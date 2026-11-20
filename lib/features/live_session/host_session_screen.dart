import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/motion.dart';
import '../../app/theme.dart';
import '../../core/env.dart';
import '../../core/responsive.dart';
import '../../models/enums.dart';
import '../../models/question.dart';
import '../../models/quiz_session.dart';
import '../../shared_widgets/answer_distribution_bar.dart';
import '../../shared_widgets/answer_tile.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/bauhaus_button.dart';
import '../../shared_widgets/bauhaus_card.dart';
import '../../shared_widgets/countdown_square.dart';
import '../../shared_widgets/join_code_display.dart';
import '../../shared_widgets/labels.dart';
import '../../shared_widgets/leaderboard_list.dart';
import '../../state/controllers.dart';
import '../../state/providers.dart';
import 'connection_banner.dart';
import 'question_heading.dart';

/// The host's projector. The loudest surface in the app: the join code at
/// display scale, the question as a heading, four colour planes, and a
/// transport strip pinned to the bottom so the teacher's controls never move.
///
/// Built for the room it is shown in:
///
/// * **Projector width.** At 1024 px and up the stage splits: question and
///   answers on the left, the live answered count and the standings on the
///   right. The single 1000 px column it replaced put the standings below the
///   fold of a 1080p projector and left 920 px unused.
/// * **Live numbers from the socket.** "n / m answered" comes from the
///   coalesced `answer.count` delta, and the reveal's distribution from
///   `question.revealed`. The counter used to read a response list that was
///   only fetched at reveal, so it said 0 for the whole question.
/// * **The server closes questions.** With the networked backend the host's
///   own countdown no longer triggers the reveal — a host laptop with a fast
///   clock cut every question short for the class. The server reveals at the
///   deadline. The offline backend has no server, so there it still does.
/// * **Joining without typing.** The lobby shows the join link and a QR code.
class HostSessionScreen extends ConsumerWidget {
  const HostSessionScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = QuizzleTokens.of(context);
    final sessionAsync = ref.watch(sessionProvider(sessionId));
    final questionsAsync = ref.watch(sessionQuestionsProvider(sessionId));
    final link = ref.watch(liveConnectionProvider);
    final host = ref.read(sessionHostControllerProvider(sessionId));
    final session = sessionAsync.valueOrNull;

    ref.listen(sessionProvider(sessionId), (_, next) {
      final s = next.valueOrNull;
      if (s != null && s.isEnded) {
        GoRouter.maybeOf(context)?.go('/results/$sessionId');
      }
    });

