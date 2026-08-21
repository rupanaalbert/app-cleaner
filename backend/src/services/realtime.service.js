import { applicationDefault, getApps, initializeApp } from 'firebase-admin/app';
import { getDatabase } from 'firebase-admin/database';
import { getAuth } from 'firebase-admin/auth';
import { query } from '../db/pool.js';
import { config } from '../config/index.js';
import { logger } from '../utils/logger.js';

if (!getApps().length && process.env.FIREBASE_SERVICE_ACCOUNT_JSON) {
  initializeApp({
    credential: applicationDefault(),
    databaseURL: process.env.FIREBASE_DATABASE_URL,
  });
}

const db = () => getDatabase();

/**
 * The bridge between Postgres (source of truth) and Firebase (transport for
 * anything that changes every few seconds).
 *
 * Clients never write the access index — that's the whole security model. A
 * cleaner can publish location for a booking only because the backend put
 * their uid under `booking_access/{id}/cleaner_id` when they claimed it, and
 * only while status is `en_route`. Rules enforce both.
 */
export class RealtimeService {
  /** Called on assignment. Opens the tracking and chat channel for both parties. */
  static async grantAccess(booking) {
    await db().ref(`booking_access/${booking.id}`).set({
      customer_id: booking.customer_id,
      cleaner_id: booking.cleaner_id,
      status: booking.status,
      scheduled_at: new Date(booking.scheduled_at).getTime(),
    });
    await query('UPDATE bookings SET firebase_thread_id = $2 WHERE id = $1',
      [booking.id, booking.id]);
  }

  /** Mirrors status so the rules can gate writes and the customer app can react. */
  static async publishStatus(bookingId, status) {
    await db().ref(`booking_access/${bookingId}/status`).set(status);
    if (status === 'arrived' || status === 'completed') {
      // Stop the location stream the moment it stops being useful. Tracking a
      // cleaner who is already inside the house is surveillance, not service.
      await db().ref(`tracking/${bookingId}`).remove();
    }
  }

  /**
   * Revokes access and clears the channel. Scheduled 24h after completion so
   * both sides can still read the thread while a dispute window is open.
   */
  static async revokeAccess(bookingId) {
    await Promise.all([
      db().ref(`booking_access/${bookingId}`).remove(),
      db().ref(`tracking/${bookingId}`).remove(),
      db().ref(`threads/${bookingId}`).remove(),
    ]);
    logger.info({ bookingId }, 'realtime channel closed');
  }

  /**
   * Firebase auth token scoped to this user. Clients authenticate to our API
   * with a JWT and exchange it here — Firebase never becomes a second, weaker
   * identity system with its own signup path.
   */
  static async mintToken(userId, role) {
    return getAuth().createCustomToken(userId, { role, iss: 'sparkle-api' });
  }

  /**
   * Coarse trail for disputes. The 10-second stream stays in Firebase and is
   * discarded; this is what survives, at 1/6th the resolution and
   * `privacy.breadcrumbRetentionDays` of life.
   */
  static async recordBreadcrumb(bookingId, { lat, lng }) {
    await query(
      `INSERT INTO location_breadcrumbs (booking_id, point)
       VALUES ($1, ST_SetSRID(ST_MakePoint($2,$3),4326)::geography)`,
      [bookingId, lng, lat],
    );
  }

  static get retentionDays() {
    return config.privacy.breadcrumbRetentionDays;
  }
}
