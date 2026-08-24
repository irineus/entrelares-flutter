-- =============================================================================
-- S-15 (A-1) — mark who joined by invitation
--
-- The legal review needs the app to show DIFFERENT declarations to the two ways
-- of entering a family (adendo v1 A-1, refined in adendo v2 A-1.1/A-1.2):
--
--   · whoever CREATES the family accepts a "termo de ciência e responsabilidade"
--     — the system has no dedicated child fields, and they undertake to enter
--     only what the routine requires in free text;
--   · whoever is INVITED accepts a confidentiality declaration instead — they
--     hold no parental authority and must not consent for the child's data.
--
-- Register.razor knows which path it is (the invite token is in hand). The
-- RE-CONSENT gate does not: it runs for profiles created long ago, where no
-- invite context survives. Hence a persisted marker.
--
-- Design: derived from family_invitations, NOT from handle_new_user.
--   The obvious place would be handle_new_user, which already branches on the
--   invite token — but that function is ~100 lines re-emitted verbatim by every
--   migration that touches it, and a transcription slip there breaks ALL sign-ups.
--   A tiny independent trigger carries none of that risk.
--   The rule is ordering-independent on purpose: ANY invitation ever addressed to
--   this e-mail means the person was invited. It does not matter whether
--   handle_new_user marks the invitation accepted before or after inserting the
--   profile, which is exactly the coupling we want to avoid.
-- =============================================================================

-- ── 1. Column ─────────────────────────────────────────────────────────────────
-- NOT NULL DEFAULT false: a family's creator is the absence of an invitation.

ALTER TABLE public.profiles
	ADD COLUMN IF NOT EXISTS joined_via_invite boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.profiles.joined_via_invite IS
	'S-15/A-1: true when this profile entered through an invitation. Decides which declaration the sign-up and the re-consent screen show (creator = ciência/responsabilidade; invitee = confidencialidade).';

-- ── 2. Backfill — exact, not heuristic ───────────────────────────────────────
-- Every invited member necessarily has an invitation row addressed to their
-- e-mail; a founder never does. This is why the marker is NOT inferred from
-- "oldest profile in the family" — S-11's admin succession makes that wrong.

UPDATE public.profiles p
   SET joined_via_invite = true
 WHERE EXISTS (
	SELECT 1 FROM public.family_invitations i
	 WHERE lower(i.email) = lower(p.email)
 );

-- ── 3. Set it on INSERT, and freeze it on UPDATE ─────────────────────────────
-- The column decides WHICH legal declaration a user is asked to accept, so a
-- client able to flip it could route itself to the weaker text. The client is
-- allowed to edit its own profile (name, etc.), so the protection lives here.
--
-- On UPDATE the old value is PRESERVED SILENTLY rather than raising: a client
-- that sends the whole row back (instead of a single column) would otherwise hit
-- an exception on an edit that has nothing to do with this field, breaking
-- ordinary profile editing. Silently pinning it is both safe and non-disruptive.

CREATE OR REPLACE FUNCTION public.set_joined_via_invite()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
	IF TG_OP = 'UPDATE' THEN
		NEW.joined_via_invite := OLD.joined_via_invite;   -- immutable after creation
		RETURN NEW;
	END IF;

	NEW.joined_via_invite := EXISTS (
		SELECT 1 FROM public.family_invitations i
		 WHERE lower(i.email) = lower(NEW.email)
	);
	RETURN NEW;
END;
$$;

ALTER FUNCTION public.set_joined_via_invite() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.set_joined_via_invite() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_set_joined_via_invite ON public.profiles;

CREATE TRIGGER trg_set_joined_via_invite
	BEFORE INSERT OR UPDATE ON public.profiles
	FOR EACH ROW
	EXECUTE FUNCTION public.set_joined_via_invite();
