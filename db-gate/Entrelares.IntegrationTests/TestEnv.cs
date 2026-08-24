namespace Entrelares.IntegrationTests
{
    // T-30: the suite runs against the REAL dev Supabase project (decision of
    // July 2026). URL and anon key default to the committed dev config; the
    // service-role key is a secret and is REQUIRED — without it the fixture
    // aborts with instructions instead of running half a suite. Sources, in
    // order: environment variable (CI: from the SUPABASE_SERVICE_ROLE_DEV
    // secret) → the git-ignored `e2e.local.env` file at the repo root
    // (KEY=VALUE lines) for local runs.
    public static class TestEnv
    {
        public const string E2eFamilyPrefix = "E2E-";
        public const string E2eEmailDomain = "@resend.dev";   // Resend test domain — no real mailbox, no bounces

        public static string SupabaseUrl =>
            Get("E2E_SUPABASE_URL") ?? "https://buroanotfjcgvbfmacuh.supabase.co";

        public static string AnonKey =>
            Get("E2E_SUPABASE_ANON_KEY") ?? "sb_publishable_Eniwxftri8Std4uXaWhD8w_tzKO9u-g";

        public static string ServiceRoleKey =>
            Get("E2E_SUPABASE_SERVICE_ROLE_KEY")
            ?? throw new InvalidOperationException(
                "E2E_SUPABASE_SERVICE_ROLE_KEY is not set. The suite needs the DEV project's service_role " +
                "key (Dashboard → Settings → API) to create/purge its throwaway test family. Set the " +
                "environment variable, or put 'E2E_SUPABASE_SERVICE_ROLE_KEY=<key>' in the git-ignored " +
                "e2e.local.env file at the repository root. Never use the PROD key here.");

        // S-16: a key is either LEGACY (a JWT signed with the project's JWT
        // secret) or NEW-MODEL (`sb_publishable_…` / `sb_secret_…`). They need
        // OPPOSITE headers, so every hand-built request goes through the helper
        // below instead of hardcoding one shape:
        //   · legacy → `apikey` AND `Authorization: Bearer`. PostgREST derives the
        //     DB role from the Bearer JWT; `apikey` alone runs as `anon`, which in
        //     this 100% RLS-locked app reads nothing (the T-44 keep-alive lesson).
        //   · new    → `apikey` ONLY. They are not JWTs: the platform resolves the
        //     role from the key itself and rejects it on Authorization.
        // Keeping both shapes alive is what lets the CI secrets be rotated one at
        // a time instead of in a single flip-everything-at-once step.
        public static bool IsNewKeyFormat(string key) =>
            key.StartsWith("sb_", StringComparison.Ordinal);

        public static void ApplyKeyHeaders(HttpRequestMessage request, string key)
        {
            request.Headers.Add("apikey", key);
            if (!IsNewKeyFormat(key)) request.Headers.Add("Authorization", $"Bearer {key}");
        }

        // T-39: OPTIONAL secrets (e.g. the billing-webhook shared token). Absent
        // is a valid state — the dependent tests arm themselves only when the
        // value exists (env var or e2e.local.env), mirroring how the function
        // secret itself is provisioned out-of-band.
        public static string? Optional(string key)
        {
            var value = Get(key);
            // CI passes missing GitHub secrets as empty strings — same as absent.
            return string.IsNullOrWhiteSpace(value) ? null : value;
        }

        private static string? Get(string key) =>
            Environment.GetEnvironmentVariable(key) ?? LocalEnvFile.Value.GetValueOrDefault(key);

        // Minimal .env reader: KEY=VALUE lines, '#' comments; searched upward
        // from the test assembly so it works from any project/working dir.
        private static readonly Lazy<Dictionary<string, string>> LocalEnvFile = new(() =>
        {
            var values = new Dictionary<string, string>();
            for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            {
                var path = Path.Combine(dir.FullName, "e2e.local.env");
                if (!File.Exists(path)) continue;

                foreach (var line in File.ReadAllLines(path))
                {
                    var trimmed = line.Trim();
                    if (trimmed.Length == 0 || trimmed.StartsWith('#')) continue;
                    var separator = trimmed.IndexOf('=');
                    if (separator <= 0) continue;
                    values[trimmed[..separator].Trim()] = trimmed[(separator + 1)..].Trim();
                }
                break;
            }
            return values;
        });
    }
}
