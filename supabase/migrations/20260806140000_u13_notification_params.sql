-- U-13 — localizable notifications, part 1: the column + ONE trigger, to prove
-- the pattern before it is copied across the other eleven.
--
-- THE PROBLEM. notifications.title/.message are RENDERED PT-BR SENTENCES, written
-- at INSERT time — by SQL triggers here, and by the client in
-- SwapRequestService. Each row is read by SOMEONE ELSE, whose language may
-- differ from the writer's. So there is no language the writer could pick that
-- is right: translating at write time just moves the error to the other party.
--
-- THE SHAPE. Store the DATA (`params`) and render on the CLIENT, in the READER's
-- language, from `type` + `params`. The stored title/message stay untouched and
-- serve as the fallback for every row written before this migration — nothing in
-- history changes, and no backfill can fabricate a translation we never had.
--
-- WHAT GOES IN params: values, never sentences. Dates as the app formats them,
-- names as user data passed through, and a discriminator when one `type` has
-- more than one wording (see `role` below). A sentence in params would defeat
-- the whole point.
--
-- REJECTED: PT/EN column pairs. That doubles every future trigger body and still
-- fails the moment a third language appears.
--
-- WHY auto_approve_expired FIRST (owner, 06/08/2026): it is the highest-volume
-- path, it inserts FOUR notifications covering three types, and it is the
-- function the F-47 delivery rewrote most recently — so it exercises the
-- CREATE OR REPLACE hazard the CLAUDE.md gotcha describes. The body below was
-- copied from `20260804220000_f47_revert_notes.sql`, the LATEST version, and the
-- only edits are the params payloads.

ALTER TABLE public.notifications
	ADD COLUMN IF NOT EXISTS params jsonb;

COMMENT ON COLUMN public.notifications.params IS
	'U-13: render data for the client-side renderer (type + params -> text in the READER''s language). NULL on rows written before the item; the stored title/message are the fallback for those.';

-- ── auto_approve_expired ─────────────────────────────────────────────────────
-- Copied from 20260804220000_f47_revert_notes.sql (the latest body) with the
-- params payloads added. Nothing else changed: the 24h reminder window, the 48h
-- auto-approval, the F-47 revert_notes restore and the F-28 family fan-out all
-- behave exactly as before.

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
    fanout_kind   text;
BEGIN
    -- ── 24h reminders: expired between 24h and 48h ago, not yet reminded ──
    FOR rec IN
        SELECT * FROM public.swap_requests
        WHERE status IN ('pending', 'revert_pending') AND reminder_sent_at IS NULL
    LOOP
        expiry := (rec.schedule_date + COALESCE(rec.proposed_handoff_time, '00:00'::time)) AT TIME ZONE tz;
        IF now() >= expiry + interval '24 hours' AND now() < expiry + interval '48 hours' THEN
            d := to_char(rec.schedule_date, 'DD/MM');
            INSERT INTO public.notifications (recipient_profile_id, type, title, message, params, swap_request_id, is_read, created_at)
            VALUES (
                rec.target_profile_id,
                'auto_reminder',
                p_env_prefix || '⏰ Solicitação pendente expira em 24h',
                'A solicitação do dia ' || d || ' será aprovada automaticamente em 24h se não houver resposta.',
                jsonb_build_object('date', d),
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
                fanout_kind := 'auto_swap';
            ELSE
                -- F-47: the requester's decision about the day observation.
                PERFORM public.restore_pre_edit_state(rec.schedule_id, rec.pre_edit_log_id, rec.revert_notes);
                UPDATE public.swap_requests SET status = 'revert_approved', resolved_by = 'system' WHERE id = rec.id;

                fanout_msg := 'A troca do dia ' || d || ' foi revertida automaticamente — '
                    || COALESCE(proposed_name, 'o responsável planejado')
                    || ' volta a ficar com a criança.';
                fanout_kind := 'auto_revert';
            END IF;

            -- Notify the requester and the approver (distinct copy).
            -- U-13: same `type`, two different wordings — so `role` is the
            -- discriminator the renderer branches on. Without it the reader
            -- would get the other party's sentence.
            INSERT INTO public.notifications (recipient_profile_id, type, title, message, params, swap_request_id, is_read, created_at)
            VALUES (
                rec.requesting_profile_id, 'auto_approved',
                p_env_prefix || '✅ Solicitação aprovada automaticamente',
                'A solicitação do dia ' || d || ' foi aprovada automaticamente após 48h sem resposta.',
                jsonb_build_object('date', d, 'role', 'requester'),
                rec.id, false, now()
            );
            INSERT INTO public.notifications (recipient_profile_id, type, title, message, params, swap_request_id, is_read, created_at)
            VALUES (
                rec.target_profile_id, 'auto_approved',
                p_env_prefix || '✅ Solicitação aprovada automaticamente',
                'A solicitação do dia ' || d || ' foi aprovada automaticamente. Você não respondeu dentro do prazo.',
                jsonb_build_object('date', d, 'role', 'approver'),
                rec.id, false, now()
            );

            -- F-28: family-info fan-out to uninvolved caregivers.
            -- U-13: `name` is USER DATA (a caregiver's own name) and is passed
            -- through untranslated, exactly like the role catalogue's custom
            -- roles. `kind` tells the renderer swap from revert.
            INSERT INTO public.notifications (recipient_profile_id, type, title, message, params, swap_request_id, is_read, created_at)
            SELECT p.id, 'swap_family_info',
                   p_env_prefix || '📅 Calendário atualizado',
                   fanout_msg,
                   jsonb_build_object('date', d, 'kind', fanout_kind, 'name', proposed_name),
                   rec.id, false, now()
            FROM public.profiles p
            WHERE p.family_id = rec.family_id
              AND p.id NOT IN (rec.requesting_profile_id, rec.target_profile_id);

            swap_request_id := rec.id; email_type := 'auto_approved'; RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;

-- Unchanged from the F-47 delivery: the worker RPC stays service_role-only.
REVOKE ALL ON FUNCTION public.auto_approve_expired(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auto_approve_expired(text) TO service_role;
