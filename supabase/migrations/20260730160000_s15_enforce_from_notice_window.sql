-- =============================================================================
-- S-15 (B-4) — correct the re-consent gate's notice window
--
-- Fix-forward on 20260730120000, which is already applied: it seeded
-- policy.enforce_from with the POLICY TEXT's date (2026-07-28), reasoning that
-- the text had been published long enough for its 15-day window to have elapsed.
--
-- That reasoning was wrong. What is new is not the text but the ENFORCEMENT: no
-- user was ever told "accept the current version or lose access". Enforcing from
-- the text's date means every legacy profile (consent_policy_version NULL — the
-- ones S-13 deliberately left unstamped rather than fabricating evidence) is
-- blocked the instant the gate deploys, with ZERO notice. That is exactly what
-- the legal review's "aviso de 15 dias" exists to prevent, and the E2E suite
-- caught it immediately: its users are created without the metadata, so every UI
-- flow was bounced to the acceptance screen.
--
-- The window therefore runs from the GATE's deploy (2026-07-30), not from the
-- text's publication: 2026-07-30 + 15 = 2026-08-14. Mirrors
-- Helpers/PolicyVersions.EnforceFrom, which the client actually reads.
-- =============================================================================

UPDATE public.app_settings
   SET value      = '2026-08-14',
       updated_at = timezone('utc'::text, now())
 WHERE key = 'policy.enforce_from';

COMMENT ON TABLE public.app_settings IS
	'T-41 operational parameters. policy.* (S-15): current_version is validated by accept_current_policy; enforce_from is the date the re-consent hard lock starts (publication + 15 days, per the 30/07/2026 legal review) and must stay in step with Helpers/PolicyVersions.';
