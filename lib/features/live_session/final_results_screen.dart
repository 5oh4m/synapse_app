import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/motion.dart';
import '../../app/theme.dart';
import '../../models/enums.dart';
import '../../shared_widgets/answer_distribution_bar.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/bauhaus_button.dart';
import '../../shared_widgets/bauhaus_card.dart';
import '../../shared_widgets/labels.dart';
import '../../shared_widgets/leaderboard_list.dart';
import '../../state/providers.dart';

/// The end of a session: the podium rises, the scores count up, everybody sees
/// where they landed.
class FinalResultsScreen extends ConsumerWidget {
  const FinalResultsScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final sessionAsync = ref.watch(sessionProvider(sessionId));
    final participantsAsync = ref.watch(participantsProvider(sessionId));
    final user = ref.watch(currentUserProvider);
    final isEducator = user?.role == UserRole.educator;
    final gutter = t.gutterFor(MediaQuery.sizeOf(context).width);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const EyebrowLabel('Final'),
            Text(
              'Results',
              style: Theme.of(context).appBarTheme.titleTextStyle,
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: BauhausButton.ghost(
              label: 'Done',
              semanticLabel: 'Close the results and go home',
              onPressed: () => context.go('/'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Builder(
          builder: (context) {
            if (participantsAsync.isLoading && !participantsAsync.hasValue) {
              return const LoadingView(label: 'Counting the scores');
            }
            if (participantsAsync.hasError && !participantsAsync.hasValue) {
              return ErrorView(
                message: '${participantsAsync.error}',
                onRetry: () =>
                    ref.invalidate(participantsProvider(sessionId)),
              );
            }
            final session = sessionAsync.valueOrNull;
            final players = participantsAsync.valueOrNull ?? const [];
            final rows = rowsFromParticipants(
              players,
              highlightStudentId: user?.id,
            );
            final myIndex = players.indexWhere(
              (p) => p.studentId == user?.id,
            );
            final totalQuestions =
                session?.totalQuestions ??
                (myIndex >= 0 ? players[myIndex].answeredCount : 0);

            if (players.isEmpty) {
              return EmptyView(
                icon: Icons.groups_outlined,
                title: 'Nobody played this one',
                subtitle: 'No scores were recorded for this session.',
                action: BauhausButton.primary(
                  label: 'Back to home',
                  onPressed: () => context.go('/'),
                ),
              );
            }

            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: EdgeInsets.symmetric(
                    horizontal: gutter,
                    vertical: gutter,
                  ),
                  children: staggered([
                    Semantics(
                      header: true,
                      child: Text(
                        session?.quizTitle ?? 'Quiz',
                        style: theme.textTheme.displaySmall,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${players.length} '
                      '${players.length == 1 ? "player" : "players"} · '
                      '$totalQuestions questions',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Animation 7: blocks rise from zero, 2nd -> 1st -> 3rd.
                    Podium(rows: rows),
                    const SizedBox(height: 28),
                    if (!isEducator && myIndex >= 0) ...[
                      RankBadge(
                        rank: myIndex + 1,
                        points: players[myIndex].totalScore,
                        label: 'You finished',
                        of: players.length,
                      ),
                      const SizedBox(height: 14),
                      BauhausCard(
                        child: BauhausMeter(
                          factor: totalQuestions == 0
                              ? 0
                              : players[myIndex].correctCount / totalQuestions,
                          label: 'Your accuracy',
                          valueText:
                              '${players[myIndex].correctCount} / $totalQuestions',
                        ),
                      ),
                      const SizedBox(height: 28),
                    ],
                    const SectionHeader(
                      eyebrow: 'Everyone',
                      title: 'Final leaderboard',
                    ),
                    const SizedBox(height: 14),
                    LeaderboardList(rows: rows),
                    const SizedBox(height: 28),
                    if (isEducator)
                      BauhausButton.primary(
                        label: 'View quiz analytics',
                        icon: Icons.insights_outlined,
                        expand: true,
                        onPressed: () => context.go(
                          '/analytics/quiz/${session?.quizId ?? ''}',
                        ),
                      )
                    else
                      BauhausButton.primary(
                        label: 'Global leaderboard',
                        icon: Icons.leaderboard_outlined,
                        expand: true,
                        onPressed: () => context.go('/leaderboard'),
                      ),
                    const SizedBox(height: 12),
                    BauhausButton.secondary(
                      label: 'Back to home',
                      expand: true,
                      onPressed: () => context.go('/'),
                    ),
                    const SizedBox(height: 24),
                  ]),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
