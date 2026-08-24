#!/usr/bin/env node
/**
 * Standalone PayPal sandbox spike — exercises the exact request shapes
 * payment.service.js / onboarding.service.js send, and prints the exact
 * response shapes PayPal sends back, so they can be checked against what
 * webhook.service.js assumes. Deliberately independent of src/config and
 * src/db/pool — no Postgres needed, just PAYPAL_* from backend/.env.
 *
 * Usage: node --env-file=.env scripts/paypal-sandbox-spike.mjs <command> [...args]
 *   token
 *   create-order <amountCents> <reference>
 *   order <orderId>                              # GET order, show status + links
 *   authorize <orderId>
 *   capture <authorizationId> <amountCents>
 *   void <authorizationId>
 *   refund <captureId> <amountCents>
 *   payout-verify <cleanerId> <email>
 *   payout-batch <email> <amountCents>
 *   events [eventType] [pageSize]
 *   event <eventId>
 */

const BASE = 'https://api-m.sandbox.paypal.com';
const centsToDecimal = (c) => (c / 100).toFixed(2);

let cachedToken = null;
async function getAccessToken() {
  if (cachedToken && cachedToken.expiresAt > Date.now()) return cachedToken.value;
  const auth = Buffer.from(`${process.env.PAYPAL_CLIENT_ID}:${process.env.PAYPAL_CLIENT_SECRET}`).toString('base64');
  const res = await fetch(`${BASE}/v1/oauth2/token`, {
    method: 'POST',
    headers: { authorization: `Basic ${auth}`, 'content-type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=client_credentials',
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`oauth2 ${res.status}: ${JSON.stringify(body)}`);
  cachedToken = { value: body.access_token, expiresAt: Date.now() + (body.expires_in - 60) * 1000 };
  return cachedToken.value;
}

async function req(path, { method = 'GET', body, idempotencyKey } = {}) {
  const token = await getAccessToken();
  const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
  if (idempotencyKey) headers['PayPal-Request-Id'] = idempotencyKey;
  const res = await fetch(`${BASE}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await res.text();
  const json = text ? JSON.parse(text) : {};
  return { status: res.status, ok: res.ok, json };
}

function show(label, result) {
  console.log(`\n=== ${label} (HTTP ${result.status}) ===`);
  console.log(JSON.stringify(result.json, null, 2));
  if (!result.ok) process.exitCode = 1;
}

const [, , cmd, ...args] = process.argv;

switch (cmd) {
  case 'token': {
    const token = await getAccessToken();
    console.log('access_token:', token.slice(0, 20) + '...');
    break;
  }

  case 'create-order': {
    const [amountCents, reference] = args;
    const result = await req('/v2/checkout/orders', {
      method: 'POST',
      idempotencyKey: `order:${reference}:create`,
      body: {
        intent: 'AUTHORIZE',
        purchase_units: [{
          reference_id: reference,
          amount: { currency_code: 'USD', value: centsToDecimal(Number(amountCents)) },
        }],
        application_context: {
          // sparkle:// won't resolve in a browser — swapped for an https url
          // purely so the spike can complete the buyer approval redirect.
          return_url: 'https://example.com/booking/paypal/return',
          cancel_url: 'https://example.com/booking/paypal/cancel',
          user_action: 'PAY_NOW',
        },
      },
    });
    show('create-order', result);
    const approve = result.json.links?.find((l) => l.rel === 'approve')?.href;
    if (approve) console.log('\napprove_url:', approve);
    break;
  }

  case 'order': {
    const [orderId] = args;
    show('order', await req(`/v2/checkout/orders/${orderId}`));
    break;
  }

  case 'authorize': {
    const [orderId] = args;
    const result = await req(`/v2/checkout/orders/${orderId}/authorize`, {
      method: 'POST',
      idempotencyKey: `booking:spike-${orderId}:authorize`,
    });
    show('authorize', result);
    break;
  }

  case 'capture': {
    const [authorizationId, amountCents] = args;
    const result = await req(`/v2/payments/authorizations/${authorizationId}/capture`, {
      method: 'POST',
      idempotencyKey: `booking:spike-${authorizationId}:capture`,
      body: { amount: { currency_code: 'USD', value: centsToDecimal(Number(amountCents)) }, final_capture: true },
    });
    show('capture', result);
    break;
  }

  case 'void': {
    const [authorizationId] = args;
    const result = await req(`/v2/payments/authorizations/${authorizationId}/void`, {
      method: 'POST',
      idempotencyKey: `booking:spike-${authorizationId}:void`,
    });
    show('void', result);
    break;
  }

  case 'refund': {
    const [captureId, amountCents] = args;
    const result = await req(`/v2/payments/captures/${captureId}/refund`, {
      method: 'POST',
      idempotencyKey: `payment:spike-${captureId}:refund:${amountCents}`,
      body: { amount: { currency_code: 'USD', value: centsToDecimal(Number(amountCents)) } },
    });
    show('refund', result);
    break;
  }

  case 'payout-verify': {
    const [cleanerId, email] = args;
    const result = await req('/v1/payments/payouts', {
      method: 'POST',
      idempotencyKey: `verify:${cleanerId}`,
      body: {
        sender_batch_header: { sender_batch_id: `verify:${cleanerId}:${Date.now()}`, email_subject: 'Confirming your Sparkle payout details' },
        items: [{
          recipient_type: 'EMAIL', receiver: email, sender_item_id: `verify:${cleanerId}`,
          amount: { value: '0.01', currency: 'USD' }, note: 'Verifying this email can receive Sparkle payouts.',
        }],
      },
    });
    show('payout-verify', result);
    break;
  }

  case 'payout-batch': {
    const [email, amountCents] = args;
    const batchId = `disburse:spike:${Date.now()}`;
    const result = await req('/v1/payments/payouts', {
      method: 'POST',
      idempotencyKey: batchId,
      body: {
        sender_batch_header: { sender_batch_id: batchId, email_subject: "You've been paid by Sparkle" },
        items: [{
          recipient_type: 'EMAIL', receiver: email, sender_item_id: `payout:spike-${Date.now()}`,
          amount: { value: centsToDecimal(Number(amountCents)), currency: 'USD' },
        }],
      },
    });
    show('payout-batch', result);
    break;
  }

  case 'payout-item': {
    const [payoutItemId] = args;
    show('payout-item', await req(`/v1/payments/payouts-item/${payoutItemId}`));
    break;
  }

  case 'events': {
    const [eventType, pageSize = '20'] = args;
    const qs = new URLSearchParams({ page_size: pageSize, total_required: 'true' });
    if (eventType) qs.set('event_type', eventType);
    const result = await req(`/v1/notifications/webhooks-events?${qs}`);
    console.log(`\n=== events (HTTP ${result.status}) ===`);
    for (const e of result.json.events ?? []) {
      console.log(`${e.create_time}  ${e.event_type.padEnd(32)} id=${e.id} resource_type=${e.resource_type}`);
    }
    if (!result.ok) console.log(JSON.stringify(result.json, null, 2));
    break;
  }

  case 'event': {
    const [eventId] = args;
    show('event', await req(`/v1/notifications/webhooks-events/${eventId}`));
    break;
  }

  default:
    console.error(`unknown command: ${cmd}`);
    console.error('see the usage comment at the top of this file');
    process.exitCode = 1;
}
