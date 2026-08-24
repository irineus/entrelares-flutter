-- =============================================================================
-- F-58 (QA round, 18/08/2026) — admin_list_families()
--
-- The console's first QA pass asked for the family screen to LIST everything
-- upfront and filter client-side (by family name, member name or member
-- e-mail), instead of requiring an exact e-mail to find anything — and for a
-- participants view built from the same data. At closed-alpha scale the whole
-- dataset is dozens of rows, so one operator-gated RPC returns it all and the
-- console filters locally.
--
-- Same security shape as the other admin_* RPCs (20260818150000): operator
-- gate first, and the access is AUDITED — one row per listing, because a bulk
-- read of every family's cadastral data is exactly the kind of access the
-- trail exists for. Subscription data rides along so the family detail screen
-- needs no second call.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_list_families()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	result jsonb;
BEGIN
	IF NOT public.is_platform_operator() THEN
		RAISE EXCEPTION 'Acesso restrito à operação da plataforma.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	INSERT INTO public.operator_audit_logs (operator_user_id, action)
	VALUES (auth.uid(), 'families_listed');

	SELECT COALESCE(jsonb_agg(jsonb_build_object(
		'id',                f.id,
		'name',              f.name,
		'plan',              f.plan,
		'trial_ends_at',     f.trial_ends_at,
		'comp_premium_at',   f.comp_premium_at,
		'comp_premium_note', f.comp_premium_note,
		'is_premium',        public.is_premium(f.id),
		'created_at',        f.created_at,
		'subscription', (
			SELECT jsonb_build_object(
				'status',             s.status,
				'cycle',              s.cycle,
				'price_cents',        s.price_cents,
				'current_period_end', s.current_period_end,
				'overdue_since',      s.overdue_since,
				'canceled_at',        s.canceled_at
			)
			FROM public.subscriptions s WHERE s.family_id = f.id
		),
		'members', (
			SELECT COALESCE(jsonb_agg(jsonb_build_object(
				'id',        p.id,
				'full_name', p.full_name,
				'email',     p.email,
				'role',      (SELECT r.role FROM public.roles r WHERE r.id = p.role_id),
				'is_admin',  p.is_admin,
				'left_at',   p.left_at
			) ORDER BY p.id), '[]'::jsonb)
			FROM public.profiles p WHERE p.family_id = f.id
		)
	) ORDER BY f.name, f.id), '[]'::jsonb)
	INTO result
	FROM public.families f;

	RETURN result;
END;
$$;

ALTER FUNCTION public.admin_list_families() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.admin_list_families() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_families() FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_list_families() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_families() TO service_role;
