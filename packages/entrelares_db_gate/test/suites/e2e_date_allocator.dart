import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

/// The allocator that hands day-cell tests their dates is PURE, and it has
/// already taken the gate down twice near a month end — first by clamping an
/// overflow onto a PAST day (immutable per V008, plus a UNIQUE violation on
/// every repeat), then by handing out the LAST grid row, which the fixed
/// selection action bar covers, so the press landed on the bar.
///
/// Both are invisible for most of the month, which is exactly why they are
/// pinned here instead of being rediscovered during a promotion.
///
/// The suite touches no database: it builds its OWN [GateFixture] instances and
/// only calls the allocator on them, which is why it is the one suite that would
/// pass with no service key at all.
///
/// Port of `db-gate/Entrelares.IntegrationTests/E2EDateAllocatorTests.cs`.
void e2eDateAllocatorTests(GateFixture _) {
  // Mirror of the calendar's own layout, Sunday-first. Dart's `DateTime.weekday`
  // is 1=Monday…7=Sunday, so Sunday folds back to 0.
  int blanks(DateTime d) => DateTime(d.year, d.month, 1).weekday % 7;
  int row(DateTime d) => (blanks(d) + d.day - 1) ~/ 7;
  int daysInMonth(DateTime d) => DateTime(d.year, d.month + 1, 0).day;
  int lastRow(DateTime d) => (blanks(d) + daysInMonth(d) - 1) ~/ 7;

  group('E2EDateAllocatorTests', () {
    for (final count in [1, 2, 3]) {
      test('a block of $count stays in one month and off the last grid row',
          () async {
        final fx = GateFixture();
        var previous = DateTime(1900);

        // Enough blocks to walk more than a year of month shapes, so the 28-day
        // February and the 31-day month that starts on a Saturday — the shape
        // that failed on 24/08/2026 — are both covered.
        for (var i = 0; i < 200; i++) {
          final block = fx.nextVisibleDays(count);
          expect(block, hasLength(count));

          for (final d in block) {
            expect(d.month, block.first.month);
            expect(row(d), lessThan(lastRow(d)),
                reason: '${isoDate(d)} is on the last grid row '
                    '(row ${row(d)} of ${lastRow(d)})');
          }

          // Only ever FORWARD: the UNIQUE (family_id, schedule_date) constraint
          // is what the whole allocator exists to respect.
          expect(block.first.isAfter(previous), isTrue,
              reason: '${isoDate(block.first)} does not follow '
                  '${isoDate(previous)}');
          previous = block.last;
        }
      });
    }

    test('a block no month can hold is refused, not spun on', () async {
      // The tightest month leaves room for 21 days above the last row; beyond
      // that, no start date satisfies the rule and the search would never end.
      final fx = GateFixture();
      expect(() => fx.nextVisibleDays(22), throwsA(isA<RangeError>()));
      expect(() => fx.nextVisibleDays(0), throwsA(isA<RangeError>()));
    });
  });
}
