-- =============================================================================
-- V007 — Auto-approve expired swap/revert requests after 48h + 24h reminder (F-24)
-- Guarda Compartilhada — Supabase/PostgreSQL
--
-- A scheduled Edge Function (auto-approve-expired) calls the auto_approve_expired()
-- RPC on a cron. This migration provides everything the server-side flow needs:
--
-- 1. swap_requests columns: reminder_sent_at, resolved_by ('user' | 'system').
-- 2. Extends the state-machine trigger to allow the SYSTEM context (service_role,
--    where auth.uid() is null) to perform ONLY pending->approved and
--    revert_pending->revert_approved. Authenticated users keep the actor checks.
-- 3. restore_pre_edit_state(): the SQL twin of the C# F-26 revert restore, used to
--    auto-approve reverts.
-- 4. auto_approve_expired(): sends 24h reminders, auto-approves at 48h (applying the
--    calendar change + notifications) and RETURNS the emails the Edge Function
--    should dispatch.
--
-- Timezone: handoff times are treated as America/Sao_Paulo wall-clock (matching the
-- client's urgency calc). Revisit when the app supports multiple timezones.
--
-- Apply via the Supabase SQL Editor against the target project AFTER V006.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. New columns
-- ---------------------------------------------------------------------------

ALTER TABLE public.swap_requests
	ADD COLUMN IF NOT EXISTS reminder_sent_at timestamp with time zone,
	ADD COLUMN IF NOT EXISTS resolved_by      text NOT NULL DEFAULT 'user';

ALTER TABLE public.swap_requests
	DROP CONSTRAINT IF EXISTS swap_requests_resolved_by_check;
ALTER TABLE public.swap_requests
	ADD CONSTRAINT swap_requests_resolved_by_check CHECK (resolved_by IN ('user', 'system'));

-- ---------------------------------------------------------------------------
-- 2. Extend the state-machine trigger with a system-context branch
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_swap_status_transition()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    current_profile_id bigint;
    allowed boolean := false;
BEGIN
    SELECT id INTO current_profile_id
    FROM public.profiles
    WHERE user_id = auth.uid();

    -- Status unchanged → allow (e.g. setting reminder_sent_at, other fields).
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    IF current_profile_id IS NULL THEN
        -- System context: the Edge Function / cron runs as service_role, which
        -- bypasses RLS and has no auth.uid(). Allow ONLY auto-approval transitions.
        -- (Authenticated-without-profile users are already blocked by RLS.)
        allowed := (OLD.status = 'pending'        AND NEW.status = 'approved')
                OR (OLD.status = 'revert_pending' AND NEW.status = 'revert_approved');
    ELSE
        CASE OLD.status
            WHEN 'pending' THEN
                CASE NEW.status
                    WHEN 'approved'  THEN allowed := (current_profile_id = OLD.target_profile_id);
                    WHEN 'rejected'  THEN allowed := (current_profile_id = OLD.target_profile_id);
                    WHEN 'cancelled' THEN allowed := (current_profile_id = OLD.requesting_profile_id);
                    ELSE allowed := false;
                END CASE;

            WHEN 'revert_pending' THEN
                CASE NEW.status
                    WHEN 'revert_approved'  THEN allowed := (current_profile_id = OLD.target_profile_id);
                    WHEN 'revert_rejected'  THEN allowed := (current_profile_id = OLD.target_profile_id);
                    WHEN 'revert_cancelled' THEN allowed := (current_profile_id = OLD.requesting_profile_id);
                    ELSE allowed := false;
                END CASE;

            ELSE
                allowed := false;
        END CASE;
    END IF;

    IF NOT allowed THEN
        RAISE EXCEPTION 'Invalid status transition from "%" to "%" for current user',
            OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;

    NEW.updated_at := timezone('utc', now());
    IF NEW.status IN ('approved', 'rejected', 'cancelled', 'revert_approved', 'revert_rejected', 'revert_cancelled') THEN
        NEW.resolved_at := timezone('utc', now());
    END IF;

    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. SQL twin of the C# F-26 revert restore
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.restore_pre_edit_state(p_schedule_id bigint, p_pre_edit_log_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
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

    -- old_data NULL → the day was created by the edit; restoring "before" removes it.
    IF snap IS NULL THEN
        DELETE FROM public.care_schedules WHERE id = p_schedule_id;
        RETURN;
    END IF;

    UPDATE public.care_schedules
    SET scheduled_parent_id = COALESCE((snap->>'scheduled_parent_id')::bigint, scheduled_parent_id),
        actual_parent_id    = (snap->>'actual_parent_id')::bigint,
        handoff_time        = (snap->>'handoff_time')::time,
        notes               = snap->>'notes',
        updated_at          = timezone('utc', now())
    WHERE id = p_schedule_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Cron worker: reminders + auto-approvals
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.auto_approve_expired(p_env_prefix text DEFAULT '')
RETURNS TABLE (swap_request_id bigint, email_type text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    rec    record;
    tz     constant text := 'America/Sao_Paulo';
    expiry timestamptz;
    d      text;
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

            IF rec.status = 'pending' THEN
                IF rec.schedule_id IS NOT NULL THEN
                    UPDATE public.care_schedules
                    SET actual_parent_id = rec.proposed_actual_parent_id,
                        handoff_time     = rec.proposed_handoff_time,
                        updated_at       = timezone('utc', now())
                    WHERE id = rec.schedule_id;
                END IF;
                UPDATE public.swap_requests SET status = 'approved', resolved_by = 'system' WHERE id = rec.id;
            ELSE
                PERFORM public.restore_pre_edit_state(rec.schedule_id, rec.pre_edit_log_id);
                UPDATE public.swap_requests SET status = 'revert_approved', resolved_by = 'system' WHERE id = rec.id;
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

            swap_request_id := rec.id; email_type := 'auto_approved'; RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants — lock the worker down to service_role
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.restore_pre_edit_state(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.auto_approve_expired(text)             FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.auto_approve_expired(text)          TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Register migration
-- ---------------------------------------------------------------------------

INSERT INTO public.schema_migrations (version, description)
VALUES ('V007', 'auto_approve')
ON CONFLICT (version) DO NOTHING;

COMMIT;
