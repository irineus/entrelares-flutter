import 'package:entrelares_core/entrelares_core.dart';

/// The slice of a `profiles` row the calendar needs.
/// Mirrors `Entrelares/Models/Profile.cs`.
class Member {
  final int id;
  final String fullName;
  final int? colorSlot;
  final String? userId;
  final String? leftAt;

  const Member({
    required this.id,
    required this.fullName,
    this.colorSlot,
    this.userId,
    this.leftAt,
  });

  /// A live, present member holds a family seat (Profile.IsActiveMember).
  bool get isActiveMember => (userId ?? '').isNotEmpty && leftAt == null;

  factory Member.fromJson(Map<String, dynamic> json) => Member(
        id: json['id'] as int,
        fullName: (json['full_name'] as String?) ?? '',
        colorSlot: json['color_slot'] as int?,
        userId: json['user_id'] as String?,
        leftAt: json['left_at'] as String?,
      );

  MemberView toView() => MemberView(
        id: id,
        fullName: fullName,
        colorSlot: colorSlot,
        isActiveMember: isActiveMember,
      );
}
