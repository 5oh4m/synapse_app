import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive.dart';
import '../../models/enums.dart';
import '../../models/quiz_session.dart';
import '../../models/response.dart';
import '../../models/session_participant.dart';
import '../../state/providers.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/countdown_ring.dart';
import '../../shared_widgets/leaderboard_list.dart';
import 'option_grid.dart';

class PlaySessionScreen extends ConsumerStatefulWidget {
  const PlaySessionScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<PlaySessionScreen> createState() => _PlaySessionScreenState();
}

class _PlaySessionScreenState extends ConsumerState<PlaySessionScreen> {
  int? _pendingSelection;
  int _submittingForIndex = -1;
  bool _ensuringJoin = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureJoined());
  }

  Future<void> _ensureJoined() async {
    if (_ensuringJoin) return;
    _ensuringJoin = true;
    final user = ref.read(currentUserProvider);
    if (user == null) {
      if (mounted) context.go('/login');
      return;
    }
    try {
      final repo = ref.read(sessionRepositoryProvider);
      final session = await ref.read(sessionProvider(widget.sessionId).future);
      if (session == null) return;
      final joined = ref
          .read(participantsProvider(widget.sessionId))
          .valueOrNull
          ?.any((p) => p.studentId == user.id);
      if (joined != true) {
        await repo.joinSession(joinCode: session.joinCode, student: user);
      }
      await repo.setConnected(
        sessionId: widget.sessionId,
        studentId: user.id,
        connected: true,
      );
    } catch (_) {
      /* handled by UI states */
    }
  }

  @override
  void dispose() {
    final user = ref.read(currentUserProvider);
    if (user != null) {
      unawaited(
        ref
            .read(sessionRepositoryProvider)
            .setConnected(
              sessionId: widget.sessionId,
              studentId: user.id,
              connected: false,
            ),
      );
    }
    super.dispose();
  }

  Future<void> _submit(QuizSession s, int index) async {
    final sel = _pendingSelection;
    final user = ref.read(currentUserProvider);
    if (sel == null || user == null) return;
    setState(() => _submittingForIndex = index);
    final elapsed = s.questionStartedAt == null
        ? 0
        : DateTime.now().difference(s.questionStartedAt!).inMilliseconds;
    try {
      await ref
          .read(sessionRepositoryProvider)
          .submitAnswer(
            sessionId: widget.sessionId,
            student: user,
            questionIndex: index,
            selectedIndex: sel,
            responseTimeMs: elapsed,
          );
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _submittingForIndex = -1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider(widget.sessionId));
    final user = ref.watch(currentUserProvider);

    ref.listen(sessionProvider(widget.sessionId), (_, next) {
      final s = next.valueOrNull;
      if (s != null && s.isEnded) context.go('/results/${widget.sessionId}');
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live quiz'),
        leading: BackButton(onPressed: () => context.go('/')),
      ),
      body: session.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: '$e',
          onRetry: () => ref.invalidate(sessionProvider(widget.sessionId)),
        ),
        data: (s) {
          if (s == null) {
            return ErrorView(
              message: 'This session is no longer available.',
              onRetry: () => context.go('/join'),
            );
          }
          if (user == null) return const LoadingView();
          if (s.isLobby) return _WaitingRoom(sessionId: widget.sessionId);
          return _LiveBody(
            sessionId: widget.sessionId,
            session: s,
            studentId: user.id,
            pendingSelection: _pendingSelection,
            submitting: _submittingForIndex == s.currentQuestionIndex,
            onSelect: (i) => setState(() => _pendingSelection = i),
            onSubmit: () => _submit(s, s.currentQuestionIndex),
          );
        },
      ),
    );
  }
}

class _WaitingRoom extends ConsumerWidget {
  const _WaitingRoom({required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ps =
        ref.watch(participantsProvider(sessionId)).valueOrNull ?? const [];
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF1F9E5B), size: 56),
          const SizedBox(height: 12),
          Text("You're in!", style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          const Text('Waiting for the host to start…'),
          const SizedBox(height: 16),
          Text('${ps.length} player${ps.length == 1 ? "" : "s"} in the lobby'),
        ],
      ),
    );
  }
}

class _LiveBody extends ConsumerWidget {
  const _LiveBody({
    required this.sessionId,
    required this.session,
    required this.studentId,
    required this.pendingSelection,
    required this.submitting,
    required this.onSelect,
    required this.onSubmit,
  });

