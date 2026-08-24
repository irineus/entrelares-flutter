-- =============================================================================
-- S-15 (A-4, PR3b) — purge invitations that were never accepted
--
-- The legal review required the invitation e-mail to state BOTH periods (the
-- complementary parecer settled the contradiction in the original wording, which
-- mentioned only 30 days while the link expires in 7):
--
--   "Este convite é válido por 7 dias. Seu nome e e-mail foram inseridos sob o
--    legítimo interesse do convidador. Caso este convite não seja aceito, seu
--    registro será permanentemente expurgado de nossos sistemas em até 30 dias."
--
-- The 7-day expiry already existed. The 30-day purge did NOT — this migration is
-- what makes the sentence true. An invitee who never joined never consented to
-- anything; their name and e-mail sit here purely on the inviter's legitimate
-- interest, and once the invitation can no longer be accepted that interest is
-- spent (art. 15, I — the purpose is achieved or no longer applies).
--
-- WHAT IS PURGED: invitations with accepted_at IS NULL older than 30 days —
-- expired, revoked and still-pending alike. All three are "not accepted", and
-- none can be accepted anymore (the link dies at 7 days).
--
-- WHAT IS NOT: anything with accepted_at set. Those rows are the evidence that a
-- member joined by invitation, which is exactly what profiles.joined_via_invite
-- is derived from (PR2a) — set_joined_via_invite() looks the e-mail up in this
-- table on INSERT. Deleting an ACCEPTED invitation would silently reclassify a
-- future re-registration of the same person as a family creator, showing them the
-- wrong legal declaration. The accepted_at filter is not a nicety; it is what
-- keeps A-1 correct.
--
-- 30 days counted from created_at, not from expires_at: "em até 30 dias" reads
-- from the invitation, and counting from creation is both the literal reading and
-- the one more favourable to the subject (37 days would overshoot what we
-- promised). Existing rows are covered — the first run purges whatever is already
-- past the window.
--
-- Scheduling: called by the purge-deleted cron (daily), alongside the S-11
-- account/family purges and the S-13 notification retention. No new
-- infrastructure and no new runbook step.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.purge_stale_invitations()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	removed integer;
BEGIN
	DELETE FROM public.family_invitations
	 WHERE accepted_at IS NULL
	   AND created_at < timezone('utc', now()) - interval '30 days';

	GET DIAGNOSTICS removed = ROW_COUNT;
	RETURN removed;
END;
$$;

ALTER FUNCTION public.purge_stale_invitations() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purge_stale_invitations() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_stale_invitations() TO service_role;

COMMENT ON FUNCTION public.purge_stale_invitations() IS
	'S-15/A-4: deletes never-accepted invitations older than 30 days, making the invitation e-mail''s purge promise true. NEVER touches accepted_at rows — profiles.joined_via_invite is derived from them.';
