import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_exercise_defaults_repository.dart';
import 'package:localtest222/block_planner_2/bp2_repository.dart';
import 'package:localtest222/block_planner_2/bp2_settings_resolver.dart';
import 'package:localtest222/exercise_model_registry.dart';

/// Canonical Bench defaults straight from the tiered default system.
Map<String, dynamic> benchDefaults() =>
    BlockExerciseDefaultsRepository.defaultSettingsPayload(
      name: 'Bench Press, Barbell',
      category: 'Horizontal Press',
      bodyPart: 'Chest',
    );

Map<String, dynamic> persistedCustom() => {
      'periodizationModel': 'DUP, By Week',
      'rirModel': 'Static RIR',
      'progressionModel': 'Add Reps',
      'weeklyFrequency': 2,
      'defaultSets': 4,
      'increments': {'primary': 1.25},
      'someUnknownKey': {'keep': true},
      'repTargets': {
        'week1': {'instance1': '8 x 4', 'instance2': '12 x 2'},
      },
      'rirPlan': {
        'week1': {
          'session1': {
            'set1': {'rir': '1', 'reps': '8'},
            'set2': {'rir': '1.5'},
            'set3': {'rir': '2'},
            'set4': {'rir': '2.5'},
          },
          'session2': {
            'set1': {'rir': '3', 'reps': '12'},
            'set2': {'rir': '3'},
          },
        },
      },
    };

