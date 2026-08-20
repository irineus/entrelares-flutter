import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import '../widgets/ui/ui.dart';
import '../theme/tokens.dart';

import '../models/care_schedule.dart';
import '../models/member.dart';
import '../models/role.dart';
import '../services/custody_data_source.dart';
import '../widgets/app_l10n.dart';
import '../widgets/rich_label.dart';

/// "Resumo do Período" — port of `ReportsSummary.razor`.
///
/// Every number on screen comes from [caregiverStats], the same pure function
/// the F-33 document calls: the web keeps the two in step by comment, this
/// keeps them in step by construction.
///
/// Two native improvements the owner directive allows: changing a filter
/// reloads immediately (the web needs a "Filtrar" tap) and the period can be
/// pulled to refresh. The U-20 projection toggle recomputes from the rows
/// already loaded, exactly as the web does — it is a reading of the same data,
/// never a new query.
class ReportsSummaryTab extends StatefulWidget {
  final CustodyDataSource dataSource;

  /// Injected by the tests; production reads the clock.
  final DateTime Function() now;

  const ReportsSummaryTab({
    super.key,
    required this.dataSource,
    this.now = DateTime.now,
  });

  @override
  State<ReportsSummaryTab> createState() => _ReportsSummaryTabState();
}

class _ReportsSummaryTabState extends State<ReportsSummaryTab> {
  late int _month = widget.now().month;
  late int _year = widget.now().year;
  bool _byMonth = false; // the web opens on "Por Ano"
  bool _includeFutureSwaps = false;

  bool _loading = true;

  /// The raw failure, formatted at RENDER time — the first load starts from
  /// [initState], where the inherited localization is not reachable yet.
  String? _errorRaw;

