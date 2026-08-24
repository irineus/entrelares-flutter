-- =============================================================================
-- S-10 — Re-authentication layer ("sudo mode") + account-operations audit trail
-- Guarda Compartilhada — Supabase/PostgreSQL
--
-- Threat model: a co-parent (or anyone) holding an unlocked signed-in device,
-- and secondarily a stolen session token. The calendar already has two-party
-- consent; the ACCOUNT layer trusted any open session completely.
--
--   1. auth_elevations — one row per user; the `elevate` Edge Function
--      (service role) upserts elevated_until = now + 5 min after verifying
--      the CURRENT password against GoTrue. RLS: user reads own row only;
--      authenticated cannot write (service role only).
--   2. is_elevated() — SECURITY DEFINER helper checked INSIDE sensitive RPCs,
--      so a stolen token cannot operate without the password (server-side
--      enforcement, not UI theater).
--   3. set_member_admin — now requires an active elevation. Raises a
--      detectable 'ELEVATION_REQUIRED:' error so the client opens the
--      password prompt and retries. (Body otherwise verbatim from baseline;
--      the >= 1 admin invariant stays in enforce_profile_protection.)
--   4. account_logs — append-only audit of account operations, family-scoped
--      SELECT, written only from SECURITY DEFINER trigger functions/RPCs.
--      Separate from activity_logs on purpose: that table is calendar-shaped
--      (schedule_id, affected_date).
--   5. Audit triggers: profiles (is_admin / role_id / full_name / email —
--      the latter also captures the GoTrue-driven sync_profile_email update),
--      families (name), family_invitations (created / revoked / accepted).
--   6. log_account_action() — client-callable logging for self-actions that
--      have no other DB footprint, restricted by a whitelist
--      (password_changed, email_change_requested, data_exported).
--
-- purge_e2e_family needs NO change: account_logs.family_id cascades on the
-- final families delete, profile FKs are SET NULL (profiles go first), and
-- auth_elevations cascades when the Admin API deletes auth.users.
-- =============================================================================

-- ── 1. auth_elevations ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.auth_elevations (
	user_id        uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
	elevated_until timestamp with time zone NOT NULL,
	created_at     timestamp with time zone DEFAULT timezone('utc', now()) NOT NULL
);

ALTER TABLE public.auth_elevations OWNER TO postgres;
ALTER TABLE public.auth_elevations ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.auth_elevations FROM PUBLIC;
REVOKE ALL ON TABLE public.auth_elevations FROM anon;
REVOKE ALL ON TABLE public.auth_elevations FROM authenticated;
GRANT SELECT ON TABLE public.auth_elevations TO authenticated;
GRANT ALL    ON TABLE public.auth_elevations TO service_role;

CREATE POLICY auth_elevations_own_read ON public.auth_elevations
	FOR SELECT TO authenticated
	USING (user_id = auth.uid());

-- ── 2. is_elevated() ─────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.is_elevated()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
	SELECT EXISTS (
		SELECT 1 FROM public.auth_elevations
		WHERE user_id = auth.uid()
		  AND elevated_until > timezone('utc', now())
	);
$$;

ALTER FUNCTION public.is_elevated() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.is_elevated() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_elevated() FROM anon;
GRANT EXECUTE ON FUNCTION public.is_elevated() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_elevated() TO service_role;

-- ── 3. set_member_admin: elevation gate ──────────────────────────────────────
-- Body verbatim from the baseline except the is_elevated() check. The
-- 'ELEVATION_REQUIRED:' prefix is the client contract — FamilyService detects
-- it and opens the sudo prompt instead of showing an error.

