-- =============================================================================
-- V006 — Revert restores the full pre-swap state via the audit log (F-26)
-- Guarda Compartilhada — Supabase/PostgreSQL
--
-- Adds swap_requests.pre_edit_log_id: a reference to the activity_logs row whose
-- old_data JSON snapshot captures the day exactly as it was BEFORE the edit that
-- started the swap. On revert approval the app restores care_schedules from that
-- snapshot (full row), instead of only clearing actual_parent_id.
--
-- One generic reference — it does not grow per schedule field, since the audit
-- log already snapshots the whole row (and any future column) automatically.
--
-- Apply via the Supabase SQL Editor against the target project AFTER V005.
-- =============================================================================

BEGIN;

ALTER TABLE public.swap_requests
	ADD COLUMN IF NOT EXISTS pre_edit_log_id bigint
	REFERENCES public.activity_logs (id) ON DELETE SET NULL;

INSERT INTO public.schema_migrations (version, description)
VALUES ('V006', 'revert_snapshot')
ON CONFLICT (version) DO NOTHING;

COMMIT;
