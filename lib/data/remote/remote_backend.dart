import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/env.dart';
import '../../core/failure.dart';
import '../../models/content_item.dart';
import '../../models/enums.dart';
import '../../models/leaderboard_entry.dart';
import '../../models/question.dart';
import '../../models/quiz.dart';
import '../../models/quiz_session.dart';
import '../../models/response.dart';
import '../../models/session_participant.dart';
import '../../models/user.dart';
import '../repositories.dart';

/// Talks to the bundled Node backend (see `backend/`). Live updates arrive on a
/// single WebSocket that pushes `{channel: "..."}` messages; the client
/// re-fetches the matching REST snapshot, mirroring the in-memory event bus so
/// the UI code is identical for both backends.
class RemoteBackend implements Backend {
  RemoteBackend({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: Env.apiBase,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              headers: {'content-type': 'application/json'},
            ),
          ) {
    _auth = _RemoteAuth(this);
    _content = _RemoteContent(this);
    _quizzes = _RemoteQuizzes(this);
    _sessions = _RemoteSessions(this);
    _leaderboard = _RemoteLeaderboard(this);
    _analytics = _RemoteAnalytics(this);
  }

  final Dio _dio;
  String? _token;

  final _events = StreamController<String>.broadcast();
  WebSocketChannel? _ws;
  Timer? _reconnect;

  late final _RemoteAuth _auth;
  late final _RemoteContent _content;
  late final _RemoteQuizzes _quizzes;
  late final _RemoteSessions _sessions;
  late final _RemoteLeaderboard _leaderboard;
  late final _RemoteAnalytics _analytics;

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
  Future<void> init() async {
    _connectWs();
  }

  void _connectWs() {
    try {
      final base = Env.apiBase
          .replaceFirst('http://', 'ws://')
          .replaceFirst('https://', 'wss://');
      final wsUrl = '$base/ws';
      _ws = WebSocketChannel.connect(Uri.parse(wsUrl));
      _ws!.stream.listen(
        (data) {
          try {
            final msg = jsonDecode(data as String) as Map<String, dynamic>;
            final ch = msg['channel'];
            if (ch is String) _events.add(ch);
          } catch (_) {}
        },
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 2), _connectWs);
  }

  /// Emits an initial snapshot, then re-fetches whenever a matching channel
  /// event arrives. Also polls slowly as a safety net if the socket is down.
  Stream<T> _watch<T>(List<String> channels, Future<T> Function() fetch) {
    late StreamController<T> ctrl;
    StreamSubscription<String>? sub;
    Timer? poll;
    Future<void> emit() async {
      try {
        ctrl.add(await fetch());
      } catch (_) {
        /* keep last good value */
      }
    }

    ctrl = StreamController<T>(
      onListen: () {
        emit();
        sub = _events.stream.listen((c) {
          if (channels.any((p) => c == p || c.startsWith('$p:'))) emit();
        });
        poll = Timer.periodic(const Duration(seconds: 5), (_) => emit());
      },
      onCancel: () {
        sub?.cancel();
        poll?.cancel();
      },
    );
    return ctrl.stream;
  }

