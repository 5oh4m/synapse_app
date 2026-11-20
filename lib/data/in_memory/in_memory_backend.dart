import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../ai/mock_quiz_generator.dart';
import '../../ai/quiz_generator.dart';
import '../../core/connection.dart';
import '../../core/failure.dart';
import '../../core/ids.dart';
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
import '../../models/scoring.dart';
import '../../models/session_participant.dart';
import '../../models/user.dart';
import '../local/key_value_store.dart';
import '../repositories.dart';

/// Offline backend: one isolate, no network, no setup.
///
/// **What it is.** The store for the unit tests and a single-device demo of the
/// whole flow — register, generate, review, host, play, score.
///
/// **What it is not.** Multi-device. A host and a student in this backend are
/// the same running app; two browser tabs do not see each other. Real
/// classroom play needs `--dart-define=BACKEND=remote` and the server in
/// `backend/` ([RemoteBackend]). [isMultiDevice] returns false so the UI can
/// say so rather than implying otherwise.
///
/// **Credentials are never written to disk.** The previous version kept an
/// `email -> plaintext password` map and serialised it into
/// `shared_preferences` (localStorage on web). That key is now actively deleted
/// on first run (see [_Db._purgeLeakedV1Store]).
class InMemoryBackend implements Backend {
  InMemoryBackend({KeyValueStore? store, bool seedDemoData = true})
    : _db = _Db(store ?? SharedPreferencesStore()),
      _seedDemoData = seedDemoData {
    _auth = _Auth(_db);
    _content = _Content(_db);
    _quizzes = _Quizzes(_db);
    _sessions = _Sessions(_db);
    _leaderboard = _Leaderboard(_db);
    _analytics = _Analytics(_db);
  }

  final _Db _db;
  final bool _seedDemoData;
  late final _Auth _auth;
  late final _Content _content;
  late final _Quizzes _quizzes;
  late final _Sessions _sessions;
  late final _Leaderboard _leaderboard;
  late final _Analytics _analytics;
  final _generator = MockQuizGenerator();

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
  String get generatorLabel => 'Offline sample generator';

  @override
  bool get isMultiDevice => false;

  /// No socket, so no reconnect states to report. It says `connected` because
  /// the store is in this isolate and always reachable — not to imply a network.
  @override
  Stream<ConnectionState> connectionState() =>
      Stream.value(ConnectionState.connected);

  /// The session clock is this device's clock, so there is no offset to learn.
  @override
  final ServerClock clock = ServerClock();

  @override
  void resumeRealtime() {}

  @override
  Stream<AppFailure> storageIssues() => _db.issues;

  @override
  Future<void> init() async {
    final restored = await _db.restore();
    if (!restored && _seedDemoData) {
      _db.seedDemo();
      await _db.flush();
    }
  }

  @override
  Future<void> dispose() async {
    await _db.dispose();
  }

  /// Waits for any debounced write to land. Tests use this instead of sleeping.
  Future<void> flush() => _db.flush();
}

// ---------------------------------------------------------------------------
// Shared store
// ---------------------------------------------------------------------------

/// The collections that are persisted, each under its own key.
///
/// Live-session state (sessions, participants, responses) is deliberately
/// absent: it churns on every answer and is meaningless after a restart. The
/// durable summary of a finished session is one [_Played] record per player.
enum _Col { users, content, quizzes, questions, results, session }

class _Db {
  _Db(this.store);

  final KeyValueStore store;

  static const _prefix = 'quizzle.v2';
  static const _legacyKey = 'quizzle.store.v1';

  static String _key(_Col col) => '$_prefix.${col.name}';

  /// Bulky extracted text lives one key per item, so a quiz edit never
  /// rewrites a megabyte of lecture notes.
  static String _textKey(String id) => '$_prefix.text.$id';

  final Map<String, AppUser> users = {};

  /// email -> salted hash. **RAM only.** Never serialised; see the class doc.
  final Map<String, String> _credentials = {};

  AppUser? currentUser;

  final Map<String, ContentItem> content = {};
  final Map<String, Quiz> quizzes = {};
  final Map<String, Question> questions = {};

  // Ephemeral.
  final Map<String, QuizSession> sessions = {};
  final Map<String, SessionParticipant> participants = {};
  final Map<String, QuizResponse> responses = {};
  final Map<String, List<Question>> sessionQuestions = {};

  /// Durable per-player result of a finished session. Enough to filter the
  /// leaderboard by period and subject for real.
  final List<_Played> results = [];

  final _authCtrl = StreamController<AppUser?>.broadcast();
  final _bus = StreamController<String>.broadcast();
  final _issuesCtrl = StreamController<AppFailure>.broadcast();

  Stream<AppUser?> get authStream => _authCtrl.stream;

  /// Storage failures, surfaced instead of swallowed.
  Stream<AppFailure> get issues => _issuesCtrl.stream;

  final Set<_Col> _dirty = {};
  final Set<String> _dirtyText = {};
  Timer? _timer;
  Completer<void>? _pending;
  int _consecutiveFailures = 0;
  bool seeded = false;

  // ------------------------------------------------------------ mutations ---

  void setUser(AppUser? u) {
    currentUser = u;
    _authCtrl.add(u);
    touch(_Col.session);
  }

  void setCredential(String email, String password) {
    _credentials[email] = _hash(email, password);
  }

  bool hasCredential(String email) => _credentials.containsKey(email);

  bool checkCredential(String email, String password) =>
      _credentials[email] == _hash(email, password);

  /// Salted with the address so two accounts sharing a password do not share a
  /// digest. Demo-grade and RAM-only — the server uses bcrypt.
  String _hash(String email, String password) =>
      base64Url.encode(sha256.convert(utf8.encode('$email::$password')).bytes);

