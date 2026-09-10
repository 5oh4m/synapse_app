import 'dart:math';

import '../core/failure.dart';
import '../core/ids.dart';
import '../models/enums.dart';
import '../models/question.dart';
import 'quiz_generator.dart';

/// Offline generator used when no AI provider is configured (the default).
/// It builds fill-in-the-blank and true-statement questions from the extracted
/// text so the whole flow — generate, review, edit, play — works with zero
/// setup and no network. Swap in [AnthropicQuizGenerator] or the backend's
/// generator for real questions.
class MockQuizGenerator implements QuizGenerator {
  MockQuizGenerator([Random? random]) : _rng = random ?? Random(42);

  final Random _rng;

  static final _stop = <String>{
    'the',
    'and',
    'for',
    'are',
    'but',
    'not',
    'you',
    'all',
    'any',
    'can',
    'her',
    'was',
    'one',
    'our',
    'out',
    'day',
    'get',
    'has',
    'him',
    'his',
    'how',
    'man',
    'new',
    'now',
    'old',
    'see',
    'two',
    'way',
    'who',
    'boy',
    'did',
    'its',
    'let',
    'put',
    'say',
    'she',
    'too',
    'use',
    'this',
    'that',
    'with',
    'from',
    'they',
    'have',
    'were',
    'been',
    'their',
    'which',
    'these',
    'also',
    'such',
    'than',
    'then',
    'them',
    'when',
    'what',
    'into',
    'each',
  };

  @override
  Future<List<Question>> generate(
    GenerationRequest request, {
    required String quizId,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final diffs = request.resolvedDifficulties();
    final sentences = _sentences(request.sourceText);
    final questions = <Question>[];
    final usedStems = <String>{};

    for (var i = 0; i < request.count; i++) {
      final q = _buildOne(
        quizId: quizId,
        orderIndex: i,
        difficulty: diffs[i % diffs.length],
        sentences: sentences,
        subject: request.subject.isNotEmpty ? request.subject : request.title,
        usedStems: usedStems,
      );
      questions.add(q);
    }
    // Run the model output through the same validation a real provider hits.
    parseAndValidate(
      [for (final q in questions) q.toJson()..['question'] = q.text],
      quizId: quizId,
      expectedCount: request.count,
    );
    if (questions.length != request.count) {
      throw const AppFailure(
        'Generator produced the wrong number of questions.',
      );
    }
    return questions;
  }

  @override
  Future<Question> regenerateOne(
    GenerationRequest request, {
    required String quizId,
    required int orderIndex,
    required Difficulty difficulty,
    List<String> avoid = const [],
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final sentences = _sentences(request.sourceText);
    return _buildOne(
      quizId: quizId,
      orderIndex: orderIndex,
      difficulty: difficulty,
      sentences: sentences,
      subject: request.subject.isNotEmpty ? request.subject : request.title,
      usedStems: avoid.toSet(),
    );
  }

  Question _buildOne({
    required String quizId,
    required int orderIndex,
    required Difficulty difficulty,
    required List<String> sentences,
    required String subject,
    required Set<String> usedStems,
  }) {
    final usable = sentences
        .where((s) => s.split(' ').length >= 6 && s.split(' ').length <= 34)
        .toList();

    if (usable.isNotEmpty) {
      for (var attempt = 0; attempt < 12; attempt++) {
        final s = usable[_rng.nextInt(usable.length)];
        if (usedStems.contains(s)) continue;
        final built = _clozeFrom(s, sentences);
        if (built != null) {
          usedStems.add(s);
          return Question(
            id: newId(),
            quizId: quizId,
            text: built.text,
            options: built.options,
            correctIndex: built.correctIndex,
            explanation: 'The material states: "${_trim(s, 160)}"',
            difficulty: difficulty,
            sourceReference: 'Page ${1 + (orderIndex ~/ 3)}',
            orderIndex: orderIndex,
            timeLimitSeconds: _timeFor(difficulty),
          );
        }
      }
    }
    return _fallback(quizId, orderIndex, difficulty, subject);
  }

  _Cloze? _clozeFrom(String sentence, List<String> pool) {
    final words = sentence.split(RegExp(r'\s+'));
    final candidates = <String>[];
    for (final w in words) {
      final clean = w.replaceAll(RegExp(r'[^A-Za-z0-9\-]'), '');
      if (clean.length >= 4 && !_stop.contains(clean.toLowerCase())) {
        candidates.add(clean);
      }
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.length.compareTo(a.length));
    final answer = candidates[_rng.nextInt(min(3, candidates.length))];

    final distractPool = <String>{};
    for (final s in pool) {
      for (final w in s.split(RegExp(r'\s+'))) {
        final clean = w.replaceAll(RegExp(r'[^A-Za-z0-9\-]'), '');
        if (clean.length >= 4 &&
            clean.toLowerCase() != answer.toLowerCase() &&
            !_stop.contains(clean.toLowerCase())) {
          distractPool.add(clean);
        }
      }
    }
    final distractors = distractPool.toList()..shuffle(_rng);
    if (distractors.length < 3) {
      distractors.addAll(['none of these', 'all of these', 'not stated']);
    }
    final options = <String>{answer};
    for (final d in distractors) {
      if (options.length == 4) break;
      options.add(d);
    }
    if (options.length < 4) return null;

    final ordered = options.toList()..shuffle(_rng);
    final blanked = sentence.replaceFirst(
      RegExp(RegExp.escape(answer)),
      '_____',
    );
    return _Cloze(
      text: 'Fill in the blank: "${_trim(blanked, 200)}"',
      options: ordered,
      correctIndex: ordered.indexWhere(
        (o) => o.toLowerCase() == answer.toLowerCase(),
      ),
    );
  }

  Question _fallback(
    String quizId,
    int orderIndex,
    Difficulty difficulty,
    String subject,
  ) {
    final topic = subject.isNotEmpty ? subject : 'this material';
    final options = [
      'A concept covered in $topic',
      'An unrelated topic',
      'A term from a different subject',
      'None of the above',
    ]..shuffle(_rng);
    return Question(
      id: newId(),
      quizId: quizId,
      text:
          'Which of the following best relates to $topic? (Q${orderIndex + 1})',
      options: options,
      correctIndex: options.indexWhere(
        (o) => o.startsWith('A concept covered'),
      ),
      explanation:
          'Add more source text to get sharper questions, or enable an AI provider.',
      difficulty: difficulty,
      sourceReference: 'General',
      orderIndex: orderIndex,
      timeLimitSeconds: _timeFor(difficulty),
    );
  }

  int _timeFor(Difficulty d) => switch (d) {
    Difficulty.easy => 15,
    Difficulty.medium => 20,
    Difficulty.hard => 30,
  };

  List<String> _sentences(String text) {
    if (text.trim().isEmpty) return const [];
    return text
        .replaceAll(RegExp(r'\s+'), ' ')
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((s) => s.trim())
        .where((s) => s.length > 20)
        .toList();
  }

  String _trim(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
}

class _Cloze {
  _Cloze({
    required this.text,
    required this.options,
    required this.correctIndex,
  });
  final String text;
  final List<String> options;
  final int correctIndex;
}
