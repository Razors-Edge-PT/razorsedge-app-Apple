// Training-profile privacy on the client: the showcase comes from the
// friend-gated users_showcase/{uid}, never from users_public for someone the
// rules refuse, and a refusal never takes the profile identity down with it.
// The database-level denial itself is tested against the real rules engine in
// functions/test-rules/profile_privacy_rules.spec.js.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/leaderboard/leaderboard_medals.dart';
import 'package:localtest222/leaderboard/leaderboard_repository.dart';
import 'package:localtest222/profile/data/profile_repository.dart';

const String kBench = 'AmfUWbF1DH3I7qPAdh5k';

Map<String, Object?> v2(double rePoints, double weight, int reps) =>
    <String, Object?>{
      'schema': 'profileShowcaseV2',
      'categories': <String, Object?>{
        'horizontalPress': <String, Object?>{
          'bestExerciseId': kBench,
          'exercises': <String, Object?>{
            kBench: <String, Object?>{
              'slot': 'bench',
              'exerciseId': kBench,
              'rePoints': rePoints,
              'points': <String, Object?>{
                'slot': 'bench',
                'exerciseId': kBench,
                'dateKey': '2026-09-12',
                'setKey': 's0',
                'weight': weight,
                'reps': reps,
                'e1rm': 200.0,
                'formulaVersion': 1,
                'fingerprint': 'fp',
              },
            },
          },
        },
      },
    };

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late FakeFirebaseFirestore db;

  setUp(() async {
    db = FakeFirebaseFirestore();
    await db.collection('users_public').doc('athlete').set(<String, Object?>{
      'username': 'Lifter',
      'photoURL': 'https://example.invalid/a.jpg',
      'profileShowcaseV2': v2(100, 120, 5), // legacy transition mirror
    });
  });

  group('ProfileRepository.watch', () {
    test('a permitted viewer gets the friend-gated showcase, not the legacy copy',
        () async {
      await db
          .collection('users_showcase')
          .doc('athlete')
          .set(<String, Object?>{'profileShowcaseV2': v2(174.28, 158.5, 9)});
      final ProfileIdentity p =
          await ProfileRepository(firestore: db).watch('athlete').firstWhere(
                (ProfileIdentity p) => p.showcaseV2 != null,
              );
      expect(p.username, 'Lifter');
      expect(
          p.showcaseV2!.categories.first.exercises.first.rePoints, 174.28);
    });

    test('an athlete not migrated yet falls back to the legacy fields', () async {
      final ProfileIdentity p =
          await ProfileRepository(firestore: db).watch('athlete').firstWhere(
                (ProfileIdentity p) => p.showcaseV2 != null,
              );
      expect(p.showcaseV2!.categories.first.exercises.first.rePoints, 100);
    });
  });

  group('ProfileRepository.combineIdentity', () {
    late StreamController<DocumentSnapshot<Map<String, dynamic>>> showcase;
    late List<ProfileIdentity> seen;
    late List<Object> errors;
    late StreamSubscription<ProfileIdentity> sub;

    setUp(() async {
      showcase = StreamController<DocumentSnapshot<Map<String, dynamic>>>();
      seen = <ProfileIdentity>[];
      errors = <Object>[];
      sub = ProfileRepository.combineIdentity(
        'athlete',
        db.collection('users_public').doc('athlete').snapshots(),
        showcase.stream,
      ).listen(seen.add, onError: errors.add);
      await settle();
    });

    tearDown(() async {
      await sub.cancel();
      await showcase.close();
    });

    test('a non-friend (denied) sees the identity and NO showcase', () async {
      showcase.addError(FirebaseException(
          plugin: 'cloud_firestore', code: 'permission-denied'));
      await settle();
      expect(errors, isEmpty, reason: 'a refusal is not a broken profile');
      expect(seen.last.username, 'Lifter');
      expect(seen.last.photoURL, 'https://example.invalid/a.jpg');
      expect(seen.last.showcaseV2, isNull,
          reason: 'never the users_public legacy copy');
      expect(seen.last.showcase.lifts, isEmpty);
    });

    test('before the showcase read answers, no showcase is shown', () async {
      expect(seen, isNotEmpty);
      expect(seen.every((ProfileIdentity p) => p.showcaseV2 == null), isTrue);
    });

    test('any other showcase failure surfaces as an error', () async {
      showcase.addError(
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'));
      await settle();
      expect(errors, hasLength(1));
    });
  });

  group('ShowcaseSource', () {
    test('denied hides everything; legacy reads users_public; document wins',
        () {
      final Map<String, dynamic> pub = <String, dynamic>{
        'profileShowcaseV2': v2(1, 1, 1)
      };
      expect(const ShowcaseSource.denied().fieldsFor(pub), isEmpty);
      expect(const ShowcaseSource.legacy().fieldsFor(pub), same(pub));
      final Map<String, dynamic> doc = <String, dynamic>{
        'profileShowcaseV2': v2(2, 2, 2)
      };
      expect(ShowcaseSource.document(doc).fieldsFor(pub), same(doc));
    });
  });

  group('all-time medal record line', () {
    LeaderboardMedal medal(int units) => LeaderboardMedal(
          uid: 'athlete',
          tier: MedalTier.gold,
          categoryKey: 'horizontalPress',
          pointsUnits: units,
          periodKey: 'all_time',
          exerciseId: kBench,
        );

    test('comes from the friend-gated document when it is readable', () async {
      await db
          .collection('users_showcase')
          .doc('athlete')
          .set(<String, Object?>{'profileShowcaseV2': v2(174.28, 158.5, 9)});
      expect(
          await LeaderboardRepository(firestore: db)
              .fetchMedalRecordSource(medal(1742800)),
          '158.5 kg × 9');
    });

    test('an unmigrated athlete still shows the line (legacy fallback)',
        () async {
      expect(
          await LeaderboardRepository(firestore: db)
              .fetchMedalRecordSource(medal(1000000)),
          '120 kg × 5');
    });
  });
}
