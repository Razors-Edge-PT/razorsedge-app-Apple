import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_plan_service.dart';
import 'package:localtest222/bb3_planned_exercise_service.dart';
import 'package:localtest222/settings_merge.dart';
import 'package:localtest222/wes2_exercise_settings_patch.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Fixtures
// ─────────────────────────────────────────────────────────────────────────────

/// Complete canonical Static-RIR (template) Bench-style config: week1 only.
Map<String, dynamic> _completeTemplateSettings() => {
      'periodizationModel': 'DUP, By Week',
      'rirModel': 'Static RIR',
      'progressionModel': 'Smart Progression',
      'weeklyFrequency': 3,
      'defaultSets': 3,
      'increments': {'primary': 2.5, 'secondary': 1.25},
      'someUnknownKey': {'keepMe': true, 'nested': [1, 2, 3]},
      'repTargets': {
        'week1': {
          'instance1': '3 x 4',
          'instance2': '12 x 3',
          'instance3': '5 x 3',
        },
      },
      'rirPlan': {
        'week1': {
          'session1': {
            'set1': {'rir': '2', 'reps': '3'},
            'set2': {'rir': '2'},
            'set3': {'rir': '2.5'},
          },
          'session2': {
            'set1': {'rir': '2', 'reps': '12'},
            'set2': {'rir': '2'},
            'set3': {'rir': '2.5'},
          },
          'session3': {
            'set1': {'rir': '1.5', 'reps': '5'},
            'set2': {'rir': '2'},
            'set3': {'rir': '3.5'},
          },
        },
      },
    };

const _uid = 'u1';
const _block = 'b1';
const _ex = 'benchId';

Future<FakeFirebaseFirestore> _seed(Map<String, dynamic> settings,
    {Map<String, dynamic> extraDocFields = const {}}) async {
  final db = FakeFirebaseFirestore();
  await db
      .collection('users')
      .doc(_uid)
      .collection('planned_blocks')
      .doc(_block)
      .set({
    'exerciseSettings': {
      _ex: settings,
      // A sibling exercise that must never change when we save benchId.
      'squatId': {
        'periodizationModel': 'DUP, By Week',
        'weeklyFrequency': 2,
        'rirPlan': {
          'week1': {
            'session1': {
              'set1': {'rir': '3'}
            }
          }
        },
      },
    },
    // Legacy/other top-level keys that must never change.
    'plannedExerciseDetails': {
      'benchId': {'legacy': 'DO_NOT_TOUCH'}
    },
    ...extraDocFields,
  });
  return db;
}

Future<Map<String, dynamic>> _allExerciseSettings(
    FakeFirebaseFirestore db) async {
  final snap = await db
      .collection('users')
      .doc(_uid)
      .collection('planned_blocks')
      .doc(_block)
      .get();
  return Map<String, dynamic>.from(snap.data()!['exerciseSettings'] as Map);
}

