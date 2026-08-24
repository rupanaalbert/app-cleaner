# Admin console

Single-screen Trust & Safety console, wired to the live `/v1/admin/*` API through [`api.js`](./api.js).

**Wiring.** `api.js` holds the fetch client and session: `login` / `logout`, an in-memory access token, and a one-shot refresh-and-retry on `401` (the refresh token rides the httpOnly cookie for web, with the login-response value kept as a same-session fallback for dev over http). `AdminConsole.jsx` gates on an admin sign-in, then loads metrics, the vetting queue, and open disputes. Decisions are **optimistic** — approve/reject/suspend/resolve drop the card immediately and put it back if the server rejects, surfacing the reason (the three approval-gate `422`s, `REASON_REQUIRED`, `ALREADY_RESOLVED`) in the toast. Dispute evidence (status timeline, time on site) is pulled lazily from `GET /admin/bookings/:id` when a case opens.

Same-origin by default. To point at an API on another origin, set `window.__SPARKLE_API_BASE__` (e.g. `"http://localhost:8080/v1"`) before the bundle loads; the backend already reflects CORS with credentials. There is no bundler in this repo — drop these two files into the host app (React + Tailwind + `lucide-react`).

**Why a queue, not a dashboard.** Vetting and dispute work is a stream of repetitive judgement calls. The screen is built for the 200th decision of a shift: one case at a time, evidence and decision controls on the same screen, `J`/`K` to move, `A` to approve. A grid of cards with a modal per record adds two clicks to every decision, and agents make hundreds.

**Three things the UI refuses to do:**

1. **Approve past the gates.** Clear background check, every document reviewed, PayPal payouts verified. The button is disabled *and* the unmet gates are listed — a disabled control with no explanation is how agents end up messaging engineering. The API enforces the same three independently; the UI is a convenience, not the control.
2. **Reject or suspend without a reason.** The textarea is required client-side and the endpoint returns `400 REASON_REQUIRED` regardless. The note goes to the applicant, so it's labelled as something they will read.
3. **Couple refunds to cleaner fault.** Separate controls, by design. A broken lockbox makes the customer whole and leaves the cleaner blameless; one combined "resolve" slider teaches agents to under-refund to protect good cleaners.

**Audit.** Every admin action writes to `audit_log` in the same transaction as the change. The app database role has no `UPDATE` or `DELETE` grant on that table, so an admin cannot quietly rewrite their own trail. That's the difference between having logs and having evidence.
