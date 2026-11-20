import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/connection.dart';
import '../../core/env.dart';
import '../../core/server_clock.dart';
import 'api_client.dart';

/// One frame from the server: `{type, session_id, data, at}`.
///
/// `data` is a map for most deltas and a **list** for `scoreboard`, so it is
/// kept as `Object?` and narrowed at the use site.
class RealtimeEvent {
  const RealtimeEvent(this.type, this.data, {this.sessionId});

  final String type;
  final Object? data;

  /// The session this frame belongs to; null for connection-level frames.
  final String? sessionId;

  Map<String, dynamic> get map =>
      data is Map ? (data as Map).cast<String, dynamic>() : const {};

  List<Map<String, dynamic>> get rows => data is List
      ? [
          for (final e in data as List)
            if (e is Map) e.cast<String, dynamic>(),
        ]
      : const [];

  @override
  String toString() => 'RealtimeEvent($type)';
}

/// The transport, kept behind an interface so tests can feed frames in without
/// a real socket.
abstract class RealtimeSocket {
  Stream<dynamic> get messages;
  Future<void> get ready;

  /// The close code once the socket has closed, if the server sent one.
  int? get closeCode;

  void send(String frame);
  Future<void> close();
}

typedef RealtimeSocketFactory = RealtimeSocket Function(Uri uri);

class WebSocketRealtimeSocket implements RealtimeSocket {
  WebSocketRealtimeSocket(this._channel);

  factory WebSocketRealtimeSocket.connect(Uri uri) =>
      WebSocketRealtimeSocket(WebSocketChannel.connect(uri));

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get messages => _channel.stream;

  @override
  Future<void> get ready => _channel.ready;

  @override
  int? get closeCode => _channel.closeCode;

  @override
  void send(String frame) => _channel.sink.add(frame);

  @override
  Future<void> close() async {
    try {
      await _channel.sink.close();
    } catch (_) {
      // Already gone.
    }
  }
}

/// Server close code: the access token behind the socket expired.
const int closeTokenExpired = 4001;

