import { Router } from 'express';
import { config } from '../config/index.js';
import { logger } from '../utils/logger.js';
import { paypal } from '../services/paypal.client.js';
import { WebhookService } from '../services/webhook.service.js';

const router = Router();

/**
 * Every event is recorded before it is processed. PayPal retries aggressively
 * (up to 25 times over 3 days on a non-2xx); without the dedupe table a
 * redelivered payout-succeeded event would double-count. Always return 2xx
 * once recorded — a 500 buys you an infinite retry loop, and a handler that
 * throws is captured in `webhook_events` for the replay sweep
 * (WebhookService.replayPaypal) instead. Signature verification is the only
 * thing the route still owns; recording and processing live in the service.
 *
 * Verification posts the transmission details back to PayPal's own
 * verify-webhook-signature endpoint rather than verifying the RSA signature
 * locally — one more HTTP round trip, but no certificate parsing to get
 * wrong, consistent with this app's "fetch, not a heavy SDK" convention.
 */
router.post('/', async (req, res) => {
  let event;
  try {
    event = JSON.parse(req.body.toString());
  } catch {
    return res.status(400).send('invalid payload');
  }

  try {
    const verification = await paypal.request('/v1/notifications/verify-webhook-signature', {
      method: 'POST',
      body: {
        auth_algo: req.get('paypal-auth-algo'),
        cert_url: req.get('paypal-cert-url'),
        transmission_id: req.get('paypal-transmission-id'),
        transmission_sig: req.get('paypal-transmission-sig'),
        transmission_time: req.get('paypal-transmission-time'),
        webhook_id: config.paypal.webhookId,
        webhook_event: event,
      },
    });
    if (verification.verification_status !== 'SUCCESS') {
      logger.warn({ verification }, 'paypal signature verification failed');
      return res.status(400).send('invalid signature');
    }
  } catch (err) {
    logger.warn({ err: err.message }, 'paypal signature verification request failed');
    return res.status(400).send('invalid signature');
  }

  const result = await WebhookService.ingestPaypal(event);
  res.json(result.duplicate ? { received: true, duplicate: true } : { received: true });
});

export default router;
