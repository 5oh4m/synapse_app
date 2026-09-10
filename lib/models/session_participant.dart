class SessionParticipant {
  const SessionParticipant({
    required this.id,
    required this.sessionId,
    required this.studentId,
    required this.displayName,
    required this.joinedAt,
    this.totalScore = 0,
    this.correctCount = 0,
    this.answeredCount = 0,
    this.streak = 0,
    this.connected = true,
    this.lastAnsweredIndex = -1,
  });

  final String id;
  final String sessionId;
  final String studentId;
  final String displayName;
  final DateTime joinedAt;
  final int totalScore;
  final int correctCount;
  final int answeredCount;
  final int streak;
  final bool connected;

  /// Highest question index this participant has submitted an answer for.
  /// Guards against double scoring on reconnect.
  final int lastAnsweredIndex;

  SessionParticipant copyWith({
    String? displayName,
    int? totalScore,
    int? correctCount,
    int? answeredCount,
    int? streak,
    bool? connected,
    int? lastAnsweredIndex,
  }) => SessionParticipant(
    id: id,
    sessionId: sessionId,
    studentId: studentId,
    displayName: displayName ?? this.displayName,
    joinedAt: joinedAt,
    totalScore: totalScore ?? this.totalScore,
    correctCount: correctCount ?? this.correctCount,
    answeredCount: answeredCount ?? this.answeredCount,
    streak: streak ?? this.streak,
    connected: connected ?? this.connected,
    lastAnsweredIndex: lastAnsweredIndex ?? this.lastAnsweredIndex,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'session_id': sessionId,
    'student_id': studentId,
    'display_name': displayName,
    'joined_at': joinedAt.toIso8601String(),
    'total_score': totalScore,
    'correct_count': correctCount,
    'answered_count': answeredCount,
    'streak': streak,
    'connected': connected,
    'last_answered_index': lastAnsweredIndex,
  };

  factory SessionParticipant.fromJson(Map<String, dynamic> j) =>
      SessionParticipant(
        id: j['id'] as String,
        sessionId: (j['session_id'] ?? '') as String,
        studentId: (j['student_id'] ?? '') as String,
        displayName: (j['display_name'] ?? 'Player') as String,
        joinedAt:
            DateTime.tryParse(j['joined_at'] as String? ?? '') ??
            DateTime.now(),
        totalScore: (j['total_score'] ?? 0) as int,
        correctCount: (j['correct_count'] ?? 0) as int,
        answeredCount: (j['answered_count'] ?? 0) as int,
        streak: (j['streak'] ?? 0) as int,
        connected: (j['connected'] ?? true) as bool,
        lastAnsweredIndex: (j['last_answered_index'] ?? -1) as int,
      );
}
