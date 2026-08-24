import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// F-45 — `swap_requests.resolution_log_id`: the DB trigger stamps, on the
/// resolution transition, the `activity_logs` row the resolution produced,
/// closing the request → change link that the Histórico and the PDF read.
///
/// Like the transition suite, these drive the REAL write paths: the manual
/// approval exactly as the app issues it (target updates `care_schedules`, then
/// flips the request status) and the automatic path through
/// `auto_approve_expired`. A single trigger serves both, which is the point of
/// doing it server-side.
///
/// Port of `db-gate/Entrelares.IntegrationTests/ResolutionLogLinkTests.cs`.
void resolutionLogLinkTests(GateFixture fx) {
  /// `created_at` for a seeded request, deliberately a minute in the past.
  ///
  /// **Why not simply "now".** The trigger finds the resolution's audit row with
  /// `al.created_at >= OLD.created_at`, where the left side is the DATABASE's
  /// clock and the right side is whatever the client wrote. "Now" therefore made
  /// the test depend on the developer's workstation being no further ahead than
  /// the Supabase host — and a machine one second fast fails all four, with an
  /// assertion that points at the trigger and says nothing about clocks. Found
  /// in the pre-production round of Aug 2026 on a box running ~1 s fast; CI never
  /// saw it, because CI runners are NTP-tight.
  ///
  /// A minute is far more than any plausible skew and changes nothing else:
  /// nothing here asserts on age, and the auto-approval window is 48 h. The real
  /// app never had the problem — its requests are created and resolved by
  /// separate human acts, minutes or days apart — which is why this is a fix to
  /// the SEED and not to the trigger.
  String seedCreatedAt() => DateTime.now()
      .toUtc()
      .subtract(const Duration(minutes: 1))
      .toIso8601String();

  Future<CareSchedule> seedSchedule(DateTime date) async {
    await fx.founder.from('care_schedules').insert({
      'schedule_date': isoDate(date),
      'scheduled_parent_id': fx.founderProfile.id,
    });
    return readDay(fx.founder, date);
  }

  /// The member asks for the founder's day — the founder is the approver, which
  /// is what lets day protection accept the `actual_parent` change.
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
                'created_at': seedCreatedAt(),
              })
              .select())
          .single);

  /// The approve flow, verbatim: the target applies the calendar change with a
  /// full-row update, then resolves the request.
  Future<void> applyAndResolve(
      CareSchedule day, SwapRequest request, String status) async {
    final fresh = await readDayById(fx.founder, day.id);
    await saveDay(
        fx.founder, fresh.copyWith(actualParentId: request.proposedActualParentId));

    await fx.founder.from('swap_requests').update({
      'status': status,
      'resolved_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', request.id);
  }

  Future<SwapRequest> reload(int requestId) async => SwapRequest.fromJson(
      (await fx.service.from('swap_requests').select().eq('id', requestId))
          .single);

  Future<ActivityLog> log(int logId) async => ActivityLog.fromJson(
      (await fx.service.from('activity_logs').select().eq('id', logId)).single);

  group('ResolutionLogLinkTests', () {
    test("a manual approval stamps the log the approver's write produced",
        () async {
      final date = fx.nextFutureDate();
      final day = await seedSchedule(date);
      final request = await openPendingSwap(date, day.id);

      await applyAndResolve(day, request, 'approved');

      final resolved = await reload(request.id);
      expect(resolved.resolutionLogId, isNotNull);

      final stamped = await log(resolved.resolutionLogId!);
      expect(isoDate(stamped.affectedDate), isoDate(date));
      expect(stamped.scheduleId, day.id);
      expect(stamped.action, 'UPDATE');
    });

    test('auto-approval stamps the resolution log', () async {
      // The RPC goes through the SAME trigger — the "Sistema" entry finally
      // carries a trace of the request behind it.
      //
      // 108 h: the same backdating technique as the auto-approval suite, on a
      // date (~4.5 days ago) distinct from its 60 h/84 h seeds — the shared
      // family's UNIQUE (family_id, schedule_date) demands it.
      final expiry = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 108 + 3));
      final date = DateTime(expiry.year, expiry.month, expiry.day);

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
                'proposed_handoff_time': isoTime(expiry),
                'status': 'pending',
                'created_at': seedCreatedAt(),
              })
              .select())
          .single);

      await fx.service.rpc<dynamic>('auto_approve_expired',
          params: {'p_env_prefix': '[Dev] '});

      final resolved = await reload(request.id);
      expect(resolved.status, 'approved');
      expect(resolved.resolvedBy, 'system');
      expect(resolved.resolutionLogId, isNotNull);

      final stamped = await log(resolved.resolutionLogId!);
      expect(isoDate(stamped.affectedDate), isoDate(date));
      expect(stamped.scheduleId, schedule.id);
    });

    test("a revert approval stamps its OWN, newer resolution log", () async {
      final date = fx.nextFutureDate();
      final day = await seedSchedule(date);
      final request = await openPendingSwap(date, day.id);
      await applyAndResolve(day, request, 'approved');
      final approvedLogId = (await reload(request.id)).resolutionLogId;
      expect(approvedLogId, isNotNull);

      // The founder (planned parent) asks, so the member — the currently
      // approved parent — confirms and restores.
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
                'created_at': seedCreatedAt(),
              })
              .select())
          .single);

      // The revert approval without a pre-edit snapshot: clear the swap back to
      // the scheduled parent, then resolve.
      final toRestore = await readDayById(fx.member, day.id);
      await saveDay(fx.member, toRestore.copyWith(actualParentId: null));
      await fx.member.from('swap_requests').update({
        'status': 'revert_approved',
        'resolved_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', revert.id);

      final resolvedRevert = await reload(revert.id);
      expect(resolvedRevert.resolutionLogId, isNotNull);
      expect(resolvedRevert.resolutionLogId, greaterThan(approvedLogId!),
          reason: "the revert's resolution log must be the restore's write, "
              "not the original swap's");

      // The original swap's stamp survives the revert untouched.
      expect((await reload(request.id)).resolutionLogId, approvedLogId);
    });

    test('a client write can neither clear nor forge the stamp', () async {
      // The column is trigger-owned.
      final date = fx.nextFutureDate();
      final day = await seedSchedule(date);
      final request = await openPendingSwap(date, day.id);
      await applyAndResolve(day, request, 'approved');

      final stamped = (await reload(request.id)).resolutionLogId;
      expect(stamped, isNotNull);

      // The requester rewrites the resolved row — the status is unchanged, so
      // the transition guard lets the update through — trying to null the link.
      await fx.member
          .from('swap_requests')
          .update({'resolution_log_id': null}).eq('id', request.id);

      expect((await reload(request.id)).resolutionLogId, stamped);
    });
  });
}
