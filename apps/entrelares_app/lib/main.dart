import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'deep_link_urls.dart';
import 'env.dart';
import 'models/member.dart';
import 'screens/calendar_screen.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'screens/placeholder_screen.dart';
import 'screens/reset_password_screen.dart';
import 'screens/update_password_screen.dart';
import 'services/admin_mode.dart';
import 'services/custody_data_source.dart';
import 'services/session_gate.dart';
import 'services/supabase_custody_data_source.dart';
import 'widgets/app_l10n.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // publishableKey is just the `apikey` header value — it accepts the legacy
  // anon JWT dev still uses (until S-17) as well as the new sb_publishable_…
  // key prod already has, so the S-16 shape ports for free (stage 0).
  // Incoming App Links with auth tokens (recovery) are consumed here too:
  // supabase_flutter parses them and emits `passwordRecovery`.
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

enum _AuthPhase { gate, anon, authed }

/// Pings the router into re-running its redirect when the auth phase moves.
class _RouterRefresh extends ChangeNotifier {
  void ping() => notifyListeners();
}

class _EntrelaresAppState extends State<EntrelaresApp>
    with WidgetsBindingObserver {
  late final SessionGate _gate;
  late final CustodyDataSource _dataSource;
  // F-14: session-scoped, like the web's scoped AdminModeService — never
  // persisted; leaving the authenticated phase always deactivates it.
  final _adminMode = AdminMode();
  late Localization _l;
  final _refresh = _RouterRefresh();
  _AuthPhase _phase = _AuthPhase.gate;
  SessionExpiredReason _expiredReason = SessionExpiredReason.none;
  StreamSubscription<AuthState>? _authSub;

  // S-04 — inactivity timeout (mirror in InactivityPolicy). The web resets on
  // click/touch/key/scroll; every one of those starts as a pointer-down here.
  // Background time counts, same as the web's timer running in a hidden tab:
  // the resume hook re-checks immediately.
  DateTime _lastInteraction = DateTime.now();
  Timer? _inactivityTimer;

  /// Second belt of the adoption loop guard (the web's sessionStorage flag):
  /// even if the local persist failed, one process never adopts twice.
  static bool _adoptedThisProcess = false;

  SupabaseClient get _client => Supabase.instance.client;

  late final GoRouter _router = GoRouter(
    initialLocation: '/splash',
    refreshListenable: _refresh,
    redirect: _redirect,
    routes: [
      GoRoute(
        path: '/splash',
        builder: (_, _) =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) => LoginScreen(
          onSignIn: _signIn,
          onForgotPassword: () => _router.go('/reset-password'),
          prefs: widget.prefs,
          expiredReason: _expiredReason,
        ),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (_, _) => ResetPasswordScreen(
          onSendReset: (email) => _client.auth.resetPasswordForEmail(email,
              redirectTo: DeepLinkUrls.updatePassword),
          onBackToLogin: () => _router.go('/login'),
        ),
      ),
      GoRoute(
        path: '/update-password',
        builder: (_, _) => UpdatePasswordScreen(
          hasSession: _client.auth.currentSession != null,
          onUpdatePassword: (newPassword) async {
            await _client.auth
                .updateUser(UserAttributes(password: newPassword));
          },
          onDone: () => _router.go('/'),
        ),
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => HomeShell(shell: shell, adminMode: _adminMode),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => CalendarScreen(
                  dataSource: _dataSource,
                  adminMode: _adminMode,
                  onSignOut: _signOut),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/family',
              builder: (_, _) =>
                  const PlaceholderScreen(titleKey: K.navFamily),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/notifications',
              builder: (_, _) =>
                  const PlaceholderScreen(titleKey: K.navNotifications),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/reports',
              builder: (_, _) =>
                  const PlaceholderScreen(titleKey: K.navReports),
            ),
          ]),
        ],
      ),
    ],
  );

  /// S-02's shape in router terms: everything is guarded except the auth
  /// surfaces. `/update-password` stays reachable in EVERY phase — the
  /// recovery visitor is technically authenticated, and an anonymous open
  /// shows the web's own "invalid session" message instead of bouncing.
  String? _redirect(BuildContext context, GoRouterState state) {
    final location = state.matchedLocation;
    const public = {'/login', '/reset-password', '/update-password'};
    return switch (_phase) {
      _AuthPhase.gate => location == '/splash' ? null : '/splash',
      _AuthPhase.anon => public.contains(location) ? null : '/login',
      _AuthPhase.authed => (location == '/splash' ||
              location == '/login' ||
              location == '/reset-password')
          ? '/'
          : null,
    };
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _gate = SessionGate(_client.auth);
    _dataSource = SupabaseCustodyDataSource(_client,
        environmentPrefix:
            environmentTitlePrefix(isProduction: Env.current.isProduction));
    _l = Localization(widget.initialLanguage);
    _openGate();
    _authSub = _client.auth.onAuthStateChange.listen((state) {
      switch (state.event) {
        // Pilot lesson 1.1 (second half): when the session dies MID-USE,
        // return to login instead of letting every call fail 42501.
        case AuthChangeEvent.signedOut:
          if (_expiredReason == SessionExpiredReason.none &&
              _phase == _AuthPhase.authed) {
            _expiredReason = SessionExpiredReason.restored;
          }
          _setPhase(_AuthPhase.anon);
        // The recovery deep link's session was just created from the e-mail
        // tokens — land on the new-password form wherever the app was.
        case AuthChangeEvent.passwordRecovery:
          _setPhase(_AuthPhase.authed);
          _router.go('/update-password');
        // A session that appeared while we sat anonymous (deep link paths);
        // the explicit flows (_signIn/_openGate) set their phase themselves.
        case AuthChangeEvent.signedIn:
          if (_phase == _AuthPhase.anon) {
            _expiredReason = SessionExpiredReason.none;
            _setPhase(_AuthPhase.authed);
            _syncProfileLanguage();
          }
        default:
          break;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSub?.cancel();
    _inactivityTimer?.cancel();
    _adminMode.dispose();
    _refresh.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkInactivity();
  }

  void _setPhase(_AuthPhase phase) {
    if (!mounted) return;
    _phase = phase;
    // Mirror of the web's logout path: leaving the authenticated phase for
    // ANY reason (sign-out, inactivity, dead session) drops admin mode.
    if (phase != _AuthPhase.authed) _adminMode.deactivate();
    if (phase == _AuthPhase.authed) {
      _lastInteraction = DateTime.now();
      _inactivityTimer ??= Timer.periodic(
          InactivityPolicy.pollInterval, (_) => _checkInactivity());
    } else {
      _inactivityTimer?.cancel();
      _inactivityTimer = null;
    }
    _refresh.ping();
  }

  void _checkInactivity() {
    if (_phase != _AuthPhase.authed) return;
    if (!InactivityPolicy.expired(_lastInteraction, DateTime.now())) return;
    _expiredReason = SessionExpiredReason.inactivity;
    _setPhase(_AuthPhase.anon);
    // Local-first is fine: navigation never waits on the network (lesson 1.3).
    unawaited(_gate.signOutSafely());
  }

  Future<void> _openGate() async {
    // Lesson 1.1: a restored session proves nothing — validate with
    // refreshSession() BEFORE routing (Blazor got this for free via
    // forceLoad; Flutter has no equivalent).
    final hadSession = _client.auth.currentSession != null;
    final alive = await _gate.validateRestoredSession();
    if (!mounted) return;
    _expiredReason = !alive && hadSession
        ? SessionExpiredReason.restored
        : SessionExpiredReason.none;
    _setPhase(alive ? _AuthPhase.authed : _AuthPhase.anon);
    if (alive) await _syncProfileLanguage();
  }

  Future<void> _signIn(String email, String password) async {
    await _client.auth.signInWithPassword(email: email, password: password);
    _expiredReason = SessionExpiredReason.none;
    _setPhase(_AuthPhase.authed);
    await _syncProfileLanguage();
  }

  Future<void> _signOut() async {
    await _gate.signOutSafely();
    // Lesson 1.3: navigate ALWAYS (the auth listener also fires on success).
    _expiredReason = SessionExpiredReason.none;
    _setPhase(_AuthPhase.anon);
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
      child: Listener(
        // S-04: any touch anywhere is activity.
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _lastInteraction = DateTime.now(),
        child: MaterialApp.router(
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
          routerConfig: _router,
        ),
      ),
    );
  }
}
