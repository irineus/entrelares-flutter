-- =============================================================================
-- T-48 (redesigned, T-53 lote 5) — the STORE billing rail: Google Play.
--
-- The original T-48 described the Chrome Digital Goods API inside the TWA.
-- That mechanism does not exist in a native app, and Play REQUIRES Play
-- Billing for a digital subscription sold inside one — so the Flutter client
-- sells through the store and this migration teaches the existing bookkeeping
-- to hold what the store rail writes.
--
-- WHAT DOES NOT CHANGE (and must not):
--   · `subscriptions` stays ONE row per family. A family is a payer, not a
--     Google account — which is the real complexity of this rail and the
--     reason the purchase token is stored here, on the family's row.
--   · Entitlement stays F-32: the store functions flip `families.plan` through
--     the SAME `set_family_plan` RPC, never by writing the column.
--   · `billing_events` stays the idempotency ledger for BOTH rails. The store
--     side's `event_id` is derived from the RTDN message id (or the purchase
--     token, for a direct verification), so a redelivery is a no-op exactly
--     like an Asaas one.
--   · The grace window, the B-3 warning, cancellation honoring paid time and
--     additive renewal all keep working: they read `status`/`current_period_end`,
--     which the store rail writes with the same meanings.
--
-- SECURITY MODEL: unchanged. Members SELECT their own family's row; every
-- write is service_role (the two store functions use the secret key). The
-- purchase token is NOT secret in the credential sense — it identifies a
-- purchase and is only useful with the Play Developer API — but it is still
-- server-side data, and the client already has it (Play handed it over).
-- =============================================================================

-- ── 1. The store rail is a second gateway ───────────────────────────────────

ALTER TABLE public.subscriptions
	DROP CONSTRAINT IF EXISTS subscriptions_gateway_check;

ALTER TABLE public.subscriptions
	ADD CONSTRAINT subscriptions_gateway_check
	CHECK (gateway IN ('asaas', 'play'));

COMMENT ON COLUMN public.subscriptions.gateway IS
	'asaas (web rail: recurring + Pix avulso) | play (store rail, T-48). Both '
	'converge here and apply through set_family_plan; the column says which '
	'webhook owns the row, and therefore where the family cancels.';

-- ── 2. What the store rail needs to identify a purchase ─────────────────────
-- The purchase token is Play's identity for "this Google account bought this
-- product". UNIQUE because one purchase may fund exactly one family: without
-- it, the same receipt could be replayed by a second family and both would go
-- premium off one payment.

ALTER TABLE public.subscriptions
	ADD COLUMN IF NOT EXISTS store_purchase_token text;

ALTER TABLE public.subscriptions
	ADD COLUMN IF NOT EXISTS store_product_id text;

CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_store_purchase_token_key
	ON public.subscriptions (store_purchase_token)
	WHERE store_purchase_token IS NOT NULL;

COMMENT ON COLUMN public.subscriptions.store_purchase_token IS
	'T-48: Play purchase token of the CURRENT store subscription. Unique — one '
	'purchase funds one family, so a replayed receipt cannot buy Premium twice. '
	'Play rotates it on upgrade/downgrade/resubscribe (linkedPurchaseToken), so '
	'the verify function overwrites rather than accumulating.';

COMMENT ON COLUMN public.subscriptions.store_product_id IS
	'T-48: the Play product that sold it (premium_monthly | premium_annual). '
	'Kept so the in-app "manage subscription" deep link can point at the right '
	'SKU, and so the ledger says WHAT was bought.';

-- ── 3. The store rail's own master switch ───────────────────────────────────
-- Deliberately separate from billing.enabled (which rules the web rail): the
-- two rails go live independently, and the store one must stay OFF until the
-- Play Console side exists — products published, RTDN topic wired, service
-- account granted. An offer the store cannot honor is worse than no offer, so
-- the client falls back to the T-38 neutral note while this is false.

INSERT INTO public.app_settings (key, value, value_type, category, description, is_public) VALUES
	('billing.store_enabled', 'false', 'bool', 'billing',
	 'T-48 master switch for the STORE rail (Google Play). While false the Flutter store build shows the neutral T-38 note instead of an in-app purchase; the verify function also refuses. Independent of billing.enabled, which rules the web/Asaas rail.',
	 true)
ON CONFLICT (key) DO NOTHING;

-- ── 4. The ledger's category for store money ────────────────────────────────
-- get_billing_history sanitizes and labels the family's timeline. The store
-- events land as ordinary payments (category 'payment') because that is what
-- they are to the family — what differs is who charged, which the row's
-- billing_type already carries as 'PLAY'.

COMMENT ON TABLE public.billing_events IS
	'Idempotency ledger + raw audit of everything a gateway told us. BOTH rails '
	'write here: Asaas keys on its event id, Play on the RTDN message id (or on '
	'"play:<purchase token>" for a direct client verification).';
