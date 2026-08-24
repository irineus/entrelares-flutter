/// S-11 PR2 — the family-deletion request and the answers to it. Mirrors
/// `Entrelares/Models/FamilyDeletionRequest.cs`.
///
/// RLS grants SELECT only: every transition goes through a SECURITY DEFINER
/// RPC, and a partial unique index guarantees at most ONE `pending` row per
/// family — so there is never a second request to reconcile.
class FamilyDeletionRequest {
  final int id;
  final int requestedBy;

  /// When the family is purged unless somebody stops it — 30 days out, or now
  /// if an admin executed it early.
  final DateTime scheduledFor;

  final DateTime requestedAt;

  /// `pending` · `refused` · `withdrawn`. Only `pending` shows a banner: a
  /// refusal or a withdrawal ends the request outright.
  final String status;

  const FamilyDeletionRequest({
    required this.id,
    required this.requestedBy,
    required this.scheduledFor,
    required this.requestedAt,
    required this.status,
  });

  bool get isPending => status == 'pending';

  factory FamilyDeletionRequest.fromJson(Map<String, dynamic> json) =>
      FamilyDeletionRequest(
        id: json['id'] as int,
        requestedBy: json['requested_by'] as int,
        scheduledFor: DateTime.parse(json['scheduled_for'] as String).toUtc(),
        requestedAt: DateTime.parse(json['created_at'] as String).toUtc(),
        status: (json['status'] as String?) ?? 'pending',
      );
}

/// One member's answer. The ABSENCE of a row means "aguardando" — which is why
/// deleting a row (the "undo" path) puts the member back into waiting rather
/// than recording a refusal.
class FamilyDeletionResponse {
  final int profileId;
  final bool agreed;

  const FamilyDeletionResponse({required this.profileId, required this.agreed});

  factory FamilyDeletionResponse.fromJson(Map<String, dynamic> json) =>
      FamilyDeletionResponse(
        profileId: json['profile_id'] as int,
        agreed: (json['agreed'] as bool?) ?? false,
      );
}
