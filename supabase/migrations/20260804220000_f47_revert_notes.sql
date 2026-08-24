-- F-47: the reverter decides whether undoing a swap also puts the day's
-- OBSERVATION back.
--
-- The F-26 restore replays the whole pre-edit snapshot, care_schedules.notes
-- included. Sometimes that is right (the observation described the swap being
-- undone) and sometimes it silently destroys work (the family rewrote the
-- observation days AFTER the swap was approved). There is no universal rule,
-- so the requester answers the question when it is actually ambiguous — and
-- the answer travels ON THE REQUEST, because the restore runs later and on the
-- OTHER side: the approver's client and the 48h auto-approval must both honour
-- a decision neither of them witnessed.
--
-- Fail-safe by construction: the column defaults to false (keep the current
-- text), so every path that does not know about F-47 — an old cached PWA
-- build, a request created before this migration — preserves what is on the
-- day instead of overwriting it.
--
-- Idempotent (IF NOT EXISTS / OR REPLACE / DROP IF EXISTS): the dev dry-run
-- goes through execute_sql and CI applies this same file on the dev push
-- (CLAUDE.md, T-45 lesson).

-- ── The decision, carried by the request ────────────────────────────────────

ALTER TABLE public.swap_requests
    ADD COLUMN IF NOT EXISTS revert_notes boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.swap_requests.revert_notes IS
    'F-47: true when the requester chose to also restore the day observation '
    '(care_schedules.notes) from the pre-edit snapshot. Written once at '
    'creation and frozen afterwards; false means the current observation stays.';

-- ── Frozen after the INSERT ─────────────────────────────────────────────────
--
-- The choice belongs to the REQUESTER, but the row is updated later by the
-- APPROVER (status/approval_note) — a full-row PostgREST update from that side
-- would otherwise carry a flipped flag straight into the restore. Same
-- discipline as resolution_log_id (F-45): whatever the client sends, the
-- stored value wins. No role check inside, so no SECURITY DEFINER needed
-- (T-35): the function never asks WHO is writing, it asks nothing at all.

CREATE OR REPLACE FUNCTION public.freeze_revert_notes_choice()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.revert_notes := OLD.revert_notes;
    RETURN NEW;
END;
$$;

ALTER FUNCTION public.freeze_revert_notes_choice() OWNER TO postgres;

-- trigger_z_…: after trigger_a_set_swap_request_family and the status
-- transition guard, alongside the F-45 stamp (the two touch disjoint columns).
DROP TRIGGER IF EXISTS trigger_z_freeze_revert_notes ON public.swap_requests;
CREATE TRIGGER trigger_z_freeze_revert_notes
    BEFORE UPDATE ON public.swap_requests
    FOR EACH ROW EXECUTE FUNCTION public.freeze_revert_notes_choice();

