import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive.dart';
import '../../models/enums.dart';
import '../../state/providers.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/leaderboard_list.dart';

class FinalResultsScreen extends ConsumerWidget {
  const FinalResultsScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider(sessionId));
    final participants = ref.watch(participantsProvider(sessionId));
    final user = ref.watch(currentUserProvider);
    final isEducator = user?.role == UserRole.educator;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Results'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () => context.go('/'),
            child: const Text('Done'),
          ),
        ],
      ),
      body: session.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: '$e'),
        data: (s) => participants.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(message: '$e'),
          data: (ps) {
            final rows = rowsFromParticipants(ps, highlightStudentId: user?.id);
            final me = ps.indexWhere((p) => p.studentId == user?.id);
            return ContentContainer(
              maxWidth: 720,
              child: ListView(
                children: [
                  const SizedBox(height: 8),
                  Text(
                    s?.quizTitle ?? 'Quiz',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Final leaderboard',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),
                  Podium(rows: rows),
                  const SizedBox(height: 24),
                  if (!isEducator && me >= 0)
                    Card(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Text(
                              '#${me + 1}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 22,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${ps[me].totalScore} points',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 18,
                                    ),
                                  ),
                                  Text(
                                    '${ps[me].correctCount} / ${s?.totalQuestions ?? ps[me].answeredCount} correct',
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  LeaderboardList(rows: rows),
                  const SizedBox(height: 24),
                  if (isEducator)
                    FilledButton.icon(
                      onPressed: () =>
                          context.go('/analytics/quiz/${s?.quizId ?? ""}'),
                      icon: const Icon(Icons.insights_outlined),
                      label: const Text('View quiz analytics'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: () => context.go('/leaderboard'),
                      icon: const Icon(Icons.leaderboard_outlined),
                      label: const Text('Global leaderboard'),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
