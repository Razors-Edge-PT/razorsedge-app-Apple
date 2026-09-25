// Per-exercise weight units: canonical kilograms everywhere, conversion only
// at the input/output boundary (lib/units/).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/units/exercise_unit_registry.dart';
import 'package:localtest222/units/weight_unit.dart';

void main() {
  group('ExerciseWeightUnit', () {
    test('missing, null, malformed and legacy values default to kg', () {
      for (final Object? raw in <Object?>[
        null,
        '',
        'stone',
        3,
        'pounds',
        true
      ]) {
        expect(ExerciseWeightUnit.parse(raw), ExerciseWeightUnit.kg,
            reason: '$raw');
      }
      expect(ExerciseWeightUnit.parse('lb'), ExerciseWeightUnit.lb);
      expect(ExerciseWeightUnit.parse(' LB '), ExerciseWeightUnit.lb);
      expect(ExerciseWeightUnit.parse('kg'), ExerciseWeightUnit.kg);
      expect(ExerciseWeightUnit.parseOrNull('stone'), isNull);
    });

    test('exact conversion constants', () {
      expect(kKgPerLb, 0.45359237);
      expect(kLbPerKg, 2.2046226218487757);
      expect(ExerciseWeightUnit.lb.toKg(1), 0.45359237);
      expect(ExerciseWeightUnit.lb.fromKg(1), 2.2046226218487757);
      expect(ExerciseWeightUnit.kg.toKg(102.5), 102.5);
      expect(ExerciseWeightUnit.kg.fromKg(102.5), 102.5);
    });

    test('selector labels', () {
      expect(ExerciseWeightUnit.kg.choiceLabel, 'Kilograms (kg)');
      expect(ExerciseWeightUnit.lb.choiceLabel, 'Pounds (lb)');
      expect(ExerciseWeightUnit.lb.storageValue, 'lb');
    });
  });

  group('round trips', () {
    test('225 lb is stored as canonical kg and shown as 225 again', () {
      final double kg = parseDisplayToKg('225', ExerciseWeightUnit.lb)!;
      expect(kg, 225 * 0.45359237);
      expect(
          formatWeightKg(kg, ExerciseWeightUnit.lb, maxDecimals: 3), '225 lb');
      expect(WeightKg(kg).inUnit(ExerciseWeightUnit.lb).number(), '225');
    });

    test('repeated open/save cycles never drift', () {
      double kg = parseDisplayToKg('225', ExerciseWeightUnit.lb)!;
      final double first = kg;
      for (int i = 0; i < 50; i++) {
        final String shown =
            formatWeightNumber(ExerciseWeightUnit.lb.fromKg(kg));
        kg = parseDisplayToKg(shown, ExerciseWeightUnit.lb)!;
      }
      expect(kg, first, reason: 'the same text always re-derives the same kg');
      // kg input behaves exactly as before.
      expect(parseDisplayToKg('102.5', ExerciseWeightUnit.kg), 102.5);
      expect(formatWeightKg(102.5, ExerciseWeightUnit.kg), '102.5 kg');
      expect(formatWeightKg(100, ExerciseWeightUnit.kg), '100 kg');
    });

    test('the canonical value is never rounded prematurely', () {
      final double kg = parseDisplayToKg('5', ExerciseWeightUnit.lb)!;
      // Exactly the product (2.2679618500000003), not a rounded 2.268.
      expect(kg, 5 * 0.45359237);
      expect(kg, isNot(2.268));
      expect(parseDisplayToKg('abc', ExerciseWeightUnit.lb), isNull);
      expect(parseDisplayToKg('', ExerciseWeightUnit.lb), isNull);
    });
  });

  group('typed values', () {
    test('DisplayWeight carries its unit; comparing goes through kg', () {
      const DisplayWeight lb = DisplayWeight(225, ExerciseWeightUnit.lb);
      const DisplayWeight kg =
          DisplayWeight(102.05828325, ExerciseWeightUnit.kg);
      expect(lb == kg, isFalse,
          reason: 'display numbers are not comparable raw');
      expect(lb.toKg().kg, closeTo(kg.toKg().kg, 1e-9));
      expect(lb.label(), '225 lb');
      expect(DisplayWeight.tryParse('x', ExerciseWeightUnit.lb), isNull);
    });

    test(
        'cross-exercise inference is computed in kg, then shown in the target unit',
        () {
      // Source: a barbell bench in kg (100 kg). Target: a DB press shown in lb.
      final DisplayWeight hint = deriveForExercise(
        source: const WeightKg(100),
        calculateKg: (WeightKg w) => w * 0.4, // any kg-domain rule
        targetUnit: ExerciseWeightUnit.lb,
      );
      expect(hint.unit, ExerciseWeightUnit.lb);
      expect(hint.value, closeTo(40 * kLbPerKg, 1e-9));
      expect(hint.label(), '88.2 lb');
      // The same rule for a kg target is the plain kg result.
      expect(
        deriveForExercise(
          source: const WeightKg(100),
          calculateKg: (WeightKg w) => w * 0.4,
          targetUnit: ExerciseWeightUnit.kg,
        ).label(),
        '40 kg',
      );
    });
  });

  group('ExerciseUnits', () {
    const String bench = 'AmfUWbF1DH3I7qPAdh5k';
    const String squat = 'heeBViVINHO6tUScSd6y';

    test('two exercises resolve independently; unset is kg', () {
      final ExerciseUnits u = ExerciseUnits(
        blockSettings: <String, dynamic>{
          bench: <String, dynamic>{'weightUnit': 'lb'},
          squat: <String, dynamic>{'weightUnit': 'kg'},
        },
      );
      expect(u.unitFor(bench), ExerciseWeightUnit.lb);
      expect(u.unitFor(squat), ExerciseWeightUnit.kg);
      expect(u.unitFor('other'), ExerciseWeightUnit.kg);
      expect(u.unitFor(null), ExerciseWeightUnit.kg);
    });

    test('precedence: local choice > block explicit > published > kg', () {
      final ExerciseUnits published = ExerciseUnits(
        published: ExerciseUnits.parsePublished(<String, Object?>{
          bench: 'lb',
          squat: 'stone', // invalid: dropped
        }),
      );
      expect(published.unitFor(bench), ExerciseWeightUnit.lb);
      expect(published.unitFor(squat), ExerciseWeightUnit.kg);
      final ExerciseUnits block = published.withBlockSettings(<String, dynamic>{
        bench: <String, dynamic>{'weightUnit': 'kg'},
      });
      expect(block.unitFor(bench), ExerciseWeightUnit.kg);
      final ExerciseUnits local = ExerciseUnits(
        blockSettings: block.blockSettings,
        published: block.published,
        local: const <String, ExerciseWeightUnit>{bench: ExerciseWeightUnit.lb},
      );
      expect(local.unitFor(bench), ExerciseWeightUnit.lb);
    });

    test('a malformed block value falls back to the published choice', () {
      final ExerciseUnits u = ExerciseUnits(
        blockSettings: <String, dynamic>{
          bench: <String, dynamic>{'weightUnit': 7},
        },
        published: const <String, ExerciseWeightUnit>{
          bench: ExerciseWeightUnit.lb
        },
      );
      expect(u.unitFor(bench), ExerciseWeightUnit.lb);
    });

    test('the registry keeps local choices per athlete and notifies', () {
      final ExerciseUnitRegistry r = ExerciseUnitRegistry();
      int notified = 0;
      r.addListener(() => notified++);
      r.seedPublished('owner', <String, Object?>{bench: 'lb'});
      r.noteLocalChoice('owner', squat, ExerciseWeightUnit.lb);
      final ExerciseUnits owner = r.unitsFor('owner');
      expect(owner.unitFor(bench), ExerciseWeightUnit.lb);
      expect(owner.unitFor(squat), ExerciseWeightUnit.lb);
      expect(r.unitsFor('friend').unitFor(bench), ExerciseWeightUnit.kg);
      expect(notified, 2);
    });
  });

  test('parity: the server parser and constants match', () {
    final String js =
        File('functions/showcase/weight_unit.js').readAsStringSync();
    expect(js.contains('const KG_PER_LB = 0.45359237;'), isTrue);
    expect(js.contains('const LB_PER_KG = 2.2046226218487757;'), isTrue);
    expect(js.contains("const WEIGHT_UNIT_FIELD = 'weightUnit';"), isTrue);
    expect(js.contains("Object.freeze(['kg', 'lb'])"), isTrue);
    expect(kWeightUnitField, 'weightUnit');
  });
}
