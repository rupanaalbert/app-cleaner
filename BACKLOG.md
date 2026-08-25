# Backlog

Ordered by what would hurt most if it stayed broken. Each item has acceptance criteria so it can be picked up cold.

## 1. Integration tests on the booking state machine — **done**

The unit suite covers math. Nothing has ever executed the concurrency path against a real database.

- [x] Two cleaners accept the same offer within the same transaction window → exactly one wins, the loser gets `409 OFFER_TAKEN`, and no second `booking_offers` row flips to `accepted`.
- [x] Every illegal transition in `TRANSITIONS` returns `409 ILLEGAL_TRANSITION`.
- [x] `no_double_booking` exclusion constraint actually rejects an overlapping assignment.
- [x] Geofence rejection at `arrived` when the reported point is >150 m from the property.
- [x] `completed` on a Deep Clean without three after-photos returns `422 PHOTOS_REQUIRED`.

Landed in `backend/test/integration/booking-state-machine.test.js`, behind `npm run test:integration` so `npm test` stays sub-second (it now names the unit files explicitly — the runner globs every `.js` under `test/`, so pointing it at the directory would have swept the DB suite into the fast gate). CI runs it as the `integration` job against the same PostGIS service the `schema` job uses. Redis/Firebase/Stripe are stubbed; every case asserts a path that rejects before money moves.

## 2. Migrations — **done**

`db/schema.sql` couldn't express "add a column to a live table."

- [x] Adopted `node-pg-migrate`. The former `db/schema.sql` is now `backend/migrations/0001_init.sql`, run by `backend/migrations/0001_init.cjs` (init is declared irreversible — `down = false`).
- [x] `npm run migrate:up` / `migrate:down` / `migrate:create`; CI's `schema` and `integration` jobs run `migrate up` from an empty database instead of applying the dump.
- [x] `infra/docker-compose.yml` init mount removed (schema is owned by migrations); README/CLAUDE/verify document the `migrate:up` step before `seed`.

Next DB change: `npm run migrate:create -- add_whatever`, write both `up` and `down`, never edit a shipped migration.

## 3. Stripe webhook replay — **done**

`webhook_events` recorded failures with the error text and nothing replayed them.

- [x] Migration `0002` adds `attempts` / `last_attempt_at` / `next_attempt_at` and a partial replay index.
- [x] The Stripe handler moved out of the route into `WebhookService` (`src/services/webhook.service.js`) so the live delivery and the replay run identical, idempotent code; each event is processed + stamped in one transaction.
- [x] Worker `webhooks` queue sweeps `processed_at IS NULL AND error IS NOT NULL` on a repeatable job — exponential backoff (`webhooks.backoff*`), poison-pilled after `webhooks.maxReplayAttempts`, SKIP LOCKED so two sweeps never collide.
- [x] `GET /admin/webhooks/failed?status=dead|failing|all` inspects them; `POST /admin/webhooks/:id/requeue` hands one back (audited).
- [x] Integration coverage in `test/integration/webhook-replay.test.js` (success, backoff, poison-pill, not-due).

## 4. Wire the admin console to the API — **done**

`admin/AdminConsole.jsx` ran on fixtures.

- [x] Real fetch client + session in `admin/api.js`: admin login, in-memory access token, one-shot `401` refresh-and-retry, `ApiError` carrying the problem-detail `code`.
- [x] Fixtures replaced with live `metrics` / `cleaners/pending` / `disputes`, plus loading / empty / error states; dispute evidence enriched lazily from the booking dossier.
- [x] Optimistic approve / reject / suspend / resolve with rollback; the three gate `422`s (`BACKGROUND_NOT_CLEAR`, `DOCUMENTS_PENDING`, `PAYOUTS_DISABLED`) and `REASON_REQUIRED` surface in the toast.
- [x] Keyboard model intact (`J`/`K`, `A`/`R`/`S`, `1`/`2`, `?`); suspend now also collects a duration.