/// Holds the single `/ws` socket, joins session rooms and republishes the
/// server's deltas.
///
/// What it deliberately does **not** do: poll. The only refetch is one resync
/// per session after a socket reconnect, emitted on [resyncs].
///
/// What it does to survive a classroom:
///  * **Fresh tokens.** The socket authenticates in its URL, outside the Dio
///    interceptor that refreshes tokens. It used to reconnect with whatever
///    token it had, so a socket that dropped after the 15-minute access token
///    expired retried with a dead token forever. It now refreshes before
///    opening, and again (at most every 30 s) after the server refuses one.
///  * **Heartbeat.** A socket left half-open by a wifi-to-cellular switch looks
///    healthy until TCP gives up. The client pings every [heartbeatInterval]
///    and reconnects when two intervals pass without any frame.
///  * **Resume.** [nudge] skips the backoff when the app returns to the
///    foreground.
///  * **Clock.** Every frame's send time feeds [clock].
class RealtimeClient {
  RealtimeClient({
    required ApiClient api,
    RealtimeSocketFactory? socketFactory,
    Random? random,
    ServerClock? clock,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 15),
    this.heartbeatInterval = const Duration(seconds: 20),
  }) : _api = api,
       _connect = socketFactory ?? WebSocketRealtimeSocket.connect,
       _random = random ?? Random(),
       clock = clock ?? ServerClock();

  final ApiClient _api;
  final RealtimeSocketFactory _connect;
  final Random _random;
  final Duration baseDelay;
  final Duration maxDelay;
  final Duration heartbeatInterval;

  /// Server time estimated from frame timestamps.
  final ServerClock clock;

  final _events = StreamController<RealtimeEvent>.broadcast();
  final _stateCtrl = StreamController<ConnectionState>.broadcast();
  final _resyncCtrl = StreamController<String>.broadcast();
  final Set<String> _rooms = {};

  RealtimeSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  Timer? _retryTimer;
  Timer? _heartbeat;
  Timer? _probe;
  int _attempt = 0;
  bool _wanted = false;
  bool _opening = false;
  bool _connectedBefore = false;
  bool _refreshNext = false;
  DateTime _lastFrameAt = DateTime.now();
  ConnectionState _state = ConnectionState.offline;

  Stream<RealtimeEvent> get events => _events.stream;

  /// Emits a session id when that room must be re-read over REST because the
  /// socket dropped and deltas were missed. Exactly one per session per
  /// reconnect.
  Stream<String> get resyncs => _resyncCtrl.stream;

  ConnectionState get state => _state;

  /// Replays the current value so a late subscriber (a banner widget mounting
  /// mid-session) sees the truth immediately.
  Stream<ConnectionState> states() async* {
    yield _state;
    yield* _stateCtrl.stream;
  }

  bool get isConnected => _state == ConnectionState.connected;

  /// Number of socket open attempts. Test observability.
  int connectAttempts = 0;

  void start() {
    _wanted = true;
    if (_socket == null) unawaited(_open());
  }

  Future<void> stop() async {
    _wanted = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _attempt = 0;
    _connectedBefore = false;
    await _teardown();
    _setState(ConnectionState.offline);
  }

  /// Sign-in / sign-out / token refresh: drop the old socket and reconnect with
  /// the current token.
  void restart() {
    _retryTimer?.cancel();
    _attempt = 0;
    unawaited(_teardown());
    if (_wanted) unawaited(_open());
  }

  /// The app is back in the foreground, or the user tapped "reconnect".
  ///
  /// Reconnecting: retry now instead of waiting out the backoff. Connected:
  /// the socket may be half-open after the device slept, so ping and give it
  /// a few seconds to answer.
  void nudge() {
    if (!_wanted) return;
    if (_state == ConnectionState.connected && _socket != null) {
      final sentAt = DateTime.now();
      _send({'action': 'ping'});
      _probe?.cancel();
      _probe = Timer(_probeTimeout, () {
        if (_lastFrameAt.isBefore(sentAt)) _onClosed();
      });
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    _attempt = 0;
    unawaited(_open());
  }

  Duration get _probeTimeout => heartbeatInterval < const Duration(seconds: 5)
      ? heartbeatInterval
      : const Duration(seconds: 5);

  void subscribe(String sessionId) {
    if (!_rooms.add(sessionId)) return;
    _sendSubscribe(sessionId);
  }

  void unsubscribe(String sessionId) {
    if (!_rooms.remove(sessionId)) return;
    _send({'action': 'unsubscribe', 'session_id': sessionId});
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await _stateCtrl.close();
    await _resyncCtrl.close();
  }

  // ------------------------------------------------------------ internals ---

  void _sendSubscribe(String sessionId) =>
      _send({'action': 'subscribe', 'session_id': sessionId});

  void _send(Map<String, Object?> frame) {
    final socket = _socket;
    if (socket == null || _state != ConnectionState.connected) return;
    try {
      socket.send(jsonEncode(frame));
    } catch (_) {
      // The close handler will schedule a reconnect.
    }
  }

  Future<void> _open() async {
    if (!_wanted || _socket != null || _opening) return;
    _opening = true;
    try {
      if (_state != ConnectionState.connected) {
        _setState(ConnectionState.reconnecting);
      }
      final forced = _refreshNext;
      _refreshNext = false;
      final token = await _api.freshAccessToken(force: forced);
      if (!_wanted || _socket != null) return;
      if (token == null) {
        if (_api.isAuthenticated) {
          // Signed in, but the refresh could not reach the server. Try again.
          _scheduleRetry();
        } else {
          _setState(ConnectionState.offline);
        }
        return;
      }

      connectAttempts++;
      final socket = _connect(Env.wsUri(token));
      _socket = socket;

      _sub = socket.messages.listen(
        _onFrame,
        onError: (_) => _onClosed(),
        onDone: _onClosed,
        cancelOnError: false,
      );

      try {
        await socket.ready;
      } catch (_) {
        // The upgrade failed. Most often the server refused the token, which
        // this device's clock still thinks is valid: refresh before retrying.
        _refreshNext = true;
        _onClosed();
        return;
      }
      if (!_wanted || _socket != socket) return;

      _attempt = 0;
      _lastFrameAt = DateTime.now();
      _setState(ConnectionState.connected);
      _startHeartbeat();

      final reconnect = _connectedBefore;
      _connectedBefore = true;
      for (final id in _rooms) {
        _sendSubscribe(id);
        // One resync per room, and only after an actual reconnect: the first
        // connection's snapshot is fetched by the session channel itself.
        if (reconnect && !_resyncCtrl.isClosed) _resyncCtrl.add(id);
      }
    } finally {
      _opening = false;
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      if (_state != ConnectionState.connected) return;
      final silentFor = DateTime.now().difference(_lastFrameAt);
      if (silentFor > heartbeatInterval * 2) {
        // Nothing — not even a pong — for two intervals: the link is dead
        // even though the socket never reported closing.
        _onClosed();
        return;
      }
      _send({'action': 'ping'});
    });
  }

  void _onFrame(dynamic raw) {
    final receivedAt = DateTime.now();
    _lastFrameAt = receivedAt;
    if (raw is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final at = DateTime.tryParse((decoded['at'] as String?) ?? '');
    if (at != null) clock.sample(at, receivedAt: receivedAt);
    final type = decoded['type'];
    if (type is! String) return;
    if (!_events.isClosed) {
      _events.add(
        RealtimeEvent(
          type,
          decoded['data'],
          sessionId: decoded['session_id'] as String?,
        ),
      );
    }
  }

  void _onClosed() {
    // A failed upgrade reports twice (the ready future and the stream's
    // onDone); only the first schedules a retry.
    if (_socket == null &&
        (_state == ConnectionState.offline || (_retryTimer?.isActive ?? false))) {
      return;
    }
    final code = _socket?.closeCode;
    unawaited(_teardown());
    if (!_wanted) {
      _setState(ConnectionState.offline);
      return;
    }
    _setState(ConnectionState.reconnecting);
    if (code == closeTokenExpired) {
      // Expected every 15 minutes: refresh and come straight back.
      _refreshNext = true;
      _attempt = 0;
    }
    _scheduleRetry();
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    final exponent = _attempt.clamp(0, 6);
    final raw = baseDelay.inMilliseconds * pow(2, exponent);
    final capped = min(raw.toDouble(), maxDelay.inMilliseconds.toDouble());
    // +/- 25% jitter so a classroom full of dropped clients does not all
    // reconnect on the same millisecond.
    final jittered = capped * (0.75 + _random.nextDouble() * 0.5);
    _attempt++;
    _retryTimer = Timer(
      Duration(milliseconds: jittered.round()),
      () => unawaited(_open()),
    );
  }

  Future<void> _teardown() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _probe?.cancel();
    _probe = null;
    final sub = _sub;
    final socket = _socket;
    _sub = null;
    _socket = null;
    await sub?.cancel();
    await socket?.close();
  }

  void _setState(ConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateCtrl.isClosed) _stateCtrl.add(next);
  }
}
