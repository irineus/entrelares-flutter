-- =============================================================================
-- S-15 (B-4) — Re-consent gate on policy change
--
-- Legal review of 30/07/2026, item B-4 (Obrigatório/bloqueante): "novo aceite é
-- exigido para mudanças materiais. O bloqueio do uso (hard lock) até o aceite é
-- válido e proporcional. Aviso de 15 dias."
--
-- S-13 recorded consent at sign-up (profiles.consent_accepted_at /
-- consent_policy_version) but nothing ever RE-collected it: when the policy text
-- changed, existing users kept their old stamp and legacy profiles stayed NULL.
-- This migration adds the server half of the gate.
--
-- Design decisions (locked with the product owner, July 2026):
--
-- 1. The version a user accepts is NOT taken on trust from the client. The
--    burden of proving consent is the controller's (LGPD art. 8 §1), so a record
--    the CLIENT could dictate is weak evidence. The RPC validates the submitted
--    version against `policy.current_version` in app_settings (T-41) and REFUSES
--    a mismatch. Consequence, by design: a stale cached PWA that still ships an
--    older policy text cannot stamp a consent it never displayed — it gets a
--    clear error and the UI tells the user to update the app.
--
-- 2. `policy.enforce_from` carries the 15-day notice window. Before that date a
--    profile on an old version sees a NON-blocking notice; from it, the hard
--    lock. It lives in settings (not code) so the window can be adjusted
--    operationally without a deploy — and it is PUBLIC so the client mirrors it.
--
-- 3. MATERIAL-CHANGE CHECKLIST (both places, same delivery): bump
--    Helpers/PolicyVersions.cs AND `policy.current_version` here, and set
--    `policy.enforce_from` to publication + 15 days. Forgetting the setting makes
--    the RPC refuse every accept with an explicit message — a loud failure, never
--    a silent one that would let a material change slip through unconsented.
-- =============================================================================

-- ── 1. Settings — the server's source of truth for the gate ──────────────────
-- Seeded with the CURRENT published version (2026-07-28, the T-39 PR3 billing
-- change). enforce_from is seeded in the PAST on purpose: this version is
-- already published and its 15-day notice has long elapsed, so the legacy NULL
-- profiles the gate is meant to capture are captured from the first deploy.

INSERT INTO public.app_settings (key, value, value_type, category, description, is_public) VALUES
	('policy.current_version', '2026-07-28', 'string', 'legal', 'Versão vigente da Política/Termos que o aceite deve referenciar (espelha Helpers/PolicyVersions.cs).', true),
	('policy.enforce_from',    '2026-07-28', 'string', 'legal', 'Data a partir da qual a falta de aceite da versão vigente bloqueia o uso (publicação + 15 dias, conforme parecer B-4).', true)
ON CONFLICT (key) DO NOTHING;

-- ── 2. accept_current_policy — the only way a profile's consent is re-stamped ─
-- SECURITY DEFINER because the client never writes to profiles directly
-- (architecture invariant). It acts ONLY on the caller's own row: auth.uid()
-- is the whole authorization, so there is no way to stamp someone else's
-- consent, which would be fabricated evidence.

CREATE OR REPLACE FUNCTION public.accept_current_policy(p_version text)
RETURNS timestamp with time zone
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	expected  text;
	stamped   timestamp with time zone;
	rows_hit  int;
BEGIN
	IF auth.uid() IS NULL THEN
		RAISE EXCEPTION 'Sessão não autenticada.' USING ERRCODE = '42501';
	END IF;

	-- NULL::text explicitly: an untyped NULL leaves the argument's type to
	-- resolution, and this whole function is the one thing that must not fail
	-- obscurely at runtime.
	expected := public.setting_text('policy.current_version', NULL::text);

	IF expected IS NULL THEN
		-- Never silently accept an unverifiable version: without the setting we
		-- cannot prove WHICH text the user saw (see decision 3 above).
		RAISE EXCEPTION 'Configuração policy.current_version ausente — aceite não pode ser registrado.'
			USING ERRCODE = 'P0002';
	END IF;

	IF p_version IS DISTINCT FROM expected THEN
		RAISE EXCEPTION 'Versão da política desatualizada (enviada: %, vigente: %). Atualize o aplicativo.',
			coalesce(p_version, '(nula)'), expected USING ERRCODE = '22023';
	END IF;

	stamped := timezone('utc'::text, now());

	UPDATE public.profiles
	   SET consent_accepted_at    = stamped,
	       consent_policy_version = expected
	 WHERE user_id = auth.uid()
	   AND left_at IS NULL;   -- S-11: a frozen profile is immutable

	GET DIAGNOSTICS rows_hit = ROW_COUNT;

	IF rows_hit = 0 THEN
		RAISE EXCEPTION 'Perfil ativo não encontrado para a sessão atual.' USING ERRCODE = 'P0002';
	END IF;

	RETURN stamped;
END;
$$;

ALTER FUNCTION public.accept_current_policy(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.accept_current_policy(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_current_policy(text) TO authenticated;

COMMENT ON FUNCTION public.accept_current_policy(text) IS
	'S-15/B-4: re-stamps the CALLER''s consent (art. 8 §1) after validating the version against policy.current_version. Refuses stale clients.';
