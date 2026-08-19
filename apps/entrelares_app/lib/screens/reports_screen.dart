import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';

import '../services/custody_data_source.dart';
import '../widgets/app_l10n.dart';
import 'reports_audit_tab.dart';
import 'reports_summary_tab.dart';

/// The Relatórios hub — port of the `ReportsTabs` switcher shared by
/// `ReportsSummary.razor`, `ReportsAudit.razor` and `ReportsPdf.razor`.
///
/// **The native improvement the owner directive allows:** the web navigates
/// between three ROUTES (`reports/summary|audit|pdf`) because it has no
/// persistent tab shell; here the three views are a `TabBar` inside the
/// Relatórios destination, so switching never re-enters the shell and each
/// view keeps its own filter state while the user compares them.
class ReportsScreen extends StatelessWidget {
  final CustodyDataSource dataSource;

  const ReportsScreen({super.key, required this.dataSource});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l[K.navReports]),
          bottom: TabBar(
            tabs: [
              Tab(text: '📋 ${l[K.repTabSummary]}'),
              Tab(text: '⏱️ ${l[K.repTabHistory]}'),
              Tab(text: '📄 ${l[K.repTabPdf]}'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            ReportsSummaryTab(dataSource: dataSource),
            ReportsAuditTab(dataSource: dataSource),
            // Lote 6, PR 4 — the F-33 native PDF.
            const ReportTabUnderConstruction(),
          ],
        ),
      ),
    );
  }
}

/// The filling of a report tab whose screen belongs to a later PR of this
/// batch — the same copy the shell destinations used before their screens
/// landed.
class ReportTabUnderConstruction extends StatelessWidget {
  const ReportTabUnderConstruction({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.construction,
                size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(l[KApp.shellUnderConstructionTitle],
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(l[KApp.shellUnderConstructionBody],
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
