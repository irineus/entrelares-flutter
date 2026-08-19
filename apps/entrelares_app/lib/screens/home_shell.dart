import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/app_l10n.dart';

/// The authenticated hull — the same four destinations as the web's NavMenu
/// bottom tab bar (Calendário, Família, Avisos, Relatórios). Branch state is
/// preserved per tab by the indexed stack, the native improvement over the
/// web's full page swaps.
class HomeShell extends StatelessWidget {
  final StatefulNavigationShell shell;

  const HomeShell({super.key, required this.shell});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: (index) => shell.goBranch(index,
            // Re-tapping the active tab resets it to its root, the platform
            // convention.
            initialLocation: index == shell.currentIndex),
        destinations: [
          NavigationDestination(
              icon: const Icon(Icons.calendar_month_outlined),
              selectedIcon: const Icon(Icons.calendar_month),
              label: l[K.navCalendar]),
          NavigationDestination(
              icon: const Icon(Icons.group_outlined),
              selectedIcon: const Icon(Icons.group),
              label: l[K.navFamily]),
          NavigationDestination(
              icon: const Icon(Icons.notifications_outlined),
              selectedIcon: const Icon(Icons.notifications),
              label: l[K.navNotificationsShort]),
          NavigationDestination(
              icon: const Icon(Icons.bar_chart_outlined),
              selectedIcon: const Icon(Icons.bar_chart),
              label: l[K.navReports]),
        ],
      ),
    );
  }
}
