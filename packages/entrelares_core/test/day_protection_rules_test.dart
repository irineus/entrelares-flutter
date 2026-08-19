/// The day-protection mirror (F-12/F-13/F-14 + F-40). No C# unit suite exists
/// for these — in the web they are inline properties of `Home.razor` and the
/// enforcement tests live in `Entrelares.IntegrationTests` against the
/// `enforce_day_protection` trigger. These tests pin the CLIENT mirror to the
/// trigger's documented rules (migration `20260724180000_f40`), especially the
/// tier-aware retroactive floor, whose month arithmetic must clamp exactly
/// like Postgres.
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

final _today = DateTime(2026, 8, 19);

void main() {
  group('isAdminBypass (F-14)', () {
    test('requires the mode ON and the profile really being an admin', () {
      expect(isAdminBypass(adminModeActive: true, isAdmin: true), isTrue);
      expect(isAdminBypass(adminModeActive: true, isAdmin: false), isFalse);
      expect(isAdminBypass(adminModeActive: false, isAdmin: true), isFalse);
      expect(isAdminBypass(adminModeActive: false, isAdmin: false), isFalse);
    });
  });

  group('isDayInPast (F-13, date-only semantics)', () {
    test('yesterday is past', () {
      expect(isDayInPast(DateTime(2026, 8, 18), _today), isTrue);
    });
    test('today is not past — whatever the time components say', () {
      expect(isDayInPast(DateTime(2026, 8, 19, 23, 59), _today), isFalse);
    });
    test('tomorrow is not past', () {
      expect(isDayInPast(DateTime(2026, 8, 20), _today), isFalse);
    });
  });

  group('isDayFrozen (F-12)', () {
    final frozen = [DateTime(2026, 8, 21), DateTime(2026, 8, 25, 14, 30)];
    test('a date in the pending set is frozen (time ignored)', () {
      expect(isDayFrozen(DateTime(2026, 8, 25), frozen), isTrue);
    });
    test('a date outside the set is not', () {
      expect(isDayFrozen(DateTime(2026, 8, 22), frozen), isFalse);
    });
    test('empty set freezes nothing', () {
      expect(isDayFrozen(DateTime(2026, 8, 21), const []), isFalse);
    });
  });

  group('isApprovedSwapDay (F-12)', () {
    test('actual set and different from scheduled', () {
      expect(
          isApprovedSwapDay(
              const DayAssignment(scheduledParentId: 1, actualParentId: 2)),
          isTrue);
    });
    test('actual equal to scheduled is not a swap', () {
      expect(
          isApprovedSwapDay(
              const DayAssignment(scheduledParentId: 1, actualParentId: 1)),
          isFalse);
    });
    test('no actual / no row', () {
      expect(isApprovedSwapDay(const DayAssignment(scheduledParentId: 1)),
          isFalse);
      expect(isApprovedSwapDay(null), isFalse);
    });
  });

  group('isClearDayBlocked / isSaveDayBlocked', () {
    test('clearing an assigned day is admin-only across the board', () {
      expect(isClearDayBlocked(adminBypass: false), isTrue);
      expect(isClearDayBlocked(adminBypass: true), isFalse);
    });
    test('save blocked on past or frozen days without the bypass', () {
      expect(
          isSaveDayBlocked(adminBypass: false, isPast: true, isFrozen: false),
          isTrue);
      expect(
          isSaveDayBlocked(adminBypass: false, isPast: false, isFrozen: true),
          isTrue);
      expect(
          isSaveDayBlocked(adminBypass: false, isPast: false, isFrozen: false),
          isFalse);
    });
    test('the bypass relaxes both guards', () {
      expect(isSaveDayBlocked(adminBypass: true, isPast: true, isFrozen: true),
          isFalse);
    });
  });

  group('F-40: tier-aware retroactive reach', () {
    // Trigger rule: free admin (Gestor) reaches back override_free_days DAYS;
    // premium (Administrador) reaches override_premium_months MONTHS — the
    // hard cap for everyone. Blocked when the_date < floor.
    DateTime floor({required bool isPremium}) => adminRetroactiveFloor(
          today: _today,
          isPremium: isPremium,
          overrideFreeDays: 7,
          overridePremiumMonths: 6,
        );

    test('free floor: today − 7 days', () {
      expect(floor(isPremium: false), DateTime(2026, 8, 12));
    });
    test('premium floor: today − 6 months', () {
      expect(floor(isPremium: true), DateTime(2026, 2, 19));
    });
    test('premium floor clamps the day like Postgres (Aug 31 − 6 → Feb 28)',
        () {
      expect(
          adminRetroactiveFloor(
            today: DateTime(2026, 8, 31),
            isPremium: true,
            overrideFreeDays: 7,
            overridePremiumMonths: 6,
          ),
          DateTime(2026, 2, 28));
    });

    bool reaches(DateTime date, {required bool isPremium}) =>
        isWithinAdminRetroactiveReach(
          date: date,
          today: _today,
          isPremium: isPremium,
          overrideFreeDays: 7,
          overridePremiumMonths: 6,
        );

    test('the floor itself is still editable (trigger blocks strictly below)',
        () {
      expect(reaches(DateTime(2026, 8, 12), isPremium: false), isTrue);
      expect(reaches(DateTime(2026, 2, 19), isPremium: true), isTrue);
    });
    test('one day below the floor is out of reach', () {
      expect(reaches(DateTime(2026, 8, 11), isPremium: false), isFalse);
      expect(reaches(DateTime(2026, 2, 18), isPremium: true), isFalse);
    });
    test('a recent past day is within both tiers', () {
      expect(reaches(DateTime(2026, 8, 15), isPremium: false), isTrue);
      expect(reaches(DateTime(2026, 8, 15), isPremium: true), isTrue);
    });
    test('beyond the free window but inside premium reach', () {
      expect(reaches(DateTime(2026, 6, 1), isPremium: false), isFalse);
      expect(reaches(DateTime(2026, 6, 1), isPremium: true), isTrue);
    });
  });
}
