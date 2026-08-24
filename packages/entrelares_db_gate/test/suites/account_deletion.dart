import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// S-11 (PR1) — individual account deletion, i.e. leaving the family:
///   · sudo-gated (`ELEVATION_REQUIRED` without a fresh password);
///   · the only admin must name a successor, who is promoted before they leave;
///   · the last active member's exit schedules the WHOLE family for removal;
///   · leaving clears the member's FUTURE days, frees the seat, keeps the PAST
///     (the name is preserved), and can be cancelled while a seat is free;
///   · `purge_expired_accounts` scrubs the e-mail (a member) or purges the whole
///     family (the last member) and returns the auth uid(s) for the cron.
///
/// Destructive scenarios run on throwaway families, so the shared fixture is
/// never mutated.
///
/// Port of `db-gate/Entrelares.IntegrationTests/AccountDeletionTests.cs`.
void accountDeletionTests(GateFixture fx) {
  Future<List<Member>> profilesOf(SupabaseClient who) async => [
        for (final row in await who.from('profiles').select())
          Member.fromJson(row)
      ];

  Future<Member> profileById(int id) async => Member.fromJson(
      (await fx.service.from('profiles').select().eq('id', id)).single);

  group('AccountDeletionTests', () {
    test('a deletion request without elevation is rejected', () async {
      // The detectable ELEVATION_REQUIRED contract, and no mutation.
      await fx.clearElevation(fx.memberProfile);

      await expectRejected(
        () => fx.member.rpc<dynamic>('request_account_deletion'),
        contains: 'ELEVATION_REQUIRED',
      );
    });

    test('the only admin must name a successor, who is promoted first',
        () async {
      final fam = await fx.createFamily('succ');

      // Without a successor → rejected, and no mutation.
      await fx.elevate(fam.adminProfile);
      await expectRejected(
          () => fam.admin.rpc<dynamic>('request_account_deletion'));
      expect((await profileById(fam.adminProfile.id)).leftAt, isNull);

      // With a successor → the member is promoted and the admin leaves.
      await fx.elevate(fam.adminProfile);
      await fam.admin.rpc<dynamic>('request_account_deletion',
          params: {'p_new_admin_id': fam.memberProfile.id});

      final all = await profilesOf(fam.member);
      expect(all.firstWhere((p) => p.id == fam.memberProfile.id).isAdmin, isTrue);
      expect(all.firstWhere((p) => p.id == fam.adminProfile.id).leftAt, isNotNull);
    });

    test('the last member leaving purges the whole family', () async {
      final fam = await fx.createFamily('lastm');

      // The member leaves first, leaving the admin as the sole active member.
      await fx.elevate(fam.memberProfile);
      await fam.member.rpc<dynamic>('request_account_deletion');

      // The admin — now the last member — leaves; no successor is needed.
      await fx.elevate(fam.adminProfile);
      await fam.admin.rpc<dynamic>('request_account_deletion');

      // Backdate both grace periods and run the purge.
      await fx.service.from('profiles').update({
        'deletion_scheduled_for': DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 1))
            .toIso8601String(),
      }).eq('family_id', fam.familyId);

      final result = await fx.service.rpc<dynamic>('purge_expired_accounts');

      // The whole family is gone, and both auth uids came back for the cron.
      expect(
          await fx.service.from('families').select().eq('id', fam.familyId),
          isEmpty);
      expect(result.toString(), contains(fam.adminProfile.userId));
      expect(result.toString(), contains(fam.memberProfile.userId));
    });

    test('leaving clears the future, frees the seat, and a cancel restores',
        () async {
      final fam = await fx.createFamily('leave');

      // A future planned day AND today's day for the leaving member — S-11 QA:
      // today counts as future and must be cleared too.
      final futureDay = addDays(today(), 20);
      final todayDay = today();
      for (final date in [futureDay, todayDay]) {
        await fam.admin.from('care_schedules').insert({
          'schedule_date': isoDate(date),
          'scheduled_parent_id': fam.memberProfile.id,
        });
      }

      await fx.elevate(fam.memberProfile);
      await fam.member.rpc<dynamic>('request_account_deletion');

      // Leaving state: left_at set, the 30-day schedule, and the seat freed.
      final members = await profilesOf(fam.admin);
      final leaver = members.firstWhere((p) => p.id == fam.memberProfile.id);
      expect(leaver.leftAt, isNotNull);
      expect(leaver.deletionScheduledFor, isNotNull);
      expect(members.where((p) => p.isActiveMember).length, 1);

      // Both the future day and today's day are gone.
      final days = (await fam.admin.from('care_schedules').select())
          .map((d) => d['schedule_date'])
          .toList();
      expect(days, isNot(contains(isoDate(futureDay))));
      expect(days, isNot(contains(isoDate(todayDay))));

      // The other member is notified in-app — transparency; the e-mail is the
      // best-effort twin, dispatched from the client.
      final adminNotifs = await fam.admin.from('notifications').select();
      expect(
        adminNotifs.where((n) =>
            n['type'] == 'account_deletion' &&
            n['recipient_profile_id'] == fam.adminProfile.id),
        isNotEmpty,
      );

      // A cancel restores membership, since a seat is still free.
      await fx.elevate(fam.memberProfile);
      await fam.member.rpc<dynamic>('cancel_account_deletion');
      final restored = await profileById(fam.memberProfile.id);
      expect(restored.leftAt, isNull);
      expect(restored.isActiveMember, isTrue);
    });

    test('colour slots are sticky, recycled on join, reassigned on return',
        () async {
      final fam = await fx.createFamily('slots');

      var members = await profilesOf(fam.admin);
      expect(members.firstWhere((p) => p.id == fam.adminProfile.id).colorSlot, 1);
      expect(members.firstWhere((p) => p.id == fam.memberProfile.id).colorSlot, 2);

      // The member leaves, keeping their stored slot; the admin is unchanged.
      await fx.elevate(fam.memberProfile);
      await fam.member.rpc<dynamic>('request_account_deletion');

      // A third person joins through the real invite flow → takes slot 2.
      final admin = AdminApi();
      final thirdEmail = fx.testEmail('slots-3rd');
      try {
        final token = await GateFixture.createInvitation(
            fam.admin, thirdEmail, fx.roleId('aunt'));
        await admin.createConfirmedUser(thirdEmail, fx.password, {
          'full_name': 'E2E Slots Third',
          'invite_token': token,
        });
      } finally {
        admin.close();
      }

      members = await profilesOf(fam.admin);
      expect(members.firstWhere((p) => p.email == thirdEmail).colorSlot, 2);
      expect(members.firstWhere((p) => p.id == fam.adminProfile.id).colorSlot, 1);

      // The departed member returns — their old colour is taken, so they get 3.
      await fx.elevate(fam.memberProfile);
      await fam.member.rpc<dynamic>('cancel_account_deletion');

      final returned = await profileById(fam.memberProfile.id);
      expect(returned.isActiveMember, isTrue);
      expect(returned.colorSlot, 3);
    });

    test('joining and returning both notify the other members', () async {
      // The fixture adds its member through the real invite flow, so the admin
      // must already have a member_joined notification.
      final fam = await fx.createFamily('notify');

      final joined = await fam.admin.from('notifications').select();
      expect(
        joined.where((n) =>
            n['type'] == 'member_joined' &&
            n['recipient_profile_id'] == fam.adminProfile.id),
        isNotEmpty,
      );

      await fx.elevate(fam.memberProfile);
      await fam.member.rpc<dynamic>('request_account_deletion');
      await fx.elevate(fam.memberProfile);
      await fam.member.rpc<dynamic>('cancel_account_deletion');

      final returned = await fam.admin.from('notifications').select();
      expect(
        returned.where((n) =>
            n['type'] == 'member_returned' &&
            n['recipient_profile_id'] == fam.adminProfile.id),
        isNotEmpty,
      );
    });

    test('a departed member is frozen: no edits, no day assignment', () async {
      final fam = await fx.createFamily('freeze');

      await fx.elevate(fam.memberProfile);
      await fam.member.rpc<dynamic>('request_account_deletion');

      await expectRejected(() => fam.admin.rpc<dynamic>('update_member_name',
          params: {
            'p_profile_id': fam.memberProfile.id,
            'p_full_name': 'Nome Novo',
          }));

      // Elevated on purpose, so the call reaches the frozen-row guard rather
      // than stopping at the sudo gate.
      await fx.elevate(fam.adminProfile);
      await expectRejected(() => fam.admin.rpc<dynamic>('set_member_admin',
          params: {
            'p_profile_id': fam.memberProfile.id,
            'p_is_admin': true,
          }));

      await expectRejected(() => fam.admin.from('care_schedules').insert({
            'schedule_date': isoDate(addDays(today(), 25)),
            'scheduled_parent_id': fam.memberProfile.id,
          }));

      final frozen = await profileById(fam.memberProfile.id);
      expect(frozen.isAdmin, isFalse);
      expect(frozen.fullName, fam.memberProfile.fullName);
    });

    test('the previous family surfaces only for a DEPARTED member', () async {
      // Cross-family migration: an active member's e-mail must yield nothing,
      // or the RPC would be a family-name oracle for any address.
      final fam = await fx.createFamily('xfam-name');
      final familyName = (await fx.service
              .from('families')
              .select('name')
              .eq('id', fam.familyId))
          .single['name'] as String;

      final active = await fx.service.rpc<dynamic>('departed_member_family',
          params: {'p_email': fam.memberProfile.email});
      expect(active.toString(), isNot(contains(familyName)));

      await fx.elevate(fam.memberProfile);
      await fam.member.rpc<dynamic>('request_account_deletion');

      final departed = await fx.service.rpc<dynamic>('departed_member_family',
          params: {'p_email': fam.memberProfile.email});
      expect(departed.toString(), contains(familyName));
    });

    test('purging a departed member on demand tombstones them when others '
        'remain', () async {
      final fam = await fx.createFamily('xfam-purge');
      final originalName = fam.memberProfile.fullName;
      final uid = fam.memberProfile.userId;

      await fx.elevate(fam.memberProfile);
      await fam.member.rpc<dynamic>('request_account_deletion');

      // The on-demand migration purge needs no grace backdating — the admin
      // still holds a seat, so the member is tombstoned, not the family.
      final result = await fx.service.rpc<dynamic>(
          'purge_departed_member_by_email',
          params: {'p_email': fam.memberProfile.email});
      expect(result.toString(), contains(uid));

      final purged = await profileById(fam.memberProfile.id);
      expect(purged.email, startsWith('removido+')); // freed for a new family
      expect(purged.fullName, originalName); // the name stays, for the history

      // The family and the admin survive.
      expect((await profileById(fam.adminProfile.id)).isActiveMember, isTrue);
    });

    test('a past grace scrubs the e-mail, keeps the name, returns the uid',
        () async {
      final fam = await fx.createFamily('purge');
      final originalName = fam.memberProfile.fullName;
      final uid = fam.memberProfile.userId;

      await fx.elevate(fam.memberProfile);
      await fam.member.rpc<dynamic>('request_account_deletion');

      // Backdate the grace so the purge picks it up now.
      await fx.service.from('profiles').update({
        'deletion_scheduled_for': DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 1))
            .toIso8601String(),
      }).eq('id', fam.memberProfile.id);

      final result = await fx.service.rpc<dynamic>('purge_expired_accounts');
      expect(result.toString(), contains(uid));

      final purged = await profileById(fam.memberProfile.id);
      expect(purged.email, startsWith('removido+'));
      expect(purged.fullName, originalName);
    });
  });
}
