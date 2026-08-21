/**
 * Candidate ranking. Pure, dependency-free — same reasoning as pricing.math.js.
 *
 * Score is in [0,1]. Hard eligibility (background check, availability, radius,
 * no overlapping job) is enforced in SQL; this only ranks the survivors.
 */

/**
 * Bayesian-smoothed rating. Without the prior, one 5.0 review outranks 200
 * jobs at 4.85 and the top of every search is a cleaner nobody has vetted in
 * practice.
 */
export const bayesianRating = (sum, count, { priorRating, priorWeight }) =>
  (sum + priorRating * priorWeight) / (count + priorWeight);

export function scoreCandidate(candidate, { weights, medianEarned7d }) {
  const proximity = Math.max(0, 1 - candidate.distance_km / candidate.effective_radius_km);

  // Scaled from 3.0: anything below that is already excluded upstream, so
  // spending score resolution on 1.0–3.0 would waste the range.
  const quality = Math.min(1, Math.max(0, (candidate.quality_rating - 3) / 2));

  // 0.12 per late cancel, not 0.05: at 0.05 a cleaner with four late cancels in
  // 60 days still outranked a reliable one 3 km further out. Late cancellations
  // are the single biggest driver of customer churn, so they have to cost more
  // than a short drive saves.
  const reliability = Math.min(1, Math.max(0, candidate.completion_rate - candidate.late_cancels * 0.12));
  const acceptance = Math.min(1, Math.max(0, candidate.acceptance_rate));

  // Not charity. A marketplace where the top 5% take every job loses the other
  // 95% of its supply within a month. Cold start is neutral, not maximal.
  const fairness = medianEarned7d > 0
    ? Math.min(1, Math.max(0, 1 - candidate.earned_7d / medianEarned7d))
    : 0.5;

  const score = weights.proximity * proximity
    + weights.quality * quality
    + weights.reliability * reliability
    + weights.acceptance * acceptance
    + weights.fairness * fairness;

  return Number(score.toFixed(4));
}
