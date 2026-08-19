import 'package:entrelares_core/entrelares_core.dart' show PreEditNotes;

import '../models/app_notification.dart';
import '../models/care_schedule.dart';
import '../models/family.dart';
import '../models/family_deletion.dart';
import '../models/family_invitation.dart';
import '../models/invite_info.dart';
import '../models/member.dart';
import '../models/role.dart';
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

  // ── Lote 4: sign-up and invitations ───────────────────────────────────────

  /// Resolves an invitation token for an anonymous visitor, or null when the
  /// invitation is not usable. Unknown, accepted, revoked and expired tokens
  /// are all null — the RPC does not distinguish them, and neither may the UI.
  Future<InviteInfo?> fetchInviteInfo(String token);

  /// The FOUNDER branch. GoTrue creates the auth user carrying the metadata
  /// `handle_new_user` reads; the trigger is what creates family + profile
  /// atomically, so nothing here is a two-step the client could half-finish.
  ///
  /// Throws [SignUpFailure] with the catalog key to show — including for the
  /// anti-enumeration "silent duplicate" shape.
  Future<void> signUpFounder({
    required String email,
    required String password,
    required String fullName,
    required String role,
    required String familyName,
    required String languageCode,
  });

  /// The INVITEE branch (U-17), which is auto-confirmed and therefore cannot
  /// go through GoTrue sign-up: the `register-invitee` Edge Function creates
  /// the user with the service role after re-validating the invitation.
  Future<InviteeResult> registerInvitee({
    required String token,
    required String fullName,
    required String password,
    bool confirmMigration = false,
  });

  // ── Lote 4: family page, invitations and custom roles (F-41) ──────────────

  /// Every role this family may use: the 21 built-ins plus its own custom
  /// rows. RLS does the narrowing.
  Future<List<Role>> fetchRoles();

  /// Admin-only by DB rule; the rename is audited into `account_logs`.
  Future<void> renameFamily(String name);

  /// Invitations that are neither accepted nor revoked — pending AND expired,
  /// since the page offers a resend for the latter.
  Future<List<FamilyInvitation>> fetchOpenInvitations();

  /// `create_invitation` — which also REVOKES this address's previous open
  /// invitation before counting seats, so a resend never trips its own cap.
  /// That is what makes the call safe to retry. Returns the new row's id.
  Future<int> createInvitation({required String email, required int roleId});

  Future<void> revokeInvitation(int invitationId);

  /// Best-effort: the invitation exists either way, and the copyable link is
  /// the fallback the page always shows. Returns whether the mail went out.
  Future<bool> sendInvitationEmail(int invitationId);

  /// F-41. Server-enforced: admin, Premium, no duplicate (case-insensitive,
  /// against built-ins too). The client pre-checks only length/emoji.
  Future<void> createCustomRole({required String label, String? emoji});

  /// Omitting [emoji] CLEARS it — the RPC nulls a blank value.
  Future<void> updateCustomRole(
      {required int roleId, required String label, String? emoji});

  /// Delete is deliberately NOT Premium-gated (a family that lapses must still
  /// be able to clean up), but the DB refuses a role still in use.
  Future<void> deleteCustomRole(int roleId);

  // ── Lote 4: profile, account and the LGPD export ──────────────────────────

  /// My own name. A plain profile update — RLS bounds it to my row.
  Future<void> updateOwnName(int profileId, String fullName);

  /// Another member's name, admin-only by DB rule.
  Future<void> updateMemberName(int profileId, String fullName);

  /// Admin-only; audited into `account_logs` as `role_changed`.
  Future<void> setMemberRole({required int profileId, required int roleId});

  /// Admin-only AND sudo-gated (`ELEVATION_REQUIRED:`) — granting admin is the
  /// one membership change that hands out powers, so it costs a password.
  Future<void> setMemberAdmin({required int profileId, required bool isAdmin});

  /// Sends the password-reset e-mail to [email]. Used both for "I forgot mine"
  /// and for an admin helping another member.
  Future<void> sendPasswordReset(String email);

  /// Starts an e-mail change. GoTrue only APPLIES it once the confirmation
  /// link is clicked, so success here means "link sent", never "changed".
  Future<void> updateOwnEmail(String email);

  Future<void> updateOwnPassword(String password);

  /// The `log_account_action` RPC — a whitelist of three self-actions
  /// (`password_changed`, `email_change_requested`, `data_exported`). The
  /// account log is append-only and family-scoped.
  Future<void> logAccountAction(String action);

  /// F-17: every row RLS lets this member read, for the LGPD export.
  Future<ExportBundle> fetchExportData(int myProfileId);

  // ── Lote 4: leaving, family deletion (S-11) and re-consent (S-15) ─────────

  /// The family's live deletion request and its answers, or null when there is
  /// none. At most one `pending` row can exist (partial unique index).
  Future<PendingFamilyDeletion?> fetchPendingFamilyDeletion();

  /// Sudo-gated. Admin-only, and refused while the family has a single live
  /// member — that person deletes the family by leaving instead.
  Future<void> requestFamilyDeletion();

  /// [agree] null REMOVES my answer (back to "aguardando"). Deliberately NOT
  /// sudo-gated: agreeing is not the destructive act, executing is.
  Future<void> respondFamilyDeletion(bool? agree);

  /// Sudo-gated; the requester's own way out.
  Future<void> withdrawFamilyDeletion();

  /// Sudo-gated. Admin-only and re-checks unanimity server-side; sets the
  /// deadline to now.
  Future<void> executeFamilyDeletion();

  /// Runs the purge immediately after [executeFamilyDeletion] instead of
  /// waiting for the cron. Best-effort: the row is already scheduled.
  Future<void> purgeNow();

  /// S-11: schedules MY exit (30 days). [successorProfileId] is required by the
  /// DB when I am the only admin — it promotes them BEFORE letting me go.
  /// Sudo-gated.
  Future<void> requestAccountDeletion({int? successorProfileId});

  /// Sudo-gated. Refused when the family already filled my seat.
  Future<void> cancelAccountDeletion();

  /// Best-effort account e-mails (`member_left`, `member_returned`,
  /// `family_deletion_requested` and friends) through `send-account-email`.
  Future<void> sendAccountEmail(String emailType, {int? profileId});

  /// S-15: records acceptance of [PolicyVersions.current]. The RPC REFUSES a
  /// version that is not the one `app_settings` declares, so a client that is
  /// behind fails loudly instead of stamping an unconsented version.
  Future<void> acceptCurrentPolicy();

  // ── Lote 4: first-run onboarding (U-23) ───────────────────────────────────

  /// Whether an invitation is still open. Bounded to one row: the checklist
  /// only needs to know THAT one exists.
  Future<bool> hasOpenInvitation();

  /// The two facts only a query can answer. [includeSwapParticipation] is
  /// false whenever the explanation stamp already settles that step, so the
  /// calendar does not pay for a read it cannot use.
  Future<OnboardingFacts> fetchOnboardingFacts({
    required int myProfileId,
    bool includeSwapParticipation = true,
  });

  /// Writes one of the three U-23 stamps on MY profile row. Idempotent: a
  /// stamp that already exists is left alone, so "seen" keeps its first date.
  Future<void> stampOnboarding(OnboardingStamp stamp);

  /// Reopening the checklist from the profile clears the dismissal.
  Future<void> clearChecklistDismissal();
}

