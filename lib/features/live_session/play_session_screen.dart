import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/motion.dart';
import '../../app/theme.dart';
import '../../core/failure.dart';
import '../../models/enums.dart';
import '../../models/question.dart';
import '../../models/quiz_session.dart';
import '../../models/response.dart';
import '../../models/reveal.dart';
import '../../models/session_participant.dart';
import '../../shared_widgets/answer_tile.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/bauhaus_button.dart';
import '../../shared_widgets/countdown_square.dart';
import '../../shared_widgets/labels.dart';
import '../../shared_widgets/leaderboard_list.dart';
import '../../state/providers.dart';
import 'connection_banner.dart';
import 'question_heading.dart';

/// The student's device during a live session. The loud register: one question,
/// four colour planes, a depleting square and a score that counts.
///
/// How it stays correct across devices and bad wifi:
///
/// * **Selections are keyed by question index** ([_pending]), so an answer can
///   never carry over to the next question.
/// * **The reveal comes from the socket.** The question is fetched once,
///   redacted. `question.revealed` supplies the key and `answer.result` this
///   player's outcome. The screen used to refetch the question on the phase
///   flip and render the stale, redacted copy as revealed for the length of
///   that request — a RangeError on `options[-1]` on every student's device at
///   every reveal. A redacted question is now never treated as revealed.
/// * **Correctness is never taken from the submit response**, which the
///   server withholds until the reveal.
/// * **Countdown on the server clock**, so a phone with a drifting clock still
///   shows the time the server enforces.
/// * **Presence is the server's job.** The screen no longer posts
///   `connected: false` from `dispose` — which threw, because `ref` is gone by
///   then — the socket closing is the signal.
///
/// Layout: the question scrolls, Submit is a bar pinned to the bottom edge, so
/// on a 375 × 667 phone the button is on screen next to four stacked tiles
/// instead of below the fold. Standings stay mounted between questions (just
/// hidden), so ranks slide and scores count on from where they were.
class PlaySessionScreen extends ConsumerStatefulWidget {
  const PlaySessionScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<PlaySessionScreen> createState() => _PlaySessionScreenState();
}

class _PlaySessionScreenState extends ConsumerState<PlaySessionScreen> {
  /// question index -> tapped-but-not-yet-submitted option.
  final Map<int, int> _pending = {};

  /// question index -> the receipt for the answer this device submitted.
  final Map<int, QuizResponse> _submitted = {};