  List<Member> _members = const [];
  List<Role> _roles = const [];
  List<CareSchedule> _days = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  (DateTime, DateTime) get _period => _byMonth
      ? (DateTime(_year, _month, 1), DateTime(_year, _month + 1, 0))
      : (DateTime(_year, 1, 1), DateTime(_year, 12, 31));

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errorRaw = null;
    });
    try {
      final (start, end) = _period;
      final members = await widget.dataSource.fetchMembers();
      final roles = await widget.dataSource.fetchRoles();
      final days = await widget.dataSource.fetchSchedulesForPeriod(start, end);
      if (!mounted) return;
      setState(() {
        _members = members;
        _roles = roles;
        _days = days;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorRaw = e.toString();
        _loading = false;
      });
    }
  }

  List<MemberView> get _views => [for (final m in _members) m.toView()];

  String _roleLabel(int profileId, AppLanguage language) {
    for (final m in _members) {
      if (m.id != profileId) continue;
      for (final role in _roles) {
        if (role.id == m.roleId) return role.displayLabel(language);
      }
    }
    return '';
  }

  List<CaregiverStat> _stats(AppLanguage language) => caregiverStats(
        members: _views,
        days: [
          for (final d in _days)
            ReportDay(
              scheduleDate: d.scheduleDate,
              scheduledParentId: d.scheduledParentId,
              actualParentId: d.actualParentId,
            ),
        ],
        today: widget.now(),
        includeFutureSwaps: _includeFutureSwaps,
        roleLabelOf: (id) => _roleLabel(id, language),
      );

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
    final stats = _stats(l.current);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Text(l[K.sumSubtitle],
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          _filterCard(l),
          const SizedBox(height: 12),
          if (_errorRaw != null)
            _errorBanner(l)
          else if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (!hasSummaryData(stats))
            _emptyState(l)
          else ...[
            for (final stat in stats) _statCard(stat, l),
            const SizedBox(height: 8),
            Center(
              child: RichLabel.of(
                l,
                _includeFutureSwaps
                    ? K.sumTotalSwapsProjected
                    : K.sumTotalSwaps,
                args: [
                  totalVisibleSwaps(
                    days: [
                      for (final d in _days)
                        ReportDay(
                          scheduleDate: d.scheduleDate,
                          scheduledParentId: d.scheduledParentId,
                          actualParentId: d.actualParentId,
                        ),
                    ],
                    today: widget.now(),
                    includeFutureSwaps: _includeFutureSwaps,
                  )
                ],
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _filterCard(Localization l) {
    final thisYear = widget.now().year;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              label: l[K.repPeriodAria],
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text(l[K.repByYear])),
                  ButtonSegment(value: true, label: Text(l[K.repByMonth])),
                ],
                selected: {_byMonth},
                onSelectionChanged: _loading
                    ? null
                    : (s) {
                        setState(() => _byMonth = s.first);
                        _load();
                      },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (_byMonth) ...[
                  Expanded(
                    child: Semantics(
                      label: l[K.repByMonth],
                      child: DropdownButtonFormField<int>(
                        initialValue: _month,
                        items: [
                          for (var m = 1; m <= 12; m++)
                            DropdownMenuItem(
                                value: m, child: Text(l.monthName(m))),
                        ],
                        onChanged: _loading
                            ? null
                            : (m) {
                                if (m == null) return;
                                setState(() => _month = m);
                                _load();
                              },
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Semantics(
                    label: l[K.repByYear],
                    child: DropdownButtonFormField<int>(
                      initialValue: _year,
                      items: [
                        // Web parity: last year through two years ahead.
                        for (var y = thisYear - 1; y <= thisYear + 2; y++)
                          DropdownMenuItem(value: y, child: Text('$y')),
                      ],
                      onChanged: _loading
                          ? null
                          : (y) {
                              if (y == null) return;
                              setState(() => _year = y);
                              _load();
                            },
                    ),
                  ),
                ),
              ],
            ),
            // U-20: accepted future swaps already carry actual_parent_id — the
            // default view simply ignores them.
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _includeFutureSwaps,
              title: Text(l[K.sumFutureToggle],
                  style: Theme.of(context).textTheme.bodySmall),
              onChanged: _loading
                  ? null
                  : (v) => setState(() => _includeFutureSwaps = v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(CaregiverStat stat, Localization l) {
    final color =
        context.tokens.slot(profileSlotIndex(stat.profileId, _views)).tone.solid;
    final firstName = stat.name.split(' ').first;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: color, width: 4)),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              stat.role.isEmpty ? firstName : '$firstName (${stat.role})',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            _statRow(l[K.sumPlanned], _daysLabel(stat.plannedDays, l)),
            _statRow(l[K.sumActual], _daysLabel(stat.actualDays, l),
                highlight: true),
            if (_includeFutureSwaps)
              _statRow(l[K.sumProjected], _daysLabel(stat.projectedDays, l),
                  highlight: true),
            // U-07: who gave days away and who received them.
            _statRow(
              l[K.sumSwaps],
              l.format(
                  K.sumSwapSplit, [stat.swapsGiven, stat.swapsReceived]),
            ),
          ],
        ),
      ),
    );
  }

  /// U-13: a plural is not a singular plus "s" in either language, and the
  /// count carries its unit — two catalog entries, exactly like the web.
  String _daysLabel(int count, Localization l) =>
      l.format(count == 1 ? K.sumDaysOne : K.sumDaysMany, [count]);

  Widget _statRow(String label, String value, {bool highlight = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: highlight ? Theme.of(context).colorScheme.primary : null,
              ),
            ),
          ],
        ),
      );

  Widget _emptyState(Localization l) => AppEmptyState(
        icon: '📅',
        title: l[K.sumEmptyTitle],
        body: l[K.sumEmptyBody],
      );

  /// The central mappings the whole app shares: a dead session says so, and a
  /// server error propagates its own text.
  String _errorMessage(Localization l) => isSessionExpired(_errorRaw!)
      ? sessionExpiredMessage(l)
      : l.format(K.sumErrProcess, [_errorRaw!]);

  Widget _errorBanner(Localization l) => AppBanner(
        tone: context.tokens.danger,
        leading: '⚠️',
        title: l[K.repErrorTitle],
        message: _errorMessage(l),
      );
}
