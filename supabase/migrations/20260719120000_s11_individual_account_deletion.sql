-- =============================================================================
-- S-11 (PR1) — Right to erasure, part 1: individual account deletion
-- (leave the family) with a 30-day grace period. LGPD art. 18, V/VI.
--
-- Design (settled with the product owner, July 2026):
--   · PAST is immutable — the calendar/audit/resolved-swap history KEEPS the
--     leaving member's full name (anti-tamper: who did what stays knowable;
--     retention grounded in LGPD art. 16 — legal defense; documented in S-13).
--     Only the e-mail is scrubbed and the GoTrue user is deleted, and only at
--     the END of the grace period.
--   · FUTURE is cleared at request time: days the member PLANS are deleted
--     (must be re-planned anyway); days where they are the real parent of an
--     approved swap revert to the planned parent; their pending swaps cancel.
--   · The seat frees IMMEDIATELY on request (an admin may invite a
--     replacement at once).
--   · 30-day grace: the member logs in only to a "restore / wait" screen and
--     may cancel — restore succeeds only if a seat is still free.
--   · After 30 days a scheduled job (Edge Function cron `purge-deleted`)
--     deletes the GoTrue user and turns the profile into a permanent
--     tombstone (name kept, e-mail scrubbed, user_id NULL).
--
--   LAST-member exit and WHOLE-family deletion are PR2 (they need the
--   consent machinery); here the RPC refuses if no other active member would
--   remain, pointing the user to "Excluir família" (PR2).
-- =============================================================================

-- ── 1. Tombstone columns + nullable user_id (FK survives GoTrue delete) ──────

ALTER TABLE public.profiles
	ADD COLUMN IF NOT EXISTS left_at                timestamp with time zone,
	ADD COLUMN IF NOT EXISTS deletion_scheduled_for timestamp with time zone;

-- The hard purge deletes auth.users; the profile row must survive (history FK)
-- with user_id nulled instead of blocking the delete.
ALTER TABLE public.profiles ALTER COLUMN user_id DROP NOT NULL;
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_user_id_fkey;
ALTER TABLE public.profiles
	ADD CONSTRAINT profiles_user_id_fkey
	FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE SET NULL;

-- ── 2. Active-member helper (a seat is taken only by a live, present member) ──
-- A leaving member (left_at set) and a tombstone (user_id NULL) hold no seat.

CREATE OR REPLACE FUNCTION public.active_member_count(p_family_id bigint)
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
	SELECT count(*)::int FROM public.profiles
	WHERE family_id = p_family_id
	  AND user_id IS NOT NULL
	  AND left_at IS NULL;
$$;

