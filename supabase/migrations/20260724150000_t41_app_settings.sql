-- =============================================================================
-- T-41 — Central application configuration table (operational parameters)
--
-- A general key/value store for app-wide operational parameters — NOT limited to
-- freemium limits. First parameters: the free/premium e-mail caps (F-38) and the
-- free/premium calendar horizons (F-39); designed to hold anything later (other
-- limits, retention windows, behaviour flags, …).
--
-- SECURITY MODEL (important):
--   · The client only READS (for UX); the DATABASE ENFORCES. A tampered client
--     that reads a different value gains nothing — every real limit is enforced
--     server-side (SECURITY DEFINER functions / triggers read the true value).
--   · Writes are service_role ONLY (no INSERT/UPDATE/DELETE for authenticated).
--   · Reads: authenticated may SELECT only rows flagged `is_public` (e.g. the
--     calendar horizons the calendar UI mirrors). Non-public rows (e.g. e-mail
--     caps) are never exposed to clients.
--   · The typed accessor `setting_int(...)` is SECURITY DEFINER and is granted to
--     service_role ONLY — never to authenticated — so it cannot be used to read
--     a non-public value around RLS. Server DEFINER functions (owned by postgres)
--     can still call it.
-- =============================================================================

-- ── 1. The table ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.app_settings (
	key         text PRIMARY KEY,
	value       text NOT NULL,
	value_type  text NOT NULL DEFAULT 'string'
	            CHECK (value_type IN ('int', 'decimal', 'bool', 'string', 'json')),
	category    text NOT NULL DEFAULT 'general',
	description text,
	is_public   boolean NOT NULL DEFAULT false,   -- readable by authenticated clients
	updated_at  timestamp with time zone NOT NULL DEFAULT timezone('utc', now()),
	updated_by  bigint REFERENCES public.profiles (id)
);

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;

-- Public rows are readable by any authenticated user (UX mirror only); writes are
-- service_role only (no authenticated write policy exists, so all writes are denied).
CREATE POLICY app_settings_public_read ON public.app_settings
	FOR SELECT TO authenticated
	USING (is_public);

GRANT SELECT ON public.app_settings TO authenticated;
GRANT ALL    ON public.app_settings TO service_role;

-- ── 2. Typed accessors (server-side, with a hardcoded fallback) ──────────────
-- SECURITY DEFINER so the server gate functions read the true value regardless of
-- RLS. NOT granted to authenticated (that would leak non-public values); the
-- client reads the public rows straight from the table instead.

CREATE OR REPLACE FUNCTION public.setting_int(p_key text, p_default int)
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
	SELECT COALESCE((SELECT value::int FROM public.app_settings WHERE key = p_key), p_default);
$$;

CREATE OR REPLACE FUNCTION public.setting_text(p_key text, p_default text)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
	SELECT COALESCE((SELECT value FROM public.app_settings WHERE key = p_key), p_default);
$$;

CREATE OR REPLACE FUNCTION public.setting_bool(p_key text, p_default boolean)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
	SELECT COALESCE((SELECT value::boolean FROM public.app_settings WHERE key = p_key), p_default);
$$;

