import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';
import 'package:razorsedge/constants/constrained_padding.dart';

import 'theme_controller.dart';

/// A screen that lets the user pick background, primary, and secondary colours.
/// Changes are previewed live; they are only persisted when the user saves.
class ColourPickerScreen extends StatefulWidget {
  const ColourPickerScreen({super.key});

  @override
  State<ColourPickerScreen> createState() => _ColourPickerScreenState();
}

class _ColourPickerScreenState extends State<ColourPickerScreen> {
  late ThemeController _controller;
  late Color _primary;
  late Color _secondary;
  late Color _lightBg;
  late Color _darkBg;
  late ThemeMode _mode;

  late Color _origPrimary;
  late Color _origSecondary;
  late Color _origLightBg;
  late Color _origDarkBg;
  late ThemeMode _origMode;
  bool _saved = false;

  // ROYGBIV presets for primary and secondary.
  static const List<Color> _accentPresets = [
    Color(0xFFF44336), // Red
    Color(0xFFFF9800), // Orange
    Color(0xFFFFEB3B), // Yellow
    Color(0xFF4CAF50), // Green
    Color(0xFF2196F3), // Blue
    Color(0xFF3F51B5), // Indigo
    Color(0xFF9C27B0), // Violet
  ];

  // 3 placeholder options per mode — to be finalised.
  static const List<Color> _lightBgPresets = [
    Colors.white,
    Color(0xFFF5F5F5),
    Color(0xFFE3F2FD),
  ];
  static const List<Color> _darkBgPresets = [
    Color(0xFF424242),
    Color(0xFF263239),
    Color(0xFF212121),
  ];

  @override
  void initState() {
    super.initState();
    _controller = context.read<ThemeController>();
    _primary = _origPrimary = _controller.primaryColor;
    _secondary = _origSecondary = _controller.secondaryColor;
    _lightBg = _origLightBg = _controller.lightBackground;
    _darkBg = _origDarkBg = _controller.darkBackground;
    _mode = _origMode = _controller.themeMode;
  }

  @override
  void dispose() {
    if (!_saved) {
      _controller.preview(
        primary: _origPrimary,
        secondary: _origSecondary,
        lightBackground: _origLightBg,
        darkBackground: _origDarkBg,
        mode: _origMode,
      );
    }
    super.dispose();
  }

  void _save() {
    _saved = true;
    _controller.update(
      primary: _primary,
      secondary: _secondary,
      lightBackground: _lightBg,
      darkBackground: _darkBg,
      mode: _mode,
    );
    Navigator.of(context).pop();
  }

  Color get _activeBg => _mode == ThemeMode.dark ? _darkBg : _lightBg;
  List<Color> get _activeBgPresets =>
      _mode == ThemeMode.dark ? _darkBgPresets : _lightBgPresets;

  void _onBgChanged(Color c) {
    setState(() {
      if (_mode == ThemeMode.dark) {
        _darkBg = c;
      } else {
        _lightBg = c;
      }
    });
    _controller.preview(
      lightBackground: _mode != ThemeMode.dark ? c : _lightBg,
      darkBackground: _mode == ThemeMode.dark ? c : _darkBg,
    );
  }

  void _onPrimaryChanged(Color c) {
    setState(() => _primary = c);
    _controller.preview(primary: c);
  }

  void _onSecondaryChanged(Color c) {
    setState(() => _secondary = c);
    _controller.preview(secondary: c);
  }

  static const List<ThemeMode> _modeOrder = [
    ThemeMode.light,
    ThemeMode.dark,
  ];

  IconData get _modeIcon => _mode == ThemeMode.light ? Icons.light_mode : Icons.dark_mode;

  String get _modeLabel => _mode == ThemeMode.light ? 'Light' : 'Dark';

  void _cycleMode() {
    final next = _modeOrder[(_modeOrder.indexOf(_mode) + 1) % _modeOrder.length];
    _onModeChanged(next);
  }

  void _onModeChanged(ThemeMode newMode) {
    setState(() => _mode = newMode);
    _controller.preview(mode: newMode);
  }

  void _showCustomPicker({
    required Color current,
    required ValueChanged<Color> onChanged,
  }) {
    Color temp = current;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Custom colour'),
        content: SingleChildScrollView(
          child: StatefulBuilder(
            builder: (ctx, setDlgState) => ColorPicker(
              pickerColor: temp,
              onColorChanged: (c) {
                setDlgState(() => temp = c);
                onChanged(c);
              },
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
            onPressed: () {
              onChanged(current);
              Navigator.pop(ctx);
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  Widget _buildSwatch(Color colour, {required bool isSelected, required VoidCallback onTap}) {
    final onColour = colour.computeLuminance() > 0.35 ? Colors.black : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: colour,
          shape: BoxShape.circle,
          border: isSelected
              ? Border.all(color: onColour, width: 3)
              : Border.all(color: Colors.transparent, width: 3),
        ),
        child: isSelected
            ? Icon(Icons.check, color: onColour, size: 20)
            : null,
      ),
    );
  }

  Widget _buildPlusSwatch({required VoidCallback onTap}) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          shape: BoxShape.circle,
          border: Border.all(color: scheme.outline.withOpacity(0.4), width: 1.5),
        ),
        child: Icon(Icons.add, color: scheme.onSurfaceVariant),
      ),
    );
  }

  /// Builds a 4-column colour grid.
  /// [presets] are the fixed swatches; [showPlus] appends a custom-colour button.
  Widget _buildGrid({
    required Color selected,
    required List<Color> presets,
    required ValueChanged<Color> onChanged,
    bool showPlus = false,
  }) {
    final swatches = presets
        .map((c) => _buildSwatch(c, isSelected: selected == c, onTap: () => onChanged(c)))
        .toList();

    final children = [
      ...swatches,
      if (showPlus)
        _buildPlusSwatch(
          onTap: () => _showCustomPicker(current: selected, onChanged: onChanged),
        ),
    ];

    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      children: children,
    );
  }

  Widget _buildSection({
    required String label,
    required Color selected,
    required List<Color> presets,
    required ValueChanged<Color> onChanged,
    bool showPlus = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _buildGrid(
          selected: selected,
          presets: presets,
          onChanged: onChanged,
          showPlus: showPlus,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: Navigator.of(context).pop),
        title: const Text('Choose Colours'),
        actions: [
          IconButton(
            icon: Icon(_modeIcon),
            tooltip: _modeLabel,
            onPressed: _cycleMode,
          ),
          IconButton(icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      body: ConstrainedPadding(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Text('Background colour', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: _activeBgPresets
                    .map((c) => SizedBox(
                          width: 56,
                          height: 56,
                          child: _buildSwatch(
                            c,
                            isSelected: _activeBg == c,
                            onTap: () => _onBgChanged(c),
                          ),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 24),
              _buildSection(
                label: 'Primary colour',
                selected: _primary,
                presets: _accentPresets,
                onChanged: _onPrimaryChanged,
                showPlus: true,
              ),
              const SizedBox(height: 24),
              _buildSection(
                label: 'Secondary colour',
                selected: _secondary,
                presets: _accentPresets,
                onChanged: _onSecondaryChanged,
                showPlus: true,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}