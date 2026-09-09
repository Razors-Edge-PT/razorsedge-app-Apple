import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_plan_service.dart';
import 'package:localtest222/WES2_widgets/WES2_exercise_settings_dialog.dart';
import 'package:localtest222/block_exercise_defaults_repository.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/settings_merge.dart';
import 'package:localtest222/wes2_exercise_settings_patch.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Focused regression suite for the WES2 exercise-settings Secondary Increment.
//
// Confirmed production symptom (Butterfly Dumbbell Raise, exerciseId
// RcC48r0oLsNCH798d3jc): Firestore carried `increments: {primary: 2.5,
// secondary: 1.25}` but the settings cog only exposed Primary Increment, so the
// hidden secondary silently added 1.25-offset weights (…13.75, 16.25…) to the
// valid-weight grid that every progression model — Smart Progression included —
// snaps to. WES2's one-decimal formatter then rendered 16.25 as "16.3".
// ─────────────────────────────────────────────────────────────────────────────

const _uid = 'u1';
const _block = 'b1';
const _butterflyId = 'RcC48r0oLsNCH798d3jc';

/// Complete, `isSettingsUsable`-passing config shaped like the real Butterfly
/// Dumbbell Raise entry (DUP, By Exposure, Smart Progression), with both
/// increments present.
Map<String, dynamic> _butterflySettings({
  Object? primary = 2.5,
  Object? secondary = 1.25,
}) =>
    {
      'periodizationModel': 'DUP, By Exposure',
      'rirModel': 'Static RIR',
      'progressionModel': 'Smart Progression',
      'weeklyFrequency': 3,
      'defaultSets': 3,
      'increments': {
        if (primary != null) 'primary': primary,
        if (secondary != null) 'secondary': secondary,
      },
      'notes': 'keep me',
      'someUnknownKey': {
        'keepMe': true,
        'nested': [1, 2, 3],
      },
      'repTargets': {
        'week1': {
          'instance1': '12 x 3',
          'instance2': '10 x 3',
          'instance3': '8 x 3',
        },
      },
      'rirPlan': {
        'week1': {
          'session1': {
            'set1': {'rir': '2', 'reps': '12'},
            'set2': {'rir': '2'},
            'set3': {'rir': '2'},
          },
          'session2': {
            'set1': {'rir': '2', 'reps': '10'},
            'set2': {'rir': '2'},
            'set3': {'rir': '2'},
          },
          'session3': {
            'set1': {'rir': '1', 'reps': '8'},
            'set2': {'rir': '1'},
            'set3': {'rir': '1'},
          },
        },
      },
    };

Future<FakeFirebaseFirestore> _seed(Map<String, dynamic> settings) async {
  final db = FakeFirebaseFirestore();
  await db
      .collection('users')
      .doc(_uid)
      .collection('planned_blocks')
      .doc(_block)
      .set({
    'exerciseSettings': {
      _butterflyId: settings,
      // A sibling exercise that must never change when Butterfly is saved.
      'squatId': {
        'periodizationModel': 'DUP, By Week',
        'weeklyFrequency': 2,
        'increments': {'primary': 5.0},
        'repTargets': {
          'week1': {'instance1': '5 x 3', 'instance2': '5 x 3'}
        },
      },
    },
    // Legacy top-level key that must never change.
    'plannedExerciseDetails': {
      _butterflyId: {'legacy': 'DO_NOT_TOUCH'}
    },
  });
  return db;
}

Future<Map<String, dynamic>> _reloadButterfly(FakeFirebaseFirestore db) async {
  final svc = FirestoreWes2PlanService(firestore: db);
  final all = await svc.loadExerciseSettings(uid: _uid, blockId: _block);
  return Map<String, dynamic>.from(all[_butterflyId] as Map);
}

