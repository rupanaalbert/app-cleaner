import { Router } from 'express';
import { z } from 'zod';
import { requireAuth, requireRole } from '../../middleware/auth.js';
import { validate } from '../../middleware/validate.js';
import { query } from '../../db/pool.js';
import { OnboardingService } from '../../services/onboarding.service.js';

const router = Router();
router.use(requireAuth, requireRole('cleaner'));

router.get('/onboarding', async (req, res, next) => {
  try { res.json(await OnboardingService.status(req.user.id)); } catch (err) { next(err); }
});

router.patch('/onboarding/profile',
  validate(z.object({
    bio: z.string().max(1000).optional(),
    years_experience: z.number().int().min(0).max(60).optional(),
    service_types: z.array(z.enum(['standard', 'deep'])).min(1).optional(),
    service_radius_km: z.number().min(2).max(60).optional(),
    lat: z.number().min(-90).max(90).optional(),
    lng: z.number().min(-180).max(180).optional(),
  })),
  async (req, res, next) => {
    try {
      await OnboardingService.saveProfile(req.user.id, {
        bio: req.body.bio,
        yearsExperience: req.body.years_experience,
        serviceTypes: req.body.service_types,
        serviceRadiusKm: req.body.service_radius_km,
        lat: req.body.lat,
        lng: req.body.lng,
      });
      res.json(await OnboardingService.status(req.user.id));
    } catch (err) { next(err); }
  });

router.put('/onboarding/availability',
  validate(z.object({
    windows: z.array(z.object({
      day_of_week: z.number().int().min(0).max(6),
      start_min: z.number().int().min(0).max(1439),
      end_min: z.number().int().min(1).max(1440),
    })).max(21),
  })),
  async (req, res, next) => {
    try {
      await OnboardingService.setAvailability(req.user.id, req.body.windows);
      res.json(await OnboardingService.status(req.user.id));
    } catch (err) { next(err); }
  });

router.post('/onboarding/documents',
  validate(z.object({
    doc_type: z.enum(['gov_id', 'insurance', 'work_auth', 'certification']),
    expires_at: z.string().date().optional(),
    content_type: z.string().default('image/jpeg'),
  })),
  async (req, res, next) => {
    try {
      res.status(201).json(await OnboardingService.presignDocument(req.user.id, {
        docType: req.body.doc_type,
        expiresAt: req.body.expires_at,
        contentType: req.body.content_type,
      }));
    } catch (err) { next(err); }
  });

router.post('/onboarding/documents/:id/confirm',
  validate(z.object({ sha256: z.string().length(64) })),
  async (req, res, next) => {
    try {
      await OnboardingService.confirmDocument(req.user.id, req.params.id, req.body.sha256);
      res.json(await OnboardingService.status(req.user.id));
    } catch (err) { next(err); }
  });

router.post('/onboarding/payouts',
  validate(z.object({ return_url: z.string().url(), refresh_url: z.string().url() })),
  async (req, res, next) => {
    try {
      res.json(await OnboardingService.payoutsLink(req.user.id, {
        returnUrl: req.body.return_url, refreshUrl: req.body.refresh_url,
      }));
    } catch (err) { next(err); }
  });

router.post('/onboarding/background-check', async (req, res, next) => {
  try { res.json(await OnboardingService.startBackgroundCheck(req.user.id)); } catch (err) { next(err); }
});

router.post('/onboarding/submit', async (req, res, next) => {
  try { res.json(await OnboardingService.submit(req.user.id)); } catch (err) { next(err); }
});

/**
 * The online toggle. Gated on approval so a pending applicant cannot put
 * themselves into dispatch — the matching engine filters on this too, but the
 * clearer error belongs here.
 */
router.patch('/availability',
  validate(z.object({ is_available: z.boolean() })),
  async (req, res, next) => {
    try {
      const { rows: [updated] } = await query(
        `UPDATE cleaner_profiles SET is_available = $2
          WHERE user_id = $1 AND onboarding_status = 'approved'
          RETURNING is_available`,
        [req.user.id, req.body.is_available],
      );
      if (!updated) {
        return res.status(422).json({
          type: 'https://api.sparkle.app/errors/not-approved',
          title: 'Not approved yet', status: 422, code: 'NOT_APPROVED',
          detail: 'You can start accepting jobs once your application is approved.',
          request_id: req.id,
        });
      }
      res.json(updated);
    } catch (err) { next(err); }
  });

export default router;
