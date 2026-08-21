# Sparkle API — v1

Base: `https://api.sparkle.app/v1` · JSON only · all money in integer cents.

**Auth**: `Authorization: Bearer <access_token>` (JWT, 15 min). Refresh via `POST /auth/refresh` with a rotating, device-bound refresh token. Claims: `sub`, `role`, `jti`.

**Idempotency**: every `POST` that moves money or creates a booking requires `Idempotency-Key: <uuid>`. Replays return the original response with `Idempotent-Replay: true`.

**Errors**: RFC 9457 problem detail.
```json
{ "type": "https://api.sparkle.app/errors/slot-unavailable",
  "title": "No cleaners available",
  "status": 409, "detail": "No approved cleaner serves 02148 at that time.",
  "code": "NO_SUPPLY", "request_id": "req_01J8..." }
```

`400` validation · `401` bad token · `403` wrong role or not a party to the booking · `404` · `409` state conflict · `422` business rule · `429` rate limit · `402` payment failure.

---

## Booking flow

### `POST /quotes` — price estimate
Customer. No money moves. Quote is binding for 15 minutes.

```json
{ "property_id": "018f...", "service_code": "standard",
  "addon_codes": ["inside_oven"],
  "scheduled_at": "2026-08-22T14:00:00Z" }
```
Property may be inlined instead of referenced (`property: { bedrooms, bathrooms, square_feet, address_id }`) for guest checkout.

`201`
```json
{ "quote_id": "018f...", "expires_at": "2026-08-15T18:15:00Z",
  "duration_min": 180,
  "breakdown": {
    "base_cents": 4900,
    "bedrooms": { "count": 3, "unit_cents": 1200, "cents": 3600 },
    "bathrooms": { "count": 2, "unit_cents": 1500, "cents": 3000 },
    "size_tier_cents": 1500,
    "addons": [{ "code": "inside_oven", "cents": 2500 }],
    "multipliers": [{ "code": "weekend", "factor_bps": 11500 }],
    "subtotal_cents": 17825,
    "trust_safety_fee_cents": 527,
    "tax_cents": 0
  },
  "total_cents": 18352 }
```
Errors: `422 OUTSIDE_SERVICE_AREA`, `422 LEAD_TIME_TOO_SHORT` (< 2h), `409 QUOTE_EXPIRED` on reuse.

---

### `POST /bookings` — confirm and authorize
Customer. Creates the booking, authorizes the card, enqueues matching. Atomic: if the PaymentIntent fails, no booking row survives.

```json
{ "quote_id": "018f...", "payment_method_id": "pm_1P...",
  "special_instructions": "Cat is friendly. Code #4417.",
  "entry_method": "lockbox" }
```

`201`
```json
{ "booking": {
    "id": "018f...", "reference": "SPK-8J4K2Q", "status": "pending_match",
    "scheduled_at": "2026-08-22T14:00:00Z", "duration_min": 180,
    "total_cents": 18352, "cleaner": null },
  "payment": { "status": "authorized", "authorized_cents": 20187,
               "client_secret": "pi_..._secret_..." } }
```
The authorization carries a ~10% buffer for overage; only the actual amount is captured. Errors: `402 CARD_DECLINED`, `409 QUOTE_EXPIRED`, `409 SLOT_TAKEN`.

---

### `GET /bookings/:id`
Either party or admin. The customer sees the cleaner's first name, photo, rating, and masked number once `assigned`. The cleaner sees the full street address and `access_notes` only from `assigned` until 24h after `completed` — before and after that window those fields are omitted, not nulled.

---

### `GET /bookings?status=upcoming&limit=20&cursor=...`
Cursor-paginated, newest first. `status` accepts `upcoming | past | active | canceled`.

---

### `POST /bookings/:id/cancel`
```json
{ "reason": "schedule_conflict" }
```
`200` → `{ "status": "canceled", "cancel_fee_cents": 8912, "refund_cents": 9440 }`

Customer cancels ≥12h out: full refund, authorization released. Under 12h: 50% of subtotal captured and paid to the assigned cleaner. Cleaner cancels: no fee, reliability score penalty, booking re-enters `pending_match` with a priority flag.

---

## Matching (cleaner-facing)

### `GET /cleaner/offers`
Open offers ranked for this cleaner, newest first. Powers the Job Discovery screen.

