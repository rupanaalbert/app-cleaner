import React, { useState, useEffect, useMemo, useCallback } from "react";
import {
  ShieldCheck, AlertTriangle, Clock, FileText, Check, X, Ban,
  MapPin, Camera, Star, ChevronRight, Keyboard, CircleDot, Loader2, LogOut,
} from "lucide-react";
import { api, login as apiLogin, logout as apiLogout, session, isAuthed, ApiError } from "./api.js";

/**
 * Sparkle — Trust & Safety console.
 *
 * This is not a dashboard. Vetting and dispute work is a queue of repetitive
 * judgement calls, so the screen is built for the 200th decision of the shift,
 * not the first: one case at a time, evidence and decision on the same screen,
 * and hands on the keyboard. J/K to move, A to approve, R to reject.
 *
 * Wired to the live `/v1/admin/*` API via ./api.js. Decisions are optimistic —
 * the card leaves the queue immediately and is put back if the server rejects
 * it — so an agent is never waiting on a round trip. The three approval gates
 * are enforced server-side; the UI mirrors them as reasons and surfaces the
 * 422 if its view was stale.
 */

const usd = (cents) =>
  ((cents ?? 0) / 100).toLocaleString("en-US", { style: "currency", currency: "USD" });

const ago = (iso) => {
  const h = Math.round((Date.now() - new Date(iso)) / 3.6e6);
  if (h < 1) return "just now";
  if (h < 24) return `${h}h ago`;
  return `${Math.round(h / 24)}d ago`;
};

// ------------------------------------------------------------------- shell --
export default function AdminConsole() {
  const [authed, setAuthed] = useState(isAuthed());
  const signOut = useCallback(() => { apiLogout(); setAuthed(false); }, []);

  if (!authed) return <LoginScreen onSignedIn={() => setAuthed(true)} />;
  return <Console onSignOut={signOut} />;
}

