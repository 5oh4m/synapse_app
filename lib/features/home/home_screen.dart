import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/motion.dart';
import '../../app/theme.dart';
import '../../data/repositories.dart';
import '../../models/enums.dart';
import '../../models/quiz.dart';
import '../../shared_widgets/app_scaffold.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/bauhaus_button.dart';
import '../../shared_widgets/bauhaus_card.dart';
import '../../shared_widgets/labels.dart';
import '../../shared_widgets/leaderboard_list.dart';
import '../../state/providers.dart';

/// Home. Two registers from one vocabulary: the educator gets a **Bento Box**
/// dashboard of modular planes; the student gets a loud "join" plane and a
/// short stack of sections.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    if (user == null) {
      return const Scaffold(body: LoadingView(label: 'Loading your account'));
    }
    final isEducator = user.role == UserRole.educator;
    final firstName = user.name.trim().isEmpty
        ? 'there'
        : user.name.trim().split(' ').first;

    return AppScaffold(
      title: 'Hi, $firstName',
      eyebrow: isEducator ? 'Educator dashboard' : 'Student home',
      currentRoute: '/',
      padBody: true,
      maxContentWidth: 1180,
      floatingActionButton: isEducator
          ? FloatingActionButton.extended(
              onPressed: () => context.go('/create'),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('New quiz'),
              tooltip: 'Generate a new quiz from lecture material',
            )
          : null,
      body: isEducator ? const _EducatorHome() : const _StudentHome(),
    );
  }
}

// ---------------------------------------------------------------- educator

