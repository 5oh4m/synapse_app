import 'dart:async';

import '../../core/failure.dart';
import '../../core/ids.dart';
import '../../models/content_item.dart';
import '../../models/enums.dart';
import '../../models/leaderboard_entry.dart';
import '../../models/question.dart';
import '../../models/quiz.dart';
import '../../models/quiz_session.dart';
import '../../models/response.dart';
import '../../models/scoring.dart';
import '../../models/session_participant.dart';
import '../../models/user.dart';
import '../repositories.dart';

/// Zero-setup backend: everything lives in memory in one isolate. Perfect for
/// running the full flow on one device and for tests. Live sessions only sync
/// between host and students inside the *same* running app instance — use the
/// `remote` backend (bundled Node server) for real multi-device play.
class InMemoryBackend implements Backend {
  InMemoryBackend() {
    _auth = _Auth(_db);
    _content = _Content(_db);
    _quizzes = _Quizzes(_db);
    _sessions = _Sessions(_db);
    _leaderboard = _Leaderboard(_db);
    _analytics = _Analytics(_db);
  }

  final _Db _db = _Db();
  late final _Auth _auth;
  late final _Content _content;
  late final _Quizzes _quizzes;
  late final _Sessions _sessions;
  late final _Leaderboard _leaderboard;
  late final _Analytics _analytics;

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
  Future<void> init() async => _db.seedDemo();
}

// ---------------------------------------------------------------------------
// Shared store
// ---------------------------------------------------------------------------

class _Db {
  final Map<String, AppUser> users = {};
  final Map<String, String> passwords = {}; // email -> password (mock only)
  AppUser? currentUser;

  final Map<String, ContentItem> content = {};
  final Map<String, Quiz> quizzes = {};
  final Map<String, Question> questions = {};
  final Map<String, QuizSession> sessions = {};
  final Map<String, SessionParticipant> participants = {};
  final Map<String, QuizResponse> responses = {};

  /// studentId -> cumulative record
  final Map<String, _Cum> cumulative = {};

  final _authCtrl = StreamController<AppUser?>.broadcast();
  final _bus = StreamController<String>.broadcast();

  Stream<AppUser?> get authStream => _authCtrl.stream;

  void setUser(AppUser? u) {
    currentUser = u;
    _authCtrl.add(u);
  }

  void ping(String channel) => _bus.add(channel);

  /// Emits [snapshot()] now, then again on every ping whose channel starts with
  /// one of [channels].
  Stream<T> watch<T>(List<String> channels, T Function() snapshot) {
    late StreamController<T> ctrl;
    StreamSubscription<String>? sub;
    ctrl = StreamController<T>(
      onListen: () {
        ctrl.add(snapshot());
        sub = _bus.stream.listen((c) {
          if (channels.any((p) => c == p || c.startsWith('$p:'))) {
            ctrl.add(snapshot());
          }
        });
      },
      onCancel: () => sub?.cancel(),
    );
    return ctrl.stream;
  }

