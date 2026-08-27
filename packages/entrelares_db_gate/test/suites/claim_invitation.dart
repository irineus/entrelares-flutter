import 'dart:convert';

import 'package:entrelares_core/entrelares_core.dart';
import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

/// F-57 — the `claim-invitation` Edge Function: an EXISTING (social-login)
/// session attaches itself to a family through a valid invitation.
///
/// It is register-invitee's mirror image — same token capability, same S-11
/// cross-family migration — for a caller who already has an auth user (the
/// OAuth redirect created it, or automatic linking landed them on their old
/// one) and no profile. Identity comes from the JWT: the suite signs the
/// throwaway user in and sends the session's access token, exactly like the
/// app will.
void claimInvitationTests(GateFixture fx) {
  final endpoint = Uri.parse(
      '${TestEnv.supabaseUrl.replaceAll(RegExp(r'/+$'), '')}/functions/v1/claim-invitation');

  Future<(int status, String body)> call(
    String? jwt,
    Map<String, dynamic> payload,
  ) async {
    final response = await http.post(
      endpoint,
      headers: {
        // S-16 header shape for the gateway key, then the USER's session token
        // on Authorization — the platform's verify_jwt gate reads it there.
        ...TestEnv.keyHeaders(TestEnv.anonKey),
        if (jwt != null) 'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );
    return (response.statusCode, response.body);
  }

  String jwtOf(SupabaseClient client) => client.auth.currentSession!.accessToken;

  /// Same polling rationale as RegisterInviteeTests: the invitation and the
  /// departed-member view are eventually consistent with the function's reads.
  Future<(int status, String body)> callUntil(
    String jwt,
    Map<String, dynamic> payload,
    bool Function(int status, String body) settled, {
    int attempts = 10,
    int delayMs = 750,
  }) async {
    var last = (0, '');
    for (var attempt = 0; attempt < attempts; attempt++) {
      last = await call(jwt, payload);
      if (settled(last.$1, last.$2)) return last;
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
    return last;
  }

  // The destination is a THROWAWAY family (2 members, inside its 30-day
  // trial, so a third seat is grantable) — never the shared family B:
  // RegisterInviteeTests already parks two joins there, and more here would
  // put the shared family at the max_caregivers cap for whoever runs next.
  // ONE destination serves the whole suite (seats = active members + PENDING
  // invitations, so the refusal tests revoke theirs on the way out).
  ThrowawayFamily? sharedDest;
  Future<ThrowawayFamily> destFamily() async =>
      sharedDest ??= await fx.createFamily('claim-dst');

  Future<void> revokeInvitation(String token) async {
    await fx.service
        .from('family_invitations')
        .update({'revoked_at': DateTime.now().toUtc().toIso8601String()})
        .eq('token', token);
  }

  group('ClaimInvitationTests', () {
    test('a valid claim attaches the OAuth session to the family', () async {
      final dest = await destFamily();
      final email = await fx.createOauthUser('claim-ok');
      final client = await fx.signIn(email);
      final auntId = fx.roleId('aunt');
      final token =
          await GateFixture.createInvitation(dest.admin, email, auntId);

      final (status, body) = await callUntil(
        jwtOf(client),
        {
          'token': token,
          'fullName': 'E2E Claim OK',
          'policyVersion': PolicyVersions.current,
        },
        (status, _) => status == 200,
      );
      expect(status, 200, reason: body);

      final me = Member.fromJson(
          (await client.from('profiles').select().eq('email', email)).single);
      expect(me.familyId, dest.familyId);
      expect(me.roleId, auntId);
      expect(me.isAdmin, isFalse);
      expect(me.joinedViaInvite, isTrue);
      expect(me.consentPolicyVersion, PolicyVersions.current,
          reason: 'S-13: consent stamped at creation');

      // A replay is refused — the caller is already attached (that guard runs
      // before the consumed token is even looked at).
      final (replay, replayBody) = await call(jwtOf(client), {
        'token': token,
        'fullName': 'E2E Claim OK',
        'policyVersion': PolicyVersions.current,
      });
      expect(replay, 400, reason: replayBody);
      expect(replayBody, contains('já está vinculada'));
    });

    test("a token issued for ANOTHER e-mail never attaches this session",
        () async {
      final dest = await destFamily();
      final email = await fx.createOauthUser('claim-thief');
      final client = await fx.signIn(email);
      final token = await GateFixture.createInvitation(
          dest.admin, fx.testEmail('claim-victim'), fx.roleId('aunt'));

      final (status, body) = await call(jwtOf(client), {
        'token': token,
        'fullName': 'E2E Thief',
        'policyVersion': PolicyVersions.current,
      });
      expect(status, 400, reason: body);
      expect(body, contains('Convite inválido'));

      final rows =
          await fx.service.from('profiles').select().eq('email', email);
      expect(rows, isEmpty, reason: 'a stolen token alone attaches nobody');

      await revokeInvitation(token);
    });

    test('a stale policy version is refused and nothing is created', () async {
      final dest = await destFamily();
      final email = await fx.createOauthUser('claim-stale');
      final client = await fx.signIn(email);
      final token = await GateFixture.createInvitation(
          dest.admin, email, fx.roleId('aunt'));

      final (status, body) = await call(jwtOf(client), {
        'token': token,
        'fullName': 'E2E Claim Stale',
        'policyVersion': '2020-01-01',
      });
      expect(status, 400, reason: body);
      expect(body, contains('Versão da política desatualizada'));

      final rows =
          await fx.service.from('profiles').select().eq('email', email);
      expect(rows, isEmpty);

      await revokeInvitation(token);
    });

    test('no session token → the platform gate refuses before our code runs',
        () async {
      final (status, _) = await call(null, {
        'token': '11111111-2222-4333-8444-555555555555',
        'fullName': 'E2E Nobody',
        'policyVersion': PolicyVersions.current,
      });
      // verify_jwt: with only the anon apikey (new-format keys send no
      // Authorization at all; legacy sends the anon JWT, which carries no user)
      // the platform or the function refuses with a 401.
      expect(status, 401);
    });

    test('a departed member is warned, then migrated on consent — and their '
        'session SURVIVES', () async {
      // S-11 adapted to automatic account linking: the departed member signing
      // in with Google lands on their EXISTING auth user, so the migration must
      // detach the old tombstoned profile instead of deleting the caller.
      final famA = await fx.createFamily('oaumig');
      final email = famA.memberProfile.email!;
      final famAName = (await fx.service
              .from('families')
              .select('name')
              .eq('id', famA.familyId))
          .single['name'] as String;

      // The member leaves family A — the admin stays, so this is a tombstone
      // departure, not a family purge.
      await fx.elevate(famA.memberProfile);
      await famA.member.rpc<dynamic>('request_account_deletion');

      // Invited to a fresh destination family — allowed: they are no longer
      // active in A. (Throwaway destination for the same seat-economy reason
      // as the happy path.)
      final dest = await fx.createFamily('oaumig-dst');
      final auntId = fx.roleId('aunt');
      final token =
          await GateFixture.createInvitation(dest.admin, email, auntId);

      final jwt = jwtOf(famA.member);
      final basePayload = {
        'token': token,
        'fullName': 'E2E OAuth Migrante',
        'policyVersion': PolicyVersions.current,
      };

      // No consent yet → warned with the previous family's name, and nothing
      // was created or destroyed.
      final (warnStatus, warnBody) = await callUntil(
        jwt,
        basePayload,
        (status, body) => status == 409 && body.contains('needsMigration'),
        attempts: 15,
        delayMs: 1000,
      );
      expect(warnStatus, 409, reason: warnBody);
      expect(warnBody, contains('needsMigration'));
      expect(warnBody, contains(famAName));

      // Consent given → old registration erased, new profile in the
      // destination family.
      final (okStatus, okBody) = await callUntil(
        jwt,
        {...basePayload, 'confirmMigration': true},
        (status, _) => status == 200,
        attempts: 15,
        delayMs: 1000,
      );
      expect(okStatus, 200, reason: okBody);

      // Old profile: tombstoned (e-mail freed, name kept) and DETACHED from
      // the surviving auth user.
      final oldProfile = Member.fromJson((await fx.service
              .from('profiles')
              .select()
              .eq('id', famA.memberProfile.id))
          .single);
      expect(oldProfile.email, startsWith('removido+'));
      expect(oldProfile.userId, isNull,
          reason: 'the caller keeps their auth user — the old profile lets go');

      // New profile: the destination family, through the invitation's role.
      final inDest = [
        for (final row in await fx.service
            .from('profiles')
            .select()
            .eq('family_id', dest.familyId))
          Member.fromJson(row)
      ];
      expect(inDest.where((p) => p.email == email && p.roleId == auntId),
          isNotEmpty);

      // And the session that made the claim still works — the whole point of
      // the detach-instead-of-delete design.
      final freshRead =
          await famA.member.from('profiles').select().eq('email', email);
      expect(freshRead, isNotEmpty);
    });
  });
}
