import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_planner_2/bp2_controller.dart';
import 'package:localtest222/block_planner_2/bp2_date_utils.dart';
import 'package:localtest222/block_planner_2/bp2_settings_resolver.dart';

import 'bp2_test_support.dart';

void main() {
  const athlete = 'athlete-uid';
  const coach = 'coach-uid';
  const bench = 'AmfUWbF1DH3I7qPAdh5k';

  Future<Harness> seeded() async {
    final h = Harness();
    await h.seedShared(bench, 'Bench Press, Barbell');
    await h.seedShared('sq', 'Back Squat, Barbell',
        category: 'Squat Pattern', bodyPart: 'Quads');
    await h.seedCustom(athlete, 'c1', 'Athlete Custom');
    await h.seedCustom(coach, 'coachCustom', 'Coach Custom');
    await h.seedTemplate(athlete, 't1', 'active1', [
      {'exerciseId': bench, 'name': 'Bench Press, Barbell'}
    ]);
    await h.seedTemplate(athlete, 't2', 'old1', [
      {'exerciseId': 'sq', 'name': 'Back Squat, Barbell'}
    ]);
    await h.seedBlock(athlete, 'active1', isActive: true);
    await h.seedBlock(athlete, 'old1', isActive: false);
    await h.seedUser(athlete, username: 'richard');
    await h.seedUser(coach, username: 'coach');
    return h;
  }

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 10));

  group('new draft', () {
    test('auto name follows date changes until edited, then stays custom',
        () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, activeBlockId: 'active1');
      expect(c.nameIsAuto, isTrue);
      expect(c.name, startsWith('richard — 21 Sep 2026 to '));
      expect(c.range!.weeks, 4); // four Monday–Sunday weeks
      expect(c.range!.start, DateTime(2026, 9, 21));
      expect(c.range!.end, DateTime(2026, 10, 18));

      c.setRange(DateTime(2026, 9, 23), DateTime(2026, 10, 6));
      expect(
          c.range,
          Bp2DateUtils.normalizeRange(
              DateTime(2026, 9, 21), DateTime(2026, 10, 11)));
      expect(c.name, 'richard — 21 Sep 2026 to 11 Oct 2026');

      c.setName('Hypertrophy block');
      expect(c.nameIsAuto, isFalse);
      c.setRange(DateTime(2026, 11, 2), DateTime(2026, 11, 29));
      expect(c.name, 'Hypertrophy block');

      // Whitespace-only means "no custom name": the fallback returns and
      // follows the dates again.
      c.setName('   ');
      expect(c.nameIsAuto, isTrue);
      expect(c.effectiveName, 'richard — 2 Nov 2026 to 29 Nov 2026');
      c.dispose();
    });

    test('opening and closing without interaction writes nothing', () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, activeBlockId: 'active1');
      expect(c.isDirty, isFalse);
      final out = await c.save(fromExit: true);
      expect(out.nothingToSave, isTrue);
      final blocks = await h.db
          .collection('users')
          .doc(athlete)
          .collection('planned_blocks')
          .get();
      expect(blocks.docs.length, 2, reason: 'no new block document');
      c.dispose();
    });

    test(
        'manual save creates the block for the SELECTED athlete and only dirty settings',
        () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, activeBlockId: 'active1');
      final id = c.block!.id;
      c.setRange(DateTime(2026, 9, 21), DateTime(2026, 10, 18));
      c.edit(bench, Bp2Field.incrementPrimary, '5');
      c.edit(bench, Bp2Field.weeklyFrequency, '4'); // same as default → no-op
      expect(c.dirtyExerciseIds, {bench});

      final out = await c.save();
      expect(out.success, isTrue);
      expect(out.offlineQueued, isFalse);

      final doc = await h.block(athlete, id);
      expect(doc, isNotNull);
      expect(doc!['name'], 'richard — 21 Sep 2026 to 18 Oct 2026');
      expect(doc['isActive'], false);
      expect(doc['selectedDays'],
          ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']);
      final settings = doc['exerciseSettings'] as Map;
      expect(settings.keys, [bench],
          reason: 'only the dirty exercise is written');
      final benchSettings = Map<String, dynamic>.from(settings[bench] as Map);
      expect(benchSettings['increments'], {'primary': 5.0});
      expect(benchSettings['weeklyFrequency'], 4);
      expect(benchSettings['defaultSets'], 3);
      expect(benchSettings['periodizationModel'], 'DUP, By Exposure');
      expect(doc.containsKey('plannedExerciseDetails'), isFalse);
      expect(doc.containsKey('explicitRepTargets'), isFalse);
      // Nothing written under the coach.
      expect(await h.block(coach, id), isNull);
      // Canonical week scaffold requested for exactly the normalized weeks.
      expect(h.repo.scaffolds.single.$2, id);
      expect(h.repo.scaffolds.single.$4, 4);
      // Dirty flags cleared, draft cache cleared.
      expect(c.isDirty, isFalse);
      expect(await h.sync.readDraft(athlete, id), isNull);
      expect(c.block!.existsRemotely, isTrue);
      expect(c.isEditingActiveBlock, isFalse);
      c.dispose();
    });

    test('reopening a new draft reuses the same stable id (no duplicates)',
        () async {
      final h = await seeded();
      final c1 = h.controller;
      await c1.bind(uid: athlete, activeBlockId: 'active1');
      final id = c1.block!.id;
      c1.setName('Draft in progress');
      await pump();
      c1.dispose();

      final c2 = Bp2Controller(
          sync: h.sync,
          repo: h.repo,
          now: () => h.now,
          draftDebounce: Duration.zero);
      await c2.bind(uid: athlete, activeBlockId: 'active1');
      expect(c2.block!.id, id);
      expect(c2.name, 'Draft in progress');
      expect(c2.nameIsAuto, isFalse);
      c2.dispose();
    });
  });

  group('athlete isolation', () {
    test(
        'switching athlete clears stale state synchronously before rehydration',
        () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, activeBlockId: 'active1');
      c.edit(bench, Bp2Field.incrementPrimary, '7');
      expect(c.grouping.currentBlock.map((e) => e.id), [bench]);

      final binding = c.bind(uid: coach, activeBlockId: null);
      // Synchronous part of bind has already run:
      expect(c.uid, coach);
      expect(c.block, isNull);
      expect(c.catalogue, isEmpty);
      expect(c.draftFor(bench).isEmpty, isTrue);
      expect(c.grouping.total, 0);
      await binding;
      expect(c.catalogue.map((e) => e.id), containsAll(['coachCustom', bench]));
      expect(c.catalogue.any((e) => e.id == 'c1'), isFalse);
      expect(c.grouping.currentBlock, isEmpty);
      expect(c.name, startsWith('coach — '));
      c.dispose();
    });

    test('grouping uses the canonical active pointer', () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, activeBlockId: 'active1');
      expect(c.grouping.currentBlock.map((e) => e.id), [bench]);
      expect(c.grouping.otherBlocks.map((e) => e.id), ['sq']);
      expect(c.grouping.allOther.map((e) => e.id), ['c1']);
      c.setActiveBlockPointer('old1');
      expect(c.grouping.currentBlock.map((e) => e.id), ['sq']);
      expect(c.grouping.otherBlocks.map((e) => e.id), [bench]);
      c.dispose();
    });
  });

  group('drafts and freshness', () {
    test('expand/collapse and background refresh never discard unsaved edits',
        () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'old1', activeBlockId: 'active1');
      c.toggleExpanded(bench);
      c.edit(bench, Bp2Field.rir(1, 2), '0.5');
      c.toggleExpanded(bench); // collapse
      c.toggleExpanded('sq'); // open another
      expect(c.resolvedFor(bench).sessions[0].rir[1], '0.5');

      // Remote changes to the block while editing.
      await h.db
          .collection('users')
          .doc(athlete)
          .collection('planned_blocks')
          .doc('old1')
          .update({'name': 'Renamed remotely'});
      await h.sync.refreshBlock(athlete, 'old1');
      await c.retrySync();
      expect(c.resolvedFor(bench).sessions[0].rir[1], '0.5');
      expect(c.isExerciseDirty(bench), isTrue);
      c.dispose();
    });

    test('warm open of an existing block: cached first, counts, one block read',
        () async {
      final h = await seeded();
      await h.sync.refresh(athlete);
      await h.sync.refreshBlock(athlete, 'old1');
      final fetchesBefore = h.repo.totalFetches;
      final countsBefore = h.repo.countCalls;
      final blockReadsBefore = h.repo.blockDocFetches;

      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'old1', activeBlockId: 'active1');
      expect(c.catalogueLoaded, isTrue);
      expect(c.block!.name, 'old1');
      expect(h.repo.totalFetches, fetchesBefore, reason: 'no re-download');
      expect(h.repo.countCalls, countsBefore + 4);
      expect(h.repo.blockDocFetches, blockReadsBefore + 1);
      c.dispose();
    });
  });

  group('activation', () {
    test('leaves exactly one active block, retires the previous, no PMU writes',
        () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, activeBlockId: 'active1');
      c.setName('New block');
      final id = c.block!.id;
      expect((await c.save()).success, isTrue);
      expect(c.isEditingActiveBlock, isFalse, reason: 'activation is offered');

      final before = await h.block(athlete, 'active1');
      final out = await c.activate();
      expect(out.success, isTrue);
      expect(await h.activeBlockIds(athlete), [id]);
      final retired = await h.block(athlete, 'active1');
      expect(retired!['isActive'], false);
      // Retiring touched only the flag (+ updatedAt): every other field intact.
      for (final k in before!.keys) {
        if (k == 'isActive' || k == 'updatedAt') continue;
        expect(retired[k], before[k], reason: k);
      }
      expect(retired.containsKey('plannedExerciseDetails'), isFalse);
      expect(c.isEditingActiveBlock, isTrue);
      expect(c.activeBlockId, id);
      expect(c.grouping.currentBlock, isEmpty, reason: 'no templates yet');
      expect(c.grouping.otherBlocks.map((e) => e.id).toSet(), {bench, 'sq'});
      // Retrying activation is idempotent.
      expect((await c.activate()).success, isTrue);
      expect(await h.activeBlockIds(athlete), [id]);
      c.dispose();
    });

    test('activation converges when two blocks were concurrently active',
        () async {
      final h = await seeded();
      await h.seedBlock(athlete, 'rogue', isActive: true);
      final r = await h.repo.activateBlock(uid: athlete, blockId: 'old1');
      expect(r.retiredBlockIds.toSet(), {'active1', 'rogue'});
      expect(await h.activeBlockIds(athlete), ['old1']);
    });
  });

  group('existing block edits', () {
    test(
        'only dirty settings are patched; unrelated keys and exercises survive',
        () async {
      final h = await seeded();
      await h.seedBlock(athlete, 'old1', isActive: false, exerciseSettings: {
        bench: {
          'periodizationModel': 'DUP, By Week',
          'rirModel': 'Static RIR',
          'progressionModel': 'Add Reps',
          'weeklyFrequency': 2,
          'defaultSets': 4,
          'increments': {'primary': 1.25, 'secondary': 0.5},
          'notes': 'keep me',
          'repTargets': {
            'week1': {'instance1': '8 x 4', 'instance2': '12 x 2'}
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
            }
          },
        },
        'sq': {
          'periodizationModel': 'Linear, Classic',
          'weeklyFrequency': 1,
          'repTargets': {
            'week1': {'instance1': '5 x 5'}
          }
        },
      }, extra: {
        'completedWorkoutMetadata': {'keep': 'DO_NOT_TOUCH'}
      });
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'old1', activeBlockId: 'active1');
      expect(c.resolvedFor(bench).incrementPrimary, '1.25');
      c.edit(bench, Bp2Field.rir(1, 2), '2.5');
      c.edit(bench, Bp2Field.progressionModel, 'None');
      expect(c.blockDirty, isFalse);

      final out = await c.save();
      expect(out.success, isTrue);
      final doc = (await h.block(athlete, 'old1'))!;
      expect(doc['name'], 'old1');
      expect(doc['completedWorkoutMetadata'], {'keep': 'DO_NOT_TOUCH'});
      final s = doc['exerciseSettings'] as Map;
      final b = Map<String, dynamic>.from(s[bench] as Map);
      expect(b['progressionModel'], 'None');
      expect(b['defaultSets'], 4);
      expect(b['notes'], 'keep me');
      expect(b['increments'], {'primary': 1.25, 'secondary': 0.5});
      expect(b['rirPlan']['week1']['session1']['set2'],
          {'rir': '2.5', 'reps': '8'});
      expect(
          b['rirPlan']['week1']['session1']['set1'], {'rir': '1', 'reps': '8'});
      expect(b['repTargets'], {
        'week1': {'instance1': '8 x 4', 'instance2': '12 x 2'}
      });
      expect(s['sq'], {
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'repTargets': {
          'week1': {'instance1': '5 x 5'}
        }
      });
      expect(h.repo.scaffolds, isEmpty,
          reason: 'dates unchanged → no scaffold');
      c.dispose();
    });
  });
}
