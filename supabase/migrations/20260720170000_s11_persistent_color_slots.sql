-- =============================================================================
-- S-11 (QA) — persistent per-member color slots
--
-- The calendar color was the profile's POSITION among the family's first 4
-- profiles by id, computed live. With departures/joins that breaks twice:
-- a departed member keeps an active color in the legend forever (the
-- tombstone row never leaves), and a member who joins after a departure
-- falls outside Take(4) — invisible in the legend and rendered with the
-- FOUNDER's color (slot fallback 1).
--
-- Decision (product owner, July 2026): the color is bound to the PERSON,
-- not the position — a persistent `color_slot` (1–4) on the profile:
--   · assigned at join: founder = 1; invitee = lowest slot free among the
--     family's ACTIVE members (naturally reuses a departed member's color);
--   · never changes because OTHERS leave/join;
--   · kept on leave (grace): cancelling reclaims the same color if still
--     free, otherwise takes the lowest free one;
--   · the 4 color themes belong to ACTIVE members only — inactive members
--     (left_at set / tombstones) render in a single gray "inactive" theme,
--     past days included (accepted: history is consult-only).
-- =============================================================================

-- ── 1. Column + backfill ─────────────────────────────────────────────────────

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS color_slot smallint;

-- Backfill mirrors today's rendering (position among the family's first 4 by
-- id), so existing families see zero visual change...
WITH ranked AS (
	SELECT id, row_number() OVER (PARTITION BY family_id ORDER BY id) AS rn
	FROM public.profiles
)
UPDATE public.profiles p SET color_slot = r.rn
FROM ranked r
WHERE p.id = r.id AND r.rn <= 4 AND p.color_slot IS NULL;

-- ...and actives left without a slot (joined after a departure — the very bug
-- being fixed) get the lowest slot free among the family's active members.
DO $$
DECLARE
	r record;
	s smallint;
BEGIN
	FOR r IN
		SELECT id, family_id FROM public.profiles
		WHERE color_slot IS NULL AND left_at IS NULL AND user_id IS NOT NULL
		ORDER BY id
	LOOP
		SELECT gs::smallint INTO s FROM generate_series(1, 4) gs
		WHERE gs NOT IN (
			SELECT color_slot FROM public.profiles
			WHERE family_id = r.family_id AND left_at IS NULL
			  AND user_id IS NOT NULL AND color_slot IS NOT NULL)
		ORDER BY gs LIMIT 1;
		UPDATE public.profiles SET color_slot = s WHERE id = r.id;
	END LOOP;
END $$;

-- ── 2. next_free_color_slot helper ───────────────────────────────────────────
-- Lowest 1–4 not held by an ACTIVE member. The 4-seat cap guarantees a free
-- slot whenever a join/return is allowed.

CREATE OR REPLACE FUNCTION public.next_free_color_slot(p_family_id bigint)
RETURNS smallint
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
	SELECT gs::smallint FROM generate_series(1, 4) gs
	WHERE gs NOT IN (
		SELECT color_slot FROM public.profiles
		WHERE family_id = p_family_id AND left_at IS NULL
		  AND user_id IS NOT NULL AND color_slot IS NOT NULL)
	ORDER BY gs LIMIT 1;
$$;

