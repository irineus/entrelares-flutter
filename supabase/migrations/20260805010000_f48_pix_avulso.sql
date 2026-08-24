-- F-48 (block 3) — Pix avulso: a single NON-RECURRING charge for one period.
--
-- The row model reuses the whole canceled-with-paid-time machinery on purpose:
-- after the charge settles, the webhook leaves the row at status 'canceled'
-- with current_period_end one cycle ahead — which is exactly "premium until X,
-- no further charges": the offer shows "Premium ativo até X", renewing is
-- additive, the grace cron lapses it, and U-22 announces the expiry. The ONLY
-- new state is the marker below, which
--   · tells the webhook a settling payment must NOT leave the row 'active'
--     (there is no gateway subscription to renew it), and
--   · excludes the row from the F-42 reactivate path (both sides guard it):
--     "reactivate my subscription" is not a thing the family ever had.
--
-- Idempotent: IF NOT EXISTS; the backfill default (false) is correct for every
-- existing row — they were all created by the recurring checkout.

ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS single_charge boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.subscriptions.single_charge IS
  'F-48: true when the row was created by the Pix avulso (single, non-recurring charge) checkout. A settled avulso rests at status ''canceled'' with the paid period on current_period_end; never eligible for F-42 reactivation.';
