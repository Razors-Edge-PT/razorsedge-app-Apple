import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/increment_grid.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/workout_model.dart';

/// FIX 2 — set ORDER has zero significance for historical values.
///
/// The history index already collapsed each exercise/date to the highest-E1RM
/// set, but the used-combo index was built separately from `sets.first`. So for
/// a session logged 220×8 / 250×6 / 270×4, the baseline said "270×4 represents
/// that day" while the combo index said "220×8 did".
///
/// Invariant now: ONE canonical daily top set per exercise identity per date,
/// chosen by value alone, feeding topSetHistory, the Smart Progression
/// baseline, used-combo detection, Add Reps and Linear alike.

const String kEx = 'top-set-fixture-id';
const String kExName = 'Lat Pull Down, Supinated';
final DateTime kAsOf = DateTime(2026, 8, 23);

String _ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Map<String, dynamic> aSet(double weight, int reps, double? rir) =>
    <String, dynamic>{
      'weight': weight,
      'reps': reps,
      if (rir != null) 'rir': rir,
    };

/// One workout document holding a single exercise row.
Map<String, dynamic> doc({
  required DateTime date,
  required List<Map<String, dynamic>> sets,
  String exerciseId = kEx,
  String name = kExName,
  String uid = 'athlete-1',
  bool includeExerciseId = true,
}) =>
    <String, dynamic>{
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

/// One workout document holding SEVERAL rows for the same exercise identity.
Map<String, dynamic> multiRowDoc({
  required DateTime date,
  required List<List<Map<String, dynamic>>> rows,
  String exerciseId = kEx,
  String name = kExName,
  String uid = 'athlete-1',
}) =>
    <String, dynamic>{
      'date': _ymd(date),
      '_uid': uid,
      'exercises': [
        for (final sets in rows)
          <String, dynamic>{
            'exerciseId': exerciseId,
            'name': name,
            'sets': sets,
          }
      ],
    };

void publish(List<Map<String, dynamic>> workouts) =>
    PeriodizationModelUtils.applyHistorySnapshot(
        uid: 'athlete-1', workouts: workouts);

List<Map<String, dynamic>> history({String id = kEx, String name = kExName}) =>
    PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: id, exerciseName: name, asOfDate: kAsOf);

Set<String> combos({
  String id = kEx,
  String name = kExName,
  DateTime? asOfDate,
}) =>
    PeriodizationModelUtils.usedCombosFor(
        exerciseId: id, exerciseName: name, asOfDate: asOfDate ?? kAsOf);

String comboOf(double weight, int reps, double rir) =>
    '${weight.toStringAsFixed(1)}_${reps}_${rir.toStringAsFixed(1)}';

/// (weight, reps, rir) of a routed history sample.
List<double> triple(Map<String, dynamic> s) => <double>[
      (s['weight'] as num).toDouble(),
      (s['reps'] as num).toDouble(),
      (s['rir'] as num).toDouble(),
    ];

