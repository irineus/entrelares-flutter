-- U-13 — the recipient's language, on the profile.
--
-- WHY THE COLUMN EXISTS AT ALL (the client already keeps the choice in
-- localStorage): the server-side senders have no browser to ask. The two e-mail
-- Edge Functions (send-swap-email, send-account-email) and the cron notifications
-- run with no session and no navigator.language — without this column they can
-- only guess, and the whole point of the item is that a tester who reads the app
-- in English must not receive a PT-BR invitation e-mail.
--
-- So the two stores are NOT redundant: localStorage is the CLIENT's truth (it has
-- to work before any session exists — the login screen), this column is the
-- SERVER's copy of it, written whenever the user picks a language.
--
-- NULL means "never chose / pre-U-13 profile". Senders read NULL as pt-BR, which
-- is what every existing row is: the product had no other language until now.
-- Deliberately NOT backfilled to 'pt-BR' — a NULL that means "unknown" and a
-- 'pt-BR' that means "asked for Portuguese" are different facts, and the second
-- one would be a lie about every profile created before today.
--
-- The column is intentionally left OUT of enforce_profile_protection: that
-- trigger is a blacklist of system-managed / privilege-bearing fields
-- (color_slot, family_id, is_admin, role_id), and a display language is neither.
-- The existing profiles_own_update policy is the whole authorization story —
-- a member may change their own language and nobody else's.

ALTER TABLE public.profiles
	ADD COLUMN IF NOT EXISTS language text;

-- Same closed set as AppLanguages: one Portuguese, one everything-else. A third
-- language means widening this constraint in the same migration that adds it.
DO $$
BEGIN
	IF NOT EXISTS (
		SELECT 1 FROM pg_constraint
		WHERE conrelid = 'public.profiles'::regclass
		  AND conname = 'profiles_language_check'
	) THEN
		ALTER TABLE public.profiles
			ADD CONSTRAINT profiles_language_check
			CHECK (language IS NULL OR language IN ('pt-BR', 'en'));
	END IF;
END $$;

COMMENT ON COLUMN public.profiles.language IS
	'U-13: UI/e-mail language chosen by this member (pt-BR | en). NULL = never chose; senders treat it as pt-BR.';