    if (session != null && session.isEnded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          GoRouter.maybeOf(context)?.go('/results/$sessionId');
        }
      });
      return const Scaffold(
        body: Center(child: LoadingView(label: 'Loading results…')),
      );
    }

    final questions = questionsAsync.valueOrNull ?? const <Question>[];

    Widget body;
    Widget? transport;
    String bodyKey = 'status';
    if (session == null) {
      if (sessionAsync.isLoading) {
        body = const LoadingView(label: 'Opening the session');
      } else if (sessionAsync.hasError) {
        body = ErrorView(
          message: '${sessionAsync.error}',
          onRetry: () => ref.invalidate(sessionProvider(sessionId)),
        );
      } else {
        body = EmptyView(
          icon: Icons.link_off,
          title: 'Session not found',
          subtitle: 'It may already have ended.',
          action: BauhausButton.secondary(
            label: 'Back to quizzes',
            onPressed: () => GoRouter.maybeOf(context)?.go('/quizzes'),
          ),
        );
      }
    } else if (session.isLobby) {
      bodyKey = 'lobby';
      final players =
          ref.watch(participantsProvider(sessionId)).valueOrNull ?? const [];
      body = _Lobby(session: session);
      transport = _Transport(
        children: [
          Expanded(
            child: Text(
              players.isEmpty
                  ? 'Waiting for the first player…'
                  : '${players.length} ${players.length == 1 ? "player" : "players"} ready',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          BauhausButton.primary(
            label: 'Start quiz',
            icon: Icons.play_arrow,
            semanticLabel: players.isEmpty
                ? 'Start quiz. Waiting for players to join.'
                : 'Start the quiz for ${players.length} players',
            onPressed: players.isEmpty ? null : host.start,
          ),
        ],
      );
    } else {
      bodyKey = 'live';
      final revealing = session.phase == SessionPhase.revealing;
      body = _HostLive(
        sessionId: sessionId,
        session: session,
        questions: questions,
        loadingQuestions: questionsAsync.isLoading && questions.isEmpty,
      );
      transport = _Transport(
        children: [
          Expanded(
            child: _AnsweredCount(sessionId: sessionId, session: session),
          ),
          PlaneSwitcher(
            switchKey: revealing,
            child: !revealing
                ? BauhausButton.primary(
                    label: 'Reveal answer',
                    icon: Icons.visibility_outlined,
                    onPressed: host.reveal,
                  )
                : BauhausButton.primary(
                    label: session.isLastQuestion ? 'Finish' : 'Next question',
                    icon: session.isLastQuestion
                        ? Icons.flag_outlined
                        : Icons.arrow_forward,
                    semanticLabel: session.isLastQuestion
                        ? 'Finish the quiz and show the results'
                        : 'Move on to question ${session.currentQuestionIndex + 2}',
                    onPressed: () async {
                      try {
                        if (session.isLastQuestion) {
                          await host.end();
                        } else {
                          await host.next();
                        }
                      } catch (_) {
                        // Idempotent or racing with auto-advance: navigate if ended
                      } finally {
                        if (session.isLastQuestion && context.mounted) {
                          GoRouter.maybeOf(context)?.go('/results/$sessionId');
                        }
                      }
                    },
                  ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const EyebrowLabel('Hosting'),
            Text(
              session?.quizTitle ?? 'Live session',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).appBarTheme.titleTextStyle,
            ),
          ],
        ),
        leading: BauhausIconButton(
          icon: Icons.arrow_back,
          tooltip: 'Back to quizzes',
          semanticLabel: 'Leave hosting and go back to quizzes',
          bordered: false,
          onPressed: () => GoRouter.maybeOf(context)?.go('/quizzes'),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: BauhausIconButton(
              icon: Icons.stop_circle_outlined,
              tooltip: 'End session',
              semanticLabel: 'End this session and show the results',
              bordered: false,
              onPressed: () => _confirmEnd(context, host),
            ),
          ),
        ],
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
                detail:
                    'Reconnecting to the session. Players keep their scores.',
                onRetry: () => ref.read(backendProvider).resumeRealtime(),
              ),
            ),
            Expanded(
              child: PlaneSwitcher(switchKey: bodyKey, child: body),
            ),
            if (transport != null) ...[
              Container(height: t.borderWidth, color: t.line),
              transport,
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmEnd(
    BuildContext context,
    SessionHostController host,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End this session?'),
        content: const Text(
          'Players stop where they are and the final results are shown.',
        ),
        actions: [
          BauhausButton.ghost(
            label: 'Keep playing',
            onPressed: () => Navigator.of(context).pop(false),
          ),
          BauhausButton.danger(
            label: 'End session',
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (ok == true) await host.end();
  }
}

/// The pinned control strip. Flat plane, 2px rule above it, controls right.
class _Transport extends StatelessWidget {
  const _Transport({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    return Container(
      color: t.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: children),
    );
  }
}

class _Lobby extends ConsumerWidget {
  const _Lobby({required this.session});

  final QuizSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final players =
        ref.watch(participantsProvider(session.id)).valueOrNull ?? const [];
    final gutter = t.gutterFor(MediaQuery.sizeOf(context).width);
    final url = Env.joinUrl(session.joinCode);
    final wide = !isCompact(context);

    final code = JoinCodeDisplay(
      code: session.joinCode,
      caption: url == null
          ? 'Players open quizzle and enter this code.'
          : 'Scan the code, or open $url',
      onCopy: () => showSnack(context, 'Join code copied'),
      onShare: () async {
        await Clipboard.setData(
          ClipboardData(
            text: url == null
                ? 'Join my quizzle session with code ${session.joinCode}'
                : 'Join my quizzle session: $url',
          ),
        );
        if (context.mounted) {
          showSnack(
            context,
            url == null ? 'Invite copied to the clipboard' : 'Join link copied',
          );
        }
      },
    );

    final Widget joinBlock = url == null
        ? code
        : Flex(
            direction: wide ? Axis.horizontal : Axis.vertical,
            crossAxisAlignment: wide
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              if (wide) Expanded(child: code) else code,
              SizedBox(width: wide ? 24 : 0, height: wide ? 0 : 20),
              _JoinQr(url: url, size: wide ? 220 : 180),
            ],
          );

    return ListView(
      padding: EdgeInsets.symmetric(horizontal: gutter, vertical: gutter),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: staggered([
                // Animation 8: the code's characters stagger in 40ms apart.
                joinBlock,
                const SizedBox(height: 20),
                if (!Env.isRemote) ...[
                  const _MemoryModeNotice(),
                  const SizedBox(height: 20),
                ],
                SectionHeader(
                  eyebrow: 'Lobby',
                  title: 'Players (${players.length})',
                ),
                const SizedBox(height: 14),
                if (players.isEmpty)
                  Container(
                    decoration: t.plane(fill: t.surface),
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        MarchingSquares(color: t.ink),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            'Nobody has joined yet. The list fills in as '
                            'players enter the code.',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (var i = 0; i < players.length; i++)
                        StaggeredEntry(
                          key: ValueKey(players[i].id),
                          index: i,
                          axis: Axis.horizontal,
                          child: BauhausChip(
                            label: players[i].displayName,
                            icon: players[i].connected
                                ? Icons.person
                                : Icons.person_off_outlined,
                            semanticLabel: players[i].connected
                                ? '${players[i].displayName}, connected'
                                : '${players[i].displayName}, disconnected',
                            fill: players[i].connected
                                ? t.surface
                                : t.surfaceMuted,
                          ),
                        ),
                    ],
                  ),
              ]),
            ),
          ),
        ),
      ],
    );
  }
}

