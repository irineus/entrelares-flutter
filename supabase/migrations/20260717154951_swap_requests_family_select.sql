-- ============================================================================
-- F-28 QA fix: swap_requests SELECT becomes family-scoped.
--
-- The V002 policy limited reads to the requester and the target. With two
-- members every request involved both, so it was invisible; with a third
-- caregiver (QA, July 2026) the uninvolved member could not SELECT the pending
-- request — their calendar showed the day fully OPEN (no freeze/hourglass)
-- while the other two saw it frozen. The day-protection trigger (SECURITY
-- DEFINER, sees all rows) still blocked any edit, so the workflow could not
-- actually be broken — but the observer got a hard error instead of the
-- frozen-day UX, and the FrozenDayPanel's observer view was unreachable.
--
-- A pending request freezes the day for the WHOLE family — every caregiver
-- must see it. Writes are untouched: UPDATE stays requester/target-only and
-- INSERT keeps its family checks.
-- ============================================================================

DROP POLICY IF EXISTS "swap_requests_select_own" ON public.swap_requests;

CREATE POLICY "swap_requests_select_family"
	ON public.swap_requests FOR SELECT TO authenticated
	USING (family_id = public.get_my_family_id());
