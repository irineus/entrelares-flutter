-- =============================================================================
-- V004 — Revoke anon grants + enforce swap workflow at database level
-- Guarda Compartilhada — Supabase/PostgreSQL
--
-- S-03: Revokes all grants from the `anon` role on application tables and
--       sequences. The anon key is publicly visible in the client bundle;
--       defense-in-depth requires that unauthenticated callers cannot even
--       attempt queries on sensitive tables regardless of RLS state.
--
-- S-05: Replaces the permissive swap_requests UPDATE policy with granular
--       policies that enforce the state machine at the database level:
--       - Only the target (approver) can approve or reject.
--       - Only the requester can cancel.
--       - Status transitions are validated by a BEFORE UPDATE trigger.
--       This prevents a technically savvy user from bypassing the C# service
--       layer via direct PostgREST API calls.
--
-- Apply via the Supabase SQL Editor AFTER V003.
-- =============================================================================


-- ===========================================================================
-- PART 1: S-03 — Revoke anon grants
-- ===========================================================================

-- Tables
REVOKE ALL ON public.roles            FROM anon;
REVOKE ALL ON public.profiles         FROM anon;
REVOKE ALL ON public.care_schedules   FROM anon;
REVOKE ALL ON public.activity_logs    FROM anon;
REVOKE ALL ON public.swap_requests    FROM anon;
REVOKE ALL ON public.notifications    FROM anon;

-- Sequences
REVOKE ALL ON SEQUENCE public.roles_id_seq            FROM anon;
REVOKE ALL ON SEQUENCE public.profiles_id_seq         FROM anon;
REVOKE ALL ON SEQUENCE public.care_schedules_id_seq   FROM anon;
REVOKE ALL ON SEQUENCE public.activity_logs_id_seq    FROM anon;
REVOKE ALL ON SEQUENCE public.swap_requests_id_seq    FROM anon;
REVOKE ALL ON SEQUENCE public.notifications_id_seq    FROM anon;

-- Functions
REVOKE ALL ON FUNCTION public.audit_care_schedule_changes() FROM anon;


-- ===========================================================================
-- PART 2: S-05 — Database-level swap workflow enforcement
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 2a. Drop the permissive UPDATE policy that allowed either party to set
--     any status with WITH CHECK (true).
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS "swap_requests_update_parties" ON public.swap_requests;

-- ---------------------------------------------------------------------------
-- 2b. Create granular UPDATE policies per actor role.
--
--     Target (approver) can update rows where they are the target_profile_id.
--     Requester can update rows where they are the requesting_profile_id.
--     The actual status-transition validation is enforced by the trigger below
--     so these policies only gate WHO can touch the row.
-- ---------------------------------------------------------------------------

-- Target (approver) can update swap requests directed at them
CREATE POLICY "swap_requests_update_target"
    ON public.swap_requests FOR UPDATE TO authenticated
    USING (
        target_profile_id = (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    )
    WITH CHECK (
        target_profile_id = (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    );

-- Requester can update their own swap requests (for cancel operations)
CREATE POLICY "swap_requests_update_requester"
    ON public.swap_requests FOR UPDATE TO authenticated
    USING (
        requesting_profile_id = (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    )
    WITH CHECK (
        requesting_profile_id = (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    );

-- ---------------------------------------------------------------------------
-- 2c. BEFORE UPDATE trigger that enforces valid state transitions and
--     ensures only the correct actor can perform each transition.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_swap_status_transition()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    current_profile_id bigint;
    allowed boolean := false;
BEGIN
    -- Resolve the current user's profile id
    SELECT id INTO current_profile_id
    FROM public.profiles
    WHERE user_id = auth.uid();

    -- If status hasn't changed, allow the update (e.g. updating other fields)
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    -- Validate transition + actor
    CASE OLD.status
        WHEN 'pending' THEN
            CASE NEW.status
                WHEN 'approved' THEN
                    allowed := (current_profile_id = OLD.target_profile_id);
                WHEN 'rejected' THEN
                    allowed := (current_profile_id = OLD.target_profile_id);
                WHEN 'cancelled' THEN
                    allowed := (current_profile_id = OLD.requesting_profile_id);
                ELSE
                    allowed := false;
            END CASE;

        WHEN 'revert_pending' THEN
            CASE NEW.status
                WHEN 'revert_approved' THEN
                    allowed := (current_profile_id = OLD.target_profile_id);
                WHEN 'revert_rejected' THEN
                    allowed := (current_profile_id = OLD.target_profile_id);
                WHEN 'revert_cancelled' THEN
                    allowed := (current_profile_id = OLD.requesting_profile_id);
                ELSE
                    allowed := false;
            END CASE;

        ELSE
            -- Terminal statuses cannot transition
            allowed := false;
    END CASE;

    IF NOT allowed THEN
        RAISE EXCEPTION 'Invalid status transition from "%" to "%" for current user',
            OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;

    -- Auto-set resolved_at and updated_at on terminal transitions
    NEW.updated_at := timezone('utc', now());
    IF NEW.status IN ('approved', 'rejected', 'cancelled', 'revert_approved', 'revert_rejected', 'revert_cancelled') THEN
        NEW.resolved_at := timezone('utc', now());
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trigger_enforce_swap_status_transition
    BEFORE UPDATE ON public.swap_requests
    FOR EACH ROW EXECUTE FUNCTION public.enforce_swap_status_transition();

-- Grant execute on the new function to authenticated and service_role only
GRANT EXECUTE ON FUNCTION public.enforce_swap_status_transition() TO authenticated, service_role;