  bool seeded = false;
  void seedDemo() {
    if (seeded) return;
    seeded = true;
    final now = DateTime.now();

    final ada = AppUser(
      id: 'u-ada',
      name: 'Prof. Ada',
      email: 'ada@quizzle.dev',
      role: UserRole.educator,
      createdAt: now,
    );
    final sam = AppUser(
      id: 'u-sam',
      name: 'Sam',
      email: 'sam@quizzle.dev',
      role: UserRole.student,
      createdAt: now,
    );
    final rio = AppUser(
      id: 'u-rio',
      name: 'Rio',
      email: 'rio@quizzle.dev',
      role: UserRole.student,
      createdAt: now,
    );
    for (final u in [ada, sam, rio]) {
      users[u.id] = u;
      passwords[u.email] = 'password';
    }

    final content0 = ContentItem(
      id: 'c-cell',
      ownerId: ada.id,
      title: 'Lecture 3 — The Cell',
      subject: 'Biology',
      fileType: ContentType.pdf,
      status: ContentStatus.ready,
      extractedText:
          'The cell is the basic structural and functional unit of life. '
          'Prokaryotic cells lack a membrane-bound nucleus, while eukaryotic '
          'cells contain a nucleus and membrane-bound organelles. Mitochondria '
          'are the site of aerobic respiration and generate ATP, the energy '
          'currency of the cell. The endoplasmic reticulum is involved in '
          'protein and lipid synthesis. Ribosomes assemble proteins from amino '
          'acids using messenger RNA as a template. The cell membrane is a '
          'phospholipid bilayer that regulates what enters and leaves the cell. '
          'Chloroplasts carry out photosynthesis in plant cells.',
      pageCount: 12,
      createdAt: now.subtract(const Duration(days: 2)),
    );
    content[content0.id] = content0;

    final quiz0 = Quiz(
      id: 'q-cell',
      ownerId: ada.id,
      title: 'The Cell — Quick Check',
      subject: 'Biology',
      description: 'Five questions from Lecture 3.',
      tags: const ['biology', 'cells'],
      contentItemId: content0.id,
      status: QuizStatus.published,
      questionCount: 5,
      createdAt: now.subtract(const Duration(days: 2)),
    );
    quizzes[quiz0.id] = quiz0;

    final qs = <Question>[
      Question(
        id: 'qq-1',
        quizId: quiz0.id,
        text: 'What is the primary function of mitochondria?',
        options: const [
          'Protein synthesis',
          'Energy production (ATP)',
          'Waste removal',
          'Cell division',
        ],
        correctIndex: 1,
        explanation: 'Mitochondria generate ATP through aerobic respiration.',
        difficulty: Difficulty.easy,
        sourceReference: 'Page 4',
        orderIndex: 0,
        timeLimitSeconds: 15,
      ),
      Question(
        id: 'qq-2',
        quizId: quiz0.id,
        text: 'Which cells lack a membrane-bound nucleus?',
        options: const [
          'Eukaryotic cells',
          'Plant cells',
          'Prokaryotic cells',
          'Animal cells',
        ],
        correctIndex: 2,
        explanation: 'Prokaryotes have no membrane-bound nucleus.',
        difficulty: Difficulty.medium,
        sourceReference: 'Page 2',
        orderIndex: 1,
        timeLimitSeconds: 20,
      ),
      Question(
        id: 'qq-3',
        quizId: quiz0.id,
        text: 'The cell membrane is best described as a…',
        options: const [
          'Rigid protein wall',
          'Phospholipid bilayer',
          'Single layer of sugars',
          'Strand of DNA',
        ],
        correctIndex: 1,
        explanation: 'It is a phospholipid bilayer controlling transport.',
        difficulty: Difficulty.medium,
        sourceReference: 'Page 6',
        orderIndex: 2,
        timeLimitSeconds: 20,
      ),
      Question(
        id: 'qq-4',
        quizId: quiz0.id,
        text: 'Ribosomes assemble proteins using which template?',
        options: const ['Messenger RNA', 'Transfer DNA', 'Lipids', 'ATP'],
        correctIndex: 0,
        explanation: 'Ribosomes read mRNA to assemble amino acids.',
        difficulty: Difficulty.hard,
        sourceReference: 'Page 7',
        orderIndex: 3,
        timeLimitSeconds: 30,
      ),
      Question(
        id: 'qq-5',
        quizId: quiz0.id,
        text: 'Which organelle carries out photosynthesis?',
        options: const [
          'Mitochondrion',
          'Nucleus',
          'Chloroplast',
          'Golgi apparatus',
        ],
        correctIndex: 2,
        explanation: 'Chloroplasts perform photosynthesis in plant cells.',
        difficulty: Difficulty.easy,
        sourceReference: 'Page 9',
        orderIndex: 4,
        timeLimitSeconds: 15,
      ),
    ];
    for (final q in qs) {
      questions[q.id] = q;
    }

    cumulative[sam.id] = _Cum(sam.id, sam.name)
      ..points = 4200
      ..quizzes = 3
      ..correct = 11
      ..answered = 15;
    cumulative[rio.id] = _Cum(rio.id, rio.name)
      ..points = 3850
      ..quizzes = 2
      ..correct = 8
      ..answered = 10;
  }
}

