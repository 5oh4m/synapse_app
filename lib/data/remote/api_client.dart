import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/env.dart';
import '../../core/failure.dart';
import '../local/token_store.dart';

/// Marks a request that must not carry (or refresh) a bearer token:
/// `/auth/login`, `/auth/register`, `/auth/refresh`.
const _skipAuth = 'quizzle.skipAuth';

/// Marks a request that has already been replayed after a refresh, so a second
/// 401 cannot start an infinite retry loop.
const _isRetry = 'quizzle.isRetry';

/// The one HTTP client. Everything above it (repositories, generators,
/// extraction) goes through here, so there is exactly one place that knows
/// about tokens, refresh and the error envelope.
class ApiClient {
  ApiClient({Dio? dio, TokenStore? tokenStore, String? baseUrl})
    : tokenStore = tokenStore ?? MemoryTokenStore(),
      dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
              headers: {'content-type': 'application/json'},
            ),
          ) {
    this.dio.options.baseUrl = baseUrl ?? this.dio.options.baseUrl;
    if (this.dio.options.baseUrl.isEmpty) {
      this.dio.options.baseUrl = Env.apiRoot;
    }
    this.dio.interceptors.add(
      InterceptorsWrapper(onRequest: _onRequest, onError: _onError),
    );
  }

  final Dio dio;
  final TokenStore tokenStore;

  AuthTokens? _tokens;

  /// The single in-flight refresh. Every concurrent 401 awaits *this* future
  /// rather than starting its own — that is the whole point of the queue.
  Future<_RefreshResult>? _refreshInFlight;

  /// Number of `POST /auth/refresh` calls actually made. Exposed so the tests
  /// can assert "N concurrent 401s cause exactly one refresh".
  int refreshAttempts = 0;

  final _signedOut = StreamController<String>.broadcast();

  /// Emits when refresh failed and the session had to be dropped. The backend
  /// listens and clears the current user.
  Stream<String> get onSignedOut => _signedOut.stream;

  AuthTokens? get tokens => _tokens;
  String? get accessToken => _tokens?.accessToken;
  bool get isAuthenticated => _tokens != null;

  /// Loads any persisted session at boot.
  Future<AuthTokens?> restore() async {
    _tokens = await tokenStore.read();
    return _tokens;
  }

  Future<void> setTokens(AuthTokens tokens) async {
    _tokens = tokens;
    await tokenStore.write(tokens);
  }

  Future<void> clearTokens() async {
    _tokens = null;
    await tokenStore.clear();
  }

  Future<void> dispose() async {
    await _signedOut.close();
    dio.close(force: true);
  }

  // ---------------------------------------------------------------- verbs ---

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send(() => dio.get<dynamic>(path, queryParameters: _clean(query)));

  Future<List<dynamic>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final data = await get(path, query: query);
    if (data is List) return data;
    if (data is Map && data['items'] is List) return data['items'] as List;
    return const [];
  }

  Future<Map<String, dynamic>> getMap(
    String path, {
    Map<String, dynamic>? query,
  }) async => _asMap(await get(path, query: query));

  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    bool authenticated = true,
  }) async => _asMap(
    await _send(
      () => dio.post<dynamic>(
        path,
        data: body,
        options: Options(extra: {if (!authenticated) _skipAuth: true}),
      ),
    ),
  );

  Future<Map<String, dynamic>> postMultipart(
    String path,
    FormData form,
  ) async => _asMap(
    await _send(
      () => dio.post<dynamic>(
        path,
        data: form,
        options: Options(contentType: 'multipart/form-data'),
      ),
    ),
  );

  Future<Map<String, dynamic>> put(String path, {Object? body}) async =>
      _asMap(await _send(() => dio.put<dynamic>(path, data: body)));

  Future<Map<String, dynamic>> patch(String path, {Object? body}) async =>
      _asMap(await _send(() => dio.patch<dynamic>(path, data: body)));

  Future<void> delete(String path) async {
    await _send(() => dio.delete<dynamic>(path));
  }

  Future<dynamic> _send(Future<Response<dynamic>> Function() run) async {
    try {
      final res = await run();
      return res.data;
    } on DioException catch (e) {
      throw failureFrom(e);
    }
  }

  Map<String, dynamic> _asMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    return <String, dynamic>{};
  }

  Map<String, dynamic>? _clean(Map<String, dynamic>? q) {
    if (q == null) return null;
    final out = <String, dynamic>{};
    q.forEach((k, v) {
      if (v != null) out[k] = v;
    });
    return out.isEmpty ? null : out;
  }

  // --------------------------------------------------------- interceptor ---

  void _onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.extra[_skipAuth] != true) {
      final token = _tokens?.accessToken;
      if (token != null) options.headers['authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  Future<void> _onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final req = err.requestOptions;
    final status = err.response?.statusCode;

    final refreshable =
        status == 401 &&
        req.extra[_skipAuth] != true &&
        req.extra[_isRetry] != true &&
        _tokens != null;

    if (!refreshable) return handler.next(err);

    // The access token this request actually used. If it is already stale —
    // another request refreshed while this one was in flight — we can retry
    // immediately without a second refresh.
    final used = (req.headers['authorization'] as String?)?.replaceFirst(
      'Bearer ',
      '',
    );

    final current = _tokens;
    final _RefreshResult result;
    if (current != null && used != null && current.accessToken != used) {
      result = _RefreshResult.ok(current);
    } else {
      result = await _refreshOnce();
    }

    final fresh = result.tokens;
    if (fresh == null) {
      // Only a refresh the server *rejected* ends the session. One that could
      // not reach the server (a wifi blip mid-quiz) used to sign the student
      // out too; now the request just fails and the session survives.
      if (result.rejected) {
        await _signOut('Your session expired. Sign in again.');
      }
      return handler.next(err);
    }

    try {
      handler.resolve(await _replay(req, fresh.accessToken));
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  /// A current access token for a caller that cannot go through the Dio
  /// interceptor — the WebSocket upgrade, which authenticates in the URL.
  ///
  /// Refreshes first when the token expires within [leeway], or when [force]
  /// is set because the server just refused it (this device's clock may
  /// disagree with the server's about expiry). Forced refreshes are spaced at
  /// least [minForcedGap] apart so a flapping socket cannot churn the refresh
  /// token. Returns null when there is no usable token right now; check
  /// [isAuthenticated] to tell "signed out" from "server unreachable".
  Future<String?> freshAccessToken({
    bool force = false,
    Duration leeway = const Duration(seconds: 60),
    Duration minForcedGap = const Duration(seconds: 30),
  }) async {
    final current = _tokens;
    if (current == null) return null;
    final expiring = _expiresWithin(current.accessToken, leeway);
    final recentlyRefreshed =
        _lastRefreshAt != null &&
        DateTime.now().difference(_lastRefreshAt!) < minForcedGap;
    if (!expiring && (!force || recentlyRefreshed)) return current.accessToken;

    final result = await _refreshOnce();
    if (result.tokens != null) return result.tokens!.accessToken;
    if (result.rejected) {
      await _signOut('Your session expired. Sign in again.');
    }
    return null;
  }

  DateTime? _lastRefreshAt;

  /// Reads `exp` from a JWT without verifying it — only to decide whether to
  /// refresh. The server remains the only judge of validity. An unreadable
  /// token counts as expiring, which just triggers a refresh.
  static bool _expiresWithin(String jwt, Duration leeway) {
    final exp = jwtExpiry(jwt);
    if (exp == null) return true;
    return exp.isBefore(DateTime.now().add(leeway));
  }

  /// `exp` of a JWT as a UTC instant, or null if it cannot be read.
  static DateTime? jwtExpiry(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final exp = (jsonDecode(payload) as Map)['exp'];
      if (exp is! num) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        (exp * 1000).round(),
        isUtc: true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Coalesces concurrent refreshes onto one request.
  Future<_RefreshResult> _refreshOnce() {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final future = _performRefresh();
    _refreshInFlight = future;
    // Cleared only after the awaiting callers have been handed the result.
    future.whenComplete(() => _refreshInFlight = null);
    return future;
  }

  Future<_RefreshResult> _performRefresh() async {
    final current = _tokens;
    if (current == null) return const _RefreshResult.rejected();
    refreshAttempts++;
    try {
      final res = await dio.post<dynamic>(
        '/auth/refresh',
        data: {'refreshToken': current.refreshToken},
        options: Options(extra: {_skipAuth: true}),
      );
      final data = _asMap(res.data);
      final access = data['accessToken'] as String?;
      final refresh = data['refreshToken'] as String?;
      if (access == null || refresh == null) {
        return const _RefreshResult.rejected();
      }
      final next = AuthTokens(accessToken: access, refreshToken: refresh);
      await setTokens(next);
      _lastRefreshAt = DateTime.now();
      return _RefreshResult.ok(next);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      // 400/401/403: the server looked at the refresh token and said no.
      // Anything else (no response, 5xx, 429) says nothing about the session.
      if (status != null && status >= 400 && status < 404) {
        return const _RefreshResult.rejected();
      }
      return const _RefreshResult.unreachable();
    }
  }

  Future<Response<dynamic>> _replay(RequestOptions req, String token) {
    var body = req.data;
    // A consumed FormData cannot be re-read; Dio clones it for exactly this.
    if (body is FormData) body = body.clone();
    return dio.request<dynamic>(
      req.path,
      data: body,
      queryParameters: req.queryParameters,
      cancelToken: req.cancelToken,
      options: Options(
        method: req.method,
        headers: {...req.headers, 'authorization': 'Bearer $token'},
        responseType: req.responseType,
        contentType: req.contentType,
        extra: {...req.extra, _isRetry: true},
      ),
    );
  }

  Future<void> _signOut(String reason) async {
    if (_tokens == null) return;
    await clearTokens();
    if (!_signedOut.isClosed) _signedOut.add(reason);
  }

  /// Public so the auth repository can drop the session on explicit logout.
  Future<void> forgetSession() => clearTokens();
}

/// Outcome of one refresh: new tokens, a refusal (the session is over), or no
/// answer at all (the session may be fine; the network is not).
class _RefreshResult {
  const _RefreshResult.ok(AuthTokens this.tokens) : rejected = false;
  const _RefreshResult.rejected() : tokens = null, rejected = true;
  const _RefreshResult.unreachable() : tokens = null, rejected = false;

  final AuthTokens? tokens;
  final bool rejected;
}

/// Maps a Dio failure onto [AppFailure], preserving the backend's
/// `{error:{code,message,field}}` envelope so a form can highlight the field
/// the server complained about.
AppFailure failureFrom(DioException e) {
  final status = e.response?.statusCode;
  final envelope = _envelope(e.response?.data);

  if (envelope != null) {
    final retryAfter = e.response?.headers.value('retry-after');
    final message = envelope.message;
    return AppFailure(
      status == 429 && retryAfter != null
          ? '$message Try again in ${retryAfter}s.'
          : message,
      code: envelope.code,
      field: envelope.field,
      status: status,
      cause: e,
    );
  }

  switch (e.type) {
    case DioExceptionType.connectionError:
    case DioExceptionType.connectionTimeout:
      return AppFailure(
        'Cannot reach the server at ${Env.apiBase}. Is the backend running?',
        code: 'NETWORK',
        cause: e,
      );
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return AppFailure(
        'The server took too long to respond.',
        code: 'NETWORK',
        cause: e,
      );
    case DioExceptionType.cancel:
      return AppFailure('Request cancelled.', code: 'CANCELLED', cause: e);
    default:
      break;
  }

  if (status == 401) {
    return AppFailure(
      'Sign in to continue.',
      code: 'UNAUTHORIZED',
      status: 401,
      cause: e,
    );
  }
  return AppFailure(
    'Request failed${status == null ? '' : ' ($status)'}.',
    code: status == null ? 'NETWORK' : 'INTERNAL',
    status: status,
    cause: e,
  );
}

class _Envelope {
  const _Envelope(this.code, this.message, this.field);
  final String code;
  final String message;
  final String? field;
}

_Envelope? _envelope(Object? data) {
  Object? decoded = data;
  if (decoded is String) {
    if (decoded.trim().isEmpty) return null;
    try {
      decoded = jsonDecode(decoded);
    } catch (_) {
      return null;
    }
  }
  if (decoded is! Map) return null;
  final error = decoded['error'];
  if (error is! Map) return null;
  final message = error['message'];
  if (message is! String || message.isEmpty) return null;
  return _Envelope(
    (error['code'] as String?) ?? 'INTERNAL',
    message,
    error['field'] as String?,
  );
}
