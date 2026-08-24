-- U-13 — localizable notifications, part 2: the remaining NINE functions.
--
-- Part 1 (20260806140000) added the `params` column and proved the pattern on
-- auto_approve_expired. This file replicates it across every other function that
-- writes a notification, so no in-app text is left that only a Portuguese
-- speaker can read.
--
-- THE RULES, unchanged from the pilot:
--   · Each body below was copied from the LATEST migration that defines that
--     function (named above each block). `CREATE OR REPLACE` replaces the WHOLE
--     body, so starting from a remembered version silently deletes whatever a
--     later migration added — see the CLAUDE.md gotcha.
--   · The ONLY edit is adding `params` to the INSERTs.
--   · `params` carries VALUES, never sentences, plus a discriminator whenever
--     one `type` has more than one wording.
--   · The stored PT-BR title/message stay exactly as they were: they are the
--     fallback for every row written before this migration.
--
-- DISCRIMINATORS THIS FILE INTRODUCES (each one exists because the same `type`
-- is written with different copy, and without it a reader would get someone
-- else's sentence — worse than not translating, because it is false):
--   · family_deletion → kind: requested_self | requested_other | agreed |
--                             agreement_undone | refused | withdrawn | reminder
--   · account_deletion → kind: self | self_last | other_left
--   · swap_cancelled  → kind: member_left  (the CLIENT writes the same type
--                       with kind = by_requester — a real collision, not a
--                       theoretical one)
--   · email_cap_reached → tier: premium | free
--   · billing → kind: grace_warning  (the type is broad on purpose; future
--               billing notices add kinds instead of types)
--
-- The column order (recipient_profile_id, type, title, message, params, …) is
-- deliberate and uniform: NotificationParamsTests reads pg_proc.prosrc and
-- fails any INSERT into notifications that omits `params`, which is what keeps
-- a twelfth function from being forgotten later.

-- ── notify_member_joined ─────────────────────────────────────────────────────
-- From 20260719200000_s11_join_return_notifications.sql.

CREATE OR REPLACE FUNCTION public.notify_member_joined()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
	INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
	SELECT p.id, 'member_joined',
	       'Novo responsável na família',
	       NEW.full_name || ' juntou-se à família. Confira o calendário para incluí-lo no planejamento.',
	       jsonb_build_object('name', NEW.full_name)
	FROM public.profiles p
	WHERE p.family_id = NEW.family_id
	  AND p.id <> NEW.id
	  AND p.left_at IS NULL
	  AND p.user_id IS NOT NULL;

	RETURN NEW;
END;
$$;

ALTER FUNCTION public.notify_member_joined() OWNER TO postgres;

-- ── cancel_account_deletion ──────────────────────────────────────────────────
-- From 20260720170000_s11_persistent_color_slots.sql (the color-slot rules on
-- the UPDATE below are that migration's whole point — they must survive).

CREATE OR REPLACE FUNCTION public.cancel_account_deletion()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me public.profiles%ROWTYPE;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();
	IF me.id IS NULL OR me.left_at IS NULL THEN
		RAISE EXCEPTION 'Não há saída pendente para cancelar.' USING ERRCODE = 'check_violation';
	END IF;

	IF NOT public.is_elevated() THEN
		RAISE EXCEPTION 'ELEVATION_REQUIRED: Confirme sua senha para cancelar a saída.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	-- Return only if a seat is still free (the leaver does not count while
	-- left_at is set, so a full family means the seat was refilled).
	IF public.active_member_count(me.family_id) >= 4 THEN
		RAISE EXCEPTION 'A família já preencheu a vaga; não é possível cancelar a saída.'
			USING ERRCODE = 'check_violation';
	END IF;

	UPDATE public.profiles
	SET left_at = NULL,
	    deletion_scheduled_for = NULL,
	    color_slot = CASE
	        WHEN me.color_slot IS NOT NULL AND NOT EXISTS (
	            SELECT 1 FROM public.profiles a
	            WHERE a.family_id = me.family_id AND a.left_at IS NULL
	              AND a.user_id IS NOT NULL AND a.id <> me.id
	              AND a.color_slot = me.color_slot)
	        THEN me.color_slot                                   -- old color still free
	        ELSE public.next_free_color_slot(me.family_id) END   -- take the freed one
	WHERE id = me.id;

	INSERT INTO public.account_logs (family_id, actor_profile_id, target_profile_id, action)
	VALUES (me.family_id, me.id, me.id, 'account_deletion_cancelled');

	-- Heads-up to the other active members that the person is back.
	INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
	SELECT p.id, 'member_returned',
	       'Responsável voltou à família',
	       me.full_name || ' cancelou a saída e voltou à família.',
	       jsonb_build_object('name', me.full_name)
	FROM public.profiles p
	WHERE p.family_id = me.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL AND p.id <> me.id;
END;
$$;

ALTER FUNCTION public.cancel_account_deletion() OWNER TO postgres;

-- ── request_account_deletion ─────────────────────────────────────────────────
-- From 20260721150000_s11_family_deletion_consent.sql. Carries the family-
-- deletion block, the successor-admin rule (20260719160000) and the
-- today-counts-as-future clearing (20260720190000) — all three came from
-- DIFFERENT migrations and all three are in the body below.

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
		                          'date', to_char(sr.schedule_date, 'DD/MM/YYYY')),
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

