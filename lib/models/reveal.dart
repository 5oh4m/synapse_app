import 'question.dart';

/// What `question.revealed` told the room, so a device can show the key and
/// the histogram without another request.
class RevealInfo {
  const RevealInfo({
    required this.questionIndex,
    required this.correctIndex,
    required this.explanation,
    required this.distribution,
  });

  final int questionIndex;
  final int correctIndex;
  final String explanation;
  final List<int> distribution;

  /// Applies the revealed key onto a redacted question.
  Question applyTo(Question redacted) => redacted.copyWith(
    correctIndex: correctIndex,
    explanation: explanation.isEmpty ? redacted.explanation : explanation,
  );

  factory RevealInfo.fromJson(Map<String, dynamic> j, {int? fallbackIndex}) =>
      RevealInfo(
        questionIndex:
            (j['question_index'] as num?)?.toInt() ?? fallbackIndex ?? -1,
        correctIndex: (j['correct_index'] as num?)?.toInt() ?? -1,
        explanation: (j['explanation'] as String?) ?? '',
        distribution: [
          for (final n in (j['distribution'] as List? ?? const []))
            (n as num).toInt(),
        ],
      );
}

/// One player's own outcome for one question. The server only sends it once the
/// question is revealed — correctness is part of the answer key.
class AnswerResult {
  const AnswerResult({
    required this.questionIndex,
    required this.selectedIndex,
    required this.isCorrect,
    required this.pointsAwarded,
    this.responseTimeMs = 0,
  });

  final int questionIndex;

  /// -1 when the timer ran out with no answer.
  final int selectedIndex;
  final bool isCorrect;
  final int pointsAwarded;
  final int responseTimeMs;

  bool get answered => selectedIndex >= 0;

  factory AnswerResult.fromJson(Map<String, dynamic> j) => AnswerResult(
    questionIndex: (j['question_index'] as num?)?.toInt() ?? -1,
    selectedIndex: (j['selected_index'] as num?)?.toInt() ?? -1,
    isCorrect: (j['is_correct'] as bool?) ?? false,
    pointsAwarded: (j['points_awarded'] as num?)?.toInt() ?? 0,
    responseTimeMs: (j['response_time_ms'] as num?)?.toInt() ?? 0,
  );
}

/// The server's verdict on one practice answer.
class PracticeGrade {
  const PracticeGrade({
    required this.questionId,
    required this.selectedIndex,
    required this.isCorrect,
    required this.correctIndex,
    required this.explanation,
  });

  final String questionId;
  final int selectedIndex;
  final bool isCorrect;
  final int correctIndex;
  final String explanation;

  factory PracticeGrade.fromJson(Map<String, dynamic> j) => PracticeGrade(
    questionId: (j['question_id'] as String?) ?? '',
    selectedIndex: (j['selected_index'] as num?)?.toInt() ?? -1,
    isCorrect: (j['is_correct'] as bool?) ?? false,
    correctIndex: (j['correct_index'] as num?)?.toInt() ?? -1,
    explanation: (j['explanation'] as String?) ?? '',
  );
}
