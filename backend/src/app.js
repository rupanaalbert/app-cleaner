import express from 'express';
import helmet from 'helmet';
import cors from 'cors';
import compression from 'compression';
import cookieParser from 'cookie-parser';
import pinoHttp from 'pino-http';
import { randomUUID } from 'node:crypto';
import { config } from './config/index.js';
import { logger } from './utils/logger.js';
import { registry, CONTENT_TYPE } from './observability/metrics.js';
import { errorHandler, notFound } from './middleware/errorHandler.js';
import { apiLimiter } from './middleware/rateLimit.js';
import paypalWebhook from './webhooks/paypal.js';
import checkrWebhook from './webhooks/checkr.js';
import authRoutes from './api/routes/auth.routes.js';
import quoteRoutes from './api/routes/quotes.routes.js';
import bookingRoutes from './api/routes/bookings.routes.js';
import offerRoutes from './api/routes/offers.routes.js';
import paymentRoutes from './api/routes/payments.routes.js';
import reviewRoutes from './api/routes/reviews.routes.js';
import meRoutes from './api/routes/me.routes.js';
import realtimeRoutes from './api/routes/realtime.routes.js';
import adminRoutes from './api/routes/admin.routes.js';
import onboardingRoutes from './api/routes/onboarding.routes.js';

export function createApp() {
  const app = express();
  app.set('trust proxy', 1);

  app.use(helmet());
  app.use(cors({ origin: (o, cb) => cb(null, true), credentials: true }));
  app.use(compression());
  app.use(cookieParser()); // refresh cookie for web; mobile uses the body
  app.use((req, res, next) => {
    req.id = req.get('x-request-id') ?? randomUUID();
    res.set('x-request-id', req.id);
    next();
  });
  app.use(pinoHttp({ logger, genReqId: (req) => req.id }));

  // Webhooks mount BEFORE express.json(): signature verification needs the
  // raw body, and a parsed body silently breaks it.
  app.use('/v1/webhooks/paypal', express.raw({ type: 'application/json' }), paypalWebhook);
  app.use('/v1/webhooks/checkr', express.raw({ type: 'application/json' }), checkrWebhook);

  app.use(express.json({ limit: '1mb' }));
  app.get('/healthz', (req, res) => res.json({ ok: true, version: process.env.GIT_SHA ?? 'dev' }));

  // Prometheus scrape. Optionally bearer-gated (METRICS_TOKEN) for when it's
  // reachable off a trusted network. Records only this (API) process; the
  // worker exposes its own on WORKER_METRICS_PORT.
  app.get('/metrics', (req, res) => {
    const { token } = config.observability;
    if (token && req.get('authorization') !== `Bearer ${token}`) return res.status(401).end();
    res.set('content-type', CONTENT_TYPE).send(registry.render());
  });

  app.use('/v1/auth', authRoutes);   // before apiLimiter: authLimiter is stricter
  app.use('/v1', apiLimiter);
  app.use('/v1/quotes', quoteRoutes);
  app.use('/v1/bookings', bookingRoutes);
  app.use('/v1', offerRoutes);       // /cleaner/offers, /offers/:id/accept
  app.use('/v1', paymentRoutes);
  app.use('/v1', reviewRoutes);
  app.use('/v1', realtimeRoutes); // /realtime/token, /bookings/:id/breadcrumb
  app.use('/v1/me', meRoutes);
  app.use('/v1/admin', adminRoutes);
  app.use('/v1/cleaner', onboardingRoutes);

  app.use(notFound);
  app.use(errorHandler);
  return app;
}
