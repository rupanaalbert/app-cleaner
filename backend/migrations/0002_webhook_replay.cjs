'use strict';

// 0002 — replay bookkeeping for webhook_events.
//
// The table already records a failed webhook with its error text, but nothing
// retried it: a `payment.captured` that failed silently is a job the cleaner
// worked for free. These columns let a worker sweep the failures with backoff
// and give up after a threshold, and let an admin find the ones that gave up.
//
// Written with the node-pg-migrate DSL (not raw SQL) so `down` is real — this
// is exactly the "add a column to a live table" case 0001 as a single dump
// couldn't express.

exports.shorthands = undefined;

exports.up = (pgm) => {
  pgm.addColumns('webhook_events', {
    attempts: { type: 'smallint', notNull: true, default: 0 }, // replay attempts, not the live delivery
    last_attempt_at: { type: 'timestamptz' },
    next_attempt_at: { type: 'timestamptz' }, // when the sweeper may try again (backoff)
  });

  // The sweeper's scan: due, still-unresolved failures only. Partial so the
  // index stays the size of the backlog, not the size of the table.
  pgm.createIndex('webhook_events', 'next_attempt_at', {
    name: 'webhook_events_replay_ix',
    where: 'processed_at IS NULL AND error IS NOT NULL',
  });
};

exports.down = (pgm) => {
  pgm.dropIndex('webhook_events', 'next_attempt_at', { name: 'webhook_events_replay_ix' });
  pgm.dropColumns('webhook_events', ['attempts', 'last_attempt_at', 'next_attempt_at']);
};
