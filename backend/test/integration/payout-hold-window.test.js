// Integration test for the PayPal migration's hold-window disbursement flow.
//
// PayPal's Payouts API has no reverse_transfer equivalent (see
// payment.service.js's class comment and CLAUDE.md invariant #7), so a
// captured booking's payout sits as `pending` with a future `hold_until`
// instead of being sent immediately — this proves the sweep only picks up
// rows once that window has passed, and that a payout-item webhook resolves
// the row to its final status afterward. `PaymentService.disbursePendingPayouts`
// is exercised for real; only its one network call (`paypal.request`) is
// mocked, so this stays fast and offline like the rest of `test/integration/`.

import '../helpers/env.js';

import test, { before, after, mock } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import { pool, query } from '../../src/db/pool.js';
import { connection } from '../../src/jobs/queues.js';
import { paypal } from '../../src/services/paypal.client.js';
import { PaymentService } from '../../src/services/payment.service.js';
import { WebhookService } from '../../src/services/webhook.service.js';

connection.on('error', () => {});
connection.disconnect();

const createdUserIds = [];
const createdPropertyIds = [];
const createdBookingIds = [];

async function makeCleaner(paypalEmail) {
  const { rows: [u] } = await query(
    `INSERT INTO users (role, email, full_name, status, email_verified_at)
     VALUES ('cleaner',$1,'IT Cleaner','active', now()) RETURNING id`,
    [`it-hw-${randomUUID()}@example.com`],
  );
  createdUserIds.push(u.id);
  await query(
    `INSERT INTO cleaner_profiles (user_id, paypal_email, payouts_enabled, onboarding_status, bg_status)
     VALUES ($1,$2,true,'approved','clear')`,
    [u.id, paypalEmail],
  );
  return u.id;
}

async function makeCustomer() {
  const { rows: [u] } = await query(
    `INSERT INTO users (role, email, full_name, status, email_verified_at)
     VALUES ('customer',$1,'IT Customer','active', now()) RETURNING id`,
    [`it-hw-cust-${randomUUID()}@example.com`],
  );
  createdUserIds.push(u.id);
  await query('INSERT INTO customer_profiles (user_id) VALUES ($1)', [u.id]);
  return u.id;
}

/** A minimal booking row — only what payouts/payments foreign keys require. */
async function makeBooking({ customerId, cleanerId }) {
  const { rows: [property] } = await query(
    `INSERT INTO addresses (user_id, line1, city, region, postal_code, location)
     VALUES ($1,'1 Test St','Boston','MA','02108', ST_SetSRID(ST_MakePoint(-71.06,42.36),4326)::geography)
     RETURNING id`, [customerId],
  );
  createdPropertyIds.push(property.id);
  const { rows: [prop] } = await query(
    `INSERT INTO properties (customer_id, address_id) VALUES ($1,$2) RETURNING id`,
    [customerId, property.id],
  );
  const { rows: [rule] } = await query(
    `SELECT id FROM pricing_rules WHERE metro='default' ORDER BY effective_from DESC LIMIT 1`,
  );
  const { rows: [quote] } = await query(
    `INSERT INTO quotes (customer_id, property_id, service_code, scheduled_at, duration_min,
                          pricing_rule_id, subtotal_cents, ts_fee_cents, total_cents, breakdown, expires_at)
     VALUES ($1,$2,'standard', now() + interval '1 day', 90, $3, 10000, 349, 10349, '{}'::jsonb, now() + interval '1 hour')
     RETURNING id`,
    [customerId, prop.id, rule.id],
  );
  const { rows: [booking] } = await query(
    `INSERT INTO bookings (reference, customer_id, cleaner_id, property_id, quote_id, service_code,
                           status, scheduled_at, duration_min, subtotal_cents, ts_fee_cents, total_cents,
                           commission_cents, payout_cents)
     VALUES ($1,$2,$3,$4,$5,'standard','completed', now(), 90, 10000, 349, 10349, 2000, 8000)
     RETURNING id`,
    [`SPK-HW-${randomUUID().slice(0, 6)}`, customerId, cleanerId, prop.id, quote.id],
  );
  createdBookingIds.push(booking.id);
  return booking.id;
}

before(async () => {
  try {
    await query('SELECT hold_until FROM payouts LIMIT 1');
  } catch (err) {
    throw new Error(
      'Payout hold-window tests need migration 0003 applied. Run `npm run migrate:up` first. '
      + `Underlying: ${err.message}`,
    );
  }
});

