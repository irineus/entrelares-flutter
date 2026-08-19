import 'localization/k.dart';

/// S-01 — progressive client-side login throttling, the mirror of
/// `Login.razor`'s rule in the web app. The server is not involved: this
/// exists to slow a keyboard attacker down on THIS device, and the numbers
/// must match the web so QA reads one behaviour.
abstract final class LoginThrottle {
  /// Failed attempts → lockout seconds. Under 3 failures there is no lockout
  /// (the count is still persisted); 3–4 failures cost `attempts × 5` seconds;
  /// 5 or more cost a flat 60.
  static int lockoutSecondsFor(int failedAttempts) {
    if (failedAttempts >= 5) return 60;
    if (failedAttempts >= 3) return failedAttempts * 5;
    return 0;
  }

  /// Seconds left of a persisted lockout, floored at zero — the restore path
  /// (the web keeps `login_lockout_until` in sessionStorage; the app keeps it
  /// in local prefs so a process restart does not reset the clock).
  static int remainingSeconds(DateTime lockoutUntil, DateTime now) {
    final seconds = lockoutUntil.difference(now).inSeconds;
    return seconds > 0 ? seconds : 0;
  }
}

/// S-04 — the 30-minute inactivity timeout, mirror of `MainLayout.razor`.
/// Only the threshold decision is a rule; WHAT counts as interaction (pointer
/// events, app resume) is the shell's business.
abstract final class InactivityPolicy {
  static const Duration timeout = Duration(minutes: 30);

  /// How often the shell re-checks — same 30 s cadence as the web's poll.
  static const Duration pollInterval = Duration(seconds: 30);

  static bool expired(DateTime lastInteraction, DateTime now) =>
      !now.difference(lastInteraction).isNegative &&
      now.difference(lastInteraction) >= timeout;
}

/// The `/update-password` form's validation, mirror of `UpdatePassword.razor`
/// (GoTrue enforces its own minimum server-side; this mirrors the web's
/// upfront refusal so the two clients speak with one voice).
abstract final class UpdatePasswordRules {
  static const int minLength = 6;

  /// Returns the catalog KEY of the violation, or null when valid — the
  /// screen renders it per reader language.
  static String? validationErrorKey(String newPassword, String confirmation) {
    if (newPassword.length < minLength) return K.updatePwdErrorShort;
    if (newPassword != confirmation) return K.updatePwdErrorMismatch;
    return null;
  }
}
