import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../ai/quiz_generator.dart';
import '../../ai/remote_quiz_generator.dart';
import '../../core/connection.dart';
import '../../core/env.dart';
import '../../core/failure.dart';
import '../../core/server_clock.dart';
import '../../models/content_item.dart';
import '../../models/enums.dart';
import '../../models/extracted_content.dart';
import '../../models/leaderboard_entry.dart';
import '../../models/question.dart';
import '../../models/quiz.dart';
import '../../models/quiz_session.dart';
import '../../models/response.dart';
import '../../models/reveal.dart';
import '../../models/session_participant.dart';
import '../../models/user.dart';
import '../local/token_store.dart';
import '../repositories.dart';
import 'api_client.dart';
import 'realtime_client.dart';
import 'session_channel.dart';

/// Local refresh keys. These are *not* server channels: they mark data this
/// device just changed, so its own streams re-read once. Nothing is timed.
class _Keys {
  static const content = 'content';
  static const quizzes = 'quizzes';
  static String questions(String quizId) => 'questions:$quizId';
  static const leaderboard = 'leaderboard';
}

/// The real backend: JWT auth, Postgres persistence, WebSocket deltas.
///
/// Realtime is push-only. There is no polling anywhere in this file — the
/// previous implementation refetched every stream on every broadcast *and*
/// polled all of them every 5 seconds, which is ~2,500 requests per question
/// for a 50-student class. Live session state now arrives as deltas
/// (`session.state`, `participant.joined`, `answer.count`,
/// `question.revealed`, `scoreboard`, `session.ended`) and the only refetch is
/// one resync per session after a socket reconnect.
class RemoteBackend implements Backend {
  RemoteBackend({
    ApiClient? api,
    TokenStore? tokenStore,
    RealtimeClient? realtime,
    RealtimeSocketFactory? socketFactory,
  }) : api =
           api ??
           ApiClient(
             tokenStore: tokenStore ?? defaultTokenStore(),
             baseUrl: Env.apiRoot,
           ) {
    this.realtime =
        realtime ??
        RealtimeClient(api: this.api, socketFactory: socketFactory);
    hub = SessionHub(realtime: this.realtime);
    _auth = _RemoteAuth(this);
    _content = _RemoteContent(this);
    _quizzes = _RemoteQuizzes(this);
    _sessions = _RemoteSessions(this);
    _leaderboard = _RemoteLeaderboard(this);
    _analytics = _RemoteAnalytics(this);
    _generator = RemoteQuizGenerator(this.api);
  }

  final ApiClient api;
  late final RealtimeClient realtime;
  late final SessionHub hub;

  late final _RemoteAuth _auth;
  late final _RemoteContent _content;
  late final _RemoteQuizzes _quizzes;
  late final _RemoteSessions _sessions;
  late final _RemoteLeaderboard _leaderboard;
  late final _RemoteAnalytics _analytics;
  late final RemoteQuizGenerator _generator;

  final _localRefresh = StreamController<String>.broadcast();
  StreamSubscription<String>? _signOutSub;

  @override
  AuthRepository get auth => _auth;
  @override
  ContentRepository get content => _content;
  @override
  QuizRepository get quizzes => _quizzes;
  @override
  SessionRepository get sessions => _sessions;
  @override
  LeaderboardRepository get leaderboard => _leaderboard;
  @override
  AnalyticsRepository get analytics => _analytics;
  @override
  QuizGenerator get generator => _generator;

  @override
  String get generatorLabel => 'Server (${Env.aiProvider})';

  @override
  bool get isMultiDevice => true;

  @override
  Stream<ConnectionState> connectionState() => realtime.states();

  @override
  ServerClock get clock => realtime.clock;

  @override
  void resumeRealtime() => realtime.nudge();

  /// The server is the store of record; nothing bulky is kept in browser
  /// storage, so there are no quota failures to report.
  @override
  Stream<AppFailure> storageIssues() => const Stream.empty();

