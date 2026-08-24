import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// U-13 (pre-production round) — the database half of "e-mails in the language
/// the person actually reads".
///
/// The defect: `profiles.language` was written only by the language picker, and
/// the picker was rendered only on the public auth screens (where the visitor is
/// anonymous, so nothing is written) and in the DESKTOP top bar. A signed-in
/// phone had no picker at all, so the column was NULL for everyone — and
/// `send-swap-email`, which correctly reads the RECIPIENT's language, resolved
/// NULL to pt-BR and mailed Portuguese to people whose whole app was in English.
///
/// The fix is two columns and a generated third, and what these tests pin is the
/// part no unit test can: that the generated column really is what the Edge
/// Functions will read, and that a member can write their own detection through
/// the existing own-row policy without a new RPC.
///
/// **Why raw maps and not the `Member` contract here.** `language_effective` is a
/// GENERATED column: PostgREST rejects any write carrying it, so mapping it into
/// the app's contract would be one careless full-row save away from breaking
/// every profile write. The gate reads it as a bare projection instead — which
/// is exactly how the Edge Functions read it.
///
/// Port of `db-gate/Entrelares.IntegrationTests/ProfileLanguageTests.cs`.
void profileLanguageTests(GateFixture fx) {
  Future<Map<String, dynamic>> readLanguages(int profileId) async =>
      (await fx.service
              .from('profiles')
              .select('id, language, language_detected, language_effective')
              .eq('id', profileId))
          .single;

  Future<void> setLanguages(int profileId, String? choice, String? detected) =>
      fx.service.from('profiles').update({
        'language': choice,
        'language_detected': detected,
      }).eq('id', profileId);

  group('ProfileLanguageTests', () {
    test('a detection feeds the effective language when no choice was made',
        () async {
      // The reported bug, as a rule: no choice on file, but we know what their
      // screen renders — and that is what the senders must read.
      final id = fx.memberProfile.id;
      try {
        await setLanguages(id, null, 'en');
        expect((await readLanguages(id))['language_effective'], 'en');
      } finally {
        await setLanguages(id, null, null);
      }
    });

    test('an explicit choice wins over the detection', () async {
      // Someone reading the app in English on a borrowed device still gets
      // their own language in the mail.
      final id = fx.memberProfile.id;
      try {
        await setLanguages(id, 'pt-BR', 'en');
        expect((await readLanguages(id))['language_effective'], 'pt-BR');
      } finally {
        await setLanguages(id, null, null);
      }
    });

    test('the effective language is NULL when neither is known', () async {
      // The senders' own NULL → pt-BR fallback applies, and it must be a real
      // NULL rather than a guessed 'pt-BR': the two are different FACTS and the
      // migration refuses to conflate them.
      final id = fx.memberProfile.id;
      await setLanguages(id, null, null);
      expect((await readLanguages(id))['language_effective'], isNull);
    });

    test('a member records their own detection through the own-row policy',
        () async {
      // The client writes this itself on sign-in — no RPC — and
      // `enforce_profile_protection` must not treat a display language as a
      // system-managed field the way it does `color_slot` or `is_admin`.
      final id = fx.memberProfile.id;
      try {
        await fx.member
            .from('profiles')
            .update({'language_detected': 'en'}).eq('id', id);

        expect((await readLanguages(id))['language_detected'], 'en');
      } finally {
        await setLanguages(id, null, null);
      }
    });

    test("a member cannot record someone else's language", () async {
      // RLS answers with silence, not an error, so the assertion has to be on
      // the stored value.
      final target = fx.founderProfile.id;
      try {
        await fx.member
            .from('profiles')
            .update({'language_detected': 'en'}).eq('id', target);

        expect((await readLanguages(target))['language_detected'], isNull);
      } finally {
        await setLanguages(target, null, null);
      }
    });

    test('a detection refuses a language the app does not have', () async {
      // The CHECK is the same closed set as the app's language list — a third
      // language means widening it in the migration that adds it, never in a
      // caller.
      await expectRejected(
        () => setLanguages(fx.memberProfile.id, null, 'fr'),
        contains: 'language_detected',
      );
    });
  });
}
