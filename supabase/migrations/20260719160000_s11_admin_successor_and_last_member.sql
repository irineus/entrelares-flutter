-- =============================================================================
-- S-11 (PR1, follow-up) — admin succession on exit + last-member family removal
--
-- Product decisions (July 2026):
--   1. If the leaving member is the ONLY admin and other members remain, they
--      must name a SUCCESSOR, who is promoted to admin BEFORE they leave (kept
--      the >= 1 admin invariant; previously the RPC just blocked with a message
--      and the promotion was a separate manual step).
--   2. If the leaving member is the LAST active member, leaving is no longer
--      blocked — it schedules the WHOLE FAMILY for removal (the no-consent case
--      of family deletion). Admin-initiated deletion of a family that still has
--      OTHER members (multi-party consent) remains PR2.
--
-- The 30-day grace, cancel and cron reuse PR1's machinery. New helper
-- purge_family_data() performs the ordered teardown (also the foundation PR2
-- will reuse for consent-based deletion). Corrective migration — the originals
-- already applied to dev; the RPC signature changes, so the old overload is
-- dropped first.
-- =============================================================================

-- ── 1. purge_family_data — ordered teardown of a whole family ────────────────
-- Returns the member auth uids for the cron to delete, then removes all the
-- family's rows. Idempotent (no-op if the family is already gone).

CREATE OR REPLACE FUNCTION public.purge_family_data(p_family_id bigint)
RETURNS SETOF uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
	PERFORM set_config('app.deletion_context', 'on', true);

	IF NOT EXISTS (SELECT 1 FROM public.families WHERE id = p_family_id) THEN
		RETURN;   -- already purged
	END IF;

	-- Hand back the auth user ids BEFORE deleting the profiles.
	RETURN QUERY
	SELECT p.user_id::uuid FROM public.profiles p
	WHERE p.family_id = p_family_id AND p.user_id IS NOT NULL;

	-- Ordered teardown (children first; notifications have no family_id).
	DELETE FROM public.notifications
	WHERE recipient_profile_id IN (SELECT id FROM public.profiles WHERE family_id = p_family_id);
	DELETE FROM public.account_logs       WHERE family_id = p_family_id;
	DELETE FROM public.swap_requests      WHERE family_id = p_family_id;
	DELETE FROM public.care_schedules     WHERE family_id = p_family_id;
	DELETE FROM public.activity_logs      WHERE family_id = p_family_id;
	DELETE FROM public.family_invitations WHERE family_id = p_family_id;
	DELETE FROM public.profiles           WHERE family_id = p_family_id;
	DELETE FROM public.families           WHERE id = p_family_id;
END;
$$;

ALTER FUNCTION public.purge_family_data(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purge_family_data(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_family_data(bigint) FROM anon;
REVOKE ALL ON FUNCTION public.purge_family_data(bigint) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.purge_family_data(bigint) TO service_role;

-- ── 2. request_account_deletion(p_new_admin_id) — succession + last member ───

DROP FUNCTION IF EXISTS public.request_account_deletion();

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

	-- Clear my FUTURE days.
	UPDATE public.care_schedules
	SET actual_parent_id = NULL, updated_at = timezone('utc', now())
	WHERE family_id = me.family_id AND schedule_date > today
	  AND actual_parent_id = me.id AND scheduled_parent_id <> me.id;

	DELETE FROM public.care_schedules
	WHERE family_id = me.family_id AND schedule_date > today
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

ALTER FUNCTION public.request_account_deletion(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.request_account_deletion(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_account_deletion(bigint) FROM anon;
GRANT EXECUTE ON FUNCTION public.request_account_deletion(bigint) TO authenticated, service_role;

-- ── 3. purge_expired_accounts — last member purges the whole family ──────────

CREATE OR REPLACE FUNCTION public.purge_expired_accounts()
RETURNS TABLE (user_id uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	r record;
BEGIN
	PERFORM set_config('app.deletion_context', 'on', true);

	FOR r IN
		SELECT p.id, p.user_id AS uid, p.family_id
		FROM public.profiles p
		WHERE p.left_at IS NOT NULL
		  AND p.user_id IS NOT NULL
		  AND p.deletion_scheduled_for IS NOT NULL
		  AND p.deletion_scheduled_for <= timezone('utc', now())
	LOOP
		IF public.active_member_count(r.family_id) = 0 THEN
			-- No active members left → purge the whole family (returns every
			-- member's auth uid; idempotent if a prior row already purged it).
			RETURN QUERY SELECT u FROM public.purge_family_data(r.family_id) AS u;
		ELSE
			-- Others remain → tombstone this member only (name kept for history).
			UPDATE public.profiles p
			SET email = 'removido+' || p.id || '@guarda.invalido'
			WHERE p.id = r.id;
			user_id := r.uid;
			RETURN NEXT;
		END IF;
	END LOOP;
END;
$$;
