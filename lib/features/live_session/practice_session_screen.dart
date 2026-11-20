import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/motion.dart';
import '../../app/theme.dart';
import '../../core/failure.dart';
import '../../models/question.dart';
import '../../models/quiz.dart';
import '../../models/reveal.dart';
import '../../models/scoring.dart';
import '../../shared_widgets/answer_distribution_bar.dart';
import '../../shared_widgets/answer_tile.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/bauhaus_button.dart';
import '../../shared_widgets/bauhaus_card.dart';
import '../../shared_widgets/labels.dart';
import '../../state/providers.dart';
import 'question_heading.dart';

/// Self-paced practice on a published quiz.
///
/// This is the destination the student home's "practice" cards used to lack —
/// they pointed at `/join`, which asks for a live code that does not exist for
/// a published quiz. This screen is a real runner: the same [AnswerTile] and
/// the same scoring model as a live session, minus the clock and the class.
///
/// Nothing is written to the server: practice is a rehearsal, it does not move
/// the global leaderboard, and the screen says so.
class PracticeSessionScreen extends ConsumerStatefulWidget {
  const PracticeSessionScreen({super.key, required this.quizId});

  final String quizId;

  @override
  ConsumerState<PracticeSessionScreen> createState() =>
      _PracticeSessionScreenState();
}

