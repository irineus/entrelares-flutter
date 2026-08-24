-- U-24 — notification params carry an ISO 8601 date, so the READER's device
-- decides how it is written.
--
-- WHY. U-13 (PR 4a/4b) moved notifications from a stored PT-BR sentence to
-- stored DATA (`params`) rendered on the reader's device. The date was the one
-- field that did not make the trip: the writers stored it ALREADY FORMATTED as
-- 'DD/MM/YYYY' (or 'DD/MM'), so `NotificationRenderer` could only interpolate
-- it verbatim. The result was a half-translated notification — English words
-- around a Brazilian date — which is worse than an untranslated label, because
-- 05/08 reads as May 8th to most of the anglophone world and nothing on screen
-- signals it. The reader simply believes the wrong day.
--
-- WHAT CHANGES. Only the `params` jsonb. Every `title`/`message` column keeps
-- its PT-BR sentence with the PT-BR date, because that column is the FALLBACK
-- the renderer prints when it cannot rebuild a row — it must stay a truthful
-- record of what was sent, not become a second half-translated surface.
--
-- LEGACY ROWS ARE NOT TOUCHED. No backfill. A row written before this migration
-- keeps its 'DD/MM/YYYY' string, and `DateFormats.FormatIsoDate` returns
-- anything that does not parse as ISO unchanged — the same promise the renderer
-- already makes for rows with no `params` at all. Nobody's history is rewritten,
-- and a trigger deployed ahead of the client is covered by the same rule.
--
-- HOW THESE BODIES WERE PRODUCED. Each function below was extracted VERBATIM
-- from its most recent definition (`auto_approve_expired` from
-- 20260806140000_u13_notification_params.sql; the other four from
-- 20260806180000_u13_notification_params_rest.sql), with the date expression
-- inside `jsonb_build_object` as the ONLY edit. This is deliberate: rewriting a
-- shared body from the version one remembers is how S-09's copy of
-- `enforce_day_protection` silently dropped four later rules (see CLAUDE.md).
-- Where the same variable fed BOTH the stored sentence and `params`
-- (`auto_approve_expired.d`, `request_family_deletion.deadline_br`), a parallel
-- ISO variable was added rather than changing the existing one.

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
    d_iso         text;   -- U-24: ISO for params; `d` stays PT-BR in the stored sentence
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
            d_iso := to_char(rec.schedule_date, 'YYYY-MM-DD');
            INSERT INTO public.notifications (recipient_profile_id, type, title, message, params, swap_request_id, is_read, created_at)
            VALUES (
                rec.target_profile_id,
                'auto_reminder',
                p_env_prefix || '⏰ Solicitação pendente expira em 24h',
                'A solicitação do dia ' || d || ' será aprovada automaticamente em 24h se não houver resposta.',
                jsonb_build_object('date', d_iso),
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
            d_iso := to_char(rec.schedule_date, 'YYYY-MM-DD');

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
                jsonb_build_object('date', d_iso, 'role', 'requester'),
                rec.id, false, now()
            );
            INSERT INTO public.notifications (recipient_profile_id, type, title, message, params, swap_request_id, is_read, created_at)
            VALUES (
                rec.target_profile_id, 'auto_approved',
                p_env_prefix || '✅ Solicitação aprovada automaticamente',
                'A solicitação do dia ' || d || ' foi aprovada automaticamente. Você não respondeu dentro do prazo.',
                jsonb_build_object('date', d_iso, 'role', 'approver'),
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
                   jsonb_build_object('date', d_iso, 'kind', fanout_kind, 'name', proposed_name),
                   rec.id, false, now()
            FROM public.profiles p
            WHERE p.family_id = rec.family_id
              AND p.id NOT IN (rec.requesting_profile_id, rec.target_profile_id);

            swap_request_id := rec.id; email_type := 'auto_approved'; RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;


CREATE OR REPLACE FUNCTION public.request_account_deletion(p_new_admin_id bigint DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me              public.profiles%ROWTYPE;
	today           date := (now() AT TIME ZONE 'America/Sao_Paulo')::date;
	other_active    int;
	has_other_admin boolean;
	is_last         boolean;
	sr              record;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();
	IF me.id IS NULL THEN
		RAISE EXCEPTION 'Perfil não encontrado.' USING ERRCODE = 'check_violation';
	END IF;
	IF me.left_at IS NOT NULL THEN
		RAISE EXCEPTION 'Sua saída já foi solicitada.' USING ERRCODE = 'check_violation';
	END IF;

	IF EXISTS (SELECT 1 FROM public.family_deletion_requests
	           WHERE family_id = me.family_id AND status = 'pending') THEN
		RAISE EXCEPTION 'Há uma solicitação de exclusão da família em andamento — a saída individual fica bloqueada até ela ser resolvida.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- S-10: sensitive operation — requires a fresh password confirmation.
	IF NOT public.is_elevated() THEN
		RAISE EXCEPTION 'ELEVATION_REQUIRED: Confirme sua senha para sair da família.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	other_active := public.active_member_count(me.family_id) - 1;
	is_last := (other_active <= 0);

	IF NOT is_last THEN
		-- Members remain: keep the >= 1 admin invariant. If I am the only admin,
		-- a successor must be named and is promoted BEFORE I leave (promotion is
		-- audited normally, so it happens before the deletion-context bypass).
		has_other_admin := EXISTS (
			SELECT 1 FROM public.profiles
			WHERE family_id = me.family_id AND is_admin AND left_at IS NULL
			  AND user_id IS NOT NULL AND id <> me.id);

		IF me.is_admin AND NOT has_other_admin THEN
			IF p_new_admin_id IS NULL THEN
				RAISE EXCEPTION 'Indique um novo administrador para assumir antes de sair.'
					USING ERRCODE = 'check_violation';
			END IF;
			IF NOT EXISTS (
				SELECT 1 FROM public.profiles
				WHERE id = p_new_admin_id AND family_id = me.family_id
				  AND left_at IS NULL AND user_id IS NOT NULL AND id <> me.id) THEN
				RAISE EXCEPTION 'Selecione um responsável ativo da família para assumir como administrador.'
					USING ERRCODE = 'check_violation';
			END IF;
			UPDATE public.profiles SET is_admin = true WHERE id = p_new_admin_id;
		END IF;
	END IF;

	PERFORM set_config('app.deletion_context', 'on', true);

	-- Cancel my pending swap requests and notify the counterpart.
	FOR sr IN
		SELECT * FROM public.swap_requests
		WHERE family_id = me.family_id
		  AND status IN ('pending', 'revert_pending')
		  AND (requesting_profile_id = me.id OR target_profile_id = me.id
		       OR proposed_actual_parent_id = me.id OR previous_actual_parent_id = me.id)
	LOOP
		UPDATE public.swap_requests
		SET status = 'cancelled', resolved_at = timezone('utc', now()), resolved_by = 'system'
		WHERE id = sr.id;

		-- U-13: `swap_cancelled` is ALSO written by SwapRequestService, with
		-- entirely different copy — `kind` is what keeps a departure notice from
		-- rendering as "cancelled by the requester".
		INSERT INTO public.notifications (recipient_profile_id, type, title, message, params, swap_request_id)
		SELECT p.id, 'swap_cancelled',
		       'Solicitação cancelada',
		       me.full_name || ' saiu da família e a solicitação de troca de ' ||
		           to_char(sr.schedule_date, 'DD/MM/YYYY') || ' foi cancelada.',
		       jsonb_build_object('kind', 'member_left', 'name', me.full_name,
		                          'date', to_char(sr.schedule_date, 'YYYY-MM-DD')),
		       sr.id
		FROM public.profiles p
		WHERE p.family_id = me.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL
		  AND p.id IN (sr.requesting_profile_id, sr.target_profile_id) AND p.id <> me.id;
	END LOOP;

	-- Clear my FUTURE days — TODAY included (product decision: the current day
	-- counts as future for a departed member, even past its handoff time).
	UPDATE public.care_schedules
	SET actual_parent_id = NULL, updated_at = timezone('utc', now())
	WHERE family_id = me.family_id AND schedule_date >= today
	  AND actual_parent_id = me.id AND scheduled_parent_id <> me.id;

	DELETE FROM public.care_schedules
	WHERE family_id = me.family_id AND schedule_date >= today
	  AND scheduled_parent_id = me.id;

	-- Enter the leaving state (seat frees immediately; the GoTrue user survives
	-- so I can still cancel). When I am the last member, the cron will purge the
	-- whole family once the grace elapses.
	UPDATE public.profiles
	SET left_at = timezone('utc', now()),
	    deletion_scheduled_for = timezone('utc', now()) + interval '30 days'
	WHERE id = me.id;

	INSERT INTO public.account_logs (family_id, actor_profile_id, target_profile_id, action)
	VALUES (me.family_id, me.id, me.id, 'account_deletion_requested');

	-- Confirmation to myself (text differs for the last-member family removal).
	INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
	VALUES (me.id, 'account_deletion',
	        CASE WHEN is_last THEN 'Exclusão da família solicitada' ELSE 'Saída solicitada' END,
	        CASE WHEN is_last
	             THEN 'Como você é o único responsável, sua saída removerá a família e todos os dados após 30 dias. Você pode cancelar nesse período.'
	             ELSE 'Sua saída da família foi solicitada. Você tem 30 dias para cancelar; após esse prazo a conta será apagada.' END,
	        jsonb_build_object('kind', CASE WHEN is_last THEN 'self_last' ELSE 'self' END));

	-- Heads-up to the other active members (only when the family stays).
	IF NOT is_last THEN
		INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
		SELECT p.id, 'account_deletion',
		       'Um responsável saiu',
		       me.full_name || ' saiu da família. Os dias futuros dessa pessoa foram liberados — '
		           || 'verifique o calendário e reatribua o que for necessário.',
		       jsonb_build_object('kind', 'other_left', 'name', me.full_name)
		FROM public.profiles p
		WHERE p.family_id = me.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL AND p.id <> me.id;
	END IF;
END;
$$;


CREATE OR REPLACE FUNCTION public.request_family_deletion()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me       public.profiles%ROWTYPE;
	deadline timestamp with time zone := timezone('utc', now()) + interval '30 days';
	deadline_br text;
	deadline_iso text;   -- U-24: ISO for params; deadline_br stays PT-BR in the sentence
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();
	IF me.id IS NULL OR me.left_at IS NOT NULL THEN
		RAISE EXCEPTION 'Perfil não encontrado ou em processo de saída.' USING ERRCODE = 'check_violation';
	END IF;
	IF NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores podem solicitar a exclusão da família.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- S-10: sensitive operation — requires a fresh password confirmation.
	IF NOT public.is_elevated() THEN
		RAISE EXCEPTION 'ELEVATION_REQUIRED: Confirme sua senha para solicitar a exclusão da família.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	-- The consent flow only makes sense with other members to consult; the
	-- last active member deletes the family through their own exit (PR1).
	IF public.active_member_count(me.family_id) <= 1 THEN
		RAISE EXCEPTION 'Você é o único responsável ativo — a exclusão da família acontece pela sua própria saída, em "Sair da família".'
			USING ERRCODE = 'check_violation';
	END IF;

	IF EXISTS (SELECT 1 FROM public.family_deletion_requests
	           WHERE family_id = me.family_id AND status = 'pending') THEN
		RAISE EXCEPTION 'Já existe uma solicitação de exclusão da família em andamento.'
			USING ERRCODE = 'check_violation';
	END IF;

	INSERT INTO public.family_deletion_requests (family_id, requested_by, scheduled_for)
	VALUES (me.family_id, me.id, deadline);

	INSERT INTO public.account_logs (family_id, actor_profile_id, action, new_value)
	VALUES (me.family_id, me.id, 'family_deletion_requested', to_char(deadline, 'YYYY-MM-DD'));

	deadline_br := to_char(deadline AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY');
	deadline_iso := to_char(deadline AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD');

	-- Confirmation to the requester.
	INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
	VALUES (me.id, 'family_deletion',
	        'Exclusão da família solicitada',
	        'Você solicitou a exclusão da família. Se ninguém recusar até ' || deadline_br ||
	        ', todos os dados (calendário, histórico e contas) serão apagados definitivamente. ' ||
	        'Você pode retirar a solicitação a qualquer momento.',
	        jsonb_build_object('kind', 'requested_self', 'date', deadline_iso));

	-- Heads-up to every other active member: silence = consent, refusal ends it.
	INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
	SELECT p.id, 'family_deletion',
	       'Exclusão da família solicitada',
	       me.full_name || ' solicitou a exclusão da família. Se ninguém recusar até ' || deadline_br ||
	       ', TODOS os dados (calendário, histórico e contas de todos) serão apagados definitivamente. ' ||
	       'Você pode recusar em Perfil > Exclusão da família — qualquer recusa cancela a exclusão.',
	       jsonb_build_object('kind', 'requested_other', 'name', me.full_name, 'date', deadline_iso)
	FROM public.profiles p
	WHERE p.family_id = me.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL AND p.id <> me.id;
END;
$$;


CREATE OR REPLACE FUNCTION public.family_deletion_reminders_due()
RETURNS TABLE (request_id bigint, requester_profile_id bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	r record;
BEGIN
	FOR r IN
		SELECT * FROM public.family_deletion_requests
		WHERE status = 'pending'
		  AND reminder_sent_at IS NULL
		  AND scheduled_for - interval '3 days' <= timezone('utc', now())
		  AND scheduled_for > timezone('utc', now())
	LOOP
		UPDATE public.family_deletion_requests
		SET reminder_sent_at = timezone('utc', now())
		WHERE id = r.id;

		INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
		SELECT p.id, 'family_deletion',
		       'Exclusão da família se aproxima',
		       'A família será excluída definitivamente em ' ||
		       to_char(r.scheduled_for AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY') ||
		       '. Você ainda pode recusar em Perfil > Exclusão da família, ou exportar seus dados antes.',
		       jsonb_build_object('kind', 'reminder',
		                          'date', to_char(r.scheduled_for AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD'))
		FROM public.profiles p
		WHERE p.family_id = r.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL;

		request_id := r.id;
		requester_profile_id := r.requested_by;
		RETURN NEXT;
	END LOOP;
END;
$$;


CREATE OR REPLACE FUNCTION public.billing_grace_warnings_due()
RETURNS TABLE (subscription_id bigint, family_id bigint, admin_profile_id bigint, grace_ends_at timestamp with time zone)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	grace_days   int := public.setting_int('billing.grace_days', 7);
	warning_days int := public.setting_int('billing.grace_warning_days', 2);
	r            record;
	ends_at      timestamp with time zone;
BEGIN
	FOR r IN
		SELECT s.id, s.family_id AS fam_id, s.overdue_since
		  FROM public.subscriptions s
		  JOIN public.families f ON f.id = s.family_id
		 WHERE s.status = 'overdue'
		   AND s.overdue_since IS NOT NULL
		   AND s.grace_warning_sent_at IS NULL
		   AND f.plan = 'premium'
		   -- Inside the warning window and not yet past the downgrade: warning
		   -- someone AFTER they already lost access would be worse than silence.
		   AND s.overdue_since + make_interval(days => grace_days - warning_days)
		       <= timezone('utc', now())
		   AND s.overdue_since + make_interval(days => grace_days)
		       > timezone('utc', now())
	LOOP
		ends_at := r.overdue_since + make_interval(days => grace_days);

		UPDATE public.subscriptions
		   SET grace_warning_sent_at = timezone('utc', now())
		 WHERE id = r.id;

		-- Reliable channel, same transaction as the marker.
		INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
		SELECT p.id, 'billing',
		       'Seu Premium está prestes a ser interrompido',
		       'Não conseguimos confirmar o pagamento da assinatura. Se a cobrança não for regularizada até ' ||
		       to_char(ends_at AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY') ||
		       ', a família voltará ao Plano Gratuito. Nenhum dado é apagado — os recursos Premium apenas ficam indisponíveis.',
		       jsonb_build_object('kind', 'grace_warning',
		                          'date', to_char(ends_at AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD'))
		  FROM public.profiles p
		 WHERE p.family_id = r.fam_id
		   AND p.is_admin
		   AND p.left_at IS NULL
		   AND p.user_id IS NOT NULL;

		-- One row per admin for the e-mail twin.
		RETURN QUERY
		SELECT r.id, r.fam_id, p.id, ends_at
		  FROM public.profiles p
		 WHERE p.family_id = r.fam_id
		   AND p.is_admin
		   AND p.left_at IS NULL
		   AND p.user_id IS NOT NULL;
	END LOOP;
END;
$$;
