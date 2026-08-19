import 'package:entrelares_core/entrelares_core.dart' show PreEditNotes;

import '../models/app_notification.dart';
import '../models/care_schedule.dart';
import '../models/family.dart';
import '../models/member.dart';
import '../models/swap_request.dart';

/// What the calendar slice needs from the backend — an interface so widget
/// tests run against a fake while the real implementation talks to Supabase.
abstract class CustodyDataSource {
  Future<List<Member>> fetchMembers();

  /// The signed-in user's OWN profile row, or null when none exists. Read at
  /// gate time for the U-13 language adoption/detection sync — before the
  /// calendar loads, not inside it.
  Future<Member?> fetchOwnProfile();

  /// U-13: persists the user's explicit language CHOICE. Best-effort at the
  /// call site — the client's language does not depend on the server write.
  Future<void> updateOwnLanguage(int profileId, String languageCode);

  /// U-13: records what this session renders in (`language_detected`), so a
  /// sender with no browser can match the screen. Best-effort, every boot
  /// where it disagrees.
  Future<void> updateDetectedLanguage(int profileId, String languageCode);

  /// All rows of [year]/[month]. RLS scopes the family server-side.
  Future<List<CareSchedule>> fetchMonth(int year, int month);

  /// Rows from [from] (inclusive) through [from] + [days], date-ascending —
  /// the Today card's row + next-handoff scan window (mirror of the web's
  /// `GetNextHandoffDateAsync` fetch; the scan itself is pure, in core).
  Future<List<CareSchedule>> fetchUpcoming(DateTime from, int days);

  /// F-32: the signed-in user's family row (RLS yields at most one), or null.
  /// The entitlement mirror fails CLOSED on null by construction.
  Future<Family?> fetchOwnFamily();

  /// T-41: the PUBLIC `app_settings` rows as key→value (RLS exposes only the
  /// public ones). Callers cache load-once and fall back to the seeded
  /// defaults on failure, as the web does.
  Future<Map<String, String>> fetchPublicSettings();

  /// One day's row, or null when unassigned — mirror of the web's
  /// `GetScheduleForDateAsync` (the T-27 transition check on the 1st of the
  /// month needs the previous month's last day).
  Future<CareSchedule?> fetchDay(DateTime date);

  Future<void> insertDay(CareSchedule day);

  /// Full-row update carrying the T-33/T-35 echo (see CareSchedule).
  Future<void> updateDay(CareSchedule day);

  /// Clears an assigned day. Admin-only by DB rule (QA July 2026 — the UI
  /// mirrors with [isClearDayBlocked]); the trigger enforces regardless.
  Future<void> deleteDay(int id);

  /// The wizard's write path — mirror of `CustodyService.BulkUpsertAsync`:
  /// inserts only NEW future days (past and already-assigned days are
  /// skipped, never overwritten) and returns how many were created; the
  /// caller derives the "kept" count. [onProgress] reports 0–100.
  Future<int> bulkInsertNewDays(List<CareSchedule> days,
      {void Function(int percent)? onProgress});

  /// Starts listening for care_schedules changes; [onChange] fires on any
  /// insert/update/delete visible to this session. [onStatus] reports socket
  /// health (true = subscribed) — the F-23 safety poll adapts its cadence to
  /// it (owner decision 19/08/2026: the poll survives until the socket proves
  /// itself under real load). Returns a dispose callback.
  Future<void Function()> watchChanges(void Function() onChange,
      {void Function(bool connected)? onStatus});

  // ── Lote 3: swap-approval workflow (mirror of SwapRequestService.cs) ──────
  // No RPCs: the whole workflow is PostgREST CRUD plus one best-effort Edge
  // Function invoke. The mutations also write the workflow's in-app
  // notifications (composed in core, byte-identical to the web's stored
  // PT-BR sentences) — the DB stays the enforcement throughout.

  /// The month's OPEN requests (`pending`/`revert_pending`) — the F-12 frozen
  /// source. Months entirely in the past return empty without a round-trip.
  Future<List<SwapRequest>> fetchFrozenRequestsForMonth(int year, int month);

  /// Open requests awaiting MY response — the nav badge count and the
  /// "Para você" tab (⚠️ the bell badge counts THESE, not unread rows).
  Future<List<SwapRequest>> fetchPendingForMe(int myProfileId);

