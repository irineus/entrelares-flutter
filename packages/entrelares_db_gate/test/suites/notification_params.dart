import 'dart:convert';

import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

/// U-13 — the half of the notification renderer that lives in the DATABASE.
///
/// The client-side rendering rules are pinned by the app's own unit suite, but
/// they are worthless if the trigger does not actually WRITE the payload they
/// read. That is the seam this suite covers, and it is a seam no unit test can
/// reach: `params` is filled by `auto_approve_expired()` inside PostgreSQL.
///
/// It deliberately asserts the DATA and not the sentence: the stored
/// title/message stay PT-BR by design — they are the fallback for legacy rows —
/// so asserting text here would pin the wrong thing.
///
/// Port of `db-gate/Entrelares.IntegrationTests/NotificationParamsTests.cs`.
void notificationParamsTests(GateFixture fx) {
  /// Offsets are ~43-47 DAYS back, not hours: the shared family is seeded by
  /// several suites and a few days back is crowded (108 h and 156 h passed alone
  /// and collided in the full CI pack). The rule applies — a test that never
  /// renders the day cell should go FAR past, out of every in-month helper's
  /// range by construction.
  ///
  /// Mirrors the auto-approval suite: the RPC computes expiry as
  /// `schedule_date + handoff` in `America/Sao_Paulo` (fixed UTC-3), so this
  /// lands the expiry a controlled number of hours in the past.
  (DateTime date, String handoff) expiryHoursAgo(double hoursAgo) {
    final sp = DateTime.now()
        .toUtc()
        .subtract(Duration(minutes: (3 * 60 + hoursAgo * 60).round()));
    return (DateTime(sp.year, sp.month, sp.day), isoTime(sp));
  }

  Future<(int requestId, DateTime date)> seedExpiredSwap(
      double hoursAgo) async {
    final (date, handoff) = expiryHoursAgo(hoursAgo);

    final schedule = CareSchedule.fromJson((await fx.service
            .from('care_schedules')
            .insert({
              'schedule_date': isoDate(date),
              'scheduled_parent_id': fx.founderProfile.id,
            })
            .select())
        .single);

    final request = SwapRequest.fromJson((await fx.service
            .from('swap_requests')
            .insert({
              'schedule_date': isoDate(date),
              'schedule_id': schedule.id,
              'requesting_profile_id': fx.memberProfile.id,
              'target_profile_id': fx.founderProfile.id,
              'previous_actual_parent_id': null,
              'proposed_actual_parent_id': fx.memberProfile.id,
              'proposed_handoff_time': handoff,
              'status': 'pending',
            })
            .select())
        .single);

    return (request.id, date);
  }

  Future<List<AppNotification>> notificationsFor(int requestId) async => [
        for (final row in await fx.service
            .from('notifications')
            .select()
            .eq('swap_request_id', requestId))
          AppNotification.fromJson(row)
      ];

  /// Reads through `paramsJson` on purpose — that is the exact string the client
  /// renderer receives, so a serialization break shows up HERE rather than on
  /// somebody's screen.
  Map<String, dynamic> paramsOf(AppNotification n) {
    expect(n.paramsJson, isNotNull,
        reason: "notification '${n.type}' was written without params — "
            'the client cannot localize it');
    return jsonDecode(n.paramsJson!) as Map<String, dynamic>;
  }

  group('NotificationParamsTests', () {
    test('auto-approval writes render params on every notification it makes',
        () async {
      final (requestId, date) = await seedExpiredSwap(24 * 45);

      await fx.service.rpc<dynamic>('auto_approve_expired',
          params: {'p_env_prefix': '[Dev] '});

      final notifications = await notificationsFor(requestId);
      // U-24: ISO 8601, not a rendered date. `params` carries DATA so the
      // reader's device can write the day in the reader's own format — storing
      // `05/08` here is exactly what told an English reader May 8th.
      final expectedDate = isoDate(date);

      // BOTH parties are notified under the SAME type with DIFFERENT copy, so
      // `role` is what keeps the renderer from handing each the other's
      // sentence. Its absence would be invisible until a user read it.
      final approved =
          notifications.where((n) => n.type == 'auto_approved').toList();
      expect(approved, hasLength(2));

      final roles = [for (final n in approved) paramsOf(n)['role'] as String]
        ..sort();
      expect(roles, ['approver', 'requester']);

      for (final n in approved) {
        expect(paramsOf(n)['date'], expectedDate);
      }

      // F-28 fan-out: carries the date, the swap/revert discriminator and the
      // caregiver's NAME as user data — never translated downstream.
      final fanout =
          notifications.where((n) => n.type == 'swap_family_info').toList();
      if (fanout.isNotEmpty) {
        final p = paramsOf(fanout.single);
        expect(p['date'], expectedDate);
        expect(p['kind'], 'auto_swap');
        expect(p['name'], fx.memberProfile.fullName);
      }
    });

    // NOTE — the 24 h REMINDER payload is asserted inside the auto-approval
    // suite, not here, and that is deliberate. The reminder only fires between
    // 24 h and 48 h before now, so its seed CANNOT be moved far into the past
    // like the two around it. That window is barely two calendar days wide, and
    // the shared family already spends both on the auto-approval suite's own
    // cases — any value this suite picked would sit within 24 h of one of them
    // and share its date, which is the (family_id, schedule_date) collision the
    // CI pack caught twice.

    test('a member joining writes the NAME as render data', () async {
      // A SECOND writer, proven end to end through a real flow. Why this one and
      // not `request_account_deletion` or the family-deletion RPCs: those are
      // destructive (they leave the family, or schedule its erasure) and demand
      // sudo, so exercising them in the shared family would dismantle it.
      // `notify_member_joined` is the opposite — an AFTER INSERT trigger on
      // profiles, so simply completing an invitation fires it, and a THROWAWAY
      // family keeps it off family A.
      final family = await fx.createFamily('u13notif');

      final joined = [
        for (final row in await fx.service
            .from('notifications')
            .select()
            .eq('recipient_profile_id', family.adminProfile.id)
            .eq('type', 'member_joined'))
          AppNotification.fromJson(row)
      ];
      expect(joined, hasLength(1));

      // The NAME, not the sentence: the admin may read the app in a different
      // language from the person who joined, and a name is user data that passes
      // through untranslated in either one.
      expect(paramsOf(joined.single)['name'], family.memberProfile.fullName);

      // The PT-BR fallback still stands for clients that predate the item.
      expect(joined.single.message, contains(family.memberProfile.fullName));
    });

    test('the stored sentence is still written alongside params', () async {
      // It is the fallback for every row written before U-13, and for any client
      // that does not yet know a newer type. Writing params must never come at
      // the cost of the text that keeps history readable.
      final (requestId, _) = await seedExpiredSwap(24 * 47);

      await fx.service.rpc<dynamic>('auto_approve_expired',
          params: {'p_env_prefix': '[Dev] '});

      for (final n in await notificationsFor(requestId)) {
        expect(n.title, isNotEmpty);
        expect(n.message, isNotEmpty);
      }
    });
  });
}
