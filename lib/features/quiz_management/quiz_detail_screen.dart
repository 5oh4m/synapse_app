import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/failure.dart';
import '../../core/responsive.dart';
import '../../state/controllers.dart';
import '../../state/providers.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/difficulty_chip.dart';

class QuizDetailScreen extends ConsumerWidget {
  const QuizDetailScreen({super.key, required this.quizId});
  final String quizId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quiz = ref.watch(quizProvider(quizId));
    final questions = ref.watch(questionsProvider(quizId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quiz'),
        leading: BackButton(onPressed: () => context.go('/quizzes')),
        actions: [
          IconButton(
            tooltip: 'Analytics',
            onPressed: () => context.go('/analytics/quiz/$quizId'),
            icon: const Icon(Icons.insights_outlined),
          ),
        ],
      ),
      body: quiz.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: '$e'),
        data: (q) {
          if (q == null) {
            return const EmptyView(
              icon: Icons.error_outline,
              title: 'Quiz not found',
            );
          }
          return ContentContainer(
            maxWidth: 720,
            child: ListView(
              children: [
                Text(q.title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Chip(label: Text(q.isPublished ? 'Published' : 'Draft')),
                    if (q.subject.isNotEmpty) Chip(label: Text(q.subject)),
                    Text('${q.questionCount} questions'),
                  ],
                ),
                if (q.description.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(q.description),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: q.isPublished
                            ? () => _goLive(context, ref)
                            : null,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Go live'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => context.go('/quiz/$quizId/review'),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit questions'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (q.isPublished)
                      TextButton.icon(
                        onPressed: () =>
                            ref.read(quizRepositoryProvider).unpublish(quizId),
                        icon: const Icon(Icons.unpublished_outlined),
                        label: const Text('Unpublish'),
                      )
                    else
                      TextButton.icon(
                        onPressed: () async {
                          try {
                            await ref
                                .read(quizRepositoryProvider)
                                .publish(quizId);
                            if (context.mounted) {
                              showSnack(context, 'Published.');
                            }
                          } on AppFailure catch (e) {
                            if (context.mounted) {
                              showSnack(context, e.message, error: true);
                            }
                          }
                        },
                        icon: const Icon(Icons.publish),
                        label: const Text('Publish'),
                      ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () async {
                        await ref
                            .read(quizRepositoryProvider)
                            .deleteQuiz(quizId);
                        if (context.mounted) context.go('/quizzes');
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete'),
                    ),
                  ],
                ),
                const Divider(height: 32),
                Text(
                  'Questions',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                questions.when(
                  loading: () => const LoadingView(),
                  error: (e, _) => ErrorView(message: '$e'),
                  data: (list) => Column(
                    children: [
                      for (final question in list)
                        ListTile(
                          dense: true,
                          leading: Text('${question.orderIndex + 1}'),
                          title: Text(
                            question.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${question.options.length} options · '
                            'answer ${String.fromCharCode(65 + question.correctIndex)} · '
                            '${question.timeLimitSeconds}s',
                          ),
                          trailing: DifficultyChip(
                            question.difficulty,
                            dense: true,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _goLive(BuildContext context, WidgetRef ref) async {
    try {
      final quiz = await ref.read(quizRepositoryProvider).get(quizId);
      final id = await ref.read(goLiveProvider)(quiz);
      if (context.mounted) context.go('/host/$id');
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }
}