  /// Requests I sent, any status, newest 100 — the "Enviadas" tab is a
  /// recent-activity view, not an unbounded archive.
  Future<List<SwapRequest>> fetchSentRequests(int myProfileId);

  /// Opens a swap request for [schedule] (already upserted by the caller with
  /// scheduled parent + notes only). Enforces the F-28 scenario-C gate,
  /// snapshots the pre-edit log reference (F-26), inserts the request and the
  /// two notifications, then fires the best-effort e-mail.
  Future<void> createSwapRequest({
    required CareSchedule schedule,
    required int proposedActualParentId,
    String? proposedHandoffTime,
    String? requestMessage,
    required Member myProfile,
    required List<Member> allProfiles,
  });

  /// Applies the proposed change to the day (full-row T-33/T-35 echo), marks
  /// the request approved and notifies requester + self + uninvolved (F-28).
  Future<void> approveSwap(int swapRequestId,
      {String? approvalNote, required List<Member> allProfiles});

  Future<void> rejectSwap(int swapRequestId,
      {String? reason, required List<Member> allProfiles});

  Future<void> cancelSwap(int swapRequestId,
      {required List<Member> allProfiles});

  /// Opens a revert request for an approved swap. [restoreNotes] is the F-47
  /// answer — it travels WITH the request because the restore runs later and
  /// on the other side (approver's client or the 48h auto-approval).
  Future<void> requestRevert({
    required DateTime scheduleDate,
    required int currentActualProfileId,
    required int scheduledParentId,
    String? requestMessage,
    bool restoreNotes = false,
    required Member myProfile,
    required List<Member> allProfiles,
  });

  /// Restores the day to its pre-edit snapshot (F-26 plan computed in core),
  /// marks the request revert_approved and notifies.
  Future<void> approveRevert(int swapRequestId,
      {String? approvalNote, required List<Member> allProfiles});

  Future<void> rejectRevert(int swapRequestId,
      {String? reason, required List<Member> allProfiles});

  Future<void> cancelRevert(int swapRequestId,
      {required List<Member> allProfiles});

  /// F-47: the day's observation as the pre-edit snapshot holds it, or null
  /// when there is nothing to restore FROM (no approved swap on the date, no
  /// snapshot reference, or an old_data-less snapshot).
  Future<PreEditNotes?> fetchPreEditNotes(DateTime scheduleDate);

  /// My notifications, newest 100 — the "Histórico" tab.
  Future<List<AppNotification>> fetchNotifications(int myProfileId);

  /// Opening the Notifications page marks EVERYTHING read (web parity) — one
  /// bulk PATCH on my unread rows.
  Future<void> markAllNotificationsRead(int myProfileId);

  /// Listens for swap_requests + notifications changes — the lote-3 twin of
  /// [watchChanges] (frozen paint, badge, page refresh). Safe to call from
  /// more than one subscriber. Returns a dispose callback.
  Future<void Function()> watchWorkflowChanges(void Function() onChange,
      {void Function(bool connected)? onStatus});

  // ── Lote 4: sudo elevation (S-10) ─────────────────────────────────────────

  /// Exchanges the current password for the server's elevation window. Returns
  /// the `elevated_until` ISO instant the `elevate` Edge Function reports, or
  /// null when the response omits it (the caller falls back to the local
  /// 5-minute estimate).
  ///
  /// Throws [ElevationRefused] when the function answers with an error — the
  /// caller distinguishes a wrong password (which feeds the local throttle)
  /// from anything else. The identity always comes from the JWT: the password
  /// is proof, never a claim about WHO is elevating.
  Future<String?> elevate(String password);
}

/// Why the `elevate` Edge Function refused.
///
/// [serverMessage] is the function's OWN text and is preferred over any
/// client-side guess (pilot lesson 4: never collapse the server's error into a
/// generic one). The flags exist so the local throttle counts only genuine
/// wrong-password answers — a network hiccup must not spend an attempt.
class ElevationRefused implements Exception {
  final String? serverMessage;
  final bool wrongPassword;
  final bool rateLimited;

  const ElevationRefused({
    this.serverMessage,
    this.wrongPassword = false,
    this.rateLimited = false,
  });

  @override
  String toString() => 'ElevationRefused(${serverMessage ?? 'no message'})';
}
