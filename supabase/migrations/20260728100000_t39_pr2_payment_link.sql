-- =============================================================================
-- T-39 (PR2) — hosted checkout via Asaas Payment Link
--
-- The checkout is a RECURRENT-type Asaas Payment Link: the payer fills name,
-- CPF and e-mail on Asaas's own PCI-scoped page (nothing sensitive ever touches
-- our domain — the "hosted/redirect" decision of PR1). The link id is stored so
-- the webhook can adopt the subscription the gateway creates from it (matching
-- by externalReference `family:<id>` first, payment link id as fallback).
-- =============================================================================

ALTER TABLE public.subscriptions
	ADD COLUMN IF NOT EXISTS external_payment_link_id text;
