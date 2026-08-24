-- =============================================================================
-- T-45 — the T-27 invariant becomes a DATABASE rule.
--
-- T-27 says a handoff time belongs only on a TRANSITION day: one whose
-- effective responsible (actual ?? scheduled) differs from the previous day's
-- (no previous day = custody starts here = transition). Until now that rule
-- lived only in the client and only looked BACKWARDS on manual saves (day
-- editor, bulk, wizard). No resolution path ever touched day D+1: the client
-- ApproveAsync, the auto_approve_expired RPC and the revert restore all update
-- the single row of day D. So an approved swap that makes D+1's responsible
-- equal to D's new effective responsible left D+1 with a handoff time on a day
-- where no handoff happens — and reverting the swap could not put it back,
-- because nothing had recorded that it was ever removed.
--
-- Two triggers, one rule:
--
--   · trigger_d (BEFORE INSERT/UPDATE) applies the rule to the row being
--     written, comparing it against D-1. A time on a non-transition day is
--     PARKED in the new handoff_time_backup column instead of being destroyed;
--     when the day becomes a transition again the parked value comes back.
--     That parking slot is what makes the revert work: it is the value, not an
--     archaeology of the audit log, and it is right for every path (approval,
--     auto-approval, revert, admin correction, bulk) by construction.
--
--   · trigger_d_sync (AFTER INSERT/UPDATE/DELETE) re-evaluates D+1 whenever a
--     day's effective responsible changes, by touching D+1 — the BEFORE trigger
--     above is what decides. It touches nothing when D+1 would not change, so
--     the audit trail stays free of no-op rows.
--
-- The cascade is a server-driven write of handoff_time only, so it announces
-- itself with the app.handoff_cascade GUC and enforce_day_protection waves it
-- through: D+1 may legitimately be frozen by its OWN pending request, or be a
-- past day under an admin correction, and neither is a reason to leave the
-- calendar inconsistent. Clients cannot set that GUC (PostgREST exposes no way
-- to run SET), and it is transaction-local.
--
-- Both functions are SECURITY DEFINER owned by postgres. That is also what
-- keeps the cascade past T-35: enforce_schedule_revision exempts by ROLE, and
-- inside a definer function current_user is the owner, so the internal UPDATE
-- is not asked to echo a revision token it never read.
--
-- Deliberately NOT done (owner decision, Aug 2026): the inverse case. A swap
-- that CREATES a transition at D+1 leaves its handoff_time NULL — there is no
-- time to invent, and a day without a handoff time is an ordinary state.
-- =============================================================================

ALTER TABLE public.care_schedules
	ADD COLUMN IF NOT EXISTS handoff_time_backup time without time zone;

COMMENT ON COLUMN public.care_schedules.handoff_time_backup IS
	'T-45: handoff_time parked by the transition rule when the day stopped being a transition, returned when it becomes one again. Server-owned — the triggers below overwrite whatever a payload sends.';

-- ── The rule itself ─────────────────────────────────────────────────────────
-- Runs as trigger_d_… so it fires AFTER trigger_a (family stamp — it needs
-- NEW.family_id), trigger_b (day protection) and trigger_c (T-33/T-35
-- concurrency): a frozen/past-day or staleness error still takes precedence
-- over any handoff rewriting.
CREATE OR REPLACE FUNCTION public.apply_handoff_transition_rule()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	prev_effective bigint;
	prev_found     boolean := false;
	new_effective  bigint;
	is_transition  boolean;
