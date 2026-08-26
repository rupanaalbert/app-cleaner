#!/usr/bin/env node
/**
 * Development seed.
 *
 *   npm run seed            # add data, leave what's there
 *   npm run seed -- --reset # truncate first
 *
 * Seeds a realistic slice of the Merrimack Valley: cleaners at varying quality
 * and distance, bookings in every live status, reviews that produce a spread
 * of ratings, and one open dispute. The point is to make the admin console and
 * the matching engine do something interesting on a fresh checkout — an empty
 * database makes a queue-shaped UI look broken.
 *
 * Money here is computed with the real pricing math, not hardcoded, so seeded
 * bookings satisfy the same CHECK constraints production data does.
 */
import './helpers/env.js';

import { randomUUID } from 'node:crypto';
import argon2 from 'argon2';

import { pool, query, withTransaction } from '../src/db/pool.js';
import { composeQuote } from '../src/domain/pricing.math.js';

if (process.env.NODE_ENV === 'production') {
  console.error('Refusing to seed a production database.');
  process.exit(1);
}

const reset = process.argv.includes('--reset');
const PASSWORD = 'sparkle-dev-password';

// Methuen and its neighbours — far enough apart that service radii actually
// discriminate, close enough that most cleaners are eligible for most jobs.
const PLACES = {
  methuen: { lat: 42.7262, lng: -71.1909, city: 'Methuen', zip: '01844' },
  lawrence: { lat: 42.7070, lng: -71.1631, city: 'Lawrence', zip: '01841' },
  andover: { lat: 42.6583, lng: -71.1368, city: 'Andover', zip: '01810' },
  haverhill: { lat: 42.7762, lng: -71.0773, city: 'Haverhill', zip: '01830' },
  lowell: { lat: 42.6334, lng: -71.3162, city: 'Lowell', zip: '01852' },
};

const CLEANERS = [
  { name: 'Amara Osei', place: 'methuen', radius: 18, years: 6, types: ['standard', 'deep'], ratings: [5, 5, 4, 5, 5, 5, 4, 5], approved: true },
  { name: 'Marcus Hale', place: 'lawrence', radius: 15, years: 3, types: ['standard'], ratings: [4, 3, 4, 4, 5], approved: true },
  { name: 'Sofia Lind', place: 'andover', radius: 22, years: 9, types: ['standard', 'deep'], ratings: [5, 5, 5, 5, 4, 5, 5, 5, 5, 5], approved: true },
  { name: 'Jonas Whitfield', place: 'haverhill', radius: 12, years: 1, types: ['standard'], ratings: [3, 4, 3, 2, 4], approved: true },
  { name: 'Rosa Belén Ruiz', place: 'lowell', radius: 25, years: 11, types: ['standard', 'deep'], ratings: [], approved: false },
  { name: 'Danil Petrov', place: 'lawrence', radius: 12, years: 2, types: ['standard'], ratings: [], approved: false },
];

const CUSTOMERS = [
  { name: 'Priya Raman', place: 'methuen', beds: 3, baths: 2, sqft: 1600 },
  { name: 'Ben Achebe', place: 'andover', beds: 2, baths: 1, sqft: 1100 },
  { name: 'Elena Marsh', place: 'haverhill', beds: 4, baths: 3, sqft: 2400 },
  { name: 'Tom Okafor', place: 'lowell', beds: 1, baths: 1, sqft: 700 },
];

const slug = (name) => name.toLowerCase().normalize('NFD').replace(/[^a-z ]/g, '').split(' ').join('.');
const ref = () => `SPK-${randomUUID().replace(/[^23456789ABCDEFGHJKLMNPQRSTUVWXYZ]/gi, '').toUpperCase().slice(0, 6).padEnd(6, 'X')}`;

