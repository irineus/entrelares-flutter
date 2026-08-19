/// Client mirrors of the swap-approval workflow rules — ported from
/// `entrelares-app` `Entrelares/Services/SwapRequestService.cs` (the static
/// helpers covered by `SwapRequestServiceLogicTests`) and from the resolve
/// subsets inline in `Home.razor`. The database is the enforcement (RLS, the
/// `swap_requests_one_pending_per_date` unique index, the day-protection
/// trigger); these exist so the UI decides upfront when a save becomes a
/// request and how urgency displays. Where the C# reads `DateTime.Today` /
/// `DateTime.Now` internally, these take `today` / `reference` as parameters:
/// pure functions, deterministic tests.
library;

import 'date_math.dart';
import 'day_protection_rules.dart';

// ── F-20/F-22: the dynamic priority tag ──────────────────────────────────────

/// F-20: never stored, always computed (mirror of `PriorityTag`).
enum SwapPriorityTag {
  none,

  /// Less than 24h to the handoff.
  urgent,

  /// The handoff time has passed.
  overdue,
}

/// The single urgency formula (mirror of `ComputePriorityTag`):
///   handoff = scheduleDate + (handoffTime ?? 00:00)
///   reference >= handoff        → overdue
///   handoff − reference < 24h   → urgent
///   otherwise                   → none
/// [handoffTime] is the wire string ("HH:mm" or "HH:mm:ss"); unparseable
/// values fall back to midnight, like the C# `?? TimeOnly.MinValue`.
SwapPriorityTag computePriorityTag(
    DateTime scheduleDate, String? handoffTime, DateTime reference) {
  final t = parseTimeOfDay(handoffTime);
  final handoff = DateTime(scheduleDate.year, scheduleDate.month,
      scheduleDate.day, t?.hour ?? 0, t?.minute ?? 0);
  if (!reference.isBefore(handoff)) return SwapPriorityTag.overdue;
  return handoff.difference(reference) < const Duration(hours: 24)
      ? SwapPriorityTag.urgent
      : SwapPriorityTag.none;
}

/// History semantics (mirror of the `SwapRequest` overload): a resolved
/// request is measured against its `resolved_at` (already converted to local
/// time by the caller), a pending one against the clock — so history shows
/// the state the request had at the moment it was resolved, forever.
SwapPriorityTag swapRequestPriorityTag({
  required DateTime scheduleDate,
  String? proposedHandoffTime,
  DateTime? resolvedAtLocal,
  required DateTime now,
}) =>
    computePriorityTag(scheduleDate, proposedHandoffTime,
        resolvedAtLocal ?? now);

/// The stored-title prefix (mirror of `PriorityTagPrefix`) — baked into the
/// PT-BR fallback sentence; the reader-language copy comes from `params.tag`
/// via the NotificationRenderer.
String priorityTagPrefix(SwapPriorityTag tag) => switch (tag) {
      SwapPriorityTag.urgent => '⚠️ URGENTE: ',
      SwapPriorityTag.overdue => '⏰ ATRASADO: ',
      SwapPriorityTag.none => '',
    };

/// The `params.tag` value (mirror of `PriorityTagParam`): null (dropped from
/// the payload) when there is no tag — the tag rides in params because it is
/// CONTENT, not a deploy marker (owner decision, Aug 2026).
String? priorityTagParam(SwapPriorityTag tag) => switch (tag) {
      SwapPriorityTag.urgent => 'urgent',
      SwapPriorityTag.overdue => 'overdue',
      SwapPriorityTag.none => null,
    };

