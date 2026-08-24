import 'dart:convert';

import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// S-10 — server-enforced sudo mode and the account audit trail:
///   · `set_member_admin` refuses without an ACTIVE elevation, so a stolen
///     session token ALONE cannot flip admin flags;
///   · `account_logs` is append-only, family-scoped and fed by DB triggers;
///   · `log_account_action` only accepts the self-action whitelist;
///   · the deployed `elevate` Edge Function rejects a wrong password.
///
/// Port of `db-gate/Entrelares.IntegrationTests/SudoElevationTests.cs`.
void sudoElevationTests(GateFixture fx) {
  Future<List<AccountLog>> logsOf(SupabaseClient who) async => [
        for (final row in await who.from('account_logs').select())
          AccountLog.fromJson(row)
      ];

  Future<void> setAdmin(int profileId, bool isAdmin) =>
      fx.founder.rpc<dynamic>('set_member_admin',
          params: {'p_profile_id': profileId, 'p_is_admin': isAdmin});

  group('SudoElevationTests', () {
    test('set_member_admin without an elevation is rejected', () async {
      await fx.clearElevation(fx.founderProfile);

      await expectRejected(
        () => setAdmin(fx.memberProfile.id, true),
        contains: 'ELEVATION_REQUIRED',
      );
    });

    test('an EXPIRED elevation is as good as none', () async {
      await fx.service.from('auth_elevations').upsert({
        'user_id': fx.founderProfile.userId,
        'elevated_until': DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
      });

      await expectRejected(
        () => setAdmin(fx.memberProfile.id, true),
        contains: 'ELEVATION_REQUIRED',
      );
    });

    test('an elevated admin toggles the flag, and both moves are audited',
        () async {
      await fx.elevate(fx.founderProfile);

      try {
        await setAdmin(fx.memberProfile.id, true);

        final refreshed = Member.fromJson((await fx.founder
                .from('profiles')
                .select()
                .eq('id', fx.memberProfile.id))
            .single);
        expect(refreshed.isAdmin, isTrue);

        final granted = (await logsOf(fx.founder)).where((l) =>
            l.action == 'admin_granted' &&
            l.targetProfileId == fx.memberProfile.id);
        expect(granted, isNotEmpty);
        for (final log in granted) {
          expect(log.actorProfileId, fx.founderProfile.id);
        }
      } finally {
        await setAdmin(fx.memberProfile.id, false);
      }

      expect(
          (await logsOf(fx.founder)).where((l) =>
              l.action == 'admin_revoked' &&
              l.targetProfileId == fx.memberProfile.id),
          isNotEmpty);
    });

    test('log_account_action enforces its whitelist', () async {
      // A trigger-only action must not be forgeable from a client: the trail is
      // evidence, and an entry a user could write themselves is not.
      await expectRejected(
        () => fx.member
            .rpc<dynamic>('log_account_action', params: {'p_action': 'admin_granted'}),
        contains: 'não permitida',
      );

      await fx.member
          .rpc<dynamic>('log_account_action', params: {'p_action': 'data_exported'});

      final rows = (await logsOf(fx.member)).where((l) =>
          l.action == 'data_exported' &&
          l.actorProfileId == fx.memberProfile.id);
      expect(rows, isNotEmpty);
      for (final log in rows) {
        expect(log.targetProfileId, fx.memberProfile.id);
      }
    });

    test('account logs are family-scoped', () async {
      // Guarantee at least one family-A row exists.
      await fx.founder
          .rpc<dynamic>('log_account_action', params: {'p_action': 'data_exported'});

      final mine = await logsOf(fx.founder);
      expect(mine, isNotEmpty);
      for (final log in mine) {
        expect(log.familyId, fx.familyId);
      }

      final theirs = await logsOf(fx.founderB);
      expect(theirs.map((l) => l.familyId), isNot(contains(fx.familyId)));
    });

    test('self-actions are the author\'s alone; governance is the family\'s',
        () async {
      // QA refinement, and the distinction is the point: an export is a personal
      // act, while a promotion is two-party oversight — the member has to be
      // able to see that somebody made them an admin.
      await fx.founder
          .rpc<dynamic>('log_account_action', params: {'p_action': 'data_exported'});

      await fx.elevate(fx.founderProfile);
      await setAdmin(fx.memberProfile.id, true);
      await setAdmin(fx.memberProfile.id, false);

      final memberView = await logsOf(fx.member);

      expect(
          memberView.where((l) =>
              l.action == 'data_exported' &&
              l.actorProfileId == fx.founderProfile.id),
          isEmpty);

      expect(
          memberView.where((l) =>
              l.action == 'admin_granted' &&
              l.targetProfileId == fx.memberProfile.id),
          isNotEmpty);
      expect(
          memberView.where((l) =>
              l.action == 'admin_revoked' &&
              l.targetProfileId == fx.memberProfile.id),
          isNotEmpty);

      expect(
          (await logsOf(fx.founder)).where((l) =>
              l.action == 'data_exported' &&
              l.actorProfileId == fx.founderProfile.id),
          isNotEmpty);
    });

    test('the elevate function refuses a wrong password', () async {
      final accessToken = fx.founder.auth.currentSession!.accessToken;

      final response = await http.post(
        Uri.parse('${TestEnv.supabaseUrl.replaceAll(RegExp(r'/+$'), '')}'
            '/functions/v1/elevate'),
        headers: {
          'apikey': TestEnv.anonKey,
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'password': 'senha-errada-123'}),
      );

      expect(response.statusCode, 401);
      expect(response.body, contains('Senha incorreta'));
    });
  });
}
