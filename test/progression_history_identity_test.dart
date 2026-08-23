import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/periodization_model_utils.dart';

/// Regression tests for the progression-history identity bug.
///
/// Invariant under test: every progression model reached through
/// [PeriodizationModelUtils.getWeightByProgressionModel] must use the
/// `topSetHistory` handed to it by the router. Identity resolution
/// (exerciseId first, legacy name fallback) happens once, upstream in
/// progression_engine.dart — never inside an individual model.
///
/// The production symptom: "One Arm Row, Dumbbell" history was stored under an
/// exercise ID, the model re-queried `topSetsByExercise[exerciseName]`, found
/// nothing, and returned the 5 kg dumbbell default.

const String kExerciseName = 'One Arm Row, Dumbbell';

/// Dumbbell increment grid as the engine builds it (5 kg default at the bottom).
const List<double> kDumbbellIncrements = <double>[
  5.0,
  7.5,
  10.0,
  12.5,
  15.0,
  17.5,
  20.0,
  22.5,
  25.0,
  27.5,
  30.0,
  32.5,
  35.0,
];

/// Realistic ID-keyed history: 25 kg × 10 @ RIR 1, recent.
List<Map<String, dynamic>> _idKeyedHistory() {
  final DateTime now = DateTime.now();
  return <Map<String, dynamic>>[
    {
      'weight': 25.0,
      'reps': 10,
      'rir': 1.0,
      'date': now.subtract(const Duration(days: 7)),
    },
    {
      'weight': 25.0,
      'reps': 9,
      'rir': 1.0,
      'date': now.subtract(const Duration(days: 14)),
    },
    {
      'weight': 22.5,
      'reps': 10,
      'rir': 1.0,
      'date': now.subtract(const Duration(days: 21)),
    },
  ];
}

/// Deliberately wrong name-keyed history — light, stale, and nothing like the
/// routed history. If a model secretly re-queries by name, results collapse
/// toward this.
List<Map<String, dynamic>> _conflictingNameKeyedHistory() {
  final DateTime now = DateTime.now();
  return <Map<String, dynamic>>[
    {
      'weight': 5.0,
      'reps': 5,
      'rir': 3.0,
      'date': now.subtract(const Duration(days: 400)),
    },
  ];
}

Map<String, dynamic> _run(
  ProgressionModelType model, {
  required List<Map<String, dynamic>>? topSetHistory,
}) {
  return PeriodizationModelUtils.getWeightByProgressionModel(
    model: model,
    exerciseName: kExerciseName,
    repTarget: 10,
    defaultWeight: 5.0, // the bogus dumbbell fallback we must never see
    increments: kDumbbellIncrements,
    topSetHistory: topSetHistory,
    weekIndex: 1, // week 2+ — past the week-1 short circuit
    rirValue: 1.0,
  );
}

void main() {
  setUp(() {
    // No name-keyed history anywhere: history exists ONLY via the routed
    // (ID-resolved) topSetHistory argument.
    PeriodizationModelUtils.topSetsByExercise.clear();
    PeriodizationModelUtils.savedWorkoutsList.clear();
  });

  tearDown(() {
    PeriodizationModelUtils.topSetsByExercise.clear();
    PeriodizationModelUtils.savedWorkoutsList.clear();
  });

  group('ID-keyed history only (no topSetsByExercise[name] entry)', () {
    for (final entry in <String, ProgressionModelType>{
      'Add Reps': ProgressionModelType.addRepsProgressionModel,
      'Smart Progression': ProgressionModelType.smartProgression,
      'Linear Weight Increase': ProgressionModelType.linearWeightIncrease,
    }.entries) {
      test('${entry.key} uses routed history and does not fall back to 5 kg',
          () {
        expect(
          PeriodizationModelUtils.topSetsByExercise[kExerciseName],
          isNull,
          reason: 'the bug only reproduces when no name-keyed entry exists',
        );

        final result = _run(entry.value, topSetHistory: _idKeyedHistory());
        final double weight = (result['weight'] as num).toDouble();

        expect(weight, isNot(5.0),
            reason: '${entry.key} fell back to the default dumbbell weight, '
                'which means it ignored the routed history');
        expect(weight, greaterThanOrEqualTo(20.0),
            reason: '${entry.key} should land near the 25 kg × 10 history');
      });
    }
  });

  group('routed history wins over conflicting name-keyed global', () {
    for (final entry in <String, ProgressionModelType>{
      'Add Reps': ProgressionModelType.addRepsProgressionModel,
      'Smart Progression': ProgressionModelType.smartProgression,
      'Linear Weight Increase': ProgressionModelType.linearWeightIncrease,
    }.entries) {
      test('${entry.key} ignores topSetsByExercise[exerciseName]', () {
        // Poison the global name-keyed map with wrong history.
        PeriodizationModelUtils.topSetsByExercise[kExerciseName] =
            _conflictingNameKeyedHistory();

        final result = _run(entry.value, topSetHistory: _idKeyedHistory());
        final double weight = (result['weight'] as num).toDouble();

        expect(weight, greaterThanOrEqualTo(20.0),
            reason: '${entry.key} used the poisoned name-keyed history instead '
                'of the router-supplied topSetHistory');
      });

      test('${entry.key} does not mutate the global name-keyed history', () {
        final poisoned = _conflictingNameKeyedHistory();
        PeriodizationModelUtils.topSetsByExercise[kExerciseName] = poisoned;

        _run(entry.value, topSetHistory: _idKeyedHistory());

        expect(
          PeriodizationModelUtils.topSetsByExercise[kExerciseName],
          same(poisoned),
        );
        expect(poisoned.single['weight'], 5.0);
      });
    }
  });

  group('empty routed history', () {
    test(
        'Add Reps returns the default when routed history is empty, even with '
        'a name-keyed entry present', () {
      PeriodizationModelUtils.topSetsByExercise[kExerciseName] =
          _idKeyedHistory();

      final result = _run(
        ProgressionModelType.addRepsProgressionModel,
        topSetHistory: const <Map<String, dynamic>>[],
      );

      expect((result['weight'] as num).toDouble(), 5.0,
          reason: 'an empty routed history must NOT be topped up by a name '
              'lookup inside the model');
    });
  });

  group('source invariant: no name-keyed history lookups inside models', () {
    // Behavioural tests cannot catch a dormant `topSetHistory.isNotEmpty ? ... :
    // topSetsByExercise[name]` fallback, because it only fires when the routed
    // history is empty. Guard the architecture directly instead.
    final String source =
        File('lib/periodization_model_utils.dart').readAsStringSync();

    String bodyOf(String signature) {
      final int start = source.indexOf(signature);
      expect(start, isNonNegative, reason: 'signature not found: $signature');
      final int end =
          source.indexOf(RegExp(r'\n  static '), start + signature.length);
      return source.substring(start, end == -1 ? source.length : end);
    }

    for (final signature in <String>[
      'static double getProgressedWeight({',
      'static Map<String, dynamic> smartProgressionModel({',
      'static Map<String, dynamic> addRepsProgressionModel({',
      'static Map<String, dynamic> getWeightByProgressionModel({',
    ]) {
      test('$signature performs no topSetsByExercise lookup', () {
        expect(
          bodyOf(signature),
          isNot(contains('topSetsByExercise[')),
          reason: 'exercise identity must be resolved once, upstream in '
              'progression_engine.dart — never inside a progression model or '
              'the router',
        );
      });
    }
  });
}
