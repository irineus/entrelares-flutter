-- =============================================================================
-- F-16 — Profile self-service (name/e-mail/password) + admin member editing
-- Guarda Compartilhada — Supabase/PostgreSQL
--
-- 1. profiles.email is a denormalized copy of auth.users.email; the GoTrue
--    "change e-mail" flow (Auth.Update + confirmation link) only touches
--    auth.users. New trigger keeps profiles.email in sync on confirmation.
-- 2. enforce_profile_protection gains a role_id guard: the own-row UPDATE
--    policy let any user change their OWN role directly, bypassing the F-27
--    decision that role changes are admin-only (set_member_role).
-- 3. New RPC update_member_name: admins may fix another member's display
--    name (the RLS own-row policy correctly blocks direct writes). E-mail
--    and password stay PERSONAL (decision of July 2026): letting an admin
--    change the other parent's login e-mail would enable account takeover.
-- =============================================================================

-- ── 1. Keep profiles.email in sync with auth.users.email ────────────────────

CREATE OR REPLACE FUNCTION public.sync_profile_email()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
	UPDATE public.profiles SET email = NEW.email WHERE user_id = NEW.id;
	RETURN NEW;
END;
$$;

ALTER FUNCTION public.sync_profile_email() OWNER TO postgres;

DROP TRIGGER IF EXISTS trigger_sync_profile_email ON auth.users;
CREATE TRIGGER trigger_sync_profile_email
	AFTER UPDATE OF email ON auth.users
	FOR EACH ROW
	WHEN (OLD.email IS DISTINCT FROM NEW.email)
	EXECUTE FUNCTION public.sync_profile_email();

-- ── 2. enforce_profile_protection: add the role_id guard ────────────────────
-- Body verbatim from the baseline except the new role_id block.

CREATE OR REPLACE FUNCTION public.enforce_profile_protection()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
	actor_admin  boolean;
	actor_family bigint;
BEGIN
	-- System context (service_role / migrations): unrestricted.
	IF auth.uid() IS NULL THEN
		RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
	END IF;

	SELECT is_admin, family_id INTO actor_admin, actor_family
	FROM public.profiles WHERE user_id = auth.uid();

	IF TG_OP = 'UPDATE' THEN
		IF NEW.family_id IS DISTINCT FROM OLD.family_id THEN
			RAISE EXCEPTION 'A família de um perfil não pode ser alterada.'
				USING ERRCODE = 'check_violation';
		END IF;

		IF NEW.is_admin IS DISTINCT FROM OLD.is_admin THEN
			-- Blocks self-promotion through the profiles_own_update policy.
			IF COALESCE(actor_admin, false) = false OR actor_family IS DISTINCT FROM OLD.family_id THEN
				RAISE EXCEPTION 'Somente administradores da família podem alterar permissões de administrador.'
					USING ERRCODE = 'check_violation';
			END IF;

			-- Demotion: keep the >= 1 admin per family invariant.
			IF OLD.is_admin AND NOT NEW.is_admin AND NOT EXISTS (
				SELECT 1 FROM public.profiles
				WHERE family_id = OLD.family_id AND is_admin AND id <> OLD.id
			) THEN
				RAISE EXCEPTION 'A família precisa de pelo menos uma pessoa administradora.'
					USING ERRCODE = 'check_violation';
			END IF;
		END IF;

		-- F-16/F-27: role changes are admin-only (set_member_role) — the
		-- own-row UPDATE policy must not be a side door for self role edits.
		IF NEW.role_id IS DISTINCT FROM OLD.role_id THEN
			IF COALESCE(actor_admin, false) = false OR actor_family IS DISTINCT FROM OLD.family_id THEN
				RAISE EXCEPTION 'Somente administradores da família podem alterar papéis.'
					USING ERRCODE = 'check_violation';
			END IF;
		END IF;

		RETURN NEW;
	END IF;

	-- DELETE: never remove the last admin of a family.
	IF OLD.is_admin AND NOT EXISTS (
		SELECT 1 FROM public.profiles
		WHERE family_id = OLD.family_id AND is_admin AND id <> OLD.id
	) THEN
		RAISE EXCEPTION 'A família precisa de pelo menos uma pessoa administradora.'
			USING ERRCODE = 'check_violation';
	END IF;
	RETURN OLD;
END;
$$;

-- ── 3. update_member_name: admin fixes another member's display name ────────

CREATE OR REPLACE FUNCTION public.update_member_name(p_profile_id bigint, p_full_name text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me public.profiles%ROWTYPE;
	clean_name text;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();

	IF me.id IS NULL OR NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores da família podem alterar dados de outros membros.'
			USING ERRCODE = 'check_violation';
	END IF;

	clean_name := trim(p_full_name);
	IF clean_name IS NULL OR length(clean_name) < 2 OR length(clean_name) > 80 THEN
		RAISE EXCEPTION 'Informe um nome entre 2 e 80 caracteres.'
			USING ERRCODE = 'check_violation';
	END IF;

	UPDATE public.profiles
	SET full_name = clean_name
	WHERE id = p_profile_id AND family_id = me.family_id;

	IF NOT FOUND THEN
		RAISE EXCEPTION 'Perfil não encontrado na sua família.'
			USING ERRCODE = 'check_violation';
	END IF;
END;
$$;

ALTER FUNCTION public.update_member_name(bigint, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.update_member_name(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_member_name(bigint, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_member_name(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_member_name(bigint, text) TO service_role;
