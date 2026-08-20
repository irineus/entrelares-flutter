import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'deep_link_urls.dart';
import 'env.dart';
import 'models/member.dart';
import 'screens/calendar_screen.dart';
import 'screens/custom_roles_screen.dart';
import 'screens/family_screen.dart';
import 'screens/home_shell.dart';
import 'screens/leaving_screen.dart';
import 'screens/login_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/policy_update_screen.dart';
import 'screens/premium_return_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/register_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/reset_password_screen.dart';
import 'screens/update_password_screen.dart';
import 'services/account_identity.dart';
import 'services/admin_mode.dart';
import 'services/analytics_service.dart';
import 'services/custody_data_source.dart';
import 'services/notification_badge.dart';
import 'services/onboarding_service.dart';
import 'services/session_gate.dart';
import 'services/store_billing.dart';
import 'services/sudo_service.dart';
import 'services/supabase_custody_data_source.dart';
import 'theme/app_theme.dart';
import 'widgets/app_l10n.dart';
import 'widgets/app_splash.dart';
import 'widgets/onboarding.dart';

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
  late final NotificationBadge _badge;

  /// U-28 — who is signed in, published by the screens that load the member
  /// list and read by the account button in every tab's app bar.
  final AccountIdentity _identity = AccountIdentity();
  /// T-37 — one per process; a no-op unless the flavor carries a website id.
  late final AnalyticsService _analytics;
  // S-10: session-scoped like admin mode, and for a stronger reason — an
  // elevation window must never outlive the session that earned it.
  late final SudoService _sudo;
  // T-48: the store rail exists only where there IS a store. On the web target
  // it is null and the Premium section keeps its neutral note — the same state
  // the master switch off produces, so one missing piece never yields a
  // half-drawn offer.
  final StoreBilling? _storeBilling = kIsWeb ? null : PlayStoreBilling();

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
        // U-28: the product's first frame says what the product is — the
        // web's U-10 animated calendar, ported to Flutter over the tokens.
        builder: (_, _) => const AppSplash(),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) => LoginScreen(
          onSignIn: _signIn,
          onForgotPassword: () => _router.go('/reset-password'),
          onSignUp: () => _router.go('/register'),
          prefs: widget.prefs,
          expiredReason: _expiredReason,
        ),
      ),
      GoRoute(
        path: '/register',
        builder: (_, state) => RegisterScreen(
          dataSource: _dataSource,
          analytics: _analytics,
          inviteToken: InviteFormRules.inviteTokenFrom(state.uri),
          onSignIn: _signIn,
          onBackToLogin: () => _router.go('/login'),
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
      // S-11: outside the shell on purpose — a member on their way out has no
      // tabs to browse.
      GoRoute(
        path: '/leaving',
        builder: (_, _) => LeavingScreen(
          dataSource: _dataSource,
          sudo: _sudo,
          onSignOut: _signOut,
          onReturned: () {
            _isLeaving = false;
            _router.go('/');
          },
        ),
      ),
      // S-15: also outside the shell — past the notice window this is the only
      // screen the app offers.
      // T-39: where the hosted checkout sends the payer back. It is the SAME
      // path the web serves (`appUrl/premium/retorno`, built server-side by
      // billing-checkout), so on a device with the domain verified the App
      // Link opens the app here and anywhere else it stays on the web.
      GoRoute(
        path: '/premium/retorno',
        builder: (_, _) => PremiumReturnScreen(
          dataSource: _dataSource,
          analytics: _analytics,
          onBackToFamily: () => _router.go('/family'),
        ),
      ),
      GoRoute(
        path: '/policy-update',
        builder: (_, _) => PolicyUpdateScreen(
          dataSource: _dataSource,
          onSignOut: _signOut,
          onAccepted: () {
            _consentState = ConsentGateState.upToDate;
            _router.go('/');
          },
        ),
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => HomeShell(
            shell: shell,
            adminMode: _adminMode,
            badge: _badge,
            identity: _identity,
            // U-28: the shell owns sign-out now, so it is reachable from all
            // four tabs — it used to be a CalendarScreen parameter only.
            onSignOut: _signOut,
            onOpenProfile: () => _router.go('/family/profile'),
            deletionBanner: _deletionBanner,
            tourKeys: _tourKeys),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => CalendarScreen(
                  dataSource: _dataSource,
                  adminMode: _adminMode,
                  analytics: _analytics,
                  onboarding: _onboarding,
                  tourKeys: _tourKeys,
                  onOpenFamily: () => _router.go('/family')),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/family',
              builder: (_, _) => FamilyScreen(
                dataSource: _dataSource,
                adminMode: _adminMode,
                analytics: _analytics,
                sudo: _sudo,
                storeBilling: _storeBilling,
                onFamilyDeleted: _signOut,
                onOpenCustomRoles: () => _router.go('/family/custom-roles'),
                // F-16: own card opens my profile; another member's opens
                // theirs, and the screen itself re-checks that I may look.
                onOpenProfile: (member, isOwn) => _router.go(
                    isOwn ? '/family/profile' : '/family/profile/${member.id}'),
              ),
              routes: [
                // Nested so the bottom bar stays put — the web navigates away
                // to `/custom-roles` and `/profile` because it has no
                // persistent tab shell.
                GoRoute(
                  path: 'custom-roles',
                  builder: (_, _) => CustomRolesScreen(
                    dataSource: _dataSource,
                    analytics: _analytics,
                    onSeePremium: () => _router.go('/family'),
                  ),
                ),
                GoRoute(
                  path: 'profile',
                  builder: (_, _) => ProfileScreen(
                    dataSource: _dataSource,
                    sudo: _sudo,
                    onOpenFamily: () => _router.go('/family'),
                    onReopenOnboarding: ({required bool replayTour}) async {
                      await _onboarding.reopenChecklist();
                      _onboarding.tourReplayRequested = replayTour;
                      if (mounted) _router.go('/');
                    },
                    onLeaving: () {
                      _isLeaving = true;
                      _router.go('/leaving');
                    },
                  ),
                  routes: [
                    GoRoute(
                      path: ':id',
                      builder: (_, state) => ProfileScreen(
                        dataSource: _dataSource,
                        sudo: _sudo,
                        profileId:
                            int.tryParse(state.pathParameters['id'] ?? ''),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/notifications',
              builder: (_, _) => NotificationsScreen(
                  dataSource: _dataSource, badge: _badge),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/reports',
              builder: (_, _) => ReportsScreen(dataSource: _dataSource),
            ),
          ]),
        ],
      ),
    ],
  );

  /// Where an App Link wanted to go before the session gate had answered — the
  /// state half of [RouteRules.redirect] (the decision itself is a pure mirror
  /// with its own tests).
  String? _pendingLocation;

  /// S-11: this member asked to leave, so the app is closed to them until they
  /// cancel or sign out (mirror of `MainLayout.EnforceLeaving`).
  bool _isLeaving = false;

  /// S-15/B-4: whether the re-consent gate warns, blocks, or says nothing.
  ConsentGateState _consentState = ConsentGateState.upToDate;

  /// S-11: what the shell's persistent deletion banner shows, or null.
  FamilyDeletionBanner? _deletionBanner;

  /// U-23 — the checklist/tour state and the shared registry of tour targets
  /// (they live in two different subtrees: the tab bar and the calendar).
  late final OnboardingService _onboarding;
  final _tourKeys = TourKeys();

  String? _redirect(BuildContext context, GoRouterState state) {
    final location = state.matchedLocation;

    if (_phase == _AuthPhase.gate) {
      // Remember the destination WITH its query — the invite token lives there
      // — for as long as the gate is still deciding.
      if (location != RouteRules.splash) _pendingLocation = state.uri.toString();
      return RouteRules.redirect(phase: AuthPhase.gate, location: location);
    }

    // The web's order, and it matters: authentication first, then the exit
    // confinement, then the consent gate. A member on their way out never
    // meets the re-consent screen — asking someone to accept new terms on the
    // way to deleting their account would be absurd.
    if (_phase == _AuthPhase.authed) {
      if (FamilyLifecycleRules.mustStayOnLeavingScreen(
          isLeaving: _isLeaving, location: location)) {
        return FamilyLifecycleRules.leavingRoute;
      }
      if (!_isLeaving &&
          _consentState == ConsentGateState.blocked &&
          location != FamilyLifecycleRules.policyUpdateRoute &&
          location != RouteRules.login) {
        return FamilyLifecycleRules.policyUpdateRoute;
      }
    }

    final pending = _pendingLocation;
    final decision = RouteRules.redirect(
      phase: _routePhase,
      location: location,
      pendingLocation: pending,
    );
    // Hand a remembered destination back exactly once (otherwise leaving that
    // screen would bounce straight into it again), and drop it entirely once
    // there is a session — by then it has either been used or was never usable.
    if (decision == pending || _phase == _AuthPhase.authed) {
      _pendingLocation = null;
    }
    return decision;
  }

  AuthPhase get _routePhase => switch (_phase) {
        _AuthPhase.gate => AuthPhase.gate,
        _AuthPhase.anon => AuthPhase.anon,
        _AuthPhase.authed => AuthPhase.authed,
      };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _gate = SessionGate(_client.auth);
    _analytics = AnalyticsService(language: widget.initialLanguage.code);
    _dataSource = SupabaseCustodyDataSource(_client,
        environmentPrefix:
            environmentTitlePrefix(isProduction: Env.current.isProduction),
        analytics: _analytics);
    _badge = NotificationBadge(_dataSource);
    // T-37: a pageview per navigation, the app's answer to the web's
    // `OnLocationChanged`. The URL is sanitized by the pure mirror, so no
    // invite token or profile id can travel with it.
    _router.routeInformationProvider.addListener(_trackPageView);
    _sudo = SudoService(_dataSource);
    _onboarding = OnboardingService(_dataSource);
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
    _router.routeInformationProvider.removeListener(_trackPageView);
    _inactivityTimer?.cancel();
    _adminMode.dispose();
    _storeBilling?.dispose();
    _sudo.dispose();
    _badge.dispose();
    _refresh.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkInactivity();
  }

  void _trackPageView() {
    final location = _router.routeInformationProvider.value.uri.toString();
    // The splash is a gate, not a screen someone visited.
    if (location.startsWith('/splash')) return;
    _analytics.trackPageView(location);
  }

  void _setPhase(_AuthPhase phase) {
    if (!mounted) return;
    _phase = phase;
    // Mirror of the web's logout path: leaving the authenticated phase for
    // ANY reason (sign-out, inactivity, dead session) drops admin mode — and
    // the S-10 elevation window with it.
    if (phase != _AuthPhase.authed) {
      _adminMode.deactivate();
      _sudo.reset();
    }
    if (phase == _AuthPhase.authed) {
      _lastInteraction = DateTime.now();
      _inactivityTimer ??= Timer.periodic(
          InactivityPolicy.pollInterval, (_) => _checkInactivity());
      // The bell badge lives with the authenticated phase (count + its
      // workflow Realtime trigger).
      _badge.start();
    } else {
      _badge.stop();
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
    _identity.clear();
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

    // S-11/S-15 — the two account gates, decided once per authenticated boot
    // exactly like the web's MainLayout does after its first render.
    _isLeaving = me.leftAt != null;
    _consentState = _isLeaving
        ? ConsentGateState.upToDate
        : PolicyVersions.evaluate(me.consentPolicyVersion, DateTime.now());
    _refresh.ping();
    unawaited(_refreshDeletionBanner(me));

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

  /// S-11 — the banner that has to reach every tab. Best-effort: a family with
  /// no pending request is the overwhelmingly common case, and a failed read
  /// must never keep the app from opening.
  Future<void> _refreshDeletionBanner(Member me) async {
    try {
      final pending = await _dataSource.fetchPendingFamilyDeletion();
      if (!mounted) return;
      if (pending == null || _isLeaving) {
        if (_deletionBanner != null) {
          setState(() => _deletionBanner = null);
        }
        return;
      }
      final members = await _dataSource.fetchMembers();
      if (!mounted) return;
      setState(() {
        _deletionBanner = FamilyDeletionBanner(
          scheduledFor: pending.request.scheduledFor,
          allAgreed: FamilyLifecycleRules.allAgreed(
            members: members
                .map((m) => LifecycleMember(
                    id: m.id,
                    isActiveMember: m.isActiveMember,
                    isAdmin: m.isAdmin))
                .toList(),
            requesterProfileId: pending.request.requestedBy,
            votes: pending.responses
                .map((r) =>
                    DeletionVote(profileId: r.profileId, agreed: r.agreed))
                .toList(),
          ),
          iAmRequester: pending.request.requestedBy == me.id,
          onTap: () => _router.go('/family'),
        );
      });
    } catch (_) {
      // No banner is the honest fallback: the Família page still shows the
      // whole panel, and the DB enforces the deadline regardless.
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
          // U-27 — both themes are hand-written from the tokens, and dark
          // ships WITH them: it is nearly free here and was nearly impossible
          // against the 79 colour literals this delivery removed. Following
          // the system is the whole feature for now; a user-facing switch is
          // U-12's, not this item's.
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeMode.system,
          routerConfig: _router,
        ),
      ),
    );
  }
}
