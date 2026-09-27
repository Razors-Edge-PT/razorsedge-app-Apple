// Medal rows keep the leaderboard row's PRE-MEDAL vertical footprint.
//
// The baseline is the real pre-medal implementation (7e016c89^), frozen in
// test/support/pre_medal_leaderboard_row.dart — never an estimate. Every
// comparison renders both rows under identical conditions.

import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/leaderboard/leaderboard_medals.dart';
import 'package:localtest222/leaderboard/leaderboard_models.dart';
import 'package:localtest222/leaderboard/leaderboard_repository.dart';
import 'package:localtest222/leaderboard/leaderboard_view.dart';
import 'package:localtest222/leaderboard/medal_badge.dart';
import 'package:localtest222/leaderboard/medal_row_layout.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';
import 'package:localtest222/social/buddy_repository.dart';

import 'support/pre_medal_leaderboard_row.dart';

const String kMe = 'me';
final DateTime kNow = DateTime(2026, 9, 24, 10);

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

List<LeaderboardMedal> medalsFor(String uid, int n,
        {String period = '2026-09'}) =>
    <LeaderboardMedal>[
      for (int i = 0; i < n; i++)
        LeaderboardMedal(
          uid: uid,
          tier: MedalTier.values[i % 3],
          categoryKey: kCats[i],
          pointsUnits: 10000 * (i + 1),
          periodKey: period,
        ),
    ];

// '8.99': under the test font (every glyph 1 em wide) this is about as wide
// as a real '899.40' in Monda, so the frozen row is not squeezed unrealistically.
const LeaderboardEntry kEntry = LeaderboardEntry(
    uid: 'a',
    rank: 12,
    totalPointsUnits: 89940,
    username: 'averyverylongusername');

/// Records every circle a painter draws.
class _CircleLog implements Canvas {
  final List<(Offset, double)> circles = <(Offset, double)>[];

  @override
  void drawCircle(Offset c, double radius, Paint paint) =>
      circles.add((c, radius));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  setUp(() => profileImageStore = _AbsentStore());
  tearDown(resetProfileImageCache);

