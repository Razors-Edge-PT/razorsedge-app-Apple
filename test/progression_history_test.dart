import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/progression_engine.dart';

/// Regression tests for the progression-history architecture.
///
/// Invariant: ONE athlete history snapshot → ONE exercise-identity resolution
/// boundary → the SAME routed history for the baseline/default weight,
/// computeBaseE1RMFromHistory, Smart Progression, Add Reps, Linear, and
/// used-combo detection.
///
/// The production symptoms these lock down:
///   * "Seated Shoulder Dumbbell Press" suggested 5 kg × 9 @ 1.5 — the generic
///     no-history dumbbell default — while the athlete had ~50 kg E1RM top sets
///     that were simply older than the current block.
///   * "Lat Pull Down, Wide Arm" suggested 67.5 × 15 @ 1.5 (~118 E1RM) against
///     240–260 E1RM history.

const String kSpId = 'sp-seated-shoulder-db-press';
const String kSpName = 'Seated Shoulder Dumbbell Press';
const String kLatId = 'lat-pull-down-wide-arm';
const String kLatName = 'Lat Pull Down, Wide Arm';

/// The as-of date every scenario is planned for.
final DateTime kToday = DateTime(2026, 8, 23);

String _ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Builds one workout document as Firestore stores it.
Map<String, dynamic> workoutDoc({
  required DateTime date,
  required String exerciseId,
  required String name,
  required List<Map<String, dynamic>> sets,
  String uid = 'athlete-1',
  bool includeExerciseId = true,
}) {
  return <String, dynamic>{
    'date': _ymd(date),
    '_uid': uid,
    'exercises': [
      <String, dynamic>{
        if (includeExerciseId) 'exerciseId': exerciseId,
        'name': name,
        'sets': sets,
      }
    ],
  };
}

Map<String, dynamic> set1(double weight, int reps, double rir) =>
    <String, dynamic>{
      'setIndex': 0,
      'weight': weight,
      'reps': reps,
      'rir': rir
    };

/// Case A history: five real top sets, ALL older than 28 days from [kToday],
/// and all older than a block that started this month.
List<Map<String, dynamic>> shoulderPressHistory({String uid = 'athlete-1'}) => [
      workoutDoc(
          date: DateTime(2026, 5, 6),
          exerciseId: kSpId,
          name: kSpName,
          uid: uid,
          sets: [set1(35.0, 12, 0.5)]),
      workoutDoc(
          date: DateTime(2026, 4, 20),
          exerciseId: kSpId,
          name: kSpName,
          uid: uid,
          sets: [set1(35.0, 11, 1.0)]),
      workoutDoc(
          date: DateTime(2026, 4, 13),
          exerciseId: kSpId,
          name: kSpName,
          uid: uid,
          sets: [set1(32.5, 11, 1.0)]),
      workoutDoc(
          date: DateTime(2026, 4, 8),
          exerciseId: kSpId,
          name: kSpName,
          uid: uid,
          sets: [set1(37.5, 9, 1.0)]),
      workoutDoc(
          date: DateTime(2026, 3, 25),
          exerciseId: kSpId,
          name: kSpName,
          uid: uid,
          sets: [set1(35.0, 10, 1.5)]),
    ];

/// Case B history: recent Lat Pull Down top sets, 240–260 E1RM.
List<Map<String, dynamic>> latPullDownHistory() => [
      workoutDoc(
          date: DateTime(2026, 8, 17),
          exerciseId: kLatId,
          name: kLatName,
          sets: [set1(185.0, 8, 1.5)]),
      workoutDoc(
          date: DateTime(2026, 7, 15),
          exerciseId: kLatId,
          name: kLatName,
          sets: [set1(200.0, 8, 1.0)]),
      workoutDoc(
          date: DateTime(2026, 7, 8),
          exerciseId: kLatId,
          name: kLatName,
          sets: [set1(185.0, 10, 1.0)]),
      workoutDoc(
          date: DateTime(2026, 6, 30),
          exerciseId: kLatId,
          name: kLatName,
          sets: [set1(157.5, 13, 2.0)]),
      workoutDoc(
          date: DateTime(2026, 6, 18),
          exerciseId: kLatId,
          name: kLatName,
          sets: [set1(200.0, 6, 1.5)]),
      workoutDoc(
          date: DateTime(2026, 6, 9),
          exerciseId: kLatId,
          name: kLatName,
          sets: [set1(180.0, 8, 2.5)]),
    ];

