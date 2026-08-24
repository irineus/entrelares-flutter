-- =============================================================================
-- U-22 — billing.grace_days becomes a PUBLIC app_setting
--
-- The overdue panel (Família page) now shows the real grace deadline
-- (overdue_since + billing.grace_days), so the client needs to READ the
-- parameter. It was seeded non-public in T-39 PR1 ("server-only dunning
-- parameter"), but the value itself is not sensitive — it is even announced
-- to the family in the S-15/B-3 grace-warning e-mail. Enforcement is
-- unchanged: the downgrade cron (billing_grace_downgrade) keeps reading the
-- server-side value, so a tampered client can only mis-render a date, never
-- extend its own grace.
-- =============================================================================

UPDATE public.app_settings
SET is_public = true
WHERE key = 'billing.grace_days';
