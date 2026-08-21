import { query, withTransaction } from '../db/pool.js';
import { config } from '../config/index.js';
import { AppError } from '../utils/errors.js';
import { logger } from '../utils/logger.js';
import { stripe } from './payment.service.js';

/**
 * Cleaner onboarding.
 *
 * Four independent tracks that can be completed in any order — profile,
 * documents, payouts, background check — plus a submit step that hands the
 * application to the vetting queue.
 *
 * Order matters less than parallelism here: the Checkr report takes 1–5 days,
 * so it starts as early as the candidate will let it, and the rest of the
 * application is filled in while it runs. Forcing a linear wizard would idle
 * the slowest step behind the fastest ones.
 */
export class OnboardingService {
  /**
   * The applicant's view of their own application. Deliberately the same three
   * gates the admin console enforces — an applicant who can see what's
   * blocking them doesn't open a support ticket.
   */
  static async status(cleanerId) {
    const { rows: [profile] } = await query(
      `SELECT c.*, u.full_name, u.email, u.phone_verified_at
         FROM cleaner_profiles c JOIN users u ON u.id = c.user_id
        WHERE c.user_id = $1`, [cleanerId]);
    if (!profile) throw AppError.notFound('Cleaner profile');

    const { rows: documents } = await query(
      `SELECT id, doc_type, expires_at, verified_at, rejected_note, created_at
         FROM cleaner_documents WHERE cleaner_id = $1 ORDER BY doc_type`, [cleanerId]);

    const { rows: availability } = await query(
      'SELECT day_of_week, start_min, end_min FROM cleaner_availability WHERE cleaner_id = $1',
      [cleanerId]);

    const required = ['gov_id', 'insurance', 'work_auth'];
    const uploaded = new Set(documents.map((d) => d.doc_type));
    const missing = required.filter((t) => !uploaded.has(t));
    const rejected = documents.filter((d) => d.rejected_note);

    const steps = {
      profile: {
        complete: Boolean(profile.bio && profile.home_location && availability.length > 0),
        detail: availability.length === 0
          ? 'Add the hours you can work'
          : `${availability.length} weekly window${availability.length > 1 ? 's' : ''}, ${profile.service_radius_km} km radius`,
      },
      documents: {
        complete: missing.length === 0 && rejected.length === 0,
        detail: missing.length
          ? `Still needed: ${missing.map(labelFor).join(', ')}`
          : rejected.length
            ? `${rejected.length} document needs replacing`
            : `${documents.length} uploaded`,
      },
      payouts: {
        complete: profile.payouts_enabled,
        detail: profile.stripe_account_id
          ? (profile.payouts_enabled ? 'Ready to receive payouts' : 'Stripe needs a few more details')
          : 'Connect a bank account',
      },
      background_check: {
        complete: profile.bg_status === 'clear',
        detail: {
          not_started: 'Consent to a background check',
          pending: 'In progress — usually 1 to 3 business days',
          clear: 'Clear',
          consider: 'Under review by our team',
          suspended: 'On hold — our team will be in touch',
          expired: 'Needs renewing',
        }[profile.bg_status],
      },
    };

    const readyToSubmit = Object.values(steps).every((s) => s.complete);

    return {
      onboarding_status: profile.onboarding_status,
      steps,
      ready_to_submit: readyToSubmit,
      submitted: ['docs_submitted', 'check_pending', 'approved'].includes(profile.onboarding_status),
      documents,
      profile: {
        bio: profile.bio,
        years_experience: profile.years_experience,
        service_types: profile.service_types,
        service_radius_km: Number(profile.service_radius_km),
      },
      availability,
    };
  }

  static async saveProfile(cleanerId, { bio, yearsExperience, serviceTypes, serviceRadiusKm, lat, lng }) {
    const { rows: [updated] } = await query(
      `UPDATE cleaner_profiles
          SET bio = COALESCE($2, bio),
              years_experience = COALESCE($3, years_experience),
              service_types = COALESCE($4, service_types),
              service_radius_km = COALESCE($5, service_radius_km),
              home_location = COALESCE(
                CASE WHEN $6::float IS NULL THEN NULL
                     ELSE ST_SetSRID(ST_MakePoint($7,$6),4326)::geography END,
                home_location)
        WHERE user_id = $1
        RETURNING *`,
      [cleanerId, bio, yearsExperience, serviceTypes, serviceRadiusKm, lat ?? null, lng ?? null],
    );
    if (!updated) throw AppError.notFound('Cleaner profile');
    return updated;
  }