void main() {
  const ex = 'AmfUWbF1DH3I7qPAdh5k'; // Bench Press, Barbell (velocity default)

  group('defaults precedence', () {
    test('canonical defaults show when no custom override exists', () {
      final base = Bp2SettingsResolver.canonicalBase(null, benchDefaults());
      final r = Bp2SettingsResolver.resolve(
        exerciseId: ex,
        base: base,
        draft: Bp2ExerciseDraft.empty,
        totalBlockWeeks: 4,
      );
      expect(r.periodizationModel, ExerciseModelRegistry.dupByExposure);
      expect(r.rirModel, ExerciseModelRegistry.staticRir);
      expect(r.progressionModel, ExerciseModelRegistry.smartProgression);
      expect(r.weeklyFrequency, 4);
      expect(r.incrementPrimary, '2.5');
      expect(r.showVelocity, isTrue); // velocity default for this id
      expect(r.sessions.map((s) => s.reps), [9, 5, 12, 3]);
      expect(r.sessions.map((s) => s.sets), [3, 3, 3, 3]);
      // First set RIR from rirTargets, later sets from the canonical matrix.
      expect(r.sessions[0].rir, ['2', '2', '2.5']);
      expect(r.sessions[2].rir, ['1.5', '2', '2.5']);
    });

    test('persisted custom values beat defaults; unsaved entry beats both', () {
      final base =
          Bp2SettingsResolver.canonicalBase(persistedCustom(), benchDefaults());
      final r = Bp2SettingsResolver.resolve(
        exerciseId: ex,
        base: base,
        draft: const Bp2ExerciseDraft({Bp2Field.incrementPrimary: '5'}),
        totalBlockWeeks: 4,
      );
      expect(r.periodizationModel, 'DUP, By Week');
      expect(r.progressionModel, 'Add Reps');
      expect(r.weeklyFrequency, 2);
      expect(r.incrementPrimary, '5'); // unsaved entry wins
      expect(r.sessions[0].reps, 8);
      expect(r.sessions[0].sets, 4);
      expect(r.sessions[0].rir, ['1', '1.5', '2', '2.5']);
      expect(r.sessions[1].sets, 2);
      expect(r.sessions[1].rir, ['3', '3']);
      // Persisted object is complete: not re-seeded from defaults.
      expect(base['increments'], {'primary': 1.25});
      expect(base['someUnknownKey'], {'keep': true});
    });

    test(
        'an incomplete persisted fragment is healed over defaults, custom kept',
        () {
      final base = Bp2SettingsResolver.canonicalBase(
        {
          'increments': {'primary': 10}
        },
        benchDefaults(),
      );
      expect(base['increments'], {'primary': 10});
      expect(base['periodizationModel'], ExerciseModelRegistry.dupByExposure);
      expect(BlockExerciseDefaultsRepository.isSettingsUsable(base), isTrue);
    });

    test('opening (resolving) never yields a dirty patch', () {
      final base = Bp2SettingsResolver.canonicalBase(null, benchDefaults());
      final patch = Bp2SettingsResolver.buildPatch(
          base: base, draft: Bp2ExerciseDraft.empty, totalBlockWeeks: 4);
      expect(patch.isEmpty, isTrue);
    });

    test('editing a field back to its original value produces no patch', () {
      final base =
          Bp2SettingsResolver.canonicalBase(persistedCustom(), benchDefaults());
      final patch = Bp2SettingsResolver.buildPatch(
        base: base,
        draft: const Bp2ExerciseDraft({
          Bp2Field.incrementPrimary: '1.25',
          Bp2Field.weeklyFrequency: '2',
          'rir.session1.set2': '1.5',
        }),
        totalBlockWeeks: 4,
      );
      expect(patch.isEmpty, isTrue);
    });
  });

  group('frequency / model changes', () {
    test('increasing frequency seeds only missing sessions, keeps custom ones',
        () {
      final base =
          Bp2SettingsResolver.canonicalBase(persistedCustom(), benchDefaults());
      final draft = const Bp2ExerciseDraft({Bp2Field.weeklyFrequency: '3'});
      final r = Bp2SettingsResolver.resolve(
          exerciseId: ex, base: base, draft: draft, totalBlockWeeks: 4);
      expect(r.sessions.length, 3);
      // Existing custom sessions untouched.
      expect(r.sessions[0].reps, 8);
      expect(r.sessions[0].sets, 4);
      expect(r.sessions[1].reps, 12);
      expect(r.sessions[1].sets, 2);
      // New session seeded by the canonical cycling rule (instance1 pattern).
      expect(r.sessions[2].reps, 8);
      expect(r.sessions[2].sets, 4);
      // RIR for the new session healed from the canonical matrix, not blank.
      expect(r.sessions[2].rir.length, 4);
      expect(r.sessions[2].rir.every((v) => v.isNotEmpty), isTrue);
      // Only the frequency scalar is in the patch — nothing regenerated.
      final patch = Bp2SettingsResolver.buildPatch(
          base: base, draft: draft, totalBlockWeeks: 4);
      expect(patch.scalarChanges, {'weeklyFrequency': 3});
      expect(patch.repTargetChanges, isEmpty);
      expect(patch.rirChanges, isEmpty);
    });

    test('reducing frequency then restoring it keeps custom session 2', () {
      final base =
          Bp2SettingsResolver.canonicalBase(persistedCustom(), benchDefaults());
      var draft = const Bp2ExerciseDraft({Bp2Field.weeklyFrequency: '1'});
      final r1 = Bp2SettingsResolver.resolve(
          exerciseId: ex, base: base, draft: draft, totalBlockWeeks: 4);
      expect(r1.sessions.length, 1);
      draft = draft.withEdit(Bp2Field.weeklyFrequency, '2');
      final r2 = Bp2SettingsResolver.resolve(
          exerciseId: ex, base: base, draft: draft, totalBlockWeeks: 4);
      expect(r2.sessions[1].reps, 12);
      expect(r2.sessions[1].rir, ['3', '3']);
    });

    test(
        'rep and RIR models are independent; a model change keeps custom targets',
        () {
      final base =
          Bp2SettingsResolver.canonicalBase(persistedCustom(), benchDefaults());
      final draft = const Bp2ExerciseDraft({
        Bp2Field.rirModel: 'Linear-Taper',
        'rir.session1.set1': '0.5',
      });
      final r = Bp2SettingsResolver.resolve(
          exerciseId: ex, base: base, draft: draft, totalBlockWeeks: 4);
      expect(r.periodizationModel, 'DUP, By Week'); // unchanged
      expect(r.rirModel, 'Linear-Taper');
      expect(r.sessions[0].reps, 8);
      expect(r.sessions[0].rir, ['0.5', '1.5', '2', '2.5']);
      final patch = Bp2SettingsResolver.buildPatch(
          base: base, draft: draft, totalBlockWeeks: 4);
      expect(patch.scalarChanges, {'rirModel': 'Linear-Taper'});
      expect(patch.rirChanges.length, 1);
      expect(patch.rirChanges.single.rir, '0.5');
    });

    test('DUP Signature presents min/max + set count, not sessions', () {
      final base =
          Bp2SettingsResolver.canonicalBase(persistedCustom(), benchDefaults());
      final draft = const Bp2ExerciseDraft({
        Bp2Field.periodizationModel: 'DUP, Signature',
        Bp2Field.repMin: '6',
        Bp2Field.repMax: '12',
      });
      final r = Bp2SettingsResolver.resolve(
          exerciseId: ex, base: base, draft: draft, totalBlockWeeks: 4);
      expect(r.repShape, RepTargetShape.repRange);
      expect(r.repMin, 6);
      expect(r.repMax, 12);
      expect(r.sessions.every((s) => s.reps == null), isTrue);
      expect(r.sessions.every((s) => s.sets == 4), isTrue); // defaultSets
      final patch = Bp2SettingsResolver.buildPatch(
          base: base, draft: draft, totalBlockWeeks: 4);
      expect(patch.repTargetChanges.map((c) => '${c.key}=${c.value}'),
          ['min=6', 'max=12']);
      expect(r.projected['repTargets']['repRange'], {'min': 6, 'max': 12});
      // Instance slots from the previous model survive in the stored object.
      expect(r.projected['repTargets']['week1']['instance2'], '12 x 2');
    });
  });

  group('rep and RIR editing', () {
    test('rep rows edit reps and set counts as canonical "R x S" strings', () {
      final base =
          Bp2SettingsResolver.canonicalBase(persistedCustom(), benchDefaults());
      final draft = Bp2ExerciseDraft({
        Bp2Field.repInstance(2): Bp2SettingsResolver.repString(15, 4),
      });
      final r = Bp2SettingsResolver.resolve(
          exerciseId: ex, base: base, draft: draft, totalBlockWeeks: 4);
      expect(r.sessions[1].reps, 15);
      expect(r.sessions[1].sets, 4);
      // Growing the set count reveals healed RIR cells for the new sets.
      expect(r.sessions[1].rir.length, 4);
      expect(r.sessions[1].rir.sublist(0, 2), ['3', '3']);
      final patch = Bp2SettingsResolver.buildPatch(
          base: base, draft: draft, totalBlockWeeks: 4);
      expect(patch.repTargetChanges.single.key, 'instance2');
      expect(patch.repTargetChanges.single.value, '15 x 4');
    });

    test('RIR rows edit each set independently with decimals', () {
      final base =
          Bp2SettingsResolver.canonicalBase(persistedCustom(), benchDefaults());
      final draft = Bp2ExerciseDraft({
        Bp2Field.rir(1, 2): '2.5',
        Bp2Field.rir(1, 4): '0.5',
      });
      final r = Bp2SettingsResolver.resolve(
          exerciseId: ex, base: base, draft: draft, totalBlockWeeks: 4);
      expect(r.sessions[0].rir, ['1', '2.5', '2', '0.5']);
      expect(r.sessions[1].rir, ['3', '3']); // other session untouched
      final patch = Bp2SettingsResolver.buildPatch(
          base: base, draft: draft, totalBlockWeeks: 4);
      expect(patch.rirChanges.length, 2);
      final merged =
          Bp2Repository.mergeForSave(persistedCustom(), patch, benchDefaults());
      final s1 = merged['rirPlan']['week1']['session1'];
      // The canonical healer also back-fills the `reps` sibling on save.
      expect(s1['set2'], {'rir': '2.5', 'reps': '8'});
      expect(s1['set4'], {'rir': '0.5', 'reps': '8'});
      expect(s1['set1'], {'rir': '1', 'reps': '8'}); // sibling preserved
    });

    test('numeric normalisation stores compact numbers, not formatted strings',
        () {
      final base =
          Bp2SettingsResolver.canonicalBase(persistedCustom(), benchDefaults());
      final draft = const Bp2ExerciseDraft({
        Bp2Field.incrementPrimary: '2,50',
        'rir.session1.set1': '2.0',
      });
      final patch = Bp2SettingsResolver.buildPatch(
          base: base, draft: draft, totalBlockWeeks: 4);
      expect(patch.incrementChanges, {'primary': 2.5});
      expect(patch.rirChanges.single.rir, '2');
    });
  });

  group('validation', () {
    test('rejects out-of-range and non-numeric values', () {
      final errors = Bp2SettingsResolver.validate(const Bp2ExerciseDraft({
        Bp2Field.weeklyFrequency: '15',
        Bp2Field.incrementPrimary: 'abc',
        'rep.instance1': '0 x 3',
        'rir.session1.set1': '-1',
        Bp2Field.repMin: '10',
        Bp2Field.repMax: '8',
      }));
      expect(errors.map((e) => e.field).toSet(), {
        Bp2Field.weeklyFrequency,
        Bp2Field.incrementPrimary,
        'rep.instance1',
        'rir.session1.set1',
        Bp2Field.repMax,
      });
    });

    test('accepts every weekday frequency and decimals', () {
      for (var f = 1; f <= 7; f++) {
        expect(
            Bp2SettingsResolver.validate(
                Bp2ExerciseDraft({Bp2Field.weeklyFrequency: '$f'})),
            isEmpty);
      }
      expect(
          Bp2SettingsResolver.validate(const Bp2ExerciseDraft({
            Bp2Field.incrementSecondary: '1.25',
            'rir.session2.set3': '2.5',
          })),
          isEmpty);
    });
  });

  group('mergeForSave (only dirty fields, defaults seeded once)', () {
    test('unrelated keys such as defaultSets survive a one-field patch', () {
      final patch = Bp2SettingsResolver.buildPatch(
        base: Bp2SettingsResolver.canonicalBase(
            persistedCustom(), benchDefaults()),
        draft: const Bp2ExerciseDraft({Bp2Field.progressionModel: 'None'}),
        totalBlockWeeks: 4,
      );
      final merged =
          Bp2Repository.mergeForSave(persistedCustom(), patch, benchDefaults());
      expect(merged['progressionModel'], 'None');
      expect(merged['defaultSets'], 4);
      expect(merged['someUnknownKey'], {'keep': true});
      expect(merged['repTargets'], persistedCustom()['repTargets']);
      expect(merged.containsKey('plannedExerciseDetails'), isFalse);
      expect(merged.containsKey('explicitRepTargets'), isFalse);
    });

    test(
        'an exercise with no settings is seeded from canonical defaults + patch',
        () {
      final patch = Bp2SettingsResolver.buildPatch(
        base: Bp2SettingsResolver.canonicalBase(null, benchDefaults()),
        draft: const Bp2ExerciseDraft({Bp2Field.incrementPrimary: '5'}),
        totalBlockWeeks: 4,
      );
      final merged = Bp2Repository.mergeForSave(null, patch, benchDefaults());
      expect(BlockExerciseDefaultsRepository.isSettingsUsable(merged), isTrue);
      expect(merged['increments'], {'primary': 5.0});
      expect(merged['periodizationModel'], ExerciseModelRegistry.dupByExposure);
      expect(merged['rirPlan']['week1']['session4']['set3'], isNotNull);
    });
  });
}
