import 'dart:async';

import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../models/care_schedule.dart';
import '../models/family.dart';
import '../models/member.dart';
import '../models/swap_request.dart';
import '../services/admin_mode.dart';
import '../services/custody_data_source.dart';
import '../widgets/app_l10n.dart';
import '../widgets/app_snack.dart';
import '../widgets/today_card.dart';
import 'bulk_sheet.dart';
import 'day_sheet.dart';
import 'frozen_day_sheet.dart';
import 'resolve_sheet.dart';
import 'wizard_sheet.dart';

/// F-27 slot palette (slot 0 = gray: inactive/unknown); swapped is its own
/// color, matching the web's "Trocado" convention.
const slotColors = <int, Color>{
  0: Color(0xFF9E9E9E),
  1: Color(0xFF4F46E5),
  2: Color(0xFF0D9488),
  3: Color(0xFFD97706),
  4: Color(0xFFDB2777),
};
const swappedColor = Color(0xFFE11D48);

class CalendarScreen extends StatefulWidget {
  final CustodyDataSource dataSource;
  final AdminMode adminMode;
  final Future<void> Function() onSignOut;

  const CalendarScreen(
      {super.key,
      required this.dataSource,
      required this.adminMode,
      required this.onSignOut});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen>
    with WidgetsBindingObserver {
  // Improvement over the web (owner directive): months are swipeable pages.
  // _basePage maps to the month shown at startup; ±offset navigates.
  static const _basePage = 1200;
  late final PageController _pageController;
  late DateTime _anchorMonth; // month at _basePage — never reassigned
  late DateTime _visibleMonth;

  List<Member> _members = const [];
  Map<String, CareSchedule> _daysByIso = const {};
  Member? _ownProfile;
  // Today + the next-handoff window ([today, today + 91] — the web scans
  // [tomorrow, tomorrow + 90]; one query serves the card's row and the scan).
  List<CareSchedule> _upcoming = const [];
  // F-12: the visible month's OPEN swap requests — the frozen-day source
  // (paint, guards, panel). Keyed alongside _daysByIso on every load.
  Map<String, SwapRequest> _frozenByIso = const {};
  bool _loading = true;
  String? _loadError;
  void Function()? _unwatch;
  void Function()? _unwatchWorkflow;

  // F-23: the safety poll survives the native Realtime until the socket
  // proves itself under real load (owner decision 19/08/2026). Adaptive
  // cadence (25 s down / 120 s healthy), paused while backgrounded and
  // refreshed on resume — mirror of Home.razor's poll + visibility handling.
  Timer? _pollTimer;
  bool _socketConnected = false;

  // F-39 horizon inputs (T-41 settings + F-32 entitlement), loaded once like
  // the web's OnInitialized. The web call site is deliberately fail-OPEN: a
  // failed entitlement read defaults to premium so paging is never wrongly
  // blocked — the DB enforces the real limit regardless.
  Family? _family;
  bool _entitlementFailed = false;
  PublicSettings _settings = PublicSettings.unloaded;

  DateTime get _today => DateTime.now();

  bool get _isPremiumForPaging => _entitlementFailed ||
      Family.isPremiumFamily(_family, DateTime.now().toUtc());

  DateTime get _horizonDate => addMonthsClamped(
      _today,
      planningHorizonMonths(
        isPremium: _isPremiumForPaging,
        freeMonths: _settings.calendarMonthsFree,
        premiumMonths: _settings.calendarMonthsPremium,
      ));

  /// F-14: bypass only with the mode ON and the profile really an admin.
  bool get _adminBypass => isAdminBypass(
      adminModeActive: widget.adminMode.isActive,
      isAdmin: _ownProfile?.isAdmin ?? false);

  // ── Bulk selection (U-11): long-press arms it; the ☑️ button is the
  //    accessible entry point. Mirror of Home.razor's selection state.
  final Set<DateTime> _selectedDays = {};
  bool _selectionArmed = false;

  bool get _isSelectionMode => isSelectionMode(
      selectedCount: _selectedDays.length, armed: _selectionArmed);

  @override
  void initState() {
    super.initState();
    final now = _today;
    _anchorMonth = DateTime(now.year, now.month, 1);
    _visibleMonth = _anchorMonth;
    _pageController = PageController(initialPage: _basePage);
    WidgetsBinding.instance.addObserver(this);
    widget.adminMode.addListener(_onAdminModeChanged);
    _load();
    _loadHorizonInputs();
    _watch();
    _schedulePoll();
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    _pollTimer = Timer(
        Duration(milliseconds: pollIntervalMs(socketConnected: _socketConnected)),
        () {
      if (mounted) _load(silent: true);
      _schedulePoll();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Mirror of OnVisibilityChanged: no polling on a hidden app; a fresh
    // load + a new timer on return.
    if (state == AppLifecycleState.resumed) {
      _load(silent: true);
      _schedulePoll();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _onAdminModeChanged() {
    if (mounted) setState(() {});
  }

  /// Defensive like the web: neither read may break the calendar — entitlement
  /// falls to premium, settings to the seeded fallbacks (no wrongful block).
  Future<void> _loadHorizonInputs() async {
    Family? family;
    var failed = false;
    try {
      family = await widget.dataSource.fetchOwnFamily();
    } catch (_) {
      failed = true;
    }
    var settings = PublicSettings.unloaded;
    try {
      settings = PublicSettings(await widget.dataSource.fetchPublicSettings());
    } catch (_) {/* seeded fallbacks */}
    if (!mounted) return;
    setState(() {
      _family = family;
      _entitlementFailed = failed;
      _settings = settings;
    });
  }

  Future<void> _watch() async {
    // Native Realtime — the whole reason F-29's JS bridge retires. Any change
    // another member saves shows up here without polling. The socket's health
    // drives the F-23 poll cadence.
    _unwatch = await widget.dataSource.watchChanges(
      () {
        if (mounted) _load(silent: true);
      },
      onStatus: (connected) {
        if (!mounted) return;
        if (connected != _socketConnected) {
          _socketConnected = connected;
          if (_pollTimer != null) _schedulePoll();
        }
      },
    );
    // Lote 3: the workflow channel — a request opened/resolved by the other
    // member repaints the frozen days without a manual refresh.
    _unwatchWorkflow = await widget.dataSource.watchWorkflowChanges(() {
      if (mounted) _load(silent: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.adminMode.removeListener(_onAdminModeChanged);
    _unwatch?.call();
    _unwatchWorkflow?.call();
    _pollTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  DateTime _monthForPage(int page) =>
      DateTime(_anchorMonth.year, _anchorMonth.month + (page - _basePage), 1);

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final members = await widget.dataSource.fetchMembers();
      final days = await widget.dataSource
          .fetchMonth(_visibleMonth.year, _visibleMonth.month);
      final frozen = await widget.dataSource
          .fetchFrozenRequestsForMonth(_visibleMonth.year, _visibleMonth.month);
      final ownProfile = await widget.dataSource.fetchOwnProfile();
      final upcoming = await widget.dataSource
          .fetchUpcoming(_today, nextHandoffWindowDays + 1);
      if (!mounted) return;
      setState(() {
        _members = members;
        _daysByIso = {
          for (final d in days) CareSchedule.isoDate(d.scheduleDate): d
        };
        // Web parity (Home's frozenRequests.First per day): one request per
        // date matters — the DB's one-pending-per-date index guarantees it.
        _frozenByIso = {
          for (final r in frozen) CareSchedule.isoDate(r.scheduleDate): r
        };
        _ownProfile = ownProfile;
        _upcoming = upcoming;
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

  int _pageForMonth(DateTime month) =>
      _basePage +
      (month.year * 12 + month.month) -
      (_anchorMonth.year * 12 + _anchorMonth.month);

  void _bounceBack() {
    _pageController.animateToPage(_pageForMonth(_visibleMonth),
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  /// The web's navigation guard: month navigation while days are selected
  /// asks before discarding the selection. Returns whether to proceed.
  Future<bool> _confirmDiscardSelection() async {
    final l = AppL10n.of(context).l;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.format(
            _selectedDays.length == 1
                ? K.navGuardSelectedOne
                : K.navGuardSelectedMany,
            [_selectedDays.length])),
        content: Text(l[K.navGuardBody]),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l[K.navGuardYes])),
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l[K.navGuardNo])),
        ],
      ),
    );
    if (proceed == true) {
      _cancelSelection();
      return true;
    }
    return false;
  }

  Future<void> _onPageChanged(int page) async {
    final month = _monthForPage(page);
    // The bounce-back below re-fires with the month already shown — no-op.
    if (month.year == _visibleMonth.year && month.month == _visibleMonth.month) {
      return;
    }
    // F-39 mirror of the web's NextMonth: paging stops at the family's
    // planning horizon with the tier message instead of advancing. The
    // horizon check comes BEFORE the guard, same order as NextMonth.
    if (!canPageToMonth(month, _horizonDate)) {
      showAppSnack(
          context,
          _isPremiumForPaging
              ? AppL10n.of(context).l.format(
                  K.horizonPremium, [_settings.calendarMonthsPremium])
              : AppL10n.of(context).l.format(K.horizonFree, [
                  _settings.calendarMonthsFree,
                  _settings.calendarMonthsPremium,
                ]));
      _bounceBack();
      return;
    }
    if (_isSelectionMode && !await _confirmDiscardSelection()) {
      _bounceBack();
      return;
    }
    setState(() => _visibleMonth = month);
    _load();
  }

  List<MemberView> get _memberViews =>
      _members.map((m) => m.toView()).toList(growable: false);

  void _toggleDaySelection(DateTime date) {
    final d = dateOnly(date);
    setState(() {
      if (!_selectedDays.remove(d)) _selectedDays.add(d);
    });
  }

  /// Mirror of LongPressDay: entering selection always ADDS the day.
  void _onDayLongPress(DateTime date) {
    HapticFeedback.mediumImpact();
    setState(() => _selectedDays.add(dateOnly(date)));
  }

  void _onDayTap(DateTime date) {
    if (_isSelectionMode) {
      HapticFeedback.selectionClick();
      _toggleDaySelection(date);
      return;
    }
    // Web parity (HandleDayClick): a day with a pending request opens the
    // frozen panel instead of the editor — for everyone, admins included.
    final frozen = _frozenByIso[CareSchedule.isoDate(date)];
    if (frozen != null) {
      _openFrozenDay(frozen);
      return;
    }
    _openDay(date);
  }

  Future<void> _openFrozenDay(SwapRequest request) async {
    HapticFeedback.selectionClick();
    final outcome = await showFrozenDaySheet(
      context: context,
      request: request,
      allProfiles: _members,
      ownProfileId: _ownProfile?.id,
      dataSource: widget.dataSource,
    );
    if (outcome != null) {
      _load(silent: true);
      if (mounted) {
        showAppSnack(
            context, AppL10n.of(context).l[frozenOutcomeToastKey(outcome)]);
      }
    }
  }

  void _cancelSelection() {
    setState(() {
      _selectedDays.clear();
      _selectionArmed = false;
    });
  }

  Future<void> _openBulkSheet() async {
    final summary = await showBulkSheet(
      context: context,
      selectedDays: Set.of(_selectedDays),
      daysByIso: _daysByIso,
      activeMembers: _members.where((m) => m.isActiveMember).toList(),
      today: _today,
      dataSource: widget.dataSource,
      adminBypass: _adminBypass,
      frozenDates: [for (final r in _frozenByIso.values) r.scheduleDate],
      myProfile: _ownProfile,
      allProfiles: _members,
    );
    if (summary != null) {
      // Mirror of FinishBulkSave: the selection clears (armed state stays),
      // the month reloads and the summary is the toast.
      setState(() => _selectedDays.clear());
      _load(silent: true);
      if (mounted) showAppSnack(context, summary);
    }
  }

  /// Mirror of `WorkflowActionableCount`: how many selected days carry an
  /// action for the resolve sheet (awaiting me + sent by me + revertable).
  int get _workflowActionableCount {
    final views = [for (final r in _frozenByIso.values) r.toView()];
    final frozenDates = [for (final r in _frozenByIso.values) r.scheduleDate];
    var revertable = 0;
    for (final d in _selectedDays) {
      final row = _daysByIso[CareSchedule.isoDate(d)];
      if (row != null &&
          isRevertCandidate(
            scheduleDate: row.scheduleDate,
            scheduledParentId: row.scheduledParentId,
            actualParentId: row.actualParentId,
            today: _today,
            frozenDates: frozenDates,
          )) {
        revertable++;
      }
    }
    return selectedPendingForMe(
                openRequests: views,
                selectedDates: _selectedDays,
                myProfileId: _ownProfile?.id)
            .length +
        selectedSentByMe(
                openRequests: views,
                selectedDates: _selectedDays,
                myProfileId: _ownProfile?.id)
            .length +
        revertable;
  }

  Future<void> _openResolveSheet() async {
    final summary = await showResolveSheet(
      context: context,
      selectedDays: Set.of(_selectedDays),
      openRequests: _frozenByIso.values.toList(),
      daysByIso: _daysByIso,
      today: _today,
      ownProfileId: _ownProfile?.id,
      myProfile: _ownProfile,
      allProfiles: _members,
      dataSource: widget.dataSource,
    );
    if (summary != null) {
      // Mirror of RunBulkWorkflowAsync's close: selection clears, month
      // reloads, the summary is the toast.
      setState(() => _selectedDays.clear());
      _load(silent: true);
      if (mounted) showAppSnack(context, summary);
    }
  }

  Future<void> _openWizard() async {
    final generated = await showWizardSheet(
      context: context,
      activeMembers: _members.where((m) => m.isActiveMember).toList(),
      today: _today,
      dataSource: widget.dataSource,
      // F-39: the wizard clamps to the same horizon as the paging.
      maxScheduleDate: _horizonDate,
      isFreeTier: !_isPremiumForPaging,
    );
    if (generated == true) _load(silent: true);
  }

  Future<void> _openDay(DateTime date) async {
    HapticFeedback.selectionClick();
    final iso = CareSchedule.isoDate(date);
    final previousIso =
        CareSchedule.isoDate(date.subtract(const Duration(days: 1)));
    final outcome = await showDaySheet(
      context: context,
      date: date,
      day: _daysByIso[iso],
      previousDay: _daysByIso[previousIso],
      members: _members.where((m) => m.isActiveMember).toList(),
      memberViews: _memberViews,
      today: _today,
      dataSource: widget.dataSource,
      adminBypass: _adminBypass,
      ownProfileId: _ownProfile?.id,
      // F-40 proactive gate wants the REAL entitlement (fail-closed mirror);
      // when the read failed it gets null and the gate steps aside — the
      // trigger's own refusal propagates instead of a wrongful client block.
      isPremium: _entitlementFailed
          ? null
          : Family.isPremiumFamily(_family, DateTime.now().toUtc()),
      settings: _settings,
      frozenDates: [for (final r in _frozenByIso.values) r.scheduleDate],
      myProfile: _ownProfile,
      allProfiles: _members,
    );
    if (outcome != null) {
      _load(silent: true);
      if (mounted) {
        showAppSnack(
            context,
            AppL10n.of(context).l[switch (outcome) {
              DaySheetOutcome.saved => K.toastSaved,
              DaySheetOutcome.cleared => K.toastDayCleared,
              DaySheetOutcome.swapRequested => K.toastSwapRequested,
              DaySheetOutcome.revertRequested => K.toastRevertRequested,
            }]);
      }
    }
  }

  /// Web: GoToToday — no-op when already on the current month (the card is
  /// not tappable then anyway).
  void _goToToday() {
    final now = _today;
    final delta = (now.year * 12 + now.month) -
        (_anchorMonth.year * 12 + _anchorMonth.month);
    _pageController.animateToPage(_basePage + delta,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  /// The Today card inputs, all from state the load already holds. The card
  /// itself is dumb — the rules live in core (today_rules).
  Widget _todayCard(BuildContext context) {
    final todayIso = CareSchedule.isoDate(_today);
    CareSchedule? todayRow;
    for (final d in _upcoming) {
      if (CareSchedule.isoDate(d.scheduleDate) == todayIso) {
        todayRow = d;
        break;
      }
    }
    final glance = todayGlance(
      userProfileId: _ownProfile?.id,
      scheduledParentId: todayRow?.scheduledParentId,
      actualParentId: todayRow?.actualParentId,
      handoffTime: todayRow?.handoffTime,
      members: _memberViews,
    );
    // Web: a no-schedule day nulls the handoff (the scan needs a "current"
    // parent to differ from).
    DateTime? nextHandoff;
    if (todayRow != null) {
      nextHandoff = nextHandoffDate(todayRow.effectiveParentId, [
        for (final d in _upcoming)
          if (CareSchedule.isoDate(d.scheduleDate) != todayIso)
            (
              date: d.scheduleDate,
              scheduledParentId: d.scheduledParentId,
              actualParentId: d.actualParentId,
            ),
      ]);
    }
    return TodayCard(
      glance: glance,
      userFullName: _ownProfile?.fullName ?? '',
      today: _today,
      nextHandoffDate: nextHandoff,
      viewingCurrentMonth: isCurrentMonth(_visibleMonth, _today),
      showInviteNudge: showInviteNudge(
        isLoading: _loading,
        isAdmin: _ownProfile?.isAdmin ?? false,
        activeMemberCount: _members.where((m) => m.isActiveMember).length,
      ),
      onGoToToday: _goToToday,
      onInvite: () => context.go('/family'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppL10n.of(context);
    final l = app.l;
    final views = _memberViews;
    final title =
        l.formatMonthYear(_visibleMonth.year, _visibleMonth.month);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          // U-11: the accessible entry point to bulk selection (mirrors the
          // long-press). Once armed, tapping a day toggles its selection.
          if (!_isSelectionMode)
            IconButton(
              tooltip: l[K.calSelectDays],
              icon: const Icon(Icons.check_box_outlined),
              onPressed: () => setState(() => _selectionArmed = true),
            ),
          IconButton(
            tooltip: l[K.calWizard],
            icon: const Icon(Icons.event_repeat),
            onPressed: _openWizard,
          ),
          // F-14: the explicit admin-mode toggle — mirror of the web's NavMenu
          // button. Only a real admin sees it; the shell shows the persistent
          // banner while it is on.
          if (_ownProfile?.isAdmin == true)
            IconButton(
              tooltip: l[widget.adminMode.isActive
                  ? K.navAdminExit
                  : K.navAdminEnter],
              icon: Icon(
                widget.adminMode.isActive
                    ? Icons.shield
                    : Icons.shield_outlined,
                color: widget.adminMode.isActive
                    ? const Color(0xFFB91C1C)
                    : null,
              ),
              onPressed: widget.adminMode.toggle,
            ),
          // U-13: the signed-in picker — a switch persists to the profile so
          // the server-side senders follow (best-effort, in _setLanguage).
          PopupMenuButton<AppLanguage>(
            tooltip: l[K.languageAriaLabel],
            icon: const Icon(Icons.language),
            onSelected: app.setLanguage,
            itemBuilder: (context) => [
              for (final (language, label) in [
                (AppLanguage.ptBr, l[K.languagePtBr]),
                (AppLanguage.en, l[K.languageEn]),
              ])
                PopupMenuItem(
                  value: language,
                  enabled: l.current != language,
                  child: Text(label),
                ),
            ],
          ),
          IconButton(
            tooltip: l[K.navLogout],
            icon: const Icon(Icons.logout),
            onPressed: widget.onSignOut,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_ownProfile != null) _todayCard(context),
          _Legend(members: _members, views: views),
          const Divider(height: 1),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, page) {
                final month = _monthForPage(page);
                final isVisible = month.year == _visibleMonth.year &&
                    month.month == _visibleMonth.month;
                return RefreshIndicator(
                  onRefresh: _load,
                  child: _loadError != null && isVisible
                      ? ListView(children: [
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child:
                                Text(_loadError!, textAlign: TextAlign.center),
                          )
                        ])
                      : _MonthGrid(
                          month: month,
                          daysByIso: isVisible ? _daysByIso : const {},
                          frozenByIso: isVisible ? _frozenByIso : const {},
                          ownProfileId: _ownProfile?.id,
                          views: views,
                          today: _today,
                          loading: _loading && isVisible,
                          selectedIso: {
                            for (final d in _selectedDays)
                              CareSchedule.isoDate(d)
                          },
                          onDayTap: _onDayTap,
                          onDayLongPress: _onDayLongPress,
                        ),
                );
              },
            ),
          ),
          if (_isSelectionMode)
            Material(
              elevation: 8,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _selectedDays.isEmpty
                              ? null
                              : _openBulkSheet,
                          child: Text(l.format(
                              K.selectionEdit, [_selectedDays.length])),
                        ),
                      ),
                      // 🔔 Resolver — only when the selection carries open
                      // requests / revertable days (WorkflowActionableCount).
                      if (_workflowActionableCount > 0) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _openResolveSheet,
                            child: Text(l.format(K.selectionResolve,
                                [_workflowActionableCount])),
                          ),
                        ),
                      ],
                      IconButton(
                        tooltip: l[K.selectionCancel],
                        icon: const Icon(Icons.close),
                        onPressed: _cancelSelection,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final List<Member> members;
  final List<MemberView> views;

  const _Legend({required this.members, required this.views});

  @override
  Widget build(BuildContext context) {
    // F-27/S-11: colors are per ACTIVE member (persistent color_slot).
    final active = members.where((m) => m.isActiveMember).toList()
      ..sort((a, b) => (a.colorSlot ?? 9).compareTo(b.colorSlot ?? 9));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final m in active)
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: CircleAvatar(
                backgroundColor:
                    slotColors[profileSlotIndex(m.id, views)] ?? slotColors[0],
                child: Text(displayInitials(m.id, views),
                    style: const TextStyle(fontSize: 10, color: Colors.white)),
              ),
              label: Text(m.fullName.split(' ').first),
            ),
          Chip(
            visualDensity: VisualDensity.compact,
            avatar: const CircleAvatar(backgroundColor: swappedColor),
            label: Text(AppL10n.of(context).l[K.calSwapped]),
          ),
        ],
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  final DateTime month;
  final Map<String, CareSchedule> daysByIso;
  final Map<String, SwapRequest> frozenByIso;
  final int? ownProfileId;
  final List<MemberView> views;
  final DateTime today;
  final bool loading;
  final Set<String> selectedIso;
  final void Function(DateTime) onDayTap;
  final void Function(DateTime) onDayLongPress;

  const _MonthGrid({
    required this.month,
    required this.daysByIso,
    required this.frozenByIso,
    required this.ownProfileId,
    required this.views,
    required this.today,
    required this.loading,
    required this.selectedIso,
    required this.onDayTap,
    required this.onDayLongPress,
  });

  /// The F-12 cell badge — mirror of Home.razor's day-frozen markup: 🔔 when
  /// the request awaits MY response (overdue gets the red variant), ⏳ when it
  /// awaits someone else; the semantics label carries the web's title text.
  _FrozenMark? _markFor(SwapRequest? frozen, Localization l) {
    if (frozen == null) return null;
    final awaitingMe = frozen.targetProfileId == ownProfileId;
    final overdue =
        frozen.toView().priorityTag(DateTime.now()) == SwapPriorityTag.overdue;
    if (awaitingMe) {
      return _FrozenMark(
        badge: '🔔',
        overdue: overdue,
        label: l[overdue ? K.calOverdueAwaitingYou : K.calAwaitingYou],
      );
    }
    String? targetName;
    for (final v in views) {
      if (v.id == frozen.targetProfileId) {
        targetName = v.fullName;
        break;
      }
    }
    return _FrozenMark(
      badge: '⏳',
      overdue: false,
      label: l
          .format(K.calAwaitingFrom, [targetName ?? l[K.calOtherCaregiver]]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // Sunday-first: DateTime.weekday has Mon=1..Sun=7, so %7 puts Sunday at 0
    // — same blank count as the web's (int)firstDayOfMonth.DayOfWeek.
    final blanksBefore = DateTime(month.year, month.month, 1).weekday % 7;
    final todayIso = CareSchedule.isoDate(today);
    // Sunday-first initials per language — the catalog carries the row
    // (K.calWeekdayInitials: "D,S,T,Q,Q,S,S" · "S,M,T,W,T,F,S").
    final weekdayInitials =
        AppL10n.of(context).l[K.calWeekdayInitials].split(',');

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(8),
      children: [
        Row(
          children: [
            for (final w in weekdayInitials)
              Expanded(
                child: Center(
                  child: Text(w,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            children: [
              for (var i = 0; i < blanksBefore; i++) const SizedBox.shrink(),
              for (var day = 1; day <= daysInMonth; day++)
                _DayCell(
                  date: DateTime(month.year, month.month, day),
                  day: daysByIso[CareSchedule.isoDate(
                      DateTime(month.year, month.month, day))],
                  frozenMark: _markFor(
                      frozenByIso[CareSchedule.isoDate(
                          DateTime(month.year, month.month, day))],
                      AppL10n.of(context).l),
                  views: views,
                  isToday: CareSchedule.isoDate(
                          DateTime(month.year, month.month, day)) ==
                      todayIso,
                  isSelected: selectedIso.contains(CareSchedule.isoDate(
                      DateTime(month.year, month.month, day))),
                  onTap: onDayTap,
                  onLongPress: onDayLongPress,
                ),
            ],
          ),
      ],
    );
  }
}

/// What a frozen day paints on its cell (computed in [_MonthGrid._markFor]).
class _FrozenMark {
  final String badge; // 🔔 (mine) · ⏳ (theirs)
  final bool overdue;
  final String label; // semantics — the web's badge title
  const _FrozenMark(
      {required this.badge, required this.overdue, required this.label});
}

class _DayCell extends StatelessWidget {
  final DateTime date;
  final CareSchedule? day;
  final _FrozenMark? frozenMark;
  final List<MemberView> views;
  final bool isToday;
  final bool isSelected;
  final void Function(DateTime) onTap;
  final void Function(DateTime) onLongPress;

  const _DayCell({
    required this.date,
    required this.day,
    required this.frozenMark,
    required this.views,
    required this.isToday,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final assignment = day == null
        ? null
        : DayAssignment(
            scheduledParentId: day!.scheduledParentId,
            actualParentId: day!.actualParentId,
          );
    final paint = dayPaint(assignment, views);
    final color = switch (paint) {
      DayUnassigned() => Colors.transparent,
      DaySwapped() => swappedColor,
      DaySlot(slot: final s) => slotColors[s] ?? slotColors[0]!,
    };
    final initial = parentInitial(assignment, views);
    final assigned = paint is! DayUnassigned;

    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () => onTap(date),
      // U-11: the mobile entry point to bulk selection (web: 500 ms press).
      onLongPress: () => onLongPress(date),
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: isSelected
                  ? Border.all(color: primary, width: 2)
                  : isToday
                      ? Border.all(color: primary, width: 2)
                      : Border.all(color: Theme.of(context).dividerColor),
              color: isSelected
                  ? primary.withValues(alpha: 0.12)
                  : assigned
                      ? color.withValues(alpha: 0.15)
                      : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${date.day}',
                    style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(height: 2),
                CircleAvatar(
                  radius: 10,
                  backgroundColor: assigned ? color : Colors.transparent,
                  child: Text(initial,
                      style: TextStyle(
                          fontSize: 9,
                          color: assigned
                              ? Colors.white
                              : Theme.of(context).hintColor)),
                ),
                // Web parity: the frozen badge REPLACES the handoff badge.
                if (frozenMark != null)
                  Semantics(
                    label: frozenMark!.label,
                    child: Container(
                      padding: frozenMark!.overdue
                          ? const EdgeInsets.symmetric(horizontal: 3)
                          : EdgeInsets.zero,
                      decoration: frozenMark!.overdue
                          ? BoxDecoration(
                              color: const Color(0xFFFEE2E2),
                              borderRadius: BorderRadius.circular(6),
                            )
                          : null,
                      child: Text(frozenMark!.badge,
                          style: const TextStyle(fontSize: 9)),
                    ),
                  )
                else if (day?.handoffTime != null)
                  Icon(Icons.swap_horiz,
                      size: 10, color: Theme.of(context).hintColor),
              ],
            ),
          ),
          // The web's corner mark on selected cells.
          if (isSelected)
            Positioned(
              top: 2,
              right: 2,
              child: Text('✓',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: primary)),
            ),
        ],
      ),
    );
  }
}