ALTER FUNCTION public.active_member_count(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.active_member_count(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.active_member_count(bigint) TO authenticated, service_role;

-- ── 3. Deletion-context bypass in the day-protection trigger ─────────────────
-- Clearing the leaving member's FUTURE days (deleting planned days, reverting
-- their approved swaps) would trip the S-09 protections. Only the SECURITY
-- DEFINER deletion RPCs set this transaction-local GUC; a client cannot set a
-- GUC and smuggle a care_schedules write into the same PostgREST transaction,
-- so it is not a bypass vector. Body otherwise VERBATIM from
-- 20260714225153_protect_scheduled_parent.

CREATE OR REPLACE FUNCTION public.enforce_day_protection()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
	cur_profile_id bigint;
	cur_is_admin   boolean := false;
	today          date;
	the_date       date;
	fam            bigint;
	is_frozen      boolean := false;
	is_target      boolean := false;
BEGIN
	-- S-11: controlled erasure cleanup — see migration header.
	IF current_setting('app.deletion_context', true) = 'on' THEN
		RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
	END IF;

	-- System context (service_role: F-24 auto-approval, migrations): unrestricted.
	SELECT id, is_admin INTO cur_profile_id, cur_is_admin
	FROM public.profiles WHERE user_id = auth.uid();
	IF cur_profile_id IS NULL THEN
		RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
	END IF;

	today    := (now() AT TIME ZONE 'America/Sao_Paulo')::date;
	the_date := COALESCE(NEW.schedule_date, OLD.schedule_date);
	fam      := COALESCE(NEW.family_id, OLD.family_id,
	                     (SELECT family_id FROM public.profiles WHERE id = NEW.scheduled_parent_id));

	SELECT bool_or(true), bool_or(target_profile_id = cur_profile_id)
	INTO is_frozen, is_target
	FROM public.swap_requests
	WHERE family_id = fam AND schedule_date = the_date
	  AND status IN ('pending', 'revert_pending');
	is_frozen := COALESCE(is_frozen, false);
	is_target := COALESCE(is_target, false);

	-- F-12: frozen days are untouchable, except by the pending request's target
	-- (who legitimately applies the calendar change while approving) or an admin.
	IF TG_OP IN ('UPDATE', 'DELETE') AND is_frozen AND NOT is_target AND NOT cur_is_admin THEN
		RAISE EXCEPTION 'Este dia tem uma solicitação pendente e não pode ser alterado.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- F-13: past days are immutable (the target exemption keeps overdue
	-- workflow completions working; admins may bypass — F-14).
	IF the_date < today AND NOT cur_is_admin AND NOT is_target THEN
		RAISE EXCEPTION 'Dias passados não podem ser alterados.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- S-09: the PLANNED schedule is immutable for regular users — changing the
	-- scheduled parent of an assigned day requires an admin (explicit, audited)
	-- or the pending revert's target restoring the pre-edit snapshot (F-26).
	-- Responsibility changes for a day belong to the swap workflow (actual).
	IF TG_OP = 'UPDATE'
	   AND NEW.scheduled_parent_id IS DISTINCT FROM OLD.scheduled_parent_id
	   AND NOT cur_is_admin AND NOT is_target THEN
		RAISE EXCEPTION 'O responsável planejado só pode ser alterado por administradores; para mudar quem fica com a criança, use o fluxo de troca.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF TG_OP = 'DELETE' THEN
		-- F-12: a day with an approved swap cannot be deleted (admin may — F-14).
		IF OLD.actual_parent_id IS NOT NULL AND OLD.actual_parent_id <> OLD.scheduled_parent_id
		   AND NOT cur_is_admin AND NOT is_target THEN
			RAISE EXCEPTION 'Dias com troca aprovada não podem ser apagados.'
				USING ERRCODE = 'check_violation';
		END IF;
		RETURN OLD;
	END IF;

	-- Swap-workflow enforcement (applies to admins too — F-14 decision):
	-- creating or undoing a swap directly is forbidden; only the pending
	-- request's target (applying an approval) may write such a change.
	-- Exception: admins may correct the actual parent of PAST days (historical
	-- fixes — the workflow cannot exist for past dates), never future ones.
	IF cur_is_admin AND the_date < today THEN
		RETURN NEW;
	END IF;

	IF TG_OP = 'INSERT' THEN
		IF NEW.actual_parent_id IS NOT NULL AND NEW.actual_parent_id <> NEW.scheduled_parent_id THEN
			RAISE EXCEPTION 'Alterações do responsável real devem passar pelo fluxo de aprovação.'
				USING ERRCODE = 'check_violation';
		END IF;
	ELSIF NEW.actual_parent_id IS DISTINCT FROM OLD.actual_parent_id AND NOT is_target THEN
		IF (OLD.actual_parent_id IS NOT NULL AND OLD.actual_parent_id <> OLD.scheduled_parent_id)  -- undo/alter an approved swap
		   OR (NEW.actual_parent_id IS NOT NULL AND NEW.actual_parent_id <> NEW.scheduled_parent_id) -- create a swap directly
		THEN
			RAISE EXCEPTION 'Alterações do responsável real devem passar pelo fluxo de aprovação.'
				USING ERRCODE = 'check_violation';
		END IF;
	END IF;

	RETURN NEW;
END;
$$;

-- ── 4. Skip account-audit noise during erasure ──────────────────────────────
-- The hard purge scrubs the e-mail; that legitimate change should not spawn an
-- 'email_changed' governance row. Body otherwise VERBATIM from
-- 20260718113000_s10_sudo_elevation_account_logs.

