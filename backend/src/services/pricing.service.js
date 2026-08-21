import { query } from '../db/pool.js';
import { config } from '../config/index.js';
import { AppError } from '../utils/errors.js';
import * as math from '../domain/pricing.math.js';

/**
 * Pricing engine — the database-facing half.
 *
 * All arithmetic lives in `domain/pricing.math.js` so it can be tested without
 * Postgres. This class resolves which rules apply and persists the result.
 */
export class PricingService {
  /** Active rule set for a metro at a point in time. */
  static async getRules(metro = 'default', at = new Date()) {
    const { rows } = await query(
      `SELECT * FROM pricing_rules
        WHERE metro = $1 AND effective_from <= $2
          AND (effective_to IS NULL OR effective_to > $2)
        ORDER BY effective_from DESC LIMIT 1`,
      [metro, at],
    );
    if (!rows[0]) throw AppError.unprocessable('NO_PRICING_RULES', `No pricing configured for ${metro}`);
    return rows[0];
  }

  /**
   * Resolves rules, prices the job, and returns a breakdown ready to persist.
   * The fully resolved rule set is stored on the quote so a support agent can
   * explain a price six months after the rules changed.
   */
  static async estimate({ property, service, addons = [], scheduledAt, metro = 'default', timeZone }) {
    const rules = await this.getRules(metro, new Date());
    return {
      pricing_rule_id: rules.id,
      ...math.composeQuote({ rules, property, service, addons, scheduledAt, timeZone }),
    };
  }

  static authorizationAmount(totalCents) {
    return math.authorizationAmount(totalCents, config.booking.authBufferBps);
  }

  static cancellationOutcome(booking, now = new Date()) {
    return math.cancellationOutcome(booking, config.booking, now);
  }

  // Re-exported so existing callers and tests keep one import surface.
  static sizeTierAdjustment = math.sizeTierAdjustment;
  static demandMultipliers = math.demandMultipliers;
  static trustAndSafetyFee = math.trustAndSafetyFee;
}
