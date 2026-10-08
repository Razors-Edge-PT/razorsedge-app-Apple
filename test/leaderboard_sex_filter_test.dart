import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/leaderboard/leaderboard_controller.dart';
import 'package:localtest222/leaderboard/leaderboard_models.dart';
import 'package:localtest222/leaderboard/leaderboard_repository.dart';
import 'package:localtest222/main.dart' show routeObserver;

import 'leaderboard_age_view_test.dart' as board;

Future<void> seedSex(
  FakeFirebaseFirestore db,
  String period,
  LeaderboardSexFilter sex,
  List<String> uids, {
  bool age = false,
}) =>
    db
        .collection(age ? kLeaderboardsAgeCollection : 'leaderboards')
        .doc('${period}_${sex.name}')
        .set(<String, Object?>{
      'sexBoardSchemaVersion': 1,
      'sexFilter': sex.name,
      'periodKey': period,
      'view': age ? 'age' : 'raw',
      'generatedAt': board.kNow.toIso8601String(),
      if (age) 'ageModelVersion': kAgeModelVersion,
      'entries': <Map<String, Object?>>[
        for (int i = 0; i < uids.length; i++)
          <String, Object?>{
            'uid': uids[i],
            'username': 'name-${uids[i]}',
            'totalPointsUnits': 3000000 - i * 10000,
            if (age) ...<String, Object?>{
              'ageModelVersion': kAgeModelVersion,
              'ageComplete': true,
              'adjustedTotalUnits': 4000000 - i * 10000,
              'rawTotalPointsUnits': 3000000 - i * 10000,
            },
          },
      ],
    });

Future<FakeFirebaseFirestore> seeded() async {
  final FakeFirebaseFirestore db = FakeFirebaseFirestore();
  await board.seedBoards(db);
  for (final String period in <String>[board.kMonth, kAllTimePeriodKey]) {
    for (final LeaderboardSexFilter sex in <LeaderboardSexFilter>[
      LeaderboardSexFilter.male,
      LeaderboardSexFilter.female,
    ]) {
      await seedSex(db, period, sex, <String>[
        '${sex.name}-first',
        '${sex.name}-second',
      ]);
      await seedSex(
          db,
          period,
          sex,
          <String>[
            '${sex.name}-second',
            '${sex.name}-first',
          ],
          age: true);
    }
  }
  return db;
}

