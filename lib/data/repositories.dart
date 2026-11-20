import 'dart:typed_data';

import '../ai/quiz_generator.dart';
import '../core/connection.dart';
import '../core/failure.dart';
import '../core/server_clock.dart';
import '../models/content_item.dart';
import '../models/enums.dart';
import '../models/extracted_content.dart';
import '../models/leaderboard_entry.dart';
import '../models/question.dart';
import '../models/quiz.dart';
import '../models/quiz_session.dart';
import '../models/response.dart';
import '../models/reveal.dart';
import '../models/session_participant.dart';
import '../models/user.dart';

/// Backend-agnostic contracts — the seam the screens never look behind.
///
/// Implementations:
///  * [RemoteBackend] — the JWT + Postgres server in `backend/` (docs/API.md).
///    The only one that supports real multi-device play.
///  * [InMemoryBackend] — one isolate, no network. Tests and a zero-setup
///    single-device demo. It is not multi-device and does not claim to be.
abstract class Backend {
  AuthRepository get auth;
  ContentRepository get content;
  QuizRepository get quizzes;
  SessionRepository get sessions;
  LeaderboardRepository get leaderboard;
  AnalyticsRepository get analytics;

  /// Question generation. Owned by the backend because the model key and the
  /// rate limit live server-side; the in-memory backend generates offline.
  QuizGenerator get generator;

  /// Human label for the "how are questions generated" banner.
  String get generatorLabel;

  /// True only when host and students can be on different devices.
  bool get isMultiDevice;

  /// Realtime status for the reconnect banner. Backends without a socket
  /// report a single, permanent value rather than faking a connection.
  Stream<ConnectionState> connectionState();

  /// Server time as estimated on this device. Countdowns use it instead of the
  /// local clock, so a device whose clock drifts still closes on time.
  ServerClock get clock;

  /// The app came back to the foreground (or the user asked to retry): drop any
  /// backoff and check the realtime link now instead of waiting up to 15 s.
  void resumeRealtime();

  /// Local-storage problems worth telling the user about (a full browser quota,
  /// for example). Previously these were swallowed by `catch (_) {}`.
  Stream<AppFailure> storageIssues();

  Future<void> init();

  Future<void> dispose();
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

  /// One-tap demo identity for the sign-in screen.
  ///
  /// It exists as a repository call because the two backends do genuinely
  /// different things: the server logs in (or registers) a demo account with a
  /// dev password, while the in-memory backend hands over a local profile
  /// without any credential at all — it deliberately keeps none.
  Future<AppUser> demoSignIn(UserRole role);

  Future<void> signOut();
  Future<AppUser> updateProfile({String? name});
}

abstract class ContentRepository {
  Stream<List<ContentItem>> watchLibrary(String ownerId);
  Future<ContentItem> get(String id);

  /// Creates a library item from text that is already in hand (pasted, or
  /// returned by [extractFile]).
  ///
  /// `ownerId` is accepted for call-site compatibility but the server ignores
  /// it: identity always comes from the JWT (docs/API.md rule 1).
  Future<ContentItem> ingest({
    String? ownerId,
    required String title,
    String? subject,
    required ContentType sourceType,
    required String rawText,
    int pageCount,
    String? fileName,
  });

  /// Uploads the file and lets the **server** extract it, creating the library
  /// item in one round trip (`POST /content/upload`).
  Future<ContentItem> upload({
    required String fileName,
    required Uint8List bytes,
    String? title,
    String? subject,
  });

  /// Extracts text without creating a library item (`POST /content/extract`),
  /// so the educator can review it before saving.
  Future<ExtractedContent> extractFile({
    required String fileName,
    required Uint8List bytes,
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
    String? ownerId,
    required String title,
    String? subject,
    String? contentItemId,
  });
  Future<void> saveQuiz(Quiz quiz);
  Future<void> publish(String quizId);
  Future<void> unpublish(String quizId);
  Future<void> deleteQuiz(String quizId);

  Future<void> addQuestions(String quizId, List<Question> questions);

  /// Writes one question **in place**.
  ///
  /// If [question]'s id is not a known question, the row at the same
  /// `order_index` in the same quiz is replaced instead of a new one being
  /// appended. That is the guard for the confirmed "Regenerate duplicated a
  /// question" bug, where a freshly generated id turned 2 questions into 3 with
  /// two rows claiming `order_index: 0`.
  Future<void> saveQuestion(Question question);