CREATE OR REPLACE FUNCTION public.audit_profile_account_changes()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	actor bigint;
BEGIN
	-- S-11: erasure cleanup is not an auditable account edit.
	IF current_setting('app.deletion_context', true) = 'on' THEN
		RETURN NEW;
	END IF;

	SELECT id INTO actor FROM public.profiles WHERE user_id = auth.uid();

	IF NEW.is_admin IS DISTINCT FROM OLD.is_admin THEN
		INSERT INTO public.account_logs (family_id, actor_profile_id, target_profile_id, action, old_value, new_value)
		VALUES (OLD.family_id, actor, OLD.id,
		        CASE WHEN NEW.is_admin THEN 'admin_granted' ELSE 'admin_revoked' END,
		        OLD.is_admin::text, NEW.is_admin::text);
	END IF;

	IF NEW.role_id IS DISTINCT FROM OLD.role_id THEN
		INSERT INTO public.account_logs (family_id, actor_profile_id, target_profile_id, action, old_value, new_value)
		VALUES (OLD.family_id, actor, OLD.id, 'role_changed',
		        (SELECT role FROM public.roles WHERE id = OLD.role_id),
		        (SELECT role FROM public.roles WHERE id = NEW.role_id));
	END IF;

	IF NEW.full_name IS DISTINCT FROM OLD.full_name THEN
		INSERT INTO public.account_logs (family_id, actor_profile_id, target_profile_id, action, old_value, new_value)
		VALUES (OLD.family_id, actor, OLD.id, 'name_changed', OLD.full_name, NEW.full_name);
	END IF;

	IF NEW.email IS DISTINCT FROM OLD.email THEN
		INSERT INTO public.account_logs (family_id, actor_profile_id, target_profile_id, action, old_value, new_value)
		VALUES (OLD.family_id, COALESCE(actor, OLD.id), OLD.id, 'email_changed', OLD.email, NEW.email);
	END IF;

	RETURN NEW;
END;
$$;

-- ── 5. Seat counting excludes leaving members / tombstones ───────────────────
-- create_invitation: members counted via active_member_count. Body otherwise
-- VERBATIM from 20260717023010_multi_caregiver_membership.

CREATE OR REPLACE FUNCTION public.create_invitation(p_email text, p_role_id bigint)
RETURNS TABLE (invitation_id bigint, token uuid, expires_at timestamp with time zone)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
	me        public.profiles%ROWTYPE;
	inv       public.family_invitations%ROWTYPE;
	max_seats constant int := 4;
	taken     int;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();

	IF me.id IS NULL OR NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores da família podem enviar convites.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF EXISTS (SELECT 1 FROM public.profiles
	           WHERE lower(email) = lower(trim(p_email))
	             AND user_id IS NOT NULL AND left_at IS NULL) THEN
		RAISE EXCEPTION 'Este e-mail já possui cadastro no aplicativo.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF NOT EXISTS (SELECT 1 FROM public.roles WHERE id = p_role_id) THEN
		RAISE EXCEPTION 'Papel inválido.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- Resend semantics: revoke this e-mail's previous open invitation BEFORE
	-- counting seats, so a resend never trips the cap it already occupies.
	UPDATE public.family_invitations
	SET revoked_at = timezone('utc', now())
	WHERE family_id = me.family_id
	  AND lower(email) = lower(trim(p_email))
	  AND accepted_at IS NULL AND revoked_at IS NULL;

	-- Seats taken = ACTIVE members + open (pending, unexpired) invitations.
	SELECT public.active_member_count(me.family_id)
	     + (SELECT count(*) FROM public.family_invitations fi
	        WHERE fi.family_id = me.family_id
	          AND fi.accepted_at IS NULL AND fi.revoked_at IS NULL
	          AND fi.expires_at > timezone('utc', now()))
	INTO taken;

	IF taken >= max_seats THEN
		RAISE EXCEPTION 'Esta família já atingiu o limite de % responsáveis (contando convites pendentes).', max_seats
			USING ERRCODE = 'check_violation';
	END IF;

	INSERT INTO public.family_invitations (family_id, email, role_id, invited_by)
	VALUES (me.family_id, lower(trim(p_email)), p_role_id, me.id)
	RETURNING * INTO inv;

	RETURN QUERY SELECT inv.id, inv.token, inv.expires_at;
