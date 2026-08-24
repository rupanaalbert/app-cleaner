/**
 * Pricing math. Pure functions, zero imports.
 *
 * This is separated from `services/pricing.service.js` on purpose: the service
 * needs Postgres to fetch rules, and a test that needs a live database is a
 * test nobody runs before pushing. Every number that can become a refund queue
 * lives here and is testable in milliseconds.
 *
 * All amounts are integer cents. All rates are basis points (10000 = 1.00x).
 */

export const BPS = 10_000;
export const applyBps = (cents, bps) => Math.round((cents * bps) / BPS);

export function sizeTierAdjustment(rules, squareFeet) {
  if (!squareFeet) return 0;
  for (const tier of rules.size_tiers) {
    if (tier.max_sqft === null || squareFeet <= tier.max_sqft) return tier.adj_cents;
  }
  return 0;
}

/**
 * Demand multipliers stack multiplicatively and are capped, so a weekend
 * evening in a surge window can't quietly triple a customer's bill. When the
 * cap bites it is added to `applied` rather than swallowed — a price the
 * breakdown can't explain is a support ticket.
 */
export function demandMultipliers(rules, scheduledAt, timeZone = 'America/New_York') {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone, weekday: 'short', hour: 'numeric', hour12: false,
  }).formatToParts(new Date(scheduledAt));

  const weekday = parts.find((p) => p.type === 'weekday').value;
  const hour = Number(parts.find((p) => p.type === 'hour').value) % 24;

  const applied = [];
  if (weekday === 'Sat' || weekday === 'Sun') {
    applied.push({ code: 'weekend', factor_bps: rules.weekend_bps });
  }
  if (hour >= 17) {
    applied.push({ code: 'evening', factor_bps: rules.evening_bps });
  }

  let combinedBps = BPS;
  for (const m of applied) combinedBps = Math.round((combinedBps * m.factor_bps) / BPS);

  if (combinedBps > rules.demand_cap_bps) {
    combinedBps = rules.demand_cap_bps;
    applied.push({ code: 'cap_applied', factor_bps: rules.demand_cap_bps });
  }
  return { applied, combinedBps };
}

export function trustAndSafetyFee(rules, subtotalCents) {
  return Math.min(
    rules.ts_fee_flat_cents + applyBps(subtotalCents, rules.ts_fee_bps),
    rules.ts_fee_cap_cents,
  );
}

/**
 * The whole quote, from rules and choices to every line the customer sees.
 * Commission is taken on the subtotal only — never on the trust & safety fee,
 * never on tips.
 */
export function composeQuote({ rules, property, service, addons = [], scheduledAt, timeZone }) {
  const bedroomsCents = property.bedrooms * rules.per_bedroom_cents;
  const bathroomsCents = property.bathrooms * rules.per_bathroom_cents;
  const sizeCents = sizeTierAdjustment(rules, property.square_feet);
  const addonCents = addons.reduce((sum, a) => sum + a.price_cents, 0);

  const preMultiplier = rules.base_cents + bedroomsCents + bathroomsCents + sizeCents + addonCents;
  const afterService = applyBps(preMultiplier, service.multiplier_bps);
  const demand = demandMultipliers(rules, scheduledAt, timeZone);

  const subtotalCents = applyBps(afterService, demand.combinedBps);
  const tsFeeCents = trustAndSafetyFee(rules, subtotalCents);
  const taxCents = 0; // No tax provider wired up yet — a no-op in every metro today
  const commissionCents = applyBps(subtotalCents, rules.commission_bps);

  const rawMinutes = service.base_minutes
    + property.bedrooms * service.minutes_per_bedroom
    + property.bathrooms * service.minutes_per_bathroom
    + addons.reduce((sum, a) => sum + a.minutes, 0);

  return {
    duration_min: Math.ceil(rawMinutes / 15) * 15, // round to the quarter hour
    subtotal_cents: subtotalCents,
    ts_fee_cents: tsFeeCents,
    tax_cents: taxCents,
    total_cents: subtotalCents + tsFeeCents + taxCents,
    commission_cents: commissionCents,
    payout_cents: subtotalCents - commissionCents,
    breakdown: {
      base_cents: rules.base_cents,
      bedrooms: { count: property.bedrooms, unit_cents: rules.per_bedroom_cents, cents: bedroomsCents },
      bathrooms: { count: property.bathrooms, unit_cents: rules.per_bathroom_cents, cents: bathroomsCents },
      size_tier_cents: sizeCents,
      addons: addons.map((a) => ({ code: a.code, cents: a.price_cents })),
      service: { code: service.code, multiplier_bps: service.multiplier_bps },
      multipliers: demand.applied,
      subtotal_cents: subtotalCents,
      trust_safety_fee_cents: tsFeeCents,
      commission_bps: rules.commission_bps,
    },
  };
}

/** Authorize above the quote so a modest overrun doesn't need a second hold. */
export const authorizationAmount = (totalCents, bufferBps) =>
  totalCents + applyBps(totalCents, bufferBps);

/**
 * Inside the late window the cleaner is paid for the slot they can no longer
 * fill, and the platform takes no commission on it. An unassigned booking
 * cancels free: nobody lost a slot, so nobody is owed.
 */
export function cancellationOutcome(booking, { lateCancelHours, lateCancelShareBps }, now = new Date()) {
  const hoursOut = (new Date(booking.scheduled_at) - now) / 3_600_000;
  if (hoursOut >= lateCancelHours || !booking.cleaner_id) {
    return { fee_cents: 0, cleaner_cents: 0, refund_cents: booking.total_cents };
  }
  const fee = applyBps(booking.subtotal_cents, lateCancelShareBps);
  return { fee_cents: fee, cleaner_cents: fee, refund_cents: booking.total_cents - fee };
}
