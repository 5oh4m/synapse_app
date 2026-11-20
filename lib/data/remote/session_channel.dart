import 'dart:async';

import '../../core/failure.dart';
import '../../models/enums.dart';
import '../../models/quiz_session.dart';
import '../../models/response.dart';
import '../../models/reveal.dart';
import '../../models/session_participant.dart';
import 'realtime_client.dart';

export '../../models/reveal.dart' show RevealInfo, AnswerResult;

typedef AnswerCount = ({int answered, int total});

/// What `GET /sessions/:id/current-question` knows about a revealed question:
/// the room-wide reveal plus the caller's own result.
typedef RevealSnapshot = ({RevealInfo reveal, AnswerResult? mine});

/// Latest-value broadcast cell. New listeners get the current value first, so a
/// widget that mounts mid-session renders immediately instead of waiting for
/// the next delta.
class _Replay<T> {
  _Replay(this._value);

  T _value;
  bool _hasValue = false;
  final _ctrl = StreamController<T>.broadcast();

  T get value => _value;
  bool get hasValue => _hasValue;

  void set(T next) {
    _value = next;
    _hasValue = true;
    if (!_ctrl.isClosed) _ctrl.add(next);
  }

  Stream<T> stream() async* {
    if (_hasValue) yield _value;
    yield* _ctrl.stream;
  }

  Future<void> close() => _ctrl.close();
}

/// One live session's state, maintained from WebSocket deltas.
///
/// Lifecycle: the first stream listener joins the server room and takes one
/// REST snapshot; the last listener to go away leaves the room. After that the
/// only network traffic is the server's own deltas and a single resync per
/// reconnect. A reveal costs no request at all: `question.revealed` carries the
/// key and the distribution, and `answer.result` carries this player's outcome.
class SessionChannel {
  SessionChannel({
    required this.sessionId,
    required RealtimeClient realtime,
    required Future<QuizSession?> Function() fetchSession,
    required Future<List<SessionParticipant>> Function() fetchParticipants,
    required Future<List<QuizResponse>> Function() fetchResponses,
    Future<RevealSnapshot?> Function(int index)? fetchReveal,
  }) : _realtime = realtime,
       _fetchSession = fetchSession,
       _fetchParticipants = fetchParticipants,
       _fetchResponses = fetchResponses,
       _fetchReveal = fetchReveal;

  final String sessionId;
  final RealtimeClient _realtime;
  final Future<QuizSession?> Function() _fetchSession;
  final Future<List<SessionParticipant>> Function() _fetchParticipants;
  final Future<List<QuizResponse>> Function() _fetchResponses;
  final Future<RevealSnapshot?> Function(int index)? _fetchReveal;

  final _session = _Replay<QuizSession?>(null);
  final _participants = _Replay<List<SessionParticipant>>(const []);
  final _responses = _Replay<List<QuizResponse>>(const []);
  final _answers = _Replay<AnswerCount>((answered: 0, total: 0));
  final _reveals = _Replay<RevealInfo?>(null);
  final _myResults = _Replay<Map<int, AnswerResult>>(const {});

  StreamSubscription<String>? _resyncSub;
  int _listeners = 0;
  bool _responsesForbidden = false;
  int _lastIndex = -1;

  /// Number of REST resyncs performed after a reconnect. Test observability.
  int resyncs = 0;

  /// Number of full snapshot fetches (initial + resync). Test observability.
  int snapshotFetches = 0;

  /// Number of host `/responses` reads. Test observability: a reveal must not
  /// trigger one.
  int responseFetches = 0;

  bool get isActive => _listeners > 0;

  Stream<QuizSession?> session() => _track(_session.stream());
  Stream<List<SessionParticipant>> participants() =>
      _track(_participants.stream());
  Stream<List<QuizResponse>> responses() => _track(_responses.stream());
  Stream<AnswerCount> answerCount() => _track(_answers.stream());
  Stream<RevealInfo?> reveals() => _track(_reveals.stream());
  Stream<Map<int, AnswerResult>> myResults() => _track(_myResults.stream());

  QuizSession? get currentSession => _session.value;

  /// Applies a frame. Called by [SessionHub]; never polls anything.
  void handle(RealtimeEvent event) {
    switch (event.type) {
      case 'session.state':
        _applySessionState(event.map);
      case 'participant.joined':
        _applyJoined(event.map);
      case 'participant.presence':
        _applyPresence(event.map);
      case 'answer.count':
        final m = event.map;
        _answers.set((
          answered: (m['answered'] as num?)?.toInt() ?? 0,
          total: (m['total'] as num?)?.toInt() ?? _participants.value.length,
        ));
      case 'question.revealed':
        _reveals.set(RevealInfo.fromJson(event.map, fallbackIndex: _lastIndex));
      case 'answer.result':
        _mergeResult(AnswerResult.fromJson(event.map));
      case 'scoreboard':
        _applyScoreboard(event.rows);
      case 'session.ended':
        _applyEnded(event.map);
      default:
        break;
    }
  }

