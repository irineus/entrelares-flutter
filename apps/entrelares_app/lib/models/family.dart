import 'package:entrelares_core/entrelares_core.dart';

/// The slice of the `families` row the entitlement mirror reads (F-32).
/// Mirrors `Entrelares/Models/Family.cs`: `plan` is written only by the
/// service-role RPC `set_family_plan`; `comp_premium_at` (F-58) only by
/// `admin_set_comp` — the client never writes any of this.
class Family {
  final int id;
  final String plan;
  final DateTime? trialEndsAt;
  final DateTime? compPremiumAt;

  const Family({
    required this.id,
    required this.plan,
    this.trialEndsAt,
    this.compPremiumAt,
  });

  factory Family.fromJson(Map<String, dynamic> json) => Family(
        id: json['id'] as int,
        plan: (json['plan'] as String?) ?? 'free',
        trialEndsAt: _utc(json['trial_ends_at'] as String?),
        compPremiumAt: _utc(json['comp_premium_at'] as String?),
      );

  static DateTime? _utc(String? wire) =>
      wire == null ? null : DateTime.parse(wire).toUtc();

  /// Mirror of `EntitlementService.IsPremium(Family?)`: null → free — the
  /// fail-closed default (an RLS-blocked or missing row never grants).
  static bool isPremiumFamily(Family? family, DateTime nowUtc) =>
      family != null &&
      computeIsPremium(
        plan: family.plan,
        trialEndsAtUtc: family.trialEndsAt,
        nowUtc: nowUtc,
        compPremiumAtUtc: family.compPremiumAt,
      );
}
