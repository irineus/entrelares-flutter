/// S-11 PR2 — the family-deletion request and the answers to it. Mirrors
/// `Entrelares/Models/FamilyDeletionRequest.cs`.
///
/// RLS grants SELECT only: every transition goes through a SECURITY DEFINER
/// RPC, and a partial unique index guarantees at most ONE `pending` row per
/// family — so there is never a second request to reconcile.
class FamilyDeletionRequest {
  final int id;

  /// Which family the request belongs to. The app never needs it (RLS narrows
  /// the read to one family); the gate does, because proving that a forged
  /// INSERT wrote nothing means asking the service client for this family's
  /// rows and finding none.
  final int? familyId;

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
    this.familyId,
    required this.requestedBy,
    required this.scheduledFor,
    required this.requestedAt,
    required this.status,
  });

  bool get isPending => status == 'pending';

  factory FamilyDeletionRequest.fromJson(Map<String, dynamic> json) =>
      FamilyDeletionRequest(
        id: json['id'] as int,
        familyId: json['family_id'] as int?,
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

  /// Which request this answer belongs to. The app reads the answers of the one
  /// request it is showing, so it never needs the link; the gate scopes its
  /// assertions to a request it created, which is the only way "nothing was
  /// written" means anything on a shared project.
  final int? requestId;

  const FamilyDeletionResponse({
    required this.profileId,
    required this.agreed,
    this.requestId,
  });

  factory FamilyDeletionResponse.fromJson(Map<String, dynamic> json) =>
      FamilyDeletionResponse(
        profileId: json['profile_id'] as int,
        agreed: (json['agreed'] as bool?) ?? false,
        requestId: json['request_id'] as int?,
      );
}
