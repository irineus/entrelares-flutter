-- =============================================================================
-- F-27 — Caregiver role catalog (Phase A: two-member family model)
-- Guarda Compartilhada — Supabase/PostgreSQL
--
-- The roles table held a fixed father/mother pair with environment-
-- inconsistent seeds ('father'/'mother' per V001 vs 'Pai'/'Mãe' hand-seeded
-- in dev). This migration:
--
--   1. Adds label_pt and normalizes existing rows to canonical english
--      slugs + PT-BR labels (idempotent — runs safely on both vocabularies).
--   2. Seeds the expanded catalog (21 roles, decisions of July 2026).
--      Duplicate roles per family are ALLOWED (e.g. Avó materna + paterna);
--      colors are per family member (client-side), not per role.
--   3. handle_new_user: the hardcoded father/mother alias CASE becomes a
--      catalog lookup (canonical value or PT-BR label, case-insensitive).
--   4. New RPC set_member_role: family admins may change any member's role,
--      including their own (a role is descriptive, not a privilege — no
--      lockout risk, unlike set_member_admin's last-admin invariant).
--
-- Mirrors: RoleCatalog.cs (client) and send-swap-email templateInvitation
-- (Edge Function reads label_pt) must ship together with this migration.
-- =============================================================================

-- ── 1. Canonicalize ─────────────────────────────────────────────────────────

ALTER TABLE public.roles ADD COLUMN IF NOT EXISTS label_pt text;

-- Normalize the legacy pair whatever vocabulary the environment used.
UPDATE public.roles SET role = 'father', label_pt = 'Pai'
WHERE lower(trim(role)) IN ('father', 'pai');
UPDATE public.roles SET role = 'mother', label_pt = 'Mãe'
WHERE lower(trim(role)) IN ('mother', 'mãe', 'mae');

-- Hand-seeded environments have stale identity sequences (V009 gotcha).
SELECT setval(pg_get_serial_sequence('public.roles', 'id'),
              COALESCE((SELECT max(id) FROM public.roles), 0) + 1, false);

-- ── 2. Seed the expanded catalog ────────────────────────────────────────────

INSERT INTO public.roles (role, label_pt)
SELECT v.role, v.label_pt
FROM (VALUES
	('grandfather',       'Avô'),
	('grandmother',       'Avó'),
	('great_grandfather', 'Bisavô'),
	('great_grandmother', 'Bisavó'),
	('stepfather',        'Padrasto'),
	('stepmother',        'Madrasta'),
	('uncle',             'Tio'),
	('aunt',              'Tia'),
	('godfather',         'Padrinho'),
	('godmother',         'Madrinha'),
	('brother',           'Irmão'),
	('sister',            'Irmã'),
	('cousin_m',          'Primo'),
	('cousin_f',          'Prima'),
	('friend_m',          'Amigo'),
	('friend_f',          'Amiga'),
	('guardian_m',        'Tutor'),
	('guardian_f',        'Tutora'),
	('nanny',             'Babá')
) AS v(role, label_pt)
WHERE NOT EXISTS (SELECT 1 FROM public.roles r WHERE r.role = v.role);

ALTER TABLE public.roles ALTER COLUMN label_pt SET NOT NULL;

-- Canonical slugs are unique from here on.
CREATE UNIQUE INDEX IF NOT EXISTS roles_role_key ON public.roles (role);

-- ── 3. handle_new_user: catalog-driven role lookup ──────────────────────────
-- Body verbatim from V009/baseline except the founder role resolution
-- (the alias CASE becomes a lookup on canonical slug or PT-BR label).

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

		-- The family may have completed meanwhile (invite raced a manual add).
		IF (SELECT count(*) FROM public.profiles WHERE family_id = inv.family_id) >= 2 THEN
			RAISE EXCEPTION 'Esta família já possui dois responsáveis cadastrados.'
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

-- ── 4. set_member_role: admin changes any member's role ─────────────────────

CREATE OR REPLACE FUNCTION public.set_member_role(p_profile_id bigint, p_role_id bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me public.profiles%ROWTYPE;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();

	IF me.id IS NULL OR NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores da família podem alterar papéis.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF NOT EXISTS (SELECT 1 FROM public.roles WHERE id = p_role_id) THEN
		RAISE EXCEPTION 'Papel inválido.'
			USING ERRCODE = 'check_violation';
	END IF;

	UPDATE public.profiles
	SET role_id = p_role_id
	WHERE id = p_profile_id AND family_id = me.family_id;

	IF NOT FOUND THEN
		RAISE EXCEPTION 'Perfil não encontrado na sua família.'
			USING ERRCODE = 'check_violation';
	END IF;
END;
$$;

ALTER FUNCTION public.set_member_role(bigint, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.set_member_role(bigint, bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_member_role(bigint, bigint) TO authenticated;
GRANT ALL ON FUNCTION public.set_member_role(bigint, bigint) TO service_role;
