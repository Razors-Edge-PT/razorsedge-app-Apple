// Regression coverage for the WES2 settings cog "custom settings revert to
// exercise defaults" bug.
//
// Reproduction: changing weeklyFrequency 4 → 3 in the cog left a stale
// `repTargets.week1.instance4` behind (the dirty-leaf patch had no controller
// left to emit a deletion for it). The resulting object failed
// `isSettingsUsable` (wf=3 vs 4 instances), which triggered the lazy default
// healer, which then force-restored the exercise-library weeklyFrequency /
// repTargets / rirPlan — so the user's custom frequency and rep targets
// reverted while the periodization model survived.
//
// The invariant these tests lock in: a user-selected block setting always
// outranks the exercise-library default, and SAVE itself writes a structurally
// self-consistent object rather than relying on a later healer.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_plan_service.dart';
import 'package:localtest222/block_exercise_defaults_repository.dart';
import 'package:localtest222/settings_merge.dart';
import 'package:localtest222/wes2_exercise_settings_patch.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Fixtures
// ─────────────────────────────────────────────────────────────────────────────

/// The exact production starting state for Bench Press, Barbell:
/// weeklyFrequency 4, DUP By Exposure, rep targets 9 / 5 / 12 / 3.
Map<String, dynamic> _benchAsShipped() => {
      'periodizationModel': 'DUP, By Exposure',
      'rirModel': 'Static RIR',
      'progressionModel': 'Smart Progression',
      'weeklyFrequency': 4,
      'defaultSets': 3,
      'increments': {'primary': 2.5, 'secondary': 1.25},
      'notes': 'keep me',
      'someUnknownFutureKey': {
        'nested': [1, 2, 3]
      },
      'repTargets': {
        'week1': {
          'instance1': '9 x 3',
          'instance2': '5 x 3',
          'instance3': '12 x 3',
          'instance4': '3 x 3',
        },
      },
      'rirPlan': {
        'week1': {
          'session1': {
            'set1': {'rir': '2', 'reps': '9'},
            'set2': {'rir': '2'},
            'set3': {'rir': '2.5'},
          },
          'session2': {
            'set1': {'rir': '2', 'reps': '5'},
            'set2': {'rir': '2'},
            'set3': {'rir': '2.5'},
          },
          'session3': {
            'set1': {'rir': '1.5', 'reps': '12'},
            'set2': {'rir': '2'},
            'set3': {'rir': '2.5'},
          },
          'session4': {
            'set1': {'rir': '2', 'reps': '3'},
            'set2': {'rir': '2'},
            'set3': {'rir': '3'},
          },
        },
      },
    };

Map<String, dynamic> _week1RepTargets(Map<String, dynamic> settings) =>
    Map<String, dynamic>.from(
        (settings['repTargets'] as Map)['week1'] as Map);