  Options get _authOpts => Options(
    headers: _token == null ? null : {'authorization': 'Bearer $_token'},
  );

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final r = await _dio.get<dynamic>(
        path,
        queryParameters: query,
        options: _authOpts,
      );
      return _asMap(r.data);
    } on DioException catch (e) {
      throw _fail(e);
    }
  }

  Future<List<dynamic>> _getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final r = await _dio.get<dynamic>(
        path,
        queryParameters: query,
        options: _authOpts,
      );
      final data = r.data;
      if (data is List) return data;
      if (data is Map && data['items'] is List) return data['items'] as List;
      return const [];
    } on DioException catch (e) {
      throw _fail(e);
    }
  }

  Future<Map<String, dynamic>> _post(String path, [Object? body]) async {
    try {
      final r = await _dio.post<dynamic>(path, data: body, options: _authOpts);
      return _asMap(r.data);
    } on DioException catch (e) {
      throw _fail(e);
    }
  }

  Future<Map<String, dynamic>> _put(String path, [Object? body]) async {
    try {
      final r = await _dio.put<dynamic>(path, data: body, options: _authOpts);
      return _asMap(r.data);
    } on DioException catch (e) {
      throw _fail(e);
    }
  }

  Future<void> _delete(String path, {Map<String, dynamic>? query}) async {
    try {
      await _dio.delete<dynamic>(
        path,
        queryParameters: query,
        options: _authOpts,
      );
    } on DioException catch (e) {
      throw _fail(e);
    }
  }

  Map<String, dynamic> _asMap(Object? data) =>
      data is Map<String, dynamic> ? data : <String, dynamic>{};

  AppFailure _fail(DioException e) {
    final msg = e.response?.data;
    if (msg is Map && msg['error'] is String) {
      return AppFailure(msg['error'] as String, cause: e);
    }
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout) {
      return AppFailure('Cannot reach the server at ${Env.apiBase}.', cause: e);
    }
    return AppFailure(
      'Request failed (${e.response?.statusCode ?? '?'}).',
      cause: e,
    );
  }
}

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

  void _set(AppUser? u, [String? token]) {
    _current = u;
    _b._token = token ?? _b._token;
    if (u == null) _b._token = null;
    _ctrl.add(u);
  }

  @override
  Future<AppUser> register({
    required String name,
    required String email,
    required String password,
    required UserRole role,
  }) async {
    final r = await _b._post('/auth/register', {
      'name': name,
      'email': email,
      'password': password,
      'role': role.name,
    });
    final user = AppUser.fromJson(r['user'] as Map<String, dynamic>);
    _set(user, r['token'] as String?);
    return user;
  }

  @override
  Future<AppUser> signIn({
    required String email,
    required String password,
  }) async {
    final r = await _b._post('/auth/login', {
      'email': email,
      'password': password,
    });
    final user = AppUser.fromJson(r['user'] as Map<String, dynamic>);
    _set(user, r['token'] as String?);
    return user;
  }

  @override
  Future<void> signOut() async {
    try {
      await _b._post('/auth/logout');
    } catch (_) {}
    _set(null);
  }

  @override
  Future<AppUser> updateProfile({String? name}) async {
    final r = await _b._put('/auth/profile', {'name': name});
    final user = AppUser.fromJson(r['user'] as Map<String, dynamic>);
    _set(user);
    return user;
  }
}

class _RemoteContent implements ContentRepository {
  _RemoteContent(this._b);
  final RemoteBackend _b;

