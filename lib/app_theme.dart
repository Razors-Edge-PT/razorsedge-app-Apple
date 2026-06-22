import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// App-wide theme constants and theme builders.
///
/// Role semantics (user-facing names):
///   Primary    = chrome / branded background surfaces (AppBar, scaffold, drawer)
///   Secondary  = active / selected states (switches, focused borders, chart lines)
///   Tertiary   = action icons / accent highlights (FABs, chips, send icons, bubbles)
///   Quaternary = completed / success states (completed workout calendar markers)
class AppTheme {
  // Primary = chrome / branded background surfaces (AppBar, scaffold, drawer).
  static const Color defaultPrimary = Color(0xFF000000); // Black primary
  // Secondary = active / selected states (switches, focused borders, chart lines).
  static const Color defaultSecondary = Color(0xFF03A9F4); // Light Blue 500
  // Tertiary = action icons / accent highlights (FABs, chips, send icons, bubbles).
  static const Color defaultTertiary = Color(0xFF18FFFF); // Cyan Accent
  // Quaternary = completed / success states (completed workout calendar markers).
  static const Color defaultQuaternary = Color(0xFF263238); // BlueGrey 900

  static const ThemeMode defaultThemeMode = ThemeMode.dark;

  /// Adaptive foreground: black on light backgrounds, white on dark.
  static Color onColor(Color bg) =>
      bg.computeLuminance() > 0.35 ? Colors.black87 : Colors.white;

  static ThemeData dark({
    Color? primary,
    Color? secondary,
    Color? tertiary,
    Color? quaternary,
  }) {
    final chrome = primary ?? defaultPrimary; // scaffold / AppBar bg
    final active = secondary ?? defaultSecondary; // colorScheme.primary slot
    final accent = tertiary ?? defaultTertiary; // colorScheme.tertiary slot
    final done = quaternary ?? defaultQuaternary; // completed / success
    final onActive = onColor(active);
    final onAccent = onColor(accent);

    // Elevated surface: slightly lighter than chrome — matches blueGrey.shade800 at defaults.
    final cardSurface = Color.lerp(chrome, Colors.white, 0.12)!;

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: chrome,
      primaryColor: active,
      colorScheme: ColorScheme.dark(
        primary: active,
        onPrimary: onActive,
        secondary: active,
        onSecondary: onActive,
        tertiary: accent,
        onTertiary: onAccent,
        surface: chrome,
        onSurface: Colors.white,
        outline: Color.lerp(chrome, Colors.white, 0.25)!,
      ),
      extensions: <ThemeExtension<dynamic>>[
        GoodLiftColors(quaternary: done),
      ],
      appBarTheme: AppBarTheme(
        backgroundColor: chrome,
        foregroundColor: Colors.white,
        titleTextStyle: GoogleFonts.monda(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ).copyWith(fontFamilyFallback: const ['Roboto', 'Helvetica', 'Arial']),
        toolbarTextStyle: GoogleFonts.monda(
          color: Colors.white,
          fontSize: 16,
        ).copyWith(fontFamilyFallback: const ['Roboto', 'Helvetica', 'Arial']),
      ),
      cardTheme: CardThemeData(
        color: cardSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardSurface,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: chrome,
      ),
      listTileTheme: const ListTileThemeData(
        tileColor: Colors.transparent,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blueGrey.shade700,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      iconTheme: const IconThemeData(color: Colors.white70),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: Colors.white),
        labelLarge: TextStyle(color: Colors.white),
      ),
    );
  }

  static ThemeData light({
    Color? primary,
    Color? secondary,
    Color? tertiary,
    Color? quaternary,
  }) {
    // Derive a tinted light surface from the chrome primary color.
    // At default (blueGrey 900) this produces ~#D0D4D5, near-identical to grey.shade200.
    final chrome = primary ?? defaultPrimary;
    final lightChrome = Color.lerp(chrome, Colors.white, 0.85)!;
    final onChrome =
        onColor(lightChrome); // always black87 for any sensible chrome

    final active = secondary ?? defaultSecondary;
    final accent = tertiary ?? defaultTertiary;
    final done = quaternary ?? defaultQuaternary;
    final onActive = onColor(active);
    final onAccent = onColor(accent);

    // Card surface: subtly darker than the scaffold so cards stand out.
    final cardSurface = Color.lerp(lightChrome, Colors.black, 0.06)!;

    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: lightChrome,
      primaryColor: active,
      colorScheme: ColorScheme.light(
        primary: active,
        onPrimary: onActive,
        secondary: accent,
        onSecondary: onAccent,
        tertiary: accent,
        onTertiary: onAccent,
        surface: lightChrome,
        onSurface: Colors.black87,
        outline: Color.lerp(lightChrome, Colors.black, 0.25)!,
      ),
      extensions: <ThemeExtension<dynamic>>[
        GoodLiftColors(quaternary: done),
      ],
      appBarTheme: AppBarTheme(
        backgroundColor: lightChrome,
        foregroundColor: onChrome,
        titleTextStyle: GoogleFonts.monda(
          color: onChrome,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ).copyWith(fontFamilyFallback: const ['Roboto', 'Helvetica', 'Arial']),
        toolbarTextStyle: GoogleFonts.monda(
          color: onChrome,
          fontSize: 16,
        ).copyWith(fontFamilyFallback: const ['Roboto', 'Helvetica', 'Arial']),
      ),
      cardTheme: CardThemeData(
        color: cardSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardSurface,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: lightChrome,
      ),
      listTileTheme: const ListTileThemeData(
        tileColor: Colors.transparent,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blueGrey.shade700,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      iconTheme: const IconThemeData(color: Colors.black54),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: Colors.black87),
        labelLarge: TextStyle(color: Colors.black87),
      ),
    );
  }
}

/// GoodLift-specific colour tokens that have no standard [ColorScheme] slot.
///
/// Access via:
/// ```dart
/// Theme.of(context).extension<GoodLiftColors>()?.quaternary
///   ?? AppTheme.defaultQuaternary
/// ```
@immutable
class GoodLiftColors extends ThemeExtension<GoodLiftColors> {
  const GoodLiftColors({required this.quaternary});

  /// Completed / success state colour — e.g. completed workout calendar markers.
  final Color quaternary;

  @override
  GoodLiftColors copyWith({Color? quaternary}) =>
      GoodLiftColors(quaternary: quaternary ?? this.quaternary);

  @override
  GoodLiftColors lerp(ThemeExtension<GoodLiftColors>? other, double t) {
    if (other is! GoodLiftColors) return this;
    return GoodLiftColors(
      quaternary: Color.lerp(quaternary, other.quaternary, t) ?? quaternary,
    );
  }
}
