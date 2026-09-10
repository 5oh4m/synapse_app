import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../ai/quiz_generator.dart';
import '../../core/failure.dart';
import '../../core/responsive.dart';
import '../../models/enums.dart';
import '../../models/question.dart';
import '../../state/providers.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/difficulty_chip.dart';

class QuestionReviewScreen extends ConsumerWidget {
  const QuestionReviewScreen({super.key, required this.quizId});
  final String quizId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quiz = ref.watch(quizProvider(quizId));
    final questions = ref.watch(questionsProvider(quizId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review questions'),
        leading: BackButton(onPressed: () => context.go('/quiz/$quizId')),
        actions: [
          TextButton.icon(
            onPressed: () async {
              try {
                await ref.read(quizRepositoryProvider).publish(quizId);
                if (context.mounted) {
                  showSnack(context, 'Quiz published.');
                  context.go('/quiz/$quizId');
                }
              } on AppFailure catch (e) {
                if (context.mounted) showSnack(context, e.message, error: true);
              }
            },
            icon: const Icon(Icons.publish),
            label: const Text('Publish'),
          ),
        ],
      ),
      body: quiz.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: '$e'),
        data: (q) {
          if (q == null) {
            return const EmptyView(
              icon: Icons.error_outline,
              title: 'Quiz not found',
            );
          }
          return questions.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(message: '$e'),
            data: (list) => ContentContainer(
              maxWidth: 820,
              child: Column(
                children: [
                  _Banner(
                    draft: !q.isPublished,
                    count: list.length,
                    generator: ref.watch(generatorLabelProvider),
                  ),
                  Expanded(
                    child: list.isEmpty
                        ? const EmptyView(
                            icon: Icons.playlist_add,
                            title: 'No questions',
                            subtitle: 'Add one, or regenerate from content.',
                          )
                        : ReorderableListView.builder(
                            padding: const EdgeInsets.only(bottom: 90),
                            itemCount: list.length,
                            onReorder: (from, to) {
                              final ids = list.map((e) => e.id).toList();
                              if (to > from) to -= 1;
                              final id = ids.removeAt(from);
                              ids.insert(to, id);
                              ref
                                  .read(quizRepositoryProvider)
                                  .reorderQuestions(quizId, ids);
                            },
                            itemBuilder: (context, i) => Padding(
                              key: ValueKey(list[i].id),
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: _QuestionCard(
                                quizId: quizId,
                                question: list[i],
                                subject: q.subject,
                                total: list.length,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addBlank(ref),
        icon: const Icon(Icons.add),
        label: const Text('Add question'),
      ),
    );
  }

  Future<void> _addBlank(WidgetRef ref) async {
    final existing = await ref
        .read(quizRepositoryProvider)
        .questionsOnce(quizId);
    await ref.read(quizRepositoryProvider).addQuestions(quizId, [
      Question(
        id: '',
        quizId: quizId,
        text: 'New question',
        options: const ['Option A', 'Option B', 'Option C', 'Option D'],
        correctIndex: 0,
        explanation: '',
        difficulty: Difficulty.medium,
        orderIndex: existing.length,
      ),
    ]);
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.draft,
    required this.count,
    required this.generator,
  });
  final bool draft;
  final int count;
  final String generator;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: draft ? scheme.tertiaryContainer : scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        draft
            ? '$count draft questions from $generator. Edit anything, then Publish.'
            : 'Published · $count questions. Edits stay live for future sessions.',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _QuestionCard extends ConsumerStatefulWidget {
  const _QuestionCard({
    required this.quizId,
    required this.question,
    required this.subject,
    required this.total,
  });
  final String quizId;
  final Question question;
  final String subject;
  final int total;

  @override
  ConsumerState<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends ConsumerState<_QuestionCard> {
  late TextEditingController _text;
  late List<TextEditingController> _opts;
  late int _correct;
  late Difficulty _difficulty;
  late int _time;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _bind(widget.question);
  }

  void _bind(Question q) {
    _text = TextEditingController(text: q.text);
    _opts = [for (final o in q.options) TextEditingController(text: o)];
    while (_opts.length < 4) {
      _opts.add(TextEditingController());
    }
    _correct = q.correctIndex.clamp(0, 3);
    _difficulty = q.difficulty;
    _time = q.timeLimitSeconds;
  }

  @override
  void didUpdateWidget(covariant _QuestionCard old) {
    super.didUpdateWidget(old);
    if (old.question.id != widget.question.id) {
      for (final c in _opts) {
        c.dispose();
      }
      _text.dispose();
      setState(() => _bind(widget.question));
    }
  }

  @override
  void dispose() {
    _text.dispose();
    for (final c in _opts) {
      c.dispose();
    }
    super.dispose();
  }

  Question _current() => widget.question.copyWith(
    text: _text.text.trim(),
    options: [for (final c in _opts) c.text.trim()],
    correctIndex: _correct,
    difficulty: _difficulty,
    timeLimitSeconds: _time,
  );

  Future<void> _save() async {
    final q = _current();
    if (!q.isValid()) {
      showSnack(
        context,
        'Fill in all 4 options and pick the answer.',
        error: true,
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(quizRepositoryProvider).saveQuestion(q);
      if (mounted) showSnack(context, 'Saved.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _regenerate() async {
    setState(() => _busy = true);
    try {
      final quiz = await ref.read(quizRepositoryProvider).get(widget.quizId);
      final content = quiz.contentItemId == null
          ? null
          : await ref.read(contentRepositoryProvider).get(quiz.contentItemId!);
      final others = await ref
          .read(quizRepositoryProvider)
          .questionsOnce(widget.quizId);
      final regen = await ref
          .read(quizGeneratorProvider)
          .regenerateOne(
            GenerationRequest(
              sourceText: content?.extractedText ?? widget.subject,
              count: 1,
              difficultyMix: {_difficulty: 1},
              subject: quiz.subject,
              title: quiz.title,
            ),
            quizId: widget.quizId,
            orderIndex: widget.question.orderIndex,
            difficulty: _difficulty,
            avoid: [for (final o in others) o.text],
          );
      await ref
          .read(quizRepositoryProvider)
          .saveQuestion(regen.copyWith(orderIndex: widget.question.orderIndex));
      if (mounted) showSnack(context, 'Regenerated.');
    } on AppFailure catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Q${widget.question.orderIndex + 1}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(width: 8),
                DifficultyChip(_difficulty, dense: true),
                const Spacer(),
                if (_busy)
                  const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                IconButton(
                  tooltip: 'Regenerate',
                  onPressed: _busy ? null : _regenerate,
                  icon: const Icon(Icons.casino_outlined),
                ),
                IconButton(
                  tooltip: 'Delete',
                  onPressed: _busy
                      ? null
                      : () => ref
                            .read(quizRepositoryProvider)
                            .deleteQuestion(widget.quizId, widget.question.id),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _text,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Question'),
            ),
            const SizedBox(height: 10),
            RadioGroup<int>(
              groupValue: _correct,
              onChanged: (v) => setState(() => _correct = v ?? _correct),
              child: Column(
                children: [
                  for (var i = 0; i < 4; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Radio<int>(value: i),
                          Expanded(
                            child: TextField(
                              controller: _opts[i],
                              decoration: InputDecoration(
                                isDense: true,
                                labelText:
                                    'Option ${String.fromCharCode(65 + i)}'
                                    '${i == _correct ? "  ✓ correct" : ""}',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                DropdownButton<Difficulty>(
                  value: _difficulty,
                  onChanged: (v) => setState(() => _difficulty = v!),
                  items: [
                    for (final d in Difficulty.values)
                      DropdownMenuItem(value: d, child: Text(d.name)),
                  ],
                ),
                const SizedBox(width: 16),
                const Icon(Icons.timer_outlined, size: 18),
                Expanded(
                  child: Slider(
                    value: _time.toDouble(),
                    min: 5,
                    max: 90,
                    divisions: 17,
                    label: '${_time}s',
                    onChanged: (v) => setState(() => _time = v.round()),
                  ),
                ),
                Text('${_time}s'),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: _busy ? null : _save,
                child: const Text('Save'),
              ),
            ),
            if (widget.question.explanation.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Explanation: ${widget.question.explanation}',
                  style: TextStyle(
                    color: scheme.outline,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