/// "HH:mm" / "HH:mm:ss" → hour+minute, or null when absent/unparseable.
({int hour, int minute})? parseTimeOfDay(String? time) {
  if (time == null || time.isEmpty) return null;
  final parts = time.split(':');
  if (parts.length < 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return (hour: hour, minute: minute);
}

// ── The two workflow predicates + the F-28 scenario-C gate ──────────────────

/// Mirror of `ShouldTriggerWorkflow`: whether saving a day with this proposed
/// ACTUAL responsible must open a swap request instead of writing directly.
/// [proposedActualParentId] 0 means "none selected" (the web's dropdown
/// sentinel).
bool shouldTriggerWorkflow({
  required DateTime scheduleDate,
  int? currentActualParentId,
  required int scheduledParentId,
  required int proposedActualParentId,
  required DateTime today,
}) {
  if (isDayInPast(scheduleDate, today)) return false;
  if (proposedActualParentId == 0) return false;
  if (proposedActualParentId == scheduledParentId) return false;
  if (proposedActualParentId == currentActualParentId) return false;
  return true;
}

/// F-28: with N caregivers a swap may only be OPENED by someone who takes
/// part in it — the day's planned responsible (giving the day, scenario A) or
/// the member proposing themselves (taking it, scenario B). A third member
/// proposing someone ELSE (scenario C) would hand that person the day without
/// their consent. Mirror of `RequesterParticipates`.
bool requesterParticipates({
  required int requesterId,
  required int scheduledParentId,
  required int proposedActualParentId,
}) =>
    requesterId == scheduledParentId || requesterId == proposedActualParentId;

/// Mirror of `ShouldRequestRevert`: whether clearing/restoring a swapped day
/// must open a revert request. [newActualParentId] null or 0 both read as
/// "clearing the actual responsible".
bool shouldRequestRevert({
  required DateTime scheduleDate,
  int? currentActualParentId,
  int? newActualParentId,
  required int scheduledParentId,
  required DateTime today,
}) {
  if (isDayInPast(scheduleDate, today)) return false;
  if (currentActualParentId == null) return false;
  if (currentActualParentId == scheduledParentId) return false;

  return newActualParentId == null ||
      newActualParentId == 0 ||
      newActualParentId == scheduledParentId;
}

// ── F-44: free-text plumbing (requester message / approval note) ────────────

/// Stored trimmed; whitespace-only collapses to null so an empty input never
/// renders a dangling "Mensagem:" label anywhere. Mirror of
/// `NormalizeFreeText`.
String? normalizeFreeText(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// The ONE notification suffix for workflow communication (QA of F-44, Aug
/// 2026): requester message, approval note and rejection reason are all
/// "Mensagem" on screen — "Observação do dia" is reserved for the day-scoped
/// `care_schedules.notes`. Mirror of `MessageSuffix`.
String messageSuffix(String? message) {
  final normalized = normalizeFreeText(message);
  return normalized == null ? '' : ' Mensagem: $normalized';
}

// ── The slice of a `swap_requests` row the pure rules need ──────────────────

/// The app package maps its Supabase row type onto this (same pattern as
/// [DayAssignment]/[MemberView]).
class SwapRequestView {
  final int id;
  final DateTime scheduleDate; // date-only
  final String status;
  final int requestingProfileId;
  final int targetProfileId;

  /// Wire string ("HH:mm:ss"), as `care_schedules.handoff_time`.
  final String? proposedHandoffTime;

  /// `resolved_at` already converted to LOCAL time, or null while open.
  final DateTime? resolvedAtLocal;

  const SwapRequestView({
    required this.id,
    required this.scheduleDate,
    required this.status,
    required this.requestingProfileId,
    required this.targetProfileId,
    this.proposedHandoffTime,
    this.resolvedAtLocal,
  });

  /// A revert-flavored request (`FrozenDayPanel.isRevert`).
  bool get isRevertPending => status == 'revert_pending';

  SwapPriorityTag priorityTag(DateTime now) => swapRequestPriorityTag(
        scheduleDate: scheduleDate,
        proposedHandoffTime: proposedHandoffTime,
        resolvedAtLocal: resolvedAtLocal,
        now: now,
      );
}

/// The date-only set the F-12 frozen guards consume — derived from the
/// month's open requests (`GetFrozenDatesForMonthAsync` returns the rows;
/// the guards only need the dates).
Set<DateTime> frozenDatesOf(Iterable<SwapRequestView> openRequests) =>
    {for (final r in openRequests) dateOnly(r.scheduleDate)};

// ── Bulk resolution ("🔔 Resolver") subsets — mirrors of Home.razor ─────────

/// Open requests on selected days awaiting MY response (`SelectedPendingForMe`).
List<SwapRequestView> selectedPendingForMe({
  required Iterable<SwapRequestView> openRequests,
  required Set<DateTime> selectedDates,
  required int? myProfileId,
}) {
  final selected = {for (final d in selectedDates) dateOnly(d)};
  return [
    for (final r in openRequests)
      if (selected.contains(dateOnly(r.scheduleDate)) &&
          r.targetProfileId == myProfileId)
        r,
  ];
}

/// Open requests on selected days that I sent (`SelectedSentByMe`).
List<SwapRequestView> selectedSentByMe({
  required Iterable<SwapRequestView> openRequests,
  required Set<DateTime> selectedDates,
  required int? myProfileId,
}) {
  final selected = {for (final d in selectedDates) dateOnly(d)};
  return [
    for (final r in openRequests)
      if (selected.contains(dateOnly(r.scheduleDate)) &&
          r.requestingProfileId == myProfileId)
        r,
  ];
}

/// Whether a selected day qualifies for the bulk "request revert" section
/// (`SelectedRevertable`): today or future, carrying an approved swap (actual
/// set and ≠ scheduled), and not already frozen by an open request.
bool isRevertCandidate({
  required DateTime scheduleDate,
  required int scheduledParentId,
  int? actualParentId,
  required DateTime today,
  required Iterable<DateTime> frozenDates,
}) =>
    !isDayInPast(scheduleDate, today) &&
    actualParentId != null &&
    actualParentId != scheduledParentId &&
    !isDayFrozen(scheduleDate, frozenDates);
