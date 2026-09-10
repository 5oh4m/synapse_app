import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive.dart';
import '../../models/enums.dart';
import '../../models/quiz.dart';
import '../../state/providers.dart';
import '../../shared_widgets/app_scaffold.dart';
import '../../shared_widgets/async_view.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    if (user == null) {
      return const Scaffold(body: LoadingView());
    }
    final isEducator = user.role == UserRole.educator;
    return AppScaffold(
      title: 'Hi, ${user.name.split(' ').first}',
      currentRoute: '/',
      floatingActionButton: isEducator
          ? FloatingActionButton.extended(
              onPressed: () => context.go('/create'),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('New quiz'),
            )
          : null,
      body: isEducator ? const _EducatorHome() : const _StudentHome(),
    );
  }
}

class _EducatorHome extends ConsumerWidget {
  const _EducatorHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider)!;
    final quizzes = ref.watch(quizzesProvider(user.id));
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _QuickActions(
          actions: [
            _Action(
              'Upload material',
              Icons.upload_file,
              () => context.go('/create'),
            ),
            _Action(
              'Content library',
              Icons.folder_outlined,
              () => context.go('/library'),
            ),
            _Action(
              'My quizzes',
              Icons.quiz_outlined,
              () => context.go('/quizzes'),
            ),
            _Action(
              'Analytics',
              Icons.insights_outlined,
              () => context.go('/analytics'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('Recent quizzes', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        quizzes.when(
          loading: () =>
              const Padding(padding: EdgeInsets.all(24), child: LoadingView()),
          error: (e, _) => ErrorView(message: '$e'),
          data: (list) {
            if (list.isEmpty) {
              return const EmptyView(
                icon: Icons.auto_awesome_outlined,
                title: 'No quizzes yet',
                subtitle: 'Upload a PDF, slide deck or photo to generate one.',
              );
            }
            return Column(
              children: [for (final q in list.take(6)) _QuizTile(quiz: q)],
            );
          },
        ),
      ],
    );
  }
}

class _StudentHome extends ConsumerWidget {
  const _StudentHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final published = ref.watch(publishedQuizzesProvider);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Join a live quiz',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Enter the code your teacher shows on screen.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () => context.go('/join'),
                  icon: const Icon(Icons.login),
                  label: const Text('Enter join code'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        _QuickActions(
          actions: [
            _Action(
              'Leaderboard',
              Icons.leaderboard_outlined,
              () => context.go('/leaderboard'),
            ),
            _Action(
              'My profile',
              Icons.account_circle_outlined,
              () => context.go('/profile'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          'Practice published quizzes',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        published.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(message: '$e'),
          data: (list) => list.isEmpty
              ? const EmptyView(
                  icon: Icons.menu_book_outlined,
                  title: 'Nothing published yet',
                )
              : Column(
                  children: [
                    for (final q in list.take(8))
                      Card(
                        child: ListTile(
                          title: Text(q.title),
                          subtitle: Text(
                            '${q.subject} · ${q.questionCount} questions',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => context.go('/join'),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _Action {
  _Action(this.label, this.icon, this.onTap);
  final String label;
  final IconData icon;
  final VoidCallback onTap;
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.actions});
  final List<_Action> actions;

  @override
  Widget build(BuildContext context) {
    final cols = responsive<int>(context, compact: 2, medium: 3, expanded: 4);
    return GridView.count(
      crossAxisCount: cols,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.6,
      children: [
        for (final a in actions)
          Card(
            child: InkWell(
              onTap: a.onTap,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(a.icon, color: Theme.of(context).colorScheme.primary),
                    const Spacer(),
                    Text(
                      a.label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _QuizTile extends ConsumerWidget {
  const _QuizTile({required this.quiz});
  final Quiz quiz;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        title: Text(quiz.title),
        subtitle: Text(
          '${quiz.isPublished ? "Published" : "Draft"} · '
          '${quiz.questionCount} questions'
          '${quiz.subject.isNotEmpty ? " · ${quiz.subject}" : ""}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.go('/quiz/${quiz.id}'),
      ),
    );
  }
}