`200`
```json
{ "offers": [{
    "offer_id": "018f...", "booking_id": "018f...",
    "service": { "code": "deep", "name": "Deep Clean" },
    "scheduled_at": "2026-08-22T14:00:00Z", "duration_min": 180,
    "payout_cents": 14260,
    "distance_km": 4.2, "travel_min": 11,
    "neighborhood": "Malden, MA 02148",
    "approx_location": { "lat": 42.4258, "lng": -71.0662 },
    "property": { "bedrooms": 3, "bathrooms": 2, "square_feet": 1600, "has_pets": true },
    "expires_at": "2026-08-15T18:03:30Z" }],
  "next_cursor": null }
```
`approx_location` is jittered to ~300 m. Exact coordinates are released on accept.

### `POST /offers/:id/accept`
First claim wins via `SELECT … FOR UPDATE SKIP LOCKED`. `200` returns the full booking with exact address; `409 OFFER_TAKEN` or `410 OFFER_EXPIRED` otherwise.

### `POST /offers/:id/decline`
`{ "reason": "too_far" }` → `204`. Reasons feed radius tuning; declines do not penalize, non-responses do.

---

## Job execution

### `PATCH /bookings/:id/status`
Cleaner only. The only legal transitions are `assigned→en_route→arrived→in_progress→completed`; anything else is `409 ILLEGAL_TRANSITION`.

```json
{ "status": "arrived", "location": { "lat": 42.4258, "lng": -71.0662, "accuracy_m": 12 } }
```
`arrived` and `completed` require a location within 150 m of the property (`422 GEOFENCE_FAILED`). `completed` on a Deep Clean requires ≥3 `after` photos (`422 PHOTOS_REQUIRED`) and triggers capture + transfer.

### `POST /bookings/:id/photos`
`{ "phase": "before", "count": 4 }` → presigned S3 PUT URLs. Photos never pass through the API.

### `POST /bookings/:id/call`
Opens a Twilio Proxy session. `200` → `{ "proxy_number": "+16175550142", "expires_at": "..." }`. Valid from `assigned` until 2h after `completed`.

### `POST /realtime/token`
Exchanges an API access token for a Firebase custom token (1h). Clients authenticate once, against our identity system — Firebase never becomes a second, weaker signup path.

`200` → `{ "firebase_token": "eyJ...", "expires_in": 3600 }`

### `POST /bookings/:id/breadcrumb`
Cleaner only, rate-limited to 3/min. `{ "lat": 42.42, "lng": -71.06 }` → `204`. The coarse trail that survives for disputes.

**Live tracking is not an endpoint.** The cleaner app writes to Firebase RTDB `tracking/{bookingId}` roughly every 10s while `en_route`; the customer app subscribes. Access is governed by `booking_access/{bookingId}`, which only the backend service account writes (on offer accept, via `RealtimeService.grantAccess`). Rules allow location writes only while that node's status is `en_route`, so tracking ends at the door rather than relying on the client to stop. The whole channel — tracking, chat, access index — is torn down 24h after completion, once the dispute window closes.

---

## Payments

### `POST /bookings/:id/payments/capture`
Internal/admin; normally fired automatically on `completed`.
```json
{ "actual_duration_min": 195 }
```
`200`
```json
{ "captured_cents": 18352, "application_fee_cents": 4092,
  "transfer": { "id": "tr_1P...", "amount_cents": 14260, "destination": "acct_1P..." } }
```

### `POST /bookings/:id/tip`
Within 24h of completion. Tips transfer 100% to the cleaner — no commission, no fee.

### `POST /bookings/:id/refund`
Admin or automated dispute resolution. `{ "amount_cents": 5000, "reason": "quality" }` → creates a `refunds` row and a reversing `ledger_entries` pair.

### `GET /cleaner/earnings?from=&to=`
`200` → `{ "gross_cents", "commission_cents", "net_cents", "tips_cents", "jobs": 14, "next_payout": { "amount_cents", "arrival_date" } }`

