import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_finalisation.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_repository.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/workout_model.dart';

/// Marking a WES2 exercise Done must durably store the RIR the athlete
/// actually completed each performed set with.
///
/// The hazard these pin: WES2 shows RIR as `actualValue ?? hintValue` and
/// computes the on-screen E1RM from that resolved value, while the writer
/// persisted actualValues only. An athlete who logged 130 kg x 5 while simply
/// accepting the displayed RIR 2.0 saw E1RM 156.0 on the row, and the
/// completed workout stored `rir: null` — which Top Sets, PBs and progression
/// all read back as RIR 0 (E1RM 146.3). History then disagreed with the
/// workout that was actually performed, and a weaker later set could win the
/// day's top set.

const String kUid = 'athlete-1';
final DateTime kDate = DateTime(2026, 3, 14);
const String kDocId = '2026-03-14';
const String kExId = 'bench_press_barbell';

/// The E1RM WES2 renders on the row for 130 x 5 @ RIR 2.0.
final double kE1rmAtRir2 = PeriodizationModelUtils.calculateE1RM(130, 5, 2.0);

/// What the same set collapses to once its RIR is lost and a reader
/// substitutes 0. This is the number that appeared in Top Sets.
final double kE1rmAtRir0 = PeriodizationModelUtils.calculateE1RM(130, 5, 0.0);

Wes2FieldState<double> _dbl({double? actual, double? hint}) =>
    Wes2FieldState<double>(
      actualValue: actual,
      hintValue: hint,
      origin: actual != null ? FieldOrigin.typed : FieldOrigin.bb3Hint,
      hintOrigin: hint != null ? FieldOrigin.bb3Hint : FieldOrigin.empty,
    );

Wes2FieldState<int> _int({int? actual, int? hint}) => Wes2FieldState<int>(
      actualValue: actual,
      hintValue: hint,
      origin: actual != null ? FieldOrigin.typed : FieldOrigin.bb3Hint,
      hintOrigin: hint != null ? FieldOrigin.bb3Hint : FieldOrigin.empty,
    );

/// One BB3-planned set: hints always present, actuals only when logged.
Wes2SetState _plannedSet(
  int i, {
  double? weight,
  int? reps,
  double? rir,
  double weightHint = 130,
  int repsHint = 5,
  double? rirHint = 2.0,
  double? velocity,
  String? setId,
  String? executionNote,
}) =>
    Wes2SetState(
      setIndex: i,
      setId: setId,
      weight: _dbl(actual: weight, hint: weightHint),
      reps: _int(actual: reps, hint: repsHint),
      rir: _dbl(actual: rir, hint: rirHint),
      velocity: Wes2FieldState<double>(actualValue: velocity),
      executionNote: executionNote,
    );

Wes2ExerciseRow _row(
  List<Wes2SetState> sets, {
  Wes2RowSource source = Wes2RowSource.bb3Planned,
  String exerciseId = kExId,
  int orderIndex = 0,
  String? exerciseExecutionNote,
}) =>
    Wes2ExerciseRow(
      exerciseId: exerciseId,
      name: 'Bench Press, Barbell',
      circuitIndex: 0,
      orderIndex: orderIndex,
      setCount: sets.length,
      sets: sets,
      source: source,
      exerciseExecutionNote: exerciseExecutionNote,
    );

DocumentReference<Map<String, dynamic>> _dayRef(FakeFirebaseFirestore db) =>
    db.collection('users').doc(kUid).collection('workouts').doc(kDocId);

Future<List<Map<String, dynamic>>> _storedSets(
  FakeFirebaseFirestore db, {
  String exerciseId = kExId,
}) async {
  final row = await _storedRow(db, exerciseId: exerciseId);
  return (row['sets'] as List<dynamic>).cast<Map<String, dynamic>>();
}

Future<Map<String, dynamic>> _storedRow(
  FakeFirebaseFirestore db, {
  String exerciseId = kExId,
}) async {
  final snap = await _dayRef(db).get();
  final rows = (snap.data()?['exercises'] as List<dynamic>? ?? <dynamic>[])
      .cast<Map<String, dynamic>>();
  return rows.firstWhere((r) => r['exerciseId'] == exerciseId);
}