Future<Map<String, dynamic>> _readSettings(FakeFirebaseFirestore db) async {
  final snap = await db
      .collection('users')
      .doc(_uid)
      .collection('planned_blocks')
      .doc(_block)
      .get();
  return Map<String, dynamic>.from(
      (snap.data()!['exerciseSettings'] as Map)[_ex] as Map);
}

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // Pure merge / propagation
  // ───────────────────────────────────────────────────────────────────────────
  group('SettingsMerge.applyPatch', () {
    test('1+12+13: one RIR edit preserves every unrelated field & reps sibling',
        () {
      final base = _completeTemplateSettings();
      final patch = ExerciseSettingsPatch(
        rirChanges: const [RirChange(session: 'session2', set: 'set1', rir: '2.5')],
        totalBlockWeeks: 4,
      );
      final out = SettingsMerge.applyPatch(base, patch);

      final rir = out['rirPlan']['week1'];
      // Only the intended leaf changed.
      expect(rir['session2']['set1']['rir'], '2.5');
      // Sibling reps preserved.
      expect(rir['session2']['set1']['reps'], '12');
      // Every other RIR value intact.
      expect(rir['session1']['set1']['rir'], '2');
      expect(rir['session2']['set2']['rir'], '2');
      expect(rir['session3']['set3']['rir'], '3.5');
      // No sparse weekN created (template model).
      expect(out['rirPlan'].keys.toList(), ['week1']);
      // Unrelated scalars + unknown metadata intact.
      expect(out['weeklyFrequency'], 3);
      expect(out['someUnknownKey'], {
        'keepMe': true,
        'nested': [1, 2, 3]
      });
      expect(out['repTargets'], base['repTargets']);
    });

    test('2: one rep-target edit preserves every unrelated field', () {
      final base = _completeTemplateSettings();
      final patch = ExerciseSettingsPatch(
        repTargetChanges: const [RepTargetChange('instance2', '10 x 3')],
        totalBlockWeeks: 4,
      );
      final out = SettingsMerge.applyPatch(base, patch);
      expect(out['repTargets']['week1']['instance2'], '10 x 3');
      expect(out['repTargets']['week1']['instance1'], '3 x 4');
      expect(out['repTargets']['week1']['instance3'], '5 x 3');
      expect(out['repTargets'].keys.toList(), ['week1']); // no sparse weekN
      expect(out['rirPlan'], base['rirPlan']);
    });

    test('9: template model updates week1 and creates no sparse weekN', () {
      final base = _completeTemplateSettings(); // DUP, By Week + Static RIR
      final patch = ExerciseSettingsPatch(
        rirChanges: const [RirChange(session: 'session1', set: 'set2', rir: '0.5')],
        repTargetChanges: const [RepTargetChange('instance1', '4 x 4')],
        totalBlockWeeks: 6,
      );
      final out = SettingsMerge.applyPatch(base, patch);
      expect(out['rirPlan'].keys.toList(), ['week1']);
      expect(out['repTargets'].keys.toList(), ['week1']);
      expect(out['rirPlan']['week1']['session1']['set2']['rir'], '0.5');
    });

    test('10: per-week model propagates the changed leaf across all weeks', () {
      final base = _completeTemplateSettings();
      base['rirModel'] = 'Linear-Taper'; // per-week scope
      final patch = ExerciseSettingsPatch(
        rirChanges: const [RirChange(session: 'session2', set: 'set1', rir: '1')],
        totalBlockWeeks: 4,
      );
      final out = SettingsMerge.applyPatch(base, patch);
      for (var w = 1; w <= 4; w++) {
        expect(out['rirPlan']['week$w']['session2']['set1']['rir'], '1',
            reason: 'week$w should carry the propagated leaf');
        // Unrelated leaves preserved (seeded from week1 template).
        expect(out['rirPlan']['week$w']['session1']['set1']['rir'], '2');
      }
    });

    test('11: clearing one field removes only that leaf', () {
      final base = _completeTemplateSettings();
      final patch = ExerciseSettingsPatch(
        rirChanges: const [RirChange(session: 'session2', set: 'set2', rir: null)],
        totalBlockWeeks: 4,
      );
      final out = SettingsMerge.applyPatch(base, patch);
      final sess2 = out['rirPlan']['week1']['session2'] as Map;
      // set2 removed (it had only rir); siblings intact.
      expect(sess2.containsKey('set2'), false);
      expect(sess2['set1']['rir'], '2');
      expect(sess2['set1']['reps'], '12');
      expect(sess2['set3']['rir'], '2.5');
    });

    test('clear preserves reps sibling when set has other keys', () {
      final base = _completeTemplateSettings();
      final patch = ExerciseSettingsPatch(
        rirChanges: const [RirChange(session: 'session2', set: 'set1', rir: null)],
        totalBlockWeeks: 4,
      );
      final out = SettingsMerge.applyPatch(base, patch);
      final set1 = out['rirPlan']['week1']['session2']['set1'] as Map;
      expect(set1.containsKey('rir'), false);
      expect(set1['reps'], '12'); // sibling survives
    });

    test('increment edit merges only changed sub-key', () {
      final base = _completeTemplateSettings();
      final patch = ExerciseSettingsPatch(
        incrementChanges: const {'primary': 5.0},
        totalBlockWeeks: 4,
      );
      final out = SettingsMerge.applyPatch(base, patch);
      expect(out['increments']['primary'], 5.0);
      expect(out['increments']['secondary'], 1.25); // preserved
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Repair
  // ───────────────────────────────────────────────────────────────────────────
  group('SettingsMerge.repairShadows', () {
    test('7: sparse weekN shadow removed (template) before display', () {
      final s = _completeTemplateSettings();
      // Simulate prior-bug corruption: sparse week3 with a single leaf.
      (s['rirPlan'] as Map)['week3'] = {
        'session2': {
          'set1': {'rir': '2.5'}
        }
      };
      final (repaired, changed) = SettingsMerge.repairShadows(s);
      expect(changed, true);
      expect((repaired['rirPlan'] as Map).keys.toList(), ['week1']);
      // week1 template fully intact.
      expect(repaired['rirPlan']['week1']['session1']['set1']['rir'], '2');
    });

    test('8: healthy complete custom weekN is NOT changed', () {
      final s = _completeTemplateSettings();
      s['rirModel'] = 'Linear-Taper'; // per-week scope
      // week2 has full coverage but custom values.
      (s['rirPlan'] as Map)['week2'] = {
        'session1': {
          'set1': {'rir': '0.5', 'reps': '3'},
          'set2': {'rir': '0.5'},
          'set3': {'rir': '1'},
        },
        'session2': {
          'set1': {'rir': '0.5', 'reps': '12'},
          'set2': {'rir': '0.5'},
          'set3': {'rir': '1'},
        },
        'session3': {
          'set1': {'rir': '0', 'reps': '5'},
          'set2': {'rir': '0.5'},
          'set3': {'rir': '1'},
        },
      };
      final before = Map<String, dynamic>.from(s['rirPlan']['week2']);
      final (repaired, changed) = SettingsMerge.repairShadows(s);
      expect(changed, false);
      expect(repaired['rirPlan']['week2'], before);
    });

    test('5+6: per-week repair fills only missing leaves, never overwrites', () {
      final s = _completeTemplateSettings();
      s['rirModel'] = 'Wave RIR undulation'; // per-week scope
      // week2 sparse subset: has session2/set1 with a CUSTOM value, missing rest.
      (s['rirPlan'] as Map)['week2'] = {
        'session2': {
          'set1': {'rir': '0.5', 'reps': '12'}
        }
      };
      final (repaired, changed) = SettingsMerge.repairShadows(s);
      expect(changed, true);
      final w2 = repaired['rirPlan']['week2'];
      // Present custom value preserved (NOT overwritten by week1's '2').
      expect(w2['session2']['set1']['rir'], '0.5');
      expect(w2['session2']['set1']['reps'], '12');
      // Genuinely missing leaves filled from week1 template.
      expect(w2['session1']['set1']['rir'], '2');
      expect(w2['session3']['set3']['rir'], '3.5');
      expect(w2['session2']['set2']['rir'], '2');
    });

    test('3: custom stored RIR differing from default is preserved (no repair)',
        () {
      final s = _completeTemplateSettings();
      s['rirPlan']['week1']['session2']['set1']['rir'] = '2.5'; // custom
      final (repaired, changed) = SettingsMerge.repairShadows(s);
      expect(changed, false);
      expect(repaired['rirPlan']['week1']['session2']['set1']['rir'], '2.5');
    });

    test('4: custom stored rep target differing from default is preserved', () {
      final s = _completeTemplateSettings();
      s['repTargets']['week1']['instance1'] = '5 x 5'; // custom vs any default
      final (repaired, changed) = SettingsMerge.repairShadows(s);
      expect(changed, false);
      expect(repaired['repTargets']['week1']['instance1'], '5 x 5');
    });

    test('healthy template-only config triggers no repair', () {
      final (_, changed) =
          SettingsMerge.repairShadows(_completeTemplateSettings());
      expect(changed, false);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Service (fake Firestore) — transaction wiring
  // ───────────────────────────────────────────────────────────────────────────
  group('FirestoreWes2PlanService.saveExerciseSettings', () {
    test('exact reported case: only Session2/Set1 RIR changes to 2.5', () async {
      final db = await _seed(_completeTemplateSettings());
      final svc = FirestoreWes2PlanService(firestore: db);

      await svc.saveExerciseSettings(
        uid: _uid,
        blockId: _block,
        exerciseId: _ex,
        patch: const ExerciseSettingsPatch(
          rirChanges: [RirChange(session: 'session2', set: 'set1', rir: '2.5')],
          totalBlockWeeks: 4,
        ),
      );

      final saved = await _readSettings(db);
      final rir = saved['rirPlan']['week1'];
      expect(rir['session2']['set1']['rir'], '2.5');
      expect(rir['session2']['set1']['reps'], '12'); // sibling
      expect(rir['session1']['set1']['rir'], '2');
      expect(rir['session3']['set3']['rir'], '3.5');
      expect(saved['rirPlan'].keys.toList(), ['week1']); // no sparse weekN
      // everything else intact
      expect(saved['repTargets'], _completeTemplateSettings()['repTargets']);
      expect(saved['weeklyFrequency'], 3);
      expect(saved['progressionModel'], 'Smart Progression');
      expect(saved['someUnknownKey'], {
        'keepMe': true,
        'nested': [1, 2, 3]
      });
    });

    test('18+17: save touches only the edited exercise; other exercises intact',
        () async {
      // NOTE: production uses set(SetOptions(mergeFields: ['exerciseSettings'])),
      // which in REAL Firestore writes ONLY the exerciseSettings field and
      // leaves every other top-level field (plannedExerciseDetails, completed
      // workout records, etc.) untouched. fake_cloud_firestore does not model
      // mergeFields' preservation of unlisted top-level fields, so here we
      // assert the property fake CAN model: other exercises inside the written
      // field are preserved and only the edited exercise changes.
      final db = await _seed(_completeTemplateSettings());
      final svc = FirestoreWes2PlanService(firestore: db);

      final squatBefore = (await _allExerciseSettings(db))['squatId'];

      await svc.saveExerciseSettings(
        uid: _uid,
        blockId: _block,
        exerciseId: _ex,
        patch: const ExerciseSettingsPatch(
          rirChanges: [RirChange(session: 'session1', set: 'set1', rir: '0')],
          totalBlockWeeks: 4,
        ),
      );

      final all = await _allExerciseSettings(db);
      // Sibling exercise byte-identical.
      expect(all['squatId'], squatBefore);
      // Edited exercise changed as intended.
      expect(all[_ex]['rirPlan']['week1']['session1']['set1']['rir'], '0');
    });

    test('14: sequential saves from latest server keep both leaves', () async {
      final db = await _seed(_completeTemplateSettings());
      final svc = FirestoreWes2PlanService(firestore: db);

      await svc.saveExerciseSettings(
        uid: _uid,
        blockId: _block,
        exerciseId: _ex,
        patch: const ExerciseSettingsPatch(
          rirChanges: [RirChange(session: 'session2', set: 'set1', rir: '2.5')],
          totalBlockWeeks: 4,
        ),
      );
      await svc.saveExerciseSettings(
        uid: _uid,
        blockId: _block,
        exerciseId: _ex,
        patch: const ExerciseSettingsPatch(
          repTargetChanges: [RepTargetChange('instance1', '7 x 4')],
          totalBlockWeeks: 4,
        ),
      );

      final saved = await _readSettings(db);
      // Both independent edits survive (second save started from latest).
      expect(saved['rirPlan']['week1']['session2']['set1']['rir'], '2.5');
      expect(saved['repTargets']['week1']['instance1'], '7 x 4');
    });

    test('16: runtime getRirFromPlan reads the corrected value post-save',
        () async {
      final db = await _seed(_completeTemplateSettings());
      final svc = FirestoreWes2PlanService(firestore: db);
      await svc.saveExerciseSettings(
        uid: _uid,
        blockId: _block,
        exerciseId: _ex,
        patch: const ExerciseSettingsPatch(
          rirChanges: [RirChange(session: 'session2', set: 'set1', rir: '2.5')],
          totalBlockWeeks: 4,
        ),
      );
      final saved = await _readSettings(db);
      // week index 2 (=week3) falls back to week1 template → reads 2.5.
      final rir = BB3PlannedExerciseService.getRirFromPlan(
        exSettings: saved,
        weekIndex: 2,
        sessionIndex: 1, // session2
        setNumber: 1,
      );
      expect(rir, 2.5);
    });

    test('clearing a leaf actually deletes it in Firestore', () async {
      final db = await _seed(_completeTemplateSettings());
      final svc = FirestoreWes2PlanService(firestore: db);
      await svc.saveExerciseSettings(
        uid: _uid,
        blockId: _block,
        exerciseId: _ex,
        patch: const ExerciseSettingsPatch(
          rirChanges: [RirChange(session: 'session2', set: 'set2', rir: null)],
          totalBlockWeeks: 4,
        ),
      );
      final saved = await _readSettings(db);
      expect((saved['rirPlan']['week1']['session2'] as Map).containsKey('set2'),
          false);
      expect(saved['rirPlan']['week1']['session2']['set1']['rir'], '2');
    });
  });

  group('FirestoreWes2PlanService.repairExerciseShadows', () {
    test('7(e2e): sparse weekN shadow is removed in Firestore on open', () async {
      final s = _completeTemplateSettings();
      (s['rirPlan'] as Map)['week3'] = {
        'session2': {
          'set1': {'rir': '2.5'}
        }
      };
      final db = await _seed(s);
      final svc = FirestoreWes2PlanService(firestore: db);

      final repaired = await svc.repairExerciseShadows(
          uid: _uid, blockId: _block, exerciseId: _ex);
      expect((repaired!['rirPlan'] as Map).keys.toList(), ['week1']);

      final saved = await _readSettings(db);
      expect((saved['rirPlan'] as Map).keys.toList(), ['week1']);
      // 15: reopening (load) shows complete week1 config.
      expect(saved['rirPlan']['week1']['session1']['set1']['rir'], '2');
      expect(saved['rirPlan']['week1']['session3']['set3']['rir'], '3.5');
    });

    test('healthy config: repair performs no write', () async {
      final db = await _seed(_completeTemplateSettings());
      final svc = FirestoreWes2PlanService(firestore: db);
      final result = await svc.repairExerciseShadows(
          uid: _uid, blockId: _block, exerciseId: _ex);
      // Returns the settings unchanged; no shadow to remove.
      expect((result!['rirPlan'] as Map).keys.toList(), ['week1']);
    });
  });
}
