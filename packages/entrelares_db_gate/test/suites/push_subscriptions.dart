import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// F-09 — the device registry, and the one rule that is NOT family-scoped.
///
/// Almost everything in this schema is visible to the whole family: the
/// calendar, the swap history, the audit trail. `push_subscriptions` is
/// deliberately the exception. A registration token is a capability to
/// interrupt someone's phone, and sharing a family is not consent to hold it —
/// so the policies are OWN ROWS ONLY, and these tests exist to keep a future
/// "make it consistent with the rest" refactor from quietly widening them.
///
/// The second half covers the dispatcher trigger. It fires on every
/// notification INSERT and, on a project with no Vault secrets, must do
/// nothing at all — quietly, without taking the INSERT down with it. That is
/// the state of the dev project this gate runs against, so what these tests
/// really pin is the fail-closed path: the one that runs everywhere until the
/// Firebase console work is done, and the one a broken push must fall back to.
void pushSubscriptionsTests(GateFixture fx) {
  /// The rows the service role sees for [profileId] — the truth, past RLS.
  Future<List<Map<String, dynamic>>> tokensOf(int profileId) async =>
      (await fx.service
              .from('push_subscriptions')
              .select()
              .eq('profile_id', profileId))
          .cast<Map<String, dynamic>>();

  Future<String> registerFor(
    SupabaseClient who,
    int profileId, {
    String platform = 'android',
  }) async {
    final token = 'e2e-${uniqueMarker()}';
    await who.from('push_subscriptions').insert({
      'profile_id': profileId,
      'token': token,
      'platform': platform,
    });
    return token;
  }

  group('PushSubscriptionsTests', () {
    test('a member registers a device for their own profile', () async {
      final token = await registerFor(fx.member, fx.memberProfile.id);

      final mine = await tokensOf(fx.memberProfile.id);
      expect(mine.map((r) => r['token']), contains(token));
      expect(mine.firstWhere((r) => r['token'] == token)['platform'], 'android');
    });

    test('a member cannot register a device for someone else', () async {
      await expectRejected(() => fx.member.from('push_subscriptions').insert({
            'profile_id': fx.founderProfile.id,
            'token': 'e2e-forged-${uniqueMarker()}',
            'platform': 'android',
          }));

      // Nothing was written under the founder's name.
      final founderTokens = await tokensOf(fx.founderProfile.id);
      expect(founderTokens.where((r) => (r['token'] as String).contains('forged')),
          isEmpty);
    });

    test("a member cannot read another caregiver's tokens", () async {
      await registerFor(fx.founder, fx.founderProfile.id);

      // RLS on SELECT does not throw — it returns nothing. Asserting emptiness
      // is the only assertion that can tell the two apart.
      final seen = await fx.member
          .from('push_subscriptions')
          .select('token')
          .eq('profile_id', fx.founderProfile.id);
      expect(seen, isEmpty);
    });

    test("a member cannot move another caregiver's token to themselves",
        () async {
      final victim = await registerFor(fx.founder, fx.founderProfile.id);

      // An UPDATE the client may not make does NOT throw — it matches 0 rows,
      // and PostgREST answers success. So the assertion is on the ROW, read
      // back with the service client.
      await fx.member
          .from('push_subscriptions')
          .update({'profile_id': fx.memberProfile.id}).eq('token', victim);

      final row = (await fx.service
              .from('push_subscriptions')
              .select('profile_id')
              .eq('token', victim))
          .single;
      expect(row['profile_id'], fx.founderProfile.id,
          reason: 'the token was re-pointed at another profile');
    });

    test("a member cannot delete another caregiver's device", () async {
      final victim = await registerFor(fx.founder, fx.founderProfile.id);

      await fx.member.from('push_subscriptions').delete().eq('token', victim);

      final still = await fx.service
          .from('push_subscriptions')
          .select('token')
          .eq('token', victim);
      expect(still, hasLength(1), reason: 'the device was unregistered by someone else');
    });

    test('a member unregisters their own device', () async {
      final token = await registerFor(fx.member, fx.memberProfile.id);
      await fx.member.from('push_subscriptions').delete().eq('token', token);

      final gone =
          await fx.service.from('push_subscriptions').select('token').eq('token', token);
      expect(gone, isEmpty);
    });

    test('the same token cannot be registered twice', () async {
      final token = await registerFor(fx.member, fx.memberProfile.id);

      // UNIQUE on the token, not on (profile, token): a device belongs to one
      // account at a time, and a token that moved to another sign-in must not
      // leave the old row behind to receive the previous user's notices.
      await expectRejected(() => fx.founder.from('push_subscriptions').insert({
            'profile_id': fx.founderProfile.id,
            'token': token,
            'platform': 'android',
          }));
    });

    test('an unknown platform is refused', () async {
      await expectRejected(() => fx.member.from('push_subscriptions').insert({
            'profile_id': fx.memberProfile.id,
            'token': 'e2e-${uniqueMarker()}',
            'platform': 'symbian',
          }));
    });

    test('the dispatcher never fails the notification it rides on', () async {
      // The whole point of the AFTER trigger being async and swallowing its own
      // errors: on this project there are no Vault secrets, so the dispatcher
      // returns without doing anything. If it ever raised instead, THIS insert
      // is what would start failing — and with it every swap in the product.
      final marker = uniqueMarker();
      await fx.service.from('notifications').insert({
        'recipient_profile_id': fx.memberProfile.id,
        'type': 'swap_requested',
        'title': 'Nova solicitação de troca',
        'message': 'gate $marker',
        'params': {'date': '2026-12-24', 'proposed': 'target', 'name': 'QA'},
      });

      final written = await fx.service
          .from('notifications')
          .select('id')
          .eq('recipient_profile_id', fx.memberProfile.id)
          .eq('message', 'gate $marker');
      expect(written, hasLength(1));
    });

    test('a non-pushable notification is written just the same', () async {
      final marker = uniqueMarker();
      await fx.service.from('notifications').insert({
        'recipient_profile_id': fx.memberProfile.id,
        'type': 'member_joined',
        'title': 'Novo responsável na família',
        'message': 'gate $marker',
        'params': {'name': 'QA'},
      });

      final written = await fx.service
          .from('notifications')
          .select('id')
          .eq('recipient_profile_id', fx.memberProfile.id)
          .eq('message', 'gate $marker');
      expect(written, hasLength(1));
    });
  });
}