async function main() {
  if (reset) {
    await query(`TRUNCATE users, pricing_rules, services, addons RESTART IDENTITY CASCADE`);
    console.log('• truncated');
    await seedCatalog();
  } else {
    const { rows: [{ count }] } = await query('SELECT COUNT(*)::int AS count FROM pricing_rules');
    if (count === 0) await seedCatalog();
  }

  const hash = await argon2.hash(PASSWORD, {
    type: argon2.argon2id, memoryCost: 19_456, timeCost: 2, parallelism: 1,
  });

  const { rows: [rules] } = await query(
    `SELECT * FROM pricing_rules WHERE metro = 'default' ORDER BY effective_from DESC LIMIT 1`);
  const { rows: services } = await query('SELECT * FROM services');
  const byCode = Object.fromEntries(services.map((s) => [s.code, s]));

  const cleaners = [];
  for (const spec of CLEANERS) {
    cleaners.push(await seedCleaner(spec, hash));
  }

  const customers = [];
  for (const spec of CUSTOMERS) {
    customers.push(await seedCustomer(spec, hash));
  }

  // Bookings across every live status, so the admin console and both apps have
  // something to render on every screen.
  const plan = [
    { c: 0, k: 0, service: 'standard', status: 'settled', daysAgo: 6 },
    { c: 0, k: 2, service: 'deep', status: 'settled', daysAgo: 3 },
    { c: 1, k: 1, service: 'standard', status: 'settled', daysAgo: 2 },
    { c: 2, k: 2, service: 'deep', status: 'in_progress', daysAgo: 0 },
    { c: 3, k: 0, service: 'standard', status: 'en_route', daysAgo: 0 },
    { c: 1, k: 3, service: 'standard', status: 'assigned', daysAgo: -1 },
    { c: 2, k: null, service: 'deep', status: 'pending_match', daysAgo: -2 },
    { c: 0, k: 1, service: 'standard', status: 'disputed', daysAgo: 4 },
  ];

  const bookings = [];
  for (const row of plan) {
    bookings.push(await seedBooking({
      rules,
      service: byCode[row.service],
      customer: customers[row.c],
      cleaner: row.k === null ? null : cleaners[row.k],
      status: row.status,
      daysAgo: row.daysAgo,
    }));
  }

  await seedReviews(cleaners, customers, bookings);
  await seedDispute(bookings.find((b) => b.status === 'disputed'), customers[0]);

  const { rows: [summary] } = await query(`
    SELECT (SELECT COUNT(*) FROM users)::int AS users,
           (SELECT COUNT(*) FROM bookings)::int AS bookings,
           (SELECT COUNT(*) FROM reviews)::int AS reviews,
           (SELECT COUNT(*) FROM disputes)::int AS disputes`);

  console.log('\nSeeded:', summary);
  console.log(`Sign in as any of them with: ${PASSWORD}`);
  console.log(`  customer  ${slug(CUSTOMERS[0].name)}@example.com`);
  console.log(`  cleaner   ${slug(CLEANERS[0].name)}@example.com   (approved)`);
  console.log(`  applicant ${slug(CLEANERS[4].name)}@example.com   (in the vetting queue)\n`);
  await pool.end();
}

async function seedCatalog() {
  await query(`
    INSERT INTO services (code,name,multiplier_bps,base_minutes,requires_photos) VALUES
      ('standard','Standard Clean',10000,90,false),
      ('deep','Deep Clean',16000,180,true)
    ON CONFLICT (code) DO NOTHING`);
  await query(`
    INSERT INTO addons (code,name,price_cents,minutes) VALUES
      ('inside_fridge','Inside fridge',2500,25),
      ('inside_oven','Inside oven',2500,30),
      ('interior_windows','Interior windows',3500,40),
      ('laundry','Laundry (1 load)',1500,15)
    ON CONFLICT (code) DO NOTHING`);
  await query(`
    INSERT INTO pricing_rules (metro, base_cents, per_bedroom_cents, per_bathroom_cents, size_tiers)
    VALUES ('default', 4900, 1200, 1500,
      '[{"max_sqft":1000,"adj_cents":0},{"max_sqft":1500,"adj_cents":800},
        {"max_sqft":2000,"adj_cents":1500},{"max_sqft":3000,"adj_cents":2800},
        {"max_sqft":null,"adj_cents":4500}]'::jsonb)`);
  console.log('• catalog and pricing rules');
}

