-- =============================================================================
-- S-13 — LGPD accountability: demonstrable consent records + retention purge
--
-- 1. Consent records (art. 8 §1 — the burden of proving consent is the
--    controller's): F-18 added the sign-up consent checkbox but never RECORDED
--    it. New columns profiles.consent_accepted_at / consent_policy_version are
--    stamped by handle_new_user from the sign-up metadata (both the founder
--    and the invitee paths send `policy_version`). LEGACY profiles stay NULL
--    on purpose — their consent happened (the F-18 checkbox gated sign-up)
--    but was not recorded, and backfilling would fabricate evidence; a
--    re-consent flow on policy change is the future improvement that closes
--    that gap.
--
-- 2. Retention purge (art. 6, III — data minimization; periods decided by the
--    product owner, July 2026): READ notifications older than 6 months are
--    deleted by the purge-deleted cron. Calendar, swap history and audit stay
--    for the account/family lifetime (art. 16 — legal defense; S-11's erasure
--    already purges everything on exit/deletion).
-- =============================================================================

-- ── 1. Consent columns ────────────────────────────────────────────────────────

ALTER TABLE public.profiles
	ADD COLUMN IF NOT EXISTS consent_accepted_at    timestamp with time zone,
	ADD COLUMN IF NOT EXISTS consent_policy_version text;

-- ── 2. handle_new_user — stamp the consent at profile creation ───────────────
-- Body copied VERBATIM from 20260720170000 (persistent color slots); only the
-- consent metadata read + the two new INSERT columns are new.

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

-- ── 3. Retention purge — read notifications older than 6 months ──────────────
-- Called by the purge-deleted cron. Unread notifications are kept (the user
-- has not seen them yet); everything else the family holds stays for the
-- account/family lifetime per the retention policy.

CREATE OR REPLACE FUNCTION public.purge_old_notifications()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	removed integer;
BEGIN
	DELETE FROM public.notifications
	WHERE is_read
	  AND created_at < timezone('utc', now()) - interval '6 months';
	GET DIAGNOSTICS removed = ROW_COUNT;
	RETURN removed;
END;
$$;

ALTER FUNCTION public.purge_old_notifications() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purge_old_notifications() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_old_notifications() FROM anon;
REVOKE ALL ON FUNCTION public.purge_old_notifications() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.purge_old_notifications() TO service_role;
