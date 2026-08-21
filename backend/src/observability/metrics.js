// Tiny zero-dependency metrics in Prometheus text exposition format.
//
// Deliberately not prom-client: this repo's test story is that the paths that
// matter are checkable without infra, and a small registry we can unit-test
// beats a dependency nobody exercises before pushing. The call sites — `.inc()`,
// `.observe()`, `.set()` — are the stable surface; swap the implementation for
// prom-client if you outgrow it and the instrumentation won't change.
//
// Metrics are per-process. The API records what happens on a request
// (matches, capture failures, live webhooks); the worker records what happens
// off it (dispatch rounds, webhook replay, the stuck-booking sweep). Both
// expose /metrics, and Prometheus scrapes them as two targets.

const escapeLabelValue = (v) =>
  String(v).replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/"/g, '\\"');

function labelKey(labels) {
  const keys = Object.keys(labels).sort();
  if (keys.length === 0) return '';
  return keys.map((k) => `${k}="${escapeLabelValue(labels[k])}"`).join(',');
}

const braces = (key) => (key ? `{${key}}` : '');
const withLe = (key, le) => (key ? `${key},le="${le}"` : `le="${le}"`);

/** Split (labels?, value?) — both `.set(5)` and `.set({a:1}, 5)` are valid. */
function argsToLabelsValue(a, b, fallback) {
  if (typeof a === 'number') return [{}, a];
  return [a ?? {}, b ?? fallback];
}

class Counter {
  constructor(name, help) {
    this.name = name; this.help = help; this.type = 'counter';
    this.values = new Map();
  }

  inc(labels = {}, amount = 1) {
    // Allow `.inc()` and `.inc(2)` as well as `.inc({label}, 2)`.
    if (typeof labels === 'number') { amount = labels; labels = {}; }
    const key = labelKey(labels);
    this.values.set(key, (this.values.get(key) ?? 0) + amount);
  }

  * samples() {
    if (this.values.size === 0) { yield { labels: '', value: 0 }; return; }
    for (const [labels, value] of this.values) yield { labels, value };
  }
}

class Gauge {
  constructor(name, help) {
    this.name = name; this.help = help; this.type = 'gauge';
    this.values = new Map();
  }

  set(a, b) {
    const [labels, value] = argsToLabelsValue(a, b, 0);
    this.values.set(labelKey(labels), value);
  }

  * samples() {
    if (this.values.size === 0) { yield { labels: '', value: 0 }; return; }
    for (const [labels, value] of this.values) yield { labels, value };
  }
}

class Histogram {
  constructor(name, help, buckets) {
    this.name = name; this.help = help; this.type = 'histogram';
    this.buckets = [...buckets].sort((x, y) => x - y);
    this.series = new Map();
  }

  observe(a, b) {
    const [labels, value] = argsToLabelsValue(a, b, 0);
    const key = labelKey(labels);
    let s = this.series.get(key);
    if (!s) { s = { counts: new Array(this.buckets.length).fill(0), sum: 0, count: 0 }; this.series.set(key, s); }
    s.count += 1;
    s.sum += value;
    // counts[i] is the number of observations <= buckets[i]; since buckets are
    // ascending this is already the cumulative value Prometheus expects.
    for (let i = 0; i < this.buckets.length; i++) if (value <= this.buckets[i]) s.counts[i] += 1;
  }
}

export class Registry {
  constructor() { this.metrics = []; }

  counter(name, help) { const m = new Counter(name, help); this.metrics.push(m); return m; }
  gauge(name, help) { const m = new Gauge(name, help); this.metrics.push(m); return m; }
  histogram(name, help, buckets) { const m = new Histogram(name, help, buckets); this.metrics.push(m); return m; }

  render() {
    const lines = [];
    for (const m of this.metrics) {
      lines.push(`# HELP ${m.name} ${m.help}`);
      lines.push(`# TYPE ${m.name} ${m.type}`);
      if (m.type === 'histogram') {
        const series = m.series.size
          ? [...m.series.entries()]
          : [['', { counts: new Array(m.buckets.length).fill(0), sum: 0, count: 0 }]];
        for (const [key, s] of series) {
          for (let i = 0; i < m.buckets.length; i++) {
            lines.push(`${m.name}_bucket{${withLe(key, m.buckets[i])}} ${s.counts[i]}`);
          }
          lines.push(`${m.name}_bucket{${withLe(key, '+Inf')}} ${s.count}`);
          lines.push(`${m.name}_sum${braces(key)} ${s.sum}`);
          lines.push(`${m.name}_count${braces(key)} ${s.count}`);
        }
      } else {
        for (const { labels, value } of m.samples()) {
          lines.push(`${m.name}${braces(labels)} ${value}`);
        }
      }
    }
    return `${lines.join('\n')}\n`;
  }
}

export const CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8';

// The one registry per process. Everything instrumented registers here.
export const registry = new Registry();

export const metrics = {
  bookingsCreated: registry.counter(
    'sparkle_bookings_created_total', 'Bookings confirmed and entering matching'),
  bookingsMatched: registry.counter(
    'sparkle_bookings_matched_total', 'Bookings assigned via an accepted offer'),
  dispatchRounds: registry.counter(
    'sparkle_dispatch_rounds_total', 'Matching dispatch rounds executed, by outcome'),
  offersBroadcast: registry.counter(
    'sparkle_offers_broadcast_total', 'Offers pushed to cleaners'),
  timeToMatch: registry.histogram(
    'sparkle_time_to_match_seconds', 'Seconds from booking creation to match',
    [15, 30, 60, 120, 300, 600]),
  captureFailures: registry.counter(
    'sparkle_payment_capture_failures_total', 'Stripe capture/transfer failures at completion'),
  webhookProcessed: registry.counter(
    'sparkle_webhook_processed_total', 'Webhook events processed, by provider and outcome'),
  webhookLag: registry.histogram(
    'sparkle_webhook_lag_seconds', 'Seconds from webhook receipt to successful processing',
    [1, 5, 15, 60, 300, 1800]),
  stuckPendingMatch: registry.gauge(
    'sparkle_bookings_stuck_pending_match', 'Bookings still pending_match past two dispatch rounds'),
};
