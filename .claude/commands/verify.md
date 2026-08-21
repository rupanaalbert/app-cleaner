---
description: Run the full local verification pass before committing
---

Run these in order and report failures with the smallest reproduction you can find. Stop at the first failure rather than continuing.

1. `cd backend && npm test` — domain math. Should be 16+ passing, under a second.
2. `cd backend && for f in $(find src scripts -name '*.js'); do node --check "$f" || echo "SYNTAX $f"; done`
3. Migrate a scratch database and confirm it runs clean from empty:
   `docker compose -f infra/docker-compose.yml up -d db && cd backend && npm run migrate:up`
4. `cd backend && npm run seed -- --reset`, then verify the money invariants:
   ```sql
   SELECT COUNT(*) FROM bookings
    WHERE total_cents <> subtotal_cents + ts_fee_cents + tax_cents
       OR subtotal_cents <> commission_cents + payout_cents;
   ```
   Must be 0.
5. `cd backend && npm run test:integration` — the booking state machine against the migrated database.
6. `cd mobile/customer_app && flutter analyze`, then the same in `mobile/cleaner_app`.

If you changed pricing or ranking logic and didn't add a test, say so explicitly rather than reporting a clean pass.
