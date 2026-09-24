// The leaderboard repository (server-ordered, paginated query) and its
// controller (period selection, paging, loading / empty / error states).

import 'dart:async';
import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/leaderboard/leaderboard_controller.dart';
import 'package:localtest222/leaderboard/leaderboard_models.dart';
import 'package:localtest222/leaderboard/leaderboard_repository.dart';

final DateTime kNow = DateTime(2026, 9, 24, 10);

Future<void> seed(FakeFirebaseFirestore db, String period,
    List<Map<String, Object?>> rows) async {
  for (final Map<String, Object?> r in rows) {
    await db
        .collection('leaderboards')
        .doc(period)
        .collection('entries')
        .doc(r['uid']! as String)
        .set(r);
  }
}

Map<String, Object?> row(String uid, int units, String tie,
        {String? username, String? photoURL}) =>
    <String, Object?>{
      'uid': uid,
      'totalPointsUnits': units,
      'tieBreakDateKey': tie,
      'username': username ?? uid,
      if (photoURL != null) 'photoURL': photoURL,
    };

/// A repository whose pages are scripted.
class _ScriptedRepo extends LeaderboardRepository {
  _ScriptedRepo(this.pages)
      : super(firestore: FakeFirebaseFirestore(), clock: () => kNow);

  final Map<LeaderboardPeriod, List<Future<LeaderboardPageResult> Function()>>
      pages;
  final List<LeaderboardPeriod> calls = <LeaderboardPeriod>[];

  @override
  Future<LeaderboardPageResult> fetchPage(LeaderboardPeriod period,
      {Object? after,
      int startRank = 1,
      int limit = LeaderboardRepository.pageSize}) {
    calls.add(period);
    final List<Future<LeaderboardPageResult> Function()> list = pages[period]!;
    final int n = calls.where((LeaderboardPeriod p) => p == period).length - 1;
    return list[n < list.length ? n : list.length - 1]();
  }
}

LeaderboardPageResult page(List<String> uids,
        {bool hasMore = false, int start = 1}) =>
    LeaderboardPageResult(
      entries: <LeaderboardEntry>[
        for (int i = 0; i < uids.length; i++)
          LeaderboardEntry(
              uid: uids[i],
              rank: start + i,
              totalPointsUnits: 10000 * (10 - i),
              username: uids[i]),
      ],
      hasMore: hasMore,
    );

