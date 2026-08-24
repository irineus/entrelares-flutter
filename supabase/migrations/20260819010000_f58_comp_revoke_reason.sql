-- =============================================================================
-- F-58 (QA round 4) — the REVOKE gets its own reason
--
-- QA 3 put the courtesy's note into the family-visible entry; the owner then
-- noticed the revoke echoing the GRANT's note in the same green pill and asked
-- for better. Two halves: the renderer now draws a lone old value in the
-- "undone" style (client change, 1.8.12), and — here — the revocation accepts
-- ITS OWN optional reason: the family entry becomes
-- old_value = the courtesy's note (what is being undone) and
-- new_value = the revoke's reason (why), rendering as "note → reason".
--
-- Body from 20260819000000 (the latest); ONLY the revoke branch's two INSERTs
-- change (T-45 lesson: replace from the newest body, and say what moved).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_set_comp(p_family_id bigint, p_granted boolean, p_note text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	fam public.families%ROWTYPE;
BEGIN
	IF NOT public.is_platform_operator() THEN
		RAISE EXCEPTION 'Acesso restrito à operação da plataforma.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	IF NOT public.is_elevated() THEN
		RAISE EXCEPTION 'ELEVATION_REQUIRED: Confirme sua senha para alterar o plano de uma família.'
			USING ERRCODE = 'insufficient_privilege';
	END IF;

	SELECT * INTO fam FROM public.families WHERE id = p_family_id FOR UPDATE;
	IF NOT FOUND THEN
		RAISE EXCEPTION 'Família não encontrada: %.', p_family_id
			USING ERRCODE = 'check_violation';
	END IF;

	IF p_granted AND fam.comp_premium_at IS NULL THEN
		UPDATE public.families
		SET comp_premium_at = timezone('utc', now()), comp_premium_note = p_note
		WHERE id = p_family_id;

		INSERT INTO public.operator_audit_logs (operator_user_id, action, family_id, old_value, new_value)
		VALUES (auth.uid(), 'comp_granted', p_family_id, NULL, COALESCE(p_note, 'comp'));

		INSERT INTO public.account_logs (family_id, action, new_value)
		VALUES (p_family_id, 'comp_premium_granted', p_note);

	ELSIF NOT p_granted AND fam.comp_premium_at IS NOT NULL THEN
		UPDATE public.families
		SET comp_premium_at = NULL, comp_premium_note = NULL
		WHERE id = p_family_id;

		-- QA 4: the revoke's own reason (p_note) joins both trails; the
		-- courtesy's note stays as what is being undone.
		INSERT INTO public.operator_audit_logs (operator_user_id, action, family_id, old_value, new_value)
		VALUES (auth.uid(), 'comp_revoked', p_family_id, fam.comp_premium_note, p_note);

		INSERT INTO public.account_logs (family_id, action, old_value, new_value)
		VALUES (p_family_id, 'comp_premium_revoked', fam.comp_premium_note, p_note);
	END IF;
END;
$$;

ALTER FUNCTION public.admin_set_comp(bigint, boolean, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.admin_set_comp(bigint, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_comp(bigint, boolean, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_comp(bigint, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_comp(bigint, boolean, text) TO service_role;
