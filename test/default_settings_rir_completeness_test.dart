// Source completeness: every default tier the app writes for a NEW exercise
// (seedDefaultsForBlock / ensureExerciseDefaults / BP2 / legacy planner all
// use getDefaultSettings → defaultSettingsPayload) must already carry the
// complete week-1 RIR structure, i.e. the canonical week-1 heal finds nothing
// to fill. Otherwise incomplete RIR data would still be produced today.

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_exercise_defaults_repository.dart';

void main() {
  final tiers = <String, Map<String, dynamic>>{
    for (final name
        in BlockExerciseDefaultsRepository.debugExplicitDefaultNames)
      'name:$name': BlockExerciseDefaultsRepository.defaultSettingsPayload(
          name: name, category: 'Other', bodyPart: ''),
    for (final group in BlockExerciseDefaultsRepository.debugDefaultGroups)
      'group:$group': BlockExerciseDefaultsRepository.defaultSettingsPayload(
          name: '__none__', category: group, bodyPart: ''),
  };

  test('there are default tiers to check', () {
    expect(tiers.length, greaterThan(5));
  });

  for (final e in tiers.entries) {
    test('${e.key}: new-exercise defaults have complete week-1 RIR', () {
      final payload = e.value;
      if (payload.isEmpty) return; // no default tier applies
      expect(BlockExerciseDefaultsRepository.healWeek1RirPlan(payload), isNull,
          reason: 'incomplete week-1 RIR at creation for ${e.key}');
    });
  }
}
