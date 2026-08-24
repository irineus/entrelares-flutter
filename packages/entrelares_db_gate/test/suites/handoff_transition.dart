import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// T-45 — the T-27 invariant as a DATABASE rule: a handoff time belongs only on
/// a TRANSITION day, one whose effective responsible differs from the previous
/// day's. Before this item the rule lived in the client and only looked
/// backwards on manual saves, so an approved swap on day D left D+1 with a
/// handoff time on a day where nobody hands the child over — and a revert could
/// not put it back, because nothing recorded the removal.
///
/// These tests exercise the REAL write paths — an approval applied by the
/// request's target, the `auto_approve_expired` RPC, the revert applied by the
/// revert's target — never a shortcut: the rule is worth nothing if it only
/// holds for the way the test writes.
///
/// Port of `db-gate/Entrelares.IntegrationTests/HandoffTransitionTests.cs`.
void handoffTransitionTests(GateFixture fx) {
  const sixPm = '18:00:00';

  /// The founder owns D, the member owns D+1 at 18:00 — a genuine transition,
  /// so the time survives the insert. Returns the two dates.
  Future<(DateTime d, DateTime next)> seedTransitionPair() async {
    final dates = fx.nextFutureDates(2);

    await fx.founder.from('care_schedules').insert({
      'schedule_date': isoDate(dates[0]),
      'scheduled_parent_id': fx.founderProfile.id,
    });
    await fx.founder.from('care_schedules').insert({
      'schedule_date': isoDate(dates[1]),
      'scheduled_parent_id': fx.memberProfile.id,
      'handoff_time': sixPm,
    });

    expect((await readDay(fx.founder, dates[1])).handoffTime, sixPm);
    return (dates[0], dates[1]);
  }

  /// The member asks for day D; the founder is the approver, which is what lets
  /// the day-protection trigger accept the `actual_parent` change.
  Future<SwapRequest> openPendingSwap(DateTime date, int scheduleId) async =>
      SwapRequest.fromJson((await fx.member
              .from('swap_requests')
              .insert({
                'schedule_date': isoDate(date),
                'schedule_id': scheduleId,
                'requesting_profile_id': fx.memberProfile.id,
                'target_profile_id': fx.founderProfile.id,
                'previous_actual_parent_id': null,
                'proposed_actual_parent_id': fx.memberProfile.id,
                'status': 'pending',
              })
              .select())
          .single);

  Future<void> resolve(SwapRequest request, String status) async {
    await fx.founder.from('swap_requests').update({
      'status': status,
      'resolved_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', request.id);
  }

  /// The approval, exactly as the app's approve flow performs it: the TARGET
  /// applies the calendar change with a full-row update, then resolves.
  Future<void> approveSwapTo(DateTime d, int newActualParentId) async {
    final day = await readDay(fx.founder, d);
    await saveDay(fx.founder, day.copyWith(actualParentId: newActualParentId));
  }

  group('HandoffTransitionTests', () {
    test("an approval clears the handoff of a next day that stopped being a "
        'transition', () async {
      // The gap the item was opened for.
      final (d, next) = await seedTransitionPair();
      final day = await readDay(fx.founder, d);
      final request = await openPendingSwap(d, day.id);

      await approveSwapTo(d, fx.memberProfile.id);
      await resolve(request, 'approved');

      // D and D+1 are now both the member's: nobody hands over at 18:00.
      expect((await readDay(fx.founder, next)).handoffTime, isNull);
    });

    test("a revert gives the next day's handoff back", () async {
      // The other half: reverting makes D+1 a transition again, and the time the
      // approval took away comes back — the PARKED value, not a guess.
      final (d, next) = await seedTransitionPair();
      final day = await readDay(fx.founder, d);
      final request = await openPendingSwap(d, day.id);

      await approveSwapTo(d, fx.memberProfile.id);
      await resolve(request, 'approved');
      expect((await readDay(fx.founder, next)).handoffTime, isNull);

      // The revert request: the founder (the planned parent) asks, so the
      // approver — and the one who applies the restore — is the member.
      final revert = SwapRequest.fromJson((await fx.founder
              .from('swap_requests')
              .insert({
                'schedule_date': isoDate(d),
                'schedule_id': day.id,
                'requesting_profile_id': fx.founderProfile.id,
                'target_profile_id': fx.memberProfile.id,
                'previous_actual_parent_id': fx.memberProfile.id,
                'proposed_actual_parent_id': fx.founderProfile.id,
                'status': 'revert_pending',
              })
              .select())
          .single);

      final toRestore = await readDayById(fx.member, day.id);
      await saveDay(fx.member, toRestore.copyWith(actualParentId: null));
      await fx.member.from('swap_requests').update({
        'status': 'revert_approved',
        'resolved_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', revert.id);

      expect((await readDay(fx.founder, next)).handoffTime, sixPm);
    });

    test("auto-approval clears the next day's handoff", () async {
      // The server-side resolution path (F-24) goes through the same DB rule —
      // it is a trigger, not something the approve flow remembers to do.
      //
      // Far enough in the past to be long expired, and far from the dates the
      // auto-approval suite backdates (~2–4 days ago): the RPC resolves EVERY
      // expired request in the project, so the seeds must not overlap.
      final expiry =
          DateTime.now().toUtc().subtract(const Duration(days: 9, hours: 3));
      final d = DateTime(expiry.year, expiry.month, expiry.day);
      final next = addDays(d, 1);

      final day = CareSchedule.fromJson((await fx.service
              .from('care_schedules')
              .insert({
                'schedule_date': isoDate(d),
                'scheduled_parent_id': fx.founderProfile.id,
              })
              .select())
          .single);
      final nextDay = CareSchedule.fromJson((await fx.service
              .from('care_schedules')
              .insert({
                'schedule_date': isoDate(next),
                'scheduled_parent_id': fx.memberProfile.id,
                'handoff_time': sixPm,
              })
              .select())
          .single);

      await fx.service.from('swap_requests').insert({
        'schedule_date': isoDate(d),
        'schedule_id': day.id,
        'requesting_profile_id': fx.memberProfile.id,
        'target_profile_id': fx.founderProfile.id,
        'previous_actual_parent_id': null,
        'proposed_actual_parent_id': fx.memberProfile.id,
        'proposed_handoff_time': isoTime(expiry),
        'status': 'pending',
      });

      await fx.service
          .rpc<dynamic>('auto_approve_expired', params: {'p_env_prefix': '[Dev] '});

      // By ID, not by date: the service client bypasses RLS, so a date filter
      // would also pick up other families' days.
      final afterNext = await readDayById(fx.service, nextDay.id);
      expect(afterNext.handoffTime, isNull);
    });

    test('a next day that stays a transition keeps its handoff', () async {
      // The rule only removes what became meaningless. (The inverse case — a
      // swap that CREATES a transition at D+1 — is deliberately left alone:
      // there is no time to invent.)
      final third = await fx.ensureThirdMember();
      final dates = fx.nextFutureDates(2);

      await fx.founder.from('care_schedules').insert({
        'schedule_date': isoDate(dates[0]),
        'scheduled_parent_id': fx.founderProfile.id,
      });
      await fx.founder.from('care_schedules').insert({
        'schedule_date': isoDate(dates[1]),
        'scheduled_parent_id': third.id,
        'handoff_time': sixPm,
      });

      final day = await readDay(fx.founder, dates[0]);
      final request = await openPendingSwap(dates[0], day.id);

      // founder → member, which is still ≠ the third caregiver on D+1.
      await approveSwapTo(dates[0], fx.memberProfile.id);
      await resolve(request, 'approved');

      expect((await readDay(fx.founder, dates[1])).handoffTime, sixPm);
    });

    test('an explicit handoff write replaces the parked value', () async {
      // A time written by hand is INTENT and outranks whatever the rule parked
      // earlier: the revert must give back the time the family last chose, never
      // resurrect the one it replaced.
      final (d, next) = await seedTransitionPair();
      final day = await readDay(fx.founder, d);
      final request = await openPendingSwap(d, day.id);

      await approveSwapTo(d, fx.memberProfile.id);
      await resolve(request, 'approved');
      expect((await readDay(fx.founder, next)).handoffTime, isNull);

      // The family sets a NEW time on D+1 while it is NOT a transition — the
      // rule parks this one instead, so it never lands on the day.
      final nextDay = await readDay(fx.founder, next);
      await saveDay(fx.founder, nextDay.copyWith(handoffTime: '20:00:00'));
      expect((await readDay(fx.founder, next)).handoffTime, isNull);

      // Undo the swap: D+1 is a transition again, and gets 20:00, not 18:00.
      final revert = SwapRequest.fromJson((await fx.founder
              .from('swap_requests')
              .insert({
                'schedule_date': isoDate(d),
                'schedule_id': day.id,
                'requesting_profile_id': fx.founderProfile.id,
                'target_profile_id': fx.memberProfile.id,
                'previous_actual_parent_id': fx.memberProfile.id,
                'proposed_actual_parent_id': fx.founderProfile.id,
                'status': 'revert_pending',
              })
              .select())
          .single);

      final toRestore = await readDayById(fx.member, day.id);
      await saveDay(fx.member, toRestore.copyWith(actualParentId: null));
      await fx.member.from('swap_requests').update({
        'status': 'revert_approved',
        'resolved_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', revert.id);

      expect((await readDay(fx.founder, next)).handoffTime, '20:00:00');
    });
  });
}