/// The three U-23 stamps, named rather than passed as column strings.
enum OnboardingStamp {
  swapExplained('onboarding_swap_explained_at'),
  tourSeen('onboarding_tour_seen_at'),
  dismissed('onboarding_dismissed_at');

  const OnboardingStamp(this.column);

  final String column;
}

class OnboardingFacts {
  /// At least one row in `care_schedules`, ANY date — someone who planned
  /// August in July has done that step.
  final bool hasAnyPlannedDay;

  /// This member requested, or was asked to approve, a swap.
  final bool hasTakenPartInASwap;

  const OnboardingFacts({
    this.hasAnyPlannedDay = false,
    this.hasTakenPartInASwap = false,
  });
}

/// The family-deletion request together with the answers to it — they are
/// always read as a pair, and the panel needs both to say anything true.
class PendingFamilyDeletion {
  final FamilyDeletionRequest request;
  final List<FamilyDeletionResponse> responses;

  const PendingFamilyDeletion(this.request, this.responses);
}

/// The raw material of the F-17 export. Assembling it into the published JSON
/// shape is a pure step (`ExportService.buildPayload`), so the payload can be
/// asserted without a backend.
class ExportBundle {
  final List<CareSchedule> schedules;
  final List<SwapRequest> swapRequests;
  final List<AppNotification> notifications;

  /// The audit trail, still untyped: the audit MODEL arrives with the reports
  /// slice (lote 6). Carrying the rows through as maps keeps the export
  /// COMPLETE meanwhile — an LGPD export missing a category would be the
  /// wrong thing to defer.
  final List<Map<String, dynamic>> activityLog;

  const ExportBundle({
    this.schedules = const [],
    this.swapRequests = const [],
    this.notifications = const [],
    this.activityLog = const [],
  });
}

/// A sign-up refusal, already translated to a catalog KEY (GoTrue answers in
/// English whatever the reader's language).
class SignUpFailure implements Exception {
  final String errorKey;

  const SignUpFailure(this.errorKey);

  @override
  String toString() => 'SignUpFailure($errorKey)';
}

/// How the invitee branch ended.
sealed class InviteeResult {
  const InviteeResult();
}

/// The account exists and is confirmed — the caller signs in immediately.
class InviteeRegistered extends InviteeResult {
  const InviteeRegistered();
}

/// S-11 cross-family migration: this address already belongs to another
/// family, and joining this one DELETES that registration. The Edge Function
/// refuses until the visitor confirms, so this is a question, not an error.
class InviteeNeedsMigration extends InviteeResult {
  final String? previousFamilyName;

  const InviteeNeedsMigration(this.previousFamilyName);
}

/// A refusal. [message] is the function's own PT-BR text when it sent one —
/// still not localized server-side, so it reaches an English reader in
/// Portuguese (same as the web).
class InviteeFailed extends InviteeResult {
  final String? message;

  const InviteeFailed(this.message);
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
