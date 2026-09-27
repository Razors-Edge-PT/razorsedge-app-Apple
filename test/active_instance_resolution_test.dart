// Canonical active training instance (option A) — the shared resolver, the
// BB3 cache-loaded and pre-cache paths, the settings dialog, and the numeric
// BB3 weight hint.
//
// This suite pins the SMALL new surface the fix introduces:
//
//   lib/active_instance.dart
//     ActiveInstance { exposurePosition, repInstanceIndex, rirSessionIndex }
//     ActiveInstanceResolver.exposurePosition(...)   one position, both screens
//     ActiveInstanceResolver.resolve(...)            explicit, separate wraps
//     ActiveInstanceResolver.repInstanceCount(...) / rirSessionCount(...)
//
//   BB3PlannedExerciseService
//     getExposureHintIndex(..., firestore:, today:, plannedDayLoader:)  (cache)
//     exposurePositionSync(...)                                      (pre-cache)
//
//   Wes2ExerciseSettingsDialog(activeInstance: ...)
//   BB3SetHint.weightKg (numeric; no kg-string round trip)
//
// The contract (option A):
//   * WES2: distinct valid completed exposure dates in [blockStart, selected).
//   * BB3: the same, plus eligible planned dates in [today, selected) for a
//     future selected date. A date both planned and completed counts once.
//     Past planned-but-uncompleted dates never count. The selected date never
//     counts itself. Later history never affects an earlier selected date.
//   * repInstanceIndex = position % repInstanceCount
//     rirSessionIndex  = position % rirSessionCount
//     — the SAME position, each wrapped over its OWN configured length. A rep
//     modulo never changes the RIR index; no missing key is ever relied on.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_plan_service.dart';
import 'package:localtest222/WES2_widgets/WES2_exercise_settings_dialog.dart';
import 'package:localtest222/active_instance.dart';
import 'package:localtest222/bb3_hint_service.dart';
import 'package:localtest222/bb3_models.dart';
import 'package:localtest222/bb3_planned_exercise_service.dart';
import 'package:localtest222/units/weight_unit.dart';

import 'support/bb3_wes2_instance_fixture.dart';

String ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

BB3Exercise planned({String id = kExId, String name = kExName}) => BB3Exercise(
      exerciseId: id,
      name: name,
      circuitIndex: 0,
      orderIndex: 0,
      sets: const <BB3Set>[],
    );

