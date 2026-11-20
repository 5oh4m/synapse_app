import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/motion.dart';
import '../../app/theme.dart';
import '../../core/failure.dart';
import '../../models/question.dart';
import '../../shared_widgets/answer_tile.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/bauhaus_button.dart';
import '../../shared_widgets/difficulty_chip.dart';
import '../../shared_widgets/labels.dart';
import '../../state/controllers.dart';
import '../../state/providers.dart';

/// One quiz: its state, its actions and a read-only run through its questions.
class QuizDetailScreen extends ConsumerWidget {
  const QuizDetailScreen({super.key, required this.quizId});

  final String quizId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final quizAsync = ref.watch(quizProvider(quizId));
    final questionsAsync = ref.watch(questionsProvider(quizId));
    final gutter = t.gutterFor(MediaQuery.sizeOf(context).width);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const EyebrowLabel('Quiz'),
            Text(
              quizAsync.valueOrNull?.title ?? 'Quiz',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.appBarTheme.titleTextStyle,
            ),
          ],
        ),
        leading: BauhausIconButton(
          icon: Icons.arrow_back,
          tooltip: 'Back to quizzes',
          semanticLabel: 'Back to the quiz list',
          bordered: false,
          onPressed: () => context.go('/quizzes'),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: BauhausIconButton(
              icon: Icons.insights_outlined,
              tooltip: 'Analytics',
              semanticLabel: 'Analytics for this quiz',
              bordered: false,
              onPressed: () => context.go('/analytics/quiz/$quizId'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: quizAsync.when(
          loading: () => const LoadingView(label: 'Loading the quiz'),
          error: (e, _) => ErrorView(
            message: '$e',
            onRetry: () => ref.invalidate(quizProvider(quizId)),
          ),
          data: (quiz) {
            if (quiz == null) {
              return EmptyView(
                icon: Icons.error_outline,
                title: 'Quiz not found',
                subtitle: 'It may have been deleted.',
                action: BauhausButton.secondary(
                  label: 'Back to quizzes',
                  onPressed: () => context.go('/quizzes'),
                ),
              );
            }
            final questions =
                questionsAsync.valueOrNull ?? const <Question>[];

            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: ListView(
                  padding: EdgeInsets.symmetric(
                    horizontal: gutter,
                    vertical: gutter,
                  ),
                  children: staggered([
                    Semantics(
                      header: true,
                      child: Text(
                        quiz.title,
                        style: theme.textTheme.displaySmall,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        BauhausChip(
                          label: quiz.isPublished ? 'Published' : 'Draft',
                          dense: true,
                          fill: quiz.isPublished ? t.correct : t.surface,
                          ink: quiz.isPublished ? QuizzleColors.paper : t.ink,
                        ),
                        BauhausChip(
                          label: '${quiz.questionCount} questions',
                          dense: true,
                        ),
                        if (quiz.subject.isNotEmpty)
                          BauhausChip(label: quiz.subject, dense: true),
                        BauhausChip(
                          label: '${quiz.scoring.basePoints} base pts',
                          dense: true,
                          semanticLabel:
                              '${quiz.scoring.basePoints} base points, '
                              'up to ${quiz.scoring.speedBonusMax} speed bonus',
                        ),
                      ],
                    ),
                    if (quiz.description.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: t.proseMaxWidth,
                        ),
                        child: Text(
                          quiz.description,
                          style: theme.textTheme.bodyLarge,
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        BauhausButton.primary(
                          label: 'Go live',
                          icon: Icons.play_arrow,
                          semanticLabel: quiz.isPublished
                              ? 'Host a live session'
                              : 'Go live. Publish the quiz first.',
                          onPressed: quiz.isPublished
                              ? () => _goLive(context, ref)
                              : null,
                        ),
                        BauhausButton.secondary(
                          label: 'Edit questions',
                          icon: Icons.edit_outlined,
                          onPressed: () => context.go('/quiz/$quizId/review'),
                        ),
                        if (quiz.isPublished)
                          BauhausButton.ghost(
                            label: 'Unpublish',
                            icon: Icons.unpublished_outlined,
                            onPressed: () async {
                              await ref
                                  .read(quizRepositoryProvider)
                                  .unpublish(quizId);
                              if (context.mounted) {
                                showSnack(context, 'Back to draft.');
                              }
                            },
                          )
                        else
                          BauhausButton.ghost(
                            label: 'Publish',
                            icon: Icons.publish,
                            onPressed: () => _publish(context, ref),
                          ),
                        BauhausButton.ghost(
                          label: 'Delete',
                          icon: Icons.delete_outline,
                          semanticLabel: 'Delete this quiz',
                          onPressed: () => _confirmDelete(context, ref, quiz.title),
                        ),
                      ],
                    ),
                    const SizedBox(height: 26),
                    SectionHeader(
                      eyebrow: 'Contents',
                      title: 'Questions (${questions.length})',
                      trailing: BauhausIconButton(
                        icon: Icons.edit_outlined,
                        tooltip: 'Edit questions',
                        semanticLabel: 'Open the question editor',
                        bordered: false,
                        onPressed: () => context.go('/quiz/$quizId/review'),
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (questionsAsync.isLoading && questions.isEmpty)
                      const LoadingView(label: 'Loading questions')
                    else if (questions.isEmpty)
                      EmptyView(
                        icon: Icons.playlist_add,
                        title: 'No questions yet',
                        subtitle: 'Add them in the editor, or regenerate from '
                            'the source material.',
                        action: BauhausButton.secondary(
                          label: 'Open the editor',
                          onPressed: () => context.go('/quiz/$quizId/review'),
                        ),
                      )
                    else
                      for (final question in questions)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _QuestionSummary(question: question),
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

  Future<void> _publish(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(quizRepositoryProvider).publish(quizId);
      if (context.mounted) showSnack(context, 'Published.');
    } on AppFailure catch (e) {
      if (context.mounted) showSnack(context, e.message, error: true);
    }
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

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    String title,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this quiz?'),
        content: Text('“$title” and all of its questions are removed.'),
        actions: [
          BauhausButton.ghost(
            label: 'Keep it',
            onPressed: () => Navigator.of(context).pop(false),
          ),
          BauhausButton.danger(
            label: 'Delete',
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(quizRepositoryProvider).deleteQuiz(quizId);
    if (context.mounted) context.go('/quizzes');
  }
}

class _QuestionSummary extends StatelessWidget {
  const _QuestionSummary({required this.question});

  final Question question;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final letter = AnswerTile.letterFor(question.correctIndex);

    return Semantics(
      label:
          'Question ${question.orderIndex + 1}. ${question.text}. '
          'Answer option $letter. ${question.difficulty.name} difficulty, '
          '${question.timeLimitSeconds} seconds.',
      excludeSemantics: true,
      child: Container(
        decoration: t.plane(fill: t.surface),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              decoration: t.plane(fill: t.surfaceMuted),
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              child: Text(
                '${question.orderIndex + 1}',
                style: theme.textTheme.labelMedium?.copyWith(color: t.ink),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(question.text, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 6),
                  Text(
                    'Answer $letter · ${question.timeLimitSeconds}s',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: t.inkSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            DifficultyChip(question.difficulty, dense: true),
          ],
        ),
      ),
    );
  }
}
