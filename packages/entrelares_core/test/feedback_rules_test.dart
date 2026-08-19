/// UX-feedback mirror (T-53 lote 1 port) — ported from
/// `Entrelares.Tests/ToastServiceTests.cs` (`ComputeDismissDelay` cases; the
/// tap-to-dismiss behaviour is a widget concern and is tested in the app
/// package).
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

void main() {
  group('snackDismissDelayMs', () {
    for (final (length, expected) in [
      (0, 3000), // empty → baseline
      (40, 3000), // short message → baseline
      (60, 3700), // 20 chars over → +35ms each
      (120, 5800), // long bulk summary → proportionally longer
      (1000, 8000), // absurd length → capped at 8s
    ]) {
      test('length $length → ${expected}ms', () {
        expect(snackDismissDelayMs(length), expected);
      });
    }
  });
}
