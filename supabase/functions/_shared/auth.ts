// S-16 — in-code authorization for functions whose gateway JWT check had to go.
//
// Why this file exists: the platform's `verify_jwt` gate only understands the
// LEGACY JWT-based keys. A caller holding a new-model key (`sb_secret_…`) sends
// it on the `apikey` header — which the gate does not verify — so every function
// reachable by such a caller must run with `verify_jwt = false` and authorize
// the request itself. Without an explicit check, turning the gate off would
// leave the function open to anonymous invocation (e-mail relay, cron worker,
// account purge), so each caller class gets a check here:
//
//   · internal / cron caller  → holds the SECRET key, sent on `apikey`
//   · app caller (a signed-in user) → holds a real user JWT on `Authorization`
//
// This is the same shape as `billing-webhook`'s `asaas-access-token` check, the
// function that has always run without the gate.

/** Minimal shape of the admin client used to validate a user JWT (a supabase-js client fits). */
// deno-lint-ignore no-explicit-any
export type UserValidator = { auth: { getUser: (jwt: string) => Promise<any> } };

/** Length-checked, constant-time-ish comparison — no early exit on the first differing byte. */
function secureEquals(a: string, b: string): boolean {
	if (a.length !== b.length) return false;
	let diff = 0;
	for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
	return diff === 0;
}

/**
 * True when the caller presents the project's SECRET key — i.e. it is one of our
 * own backends: a pg_cron job (`net.http_post` with the key on `apikey`) or
 * another Edge Function calling this one. The key is read from `apikey`; the
 * `Authorization` header is NOT accepted for it, because the new keys are not
 * JWTs and the platform rejects them there.
 */
export function isSecretKeyCaller(req: Request, secret: string): boolean {
	const presented = req.headers.get("apikey");
	return presented !== null && secureEquals(presented, secret);
}

/**
 * True when the caller carries a valid Supabase user session (the app's own
 * calls, which the SDK sends as `Authorization: Bearer <access token>`). This
 * reproduces exactly what the `verify_jwt` gate used to do — any authenticated
 * user passes; per-request ownership rules stay where they already are, inside
 * each function.
 */
export async function hasValidUserSession(req: Request, admin: UserValidator): Promise<boolean> {
	const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
	if (!jwt) return false;
	const { data, error } = await admin.auth.getUser(jwt);
	return !error && !!data?.user;
}

/** Header set for our own function-to-function and cron calls (S-16: key on `apikey`, never Bearer). */
export function internalCallHeaders(secret: string): Record<string, string> {
	return { "apikey": secret, "Content-Type": "application/json" };
}
