import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_planner_2/bp2_screen.dart';
import 'package:localtest222/block_planner_2/bp2_settings_resolver.dart';
import 'package:localtest222/exercise_catalog.dart';
import 'package:localtest222/user_context.dart';
import 'package:provider/provider.dart';

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
    await h.seedShared('row', 'Cable Row',
        category: 'Horizontal Pull', bodyPart: 'Lats');
    await h.seedCustom(athlete, 'c1', 'Athlete Custom');
    await h.seedTemplate(athlete, 't1', 'active1', [
      {'exerciseId': bench, 'name': 'Bench Press, Barbell'}
    ]);
    await h.seedTemplate(athlete, 't2', 'old1', [
      {'exerciseId': 'sq', 'name': 'Back Squat, Barbell'}
    ]);
    await h.seedBlock(athlete, 'active1', isActive: true);
    await h.seedBlock(athlete, 'old1', isActive: false);
    await h.seedUser(athlete, username: 'richard');
    return h;
  }

  /// Coach signed in, athlete selected — the screen must scope to the athlete.
  UserContext coachViewingAthlete() {
    final uc = UserContext(actorUid: coach, isCoach: true);
    uc.actingAsUid = athlete;
    uc.debugSetBlockMeta(activeBlockId: 'active1');
    return uc;
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    Harness h, {
    UserContext? uc,
    String? blockId,
    Bp2AddExerciseFlow? addExerciseFlow,
    GlobalKey<NavigatorState>? navKey,
  }) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<UserContext>.value(
      value: uc ?? coachViewingAthlete(),
      child: MaterialApp(
        navigatorKey: navKey,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('open'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => Bp2Screen(
                    blockId: blockId,
                    controller: h.controller,
                    addExerciseFlow: addExerciseFlow,
                  ),
                )),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
  }

  testWidgets('renders title, Save, name, dates, groups and add-exercise',
      (tester) async {
    final h = await seeded();
    await pumpScreen(tester, h);

    expect(find.text('Block Planner 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('bp2-save')), findsOneWidget);
    expect(find.text('Add exercise'), findsOneWidget);
    expect(find.text('Exercises in templates'), findsOneWidget);
    expect(find.text('Current block'), findsOneWidget);
    expect(find.text('Other blocks'), findsOneWidget);
    expect(find.text('All other exercises'), findsOneWidget);
    expect(find.text('26 weeks'), findsOneWidget);
    expect(h.controller.name, startsWith('richard — '));
    expect(h.controller.uid, athlete, reason: 'scoped to selected athlete');

    // Group order: bench (current) → squat (other) → rest alphabetical.
    final names = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(ListTile), matching: find.byType(Text)))
        .map((t) => t.data)
        .whereType<String>()
        .where(
            (s) => s.contains(',') || s == 'Athlete Custom' || s == 'Cable Row')
        .toList();
    expect(names, [
      'Bench Press, Barbell',
      'Back Squat, Barbell',
      'Athlete Custom',
      'Cable Row',
    ]);
  });

  testWidgets('expanding shows the four rows; edits survive collapse/reopen',
      (tester) async {
    final h = await seeded();
    await pumpScreen(tester, h);

    await tester.tap(find.text('Bench Press, Barbell'));
    await tester.pumpAndSettle();
    for (final label in [
      'Increments',
      'Weekly frequency',
      'Rep periodization model',
      'Rep targets & set count',
      'RIR periodization model',
      'RIR targets',
      'Progression model',
      'Velocity',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(tester.takeException(), isNull,
        reason: 'no overflow at phone width');
    // Canonical defaults shown (Bench: 2.5 kg, 4×/week, DUP By Exposure).
    expect(find.widgetWithText(TextField, '2.5'), findsOneWidget);
    expect(find.widgetWithText(TextField, '4'), findsOneWidget);
    expect(find.text('DUP, By Exposure'), findsOneWidget);
    expect(find.text('9×3, 5×3, 12×3, 3×3'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '2.5'), '5');
    await tester.pump();
    expect(h.controller.draftFor(bench)[Bp2Field.incrementPrimary], '5');

    // Collapse, open another, reopen: the unsaved value is still there.
    await tester.tap(find.text('Bench Press, Barbell'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cable Row'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bench Press, Barbell'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '5'), findsOneWidget);
    expect(h.controller.isExerciseDirty(bench), isTrue);
  });

  testWidgets('rep editor edits reps and sets; RIR editor edits each set',
      (tester) async {
    final h = await seeded();
    await pumpScreen(tester, h);
    await tester.tap(find.text('Bench Press, Barbell'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('9×3, 5×3, 12×3, 3×3'));
    await tester.pumpAndSettle();
    expect(find.text('Session 1:'), findsOneWidget);
    expect(find.text('Session 4:'), findsOneWidget);
    await tester.enterText(find.bySemanticsLabel('Session 2 reps'), '15');
    await tester.enterText(find.bySemanticsLabel('Session 2 sets'), '4');
    await tester.pump();
    expect(h.controller.draftFor(bench)[Bp2Field.repInstance(2)], '15 x 4');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('9×3, 15×4, 12×3, 3×3'), findsOneWidget);

    final r = h.controller.resolvedFor(bench);
    await tester.tap(find.text(r.rirSummary));
    await tester.pumpAndSettle();
    expect(find.text('Session 2'), findsOneWidget);
    // Session 2 now has 4 sets.
    expect(find.bySemanticsLabel('Session 2 set 4 RIR'), findsOneWidget);
    await tester.enterText(find.bySemanticsLabel('Session 2 set 4 RIR'), '0.5');
    await tester.enterText(find.bySemanticsLabel('Session 1 set 1 RIR'), '1.5');
    await tester.pump();
    expect(h.controller.draftFor(bench)[Bp2Field.rir(2, 4)], '0.5');
    expect(h.controller.draftFor(bench)[Bp2Field.rir(1, 1)], '1.5');
    final r2 = h.controller.resolvedFor(bench);
    expect(r2.sessions[1].rir, ['2', '2', '2.5', '0.5']);
    expect(r2.sessions[0].rir, ['1.5', '2', '2.5']);
  });

  testWidgets('manual Save offers activation; activation retires the old block',
      (tester) async {
    final h = await seeded();
    final uc = coachViewingAthlete();
    await pumpScreen(tester, h, uc: uc);
    await tester.enterText(find.byKey(const ValueKey('bp2-name')), 'New block');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('bp2-save')));
    await tester.pumpAndSettle();
    expect(find.text('Activate block?'), findsOneWidget);
    expect(find.text('Activate block'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);

    await tester.tap(find.text('Activate block'));
    await tester.pumpAndSettle();
    final id = h.controller.block!.id;
    expect(await h.activeBlockIds(athlete), [id]);
    expect(uc.activeBlockId, id, reason: 'UserContext pointer refreshed');
    expect((await h.block(athlete, 'active1'))!['isActive'], false);
    expect(find.text('Block activated.'), findsOneWidget);

    // Saving again while active: no redundant offer.
    await tester.enterText(
        find.byKey(const ValueKey('bp2-name')), 'New block 2');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('bp2-save')));
    await tester.pumpAndSettle();
    expect(find.text('Activate block?'), findsNothing);
    expect(find.text('Block saved.'), findsOneWidget);
  });

  testWidgets('exit auto-saves dirty changes without offering activation',
      (tester) async {
    final h = await seeded();
    await pumpScreen(tester, h);
    await tester.enterText(find.byKey(const ValueKey('bp2-name')), 'Exit save');
    await tester.pump();
    final id = h.controller.block!.id;

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Activate block?'), findsNothing);
    expect(find.text('Block Planner 2'), findsNothing, reason: 'route popped');
    final doc = await h.block(athlete, id);
    expect(doc!['name'], 'Exit save');
    expect(doc['isActive'], false);
  });

  testWidgets('exit with nothing changed pops immediately with no writes',
      (tester) async {
    final h = await seeded();
    await pumpScreen(tester, h);
    final id = h.controller.block!.id;
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Block Planner 2'), findsNothing);
    expect(await h.block(athlete, id), isNull);
  });

  testWidgets('invalid data keeps the page open and shows the error',
      (tester) async {
    final h = await seeded();
    await pumpScreen(tester, h);
    await tester.tap(find.text('Bench Press, Barbell'));
    await tester.pumpAndSettle();
    await tester.enterText(find.bySemanticsLabel('Weekly frequency'), '20');
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Block Planner 2'), findsOneWidget, reason: 'still open');
    expect(find.textContaining('Weekly frequency must be'), findsWidgets);
  });

  testWidgets(
      'Add exercise opens the canonical flow scoped to the athlete and refreshes',
      (tester) async {
    final h = await seeded();
    String? seenOwner;
    String? seenActor;
    Future<AddExerciseResult?> flow(BuildContext context,
        {required String ownerUid, required String actorUid}) async {
      seenOwner = ownerUid;
      seenActor = actorUid;
      // Simulate the canonical dialog writing through ExerciseCatalog.
      await h.seedCustom(ownerUid, 'newCustom', 'Aardvark Crunch');
      return const AddExerciseResult(
          outcome: AddExerciseOutcome.createdCustom,
          exerciseId: 'newCustom',
          ownerUid: athlete);
    }

    await pumpScreen(tester, h, addExerciseFlow: flow);
    final fetchesBefore = h.repo.totalFetches;
    await tester.tap(find.byKey(const ValueKey('bp2-add-exercise')));
    await tester.pumpAndSettle();
    expect(seenOwner, athlete);
    expect(seenActor, coach);
    // Appears immediately, alphabetically first in "All other exercises".
    final tiles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title as Text).data)
        .toList();
    final allOtherStart = tiles.indexOf('Aardvark Crunch');
    expect(allOtherStart, greaterThanOrEqualTo(0));
    expect(tiles.indexOf('Athlete Custom'), allOtherStart + 1);
    expect(h.repo.totalFetches, fetchesBefore, reason: 'no full reload');
  });
}
