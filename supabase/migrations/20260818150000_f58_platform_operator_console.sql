-- =============================================================================
-- F-58 — Platform-operator console (PR 1: database foundation)
--
-- The product gains its first PLATFORM-level role: the operator. Everything the
-- app had so far is family-scoped (`is_admin` is FAMILY admin; RLS fences every
-- table by family) — the operator is the person who RUNS the platform, and the
-- console UI lives in a separate Flutter app (`entrelares-console`), so not one
-- line of operator UI ships in the public bundle. Security therefore lives HERE:
-- the console is only a caller of the RPCs below.
--
-- SECURITY MODEL (decisions locked 18/08/2026, owner):
--   · `platform_operators` is seeded by MIGRATION from the owner's auth e-mail —
--     never assignable through any UI or client-callable RPC. No client role has
--     ANY privilege on the table (T-41 lesson: privilege-level denial fails hard).
--   · ZERO broad RLS bypass: every operator capability is a SECURITY DEFINER RPC
--     that checks auth.uid() against the seeded table (T-35 lesson: never
--     current_user inside DEFINER) and, on every WRITE, requires an active S-10
--     sudo elevation (`ELEVATION_REQUIRED:` contract, same as set_member_admin).
--   · `policy.current_version` / `policy.enforce_from` are READ-ONLY here: a
--     console edit would desync `PolicyVersions.cs` and the S-15 four-piece
--     delivery rule, risking a production-wide lockout. Migration flow only.
--   · Comp Premium is a DEDICATED column read by is_premium() — never a parallel
--     `if`, and orthogonal to `plan`, so a billing webhook downgrade can never
--     silently clobber a courtesy grant. Comp SEMANTICS (who gets it, F-53) come
--     in their own item; this migration ships the mechanism.
--   · Transparency: granting/revoking comp writes the family's own account_logs
--     (visible to its members — actor NULL renders as the system actor), besides
--     the operator's append-only audit trail (`operator_audit_logs`).
--   · `operator_audit_logs` carries NO foreign keys on purpose: it is evidence,
--     and must outlive the family or operator account it names (same reasoning
--     as the C-6 opt-in log). Reads are service_role/Dashboard-only in v1.
-- =============================================================================

-- ── 1. platform_operators ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.platform_operators (
	user_id    uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
	granted_at timestamp with time zone NOT NULL DEFAULT timezone('utc', now()),
	note       text
);

ALTER TABLE public.platform_operators OWNER TO postgres;
ALTER TABLE public.platform_operators ENABLE ROW LEVEL SECURITY;

