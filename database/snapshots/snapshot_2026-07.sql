


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."audit_care_schedule_changes"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
	INSERT INTO public.activity_logs (
		schedule_id,
		affected_date,
		action,
		old_data,
		new_data,
		performed_by_id,
		family_id
	) VALUES (
		CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE NEW.id END,
		COALESCE(NEW.schedule_date, OLD.schedule_date),
		TG_OP,
		CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END,
		CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END,
		(SELECT id FROM public.profiles WHERE user_id = auth.uid()),
		COALESCE(NEW.family_id, OLD.family_id)
	);

	IF TG_OP = 'DELETE' THEN
		RETURN OLD;
	END IF;
	RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."audit_care_schedule_changes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_approve_expired"("p_env_prefix" "text" DEFAULT ''::"text") RETURNS TABLE("swap_request_id" bigint, "email_type" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    rec    record;
    tz     constant text := 'America/Sao_Paulo';
    expiry timestamptz;
    d      text;
BEGIN
    -- ── 24h reminders: expired between 24h and 48h ago, not yet reminded ──
    FOR rec IN
        SELECT * FROM public.swap_requests
        WHERE status IN ('pending', 'revert_pending') AND reminder_sent_at IS NULL
    LOOP
        expiry := (rec.schedule_date + COALESCE(rec.proposed_handoff_time, '00:00'::time)) AT TIME ZONE tz;
        IF now() >= expiry + interval '24 hours' AND now() < expiry + interval '48 hours' THEN
            d := to_char(rec.schedule_date, 'DD/MM');
            INSERT INTO public.notifications (recipient_profile_id, type, title, message, swap_request_id, is_read, created_at)
            VALUES (
                rec.target_profile_id,
                'auto_reminder',
                p_env_prefix || '⏰ Solicitação pendente expira em 24h',
                'A solicitação do dia ' || d || ' será aprovada automaticamente em 24h se não houver resposta.',
                rec.id, false, now()
            );
            UPDATE public.swap_requests SET reminder_sent_at = now() WHERE id = rec.id;

            swap_request_id := rec.id; email_type := 'reminder'; RETURN NEXT;
        END IF;
    END LOOP;

    -- ── Auto-approve: expired more than 48h ago ──────────────────────────
    FOR rec IN
        SELECT * FROM public.swap_requests
        WHERE status IN ('pending', 'revert_pending')
    LOOP
        expiry := (rec.schedule_date + COALESCE(rec.proposed_handoff_time, '00:00'::time)) AT TIME ZONE tz;
        IF now() >= expiry + interval '48 hours' THEN
            d := to_char(rec.schedule_date, 'DD/MM');

            IF rec.status = 'pending' THEN
                IF rec.schedule_id IS NOT NULL THEN
                    UPDATE public.care_schedules
                    SET actual_parent_id = rec.proposed_actual_parent_id,
                        handoff_time     = rec.proposed_handoff_time,
                        updated_at       = timezone('utc', now())
                    WHERE id = rec.schedule_id;
                END IF;
                UPDATE public.swap_requests SET status = 'approved', resolved_by = 'system' WHERE id = rec.id;
            ELSE
                PERFORM public.restore_pre_edit_state(rec.schedule_id, rec.pre_edit_log_id);
                UPDATE public.swap_requests SET status = 'revert_approved', resolved_by = 'system' WHERE id = rec.id;
            END IF;

            -- Notify the requester and the approver (distinct copy).
            INSERT INTO public.notifications (recipient_profile_id, type, title, message, swap_request_id, is_read, created_at)
            VALUES (
                rec.requesting_profile_id, 'auto_approved',
                p_env_prefix || '✅ Solicitação aprovada automaticamente',
                'A solicitação do dia ' || d || ' foi aprovada automaticamente após 48h sem resposta.',
                rec.id, false, now()
            );
            INSERT INTO public.notifications (recipient_profile_id, type, title, message, swap_request_id, is_read, created_at)
            VALUES (
                rec.target_profile_id, 'auto_approved',
                p_env_prefix || '✅ Solicitação aprovada automaticamente',
                'A solicitação do dia ' || d || ' foi aprovada automaticamente. Você não respondeu dentro do prazo.',
                rec.id, false, now()
            );

            swap_request_id := rec.id; email_type := 'auto_approved'; RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."auto_approve_expired"("p_env_prefix" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_invitation"("p_email" "text", "p_role_id" bigint) RETURNS TABLE("invitation_id" bigint, "token" "uuid", "expires_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
	me  public.profiles%ROWTYPE;
	inv public.family_invitations%ROWTYPE;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();

	IF me.id IS NULL OR NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores da família podem enviar convites.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF (SELECT count(*) FROM public.profiles WHERE family_id = me.family_id) >= 2 THEN
		RAISE EXCEPTION 'Esta família já possui dois responsáveis cadastrados.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF EXISTS (SELECT 1 FROM public.profiles WHERE lower(email) = lower(trim(p_email))) THEN
		RAISE EXCEPTION 'Este e-mail já possui cadastro no aplicativo.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF NOT EXISTS (SELECT 1 FROM public.roles WHERE id = p_role_id) THEN
		RAISE EXCEPTION 'Papel inválido.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- Resend = revoke the previous pending invite + issue a fresh token.
	UPDATE public.family_invitations
	SET revoked_at = timezone('utc', now())
	WHERE family_id = me.family_id AND accepted_at IS NULL AND revoked_at IS NULL;

	INSERT INTO public.family_invitations (family_id, email, role_id, invited_by)
	VALUES (me.family_id, lower(trim(p_email)), p_role_id, me.id)
	RETURNING * INTO inv;

	RETURN QUERY SELECT inv.id, inv.token, inv.expires_at;
END;
$$;


ALTER FUNCTION "public"."create_invitation"("p_email" "text", "p_role_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_day_protection"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
	cur_profile_id bigint;
	cur_is_admin   boolean := false;
	today          date;
	the_date       date;
	fam            bigint;
	is_frozen      boolean := false;
	is_target      boolean := false;
BEGIN
	-- System context (service_role: F-24 auto-approval, migrations): unrestricted.
	SELECT id, is_admin INTO cur_profile_id, cur_is_admin
	FROM public.profiles WHERE user_id = auth.uid();
	IF cur_profile_id IS NULL THEN
		RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
	END IF;

	today    := (now() AT TIME ZONE 'America/Sao_Paulo')::date;
	the_date := COALESCE(NEW.schedule_date, OLD.schedule_date);
	fam      := COALESCE(NEW.family_id, OLD.family_id,
	                     (SELECT family_id FROM public.profiles WHERE id = NEW.scheduled_parent_id));

	SELECT bool_or(true), bool_or(target_profile_id = cur_profile_id)
	INTO is_frozen, is_target
	FROM public.swap_requests
	WHERE family_id = fam AND schedule_date = the_date
	  AND status IN ('pending', 'revert_pending');
	is_frozen := COALESCE(is_frozen, false);
	is_target := COALESCE(is_target, false);

	-- F-12: frozen days are untouchable, except by the pending request's target
	-- (who legitimately applies the calendar change while approving) or an admin.
	IF TG_OP IN ('UPDATE', 'DELETE') AND is_frozen AND NOT is_target AND NOT cur_is_admin THEN
		RAISE EXCEPTION 'Este dia tem uma solicitação pendente e não pode ser alterado.'
			USING ERRCODE = 'check_violation';
	END IF;

	-- F-13: past days are immutable (the target exemption keeps overdue
	-- workflow completions working; admins may bypass — F-14).
	IF the_date < today AND NOT cur_is_admin AND NOT is_target THEN
		RAISE EXCEPTION 'Dias passados não podem ser alterados.'
			USING ERRCODE = 'check_violation';
	END IF;

	IF TG_OP = 'DELETE' THEN
		-- F-12: a day with an approved swap cannot be deleted (admin may — F-14).
		IF OLD.actual_parent_id IS NOT NULL AND OLD.actual_parent_id <> OLD.scheduled_parent_id
		   AND NOT cur_is_admin AND NOT is_target THEN
			RAISE EXCEPTION 'Dias com troca aprovada não podem ser apagados.'
				USING ERRCODE = 'check_violation';
		END IF;
		RETURN OLD;
	END IF;

	-- Swap-workflow enforcement (applies to admins too — F-14 decision):
	-- creating or undoing a swap directly is forbidden; only the pending
	-- request's target (applying an approval) may write such a change.
	-- Exception: admins may correct the actual parent of PAST days (historical
	-- fixes — the workflow cannot exist for past dates), never future ones.
	IF cur_is_admin AND the_date < today THEN
		RETURN NEW;
	END IF;

	IF TG_OP = 'INSERT' THEN
		IF NEW.actual_parent_id IS NOT NULL AND NEW.actual_parent_id <> NEW.scheduled_parent_id THEN
			RAISE EXCEPTION 'Alterações do responsável real devem passar pelo fluxo de aprovação.'
				USING ERRCODE = 'check_violation';
		END IF;
	ELSIF NEW.actual_parent_id IS DISTINCT FROM OLD.actual_parent_id AND NOT is_target THEN
		IF (OLD.actual_parent_id IS NOT NULL AND OLD.actual_parent_id <> OLD.scheduled_parent_id)  -- undo/alter an approved swap
		   OR (NEW.actual_parent_id IS NOT NULL AND NEW.actual_parent_id <> NEW.scheduled_parent_id) -- create a swap directly
		THEN
			RAISE EXCEPTION 'Alterações do responsável real devem passar pelo fluxo de aprovação.'
				USING ERRCODE = 'check_violation';
		END IF;
	END IF;

	RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."enforce_day_protection"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_profile_protection"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
	actor_admin  boolean;
	actor_family bigint;
BEGIN
	-- System context (service_role / migrations): unrestricted.
	IF auth.uid() IS NULL THEN
		RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
	END IF;

	SELECT is_admin, family_id INTO actor_admin, actor_family
	FROM public.profiles WHERE user_id = auth.uid();

	IF TG_OP = 'UPDATE' THEN
		IF NEW.family_id IS DISTINCT FROM OLD.family_id THEN
			RAISE EXCEPTION 'A família de um perfil não pode ser alterada.'
				USING ERRCODE = 'check_violation';
		END IF;

		IF NEW.is_admin IS DISTINCT FROM OLD.is_admin THEN
			-- Blocks self-promotion through the profiles_own_update policy.
			IF COALESCE(actor_admin, false) = false OR actor_family IS DISTINCT FROM OLD.family_id THEN
				RAISE EXCEPTION 'Somente administradores da família podem alterar permissões de administrador.'
					USING ERRCODE = 'check_violation';
			END IF;

			-- Demotion: keep the >= 1 admin per family invariant.
			IF OLD.is_admin AND NOT NEW.is_admin AND NOT EXISTS (
				SELECT 1 FROM public.profiles
				WHERE family_id = OLD.family_id AND is_admin AND id <> OLD.id
			) THEN
				RAISE EXCEPTION 'A família precisa de pelo menos uma pessoa administradora.'
					USING ERRCODE = 'check_violation';
			END IF;
		END IF;

		RETURN NEW;
	END IF;

	-- DELETE: never remove the last admin of a family.
	IF OLD.is_admin AND NOT EXISTS (
		SELECT 1 FROM public.profiles
		WHERE family_id = OLD.family_id AND is_admin AND id <> OLD.id
	) THEN
		RAISE EXCEPTION 'A família precisa de pelo menos uma pessoa administradora.'
			USING ERRCODE = 'check_violation';
	END IF;
	RETURN OLD;
END;
$$;


ALTER FUNCTION "public"."enforce_profile_protection"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_swap_status_transition"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    current_profile_id bigint;
    allowed boolean := false;
BEGIN
    SELECT id INTO current_profile_id
    FROM public.profiles
    WHERE user_id = auth.uid();

    -- Status unchanged → allow (e.g. setting reminder_sent_at, other fields).
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    IF current_profile_id IS NULL THEN
        -- System context: the Edge Function / cron runs as service_role, which
        -- bypasses RLS and has no auth.uid(). Allow ONLY auto-approval transitions.
        -- (Authenticated-without-profile users are already blocked by RLS.)
        allowed := (OLD.status = 'pending'        AND NEW.status = 'approved')
                OR (OLD.status = 'revert_pending' AND NEW.status = 'revert_approved');
    ELSE
        CASE OLD.status
            WHEN 'pending' THEN
                CASE NEW.status
                    WHEN 'approved'  THEN allowed := (current_profile_id = OLD.target_profile_id);
                    WHEN 'rejected'  THEN allowed := (current_profile_id = OLD.target_profile_id);
                    WHEN 'cancelled' THEN allowed := (current_profile_id = OLD.requesting_profile_id);
                    ELSE allowed := false;
                END CASE;

            WHEN 'revert_pending' THEN
                CASE NEW.status
                    WHEN 'revert_approved'  THEN allowed := (current_profile_id = OLD.target_profile_id);
                    WHEN 'revert_rejected'  THEN allowed := (current_profile_id = OLD.target_profile_id);
                    WHEN 'revert_cancelled' THEN allowed := (current_profile_id = OLD.requesting_profile_id);
                    ELSE allowed := false;
                END CASE;

            ELSE
                allowed := false;
        END CASE;
    END IF;

    IF NOT allowed THEN
        RAISE EXCEPTION 'Invalid status transition from "%" to "%" for current user',
            OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;

    NEW.updated_at := timezone('utc', now());
    IF NEW.status IN ('approved', 'rejected', 'cancelled', 'revert_approved', 'revert_rejected', 'revert_cancelled') THEN
        NEW.resolved_at := timezone('utc', now());
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."enforce_swap_status_transition"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_invite_info"("p_token" "uuid") RETURNS TABLE("family_name" "text", "inviter_name" "text", "invited_email" "text", "role_name" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
	SELECT f.name, p.full_name, i.email, r.role
	FROM public.family_invitations i
	JOIN public.families f ON f.id = i.family_id
	JOIN public.profiles p ON p.id = i.invited_by
	JOIN public.roles    r ON r.id = i.role_id
	WHERE i.token = p_token
	  AND i.accepted_at IS NULL
	  AND i.revoked_at  IS NULL
	  AND i.expires_at  > timezone('utc', now());
$$;


ALTER FUNCTION "public"."get_invite_info"("p_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_family_id"() RETURNS bigint
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
	SELECT family_id FROM public.profiles WHERE user_id = auth.uid();
$$;


ALTER FUNCTION "public"."get_my_family_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
	meta_name   text;
	meta_role   text;
	meta_token  text;
	meta_family text;
	inv         public.family_invitations%ROWTYPE;
	fam_id      bigint;
	new_role_id bigint;
	admin_flag  boolean;
BEGIN
	-- Idempotency: never duplicate a profile (e.g. trigger re-run).
	IF EXISTS (SELECT 1 FROM public.profiles WHERE user_id = NEW.id) THEN
		RETURN NEW;
	END IF;

	meta_name   := NULLIF(trim(NEW.raw_user_meta_data ->> 'full_name'), '');
	meta_role   := NULLIF(trim(NEW.raw_user_meta_data ->> 'role'), '');
	meta_token  := NULLIF(trim(NEW.raw_user_meta_data ->> 'invite_token'), '');
	meta_family := NULLIF(trim(NEW.raw_user_meta_data ->> 'family_name'), '');

	-- Fallback: e-mail local part (metadata should always carry the name).
	IF meta_name IS NULL THEN
		meta_name := split_part(NEW.email, '@', 1);
	END IF;

	IF meta_token IS NOT NULL THEN
		-- INVITEE: token must be valid, pending and issued for this e-mail.
		-- (a malformed token must fail with the friendly message, not a cast error)
		BEGIN
			SELECT * INTO inv
			FROM public.family_invitations
			WHERE token = meta_token::uuid
			  AND accepted_at IS NULL
			  AND revoked_at  IS NULL
			  AND expires_at  > timezone('utc', now())
			  AND lower(email) = lower(NEW.email);
		EXCEPTION WHEN invalid_text_representation THEN
			inv := NULL;
		END;

		IF inv.id IS NULL THEN
			RAISE EXCEPTION 'Convite inválido, expirado ou emitido para outro e-mail.'
				USING ERRCODE = 'check_violation';
		END IF;

		-- The family may have completed meanwhile (invite raced a manual add).
		IF (SELECT count(*) FROM public.profiles WHERE family_id = inv.family_id) >= 2 THEN
			RAISE EXCEPTION 'Esta família já possui dois responsáveis cadastrados.'
				USING ERRCODE = 'check_violation';
		END IF;

		fam_id      := inv.family_id;
		new_role_id := inv.role_id;
		admin_flag  := false;

		UPDATE public.family_invitations
		SET accepted_at = timezone('utc', now())
		WHERE id = inv.id;
	ELSE
		-- FOUNDER: creates the family and becomes its admin (F-14 decision).
		IF meta_role IS NULL THEN
			RAISE EXCEPTION 'Selecione o papel (pai ou mãe) para criar a conta.'
				USING ERRCODE = 'check_violation';
		END IF;

		-- Tolerant match: seed data differs across environments — the dev DB
		-- holds 'Pai'/'Mãe' while V001 documents 'father'/'mother'. Accept both
		-- vocabularies (the client always sends the canonical english value).
		SELECT id INTO new_role_id
		FROM public.roles
		WHERE lower(trim(role)) = ANY (
			CASE lower(meta_role)
				WHEN 'father' THEN ARRAY['father', 'pai']
				WHEN 'mother' THEN ARRAY['mother', 'mãe', 'mae']
				ELSE ARRAY[lower(meta_role)]
			END)
		ORDER BY id
		LIMIT 1;
		IF new_role_id IS NULL THEN
			RAISE EXCEPTION 'Papel inválido: %.', meta_role
				USING ERRCODE = 'check_violation';
		END IF;

		-- Family name chosen by the founder; neutral fallback for safety
		-- (the register form makes the field required).
		INSERT INTO public.families (name)
		VALUES (COALESCE(meta_family, 'Família ' || meta_name))
		RETURNING id INTO fam_id;

		admin_flag := true;
	END IF;

	INSERT INTO public.profiles (user_id, full_name, role_id, email, family_id, is_admin)
	VALUES (NEW.id, meta_name, new_role_id, NEW.email, fam_id, admin_flag);

	RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rename_family"("p_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
	me       public.profiles%ROWTYPE;
	new_name text;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();

	IF me.id IS NULL OR NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores da família podem renomear a família.'
			USING ERRCODE = 'check_violation';
	END IF;

	new_name := NULLIF(trim(p_name), '');
	IF new_name IS NULL OR length(new_name) > 80 THEN
		RAISE EXCEPTION 'Informe um nome de família com até 80 caracteres.'
			USING ERRCODE = 'check_violation';
	END IF;

	UPDATE public.families SET name = new_name WHERE id = me.family_id;
END;
$$;


ALTER FUNCTION "public"."rename_family"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."restore_pre_edit_state"("p_schedule_id" bigint, "p_pre_edit_log_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    snap jsonb;
BEGIN
    IF p_schedule_id IS NULL THEN
        RETURN;
    END IF;

    -- No snapshot reference (swaps approved before F-26): clear the swap only.
    IF p_pre_edit_log_id IS NULL THEN
        UPDATE public.care_schedules
        SET actual_parent_id = NULL, updated_at = timezone('utc', now())
        WHERE id = p_schedule_id;
        RETURN;
    END IF;

    SELECT old_data INTO snap FROM public.activity_logs WHERE id = p_pre_edit_log_id;

    -- old_data NULL → the day was created by the edit; restoring "before" removes it.
    IF snap IS NULL THEN
        DELETE FROM public.care_schedules WHERE id = p_schedule_id;
        RETURN;
    END IF;

    UPDATE public.care_schedules
    SET scheduled_parent_id = COALESCE((snap->>'scheduled_parent_id')::bigint, scheduled_parent_id),
        actual_parent_id    = (snap->>'actual_parent_id')::bigint,
        handoff_time        = (snap->>'handoff_time')::time,
        notes               = snap->>'notes',
        updated_at          = timezone('utc', now())
    WHERE id = p_schedule_id;
END;
$$;


ALTER FUNCTION "public"."restore_pre_edit_state"("p_schedule_id" bigint, "p_pre_edit_log_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revoke_invitation"("p_invitation_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
	me public.profiles%ROWTYPE;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();

	IF me.id IS NULL OR NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores da família podem revogar convites.'
			USING ERRCODE = 'check_violation';
	END IF;

	UPDATE public.family_invitations
	SET revoked_at = timezone('utc', now())
	WHERE id = p_invitation_id
	  AND family_id = me.family_id
	  AND accepted_at IS NULL
	  AND revoked_at  IS NULL;
END;
$$;


ALTER FUNCTION "public"."revoke_invitation"("p_invitation_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_care_schedule_family"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
	IF TG_OP = 'INSERT' THEN
		NEW.family_id := (SELECT family_id FROM public.profiles WHERE id = NEW.scheduled_parent_id);
	ELSE
		NEW.family_id := OLD.family_id;
	END IF;
	RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_care_schedule_family"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_member_admin"("p_profile_id" bigint, "p_is_admin" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
	me public.profiles%ROWTYPE;
BEGIN
	SELECT * INTO me FROM public.profiles WHERE user_id = auth.uid();

	IF me.id IS NULL OR NOT me.is_admin THEN
		RAISE EXCEPTION 'Somente administradores da família podem alterar permissões.'
			USING ERRCODE = 'check_violation';
	END IF;

	UPDATE public.profiles
	SET is_admin = p_is_admin
	WHERE id = p_profile_id AND family_id = me.family_id;

	IF NOT FOUND THEN
		RAISE EXCEPTION 'Perfil não encontrado na sua família.'
			USING ERRCODE = 'check_violation';
	END IF;
END;
$$;


ALTER FUNCTION "public"."set_member_admin"("p_profile_id" bigint, "p_is_admin" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_swap_request_family"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
	IF TG_OP = 'INSERT' THEN
		NEW.family_id := (SELECT family_id FROM public.profiles WHERE id = NEW.requesting_profile_id);
	ELSE
		NEW.family_id := OLD.family_id;
	END IF;
	RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_swap_request_family"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."activity_logs" (
    "id" bigint NOT NULL,
    "schedule_id" bigint,
    "affected_date" "date" NOT NULL,
    "action" "text" NOT NULL,
    "old_data" "jsonb",
    "new_data" "jsonb",
    "performed_by_id" bigint,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "family_id" bigint
);


ALTER TABLE "public"."activity_logs" OWNER TO "postgres";


ALTER TABLE "public"."activity_logs" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."activity_logs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."care_schedules" (
    "id" bigint NOT NULL,
    "schedule_date" "date" NOT NULL,
    "scheduled_parent_id" bigint NOT NULL,
    "actual_parent_id" bigint,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "handoff_time" time without time zone,
    "family_id" bigint NOT NULL
);


ALTER TABLE "public"."care_schedules" OWNER TO "postgres";


ALTER TABLE "public"."care_schedules" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."care_schedules_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."families" (
    "id" bigint NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."families" OWNER TO "postgres";


ALTER TABLE "public"."families" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."families_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."family_invitations" (
    "id" bigint NOT NULL,
    "family_id" bigint NOT NULL,
    "email" "text" NOT NULL,
    "role_id" bigint NOT NULL,
    "token" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "invited_by" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("timezone"('utc'::"text", "now"()) + '7 days'::interval) NOT NULL,
    "accepted_at" timestamp with time zone,
    "revoked_at" timestamp with time zone
);


ALTER TABLE "public"."family_invitations" OWNER TO "postgres";


ALTER TABLE "public"."family_invitations" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."family_invitations_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" bigint NOT NULL,
    "recipient_profile_id" bigint NOT NULL,
    "type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "message" "text" NOT NULL,
    "swap_request_id" bigint,
    "is_read" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


ALTER TABLE "public"."notifications" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."notifications_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "role_id" bigint NOT NULL,
    "email" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "family_id" bigint NOT NULL,
    "is_admin" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


ALTER TABLE "public"."profiles" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."profiles_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."roles" (
    "id" bigint NOT NULL,
    "role" "text" NOT NULL
);


ALTER TABLE "public"."roles" OWNER TO "postgres";


ALTER TABLE "public"."roles" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."roles_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."schema_migrations" (
    "version" "text" NOT NULL,
    "description" "text",
    "applied_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."schema_migrations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."swap_requests" (
    "id" bigint NOT NULL,
    "schedule_date" "date" NOT NULL,
    "schedule_id" bigint,
    "requesting_profile_id" bigint NOT NULL,
    "target_profile_id" bigint NOT NULL,
    "previous_actual_parent_id" bigint,
    "proposed_actual_parent_id" bigint NOT NULL,
    "proposed_handoff_time" time without time zone,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "rejection_reason" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "resolved_at" timestamp with time zone,
    "pre_edit_log_id" bigint,
    "reminder_sent_at" timestamp with time zone,
    "resolved_by" "text" DEFAULT 'user'::"text" NOT NULL,
    "family_id" bigint NOT NULL,
    CONSTRAINT "swap_requests_resolved_by_check" CHECK (("resolved_by" = ANY (ARRAY['user'::"text", 'system'::"text"]))),
    CONSTRAINT "swap_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'cancelled'::"text", 'reverted'::"text", 'revert_pending'::"text", 'revert_approved'::"text", 'revert_rejected'::"text", 'revert_cancelled'::"text"])))
);


ALTER TABLE "public"."swap_requests" OWNER TO "postgres";


ALTER TABLE "public"."swap_requests" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."swap_requests_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."activity_logs"
    ADD CONSTRAINT "activity_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."care_schedules"
    ADD CONSTRAINT "care_schedules_family_schedule_date_key" UNIQUE ("family_id", "schedule_date");



ALTER TABLE ONLY "public"."care_schedules"
    ADD CONSTRAINT "care_schedules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."families"
    ADD CONSTRAINT "families_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."family_invitations"
    ADD CONSTRAINT "family_invitations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."family_invitations"
    ADD CONSTRAINT "family_invitations_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."schema_migrations"
    ADD CONSTRAINT "schema_migrations_pkey" PRIMARY KEY ("version");



ALTER TABLE ONLY "public"."swap_requests"
    ADD CONSTRAINT "swap_requests_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "swap_requests_one_pending_per_date" ON "public"."swap_requests" USING "btree" ("family_id", "schedule_date") WHERE ("status" = ANY (ARRAY['pending'::"text", 'revert_pending'::"text"]));



CREATE OR REPLACE TRIGGER "trigger_a_set_care_schedule_family" BEFORE INSERT OR UPDATE ON "public"."care_schedules" FOR EACH ROW EXECUTE FUNCTION "public"."set_care_schedule_family"();



CREATE OR REPLACE TRIGGER "trigger_a_set_swap_request_family" BEFORE INSERT OR UPDATE ON "public"."swap_requests" FOR EACH ROW EXECUTE FUNCTION "public"."set_swap_request_family"();



CREATE OR REPLACE TRIGGER "trigger_audit_care_schedule" AFTER INSERT OR DELETE OR UPDATE ON "public"."care_schedules" FOR EACH ROW EXECUTE FUNCTION "public"."audit_care_schedule_changes"();



CREATE OR REPLACE TRIGGER "trigger_b_enforce_day_protection" BEFORE INSERT OR DELETE OR UPDATE ON "public"."care_schedules" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_day_protection"();



CREATE OR REPLACE TRIGGER "trigger_enforce_profile_protection" BEFORE DELETE OR UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_profile_protection"();



CREATE OR REPLACE TRIGGER "trigger_enforce_swap_status_transition" BEFORE UPDATE ON "public"."swap_requests" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_swap_status_transition"();



ALTER TABLE ONLY "public"."activity_logs"
    ADD CONSTRAINT "activity_logs_family_id_fkey" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id");



ALTER TABLE ONLY "public"."activity_logs"
    ADD CONSTRAINT "activity_logs_performed_by_id_fkey" FOREIGN KEY ("performed_by_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."activity_logs"
    ADD CONSTRAINT "activity_logs_schedule_id_fkey" FOREIGN KEY ("schedule_id") REFERENCES "public"."care_schedules"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."care_schedules"
    ADD CONSTRAINT "care_schedules_actual_parent_id_fkey" FOREIGN KEY ("actual_parent_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."care_schedules"
    ADD CONSTRAINT "care_schedules_family_id_fkey" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id");



ALTER TABLE ONLY "public"."care_schedules"
    ADD CONSTRAINT "care_schedules_scheduled_parent_id_fkey" FOREIGN KEY ("scheduled_parent_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."family_invitations"
    ADD CONSTRAINT "family_invitations_family_id_fkey" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id");



ALTER TABLE ONLY "public"."family_invitations"
    ADD CONSTRAINT "family_invitations_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."family_invitations"
    ADD CONSTRAINT "family_invitations_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_recipient_fkey" FOREIGN KEY ("recipient_profile_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_swap_request_id_fkey" FOREIGN KEY ("swap_request_id") REFERENCES "public"."swap_requests"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_family_id_fkey" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."swap_requests"
    ADD CONSTRAINT "swap_requests_family_id_fkey" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id");



ALTER TABLE ONLY "public"."swap_requests"
    ADD CONSTRAINT "swap_requests_pre_edit_log_id_fkey" FOREIGN KEY ("pre_edit_log_id") REFERENCES "public"."activity_logs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."swap_requests"
    ADD CONSTRAINT "swap_requests_previous_actual_parent_id_fkey" FOREIGN KEY ("previous_actual_parent_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."swap_requests"
    ADD CONSTRAINT "swap_requests_proposed_actual_parent_id_fkey" FOREIGN KEY ("proposed_actual_parent_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."swap_requests"
    ADD CONSTRAINT "swap_requests_requesting_profile_id_fkey" FOREIGN KEY ("requesting_profile_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."swap_requests"
    ADD CONSTRAINT "swap_requests_schedule_id_fkey" FOREIGN KEY ("schedule_id") REFERENCES "public"."care_schedules"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."swap_requests"
    ADD CONSTRAINT "swap_requests_target_profile_id_fkey" FOREIGN KEY ("target_profile_id") REFERENCES "public"."profiles"("id");



CREATE POLICY "Allow full access to care schedules for authenticated users" ON "public"."care_schedules" TO "authenticated" USING (true);



CREATE POLICY "Allow read for authenticated users" ON "public"."roles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow read logs for authenticated users" ON "public"."activity_logs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow read profiles for authenticated users" ON "public"."profiles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow users to update their own profile" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."activity_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "activity_logs_family_read" ON "public"."activity_logs" FOR SELECT TO "authenticated" USING (("family_id" = "public"."get_my_family_id"()));



ALTER TABLE "public"."care_schedules" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "care_schedules_family_delete" ON "public"."care_schedules" FOR DELETE TO "authenticated" USING (("family_id" = "public"."get_my_family_id"()));



CREATE POLICY "care_schedules_family_insert" ON "public"."care_schedules" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "profiles"."family_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "care_schedules"."scheduled_parent_id")) = "public"."get_my_family_id"()));



CREATE POLICY "care_schedules_family_select" ON "public"."care_schedules" FOR SELECT TO "authenticated" USING (("family_id" = "public"."get_my_family_id"()));



CREATE POLICY "care_schedules_family_update" ON "public"."care_schedules" FOR UPDATE TO "authenticated" USING (("family_id" = "public"."get_my_family_id"())) WITH CHECK (("family_id" = "public"."get_my_family_id"()));



ALTER TABLE "public"."families" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "families_member_read" ON "public"."families" FOR SELECT TO "authenticated" USING (("id" = "public"."get_my_family_id"()));



ALTER TABLE "public"."family_invitations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "family_invitations_family_read" ON "public"."family_invitations" FOR SELECT TO "authenticated" USING (("family_id" = "public"."get_my_family_id"()));



ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notifications_insert" ON "public"."notifications" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "profiles"."family_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "notifications"."recipient_profile_id")) = "public"."get_my_family_id"()));



CREATE POLICY "notifications_select_own" ON "public"."notifications" FOR SELECT TO "authenticated" USING (("recipient_profile_id" = ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."user_id" = "auth"."uid"()))));



CREATE POLICY "notifications_update_own" ON "public"."notifications" FOR UPDATE TO "authenticated" USING (("recipient_profile_id" = ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."user_id" = "auth"."uid"())))) WITH CHECK (("recipient_profile_id" = ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."user_id" = "auth"."uid"()))));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_family_read" ON "public"."profiles" FOR SELECT TO "authenticated" USING ((("family_id" = "public"."get_my_family_id"()) OR ("user_id" = "auth"."uid"())));



CREATE POLICY "profiles_own_update" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "roles_authenticated_read" ON "public"."roles" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."schema_migrations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."swap_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "swap_requests_insert" ON "public"."swap_requests" FOR INSERT TO "authenticated" WITH CHECK ((("requesting_profile_id" = ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."user_id" = "auth"."uid"()))) AND (( SELECT "profiles"."family_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "swap_requests"."target_profile_id")) = "public"."get_my_family_id"())));



CREATE POLICY "swap_requests_select_own" ON "public"."swap_requests" FOR SELECT TO "authenticated" USING ((("requesting_profile_id" = ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."user_id" = "auth"."uid"()))) OR ("target_profile_id" = ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."user_id" = "auth"."uid"())))));



CREATE POLICY "swap_requests_update_requester" ON "public"."swap_requests" FOR UPDATE TO "authenticated" USING (("requesting_profile_id" = ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."user_id" = "auth"."uid"())))) WITH CHECK (("requesting_profile_id" = ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."user_id" = "auth"."uid"()))));



