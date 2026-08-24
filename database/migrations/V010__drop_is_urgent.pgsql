-- =============================================================================
-- V010 — Drop the static is_urgent flag (F-20 + F-22)
-- Guarda Compartilhada — Supabase/PostgreSQL
--
-- Urgency is a function of "now", not a fact of the record: the boolean was a
-- snapshot frozen at creation time that could never become urgent (or overdue)
-- as the handoff approached. The priority tag is now COMPUTED everywhere from
-- fields that already exist on swap_requests:
--
--     reference = resolved_at ?? now        (pending uses the clock;
--                                             resolved uses the historical fact)
--     handoff   = schedule_date + coalesce(proposed_handoff_time, 00:00)
--
--     reference <  handoff - 24h  →  (no tag)
--     reference <  handoff        →  urgent   (⚠️ URGENTE)
--     reference >= handoff        →  overdue  (⏰ ATRASADO)
--
-- No replacement column: the resolution-time tag is fully derivable from
-- resolved_at, so storing it would be redundant derived state. The client and
-- the send-swap-email Edge Function (send-time, America/Sao_Paulo) share the
-- same formula. Urgency history from the boolean era is intentionally lost
-- (decision recorded in F-20 — the app is not public yet).
--
-- Apply via the Supabase SQL Editor against the target project AFTER V009.
-- =============================================================================

BEGIN;

ALTER TABLE public.swap_requests DROP COLUMN IF EXISTS is_urgent;

INSERT INTO public.schema_migrations (version, description)
VALUES ('V010', 'drop_is_urgent')
ON CONFLICT (version) DO NOTHING;

COMMIT;