  @override
  Future<void> init() async {
    // A refresh that fails anywhere signs the session out exactly once.
    _signOutSub = api.onSignedOut.listen(_auth.onSessionLost);
    await _auth.restore();
  }

  @override
  Future<void> dispose() async {
    await _signOutSub?.cancel();
    await hub.dispose();
    await realtime.dispose();
    await _localRefresh.close();
    await api.dispose();
  }

  void invalidate(String key) {
    if (!_localRefresh.isClosed) _localRefresh.add(key);
  }

  /// Emits once immediately, then again when (a) this device changed something
  /// under one of [keys], or (b) the socket came back after a drop and the data
  /// may have moved on without us. No timers.
  Stream<T> watch<T>(List<String> keys, Future<T> Function() fetch) {
    late StreamController<T> ctrl;
    StreamSubscription<String>? refreshSub;
    StreamSubscription<ConnectionState>? connSub;
    var delivered = false;
    var wasDisconnected = false;

    Future<void> emit() async {
      try {
        final value = await fetch();
        if (ctrl.isClosed) return;
        delivered = true;
        ctrl.add(value);
      } on AppFailure catch (e, st) {
        // First load: the UI needs to know. Later: keep the last good value
        // rather than blanking the screen on a blip.
        if (!delivered && !ctrl.isClosed) ctrl.addError(e, st);
      }
    }

    ctrl = StreamController<T>(
      onListen: () {
        unawaited(emit());
        refreshSub = _localRefresh.stream.listen((key) {
          if (keys.any((k) => key == k || key.startsWith('$k:'))) {
            unawaited(emit());
          }
        });
        connSub = realtime.states().listen((state) {
          if (state != ConnectionState.connected) {
            wasDisconnected = true;
            return;
          }
          if (wasDisconnected) {
            wasDisconnected = false;
            unawaited(emit());
          }
        });
      },
      onCancel: () async {
        await refreshSub?.cancel();
        await connSub?.cancel();
      },
    );
    return ctrl.stream;
  }
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

class _RemoteAuth implements AuthRepository {
  _RemoteAuth(this._b);

  final RemoteBackend _b;
  final _ctrl = StreamController<AppUser?>.broadcast();
  AppUser? _current;

  @override
  Stream<AppUser?> authState() async* {
    yield _current;
    yield* _ctrl.stream;
  }

  @override
  AppUser? get currentUser => _current;

  /// Boot path: if a token pair survived, verify it with `GET /auth/me`.
  /// An expired access token is refreshed by the interceptor on that very
  /// call, so a returning user is not bounced to the sign-in screen.
  Future<void> restore() async {
    final tokens = await _b.api.restore();
    if (tokens == null) return;
    try {
      final res = await _b.api.getMap('/auth/me');
      _set(AppUser.fromJson(res['user'] as Map<String, dynamic>));
    } on AppFailure {
      // Refresh token revoked, expired, or the server was reset.
      await _b.api.clearTokens();
      _set(null);
    }
  }

  @override
  Future<AppUser> register({
    required String name,
    required String email,
    required String password,
    required UserRole role,
  }) async {
    final res = await _b.api.post(
      '/auth/register',
      authenticated: false,
      body: {
        'name': name,
        'email': email,
        'password': password,
        'role': role.name,
      },
    );
    return _adopt(res);
  }

  @override
  Future<AppUser> signIn({
    required String email,
    required String password,
  }) async {
    final res = await _b.api.post(
      '/auth/login',
      authenticated: false,
      body: {'email': email, 'password': password},
    );
    return _adopt(res);
  }

  /// Demo identities are real server accounts; the password is sent over the
  /// wire and bcrypted server-side, and is never stored on this device.
  @override
  Future<AppUser> demoSignIn(UserRole role) async {
    final educator = role == UserRole.educator;
    final email = educator ? 'ada@quizzle.dev' : 'sam@quizzle.dev';
    const password = 'password';
    try {
      return await signIn(email: email, password: password);
    } on AppFailure catch (e) {
      if (e.code != 'UNAUTHORIZED') rethrow;
      return register(
        name: educator ? 'Prof. Ada' : 'Sam',
        email: email,
        password: password,
        role: role,
      );
    }
  }

