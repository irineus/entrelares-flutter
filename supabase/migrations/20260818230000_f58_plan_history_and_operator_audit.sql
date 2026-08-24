-- =============================================================================
-- F-58 (QA round 2, 18/08/2026) — plan history for the FAMILY + audit read for
-- the OPERATOR
--
-- The owner's second console pass found the family's account history mute
-- about WHY a plan changed: the comp had its entries (QA round 1), but a paid
-- subscription arriving, a dunning downgrade or a cancellation lapse flipped
-- `families.plan` with nothing in the family's own trail.
--
-- Design: a TRIGGER on public.families, firing only when `plan` actually
-- changes — deliberately NOT edits to the writers. Plan flips happen in three
-- places today (billing-webhook via set_family_plan, the grace cron's direct
-- UPDATE, ops), and the billing path is production-critical: a trigger covers
-- all of them, plus any future writer, with zero risk added to the webhook.
-- The REASON is inferred from the family's subscription row at flip time:
--   free → premium:  single_charge row → avulso Pix; active row → paid
--                    subscription; anything else → generic activation
--   premium → free:  overdue row → grace expired (dunning); canceled row →
--                    subscription ended (lapse/refund); else → generic
-- The webhook stamps the subscription BEFORE flipping the plan, and the grace
-- cron flips while the row still says overdue/canceled, so the inference reads
-- the state each writer just left — no GUC, no writer edits.
-- "Trial ended" is deliberately NOT here: expiry writes nothing (is_premium()
-- computes it), so the app renders it as a synthetic timeline entry from
-- trial_ends_at — a computed fact, shown as such, never a forged audit row.
--
-- admin_list_audit(): the operator's read over operator_audit_logs (console
-- "Auditoria" tab). Reading the trail is how the trail is USED — it writes no
-- audit row of itself, or every view would double the log.
-- =============================================================================

-- ── 1. Plan-change history into the family's account_logs ────────────────────

CREATE OR REPLACE FUNCTION public.audit_family_plan_change()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	actor      bigint;
	sub        public.subscriptions%ROWTYPE;
	the_action text;
BEGIN
	SELECT id INTO actor FROM public.profiles WHERE user_id = auth.uid();
	SELECT * INTO sub FROM public.subscriptions WHERE family_id = NEW.id;

	IF NEW.plan = 'premium' THEN
		the_action := CASE
			WHEN sub.id IS NOT NULL AND sub.single_charge THEN 'plan_premium_avulso'
			WHEN sub.id IS NOT NULL AND sub.status = 'active' THEN 'plan_premium_payment'
			ELSE 'plan_premium_set'
		END;
	ELSE
		the_action := CASE
			WHEN sub.id IS NOT NULL AND sub.status = 'overdue' THEN 'plan_free_overdue'
			WHEN sub.id IS NOT NULL AND sub.status = 'canceled' THEN 'plan_free_canceled'
			ELSE 'plan_free_set'
		END;
	END IF;

	INSERT INTO public.account_logs (family_id, actor_profile_id, action, old_value, new_value)
	VALUES (NEW.id, actor, the_action, OLD.plan, NEW.plan);

	RETURN NEW;
END;
$$;

ALTER FUNCTION public.audit_family_plan_change() OWNER TO postgres;

DROP TRIGGER IF EXISTS trigger_audit_family_plan ON public.families;
CREATE TRIGGER trigger_audit_family_plan
	AFTER UPDATE OF plan ON public.families
	FOR EACH ROW
	WHEN (OLD.plan IS DISTINCT FROM NEW.plan)
	EXECUTE FUNCTION public.audit_family_plan_change();

-- ── 2. admin_list_audit — the operator's own trail, readable in the console ──

CREATE OR REPLACE FUNCTION public.admin_list_audit(p_limit int DEFAULT 200)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	result jsonb;
BEGIN
	IF NOT public.is_platform_operator() THEN
		RAISE EXCEPTION 'Acesso restrito à operação da plataforma.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	SELECT COALESCE(jsonb_agg(entry ORDER BY id DESC), '[]'::jsonb)
	INTO result
	FROM (
		SELECT l.id,
		       jsonb_build_object(
		           'id',          l.id,
		           'action',      l.action,
		           'family_id',   l.family_id,
		           'family_name', (SELECT f.name FROM public.families f WHERE f.id = l.family_id),
		           'setting_key', l.setting_key,
		           'old_value',   l.old_value,
		           'new_value',   l.new_value,
		           'created_at',  l.created_at
		       ) AS entry
		FROM public.operator_audit_logs l
		ORDER BY l.id DESC
		LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 200), 1000))
	) latest;

	RETURN result;
END;
$$;

ALTER FUNCTION public.admin_list_audit(int) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.admin_list_audit(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_audit(int) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_list_audit(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_audit(int) TO service_role;
