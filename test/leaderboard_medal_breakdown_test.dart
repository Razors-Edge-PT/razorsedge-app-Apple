// The monthly medal detail's exercise breakdown: parsing the server's
// categoryExerciseBreakdown, the "This month:" rows (order, formatting,
// singular / plural sessions), long names on small screens, the legacy
// fallback sentence, and the All Time detail left exactly as it was.

import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/leaderboard/leaderboard_medals.dart';
import 'package:localtest222/leaderboard/leaderboard_models.dart';
import 'package:localtest222/leaderboard/leaderboard_repository.dart';
import 'package:localtest222/leaderboard/leaderboard_view.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';
import 'package:localtest222/social/buddy_repository.dart';

const String kMe = 'me';
final DateTime kNow = DateTime(2026, 9, 24, 10);
const String kBench = 'AmfUWbF1DH3I7qPAdh5k';
const String kDbBench = 'kTs5fLSTKjUkUZL10iii';
const String kSquat = 'heeBViVINHO6tUScSd6y';

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

Map<String, Object?> contribution(String id, int units, int sessions,
        {String name = 'stored name'}) =>
    <String, Object?>{
      'exerciseId': id,
      'displayName': name,
      'pointsUnits': units,
      'sessionCount': sessions,
    };

Future<void> seedEntry(FakeFirebaseFirestore db, String period, String uid,
    {Map<String, List<Object?>>? breakdown}) {
  return db
      .collection('leaderboards')
      .doc(period)
      .collection('entries')
      .doc(uid)
      .set(<String, Object?>{
    'uid': uid,
    'username': 'name-$uid',
    'totalPointsUnits': 9000000,
    'tieBreakDateKey': '2026-09-10',
    if (breakdown != null)
      'categoryExerciseBreakdown': <String, Object?>{
        for (final String c in kCats) c: breakdown[c] ?? <Object?>[],
      },
  });
}

Future<void> seedMedal(FakeFirebaseFirestore db, String period, String cat,
    String uid, int units,
    {String? exerciseId}) {
  return db.collection(kLeaderboardMedalsCollection).doc(period).set(
    <String, Object?>{
      'schema': 'leaderboardMedals',
      'schemaVersion': 1,
      'periodKey': period,
      'boardType': period == 'all_time' ? 'allTime' : 'month',
      'revision': 1,
      'categories': <String, Object?>{
        for (final String c in kCats)
          c: c == cat
              ? <Object?>[
                  <String, Object?>{
                    'uid': uid,
                    'place': 1,
                    'pointsUnits': units,
                    'achievedDateKey': '2026-09-12',
                    if (exerciseId != null) 'exerciseId': exerciseId,
                    if (exerciseId != null) 'recordDateKey': '2026-09-12',
                  },
                ]
              : <Object?>[],
      },
    },
  );
}