  @override
  Future<void> signOut() async {
    final refresh = _b.api.tokens?.refreshToken;
    try {
      // Revokes that refresh token server-side, so a stolen copy is useless.
      if (refresh != null) {
        await _b.api.post('/auth/logout', body: {'refreshToken': refresh});
      }
    } on AppFailure {
      // Offline sign-out still has to work locally.
    }
    await _b.api.forgetSession();
    _set(null);
  }

  @override
  Future<AppUser> updateProfile({String? name}) async {
    final res = await _b.api.patch('/auth/me', body: {'name': name});
    final user = AppUser.fromJson(res['user'] as Map<String, dynamic>);
    _set(user);
    return user;
  }

  /// The interceptor could not refresh: the session is gone.
  void onSessionLost(String reason) {
    if (_current == null) return;
    _set(null);
  }

  Future<AppUser> _adopt(Map<String, dynamic> res) async {
    final access = res['accessToken'] as String?;
    final refresh = res['refreshToken'] as String?;
    if (access == null || refresh == null) {
      throw const AppFailure(
        'The server did not return a session token.',
        code: 'UPSTREAM',
      );
    }
    await _b.api.setTokens(
      AuthTokens(accessToken: access, refreshToken: refresh),
    );
    final user = AppUser.fromJson(res['user'] as Map<String, dynamic>);
    _set(user);
    return user;
  }

  void _set(AppUser? user) {
    _current = user;
    if (!_ctrl.isClosed) _ctrl.add(user);
    // The socket authenticates with the access token in the query string, so
    // it has to be reopened whenever the identity changes.
    if (user == null) {
      unawaited(_b.realtime.stop());
    } else {
      _b.realtime.start();
      _b.realtime.restart();
    }
  }
}

// ---------------------------------------------------------------------------
// Content
// ---------------------------------------------------------------------------

class _RemoteContent implements ContentRepository {
  _RemoteContent(this._b);
  final RemoteBackend _b;

  @override
  Stream<List<ContentItem>> watchLibrary(String ownerId) =>
      _b.watch([_Keys.content], () async {
        // Owner scoping is server-side, from the JWT.
        final rows = await _b.api.getList('/content');
        return [
          for (final r in rows) ContentItem.fromJson(r as Map<String, dynamic>),
        ];
      });

  @override
  Future<ContentItem> get(String id) async =>
      ContentItem.fromJson(await _b.api.getMap('/content/$id'));

  @override
  Future<ContentItem> ingest({
    String? ownerId,
    required String title,
    String? subject,
    required ContentType sourceType,
    required String rawText,
    int pageCount = 1,
    String? fileName,
  }) async {
    final res = await _b.api.post(
      '/content',
      body: {
        'title': title,
        'subject': subject,
        'source_type': sourceType.name,
        'raw_text': rawText,
        'file_name': fileName,
      },
    );
    _b.invalidate(_Keys.content);
    return ContentItem.fromJson(res);
  }

  @override
  Future<ContentItem> upload({
    required String fileName,
    required Uint8List bytes,
    String? title,
    String? subject,
  }) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: fileName),
      if (title != null && title.isNotEmpty) 'title': title,
      if (subject != null && subject.isNotEmpty) 'subject': subject,
    });
    final res = await _b.api.postMultipart('/content/upload', form);
    _b.invalidate(_Keys.content);
    return ContentItem.fromJson(res);
  }

  @override
  Future<ExtractedContent> extractFile({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: fileName),
    });
    final res = await _b.api.postMultipart('/content/extract', form);
    return ExtractedContent.fromJson(res);
  }

  @override
  Future<void> delete(String id) async {
    await _b.api.delete('/content/$id');
    _b.invalidate(_Keys.content);
  }
}

