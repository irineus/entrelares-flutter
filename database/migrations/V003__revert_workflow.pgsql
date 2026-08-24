-- =============================================================================
-- V003 — Revert-swap approval workflow + urgency flag
-- Guarda Compartilhada — Supabase/PostgreSQL
--
-- 1. Adds is_urgent column to swap_requests.
-- 2. Widens the status check constraint to include the new revert lifecycle:
--      revert_pending  → requested, awaiting original parent confirmation
--      revert_approved → original parent confirmed, calendar reverted
--      revert_rejected → original parent refused the revert
--      revert_cancelled → requesting party withdrew before approval
-- 3. Drops and recreates the one-pending-per-date partial unique index so that
--    a revert_pending row also blocks a second concurrent pending row.
-- Apply via the Supabase SQL Editor against the target project AFTER V002.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Add is_urgent flag
-- ---------------------------------------------------------------------------

ALTER TABLE public.swap_requests
	ADD COLUMN IF NOT EXISTS is_urgent boolean NOT NULL DEFAULT false;


-- ---------------------------------------------------------------------------
-- 2. Widen status check constraint
-- ---------------------------------------------------------------------------

ALTER TABLE public.swap_requests
	DROP CONSTRAINT IF EXISTS swap_requests_status_check;

ALTER TABLE public.swap_requests
	ADD CONSTRAINT swap_requests_status_check
	CHECK (status IN (
		'pending',
		'approved',
		'rejected',
		'cancelled',
		'reverted',
		'revert_pending',
		'revert_approved',
		'revert_rejected',
		'revert_cancelled'
	));


-- ---------------------------------------------------------------------------
-- 3. Recreate partial unique index to block concurrent pending rows of
--    either kind (swap pending or revert pending) for the same date.
-- ---------------------------------------------------------------------------

DROP INDEX IF EXISTS public.swap_requests_one_pending_per_date;

CREATE UNIQUE INDEX swap_requests_one_pending_per_date
	ON public.swap_requests (schedule_date)
	WHERE status IN ('pending', 'revert_pending');
