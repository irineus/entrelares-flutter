-- =============================================================================
-- S-15 (B-4) — pin the re-consent notice window to the PRODUCTION promotion
--
-- Runbook section 7, item 1: the `dev`→`master` promotion must carry this, in
-- the same delivery as the matching `Helpers/PolicyVersions.EnforceFrom`.
--
-- WHY IT MOVES AGAIN. `2026-09-30` was deliberately loose: PR2b shipped the
-- material text to `dev` with no idea when it would reach production, and the
-- 15-day notice the legal review requires only means anything once the subject
-- can READ the text — which happens in PRODUCTION, not on the QA merge. Setting
-- a real date before knowing the promotion date could only be wrong in one of
-- two ways: too early (a window that expires while the text is still invisible,
-- i.e. the exact B-4 failure the 30/07 fix already corrected once) or too late
-- (a window longer than the one the review designed). The loose value chose the
-- harmless error on purpose; this migration replaces it with the real one.
--
--   promotion 2026-08-01 + 15 days = 2026-08-16
--
-- Until this date the gate only WARNS (ConsentGateState.Notice); from it, a
-- profile stamped with an older version — or a legacy NULL, which S-13 left
-- unstamped rather than fabricate consent evidence — is blocked until it
-- accepts. Shortening an already-published window would be worse than leaving
-- it long, so this value must not move again without a new material change.
--
-- The client constant and this row are two halves of ONE decision:
-- `ReconsentGateTests.EnforceFromConstant_MatchesServerSetting` fails the build
-- if only one of them moves, which is what turns a would-be live lockout (or a
-- silently unenforced policy) into a red CI gate.
-- =============================================================================

UPDATE public.app_settings
   SET value      = '2026-08-16',
       updated_at = timezone('utc'::text, now())
 WHERE key = 'policy.enforce_from';
