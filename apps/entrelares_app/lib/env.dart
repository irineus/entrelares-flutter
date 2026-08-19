/// PUBLIC client config — the same values the web app ships in its
/// `appsettings.json`. Nothing here is a secret and no secret may ever be
/// added to this file: the anon key has zero privilege by construction
/// (100% RLS, T-44); all power comes from the authenticated session and the
/// server-side gates.
///
/// The spike targets DEV ONLY. Prod arrives at stage 3 via build flavors —
/// the Supabase singleton initializes once per process (pilot lesson 8), so
/// environments are per build variant, never a runtime switcher.
/// Dev still runs the legacy anon JWT until S-17 (app repo) retires it.
class Env {
  static const name = 'Dev/QA';
  static const supabaseUrl = 'https://buroanotfjcgvbfmacuh.supabase.co';
  static const supabaseKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ1cm9hbm90ZmpjZ3ZiZm1hY3VoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEwMTIwNDcsImV4cCI6MjA5NjU4ODA0N30.hRU5jhn1pJQeUVpvnAp4IGBJ5Is_pCwlIfR5hdK9Mi0';
}
