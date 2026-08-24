'use strict';

// 0003 — swap Stripe Connect for PayPal (collect-then-disburse).
//
// Stripe Connect Express gated every cleaner behind Stripe's own business
// verification review, which is what's blocking launch. The replacement
// architecture collects into Sparkle's own PayPal account (Orders v2,
// intent=AUTHORIZE, no split at capture) and disburses the cleaner's share
// separately via the Payouts API once a hold window has passed — see
// `payment.service.js` and `CLAUDE.md` invariant #7 for why the hold window
// and `payout_adjustments` exist: PayPal Payouts is a one-way send with no
// `reverse_transfer` equivalent, so a refund after disbursement can't claw
// back automatically the way Stripe's did.
//
// Pre-launch, no production data — old Stripe columns are dropped outright
// rather than kept as deprecated nullable cruft.

exports.shorthands = undefined;

exports.up = (pgm) => {
  // customer_profiles: Orders v2 is stateless per-order, no stored customer id.
  pgm.dropColumns('customer_profiles', ['stripe_customer_id']);

  // cleaner_profiles: an on-file PayPal email replaces the Connect account id.
  // `payouts_enabled` keeps its name and meaning (never set optimistically —
  // see webhook.service.js's verification-payout handler) but is now driven
  // by a $0.01 verification payout, not Stripe's account.updated webhook.
  pgm.addColumns('cleaner_profiles', {
    paypal_email: { type: 'text' },
  });
  pgm.dropColumns('cleaner_profiles', ['stripe_account_id']);

  // payments: application_fee_cents renamed to platform_fee_cents — it was
  // always "commission + T&S fee" in spirit, application_fee_amount was just
  // the Stripe field name it fed into.
  pgm.addColumns('payments', {
    paypal_order_id: { type: 'text' },
    paypal_authorization_id: { type: 'text' },
    paypal_capture_id: { type: 'text' },
  });
  pgm.renameColumn('payments', 'application_fee_cents', 'platform_fee_cents');
  pgm.dropColumns('payments', ['stripe_payment_intent_id', 'stripe_charge_id', 'stripe_fee_cents']);
  pgm.alterColumn('payments', 'paypal_order_id', { notNull: true });
  pgm.addConstraint('payments', 'payments_paypal_order_id_uq', 'UNIQUE (paypal_order_id)');

  // refunds
  pgm.addColumns('refunds', {
    paypal_refund_id: { type: 'text' },
  });
  pgm.dropColumns('refunds', ['stripe_refund_id']);
  pgm.alterColumn('refunds', 'paypal_refund_id', { notNull: true });
  pgm.addConstraint('refunds', 'refunds_paypal_refund_id_uq', 'UNIQUE (paypal_refund_id)');

  // payouts: hold_until drives the disbursement sweep
  // (`disburse_pending_payouts` in jobs/worker.js); batch/item ids replace
  // the single stripe_transfer_id (which, under destination charges, actually
  // held the destination account id — this fixes that pre-existing misnomer
  // by giving batch and item their own columns instead of overloading one).
  pgm.addColumns('payouts', {
    paypal_payout_batch_id: { type: 'text' },
    paypal_payout_item_id: { type: 'text' },
    hold_until: { type: 'timestamptz' },
  });
  pgm.dropColumns('payouts', ['stripe_transfer_id', 'stripe_payout_id']);

  // A late refund after a payout has already been disbursed can't claw back
  // atomically (no reverse_transfer equivalent) — it debits the cleaner's
  // next payout batch instead. See payment.service.js `refund()`.
  pgm.createTable('payout_adjustments', {
    id: { type: 'uuid', primaryKey: true, default: pgm.func('uuid_generate_v7()') },
    booking_id: { type: 'uuid', notNull: true, references: 'bookings' },
    cleaner_id: { type: 'uuid', notNull: true, references: 'cleaner_profiles(user_id)' },
    amount_cents: { type: 'int', notNull: true, check: 'amount_cents > 0' },
    reason: { type: 'text', notNull: true },
    applied_to_payout_id: { type: 'uuid', references: 'payouts' }, // set once netted against a batch
    created_at: { type: 'timestamptz', notNull: true, default: pgm.func('now()') },
  });
  pgm.createIndex('payout_adjustments', ['cleaner_id', 'applied_to_payout_id']);

  // Postgres can add an enum value inside a transaction (PG12+); it just can't
  // be *used* in the same transaction it's added in, which this migration
  // doesn't need to do.
  pgm.sql("ALTER TYPE payout_status ADD VALUE IF NOT EXISTS 'canceled'");
};

exports.down = (pgm) => {
  // Postgres has no DROP VALUE for enums short of recreating the type, which
  // would fail if any row already uses 'canceled' by the time this runs —
  // deliberately left as a no-op, matching how irreversible enum additions
  // are usually handled in practice.

  pgm.dropIndex('payout_adjustments', ['cleaner_id', 'applied_to_payout_id']);
  pgm.dropTable('payout_adjustments');

  pgm.addColumns('payouts', {
    stripe_transfer_id: { type: 'text', unique: true },
    stripe_payout_id: { type: 'text' },
  });
  pgm.dropColumns('payouts', ['paypal_payout_batch_id', 'paypal_payout_item_id', 'hold_until']);

  pgm.addColumns('refunds', {
    stripe_refund_id: { type: 'text', notNull: true, unique: true },
  });
  pgm.dropConstraint('refunds', 'refunds_paypal_refund_id_uq');
  pgm.dropColumns('refunds', ['paypal_refund_id']);

  pgm.addColumns('payments', {
    stripe_payment_intent_id: { type: 'text', notNull: true, unique: true },
    stripe_charge_id: { type: 'text' },
    stripe_fee_cents: { type: 'int' },
  });
  pgm.renameColumn('payments', 'platform_fee_cents', 'application_fee_cents');
  pgm.dropConstraint('payments', 'payments_paypal_order_id_uq');
  pgm.dropColumns('payments', ['paypal_order_id', 'paypal_authorization_id', 'paypal_capture_id']);

  pgm.addColumns('cleaner_profiles', {
    stripe_account_id: { type: 'text', unique: true },
  });
  pgm.dropColumns('cleaner_profiles', ['paypal_email']);

  pgm.addColumns('customer_profiles', {
    stripe_customer_id: { type: 'text', unique: true },
  });
};
