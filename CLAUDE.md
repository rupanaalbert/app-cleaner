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

## Known stubs and rough edges

- Transactional email/SMS deliver through Postmark and Twilio (`src/services/mail.service.js`, `sms.service.js`); with no provider configured they log instead, so dev and tests never hit the network. Sends are best-effort and post-commit — a provider blip loses a resendable message, not the write. No retry queue yet (`notifyQueue` is the place for one).
- **Admin console render pass done (2026-08-24).** The "no bundler in-repo" note was stale — `admin/` already carried a Vite scaffold, just missing Tailwind (so it rendered unstyled) and a proxy for `api.js`'s same-origin `/v1` calls; both are now filled in (`admin/vite.config.js`, `admin/index.css`). Verified against a throwaway fixture server standing in for `/v1/admin/*` (no live backend available — see the money-invariant caveat this leaves, below): login screen and its invalid-credential error state, the metrics strip (including alarm-red thresholds), a fully-clear vetting case vs. one blocked on unverified documents + disabled payouts, live document verification (optimistic update, confirmed against the fixture server rather than just client state), the full approve cycle (card leaves the queue, count decrements), the disputes queue with both a rich-evidence case and a sparse one (no cleaner assigned, no photos, job never started), `J`/`K` navigation, and the `?` keyboard-shortcut modal. Reject/suspend/resolve weren't exercised end-to-end (browser session dropped mid-run) — they share the identical optimistic-update-then-POST pattern already proven correct by approve, so this is a coverage gap, not a known-broken path.
- **PayPal sandbox spike done (2026-08-24), one real bug found and fixed.** Exercised against a live sandbox app end to end: order create → buyer approval (webview redirect confirmed to carry `token`+`PayerID`, matching what the mobile app captures) → authorize → capture → partial refund → void; both `savePayoutsEmail`'s `$0.01` verification payout and a normal batch payout, checked against their actual `PAYMENT.PAYOUTS-ITEM.SUCCEEDED` webhook resource. Findings:
  - **Fixed:** `webhook.service.js`'s `PAYMENT.CAPTURE.REFUNDED` handler unconditionally set `refunded_cents = captured_cents` and `status = 'refunded'` — correct for a full refund, wrong for a partial one. A live event for a $20 refund on a $75 capture carries the *cumulative* total at `resource.seller_payable_breakdown.total_refunded_amount.value` (here `"20.00"`, not `"75.00"`), which the handler now reads instead of assuming full refund. Before the fix, a partial refund processed through `PaymentService.refund()` (which updates the row correctly) would get silently overwritten back to "fully refunded" once the async webhook landed.
  - **Confirmed correct as written:** `authorize()`'s and `captureAndTransfer()`'s response parsing, `void`'s empty 204 body handling in `paypal.client.js`, and the `PAYMENT.PAYOUTS-ITEM.SUCCEEDED` handler's `resource.payout_item.sender_item_id` path (both the `verify:{cleanerId}` and `payout:{payoutId}` prefixes share that same shape).
  - **Still unconfirmed:** `CUSTOMER.DISPUTE.CREATED`'s resource shape — filing an actual dispute wasn't reachable through the sandbox Resolution Center in the time spent on the spike, so that branch still only follows PayPal's documented payload. Live webhook signature verification (`/v1/notifications/verify-webhook-signature`) also wasn't exercised end to end — there's no publicly reachable receiver in this environment, so delivery to the sandbox webhook always showed "Pending"; the events themselves were instead pulled via `GET /v1/notifications/webhooks-events`. Payouts also carried a real $0.25 fee on a $0.01 verification send in sandbox — worth knowing before assuming the verification payout is negligible-cost at any volume.
- **Matching query index rewrite landed but is untested against real Postgres (2026-08-24)** — no PostGIS available in this environment. See BACKLOG.md item 10 for the fix; `npm run loadtest:matching` is the way to confirm it once a database is reachable.

## Testing

`npm test` covers `src/domain/*` only, and that's the point: a suite needing live Postgres and a PayPal key is a suite nobody runs before pushing. CI additionally runs the migrations against real PostGIS, seeds, checks the money invariants, and exercises the `ST_DWithin` matching filter (the `schema` job), and runs the booking state-machine suite (`npm run test:integration`, the `integration` job). Those need a database, so they live outside `npm test`.

When you add logic to pricing or ranking, add the test in the same commit. These tests have already caught a one-cent rounding error in the README and a late-cancellation penalty too weak to outweigh 3 km of proximity.

## Where to start

See `BACKLOG.md`. **All ten items are done**, including the matching query's index-friendly rewrite (item 10) — but that one hasn't been run against real Postgres/PostGIS (none available in this environment), so confirming `npm run loadtest:matching` actually shows `cleaner_home_gix` used instead of `Seq Scan on cleaner_profiles` is the natural first thing to do wherever Postgres is reachable.