/// Runs the real ProgressionEngine for one exercise, exactly as WES2's hint
/// pipeline does (BB3HintService → engineProgressedValues).
Map<String, dynamic> runEngine({
  required String exerciseId,
  required String name,
  required int repTarget,
  required double rir,
  required DateTime blockStart,
  DateTime? selectedDate,
  double incrementPrimary = 2.5,
  String progressionModel = 'Smart Progression',
}) {
  PeriodizationModelUtils.exercisePeriodizationModels[exerciseId] =
      PeriodizationModelType.dailyUndulatingExposure;

  final settings = <String, dynamic>{
    exerciseId: <String, dynamic>{
      'progressionModel': progressionModel,
      'periodizationModel': 'DUP, By Exposure',
      'increments': {'primary': incrementPrimary},
      'repTargets': {
        'week1': {'instance1': '$repTarget x 3'}
      },
    },
  };

  final inputs = ProgressionEngineInputs(
    blockStartDate: blockStart,
    blockEndDate: blockStart.add(const Duration(days: 7 * 6)),
    selectedDate: selectedDate ?? kToday,
    cachedUid: 'athlete-1',
    selectedExercisesWithCircuits: [
      {'exerciseId': exerciseId, 'id': exerciseId, 'name': name}
    ],
    exerciseSettings: settings,
    cachedProgressedValues: <String, Map<String, dynamic>>{},
    seedHintsByKey: const {},
    resolvedBB2Values: const {},
    rowKeyBy: (_) => '$exerciseId|0',
    rowCacheKey: (_) => '$exerciseId|0',
    getApplicableWeekIndex: (_) => PeriodizationModelUtils.getWeekIndexForDate(
        selectedDate ?? kToday, blockStart),
    getRirFromPlanOrInput: (_, __) => rir,
    weightTextAt: (_, __) => '',
    rirTextAt: (_, __) => '',
  );

  return ProgressionEngine.engineProgressedValues(inputs, 0);
}

double e1rmOf(Map<String, dynamic> progressed, double rir) =>
    PeriodizationModelUtils.calculateE1RM(
      (progressed['weight'] as num).toDouble(),
      (progressed['reps'] as num).toDouble(),
      rir,
    );

