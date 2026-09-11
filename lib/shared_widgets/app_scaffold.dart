import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/theme.dart';
import '../core/responsive.dart';
import '../models/enums.dart';
import '../state/providers.dart';
import 'bauhaus_button.dart';
import 'labels.dart';

/// One navigation destination. [tooltip] is announced alongside the label so
/// the rail's icons are never unlabelled.
class NavDest {
  const NavDest(this.label, this.icon, this.route, {this.tooltip});

  final String label;
  final IconData icon;
  final String route;

  /// Defaults to `'<label> — go to <label>'` phrasing built at render time.
  final String? tooltip;
}

/// App chrome: a bottom bar on phones, a side rail from 600px up.
///
/// Bauhaus shell — flat planes, a 2px rule under the app bar and beside the
/// rail, no blur. Destinations depend on the signed-in role.
///
/// Compatible with the previous API. New optional arguments: [eyebrow],
/// [padBody], [bottom] and [maxContentWidth]; [padBody] defaults to `false` so
/// screens that already pad their own body are unaffected.
class AppScaffold extends ConsumerWidget {
  const AppScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.floatingActionButton,
    this.currentRoute,
    this.eyebrow,
    this.padBody = false,
    this.bottom,
    this.maxContentWidth,
    this.showProfileAction = true,
  });

  final String title;
  final Widget body;
  final List<Widget>? actions;
  final Widget? floatingActionButton;

  /// Overrides the route used to pick the selected destination.
  final String? currentRoute;

  /// Stencilled label above the title.
  final String? eyebrow;

  /// Apply the 16/24px gutter to [body]. Off by default for compatibility.
  final bool padBody;

  /// A persistent strip under the body — a host's transport controls, say.
  final Widget? bottom;

  /// Caps the body width on wide screens when [padBody] is on.
  final double? maxContentWidth;

  final bool showProfileAction;

  static const List<NavDest> educatorDests = [
    NavDest('Home', Icons.home_outlined, '/'),
    NavDest('Library', Icons.folder_outlined, '/library'),
    NavDest('Quizzes', Icons.quiz_outlined, '/quizzes'),
    NavDest('Analytics', Icons.insights_outlined, '/analytics'),
  ];
  static const List<NavDest> studentDests = [
    NavDest('Home', Icons.home_outlined, '/'),
    NavDest('Join', Icons.login_outlined, '/join'),
    NavDest('Leaderboard', Icons.leaderboard_outlined, '/leaderboard'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final user = ref.watch(currentUserProvider);
    final dests = (user?.role == UserRole.educator)
        ? educatorDests
        : studentDests;

    final loc = currentRoute ?? GoRouterState.of(context).matchedLocation;
    var index = dests.indexWhere((d) => d.route == loc);
    if (index < 0) index = 0;

    final railMode = !isCompact(context);
    final gutter = t.gutterFor(MediaQuery.sizeOf(context).width);

    Widget content = body;
    if (padBody) {
      content = Padding(
        padding: EdgeInsets.symmetric(horizontal: gutter, vertical: gutter),
        child: maxContentWidth == null
            ? content
            : Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxContentWidth!),
                  child: content,
                ),
              ),
      );
    }
    if (bottom != null) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: content),
          Container(height: t.borderWidth, color: t.line),
          bottom!,
        ],
      );
    }

    final scaffold = Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (eyebrow != null) EyebrowLabel(eyebrow!),
            Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.appBarTheme.titleTextStyle,
              ),
            ),
          ],
        ),
        actions: [
          ...?actions,
          if (showProfileAction)
            Padding(
              padding: const EdgeInsets.only(right: 8, left: 4),
              child: BauhausIconButton(
                icon: Icons.account_circle_outlined,
                tooltip: 'Profile',
                semanticLabel: 'Open your profile',
                bordered: false,
                onPressed: () => context.go('/profile'),
              ),
            ),
        ],
      ),
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: railMode
          ? null
          : DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: t.line, width: t.borderWidth),
                ),
              ),
              child: NavigationBar(
                selectedIndex: index,
                onDestinationSelected: (i) => context.go(dests[i].route),
                destinations: [
                  for (final d in dests)
                    NavigationDestination(
                      icon: Icon(d.icon),
                      label: d.label,
                      tooltip: d.tooltip ?? 'Go to ${d.label}',
                    ),
                ],
              ),
            ),
      body: SafeArea(child: content),
    );

    if (!railMode) return scaffold;

    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Rail(
            dests: dests,
            selectedIndex: index,
            onSelected: (i) => context.go(dests[i].route),
          ),
          Container(width: t.borderWidth, color: t.line),
          Expanded(child: scaffold),
        ],
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.dests,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<NavDest> dests;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    return NavigationRail(
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelected,
      labelType: NavigationRailLabelType.all,
      leading: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Semantics(
          label: 'quizzle',
          excludeSemantics: true,
          // The brand mark: a quarter-circle on a square. One accent, once.
          child: SizedBox(
            width: 28,
            height: 28,
            child: CustomPaint(painter: _BrandMarkPainter(t.ink, t.warn)),
          ),
        ),
      ),
      destinations: [
        for (final d in dests)
          NavigationRailDestination(
            icon: Icon(d.icon),
            label: Text(d.label),
            // The rail's icons get the same tooltip the bar's do.
            padding: EdgeInsets.zero,
          ),
      ],
    );
  }
}

class _BrandMarkPainter extends CustomPainter {
  const _BrandMarkPainter(this.ink, this.accent);

  final Color ink;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final square = Paint()..color = ink;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), square);
    final quarter = Paint()..color = accent;
    canvas.drawPath(
      Path()
        ..moveTo(size.width, 0)
        ..arcToPoint(
          Offset(size.width, size.height),
          radius: Radius.circular(size.height),
          clockwise: true,
        )
        ..lineTo(size.width, 0)
        ..close(),
      quarter,
    );
  }

  @override
  bool shouldRepaint(_BrandMarkPainter old) =>
      old.ink != ink || old.accent != accent;
}