Map<String, dynamic> _week1RirPlan(Map<String, dynamic> settings) =>
    Map<String, dynamic>.from((settings['rirPlan'] as Map)['week1'] as Map);

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // TEST A — exact production reproduction
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST A — production reproduction (Bench Press 4 → 3, model change)',
      () {
    /// One single save: DUP By Exposure → DUP By Week, wf 4 → 3, rep targets
    /// rewritten to 5 / 9 / 1.
    Map<String, dynamic> saveOnce() {
      final patch = ExerciseSettingsPatch(
        scalarChanges: const {
          'periodizationModel': 'DUP, By Week',
          'weeklyFrequency': 3,
        },
        repTargetChanges: const [
          RepTargetChange('instance1', '5 x 3'),
          RepTargetChange('instance2', '9 x 3'),
          RepTargetChange('instance3', '1 x 3'),
        ],
        totalBlockWeeks: 4,
      );
      return SettingsMerge.applyPatch(_benchAsShipped(), patch);
    }

    test('model, frequency and rep targets all persist', () {
      final out = saveOnce();
      expect(out['periodizationModel'], 'DUP, By Week');
      expect(out['weeklyFrequency'], 3);

      final week1 = _week1RepTargets(out);
      expect(week1['instance1'], '5 x 3');
      expect(week1['instance2'], '9 x 3');
      expect(week1['instance3'], '1 x 3');
    });

    test('the stale instance4 is gone', () {
      final week1 = _week1RepTargets(saveOnce());
      expect(week1.containsKey('instance4'), isFalse);
      expect(
        week1.keys.where((k) => k.startsWith('instance')).length,
        3,
      );
    });

    test('the obsolete repeating RIR session4 is gone', () {
      final rir = _week1RirPlan(saveOnce());
      expect(rir.containsKey('session4'), isFalse);
      expect(rir.containsKey('session1'), isTrue);
      expect(rir.containsKey('session2'), isTrue);
      expect(rir.containsKey('session3'), isTrue);
    });

    test('the saved object is immediately usable — no healer needed', () {
      expect(
        BlockExerciseDefaultsRepository.isSettingsUsable(saveOnce()),
        isTrue,
        reason:
            'SAVE must write a self-consistent object; validity must not depend '
            'on a later healing pass.',
      );
    });

    test('re-reading / reopening yields the same values (idempotent)', () {
      final first = saveOnce();
      // Reopening the cog and saving with nothing changed is an empty patch.
      final second = SettingsMerge.applyPatch(
        first,
        const ExerciseSettingsPatch(totalBlockWeeks: 4),
      );
      expect(second['weeklyFrequency'], 3);
      expect(second['periodizationModel'], 'DUP, By Week');
      expect(_week1RepTargets(second), _week1RepTargets(first));
      expect(_week1RirPlan(second), _week1RirPlan(first));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST B — the healer no longer restores exercise-library defaults
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST B — custom frequency is not treated as corruption', () {
    // Bench Press factory default is weeklyFrequency 4.
    final benchDefaults = BlockExerciseDefaultsRepository.getDefaultSettings(
      'Bench Press, Barbell',
      'Horizontal Press',
      'Chest',
    );

    /// A valid, deliberate 3/week Bench Press configuration.
    Map<String, dynamic> customBench() => {
          'periodizationModel': 'DUP, By Week',
          'rirModel': 'Static RIR',
          'progressionModel': 'Smart Progression',
          'weeklyFrequency': 3,
          'defaultSets': 3,
          'increments': {'primary': 2.5},
          'repTargets': {
            'week1': {
              'instance1': '5 x 3',
              'instance2': '9 x 3',
              'instance3': '1 x 3',
            },
          },
        };

    test('the factory default really is 4 (fixture guard)', () {
      expect(benchDefaults['weeklyFrequency'], 4);
    });

    test('a 3/week Bench Press config is considered usable', () {
      expect(
        BlockExerciseDefaultsRepository.isSettingsUsable(customBench()),
        isTrue,
      );
    });

    test('healing does NOT push weeklyFrequency back to 4', () {
      final healed = BlockExerciseDefaultsRepository.projectHealedSettings(
        customBench(),
        benchDefaults,
      );
      expect(healed['weeklyFrequency'], 3);
    });

    test('healing does NOT restore the 9 / 5 / 12 / 3 default rep targets', () {
      final healed = BlockExerciseDefaultsRepository.projectHealedSettings(
        customBench(),
        benchDefaults,
      );
      final week1 = _week1RepTargets(healed);
      expect(week1['instance1'], '5 x 3');
      expect(week1['instance2'], '9 x 3');
      expect(week1['instance3'], '1 x 3');
      expect(week1.containsKey('instance4'), isFalse);
    });

    test('healing still fills a genuinely missing core field', () {
      final incomplete = customBench()..remove('progressionModel');
      final healed = BlockExerciseDefaultsRepository.projectHealedSettings(
        incomplete,
        benchDefaults,
      );
      // The absent field is seeded …
      expect(healed['progressionModel'], 'Smart Progression');
      // … while the custom configuration is left completely alone.
      expect(healed['weeklyFrequency'], 3);
      expect(_week1RepTargets(healed)['instance1'], '5 x 3');
    });

    test('healing repairs a genuinely malformed structure to the CUSTOM '
        'frequency, not the factory one', () {
      // The exact corruption the old save produced: wf=3 with a stale
      // instance4 left behind.
      final corrupt = customBench();
      (corrupt['repTargets'] as Map)['week1']['instance4'] = '3 x 3';
      expect(
        BlockExerciseDefaultsRepository.isSettingsUsable(corrupt),
        isFalse,
        reason: 'wf=3 with 4 instances is genuinely inconsistent',
      );

      final healed = BlockExerciseDefaultsRepository.projectHealedSettings(
        corrupt,
        benchDefaults,
      );
      expect(healed['weeklyFrequency'], 3, reason: 'never reset to 4');
      expect(_week1RepTargets(healed).containsKey('instance4'), isFalse);
      expect(
        BlockExerciseDefaultsRepository.isSettingsUsable(healed),
        isTrue,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST C — frequency reduction 5 → 2
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST C — frequency reduction 5 → 2 prunes obsolete slots', () {
    Map<String, dynamic> fiveSessionSettings() => {
          'periodizationModel': 'DUP, By Week',
          'rirModel': 'Static RIR',
          'weeklyFrequency': 5,
          'defaultSets': 3,
          'repTargets': {
            'week1': {
              'instance1': '9 x 3',
              'instance2': '5 x 3',
              'instance3': '12 x 3',
              'instance4': '3 x 3',
              'instance5': '7 x 3',
            },
          },
          'rirPlan': {
            'week1': {
              for (int i = 1; i <= 5; i++)
                'session$i': {
                  'set1': {'rir': '2', 'reps': '9'},
                  'set2': {'rir': '2'},
                },
            },
          },
        };

    Map<String, dynamic> reduced() => SettingsMerge.applyPatch(
          fiveSessionSettings(),
          const ExerciseSettingsPatch(
            scalarChanges: {'weeklyFrequency': 2},
            totalBlockWeeks: 4,
          ),
        );

    test('instance3, instance4 and instance5 are pruned', () {
      final week1 = _week1RepTargets(reduced());
      expect(week1.keys.toSet(), {'instance1', 'instance2'});
      expect(week1['instance1'], '9 x 3');
      expect(week1['instance2'], '5 x 3');
    });

    test('the obsolete repeating RIR sessions 3-5 are pruned', () {
      final rir = _week1RirPlan(reduced());
      expect(rir.keys.toSet(), {'session1', 'session2'});
    });

    test('surviving RIR sets and their reps siblings are untouched', () {
      final rir = _week1RirPlan(reduced());
      expect((rir['session1'] as Map)['set1'], {'rir': '2', 'reps': '9'});
      expect((rir['session2'] as Map)['set2'], {'rir': '2'});
    });

    test('the result is usable', () {
      expect(BlockExerciseDefaultsRepository.isSettingsUsable(reduced()),
          isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST D — frequency increase 2 → 4
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST D — frequency increase 2 → 4 creates safe new slots', () {
    Map<String, dynamic> twoSessionSettings() => {
          'periodizationModel': 'DUP, By Week',
          'rirModel': 'Static RIR',
          'weeklyFrequency': 2,
          'defaultSets': 3,
          'repTargets': {
            'week1': {
              'instance1': '5 x 3',
              'instance2': '9 x 3',
            },
          },
          'rirPlan': {
            'week1': {
              'session1': {
                'set1': {'rir': '2', 'reps': '5'}
              },
              'session2': {
                'set1': {'rir': '2', 'reps': '9'}
              },
            },
          },
        };

    Map<String, dynamic> increased() => SettingsMerge.applyPatch(
          twoSessionSettings(),
          const ExerciseSettingsPatch(
            scalarChanges: {'weeklyFrequency': 4},
            totalBlockWeeks: 4,
          ),
        );

    test('the existing first two sessions are unchanged', () {
      final week1 = _week1RepTargets(increased());
      expect(week1['instance1'], '5 x 3');
      expect(week1['instance2'], '9 x 3');
    });

    test('new slots are created (never left blank or holed)', () {
      final week1 = _week1RepTargets(increased());
      expect(week1.keys.where((k) => k.startsWith('instance')).length, 4);
      expect(week1['instance3'], isNotNull);
      expect(week1['instance4'], isNotNull);
      expect((week1['instance3'] as String).isNotEmpty, isTrue);
      expect((week1['instance4'] as String).isNotEmpty, isTrue);
    });

    test('new slots cycle the existing configured pattern', () {
      final week1 = _week1RepTargets(increased());
      expect(week1['instance3'], '5 x 3'); // cycles back to instance1
      expect(week1['instance4'], '9 x 3'); // cycles back to instance2
    });

    test('existing RIR sessions survive and none are fabricated here', () {
      // New RIR sessions are materialised by the default-matrix healer
      // (healWeek1RirPlan) so the app keeps a single source of that shape.
      final rir = _week1RirPlan(increased());
      expect((rir['session1'] as Map)['set1'], {'rir': '2', 'reps': '5'});
      expect((rir['session2'] as Map)['set1'], {'rir': '2', 'reps': '9'});
    });

    test('the result is immediately usable', () {
      expect(BlockExerciseDefaultsRepository.isSettingsUsable(increased()),
          isTrue);
    });

    test('the default RIR healer then fills the new sessions', () {
      final healed =
          BlockExerciseDefaultsRepository.healWeek1RirPlan(increased());
      expect(healed, isNotNull);
      final week1 = Map<String, dynamic>.from(healed!['week1'] as Map);
      expect(week1.containsKey('session3'), isTrue);
      expect(week1.containsKey('session4'), isTrue);
      // Pre-existing values are never overwritten.
      expect((week1['session1'] as Map)['set1'], {'rir': '2', 'reps': '5'});
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST E — same frequency, rep edits only
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST E — ordinary rep-target edits are unaffected', () {
    test('a rep edit with no frequency change touches nothing else', () {
      final base = _benchAsShipped();
      final out = SettingsMerge.applyPatch(
        base,
        const ExerciseSettingsPatch(
          repTargetChanges: [RepTargetChange('instance2', '6 x 3')],
          totalBlockWeeks: 4,
        ),
      );

      expect(out['weeklyFrequency'], 4);
      final week1 = _week1RepTargets(out);
      expect(week1['instance1'], '9 x 3');
      expect(week1['instance2'], '6 x 3');
      expect(week1['instance3'], '12 x 3');
      expect(week1['instance4'], '3 x 3', reason: 'not a structural change');
      // The RIR plan is completely untouched.
      expect(_week1RirPlan(out), _week1RirPlan(base));
    });

    test('an explicit no-op frequency scalar still normalises harmlessly', () {
      final base = _benchAsShipped();
      final out = SettingsMerge.applyPatch(
        base,
        const ExerciseSettingsPatch(
          scalarChanges: {'weeklyFrequency': 4},
          totalBlockWeeks: 4,
        ),
      );
      expect(_week1RepTargets(out), _week1RepTargets(base));
      expect(_week1RirPlan(out), _week1RirPlan(base));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST F — periodization model + frequency change in the same save
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST F — the NEW model drives structural propagation', () {
    test('switching to DUP Signature skips instance resizing entirely', () {
      // Signature uses repRange, not instanceN — resizing must not touch it.
      final out = SettingsMerge.applyPatch(
        _benchAsShipped(),
        const ExerciseSettingsPatch(
          scalarChanges: {
            'periodizationModel': 'DUP, Signature',
            'weeklyFrequency': 2,
          },
          repTargetChanges: [
            RepTargetChange('min', '5'),
            RepTargetChange('max', '10'),
          ],
          totalBlockWeeks: 4,
        ),
      );

      expect(out['periodizationModel'], 'DUP, Signature');
      expect(out['weeklyFrequency'], 2);
      expect((out['repTargets'] as Map)['repRange'], {'min': 5, 'max': 10});
      // instanceN keys are left exactly as they were — Signature does not use
      // them, so pruning them would destroy data the user may return to.
      final week1 = _week1RepTargets(out);
      expect(week1.keys.where((k) => k.startsWith('instance')).length, 4);
      // But the RIR sessions, which ARE tied to weekly frequency, are resized.
      expect(_week1RirPlan(out).keys.toSet(), {'session1', 'session2'});
    });

    test('switching Linear → DUP By Week resizes under the new model', () {
      final linear = {
        'periodizationModel': 'Linear, Classic',
        'rirModel': 'Static RIR',
        'weeklyFrequency': 4,
        'repTargets': {
          'week1': {
            'instance1': '15 x 3',
            'instance2': '20 x 3',
            'instance3': '16 x 3',
            'instance4': '18 x 3',
          },
          'week2': {
            'instance1': '14 x 3',
            'instance2': '19 x 3',
            'instance3': '15 x 3',
            'instance4': '17 x 3',
          },
        },
      };

      final out = SettingsMerge.applyPatch(
        linear,
        const ExerciseSettingsPatch(
          scalarChanges: {
            'periodizationModel': 'DUP, By Week',
            'weeklyFrequency': 2,
          },
          totalBlockWeeks: 4,
        ),
      );

      expect(out['periodizationModel'], 'DUP, By Week');
      // Every week map is resized — instance slots are frequency-bound in both
      // template and per-week models.
      expect(_week1RepTargets(out).keys.toSet(), {'instance1', 'instance2'});
      final week2 =
          Map<String, dynamic>.from((out['repTargets'] as Map)['week2'] as Map);
      expect(week2.keys.toSet(), {'instance1', 'instance2'});
      expect(week2['instance1'], '14 x 3', reason: 'values preserved');
      expect(BlockExerciseDefaultsRepository.isSettingsUsable(out), isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST G — unrelated settings survive a structural save
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST G — unrelated settings are preserved', () {
    test('increments, progression model, notes and unknown keys all survive',
        () {
      final out = SettingsMerge.applyPatch(
        _benchAsShipped(),
        const ExerciseSettingsPatch(
          scalarChanges: {'weeklyFrequency': 3},
          incrementChanges: {'primary': 5.0},
          totalBlockWeeks: 4,
        ),
      );

      expect(out['progressionModel'], 'Smart Progression');
      expect(out['rirModel'], 'Static RIR');
      expect(out['defaultSets'], 3);
      expect(out['notes'], 'keep me');
      expect(out['someUnknownFutureKey'], {
        'nested': [1, 2, 3]
      });
      // Changed increment applied, untouched sibling preserved.
      expect((out['increments'] as Map)['primary'], 5.0);
      expect((out['increments'] as Map)['secondary'], 1.25);
    });

    test('unknown week/instance-shaped siblings are not pruned', () {
      final withOddKeys = _benchAsShipped();
      (withOddKeys['repTargets'] as Map)['week1']['instanceNotes'] = 'freeform';
      (withOddKeys['repTargets'] as Map)['metadata'] = {'source': 'import'};

      final out = SettingsMerge.applyPatch(
        withOddKeys,
        const ExerciseSettingsPatch(
          scalarChanges: {'weeklyFrequency': 3},
          totalBlockWeeks: 4,
        ),
      );

      final week1 = _week1RepTargets(out);
      expect(week1['instanceNotes'], 'freeform',
          reason: 'not a numbered slot → never touched');
      expect(week1.containsKey('instance4'), isFalse);
      expect((out['repTargets'] as Map)['metadata'], {'source': 'import'});
    });

    test('sibling exercises are irrelevant — the merge is per-exercise', () {
      // applyPatch operates on exerciseSettings[exerciseId] only; identity is
      // uid + blockId + exerciseId at the call site. Guard the shape here.
      final out = SettingsMerge.applyPatch(
        _benchAsShipped(),
        const ExerciseSettingsPatch(
          scalarChanges: {'weeklyFrequency': 3},
          totalBlockWeeks: 4,
        ),
      );
      expect(out.containsKey('exerciseSettings'), isFalse);
      expect(out.containsKey('plannedExerciseDetails'), isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST H — not special-cased to Bench Press
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST H — no factory-default overwrite for other exercises', () {
    test('Deadlift, Conventional (default 4/week) keeps a custom 2/week', () {
      final defaults = BlockExerciseDefaultsRepository.getDefaultSettings(
        'Deadlift, Conventional',
        'Hip Hinge',
        'Back',
      );
      expect(defaults['weeklyFrequency'], 4, reason: 'fixture guard');

      final custom = {
        'periodizationModel': 'DUP, By Exposure',
        'rirModel': 'Static RIR',
        'weeklyFrequency': 2,
        'defaultSets': 4,
        'repTargets': {
          'week1': {'instance1': '2 x 4', 'instance2': '6 x 4'},
        },
      };

      final healed = BlockExerciseDefaultsRepository.projectHealedSettings(
        custom,
        defaults,
      );
      expect(healed['weeklyFrequency'], 2);
      expect(_week1RepTargets(healed).keys.toSet(),
          {'instance1', 'instance2'});
      expect(_week1RepTargets(healed)['instance1'], '2 x 4');
      expect(BlockExerciseDefaultsRepository.isSettingsUsable(healed), isTrue);
    });

    test('Back Squat, Barbell (default 2/week) keeps a custom 4/week', () {
      final defaults = BlockExerciseDefaultsRepository.getDefaultSettings(
        'Back Squat, Barbell',
        'Squat Pattern',
        'Legs',
      );
      expect(defaults['weeklyFrequency'], 2, reason: 'fixture guard');

      final custom = {
        'periodizationModel': 'DUP, By Week',
        'rirModel': 'Static RIR',
        'weeklyFrequency': 4,
        'defaultSets': 3,
        'repTargets': {
          'week1': {
            'instance1': '8 x 3',
            'instance2': '3 x 3',
            'instance3': '10 x 3',
            'instance4': '5 x 3',
          },
        },
      };

      final healed = BlockExerciseDefaultsRepository.projectHealedSettings(
        custom,
        defaults,
      );
      expect(healed['weeklyFrequency'], 4);
      expect(_week1RepTargets(healed).length, 4);
      expect(_week1RepTargets(healed)['instance3'], '10 x 3');
      expect(BlockExerciseDefaultsRepository.isSettingsUsable(healed), isTrue);
    });

    test('an isolation-tier exercise keeps its custom frequency too', () {
      final defaults = BlockExerciseDefaultsRepository.getDefaultSettings(
        'Some Custom Curl',
        'Other',
        'Biceps',
      );
      expect(defaults['weeklyFrequency'], 4, reason: 'isolation tier default');

      final custom = {
        'periodizationModel': 'DUP, By Exposure',
        'rirModel': 'Static RIR',
        'weeklyFrequency': 1,
        'repTargets': {
          'week1': {'instance1': '12 x 3'},
        },
      };

      final healed = BlockExerciseDefaultsRepository.projectHealedSettings(
        custom,
        defaults,
      );
      expect(healed['weeklyFrequency'], 1);
      expect(_week1RepTargets(healed).keys.toSet(), {'instance1'});
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Validation contract
  // ───────────────────────────────────────────────────────────────────────────
  group('isSettingsUsable — structure vs frequency, not frequency vs default',
      () {
    Map<String, dynamic> withFrequency(int wf, int instances) => {
          'periodizationModel': 'DUP, By Week',
          'weeklyFrequency': wf,
          'repTargets': {
            'week1': {
              for (int i = 1; i <= instances; i++) 'instance$i': '5 x 3',
            },
          },
        };

    test('agreement is valid at every frequency', () {
      for (int wf = 1; wf <= 6; wf++) {
        expect(
          BlockExerciseDefaultsRepository.isSettingsUsable(
              withFrequency(wf, wf)),
          isTrue,
          reason: 'wf=$wf with $wf instances must be valid',
        );
      }
    });

    test('disagreement is invalid', () {
      expect(
        BlockExerciseDefaultsRepository.isSettingsUsable(withFrequency(3, 4)),
        isFalse,
      );
      expect(
        BlockExerciseDefaultsRepository.isSettingsUsable(withFrequency(4, 2)),
        isFalse,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // End-to-end: the transactional save actually PERSISTS the resized object,
  // and a reload (what WES2 and the reopened cog both do) reads it back.
  // ───────────────────────────────────────────────────────────────────────────
  group('end-to-end save + reload (uid + blockId + exerciseId)', () {
    const uid = 'u1';
    const blockId = 'b1';
    const exerciseId = 'benchId';

    Future<FakeFirebaseFirestore> seed() async {
      final db = FakeFirebaseFirestore();
      await db
          .collection('users')
          .doc(uid)
          .collection('planned_blocks')
          .doc(blockId)
          .set({
        'exerciseSettings': {
          exerciseId: _benchAsShipped(),
          // A sibling exercise that must never be touched.
          'squatId': {
            'periodizationModel': 'DUP, By Week',
            'weeklyFrequency': 4,
            'repTargets': {
              'week1': {
                'instance1': '8 x 3',
                'instance2': '3 x 3',
                'instance3': '10 x 3',
                'instance4': '5 x 3',
              },
            },
          },
        },
        // Another top-level field that must survive the write untouched.
        'plannedExerciseDetails': {
          exerciseId: {'legacy': 'DO_NOT_TOUCH'}
        },
      });
      return db;
    }

    test('the production save persists frequency 3 and 5 / 9 / 1', () async {
      final db = await seed();
      final svc = FirestoreWes2PlanService(firestore: db);

      await svc.saveExerciseSettings(
        uid: uid,
        blockId: blockId,
        exerciseId: exerciseId,
        patch: const ExerciseSettingsPatch(
          scalarChanges: {
            'periodizationModel': 'DUP, By Week',
            'weeklyFrequency': 3,
          },
          repTargetChanges: [
            RepTargetChange('instance1', '5 x 3'),
            RepTargetChange('instance2', '9 x 3'),
            RepTargetChange('instance3', '1 x 3'),
          ],
          totalBlockWeeks: 4,
        ),
      );

      // What WES2 reloads after Save, and what the reopened cog reads.
      final reloaded = await svc.loadExerciseSettings(uid: uid, blockId: blockId);
      final bench = Map<String, dynamic>.from(reloaded[exerciseId] as Map);

      expect(bench['periodizationModel'], 'DUP, By Week');
      expect(bench['weeklyFrequency'], 3);

      final week1 = _week1RepTargets(bench);
      expect(week1['instance1'], '5 x 3');
      expect(week1['instance2'], '9 x 3');
      expect(week1['instance3'], '1 x 3');
      expect(week1.containsKey('instance4'), isFalse,
          reason: 'the stale slot must be gone from Firestore, not just memory');

      expect(_week1RirPlan(bench).containsKey('session4'), isFalse);
      expect(BlockExerciseDefaultsRepository.isSettingsUsable(bench), isTrue);
    });

    test('the first weekly rep hint source changes from 9 to 5', () async {
      final db = await seed();
      final svc = FirestoreWes2PlanService(firestore: db);

      final before = await svc.loadExerciseSettings(uid: uid, blockId: blockId);
      expect(
        _week1RepTargets(Map<String, dynamic>.from(before[exerciseId] as Map))[
            'instance1'],
        '9 x 3',
      );

      await svc.saveExerciseSettings(
        uid: uid,
        blockId: blockId,
        exerciseId: exerciseId,
        patch: const ExerciseSettingsPatch(
          scalarChanges: {
            'periodizationModel': 'DUP, By Week',
            'weeklyFrequency': 3,
          },
          repTargetChanges: [
            RepTargetChange('instance1', '5 x 3'),
            RepTargetChange('instance2', '9 x 3'),
            RepTargetChange('instance3', '1 x 3'),
          ],
          totalBlockWeeks: 4,
        ),
      );

      final after = await svc.loadExerciseSettings(uid: uid, blockId: blockId);
      expect(
        _week1RepTargets(Map<String, dynamic>.from(after[exerciseId] as Map))[
            'instance1'],
        '5 x 3',
        reason: 'WES2 reloads this immediately after Save — no restart needed',
      );
    });

    // NOTE: production writes with set(SetOptions(mergeFields:
    // ['exerciseSettings'])), which in REAL Firestore leaves every other
    // top-level field untouched. fake_cloud_firestore does not model that, so
    // this asserts the property the fake CAN model: other exercises inside the
    // written field are preserved and only the edited exercise changes.
    test('no other exercise is affected', () async {
      final db = await seed();
      final svc = FirestoreWes2PlanService(firestore: db);

      await svc.saveExerciseSettings(
        uid: uid,
        blockId: blockId,
        exerciseId: exerciseId,
        patch: const ExerciseSettingsPatch(
          scalarChanges: {'weeklyFrequency': 3},
          totalBlockWeeks: 4,
        ),
      );

      final snap = await db
          .collection('users')
          .doc(uid)
          .collection('planned_blocks')
          .doc(blockId)
          .get();
      final data = snap.data()!;

      final squat = Map<String, dynamic>.from(
          (data['exerciseSettings'] as Map)['squatId'] as Map);
      expect(squat['weeklyFrequency'], 4);
      expect(_week1RepTargets(squat).length, 4,
          reason: 'a sibling exercise must keep its own 4 instances');
    });
  });
}
