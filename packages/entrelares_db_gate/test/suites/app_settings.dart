import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// T-41 — the central app-configuration table.
///
/// Security model: the client only READS the public rows, as a UX mirror; every
/// real limit is enforced server-side. These tests prove a malicious
/// authenticated user can neither read the private settings nor change any
/// setting for their own benefit.
///
/// Port of `db-gate/Entrelares.IntegrationTests/AppSettingsTests.cs`.
void appSettingsTests(GateFixture fx) {
  Future<Set<String>> keysSeenBy(SupabaseClient who) async =>
      {for (final row in await who.from('app_settings').select('key')) row['key'] as String};

  group('AppSettingsTests', () {
    test('an authenticated client reads only the PUBLIC settings', () async {
      final keys = await keysSeenBy(fx.member);

      expect(keys, contains('calendar_months_free'));
      expect(keys, contains('calendar_months_premium'));
      expect(keys, contains('free_caregivers'));
      expect(keys, contains('max_caregivers'));
      expect(keys, isNot(contains('email_cap_free')));
      expect(keys, isNot(contains('email_cap_premium')));
    });

    test('an authenticated client reads the cutover date', () async {
      // T-53 stage 4: `cutover.web_date` is a PUBLIC row — the FROZEN Blazor
      // client reads it to decide whether to announce the move at all, and a
      // client that cannot read it announces nothing. The key is spelled out
      // here rather than mirrored from a constant, because the helper that owned
      // it belongs to that client and dies with it.
      final row = (await fx.member
              .from('app_settings')
              .select('key, value_type')
              .eq('key', 'cutover.web_date'))
          .single;

      // The VALUE is deliberately not asserted: QA legitimately writes a date
      // here to exercise the banner. What is pinned is the declared TYPE, which
      // the table's own check constraint accepts — `text` is NOT one of the five
      // it allows, and the migration that said so was refused outright.
      expect(row['value_type'], 'string');
    });

    test('the service role sees every setting', () async {
      final keys = await keysSeenBy(fx.service);

      expect(keys, contains('email_cap_free'));
      expect(keys, contains('calendar_months_free'));
    });

    test('an authenticated client cannot write settings', () async {
      await expectRejected(() => fx.member
          .from('app_settings')
          .update({'value': '999'}).eq('key', 'calendar_months_free'));

      await expectRejected(() => fx.member.from('app_settings').insert({
            'key': 'hacker_key',
            'value': '1',
            'value_type': 'int',
            'category': 'general',
          }));

      // The real value is untouched — the server reads the truth.
      final row = (await fx.service
              .from('app_settings')
              .select('value')
              .eq('key', 'calendar_months_free'))
          .single;
      expect(row['value'], '6');
    });
  });
}
