#!/usr/bin/env node
/**
 * Load-test the matching candidate query — BACKLOG item 10.
 *
 *   npm run loadtest:matching                 # 6,000 synthetic cleaners
 *   npm run loadtest:matching -- --cleaners 20000
 *   npm run loadtest:matching -- --keep       # leave the synthetic supply behind
 *
 * Generates N cleaners spread across the metro (all approved, clear, available,
 * open all week), one target booking, ANALYZEs, then runs EXPLAIN (ANALYZE,
 * BUFFERS) on the EXACT query production uses (matching.candidates.sql.js) and
 * prints the plan with a verdict. `findCandidates` does a PostGIS radius scan
 * plus three correlated subqueries per candidate; this shows how that plan
 * behaves at 6,000 before a customer is the one waiting on it.
 *
 * The ST_DWithin bound is a per-row radius, which a GiST index can't satisfy —
 * so the interesting question the plan answers is whether cleaner_profiles is
 * scanned or index-accessed. All synthetic rows are tagged `loadtest-*` and
 * removed on exit unless --keep.
 */
import { pool, query } from '../src/db/pool.js';
import { config } from '../src/config/index.js';
import { FIND_CANDIDATES_SQL } from '../src/services/matching.candidates.sql.js';

if (process.env.NODE_ENV === 'production') {
  console.error('Refusing to run the load test against a production database.');
  process.exit(1);
}

const argValue = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const CLEANERS = Math.max(1, Number(argValue('cleaners', '6000')));
const KEEP = process.argv.includes('--keep');
const TARGET_MS = Number(argValue('budget', '250')); // soft budget for a single dispatch scan

const CENTER = { lat: 42.72, lng: -71.16 }; // Merrimack Valley
const CLEANER_LIKE = 'loadtest-c-%@synthetic.invalid';
const ANY_LIKE = 'loadtest-%@synthetic.invalid';

async function seedSupply() {
  console.log(`• generating ${CLEANERS.toLocaleString()} synthetic cleaners…`);

  await query(
    `INSERT INTO users (role, email, full_name, status, email_verified_at)
     SELECT 'cleaner', 'loadtest-c-' || g || '@synthetic.invalid', 'LoadTest Cleaner ' || g, 'active', now()
       FROM generate_series(1, $1) g
     ON CONFLICT DO NOTHING`,
    [CLEANERS],
  );

  // Spread home locations ~±0.3° (roughly a 30–50 km box) so many fall inside a
  // 15–30 km service radius and many don't — the radius filter does real work.
  await query(
    `INSERT INTO cleaner_profiles
       (user_id, paypal_email, payouts_enabled, onboarding_status, bg_status,
        bg_completed_at, bg_expires_at, service_types, home_location, service_radius_km, is_available)
     SELECT u.id, 'loadtest-' || u.id || '@example.com', true, 'approved', 'clear',
            now() - interval '10 days', now() + interval '300 days',
            ARRAY['standard','deep'],
            ST_SetSRID(ST_MakePoint($2 + (random() - 0.5) * 0.6, $3 + (random() - 0.5) * 0.6), 4326)::geography,
            15 + (random() * 15)::numeric(5,2),
            true
       FROM users u
      WHERE u.email LIKE $1 AND u.role = 'cleaner'
     ON CONFLICT (user_id) DO NOTHING`,
    [CLEANER_LIKE, CENTER.lng, CENTER.lat],
  );

  // Open all week so the availability EXISTS never trivially eliminates a row.
  await query(
    `INSERT INTO cleaner_availability (cleaner_id, day_of_week, start_min, end_min)
     SELECT c.user_id, d, 0, 1440
       FROM cleaner_profiles c
       CROSS JOIN generate_series(0, 6) d
      WHERE c.user_id IN (SELECT id FROM users WHERE email LIKE $1)`,
    [CLEANER_LIKE],
  );

  // Rating snapshots so the LEFT JOIN and the is_dispatchable filter are exercised.
  await query(
    `INSERT INTO cleaner_rating_snapshot
       (cleaner_id, review_count, avg_rating, bayesian_rating, rating_last_20,
        completion_rate, acceptance_rate, jobs_completed, is_dispatchable)
     SELECT c.user_id, 12, 4.70, 4.70, 4.70, 0.97, 0.85, 12, true
       FROM cleaner_profiles c
      WHERE c.user_id IN (SELECT id FROM users WHERE email LIKE $1)
     ON CONFLICT (cleaner_id) DO NOTHING`,
    [CLEANER_LIKE],
  );
}

