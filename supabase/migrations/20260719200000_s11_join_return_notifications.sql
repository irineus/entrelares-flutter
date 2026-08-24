-- =============================================================================
-- S-11 (PR1) — in-app notifications for member JOIN and RETURN
--
-- Product decision (July 2026): keep the family informed of roster changes.
--   · A new member joining notifies every existing active member.
--   · A member returning (cancelling their exit) notifies every other active
--     member. Distinct texts for each case.
-- The e-mail twins are dispatched from the app / register-invitee via
-- send-account-email (member_joined / member_returned). In-app is the reliable
-- channel (DB-written here); e-mail is best-effort.
-- =============================================================================

-- ── 1. Notify existing members when someone joins ───────────────────────────
-- AFTER INSERT on profiles: the founder's own insert has no other members
-- (no-op); an invitee's insert notifies the family already present.

CREATE OR REPLACE FUNCTION public.notify_member_joined()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
	INSERT INTO public.notifications (recipient_profile_id, type, title, message)
	SELECT p.id, 'member_joined',
	       'Novo responsável na família',
	       NEW.full_name || ' juntou-se à família. Confira o calendário para incluí-lo no planejamento.'
	FROM public.profiles p
	WHERE p.family_id = NEW.family_id
	  AND p.id <> NEW.id
	  AND p.left_at IS NULL
	  AND p.user_id IS NOT NULL;

	RETURN NEW;
END;
$$;

ALTER FUNCTION public.notify_member_joined() OWNER TO postgres;

DROP TRIGGER IF EXISTS trigger_notify_member_joined ON public.profiles;
CREATE TRIGGER trigger_notify_member_joined
	AFTER INSERT ON public.profiles
	FOR EACH ROW
	EXECUTE FUNCTION public.notify_member_joined();

-- ── 2. cancel_account_deletion: notify others on return ─────────────────────
-- Body from 20260719120000 plus the member-returned notifications.

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

	-- Heads-up to the other active members that the person is back.
	INSERT INTO public.notifications (recipient_profile_id, type, title, message)
	SELECT p.id, 'member_returned',
	       'Responsável voltou à família',
	       me.full_name || ' cancelou a saída e voltou à família.'
	FROM public.profiles p
	WHERE p.family_id = me.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL AND p.id <> me.id;
END;
$$;