  /// Explicit replace-by-id (`PUT /questions/:id`): keeps the id and the
  /// `order_index`, changes everything else.
  Future<Question> replaceQuestion(String questionId, Question replacement);

  Future<void> deleteQuestion(String quizId, String questionId);
  Future<void> reorderQuestions(String quizId, List<String> orderedIds);

  Future<List<Quiz>> publishedQuizzes();

  /// Grades one practice answer. Only a quiz's owner receives its answer key
  /// from [watchQuestions]; everyone else gets redacted questions and asks the
  /// backend whether each answer was right. Throws a `CONFLICT` failure while
  /// the quiz is being played live.
  Future<PracticeGrade> gradePractice({
    required String quizId,
    required String questionId,
    required int selectedIndex,
  });
}

abstract class SessionRepository {
  /// `hostId` and `questions` are accepted for call-site compatibility; the
  /// server derives the host from the JWT and snapshots the questions itself
  /// (so editing the quiz mid-session cannot change what is being played).
  Future<QuizSession> createSession({
    required Quiz quiz,
    String? hostId,
    List<Question> questions,
  });

  Stream<QuizSession?> watchSession(String sessionId);
  Stream<List<SessionParticipant>> watchParticipants(String sessionId);
  Stream<List<QuizResponse>> watchResponses(String sessionId);

  /// Live "n of m answered" during `asking`, fed by the server's coalesced
  /// `answer.count` delta.
  Stream<({int answered, int total})> watchAnswerCount(String sessionId);

  /// The current question's key, explanation and distribution once it is
  /// revealed; null while it is being asked. Fed by `question.revealed`, so a
  /// reveal needs no request.
  Stream<RevealInfo?> watchReveal(String sessionId);

  /// The signed-in player's own results, keyed by question index. Entries only
  /// appear for revealed questions.
  Stream<Map<int, AnswerResult>> watchMyResults(String sessionId);

  Future<QuizSession?> findByJoinCode(String code);

  /// HOST ONLY — carries the answer key. A student calling this gets a 404.
  Future<List<Question>> sessionQuestions(String sessionId);

  /// Student-facing question. `correctIndex == -1` and an empty explanation
  /// until the host (or the server's timer) reveals.
  Future<Question?> publicQuestionAt(String sessionId, int index);

  Future<SessionParticipant> joinSession({
    required String joinCode,
    AppUser? student,
  });

  Future<void> setConnected({
    required String sessionId,
    String? studentId,
    required bool connected,
  });

  // Host controls. Enforced server-side: a student hitting one gets a 404.
  Future<void> startSession(String sessionId);
  Future<void> revealAnswer(String sessionId);
  Future<void> nextQuestion(String sessionId);
  Future<void> endSession(String sessionId);

  /// `responseTimeMs` is ignored on purpose. The server measures elapsed time
  /// against `question_started_at` inside the write transaction, so no client
  /// clock can influence a score (docs/API.md rule 2). The parameter stays only
  /// so existing call sites keep compiling.
  ///
  /// Until the question is revealed the returned response confirms receipt
  /// only: `isCorrect` is false and `pointsAwarded` 0 regardless of the answer.
  /// Read the real outcome from [watchMyResults].
  Future<QuizResponse> submitAnswer({
    required String sessionId,
    AppUser? student,
    required int questionIndex,
    required int selectedIndex,
    int responseTimeMs,
  });
}

abstract class LeaderboardRepository {
  /// `period` is `week` | `month` | `all-time`, `subject` an exact (case
  /// insensitive) match. Both are really applied now — the previous server
  /// accepted them and ignored them, which made the UI toggle a dead control.
  Stream<List<LeaderboardEntry>> watchGlobal({
    String period = 'all-time',
    String? subject,
  });

  /// Subjects that actually have played results, for the filter.
  Future<List<String>> subjects();
}

class QuestionStat {
  const QuestionStat({
    required this.questionId,
    required this.text,
    required this.answers,
    required this.correct,
    required this.orderIndex,
    this.averageTimeMs = 0,
  });
  final String questionId;
  final String text;
  final int answers;
  final int correct;
  final int orderIndex;
  final int averageTimeMs;
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
