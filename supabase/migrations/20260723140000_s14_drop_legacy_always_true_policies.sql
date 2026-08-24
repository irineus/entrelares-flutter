-- =============================================================================
-- S-14 — drop the baseline-era always-true RLS policies that nullify the
-- family scoping.
--
-- Permissive RLS policies combine with OR, so a `USING (true)` policy sitting
-- alongside the family-scoped ones lets ANY authenticated account read (and,
-- for care_schedules, write) another family's rows through direct PostgREST —
-- the app UI never exposes it, but a hand-crafted API call does.
--
-- The Supabase Security Advisor (`rls_policy_always_true`) flagged only
-- care_schedules at the v1.6.0 promotion; the S-14 sweep found the SAME leak on
-- activity_logs and profiles (both carry a `USING (true)` SELECT policy next to
-- their family-scoped read). All three are closed here. roles keeps a single
-- always-true read (it is GLOBAL reference vocabulary, read by everyone by
-- design) — only the redundant duplicate is removed.
--
-- Safe to drop: the family-scoped policies already cover every access pattern
-- the app uses (own family + own profile); profile writes go through
-- SECURITY DEFINER RPCs, the audit log is append-only by trigger, and the
-- legitimate cross-family flow (invite migration) runs as service_role in an
-- Edge Function, which bypasses RLS entirely.
-- =============================================================================

-- care_schedules: legacy policy was FOR ALL — closes cross-family read AND write.
DROP POLICY IF EXISTS "Allow full access to care schedules for authenticated users"
	ON public.care_schedules;

-- activity_logs: legacy policy was SELECT — closes cross-family read of the
-- immutable audit history.
DROP POLICY IF EXISTS "Allow read logs for authenticated users"
	ON public.activity_logs;

-- profiles: legacy policy was SELECT — closes cross-family read of names,
-- e-mails and roles.
DROP POLICY IF EXISTS "Allow read profiles for authenticated users"
	ON public.profiles;

-- roles: global reference data — an always-true read is intended, but there
-- were TWO identical policies. Keep roles_authenticated_read; drop the dupe.
DROP POLICY IF EXISTS "Allow read for authenticated users"
	ON public.roles;
