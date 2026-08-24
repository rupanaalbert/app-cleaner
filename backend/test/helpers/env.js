// config/index.js parses the environment at import time, so this has to run
// before any src/ module is loaded. Every test file imports it first.
process.env.NODE_ENV ??= 'test';
process.env.DATABASE_URL ??= 'postgres://sparkle:sparkle@localhost:5432/sparkle_test';
process.env.REDIS_URL ??= 'redis://localhost:6379';
process.env.JWT_ACCESS_SECRET ??= 'test-access-secret-value';
process.env.JWT_REFRESH_SECRET ??= 'test-refresh-secret-value';
process.env.PAYPAL_CLIENT_ID ??= 'paypal-client-id-placeholder';
process.env.PAYPAL_CLIENT_SECRET ??= 'paypal-client-secret-placeholder';
process.env.PAYPAL_WEBHOOK_ID ??= 'paypal-webhook-id-placeholder';
process.env.PAYPAL_ENV ??= 'sandbox';
