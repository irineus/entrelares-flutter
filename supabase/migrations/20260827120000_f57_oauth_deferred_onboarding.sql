-- =============================================================================
-- F-57 (PR 1) — deferred onboarding for social-login (OAuth) sign-ups
--
-- A Google sign-up reaches `handle_new_user` with raw_user_meta_data filled by
-- the PROVIDER (name, avatar), not by our forms: no `role`, no `family_name`,
-- no `invite_token`, no `policy_version`. The founder branch then raises
-- "Selecione o seu papel" — and because the trigger runs AFTER INSERT ON
-- auth.users, the exception aborts the auth INSERT itself: the OAuth account
-- simply never comes into existence.
--
-- Design (locked with the owner, 27/08/2026): DEFER the profile. An OAuth
-- sign-up creates the auth user with NO profile; the client routes the
-- profile-less session to an onboarding screen, and the profile is created by:
--
--   · complete_oauth_onboarding(...)  — founder path: authenticated RPC that
--     collects role + family name + consent and creates family + admin profile
--     (the RPC twin of the trigger's founder branch);
--   · claim_invitation_for_user(...)  — invitee path: service_role-only,
--     called by the `claim-invitation` Edge Function after it resolves the
--     caller from the JWT (the SQL twin of the trigger's invitee branch,
--     including the S-11 cross-family migration).
--
-- Why the invitee half is service_role-only: the S-11 migration must delete
-- GoTrue users of a purged previous family, which is Admin API work — the Edge
-- Function owns that dance exactly like `register-invitee` does today. The
-- account-linking posture is GoTrue's automatic linking (Google e-mails arrive
-- verified), so a departed member signing in with Google lands on their
-- EXISTING auth user — which is why the migration path here detaches the
-- tombstoned profile instead of deleting the caller's own account.
--
-- Consent (S-13/S-15): both creators validate the submitted policy version
-- against `app_settings.policy.current_version` and REFUSE a mismatch — same
-- posture as accept_current_policy, so a stale client can never stamp a
-- consent it did not display. A NULL stamp would also work mechanically (the
-- S-15 gate blocks NULL), but the onboarding screen collects the checkbox, so
-- the stamp is recorded at creation exactly like the register form's path.
-- =============================================================================

-- ── 1. handle_new_user — the deferred-profile branch ─────────────────────────
-- Body copied VERBATIM from 20260802170000 (F-41); ONLY the F-57 deferred
-- branch is new (right after the metadata extraction).

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

	-- F-57: a social-login sign-up carries neither an invite token nor the
	-- founder metadata (GoTrue fills raw_user_meta_data from the provider, not
	-- from our forms). Raising here would abort the auth.users INSERT and the
	-- OAuth account would never exist — so the profile is DEFERRED: the client
	-- routes the profile-less session to onboarding, and the profile is created
	-- by complete_oauth_onboarding (founder) or claim-invitation (invitee).
	-- The password path is untouched: its provider is 'email', and the register
	-- form always sends the metadata.
	IF meta_token IS NULL AND meta_role IS NULL
	   AND COALESCE(NEW.raw_app_meta_data ->> 'provider', 'email') <> 'email' THEN
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

-- ── 2. complete_oauth_onboarding — the founder path, as an RPC ───────────────
-- The RPC twin of the trigger's founder branch, for a session that exists but
-- has no profile yet. auth.uid() is the whole authorization: it acts only for
-- the caller, and only while the caller has NO profile row at all — a frozen
-- (departed) profile also refuses, because a departed member's only way into a
-- family is an invitation (the same rule the password path enforces).

