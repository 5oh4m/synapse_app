class QuizResponse {
  const QuizResponse({
    required this.id,
    required this.sessionId,
    required this.studentId,
    required this.questionId,
    required this.questionIndex,
    required this.selectedIndex,
    required this.isCorrect,
    required this.responseTimeMs,
    required this.pointsAwarded,
    required this.answeredAt,
  });

  final String id;
  final String sessionId;
  final String studentId;
  final String questionId;
  final int questionIndex;

  /// -1 means the timer expired with no answer.
  final int selectedIndex;
  final bool isCorrect;
  final int responseTimeMs;
  final int pointsAwarded;
  final DateTime answeredAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'session_id': sessionId,
    'student_id': studentId,
    'question_id': questionId,
    'question_index': questionIndex,
    'selected_index': selectedIndex,
    'is_correct': isCorrect,
    'response_time_ms': responseTimeMs,
    'points_awarded': pointsAwarded,
    'answered_at': answeredAt.toIso8601String(),
  };

  factory QuizResponse.fromJson(Map<String, dynamic> j) => QuizResponse(
    id: j['id'] as String,
    sessionId: (j['session_id'] ?? '') as String,
    studentId: (j['student_id'] ?? '') as String,
    questionId: (j['question_id'] ?? '') as String,
    questionIndex: (j['question_index'] ?? 0) as int,
    selectedIndex: (j['selected_index'] ?? -1) as int,
    isCorrect: (j['is_correct'] ?? false) as bool,
    responseTimeMs: (j['response_time_ms'] ?? 0) as int,
    pointsAwarded: (j['points_awarded'] ?? 0) as int,
    answeredAt:
        DateTime.tryParse(j['answered_at'] as String? ?? '') ?? DateTime.now(),
  );
}
