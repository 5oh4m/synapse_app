import 'enums.dart';

/// The live session document. All connected clients listen to this and render
/// the same question/phase at the same time (spec section 9 sync model).
class QuizSession {
  const QuizSession({
    required this.id,
    required this.quizId,
    required this.quizTitle,
    required this.hostId,
    required this.joinCode,
    required this.status,
    required this.createdAt,
    this.currentQuestionIndex = -1,
    this.totalQuestions = 0,
    this.phase = SessionPhase.asking,
    this.questionStartedAt,
    this.questionEndsAt,
    this.startedAt,
    this.endedAt,
    this.allowLateJoin = true,
  });

  final String id;
  final String quizId;
  final String quizTitle;
  final String hostId;
  final String joinCode;
  final SessionStatus status;

  /// -1 while in the lobby; 0-based once the quiz is running.
  final int currentQuestionIndex;
  final int totalQuestions;
  final SessionPhase phase;
  final DateTime? questionStartedAt;
  final DateTime? questionEndsAt;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final bool allowLateJoin;
  final DateTime createdAt;

  bool get isLobby => status == SessionStatus.lobby;
  bool get isActive => status == SessionStatus.active;
  bool get isEnded => status == SessionStatus.ended;
  bool get isLastQuestion =>
      totalQuestions > 0 && currentQuestionIndex >= totalQuestions - 1;

  QuizSession copyWith({
    SessionStatus? status,
    int? currentQuestionIndex,
    int? totalQuestions,
    SessionPhase? phase,
    DateTime? questionStartedAt,
    DateTime? questionEndsAt,
    DateTime? startedAt,
    DateTime? endedAt,
    bool? allowLateJoin,
  }) => QuizSession(
    id: id,
    quizId: quizId,
    quizTitle: quizTitle,
    hostId: hostId,
    joinCode: joinCode,
    status: status ?? this.status,
    currentQuestionIndex: currentQuestionIndex ?? this.currentQuestionIndex,
    totalQuestions: totalQuestions ?? this.totalQuestions,
    phase: phase ?? this.phase,
    questionStartedAt: questionStartedAt ?? this.questionStartedAt,
    questionEndsAt: questionEndsAt ?? this.questionEndsAt,
    startedAt: startedAt ?? this.startedAt,
    endedAt: endedAt ?? this.endedAt,
    allowLateJoin: allowLateJoin ?? this.allowLateJoin,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'quiz_id': quizId,
    'quiz_title': quizTitle,
    'host_id': hostId,
    'join_code': joinCode,
    'status': status.name,
    'current_question_index': currentQuestionIndex,
    'total_questions': totalQuestions,
    'phase': phase.name,
    'question_started_at': questionStartedAt?.toIso8601String(),
    'question_ends_at': questionEndsAt?.toIso8601String(),
    'started_at': startedAt?.toIso8601String(),
    'ended_at': endedAt?.toIso8601String(),
    'allow_late_join': allowLateJoin,
    'created_at': createdAt.toIso8601String(),
  };

  factory QuizSession.fromJson(Map<String, dynamic> j) => QuizSession(
    id: j['id'] as String,
    quizId: (j['quiz_id'] ?? '') as String,
    quizTitle: (j['quiz_title'] ?? 'Quiz') as String,
    hostId: (j['host_id'] ?? '') as String,
    joinCode: (j['join_code'] ?? '') as String,
    status: enumFromName(
      SessionStatus.values,
      j['status'] as String?,
      SessionStatus.lobby,
    ),
    currentQuestionIndex: (j['current_question_index'] ?? -1) as int,
    totalQuestions: (j['total_questions'] ?? 0) as int,
    phase: enumFromName(
      SessionPhase.values,
      j['phase'] as String?,
      SessionPhase.asking,
    ),
    questionStartedAt: DateTime.tryParse(
      j['question_started_at'] as String? ?? '',
    ),
    questionEndsAt: DateTime.tryParse(j['question_ends_at'] as String? ?? ''),
    startedAt: DateTime.tryParse(j['started_at'] as String? ?? ''),
    endedAt: DateTime.tryParse(j['ended_at'] as String? ?? ''),
    allowLateJoin: (j['allow_late_join'] ?? true) as bool,
    createdAt:
        DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
  );
}