  int _submittingForIndex = -1;
  bool _ensuringJoin = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureJoined());
  }

  Future<void> _ensureJoined() async {
    if (_ensuringJoin || !mounted) return;
    _ensuringJoin = true;
    final user = ref.read(currentUserProvider);
    if (user == null) {
      GoRouter.maybeOf(context)?.go('/login');
      return;
    }
    final repo = ref.read(sessionRepositoryProvider);
    try {
      final session = await ref.read(sessionProvider(widget.sessionId).future);
      if (session == null || !mounted) return;
      final joined = ref
          .read(participantsProvider(widget.sessionId))
          .valueOrNull
          ?.any((p) => p.studentId == user.id);
      // Idempotent and cheap on the server: a re-join no longer broadcasts.
      if (joined != true) {
        await repo.joinSession(joinCode: session.joinCode, student: user);
      }
    } on AppFailure {
      // Surfaced by the connection banner / error views instead.
    } finally {
      _ensuringJoin = false;
    }
  }

  Future<void> _submit(QuizSession session, int index) async {
    final selected = _pending[index];
    final user = ref.read(currentUserProvider);
    if (selected == null || user == null || _submitted.containsKey(index)) {
      return;
    }
    final repo = ref.read(sessionRepositoryProvider);
    setState(() => _submittingForIndex = index);
    try {
      final receipt = await repo.submitAnswer(
        sessionId: widget.sessionId,
        student: user,
        questionIndex: index,
        selectedIndex: selected,
      );
      if (mounted) setState(() => _submitted[index] = receipt);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _submittingForIndex = -1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionAsync = ref.watch(sessionProvider(widget.sessionId));
    final link = ref.watch(liveConnectionProvider);
    final user = ref.watch(currentUserProvider);
    final session = sessionAsync.valueOrNull;

    ref.listen(sessionProvider(widget.sessionId), (previous, next) {
      final before = previous?.valueOrNull;
      final after = next.valueOrNull;
      if (after == null) return;
      if (after.isEnded) {
        GoRouter.maybeOf(context)?.go('/results/${widget.sessionId}');
        return;
      }
      if (before?.currentQuestionIndex != after.currentQuestionIndex) {
        // A new question starts with nothing selected.
        _pending.removeWhere((key, _) => key != after.currentQuestionIndex);
      }
    });

    if (session != null && session.isEnded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          GoRouter.maybeOf(context)?.go('/results/${widget.sessionId}');
        }
      });
      return const Scaffold(
        body: Center(child: LoadingView(label: 'Loading results…')),
      );
    }

    final Widget body;
    final String bodyKey;
    if (session == null) {
      bodyKey = 'status';
      if (sessionAsync.isLoading) {
        body = const LoadingView(label: 'Joining the session');
      } else if (sessionAsync.hasError) {
        body = ErrorView(
          message: '${sessionAsync.error}',
          onRetry: () => ref.invalidate(sessionProvider(widget.sessionId)),
        );
      } else {
        body = EmptyView(
          icon: Icons.link_off,
          title: 'This session has closed',
          subtitle: 'Ask your teacher for a new join code.',
          action: BauhausButton.primary(
            label: 'Enter a code',
            onPressed: () => GoRouter.maybeOf(context)?.go('/join'),
          ),
        );
      }
    } else if (user == null) {
      bodyKey = 'status';
      body = const LoadingView(label: 'Loading your account');
    } else if (session.isLobby) {
      bodyKey = 'lobby';
      body = _WaitingRoom(sessionId: widget.sessionId);
    } else {
      bodyKey = 'live';
      final index = session.currentQuestionIndex;
      body = _LiveBody(
        sessionId: widget.sessionId,
        session: session,
        studentId: user.id,
        selection: _pending[index],
        receipt: _submitted[index],
        submitting: _submittingForIndex == index,
        onSelect: (option) => setState(() => _pending[index] = option),
        onSubmit: () => _submit(session, index),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const EyebrowLabel('Live quiz'),
            Text(
              session?.quizTitle ?? 'Live quiz',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).appBarTheme.titleTextStyle,
            ),
          ],
        ),
        leading: BauhausIconButton(
          icon: Icons.close,
          tooltip: 'Leave quiz',
          semanticLabel: 'Leave the quiz and go home',
          bordered: false,
          onPressed: () => GoRouter.maybeOf(context)?.go('/'),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedSize(
              duration: Motion.dur(context, durQuick),
              curve: easeSnap,
              alignment: Alignment.topCenter,
              child: ConnectionBanner(
                state: link,
                onRetry: () => ref.read(backendProvider).resumeRealtime(),
              ),
            ),
            Expanded(
              child: PlaneSwitcher(switchKey: bodyKey, child: body),
            ),
          ],
        ),
      ),
    );
  }
}

