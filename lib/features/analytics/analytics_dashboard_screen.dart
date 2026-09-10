import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/enums.dart';
import '../../models/quiz.dart';
import '../../state/providers.dart';
import '../../shared_widgets/app_scaffold.dart';
import '../../shared_widgets/async_view.dart';

class AnalyticsDashboardScreen extends ConsumerWidget {
  const AnalyticsDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final quizzes = user == null
        ? const AsyncValue<List<Quiz>>.loading()
        : ref.watch(quizzesProvider(user.id));

    return AppScaffold(
      title: 'Analytics',
      currentRoute: '/analytics',
      body: quizzes.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: '$e'),
        data: (list) {
          final published = list
              .where((q) => q.status == QuizStatus.published)
              .toList();
          if (published.isEmpty) {
            return const EmptyView(
              icon: Icons.insights_outlined,
              title: 'No published quizzes',
              subtitle: 'Publish and run a quiz to see analytics.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: published.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final q = published[i];
              return Card(
                child: ListTile(
                  title: Text(q.title),
                  subtitle: Text('${q.questionCount} questions · ${q.subject}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/analytics/quiz/${q.id}'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
