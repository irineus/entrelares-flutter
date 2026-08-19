/// F-32 client mirror — the freemium entitlement rule, ported from the web's
/// `Entrelares/Services/EntitlementService.cs`. The DATABASE is the single
/// source of truth (`public.is_premium()`); this mirror applies the exact same
/// rule to the family row the client already loaded, so the UI can show/hide
/// premium affordances without an extra round-trip. A stale or tampered client
/// value can only affect what the UI offers — never what the DB permits.
library;

/// Pure entitlement rule — mirrors `public.is_premium()` exactly. The rule
/// (locked July 2026): a family is premium when its plan is `premium`, OR it
/// holds the F-58 permanent courtesy comp, OR its 30-day trial is still
/// running. [nowUtc] is injected so the trial boundary is deterministic in
/// tests.
bool computeIsPremium({
  required String? plan,
  required DateTime? trialEndsAtUtc,
  required DateTime nowUtc,
  DateTime? compPremiumAtUtc,
}) {
  if (plan != null && plan.toLowerCase() == 'premium') return true;
  // F-58: the comp timestamp records WHEN it was granted — it is NOT an
  // expiry. Orthogonal to plan/trial so billing can never clobber it.
  if (compPremiumAtUtc != null) return true;
  return trialEndsAtUtc != null && trialEndsAtUtc.isAfter(nowUtc);
}

/// Entitlement snapshot for the UI: whether premium is active, whether that is
/// because of the trial, and how many days of trial remain.
class PlanStatus {
  final bool isPremium;
  final bool onTrial;
  final int? trialDaysLeft;

  const PlanStatus(this.isPremium, this.onTrial, this.trialDaysLeft);
}

/// How the current entitlement was reached — drives the plan status label.
/// Mirrors `EntitlementService.DescribePlan`: the trial countdown is
/// `ceil(days)` floored at 1, so the UI never says "0 days left"; comp and a
/// premium plan both hide the trial clock (a comped family inside a trial
/// shows no countdown — F-53's vocabulary owns the comp UX, here it must
/// simply BE premium).
PlanStatus describePlan({
  required String? plan,
  required DateTime? trialEndsAtUtc,
  required DateTime nowUtc,
  DateTime? compPremiumAtUtc,
}) {
  if (plan != null && plan.toLowerCase() == 'premium') {
    return const PlanStatus(true, false, null);
  }
  if (compPremiumAtUtc != null) return const PlanStatus(true, false, null);
  final ends = trialEndsAtUtc;
  if (ends != null && ends.isAfter(nowUtc)) {
    final daysLeft = (ends.difference(nowUtc).inMicroseconds /
            Duration.microsecondsPerDay)
        .ceil();
    return PlanStatus(true, true, daysLeft < 1 ? 1 : daysLeft);
  }
  return const PlanStatus(false, false, null);
}