BEGIN
	-- The parking slot is server-owned (same stance as T-35's submitted_token):
	-- a payload never decides what is parked.
	IF TG_OP = 'UPDATE' THEN
		NEW.handoff_time_backup := OLD.handoff_time_backup;

		-- An explicit write of handoff_time is the writer's INTENT and always
		-- wins over a parked value: a time cleared by hand must never be
		-- resurrected later by the restore branch below.
		IF NEW.handoff_time IS DISTINCT FROM OLD.handoff_time THEN
			NEW.handoff_time_backup := NULL;
		END IF;
	ELSE
		NEW.handoff_time_backup := NULL;
	END IF;

	new_effective := COALESCE(NEW.actual_parent_id, NEW.scheduled_parent_id);

	SELECT COALESCE(actual_parent_id, scheduled_parent_id), true
	INTO prev_effective, prev_found
	FROM public.care_schedules
	WHERE family_id = NEW.family_id
	  AND schedule_date = NEW.schedule_date - 1;

	-- No previous day = custody starts here = transition (mirrors the editor).
	is_transition := NOT COALESCE(prev_found, false)
	                 OR prev_effective IS DISTINCT FROM new_effective;

	IF is_transition THEN
		IF NEW.handoff_time IS NULL AND NEW.handoff_time_backup IS NOT NULL THEN
			NEW.handoff_time        := NEW.handoff_time_backup;
			NEW.handoff_time_backup := NULL;
		END IF;
	ELSIF NEW.handoff_time IS NOT NULL THEN
		NEW.handoff_time_backup := NEW.handoff_time;
		NEW.handoff_time        := NULL;
	END IF;

	RETURN NEW;
END;
$$;

ALTER FUNCTION public.apply_handoff_transition_rule() OWNER TO postgres;

CREATE OR REPLACE TRIGGER trigger_d_apply_handoff_transition_rule
	BEFORE INSERT OR UPDATE ON public.care_schedules
	FOR EACH ROW EXECUTE FUNCTION public.apply_handoff_transition_rule();

-- ── The cascade to D+1 ──────────────────────────────────────────────────────
-- Named trigger_d_… so it runs after trigger_audit_care_schedule (AFTER
-- triggers fire in name order): the log of the day that CHANGED is written
-- before the log of the D+1 correction it causes, which is the order a reader
-- of the audit trail expects.
CREATE OR REPLACE FUNCTION public.sync_next_day_handoff()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	fam            bigint;
	the_date       date;
	day_effective  bigint;   -- NULL when the day no longer exists (DELETE)
	nxt            public.care_schedules%ROWTYPE;
	next_effective bigint;
	is_transition  boolean;
	prev_flag      text;
BEGIN
	-- Only a change of the day's effective responsible can flip D+1's
	-- transition status. This is also what stops the recursion: the cascade
	-- below writes handoff_time, never the responsible.
	IF TG_OP = 'UPDATE'
	   AND NEW.schedule_date = OLD.schedule_date
	   AND COALESCE(NEW.actual_parent_id, NEW.scheduled_parent_id)
	       IS NOT DISTINCT FROM COALESCE(OLD.actual_parent_id, OLD.scheduled_parent_id) THEN
		RETURN NULL;
	END IF;

	IF TG_OP = 'DELETE' THEN
		fam := OLD.family_id;  the_date := OLD.schedule_date;  day_effective := NULL;
	ELSE
		fam := NEW.family_id;  the_date := NEW.schedule_date;
		day_effective := COALESCE(NEW.actual_parent_id, NEW.scheduled_parent_id);
	END IF;

	SELECT * INTO nxt
	FROM public.care_schedules
	WHERE family_id = fam AND schedule_date = the_date + 1;
	IF NOT FOUND THEN
		RETURN NULL;
	END IF;

	next_effective := COALESCE(nxt.actual_parent_id, nxt.scheduled_parent_id);
	-- The day is gone (DELETE) → D+1 has no previous day → it is a transition.
	is_transition  := day_effective IS NULL OR day_effective IS DISTINCT FROM next_effective;

	-- Touch D+1 only when the rule would actually change it — an UPDATE here
	-- costs an activity_logs row and a new revision token for every client
	-- holding that day open.
	IF (NOT is_transition AND nxt.handoff_time IS NOT NULL)
	   OR (is_transition AND nxt.handoff_time IS NULL AND nxt.handoff_time_backup IS NOT NULL) THEN
		prev_flag := COALESCE(current_setting('app.handoff_cascade', true), 'off');
		PERFORM set_config('app.handoff_cascade', 'on', true);

		-- No column of substance: trigger_d recomputes handoff_time from the
		-- new state of day D.
		UPDATE public.care_schedules
		SET updated_at = timezone('utc', now())
		WHERE id = nxt.id;

		PERFORM set_config('app.handoff_cascade', prev_flag, true);
	END IF;

	RETURN NULL;
END;
$$;

ALTER FUNCTION public.sync_next_day_handoff() OWNER TO postgres;

CREATE OR REPLACE TRIGGER trigger_d_sync_next_day_handoff
	AFTER INSERT OR UPDATE OR DELETE ON public.care_schedules
	FOR EACH ROW EXECUTE FUNCTION public.sync_next_day_handoff();

-- ── Day protection: let the cascade through ─────────────────────────────────
-- The cascade rewrites handoff_time on D+1 as a consequence of a change the
-- caller was ALREADY allowed to make on D; blocking it would leave the calendar
-- inconsistent exactly in the cases the rule exists for (D+1 frozen by its own
-- pending request, or a past day under an admin correction). Same shape as the
-- S-11 deletion-context escape right below it.
--
-- Body copied VERBATIM from 20260724180000 (F-40), which is the LATEST of the
-- eight migrations that have replaced this function — S-09, S-11 ×2, the QA
-- clear rule, F-39, T-41 and F-40 all rewrote it in full. Copying the version
-- you happen to remember silently DELETES every rule added after it (doing that
-- here, from the S-09 body, took out the S-11 departed-member block, the F-39
-- planning horizon and the F-40 tier-aware past-day override in one line, and
-- seven integration tests said so). Always start from the newest definition.
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
	-- T-45: internal cascade of the handoff transition rule (sync_next_day_handoff).
	IF current_setting('app.handoff_cascade', true) = 'on' THEN
		RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
	END IF;

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

-- ── Backfill ────────────────────────────────────────────────────────────────
-- Days that are already inconsistent (a handoff time on a non-transition day)
-- are corrected once, here, so the invariant holds for the whole history and
-- not only from the next write on. The UPDATE only TOUCHES them — writing
-- handoff_time here would be undone by the trigger, which reads the incoming
-- value as the writer's intent; letting trigger_d do the parking is both
-- shorter and the same code path everything else uses. Running as the
-- migration role, day protection sees the system context and blocks nothing.
UPDATE public.care_schedules d
SET updated_at = timezone('utc', now())
FROM public.care_schedules p
WHERE p.family_id = d.family_id
  AND p.schedule_date = d.schedule_date - 1
  AND d.handoff_time IS NOT NULL
  AND COALESCE(d.actual_parent_id, d.scheduled_parent_id)
      = COALESCE(p.actual_parent_id, p.scheduled_parent_id);