-- ── The restore honours the flag ────────────────────────────────────────────
--
-- New third argument instead of an overload: a DEFAULT on a 3-arg twin would
-- make every existing 2-arg call ambiguous, so the old signature is dropped.
-- Its only caller is auto_approve_expired, replaced below in the same file.
--
-- Grants tightened while the function is being rewritten anyway. It is
-- SECURITY DEFINER over a bare schedule id with no family filter, so an end
-- user who could call it would be able to rewrite — or DELETE — any family's
-- day. No client ever calls it (the C# revert does its own restore); the
-- worker does.
--
-- The V007-era lockdown was `REVOKE ALL … FROM PUBLIC` + `GRANT … TO
-- service_role`, and that never worked (verified on DEV, Aug 2026): Supabase's
-- DEFAULT PRIVILEGES grant EXECUTE to anon/authenticated on every new function
-- in `public`, and those are role grants, which a revoke from PUBLIC does not
-- touch. Both functions were callable by any logged-in user — and by anon.
-- Revoking from the two roles by name is what actually closes it.

DROP FUNCTION IF EXISTS public.restore_pre_edit_state(bigint, bigint);

CREATE OR REPLACE FUNCTION public.restore_pre_edit_state(
    p_schedule_id     bigint,
    p_pre_edit_log_id bigint,
    p_restore_notes   boolean DEFAULT false)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    snap jsonb;
BEGIN
    IF p_schedule_id IS NULL THEN
        RETURN;
    END IF;

    -- No snapshot reference (swaps approved before F-26): clear the swap only.
    IF p_pre_edit_log_id IS NULL THEN
        UPDATE public.care_schedules
        SET actual_parent_id = NULL, updated_at = timezone('utc', now())
        WHERE id = p_schedule_id;
        RETURN;
    END IF;

    SELECT old_data INTO snap FROM public.activity_logs WHERE id = p_pre_edit_log_id;

    -- old_data NULL → the day was created by the edit; restoring "before"
    -- removes it. Nothing to decide about the observation: the day goes.
    IF snap IS NULL THEN
        DELETE FROM public.care_schedules WHERE id = p_schedule_id;
        RETURN;
    END IF;

    UPDATE public.care_schedules
    SET scheduled_parent_id = COALESCE((snap->>'scheduled_parent_id')::bigint, scheduled_parent_id),
        actual_parent_id    = (snap->>'actual_parent_id')::bigint,
        handoff_time        = (snap->>'handoff_time')::time,
        -- F-47: the observation moves only when the requester asked for it.
        -- NULL is treated as "no" — the safe answer is also the default one.
        notes               = CASE WHEN COALESCE(p_restore_notes, false)
                                   THEN snap->>'notes'
                                   ELSE notes
                              END,
        updated_at          = timezone('utc', now())
    WHERE id = p_schedule_id;
END;
$$;

ALTER FUNCTION public.restore_pre_edit_state(bigint, bigint, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.restore_pre_edit_state(bigint, bigint, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.restore_pre_edit_state(bigint, bigint, boolean) TO service_role;

-- ── auto_approve_expired passes the request's own decision ──────────────────
--
-- Body verbatim from 20260717025853_auto_approve_family_fanout.sql (the LATEST
-- definition — T-45 lesson) with a single line changed: the restore call now
-- carries rec.revert_notes.

CREATE OR REPLACE FUNCTION public.auto_approve_expired(p_env_prefix text DEFAULT '')
RETURNS TABLE (swap_request_id bigint, email_type text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    rec           record;
    tz            constant text := 'America/Sao_Paulo';
    expiry        timestamptz;
    d             text;
    proposed_name text;
    fanout_msg    text;
BEGIN
    -- ── 24h reminders: expired between 24h and 48h ago, not yet reminded ──
    FOR rec IN
        SELECT * FROM public.swap_requests
        WHERE status IN ('pending', 'revert_pending') AND reminder_sent_at IS NULL
    LOOP
        expiry := (rec.schedule_date + COALESCE(rec.proposed_handoff_time, '00:00'::time)) AT TIME ZONE tz;
        IF now() >= expiry + interval '24 hours' AND now() < expiry + interval '48 hours' THEN
            d := to_char(rec.schedule_date, 'DD/MM');
            INSERT INTO public.notifications (recipient_profile_id, type, title, message, swap_request_id, is_read, created_at)
            VALUES (
                rec.target_profile_id,
                'auto_reminder',
                p_env_prefix || '⏰ Solicitação pendente expira em 24h',
                'A solicitação do dia ' || d || ' será aprovada automaticamente em 24h se não houver resposta.',
                rec.id, false, now()
            );
            UPDATE public.swap_requests SET reminder_sent_at = now() WHERE id = rec.id;

            swap_request_id := rec.id; email_type := 'reminder'; RETURN NEXT;
        END IF;
    END LOOP;

    -- ── Auto-approve: expired more than 48h ago ──────────────────────────
    FOR rec IN
        SELECT * FROM public.swap_requests
        WHERE status IN ('pending', 'revert_pending')
    LOOP
        expiry := (rec.schedule_date + COALESCE(rec.proposed_handoff_time, '00:00'::time)) AT TIME ZONE tz;
        IF now() >= expiry + interval '48 hours' THEN
            d := to_char(rec.schedule_date, 'DD/MM');

            -- The person the day lands on: the proposed parent (for a revert
            -- request that is the restored planned responsible).
            SELECT full_name INTO proposed_name
            FROM public.profiles WHERE id = rec.proposed_actual_parent_id;

            IF rec.status = 'pending' THEN
                IF rec.schedule_id IS NOT NULL THEN
                    UPDATE public.care_schedules
                    SET actual_parent_id = rec.proposed_actual_parent_id,
                        handoff_time     = rec.proposed_handoff_time,
                        updated_at       = timezone('utc', now())
                    WHERE id = rec.schedule_id;
                END IF;
                UPDATE public.swap_requests SET status = 'approved', resolved_by = 'system' WHERE id = rec.id;

                fanout_msg := COALESCE(proposed_name, 'Outro responsável')
                    || ' ficará com a criança no dia ' || d
                    || ' (troca aprovada automaticamente após 48h sem resposta).';
            ELSE
                -- F-47: the requester's decision about the day observation.
                PERFORM public.restore_pre_edit_state(rec.schedule_id, rec.pre_edit_log_id, rec.revert_notes);
                UPDATE public.swap_requests SET status = 'revert_approved', resolved_by = 'system' WHERE id = rec.id;

                fanout_msg := 'A troca do dia ' || d || ' foi revertida automaticamente — '
                    || COALESCE(proposed_name, 'o responsável planejado')
                    || ' volta a ficar com a criança.';
            END IF;

            -- Notify the requester and the approver (distinct copy).
            INSERT INTO public.notifications (recipient_profile_id, type, title, message, swap_request_id, is_read, created_at)
            VALUES (
                rec.requesting_profile_id, 'auto_approved',
                p_env_prefix || '✅ Solicitação aprovada automaticamente',
                'A solicitação do dia ' || d || ' foi aprovada automaticamente após 48h sem resposta.',
                rec.id, false, now()
            );
            INSERT INTO public.notifications (recipient_profile_id, type, title, message, swap_request_id, is_read, created_at)
            VALUES (
                rec.target_profile_id, 'auto_approved',
                p_env_prefix || '✅ Solicitação aprovada automaticamente',
                'A solicitação do dia ' || d || ' foi aprovada automaticamente. Você não respondeu dentro do prazo.',
                rec.id, false, now()
            );

            -- F-28: family-info fan-out to uninvolved caregivers.
            INSERT INTO public.notifications (recipient_profile_id, type, title, message, swap_request_id, is_read, created_at)
            SELECT p.id, 'swap_family_info',
                   p_env_prefix || '📅 Calendário atualizado',
                   fanout_msg,
                   rec.id, false, now()
            FROM public.profiles p
            WHERE p.family_id = rec.family_id
              AND p.id NOT IN (rec.requesting_profile_id, rec.target_profile_id);

            swap_request_id := rec.id; email_type := 'auto_approved'; RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;

-- The lockdown V007 intended, this time effective (see the note above): the
-- worker RPC was reachable by anon/authenticated, so any logged-in user could
-- force-resolve every expired request in the project and fire its
-- notifications. Every legitimate caller — the Edge Function cron and the
-- integration suites — runs as service_role.
REVOKE ALL ON FUNCTION public.auto_approve_expired(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auto_approve_expired(text) TO service_role;
