// Regression tests for the realtime client, written from the second audit's
// proofs: each one failed against the code the audit reviewed.
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizzle/core/connection.dart' as net;
import 'package:quizzle/data/local/token_store.dart';
import 'package:quizzle/data/remote/api_client.dart';
import 'package:quizzle/data/remote/realtime_client.dart';
import 'package:quizzle/data/remote/session_channel.dart';
import 'package:quizzle/features/live_session/connection_banner.dart';
import 'package:quizzle/models/enums.dart';
import 'package:quizzle/models/quiz_session.dart';
import 'package:quizzle/models/session_participant.dart';
import 'package:quizzle/state/providers.dart';

/// An unsigned JWT with the given expiry. The client only reads `exp`.
String jwt({required Duration expiresIn, String sub = 'u1'}) {
  String part(Map<String, Object> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp = DateTime.now().add(expiresIn).millisecondsSinceEpoch ~/ 1000;
  return '${part({'alg': 'HS256'})}.${part({'sub': sub, 'exp': exp})}.sig';
}

/// Answers `/auth/refresh` like the server, or fails the way a dead network
/// does.
class _RefreshAdapter implements HttpClientAdapter {
  _RefreshAdapter({this.reachable = true});

  bool reachable;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (!reachable) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'no route to host',
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'accessToken': jwt(expiresIn: const Duration(minutes: 15)),
        'refreshToken': 'rotated-$calls',
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeSocket implements RealtimeSocket {
  _FakeSocket({this.accept = true});

  final bool accept;
  final _ctrl = StreamController<dynamic>();
  final sent = <String>[];

  @override
  int? closeCode;

  @override
  Stream<dynamic> get messages => _ctrl.stream;

  @override
  Future<void> get ready =>
      accept ? Future.value() : Future.error(StateError('HTTP 401'));

  @override
  void send(String frame) => sent.add(frame);

  @override
  Future<void> close() async {
    if (!_ctrl.isClosed) await _ctrl.close();
  }

  void push(Map<String, Object?> frame) => _ctrl.add(jsonEncode(frame));

  void drop({int? code}) {
    closeCode = code;
    _ctrl.close();
  }
}

Future<ApiClient> _api(String accessToken, _RefreshAdapter adapter) async {
  final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9/api'))
    ..httpClientAdapter = adapter;
  final api = ApiClient(dio: dio, tokenStore: MemoryTokenStore());
  await api.setTokens(
    AuthTokens(accessToken: accessToken, refreshToken: 'refresh-1'),
  );
  return api;
}

Future<void> _settle([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('MD-1: a socket that drops after the token expired refreshes, then reconnects', () async {
    final adapter = _RefreshAdapter();
    final api = await _api(jwt(expiresIn: const Duration(minutes: 10)), adapter);
    final tokens = <String>[];
    final sockets = <_FakeSocket>[];
    final rt = RealtimeClient(
      api: api,
      baseDelay: const Duration(milliseconds: 1),
      maxDelay: const Duration(milliseconds: 4),
      socketFactory: (uri) {
        tokens.add(uri.queryParameters['token']!);
        final s = _FakeSocket();
        sockets.add(s);
        return s;
      },
    );
    rt.start();
    await _settle();
    expect(rt.state, net.ConnectionState.connected);

    // Fifteen minutes later the token has expired and the wifi blips.
    await api.setTokens(
      AuthTokens(
        accessToken: jwt(expiresIn: const Duration(minutes: -1)),
        refreshToken: 'refresh-1',
      ),
    );
    sockets.last.drop();
    await _settle(120);

    expect(api.refreshAttempts, 1, reason: 'the socket never refreshed');
    expect(rt.state, net.ConnectionState.connected);
    expect(tokens.last, isNot(tokens.first));
    expect(ApiClient.jwtExpiry(tokens.last)!.isAfter(DateTime.now()), isTrue);
    await rt.dispose();
  });

  test('MD-1: a refused upgrade forces one refresh even if the token looks valid', () async {
    final adapter = _RefreshAdapter();
    final api = await _api(jwt(expiresIn: const Duration(minutes: 10)), adapter);
    var n = 0;
    final rt = RealtimeClient(
      api: api,
      baseDelay: const Duration(milliseconds: 1),
      maxDelay: const Duration(milliseconds: 4),
      // The server's clock says the token is dead: refuse the first upgrade.
      socketFactory: (_) => _FakeSocket(accept: n++ > 0),
    );
    rt.start();
    await _settle(120);
    expect(api.refreshAttempts, 1);
    expect(rt.state, net.ConnectionState.connected);
    await rt.dispose();
  });

  test('MD-10: close code 4001 (token expired) refreshes and comes straight back', () async {
    final adapter = _RefreshAdapter();
    final api = await _api(jwt(expiresIn: const Duration(minutes: 10)), adapter);
    final sockets = <_FakeSocket>[];
    final rt = RealtimeClient(
      api: api,
      baseDelay: const Duration(milliseconds: 1),
      socketFactory: (_) {
        final s = _FakeSocket();
        sockets.add(s);
        return s;
      },
    );
    rt.start();
    await _settle();
    sockets.last.drop(code: closeTokenExpired);
    await _settle(120);
    expect(api.refreshAttempts, 1);
    expect(sockets.length, 2);
    expect(rt.state, net.ConnectionState.connected);
    await rt.dispose();
  });

  test('a refresh that cannot reach the server does not sign the student out', () async {
    final adapter = _RefreshAdapter(reachable: false);
    final api = await _api(jwt(expiresIn: const Duration(minutes: -1)), adapter);
    var signedOut = false;
    final sub = api.onSignedOut.listen((_) => signedOut = true);

    expect(await api.freshAccessToken(), isNull);
    expect(api.isAuthenticated, isTrue, reason: 'a wifi blip ended the session');
    expect(signedOut, isFalse);
    await sub.cancel();
  });

  test('MD-10: a silent, half-open socket is detected by the heartbeat', () async {
    final adapter = _RefreshAdapter();
    final api = await _api(jwt(expiresIn: const Duration(minutes: 10)), adapter);
    final sockets = <_FakeSocket>[];
    final rt = RealtimeClient(
      api: api,
      baseDelay: const Duration(milliseconds: 1),
      heartbeatInterval: const Duration(milliseconds: 20),
      socketFactory: (_) {
        final s = _FakeSocket();
        sockets.add(s);
        return s;
      },
    );
    rt.start();
    // The first socket never answers anything, pings included.
    await _settle(150);
    expect(sockets.first.sent.any((f) => f.contains('"ping"')), isTrue);
    expect(rt.connectAttempts, greaterThan(1), reason: 'a dead link looked healthy');
    await rt.dispose();
  });

  test('MD-2: the banner reports a dropped socket', () async {
    final adapter = _RefreshAdapter();
    final api = await _api(jwt(expiresIn: const Duration(minutes: 10)), adapter);
    _FakeSocket? socket;
    final rt = RealtimeClient(
      api: api,
      baseDelay: const Duration(seconds: 30),
      socketFactory: (_) => socket = _FakeSocket(),
    );
    final container = ProviderContainer(
      overrides: [connectionStateProvider.overrideWith((ref) => rt.states())],
    );
    final banner = container.listen(liveConnectionProvider, (_, _) {});
    rt.start();
    await _settle();
    expect(banner.read(), LiveConnection.connected);

    socket!.drop();
    await _settle();
    expect(banner.read(), LiveConnection.reconnecting);

    banner.close();
    container.dispose();
    await rt.dispose();
  });

  test('frames carry server time: the clock learns the offset', () async {
    final adapter = _RefreshAdapter();
    final api = await _api(jwt(expiresIn: const Duration(minutes: 10)), adapter);
    _FakeSocket? socket;
    final rt = RealtimeClient(api: api, socketFactory: (_) => socket = _FakeSocket());
    rt.start();
    await _settle();
    // The server is 5 s ahead of this device.
    socket!.push({
      'type': 'hello',
      'data': {},
      'at': DateTime.now().add(const Duration(seconds: 5)).toUtc().toIso8601String(),
    });
    await _settle();
    expect(rt.clock.offset.inMilliseconds, closeTo(5000, 250));
    await rt.dispose();
  });

  group('session channel', () {
    late ApiClient api;
    late RealtimeClient rt;
    late SessionHub hub;
    late _FakeSocket socket;

    QuizSession session(String id, {int index = 0, SessionPhase phase = SessionPhase.asking}) =>
        QuizSession(
          id: id,
          quizId: 'q',
          quizTitle: 'Q',
          hostId: 'h',
          joinCode: 'ABC234',
          status: SessionStatus.active,
          currentQuestionIndex: index,
          totalQuestions: 3,
          phase: phase,
          createdAt: DateTime.now(),
        );

    setUp(() async {
      api = await _api(jwt(expiresIn: const Duration(minutes: 10)), _RefreshAdapter());
      rt = RealtimeClient(api: api, socketFactory: (_) => socket = _FakeSocket());
      hub = SessionHub(realtime: rt);
      rt.start();
      await _settle();
    });

    tearDown(() async {
      await hub.dispose();
      await rt.dispose();
    });

    SessionChannel open(String id, {List<SessionParticipant> roster = const []}) =>
        hub.channel(
          id,
          fetchSession: () async => session(id),
          fetchParticipants: () async => roster,
          fetchResponses: () async => const [],
        );

    test('MD-6: a frame reaches only the session it names', () async {
      final a = open('A');
      final b = open('B');
      final countsA = <int>[];
      final countsB = <int>[];
      final subA = a.answerCount().listen((c) => countsA.add(c.answered));
      final subB = b.answerCount().listen((c) => countsB.add(c.answered));
      await _settle();

      socket.push({'type': 'answer.count', 'session_id': 'A', 'data': {'answered': 7, 'total': 9}});
      await _settle();
      expect(countsA.last, 7);
      expect(countsB.contains(7), isFalse, reason: 'session B took session A\'s count');
      await subA.cancel();
      await subB.cancel();
    });

    test('FN-6/PERF-5: a reveal delivers the key and my result with no request', () async {
      final ch = open('S');
      RevealInfo? reveal;
      Map<int, AnswerResult> mine = const {};
      final s1 = ch.reveals().listen((r) => reveal = r);
      final s2 = ch.myResults().listen((m) => mine = m);
      await _settle();
      final fetchesBefore = ch.responseFetches;

      socket.push({
        'type': 'question.revealed',
        'session_id': 'S',
        'data': {'question_index': 0, 'correct_index': 2, 'explanation': 'x', 'distribution': [1, 0, 3, 0]},
      });
      socket.push({
        'type': 'answer.result',
        'session_id': 'S',
        'data': {'question_index': 0, 'selected_index': 2, 'is_correct': true, 'points_awarded': 870},
      });
      await _settle();

      expect(reveal?.correctIndex, 2);
      expect(reveal?.distribution, [1, 0, 3, 0]);
      expect(mine[0]?.pointsAwarded, 870);
      expect(ch.responseFetches, fetchesBefore, reason: 'the reveal refetched responses');
      await s1.cancel();
      await s2.cancel();
    });

    test('MD-9: presence frames update the roster', () async {
      final ch = open(
        'P',
        roster: [
          SessionParticipant(
            id: 'p1',
            sessionId: 'P',
            studentId: 's1',
            displayName: 'Sam',
            joinedAt: DateTime.now(),
          ),
        ],
      );
      List<SessionParticipant> roster = const [];
      final sub = ch.participants().listen((r) => roster = r);
      await _settle();
      socket.push({'type': 'participant.presence', 'session_id': 'P', 'data': {'id': 'p1', 'connected': false}});
      await _settle();
      expect(roster.single.connected, isFalse);
      await sub.cancel();
    });
  });
}