/// Seeds the workout document the way the ordinary field-patch path would
/// have left it: actual weight/reps saved on unfocus, RIR never typed so
/// never written.
Future<void> _seedCompletedRow(
  FakeFirebaseFirestore db,
  List<Map<String, dynamic>> sets, {
  int setCount = 1,
  Map<String, dynamic> extraRowFields = const <String, dynamic>{},
  List<Map<String, dynamic>> otherRows = const <Map<String, dynamic>>[],
}) async {
  await _dayRef(db).set(<String, dynamic>{
    'userId': kUid,
    'date': kDocId,
    'exercises': <Map<String, dynamic>>[
      <String, dynamic>{
        'exerciseId': kExId,
        'name': 'Bench Press, Barbell',
        'circuitIndex': 0,
        'orderIndex': 0,
        'setCount': setCount,
        'isMarkedDone': false,
        'sets': sets,
        ...extraRowFields,
      },
      ...otherRows,
    ],
    'wesPlannedExercises': <Map<String, dynamic>>[],
  });
}

void main() {
  late FakeFirebaseFirestore db;
  late FirestoreWes2Repository repo;

  setUp(() {
    db = FakeFirebaseFirestore();
    repo = FirestoreWes2Repository(firestore: db);
  });

  // ── The rule itself ────────────────────────────────────────────────────────

  group('wes2FinalisedPerformedSets — the finalisation rule', () {
    test('an accepted displayed RIR becomes the completed RIR', () {
      final out = wes2FinalisedPerformedSets(
        _row(<Wes2SetState>[_plannedSet(0, weight: 130, reps: 5)]),
      );
      expect(out, hasLength(1));
      expect(out.single.rir, 2.0);
      expect(out.single.weight, 130);
      expect(out.single.reps, 5);
    });

    test('a typed RIR is returned untouched, never replaced by the hint', () {
      final out = wes2FinalisedPerformedSets(
        _row(<Wes2SetState>[
          _plannedSet(0, weight: 130, reps: 5, rir: 1.5, rirHint: 2.0),
        ]),
      );
      expect(out.single.rir, 1.5);
    });

    test('an explicit RIR 0 is a real value, not a missing one', () {
      final out = wes2FinalisedPerformedSets(
        _row(<Wes2SetState>[
          _plannedSet(0, weight: 130, reps: 5, rir: 0.0, rirHint: 2.0),
        ]),
      );
      expect(out.single.rir, 0.0);
    });

    test('a set with hints but no actuals yields nothing', () {
      expect(wes2FinalisedPerformedSets(_row(<Wes2SetState>[_plannedSet(0)])),
          isEmpty);
    });

    test('weight without reps, or reps without weight, is not performed', () {
      expect(
        wes2FinalisedPerformedSets(
            _row(<Wes2SetState>[_plannedSet(0, weight: 130)])),
        isEmpty,
      );
      expect(
        wes2FinalisedPerformedSets(
            _row(<Wes2SetState>[_plannedSet(0, reps: 5)])),
        isEmpty,
      );
    });

    test('no RIR at all (timed row) finalises weight/reps with a null RIR', () {
      final out = wes2FinalisedPerformedSets(
        _row(<Wes2SetState>[
          _plannedSet(0, weight: 130, reps: 5, rirHint: null),
        ]),
      );
      expect(out.single.rir, isNull);
    });

    test('weight and reps hints are never promoted to actuals', () {
      final out = wes2FinalisedPerformedSets(
        _row(<Wes2SetState>[
          _plannedSet(0, weight: 125, reps: 4, weightHint: 130, repsHint: 5),
        ]),
      );
      expect(out.single.weight, 125);
      expect(out.single.reps, 4);
    });

    test('the rule is index-independent: planned and added sets are equal', () {
      // Set 0 is an originally prescribed set, set 4 an Add Set extra. Both
      // carry actual weight/reps and an unaccepted RIR hint, and both must
      // finalise. There is no "sets 1-4 are different" branch to trip over.
      final out = wes2FinalisedPerformedSets(_row(<Wes2SetState>[
        _plannedSet(0, weight: 130, reps: 5),
        _plannedSet(1),
        _plannedSet(2),
        _plannedSet(3),
        _plannedSet(4, weight: 120, reps: 8, rirHint: 1.0),
      ]));
      expect(out.map((f) => f.setIndex), <int>[0, 4]);
      expect(out.map((f) => f.rir), <double>[2.0, 1.0]);
    });
  });

  // ── TEST 1 — BB3 planned RIR accepted implicitly ──────────────────────────

  group('TEST 1 — BB3 planned RIR accepted implicitly', () {
    test('Done stores rir 2.0 for a 130 x 5 set whose RIR was never typed',
        () async {
      await _seedCompletedRow(db, <Map<String, dynamic>>[
        <String, dynamic>{'setIndex': 0, 'weight': 130, 'reps': 5},
      ]);

      await repo.setMarkedDone(
        uid: kUid,
        date: kDate,
        row: _row(<Wes2SetState>[_plannedSet(0, weight: 130, reps: 5)]),
        isDone: true,
      );

      final sets = await _storedSets(db);
      expect(sets.single['weight'], 130);
      expect(sets.single['reps'], 5);
      expect(sets.single['rir'], 2.0);
      expect((await _storedRow(db))['isMarkedDone'], isTrue);
    });

    test('a BB3 row not yet in the document is created carrying its RIR',
        () async {
      // Nothing has been written for this day at all — the create path.
      await repo.setMarkedDone(
        uid: kUid,
        date: kDate,
        row: _row(<Wes2SetState>[_plannedSet(0, weight: 130, reps: 5)]),
        isDone: true,
      );

      final sets = await _storedSets(db);
      expect(sets.single['weight'], 130);
      expect(sets.single['reps'], 5);
      expect(sets.single['rir'], 2.0);
    });

    test('a wesPlanned row is promoted carrying its RIR', () async {
      await _dayRef(db).set(<String, dynamic>{
        'userId': kUid,
        'date': kDocId,
        'exercises': <Map<String, dynamic>>[],
        'wesPlannedExercises': <Map<String, dynamic>>[
          <String, dynamic>{
            'exerciseId': kExId,
            'name': 'Bench Press, Barbell',
            'circuitIndex': 0,
            'orderIndex': 0,
            'setCount': 1,
            'sets': <Map<String, dynamic>>[],
          },
        ],
      });

      await repo.setMarkedDone(
        uid: kUid,
        date: kDate,
        row: _row(<Wes2SetState>[_plannedSet(0, weight: 130, reps: 5)],
            source: Wes2RowSource.wes2Manual),
        isDone: true,
      );

      final sets = await _storedSets(db);
      expect(sets.single['rir'], 2.0);
      final snap = await _dayRef(db).get();
      expect(snap.data()!['wesPlannedExercises'], isEmpty);
    });
  });

  // ── TEST 2 — E1RM / history consistency ───────────────────────────────────

  group('TEST 2 — history reads back the E1RM WES2 displayed', () {
    test('the completed workout computes 156.0, not the 146.3 of a null RIR',
        () async {
      await _seedCompletedRow(db, <Map<String, dynamic>>[
        <String, dynamic>{'setIndex': 0, 'weight': 130, 'reps': 5},
      ]);
      await repo.setMarkedDone(
        uid: kUid,
        date: kDate,
        row: _row(<Wes2SetState>[_plannedSet(0, weight: 130, reps: 5)]),
        isDone: true,
      );

      // Read it back exactly as Top Sets does: through Workout.fromFirestore,
      // then the same `s.rir ?? 0` fallback its ranking uses.
      final workout = Workout.fromFirestore(await _dayRef(db).get());
      final SetDetails s = workout.exercises.single.sets.single;
      expect(s.rir, 2.0);

      final double historyE1rm = PeriodizationModelUtils.calculateE1RM(
        s.weight ?? 0,
        (s.reps ?? 0).toDouble(),
        s.rir ?? 0,
      );
      expect(historyE1rm, closeTo(kE1rmAtRir2, 0.001));
      expect(historyE1rm, closeTo(156.0, 0.05));
      expect(historyE1rm, isNot(closeTo(kE1rmAtRir0, 0.001)));
    });

    test('the strongest set still ranks top after finalisation', () async {
      // The reported failure: a 130x5 @ RIR 2 opener losing its RIR let a
      // weaker 120x5 @ RIR 1 later set win the day.
      await _seedCompletedRow(
        db,
        <Map<String, dynamic>>[
          <String, dynamic>{'setIndex': 0, 'weight': 130, 'reps': 5},
          <String, dynamic>{'setIndex': 1, 'weight': 120, 'reps': 5, 'rir': 1.0},
        ],
        setCount: 2,
      );
      await repo.setMarkedDone(
        uid: kUid,
        date: kDate,
        row: _row(<Wes2SetState>[
          _plannedSet(0, weight: 130, reps: 5),
          _plannedSet(1, weight: 120, reps: 5, rir: 1.0),
        ]),
        isDone: true,
      );

      final workout = Workout.fromFirestore(await _dayRef(db).get());
      final List<double> e1rms = workout.exercises.single.sets
          .map((s) => PeriodizationModelUtils.calculateE1RM(
              s.weight ?? 0, (s.reps ?? 0).toDouble(), s.rir ?? 0))
          .toList();
      expect(e1rms.first, greaterThan(e1rms.last));
    });
  });

  // ── TEST 3 — manual RIR wins ──────────────────────────────────────────────

  test('TEST 3 — a manually entered RIR is never replaced by the hint',
      () async {
    await _seedCompletedRow(db, <Map<String, dynamic>>[
      <String, dynamic>{'setIndex': 0, 'weight': 130, 'reps': 5, 'rir': 1.5},
    ]);

    await repo.setMarkedDone(
      uid: kUid,
      date: kDate,
      row: _row(<Wes2SetState>[
        _plannedSet(0, weight: 130, reps: 5, rir: 1.5, rirHint: 2.0),
      ]),
      isDone: true,
    );

    expect((await _storedSets(db)).single['rir'], 1.5);
  });

  // ── TEST 4 — blank planned sets stay blank ────────────────────────────────

  test('TEST 4 — planned sets with hints only do not become completed sets',
      () async {
    await _seedCompletedRow(
      db,
      <Map<String, dynamic>>[
        <String, dynamic>{'setIndex': 0, 'weight': 130, 'reps': 5},
        <String, dynamic>{'setIndex': 1, 'weight': 130, 'reps': 5},
      ],
      setCount: 4,
    );

    await repo.setMarkedDone(
      uid: kUid,
      date: kDate,
      row: _row(<Wes2SetState>[
        _plannedSet(0, weight: 130, reps: 5),
        _plannedSet(1, weight: 130, reps: 5),
        _plannedSet(2), // hints only
        _plannedSet(3), // hints only
      ]),
      isDone: true,
    );

    final sets = await _storedSets(db);
    expect(sets, hasLength(2),
        reason: 'no set map may be minted for an unperformed planned set');
    expect(sets[0]['rir'], 2.0);
    expect(sets[1]['rir'], 2.0);
    // setCount is the plan's, and is never shrunk by finalisation.
    expect((await _storedRow(db))['setCount'], 4);
  });

  test('TEST 4b — a stored blank set map is left completely untouched',
      () async {
    await _seedCompletedRow(
      db,
      <Map<String, dynamic>>[
        <String, dynamic>{'setIndex': 0, 'weight': 130, 'reps': 5},
        <String, dynamic>{'setIndex': 1},
      ],
      setCount: 2,
    );

    await repo.setMarkedDone(
      uid: kUid,
      date: kDate,
      row: _row(<Wes2SetState>[
        _plannedSet(0, weight: 130, reps: 5),
        _plannedSet(1),
      ]),
      isDone: true,
    );

    final sets = await _storedSets(db);
    expect(sets[1], <String, dynamic>{'setIndex': 1});
  });

  // ── TEST 5 — multiple completed planned sets ──────────────────────────────

  test('TEST 5 — every performed set persists its own accepted RIR', () async {
    await _seedCompletedRow(
      db,
      <Map<String, dynamic>>[
        <String, dynamic>{'setIndex': 0, 'weight': 130, 'reps': 5},
        <String, dynamic>{'setIndex': 1, 'weight': 130, 'reps': 4},
        <String, dynamic>{'setIndex': 2, 'weight': 125, 'reps': 4},
      ],
      setCount: 3,
    );

    await repo.setMarkedDone(
      uid: kUid,
      date: kDate,
      row: _row(<Wes2SetState>[
        _plannedSet(0, weight: 130, reps: 5, rirHint: 2.0),
        _plannedSet(1, weight: 130, reps: 4, rirHint: 1.5),
        _plannedSet(2, weight: 125, reps: 4, rirHint: 1.0),
      ]),
      isDone: true,
    );

    final sets = await _storedSets(db);
    expect(sets.map((s) => s['rir']).toList(), <double>[2.0, 1.5, 1.0]);
    expect(sets.map((s) => s['reps']).toList(), <int>[5, 4, 4]);
  });

  // ── TEST 6 — added set ────────────────────────────────────────────────────

  test('TEST 6 — an Add Set extra finalises by the same rule', () async {
    // Four prescribed sets plus a fifth added during the session. The extra
    // set's RIR hint is model-resolved rather than BB3-locked; finalisation
    // does not care which.
    await _seedCompletedRow(
      db,
      <Map<String, dynamic>>[
        <String, dynamic>{'setIndex': 0, 'weight': 130, 'reps': 5},
        <String, dynamic>{'setIndex': 1, 'weight': 130, 'reps': 5},
        <String, dynamic>{'setIndex': 2, 'weight': 130, 'reps': 5},
        <String, dynamic>{'setIndex': 3, 'weight': 130, 'reps': 5},
        <String, dynamic>{'setIndex': 4, 'weight': 110, 'reps': 8},
      ],
      setCount: 5,
    );

    await repo.setMarkedDone(
      uid: kUid,
      date: kDate,
      row: _row(<Wes2SetState>[
        _plannedSet(0, weight: 130, reps: 5),
        _plannedSet(1, weight: 130, reps: 5),
        _plannedSet(2, weight: 130, reps: 5),
        _plannedSet(3, weight: 130, reps: 5),
        Wes2SetState(
          setIndex: 4,
          setId: 'added-set-uuid',
          weight: _dbl(actual: 110),
          reps: _int(actual: 8),
          rir: const Wes2FieldState<double>(
            hintValue: 0.5,
            hintOrigin: FieldOrigin.modelHint,
            origin: FieldOrigin.modelHint,
          ),
        ),
      ]),
      isDone: true,
    );

    final sets = await _storedSets(db);
    expect(sets, hasLength(5));
    expect(sets[4]['rir'], 0.5);
    expect(sets[4]['weight'], 110);
    expect(sets.take(4).map((s) => s['rir']).toList(),
        <double>[2.0, 2.0, 2.0, 2.0]);
  });

  test('TEST 6b — a performed set missing from the document is created',
      () async {
    // The added set's own field patch has not committed yet. Finalisation
    // pads to it rather than dropping the athlete's values.
    await _seedCompletedRow(
      db,
      <Map<String, dynamic>>[
        <String, dynamic>{'setIndex': 0, 'weight': 130, 'reps': 5},
      ],
      setCount: 1,
    );

    await repo.setMarkedDone(
      uid: kUid,
      date: kDate,
      row: _row(<Wes2SetState>[
        _plannedSet(0, weight: 130, reps: 5),
        _plannedSet(1, weight: 110, reps: 8, rirHint: 0.5),
      ]),
      isDone: true,
    );

    final sets = await _storedSets(db);
    expect(sets, hasLength(2));
    expect(sets[1]['weight'], 110);
    expect(sets[1]['reps'], 8);
    expect(sets[1]['rir'], 0.5);
    expect((await _storedRow(db))['setCount'], 2);
  });

  // ── TEST 7 — Done / Not Done / Done ───────────────────────────────────────

  test('TEST 7 — toggling Done off and on loses or corrupts nothing', () async {
    await _seedCompletedRow(
      db,
      <Map<String, dynamic>>[
        <String, dynamic>{
          'setIndex': 0,
          'setId': 'proof-set-1',
          'weight': 130,
          'reps': 5,
          'executionNote': 'felt smooth',
        },
        <String, dynamic>{'setIndex': 1, 'weight': 130, 'reps': 4, 'rir': 0},
      ],
      setCount: 2,
      extraRowFields: <String, dynamic>{
        'exerciseExecutionNote': 'shoulder ok today',
      },
    );

    final row = _row(<Wes2SetState>[
      _plannedSet(0,
          weight: 130,
          reps: 5,
          setId: 'proof-set-1',
          executionNote: 'felt smooth'),
      _plannedSet(1, weight: 130, reps: 4, rir: 0.0),
    ], exerciseExecutionNote: 'shoulder ok today');

    Future<void> mark(bool isDone) =>
        repo.setMarkedDone(uid: kUid, date: kDate, row: row, isDone: isDone);

    await mark(true);
    final afterFirst = await _storedSets(db);

    await mark(false);
    expect((await _storedRow(db))['isMarkedDone'], isFalse);
    expect(await _storedSets(db), afterFirst,
        reason: 'un-marking must not rewrite any execution value');

    await mark(true);
    final sets = await _storedSets(db);
    expect(sets, hasLength(2));
    expect(sets, afterFirst);
    expect(sets[0]['rir'], 2.0);
    expect(sets[0]['setId'], 'proof-set-1');
    expect(sets[0]['executionNote'], 'felt smooth');
    expect(sets[1]['rir'], 0);
    final storedRow = await _storedRow(db);
    expect(storedRow['isMarkedDone'], isTrue);
    expect(storedRow['exerciseExecutionNote'], 'shoulder ok today');
  });

  // ── TEST 8 — rapid final edit then Done ───────────────────────────────────

  group('TEST 8 — editing the final field then immediately pressing Done', () {
    // Every unfocused-field text the production widget emitted, so the test
    // can assert that pressing Done really did drop focus and fire the
    // ordinary save with the latest text.
    late List<({Wes2FieldKey key, String text})> unfocusCalls;

    // The row snapshot the Done handler would have handed to the repository.
    late List<Wes2ExerciseRow> finalisedRows;

    setUp(() {
      unfocusCalls = <({Wes2FieldKey key, String text})>[];
      finalisedRows = <Wes2ExerciseRow>[];
    });

    /// Mirrors the production wiring: onChanged updates the controller
    /// synchronously, focus loss fires the ordinary field save, and Done drops
    /// focus FIRST (Wes2Screen._onToggleMarkedDone) before finalising.
    /// The Firestore writes themselves are pinned by the ordering tests below;
    /// this harness pins the sequencing that feeds them.
    Widget harness(Wes2SessionController controller) => MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: controller,
              builder: (BuildContext context, Widget? _) {
                final Wes2ExerciseRow row = controller.rows.single;
                return Column(
                  children: <Widget>[
                    Wes2SetRow(
                      set: row.sets.first,
                      showVelocity: false,
                      onFieldChanged: (key, text) => controller.updateSetField(
                        exerciseId: row.exerciseId,
                        setIndex: 0,
                        fieldKey: key,
                        rawText: text,
                      ),
                      onFieldUnfocused: (key, text) =>
                          unfocusCalls.add((key: key, text: text)),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        FocusManager.instance.primaryFocus?.unfocus();
                        controller.toggleMarkedDone(row.exerciseId, true);
                        finalisedRows.add(controller.rows.single);
                      },
                      child: const Text('Done'),
                    ),
                  ],
                );
              },
            ),
          ),
        );

    Wes2SessionController controllerFor(Wes2ExerciseRow row) {
      final c = Wes2SessionController(kDate)
        ..initIdentity(actorUid: kUid, actingUid: kUid, isCoach: false);
      c.setRows(<Wes2ExerciseRow>[row], c.beginLoad());
      return c;
    }

    testWidgets('Done drops focus, so the field still being edited is saved',
        (tester) async {
      final controller = controllerFor(
        _row(<Wes2SetState>[_plannedSet(0, weight: 130, reps: 5)]),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(harness(controller));

      // Field order in normal mode: weight(0), reps(1), rir(2).
      await tester.enterText(find.byType(TextField).at(2), '1.5');
      expect(unfocusCalls, isEmpty,
          reason: 'the RIR field still holds focus and the keyboard is up');

      // Straight to Done without unfocusing first.
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      // Tapping a button does not unfocus a TextField on its own, so without
      // the explicit drop this save would never have fired at all.
      expect(unfocusCalls, hasLength(1));
      expect(unfocusCalls.single.key, Wes2FieldKey.rir);
      expect(unfocusCalls.single.text, '1.5');
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('the finalisation snapshot already carries the last keystroke',
        (tester) async {
      final controller = controllerFor(
        _row(<Wes2SetState>[_plannedSet(0, reps: 5)]),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(harness(controller));

      await tester.enterText(find.byType(TextField).at(0), '132.5');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      // Synchronous onChanged means the row handed to setMarkedDone is ahead
      // of Firestore, so finalisation never depends on which write lands first.
      final Wes2SetState s = finalisedRows.single.sets.single;
      expect(s.weight.actualValue, 132.5);
      expect(wes2FinalisedPerformedSets(finalisedRows.single).single.rir, 2.0);
    });

    /// Whichever of the two transactions commits first, the stored set must
    /// end up complete. Each re-reads the document, so both orders converge.
    Future<List<Map<String, dynamic>>> raceRun({
      required bool patchFirst,
    }) async {
      db = FakeFirebaseFirestore();
      repo = FirestoreWes2Repository(firestore: db);
      await _seedCompletedRow(db, <Map<String, dynamic>>[
        <String, dynamic>{'setIndex': 0, 'weight': 130, 'reps': 5},
      ]);

      // The athlete typed RIR 1.5 and pressed Done before it was saved.
      final Wes2ExerciseRow row = _row(<Wes2SetState>[
        _plannedSet(0, weight: 130, reps: 5, rir: 1.5, rirHint: 2.0),
      ]);
      Future<void> patch() => repo.saveFieldPatch(
            uid: kUid,
            date: kDate,
            row: row,
            setIndex: 0,
            fieldKey: Wes2FieldKey.rir,
            value: 1.5,
          );
      Future<void> done() => repo.setMarkedDone(
          uid: kUid, date: kDate, row: row, isDone: true);

      if (patchFirst) {
        await patch();
        await done();
      } else {
        await done();
        await patch();
      }
      return _storedSets(db);
    }

    test('the field patch committing first still leaves a complete record',
        () async {
      final sets = await raceRun(patchFirst: true);
      expect(sets.single['rir'], 1.5);
      expect(sets.single['weight'], 130);
      expect(sets.single['reps'], 5);
      expect((await _storedRow(db))['isMarkedDone'], isTrue);
    });

    test('the finalisation committing first still leaves a complete record',
        () async {
      final sets = await raceRun(patchFirst: false);
      expect(sets.single['rir'], 1.5);
      expect(sets.single['weight'], 130);
      expect(sets.single['reps'], 5);
      expect((await _storedRow(db))['isMarkedDone'], isTrue);
    });
  });

  // ── TEST 9 — explicit RIR zero ────────────────────────────────────────────

  test('TEST 9 — a stored explicit RIR 0 is preserved, never treated as null',
      () async {
    await _seedCompletedRow(db, <Map<String, dynamic>>[
      <String, dynamic>{'setIndex': 0, 'weight': 130, 'reps': 5, 'rir': 0},
    ]);

    await repo.setMarkedDone(
      uid: kUid,
      date: kDate,
      row: _row(<Wes2SetState>[
        _plannedSet(0, weight: 130, reps: 5, rir: 0.0, rirHint: 2.0),
      ]),
      isDone: true,
    );

    final sets = await _storedSets(db);
    expect(sets.single['rir'], 0);
    expect(sets.single.containsKey('rir'), isTrue);
  });

  // ── TEST 10 — hint-only workout ───────────────────────────────────────────

  group('TEST 10 — an exercise with no performed set', () {
    test('completion invents no execution values', () async {
      await repo.setMarkedDone(
        uid: kUid,
        date: kDate,
        row: _row(<Wes2SetState>[
          _plannedSet(0),
          _plannedSet(1),
          _plannedSet(2),
        ]),
        isDone: true,
      );

      final sets = await _storedSets(db);
      expect(sets, hasLength(3));
      for (final Map<String, dynamic> s in sets) {
        expect(s.containsKey('weight'), isFalse);
        expect(s.containsKey('reps'), isFalse);
        expect(s.containsKey('rir'), isFalse);
        expect(s.containsKey('velocity'), isFalse);
      }
    });

    test('an already-stored hint-only row is not altered', () async {
      await _seedCompletedRow(
        db,
        <Map<String, dynamic>>[
          <String, dynamic>{'setIndex': 0},
          <String, dynamic>{'setIndex': 1},
        ],
        setCount: 2,
      );

      await repo.setMarkedDone(
        uid: kUid,
        date: kDate,
        row: _row(<Wes2SetState>[_plannedSet(0), _plannedSet(1)]),
        isDone: true,
      );

      expect(await _storedSets(db), <Map<String, dynamic>>[
        <String, dynamic>{'setIndex': 0},
        <String, dynamic>{'setIndex': 1},
      ]);
    });
  });

  // ── Surrounding data is untouched ─────────────────────────────────────────

  group('finalisation touches nothing it does not own', () {
    test('neighbouring exercises, velocity, notes and setId all survive',
        () async {
      await _seedCompletedRow(
        db,
        <Map<String, dynamic>>[
          <String, dynamic>{
            'setIndex': 0,
            'setId': 'keep-me',
            'weight': 130,
            'reps': 5,
            'velocity': 0.42,
            'executionNote': 'paused',
          },
        ],
        extraRowFields: <String, dynamic>{
          'exerciseExecutionNote': 'bar felt heavy',
        },
        otherRows: <Map<String, dynamic>>[
          <String, dynamic>{
            'exerciseId': 'squat_barbell',
            'name': 'Squat, Barbell',
            'circuitIndex': 0,
            'orderIndex': 1,
            'setCount': 1,
            'isMarkedDone': true,
            'sets': <Map<String, dynamic>>[
              <String, dynamic>{
                'setIndex': 0,
                'weight': 180,
                'reps': 3,
                'rir': 2.0,
              },
            ],
          },
        ],
      );

      await repo.setMarkedDone(
        uid: kUid,
        date: kDate,
        row: _row(<Wes2SetState>[
          _plannedSet(0,
              weight: 130,
              reps: 5,
              velocity: 0.42,
              setId: 'keep-me',
              executionNote: 'paused'),
        ]),
        isDone: true,
      );

      final sets = await _storedSets(db);
      expect(sets.single, <String, dynamic>{
        'setIndex': 0,
        'setId': 'keep-me',
        'weight': 130,
        'reps': 5,
        'velocity': 0.42,
        'executionNote': 'paused',
        'rir': 2.0,
      });
      expect((await _storedRow(db))['exerciseExecutionNote'], 'bar felt heavy');

      final neighbour = await _storedRow(db, exerciseId: 'squat_barbell');
      expect(neighbour['isMarkedDone'], isTrue);
      expect((neighbour['sets'] as List<dynamic>).single, <String, dynamic>{
        'setIndex': 0,
        'weight': 180,
        'reps': 3,
        'rir': 2.0,
      });
    });

    test('an existing stored value always beats the in-memory snapshot',
        () async {
      // A concurrent field patch committed 132.5 while this row snapshot still
      // said 130. Finalisation is gap-filling and must not roll it back.
      await _seedCompletedRow(db, <Map<String, dynamic>>[
        <String, dynamic>{'setIndex': 0, 'weight': 132.5, 'reps': 6},
      ]);

      await repo.setMarkedDone(
        uid: kUid,
        date: kDate,
        row: _row(<Wes2SetState>[_plannedSet(0, weight: 130, reps: 5)]),
        isDone: true,
      );

      final sets = await _storedSets(db);
      expect(sets.single['weight'], 132.5);
      expect(sets.single['reps'], 6);
      expect(sets.single['rir'], 2.0);
    });

    test('legacy sets written without a setIndex key are located by position',
        () async {
      await _seedCompletedRow(
        db,
        <Map<String, dynamic>>[
          <String, dynamic>{'weight': 130, 'reps': 5},
          <String, dynamic>{'weight': 130, 'reps': 4},
        ],
        setCount: 2,
      );

      await repo.setMarkedDone(
        uid: kUid,
        date: kDate,
        row: _row(<Wes2SetState>[
          _plannedSet(0, weight: 130, reps: 5, rirHint: 2.0),
          _plannedSet(1, weight: 130, reps: 4, rirHint: 1.0),
        ]),
        isDone: true,
      );

      final sets = await _storedSets(db);
      expect(sets, hasLength(2));
      expect(sets[0]['rir'], 2.0);
      expect(sets[1]['rir'], 1.0);
      expect(sets[0].containsKey('setIndex'), isFalse,
          reason: 'a legacy set map keeps its exact shape');
    });

    test('un-marking Done never finalises anything', () async {
      await _seedCompletedRow(db, <Map<String, dynamic>>[
        <String, dynamic>{'setIndex': 0, 'weight': 130, 'reps': 5},
      ]);

      await repo.setMarkedDone(
        uid: kUid,
        date: kDate,
        row: _row(<Wes2SetState>[_plannedSet(0, weight: 130, reps: 5)]),
        isDone: false,
      );

      final sets = await _storedSets(db);
      expect(sets.single.containsKey('rir'), isFalse);
      expect((await _storedRow(db))['isMarkedDone'], isFalse);
    });
  });
}