ALTER FUNCTION public.request_account_deletion(bigint) OWNER TO postgres;

-- ── request_family_deletion ──────────────────────────────────────────────────
-- From 20260721150000_s11_family_deletion_consent.sql.

CREATE OR REPLACE FUNCTION public.request_family_deletion()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me       public.profiles%ROWTYPE;
	deadline timestamp with time zone := timezone('utc', now()) + interval '30 days';
	deadline_br text;
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

	-- Confirmation to the requester.
	INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
	VALUES (me.id, 'family_deletion',
	        'Exclusão da família solicitada',
	        'Você solicitou a exclusão da família. Se ninguém recusar até ' || deadline_br ||
	        ', todos os dados (calendário, histórico e contas) serão apagados definitivamente. ' ||
	        'Você pode retirar a solicitação a qualquer momento.',
	        jsonb_build_object('kind', 'requested_self', 'date', deadline_br));

	-- Heads-up to every other active member: silence = consent, refusal ends it.
	INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
	SELECT p.id, 'family_deletion',
	       'Exclusão da família solicitada',
	       me.full_name || ' solicitou a exclusão da família. Se ninguém recusar até ' || deadline_br ||
	       ', TODOS os dados (calendário, histórico e contas de todos) serão apagados definitivamente. ' ||
	       'Você pode recusar em Perfil > Exclusão da família — qualquer recusa cancela a exclusão.',
	       jsonb_build_object('kind', 'requested_other', 'name', me.full_name, 'date', deadline_br)
	FROM public.profiles p
	WHERE p.family_id = me.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL AND p.id <> me.id;
END;
$$;

ALTER FUNCTION public.request_family_deletion() OWNER TO postgres;

-- ── respond_family_deletion ──────────────────────────────────────────────────
-- From 20260721270000_s11_family_deletion_unanimity.sql — the LATER file, which
-- added the NULL "undo my agreement" branch that 20260721150000 does not have.

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

		INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
		VALUES (req.requested_by, 'family_deletion',
		        'Resposta à exclusão da família',
		        me.full_name || ' desfez a concordância com a exclusão da família (voltou a aguardar).',
		        jsonb_build_object('kind', 'agreement_undone', 'name', me.full_name));
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

		INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
		VALUES (req.requested_by, 'family_deletion',
		        'Resposta à exclusão da família',
		        me.full_name || ' concordou com a exclusão da família.',
		        jsonb_build_object('kind', 'agreed', 'name', me.full_name));
	ELSE
		UPDATE public.family_deletion_requests
		SET status = 'refused', resolved_at = timezone('utc', now()), resolved_by = me.id
		WHERE id = req.id;

		INSERT INTO public.account_logs (family_id, actor_profile_id, action)
		VALUES (me.family_id, me.id, 'family_deletion_refused');

		-- Everyone (requester included) learns the family continues.
		INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
		SELECT p.id, 'family_deletion',
		       'Exclusão da família cancelada',
		       me.full_name || ' recusou a exclusão da família. A solicitação foi encerrada e a família continua.',
		       jsonb_build_object('kind', 'refused', 'name', me.full_name)
		FROM public.profiles p
		WHERE p.family_id = me.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL;
	END IF;