  Future<void> pumpRows(
    WidgetTester tester, {
    required double width,
    double textScale = 1.0,
    required List<Widget> rows,
  }) async {
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
            size: Size(width, 2400), textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(children: rows),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  double heightOf(WidgetTester tester, String key) =>
      tester.getSize(find.byKey(ValueKey<String>(key))).height;

  group('same height as the pre-medal row at normal text scale', () {
    for (final double width in <double>[320, 360, 412]) {
      for (final LeaderboardRowAction action in LeaderboardRowAction.values) {
        testWidgets(
            '${width.toInt()} px, action ${action.name}: 0, 1, 5 medals',
            (WidgetTester tester) async {
          await pumpRows(tester, width: width, rows: <Widget>[
            PreMedalLeaderboardRow(
                key: const ValueKey<String>('pre'),
                entry: kEntry,
                onTap: () {},
                action: action,
                onAction: () {}),
            for (final int n in <int>[0, 1, 5])
              LeaderboardRow(
                key: ValueKey<String>('row$n'),
                entry: kEntry,
                onTap: () {},
                action: action,
                onAction: () {},
                medals: medalsFor('a', n),
                onMedalTap: (_) {},
              ),
          ]);
          expect(tester.takeException(), isNull, reason: 'no overflow');
          final double pre = heightOf(tester, 'pre');
          for (final int n in <int>[0, 1, 5]) {
            expect(heightOf(tester, 'row$n'), pre,
                reason: '$n medal(s) at ${width.toInt()} px');
          }
          // Every medal is shown, in category order, inside its row.
          for (final int n in <int>[1, 5]) {
            final Finder row = find.byKey(ValueKey<String>('row$n'));
            final Rect r = tester.getRect(row);
            final List<Rect> coins = <Rect>[
              for (final String c in kCats.take(n))
                tester.getRect(find.descendant(
                    of: row,
                    matching: find
                        .byKey(ValueKey<String>('leaderboard-medal-a-$c')))),
            ];
            expect(coins, hasLength(n));
            for (int i = 0; i < coins.length; i++) {
              expect(r.contains(coins[i].topLeft), isTrue);
              expect(r.contains(coins[i].bottomRight), isTrue);
              expect(coins[i].width, greaterThan(0));
              if (i > 0) expect(coins[i].left, greaterThan(coins[i - 1].right));
            }
          }
        });
      }
    }

    testWidgets('busy (request in flight) rows too',
        (WidgetTester tester) async {
      await pumpRows(tester, width: 360, rows: <Widget>[
        PreMedalLeaderboardRow(
            key: const ValueKey<String>('pre'),
            entry: kEntry,
            onTap: () {},
            action: LeaderboardRowAction.add,
            busy: true),
        LeaderboardRow(
          key: const ValueKey<String>('row5'),
          entry: kEntry,
          onTap: () {},
          action: LeaderboardRowAction.add,
          busy: true,
          medals: medalsFor('a', 5),
          onMedalTap: (_) {},
        ),
      ]);
      expect(heightOf(tester, 'row5'), heightOf(tester, 'pre'));
    });
  });

  testWidgets(
      'tightest case (320 px, Add friend, five medals): the name keeps at least '
      'its first character and the ellipsis', (WidgetTester tester) async {
    await pumpRows(tester, width: 320, rows: <Widget>[
      LeaderboardRow(
        key: const ValueKey<String>('row'),
        entry: kEntry,
        onTap: () {},
        action: LeaderboardRowAction.add,
        onAction: () {},
        medals: medalsFor('a', 5),
        onMedalTap: (_) {},
      ),
    ]);
    final RenderParagraph name =
        tester.renderObject(find.text('averyverylongusername'));
    // Test font: every glyph is 1 em (14 px), so "a…" is 28 px.
    expect(name.size.width, greaterThanOrEqualTo(28));
    final RenderMedalRowLayout l =
        tester.renderObject(find.byType(MedalRowLayout));
    expect(l.debugCoinSide, greaterThan(0));
  });

  group('coins', () {
    test('no loop: every circle the painter draws is the coin, centred', () {
      for (final MedalTier tier in MedalTier.values) {
        final _CircleLog log = _CircleLog();
        const Size box = Size.square(kMedalCoinSide);
        MedalPainter(tier: tier, code: 'BP').paint(log, box);
        final Offset centre = box.center(Offset.zero);
        expect(log.circles, isNotEmpty);
        for (final (Offset c, double r) in log.circles) {
          expect(c.dx, centre.dx, reason: 'nothing beside the coin');
          expect(c.dy, greaterThanOrEqualTo(centre.dy),
              reason: 'nothing above the coin (the former loop sat above)');
          expect(r, lessThanOrEqualTo(kMedalCoinSide * 0.47 + 1e-9));
        }
      }
    });

    test('the visible coin keeps the former 29 px medal\'s 24.9 px diameter',
        () {
      // Former: 29 px square, coin radius 0.43 of it (loop above).
      expect(MedalPainter.coinDiameterFor(kMedalCoinSide),
          moreOrLessEquals(29 * 0.43 * 2, epsilon: 0.05));
    });

    test('same metals as before', () {
      expect(MedalPalette.gold.mid, const Color(0xFFD8AD35));
      expect(MedalPalette.silver.mid, const Color(0xFFB8C0CA));
      expect(MedalPalette.bronze.mid, const Color(0xFFB96832));
    });

    testWidgets('full coin size wherever it fits (friend rows, 412 px)',
        (WidgetTester tester) async {
      await pumpRows(tester, width: 412, rows: <Widget>[
        LeaderboardRow(
          key: const ValueKey<String>('row5'),
          entry: kEntry,
          onTap: () {},
          medals: medalsFor('a', 5),
          onMedalTap: (_) {},
        ),
      ]);
      final RenderMedalRowLayout l =
          tester.renderObject(find.byType(MedalRowLayout));
      expect(l.debugArea, MedalArea.underName);
      expect(l.debugCoinSide, kMedalCoinSide);
    });
  });

  group('taps', () {
    for (final LeaderboardRowAction action in <LeaderboardRowAction>[
      LeaderboardRowAction.none,
      LeaderboardRowAction.add,
      LeaderboardRowAction.accept,
      LeaderboardRowAction.requested,
    ]) {
      testWidgets(
          'action ${action.name}: medal tap opens the medal only; row tap '
          'opens the profile; the action still works',
          (WidgetTester tester) async {
        final List<String> events = <String>[];
        await pumpRows(tester, width: 360, rows: <Widget>[
          LeaderboardRow(
            key: const ValueKey<String>('row'),
            entry: kEntry,
            onTap: () => events.add('profile'),
            action: action,
            onAction: () => events.add('action'),
            medals: medalsFor('a', 5),
            onMedalTap: (LeaderboardMedal m) => events.add('medal:${m.code}'),
          ),
        ]);
        for (final String c in kCats) {
          await tester
              .tap(find.byKey(ValueKey<String>('leaderboard-medal-a-$c')));
        }
        expect(events, <String>[
          'medal:BP',
          'medal:VP',
          'medal:OH',
          'medal:DL',
          'medal:SQ',
        ]);
        events.clear();
        // Beside a coin but inside its cell: still that medal.
        final RenderMedalRowLayout l =
            tester.renderObject(find.byType(MedalRowLayout));
        final Offset origin = tester.getTopLeft(find.byType(MedalRowLayout));
        final Rect coin = tester.getRect(find.byKey(
            const ValueKey<String>('leaderboard-medal-a-overheadPress')));
        final Rect cell = l.debugCells[2].shift(origin);
        final Offset offCoin = Offset(coin.center.dx,
            cell.bottom - 1 > coin.bottom ? cell.bottom - 1 : cell.top + 1);
        if (!coin.contains(offCoin)) {
          await tester.tapAt(offCoin);
          expect(events, <String>['medal:OH']);
          events.clear();
        }
        // The rank opens the profile, never a medal.
        await tester.tap(find.text('12'));
        expect(events, <String>['profile']);
        events.clear();
        if (action == LeaderboardRowAction.add) {
          await tester
              .tap(find.byKey(const ValueKey<String>('leaderboard-add-a')));
          expect(events, <String>['action']);
        } else if (action == LeaderboardRowAction.accept) {
          await tester
              .tap(find.byKey(const ValueKey<String>('leaderboard-accept-a')));
          expect(events, <String>['action']);
        }
      });
    }

    testWidgets('medal semantics: a button with the full label',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await pumpRows(tester, width: 320, rows: <Widget>[
        LeaderboardRow(
          key: const ValueKey<String>('row'),
          entry: kEntry,
          onTap: () {},
          action: LeaderboardRowAction.add,
          onAction: () {},
          medals: medalsFor('a', 5),
          onMedalTap: (_) {},
        ),
      ]);
      expect(
          find.bySemanticsLabel(
              'Gold medal, Horizontal Press, 1.00 monthly RE Points'),
          findsOneWidget);
      expect(
          tester.getSemantics(find.byKey(
              const ValueKey<String>('leaderboard-medal-a-horizontalPress'))),
          matchesSemantics(
              isButton: true,
              hasTapAction: true,
              label: 'Gold medal, Horizontal Press, 1.00 monthly RE Points'));
      handle.dispose();
    });
  });