void main() {
  // ─────────────────────────────────────────────────────────────────────────
  group('exposure position — WES2 (completed only)', () {
    final DateTime sel = DateTime(2026, 1, 25);

    test('counts distinct completed dates strictly before the selected date',
        () {
      expect(
          ActiveInstanceResolver.exposurePosition(
            selectedDate: sel,
            completedDates: kPriorExposureDates,
            blockStartDate: kBlockStart,
          ),
          4);
    });

    test('the selected date never counts itself', () {
      expect(
          ActiveInstanceResolver.exposurePosition(
            selectedDate: sel,
            completedDates: <String>[...kPriorExposureDates, '2026-01-25'],
            blockStartDate: kBlockStart,
          ),
          4);
    });

    test('later exposures never affect an earlier selected date', () {
      expect(
          ActiveInstanceResolver.exposurePosition(
            selectedDate: DateTime(2026, 1, 13),
            completedDates: <String>[
              ...kPriorExposureDates,
              '2026-01-25',
              '2026-02-02',
            ],
            blockStartDate: kBlockStart,
          ),
          2,
          reason: 'only 01-06 and 01-09 precede 01-13');
    });

    test('duplicate dates count once; pre-block dates do not count', () {
      expect(
          ActiveInstanceResolver.exposurePosition(
            selectedDate: sel,
            completedDates: <String>[
              '2025-12-30', // before the block
              '2026-01-06',
              '2026-01-06',
              '2026-01-09',
            ],
            blockStartDate: kBlockStart,
          ),
          2);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('exposure position — BB3 (completed + eligible planned)', () {
    // The brief's example: Monday completed, Tuesday and Wednesday planned,
    // Thursday selected (future). Today is Tuesday.
    final DateTime mon = DateTime(2026, 2, 2);
    final DateTime tue = DateTime(2026, 2, 3);
    final DateTime wed = DateTime(2026, 2, 4);
    final DateTime thu = DateTime(2026, 2, 5);

    test('WES2 Thursday = 1 (only Monday was completed)', () {
      expect(
          ActiveInstanceResolver.exposurePosition(
            selectedDate: thu,
            completedDates: <String>[ymd(mon)],
            blockStartDate: kBlockStart,
          ),
          1);
    });

    test('BB3 Thursday = 3 (Monday completed + Tuesday and Wednesday planned)',
        () {
      expect(
          ActiveInstanceResolver.exposurePosition(
            selectedDate: thu,
            completedDates: <String>[ymd(mon)],
            plannedDates: <String>[ymd(tue), ymd(wed), ymd(thu)],
            today: tue,
            blockStartDate: kBlockStart,
          ),
          3,
          reason: 'Thursday is the fourth occurrence; the selected date itself '
              'never counts');
    });

    test('a date both planned and completed counts once', () {
      expect(
          ActiveInstanceResolver.exposurePosition(
            selectedDate: thu,
            completedDates: <String>[ymd(mon), ymd(tue)],
            plannedDates: <String>[ymd(tue), ymd(wed)],
            today: tue,
            blockStartDate: kBlockStart,
          ),
          3);
    });

    test('past planned-but-uncompleted dates never count', () {
      // Today is Wednesday; Monday and Tuesday were planned but never done.
      expect(
          ActiveInstanceResolver.exposurePosition(
            selectedDate: thu,
            completedDates: const <String>[],
            plannedDates: <String>[ymd(mon), ymd(tue), ymd(wed)],
            today: wed,
            blockStartDate: kBlockStart,
          ),
          1,
          reason: 'only Wednesday (today, planned) precedes Thursday');
    });

    test('current-day row with no intervening plans matches WES2', () {
      final int wes2 = ActiveInstanceResolver.exposurePosition(
        selectedDate: tue,
        completedDates: <String>[ymd(mon)],
        blockStartDate: kBlockStart,
      );
      final int bb3 = ActiveInstanceResolver.exposurePosition(
        selectedDate: tue,
        completedDates: <String>[ymd(mon), ymd(tue)], // logged today already
        plannedDates: <String>[ymd(tue)],
        today: tue,
        blockStartDate: kBlockStart,
      );
      expect(bb3, wes2);
      expect(bb3, 1);
    });

    test('a past selected date ignores plans entirely', () {
      expect(
          ActiveInstanceResolver.exposurePosition(
            selectedDate: mon,
            completedDates: <String>[ymd(mon), ymd(tue)],
            plannedDates: <String>[ymd(tue), ymd(wed)],
            today: wed,
            blockStartDate: kBlockStart,
          ),
          0);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('position → rep slot and RIR session (explicit, separate wraps)', () {
    test('equal lengths: rep slot and RIR session coincide', () {
      final ActiveInstance a = ActiveInstanceResolver.resolve(
          exposurePosition: 10, repInstanceCount: 3, rirSessionCount: 3);
      expect(a.exposurePosition, 10);
      expect(a.repInstanceIndex, 1);
      expect(a.rirSessionIndex, 1);
    });

    test('different lengths: each wraps over its own length', () {
      final ActiveInstance a = ActiveInstanceResolver.resolve(
          exposurePosition: 5, repInstanceCount: 3, rirSessionCount: 2);
      expect(a.repInstanceIndex, 2);
      expect(a.rirSessionIndex, 1,
          reason: 'the rep modulo (5 % 3) must not choose the RIR session');
      final ActiveInstance b = ActiveInstanceResolver.resolve(
          exposurePosition: 4, repInstanceCount: 2, rirSessionCount: 3);
      expect(b.repInstanceIndex, 0);
      expect(b.rirSessionIndex, 1);
    });

    test('no configuration: index 0, never negative or out of range', () {
      final ActiveInstance a = ActiveInstanceResolver.resolve(
          exposurePosition: 7, repInstanceCount: 0, rirSessionCount: 0);
      expect(a.repInstanceIndex, 0);
      expect(a.rirSessionIndex, 0);
    });

    test('lengths are read from contiguous instanceN / sessionN keys', () {
      final Map<String, dynamic> s = exerciseSettingsFor();
      expect(ActiveInstanceResolver.repInstanceCount(s), 3);
      expect(ActiveInstanceResolver.rirSessionCount(s), 3);
      final Map<String, dynamic> two =
          exerciseSettingsFor(sessionRir: <int, List<double>>{
        1: <double>[2.0],
        2: <double>[1.0],
      });
      expect(ActiveInstanceResolver.rirSessionCount(two), 2);
      expect(ActiveInstanceResolver.repInstanceCount(null), 0);
      expect(ActiveInstanceResolver.rirSessionCount(null), 0);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('BB3 cache-loaded (async) and pre-cache (sync) paths agree', () {
    Future<FakeFirebaseFirestore> seedWorkouts(List<String> dates) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      for (final String d in dates) {
        await db
            .collection('users')
            .doc(kUid)
            .collection('workouts')
            .doc(d)
            .set(<String, dynamic>{
          'exercises': <Map<String, dynamic>>[
            <String, dynamic>{
              'exerciseId': kExId,
              'name': kExName,
              'sets': <Map<String, dynamic>>[
                <String, dynamic>{'weight': 100, 'reps': 5, 'rir': 2},
              ],
            },
          ],
        });
      }
      return db;
    }

    // Selected Thursday 2026-01-29; today Tuesday 01-27. Completed: the four
    // prior exposures + 01-27 (today, logged). Planned: 01-27, 01-28, 01-29.
    final DateTime today = DateTime(2026, 1, 27);
    final DateTime sel = DateTime(2026, 1, 29);
    final List<String> completed = <String>[
      ...kPriorExposureDates,
      '2026-01-27'
    ];
    final Map<String, List<BB3Exercise>> plannedByDate =
        <String, List<BB3Exercise>>{
      '2026-01-27': <BB3Exercise>[planned()],
      '2026-01-28': <BB3Exercise>[planned()],
      '2026-01-29': <BB3Exercise>[planned()],
    };

    setUp(() => seedHistory(<Map<String, dynamic>>[
          for (final String d in completed) workout(d),
        ]));
    tearDown(clearHistory);

    test('cache-loaded index = completed(5) + planned 01-28 = 6', () async {
      final FakeFirebaseFirestore db = await seedWorkouts(completed);
      final int idx = await BB3PlannedExerciseService.getExposureHintIndex(
        exerciseId: kExId,
        exerciseName: kExName,
        blockStartDate: kBlockStart,
        selectedDate: sel,
        uid: kUid,
        blockId: kBlockId,
        firestore: db,
        today: today,
        plannedDayLoader: (DateTime d) async =>
            plannedByDate[ymd(d)] ?? const <BB3Exercise>[],
      );
      expect(idx, 6);
    });

    test('pre-cache index equals the cache-loaded index', () async {
      final FakeFirebaseFirestore db = await seedWorkouts(completed);
      final int cached = await BB3PlannedExerciseService.getExposureHintIndex(
        exerciseId: kExId,
        exerciseName: kExName,
        blockStartDate: kBlockStart,
        selectedDate: sel,
        uid: kUid,
        blockId: kBlockId,
        firestore: db,
        today: today,
        plannedDayLoader: (DateTime d) async =>
            plannedByDate[ymd(d)] ?? const <BB3Exercise>[],
      );
      final int sync = BB3PlannedExerciseService.exposurePositionSync(
        exerciseId: kExId,
        exerciseName: kExName,
        blockStartDate: kBlockStart,
        selectedDate: sel,
        today: today,
        plannedByDateKey: plannedByDate,
      );
      expect(sync, cached);
    });

    test('current-day row: a workout already logged today is not counted',
        () async {
      final FakeFirebaseFirestore db = await seedWorkouts(completed);
      final int idx = await BB3PlannedExerciseService.getExposureHintIndex(
        exerciseId: kExId,
        exerciseName: kExName,
        blockStartDate: kBlockStart,
        selectedDate: today,
        uid: kUid,
        blockId: kBlockId,
        firestore: db,
        today: today,
        plannedDayLoader: (DateTime d) async =>
            plannedByDate[ymd(d)] ?? const <BB3Exercise>[],
      );
      expect(idx, 4, reason: 'equal to WES2: the four exposures before today');
    });

    test('a past selected date ignores later completions', () async {
      final FakeFirebaseFirestore db = await seedWorkouts(completed);
      final int idx = await BB3PlannedExerciseService.getExposureHintIndex(
        exerciseId: kExId,
        exerciseName: kExName,
        blockStartDate: kBlockStart,
        selectedDate: DateTime(2026, 1, 13),
        uid: kUid,
        blockId: kBlockId,
        firestore: db,
        today: today,
        plannedDayLoader: (DateTime d) async =>
            plannedByDate[ymd(d)] ?? const <BB3Exercise>[],
      );
      expect(idx, 2);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('settings dialog shows the same resolved instance the hint uses', () {
    Future<void> pumpDialog(WidgetTester tester, ActiveInstance a) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await db
          .collection('users')
          .doc(kUid)
          .collection('planned_blocks')
          .doc(kBlockId)
          .set(<String, dynamic>{
        'exerciseSettings': <String, dynamic>{kExId: exerciseSettingsFor()},
      });
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Wes2ExerciseSettingsDialog(
            uid: kUid,
            blockId: kBlockId,
            exerciseId: kExId,
            exerciseName: kExName,
            weekIndex: 2,
            dayIndex: 6, // a weekday position that must NOT be used
            totalBlockWeeks: 12,
            planService: FirestoreWes2PlanService(firestore: db),
            activeInstance: a,
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    /// The 1-based RIR session group that carries the active-session border.
    int? highlightedSession(WidgetTester tester) {
      for (int i = 1; i <= 3; i++) {
        final Finder label = find.text('Session $i');
        if (label.evaluate().isEmpty) continue;
        final Finder boxed = find.ancestor(
          of: label,
          matching: find.byWidgetPredicate((Widget w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).border != null),
        );
        if (boxed.evaluate().isNotEmpty) return i;
      }
      return null;
    }

    testWidgets('position 4 → instance 2 of 3 and Session 2', (tester) async {
      await pumpDialog(
          tester,
          ActiveInstanceResolver.resolve(
              exposurePosition: 4, repInstanceCount: 3, rirSessionCount: 3));
      expect(
          find.textContaining('rep target instance: 2 of 3'), findsOneWidget);
      expect(highlightedSession(tester), 2);
    });

    testWidgets(
        'this pass: the caller\'s effective WES2 RIR session wins over the '
        'instance\'s RIR index (weekday 7 → session1 fallback)',
        (tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await db
          .collection('users')
          .doc(kUid)
          .collection('planned_blocks')
          .doc(kBlockId)
          .set(<String, dynamic>{
        'exerciseSettings': <String, dynamic>{kExId: exerciseSettingsFor()},
      });
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Wes2ExerciseSettingsDialog(
            uid: kUid,
            blockId: kBlockId,
            exerciseId: kExId,
            exerciseName: kExName,
            weekIndex: 2,
            dayIndex: 6,
            totalBlockWeeks: 12,
            planService: FirestoreWes2PlanService(firestore: db),
            activeRirSessionIndex: 7,
            activeInstance: ActiveInstanceResolver.resolve(
                exposurePosition: 4, repInstanceCount: 3, rirSessionCount: 3),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('rep target instance: 2 of 3'), findsOneWidget);
      expect(highlightedSession(tester), 1);
    });

    testWidgets('rep slot and RIR session are shown independently',
        (tester) async {
      await pumpDialog(
          tester,
          const ActiveInstance(
              exposurePosition: 5, repInstanceIndex: 2, rirSessionIndex: 1));
      expect(
          find.textContaining('rep target instance: 3 of 3'), findsOneWidget);
      expect(highlightedSession(tester), 2);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('BB3 hint carries a numeric kg weight (no string round trip)', () {
    setUp(() => seedHistory(history()));
    tearDown(clearHistory);

    test('on a 15 lb grid the numeric weight is an exact multiple of 15 lb',
        () {
      final Map<String, dynamic> all = allSettings(
          settings: exerciseSettingsFor(
              increments: <String, dynamic>{'primary': 6.80388555}));
      final BB3SetHint h = BB3HintService.getHintsForSet(
        exerciseId: kExId,
        exerciseName: kExName,
        fullExerciseSettings: all,
        weekIndex: 2,
        sessionIndex: 1,
        setIndex: 0,
        blockStartDate: kBlockStart,
        blockEndDate: kBlockEnd,
        selectedDate: kSelected,
        uid: kUid,
      );
      expect(h.weightKg, isNotNull);
      final double lb = ExerciseWeightUnit.lb.fromKg(h.weightKg!);
      expect((lb - (lb / 15).round() * 15).abs(), lessThan(1e-6),
          reason: '$lb lb');
      expect(formatWeightNumber(lb), isNot(contains('.')));
    });
  });
}
