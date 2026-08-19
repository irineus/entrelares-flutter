import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';

import '../services/custody_data_source.dart';
import '../widgets/app_l10n.dart';
import 'reports_audit_tab.dart';
import 'reports_pdf_tab.dart';
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
            ReportsPdfTab(dataSource: dataSource),
          ],
        ),
      ),
    );
  }
}
