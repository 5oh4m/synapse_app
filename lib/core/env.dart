/// Runtime configuration.
///
/// Values are supplied at build/run time with either:
///   flutter run --dart-define-from-file=dart_define.json
/// or individual --dart-define=KEY=VALUE flags.
///
/// Nothing secret is read here. A `--dart-define` is a *compile-time constant*:
/// it is baked into `main.dart.js` in plain text and is trivially recoverable
/// from a shipped build, so no API key is ever accepted from this class. The
/// Anthropic key lives only in `backend/.env`; the client asks the backend to
/// generate (`POST /generate`).
class Env {
  const Env._();

  /// `memory` (offline, single-device, zero setup) or `remote` (the JWT +
  /// Postgres backend in `backend/`, required for real multi-device play).
  static const String backend = String.fromEnvironment(
    'BACKEND',
    defaultValue: 'memory',
  );

  /// Origin of the backend when [backend] == 'remote'. The REST API is served
  /// under `<apiBase>/api`; the socket is `<apiBase>/ws`.
  static const String apiBase = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'http://localhost:8787',
  );

  /// REST root. Every call in [ApiClient] is relative to this.
  static String get apiRoot => '${_trimSlash(apiBase)}/api';

  /// `ws://…/ws` / `wss://…/ws`, derived from [apiBase].
  static Uri wsUri(String accessToken) {
    final base = Uri.parse(_trimSlash(apiBase));
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/ws',
      queryParameters: {'token': accessToken},
    );
  }

  /// Label only. The provider that actually runs is chosen by the *server*
  /// from `AI_PROVIDER` in `backend/.env`; the client cannot pick it.
  static const String aiProvider = String.fromEnvironment(
    'AI',
    defaultValue: 'mock',
  );

  /// Shown in the "how are questions generated" banner. The backend pins the
  /// real id (`claude-sonnet-4-20250514`); `claude-sonnet-5` does not exist.
  static const String anthropicModel = String.fromEnvironment(
    'ANTHROPIC_MODEL',
    defaultValue: 'claude-sonnet-4-20250514',
  );

  static bool get isRemote => backend == 'remote';

  /// Public origin of this app, for join links and QR codes. Optional on web,
  /// where the page's own origin is used; set it for native builds, or when
  /// the app is served from a different host than the one students should
  /// open.
  static const String appUrl = String.fromEnvironment('APP_URL');

  /// `https://…/join/ABC123` — the link a student opens (or scans) to land on
  /// the join screen with the code filled in. Null when no public origin is
  /// known (a native build without `APP_URL`).
  static String? joinUrl(String code) {
    final origin = appUrl.isNotEmpty
        ? _trimSlash(appUrl)
        : (Uri.base.scheme.startsWith('http') ? Uri.base.origin : null);
    if (origin == null) return null;
    return '$origin/join/$code';
  }

  static String _trimSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;
}
