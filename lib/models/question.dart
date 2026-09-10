import 'enums.dart';

/// One multiple-choice question. Shape mirrors the AI JSON schema in the spec
/// (question / options / correct_index / explanation / difficulty /
/// source_reference) plus fields the editor needs.
class Question {
  const Question({
    required this.id,
    required this.quizId,
    required this.text,
    required this.options,
    required this.correctIndex,
    required this.explanation,
    required this.difficulty,
    required this.orderIndex,
    this.sourceReference = '',
    this.timeLimitSeconds = 20,
  });

  final String id;
  final String quizId;
  final String text;
  final List<String> options;
  final int correctIndex;
  final String explanation;
  final Difficulty difficulty;
  final String sourceReference;
  final int orderIndex;
  final int timeLimitSeconds;

  bool isValid() =>
      text.trim().isNotEmpty &&
      options.length == 4 &&
      options.every((o) => o.trim().isNotEmpty) &&
      correctIndex >= 0 &&
      correctIndex < options.length &&
      timeLimitSeconds >= 5 &&
      timeLimitSeconds <= 120;

  Question copyWith({
    String? text,
    List<String>? options,
    int? correctIndex,
    String? explanation,
    Difficulty? difficulty,
    String? sourceReference,
    int? orderIndex,
    int? timeLimitSeconds,
  }) => Question(
    id: id,
    quizId: quizId,
    text: text ?? this.text,
    options: options ?? this.options,
    correctIndex: correctIndex ?? this.correctIndex,
    explanation: explanation ?? this.explanation,
    difficulty: difficulty ?? this.difficulty,
    sourceReference: sourceReference ?? this.sourceReference,
    orderIndex: orderIndex ?? this.orderIndex,
    timeLimitSeconds: timeLimitSeconds ?? this.timeLimitSeconds,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'quiz_id': quizId,
    'question_text': text,
    'options': options,
    'correct_index': correctIndex,
    'explanation': explanation,
    'difficulty': difficulty.name,
    'source_reference': sourceReference,
    'order_index': orderIndex,
    'time_limit_seconds': timeLimitSeconds,
  };

  factory Question.fromJson(Map<String, dynamic> j) => Question(
    id: j['id'] as String,
    quizId: (j['quiz_id'] ?? '') as String,
    text: (j['question_text'] ?? j['question'] ?? '') as String,
    options: (j['options'] as List? ?? const [])
        .map((e) => e.toString())
        .toList(growable: false),
    correctIndex: (j['correct_index'] ?? 0) as int,
    explanation: (j['explanation'] ?? '') as String,
    difficulty: enumFromName(
      Difficulty.values,
      j['difficulty'] as String?,
      Difficulty.medium,
    ),
    sourceReference: (j['source_reference'] ?? '') as String,
    orderIndex: (j['order_index'] ?? 0) as int,
    timeLimitSeconds: (j['time_limit_seconds'] ?? 20) as int,
  );
}