class _PracticeSessionScreenState
    extends ConsumerState<PracticeSessionScreen> {
  final FocusNode _headingFocus = FocusNode(debugLabel: 'practice question');

  int _index = 0;
  bool _finished = false;
  DateTime _askedAt = DateTime.now();

  /// question index -> chosen option. Keyed by index, so an answer can never
  /// leak onto the next question.
  final Map<int, int> _answers = {};
  final Map<int, int> _points = {};

  /// question index -> the backend's verdict. Only a quiz's owner receives its
  /// answer key; everyone else asks the backend after committing to an answer.
  final Map<int, PracticeGrade> _grades = {};

  @override
  void dispose() {
    _headingFocus.dispose();
    super.dispose();
  }

  int get _score => _points.values.fold(0, (a, b) => a + b);
  int get _correctCount => _grades.values.where((g) => g.isCorrect).length;

  Future<void> _answer(Question q, ScoringConfig scoring, int selected) async {
    final index = _index;
    if (_answers.containsKey(index)) return;
    final elapsed = DateTime.now().difference(_askedAt).inMilliseconds;
    // Lock the choice at once; the verdict follows.
    setState(() => _answers[index] = selected);
    try {
      final grade = await ref
          .read(quizRepositoryProvider)
          .gradePractice(
            quizId: widget.quizId,
            questionId: q.id,
            selectedIndex: selected,
          );
      if (!mounted) return;
      setState(() {
        _grades[index] = grade;
        _points[index] = scoring.pointsFor(
          isCorrect: grade.isCorrect,
          responseTimeMs: elapsed,
          timeLimitMs: q.timeLimitSeconds * 1000,
        );
      });
    } on AppFailure catch (e) {
      if (!mounted) return;
      // Let the player try again rather than stranding a locked tile.
      setState(() => _answers.remove(index));
      showSnack(context, e.message, error: true);
    }
  }

  void _next(int total) {
    setState(() {
      if (_index >= total - 1) {
        _finished = true;
      } else {
        _index++;
        _askedAt = DateTime.now();
      }
    });
    if (!_finished) {
      // Focus follows the question, exactly as it does when a host advances.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _headingFocus.requestFocus();
      });
    }
  }

  void _restart() {
    setState(() {
      _index = 0;
      _finished = false;
      _answers.clear();
      _points.clear();
      _grades.clear();
      _askedAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    final quiz = ref.watch(quizProvider(widget.quizId)).valueOrNull;
    final questionsAsync = ref.watch(questionsProvider(widget.quizId));
    final gutter = t.gutterFor(MediaQuery.sizeOf(context).width);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const EyebrowLabel('Practice'),
            Text(
              quiz?.title ?? 'Practice',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).appBarTheme.titleTextStyle,
            ),
          ],
        ),
        leading: BauhausIconButton(
          icon: Icons.close,
          tooltip: 'Leave practice',
          semanticLabel: 'Leave practice and go home',
          bordered: false,
          onPressed: () => context.go('/'),
        ),
      ),
      body: SafeArea(
        child: questionsAsync.when(
          loading: () => const LoadingView(label: 'Loading questions'),
          error: (e, _) => ErrorView(
            message: '$e',
            onRetry: () => ref.invalidate(questionsProvider(widget.quizId)),
          ),
          data: (questions) {
            if (questions.isEmpty) {
              return EmptyView(
                icon: Icons.help_outline,
                title: 'This quiz has no questions yet',
                subtitle: 'Ask your teacher to add some.',
                action: BauhausButton.secondary(
                  label: 'Back to home',
                  onPressed: () => context.go('/'),
                ),
              );
            }
            final scoring = quiz?.scoring ?? const ScoringConfig();
            final index = _index.clamp(0, questions.length - 1);
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: _finished
                    ? _Summary(
                        quiz: quiz,
                        questions: questions,
                        answers: _answers,
                        grades: _grades,
                        score: _score,
                        correct: _correctCount,
                        onRestart: _restart,
                        gutter: gutter,
                      )
                    : _Runner(
                        question: questions[index],
                        index: index,
                        total: questions.length,
                        score: _score,
                        selected: _answers[index],
                        grade: _grades[index],
                        headingFocus: _headingFocus,
                        gutter: gutter,
                        points: _points[index],
                        onSelect: (i) =>
                            _answer(questions[index], scoring, i),
                        onNext: () => _next(questions.length),
                      ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Runner extends StatelessWidget {
  const _Runner({
    required this.question,
    required this.index,
    required this.total,
    required this.score,
    required this.selected,
    required this.grade,
    required this.headingFocus,
    required this.gutter,
    required this.points,
    required this.onSelect,
    required this.onNext,
  });

  final Question question;
  final int index;
  final int total;
  final int score;
  final int? selected;

  /// The verdict once it is back; null while the answer is being graded.
  final PracticeGrade? grade;
  final FocusNode headingFocus;
  final double gutter;
  final int? points;
  final ValueChanged<int> onSelect;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final answered = selected != null;
    final revealed = grade != null;
    final isCorrect = grade?.isCorrect ?? false;

    return ListView(
      padding: EdgeInsets.symmetric(horizontal: gutter, vertical: gutter),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  EyebrowLabel('Question ${index + 1} of $total'),
                  const SizedBox(height: 6),
                  _ProgressBlocks(index: index, total: total),
                ],
              ),
            ),
            const SizedBox(width: 12),
            CountUp(
              value: score,
              suffix: ' pts',
              style: theme.textTheme.headlineMedium,
              semanticsLabel: 'Score, $score points',
            ),
          ],
        ),
        const SizedBox(height: 18),
        QuestionHeading(text: question.text, focusNode: headingFocus),
        const SizedBox(height: 18),
        AnswerTileGrid(
          options: question.options,
          selectedIndex: selected,
          correctIndex: revealed ? grade!.correctIndex : null,
          lockedIn: answered,
          enabled: !answered,
          onSelect: answered ? null : onSelect,
          // The grid replays its stagger on every question because the key
          // changes with the index.
          key: ValueKey('practice-options-$index'),
        ),
        const SizedBox(height: 18),
        if (answered && !revealed)
          Container(
            decoration: t.plane(fill: t.surface),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                MarchingSquares(color: t.ink),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Checking your answer…',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          )
        else if (!revealed)
          Container(
            decoration: t.plane(fill: t.surface),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.timer_outlined, size: 18, color: t.ink),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Answer at your own pace — answering quickly still earns '
                    'the speed bonus.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: t.inkSecondary,
                    ),
                  ),
                ),
              ],
            ),
          )
        else ...[
          _Outcome(
            correct: isCorrect,
            points: points ?? 0,
            explanation: grade!.explanation,
          ),
          const SizedBox(height: 18),
          BauhausButton.primary(
            label: index >= total - 1 ? 'See your result' : 'Next question',
            trailingIcon: index >= total - 1
                ? Icons.flag_outlined
                : Icons.arrow_forward,
            expand: true,
            autofocus: true,
            onPressed: onNext,
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

/// One small square per question — filled once answered. Wraps rather than
/// overflowing, and carries no text, so large text scales cannot clip it.
class _ProgressBlocks extends StatelessWidget {
  const _ProgressBlocks({required this.index, required this.total});

  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    return ExcludeSemantics(
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (var i = 0; i < total; i++)
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: i < index
                    ? t.ink
                    : i == index
                    ? t.warn
                    : const Color(0x00000000),
                border: Border.all(color: t.line, width: 2),
              ),
            ),
        ],
      ),
    );
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome({
    required this.correct,
    required this.points,
    required this.explanation,
  });

  final bool correct;
  final int points;
  final String explanation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final headline = correct ? 'Correct  +$points' : 'Not quite';

    return Semantics(
      liveRegion: true,
      label: explanation.isEmpty ? headline : '$headline. $explanation',
      excludeSemantics: true,
      child: Container(
        decoration: t.plane(fill: correct ? t.correct : t.wrong),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  correct ? Icons.check : Icons.close,
                  color: QuizzleColors.paper,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    headline,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: QuizzleColors.paper,
                    ),
                  ),
                ),
              ],
            ),
            if (explanation.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                explanation,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: QuizzleColors.paper,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.quiz,
    required this.questions,
    required this.answers,
    required this.grades,
    required this.score,
    required this.correct,
    required this.onRestart,
    required this.gutter,
  });

  final Quiz? quiz;
  final List<Question> questions;
  final Map<int, int> answers;
  final Map<int, PracticeGrade> grades;
  final int score;
  final int correct;
  final VoidCallback onRestart;
  final double gutter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final total = questions.length;
    final accuracy = total == 0 ? 0.0 : correct / total;

    return ListView(
      padding: EdgeInsets.symmetric(horizontal: gutter, vertical: gutter),
      children: staggered([
        const EyebrowLabel('Practice complete'),
        const SizedBox(height: 8),
        Semantics(
          header: true,
          child: Text(
            quiz?.title ?? 'Practice',
            style: theme.textTheme.displaySmall,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          decoration: t.plane(fill: t.inverseGround),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              EyebrowLabel('Your score', color: t.inverseInk),
              const SizedBox(height: 8),
              CountUp(
                value: score,
                style: theme.textTheme.displayLarge?.copyWith(
                  color: t.inverseInk,
                ),
                semanticsLabel: 'You scored $score points',
              ),
              const SizedBox(height: 6),
              Text(
                '$correct of $total correct',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: t.inverseInk,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        BauhausCard(
          child: BauhausMeter(
            factor: accuracy,
            label: 'Accuracy',
            valueText: '${(accuracy * 100).round()}%',
          ),
        ),
        const SizedBox(height: 18),
        const SectionHeader(eyebrow: 'Review', title: 'Question by question'),
        const SizedBox(height: 12),
        for (var i = 0; i < questions.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ReviewRow(
              index: i,
              question: questions[i],
              chosen: answers[i],
              grade: grades[i],
            ),
          ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: BauhausButton.primary(
                label: 'Practise again',
                icon: Icons.refresh,
                expand: true,
                onPressed: onRestart,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: BauhausButton.secondary(
                label: 'Back to home',
                expand: true,
                onPressed: () => context.go('/'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          'Practice runs stay on this device — they do not change the global '
          'leaderboard.',
          style: theme.textTheme.bodySmall?.copyWith(color: t.ink),
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}

class _ReviewRow extends StatelessWidget {
  const _ReviewRow({
    required this.index,
    required this.question,
    required this.chosen,
    required this.grade,
  });

  final int index;
  final Question question;
  final int? chosen;

  /// Null when the question was never graded (no answer given).
  final PracticeGrade? grade;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final right = grade?.isCorrect ?? false;
    final chosenLetter = chosen == null
        ? 'no answer'
        : 'option ${AnswerTile.letterFor(chosen!)}';
    final key = grade?.correctIndex ?? -1;
    final correctLetter = key >= 0 ? AnswerTile.letterFor(key) : '—';

    return Semantics(
      label:
          'Question ${index + 1}. ${question.text}. You picked $chosenLetter. '
          '${right ? 'Correct' : 'The answer was option $correctLetter'}.',
      excludeSemantics: true,
      child: Container(
        decoration: t.plane(fill: t.surface),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 14,
              height: 14,
              margin: const EdgeInsets.only(top: 4),
              color: right ? t.correct : t.wrong,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Q${index + 1}. ${question.text}',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    right
                        ? 'You picked ${chosenLetter.toUpperCase()} — correct'
                        : key >= 0 && key < question.options.length
                        ? 'Answer: option $correctLetter · '
                              '${question.options[key]}'
                        : 'Not answered',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: t.inkSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