  /** Replaces the whole weekly schedule — partial edits of a calendar are a bug factory. */
  static async setAvailability(cleanerId, windows) {
    return withTransaction(async (client) => {
      await client.query('DELETE FROM cleaner_availability WHERE cleaner_id = $1', [cleanerId]);
      for (const w of windows) {
        if (w.end_min <= w.start_min) {
          throw AppError.badRequest('INVALID_WINDOW', 'Each window must end after it starts');
        }
        await client.query(
          `INSERT INTO cleaner_availability (cleaner_id, day_of_week, start_min, end_min)
           VALUES ($1,$2,$3,$4)`,
          [cleanerId, w.day_of_week, w.start_min, w.end_min],
        );
      }
      return windows;
    });
  }

  /**
   * Presigned upload. Identity documents never transit our API — one fewer
   * place a passport scan can end up in a log line or an APM trace.
   */
  static async presignDocument(cleanerId, { docType, expiresAt, contentType = 'image/jpeg' }) {
    const { getSignedUrl } = await import('@aws-sdk/s3-request-presigner');
    const { S3Client, PutObjectCommand } = await import('@aws-sdk/client-s3');
    const s3 = new S3Client({ region: process.env.AWS_REGION });

    const key = `cleaners/${cleanerId}/${docType}/${crypto.randomUUID()}`;
    const url = await getSignedUrl(s3, new PutObjectCommand({
      Bucket: process.env.S3_BUCKET,
      Key: key,
      ContentType: contentType,
      ServerSideEncryption: 'aws:kms',
    }), { expiresIn: 900 });

    // Re-uploading a rejected document replaces it rather than stacking a
    // second row, so the reviewer always sees exactly one of each type.
    const { rows: [doc] } = await query(
      `INSERT INTO cleaner_documents (cleaner_id, doc_type, s3_key, sha256, expires_at)
       VALUES ($1,$2,$3,'pending',$4)
       RETURNING id, doc_type, s3_key`,
      [cleanerId, docType, key, expiresAt ?? null],
    );
    await query(
      `DELETE FROM cleaner_documents
        WHERE cleaner_id = $1 AND doc_type = $2 AND id <> $3 AND verified_at IS NULL`,
      [cleanerId, docType, doc.id],
    );

    return { document_id: doc.id, upload_url: url, key };
  }

  /** Client confirms the PUT succeeded and reports the file hash. */
  static async confirmDocument(cleanerId, documentId, sha256) {
    const { rows: [doc] } = await query(
      `UPDATE cleaner_documents SET sha256 = $3, rejected_note = NULL
        WHERE id = $2 AND cleaner_id = $1 RETURNING *`,
      [cleanerId, documentId, sha256],
    );
    if (!doc) throw AppError.notFound('Document');
    return doc;
  }

  /**
   * Stripe Connect Express. We create the account and hand back a one-time
   * onboarding link; Stripe collects the bank details and the tax identity, so
   * none of it lands in our database.
   */
  static async payoutsLink(cleanerId, { returnUrl, refreshUrl }) {
    const { rows: [profile] } = await query(
      'SELECT stripe_account_id FROM cleaner_profiles WHERE user_id = $1', [cleanerId]);
    if (!profile) throw AppError.notFound('Cleaner profile');

    let accountId = profile.stripe_account_id;
    if (!accountId) {
      const { rows: [user] } = await query('SELECT email FROM users WHERE id = $1', [cleanerId]);
      const account = await stripe.accounts.create({
        type: 'express',
        email: user.email,
        business_type: 'individual',
        capabilities: { transfers: { requested: true } },
        settings: { payouts: { schedule: { interval: 'daily', delay_days: 2 } } },
        metadata: { cleaner_id: cleanerId },
      }, { idempotencyKey: `connect:${cleanerId}` });
      accountId = account.id;
      await query('UPDATE cleaner_profiles SET stripe_account_id = $2 WHERE user_id = $1',
        [cleanerId, accountId]);
    }

    const link = await stripe.accountLinks.create({
      account: accountId,
      type: 'account_onboarding',
      return_url: returnUrl,
      refresh_url: refreshUrl,
    });
    // `payouts_enabled` is set by the account.updated webhook, never here —
    // Stripe decides when an account can receive money, not us.
    return { url: link.url, expires_at: new Date(link.expires_at * 1000) };
  }