ALTER FUNCTION public.setting_int(text, int)      OWNER TO postgres;
ALTER FUNCTION public.setting_text(text, text)    OWNER TO postgres;
ALTER FUNCTION public.setting_bool(text, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.setting_int(text, int)      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.setting_text(text, text)    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.setting_bool(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.setting_int(text, int)      TO service_role;
GRANT EXECUTE ON FUNCTION public.setting_text(text, text)    TO service_role;
GRANT EXECUTE ON FUNCTION public.setting_bool(text, boolean) TO service_role;

-- ── 3. Seed the first parameters ─────────────────────────────────────────────
-- email caps: NOT public (server-only). calendar horizons: public (the calendar
-- UI mirrors them — enforcement still happens in enforce_day_protection).

INSERT INTO public.app_settings (key, value, value_type, category, description, is_public) VALUES
	('email_cap_free',          '100',   'int', 'freemium', 'E-mails transacionais por família por mês — plano gratuito.', false),
	('email_cap_premium',       '10000', 'int', 'freemium', 'E-mails transacionais por família por mês — plano premium (cap alto, anti-abuso; nada é ilimitado).', false),
	('calendar_months_free',    '6',     'int', 'freemium', 'Meses de calendário à frente que o plano gratuito pode planejar.', true),
	('calendar_months_premium', '24',    'int', 'freemium', 'Meses de calendário à frente do plano premium (também o teto rígido para todos).', true),
	('free_caregivers',         '2',     'int', 'freemium', 'Cuidadores ativos incluídos no plano gratuito (o núcleo do casal).', true),
	('max_caregivers',          '4',     'int', 'freemium', 'Teto absoluto de cuidadores por família (paleta de cores de 4 membros).', true)
ON CONFLICT (key) DO NOTHING;

-- ── 4. F-39 refactor — enforce_day_protection reads the horizons from settings ─
-- Body copied VERBATIM from 20260724140000; ONLY the horizon_months computation
-- now reads calendar_months_free / calendar_months_premium (defaults preserved as
-- the safety net if a key is ever missing).

CREATE OR REPLACE FUNCTION public.enforce_day_protection()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
	cur_profile_id bigint;
	cur_is_admin   boolean := false;
	today          date;
	the_date       date;
	fam            bigint;
	is_frozen      boolean := false;
	is_target      boolean := false;
	horizon_months int;
BEGIN
	-- S-11: controlled erasure cleanup — see 20260719120000.
	IF current_setting('app.deletion_context', true) = 'on' THEN
		RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
	END IF;

	-- System context (service_role: F-24 auto-approval, migrations): unrestricted.
	SELECT id, is_admin INTO cur_profile_id, cur_is_admin
	FROM public.profiles WHERE user_id = auth.uid();
	IF cur_profile_id IS NULL THEN
		RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
	END IF;

	-- S-11: a departed member (left_at set) cannot be NEWLY assigned to a day,
	-- as the planned or the real parent. Past history keeps their name — only a
	-- CHANGE that puts a departed member on a day is blocked.
	IF TG_OP IN ('INSERT', 'UPDATE') THEN
		IF (TG_OP = 'INSERT' OR NEW.scheduled_parent_id IS DISTINCT FROM OLD.scheduled_parent_id)
		   AND EXISTS (SELECT 1 FROM public.profiles
		               WHERE id = NEW.scheduled_parent_id AND left_at IS NOT NULL) THEN
			RAISE EXCEPTION 'Não é possível atribuir dias a um responsável que saiu da família.'
				USING ERRCODE = 'check_violation';
		END IF;
		IF NEW.actual_parent_id IS NOT NULL
		   AND (TG_OP = 'INSERT' OR NEW.actual_parent_id IS DISTINCT FROM OLD.actual_parent_id)
		   AND EXISTS (SELECT 1 FROM public.profiles
		               WHERE id = NEW.actual_parent_id AND left_at IS NOT NULL) THEN
			RAISE EXCEPTION 'Não é possível atribuir dias a um responsável que saiu da família.'
				USING ERRCODE = 'check_violation';
		END IF;
	END IF;

	today    := (now() AT TIME ZONE 'America/Sao_Paulo')::date;
	the_date := COALESCE(NEW.schedule_date, OLD.schedule_date);
	fam      := COALESCE(NEW.family_id, OLD.family_id,
	                     (SELECT family_id FROM public.profiles WHERE id = NEW.scheduled_parent_id));

	-- F-39 (T-41: horizons now come from app_settings; defaults are the safety net).
	-- Free plans up to N months ahead; premium up to M, the hard ceiling for all
	-- (a cost/monetization gate, not admin-bypassable; only the service/system
	-- context above is exempt). Grandfather: only NEW far-future writes are blocked
	-- — an INSERT, or an UPDATE that moves a day further out; DELETEs and edits to
	-- an existing far-future row pass through.
	IF the_date > today
	   AND (TG_OP = 'INSERT'
	        OR (TG_OP = 'UPDATE' AND NEW.schedule_date IS DISTINCT FROM OLD.schedule_date)) THEN
		horizon_months := CASE WHEN public.is_premium(fam)
		                       THEN public.setting_int('calendar_months_premium', 24)
		                       ELSE public.setting_int('calendar_months_free', 6) END;
		IF the_date > (today + make_interval(months => horizon_months))::date THEN
			IF public.is_premium(fam) THEN
				RAISE EXCEPTION 'O calendário permite agendar no máximo % meses à frente.', horizon_months
					USING ERRCODE = 'check_violation';
			ELSE
				RAISE EXCEPTION 'O plano gratuito permite agendar até % meses à frente. Ative o Premium para planejar mais longe.', horizon_months
					USING ERRCODE = 'check_violation';
			END IF;
		END IF;
	END IF;

	SELECT bool_or(true), bool_or(target_profile_id = cur_profile_id)
	INTO is_frozen, is_target
	FROM public.swap_requests
	WHERE family_id = fam AND schedule_date = the_date
	  AND status IN ('pending', 'revert_pending');
	is_frozen := COALESCE(is_frozen, false);
	is_target := COALESCE(is_target, false);

	-- F-12: frozen days are untouchable, except by the pending request's target
	-- (who legitimately applies the calendar change while approving) or an admin.
	IF TG_OP IN ('UPDATE', 'DELETE') AND is_frozen AND NOT is_target AND NOT cur_is_admin THEN
		RAISE EXCEPTION 'Este dia tem uma solicitação pendente e não pode ser alterado.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- F-13: past days are immutable (the target exemption keeps overdue
	-- workflow completions working; admins may bypass — F-14).
	IF the_date < today AND NOT cur_is_admin AND NOT is_target THEN
		RAISE EXCEPTION 'Dias passados não podem ser alterados.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- S-09: the PLANNED schedule is immutable for regular users — changing the
	-- scheduled parent of an assigned day requires an admin (explicit, audited)
	-- or the pending revert's target restoring the pre-edit snapshot (F-26).
	-- Responsibility changes for a day belong to the swap workflow (actual).
	IF TG_OP = 'UPDATE'
	   AND NEW.scheduled_parent_id IS DISTINCT FROM OLD.scheduled_parent_id
	   AND NOT cur_is_admin AND NOT is_target THEN
		RAISE EXCEPTION 'O responsável planejado só pode ser alterado por administradores; para mudar quem fica com a criança, use o fluxo de troca.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF TG_OP = 'DELETE' THEN
		-- F-12: a day with an approved swap cannot be deleted (admin may — F-14).
		IF OLD.actual_parent_id IS NOT NULL AND OLD.actual_parent_id <> OLD.scheduled_parent_id
		   AND NOT cur_is_admin AND NOT is_target THEN
			RAISE EXCEPTION 'Dias com troca aprovada não podem ser apagados.'
				USING ERRCODE = 'check_violation';
		END IF;
		-- QA (July 2026): clearing an assigned day is admin-only — otherwise a
		-- regular member deletes + recreates the day with anyone, bypassing the
		-- S-09 planned-parent rule. The workflow target keeps its exemption.
		IF NOT cur_is_admin AND NOT is_target THEN
			RAISE EXCEPTION 'Um dia já planejado só pode ser limpo por um administrador.'
				USING ERRCODE = 'check_violation';
		END IF;
		RETURN OLD;
	END IF;

	-- Swap-workflow enforcement (applies to admins too — F-14 decision):
	-- creating or undoing a swap directly is forbidden; only the pending
	-- request's target (applying an approval) may write such a change.
	-- Exception: admins may correct the actual parent of PAST days (historical
	-- fixes — the workflow cannot exist for past dates), never future ones.
	IF cur_is_admin AND the_date < today THEN
		RETURN NEW;
	END IF;

	IF TG_OP = 'INSERT' THEN
		IF NEW.actual_parent_id IS NOT NULL AND NEW.actual_parent_id <> NEW.scheduled_parent_id THEN
			RAISE EXCEPTION 'Alterações do responsável real devem passar pelo fluxo de aprovação.'
				USING ERRCODE = 'check_violation';
		END IF;
	ELSIF NEW.actual_parent_id IS DISTINCT FROM OLD.actual_parent_id AND NOT is_target THEN
		IF (OLD.actual_parent_id IS NOT NULL AND OLD.actual_parent_id <> OLD.scheduled_parent_id)  -- undo/alter an approved swap
		   OR (NEW.actual_parent_id IS NOT NULL AND NEW.actual_parent_id <> NEW.scheduled_parent_id) -- create a swap directly
		THEN
			RAISE EXCEPTION 'Alterações do responsável real devem passar pelo fluxo de aprovação.'
				USING ERRCODE = 'check_violation';
		END IF;
	END IF;

	RETURN NEW;
END;
$$;

-- ── 5. F-37 refactor — create_invitation reads the caregiver limits from settings ─
-- Body copied VERBATIM from 20260724120000; ONLY the free/max caregiver counts now
-- come from free_caregivers / max_caregivers (defaults preserved as the safety net).

CREATE OR REPLACE FUNCTION public.create_invitation(p_email text, p_role_id bigint)
RETURNS TABLE (invitation_id bigint, token uuid, expires_at timestamp with time zone)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
	me         public.profiles%ROWTYPE;
	inv        public.family_invitations%ROWTYPE;
	max_seats  int := public.setting_int('max_caregivers', 4);
	free_seats int := public.setting_int('free_caregivers', 2);
	taken      int;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();

	IF me.id IS NULL OR NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores da família podem enviar convites.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF EXISTS (SELECT 1 FROM public.family_deletion_requests
	           WHERE family_id = me.family_id AND status = 'pending') THEN
		RAISE EXCEPTION 'Há uma solicitação de exclusão da família em andamento — convites ficam bloqueados até ela ser resolvida.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF EXISTS (SELECT 1 FROM public.profiles
	           WHERE lower(email) = lower(trim(p_email))
	             AND user_id IS NOT NULL AND left_at IS NULL) THEN
		RAISE EXCEPTION 'Este e-mail já possui cadastro no aplicativo.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF NOT EXISTS (SELECT 1 FROM public.roles WHERE id = p_role_id) THEN
		RAISE EXCEPTION 'Papel inválido.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- Resend semantics: revoke this e-mail's previous open invitation BEFORE
	-- counting seats, so a resend never trips the cap it already occupies.
	UPDATE public.family_invitations
	SET revoked_at = timezone('utc', now())
	WHERE family_id = me.family_id
	  AND lower(email) = lower(trim(p_email))
	  AND accepted_at IS NULL AND revoked_at IS NULL;

	-- Seats taken = ACTIVE members + open (pending, unexpired) invitations.
	SELECT public.active_member_count(me.family_id)
	     + (SELECT count(*) FROM public.family_invitations fi
	        WHERE fi.family_id = me.family_id
	          AND fi.accepted_at IS NULL AND fi.revoked_at IS NULL
	          AND fi.expires_at > timezone('utc', now()))
	INTO taken;

	-- F-37 (T-41: free_caregivers from settings) — the free tier includes N
	-- caregivers; adding beyond that is Premium. Add-only + grandfather (F-32).
	IF taken >= free_seats AND NOT public.is_premium(me.family_id) THEN
		RAISE EXCEPTION 'Famílias no plano gratuito incluem % responsáveis. Para adicionar mais (avós, babá, etc.), ative o Premium.', free_seats
			USING ERRCODE = 'check_violation';
	END IF;

	IF taken >= max_seats THEN
		RAISE EXCEPTION 'Esta família já atingiu o limite de % responsáveis (contando convites pendentes).', max_seats
			USING ERRCODE = 'check_violation';
	END IF;

	INSERT INTO public.family_invitations (family_id, email, role_id, invited_by)
	VALUES (me.family_id, lower(trim(p_email)), p_role_id, me.id)
	RETURNING * INTO inv;

	RETURN QUERY SELECT inv.id, inv.token, inv.expires_at;