  /// Notifies watchers. Unlike the previous version this does **not** trigger a
  /// write: persistence is requested explicitly by [touch], so a live session's
  /// answer storm costs zero storage writes.
  void ping(String channel) => _bus.add(channel);

  /// Marks one collection as needing a write.
  void touch(_Col col) {
    _dirty.add(col);
    _schedule();
  }

  /// Marks one content item's extracted text as needing a write.
  void touchText(String id) {
    _dirtyText.add(id);
    _schedule();
  }

  void _schedule() {
    if (_consecutiveFailures >= 3) return;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 250), () {
      unawaited(flush());
    });
  }

  /// Writes only what changed. Returns when the write attempt is finished.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (_pending != null) return _pending!.future;
    if (_dirty.isEmpty && _dirtyText.isEmpty) return;

    final completer = Completer<void>();
    _pending = completer;

    final cols = _dirty.toList();
    final texts = _dirtyText.toList();
    _dirty.clear();
    _dirtyText.clear();

    var failed = false;
    for (final col in cols) {
      failed = !await _writeCollection(col) || failed;
    }
    for (final id in texts) {
      final item = content[id];
      if (item == null) {
        await store.remove(_textKey(id));
        continue;
      }
      failed = !await _write(_textKey(id), item.extractedText) || failed;
    }

    _consecutiveFailures = failed ? _consecutiveFailures + 1 : 0;
    if (_consecutiveFailures == 3) {
      _report(
        const AppFailure(
          'Offline storage keeps rejecting writes, so nothing more will be '
          'saved this session. Your work stays in this tab only.',
          code: 'STORAGE',
        ),
      );
    }

    _pending = null;
    completer.complete();
  }

  Future<bool> _writeCollection(_Col col) async {
    final payload = switch (col) {
      _Col.users => jsonEncode([for (final u in users.values) u.toJson()]),
      // The index carries metadata only; `extracted_text` is written per item.
      _Col.content => jsonEncode([
        for (final c in content.values) c.toJson()..remove('extracted_text'),
      ]),
      _Col.quizzes => jsonEncode([for (final q in quizzes.values) q.toJson()]),
      _Col.questions => jsonEncode([
        for (final q in questions.values) q.toJson(),
      ]),
      _Col.results => jsonEncode([for (final r in results) r.toJson()]),
      _Col.session => jsonEncode({'current_user_id': currentUser?.id}),
    };
    return _write(_key(col), payload);
  }

  Future<bool> _write(String key, String value) async {
    try {
      await store.write(key, value);
      return true;
    } on AppFailure catch (e) {
      _report(e);
      return false;
    } catch (e) {
      _report(
        AppFailure(
          'Could not save to offline storage ($key).',
          code: 'STORAGE',
          cause: e,
        ),
      );
      return false;
    }
  }

  void _report(AppFailure failure) {
    if (!_issuesCtrl.isClosed) _issuesCtrl.add(failure);
  }

  // -------------------------------------------------------------- restore ---

  Future<bool> restore() async {
    await _purgeLeakedV1Store();
    final rawUsers = await store.read(_key(_Col.users));
    if (rawUsers == null) return false;
    try {
      for (final raw in (jsonDecode(rawUsers) as List)) {
        final u = AppUser.fromJson(raw as Map<String, dynamic>);
        users[u.id] = u;
      }
      await _restoreContent();
      await _restoreList(
        _Col.quizzes,
        (m) => quizzes[(m['id'] as String)] = Quiz.fromJson(m),
      );
      await _restoreList(
        _Col.questions,
        (m) => questions[(m['id'] as String)] = Question.fromJson(m),
      );
      final rawResults = await store.read(_key(_Col.results));
      if (rawResults != null) {
        for (final raw in (jsonDecode(rawResults) as List)) {
          results.add(_Played.fromJson(raw as Map<String, dynamic>));
        }
      }
      final rawSession = await store.read(_key(_Col.session));
      if (rawSession != null) {
        final id =
            (jsonDecode(rawSession) as Map<String, dynamic>)['current_user_id']
                as String?;
        currentUser = id == null ? null : users[id];
      }
      seeded = true;
      return true;
    } catch (e) {
      _report(
        AppFailure(
          'Saved offline data could not be read and was ignored.',
          code: 'STORAGE',
          cause: e,
        ),
      );
      return false;
    }
  }

  Future<void> _restoreList(
    _Col col,
    void Function(Map<String, dynamic>) add,
  ) async {
    final raw = await store.read(_key(col));
    if (raw == null) return;
    for (final row in (jsonDecode(raw) as List)) {
      add(row as Map<String, dynamic>);
    }
  }

  Future<void> _restoreContent() async {
    final raw = await store.read(_key(_Col.content));
    if (raw == null) return;
    for (final row in (jsonDecode(raw) as List)) {
      final map = row as Map<String, dynamic>;
      final id = map['id'] as String;
      map['extracted_text'] = await store.read(_textKey(id)) ?? '';
      content[id] = ContentItem.fromJson(map);
    }
  }

  /// The v1 blob contained `{"passwords": {"a@b.c": "hunter2"}}` in cleartext.
  /// Anything still holding it gets it deleted — migrating the data would mean
  /// carrying the leak forward, so only the non-credential parts are kept.
  Future<void> _purgeLeakedV1Store() async {
    final legacy = await store.read(_legacyKey);
    if (legacy == null) return;
    try {
      final j = jsonDecode(legacy) as Map<String, dynamic>;
      for (final raw in (j['users'] as List? ?? const [])) {
        final u = AppUser.fromJson(raw as Map<String, dynamic>);
        users[u.id] = u;
      }
      for (final raw in (j['quizzes'] as List? ?? const [])) {
        final q = Quiz.fromJson(raw as Map<String, dynamic>);
        quizzes[q.id] = q;
      }
      for (final raw in (j['questions'] as List? ?? const [])) {
        final q = Question.fromJson(raw as Map<String, dynamic>);
        questions[q.id] = q;
      }
      for (final raw in (j['content'] as List? ?? const [])) {
        final c = ContentItem.fromJson(raw as Map<String, dynamic>);
        content[c.id] = c;
        _dirtyText.add(c.id);
      }
      if (users.isNotEmpty) {
        seeded = true;
        _dirty.addAll([
          _Col.users,
          _Col.quizzes,
          _Col.questions,
          _Col.content,
        ]);
      }
    } catch (_) {
      // Unreadable legacy blob: drop it anyway.
    }
    await store.remove(_legacyKey);
    if (_dirty.isNotEmpty) await flush();
  }

  // ---------------------------------------------------------------- watch ---

  /// Emits [snapshot] now, then again on every ping matching [channels].
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

  Future<void> dispose() async {
    _timer?.cancel();
    await _authCtrl.close();
    await _bus.close();
    await _issuesCtrl.close();
  }

  // ----------------------------------------------------------------- seed ---

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
      // In RAM for this run only, so the demo accounts can sign in normally.
      setCredential(u.email, 'password');
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

    const seedQuestions = <(String, List<String>, int, String)>[
      (
        'Which organelle generates most of the ATP in a eukaryotic cell?',
        ['Mitochondrion', 'Ribosome', 'Golgi apparatus', 'Lysosome'],
        0,
        'Mitochondria are the site of aerobic respiration.',
      ),
      (
        'What distinguishes a prokaryotic cell from a eukaryotic cell?',
        [
          'No membrane-bound nucleus',
          'No cell membrane',
          'No ribosomes',
          'No DNA',
        ],
        0,
        'Prokaryotes lack a membrane-bound nucleus.',
      ),
      (
        'Which structure assembles proteins from amino acids?',
        ['Ribosome', 'Nucleolus', 'Vacuole', 'Centriole'],
        0,
        'Ribosomes read mRNA to build proteins.',
      ),
      (
        'The cell membrane is best described as a',
        [
          'phospholipid bilayer',
          'single protein sheet',
          'rigid cellulose wall',
          'starch granule',
        ],
        0,
        'It is a bilayer that regulates transport.',
      ),
      (
        'Photosynthesis in plant cells happens in the',
        ['chloroplast', 'mitochondrion', 'nucleus', 'peroxisome'],
        0,
        'Chloroplasts carry out photosynthesis.',
      ),
    ];

    for (var i = 0; i < seedQuestions.length; i++) {
      final (text, options, correct, why) = seedQuestions[i];
      final shuffled = [...options];
      final answer = options[correct];
      shuffled.shuffle();
      final id = 'q-cell-$i';
      questions[id] = Question(
        id: id,
        quizId: quiz0.id,
        text: text,
        options: shuffled,
        correctIndex: shuffled.indexOf(answer),
        explanation: why,
        difficulty: i < 2 ? Difficulty.easy : Difficulty.medium,
        sourceReference: 'Page ${2 + i}',
        orderIndex: i,
        timeLimitSeconds: 20,
      );
    }

    _dirty.addAll([
      _Col.users,
      _Col.content,
      _Col.quizzes,
      _Col.questions,
      _Col.session,
    ]);
    _dirtyText.add(content0.id);
  }
}