/// The join link as a QR code. Always dark modules on a white plane, in both
/// themes, because that is what phone cameras read reliably.
class _JoinQr extends StatelessWidget {
  const _JoinQr({required this.url, required this.size});

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    return Semantics(
      image: true,
      label: 'QR code for the join link $url',
      excludeSemantics: true,
      child: Container(
        decoration: BoxDecoration(
          color: QuizzleColors.paper,
          border: Border.all(color: t.line, width: t.borderWidth),
        ),
        padding: const EdgeInsets.all(10),
        child: QrImageView(
          data: url,
          size: size,
          padding: EdgeInsets.zero,
          backgroundColor: QuizzleColors.paper,
          errorCorrectionLevel: QrErrorCorrectLevel.M,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: QuizzleColors.navy,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: QuizzleColors.navy,
          ),
        ),
      ),
    );
  }
}

/// The default `BACKEND=memory` mode keeps every quiz in this app instance's
/// own memory, so a code shown here only resolves in a tab opened from the
/// same running app.
class _MemoryModeNotice extends StatelessWidget {
  const _MemoryModeNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    return Container(
      decoration: t.plane(fill: t.surface),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Container(width: 14, height: 14, color: t.warn),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const EyebrowLabel('Offline demo mode'),
                const SizedBox(height: 4),
                Text(
                  'This code only works in tabs opened from this same running '
                  'app. For real multi-device play, start backend/ and run '
                  'with BACKEND=remote.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: t.inkSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "n / m answered", as a live region, so the host hears it change. Fed by the
/// server's coalesced `answer.count` delta during the question.
class _AnsweredCount extends ConsumerWidget {
  const _AnsweredCount({
    required this.sessionId,
    required this.session,
    this.large = false,
  });

  final String sessionId;
  final QuizSession session;
  final bool large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final players =
        ref.watch(participantsProvider(sessionId)).valueOrNull ?? const [];
    final counts = ref.watch(answerCountProvider(sessionId)).valueOrNull;
    final total = counts == null || counts.total == 0
        ? players.length
        : counts.total;
    final answered = (counts?.answered ?? 0).clamp(0, total);

    return Semantics(
      liveRegion: true,
      label: '$answered of $total players answered',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const EyebrowLabel('Answered'),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              CountUp(
                value: answered,
                from: answered,
                liveRegion: false,
                duration: durQuick,
                style: large
                    ? theme.textTheme.displayMedium
                    : theme.textTheme.titleLarge,
              ),
              Text(
                ' / $total',
                style: large
                    ? theme.textTheme.headlineMedium
                    : theme.textTheme.titleLarge,
              ),
            ],
          ),
          if (large) ...[
            const SizedBox(height: 10),
            BauhausMeter(
              factor: total == 0 ? 0 : answered / total,
              label: 'Class progress',
              valueText: total == 0 ? '—' : '${(answered * 100 / total).round()}%',
            ),
          ],
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
    required this.loadingQuestions,
  });

  final String sessionId;
  final QuizSession session;
  final List<Question> questions;
  final bool loadingQuestions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final index = session.currentQuestionIndex;
    final host = ref.read(sessionHostControllerProvider(sessionId));
    final backend = ref.watch(backendProvider);
    final clock = ref.watch(serverClockProvider);
    final gutter = t.gutterFor(MediaQuery.sizeOf(context).width);

