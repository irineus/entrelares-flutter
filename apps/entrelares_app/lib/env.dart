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
    this.umamiWebsiteId = '',
    required this.analyticsHostname,
    required this.androidPackage,
  });

  final String name;
  final bool isProduction;
  final String supabaseUrl;
  final String supabaseKey;

  /// T-37: the Umami website id is PUBLIC (it identifies a site, not a person)
  /// but environment-specific. **Empty on dev on purpose** — the service turns
  /// into a no-op, so QA traffic never pollutes production statistics, exactly
  /// as the web app's deploy does by leaving the variable unset outside
  /// `master`.
  final String umamiWebsiteId;

  /// Umami Cloud. A self-hosted collector would change this (and the web app's
  /// `UMAMI_HOST` variable) together.
  final String umamiHost = 'https://cloud.umami.is';

  /// What Umami reports as the site. The app declares its own hostname so
  /// store traffic is separable from `web.entrelares.app` in the same
  /// dashboard — a device has no `location.hostname` to read.
  final String analyticsHostname;

  /// T-48: the Android `applicationId` of THIS variant. Only the Play
  /// "manage subscription" deep link reads it, and pointing it at the wrong
  /// package sends the subscriber to a page about an app they do not have —
  /// hence a per-flavor value rather than a constant (dev deliberately keeps
  /// its own package so the QA build coexists with the store one).
  final String androidPackage;

  /// Dev/QA — the spike's original target. Still runs the legacy anon JWT
  /// until S-17 (app repo) retires it.
  static const dev = Env._(
    name: 'Dev/QA',
    isProduction: false,
    supabaseUrl: 'https://buroanotfjcgvbfmacuh.supabase.co',
    supabaseKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ1cm9hbm90ZmpjZ3ZiZm1hY3VoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEwMTIwNDcsImV4cCI6MjA5NjU4ODA0N30.hRU5jhn1pJQeUVpvnAp4IGBJ5Is_pCwlIfR5hdK9Mi0',
    // No website id: analytics is OFF on dev, by decision.
    analyticsHostname: 'dev.app.entrelares.app',
    androidPackage: 'com.entrelares.flutter',
  );

  /// Production — the exact public values `web.entrelares.app` serves every
  /// browser in `appsettings.json` (S-16 publishable key).
  static const prod = Env._(
    name: 'Produção',
    isProduction: true,
    supabaseUrl: 'https://jptqbwfziyzlhlmoekzu.supabase.co',
    supabaseKey: 'sb_publishable_uKr0ES-10F3gpcd0j0osYw_HxqP_RMZ',
    // T-37: the PRODUCT's Umami site — the same one the web app reports to, so
    // the two clients share a dashboard and the `channel` prop separates them.
    umamiWebsiteId: '6fdd6c5a-4bce-449f-8188-3b7399a859d8',
    analyticsHostname: 'app.entrelares.app',
    androidPackage: 'com.entrelares.app',
  );

  /// Anything that is not the `prod` flavor falls back to dev: `flutter test`
  /// and flavor-less targets must never touch production.
  static const current = appFlavor == 'prod' ? prod : dev;

  /// Mirrors `pubspec.yaml`'s `version:` — the web's `AppVersion.Display`.
  /// Only the F-17 export reads it, and a stale value there would misdate an
  /// LGPD record, so `env_version_test.dart` fails the build if the two drift.
  static const String appVersion = '0.2.29+31';
}
