import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/care_schedule.dart';
import '../models/member.dart';
import '../services/custody_data_source.dart';
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

/// Sunday-first, same as the web grid ((int)DayOfWeek: Sunday = 0).
const _weekdayInitials = ['D', 'S', 'T', 'Q', 'Q', 'S', 'S'];
const _monthNamesPtBr = [
  'janeiro',
  'fevereiro',
  'março',
  'abril',
  'maio',
  'junho',
  'julho',
  'agosto',
  'setembro',
  'outubro',
  'novembro',
  'dezembro',
];

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
  bool _loading = true;
  String? _loadError;
  void Function()? _unwatch;

  DateTime get _today => DateTime.now();

  @override
  void initState() {
    super.initState();
    final now = _today;
    _anchorMonth = DateTime(now.year, now.month, 1);
    _visibleMonth = _anchorMonth;
    _pageController = PageController(initialPage: _basePage);
    _load();
    _watch();
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
      if (!mounted) return;
      setState(() {
        _members = members;
        _daysByIso = {
          for (final d in days) CareSchedule.isoDate(d.scheduleDate): d
        };
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = isSessionExpired(e.toString())
            ? sessionExpiredMessage
            : 'Não foi possível carregar o calendário.';
      });
    }
  }

  void _onPageChanged(int page) {
    setState(() => _visibleMonth = _monthForPage(page));
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
    if (changed == true) _load(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final views = _memberViews;
    final title =
        '${_monthNamesPtBr[_visibleMonth.month - 1]} de ${_visibleMonth.year}';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Sair',
            icon: const Icon(Icons.logout),
            onPressed: widget.onSignOut,
          ),
        ],
      ),
      body: Column(
        children: [
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
          const Chip(
            visualDensity: VisualDensity.compact,
            avatar: CircleAvatar(backgroundColor: swappedColor),
            label: Text('Trocado'),
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

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(8),
      children: [
        Row(
          children: [
            for (final w in _weekdayInitials)
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
