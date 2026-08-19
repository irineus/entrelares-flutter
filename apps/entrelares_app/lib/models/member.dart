import 'package:entrelares_core/entrelares_core.dart';

/// The slice of a `profiles` row the calendar needs.
/// Mirrors `Entrelares/Models/Profile.cs`.
class Member {
  final int id;
  final String fullName;
  final int? colorSlot;
  final String? userId;
  final String? leftAt;

  /// U-13: the user's explicit language CHOICE (`profiles.language`), or null
  /// when they never chose. Drives cross-device adoption; the server-side
  /// senders read the generated `language_effective`.
  final String? language;

  /// U-13: what this user's sessions actually render in, recorded on boot
  /// (`profiles.language_detected`). Never drives a screen — it exists so an
  /// e-mail arrives in the same language as the app did.
  final String? languageDetected;

  /// Family admin (🛡️). Client-side it only gates AFFORDANCES (the F-31
  /// invite nudge here); every admin power is re-checked by RLS/triggers.
  final bool isAdmin;

  /// The `roles` row this member holds — resolved against the fetched role list
  /// for display (built-ins translate, F-41 custom roles pass through).
  final int? roleId;

  /// The address on the profile row. Read-only in this client; changing it is
  /// a sudo-gated flow of its own.
  final String? email;

  /// S-11: when this member's data is purged, once they asked to leave. Null
  /// while they are staying.
  final DateTime? deletionScheduledFor;

  /// S-15: which declaration this member accepted — founder or invitee. The
  /// re-consent gate has no invite context left, so the marker is persisted
  /// (and immutable: a trigger preserves it on update).
  final bool joinedViaInvite;

  /// S-13: the policy version stamped at sign-up. Null on legacy profiles,
  /// which the gate deliberately captures rather than backfilling.
  final String? consentPolicyVersion;

  const Member({
    required this.id,
    required this.fullName,
    this.colorSlot,
    this.userId,
    this.leftAt,
    this.language,
    this.languageDetected,
    this.isAdmin = false,
    this.roleId,
    this.email,
    this.deletionScheduledFor,
    this.joinedViaInvite = false,
    this.consentPolicyVersion,
  });

  /// A live, present member holds a family seat (Profile.IsActiveMember).
  bool get isActiveMember => (userId ?? '').isNotEmpty && leftAt == null;

  factory Member.fromJson(Map<String, dynamic> json) => Member(
        id: json['id'] as int,
        fullName: (json['full_name'] as String?) ?? '',
        colorSlot: json['color_slot'] as int?,
        userId: json['user_id'] as String?,
        leftAt: json['left_at'] as String?,
        language: json['language'] as String?,
        languageDetected: json['language_detected'] as String?,
        isAdmin: (json['is_admin'] as bool?) ?? false,
        roleId: json['role_id'] as int?,
        email: json['email'] as String?,
        deletionScheduledFor: json['deletion_scheduled_for'] == null
            ? null
            : DateTime.parse(json['deletion_scheduled_for'] as String).toUtc(),
        joinedViaInvite: (json['joined_via_invite'] as bool?) ?? false,
        consentPolicyVersion: json['consent_policy_version'] as String?,
      );

  /// The avatar letter the roster shows — "?" when there is no usable name,
  /// mirroring the web's `GetInitial`.
  String get initial =>
      fullName.trim().isEmpty ? '?' : fullName.trim()[0].toUpperCase();

  MemberView toView() => MemberView(
        id: id,
        fullName: fullName,
        colorSlot: colorSlot,
        isActiveMember: isActiveMember,
      );
}
