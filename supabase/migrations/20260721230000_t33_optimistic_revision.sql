-- =============================================================================
-- T-33 — optimistic concurrency on calendar updates (scope decided July 2026:
-- care_schedules only; single-field profile/family edits stay last-writer-wins,
-- accepted and documented in the mutation inventory).
--
-- The race the 23505 UNIQUE already covers is the INSERT one; a stale UPDATE
-- was WORSE — it silently overwrote (last-writer-wins fails nothing). Now:
--   · care_schedules.revision (int, default 0) increments on every UPDATE;
--   · the client sends the full row WITH the revision it READ — if the row
--     changed meanwhile the revisions differ and the trigger raises the same
--     PT-BR "someone got there first" message the client already translates
--     and recovers from (reload + rehydrate, v1.5.17 machinery);
--   · server-side flows (S-11 erasure cleanup, auto-approval, swap RPCs) use
--     column-list UPDATEs that never mention revision → NEW.revision equals
--     OLD.revision → they pass untouched and increment. No special bypass.
--
-- Trigger naming: 'trigger_c_…' so it runs AFTER trigger_a (family stamp) and
-- trigger_b (day protection) — frozen/past-day errors take precedence over the
-- staleness error.
-- =============================================================================

ALTER TABLE public.care_schedules
	ADD COLUMN IF NOT EXISTS revision integer NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.enforce_schedule_revision()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
	IF NEW.revision IS DISTINCT FROM OLD.revision THEN
		RAISE EXCEPTION 'Outro responsável salvou este dia primeiro — atualize o calendário e tente novamente.'
			USING ERRCODE = 'check_violation';
	END IF;
	NEW.revision   := OLD.revision + 1;
	NEW.updated_at := timezone('utc', now());
	RETURN NEW;
END;
$$;

ALTER FUNCTION public.enforce_schedule_revision() OWNER TO postgres;

CREATE OR REPLACE TRIGGER trigger_c_enforce_schedule_revision
	BEFORE UPDATE ON public.care_schedules
	FOR EACH ROW EXECUTE FUNCTION public.enforce_schedule_revision();
