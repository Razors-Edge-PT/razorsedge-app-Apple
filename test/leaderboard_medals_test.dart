// Leaderboard category medals in the app: parsing the server snapshot,
// attaching awards to rows by uid, the vector medal strip, the detail sheet,
// tap separation from profile navigation, board switching, paging, cached
// medals, and narrow / large-text layouts.

import 'dart:async';
import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/leaderboard/leaderboard_controller.dart';
import 'package:localtest222/leaderboard/leaderboard_medals.dart';
import 'package:localtest222/leaderboard/leaderboard_models.dart';
import 'package:localtest222/leaderboard/leaderboard_repository.dart';
import 'package:localtest222/leaderboard/leaderboard_view.dart';
import 'package:localtest222/leaderboard/medal_badge.dart';
import 'package:localtest222/leaderboard/medal_row_layout.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';
import 'package:localtest222/social/buddy_repository.dart';

const String kMe = 'me';
final DateTime kNow = DateTime(2026, 9, 24, 10);
const String kBench = 'AmfUWbF1DH3I7qPAdh5k';

const List<String> kCats = <String>[
  'horizontalPress',
  'verticalPull',
  'overheadPress',
  'hipHinge',
  'squatPattern',
];

class _AbsentStore implements ProfileImageStore {
  @override
  Future<File?> cached(String url, {String? key}) async => null;

  @override
  Future<File> download(String url, {String? key}) =>
      Future<File>.error(const SocketException('offline in tests'));

  @override
  Future<void> evict(String key) async {}
}

Map<String, Object?> award(String uid, int place, int units,
        {String date = '2026-09-10', String? exerciseId}) =>
    <String, Object?>{
      'uid': uid,
      'place': place,
      'pointsUnits': units,
      'achievedDateKey': date,
      if (exerciseId != null) 'exerciseId': exerciseId,
      if (exerciseId != null) 'recordDateKey': date,
    };

Map<String, Object?> snapshot(String period, Map<String, List<Object?>> cats,
        {int revision = 1}) =>
    <String, Object?>{
      'schema': 'leaderboardMedals',
      'schemaVersion': 1,
      'periodKey': period,
      'boardType': period == 'all_time' ? 'allTime' : 'month',
      'revision': revision,
      'categories': <String, Object?>{
        for (final String c in kCats) c: cats[c] ?? <Object?>[],
      },
    };

Future<void> seedEntries(
    FakeFirebaseFirestore db, String period, List<String> uids,
    {String Function(String uid)? name}) async {
  int units = 9000000;
  for (final String uid in uids) {
    units -= 10000;
    await db
        .collection('leaderboards')
        .doc(period)
        .collection('entries')
        .doc(uid)
        .set(<String, Object?>{
      'uid': uid,
      'username': name == null ? 'name-$uid' : name(uid),
      'totalPointsUnits': units,
      'tieBreakDateKey': '2026-09-10',
    });
  }
}

Future<void> seedMedals(FakeFirebaseFirestore db, String period,
        Map<String, List<Object?>> cats) =>
    db
        .collection(kLeaderboardMedalsCollection)
        .doc(period)
        .set(snapshot(period, cats));

/// The viewer is friends with everyone, so every row opens its profile.
Future<BuddyRepository> friendsWithAll(
    FakeFirebaseFirestore db, List<String> uids) async {
  await db.collection('socialGraph').doc(kMe).set(<String, Object?>{
    'friends': uids,
  });
  return BuddyRepository(firestore: db, overrideUid: kMe);
}

