// config/index.js parses the environment at import time, so this has to run
// before any src/ module is loaded — same reasoning as test/helpers/env.js.
// Dev/CI scripts like seed.js need a real DATABASE_URL but never touch Redis
// or PayPal, so those get harmless placeholders rather than requiring a full
// .env just to seed a database.
process.env.REDIS_URL ??= 'redis://localhost:6379';
process.env.JWT_ACCESS_SECRET ??= 'dev-script-access-secret-placeholder';
process.env.JWT_REFRESH_SECRET ??= 'dev-script-refresh-secret-placeholder';
process.env.PAYPAL_CLIENT_ID ??= 'paypal-client-id-placeholder';
process.env.PAYPAL_CLIENT_SECRET ??= 'paypal-client-secret-placeholder';
process.env.PAYPAL_WEBHOOK_ID ??= 'paypal-webhook-id-placeholder';
process.env.PAYPAL_ENV ??= 'sandbox';
