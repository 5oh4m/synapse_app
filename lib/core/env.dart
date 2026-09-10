/// Runtime configuration.
///
/// Values are supplied at build/run time with either:
///   flutter run --dart-define-from-file=dart_define.json
/// or individual --dart-define=KEY=VALUE flags.
///
/// Nothing secret is committed. See dart_define.example.json and README.
class Env {
  const Env._();

  /// `memory` (default, zero-setup, single-device) or `remote` (talks to the
  /// bundled Node backend so live sessions work across real devices).
  static const String backend = String.fromEnvironment(
    'BACKEND',
    defaultValue: 'memory',
  );

  /// Base URL of the Node backend when [backend] == 'remote'.
  static const String apiBase = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'http://localhost:8787',
  );

  /// `mock` (default, offline, deterministic-ish) or `anthropic`
  /// (real Claude call; only honoured by the Node backend / dev client).
  static const String aiProvider = String.fromEnvironment(
    'AI',
    defaultValue: 'mock',
  );

  /// Dev-only: lets the Flutter client call Claude directly. Never ship a real
  /// key in a client build — production routes generation through the backend.
  static const String anthropicApiKey = String.fromEnvironment(
    'ANTHROPIC_API_KEY',
    defaultValue: '',
  );

  static const String anthropicModel = String.fromEnvironment(
    'ANTHROPIC_MODEL',
    defaultValue: 'claude-sonnet-5',
  );

  static bool get isRemote => backend == 'remote';
  static bool get useAnthropicDirect =>
      aiProvider == 'anthropic' && anthropicApiKey.isNotEmpty;
}
