/// U-24 — the e-mails cannot reach `date_formats.dart`.
///
/// `supabase/functions/_shared/i18n.ts` carries `formatDateIn`, the server-side
/// mirror of the client's display format, with its own hardcoded month
/// abbreviations. It has to be its own copy: the Edge Functions are Deno and
/// cannot call into Dart.
///
/// Why this matters more than it looks. The SAME day reaches one caregiver as
/// an e-mail and the other on screen. If the two spell it differently — one
/// `05 Aug 2026`, the other `05 August 2026`, or worse one of them slipping
/// back to `08/05` — the family is reading two descriptions of one day, and the
/// app's entire job is being unambiguous about which day is whose.
///
/// The mirror also cannot use `Intl`/`toLocaleDateString`, because that would
/// bind the output to whatever ICU data the Deno runtime ships and a platform
/// upgrade could restyle every e-mail we send with no commit to point at. The
/// price of hardcoding is drift, and this suite is what makes drift red.
///
/// Ported from `entrelares-app` `Entrelares.Tests/EmailDateFormatMirrorTests.cs`
/// (T-56, 24/08/2026).
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

import 'repo_files.dart';

/// The `EN_MONTHS` array literal, in order.
List<String> _mirrorMonths() {
  final block = RegExp(r'EN_MONTHS\s*=\s*\[(.*?)\];', dotAll: true)
      .firstMatch(i18nSource());
  expect(block, isNotNull,
      reason: 'EN_MONTHS literal not found — did the mirror move or change '
          'shape?');

  return RegExp(r'"([^"]+)"')
      .allMatches(block!.group(1)!)
      .map((m) => m.group(1)!)
      .toList();
}

void main() {
  final en = Localization(AppLanguage.en);
  final ptBr = Localization(AppLanguage.ptBr);

  // The scanner must actually match something. Without this, a renamed constant
  // would make every assertion below pass over an empty list — the failure mode
  // this whole suite exists to prevent.
  test('the mirror is actually being read', () {
    expect(_mirrorMonths(), hasLength(12));
  });

  test('every month abbreviation matches what the app renders', () {
    final mirror = _mirrorMonths();

    for (var month = 1; month <= 12; month++) {
      // The client's own rendering is the source of truth; the mirror must
      // agree with it token for token.
      final appRendered = en.formatDate(DateTime(2026, month, 5));
      final expected = appRendered.split(' ')[1];

      expect(mirror[month - 1], expected,
          reason: "Month $month: the e-mail mirror says '${mirror[month - 1]}' "
              "while the app renders '$expected' (from '$appRendered').");
    }
  });

  // The shape, not just the tokens: an e-mail saying `Aug 05, 2026` while the
  // screen says `05 Aug 2026` would pass the check above and still be two
  // spellings of one day.
  test('the mirror assembles the same shape as the app', () {
    final body = RegExp(
            r'export function formatDateIn\([^)]*\)[^{]*\{(.*?)\n\}',
            dotAll: true)
        .firstMatch(i18nSource());
    expect(body, isNotNull,
        reason: 'formatDateIn not found — did the mirror change shape?');

    expect(body!.group(1)!, contains(r'${day} ${EN_MONTHS[Number(month) - 1]'));
    expect(body.group(1)!, contains(r'${day}/${month}/${year}'));

    // And the app agrees on both sides of that branch.
    expect(en.formatDate(DateTime(2026, 8, 5)), '05 Aug 2026');
    expect(ptBr.formatDate(DateTime(2026, 8, 5)), '05/08/2026');
  });
}
