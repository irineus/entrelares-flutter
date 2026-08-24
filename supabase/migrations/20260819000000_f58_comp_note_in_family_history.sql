-- =============================================================================
-- F-58 (QA round 3) — the comp's REASON reaches the family's history
--
-- The owner granted a courtesy WITH a reason and the family's account history
-- showed only "Premium cortesia concedido à família" — the note went to the
-- operator trail and to families.comp_premium_note, but not into the family's
-- own account_logs row. The timeline renderer already displays old/new values,
-- so the fix is data, not UI: the grant records the note as the entry's value,
-- and the revoke records WHICH note is being revoked.
--
-- Existing rows are left untouched — the history is a record, not a document
-- to rewrite (same reason the plan-history trigger did not backfill).
--
-- Body from 20260818150000 (the only prior definition of admin_set_comp);
-- ONLY the two account_logs INSERTs change (T-45 lesson: replace from the
-- LATEST body, and say what moved).
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

		-- QA 3: the reason travels WITH the family-visible entry.
		INSERT INTO public.account_logs (family_id, action, new_value)
		VALUES (p_family_id, 'comp_premium_granted', p_note);

	ELSIF NOT p_granted AND fam.comp_premium_at IS NOT NULL THEN
		UPDATE public.families
		SET comp_premium_at = NULL, comp_premium_note = NULL
		WHERE id = p_family_id;

		INSERT INTO public.operator_audit_logs (operator_user_id, action, family_id, old_value, new_value)
		VALUES (auth.uid(), 'comp_revoked', p_family_id, fam.comp_premium_at::text, NULL);

		-- QA 3: the revoke shows WHICH courtesy (its note) is being undone.
		INSERT INTO public.account_logs (family_id, action, old_value)
		VALUES (p_family_id, 'comp_premium_revoked', fam.comp_premium_note);
	END IF;
END;
$$;

ALTER FUNCTION public.admin_set_comp(bigint, boolean, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.admin_set_comp(bigint, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_comp(bigint, boolean, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_comp(bigint, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_comp(bigint, boolean, text) TO service_role;
