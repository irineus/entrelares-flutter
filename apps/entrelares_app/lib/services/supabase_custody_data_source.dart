import 'package:entrelares_core/entrelares_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/app_notification.dart';
import '../models/care_schedule.dart';
import '../models/family.dart';
import '../models/member.dart';
import '../models/swap_request.dart';
import 'custody_data_source.dart';

/// The real data source. Mirrors `CustodyService.cs`/`ProfileService.cs` reads
/// and the full-row write, plus the `SwapRequestService.cs` workflow (lote 3);
/// Realtime is NATIVE here — the F-29 JS bridge retires in this stack (the
/// F-23 poll survives as a safety net until the socket proves itself under
/// real load, owner decision 19/08/2026).
class SupabaseCustodyDataSource implements CustodyDataSource {
  final SupabaseClient _client;

  /// "[Dev] " on non-production flavors — leads every stored notification
  /// title (deploy marker, deliberately absent from `params`).
  final String environmentPrefix;

  SupabaseCustodyDataSource(this._client, {this.environmentPrefix = ''});

  @override
  Future<List<Member>> fetchMembers() async {
    final rows = await _client.from('profiles').select();
    return rows.map(Member.fromJson).toList();
  }

  @override
  Future<Member?> fetchOwnProfile() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return null;
    final row = await _client
        .from('profiles')
        .select()
        .eq('user_id', uid)
        .maybeSingle();
    return row == null ? null : Member.fromJson(row);
  }

  @override
  Future<void> updateOwnLanguage(int profileId, String languageCode) async {
    await _client
        .from('profiles')
        .update({'language': languageCode}).eq('id', profileId);
  }

  @override
  Future<void> updateDetectedLanguage(
      int profileId, String languageCode) async {
    await _client
        .from('profiles')
        .update({'language_detected': languageCode}).eq('id', profileId);
  }

  @override
  Future<List<CareSchedule>> fetchMonth(int year, int month) async {
    final first = DateTime(year, month, 1);
    final last = DateTime(year, month + 1, 0);
    final rows = await _client
        .from('care_schedules')
        .select()
        .gte('schedule_date', CareSchedule.isoDate(first))
        .lte('schedule_date', CareSchedule.isoDate(last))
        .order('schedule_date', ascending: true);
    return rows.map(CareSchedule.fromJson).toList();
  }

  @override
  Future<List<CareSchedule>> fetchUpcoming(DateTime from, int days) async {
    final rows = await _client
        .from('care_schedules')
        .select()
        .gte('schedule_date', CareSchedule.isoDate(from))
        .lte('schedule_date',
            CareSchedule.isoDate(from.add(Duration(days: days))))
        .order('schedule_date', ascending: true);
    return rows.map(CareSchedule.fromJson).toList();
  }

  @override
  Future<Family?> fetchOwnFamily() async {
    // Same shape as the web's GetMyFamilyAsync: a plain RLS-scoped select,
    // first row or null — never the is_premium() RPC (the mirror exists so
    // no extra round-trip is needed).
    final rows = await _client.from('families').select().limit(1);
    return rows.isEmpty ? null : Family.fromJson(rows.first);
  }

  @override
  Future<Map<String, String>> fetchPublicSettings() async {
    final rows = await _client.from('app_settings').select('key, value');
    return {
      for (final row in rows)
        (row['key'] as String): (row['value'] as String? ?? ''),
    };
  }

  @override
  Future<CareSchedule?> fetchDay(DateTime date) async {
    final row = await _client
        .from('care_schedules')
        .select()
        .eq('schedule_date', CareSchedule.isoDate(date))
        .maybeSingle();
    return row == null ? null : CareSchedule.fromJson(row);
  }

  @override
  Future<void> insertDay(CareSchedule day) async {
    await _client.from('care_schedules').insert(day.toInsertJson());
  }

  @override
  Future<void> updateDay(CareSchedule day) async {
    await _client
        .from('care_schedules')
        .update(day.toUpdateJson())
        .eq('id', day.id);
  }

  @override
  Future<void> deleteDay(int id) async {
    await _client.from('care_schedules').delete().eq('id', id);
  }

  @override
  Future<int> bulkInsertNewDays(List<CareSchedule> days,
      {void Function(int percent)? onProgress}) async {
    if (days.isEmpty) return 0;
    final dates = days.map((d) => d.scheduleDate).toList()
      ..sort((a, b) => a.compareTo(b));
    final first = dates.first;
    final last = dates.last;

    Future<Set<String>> existingDates() async {
      final rows = await _client
          .from('care_schedules')
          .select('schedule_date')
          .gte('schedule_date', CareSchedule.isoDate(first))
          .lte('schedule_date', CareSchedule.isoDate(last));
      return {for (final r in rows) r['schedule_date'] as String};
    }

    final existing = await existingDates();
    onProgress?.call(20);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final toInsert = [
      for (final d in days)
        // Past days are immutable; already-assigned days are kept.
        if (!d.scheduleDate.isBefore(today) &&
            !existing.contains(CareSchedule.isoDate(d.scheduleDate)))
          d,
    ];
    onProgress?.call(30);
    if (toInsert.isEmpty) {
      onProgress?.call(100);
      return 0;
    }

    // T-33: another member may create one of these days between the check and
    // the batch INSERT — on the UNIQUE(family, date) collision, re-fetch,
    // drop the collided days and retry the remainder once (web mirror).
    Future<int> insertBatch(List<CareSchedule> batch) async {
      try {
        await _client
            .from('care_schedules')
            .insert([for (final d in batch) d.toInsertJson()]);
        return batch.length;
      } catch (e) {
        if (!isUniqueDayConflict(e.toString())) rethrow;
        final fresh = await existingDates();
        final remainder = [
          for (final d in batch)
            if (!fresh.contains(CareSchedule.isoDate(d.scheduleDate))) d,
        ];
        if (remainder.isEmpty) return 0;
        await _client
            .from('care_schedules')
            .insert([for (final d in remainder) d.toInsertJson()]);
        return remainder.length;
      }
    }

    const batchSize = 10;
    final totalBatches = (toInsert.length + batchSize - 1) ~/ batchSize;
    var inserted = 0;
    var batchesDone = 0;
    for (var i = 0; i < toInsert.length; i += batchSize) {
      final end =
          i + batchSize > toInsert.length ? toInsert.length : i + batchSize;
      inserted += await insertBatch(toInsert.sublist(i, end));
      batchesDone++;
      onProgress?.call(30 + (batchesDone * 70 ~/ totalBatches));
    }
    return inserted;
  }

  /// Channel topics must be unique per subscription — two subscribers on the
  /// same name would collide in the Realtime client.
  int _channelSeq = 0;

  void Function(RealtimeSubscribeStatus, Object?)? _statusCallback(
          void Function(bool connected)? onStatus) =>
      onStatus == null
          ? null
          : (status, _) =>
              onStatus(status == RealtimeSubscribeStatus.subscribed);

  @override
  Future<void Function()> watchChanges(void Function() onChange,
      {void Function(bool connected)? onStatus}) async {
    final channel = _client
        .channel('care_schedules_changes_${_channelSeq++}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'care_schedules',
          callback: (_) => onChange(),
        )
        .subscribe(_statusCallback(onStatus));
    return () => _client.removeChannel(channel);
  }

  // ── Lote 3: swap-approval workflow (mirror of SwapRequestService.cs) ──────

  static String _nowUtcIso() => DateTime.now().toUtc().toIso8601String();

  static DateTime _todayLocal() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  Future<List<SwapRequest>> fetchFrozenRequestsForMonth(
      int year, int month) async {
    final first = DateTime(year, month, 1);
    final last = DateTime(year, month + 1, 0);
    if (last.isBefore(_todayLocal())) return [];

    // Filter server-side: months with a long history hold many resolved
    // requests — only the open (frozen) ones matter here.
    final rows = await _client
        .from('swap_requests')
        .select()
        .gte('schedule_date', CareSchedule.isoDate(first))
        .lte('schedule_date', CareSchedule.isoDate(last))
        .inFilter('status', ['pending', 'revert_pending']);
    return rows.map(SwapRequest.fromJson).toList();
  }

  @override
  Future<List<SwapRequest>> fetchPendingForMe(int myProfileId) async {
    // Server-side filter: this backs the nav badge, so it must return only
    // the handful of open requests, not the full history.
    final rows = await _client
        .from('swap_requests')
        .select()
        .eq('target_profile_id', myProfileId)
        .inFilter('status', ['pending', 'revert_pending']).order('created_at',
            ascending: false, nullsFirst: false);
    return rows.map(SwapRequest.fromJson).toList();
  }

  @override
  Future<List<SwapRequest>> fetchSentRequests(int myProfileId) async {
    final rows = await _client
        .from('swap_requests')
        .select()
        .eq('requesting_profile_id', myProfileId)
        .order('created_at', ascending: false, nullsFirst: false)
        .limit(100);
    return rows.map(SwapRequest.fromJson).toList();
  }

  Future<SwapRequest> _fetchRequest(int id) async {
    final row =
        await _client.from('swap_requests').select().eq('id', id).maybeSingle();
    if (row == null) throw StateError('Solicitação não encontrada.');
    return SwapRequest.fromJson(row);
  }

  /// The revert links back to the swap it undoes: the most recently resolved
  /// approved request on that date.
  Future<SwapRequest?> _approvedRequestForDate(DateTime date) async {
    final rows = await _client
        .from('swap_requests')
        .select()
        .eq('schedule_date', CareSchedule.isoDate(date))
        .eq('status', 'approved')
        .order('resolved_at', ascending: false, nullsFirst: false)
        .limit(1);
    return rows.isEmpty ? null : SwapRequest.fromJson(rows.first);
  }

  /// The newest activity_logs row for a date is the one just written by the
  /// base-schedule upsert that precedes [createSwapRequest], so its old_data
  /// is the day's pre-edit snapshot (id is a monotonic identity).
  Future<int?> _latestLogIdForDate(DateTime date) async {
    final rows = await _client
        .from('activity_logs')
        .select('id')
        .eq('affected_date', CareSchedule.isoDate(date))
        .order('id', ascending: false)
        .limit(1);
    return rows.isEmpty ? null : rows.first['id'] as int?;
  }

  Future<Object?> _fetchOldData(int logId) async {
    final row = await _client
        .from('activity_logs')
        .select('old_data')
        .eq('id', logId)
        .maybeSingle();
    return row?['old_data'];
  }

  /// Inserts the drafts WITHOUT representation (the SELECT policy restricts
  /// each user to their own notifications — returning the row inserted for
  /// the other parent would raise RLS 42501). Best-effort drafts (the F-28
  /// family fan-out) swallow their own failures.
  Future<void> _insertNotifications(
      List<NotificationDraft> drafts, int swapRequestId) async {
    for (final d in drafts) {
      final row = {
        'recipient_profile_id': d.recipientProfileId,
        'type': d.type,
        'title': d.title,
        'message': d.message,
        'params': d.params,
        'swap_request_id': swapRequestId,
        'is_read': false,
        'created_at': _nowUtcIso(),
      };
      if (d.bestEffort) {
        try {
          await _client.from('notifications').insert(row);
        } catch (_) {/* informational only */}
      } else {
        await _client.from('notifications').insert(row);
      }
    }
  }

  /// F-20: no urgency in the payload — the Edge Function computes the
  /// priority tag at SEND time from the request itself. Best-effort: e-mail
  /// failures never fail the workflow.
  Future<void> _sendSwapEmail(int swapRequestId, String emailType) async {
    try {
      await _client.functions.invoke('send-swap-email', body: {
        'swapRequestId': swapRequestId,
        'emailType': emailType,
        'environmentPrefix': environmentPrefix,
      });
    } catch (_) {/* best-effort */}
  }

  @override
  Future<void> createSwapRequest({
    required CareSchedule schedule,
    required int proposedActualParentId,
    String? proposedHandoffTime,
    String? requestMessage,
    required Member myProfile,
    required List<Member> allProfiles,
  }) async {
    final message = normalizeFreeText(requestMessage);

    // F-28: scenario-C gate — the DB does not hold this one (two-party
    // approval principle), so the mirror must refuse exactly like the web.
    if (!requesterParticipates(
        requesterId: myProfile.id,
        scheduledParentId: schedule.scheduledParentId,
        proposedActualParentId: proposedActualParentId)) {
      throw StateError(
          'Somente o responsável planejado do dia ou quem se propõe a assumir pode abrir a troca.');
    }

    // The approver is always the party that is NOT the requester.
    final approverId = myProfile.id == schedule.scheduledParentId
        ? proposedActualParentId
        : schedule.scheduledParentId;
    final target = allProfiles.where((p) => p.id == approverId).firstOrNull;
    if (target == null) {
      throw StateError('Perfil do responsável para aprovação não encontrado.');
    }

    // Tag at this instant — only for the point-in-time notification title;
    // display badges stay dynamic (F-20).
    final creationTag = computePriorityTag(
        schedule.scheduleDate, proposedHandoffTime, DateTime.now());

    // Snapshot reference (F-26): the base schedule was just upserted by the
    // caller, so the newest audit log for this date holds the pre-edit
    // old_data used to fully restore the day if this swap is later reverted.
    final preEditLogId = await _latestLogIdForDate(schedule.scheduleDate);

    final now = _nowUtcIso();
    final inserted = await _client
        .from('swap_requests')
        .insert({
          'schedule_date': CareSchedule.isoDate(schedule.scheduleDate),
          'schedule_id': schedule.id == 0 ? null : schedule.id,
          'requesting_profile_id': myProfile.id,
          'target_profile_id': approverId,
          'previous_actual_parent_id': schedule.actualParentId,
          'proposed_actual_parent_id': proposedActualParentId,
          'proposed_handoff_time': proposedHandoffTime,
          'status': 'pending',
          'request_message': message,
          'pre_edit_log_id': preEditLogId,
          'created_at': now,
          'updated_at': now,
        })
        .select('id')
        .single();
    final requestId = inserted['id'] as int;

    final drafts = composeSwapCreated(
      scheduleDate: schedule.scheduleDate,
      requesterId: myProfile.id,
      requesterName: myProfile.fullName,
      targetId: target.id,
      targetName: target.fullName,
      targetIsProposed: approverId == proposedActualParentId,
      creationTag: creationTag,
      requestMessage: message,
      environmentPrefix: environmentPrefix,
    );
    await _insertNotifications(drafts, requestId);
    await _sendSwapEmail(requestId, 'swap_requested');
  }

  @override
  Future<void> approveSwap(int swapRequestId,
      {String? approvalNote, required List<Member> allProfiles}) async {
    final request = await _fetchRequest(swapRequestId);

    // Apply the change to care_schedules — full-row update so the T-33/T-35
    // echo travels with it.
    final scheduleId = request.scheduleId;
    if (scheduleId != null) {
      final row = await _client
          .from('care_schedules')
          .select()
          .eq('id', scheduleId)
          .maybeSingle();
      if (row != null) {
        final updated = CareSchedule.fromJson(row).copyWith(
          actualParentId: request.proposedActualParentId,
          handoffTime: request.proposedHandoffTime,
        );
        await _client
            .from('care_schedules')
            .update(updated.toUpdateJson())
            .eq('id', scheduleId);
      }
    }

    final note = normalizeFreeText(approvalNote); // F-44
    final now = _nowUtcIso();
    await _client.from('swap_requests').update({
      'status': 'approved',
      'approval_note': note,
      'resolved_at': now,
      'updated_at': now,
    }).eq('id', swapRequestId);

    final drafts = composeSwapApproved(
      scheduleDate: request.scheduleDate,
      requestingProfileId: request.requestingProfileId,
      targetProfileId: request.targetProfileId,
      proposedActualParentId: request.proposedActualParentId,
      approvalNote: note,
      allProfiles: [for (final p in allProfiles) p.toView()],
      environmentPrefix: environmentPrefix,
    );
    await _insertNotifications(drafts, swapRequestId);
    await _sendSwapEmail(swapRequestId, 'approved');
  }

  @override
  Future<void> rejectSwap(int swapRequestId,
      {String? reason, required List<Member> allProfiles}) async {
    final request = await _fetchRequest(swapRequestId);
    final now = _nowUtcIso();
    await _client.from('swap_requests').update({
      'status': 'rejected',
      'rejection_reason': reason,
      'resolved_at': now,
      'updated_at': now,
    }).eq('id', swapRequestId);

    final drafts = composeSwapRejected(
      scheduleDate: request.scheduleDate,
      requestingProfileId: request.requestingProfileId,
      targetProfileId: request.targetProfileId,
      reason: reason,
      allProfiles: [for (final p in allProfiles) p.toView()],
      environmentPrefix: environmentPrefix,
    );
    await _insertNotifications(drafts, swapRequestId);
    await _sendSwapEmail(swapRequestId, 'rejected');
  }

  @override
  Future<void> cancelSwap(int swapRequestId,
      {required List<Member> allProfiles}) async {
    final request = await _fetchRequest(swapRequestId);
    final now = _nowUtcIso();
    await _client.from('swap_requests').update({
      'status': 'cancelled',
      'resolved_at': now,
      'updated_at': now,
    }).eq('id', swapRequestId);

    final drafts = composeSwapCancelled(
      scheduleDate: request.scheduleDate,
      targetProfileId: request.targetProfileId,
      allProfiles: [for (final p in allProfiles) p.toView()],
      environmentPrefix: environmentPrefix,
    );
    await _insertNotifications(drafts, swapRequestId);
    await _sendSwapEmail(swapRequestId, 'cancelled');
  }

  @override
  Future<void> requestRevert({
    required DateTime scheduleDate,
    required int currentActualProfileId,
    required int scheduledParentId,
    String? requestMessage,
    bool restoreNotes = false,
    required Member myProfile,
    required List<Member> allProfiles,
  }) async {
    final message = normalizeFreeText(requestMessage);

    // The approver is always the party that is NOT the requester.
    final approverId = myProfile.id == scheduledParentId
        ? currentActualProfileId
        : scheduledParentId;
    final approver = allProfiles.where((p) => p.id == approverId).firstOrNull;
    if (approver == null) {
      throw StateError('Perfil do responsável para aprovação não encontrado.');
    }

    // Find the approved swap for this date to link back (F-26) and read the
    // day's current handoff time for the urgency tag.
    final approvedRequest = await _approvedRequestForDate(scheduleDate);
    String? currentHandoffTime;
    final approvedScheduleId = approvedRequest?.scheduleId;
    if (approvedScheduleId != null) {
      final row = await _client
          .from('care_schedules')
          .select('handoff_time')
          .eq('id', approvedScheduleId)
          .maybeSingle();
      currentHandoffTime = row?['handoff_time'] as String?;
    }

    final creationTag =
        computePriorityTag(scheduleDate, currentHandoffTime, DateTime.now());

    final now = _nowUtcIso();
    final inserted = await _client
        .from('swap_requests')
        .insert({
          'schedule_date': CareSchedule.isoDate(scheduleDate),
          'schedule_id': approvedRequest?.scheduleId,
          'requesting_profile_id': myProfile.id,
          'target_profile_id': approverId,
          'previous_actual_parent_id': currentActualProfileId,
          'proposed_actual_parent_id': scheduledParentId,
          'proposed_handoff_time': currentHandoffTime,
          'status': 'revert_pending',
          'request_message': message,
          // F-47: the requester's answer travels with the request — the
          // restore runs later and on the other side.
          'revert_notes': restoreNotes,
          'pre_edit_log_id': approvedRequest?.preEditLogId,
          'created_at': now,
          'updated_at': now,
        })
        .select('id')
        .single();
    final requestId = inserted['id'] as int;

    final drafts = composeRevertRequested(
      scheduleDate: scheduleDate,
      requesterId: myProfile.id,
      requesterName: myProfile.fullName,
      approverId: approver.id,
      approverName: approver.fullName,
      creationTag: creationTag,
      requestMessage: message,
      environmentPrefix: environmentPrefix,
    );
    await _insertNotifications(drafts, requestId);
    await _sendSwapEmail(requestId, 'revert_requested');
  }

  /// Restores the day to the full snapshot captured before the swap edit
  /// (F-26). The branching is the pure [revertRestorePlan]; this only
  /// executes it.
  Future<void> _restorePreEditState(SwapRequest request) async {
    final scheduleId = request.scheduleId;
    if (scheduleId == null) return;
    final row = await _client
        .from('care_schedules')
        .select()
        .eq('id', scheduleId)
        .maybeSingle();
    if (row == null) return;
    final schedule = CareSchedule.fromJson(row);

    final preEditLogId = request.preEditLogId;
    final oldData =
        preEditLogId == null ? null : await _fetchOldData(preEditLogId);
    final plan = revertRestorePlan(
      hasPreEditLogId: preEditLogId != null,
      oldData: oldData,
      revertNotes: request.revertNotes,
    );

    switch (plan) {
      case RevertClearActualOnly():
        final updated = schedule.copyWith(actualParentId: null);
        await _client
            .from('care_schedules')
            .update(updated.toUpdateJson())
            .eq('id', scheduleId);
      case RevertDeleteDay():
        await _client.from('care_schedules').delete().eq('id', scheduleId);
      case RevertRestoreFields():
        final updated = schedule.copyWith(
          scheduledParentId:
              plan.scheduledParentId ?? schedule.scheduledParentId,
          actualParentId: plan.actualParentId,
          handoffTime: plan.handoffTime,
          notes: plan.restoreNotes ? plan.notes : schedule.notes,
        );
        await _client
            .from('care_schedules')
            .update(updated.toUpdateJson())
            .eq('id', scheduleId);
    }
  }

  @override
  Future<void> approveRevert(int swapRequestId,
      {String? approvalNote, required List<Member> allProfiles}) async {
    final request = await _fetchRequest(swapRequestId);

    if (request.scheduleId != null) {
      await _restorePreEditState(request);
    }

    final note = normalizeFreeText(approvalNote); // F-44
    final now = _nowUtcIso();
    await _client.from('swap_requests').update({
      'status': 'revert_approved',
      'approval_note': note,
      'resolved_at': now,
      'updated_at': now,
    }).eq('id', swapRequestId);

    final drafts = composeRevertApproved(
      scheduleDate: request.scheduleDate,
      requestingProfileId: request.requestingProfileId,
      targetProfileId: request.targetProfileId,
      proposedActualParentId: request.proposedActualParentId,
      approvalNote: note,
      allProfiles: [for (final p in allProfiles) p.toView()],
      environmentPrefix: environmentPrefix,
    );
    await _insertNotifications(drafts, swapRequestId);
    await _sendSwapEmail(swapRequestId, 'revert_approved');
  }

  @override
  Future<void> rejectRevert(int swapRequestId,
      {String? reason, required List<Member> allProfiles}) async {
    final request = await _fetchRequest(swapRequestId);
    final now = _nowUtcIso();
    await _client.from('swap_requests').update({
      'status': 'revert_rejected',
      'rejection_reason': reason,
      'resolved_at': now,
      'updated_at': now,
    }).eq('id', swapRequestId);

    final drafts = composeRevertRejected(
      scheduleDate: request.scheduleDate,
      requestingProfileId: request.requestingProfileId,
      targetProfileId: request.targetProfileId,
      reason: reason,
      allProfiles: [for (final p in allProfiles) p.toView()],
      environmentPrefix: environmentPrefix,
    );
    await _insertNotifications(drafts, swapRequestId);
    await _sendSwapEmail(swapRequestId, 'revert_rejected');
  }

  @override
  Future<void> cancelRevert(int swapRequestId,
      {required List<Member> allProfiles}) async {
    final request = await _fetchRequest(swapRequestId);
    final now = _nowUtcIso();
    await _client.from('swap_requests').update({
      'status': 'revert_cancelled',
      'resolved_at': now,
      'updated_at': now,
    }).eq('id', swapRequestId);

    final drafts = composeRevertCancelled(
      scheduleDate: request.scheduleDate,
      targetProfileId: request.targetProfileId,
      allProfiles: [for (final p in allProfiles) p.toView()],
      environmentPrefix: environmentPrefix,
    );
    await _insertNotifications(drafts, swapRequestId);
    await _sendSwapEmail(swapRequestId, 'revert_cancelled');
  }

  @override
  Future<PreEditNotes?> fetchPreEditNotes(DateTime scheduleDate) async {
    final approvedRequest = await _approvedRequestForDate(scheduleDate);
    final preEditLogId = approvedRequest?.preEditLogId;
    if (preEditLogId == null) return null;
    final snapshot = PreEditSnapshot.parse(await _fetchOldData(preEditLogId));
    if (snapshot == null) return null;
    return PreEditNotes(snapshot.notes);
  }

  @override
  Future<List<AppNotification>> fetchNotifications(int myProfileId) async {
    // Newest 100 — the history tab is a recent-activity view (web parity).
    final rows = await _client
        .from('notifications')
        .select()
        .eq('recipient_profile_id', myProfileId)
        .order('created_at', ascending: false)
        .limit(100);
    return rows.map(AppNotification.fromJson).toList();
  }

  @override
  Future<void> markAllNotificationsRead(int myProfileId) async {
    await _client
        .from('notifications')
        .update({'is_read': true})
        .eq('recipient_profile_id', myProfileId)
        .eq('is_read', false);
  }

  @override
  Future<void Function()> watchWorkflowChanges(void Function() onChange,
      {void Function(bool connected)? onStatus}) async {
    final channel = _client
        .channel('workflow_changes_${_channelSeq++}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'swap_requests',
          callback: (_) => onChange(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notifications',
          callback: (_) => onChange(),
        )
        .subscribe(_statusCallback(onStatus));
    return () => _client.removeChannel(channel);
  }

  // ── Lote 4: sudo elevation (S-10) ─────────────────────────────────────────

  @override
  Future<String?> elevate(String password) async {
    // Pilot QA round 2 (console): a STALE access token makes `elevate` answer
    // 401 no matter how right the password is, and the user reads "senha
    // incorreta" while typing the correct one. Refresh first, best-effort —
    // if the refresh itself fails the call below reports the real problem.
    try {
      await _client.auth.refreshSession();
    } catch (_) {/* the invoke below surfaces a dead session honestly */}

    try {
      final response = await _client.functions
          .invoke('elevate', body: {'password': password});
      final data = response.data;
      if (data is Map && data['elevated_until'] is String) {
        return data['elevated_until'] as String;
      }
      return null;
    } on FunctionException catch (e) {
      throw ElevationRefused(
        // Pilot lesson 4: the function's own PT-BR text, never a guess.
        serverMessage: _functionErrorText(e),
        wrongPassword: e.status == 401,
        rateLimited: e.status == 429,
      );
    }
  }

  /// The `error` field an Edge Function puts in its body, when there is one.
  static String? _functionErrorText(FunctionException e) {
    final details = e.details;
    if (details is Map && details['error'] is String) {
      final text = (details['error'] as String).trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }
}
