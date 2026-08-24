import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// F-47 — `swap_requests.revert_notes`: the requester decides whether undoing a
/// swap also puts the day's OBSERVATION back to the pre-swap snapshot.
///
/// The decision is taken on one side and honoured on the other, so the two
/// things worth pinning in the database are exactly those: the 48 h
/// auto-approval — which restores with no client involved and never saw the
/// question — must read the flag, and the approver, who rewrites the row when
/// they resolve it, must not be able to change the answer they were given.
///
/// The manual approval path restores from the client; its half of the rule is
/// covered by unit tests plus the QA pass, since no DB rule governs it.
///
/// Port of `db-gate/Entrelares.IntegrationTests/RevertNotesTests.cs`.
void revertNotesTests(GateFixture fx) {
  const beforeTheSwap = 'F-47 texto A — combinado antes da troca';
  const afterTheSwap = 'F-47 texto B — reescrito depois da troca';

  /// Builds the situation the item exists for: a past day whose swap was
  /// approved and whose observation was rewritten AFTERWARDS. Returns the day
  /// and the `activity_logs` row whose `old_data` is the pre-swap snapshot —
  /// the same reference the revert request carries over.
  Future<(CareSchedule day, int preEditLogId)> seedRewrittenObservation(
      DateTime date) async {
    final day = CareSchedule.fromJson((await fx.service
            .from('care_schedules')
            .insert({
              'schedule_date': isoDate(date),
              'scheduled_parent_id': fx.founderProfile.id,
              'notes': beforeTheSwap,
            })
            .select())
        .single);

    // The swap itself: this UPDATE's `old_data` IS the pre-edit snapshot.
    await fx.service
        .from('care_schedules')
        .update({'actual_parent_id': fx.memberProfile.id}).eq('id', day.id);

    // Newest log for this day — it has two so far, the INSERT and the swap
    // UPDATE, and the swap's own row is the one whose `old_data` holds the
    // pre-swap observation.
    final preEditLog = ActivityLog.fromJson((await fx.service
            .from('activity_logs')
            .select()
            .eq('schedule_id', day.id)
            .order('id', ascending: false)
            .limit(1))
        .single);

    // The family rewrites the observation days later — the text F-47 refuses to
    // throw away behind their back.
    await fx.service
        .from('care_schedules')
        .update({'notes': afterTheSwap}).eq('id', day.id);

    return (await readDayById(fx.service, day.id), preEditLog.id);
  }

  Future<void> openExpiredRevert(
    CareSchedule day,
    int preEditLogId,
    String handoff, {
    required bool revertNotes,
  }) async {
    await fx.service.from('swap_requests').insert({
      'schedule_date': isoDate(day.scheduleDate),
      'schedule_id': day.id,
      'requesting_profile_id': fx.founderProfile.id,
      'target_profile_id': fx.memberProfile.id,
      'previous_actual_parent_id': fx.memberProfile.id,
      'proposed_actual_parent_id': fx.founderProfile.id,
      'proposed_handoff_time': handoff,
      'status': 'revert_pending',
      'pre_edit_log_id': preEditLogId,
      'revert_notes': revertNotes,
    });
  }

  Future<void> runAutoApproval() => fx.service
      .rpc<dynamic>('auto_approve_expired', params: {'p_env_prefix': '[Dev] '});

  /// A past instant in `America/Sao_Paulo` (fixed UTC-3), [daysAgo] back.
  DateTime expirySpDaysAgo(int daysAgo) =>
      DateTime.now().toUtc().subtract(Duration(days: daysAgo, hours: 3));

  group('RevertNotesTests', () {
    test('auto-approval keeps the current observation when the requester did '
        'not ask for it', () async {
      // The default, and the answer a dismissed question leaves behind: the swap
      // is undone, the current observation survives it.
      //
      // ~16 days back, clear of the other backdated seeds (auto-approval's
      // 60 h/84 h, the resolution log's 108 h, the transition suite's 9 d): the
      // RPC resolves EVERY expired request in the project.
      final expiry = expirySpDaysAgo(16);
      final (day, preEditLogId) = await seedRewrittenObservation(
          DateTime(expiry.year, expiry.month, expiry.day));
      await openExpiredRevert(day, preEditLogId, isoTime(expiry),
          revertNotes: false);

      await runAutoApproval();

      final restored = await readDayById(fx.service, day.id);
      expect(restored.actualParentId, isNull); // the swap IS undone…
      expect(restored.notes, afterTheSwap); // …the observation is not.
    });

    test('auto-approval restores the observation when the requester asked for it',
        () async {
      final expiry = expirySpDaysAgo(17);
      final (day, preEditLogId) = await seedRewrittenObservation(
          DateTime(expiry.year, expiry.month, expiry.day));
      await openExpiredRevert(day, preEditLogId, isoTime(expiry),
          revertNotes: true);

      await runAutoApproval();

      final restored = await readDayById(fx.service, day.id);
      expect(restored.actualParentId, isNull);
      expect(restored.notes, beforeTheSwap);
    });

    test("an approver's write cannot flip the requester's choice", () async {
      // The choice belongs to the requester, and the APPROVER rewrites this row
      // when they resolve it — a flipped flag must not ride along.
      final date = fx.nextFutureDate();
      final day = CareSchedule.fromJson((await fx.founder
              .from('care_schedules')
              .insert({
                'schedule_date': isoDate(date),
                'scheduled_parent_id': fx.founderProfile.id,
                'notes': beforeTheSwap,
              })
              .select())
          .single);

      // The founder asks to undo a swap on their own day and wants the pre-swap
      // observation back; the member is the approver.
      final revert = SwapRequest.fromJson((await fx.founder
              .from('swap_requests')
              .insert({
                'schedule_date': isoDate(date),
                'schedule_id': day.id,
                'requesting_profile_id': fx.founderProfile.id,
                'target_profile_id': fx.memberProfile.id,
                'previous_actual_parent_id': fx.memberProfile.id,
                'proposed_actual_parent_id': fx.founderProfile.id,
                'status': 'revert_pending',
                'revert_notes': true,
              })
              .select())
          .single);

      // A write from the other side carrying the opposite answer. The status is
      // untouched, so the transition guard lets the update through — which is
      // precisely why the flag needs a rule of its own.
      await fx.member
          .from('swap_requests')
          .update({'revert_notes': false}).eq('id', revert.id);

      final reloaded = SwapRequest.fromJson((await fx.service
              .from('swap_requests')
              .select()
              .eq('id', revert.id))
          .single);
      expect(reloaded.revertNotes, isTrue);
    });

    test('the worker functions are not callable by an end user', () async {
      // Carried by the same migration: both worker functions were reachable by
      // any logged-in user. `REVOKE … FROM PUBLIC` (V007) never removed
      // Supabase's DEFAULT-PRIVILEGES grants to anon/authenticated, so the
      // lockdown had been inert since it was written — and
      // `restore_pre_edit_state` is SECURITY DEFINER over a bare schedule id,
      // which made it a cross-family delete primitive.
      await expectRejected(() => fx.member.rpc<dynamic>('auto_approve_expired',
          params: {'p_env_prefix': '[Dev] '}));

      await expectRejected(() => fx.member.rpc<dynamic>('restore_pre_edit_state',
          params: {
            'p_schedule_id': 1,
            'p_pre_edit_log_id': 1,
            'p_restore_notes': false,
          }));
    });
  });
}
