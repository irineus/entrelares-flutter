-- ============================================================================
-- F-28 (PR1): multi-caregiver membership — lift the two-member limit to a
-- 4-caregiver cap per family.
--
--   1. create_invitation:
--      · cap = current members + OPEN invitations < 4 (an open invitation
--        reserves a seat so two parallel invites cannot overshoot the cap
--        at acceptance time);
--      · resend revokes only the SAME e-mail's open invitation (the old rule
--        revoked every open invitation in the family — with N members,
--        inviting a 2nd person would silently kill the 1st person's invite).
--   2. handle_new_user (invitee path): the acceptance re-check moves from
--      2 to 4 members (guards the race where seats filled meanwhile).
--
-- The caregiver cap is 4 by design: the member-slot color palette
-- (role-1..4 themes, F-27) and the calendar legend hold exactly 4 members.
-- Raising it later = bump both constants here + extend the palette.
-- ============================================================================

-- ── 1. create_invitation ────────────────────────────────────────────────────
-- Body from V009 except the cap and the per-e-mail resend revocation.

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

	IF EXISTS (SELECT 1 FROM public.profiles WHERE lower(email) = lower(trim(p_email))) THEN
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

	-- Seats taken = members + open (pending, unexpired) invitations.
	SELECT (SELECT count(*) FROM public.profiles WHERE family_id = me.family_id)
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

-- ── 2. handle_new_user ──────────────────────────────────────────────────────
-- Body verbatim from 20260715043019_role_catalog except the invitee-path
-- member cap (2 → 4) and its message.

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
		IF (SELECT count(*) FROM public.profiles WHERE family_id = inv.family_id) >= max_seats THEN
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