void main() {
  setUp(() {
    PeriodizationModelUtils.clearHistorySnapshot();
    PeriodizationModelUtils.exercisePeriodizationModels.clear();
    PeriodizationModelUtils.nameToId.clear();
    PeriodizationModelUtils.exerciseTypeById.clear();
  });

  tearDown(() {
    PeriodizationModelUtils.clearHistorySnapshot();
    PeriodizationModelUtils.exercisePeriodizationModels.clear();
    PeriodizationModelUtils.nameToId.clear();
    PeriodizationModelUtils.exerciseTypeById.clear();
  });

  // ── TEST 1 — old shoulder-press history ──────────────────────────────────
  group('TEST 1 — history older than 28 days still sets the baseline', () {
    setUp(() {
      PeriodizationModelUtils.applyHistorySnapshot(
        uid: 'athlete-1',
        workouts: shoulderPressHistory(),
      );
    });

    test('is not classified as no_history, and uses the last-4 average', () {
      final routed = PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: kSpId,
        exerciseName: kSpName,
        asOfDate: kToday,
      );
      expect(routed, hasLength(5));

      final info = PeriodizationModelUtils.computeBaseE1RMFromHistory(
        exerciseName: kSpName,
        repTarget: 9,
        plannedRIR: 1.5,
        topSetHistory: routed,
        asOfDate: kToday,
      );

      expect(info['baseSource'], isNot('no_history'));
      expect(info['baseSource'], 'last4_avg');
      expect(info['nUsed'], 4);
      expect(info['baseE1RM'] as double, closeTo(49.7, 1.0),
          reason: 'the four newest sessions average ~49-50 kg E1RM');
    });

    test('week 1 Smart Progression returns a mid/high-30s working weight', () {
      final progressed = runEngine(
        exerciseId: kSpId,
        name: kSpName,
        repTarget: 9,
        rir: 1.5,
        blockStart: DateTime(2026, 8, 17), // block starts AFTER all history
      );

      final weight = (progressed['weight'] as num).toDouble();
      expect(weight, isNot(5.0),
          reason: 'the generic no-history dumbbell default must be impossible '
              'while real history exists');
      expect(weight, inInclusiveRange(32.5, 40.0),
          reason: '~49.7 E1RM at 9 reps @ 1.5 RIR implies ~36.6 kg, snapped to '
              'the 2.5 kg grid');
      expect((progressed['reps'] as num).toInt(), 9);
    });

    test('the baseline weight cannot be the generic default for ANY model', () {
      for (final model in const [
        'Smart Progression',
        'Add Reps',
        'Linear Weight Increase',
      ]) {
        final progressed = runEngine(
          exerciseId: kSpId,
          name: kSpName,
          repTarget: 9,
          rir: 1.5,
          blockStart: DateTime(2026, 8, 17),
          progressionModel: model,
        );
        expect((progressed['weight'] as num).toDouble(), isNot(5.0),
            reason: '$model fell back to the no-history dumbbell default');
      }
    });
  });

  // ── TEST 2 — Lat Pull Down ───────────────────────────────────────────────
  group('TEST 2 — Lat Pull Down baseline tracks its real E1RM', () {
    setUp(() {
      PeriodizationModelUtils.applyHistorySnapshot(
        uid: 'athlete-1',
        workouts: latPullDownHistory(),
      );
    });

    test('selected base E1RM stays in the 240-260 region', () {
      final info = PeriodizationModelUtils.computeBaseE1RMFromHistory(
        exerciseName: kLatName,
        repTarget: 15,
        plannedRIR: 1.5,
        topSetHistory: PeriodizationModelUtils.resolveTopSetHistory(
          exerciseId: kLatId,
          exerciseName: kLatName,
          asOfDate: kToday,
        ),
        asOfDate: kToday,
      );
      expect(info['baseE1RM'] as double, inInclusiveRange(240.0, 260.0));
    });

    test('15 reps @ 1.5 RIR cannot produce ~67.5 kg / ~118 E1RM', () {
      final progressed = runEngine(
        exerciseId: kLatId,
        name: kLatName,
        repTarget: 15,
        rir: 1.5,
        blockStart: DateTime(2026, 8, 17),
      );

      final weight = (progressed['weight'] as num).toDouble();
      final e1rm = e1rmOf(progressed, 1.5);

      expect(weight, greaterThan(100.0),
          reason: 'observed bug produced 67.5 kg from 240-260 E1RM history');
      expect(weight, inInclusiveRange(120.0, 160.0));
      expect(e1rm, inInclusiveRange(230.0, 270.0));
      expect(e1rm, greaterThan(150.0),
          reason: 'a ~118 E1RM suggestion must be unreachable');
    });
  });

  // ── TEST 3 — week 1 keeps the baseline but adds no progression ───────────
  test('TEST 3 — week 1 uses history but withholds the progression increase',
      () {
    PeriodizationModelUtils.applyHistorySnapshot(
      uid: 'athlete-1',
      workouts: latPullDownHistory(),
    );

    final week1 = runEngine(
      exerciseId: kLatId,
      name: kLatName,
      repTarget: 8,
      rir: 1.5,
      blockStart: DateTime(2026, 8, 20), // selected date is in week 0
    );
    final week2 = runEngine(
      exerciseId: kLatId,
      name: kLatName,
      repTarget: 8,
      rir: 1.5,
      blockStart: DateTime(2026, 8, 10), // selected date is in week 1
    );

    final e1Week1 = e1rmOf(week1, 1.5);
    final e1Week2 = e1rmOf(week2, 1.5);

    // Week 1 is the historical baseline...
    expect(e1Week1, inInclusiveRange(230.0, 270.0));
    expect((week1['weight'] as num).toDouble(), isNot(5.0));
    // ...and week 2 progresses at or above it.
    expect(e1Week2, greaterThanOrEqualTo(e1Week1 - 0.01),
        reason: 'week 2+ must not fall below the week-1 baseline');
  });

  // ── TEST 4 — genuinely no history ────────────────────────────────────────
  group('TEST 4 — true no-history still uses the generic type default', () {
    test('dumbbell exercise falls back to 5 kg', () {
      PeriodizationModelUtils.applyHistorySnapshot(
          uid: 'athlete-1', workouts: <Map<String, dynamic>>[]);

      final info = PeriodizationModelUtils.computeBaseE1RMFromHistory(
        exerciseName: kSpName,
        repTarget: 9,
        plannedRIR: 1.5,
        topSetHistory: const <Map<String, dynamic>>[],
        asOfDate: kToday,
      );
      expect(info['baseSource'], 'no_history');
      expect(info['baseE1RM'], isNull);

      expect(
        PeriodizationModelUtils.getSuggestedWeightFromRep(
          kSpName,
          9,
          1.5,
          exerciseId: kSpId,
          topSetHistory: const <Map<String, dynamic>>[],
          asOfDate: kToday,
        ),
        5.0,
      );
    });

    test('barbell exercise falls back to 20 kg', () {
      PeriodizationModelUtils.applyHistorySnapshot(
          uid: 'athlete-1', workouts: <Map<String, dynamic>>[]);
      PeriodizationModelUtils.exerciseTypeById['bb-row'] = 'Barbell';
      PeriodizationModelUtils.nameToId['Bent Over Row, Barbell'] = 'bb-row';

      expect(
        PeriodizationModelUtils.getSuggestedWeightFromRep(
          'Bent Over Row, Barbell',
          8,
          2.0,
          exerciseId: 'bb-row',
          topSetHistory: const <Map<String, dynamic>>[],
          asOfDate: kToday,
        ),
        20.0,
      );
    });
  });

  // ── TEST 5 — ID-first identity ───────────────────────────────────────────
  test('TEST 5 — same display name, different IDs, no cross contamination', () {
    const sharedName = 'Row, Machine';
    PeriodizationModelUtils.applyHistorySnapshot(
      uid: 'athlete-1',
      workouts: [
        workoutDoc(
            date: DateTime(2026, 8, 12),
            exerciseId: 'row-heavy',
            name: sharedName,
            sets: [set1(120.0, 8, 1.0)]),
        workoutDoc(
            date: DateTime(2026, 8, 13),
            exerciseId: 'row-light',
            name: sharedName,
            sets: [set1(40.0, 8, 1.0)]),
      ],
    );

    final heavy = PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: 'row-heavy', exerciseName: sharedName, asOfDate: kToday);
    final light = PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: 'row-light', exerciseName: sharedName, asOfDate: kToday);

    expect(heavy, hasLength(1));
    expect(light, hasLength(1));
    expect((heavy.single['weight'] as num).toDouble(), 120.0);
    expect((light.single['weight'] as num).toDouble(), 40.0);

    final heavyBase = PeriodizationModelUtils.computeBaseE1RMFromHistory(
        exerciseName: sharedName,
        repTarget: 8,
        plannedRIR: 1.0,
        topSetHistory: heavy,
        asOfDate: kToday)['baseE1RM'] as double;
    final lightBase = PeriodizationModelUtils.computeBaseE1RMFromHistory(
        exerciseName: sharedName,
        repTarget: 8,
        plannedRIR: 1.0,
        topSetHistory: light,
        asOfDate: kToday)['baseE1RM'] as double;

    expect(heavyBase, greaterThan(2 * lightBase));

    // Used combos are isolated by identity too.
    expect(
      PeriodizationModelUtils.usedCombosFor(
          exerciseId: 'row-heavy', exerciseName: sharedName, asOfDate: kToday),
      contains('120.0_8_1.0'),
    );
    expect(
      PeriodizationModelUtils.usedCombosFor(
          exerciseId: 'row-light', exerciseName: sharedName, asOfDate: kToday),
      isNot(contains('120.0_8_1.0')),
    );
  });

  // ── TEST 6 — legacy rows without an exerciseId ───────────────────────────
  test('TEST 6 — legacy rows with no exerciseId resolve by canonical name', () {
    PeriodizationModelUtils.applyHistorySnapshot(
      uid: 'athlete-1',
      workouts: [
        workoutDoc(
            date: DateTime(2026, 8, 10),
            exerciseId: '',
            name: kSpName,
            includeExerciseId: false,
            sets: [set1(35.0, 10, 1.0)]),
      ],
    );

    // Exact display name.
    expect(
      PeriodizationModelUtils.resolveTopSetHistory(
          exerciseId: kSpId, exerciseName: kSpName, asOfDate: kToday),
      hasLength(1),
    );

    // Canonicalised name (case/punctuation differences, "DB" ↔ "Dumbbell").
    expect(
      PeriodizationModelUtils.resolveTopSetHistory(
          exerciseId: kSpId,
          exerciseName: '  seated shoulder DB press ',
          asOfDate: kToday),
      hasLength(1),
    );

    final progressed = runEngine(
      exerciseId: kSpId,
      name: kSpName,
      repTarget: 10,
      rir: 1.0,
      blockStart: DateTime(2026, 8, 17),
    );
    expect((progressed['weight'] as num).toDouble(), isNot(5.0));
  });

  // ── TEST 7 — as-of date ──────────────────────────────────────────────────
  test('TEST 7 — samples after the selected date are ignored', () {
    PeriodizationModelUtils.applyHistorySnapshot(
      uid: 'athlete-1',
      workouts: [
        workoutDoc(
            date: DateTime(2026, 6, 1),
            exerciseId: kLatId,
            name: kLatName,
            sets: [set1(100.0, 8, 1.0)]),
        workoutDoc(
            date: DateTime(2026, 8, 20), // AFTER the day being edited
            exerciseId: kLatId,
            name: kLatName,
            sets: [set1(250.0, 8, 1.0)]),
      ],
    );

    final asOf = DateTime(2026, 7, 1);
    final routed = PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: kLatId, exerciseName: kLatName, asOfDate: asOf);
    expect(routed, hasLength(1));
    expect((routed.single['weight'] as num).toDouble(), 100.0);

    final base = PeriodizationModelUtils.computeBaseE1RMFromHistory(
      exerciseName: kLatName,
      repTarget: 8,
      plannedRIR: 1.0,
      topSetHistory: routed,
      asOfDate: asOf,
    )['baseE1RM'] as double;
    expect(base, lessThan(200.0),
        reason: 'the 250 kg session from August must not inform a July hint');

    // Even an unsliced list must not leak the future sample.
    final unsliced = PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: kLatId, exerciseName: kLatName);
    expect(unsliced, hasLength(2));
    final guarded = PeriodizationModelUtils.computeBaseE1RMFromHistory(
      exerciseName: kLatName,
      repTarget: 8,
      plannedRIR: 1.0,
      topSetHistory: unsliced,
      asOfDate: asOf,
    )['baseE1RM'] as double;
    expect(guarded, closeTo(base, 0.001));

    // Used combos are as-of filtered too.
    expect(
      PeriodizationModelUtils.usedCombosFor(
          exerciseId: kLatId, exerciseName: kLatName, asOfDate: asOf),
      isNot(contains('250.0_8_1.0')),
    );

    // And the hint itself never inflates toward the future session.
    final progressed = runEngine(
      exerciseId: kLatId,
      name: kLatName,
      repTarget: 8,
      rir: 1.0,
      blockStart: DateTime(2026, 6, 29),
      selectedDate: asOf,
    );
    expect((progressed['weight'] as num).toDouble(), lessThan(160.0));
  });

  // ── TEST 8 — history older than the current block ────────────────────────
  test('TEST 8 — the block boundary does not turn history into no_history', () {
    PeriodizationModelUtils.applyHistorySnapshot(
      uid: 'athlete-1',
      workouts: shoulderPressHistory(),
    );

    // Block starts months after every historical session.
    final progressed = runEngine(
      exerciseId: kSpId,
      name: kSpName,
      repTarget: 9,
      rir: 1.5,
      blockStart: DateTime(2026, 8, 17),
    );

    expect((progressed['weight'] as num).toDouble(), greaterThan(20.0),
        reason: 'pre-block history is still authoritative for the baseline');

    final info = PeriodizationModelUtils.computeBaseE1RMFromHistory(
      exerciseName: kSpName,
      repTarget: 9,
      plannedRIR: 1.5,
      topSetHistory: PeriodizationModelUtils.resolveTopSetHistory(
          exerciseId: kSpId, exerciseName: kSpName, asOfDate: kToday),
      asOfDate: kToday,
    );
    expect(info['baseSource'], isNot('no_history'));
  });

  // ── TEST 10a — one index build, reused by every hint ─────────────────────
  test('TEST 10a — the index is built once and reused across rows and sets',
      () {
    PeriodizationModelUtils.applyHistorySnapshot(
      uid: 'athlete-1',
      workouts: [...shoulderPressHistory(), ...latPullDownHistory()],
    );

    final buildsAfterSnapshot = PeriodizationModelUtils.historyIndexBuilds;

    for (int i = 0; i < 25; i++) {
      PeriodizationModelUtils.resolveTopSetHistory(
          exerciseId: kSpId, exerciseName: kSpName, asOfDate: kToday);
      PeriodizationModelUtils.resolveTopSetHistory(
          exerciseId: kLatId, exerciseName: kLatName, asOfDate: kToday);
      PeriodizationModelUtils.usedCombosFor(
          exerciseId: kSpId, exerciseName: kSpName, asOfDate: kToday);
      PeriodizationModelUtils.exposureDatesFor(
          exerciseId: kLatId, exerciseName: kLatName);
      runEngine(
        exerciseId: kSpId,
        name: kSpName,
        repTarget: 9,
        rir: 1.5,
        blockStart: DateTime(2026, 8, 17),
      );
    }

    expect(PeriodizationModelUtils.historyIndexBuilds, buildsAfterSnapshot,
        reason: 'hint computation must never rebuild the history index');

    // As-of slices are memoised: the same list instance comes back.
    final a = PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: kSpId, exerciseName: kSpName, asOfDate: kToday);
    final b = PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: kSpId, exerciseName: kSpName, asOfDate: kToday);
    expect(identical(a, b), isTrue);
  });

  // ── Athlete isolation ────────────────────────────────────────────────────
  test('a snapshot for one athlete never leaks into another', () {
    PeriodizationModelUtils.applyHistorySnapshot(
      uid: 'athlete-1',
      workouts: [
        ...shoulderPressHistory(uid: 'athlete-1'),
        // A stray document stamped for a different athlete.
        workoutDoc(
            date: DateTime(2026, 8, 12),
            exerciseId: kSpId,
            name: kSpName,
            uid: 'athlete-2',
            sets: [set1(90.0, 10, 0.0)]),
      ],
    );

    final routed = PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: kSpId, exerciseName: kSpName, asOfDate: kToday);
    expect(routed, hasLength(5));
    expect(
      routed.every((s) => (s['weight'] as num).toDouble() < 40.0),
      isTrue,
      reason: "athlete-2's 90 kg session must not appear in athlete-1 history",
    );
  });

  // ── Used-combo scope ─────────────────────────────────────────────────────
  test('used combos keep their top-set scope (first set only)', () {
    PeriodizationModelUtils.applyHistorySnapshot(
      uid: 'athlete-1',
      workouts: [
        workoutDoc(
          date: DateTime(2026, 8, 12),
          exerciseId: kLatId,
          name: kLatName,
          sets: [
            set1(185.0, 8, 1.5),
            // back-off sets must NOT become "used combos"
            {'setIndex': 1, 'weight': 165.0, 'reps': 8, 'rir': 1.5},
            {'setIndex': 2, 'weight': 145.0, 'reps': 8, 'rir': 1.5},
          ],
        ),
      ],
    );

    final combos = PeriodizationModelUtils.usedCombosFor(
        exerciseId: kLatId, exerciseName: kLatName, asOfDate: kToday);
    expect(combos, contains('185.0_8_1.5'));
    expect(combos, isNot(contains('165.0_8_1.5')));
    expect(combos, isNot(contains('145.0_8_1.5')));
  });

  // ── The exact Case A mechanism ───────────────────────────────────────────
  test('the baseline weight no longer depends on a name-keyed lookup', () {
    PeriodizationModelUtils.applyHistorySnapshot(
      uid: 'athlete-1',
      workouts: shoulderPressHistory(),
    );

    // History is keyed by exerciseId, exactly as production stores it.
    expect(PeriodizationModelUtils.topSetsByExercise[kSpId], isNotNull);
    expect(PeriodizationModelUtils.topSetsByExercise[kSpName], isNull,
        reason: 'the old default-weight path looked here and found nothing, '
            'which is how a 5 kg hint appeared for a 50 kg E1RM exercise');

    final baseline = PeriodizationModelUtils.getSuggestedWeightFromRep(
      kSpName,
      9,
      1.5,
      exerciseId: kSpId,
      increments: const [
        0.0,
        2.5,
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
        37.5,
        40.0
      ],
      asOfDate: kToday,
    );

    expect(baseline, isNot(5.0));
    expect(baseline, inInclusiveRange(32.5, 40.0));
  });

  // ── Legacy Timestamp-dated documents ─────────────────────────────────────
  test('legacy documents with a Timestamp date are still real history', () {
    PeriodizationModelUtils.applyHistorySnapshot(
      uid: 'athlete-1',
      workouts: [
        {
          'date': Timestamp.fromDate(DateTime(2026, 5, 6)),
          '_uid': 'athlete-1',
          'exercises': [
            {
              'exerciseId': kSpId,
              'name': kSpName,
              'sets': [set1(35.0, 12, 0.5)],
            }
          ],
        }
      ],
    );

    final routed = PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: kSpId, exerciseName: kSpName, asOfDate: kToday);
    expect(routed, hasLength(1));
    expect(routed.single['date'], DateTime(2026, 5, 6));
  });
}
