import test from 'node:test';
import assert from 'node:assert/strict';

import { scoreCandidate } from '../src/domain/matching.score.js';

const WEIGHTS = {
  proximity: 0.35, quality: 0.30, reliability: 0.15, acceptance: 0.10, fairness: 0.10,
};
const score = (c, ctx) => scoreCandidate(c, { weights: WEIGHTS, ...ctx });

const candidate = (overrides = {}) => ({
  distance_km: 5,
  effective_radius_km: 20,
  quality_rating: 4.6,
  completion_rate: 1,
  acceptance_rate: 1,
  late_cancels: 0,
  earned_7d: 10_000,
  ...overrides,
});

test('score stays inside [0,1]', () => {
  const best = score(
    candidate({ distance_km: 0, quality_rating: 5, earned_7d: 0 }), { medianEarned7d: 10_000 });
  const worst = score(
    candidate({ distance_km: 20, quality_rating: 3, completion_rate: 0, acceptance_rate: 0, earned_7d: 50_000 }),
    { medianEarned7d: 10_000 });

  assert.ok(best <= 1 && best > 0.9, `expected near 1, got ${best}`);
  assert.equal(worst, 0);
});

test('closer beats further, all else equal', () => {
  const near = score(candidate({ distance_km: 2 }), { medianEarned7d: 10_000 });
  const far = score(candidate({ distance_km: 15 }), { medianEarned7d: 10_000 });
  assert.ok(near > far);
});

test('late cancellations cost more than a small distance penalty', () => {
  const reliable = score(candidate({ distance_km: 8 }), { medianEarned7d: 10_000 });
  const flaky = score(
    candidate({ distance_km: 5, late_cancels: 4 }), { medianEarned7d: 10_000 });
  assert.ok(reliable > flaky, 'a cleaner who cancels should not win on proximity alone');
});

test('fairness lifts a cleaner earning below the median', () => {
  const quiet = score(candidate({ earned_7d: 0 }), { medianEarned7d: 20_000 });
  const busy = score(candidate({ earned_7d: 40_000 }), { medianEarned7d: 20_000 });
  assert.ok(quiet > busy, 'supply concentration kills a marketplace');
  assert.ok(quiet - busy <= 0.1 + 1e-9, 'but fairness is weighted at 0.10, not more');
});

test('quality is scaled from 3.0, so mediocre ratings score near zero', () => {
  assert.equal(
    score(candidate({ quality_rating: 3 }), { medianEarned7d: 10_000 }),
    score(candidate({ quality_rating: 2 }), { medianEarned7d: 10_000 }),
    'below 3.0 is already the floor — those cleaners are filtered out upstream',
  );
});

test('with no earnings history fairness is neutral, not maximal', () => {
  const coldStart = score(candidate(), { medianEarned7d: 0 });
  const withMedian = score(candidate({ earned_7d: 0 }), { medianEarned7d: 10_000 });
  assert.ok(coldStart < withMedian, 'a cold start should not hand out the full fairness bonus');
});
