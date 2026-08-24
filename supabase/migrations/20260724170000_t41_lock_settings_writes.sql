-- =============================================================================
-- T-41 (corrective) — lock the config/usage tables at the PRIVILEGE level
--
-- Supabase's default privileges grant `anon`/`authenticated` write access on new
-- public tables. RLS then blocks a client write, but an UPDATE/DELETE that matches
-- no policy affects **0 rows silently** (no error) instead of failing loudly. For
-- these system tables we want writes to be denied at the privilege level too, so a
-- tampering attempt fails hard (defense in depth) — and the enforcement stays
-- unambiguous (the app only ever READS the public settings; the DATABASE enforces
-- every real limit server-side, so a client cannot change a value for its benefit).
--
-- app_settings: authenticated keeps SELECT only (RLS still filters to is_public).
-- email_usage:  fully server-side (service_role only) — no client access at all.
-- =============================================================================

REVOKE ALL ON public.app_settings FROM anon, authenticated;
GRANT SELECT ON public.app_settings TO authenticated;   -- public rows only (RLS USING is_public)

REVOKE ALL ON public.email_usage FROM anon, authenticated;