void main() {
  setUp(() => PeriodizationModelUtils.clearHistorySnapshot());
  tearDown(() => PeriodizationModelUtils.clearHistorySnapshot());

  // ───────────────────────────────────────────────────────────────────────────
  // TESTS 1–3 — the winner is decided by E1RM, wherever it sits in the array.
  // ───────────────────────────────────────────────────────────────────────────
  group('the day\'s top set wins from any position', () {
    // 220×8@2 → E1RM 289.5 | 270×4@1 → E1RM 305.7 | 240×6@2 → E1RM 297.2
    final low1 = aSet(220.0, 8, 2.0);
    final mid = aSet(240.0, 6, 2.0);
    final top = aSet(270.0, 4, 1.0);

    void expectTopSetWins(List<Map<String, dynamic>> sets) {
      publish([doc(date: DateTime(2026, 8, 12), sets: sets)]);

      expect(history(), hasLength(1));
      expect(triple(history().single), [270.0, 4.0, 1.0]);

      final c = combos();
      expect(c, contains(comboOf(270.0, 4, 1.0)),
          reason: 'the day\'s real top set must be the used combo');
      expect(c, isNot(contains(comboOf(220.0, 8, 2.0))));
      expect(c, isNot(contains(comboOf(240.0, 6, 2.0))));
      expect(c, hasLength(1), reason: 'exactly one combo per exercise/date');
    }

    test('TEST 1 — first set is NOT the top set', () {
      expectTopSetWins([low1, top, mid]);
    });

    test('TEST 2 — last set is the top set', () {
      expectTopSetWins([low1, mid, top]);
    });

    test('TEST 3 — middle set is the top set', () {
      expectTopSetWins([low1, top, mid]);
      expectTopSetWins([mid, top, low1]);
    });

    test('TEST 18 — a later athlete-ADDED set can win, like any other', () {
      // A 6th set appended after the planned five.
      publish([
        doc(date: DateTime(2026, 8, 12), sets: [
          aSet(200.0, 8, 2.0),
          aSet(200.0, 8, 2.0),
          aSet(200.0, 8, 2.0),
          aSet(200.0, 8, 2.0),
          aSet(200.0, 8, 2.0),
          aSet(280.0, 3, 0.0), // added set, highest E1RM
        ])
      ]);
      expect(triple(history().single), [280.0, 3.0, 0.0]);
      expect(combos(), {comboOf(280.0, 3, 0.0)});
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 4 — raw re-ordering changes nothing at all.
  // ───────────────────────────────────────────────────────────────────────────
  test('TEST 4 — reordering raw sets changes no derived value', () {
    final a = aSet(220.0, 8, 2.0);
    final b = aSet(270.0, 4, 1.0); // top
    final c = aSet(240.0, 6, 2.0);

    final orders = <List<Map<String, dynamic>>>[
      [a, b, c],
      [c, a, b],
      [b, c, a],
      [c, b, a],
    ];

    final results = <List<Object>>[];
    for (final order in orders) {
      publish([doc(date: DateTime(2026, 8, 12), sets: order)]);
      final sp = PeriodizationModelUtils.smartProgressionModel(
        exerciseName: kExName,
        repTarget: 5,
        defaultWeight: 250.0,
        rirValue: 1.0,
        increments: const <double>[],
        grid: IncrementGrid(primary: 2.5),
        topSetHistory: history(),
        weekIndex: 1,
        exerciseId: kEx,
        asOfDate: kAsOf,
      );
      results.add(<Object>[
        triple(history().single).toString(),
        combos().toList().toString(),
        '${sp['weight']}x${sp['reps']}',
      ]);
    }

    for (final r in results) {
      expect(r, results.first,
          reason: 'raw storage order must have zero significance');
    }
    expect(results.first[0], triple(<String, dynamic>{
      'weight': 270.0,
      'reps': 4.0,
      'rir': 1.0,
    }).toString());
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TESTS 5–6 — used combos gate on TOP sets, not on any set ever performed.
  // ───────────────────────────────────────────────────────────────────────────
  group('used combos gate on top sets only', () {
    // Day: back-off 100×10@2 (E1RM 144.0) and top set 140×6@1 (E1RM 168.0).
    final backOff = aSet(100.0, 10, 2.0);
    final topSet = aSet(140.0, 6, 1.0);

    test('TEST 5 — a non-top historical combo does NOT block Smart Progression',
        () {
      publish([
        doc(date: DateTime(2026, 8, 12), sets: [backOff, topSet, backOff]),
      ]);

      expect(combos(), isNot(contains(comboOf(100.0, 10, 2.0))),
          reason: 'a back-off set was never the athlete\'s top set');

      // Make 100 × 10 @ RIR 2 the natural winner: baseline E1RM 144.0 is
      // exactly what that combo produces, and it is the grid centre.
      final sp = PeriodizationModelUtils.smartProgressionModel(
        exerciseName: kExName,
        repTarget: 10,
        defaultWeight: 100.0,
        rirValue: 2.0,
        increments: const <double>[],
        grid: IncrementGrid(primary: 2.5),
        topSetHistory: [
          {
            'weight': 100.0,
            'reps': 10.0,
            'rir': 2.0,
            'date': DateTime(2026, 8, 12),
          }
        ],
        weekIndex: 1,
        exerciseId: kEx,
        asOfDate: kAsOf,
      );

      expect((sp['weight'] as num).toDouble(), 100.0);
      expect((sp['reps'] as num).toInt(), 10);
    });

    test('TEST 6 — a genuine historical TOP-SET combo DOES block it', () {
      publish([
        doc(date: DateTime(2026, 8, 12), sets: [backOff, topSet, backOff]),
      ]);

      expect(combos(), contains(comboOf(140.0, 6, 1.0)));

      final sp = PeriodizationModelUtils.smartProgressionModel(
        exerciseName: kExName,
        repTarget: 6,
        defaultWeight: 140.0,
        rirValue: 1.0,
        increments: const <double>[],
        grid: IncrementGrid(primary: 2.5),
        topSetHistory: history(),
        weekIndex: 1,
        exerciseId: kEx,
        asOfDate: kAsOf,
      );

      final chosen = comboOf(
        (sp['weight'] as num).toDouble(),
        (sp['reps'] as num).toInt(),
        1.0,
      );
      expect(chosen, isNot(comboOf(140.0, 6, 1.0)),
          reason: 'the no-repeat rule must still reject a real top-set combo');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 7 — several rows for one exercise on one date collapse to ONE winner.
  // ───────────────────────────────────────────────────────────────────────────
  test('TEST 7 — duplicate exercise rows on one date yield one daily winner',
      () {
    publish([
      multiRowDoc(date: DateTime(2026, 8, 12), rows: [
        [aSet(200.0, 8, 2.0), aSet(210.0, 6, 2.0)], // row 1, lower
        [aSet(230.0, 8, 1.0), aSet(220.0, 5, 3.0)], // row 2, holds the winner
      ])
    ]);

    expect(history(), hasLength(1),
        reason: 'one canonical sample per exercise/date, not per row');
    expect(triple(history().single), [230.0, 8.0, 1.0]);
    expect(combos(), {comboOf(230.0, 8, 1.0)},
        reason: 'and exactly one combo, not one per raw row');
  });

  test('TEST 7b — row order does not decide the daily winner', () {
    publish([
      multiRowDoc(date: DateTime(2026, 8, 12), rows: [
        [aSet(230.0, 8, 1.0)], // winner now appears FIRST
        [aSet(200.0, 8, 2.0)],
      ])
    ]);
    expect(triple(history().single), [230.0, 8.0, 1.0]);
    expect(combos(), {comboOf(230.0, 8, 1.0)});
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 8 — one sample and one combo per date, across dates.
  // ───────────────────────────────────────────────────────────────────────────
  test('TEST 8 — three dates give exactly three samples and three combos', () {
    publish([
      doc(date: DateTime(2026, 8, 5), sets: [
        aSet(180.0, 8, 2.0),
        aSet(200.0, 8, 2.0), // winner, last
      ]),
      doc(date: DateTime(2026, 8, 12), sets: [
        aSet(210.0, 8, 2.0), // winner, first
        aSet(190.0, 8, 2.0),
      ]),
      doc(date: DateTime(2026, 8, 19), sets: [
        aSet(195.0, 8, 2.0),
        aSet(220.0, 8, 2.0), // winner, middle
        aSet(205.0, 8, 2.0),
      ]),
    ]);

    final h = history();
    expect(h, hasLength(3));
    // newest-first
    expect(triple(h[0]), [220.0, 8.0, 2.0]);
    expect(triple(h[1]), [210.0, 8.0, 2.0]);
    expect(triple(h[2]), [200.0, 8.0, 2.0]);

    expect(combos(), {
      comboOf(220.0, 8, 2.0),
      comboOf(210.0, 8, 2.0),
      comboOf(200.0, 8, 2.0),
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 9 — as-of slicing applies to combos exactly as to samples.
  // ───────────────────────────────────────────────────────────────────────────
  test('TEST 9 — future daily top sets leak into neither history nor combos',
      () {
    publish([
      doc(date: DateTime(2026, 8, 5), sets: [
        aSet(180.0, 8, 2.0),
        aSet(200.0, 8, 2.0), // past winner
      ]),
      doc(date: DateTime(2026, 8, 26), sets: [
        aSet(260.0, 8, 1.0), // FUTURE winner
      ]),
    ]);

    final asOf = DateTime(2026, 8, 12);
    final sliced = PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: kEx, exerciseName: kExName, asOfDate: asOf);
    expect(sliced, hasLength(1));
    expect(triple(sliced.single), [200.0, 8.0, 2.0]);

    final c = combos(asOfDate: asOf);
    expect(c, {comboOf(200.0, 8, 2.0)});
    expect(c, isNot(contains(comboOf(260.0, 8, 1.0))));

    // Unsliced, the future winner is present — proving the slice did the work.
    expect(combos(asOfDate: DateTime(2026, 9, 30)),
        contains(comboOf(260.0, 8, 1.0)));
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TESTS 10–11 — identity routing is untouched.
  // ───────────────────────────────────────────────────────────────────────────
  test('TEST 10 — two ids sharing a display name stay isolated', () {
    const sharedName = 'Row, Machine';
    publish([
      doc(
          date: DateTime(2026, 8, 12),
          exerciseId: 'row-heavy',
          name: sharedName,
          sets: [aSet(60.0, 10, 2.0), aSet(120.0, 8, 1.0)]),
      doc(
          date: DateTime(2026, 8, 12),
          exerciseId: 'row-light',
          name: sharedName,
          sets: [aSet(40.0, 8, 1.0), aSet(30.0, 12, 2.0)]),
    ]);

    expect(triple(history(id: 'row-heavy', name: sharedName).single),
        [120.0, 8.0, 1.0]);
    expect(triple(history(id: 'row-light', name: sharedName).single),
        [40.0, 8.0, 1.0]);

    expect(combos(id: 'row-heavy', name: sharedName),
        {comboOf(120.0, 8, 1.0)});
    expect(combos(id: 'row-light', name: sharedName), {comboOf(40.0, 8, 1.0)});
    expect(combos(id: 'row-light', name: sharedName),
        isNot(contains(comboOf(120.0, 8, 1.0))));
  });

  test('TEST 11 — a legacy row without an exerciseId still routes by name', () {
    publish([
      doc(
        date: DateTime(2026, 8, 12),
        includeExerciseId: false,
        sets: [aSet(180.0, 6, 1.0), aSet(200.0, 6, 1.0)],
      ),
    ]);

    // Resolved through the legacy-name fallback, top set and combo agree.
    final h = PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: 'some-modern-id', exerciseName: kExName, asOfDate: kAsOf);
    expect(triple(h.single), [200.0, 6.0, 1.0]);
    expect(
        PeriodizationModelUtils.usedCombosFor(
            exerciseId: 'some-modern-id',
            exerciseName: kExName,
            asOfDate: kAsOf),
        {comboOf(200.0, 6, 1.0)});

    // The legacy row must not have populated a modern id bucket.
    expect(PeriodizationModelUtils.topSetsByExercise['some-modern-id'], isNull);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 12 — missing RIR keeps the existing reader semantics (null → 0).
  // ───────────────────────────────────────────────────────────────────────────
  test('TEST 12 — a persisted-null RIR is read as 0, never inferred', () {
    publish([
      doc(date: DateTime(2026, 8, 12), sets: [
        aSet(150.0, 10, 2.0), // E1RM 216.0
        aSet(200.0, 6, null), // no persisted rir at all → E1RM 232.3
      ])
    ]);

    final s = history().single;
    expect(triple(s), [200.0, 6.0, 0.0],
        reason: 'the top-set reader has always treated a missing RIR as 0');

    // The combo is spelled from that same sample — one reader, one answer.
    expect(combos(), {comboOf(200.0, 6, 0.0)});
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 13 — DUP exposure counting is untouched.
  // ───────────────────────────────────────────────────────────────────────────
  test('TEST 13 — exposure dates are unchanged by set order', () {
    final a = aSet(220.0, 8, 2.0);
    final b = aSet(270.0, 4, 1.0);
    final c = aSet(240.0, 6, 2.0);

    publish([doc(date: DateTime(2026, 8, 12), sets: [a, b, c])]);
    final first = PeriodizationModelUtils.exposureDatesFor(
        exerciseId: kEx, exerciseName: kExName);

    publish([doc(date: DateTime(2026, 8, 12), sets: [c, a, b])]);
    final second = PeriodizationModelUtils.exposureDatesFor(
        exerciseId: kEx, exerciseName: kExName);

    expect(second, first);
    expect(first, {'2026-08-12'});
  });

  test('TEST 13b — exposure still counts a day with no E1RM-eligible set', () {
    // A 0 kg bodyweight set is "performed" for exposure but cannot be a top
    // set. Exposure semantics ("did it happen?") stay independent of the
    // top-set rule ("which set represents the day?").
    publish([
      doc(date: DateTime(2026, 8, 12), sets: [aSet(0.0, 12, 2.0)])
    ]);
    expect(
        PeriodizationModelUtils.exposureDatesFor(
            exerciseId: kEx, exerciseName: kExName),
        {'2026-08-12'});
    expect(history(), isEmpty);
    expect(combos(), isEmpty);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TESTS 14–15 — Add Reps and Linear read the canonical daily top set.
  // ───────────────────────────────────────────────────────────────────────────
  test('TEST 14 — Add Reps sees the day\'s top set, not raw Set 1', () {
    publish([
      doc(date: DateTime(2026, 8, 19), sets: [
        aSet(100.0, 12, 3.0), // raw Set 1 — a warm-up-ish opener
        aSet(140.0, 8, 0.0), // the real top set
        aSet(110.0, 10, 2.0),
      ]),
      doc(date: DateTime(2026, 8, 12), sets: [aSet(130.0, 5, 1.0)]),
    ]);

    final routed = history();
    expect(triple(routed.first), [140.0, 8.0, 0.0],
        reason: 'newest-first canonical history — `.first` here is legitimate');

    final result = PeriodizationModelUtils.addRepsProgressionModel(
      exerciseName: kExName,
      repTarget: 5,
      defaultWeight: 140.0,
      rirValue: 0.0,
      increments: const <double>[],
      grid: IncrementGrid(primary: 2.5),
      topSetHistory: routed,
      weekIndex: 1,
      exerciseId: kEx,
      asOfDate: kAsOf,
    );

    // It promoted off 140.0 (the top set), never off 100.0 (raw Set 1).
    final w = (result['weight'] as num).toDouble();
    expect(w, greaterThanOrEqualTo(140.0));
    expect(w, isNot(100.0));
  });

  test('TEST 15 — Linear progresses from the day\'s top set', () {
    publish([
      doc(date: DateTime(2026, 8, 19), sets: [
        aSet(100.0, 5, 1.0), // raw Set 1, also at the rep target
        aSet(140.0, 5, 1.0), // top set, same reps
        aSet(120.0, 5, 1.0),
      ]),
    ]);

    final w = PeriodizationModelUtils.getProgressedWeight(
      exerciseName: kExName,
      repTarget: 5,
      defaultWeight: 140.0,
      rirValue: 1.0,
      increments: const <double>[],
      grid: IncrementGrid(primary: 2.5),
      topSetHistory: history(),
      weekIndex: 1,
      exerciseId: kEx,
      asOfDate: kAsOf,
    );

    expect(w, 142.5,
        reason: 'promotion is off 140.0 (the top set), not 100.0 (Set 1)');
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 16 — the Top Sets screen and progression pick the same set.
  // ───────────────────────────────────────────────────────────────────────────
  test('TEST 16 — Top Sets screen and progression agree on the day\'s winner',
      () {
    final rawSets = <Map<String, dynamic>>[
      aSet(220.0, 8, 2.0),
      aSet(270.0, 4, 1.0),
      aSet(240.0, 6, 2.0),
      aSet(255.0, 5, 2.0),
    ];

    publish([doc(date: DateTime(2026, 8, 12), sets: rawSets)]);
    final progressionWinner = history().single;

    // The Top Sets screen walks SetDetails objects for the same persisted day
    // and applies PeriodizationModelUtils.beatsTopSet — the shared rule.
    final screenSets = rawSets
        .map((m) => SetDetails(
              weight: (m['weight'] as num).toDouble(),
              reps: (m['reps'] as num).toInt(),
              rir: (m['rir'] as num?)?.toDouble(),
            ))
        .toList();

    SetDetails? topSet;
    for (final set in screenSets) {
      if (topSet == null ||
          PeriodizationModelUtils.beatsTopSet(
            candidateWeight: set.weight ?? 0.0,
            candidateReps: (set.reps ?? 0).toDouble(),
            candidateRir: set.rir ?? 0.0,
            incumbentWeight: topSet.weight ?? 0.0,
            incumbentReps: (topSet.reps ?? 0).toDouble(),
            incumbentRir: topSet.rir ?? 0.0,
          )) {
        topSet = set;
      }
    }

    expect(topSet!.weight, (progressionWinner['weight'] as num).toDouble());
    expect(topSet.reps, (progressionWinner['reps'] as num).toInt());
    expect(topSet.rir, (progressionWinner['rir'] as num).toDouble());
    expect(
      PeriodizationModelUtils.calculateE1RM(
          topSet.weight, (topSet.reps ?? 0).toDouble(), topSet.rir),
      PeriodizationModelUtils.calculateE1RM(
          (progressionWinner['weight'] as num).toDouble(),
          (progressionWinner['reps'] as num).toDouble(),
          (progressionWinner['rir'] as num).toDouble()),
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 17 — equal E1RM resolves on values, never on position.
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST 17 — exact E1RM ties', () {
    // Brzycki: E1RM = w * 36 / (37 - totalReps).
    // 100 × 6 @ 1 → 100 * 36/30 = 120.0
    // 120 × 3 @ 0 → 120 * 36/34 ≈ 127.06  (not a tie)
    // A real tie: 90 × 8 @ 1 → 90*36/28 = 115.714…
    //             and       → find a heavier equal-E1RM pair below.
    // 120 × 1 @ 1 → 120 * 36/35 = 123.43
    // 123.43 also = w * 36/(37-t). For w=105, 105*36/x = 123.43 → x = 30.62.
    // Simplest exact tie: identical E1RM by construction — 100 × 5 @ 2
    // (100*36/30 = 120.0) and 100 × 6 @ 1 (100*36/30 = 120.0): same weight,
    // different reps/RIR.
    final lighterMoreReps = aSet(100.0, 6, 1.0); // E1RM 120.0
    final sameWeightFewer = aSet(100.0, 5, 2.0); // E1RM 120.0

    test('equal E1RM and weight → more reps wins, in any order', () {
      publish([
        doc(date: DateTime(2026, 8, 12), sets: [sameWeightFewer, lighterMoreReps])
      ]);
      final a = triple(history().single);

      publish([
        doc(date: DateTime(2026, 8, 12), sets: [lighterMoreReps, sameWeightFewer])
      ]);
      final b = triple(history().single);

      expect(a, b, reason: 'the tie-break must not depend on position');
      expect(a, [100.0, 6.0, 1.0], reason: 'more reps wins an E1RM+weight tie');
    });

    test('equal E1RM, different weight → the heavier lift wins', () {
      // 150 × 7 @ 0 → 150 * 36/30 = 180.0
      // 120 × 10 @ 2 → 120 * 36/25 = 172.8  (not equal) — construct exactly:
      // For E1RM 180 at 5 total reps: w = 180 * 32/36 = 160.0 → 160 × 4 @ 1.
      final lighter = aSet(150.0, 6, 1.0); // 150*36/30 = 180.0
      final heavier = aSet(160.0, 4, 1.0); // 160*36/32 = 180.0

      publish([doc(date: DateTime(2026, 8, 12), sets: [lighter, heavier])]);
      final a = triple(history().single);
      publish([doc(date: DateTime(2026, 8, 12), sets: [heavier, lighter])]);
      final b = triple(history().single);

      expect(a, b);
      expect(a, [160.0, 4.0, 1.0], reason: 'heavier load wins an E1RM tie');

      // And the combo follows the same winner.
      expect(combos(), {comboOf(160.0, 4, 1.0)});
    });

    test('the comparator itself is antisymmetric and position-free', () {
      int cmp(List<double> x, List<double> y) =>
          PeriodizationModelUtils.compareTopSetCandidates(
            aWeight: x[0],
            aReps: x[1],
            aRir: x[2],
            bWeight: y[0],
            bReps: y[1],
            bRir: y[2],
          );

      final heavier = [160.0, 4.0, 1.0];
      final lighter = [150.0, 6.0, 1.0];
      expect(cmp(heavier, lighter), lessThan(0));
      expect(cmp(lighter, heavier), greaterThan(0));
      expect(cmp(heavier, heavier), 0);

      // Equal E1RM + weight + reps → lower RIR (harder set) wins.
      expect(cmp([100.0, 6.0, 1.0], [100.0, 6.0, 1.0]), 0);
      expect(
          PeriodizationModelUtils.beatsTopSet(
            candidateWeight: 100.0,
            candidateReps: 6.0,
            candidateRir: 0.0,
            incumbentWeight: 100.0,
            incumbentReps: 6.0,
            incumbentRir: 0.0,
          ),
          isFalse,
          reason: 'an identical candidate never displaces the incumbent');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Source-level guard: no raw positional selection in the index build.
  // ───────────────────────────────────────────────────────────────────────────
  group('source invariants', () {
    String indexBuildBody() {
      final src = File('lib/periodization_model_utils.dart').readAsStringSync();
      const signature = 'static void _rebuildHistoryIndex() {';
      final start = src.indexOf(signature);
      expect(start, isNonNegative);
      final end = src.indexOf(RegExp(r'\n  /// '), start + signature.length);
      return src.substring(start, end == -1 ? src.length : end);
    }

    test('the history index never selects a raw set by position', () {
      final body = indexBuildBody();
      for (final banned in <String>['sets.first', 'sets[0]', 'sets.last']) {
        expect(body, isNot(contains(banned)),
            reason: 'historical weight/reps/RIR must come from the canonical '
                'daily top set, never from array position');
      }
    });

    test('used combos are derived from the canonical daily samples', () {
      final body = indexBuildBody();
      expect(body, contains('topSetComboKey(sample)'),
          reason: 'one derivation, so combos and history cannot disagree');
    });

    test('the Top Sets screen shares the progression selection rule', () {
      final src = File('lib/top_sets_screen.dart').readAsStringSync();
      expect(src, contains('PeriodizationModelUtils.beatsTopSet('),
          reason: 'the visible Top Set and progression history must be chosen '
              'by the same rule');
    });
  });
}
