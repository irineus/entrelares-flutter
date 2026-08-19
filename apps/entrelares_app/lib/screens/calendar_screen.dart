import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../models/care_schedule.dart';
import '../models/family.dart';
import '../models/member.dart';
import '../services/custody_data_source.dart';
import '../widgets/app_l10n.dart';
import '../widgets/app_snack.dart';
import '../widgets/today_card.dart';
import 'day_sheet.dart';

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
  final Future<void> Function() onSignOut;

  const CalendarScreen(
      {super.key, required this.dataSource, required this.onSignOut});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
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
  bool _loading = true;
  String? _loadError;
  void Function()? _unwatch;

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

  @override
  void initState() {
    super.initState();
    final now = _today;
    _anchorMonth = DateTime(now.year, now.month, 1);
    _visibleMonth = _anchorMonth;
    _pageController = PageController(initialPage: _basePage);
    _load();
    _loadHorizonInputs();
    _watch();
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
    // another member saves shows up here without polling.
    _unwatch = await widget.dataSource.watchChanges(() {
      if (mounted) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _unwatch?.call();
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
      final ownProfile = await widget.dataSource.fetchOwnProfile();
      final upcoming = await widget.dataSource
          .fetchUpcoming(_today, nextHandoffWindowDays + 1);
      if (!mounted) return;
      setState(() {
        _members = members;
        _daysByIso = {
          for (final d in days) CareSchedule.isoDate(d.scheduleDate): d
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

  void _onPageChanged(int page) {
    final month = _monthForPage(page);
    // The bounce-back below re-fires with the month already shown — no-op.
    if (month.year == _visibleMonth.year && month.month == _visibleMonth.month) {
      return;
    }
    // F-39 mirror of the web's NextMonth: paging stops at the family's
    // planning horizon with the tier message instead of advancing.
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
      _pageController.animateToPage(_pageForMonth(_visibleMonth),
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      return;
    }
    setState(() => _visibleMonth = month);
    _load();
  }

  List<MemberView> get _memberViews =>
      _members.map((m) => m.toView()).toList(growable: false);

  Future<void> _openDay(DateTime date) async {
    HapticFeedback.selectionClick();
    final iso = CareSchedule.isoDate(date);
    final previousIso =
        CareSchedule.isoDate(date.subtract(const Duration(days: 1)));
    final changed = await showDaySheet(
      context: context,
      date: date,
      day: _daysByIso[iso],
      previousDay: _daysByIso[previousIso],
      members: _members.where((m) => m.isActiveMember).toList(),
      memberViews: _memberViews,
      today: _today,
      dataSource: widget.dataSource,
    );
    if (changed == true) {
      _load(silent: true);
      if (mounted) {
        showAppSnack(context, AppL10n.of(context).l[K.toastSaved]);
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
                          views: views,
                          today: _today,
                          loading: _loading && isVisible,
                          onDayTap: _openDay,
                        ),
                );
              },
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
  final List<MemberView> views;
  final DateTime today;
  final bool loading;
  final void Function(DateTime) onDayTap;

  const _MonthGrid({
    required this.month,
    required this.daysByIso,
    required this.views,
    required this.today,
    required this.loading,
    required this.onDayTap,
  });

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
                  views: views,
                  isToday: CareSchedule.isoDate(
                          DateTime(month.year, month.month, day)) ==
                      todayIso,
                  onTap: onDayTap,
                ),
            ],
          ),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  final DateTime date;
  final CareSchedule? day;
  final List<MemberView> views;
  final bool isToday;
  final void Function(DateTime) onTap;

  const _DayCell({
    required this.date,
    required this.day,
    required this.views,
    required this.isToday,
    required this.onTap,
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

    return InkWell(
      onTap: () => onTap(date),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: isToday
              ? Border.all(
                  color: Theme.of(context).colorScheme.primary, width: 2)
              : Border.all(color: Theme.of(context).dividerColor),
          color: assigned ? color.withValues(alpha: 0.15) : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('${date.day}', style: Theme.of(context).textTheme.labelSmall),
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
            if (day?.handoffTime != null)
              Icon(Icons.swap_horiz,
                  size: 10, color: Theme.of(context).hintColor),
          ],
        ),
      ),
    );
  }
}
