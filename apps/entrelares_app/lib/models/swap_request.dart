import 'package:entrelares_core/entrelares_core.dart';

/// The `swap_requests` row. Mirrors `Entrelares/Models/SwapRequest.cs` —
/// `family_id` stays off the client model on purpose (RLS scopes it, the
/// trigger stamps it), and `resolution_log_id` is trigger-owned (client
/// writes to it are inert).
class SwapRequest {
  final int id;
  final DateTime scheduleDate; // date-only; ISO yyyy-MM-dd on the wire
  final int? scheduleId;
  final int requestingProfileId;
  final int targetProfileId;
  final int? previousActualParentId;
  final int proposedActualParentId;
  final String? proposedHandoffTime; // "HH:mm:ss" as PostgREST returns it
  final String status;
  final String? rejectionReason;
  final String? requestMessage; // F-44
  final String? approvalNote; // F-44
  final int? preEditLogId; // F-26
  final int? resolutionLogId;
  final bool revertNotes; // F-47, frozen after insert by the DB
  final String? resolvedBy; // 'user' | 'system' (F-24 auto-approval)
  final String? createdAt;
  final String? updatedAt;
  final String? resolvedAt;

  const SwapRequest({
    required this.id,
    required this.scheduleDate,
    this.scheduleId,
    required this.requestingProfileId,
    required this.targetProfileId,
    this.previousActualParentId,
    required this.proposedActualParentId,
    this.proposedHandoffTime,
    required this.status,
    this.rejectionReason,
    this.requestMessage,
    this.approvalNote,
    this.preEditLogId,
    this.resolutionLogId,
    this.revertNotes = false,
    this.resolvedBy,
    this.createdAt,
    this.updatedAt,
    this.resolvedAt,
  });

  static DateTime _parseDate(String iso) {
    final p = iso.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  }

  /// `resolved_at` in local time — the F-20 history semantics measure a
  /// resolved request's urgency against this instant, never the clock.
  DateTime? get resolvedAtLocal {
    final raw = resolvedAt;
    if (raw == null) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  /// A revert-flavored open request (`FrozenDayPanel.isRevert`).
  bool get isRevertPending => status == 'revert_pending';

  /// F-24: resolved by the 48h server cron, displayed as `🤖 Automático`.
  bool get isAutoResolved =>
      resolvedBy == 'system' &&
      (status == 'approved' || status == 'revert_approved');

  factory SwapRequest.fromJson(Map<String, dynamic> json) => SwapRequest(
        id: json['id'] as int,
        scheduleDate: _parseDate(json['schedule_date'] as String),
        scheduleId: json['schedule_id'] as int?,
        requestingProfileId: json['requesting_profile_id'] as int,
        targetProfileId: json['target_profile_id'] as int,
        previousActualParentId: json['previous_actual_parent_id'] as int?,
        proposedActualParentId: json['proposed_actual_parent_id'] as int,
        proposedHandoffTime: json['proposed_handoff_time'] as String?,
        status: (json['status'] as String?) ?? 'pending',
        rejectionReason: json['rejection_reason'] as String?,
        requestMessage: json['request_message'] as String?,
        approvalNote: json['approval_note'] as String?,
        preEditLogId: json['pre_edit_log_id'] as int?,
        resolutionLogId: json['resolution_log_id'] as int?,
        revertNotes: (json['revert_notes'] as bool?) ?? false,
        resolvedBy: json['resolved_by'] as String?,
        createdAt: json['created_at'] as String?,
        updatedAt: json['updated_at'] as String?,
        resolvedAt: json['resolved_at'] as String?,
      );

  /// The slice the pure rules consume (frozen set, urgency, resolve subsets).
  SwapRequestView toView() => SwapRequestView(
        id: id,
        scheduleDate: scheduleDate,
        status: status,
        requestingProfileId: requestingProfileId,
        targetProfileId: targetProfileId,
        proposedHandoffTime: proposedHandoffTime,
        resolvedAtLocal: resolvedAtLocal,
      );
}
