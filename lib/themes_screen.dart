import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';
import 'theme_controller.dart';
import 'app_theme.dart';

/// Screen for selecting app theme colors and mode.
/// Changes are live-persisted immediately on every selection.
class ThemesScreen extends StatelessWidget {
  const ThemesScreen({super.key});

  /// Broad palette for all three color roles.
  /// Darker entries work well as chrome/background (primary role).
  /// Brighter entries work well as accent/action (secondary/tertiary roles).
  static const List<Color> _presets = [
    // Reds / Pinks
    Color(0xFFF44336), // Red 500
    Color(0xFFE91E63), // Pink 500
    Color(0xFFFF5722), // Deep Orange 500
    Color(0xFFFF80AB), // Pink Accent 200
    // Oranges / Yellows
    Color(0xFFFF9800), // Orange 500
    Color(0xFFFFC107), // Amber 500
    Color(0xFFFFEB3B), // Yellow 500
    Color(0xFFFFD740), // Amber Accent 200
    // Greens
    Color(0xFF8BC34A), // Light Green 500
    Color(0xFF4CAF50), // Green 500
    Color(0xFF69F0AE), // Green Accent 200
    Color(0xFF009688), // Teal 500
    Color(0xFF1DE9B6), // Teal Accent 400
    // Blues / Cyans
    Color(0xFF00BCD4), // Cyan 500
    Color(0xFF18FFFF), // Cyan Accent (default tertiary)
    Color(0xFF40C4FF), // Light Blue Accent (default secondary)
    Color(0xFF03A9F4), // Light Blue 500
    Color(0xFF2196F3), // Blue 500
    Color(0xFF448AFF), // Blue Accent 200
    Color(0xFF3F51B5), // Indigo 500
    // Purples
    Color(0xFF673AB7), // Deep Purple 500
    Color(0xFF9C27B0), // Purple 500
    Color(0xFFCE93D8), // Purple 200
    Color(0xFFEA80FC), // Purple Accent 100
    // Dark / chrome tones (good for primary background role)
    Color(0xFF263238), // BlueGrey 900 (default primary/chrome)
    Color(0xFF37474F), // BlueGrey 800
    Color(0xFF455A64), // BlueGrey 700
    Color(0xFF1A237E), // Indigo 900
    Color(0xFF006064), // Cyan 900
    Color(0xFF1B5E20), // Green 900
    Color(0xFF4A148C), // Purple 900
    Color(0xFF212121), // Grey 900
    Color(0xFF000000), // Black
  ];

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeController>(
      builder: (context, tc, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Themes'),
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Theme Mode',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('Light'),
                        icon: Icon(Icons.light_mode),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('Dark'),
                        icon: Icon(Icons.dark_mode),
                      ),
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('System'),
                        icon: Icon(Icons.brightness_auto),
                      ),
                    ],
                    selected: {tc.themeMode},
                    style: SegmentedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.secondary,
                      selectedBackgroundColor: Theme.of(context).colorScheme.secondary,
                      foregroundColor: AppTheme.onColor(Theme.of(context).colorScheme.secondary),
                      selectedForegroundColor: AppTheme.onColor(Theme.of(context).colorScheme.secondary),
                    ),
                    onSelectionChanged: (s) => tc.update(mode: s.first),
                  ),
                  const SizedBox(height: 28),
                  _ColorSection(
                    label: 'Primary Color',
                    subtitle: 'AppBar, scaffold background, branded surfaces',
                    current: tc.primaryColor,
                    presets: _presets,
                    onChanged: (c) => tc.update(primary: c),
                  ),
                  const SizedBox(height: 28),
                  _ColorSection(
                    label: 'Secondary Color',
                    subtitle: 'Active/selected states, switches, focused borders',
                    current: tc.secondaryColor,
                    presets: _presets,
                    onChanged: (c) => tc.update(secondary: c),
                  ),
                  const SizedBox(height: 28),
                  _ColorSection(
                    label: 'Tertiary Color',
                    subtitle: 'Action icons, chips, message bubbles, send accents',
                    current: tc.tertiaryColor,
                    presets: _presets,
                    onChanged: (c) => tc.update(tertiary: c),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.secondary,
                        foregroundColor: AppTheme.onColor(Theme.of(context).colorScheme.secondary),
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                      ),
                      onPressed: () => tc.reset(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reset to Defaults'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ColorSection extends StatelessWidget {
  const _ColorSection({
    required this.label,
    required this.subtitle,
    required this.current,
    required this.presets,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final Color current;
  final List<Color> presets;
  final void Function(Color) onChanged;

  @override
  Widget build(BuildContext context) {
    final lum = current.computeLuminance();
    final bool extremeColor = lum > 0.85 || lum < 0.02;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.tertiary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            ...presets.map((c) => _Swatch(
                  color: c,
                  isSelected: current.value == c.value,
                  onTap: () => onChanged(c),
                )),
            _PlusSwatch(
              onTap: () => _showCustomPicker(context, current, onChanged),
            ),
          ],
        ),
        if (extremeColor) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.info_outline, size: 14,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Very light or very dark colors may reduce contrast in some areas.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  void _showCustomPicker(
    BuildContext context,
    Color current,
    void Function(Color) onChanged,
  ) {
    Color temp = current;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Custom color'),
        content: SingleChildScrollView(
          child: StatefulBuilder(
            builder: (ctx, setDlgState) => ColorPicker(
              pickerColor: temp,
              onColorChanged: (c) => setDlgState(() => temp = c),
              colorPickerWidth: 280,
              pickerAreaHeightPercent: 0.4,
              enableAlpha: false,
              labelTypes: const [],
              displayThumbColor: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              onChanged(temp);
              Navigator.pop(ctx);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final onC = AppTheme.onColor(color);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? onC : Colors.transparent,
            width: 3,
          ),
        ),
        child: isSelected ? Icon(Icons.check, color: onC, size: 18) : null,
      ),
    );
  }
}

class _PlusSwatch extends StatelessWidget {
  const _PlusSwatch({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.blueGrey.shade700,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white38, width: 1.5),
        ),
        child: const Icon(Icons.add, color: Colors.white70, size: 20),
      ),
    );
  }
}
