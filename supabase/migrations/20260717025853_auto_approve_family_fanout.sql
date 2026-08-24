-- ============================================================================
-- F-28 (PR2): auto_approve_expired — family-info fan-out.
--
-- When the system auto-approves a swap/revert after 48h, the calendar changes
-- for the WHOLE family, so caregivers who are neither the requester nor the
-- approver now receive an in-app informational notification with explicit
-- names (mirrors SwapRequestService.NotifyUninvolvedMembersAsync). No e-mail —
-- awareness, not a call to action.
--
-- Body verbatim from V007/baseline plus the fan-out INSERTs (and the name
-- lookups they need).
-- ============================================================================

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
                PERFORM public.restore_pre_edit_state(rec.schedule_id, rec.pre_edit_log_id);
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

-- Same lockdown as V007: worker-only.
REVOKE ALL ON FUNCTION public.auto_approve_expired(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.auto_approve_expired(text) TO service_role;
