// Integration tests for the booking state machine — BACKLOG.md item 1.
//
// The unit suite (test/*.test.js) covers the pricing/ranking arithmetic in
// src/domain/*. Nothing there ever touches Postgres, and that is deliberate.
// This file is the other half: the concurrency, transition, and constraint
// behaviour that only means anything against a real database. It needs a
// migrated Postgres+PostGIS at DATABASE_URL (run `npm run migrate:up` first)
// and is kept out of `npm test` behind `npm run test:integration`.
//
// External collaborators are neutralised, not exercised: Firebase fan-out
// (RealtimeService) and the BullMQ enqueues are stubbed in `before`, and the
// Redis socket queues.js opens at import is dropped immediately below. Stripe
// is never reached — every case here asserts a rejection that fires before the
// capture/transfer path. The subject under test is the state machine.

import '../helpers/env.js'; // must be first: seeds process.env before config parses

import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import { pool, query } from '../../src/db/pool.js';
import { connection, matchQueue, privacyQueue } from '../../src/jobs/queues.js';
import { MatchingService } from '../../src/services/matching.service.js';
import { BookingService } from '../../src/services/booking.service.js';
import { RealtimeService } from '../../src/services/realtime.service.js';

// queues.js opens an eager ioredis connection at import. These tests don't use
// Redis; with none listening it would emit an unhandled 'error' (crashing the
// process) and retry forever (keeping it alive). Swallow the error and drop the
// socket synchronously, before ioredis's first async connect attempt fires.
connection.on('error', () => {});
connection.disconnect();

// ---------------------------------------------------------------- fixtures ---
// Created rows are tracked and torn down in `after`, so the suite is safe to run
// against a seeded database without colliding with or deleting seed data.

const createdUserIds = [];
const createdBookingIds = [];

const PROP = { lng: -71.1909, lat: 42.7262 }; // Methuen, matching the dev seed

async function makeCustomer({ lng = PROP.lng, lat = PROP.lat, beds = 2, baths = 1, sqft = 1200 } = {}) {
  const { rows: [u] } = await query(
    `INSERT INTO users (role, email, full_name, status, email_verified_at)
     VALUES ('customer',$1,'IT Customer','active', now()) RETURNING id`,
    [`it-cust-${randomUUID()}@example.com`],
  );
  createdUserIds.push(u.id);
  await query(
    `INSERT INTO customer_profiles (user_id, stripe_customer_id) VALUES ($1,$2)`,
    [u.id, `cus_it_${u.id.slice(0, 8)}`],
  );
  const { rows: [a] } = await query(
    `INSERT INTO addresses (user_id, line1, city, region, postal_code, location)
     VALUES ($1,'1 Test St','Methuen','MA','01844',
             ST_SetSRID(ST_MakePoint($2,$3),4326)::geography) RETURNING id`,
    [u.id, lng, lat],
  );
  const { rows: [p] } = await query(
    `INSERT INTO properties (customer_id, address_id, bedrooms, bathrooms, square_feet)
     VALUES ($1,$2,$3,$4,$5) RETURNING id`,
    [u.id, a.id, beds, baths, sqft],
  );
  return { customerId: u.id, propertyId: p.id, addressId: a.id, lng, lat };
}

async function makeCleaner({ lng = PROP.lng, lat = PROP.lat } = {}) {
  const { rows: [u] } = await query(
    `INSERT INTO users (role, email, full_name, status, email_verified_at)
     VALUES ('cleaner',$1,'IT Cleaner','active', now()) RETURNING id`,
    [`it-clnr-${randomUUID()}@example.com`],
  );
  createdUserIds.push(u.id);
  await query(
    `INSERT INTO cleaner_profiles
       (user_id, stripe_account_id, payouts_enabled, onboarding_status, bg_status,
        bg_completed_at, bg_expires_at, service_types, home_location,
        service_radius_km, is_available)
     VALUES ($1,$2,true,'approved','clear', now()-interval '10 days', now()+interval '300 days',
             '{standard,deep}', ST_SetSRID(ST_MakePoint($3,$4),4326)::geography, 25, true)`,
    [u.id, `acct_it_${u.id.slice(0, 8)}`, lng, lat],
  );
  return u.id;
}

