import { Router } from 'express';
import { z } from 'zod';
import { requireAuth, requireRole } from '../../middleware/auth.js';
import { validate } from '../../middleware/validate.js';
import { AdminService } from '../../services/admin.service.js';

const router = Router();

// Admin is a role, not a subdomain. Every route below is behind the same gate,
// applied once here so a new route cannot be added without it.
router.use(requireAuth, requireRole('admin'));

const ctx = (req) => ({ actorId: req.user.id, ip: req.ip });

router.get('/metrics', async (req, res, next) => {
  try { res.json(await AdminService.metrics()); } catch (err) { next(err); }
});

// ---------------------------------------------------------------- vetting ---
router.get('/cleaners/pending', async (req, res, next) => {
  try { res.json({ cleaners: await AdminService.vettingQueue() }); } catch (err) { next(err); }
});

router.post('/documents/:id/review',
  validate(z.object({ approved: z.boolean(), note: z.string().max(500).optional() })),
  async (req, res, next) => {
    try {
      const doc = await AdminService.reviewDocument({
        documentId: req.params.id, approved: req.body.approved, note: req.body.note, ...ctx(req),
      });
      res.json({ document: doc });
    } catch (err) { next(err); }
  });

router.post('/cleaners/:id/approve', async (req, res, next) => {
  try {
    res.json({ cleaner: await AdminService.approveCleaner({ cleanerId: req.params.id, ...ctx(req) }) });
  } catch (err) { next(err); }
});

router.post('/cleaners/:id/reject',
  validate(z.object({ reason: z.string().min(3).max(500) })),
  async (req, res, next) => {
    try {
      res.json({ cleaner: await AdminService.rejectCleaner({
        cleanerId: req.params.id, reason: req.body.reason, ...ctx(req) }) });
    } catch (err) { next(err); }
  });

router.post('/cleaners/:id/suspend',
  validate(z.object({ days: z.number().int().min(1).max(365), reason: z.string().min(3).max(500) })),
  async (req, res, next) => {
    try {
      res.json(await AdminService.suspendCleaner({
        cleanerId: req.params.id, days: req.body.days, reason: req.body.reason, ...ctx(req) }));
    } catch (err) { next(err); }
  });

// --------------------------------------------------------------- disputes ---
router.get('/disputes', async (req, res, next) => {
  try {
    res.json({ disputes: await AdminService.disputeQueue({ status: req.query.status ?? 'open' }) });
  } catch (err) { next(err); }
});

router.post('/disputes/:id/resolve',
  validate(z.object({
    resolution: z.string().min(3).max(2000),
    refund_cents: z.number().int().min(0).default(0),
    // Refund and penalty are separate decisions: a customer can be made whole
    // without the cleaner being at fault.
    penalty: z.enum(['none', 'hide_review', 'coaching', 'suspend']).default('none'),
  })),
  async (req, res, next) => {
    try {
      res.json({ dispute: await AdminService.resolveDispute({
        disputeId: req.params.id,
        resolution: req.body.resolution,
        refundCents: req.body.refund_cents,
        penalty: req.body.penalty,
        ...ctx(req),
      }) });
    } catch (err) { next(err); }
  });

router.get('/bookings/:id', async (req, res, next) => {
  try { res.json(await AdminService.bookingDossier(req.params.id)); } catch (err) { next(err); }
});

// --------------------------------------------------- webhook dead-letters ---
router.get('/webhooks/failed',
  validate(z.object({ status: z.enum(['dead', 'failing', 'all']).default('dead') }), 'query'),
  async (req, res, next) => {
    try { res.json(await AdminService.listFailedWebhooks({ status: req.query.status })); }
    catch (err) { next(err); }
  });

router.post('/webhooks/:id/requeue', async (req, res, next) => {
  try {
    res.json({ webhook: await AdminService.requeueWebhook({ eventId: req.params.id, ...ctx(req) }) });
  } catch (err) { next(err); }
});

export default router;