void main() {
  setUp(() => profileImageStore = _AbsentStore());
  tearDown(resetProfileImageCache);

  group('snapshot parsing', () {
    test('awards attach by uid, in fixed category order, one per place', () {
      final LeaderboardMedals m = LeaderboardMedals.fromMap(
          '2026-09',
          snapshot('2026-09', <String, List<Object?>>{
            'squatPattern': <Object?>[award('a', 1, 10)],
            'horizontalPress': <Object?>[award('a', 2, 5), award('b', 1, 9)],
            'hipHinge': <Object?>[award('a', 3, 1)],
          }));
      expect(m.forUid('a').map((x) => x.code), <String>['BP', 'DL', 'SQ']);
      expect(m.forUid('a').map((x) => x.tier), <MedalTier>[
        MedalTier.silver,
        MedalTier.bronze,
        MedalTier.gold,
      ]);
      expect(m.forUid('b').single.tier, MedalTier.gold);
      expect(m.forUid('nobody'), isEmpty);
    });

    test('malformed, duplicate, zero and foreign awards are dropped', () {
      final LeaderboardMedals m = LeaderboardMedals.fromMap(
          '2026-09',
          snapshot('2026-09', <String, List<Object?>>{
            'horizontalPress': <Object?>[
              award('a', 1, 10),
              award('b', 1, 9), // second gold
              award('a', 2, 8), // second medal for a
              award('c', 4, 7), // no such place
              award('d', 2, 0), // zero score
              'garbage',
              <String, Object?>{'uid': 'e', 'place': 3},
            ],
          }));
      expect(m.forUid('a').length, 1);
      for (final String u in <String>['b', 'c', 'd', 'e']) {
        expect(m.forUid(u), isEmpty, reason: u);
      }
      expect(LeaderboardMedals.fromMap('2026-09', null).isEmpty, isTrue);
      expect(
          LeaderboardMedals.fromMap('2026-09', snapshot('2026-08', {})).isEmpty,
          isTrue,
          reason: 'another board');
      expect(
          LeaderboardMedals.fromMap('2026-09', <String, dynamic>{'schema': 'x'})
              .isEmpty,
          isTrue);
    });

    test('semantics say placement, full category and the score', () {
      final LeaderboardMedal month = LeaderboardMedals.fromMap(
          '2026-09',
          snapshot('2026-09', <String, List<Object?>>{
            'horizontalPress': <Object?>[award('a', 1, 8423500)],
          })).forUid('a').single;
      expect(month.semanticsLabel,
          'Gold medal, Horizontal Press, 842.35 monthly RE Points');
      final LeaderboardMedal at = LeaderboardMedals.fromMap(
          'all_time',
          snapshot('all_time', <String, List<Object?>>{
            'overheadPress': <Object?>[award('a', 3, 1742800)],
          })).forUid('a').single;
      expect(at.semanticsLabel,
          'Bronze medal, Overhead Press / Dip, 174.28 all-time best RE Points');
      expect(describeDateKey('2026-09-07'), '7 Sep 2026');
      expect(describeDateKey('bad'), isNull);
    });
  });

  group('leaderboard rows', () {
    Future<List<String>> pumpBoard(
      WidgetTester tester,
      FakeFirebaseFirestore db, {
      Size size = const Size(400, 1600),
      double textScale = 1.0,
      List<String> friends = const <String>['a', 'b', 'c', 'd', 'long'],
      LeaderboardRepository? repo,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final List<String> opened = <String>[];
      final BuddyRepository buddies = await friendsWithAll(db, friends);
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
              size: size, textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: LeaderboardView(
                repository: repo ??
                    LeaderboardRepository(firestore: db, clock: () => kNow),
                buddies: buddies,
                onOpenProfile: opened.add,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return opened;
    }

    Finder medal(String uid, String cat) =>
        find.byKey(ValueKey<String>('leaderboard-medal-$uid-$cat'));
    Finder row(String uid) =>
        find.byKey(ValueKey<String>('leaderboard-row-$uid'));

    testWidgets('no medals: no medal layout; medals add no row height',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedEntries(db, '2026-09', <String>['a', 'b']);
      await seedMedals(db, '2026-09', <String, List<Object?>>{
        'horizontalPress': <Object?>[award('a', 1, 100)],
      });
      await pumpBoard(tester, db);
      expect(find.byType(MedalRowLayout), findsOneWidget);
      expect(
          find.descendant(of: row('b'), matching: find.byType(MedalRowLayout)),
          findsNothing);
      // b's row is exactly as tall as a row always was — and so is a's.
      expect(tester.getSize(row('b')).height, 56);
      expect(tester.getSize(row('a')).height, 56);
    });

    testWidgets(
        'one medal, five medals, mixed metals, fixed BP VP OH DL SQ order',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedEntries(db, '2026-09', <String>['a', 'b', 'c']);
      await seedMedals(db, '2026-09', <String, List<Object?>>{
        'squatPattern': <Object?>[award('a', 3, 1), award('b', 1, 9)],
        'hipHinge': <Object?>[award('a', 2, 5)],
        'overheadPress': <Object?>[award('a', 1, 7)],
        'verticalPull': <Object?>[award('a', 1, 7)],
        'horizontalPress': <Object?>[award('a', 1, 70)],
      });
      await pumpBoard(tester, db);
      final List<double> xs = <double>[
        for (final String c in kCats) tester.getTopLeft(medal('a', c)).dx,
      ];
      expect(xs, List<double>.of(xs)..sort(), reason: 'category order');
      final List<LeaderboardMedal> badges = tester
          .widgetList<MedalButton>(
              find.descendant(of: row('a'), matching: find.byType(MedalButton)))
          .map((MedalButton b) => b.medal)
          .toList();
      expect(badges.map((b) => b.code), <String>['BP', 'VP', 'OH', 'DL', 'SQ']);
      expect(badges.map((b) => b.tier), <MedalTier>[
        MedalTier.gold,
        MedalTier.gold,
        MedalTier.gold,
        MedalTier.silver,
        MedalTier.bronze,
      ]);
      // Evenly pitched, coins no larger than the preferred 26.5 px square.
      final double pitch = xs[1] - xs[0];
      for (int i = 2; i < xs.length; i++) {
        expect(xs[i] - xs[i - 1], moreOrLessEquals(pitch));
      }
      expect(tester.getSize(medal('a', 'horizontalPress')).width,
          lessThanOrEqualTo(kMedalCoinSide));
      expect(find.descendant(of: row('b'), matching: find.byType(MedalButton)),
          findsOneWidget);
      expect(find.descendant(of: row('c'), matching: find.byType(MedalButton)),
          findsNothing);
      // One medal gets the full coin.
      expect(tester.getSize(medal('b', 'squatPattern')),
          const Size.square(kMedalCoinSide));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'medal tap opens its detail, never the profile; row tap still opens',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedEntries(db, '2026-09', <String>['a', 'b']);
      await seedMedals(db, '2026-09', <String, List<Object?>>{
        'horizontalPress': <Object?>[award('a', 1, 8423500)],
      });
      final List<String> opened = await pumpBoard(tester, db);
      await tester.tap(medal('a', 'horizontalPress'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(
          find.byKey(const ValueKey<String>('medal-detail')), findsOneWidget);
      expect(find.text('Gold — Horizontal Press'), findsOneWidget);
      expect(find.text('September 2026 category total: 842.35 RE Points'),
          findsOneWidget);
      expect(
          find.textContaining(
              'winning Horizontal Press score on each training day'),
          findsOneWidget);
      // Close, then tap the row away from the medal (on the name).
      Navigator.of(tester
              .element(find.byKey(const ValueKey<String>('medal-detail'))))
          .pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('name-a'));
      await tester.pumpAndSettle();
      expect(opened, <String>['a']);
      await tester.tap(find.text('name-b'));
      expect(opened, <String>['a', 'b']);
    });

    testWidgets(
        'all-time detail: best single score, winning exercise, set and date',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedEntries(db, 'all_time', <String>['a']);
      await seedMedals(db, 'all_time', <String, List<Object?>>{
        'horizontalPress': <Object?>[
          award('a', 1, 1742800, date: '2026-09-12', exerciseId: kBench),
        ],
      });
      await db.collection('users_public').doc('a').set(<String, Object?>{
        'username': 'name-a',
        'profileShowcaseV2': <String, Object?>{
          'schema': 'profileShowcaseV2',
          'categories': <String, Object?>{
            'horizontalPress': <String, Object?>{
              'bestExerciseId': kBench,
              'exercises': <String, Object?>{
                kBench: <String, Object?>{
                  'slot': 'bench',
                  'exerciseId': kBench,
                  'rePoints': 174.28,
                  'points': <String, Object?>{
                    'slot': 'bench',
                    'exerciseId': kBench,
                    'dateKey': '2026-09-12',
                    'setKey': 's0',
                    'weight': 158.5,
                    'reps': 9,
                    'e1rm': 200.0,
                    'formulaVersion': 1,
                    'fingerprint': 'fp',
                  },
                },
              },
            },
          },
        },
      });
      await pumpBoard(tester, db);
      await tester.tap(
          find.byKey(const ValueKey<String>('leaderboard-period-allTime')));
      await tester.pumpAndSettle();
      await tester.tap(medal('a', 'horizontalPress'));
      await tester.pumpAndSettle();
      expect(find.text('Gold — Horizontal Press'), findsOneWidget);
      expect(find.text('Best single score: 174.28 RE Points'), findsOneWidget);
      expect(find.text('Bench Press, Barbell — 158.5 kg × 9'), findsOneWidget);
      expect(find.text('12 Sep 2026'), findsOneWidget);
    });

    testWidgets(
        'all-time detail omits the set line when the public record no longer matches',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedEntries(db, 'all_time', <String>['a']);
      await seedMedals(db, 'all_time', <String, List<Object?>>{
        'horizontalPress': <Object?>[
          award('a', 1, 1742800, exerciseId: kBench),
        ],
      });
      await pumpBoard(tester, db);
      await tester.tap(
          find.byKey(const ValueKey<String>('leaderboard-period-allTime')));
      await tester.pumpAndSettle();
      await tester.tap(medal('a', 'horizontalPress'));
      await tester.pumpAndSettle();
      expect(find.text('Bench Press, Barbell'), findsOneWidget);
    });

    testWidgets('This Month and All Time each use their own board\'s medals',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedEntries(db, '2026-09', <String>['a', 'b']);
      await seedEntries(db, 'all_time', <String>['a', 'b']);
      await seedMedals(db, '2026-09', <String, List<Object?>>{
        'hipHinge': <Object?>[award('a', 1, 5)],
      });
      await seedMedals(db, 'all_time', <String, List<Object?>>{
        'hipHinge': <Object?>[award('b', 1, 5)],
      });
      await pumpBoard(tester, db);
      expect(medal('a', 'hipHinge'), findsOneWidget);
      expect(medal('b', 'hipHinge'), findsNothing);
      await tester.tap(
          find.byKey(const ValueKey<String>('leaderboard-period-allTime')));
      await tester.pumpAndSettle();
      expect(medal('a', 'hipHinge'), findsNothing);
      expect(medal('b', 'hipHinge'), findsOneWidget);
      await tester.tap(
          find.byKey(const ValueKey<String>('leaderboard-period-thisMonth')));
      await tester.pump();
      expect(medal('a', 'hipHinge'), findsOneWidget,
          reason: 'kept, immediately');
    });

    testWidgets('a medallist on a later page gets their medal after Show more',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final List<String> uids = <String>[for (int i = 0; i < 55; i++) 'u$i'];
      await seedMedals(db, '2026-09', <String, List<Object?>>{
        'squatPattern': <Object?>[award('u53', 1, 5)],
      });
      // Pages are scripted (the fake's cursor paging of this query is not
      // supported); the medals come from the real snapshot read.
      await pumpBoard(tester, db,
          size: const Size(400, 5000),
          friends: uids,
          repo: _PagedRepo(db, uids));
      expect(row('u53'), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('leaderboard-more')));
      await tester.pumpAndSettle();
      expect(medal('u53', 'squatPattern'), findsOneWidget);
    });

    testWidgets(
        '320 px with five medals, a long name and no avatar: no overflow, no extra height',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedEntries(db, '2026-09', <String>['long', 'b'],
          name: (String u) =>
              u == 'long' ? 'averyveryverylongusernamethatneverends' : 'b');
      await seedMedals(db, '2026-09', <String, List<Object?>>{
        for (final String c in kCats) c: <Object?>[award('long', 1, 5)],
      });
      await pumpBoard(tester, db, size: const Size(320, 1400));
      expect(tester.takeException(), isNull);
      final Finder strip =
          find.byKey(const ValueKey<String>('leaderboard-medals-long'));
      final Rect r = tester.getRect(row('long'));
      expect(r.height, 56, reason: 'the medal-less row height');
      // Five medals, all inside the row, left of the points.
      final Rect pts = tester.getRect(find.text('899.00'));
      final List<Rect> coins = <Rect>[
        for (final Element e in find
            .descendant(of: strip, matching: find.byType(MedalButton))
            .evaluate())
          tester.getRect(find.byWidget(e.widget)),
      ];
      expect(coins, hasLength(5));
      for (final Rect c in coins) {
        expect(r.contains(c.topLeft) && r.contains(c.bottomRight), isTrue);
        expect(c.right, lessThanOrEqualTo(pts.left));
        expect(c.width, greaterThan(0));
      }
      // Points are still fully visible.
      expect(r.contains(pts.topLeft) && r.contains(pts.bottomRight), isTrue);
      expect(
          find.text('averyveryverylongusernamethatneverends'), findsOneWidget);
    });

    testWidgets('large text: rows with medals still lay out',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedEntries(db, '2026-09', <String>['a']);
      await seedMedals(db, '2026-09', <String, List<Object?>>{
        for (final String c in kCats) c: <Object?>[award('a', 2, 5)],
      });
      await pumpBoard(tester, db, size: const Size(320, 1600), textScale: 2.0);
      expect(tester.takeException(), isNull);
      expect(find.byType(MedalButton), findsNWidgets(5));
    });

    testWidgets(
        'medals are reachable buttons with full semantics and a tap area wider than the coin',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedEntries(db, '2026-09', <String>['a']);
      await seedMedals(db, '2026-09', <String, List<Object?>>{
        'horizontalPress': <Object?>[award('a', 1, 8423500)],
      });
      await pumpBoard(tester, db);
      expect(
          find.bySemanticsLabel(
              'Gold medal, Horizontal Press, 842.35 monthly RE Points'),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Rank 1, name-a, .*1 medal$')),
          findsOneWidget);
      // A tap just beside the coin, inside its cell, is still the medal's.
      final RenderMedalRowLayout layout = tester.renderObject(
          find.byKey(const ValueKey<String>('leaderboard-medals-a')));
      final Rect cell = layout.debugCells.single;
      expect(cell.height, greaterThan(kMedalCoinSide),
          reason: 'the cell spans the free line height');
      final Rect coin = tester.getRect(medal('a', 'horizontalPress'));
      expect(cell.width, greaterThan(coin.width));
      handle.dispose();
    });
  });

  group('controller', () {
    test(
        'medals load beside the first page and survive a failed refresh (cached)',
        () async {
      final _ScriptedMedals repo = _ScriptedMedals();
      final LeaderboardController c = LeaderboardController(repository: repo);
      await c.start();
      await pumpEventQueue();
      expect(c.medalsFor('a').single.tier, MedalTier.gold);
      expect(c.medals!.isFromCache, isTrue);
      repo.fail = true;
      await c.refresh();
      await pumpEventQueue();
      expect(c.status, LeaderboardStatus.ready);
      expect(c.medalsFor('a').single.tier, MedalTier.gold,
          reason: 'last loaded medals stay available offline');
      c.dispose();
    });

    test('a slow medal snapshot never blocks the rows', () async {
      final _ScriptedMedals repo = _ScriptedMedals()..gate = Completer<void>();
      final LeaderboardController c = LeaderboardController(repository: repo);
      await c.start();
      expect(c.status, LeaderboardStatus.ready);
      expect(c.medalsFor('a'), isEmpty);
      repo.gate!.complete();
      await pumpEventQueue();
      expect(c.medalsFor('a'), isNotEmpty);
      c.dispose();
    });
  });
}

