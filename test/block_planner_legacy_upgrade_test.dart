// Fresh device / app update: the LEGACY Block Planner (Drawer → Planned
// Blocks and Drawer → Block Planner) opens a populated pre-update active
// block with no local cache. Opening and leaving must write nothing; a failed
// or incomplete load must never be saved; an explicit deletion removes
// exactly that exercise and nothing else.

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/Block_Planner.dart';
import 'package:localtest222/block_exercise_defaults_repository.dart';
import 'package:localtest222/exercise_catalog.dart';
import 'package:localtest222/user_context.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/pre_update_block_fixture.dart';

String _enc(Object? o) => jsonEncode(o,
    toEncodable: (v) =>
        v is Timestamp ? v.millisecondsSinceEpoch : v.toString());

/// The whole database as JSON, minus the empty placeholder entries the fake
/// lists for bare `.doc(id)` references (real Firestore writes nothing for
/// those; a real document in these fixtures always has fields).
String _state(FakeFirebaseFirestore db) {
  Object? prune(Object? v) {
    if (v is Map) {
      final out = <String, Object?>{};
      v.forEach((k, val) {
        final p = prune(val);
        if (p is Map && p.isEmpty) return;
        out[k.toString()] = p;
      });
      return out;
    }
    if (v is List) return v.map(prune).toList();
    return v;
  }

  return jsonEncode(prune(jsonDecode(db.dump())));
}

void main() {
  late FakeFirebaseFirestore db;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = FakeFirebaseFirestore();
    Block_Planner.debugFirestoreOverride = db;
    ExerciseCatalog.debugFirestoreOverride = db;
    BlockExerciseDefaultsRepository.debugFirestoreOverride = db;
  });

  tearDown(() {
    Block_Planner.debugFirestoreOverride = null;
    ExerciseCatalog.debugFirestoreOverride = null;
    BlockExerciseDefaultsRepository.debugFirestoreOverride = null;
  });

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> open(WidgetTester tester, Map<String, dynamic> args) async {
    tester.view.physicalSize = const Size(1200, 12000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final uc = UserContext(actorUid: kFxAthlete, isCoach: false)
      ..debugSetBlockMeta(activeBlockId: kFxActive);
    await tester.pumpWidget(ChangeNotifierProvider<UserContext>.value(
      value: uc,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                settings: RouteSettings(arguments: args),
                builder: (_) => ChangeNotifierProvider<UserContext>.value(
                  value: uc,
                  child: const Block_Planner(),
                ),
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await settle(tester);
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pageBack();
    await settle(tester);
    expect(find.text('Block Planner'), findsNothing);
  }

  for (final allAvailable in [false, true]) {
    final shape = allAvailable ? 'allExercisesAvailable' : 'membership arrays';

    testWidgets(
        '[$shape] open existing active block + leave: zero writes, every '
        'exercise visible', (tester) async {
      await seedPreUpdateBlock(db, allExercisesAvailable: allAvailable);
      final before = _state(db);

      await open(tester, {'blockId': kFxActive});
      for (final id in kFxMembers) {
        final row = find.byKey(ValueKey('bp_${kFxActive}_$id'));
        expect(row, findsOneWidget, reason: '$id listed');
        expect(
            find.descendant(
                of: row,
                matching:
                    find.textContaining(kFxNames[id]!, findRichText: true)),
            findsWidgets,
            reason: '$id card rendered (settings + dates loaded)');
      }
      expect(find.byKey(const ValueKey('bp-load-error')), findsNothing);
      expect(_state(db), before, reason: 'opening wrote nothing');

      await leave(tester);
      expect(_state(db), before, reason: 'leaving wrote nothing');
    });
  }

  testWidgets('a failed block load is shown and can never be saved',
      (tester) async {
    await seedPreUpdateBlock(db);
    // A block the old parser cannot read (no dates) — the load fails.
    await db
        .collection('users')
        .doc(kFxAthlete)
        .collection('planned_blocks')
        .doc(kFxActive)
        .update({'startDate': FieldValue.delete()});
    final before = _state(db);

    await open(tester, {'blockId': kFxActive});
    expect(find.byKey(const ValueKey('bp-load-error')), findsOneWidget);
    await tester.tap(find.byIcon(Icons.save));
    await settle(tester);
    // The Save dialog may appear (validation is UI-level); confirm it.
    if (find.text('Save').evaluate().isNotEmpty) {
      await tester.tap(find.text('Save').last);
      await settle(tester);
    }
    expect(_state(db), before);
    await leave(tester);
    expect(_state(db), before);
  });

  testWidgets(
      'an empty temporary catalogue (fresh device, offline) cannot be saved '
      'over an allExercisesAvailable block', (tester) async {
    await seedPreUpdateBlock(db, allExercisesAvailable: true);
    for (final id in kFxNames.keys) {
      await db.collection('exercises').doc(id).delete();
    }
    await db
        .collection('users')
        .doc(kFxAthlete)
        .collection('customExercises')
        .doc(kFxCustom)
        .delete();
    final before = _state(db);

    await open(tester, {'blockId': kFxActive});
    expect(find.byKey(const ValueKey('bp-load-error')), findsOneWidget);
    await leave(tester);
    expect(_state(db), before);
  });

  testWidgets(
      'an explicit swipe-delete removes exactly that exercise; every other '
      'stored field stays byte-identical', (tester) async {
    await seedPreUpdateBlock(db);
    final before = await fxBlock(db);

    await open(tester, {'blockId': kFxActive});
    final tile = find.byKey(const ValueKey('bp_${kFxActive}_$kFxCurl'));
    await tester.ensureVisible(tile);
    await tester.drag(tile, const Offset(-1100, 0));
    await settle(tester);

    final after = await fxBlock(db);
    final settings = after['exerciseSettings'] as Map;
    expect(settings.containsKey(kFxCurl), isFalse);
    for (final id in kFxMembers.where((id) => id != kFxCurl)) {
      expect(_enc(settings[id]), _enc(kFxSettings[id]), reason: id);
    }
    final remaining = kFxMembers.where((id) => id != kFxCurl).toList();
    expect(after['exercises'], remaining);
    expect(after['plannedExercises'], remaining);
    for (final k in before.keys.where((k) =>
        !{'exerciseSettings', 'exercises', 'plannedExercises'}.contains(k))) {
      expect(_enc(after[k]), _enc(before[k]), reason: k);
    }
    expect(_enc(await fxBlock(db, kFxOther)), isNotEmpty);
  });

  testWidgets(
      'Drawer → Block Planner (new block) opens and leaves with zero '
      'writes', (tester) async {
    await seedPreUpdateBlock(db);
    final before = _state(db);
    await open(tester, {'newBlock': true});
    expect(_state(db), before, reason: 'no block created merely by opening');
    await leave(tester);
    expect(_state(db), before);
  });
}
