# Sparkle — working notes for Claude Code

On-demand cleaning marketplace. Node/Express + PostgreSQL + PostGIS backend, two Flutter apps, a React admin console, Firebase for realtime, Stripe Connect for money.

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
2. **Commission is taken on the subtotal only** — never on the Trust & Safety fee, never on tips. `application_fee_amount` = commission + T&S fee.
3. **`src/domain/*.js` has zero imports.** Pricing and ranking math lives there so it stays testable without Postgres. Services own I/O and delegate arithmetic. If you find yourself importing `db/pool.js` into `domain/`, the logic belongs in a service instead.
4. **Every admin action writes an `audit_log` row in the same transaction as the change.** The app DB role has no UPDATE/DELETE grant on that table — don't add one.
5. **Location tracking stops at `arrived`.** Enforced three ways: client tears down the stream, `RealtimeService.publishStatus` deletes the node, Firebase rules reject writes unless `booking_access/{id}/status` is `en_route`. Keep all three.
6. **`booking_access/*` in Firebase is written only by the backend service account.** Clients granting themselves booking access is the whole threat model.
7. **`payouts_enabled` is set only by the Stripe `account.updated` webhook.** Never set it optimistically — the admin approval gate depends on it, and an optimistic value means a job completes and then fails at transfer.
8. **Admins are never created over HTTP.** `npm run create-admin` requires shell access. Don't add a route.
9. **Every Stripe call carries an idempotency key** of the form `booking:{id}:{action}`. Every webhook is recorded in `webhook_events` before processing and skipped if already seen.
10. **Booking status changes go through `BookingService.updateStatus`**, which enforces the `TRANSITIONS` map. Don't UPDATE `bookings.status` directly outside that method (the seed script is the deliberate exception).

## Conventions

- ESM throughout (`"type": "module"`). Node 20+.
- Schema changes go through migrations (`node-pg-migrate`, in `backend/migrations/`). `0001_init` is the whole schema; add the next with `npm run migrate:create -- add_something`, write both `up` and `down`, and let the `schema` CI job prove it applies from an empty database. Migration files are `.cjs` (the package is ESM) or plain `.sql`. Never hand-edit a shipped migration — add a new one.
- Routes validate with zod and authorize; controllers translate HTTP; services hold rules; SQL stays in services/repositories. A service never imports `express`; a route never imports `pg`.
- Errors: throw `AppError.*`; the handler renders RFC 9457 problem details. Never leak internals — the `request_id` ties a response to the log line.
- Any handler touching more than one table wraps in `withTransaction`.
- Webhook routes mount **before** `express.json()` — Stripe signature verification needs the raw body.
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
- `admin/AdminConsole.jsx` is wired to `/v1/admin/*` via `admin/api.js`, but there's no bundler in-repo, so it's never been run in a browser here — verify a render pass before shipping it.

## Testing

`npm test` covers `src/domain/*` only, and that's the point: a suite needing live Postgres and a Stripe key is a suite nobody runs before pushing. CI additionally runs the migrations against real PostGIS, seeds, checks the money invariants, and exercises the `ST_DWithin` matching filter (the `schema` job), and runs the booking state-machine suite (`npm run test:integration`, the `integration` job). Those need a database, so they live outside `npm test`.

When you add logic to pricing or ranking, add the test in the same commit. These tests have already caught a one-cent rounding error in the README and a late-cancellation penalty too weak to outweigh 3 km of proximity.

## Where to start

See `BACKLOG.md`. **All ten items are done.** The one open thread the backlog leaves deliberately unmerged is the matching query's index-friendly rewrite (item 10): `findCandidates`' `ST_DWithin` uses a per-row radius the GiST index can't accelerate — `npm run loadtest:matching` confirms the plan, and the constant-radius-prefilter fix is documented at the call site (`src/services/matching.candidates.sql.js`) but not applied, since it changes the result set. That's the natural next change if matching latency becomes a problem.
