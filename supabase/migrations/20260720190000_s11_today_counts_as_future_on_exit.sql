-- =============================================================================
-- S-11 (QA) — TODAY counts as a future day when clearing a departed member
--
-- The exit cleanup cleared only strictly-future days (schedule_date > today),
-- so if the leaver was the planned parent for TODAY, that day stayed assigned
-- to them — and a regular member cannot reassign a day's planned parent
-- (S-09), so it got stuck showing the departed member. Decision (product
-- owner, July 2026): for the treatment of a departed member's days, the
-- CURRENT day counts as future regardless of the handoff time — clear it too.
--
-- Only the two cleanup predicates change (> today → >= today); the rest is
-- VERBATIM from 20260719160000.
-- =============================================================================

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

		INSERT INTO public.notifications (recipient_profile_id, type, title, message, swap_request_id)
		SELECT p.id, 'swap_cancelled',
		       'Solicitação cancelada',
		       me.full_name || ' saiu da família e a solicitação de troca de ' ||
		           to_char(sr.schedule_date, 'DD/MM/YYYY') || ' foi cancelada.',
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
	INSERT INTO public.notifications (recipient_profile_id, type, title, message)
	VALUES (me.id, 'account_deletion',
	        CASE WHEN is_last THEN 'Exclusão da família solicitada' ELSE 'Saída solicitada' END,
	        CASE WHEN is_last
	             THEN 'Como você é o único responsável, sua saída removerá a família e todos os dados após 30 dias. Você pode cancelar nesse período.'
	             ELSE 'Sua saída da família foi solicitada. Você tem 30 dias para cancelar; após esse prazo a conta será apagada.' END);

	-- Heads-up to the other active members (only when the family stays).
	IF NOT is_last THEN
		INSERT INTO public.notifications (recipient_profile_id, type, title, message)
		SELECT p.id, 'account_deletion',
		       'Um responsável saiu',
		       me.full_name || ' saiu da família. Os dias futuros dessa pessoa foram liberados — '
		           || 'verifique o calendário e reatribua o que for necessário.'
		FROM public.profiles p
		WHERE p.family_id = me.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL AND p.id <> me.id;
	END IF;
END;
$$;
