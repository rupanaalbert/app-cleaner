# Sparkle — working notes for Claude Code

On-demand cleaning marketplace. Node/Express + PostgreSQL + PostGIS backend, two Flutter apps, a React admin console, Firebase for realtime, PayPal (collect-then-disburse, not Stripe Connect) for money.

Read `README.md` for the architecture and `docs/API.md` for endpoint contracts before changing anything structural. This file is the stuff that isn't obvious from the code.

## Commands

```bash
docker compose -f infra/docker-compose.yml up -d   # Postgres+PostGIS, Redis
cd backend && npm install
npm run migrate:up            # apply migrations; schema lives in migrations/, not one file
npm run seed                  # realistic dev data; --reset to truncate first
npm run create-admin -- email@example.com "Name"
npm run dev                   # API on :8080
npm run worker                # matching, payouts, ratings, retention sweeps
npm test                      # domain math only: no DB, no network, ~250ms
npm run test:integration      # booking state machine; needs a migrated DB
```

Flutter: `cd mobile/customer_app && flutter run` (or `cleaner_app`). Both ship a fake repository so they run without the backend.

## Invariants — do not break these

1. **Money is integer cents. Everywhere.** No floats in any pricing path, including Dart. Rates are basis points (10000 = 1.00x).
2. **Commission is taken on the subtotal only** — never on the Trust & Safety fee, never on tips. `platform_fee_cents` = commission + T&S fee, kept by Sparkle's own PayPal account at capture.
3. **`src/domain/*.js` has zero imports.** Pricing and ranking math lives there so it stays testable without Postgres. Services own I/O and delegate arithmetic. If you find yourself importing `db/pool.js` into `domain/`, the logic belongs in a service instead.
4. **Every admin action writes an `audit_log` row in the same transaction as the change.** The app DB role has no UPDATE/DELETE grant on that table — don't add one.
5. **Location tracking stops at `arrived`.** Enforced three ways: client tears down the stream, `RealtimeService.publishStatus` deletes the node, Firebase rules reject writes unless `booking_access/{id}/status` is `en_route`. Keep all three.
6. **`booking_access/*` in Firebase is written only by the backend service account.** Clients granting themselves booking access is the whole threat model.
7. **`payouts_enabled` is set only by a successful verification-payout webhook** (`PAYMENT.PAYOUTS-ITEM.SUCCEEDED` for the reserved `verify:{cleanerId}` sender_item_id — see `webhook.service.js`). Never set it optimistically, e.g. on the `savePayoutsEmail` call itself — the admin approval gate depends on it, and an optimistic value means a job completes and then fails at payout.
8. **Admins are never created over HTTP.** `npm run create-admin` requires shell access. Don't add a route.
9. **Every PayPal call carries a `PayPal-Request-Id`** of the form `booking:{id}:{action}`. Every webhook is recorded in `webhook_events` before processing and skipped if already seen.
10. **Booking status changes go through `BookingService.updateStatus`**, which enforces the `TRANSITIONS` map. Don't UPDATE `bookings.status` directly outside that method (the seed script is the deliberate exception).

## Conventions

- ESM throughout (`"type": "module"`). Node 20+.
- Schema changes go through migrations (`node-pg-migrate`, in `backend/migrations/`). `0001_init` is the whole schema; add the next with `npm run migrate:create -- add_something`, write both `up` and `down`, and let the `schema` CI job prove it applies from an empty database. Migration files are `.cjs` (the package is ESM) or plain `.sql`. Never hand-edit a shipped migration — add a new one.
- Routes validate with zod and authorize; controllers translate HTTP; services hold rules; SQL stays in services/repositories. A service never imports `express`; a route never imports `pg`.
- Errors: throw `AppError.*`; the handler renders RFC 9457 problem details. Never leak internals — the `request_id` ties a response to the log line.
- Any handler touching more than one table wraps in `withTransaction`.
- Webhook routes mount **before** `express.json()` — PayPal signature verification needs the raw body.
- Flutter: repositories are abstract classes with an HTTP implementation and a fake. Screens take the repository as a constructor arg. Every screen ships loading, empty, and error states.
- Tap targets 44pt minimum. Disabled beats hidden so controls don't shift under a thumb.

## Design language

Shared marine (`#0E3A45`) across all three surfaces, different accents by job:

