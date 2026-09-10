import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/responsive.dart';
import '../../state/providers.dart';
import '../../shared_widgets/app_scaffold.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/leaderboard_list.dart';

class GlobalLeaderboardScreen extends ConsumerStatefulWidget {
  const GlobalLeaderboardScreen({super.key});

  @override
  ConsumerState<GlobalLeaderboardScreen> createState() => _State();
}

class _State extends ConsumerState<GlobalLeaderboardScreen> {
  String _period = 'all-time';

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final data = ref.watch(
      globalLeaderboardProvider(LeaderboardQuery(period: _period)),
    );
    return AppScaffold(
      title: 'Leaderboard',
      currentRoute: '/leaderboard',
      body: ContentContainer(
        maxWidth: 640,
        child: Column(
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'weekly', label: Text('This week')),
                ButtonSegment(value: 'all-time', label: Text('All time')),
              ],
              selected: {_period},
              onSelectionChanged: (s) => setState(() => _period = s.first),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: data.when(
                loading: () => const LoadingView(),
                error: (e, _) => ErrorView(message: '$e'),
                data: (entries) {
                  if (entries.isEmpty) {
                    return const EmptyView(
                      icon: Icons.leaderboard_outlined,
                      title: 'No scores yet',
                      subtitle: 'Play a live quiz to get on the board.',
                    );
                  }
                  return SingleChildScrollView(
                    child: LeaderboardList(
                      rows: [
                        for (final e in entries)
                          LeaderRow(
                            rank: e.rank,
                            name: e.displayName,
                            points: e.points,
                            highlight: e.studentId == user?.id,
                            subtitle:
                                '${e.quizzesPlayed} quizzes · ${(e.correctRate * 100).round()}% correct',
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
