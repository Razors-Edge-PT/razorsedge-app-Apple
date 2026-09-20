// functions/coach/bodyweight_exercises.js decides which exercises the coach PB
// engine compares on total load. It must name exactly the exercises the app
// treats as bodyweight exercises (PeriodizationModelUtils.isBodyweightExercise),
// or the server and the app would read the same set in different bases.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/exercise_type.dart';
import 'package:localtest222/periodization_model_utils.dart';

List<String> _quotedBetween(String source, String start, String end) {
  final int from = source.indexOf(start);
  final int to = source.indexOf(end, from + 1);
  expect(from, greaterThanOrEqualTo(0), reason: 'marker $start');
  expect(to, greaterThan(from), reason: 'marker $end');
  return RegExp(r"'([^']+)'")
      .allMatches(source.substring(from, to))
      .map((Match m) => m.group(1)!)
      .toList();
}

void main() {
  final String js =
      File('functions/coach/bodyweight_exercises.js').readAsStringSync();

  test('the same catalogue ids', () {
    final List<String> ids = _quotedBetween(js, '// ids:start', '// ids:end');
    expect(ids.toSet(), PeriodizationModelUtils.debugBodyweightExerciseIds);
    expect(ids.length, ids.toSet().length, reason: 'no duplicates');
  });

  test('the same display names', () {
    final List<String> names =
        _quotedBetween(js, '// names:start', '// names:end');
    expect(names.toSet(), PeriodizationModelUtils.debugBodyweightExerciseNames);
    expect(names.length, names.toSet().length, reason: 'no duplicates');
  });

  test('the same catalogue type', () {
    // The second, data-driven half of the rule: an exercise also qualifies
    // when its catalogue `type` is this exact value. The two sides must name
    // the same string, or a "Body Weight" exercise would be normalised on one
    // side and read raw on the other.
    expect(
      _quotedBetween(js, '// type:start', '// type:end'),
      <String>[kBodyweightExerciseType],
    );
  });

  test('the same classification behaviour for a typed exercise', () {
    // An id in NEITHER list, qualifying purely by type — the case the whole
    // change exists for.
    expect(
      PeriodizationModelUtils.isBodyweightExercise(
          id: 'parity-unknown-id', name: 'Parity Unknown', type: ' body WEIGHT '),
      isTrue,
    );
    expect(
      PeriodizationModelUtils.isBodyweightExercise(
          id: 'parity-unknown-id', name: 'Parity Unknown', type: 'Barbell'),
      isFalse,
    );
  });
}