class _EducatorHome extends ConsumerWidget {
  const _EducatorHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider)!;
    final quizzesAsync = ref.watch(quizzesProvider(user.id));
    final libraryAsync = ref.watch(libraryProvider(user.id));

    final quizzes = quizzesAsync.valueOrNull ?? const <Quiz>[];
    final published = quizzes.where((q) => q.isPublished).length;
    final questions = quizzes.fold<int>(0, (a, q) => a + q.questionCount);
    final library = libraryAsync.valueOrNull?.length ?? 0;

    if (quizzesAsync.hasError && !quizzesAsync.hasValue) {
      return ErrorView(
        message: '${quizzesAsync.error}',
        onRetry: () => ref.invalidate(quizzesProvider(user.id)),
      );
    }

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // Bento: unequal modular tiles on a fixed grid, staggered 40ms apart.
        BentoGrid(
          children: [
            BentoTile(
              child: StatTile(
                label: 'Quizzes',
                numericValue: quizzes.length,
                bordered: false,
                icon: Icons.quiz_outlined,
                caption: quizzesAsync.isLoading ? 'Loading…' : 'in your account',
              ),
            ),
            BentoTile(
              child: StatTile(
                label: 'Published',
                numericValue: published,
                bordered: false,
                icon: Icons.public,
                accent: published > 0 ? null : null,
                caption: published == 0
                    ? 'Publish one to go live'
                    : 'ready to host',
              ),
            ),
            BentoTile(
              child: StatTile(
                label: 'Questions',
                numericValue: questions,
                bordered: false,
                icon: Icons.help_outline,
                caption: 'across all quizzes',
              ),
            ),
            // The one tile allowed to span two columns.
            BentoTile(
              columnSpan: 2,
              eyebrow: 'Recent',
              title: 'Your quizzes',
              trailing: BauhausIconButton(
                icon: Icons.arrow_forward,
                tooltip: 'See all quizzes',
                semanticLabel: 'Open the full quiz list',
                bordered: false,
                onPressed: () => context.go('/quizzes'),
              ),
              child: quizzesAsync.isLoading && quizzes.isEmpty
                  ? const LoadingView(label: 'Loading quizzes', compact: true)
                  : quizzes.isEmpty
                  ? _InlineEmpty(
                      title: 'No quizzes yet',
                      body: 'Upload a PDF, a slide deck or a photo of the '
                          'board and quizzle will draft the questions.',
                      actionLabel: 'Create the first one',
                      onAction: () => context.go('/create'),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final q in quizzes.take(5))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _QuizRow(quiz: q),
                          ),
                      ],
                    ),
            ),
            BentoTile(
              eyebrow: 'Jump to',
              title: 'Shortcuts',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  BauhausButton.secondary(
                    label: 'Upload material',
                    icon: Icons.upload_file,
                    expand: true,
                    onPressed: () => context.go('/create'),
                  ),
                  const SizedBox(height: 10),
                  BauhausButton.secondary(
                    label: 'Content library ($library)',
                    icon: Icons.folder_outlined,
                    semanticLabel: '$library items in the content library',
                    expand: true,
                    onPressed: () => context.go('/library'),
                  ),
                  const SizedBox(height: 10),
                  BauhausButton.secondary(
                    label: 'Analytics',
                    icon: Icons.insights_outlined,
                    expand: true,
                    onPressed: () => context.go('/analytics'),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _QuizRow extends StatelessWidget {
  const _QuizRow({required this.quiz});

  final Quiz quiz;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final meta = [
      quiz.isPublished ? 'Published' : 'Draft',
      '${quiz.questionCount} questions',
      if (quiz.subject.isNotEmpty) quiz.subject,
    ].join(' · ');

    return BauhausCard(
      background: t.surfaceMuted,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      semanticLabel: '${quiz.title}. $meta. Open quiz',
      onTap: () => context.go('/quiz/${quiz.id}'),
      child: Row(
        children: [
          // Square status block: filled when published, outlined when draft.
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: quiz.isPublished ? t.correct : const Color(0x00000000),
              border: Border.all(color: t.line, width: 2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(quiz.title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                // Primary ink: this row sits on the ice-mist plane, where
                // slate would only be legal at large sizes.
                Text(
                  meta,
                  style: theme.textTheme.bodySmall?.copyWith(color: t.ink),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.chevron_right, color: t.ink),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- student

class _StudentHome extends ConsumerWidget {
  const _StudentHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final user = ref.watch(currentUserProvider)!;
    final published = ref.watch(publishedQuizzesProvider);
    final history = ref.watch(studentHistoryProvider(user.id));
    final board = ref.watch(
      globalLeaderboardProvider(const LeaderboardQuery(period: 'all-time')),
    );

    final entries = board.valueOrNull ?? const [];
    final mine = entries.where((e) => e.studentId == user.id).toList();

    return ListView(
      padding: EdgeInsets.zero,
      children: staggered([
        // The loud plane: the one thing a student is here to do.
        Container(
          decoration: t.plane(fill: t.inverseGround),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              EyebrowLabel('Live now', color: t.inverseInk),
              const SizedBox(height: 8),
              Semantics(
                header: true,
                child: Text(
                  'Join a live quiz',
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: t.inverseInk,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Type the code your teacher has on screen.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: t.inverseInk,
                ),
              ),
              const SizedBox(height: 18),
              BauhausButton.secondary(
                label: 'Enter join code',
                icon: Icons.login,
                onPressed: () => context.go('/join'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (mine.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: RankBadge(
              rank: mine.first.rank,
              points: mine.first.points,
              label: 'Your all-time rank',
              of: entries.length,
            ),
          ),
        const SectionHeader(
          eyebrow: 'Self-paced',
          title: 'Practice',
        ),
        const SizedBox(height: 12),
        published.when(
          loading: () => const LoadingView(label: 'Loading quizzes'),
          error: (e, _) => ErrorView(
            message: '$e',
            compact: true,
            onRetry: () => ref.invalidate(publishedQuizzesProvider),
          ),
          data: (list) => list.isEmpty
              ? const EmptyView(
                  icon: Icons.menu_book_outlined,
                  title: 'Nothing published yet',
                  subtitle: 'Your teachers have not published a quiz you can '
                      'practise on.',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final q in list.take(8))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _PracticeRow(quiz: q),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 24),
        SectionHeader(
          eyebrow: 'History',
          title: 'Your recent quizzes',
          trailing: BauhausIconButton(
            icon: Icons.leaderboard_outlined,
            tooltip: 'Global leaderboard',
            semanticLabel: 'Open the global leaderboard',
            bordered: false,
            onPressed: () => context.go('/leaderboard'),
          ),
        ),
        const SizedBox(height: 12),
        history.when(
          loading: () => const LoadingView(label: 'Loading your history'),
          error: (e, _) => ErrorView(
            message: '$e',
            compact: true,
            onRetry: () => ref.invalidate(studentHistoryProvider(user.id)),
          ),
          data: (list) => list.isEmpty
              ? const EmptyView(
                  icon: Icons.history,
                  title: 'No games yet',
                  subtitle: 'Join a live quiz or practise one above and your '
                      'results will show up here.',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final r in list.take(5))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: StudentHistoryRow(result: r),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}

class _PracticeRow extends StatelessWidget {
  const _PracticeRow({required this.quiz});

  final Quiz quiz;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final meta = [
      if (quiz.subject.isNotEmpty) quiz.subject,
      '${quiz.questionCount} questions',
    ].join(' · ');

    return BauhausCard(
      // A real destination: a self-paced run of this quiz, not the live-code
      // screen the old card pointed at.
      onTap: () => context.go('/practice/${quiz.id}'),
      semanticLabel: 'Practise ${quiz.title}. $meta',
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(quiz.title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  meta,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: t.inkSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Practise', style: theme.textTheme.labelMedium),
                const SizedBox(width: 4),
                Icon(Icons.play_arrow, color: t.ink, size: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One past result. Shared by the student home and the profile screen so
/// `studentHistoryProvider` has a single presentation.
class StudentHistoryRow extends StatelessWidget {
  const StudentHistoryRow({super.key, required this.result});

  final StudentQuizResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final when = DateFormat.yMMMd().add_jm().format(result.playedAt);
    final accuracy = result.total == 0
        ? 0
        : ((result.correct / result.total) * 100).round();

    return Semantics(
      label:
          '${result.quizTitle}, rank ${result.rank}, ${result.score} points, '
          '${result.correct} of ${result.total} correct, $when',
      excludeSemantics: true,
      child: Container(
        decoration: t.plane(fill: t.surface),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              decoration: t.plane(fill: t.inverseGround),
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              child: Text(
                '#${result.rank}',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: t.inverseInk,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(result.quizTitle, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    '${result.correct}/${result.total} correct · $accuracy% · $when',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: t.inkSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${result.score}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty({
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          body,
          style: theme.textTheme.bodySmall?.copyWith(color: t.inkSecondary),
        ),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 14),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: BauhausButton.secondary(
              label: actionLabel!,
              icon: Icons.add,
              onPressed: onAction,
            ),
          ),
        ],
      ],
    );
  }
}