CREATE OR REPLACE FUNCTION public.set_member_admin(p_profile_id bigint, p_is_admin boolean)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me public.profiles%ROWTYPE;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();

	IF me.id IS NULL OR NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores da família podem alterar permissões.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- S-10: admin grants/revokes require a fresh password confirmation.
	IF NOT public.is_elevated() THEN
		RAISE EXCEPTION 'ELEVATION_REQUIRED: Confirme sua senha para alterar permissões de administrador.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	UPDATE public.profiles
	SET is_admin = p_is_admin
	WHERE id = p_profile_id AND family_id = me.family_id;

	IF NOT FOUND THEN
		RAISE EXCEPTION 'Perfil não encontrado na sua família.'
			USING ERRCODE = 'check_violation';
	END IF;
END;
$$;

-- ── 4. account_logs ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.account_logs (
	id                bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
	family_id         bigint NOT NULL REFERENCES public.families (id) ON DELETE CASCADE,
	actor_profile_id  bigint REFERENCES public.profiles (id) ON DELETE SET NULL,
	target_profile_id bigint REFERENCES public.profiles (id) ON DELETE SET NULL,
	action            text NOT NULL,
	old_value         text,
	new_value         text,
	created_at        timestamp with time zone DEFAULT timezone('utc', now()) NOT NULL
);

CREATE INDEX IF NOT EXISTS account_logs_family_created_idx
	ON public.account_logs (family_id, created_at DESC);

ALTER TABLE public.account_logs OWNER TO postgres;
ALTER TABLE public.account_logs ENABLE ROW LEVEL SECURITY;

-- Append-only: authenticated may only SELECT (family-scoped); every write
-- happens inside SECURITY DEFINER functions owned by postgres.
REVOKE ALL ON TABLE public.account_logs FROM PUBLIC;
REVOKE ALL ON TABLE public.account_logs FROM anon;
REVOKE ALL ON TABLE public.account_logs FROM authenticated;
GRANT SELECT ON TABLE public.account_logs TO authenticated;
GRANT ALL    ON TABLE public.account_logs TO service_role;

CREATE POLICY account_logs_family_read ON public.account_logs
	FOR SELECT TO authenticated
	USING (family_id = public.get_my_family_id());

-- ── 5. Audit triggers ────────────────────────────────────────────────────────

-- profiles: admin flag, role, display name, e-mail (the e-mail UPDATE arrives
-- via sync_profile_email in a GoTrue context where auth.uid() is NULL — the
-- change is always self-service, so the actor falls back to the profile
-- itself there).
CREATE OR REPLACE FUNCTION public.audit_profile_account_changes()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	actor bigint;
BEGIN
	SELECT id INTO actor FROM public.profiles WHERE user_id = auth.uid();

	IF NEW.is_admin IS DISTINCT FROM OLD.is_admin THEN
		INSERT INTO public.account_logs (family_id, actor_profile_id, target_profile_id, action, old_value, new_value)
		VALUES (OLD.family_id, actor, OLD.id,
		        CASE WHEN NEW.is_admin THEN 'admin_granted' ELSE 'admin_revoked' END,
		        OLD.is_admin::text, NEW.is_admin::text);
	END IF;

	IF NEW.role_id IS DISTINCT FROM OLD.role_id THEN
		INSERT INTO public.account_logs (family_id, actor_profile_id, target_profile_id, action, old_value, new_value)
		VALUES (OLD.family_id, actor, OLD.id, 'role_changed',
		        (SELECT role FROM public.roles WHERE id = OLD.role_id),
		        (SELECT role FROM public.roles WHERE id = NEW.role_id));
	END IF;

	IF NEW.full_name IS DISTINCT FROM OLD.full_name THEN
		INSERT INTO public.account_logs (family_id, actor_profile_id, target_profile_id, action, old_value, new_value)
		VALUES (OLD.family_id, actor, OLD.id, 'name_changed', OLD.full_name, NEW.full_name);
	END IF;

	IF NEW.email IS DISTINCT FROM OLD.email THEN
		INSERT INTO public.account_logs (family_id, actor_profile_id, target_profile_id, action, old_value, new_value)
		VALUES (OLD.family_id, COALESCE(actor, OLD.id), OLD.id, 'email_changed', OLD.email, NEW.email);
	END IF;

	RETURN NEW;
END;
$$;

