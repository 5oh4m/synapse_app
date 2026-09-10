import '../core/failure.dart';
import '../models/enums.dart';
import '../models/question.dart';

class GenerationRequest {
  const GenerationRequest({
    required this.sourceText,
    required this.count,
    required this.difficultyMix,
    this.subject = '',
    this.title = '',
  });

  final String sourceText;
  final int count;

  /// Weights per difficulty, e.g. {easy: 3, medium: 5, hard: 2}. Values are
  /// relative; they do not need to sum to [count].
  final Map<Difficulty, int> difficultyMix;
  final String subject;
  final String title;

  List<Difficulty> resolvedDifficulties() {
    final total = difficultyMix.values.fold<int>(0, (a, b) => a + b);
    if (total <= 0) {
      return List.filled(count, Difficulty.medium);
    }
    final out = <Difficulty>[];
    difficultyMix.forEach((d, w) {
      final n = ((w / total) * count).round();
      out.addAll(List.filled(n, d));
    });
    while (out.length < count) {
      out.add(Difficulty.medium);
    }
    return out.take(count).toList();
  }
}

/// Turns extracted content into draft questions. Output is always validated
/// against the schema before it reaches storage (spec section 16.5).
abstract class QuizGenerator {
  Future<List<Question>> generate(
    GenerationRequest request, {
    required String quizId,
  });

  /// Regenerate a single question, optionally avoiding text already in use.
  Future<Question> regenerateOne(
    GenerationRequest request, {
    required String quizId,
    required int orderIndex,
    required Difficulty difficulty,
    List<String> avoid = const [],
  });
}

/// Parses + validates the model's JSON array. Throws [AppFailure] on anything
/// malformed so callers can retry or surface the error.
List<Question> parseAndValidate(
  Object? decoded, {
  required String quizId,
  required int expectedCount,
}) {
  if (decoded is Map && decoded['questions'] is List) {
    decoded = decoded['questions'];
  }
  if (decoded is! List || decoded.isEmpty) {
    throw const AppFailure('AI returned no questions.');
  }
  final out = <Question>[];
  for (var i = 0; i < decoded.length; i++) {
    final row = decoded[i];
    if (row is! Map) {
      throw AppFailure('Question ${i + 1} is not an object.');
    }
    final text = (row['question'] ?? row['question_text'] ?? '')
        .toString()
        .trim();
    final options = (row['options'] as List? ?? const [])
        .map((e) => e.toString().trim())
        .toList();
    final correct = row['correct_index'];
    if (text.isEmpty) {
      throw AppFailure('Question ${i + 1} has no text.');
    }
    if (options.length != 4 || options.any((o) => o.isEmpty)) {
      throw AppFailure(
        'Question ${i + 1} must have exactly 4 non-empty options.',
      );
    }
    if (correct is! int || correct < 0 || correct > 3) {
      throw AppFailure('Question ${i + 1} has an invalid correct_index.');
    }
    if (options.toSet().length != options.length) {
      throw AppFailure('Question ${i + 1} has duplicate options.');
    }
    out.add(
      Question(
        id: 'tmp-$i',
        quizId: quizId,
        text: text,
        options: options,
        correctIndex: correct,
        explanation: (row['explanation'] ?? '').toString().trim(),
        difficulty: enumFromName(
          Difficulty.values,
          row['difficulty']?.toString(),
          Difficulty.medium,
        ),
        sourceReference: (row['source_reference'] ?? '').toString().trim(),
        orderIndex: i,
      ),
    );
  }
  if (out.isEmpty) {
    throw const AppFailure('AI returned no valid questions.');
  }
  return out;
}