  /// Merges a participant the local device just created via `POST
  /// /sessions/join`, so the roster is correct without a refetch.
  void mergeParticipant(SessionParticipant participant) {
    final next = [..._participants.value];
    final at = next.indexWhere((p) => p.id == participant.id);
    if (at == -1) {
      next.add(participant);
    } else {
      next[at] = participant;
    }
    _participants.set(_sorted(next));
    _bumpTotal();
  }

  void setSession(QuizSession session) {
    _lastIndex = session.currentQuestionIndex;
    _session.set(session);
  }

  Future<void> dispose() async {
    await _resyncSub?.cancel();
    _resyncSub = null;
    await _session.close();
    await _participants.close();
    await _responses.close();
    await _answers.close();
    await _reveals.close();
    await _myResults.close();
  }

  // ------------------------------------------------------------ internals ---

  Stream<S> _track<S>(Stream<S> source) {
    late StreamController<S> ctrl;
    StreamSubscription<S>? sub;
    ctrl = StreamController<S>(
      onListen: () {
        _retain();
        sub = source.listen(
          ctrl.add,
          onError: ctrl.addError,
          onDone: ctrl.close,
        );
      },
      onCancel: () async {
        await sub?.cancel();
        _release();
      },
    );
    return ctrl.stream;
  }

  void _retain() {
    _listeners++;
    if (_listeners > 1) return;
    _realtime.subscribe(sessionId);
    _resyncSub = _realtime.resyncs.listen((id) {
      if (id != sessionId) return;
      resyncs++;
      unawaited(_snapshot());
    });
    unawaited(_snapshot());
  }

  void _release() {
    _listeners--;
    if (_listeners > 0) return;
    _listeners = 0;
    _realtime.unsubscribe(sessionId);
    unawaited(_resyncSub?.cancel());
    _resyncSub = null;
  }

  /// The one and only refetch path: first listener, and one per reconnect.
  Future<void> _snapshot() async {
    snapshotFetches++;
    QuizSession? session;
    try {
      session = await _fetchSession();
      if (session != null) {
        final movedOn = session.currentQuestionIndex != _lastIndex;
        _lastIndex = session.currentQuestionIndex;
        _session.set(session);
        if (movedOn) _reveals.set(null);
      }
    } on AppFailure {
      // Leave the last known state in place; the banner already says we are
      // reconnecting.
    }
    try {
      final roster = await _fetchParticipants();
      _participants.set(_sorted(roster));
      _bumpTotal();
    } on AppFailure {
      /* keep last good roster */
    }
    await _loadResponses();
    if (session != null) await _restoreReveal(session);
  }

  /// A device that (re)connects during a reveal missed `question.revealed` and
  /// its own `answer.result`. Rebuild both from one read.
  Future<void> _restoreReveal(QuizSession session) async {
    final fetch = _fetchReveal;
    final index = session.currentQuestionIndex;
    if (fetch == null || index < 0) return;
    if (session.phase != SessionPhase.revealing) return;
    if (_reveals.value?.questionIndex == index) return;
    try {
      final snap = await fetch(index);
      if (snap == null || _lastIndex != index) return;
      _reveals.set(snap.reveal);
      final mine = snap.mine;
      if (mine != null) _mergeResult(mine);
    } on AppFailure {
      /* the next reveal frame will bring it */
    }
  }

  Future<void> _loadResponses() async {
    if (_responsesForbidden) return;
    try {
      responseFetches++;
      _responses.set(await _fetchResponses());
    } on AppFailure catch (e) {
      // `/responses` is host-only; a student gets 404. Ask once, then stop.
      if (e.isNotFound || e.code == 'FORBIDDEN') _responsesForbidden = true;
    }
  }

  void _mergeResult(AnswerResult result) {
    if (result.questionIndex < 0) return;
    _myResults.set({..._myResults.value, result.questionIndex: result});
  }

  void _applySessionState(Map<String, dynamic> data) {
    if (data.isEmpty) return;
    final session = QuizSession.fromJson(data);
    final movedOn = session.currentQuestionIndex != _lastIndex;
    _lastIndex = session.currentQuestionIndex;
    _session.set(session);
    if (movedOn) {
      // New question: nobody has answered it yet. Do not wait for the first
      // coalesced tick to say so.
      _answers.set((answered: 0, total: _participants.value.length));
      _reveals.set(null);
    }
  }

