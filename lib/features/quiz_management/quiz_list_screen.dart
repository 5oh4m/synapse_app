import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/motion.dart';
import '../../app/theme.dart';
import '../../models/quiz.dart';
import '../../shared_widgets/app_scaffold.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/bauhaus_button.dart';
import '../../shared_widgets/bauhaus_card.dart';
import '../../shared_widgets/labels.dart';
import '../../state/controllers.dart';
import '../../state/providers.dart';

/// Every quiz the educator owns, draft and published.
class QuizListScreen extends ConsumerWidget {
  const QuizListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final quizzes = user == null
        ? const AsyncValue<List<Quiz>>.loading()
        : ref.watch(quizzesProvider(user.id));

    return AppScaffold(
      title: 'My quizzes',
      eyebrow: 'Library',
      currentRoute: '/quizzes',
      padBody: true,
      maxContentWidth: 900,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/create'),
        icon: const Icon(Icons.auto_awesome),
        label: const Text('New quiz'),
        tooltip: 'Generate a new quiz',
      ),
      body: quizzes.when(
        loading: () => const LoadingView(label: 'Loading your quizzes'),
        error: (e, _) => ErrorView(
          message: '$e',
          onRetry: user == null
              ? null
              : () => ref.invalidate(quizzesProvider(user.id)),
        ),
        data: (list) {
          if (list.isEmpty) {
            return EmptyView(
              icon: Icons.quiz_outlined,
              title: 'No quizzes yet',
              subtitle: 'Generate one from your lecture material and edit the '
                  'draft before you publish.',
              action: BauhausButton.primary(
                label: 'Create a quiz',
                icon: Icons.auto_awesome,
                onPressed: () => context.go('/create'),
              ),
            );
          }
          final published = list.where((q) => q.isPublished).length;
          return ListView.separated(
            padding: EdgeInsets.zero,
            itemCount: list.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              if (i == 0) {
                return SectionHeader(
                  eyebrow: 'All quizzes',
                  title: '${list.length} total · $published published',
                );
              }
              return StaggeredEntry(
                index: i - 1,
                child: _QuizCard(quiz: list[i - 1]),
              );
            },
          );
        },
      ),
    );
  }
}

class _QuizCard extends ConsumerWidget {
  const _QuizCard({required this.quiz});

  final Quiz quiz;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);

    return BauhausCard(
      accentBar: quiz.isPublished ? t.correct : t.inkMuted,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(quiz.title, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        BauhausChip(
                          label: quiz.isPublished ? 'Published' : 'Draft',
                          dense: true,
                          fill: quiz.isPublished ? t.correct : t.surface,
                          ink: quiz.isPublished
                              ? QuizzleColors.paper
                              : t.ink,
                          semanticLabel: quiz.isPublished
                              ? 'Published quiz'
                              : 'Draft quiz',
                        ),
                        BauhausChip(
                          label: '${quiz.questionCount} questions',
                          dense: true,
                        ),
                        if (quiz.subject.isNotEmpty)
                          BauhausChip(label: quiz.subject, dense: true),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              BauhausIconButton(
                icon: Icons.insights_outlined,
                tooltip: 'Analytics',
                semanticLabel: 'Analytics for ${quiz.title}',
                onPressed: () => context.go('/analytics/quiz/${quiz.id}'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              if (quiz.isPublished)
                BauhausButton.primary(
                  label: 'Go live',
                  icon: Icons.play_arrow,
                  semanticLabel: 'Host a live session of ${quiz.title}',
                  onPressed: () => _goLive(context, ref, quiz),
                ),
              BauhausButton.secondary(
                label: 'Open',
                icon: Icons.open_in_new,
                semanticLabel: 'Open ${quiz.title}',
                onPressed: () => context.go('/quiz/${quiz.id}'),
              ),
              BauhausButton.ghost(
                label: 'Edit questions',
                icon: Icons.edit_outlined,
                semanticLabel: 'Edit the questions in ${quiz.title}',
                onPressed: () => context.go('/quiz/${quiz.id}/review'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _goLive(BuildContext context, WidgetRef ref, Quiz quiz) async {
    try {
      final id = await ref.read(goLiveProvider)(quiz);
      if (context.mounted) context.go('/host/$id');
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }
}
