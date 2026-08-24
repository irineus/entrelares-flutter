-- U-23 — first-run onboarding: the three facts the app cannot derive.
--
-- The activation checklist reads REAL state for everything it can: whether a
-- second caregiver exists or an invitation is open, whether the family has any
-- planned day. Those are queries, not flags, and they are deliberately not
-- stored here — a stored "done" that disagrees with the family's actual state is
-- worse than no checklist, because it tells a brand-new user they finished
-- something they never did.
--
-- What CANNOT be derived is what the person has SEEN or DECIDED. Three facts:
--   · they opened the "how a swap works" explanation (the one step of the
--     checklist that is legitimately seen-based — understanding is not a row in
--     any table);
--   · they ran, or skipped, the guided tour (so it never runs twice);
--   · they put the checklist away (a dismissal is a real decision, not noise).
--
-- WHY ON THE PROFILE AND NOT IN localStorage. localStorage is per DEVICE. A
-- parent who signs in on a second phone would meet the first-run experience
-- again — and, worse, a dismissal made on the first device would silently not
-- count. The onboarding is about a PERSON, so it is stored where the person is.
-- (Contrast with U-13's language, which lives in BOTH: there localStorage is the
-- client's truth because it must work before a session exists. Onboarding never
-- renders before login, so it needs no pre-session copy.)
--
-- WHY TIMESTAMPS AND NOT BOOLEANS. Same shape as consent_accepted_at, left_at
-- and deletion_scheduled_for: a boolean answers "did it happen", a timestamp
-- answers that AND "when" — which is the only way a future question like "do
-- people dismiss the checklist before or after inviting?" can be answered from
-- data that already exists. NULL means "not yet", uniformly.
--
-- These columns are intentionally left OUT of enforce_profile_protection: that
-- trigger is a blacklist of system-managed / privilege-bearing fields
-- (color_slot, family_id, is_admin, role_id), and "I read the explanation" is
-- neither. The existing profiles_own_update policy is the whole authorization
-- story — a member stamps their own onboarding and nobody else's.

ALTER TABLE public.profiles
	ADD COLUMN IF NOT EXISTS onboarding_swap_explained_at   timestamptz,
	ADD COLUMN IF NOT EXISTS onboarding_tour_seen_at        timestamptz,
	ADD COLUMN IF NOT EXISTS onboarding_dismissed_at        timestamptz;

COMMENT ON COLUMN public.profiles.onboarding_swap_explained_at IS
	'U-23: when this member opened the "how a swap works" explanation. NULL = never.';
COMMENT ON COLUMN public.profiles.onboarding_tour_seen_at IS
	'U-23: when this member finished or skipped the guided tour. NULL = never ran.';
COMMENT ON COLUMN public.profiles.onboarding_dismissed_at IS
	'U-23: when this member put the "Primeiros passos" checklist away. NULL = still showing.';
