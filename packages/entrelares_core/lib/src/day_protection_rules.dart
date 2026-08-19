/// Client mirrors of the day-protection rules (F-12/F-13/F-14 + the F-40
/// tier-aware retroactive reach) — ported from the guard properties inline in
/// `entrelares-app` `Entrelares/Pages/Home.razor` and from the
/// `enforce_day_protection` trigger (migration `20260724180000_f40`). The
/// trigger is the enforcement — including for admins; these exist so the UI
/// can refuse upfront and explain, and they must keep saying exactly what the
/// trigger says.
library;

import 'calendar_rules.dart';
import 'date_math.dart';

/// F-14: with admin mode ON (and the profile really being an admin) the UI
/// relaxes the single-day editor guards. Mirror of `Home.IsAdminBypass`.
bool isAdminBypass({required bool adminModeActive, required bool isAdmin}) =>
    adminModeActive && isAdmin;

/// F-13: past days are immutable for regular members. Date-only comparison
/// (T-07 semantics). Mirror of `Home.IsSelectedDayInPast`.
bool isDayInPast(DateTime date, DateTime today) =>
    dateOnly(date).isBefore(dateOnly(today));

/// F-12: a day with a pending/revert_pending swap request is frozen. The
/// [frozenDates] set comes from the swap-request fetch (lote 3 wires it; the
/// rule is date-only). Mirror of `Home.IsSelectedDayFrozen`.
bool isDayFrozen(DateTime date, Iterable<DateTime> frozenDates) {
  final d = dateOnly(date);
  return frozenDates.any((f) => dateOnly(f) == d);
}

/// F-12: a day carrying an APPROVED swap (actual set and ≠ scheduled) — such
/// days cannot be deleted by regular members. Same predicate as [isSwapped];
/// aliased so call sites read as the protection rule they mirror
/// (`Home.IsSelectedDayApprovedSwap`).
bool isApprovedSwapDay(DayAssignment? day) => isSwapped(day);

/// QA (July 2026): clearing an assigned day is ADMIN-ONLY across the board —
/// a regular member could delete + recreate the day with anyone, bypassing
/// the S-09 planned-parent rule. Mirror of `Home.IsClearDayBlocked`.
bool isClearDayBlocked({required bool adminBypass}) => !adminBypass;

/// Mirror of `Home.IsSaveDayBlocked`: the editor's save is blocked on past or
/// frozen days unless the admin bypass is active.
bool isSaveDayBlocked({
  required bool adminBypass,
  required bool isPast,
  required bool isFrozen,
}) =>
    !adminBypass && (isPast || isFrozen);

// ── F-40: tier-aware retroactive reach of the admin override ─────────────────
// The web client does not pre-compute this — it lets the trigger refuse and
// shows the propagated text. Porting it as a pure mirror (decision of
// 19/08/2026) lets the native editor explain/disable upfront; the trigger
// remains the enforcement, so the two must clamp to the SAME floor.

/// The earliest past date an active admin may still correct. Premium
/// (Administrador): `today − override_premium_months` — also the hard cap for
/// everyone. Free (Gestor): `today − override_free_days`. Month subtraction
/// clamps the day-of-month exactly like the trigger's `make_interval`.
DateTime adminRetroactiveFloor({
  required DateTime today,
  required bool isPremium,
  required int overrideFreeDays,
  required int overridePremiumMonths,
}) =>
    isPremium
        ? addMonthsClamped(dateOnly(today), -overridePremiumMonths)
        : DateTime(today.year, today.month, today.day - overrideFreeDays);

/// Whether the admin override reaches [date]. The trigger blocks
/// `the_date < floor`; the floor itself is editable.
bool isWithinAdminRetroactiveReach({
  required DateTime date,
  required DateTime today,
  required bool isPremium,
  required int overrideFreeDays,
  required int overridePremiumMonths,
}) =>
    !dateOnly(date).isBefore(adminRetroactiveFloor(
      today: today,
      isPremium: isPremium,
      overrideFreeDays: overrideFreeDays,
      overridePremiumMonths: overridePremiumMonths,
    ));