END;
$$;

-- handle_new_user: the invitee-path seat re-check counts ACTIVE members. Body
-- otherwise VERBATIM from 20260717023010_multi_caregiver_membership.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	meta_name   text;
	meta_role   text;
	meta_token  text;
	meta_family text;
	inv         public.family_invitations%ROWTYPE;
	fam_id      bigint;
	new_role_id bigint;
	admin_flag  boolean;
	max_seats   constant int := 4;
BEGIN
	-- Idempotency: never duplicate a profile (e.g. trigger re-run).
	IF EXISTS (SELECT 1 FROM public.profiles WHERE user_id = NEW.id) THEN
		RETURN NEW;
	END IF;

	meta_name   := NULLIF(trim(NEW.raw_user_meta_data ->> 'full_name'), '');
	meta_role   := NULLIF(trim(NEW.raw_user_meta_data ->> 'role'), '');
	meta_token  := NULLIF(trim(NEW.raw_user_meta_data ->> 'invite_token'), '');
	meta_family := NULLIF(trim(NEW.raw_user_meta_data ->> 'family_name'), '');

	-- Fallback: e-mail local part (metadata should always carry the name).
	IF meta_name IS NULL THEN
		meta_name := split_part(NEW.email, '@', 1);
	END IF;

	IF meta_token IS NOT NULL THEN
		-- INVITEE: token must be valid, pending and issued for this e-mail.
		-- (a malformed token must fail with the friendly message, not a cast error)
		BEGIN
			SELECT * INTO inv
			FROM public.family_invitations
			WHERE token = meta_token::uuid
			  AND accepted_at IS NULL
			  AND revoked_at  IS NULL
			  AND expires_at  > timezone('utc', now())
			  AND lower(email) = lower(NEW.email);
		EXCEPTION WHEN invalid_text_representation THEN
			inv := NULL;
		END;

		IF inv.id IS NULL THEN
			RAISE EXCEPTION 'Convite inválido, expirado ou emitido para outro e-mail.'
				USING ERRCODE = 'check_violation';
		END IF;

		-- The family may have completed meanwhile (parallel invites racing).
		IF public.active_member_count(inv.family_id) >= max_seats THEN
			RAISE EXCEPTION 'Esta família já atingiu o limite de % responsáveis.', max_seats
				USING ERRCODE = 'check_violation';
		END IF;

		fam_id      := inv.family_id;
		new_role_id := inv.role_id;
		admin_flag  := false;

		UPDATE public.family_invitations
		SET accepted_at = timezone('utc', now())
		WHERE id = inv.id;
	ELSE
		-- FOUNDER: creates the family and becomes its admin (F-14 decision).
		IF meta_role IS NULL THEN
			RAISE EXCEPTION 'Selecione o seu papel para criar a conta.'
				USING ERRCODE = 'check_violation';
		END IF;

		-- F-27: catalog-driven lookup — the client sends the canonical slug;
		-- the PT-BR label is accepted as a fallback vocabulary.
		SELECT id INTO new_role_id
		FROM public.roles
		WHERE lower(trim(role)) = lower(meta_role)
		   OR lower(trim(label_pt)) = lower(meta_role)
		ORDER BY id
		LIMIT 1;
		IF new_role_id IS NULL THEN
			RAISE EXCEPTION 'Papel inválido: %.', meta_role
				USING ERRCODE = 'check_violation';
		END IF;

		-- Family name chosen by the founder; neutral fallback for safety
		-- (the register form makes the field required).
		INSERT INTO public.families (name)
		VALUES (COALESCE(meta_family, 'Família ' || meta_name))
		RETURNING id INTO fam_id;

		admin_flag := true;
	END IF;

	INSERT INTO public.profiles (user_id, full_name, role_id, email, family_id, is_admin)
	VALUES (NEW.id, meta_name, new_role_id, NEW.email, fam_id, admin_flag);

	RETURN NEW;
