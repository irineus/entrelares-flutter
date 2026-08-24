-- U-13 (pre-production round) — the language the member actually READS the app
-- in, so the server-side senders stop writing PT-BR to an English reader.
--
-- WHAT WAS BROKEN. `profiles.language` is written in exactly one place: the
-- LanguagePicker, and only while signed in. But the picker is rendered on the
-- PUBLIC screens (login, sign-up, reset — where the visitor is anonymous, so
-- nothing is written) and in the DESKTOP top bar. A signed-in phone had no
-- picker at all, which left two ways to be reading English — `navigator.language`
-- detection, or a pick made on the login screen — and NEITHER reached the
-- column. Every profile in DEV was NULL, and the swap e-mail correctly resolved
-- NULL to pt-BR while the in-app notification (rendered by the client, which
-- does know) came out in English. Same event, two languages.
--
-- WHY A SECOND COLUMN AND NOT A WRITE TO `language`. `language` also drives the
-- cross-device adoption rule (LocalizationService.ShouldAdopt): a device with no
-- explicit local pick follows the profile. Recording a DETECTED language there
-- would make detection contagious — a Brazilian who once opened the app on a
-- laptop with an English browser would find their own PHONE switched to English
-- on the next visit, having never chosen anything. So the two facts stay apart:
--
--   language           = an explicit CHOICE. Drives adoption. Unchanged.
--   language_detected  = what this member's session actually renders in.
--                        Written on every sign-in that disagrees with it.
--                        Read by NOTHING on the client — it must never move a
--                        screen, only a sender.
--
-- WHY THE GENERATED COLUMN. Senders want one answer, not a coalesce they have to
-- remember: `language_effective` is that answer, and a future e-mail function
-- gets it right by reading the obvious column instead of by knowing this file.
-- STORED (not a view) so PostgREST exposes it like any other column and the
-- Edge Functions keep their single `.select(...)`.
--
-- No backfill, for the same reason the original migration gave: guessing pt-BR
-- for someone who has not come back would erase the difference between what we
-- know and what we assume — and pt-BR is already what a NULL resolves to, so the
-- guess would buy nothing. The column fills itself on each member's next visit.

ALTER TABLE public.profiles
	ADD COLUMN IF NOT EXISTS language_detected text;

DO $$
BEGIN
	IF NOT EXISTS (
		SELECT 1 FROM pg_constraint
		WHERE conrelid = 'public.profiles'::regclass
		  AND conname = 'profiles_language_detected_check'
	) THEN
		ALTER TABLE public.profiles
			ADD CONSTRAINT profiles_language_detected_check
			CHECK (language_detected IS NULL OR language_detected IN ('pt-BR', 'en'));
	END IF;
END $$;

ALTER TABLE public.profiles
	ADD COLUMN IF NOT EXISTS language_effective text
	GENERATED ALWAYS AS (COALESCE(language, language_detected)) STORED;

COMMENT ON COLUMN public.profiles.language IS
	'U-13: UI/e-mail language this member CHOSE (pt-BR | en). NULL = never chose. Drives the cross-device adoption rule; senders read language_effective instead.';

COMMENT ON COLUMN public.profiles.language_detected IS
	'U-13: the language this member''s session actually renders in (pt-BR | en), recorded on sign-in. Never drives a screen — it exists so the server-side senders know what the client already knows.';

COMMENT ON COLUMN public.profiles.language_effective IS
	'U-13: what every server-side sender must read — the choice when there is one, the detection otherwise. NULL only until the member''s first visit after Aug/2026; senders resolve NULL to pt-BR.';
