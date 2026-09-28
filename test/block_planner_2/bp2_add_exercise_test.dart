// End-to-end: Block Planner 2 "Add exercise" adds an EXISTING exercise to the
// selected block — through the real button, the real picker route and the
// real repository transaction (fake Firestore). No callback is replaced.

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_planner_2/bp2_exercise_picker.dart';
import 'package:localtest222/block_planner_2/bp2_screen.dart';
import 'package:localtest222/user_context.dart';
import 'package:provider/provider.dart';

import '../support/pre_update_block_fixture.dart';
import 'bp2_test_support.dart';

String _enc(Object? o) => jsonEncode(o,
    toEncodable: (v) =>
        v is Timestamp ? v.millisecondsSinceEpoch : v.toString());

void main() {
  Future<void> openBlock(WidgetTester tester, Harness h, String blockId) async {
    tester.view.physicalSize = const Size(412, 2400);
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
                builder: (_) =>
                    Bp2Screen(blockId: blockId, controller: h.controller),
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
  }

  Future<int> count(Harness h, String path) async =>
      (await h.db.collection(path).get()).docs.length;

  testWidgets(
      'Add exercise → pick an existing exercise → exactly that exercise is '
      'added to block A; block B, A\'s other settings and the catalogue are '
      'unchanged', (tester) async {
    final h = Harness();
    await seedPreUpdateBlock(h.db);
    final blockBBefore = _enc(await fxBlock(h.db, kFxOther));
    final blockABefore = await fxBlock(h.db);
    final globalCount = await count(h, 'exercises');
    final customCount = await count(h, 'users/$kFxAthlete/customExercises');

    await openBlock(tester, h, kFxActive);
    await tester.tap(find.byKey(const ValueKey('bp2-add-exercise')));
    await tester.pumpAndSettle();
    expect(find.text(Bp2ExercisePicker.title), findsOneWidget,
        reason: 'the block picker opened, not the creation dialog');

    // Existing global AND custom exercises are listed; ones already in the
    // block cannot be picked again.
    expect(find.byKey(const ValueKey('bp2-pick-$kFxUnused')), findsOneWidget);
    expect(find.byKey(const ValueKey('bp2-pick-$kFxCustom')), findsOneWidget);
    expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('bp2-pick-$kFxBench')))
            .enabled,
        isFalse);

    // Search narrows the list.
    await tester.enterText(
        find.byKey(const ValueKey('bp2-picker-search')), 'zerch');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bp2-pick-$kFxBench')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('bp2-pick-$kFxUnused')));
    await tester.pumpAndSettle();
    expect(find.text(Bp2ExercisePicker.title), findsNothing);

    final blockA = await fxBlock(h.db);
    final settings = blockA['exerciseSettings'] as Map;
    expect(settings.keys.toSet(), {...kFxMembers, kFxUnused},
        reason: 'exactly the picked exercise was added');
    final added = settings[kFxUnused] as Map;
    for (final k in ['periodizationModel', 'repTargets', 'defaultSets']) {
      expect(added.containsKey(k), isTrue, reason: 'seeded default $k');
    }
    for (final id in kFxMembers) {
      expect(_enc(settings[id]), _enc(kFxSettings[id]),
          reason: '$id unchanged');
    }
    for (final k in blockABefore.keys.where((k) => k != 'exerciseSettings')) {
      expect(_enc(blockA[k]), _enc(blockABefore[k]), reason: k);
    }
    expect(_enc(await fxBlock(h.db, kFxOther)), blockBBefore,
        reason: 'another block is never touched');
    expect(await count(h, 'exercises'), globalCount,
        reason: 'no global exercise document created');
    expect(await count(h, 'users/$kFxAthlete/customExercises'), customCount);

    // It now shows in Current block (its settings key), without a reload.
    expect(h.controller.grouping.currentBlock.map((e) => e.id),
        contains(kFxUnused));
  });

  testWidgets('a new, unsaved block asks to be saved first and writes nothing',
      (tester) async {
    final h = Harness();
    await seedPreUpdateBlock(h.db);
    final blocksBefore = await count(h, 'users/$kFxAthlete/planned_blocks');
    final aBefore = _enc(await fxBlock(h.db));
    tester.view.physicalSize = const Size(412, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<UserContext>.value(
      value: UserContext(actorUid: kFxAthlete, isCoach: false),
      child: MaterialApp(home: Bp2Screen(controller: h.controller)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bp2-add-exercise')));
    await tester.pumpAndSettle();
    expect(find.text(Bp2ExercisePicker.title), findsNothing);
    expect(
        find.text('Save the block before adding exercises.'), findsOneWidget);
    // (The fake lists an empty placeholder for the id BP2 allocates with
    // doc(); real Firestore writes nothing. Compare real documents.)
    expect(await count(h, 'users/$kFxAthlete/planned_blocks'), blocksBefore,
        reason: 'no block document created');
    expect(_enc(await fxBlock(h.db)), aBefore);
  });
}
