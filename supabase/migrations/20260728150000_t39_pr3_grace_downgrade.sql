-- =============================================================================
-- T-39 (PR3) — grace-period downgrade cron + E2E billing-ledger hygiene
--
-- The webhook (PR1/PR2) never downgrades on its own: cancellation keeps the
-- paid period and an overdue renewal only stamps `overdue_since`. This
-- migration adds the missing half — the scheduled job that flips the plan to
-- free WHEN (and only when) the paid/grace time actually runs out:
--
--   · status='canceled'  AND current_period_end in the past      → lapse
--   · status='overdue'   AND overdue_since older than the grace
--     window (billing.grace_days, default 7)                     → grace out
--
-- Rules (locked in PR1): the downgrade NEVER deletes data — the F-32 gates
-- simply re-engage; an overdue subscription keeps status 'overdue', so a late
-- payment webhook still reactivates it. Every downgrade is recorded in the
-- billing_events ledger (GRACE_DOWNGRADE) for audit.
--
-- Scheduling: pg_cron (already in the baseline), hourly at :23 — off the top
-- of the hour per the repo convention (GitHub/pg_cron top-of-hour congestion).
-- Runs in BOTH environments; harmless while billing is disabled (no rows match).
-- =============================================================================

-- ── 1. The downgrade function (service-side only) ────────────────────────────

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
		       CASE WHEN s.status = 'canceled' THEN 'canceled_lapsed'
		            ELSE 'overdue_grace_expired' END AS why
		FROM public.subscriptions s
		JOIN public.families f ON f.id = s.family_id
		WHERE f.plan = 'premium'
		  AND (
		        (s.status = 'canceled' AND s.current_period_end IS NOT NULL
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

-- ── 2. Schedule (hourly, off the top of the hour) ────────────────────────────
-- cron.schedule upserts by job name, so re-running the migration is safe.

SELECT cron.schedule(
	'billing-grace-downgrade',
	'23 * * * *',
	$$SELECT public.billing_grace_downgrade();$$
);

-- ── 3. E2E hygiene — the billing ledger survives the family cascade ──────────
-- billing_events.family_id is denormalized (no FK), so purge_e2e_family left
-- test events behind after every CI run. Extend the guarded purge to sweep
-- them; everything else is the existing function verbatim.

CREATE OR REPLACE FUNCTION public.purge_e2e_family(p_family_id bigint)
RETURNS SETOF uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	fam_name text;
	non_e2e_members int;
BEGIN
	SELECT name INTO fam_name FROM public.families WHERE id = p_family_id;
	IF fam_name IS NULL THEN
		RETURN;   -- already gone: purge is idempotent
	END IF;

	-- E2E double signature — refuse anything that is not unmistakably test data.
	IF fam_name NOT LIKE 'E2E-%' THEN
		RAISE EXCEPTION 'purge_e2e_family: family % is not an E2E family (name).', p_family_id
			USING ERRCODE = 'check_violation';
	END IF;
	SELECT count(*) INTO non_e2e_members
	FROM public.profiles
	WHERE family_id = p_family_id
	  AND email NOT LIKE '%@resend.dev'
	  AND email NOT LIKE 'removido+%@guarda.invalido';
	IF non_e2e_members > 0 THEN
		RAISE EXCEPTION 'purge_e2e_family: family % has non-E2E members (email).', p_family_id
			USING ERRCODE = 'check_violation';
	END IF;

	-- Hand the auth user ids back BEFORE deleting the profiles.
	RETURN QUERY
	SELECT user_id::uuid FROM public.profiles
	WHERE family_id = p_family_id AND user_id IS NOT NULL;

	-- Ordered teardown (children first; profiles are referenced by all data).
	DELETE FROM public.notifications
	WHERE recipient_profile_id IN (SELECT id FROM public.profiles WHERE family_id = p_family_id);
	DELETE FROM public.swap_requests      WHERE family_id = p_family_id;
	DELETE FROM public.care_schedules     WHERE family_id = p_family_id;
	DELETE FROM public.activity_logs      WHERE family_id = p_family_id;
	DELETE FROM public.family_invitations WHERE family_id = p_family_id;
	-- T-39: the billing ledger is denormalized on purpose (audit survives the
	-- subscription); for E2E families it must go with them.
	DELETE FROM public.billing_events     WHERE family_id = p_family_id;
	DELETE FROM public.profiles           WHERE family_id = p_family_id;
	DELETE FROM public.families           WHERE id = p_family_id;
END;
$$;
