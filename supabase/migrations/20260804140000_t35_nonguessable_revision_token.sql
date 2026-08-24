-- =============================================================================
-- T-35 — hardens the T-33 optimistic guard against a FABRICATED payload
-- (T-32 finding T32-A1).
--
-- The T-33 guard compares NEW.revision with OLD.revision. It catches the honest
-- stale client, but `revision` increments monotonically (+1), so a hand-crafted
-- PostgREST call can send `revision = read + 1` and its stale write is accepted.
--
-- Swapping the counter for a random uuid does NOT fix it: inside a BEFORE UPDATE
-- trigger an OMITTED column is indistinguishable from a correctly echoed one
-- (NEW.<col> simply carries OLD.<col> in both cases), so the same forger would
-- just leave the column out of the PATCH body and pass again.
--
-- What closes it is splitting read from echo into TWO columns:
--   · revision_token  — re-rolled by the trigger on EVERY write; this is what a
--                       client reads (it can never be predicted from the row it
--                       already has);
--   · submitted_token — the echo, reset to NULL after every write. A write must
--                       carry it EQUAL to the row's current revision_token.
--                       Omitting it inherits NULL ≠ token → rejected. Forging it
--                       means guessing a random uuid → rejected. The only way to
--                       produce a valid echo is to actually READ the row, which
--                       is exactly what the optimistic lock asks for.
--
-- Server-side flows are exempt BY ROLE, not by payload shape: SECURITY DEFINER
-- RPCs (S-11 erasure, auto_approve_expired, the E2E purge) run as their owner
-- `postgres` and the crons/integration harness run as `service_role`, so their
-- column-list UPDATEs keep passing untouched. Everything else — i.e. `authenticated`
-- coming through PostgREST — must prove it read the row. Fail-closed: the exemption
-- is an allowlist, so an unforeseen role is guarded rather than waved through.
--
-- Consequence for END-USER writes, deliberate: an authenticated column-list
-- UPDATE (`.Set(...)`) on care_schedules is now rejected — the client must send
-- the full row, which it already does everywhere (CustodyService/SwapRequestService).
--
-- The legacy `revision` counter and its guard STAY: it costs nothing, keeps the
-- human-readable "how many times was this day edited" signal, and keeps rejecting
-- a client that stamps a revision it never read.
-- =============================================================================

ALTER TABLE public.care_schedules
	ADD COLUMN IF NOT EXISTS revision_token uuid NOT NULL DEFAULT gen_random_uuid(),
	ADD COLUMN IF NOT EXISTS submitted_token uuid;

COMMENT ON COLUMN public.care_schedules.revision_token IS
	'T-35: non-guessable optimistic-concurrency token, re-rolled on every write. Clients read it and echo it back in submitted_token.';
COMMENT ON COLUMN public.care_schedules.submitted_token IS
	'T-35: the token echoed by the writer. Never stored — the trigger resets it to NULL after each write; a row at rest always reads NULL.';

-- Existing rows: ADD COLUMN with a VOLATILE default evaluates per row, so each
-- one already gets a distinct uuid (the "fast default" shortcut only applies to
-- non-volatile defaults). The UPDATE below only matters if the column arrived by
-- some other route on a given environment — a shared zero uuid would be as
-- guessable as the counter this item is replacing.
UPDATE public.care_schedules
SET revision_token = gen_random_uuid()
WHERE revision_token = '00000000-0000-0000-0000-000000000000'::uuid;

-- ── INSERT: the token is stamped by the server, never by the payload ──────────
-- The C# model serializes every [Column] property, so an INSERT arrives with
-- revision_token = the all-zeros uuid, which would override the DEFAULT and make
-- the first token of every new row perfectly guessable. The trigger settles it.
-- SECURITY INVOKER (the default) on BOTH trigger functions, deliberately: see the
-- note on enforce_schedule_revision below. Neither function reads or writes a
-- table — they only rewrite NEW and raise — so they never needed definer rights.
CREATE OR REPLACE FUNCTION public.stamp_schedule_revision_token()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
	NEW.revision_token  := gen_random_uuid();
	NEW.submitted_token := NULL;
	RETURN NEW;
END;
$$;

ALTER FUNCTION public.stamp_schedule_revision_token() OWNER TO postgres;

CREATE OR REPLACE TRIGGER trigger_c_stamp_schedule_revision_token
	BEFORE INSERT ON public.care_schedules
	FOR EACH ROW EXECUTE FUNCTION public.stamp_schedule_revision_token();

-- ── UPDATE: the guard itself ──────────────────────────────────────────────────
-- Naming/order unchanged from T-33: 'trigger_c_…' runs AFTER trigger_a (family
-- stamp) and trigger_b (day protection), so frozen/past-day errors keep taking
-- precedence over a staleness error.
-- The function DROPS SECURITY DEFINER (it was definer since T-33, gratuitously —
-- it touches no table). That is not cosmetic: inside a SECURITY DEFINER function
-- `current_user` is the function's OWNER, so the role test below would read
-- 'postgres' for every caller and the guard would silently never fire. As
-- SECURITY INVOKER it reads the effective role of the caller — 'authenticated'
-- for a PostgREST end user, 'service_role' for the crons/harness, and 'postgres'
-- inside a SECURITY DEFINER RPC, which is exactly the distinction this needs.
-- (`auth.role()` would NOT work: it reads the JWT claim, so a SECURITY DEFINER
-- RPC called by an end user would still report 'authenticated' and get blocked.)
-- Trigger functions do not need EXECUTE at fire time — that is checked when the
-- trigger is created — so invoker rights cost nothing here.
CREATE OR REPLACE FUNCTION public.enforce_schedule_revision()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
	IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
		-- No echo at all: either a client build that predates T-35 (its PATCH
		-- has no submitted_token) or a forged payload that dropped the column.
		-- The message is distinct on purpose — telling an out-of-date app that
		-- "someone got there first" sends the user into a reload/retry loop that
		-- can never succeed, while "update the app" is actionable. Pre-T-35
		-- clients surface it as-is: CalendarHelpers.TranslateSaveError passes
		-- accented trigger messages straight through.
		IF NEW.submitted_token IS NULL THEN
			RAISE EXCEPTION 'Recarregue o aplicativo para continuar — esta versão está desatualizada.'
				USING ERRCODE = 'check_violation';
		END IF;

		IF NEW.submitted_token IS DISTINCT FROM OLD.revision_token THEN
			RAISE EXCEPTION 'Outro responsável salvou este dia primeiro — atualize o calendário e tente novamente.'
				USING ERRCODE = 'check_violation';
		END IF;
	END IF;

	-- T-33 legacy guard, kept: a client that stamps a revision it never read is
	-- still rejected, with the same message it has always raised.
	IF NEW.revision IS DISTINCT FROM OLD.revision THEN
		RAISE EXCEPTION 'Outro responsável salvou este dia primeiro — atualize o calendário e tente novamente.'
			USING ERRCODE = 'check_violation';
	END IF;

	NEW.revision        := OLD.revision + 1;
	NEW.revision_token  := gen_random_uuid();
	NEW.submitted_token := NULL;
	NEW.updated_at      := timezone('utc', now());
	RETURN NEW;
END;
$$;

ALTER FUNCTION public.enforce_schedule_revision() OWNER TO postgres;
