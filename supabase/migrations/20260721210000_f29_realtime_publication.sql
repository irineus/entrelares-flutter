-- =============================================================================
-- F-29 — realtime publication catch-up
--
-- The supabase-js bridge subscribes to postgres_changes on care_schedules,
-- swap_requests, profiles, notifications and family_deletion_requests. The
-- baseline publication already carries the first four; family_deletion_requests
-- (created in S-11 PR2) joins it here. RLS (WALRUS) scopes the events — each
-- client only receives changes to rows it can SELECT.
-- =============================================================================

DO $$
BEGIN
	ALTER PUBLICATION supabase_realtime ADD TABLE ONLY public.family_deletion_requests;
EXCEPTION WHEN duplicate_object THEN
	NULL;   -- already in the publication (idempotent re-run)
END $$;
