// Integration tests for Stripe webhook replay — BACKLOG.md item 3.
//
// Exercises WebhookService.replayStripe against a real database: a due failure
// gets reprocessed (and its side effect lands), a handler that throws again is
// backed off and its attempt counted, and rows that are poison-pilled or not
// yet due are left alone. Same harness as booking-state-machine.test.js —
// needs a migrated Postgres, drops the eager Redis socket, no Stripe/Firebase.

import '../helpers/env.js';

import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import { pool, query } from '../../src/db/pool.js';
import { connection } from '../../src/jobs/queues.js';
import { config } from '../../src/config/index.js';
import { WebhookService } from '../../src/services/webhook.service.js';

connection.on('error', () => {});
connection.disconnect();

const createdUserIds = [];
const createdEventIds = [];

async function makeCleaner({ accountId, payoutsEnabled = false }) {
  const { rows: [u] } = await query(
    `INSERT INTO users (role, email, full_name, status, email_verified_at)
     VALUES ('cleaner',$1,'IT Cleaner','active', now()) RETURNING id`,
    [`it-wh-${randomUUID()}@example.com`],
  );
  createdUserIds.push(u.id);
  await query(
    `INSERT INTO cleaner_profiles (user_id, stripe_account_id, payouts_enabled, onboarding_status, bg_status)
     VALUES ($1,$2,$3,'approved','clear')`,
    [u.id, accountId, payoutsEnabled],
  );
  return u.id;
}

// Insert a webhook_events row already in the failed state the replay sweep looks
// for: unprocessed, with an error, and (by default) due.
async function makeFailedEvent({ type, object, attempts = 0, dueInSeconds = -60, error = 'initial failure' }) {
  const id = `evt_it_${randomUUID().replace(/-/g, '')}`;
  createdEventIds.push(id);
  await query(
    `INSERT INTO webhook_events (id, provider, event_type, payload, error, attempts, next_attempt_at)
     VALUES ($1,'stripe',$2,$3,$4,$5, now() + ($6 || ' seconds')::interval)`,
    [id, type, { id, type, data: { object } }, error, attempts, String(dueInSeconds)],
  );
  return id;
}

const eventRow = async (id) => (await query('SELECT * FROM webhook_events WHERE id = $1', [id])).rows[0];

before(async () => {
  try {
    await query('SELECT attempts, next_attempt_at FROM webhook_events LIMIT 1');
  } catch (err) {
    throw new Error(
      'Webhook replay tests need a migrated Postgres at DATABASE_URL '
      + `(${process.env.DATABASE_URL}). Run \`npm run migrate:up\` first (0002 adds the replay columns). `
      + `Underlying: ${err.message}`,
    );
  }
});

after(async () => {
  if (createdEventIds.length) {
    await query('DELETE FROM webhook_events WHERE id = ANY($1::text[])', [createdEventIds]);
  }
  if (createdUserIds.length) {
    await query('DELETE FROM users WHERE id = ANY($1::uuid[])', [createdUserIds]);
  }
  await pool.end();
  connection.disconnect();
});

test('a due failure is replayed: handler re-runs, side effect lands, row is marked processed', async () => {
  const accountId = `acct_it_${randomUUID().slice(0, 12)}`;
  const cleanerId = await makeCleaner({ accountId, payoutsEnabled: false });
  const eventId = await makeFailedEvent({
    type: 'account.updated',
    object: { id: accountId, payouts_enabled: true, charges_enabled: true },
  });

  const result = await WebhookService.replayStripe();
  assert.ok(result.ok >= 1, 'at least our event should have been processed');

  const row = await eventRow(eventId);
  assert.ok(row.processed_at, 'event should be marked processed');
  assert.equal(row.error, null, 'the error should be cleared on success');
  assert.equal(row.attempts, 1, 'one replay attempt counted');

  const { rows: [c] } = await query(
    'SELECT payouts_enabled FROM cleaner_profiles WHERE user_id = $1', [cleanerId]);
  assert.equal(c.payouts_enabled, true, 'account.updated should have gated payouts on');
});

test('a handler that throws again is backed off and its attempt counted, not marked processed', async () => {
  // amount_refunded is non-numeric, so the refunded_cents UPDATE fails on cast —
  // a deterministic handler failure with no matching payments row required.
  const eventId = await makeFailedEvent({
    type: 'charge.refunded',
    object: { id: 'ch_bogus', amount_refunded: 'not-a-number' },
    attempts: 0,
  });

  const result = await WebhookService.replayStripe();
  assert.ok(result.failed >= 1, 'the failing event should be counted as failed');

  const row = await eventRow(eventId);
  assert.equal(row.processed_at, null, 'a failed replay must not mark the event processed');
  assert.equal(row.attempts, 1, 'the attempt is counted so the poison-pill gate can close');
  assert.ok(row.error, 'the new error is recorded');
  assert.ok(new Date(row.next_attempt_at) > new Date(), 'the next attempt is pushed into the future (backoff)');
});

test('a poison-pilled event (attempts exhausted) is left for a human, not retried', async () => {
  const accountId = `acct_it_${randomUUID().slice(0, 12)}`;
  const cleanerId = await makeCleaner({ accountId, payoutsEnabled: false });
  const eventId = await makeFailedEvent({
    type: 'account.updated',
    object: { id: accountId, payouts_enabled: true, charges_enabled: true },
    attempts: config.webhooks.maxReplayAttempts, // at the threshold → never selected
  });

  await WebhookService.replayStripe();

  const row = await eventRow(eventId);
  assert.equal(row.processed_at, null, 'a poison-pilled event stays unprocessed');
  assert.equal(row.attempts, config.webhooks.maxReplayAttempts, 'its attempt count is untouched');

  const { rows: [c] } = await query(
    'SELECT payouts_enabled FROM cleaner_profiles WHERE user_id = $1', [cleanerId]);
  assert.equal(c.payouts_enabled, false, 'the handler that would fix it was never run');
});

test('an event not yet due (inside its backoff) is skipped', async () => {
  const accountId = `acct_it_${randomUUID().slice(0, 12)}`;
  const cleanerId = await makeCleaner({ accountId, payoutsEnabled: false });
  const eventId = await makeFailedEvent({
    type: 'account.updated',
    object: { id: accountId, payouts_enabled: true, charges_enabled: true },
    attempts: 2,
    dueInSeconds: 3600, // due in an hour
  });

  await WebhookService.replayStripe();

  const row = await eventRow(eventId);
  assert.equal(row.processed_at, null, 'a not-yet-due event stays unprocessed');
  assert.equal(row.attempts, 2, 'its attempt count is untouched');

  const { rows: [c] } = await query(
    'SELECT payouts_enabled FROM cleaner_profiles WHERE user_id = $1', [cleanerId]);
  assert.equal(c.payouts_enabled, false, 'skipped means the handler did not run');
});
