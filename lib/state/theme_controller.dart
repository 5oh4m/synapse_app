import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefKey = 'quizzle.theme_mode';

/// Persisted light/dark preference. Starts on [ThemeMode.system] (matches the
/// device) until the user flips the switch in Profile, after which their
/// explicit choice is remembered across restarts.
class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _restore();
    return ThemeMode.system;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      for (final mode in ThemeMode.values) {
        if (mode.name == saved) {
          state = mode;
          break;
        }
      }
    } catch (_) {
      // No persisted preference (or storage unavailable) — keep system default.
    }
  }

  Future<void> setDark(bool dark) async {
    final mode = dark ? ThemeMode.dark : ThemeMode.light;
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, mode.name);
    } catch (_) {
      // Preference just won't survive a restart; the toggle still works now.
    }
  }
}

final themeModeControllerProvider =
    NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);
