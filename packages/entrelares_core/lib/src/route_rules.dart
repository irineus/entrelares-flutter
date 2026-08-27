/// S-02 in router terms: which screens an unauthenticated visitor may reach,
/// and where everyone else is sent. Mirror of the web's `MainLayout.EnforceAuth`
/// allow-list, plus the one rule this stack needs and the web never did.
///
/// **Why a pending location exists.** In the browser the URL survives whatever
/// the app does while it decides who you are. Here the session gate must answer
/// BEFORE routing (pilot lesson 1.1), so an App Link that arrives cold is
/// interrupted by the splash — and its destination would simply be lost. The
/// recovery link does not notice, because its `passwordRecovery` event routes
/// explicitly; an INVITATION link carries no event at all, so without this the
/// visitor lands on the login screen holding a link that appears to do nothing.
library;

enum AuthPhase {
  /// The restored session is still being validated — nothing may render yet.
  gate,

  /// No live session.
  anon,

  /// F-57: a validated session with NO profile — an OAuth sign-up whose
  /// profile `handle_new_user` deferred. The app is closed to it except the
  /// onboarding screen, where family (or invitation claim) and S-13 consent
  /// are collected.
  onboarding,

  /// A validated session.
  authed,
}

abstract final class RouteRules {
  static const String splash = '/splash';
  static const String login = '/login';
  static const String register = '/register';
  static const String resetPassword = '/reset-password';
  static const String updatePassword = '/update-password';

  /// F-57: where a profile-less (deferred OAuth) session lives until it
  /// founds a family or claims its invitation.
  static const String onboarding = '/onboarding';

  static const String home = '/';

  /// Reachable without a session. `/update-password` is here even though the
  /// recovery visitor is technically authenticated: opening it anonymously
  /// shows the web's own "invalid session" message instead of bouncing.
  static const Set<String> publicRoutes = {
    login,
    register,
    resetPassword,
    updatePassword,
  };

  /// Screens an authenticated visitor has no business on: a sign-up form
  /// cannot apply to them, and a login form is already answered. F-57 adds
  /// the onboarding screen — despite the name, a FULLY onboarded visitor has
  /// no business there either (their family already exists), and the
  /// onboarding PHASE forces its own route regardless of this set.
  static const Set<String> anonymousOnlyRoutes = {
    splash,
    login,
    register,
    resetPassword,
    onboarding,
  };

  static bool isPublic(String location) => publicRoutes.contains(location);

  /// Whether a remembered FULL uri (path plus query — the invite token lives in
  /// the query) may be restored for someone who turned out to have NO session.
  /// Public only: restoring a guarded screen for an anonymous visitor would be
  /// handing over exactly what S-02 exists to refuse.
  static bool isRestorable(String uri) {
    final path = Uri.tryParse(uri)?.path;
    return path != null && isPublic(path);
  }

  /// The same question for someone the gate confirmed as AUTHENTICATED — and
  /// the answer is almost the opposite: any screen except the ones that make
  /// no sense with a session (a login form is already answered).
  ///
  /// This is what makes F5 restore the screen the reader was on. On Android
  /// nothing exercised it: there is no reload, and the App Links that arrive
  /// cold aim at public routes. On the web EVERY reload goes through the gate,
  /// so without this an authenticated reader who refreshed `/family` was
  /// silently returned to the calendar — the destination remembered, then
  /// thrown away one phase later.
  static bool isRestorableWhenAuthed(String uri) {
    final path = Uri.tryParse(uri)?.path;
    return path != null &&
        path.isNotEmpty &&
        !anonymousOnlyRoutes.contains(path);
  }

  /// Where the router should send this visitor; null means "stay here".
  ///
  /// [pendingLocation] is the full URI an App Link — or a browser reload —
  /// asked for before the gate answered. Who it is honoured for depends on the
  /// answer the gate gave: for an ANONYMOUS visitor only a public destination
  /// (restoring a guarded screen would hand over exactly what S-02 refuses),
  /// and for an AUTHENTICATED one anything that is not an anonymous-only
  /// screen — that second half is what makes a reload land where the reader
  /// was.
  static String? redirect({
    required AuthPhase phase,
    required String location,
    String? pendingLocation,
  }) =>
      switch (phase) {
        AuthPhase.gate => location == splash ? null : splash,
        AuthPhase.anon => isPublic(location)
            ? null
            : (pendingLocation != null && isRestorable(pendingLocation)
                ? pendingLocation
                : login),
        // F-57: a profile-less session is confined to the onboarding screen —
        // the S-11 leaving confinement's shape, for the opposite end of the
        // account's life. A pending destination is deliberately NOT honoured:
        // there is no profile to show any of it to yet.
        AuthPhase.onboarding =>
            location == onboarding ? null : onboarding,
        AuthPhase.authed => anonymousOnlyRoutes.contains(location)
            ? (pendingLocation != null &&
                    isRestorableWhenAuthed(pendingLocation)
                ? pendingLocation
                : home)
            : null,
      };
}