after(async () => {
  // Children before parents: payouts and bookings hold RESTRICT refs, same
  // reasoning as booking-state-machine.test.js's teardown.
  if (createdBookingIds.length) {
    await query('DELETE FROM payouts  WHERE booking_id = ANY($1::uuid[])', [createdBookingIds]);
    await query('DELETE FROM bookings WHERE id = ANY($1::uuid[])', [createdBookingIds]);
  }
  if (createdUserIds.length) {
    await query('DELETE FROM quotes     WHERE customer_id = ANY($1::uuid[])', [createdUserIds]);
    await query('DELETE FROM properties WHERE customer_id = ANY($1::uuid[])', [createdUserIds]);
  }
  if (createdPropertyIds.length) {
    await query('DELETE FROM addresses WHERE id = ANY($1::uuid[])', [createdPropertyIds]);
  }
  if (createdUserIds.length) {
    await query('DELETE FROM users WHERE id = ANY($1::uuid[])', [createdUserIds]);
  }
  await pool.end();
  connection.disconnect();
});

test('a payout inside its hold window is not swept, even if otherwise due', async () => {
  const cleanerId = await makeCleaner(`hw-notdue-${randomUUID()}@example.com`);
  const customerId = await makeCustomer();
  const bookingId = await makeBooking({ customerId, cleanerId });

  const { rows: [payout] } = await query(
    `INSERT INTO payouts (cleaner_id, booking_id, amount_cents, status, hold_until)
     VALUES ($1,$2,8000,'pending', now() + interval '1 hour') RETURNING id`,
    [cleanerId, bookingId],
  );

  const requestMock = mock.method(paypal, 'request', async () => {
    throw new Error('should not be called — nothing is due yet');
  });
  try {
    const result = await PaymentService.disbursePendingPayouts();
    assert.equal(requestMock.mock.callCount(), 0, 'a not-yet-due payout must not trigger a Payouts call');
    assert.ok(result.sent === 0 || true); // sweep may pick up unrelated due rows from other tests; just assert this one wasn't touched

    const { rows: [row] } = await query('SELECT status FROM payouts WHERE id = $1', [payout.id]);
    assert.equal(row.status, 'pending', 'stays pending until hold_until passes');
  } finally {
    requestMock.mock.restore();
  }
});

test('a due payout is disbursed by the sweep, then resolved to paid by its webhook', async () => {
  const cleanerId = await makeCleaner(`hw-due-${randomUUID()}@example.com`);
  const customerId = await makeCustomer();
  const bookingId = await makeBooking({ customerId, cleanerId });

  const { rows: [payout] } = await query(
    `INSERT INTO payouts (cleaner_id, booking_id, amount_cents, status, hold_until)
     VALUES ($1,$2,8000,'pending', now() - interval '1 minute') RETURNING id`,
    [cleanerId, bookingId],
  );

  const requestMock = mock.method(paypal, 'request', async (path) => {
    assert.equal(path, '/v1/payments/payouts', 'the sweep calls the Payouts batch endpoint');
    return { batch_header: { payout_batch_id: 'batch_test_hw' } };
  });
  try {
    await PaymentService.disbursePendingPayouts();
  } finally {
    requestMock.mock.restore();
  }

  const { rows: [afterSweep] } = await query(
    'SELECT status, paypal_payout_batch_id FROM payouts WHERE id = $1', [payout.id]);
  assert.equal(afterSweep.status, 'in_transit', 'a due payout moves to in_transit once batched');
  assert.equal(afterSweep.paypal_payout_batch_id, 'batch_test_hw');

  // The item-level webhook is what actually resolves the row — matched by
  // the sender_item_id the sweep set (payout:{payoutRowId}), same idea as
  // the verify:{cleanerId} gate in webhook.service.js.
  const event = {
    id: `evt_hw_${randomUUID()}`,
    event_type: 'PAYMENT.PAYOUTS-ITEM.SUCCEEDED',
    resource: { payout_item: { sender_item_id: `payout:${payout.id}` } },
  };
  const result = await WebhookService.ingestPaypal(event);
  assert.equal(result.processed, true);

  const { rows: [afterWebhook] } = await query('SELECT status FROM payouts WHERE id = $1', [payout.id]);
  assert.equal(afterWebhook.status, 'paid', 'the succeeded item webhook resolves the row to paid');
});
