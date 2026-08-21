import { Router } from 'express';
import { stripe } from '../services/payment.service.js';
import { config } from '../config/index.js';
import { logger } from '../utils/logger.js';
import { WebhookService } from '../services/webhook.service.js';

const router = Router();

/**
 * Every event is recorded before it is processed. Stripe retries aggressively;
 * without the dedupe table a redelivered `payout.paid` would double-count.
 * Always return 2xx once recorded — a 500 buys you an infinite retry loop, and
 * a handler that throws is captured in `webhook_events` for the replay sweep
 * (WebhookService.replayStripe) instead. Signature verification is the only
 * thing the route still owns; recording and processing live in the service.
 */
router.post('/', async (req, res) => {
  let event;
  try {
    event = stripe.webhooks.constructEvent(
      req.body, req.get('stripe-signature'), config.stripe.webhookSecret,
    );
  } catch (err) {
    logger.warn({ err: err.message }, 'stripe signature verification failed');
    return res.status(400).send('invalid signature');
  }

  const result = await WebhookService.ingestStripe(event);
  res.json(result.duplicate ? { received: true, duplicate: true } : { received: true });
});

export default router;