  void _applyJoined(Map<String, dynamic> data) {
    final id = data['id'] as String?;
    if (id == null) return;
    if (_participants.value.any((p) => p.id == id)) return;
    _participants.set(
      _sorted([
        ..._participants.value,
        SessionParticipant(
          id: id,
          sessionId: sessionId,
          // The delta carries counts and names only — never identities
          // (docs/API.md). The owning device fills its own user id in via
          // [mergeParticipant].
          studentId: '',
          displayName: (data['display_name'] as String?) ?? 'Player',
          joinedAt: DateTime.now(),
        ),
      ]),
    );
    _bumpTotal();
  }

  void _applyPresence(Map<String, dynamic> data) {
    final id = data['id'] as String?;
    final connected = data['connected'];
    if (id == null || connected is! bool) return;
    final list = _participants.value;
    final at = list.indexWhere((p) => p.id == id);
    if (at == -1 || list[at].connected == connected) return;
    _participants.set([
      for (var i = 0; i < list.length; i++)
        i == at ? list[i].copyWith(connected: connected) : list[i],
    ]);
  }

  void _applyScoreboard(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return;
    final byId = {for (final p in _participants.value) p.id: p};
    final out = <SessionParticipant>[];
    for (final row in rows) {
      final id = row['participant_id'] as String?;
      if (id == null) continue;
      final name = (row['display_name'] as String?) ?? 'Player';
      final score = (row['total_score'] as num?)?.toInt() ?? 0;
      final correct = (row['correct_count'] as num?)?.toInt();
      final answered = (row['answered_count'] as num?)?.toInt();
      final existing = byId.remove(id);
      out.add(
        existing == null
            ? SessionParticipant(
                id: id,
                sessionId: sessionId,
                studentId: '',
                displayName: name,
                joinedAt: DateTime.now(),
                totalScore: score,
                correctCount: correct ?? 0,
                answeredCount: answered ?? 0,
              )
            : existing.copyWith(
                displayName: name,
                totalScore: score,
                correctCount: correct ?? existing.correctCount,
                answeredCount: answered ?? existing.answeredCount,
              ),
      );
    }
    // Anyone the scoreboard did not mention (shouldn't happen) is kept.
    out.addAll(byId.values);
    _participants.set(_sorted(out));
    _bumpTotal();
  }

  void _applyEnded(Map<String, dynamic> data) {
    final current = _session.value;
    if (current != null && !current.isEnded) {
      _session.set(
        current.copyWith(
          status: SessionStatus.ended,
          phase: SessionPhase.revealing,
          endedAt:
              DateTime.tryParse((data['ended_at'] as String?) ?? '') ??
              DateTime.now(),
        ),
      );
    }
    // Once, at the end, for the host's post-game analytics view.
    unawaited(_loadResponses());
  }

  void _bumpTotal() {
    final total = _participants.value.length;
    final current = _answers.value;
    if (current.total != total) {
      _answers.set((answered: current.answered, total: total));
    }
  }

  List<SessionParticipant> _sorted(List<SessionParticipant> list) {
    final out = [...list];
    out.sort((a, b) {
      final byScore = b.totalScore.compareTo(a.totalScore);
      return byScore != 0 ? byScore : a.joinedAt.compareTo(b.joinedAt);
    });
    return out;
  }
}

/// Owns the per-session channels and routes frames to them.
class SessionHub {
  SessionHub({required RealtimeClient realtime}) : _realtime = realtime {
    _sub = _realtime.events.listen(_route);
  }

  final RealtimeClient _realtime;
  final Map<String, SessionChannel> _channels = {};
  StreamSubscription<RealtimeEvent>? _sub;

  SessionChannel channel(
    String sessionId, {
    required Future<QuizSession?> Function() fetchSession,
    required Future<List<SessionParticipant>> Function() fetchParticipants,
    required Future<List<QuizResponse>> Function() fetchResponses,
    Future<RevealSnapshot?> Function(int index)? fetchReveal,
  }) => _channels.putIfAbsent(
    sessionId,
    () => SessionChannel(
      sessionId: sessionId,
      realtime: _realtime,
      fetchSession: fetchSession,
      fetchParticipants: fetchParticipants,
      fetchResponses: fetchResponses,
      fetchReveal: fetchReveal,
    ),
  );

  SessionChannel? existing(String sessionId) => _channels[sessionId];

  Future<void> dispose() async {
    await _sub?.cancel();
    for (final c in _channels.values) {
      await c.dispose();
    }
    _channels.clear();
  }

  /// Every frame names its session (`session_id`), so it reaches that
  /// channel only. Frames from an older server without the field fall back to
  /// the payload's own id, then to every active channel.
  void _route(RealtimeEvent event) {
    final id =
        event.sessionId ??
        switch (event.type) {
          'session.state' => event.map['id'] as String?,
          'session.ended' => event.map['session_id'] as String?,
          _ => null,
        };
    if (id != null) {
      _channels[id]?.handle(event);
      return;
    }
    for (final channel in _channels.values) {
      if (channel.isActive) channel.handle(event);
    }
  }
}
