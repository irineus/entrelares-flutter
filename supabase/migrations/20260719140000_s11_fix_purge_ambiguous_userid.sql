-- =============================================================================
-- S-11 (PR1) — fix forward: purge_expired_accounts raised
--   42702 "column reference \"user_id\" is ambiguous"
-- because RETURNS TABLE (user_id uuid) puts a PL/pgSQL OUT variable `user_id`
-- in scope that collides with the bare `user_id` column reference in the WHERE.
-- Qualify it as public.profiles.user_id. Body otherwise identical to
-- 20260719120000. (Corrective migration — the original already applied to dev.)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.purge_expired_accounts()
RETURNS TABLE (user_id uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
	PERFORM set_config('app.deletion_context', 'on', true);

	RETURN QUERY
	WITH due AS (
		SELECT p.id, p.user_id AS uid
		FROM public.profiles p
		WHERE p.left_at IS NOT NULL
		  AND p.user_id IS NOT NULL
		  AND p.deletion_scheduled_for IS NOT NULL
		  AND p.deletion_scheduled_for <= timezone('utc', now())
	), scrubbed AS (
		UPDATE public.profiles p
		SET email = 'removido+' || p.id || '@guarda.invalido'
		FROM due
		WHERE p.id = due.id
		RETURNING due.uid
	)
	SELECT uid FROM scrubbed WHERE uid IS NOT NULL;
END;
$$;
