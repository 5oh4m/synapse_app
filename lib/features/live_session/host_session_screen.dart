import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/env.dart';
import '../../core/responsive.dart';
import '../../models/enums.dart';
import '../../models/question.dart';
import '../../models/quiz_session.dart';
import '../../state/controllers.dart';
import '../../state/providers.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/countdown_ring.dart';
import '../../shared_widgets/leaderboard_list.dart';
import 'option_grid.dart';

class HostSessionScreen extends ConsumerWidget {
  const HostSessionScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider(sessionId));
    final questions = ref.watch(sessionQuestionsProvider(sessionId));

    ref.listen(sessionProvider(sessionId), (_, next) {
      final s = next.valueOrNull;
      if (s != null && s.isEnded) context.go('/results/$sessionId');
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Host'),
        leading: BackButton(onPressed: () => context.go('/quizzes')),
        actions: [
          TextButton.icon(
            onPressed: () =>
                ref.read(sessionHostControllerProvider(sessionId)).end(),
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('End'),
          ),
        ],
      ),
      body: session.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: '$e'),
        data: (s) {
          if (s == null) {
            return const EmptyView(
              icon: Icons.error_outline,
              title: 'Session not found',
            );
          }
          final qs = questions.valueOrNull ?? const <Question>[];
          if (s.isLobby) return _Lobby(sessionId: sessionId, session: s);
          return _HostLive(sessionId: sessionId, session: s, questions: qs);
        },
      ),
    );
  }
}

class _Lobby extends ConsumerWidget {
  const _Lobby({required this.sessionId, required this.session});
  final String sessionId;
  final QuizSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final participants =
        ref.watch(participantsProvider(sessionId)).valueOrNull ?? const [];
    final t = Theme.of(context);
    return ContentContainer(
      maxWidth: 720,
      child: ListView(
        children: [
          const SizedBox(height: 8),
          Text(
            session.quizTitle,
            textAlign: TextAlign.center,
            style: t.textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          if (!Env.isRemote) const _MemoryModeNotice(),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                children: [
                  Text('Join at this code', style: t.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SelectableText(
                    session.joinCode,
                    style: t.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: 8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: session.joinCode),
                          );
                          showSnack(context, 'Code copied');
                        },
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy code'),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(
                              text: 'Join my quizzle: code ${session.joinCode}',
                            ),
                          );
                          showSnack(context, 'Invite copied');
                        },
                        icon: const Icon(Icons.ios_share, size: 16),
                        label: const Text('Copy invite'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Text(
                'Players (${participants.length})',
                style: t.textTheme.titleMedium,
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: participants.isEmpty
                    ? null
                    : () => ref
                          .read(sessionHostControllerProvider(sessionId))
                          .start(),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start quiz'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (participants.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Waiting for players to join…',
                textAlign: TextAlign.center,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in participants)
                  Chip(
                    avatar: CircleAvatar(
                      child: Text(
                        p.displayName.isNotEmpty
                            ? p.displayName[0].toUpperCase()
                            : '?',
                      ),
                    ),
                    label: Text(p.displayName),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The default `BACKEND=memory` mode keeps every quiz in this browser tab's /
/// app instance's own memory. A join code shown here only resolves in another
/// tab, window or device once the app is switched to the Node backend.
class _MemoryModeNotice extends StatelessWidget {
  const _MemoryModeNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Offline demo mode: this code only works in tabs/windows opened '
              'from this same running app. For real multi-device play, start '
              'backend/ and run with BACKEND=remote (see README).',
              style: TextStyle(color: scheme.onTertiaryContainer, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _HostLive extends ConsumerWidget {
  const _HostLive({
    required this.sessionId,
    required this.session,
    required this.questions,
  });
  final String sessionId;
  final QuizSession session;
  final List<Question> questions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idx = session.currentQuestionIndex;
    if (idx < 0 || idx >= questions.length) return const LoadingView();
    final q = questions[idx];
    final participants =
        ref.watch(participantsProvider(sessionId)).valueOrNull ?? const [];
    final responses =
        ref.watch(sessionResponsesProvider(sessionId)).valueOrNull ?? const [];
    final answered = responses
        .where((r) => r.questionIndex == idx && r.selectedIndex >= 0)
        .length;
    final revealing = session.phase == SessionPhase.revealing;
    final host = ref.read(sessionHostControllerProvider(sessionId));
    final t = Theme.of(context);

    final counts = List<int>.filled(q.options.length, 0);
    for (final r in responses.where((r) => r.questionIndex == idx)) {
      if (r.selectedIndex >= 0 && r.selectedIndex < counts.length) {
        counts[r.selectedIndex]++;
      }
    }

    return ContentContainer(
      maxWidth: 900,
      child: ListView(
        children: [
          Row(
            children: [
              Text(
                'Question ${idx + 1} / ${questions.length}',
                style: t.textTheme.titleMedium,
              ),
              const Spacer(),
              if (!revealing && session.questionEndsAt != null)
                CountdownRing(
                  deadline: session.questionEndsAt!,
                  total: Duration(seconds: q.timeLimitSeconds),
                  onExpire: () => host.reveal(),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(q.text, style: t.textTheme.headlineSmall),
          const SizedBox(height: 16),
          OptionGrid(
            options: q.options,
            correctIndex: revealing ? q.correctIndex : null,
            counts: revealing ? counts : null,
            selectedIndex: null,
            enabled: false,
            onTap: (_) {},
          ),
          const SizedBox(height: 16),
          if (!revealing)
            Row(
              children: [
                Text(
                  '$answered / ${participants.length} answered',
                  style: t.textTheme.bodyLarge,
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () => host.reveal(),
                  icon: const Icon(Icons.visibility),
                  label: const Text('Reveal answer'),
                ),
              ],
            )
          else ...[
            if (q.explanation.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(q.explanation),
                ),
              ),
            const SizedBox(height: 16),
            Text('Leaderboard', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            LeaderboardList(
              rows: rowsFromParticipants(participants),
              dense: true,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => host.next(),
              icon: Icon(
                session.isLastQuestion ? Icons.flag : Icons.arrow_forward,
              ),
              label: Text(
                session.isLastQuestion
                    ? 'Finish & show results'
                    : 'Next question',
              ),
            ),
          ],
        ],
      ),
    );
  }
}