async function makeQuote({ customerId, propertyId, serviceCode, scheduledAt, durationMin }) {
  const { rows: [r] } = await query(
    `SELECT id FROM pricing_rules WHERE metro='default' ORDER BY effective_from DESC LIMIT 1`,
  );
  const { rows: [q] } = await query(
    `INSERT INTO quotes (customer_id, property_id, service_code, scheduled_at, duration_min,
                         pricing_rule_id, subtotal_cents, ts_fee_cents, tax_cents, total_cents,
                         breakdown, expires_at)
     VALUES ($1,$2,$3,$4,$5,$6,10000,349,0,10349,'{}'::jsonb, now()+interval '1 hour') RETURNING id`,
    [customerId, propertyId, serviceCode, scheduledAt, durationMin, r.id],
  );
  return q.id;
}

// Money satisfies the bookings CHECKs: total = subtotal+ts_fee+tax (10349 =
// 10000+349+0) and subtotal = commission+payout (10000 = 2000+8000).
async function makeBooking({
  customerId, propertyId, cleanerId = null, status,
  serviceCode = 'standard', scheduledAt, durationMin = 120,
}) {
  const quoteId = await makeQuote({ customerId, propertyId, serviceCode, scheduledAt, durationMin });
  const { rows: [b] } = await query(
    `INSERT INTO bookings (reference, customer_id, cleaner_id, property_id, quote_id, service_code,
                           status, scheduled_at, duration_min,
                           subtotal_cents, ts_fee_cents, tax_cents, total_cents,
                           commission_cents, payout_cents)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,10000,349,0,10349,2000,8000) RETURNING *`,
    [`SPK-${randomUUID().slice(0, 6).toUpperCase()}`, customerId, cleanerId, propertyId, quoteId,
      serviceCode, status, scheduledAt, durationMin],
  );
  createdBookingIds.push(b.id);
  return b;
}

async function makeOffer({ bookingId, cleanerId, status = 'sent', ttlSeconds = 90 }) {
  const { rows: [o] } = await query(
    `INSERT INTO booking_offers
       (booking_id, cleaner_id, round, score, distance_km, payout_cents, status, expires_at)
     VALUES ($1,$2,1,0.9000,3.00,8000,$3, now() + ($4 || ' seconds')::interval) RETURNING id`,
    [bookingId, cleanerId, status, String(ttlSeconds)],
  );
  return o.id;
}

const soon = () => new Date(Date.now() + 2 * 86_400_000); // 2 days out, clear of min lead time

// ------------------------------------------------------------- lifecycle -----

before(async () => {
  // The state machine is the subject; the fan-out and enqueues it triggers are
  // not. Stub them so a successful accept/transition doesn't reach into
  // Firebase or BullMQ.
  RealtimeService.grantAccess = async () => {};
  RealtimeService.publishStatus = async () => {};
  matchQueue.add = async () => {};
  privacyQueue.add = async () => {};

  try {
    await query('SELECT 1 FROM bookings LIMIT 1');
  } catch (err) {
    throw new Error(
      'Integration tests need a migrated Postgres+PostGIS at DATABASE_URL '
      + `(${process.env.DATABASE_URL}). Run \`npm run migrate:up\` first. Underlying: ${err.message}`,
    );
  }
});

after(async () => {
  // Delete children before parents: bookings hold RESTRICT refs to quotes,
  // properties, cleaner_profiles and customer users, so they go first.
  if (createdBookingIds.length) {
    await query('DELETE FROM bookings WHERE id = ANY($1::uuid[])', [createdBookingIds]);
  }
  if (createdUserIds.length) {
    await query('DELETE FROM quotes     WHERE customer_id = ANY($1::uuid[])', [createdUserIds]);
    await query('DELETE FROM properties WHERE customer_id = ANY($1::uuid[])', [createdUserIds]);
    await query('DELETE FROM addresses  WHERE user_id     = ANY($1::uuid[])', [createdUserIds]);
    await query('DELETE FROM users      WHERE id          = ANY($1::uuid[])', [createdUserIds]);
  }
  await pool.end();
  connection.disconnect();
});

