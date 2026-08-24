import 'package:entrelares_core/entrelares_core.dart';

/// The `activity_logs` row. Mirrors `Entrelares/Models/ActivityLog.cs`.
///
/// Written ONLY by the `care_schedules` trigger — the client has family-scoped
/// SELECT and nothing else, which is why there is no `toJson`. The snapshots
/// arrive as decoded jsonb and stay untyped: the diff is computed key by key
/// by the pure mirror ([computeAuditDiff]), exactly like the web.
class ActivityLog {
  final int id;
  final int? scheduleId;
  final DateTime affectedDate;
  final String action;
  final Map<String, dynamic>? oldData;
  final Map<String, dynamic>? newData;
  final int? performedById;

  /// UTC instant the trigger wrote the row. Display converts to local — the
  /// timeline and the F-33 footer both say so.
  final DateTime createdAt;

  const ActivityLog({
    required this.id,
    required this.affectedDate,
    required this.action,
    required this.createdAt,
    this.scheduleId,
    this.oldData,
    this.newData,
    this.performedById,
  });

  factory ActivityLog.fromJson(Map<String, dynamic> json) => ActivityLog(
        id: json['id'] as int,
        scheduleId: json['schedule_id'] as int?,
        affectedDate: DateTime.parse(json['affected_date'] as String),
        action: (json['action'] as String?) ?? '',
        oldData: _snapshot(json['old_data']),
        newData: _snapshot(json['new_data']),
        performedById: json['performed_by_id'] as int?,
        createdAt:
            DateTime.parse(json['created_at'] as String).toUtc(),
      );

  /// The pure-rule view of this row, with the timestamp already local.
  AuditLogView get view => AuditLogView(
        id: id,
        affectedDate: affectedDate,
        createdAtLocal: createdAt.toLocal(),
        action: action,
        oldData: oldData,
        newData: newData,
        performedById: performedById,
      );

  static Map<String, dynamic>? _snapshot(Object? raw) =>
      raw is Map ? raw.cast<String, dynamic>() : null;
}