CREATE OR REPLACE FUNCTION public.complete_oauth_onboarding(
	p_full_name      text,
	p_role           text,
	p_family_name    text,
	p_policy_version text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	uid         uuid := auth.uid();
	user_email  text;
	expected    text;
	the_name    text;
	new_role_id bigint;
	fam_id      bigint;
BEGIN
	IF uid IS NULL THEN
		RAISE EXCEPTION 'Sessão não autenticada.' USING ERRCODE = '42501';
	END IF;

	-- profiles has no UNIQUE on user_id (the trigger's EXISTS check covers the
	-- normal path), so serialize per user: a double-tap must not create two
	-- families.
	PERFORM pg_advisory_xact_lock(hashtext(uid::text));

	IF EXISTS (SELECT 1 FROM public.profiles WHERE user_id = uid) THEN
		RAISE EXCEPTION 'Esta conta já está vinculada a uma família.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- S-15 posture: never stamp a consent the client cannot prove it displayed.
	expected := public.setting_text('policy.current_version', NULL::text);
	IF expected IS NULL THEN
		RAISE EXCEPTION 'Configuração policy.current_version ausente — aceite não pode ser registrado.'
			USING ERRCODE = 'P0002';
	END IF;
	IF p_policy_version IS DISTINCT FROM expected THEN
		RAISE EXCEPTION 'Versão da política desatualizada (enviada: %, vigente: %). Atualize o aplicativo.',
			coalesce(p_policy_version, '(nula)'), expected USING ERRCODE = '22023';
	END IF;

	-- F-27/F-41: catalog lookup, built-ins only (a founder has no family).
	SELECT id INTO new_role_id
	FROM public.roles
	WHERE family_id IS NULL
	  AND (lower(trim(role)) = lower(p_role)
	    OR lower(trim(label_pt)) = lower(p_role))
	ORDER BY id
	LIMIT 1;
	IF new_role_id IS NULL THEN
		RAISE EXCEPTION 'Papel inválido: %.', coalesce(p_role, '(nulo)')
			USING ERRCODE = 'check_violation';
	END IF;

	SELECT email INTO user_email FROM auth.users WHERE id = uid;
	the_name := COALESCE(NULLIF(trim(p_full_name), ''), split_part(user_email, '@', 1));

	INSERT INTO public.families (name)
	VALUES (COALESCE(NULLIF(trim(p_family_name), ''), 'Família ' || the_name))
	RETURNING id INTO fam_id;

	-- Founder = admin, color slot 1, consent stamped at creation — the exact
	-- shape handle_new_user's founder branch produces.
	INSERT INTO public.profiles (user_id, full_name, role_id, email, family_id, is_admin, color_slot,
	                             consent_accepted_at, consent_policy_version)
	VALUES (uid, the_name, new_role_id, user_email, fam_id, true, 1,
	        timezone('utc', now()), expected);
END;
$$;

ALTER FUNCTION public.complete_oauth_onboarding(text, text, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.complete_oauth_onboarding(text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_oauth_onboarding(text, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.complete_oauth_onboarding(text, text, text, text) IS
	'F-57: creates family + admin profile for an OAuth session whose profile was deferred by handle_new_user. Validates the policy version against policy.current_version (S-15) and refuses a caller who already has any profile row.';

-- ── 3. claim_invitation_for_user — the invitee path, service_role only ───────
-- The SQL twin of the trigger's invitee branch, for a user that already exists
-- (OAuth). Called exclusively by the `claim-invitation` Edge Function, which
-- resolves the caller from the JWT — hence p_user_id as an argument and the
-- service_role-only grant, the same posture as purge_departed_member_by_email.
--
-- S-11 migration, adapted to automatic account linking: a departed member who
-- signs in with Google lands on their EXISTING auth user, so there is no
-- "already registered" conflict to trip on — the frozen previous-family
-- profile is what stands in the way. With p_confirm_migration the previous
-- registration is purged (same teardown as register-invitee), the caller's own
-- tombstoned profile is DETACHED (user_id → NULL, never deleted: the history
-- keeps the name), and only OTHER freed auth users are returned for the Edge
-- Function to delete from GoTrue. Without it, the caller gets the
-- MIGRATION_REQUIRED marker so the client can warn before the destructive step
-- (the S-10 'ELEVATION_REQUIRED:' pattern).

CREATE OR REPLACE FUNCTION public.claim_invitation_for_user(
	p_user_id           uuid,
	p_full_name         text,
	p_token             text,
	p_policy_version    text,
	p_confirm_migration boolean DEFAULT false
)
RETURNS TABLE (auth_uid uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	user_email  text;
	expected    text;
	the_name    text;
	inv         public.family_invitations%ROWTYPE;
	prev_family text;
	max_seats   int := public.setting_int('max_caregivers', 4);
	free_seats  int := public.setting_int('free_caregivers', 2);
BEGIN
	PERFORM pg_advisory_xact_lock(hashtext(p_user_id::text));

	SELECT u.email INTO user_email FROM auth.users u WHERE u.id = p_user_id;
	IF user_email IS NULL THEN
		RAISE EXCEPTION 'Sessão não autenticada.' USING ERRCODE = '42501';
	END IF;

	IF EXISTS (SELECT 1 FROM public.profiles p
	           WHERE p.user_id = p_user_id AND p.left_at IS NULL) THEN
		RAISE EXCEPTION 'Esta conta já está vinculada a uma família.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- S-15 posture — same validation as complete_oauth_onboarding.
	expected := public.setting_text('policy.current_version', NULL::text);
	IF expected IS NULL THEN
		RAISE EXCEPTION 'Configuração policy.current_version ausente — aceite não pode ser registrado.'
			USING ERRCODE = 'P0002';
	END IF;
	IF p_policy_version IS DISTINCT FROM expected THEN
		RAISE EXCEPTION 'Versão da política desatualizada (enviada: %, vigente: %). Atualize o aplicativo.',
			coalesce(p_policy_version, '(nula)'), expected USING ERRCODE = '22023';
	END IF;

	-- Token validation — verbatim mirror of the trigger's invitee branch.
	BEGIN
		SELECT * INTO inv
		FROM public.family_invitations i
		WHERE i.token = p_token::uuid
		  AND i.accepted_at IS NULL
		  AND i.revoked_at  IS NULL
		  AND i.expires_at  > timezone('utc', now())
		  AND lower(i.email) = lower(user_email);
	EXCEPTION WHEN invalid_text_representation THEN
		inv := NULL;
	END;

	IF inv.id IS NULL THEN
		RAISE EXCEPTION 'Convite inválido, expirado ou emitido para outro e-mail.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- S-11: a departed previous-family registration must be consciously erased
	-- before joining the new family (1 e-mail = 1 family until F-30).
	prev_family := public.departed_member_family(user_email);
	IF prev_family IS NOT NULL THEN
		IF NOT p_confirm_migration THEN
			RAISE EXCEPTION 'MIGRATION_REQUIRED:%', prev_family
				USING ERRCODE = 'check_violation';
		END IF;

		-- Same teardown register-invitee runs, but the caller's own auth user
		-- SURVIVES (it is the session making this claim): their tombstoned
		-- profile is detached instead, and only other freed users are handed
		-- back for GoTrue deletion (whole-family purge can free several).
		RETURN QUERY
			SELECT purged.auth_uid
			FROM public.purge_departed_member_by_email(user_email) AS purged
			WHERE purged.auth_uid IS DISTINCT FROM p_user_id;

		UPDATE public.profiles p
		SET user_id = NULL
		WHERE p.user_id = p_user_id AND p.left_at IS NOT NULL;
	END IF;

	-- Seat caps — verbatim mirror of the trigger's invitee branch.
	IF public.active_member_count(inv.family_id) >= max_seats THEN
		RAISE EXCEPTION 'Esta família já atingiu o limite de % responsáveis.', max_seats
			USING ERRCODE = 'check_violation';
	END IF;

	IF public.active_member_count(inv.family_id) >= free_seats
	   AND NOT public.is_premium(inv.family_id) THEN
		RAISE EXCEPTION 'Esta família já atingiu o limite de % responsáveis do plano gratuito. Peça ao administrador para ativar o Premium e liberar novos cuidadores.', free_seats
			USING ERRCODE = 'check_violation';
	END IF;

	UPDATE public.family_invitations i
	SET accepted_at = timezone('utc', now())
	WHERE i.id = inv.id;

	the_name := COALESCE(NULLIF(trim(p_full_name), ''), split_part(user_email, '@', 1));

	INSERT INTO public.profiles (user_id, full_name, role_id, email, family_id, is_admin, color_slot,
	                             consent_accepted_at, consent_policy_version)
	VALUES (p_user_id, the_name, inv.role_id, user_email, inv.family_id, false,
	        public.next_free_color_slot(inv.family_id),
	        timezone('utc', now()), expected);

	RETURN;
END;
$$;

ALTER FUNCTION public.claim_invitation_for_user(uuid, text, text, text, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.claim_invitation_for_user(uuid, text, text, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_invitation_for_user(uuid, text, text, text, boolean) TO service_role;

COMMENT ON FUNCTION public.claim_invitation_for_user(uuid, text, text, text, boolean) IS
	'F-57: attaches an existing (OAuth) auth user to a family through a valid invitation — the SQL twin of handle_new_user''s invitee branch, including the S-11 cross-family migration. service_role only: the claim-invitation Edge Function resolves the caller from the JWT and deletes the returned freed auth users.';
