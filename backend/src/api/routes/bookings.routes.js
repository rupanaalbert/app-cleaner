import { Router } from 'express';
import { z } from 'zod';
import { requireAuth, requireRole, requireBookingParty } from '../../middleware/auth.js';
import { validate } from '../../middleware/validate.js';
import { idempotency } from '../../middleware/idempotency.js';
import { bookLimiter } from '../../middleware/rateLimit.js';
import { BookingController } from '../controllers/booking.controller.js';

const router = Router();

const create = z.object({
  quote_id: z.string().uuid(),
  payment_method_id: z.string().startsWith('pm_'),
  special_instructions: z.string().max(1000).optional(),
  entry_method: z.enum(['home', 'lockbox', 'doorman', 'hidden_key']).optional(),
});

const statusUpdate = z.object({
  status: z.enum(['en_route', 'arrived', 'in_progress', 'completed']),
  location: z.object({
    lat: z.number().min(-90).max(90),
    lng: z.number().min(-180).max(180),
    accuracy_m: z.number().optional(),
  }).optional(),
  actual_duration_min: z.number().int().positive().optional(),
});

router.post('/', requireAuth, requireRole('customer'), bookLimiter,
  idempotency, validate(create), BookingController.create);

router.get('/', requireAuth, BookingController.list);
router.get('/:id', requireAuth, requireBookingParty, BookingController.get);

router.patch('/:id/status', requireAuth, requireRole('cleaner'), requireBookingParty,
  validate(statusUpdate), BookingController.updateStatus);

router.post('/:id/cancel', requireAuth, requireBookingParty,
  validate(z.object({ reason: z.string().max(200) })), BookingController.cancel);

router.post('/:id/photos', requireAuth, requireRole('cleaner'), requireBookingParty,
  validate(z.object({ phase: z.enum(['before', 'after']), count: z.number().int().min(1).max(10) })),
  BookingController.presignPhotos);

router.post('/:id/call', requireAuth, requireBookingParty, BookingController.openMaskedCall);

export default router;
