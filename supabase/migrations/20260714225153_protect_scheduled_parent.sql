-- =============================================================================
-- S-09 — Protect scheduled_parent_id at the database level
-- Guarda Compartilhada — Supabase/PostgreSQL
--
-- The single-day editor's scheduled-parent lock was UI-only, and the bulk
-- edit sheet had no lock at all: any family member could rewrite the PLANNED
-- schedule (evading the swap approval workflow) via bulk edit or a direct
-- API PATCH. This migration extends the V008 enforce_day_protection trigger:
--
--   · Changing scheduled_parent_id on UPDATE now requires a family ADMIN
--     (explicit, audited action — F-14 pattern), the SYSTEM context
--     (auth.uid() IS NULL: F-24 auto-approve, migrations), or the pending
--     request's TARGET (the F-26 revert-restore writes scheduled_parent_id
--     back from the audit snapshot while the request is still revert_pending).
--   · INSERT stays free — assigning an unassigned day is planning (F-05),
--     not workflow evasion.
--
-- Everything else in the function is verbatim from V008 (frozen days, past
-- days, approved-swap deletion, actual-parent workflow enforcement).
-- First migration shipped through the T-29 CI/CD pipeline.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.enforce_day_protection()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
	cur_profile_id bigint;
	cur_is_admin   boolean := false;
	today          date;
	the_date       date;
	fam            bigint;
	is_frozen      boolean := false;
	is_target      boolean := false;
BEGIN
	-- System context (service_role: F-24 auto-approval, migrations): unrestricted.
	SELECT id, is_admin INTO cur_profile_id, cur_is_admin
	FROM public.profiles WHERE user_id = auth.uid();
	IF cur_profile_id IS NULL THEN
		RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
	END IF;

	today    := (now() AT TIME ZONE 'America/Sao_Paulo')::date;
	the_date := COALESCE(NEW.schedule_date, OLD.schedule_date);
	fam      := COALESCE(NEW.family_id, OLD.family_id,
	                     (SELECT family_id FROM public.profiles WHERE id = NEW.scheduled_parent_id));

	SELECT bool_or(true), bool_or(target_profile_id = cur_profile_id)
	INTO is_frozen, is_target
	FROM public.swap_requests
	WHERE family_id = fam AND schedule_date = the_date
	  AND status IN ('pending', 'revert_pending');
	is_frozen := COALESCE(is_frozen, false);
	is_target := COALESCE(is_target, false);

	-- F-12: frozen days are untouchable, except by the pending request's target
	-- (who legitimately applies the calendar change while approving) or an admin.
	IF TG_OP IN ('UPDATE', 'DELETE') AND is_frozen AND NOT is_target AND NOT cur_is_admin THEN
		RAISE EXCEPTION 'Este dia tem uma solicitação pendente e não pode ser alterado.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- F-13: past days are immutable (the target exemption keeps overdue
	-- workflow completions working; admins may bypass — F-14).
	IF the_date < today AND NOT cur_is_admin AND NOT is_target THEN
		RAISE EXCEPTION 'Dias passados não podem ser alterados.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- S-09: the PLANNED schedule is immutable for regular users — changing the
	-- scheduled parent of an assigned day requires an admin (explicit, audited)
	-- or the pending revert's target restoring the pre-edit snapshot (F-26).
	-- Responsibility changes for a day belong to the swap workflow (actual).
	IF TG_OP = 'UPDATE'
	   AND NEW.scheduled_parent_id IS DISTINCT FROM OLD.scheduled_parent_id
	   AND NOT cur_is_admin AND NOT is_target THEN
		RAISE EXCEPTION 'O responsável planejado só pode ser alterado por administradores; para mudar quem fica com a criança, use o fluxo de troca.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF TG_OP = 'DELETE' THEN
		-- F-12: a day with an approved swap cannot be deleted (admin may — F-14).
		IF OLD.actual_parent_id IS NOT NULL AND OLD.actual_parent_id <> OLD.scheduled_parent_id
		   AND NOT cur_is_admin AND NOT is_target THEN
			RAISE EXCEPTION 'Dias com troca aprovada não podem ser apagados.'
				USING ERRCODE = 'check_violation';
		END IF;
		RETURN OLD;
	END IF;

	-- Swap-workflow enforcement (applies to admins too — F-14 decision):
	-- creating or undoing a swap directly is forbidden; only the pending
	-- request's target (applying an approval) may write such a change.
	-- Exception: admins may correct the actual parent of PAST days (historical
	-- fixes — the workflow cannot exist for past dates), never future ones.
	IF cur_is_admin AND the_date < today THEN
		RETURN NEW;
	END IF;

	IF TG_OP = 'INSERT' THEN
		IF NEW.actual_parent_id IS NOT NULL AND NEW.actual_parent_id <> NEW.scheduled_parent_id THEN
			RAISE EXCEPTION 'Alterações do responsável real devem passar pelo fluxo de aprovação.'
				USING ERRCODE = 'check_violation';
		END IF;
	ELSIF NEW.actual_parent_id IS DISTINCT FROM OLD.actual_parent_id AND NOT is_target THEN
		IF (OLD.actual_parent_id IS NOT NULL AND OLD.actual_parent_id <> OLD.scheduled_parent_id)  -- undo/alter an approved swap
		   OR (NEW.actual_parent_id IS NOT NULL AND NEW.actual_parent_id <> NEW.scheduled_parent_id) -- create a swap directly
		THEN
			RAISE EXCEPTION 'Alterações do responsável real devem passar pelo fluxo de aprovação.'
				USING ERRCODE = 'check_violation';
		END IF;
	END IF;

	RETURN NEW;
END;
$$;
