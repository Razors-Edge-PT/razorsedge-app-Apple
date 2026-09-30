/// Turns a voice "set one 50 kilos 5 reps 2 RIR" into exactly the field edits
/// the WES2 row would report if the athlete had typed those values and left
/// each field: canonical kilogram text for weight (converted once, with the
/// shared unit helpers), and the same [Wes2FieldParser] validation.
///
/// Validation first, for every value: an invalid value yields an error and NO
/// edits, so a combined command never leaves a half-applied set.
library;

import '../WES2_models.dart';
import '../units/weight_unit.dart';
import '../wes2_field_parser.dart';
import 'aurelian_command.dart';

class SetFieldEdit {
  const SetFieldEdit(this.fieldKey, this.text);

  final Wes2FieldKey fieldKey;

  /// What the row reports on leaving the field: kilograms for weight.
  final String text;

  @override
  bool operator ==(Object other) =>
      other is SetFieldEdit && other.fieldKey == fieldKey && other.text == text;

  @override
  int get hashCode => Object.hash(fieldKey, text);

  @override
  String toString() => 'SetFieldEdit(${fieldKey.name}: $text)';
}

class SetEntryPlan {
  const SetEntryPlan._(this.setIndex, this.edits, this.summary, this.error);

  factory SetEntryPlan.error(String message) =>
      SetEntryPlan._(-1, const <SetFieldEdit>[], '', message);

  /// WES2's 0-based index (spoken set number - 1).
  final int setIndex;
  final List<SetFieldEdit> edits;

  /// "Set 1: 50 kg · 5 reps · RIR 2", in the unit that was said.
  final String summary;
  final String? error;

  bool get isValid => error == null;
}

/// [setCount] is the exercise's number of sets; [displayUnit] its GoodLift
/// unit (used when no unit was said); [velocityShown] whether the exercise
/// shows a velocity field; [normalEntry] false for timed exercises.
SetEntryPlan planSetEntry(
  AurelianCommand command, {
  required String exerciseName,
  required int setCount,
  required ExerciseWeightUnit displayUnit,
  required bool velocityShown,
  bool normalEntry = true,
}) {
  final int? number = command.setNumber;
  if (number == null || number < 1) {
    return SetEntryPlan.error('Say which set');
  }
  if (!command.hasSetValues) return SetEntryPlan.error('No value given');
  if (!normalEntry) {
    return SetEntryPlan.error(
        '$exerciseName is timed — enter it on screen');
  }
  if (number > setCount) {
    return SetEntryPlan.error(
        '$exerciseName has $setCount ${setCount == 1 ? 'set' : 'sets'} — say "add set" for set $number');
  }
  final List<SetFieldEdit> edits = <SetFieldEdit>[];
  final List<String> said = <String>[];

  final double? weight = command.weight;
  if (weight != null) {
    if (weight < 0) return SetEntryPlan.error('Weight can\'t be negative');
    final ExerciseWeightUnit unit = command.weightUnit ?? displayUnit;
    final String spoken = formatWeightNumber(weight);
    // Exactly what the row's weight field does with typed text in [unit].
    final String kgText = unit == ExerciseWeightUnit.kg
        ? spoken
        : (parseDisplayToKg(spoken, unit)?.toString() ?? '');
    if (Wes2FieldParser.valueOrNull(Wes2FieldKey.weight, kgText) == null) {
      return SetEntryPlan.error('"$spoken" isn\'t a weight GoodLift accepts');
    }
    edits.add(SetFieldEdit(Wes2FieldKey.weight, kgText));
    said.add('$spoken ${unit.suffix}');
  }

  final int? reps = command.reps;
  if (reps != null) {
    final String text = '$reps';
    if (reps < 0 || Wes2FieldParser.valueOrNull(Wes2FieldKey.reps, text) == null) {
      return SetEntryPlan.error('"$reps" isn\'t a rep count GoodLift accepts');
    }
    edits.add(SetFieldEdit(Wes2FieldKey.reps, text));
    said.add('$reps ${reps == 1 ? 'rep' : 'reps'}');
  }

  final double? rir = command.rir;
  if (rir != null) {
    final String text = formatWeightNumber(rir);
    if (rir < 0 || rir > 10 || Wes2FieldParser.valueOrNull(Wes2FieldKey.rir, text) == null) {
      return SetEntryPlan.error('RIR $text is out of range');
    }
    edits.add(SetFieldEdit(Wes2FieldKey.rir, text));
    said.add('RIR $text');
  }

  final double? velocity = command.velocity;
  if (velocity != null) {
    if (!velocityShown) {
      return SetEntryPlan.error('$exerciseName has no velocity field');
    }
    final String text = formatWeightNumber(velocity);
    if (velocity <= 0 || Wes2FieldParser.valueOrNull(Wes2FieldKey.velocity, text) == null) {
      return SetEntryPlan.error('Velocity $text is out of range');
    }
    edits.add(SetFieldEdit(Wes2FieldKey.velocity, text));
    said.add('$text m/s');
  }

  return SetEntryPlan._(
      number - 1, edits, 'Set $number: ${said.join(' · ')}', null);
}
