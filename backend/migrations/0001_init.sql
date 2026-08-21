-- ============================================================================
-- Sparkle Marketplace — PostgreSQL 16 schema
-- Money is ALWAYS integer cents. Timestamps are ALWAYS timestamptz (UTC).
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- UUIDv7-ish: time-ordered ids keep btree indexes and future sharding sane.
CREATE OR REPLACE FUNCTION uuid_generate_v7() RETURNS uuid AS $$
  SELECT encode(
    set_bit(set_bit(overlay(uuid_send(gen_random_uuid())
      PLACING substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3)
      FROM 1 FOR 6), 52, 1), 53, 1), 'hex')::uuid;
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------- enums ----
CREATE TYPE user_role          AS ENUM ('customer','cleaner','admin');
CREATE TYPE account_status     AS ENUM ('pending','active','suspended','deleted');
CREATE TYPE onboarding_status  AS ENUM ('started','docs_submitted','check_pending','approved','rejected');
CREATE TYPE bg_check_status    AS ENUM ('not_started','pending','clear','consider','suspended','expired');
CREATE TYPE property_type      AS ENUM ('residential','commercial');
CREATE TYPE booking_status     AS ENUM ('draft','quoted','pending_match','assigned','en_route',
                                        'arrived','in_progress','completed','settled','canceled','disputed');
CREATE TYPE cancel_actor       AS ENUM ('customer','cleaner','admin','system');
CREATE TYPE payment_status     AS ENUM ('requires_payment','authorized','captured','partially_refunded',
                                        'refunded','failed','canceled');
CREATE TYPE payout_status      AS ENUM ('pending','in_transit','paid','failed','reversed');
CREATE TYPE offer_status       AS ENUM ('sent','viewed','accepted','declined','expired','superseded');
CREATE TYPE review_author      AS ENUM ('customer','cleaner');

