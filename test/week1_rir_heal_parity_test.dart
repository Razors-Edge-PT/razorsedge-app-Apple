// The backfill tool (functions/scripts/week1_rir_fill.js) must apply exactly
// the app's canonical week-1 RIR rule. Both it and this test assert the same
// shared vectors: here, against BlockExerciseDefaultsRepository.healWeek1RirPlan.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_exercise_defaults_repository.dart';

void main() {
  final vectors = jsonDecode(
      File('functions/test/fixtures/week1_rir_fill_vectors.json')
          .readAsStringSync()) as Map<String, dynamic>;

  for (final e in vectors.entries) {
    test('Dart heal matches vector: ${e.key}', () {
      final v = e.value as Map<String, dynamic>;
      final input =
          Map<String, dynamic>.from(jsonDecode(jsonEncode(v['input'])) as Map);
      final healed = BlockExerciseDefaultsRepository.healWeek1RirPlan(input);
      final actual =
          Map<String, dynamic>.from(jsonDecode(jsonEncode(v['input'])) as Map);
      if (healed != null) actual['rirPlan'] = healed;
      expect(jsonEncode(actual), jsonEncode(v['expected']));
    });
  }
}