/// Pages of [uids] in order; medals from the real repository read.
class _PagedRepo extends LeaderboardRepository {
  _PagedRepo(FakeFirebaseFirestore db, this.uids)
      : super(firestore: db, clock: () => kNow);

  final List<String> uids;

  @override
  Future<LeaderboardPageResult> fetchPage(LeaderboardPeriod period,
      {Object? after,
      int startRank = 1,
      int limit = LeaderboardRepository.pageSize}) async {
    final int from = after is int ? after : 0;
    final int to = (from + limit).clamp(0, uids.length);
    return LeaderboardPageResult(
      entries: <LeaderboardEntry>[
        for (int i = from; i < to; i++)
          LeaderboardEntry(
              uid: uids[i],
              rank: i + 1,
              totalPointsUnits: 1000000 - i,
              username: 'name-${uids[i]}'),
      ],
      hasMore: to < uids.length,
      cursor: to,
    );
  }
}

class _ScriptedMedals extends LeaderboardRepository {
  _ScriptedMedals()
      : super(firestore: FakeFirebaseFirestore(), clock: () => kNow);

  bool fail = false;
  Completer<void>? gate;

  @override
  Future<LeaderboardPageResult> fetchPage(LeaderboardPeriod period,
      {Object? after,
      int startRank = 1,
      int limit = LeaderboardRepository.pageSize}) async {
    return LeaderboardPageResult(entries: <LeaderboardEntry>[
      const LeaderboardEntry(uid: 'a', rank: 1, totalPointsUnits: 10),
    ], hasMore: false);
  }

  @override
  Future<LeaderboardMedals> fetchMedals(LeaderboardPeriod period) async {
    if (gate != null) await gate!.future;
    if (fail) throw StateError('offline');
    return LeaderboardMedals.fromMap(
        '2026-09',
        snapshot('2026-09', <String, List<Object?>>{
          'horizontalPress': <Object?>[award('a', 1, 10)],
        }),
        isFromCache: true);
  }
}
