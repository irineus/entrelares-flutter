-- =============================================================================
-- S-10 — QA refinement (fix forward): self-actions in account_logs are
-- visible ONLY to their author.
--
-- The first S-10 cut gave account_logs a family-wide SELECT (mirroring the
-- calendar's activity_logs). QA review: that is right for GOVERNANCE events
-- (admin grants/revokes, role/name changes, family rename, invitations —
-- two-party accountability demands the other side sees them), but the
-- whitelisted SELF-actions are personal signals, sensitive in a custody
-- dispute: seeing the co-parent exported their data (possible litigation
-- prep) or changed their password ("they are locking things down") serves
-- no governance purpose and may chill the exercise of personal rights.
-- Those rows exist so the ACCOUNT OWNER can detect misuse of their own
-- account — so only the author sees them.
-- =============================================================================

DROP POLICY IF EXISTS account_logs_family_read ON public.account_logs;

CREATE POLICY account_logs_family_read ON public.account_logs
	FOR SELECT TO authenticated
	USING (
		family_id = public.get_my_family_id()
		AND (
			action NOT IN ('password_changed', 'email_change_requested', 'data_exported')
			OR actor_profile_id = (SELECT id FROM public.profiles WHERE user_id = auth.uid())
		)
	);