-- No client access AT ALL — not even SELECT. The UI-gating question ("am I the
-- operator?") is answered by is_platform_operator(), which only ever discloses
-- the caller's OWN status.
REVOKE ALL ON TABLE public.platform_operators FROM PUBLIC;
REVOKE ALL ON TABLE public.platform_operators FROM anon;
REVOKE ALL ON TABLE public.platform_operators FROM authenticated;
GRANT ALL ON TABLE public.platform_operators TO service_role;

-- Seed: the owner's account, matched by e-mail. Idempotent; finds nothing on an
-- environment where that account does not exist yet (see supabase/README.md —
-- the grant can then be done by service_role once the account signs up).
INSERT INTO public.platform_operators (user_id, note)
SELECT id, 'Owner — seeded by migration (F-58)'
FROM auth.users
WHERE lower(email) = 'irineus@gmail.com'
ON CONFLICT (user_id) DO NOTHING;

-- ── 2. is_platform_operator() ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.is_platform_operator()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
	SELECT EXISTS (
		SELECT 1 FROM public.platform_operators WHERE user_id = auth.uid()
	);
$$;

ALTER FUNCTION public.is_platform_operator() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.is_platform_operator() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_platform_operator() FROM anon;
GRANT EXECUTE ON FUNCTION public.is_platform_operator() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_platform_operator() TO service_role;

-- ── 3. Comp Premium column + is_premium() ────────────────────────────────────

ALTER TABLE public.families
	ADD COLUMN IF NOT EXISTS comp_premium_at   timestamp with time zone,
	ADD COLUMN IF NOT EXISTS comp_premium_note text;

-- Body from 20260723120000 (the only prior definition), adding ONLY the comp
-- clause. Every gate reads this function, so the comp flows through the same
-- entitlement rule as plan/trial (never a parallel check).
CREATE OR REPLACE FUNCTION public.is_premium(p_family_id bigint)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
	SELECT EXISTS (
		SELECT 1 FROM public.families f
		WHERE f.id = p_family_id
		  AND (f.plan = 'premium'
		       OR f.comp_premium_at IS NOT NULL
		       OR (f.trial_ends_at IS NOT NULL AND f.trial_ends_at > timezone('utc', now())))
	);
$$;

ALTER FUNCTION public.is_premium(bigint) OWNER TO postgres;

-- ── 4. operator_audit_logs ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.operator_audit_logs (
	id               bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
	operator_user_id uuid NOT NULL,
	action           text NOT NULL,
	family_id        bigint,
	setting_key      text,
	old_value        text,
	new_value        text,
	created_at       timestamp with time zone NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS operator_audit_logs_created_idx
	ON public.operator_audit_logs (created_at DESC);

ALTER TABLE public.operator_audit_logs OWNER TO postgres;
ALTER TABLE public.operator_audit_logs ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.operator_audit_logs FROM PUBLIC;
REVOKE ALL ON TABLE public.operator_audit_logs FROM anon;
REVOKE ALL ON TABLE public.operator_audit_logs FROM authenticated;
GRANT ALL ON TABLE public.operator_audit_logs TO service_role;

-- ── 5. admin_list_settings ───────────────────────────────────────────────────
-- Read-only, operator-gated view of the WHOLE app_settings table (the client
-- RLS only ever exposes is_public rows — the console needs them all).

CREATE OR REPLACE FUNCTION public.admin_list_settings()
RETURNS SETOF public.app_settings
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
	IF NOT public.is_platform_operator() THEN
		RAISE EXCEPTION 'Acesso restrito à operação da plataforma.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	RETURN QUERY
	SELECT * FROM public.app_settings ORDER BY category, key;
END;
$$;

ALTER FUNCTION public.admin_list_settings() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.admin_list_settings() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_settings() FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_list_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_settings() TO service_role;

-- ── 6. admin_update_setting ──────────────────────────────────────────────────
-- Edits an EXISTING parameter (the console edits, never creates), validating
-- the new value against the row's declared value_type. policy.* is refused.

CREATE OR REPLACE FUNCTION public.admin_update_setting(p_key text, p_value text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	cur      public.app_settings%ROWTYPE;
	me_id    bigint;
	dummy_n  numeric;
	dummy_j  jsonb;
BEGIN
	IF NOT public.is_platform_operator() THEN
		RAISE EXCEPTION 'Acesso restrito à operação da plataforma.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	IF NOT public.is_elevated() THEN
		RAISE EXCEPTION 'ELEVATION_REQUIRED: Confirme sua senha para alterar parâmetros da aplicação.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	-- S-15/B-4: the policy keys move ONLY by migration, in the four-piece
	-- delivery (PolicyVersions.cs + app_settings + ChangeSummary + notice
	-- window). A lone DB edit here could lock the whole user base out.
	IF p_key LIKE 'policy.%' THEN
		RAISE EXCEPTION 'As chaves policy.* só mudam por migração (fluxo S-15) — o console não as edita.'
			USING ERRCODE = 'check_violation';
	END IF;

	SELECT * INTO cur FROM public.app_settings WHERE key = p_key;
	IF NOT FOUND THEN
		RAISE EXCEPTION 'Parâmetro inexistente: %.', p_key
			USING ERRCODE = 'check_violation';
	END IF;

	-- Type validation against the row's declared value_type.
	IF cur.value_type = 'int' AND p_value !~ '^-?[0-9]+$' THEN
		RAISE EXCEPTION 'Valor inválido para o tipo int: %.', p_value
			USING ERRCODE = 'check_violation';
	ELSIF cur.value_type = 'bool' AND lower(p_value) NOT IN ('true', 'false') THEN
		RAISE EXCEPTION 'Valor inválido para o tipo bool: %.', p_value
			USING ERRCODE = 'check_violation';
	ELSIF cur.value_type = 'decimal' THEN
		BEGIN
			dummy_n := p_value::numeric;
		EXCEPTION WHEN OTHERS THEN
			RAISE EXCEPTION 'Valor inválido para o tipo decimal: %.', p_value
				USING ERRCODE = 'check_violation';
		END;
	ELSIF cur.value_type = 'json' THEN
		BEGIN
			dummy_j := p_value::jsonb;
		EXCEPTION WHEN OTHERS THEN
			RAISE EXCEPTION 'Valor inválido para o tipo json: %.', p_value
				USING ERRCODE = 'check_violation';
		END;
	END IF;

	SELECT id INTO me_id FROM public.profiles WHERE user_id = auth.uid();

	UPDATE public.app_settings
	SET value      = p_value,
	    updated_at = timezone('utc', now()),
	    updated_by = me_id
	WHERE key = p_key;

	INSERT INTO public.operator_audit_logs (operator_user_id, action, setting_key, old_value, new_value)
	VALUES (auth.uid(), 'setting_updated', p_key, cur.value, p_value);
END;
$$;

ALTER FUNCTION public.admin_update_setting(text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.admin_update_setting(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_update_setting(text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_update_setting(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_setting(text, text) TO service_role;

-- ── 7. admin_lookup_family ───────────────────────────────────────────────────
-- Support lookup by member e-mail, crossing the family RLS on purpose (that is
-- what SECURITY DEFINER + the operator gate exist for). EVERY call is logged —
-- including misses — because looking up personal data is the audited act, found
-- or not. Returns NULL when no profile matches.

CREATE OR REPLACE FUNCTION public.admin_lookup_family(p_email text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	fam    public.families%ROWTYPE;
	target public.profiles%ROWTYPE;
	result jsonb;
BEGIN
	IF NOT public.is_platform_operator() THEN
		RAISE EXCEPTION 'Acesso restrito à operação da plataforma.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	SELECT * INTO target
	FROM public.profiles
	WHERE lower(email) = lower(trim(p_email))
	ORDER BY (left_at IS NULL) DESC, id
	LIMIT 1;

	INSERT INTO public.operator_audit_logs (operator_user_id, action, family_id, new_value)
	VALUES (auth.uid(), 'family_lookup', target.family_id, lower(trim(p_email)));

	IF target.id IS NULL THEN
		RETURN NULL;
	END IF;

	SELECT * INTO fam FROM public.families WHERE id = target.family_id;

	SELECT jsonb_build_object(
		'family', jsonb_build_object(
			'id',              fam.id,
			'name',            fam.name,
			'plan',            fam.plan,
			'trial_ends_at',   fam.trial_ends_at,
			'comp_premium_at', fam.comp_premium_at,
			'comp_premium_note', fam.comp_premium_note,
			'is_premium',      public.is_premium(fam.id),
			'created_at',      fam.created_at
		),
		'subscription', (
			SELECT jsonb_build_object(
				'status',             s.status,
				'cycle',              s.cycle,
				'price_cents',        s.price_cents,
				'current_period_end', s.current_period_end,
				'overdue_since',      s.overdue_since,
				'canceled_at',        s.canceled_at
			)
			FROM public.subscriptions s WHERE s.family_id = fam.id
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
			FROM public.profiles p WHERE p.family_id = fam.id
		)
	) INTO result;

	RETURN result;
END;
$$;

ALTER FUNCTION public.admin_lookup_family(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.admin_lookup_family(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_lookup_family(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_lookup_family(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_lookup_family(text) TO service_role;

-- ── 8. admin_set_comp ────────────────────────────────────────────────────────
-- Grants/revokes the permanent courtesy Premium. Idempotent (a repeated grant
-- keeps the ORIGINAL timestamp and writes no duplicate audit). The family sees
-- the act in its own account_logs; the operator trail keeps the before/after.

CREATE OR REPLACE FUNCTION public.admin_set_comp(p_family_id bigint, p_granted boolean, p_note text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	fam public.families%ROWTYPE;
BEGIN
	IF NOT public.is_platform_operator() THEN
		RAISE EXCEPTION 'Acesso restrito à operação da plataforma.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	IF NOT public.is_elevated() THEN
		RAISE EXCEPTION 'ELEVATION_REQUIRED: Confirme sua senha para alterar o plano de uma família.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	SELECT * INTO fam FROM public.families WHERE id = p_family_id FOR UPDATE;
	IF NOT FOUND THEN
		RAISE EXCEPTION 'Família não encontrada: %.', p_family_id
			USING ERRCODE = 'check_violation';
	END IF;

	IF p_granted AND fam.comp_premium_at IS NULL THEN
		UPDATE public.families
		SET comp_premium_at = timezone('utc', now()), comp_premium_note = p_note
		WHERE id = p_family_id;

		INSERT INTO public.operator_audit_logs (operator_user_id, action, family_id, old_value, new_value)
		VALUES (auth.uid(), 'comp_granted', p_family_id, NULL, COALESCE(p_note, 'comp'));

		INSERT INTO public.account_logs (family_id, action)
		VALUES (p_family_id, 'comp_premium_granted');

	ELSIF NOT p_granted AND fam.comp_premium_at IS NOT NULL THEN
		UPDATE public.families
		SET comp_premium_at = NULL, comp_premium_note = NULL
		WHERE id = p_family_id;

		INSERT INTO public.operator_audit_logs (operator_user_id, action, family_id, old_value, new_value)
		VALUES (auth.uid(), 'comp_revoked', p_family_id, fam.comp_premium_at::text, NULL);

		INSERT INTO public.account_logs (family_id, action)
		VALUES (p_family_id, 'comp_premium_revoked');
	END IF;
END;
$$;

ALTER FUNCTION public.admin_set_comp(bigint, boolean, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.admin_set_comp(bigint, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_comp(bigint, boolean, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_comp(bigint, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_comp(bigint, boolean, text) TO service_role;
