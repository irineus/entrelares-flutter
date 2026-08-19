/// S-10 sudo elevation — the pure half of `entrelares-app`
/// `Entrelares/Services/SudoService.cs`, plus the two QA fixes the console
/// pilot paid for (see `entrelares-console` `lib/rules.dart` and the notes on
/// [isElevated]).
///
/// The SERVER owns the truth: `auth_elevations.elevated_until` is written only
/// by the `elevate` Edge Function (service role), and every gated RPC re-checks
/// `is_elevated()`. Everything here exists so the client can decide whether to
/// ASK for the password before spending a round-trip — and so the marker that
/// comes back when it guessed wrong is recognised on both transports.
library;

abstract final class SudoRules {
  /// The marker a gated RPC or Edge Function prefixes to its message when the
  /// elevation window is missing or expired.
  static const String elevationRequiredMarker = 'ELEVATION_REQUIRED';

  /// The server's window. The Edge Function owns this number; it is duplicated
  /// here only as the fallback when a response carries no `elevated_until`.
  static const Duration serverWindow = Duration(minutes: 5);

  /// Renewing this early avoids racing the RPC's own check at the boundary: a
  /// client that considers itself elevated for the last second of the window
  /// will lose that race about as often as it wins it.
  static const Duration edgeSafety = Duration(seconds: 15);

  /// Wrong-password attempts before the local throttle kicks in.
  static const int maxAttempts = 3;

  static const Duration cooldown = Duration(seconds: 60);

  /// Detects the marker on EITHER transport: a PostgREST error whose JSON body
  /// carries the raised message, or an Edge Function payload
  /// (`FunctionException.details['error']`). Deliberately a substring test on
  /// the stringified error, not a prefix match — the marker survives being
  /// wrapped in an exception's `toString()` either way.
  static bool isElevationRequired(Object? error) =>
      error != null && error.toString().contains(elevationRequiredMarker);

  /// Removes the marker AND the ": " that follows it, leaving the human half
  /// of the message. A message with no marker comes back untouched.
  static String stripMarker(String error) =>
      error.replaceAll('$elevationRequiredMarker: ', '');

  /// Whether the client believes it is still elevated. Null (never elevated)
  /// is false; the [edgeSafety] margin is subtracted BEFORE comparing.
  static bool isElevated(DateTime? elevatedUntilUtc, DateTime nowUtc) =>
      elevatedUntilUtc != null &&
      elevatedUntilUtc.subtract(edgeSafety).isAfter(nowUtc);

  /// Seconds left of the local throttle, rounded UP (a fraction of a second
  /// still reads as "1" — truncating would show "0" while the gate is closed).
  /// Floored at zero when there is no active cooldown.
  static int cooldownSecondsRemaining(
      DateTime? cooldownUntilUtc, DateTime nowUtc) {
    if (cooldownUntilUtc == null || !cooldownUntilUtc.isAfter(nowUtc)) return 0;
    final micros = cooldownUntilUtc.difference(nowUtc).inMicroseconds;
    return (micros / Duration.microsecondsPerSecond).ceil();
  }

  /// The local throttle's step after a refused password. On the [maxAttempts]th
  /// failure the counter RESETS and the cooldown starts — so after waiting the
  /// user gets a fresh set of three attempts, not a single one. (Faithful to
  /// the web; a port that keeps counting would lock the user out for good.)
  static ({int failedAttempts, bool cooldownStarts}) registerFailedAttempt(
      int currentFailedAttempts) {
    final next = currentFailedAttempts + 1;
    return next >= maxAttempts
        ? (failedAttempts: 0, cooldownStarts: true)
        : (failedAttempts: next, cooldownStarts: false);
  }

  /// When the elevation the server just granted expires. The Edge Function
  /// returns `elevated_until` as an ISO instant; anything unparseable falls
  /// back to the local estimate, which is conservative because the client also
  /// subtracts [edgeSafety] before trusting it.
  static DateTime elevatedUntilFrom(String? serverIsoInstant, DateTime nowUtc) {
    if (serverIsoInstant != null) {
      final parsed = DateTime.tryParse(serverIsoInstant);
      if (parsed != null) return parsed.toUtc();
    }
    return nowUtc.add(serverWindow);
  }
}
