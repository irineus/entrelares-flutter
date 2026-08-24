-- ============================================================================
-- F-37 — Freemium gate: the 3rd+ caregiver is Premium (add-only + grandfather)
--
-- The freemium line F-32 locked, made concrete for the first time. Free families
-- include TWO caregivers (the two-parent core stays free forever); adding a 3rd+
-- caregiver requires Premium. Enforced in the DB at both add points:
--
--   1. create_invitation  — the admin creating the invite (primary, admin-facing
--      upsell message). Blocks when seats taken (ACTIVE members + open invites)
--      already reach 2 on a non-premium family.
--   2. handle_new_user     — the invitee accepting (backstop, invitee-facing
--      message). Covers the race where two invites were created while premium /
--      during the trial and one is accepted after the family dropped to free.
--
-- Design (decisions locked July 2026):
--   · Add-only: the gate blocks only NEW additions — it NEVER removes or freezes
--     members a family already holds.
--   · Grandfather is AUTOMATIC and needs no data migration: F-32 marked every
--     pre-existing family permanent `premium`, and every new family is premium
--     during its 30-day trial. So a family only ever meets this gate as `free`
--     AFTER its trial, and any members it gained meanwhile simply stay (add-only).
--   · Uniform rule (locked): on a free family ANY addition that would exceed 2
--     active caregivers is Premium — including RE-adding after a departure. No
--     historical-peak tracking; a departure narrows a free family back toward 2.
--   · The hard 4-seat cap (F-28, member-slot colour palette) still applies ABOVE
--     this gate for premium families.
--
-- Both functions are CREATE OR REPLACE of their latest bodies (create_invitation
-- from 20260721150000, handle_new_user from 20260721190000) copied VERBATIM with
-- only the F-37 guard inserted — nothing else changes.
-- ============================================================================

-- ── 1. create_invitation — admin-facing free-cap guard ──────────────────────
-- Body copied VERBATIM from 20260721150000; only the F-37 guard (right before
-- the hard-cap check) is new.

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

	IF EXISTS (SELECT 1 FROM public.family_deletion_requests
	           WHERE family_id = me.family_id AND status = 'pending') THEN
		RAISE EXCEPTION 'Há uma solicitação de exclusão da família em andamento — convites ficam bloqueados até ela ser resolvida.'
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

	-- F-37: freemium gate — free families include 2 caregivers; the 3rd+ is
	-- Premium. Grandfather is automatic (F-32). Add-only: nothing is removed.
	IF taken >= 2 AND NOT public.is_premium(me.family_id) THEN
		RAISE EXCEPTION 'Famílias no plano gratuito incluem 2 responsáveis. Para adicionar um 3º cuidador (avós, babá, etc.), ative o Premium.'
			USING ERRCODE = 'check_violation';
	END IF;

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

-- ── 2. handle_new_user — invitee-facing free-cap backstop ────────────────────
-- Body copied VERBATIM from 20260721190000; only the F-37 guard (right after the
-- hard-cap race re-check, invitee path) is new.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	meta_name    text;
	meta_role    text;
	meta_token   text;
	meta_family  text;
	meta_policy  text;
	inv          public.family_invitations%ROWTYPE;
	fam_id       bigint;
	new_role_id  bigint;
	admin_flag   boolean;
	max_seats    constant int := 4;
BEGIN
	-- Idempotency: never duplicate a profile (e.g. trigger re-run).
	IF EXISTS (SELECT 1 FROM public.profiles WHERE user_id = NEW.id) THEN
		RETURN NEW;
	END IF;

	meta_name   := NULLIF(trim(NEW.raw_user_meta_data ->> 'full_name'), '');
	meta_role   := NULLIF(trim(NEW.raw_user_meta_data ->> 'role'), '');
	meta_token  := NULLIF(trim(NEW.raw_user_meta_data ->> 'invite_token'), '');
	meta_family := NULLIF(trim(NEW.raw_user_meta_data ->> 'family_name'), '');
	meta_policy := NULLIF(trim(NEW.raw_user_meta_data ->> 'policy_version'), '');

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

		-- F-37: freemium gate backstop — a 3rd+ caregiver joining a free family
		-- needs Premium. Primary guard is create_invitation; this covers the race
		-- where the invite was created while premium/on trial and accepted after
		-- the family dropped to free. Invitee-facing copy (they can't self-upgrade).
		IF public.active_member_count(inv.family_id) >= 2
		   AND NOT public.is_premium(inv.family_id) THEN
			RAISE EXCEPTION 'Esta família já atingiu o limite de 2 responsáveis do plano gratuito. Peça ao administrador para ativar o Premium e liberar novos cuidadores.'
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
	-- S-13: the LGPD consent (checkbox gated sign-up) is recorded with the
	-- policy version accepted, so it is demonstrable later (art. 8 §1).
	INSERT INTO public.profiles (user_id, full_name, role_id, email, family_id, is_admin, color_slot,
	                             consent_accepted_at, consent_policy_version)
	VALUES (NEW.id, meta_name, new_role_id, NEW.email, fam_id, admin_flag,
	        CASE WHEN admin_flag THEN 1 ELSE public.next_free_color_slot(fam_id) END,
	        CASE WHEN meta_policy IS NOT NULL THEN timezone('utc', now()) END,
	        meta_policy);

	RETURN NEW;
END;
$$;
