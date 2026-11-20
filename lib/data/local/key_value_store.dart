import 'package:shared_preferences/shared_preferences.dart';

import '../../core/failure.dart';

/// Tiny key/value seam over `shared_preferences`.
///
/// It exists for two reasons:
///  * tests can inject a store that fails (to prove quota errors are surfaced,
///    not swallowed);
///  * writes report failure instead of being wrapped in `catch (_) {}`. The
///    previous implementation silently discarded every storage error, so a
///    browser that had hit its ~5 MB localStorage quota looked identical to a
///    successful save.
abstract class KeyValueStore {
  Future<String?> read(String key);

  /// Throws [AppFailure] with `code == 'STORAGE'` when the write does not land.
  Future<void> write(String key, String value);

  Future<void> remove(String key);

  /// Keys currently held, used to garbage-collect per-item records.
  Future<Set<String>> keys();
}

class SharedPreferencesStore implements KeyValueStore {
  SharedPreferencesStore();

  SharedPreferences? _prefs;
  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<String?> read(String key) async {
    try {
      return (await _p).getString(key);
    } catch (e) {
      // A read failure is recoverable: behave as "nothing stored".
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      final ok = await (await _p).setString(key, value);
      if (!ok) {
        throw AppFailure(
          _quotaMessage(key, value.length),
          code: 'STORAGE',
        );
      }
    } on AppFailure {
      rethrow;
    } catch (e) {
      throw AppFailure(_quotaMessage(key, value.length), code: 'STORAGE', cause: e);
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      await (await _p).remove(key);
    } catch (_) {
      // Nothing useful to do; the value is either gone or unreachable.
    }
  }

  @override
  Future<Set<String>> keys() async {
    try {
      return (await _p).getKeys();
    } catch (_) {
      return const {};
    }
  }

  String _quotaMessage(String key, int chars) =>
      'Offline storage rejected a ${(chars / 1024).toStringAsFixed(1)} KB write '
      '($key). Local browser storage is probably full, so this change will not '
      'survive a reload.';
}

/// RAM-only store. Used by tests and by any platform where persistence is
/// unavailable — it never claims a write survived a restart.
class MemoryKeyValueStore implements KeyValueStore {
  MemoryKeyValueStore({this.failOnWrite = false});

  final Map<String, String> values = {};

  /// When true every [write] throws a storage [AppFailure], which is how the
  /// tests simulate a full localStorage quota.
  bool failOnWrite;

  /// Every write attempted, in order, including the ones that failed.
  final List<String> writeLog = [];

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writeLog.add(key);
    if (failOnWrite) {
      throw const AppFailure(
        'Simulated storage quota failure.',
        code: 'STORAGE',
      );
    }
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }

  @override
  Future<Set<String>> keys() async => values.keys.toSet();
}
