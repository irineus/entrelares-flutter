-- ============================================================================
-- F-41 (QA round 2) — update_custom_role: edit a custom role's label/emoji
--
-- The custom-roles management moved to its own page (/custom-roles) and gained
-- EDIT (QA feedback: the grid outgrew the family page; editing did not exist).
-- Decision (owner, Aug 2026): editing is PREMIUM, like creation — the free
-- plan keeps using (and deleting) existing custom roles, but reshaping them
-- (rename / emoji change) is part of the premium feature. Deletion stays free.
--
-- Editing an IN-USE role is allowed by design — renaming "Vovó" to "Vovó
-- materna" is the whole point; members referencing the role just render the
-- new label (role_id is the identity, the label is display).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_custom_role(p_role_id bigint, p_label text, p_emoji text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
	me      public.profiles%ROWTYPE;
	v_label text;
	v_emoji text;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();

	IF me.id IS NULL OR NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores da família podem alterar papéis personalizados.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- Custom rows of MY family only — built-ins and other families' rows are
	-- out of reach by construction (mirrors delete_custom_role).
	IF NOT EXISTS (SELECT 1 FROM public.roles
	               WHERE id = p_role_id AND family_id = me.family_id) THEN
		RAISE EXCEPTION 'Papel personalizado não encontrado na sua família.'
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

	v_emoji := NULLIF(trim(coalesce(p_emoji, '')), '');
	IF v_emoji IS NOT NULL AND char_length(v_emoji) > 16 THEN
		RAISE EXCEPTION 'Emoji inválido.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- F-41: editing is Premium, like creation (owner decision, Aug 2026).
	IF NOT public.is_premium(me.family_id) THEN
		RAISE EXCEPTION 'A edição de papéis personalizados é um recurso Premium. Ative o Premium para alterá-los.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- Friendly duplicate check against built-ins AND this family's OTHER rows
	-- (renaming a role to its own current label is a no-op, not a duplicate).
	IF EXISTS (SELECT 1 FROM public.roles r
	           WHERE (r.family_id IS NULL OR r.family_id = me.family_id)
	             AND r.id <> p_role_id
	             AND lower(r.label_pt) = lower(v_label)) THEN
		RAISE EXCEPTION 'Já existe um papel com esse nome.'
			USING ERRCODE = 'check_violation';
	END IF;

	UPDATE public.roles
	SET role = v_label, label_pt = v_label, emoji = v_emoji
	WHERE id = p_role_id;
END;
$$;

ALTER FUNCTION public.update_custom_role(bigint, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.update_custom_role(bigint, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_custom_role(bigint, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_custom_role(bigint, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_custom_role(bigint, text, text) TO service_role;
