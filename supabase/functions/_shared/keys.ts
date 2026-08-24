// S-16 — API key resolution for the NEW Supabase key model.
//
// The legacy `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY` env vars hold a
// single JWT string signed with the project's JWT secret. The new publishable
// (`sb_publishable_…`) and secret (`sb_secret_…`) keys are NOT JWTs — they are
// injected as a JSON dictionary keyed by the key's NAME:
//
//   SUPABASE_PUBLISHABLE_KEYS = {"default":"sb_publishable_…"}
//   SUPABASE_SECRET_KEYS      = {"default":"sb_secret_…"}
//
// Reading the new vars is what lets the legacy keys be deactivated (and what
// makes the ES256 signing-key cutover safe): the new keys are validated by the
// platform gateway and no longer depend on the JWT secret at all.
//
// Naming: the Dashboard creates the first key as `default`, but a project may
// hold differently-named keys (the DEV project's publishable key is named
// `github_key`). So: prefer `default`; if there is exactly ONE key, use it;
// otherwise fail loudly naming the candidates — never guess between several,
// since picking the wrong one is an auth failure that only shows up at runtime.

function resolve(varName: string, expectedPrefix: string): string {
	const raw = Deno.env.get(varName);
	if (!raw) {
		throw new Error(
			`${varName} is not set. This project is still on the legacy API keys — ` +
			`create the publishable/secret keys in Dashboard → Settings → API Keys ` +
			`BEFORE deploying the functions (see supabase/README.md § 10).`,
		);
	}

	let dict: Record<string, string>;
	try {
		dict = JSON.parse(raw) as Record<string, string>;
	} catch {
		throw new Error(`${varName} is not valid JSON — expected {"<name>":"${expectedPrefix}…"}.`);
	}

	const names = Object.keys(dict);
	const key = dict["default"] ?? (names.length === 1 ? dict[names[0]] : undefined);
	if (!key) {
		throw new Error(
			`${varName} has no "default" key and holds ${names.length} candidates ` +
			`(${names.join(", ")}) — name one of them "default", or the function ` +
			`cannot tell which to use.`,
		);
	}
	return key;
}

/** The secret key (`sb_secret_…`) — bypasses RLS. Server-side only, never sent to a browser. */
export function secretKey(): string {
	return resolve("SUPABASE_SECRET_KEYS", "sb_secret_");
}

/** The publishable key (`sb_publishable_…`) — the anon-equivalent, RLS applies. */
export function publishableKey(): string {
	return resolve("SUPABASE_PUBLISHABLE_KEYS", "sb_publishable_");
}
