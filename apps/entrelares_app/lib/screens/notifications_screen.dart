import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import '../widgets/ui/ui.dart';
import '../theme/tokens.dart';

import '../models/app_notification.dart';
import '../models/member.dart';
import '../models/swap_request.dart';
import '../services/custody_data_source.dart';
import '../services/notification_badge.dart';
import '../widgets/app_l10n.dart';
import '../widgets/app_snack.dart';

/// The Notifications page — port of `Notifications.razor`: three tabs
/// ("Para você" = open requests where I am the approver, "Enviadas" = my
/// newest 100 requests, "Histórico" = my newest 100 notification rows,
/// rebuilt in the READER's language by the NotificationRenderer). Opening the
/// page marks everything read (web parity — one bulk PATCH); the F-45 diff
/// list arrives with the audit mirror in lote 6 (decision 19/08/2026).
class NotificationsScreen extends StatefulWidget {
  final CustodyDataSource dataSource;
  final NotificationBadge badge;

  const NotificationsScreen(
      {super.key, required this.dataSource, required this.badge});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

enum _Tab { incoming, sent, history }

/// Mirror of `GetNotifIcon`.
String notifIcon(String type) => switch (type) {
      'swap_requested' => '🔄',
      'swap_sent' => '📤',
      'swap_approved' => '✅',
      'swap_approved_self' => '✅',
      'swap_rejected' => '❌',
      'swap_cancelled' => '🚫',
      'swap_reverted' => '↩️',
      'revert_requested' => '↩️',
      'revert_sent' => '📤',
      'revert_approved' => '✅',
      'revert_approved_self' => '✅',
      'revert_rejected' => '❌',
      'revert_cancelled' => '🚫',
      'auto_reminder' => '⏰',
      'auto_approved' => '🤖',
      'swap_family_info' => '👪',
      'email_cap_80' => '⚠️',
      'email_cap_last' => '✉️',
      'email_cap_reached' => '✉️',
      'billing' => '💳',
      _ => '🔔',
    };

class _NotificationsScreenState extends State<NotificationsScreen> {
  _Tab _tab = _Tab.incoming;
  bool _loading = true;
  String? _loadError;
  List<Member> _allProfiles = const [];
  Member? _ownProfile;
  List<SwapRequest> _incoming = const [];
  List<SwapRequest> _sent = const [];
  List<AppNotification> _history = const [];

  /// F-44: one dual-purpose note per incoming card (approval note on approve,
  /// rejection reason on reject — same decision as the frozen panel).
  final Map<int, TextEditingController> _approverNotes = {};

