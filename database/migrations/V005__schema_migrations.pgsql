-- =============================================================================
-- V005 — Migration tracking table (schema_migrations)
-- Guarda Compartilhada — Supabase/PostgreSQL
--
-- Introduces public.schema_migrations so every environment records which
-- versioned migrations it has applied. This makes promoting changes to QA /
-- production deterministic and loss-proof:
--
--     apply, in ascending order, every migrations/VNNN__* whose `version`
--     is NOT yet present in schema_migrations for that environment.
--
-- 1. Creates the tracking table (RLS on, no client access — meta only).
-- 2. Back-fills V001–V004 as already applied (they predate this convention).
-- 3. Registers V005 itself.
--
-- From V006 onward every migration ends with its own INSERT into this table
-- (see the template in database/README.md).
--
-- NOTE: uses the `public` schema on purpose. The `supabase_migrations` schema
-- is reserved for the Supabase CLI, which we plan to adopt in Phase 4 (see
-- backlog T-29); keeping our table separate avoids a collision at that point.
--
-- Apply via the Supabase SQL Editor against the target project AFTER V004.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Tracking table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.schema_migrations (
	version     text PRIMARY KEY,
	description text,
	applied_at  timestamp with time zone NOT NULL DEFAULT timezone('utc', now())
);

-- Meta table — clients (anon/authenticated) must never touch it; only
-- migrations, which run as the table owner and bypass RLS.
ALTER TABLE public.schema_migrations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.schema_migrations FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Back-fill migrations applied before this convention existed
--    (correct both on existing DBs already at V004 and on a fresh run,
--    where V001–V004 have just been executed in order right before this).
-- ---------------------------------------------------------------------------

INSERT INTO public.schema_migrations (version, description) VALUES
	('V001', 'initial_schema'),
	('V002', 'swap_requests'),
	('V003', 'revert_workflow'),
	('V004', 'revoke_anon_and_enforce_swap_workflow')
ON CONFLICT (version) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. Register this migration
-- ---------------------------------------------------------------------------

INSERT INTO public.schema_migrations (version, description)
VALUES ('V005', 'schema_migrations')
ON CONFLICT (version) DO NOTHING;

COMMIT;