END;
$$;

ALTER FUNCTION public.respond_family_deletion(boolean) OWNER TO postgres;

-- ── withdraw_family_deletion ─────────────────────────────────────────────────
-- From 20260721150000_s11_family_deletion_consent.sql.

CREATE OR REPLACE FUNCTION public.withdraw_family_deletion()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me  public.profiles%ROWTYPE;
	req public.family_deletion_requests%ROWTYPE;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();
	IF me.id IS NULL THEN
		RAISE EXCEPTION 'Perfil não encontrado.' USING ERRCODE = 'check_violation';
	END IF;

	SELECT * INTO req FROM public.family_deletion_requests
	WHERE family_id = me.family_id AND status = 'pending';
	IF req.id IS NULL THEN
		RAISE EXCEPTION 'Não há solicitação de exclusão da família pendente.'
			USING ERRCODE = 'check_violation';
	END IF;
	IF req.requested_by <> me.id THEN
		RAISE EXCEPTION 'Somente quem solicitou a exclusão pode retirá-la.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF NOT public.is_elevated() THEN
		RAISE EXCEPTION 'ELEVATION_REQUIRED: Confirme sua senha para retirar a solicitação.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	UPDATE public.family_deletion_requests
	SET status = 'withdrawn', resolved_at = timezone('utc', now()), resolved_by = me.id
	WHERE id = req.id;

	INSERT INTO public.account_logs (family_id, actor_profile_id, action)
	VALUES (me.family_id, me.id, 'family_deletion_withdrawn');

	INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
	SELECT p.id, 'family_deletion',
	       'Exclusão da família retirada',
	       me.full_name || ' retirou a solicitação de exclusão da família. A família continua normalmente.',
	       jsonb_build_object('kind', 'withdrawn', 'name', me.full_name)
	FROM public.profiles p
	WHERE p.family_id = me.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL;
END;
$$;

ALTER FUNCTION public.withdraw_family_deletion() OWNER TO postgres;

