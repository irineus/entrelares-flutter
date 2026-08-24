-- =============================================================================
-- S-15 (B-3, PR3b) — warn before the Premium grace period runs out
--
-- PR3a published the approved B-3 wording in the Terms:
--   "Se houver falha na cobrança, poderemos fornecer um breve período de carência
--    a nosso critério. Esgotada a carência, o acesso retornará ao Plano Gratuito.
--    AVISAREMOS POR E-MAIL ANTES DA INDISPONIBILIDADE."
--
-- That last sentence had NO implementation. `billing_grace_downgrade` (T-39 PR3)
-- flips the family to free in silence: no e-mail, no in-app notice. We found it
-- by checking the sentence against the code — the A-1.3 lesson (a policy claim
-- that had never been verified against the database, which cost a third round of
-- legal opinion), now applied to every wording we receive. This migration makes
-- the promise true BEFORE the text can reach production.
--
-- Strictly this belongs to T-39 (billing); it ships under S-15 because S-15's
-- text is what creates the obligation.
--
-- DESIGN — mirrors family_deletion_reminders_due (S-11's D-3 reminder), the
-- established "notify once, ahead of an irreversible deadline" pattern:
--   · a sent-marker column makes it idempotent, so an hourly/daily cron cannot
--     spam the same family;
--   · the in-app notification is written HERE, inside the same transaction as
--     the marker — that is the reliable channel. The e-mail twin is dispatched by
--     the purge-deleted cron and is best-effort, exactly like the D-3 reminder;
--   · the warning window is configurable (T-41) rather than hardcoded.
--
-- WHO IS WARNED: the family's ADMINS. They are the ones who can act on it — the
-- checkout and the subscription panel are admin-only (F-40/T-39), so warning a
-- non-admin member would be an alarm they cannot answer.
-- =============================================================================

-- ── 1. Sent-marker ───────────────────────────────────────────────────────────
-- Cleared whenever a new overdue cycle starts, so a family that recovers and
-- later falls overdue again is warned again (see the webhook note in section 4).

ALTER TABLE public.subscriptions
	ADD COLUMN IF NOT EXISTS grace_warning_sent_at timestamp with time zone;

COMMENT ON COLUMN public.subscriptions.grace_warning_sent_at IS
	'S-15/B-3: when the "grace ending" warning was sent for the CURRENT overdue cycle. NULL = not warned yet. Reset when overdue_since changes.';

-- ── 2. How many days before the downgrade to warn ────────────────────────────
-- Not public: purely operational, the client never reads it.

INSERT INTO public.app_settings (key, value, value_type, category, description, is_public) VALUES
	('billing.grace_warning_days', '2', 'int', 'billing', 'Dias de antecedência do aviso de fim da carência do Premium (S-15/B-3).', false)
ON CONFLICT (key) DO NOTHING;

-- ── 3. The due-warnings function ─────────────────────────────────────────────
-- Returns ONE ROW PER ADMIN so the caller can address each e-mail to a real
-- person. The marker is stamped once per subscription, before the rows are
-- returned, so a crash in the e-mail loop cannot produce a second wave.

CREATE OR REPLACE FUNCTION public.billing_grace_warnings_due()
RETURNS TABLE (subscription_id bigint, family_id bigint, admin_profile_id bigint, grace_ends_at timestamp with time zone)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	grace_days   int := public.setting_int('billing.grace_days', 7);
	warning_days int := public.setting_int('billing.grace_warning_days', 2);
	r            record;
	ends_at      timestamp with time zone;
BEGIN
	FOR r IN
		SELECT s.id, s.family_id AS fam_id, s.overdue_since
		  FROM public.subscriptions s
		  JOIN public.families f ON f.id = s.family_id
		 WHERE s.status = 'overdue'
		   AND s.overdue_since IS NOT NULL
		   AND s.grace_warning_sent_at IS NULL
		   AND f.plan = 'premium'
		   -- Inside the warning window and not yet past the downgrade: warning
		   -- someone AFTER they already lost access would be worse than silence.
		   AND s.overdue_since + make_interval(days => grace_days - warning_days)
		       <= timezone('utc', now())
		   AND s.overdue_since + make_interval(days => grace_days)
		       > timezone('utc', now())
	LOOP
		ends_at := r.overdue_since + make_interval(days => grace_days);

		UPDATE public.subscriptions
		   SET grace_warning_sent_at = timezone('utc', now())
		 WHERE id = r.id;

		-- Reliable channel, same transaction as the marker.
		INSERT INTO public.notifications (recipient_profile_id, type, title, message)
		SELECT p.id, 'billing',
		       'Seu Premium está prestes a ser interrompido',
		       'Não conseguimos confirmar o pagamento da assinatura. Se a cobrança não for regularizada até ' ||
		       to_char(ends_at AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY') ||
		       ', a família voltará ao Plano Gratuito. Nenhum dado é apagado — os recursos Premium apenas ficam indisponíveis.'
		  FROM public.profiles p
		 WHERE p.family_id = r.fam_id
		   AND p.is_admin
		   AND p.left_at IS NULL
		   AND p.user_id IS NOT NULL;

		-- One row per admin for the e-mail twin.
		RETURN QUERY
		SELECT r.id, r.fam_id, p.id, ends_at
		  FROM public.profiles p
		 WHERE p.family_id = r.fam_id
		   AND p.is_admin
		   AND p.left_at IS NULL
		   AND p.user_id IS NOT NULL;
	END LOOP;
END;
$$;

ALTER FUNCTION public.billing_grace_warnings_due() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.billing_grace_warnings_due() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_grace_warnings_due() TO service_role;

COMMENT ON FUNCTION public.billing_grace_warnings_due() IS
	'S-15/B-3: stamps + returns the admins to warn before the Premium grace period expires. Writes the in-app notice itself; the e-mail twin is dispatched by purge-deleted (best-effort).';

-- ── 4. Reset the marker when a NEW overdue cycle begins ──────────────────────
-- Without this, a family warned once would never be warned again: it pays, goes
-- overdue months later, and the stale marker silences the second warning. The
-- webhook writes overdue_since, so keying the reset to that column covers every
-- path into overdue without touching the webhook's own code.

CREATE OR REPLACE FUNCTION public.reset_grace_warning_on_new_overdue()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
	IF NEW.overdue_since IS DISTINCT FROM OLD.overdue_since THEN
		NEW.grace_warning_sent_at := NULL;
	END IF;
	RETURN NEW;
END;
$$;

ALTER FUNCTION public.reset_grace_warning_on_new_overdue() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_reset_grace_warning ON public.subscriptions;

CREATE TRIGGER trg_reset_grace_warning
	BEFORE UPDATE ON public.subscriptions
	FOR EACH ROW
	EXECUTE FUNCTION public.reset_grace_warning_on_new_overdue();
