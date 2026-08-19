/// The `account_logs` row (S-10). Mirrors `Entrelares/Models/AccountLog.cs`.
///
/// Append-only audit of ACCOUNT operations — admin grants, role/name/e-mail
/// changes, invitations, plan transitions and self-actions. Written only by DB
/// triggers and definer RPCs; the client has family-scoped SELECT alone.
class AccountLog {
  final int id;
  final int familyId;
  final int? actorProfileId;
  final int? targetProfileId;
  final String action;
  final String? oldValue;
  final String? newValue;

  /// UTC instant the row was written; the timeline shows it in local time.
  final DateTime createdAt;

  const AccountLog({
    required this.id,
    required this.familyId,
    required this.action,
    required this.createdAt,
    this.actorProfileId,
    this.targetProfileId,
    this.oldValue,
    this.newValue,
  });

  factory AccountLog.fromJson(Map<String, dynamic> json) => AccountLog(
        id: json['id'] as int,
        familyId: (json['family_id'] as int?) ?? 0,
        actorProfileId: json['actor_profile_id'] as int?,
        targetProfileId: json['target_profile_id'] as int?,
        action: (json['action'] as String?) ?? '',
        oldValue: json['old_value'] as String?,
        newValue: json['new_value'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
      );
}
