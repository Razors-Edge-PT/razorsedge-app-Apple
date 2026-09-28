import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/top_sets_bodyweight_metrics.dart';
import 'package:localtest222/top_sets_screen.dart';
import 'package:localtest222/units/weight_unit.dart';
import 'package:localtest222/workout_model.dart';

SetDetails _set({
  required double weight,
  required int reps,
  double rir = 0,
  int? setIndex,
  double? weightAdded,
}) =>
    SetDetails(
      weight: weight,
      reps: reps,
      rir: rir,
      setIndex: setIndex,
      weightAdded: weightAdded,
    );

void main() {
  test('signed labels preserve zero and assisted external loads', () {
    expect(formatSignedTopSetWeightKg(0, ExerciseWeightUnit.kg), '+0 kg');
    expect(formatSignedTopSetWeightKg(-10, ExerciseWeightUnit.kg), '-10 kg');
    expect(formatSignedTopSetWeightKg(20, ExerciseWeightUnit.kg), '+20 kg');
  });

  test('WES2 zero means zero added load, not the athlete bodyweight', () {
    final metrics = topSetBodyweightMetrics(
      _set(weight: 0, reps: 5, rir: 1, setIndex: 1),
      70,
    );

    expect(metrics.load.addedKg, 0);
    expect(metrics.load.totalKg, 70);
    expect(metrics.rankTier, 2);
    expect(metrics.addedE1rmKg, isNotNull);
  });

  test('WES2 added load remains distinct from total system load', () {
    final metrics = topSetBodyweightMetrics(
      _set(weight: 20, reps: 5, rir: 1, setIndex: 1),
      70,
    );

    expect(metrics.load.addedKg, 20);
    expect(metrics.load.totalKg, 90);
  });

  test('legacy assisted performance preserves a negative added load', () {
    final metrics = topSetBodyweightMetrics(_set(weight: 60, reps: 5), 70);

    expect(metrics.load.addedKg, -10);
    expect(metrics.load.totalKg, 60);
    expect(metrics.addedE1rmKg, lessThan(0));
  });

  test('missing historical bodyweight never invents an added-load E1RM', () {
    final wes2 = topSetBodyweightMetrics(
      _set(weight: 15, reps: 5, setIndex: 1),
      null,
    );
    final legacy = topSetBodyweightMetrics(_set(weight: 85, reps: 5), null);

    expect(wes2.load.addedKg, 15);
    expect(wes2.addedE1rmKg, isNull);
    expect(wes2.rankTier, 1);
    expect(legacy.load.addedKg, isNull);
    expect(legacy.addedE1rmKg, isNull);
    expect(legacy.rankTier, 0);
  });

  test('ranking uses added performance and preserves assisted values', () {
    final bodyweightOnly = topSetBodyweightMetrics(
      _set(weight: 0, reps: 5, setIndex: 1),
      70,
    );
    final weighted = topSetBodyweightMetrics(
      _set(weight: 20, reps: 5, setIndex: 1),
      70,
    );
    final lessAssisted = topSetBodyweightMetrics(_set(weight: 65, reps: 5), 70);
    final moreAssisted = topSetBodyweightMetrics(_set(weight: 60, reps: 5), 70);

    expect(bodyweightTopSetBeats(weighted, bodyweightOnly), isTrue);
    expect(bodyweightTopSetBeats(lessAssisted, moreAssisted), isTrue);
  });
}
