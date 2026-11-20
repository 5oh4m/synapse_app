import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'key_value_store.dart';

/// The pair issued by `POST /auth/login|register|refresh`.
@immutable
class AuthTokens {
  const AuthTokens({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;

  @override
  bool operator ==(Object other) =>
      other is AuthTokens &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken;

  @override
  int get hashCode => Object.hash(accessToken, refreshToken);

  /// Never prints the tokens themselves.
  @override
  String toString() =>
      'AuthTokens(access: ${accessToken.length} chars, refresh: ${refreshToken.length} chars)';
}

/// Where the JWT pair lives between launches.
///
/// **Passwords are never stored, anywhere.** Only the access/refresh tokens,
/// which the server can revoke.
abstract class TokenStore {
  Future<AuthTokens?> read();
  Future<void> write(AuthTokens tokens);
  Future<void> clear();
}

/// Picks the best available backing for the platform:
///
///  * web — `shared_preferences` (localStorage). `flutter_secure_storage` has a
///    web implementation but it is AES-in-localStorage with the key sitting in
///    the same origin, so it is not a real secure enclave; pretending otherwise
///    would be the kind of false claim this rewrite is removing.
///  * everything else — `flutter_secure_storage` (Keychain / Keystore /
///    libsecret / DPAPI), falling back to `shared_preferences` if the plugin is
///    missing (e.g. a plain `flutter test` VM run).
TokenStore defaultTokenStore() =>
    kIsWeb ? PrefsTokenStore() : SecureTokenStore();

class PrefsTokenStore implements TokenStore {
  PrefsTokenStore({KeyValueStore? store})
    : _store = store ?? SharedPreferencesStore();

  static const accessKey = 'quizzle.auth.access';
  static const refreshKey = 'quizzle.auth.refresh';

  final KeyValueStore _store;

  @override
  Future<AuthTokens?> read() async {
    final access = await _store.read(accessKey);
    final refresh = await _store.read(refreshKey);
    if (access == null || refresh == null) return null;
    return AuthTokens(accessToken: access, refreshToken: refresh);
  }

  @override
  Future<void> write(AuthTokens tokens) async {
    await _store.write(accessKey, tokens.accessToken);
    await _store.write(refreshKey, tokens.refreshToken);
  }

  @override
  Future<void> clear() async {
    await _store.remove(accessKey);
    await _store.remove(refreshKey);
  }
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage, TokenStore? fallback})
    : _storage = storage ?? const FlutterSecureStorage(),
      _fallback = fallback ?? PrefsTokenStore();

  final FlutterSecureStorage _storage;
  final TokenStore _fallback;
  bool _degraded = false;

  @override
  Future<AuthTokens?> read() async {
    if (_degraded) return _fallback.read();
    try {
      final access = await _storage.read(key: PrefsTokenStore.accessKey);
      final refresh = await _storage.read(key: PrefsTokenStore.refreshKey);
      if (access == null || refresh == null) return null;
      return AuthTokens(accessToken: access, refreshToken: refresh);
    } on MissingPluginException {
      _degraded = true;
      return _fallback.read();
    } catch (_) {
      // Keychain locked / unavailable: treat as "no session", never crash the
      // app on launch.
      return null;
    }
  }

  @override
  Future<void> write(AuthTokens tokens) async {
    if (_degraded) return _fallback.write(tokens);
    try {
      await _storage.write(
        key: PrefsTokenStore.accessKey,
        value: tokens.accessToken,
      );
      await _storage.write(
        key: PrefsTokenStore.refreshKey,
        value: tokens.refreshToken,
      );
    } on MissingPluginException {
      _degraded = true;
      await _fallback.write(tokens);
    }
  }

  @override
  Future<void> clear() async {
    if (_degraded) return _fallback.clear();
    try {
      await _storage.delete(key: PrefsTokenStore.accessKey);
      await _storage.delete(key: PrefsTokenStore.refreshKey);
    } on MissingPluginException {
      _degraded = true;
      await _fallback.clear();
    } catch (_) {
      // Nothing more to do; the tokens are dropped from memory regardless.
    }
  }
}

/// RAM only. Tests use this; so does any run where persisting a session would
/// be wrong (a shared kiosk browser, for example).
class MemoryTokenStore implements TokenStore {
  AuthTokens? _tokens;

  @override
  Future<AuthTokens?> read() async => _tokens;

  @override
  Future<void> write(AuthTokens tokens) async => _tokens = tokens;

  @override
  Future<void> clear() async => _tokens = null;
}
