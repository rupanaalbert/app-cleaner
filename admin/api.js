// Sparkle admin API client.
//
// Talks to the same `/v1` surface documented in docs/API.md. Access tokens live
// in memory only (never localStorage — an XSS'd bearer token is a bad day); the
// refresh token rides in the httpOnly cookie the server sets for web, with the
// body value kept as a same-session fallback for dev over http where a `secure`
// cookie won't stick. A 401 triggers one silent refresh-and-retry; a second 401
// signs the operator out.
//
// Point at a non-same-origin API by setting `window.__SPARKLE_API_BASE__`
// (e.g. "http://localhost:8080/v1") before this module loads.

const BASE = (typeof window !== 'undefined' && window.__SPARKLE_API_BASE__) || '/v1';

let tokens = { access: null, refresh: null };
let currentUser = null;

export function session() { return currentUser; }
export function isAuthed() { return Boolean(tokens.access); }

/** RFC 9457 problem detail, typed. `code` is the machine code (e.g. PAYOUTS_DISABLED). */
export class ApiError extends Error {
  constructor(status, code, detail, meta) {
    super(detail || code || 'Request failed');
    this.status = status;
    this.code = code;
    this.meta = meta;
  }
}

async function problem(res) {
  let body = null;
  try { body = await res.json(); } catch { /* non-JSON error body */ }
  return new ApiError(res.status, body?.code ?? 'ERROR', body?.detail ?? res.statusText, body?.meta);
}

async function refresh() {
  try {
    const res = await fetch(`${BASE}/auth/refresh`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify(tokens.refresh ? { refresh_token: tokens.refresh } : {}),
    });
    if (!res.ok) { logout(); return false; }
    const data = await res.json();
    tokens = { access: data.access_token, refresh: data.refresh_token ?? tokens.refresh };
    return true;
  } catch {
    logout();
    return false;
  }
}

async function call(path, { method = 'GET', body } = {}, allowRetry = true) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(tokens.access ? { Authorization: `Bearer ${tokens.access}` } : {}),
    },
    credentials: 'include',
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  // Access tokens are short-lived (15m); refresh once, transparently, then retry.
  // Always worth trying on a 401: the refresh token may be the in-memory value
  // or the httpOnly cookie (invisible to JS), and a genuine dead end just 401s
  // the refresh and signs out.
  if (res.status === 401 && allowRetry) {
    if (await refresh()) return call(path, { method, body }, false);
  }
  if (!res.ok) throw await problem(res);
  if (res.status === 204) return null;
  return res.json();
}

export async function login(email, password) {
  const res = await fetch(`${BASE}/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include',
    body: JSON.stringify({ email, password }),
  });
  if (!res.ok) throw await problem(res);
  const data = await res.json();
  if (data.user?.role !== 'admin') {
    // Don't keep a non-admin session around; this console is admin-only.
    logout();
    throw new ApiError(403, 'NOT_ADMIN', 'This console is for admin accounts.');
  }
  tokens = { access: data.access_token, refresh: data.refresh_token };
  currentUser = data.user;
  return data.user;
}

export function logout() {
  tokens = { access: null, refresh: null };
  currentUser = null;
}

/** The `/v1/admin/*` surface. Every method resolves to plain data or throws ApiError. */
export const api = {
  metrics: () => call('/admin/metrics'),
  pendingCleaners: () => call('/admin/cleaners/pending').then((r) => r.cleaners ?? r),
  disputes: (status = 'open') => call(`/admin/disputes?status=${encodeURIComponent(status)}`).then((r) => r.disputes ?? r),
  bookingDossier: (bookingId) => call(`/admin/bookings/${bookingId}`),

  reviewDocument: (documentId, approved, note) =>
    call(`/admin/documents/${documentId}/review`, { method: 'POST', body: { approved, note } }),
  approveCleaner: (cleanerId) => call(`/admin/cleaners/${cleanerId}/approve`, { method: 'POST', body: {} }),
  rejectCleaner: (cleanerId, reason) =>
    call(`/admin/cleaners/${cleanerId}/reject`, { method: 'POST', body: { reason } }),
  suspendCleaner: (cleanerId, days, reason) =>
    call(`/admin/cleaners/${cleanerId}/suspend`, { method: 'POST', body: { days, reason } }),
  resolveDispute: (disputeId, { resolution, refund_cents, penalty }) =>
    call(`/admin/disputes/${disputeId}/resolve`, { method: 'POST', body: { resolution, refund_cents, penalty } }),
};