  /// Which request is being acted on (disables its card's buttons) and the
  /// per-card error text.
  final Map<int, String> _actioning = {};
  final Map<int, String> _actionErrors = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    for (final c in _approverNotes.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _noteFor(int requestId) =>
      _approverNotes.putIfAbsent(requestId, TextEditingController.new);

  Future<void> _init() async {
    await _loadAll();
    // Web parity (OnInitializedAsync): refresh the badge, then mark
    // everything read — best-effort, never blocks the page.
    await widget.badge.refresh();
    try {
      final me = _ownProfile;
      if (me != null) {
        await widget.dataSource.markAllNotificationsRead(me.id);
      }
    } catch (_) {/* best-effort */}
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    try {
      final profiles = await widget.dataSource.fetchMembers();
      final me = await widget.dataSource.fetchOwnProfile();
      final incoming =
          me == null ? <SwapRequest>[] : await widget.dataSource.fetchPendingForMe(me.id);
      final sent =
          me == null ? <SwapRequest>[] : await widget.dataSource.fetchSentRequests(me.id);
      final history = me == null
          ? <AppNotification>[]
          : await widget.dataSource.fetchNotifications(me.id);
      if (!mounted) return;
      setState(() {
        _allProfiles = profiles;
        _ownProfile = me;
        _incoming = incoming;
        _sent = sent;
        _history = history;
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      final l = AppL10n.of(context).l;
      setState(() {
        _loading = false;
        _loadError = isSessionExpired(e.toString())
            ? sessionExpiredMessage(l)
            : l[KApp.errCalendarLoad];
      });
    }
  }

  String? _nameOf(int? id) {
    for (final p in _allProfiles) {
      if (p.id == id) return p.fullName;
    }
    return null;
  }

  Future<void> _act(
    SwapRequest req,
    String action,
    String errorKey,
    String toastKey,
    Future<void> Function() run,
  ) async {
    final l = AppL10n.of(context).l;
    setState(() {
      _actioning[req.id] = action;
      _actionErrors.remove(req.id);
    });
    try {
      await run();
      await _loadAll();
      await widget.badge.refresh();
      if (mounted) showAppSnack(context, l[toastKey]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _actionErrors[req.id] = isSessionExpired(e.toString())
            ? sessionExpiredMessage(l)
            : l.format(errorKey, [e.toString()]);
      });
    } finally {
      if (mounted) setState(() => _actioning.remove(req.id));
    }
  }

  String? _noteText(int requestId) {
    final text = _noteFor(requestId).text;
    return text.trim().isEmpty ? null : text;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
    return Scaffold(
      appBar: AppBar(title: Text(l[K.notifPageTitle])),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: AppSegmented<_Tab>(
              options: [
                (
                  value: _Tab.incoming,
                  label: _incoming.isEmpty
                      ? l[K.notifTabIncoming]
                      : '${l[K.notifTabIncoming]} (${_incoming.length})'
                ),
                (value: _Tab.sent, label: l[K.notifTabSent]),
                (value: _Tab.history, label: l[K.notifTabHistory]),
              ],
              selected: _tab,
              onChanged: (v) => setState(() => _tab = v),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await _loadAll();
                await widget.badge.refresh();
              },
              child: _loading
                  ? AppSkeletonList(rows: 3, semanticsLabel: l[K.famLoading])
                  : _loadError != null
                      ? ListView(children: [
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(_loadError!,
                                textAlign: TextAlign.center),
                          )
                        ])
                      : switch (_tab) {
                          _Tab.incoming => _incomingTab(l),
                          _Tab.sent => _sentTab(l),
                          _Tab.history => _historyTab(l),
                        },
            ),
          ),
        ],
      ),
    );
  }

  // Still a ListView: the empty tab has to stay pull-to-refreshable, which is
  // the one thing the shared component cannot know about.
  Widget _empty(String icon, String textKey, Localization l) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: Spacing.md),
          AppEmptyState(icon: icon, title: l[textKey]),
        ],
      );

  Widget _infoRow(String label, String value) =>
      AppListRow(label: label, value: value);

  /// U-28 — a card's first line: the day on the left, its state pills on the
  /// right, and a SECOND LINE for the pills when they do not fit.
  ///
  /// It was a `Row` with the date in an `Expanded` beside a `Wrap` of up to
  /// three badges. `Row` lays the inflexible child out first, so the badges took
  /// the width they wanted and the `Expanded` got what was left — around ten
  /// pixels, which the date then filled ONE CHARACTER PER LINE while the badges
  /// still reported `RIGHT OVERFLOWED BY 85 PIXELS`. A `Wrap` cannot do that to
  /// itself: what does not fit moves down.
  Widget _cardHeader(String title, List<Widget> badges) => Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.xs,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          Wrap(spacing: Spacing.xs, runSpacing: Spacing.xs, children: badges),
        ],
      );

  Widget _statusBadge(String text, {ToneColors? tone, String? semantics}) =>
      AppBadge(
        text: text,
        tone: tone ?? context.tokens.neutral,
        semantics: semantics,
      );

  Widget _tagBanner(SwapPriorityTag tag, Localization l) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: AppBanner(
          tone: tag == SwapPriorityTag.overdue
              ? context.tokens.danger
              : context.tokens.warning,
          bordered: false,
          message: l[
              tag == SwapPriorityTag.overdue ? K.frozenOverdue : K.frozenUrgent],
        ),
      );

  Widget _card({required List<Widget> children}) => Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm + Spacing.xs, vertical: Spacing.sm - 2),
        child: AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      );

  // ── "Para você" ────────────────────────────────────────────────────────────

  Widget _incomingTab(Localization l) {
    if (_incoming.isEmpty) return _empty('✅', K.notifEmptyIncoming, l);
    final now = DateTime.now();
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        for (final req in _incoming) _incomingCard(req, now, l),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _incomingCard(SwapRequest req, DateTime now, Localization l) {
    final isRevert = req.isRevertPending;
    final tag = req.toView().priorityTag(now); // F-20: pending → clock
    final handoff = parseTimeOfDay(req.proposedHandoffTime);
    final createdLocal = req.createdAt == null
        ? null
        : DateTime.tryParse(req.createdAt!)?.toLocal();
    final acting = _actioning.containsKey(req.id);
    final error = _actionErrors[req.id];

    return _card(children: [
      _cardHeader('📅 ${l.formatDate(req.scheduleDate)}', [
        _statusBadge(
          l[isRevert ? K.notifRevertPendingBadge : K.notifPendingBadge],
          tone: isRevert ? context.tokens.accent : context.tokens.warning,
        ),
      ]),
      if (tag != SwapPriorityTag.none) _tagBanner(tag, l),
      _infoRow(l[K.notifLabelRequester],
          _nameOf(req.requestingProfileId) ?? '—'),
      // F-44: the requester's message, shown to the approver.
      if ((req.requestMessage ?? '').isNotEmpty)
        _infoRow(l[K.notifLabelRequesterMessage], req.requestMessage!),
      if (isRevert)
        _infoRow(
            l[K.notifLabelRevertTo], _nameOf(req.proposedActualParentId) ?? '—')
      else
        _infoRow(l[K.notifLabelProposes],
            '${_nameOf(req.proposedActualParentId) ?? '—'} ${l[K.notifProposesSuffix]}'),
      if (handoff != null)
        _infoRow(
            l[K.notifLabelTime],
            '${handoff.hour.toString().padLeft(2, '0')}:'
            '${handoff.minute.toString().padLeft(2, '0')}'),
      if (createdLocal != null)
        _infoRow(
            l[K.notifLabelRequestedAt], l.formatDateTimeShort(createdLocal)),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('⚠️ $error',
              style: TextStyle(
                  color: context.tokens.danger.onContainer,
                  fontSize: TypeScale.label)),
        ),
      const SizedBox(height: 8),
      // U-27: a placeholder-only field has no accessible name once it has
      // text in it — the label is permanent, the placeholder stays a hint.
      AppTextField(
        label: l[K.wfMessage],
        hint: l[K.notifNotePlaceholder],
        controller: _noteFor(req.id),
        maxLength: 200,
        enabled: !acting,
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: acting
                  ? null
                  : () => isRevert
                      ? _act(
                          req,
                          'approve',
                          K.errConfirmRevertFailed,
                          K.toastRevertConfirmed,
                          () => widget.dataSource.approveRevert(req.id,
                              approvalNote: _noteText(req.id),
                              allProfiles: _allProfiles))
                      : _act(
                          req,
                          'approve',
                          K.errApproveFailed,
                          K.toastSwapApproved,
                          () => widget.dataSource.approveSwap(req.id,
                              approvalNote: _noteText(req.id),
                              allProfiles: _allProfiles)),
              child: _actioning[req.id] == 'approve'
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l[
                      isRevert ? K.notifBtnConfirmRevert : K.notifBtnApprove]),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: acting
                  ? null
                  : () => isRevert
                      ? _act(
                          req,
                          'reject',
                          K.errRejectRevertFailed,
                          K.toastRevertRejected,
                          () => widget.dataSource.rejectRevert(req.id,
                              reason: _noteText(req.id),
                              allProfiles: _allProfiles))
                      : _act(
                          req,
                          'reject',
                          K.errRejectFailed,
                          K.toastSwapRejected,
                          () => widget.dataSource.rejectSwap(req.id,
                              reason: _noteText(req.id),
                              allProfiles: _allProfiles)),
              child: _actioning[req.id] == 'reject'
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l[K.notifBtnReject]),
            ),
          ),
        ],
      ),
    ]);
  }

  // ── "Enviadas" ─────────────────────────────────────────────────────────────

  Widget _sentTab(Localization l) {
    if (_sent.isEmpty) return _empty('📤', K.notifEmptySent, l);
    final now = DateTime.now();
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        for (final req in _sent) _sentCard(req, now, l),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _sentCard(SwapRequest req, DateTime now, Localization l) {
    final isPending = req.status == 'pending' || req.status == 'revert_pending';
    // F-20: pending → live tag; resolved → frozen at resolved_at.
    final tag = req.toView().priorityTag(now);
    final createdLocal = req.createdAt == null
        ? null
        : DateTime.tryParse(req.createdAt!)?.toLocal();
    final acting = _actioning.containsKey(req.id);
    final error = _actionErrors[req.id];
    final statusKey = swapStatusLabelKey(req.status);

    return _card(children: [
      _cardHeader('📅 ${l.formatDate(req.scheduleDate)}', [
        // The state the request had AT RESOLUTION, kept forever (F-20).
        if (!isPending && tag != SwapPriorityTag.none)
          _statusBadge(
            l[tag == SwapPriorityTag.overdue
                ? K.notifTagOverdueShort
                : K.notifTagUrgentShort],
            tone: tag == SwapPriorityTag.overdue
                ? context.tokens.danger
                : context.tokens.warning,
            semantics: l[K.notifResolvedStateTitle],
          ),
        _statusBadge(statusKey == null ? req.status : l[statusKey]),
        // F-24: resolved by the 48h server cron.
        if (req.isAutoResolved)
          _statusBadge(l[K.notifAutoBadge],
              tone: context.tokens.info,
              semantics: l[K.notifAutoBadgeTitle]),
      ]),
      _infoRow(l[K.notifLabelTo], _nameOf(req.targetProfileId) ?? '—'),
      _infoRow(l[K.notifLabelProposed],
          _nameOf(req.proposedActualParentId) ?? '—'),
      if (isPending && tag != SwapPriorityTag.none) _tagBanner(tag, l),
      // F-44: the sender sees their own message and, once resolved, the
      // approver's note / rejection reason.
      if ((req.requestMessage ?? '').isNotEmpty)
        _infoRow(l[K.notifLabelYourMessage], req.requestMessage!),
      if ((req.approvalNote ?? '').isNotEmpty)
        _infoRow(l[K.notifLabelApproverMessage], req.approvalNote!),
      if ((req.rejectionReason ?? '').isNotEmpty)
        _infoRow(l[K.notifLabelApproverMessage], req.rejectionReason!),
      if (createdLocal != null)
        _infoRow(
            l[K.notifLabelRequestedAt], l.formatDateTimeShort(createdLocal)),
      if (isPending) ...[
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('⚠️ $error',
                style: TextStyle(
                    color: context.tokens.danger.onContainer,
                    fontSize: TypeScale.label)),
          ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: acting
              ? null
              : () => req.isRevertPending
                  ? _act(
                      req,
                      'cancel',
                      K.errCancelRevertFailed,
                      K.toastRevertCancelled,
                      () => widget.dataSource
                          .cancelRevert(req.id, allProfiles: _allProfiles))
                  : _act(
                      req,
                      'cancel',
                      K.errCancelFailed,
                      K.toastRequestCancelled,
                      () => widget.dataSource
                          .cancelSwap(req.id, allProfiles: _allProfiles)),
          style: OutlinedButton.styleFrom(
              foregroundColor: context.tokens.danger.onContainer),
          child: acting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l[req.isRevertPending
                  ? K.notifBtnCancelRevert
                  : K.notifBtnCancelRequest]),
        ),
      ],
    ]);
  }

  // ── "Histórico" ────────────────────────────────────────────────────────────

  Widget _historyTab(Localization l) {
    if (_history.isEmpty) return _empty('🔔', K.notifEmptyHistory, l);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        for (final notif in _history) _historyItem(notif, l),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _historyItem(AppNotification notif, Localization l) {
    final createdLocal = notif.createdAt == null
        ? null
        : DateTime.tryParse(notif.createdAt!)?.toLocal();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(notifIcon(notif.type), style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // U-13: the row was written in the LANGUAGE OF WHOEVER ACTED,
                // so the stored sentence is only correct by accident. Rebuild
                // from type + params in THIS reader's language; rows written
                // before the item carry no params and render as stored.
                Text(
                  NotificationRenderer.title(
                      notif.type, notif.paramsJson, notif.title, l),
                  style: TextStyle(
                      fontWeight:
                          notif.isRead ? FontWeight.normal : FontWeight.w600),
                ),
                Text(
                  NotificationRenderer.message(
                      notif.type, notif.paramsJson, notif.message, l),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (createdLocal != null)
                  Text(l.formatDateTime(createdLocal),
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: Theme.of(context).hintColor)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