class _WaitingRoom extends ConsumerWidget {
  const _WaitingRoom({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final players =
        ref.watch(participantsProvider(sessionId)).valueOrNull ?? const [];

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: staggered([
              // A filled square: the geometric signal for "ready".
              ExcludeSemantics(
                child: Row(
                  children: [
                    Container(width: 22, height: 22, color: t.correct),
                    const SizedBox(width: 10),
                    EyebrowLabel('You are in', color: t.ink),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Semantics(
                header: true,
                child: Text(
                  'Waiting for the host to start',
                  style: theme.textTheme.displaySmall,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Keep this screen open. The first question appears here the '
                'moment your teacher starts the quiz.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              Semantics(
                liveRegion: true,
                label:
                    '${players.length} ${players.length == 1 ? "player" : "players"} '
                    'in the lobby',
                excludeSemantics: true,
                child: Container(
                  decoration: t.plane(fill: t.surface),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      Expanded(child: EyebrowLabel('In the lobby')),
                      CountUp(
                        value: players.length,
                        liveRegion: false,
                        style: theme.textTheme.headlineMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _LiveBody extends ConsumerWidget {
  const _LiveBody({
    required this.sessionId,
    required this.session,
    required this.studentId,
    required this.selection,
    required this.receipt,
    required this.submitting,
    required this.onSelect,
    required this.onSubmit,
  });

  final String sessionId;
  final QuizSession session;
  final String studentId;
  final int? selection;
  final QuizResponse? receipt;
  final bool submitting;
  final ValueChanged<int> onSelect;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final gutter = t.gutterFor(MediaQuery.sizeOf(context).width);
    final clock = ref.watch(serverClockProvider);

    final index = session.currentQuestionIndex;
    final revealing = session.phase == SessionPhase.revealing;
    final questionAsync = ref.watch(
      publicQuestionProvider((sessionId: sessionId, index: index)),
    );
    final reveal = ref.watch(revealProvider(sessionId)).valueOrNull;
    final result = (ref.watch(myResultsProvider(sessionId)).valueOrNull ??
        const <int, AnswerResult>{})[index];
    final players =
        ref.watch(participantsProvider(sessionId)).valueOrNull ?? const [];

    SessionParticipant? me;
    for (final p in players) {
      if (p.studentId == studentId) me = p;
    }
    final myRank = players.indexWhere((p) => p.studentId == studentId) + 1;

    // "Answered" survives a reload through the server's roster, not just the
    // local receipt.
    final answered =
        receipt != null ||
        (result?.answered ?? false) ||
        (me?.lastAnsweredIndex ?? -1) >= index;
    final chosen = result?.selectedIndex ?? receipt?.selectedIndex ?? selection;

    final question = questionAsync.valueOrNull;
    // The key only ever comes from a reveal for *this* question. Until then
    // the question stays redacted and nothing indexes it with -1.
    final applicable = revealing && reveal?.questionIndex == index
        ? reveal
        : null;
    final shown = question == null
        ? null
        : (applicable?.applyTo(question) ?? question);
    final keyRevealed = shown != null && revealing && shown.correctIndex >= 0;

    Widget questionArea() {
      if (shown == null) {
        if (questionAsync.hasError) {
          return ErrorView(
            message: '${questionAsync.error}',
            onRetry: () => ref.invalidate(
              publicQuestionProvider((sessionId: sessionId, index: index)),
            ),
          );
        }
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: LoadingView(label: 'Loading the question'),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          QuestionHeading(text: shown.text, focusOnMount: true),
          const SizedBox(height: 18),
          AnswerTileGrid(
            // Keyed by question only: the same tiles stay mounted through the
            // reveal, so the correct one wipes instead of re-entering.
            key: ValueKey('play-$index'),
            options: shown.options,
            selectedIndex: keyRevealed ? result?.selectedIndex ?? chosen : chosen,
            correctIndex: keyRevealed ? shown.correctIndex : null,
            lockedIn: answered,
            enabled: !revealing && !answered,
            onSelect: (revealing || answered) ? null : onSelect,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: gutter, vertical: gutter),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _LiveHeader(
                      index: index,
                      total: session.totalQuestions,
                      score: me?.totalScore ?? 0,
                      rank: myRank,
                      streak: me?.streak ?? 0,
                      deadline: revealing ? null : session.questionEndsAt,
                      timeLimit: Duration(
                        seconds: shown?.timeLimitSeconds ?? 20,
                      ),
                      now: clock.now,
                      // Time is up: send whatever is selected rather than
                      // dropping it. The server allows 750 ms of grace.
                      onExpire: () {
                        if (!answered && selection != null) onSubmit();
                      },
                    ),
                    const SizedBox(height: 18),
                    PlaneSwitcher(
                      switchKey: 'q-$index-${shown == null}',
                      child: questionArea(),
                    ),
                    if (revealing) ...[
                      const SizedBox(height: 18),
                      PlaneSwitcher(
                        switchKey: 'outcome-$index-$keyRevealed',
                        animateSize: true,
                        duration: durSlow,
                        child: keyRevealed
                            ? _RevealPanel(
                                question: shown,
                                result: result,
                                localChoice: chosen,
                                answered: answered,
                              )
                            : const _RevealPending(),
                      ),
                    ],
                    // Mounted for the whole session and only shown while
                    // revealing, so a rank change slides and a score counts
                    // on from its last value instead of from zero.
                    Visibility(
                      visible: revealing,
                      maintainState: true,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SectionHeader(
                              eyebrow: 'Standings',
                              title: 'Leaderboard',
                            ),
                            const SizedBox(height: 12),
                            LeaderboardList(
                              rows: rowsFromParticipants(
                                players,
                                highlightStudentId: studentId,
                              ),
                              dense: true,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      session.isLastQuestion
                          ? 'Last question — results next.'
                          : 'The host controls when the quiz moves on.',
                      style: theme.textTheme.bodySmall?.copyWith(color: t.ink),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (!revealing && shown != null)
          _SubmitBar(
            gutter: gutter,
            child: PlaneSwitcher(
              switchKey: 'submit-$index-$answered',
              animateSize: true,
              child: answered
                  ? _LockedIn(hasLocalCopy: receipt != null)
                  : BauhausButton.primary(
                      label: 'Submit answer',
                      trailingIcon: Icons.lock_outline,
                      semanticLabel: selection == null
                          ? 'Submit answer. Pick an option first.'
                          : 'Submit option ${AnswerTile.letterFor(selection!)}',
                      expand: true,
                      busy: submitting,
                      onPressed: selection == null || submitting
                          ? null
                          : onSubmit,
                    ),
            ),
          ),
      ],
    );
  }
}

/// The action strip pinned to the bottom edge: always reachable by a thumb,
/// whatever the length of the question above it.
class _SubmitBar extends StatelessWidget {
  const _SubmitBar({required this.gutter, required this.child});

  final double gutter;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.line, width: t.borderWidth)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _LiveHeader extends StatelessWidget {
  const _LiveHeader({
    required this.index,
    required this.total,
    required this.score,
    required this.rank,
    required this.streak,
    required this.deadline,
    required this.timeLimit,
    required this.now,
    required this.onExpire,
  });

  final int index;
  final int total;
  final int score;
  final int rank;
  final int streak;
  final DateTime? deadline;
  final Duration timeLimit;
  final DateTime Function() now;
  final VoidCallback onExpire;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              EyebrowLabel('Question ${index + 1} of $total'),
              const SizedBox(height: 8),
              // Score is a live region: it must reach a screen reader.
              CountUp(
                value: score,
                suffix: ' pts',
                style: theme.textTheme.displaySmall,
                semanticsLabel: rank > 0
                    ? 'Score, $score points, rank $rank'
                    : 'Score, $score points',
              ),
              if (rank > 0 || streak >= 2) ...[
                const SizedBox(height: 6),
                Text(
                  [
                    if (rank > 0) 'Rank $rank',
                    if (streak >= 2) '$streak in a row',
                  ].join(' · '),
                  style: theme.textTheme.labelMedium?.copyWith(color: t.ink),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 16),
        if (deadline != null)
          CountdownSquare(
            deadline: deadline!,
            total: timeLimit,
            size: 84,
            now: now,
            onExpire: onExpire,
          ),
      ],
    );
  }
}

class _LockedIn extends StatelessWidget {
  const _LockedIn({required this.hasLocalCopy});

  final bool hasLocalCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final message = hasLocalCopy
        ? 'Answer locked in. Waiting for the rest of the class…'
        : 'You already answered this question.';

    return Semantics(
      liveRegion: true,
      label: message,
      excludeSemantics: true,
      child: Container(
        constraints: BoxConstraints(minHeight: t.minTouchTarget),
        decoration: t.plane(fill: t.surface),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.lock_outline, color: t.ink),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message, style: theme.textTheme.titleSmall),
            ),
          ],
        ),
      ),
    );
  }
}

/// Between the phase flip and the key arriving (normally one frame; longer
/// after a reconnect while the channel restores the reveal).
class _RevealPending extends StatelessWidget {
  const _RevealPending();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    return Semantics(
      liveRegion: true,
      label: 'Revealing the answer',
      excludeSemantics: true,
      child: Container(
        decoration: t.plane(fill: t.surface),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            MarchingSquares(color: t.ink),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'Revealing the answer…',
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RevealPanel extends StatelessWidget {
  const _RevealPanel({
    required this.question,
    required this.result,
    required this.localChoice,
    required this.answered,
  });

  /// Always revealed here: `correctIndex >= 0`.
  final Question question;

  /// The server's verdict, from `answer.result`. Arrives right after the key.
  final AnswerResult? result;

  /// What this device knows was chosen, for the moment before [result].
  final int? localChoice;
  final bool answered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);

    final choice = result?.selectedIndex ?? (answered ? localChoice : null);
    final noAnswer = choice == null || choice < 0;
    final correct = result?.isCorrect ?? (!noAnswer && choice == question.correctIndex);
    final points = result?.pointsAwarded;

    final (Color fill, String headline) = noAnswer
        ? (t.inkMuted, answered ? 'Answer submitted' : 'No answer')
        : correct
        ? (t.correct, points == null ? 'Correct' : 'Correct  +$points')
        : (t.wrong, 'Not quite');

    final onFill = noAnswer ? t.ink : QuizzleColors.paper;
    final letter = AnswerTile.letterFor(question.correctIndex);
    final answerText = question.options[question.correctIndex];

    return Semantics(
      // The reveal outcome must be announced the moment it lands.
      liveRegion: true,
      label:
          '$headline. The answer was option $letter, $answerText.'
          '${question.explanation.isEmpty ? '' : ' ${question.explanation}'}',
      excludeSemantics: true,
      child: Container(
        decoration: t.plane(fill: fill),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  noAnswer
                      ? Icons.timer_off_outlined
                      : correct
                      ? Icons.check
                      : Icons.close,
                  color: onFill,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    headline,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: onFill,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Answer: option $letter · $answerText',
              style: theme.textTheme.titleSmall?.copyWith(color: onFill),
            ),
            if (question.explanation.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                question.explanation,
                style: theme.textTheme.bodyMedium?.copyWith(color: onFill),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
