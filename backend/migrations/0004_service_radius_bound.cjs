'use strict';

// 0004 — bound cleaner_profiles.service_radius_km at the database.
//
// findCandidates' index-usable prefilter (matching.candidates.sql.js) is only
// correct if no cleaner's service_radius_km can exceed
// config.matching.maxServiceRadiusKm (60, enforced today by onboarding.routes.js's
// zod schema). App-layer validation is a soft guarantee — a future write path
// (an admin tool, a script) that skips it would let a real row past a radius the
// query's prefilter assumes is impossible, silently dropping that cleaner from
// every match. This CHECK makes the bound a real invariant instead of a
// convention two files have to independently remember.

exports.shorthands = undefined;

exports.up = (pgm) => {
  pgm.addConstraint('cleaner_profiles', 'service_radius_within_bound',
    'CHECK (service_radius_km <= 60)');
};

exports.down = (pgm) => {
  pgm.dropConstraint('cleaner_profiles', 'service_radius_within_bound');
};
