import { createHash } from 'node:crypto';
import { query } from '../db/pool.js';
import { AppError } from '../utils/errors.js';

/**
 * Replay guard for money-moving POSTs. A retried mobile request (flaky
 * network, user double-tap) returns the original response instead of
 * creating a second booking or a second charge.
 */
export function idempotency(req, res, next) {
  const key = req.get('idempotency-key');
  if (!key) return next(AppError.badRequest('IDEMPOTENCY_KEY_REQUIRED', 'Send an Idempotency-Key header'));

  const fingerprint = createHash('sha256')
    .update(`${req.user.id}:${req.path}:${JSON.stringify(req.body)}`).digest('hex');

  query(`SELECT response, fingerprint FROM idempotency_keys WHERE key = $1`, [key])
    .then(({ rows: [existing] }) => {
      if (existing) {
        if (existing.fingerprint !== fingerprint) {
          return next(AppError.conflict('IDEMPOTENCY_MISMATCH', 'This key was used with a different payload'));
        }
        res.set('Idempotent-Replay', 'true');
        return res.status(200).json(existing.response);
      }
      const originalJson = res.json.bind(res);
      res.json = (body) => {
        if (res.statusCode < 400) {
          query(`INSERT INTO idempotency_keys (key, fingerprint, response)
                 VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, [key, fingerprint, body]).catch(() => {});
        }
        return originalJson(body);
      };
      next();
    })
    .catch(next);
}