// ---------------------------------------------------------------------------
// Quizzes + questions
// ---------------------------------------------------------------------------

class _RemoteQuizzes implements QuizRepository {
  _RemoteQuizzes(this._b);
  final RemoteBackend _b;

  List<Question> _questions(List<dynamic> rows) =>
      [for (final r in rows) Question.fromJson(r as Map<String, dynamic>)]
        ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));

  @override
  Stream<List<Quiz>> watchQuizzes(String ownerId) =>
      _b.watch([_Keys.quizzes], () async {
        final rows = await _b.api.getList('/quizzes');
        return [for (final r in rows) Quiz.fromJson(r as Map<String, dynamic>)];
      });

  @override
  Stream<Quiz?> watchQuiz(String quizId) =>
      _b.watch<Quiz?>([_Keys.quizzes], () async {
        try {
          return Quiz.fromJson(await _b.api.getMap('/quizzes/$quizId'));
        } on AppFailure catch (e) {
          if (e.isNotFound) return null;
          rethrow;
        }
      });

  @override
  Stream<List<Question>> watchQuestions(String quizId) =>
      _b.watch([_Keys.questions(quizId), _Keys.quizzes], () async {
        return _questions(await _b.api.getList('/quizzes/$quizId/questions'));
      });

  @override
  Future<Quiz> get(String quizId) async =>
      Quiz.fromJson(await _b.api.getMap('/quizzes/$quizId'));

  @override
  Future<List<Question>> questionsOnce(String quizId) async =>
      _questions(await _b.api.getList('/quizzes/$quizId/questions'));

  @override
  Future<Quiz> createDraft({
    String? ownerId,
    required String title,
    String? subject,
    String? contentItemId,
  }) async {
    final res = await _b.api.post(
      '/quizzes',
      body: {
        'title': title,
        'subject': subject,
        'content_id': ?contentItemId,
      },
    );
    _b.invalidate(_Keys.quizzes);
    return Quiz.fromJson(res);
  }

  @override
  Future<void> saveQuiz(Quiz quiz) async {
    await _b.api.patch(
      '/quizzes/${quiz.id}',
      body: {
        'title': quiz.title,
        'subject': quiz.subject,
        'description': quiz.description,
        'scoring': quiz.scoring.toJson(),
      },
    );
    _b.invalidate(_Keys.quizzes);
  }

  @override
  Future<void> publish(String quizId) async {
    await _b.api.post('/quizzes/$quizId/publish');
    _b.invalidate(_Keys.quizzes);
  }

  @override
  Future<void> unpublish(String quizId) async {
    await _b.api.post('/quizzes/$quizId/unpublish');
    _b.invalidate(_Keys.quizzes);
  }

  @override
  Future<void> deleteQuiz(String quizId) async {
    await _b.api.delete('/quizzes/$quizId');
    _b.invalidate(_Keys.quizzes);
  }

  @override
  Future<void> addQuestions(String quizId, List<Question> questions) async {
    if (questions.isEmpty) return;
    await _b.api.post(
      '/quizzes/$quizId/questions',
      // Ids are never sent: the server assigns them and owns order_index.
      body: {'questions': [for (final q in questions) q.toPayload()]},
    );
    _b.invalidate(_Keys.questions(quizId));
    _b.invalidate(_Keys.quizzes);
  }

  @override
  Future<void> saveQuestion(Question question) async {
    try {
      await replaceQuestion(question.id, question);
      return;
    } on AppFailure catch (e) {
      if (!e.isNotFound) rethrow;
    }
    // The id is unknown to the server — a regenerated question carrying a
    // client-side id, which is exactly how the old build appended a duplicate.
    // Replace the row that holds this order_index instead.
    final existing = await questionsOnce(question.quizId);
    final target = existing.firstWhere(
      (q) => q.orderIndex == question.orderIndex,
      orElse: () => throw AppFailure(
        'That question is no longer part of this quiz.',
        code: 'NOT_FOUND',
        status: 404,
      ),
    );
    await replaceQuestion(target.id, question);
  }

  @override
  Future<Question> replaceQuestion(
    String questionId,
    Question replacement,
  ) async {
    if (questionId.isEmpty) {
      throw const AppFailure(
        'Cannot replace a question without an id.',
        code: 'VALIDATION',
      );
    }
    final res = await _b.api.put(
      '/questions/$questionId',
      body: replacement.toPayload(),
    );
    final saved = Question.fromJson(res);
    _b.invalidate(_Keys.questions(saved.quizId));
    _b.invalidate(_Keys.quizzes);
    return saved;
  }

  @override
  Future<void> deleteQuestion(String quizId, String questionId) async {
    await _b.api.delete('/questions/$questionId');
    _b.invalidate(_Keys.questions(quizId));
    _b.invalidate(_Keys.quizzes);
  }

  @override
  Future<void> reorderQuestions(String quizId, List<String> orderedIds) async {
    await _b.api.post(
      '/quizzes/$quizId/questions/reorder',
      body: {'ordered_ids': orderedIds},
    );
    _b.invalidate(_Keys.questions(quizId));
  }

  @override
  Future<List<Quiz>> publishedQuizzes() async {
    final rows = await _b.api.getList('/quizzes/published');
    return [for (final r in rows) Quiz.fromJson(r as Map<String, dynamic>)];
  }

  @override
  Future<PracticeGrade> gradePractice({
    required String quizId,
    required String questionId,
    required int selectedIndex,
  }) async => PracticeGrade.fromJson(
    await _b.api.post(
      '/quizzes/$quizId/practice/answer',
      body: {'question_id': questionId, 'selected_index': selectedIndex},
    ),
  );
}

