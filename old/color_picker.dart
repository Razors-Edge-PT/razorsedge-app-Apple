import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:razorsedge/constants/constrained_padding.dart';
import 'package:razorsedge/constants/theme.dart';

import 'theme_controller.dart';

/// A simple screen that lets the user pick primary and secondary colors.
/// Selected colors are previewed as the user makes changes.
class ColorPickerScreen extends StatefulWidget {
  const ColorPickerScreen({super.key});

  @override
  State<ColorPickerScreen> createState() => _ColorPickerScreenState();
}

class _ColorPickerScreenState extends State<ColorPickerScreen> {
  late Color _primary;
  late Color _secondary;
  late ThemeMode _mode;
  String? _error;

  @override
  void initState() {
    super.initState();
    final controller = context.read<ThemeController>();
    _primary = controller.primaryColor;
    _secondary = controller.secondaryColor;
    _mode = controller.themeMode;
  }

  void _save() {
    if (!_isColorAllowed(_primary) || !_isColorAllowed(_secondary)) {
      setState(() =>
          _error = 'One or more colors do not meet contrast requirements.');
      return;
    }
    context
        .read<ThemeController>()
        .update(primary: _primary, secondary: _secondary, mode: _mode);
    Navigator.of(context).pop();
  }

  bool _isColorAllowed(Color color) {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance();
      final lb = b.computeLuminance();
      return la > lb ? (la + 0.5) / (lb + 0.05) : (lb + 0.5) / (la + 0.05);
    }

    final theme = _mode == ThemeMode.dark
        ? AppTheme.darkTheme(primary: _primary, secondary: _secondary)
        : AppTheme.lightTheme(primary: _primary, secondary: _secondary);
    final background = theme.colorScheme.background;
    final onPrimary = theme.colorScheme.onPrimary;
    return contrast(color, background) >= 2 &&
        contrast(color, onPrimary) >= 2.5;
  }

  /// Finds the closest color shade to [original] that passes [_isColorAllowed].
  Color _nearestAllowedColor(Color original, {required bool isPrimary}) {
    const shadeValues = [200, 300, 400, 500, 600, 700, 800, 900];
    Color bestColor = original;
    double bestDistance = double.infinity;

    double _colorDistance(Color a, Color b) {
      final dr = (a.red - b.red).toDouble();
      final dg = (a.green - b.green).toDouble();
      final db = (a.blue - b.blue).toDouble();
      return dr * dr + dg * dg + db * db;
    }

    for (final base in Colors.primaries) {
      for (final shade in shadeValues) {
        final candidate = base[shade]!;

        // Temporarily evaluate the candidate in place of the current color.
        final originalPrimary = _primary;
        final originalSecondary = _secondary;
        if (isPrimary) {
          _primary = candidate;
        } else {
          _secondary = candidate;
        }
        final allowed = _isColorAllowed(candidate);
        _primary = originalPrimary;
        _secondary = originalSecondary;

        if (allowed) {
          final distance = _colorDistance(candidate, original);
          if (distance < bestDistance) {
            bestDistance = distance;
            bestColor = candidate;
          }
        }
      }
    }

    return bestColor;
  }

  Widget _buildColorGrid({
    required Color selected,
    required ValueChanged<Color> onTap,
  }) {
    const shadeValues = [50, 300, 500, 800, 900];
    final colors = Colors.primaries
        .expand((c) =>
            shadeValues.map((s) => c[s]!).where((color) => _isColorAllowed(color)))
        .toList();

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
        childAspectRatio: 1,
      ),
      itemCount: colors.length,
      itemBuilder: (context, index) {
        final color = colors[index];
        return GestureDetector(
          onTap: () => setState(() {
            onTap(color);
            _error = null;
            context.read<ThemeController>().update(
              primary: _primary,
              secondary: _secondary,
              mode: _mode,
            );
          }),
          child: Container(
            decoration: BoxDecoration(
              color: color,
              border: Border.all(
                color: selected == color
                    ? Theme.of(context).colorScheme.onSurface
                    : Colors.transparent,
                width: 3,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose Colors'),
        actions: [
          IconButton(icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return ConstrainedPadding(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: constraints.maxHeight),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Theme mode'),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      segments: const <ButtonSegment<ThemeMode>>[
                        ButtonSegment<ThemeMode>(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode)),
                        ButtonSegment<ThemeMode>(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode)),
                        ButtonSegment<ThemeMode>(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.settings)),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (modes) {
                        final newMode = modes.first;

                        // Temporarily use the new mode to determine accessible colors.
                        _mode = newMode;
                        final newPrimary =
                            _nearestAllowedColor(_primary, isPrimary: true);
                        final newSecondary =
                            _nearestAllowedColor(_secondary, isPrimary: false);

                        // Persist the validated colors before triggering a rebuild.
                        context.read<ThemeController>().update(
                              primary: newPrimary,
                              secondary: newSecondary,
                              mode: newMode,
                            );

                        setState(() {
                          _mode = newMode;
                          _primary = newPrimary;
                          _secondary = newSecondary;
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Primary color'),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _buildColorGrid(
                      selected: _primary,
                      onTap: (c) => _primary = c,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Secondary color'),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _buildColorGrid(
                      selected: _secondary,
                      onTap: (c) => _secondary = c,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