class _Cum {
  _Cum(this.studentId, this.name);
  final String studentId;
  final String name;
  int points = 0;
  int quizzes = 0;
  int correct = 0;
  int answered = 0;
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

class _Auth implements AuthRepository {
  _Auth(this._db);
  final _Db _db;

  @override
  Stream<AppUser?> authState() async* {
    yield _db.currentUser;
    yield* _db.authStream;
  }

  @override
  AppUser? get currentUser => _db.currentUser;

  @override
  Future<AppUser> register({
    required String name,
    required String email,
    required String password,
    required UserRole role,
  }) async {
    final e = email.trim().toLowerCase();
    if (_db.passwords.containsKey(e)) {
      throw const AppFailure('An account with that email already exists.');
    }
    if (password.length < 6) {
      throw const AppFailure('Password must be at least 6 characters.');
    }
    final user = AppUser(
      id: newId(),
      name: name.trim().isEmpty ? e.split('@').first : name.trim(),
      email: e,
      role: role,
      createdAt: DateTime.now(),
    );
    _db.users[user.id] = user;
    _db.passwords[e] = password;
    _db.setUser(user);
    return user;
  }

  @override
  Future<AppUser> signIn({
    required String email,
    required String password,
  }) async {
    final e = email.trim().toLowerCase();
    final stored = _db.passwords[e];
    if (stored == null || stored != password) {
      throw const AppFailure('Wrong email or password.');
    }
    final user = _db.users.values.firstWhere((u) => u.email == e);
    _db.setUser(user);
    return user;
  }

  @override
  Future<void> signOut() async => _db.setUser(null);

  @override
  Future<AppUser> updateProfile({String? name}) async {
    final u = _db.currentUser;
    if (u == null) throw const AppFailure('Not signed in.');
    final updated = u.copyWith(name: name);
    _db.users[u.id] = updated;
    _db.setUser(updated);
    return updated;
  }
}

// ---------------------------------------------------------------------------
// Content
// ---------------------------------------------------------------------------

class _Content implements ContentRepository {
  _Content(this._db);
  final _Db _db;

  List<ContentItem> _for(String ownerId) {
    final list = _db.content.values.where((c) => c.ownerId == ownerId).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Stream<List<ContentItem>> watchLibrary(String ownerId) =>
      _db.watch(['content'], () => _for(ownerId));

  @override
  Future<ContentItem> get(String id) async {
    final c = _db.content[id];
    if (c == null) throw const AppFailure('Content not found.');
    return c;
  }

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
    final id = newId();
    var item = ContentItem(
      id: id,
      ownerId: ownerId,
      title: title.trim().isEmpty ? (fileName ?? 'Untitled') : title.trim(),
      subject: subject,
      fileType: sourceType,
      status: ContentStatus.extracting,
      fileUrl: fileName,
      createdAt: DateTime.now(),
    );
    _db.content[id] = item;
    _db.ping('content');

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final text = rawText.trim();
    if (text.length < 40 && sourceType != ContentType.image) {
      item = item.copyWith(
        status: ContentStatus.failed,
        error: 'Could not extract enough text. Paste the text manually.',
      );
    } else {
      item = item.copyWith(
        status: ContentStatus.ready,
        extractedText: text,
        pageCount: pageCount,
      );
    }
    _db.content[id] = item;
    _db.ping('content');
    return item;
  }

  @override
  Future<void> delete(String id) async {
    _db.content.remove(id);
    _db.ping('content');
  }
}

// ---------------------------------------------------------------------------
// Quizzes + questions
// ---------------------------------------------------------------------------

class _Quizzes implements QuizRepository {
  _Quizzes(this._db);
  final _Db _db;

