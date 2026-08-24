-- F-45: link a swap request to the activity_logs row its RESOLUTION produced.
--
-- notifications.swap_request_id links a notification to its request, and
-- pre_edit_log_id points BACKWARDS at the pre-edit snapshot (F-26) — but
-- nothing linked a request to the calendar change its approval wrote, so the
-- Histórico could not say WHY a day changed and auto-approvals rendered as
-- "Sistema" with no trace of the underlying request. resolution_log_id closes
-- the triangle, symmetric to pre_edit_log_id.
--
-- The stamp is SERVER-SIDE (BEFORE UPDATE trigger on swap_requests), not a
-- client write: it fires identically on the client approval path
-- (SwapRequestService.ApproveAsync / ApproveRevertAsync — care_schedules
-- update, then status update) and on auto_approve_expired (same order, same
-- transaction), so there is exactly one implementation and the race-prone
-- "newest log for that date" client heuristic is not repeated. The window is
-- tight by construction: the day is FROZEN while the request is pending, so
-- the newest family log for that date since the request was created is the
-- resolution's own write.
--
-- Idempotent by design (IF NOT EXISTS / OR REPLACE / NULL-guarded backfill):
-- the dev dry-run uses execute_sql and CI applies the file again (see
-- CLAUDE.md, T-45 lesson).

-- ── Column + FK + reverse-lookup index ──────────────────────────────────────

ALTER TABLE public.swap_requests
    ADD COLUMN IF NOT EXISTS resolution_log_id bigint;

DO $$ BEGIN
    ALTER TABLE public.swap_requests
        ADD CONSTRAINT swap_requests_resolution_log_id_fkey
        FOREIGN KEY (resolution_log_id)
        REFERENCES public.activity_logs(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- The Histórico/PDF ask the reverse question ("which request produced this
-- log?") in batches — partial index keeps it cheap and small.
CREATE INDEX IF NOT EXISTS idx_swap_requests_resolution_log_id
    ON public.swap_requests (resolution_log_id)
    WHERE resolution_log_id IS NOT NULL;

-- ── Backfill (conservative) — BEFORE the trigger exists, on purpose ─────────
--
-- The trigger below makes the column trigger-owned (any non-resolution UPDATE
-- preserves the old value), which would silently null this very backfill if it
-- ran after the trigger was created. Order matters.
--
-- Conservative window: only logs written between the request's creation and
-- its resolution (small slack for clock skew between the two client HTTP
-- calls), on the same family and date, past the pre-edit snapshot. A request
-- with no log in that window stays NULL — an unlinked entry is honest, a
-- wrongly linked one is not.

UPDATE public.swap_requests sr
SET resolution_log_id = sub.log_id
FROM (
    SELECT sr2.id AS request_id, max(al.id) AS log_id
    FROM public.swap_requests sr2
    JOIN public.activity_logs al
      ON  al.family_id     = sr2.family_id
      AND al.affected_date = sr2.schedule_date
      AND al.created_at   >= sr2.created_at
      AND al.created_at   <= COALESCE(sr2.resolved_at, sr2.updated_at) + interval '5 minutes'
      AND (sr2.pre_edit_log_id IS NULL OR al.id > sr2.pre_edit_log_id)
    WHERE sr2.status IN ('approved', 'revert_approved')
      AND sr2.resolution_log_id IS NULL
    GROUP BY sr2.id
) sub
WHERE sr.id = sub.request_id;

-- ── Trigger: stamp on resolution, preserve everywhere else ──────────────────
--
-- SECURITY DEFINER (owner postgres) so the activity_logs read never depends on
-- the caller's RLS; correctness comes from the explicit family_id filter. No
-- role check inside — the T-35 lesson does not apply because the function
-- never asks WHO is writing, only WHAT transition is happening (the
-- who-question is enforce_swap_status_transition's job, which already ran:
-- BEFORE UPDATE triggers fire alphabetically and trigger_e… < trigger_z…).

CREATE OR REPLACE FUNCTION public.stamp_swap_resolution_log()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
    -- Trigger-owned column: whatever the client sent, carry the stored value
    -- through — a full-row PostgREST update can neither forge nor clear it.
    NEW.resolution_log_id := OLD.resolution_log_id;

    -- Stamp exactly once, on the resolution transition. The calendar write
    -- (care_schedules update / restore / delete-on-restore) already happened
    -- in both resolution paths, so its audit row exists and is the newest
    -- one for this family+date since the request was created.
    IF OLD.status IN ('pending', 'revert_pending')
       AND NEW.status IN ('approved', 'revert_approved') THEN
        SELECT max(al.id) INTO NEW.resolution_log_id
        FROM public.activity_logs al
        WHERE al.family_id     = NEW.family_id
          AND al.affected_date = NEW.schedule_date
          AND al.created_at   >= OLD.created_at
          AND (OLD.pre_edit_log_id IS NULL OR al.id > OLD.pre_edit_log_id);
    END IF;

    RETURN NEW;
END;
$$;

ALTER FUNCTION public.stamp_swap_resolution_log() OWNER TO postgres;

-- trigger_z_…: alphabetically after trigger_a_set_swap_request_family and
-- trigger_enforce_swap_status_transition, so validation runs first.
DROP TRIGGER IF EXISTS trigger_z_stamp_swap_resolution_log ON public.swap_requests;
CREATE TRIGGER trigger_z_stamp_swap_resolution_log
    BEFORE UPDATE ON public.swap_requests
    FOR EACH ROW EXECUTE FUNCTION public.stamp_swap_resolution_log();
