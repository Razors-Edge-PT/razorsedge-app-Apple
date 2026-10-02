import 'package:flutter/material.dart';

import '../units/weight_unit.dart';

/// Which way the WES2 weight converter converts.
enum WeightConversionDirection {
  lbToKg,
  kgToLb;

  /// The unit the typed number is in.
  ExerciseWeightUnit get from =>
      this == lbToKg ? ExerciseWeightUnit.lb : ExerciseWeightUnit.kg;

  /// The unit the result is shown in.
  ExerciseWeightUnit get to =>
      this == lbToKg ? ExerciseWeightUnit.kg : ExerciseWeightUnit.lb;

  /// [value] in [from] → [to], at full precision, through the shared
  /// conversion helpers (never a local constant).
  double convert(double value) => this == lbToKg
      ? ExerciseWeightUnit.lb.toKg(value)
      : ExerciseWeightUnit.lb.fromKg(value);
}

/// Parses the converter's typed text.
///
/// Accepts a non-negative whole number or decimal: "225", "0", "102.5", ".5"
/// and, while typing, "12." (read as 12). A single decimal comma ("102,5") is
/// read as a decimal point, except a comma followed by exactly three digits
/// ("1,000", "2,500"), which may be a thousands separator and is refused
/// rather than guessed. Grouped or mixed separators, signs, exponents, units
/// and anything above [maxValue] are refused with a message.
///
/// Returns (value: null, error: null) when there is nothing to convert yet
/// (empty text or a lone separator).
({double? value, String? error}) parseWeightConverterInput(String raw) {
  final String text = raw.trim();
  if (text.isEmpty || text == '.' || text == ',') {
    return (value: null, error: null);
  }
  if (text.startsWith('-')) {
    return (value: null, error: 'Enter a number of 0 or more');
  }
  final RegExpMatch? m = RegExp(r'^(\d*)([.,])?(\d*)$').firstMatch(text);
  if (m == null) {
    return (value: null, error: 'Enter a number, e.g. 225 or 102.5');
  }
  final String whole = m.group(1)!;
  final String? separator = m.group(2);
  final String fraction = m.group(3)!;
  if (separator == ',' && whole.isNotEmpty && fraction.length == 3) {
    return (value: null, error: 'Use a decimal point, e.g. 1000 or 2.5');
  }
  final double? value = double.tryParse(
      '${whole.isEmpty ? '0' : whole}.${fraction.isEmpty ? '0' : fraction}');
  if (value == null || !value.isFinite || value > maxWeightConverterValue) {
    return (value: null, error: 'Enter a weight up to 100000');
  }
  return (value: value, error: null);
}

/// The largest weight the converter accepts, in either unit.
const double maxWeightConverterValue = 100000;

/// Opens the WES2 weight converter. Purely local: it never reads or writes
/// the workout, so typing in it cannot reach the workout save path.
Future<void> showWes2WeightConverter(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const Wes2WeightConverterDialog(),
    );

/// A small pounds ⇄ kilograms calculator. All state is local to this dialog,
/// so typing rebuilds only the dialog, never WES2.
class Wes2WeightConverterDialog extends StatefulWidget {
  const Wes2WeightConverterDialog({super.key});

  @override
  State<Wes2WeightConverterDialog> createState() =>
      _Wes2WeightConverterDialogState();
}

class _Wes2WeightConverterDialogState extends State<Wes2WeightConverterDialog> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode(debugLabel: 'weightConverterInput');
  WeightConversionDirection _direction = WeightConversionDirection.lbToKg;

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _clear() {
    setState(_input.clear);
    _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ExerciseWeightUnit from = _direction.from;
    final ExerciseWeightUnit to = _direction.to;
    final ({double? value, String? error}) parsed =
        parseWeightConverterInput(_input.text);
    final double? value = parsed.value;
    final String? result =
        value == null ? null : formatWeightNumber(_direction.convert(value));
    final String fromName = from == ExerciseWeightUnit.lb ? 'pounds' : 'kilograms';
    final String toName = to == ExerciseWeightUnit.lb ? 'pounds' : 'kilograms';

    return AlertDialog(
      title: const Text('Weight converter'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<WeightConversionDirection>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: WeightConversionDirection.lbToKg,
                label: Text('lb → kg',
                    semanticsLabel: 'Pounds to kilograms'),
              ),
              ButtonSegment(
                value: WeightConversionDirection.kgToLb,
                label: Text('kg → lb',
                    semanticsLabel: 'Kilograms to pounds'),
              ),
            ],
            selected: <WeightConversionDirection>{_direction},
            // The typed number is kept and read in the new source unit.
            onSelectionChanged: (s) => setState(() => _direction = s.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _input,
            focusNode: _inputFocus,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Weight in $fromName (${from.suffix})',
              suffixText: from.suffix,
              errorText: parsed.error,
              errorMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            label: result == null
                ? 'Result in $toName: none'
                : 'Result: $result $toName',
            excludeSemantics: true,
            child: Column(
              children: [
                Text(
                  'Result',
                  style: theme.textTheme.labelMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  result == null ? '— ${to.suffix}' : '$result ${to.suffix}',
                  key: const ValueKey('weightConverterResult'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _clear, child: const Text('Clear')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
