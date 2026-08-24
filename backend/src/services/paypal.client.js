import { config } from '../config/index.js';
import { logger } from '../utils/logger.js';

/**
 * PayPal REST client.
 *
 * Raw fetch, no SDK — same call it was for Postmark (mail.service.js): one
 * dependency-free HTTP client beats a heavy SDK nobody else in this repo uses.
 *
 * OAuth2 client-credentials tokens are cached in memory and refreshed a
 * minute before they actually expire, so a burst of requests near expiry
 * doesn't all miss the cache at once.
 */

let cachedToken = null; // { value, expiresAt }

async function getAccessToken() {
  if (cachedToken && cachedToken.expiresAt > Date.now()) return cachedToken.value;

  const auth = Buffer.from(`${config.paypal.clientId}:${config.paypal.clientSecret}`).toString('base64');
  const res = await fetch(`${config.paypal.baseUrl}/v1/oauth2/token`, {
    method: 'POST',
    headers: {
      authorization: `Basic ${auth}`,
      'content-type': 'application/x-www-form-urlencoded',
    },
    body: 'grant_type=client_credentials',
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    throw new Error(`paypal oauth2 ${res.status}: ${detail.slice(0, 200)}`);
  }
  const body = await res.json();
  cachedToken = { value: body.access_token, expiresAt: Date.now() + (body.expires_in - 60) * 1000 };
  return cachedToken.value;
}

class PaypalError extends Error {
  constructor(status, body) {
    super(`paypal ${status}: ${JSON.stringify(body).slice(0, 300)}`);
    this.status = status;
    this.body = body;
  }
}

/**
 * `idempotencyKey` maps to PayPal's `PayPal-Request-Id` header — the same
 * `booking:{id}:{action}` convention every call carried under Stripe
 * (CLAUDE.md invariant #9), just handed to a different header name.
 */
async function request(path, { method = 'GET', body, idempotencyKey } = {}) {
  const token = await getAccessToken();
  const headers = {
    authorization: `Bearer ${token}`,
    'content-type': 'application/json',
  };
  if (idempotencyKey) headers['PayPal-Request-Id'] = idempotencyKey;

  const res = await fetch(`${config.paypal.baseUrl}${path}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });

  const text = await res.text();
  const json = text ? JSON.parse(text) : {};
  if (!res.ok) {
    logger.warn({ path, status: res.status, body: json }, 'paypal request failed');
    throw new PaypalError(res.status, json);
  }
  return json;
}

export const paypal = { request, PaypalError };
