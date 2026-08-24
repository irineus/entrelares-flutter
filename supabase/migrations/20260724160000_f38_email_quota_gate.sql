-- =============================================================================
-- F-38 — Freemium gate: monthly transactional-e-mail cap (Free) vs unlimited
--
-- Resend has a per-message cost, so free families get a GENEROUS monthly cap on
-- transactional e-mails (swap requested/approved/reverted + invitations — all
-- dispatched through send-swap-email); premium is unlimited. In-app notifications
-- are NEVER capped: only the e-mail copy pauses once the cap is reached.
--
-- Proactive heads-ups (each once per month, in-app to every active member + an
-- e-mail to the family ADMINS only — they own the upgrade):
--   · 80% of the cap reached → "chegando no limite".
--   · one slot left (cap - 1) → the warning e-mail itself TAKES the final slot,
--     so it is literally the last e-mail of the month ("último e-mail").
--   · over the cap → the real e-mail is skipped; a one-off in-app upsell only
--     (no e-mail can go out once capped).
--
-- Design (decisions locked July 2026, product owner):
--   · Cap = 100 e-mails / family / calendar month (America/Sao_Paulo). Generous.
--   · Counting is per e-mail EVENT (one send-swap-email invocation). The "último"
--     warning e-mail COUNTS (it is the final slot); the 80% heads-up does not.
--   · Premium is unlimited and never counted.
--   · All state lives in the DB; the Edge Function reads the returned status and
--     (a) skips the real send on 'denied', (b) sends the admin warning e-mail on
--     'warn_80'/'warn_last'. Fail-open on any error so a counter fault never
--     blocks e-mail.
-- =============================================================================

-- ── 1. Per-family, per-month counter ─────────────────────────────────────────
-- System-owned counter: RLS on, no authenticated policy — only the SECURITY
-- DEFINER function (and service_role) ever touch it.

CREATE TABLE IF NOT EXISTS public.email_usage (
	family_id       bigint  NOT NULL REFERENCES public.families (id) ON DELETE CASCADE,
	year_month      text    NOT NULL,               -- 'YYYY-MM' in America/Sao_Paulo
	sent_count      int     NOT NULL DEFAULT 0,
	warned_80       boolean NOT NULL DEFAULT false,  -- 80% heads-up posted this month
	warned_last     boolean NOT NULL DEFAULT false,  -- last-e-mail heads-up posted this month
	upsell_notified boolean NOT NULL DEFAULT false,  -- over-cap upsell posted this month
	PRIMARY KEY (family_id, year_month)
);

ALTER TABLE public.email_usage ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.email_usage TO service_role;

-- ── 2. In-app fan-out helper ─────────────────────────────────────────────────
-- Posts one notification to every ACTIVE family member (the in-app channel is
-- never capped). The e-mail twin (admins only) is sent by the Edge Function.

CREATE OR REPLACE FUNCTION public.notify_family_email_cap(
	p_family_id bigint, p_type text, p_title text, p_message text)
RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path TO 'public'
AS $$
	INSERT INTO public.notifications (recipient_profile_id, type, title, message)
	SELECT p.id, p_type, p_title, p_message
	FROM public.profiles p
	WHERE p.family_id = p_family_id AND p.left_at IS NULL AND p.user_id IS NOT NULL;
$$;

ALTER FUNCTION public.notify_family_email_cap(bigint, text, text, text) OWNER TO postgres;

-- ── 3. consume_email_quota — atomic consume + milestone heads-ups ─────────────
-- Returns: 'allowed' | 'warn_80' | 'warn_last' | 'denied'. The Edge Function
-- sends the real e-mail unless 'denied', and an admin warning e-mail on the two
-- warn_* statuses.

CREATE OR REPLACE FUNCTION public.consume_email_quota(p_family_id bigint)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	is_prem boolean;
	cap     int;
	warn_at int;
	last_at int;
	ym      text := to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM');
	cur     int;
BEGIN
	is_prem := public.is_premium(p_family_id);
	-- Per-tier cap — nothing is truly unlimited: premium runs against a HIGH
	-- anti-abuse cap. Both tiers are counted and enforced (T-41 config).
	cap     := CASE WHEN is_prem THEN public.setting_int('email_cap_premium', 10000)
	                             ELSE public.setting_int('email_cap_free', 100) END;
	warn_at := cap * 4 / 5;   -- 80% heads-up
	last_at := cap - 1;       -- one slot left; the free warning takes it

	-- Atomically consume one unit while under the cap. A NULL return means the
	-- row was already at the cap (the counter never climbs past it).
	INSERT INTO public.email_usage (family_id, year_month, sent_count)
	VALUES (p_family_id, ym, 1)
	ON CONFLICT (family_id, year_month) DO UPDATE
		SET sent_count = email_usage.sent_count + 1
		WHERE email_usage.sent_count < cap
	RETURNING sent_count INTO cur;

	IF cur IS NULL THEN
		-- Over the cap (either tier): skip the real e-mail. First denial → one
		-- in-app notification (tier-aware — no "upgrade" nudge for premium).
		UPDATE public.email_usage SET upsell_notified = true
		WHERE family_id = p_family_id AND year_month = ym AND upsell_notified = false;
		IF FOUND THEN
			IF is_prem THEN
				PERFORM public.notify_family_email_cap(p_family_id, 'email_cap_reached',
					'Limite de e-mails do mês atingido',
					'Sua família atingiu o limite de e-mails deste mês. As notificações aqui no app seguem normais.');
			ELSE
				PERFORM public.notify_family_email_cap(p_family_id, 'email_cap_reached',
					'Limite de e-mails do plano gratuito',
					'Sua família atingiu o limite de e-mails deste mês no plano gratuito. As notificações aqui no app seguem normais — ative o Premium para um limite bem maior.');
			END IF;
		END IF;
		RETURN 'denied';
	END IF;

	-- Proactive heads-ups are FREE-tier conversion nudges only — premium just runs
	-- against its high anti-abuse cap, with no upsell.
	IF NOT is_prem THEN
		-- Last-e-mail heads-up: the warning e-mail itself takes the final slot, so
		-- it is literally the last e-mail of the month.
		IF cur >= last_at THEN
			UPDATE public.email_usage SET warned_last = true, sent_count = cap
			WHERE family_id = p_family_id AND year_month = ym AND warned_last = false;
			IF FOUND THEN
				PERFORM public.notify_family_email_cap(p_family_id, 'email_cap_last',
					'Último e-mail do mês',
					'Este é o último e-mail do mês no plano gratuito. As notificações aqui no app seguem normais — ative o Premium para um limite bem maior.');
				RETURN 'warn_last';
			END IF;
			RETURN 'allowed';   -- already warned this month
		END IF;

		-- 80% heads-up (does NOT consume a slot).
		IF cur >= warn_at THEN
			UPDATE public.email_usage SET warned_80 = true
			WHERE family_id = p_family_id AND year_month = ym AND warned_80 = false;
			IF FOUND THEN
				PERFORM public.notify_family_email_cap(p_family_id, 'email_cap_80',
					'E-mails do mês em 80%',
					'Sua família já usou 80% dos e-mails deste mês (plano gratuito). As notificações aqui no app seguem sem limite — ative o Premium para um limite bem maior.');
				RETURN 'warn_80';
			END IF;
			RETURN 'allowed';
		END IF;
	END IF;

	RETURN 'allowed';
END;
$$;

ALTER FUNCTION public.consume_email_quota(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.consume_email_quota(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.consume_email_quota(bigint) FROM anon;
REVOKE ALL ON FUNCTION public.consume_email_quota(bigint) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.consume_email_quota(bigint) TO service_role;