// ---------------------------------------------------------------------------
// Live sessions
// ---------------------------------------------------------------------------

class _RemoteSessions implements SessionRepository {
  _RemoteSessions(this._b);
  final RemoteBackend _b;

  SessionChannel _channel(String sessionId) => _b.hub.channel(
    sessionId,
    fetchSession: () async {
      try {
        return QuizSession.fromJson(
          await _b.api.getMap('/sessions/$sessionId'),
        );
      } on AppFailure catch (e) {
        if (e.isNotFound) return null;
        rethrow;
      }
    },
    fetchParticipants: () async {
      final rows = await _b.api.getList('/sessions/$sessionId/participants');
      return [
        for (final r in rows)
          SessionParticipant.fromJson(r as Map<String, dynamic>),
      ];
    },
    fetchResponses: () async {
      final rows = await _b.api.getList('/sessions/$sessionId/responses');
      return [
        for (final r in rows) QuizResponse.fromJson(r as Map<String, dynamic>),
      ];
    },
    fetchReveal: (index) async {
      final res = await _b.api.getMap(
        '/sessions/$sessionId/current-question',
        query: {'index': index},
      );
      final q = res['question'];
      if (res['revealed'] != true || q is! Map) return null;
      final question = q.cast<String, dynamic>();
      final mine = res['my_response'];
      return (
        reveal: RevealInfo.fromJson({
          'question_index': index,
          'correct_index': question['correct_index'],
          'explanation': question['explanation'],
          'distribution': res['distribution'],
        }),
        mine: mine is Map
            ? AnswerResult.fromJson(mine.cast<String, dynamic>())
            : null,
      );
    },
  );

  @override
  Future<QuizSession> createSession({
    required Quiz quiz,
    String? hostId,
    List<Question> questions = const [],
  }) async {
    final res = await _b.api.post('/sessions', body: {'quiz_id': quiz.id});
    final session = QuizSession.fromJson(res);
    _channel(session.id).setSession(session);
    return session;
  }

  @override
  Stream<QuizSession?> watchSession(String sessionId) =>
      _channel(sessionId).session();