void main() {
  group('models', () {
    test(
        'points are formatted from integer units, two decimals, no float drift',
        () {
      expect(formatRePointUnits(0), '0.00');
      expect(formatRePointUnits(1234567), '123.46');
      expect(formatRePointUnits(1234549), '123.45');
      expect(formatRePointUnits(10000), '1.00');
      expect(formatRePointUnits(999950), '100.00');
    });

    test('units per point match the server (functions/leaderboard/reducer.js)',
        () {
      final String js =
          File('functions/leaderboard/reducer.js').readAsStringSync();
      final RegExpMatch m =
          RegExp(r'const POINT_UNITS = (\d+);').firstMatch(js)!;
      expect(int.parse(m.group(1)!), kRePointUnits);
      expect(
          js.contains("const ALL_TIME_PERIOD = '$kAllTimePeriodKey';"), isTrue);
    });

    test('period keys: local calendar month, and all_time', () {
      expect(
          periodKeyFor(
              LeaderboardPeriod.thisMonth, DateTime(2026, 9, 30, 23, 59)),
          '2026-09');
      expect(
          periodKeyFor(
              LeaderboardPeriod.thisMonth, DateTime(2026, 10, 1, 0, 1)),
          '2026-10');
      expect(periodKeyFor(LeaderboardPeriod.allTime, kNow), 'all_time');
      expect(describeMonthKey('2026-09'), 'September 2026');
    });

    test('an entry without a username falls back to a neutral name', () {
      final LeaderboardEntry e = LeaderboardEntry.fromMap(
          'u1', <String, dynamic>{'totalPointsUnits': 5},
          rank: 1)!;
      expect(e.uid, 'u1');
      expect(e.displayName, isNotEmpty);
      expect(
          LeaderboardEntry.fromMap('u', <String, dynamic>{}, rank: 1), isNull);
    });
  });

  group('repository', () {
    test('ranks by points desc, earlier tie date, then uid; excludes zero',
        () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seed(db, '2026-09', <Map<String, Object?>>[
        row('c', 500, '2026-09-02'),
        row('a', 500, '2026-09-02'),
        row('b', 500, '2026-09-01'),
        row('d', 900, '2026-09-20'),
        row('z', 0, '2026-09-20'),
      ]);
      final LeaderboardRepository repo =
          LeaderboardRepository(firestore: db, clock: () => kNow);
      final LeaderboardPageResult p =
          await repo.fetchPage(LeaderboardPeriod.thisMonth);
      expect(p.entries.map((LeaderboardEntry e) => e.uid),
          <String>['d', 'b', 'a', 'c']);
      expect(p.entries.map((LeaderboardEntry e) => e.rank), <int>[1, 2, 3, 4]);
    });

    // Cursor continuation itself (startAfterDocument over this multi-field
    // order) is exercised against the real query engine in
    // functions/test-emulator/leaderboard.spec.js; fake_cloud_firestore does
    // not implement cursors over an inequality plus several orderBys.
    test('a full page reports more and hands back its last row as the cursor',
        () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seed(db, 'all_time', <Map<String, Object?>>[
        for (int i = 0; i < 5; i++) row('u$i', 1000 - i, '2026-01-01'),
      ]);
      final LeaderboardRepository repo =
          LeaderboardRepository(firestore: db, clock: () => kNow);
      final LeaderboardPageResult first =
          await repo.fetchPage(LeaderboardPeriod.allTime, limit: 2);
      expect(first.hasMore, isTrue);
      expect(first.entries.map((LeaderboardEntry e) => '${e.rank}:${e.uid}'),
          <String>['1:u0', '2:u1']);
      expect((first.cursor! as dynamic).id, 'u1');
      final LeaderboardPageResult all = await repo
          .fetchPage(LeaderboardPeriod.allTime, limit: 50, startRank: 1);
      expect(all.hasMore, isFalse);
      expect(all.entries.length, 5);
    });

    test('This Month and All Time query different periods', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seed(db, '2026-09',
          <Map<String, Object?>>[row('month', 10, '2026-09-02')]);
      await seed(
          db, '2026-08', <Map<String, Object?>>[row('old', 99, '2026-08-02')]);
      await seed(db, 'all_time',
          <Map<String, Object?>>[row('ever', 20, '2026-01-02')]);
      final LeaderboardRepository repo =
          LeaderboardRepository(firestore: db, clock: () => kNow);
      expect(
          (await repo.fetchPage(LeaderboardPeriod.thisMonth))
              .entries
              .single
              .uid,
          'month');
      expect(
          (await repo.fetchPage(LeaderboardPeriod.allTime)).entries.single.uid,
          'ever');
    });
  });

  group('controller', () {
    test('defaults to This Month', () {
      final LeaderboardController c = LeaderboardController(
          repository: LeaderboardRepository(
              firestore: FakeFirebaseFirestore(), clock: () => kNow));
      expect(c.period, LeaderboardPeriod.thisMonth);
      expect(c.periodKey, '2026-09');
    });

    test(
        'switching period changes the query and result; switching back does not refetch',
        () async {
      final _ScriptedRepo repo = _ScriptedRepo(<LeaderboardPeriod,
          List<Future<LeaderboardPageResult> Function()>>{
        LeaderboardPeriod.thisMonth: <Future<LeaderboardPageResult> Function()>[
          () async => page(<String>['m1'])
        ],
        LeaderboardPeriod.allTime: <Future<LeaderboardPageResult> Function()>[
          () async => page(<String>['a1', 'a2'])
        ],
      });
      final LeaderboardController c = LeaderboardController(repository: repo);
      await c.start();
      expect(c.entries.map((LeaderboardEntry e) => e.uid), <String>['m1']);
      await c.selectPeriod(LeaderboardPeriod.allTime);
      expect(
          c.entries.map((LeaderboardEntry e) => e.uid), <String>['a1', 'a2']);
      await c.selectPeriod(LeaderboardPeriod.thisMonth);
      expect(c.entries.single.uid, 'm1');
      expect(repo.calls, <LeaderboardPeriod>[
        LeaderboardPeriod.thisMonth,
        LeaderboardPeriod.allTime
      ]);
    });

    test('empty, error and retry states', () async {
      int n = 0;
      final _ScriptedRepo repo = _ScriptedRepo(<LeaderboardPeriod,
          List<Future<LeaderboardPageResult> Function()>>{
        LeaderboardPeriod.thisMonth: <Future<LeaderboardPageResult> Function()>[
          () async => throw StateError('offline'),
          () async => page(<String>['x']),
        ],
        LeaderboardPeriod.allTime: <Future<LeaderboardPageResult> Function()>[
          () async {
            n++;
            return page(<String>[]);
          },
        ],
      });
      final LeaderboardController c = LeaderboardController(repository: repo);
      await c.start();
      expect(c.status, LeaderboardStatus.error);
      await c.retry();
      expect(c.status, LeaderboardStatus.ready);
      await c.selectPeriod(LeaderboardPeriod.allTime);
      expect(c.status, LeaderboardStatus.empty);
      expect(n, 1);
    });

    test('load more appends the next page once', () async {
      final _ScriptedRepo repo = _ScriptedRepo(<LeaderboardPeriod,
          List<Future<LeaderboardPageResult> Function()>>{
        LeaderboardPeriod.thisMonth: <Future<LeaderboardPageResult> Function()>[
          () async => page(<String>['a', 'b'], hasMore: true),
          () async => page(<String>['c'], start: 3),
        ],
        LeaderboardPeriod.allTime: <Future<LeaderboardPageResult> Function()>[
          () async => page(<String>[])
        ],
      });
      final LeaderboardController c = LeaderboardController(repository: repo);
      await c.start();
      await Future.wait(<Future<void>>[c.loadMore(), c.loadMore()]);
      expect(c.entries.map((LeaderboardEntry e) => e.uid),
          <String>['a', 'b', 'c']);
      expect(c.hasMore, isFalse);
      expect(repo.calls.length, 2);
    });

    test('a stale response for a superseded load is discarded', () async {
      final Completer<LeaderboardPageResult> slow =
          Completer<LeaderboardPageResult>();
      final _ScriptedRepo repo = _ScriptedRepo(<LeaderboardPeriod,
          List<Future<LeaderboardPageResult> Function()>>{
        LeaderboardPeriod.thisMonth: <Future<LeaderboardPageResult> Function()>[
          () => slow.future,
          () async => page(<String>['fresh']),
        ],
        LeaderboardPeriod.allTime: <Future<LeaderboardPageResult> Function()>[
          () async => page(<String>[])
        ],
      });
      final LeaderboardController c = LeaderboardController(repository: repo);
      final Future<void> first = c.start();
      await c.retry();
      slow.complete(page(<String>['stale']));
      await first;
      expect(c.entries.single.uid, 'fresh');
    });
  });
}
