# Sparkle API — backend

Modular monolith. Routes validate and authorize, controllers translate HTTP, services own the rules, repositories own SQL. A service never imports `express`; a route never imports `pg`.

```
src/
├── server.js                   boot, graceful shutdown
├── app.js                      express wiring, middleware order
├── config/index.js             env parsing + tunable business constants
├── db/
│   ├── pool.js                 pg pool, query helper, withTransaction()
│   └── repositories/           bookings, cleaners, payments, reviews
├── middleware/
│   ├── auth.js                 requireAuth, requireRole, requireBookingParty
│   ├── idempotency.js          replay guard for money-moving POSTs
│   ├── validate.js             zod → 400 problem details
│   └── errorHandler.js         RFC 9457 responses
├── api/
│   ├── routes/                 bookings, quotes, offers, payments, reviews, me
│   └── controllers/            thin HTTP adapters
├── services/
│   ├── pricing.service.js      quote math, commission, trust & safety fee
│   ├── matching.service.js     hard filters + weighted ranking + broadcast
│   ├── booking.service.js      state machine, geofencing, cancellation
│   ├── payment.service.js      Stripe Connect authorize/capture/transfer
│   ├── trust.service.js        Checkr, Twilio Proxy, document intake
│   └── privacy.service.js      export, erasure, consent
├── jobs/                       BullMQ queues + worker (broadcast, expiry, ratings)
└── webhooks/                   stripe.js, checkr.js — verified raw-body handlers
```

**Middleware order matters** (see `app.js`): `helmet → cors → requestId → pinoHttp → rawBody for /webhooks → json → rateLimit → routes → errorHandler`. Stripe signature verification needs the raw body, so webhook routes mount *before* `express.json()`.

**Transactions**: any handler that writes to more than one table wraps in `withTransaction`. Booking confirmation and payment authorization are one unit — a booking without a hold is a booking you can't collect on.
