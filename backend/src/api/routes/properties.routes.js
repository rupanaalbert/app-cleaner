import { Router } from 'express';
import { z } from 'zod';
import { requireAuth, requireRole } from '../../middleware/auth.js';
import { validate } from '../../middleware/validate.js';
import { PropertyController } from '../controllers/property.controller.js';

const router = Router();

const createProperty = z.object({
  line1: z.string().min(1).max(200),
  line2: z.string().max(200).optional(),
  city: z.string().min(1).max(100),
  region: z.string().trim().length(2).toUpperCase(),
  postal_code: z.string().regex(/^\d{5}(-\d{4})?$/),
  access_notes: z.string().max(500).optional(),
});

router.get('/', requireAuth, requireRole('customer'), PropertyController.list);
router.post('/', requireAuth, requireRole('customer'), validate(createProperty), PropertyController.create);

export default router;