Render pass now done against a fixture server (see CLAUDE.md's Known stubs) — the "no bundler" note was stale, `admin/` already had a Vite scaffold. A follow-up could add a UI for the item-3 webhook dead-letter endpoints.

## 5. Email and SMS delivery — **done**

`AuthService` issued verification, reset, and OTP codes and only logged them.

- [x] `MailService` (Postmark over its HTTP API, no SDK) and `SmsService` (Twilio) with a log-transport fallback when unconfigured — dev and tests never hit the network.
- [x] The four transactional emails templated as pure functions in `src/services/mail.templates.js` (verify, reset, password-changed, welcome), unit-tested in `npm test`.
- [x] `AuthService` sends after commit, best-effort: register → verify, forgot → reset, reset → password-changed, verify-email → welcome, phone/start → OTP SMS.
- [x] `dev_code` (and any code/link body in logs) exists only under `NODE_ENV=development`, not merely non-prod.

Not wired to a retry queue — a hard provider outage drops the message (resendable). If that's not good enough, enqueue sends on `notifyQueue` with a worker, the way item 3 did for webhooks.

## 6. `_sha256Hex` in the cleaner onboarding repository — **done**

Added `crypto: ^3.0.3` to `mobile/cleaner_app/pubspec.yaml` and replaced the `UnimplementedError` with `sha256.convert(bytes).toString()` over the exact bytes PUT to S3, so the confirm call's hash matches what the backend verifies.

## 7. Cleaner earnings and schedule screens — **done**

The cleaner app had Job Discovery and onboarding; the working-a-job screens were missing.

- [x] `ScheduleScreen` — today/upcoming from the `active` + `upcoming` booking filters, live job pinned on top; taps open the active job.
- [x] `ActiveJobScreen` — the status state machine (en_route → arrived → in_progress → completed) with geofenced `arrived`/`completed` (injected `Locator`), Deep-Clean after-photo capture (presign → S3), and typed handling of `GEOFENCE_FAILED` / `PHOTOS_REQUIRED` / illegal transitions.
- [x] `EarningsScreen` — take-home in amber from `GET /cleaner/earnings`, week/month/all-time, next payout.
- [x] Repositories `JobsRepository` / `EarningsRepository` (+ `HttpJobsRepository`/`HttpEarningsRepository` and fakes), `Locator` abstraction, and a three-tab `HomeShell` in `main.dart`.

Not compiled or run here (no Flutter toolchain) — needs `flutter analyze` + a device pass. `image_picker` was added to `pubspec.yaml` for photo capture.

## 8. Chat — **done**

Firebase rules for `threads/{bookingId}` were written and enforced; nothing consumed them.

- [x] `ChatRepository` (+ `FirebaseChatRepository` and fakes) and a `ChatScreen` in **both** apps, reading/writing `threads/{bookingId}/messages` per the rule schema (`sender_id` = `auth.uid`, `body` ≤ 1000, `sent_at` server timestamp, create-only).
- [x] Firebase custom-token sign-in wired via `POST /realtime/token` (`firebase_auth` added to both apps) — the missing plumbing the rules require.
- [x] Closes 24h after completion: `permission-denied` (after `RealtimeService.revokeAccess`) maps to `ThreadClosed`, and the screen goes read-only.
- [x] Entry points: cleaner active-job app bar, customer tracking screen (once a cleaner is assigned), both gated on an injected repo so the fakes still run.

Not compiled or run here (no Flutter toolchain). Also unaddressed: the same custom-token sign-in should back the existing tracking screen (which reads RTDB but never signs in) — pre-existing, out of this item's scope.

## 9. Observability — **done**

Structured logs existed; there were no metrics.

- [x] A zero-dependency Prometheus registry (`src/observability/metrics.js`, unit-tested) exposed at `GET /metrics` on both the API and the worker (`WORKER_METRICS_PORT`), optionally bearer-gated.
- [x] Counters/histograms for match rate (`bookings_created` / `bookings_matched`), `time_to_match_seconds`, `payment_capture_failures_total`, and `webhook_processed_total` / `webhook_lag_seconds`, instrumented at the real call sites (dispatch/accept, capture, webhook ingest+replay).
- [x] A worker sweep sets `sparkle_bookings_stuck_pending_match` and logs an error-level alert when a booking sits in `pending_match` past two dispatch rounds (`2 × offerTtlSeconds`).

No tracing (spans) — out of the "at minimum" scope. Metrics are per-process; Prometheus scrapes the API and worker as two targets.

## 10. Load-test the matching query — **done**

`findCandidates` does a PostGIS radius scan plus three correlated subqueries per candidate.

- [x] The query is extracted to `src/services/matching.candidates.sql.js` (single source of truth) and imported by both the service and the harness, so the measured SQL can't drift from the shipped SQL.
- [x] `npm run loadtest:matching [-- --cleaners N] [--keep]` generates synthetic supply, `ANALYZE`s, and runs `EXPLAIN (ANALYZE, BUFFERS)` against it, printing the plan and a verdict (index use, seq scan, execution time vs a budget). All rows are tagged `loadtest-*` and cleaned up unless `--keep`.

**The index-friendly rewrite has landed (2026-08-24).** `matching.candidates.sql.js` now carries a second `ST_DWithin` — a constant-radius prefilter (`$8`) ahead of the exact per-row check — that a GiST index CAN use, since a bind parameter is constant for the query even though `service_radius_km` varies per row. `$8` is derived from the new `config.matching.maxServiceRadiusKm` (60, the same bound `onboarding.routes.js`'s zod schema now reads from instead of a hardcoded literal) times the round's radius multiplier, computed identically in `matching.service.js` and `loadtest-matching.js`. Migration `0004_service_radius_bound` backs the bound with a real `CHECK` constraint, so a write path that skips the zod validation can't quietly put a cleaner's radius past what the prefilter assumes is impossible.

**Verified live (2026-08-24).** `npm run loadtest:matching` against real Postgres/PostGIS confirms `Index Scan using cleaner_home_gix` on the radius prefilter — no seq scan — at 45ms against the 250ms budget.

Getting a real database connected surfaced six previously-latent bugs, all now fixed (none of these paths had ever actually executed before):

- **`0001_init.sql` used `citext` without `CREATE EXTENSION citext`.** Migration failed on the very first table that has an email column. Added the extension alongside the other three.
- **`time_span`'s `GENERATED ALWAYS AS` expression wasn't IMMUTABLE.** `scheduled_at + interval` is STABLE per Postgres's type system (the `+` operator doesn't know the interval is minutes-only, so it won't assume DST can't matter). Wrapped it in `booking_time_span()`, a `LANGUAGE sql IMMUTABLE` function — legitimate here because the interval genuinely never carries months/days.
- **`node-pg-migrate` was running `0001_init` twice per `migrate up`.** It auto-discovers plain `.sql` files as migrations in their own right, so the sibling `0001_init.sql` (meant only to be `readFileSync`'d by `0001_init.cjs`) was *also* picked up and executed standalone — same schema, same transaction, second `CREATE TYPE` collides with the first. Fixed with `--ignore-pattern '^0001_init\.sql$'` on `migrate:up`/`migrate:down` in `package.json` (scoped to that one file, not all `.sql` — future migrations from `migrate:create` are meant to be raw `.sql`).
- **`pino-pretty` was never a declared dependency.** `src/utils/logger.js` unconditionally requires it as the transport whenever `!config.isProd` — i.e. every dev/test/CI run outside production. Added to `package.json` dependencies.
- **`scripts/seed.js` reused a bound parameter across incompatible inferred types, twice.** `$5` was both the `bg_status` enum value and the bare-text comparand in two `CASE WHEN $5 = 'clear'` branches (`text versus bg_check_status`); `$9` was both the integer `duration_min` and the operand of `$9 || ' minutes'` (`text versus integer`). Postgres can't unify a parameter's type across incompatible usages — pinned each with an explicit cast.
- **`scripts/seed.js` built fake PayPal order/auth/capture/payout ids from `booking.id.slice(0, 8)`.** `uuid_generate_v7()` is time-ordered — the leading 8 hex chars are the millisecond timestamp, shared by every row inserted in the same seed run, so two bookings collided on `payments_paypal_order_id_uq`. Switched to `.slice(-8)`, which comes from the UUID's random tail instead.

Running `npm run test:integration` for the first time (also never previously executed — see item 1's history) turned up two more, in the code the tests actually exercise:

- **`MatchingService.acceptOffer`'s loser could get `OFFER_CLOSED` instead of the documented, tested `OFFER_TAKEN`.** The function locked the *offer* row (`FOR UPDATE OF o`) before the *booking* row (`FOR UPDATE SKIP LOCKED`). The booking-row lock is the deterministic race arbiter — `SKIP LOCKED` never blocks, so the loser always finds no row there. But if the loser's offer-row lock request landed after the winner's transaction had already reached its "mark every other offer superseded" `UPDATE` (which touches the loser's offer row), the loser would block on *that* lock, then wake up to find its own offer already `superseded` and report the wrong code — a genuine, timing-dependent nondeterminism in a function whose entire job is to be deterministic under contention. Fixed by reordering: check the booking row first (unlocked existence/expiry check on the offer happens earlier, since that part genuinely can't race), and only lock the offer row for whichever transaction actually won the booking. Ran the concurrent-accept test 5x after the fix with no flake.
- **`test/integration/payout-hold-window.test.js`'s teardown never deleted the bookings, quotes, or properties it created** — only addresses and users, in that order, which fails outright (`addresses` is still referenced by `properties`) the moment `payouts`/`bookings`/`quotes`/`properties` aren't cleared first (those hold `RESTRICT` or default `NO ACTION` FKs, same as `booking-state-machine.test.js`'s teardown already accounted for). Added the missing deletes in dependency order (payouts → bookings → quotes/properties → addresses → users).

Also fixed for local reliability (not bugs in the app itself): `test:integration`'s `node --test test/integration/` bare-directory form doesn't discover files under Node 24 (works fine with an explicit glob, which also works on the Node 20 CI pins) — changed to `node --test test/integration/*.test.js`.

One environment note, not a repo bug: this machine already had a native (non-Docker) PostgreSQL listening on 5432, so `docker compose up`'s port mapping silently pointed `localhost:5432` at the wrong server (`password authentication failed for user "sparkle"` was the symptom). Worked around it locally by remapping the container to 5433 for this verification; `infra/docker-compose.yml` itself is unchanged. Anyone hitting the same symptom on this machine should check `netstat -ano | findstr 5432` before assuming the container is misconfigured.

All of the above verified together: unit suite (26/26), integration suite (11/11, concurrent-accept re-run 5x clean), the CI money-invariant query (0 violations on seeded data), and the matching loadtest.

**Pushed (2026-08-25) and checked against real CI**, not just local Postgres — this caught one more bug the local runs above couldn't, because a local `.env` was masking it: CI's `schema` job has failed on every run since it existed (confirmed by checking prior runs' per-job results, all the way back to the initial commit), at `node backend/scripts/seed.js`. `config/index.js` requires `REDIS_URL`, both JWT secrets, and all three PayPal vars with no defaults — `test/integration/*.test.js` already works around this via `test/helpers/env.js` (imported first, before any `src/` module loads config), but `scripts/seed.js` had no equivalent, and CI's `schema` job step never set those vars (it only sets `DATABASE_URL`/`PGPASSWORD` — seed.js touches neither Redis nor PayPal). Added `scripts/helpers/env.js`, the same pattern, imported first in `seed.js`. Reproduced the exact failure locally (fresh db, `.env` moved aside, only `DATABASE_URL` set) before and after the fix to confirm.

Post-push CI state: `unit` and `integration` are now green (previously `integration` also failed, on the same migration bugs above — this is a real improvement, not just local-only). `schema` should go green on the next push with this fix. `mobile (cleaner_app)` / `mobile (customer_app)` still fail at `flutter analyze` — expected, matches the caveat on items 6-8 below (never run through a Flutter toolchain) and is unrelated to this item.
