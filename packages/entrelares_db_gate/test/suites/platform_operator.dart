import 'dart:convert';

import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '_helpers.dart';

/// F-58 — the platform-operator console, DB foundation:
///   · every `admin_*` RPC refuses a caller who is not in `platform_operators`,
///     no matter how elevated or family-admin they are;
///   · writes additionally require an ACTIVE S-10 elevation
///     (`ELEVATION_REQUIRED`);
///   · `admin_update_setting` validates against `value_type` and refuses
///     `policy.*`;
///   · the comp flows through `is_premium()` ITSELF — never a parallel check —
///     and survives a billing-style plan downgrade;
///   · every operator action leaves its `operator_audit_logs` trail, and a comp
///     grant/revoke also lands in the FAMILY's own `account_logs`, which is the
///     transparency half;
///   · neither operator table is readable by any authenticated client.
///
/// The three operator tables have no app contract and never will — the client
/// reaches them only through the RPCs — so this suite reads them as raw
/// projections through the service client.
///
/// Port of `db-gate/Entrelares.IntegrationTests/PlatformOperatorTests.cs`.
void platformOperatorTests(GateFixture fx) {
  Future<void> removeOperator(Member who) async {
    await fx.service
        .from('platform_operators')
        .delete()
        .eq('user_id', who.userId!);
  }

  Future<void> makeOperator(Member who) async {
    // Idempotent (delete-first): a fixed-key seed must clean its own leftover,
    // because a cancelled run never reaches the teardown.
    await removeOperator(who);
    await fx.service.from('platform_operators').insert({
      'user_id': who.userId,
      'note': 'e2e throwaway operator',
    });
  }

  Future<bool> isPremium(int familyId) async {
    final result = await fx.service
        .rpc<dynamic>('is_premium', params: {'p_family_id': familyId});
    return result == true || result.toString().contains('true');
  }

  Future<List<Map<String, dynamic>>> auditRows(String operatorUserId) async =>
      (await fx.service
              .from('operator_audit_logs')
              .select()
              .eq('operator_user_id', operatorUserId))
          .cast<Map<String, dynamic>>();

  Future<List<AccountLog>> familyLogs(int familyId) async => [
        for (final row
            in await fx.service.from('account_logs').select().eq('family_id', familyId))
          AccountLog.fromJson(row)
      ];

  group('PlatformOperatorTests', () {
    // ── The operator gate itself ─────────────────────────────────────────

    test('a family admin, however elevated, is refused by every admin RPC',
        () async {
      // The refusal comes BEFORE anything else is checked — which is the point:
      // the operator gate is not one permission among several, it is the door.
      await removeOperator(fx.founderProfile);
      await fx.elevate(fx.founderProfile);
      try {
        final calls = <(String, Map<String, dynamic>)>[
          ('admin_list_settings', {}),
          ('admin_list_families', {}),
          ('admin_list_audit', {}),
          (
            'admin_update_setting',
            {'p_key': 'free_caregivers', 'p_value': '2'}
          ),
          ('admin_lookup_family', {'p_email': fx.founderProfile.email}),
          ('admin_set_comp', {'p_family_id': fx.familyId, 'p_granted': true}),
        ];
        for (final (rpc, args) in calls) {
          await expectRejected(
            () => fx.founder.rpc<dynamic>(rpc, params: args),
            contains: 'restrito',
          );
        }
      } finally {
        await fx.clearElevation(fx.founderProfile);
      }
    });

    test('neither operator table leaks to an authenticated client', () async {
      // Not even to the operator themselves — the console goes through the RPCs.
      await expectRejected(() => fx.founder.from('platform_operators').select());
      await expectRejected(
          () => fx.founder.from('operator_audit_logs').select());
    });

    // ── Sudo on writes ───────────────────────────────────────────────────

    test('an operator without elevation can read but not write', () async {
      await makeOperator(fx.founderProfile);
      await fx.clearElevation(fx.founderProfile);
      try {
        final settings =
            await fx.founder.rpc<dynamic>('admin_list_settings');
        expect(settings.toString(), contains('email_cap_free'));

        await expectRejected(
          () => fx.founder.rpc<dynamic>('admin_update_setting',
              params: {'p_key': 'free_caregivers', 'p_value': '2'}),
          contains: 'ELEVATION_REQUIRED',
        );

        await expectRejected(
          () => fx.founder.rpc<dynamic>('admin_set_comp',
              params: {'p_family_id': fx.familyId, 'p_granted': true}),
          contains: 'ELEVATION_REQUIRED',
        );
      } finally {
        await removeOperator(fx.founderProfile);
      }
    });

    // ── Settings editor rules ────────────────────────────────────────────

    test('admin_update_setting validates the type and refuses policy.*',
        () async {
      await makeOperator(fx.founderProfile);
      await fx.elevate(fx.founderProfile);
      try {
        await expectRejected(
          () => fx.founder.rpc<dynamic>('admin_update_setting',
              params: {'p_key': 'free_caregivers', 'p_value': 'abc'}),
          contains: 'int',
        );

        // `policy.*` is refused even for a VALID value: those two rows travel
        // with a code constant and a migration, and an out-of-band edit is what
        // locks the whole user base out of the app.
        await expectRejected(
          () => fx.founder.rpc<dynamic>('admin_update_setting',
              params: {'p_key': 'policy.current_version', 'p_value': '9.9'}),
          contains: 'policy',
        );

        // The console EDITS; it never creates.
        await expectRejected(
          () => fx.founder.rpc<dynamic>('admin_update_setting',
              params: {'p_key': 'no_such_setting', 'p_value': '1'}),
          contains: 'inexistente',
        );
      } finally {
        await fx.clearElevation(fx.founderProfile);
        await removeOperator(fx.founderProfile);
      }
    });

    test('a valid setting update persists and leaves its audit row', () async {
      // Against a THROWAWAY settings row, so the shared dev config is never
      // mutated by the suite — and delete-first, so a cancelled run cannot leave
      // a fixed key behind for the next one.
      const probeKey = 'e2e.console_probe';

      await makeOperator(fx.founderProfile);
      await fx.elevate(fx.founderProfile);
      await fx.service.from('app_settings').delete().eq('key', probeKey);
      await fx.service.from('app_settings').insert({
        'key': probeKey,
        'value': '1',
        'value_type': 'int',
        'category': 'e2e',
      });
      try {
        await fx.founder.rpc<dynamic>('admin_update_setting',
            params: {'p_key': probeKey, 'p_value': '2'});

        final row = (await fx.service
                .from('app_settings')
                .select('value')
                .eq('key', probeKey))
            .single;
        expect(row['value'], '2');

        final audit = (await auditRows(fx.founderProfile.userId!)).where((l) =>
            l['action'] == 'setting_updated' && l['setting_key'] == probeKey);
        expect(audit, hasLength(1));
        expect(audit.single['old_value'], '1');
        expect(audit.single['new_value'], '2');
      } finally {
        await fx.service.from('app_settings').delete().eq('key', probeKey);
        await fx.clearElevation(fx.founderProfile);
        await removeOperator(fx.founderProfile);
      }
    });

    // ── Comp Premium ─────────────────────────────────────────────────────

    test('the comp flows through the entitlement itself, and is audited',
        () async {
      final fam = await fx.createFamily('f58-comp');
      await fx.service.rpc<dynamic>('set_family_plan',
          params: {'p_family_id': fam.familyId, 'p_plan': 'free'});
      expect(await isPremium(fam.familyId), isFalse);

      await makeOperator(fx.founderProfile);
      await fx.elevate(fx.founderProfile);
      try {
        await fx.founder.rpc<dynamic>('admin_set_comp', params: {
          'p_family_id': fam.familyId,
          'p_granted': true,
          'p_note': 'e2e comp',
        });
        expect(await isPremium(fam.familyId), isTrue);

        // A billing-style downgrade must NOT clobber the courtesy — otherwise
        // the next dunning cycle would silently take back what support gave.
        await fx.service.rpc<dynamic>('set_family_plan',
            params: {'p_family_id': fam.familyId, 'p_plan': 'free'});
        expect(await isPremium(fam.familyId), isTrue);

        // Idempotent: a repeated grant keeps the ORIGINAL timestamp.
        Future<DateTime?> compAt() async => Family.fromJson((await fx.service
                .from('families')
                .select()
                .eq('id', fam.familyId))
            .single).compPremiumAt;
        final first = await compAt();
        await fx.founder.rpc<dynamic>('admin_set_comp',
            params: {'p_family_id': fam.familyId, 'p_granted': true});
        expect(await compAt(), first);

        // Transparency: the FAMILY's own history shows the act, WITH the reason.
        expect(
            (await familyLogs(fam.familyId)).where((l) =>
                l.action == 'comp_premium_granted' && l.newValue == 'e2e comp'),
            hasLength(1));

        // …and the operator trail keeps the grant.
        expect(
            (await auditRows(fx.founderProfile.userId!)).where((l) =>
                l['action'] == 'comp_granted' && l['family_id'] == fam.familyId),
            hasLength(1));

        // Revoke — with ITS OWN reason: entitlement drops and the entry reads
        // "courtesy's note → revoke's reason".
        await fx.founder.rpc<dynamic>('admin_set_comp', params: {
          'p_family_id': fam.familyId,
          'p_granted': false,
          'p_note': 'e2e revoke',
        });
        expect(await isPremium(fam.familyId), isFalse);

        expect(
            (await familyLogs(fam.familyId)).where((l) =>
                l.action == 'comp_premium_revoked' &&
                l.oldValue == 'e2e comp' &&
                l.newValue == 'e2e revoke'),
            hasLength(1));
        expect(
            (await auditRows(fx.founderProfile.userId!)).where((l) =>
                l['action'] == 'comp_revoked' && l['family_id'] == fam.familyId),
            hasLength(1));
      } finally {
        await fx.clearElevation(fx.founderProfile);
        await removeOperator(fx.founderProfile);
      }
    });

    // ── Support lookup ───────────────────────────────────────────────────

    test('the lookup crosses families, and every call is logged', () async {
      // Crossing the family RLS is the POINT — it is what the operator gate
      // exists for — which is exactly why a miss is audited too: an access
      // attempt that found nothing is still an access attempt.
      await makeOperator(fx.founderProfile);
      try {
        final hit = await fx.founder.rpc<dynamic>('admin_lookup_family',
            params: {'p_email': fx.founderBProfile.email});
        final decoded = hit is String
            ? jsonDecode(hit) as Map<String, dynamic>
            : hit as Map<String, dynamic>;
        expect((decoded['family'] as Map)['id'], fx.familyBId);
        expect(
            (decoded['members'] as List).map((m) => (m as Map)['email']),
            contains(fx.founderBProfile.email));

        final missEmail = fx.testEmail('f58-nobody');
        final miss = await fx.founder
            .rpc<dynamic>('admin_lookup_family', params: {'p_email': missEmail});
        expect(miss.toString(), isNot(contains('family')));

        final audit = await auditRows(fx.founderProfile.userId!);
        expect(
            audit.where((l) =>
                l['action'] == 'family_lookup' &&
                l['family_id'] == fx.familyBId &&
                l['new_value'] == fx.founderBProfile.email!.toLowerCase()),
            isNotEmpty);
        expect(
            audit.where((l) =>
                l['action'] == 'family_lookup' &&
                l['family_id'] == null &&
                l['new_value'] == missEmail.toLowerCase()),
            isNotEmpty);
      } finally {
        await removeOperator(fx.founderProfile);
      }
    });

    // ── QA round: the full listing and the login e-mail change ───────────

    test('admin_list_families returns everything with members, and audits',
        () async {
      // The console lists EVERYTHING upfront and filters locally, so the bulk
      // read itself is an audited act.
      await makeOperator(fx.founderProfile);
      try {
        final response = await fx.founder.rpc<dynamic>('admin_list_families');
        final families = (response is String
                ? jsonDecode(response) as List
                : response as List)
            .cast<Map<String, dynamic>>();

        final ids = families.map((f) => f['id']).toSet();
        expect(ids, contains(fx.familyId));
        expect(ids, contains(fx.familyBId));

        final familyA = families.firstWhere((f) => f['id'] == fx.familyId);
        final emails =
            (familyA['members'] as List).map((m) => (m as Map)['email']);
        expect(emails, contains(fx.founderProfile.email));
        expect(emails, contains(fx.memberProfile.email));

        expect(
            (await auditRows(fx.founderProfile.userId!))
                .where((l) => l['action'] == 'families_listed'),
            isNotEmpty);
      } finally {
        await removeOperator(fx.founderProfile);
      }
    });

    test('admin_list_audit returns the trail, newest first', () async {
      await makeOperator(fx.founderProfile);
      try {
        // Leave a fresh, recognizable footprint to find in the trail.
        await fx.founder.rpc<dynamic>('admin_lookup_family',
            params: {'p_email': fx.founderBProfile.email});

        final response = await fx.founder
            .rpc<dynamic>('admin_list_audit', params: {'p_limit': 50});
        final entries = (response is String
                ? jsonDecode(response) as List
                : response as List)
            .cast<Map<String, dynamic>>();

        expect(
            entries.where((e) =>
                e['action'] == 'family_lookup' && e['family_name'] != null),
            isNotEmpty);

        final ids = [for (final e in entries) e['id'] as int];
        expect(ids, orderedEquals([...ids]..sort((a, b) => b.compareTo(a))));
      } finally {
        await removeOperator(fx.founderProfile);
      }
    });

    test("a plan change writes the family's history with an inferred reason",
        () async {
      // QA 2: the flips narrate themselves in the FAMILY's own history, and the
      // reason is inferred from the subscription state — a paid activation and a
      // dunning downgrade, through the REAL writers.
      final fam = await fx.createFamily('f58-hist');
      await fx.deleteSubscriptionSeed('sub_e2e_f58-hist');
      final sub = Subscription.fromJson((await fx.service
              .from('subscriptions')
              .insert({
                'family_id': fam.familyId,
                'external_subscription_id': 'sub_e2e_f58-hist',
                'cycle': 'monthly',
                'price_cents': 549,
              })
              .select())
          .single);

      await fx.service
          .from('subscriptions')
          .update({'status': 'active'}).eq('id', sub.id);
      await fx.service.rpc<dynamic>('set_family_plan',
          params: {'p_family_id': fam.familyId, 'p_plan': 'premium'});

      await fx.service.from('subscriptions').update({
        'status': 'overdue',
        'overdue_since': DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 10))
            .toIso8601String(),
      }).eq('id', sub.id);
      // The grace cron downgrades by DIRECT UPDATE — reproduce that path, not a
      // convenient RPC, because the trigger has to fire for the cron's writes.
      await fx.service
          .from('families')
          .update({'plan': 'free', 'trial_ends_at': null}).eq(
              'id', fam.familyId);

      final logs = await familyLogs(fam.familyId);
      expect(
          logs.where((l) =>
              l.action == 'plan_premium_payment' &&
              l.oldValue == 'free' &&
              l.newValue == 'premium'),
          hasLength(1));
      expect(
          logs.where((l) =>
              l.action == 'plan_free_overdue' &&
              l.oldValue == 'premium' &&
              l.newValue == 'free'),
          hasLength(1));
    });

    test('an operator changes a member login e-mail, end to end', () async {
      final fam = await fx.createFamily('f58-mail');
      final bearer = fx.founder.auth.currentSession!.accessToken;
      final newEmail = fx.testEmail('f58-mail-new');

      Future<(int, String)> changeEmail(int profileId, String email) async {
        final response = await http.post(
          Uri.parse('${TestEnv.supabaseUrl.replaceAll(RegExp(r'/+$'), '')}'
              '/functions/v1/admin-update-member-email'),
          headers: {
            'apikey': TestEnv.anonKey,
            'Authorization': 'Bearer $bearer',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'profile_id': profileId, 'new_email': email}),
        );
        return (response.statusCode, response.body);
      }

      // Not an operator yet → refused before anything else.
      await removeOperator(fx.founderProfile);
      final refused = await changeEmail(fam.memberProfile.id, newEmail);
      expect(refused.$1, 403);
      expect(refused.$2, contains('restrito'));

      await makeOperator(fx.founderProfile);
      try {
        // Operator without sudo → the ELEVATION_REQUIRED contract.
        await fx.clearElevation(fx.founderProfile);
        final unelevated = await changeEmail(fam.memberProfile.id, newEmail);
        expect(unelevated.$1, 403);
        expect(unelevated.$2, contains('ELEVATION_REQUIRED'));

        await fx.elevate(fx.founderProfile);

        // Another account's address → refused by GoTrue.
        final duplicate =
            await changeEmail(fam.memberProfile.id, fam.adminProfile.email!);
        expect(duplicate.$1, 409);

        final ok = await changeEmail(fam.memberProfile.id, newEmail);
        expect(ok.$1, 200);

        // profiles.email followed via sync_profile_email…
        final profile = Member.fromJson((await fx.service
                .from('profiles')
                .select()
                .eq('id', fam.memberProfile.id))
            .single);
        expect(profile.email, newEmail.toLowerCase());

        // …the LOGIN really moved (same password, new address)…
        final signedIn = await fx.signIn(newEmail);
        expect(signedIn.auth.currentSession, isNotNull);

        // …and both trails carry the act.
        expect(
            (await auditRows(fx.founderProfile.userId!)).where((l) =>
                l['action'] == 'member_email_changed' &&
                l['family_id'] == fam.familyId &&
                l['new_value'] == newEmail.toLowerCase()),
            isNotEmpty);
        expect(
            (await familyLogs(fam.familyId))
                .where((l) => l.action == 'email_changed'),
            isNotEmpty);
      } finally {
        await fx.clearElevation(fx.founderProfile);
        await removeOperator(fx.founderProfile);
      }
    });
  });
}