ALTER FUNCTION public.audit_profile_account_changes() OWNER TO postgres;

DROP TRIGGER IF EXISTS trigger_audit_profile_account ON public.profiles;
CREATE TRIGGER trigger_audit_profile_account
	AFTER UPDATE ON public.profiles
	FOR EACH ROW
	EXECUTE FUNCTION public.audit_profile_account_changes();

-- families: rename.
CREATE OR REPLACE FUNCTION public.audit_family_rename()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	actor bigint;
BEGIN
	SELECT id INTO actor FROM public.profiles WHERE user_id = auth.uid();

	INSERT INTO public.account_logs (family_id, actor_profile_id, action, old_value, new_value)
	VALUES (OLD.id, actor, 'family_renamed', OLD.name, NEW.name);

	RETURN NEW;
END;
$$;

ALTER FUNCTION public.audit_family_rename() OWNER TO postgres;

DROP TRIGGER IF EXISTS trigger_audit_family_rename ON public.families;
CREATE TRIGGER trigger_audit_family_rename
	AFTER UPDATE OF name ON public.families
	FOR EACH ROW
	WHEN (OLD.name IS DISTINCT FROM NEW.name)
	EXECUTE FUNCTION public.audit_family_rename();

-- family_invitations: creation, revocation and acceptance. Acceptance runs
-- inside handle_new_user BEFORE the invitee's profile exists, so the target
-- stays NULL and the e-mail identifies the invitee.
CREATE OR REPLACE FUNCTION public.audit_invitation_changes()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	actor bigint;
BEGIN
	SELECT id INTO actor FROM public.profiles WHERE user_id = auth.uid();

	IF TG_OP = 'INSERT' THEN
		INSERT INTO public.account_logs (family_id, actor_profile_id, action, new_value)
		VALUES (NEW.family_id, COALESCE(actor, NEW.invited_by), 'invitation_created', NEW.email);
		RETURN NEW;
	END IF;

	IF NEW.revoked_at IS NOT NULL AND OLD.revoked_at IS NULL THEN
		INSERT INTO public.account_logs (family_id, actor_profile_id, action, new_value)
		VALUES (NEW.family_id, actor, 'invitation_revoked', NEW.email);
	END IF;

	IF NEW.accepted_at IS NOT NULL AND OLD.accepted_at IS NULL THEN
		INSERT INTO public.account_logs (family_id, actor_profile_id, action, new_value)
		VALUES (NEW.family_id, actor, 'invitation_accepted', NEW.email);
	END IF;

	RETURN NEW;
END;
$$;

ALTER FUNCTION public.audit_invitation_changes() OWNER TO postgres;

DROP TRIGGER IF EXISTS trigger_audit_invitation ON public.family_invitations;
CREATE TRIGGER trigger_audit_invitation
	AFTER INSERT OR UPDATE ON public.family_invitations
	FOR EACH ROW
	EXECUTE FUNCTION public.audit_invitation_changes();

-- ── 6. log_account_action ────────────────────────────────────────────────────
-- Self-actions with no other DB footprint. The whitelist keeps this endpoint
-- from being used to forge arbitrary audit entries; actor = target = caller,
-- always, so at worst a user pollutes their OWN trail with true action names.

CREATE OR REPLACE FUNCTION public.log_account_action(p_action text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me public.profiles%ROWTYPE;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();

	IF me.id IS NULL THEN
		RAISE EXCEPTION 'Perfil não encontrado.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF p_action NOT IN ('password_changed', 'email_change_requested', 'data_exported') THEN
		RAISE EXCEPTION 'Ação de auditoria não permitida.'
			USING ERRCODE = 'check_violation';
	END IF;

	INSERT INTO public.account_logs (family_id, actor_profile_id, target_profile_id, action)
	VALUES (me.family_id, me.id, me.id, p_action);
END;
$$;

ALTER FUNCTION public.log_account_action(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.log_account_action(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_account_action(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.log_account_action(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_account_action(text) TO service_role;
