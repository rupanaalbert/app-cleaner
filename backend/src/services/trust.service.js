import twilio from 'twilio';
import { query } from '../db/pool.js';
import { config } from '../config/index.js';
import { AppError } from '../utils/errors.js';

// A placeholder value (e.g. ".env"'s unfilled "...") is still a truthy
// string, so check the shape Twilio itself requires rather than just
// presence — an invalid SID throws synchronously from the constructor,
// which otherwise takes the whole server down at import time.
const client = config.twilio.sid?.startsWith('AC') ? twilio(config.twilio.sid, config.twilio.token) : null;

export class TrustService {
  /**
   * Masked calling: neither party ever sees the other's number. The session
   * closes 2h after completion, so a cleaner cannot call a customer next month.
   */
  static async openMaskedCall(bookingId) {
    const { rows: [b] } = await query(
      `SELECT b.id, b.status, b.customer_id, b.cleaner_id, b.completed_at,
              cu.phone_e164 AS customer_phone, cl.phone_e164 AS cleaner_phone
         FROM bookings b
         JOIN users cu ON cu.id = b.customer_id
         LEFT JOIN users cl ON cl.id = b.cleaner_id
        WHERE b.id = $1`, [bookingId],
    );
    if (!b?.cleaner_id) throw AppError.conflict('NOT_ASSIGNED', 'No cleaner assigned yet');

    const closedFor = b.completed_at && Date.now() - new Date(b.completed_at) > config.twilio.sessionTtlHours * 3_600_000;
    if (closedFor) throw AppError.conflict('CALL_WINDOW_CLOSED', 'Contact support instead');

    const { rows: [existing] } = await query(
      'SELECT * FROM masked_call_sessions WHERE booking_id=$1 AND closed_at IS NULL AND expires_at > now()',
      [bookingId],
    );
    if (existing) return { proxy_number: existing.proxy_number, expires_at: existing.expires_at };

    const session = await client.proxy.v1.services(config.twilio.proxyService)
      .sessions.create({ uniqueName: `booking-${bookingId}`, ttl: 8 * 3_600 });
    for (const phone of [b.customer_phone, b.cleaner_phone]) {
      await client.proxy.v1.services(config.twilio.proxyService)
        .sessions(session.sid).participants.create({ identifier: phone });
    }
    const participants = await client.proxy.v1.services(config.twilio.proxyService)
      .sessions(session.sid).participants.list();
    const proxyNumber = participants[0].proxyIdentifier;
    const expiresAt = new Date(Date.now() + 8 * 3_600_000);

    await query(
      `INSERT INTO masked_call_sessions (booking_id, twilio_sid, proxy_number, expires_at)
       VALUES ($1,$2,$3,$4)`, [bookingId, session.sid, proxyNumber, expiresAt],
    );
    return { proxy_number: proxyNumber, expires_at: expiresAt };
  }

  /** Photos and documents go straight to S3 — they never transit the API tier. */
  static async presignJobPhotos(bookingId, phase, count) {
    const { getSignedUrl } = await import('@aws-sdk/s3-request-presigner');
    const { S3Client, PutObjectCommand } = await import('@aws-sdk/client-s3');
    const s3 = new S3Client({ region: process.env.AWS_REGION });

    const uploads = [];
    for (let i = 0; i < count; i++) {
      const key = `bookings/${bookingId}/${phase}/${crypto.randomUUID()}.jpg`;
      const url = await getSignedUrl(s3, new PutObjectCommand({
        Bucket: process.env.S3_BUCKET, Key: key, ContentType: 'image/jpeg',
      }), { expiresIn: 900 });
      await query(
        `INSERT INTO job_photos (booking_id, phase, s3_key, purge_after)
         VALUES ($1,$2,$3, current_date + $4)`,
        [bookingId, phase, key, config.privacy.photoRetentionDays],
      );
      uploads.push({ key, url });
    }
    return uploads;
  }
}
