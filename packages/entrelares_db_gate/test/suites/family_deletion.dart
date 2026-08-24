import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// S-11 (PR2) — whole-family deletion with multi-party consent:
///   · admin-only + sudo-gated request; a single pending request per family;
///   · while pending: invitations and individual exits are BLOCKED;
///   · any refusal ends the request at once (the family continues); agreement
///     is recorded but never accelerates the purge — the 30-day window always
///     runs in full;
///   · withdraw is requester-only + sudo; a new request restarts the window;
///   · the reminder fires ONCE at D-3; the purge past the window removes the
///     whole family and hands back uids + real e-mails for the cron.
///
/// Destructive scenarios run on throwaway families, so the shared fixture is
/// never mutated.
///
/// Port of `db-gate/Entrelares.IntegrationTests/FamilyDeletionTests.cs`.
void familyDeletionTests(GateFixture fx) {
  Future<List<FamilyDeletionRequest>> requestsOf(SupabaseClient who) async => [
        for (final row in await who.from('family_deletion_requests').select())
          FamilyDeletionRequest.fromJson(row)
      ];

  Future<List<Map<String, dynamic>>> notificationsOf(SupabaseClient who) async =>
      (await who.from('notifications').select()).cast<Map<String, dynamic>>();

  group('FamilyDeletionTests', () {
    test('the request is gated on admin AND sudo', () async {
      final fam = await fx.createFamily('fdel-gate');

      // A non-admin, even elevated, is rejected.
      await fx.elevate(fam.memberProfile);
      await expectRejected(
        () => fam.member.rpc<dynamic>('request_family_deletion'),
        contains: 'administradores',
      );

      // An admin without elevation gets the detectable contract.
      await fx.clearElevation(fam.adminProfile);
      await expectRejected(
        () => fam.admin.rpc<dynamic>('request_family_deletion'),
        contains: 'ELEVATION_REQUIRED',
      );

      // Nothing was created.
      expect(
          await fx.service
              .from('family_deletion_requests')
              .select()
              .eq('family_id', fam.familyId),
          isEmpty);
    });

    test('a pending request notifies, blocks, records agreement, and ends on '
        'refusal', () async {
      final fam = await fx.createFamily('fdel-flow');

      await fx.elevate(fam.adminProfile);
      await fam.admin.rpc<dynamic>('request_family_deletion');

      // Pending and RLS-visible to the family; the deadline is ~30 days out.
      final pending = (await requestsOf(fam.member))
          .firstWhere((r) => r.status == 'pending');
      expect(pending.requestedBy, fam.adminProfile.id);
      expect(
          pending.scheduledFor.isAfter(
              DateTime.now().toUtc().add(const Duration(days: 29))),
          isTrue);

      // The other member was told in-app.
      expect(
        (await notificationsOf(fam.member)).where((n) =>
            n['type'] == 'family_deletion' &&
            n['recipient_profile_id'] == fam.memberProfile.id),
        isNotEmpty,
      );

      // A second request is blocked while one is pending.
      await fx.elevate(fam.adminProfile);
      await expectRejected(
        () => fam.admin.rpc<dynamic>('request_family_deletion'),
        contains: 'em andamento',
      );

      // Invitations are blocked while pending.
      await expectRejected(
        () => GateFixture.createInvitation(
            fam.admin, fx.testEmail('fdel-inv'), fx.roles.first.id),
        contains: 'bloqueados',
      );

      // So is an individual exit.
      await fx.elevate(fam.memberProfile);
      await expectRejected(
        () => fam.member.rpc<dynamic>('request_account_deletion'),
        contains: 'exclusão da família em andamento',
      );

      // Agreement is recorded but the request STAYS pending — the full window
      // runs whatever everybody says, which is what makes it a cooling-off
      // period rather than a vote.
      await fam.member
          .rpc<dynamic>('respond_family_deletion', params: {'p_agree': true});
      final agreed = FamilyDeletionResponse.fromJson((await fx.service
              .from('family_deletion_responses')
              .select()
              .eq('request_id', pending.id))
          .single);
      expect(agreed.agreed, isTrue);
      expect(
          (await requestsOf(fam.member))
              .firstWhere((r) => r.id == pending.id)
              .status,
          'pending');

      // Changing the answer to a refusal ends the request immediately.
      await fam.member
          .rpc<dynamic>('respond_family_deletion', params: {'p_agree': false});
      final refused = (await requestsOf(fam.member))
          .firstWhere((r) => r.id == pending.id);
      expect(refused.status, 'refused');
      expect(refused.resolvedBy, fam.memberProfile.id);

      // Everyone — the requester included — learns the family continues.
      expect(
        (await notificationsOf(fam.admin)).where((n) =>
            n['type'] == 'family_deletion' &&
            n['recipient_profile_id'] == fam.adminProfile.id &&
            (n['message'] as String).contains('recusou')),
        isNotEmpty,
      );

      // With the request resolved, invitations flow again.
      final token = await GateFixture.createInvitation(
          fam.admin, fx.testEmail('fdel-inv2'), fx.roles.first.id);
      expect(token, isNotEmpty);
    });

    test('withdraw is requester-only and sudo-gated, and a new request can '
        'follow', () async {
      final fam = await fx.createFamily('fdel-wdrw');

      await fx.elevate(fam.adminProfile);
      await fam.admin.rpc<dynamic>('request_family_deletion');

      // Another member cannot withdraw — they refuse instead.
      await expectRejected(
        () => fam.member.rpc<dynamic>('withdraw_family_deletion'),
        contains: 'Somente quem solicitou',
      );

      // The requester needs a fresh elevation.
      await fx.clearElevation(fam.adminProfile);
      await expectRejected(
        () => fam.admin.rpc<dynamic>('withdraw_family_deletion'),
        contains: 'ELEVATION_REQUIRED',
      );

      await fx.elevate(fam.adminProfile);
      await fam.admin.rpc<dynamic>('withdraw_family_deletion');
      final withdrawn = (await requestsOf(fam.admin))
          .firstWhere((r) => r.status == 'withdrawn');
      expect(withdrawn.resolvedBy, fam.adminProfile.id);

      await fx.elevate(fam.adminProfile);
      await fam.admin.rpc<dynamic>('request_family_deletion');
      expect(
          (await requestsOf(fam.admin)).where((r) => r.status == 'pending'),
          hasLength(1));
    });

    test('undoing an agreement removes the response and leaves the request '
        'pending', () async {
      // QA: `p_agree` NULL returns the member to "aguardando" — the ABSENCE of a
      // row is what waiting means, so an undo has to delete rather than store a
      // third state.
      final fam = await fx.createFamily('fdel-undo');

      await fx.elevate(fam.adminProfile);
      await fam.admin.rpc<dynamic>('request_family_deletion');
      await fam.member
          .rpc<dynamic>('respond_family_deletion', params: {'p_agree': true});

      final pending = (await requestsOf(fam.member))
          .firstWhere((r) => r.status == 'pending');
      expect(
          await fx.service
              .from('family_deletion_responses')
              .select()
              .eq('request_id', pending.id),
          hasLength(1));

      await fam.member
          .rpc<dynamic>('respond_family_deletion', params: {'p_agree': null});

      expect(
          await fx.service
              .from('family_deletion_responses')
              .select()
              .eq('request_id', pending.id),
          isEmpty);
      expect(
          (await requestsOf(fam.member))
              .firstWhere((r) => r.id == pending.id)
              .status,
          'pending');
    });

    test('immediate execution requires unanimity, then purges at once',
        () async {
      final fam = await fx.createFamily('fdel-exec');

      await fx.elevate(fam.adminProfile);
      await fam.admin.rpc<dynamic>('request_family_deletion');

      // Without unanimity → rejected even when elevated.
      await fx.elevate(fam.adminProfile);
      await expectRejected(
        () => fam.admin.rpc<dynamic>('execute_family_deletion'),
        contains: 'concordância explícita',
      );

      // The member agrees → unanimity; a non-admin still cannot execute.
      await fam.member
          .rpc<dynamic>('respond_family_deletion', params: {'p_agree': true});
      await expectRejected(
        () => fam.member.rpc<dynamic>('execute_family_deletion'),
        contains: 'administradores',
      );

      // An admin without a fresh elevation → ELEVATION_REQUIRED.
      await fx.clearElevation(fam.adminProfile);
      await expectRejected(
        () => fam.admin.rpc<dynamic>('execute_family_deletion'),
        contains: 'ELEVATION_REQUIRED',
      );

      // Elevated → executes: the deadline is NOW and the purge takes the family.
      await fx.elevate(fam.adminProfile);
      await fam.admin.rpc<dynamic>('execute_family_deletion');

      final result =
          await fx.service.rpc<dynamic>('purge_expired_family_deletions');
      expect(result.toString(), contains(fam.adminProfile.userId));
      expect(
          await fx.service.from('families').select().eq('id', fam.familyId),
          isEmpty);
    });

    test('the D-3 reminder fires exactly once', () async {
      final fam = await fx.createFamily('fdel-rem');

      await fx.elevate(fam.adminProfile);
      await fam.admin.rpc<dynamic>('request_family_deletion');

      // Not due yet — the deadline is ~30 days out.
      await fx.service.rpc<dynamic>('family_deletion_reminders_due');
      final untouched = (await requestsOf(fx.service))
          .where((r) => r.familyId == fam.familyId && r.status == 'pending')
          .single;
      expect(untouched.reminderSentAt, isNull);

      // Move the deadline to 2 days out → inside the D-3 window.
      await fx.service.from('family_deletion_requests').update({
        'scheduled_for': DateTime.now()
            .toUtc()
            .add(const Duration(days: 2))
            .toIso8601String(),
      }).eq('id', untouched.id);

      final due = await fx.service.rpc<dynamic>('family_deletion_reminders_due');
      expect(due.toString(), contains('${fam.adminProfile.id}'));

      final marked = FamilyDeletionRequest.fromJson((await fx.service
              .from('family_deletion_requests')
              .select()
              .eq('id', untouched.id))
          .single);
      expect(marked.reminderSentAt, isNotNull);

      expect(
        (await notificationsOf(fam.member)).where((n) =>
            n['type'] == 'family_deletion' &&
            n['recipient_profile_id'] == fam.memberProfile.id &&
            (n['message'] as String).contains('excluída definitivamente em')),
        isNotEmpty,
      );

      // A second run: already sent → nothing due for this request.
      final again =
          await fx.service.rpc<dynamic>('family_deletion_reminders_due');
      expect(again.toString().replaceAll(' ', ''),
          isNot(contains('"request_id":${untouched.id}')));
    });

    test('past the window the family is purged, with uids and e-mails for the '
        'cron', () async {
      final fam = await fx.createFamily('fdel-purge');
      final familyName = (await fx.service
              .from('families')
              .select('name')
              .eq('id', fam.familyId))
          .single['name'] as String;

      await fx.elevate(fam.adminProfile);
      await fam.admin.rpc<dynamic>('request_family_deletion');

      await fx.service.from('family_deletion_requests').update({
        'scheduled_for': DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 1))
            .toIso8601String(),
      }).eq('family_id', fam.familyId);

      final content =
          (await fx.service.rpc<dynamic>('purge_expired_family_deletions'))
              .toString();
      // The REAL e-mails, not the scrubbed ones: the cron has to be able to tell
      // people their family is gone, and after the purge there is nowhere left
      // to look them up.
      expect(content, contains(fam.adminProfile.userId));
      expect(content, contains(fam.memberProfile.userId));
      expect(content, contains(fam.adminProfile.email));
      expect(content, contains(fam.memberProfile.email));
      expect(content, contains(familyName));

      // The family and every row of its data are gone.
      expect(
          await fx.service.from('families').select().eq('id', fam.familyId),
          isEmpty);
      expect(
          await fx.service
              .from('profiles')
              .select()
              .eq('family_id', fam.familyId),
          isEmpty);
    });
  });
}
