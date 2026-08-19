/// U-13 (T-53 lote 1 port) — the gates that keep a two-language product
/// honest. Ported from `entrelares-app` `Entrelares.Tests/LocalizationTests.cs`.
///
/// The catalogs buy compile-time safety on the KEY NAME (`K.loginSubmitt`
/// does not compile) but not on the pairing: nothing in the compiler notices
/// a key added to PT-BR and forgotten in EN. That is the failure this file
/// turns red, because it is the one that reaches a user.
///
/// C# gates NOT ported yet, deliberately:
///  - `EveryDeclaredKey_HasACallSite` — the catalogs are ported AHEAD of the
///    screens (batches 2–6 consume them progressively), so the call-site scan
///    would fail on ~900 keys by design. It becomes the lote-6 close-out gate.
///  - `NoToast_CarriesALiteralString` — PORTED in lote 1 PR3 as the app
///    package's `no_literal_snack_test` (it scans app call sites, so it lives
///    beside them).
///  - Consent declarations / policy summary parity — those helpers port in
///    lote 4 with the sign-up flow.
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

void main() {
  group('catalog parity', () {
    test('English catalog covers every Portuguese key', () {
      final missing = StringsPtBr.values.keys
          .where((key) => !StringsEn.values.containsKey(key))
          .toList()
        ..sort();
      expect(missing, isEmpty,
          reason: 'Keys present in PT-BR and missing in EN: $missing');
    });

    test('Portuguese catalog covers every English key', () {
      final missing = StringsEn.values.keys
          .where((key) => !StringsPtBr.values.containsKey(key))
          .toList()
        ..sort();
      expect(missing, isEmpty,
          reason: 'Keys present in EN and missing in PT-BR: $missing');
    });

    test('every declared key has an entry in both catalogs', () {
      final orphans = K.allKeys
          .where((key) =>
              !StringsPtBr.values.containsKey(key) ||
              !StringsEn.values.containsKey(key))
          .toList()
        ..sort();
      expect(orphans, isEmpty,
          reason: 'K constants with no catalog entry: $orphans');
    });

    test('every catalog entry is a declared key', () {
      final declared = K.allKeys.toSet();
      final undeclared = StringsPtBr.values.keys
          .where((key) => !declared.contains(key))
          .toList()
        ..sort();
      expect(undeclared, isEmpty,
          reason: 'Catalog entries with no K constant: $undeclared');
    });

    // The generated allKeys list is the Dart stand-in for the C# reflection
    // scan; if the generator ever dropped it out of sync with the map, every
    // parity test above could pass over a hole.
    test('allKeys matches the catalog size exactly', () {
      expect(K.allKeys.length, StringsPtBr.values.length);
      expect(K.allKeys.toSet().length, K.allKeys.length,
          reason: 'duplicate keys in allKeys');
    });

    // The app-only supplement obeys the same gates.
    test('app supplement: parity both ways and against KApp.allKeys', () {
      expect(StringsAppEn.values.keys.toSet(),
          StringsAppPtBr.values.keys.toSet());
      expect(StringsAppPtBr.values.keys.toSet(), KApp.allKeys.toSet());
      expect(KApp.allKeys.toSet().length, KApp.allKeys.length);
    });

    // The two namespaces must never collide — the supplement exists so the
    // generated mirrors never gain a key the web catalog does not have.
    test('app supplement keys never collide with the mirrored catalog', () {
      final collisions =
          KApp.allKeys.where(StringsPtBr.values.containsKey).toList();
      expect(collisions, isEmpty);
      expect(KApp.allKeys.every((k) => k.startsWith('app.')), isTrue,
          reason: 'supplement keys carry the app. prefix by contract');
    });
  });

  group('placeholders and content contracts', () {
    Set<String> placeholders(String text) => RegExp(r'\{(\d+)\}')
        .allMatches(text)
        .map((m) => m.group(1)!)
        .toSet();

    List<String> numbersIn(String text) => RegExp(r'\d+')
        .allMatches(text.replaceAll(RegExp(r'\{\d+\}'), ' '))
        .map((m) => m.group(0)!)
        .toList();

    int countOccurrences(String text, String token) =>
        token.allMatches(text).length;

    for (final (name, pt, en) in [
      ('mirrored', StringsPtBr.values, StringsEn.values),
      ('app supplement', StringsAppPtBr.values, StringsAppEn.values),
    ]) {
      test('$name: placeholder SETS match between the two languages', () {
        final mismatches = <String>[];
        for (final entry in pt.entries) {
          final enText = en[entry.key];
          if (enText == null) continue; // covered by parity above
          if (!_setEquals(placeholders(entry.value), placeholders(enText))) {
            mismatches.add(entry.key);
          }
        }
        expect(mismatches, isEmpty,
            reason: 'Placeholder sets differ: $mismatches');
      });

      test('$name: numbers inside a text are the same in both languages', () {
        // The one legitimate exemption (from the C# gate): the day-note
        // placeholder reads "18h" in PT-BR against "6pm" in English — same
        // instant, different clock convention, no product fact stated.
        const exempt = [K.frozenNotePlaceholder];
        final mismatches = <String>[];
        for (final entry in pt.entries) {
          if (exempt.contains(entry.key)) continue;
          final enText = en[entry.key];
          if (enText == null) continue;
          final ptNums = numbersIn(entry.value);
          final enNums = numbersIn(enText);
          if (ptNums.join(',') != enNums.join(',')) {
            mismatches.add('${entry.key} (pt: $ptNums / en: $enNums)');
          }
        }
        expect(mismatches, isEmpty,
            reason: 'A number stated in one language differs in the other — '
                'these are facts, not wording: $mismatches');
      });

      test('$name: emphasis survives translation and markup is balanced', () {
        final broken = <String>[];
        for (final entry in pt.entries) {
          final enText = en[entry.key];
          if (enText == null) continue;
          if (countOccurrences(entry.value, '<strong>') !=
              countOccurrences(enText, '<strong>')) {
            broken.add('${entry.key} (count differs)');
          }
        }
        for (final catalog in [pt, en]) {
          for (final entry in catalog.entries) {
            if (countOccurrences(entry.value, '<strong>') !=
                countOccurrences(entry.value, '</strong>')) {
              broken.add('${entry.key} (unbalanced)');
            }
          }
        }
        expect(broken, isEmpty, reason: 'Emphasis problems: $broken');
      });

      test('$name: no entry is accidentally empty', () {
        // An empty PT-BR text is legitimate exactly once — the binding-version
        // notice has nothing to say in the language that IS binding.
        const expectedEmpty = [K.registerConsentBindingNotice];
        final emptyPt = pt.entries
            .where((e) => e.value.trim().isEmpty)
            .map((e) => e.key)
            .where((k) => !expectedEmpty.contains(k))
            .toList();
        expect(emptyPt, isEmpty, reason: 'Empty PT-BR entries: $emptyPt');
        final emptyEn = en.entries
            .where((e) => e.value.trim().isEmpty)
            .map((e) => e.key)
            .toList();
        expect(emptyEn, isEmpty, reason: 'Empty EN entries: $emptyEn');
      });
    }

    test('an English session is TOLD which consent version binds', () {
      final notice = StringsEn.values[K.registerConsentBindingNotice]!;
      expect(notice.trim(), isNotEmpty);
      expect(notice.toLowerCase(), contains('portuguese'));
    });
  });

  group('lookup and format', () {
    final pt = Localization(AppLanguage.ptBr);
    final en = Localization(AppLanguage.en);

    test('indexer reads the current language, both catalogs', () {
      expect(pt[K.loginSubmit], 'Entrar');
      expect(en[K.loginSubmit], isNot('Entrar'));
      expect(pt[KApp.sheetSave], 'Salvar');
      expect(en[KApp.sheetSave], 'Save');
    });

    test('format substitutes positional placeholders in any order', () {
      expect(pt.format(K.relInDays, [3]), 'em 3 dias');
      expect(pt.format(K.relDaysAgo, [2]), 'há 2 dias');
    });

    test('an unknown key falls back to PT-BR text, then to the raw key', () {
      expect(pt['no.such.key'], 'no.such.key');
      expect(en['no.such.key'], 'no.such.key');
    });

    test('pick follows the language, PT-BR default', () {
      expect(pt.pick('um', 'one'), 'um');
      expect(en.pick('um', 'one'), 'one');
    });
  });

  group('language resolution', () {
    // Auto-detection: every Portuguese tag is PT-BR, everything else EN.
    for (final tag in ['pt-BR', 'pt', 'pt-PT', 'PT-br']) {
      test('device "$tag" resolves to PT-BR', () {
        expect(LanguageResolver.resolve(null, null, tag), AppLanguage.ptBr);
      });
    }
    for (final tag in ['en-US', 'en', 'es-AR', 'fr', 'de-DE']) {
      test('device "$tag" resolves to English', () {
        expect(LanguageResolver.resolve(null, null, tag), AppLanguage.en);
      });
    }
    // Nothing detectable is NOT the same as "not Portuguese".
    for (final tag in [null, '', '   ']) {
      test('nothing detectable ("$tag") falls back to PT-BR', () {
        expect(LanguageResolver.resolve(null, null, tag), AppLanguage.ptBr);
      });
    }

    test('stored override beats device detection, both ways', () {
      expect(
          LanguageResolver.resolve('pt-BR', null, 'en-US'), AppLanguage.ptBr);
      expect(LanguageResolver.resolve('en', null, 'pt-BR'), AppLanguage.en);
    });

    test('stored override beats the profile too', () {
      expect(
          LanguageResolver.resolve('en', 'pt-BR', 'pt-BR'), AppLanguage.en);
    });

    test('profile beats device detection', () {
      expect(LanguageResolver.resolve(null, 'en', 'pt-BR'), AppLanguage.en);
    });

    test('a pre-U-13 profile (null language) is silent, not a vote', () {
      expect(LanguageResolver.resolve(null, null, 'en-GB'), AppLanguage.en);
    });
  });

  group('adopting the profile language (cross-device)', () {
    test('adopt when the profile differs and the device never chose', () {
      expect(
          Localization.shouldAdopt('en', AppLanguage.ptBr, null), isTrue);
    });

    // THE LOOP GUARD: once the code has been persisted, the very next boot
    // must decide NOT to adopt — else the app reboots endlessly for anyone
    // whose profile disagrees with their device.
    test('do not adopt on the boot that follows an adoption', () {
      expect(Localization.shouldAdopt('en', AppLanguage.en, 'en'), isFalse);
      expect(Localization.shouldAdopt('en', AppLanguage.en, null), isFalse);
    });

    test('an explicit local pick is not overridden by the server copy', () {
      expect(
          Localization.shouldAdopt('en', AppLanguage.ptBr, 'pt-BR'), isFalse);
    });

    test('a silent profile has nothing to say', () {
      expect(Localization.shouldAdopt(null, AppLanguage.ptBr, null), isFalse);
      expect(Localization.shouldAdopt('  ', AppLanguage.en, null), isFalse);
    });
  });

  group('recording the DETECTED language (what the senders read)', () {
    test('record when the profile has no detection yet', () {
      expect(
          Localization.shouldRecordDetected(null, AppLanguage.en), isTrue);
      expect(
          Localization.shouldRecordDetected('  ', AppLanguage.ptBr), isTrue);
    });

    test('record when the detection is stale', () {
      expect(
          Localization.shouldRecordDetected('pt-BR', AppLanguage.en), isTrue);
    });

    // Runs on every session boot, so agreement has to be free.
    test('do not record when the profile already agrees', () {
      expect(
          Localization.shouldRecordDetected('en', AppLanguage.en), isFalse);
      expect(Localization.shouldRecordDetected('pt-BR', AppLanguage.ptBr),
          isFalse);
    });
  });

  group('codes', () {
    // A storage contract: localStorage/SharedPreferences, profiles.language
    // (behind a CHECK constraint) and the Edge Functions all read these.
    test('codes are the ones persisted', () {
      expect(AppLanguage.ptBr.code, 'pt-BR');
      expect(AppLanguage.en.code, 'en');
      expect(LanguageResolver.storageKey, 'app-language');
    });

    test('tryParse tells absent apart from chosen', () {
      expect(AppLanguage.tryParse(null), isNull);
      expect(AppLanguage.tryParse('  '), isNull);
      expect(AppLanguage.tryParse('pt-BR'), AppLanguage.ptBr);
      expect(AppLanguage.tryParse('en-US'), AppLanguage.en);
    });
  });
}

bool _setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);