  List<Quiz> _for(String ownerId) {
    final l = _db.quizzes.values.where((q) => q.ownerId == ownerId).toList();
    l.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return l;
  }

  List<Question> _questionsFor(String quizId) {
    final l = _db.questions.values.where((q) => q.quizId == quizId).toList();
    l.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return l;
  }

  void _recount(String quizId) {
    final q = _db.quizzes[quizId];
    if (q == null) return;
    _db.quizzes[quizId] = q.copyWith(
      questionCount: _questionsFor(quizId).length,
    );
  }

  @override
  Stream<List<Quiz>> watchQuizzes(String ownerId) =>
      _db.watch(['quizzes'], () => _for(ownerId));

  @override
  Stream<Quiz?> watchQuiz(String quizId) =>
      _db.watch(['quizzes'], () => _db.quizzes[quizId]);

  @override
  Stream<List<Question>> watchQuestions(String quizId) =>
      _db.watch(['questions:$quizId'], () => _questionsFor(quizId));

  @override
  Future<Quiz> get(String quizId) async {
    final q = _db.quizzes[quizId];
    if (q == null) throw const AppFailure('Quiz not found.');
    return q;
  }

  @override
  Future<List<Question>> questionsOnce(String quizId) async =>
      _questionsFor(quizId);

  @override
  Future<Quiz> createDraft({
    required String ownerId,
    required String title,
    String? subject,
    String? contentItemId,
  }) async {
    final quiz = Quiz(
      id: newId(),
      ownerId: ownerId,
      title: title.trim().isEmpty ? 'Untitled quiz' : title.trim(),
      subject: subject ?? '',
      contentItemId: contentItemId,
      status: QuizStatus.draft,
      createdAt: DateTime.now(),
    );
    _db.quizzes[quiz.id] = quiz;
    _db.ping('quizzes');
    return quiz;
  }

  @override
  Future<void> saveQuiz(Quiz quiz) async {
    _db.quizzes[quiz.id] = quiz;
    _db.ping('quizzes');
  }

  @override
  Future<void> publish(String quizId) async {
    final q = _db.quizzes[quizId];
    if (q == null) throw const AppFailure('Quiz not found.');
    final questions = _questionsFor(quizId);
    if (questions.length < 2) {
      throw const AppFailure('Add at least 2 questions before publishing.');
    }
    final bad = questions.firstWhere(
      (x) => !x.isValid(),
      orElse: () => questions.first,
    );
    if (!bad.isValid()) {
      throw AppFailure('Question ${bad.orderIndex + 1} is incomplete.');
    }
    _db.quizzes[quizId] = q.copyWith(
      status: QuizStatus.published,
      questionCount: questions.length,
    );
    _db.ping('quizzes');
  }

  @override
  Future<void> unpublish(String quizId) async {
    final q = _db.quizzes[quizId];
    if (q == null) return;
    _db.quizzes[quizId] = q.copyWith(status: QuizStatus.draft);
    _db.ping('quizzes');
  }

  @override
  Future<void> deleteQuiz(String quizId) async {
    _db.quizzes.remove(quizId);
    _db.questions.removeWhere((_, v) => v.quizId == quizId);
    _db.ping('quizzes');
    _db.ping('questions:$quizId');
  }

  @override
  Future<void> addQuestions(String quizId, List<Question> questions) async {
    var base = _questionsFor(quizId).length;
    for (final q in questions) {
      final id = (q.id.isEmpty || q.id.startsWith('tmp')) ? newId() : q.id;
      _db.questions[id] = Question(
        id: id,
        quizId: quizId,
        text: q.text,
        options: q.options,
        correctIndex: q.correctIndex,
        explanation: q.explanation,
        difficulty: q.difficulty,
        sourceReference: q.sourceReference,
        orderIndex: base,
        timeLimitSeconds: q.timeLimitSeconds,
      );
      base++;
    }
    _recount(quizId);
    _db.ping('questions:$quizId');
    _db.ping('quizzes');
  }

