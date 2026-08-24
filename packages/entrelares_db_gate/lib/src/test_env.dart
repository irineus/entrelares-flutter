import 'dart:io';

/// Where the gate points and how it authorizes — the Dart twin of the C#
/// suite's `TestEnv` (T-30).
///
/// The suite runs against the REAL dev Supabase project, never a local stack:
/// the invariant it exists to prove is "the client MIRRORS, the database
/// ENFORCES", and a local stack proves it about a database no user talks to.
/// URL and anon key default to the committed dev config (both PUBLIC — the same
/// pair `env.dart` ships); the service-role key is a SECRET and is REQUIRED —
/// without it the fixture aborts with instructions rather than running half a
/// suite and reporting green.
///
/// Sources, in order: environment variable (CI: the `SUPABASE_SERVICE_ROLE_DEV`
/// secret) → the git-ignored `e2e.local.env` file, searched upward from the
/// working directory, for local runs.
abstract final class TestEnv {
  /// The signature the DB-side purge guard recognises. `purge_e2e_family`
  /// re-validates it server-side, which is what makes a fixture bug unable to
  /// delete a real family.
  static const String e2eFamilyPrefix = 'E2E-';

  /// Resend's test domain: accepted, delivered nowhere, never bounces.
  static const String e2eEmailDomain = '@resend.dev';

  static String get supabaseUrl =>
      _get('E2E_SUPABASE_URL') ?? 'https://buroanotfjcgvbfmacuh.supabase.co';

  static String get anonKey =>
      _get('E2E_SUPABASE_ANON_KEY') ??
      'sb_publishable_Eniwxftri8Std4uXaWhD8w_tzKO9u-g';

  static String get serviceRoleKey {
    final key = _get('E2E_SUPABASE_SERVICE_ROLE_KEY');
    if (key == null || key.trim().isEmpty) {
      throw StateError(
        'E2E_SUPABASE_SERVICE_ROLE_KEY is not set. The gate needs the DEV '
        "project's service_role key (Dashboard → Settings → API) to create and "
        'purge its throwaway family. Set the environment variable, or put '
        "'E2E_SUPABASE_SERVICE_ROLE_KEY=<key>' in the git-ignored e2e.local.env "
        'file at the repository root. Never use the PROD key here.',
      );
    }
    return key.trim();
  }

  /// S-16: a key is either LEGACY (a JWT signed with the project's JWT secret)
  /// or NEW-MODEL (`sb_publishable_…` / `sb_secret_…`). They need OPPOSITE
  /// headers, so every HAND-BUILT request goes through [keyHeaders] instead of
  /// hardcoding one shape:
  ///   · legacy → `apikey` AND `Authorization: Bearer`. PostgREST derives the
  ///     DB role from the Bearer JWT; `apikey` alone runs as `anon`, which in
  ///     this 100%-RLS app reads nothing (the T-44 keep-alive lesson).
  ///   · new    → `apikey` ONLY. They are not JWTs: the gateway resolves the
  ///     role from the key itself.
  /// Keeping both shapes alive is what lets the CI secrets be rotated one at a
  /// time instead of in a single flip-everything-at-once step.
  static bool isNewKeyFormat(String key) => key.startsWith('sb_');

  static Map<String, String> keyHeaders(String key) => {
        'apikey': key,
        if (!isNewKeyFormat(key)) 'Authorization': 'Bearer $key',
      };

  /// OPTIONAL secrets (e.g. the billing-webhook shared token). Absent is a
  /// valid state — the dependent tests arm themselves only when the value
  /// exists, mirroring how the function secret itself is provisioned
  /// out-of-band. CI passes a missing GitHub secret as an EMPTY string, which
  /// is the same thing as absent.
  static String? optional(String key) {
    final value = _get(key);
    return (value == null || value.trim().isEmpty) ? null : value.trim();
  }

  static String? _get(String key) =>
      Platform.environment[key] ?? _localEnvFile[key];

  static Map<String, String>? _localEnvFileCache;

  /// Minimal `.env` reader: `KEY=VALUE` lines, `#` comments; searched upward
  /// from the working directory so it works from any package directory.
  static Map<String, String> get _localEnvFile {
    final cached = _localEnvFileCache;
    if (cached != null) return cached;

    final values = <String, String>{};
    for (var dir = Directory.current;; dir = dir.parent) {
      final file = File('${dir.path}${Platform.pathSeparator}e2e.local.env');
      if (file.existsSync()) {
        for (final line in file.readAsLinesSync()) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
          final separator = trimmed.indexOf('=');
          if (separator <= 0) continue;
          values[trimmed.substring(0, separator).trim()] =
              trimmed.substring(separator + 1).trim();
        }
        break;
      }
      if (dir.parent.path == dir.path) break; // filesystem root
    }
    return _localEnvFileCache = values;
  }
}