ALTER FUNCTION public.next_free_color_slot(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.next_free_color_slot(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.next_free_color_slot(bigint) FROM anon;
GRANT EXECUTE ON FUNCTION public.next_free_color_slot(bigint) TO authenticated, service_role;

-- ── 3. handle_new_user assigns the slot at join ──────────────────────────────
-- Body VERBATIM from 20260719120000 except color_slot in the INSERT.

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

	-- S-11 QA: the color slot is assigned at join and belongs to the person —
	-- founder = 1; invitee = lowest slot free among the ACTIVE members (which
	-- naturally reuses a departed member's freed color).
	INSERT INTO public.profiles (user_id, full_name, role_id, email, family_id, is_admin, color_slot)
	VALUES (NEW.id, meta_name, new_role_id, NEW.email, fam_id, admin_flag,
	        CASE WHEN admin_flag THEN 1 ELSE public.next_free_color_slot(fam_id) END);

	RETURN NEW;
END;
$$;

-- ── 4. cancel_account_deletion reclaims the color on return ─────────────────
-- Body VERBATIM from 20260719200000 except the color_slot reclaim in the
-- UPDATE (evaluated while the returner is still inactive, so their own row
-- never blocks the check).

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
	INSERT INTO public.notifications (recipient_profile_id, type, title, message)
	SELECT p.id, 'member_returned',
	       'Responsável voltou à família',
	       me.full_name || ' cancelou a saída e voltou à família.'
	FROM public.profiles p
	WHERE p.family_id = me.family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL AND p.id <> me.id;
END;
$$;

-- ── 5. enforce_profile_protection: the slot is system-managed ────────────────
-- Body VERBATIM from 20260719180000 plus the color_slot guard: a client must
-- not repaint themselves (or anyone) — the slot changes only in system context
-- (migrations/service) or on the leave-cancel transition handled above.

CREATE OR REPLACE FUNCTION public.enforce_profile_protection()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
	actor_admin  boolean;
	actor_family bigint;
BEGIN
	-- System context (service_role / migrations): unrestricted.
	IF auth.uid() IS NULL THEN
		RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
	END IF;

	SELECT is_admin, family_id INTO actor_admin, actor_family
	FROM public.profiles WHERE user_id = auth.uid();

	IF TG_OP = 'UPDATE' THEN
		-- S-11: a departed member's profile is FROZEN — no edits at all.
		-- Exceptions: the erasure cleanup (deletion_context) and the owner
		-- cancelling their own exit (left_at set -> NULL).
		IF OLD.left_at IS NOT NULL
		   AND current_setting('app.deletion_context', true) IS DISTINCT FROM 'on'
		   AND NOT (OLD.user_id = auth.uid() AND NEW.left_at IS NULL) THEN
			RAISE EXCEPTION 'Este responsável saiu da família e não pode mais ser alterado.'
				USING ERRCODE = 'check_violation';
		END IF;

		-- S-11 QA: the color slot is system-managed (join / return reclaim) —
		-- never a direct client edit.
		IF NEW.color_slot IS DISTINCT FROM OLD.color_slot
		   AND NOT (OLD.left_at IS NOT NULL AND NEW.left_at IS NULL) THEN
			RAISE EXCEPTION 'A cor de um responsável é gerenciada pelo sistema.'
				USING ERRCODE = 'check_violation';
		END IF;

		IF NEW.family_id IS DISTINCT FROM OLD.family_id THEN
			RAISE EXCEPTION 'A família de um perfil não pode ser alterada.'
				USING ERRCODE = 'check_violation';
		END IF;

		IF NEW.is_admin IS DISTINCT FROM OLD.is_admin THEN
			-- Blocks self-promotion through the profiles_own_update policy.
			IF COALESCE(actor_admin, false) = false OR actor_family IS DISTINCT FROM OLD.family_id THEN
				RAISE EXCEPTION 'Somente administradores da família podem alterar permissões de administrador.'
					USING ERRCODE = 'check_violation';
			END IF;

			-- Demotion: keep the >= 1 admin per family invariant.
			IF OLD.is_admin AND NOT NEW.is_admin AND NOT EXISTS (
				SELECT 1 FROM public.profiles
				WHERE family_id = OLD.family_id AND is_admin AND id <> OLD.id
			) THEN
				RAISE EXCEPTION 'A família precisa de pelo menos uma pessoa administradora.'
					USING ERRCODE = 'check_violation';
			END IF;
		END IF;

		-- F-16/F-27: role changes are admin-only (set_member_role) — the
		-- own-row UPDATE policy must not be a side door for self role edits.
		IF NEW.role_id IS DISTINCT FROM OLD.role_id THEN
			IF COALESCE(actor_admin, false) = false OR actor_family IS DISTINCT FROM OLD.family_id THEN
				RAISE EXCEPTION 'Somente administradores da família podem alterar papéis.'
					USING ERRCODE = 'check_violation';
			END IF;
		END IF;

		RETURN NEW;
	END IF;

	-- DELETE: never remove the last admin of a family.
	IF OLD.is_admin AND NOT EXISTS (
		SELECT 1 FROM public.profiles
		WHERE family_id = OLD.family_id AND is_admin AND id <> OLD.id
	) THEN
		RAISE EXCEPTION 'A família precisa de pelo menos uma pessoa administradora.'
			USING ERRCODE = 'check_violation';
	END IF;
	RETURN OLD;
END;
$$;
