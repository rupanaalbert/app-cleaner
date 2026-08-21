import jwt from 'jsonwebtoken';
import { config } from '../config/index.js';
import { query } from '../db/pool.js';
import { AppError } from '../utils/errors.js';

export function requireAuth(req, _res, next) {
  const header = req.get('authorization') ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return next(AppError.unauthorized());
  try {
    const claims = jwt.verify(token, config.jwt.accessSecret);
    req.user = { id: claims.sub, role: claims.role };
    next();
  } catch {
    next(AppError.unauthorized('Token invalid or expired'));
  }
}

export const requireRole = (...roles) => (req, _res, next) =>
  roles.includes(req.user?.role) ? next() : next(AppError.forbidden(`Requires role: ${roles.join(' or ')}`));

/**
 * Authorization is per-record, not just per-role. A cleaner with a valid token
 * is still not entitled to a booking that isn't theirs — check the row.
 */
export async function requireBookingParty(req, _res, next) {
  try {
    const { rows: [b] } = await query(
      'SELECT customer_id, cleaner_id FROM bookings WHERE id = $1', [req.params.id],
    );
    if (!b) throw AppError.notFound('Booking');
    const isParty = b.customer_id === req.user.id || b.cleaner_id === req.user.id;
    if (!isParty && req.user.role !== 'admin') throw AppError.forbidden('Not a party to this booking');
    req.booking = b;
    next();
  } catch (err) { next(err); }
}
