// Fresh device / app update: Block Planner 2 opens a populated pre-update
// active block with a completely empty local cache. Opening, viewing and
// leaving must write nothing; every stored exercise must be visible in
// "Current block" even though no template links it by blockId; a failed or
// incomplete load can never be persisted.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_planner_2/bp2_cache.dart';
import 'package:localtest222/block_planner_2/bp2_controller.dart';
import 'package:localtest222/block_planner_2/bp2_models.dart';
import 'package:localtest222/block_planner_2/bp2_screen.dart';
import 'package:localtest222/block_planner_2/bp2_sync_service.dart';
import 'package:localtest222/exercise_catalog.dart';
import 'package:localtest222/user_context.dart';
import 'package:provider/provider.dart';

import '../support/pre_update_block_fixture.dart';
import 'bp2_test_support.dart';

class _FailingBlockRepo extends CountingRepo {
  _FailingBlockRepo(super.db);
  @override
  Future<Bp2BlockRecord?> fetchBlock(String uid, String blockId) async =>
      throw StateError('unavailable: offline with no cache');
}

class _FailingCatalogueRepo extends CountingRepo {
  _FailingCatalogueRepo(super.db);
  @override
  Future<int> countGlobalExercises() async =>
      throw StateError('unavailable: offline with no cache');
  @override
  Future<List<CatalogExercise>> fetchGlobalExercises() async =>
      throw StateError('unavailable: offline with no cache');
}

void main() {
  UserContext athleteContext() {
    final uc = UserContext(actorUid: kFxAthlete, isCoach: false);
    uc.debugSetBlockMeta(activeBlockId: kFxActive);
    return uc;
  }

  Future<void> openAndLeave(
    WidgetTester tester,
    Bp2Controller controller, {
    required void Function() afterOpen,
  }) async {
    tester.view.physicalSize = const Size(412, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<UserContext>.value(
      value: athleteContext(),
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    Bp2Screen(blockId: kFxActive, controller: controller),
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    afterOpen();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text(Bp2Screen.title), findsNothing, reason: 'left the page');
  }

  for (final allAvailable in [false, true]) {
    final shape = allAvailable ? 'allExercisesAvailable' : 'membership arrays';

    testWidgets(
        '[$shape] fresh cache: open + leave writes nothing, every stored '
        'exercise is in Current block', (tester) async {
      final h = Harness();
      await seedPreUpdateBlock(h.db, allExercisesAvailable: allAvailable);
      final before = h.db.dump();

      await openAndLeave(tester, h.controller, afterOpen: () {
        final current =
            h.controller.grouping.currentBlock.map((e) => e.id).toSet();
        expect(current, kFxMembers.toSet(),
            reason: 'exerciseSettings keys ∪ template-linked (none here)');
        expect(current.contains(kFxUnused), isFalse);
        for (final id in kFxMembers) {
          expect(find.byKey(ValueKey('bp2-tile-$id')), findsOneWidget,
              reason: '$id visible');
        }
        expect(h.controller.isDirty, isFalse, reason: 'viewing is not an edit');
      });

      expect(h.db.dump(), before,
          reason: 'update/startup, open and leave performed zero writes');
    });
  }

  testWidgets('a failed block load shows the error and can never be saved',
      (tester) async {
    final h = Harness();
    await seedPreUpdateBlock(h.db);
    final repo = _FailingBlockRepo(h.db);
    final controller = Bp2Controller(
      sync: Bp2SyncService(
          repo: repo, cache: Bp2MemoryCacheStore(), now: () => h.now),
      repo: repo,
      now: () => h.now,
      draftDebounce: Duration.zero,
    );
    final before = h.db.dump();

    await openAndLeave(tester, controller, afterOpen: () {
      expect(find.byKey(const ValueKey('bp2-load-error')), findsOneWidget);
      final save =
          tester.widget<TextButton>(find.byKey(const ValueKey('bp2-save')));
      expect(save.onPressed, isNull, reason: 'Save is disabled');
    });
    expect((await controller.save()).success, isFalse);
    expect(h.db.dump(), before);
  });

  testWidgets(
      'a temporarily empty catalogue (offline) never persists: open, Save, '
      'leave → zero writes', (tester) async {
    final h = Harness();
    await seedPreUpdateBlock(h.db, allExercisesAvailable: true);
    final repo = _FailingCatalogueRepo(h.db);
    final controller = Bp2Controller(
      sync: Bp2SyncService(
          repo: repo, cache: Bp2MemoryCacheStore(), now: () => h.now),
      repo: repo,
      now: () => h.now,
      draftDebounce: Duration.zero,
    );
    final before = h.db.dump();

    await openAndLeave(tester, controller, afterOpen: () {
      expect(controller.catalogueLoaded, isFalse);
      // Stored exercises stay visible as id rows even without the catalogue.
      expect(controller.grouping.currentBlock.map((e) => e.id).toSet(),
          kFxMembers.toSet());
    });
    expect((await controller.save()).nothingToSave, isTrue);
    expect(h.db.dump(), before);
  });
}
