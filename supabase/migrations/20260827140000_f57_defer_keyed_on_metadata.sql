-- =============================================================================
-- F-57 (PR 1, fix) — the deferred branch keys on OUR metadata, not on provider
--
-- 20260827120000 deferred the profile when `raw_app_meta_data->>'provider'`
-- was not 'email'. The very first gate run against it proved that condition
-- untestable: the GoTrue Admin API does not let a caller forge
-- `provider: google` (the platform's own default wins), so the suite could
-- never create a user the branch would match — and a production rule the gate
-- cannot exercise is exactly the kind that rots silently.
--
-- The provider was never the real discriminator anyway. Both legitimate
-- sign-up flows ALWAYS send our metadata — the register form sends
-- role/family_name/policy_version, register-invitee sends invite_token — so
-- the true mark of a sign-up that did not come through our forms is the
-- ABSENCE of that metadata, whatever the provider says. An OAuth sign-up is
-- the designed case; a bare password sign-up straight at the GoTrue API
-- (impossible through our screens) now defers to the same onboarding instead
-- of aborting the INSERT — it still confirms its e-mail before it can sign in,
-- it holds no profile so RLS grants it nothing, and complete_oauth_onboarding
-- / claim-invitation are its only ways forward. No invariant leaned on the old
-- refusal; it was a form validation living in the wrong layer.
--
-- Body copied VERBATIM from 20260827120000; ONLY the deferred-branch condition
-- (and its comment) changed.
-- =============================================================================

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
	max_seats    int := public.setting_int('max_caregivers', 4);
	free_seats   int := public.setting_int('free_caregivers', 2);
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

	-- F-57: a sign-up that carries neither an invite token nor a role did not
	-- come through our forms (they always send the metadata) — it is an OAuth
	-- sign-up, whose raw_user_meta_data is the PROVIDER's. Raising here would
	-- abort the auth.users INSERT and the account would never exist, so the
	-- profile is DEFERRED: the client routes the profile-less session to
	-- onboarding, and the profile is created by complete_oauth_onboarding
	-- (founder) or claim-invitation (invitee). Deliberately NOT keyed on
	-- raw_app_meta_data->>'provider': the Admin API cannot forge it, so a
	-- provider-based rule is one the db gate can never exercise.
	IF meta_token IS NULL AND meta_role IS NULL THEN
		RETURN NEW;
	END IF;

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

		-- F-37 (T-41: free_caregivers from settings) backstop — a caregiver beyond
		-- the free tier joining a free family needs Premium. Primary guard is
		-- create_invitation; this covers the trial-expired / parallel-invite race.
		IF public.active_member_count(inv.family_id) >= free_seats
		   AND NOT public.is_premium(inv.family_id) THEN
			RAISE EXCEPTION 'Esta família já atingiu o limite de % responsáveis do plano gratuito. Peça ao administrador para ativar o Premium e liberar novos cuidadores.', free_seats
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
		-- F-41: built-ins only — a founder has no family, so no custom row
		-- (from ANY family) may resolve here.
		SELECT id INTO new_role_id
		FROM public.roles
		WHERE family_id IS NULL
		  AND (lower(trim(role)) = lower(meta_role)
		    OR lower(trim(label_pt)) = lower(meta_role))
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
