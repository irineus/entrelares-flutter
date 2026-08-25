/// U-13 — the Edge Functions cannot reach `RoleCatalog`.
///
/// The `roles` table stores only `label_pt`, and the English labels live in the
/// client catalog (`lib/src/role_catalog.dart`). The invitation e-mail is the
/// one SERVER-side surface that prints a role name, so
/// `supabase/functions/_shared/i18n.ts` carries a mirror of the map.
///
/// A mirror nobody checks is a mirror that rots: someone adds a role to the
/// catalog, the e-mail keeps sending the Portuguese label, and nothing fails —
/// the invitee just reads "Madrinha" in an otherwise English message. This
/// suite reads the TypeScript file and makes that a red gate instead.
///
/// Direction matters: the CATALOG is the source, the TS file is the copy. Every
/// built-in role must appear in the mirror with the same English label, and the
/// mirror must contain nothing the catalog does not define — an extra entry is a
/// label the app never renders, which is how a wrong translation survives review.
///
/// Ported from `entrelares-app` `Entrelares.Tests/RoleCatalogMirrorTests.cs`
/// (T-56, 24/08/2026). Same three assertions, same argument.
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

import 'repo_files.dart';

/// The `ROLE_LABEL_EN` object literal, parsed into a map.
Map<String, String> _mirrorLabels() {
  final source = i18nSource();

  final block = RegExp(r'ROLE_LABEL_EN[^=]*=\s*\{(.*?)\n\};', dotAll: true)
      .firstMatch(source);
  expect(block, isNotNull,
      reason: 'ROLE_LABEL_EN literal not found — did the mirror move or '
          'change shape?');

  return {
    for (final m
        in RegExp(r'(\w+)\s*:\s*"([^"]*)"').allMatches(block!.group(1)!))
      m.group(1)!: m.group(2)!,
  };
}

Map<String, String> _catalogLabels() =>
    {for (final r in RoleCatalog.all) r.canonicalName: r.labelEn};

void main() {
  test('every built-in role has an English label in the Edge Function mirror',
      () {
    final catalog = _catalogLabels();
    final mirror = _mirrorLabels();

    // Guards against a parser that silently matched nothing, which would make
    // every assertion below vacuously true.
    expect(mirror, isNotEmpty);

    final missing = catalog.keys.where((k) => !mirror.containsKey(k)).toList()
      ..sort();
    expect(missing, isEmpty,
        reason: 'Roles missing from supabase/functions/_shared/i18n.ts — an '
            'invitation e-mail in English would print the Portuguese label for '
            'these: ${missing.join(", ")}');

    final extra = mirror.keys.where((k) => !catalog.containsKey(k)).toList()
      ..sort();
    expect(extra, isEmpty,
        reason: 'The mirror defines roles the catalog does not — nothing '
            'renders these, so a wrong translation here would never be seen: '
            '${extra.join(", ")}');
  });

  test('the mirrored labels match the catalog word for word', () {
    final catalog = _catalogLabels();
    final mirror = _mirrorLabels();

    final differing = catalog.entries
        .where((e) => mirror.containsKey(e.key) && mirror[e.key] != e.value)
        .map((e) => '${e.key}: catalog "${e.value}" vs TS "${mirror[e.key]}"')
        .toList()
      ..sort();

    expect(differing, isEmpty,
        reason: 'The same role reads differently in the app and in the '
            'invitation e-mail:\n  ${differing.join("\n  ")}');
  });

  // The gendered pairs are the reason this mirror is easy to get wrong: PT-BR
  // has two distinct rows where English has one word, and dropping the
  // qualifier makes two catalog entries indistinguishable in an English
  // e-mail — the same argument that put (m)/(f) in RoleCatalog itself.
  test('gendered pairs stay distinguishable in English', () {
    final mirror = _mirrorLabels();

    for (final pair in const [
      ('cousin_m', 'cousin_f'),
      ('friend_m', 'friend_f'),
      ('guardian_m', 'guardian_f'),
    ]) {
      expect(mirror[pair.$1], isNot(equals(mirror[pair.$2])),
          reason: '${pair.$1} and ${pair.$2} read identically in English.');
    }
  });
}
