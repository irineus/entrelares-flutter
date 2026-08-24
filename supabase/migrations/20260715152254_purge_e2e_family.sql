-- =============================================================================
-- T-30 — purge_e2e_family: cleanup primitive for the automated test suite
-- Guarda Compartilhada — Supabase/PostgreSQL
--
-- The integration/E2E suite runs against the REAL dev project: every run
-- creates its own throwaway family (RLS keeps it invisible to real users)
-- and purges it afterwards — in the teardown AND in a pre-run sweep that
-- catches leftovers from crashed runs.
--
-- Safety model:
--   · Callable by service_role ONLY (revoked from authenticated/anon).
--   · The E2E DOUBLE SIGNATURE is validated INSIDE the function — the family
--     name must start with 'E2E-' AND every member e-mail must end with
--     '@resend.dev' (the Resend test domain; no real mailbox can have it).
--     A bug in the test fixture therefore cannot delete a real family.
--   · Returns the members' auth user ids: auth.users rows are NOT touched
--     here (profiles.user_id has no cascade) — the caller removes them via
--     the GoTrue Admin API afterwards.
--
-- Deletes run in the service context (auth.uid() IS NULL), which the V008
-- day-protection and profile-protection triggers exempt by design.
-- =============================================================================

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
	WHERE family_id = p_family_id AND email NOT LIKE '%@resend.dev';
	IF non_e2e_members > 0 THEN
		RAISE EXCEPTION 'purge_e2e_family: family % has non-E2E members (email).', p_family_id
			USING ERRCODE = 'check_violation';
	END IF;

	-- Hand the auth user ids back BEFORE deleting the profiles.
	RETURN QUERY
	SELECT user_id::uuid FROM public.profiles
	WHERE family_id = p_family_id AND user_id IS NOT NULL;

	-- Ordered teardown (children first; profiles are referenced by all data).
	DELETE FROM public.notifications      WHERE family_id = p_family_id;
	DELETE FROM public.swap_requests      WHERE family_id = p_family_id;
	DELETE FROM public.activity_logs      WHERE family_id = p_family_id;
	DELETE FROM public.care_schedules     WHERE family_id = p_family_id;
	DELETE FROM public.family_invitations WHERE family_id = p_family_id;
	DELETE FROM public.profiles           WHERE family_id = p_family_id;
	DELETE FROM public.families           WHERE id = p_family_id;
END;
$$;

ALTER FUNCTION public.purge_e2e_family(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purge_e2e_family(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_e2e_family(bigint) FROM anon;
REVOKE ALL ON FUNCTION public.purge_e2e_family(bigint) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.purge_e2e_family(bigint) TO service_role;