Future<void> chooseSex(WidgetTester tester, LeaderboardSexFilter sex) async {
  await tester.tap(find.byKey(const ValueKey<String>('leaderboard-menu')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(ValueKey<String>('leaderboard-menu-${sex.name}')),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'All is checked by default; one sex at a time and age weighting compose on both periods',
    (tester) async {
      final db = await seeded();
      final c = await board.pumpBoard(tester, db);
      expect(c.sexFilter, LeaderboardSexFilter.all);
      await tester.tap(find.byKey(const ValueKey<String>('leaderboard-menu')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckedPopupMenuItem<String>>(
              find.byKey(const ValueKey<String>('leaderboard-menu-all')),
            )
            .checked,
        isTrue,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('leaderboard-menu-female')),
      );
      await tester.pumpAndSettle();
      expect(c.entries.map((e) => e.uid), <String>[
        'female-first',
        'female-second',
      ]);
      expect(c.entries.map((e) => e.rank), <int>[1, 2]);
      expect(
        find.text('Total RE Points · October 2026 · Female'),
        findsOneWidget,
      );
      await board.chooseAgeView(tester);
      expect(c.sexFilter, LeaderboardSexFilter.female);
      expect(c.entries.first.uid, 'female-second');
      await tester.tap(
        find.byKey(const ValueKey<String>('leaderboard-period-allTime')),
      );
      await tester.pumpAndSettle();
      expect(c.ageView, isTrue);
      expect(c.sexFilter, LeaderboardSexFilter.female);
      expect(c.entries.first.uid, 'female-second');
      await chooseSex(tester, LeaderboardSexFilter.male);
      expect(c.ageView, isTrue);
      expect(c.entries.first.uid, 'male-second');
      await chooseSex(tester, LeaderboardSexFilter.all);
      expect(c.ageView, isTrue);
      expect(c.sexFilter, LeaderboardSexFilter.all);
      c.dispose();
    },
  );

  testWidgets(
    'route pushes, background and disposal restore All; the options menu preserves the selection',
    (tester) async {
      final db = await seeded();
      final c = await board.pumpBoard(
        tester,
        db,
        observers: <NavigatorObserver>[routeObserver],
      );
      await chooseSex(tester, LeaderboardSexFilter.female);
      await board.chooseAgeView(tester);
      expect(c.sexFilter, LeaderboardSexFilter.female);
      final NavigatorState nav = tester.state<NavigatorState>(
        find.byType(Navigator),
      );
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('detail')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(c.sexFilter, LeaderboardSexFilter.all);
      expect(c.ageView, isFalse);
      nav.pop();
      await tester.pumpAndSettle();
      await chooseSex(tester, LeaderboardSexFilter.male);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(c.sexFilter, LeaderboardSexFilter.all);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await chooseSex(tester, LeaderboardSexFilter.female);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(c.sexFilter, LeaderboardSexFilter.all);
      c.dispose();
    },
  );

  test(
    'late filtered rows cannot replace All after a navigation reset',
    () async {
      final repo = _SlowSexRepo();
      final c = LeaderboardController(repository: repo);
      await c.start();
      final pending = c.setSexFilter(LeaderboardSexFilter.female);
      expect(c.status, LeaderboardStatus.loading);
      c.resetToRaw();
      repo.filtered.complete(
        const LeaderboardPageResult(
          entries: <LeaderboardEntry>[
            LeaderboardEntry(
              uid: 'late-female',
              rank: 1,
              totalPointsUnits: 123,
            ),
          ],
          hasMore: false,
        ),
      );
      await pending;
      expect(c.sexFilter, LeaderboardSexFilter.all);
      expect(c.entries.single.uid, 'raw');
      c.dispose();
    },
  );

  test(
      'missing or wrong-group snapshots fail rather than displaying the overall standings',
      () async {
    final db = FakeFirebaseFirestore();
    final repo = LeaderboardRepository(firestore: db, clock: () => board.kNow);
    await expectLater(
      repo.fetchSexPage(
        LeaderboardPeriod.thisMonth,
        LeaderboardSexFilter.female,
      ),
      throwsStateError,
    );
    await seedSex(db, board.kMonth, LeaderboardSexFilter.female, <String>[
      'female',
    ]);
    await db.collection('leaderboards').doc('${board.kMonth}_female').update(
      <String, Object?>{'sexFilter': 'male'},
    );
    await expectLater(
      repo.fetchSexPage(
        LeaderboardPeriod.thisMonth,
        LeaderboardSexFilter.female,
      ),
      throwsStateError,
    );
  });
}

class _SlowSexRepo extends LeaderboardRepository {
  _SlowSexRepo()
      : super(firestore: FakeFirebaseFirestore(), clock: () => board.kNow);
  final filtered = Completer<LeaderboardPageResult>();
  @override
  Future<LeaderboardPageResult> fetchPage(
    LeaderboardPeriod period, {
    Object? after,
    int startRank = 1,
    int limit = LeaderboardRepository.pageSize,
  }) async =>
      const LeaderboardPageResult(
        entries: <LeaderboardEntry>[
          LeaderboardEntry(uid: 'raw', rank: 1, totalPointsUnits: 10000),
        ],
        hasMore: false,
      );
  @override
  Future<LeaderboardPageResult> fetchSexPage(
    LeaderboardPeriod period,
    LeaderboardSexFilter sex, {
    bool ageAdjusted = false,
    int limit = LeaderboardRepository.boardSize,
  }) =>
      filtered.future;
}
