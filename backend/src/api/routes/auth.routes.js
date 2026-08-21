import { Router } from 'express';
import { z } from 'zod';
import { requireAuth } from '../../middleware/auth.js';
import { validate } from '../../middleware/validate.js';
import { authLimiter } from '../../middleware/rateLimit.js';
import { AuthService } from '../../services/auth.service.js';

const router = Router();

// Every unauthenticated route here is behind the same IP limiter: 10 per
// 15 minutes. Credential stuffing is the actual threat model, not clever
// cryptography.
const meta = (req) => ({
  ip: req.ip,
  userAgent: req.get('user-agent'),
  deviceId: req.get('x-device-id'),
});

/**
 * Refresh tokens go in an httpOnly cookie for web and in the response body for
 * mobile, which has no cookie jar worth trusting. Same token either way.
 */
function issueSession(res, session) {
  res.cookie?.('sparkle_refresh', session.refresh_token, {
    httpOnly: true, secure: true, sameSite: 'strict', path: '/v1/auth',
    maxAge: 60 * 86_400_000,
  });
  return session;
}

router.post('/register', authLimiter,
  validate(z.object({
    email: z.string().email().toLowerCase(),
    password: z.string().min(10).max(200),
    full_name: z.string().min(2).max(120),
    phone: z.string().regex(/^\+[1-9]\d{7,14}$/).optional(),
    role: z.enum(['customer', 'cleaner']),
  })),
  async (req, res, next) => {
    try {
      const result = await AuthService.register({
        email: req.body.email, password: req.body.password,
        fullName: req.body.full_name, phone: req.body.phone, role: req.body.role,
        ...meta(req),
      });
      // The verification token is emailed, never returned in production.
      const { verification_token, ...session } = result;
      res.status(201).json(issueSession(res, session));
    } catch (err) { next(err); }
  });

router.post('/login', authLimiter,
  validate(z.object({
    email: z.string().email().toLowerCase(),
    password: z.string().max(200),
  })),
  async (req, res, next) => {
    try {
      const session = await AuthService.login({ ...req.body, ...meta(req) });
      res.json(issueSession(res, session));
    } catch (err) { next(err); }
  });

router.post('/refresh', async (req, res, next) => {
  try {
    const presented = req.body?.refresh_token ?? req.cookies?.sparkle_refresh;
    const session = await AuthService.refresh({ presented, ...meta(req) });
    res.json(issueSession(res, session));
  } catch (err) { next(err); }
});

router.post('/logout', requireAuth,
  validate(z.object({ all_devices: z.boolean().default(false) })),
  async (req, res, next) => {
    try {
      const result = await AuthService.logout({
        presented: req.body.refresh_token ?? req.cookies?.sparkle_refresh,
        userId: req.user.id,
        allDevices: req.body.all_devices,
      });
      res.clearCookie?.('sparkle_refresh', { path: '/v1/auth' });
      res.json(result);
    } catch (err) { next(err); }
  });

router.post('/verify-email', authLimiter,
  validate(z.object({ token: z.string().min(10) })),
  async (req, res, next) => {
    try { res.json(await AuthService.verifyEmail(req.body.token)); } catch (err) { next(err); }
  });

router.post('/phone/start', requireAuth, authLimiter, async (req, res, next) => {
  try { res.json(await AuthService.startPhoneVerification(req.user.id)); } catch (err) { next(err); }
});

router.post('/phone/verify', requireAuth, authLimiter,
  validate(z.object({ code: z.string().length(6) })),
  async (req, res, next) => {
    try { res.json(await AuthService.verifyPhone(req.user.id, req.body.code)); } catch (err) { next(err); }
  });

router.post('/password/forgot', authLimiter,
  validate(z.object({ email: z.string().email().toLowerCase() })),
  async (req, res, next) => {
    try {
      await AuthService.forgotPassword(req.body.email);
      // Identical response whether or not the account exists.
      res.json({ sent: true });
    } catch (err) { next(err); }
  });

router.post('/password/reset', authLimiter,
  validate(z.object({ token: z.string().min(10), password: z.string().min(10).max(200) })),
  async (req, res, next) => {
    try { res.json(await AuthService.resetPassword(req.body)); } catch (err) { next(err); }
  });

router.get('/me', requireAuth, async (req, res) => {
  res.json({ user: { id: req.user.id, role: req.user.role } });
});

export default router;
