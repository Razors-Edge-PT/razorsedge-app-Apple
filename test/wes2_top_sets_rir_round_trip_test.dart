import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_repository.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/workout_model.dart';

/// The reader half of the original user-visible failure.
///
/// The athlete's complaint was not "a field is blank" — it was that Top Sets
/// showed the wrong session as the best one, because an RIR that was typed but
/// never persisted came back as null and was scored as 0. These drive the REAL
/// write path ([FirestoreWes2Repository] over a fake Firestore), the REAL read
/// model ([Workout.fromFirestore] → [SetDetails]) and the REAL E1RM function
/// that `top_sets_screen.dart` delegates to
/// ([PeriodizationModelUtils.calculateE1RM]).
///
/// Nothing in Top Sets is changed by this work: the fix is entirely on the
/// writer side, and these exist to prove the reader was always fine once the
/// value actually reached the document.
void main() {
  const String kAthlete = 'athlete-1';
  const String kExId = 'bench_press_barbell';
  const String kExName = 'Bench Press, Barbell';
  final DateTime kDate = DateTime(2026, 5, 4);

  late FakeFirebaseFirestore firestore;
  late FirestoreWes2Repository repository;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    repository = FirestoreWes2Repository(firestore: firestore);
  });

  Wes2ExerciseRow row({required List<Wes2SetState> sets}) => Wes2ExerciseRow(
        exerciseId: kExId,
        name: kExName,
        circuitIndex: 0,
        orderIndex: 0,
        setCount: sets.length,
        sets: sets,
        source: Wes2RowSource.bb3Planned,
      );

  /// Writes one set the way the ordinary field-save path does: one durable
  /// field patch per field, in the order the athlete fills the row.
  Future<void> saveSet(
    Wes2ExerciseRow r,
    int setIndex, {
    required double weight,
    required int reps,
    double? rir,
  }) async {
    await repository.saveFieldPatch(
      uid: kAthlete,
      date: kDate,
      row: r,
      setIndex: setIndex,
      fieldKey: Wes2FieldKey.weight,
      value: weight,
    );
    await repository.saveFieldPatch(
      uid: kAthlete,
      date: kDate,
      row: r,
      setIndex: setIndex,
      fieldKey: Wes2FieldKey.reps,
      value: reps,
    );
    if (rir != null) {
      await repository.saveFieldPatch(
        uid: kAthlete,
        date: kDate,
        row: r,
        setIndex: setIndex,
        fieldKey: Wes2FieldKey.rir,
        value: rir,
      );
    }
  }

  Future<Workout> readBack() async {
    final DocumentSnapshot<Map<String, dynamic>> snap = await firestore
        .collection('users')
        .doc(kAthlete)
        .collection('workouts')
        .doc('2026-05-04')
        .get();
    return Workout.fromFirestore(snap);
  }

  /// The Top Sets selection, verbatim from `top_sets_screen.dart`: the highest
  /// E1RM across the sets of the named exercise wins. `calculateE1RM` there is
  /// a one-line delegate to [PeriodizationModelUtils.calculateE1RM], which is
  /// what runs here.
  ({SetDetails set, double e1rm})? topSetOf(Workout workout, String name) {
    SetDetails? topSet;
    double highestE1RM = 0.0;
    for (final Exercise exercise in workout.exercises) {
      if (exercise.name != name) continue;
      for (final SetDetails set in exercise.sets) {
        final double e1rm = PeriodizationModelUtils.calculateE1RM(
          set.weight ?? 0.0,
          (set.reps ?? 0).toDouble(),
          set.rir ?? 0.0,
        );
        if (topSet == null || e1rm > highestE1RM) {
          highestE1RM = e1rm;
          topSet = set;
        }
      }
    }
    return topSet == null ? null : (set: topSet, e1rm: highestE1RM);
  }

  // ── TEST 10 ───────────────────────────────────────────────────────────────

  test('TEST 10 — 130 x 5 @ RIR 2 round-trips, and Top Sets scores it with 2.0',
      () async {
    final Wes2ExerciseRow r = row(sets: <Wes2SetState>[
      const Wes2SetState(
        setIndex: 0,
        weight: Wes2FieldState<double>(actualValue: 130),
        reps: Wes2FieldState<int>(actualValue: 5),
        rir: Wes2FieldState<double>(actualValue: 2),
      ),
    ]);
    await saveSet(r, 0, weight: 130, reps: 5, rir: 2);

    final Workout workout = await readBack();
    final SetDetails set = workout.exercises.single.sets.single;
    expect(set.weight, 130.0);
    expect(set.reps, 5);
    expect(set.rir, 2.0);

    // Brzycki on reps+RIR: 130 * 36 / (37 - 7).
    final double withStoredRir = topSetOf(workout, kExName)!.e1rm;
    expect(withStoredRir, closeTo(156.0, 0.001));

    // And that is demonstrably NOT the null/0 answer the lost-RIR bug produced.
    final double asIfRirWereMissing =
        PeriodizationModelUtils.calculateE1RM(130, 5, 0);
    expect(asIfRirWereMissing, closeTo(146.25, 0.001));
    expect(withStoredRir, isNot(closeTo(asIfRirWereMissing, 0.001)));
  });

  // ── TEST 12 ───────────────────────────────────────────────────────────────

  test('TEST 12 — a harder earlier set still wins once its RIR is persisted',
      () async {
    // Set 0 is the real top set. Set 1 is a genuinely lighter performance.
    final Wes2ExerciseRow r = row(sets: <Wes2SetState>[
      const Wes2SetState(
        setIndex: 0,
        weight: Wes2FieldState<double>(actualValue: 130),
        reps: Wes2FieldState<int>(actualValue: 5),
        rir: Wes2FieldState<double>(actualValue: 2),
      ),
      const Wes2SetState(
        setIndex: 1,
        weight: Wes2FieldState<double>(actualValue: 120),
        reps: Wes2FieldState<int>(actualValue: 5),
        rir: Wes2FieldState<double>(actualValue: 1),
      ),
    ]);
    await saveSet(r, 0, weight: 130, reps: 5, rir: 2);
    await saveSet(r, 1, weight: 120, reps: 5, rir: 1);

    final Workout workout = await readBack();
    final ({SetDetails set, double e1rm}) top = topSetOf(workout, kExName)!;

    expect(top.set.weight, 130.0);
    expect(top.set.rir, 2.0);
    expect(top.e1rm, closeTo(156.0, 0.001));

    // The exact regression: with set 0's RIR lost it scores 146.25, the later
    // 120 x 5 @ RIR 1 scores 139.35, and the wrong session is reported as the
    // athlete's best. Persisting the RIR is what puts set 0 back on top.
    expect(PeriodizationModelUtils.calculateE1RM(120, 5, 1),
        closeTo(139.355, 0.01));
  });

  // ── Null RIR stays null all the way through ───────────────────────────────

  test('an unentered RIR reaches the model as null, never as the hint',
      () async {
    final Wes2ExerciseRow r = row(sets: <Wes2SetState>[
      const Wes2SetState(
        setIndex: 0,
        weight: Wes2FieldState<double>(actualValue: 130),
        reps: Wes2FieldState<int>(actualValue: 5),
        // A displayed suggestion of 2 that the athlete never accepted.
        rir: Wes2FieldState<double>(
          hintValue: 2,
          hintOrigin: FieldOrigin.bb3Hint,
        ),
      ),
    ]);
    await saveSet(r, 0, weight: 130, reps: 5);
    await repository.setMarkedDone(
      uid: kAthlete,
      date: kDate,
      row: r,
      isDone: true,
    );

    final Workout workout = await readBack();
    expect(workout.exercises.single.sets.single.rir, isNull);

    final DocumentSnapshot<Map<String, dynamic>> snap = await firestore
        .collection('users')
        .doc(kAthlete)
        .collection('workouts')
        .doc('2026-05-04')
        .get();
    final Map<String, dynamic> stored = (snap.data()!['exercises'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .single;
    expect(stored['isMarkedDone'], isTrue);
    expect((stored['sets'] as List<dynamic>).cast<Map<String, dynamic>>().single,
        isNot(contains('rir')),
        reason: 'Done wrote the checkmark and nothing else');
  });
}
