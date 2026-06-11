import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_theme.dart';

/// Controls the app's theme colors and persists selections via SharedPreferences.
class ThemeController extends ChangeNotifier {
  static const _primaryKey    = 'primaryColor';
  static const _secondaryKey  = 'secondaryColor';
  static const _tertiaryKey   = 'tertiaryColor';
  static const _quaternaryKey = 'quaternaryColor';
  static const _modeKey       = 'themeMode';

  Color _primaryColor    = AppTheme.defaultPrimary;
  Color _secondaryColor  = AppTheme.defaultSecondary;
  Color _tertiaryColor   = AppTheme.defaultTertiary;
  Color _quaternaryColor = AppTheme.defaultQuaternary;
  ThemeMode _themeMode   = AppTheme.defaultThemeMode;

  Color get primaryColor    => _primaryColor;
  Color get secondaryColor  => _secondaryColor;
  Color get tertiaryColor   => _tertiaryColor;
  Color get quaternaryColor => _quaternaryColor;
  ThemeMode get themeMode   => _themeMode;

  /// Load persisted theme selections. Call before runApp.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final p = prefs.getInt(_primaryKey);
    final s = prefs.getInt(_secondaryKey);
    final t = prefs.getInt(_tertiaryKey);
    final q = prefs.getInt(_quaternaryKey);
    final m = prefs.getInt(_modeKey);
    if (p != null) _primaryColor    = Color(p);
    if (s != null) _secondaryColor  = Color(s);
    if (t != null) _tertiaryColor   = Color(t);
    if (q != null) _quaternaryColor = Color(q);
    // Existing users without a saved quaternary get AppTheme.defaultQuaternary.
    if (m != null && m >= 0 && m < ThemeMode.values.length) {
      _themeMode = ThemeMode.values[m];
    }
    notifyListeners();
  }

  /// In-memory preview without persisting (for live previews in picker).
  void preview({Color? primary, Color? secondary, Color? tertiary, Color? quaternary, ThemeMode? mode}) {
    if (primary    != null) _primaryColor    = primary;
    if (secondary  != null) _secondaryColor  = secondary;
    if (tertiary   != null) _tertiaryColor   = tertiary;
    if (quaternary != null) _quaternaryColor = quaternary;
    if (mode       != null) _themeMode       = mode;
    notifyListeners();
  }

  /// Update and immediately persist the given values.
  Future<void> update({Color? primary, Color? secondary, Color? tertiary, Color? quaternary, ThemeMode? mode}) async {
    final prefs = await SharedPreferences.getInstance();
    if (primary != null) {
      _primaryColor = primary;
      await prefs.setInt(_primaryKey, primary.value);
    }
    if (secondary != null) {
      _secondaryColor = secondary;
      await prefs.setInt(_secondaryKey, secondary.value);
    }
    if (tertiary != null) {
      _tertiaryColor = tertiary;
      await prefs.setInt(_tertiaryKey, tertiary.value);
    }
    if (quaternary != null) {
      _quaternaryColor = quaternary;
      await prefs.setInt(_quaternaryKey, quaternary.value);
    }
    if (mode != null) {
      _themeMode = mode;
      await prefs.setInt(_modeKey, mode.index);
    }
    notifyListeners();
  }

  /// Reset all theme settings to app defaults and persist.
  Future<void> reset() async {
    await update(
      primary:    AppTheme.defaultPrimary,
      secondary:  AppTheme.defaultSecondary,
      tertiary:   AppTheme.defaultTertiary,
      quaternary: AppTheme.defaultQuaternary,
      mode:       AppTheme.defaultThemeMode,
    );
  }
}
