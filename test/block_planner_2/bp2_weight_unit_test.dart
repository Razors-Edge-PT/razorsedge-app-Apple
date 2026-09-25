// exerciseSettings[exerciseId].weightUnit, edited from Block Planner 2 and
// from the WES2 settings cog: ONE persisted leaf, kilograms stored underneath.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_plan_service.dart';
import 'package:localtest222/WES2_widgets/WES2_exercise_settings_dialog.dart';
import 'package:localtest222/block_planner_2/bp2_settings_resolver.dart';
import 'package:localtest222/units/exercise_unit_registry.dart';
import 'package:localtest222/units/weight_unit.dart';

import 'bp2_test_support.dart';

void main() {
  const athlete = 'athlete-uid';
  const bench = 'AmfUWbF1DH3I7qPAdh5k';

  setUp(() => ExerciseUnitRegistry.shared = ExerciseUnitRegistry());

  Future<Harness> seeded() async {
    final h = Harness();
    await h.seedShared(bench, 'Bench Press, Barbell');
    await h.seedTemplate(athlete, 't1', 'active1', [
      {'exerciseId': bench, 'name': 'Bench Press, Barbell'}
    ]);
    await h.seedBlock(athlete, 'active1', isActive: true, exerciseSettings: {
      bench: {
        'periodizationModel': 'DUP, By Exposure',
        'rirModel': 'Static RIR',
        'progressionModel': 'Smart Progression',
        'weeklyFrequency': 2,
        'defaultSets': 3,
        'increments': {'primary': 2.5},
        'repTargets': {
          'week1': {'instance1': '8 x 3', 'instance2': '6 x 3'}
        },
      },
    });
    await h.seedUser(athlete, username: 'richard');
    return h;
  }

  Future<Map<String, dynamic>> benchSettings(FakeFirebaseFirestore db) async {
    final snap = await db
        .collection('users')
        .doc(athlete)
        .collection('planned_blocks')
        .doc('active1')
        .get();
    return Map<String, dynamic>.from(
        (snap.data()!['exerciseSettings'] as Map)[bench] as Map);
  }

  group('resolver', () {
    test('missing unit is kg; increments read exactly as before', () {
      final r = Bp2SettingsResolver.resolve(
        exerciseId: bench,
        base: {
          'increments': {'primary': 2.5}
        },
        draft: Bp2ExerciseDraft.empty,
        totalBlockWeeks: 4,
      );
      expect(r.weightUnit, ExerciseWeightUnit.kg);
      expect(r.incrementPrimary, '2.5');
    });

    test(
        'lb shows increments in pounds; an untouched increment is never rewritten',
        () {
      const base = {
        'weightUnit': 'lb',
        'increments': {'primary': 2.5},
      };
      final r = Bp2SettingsResolver.resolve(
        exerciseId: bench,
        base: base,
        draft: Bp2ExerciseDraft.empty,
        totalBlockWeeks: 4,
      );
      expect(r.incrementPrimary, '5.512');
      // Re-submitting the shown text is NOT a change (no drift).
      final same = Bp2SettingsResolver.buildPatch(
        base: base,
        draft: const Bp2ExerciseDraft({Bp2Field.incrementPrimary: '5.512'}),
        totalBlockWeeks: 4,
      );
      expect(same.isEmpty, isTrue);
      // Typing pounds stores canonical kilograms, unrounded.
      final typed = Bp2SettingsResolver.buildPatch(
        base: base,
        draft: const Bp2ExerciseDraft({Bp2Field.incrementPrimary: '5'}),
        totalBlockWeeks: 4,
      );
      expect(typed.incrementChanges['primary'], 5 * kKgPerLb);
    });

    test('choosing a unit writes only the unit leaf', () {
      final p = Bp2SettingsResolver.buildPatch(
        base: {
          'increments': {'primary': 2.5}
        },
        draft: const Bp2ExerciseDraft({Bp2Field.weightUnit: 'lb'}),
        totalBlockWeeks: 4,
      );
      expect(p.scalarChanges, {'weightUnit': 'lb'});
      expect(p.incrementChanges, isEmpty);
      // Re-choosing the unit already in effect (a published fallback) writes
      // nothing.
      final none = Bp2SettingsResolver.buildPatch(
        base: const {},
        draft: const Bp2ExerciseDraft({Bp2Field.weightUnit: 'lb'}),
        totalBlockWeeks: 4,
        fallbackUnit: ExerciseWeightUnit.lb,
      );
      expect(none.isEmpty, isTrue);
    });
  });

  group('Block Planner 2 persists the shared field', () {
    test('changing the unit writes weightUnit and leaves every number alone',
        () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'active1', activeBlockId: 'active1');
      final before = await benchSettings(h.db);
      c.edit(bench, Bp2Field.weightUnit, 'lb');
      expect(c.resolvedFor(bench).weightUnit, ExerciseWeightUnit.lb);
      expect((await c.save()).success, isTrue);
      final after = await benchSettings(h.db);
      expect(after['weightUnit'], 'lb');
      expect(after['increments'], before['increments'],
          reason: 'a unit change never mutates stored numbers');
      expect(ExerciseUnitRegistry.shared.unitsFor(athlete).unitFor(bench),
          ExerciseWeightUnit.lb,
          reason: 'every screen shows the new unit at once');
      c.dispose();
    });

    test('a pending increment is re-expressed when the unit switches',
        () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'active1', activeBlockId: 'active1');
      c.edit(bench, Bp2Field.incrementPrimary, '5'); // typed in kg
      c.edit(bench, Bp2Field.weightUnit, 'lb');
      expect(c.draftFor(bench)[Bp2Field.incrementPrimary], '11.023');
      expect(c.resolvedFor(bench).incrementPrimary, '11.023');
      c.dispose();
    });
  });

  group('the WES2 cog edits the SAME field', () {
    Future<void> pumpDialog(
        WidgetTester tester, FakeFirebaseFirestore db) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Wes2ExerciseSettingsDialog(
            uid: athlete,
            blockId: 'active1',
            exerciseId: bench,
            exerciseName: 'Bench Press, Barbell',
            weekIndex: 0,
            dayIndex: 0,
            totalBlockWeeks: 4,
            planService: FirestoreWes2PlanService(firestore: db),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    TextField field(WidgetTester tester, String label) =>
        tester.widget<TextField>(find.ancestor(
            of: find.text(label), matching: find.byType(TextField)));

    testWidgets('select pounds, save: weightUnit persists, kg values untouched',
        (tester) async {
      final h = Harness();
      await tester.runAsync(() async {
        await h.seedShared(bench, 'Bench Press, Barbell');
        await h
            .seedBlock(athlete, 'active1', isActive: true, exerciseSettings: {
          bench: {
            'periodizationModel': 'DUP, By Exposure',
            'rirModel': 'Static RIR',
            'progressionModel': 'Smart Progression',
            'weeklyFrequency': 2,
            'defaultSets': 3,
            'increments': {'primary': 2.5},
            'repTargets': {
              'week1': {'instance1': '8 x 3', 'instance2': '6 x 3'}
            },
          },
        });
      });
      final before = await tester.runAsync(() => benchSettings(h.db));

      await pumpDialog(tester, h.db);
      expect(find.text('Kilograms (kg)'), findsOneWidget);
      expect(field(tester, 'Primary Increment').controller!.text, '2.5');

      await tester.tap(find.byKey(const ValueKey('wes2-weight-unit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pounds (lb)').last);
      await tester.pumpAndSettle();
      expect(field(tester, 'Primary Increment (lb)').controller!.text, '5.512');

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final after = await tester.runAsync(() => benchSettings(h.db));
      expect(after!['weightUnit'], 'lb');
      expect(after['increments'], before!['increments'],
          reason: 'switching the unit never rewrites stored kilograms');

      // Block Planner 2 resolves the same persisted leaf.
      ExerciseUnitRegistry.shared = ExerciseUnitRegistry();
      await tester.runAsync(() async {
        final c = h.controller;
        await c.bind(
            uid: athlete, blockId: 'active1', activeBlockId: 'active1');
        expect(c.resolvedFor(bench).weightUnit, ExerciseWeightUnit.lb);
        expect(c.resolvedFor(bench).incrementPrimary, '5.512');
        c.dispose();
      });
    });
  });

  test('the unit leaf is a plain string in Firestore', () async {
    final db = FakeFirebaseFirestore();
    await db.doc('users/u/planned_blocks/b').set({
      'exerciseSettings': {
        bench: {'weightUnit': 'lb'}
      }
    });
    final snap = await db.doc('users/u/planned_blocks/b').get();
    expect(
        ((snap.data()!['exerciseSettings'] as Map)[bench] as Map)['weightUnit'],
        'lb');
    expect(
        FieldPath(const ['exerciseSettings', bench, 'weightUnit']).components,
        hasLength(3));
  });
}