-- ── family_deletion_reminders_due ────────────────────────────────────────────
-- From 20260721150000_s11_family_deletion_consent.sql.

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
		                          'date', to_char(r.scheduled_for AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY'))
		FROM public.profiles p
		WHERE p.family_id = r.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL;

		request_id := r.id;
		requester_profile_id := r.requested_by;
		RETURN NEXT;
	END LOOP;
END;
$$;

ALTER FUNCTION public.family_deletion_reminders_due() OWNER TO postgres;

-- ── notify_family_email_cap + consume_email_quota ────────────────────────────
-- From 20260724160000_f38_email_quota_gate.sql.
--
-- This pair is the one structural change in the file: notify_family_email_cap
-- receives the title and message from its CALLER, so it needs a params argument
-- too — and `CREATE OR REPLACE` cannot change an argument list (it would create
-- an overload and leave the old 4-arg function callable). Hence DROP + CREATE,
-- with consume_email_quota rewritten in the same migration so the two never
-- disagree about the signature.

DROP FUNCTION IF EXISTS public.notify_family_email_cap(bigint, text, text, text);

CREATE OR REPLACE FUNCTION public.notify_family_email_cap(
	p_family_id bigint, p_type text, p_title text, p_message text, p_params jsonb DEFAULT NULL)
RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path TO 'public'
AS $$
	INSERT INTO public.notifications (recipient_profile_id, type, title, message, params)
	SELECT p.id, p_type, p_title, p_message, p_params
	FROM public.profiles p
	WHERE p.family_id = p_family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL;
$$;

ALTER FUNCTION public.notify_family_email_cap(bigint, text, text, text, jsonb) OWNER TO postgres;

CREATE OR REPLACE FUNCTION public.consume_email_quota(p_family_id bigint)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	is_prem boolean;
	cap     int;
	warn_at int;
	last_at int;
	ym      text := to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM');
	cur     int;
BEGIN
	is_prem := public.is_premium(p_family_id);
	-- Per-tier cap — nothing is truly unlimited: premium runs against a HIGH
	-- anti-abuse cap. Both tiers are counted and enforced (T-41 config).
	cap     := CASE WHEN is_prem THEN public.setting_int('email_cap_premium', 10000)
	                             ELSE public.setting_int('email_cap_free', 100) END;
	warn_at := cap * 4 / 5;   -- 80% heads-up
	last_at := cap - 1;       -- one slot left; the free warning takes it

	-- Atomically consume one unit while under the cap. A NULL return means the
	-- row was already at the cap (the counter never climbs past it).
	INSERT INTO public.email_usage (family_id, year_month, sent_count)
	VALUES (p_family_id, ym, 1)
	ON CONFLICT (family_id, year_month) DO UPDATE
		SET sent_count = email_usage.sent_count + 1
		WHERE email_usage.sent_count < cap
	RETURNING sent_count INTO cur;

	IF cur IS NULL THEN
		-- Over the cap (either tier): skip the real e-mail. First denial → one
		-- in-app notification (tier-aware — no "upgrade" nudge for premium).
		UPDATE public.email_usage SET upsell_notified = true
		WHERE family_id = p_family_id AND year_month = ym AND upsell_notified = false;
		IF FOUND THEN
			IF is_prem THEN
				-- U-13: one type, two wordings — `tier` is the discriminator.
				PERFORM public.notify_family_email_cap(p_family_id, 'email_cap_reached',
					'Limite de e-mails do mês atingido',
					'Sua família atingiu o limite de e-mails deste mês. As notificações aqui no app seguem normais.',
					jsonb_build_object('tier', 'premium'));
			ELSE
				PERFORM public.notify_family_email_cap(p_family_id, 'email_cap_reached',
					'Limite de e-mails do plano gratuito',
					'Sua família atingiu o limite de e-mails deste mês no plano gratuito. As notificações aqui no app seguem normais — ative o Premium para um limite bem maior.',
					jsonb_build_object('tier', 'free'));
			END IF;
		END IF;
		RETURN 'denied';
	END IF;

	-- Proactive heads-ups are FREE-tier conversion nudges only — premium just runs
	-- against its high anti-abuse cap, with no upsell.
	IF NOT is_prem THEN
		-- Last-e-mail heads-up: the warning e-mail itself takes the final slot, so
		-- it is literally the last e-mail of the month.
		IF cur >= last_at THEN
			UPDATE public.email_usage SET warned_last = true, sent_count = cap
			WHERE family_id = p_family_id AND year_month = ym AND warned_last = false;
			IF FOUND THEN
				PERFORM public.notify_family_email_cap(p_family_id, 'email_cap_last',
					'Último e-mail do mês',
					'Este é o último e-mail do mês no plano gratuito. As notificações aqui no app seguem normais — ative o Premium para um limite bem maior.',
					jsonb_build_object('tier', 'free'));
				RETURN 'warn_last';
			END IF;
			RETURN 'allowed';   -- already warned this month
		END IF;

		-- 80% heads-up (does NOT consume a slot).
		IF cur >= warn_at THEN
			UPDATE public.email_usage SET warned_80 = true
			WHERE family_id = p_family_id AND year_month = ym AND warned_80 = false;
			IF FOUND THEN
				PERFORM public.notify_family_email_cap(p_family_id, 'email_cap_80',
					'E-mails do mês em 80%',
					'Sua família já usou 80% dos e-mails deste mês (plano gratuito). As notificações aqui no app seguem sem limite — ative o Premium para um limite bem maior.',
					jsonb_build_object('tier', 'free'));
				RETURN 'warn_80';
			END IF;
			RETURN 'allowed';
		END IF;
	END IF;

	RETURN 'allowed';
END;
$$;

ALTER FUNCTION public.consume_email_quota(bigint) OWNER TO postgres;

-- Grants restated: DROP took the old function's ACL with it, and CREATE OR
-- REPLACE on consume_email_quota keeps its own — restating both is harmless and
-- makes this file readable on its own.
REVOKE ALL ON FUNCTION public.notify_family_email_cap(bigint, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.notify_family_email_cap(bigint, text, text, text, jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.consume_email_quota(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_email_quota(bigint) TO service_role;

-- ── billing_grace_warnings_due ───────────────────────────────────────────────
-- From 20260731110000_s15_billing_grace_warning.sql.

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
		                          'date', to_char(ends_at AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY'))
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

ALTER FUNCTION public.billing_grace_warnings_due() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.billing_grace_warnings_due() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_grace_warnings_due() TO service_role;
