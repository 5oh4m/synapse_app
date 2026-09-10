import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/quiz.dart';
import '../../state/controllers.dart';
import '../../state/providers.dart';
import '../../shared_widgets/app_scaffold.dart';
import '../../shared_widgets/async_view.dart';

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
      currentRoute: '/quizzes',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/create'),
        icon: const Icon(Icons.auto_awesome),
        label: const Text('New quiz'),
      ),
      body: quizzes.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: '$e'),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyView(
              icon: Icons.quiz_outlined,
              title: 'No quizzes yet',
              subtitle: 'Generate one from your lecture material.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final q = list[i];
              return Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  title: Text(
                    q.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    [
                      q.isPublished ? 'Published' : 'Draft',
                      '${q.questionCount} questions',
                      if (q.subject.isNotEmpty) q.subject,
                    ].join(' · '),
                  ),
                  trailing: q.isPublished
                      ? FilledButton.icon(
                          onPressed: () => _goLive(context, ref, q),
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: const Text('Go live'),
                        )
                      : const Chip(label: Text('Draft')),
                  onTap: () => context.go('/quiz/${q.id}'),
                ),
              );
            },
          );
        },
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
