// S-10 — sudo-mode elevation: verify the CURRENT password, grant a 5-minute
// elevation window.
//
// The client calls this with the user's JWT plus the password typed in the
// sudo prompt. The function resolves the user FROM THE TOKEN (never from the
// body), verifies the password through GoTrue's own token endpoint with the
// anon key — a throwaway grant whose tokens are discarded, so the caller's
// session is never touched (same pattern as U-17's register-invitee) — and
// then upserts public.auth_elevations via the service role. Sensitive RPCs
// check is_elevated() server-side, so a stolen session token alone cannot
// perform account operations.
//
// Rate limiting: GoTrue's own password-grant limits apply to the verification
// call, and the client throttles the prompt (3 failures → 60 s cooldown).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { publishableKey, secretKey } from "../_shared/keys.ts";

const ELEVATION_MINUTES = 5;

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

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey  = secretKey();
    const anonKey     = publishableKey();
    const admin       = createClient(supabaseUrl, serviceKey);

    // Identity comes from the session token, never from the request body.
    const authHeader = req.headers.get("Authorization") ?? "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    if (!jwt) {
      return jsonResponse({ error: "Sessão inválida. Entre novamente." }, 401);
    }
    const { data: userData, error: userError } = await admin.auth.getUser(jwt);
    if (userError || !userData?.user?.email) {
      return jsonResponse({ error: "Sessão inválida. Entre novamente." }, 401);
    }

    const { password } = await req.json().catch(() => ({}));
    if (!password || typeof password !== "string") {
      return jsonResponse({ error: "Informe sua senha." }, 400);
    }

    // Throwaway password grant against GoTrue — the returned tokens are
    // discarded on purpose; this is only a password check.
    const verify = await fetch(`${supabaseUrl}/auth/v1/token?grant_type=password`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: anonKey },
      body: JSON.stringify({ email: userData.user.email, password }),
    });

    if (verify.status === 429) {
      return jsonResponse(
        { error: "Muitas tentativas. Aguarde alguns minutos antes de tentar novamente." }, 429);
    }
    if (!verify.ok) {
      return jsonResponse({ error: "Senha incorreta." }, 401);
    }

    const elevatedUntil = new Date(Date.now() + ELEVATION_MINUTES * 60_000).toISOString();
    const { error: upsertError } = await admin
      .from("auth_elevations")
      .upsert({ user_id: userData.user.id, elevated_until: elevatedUntil });

    if (upsertError) {
      console.error(`[elevate] upsert failed: ${upsertError.message}`);
      return jsonResponse({ error: "Não foi possível confirmar. Tente novamente." }, 500);
    }

    return jsonResponse({ elevated_until: elevatedUntil });
  } catch (err) {
    console.error(`[elevate] unexpected: ${err instanceof Error ? err.message : err}`);
    return jsonResponse({ error: "Não foi possível confirmar. Tente novamente." }, 500);
  }
});