  @override
  Future<void> saveQuestion(Question question) async {
    _db.questions[question.id] = question;
    _db.ping('questions:${question.quizId}');
  }

  @override
  Future<void> deleteQuestion(String quizId, String questionId) async {
    _db.questions.remove(questionId);
    final remaining = _questionsFor(quizId);
    for (var i = 0; i < remaining.length; i++) {
      _db.questions[remaining[i].id] = remaining[i].copyWith(orderIndex: i);
    }
    _recount(quizId);
    _db.ping('questions:$quizId');
    _db.ping('quizzes');
  }

  @override
  Future<void> reorderQuestions(String quizId, List<String> orderedIds) async {
    for (var i = 0; i < orderedIds.length; i++) {
      final q = _db.questions[orderedIds[i]];
      if (q != null) _db.questions[q.id] = q.copyWith(orderIndex: i);
    }
    _db.ping('questions:$quizId');
  }

  @override
  Future<List<Quiz>> publishedQuizzes() async {
    final l = _db.quizzes.values
        .where((q) => q.status == QuizStatus.published)
        .toList();
    l.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return l;
  }
}

// ---------------------------------------------------------------------------
// Live sessions
// ---------------------------------------------------------------------------

class _Sessions implements SessionRepository {
  _Sessions(this._db);
  final _Db _db;

  final Map<String, List<Question>> _sessionQuestions = {};

  List<SessionParticipant> _participants(String sessionId) {
    final l = _db.participants.values
        .where((p) => p.sessionId == sessionId)
        .toList();
    l.sort((a, b) {
      final c = b.totalScore.compareTo(a.totalScore);
      return c != 0 ? c : a.joinedAt.compareTo(b.joinedAt);
    });
    return l;
  }

  List<QuizResponse> _responses(String sessionId) =>
      _db.responses.values.where((r) => r.sessionId == sessionId).toList()
        ..sort((a, b) => a.answeredAt.compareTo(b.answeredAt));

  @override
  Future<QuizSession> createSession({
    required Quiz quiz,
    required String hostId,
    required List<Question> questions,
  }) async {
    if (questions.isEmpty) {
      throw const AppFailure('This quiz has no questions.');
    }
    final id = newId();
    var code = newJoinCode();
    while (_db.sessions.values.any(
      (s) => s.joinCode == code && s.status != SessionStatus.ended,
    )) {
      code = newJoinCode();
    }
    final session = QuizSession(
      id: id,
      quizId: quiz.id,
      quizTitle: quiz.title,
      hostId: hostId,
      joinCode: code,
      status: SessionStatus.lobby,
      totalQuestions: questions.length,
      createdAt: DateTime.now(),
    );
    _db.sessions[id] = session;
    _sessionQuestions[id] = List.of(questions);
    _db.ping('session:$id');
    _db.ping('sessions');
    return session;
  }

  @override
  Stream<QuizSession?> watchSession(String sessionId) =>
      _db.watch(['session:$sessionId'], () => _db.sessions[sessionId]);

  @override
  Stream<List<SessionParticipant>> watchParticipants(String sessionId) =>
      _db.watch(['session:$sessionId'], () => _participants(sessionId));

  @override
  Stream<List<QuizResponse>> watchResponses(String sessionId) =>
      _db.watch(['session:$sessionId'], () => _responses(sessionId));