/// One player's finished-session result. Durable, compact, written once.
class _Played {
  _Played({
    required this.studentId,
    required this.displayName,
    required this.sessionId,
    required this.quizId,
    required this.quizTitle,
    required this.subject,
    required this.points,
    required this.correct,
    required this.answered,
    required this.totalQuestions,
    required this.rank,
    required this.playedAt,
  });

  final String studentId;
  final String displayName;
  final String sessionId;
  final String quizId;
  final String quizTitle;
  final String subject;
  final int points;
  final int correct;
  final int answered;
  final int totalQuestions;
  final int rank;
  final DateTime playedAt;

  Map<String, dynamic> toJson() => {
    'student_id': studentId,
    'display_name': displayName,
    'session_id': sessionId,
    'quiz_id': quizId,
    'quiz_title': quizTitle,
    'subject': subject,
    'points': points,
    'correct': correct,
    'answered': answered,
    'total_questions': totalQuestions,
    'rank': rank,
    'played_at': playedAt.toIso8601String(),
  };

  factory _Played.fromJson(Map<String, dynamic> j) => _Played(
    studentId: j['student_id'] as String,
    displayName: (j['display_name'] ?? 'Player') as String,
    sessionId: (j['session_id'] ?? '') as String,
    quizId: (j['quiz_id'] ?? '') as String,
    quizTitle: (j['quiz_title'] ?? 'Quiz') as String,
    subject: (j['subject'] ?? '') as String,
    points: ((j['points'] ?? 0) as num).toInt(),
    correct: ((j['correct'] ?? 0) as num).toInt(),
    answered: ((j['answered'] ?? 0) as num).toInt(),
    totalQuestions: ((j['total_questions'] ?? 0) as num).toInt(),
    rank: ((j['rank'] ?? 0) as num).toInt(),
    playedAt:
        DateTime.tryParse(j['played_at'] as String? ?? '') ?? DateTime.now(),
  );
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
    if (!e.contains('@')) {
      throw const AppFailure(
        'Enter a valid email address.',
        code: 'VALIDATION',
        field: 'email',
      );
    }
    if (_db.users.values.any((u) => u.email == e)) {
      throw const AppFailure(
        'An account with that email already exists.',
        code: 'CONFLICT',
        field: 'email',
      );
    }
    // Same minimum the server enforces, so the two backends agree.
    if (password.length < 8) {
      throw const AppFailure(
        'Password must be at least 8 characters.',
        code: 'VALIDATION',
        field: 'password',
      );
    }
    final user = AppUser(
      id: newId(),
      name: name.trim().isEmpty ? e.split('@').first : name.trim(),
      email: e,
      role: role,
      createdAt: DateTime.now(),
    );
    _db.users[user.id] = user;
    _db.setCredential(e, password);
    _db.touch(_Col.users);
    _db.setUser(user);
    return user;
  }

  @override
  Future<AppUser> signIn({
    required String email,
    required String password,
  }) async {
    final e = email.trim().toLowerCase();
    final user = _db.users.values.where((u) => u.email == e).firstOrNull;
    if (user != null && !_db.hasCredential(e)) {
      // The profile was restored from storage but its password was not — this
      // backend keeps no credential on disk, by design.
      throw const AppFailure(
        'This offline demo does not store passwords. Use a demo profile, or '
        'run with --dart-define=BACKEND=remote for real accounts.',
        code: 'NO_CREDENTIAL',
        field: 'password',
      );
    }
    if (user == null || !_db.checkCredential(e, password)) {
      throw const AppFailure(
        'Wrong email or password.',
        code: 'UNAUTHORIZED',
        field: 'password',
      );
    }
    _db.setUser(user);
    return user;
  }

  /// No password involved: this backend hands over a local demo profile.
  @override
  Future<AppUser> demoSignIn(UserRole role) async {
    final email = role == UserRole.educator
        ? 'ada@quizzle.dev'
        : 'sam@quizzle.dev';
    var user = _db.users.values.where((u) => u.email == email).firstOrNull;
    user ??= _db.users.values.where((u) => u.role == role).firstOrNull;
    if (user == null) {
      user = AppUser(
        id: newId(),
        name: role == UserRole.educator ? 'Demo Educator' : 'Demo Student',
        email: email,
        role: role,
        createdAt: DateTime.now(),
      );
      _db.users[user.id] = user;
      _db.touch(_Col.users);
    }
    _db.setUser(user);
    return user;
  }

  @override
  Future<void> signOut() async => _db.setUser(null);

  @override
  Future<AppUser> updateProfile({String? name}) async {
    final u = _db.currentUser;
    if (u == null) {
      throw const AppFailure('Not signed in.', code: 'UNAUTHORIZED');
    }
    final updated = u.copyWith(name: name);
    _db.users[u.id] = updated;
    _db.touch(_Col.users);
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
    if (c == null) {
      throw const AppFailure('Content not found.', code: 'NOT_FOUND');
    }
    return c;
  }

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
    final owner = ownerId ?? _db.currentUser?.id;
    if (owner == null) {
      throw const AppFailure('Not signed in.', code: 'UNAUTHORIZED');
    }
    final id = newId();
    final text = rawText.trim();
    final usable = text.length >= 40;
    final item = ContentItem(
      id: id,
      ownerId: owner,
      title: title.trim().isEmpty ? (fileName ?? 'Untitled') : title.trim(),
      subject: subject,
      fileType: sourceType,
      status: usable ? ContentStatus.ready : ContentStatus.failed,
      fileUrl: fileName,
      extractedText: usable ? text : '',
      pageCount: usable ? pageCount : 0,
      error: usable
          ? null
          : 'Only ${text.length} characters of text — paste at least a '
                'paragraph to generate from.',
      createdAt: DateTime.now(),
    );
    _db.content[id] = item;
    _db.touch(_Col.content);
    _db.touchText(id);
    _db.ping('content');
    return item;
  }

  /// Offline: there is no parser here. Text files are decoded; anything else is
  /// stored with an honest `needs_text` explanation rather than a fake result.
  @override
  Future<ContentItem> upload({
    required String fileName,
    required Uint8List bytes,
    String? title,
    String? subject,
  }) async {
    final extracted = await extractFile(fileName: fileName, bytes: bytes);
    if (!extracted.isReady) {
      final id = newId();
      final owner = _db.currentUser?.id;
      if (owner == null) {
        throw const AppFailure('Not signed in.', code: 'UNAUTHORIZED');
      }
      final item = ContentItem(
        id: id,
        ownerId: owner,
        title: (title == null || title.isEmpty)
            ? fileName.replaceAll(RegExp(r'\.[^.]+$'), '')
            : title,
        subject: subject,
        fileType: extracted.sourceType,
        status: ContentStatus.failed,
        fileUrl: fileName,
        error: extracted.message,
        createdAt: DateTime.now(),
      );
      _db.content[id] = item;
      _db.touch(_Col.content);
      _db.ping('content');
      return item;
    }
    return ingest(
      title: (title == null || title.isEmpty)
          ? fileName.replaceAll(RegExp(r'\.[^.]+$'), '')
          : title,
      subject: subject,
      sourceType: extracted.sourceType,
      rawText: extracted.text,
      pageCount: extracted.pageCount,
      fileName: fileName,
    );
  }

  @override
  Future<ExtractedContent> extractFile({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final ext = fileName.toLowerCase().split('.').last;
    if (ext == 'txt' || ext == 'md' || ext == 'csv' || !fileName.contains('.')) {
      final text = utf8.decode(bytes, allowMalformed: true).trim();
      return ExtractedContent(
        text: text,
        pageCount: text.isEmpty ? 0 : 1,
        sourceType: ContentType.text,
        status: text.isEmpty
            ? ExtractionStatus.needsText
            : ExtractionStatus.ready,
        fileName: fileName,
      );
    }
    final type = switch (ext) {
      'pdf' => ContentType.pdf,
      'ppt' || 'pptx' => ContentType.pptx,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' => ContentType.image,
      _ => ContentType.text,
    };
    return ExtractedContent.needsText(
      sourceType: type,
      fileName: fileName,
      message: type == ContentType.image
          ? 'No OCR is bundled. Paste the text from the image instead.'
          : 'The offline backend cannot read ${ext.toUpperCase()} files. Start '
                'the server (cd backend && npm start) and run with '
                '--dart-define=BACKEND=remote, or paste the text.',
    );
  }

  @override
  Future<void> delete(String id) async {
    _db.content.remove(id);
    _db.touch(_Col.content);
    _db.touchText(id);
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
    _db.touch(_Col.quizzes);
  }

  @override
  Stream<List<Quiz>> watchQuizzes(String ownerId) =>
      _db.watch(['quizzes'], () => _for(ownerId));

  @override
  Stream<Quiz?> watchQuiz(String quizId) =>
      _db.watch(['quizzes'], () => _db.quizzes[quizId]);

  /// Mirrors the server: only the owner sees the key.
  List<Question> _visibleQuestions(String quizId) {
    final all = _questionsFor(quizId);
    final owner = _db.quizzes[quizId]?.ownerId;
    if (owner != null && owner == _db.currentUser?.id) return all;
    return [
      for (final q in all) q.copyWith(correctIndex: -1, explanation: ''),
    ];
  }

  @override
  Stream<List<Question>> watchQuestions(String quizId) =>
      _db.watch(['questions:$quizId'], () => _visibleQuestions(quizId));

  @override
  Future<Quiz> get(String quizId) async {
    final q = _db.quizzes[quizId];
    if (q == null) {
      throw const AppFailure('Quiz not found.', code: 'NOT_FOUND');
    }
    return q;
  }

  @override
  Future<List<Question>> questionsOnce(String quizId) async =>
      _visibleQuestions(quizId);

  @override
  Future<Quiz> createDraft({
    String? ownerId,
    required String title,
    String? subject,
    String? contentItemId,
  }) async {
    final owner = ownerId ?? _db.currentUser?.id;
    if (owner == null) {
      throw const AppFailure('Not signed in.', code: 'UNAUTHORIZED');
    }
    final quiz = Quiz(
      id: newId(),
      ownerId: owner,
      title: title.trim().isEmpty ? 'Untitled quiz' : title.trim(),
      subject: subject ?? '',
      contentItemId: contentItemId,
      status: QuizStatus.draft,
      createdAt: DateTime.now(),
    );
    _db.quizzes[quiz.id] = quiz;
    _db.touch(_Col.quizzes);
    _db.ping('quizzes');
    return quiz;
  }

  @override
  Future<void> saveQuiz(Quiz quiz) async {
    _db.quizzes[quiz.id] = quiz;
    _db.touch(_Col.quizzes);
    _db.ping('quizzes');
  }

  @override
  Future<void> publish(String quizId) async {
    final q = _db.quizzes[quizId];
    if (q == null) {
      throw const AppFailure('Quiz not found.', code: 'NOT_FOUND');
    }
    final questions = _questionsFor(quizId);
    if (questions.length < 2) {
      throw const AppFailure(
        'Add at least 2 questions before publishing.',
        code: 'CONFLICT',
      );
    }
    final bad = questions.where((x) => !x.isValid()).firstOrNull;
    if (bad != null) {
      throw AppFailure(
        'Question ${bad.orderIndex + 1} is incomplete.',
        code: 'CONFLICT',
      );
    }
    _db.quizzes[quizId] = q.copyWith(
      status: QuizStatus.published,
      questionCount: questions.length,
    );
    _db.touch(_Col.quizzes);
    _db.ping('quizzes');
  }

  @override
  Future<void> unpublish(String quizId) async {
    final q = _db.quizzes[quizId];
    if (q == null) return;
    _db.quizzes[quizId] = q.copyWith(status: QuizStatus.draft);
    _db.touch(_Col.quizzes);
    _db.ping('quizzes');
  }

  @override
  Future<void> deleteQuiz(String quizId) async {
    _db.quizzes.remove(quizId);
    _db.questions.removeWhere((_, v) => v.quizId == quizId);
    _db.touch(_Col.quizzes);
    _db.touch(_Col.questions);
    _db.ping('quizzes');
    _db.ping('questions:$quizId');
  }

  @override
  Future<void> addQuestions(String quizId, List<Question> questions) async {
    var next = _questionsFor(quizId).length;
    for (final q in questions) {
      final id = (q.id.isEmpty || q.id.startsWith('tmp')) ? newId() : q.id;
      _db.questions[id] = q.withId(id, quizId: quizId, orderIndex: next);
      next++;
    }
    _recount(quizId);
    _db.touch(_Col.questions);
    _db.ping('questions:$quizId');
    _db.ping('quizzes');
  }

  /// Replace in place. An unknown id falls back to the row holding the same
  /// `order_index`, which is what stops "Regenerate" from turning 2 questions
  /// into 3 with two of them claiming index 0.
  @override
  Future<void> saveQuestion(Question question) async {
    final existing = _db.questions[question.id];
    if (existing != null) {
      await replaceQuestion(existing.id, question);
      return;
    }
    final target = _questionsFor(question.quizId)
        .where((q) => q.orderIndex == question.orderIndex)
        .firstOrNull;
    if (target == null) {
      throw const AppFailure(
        'That question is no longer part of this quiz.',
        code: 'NOT_FOUND',
      );
    }
    await replaceQuestion(target.id, question);
  }

  @override
  Future<Question> replaceQuestion(
    String questionId,
    Question replacement,
  ) async {
    final existing = _db.questions[questionId];
    if (existing == null) {
      throw const AppFailure('Question not found.', code: 'NOT_FOUND');
    }
    // id and order_index survive; everything else is taken from the new one.
    final saved = replacement.withId(
      existing.id,
      quizId: existing.quizId,
      orderIndex: existing.orderIndex,
    );
    _db.questions[existing.id] = saved;
    _db.touch(_Col.questions);
    _db.ping('questions:${saved.quizId}');
    return saved;
  }

  @override
  Future<void> deleteQuestion(String quizId, String questionId) async {
    _db.questions.remove(questionId);
    final remaining = _questionsFor(quizId);
    for (var i = 0; i < remaining.length; i++) {
      _db.questions[remaining[i].id] = remaining[i].copyWith(orderIndex: i);
    }
    _recount(quizId);
    _db.touch(_Col.questions);
    _db.ping('questions:$quizId');
    _db.ping('quizzes');
  }

  @override
  Future<void> reorderQuestions(String quizId, List<String> orderedIds) async {
    for (var i = 0; i < orderedIds.length; i++) {
      final q = _db.questions[orderedIds[i]];
      if (q != null) _db.questions[q.id] = q.copyWith(orderIndex: i);
    }
    _db.touch(_Col.questions);
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

  @override
  Future<PracticeGrade> gradePractice({
    required String quizId,
    required String questionId,
    required int selectedIndex,
  }) async {
    final quiz = _db.quizzes[quizId];
    final question = _db.questions[questionId];
    if (quiz == null || question == null || question.quizId != quizId) {
      throw const AppFailure('Question not found.', code: 'NOT_FOUND');
    }
    final isOwner = quiz.ownerId == _db.currentUser?.id;
    final live = _db.sessions.values.any(
      (s) => s.quizId == quizId && s.status != SessionStatus.ended,
    );
    if (!isOwner && live) {
      throw const AppFailure(
        'This quiz is being played live right now. Practise it once the '
        'session ends.',
        code: 'CONFLICT',
      );
    }
    return PracticeGrade(
      questionId: question.id,
      selectedIndex: selectedIndex,
      isCorrect: selectedIndex >= 0 && selectedIndex == question.correctIndex,
      correctIndex: question.correctIndex,
      explanation: question.explanation,
    );
  }
}

// ---------------------------------------------------------------------------
// Live sessions
// ---------------------------------------------------------------------------

class _Sessions implements SessionRepository {
  _Sessions(this._db);
  final _Db _db;

  Map<String, List<Question>> get _sessionQuestions => _db.sessionQuestions;

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
    String? hostId,
    List<Question> questions = const [],
  }) async {
    final host = hostId ?? _db.currentUser?.id;
    if (host == null) {
      throw const AppFailure('Not signed in.', code: 'UNAUTHORIZED');
    }
    final snapshot = questions.isNotEmpty
        ? List.of(questions)
        : (_db.questions.values.where((q) => q.quizId == quiz.id).toList()
            ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex)));
    if (snapshot.isEmpty) {
      throw const AppFailure('This quiz has no questions.', code: 'CONFLICT');
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
      hostId: host,
      joinCode: code,
      status: SessionStatus.lobby,
      totalQuestions: snapshot.length,
      createdAt: DateTime.now(),
    );
    _db.sessions[id] = session;
    // Snapshot, so editing the quiz mid-session cannot change what is played.
    _sessionQuestions[id] = snapshot;
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
  Stream<({int answered, int total})> watchAnswerCount(String sessionId) =>
      _db.watch(['session:$sessionId'], () {
        final s = _db.sessions[sessionId];
        final roster = _participants(sessionId);
        final index = s?.currentQuestionIndex ?? -1;
        if (index < 0) return (answered: 0, total: roster.length);
        final answered = _db.responses.values
            .where(
              (r) =>
                  r.sessionId == sessionId &&
                  r.questionIndex == index &&
                  r.selectedIndex >= 0,
            )
            .length;
        return (answered: answered, total: roster.length);
      });

  @override
  Future<QuizSession?> findByJoinCode(String code) async {
    final norm = normalizeJoinCode(code);
    return _db.sessions.values
        .where((s) => s.joinCode == norm && s.status != SessionStatus.ended)
        .firstOrNull;
  }

  @override
  Future<List<Question>> sessionQuestions(String sessionId) async =>
      List.of(_sessionQuestions[sessionId] ?? const []);

  static bool _isRevealed(QuizSession s, int index) =>
      s.status == SessionStatus.ended ||
      index < s.currentQuestionIndex ||
      (s.currentQuestionIndex == index && s.phase == SessionPhase.revealing);

  @override
  Future<Question?> publicQuestionAt(String sessionId, int index) async {
    final qs = _sessionQuestions[sessionId];
    final s = _db.sessions[sessionId];
    if (qs == null || s == null || index < 0 || index >= qs.length) return null;
    // Never ahead of the class, matching the server.
    final isHost = _db.currentUser?.id == s.hostId;
    if (!isHost && (s.isLobby || index > s.currentQuestionIndex)) return null;
    final q = qs[index];
    if (_isRevealed(s, index)) return q;
    // The answer key never leaves the store while the question is live.
    return q.copyWith(correctIndex: -1, explanation: '');
  }

  @override
  Stream<RevealInfo?> watchReveal(String sessionId) =>
      _db.watch(['session:$sessionId'], () {
        final s = _db.sessions[sessionId];
        final qs = _sessionQuestions[sessionId];
        if (s == null || qs == null) return null;
        final index = s.currentQuestionIndex;
        if (index < 0 || index >= qs.length || s.phase != SessionPhase.revealing) {
          return null;
        }
        final distribution = List<int>.filled(4, 0);
        for (final r in _db.responses.values) {
          if (r.sessionId == sessionId &&
              r.questionIndex == index &&
              r.selectedIndex >= 0 &&
              r.selectedIndex < 4) {
            distribution[r.selectedIndex]++;
          }
        }
        return RevealInfo(
          questionIndex: index,
          correctIndex: qs[index].correctIndex,
          explanation: qs[index].explanation,
          distribution: distribution,
        );
      });

  @override
  Stream<Map<int, AnswerResult>> watchMyResults(String sessionId) =>
      _db.watch(['session:$sessionId'], () {
        final s = _db.sessions[sessionId];
        final me = _db.currentUser?.id;
        if (s == null || me == null) return const <int, AnswerResult>{};
        return {
          for (final r in _db.responses.values)
            if (r.sessionId == sessionId &&
                r.studentId == me &&
                _isRevealed(s, r.questionIndex))
              r.questionIndex: AnswerResult(
                questionIndex: r.questionIndex,
                selectedIndex: r.selectedIndex,
                isCorrect: r.isCorrect,
                pointsAwarded: r.pointsAwarded,
                responseTimeMs: r.responseTimeMs,
              ),
        };
      });

  @override
  Future<SessionParticipant> joinSession({
    required String joinCode,
    AppUser? student,
  }) async {
    final user = student ?? _db.currentUser;
    if (user == null) {
      throw const AppFailure('Not signed in.', code: 'UNAUTHORIZED');
    }
    final session = await findByJoinCode(joinCode);
    if (session == null) {
      throw const AppFailure(
        'No live session with that code.',
        code: 'NOT_FOUND',
        field: 'join_code',
      );
    }
    final existing = _db.participants.values
        .where((p) => p.sessionId == session.id && p.studentId == user.id)
        .firstOrNull;
    if (existing != null) {
      final reconnected = existing.copyWith(connected: true);
      _db.participants[existing.id] = reconnected;
      _db.ping('session:${session.id}');
      return reconnected;
    }
    if (!session.isLobby && !session.allowLateJoin) {
      throw const AppFailure(
        'This session has already started.',
        code: 'CONFLICT',
      );
    }
    final p = SessionParticipant(
      id: newId(),
      sessionId: session.id,
      studentId: user.id,
      displayName: user.name,
      joinedAt: DateTime.now(),
    );
    _db.participants[p.id] = p;
    _db.ping('session:${session.id}');
    return p;
  }

  @override
  Future<void> setConnected({
    required String sessionId,
    String? studentId,
    required bool connected,
  }) async {
    final id = studentId ?? _db.currentUser?.id;
    if (id == null) return;
    final p = _db.participants.values
        .where((p) => p.sessionId == sessionId && p.studentId == id)
        .firstOrNull;
    if (p == null) return;
    _db.participants[p.id] = p.copyWith(connected: connected);
    _db.ping('session:$sessionId');
  }

  QuizSession _require(String sessionId) {
    final s = _db.sessions[sessionId];
    if (s == null) {
      throw const AppFailure('Session not found.', code: 'NOT_FOUND');
    }
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
  /// question that just closed, so analytics and streaks stay consistent.
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
    final ended = s.copyWith(
      status: SessionStatus.ended,
      phase: SessionPhase.revealing,
      endedAt: DateTime.now(),
    );
    _db.sessions[sessionId] = ended;

    // One durable record per player. This is the only storage write a whole
    // session produces, and it happens once, at the end.
    final subject = _db.quizzes[s.quizId]?.subject ?? '';
    final ranked = _participants(sessionId);
    for (var i = 0; i < ranked.length; i++) {
      final p = ranked[i];
      _db.results.add(
        _Played(
          studentId: p.studentId,
          displayName: p.displayName,
          sessionId: sessionId,
          quizId: s.quizId,
          quizTitle: s.quizTitle,
          subject: subject,
          points: p.totalScore,
          correct: p.correctCount,
          answered: p.answeredCount,
          totalQuestions: s.totalQuestions,
          rank: i + 1,
          playedAt: ended.endedAt ?? DateTime.now(),
        ),
      );
    }
    _db.touch(_Col.results);
    _db.ping('session:$sessionId');
    _db.ping('sessions');
    _db.ping('leaderboard');
  }

  @override
  Future<QuizResponse> submitAnswer({
    required String sessionId,
    AppUser? student,
    required int questionIndex,
    required int selectedIndex,
    int responseTimeMs = 0,
  }) async {
    final user = student ?? _db.currentUser;
    if (user == null) {
      throw const AppFailure('Not signed in.', code: 'UNAUTHORIZED');
    }
    final s = _require(sessionId);
    final qs = _sessionQuestions[sessionId]!;
    if (questionIndex != s.currentQuestionIndex ||
        s.phase != SessionPhase.asking ||
        !s.isActive) {
      throw const AppFailure(
        'That question is not accepting answers.',
        code: 'CONFLICT',
      );
    }
    final participant = _db.participants.values
        .where((p) => p.sessionId == sessionId && p.studentId == user.id)
        .firstOrNull;
    if (participant == null) {
      throw const AppFailure('Join the session first.', code: 'NOT_FOUND');
    }
    // Idempotent: repeats, double taps and reconnect replays return the first.
    final prior = _db.responses.values
        .where(
          (r) =>
              r.sessionId == sessionId &&
              r.studentId == user.id &&
              r.questionIndex == questionIndex,
        )
        .firstOrNull;
    if (prior != null) return prior;

    final question = qs[questionIndex];
    final limitMs = question.timeLimitSeconds * 1000;
    // Timed here, from the session's own clock — not from the caller. The
    // `responseTimeMs` argument is ignored, exactly as the server ignores it.
    final startedAt = s.questionStartedAt ?? DateTime.now();
    final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
    final clampedMs = elapsedMs.clamp(0, limitMs);
    final isCorrect =
        selectedIndex >= 0 && selectedIndex == question.correctIndex;

    final scoring = _db.quizzes[s.quizId]?.scoring ?? const ScoringConfig();
    // 750 ms of grace, matching the server.
    final tooLate = elapsedMs > limitMs + 750;
    final points = tooLate
        ? 0
        : scoring.pointsFor(
            isCorrect: isCorrect,
            responseTimeMs: clampedMs,
            timeLimitMs: limitMs,
          );

    final response = QuizResponse(
      id: newId(),
      sessionId: sessionId,
      studentId: user.id,
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
    // Notifies watchers only — a 50-answer burst writes nothing to storage.
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

  static const _windows = <String, Duration?>{
    'week': Duration(days: 7),
    'month': Duration(days: 30),
    'all-time': null,
  };

  /// `period` and `subject` really filter, over the per-session result records.
  /// The old implementation kept one ever-growing cumulative total per student
  /// and ignored both parameters, which made the UI's toggle a dead control.
  List<LeaderboardEntry> _snapshot(String period, String? subject) {
    if (!_windows.containsKey(period)) {
      throw AppFailure(
        'period must be one of: ${_windows.keys.join(', ')}.',
        code: 'VALIDATION',
        field: 'period',
      );
    }
    final window = _windows[period];
    final since = window == null ? null : DateTime.now().subtract(window);
    final wanted = subject?.trim().toLowerCase();

    final byStudent = <String, _Agg>{};
    for (final r in _db.results) {
      if (since != null && r.playedAt.isBefore(since)) continue;
      if (wanted != null &&
          wanted.isNotEmpty &&
          r.subject.toLowerCase() != wanted) {
        continue;
      }
      final agg = byStudent.putIfAbsent(
        r.studentId,
        () => _Agg(r.studentId, r.displayName),
      );
      agg.points += r.points;
      agg.quizzes += 1;
      agg.correct += r.correct;
      agg.answered += r.answered;
      agg.name = r.displayName;
    }

    final entries =
        byStudent.values
            .map(
              (a) => LeaderboardEntry(
                studentId: a.studentId,
                displayName: a.name,
                points: a.points,
                quizzesPlayed: a.quizzes,
                correctRate: a.answered == 0 ? 0 : a.correct / a.answered,
              ),
            )
            .toList()
          ..sort((a, b) {
            final byPoints = b.points.compareTo(a.points);
            return byPoints != 0
                ? byPoints
                : a.displayName.compareTo(b.displayName);
          });

    return [
      for (var i = 0; i < entries.length; i++) entries[i].copyWith(rank: i + 1),
    ];
  }

  @override
  Stream<List<LeaderboardEntry>> watchGlobal({
    String period = 'all-time',
    String? subject,
  }) => _db.watch(['leaderboard'], () => _snapshot(period, subject));

  @override
  Future<List<String>> subjects() async {
    final out = <String>{
      for (final r in _db.results)
        if (r.subject.trim().isNotEmpty) r.subject,
    }.toList()..sort();
    return out;
  }
}

class _Agg {
  _Agg(this.studentId, this.name);
  final String studentId;
  String name;
  int points = 0;
  int quizzes = 0;
  int correct = 0;
  int answered = 0;
}

// ---------------------------------------------------------------------------
// Analytics
// ---------------------------------------------------------------------------

class _Analytics implements AnalyticsRepository {
  _Analytics(this._db);
  final _Db _db;

  /// Totals come from the durable result records; the per-question breakdown
  /// needs individual responses, which this backend keeps in RAM only — so it
  /// covers sessions played in this run. The server-backed implementation has
  /// the full history.
  @override
  Future<QuizAnalytics> quizAnalytics(String quizId) async {
    final played = _db.results.where((r) => r.quizId == quizId).toList();
    final endedIds = _db.sessions.values
        .where((s) => s.quizId == quizId && s.status == SessionStatus.ended)
        .map((s) => s.id)
        .toSet();
    final responses = _db.responses.values
        .where((r) => endedIds.contains(r.sessionId))
        .toList();

    final questions =
        _db.questions.values.where((q) => q.quizId == quizId).toList()
          ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));

    final stats = <QuestionStat>[];
    for (final q in questions) {
      final rs = responses.where((r) => r.questionId == q.id).toList();
      final attempted = rs.where((r) => r.selectedIndex >= 0).toList();
      stats.add(
        QuestionStat(
          questionId: q.id,
          text: q.text,
          answers: attempted.length,
          correct: rs.where((r) => r.isCorrect).length,
          orderIndex: q.orderIndex,
          averageTimeMs: attempted.isEmpty
              ? 0
              : attempted.map((r) => r.responseTimeMs).reduce((a, b) => a + b) ~/
                    attempted.length,
        ),
      );
    }

    final sessionsRun = played.map((r) => r.sessionId).toSet().length;
    final avgScore = played.isEmpty
        ? 0.0
        : played.map((r) => r.points).reduce((a, b) => a + b) / played.length;
    final totalAnswered = played.fold<int>(0, (a, r) => a + r.answered);
    final totalCorrect = played.fold<int>(0, (a, r) => a + r.correct);
    final completion = played.isEmpty
        ? 0.0
        : played
                  .map(
                    (r) => r.totalQuestions == 0
                        ? 0.0
                        : (r.answered / r.totalQuestions).clamp(0.0, 1.0),
                  )
                  .reduce((a, b) => a + b) /
              played.length;

    return QuizAnalytics(
      quizId: quizId,
      sessionsRun: sessionsRun,
      participants: played.length,
      averageScore: avgScore,
      averageCorrectRate: totalAnswered == 0 ? 0 : totalCorrect / totalAnswered,
      completionRate: completion,
      questionStats: stats,
    );
  }

  @override
  Future<List<StudentQuizResult>> studentHistory(String studentId) async {
    final out = [
      for (final r in _db.results)
        if (r.studentId == studentId)
          StudentQuizResult(
            sessionId: r.sessionId,
            quizTitle: r.quizTitle,
            score: r.points,
            rank: r.rank,
            playedAt: r.playedAt,
            correct: r.correct,
            total: r.totalQuestions,
          ),
    ]..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    return out;
  }
}