    if (loadingQuestions || index < 0 || index >= questions.length) {
      return const LoadingView(label: 'Loading the question');
    }
    final question = questions[index];
    final revealing = session.phase == SessionPhase.revealing;
    final players =
        ref.watch(participantsProvider(sessionId)).valueOrNull ?? const [];
    final reveal = ref.watch(revealProvider(sessionId)).valueOrNull;
    final counts = reveal != null && reveal.questionIndex == index
        ? [
            for (var i = 0; i < question.options.length; i++)
              i < reveal.distribution.length ? reveal.distribution[i] : 0,
          ]
        : List<int>.filled(question.options.length, 0);

    final stage = Column(
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
                  EyebrowLabel('Question ${index + 1} of ${questions.length}'),
                  const SizedBox(height: 8),
                  DifficultyChipRow(question: question),
                ],
              ),
            ),
            const SizedBox(width: 16),
            if (!revealing && session.questionEndsAt != null)
              CountdownSquareForHost(
                deadline: session.questionEndsAt!,
                total: Duration(seconds: question.timeLimitSeconds),
                now: clock.now,
                // A networked session is closed by the server at its
                // deadline; only the offline backend needs the host to do it.
                onExpire: backend.isMultiDevice ? null : host.reveal,
              ),
          ],
        ),
        const SizedBox(height: 18),
        PlaneSwitcher(
          switchKey: index,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Focus lands here every time the host advances.
              QuestionHeading(text: question.text, focusOnMount: true),
              const SizedBox(height: 20),
              AnswerTileGrid(
                key: ValueKey('host-$index'),
                options: question.options,
                correctIndex: revealing ? question.correctIndex : null,
                counts: revealing ? counts : null,
                showCounts: revealing,
                enabled: false,
              ),
            ],
          ),
        ),
        PlaneSwitcher(
          switchKey: 'reveal-$index-$revealing',
          animateSize: true,
          duration: durSlow,
          child: !revealing
              ? const SizedBox(width: double.infinity)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 24),
                    BauhausCard(
                      child: AnswerDistributionBar(
                        counts: counts,
                        labels: question.options,
                        correctIndex: question.correctIndex,
                      ),
                    ),
                    if (question.explanation.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      BauhausCard(
                        accentBar: t.correct,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const EyebrowLabel('Why'),
                            const SizedBox(height: 6),
                            Text(
                              question.explanation,
                              style: theme.textTheme.bodyLarge,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );

    Widget standings({required bool compact}) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(eyebrow: 'Standings', title: 'Leaderboard'),
        const SizedBox(height: 12),
        LeaderboardList(rows: rowsFromParticipants(players), dense: compact),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final split = constraints.maxWidth >= Breakpoints.medium;
        if (!split) {
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: gutter, vertical: gutter),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    stage,
                    // Mounted throughout so ranks slide at each reveal.
                    Visibility(
                      visible: revealing,
                      maintainState: true,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: standings(compact: false),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        // Projector: the stage and the room side by side, each scrolling on
        // its own, so neither pushes the other off screen.
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1760),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 3,
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(gutter),
                    child: stage,
                  ),
                ),
                Container(width: t.borderWidth, color: t.line),
                Expanded(
                  flex: 2,
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(gutter),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        BauhausCard(
                          child: _AnsweredCount(
                            sessionId: sessionId,
                            session: session,
                            large: true,
                          ),
                        ),
                        const SizedBox(height: 24),
                        standings(compact: true),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Difficulty and time limit as two pills — the question's metadata line.
class DifficultyChipRow extends StatelessWidget {
  const DifficultyChipRow({super.key, required this.question});

  final Question question;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        BauhausChip(
          label: question.difficulty.name,
          dense: true,
          semanticLabel: 'Difficulty ${question.difficulty.name}',
        ),
        BauhausChip(
          label: '${question.timeLimitSeconds}s',
          dense: true,
          icon: Icons.timer_outlined,
          semanticLabel: '${question.timeLimitSeconds} second time limit',
        ),
      ],
    );
  }
}

/// The countdown, sized for a projector.
class CountdownSquareForHost extends StatelessWidget {
  const CountdownSquareForHost({
    super.key,
    required this.deadline,
    required this.total,
    this.onExpire,
    this.now,
  });

  final DateTime deadline;
  final Duration total;
  final VoidCallback? onExpire;

  /// The server clock; see [CountdownSquare.now].
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    return CountdownSquare(
      deadline: deadline,
      total: total,
      size: 108,
      strokeWidth: 8,
      now: now,
      onExpire: onExpire,
      label: 'Time remaining for this question',
    );
  }
}
