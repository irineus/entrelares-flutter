-- =============================================================================
-- S-15 (A-1 + A-5, PR2b) — MATERIAL policy bump: 2026-07-28 → 2026-07-30
--
-- The server half of the two-place checklist. Helpers/PolicyVersions.cs moves the
-- code constant; this migration moves the settings the RPC validates against.
-- Doing only ONE of the two is the failure mode the checklist exists to prevent:
-- with the code ahead of `policy.current_version`, accept_current_policy refuses
-- EVERY accept ("atualize o aplicativo") on a build that is already current, and
-- from the enforce date nobody can get past the gate.
-- ReconsentGateTests.CodeConstant_MatchesServerSetting (and its enforce_from twin,
-- added in this delivery) turn that into a red CI gate instead of a live lockout.
--
-- WHAT MAKES THIS VERSION MATERIAL — the two findings the parecer flagged as such:
--   · A-1.1/A-1.2 — the declaration each path into a family now accepts (creator =
--     ciência e responsabilidade; invitee = confidencialidade), folded into the
--     general acceptance at sign-up and mirrored on /policy-update via
--     profiles.joined_via_invite (PR2a);
--   · A-5 — the Terms' new judicial-notice suspension clause.
-- A-1.3 (§3/§5 aligned to reality: no structured child-data collection) and C-8
-- (the PDF header name is ephemeral) ship in the same text but are NOT material —
-- declaring a SMALLER treatment than before is a clarification in the subject's
-- favour.
--
-- WHY enforce_from IS 2026-09-30 AND DELIBERATELY PROVISIONAL (owner, 30/07/2026):
-- the 15-day notice exists so the subject can READ the new text before losing
-- access, and they can only do that once it is in PRODUCTION. Counting from this
-- QA merge would burn the whole window while the text is invisible to the people
-- it binds. So this seeds a loose date — the gate merely WARNS until then, which
-- is the correct behaviour anyway — and a one-line corrective migration sets it to
-- PROMOTION DATE + 15 when dev→master happens (mirror Helpers/PolicyVersions.cs in
-- the same delivery). Same lesson as v1.6.35: the window starts when the user can
-- actually see the text.
--
-- UPSERT, not UPDATE: prod carries migration-state drift from an old stale-link
-- incident, so a row this delivery assumes exists may not. ON CONFLICT DO UPDATE
-- lands correctly on both a project that already has the S-15 seed and one that
-- somehow does not. value_type is 'string' — the CHECK accepts only
-- ('int','decimal','bool','string','json'), and 'text' cost one red gate.
-- =============================================================================

INSERT INTO public.app_settings (key, value, value_type, category, description, is_public) VALUES
	('policy.current_version', '2026-07-30', 'string', 'legal', 'Versão vigente da Política/Termos que o aceite deve referenciar (espelha Helpers/PolicyVersions.cs).', true),
	('policy.enforce_from',    '2026-09-30', 'string', 'legal', 'Data a partir da qual a falta de aceite da versão vigente bloqueia o uso. PROVISÓRIA: ajustar para a data da promoção dev→master + 15 dias (parecer B-4).', true)
ON CONFLICT (key) DO UPDATE
	SET value       = EXCLUDED.value,
	    value_type  = EXCLUDED.value_type,
	    category    = EXCLUDED.category,
	    description = EXCLUDED.description,
	    is_public   = EXCLUDED.is_public,
	    updated_at  = timezone('utc'::text, now());
