# Tests

```bash
npm test              # node --test — no database, no network, ~250ms
npm run test:integration   # booking state machine against real Postgres+PostGIS
```

`npm test` runs against `src/domain/*`: pure functions with zero imports. That split is the point. Pricing and ranking are where a rounding slip becomes a refund queue or a supply revolt, and a test suite that needs a live Postgres and a PayPal key is a suite nobody runs before pushing.

It names the unit files explicitly (`test/matching.test.js test/pricing.test.js`) rather than pointing `node --test` at `test/`, because the runner's default globbing treats **every** `.js` file under a `test/` directory as a test file — including `test/integration/*`. Keeping the path explicit is what stops the database-backed suite from being dragged into the fast gate. Add a new unit file? Add it to the `test` script too.

## Integration (`test/integration/`)

`booking-state-machine.test.js` is BACKLOG item 1: the concurrency, transition, and constraint behaviour that only means anything against a real database —

- two cleaners racing to accept one job (`FOR UPDATE SKIP LOCKED` → one wins, the loser gets `409 OFFER_TAKEN`, no second offer flips to `accepted`),
- every illegal move in the `TRANSITIONS` map → `409 ILLEGAL_TRANSITION`,
- the `no_double_booking` exclusion rejecting an overlapping live assignment,
- arrival geofencing (rejected far from the property, accepted at it),
- a Deep Clean refusing to complete without three after-photos (`422 PHOTOS_REQUIRED`).

It needs a migrated Postgres+PostGIS at `DATABASE_URL`; run `npm run migrate:up` first. Redis, Firebase, and PayPal are **not** required — the Firebase fan-out and BullMQ enqueues are stubbed, the eager Redis socket is dropped at import, and every assertion targets a path that rejects before capture/transfer. Fixtures are created with unique ids and torn down in `after`, so it's safe to run against a seeded database. CI runs it as the `integration` job (see `.github/workflows/ci.yml`).

`webhook-replay.test.js` is the equivalent for PayPal webhooks — it also covers the two behaviors specific to the PayPal migration: the hold-window disbursement flow (`payout-hold-window.test.js`) and the verification-payout gate on `payouts_enabled` (exercised inline in `webhook-replay.test.js`'s "due failure is replayed" case, since that gate *is* a webhook-driven effect).

The services still own the I/O — resolving which pricing rules apply, filtering candidates in SQL — and delegate the arithmetic here.

**These tests have already earned their keep.** On first run they caught:

1. **A one-cent error in the README.** The worked example claimed a $154.48 total; 1% of 14,950 is 149.5 cents, which rounds up, making it $154.49. The table was wrong, not the code.
2. **A too-weak late-cancellation penalty.** At 0.05 per cancel, a cleaner with four late cancels in 60 days still outranked a reliable cleaner 3 km further away. Now 0.12 — late cancels drive customer churn harder than a short drive saves.
3. **A test that was wrong about a timezone.** `2026-08-23T00:00Z` is Saturday evening in New York, not Friday. Worth knowing before someone debugged a "phantom weekend surcharge" in production.
