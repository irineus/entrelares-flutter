import 'dart:convert';

import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// U-17 — the `register-invitee` Edge Function: an invitee signs up through a
/// valid token and comes out PRE-CONFIRMED (immediate sign-in, no confirmation
/// e-mail), while garbage tokens and weak passwords are refused.
///
/// It calls the DEPLOYED function on the dev project with the ANON key —
/// exactly what the register screen does, header shape included (S-16: the key
/// format decides whether the key rides on `Authorization` too, so the request
/// is hand-built rather than handed to a convenience wrapper).
///
/// Port of `db-gate/Entrelares.IntegrationTests/RegisterInviteeTests.cs`.
void registerInviteeTests(GateFixture fx) {
  final endpoint = Uri.parse(
      '${TestEnv.supabaseUrl.replaceAll(RegExp(r'/+$'), '')}/functions/v1/register-invitee');

  Future<(int status, String body)> call(Map<String, dynamic> payload) async {
    final response = await http.post(
      endpoint,
      headers: {
        ...TestEnv.keyHeaders(TestEnv.anonKey),
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );
    return (response.statusCode, response.body);
  }

  /// Calls the function repeatedly until the response reaches its TERMINAL state
  /// ([settled]) or the attempts run out, returning the last response either
  /// way.
  ///
  /// The cross-family migration touches GoTrue's Admin API (create and delete
  /// user) and a DB teardown spanning two families — several of those steps are
  /// only EVENTUALLY consistent, so a single call can catch a transient
  /// in-between status. Polling to the terminal state absorbs that lag WITHOUT
  /// weakening the test: when the terminal state genuinely never arrives (a real
  /// regression), the loop exhausts and the caller's assertions fail on the last,
  /// wrong response. Same spirit as the fixture's 429 sign-in backoff.
  Future<(int status, String body)> callUntil(
    Map<String, dynamic> payload,
    bool Function(int status, String body) settled, {
    int attempts = 10,
    int delayMs = 750,
  }) async {
    var last = (0, '');
    for (var attempt = 0; attempt < attempts; attempt++) {
      last = await call(payload);
      if (settled(last.$1, last.$2)) return last;
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
    return last;
  }

  group('RegisterInviteeTests', () {
    test('a valid token creates a CONFIRMED user who can sign in at once',
        () async {
      final email = fx.testEmail('autoconfirm');
      final auntId = fx.roleId('aunt');
      final token =
          await GateFixture.createInvitation(fx.founderB, email, auntId);

      final (status, _) = await call({
        'token': token,
        'fullName': 'E2E Autoconfirm',
        'password': fx.password,
      });
      expect(status, 200);

      // Pre-confirmed: sign-in succeeds with no confirmation step. With an
      // unconfirmed account GoTrue would refuse with "Email not confirmed".
      final client = await fx.signIn(email);
      expect(client.auth.currentUser, isNotNull);

      final profile = Member.fromJson(
          (await fx.service.from('profiles').select().eq('email', email))
              .single);
      expect(profile.familyId, fx.familyBId);
      expect(profile.roleId, auntId);
      expect(profile.isAdmin, isFalse);
    });

    test('a departed member invited elsewhere is warned, then migrated on '
        'consent', () async {
      // S-11 cross-family migration.
      final famA = await fx.createFamily('xmig-a');
      final famB = await fx.createFamily('xmig-b');
      final email = famA.memberProfile.email!;
      final famAName = (await fx.service
              .from('families')
              .select('name')
              .eq('id', famA.familyId))
          .single['name'] as String;

      // The member leaves family A — the admin stays active, so this is a
      // tombstone rather than a purge.
      await fx.elevate(famA.memberProfile);
      await famA.member.rpc<dynamic>('request_account_deletion');

      // Invited to family B, which is allowed: they are no longer active in A.
      final auntId = fx.roleId('aunt');
      final token =
          await GateFixture.createInvitation(famB.admin, email, auntId);

      // First attempt, no consent → warned, and nothing created yet. The warn
      // call creates nothing, so it is safe to poll: retry through the transient
      // window — a 400 while the fresh invitation or the just-departed member
      // are not yet visible to the function's read, or a 409 that is the plain
      // "already registered" rejection before the departed-member view is
      // consistent — until it settles on 409 + needsMigration.
      final warnPayload = {
        'token': token,
        'fullName': 'E2E Migrante',
        'password': fx.password,
      };
      final (warnStatus, warnBody) = await callUntil(
        warnPayload,
        (status, body) => status == 409 && body.contains('needsMigration'),
        attempts: 15,
        delayMs: 1000, // ~15 s: invitation / departed-member visibility
      );
      expect(warnStatus, 409);
      expect(warnBody, contains('needsMigration'));
      expect(warnBody, contains(famAName));

      // Consent given → the old registration is erased and the new account
      // created. A non-OK response means nothing was created (createUser
      // errored), so polling never double-creates.
      //
      // GoTrue's delete-old-user → create-new-user with the SAME e-mail is
      // eventually consistent: after the erase, createUser can keep 409-ing for
      // longer than a few seconds under load. This gets the most generous
      // window — the account is created on the FIRST 200 and the loop stops, so
      // the long budget only ever spends on a genuinely slow GoTrue, never on
      // the happy path.
      final (okStatus, _) = await callUntil(
        {...warnPayload, 'confirmMigration': true},
        (status, _) => status == 200,
        attempts: 24,
        delayMs: 1250, // ~30 s ceiling for GoTrue re-registration lag
      );
      expect(okStatus, 200);

      // The e-mail now belongs to a fresh profile in family B; the family-A
      // profile was tombstoned — e-mail freed, name kept for the history.
      final inB = [
        for (final row in await fx.service
            .from('profiles')
            .select()
            .eq('family_id', famB.familyId))
          Member.fromJson(row)
      ];
      expect(inB.where((p) => p.email == email && p.roleId == auntId),
          isNotEmpty);

      final oldProfile = Member.fromJson((await fx.service
              .from('profiles')
              .select()
              .eq('id', famA.memberProfile.id))
          .single);
      expect(oldProfile.email, startsWith('removido+'));

      // Sign-in works on the new account.
      final client = await fx.signIn(email);
      expect(client.auth.currentUser, isNotNull);
    });

    test('a garbage token creates nothing and leaks nothing', () async {
      final (status, body) = await call({
        'token': '11111111-2222-4333-8444-555555555555',
        'fullName': 'E2E Nobody',
        'password': fx.password,
      });
      expect(status, 400);
      expect(body, contains('Convite inválido'));
    });

    // T-32: MALFORMED tokens — shapes that are not valid UUIDs, SQL-ish strings,
    // path traversal — must be refused GRACEFULLY: no 500, no leak, no account.
    // Two layers reject them: the function maps an invalid uuid cast to the
    // friendly "Convite inválido" (400), while attack-signature payloads (SQL
    // injection, path traversal) are stopped earlier by the platform edge/WAF
    // with a 403, before the function even runs. Either way it is a safe
    // client-error refusal — assert on that, and check the friendly body only on
    // the 400 (function) path.
    for (final token in const [
      'not-a-uuid',
      "'; DROP TABLE family_invitations; --",
      '00000000-0000-0000-0000-00000000000Z', // wrong UUID character
      '../../etc/passwd',
      '<script>alert(1)</script>',
    ]) {
      test('a malformed token is refused gracefully: $token', () async {
        final (status, body) = await call({
          'token': token,
          'fullName': 'E2E Malformed',
          'password': fx.password,
        });
        expect(status, anyOf(400, 403),
            reason: 'expected a 4xx refusal (400 from the function or 403 from '
                'the edge/WAF), got $status');
        if (status == 400) expect(body, contains('Convite inválido'));
      });
    }

    test('a weak password is refused', () async {
      // The Admin API bypasses the sign-up password policy, so the function
      // enforces the register form's 8-character minimum itself.
      final email = fx.testEmail('weakpass');
      final token = await GateFixture.createInvitation(
          fx.founderB, email, fx.roles.first.id);

      final (status, body) = await call({
        'token': token,
        'fullName': 'E2E Weak',
        'password': '1234567',
      });
      expect(status, 400);
      expect(body, contains('8 caracteres'));

      // Clean up the open invitation so it does not hold a family-B seat.
      final invitation = (await fx.service
              .from('family_invitations')
              .select('id')
              .eq('token', token))
          .single;
      await fx.founderB.rpc<dynamic>('revoke_invitation',
          params: {'p_invitation_id': invitation['id']});
    });
  });
}
