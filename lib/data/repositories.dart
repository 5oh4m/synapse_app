import '../models/content_item.dart';
import '../models/enums.dart';
import '../models/leaderboard_entry.dart';
import '../models/question.dart';
import '../models/quiz.dart';
import '../models/quiz_session.dart';
import '../models/response.dart';
import '../models/session_participant.dart';
import '../models/user.dart';

/// Backend-agnostic contracts. Concrete implementations: [InMemoryBackend]
/// (default) and [RemoteBackend] (bundled Node server). A Firebase
/// implementation is documented in docs/BACKEND_FIREBASE.md.
abstract class Backend {
  AuthRepository get auth;
  ContentRepository get content;
  QuizRepository get quizzes;
  SessionRepository get sessions;
  LeaderboardRepository get leaderboard;
  AnalyticsRepository get analytics;
  Future<void> init();
}

abstract class AuthRepository {
  Stream<AppUser?> authState();
  AppUser? get currentUser;
  Future<AppUser> register({
    required String name,
    required String email,
    required String password,
    required UserRole role,
  });
  Future<AppUser> signIn({required String email, required String password});
  Future<void> signOut();
  Future<AppUser> updateProfile({String? name});
}

abstract class ContentRepository {
  Stream<List<ContentItem>> watchLibrary(String ownerId);
  Future<ContentItem> get(String id);

  /// Creates the library item and runs the extraction step. `rawText` is the
  /// text already pulled from the file by [ContentExtractor].
  Future<ContentItem> ingest({
    required String ownerId,
    required String title,
    String? subject,
    required ContentType sourceType,
    required String rawText,
    int pageCount,
    String? fileName,
  });
  Future<void> delete(String id);
}

abstract class QuizRepository {
  Stream<List<Quiz>> watchQuizzes(String ownerId);
  Stream<Quiz?> watchQuiz(String quizId);
  Stream<List<Question>> watchQuestions(String quizId);
  Future<Quiz> get(String quizId);
  Future<List<Question>> questionsOnce(String quizId);

  Future<Quiz> createDraft({
    required String ownerId,
    required String title,
    String? subject,
    String? contentItemId,
  });
  Future<void> saveQuiz(Quiz quiz);
  Future<void> publish(String quizId);
  Future<void> unpublish(String quizId);
  Future<void> deleteQuiz(String quizId);

  Future<void> addQuestions(String quizId, List<Question> questions);
  Future<void> saveQuestion(Question question);
  Future<void> deleteQuestion(String quizId, String questionId);
  Future<void> reorderQuestions(String quizId, List<String> orderedIds);

  Future<List<Quiz>> publishedQuizzes();
}

abstract class SessionRepository {
  Future<QuizSession> createSession({
    required Quiz quiz,
    required String hostId,
    required List<Question> questions,
  });
  Stream<QuizSession?> watchSession(String sessionId);
  Stream<List<SessionParticipant>> watchParticipants(String sessionId);
  Stream<List<QuizResponse>> watchResponses(String sessionId);

  Future<QuizSession?> findByJoinCode(String code);
  Future<List<Question>> sessionQuestions(String sessionId);

  /// Answer key stripped unless the session has revealed this index — students
  /// never receive [Question.correctIndex] early.
  Future<Question?> publicQuestionAt(String sessionId, int index);

  Future<SessionParticipant> joinSession({
    required String joinCode,
    required AppUser student,
  });
  Future<void> setConnected({
    required String sessionId,
    required String studentId,
    required bool connected,
  });

  // Host controls (drive the shared session doc all clients listen to).
  Future<void> startSession(String sessionId);
  Future<void> revealAnswer(String sessionId);
  Future<void> nextQuestion(String sessionId);
  Future<void> endSession(String sessionId);

  Future<QuizResponse> submitAnswer({
    required String sessionId,
    required AppUser student,
    required int questionIndex,
    required int selectedIndex,
    required int responseTimeMs,
  });
}

abstract class LeaderboardRepository {
  Stream<List<LeaderboardEntry>> watchGlobal({
    String period = 'all-time',
    String? subject,
  });
}

class QuestionStat {
  const QuestionStat({
    required this.questionId,
    required this.text,
    required this.answers,
    required this.correct,
    required this.orderIndex,
  });
  final String questionId;
  final String text;
  final int answers;
  final int correct;
  final int orderIndex;
  double get correctRate => answers == 0 ? 0 : correct / answers;
}

class QuizAnalytics {
  const QuizAnalytics({
    required this.quizId,
    required this.sessionsRun,
    required this.participants,
    required this.averageScore,
    required this.averageCorrectRate,
    required this.completionRate,
    required this.questionStats,
  });
  final String quizId;
  final int sessionsRun;
  final int participants;
  final double averageScore;
  final double averageCorrectRate;
  final double completionRate;
  final List<QuestionStat> questionStats;

  QuestionStat? get hardestQuestion {
    if (questionStats.isEmpty) return null;
    final withData = questionStats.where((q) => q.answers > 0).toList();
    if (withData.isEmpty) return null;
    withData.sort((a, b) => a.correctRate.compareTo(b.correctRate));
    return withData.first;
  }
}

class StudentQuizResult {
  const StudentQuizResult({
    required this.sessionId,
    required this.quizTitle,
    required this.score,
    required this.rank,
    required this.playedAt,
    required this.correct,
    required this.total,
  });
  final String sessionId;
  final String quizTitle;
  final int score;
  final int rank;
  final DateTime playedAt;
  final int correct;
  final int total;
}

abstract class AnalyticsRepository {
  Future<QuizAnalytics> quizAnalytics(String quizId);
  Future<List<StudentQuizResult>> studentHistory(String studentId);
}