  group('increased text scale', () {
    for (final double scale in <double>[1.3, 2.0]) {
      for (final double width in <double>[320, 412]) {
        for (final LeaderboardRowAction action in <LeaderboardRowAction>[
          LeaderboardRowAction.none,
          LeaderboardRowAction.add,
        ]) {
          testWidgets(
              '×$scale at ${width.toInt()} px, action ${action.name}: no '
              'overflow; no taller than the pre-medal row',
              (WidgetTester tester) async {
            // The pre-medal row alone (it may itself overflow sideways at the
            // largest sizes, which is why the points now scale down).
            await pumpRows(tester,
                width: width,
                textScale: scale,
                rows: <Widget>[
                  PreMedalLeaderboardRow(
                      key: const ValueKey<String>('pre'),
                      entry: kEntry,
                      onTap: () {},
                      action: action,
                      onAction: () {}),
                ]);
            final double pre = heightOf(tester, 'pre');
            tester.takeException();
            await pumpRows(tester,
                width: width,
                textScale: scale,
                rows: <Widget>[
                  for (final int n in <int>[0, 1, 5])
                    LeaderboardRow(
                      key: ValueKey<String>('row$n'),
                      entry: kEntry,
                      onTap: () {},
                      action: action,
                      onAction: () {},
                      medals: medalsFor('a', n),
                      onMedalTap: (_) {},
                    ),
                ]);
            expect(tester.takeException(), isNull, reason: 'no overflow');
            final double none = heightOf(tester, 'row0');
            expect(none, lessThanOrEqualTo(pre));
            expect(heightOf(tester, 'row1'), none,
                reason: 'medals add nothing at this scale either');
            expect(heightOf(tester, 'row5'), none);
            expect(find.byType(MedalButton), findsNWidgets(6));
          });
        }
      }
    }
  });

