// U-28 QA — the calendar has to FIT on a phone.
//
// The owner's second round found the grid scrolling: the month bar, the legend
// and the chrome above and below it had eaten the room a six-week month needs.
// Scrolling a calendar is not a small annoyance — the whole point of the screen
// is seeing the month at once, and a month you have to scroll is a list.
//
// This measures the real thing: pump the screen at a phone's size and compare
// what the grid needs against what the viewport gives it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'calendar_slice_test.dart' as cal;

void main() {
  // 360x740 is the small end of what the product actually meets; the owner's
  // own device reports ~339x755 logical pixels.
  for (final size in [const Size(360, 740), const Size(340, 700)]) {
    testWidgets('a six-week month fits at ${size.width}x${size.height}',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(cal.app(cal.FakeCustodyDataSource(
        members: [cal.ana, cal.bruno],
        days: const [],
      )));
      await tester.pumpAndSettle();

      // `.first`: the PageView keeps neighbouring months alive, so more than
      // one grid is in the tree at any time.
      final gridFinder = find.byType(GridView).first;
      final grid = tester.getSize(gridFinder);
      // The grid's OWN viewport — `find.byType(Viewport).first` picks the
      // legend's horizontal one, which is 30 dp tall and would make this pass
      // or fail for reasons that have nothing to do with the month.
      final viewport = tester.getSize(find
          .ancestor(of: gridFinder, matching: find.byType(Viewport))
          .first);

      // The month on screen may be a five-row one; the worst case is six, and
      // that is the case the layout has to survive every year.
      final rows = (grid.height / (_cellHeight + _spacing)).round();
      final sixWeeks = grid.height / rows * 6;
      // The weekday initials and the list padding ride above the grid.
      const chrome = 40.0;

      expect(sixWeeks + chrome, lessThanOrEqualTo(viewport.height),
          reason: 'a six-week month needs ${sixWeeks + chrome} and the '
              'viewport gives ${viewport.height} — the calendar would scroll, '
              'which is the one thing this screen must not do');
    });
  }
}

/// Mirrors `_dayCellHeight` and the grid spacing in `calendar_screen.dart`.
/// Duplicated on purpose: the test asserts against the numbers a reader can
/// see, so a change to either shows up here as a failure to think about.
const double _cellHeight = 54;
const double _spacing = 4;