// ------------------------------------------------------------------ tests ----

test('two cleaners accept the same job: exactly one wins, the loser gets 409 OFFER_TAKEN', async () => {
  const { customerId, propertyId } = await makeCustomer();
  const cleanerA = await makeCleaner();
  const cleanerB = await makeCleaner();
  const booking = await makeBooking({ customerId, propertyId, status: 'pending_match', scheduledAt: soon() });
  const offerA = await makeOffer({ bookingId: booking.id, cleanerId: cleanerA });
  const offerB = await makeOffer({ bookingId: booking.id, cleanerId: cleanerB });

  // Fire both claims into the same transaction window. FOR UPDATE SKIP LOCKED on
  // the pending_match booking row is what makes this deterministic.
  const results = await Promise.allSettled([
    MatchingService.acceptOffer(offerA, cleanerA),
    MatchingService.acceptOffer(offerB, cleanerB),
  ]);

  const winners = results.filter((r) => r.status === 'fulfilled');
  const losers = results.filter((r) => r.status === 'rejected');
  assert.equal(winners.length, 1, 'exactly one accept should succeed');
  assert.equal(losers.length, 1, 'exactly one accept should fail');

  assert.equal(losers[0].reason.status, 409, 'loser status');
  assert.equal(losers[0].reason.code, 'OFFER_TAKEN', 'loser code');

  const { rows: [b] } = await query('SELECT status, cleaner_id FROM bookings WHERE id = $1', [booking.id]);
  assert.equal(b.status, 'assigned');
  assert.equal(b.cleaner_id, winners[0].value.cleaner_id, 'booking assigned to the winner');

  const { rows: [{ accepted }] } = await query(
    `SELECT COUNT(*)::int AS accepted FROM booking_offers WHERE booking_id = $1 AND status = 'accepted'`,
    [booking.id],
  );
  assert.equal(accepted, 1, 'no second booking_offers row may flip to accepted');
});

test('every illegal transition in TRANSITIONS returns 409 ILLEGAL_TRANSITION', async () => {
  // Mirror of BookingService.TRANSITIONS. Kept here on purpose: if the service
  // map changes, this literal must change with it, and the diff is the review.
  const LEGAL = {
    draft: ['quoted', 'canceled'],
    quoted: ['pending_match', 'canceled'],
    pending_match: ['assigned', 'canceled'],
    assigned: ['en_route', 'canceled'],
    en_route: ['arrived', 'canceled'],
    arrived: ['in_progress', 'canceled'],
    in_progress: ['completed'],
    completed: ['settled', 'disputed'],
    settled: ['disputed'],
    canceled: [],
    disputed: ['settled'],
  };
  const ALL = Object.keys(LEGAL);

  // One booking, carrying a cleaner in every state so updateStatus reaches the
  // legality check (rather than the ownership guard). Its status is forced with
  // direct UPDATEs — illegal calls throw before mutating anything, so the row
  // stays put between attempts.
  const { customerId, propertyId } = await makeCustomer();
  const cleanerId = await makeCleaner();
  const booking = await makeBooking({ customerId, propertyId, cleanerId, status: 'assigned', scheduledAt: soon() });

  for (const from of ALL) {
    await query('UPDATE bookings SET status = $2 WHERE id = $1', [booking.id, from]);
    const illegal = ALL.filter((to) => !LEGAL[from].includes(to));
    for (const to of illegal) {
      await assert.rejects(
        // Location is supplied but never consulted: legality is checked before
        // the geofence, so this stays a 409 even for arrived/completed targets.
        () => BookingService.updateStatus(booking.id, cleanerId, to, { location: PROP }),
        (err) => {
          assert.equal(err.status, 409, `${from} -> ${to} expected 409, got ${err.status} ${err.code}`);
          assert.equal(err.code, 'ILLEGAL_TRANSITION', `${from} -> ${to} expected ILLEGAL_TRANSITION`);
          return true;
        },
        `${from} -> ${to} must be rejected`,
      );
    }
  }
});

