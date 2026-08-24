/// F-15: a co-caregiver invitation. Mirrors
/// `Entrelares/Models/FamilyInvitation.cs`.
///
/// Rows are written EXCLUSIVELY by the `create_invitation` / `revoke_invitation`
/// RPCs — the client only reads them (RLS: family-scoped SELECT). The two
/// computed flags below are what the Família page sorts the list by.
class FamilyInvitation {
  final int id;
  final String email;
  final int roleId;

  /// The uuid that travels in `/register?invite=…`.
  final String token;

  final DateTime expiresAt;
  final DateTime? acceptedAt;
  final DateTime? revokedAt;

  const FamilyInvitation({
    required this.id,
    required this.email,
    required this.roleId,
    required this.token,
    required this.expiresAt,
    this.acceptedAt,
    this.revokedAt,
  });

  /// Still usable: nobody accepted it, nobody revoked it, and the 7-day window
  /// has not closed. A pending invitation HOLDS A SEAT (F-37).
  bool isPending(DateTime nowUtc) =>
      acceptedAt == null && revokedAt == null && expiresAt.isAfter(nowUtc);

  /// Dead by time rather than by decision — the page offers a resend instead of
  /// the link, because the link no longer works.
  bool isExpired(DateTime nowUtc) =>
      acceptedAt == null && revokedAt == null && !expiresAt.isAfter(nowUtc);

  factory FamilyInvitation.fromJson(Map<String, dynamic> json) =>
      FamilyInvitation(
        id: json['id'] as int,
        email: (json['email'] as String?) ?? '',
        roleId: json['role_id'] as int,
        token: (json['token'] as String?) ?? '',
        expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
        acceptedAt: _utc(json['accepted_at'] as String?),
        revokedAt: _utc(json['revoked_at'] as String?),
      );

  static DateTime? _utc(String? wire) =>
      wire == null ? null : DateTime.parse(wire).toUtc();
}