END;
$$;

-- ── 6. request_account_deletion — leave the family (sudo-gated) ──────────────

CREATE OR REPLACE FUNCTION public.request_account_deletion()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me           public.profiles%ROWTYPE;
	today        date := (now() AT TIME ZONE 'America/Sao_Paulo')::date;
	other_active int;
	sr           record;
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

	-- Last active member → this is a whole-family deletion (PR2).
	IF other_active <= 0 THEN
		RAISE EXCEPTION 'Você é o único responsável ativo. Use "Excluir família" para apagar todos os dados.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- Keep the >= 1 admin invariant: the last admin must promote someone first.
	IF me.is_admin AND NOT EXISTS (
		SELECT 1 FROM public.profiles
		WHERE family_id = me.family_id AND is_admin AND left_at IS NULL
		  AND user_id IS NOT NULL AND id <> me.id
	) THEN
		RAISE EXCEPTION 'Você é o único administrador. Promova outro responsável a administrador antes de sair.'
			USING ERRCODE = 'check_violation';
	END IF;

	PERFORM set_config('app.deletion_context', 'on', true);

	-- Cancel my pending swap requests (as requester or counterpart) and notify
	-- the other involved party so a frozen day never dangles on a leaver.
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

	-- Clear my FUTURE days: planned days deleted; approved swaps where I am the
	-- real parent revert to the planned parent (preserving others' plans).
	UPDATE public.care_schedules
	SET actual_parent_id = NULL, updated_at = timezone('utc', now())
	WHERE family_id = me.family_id AND schedule_date > today
	  AND actual_parent_id = me.id AND scheduled_parent_id <> me.id;

	DELETE FROM public.care_schedules
	WHERE family_id = me.family_id AND schedule_date > today
	  AND scheduled_parent_id = me.id;

	-- Enter the leaving state — the seat frees immediately (active_member_count
	-- excludes left_at rows), the GoTrue user survives so I can still cancel.
	UPDATE public.profiles
	SET left_at = timezone('utc', now()),
	    deletion_scheduled_for = timezone('utc', now()) + interval '30 days'
	WHERE id = me.id;

	INSERT INTO public.account_logs (family_id, actor_profile_id, target_profile_id, action)
	VALUES (me.family_id, me.id, me.id, 'account_deletion_requested');

	INSERT INTO public.notifications (recipient_profile_id, type, title, message)
	VALUES (me.id, 'account_deletion',
	        'Saída solicitada',
	        'Sua saída da família foi solicitada. Você tem 30 dias para cancelar; após esse prazo a conta será apagada.');

	-- Heads-up to every OTHER active member (the in-app twin of the
	-- send-account-email notice): a seat freed and future days may need
	-- reassigning. Transparency — no one is surprised by a departure.
	INSERT INTO public.notifications (recipient_profile_id, type, title, message)
	SELECT p.id, 'account_deletion',
	       'Um responsável saiu',
	       me.full_name || ' saiu da família. Os dias futuros dessa pessoa foram liberados — '
	           || 'verifique o calendário e reatribua o que for necessário.'
	FROM public.profiles p
	WHERE p.family_id = me.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL AND p.id <> me.id;
END;
$$;

ALTER FUNCTION public.request_account_deletion() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.request_account_deletion() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_account_deletion() FROM anon;
GRANT EXECUTE ON FUNCTION public.request_account_deletion() TO authenticated, service_role;

-- ── 7. cancel_account_deletion — come back if a seat is still free ───────────

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
	SET left_at = NULL, deletion_scheduled_for = NULL
	WHERE id = me.id;

	INSERT INTO public.account_logs (family_id, actor_profile_id, target_profile_id, action)
	VALUES (me.family_id, me.id, me.id, 'account_deletion_cancelled');
END;
$$;

ALTER FUNCTION public.cancel_account_deletion() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.cancel_account_deletion() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_account_deletion() FROM anon;
GRANT EXECUTE ON FUNCTION public.cancel_account_deletion() TO authenticated, service_role;

-- ── 8. purge_expired_accounts — hard delete after grace (service role only) ──
-- Returns the auth user ids for the cron to delete via the Admin API, then
-- tombstones the profile: name KEPT (history), e-mail scrubbed, user_id nulled
-- by the ON DELETE SET NULL once the cron removes the auth user.

CREATE OR REPLACE FUNCTION public.purge_expired_accounts()
RETURNS TABLE (user_id uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
	PERFORM set_config('app.deletion_context', 'on', true);

	-- "Not yet purged" is keyed off user_id IS NOT NULL (the cron nulls it via
	-- ON DELETE SET NULL once it removes the auth user). If that Admin-API call
	-- fails, the row is picked up again next run — the e-mail scrub is
	-- deterministic (same value), so re-running is a harmless no-op. Convergent
	-- retry, no stuck state.
	RETURN QUERY
	WITH due AS (
		SELECT id, profiles.user_id AS uid
		FROM public.profiles
		WHERE left_at IS NOT NULL
		  AND user_id IS NOT NULL
		  AND deletion_scheduled_for IS NOT NULL
		  AND deletion_scheduled_for <= timezone('utc', now())
	), scrubbed AS (
		UPDATE public.profiles p
		SET email = 'removido+' || p.id || '@guarda.invalido'
		FROM due
		WHERE p.id = due.id
		RETURNING due.uid
	)
	SELECT uid FROM scrubbed WHERE uid IS NOT NULL;
END;
$$;

ALTER FUNCTION public.purge_expired_accounts() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purge_expired_accounts() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_expired_accounts() FROM anon;
REVOKE ALL ON FUNCTION public.purge_expired_accounts() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.purge_expired_accounts() TO service_role;

-- ── 9. purge_e2e_family tolerates tombstone e-mails ─────────────────────────
-- A hard-purged member's e-mail becomes 'removido+<id>@guarda.invalido'. The
-- E2E purge's member-e-mail guard must accept that placeholder as test-safe,
-- so a family that exercised purge_expired_accounts can still be cleaned up.
-- Body otherwise VERBATIM from 20260715160718_fix_purge_e2e_order.

CREATE OR REPLACE FUNCTION public.purge_e2e_family(p_family_id bigint)
RETURNS SETOF uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	fam_name text;
	non_e2e_members int;
BEGIN
	SELECT name INTO fam_name FROM public.families WHERE id = p_family_id;
	IF fam_name IS NULL THEN
		RETURN;   -- already gone: purge is idempotent
	END IF;

	-- E2E double signature — refuse anything that is not unmistakably test data.
	IF fam_name NOT LIKE 'E2E-%' THEN
		RAISE EXCEPTION 'purge_e2e_family: family % is not an E2E family (name).', p_family_id
			USING ERRCODE = 'check_violation';
	END IF;
	SELECT count(*) INTO non_e2e_members
	FROM public.profiles
	WHERE family_id = p_family_id
	  AND email NOT LIKE '%@resend.dev'
	  AND email NOT LIKE 'removido+%@guarda.invalido';
	IF non_e2e_members > 0 THEN
		RAISE EXCEPTION 'purge_e2e_family: family % has non-E2E members (email).', p_family_id
			USING ERRCODE = 'check_violation';
	END IF;

	-- Hand the auth user ids back BEFORE deleting the profiles.
	RETURN QUERY
	SELECT user_id::uuid FROM public.profiles
	WHERE family_id = p_family_id AND user_id IS NOT NULL;

	-- Ordered teardown (children first; profiles are referenced by all data).
	DELETE FROM public.notifications
	WHERE recipient_profile_id IN (SELECT id FROM public.profiles WHERE family_id = p_family_id);
	DELETE FROM public.swap_requests      WHERE family_id = p_family_id;
	DELETE FROM public.care_schedules     WHERE family_id = p_family_id;
	DELETE FROM public.activity_logs      WHERE family_id = p_family_id;
	DELETE FROM public.family_invitations WHERE family_id = p_family_id;
	DELETE FROM public.profiles           WHERE family_id = p_family_id;
	DELETE FROM public.families           WHERE id = p_family_id;
END;
$$;
