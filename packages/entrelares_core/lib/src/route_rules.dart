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

  /// A validated session.
  authed,
}

abstract final class RouteRules {
  static const String splash = '/splash';
  static const String login = '/login';
  static const String register = '/register';
  static const String resetPassword = '/reset-password';
  static const String updatePassword = '/update-password';
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
  /// cannot apply to them, and a login form is already answered.
  static const Set<String> anonymousOnlyRoutes = {
    splash,
    login,
    register,
    resetPassword,
  };

  static bool isPublic(String location) => publicRoutes.contains(location);

  /// Whether a remembered FULL uri (path plus query — the invite token lives in
  /// the query) may be restored once the gate has answered.
  static bool isRestorable(String uri) {
    final path = Uri.tryParse(uri)?.path;
    return path != null && isPublic(path);
  }

  /// Where the router should send this visitor; null means "stay here".
  ///
  /// [pendingLocation] is the full URI an App Link asked for before the gate
  /// answered. It is only ever honoured for a PUBLIC destination: a deep link
  /// into the app proper still has to pass through login, and restoring it
  /// blindly would hand an anonymous visitor a guarded screen.
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
        AuthPhase.authed =>
          anonymousOnlyRoutes.contains(location) ? home : null,
      };
}