| Surface | Accent | Signature element |
|---|---|---|
| Cleaner app | Amber — payouts only | Expiry ring draining around the payout |
| Customer app | Seafoam — the single forward action | Price ledger pinned to the bottom |
| Admin console | Seafoam approve / clay reject | Keyboard-driven decision queue |

Don't introduce a fourth palette. If a colour needs to mean something new, say what it means here first.

All three surfaces also now share one depth and type system: a low-alpha marine `cardShadow` (`Sparkle.cardShadow` in each Flutter app's `theme.dart`; hand-written in `admin/index.css`) on every lifted card, the same self-hosted Archivo/Inter fonts, and the same sparkle-motif/hero SVGs. Added 2026-08-27 — see BACKLOG.md.

## Known stubs and rough edges

- Transactional email/SMS deliver through Postmark and Twilio (`src/services/mail.service.js`, `sms.service.js`); with no provider configured they log instead, so dev and tests never hit the network. Sends are best-effort and post-commit — a provider blip loses a resendable message, not the write. No retry queue yet (`notifyQueue` is the place for one).
- **Admin console render pass done (2026-08-24).** The "no bundler in-repo" note was stale — `admin/` already carried a Vite scaffold, just missing Tailwind (so it rendered unstyled) and a proxy for `api.js`'s same-origin `/v1` calls; both are now filled in (`admin/vite.config.js`, `admin/index.css`). Verified against a throwaway fixture server standing in for `/v1/admin/*` (no live backend available — see the money-invariant caveat this leaves, below): login screen and its invalid-credential error state, the metrics strip (including alarm-red thresholds), a fully-clear vetting case vs. one blocked on unverified documents + disabled payouts, live document verification (optimistic update, confirmed against the fixture server rather than just client state), the full approve cycle (card leaves the queue, count decrements), the disputes queue with both a rich-evidence case and a sparse one (no cleaner assigned, no photos, job never started), `J`/`K` navigation, and the `?` keyboard-shortcut modal. Reject/suspend/resolve weren't exercised end-to-end (browser session dropped mid-run) — they share the identical optimistic-update-then-POST pattern already proven correct by approve, so this is a coverage gap, not a known-broken path.
- **PayPal sandbox spike done (2026-08-24), one real bug found and fixed.** Exercised against a live sandbox app end to end: order create → buyer approval (webview redirect confirmed to carry `token`+`PayerID`, matching what the mobile app captures) → authorize → capture → partial refund → void; both `savePayoutsEmail`'s `$0.01` verification payout and a normal batch payout, checked against their actual `PAYMENT.PAYOUTS-ITEM.SUCCEEDED` webhook resource. Findings:
  - **Fixed:** `webhook.service.js`'s `PAYMENT.CAPTURE.REFUNDED` handler unconditionally set `refunded_cents = captured_cents` and `status = 'refunded'` — correct for a full refund, wrong for a partial one. A live event for a $20 refund on a $75 capture carries the *cumulative* total at `resource.seller_payable_breakdown.total_refunded_amount.value` (here `"20.00"`, not `"75.00"`), which the handler now reads instead of assuming full refund. Before the fix, a partial refund processed through `PaymentService.refund()` (which updates the row correctly) would get silently overwritten back to "fully refunded" once the async webhook landed.
  - **Confirmed correct as written:** `authorize()`'s and `captureAndTransfer()`'s response parsing, `void`'s empty 204 body handling in `paypal.client.js`, and the `PAYMENT.PAYOUTS-ITEM.SUCCEEDED` handler's `resource.payout_item.sender_item_id` path (both the `verify:{cleanerId}` and `payout:{payoutId}` prefixes share that same shape).
  - **Still unconfirmed:** `CUSTOMER.DISPUTE.CREATED`'s resource shape — filing an actual dispute wasn't reachable through the sandbox Resolution Center in the time spent on the spike, so that branch still only follows PayPal's documented payload. Live webhook signature verification (`/v1/notifications/verify-webhook-signature`) also wasn't exercised end to end — there's no publicly reachable receiver in this environment, so delivery to the sandbox webhook always showed "Pending"; the events themselves were instead pulled via `GET /v1/notifications/webhooks-events`. Payouts also carried a real $0.25 fee on a $0.01 verification send in sandbox — worth knowing before assuming the verification payout is negligible-cost at any volume.
- **Matching query index rewrite verified against real Postgres (2026-08-24).** `npm run loadtest:matching` confirms `Index Scan using cleaner_home_gix`, 45ms vs. a 250ms budget. See BACKLOG.md item 10 — getting a database connected also surfaced and fixed six previously-latent bugs (a missing `citext` extension, a non-IMMUTABLE generated column, `node-pg-migrate` double-running `0001_init` because it auto-discovers `.sql` siblings, an undeclared `pino-pretty` dependency that broke every non-prod run, and two bugs in `scripts/seed.js`). None of these had ever actually executed before this.
- Both mobile apps now point at the real backend by default (`main.dart`'s `_devTokenProvider`, a dev-only seeded login — no login screen exists yet), not their fake repositories. `cleaner_app` logs in as `amara.osei@example.com`, `customer_app` as `priya.raman@example.com`. The fakes are left in place, public, for tests/an offline demo.
- **Shared depth/font/illustration pass across all three surfaces (2026-08-27).** `cardShadow`/`seafoamSoft` tokens, brand fonts on the admin console, and hero/icon SVG art on both mobile apps — full detail in BACKLOG.md. Both apps now device-verified: `customer_app`'s half (new `hero_banner.dart`, icon art) turned out to have a real bug the inspection-only review missed — `HeroBanner`'s `Stack` had only a `Positioned` child and no bounded parent, crashing both booking steps that use it on first frame. `flutter analyze` doesn't catch this (layout-time, not static). Fixed with `SizedBox(height: 96)` around the `Stack`; both steps render correctly now. `cleaner_app`'s completion-checkmark animation is covered by `test/active_job_complete_test.dart` (a widget test against a fake repository — see below), since reaching it live turned out to be blocked by a separate Firebase gap, not the geofence.
- **Firebase config being a placeholder blocks more than chat/tracking (found 2026-08-28).** `RealtimeService.publishStatus` runs inside the same DB transaction as every `en_route`/`arrived` status update (`BookingService.updateStatus`), and throws `Can't determine Firebase Database URL` when `FIREBASE_SERVICE_ACCOUNT_JSON` is a placeholder — which it is by default. That means **no live `en_route`/`arrived` transition can complete on a machine without real Firebase credentials**, not just chat and realtime tracking as previously noted here. Confirmed by reaching it live: spoofing GPS (`adb emu geo fix` to the job's actual address, queried from `addresses` via PostGIS) got cleanly past the real 150m geofence, then `arrived` failed on this instead.

## Testing

`npm test` covers `src/domain/*` only, and that's the point: a suite needing live Postgres and a PayPal key is a suite nobody runs before pushing. CI additionally runs the migrations against real PostGIS, seeds, checks the money invariants, and exercises the `ST_DWithin` matching filter (the `schema` job), and runs the booking state-machine suite (`npm run test:integration`, the `integration` job). Those need a database, so they live outside `npm test`.

When you add logic to pricing or ranking, add the test in the same commit. These tests have already caught a one-cent rounding error in the README and a late-cancellation penalty too weak to outweigh 3 km of proximity.

## Where to start

See `BACKLOG.md` — all ten backlog items are done, both Flutter apps analyze clean and have been through a real device pass, both point at the real backend by default, and the admin console's negative-median-match bug is fixed. Remaining gaps worth picking up next:

- The admin console's reject/suspend/resolve flows still haven't been exercised end-to-end (item 4) — they share the same optimistic-update pattern already proven by approve, so this is coverage, not a known break.
- `CUSTOMER.DISPUTE.CREATED`'s webhook shape is still unconfirmed against a real PayPal sandbox dispute.
- Neither app has real Firebase config. This blocks chat and realtime tracking, and also blocks *every* live `en_route`/`arrived` status transition (see Known stubs above) — worth fixing before any further live device verification of the booking/job flow past `assigned`.

If this machine has a native PostgreSQL already listening on 5432 (check `netstat -ano | findstr 5432` — `docker compose`'s port mapping will silently point at it instead of the container, surfacing as `password authentication failed for user "sparkle"`), remap the container to another host port rather than assuming the docker-compose config is wrong. This machine specifically already has `infra-db-1`/`infra-redis-1` containers holding seeded data on 5433/6379 from prior sessions — `docker start` them rather than creating new ones, which will collide on the same ports.