  /**
   * Checkr. We send the candidate, Checkr emails them the consent form, and
   * the webhook writes back a status. The report body is never stored — only
   * the id and the verdict, which is all a reviewer is entitled to see.
   */
  static async startBackgroundCheck(cleanerId) {
    const { rows: [row] } = await query(
      `SELECT u.email, u.full_name, u.phone_e164, c.bg_status, c.bg_report_id
         FROM users u JOIN cleaner_profiles c ON c.user_id = u.id
        WHERE u.id = $1`, [cleanerId]);
    if (!row) throw AppError.notFound('Cleaner');
    if (['pending', 'clear'].includes(row.bg_status)) {
      return { status: row.bg_status, already_started: true };
    }

    const auth = Buffer.from(`${config.checkr.key}:`).toString('base64');
    const [firstName, ...rest] = (row.full_name ?? '').split(' ');

    const candidate = await fetch('https://api.checkr.com/v1/candidates', {
      method: 'POST',
      headers: { authorization: `Basic ${auth}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        email: row.email,
        first_name: firstName,
        last_name: rest.join(' ') || firstName,
        phone: row.phone_e164,
        work_locations: [{ country: 'US' }],
      }),
    }).then(assertOk('Checkr candidate'));

    const invitation = await fetch('https://api.checkr.com/v1/invitations', {
      method: 'POST',
      headers: { authorization: `Basic ${auth}`, 'content-type': 'application/json' },
      body: JSON.stringify({ candidate_id: candidate.id, package: 'sparkle_pro_criminal' }),
    }).then(assertOk('Checkr invitation'));

    await query(
      `UPDATE cleaner_profiles
          SET bg_status = 'pending', bg_report_id = $2,
              onboarding_status = CASE WHEN onboarding_status = 'started'
                                       THEN 'check_pending' ELSE onboarding_status END
        WHERE user_id = $1`,
      [cleanerId, invitation.report_id ?? candidate.id],
    );

    logger.info({ cleanerId }, 'background check invited');
    return { status: 'pending', invitation_url: invitation.invitation_url };
  }

  /** Hands the application to the vetting queue. Gates mirror the admin side. */
  static async submit(cleanerId) {
    const status = await this.status(cleanerId);
    if (status.submitted) {
      throw AppError.conflict('ALREADY_SUBMITTED', 'Your application is already with our team');
    }
    const incomplete = Object.entries(status.steps)
      .filter(([, s]) => !s.complete)
      .map(([name]) => name);

    // The background check is allowed to still be running: it's the slow step,
    // and a reviewer can work the rest of the file while it lands.
    const blocking = incomplete.filter((name) => name !== 'background_check');
    if (blocking.length) {
      throw AppError.unprocessable('ONBOARDING_INCOMPLETE',
        `Finish these first: ${blocking.map(labelFor).join(', ')}`, { steps: blocking });
    }

    await query(
      `UPDATE cleaner_profiles SET onboarding_status = 'docs_submitted' WHERE user_id = $1`,
      [cleanerId]);
    return { onboarding_status: 'docs_submitted', expected_review: 'within 2 business days' };
  }
}

const LABELS = {
  gov_id: 'photo ID',
  insurance: 'proof of insurance',
  work_auth: 'work authorization',
  certification: 'certification',
  profile: 'your profile',
  documents: 'your documents',
  payouts: 'bank details',
  background_check: 'the background check',
};
const labelFor = (key) => LABELS[key] ?? key.replace(/_/g, ' ');

const assertOk = (what) => async (res) => {
  if (!res.ok) {
    logger.error({ what, status: res.status }, 'external provider rejected request');
    throw AppError.unprocessable('PROVIDER_ERROR', `${what} could not be created right now`);
  }
  return res.json();
};
