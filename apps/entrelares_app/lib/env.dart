import 'package:flutter/services.dart' show appFlavor;

/// PUBLIC client config — the same values the web app ships in its
/// `appsettings.json`. Nothing here is a secret and no secret may ever be
/// added to this file: both keys have zero privilege by construction
/// (100% RLS, T-44); all power comes from the authenticated session and the
/// server-side gates.
///
/// Stage 3 (T-53): environments are BUILD FLAVORS. The Supabase singleton
/// initializes once per process (pilot lesson 8), so [current] is resolved at
/// COMPILE TIME from `--flavor` — per build variant, never a runtime switcher.
class Env {
  const Env._({
    required this.name,
    required this.isProduction,
    required this.supabaseUrl,
    required this.supabaseKey,
  });

  final String name;
  final bool isProduction;
  final String supabaseUrl;
  final String supabaseKey;

  /// Dev/QA — the spike's original target. Still runs the legacy anon JWT
  /// until S-17 (app repo) retires it.
  static const dev = Env._(
    name: 'Dev/QA',
    isProduction: false,
    supabaseUrl: 'https://buroanotfjcgvbfmacuh.supabase.co',
    supabaseKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ1cm9hbm90ZmpjZ3ZiZm1hY3VoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEwMTIwNDcsImV4cCI6MjA5NjU4ODA0N30.hRU5jhn1pJQeUVpvnAp4IGBJ5Is_pCwlIfR5hdK9Mi0',
  );

  /// Production — the exact public values `web.entrelares.app` serves every
  /// browser in `appsettings.json` (S-16 publishable key).
  static const prod = Env._(
    name: 'Produção',
    isProduction: true,
    supabaseUrl: 'https://jptqbwfziyzlhlmoekzu.supabase.co',
    supabaseKey: 'sb_publishable_uKr0ES-10F3gpcd0j0osYw_HxqP_RMZ',
  );

  /// Anything that is not the `prod` flavor falls back to dev: `flutter test`
  /// and flavor-less targets must never touch production.
  static const current = appFlavor == 'prod' ? prod : dev;

  /// Mirrors `pubspec.yaml`'s `version:` — the web's `AppVersion.Display`.
  /// Only the F-17 export reads it, and a stale value there would misdate an
  /// LGPD record, so `env_version_test.dart` fails the build if the two drift.
  static const String appVersion = '0.2.17+19';
}