async function seedCleaner(spec, hash) {
  const place = PLACES[spec.place];
  return withTransaction(async (client) => {
    const { rows: [user] } = await client.query(
      `INSERT INTO users (role, email, phone_e164, password_hash, full_name, status, email_verified_at)
       VALUES ('cleaner',$1,$2,$3,$4,$5, now())
       ON CONFLICT DO NOTHING RETURNING id`,
      [`${slug(spec.name)}@example.com`, `+1978555${String(1000 + CLEANERS.indexOf(spec)).slice(-4)}`,
       hash, spec.name, spec.approved ? 'active' : 'pending'],
    );
    if (!user) {
      const { rows: [existing] } = await client.query(
        'SELECT id FROM users WHERE email = $1', [`${slug(spec.name)}@example.com`]);
      return { id: existing.id, ...spec };
    }

    await client.query(
      `INSERT INTO cleaner_profiles
         (user_id, paypal_email, payouts_enabled, onboarding_status, bg_status,
          bg_completed_at, bg_expires_at, bio, years_experience, service_types,
          home_location, service_radius_km, is_available)
       VALUES ($1,$2,$3,$4,$5::bg_check_status,
               CASE WHEN $5::bg_check_status = 'clear' THEN now() - interval '30 days' END,
               CASE WHEN $5::bg_check_status = 'clear' THEN now() + interval '335 days' END,
               $6,$7,$8, ST_SetSRID(ST_MakePoint($9,$10),4326)::geography, $11, $3)`,
      [user.id, `${slug(spec.name)}-seed@example.com`, spec.approved,
       spec.approved ? 'approved' : 'docs_submitted',
       spec.approved ? 'clear' : (spec.name.startsWith('Danil') ? 'consider' : 'pending'),
       `${spec.years} years of experience around ${place.city}.`, spec.years, spec.types,
       place.lng, place.lat, spec.radius],
    );

    // Weekday mornings through early evening, weekends until mid-afternoon.
    for (const day of [1, 2, 3, 4, 5]) {
      await client.query(
        `INSERT INTO cleaner_availability (cleaner_id, day_of_week, start_min, end_min)
         VALUES ($1,$2,480,1080)`, [user.id, day]);
    }
    for (const day of [0, 6]) {
      await client.query(
        `INSERT INTO cleaner_availability (cleaner_id, day_of_week, start_min, end_min)
         VALUES ($1,$2,540,960)`, [user.id, day]);
    }

    for (const docType of ['gov_id', 'insurance', 'work_auth']) {
      await client.query(
        `INSERT INTO cleaner_documents (cleaner_id, doc_type, s3_key, sha256, verified_at)
         VALUES ($1,$2,$3,'seed', CASE WHEN $4 THEN now() - interval '29 days' END)`,
        [user.id, docType, `cleaners/${user.id}/${docType}/seed`, spec.approved]);
    }

    return { id: user.id, ...spec };
  });
}