List<double> _gridFor(dynamic incrementsRaw) =>
    PeriodizationModelUtils.expandIncrementOptions(
        PeriodizationModelUtils.incMapFromRaw(incrementsRaw));

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // TEST 1 — the Secondary field is actually rendered and pre-filled
  // ───────────────────────────────────────────────────────────────────────────
  testWidgets('TEST 1 — dialog visibly loads primary AND secondary increments',
      (tester) async {
    final db = await _seed(_butterflySettings()); // primary 2.5 / secondary 1.25
    final planService = FirestoreWes2PlanService(firestore: db);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Wes2ExerciseSettingsDialog(
          uid: _uid,
          blockId: _block,
          exerciseId: _butterflyId,
          exerciseName: 'Butterfly Dumbbell Raise',
          weekIndex: 0,
          dayIndex: 0,
          totalBlockWeeks: 4,
          planService: planService,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Both increment labels are on screen.
    expect(find.text('Primary Increment'), findsOneWidget);
    expect(find.text('Secondary Increment'), findsOneWidget);
    // Weekly Frequency is still visible alongside them.
    expect(find.text('Weekly Frequency'), findsOneWidget);

    TextField fieldFor(String label) => tester.widget<TextField>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(TextField),
          ),
        );

    // The visible controls (not just the controllers) carry the stored values.
    expect(fieldFor('Primary Increment').controller!.text, '2.5');
    expect(fieldFor('Secondary Increment').controller!.text, '1.25');
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 7a — after clearing + saving, reopening the dialog shows Secondary blank
  // ───────────────────────────────────────────────────────────────────────────
  testWidgets('TEST 7a — reopened dialog shows Secondary blank once removed',
      (tester) async {
    final db = await _seed(_butterflySettings());
    final planService = FirestoreWes2PlanService(firestore: db);

    // Remove secondary through the real save service.
    await planService.saveExerciseSettings(
      uid: _uid,
      blockId: _block,
      exerciseId: _butterflyId,
      patch: const ExerciseSettingsPatch(
        incrementChanges: {'secondary': null},
        totalBlockWeeks: 4,
      ),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Wes2ExerciseSettingsDialog(
          uid: _uid,
          blockId: _block,
          exerciseId: _butterflyId,
          exerciseName: 'Butterfly Dumbbell Raise',
          weekIndex: 0,
          dayIndex: 0,
          totalBlockWeeks: 4,
          planService: planService,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    TextField fieldFor(String label) => tester.widget<TextField>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(TextField),
          ),
        );

    expect(fieldFor('Primary Increment').controller!.text, '2.5');
    expect(fieldFor('Secondary Increment').controller!.text, '');
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Canonical grid expansion — the single interpretation every model consumes
  // ───────────────────────────────────────────────────────────────────────────
  group('canonical increment grid', () {
    test('TEST 2 — primary-only grid has no 1.25 offsets', () {
      final grid = _gridFor({'primary': 2.5});
      for (final w in [0.0, 2.5, 5.0, 7.5, 10.0, 12.5, 15.0, 17.5]) {
        expect(grid, contains(w));
      }
      for (final w in [1.25, 3.75, 6.25, 16.25]) {
        expect(grid, isNot(contains(w)));
      }
    });

    test('TEST 3 — primary + secondary grid includes the 1.25 offsets', () {
      final grid = _gridFor({'primary': 2.5, 'secondary': 1.25});
      for (final w in [1.25, 3.75, 6.25, 13.75, 16.25]) {
        expect(grid, contains(w));
      }
      // Primary steps are still present.
      for (final w in [0.0, 2.5, 5.0, 15.0, 17.5]) {
        expect(grid, contains(w));
      }
    });

    test('TEST 10 — secondary == primary collapses to the primary-only grid',
        () {
      final dual = _gridFor({'primary': 2.5, 'secondary': 2.5});
      final primaryOnly = _gridFor({'primary': 2.5});
      expect(dual, orderedEquals(primaryOnly));
    });

    test('incMapFromRaw drops an absent secondary entirely', () {
      expect(PeriodizationModelUtils.incMapFromRaw({'primary': 2.5}),
          {'primary': 2.5});
      expect(
          PeriodizationModelUtils.incMapFromRaw(
              {'primary': 2.5, 'secondary': 1.25}),
          {'primary': 2.5, 'secondary': 1.25});
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Save semantics through the real transactional service + fake Firestore
  // ───────────────────────────────────────────────────────────────────────────
  group('saveExerciseSettings — increment leaves', () {
    test('TEST 4 — change primary only; secondary is preserved', () async {
      final db = await _seed(_butterflySettings()); // 2.5 / 1.25
      final svc = FirestoreWes2PlanService(firestore: db);

      await svc.saveExerciseSettings(
        uid: _uid,
        blockId: _block,
        exerciseId: _butterflyId,
        patch: const ExerciseSettingsPatch(
          incrementChanges: {'primary': 5.0},
          totalBlockWeeks: 4,
        ),
      );

      final inc = (await _reloadButterfly(db))['increments'] as Map;
      expect((inc['primary'] as num).toDouble(), 5.0);
      expect((inc['secondary'] as num).toDouble(), 1.25);

      // Resulting grid uses both steps (5.0 primary + 1.25 secondary).
      final grid = _gridFor(inc);
      expect(grid, contains(6.25)); // 5.0 + 1.25
      expect(grid, contains(11.25)); // 10.0 + 1.25
    });

    test('TEST 5 — change secondary only; new value drives the grid', () async {
      final db = await _seed(_butterflySettings()); // 2.5 / 1.25
      final svc = FirestoreWes2PlanService(firestore: db);

      await svc.saveExerciseSettings(
        uid: _uid,
        blockId: _block,
        exerciseId: _butterflyId,
        patch: const ExerciseSettingsPatch(
          incrementChanges: {'secondary': 0.5},
          totalBlockWeeks: 4,
        ),
      );

      final inc = (await _reloadButterfly(db))['increments'] as Map;
      expect((inc['primary'] as num).toDouble(), 2.5);
      expect((inc['secondary'] as num).toDouble(), 0.5);

      final grid = _gridFor(inc);
      expect(grid, contains(0.5));
      expect(grid, contains(3.0)); // 2.5 + 0.5
      expect(grid, isNot(contains(16.25))); // old 1.25 offset gone
    });

    test('TEST 6 — clearing secondary physically removes the key', () async {
      final db = await _seed(_butterflySettings()); // 2.5 / 1.25
      final svc = FirestoreWes2PlanService(firestore: db);

      // Prove the offending candidate exists beforehand.
      expect(_gridFor((await _reloadButterfly(db))['increments']),
          contains(16.25));

      await svc.saveExerciseSettings(
        uid: _uid,
        blockId: _block,
        exerciseId: _butterflyId,
        patch: const ExerciseSettingsPatch(
          incrementChanges: {'secondary': null},
          totalBlockWeeks: 4,
        ),
      );

      final reloaded = await _reloadButterfly(db);
      final inc = reloaded['increments'] as Map;
      expect(inc['primary'], isNotNull);
      expect((inc['primary'] as num).toDouble(), 2.5);
      expect(inc.containsKey('secondary'), isFalse);
      expect(inc['secondary'], isNull);

      final map = PeriodizationModelUtils.incMapFromRaw(inc);
      expect(map, {'primary': 2.5});

      final grid = _gridFor(inc);
      for (final w in [0.0, 2.5, 5.0, 7.5, 10.0, 12.5, 15.0, 17.5]) {
        expect(grid, contains(w));
      }
      for (final w in [1.25, 3.75, 6.25, 13.75, 16.25]) {
        expect(grid, isNot(contains(w)));
      }
    });

    test('TEST 9 — clearing secondary preserves every unrelated setting',
        () async {
      final db = await _seed(_butterflySettings());
      final svc = FirestoreWes2PlanService(firestore: db);

      final before = await _reloadButterfly(db);

      // Sibling exercise snapshot.
      final siblingBefore = Map<String, dynamic>.from(
        ((await db
                    .collection('users')
                    .doc(_uid)
                    .collection('planned_blocks')
                    .doc(_block)
                    .get())
                .data()!['exerciseSettings'] as Map)['squatId'] as Map,
      );

      await svc.saveExerciseSettings(
        uid: _uid,
        blockId: _block,
        exerciseId: _butterflyId,
        patch: const ExerciseSettingsPatch(
          incrementChanges: {'secondary': null},
          totalBlockWeeks: 4,
        ),
      );

      final after = await _reloadButterfly(db);

      expect(after['repTargets'], before['repTargets']);
      expect(after['rirPlan'], before['rirPlan']);
      expect(after['periodizationModel'], before['periodizationModel']);
      expect(after['rirModel'], before['rirModel']);
      expect(after['progressionModel'], before['progressionModel']);
      expect(after['weeklyFrequency'], before['weeklyFrequency']);
      expect(after['defaultSets'], before['defaultSets']);
      expect(after['notes'], before['notes']);
      expect(after['someUnknownKey'], before['someUnknownKey']);

      final doc = (await db
              .collection('users')
              .doc(_uid)
              .collection('planned_blocks')
              .doc(_block)
              .get())
          .data()!;
      // NOTE: production writes set(SetOptions(mergeFields: ['exerciseSettings']))
      // which in REAL Firestore leaves every other top-level field
      // (plannedExerciseDetails, completed workout records, …) untouched.
      // fake_cloud_firestore does not model that preservation, so we assert the
      // property the fake CAN model: other exercises inside exerciseSettings are
      // byte-identical and only the edited exercise changed.
      expect((doc['exerciseSettings'] as Map)['squatId'], siblingBefore);

      // Only the intended leaf changed.
      expect((after['increments'] as Map).containsKey('secondary'), isFalse);
    });

    test('TEST 11 — Butterfly regression: 16.25 candidate appears then vanishes',
        () async {
      final db = await _seed(_butterflySettings()); // 2.5 / 1.25
      final svc = FirestoreWes2PlanService(firestore: db);

      final gridBefore = _gridFor((await _reloadButterfly(db))['increments']);
      expect(gridBefore, contains(16.25),
          reason: 'hidden secondary 1.25 makes 16.25 a valid candidate');

      await svc.saveExerciseSettings(
        uid: _uid,
        blockId: _block,
        exerciseId: _butterflyId,
        patch: const ExerciseSettingsPatch(
          incrementChanges: {'secondary': null},
          totalBlockWeeks: 4,
        ),
      );

      final gridAfter = _gridFor((await _reloadButterfly(db))['increments']);
      expect(gridAfter, isNot(contains(16.25)),
          reason: 'primary-only 2.5 grid can never produce 16.25 → no "16.3"');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 8 — the WES refresh path (loadExerciseSettings → new grid) has no
  // stale increment cache: a freshly reloaded settings map yields the new grid.
  // (WES2_screen wiring: _openExerciseSettings reloads + re-runs
  // _loadAndApplyHints after saved == true; Wes2HintServiceImpl reads
  // `increments` inline via expandIncrementOptions(incMapFromRaw(...)) on every
  // compute, and is reconstructed from the reloaded map.)
  // ───────────────────────────────────────────────────────────────────────────
  test('TEST 8 — reload after save immediately exposes the primary-only grid',
      () async {
    final db = await _seed(_butterflySettings());
    final svc = FirestoreWes2PlanService(firestore: db);

    // Session already holds the pre-save grid.
    final gridAtStart = _gridFor((await _reloadButterfly(db))['increments']);
    expect(gridAtStart, contains(16.25));

    await svc.saveExerciseSettings(
      uid: _uid,
      blockId: _block,
      exerciseId: _butterflyId,
      patch: const ExerciseSettingsPatch(
        incrementChanges: {'secondary': null},
        totalBlockWeeks: 4,
      ),
    );

    // Same code path _openExerciseSettings runs on saved == true.
    final reloaded = await svc.loadExerciseSettings(uid: _uid, blockId: _block);
    final gridAfterReload =
        _gridFor((reloaded[_butterflyId] as Map)['increments']);

    expect(gridAfterReload, isNot(contains(16.25)));
    expect(gridAfterReload, contains(15.0));
    expect(gridAfterReload, contains(17.5));
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 7b — defaults / lazy healer must not re-introduce a removed secondary
  // ───────────────────────────────────────────────────────────────────────────
  group('defaults never restore a deliberately removed secondary', () {
    test('TEST 7b — projectHealedSettings leaves a primary-only map alone', () {
      // Existing = the post-clear canonical state (still fully usable).
      final existing = _butterflySettings(secondary: null);
      // Library defaults for an isolation exercise DO carry a secondary.
      final defaults = {
        'increments': {'primary': 2.5, 'secondary': 1.25},
        'weeklyFrequency': 3,
      };

      final healed =
          BlockExerciseDefaultsRepository.projectHealedSettings(existing, defaults);

      expect((healed['increments'] as Map).containsKey('secondary'), isFalse,
          reason: 'absence of secondary is a valid canonical configuration');
      expect((healed['increments'] as Map)['primary'], 2.5);
    });

    test('projectHealedSettings still seeds increments when wholly absent', () {
      final existing = _butterflySettings()..remove('increments');
      final defaults = {
        'increments': {'primary': 2.5, 'secondary': 1.25},
      };

      final healed =
          BlockExerciseDefaultsRepository.projectHealedSettings(existing, defaults);

      expect(healed['increments'], {'primary': 2.5, 'secondary': 1.25});
    });

    test('repairShadows never touches increments', () {
      final cleared = _butterflySettings(secondary: null);
      final (repaired, changed) = SettingsMerge.repairShadows(cleared);
      expect(changed, isFalse);
      expect((repaired['increments'] as Map).containsKey('secondary'), isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Smart Progression consumes the SAME canonical grid — no private
  // interpretation. Its output is always drawn from the grid it is handed, so
  // once 16.25 leaves that grid Smart Progression can no longer emit it.
  // Candidate-selection / scoring logic itself is NOT exercised or changed here.
  // ───────────────────────────────────────────────────────────────────────────
  group('Smart Progression uses the canonical grid', () {
    setUp(() => PeriodizationModelUtils.savedWorkoutsList = []);
    tearDown(() => PeriodizationModelUtils.savedWorkoutsList = []);

    final history = <Map<String, dynamic>>[
      {
        'weight': 16.0,
        'reps': 10,
        'rir': 2,
        'date': DateTime(2026, 1, 20),
      },
    ];

    Map<String, dynamic> run(List<double> grid) =>
        PeriodizationModelUtils.smartProgressionModel(
          exerciseName: 'Butterfly Dumbbell Raise',
          repTarget: 10,
          defaultWeight: 15.0,
          rirValue: 2,
          increments: grid,
          topSetHistory: history,
          weekIndex: 1,
          exerciseId: _butterflyId,
          asOfDate: DateTime(2026, 1, 27),
        );

    test('TEST 3 (SP) — with secondary, SP may land on a 1.25-offset weight',
        () {
      final grid = _gridFor({'primary': 2.5, 'secondary': 1.25});
      final w = (run(grid)['weight'] as num).toDouble();
      expect(grid, contains(w),
          reason: 'SP only ever returns a member of the grid it is given');
      expect(grid, contains(16.25));
    });

    test('TEST 11 (SP) — primary-only grid, SP output is a clean 2.5 multiple',
        () {
      final grid = _gridFor({'primary': 2.5});
      final w = (run(grid)['weight'] as num).toDouble();
      expect(grid, contains(w));
      expect((w / 2.5 - (w / 2.5).round()).abs(), lessThan(1e-9),
          reason: 'no 1.25-offset candidate can survive without a secondary');
      expect(grid, isNot(contains(16.25)));
    });
  });
}
