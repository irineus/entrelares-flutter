import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

void main() {
  PushState resolve({
    bool platformSupported = true,
    bool permissionGranted = false,
    bool permissionDeniedForGood = false,
    bool hasSubscription = false,
  }) =>
      PushEnrollment.resolve(
        platformSupported: platformSupported,
        permissionGranted: permissionGranted,
        permissionDeniedForGood: permissionDeniedForGood,
        hasSubscription: hasSubscription,
      );

  group('PushEnrollment.resolve', () {
    test('an unsupported platform is unsupported, whatever else is true', () {
      // The web channel takes this branch. A stale `push_subscriptions` row —
      // left by the same person on their phone — must not make the web build
      // claim push is on.
      expect(
          resolve(
              platformSupported: false,
              permissionGranted: true,
              hasSubscription: true),
          PushState.unsupported);
    });

    test('granted with a device registered is on', () {
      expect(resolve(permissionGranted: true, hasSubscription: true),
          PushState.on);
    });

    test('granted with no device is off, not on', () {
      // The gap between saying yes and the row existing: a fresh grant before
      // the token comes back, or a token the server retired after an
      // uninstall. Reporting `on` here would show a switch that is on while
      // nothing can be delivered.
      expect(resolve(permissionGranted: true), PushState.off);
    });

    test('a permanent refusal is blocked, even with a row still on file', () {
      // The row survives an OS-level revocation — nothing tells the server.
      // Without the permission that token cannot produce a visible
      // notification, so `on` would be a claim the person can disprove by
      // looking at their notification shade.
      expect(
          resolve(permissionDeniedForGood: true, hasSubscription: true),
          PushState.blocked);
    });

    test('a refusal that is not permanent stays off', () {
      // Dismissing the dialog is not the same as denying it: the prompt is
      // still available, so the control keeps offering.
      expect(resolve(), PushState.off);
    });
  });

  group('PushEnrollment.shouldRegisterSilently', () {
    bool silent({
      bool platformSupported = true,
      bool permissionGranted = false,
      bool hasSubscription = false,
    }) =>
        PushEnrollment.shouldRegisterSilently(
          platformSupported: platformSupported,
          permissionGranted: permissionGranted,
          hasSubscription: hasSubscription,
        );

    test('repairs a granted permission with no registration', () {
      expect(silent(permissionGranted: true), isTrue);
    });

    test('does nothing when the device is already registered', () {
      expect(silent(permissionGranted: true, hasSubscription: true), isFalse);
    });

    test('never registers without the permission', () {
      // The one that matters: registering a token the OS will not let us
      // display would leave the switch reading `on` and the phone silent.
      expect(silent(), isFalse);
    });

    test('never registers on an unsupported platform', () {
      expect(silent(platformSupported: false, permissionGranted: true), isFalse);
    });
  });

  group('PushEnrollment.canPrompt', () {
    test('only the off state may spend the prompt', () {
      // Android shows the dialog ONCE per install. Pressing a control that
      // raises a prompt which will not appear does nothing visible, and the
      // app looks broken while behaving as designed.
      expect(PushEnrollment.canPrompt(PushState.off), isTrue);
      expect(PushEnrollment.canPrompt(PushState.blocked), isFalse);
      expect(PushEnrollment.canPrompt(PushState.on), isFalse);
      expect(PushEnrollment.canPrompt(PushState.unsupported), isFalse);
    });
  });
}