void main() {
  setUp(() => profileImageStore = _AbsentStore());
  tearDown(resetProfileImageCache);

  group('parsing', () {
    test('legacy entries have no breakdown; new ones parse every category', () {
      final LeaderboardEntry legacy = LeaderboardEntry.fromMap(
          'a', <String, dynamic>{'totalPointsUnits': 5}, rank: 1)!;
      expect(legacy.categoryBreakdown, isNull);
      expect(legacy.contributionsFor('hipHinge'), isNull);

      final LeaderboardEntry e = LeaderboardEntry.fromMap(
          'a',
          <String, dynamic>{
            'totalPointsUnits': 5,
            'categoryExerciseBreakdown': <String, Object?>{
              'horizontalPress': <Object?>[
                contribution(kDbBench, 7010800, 8),
                contribution(kBench, 10000000, 13),
              ],
              'hipHinge': <Object?>[],
            },
          },
          rank: 1)!;
      final List<MonthlyExerciseContribution> rows =
          e.contributionsFor('horizontalPress')!;
      expect(rows.map((MonthlyExerciseContribution r) => r.label), <String>[
        'Bench Press, Barbell — 1000.00 RE pts · 13 sessions',
        'Flat Bench Dumbbell Press — 701.08 RE pts · 8 sessions',
      ]);
      expect(e.contributionsFor('hipHinge'), isEmpty);
      expect(e.contributionsFor('squatPattern'), isEmpty,
          reason: 'a recorded breakdown with no row for the category');
    });

    test('singular and plural sessions', () {
      expect(MonthlyExerciseContribution.fromMap(contribution(kSquat, 12345, 1))!
          .label, 'Back Squat, Barbell — 1.23 RE pts · 1 session');
      expect(MonthlyExerciseContribution.fromMap(contribution(kSquat, 12345, 2))!
          .sessionsLabel, '2 sessions');
    });

    test('catalogue name wins; unknown ids keep the stored name', () {
      expect(
          MonthlyExerciseContribution.fromMap(
                  contribution(kBench, 1, 1, name: 'old'))!
              .displayName,
          'Bench Press, Barbell');
      expect(
          MonthlyExerciseContribution.fromMap(
                  contribution('custom', 1, 1, name: 'Custom Lift'))!
              .displayName,
          'Custom Lift');
    });

    test('malformed or non-positive rows are dropped, never crash', () {
      for (final Object? bad in <Object?>[
        null,
        'x',
        contribution(kBench, 0, 1),
        contribution(kBench, -5, 1),
        contribution(kBench, 5, 0),
        <String, Object?>{'exerciseId': kBench, 'pointsUnits': 'a'},
        <String, Object?>{'pointsUnits': 5, 'sessionCount': 1},
      ]) {
        expect(MonthlyExerciseContribution.fromMap(bad), isNull,
            reason: '$bad');
      }
      expect(parseCategoryBreakdown('nope'), isNull);
      expect(
          parseCategoryBreakdown(<String, Object?>{'hipHinge': 'nope'}),
          isEmpty);
    });

    test('rows are ordered by points, then name', () {
      final Map<String, List<MonthlyExerciseContribution>> b =
          parseCategoryBreakdown(<String, Object?>{
        'horizontalPress': <Object?>[
          contribution('z', 100, 1, name: 'Zed'),
          contribution('y', 300, 1, name: 'Yak'),
          contribution('a', 100, 1, name: 'Alpha'),
        ],
      })!;
      expect(
          b['horizontalPress']!
              .map((MonthlyExerciseContribution r) => r.displayName),
          <String>['Yak', 'Alpha', 'Zed']);
    });
  });

  group('medal detail', () {
    Future<void> pumpBoard(WidgetTester tester, FakeFirebaseFirestore db,
        {Size size = const Size(400, 1600), double textScale = 1.0}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await db.collection('socialGraph').doc(kMe).set(<String, Object?>{
        'friends': <String>['a'],
      });
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
              size: size, textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: LeaderboardView(
                repository:
                    LeaderboardRepository(firestore: db, clock: () => kNow),
                buddies: BuddyRepository(firestore: db, overrideUid: kMe),
                onOpenProfile: (_) {},
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> openMedal(WidgetTester tester, String cat) async {
      await tester.tap(find.byKey(ValueKey<String>('leaderboard-medal-a-$cat')));
      await tester.pumpAndSettle();
    }

    Finder rowText(int i) =>
        find.byKey(ValueKey<String>('medal-breakdown-row-$i'));
    String textOf(WidgetTester tester, Finder f) =>
        tester.widget<Text>(f).data!;

    testWidgets(
        'This Month: title, athlete and total kept; sentence replaced by the rows',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedEntry(db, '2026-09', 'a',
          breakdown: <String, List<Object?>>{
            'horizontalPress': <Object?>[
              contribution(kDbBench, 7010800, 8),
              contribution(kBench, 10000000, 13),
            ],
          });
      await seedMedal(db, '2026-09', 'horizontalPress', 'a', 17010800);
      await pumpBoard(tester, db);
      await openMedal(tester, 'horizontalPress');
      expect(find.text('Gold — Horizontal Press'), findsOneWidget);
      expect(find.descendant(
              of: find.byKey(const ValueKey<String>('medal-detail')),
              matching: find.text('name-a')),
          findsOneWidget);
      expect(find.text('September 2026 category total: 1701.08 RE Points'),
          findsOneWidget);
      expect(find.textContaining('winning Horizontal Press score'),
          findsNothing);
      expect(find.text('This month:'), findsOneWidget);
      expect(textOf(tester, rowText(0)),
          'Bench Press, Barbell — 1000.00 RE pts · 13 sessions');
      expect(textOf(tester, rowText(1)),
          'Flat Bench Dumbbell Press — 701.08 RE pts · 8 sessions');
      expect(rowText(2), findsNothing);
    });

    testWidgets('one contributing exercise with one session is singular',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedEntry(db, '2026-09', 'a',
          breakdown: <String, List<Object?>>{
            'squatPattern': <Object?>[contribution(kSquat, 1234567, 1)],
          });
      await seedMedal(db, '2026-09', 'squatPattern', 'a', 1234567);
      await pumpBoard(tester, db);
      await openMedal(tester, 'squatPattern');
      expect(textOf(tester, rowText(0)),
          'Back Squat, Barbell — 123.46 RE pts · 1 session');
    });

    testWidgets('legacy entry without a breakdown keeps the explanatory sentence',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedEntry(db, '2026-09', 'a');
      await seedMedal(db, '2026-09', 'hipHinge', 'a', 5000000);
      await pumpBoard(tester, db);
      await openMedal(tester, 'hipHinge');
      expect(tester.takeException(), isNull);
      expect(find.text('This month:'), findsNothing);
      expect(
          find.text(
              'The sum of this athlete\'s winning Hip Hinge score on each training day this month.'),
          findsOneWidget);
    });

    testWidgets(
        'a breakdown that does not add up to the medal total falls back to the sentence',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedEntry(db, '2026-09', 'a',
          breakdown: <String, List<Object?>>{
            'hipHinge': <Object?>[contribution(kSquat, 100, 1)],
          });
      await seedMedal(db, '2026-09', 'hipHinge', 'a', 5000000);
      await pumpBoard(tester, db);
      await openMedal(tester, 'hipHinge');
      expect(find.text('This month:'), findsNothing);
      expect(find.textContaining('winning Hip Hinge score'), findsOneWidget);
    });

    testWidgets('long names and many rows: no overflow on a small screen',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final List<Object?> rows = <Object?>[
        for (int i = 0; i < 8; i++)
          contribution('custom-$i', 1000 - i, 3,
              name:
                  'An Extremely Long Custom Exercise Name Variation Number $i With Pauses'),
      ];
      final int total =
          List<int>.generate(8, (int i) => 1000 - i).reduce((int a, int b) => a + b);
      await seedEntry(db, '2026-09', 'a',
          breakdown: <String, List<Object?>>{'squatPattern': rows});
      await seedMedal(db, '2026-09', 'squatPattern', 'a', total);
      await pumpBoard(tester, db, size: const Size(320, 568), textScale: 2.0);
      await openMedal(tester, 'squatPattern');
      expect(tester.takeException(), isNull);
      expect(find.text('This month:'), findsOneWidget);
      expect(rowText(0), findsOneWidget);
    });

    testWidgets(
        'All Time: best single score, exercise, set and date — no monthly rows',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      // Even if an all-time entry somehow carried a breakdown, it is ignored.
      await seedEntry(db, 'all_time', 'a',
          breakdown: <String, List<Object?>>{
            'horizontalPress': <Object?>[contribution(kBench, 1742800, 1)],
          });
      await seedMedal(db, 'all_time', 'horizontalPress', 'a', 1742800,
          exerciseId: kBench);
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
      await openMedal(tester, 'horizontalPress');
      expect(find.text('Gold — Horizontal Press'), findsOneWidget);
      expect(find.text('Best single score: 174.28 RE Points'), findsOneWidget);
      expect(find.text('Bench Press, Barbell — 158.5 kg × 9'), findsOneWidget);
      expect(find.text('12 Sep 2026'), findsOneWidget);
      expect(find.text('This month:'), findsNothing);
      expect(find.byKey(const ValueKey<String>('medal-breakdown')),
          findsNothing);
      expect(find.textContaining('category total'), findsNothing);
    });
  });
}
