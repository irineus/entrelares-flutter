/// Client mirrors of the freemium gate rules (F-37 caregiver cap, F-39
/// planning horizon) — ported from `entrelares-app`
/// `Entrelares/Helpers/FreemiumGates.cs`. These mirror, for UX only, limits
/// the DATABASE already enforces (`create_invitation` /
/// `enforce_day_protection`): a stale or tampered client can only change what
/// the UI offers, never what the DB permits.
library;

import 'date_math.dart';

// ── F-39 planning horizon ────────────────────────────────────────────────────

/// Months a family may plan ahead: premium horizon when entitled, otherwise
/// the free horizon. Values come from `app_settings` (T-41 mirror).
int planningHorizonMonths({
  required bool isPremium,
  required int freeMonths,
  required int premiumMonths,
}) =>
    isPremium ? premiumMonths : freeMonths;

/// Whether [targetMonth] is still within the planning horizon. Compared at
/// MONTH granularity (year*12+month) — the day component is irrelevant,
/// matching the calendar's month-by-month paging.
bool canPageToMonth(DateTime targetMonth, DateTime horizonDate) =>
    (targetMonth.year * 12 + targetMonth.month) <=
    (horizonDate.year * 12 + horizonDate.month);

/// True when a schedule's start date already sits beyond the horizon (so
/// nothing can be generated). Null horizon → no client limit (premium/unset).
bool isStartBeyondHorizon(DateTime start, DateTime? maxScheduleDate) =>
    maxScheduleDate != null &&
    dateOnly(start).isAfter(dateOnly(maxScheduleDate));

/// Clamps a generated plan's end date to the horizon. Returns the (possibly
/// clamped) end and whether clamping occurred — the caller uses the flag to
/// append the upsell/limit note. Null horizon → passed through.
({DateTime end, bool clamped}) clampScheduleEnd(
        DateTime end, DateTime? maxScheduleDate) =>
    maxScheduleDate != null && end.isAfter(maxScheduleDate)
        ? (end: maxScheduleDate, clamped: true)
        : (end: end, clamped: false);

// ── F-37 caregiver cap ───────────────────────────────────────────────────────

/// Seats a family occupies: active members plus open (pending) invitations.
/// Departed members (S-11) hold no seat and are excluded by the caller's
/// active count.
int seatsTaken({required int activeMembers, required int pendingInvitations}) =>
    activeMembers + pendingInvitations;

/// True when a non-premium family has reached the free caregiver limit and may
/// not add more. Premium is never capped here (the DB still bounds it by the
/// role-slot palette).
bool atFreeCaregiverCap({
  required bool isPremium,
  required int seatsTaken,
  required int freeLimit,
}) =>
    !isPremium && seatsTaken >= freeLimit;
