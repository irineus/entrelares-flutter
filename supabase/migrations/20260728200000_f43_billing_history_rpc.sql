-- =============================================================================
-- F-43 — payment history for family admins (sanitized view of the ledger)
--
-- The billing_events ledger stays service_role-only (raw gateway payloads may
-- carry payer metadata). This RPC exposes a SANITIZED, family-scoped timeline
-- to FAMILY ADMINS only: when it happened, what it was (payment / refund /
-- overdue / cancellation / grace downgrade), the amount, the method and the
-- Asaas invoice URL (receipt) when the event carried one.
--
-- Dedupe: a card payment can emit both PAYMENT_CONFIRMED and PAYMENT_RECEIVED
-- for the SAME gateway payment — the timeline keeps the earliest per
-- (category, payment id) so one payment is one row.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_billing_history()
RETURNS TABLE (
	occurred_at  timestamp with time zone,
	category     text,
	amount       numeric,
	billing_type text,
	invoice_url  text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
	me public.profiles%ROWTYPE;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();
	IF me.id IS NULL OR NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores da família podem ver o histórico de pagamentos.'
			USING ERRCODE = 'check_violation';
	END IF;

	RETURN QUERY
	WITH relevant AS (
		SELECT e.received_at AS r_at,
		       CASE e.event_type
		           WHEN 'PAYMENT_CONFIRMED'        THEN 'payment'
		           WHEN 'PAYMENT_RECEIVED'         THEN 'payment'
		           WHEN 'PAYMENT_REFUNDED'         THEN 'refund'
		           WHEN 'PAYMENT_OVERDUE'          THEN 'overdue'
		           WHEN 'SUBSCRIPTION_DELETED'     THEN 'canceled'
		           WHEN 'SUBSCRIPTION_INACTIVATED' THEN 'canceled'
		           WHEN 'GRACE_DOWNGRADE'          THEN 'downgraded'
		       END AS r_category,
		       (e.payload -> 'payment' ->> 'value')::numeric AS r_amount,
		       e.payload -> 'payment' ->> 'billingType'      AS r_billing_type,
		       e.payload -> 'payment' ->> 'invoiceUrl'       AS r_invoice_url,
		       COALESCE(e.payload -> 'payment' ->> 'id', e.event_id) AS r_dedupe
		FROM public.billing_events e
		WHERE e.family_id = me.family_id
		  AND e.event_type IN ('PAYMENT_CONFIRMED', 'PAYMENT_RECEIVED', 'PAYMENT_REFUNDED',
		                       'PAYMENT_OVERDUE', 'SUBSCRIPTION_DELETED',
		                       'SUBSCRIPTION_INACTIVATED', 'GRACE_DOWNGRADE')
	), deduped AS (
		SELECT DISTINCT ON (r.r_category, r.r_dedupe)
		       r.r_at, r.r_category, r.r_amount, r.r_billing_type, r.r_invoice_url
		FROM relevant r
		ORDER BY r.r_category, r.r_dedupe, r.r_at ASC
	)
	SELECT d.r_at, d.r_category, d.r_amount, d.r_billing_type, d.r_invoice_url
	FROM deduped d
	ORDER BY d.r_at DESC
	LIMIT 100;
END;
$$;

ALTER FUNCTION public.get_billing_history() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_billing_history() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_billing_history() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_billing_history() TO service_role;
