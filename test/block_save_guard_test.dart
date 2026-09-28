import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_save_guard.dart';

import 'support/pre_update_block_fixture.dart';

void main() {
  late FakeFirebaseFirestore db;
  late DocumentReference<Map<String, dynamic>> ref;

  setUp(() async {
    db = FakeFirebaseFirestore();
    await seedPreUpdateBlock(db);
    ref = db
        .collection('users')
        .doc(kFxAthlete)
        .collection('planned_blocks')
        .doc(kFxActive);
  });

  Future<BlockSavePlan> commit(BlockSaveRequest r) =>
      BlockSaveGuard.commit(db: db, ref: ref, request: r);

  test('an empty local model writes nothing', () async {
    final before = db.dump();
    final plan = await commit(const BlockSaveRequest(
      membership: [],
      excludedExerciseIds: [kFxBench, kFxSquat],
      visibleExerciseCount: 0,
    ));
    expect(plan.isEmpty, isTrue);
    expect(plan.refused, hasLength(2));
    expect(db.dump(), before, reason: 'byte-for-byte unchanged');
  });

  test('metadata can never write settings or membership', () async {
    final before = db.dump();
    final plan = await commit(const BlockSaveRequest(metadata: {
      'exerciseSettings': <String, dynamic>{},
      'exercises': <String>[],
      'plannedExercises': <String>[],
      'excludedExerciseIds': <String>[],
      'exerciseSettings.fxBench': <String, dynamic>{},
    }));
    expect(plan.isEmpty, isTrue);
    expect(plan.refused, hasLength(5));
    expect(db.dump(), before);
  });

  test(
      'one changed exercise updates only that entry, preserving its '
      'unknown keys and every other entry', () async {
    final plan = await commit(const BlockSaveRequest(changedEntries: {
      kFxSquat: {'notes': 'new note', 'explicitRepTargets': {}},
    }));
    expect(plan.updates.keys, [
      FieldPath(const ['exerciseSettings', kFxSquat])
    ]);
    final after = await fxBlock(db);
    final settings = after['exerciseSettings'] as Map;
    final expectedSquat = Map<String, dynamic>.from(kFxSettings[kFxSquat]!)
      ..['notes'] = 'new note';
    expect(jsonEncode(settings[kFxSquat]), jsonEncode(expectedSquat));
    for (final id in kFxMembers.where((id) => id != kFxSquat)) {
      expect(jsonEncode(settings[id]), jsonEncode(kFxSettings[id]), reason: id);
    }
    expect(after['exercises'], kFxMembers);
    expect(after['plannedExerciseDetails'], isNotNull);
  });

  test('only explicitly removed exercises are deleted', () async {
    await commit(const BlockSaveRequest(
      removedIds: {kFxCurl, 'neverStored'},
      membership: [kFxBench, kFxSquat, kFxRow, kFxCustom],
    ));
    final after = await fxBlock(db);
    final settings = after['exerciseSettings'] as Map;
    expect(settings.keys.toSet(), {kFxBench, kFxSquat, kFxRow, kFxCustom});
    for (final id in settings.keys) {
      expect(jsonEncode(settings[id]), jsonEncode(kFxSettings[id]));
    }
    expect(after['exercises'], [kFxBench, kFxSquat, kFxRow, kFxCustom]);
  });

  test('a missing block document is never created', () async {
    final missing = db
        .collection('users')
        .doc(kFxAthlete)
        .collection('planned_blocks')
        .doc('missing');
    final plan = await BlockSaveGuard.commit(
      db: db,
      ref: missing,
      request: const BlockSaveRequest(changedEntries: {
        kFxBench: {'notes': 'x'}
      }),
    );
    expect(plan.isEmpty, isTrue);
    expect((await missing.get()).exists, isFalse);
  });
}