CREATE POLICY "swap_requests_update_target" ON "public"."swap_requests" FOR UPDATE TO "authenticated" USING (("target_profile_id" = ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."user_id" = "auth"."uid"())))) WITH CHECK (("target_profile_id" = ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."user_id" = "auth"."uid"()))));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."activity_logs";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."care_schedules";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."notifications";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."profiles";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."roles";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."swap_requests";









GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";











































































































































































GRANT ALL ON FUNCTION "public"."audit_care_schedule_changes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."audit_care_schedule_changes"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."auto_approve_expired"("p_env_prefix" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."auto_approve_expired"("p_env_prefix" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."auto_approve_expired"("p_env_prefix" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_approve_expired"("p_env_prefix" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_invitation"("p_email" "text", "p_role_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_invitation"("p_email" "text", "p_role_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_invitation"("p_email" "text", "p_role_id" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."enforce_day_protection"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."enforce_day_protection"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enforce_day_protection"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."enforce_profile_protection"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."enforce_profile_protection"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enforce_profile_protection"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enforce_swap_status_transition"() TO "anon";
GRANT ALL ON FUNCTION "public"."enforce_swap_status_transition"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enforce_swap_status_transition"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_invite_info"("p_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_invite_info"("p_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_invite_info"("p_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_invite_info"("p_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_family_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_family_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_family_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."handle_new_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."rename_family"("p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rename_family"("p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rename_family"("p_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."restore_pre_edit_state"("p_schedule_id" bigint, "p_pre_edit_log_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."restore_pre_edit_state"("p_schedule_id" bigint, "p_pre_edit_log_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."restore_pre_edit_state"("p_schedule_id" bigint, "p_pre_edit_log_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."restore_pre_edit_state"("p_schedule_id" bigint, "p_pre_edit_log_id" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."revoke_invitation"("p_invitation_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."revoke_invitation"("p_invitation_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."revoke_invitation"("p_invitation_id" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_care_schedule_family"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_care_schedule_family"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_care_schedule_family"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_member_admin"("p_profile_id" bigint, "p_is_admin" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_member_admin"("p_profile_id" bigint, "p_is_admin" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_member_admin"("p_profile_id" bigint, "p_is_admin" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_swap_request_family"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_swap_request_family"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_swap_request_family"() TO "service_role";
























GRANT ALL ON TABLE "public"."activity_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."activity_logs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."activity_logs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."activity_logs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."care_schedules" TO "authenticated";
GRANT ALL ON TABLE "public"."care_schedules" TO "service_role";



GRANT ALL ON SEQUENCE "public"."care_schedules_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."care_schedules_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."families" TO "authenticated";
GRANT ALL ON TABLE "public"."families" TO "service_role";



GRANT ALL ON SEQUENCE "public"."families_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."families_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."family_invitations" TO "authenticated";
GRANT ALL ON TABLE "public"."family_invitations" TO "service_role";



GRANT ALL ON SEQUENCE "public"."family_invitations_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."family_invitations_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON SEQUENCE "public"."notifications_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."notifications_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON SEQUENCE "public"."profiles_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."profiles_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."roles" TO "authenticated";
GRANT ALL ON TABLE "public"."roles" TO "service_role";



GRANT ALL ON SEQUENCE "public"."roles_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."roles_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."schema_migrations" TO "service_role";



GRANT ALL ON TABLE "public"."swap_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."swap_requests" TO "service_role";



GRANT ALL ON SEQUENCE "public"."swap_requests_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."swap_requests_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































