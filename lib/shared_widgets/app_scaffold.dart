import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/responsive.dart';
import '../models/enums.dart';
import '../state/providers.dart';

class NavDest {
  const NavDest(this.label, this.icon, this.route);
  final String label;
  final IconData icon;
  final String route;
}

/// App chrome that becomes a bottom bar on phones and a side rail on
/// wider screens. Destinations depend on the signed-in role.
class AppScaffold extends ConsumerWidget {
  const AppScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.floatingActionButton,
    this.currentRoute,
  });

  final String title;
  final Widget body;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final String? currentRoute;

  static const _educatorDests = [
    NavDest('Home', Icons.home_outlined, '/'),
    NavDest('Library', Icons.folder_outlined, '/library'),
    NavDest('Quizzes', Icons.quiz_outlined, '/quizzes'),
    NavDest('Analytics', Icons.insights_outlined, '/analytics'),
  ];
  static const _studentDests = [
    NavDest('Home', Icons.home_outlined, '/'),
    NavDest('Join', Icons.login_outlined, '/join'),
    NavDest('Leaderboard', Icons.leaderboard_outlined, '/leaderboard'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final dests = (user?.role == UserRole.educator)
        ? _educatorDests
        : _studentDests;
    final loc = currentRoute ?? GoRouterState.of(context).matchedLocation;
    var index = dests.indexWhere((d) => d.route == loc);
    if (index < 0) index = 0;

    final railMode = !isCompact(context);

    final scaffold = Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          ...?actions,
          IconButton(
            tooltip: 'Profile',
            onPressed: () => context.go('/profile'),
            icon: const Icon(Icons.account_circle_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: railMode
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (i) => context.go(dests[i].route),
              destinations: [
                for (final d in dests)
                  NavigationDestination(icon: Icon(d.icon), label: d.label),
              ],
            ),
      body: SafeArea(child: body),
    );

    if (!railMode) return scaffold;

    return Row(
      children: [
        NavigationRail(
          selectedIndex: index,
          onDestinationSelected: (i) => context.go(dests[i].route),
          labelType: NavigationRailLabelType.all,
          leading: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Icon(
              Icons.bolt,
              color: Theme.of(context).colorScheme.primary,
              size: 28,
            ),
          ),
          destinations: [
            for (final d in dests)
              NavigationRailDestination(
                icon: Icon(d.icon),
                label: Text(d.label),
              ),
          ],
        ),
        const VerticalDivider(width: 1),
        Expanded(child: scaffold),
      ],
    );
  }
}
