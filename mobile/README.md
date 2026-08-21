# Sparkle mobile

Two Flutter apps, one design language, deliberately different jobs.

| | `cleaner_app` | `customer_app` |
|---|---|---|
| Job of the UI | Decide on a job in ~3 seconds | Understand the price before committing |
| Ground | Marine, high contrast for sunlight | Linen, quiet surfaces |
| Reserved accent | Amber — payouts only | Seafoam — the single forward action |
| Signature element | Expiry ring draining around the payout | Price ledger pinned to the bottom, expandable |

Shared conventions:

- Money is integer cents until the formatter. No doubles in pricing paths.
- Tap targets are 44 pt minimum; disabled beats hidden so controls never shift under a thumb.
- Every screen ships an empty state, an error state with a retry, and a loading state.
- Repositories are interfaces. Each app has a fake implementation that mirrors real backend behavior, so the UI runs and tests without a server.

## Booking flow (`customer_app`)

`service → home → schedule → review`, driven by `BookingController`.

Two details that matter more than they look:

1. **Debounced re-quoting with a sequence guard.** Each quote request carries a number; a slow response for an older draft is dropped. Without it, tapping "3 bedrooms" can leave the 2-bedroom price on screen.
2. **Quote expiry is handled in the UI, not just the API.** The review step counts down the 15-minute window and re-prices automatically when it lapses. A `409 QUOTE_EXPIRED` on confirm re-quotes and asks the customer to look again rather than booking at a price they never saw.

```bash
cd mobile/customer_app && flutter run   # runs against the in-memory fake
```

## Working a job (`cleaner_app`)

Three tabs, in the order a shift actually runs: **Discover** (`JobDiscoveryScreen`) to take work, **Schedule** (`ScheduleScreen`) for what you've committed to, **Earnings** (`EarningsScreen`) for what it paid.

- **Schedule** merges the server's `active` and `upcoming` filters and pins the live job to the top in seafoam — on a shift, the job you're doing now is the only one that matters. Tapping one opens the active-job screen.
- **Active job** (`ActiveJobScreen`) walks the state machine one tap at a time: *on my way → arrived → start → finish*. `arrived` and `completed` are geofenced server-side, so those taps carry a fresh GPS fix from an injected `Locator` (fake in tests). A Deep Clean can't be finished until three after-photos exist — the UI mirrors that gate so the cleaner shoots photos *before* the request is spent, and every refusal (`GEOFENCE_FAILED`, `PHOTOS_REQUIRED`, an illegal transition from a stale screen) comes back as plain language. Photos go presign → PUT to S3, same as documents.
- **Earnings** leads with take-home (the cleaner's share plus tips, in full) in amber, backed by `GET /cleaner/earnings`, with a week / month / all-time switch and the next payout's amount and arrival date.

`main.dart` wires all three tabs to in-memory fakes (and a `FakeLocator`), so the whole app runs and is testable without a backend; swap in `Http*` repositories, a `GeolocatorLocator`, and a real `LocationPublisher` for production.

## Live tracking

Three pieces, deliberately split across two systems:

| Piece | Where | Cadence |
|---|---|---|
| `LocationPublisher` (cleaner) | Firebase RTDB `tracking/{id}` | ~10s, 25 m distance filter |
| Same publisher → backend | `POST /bookings/:id/breadcrumb` | 60s, kept 30 days |
| `TrackBookingScreen` (customer) | RTDB subscription + Google Map | live |

The privacy boundary is enforced three times over, because one layer failing here is a serious incident: the publisher tears the stream down at "Arrived," `RealtimeService.publishStatus` deletes the node server-side, and the Firebase rules reject writes unless `booking_access/{id}/status` is `en_route`. A client that ignores the first two still can't write.

`booking_access/{id}` is written only by the backend service account when a cleaner claims the job. Nothing a client sends can grant it access to a booking.

Stale pings (>60s) render as "location paused — weak signal," not as a frozen dot implying live movement. The ETA prefers the road-distance figure the cleaner app publishes and falls back to a deliberately pessimistic straight-line estimate at 28 km/h.

## Chat

A per-booking thread, in both apps (`features/chat/chat_screen.dart`, driven by `ChatRepository`). It reads and writes `threads/{bookingId}/messages` in Firebase RTDB directly — same reasoning as tracking, and the rules already scope the path to the booking's two parties.

- **Auth.** The rules key `sender_id` on `auth.uid`, so `FirebaseChatRepository.ready()` exchanges the API session for a Firebase custom token (`POST /realtime/token`) and calls `signInWithCustomToken` before any read or write. `firebase_auth` is a dependency in both apps for exactly this.
- **Closing.** The thread is private to the booking and closes 24 hours after completion, when `RealtimeService.revokeAccess` removes `booking_access` and the thread node. The rules then deny reads; the repository maps that `permission-denied` to `ThreadClosed`, and the screen degrades to a read-only "this conversation has closed" state rather than a dead input.
- **Entry points.** Cleaner: a message button in the active-job app bar. Customer: a message button on the tracking screen, shown once a cleaner is assigned. Both are gated on an injected `ChatRepository?`, so the screens still run under the in-memory fakes with no Firebase.

Messages are create-only per the rules (`push()` ids, `sent_at` as a server timestamp, body ≤ 1000 chars), and the list is reversed so new messages pin to the bottom without a scroll controller fighting the keyboard.

## Cleaner onboarding

A hub, not a wizard. Four tasks — profile and hours, documents, payouts, background check — completable in any order, because the Checkr report takes 1–3 days and a linear flow parks every applicant behind the slowest step. The hub says so on the header: *start the background check first*.

The checklist an applicant sees is the same one the reviewer sees in the admin console, worded for them. Cleaner supply is the hard side of this marketplace; an abandoned application is a week of lost jobs, so "what's blocking me" is never a mystery and a rejected document always shows the reviewer's note verbatim.

Documents go presign → PUT to S3 → confirm with a hash. The file never passes through the API, which keeps passport scans out of log lines and APM traces.
