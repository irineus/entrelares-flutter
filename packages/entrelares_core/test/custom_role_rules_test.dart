/// Mirror of `entrelares-app` `Entrelares.Tests/CustomRoleRulesTests.cs` — same
/// cases, same verdicts, same PT-BR messages.
///
/// The messages are asserted LITERALLY on purpose: they must match the RPCs'
/// own wording byte-for-byte, so a rule that trips client-side and one that
/// trips server-side read identically to the user. Localising them here would
/// break that pairing silently.
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

void main() {
  group('validate — label', () {
    test('a normal label is accepted', () {
      expect(CustomRoleRules.validate('Vovó Coruja', '🦉'), isNull);
    });

    test('null, empty and blank all refuse with the same sentence', () {
      for (final label in [null, '', '   ']) {
        expect(CustomRoleRules.validate(label, null),
            'Informe o nome do papel.');
      }
    });

    test('exactly the maximum length is allowed', () {
      final label = 'x' * CustomRoleRules.maxLabelLength;
      expect(CustomRoleRules.validate(label, null), isNull);
    });

    test('one character past the maximum is refused', () {
      final label = 'x' * (CustomRoleRules.maxLabelLength + 1);
      expect(CustomRoleRules.validate(label, null),
          'O nome do papel pode ter no máximo 30 caracteres.');
    });

    test('the label is trimmed BEFORE the length check', () {
      final label = '  ${'x' * CustomRoleRules.maxLabelLength}  ';
      expect(CustomRoleRules.validate(label, null), isNull);
    });
  });

  group('validate — emoji', () {
    test('absent, empty and single emoji are all fine', () {
      expect(CustomRoleRules.validate('Papel', null), isNull);
      expect(CustomRoleRules.validate('Papel', ''), isNull);
      expect(CustomRoleRules.validate('Papel', '👵'), isNull);
    });

    test('a multi-codepoint ZWJ emoji fits the bound', () {
      expect(CustomRoleRules.validate('Papel', '👨‍👩‍👧‍👦'), isNull);
    });

    test('a long string in the emoji field is refused', () {
      final tooLong = 'x' * (CustomRoleRules.maxEmojiLength + 1);
      expect(CustomRoleRules.validate('Papel', tooLong), 'Emoji inválido.');
    });
  });

  group('emoji palette', () {
    test('is non-empty and has no duplicates', () {
      expect(CustomRoleRules.emojiPalette, isNotEmpty);
      expect(CustomRoleRules.emojiPalette.toSet(),
          hasLength(CustomRoleRules.emojiPalette.length));
    });

    test('every palette entry passes validate — a picker option the server '
        'refuses would be a trap', () {
      for (final emoji in CustomRoleRules.emojiPalette) {
        expect(CustomRoleRules.validate('Papel', emoji), isNull,
            reason: 'palette entry "$emoji" would be refused');
      }
    });
  });

  group('displayLabel', () {
    test('prefixes the emoji when there is one', () {
      expect(CustomRoleRules.displayLabel('Avó', '👵'), '👵 Avó');
    });

    test('renders the bare label when there is none', () {
      expect(CustomRoleRules.displayLabel('Avó', null), 'Avó');
      expect(CustomRoleRules.displayLabel('Avó', ''), 'Avó');
      expect(CustomRoleRules.displayLabel('Avó', '   '), 'Avó');
    });

    test('composes with the catalog for built-ins and customs alike', () {
      expect(
        CustomRoleRules.displayLabel(RoleCatalog.translate('nanny'), '🍼'),
        '🍼 Babá',
      );
      expect(
        CustomRoleRules.displayLabel(RoleCatalog.translate('Vovó Coruja'), '🦉'),
        '🦉 Vovó Coruja',
      );
    });
  });
}
