/// F-09 — what the push control says, and when the app may ask.
///
/// The rules live here rather than in the service because the service is
/// unreachable from a test: `firebase_messaging` is a platform channel and
/// there is no Android under `flutter test`. What is decidable without a
/// device — which of four states the person is in, whether the app may prompt,
/// whether it may register silently — is decidable from four booleans, so it
/// lives in the pure package with a suite over it.
library;

/// The four states a person can be in, and they are genuinely four.
///
/// Collapsing [blocked] into [off] is the mistake worth naming: a switch that
/// offers to turn push on, when the OS has already recorded a refusal, does
/// nothing at all when pressed — Android shows the permission dialog once and
/// never again. The person presses it, nothing happens, and the app looks
/// broken while behaving exactly as designed.
enum PushState {
  /// No push transport on this build. The web channel is here (Flutter Web
  /// push is a separate, later decision — the PWA's service worker is a
  /// tombstone and cannot gain a handler), and so is any device without the
  /// services the transport needs.
  unsupported,

  /// Supported, and the person has not enrolled. The control offers to.
  off,

  /// A device is registered and the OS permits notifications.
  on,

  /// The OS refused, permanently as far as the app is concerned. The control
  /// must send the person to system settings, never re-offer a prompt that
  /// will not appear.
  blocked,
}

abstract final class PushEnrollment {
  static PushState resolve({
    required bool platformSupported,
    required bool permissionGranted,
    required bool permissionDeniedForGood,
    required bool hasSubscription,
  }) {
    if (!platformSupported) return PushState.unsupported;
    if (permissionGranted) {
      // Granted but no row: the registration has not happened yet, or the
      // token was retired server-side after an uninstall. Either way the
      // person's ANSWER was yes, so the honest state is "not on yet" and the
      // app repairs it silently — see [shouldRegisterSilently].
      return hasSubscription ? PushState.on : PushState.off;
    }
    // A permanent refusal outranks everything below it: without the OS
    // permission a registered token can never produce a visible notification,
    // so reporting `on` because a row exists would be a lie the person can see.
    return permissionDeniedForGood ? PushState.blocked : PushState.off;
  }

  /// Whether the app may register the device WITHOUT asking anything.
  ///
  /// True only when the person has already granted the permission. That covers
  /// the two cases where a prompt would be an insult: Android below 33, where
  /// the grant is implicit and there is no dialog at all, and a returning user
  /// who said yes on this device before a reinstall or a token rotation.
  static bool shouldRegisterSilently({
    required bool platformSupported,
    required bool permissionGranted,
    required bool hasSubscription,
  }) =>
      platformSupported && permissionGranted && !hasSubscription;

  /// Whether pressing the control should raise the OS permission dialog.
  ///
  /// The prompt is a one-shot resource: Android shows it once per install and
  /// a refusal is only reversible in Settings. So it may only be spent on a
  /// gesture — never on app load — and never when it would not appear.
  static bool canPrompt(PushState state) => state == PushState.off;
}
