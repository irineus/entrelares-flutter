-- =============================================================================
-- S-11 (PR1, follow-up) — cross-family migration of a departed caregiver
--
-- Limitation being worked around: 1 e-mail = 1 family. When a caregiver leaves
-- family A (left_at set, 30-day grace, GoTrue user still alive so they can
-- cancel) and is then invited to a DIFFERENT family B, register-invitee's
-- auth.admin.createUser fails with "already registered" — the account still
-- exists. The product decision (July 2026): warn the caregiver that joining B
-- PERMANENTLY erases their family-A registration (no return), and on consent
-- run the definitive deletion NOW (not at grace expiry) before enrolling them
-- in B. True multi-family membership is the future item F-30.
--
-- Two service-role helpers:
--   1. departed_member_family(email)     — the previous family's name, or NULL
--      when there is no departed (left_at-set) member for that e-mail. Powers
--      the UI warning before the destructive step.
--   2. purge_departed_member_by_email(email) — performs the same teardown the
--      grace-expiry cron (purge_expired_accounts) would eventually do for this
--      member, but on demand and immediately: whole-family purge when they were
--      the last active member, otherwise a tombstone scrub. Returns the GoTrue
--      auth uid(s) for the Edge Function to delete so the e-mail frees up.
--
-- Both are service_role only — invoked exclusively by register-invitee, never
-- by a client. The invite token remains the capability that gates who reaches
-- this path (create_invitation already forbids inviting ACTIVE members, so only
-- a genuinely departed member's e-mail can land here).
-- =============================================================================

-- ── 1. departed_member_family — previous family name for the warning ─────────
-- NULL when the e-mail has no departed member (active member, tombstoned, or
-- unknown) — the caller then keeps the plain "already registered" rejection.

CREATE OR REPLACE FUNCTION public.departed_member_family(p_email text)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
	SELECT f.name
	FROM public.profiles p
	JOIN public.families f ON f.id = p.family_id
	WHERE p.email = p_email
	  AND p.left_at IS NOT NULL
	  AND p.user_id IS NOT NULL
	LIMIT 1;
$$;

ALTER FUNCTION public.departed_member_family(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.departed_member_family(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.departed_member_family(text) FROM anon;
REVOKE ALL ON FUNCTION public.departed_member_family(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.departed_member_family(text) TO service_role;

-- ── 2. purge_departed_member_by_email — on-demand definitive erasure ──────────
-- Mirrors purge_expired_accounts' per-member branch exactly (last active member
-- → whole-family purge; others remain → tombstone scrub), but for a single
-- e-mail and without waiting for deletion_scheduled_for. Returns the auth uid(s)
-- the caller must delete from GoTrue. Idempotent: no departed member → no rows.

-- Returns TABLE(auth_uid) — same array-of-objects shape the purge-deleted cron
-- consumes from purge_expired_accounts. The distinct column name avoids the
-- OUT-param / profiles.user_id ambiguity (42702) that bit an earlier migration.

CREATE OR REPLACE FUNCTION public.purge_departed_member_by_email(p_email text)
RETURNS TABLE (auth_uid uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me public.profiles%ROWTYPE;
BEGIN
	SELECT * INTO me
	FROM public.profiles p
	WHERE p.email = p_email
	  AND p.left_at IS NOT NULL
	  AND p.user_id IS NOT NULL
	ORDER BY p.left_at DESC
	LIMIT 1;

	IF me.id IS NULL THEN
		RETURN;   -- nothing to migrate (not a departed member)
	END IF;

	PERFORM set_config('app.deletion_context', 'on', true);

	IF public.active_member_count(me.family_id) = 0 THEN
		-- Last active member had already scheduled the whole family for removal;
		-- bring it forward now (returns every member's auth uid, idempotent).
		RETURN QUERY SELECT u FROM public.purge_family_data(me.family_id) AS u;
	ELSE
		-- Others remain → tombstone this member only (name kept for history);
		-- hand back the uid so the caller deletes the GoTrue user.
		UPDATE public.profiles p
		SET email = 'removido+' || p.id || '@guarda.invalido'
		WHERE p.id = me.id;
		auth_uid := me.user_id;
		RETURN NEXT;
	END IF;
END;
$$;

ALTER FUNCTION public.purge_departed_member_by_email(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purge_departed_member_by_email(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_departed_member_by_email(text) FROM anon;
REVOKE ALL ON FUNCTION public.purge_departed_member_by_email(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.purge_departed_member_by_email(text) TO service_role;