### `POST /webhooks/stripe`
Raw body, signature-verified. Handled: `payment_intent.succeeded`, `payment_intent.payment_failed`, `charge.refunded`, `charge.dispute.created`, `transfer.created`, `payout.paid`, `payout.failed`, `account.updated` (gates `payouts_enabled`). Every event is inserted into `webhook_events` first; duplicates return `200` without reprocessing. A handler that throws is recorded (not 5xx'd, which would trigger Stripe's own retries) and picked up by the replay sweep — exponential backoff, poison-pilled after `webhooks.maxReplayAttempts`, then visible under `GET /admin/webhooks/failed`.

### `POST /webhooks/checkr`
`report.completed` → maps Checkr status to `bg_check_status`; `clear` advances onboarding to `approved` and unlocks dispatch. `consider` routes to admin review; the report body is never persisted.

---

## Reviews

### `POST /bookings/:id/reviews`
Both parties, within 14 days of `completed`. One per side.
```json
{ "rating": 5, "tags": ["punctual","thorough"], "comment": "Spotless." }
```
Reviews stay hidden until both sides submit or the window closes — double-blind, so neither side rates retaliatorily. Publication enqueues a rating recompute; a cleaner whose trailing-20 average falls below 4.3 is removed from dispatch and flagged for coaching.

### `GET /cleaners/:id/reviews?limit=20&cursor=`
Public, hidden reviews excluded.

---

## Privacy

| Endpoint | Behavior |
|---|---|
| `GET /me/export` | Enqueues export; `202` with `request_id`. Signed ZIP emailed within 30 days, link expires in 72h. |
| `DELETE /me` | `202`, erasure scheduled +14 days. Cancelable by logging in. PII crypto-shredded; financial rows retained under legal-obligation exemption. |
| `PATCH /me/privacy` | `{ "dns_optout": true }` — CCPA do-not-sell/share. |
| `POST /me/consents` | Records purpose + policy version + IP. |

---

## Rate limits

| Scope | Limit |
|---|---|
| Auth endpoints | 10 / 15 min / IP |
| `POST /quotes` | 60 / hour / user |
| `POST /bookings` | 10 / hour / user |
| Status updates | 120 / hour / cleaner |
| Everything else | 600 / 15 min / token |

Headers: `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`.

---

## Admin

All routes below require `role: admin` and write an `audit_log` row in the same transaction as the change they make.

| Endpoint | Notes |
|---|---|
| `GET /admin/metrics` | Revenue and GMV (7d), match rate, median match time, supply online, open disputes, SLA breaches, cleaners below the 4.3 floor. |
| `GET /admin/cleaners/pending` | Vetting queue with documents. **Oldest first** — applicants who have waited longest are the ones about to go drive for someone else. |
| `POST /admin/documents/:id/review` | `{ approved, note }`. |
| `POST /admin/cleaners/:id/approve` | Three gates, none waivable: `bg_status = clear`, every document verified, `payouts_enabled`. Returns `422 BACKGROUND_NOT_CLEAR`, `422 DOCUMENTS_PENDING`, or `422 PAYOUTS_DISABLED`. Approving a cleaner who can't be paid produces a job that completes and then fails at transfer. |
| `POST /admin/cleaners/:id/reject` | `{ reason }` required — `400 REASON_REQUIRED` otherwise. |
| `POST /admin/cleaners/:id/suspend` | `{ days, reason }`. Pulls the cleaner from dispatch; live bookings are left alone rather than stranding a customer mid-job. |
| `GET /admin/disputes?status=open` | Queue with evidence counts: photos, breadcrumbs, geofence results, customer rating. |
| `POST /admin/disputes/:id/resolve` | `{ resolution, refund_cents, penalty }`. Refund and penalty are independent by design. Refunds use `reverse_transfer` so the cleaner's share is clawed back proportionally. |
| `GET /admin/bookings/:id` | Full dossier: status timeline with geofence points, photos, payment, reviews, breadcrumb trail. |
| `GET /admin/webhooks/failed?status=dead` | Provider webhooks the replay sweep couldn't process. `status`: `dead` (poison-pilled, default), `failing` (still retrying), `all`. Payload omitted; response carries `poison_pill_at`. |
| `POST /admin/webhooks/:id/requeue` | Hand a failed webhook back to the sweep: resets `attempts`, makes it due now, nudges the queue. `409 ALREADY_PROCESSED` if it already succeeded. |

---

## Cleaner onboarding

Four independent tracks plus a submit step. Order is not enforced: the Checkr report takes 1–5 days, so it starts as early as the candidate allows and the rest of the application is filled in while it runs.