async function seedCustomer(spec, hash) {
  const place = PLACES[spec.place];
  return withTransaction(async (client) => {
    const email = `${slug(spec.name)}@example.com`;
    const { rows: [user] } = await client.query(
      `INSERT INTO users (role, email, phone_e164, password_hash, full_name, status, email_verified_at)
       VALUES ('customer',$1,$2,$3,$4,'active', now())
       ON CONFLICT DO NOTHING RETURNING id`,
      [email, `+1978555${String(2000 + CUSTOMERS.indexOf(spec)).slice(-4)}`, hash, spec.name],
    );
    if (!user) {
      const { rows: [existing] } = await client.query('SELECT id FROM users WHERE email = $1', [email]);
      const { rows: [property] } = await client.query(
        'SELECT id FROM properties WHERE customer_id = $1 LIMIT 1', [existing.id]);
      return { id: existing.id, propertyId: property.id, ...spec };
    }

    await client.query(
      `INSERT INTO customer_profiles (user_id) VALUES ($1)`,
      [user.id]);

    const { rows: [address] } = await client.query(
      `INSERT INTO addresses (user_id, label, line1, city, region, postal_code, location, access_notes)
       VALUES ($1,'Home',$2,$3,'MA',$4, ST_SetSRID(ST_MakePoint($5,$6),4326)::geography,'Key under the pot.')
       RETURNING id`,
      [user.id, `${10 + CUSTOMERS.indexOf(spec) * 7} Pleasant St`, place.city, place.zip,
       place.lng, place.lat],
    );

    const { rows: [property] } = await client.query(
      `INSERT INTO properties (customer_id, address_id, bedrooms, bathrooms, square_feet, has_pets)
       VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
      [user.id, address.id, spec.beds, spec.baths, spec.sqft, CUSTOMERS.indexOf(spec) % 2 === 0]);

    return { id: user.id, propertyId: property.id, ...spec };
  });
}

async function seedBooking({ rules, service, customer, cleaner, status, daysAgo }) {
  const scheduledAt = new Date(Date.now() - daysAgo * 86_400_000);
  scheduledAt.setHours(10, 0, 0, 0);

  // Real pricing math, so every seeded row satisfies the same CHECK
  // constraints production data does.
  const quote = composeQuote({
    rules,
    property: { bedrooms: customer.beds, bathrooms: customer.baths, square_feet: customer.sqft },
    service,
    scheduledAt,
  });

  return withTransaction(async (client) => {
    const { rows: [q] } = await client.query(
      `INSERT INTO quotes (customer_id, property_id, service_code, scheduled_at, duration_min,
                           pricing_rule_id, subtotal_cents, ts_fee_cents, tax_cents, total_cents,
                           breakdown, expires_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11, now() + interval '15 minutes') RETURNING id`,
      [customer.id, customer.propertyId, service.code, scheduledAt, quote.duration_min, rules.id,
       quote.subtotal_cents, quote.ts_fee_cents, quote.tax_cents, quote.total_cents, quote.breakdown],
    );

    const done = ['settled', 'disputed'].includes(status);
    const { rows: [booking] } = await client.query(
      `INSERT INTO bookings (reference, customer_id, cleaner_id, property_id, quote_id,
                             service_code, status, scheduled_at, duration_min,
                             subtotal_cents, ts_fee_cents, tax_cents, total_cents,
                             commission_cents, payout_cents, created_at,
                             matched_at, en_route_at, arrived_at, started_at, completed_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::integer,$10,$11,$12,$13,$14,$15,
               $8::timestamptz - interval '3 days',
               CASE WHEN $3::uuid IS NULL THEN NULL ELSE $8::timestamptz - interval '2 days' END,
               CASE WHEN $16 THEN $8::timestamptz - interval '30 minutes' END,
               CASE WHEN $16 THEN $8::timestamptz - interval '5 minutes' END,
               CASE WHEN $16 THEN $8::timestamptz END,
               CASE WHEN $16 THEN $8::timestamptz + ($9::text || ' minutes')::interval END)
       RETURNING *`,
      [ref(), customer.id, cleaner?.id ?? null, customer.propertyId, q.id, service.code, status,
       scheduledAt, quote.duration_min, quote.subtotal_cents, quote.ts_fee_cents, quote.tax_cents,
       quote.total_cents, quote.commission_cents, quote.payout_cents, done],
    );

    if (done) {
      const { rows: [payment] } = await client.query(
        `INSERT INTO payments (booking_id, customer_id, paypal_order_id, paypal_authorization_id,
                               paypal_capture_id, status, authorized_cents, captured_cents,
                               platform_fee_cents, authorized_at, captured_at)
         VALUES ($1,$2,$3,$4,$5,'captured',$6,$6,$7, now() - interval '1 day', now()) RETURNING id`,
        [booking.id, customer.id, `order_seed_${booking.id.slice(-8)}`,
         `auth_seed_${booking.id.slice(-8)}`, `cap_seed_${booking.id.slice(-8)}`,
         booking.total_cents, booking.commission_cents + booking.ts_fee_cents]);
      await client.query(
        `INSERT INTO payouts (cleaner_id, booking_id, paypal_payout_batch_id, paypal_payout_item_id,
                              amount_cents, status, hold_until)
         VALUES ($1,$2,$3,$4,$5,'paid', now() - interval '1 day')`,
        [cleaner.id, booking.id, `batch_seed_${payment.id.slice(-8)}`,
         `item_seed_${payment.id.slice(-8)}`, booking.payout_cents]);
    }

    return booking;
  });
}

async function seedReviews(cleaners, customers, bookings) {
  // Ratings come from the cleaner specs so the snapshot table produces a real
  // spread — including one cleaner below the 4.3 dispatch floor.
  for (const cleaner of cleaners) {
    if (!cleaner.ratings?.length) continue;
    const sum = cleaner.ratings.reduce((a, b) => a + b, 0);
    const count = cleaner.ratings.length;
    const recent = cleaner.ratings.slice(-20);
    const trailing = recent.reduce((a, b) => a + b, 0) / recent.length;

    await query(
      `INSERT INTO cleaner_rating_snapshot
         (cleaner_id, review_count, avg_rating, bayesian_rating, rating_last_20,
          completion_rate, acceptance_rate, jobs_completed, is_dispatchable)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$2,$8)
       ON CONFLICT (cleaner_id) DO UPDATE SET
         review_count = EXCLUDED.review_count, avg_rating = EXCLUDED.avg_rating,
         bayesian_rating = EXCLUDED.bayesian_rating, rating_last_20 = EXCLUDED.rating_last_20,
         is_dispatchable = EXCLUDED.is_dispatchable`,
      [cleaner.id, count, (sum / count).toFixed(2),
       ((sum + 4.6 * 10) / (count + 10)).toFixed(2), trailing.toFixed(2),
       0.97, 0.82, trailing >= 4.3],
    );
  }

  for (const booking of bookings.filter((b) => b.status === 'settled')) {
    await query(
      `INSERT INTO reviews (booking_id, author_type, author_id, subject_id, rating, tags, comment)
       VALUES ($1,'customer',$2,$3,5,'{punctual,thorough}','Spotless, and early.')
       ON CONFLICT DO NOTHING`,
      [booking.id, booking.customer_id, booking.cleaner_id]);
  }
}

async function seedDispute(booking, customer) {
  if (!booking) return;
  await query(
    `INSERT INTO disputes (booking_id, opened_by, category, description, status)
     VALUES ($1,$2,'quality',$3,'open')`,
    [booking.id, customer.id,
     'Bathrooms were skipped entirely and the kitchen floor was still sticky.']);
}

main().catch(async (err) => {
  console.error(err);
  await pool.end();
  process.exit(1);
});