test('no_double_booking rejects an overlapping live assignment for the same cleaner', async () => {
  const base = soon();
  base.setUTCHours(15, 0, 0, 0);
  const { customerId, propertyId } = await makeCustomer();
  const cleanerId = await makeCleaner();

  // First live job, 15:00–17:00.
  await makeBooking({ customerId, propertyId, cleanerId, status: 'assigned', scheduledAt: base, durationMin: 120 });

  // Second job at 16:00 overlaps → the exclusion constraint must reject it.
  const overlap = new Date(base.getTime() + 60 * 60_000);
  await assert.rejects(
    () => makeBooking({ customerId, propertyId, cleanerId, status: 'assigned', scheduledAt: overlap, durationMin: 120 }),
    (err) => {
      assert.equal(err.code, '23P01', `expected exclusion_violation (23P01), got ${err.code}`);
      return true;
    },
    'an overlapping assignment must violate no_double_booking',
  );

  // A non-overlapping job the next day is fine — the constraint is about overlap,
  // not about the cleaner holding more than one job ever.
  const nextDay = new Date(base.getTime() + 24 * 60 * 60_000);
  await makeBooking({ customerId, propertyId, cleanerId, status: 'assigned', scheduledAt: nextDay, durationMin: 120 });
});

test('arrival is geofenced: rejected far from the property, accepted at it', async () => {
  const { customerId, propertyId, lng, lat } = await makeCustomer();
  const cleanerId = await makeCleaner();
  const booking = await makeBooking({ customerId, propertyId, cleanerId, status: 'assigned', scheduledAt: soon() });

  // assigned -> en_route needs no location.
  await BookingService.updateStatus(booking.id, cleanerId, 'en_route', {});

  // en_route -> arrived from ~1.2 km north: outside the 150 m geofence.
  await assert.rejects(
    () => BookingService.updateStatus(booking.id, cleanerId, 'arrived', { location: { lat: lat + 0.011, lng } }),
    (err) => {
      assert.equal(err.status, 422);
      assert.equal(err.code, 'GEOFENCE_FAILED');
      return true;
    },
    'arriving from outside the geofence must be refused',
  );

  // Reported at the property → within the geofence → the transition lands. This
  // also proves the rejection above was about distance, not a blanket refusal.
  const ok = await BookingService.updateStatus(booking.id, cleanerId, 'arrived', { location: { lat, lng } });
  assert.equal(ok.status, 'arrived');
});

test('completing a Deep Clean without three after-photos returns 422 PHOTOS_REQUIRED', async () => {
  const { customerId, propertyId, lng, lat } = await makeCustomer();
  const cleanerId = await makeCleaner();
  const booking = await makeBooking({
    customerId, propertyId, cleanerId, status: 'in_progress', serviceCode: 'deep', scheduledAt: soon(),
  });

  // Two after-photos: one short of the gate for a photo-required service.
  for (let i = 0; i < 2; i++) {
    await query(
      `INSERT INTO job_photos (booking_id, phase, s3_key) VALUES ($1,'after',$2)`,
      [booking.id, `it/${booking.id}/after/${i}`],
    );
  }

  // Location is at the property, so the geofence passes and we reach the photo
  // gate — which must stop the completion before any capture/transfer runs.
  await assert.rejects(
    () => BookingService.updateStatus(booking.id, cleanerId, 'completed', { location: { lat, lng } }),
    (err) => {
      assert.equal(err.status, 422);
      assert.equal(err.code, 'PHOTOS_REQUIRED');
      return true;
    },
    'a Deep Clean with fewer than three after-photos must not complete',
  );
});
