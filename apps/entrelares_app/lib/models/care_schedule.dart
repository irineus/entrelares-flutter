/// The `care_schedules` row. Mirrors `Entrelares/Models/CareSchedule.cs` —
/// including the T-33/T-35 concurrency contract: an authenticated UPDATE must
/// send the FULL row, with `revision` as read and `submitted_token` echoing
/// the `revision_token` that was read. Omitting the echo is what a forged
/// payload would do, and the trigger rejects it.
class CareSchedule {
  final int id;
  final DateTime scheduleDate; // date-only; ISO yyyy-MM-dd on the wire
  final String? handoffTime; // "HH:mm:ss" as PostgREST returns it
  final int scheduledParentId;
  final int? actualParentId;
  final String? notes;
  final String? createdAt;
  final String? updatedAt;
  final int revision;
  final String revisionToken;

  const CareSchedule({
    required this.id,
    required this.scheduleDate,
    this.handoffTime,
    required this.scheduledParentId,
    this.actualParentId,
    this.notes,
    this.createdAt,
    this.updatedAt,
    this.revision = 0,
    this.revisionToken = '',
  });

  int get effectiveParentId => actualParentId ?? scheduledParentId;

  static DateTime _parseDate(String iso) {
    final p = iso.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  }

  static String isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  factory CareSchedule.fromJson(Map<String, dynamic> json) => CareSchedule(
        id: json['id'] as int,
        scheduleDate: _parseDate(json['schedule_date'] as String),
        handoffTime: json['handoff_time'] as String?,
        scheduledParentId: json['scheduled_parent_id'] as int,
        actualParentId: json['actual_parent_id'] as int?,
        notes: json['notes'] as String?,
        createdAt: json['created_at'] as String?,
        updatedAt: json['updated_at'] as String?,
        revision: (json['revision'] as int?) ?? 0,
        revisionToken: (json['revision_token'] as String?) ?? '',
      );

  /// INSERT payload: no id (identity), no tokens (server-stamped), no
  /// family_id (trigger_a derives it from scheduled_parent_id).
  Map<String, dynamic> toInsertJson() => {
        'schedule_date': isoDate(scheduleDate),
        'handoff_time': handoffTime,
        'scheduled_parent_id': scheduledParentId,
        'actual_parent_id': actualParentId,
        'notes': notes,
      };

  /// UPDATE payload: the full row, `revision` as read and `submitted_token`
  /// echoing the `revision_token` read — the only way past the T-35 guard.
  Map<String, dynamic> toUpdateJson() => {
        'schedule_date': isoDate(scheduleDate),
        'handoff_time': handoffTime,
        'scheduled_parent_id': scheduledParentId,
        'actual_parent_id': actualParentId,
        'notes': notes,
        'revision': revision,
        'submitted_token': revisionToken.isEmpty ? null : revisionToken,
      };

  CareSchedule copyWith({int? scheduledParentId, int? actualParentId}) =>
      CareSchedule(
        id: id,
        scheduleDate: scheduleDate,
        handoffTime: handoffTime,
        scheduledParentId: scheduledParentId ?? this.scheduledParentId,
        actualParentId: actualParentId ?? this.actualParentId,
        notes: notes,
        createdAt: createdAt,
        updatedAt: updatedAt,
        revision: revision,
        revisionToken: revisionToken,
      );
}
