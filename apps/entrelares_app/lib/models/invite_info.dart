/// What `get_invite_info(p_token)` tells an ANONYMOUS visitor about a pending
/// invitation — mirror of `FamilyService.InviteInfo`.
///
/// The RPC is `SECURITY DEFINER` and granted to `anon` on purpose (the visitor
/// has no session yet), and it answers only while the invitation is still
/// pending: unknown, accepted, revoked and expired tokens are indistinguishable
/// from each other, which is what keeps it from being an enumeration oracle.
class InviteInfo {
  final String familyName;
  final String inviterName;

  /// The address the invitation was issued to. The sign-up form shows it
  /// read-only: `handle_new_user` refuses a mismatch anyway.
  final String invitedEmail;

  /// The role the inviter chose. Stored raw — [RoleCatalog] translates the
  /// built-ins and passes custom roles through.
  final String roleName;

  const InviteInfo({
    required this.familyName,
    required this.inviterName,
    required this.invitedEmail,
    required this.roleName,
  });

  factory InviteInfo.fromJson(Map<String, dynamic> json) => InviteInfo(
        familyName: (json['family_name'] as String?) ?? '',
        inviterName: (json['inviter_name'] as String?) ?? '',
        invitedEmail: (json['invited_email'] as String?) ?? '',
        roleName: (json['role_name'] as String?) ?? '',
      );
}
