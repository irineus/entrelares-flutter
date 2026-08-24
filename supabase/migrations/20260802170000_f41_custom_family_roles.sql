-- ============================================================================
-- F-41 — Gate: custom per-family roles (Premium)
--
-- Free families use the built-in role vocabulary (the 21 F-27 catalog rows);
-- premium families may define CUSTOM roles of their own (e.g. "Vovó materna").
-- Custom roles are family-scoped rows in the SAME public.roles table — the
-- profiles/family_invitations FKs keep pointing at one table, and the client
-- keeps one roles list (RLS narrows it per family).
--
-- Design (decisions locked Aug 2026):
--   · roles.family_id NULL  = built-in (global, immutable vocabulary);
--     roles.family_id set   = custom row owned by that family.
--   · Creation is Premium + admin only (is_premium() gate in create_custom_role).
--     Existing custom roles KEEP WORKING if the family later drops to free —
--     the gate is add-only, mirroring F-37's grandfather rule.
--   · Deletion (delete_custom_role) is admin only and requires the role to be
--     UNUSED (no profile, no invitation — even historical ones: the FKs would
--     block the delete anyway, so the RPC turns that into a friendly message).
--     No premium check on delete: removing data is never an upsell.
--   · Custom rows store the user's label in BOTH role and label_pt (the client
--     RoleCatalog passes unknown values through unchanged — zero client-side
--     resolution changes). Optional emoji lives in the new emoji column
--     (built-in rows keep emoji in the client catalog only).
--   · Uniqueness: built-in slugs stay globally unique (partial index replaces
--     roles_role_key); custom labels are unique PER FAMILY, and creation also
--     refuses labels that shadow a built-in label (confusing duplicates).
--
-- Scope hardening the family_id column makes NECESSARY (harmless before, a
-- cross-family leak after):
--   · RLS: the always-true authenticated read becomes family-scoped
--     (built-ins + my family's rows).
--   · create_invitation / set_member_role: "role exists" becomes "role exists
--     AND is visible to my family" — without it, family A could assign family
--     B's custom role by guessing its id.
--   · handle_new_user founder lookup matches built-ins only (a founder has no
--     family yet, so a custom row must never resolve).
-- ============================================================================

-- ── 1. Schema: family scope + optional emoji ────────────────────────────────

ALTER TABLE public.roles
	ADD COLUMN IF NOT EXISTS family_id bigint REFERENCES public.families(id) ON DELETE CASCADE,
	ADD COLUMN IF NOT EXISTS emoji text;

-- Built-in slugs stay globally unique; custom labels unique per family.
DROP INDEX IF EXISTS public.roles_role_key;
CREATE UNIQUE INDEX IF NOT EXISTS roles_builtin_role_key
	ON public.roles (role) WHERE family_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS roles_custom_label_key
	ON public.roles (family_id, lower(label_pt)) WHERE family_id IS NOT NULL;

-- ── 2. RLS: reads become family-scoped ──────────────────────────────────────
-- Built-in rows stay visible to every authenticated user; custom rows only to
-- their own family. anon keeps reading NOTHING (T-44 — no table privilege).

DROP POLICY IF EXISTS "roles_authenticated_read" ON public.roles;
CREATE POLICY roles_family_scoped_read ON public.roles
	FOR SELECT TO authenticated
	USING (family_id IS NULL OR family_id = public.get_my_family_id());

-- ── 3. create_custom_role — admin + Premium only ────────────────────────────

CREATE OR REPLACE FUNCTION public.create_custom_role(p_label text, p_emoji text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
	me      public.profiles%ROWTYPE;
	v_label text;
	v_emoji text;
	new_id  bigint;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();

	IF me.id IS NULL OR NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores da família podem criar papéis personalizados.'
			USING ERRCODE = 'check_violation';
	END IF;

	v_label := trim(coalesce(p_label, ''));
	IF v_label = '' THEN
		RAISE EXCEPTION 'Informe o nome do papel.'
			USING ERRCODE = 'check_violation';
	END IF;
	IF char_length(v_label) > 30 THEN
		RAISE EXCEPTION 'O nome do papel pode ter no máximo 30 caracteres.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- Optional emoji: short free text (multi-codepoint emoji are fine); the
	-- client input caps it too — this only blocks abuse.
	v_emoji := NULLIF(trim(coalesce(p_emoji, '')), '');
	IF v_emoji IS NOT NULL AND char_length(v_emoji) > 16 THEN
		RAISE EXCEPTION 'Emoji inválido.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- F-41: the freemium gate — creation is Premium; existing custom roles keep
	-- working on free (add-only, like F-37).
	IF NOT public.is_premium(me.family_id) THEN
		RAISE EXCEPTION 'Papéis personalizados são um recurso Premium. Ative o Premium para criar papéis exclusivos da sua família.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- Friendly duplicate check against built-ins AND this family's rows (the
	-- partial unique index still backs the per-family half against races).
	IF EXISTS (SELECT 1 FROM public.roles r
	           WHERE (r.family_id IS NULL OR r.family_id = me.family_id)
	             AND lower(r.label_pt) = lower(v_label)) THEN
		RAISE EXCEPTION 'Já existe um papel com esse nome.'
			USING ERRCODE = 'check_violation';
	END IF;

	INSERT INTO public.roles (role, label_pt, family_id, emoji)
	VALUES (v_label, v_label, me.family_id, v_emoji)
	RETURNING id INTO new_id;

	RETURN new_id;
END;
$$;

ALTER FUNCTION public.create_custom_role(text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.create_custom_role(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_custom_role(text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_custom_role(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_custom_role(text, text) TO service_role;

-- ── 4. delete_custom_role — admin only, unused roles only ───────────────────

CREATE OR REPLACE FUNCTION public.delete_custom_role(p_role_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
	me public.profiles%ROWTYPE;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();

	IF me.id IS NULL OR NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores da família podem excluir papéis personalizados.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- Custom rows of MY family only — built-ins and other families' rows are
	-- out of reach by construction.
	IF NOT EXISTS (SELECT 1 FROM public.roles
	               WHERE id = p_role_id AND family_id = me.family_id) THEN
		RAISE EXCEPTION 'Papel personalizado não encontrado na sua família.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- Unused only: any referencing profile or invitation (even departed members
	-- and old invites — the FKs would block the delete regardless) refuses with
	-- a friendly message instead of a raw FK violation.
	IF EXISTS (SELECT 1 FROM public.profiles WHERE role_id = p_role_id)
	   OR EXISTS (SELECT 1 FROM public.family_invitations WHERE role_id = p_role_id) THEN
		RAISE EXCEPTION 'Este papel está em uso por um membro ou convite e não pode ser excluído.'
			USING ERRCODE = 'check_violation';
	END IF;

	DELETE FROM public.roles WHERE id = p_role_id;
END;
$$;

ALTER FUNCTION public.delete_custom_role(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.delete_custom_role(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_custom_role(bigint) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_custom_role(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_custom_role(bigint) TO service_role;

-- ── 5. create_invitation — role check becomes family-scoped ─────────────────
-- Body copied VERBATIM from 20260724150000 (T-41); ONLY the role-existence
-- check gains the family scope (built-in OR my family's custom role).

CREATE OR REPLACE FUNCTION public.create_invitation(p_email text, p_role_id bigint)
RETURNS TABLE (invitation_id bigint, token uuid, expires_at timestamp with time zone)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
	me         public.profiles%ROWTYPE;
	inv        public.family_invitations%ROWTYPE;
	max_seats  int := public.setting_int('max_caregivers', 4);
	free_seats int := public.setting_int('free_caregivers', 2);
	taken      int;
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

	-- F-41: a role is assignable when built-in OR a custom role of MY family —
	-- another family's custom role id must not resolve.
	IF NOT EXISTS (SELECT 1 FROM public.roles
	               WHERE id = p_role_id
	                 AND (family_id IS NULL OR family_id = me.family_id)) THEN
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

	-- F-37 (T-41: free_caregivers from settings) — the free tier includes N
	-- caregivers; adding beyond that is Premium. Add-only + grandfather (F-32).
	IF taken >= free_seats AND NOT public.is_premium(me.family_id) THEN
		RAISE EXCEPTION 'Famílias no plano gratuito incluem % responsáveis. Para adicionar mais (avós, babá, etc.), ative o Premium.', free_seats
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

-- ── 6. set_member_role — role check becomes family-scoped ───────────────────
-- Body copied VERBATIM from 20260715043019 (F-27); ONLY the role-existence
-- check gains the family scope.

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

	-- F-41: built-in OR my family's custom role only.
	IF NOT EXISTS (SELECT 1 FROM public.roles
	               WHERE id = p_role_id
	                 AND (family_id IS NULL OR family_id = me.family_id)) THEN
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

-- ── 7. handle_new_user — founder role lookup matches built-ins only ─────────
-- Body copied VERBATIM from 20260724150000 (T-41); ONLY the founder role
-- lookup gains AND family_id IS NULL (a founder has no family yet — a custom
-- row from any family must never resolve).

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
