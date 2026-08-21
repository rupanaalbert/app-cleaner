// The candidate-ranking query, extracted so the load-test harness runs EXPLAIN
// against the *exact* SQL production uses — no drift between what's measured and
// what ships. Params, in order:
//   $1 booking id        $2 radius multiplier   $3 prior rating
//   $4 service code      $5 scheduled_at        $6 duration_min      $7 limit
//
// Performance note for whoever load-tests this: the `ST_DWithin` bound is
// `c.service_radius_km * 1000 * $2` — a per-row distance, not a constant. A GiST
// index answers "within a FIXED distance of a point"; a per-row radius denies it
// that, so this filter can fall back to a scan. If the plan shows a Seq Scan on
// cleaner_profiles, the fix is a constant-radius prefilter the index CAN use
// (e.g. `AND ST_DWithin(c.home_location, target.geo, <max_metres>)`) before the
// exact per-row check refines it.
export const FIND_CANDIDATES_SQL = `
      WITH target AS (
        SELECT a.location AS geo
          FROM bookings b
          JOIN properties p ON p.id = b.property_id
          JOIN addresses  a ON a.id = p.address_id
         WHERE b.id = $1
      )
      SELECT
        c.user_id AS cleaner_id,
        u.full_name,
        ST_Distance(c.home_location, target.geo) / 1000.0            AS distance_km,
        c.service_radius_km * $2                                     AS effective_radius_km,
        COALESCE(s.bayesian_rating, $3)                              AS quality_rating,
        COALESCE(s.completion_rate, 1)                               AS completion_rate,
        COALESCE(s.acceptance_rate, 1)                               AS acceptance_rate,
        COALESCE(s.late_cancels_60d, 0)                              AS late_cancels,
        COALESCE(e.earned_7d, 0)                                     AS earned_7d
      FROM cleaner_profiles c
      JOIN users u ON u.id = c.user_id
      CROSS JOIN target
      LEFT JOIN cleaner_rating_snapshot s ON s.cleaner_id = c.user_id
      LEFT JOIN LATERAL (
        SELECT SUM(payout_cents) AS earned_7d
          FROM bookings b2
         WHERE b2.cleaner_id = c.user_id
           AND b2.status IN ('completed','settled')
           AND b2.completed_at > now() - interval '7 days'
      ) e ON true
      WHERE u.status = 'active'
        AND c.onboarding_status = 'approved'
        AND c.bg_status = 'clear'
        AND (c.bg_expires_at IS NULL OR c.bg_expires_at > now())
        AND c.is_available = true
        AND (c.suspended_until IS NULL OR c.suspended_until < now())
        AND COALESCE(s.is_dispatchable, true) = true
        AND $4 = ANY (c.service_types)
        AND ST_DWithin(c.home_location, target.geo, c.service_radius_km * 1000 * $2)
        -- availability window (cleaner-local minutes-of-day)
        AND EXISTS (
          SELECT 1 FROM cleaner_availability av
           WHERE av.cleaner_id = c.user_id
             AND av.day_of_week = EXTRACT(DOW FROM $5::timestamptz)::smallint
             AND av.start_min <= EXTRACT(HOUR FROM $5::timestamptz) * 60
                                 + EXTRACT(MINUTE FROM $5::timestamptz)
             AND av.end_min   >= EXTRACT(HOUR FROM $5::timestamptz) * 60
                                 + EXTRACT(MINUTE FROM $5::timestamptz) + $6
        )
        -- no overlapping live job, plus a 45-minute travel buffer
        AND NOT EXISTS (
          SELECT 1 FROM bookings b3
           WHERE b3.cleaner_id = c.user_id
             AND b3.status IN ('assigned','en_route','arrived','in_progress')
             AND b3.time_span && tstzrange($5::timestamptz - interval '45 minutes',
                                           $5::timestamptz + ($6 || ' minutes')::interval
                                                           + interval '45 minutes')
        )
        -- never re-offer a job this cleaner already declined
        AND NOT EXISTS (
          SELECT 1 FROM booking_offers o
           WHERE o.booking_id = $1 AND o.cleaner_id = c.user_id AND o.status = 'declined'
        )
      ORDER BY distance_km ASC
      LIMIT $7
`;
