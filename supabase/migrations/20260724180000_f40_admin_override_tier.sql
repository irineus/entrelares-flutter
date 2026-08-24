-- =============================================================================
-- F-40 — Freemium gate: Manager (Free) vs Administrator (Premium override)
--
-- Split today's single admin capability:
--   · Gestor (Free): everything about RUNNING the family stays free — rename,
--     invite/revoke, roles, promote/demote admins (separate RPCs, unchanged), AND
--     the non-retroactive day powers (override a frozen day, change the planned
--     parent of a FUTURE day, clear a future day).
--   · Administrador (Premium): the retroactive OVERRIDE — correcting PAST days
--     (and the actual parent of past days) outside the two-party workflow.
--
-- Decisions (locked July 2026, product owner):
--   · Free admins get a short "honest fix" window: they may correct past days
--     within the last `override_free_days` (= 7). Premium reaches back
--     `override_premium_months` (= 6), which is ALSO the hard retroactive cap for
--     everyone (beyond it, blocked even for premium admins).
--   · The window/cap live in app_settings (T-41) — tunable, mirrored to the client
--     for messaging; the DB is the enforcement authority.
--   · Grandfather is automatic (F-32: existing families premium; new families on a
--     30-day trial), so the free window only bites a free, post-trial admin.
--
-- This is the ONLY behavioural change: the F-13 past-day check in
-- enforce_day_protection becomes tier-aware. Frozen-day (F-12), planned-parent
-- (S-09), delete and clear stay `cur_is_admin` (Gestor = free). Body otherwise
-- copied VERBATIM from 20260724150000.
-- =============================================================================

-- ── 1. Seed the override window + retroactive cap (public: UX mirrors them) ───

INSERT INTO public.app_settings (key, value, value_type, category, description, is_public) VALUES
	('override_free_days',      '7', 'int', 'freemium', 'Dias passados que um admin do plano gratuito (Gestor) pode corrigir — janela livre de conserto honesto.', true),
	('override_premium_months', '6', 'int', 'freemium', 'Alcance retroativo do override do Administrador (Premium), em meses — também o teto rígido para todos.', true)
ON CONFLICT (key) DO NOTHING;

-- ── 2. enforce_day_protection — tier-aware past-day override (F-40) ───────────

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
	horizon_months int;
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

	-- F-39 (T-41: horizons from app_settings). Free plans up to N months ahead;
	-- premium up to M, the hard ceiling for all (not admin-bypassable). Grandfather:
	-- only NEW far-future writes are blocked.
	IF the_date > today
	   AND (TG_OP = 'INSERT'
	        OR (TG_OP = 'UPDATE' AND NEW.schedule_date IS DISTINCT FROM OLD.schedule_date)) THEN
		horizon_months := CASE WHEN public.is_premium(fam)
		                       THEN public.setting_int('calendar_months_premium', 24)
		                       ELSE public.setting_int('calendar_months_free', 6) END;
		IF the_date > (today + make_interval(months => horizon_months))::date THEN
			IF public.is_premium(fam) THEN
				RAISE EXCEPTION 'O calendário permite agendar no máximo % meses à frente.', horizon_months
					USING ERRCODE = 'check_violation';
			ELSE
				RAISE EXCEPTION 'O plano gratuito permite agendar até % meses à frente. Ative o Premium para planejar mais longe.', horizon_months
					USING ERRCODE = 'check_violation';
			END IF;
		END IF;
	END IF;

	SELECT bool_or(true), bool_or(target_profile_id = cur_profile_id)
	INTO is_frozen, is_target
	FROM public.swap_requests
	WHERE family_id = fam AND schedule_date = the_date
	  AND status IN ('pending', 'revert_pending');
	is_frozen := COALESCE(is_frozen, false);
	is_target := COALESCE(is_target, false);

	-- F-12: frozen days are untouchable, except by the pending request's target
	-- (who legitimately applies the calendar change while approving) or an admin.
	-- (F-40: frozen override stays a free Gestor power — not retroactive.)
	IF TG_OP IN ('UPDATE', 'DELETE') AND is_frozen AND NOT is_target AND NOT cur_is_admin THEN
		RAISE EXCEPTION 'Este dia tem uma solicitação pendente e não pode ser alterado.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- F-13 + F-40: past days are immutable, except the pending request's target
	-- (overdue workflow completion). Admin OVERRIDE of a past day is the
	-- Administrador (Premium) power: a free admin (Gestor) may fix only the last
	-- `override_free_days`; premium reaches back `override_premium_months`, which is
	-- the hard retroactive cap for everyone (beyond it, blocked even for premium).
	IF the_date < today AND NOT is_target THEN
		IF NOT cur_is_admin THEN
			RAISE EXCEPTION 'Dias passados não podem ser alterados.'
				USING ERRCODE = 'check_violation';
		ELSIF public.is_premium(fam) THEN
			IF the_date < (today - make_interval(months => public.setting_int('override_premium_months', 6)))::date THEN
				RAISE EXCEPTION 'Correções retroativas vão até % meses atrás.', public.setting_int('override_premium_months', 6)
					USING ERRCODE = 'check_violation';
			END IF;
		ELSE   -- free admin (Gestor): only the honest-fix window
			IF the_date < (today - make_interval(days => public.setting_int('override_free_days', 7)))::date THEN
				RAISE EXCEPTION 'O plano gratuito corrige apenas os últimos % dias. Ative o Premium para corrigir dias mais antigos (até % meses).',
					public.setting_int('override_free_days', 7), public.setting_int('override_premium_months', 6)
					USING ERRCODE = 'check_violation';
			END IF;
		END IF;
	END IF;

	-- S-09: the PLANNED schedule is immutable for regular users — changing the
	-- scheduled parent of an assigned day requires an admin (explicit, audited)
	-- or the pending revert's target restoring the pre-edit snapshot (F-26).
	-- (F-40: changing a FUTURE planned parent stays a free Gestor power; a PAST one
	-- is already gated by the tier-aware past-day check above.)
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
		-- QA (July 2026): clearing an assigned day is admin-only — otherwise a
		-- regular member deletes + recreates the day with anyone, bypassing the
		-- S-09 planned-parent rule. The workflow target keeps its exemption.
		IF NOT cur_is_admin AND NOT is_target THEN
			RAISE EXCEPTION 'Um dia já planejado só pode ser limpo por um administrador.'
				USING ERRCODE = 'check_violation';
		END IF;
		RETURN OLD;
	END IF;

	-- Swap-workflow enforcement (applies to admins too — F-14 decision):
	-- creating or undoing a swap directly is forbidden; only the pending
	-- request's target (applying an approval) may write such a change.
	-- Exception: admins may correct the actual parent of PAST days (historical
	-- fixes — the workflow cannot exist for past dates), never future ones. The
	-- retroactive reach was already tier-gated by the past-day check above.
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
