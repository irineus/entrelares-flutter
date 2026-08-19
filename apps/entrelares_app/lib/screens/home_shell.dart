import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/admin_mode.dart';
import '../services/notification_badge.dart';
import '../widgets/app_l10n.dart';

/// The authenticated hull — the same four destinations as the web's NavMenu
/// bottom tab bar (Calendário, Família, Avisos, Relatórios). Branch state is
/// preserved per tab by the indexed stack, the native improvement over the
/// web's full page swaps. The bell badge counts the OPEN REQUESTS AWAITING
/// ME (web parity — not unread notifications), capped at "99+".
class HomeShell extends StatelessWidget {
  final StatefulNavigationShell shell;
  final AdminMode adminMode;
  final NotificationBadge badge;

  const HomeShell(
      {super.key,
      required this.shell,
      required this.adminMode,
      required this.badge});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
    return Scaffold(
      body: ListenableBuilder(
        listenable: adminMode,
        builder: (context, _) => Column(
          children: [
            // F-14: the persistent, explicit banner while admin mode is on —
            // mirror of the web's MainLayout strip (shown on every tab).
            if (adminMode.isActive)
              Material(
                color: const Color(0xFFB91C1C),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '🛡️ ${l[K.layoutAdminActive]} — '
                            '${l[K.layoutAdminHint]}',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                          ),
                        ),
                        TextButton(
                          onPressed: adminMode.deactivate,
                          style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              visualDensity: VisualDensity.compact),
                          child: Text(l[K.layoutAdminExit]),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(child: shell),
          ],
        ),
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: badge,
        builder: (context, _) => NavigationBar(
          selectedIndex: shell.currentIndex,
          onDestinationSelected: (index) {
            shell.goBranch(index,
                // Re-tapping the active tab resets it to its root, the
                // platform convention.
                initialLocation: index == shell.currentIndex);
            // Web parity: the badge refreshes on every navigation.
            badge.refresh();
          },
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
                icon: _bellIcon(const Icon(Icons.notifications_outlined)),
                selectedIcon: _bellIcon(const Icon(Icons.notifications)),
                tooltip: badge.count > 0
                    ? l.format(
                        badge.count == 1
                            ? K.navNotificationsOnePending
                            : K.navNotificationsManyPending,
                        [badge.count])
                    : null,
                label: l[K.navNotificationsShort]),
            NavigationDestination(
                icon: const Icon(Icons.bar_chart_outlined),
                selectedIcon: const Icon(Icons.bar_chart),
                label: l[K.navReports]),
          ],
        ),
      ),
    );
  }

  Widget _bellIcon(Icon icon) => Badge(
        isLabelVisible: badge.count > 0,
        label: Text(bellBadgeText(badge.count)),
        child: icon,
      );
}
