-- F-48 — promotional launch pricing (owner decision, Aug 2026).
--
-- R$ 4,90/month and R$ 49/year replace R$ 14,90 / R$ 149 for every NEW
-- checkout ("2 meses grátis" still holds exactly: 4900 = 10 × 490). Existing
-- subscriptions keep their acquired price — the Terms' price guarantee — which
-- needs no code: the panels and the webhook read the price stored on the
-- subscription row (`subscriptions.price_cents`), never these settings.
--
-- Idempotent by construction: plain UPDATEs land on the same values when CI
-- re-applies the file after a dev dry-run (T-45 rule).

UPDATE public.app_settings
   SET value = '490',
       description = 'Premium monthly price in BRL cents (per family). Promotional launch price since Aug 2026 (was 1490).'
 WHERE key = 'billing.price_monthly_cents';

UPDATE public.app_settings
   SET value = '4900',
       description = 'Premium annual price in BRL cents (per family, ~2 months free). Promotional launch price since Aug 2026 (was 14900).'
 WHERE key = 'billing.price_annual_cents';
