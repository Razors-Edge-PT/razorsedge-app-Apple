// Both leaderboards (This Month and All Time) show ranks 1–20 only: one
// top-20 query, rank 21 is never shown and there is no "Show more" control —
// including when a board holds exactly 20 rows.

import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/leaderboard/leaderboard_repository.dart';
import 'package:localtest222/leaderboard/leaderboard_view.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';
import 'package:localtest222/social/buddy_repository.dart';

const String kMe = 'me';
final DateTime kNow = DateTime(2026, 9, 24, 10);

class _AbsentStore implements ProfileImageStore {
  @override
  Future<File?> cached(String url, {String? key}) async => null;

  @override
  Future<File> download(String url, {String? key}) =>
      Future<File>.error(const SocketException('offline in tests'));

  @override
  Future<void> evict(String key) async {}
}

/// [count] ranked rows for [period], uids `<prefix>0` (rank 1) upwards.
Future<List<String>> seedBoard(
    FakeFirebaseFirestore db, String period, String prefix, int count) async {
  final List<String> uids = <String>[for (int i = 0; i < count; i++) '$prefix$i'];
  for (int i = 0; i < count; i++) {
    await db
        .collection('leaderboards')
        .doc(period)
        .collection('entries')
        .doc(uids[i])
        .set(<String, Object?>{
      'uid': uids[i],
      'username': 'name-${uids[i]}',
      'totalPointsUnits': 9000000 - i * 10000,
      'tieBreakDateKey': '2026-09-10',
    });
  }
  return uids;
}

Future<void> pumpBoard(
    WidgetTester tester, FakeFirebaseFirestore db, List<String> friends) async {
  tester.view.physicalSize = const Size(400, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await db.collection('socialGraph').doc(kMe).set(<String, Object?>{
    'friends': friends,
  });
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: LeaderboardView(
          repository: LeaderboardRepository(firestore: db, clock: () => kNow),
          buddies: BuddyRepository(firestore: db, overrideUid: kMe),
          onOpenProfile: (_) {},
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder row(String uid) => find.byKey(ValueKey<String>('leaderboard-row-$uid'));

void expectTop20Only(List<String> uids) {
  for (int i = 0; i < uids.length; i++) {
    expect(row(uids[i]), i < 20 ? findsOneWidget : findsNothing,
        reason: 'rank ${i + 1}');
  }
  expect(find.byKey(const ValueKey<String>('leaderboard-more')), findsNothing);
  expect(find.text('Show more'), findsNothing);
}

void main() {
  setUp(() => profileImageStore = _AbsentStore());
  tearDown(resetProfileImageCache);

  testWidgets(
      '25 entries: This Month and All Time each show exactly ranks 1–20, '
      'no Show more, across period switches', (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    final List<String> month = await seedBoard(db, '2026-09', 'm', 25);
    final List<String> all = await seedBoard(db, 'all_time', 'a', 25);
    await pumpBoard(tester, db, <String>[...month, ...all]);

    expectTop20Only(month);
    expect(find.byKey(const ValueKey<String>('leaderboard-row-m19')),
        findsOneWidget,
        reason: 'rank 20 is shown');

    await tester.tap(
        find.byKey(const ValueKey<String>('leaderboard-period-allTime')));
    await tester.pumpAndSettle();
    expectTop20Only(all);
    for (final String u in month) {
      expect(row(u), findsNothing, reason: 'only the selected board');
    }

    await tester.tap(
        find.byKey(const ValueKey<String>('leaderboard-period-thisMonth')));
    await tester.pumpAndSettle();
    expectTop20Only(month);
  });

  testWidgets('exactly 20 entries: all 20 shown, nothing suggests more',
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    final List<String> month = await seedBoard(db, '2026-09', 'm', 20);
    await pumpBoard(tester, db, month);
    expectTop20Only(month);
    for (final String u in month) {
      expect(row(u), findsOneWidget);
    }
  });

  testWidgets('fewer than 20 entries are all shown',
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    final List<String> month = await seedBoard(db, '2026-09', 'm', 3);
    await pumpBoard(tester, db, month);
    expectTop20Only(month);
  });
}
