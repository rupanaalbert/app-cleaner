import test from 'node:test';
import assert from 'node:assert/strict';

import {
  sizeTierAdjustment, demandMultipliers, trustAndSafetyFee,
  composeQuote, authorizationAmount, cancellationOutcome,
} from '../src/domain/pricing.math.js';

/**
 * These cover the pure math only — no database, no PayPal. That's deliberate:
 * pricing is where a rounding slip becomes a refund queue, and a test that
 * needs a live Postgres is a test nobody runs before pushing.
 */

const RULES = {
  base_cents: 4900,
  per_bedroom_cents: 1200,
  per_bathroom_cents: 1500,
  size_tiers: [
    { max_sqft: 1000, adj_cents: 0 },
    { max_sqft: 1500, adj_cents: 800 },
    { max_sqft: 2000, adj_cents: 1500 },
    { max_sqft: 3000, adj_cents: 2800 },
    { max_sqft: null, adj_cents: 4500 },
  ],
  commission_bps: 2000,
  weekend_bps: 11500,
  evening_bps: 11000,
  demand_cap_bps: 15000,
  ts_fee_flat_cents: 349,
  ts_fee_bps: 100,
  ts_fee_cap_cents: 999,
};

const LIMITS = { lateCancelHours: 12, lateCancelShareBps: 5000 };

const saturdayMorning = new Date('2026-08-22T14:00:00Z'); // 10:00 America/New_York
const tuesdayMorning = new Date('2026-08-18T14:00:00Z');
const weekdayEvening = new Date('2026-08-19T00:00:00Z');  // Tue 20:00 New York

test('size tiers pick the first bucket that fits', () => {
  assert.equal(sizeTierAdjustment(RULES, 900), 0);
  assert.equal(sizeTierAdjustment(RULES, 1000), 0, 'boundary is inclusive');
  assert.equal(sizeTierAdjustment(RULES, 1001), 800);
  assert.equal(sizeTierAdjustment(RULES, 1600), 1500);
  assert.equal(sizeTierAdjustment(RULES, 99_999), 4500, 'open-ended top tier');
  assert.equal(sizeTierAdjustment(RULES, null), 0, 'square footage is optional');
});

test('weekend surcharge applies on Saturday and not on Tuesday', () => {
  const weekend = demandMultipliers(RULES, saturdayMorning);
  assert.equal(weekend.combinedBps, 11500);
  assert.deepEqual(weekend.applied.map((m) => m.code), ['weekend']);

  const weekday = demandMultipliers(RULES, tuesdayMorning);
  assert.equal(weekday.combinedBps, 10000);
  assert.deepEqual(weekday.applied, []);
});

test('evening surcharge applies on its own on a weekday', () => {
  const { combinedBps, applied } = demandMultipliers(RULES, weekdayEvening);
  assert.deepEqual(applied.map((m) => m.code), ['evening']);
  assert.equal(combinedBps, 11000);
});

test('stacked multipliers never exceed the cap', () => {
  const greedy = { ...RULES, weekend_bps: 14000, evening_bps: 14000, demand_cap_bps: 15000 };
  const { combinedBps, applied } = demandMultipliers(greedy, new Date('2026-08-23T01:00:00Z'));
  assert.equal(combinedBps, 15000, '1.4 x 1.4 = 1.96 must be clamped to 1.5');
  assert.ok(applied.some((m) => m.code === 'cap_applied'), 'the cap is disclosed, not silent');
});

test('trust and safety fee is flat plus a percentage, capped', () => {
  assert.equal(trustAndSafetyFee(RULES, 14_950), 499, '349 + round(1% of 14950) = 349 + 150');
  assert.equal(trustAndSafetyFee(RULES, 0), 349, 'flat component always applies');
  assert.equal(trustAndSafetyFee(RULES, 200_000), 999, 'capped, not unbounded');
});

test('the worked example from the README still holds', () => {
  // 3 bed / 2 bath, 1600 sq ft, Standard Clean, Saturday 10:00
  const pre = RULES.base_cents + 3 * RULES.per_bedroom_cents + 2 * RULES.per_bathroom_cents
    + sizeTierAdjustment(RULES, 1600);
  assert.equal(pre, 13_000);

  const { combinedBps } = demandMultipliers(RULES, saturdayMorning);
  const subtotal = Math.round((pre * combinedBps) / 10_000);
  assert.equal(subtotal, 14_950);

  const tsFee = trustAndSafetyFee(RULES, subtotal);
  assert.equal(subtotal + tsFee, 15_449, 'customer pays $154.49');

  const commission = Math.round((subtotal * RULES.commission_bps) / 10_000);
  assert.equal(commission, 2_990);
  assert.equal(subtotal - commission, 11_960, 'cleaner receives $119.60');

  // Commission is taken on the subtotal only — never on the safety fee.
  assert.notEqual(commission, Math.round(((subtotal + tsFee) * 2000) / 10_000));
});

test('authorization carries a buffer above the quote', () => {
  assert.equal(authorizationAmount(15_449, 1000), 16_994, '10% headroom for overage');
});

test('cancellation is free outside the window and split inside it', () => {
  const booking = {
    scheduled_at: new Date(Date.now() + 48 * 3_600_000),
    total_cents: 15_449,
    subtotal_cents: 14_950,
    cleaner_id: 'someone',
  };

  const early = cancellationOutcome(booking, LIMITS);
  assert.deepEqual(early, { fee_cents: 0, cleaner_cents: 0, refund_cents: 15_449 });

  const late = cancellationOutcome({
    ...booking, scheduled_at: new Date(Date.now() + 2 * 3_600_000),
  }, LIMITS);
  assert.equal(late.fee_cents, 7_475, '50% of subtotal');
  assert.equal(late.cleaner_cents, late.fee_cents, 'the fee goes to the cleaner, not the platform');
  assert.equal(late.fee_cents + late.refund_cents, booking.total_cents, 'money is conserved');
});

test('an unassigned booking cancels free even inside the window', () => {
  const outcome = cancellationOutcome({
    scheduled_at: new Date(Date.now() + 3_600_000),
    total_cents: 11_230, subtotal_cents: 10_800, cleaner_id: null,
  }, LIMITS);
  assert.equal(outcome.fee_cents, 0, 'nobody lost a slot, so nobody is owed');
});
