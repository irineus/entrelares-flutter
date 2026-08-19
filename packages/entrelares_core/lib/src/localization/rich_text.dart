/// U-13 — the catalog's only markup. A handful of entries emphasize one word
/// or number inline (`Total de trocas … <strong>{0}</strong>`), which the web
/// renders through `LocalizationService.Rich` as a `MarkupString`.
///
/// Flutter has no HTML renderer, and pulling one in for ONE tag would be
/// absurd — so the catalog is parsed into segments here and the app turns
/// them into `TextSpan`s. `<strong>` is the ONLY tag in either catalog (126
/// occurrences, verified 19/08/2026) and there are no HTML entities, so this
/// stays a mirror rather than becoming a parser.
library;

/// A run of catalog text and whether it is emphasized.
class RichSegment {
  final String text;
  final bool bold;

  const RichSegment(this.text, {this.bold = false});

  @override
  bool operator ==(Object other) =>
      other is RichSegment && other.text == text && other.bold == bold;

  @override
  int get hashCode => Object.hash(text, bold);

  @override
  String toString() => bold ? '**$text**' : text;
}

final _strongTag = RegExp(r'</?strong>', caseSensitive: false);

/// Splits catalog text into bold/plain runs. Unbalanced or unknown markup
/// degrades to plain text — a screen showing an unemphasized sentence is a
/// far better failure than one showing `<strong>` to a user.
List<RichSegment> parseRichText(String value) {
  if (!value.contains('<')) return [RichSegment(value)];

  final segments = <RichSegment>[];
  var bold = false;
  var index = 0;

  for (final match in _strongTag.allMatches(value)) {
    if (match.start > index) {
      segments.add(RichSegment(value.substring(index, match.start), bold: bold));
    }
    bold = !match.group(0)!.startsWith('</');
    index = match.end;
  }

  if (index < value.length) {
    segments.add(RichSegment(value.substring(index), bold: bold));
  }
  return segments.isEmpty ? [const RichSegment('')] : segments;
}

/// The same text with the markup removed — for places that take a plain
/// string (semantics labels, the PDF, a test matcher).
String stripRichText(String value) =>
    value.contains('<') ? value.replaceAll(_strongTag, '') : value;
