import 'dotenv/config';
import { z } from 'zod';

const env = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().default(8080),
  DATABASE_URL: z.string().url(),
  REDIS_URL: z.string().url(),
  JWT_ACCESS_SECRET: z.string().min(16),
  JWT_REFRESH_SECRET: z.string().min(16),
  PAYPAL_CLIENT_ID: z.string(),
  PAYPAL_CLIENT_SECRET: z.string(),
  PAYPAL_WEBHOOK_ID: z.string(),
  PAYPAL_ENV: z.enum(['sandbox', 'live']).default('sandbox'),
  CHECKR_API_KEY: z.string().optional(),
  GOOGLE_MAPS_KEY: z.string().optional(),
  TWILIO_ACCOUNT_SID: z.string().optional(),
  TWILIO_AUTH_TOKEN: z.string().optional(),
  TWILIO_PROXY_SERVICE_SID: z.string().optional(),
  TWILIO_FROM: z.string().optional(),                 // SMS sender number, e.g. +19785551234
  TWILIO_MESSAGING_SERVICE_SID: z.string().optional(), // preferred over a bare number if set
  POSTMARK_TOKEN: z.string().optional(),              // transactional email; log transport if unset
  MAIL_FROM: z.string().optional(),
  APP_URL: z.string().url().optional(),               // base for verification/reset links
  METRICS_TOKEN: z.string().optional(),               // bearer-gates /metrics if set
  WORKER_METRICS_PORT: z.coerce.number().default(9101),
}).parse(process.env);

/**
 * Business constants live here, not scattered through services.
 * Anything you expect to tune weekly should end up in the `pricing_rules`
 * table instead — this file needs a deploy to change.
 */
export const config = {
  env: env.NODE_ENV,
  port: env.PORT,
  isProd: env.NODE_ENV === 'production',
  db: { url: env.DATABASE_URL, max: 20, idleTimeoutMillis: 30_000 },
  redis: { url: env.REDIS_URL },
  jwt: {
    accessSecret: env.JWT_ACCESS_SECRET,
    refreshSecret: env.JWT_REFRESH_SECRET,
    accessTtl: '15m',
    refreshTtlDays: 60,
  },
  paypal: {
    clientId: env.PAYPAL_CLIENT_ID,
    clientSecret: env.PAYPAL_CLIENT_SECRET,
    webhookId: env.PAYPAL_WEBHOOK_ID,
    env: env.PAYPAL_ENV,
    baseUrl: env.PAYPAL_ENV === 'live' ? 'https://api-m.paypal.com' : 'https://api-m.sandbox.paypal.com',
  },
  checkr: { key: env.CHECKR_API_KEY },
  maps: { key: env.GOOGLE_MAPS_KEY },
  twilio: {
    sid: env.TWILIO_ACCOUNT_SID,
    token: env.TWILIO_AUTH_TOKEN,
    proxyService: env.TWILIO_PROXY_SERVICE_SID,
    sessionTtlHours: 2,
  },

  // Transactional messaging. When a provider is unconfigured the services fall
  // back to a log transport, so local dev needs no keys and tests never touch
  // the network.
  mail: {
    postmarkToken: env.POSTMARK_TOKEN,
    from: env.MAIL_FROM ?? 'Sparkle <no-reply@sparkle.app>',
    appUrl: env.APP_URL ?? 'https://app.sparkle.app',
  },
  sms: {
    from: env.TWILIO_FROM,
    messagingServiceSid: env.TWILIO_MESSAGING_SERVICE_SID,
  },

  observability: {
    token: env.METRICS_TOKEN,
    workerMetricsPort: env.WORKER_METRICS_PORT,
  },

  booking: {
    minLeadMinutes: 120,
    quoteTtlMinutes: 15,
    authBufferBps: 1000,        // authorize 10% above quote to absorb overage
    lateCancelHours: 12,
    lateCancelShareBps: 5000,   // 50% of subtotal goes to the cleaner
    geofenceMeters: 150,
    reviewWindowDays: 14,
    disputeWindowHours: 72,
  },

  matching: {
    broadcastSize: 8,
    offerTtlSeconds: 90,
    maxRounds: 3,
    radiusExpansionFactor: 1.5,
    weights: { proximity: 0.35, quality: 0.30, reliability: 0.15, acceptance: 0.10, fairness: 0.10 },
    bayesian: { priorRating: 4.6, priorWeight: 10 },
    minTrailingRating: 4.3,     // below this: removed from dispatch, coaching
    reviewFloorWindow: 20,
  },

  webhooks: {
    // Replay of failed provider webhooks. A capture that failed silently is a
    // job the cleaner worked for free, so we retry with exponential backoff and
    // only stop — poison-pill — after maxReplayAttempts, at which point it goes
    // to the admin dead-letter view for a human.
    maxReplayAttempts: 8,
    replayIntervalSeconds: 60,   // how often the sweeper runs
    replayBatchSize: 25,         // rows per sweep
    backoffBaseSeconds: 30,      // delay = base * 2^attempts, capped
    backoffCapSeconds: 3_600,
  },

  payouts: {
    // PayPal Payouts has no reverse_transfer equivalent, so a refund can't
    // atomically claw back money already sent to a cleaner. Holding a
    // completed booking's payout for this long before disbursing gives a
    // refund the normal chance to land first — matches Stripe's own 2-day
    // default delay_days so behavior doesn't visibly regress.
    holdWindowHours: 48,
    disburseBatchSize: 500,
  },

  privacy: {
    erasureGraceDays: 14,
    exportLinkTtlHours: 72,
    breadcrumbRetentionDays: 30,
    photoRetentionDays: 90,
    financialRetentionYears: 7, // legal-obligation exemption to erasure
  },
};