  @override
  Stream<List<ContentItem>> watchLibrary(String ownerId) =>
      _b._watch(['content'], () async {
        final l = await _b._getList('/content', query: {'owner_id': ownerId});
        return l
            .map((e) => ContentItem.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  @override
  Future<ContentItem> get(String id) async =>
      ContentItem.fromJson(await _b._get('/content/$id'));

  @override
  Future<ContentItem> ingest({
    required String ownerId,
    required String title,
    String? subject,
    required ContentType sourceType,
    required String rawText,
    int pageCount = 1,
    String? fileName,
  }) async {
    final r = await _b._post('/content', {
      'owner_id': ownerId,
      'title': title,
      'subject': subject,
      'source_type': sourceType.name,
      'raw_text': rawText,
      'page_count': pageCount,
      'file_name': fileName,
    });
    return ContentItem.fromJson(r);
  }

  @override
  Future<void> delete(String id) => _b._delete('/content/$id');
}

class _RemoteQuizzes implements QuizRepository {
  _RemoteQuizzes(this._b);
  final RemoteBackend _b;

  List<Question> _questions(List<dynamic> l) =>
      l.map((e) => Question.fromJson(e as Map<String, dynamic>)).toList()
        ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));

  @override
  Stream<List<Quiz>> watchQuizzes(String ownerId) =>
      _b._watch(['quizzes'], () async {
        final l = await _b._getList('/quizzes', query: {'owner_id': ownerId});
        return l.map((e) => Quiz.fromJson(e as Map<String, dynamic>)).toList();
      });

  @override
  Stream<Quiz?> watchQuiz(String quizId) => _b._watch(['quizzes'], () async {
    try {
      return Quiz.fromJson(await _b._get('/quizzes/$quizId'));
    } catch (_) {
      return null;
    }
  });

  @override
  Stream<List<Question>> watchQuestions(String quizId) =>
      _b._watch(['questions:$quizId', 'quizzes'], () async {
        return _questions(await _b._getList('/quizzes/$quizId/questions'));
      });

  @override
  Future<Quiz> get(String quizId) async =>
      Quiz.fromJson(await _b._get('/quizzes/$quizId'));

  @override
  Future<List<Question>> questionsOnce(String quizId) async =>
      _questions(await _b._getList('/quizzes/$quizId/questions'));

  @override
  Future<Quiz> createDraft({
    required String ownerId,
    required String title,
    String? subject,
    String? contentItemId,
  }) async {
    final r = await _b._post('/quizzes', {
      'owner_id': ownerId,
      'title': title,
      'subject': subject,
      'content_item_id': contentItemId,
    });
    return Quiz.fromJson(r);
  }

  @override
  Future<void> saveQuiz(Quiz quiz) =>
      _b._put('/quizzes/${quiz.id}', quiz.toJson());

  @override
  Future<void> publish(String quizId) => _b._post('/quizzes/$quizId/publish');

  @override
  Future<void> unpublish(String quizId) =>
      _b._post('/quizzes/$quizId/unpublish');

  @override
  Future<void> deleteQuiz(String quizId) => _b._delete('/quizzes/$quizId');

  @override
  Future<void> addQuestions(String quizId, List<Question> questions) =>
      _b._post('/quizzes/$quizId/questions', {
        'questions': questions.map((q) => q.toJson()).toList(),
      });

  @override
  Future<void> saveQuestion(Question question) =>
      _b._put('/questions/${question.id}', question.toJson());

  @override
  Future<void> deleteQuestion(String quizId, String questionId) =>
      _b._delete('/questions/$questionId', query: {'quiz_id': quizId});

  @override
  Future<void> reorderQuestions(String quizId, List<String> orderedIds) => _b
      ._post('/quizzes/$quizId/questions/reorder', {'ordered_ids': orderedIds});

  @override
  Future<List<Quiz>> publishedQuizzes() async {
    final l = await _b._getList('/quizzes/published');
    return l.map((e) => Quiz.fromJson(e as Map<String, dynamic>)).toList();
  }
}

class _RemoteSessions implements SessionRepository {
  _RemoteSessions(this._b);
  final RemoteBackend _b;

  @override
  Future<QuizSession> createSession({
    required Quiz quiz,
    required String hostId,
    required List<Question> questions,
  }) async {
    final r = await _b._post('/sessions', {
      'quiz_id': quiz.id,
      'host_id': hostId,
    });
    return QuizSession.fromJson(r);
  }

  @override
  Stream<QuizSession?> watchSession(String sessionId) =>
      _b._watch(['session:$sessionId'], () async {
        try {
          return QuizSession.fromJson(await _b._get('/sessions/$sessionId'));
        } catch (_) {
          return null;
        }
      });

