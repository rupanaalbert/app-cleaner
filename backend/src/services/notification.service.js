import { applicationDefault, getApps, initializeApp } from 'firebase-admin/app';
import { getMessaging } from 'firebase-admin/messaging';
import { query } from '../db/pool.js';
import { logger } from '../utils/logger.js';

if (!getApps().length && process.env.FIREBASE_SERVICE_ACCOUNT_JSON) {
  initializeApp({ credential: applicationDefault() });
}

async function push(userId, notification, data = {}) {
  const { rows } = await query('SELECT fcm_token FROM devices WHERE user_id = $1', [userId]);
  if (!rows.length) return;
  try {
    await getMessaging().sendEachForMulticast({
      tokens: rows.map((r) => r.fcm_token),
      notification,
      data: Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)])),
      android: { priority: 'high' },
      apns: { payload: { aps: { sound: 'default', 'interruption-level': 'time-sensitive' } } },
    });
  } catch (err) {
    logger.warn({ err, userId }, 'push failed');
  }
}

export const notifyOffer = (cleanerId, booking, candidate) => push(cleanerId, {
  title: `New job · $${(booking.payout_cents / 100).toFixed(2)}`,
  body: `${candidate.distance_km.toFixed(1)} km away · ${booking.duration_min} min`,
}, { type: 'offer', booking_id: booking.id });

export const notifyAssigned = (customerId, booking, cleanerName) => push(customerId, {
  title: 'Your cleaner is booked',
  body: `${cleanerName} will arrive at your scheduled time.`,
}, { type: 'assigned', booking_id: booking.id });

export const notifyEnRoute = (customerId, booking, etaMin) => push(customerId, {
  title: 'Your cleaner is on the way',
  body: `Arriving in about ${etaMin} minutes. Track them in the app.`,
}, { type: 'en_route', booking_id: booking.id });

export { push };
