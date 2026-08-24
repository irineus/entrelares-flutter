// F-58 (QA round) — operator-only change of a member's LOGIN e-mail.
//
// The e-mail is the member's only way in: when they lose the mailbox, the
// operator is the recovery path. Changing `profiles.email` alone would change
// nothing — the login lives in GoTrue — so this function goes through GoTrue's
// Admin API (`admin.updateUserById`), which also keeps `auth.identities`
// consistent; the existing `sync_profile_email` trigger then mirrors the new
// address into `profiles`, and the S-10 profile audit writes the family's own
// `account_logs` row. This function adds the OPERATOR trail entry on top.
//
// Authorization (same model as the admin_* RPCs, enforced HERE because GoTrue's
// Admin API cannot be reached from SQL):
//   · the platform `verify_jwt` gate stays ON (callers are signed-in users);
//   · the caller resolved FROM THE TOKEN must be in `platform_operators`;
//   · an ACTIVE S-10 elevation is required — the `ELEVATION_REQUIRED:` marker
//     is the client contract to open the sudo prompt and retry.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { secretKey } from "../_shared/keys.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const admin = createClient(supabaseUrl, secretKey());

    // Identity comes from the session token, never from the request body.
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    if (!jwt) {
      return jsonResponse({ error: "Sessão inválida. Entre novamente." }, 401);
    }
    const { data: userData, error: userError } = await admin.auth.getUser(jwt);
    if (userError || !userData?.user?.id) {
      return jsonResponse({ error: "Sessão inválida. Entre novamente." }, 401);
    }
    const callerId = userData.user.id;

    const { data: operator } = await admin
      .from("platform_operators").select("user_id").eq("user_id", callerId).maybeSingle();
    if (!operator) {
      return jsonResponse({ error: "Acesso restrito à operação da plataforma." }, 403);
    }

    const { data: elevation } = await admin
      .from("auth_elevations").select("elevated_until").eq("user_id", callerId).maybeSingle();
    if (!elevation || new Date(elevation.elevated_until) <= new Date()) {
      return jsonResponse(
        { error: "ELEVATION_REQUIRED: Confirme sua senha para alterar o e-mail de um participante." },
        403);
    }

    const { profile_id, new_email } = await req.json().catch(() => ({}));
    const target = typeof new_email === "string" ? new_email.trim().toLowerCase() : "";
    if (!Number.isInteger(profile_id) || !EMAIL_RE.test(target)) {
      return jsonResponse({ error: "Informe o participante e um e-mail válido." }, 400);
    }

    const { data: profile } = await admin
      .from("profiles")
      .select("id, user_id, email, family_id, left_at")
      .eq("id", profile_id)
      .maybeSingle();
    if (!profile) {
      return jsonResponse({ error: "Participante não encontrado." }, 404);
    }
    if (!profile.user_id || profile.left_at) {
      return jsonResponse(
        { error: "Este participante saiu da família — o perfil é imutável (S-11) e não há login a recuperar." },
        400);
    }
    if ((profile.email ?? "").toLowerCase() === target) {
      return jsonResponse({ error: "O novo e-mail é igual ao atual." }, 400);
    }

    // GoTrue owns the uniqueness rule; `email_confirm` skips the confirmation
    // round-trip on purpose — the operator IS the recovery path, and the old
    // mailbox may no longer exist to click anything.
    const { error: updateError } = await admin.auth.admin.updateUserById(
      profile.user_id, { email: target, email_confirm: true });
    if (updateError) {
      const message = /already|registered|exists|duplicate/i.test(updateError.message)
        ? "Este e-mail já está em uso por outra conta."
        : `Não foi possível alterar o e-mail: ${updateError.message}`;
      return jsonResponse({ error: message }, 409);
    }

    const { error: auditError } = await admin.from("operator_audit_logs").insert({
      operator_user_id: callerId,
      action: "member_email_changed",
      family_id: profile.family_id,
      old_value: profile.email,
      new_value: target,
    });
    if (auditError) {
      // The change already happened; a lost trail row is worth surfacing loudly
      // in logs, but must not read as failure to the operator.
      console.error(`[admin-update-member-email] audit insert failed: ${auditError.message}`);
    }

    return jsonResponse({ ok: true, old_email: profile.email, new_email: target });
  } catch (err) {
    console.error(`[admin-update-member-email] unexpected: ${err instanceof Error ? err.message : err}`);
    return jsonResponse({ error: "Não foi possível alterar o e-mail. Tente novamente." }, 500);
  }
});