  @override
  Future<QuizSession?> findByJoinCode(String code) async {
    final norm = normalizeJoinCode(code);
    try {
      return _db.sessions.values.firstWhere(
        (s) => s.joinCode == norm && s.status != SessionStatus.ended,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Question>> sessionQuestions(String sessionId) async =>
      List.of(_sessionQuestions[sessionId] ?? const []);

  @override
  Future<Question?> publicQuestionAt(String sessionId, int index) async {
    final qs = _sessionQuestions[sessionId];
    final s = _db.sessions[sessionId];
    if (qs == null || s == null || index < 0 || index >= qs.length) return null;
    final q = qs[index];
    final revealed =
        s.status == SessionStatus.ended ||
        (s.currentQuestionIndex == index && s.phase == SessionPhase.revealing);
    if (revealed) return q;
    // Strip the answer key while the question is live.
    return q.copyWith(correctIndex: -1, explanation: '');
  }

  @override
  Future<SessionParticipant> joinSession({
    required String joinCode,
    required AppUser student,
  }) async {
    final session = await findByJoinCode(joinCode);
    if (session == null) {
      throw const AppFailure('No live session with that code.');
    }
    final existing = _db.participants.values.firstWhere(
      (p) => p.sessionId == session.id && p.studentId == student.id,
      orElse: () => SessionParticipant(
        id: '',
        sessionId: session.id,
        studentId: student.id,
        displayName: student.name,
        joinedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    if (existing.id.isNotEmpty) {
      final reconnected = existing.copyWith(connected: true);
      _db.participants[existing.id] = reconnected;
      _db.ping('session:${session.id}');
      return reconnected;
    }
    if (!session.isLobby && !session.allowLateJoin) {
      throw const AppFailure('This session has already started.');
    }
    final p = SessionParticipant(
      id: newId(),
      sessionId: session.id,
      studentId: student.id,
      displayName: student.name,
      joinedAt: DateTime.now(),
    );
    _db.participants[p.id] = p;
    _db.ping('session:${session.id}');
    return p;
  }

  @override
  Future<void> setConnected({
    required String sessionId,
    required String studentId,
    required bool connected,
  }) async {
    final p = _db.participants.values.firstWhere(
      (p) => p.sessionId == sessionId && p.studentId == studentId,
      orElse: () => SessionParticipant(
        id: '',
        sessionId: '',
        studentId: '',
        displayName: '',
        joinedAt: DateTime.now(),
      ),
    );
    if (p.id.isEmpty) return;
    _db.participants[p.id] = p.copyWith(connected: connected);
    _db.ping('session:$sessionId');
  }

  QuizSession _require(String sessionId) {
    final s = _db.sessions[sessionId];
    if (s == null) throw const AppFailure('Session not found.');
    return s;
  }

  @override
  Future<void> startSession(String sessionId) async {
    final s = _require(sessionId);
    if (!s.isLobby) return;
    _advanceTo(s, 0);
  }

  @override
  Future<void> revealAnswer(String sessionId) async {
    final s = _require(sessionId);
    if (!s.isActive) return;
    _db.sessions[sessionId] = s.copyWith(phase: SessionPhase.revealing);
    _autoZeroMissing(s);
    _db.ping('session:$sessionId');
  }

  @override
  Future<void> nextQuestion(String sessionId) async {
    final s = _require(sessionId);
    if (!s.isActive) return;
    final next = s.currentQuestionIndex + 1;
    if (next >= s.totalQuestions) {
      await endSession(sessionId);
      return;
    }
    _advanceTo(s, next);
  }

  void _advanceTo(QuizSession s, int index) {
    final qs = _sessionQuestions[s.id]!;
    final limit = qs[index].timeLimitSeconds;
    final now = DateTime.now();
    _db.sessions[s.id] = s.copyWith(
      status: SessionStatus.active,
      currentQuestionIndex: index,
      phase: SessionPhase.asking,
      questionStartedAt: now,
      questionEndsAt: now.add(Duration(seconds: limit)),
      startedAt: s.startedAt ?? now,
    );
    _db.ping('session:${s.id}');
  }

  /// Records a 0-point, unanswered response for anyone who did not answer the
  /// question that just closed, so analytics + streaks stay consistent.
  void _autoZeroMissing(QuizSession s) {
    final idx = s.currentQuestionIndex;
    final qs = _sessionQuestions[s.id]!;
    if (idx < 0 || idx >= qs.length) return;
    for (final p in _participants(s.id)) {
      final answered = _db.responses.values.any(
        (r) =>
            r.sessionId == s.id &&
            r.studentId == p.studentId &&
            r.questionIndex == idx,
      );
      if (answered) continue;
      final r = QuizResponse(
        id: newId(),
        sessionId: s.id,
        studentId: p.studentId,
        questionId: qs[idx].id,
        questionIndex: idx,
        selectedIndex: -1,
        isCorrect: false,
        responseTimeMs: qs[idx].timeLimitSeconds * 1000,
        pointsAwarded: 0,
        answeredAt: DateTime.now(),
      );
      _db.responses[r.id] = r;
      _db.participants[p.id] = p.copyWith(
        answeredCount: p.answeredCount + 1,
        streak: 0,
        lastAnsweredIndex: idx,
      );
    }
  }

  @override
  Future<void> endSession(String sessionId) async {
    final s = _require(sessionId);
    if (s.isEnded) return;
    if (s.isActive) _autoZeroMissing(s);
    _db.sessions[sessionId] = s.copyWith(
      status: SessionStatus.ended,
      phase: SessionPhase.revealing,
      endedAt: DateTime.now(),
    );
    // Fold session scores into the global/all-time leaderboard.
    for (final p in _participants(sessionId)) {
      final cum = _db.cumulative.putIfAbsent(
        p.studentId,
        () => _Cum(p.studentId, p.displayName),
      );
      cum.points += p.totalScore;
      cum.quizzes += 1;
      cum.correct += p.correctCount;
      cum.answered += p.answeredCount;
    }
    _db.ping('session:$sessionId');
    _db.ping('sessions');
    _db.ping('leaderboard');
  }

  @override
  Future<QuizResponse> submitAnswer({
    required String sessionId,
    required AppUser student,
    required int questionIndex,
    required int selectedIndex,
    required int responseTimeMs,
  }) async {
    final s = _require(sessionId);
    final qs = _sessionQuestions[sessionId]!;
    if (questionIndex != s.currentQuestionIndex ||
        s.phase != SessionPhase.asking ||
        !s.isActive) {
      throw const AppFailure('That question is not accepting answers.');
    }
    final participant = _db.participants.values.firstWhere(
      (p) => p.sessionId == sessionId && p.studentId == student.id,
      orElse: () => throw const AppFailure('Join the session first.'),
    );
    // Idempotent: ignore repeats / double taps / reconnect replays.
    final prior = _db.responses.values.where(
      (r) =>
          r.sessionId == sessionId &&
          r.studentId == student.id &&
          r.questionIndex == questionIndex,
    );
    if (prior.isNotEmpty) return prior.first;

    final question = qs[questionIndex];
    final limitMs = question.timeLimitSeconds * 1000;
    final clampedMs = responseTimeMs.clamp(0, limitMs);
    final isCorrect =
        selectedIndex >= 0 && selectedIndex == question.correctIndex;

    final quiz = _db.quizzes[s.quizId];
    final scoring = quiz?.scoring ?? const ScoringConfig();
    final past = responseTimeMs > limitMs;
    final points = past
        ? 0
        : scoring.pointsFor(
            isCorrect: isCorrect,
            responseTimeMs: clampedMs,
            timeLimitMs: limitMs,
          );

    final response = QuizResponse(
      id: newId(),
      sessionId: sessionId,
      studentId: student.id,
      questionId: question.id,
      questionIndex: questionIndex,
      selectedIndex: selectedIndex,
      isCorrect: isCorrect,
      responseTimeMs: clampedMs,
      pointsAwarded: points,
      answeredAt: DateTime.now(),
    );
    _db.responses[response.id] = response;
    _db.participants[participant.id] = participant.copyWith(
      totalScore: participant.totalScore + points,
      correctCount: participant.correctCount + (isCorrect ? 1 : 0),
      answeredCount: participant.answeredCount + 1,
      streak: isCorrect ? participant.streak + 1 : 0,
      lastAnsweredIndex: questionIndex,
    );
    _db.ping('session:$sessionId');
    return response;
  }
}

// ---------------------------------------------------------------------------
// Leaderboard
// ---------------------------------------------------------------------------

class _Leaderboard implements LeaderboardRepository {
  _Leaderboard(this._db);
  final _Db _db;

  List<LeaderboardEntry> _snapshot() {
    final entries = _db.cumulative.values
        .map(
          (c) => LeaderboardEntry(
            studentId: c.studentId,
            displayName: c.name,
            points: c.points,
            quizzesPlayed: c.quizzes,
            correctRate: c.answered == 0 ? 0 : c.correct / c.answered,
          ),
        )
        .toList();
    entries.sort((a, b) => b.points.compareTo(a.points));
    return [
      for (var i = 0; i < entries.length; i++) entries[i].copyWith(rank: i + 1),
    ];
  }

  @override
  Stream<List<LeaderboardEntry>> watchGlobal({
    String period = 'all-time',
    String? subject,
  }) => _db.watch(['leaderboard'], _snapshot);
}

// ---------------------------------------------------------------------------
// Analytics
// ---------------------------------------------------------------------------

class _Analytics implements AnalyticsRepository {
  _Analytics(this._db);
  final _Db _db;

  @override
  Future<QuizAnalytics> quizAnalytics(String quizId) async {
    final sessions = _db.sessions.values
        .where((s) => s.quizId == quizId && s.status == SessionStatus.ended)
        .toList();
    final sessionIds = sessions.map((s) => s.id).toSet();
    final responses = _db.responses.values
        .where((r) => sessionIds.contains(r.sessionId))
        .toList();
    final participants = _db.participants.values
        .where((p) => sessionIds.contains(p.sessionId))
        .toList();

    final questions =
        _db.questions.values.where((q) => q.quizId == quizId).toList()
          ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));

    final stats = <QuestionStat>[];
    for (final q in questions) {
      final rs = responses.where((r) => r.questionId == q.id).toList();
      final answered = rs.where((r) => r.selectedIndex >= 0).length;
      final correct = rs.where((r) => r.isCorrect).length;
      stats.add(
        QuestionStat(
          questionId: q.id,
          text: q.text,
          answers: answered,
          correct: correct,
          orderIndex: q.orderIndex,
        ),
      );
    }

    final avgScore = participants.isEmpty
        ? 0.0
        : participants.map((p) => p.totalScore).reduce((a, b) => a + b) /
              participants.length;
    final totalAns = responses.where((r) => r.selectedIndex >= 0).length;
    final totalCorrect = responses.where((r) => r.isCorrect).length;
    final completion = participants.isEmpty || questions.isEmpty
        ? 0.0
        : participants
                  .map((p) => p.answeredCount / questions.length)
                  .reduce((a, b) => a + b) /
              participants.length;

    return QuizAnalytics(
      quizId: quizId,
      sessionsRun: sessions.length,
      participants: participants.length,
      averageScore: avgScore,
      averageCorrectRate: totalAns == 0 ? 0 : totalCorrect / totalAns,
      completionRate: completion.clamp(0, 1),
      questionStats: stats,
    );
  }

  @override
  Future<List<StudentQuizResult>> studentHistory(String studentId) async {
    final out = <StudentQuizResult>[];
    final ended = _db.sessions.values
        .where((s) => s.status == SessionStatus.ended)
        .toList();
    for (final s in ended) {
      final ranked =
          _db.participants.values.where((p) => p.sessionId == s.id).toList()
            ..sort((a, b) => b.totalScore.compareTo(a.totalScore));
      final idx = ranked.indexWhere((p) => p.studentId == studentId);
      if (idx == -1) continue;
      final me = ranked[idx];
      out.add(
        StudentQuizResult(
          sessionId: s.id,
          quizTitle: s.quizTitle,
          score: me.totalScore,
          rank: idx + 1,
          playedAt: s.endedAt ?? s.createdAt,
          correct: me.correctCount,
          total: s.totalQuestions,
        ),
      );
    }
    out.sort((a, b) => b.playedAt.compareTo(a.playedAt));
    return out;
  }
}
