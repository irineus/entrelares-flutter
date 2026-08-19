/// Mirror of `entrelares-app` `Entrelares.Tests/FreemiumGatesTests.cs` — same
/// cases, same expected verdicts. The DATABASE enforces the true limits; these
/// pin the UX mirror so the calendar paging, the wizard clamp and the
/// caregiver-cap hint stay faithful to it. Plus the [addMonthsClamped] cases
/// the Dart port needs (C#'s `AddMonths` clamps natively; Dart's constructor
/// overflows).
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

void main() {
  group('addMonthsClamped', () {
    test('plain addition inside the year', () {
      expect(addMonthsClamped(DateTime(2026, 3, 10), 2), DateTime(2026, 5, 10));
    });
    test('crosses the year boundary', () {
      expect(addMonthsClamped(DateTime(2026, 11, 5), 3), DateTime(2027, 2, 5));
    });
    test('clamps to the shorter target month (Aug 31 + 1 → Sep 30)', () {
      expect(addMonthsClamped(DateTime(2026, 8, 31), 1), DateTime(2026, 9, 30));
    });
    test('clamps into February', () {
      expect(addMonthsClamped(DateTime(2026, 8, 31), 6), DateTime(2027, 2, 28));
    });
    test('respects leap years', () {
      expect(addMonthsClamped(DateTime(2027, 8, 31), 6), DateTime(2028, 2, 29));
    });
    test('negative months clamp the same way (F-40 retro floor)', () {
      expect(addMonthsClamped(DateTime(2026, 8, 31), -6), DateTime(2026, 2, 28));
    });
    test('negative months across the year boundary', () {
      expect(addMonthsClamped(DateTime(2026, 2, 15), -3), DateTime(2025, 11, 15));
    });
  });

  group('planningHorizonMonths (F-39)', () {
    test('premium uses the premium horizon', () {
      expect(
          planningHorizonMonths(
              isPremium: true, freeMonths: 6, premiumMonths: 24),
          24);
    });
    test('free uses the free horizon', () {
      expect(
          planningHorizonMonths(
              isPremium: false, freeMonths: 6, premiumMonths: 24),
          6);
    });
  });

  group('canPageToMonth (F-39, month granularity)', () {
    final horizon = DateTime(2026, 12, 31);
    test('target before the horizon: allowed', () {
      expect(canPageToMonth(DateTime(2026, 8, 1), horizon), isTrue);
    });
    test('same month as the horizon: allowed (day is irrelevant)', () {
      // The 1st of the month is allowed even though it is < the horizon's day.
      expect(canPageToMonth(DateTime(2026, 12, 1), horizon), isTrue);
    });
    test('month past the horizon: blocked', () {
      expect(canPageToMonth(DateTime(2027, 1, 1), horizon), isFalse);
    });
    test('crossing the year boundary compares by absolute month', () {
      // Dec 2026 → Jan 2027 must NOT wrap: 2027-01 > 2026-12 despite 1 < 12.
      final h = DateTime(2026, 12, 15);
      expect(canPageToMonth(DateTime(2026, 12, 20), h), isTrue);
      expect(canPageToMonth(DateTime(2027, 1, 5), h), isFalse);
    });
  });

  group('isStartBeyondHorizon (F-39)', () {
    test('null horizon: never beyond', () {
      expect(isStartBeyondHorizon(DateTime(2099, 1, 1), null), isFalse);
    });
    test('start after the max: beyond', () {
      expect(
          isStartBeyondHorizon(DateTime(2027, 1, 1), DateTime(2026, 12, 31)),
          isTrue);
    });
    test('start on the max day itself: not beyond (strict > comparison)', () {
      expect(
          isStartBeyondHorizon(DateTime(2026, 12, 31), DateTime(2026, 12, 31)),
          isFalse);
    });
  });

  group('clampScheduleEnd (F-39)', () {
    test('null horizon passes through', () {
      final end = DateTime(2030, 1, 1);
      final result = clampScheduleEnd(end, null);
      expect(result.end, end);
      expect(result.clamped, isFalse);
    });
    test('end within the horizon: unchanged', () {
      final result =
          clampScheduleEnd(DateTime(2026, 10, 1), DateTime(2026, 12, 31));
      expect(result.end, DateTime(2026, 10, 1));
      expect(result.clamped, isFalse);
    });
    test('end beyond the horizon: clamped to the max', () {
      final max = DateTime(2026, 12, 31);
      final result = clampScheduleEnd(DateTime(2027, 6, 1), max);
      expect(result.end, max);
      expect(result.clamped, isTrue);
    });
    test('end exactly at the horizon: not clamped (no upsell note)', () {
      final max = DateTime(2026, 12, 31);
      final result = clampScheduleEnd(max, max);
      expect(result.end, max);
      expect(result.clamped, isFalse);
    });
  });

  group('seatsTaken (F-37)', () {
    test('sums active members and pending invites', () {
      expect(seatsTaken(activeMembers: 2, pendingInvitations: 1), 3);
    });
    test('no invites: member count alone', () {
      expect(seatsTaken(activeMembers: 2, pendingInvitations: 0), 2);
    });
  });

  group('atFreeCaregiverCap (F-37)', () {
    test('premium is never capped here', () {
      expect(atFreeCaregiverCap(isPremium: true, seatsTaken: 9, freeLimit: 2),
          isFalse);
    });
    test('free below the limit: not capped', () {
      expect(atFreeCaregiverCap(isPremium: false, seatsTaken: 1, freeLimit: 2),
          isFalse);
    });
    test('free at the limit: capped (>= blocks the NEXT addition)', () {
      expect(atFreeCaregiverCap(isPremium: false, seatsTaken: 2, freeLimit: 2),
          isTrue);
    });
    test('free above the limit: capped', () {
      expect(atFreeCaregiverCap(isPremium: false, seatsTaken: 3, freeLimit: 2),
          isTrue);
    });
  });
}
