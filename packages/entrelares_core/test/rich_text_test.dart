/// The catalog's only markup (`<strong>`), parsed into segments so the app
/// can render it as spans instead of showing tags to a user.
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

void main() {
  test('plain text is one plain segment', () {
    expect(parseRichText('Programado:'), [const RichSegment('Programado:')]);
  });

  test('an inline emphasis splits into three runs', () {
    expect(
      parseRichText('Total: <strong>7</strong> trocas'),
      [
        const RichSegment('Total: '),
        const RichSegment('7', bold: true),
        const RichSegment(' trocas'),
      ],
    );
  });

  test('emphasis at the very start and end keeps no empty runs', () {
    expect(parseRichText('<strong>Assinatura ativa</strong>'),
        [const RichSegment('Assinatura ativa', bold: true)]);
  });

  test('more than one emphasis in a sentence', () {
    final segments =
        parseRichText('quem estava <strong>planejado</strong> e quem ficou '
            '<strong>de fato</strong> responsável');
    expect(segments.where((s) => s.bold).map((s) => s.text),
        ['planejado', 'de fato']);
  });

  test('an unclosed tag degrades to text, never to a visible tag', () {
    final segments = parseRichText('Total <strong>7 trocas');
    expect(segments.map((s) => s.text).join(), 'Total 7 trocas');
  });

  test('stripRichText leaves the sentence and drops the markup', () {
    expect(stripRichText('Total: <strong>7</strong>'), 'Total: 7');
    expect(stripRichText('sem markup'), 'sem markup');
  });

  test('every catalog entry survives a round trip through the parser', () {
    for (final catalog in [StringsPtBr.values, StringsEn.values]) {
      for (final entry in catalog.entries) {
        final joined =
            parseRichText(entry.value).map((s) => s.text).join();
        expect(joined, stripRichText(entry.value), reason: entry.key);
        expect(joined, isNot(contains('<strong>')), reason: entry.key);
      }
    }
  });
}