  group('both boards through the real view', () {
    Future<void> seedEntries(
        FakeFirebaseFirestore db, String period, List<String> uids) async {
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
          'username': 'name-$uid',
          'totalPointsUnits': units,
          'tieBreakDateKey': '2026-09-01',
          'formulaVersion': 1,
        });
      }
    }

    Map<String, Object?> award(String uid, int place) => <String, Object?>{
          'uid': uid,
          'place': place,
          'pointsUnits': 100,
          'achievedDateKey': '2026-09-10',
        };

    Future<void> seedMedals(FakeFirebaseFirestore db, String period,
        Map<String, List<Object?>> cats) async {
      await db.collection(kLeaderboardMedalsCollection).doc(period).set(
        <String, Object?>{
          'schema': 'leaderboardMedals',
          'schemaVersion': 1,
          'periodKey': period,
          'boardType': period == 'all_time' ? 'allTime' : 'month',
          'revision': 1,
          'categories': <String, Object?>{
            for (final String c in kCats) c: cats[c] ?? <Object?>[],
          },
        },
      );
    }

    testWidgets(
        'This Month and All Time: friend and non-friend rows with 0, 1 and 5 '
        'medals are all their medal-less height', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      // f* are friends (no action); s* are strangers (Add friend).
      const List<String> uids = <String>['f0', 'f1', 'f5', 's0', 's1', 's5'];
      for (final String period in <String>['2026-09', 'all_time']) {
        await seedEntries(db, period, uids);
        await seedMedals(db, period, <String, List<Object?>>{
          for (final String c in kCats)
            c: <Object?>[
              award('f5', 1),
              award('s5', 2),
              if (c == 'horizontalPress') award('f1', 3),
            ],
          'verticalPull': <Object?>[
            award('f5', 1),
            award('s5', 2),
            award('s1', 3)
          ],
        });
      }
      await db.collection('socialGraph').doc(kMe).set(<String, Object?>{
        'friends': <String>['f0', 'f1', 'f5'],
      });
      final List<String> opened = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: LeaderboardView(
              repository:
                  LeaderboardRepository(firestore: db, clock: () => kNow),
              buddies: BuddyRepository(firestore: db, overrideUid: kMe),
              onOpenProfile: opened.add,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      Future<void> check(String board) async {
        double h(String uid) => tester
            .getSize(find.byKey(ValueKey<String>('leaderboard-row-$uid')))
            .height;
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey<String>('leaderboard-medals-f5')),
            findsOneWidget,
            reason: '$board has medals');
        expect(h('f1'), h('f0'), reason: '$board friend, 1 medal');
        expect(h('f5'), h('f0'), reason: '$board friend, 5 medals');
        expect(h('s1'), h('s0'), reason: '$board non-friend, 1 medal');
        expect(h('s5'), h('s0'), reason: '$board non-friend, 5 medals');
        expect(h('f0'), 56);
      }

      await check('This Month');
      await tester.tap(
          find.byKey(const ValueKey<String>('leaderboard-period-allTime')));
      await tester.pumpAndSettle();
      await check('All Time');
      expect(opened, isEmpty);
    });
  });
}
