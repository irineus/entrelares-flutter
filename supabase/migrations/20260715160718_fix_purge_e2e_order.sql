-- =============================================================================
-- T-30 — fix-forward #2: the care_schedules deletes inside purge_e2e_family
-- fire the audit trigger, which INSERTS new activity_logs rows AFTER the
-- function had already emptied that table — the final families delete then
-- failed with 23503 (activity_logs_family_id_fkey). activity_logs must be
-- deleted AFTER care_schedules (and still before profiles, which the logs
-- reference). Full CREATE OR REPLACE, body otherwise verbatim from
-- 20260715160546.
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
	-- Notifications have no family_id: scope them by the family's recipients.
	-- activity_logs go AFTER care_schedules: the audit trigger logs those
	-- very deletes, re-populating the table mid-purge.
	DELETE FROM public.notifications
	WHERE recipient_profile_id IN (SELECT id FROM public.profiles WHERE family_id = p_family_id);
	DELETE FROM public.swap_requests      WHERE family_id = p_family_id;
	DELETE FROM public.care_schedules     WHERE family_id = p_family_id;
	DELETE FROM public.activity_logs      WHERE family_id = p_family_id;
	DELETE FROM public.family_invitations WHERE family_id = p_family_id;
	DELETE FROM public.profiles           WHERE family_id = p_family_id;
	DELETE FROM public.families           WHERE id = p_family_id;
END;
$$;