  @override
  Stream<List<SessionParticipant>> watchParticipants(String sessionId) =>
      _b._watch(['session:$sessionId'], () async {
        final l = await _b._getList('/sessions/$sessionId/participants');
        return l
            .map((e) => SessionParticipant.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  @override
  Stream<List<QuizResponse>> watchResponses(String sessionId) =>
      _b._watch(['session:$sessionId'], () async {
        final l = await _b._getList('/sessions/$sessionId/responses');
        return l
            .map((e) => QuizResponse.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  @override
  Future<QuizSession?> findByJoinCode(String code) async {
    try {
      return QuizSession.fromJson(await _b._get('/sessions/by-code/$code'));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Question>> sessionQuestions(String sessionId) async {
    final l = await _b._getList('/sessions/$sessionId/questions');
    return l.map((e) => Question.fromJson(e as Map<String, dynamic>)).toList()
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  }

  @override
  Future<Question?> publicQuestionAt(String sessionId, int index) async {
    try {
      return Question.fromJson(
        await _b._get('/sessions/$sessionId/questions/$index/public'),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<SessionParticipant> joinSession({
    required String joinCode,
    required AppUser student,
  }) async {
    final r = await _b._post('/sessions/join', {
      'join_code': joinCode,
      'student': {'id': student.id, 'name': student.name},
    });
    return SessionParticipant.fromJson(r);
  }

  @override
  Future<void> setConnected({
    required String sessionId,
    required String studentId,
    required bool connected,
  }) => _b._post('/sessions/$sessionId/connected', {
    'student_id': studentId,
    'connected': connected,
  });

  @override
  Future<void> startSession(String sessionId) =>
      _b._post('/sessions/$sessionId/start');

  @override
  Future<void> revealAnswer(String sessionId) =>
      _b._post('/sessions/$sessionId/reveal');

  @override
  Future<void> nextQuestion(String sessionId) =>
      _b._post('/sessions/$sessionId/next');

  @override
  Future<void> endSession(String sessionId) =>
      _b._post('/sessions/$sessionId/end');

  @override
  Future<QuizResponse> submitAnswer({
    required String sessionId,
    required AppUser student,
    required int questionIndex,
    required int selectedIndex,
    required int responseTimeMs,
  }) async {
    final r = await _b._post('/sessions/$sessionId/answer', {
      'student_id': student.id,
      'student_name': student.name,
      'question_index': questionIndex,
      'selected_index': selectedIndex,
      'response_time_ms': responseTimeMs,
    });
    return QuizResponse.fromJson(r);
  }
}

class _RemoteLeaderboard implements LeaderboardRepository {
  _RemoteLeaderboard(this._b);
  final RemoteBackend _b;

  @override
  Stream<List<LeaderboardEntry>> watchGlobal({
    String period = 'all-time',
    String? subject,
  }) => _b._watch(['leaderboard'], () async {
    final l = await _b._getList(
      '/leaderboard/global',
      query: {
        'period': period,
        // ignore: use_null_aware_elements
        if (subject != null) 'subject': subject,
      },
    );
    return l
        .map((e) => LeaderboardEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  });
}

class _RemoteAnalytics implements AnalyticsRepository {
  _RemoteAnalytics(this._b);
  final RemoteBackend _b;

  @override
  Future<QuizAnalytics> quizAnalytics(String quizId) async {
    final j = await _b._get('/analytics/quiz/$quizId');
    return QuizAnalytics(
      quizId: quizId,
      sessionsRun: (j['sessions_run'] ?? 0) as int,
      participants: (j['participants'] ?? 0) as int,
      averageScore: ((j['average_score'] ?? 0) as num).toDouble(),
      averageCorrectRate: ((j['average_correct_rate'] ?? 0) as num).toDouble(),
      completionRate: ((j['completion_rate'] ?? 0) as num).toDouble(),
      questionStats: ((j['question_stats'] as List?) ?? const [])
          .map(
            (e) => QuestionStat(
              questionId: (e['question_id'] ?? '') as String,
              text: (e['text'] ?? '') as String,
              answers: (e['answers'] ?? 0) as int,
              correct: (e['correct'] ?? 0) as int,
              orderIndex: (e['order_index'] ?? 0) as int,
            ),
          )
          .toList(),
    );
  }

  @override
  Future<List<StudentQuizResult>> studentHistory(String studentId) async {
    final l = await _b._getList('/analytics/student/$studentId');
    return l
        .map(
          (e) => StudentQuizResult(
            sessionId: (e['session_id'] ?? '') as String,
            quizTitle: (e['quiz_title'] ?? 'Quiz') as String,
            score: (e['score'] ?? 0) as int,
            rank: (e['rank'] ?? 0) as int,
            playedAt:
                DateTime.tryParse(e['played_at'] as String? ?? '') ??
                DateTime.now(),
            correct: (e['correct'] ?? 0) as int,
            total: (e['total'] ?? 0) as int,
          ),
        )
        .toList();
  }
}