END;
$$;

-- ── 6. F-37 refactor — handle_new_user reads the caregiver limits from settings ──
-- Body copied VERBATIM from 20260724120000; ONLY the free/max caregiver counts now
-- come from free_caregivers / max_caregivers (defaults preserved as the safety net).

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	meta_name    text;
	meta_role    text;
	meta_token   text;
	meta_family  text;
	meta_policy  text;
	inv          public.family_invitations%ROWTYPE;
	fam_id       bigint;
	new_role_id  bigint;
	admin_flag   boolean;
	max_seats    int := public.setting_int('max_caregivers', 4);
	free_seats   int := public.setting_int('free_caregivers', 2);
BEGIN
	-- Idempotency: never duplicate a profile (e.g. trigger re-run).
	IF EXISTS (SELECT 1 FROM public.profiles WHERE user_id = NEW.id) THEN
		RETURN NEW;
	END IF;

	meta_name   := NULLIF(trim(NEW.raw_user_meta_data ->> 'full_name'), '');
	meta_role   := NULLIF(trim(NEW.raw_user_meta_data ->> 'role'), '');
	meta_token  := NULLIF(trim(NEW.raw_user_meta_data ->> 'invite_token'), '');
	meta_family := NULLIF(trim(NEW.raw_user_meta_data ->> 'family_name'), '');
	meta_policy := NULLIF(trim(NEW.raw_user_meta_data ->> 'policy_version'), '');

	-- Fallback: e-mail local part (metadata should always carry the name).
	IF meta_name IS NULL THEN
		meta_name := split_part(NEW.email, '@', 1);
	END IF;

	IF meta_token IS NOT NULL THEN
		-- INVITEE: token must be valid, pending and issued for this e-mail.
		-- (a malformed token must fail with the friendly message, not a cast error)
		BEGIN
			SELECT * INTO inv
			FROM public.family_invitations
			WHERE token = meta_token::uuid
			  AND accepted_at IS NULL
			  AND revoked_at  IS NULL
			  AND expires_at  > timezone('utc', now())
			  AND lower(email) = lower(NEW.email);
		EXCEPTION WHEN invalid_text_representation THEN
			inv := NULL;
		END;

		IF inv.id IS NULL THEN
			RAISE EXCEPTION 'Convite inválido, expirado ou emitido para outro e-mail.'
				USING ERRCODE = 'check_violation';
		END IF;

		-- The family may have completed meanwhile (parallel invites racing).
		IF public.active_member_count(inv.family_id) >= max_seats THEN
			RAISE EXCEPTION 'Esta família já atingiu o limite de % responsáveis.', max_seats
				USING ERRCODE = 'check_violation';
		END IF;

		-- F-37 (T-41: free_caregivers from settings) backstop — a caregiver beyond
		-- the free tier joining a free family needs Premium. Primary guard is
		-- create_invitation; this covers the trial-expired / parallel-invite race.
		IF public.active_member_count(inv.family_id) >= free_seats
		   AND NOT public.is_premium(inv.family_id) THEN
			RAISE EXCEPTION 'Esta família já atingiu o limite de % responsáveis do plano gratuito. Peça ao administrador para ativar o Premium e liberar novos cuidadores.', free_seats
				USING ERRCODE = 'check_violation';
		END IF;

		fam_id      := inv.family_id;
		new_role_id := inv.role_id;
		admin_flag  := false;

		UPDATE public.family_invitations
		SET accepted_at = timezone('utc', now())
		WHERE id = inv.id;
	ELSE
		-- FOUNDER: creates the family and becomes its admin (F-14 decision).
		IF meta_role IS NULL THEN
			RAISE EXCEPTION 'Selecione o seu papel para criar a conta.'
				USING ERRCODE = 'check_violation';
		END IF;

		-- F-27: catalog-driven lookup — the client sends the canonical slug;
		-- the PT-BR label is accepted as a fallback vocabulary.
		SELECT id INTO new_role_id
		FROM public.roles
		WHERE lower(trim(role)) = lower(meta_role)
		   OR lower(trim(label_pt)) = lower(meta_role)
		ORDER BY id
		LIMIT 1;
		IF new_role_id IS NULL THEN
			RAISE EXCEPTION 'Papel inválido: %.', meta_role
				USING ERRCODE = 'check_violation';
		END IF;

		-- Family name chosen by the founder; neutral fallback for safety
		-- (the register form makes the field required).
		INSERT INTO public.families (name)
		VALUES (COALESCE(meta_family, 'Família ' || meta_name))
		RETURNING id INTO fam_id;

		admin_flag := true;
	END IF;

	-- S-11 QA: the color slot is assigned at join and belongs to the person —
	-- founder = 1; invitee = lowest slot free among the ACTIVE members (which
	-- naturally reuses a departed member's freed color).
	-- S-13: the LGPD consent (checkbox gated sign-up) is recorded with the
	-- policy version accepted, so it is demonstrable later (art. 8 §1).
	INSERT INTO public.profiles (user_id, full_name, role_id, email, family_id, is_admin, color_slot,
	                             consent_accepted_at, consent_policy_version)
	VALUES (NEW.id, meta_name, new_role_id, NEW.email, fam_id, admin_flag,
	        CASE WHEN admin_flag THEN 1 ELSE public.next_free_color_slot(fam_id) END,
	        CASE WHEN meta_policy IS NOT NULL THEN timezone('utc', now()) END,
	        meta_policy);

	RETURN NEW;
END;
$$;
