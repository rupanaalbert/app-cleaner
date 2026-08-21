import rateLimit from 'express-rate-limit';

const base = { standardHeaders: 'draft-7', legacyHeaders: false,
  keyGenerator: (req) => req.user?.id ?? req.ip };

export const apiLimiter   = rateLimit({ ...base, windowMs: 15 * 60_000, max: 600 });
export const authLimiter  = rateLimit({ ...base, windowMs: 15 * 60_000, max: 10, keyGenerator: (r) => r.ip });
export const quoteLimiter = rateLimit({ ...base, windowMs: 60 * 60_000, max: 60 });
export const bookLimiter  = rateLimit({ ...base, windowMs: 60 * 60_000, max: 10 });
