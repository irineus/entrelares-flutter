-- =============================================================================
-- S-11 PR2 (QA improvements, July 2026) — unanimity flow for family deletion
--
-- Product decisions from the phase-5 QA pass (supersede the earlier "the
-- 30-day window always runs in full"):
--   · A member who AGREED may UNDO the agreement (back to "aguardando") —
--     respond_family_deletion(NULL) deletes their response row. Refusal stays
--     the strong action that ends the request.
--   · When EVERY other active member has explicitly agreed, ANY active admin
--     may EXECUTE the deletion immediately (sudo-gated): the new
--     execute_family_deletion() brings scheduled_for to now, and the client
--     invokes the purge-deleted function right after — reusing the exact
--     purge/GoTrue/farewell-e-mail machinery of the cron.
--   · Agreeing stays sudo-free (decision: the warning text carries the
--     consequence; the destructive EXECUTION is the sudo-gated act).
-- =============================================================================

-- ── 1. respond_family_deletion — p_agree NULL = undo my agreement ────────────
-- Body evolved from 20260721150000; the NULL branch is new.

CREATE OR REPLACE FUNCTION public.respond_family_deletion(p_agree boolean)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me  public.profiles%ROWTYPE;
	req public.family_deletion_requests%ROWTYPE;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();
	IF me.id IS NULL OR me.left_at IS NOT NULL THEN
		RAISE EXCEPTION 'Perfil não encontrado ou em processo de saída.' USING ERRCODE = 'check_violation';
	END IF;

	SELECT * INTO req FROM public.family_deletion_requests
	WHERE family_id = me.family_id AND status = 'pending';
	IF req.id IS NULL THEN
		RAISE EXCEPTION 'Não há solicitação de exclusão da família pendente.'
			USING ERRCODE = 'check_violation';
	END IF;
	IF req.requested_by = me.id THEN
		RAISE EXCEPTION 'Quem solicitou a exclusão pode apenas retirar a solicitação.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- QA: NULL = undo my agreement — back to "aguardando" (holds off the
	-- unanimity execution without killing the whole request).
	IF p_agree IS NULL THEN
		DELETE FROM public.family_deletion_responses
		WHERE request_id = req.id AND profile_id = me.id;

		INSERT INTO public.account_logs (family_id, actor_profile_id, action)
		VALUES (me.family_id, me.id, 'family_deletion_agreement_undone');

		INSERT INTO public.notifications (recipient_profile_id, type, title, message)
		VALUES (req.requested_by, 'family_deletion',
		        'Resposta à exclusão da família',
		        me.full_name || ' desfez a concordância com a exclusão da família (voltou a aguardar).');
		RETURN;
	END IF;

	-- Recorded for the status panel; a member may change their answer while
	-- the request is pending (agree → refuse included — refusal always wins).
	INSERT INTO public.family_deletion_responses (request_id, profile_id, agreed)
	VALUES (req.id, me.id, p_agree)
	ON CONFLICT (request_id, profile_id)
	DO UPDATE SET agreed = EXCLUDED.agreed, responded_at = timezone('utc', now());

	IF p_agree THEN
		INSERT INTO public.account_logs (family_id, actor_profile_id, action)
		VALUES (me.family_id, me.id, 'family_deletion_agreed');

		INSERT INTO public.notifications (recipient_profile_id, type, title, message)
		VALUES (req.requested_by, 'family_deletion',
		        'Resposta à exclusão da família',
		        me.full_name || ' concordou com a exclusão da família.');
	ELSE
		UPDATE public.family_deletion_requests
		SET status = 'refused', resolved_at = timezone('utc', now()), resolved_by = me.id
		WHERE id = req.id;

		INSERT INTO public.account_logs (family_id, actor_profile_id, action)
		VALUES (me.family_id, me.id, 'family_deletion_refused');

		-- Everyone (requester included) learns the family continues.
		INSERT INTO public.notifications (recipient_profile_id, type, title, message)
		SELECT p.id, 'family_deletion',
		       'Exclusão da família cancelada',
		       me.full_name || ' recusou a exclusão da família. A solicitação foi encerrada e a família continua.'
		FROM public.profiles p
		WHERE p.family_id = me.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL;
	END IF;
END;
$$;

ALTER FUNCTION public.respond_family_deletion(boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.respond_family_deletion(boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.respond_family_deletion(boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.respond_family_deletion(boolean) TO authenticated, service_role;

-- ── 2. execute_family_deletion — any active admin, sudo, unanimity ───────────
-- Validates and brings scheduled_for to NOW; the actual teardown stays with
-- purge_expired_family_deletions (invoked right after via the purge-deleted
-- function by the client), so purge + GoTrue cleanup + farewell e-mail reuse
-- the exact machinery the cron runs.

CREATE OR REPLACE FUNCTION public.execute_family_deletion()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me      public.profiles%ROWTYPE;
	req     public.family_deletion_requests%ROWTYPE;
	waiting int;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();
	IF me.id IS NULL OR me.left_at IS NOT NULL THEN
		RAISE EXCEPTION 'Perfil não encontrado ou em processo de saída.' USING ERRCODE = 'check_violation';
	END IF;
	IF NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores podem executar a exclusão da família.'
			USING ERRCODE = 'check_violation';
	END IF;

	SELECT * INTO req FROM public.family_deletion_requests
	WHERE family_id = me.family_id AND status = 'pending';
	IF req.id IS NULL THEN
		RAISE EXCEPTION 'Não há solicitação de exclusão da família pendente.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- S-10: destructive final act — fresh password confirmation required.
	IF NOT public.is_elevated() THEN
		RAISE EXCEPTION 'ELEVATION_REQUIRED: Confirme sua senha para executar a exclusão da família.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	-- Unanimity: every active member other than the requester has an explicit
	-- AGREED response (silence is consent only at the 30-day deadline — the
	-- immediate path demands the explicit yes of everyone).
	SELECT count(*) INTO waiting
	FROM public.profiles p
	WHERE p.family_id = me.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL
	  AND p.id <> req.requested_by
	  AND NOT EXISTS (SELECT 1 FROM public.family_deletion_responses r
	                  WHERE r.request_id = req.id AND r.profile_id = p.id AND r.agreed);

	IF waiting > 0 THEN
		RAISE EXCEPTION 'A exclusão imediata exige a concordância explícita de todos os responsáveis (% ainda não concordaram).', waiting
			USING ERRCODE = 'check_violation';
	END IF;

	UPDATE public.family_deletion_requests
	SET scheduled_for = timezone('utc', now())
	WHERE id = req.id;

	INSERT INTO public.account_logs (family_id, actor_profile_id, action)
	VALUES (me.family_id, me.id, 'family_deletion_executed');
END;
$$;

ALTER FUNCTION public.execute_family_deletion() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.execute_family_deletion() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.execute_family_deletion() FROM anon;
GRANT EXECUTE ON FUNCTION public.execute_family_deletion() TO authenticated, service_role;
