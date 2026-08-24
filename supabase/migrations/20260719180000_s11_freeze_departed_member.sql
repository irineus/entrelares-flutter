-- =============================================================================
-- S-11 (PR1) — freeze a departed member (fix forward)
--
-- QA found that a member who left the family (left_at set) was NOT actually
-- frozen: an admin could still rename them / promote them to admin, and they
-- were still offered as an assignable parent (and the assignment saved). The
-- left_at flag existed but nothing enforced it. Enforcement belongs in the DB
-- (architecture invariant), so:
--
--   1. enforce_profile_protection: a profile with left_at set is immutable —
--      the only allowed writes are the erasure cleanup (deletion_context) and
--      the owner cancelling their own exit (left_at -> NULL).
--   2. enforce_day_protection: a departed member cannot be NEWLY assigned to a
--      day as the planned or the real parent (past history keeps their name;
--      only NEW assignments are blocked).
--
-- Both bodies are reproduced VERBATIM from their latest versions
-- (20260716113637 / 20260719120000) plus the new guards.
-- =============================================================================

-- ── 1. enforce_profile_protection: freeze the departed row ───────────────────

CREATE OR REPLACE FUNCTION public.enforce_profile_protection()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
	actor_admin  boolean;
	actor_family bigint;
BEGIN
	-- System context (service_role / migrations): unrestricted.
	IF auth.uid() IS NULL THEN
		RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
	END IF;

	SELECT is_admin, family_id INTO actor_admin, actor_family
	FROM public.profiles WHERE user_id = auth.uid();

	IF TG_OP = 'UPDATE' THEN
		-- S-11: a departed member's profile is FROZEN — no edits at all.
		-- Exceptions: the erasure cleanup (deletion_context) and the owner
		-- cancelling their own exit (left_at set -> NULL).
		IF OLD.left_at IS NOT NULL
		   AND current_setting('app.deletion_context', true) IS DISTINCT FROM 'on'
		   AND NOT (OLD.user_id = auth.uid() AND NEW.left_at IS NULL) THEN
			RAISE EXCEPTION 'Este responsável saiu da família e não pode mais ser alterado.'
				USING ERRCODE = 'check_violation';
		END IF;

		IF NEW.family_id IS DISTINCT FROM OLD.family_id THEN
			RAISE EXCEPTION 'A família de um perfil não pode ser alterada.'
				USING ERRCODE = 'check_violation';
		END IF;

		IF NEW.is_admin IS DISTINCT FROM OLD.is_admin THEN
			-- Blocks self-promotion through the profiles_own_update policy.
			IF COALESCE(actor_admin, false) = false OR actor_family IS DISTINCT FROM OLD.family_id THEN
				RAISE EXCEPTION 'Somente administradores da família podem alterar permissões de administrador.'
					USING ERRCODE = 'check_violation';
			END IF;

			-- Demotion: keep the >= 1 admin per family invariant.
			IF OLD.is_admin AND NOT NEW.is_admin AND NOT EXISTS (
				SELECT 1 FROM public.profiles
				WHERE family_id = OLD.family_id AND is_admin AND id <> OLD.id
			) THEN
				RAISE EXCEPTION 'A família precisa de pelo menos uma pessoa administradora.'
					USING ERRCODE = 'check_violation';
			END IF;
		END IF;

		-- F-16/F-27: role changes are admin-only (set_member_role) — the
		-- own-row UPDATE policy must not be a side door for self role edits.
		IF NEW.role_id IS DISTINCT FROM OLD.role_id THEN
			IF COALESCE(actor_admin, false) = false OR actor_family IS DISTINCT FROM OLD.family_id THEN
				RAISE EXCEPTION 'Somente administradores da família podem alterar papéis.'
					USING ERRCODE = 'check_violation';
			END IF;
		END IF;

		RETURN NEW;
	END IF;

	-- DELETE: never remove the last admin of a family.
	IF OLD.is_admin AND NOT EXISTS (
		SELECT 1 FROM public.profiles
		WHERE family_id = OLD.family_id AND is_admin AND id <> OLD.id
	) THEN
		RAISE EXCEPTION 'A família precisa de pelo menos uma pessoa administradora.'
			USING ERRCODE = 'check_violation';
	END IF;
	RETURN OLD;
END;
$$;

-- ── 2. enforce_day_protection: block assigning a departed member ─────────────

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
	-- S-11: controlled erasure cleanup — see 20260719120000.
	IF current_setting('app.deletion_context', true) = 'on' THEN
		RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
	END IF;

	-- System context (service_role: F-24 auto-approval, migrations): unrestricted.
	SELECT id, is_admin INTO cur_profile_id, cur_is_admin
	FROM public.profiles WHERE user_id = auth.uid();
	IF cur_profile_id IS NULL THEN
		RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
	END IF;

	-- S-11: a departed member (left_at set) cannot be NEWLY assigned to a day,
	-- as the planned or the real parent. Past history keeps their name — only a
	-- CHANGE that puts a departed member on a day is blocked.
	IF TG_OP IN ('INSERT', 'UPDATE') THEN
		IF (TG_OP = 'INSERT' OR NEW.scheduled_parent_id IS DISTINCT FROM OLD.scheduled_parent_id)
		   AND EXISTS (SELECT 1 FROM public.profiles
		               WHERE id = NEW.scheduled_parent_id AND left_at IS NOT NULL) THEN
			RAISE EXCEPTION 'Não é possível atribuir dias a um responsável que saiu da família.'
				USING ERRCODE = 'check_violation';
		END IF;
		IF NEW.actual_parent_id IS NOT NULL
		   AND (TG_OP = 'INSERT' OR NEW.actual_parent_id IS DISTINCT FROM OLD.actual_parent_id)
		   AND EXISTS (SELECT 1 FROM public.profiles
		               WHERE id = NEW.actual_parent_id AND left_at IS NOT NULL) THEN
			RAISE EXCEPTION 'Não é possível atribuir dias a um responsável que saiu da família.'
				USING ERRCODE = 'check_violation';
		END IF;
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
