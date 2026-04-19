import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/theme.dart';

/// Controls the application's theme colors and persists selections.
class ThemeController extends ChangeNotifier {
  static const _primaryKey = 'primaryColor';
  static const _secondaryKey = 'secondaryColor';
  static const _modeKey = 'themeMode';
  static const _lightBgKey = 'lightBackground';
  static const _darkBgKey = 'darkBackground';

  Color _primaryColor = AppTheme.defaultPrimaryColor;
  Color _secondaryColor = AppTheme.defaultAccentColor;
  Color _lightBackground = AppTheme.defaultLightBackground;
  Color _darkBackground = AppTheme.defaultDarkBackground;
  ThemeMode _themeMode = ThemeMode.dark;

  /// Current primary color.
  Color get primaryColor => _primaryColor;

  /// Current secondary/accent color.
  Color get secondaryColor => _secondaryColor;

  /// Current light-mode background color.
  Color get lightBackground => _lightBackground;

  /// Current dark-mode background color.
  Color get darkBackground => _darkBackground;

  /// Current theme mode (light/dark/system).
  ThemeMode get themeMode => _themeMode;
  set themeMode(ThemeMode mode) => setThemeMode(mode);

  /// Load saved colors and theme mode from persistent storage.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final p = prefs.getInt(_primaryKey);
    final s = prefs.getInt(_secondaryKey);
    final lb = prefs.getInt(_lightBgKey);
    final db = prefs.getInt(_darkBgKey);
    final m = prefs.getInt(_modeKey);
    if (p != null) _primaryColor = Color(p);
    if (s != null) _secondaryColor = Color(s);
    if (lb != null) _lightBackground = Color(lb);
    if (db != null) _darkBackground = Color(db);
    if (m != null && m >= 0 && m < ThemeMode.values.length) {
      _themeMode = ThemeMode.values[m];
    }
    notifyListeners();
  }

  /// Updates colours/backgrounds/mode in-memory for live preview without persisting.
  void preview({Color? primary, Color? secondary, Color? lightBackground, Color? darkBackground, ThemeMode? mode}) {
    if (primary != null) _primaryColor = primary;
    if (secondary != null) _secondaryColor = secondary;
    if (lightBackground != null) _lightBackground = lightBackground;
    if (darkBackground != null) _darkBackground = darkBackground;
    if (mode != null) _themeMode = mode;
    notifyListeners();
  }

  /// Update colors, backgrounds, or theme mode and persist them.
  Future<void> update({Color? primary, Color? secondary, Color? lightBackground, Color? darkBackground, ThemeMode? mode}) async {
    final prefs = await SharedPreferences.getInstance();
    if (primary != null) {
      _primaryColor = primary;
      await prefs.setInt(_primaryKey, primary.toARGB32());
    }
    if (secondary != null) {
      _secondaryColor = secondary;
      await prefs.setInt(_secondaryKey, secondary.toARGB32());
    }
    if (lightBackground != null) {
      _lightBackground = lightBackground;
      await prefs.setInt(_lightBgKey, lightBackground.toARGB32());
    }
    if (darkBackground != null) {
      _darkBackground = darkBackground;
      await prefs.setInt(_darkBgKey, darkBackground.toARGB32());
    }
    if (mode != null) {
      _themeMode = mode;
      await prefs.setInt(_modeKey, mode.index);
    }
    notifyListeners();
  }

  /// Set the theme mode directly.
  Future<void> setThemeMode(ThemeMode mode) async {
    await update(mode: mode);
  }

  /// Toggle between light and dark theme modes.
  Future<void> toggleThemeMode() async {
    final next = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    await setThemeMode(next);
  }

  /// Return the closest accessible color to [original] for the given settings.
  Color nearestAllowedColor(
    Color original,
    ThemeMode mode, {
    required Color primary,
    required Color secondary,
    required bool isPrimary,
  }) {
    const shadeValues = [50, 300, 400, 500, 600, 700, 800, 900];
    final hslOriginal = HSLColor.fromColor(original);
    final hsvOriginal = HSVColor.fromColor(original);

    Color bestColor = original;
    double bestDistance = double.infinity;

    for (final base in Colors.primaries) {
      for (final shade in shadeValues) {
        final candidate = base[shade]!;
        final theme = mode == ThemeMode.dark
            ? AppTheme.darkTheme(
                primary: isPrimary ? candidate : primary,
                secondary: isPrimary ? secondary : candidate,
              )
            : AppTheme.lightTheme(
                primary: isPrimary ? candidate : primary,
                secondary: isPrimary ? secondary : candidate,
              );
        final background = theme.colorScheme.background;
        final onPrimary = theme.colorScheme.onPrimary;
        if (_contrastRatio(candidate, background) >= 4.5 &&
            _contrastRatio(candidate, onPrimary) >= 4.5) {
          final hslCandidate = HSLColor.fromColor(candidate);
          final hsvCandidate = HSVColor.fromColor(candidate);
          final distance = _colorDistance(
            hslOriginal,
            hsvOriginal,
            hslCandidate,
            hsvCandidate,
          );
          if (distance < bestDistance) {
            bestDistance = distance;
            bestColor = candidate;
          }
        }
      }
    }
    return bestColor;
  }

  double _colorDistance(
    HSLColor hslA,
    HSVColor hsvA,
    HSLColor hslB,
    HSVColor hsvB,
  ) {
    final hslDist = _hslDistance(hslA, hslB);
    final hsvDist = _hsvDistance(hsvA, hsvB);
    return hslDist + hsvDist;
  }

  double _hslDistance(HSLColor a, HSLColor b) {
    final hueDiff = _hueDifference(a.hue, b.hue) / 360.0;
    final satDiff = a.saturation - b.saturation;
    final lightDiff = a.lightness - b.lightness;
    return hueDiff * hueDiff + satDiff * satDiff + lightDiff * lightDiff;
  }

  double _hsvDistance(HSVColor a, HSVColor b) {
    final hueDiff = _hueDifference(a.hue, b.hue) / 360.0;
    final satDiff = a.saturation - b.saturation;
    final valDiff = a.value - b.value;
    return hueDiff * hueDiff + satDiff * satDiff + valDiff * valDiff;
  }

  double _hueDifference(double h1, double h2) {
    final diff = (h1 - h2).abs();
    return diff > 180 ? 360 - diff : diff;
  }

  double _contrastRatio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (la > lb) ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
  }
}