| Endpoint | Notes |
|---|---|
| `GET /cleaner/onboarding` | Per-step completion and a plain-English `detail` for each. Same gates the admin console enforces — an applicant who can see what's blocking them doesn't open a ticket. |
| `PATCH /cleaner/onboarding/profile` | Bio, experience, service types, radius, home point. |
| `PUT /cleaner/onboarding/availability` | Replaces the whole weekly schedule. Partial edits of a calendar are a bug factory. |
| `POST /cleaner/onboarding/documents` | Returns a presigned S3 PUT (15 min, SSE-KMS). Documents never transit the API. Re-uploading a rejected type replaces it rather than stacking rows. |
| `POST /cleaner/onboarding/documents/:id/confirm` | `{ sha256 }` after the PUT succeeds. |
| `POST /cleaner/onboarding/payouts` | Creates a Stripe Connect Express account if needed, returns a one-time account link. `payouts_enabled` is only ever set by the `account.updated` webhook — Stripe decides when an account can receive money. |
| `POST /cleaner/onboarding/background-check` | Creates the Checkr candidate and invitation. Only the report id and verdict are stored; the report body never is. |
| `POST /cleaner/onboarding/submit` | `422 ONBOARDING_INCOMPLETE` with the outstanding steps. A still-running background check does **not** block submission — a reviewer can work the rest of the file while it lands. |
| `PATCH /cleaner/availability` | The online toggle. `422 NOT_APPROVED` before approval. |

---

## Auth

Access tokens are 15-minute JWTs and are never revoked — with a window that small, a revocation list costs a database read on every request for almost nothing. Refresh tokens carry the weight: opaque, stored hashed, single-use, and grouped into a **family** per login.

**Rotation with reuse detection.** Every refresh returns a new token and burns the old one. Presenting an already-used token means two parties hold the same secret — the real client and whoever copied it. We can't tell which is which, so the whole family is revoked and both must sign in again. Annoying once; safe always.

| Endpoint | Notes |
|---|---|
| `POST /auth/register` | `{ email, password, full_name, phone?, role }`. `role` accepts `customer` or `cleaner` only. Creates the role profile, records ToS + privacy consent with IP and user agent, and sends the email-verification link. |
| `POST /auth/login` | Generic `401` on both wrong email and wrong password, and a dummy Argon2 verify when the user is missing so response timing isn't an account-existence oracle. A login also cancels a pending erasure. |
| `POST /auth/refresh` | Body or `sparkle_refresh` cookie. Returns a fresh pair. |
| `POST /auth/logout` | `{ all_devices }` revokes every live family. |
| `POST /auth/verify-email` | Single-use 32-byte token, 24h. Verifying sends the welcome email. |
| `POST /auth/phone/start` · `/phone/verify` | 6-digit code, 10 min, burned after 5 wrong attempts — otherwise a six-digit code falls to a million guesses. `/start` sends the code by SMS (Twilio); it is returned in the response as `dev_code` **only** when `NODE_ENV=development`. |
| `POST /auth/password/forgot` | Always `{ sent: true }`, whether or not the address exists. When it does, a reset email goes out (Postmark). |
| `POST /auth/password/reset` | Revokes every session on success and emails a "password changed" security notice: if the reset was the attacker's doing the owner finds out immediately, and if it was the owner's, any session the attacker held is dead. |

Rate limit: 10 per 15 minutes per IP on every unauthenticated route here. Credential stuffing is the real threat model.

**Delivery.** Email goes through Postmark (`POSTMARK_TOKEN`), SMS through Twilio (`TWILIO_MESSAGING_SERVICE_SID` or `TWILIO_FROM`). With neither configured — local dev and tests — both fall back to a log transport that never touches the network, and the code/link body is logged only under `NODE_ENV=development`. Sends are best-effort and happen after the database commit: a provider outage degrades to a missing (resendable) message, never a failed request. The four transactional emails — verify, reset, password-changed, welcome — are templated in `src/services/mail.templates.js`.

**Admins are not created over HTTP.** `npm run create-admin -- ops@sparkle.app "Dana Osei"` requires shell access to a machine that already has the production `DATABASE_URL`. An API route that mints admins is an API route that hands over the platform.