  final String sessionId;
  final QuizSession session;
  final String studentId;
  final int? pendingSelection;
  final bool submitting;
  final ValueChanged<int> onSelect;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idx = session.currentQuestionIndex;
    final revealing = session.phase == SessionPhase.revealing;
    final questionAsync = ref.watch(
      publicQuestionProvider((sessionId: sessionId, index: idx)),
    );
    final responses =
        ref.watch(sessionResponsesProvider(sessionId)).valueOrNull ?? const [];
    final participants =
        ref.watch(participantsProvider(sessionId)).valueOrNull ?? const [];

    // Keep the reveal-phase question fresh (answer key appears on reveal).
    ref.listen(sessionProvider(sessionId), (prev, next) {
      final a = prev?.valueOrNull;
      final b = next.valueOrNull;
      if (a?.phase != b?.phase ||
          a?.currentQuestionIndex != b?.currentQuestionIndex) {
        ref.invalidate(
          publicQuestionProvider((sessionId: sessionId, index: idx)),
        );
      }
    });

    QuizResponse? mine;
    for (final r in responses) {
      if (r.studentId == studentId && r.questionIndex == idx) mine = r;
    }
    final me = participants
        .where((p) => p.studentId == studentId)
        .cast<SessionParticipant?>()
        .firstWhere((_) => true, orElse: () => null);
    final myRank = participants.indexWhere((p) => p.studentId == studentId) + 1;

    final t = Theme.of(context);

    return questionAsync.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(message: '$e'),
      data: (q) {
        if (q == null) return const LoadingView();
        final answered = mine != null;
        return ContentContainer(
          maxWidth: 760,
          child: ListView(
            children: [
              Row(
                children: [
                  Text(
                    'Q${idx + 1} / ${session.totalQuestions}',
                    style: t.textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (me != null)
                    Text(
                      '${me.totalScore} pts'
                      '${myRank > 0 ? "  ·  #$myRank" : ""}',
                      style: t.textTheme.titleMedium,
                    ),
                  const SizedBox(width: 12),
                  if (!revealing && session.questionEndsAt != null)
                    CountdownRing(
                      deadline: session.questionEndsAt!,
                      total: Duration(seconds: q.timeLimitSeconds),
                      size: 56,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(q.text, style: t.textTheme.headlineSmall),
              const SizedBox(height: 18),
              OptionGrid(
                options: q.options,
                selectedIndex: revealing
                    ? mine?.selectedIndex
                    : (pendingSelection ?? mine?.selectedIndex),
                correctIndex: revealing ? q.correctIndex : null,
                enabled: !revealing && !answered,
                onTap: onSelect,
              ),
              const SizedBox(height: 18),
              if (!revealing)
                if (answered)
                  _Pill(
                    icon: Icons.lock_outline,
                    text: 'Answer locked in. Waiting for others…',
                    color: t.colorScheme.primary,
                  )
                else
                  FilledButton(
                    onPressed: pendingSelection == null || submitting
                        ? null
                        : onSubmit,
                    child: submitting
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Submit answer'),
                  )
              else
                _RevealPanel(mine: mine, question: q),
              if (revealing) ...[
                const SizedBox(height: 20),
                Text('Leaderboard', style: t.textTheme.titleMedium),
                const SizedBox(height: 8),
                LeaderboardList(
                  rows: rowsFromParticipants(
                    participants,
                    highlightStudentId: studentId,
                  ),
                  dense: true,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _RevealPanel extends StatelessWidget {
  const _RevealPanel({required this.mine, required this.question});
  final QuizResponse? mine;
  final dynamic question;

  @override
  Widget build(BuildContext context) {
    final correct = mine?.isCorrect ?? false;
    final points = mine?.pointsAwarded ?? 0;
    final noAnswer = mine == null || mine!.selectedIndex < 0;
    final color = correct
        ? const Color(0xFF1F9E5B)
        : Theme.of(context).colorScheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(correct ? Icons.check_circle : Icons.cancel, color: color),
            const SizedBox(width: 8),
            Text(
              noAnswer
                  ? 'No answer'
                  : correct
                  ? 'Correct!  +$points'
                  : 'Not quite',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
            ),
          ],
        ),
        if ((question.explanation as String).isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(question.explanation as String),
        ],
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}