async function seedTargetBooking() {
  const { rows: [rules] } = await query(
    `SELECT id FROM pricing_rules WHERE metro = 'default' ORDER BY effective_from DESC LIMIT 1`);
  if (!rules) throw new Error('No pricing_rules found — apply migrations and seed the catalog first.');

  const { rows: [customer] } = await query(
    `INSERT INTO users (role, email, full_name, status, email_verified_at)
     VALUES ('customer', 'loadtest-cust-' || gen_random_uuid() || '@synthetic.invalid', 'LoadTest Customer', 'active', now())
     RETURNING id`);
  await query(`INSERT INTO customer_profiles (user_id) VALUES ($1)`, [customer.id]);

  const { rows: [address] } = await query(
    `INSERT INTO addresses (user_id, line1, city, region, postal_code, location)
     VALUES ($1, '1 Load Test Way', 'Methuen', 'MA', '01844',
             ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography)
     RETURNING id`,
    [customer.id, CENTER.lng, CENTER.lat],
  );
  const { rows: [property] } = await query(
    `INSERT INTO properties (customer_id, address_id, bedrooms, bathrooms, square_feet)
     VALUES ($1, $2, 3, 2, 1600) RETURNING id`, [customer.id, address.id]);

  const scheduledAt = new Date(Date.now() + 2 * 86_400_000);
  scheduledAt.setHours(10, 0, 0, 0);

  const { rows: [quote] } = await query(
    `INSERT INTO quotes (customer_id, property_id, service_code, scheduled_at, duration_min,
                         pricing_rule_id, subtotal_cents, ts_fee_cents, tax_cents, total_cents, breakdown, expires_at)
     VALUES ($1,$2,'standard',$3,120,$4,10000,349,0,10349,'{}'::jsonb, now() + interval '1 hour') RETURNING id`,
    [customer.id, property.id, scheduledAt, rules.id]);

  const { rows: [booking] } = await query(
    `INSERT INTO bookings (reference, customer_id, property_id, quote_id, service_code, status,
                           scheduled_at, duration_min, subtotal_cents, ts_fee_cents, tax_cents,
                           total_cents, commission_cents, payout_cents)
     VALUES ('SPK-LT' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,6)),
             $1,$2,$3,'standard','pending_match',$4,120,10000,349,0,10349,2000,8000) RETURNING *`,
    [customer.id, property.id, quote.id, scheduledAt]);

  return booking;
}

function verdict(planText, execMs, matched) {
  console.log('\n──────── EXPLAIN (ANALYZE, BUFFERS) ────────\n');
  console.log(planText);
  console.log('\n──────── verdict ────────');
  console.log(`candidates returned : ${matched}`);
  console.log(`execution time      : ${execMs == null ? '?' : `${execMs.toFixed(1)} ms`} (budget ${TARGET_MS} ms)`);

  const seqScan = /Seq Scan on cleaner_profiles/i.test(planText);
  const usesHomeGix = /cleaner_home_gix/i.test(planText);
  if (seqScan) {
    console.log('⚠ Seq Scan on cleaner_profiles — the radius filter is not index-accelerated.');
    console.log('  Expected: the ST_DWithin bound is per-row (service_radius_km * …), which a GiST');
    console.log('  index can\'t satisfy. Add a constant-radius prefilter the index CAN use before the');
    console.log('  exact per-row check (see the note in matching.candidates.sql.js).');
  } else if (usesHomeGix) {
    console.log('✓ cleaner_home_gix used for the radius scan.');
  }
  if (execMs != null && execMs > TARGET_MS) {
    console.log(`⚠ over the ${TARGET_MS} ms budget at ${CLEANERS.toLocaleString()} cleaners — dispatch runs this per round.`);
  } else if (execMs != null) {
    console.log('✓ within budget.');
  }
}

async function main() {
  await seedSupply();
  const booking = await seedTargetBooking();

  // Fresh stats so the planner chooses realistically after the bulk load.
  console.log('• ANALYZE…');
  await query('ANALYZE cleaner_profiles, cleaner_availability, cleaner_rating_snapshot, users, bookings');

  const params = [
    booking.id, 1, config.matching.bayesian.priorRating, booking.service_code,
    // 30 = findCandidates' default fetch limit (dispatch scores these, then
    // slices to broadcastSize); round 1, so radius multiplier 1.
    booking.scheduled_at, booking.duration_min, 30,
  ];

  // Warm once (plan cache, buffers), then measure.
  await query(FIND_CANDIDATES_SQL, params);
  const { rows: candidateRows } = await query(FIND_CANDIDATES_SQL, params);

  const explain = await query(`EXPLAIN (ANALYZE, BUFFERS) ${FIND_CANDIDATES_SQL}`, params);
  const planText = explain.rows.map((r) => r['QUERY PLAN']).join('\n');
  const execLine = planText.match(/Execution Time:\s*([\d.]+)\s*ms/);
  verdict(planText, execLine ? Number(execLine[1]) : null, candidateRows.length);
}

async function cleanup() {
  if (KEEP) {
    console.log(`\n(kept synthetic supply — remove with: DELETE FROM users WHERE email LIKE '${ANY_LIKE}')`);
    return;
  }
  console.log('\n• cleaning up synthetic rows…');
  const { rows: customers } = await query(
    `SELECT id FROM users WHERE email LIKE 'loadtest-cust-%@synthetic.invalid'`);
  const customerIds = customers.map((c) => c.id);
  if (customerIds.length) {
    await query('DELETE FROM bookings   WHERE customer_id = ANY($1::uuid[])', [customerIds]);
    await query('DELETE FROM quotes     WHERE customer_id = ANY($1::uuid[])', [customerIds]);
    await query('DELETE FROM properties WHERE customer_id = ANY($1::uuid[])', [customerIds]);
    await query('DELETE FROM addresses  WHERE user_id     = ANY($1::uuid[])', [customerIds]);
  }
  // Synthetic cleaners hold no bookings; user delete cascades their profile,
  // availability, and snapshot rows.
  await query('DELETE FROM users WHERE email LIKE $1', [ANY_LIKE]);
}

main()
  .then(cleanup)
  .then(() => pool.end())
  .catch(async (err) => {
    console.error('\nload test failed:', err.message);
    try { await cleanup(); } catch { /* best effort */ }
    await pool.end();
    process.exit(1);
  });
