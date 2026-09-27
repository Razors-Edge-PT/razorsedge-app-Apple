// Ordinary WES2 (no BB3 prescription) must match unchanged origin/main.
//
// The golden values were captured from origin/main (fdc94e41) by the
// two-tree parity harness over every rep model × progression model × date ×
// typed-input shape (7,680 cases; zero differences outside the approved
// strict-before same-day-history cases). This suite pins a representative
// sample of those cases — every rep model, two progression models, three
// dates without same-day history, four input shapes, plus bodyweight and
// timed exercises — comparing every set's values, the set count and the
// provenance of every field.

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/periodization_model_utils.dart';

import 'support/wes2_origin_main_golden.dart';
import 'support/wes2_parity_fixture.dart';

/// JavaScript `String(number)` formatting, as used when the golden was
/// captured (95.0 → "95", 1.25 → "1.25").
String _num(Object? v) {
  if (v == null) return '-';
  if (v is double && v == v.truncateToDouble()) return v.toInt().toString();
  return v.toString();
}

String _field(Wes2FieldState<Object> f) => <String>[
      _num(f.actualValue),
      _num(f.hintValue),
      f.origin.name,
      f.hintOrigin.name,
    ].join(',');

String _encode(Wes2ExerciseRow r) =>
    '${r.setCount}#${r.sets.map((s) => '${_field(s.weight)};${_field(s.reps)};${_field(s.rir)}').join('|')}';

const Map<String, Ex> _exercises = <String, Ex>{
  'Parity Cable Pull': kPlain,
  'Chin-Up': kChin,
  'Weighted Plank': kPlank,
};

void main() {
  tearDown(() {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  for (final MapEntry<String, String> g in kOriginMainGolden.entries) {
    test(g.key, () {
      final List<String> p = g.key.split('|');
      final Ex ex = _exercises[p[1]]!;
      final Typed input = kInputs.firstWhere((Typed t) => t.name == p[5]);
      final List<int> ymd = p[4].split('-').map(int.parse).toList();
      PeriodizationModelUtils.savedWorkoutsList = historyFor(ex);
      PeriodizationModelUtils.topSetsByExercise.clear();
      final Wes2ExerciseRow out = Wes2HintServiceImpl(
        exerciseSettings: <String, dynamic>{ex.id: settingsFor(p[2], p[3])},
        blockStartDate: kBlockStart,
        blockEndDate: kBlockEnd,
        uid: kUid,
      ).resolveRow(
        row: rowFor(ex, input),
        prescriptions: Wes2Prescriptions.none,
        uid: kUid,
        date: DateTime(ymd[0], ymd[1], ymd[2]),
      );
      expect(_encode(out), g.value);
    });
  }
}