  @override
  Stream<List<SessionParticipant>> watchParticipants(String sessionId) =>
      _channel(sessionId).participants();

  @override
  Stream<List<QuizResponse>> watchResponses(String sessionId) =>
      _channel(sessionId).responses();

  @override
  Stream<({int answered, int total})> watchAnswerCount(String sessionId) =>
      _channel(sessionId).answerCount();

  @override
  Stream<RevealInfo?> watchReveal(String sessionId) =>
      _channel(sessionId).reveals();

  @override
  Stream<Map<int, AnswerResult>> watchMyResults(String sessionId) =>
      _channel(sessionId).myResults();

  /// `GET /sessions/by-code/:code` deliberately returns four fields only — a
  /// join code must not expose the roster — so this is a partial session
  /// carrying the id the join screen needs.
  @override
  Future<QuizSession?> findByJoinCode(String code) async {
    try {
      final res = await _b.api.getMap('/sessions/by-code/$code');
      final id = res['id'] as String?;
      if (id == null) return null;
      return QuizSession(
        id: id,
        quizId: '',
        quizTitle: (res['quiz_title'] as String?) ?? 'Quiz',
        hostId: '',
        joinCode: code.toUpperCase(),
        status: enumFromName(
          SessionStatus.values,
          res['status'] as String?,
          SessionStatus.lobby,
        ),
        totalQuestions: ((res['question_count'] ?? 0) as num).toInt(),
        createdAt: DateTime.now(),
      );
    } on AppFailure catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  @override
  Future<List<Question>> sessionQuestions(String sessionId) async {
    final rows = await _b.api.getList('/sessions/$sessionId/questions');
    return [for (final r in rows) Question.fromJson(r as Map<String, dynamic>)]
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  }

  @override
  Future<Question?> publicQuestionAt(String sessionId, int index) async {
    try {
      final res = await _b.api.getMap(
        '/sessions/$sessionId/current-question',
        query: {'index': index},
      );
      final q = res['question'];
      if (q is! Map) return null;
      return Question.fromJson(q.cast<String, dynamic>());
    } on AppFailure catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  @override
  Future<SessionParticipant> joinSession({
    required String joinCode,
    AppUser? student,
  }) async {
    // No identity in the body: the server enrols the token's user.
    final res = await _b.api.post(
      '/sessions/join',
      body: {'join_code': joinCode},
    );
    final participant = SessionParticipant.fromJson(res);
    final sessionJson = res['session'];
    if (sessionJson is Map) {
      final session = QuizSession.fromJson(sessionJson.cast<String, dynamic>());
      _channel(session.id).setSession(session);
    }
    // Merge locally so the roster is right without a refetch.
    _b.hub.existing(participant.sessionId)?.mergeParticipant(participant);
    return participant;
  }

  @override
  Future<void> setConnected({
    required String sessionId,
    String? studentId,
    required bool connected,
  }) async {
    try {
      await _b.api.post(
        '/sessions/$sessionId/connected',
        body: {'connected': connected},
      );
    } on AppFailure catch (e) {
      // Leaving a session you are not in is not an error worth showing.
      if (!e.isNotFound) rethrow;
    }
  }

  @override
  Future<void> startSession(String sessionId) =>
      _control(sessionId, 'start');

  @override
  Future<void> revealAnswer(String sessionId) =>
      _control(sessionId, 'reveal');

  @override
  Future<void> nextQuestion(String sessionId) => _control(sessionId, 'next');

  @override
  Future<void> endSession(String sessionId) => _control(sessionId, 'end');

  /// Host controls return the new session state. Applying it locally keeps the
  /// host's own UI instant even if their socket is mid-reconnect; every other
  /// device gets the same state as a `session.state` delta.
  Future<void> _control(String sessionId, String action) async {
    final res = await _b.api.post('/sessions/$sessionId/$action');
    if (res.isNotEmpty && res['id'] != null) {
      _b.hub.existing(sessionId)?.setSession(QuizSession.fromJson(res));
    }
    if (action == 'end') _b.invalidate(_Keys.leaderboard);
  }

  @override
  Future<QuizResponse> submitAnswer({
    required String sessionId,
    AppUser? student,
    required int questionIndex,
    required int selectedIndex,
    int responseTimeMs = 0,
  }) async {
    // `response_time_ms` is intentionally absent: the server times the answer
    // against question_started_at. Sending it would be ignored anyway.
    final res = await _b.api.post(
      '/sessions/$sessionId/answer',
      body: {'selected_index': selectedIndex, 'question_index': questionIndex},
    );
    return QuizResponse.fromJson(res);
  }
}

// ---------------------------------------------------------------------------
// Leaderboard
// ---------------------------------------------------------------------------

class _RemoteLeaderboard implements LeaderboardRepository {
  _RemoteLeaderboard(this._b);
  final RemoteBackend _b;

  /// `period` and `subject` are passed through and really filter now (SQL
  /// WHERE clauses over `responses`), so the UI's week / all-time toggle and
  /// its subject picker are live controls again.
  @override
  Stream<List<LeaderboardEntry>> watchGlobal({
    String period = 'all-time',
    String? subject,
  }) => _b.watch([_Keys.leaderboard], () async {
    final rows = await _b.api.getList(
      '/leaderboard/global',
      query: {'period': period, 'subject': subject},
    );
    return [
      for (final r in rows) LeaderboardEntry.fromJson(r as Map<String, dynamic>),
    ];
  });

  @override
  Future<List<String>> subjects() async {
    final rows = await _b.api.getList('/leaderboard/subjects');
    return [for (final r in rows) r.toString()];
  }
}

// ---------------------------------------------------------------------------
// Analytics
// ---------------------------------------------------------------------------

class _RemoteAnalytics implements AnalyticsRepository {
  _RemoteAnalytics(this._b);
  final RemoteBackend _b;

  @override
  Future<QuizAnalytics> quizAnalytics(String quizId) async {
    final j = await _b.api.getMap('/analytics/quiz/$quizId');
    return QuizAnalytics(
      quizId: quizId,
      sessionsRun: ((j['sessions_run'] ?? 0) as num).toInt(),
      participants: ((j['participants'] ?? 0) as num).toInt(),
      averageScore: ((j['average_score'] ?? 0) as num).toDouble(),
      averageCorrectRate: ((j['average_correct_rate'] ?? 0) as num).toDouble(),
      completionRate: ((j['completion_rate'] ?? 0) as num).toDouble(),
      questionStats: [
        for (final e in (j['question_stats'] as List? ?? const []))
          QuestionStat(
            questionId: (e['question_id'] ?? '') as String,
            text: (e['text'] ?? '') as String,
            answers: ((e['answers'] ?? 0) as num).toInt(),
            correct: ((e['correct'] ?? 0) as num).toInt(),
            orderIndex: ((e['order_index'] ?? 0) as num).toInt(),
            averageTimeMs: ((e['average_time_ms'] ?? 0) as num).toInt(),
          ),
      ],
    );
  }

  @override
  Future<List<StudentQuizResult>> studentHistory(String studentId) async {
    final rows = await _b.api.getList('/analytics/student/$studentId');
    return [
      for (final e in rows)
        StudentQuizResult(
          sessionId: (e['session_id'] ?? '') as String,
          quizTitle: (e['quiz_title'] ?? 'Quiz') as String,
          score: ((e['score'] ?? 0) as num).toInt(),
          rank: ((e['rank'] ?? 0) as num).toInt(),
          playedAt:
              DateTime.tryParse(e['played_at'] as String? ?? '') ??
              DateTime.now(),
          correct: ((e['correct'] ?? 0) as num).toInt(),
          total: ((e['total'] ?? 0) as num).toInt(),
        ),
    ];
  }
}
