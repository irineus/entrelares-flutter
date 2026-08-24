-- =============================================================================
-- F-42 (PR1) — Scheduled reactivation: payment method on the row + a
--              'scheduled' subscription state (no immediate charge)
--
-- WHY THIS EXISTS. Today a family that canceled but still has paid time can
-- only come back by PAYING NOW; the webhook then ADDS the remaining time
-- (period counted from the later of dueDate / current_period_end), so nothing
-- is lost. F-42 adds the alternative UX — "Reativar assinatura" with NO charge
-- today, the next invoice falling due exactly when the paid period ends.
--
-- Feasibility is asymmetric and that asymmetry is the whole design (recorded in
-- the backlog entry, July 2026):
--   · Pix/boleto — FEASIBLE. Invoice-style billing needs no stored payment
--     instrument: we create an Asaas subscription for the ALREADY-STORED
--     customer (`external_customer_id`, written by the webhook on the first
--     confirmed payment) with nextDueDate = current_period_end. The charge is
--     only emitted at the due date.
--   · Card — NOT FEASIBLE under our hosted/no-PCI model: resuming auto-debit
--     needs the card token, which we deliberately never touch. Card families
--     keep the checkout-now + additive-time path, which is already fair.
--
-- To ACT on that asymmetry the server has to know how the family paid. The
-- webhook already receives `payment.billingType`, but it only ever reached the
-- raw `billing_events.payload` jsonb — unusable as a gate (and invisible to the
-- UI, which must decide whether to even show the button). Section 1 promotes it
-- to a first-class column.
--
-- Section 2 adds the 'scheduled' status: a subscription that EXISTS at the
-- gateway with a future first due date and no payment yet. It is deliberately a
-- distinct state and not a reuse of 'pending' — 'pending' means "a checkout was
-- started, nobody paid, and there is no gateway subscription", whereas a
-- scheduled row owns a real `external_subscription_id` that will emit a charge
-- on its own. Collapsing them would make `cancel` (which branches on exactly
-- that field) and the UI copy lie.
--
-- Section 3 is the safety net, and it is the reason this migration is not just
-- two ALTERs: `billing_grace_downgrade` lapses premium for 'canceled' rows
-- whose paid period ran out. A reactivated row is NO LONGER canceled, so
-- without this change a family whose scheduled invoice was never paid — and
-- whose PAYMENT_OVERDUE webhook was missed or delayed — would keep premium
-- forever. 'scheduled' therefore lapses exactly like 'canceled': premium runs
-- to current_period_end, then falls back. The happy path never reaches it (a
-- paid invoice flips the row to 'active' and extends the period first).
--
-- No entitlement change happens at reactivation time by design: the family is
-- already premium until current_period_end and stays so through the F-32 rule.
-- =============================================================================

-- ── 1. How the family paid ───────────────────────────────────────────────────
-- Raw Asaas vocabulary (PIX / BOLETO / CREDIT_CARD / UNDEFINED …), stored
-- verbatim and intentionally NOT constrained by a CHECK: the gateway may add
-- values at any time and a webhook that starts failing on an unknown method
-- would stall entitlement for a family that actually paid. Readers treat
-- anything they do not recognise as "not reactivatable" — the safe default.

ALTER TABLE public.subscriptions
	ADD COLUMN IF NOT EXISTS billing_type text;

COMMENT ON COLUMN public.subscriptions.billing_type IS
	'F-42: payment method of the last confirmed payment, verbatim from Asaas (PIX, BOLETO, CREDIT_CARD, UNDEFINED…). NULL = never paid / unknown. Gates the no-charge reactivation: only invoice-style methods (Pix/boleto) can be rescheduled without the payer''s instrument.';

-- ── 2. The 'scheduled' state ─────────────────────────────────────────────────
-- The T-39 baseline declared the status CHECK inline, so Postgres named it
-- `subscriptions_status_check`. Drop by that name (IF EXISTS keeps the
-- migration re-runnable) and re-add it explicitly named with the new value.

ALTER TABLE public.subscriptions
	DROP CONSTRAINT IF EXISTS subscriptions_status_check;

ALTER TABLE public.subscriptions
	ADD CONSTRAINT subscriptions_status_check
	CHECK (status IN ('pending', 'scheduled', 'active', 'overdue', 'canceled'));

COMMENT ON COLUMN public.subscriptions.status IS
	'pending (checkout started, nobody paid, no gateway subscription) | scheduled (F-42: gateway subscription exists, first charge due at current_period_end, nothing paid yet) | active | overdue | canceled.';

-- ── 3. Safety net: a scheduled row lapses like a canceled one ────────────────
-- Identical to the T-39 PR3 function except for the status list and the reason
-- label. Kept as a full CREATE OR REPLACE (fix-forward convention) so the whole
-- body stays readable in one place.

CREATE OR REPLACE FUNCTION public.billing_grace_downgrade()
RETURNS TABLE (family_id bigint, reason text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	grace_days int := public.setting_int('billing.grace_days', 7);
BEGIN
	RETURN QUERY
	WITH lapsed AS (
		SELECT s.id AS subscription_id, s.family_id AS fam_id,
		       CASE WHEN s.status = 'canceled'  THEN 'canceled_lapsed'
		            WHEN s.status = 'scheduled' THEN 'scheduled_unpaid_lapsed'
		            ELSE 'overdue_grace_expired' END AS why
		FROM public.subscriptions s
		JOIN public.families f ON f.id = s.family_id
		WHERE f.plan = 'premium'
		  AND (
		        -- F-42: 'scheduled' joins 'canceled' here. Both mean "premium is
		        -- running on time already paid for"; when that time is gone and
		        -- no new payment landed, the plan lapses.
		        (s.status IN ('canceled', 'scheduled') AND s.current_period_end IS NOT NULL
		         AND s.current_period_end < timezone('utc', now()))
		     OR (s.status = 'overdue' AND s.overdue_since IS NOT NULL
		         AND s.overdue_since < timezone('utc', now()) - make_interval(days => grace_days))
		  )
	), downgraded AS (
		-- Same semantics as set_family_plan(id, 'free'): trial cleared so
		-- is_premium() is honest afterwards.
		UPDATE public.families f
		SET plan = 'free', trial_ends_at = NULL
		FROM lapsed l
		WHERE f.id = l.fam_id
		RETURNING f.id
	), logged AS (
		INSERT INTO public.billing_events (event_id, event_type, subscription_id, family_id, payload)
		SELECT 'grace_' || l.subscription_id || '_' || to_char(timezone('utc', now()), 'YYYYMMDDHH24MI'),
		       'GRACE_DOWNGRADE', l.subscription_id, l.fam_id,
		       jsonb_build_object('reason', l.why)
		FROM lapsed l
		ON CONFLICT (event_id) DO NOTHING
		RETURNING 1
	)
	SELECT l.fam_id, l.why FROM lapsed l;
END;
$$;

ALTER FUNCTION public.billing_grace_downgrade() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.billing_grace_downgrade() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_grace_downgrade() TO service_role;

COMMENT ON FUNCTION public.billing_grace_downgrade() IS
	'T-39 PR3 + F-42: lapses premium when the paid period ends (canceled or scheduled-unpaid) or the overdue grace window expires. Never deletes data — the F-32 gates simply re-engage.';