function Console({ onSignOut }) {
  const [tab, setTab] = useState("vetting");
  const [metrics, setMetrics] = useState(null);
  const [cleaners, setCleaners] = useState([]);
  const [disputes, setDisputes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);
  const [cursor, setCursor] = useState(0);
  const [toast, setToast] = useState(null);
  const [showKeys, setShowKeys] = useState(false);

  const queue = tab === "vetting" ? cleaners : disputes;
  const current = queue[Math.min(cursor, queue.length - 1)];

  const say = useCallback((text, tone = "ok") => {
    setToast({ text, tone });
    setTimeout(() => setToast(null), 3600);
  }, []);

  const switchTab = useCallback((next) => { setTab(next); setCursor(0); }, []);

  const load = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      const [m, c, d] = await Promise.all([
        api.metrics(), api.pendingCleaners(), api.disputes("open"),
      ]);
      setMetrics(m);
      setCleaners(c);
      setDisputes(d);
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) return onSignOut();
      setLoadError(err.detail || err.message || "Could not load the queue.");
    } finally {
      setLoading(false);
    }
  }, [onSignOut]);

  useEffect(() => { load(); }, [load]);

  // Metrics move with each decision; refresh them quietly, never block on them.
  const refreshMetrics = useCallback(async () => {
    try { setMetrics(await api.metrics()); } catch { /* non-critical */ }
  }, []);

  useEffect(() => {
    const onKey = (e) => {
      if (e.target.tagName === "TEXTAREA" || e.target.tagName === "INPUT") return;
      if (e.key === "j" || e.key === "ArrowDown") setCursor((c) => Math.min(c + 1, queue.length - 1));
      if (e.key === "k" || e.key === "ArrowUp") setCursor((c) => Math.max(c - 1, 0));
      if (e.key === "1") switchTab("vetting");
      if (e.key === "2") switchTab("disputes");
      if (e.key === "?") setShowKeys((s) => !s);
      if (e.key === "Escape") setShowKeys(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [queue.length, switchTab]);

  // Optimistic: drop the card now, call the API, restore it on failure. Rethrow
  // so the case panel can stop its spinner and stay put.
  const decideCleaner = useCallback(async (cleaner, action) => {
    const snapshot = cleaners;
    const idx = snapshot.findIndex((c) => c.user_id === cleaner.user_id);
    setCleaners((prev) => prev.filter((c) => c.user_id !== cleaner.user_id));
    setCursor((c) => Math.max(0, Math.min(c, snapshot.length - 2)));
    try {
      if (action.verb === "approve") await api.approveCleaner(cleaner.user_id);
      else if (action.verb === "reject") await api.rejectCleaner(cleaner.user_id, action.reason);
      else await api.suspendCleaner(cleaner.user_id, action.days, action.reason);
      const past = { approve: "approved", reject: "rejected", suspend: "suspended" }[action.verb];
      say(`${cleaner.full_name} ${past}.`, action.verb === "approve" ? "ok" : "warn");
      refreshMetrics();
    } catch (err) {
      setCleaners(snapshot);
      setCursor(Math.max(0, idx));
      // The three gates (BACKGROUND_NOT_CLEAR / DOCUMENTS_PENDING /
      // PAYOUTS_DISABLED) and REASON_REQUIRED all arrive here with a human detail.
      say(err.detail || err.message || "That didn’t go through.", "warn");
      throw err;
    }
  }, [cleaners, say, refreshMetrics]);

  const verifyDoc = useCallback(async (cleanerId, docId) => {
    const snapshot = cleaners;
    setCleaners((prev) => prev.map((c) => (c.user_id !== cleanerId ? c : {
      ...c,
      documents: c.documents.map((d) => (d.id === docId ? { ...d, verified_at: new Date().toISOString() } : d)),
    })));
    try {
      await api.reviewDocument(docId, true);
    } catch (err) {
      setCleaners(snapshot);
      say(err.detail || "Could not verify that document.", "warn");
    }
  }, [cleaners, say]);

  const resolveDispute = useCallback(async (dispute, payload) => {
    const snapshot = disputes;
    const idx = snapshot.findIndex((d) => d.id === dispute.id);
    setDisputes((prev) => prev.filter((d) => d.id !== dispute.id));
    setCursor((c) => Math.max(0, Math.min(c, snapshot.length - 2)));
    try {
      await api.resolveDispute(dispute.id, payload);
      say(`${dispute.reference} closed. ${payload.refund_cents > 0 ? `${usd(payload.refund_cents)} refunded.` : "No refund issued."}`);
      refreshMetrics();
    } catch (err) {
      setDisputes(snapshot);
      setCursor(Math.max(0, idx));
      say(err.detail || err.message || "Could not close the dispute.", "warn");
      throw err;
    }
  }, [disputes, say, refreshMetrics]);

  return (
    <div className="flex h-screen w-full bg-[#FAFBFA] text-[#0B1F26]">
      <Rail
        tab={tab}
        onTab={switchTab}
        counts={{ vetting: cleaners.length, disputes: disputes.length }}
        user={session()}
        onSignOut={onSignOut}
      />

      <div className="flex min-w-0 flex-1 flex-col">
        <MetricStrip metrics={metrics} />

        <div className="flex min-h-0 flex-1">
          <QueueList items={queue} tab={tab} cursor={cursor} onSelect={setCursor} loading={loading} />
          <main className="min-w-0 flex-1 overflow-y-auto">
            {loading ? (
              <Centered><Loader2 size={22} className="animate-spin text-[#12A088]" /></Centered>
            ) : loadError ? (
              <LoadError message={loadError} onRetry={load} />
            ) : !current ? (
              <EmptyQueue tab={tab} />
            ) : tab === "vetting" ? (
              <VettingCase
                key={current.user_id}
                cleaner={current}
                onDecide={(action) => decideCleaner(current, action)}
                onVerifyDoc={(docId) => verifyDoc(current.user_id, docId)}
              />
            ) : (
              <DisputeCase
                key={current.id}
                dispute={current}
                onResolve={(payload) => resolveDispute(current, payload)}
              />
            )}
          </main>
        </div>

        <ShortcutBar onOpen={() => setShowKeys(true)} />
      </div>

      {showKeys && <KeyHelp onClose={() => setShowKeys(false)} />}
      {toast && (
        <div className={`fixed bottom-16 left-1/2 -translate-x-1/2 rounded-lg px-4 py-3 text-sm text-white shadow-lg
          ${toast.tone === "warn" ? "bg-[#C4553D]" : "bg-[#0E3A45]"}`}>
          {toast.text}
        </div>
      )}
    </div>
  );
}

// -------------------------------------------------------------------- auth --
function LoginScreen({ onSignedIn }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const submit = async (e) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await apiLogin(email.trim(), password);
      onSignedIn();
    } catch (err) {
      setError(err.detail || err.message || "Sign-in failed.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex h-screen w-full bg-[#0E3A45]">
      <div className="hidden w-1/2 flex-col justify-between p-10 text-white md:flex">
        <div>
          <div className="font-display text-lg font-extrabold tracking-tight">Sparkle</div>
          <div className="text-sm text-[#A9C6CD]">Trust &amp; Safety</div>
        </div>
        <div className="flex flex-col items-start gap-6">
          <img src="/images/sparkle_motif.svg" width={160} height={160} alt="" className="opacity-90" />
          <p className="font-display max-w-xs text-2xl font-semibold leading-snug">
            Trust &amp; Safety for every clean
          </p>
        </div>
        <div className="text-xs text-[#A9C6CD]">Admin console · audit-backed actions only</div>
      </div>
      <div className="flex flex-1 items-center justify-center px-6">
      <form onSubmit={submit} className="w-full max-w-sm rounded-2xl bg-white p-7 shadow-xl">
        <div className="flex items-center gap-2 text-[#0E3A45]">
          <ShieldCheck size={20} />
          <div>
            <div className="font-display text-sm font-semibold tracking-tight">Sparkle</div>
            <div className="text-xs text-[#6B8087]">Trust &amp; Safety</div>
          </div>
        </div>

        <h1 className="font-display mt-6 text-lg font-semibold">Sign in</h1>
        <p className="mt-1 text-sm text-[#6B8087]">Admin accounts only.</p>

        <label className="mt-5 block text-xs font-semibold uppercase tracking-wider text-[#6B8087]">Email</label>
        <input
          type="email" autoFocus required value={email} onChange={(e) => setEmail(e.target.value)}
          className="mt-1.5 w-full rounded border border-[#DCE7E4] p-2.5 text-sm outline-none focus:border-[#0E3A45]"
          placeholder="you@sparkle.app"
        />

        <label className="mt-4 block text-xs font-semibold uppercase tracking-wider text-[#6B8087]">Password</label>
        <input
          type="password" required value={password} onChange={(e) => setPassword(e.target.value)}
          className="mt-1.5 w-full rounded border border-[#DCE7E4] p-2.5 text-sm outline-none focus:border-[#0E3A45]"
          placeholder="••••••••••"
        />

        {error && (
          <div className="mt-4 rounded border border-[#F2C9BE] bg-[#FDF1ED] px-3 py-2 text-sm text-[#C4553D]">
            {error}
          </div>
        )}

        <button
          type="submit"
          disabled={busy || !email || !password}
          className="mt-5 flex w-full items-center justify-center gap-2 rounded bg-[#12A088] px-4 py-2.5 text-sm font-medium text-white disabled:bg-[#DCE7E4] disabled:text-[#6B8087]"
        >
          {busy && <Loader2 size={15} className="animate-spin" />} Sign in
        </button>
      </form>
      </div>
    </div>
  );
}

function Rail({ tab, onTab, counts, user, onSignOut }) {
  const item = (id, label, Icon, count) => {
    const active = tab === id;
    return (
      <button
        onClick={() => onTab(id)}
        className={`flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-left text-sm transition
          ${active ? "bg-white/10 text-white" : "text-[#A9C6CD] hover:bg-white/5"}`}
      >
        <Icon size={17} />
        <span className="flex-1">{label}</span>
        {count > 0 && (
          <span className={`rounded px-1.5 py-0.5 text-xs tabular-nums
            ${active ? "bg-white text-[#0E3A45]" : "bg-white/10 text-[#A9C6CD]"}`}>
            {count}
          </span>
        )}
      </button>
    );
  };

  return (
    <aside className="flex w-56 shrink-0 flex-col bg-[#0E3A45] p-3">
      <div className="px-3 py-4">
        <div className="font-display text-sm font-semibold tracking-tight text-white">Sparkle</div>
        <div className="text-xs text-[#A9C6CD]">Trust &amp; Safety</div>
      </div>
      <nav className="mt-2 space-y-1">
        {item("vetting", "Vetting", ShieldCheck, counts.vetting)}
        {item("disputes", "Disputes", AlertTriangle, counts.disputes)}
      </nav>
      <div className="mt-auto space-y-2">
        <div className="rounded-lg bg-white/5 p-3 text-xs leading-relaxed text-[#A9C6CD]">
          Every action here writes an audit row. The app role has no UPDATE on that table.
        </div>
        <div className="flex items-center justify-between gap-2 rounded-lg px-3 py-2 text-xs text-[#A9C6CD]">
          <span className="min-w-0 truncate">{user?.email ?? user?.full_name ?? "Signed in"}</span>
          <button
            onClick={onSignOut}
            title="Sign out"
            className="flex shrink-0 items-center gap-1 rounded px-1.5 py-1 hover:bg-white/10 hover:text-white"
          >
            <LogOut size={13} /> Sign out
          </button>
        </div>
      </div>
    </aside>
  );
}

function MetricStrip({ metrics }) {
  if (!metrics) {
    return <div className="h-[57px] shrink-0 border-b border-[#DCE7E4] bg-white" />;
  }
  const cells = [
    ["Revenue, 7d", usd(metrics.revenue_cents), false],
    ["GMV, 7d", usd(metrics.gross_cents), false],
    ["Match rate", metrics.match_rate == null ? "—" : `${Math.round(metrics.match_rate * 100)}%`,
      metrics.match_rate != null && metrics.match_rate < 0.9],
    ["Median match", metrics.avg_match_seconds == null ? "—" : `${metrics.avg_match_seconds}s`,
      metrics.avg_match_seconds > 300],
    ["Cleaners online", metrics.cleaners_online, metrics.cleaners_online < 20],
    ["Below 4.3", metrics.cleaners_below_floor, metrics.cleaners_below_floor > 0],
    ["SLA breaches", metrics.disputes_breaching_sla, metrics.disputes_breaching_sla > 0],
  ];
  return (
    <div className="flex shrink-0 items-stretch gap-px border-b border-[#DCE7E4] bg-[#DCE7E4]">
      {cells.map(([label, value, alarm]) => (
        <div key={label} className="flex-1 bg-white px-4 py-3">
          <div className="text-[10px] font-semibold uppercase tracking-wider text-[#6B8087]">{label}</div>
          <div className={`mt-1 text-lg font-semibold tabular-nums ${alarm ? "text-[#C4553D]" : "text-[#0B1F26]"}`}>
            {value}
          </div>
        </div>
      ))}
    </div>
  );
}

function QueueList({ items, tab, cursor, onSelect, loading }) {
  return (
    <div className="w-80 shrink-0 overflow-y-auto border-r border-[#DCE7E4] bg-white">
      {items.map((item, i) => {
        const active = i === cursor;
        const isVetting = tab === "vetting";
        const waited = ago(isVetting ? item.applied_at : item.created_at);
        const stale = (Date.now() - new Date(isVetting ? item.applied_at : item.created_at)) > 48 * 3.6e6;
        return (
          <button
            key={item.user_id ?? item.id}
            onClick={() => onSelect(i)}
            className={`flex w-full items-start gap-3 border-b border-[#EDF2F1] px-4 py-3 text-left transition
              ${active ? "bg-[#E2F2EE]" : "hover:bg-[#F5F8F7]"}`}
          >
            <div className={`mt-1 h-2 w-2 shrink-0 rounded-full ${stale ? "bg-[#C4553D]" : "bg-[#DCE7E4]"}`} />
            <div className="min-w-0 flex-1">
              <div className="truncate text-sm font-medium">
                {isVetting ? item.full_name : item.reference}
              </div>
              <div className="mt-0.5 truncate text-xs text-[#6B8087]">
                {isVetting
                  ? `${item.bg_status === "clear" ? "Check clear" : `Check ${item.bg_status}`} · waiting ${waited}`
                  : `${item.category} · ${item.customer_name} · ${waited}`}
              </div>
            </div>
            {active && <ChevronRight size={15} className="mt-1 shrink-0 text-[#12A088]" />}
          </button>
        );
      })}
      {!loading && items.length === 0 && (
        <div className="p-6 text-sm text-[#6B8087]">Queue clear.</div>
      )}
    </div>
  );
}

// ----------------------------------------------------------------- vetting --
function VettingCase({ cleaner, onDecide, onVerifyDoc }) {
  const [note, setNote] = useState("");
  const [days, setDays] = useState(30);
  const [mode, setMode] = useState(null); // 'reject' | 'suspend'
  const [busy, setBusy] = useState(false);

  const unverified = cleaner.documents.filter((d) => !d.verified_at);

  // The same three gates the API enforces, shown as reasons rather than a
  // disabled button with no explanation.
  const blockers = useMemo(() => {
    const out = [];
    if (cleaner.bg_status !== "clear") out.push(`Background check is ${cleaner.bg_status}`);
    if (unverified.length) out.push(`${unverified.length} document${unverified.length > 1 ? "s" : ""} unreviewed`);
    if (!cleaner.payouts_enabled) out.push("Payout details incomplete — could not be paid");
    return out;
  }, [cleaner, unverified.length]);

  const act = useCallback(async (verb, extra = {}) => {
    setBusy(true);
    try {
      await onDecide({ verb, ...extra });
      // On success the parent removes this card and it unmounts; nothing else to do.
    } catch {
      // The parent already restored the card and surfaced the reason.
      setBusy(false);
    }
  }, [onDecide]);

  useEffect(() => {
    const onKey = (e) => {
      if (e.target.tagName === "TEXTAREA" || e.target.tagName === "INPUT") return;
      if (e.key === "a" && !blockers.length && !busy) act("approve");
      if (e.key === "r") setMode("reject");
      if (e.key === "s") setMode("suspend");
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [blockers.length, busy, act]);

  return (
    <div className="mx-auto max-w-3xl px-8 py-7">
      <div className="flex items-start justify-between gap-6">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">{cleaner.full_name}</h1>
          <p className="mt-1 text-sm text-[#6B8087]">
            {cleaner.email} · applied {ago(cleaner.applied_at)} · {cleaner.years_experience ?? 0} years experience
          </p>
        </div>
        <BgBadge status={cleaner.bg_status} completedAt={cleaner.bg_completed_at} />
      </div>

      <p className="mt-4 text-sm leading-relaxed text-[#33484F]">{cleaner.bio}</p>

      <div className="mt-4 flex flex-wrap gap-2">
        {(cleaner.service_types ?? []).map((t) => (
          <span key={t} className="rounded border border-[#DCE7E4] px-2 py-1 text-xs capitalize text-[#33484F]">
            {t === "deep" ? "Deep clean" : "Standard"}
          </span>
        ))}
        <span className="rounded border border-[#DCE7E4] px-2 py-1 text-xs text-[#33484F]">
          {cleaner.service_radius_km} km radius
        </span>
        <span className={`rounded px-2 py-1 text-xs ${cleaner.payouts_enabled
          ? "border border-[#DCE7E4] text-[#33484F]" : "bg-[#FBE9E4] text-[#C4553D]"}`}>
          {cleaner.payouts_enabled ? "Payouts ready" : "Payouts incomplete"}
        </span>
      </div>

      <Section title="Documents">
        <div className="divide-y divide-[#EDF2F1] rounded-lg border border-[#DCE7E4] bg-white">
          {cleaner.documents.map((doc) => (
            <div key={doc.id} className="flex items-center gap-3 px-4 py-3">
              <FileText size={16} className="text-[#6B8087]" />
              <div className="flex-1">
                <div className="text-sm capitalize">{doc.doc_type.replace(/_/g, " ")}</div>
                <div className="text-xs text-[#6B8087]">
                  {doc.expires_at ? `Expires ${doc.expires_at}` : "No expiry"}
                </div>
              </div>
              {doc.verified_at ? (
                <span className="flex items-center gap-1 text-xs font-medium text-[#12A088]">
                  <Check size={14} /> Verified
                </span>
              ) : (
                <button
                  onClick={() => onVerifyDoc(doc.id)}
                  className="rounded border border-[#0E3A45] px-3 py-1.5 text-xs font-medium text-[#0E3A45] hover:bg-[#0E3A45] hover:text-white"
                >
                  Open and verify
                </button>
              )}
            </div>
          ))}
          {cleaner.documents.length === 0 && (
            <div className="px-4 py-3 text-sm text-[#6B8087]">No documents submitted yet.</div>
          )}
        </div>
      </Section>

      {blockers.length > 0 && (
        <div className="mt-6 rounded-lg border border-[#F0D9A8] bg-[#FDF6E7] p-4">
          <div className="text-xs font-semibold uppercase tracking-wider text-[#8A6A20]">
            Approval blocked
          </div>
          <ul className="mt-2 space-y-1">
            {blockers.map((b) => (
              <li key={b} className="flex items-start gap-2 text-sm text-[#5C4A18]">
                <CircleDot size={14} className="mt-0.5 shrink-0" /> {b}
              </li>
            ))}
          </ul>
        </div>
      )}

      {mode && (
        <div className="mt-6 rounded-lg border border-[#DCE7E4] bg-white p-4">
          <label className="text-sm font-medium">
            {mode === "reject" ? "Why is this application rejected?" : "Why is this cleaner suspended?"}
          </label>
          <p className="mt-1 text-xs text-[#6B8087]">
            Goes on the permanent record and into the applicant's notification. Write it for them to read.
          </p>
          <textarea
            autoFocus
            value={note}
            onChange={(e) => setNote(e.target.value)}
            rows={3}
            className="mt-2 w-full rounded border border-[#DCE7E4] p-2.5 text-sm outline-none focus:border-[#0E3A45]"
            placeholder="Insurance certificate expired before the first available shift."
          />
          {mode === "suspend" && (
            <div className="mt-3 flex items-center gap-2">
              <span className="text-xs font-medium text-[#6B8087]">For</span>
              {[7, 30, 90].map((d) => (
                <button
                  key={d}
                  onClick={() => setDays(d)}
                  className={`rounded border px-2.5 py-1 text-xs tabular-nums transition
                    ${days === d ? "border-[#0E3A45] bg-[#0E3A45] text-white" : "border-[#DCE7E4] hover:bg-[#EDF2F1]"}`}
                >
                  {d} days
                </button>
              ))}
            </div>
          )}
          <div className="mt-3 flex gap-2">
            <button
              disabled={note.trim().length < 3 || busy}
              onClick={() => act(mode === "reject" ? "reject" : "suspend", { reason: note.trim(), days })}
              className="flex items-center gap-2 rounded bg-[#C4553D] px-4 py-2 text-sm font-medium text-white disabled:bg-[#DCE7E4] disabled:text-[#6B8087]"
            >
              {busy && <Loader2 size={14} className="animate-spin" />}
              Confirm {mode}
            </button>
            <button onClick={() => { setMode(null); setNote(""); }}
                    className="rounded px-4 py-2 text-sm text-[#33484F] hover:bg-[#EDF2F1]">
              Cancel
            </button>
          </div>
        </div>
      )}

      <DecisionBar>
        <button
          disabled={blockers.length > 0 || busy}
          onClick={() => act("approve")}
          className="flex items-center gap-2 rounded bg-[#12A088] px-5 py-2.5 text-sm font-medium text-white disabled:bg-[#DCE7E4] disabled:text-[#6B8087]"
        >
          {busy ? <Loader2 size={15} className="animate-spin" /> : <Check size={15} />}
          Approve <Kbd>A</Kbd>
        </button>
        <button onClick={() => setMode("reject")}
                className="flex items-center gap-2 rounded border border-[#DCE7E4] px-5 py-2.5 text-sm font-medium hover:bg-[#EDF2F1]">
          <X size={15} /> Reject <Kbd>R</Kbd>
        </button>
        <button onClick={() => setMode("suspend")}
                className="flex items-center gap-2 rounded border border-[#DCE7E4] px-5 py-2.5 text-sm font-medium hover:bg-[#EDF2F1]">
          <Ban size={15} /> Suspend <Kbd>S</Kbd>
        </button>
      </DecisionBar>
    </div>
  );
}

function BgBadge({ status, completedAt }) {
  const map = {
    clear: ["bg-[#E2F2EE] text-[#0C6E5D]", "Background check clear"],
    consider: ["bg-[#FDF6E7] text-[#8A6A20]", "Background check needs review"],
    pending: ["bg-[#EDF2F1] text-[#6B8087]", "Background check pending"],
    suspended: ["bg-[#FBE9E4] text-[#C4553D]", "Background check suspended"],
  };
  const [cls, label] = map[status] ?? map.pending;
  return (
    <div className={`shrink-0 rounded-lg px-3 py-2 text-right ${cls}`}>
      <div className="text-xs font-semibold">{label}</div>
      <div className="mt-0.5 text-[11px] opacity-80">
        {completedAt ? `Returned ${ago(completedAt)}` : "Awaiting Checkr"}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- disputes --
function DisputeCase({ dispute, onResolve }) {
  const [refund, setRefund] = useState(0);
  const [penalty, setPenalty] = useState("none");
  const [resolution, setResolution] = useState("");
  const [busy, setBusy] = useState(false);

  // The list endpoint carries the money and the counts; the status timeline and
  // durations live in the booking dossier, fetched lazily when a case opens.
  const [detail, setDetail] = useState(null);
  const [detailLoading, setDetailLoading] = useState(true);

  useEffect(() => {
    let live = true;
    setDetail(null);
    setDetailLoading(true);
    api.bookingDossier(dispute.booking_id)
      .then((dossier) => {
        if (!live) return;
        const b = dossier.booking ?? {};
        const timeline = (dossier.timeline ?? []).map((t) => ({
          to_status: t.to_status,
          created_at: t.created_at,
          geofence: t.lat != null && t.lng != null ? "location recorded" : undefined,
        }));
        const actual = b.started_at && b.completed_at
          ? Math.round((new Date(b.completed_at) - new Date(b.started_at)) / 60000)
          : null;
        setDetail({ timeline, scheduled_duration_min: b.duration_min ?? null, actual_duration_min: actual });
      })
      .catch(() => { if (live) setDetail({ timeline: [], scheduled_duration_min: null, actual_duration_min: null }); })
      .finally(() => { if (live) setDetailLoading(false); });
    return () => { live = false; };
  }, [dispute.booking_id]);

  const refundable = (dispute.captured_cents ?? 0) - (dispute.refunded_cents ?? 0);
  const presets = [
    ["No refund", 0],
    ["25%", Math.round(refundable * 0.25)],
    ["50%", Math.round(refundable * 0.5)],
    ["Full", refundable],
  ];

  const timeline = detail?.timeline ?? [];
  const scheduled = detail?.scheduled_duration_min ?? null;
  const actual = detail?.actual_duration_min ?? null;
  const ranShort = actual != null && scheduled != null && actual < scheduled * 0.6;

  const submit = async () => {
    setBusy(true);
    try {
      await onResolve({ resolution: resolution.trim(), refund_cents: refund, penalty });
    } catch {
      setBusy(false); // parent restored the case and surfaced the reason
    }
  };

  return (
    <div className="mx-auto max-w-3xl px-8 py-7">
      <div className="flex items-start justify-between gap-6">
        <div>
          <h1 className="font-mono text-xl font-semibold tracking-tight">{dispute.reference}</h1>
          <p className="mt-1 text-sm capitalize text-[#6B8087]">
            {dispute.category.replace(/_/g, " ")} · opened {ago(dispute.created_at)} ·
            {" "}{dispute.customer_name} vs {dispute.cleaner_name ?? "unassigned"}
          </p>
        </div>
        <div className="shrink-0 text-right">
          <div className="text-[10px] font-semibold uppercase tracking-wider text-[#6B8087]">Charged</div>
          <div className="text-lg font-semibold tabular-nums">{usd(dispute.captured_cents)}</div>
          <div className="text-xs text-[#6B8087]">cleaner paid {usd(dispute.payout_cents)}</div>
        </div>
      </div>

      <blockquote className="mt-5 border-l-2 border-[#0E3A45] bg-white px-4 py-3 text-sm leading-relaxed text-[#33484F]">
        {dispute.description}
      </blockquote>

      <Section title="Evidence">
        <div className="grid grid-cols-2 gap-3">
          <Evidence icon={MapPin} label="Geofence" ok={timeline.some((t) => t.geofence)}
            detail={timeline.find((t) => t.geofence) ? "Arrival recorded at the property" : "No arrival recorded at the property"} />
          <Evidence icon={Camera} label="Job photos" ok={dispute.photo_count > 0}
            detail={dispute.photo_count > 0 ? `${dispute.photo_count} before/after photos` : "None uploaded"} />
          <Evidence icon={Clock} label="Time on site" ok={!ranShort}
            detail={actual == null
              ? (detailLoading ? "Loading…" : "Job never started")
              : `${actual} min of ${scheduled ?? "?"} booked`} />
          <Evidence icon={Star} label="Customer rating" ok={(dispute.customer_rating ?? 5) >= 3}
            detail={dispute.customer_rating ? `${dispute.customer_rating} of 5` : "Not rated"} />
        </div>

        <div className="mt-3 rounded-lg border border-[#DCE7E4] bg-white">
          {timeline.map((t, i) => (
            <div key={i} className="flex items-center gap-3 border-b border-[#EDF2F1] px-4 py-2.5 last:border-0">
              <div className="h-2 w-2 rounded-full bg-[#12A088]" />
              <div className="flex-1 text-sm capitalize">{t.to_status.replace(/_/g, " ")}</div>
              {t.geofence && <span className="text-xs text-[#6B8087]">{t.geofence}</span>}
              <span className="font-mono text-xs tabular-nums text-[#6B8087]">
                {new Date(t.created_at).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" })}
              </span>
            </div>
          ))}
          {timeline.length === 0 && (
            <div className="px-4 py-3 text-sm text-[#6B8087]">
              {detailLoading ? "Loading timeline…" : "No status events recorded."}
            </div>
          )}
        </div>
      </Section>

      <Section title="Refund">
        <div className="flex flex-wrap gap-2">
          {presets.map(([label, cents]) => (
            <button
              key={label}
              onClick={() => setRefund(cents)}
              className={`rounded border px-3 py-2 text-sm tabular-nums transition
                ${refund === cents
                  ? "border-[#0E3A45] bg-[#0E3A45] text-white"
                  : "border-[#DCE7E4] bg-white hover:bg-[#EDF2F1]"}`}
            >
              {label} · {usd(cents)}
            </button>
          ))}
        </div>
        <p className="mt-2 text-xs text-[#6B8087]">
          Refunds reverse the cleaner's transfer proportionally. Refundable balance {usd(refundable)}.
        </p>
      </Section>

      <Section title="Cleaner outcome">
        <div className="flex flex-wrap gap-2">
          {[
            ["none", "No fault"],
            ["hide_review", "Hide the review"],
            ["coaching", "Coaching"],
            ["suspend", "Suspend"],
          ].map(([value, label]) => (
            <button
              key={value}
              onClick={() => setPenalty(value)}
              className={`rounded border px-3 py-2 text-sm transition
                ${penalty === value
                  ? "border-[#0E3A45] bg-[#0E3A45] text-white"
                  : "border-[#DCE7E4] bg-white hover:bg-[#EDF2F1]"}`}
            >
              {label}
            </button>
          ))}
        </div>
        <p className="mt-2 text-xs text-[#6B8087]">
          Deliberately separate from the refund. A broken lockbox makes the customer whole and the
          cleaner blameless — coupling the two teaches agents to under-refund to protect good cleaners.
        </p>
      </Section>

      <Section title="Resolution note">
        <textarea
          value={resolution}
          onChange={(e) => setResolution(e.target.value)}
          rows={3}
          className="w-full rounded border border-[#DCE7E4] bg-white p-2.5 text-sm outline-none focus:border-[#0E3A45]"
          placeholder="Photos show the bathrooms were cleaned; time on site was short but within range. Partial refund as a goodwill gesture, no fault recorded."
        />
      </Section>

      <DecisionBar>
        <button
          disabled={resolution.trim().length < 3 || busy}
          onClick={submit}
          className="flex items-center gap-2 rounded bg-[#12A088] px-5 py-2.5 text-sm font-medium text-white disabled:bg-[#DCE7E4] disabled:text-[#6B8087]"
        >
          {busy ? <Loader2 size={15} className="animate-spin" /> : <Check size={15} />}
          Resolve and close
        </button>
        <span className="self-center text-xs text-[#6B8087]">
          {refund > 0 ? `${usd(refund)} back to ${dispute.customer_name}` : "No money moves"}
          {penalty !== "none" && ` · ${penalty.replace(/_/g, " ")}`}
        </span>
      </DecisionBar>
    </div>
  );
}

function Evidence({ icon: Icon, label, ok, detail }) {
  return (
    <div className={`rounded-lg border p-3 ${ok ? "border-[#DCE7E4] bg-white" : "border-[#F2C9BE] bg-[#FDF1ED]"}`}>
      <div className="flex items-center gap-2">
        <Icon size={15} className={ok ? "text-[#12A088]" : "text-[#C4553D]"} />
        <span className="text-xs font-semibold uppercase tracking-wider text-[#6B8087]">{label}</span>
      </div>
      <div className="mt-1.5 text-sm text-[#33484F]">{detail}</div>
    </div>
  );
}

// ------------------------------------------------------------------ pieces --
const Section = ({ title, children }) => (
  <section className="mt-7">
    <h2 className="mb-2.5 text-xs font-semibold uppercase tracking-wider text-[#6B8087]">{title}</h2>
    {children}
  </section>
);

const DecisionBar = ({ children }) => (
  <div className="sticky bottom-0 mt-8 flex flex-wrap gap-2 border-t border-[#DCE7E4] bg-[#FAFBFA] py-4">
    {children}
  </div>
);

const Kbd = ({ children }) => (
  <kbd className="rounded bg-black/15 px-1.5 py-0.5 font-mono text-[10px] leading-none">{children}</kbd>
);

const Centered = ({ children }) => (
  <div className="flex h-full items-center justify-center">{children}</div>
);

function LoadError({ message, onRetry }) {
  return (
    <div className="flex h-full flex-col items-center justify-center px-8 text-center">
      <AlertTriangle size={32} className="text-[#C4553D]" />
      <h2 className="mt-4 text-lg font-semibold">Couldn’t load the queue</h2>
      <p className="mt-1 max-w-sm text-sm text-[#6B8087]">{message}</p>
      <button
        onClick={onRetry}
        className="mt-4 rounded bg-[#0E3A45] px-4 py-2 text-sm font-medium text-white hover:bg-[#0B1F26]"
      >
        Try again
      </button>
    </div>
  );
}

function ShortcutBar({ onOpen }) {
  return (
    <button onClick={onOpen}
      className="flex shrink-0 items-center gap-2 border-t border-[#DCE7E4] bg-white px-4 py-2 text-xs text-[#6B8087] hover:bg-[#F5F8F7]">
      <Keyboard size={13} />
      <span><span className="font-mono">J</span>/<span className="font-mono">K</span> move ·
        {" "}<span className="font-mono">A</span> approve ·
        {" "}<span className="font-mono">R</span> reject ·
        {" "}<span className="font-mono">1</span>/<span className="font-mono">2</span> switch queue ·
        {" "}<span className="font-mono">?</span> all shortcuts</span>
    </button>
  );
}

function KeyHelp({ onClose }) {
  const rows = [
    ["J / ↓", "Next case"], ["K / ↑", "Previous case"],
    ["A", "Approve (blocked if gates are unmet)"], ["R", "Reject — needs a reason"],
    ["S", "Suspend — needs a reason"], ["1 / 2", "Vetting / Disputes"], ["Esc", "Close"],
  ];
  return (
    <div className="fixed inset-0 flex items-center justify-center bg-black/40 p-6" onClick={onClose}>
      <div className="w-80 rounded-xl bg-white p-5 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-sm font-semibold">Keyboard</h3>
        <div className="mt-3 space-y-2">
          {rows.map(([key, what]) => (
            <div key={key} className="flex items-center justify-between text-sm">
              <span className="font-mono text-xs text-[#0E3A45]">{key}</span>
              <span className="text-[#33484F]">{what}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function EmptyQueue({ tab }) {
  return (
    <div className="flex h-full flex-col items-center justify-center px-8 text-center">
      <img src="/images/illustration_empty_calm.svg" width={96} height={96} alt="" className="mb-1" />
      <h2 className="font-display mt-4 text-lg font-semibold">
        {tab === "vetting" ? "No applications waiting" : "No open disputes"}
      </h2>
      <p className="mt-1 max-w-sm text-sm text-[#6B8087]">
        {tab === "vetting"
          ? "New applicants land here the moment their background check returns."
          : "Disputes appear here when a customer opens one, or when PayPal reports a chargeback."}
      </p>
    </div>
  );
}
