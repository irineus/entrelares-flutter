-- F-48 (QA fix) — the promotional monthly price violated the gateway minimum.
--
-- Asaas refuses Pix/boleto charges under R$ 5,00 ("O valor mínimo para
-- cobranças via Boleto e Pix é R$ 5,00"), so the R$ 4,90 monthly price made
-- EVERY monthly checkout and every reactivation 502 in QA — the annual
-- (R$ 49) was fine. New promotional prices (owner decision at the QA round):
-- R$ 5,49/month · R$ 54,90/year — "2 meses grátis" stays exact
-- (5490 = 10 × 549). Fix-forward on top of 20260805003000.
--
-- Idempotent: plain UPDATEs land on the same values on re-apply.

UPDATE public.app_settings
   SET value = '549',
       description = 'Premium monthly price in BRL cents (per family). Promotional launch price since Aug 2026 (was 1490; 549 respects the Asaas R$5 Pix/boleto minimum).'
 WHERE key = 'billing.price_monthly_cents';

UPDATE public.app_settings
   SET value = '5490',
       description = 'Premium annual price in BRL cents (per family, ~2 months free). Promotional launch price since Aug 2026 (was 14900).'
 WHERE key = 'billing.price_annual_cents';