-- ---------------------------------------------------------------- users ----
CREATE TABLE users (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  role              user_role     NOT NULL,
  email             citext,
  phone_e164        text,                       -- encrypted at app layer in prod
  password_hash     text,                       -- null for OAuth-only accounts
  full_name         text,
  avatar_key        text,
  locale            text          NOT NULL DEFAULT 'en-US',
  status            account_status NOT NULL DEFAULT 'pending',
  email_verified_at timestamptz,
  phone_verified_at timestamptz,
  dns_optout        boolean       NOT NULL DEFAULT false,  -- CCPA do-not-sell/share
  last_login_at     timestamptz,
  created_at        timestamptz   NOT NULL DEFAULT now(),
  updated_at        timestamptz   NOT NULL DEFAULT now(),
  deleted_at        timestamptz                            -- tombstone; PII nulled on erasure
);
CREATE UNIQUE INDEX users_email_uq ON users (email) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX users_phone_uq ON users (phone_e164) WHERE deleted_at IS NULL;
CREATE TRIGGER users_touch BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE customer_profiles (
  user_id                 uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  stripe_customer_id      text UNIQUE,
  default_address_id      uuid,
  default_payment_method  text,
  lifetime_bookings       int NOT NULL DEFAULT 0,
  created_at              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE cleaner_profiles (
  user_id             uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  stripe_account_id   text UNIQUE,                       -- Connect Express
  payouts_enabled     boolean NOT NULL DEFAULT false,
  onboarding_status   onboarding_status NOT NULL DEFAULT 'started',
  bg_status           bg_check_status   NOT NULL DEFAULT 'not_started',
  bg_report_id        text,                              -- Checkr id only; never the report body
  bg_completed_at     timestamptz,
  bg_expires_at       timestamptz,
  bio                 text,
  years_experience    int,
  service_types       text[] NOT NULL DEFAULT '{standard}',
  home_location       geography(Point,4326),
  service_radius_km   numeric(5,2) NOT NULL DEFAULT 15,
  max_daily_jobs      int NOT NULL DEFAULT 4,
  is_available        boolean NOT NULL DEFAULT false,     -- "online" toggle
  suspended_until     timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX cleaner_home_gix ON cleaner_profiles USING gist (home_location);
CREATE INDEX cleaner_dispatchable_ix ON cleaner_profiles (is_available)
  WHERE onboarding_status = 'approved' AND bg_status = 'clear';
CREATE TRIGGER cleaner_touch BEFORE UPDATE ON cleaner_profiles FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE cleaner_documents (
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  cleaner_id    uuid NOT NULL REFERENCES cleaner_profiles(user_id) ON DELETE CASCADE,
  doc_type      text NOT NULL,            -- gov_id | insurance | work_auth | certification
  s3_key        text NOT NULL,
  sha256        text NOT NULL,
  expires_at    date,
  verified_at   timestamptz,
  verified_by   uuid REFERENCES users(id),
  rejected_note text,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX cleaner_docs_ix ON cleaner_documents (cleaner_id, doc_type);

CREATE TABLE cleaner_availability (       -- weekly recurring windows, cleaner-local
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  cleaner_id  uuid NOT NULL REFERENCES cleaner_profiles(user_id) ON DELETE CASCADE,
  day_of_week smallint NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  start_min   smallint NOT NULL CHECK (start_min BETWEEN 0 AND 1439),
  end_min     smallint NOT NULL CHECK (end_min   BETWEEN 1 AND 1440),
  CHECK (end_min > start_min)
);
CREATE INDEX cleaner_avail_ix ON cleaner_availability (cleaner_id, day_of_week);

CREATE TABLE devices (                    -- FCM push targets
  id           uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  fcm_token    text NOT NULL UNIQUE,
  platform     text NOT NULL CHECK (platform IN ('ios','android','web')),
  last_seen_at timestamptz NOT NULL DEFAULT now()
);

-- ----------------------------------------------------- places & catalog ----
CREATE TABLE addresses (
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  label         text,
  line1         text NOT NULL,
  line2         text,
  city          text NOT NULL,
  region        text NOT NULL,
  postal_code   text NOT NULL,
  country       char(2) NOT NULL DEFAULT 'US',
  location      geography(Point,4326) NOT NULL,
  access_notes  text,                     -- gate codes, parking; revealed only when assigned
  created_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz
);
CREATE INDEX addresses_user_ix ON addresses (user_id) WHERE deleted_at IS NULL;
CREATE INDEX addresses_gix ON addresses USING gist (location);

CREATE TABLE properties (
  id             uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  customer_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  address_id     uuid NOT NULL REFERENCES addresses(id),
  property_type  property_type NOT NULL DEFAULT 'residential',
  bedrooms       smallint NOT NULL DEFAULT 1,
  bathrooms      smallint NOT NULL DEFAULT 1,
  square_feet    int,
  has_pets       boolean NOT NULL DEFAULT false,
  parking_notes  text,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX properties_customer_ix ON properties (customer_id);

CREATE TABLE services (
  code            text PRIMARY KEY,        -- 'standard' | 'deep'
  name            text NOT NULL,
  description     text,
  multiplier_bps  int NOT NULL DEFAULT 10000,   -- 16000 = 1.60x
  base_minutes    int NOT NULL,
  minutes_per_bedroom  int NOT NULL DEFAULT 20,
  minutes_per_bathroom int NOT NULL DEFAULT 25,
  requires_photos boolean NOT NULL DEFAULT false,
  is_active       boolean NOT NULL DEFAULT true
);

CREATE TABLE addons (
  code        text PRIMARY KEY,
  name        text NOT NULL,
  price_cents int NOT NULL,
  minutes     int NOT NULL DEFAULT 0,
  is_active   boolean NOT NULL DEFAULT true
);

-- Versioned, never updated in place: old bookings must still explain their price.
CREATE TABLE pricing_rules (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  metro             text NOT NULL DEFAULT 'default',
  base_cents        int  NOT NULL,
  per_bedroom_cents int  NOT NULL,
  per_bathroom_cents int NOT NULL,
  size_tiers        jsonb NOT NULL,        -- [{"max_sqft":1000,"adj_cents":0}, ...]
  commission_bps    int  NOT NULL DEFAULT 2000,
  weekend_bps       int  NOT NULL DEFAULT 11500,
  evening_bps       int  NOT NULL DEFAULT 11000,
  demand_cap_bps    int  NOT NULL DEFAULT 15000,
  ts_fee_flat_cents int  NOT NULL DEFAULT 349,
  ts_fee_bps        int  NOT NULL DEFAULT 100,
  ts_fee_cap_cents  int  NOT NULL DEFAULT 999,
  effective_from    timestamptz NOT NULL DEFAULT now(),
  effective_to      timestamptz
);
CREATE INDEX pricing_rules_active_ix ON pricing_rules (metro, effective_from DESC);

-- ------------------------------------------------------ quotes & bookings ---
CREATE TABLE quotes (
  id             uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  customer_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  property_id    uuid NOT NULL REFERENCES properties(id),
  service_code   text NOT NULL REFERENCES services(code),
  addon_codes    text[] NOT NULL DEFAULT '{}',
  scheduled_at   timestamptz NOT NULL,
  duration_min   int NOT NULL,
  pricing_rule_id uuid NOT NULL REFERENCES pricing_rules(id),
  subtotal_cents int NOT NULL,
  ts_fee_cents   int NOT NULL,
  tax_cents      int NOT NULL DEFAULT 0,
  total_cents    int NOT NULL,
  breakdown      jsonb NOT NULL,           -- resolved line items, for support + audit
  expires_at     timestamptz NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX quotes_customer_ix ON quotes (customer_id, created_at DESC);

CREATE TABLE bookings (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  reference         text UNIQUE NOT NULL,         -- human-friendly, e.g. SPK-8J4K2Q
  customer_id       uuid NOT NULL REFERENCES users(id),
  cleaner_id        uuid REFERENCES cleaner_profiles(user_id),
  property_id       uuid NOT NULL REFERENCES properties(id),
  quote_id          uuid NOT NULL REFERENCES quotes(id),
  service_code      text NOT NULL REFERENCES services(code),
  addon_codes       text[] NOT NULL DEFAULT '{}',
  status            booking_status NOT NULL DEFAULT 'draft',
  scheduled_at      timestamptz NOT NULL,
  duration_min      int NOT NULL,
  special_instructions text,

  -- price snapshot (immutable once confirmed)
  subtotal_cents    int NOT NULL,
  ts_fee_cents      int NOT NULL,
  tax_cents         int NOT NULL DEFAULT 0,
  total_cents       int NOT NULL,
  commission_cents  int NOT NULL,
  payout_cents      int NOT NULL,
  tip_cents         int NOT NULL DEFAULT 0,

  -- lifecycle timestamps
  matched_at        timestamptz,
  en_route_at       timestamptz,
  arrived_at        timestamptz,
  started_at        timestamptz,
  completed_at      timestamptz,
  canceled_at       timestamptz,
  canceled_by       cancel_actor,
  cancel_reason     text,
  cancel_fee_cents  int NOT NULL DEFAULT 0,

  firebase_thread_id text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT total_adds_up CHECK (total_cents = subtotal_cents + ts_fee_cents + tax_cents),
  CONSTRAINT split_adds_up CHECK (subtotal_cents = commission_cents + payout_cents),
  CONSTRAINT assigned_needs_cleaner CHECK (
    status IN ('draft','quoted','pending_match','canceled') OR cleaner_id IS NOT NULL)
);
CREATE INDEX bookings_customer_ix ON bookings (customer_id, scheduled_at DESC);
CREATE INDEX bookings_cleaner_ix  ON bookings (cleaner_id, scheduled_at DESC);
CREATE INDEX bookings_dispatch_ix ON bookings (status, scheduled_at) WHERE status = 'pending_match';
CREATE TRIGGER bookings_touch BEFORE UPDATE ON bookings FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- One cleaner cannot hold two overlapping live jobs.
CREATE EXTENSION IF NOT EXISTS btree_gist;
ALTER TABLE bookings ADD COLUMN time_span tstzrange
  GENERATED ALWAYS AS (tstzrange(scheduled_at, scheduled_at + (duration_min || ' minutes')::interval)) STORED;
ALTER TABLE bookings ADD CONSTRAINT no_double_booking
  EXCLUDE USING gist (cleaner_id WITH =, time_span WITH &&)
  WHERE (status IN ('assigned','en_route','arrived','in_progress'));

CREATE TABLE booking_status_history (
  id          bigserial PRIMARY KEY,
  booking_id  uuid NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  from_status booking_status,
  to_status   booking_status NOT NULL,
  actor_id    uuid REFERENCES users(id),
  actor_role  user_role,
  location    geography(Point,4326),      -- captured at en_route/arrived/completed
  metadata    jsonb NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX bsh_booking_ix ON booking_status_history (booking_id, created_at);

CREATE TABLE booking_offers (
  id           uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  booking_id   uuid NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  cleaner_id   uuid NOT NULL REFERENCES cleaner_profiles(user_id) ON DELETE CASCADE,
  round        smallint NOT NULL DEFAULT 1,
  score        numeric(6,4) NOT NULL,
  distance_km  numeric(6,2) NOT NULL,
  payout_cents int NOT NULL,
  status       offer_status NOT NULL DEFAULT 'sent',
  expires_at   timestamptz NOT NULL,
  responded_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (booking_id, cleaner_id, round)
);
CREATE INDEX offers_open_ix ON booking_offers (cleaner_id, status, expires_at) WHERE status IN ('sent','viewed');

CREATE TABLE job_photos (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  booking_id  uuid NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  phase       text NOT NULL CHECK (phase IN ('before','after')),
  s3_key      text NOT NULL,
  purge_after date NOT NULL DEFAULT (current_date + 90),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE location_breadcrumbs (      -- coarse trail for disputes; live GPS lives in Firebase
  id         bigserial PRIMARY KEY,
  booking_id uuid NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  point      geography(Point,4326) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX breadcrumbs_ix ON location_breadcrumbs (booking_id, recorded_at);

CREATE TABLE masked_call_sessions (
  id             uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  booking_id     uuid NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  twilio_sid     text NOT NULL UNIQUE,
  proxy_number   text NOT NULL,
  expires_at     timestamptz NOT NULL,
  closed_at      timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------- payments ----
CREATE TABLE payments (
  id                   uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  booking_id           uuid NOT NULL REFERENCES bookings(id) ON DELETE RESTRICT,
  customer_id          uuid NOT NULL REFERENCES users(id),
  stripe_payment_intent_id text UNIQUE NOT NULL,
  stripe_charge_id     text,
  status               payment_status NOT NULL DEFAULT 'requires_payment',
  currency             char(3) NOT NULL DEFAULT 'USD',
  authorized_cents     int NOT NULL,
  captured_cents       int NOT NULL DEFAULT 0,
  refunded_cents       int NOT NULL DEFAULT 0,
  application_fee_cents int NOT NULL,
  stripe_fee_cents     int,
  failure_code         text,
  authorized_at        timestamptz,
  captured_at          timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CHECK (refunded_cents <= captured_cents)
);
CREATE INDEX payments_booking_ix ON payments (booking_id);
CREATE TRIGGER payments_touch BEFORE UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE refunds (
  id             uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  payment_id     uuid NOT NULL REFERENCES payments(id) ON DELETE CASCADE,
  stripe_refund_id text UNIQUE NOT NULL,
  amount_cents   int NOT NULL CHECK (amount_cents > 0),
  reason         text NOT NULL,
  issued_by      uuid REFERENCES users(id),
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE payouts (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  cleaner_id        uuid NOT NULL REFERENCES cleaner_profiles(user_id),
  booking_id        uuid REFERENCES bookings(id),
  stripe_transfer_id text UNIQUE,
  stripe_payout_id  text,
  amount_cents      int NOT NULL,
  status            payout_status NOT NULL DEFAULT 'pending',
  arrival_date      date,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX payouts_cleaner_ix ON payouts (cleaner_id, created_at DESC);

-- Append-only double-entry journal. Reconcile against Stripe, not against yourself.
CREATE TABLE ledger_entries (
  id           bigserial PRIMARY KEY,
  booking_id   uuid REFERENCES bookings(id),
  account      text NOT NULL,   -- customer_receivable | platform_revenue | cleaner_payable | ts_fee | stripe_fee
  direction    char(1) NOT NULL CHECK (direction IN ('D','C')),
  amount_cents int NOT NULL CHECK (amount_cents > 0),
  memo         text,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ledger_booking_ix ON ledger_entries (booking_id);

CREATE TABLE webhook_events (           -- idempotency guard for every provider
  id           text PRIMARY KEY,         -- provider event id
  provider     text NOT NULL,
  event_type   text NOT NULL,
  payload      jsonb NOT NULL,
  processed_at timestamptz,
  error        text,
  received_at  timestamptz NOT NULL DEFAULT now()
);

-- ------------------------------------------------ reviews & reputation -----
CREATE TABLE reviews (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  booking_id  uuid NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  author_type review_author NOT NULL,
  author_id   uuid NOT NULL REFERENCES users(id),
  subject_id  uuid NOT NULL REFERENCES users(id),
  rating      smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  tags        text[] NOT NULL DEFAULT '{}',   -- punctual, thorough, communicative...
  comment     text,
  is_hidden   boolean NOT NULL DEFAULT false, -- moderation
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (booking_id, author_type)            -- one review per side per job
);
CREATE INDEX reviews_subject_ix ON reviews (subject_id, created_at DESC) WHERE is_hidden = false;

-- Denormalized ranking input, recomputed by a worker on every new review.
CREATE TABLE cleaner_rating_snapshot (
  cleaner_id        uuid PRIMARY KEY REFERENCES cleaner_profiles(user_id) ON DELETE CASCADE,
  review_count      int NOT NULL DEFAULT 0,
  avg_rating        numeric(3,2),
  bayesian_rating   numeric(3,2),   -- (sum + C*prior)/(n + C), C=10, prior=4.6
  rating_last_20    numeric(3,2),
  completion_rate   numeric(5,4) NOT NULL DEFAULT 1,
  acceptance_rate   numeric(5,4) NOT NULL DEFAULT 1,
  late_cancels_60d  int NOT NULL DEFAULT 0,
  jobs_completed    int NOT NULL DEFAULT 0,
  is_dispatchable   boolean NOT NULL DEFAULT true,  -- false below the 4.3 floor
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE disputes (
  id           uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  booking_id   uuid NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  opened_by    uuid NOT NULL REFERENCES users(id),
  category     text NOT NULL,       -- quality | damage | no_show | billing | safety
  description  text NOT NULL,
  status       text NOT NULL DEFAULT 'open',  -- open | investigating | resolved | escalated
  resolution   text,
  refund_cents int NOT NULL DEFAULT 0,
  assigned_to  uuid REFERENCES users(id),
  resolved_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX disputes_open_ix ON disputes (status, created_at) WHERE status <> 'resolved';

-- ------------------------------------------------- privacy & governance ----
CREATE TABLE consents (
  id           uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose      text NOT NULL,       -- tos | privacy | marketing_email | marketing_sms | location
  version      text NOT NULL,
  granted_at   timestamptz NOT NULL DEFAULT now(),
  withdrawn_at timestamptz,
  ip_address   inet,
  user_agent   text
);
CREATE INDEX consents_user_ix ON consents (user_id, purpose);

CREATE TABLE data_requests (
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind          text NOT NULL CHECK (kind IN ('export','erasure')),
  status        text NOT NULL DEFAULT 'received',
  scheduled_for timestamptz,        -- erasure honors a 14-day grace window
  completed_at  timestamptz,
  artifact_key  text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (             -- append-only; app role has no UPDATE/DELETE grant
  id          bigserial PRIMARY KEY,
  actor_id    uuid REFERENCES users(id),
  action      text NOT NULL,
  entity_type text NOT NULL,
  entity_id   uuid,
  before      jsonb,
  after       jsonb,
  ip_address  inet,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_entity_ix ON audit_log (entity_type, entity_id, created_at DESC);

-- ------------------------------------------------------------- seed data ---
INSERT INTO services (code,name,multiplier_bps,base_minutes,requires_photos) VALUES
  ('standard','Standard Clean',10000,90,false),
  ('deep','Deep Clean',16000,180,true);

INSERT INTO addons (code,name,price_cents,minutes) VALUES
  ('inside_fridge','Inside fridge',2500,25),
  ('inside_oven','Inside oven',2500,30),
  ('interior_windows','Interior windows',3500,40),
  ('laundry','Laundry (1 load)',1500,15);

INSERT INTO pricing_rules
  (metro, base_cents, per_bedroom_cents, per_bathroom_cents, size_tiers)
VALUES ('default', 4900, 1200, 1500,
  '[{"max_sqft":1000,"adj_cents":0},
    {"max_sqft":1500,"adj_cents":800},
    {"max_sqft":2000,"adj_cents":1500},
    {"max_sqft":3000,"adj_cents":2800},
    {"max_sqft":null,"adj_cents":4500}]'::jsonb);

-- Replay guard for money-moving POSTs (see middleware/idempotency.js).
CREATE TABLE idempotency_keys (
  key         text PRIMARY KEY,
  fingerprint text NOT NULL,        -- sha256(user:path:body); mismatch = 409
  response    jsonb NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idempotency_sweep_ix ON idempotency_keys (created_at);  -- purge > 24h

-- ============================================================ auth =========
-- Refresh tokens are stored hashed and rotate on every use. Each login starts
-- a "family"; presenting an already-used token means a copy leaked, so the
-- whole family is revoked rather than just that token.
CREATE TABLE refresh_tokens (
  id             uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  family_id      uuid NOT NULL,
  token_hash     text NOT NULL UNIQUE,          -- sha256 of the presented secret
  parent_id      uuid REFERENCES refresh_tokens(id) ON DELETE SET NULL,
  device_id      text,
  user_agent     text,
  ip_address     inet,
  expires_at     timestamptz NOT NULL,
  used_at        timestamptz,
  revoked_at     timestamptz,
  revoked_reason text,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX refresh_user_ix   ON refresh_tokens (user_id, created_at DESC);
CREATE INDEX refresh_family_ix ON refresh_tokens (family_id) WHERE revoked_at IS NULL;
CREATE INDEX refresh_sweep_ix  ON refresh_tokens (expires_at);

-- One table for every short-lived secret: email verification, password reset,
-- phone OTP. Codes are hashed; attempts are counted so a 6-digit SMS code
-- cannot be brute-forced.
CREATE TABLE auth_codes (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose     text NOT NULL CHECK (purpose IN ('verify_email','reset_password','verify_phone')),
  code_hash   text NOT NULL,
  attempts    smallint NOT NULL DEFAULT 0,
  expires_at  timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX auth_codes_lookup_ix ON auth_codes (user_id, purpose, created_at DESC)
  WHERE consumed_at IS NULL;
