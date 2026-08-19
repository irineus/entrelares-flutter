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

  const Member({
    required this.id,
    required this.fullName,
    this.colorSlot,
    this.userId,
    this.leftAt,
    this.language,
    this.languageDetected,
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
      );

  MemberView toView() => MemberView(
        id: id,
        fullName: fullName,
        colorSlot: colorSlot,
        isActiveMember: isActiveMember,
      );
}
