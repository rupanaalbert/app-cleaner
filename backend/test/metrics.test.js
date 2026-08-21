import test from 'node:test';
import assert from 'node:assert/strict';

import { Registry } from '../src/observability/metrics.js';

const lines = (text) => text.trim().split('\n');
const has = (text, line) => lines(text).includes(line);

test('a counter renders zero before use and sums increments', () => {
  const r = new Registry();
  const c = r.counter('sparkle_thing_total', 'A thing');
  assert.ok(has(r.render(), 'sparkle_thing_total 0'), 'unused counter exposes 0');
  c.inc();
  c.inc(4);
  assert.ok(has(r.render(), 'sparkle_thing_total 5'));
  assert.ok(has(r.render(), '# TYPE sparkle_thing_total counter'));
  assert.ok(has(r.render(), '# HELP sparkle_thing_total A thing'));
});

test('counter labels render as sorted, quoted label sets', () => {
  const r = new Registry();
  const c = r.counter('sparkle_webhook_processed_total', 'Webhooks');
  c.inc({ provider: 'stripe', outcome: 'ok' });
  c.inc({ outcome: 'ok', provider: 'stripe' }); // same series, order-independent
  c.inc({ provider: 'stripe', outcome: 'failed' });
  const out = r.render();
  assert.ok(has(out, 'sparkle_webhook_processed_total{outcome="ok",provider="stripe"} 2'));
  assert.ok(has(out, 'sparkle_webhook_processed_total{outcome="failed",provider="stripe"} 1'));
});

test('a gauge holds the last value set', () => {
  const r = new Registry();
  const g = r.gauge('sparkle_stuck', 'Stuck');
  g.set(3);
  g.set(1);
  assert.ok(has(r.render(), 'sparkle_stuck 1'));
});

test('a histogram exposes cumulative buckets, +Inf, sum and count', () => {
  const r = new Registry();
  const h = r.histogram('sparkle_lag_seconds', 'Lag', [1, 5, 10]);
  for (const v of [0.5, 2, 2, 20]) h.observe(v);
  const out = r.render();
  // 0.5 <= 1                    → le="1" is 1
  assert.ok(has(out, 'sparkle_lag_seconds_bucket{le="1"} 1'));
  // 0.5, 2, 2 <= 5              → le="5" is 3
  assert.ok(has(out, 'sparkle_lag_seconds_bucket{le="5"} 3'));
  // still 3 <= 10 (20 excluded) → le="10" is 3
  assert.ok(has(out, 'sparkle_lag_seconds_bucket{le="10"} 3'));
  // +Inf catches everything     → 4
  assert.ok(has(out, 'sparkle_lag_seconds_bucket{le="+Inf"} 4'));
  assert.ok(has(out, 'sparkle_lag_seconds_sum 24.5'));
  assert.ok(has(out, 'sparkle_lag_seconds_count 4'));
  assert.ok(has(out, '# TYPE sparkle_lag_seconds histogram'));
});

test('histogram buckets stay cumulative under labels', () => {
  const r = new Registry();
  const h = r.histogram('sparkle_ttm_seconds', 'TTM', [30, 60]);
  h.observe({ region: 'ma' }, 10);
  h.observe({ region: 'ma' }, 45);
  const out = r.render();
  assert.ok(has(out, 'sparkle_ttm_seconds_bucket{region="ma",le="30"} 1'));
  assert.ok(has(out, 'sparkle_ttm_seconds_bucket{region="ma",le="60"} 2'));
  assert.ok(has(out, 'sparkle_ttm_seconds_bucket{region="ma",le="+Inf"} 2'));
  assert.ok(has(out, 'sparkle_ttm_seconds_count{region="ma"} 2'));
});

test('label values are escaped so they can\'t break the exposition format', () => {
  const r = new Registry();
  const c = r.counter('sparkle_x_total', 'X');
  c.inc({ note: 'a"b\\c' });
  assert.ok(has(r.render(), 'sparkle_x_total{note="a\\"b\\\\c"} 1'));
});
