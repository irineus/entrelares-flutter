import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'env.dart';
import 'models/member.dart';
import 'screens/calendar_screen.dart';
import 'screens/login_screen.dart';
import 'services/custody_data_source.dart';
import 'services/session_gate.dart';
import 'services/supabase_custody_data_source.dart';
import 'widgets/app_l10n.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // publishableKey is just the `apikey` header value — it accepts the legacy
  // anon JWT dev still uses (until S-17) as well as the new sb_publishable_…
  // key prod already has, so the S-16 shape ports for free (stage 0).
  await Supabase.initialize(
    url: Env.current.supabaseUrl,
    publishableKey: Env.current.supabaseKey,
  );
  // U-13: the language is resolved BEFORE the first frame — override beats
  // profile beats device, PT-BR fallback. The profile half is null here (no
  // session yet); it joins after the gate via the adoption rule.
  final prefs = await SharedPreferences.getInstance();
  final language = LanguageResolver.resolve(
    prefs.getString(LanguageResolver.storageKey),
    null,
    PlatformDispatcher.instance.locale.toLanguageTag(),
  );
  runApp(EntrelaresApp(prefs: prefs, initialLanguage: language));
}

class EntrelaresApp extends StatefulWidget {
  final SharedPreferences prefs;
  final AppLanguage initialLanguage;

  const EntrelaresApp(
      {super.key, required this.prefs, required this.initialLanguage});

  @override
  State<EntrelaresApp> createState() => _EntrelaresAppState();
}

enum _Route { gate, login, calendar }

class _EntrelaresAppState extends State<EntrelaresApp> {
  late final SessionGate _gate;
  late final CustodyDataSource _dataSource;
  late Localization _l;
  _Route _route = _Route.gate;
  bool _restoredSessionExpired = false;
  StreamSubscription<AuthState>? _authSub;

  /// Second belt of the adoption loop guard (the web's sessionStorage flag):
  /// even if the local persist failed, one process never adopts twice.
  static bool _adoptedThisProcess = false;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _gate = SessionGate(_client.auth);
    _dataSource = SupabaseCustodyDataSource(_client);
    _l = Localization(widget.initialLanguage);
    _openGate();
    // Pilot lesson 1.1 (second half): when the session dies MID-USE, return
    // to login instead of letting every call fail 42501.
    _authSub = _client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.signedOut && mounted) {
        setState(() => _route = _Route.login);
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _openGate() async {
    // Lesson 1.1: a restored session proves nothing — validate with
    // refreshSession() BEFORE routing (Blazor got this for free via
    // forceLoad; Flutter has no equivalent).
    final hadSession = _client.auth.currentSession != null;
    final alive = await _gate.validateRestoredSession();
    if (!mounted) return;
    setState(() {
      _restoredSessionExpired = !alive && hadSession;
      _route = alive ? _Route.calendar : _Route.login;
    });
    if (alive) await _syncProfileLanguage();
  }

  Future<void> _signIn(String email, String password) async {
    await _client.auth.signInWithPassword(email: email, password: password);
    if (mounted) setState(() => _route = _Route.calendar);
    await _syncProfileLanguage();
  }

  Future<void> _signOut() async {
    await _gate.signOutSafely();
    // Lesson 1.3: navigate ALWAYS (the auth listener also fires on success).
    if (mounted) {
      setState(() {
        _restoredSessionExpired = false;
        _route = _Route.login;
      });
    }
  }

  /// U-13 — the authenticated half of the language rule, in the web's
  /// MainLayout order: adoption first (it "reboots" the tree), detection
  /// recording second and best-effort — a failed write costs one e-mail in
  /// the old language and retries next boot.
  Future<void> _syncProfileLanguage() async {
    final Member? me;
    try {
      me = await _dataSource.fetchOwnProfile();
    } catch (_) {
      return; // no profile readable — nothing to sync
    }
    if (me == null) return;

    final stored = widget.prefs.getString(LanguageResolver.storageKey);
    if (!_adoptedThisProcess &&
        Localization.shouldAdopt(me.language, _l.current, stored)) {
      _adoptedThisProcess = true;
      final adopted = AppLanguage.tryParse(me.language)!;
      // First belt: make the NEXT boot resolve to the adopted language —
      // without persisting, a profile saying "en" on a pt-BR device would be
      // adopted, rebuilt, re-detected and adopted again, forever.
      try {
        await widget.prefs
            .setString(LanguageResolver.storageKey, adopted.code);
      } catch (_) {
        // covered by the process guard above
      }
      if (mounted) setState(() => _l = Localization(adopted));
      return;
    }

    if (me.leftAt == null &&
        Localization.shouldRecordDetected(me.languageDetected, _l.current)) {
      try {
        await _dataSource.updateDetectedLanguage(me.id, _l.current.code);
      } catch (_) {
        // best-effort by design
      }
    }
  }

  /// U-13 — the picker's path. Local storage first (it is what the next boot
  /// reads), the profile second and best-effort; then the whole tree rebuilds
  /// in the new language (the `forceLoad` analog).
  Future<void> _setLanguage(AppLanguage language) async {
    if (language == _l.current) return;
    try {
      await widget.prefs
          .setString(LanguageResolver.storageKey, language.code);
    } catch (_) {
      // Storage refused the write: the session still gets the language below;
      // the next boot re-detects from the device locale.
    }
    if (_client.auth.currentSession != null) {
      try {
        final me = await _dataSource.fetchOwnProfile();
        if (me != null) {
          await _dataSource.updateOwnLanguage(me.id, language.code);
        }
      } catch (_) {
        // The client's choice does not depend on the server write — the
        // profile copy exists for the server-side senders.
      }
    }
    if (mounted) setState(() => _l = Localization(language));
  }

  @override
  Widget build(BuildContext context) {
    return AppL10n(
      l: _l,
      setLanguage: _setLanguage,
      child: MaterialApp(
        title:
            '${environmentTitlePrefix(isProduction: Env.current.isProduction)}'
            'Entrelares',
        // Material's own surfaces (dialogs, tooltips, a11y announcements)
        // follow the session language; the app's text reads the catalog.
        locale: _l.isEnglish ? const Locale('en') : const Locale('pt', 'BR'),
        supportedLocales: const [Locale('pt', 'BR'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
          colorScheme:
              ColorScheme.fromSeed(seedColor: const Color(0xFF4F46E5)),
          useMaterial3: true,
        ),
        home: switch (_route) {
          _Route.gate =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
          _Route.login => LoginScreen(
              onSignIn: _signIn,
              showSessionExpiredNotice: _restoredSessionExpired,
            ),
          _Route.calendar => CalendarScreen(
              dataSource: _dataSource,
              onSignOut: _signOut,
            ),
        },
      ),
    );
  }
}
