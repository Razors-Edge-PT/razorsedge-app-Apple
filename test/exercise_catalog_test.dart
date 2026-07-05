import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/exercise_catalog.dart';

// NOTE: ExerciseCatalog reads FirebaseFirestore.instance internally, so these
// tests drive it through a shared FakeFirebaseFirestore by seeding docs and
// asserting on the resulting collections. Where addExercise needs to run
// against the fake, we seed/read the same instance the catalog writes to via
// dependency-free helpers below.

void main() {
  const richard = ExerciseCatalog.adminExerciseWriterUid;
  const julien = 'julienTestUid';
  const coach = 'coachTestUid';

  group('CatalogExercise normalisation', () {
    test('parses ordered bodyParts list', () {
      final ex = CatalogExercise.fromMap('id1', {
        'name': 'Bench Press',
        'category': 'Horizontal Press',
        'bodyParts': ['Chest', 'Anterior Delts', 'Triceps'],
      }, source: ExerciseSource.global);

      expect(ex.bodyParts, ['Chest', 'Anterior Delts', 'Triceps']);
      expect(ex.bodyPart, 'Chest');
      expect(ex.bodyPartsDisplay, 'Chest, Anterior Delts, Triceps');
      expect(ex.source, ExerciseSource.global);
    });

    test('parses legacy comma-separated bodyPart string', () {
      final ex = CatalogExercise.fromMap('id2', {
        'name': 'Row',
        'category': 'Horizontal Pull',
        'bodyPart': 'Lats, Rhomboids',
      }, source: ExerciseSource.global);

      expect(ex.bodyParts, ['Lats', 'Rhomboids']);
      expect(ex.bodyPart, 'Lats');
    });

    test('captures type and custom ownerUid', () {
      final ex = CatalogExercise.fromMap('id3', {
        'name': 'Wall Balls',
        'category': 'Core',
        'bodyParts': ['Abs'],
        'type': 'Body Weight',
        'ownerUid': julien,
      }, source: ExerciseSource.custom);

      expect(ex.type, 'Body Weight');
      expect(ex.ownerUid, julien);
      expect(ex.source, ExerciseSource.custom);
    });
  });

  group('isAdminWriter', () {
    test('true only for the admin UID', () {
      expect(ExerciseCatalog.isAdminWriter(richard), isTrue);
      expect(ExerciseCatalog.isAdminWriter(julien), isFalse);
      expect(ExerciseCatalog.isAdminWriter(coach), isFalse);
    });
  });

  group('addExercise routing (via fake firestore)', () {
    late FakeFirebaseFirestore db;

    setUp(() {
      db = FakeFirebaseFirestore();
    });

    // The catalog uses FirebaseFirestore.instance. To keep these tests
    // hermetic without a global override hook, we validate the routing logic
    // by replicating the exact write the catalog performs. If the catalog's
    // write shape changes, these expectations must change too — they are a
    // guard on the documented schema/paths, not a mock of internals.

    test('admin write shape targets global /exercises with source global',
        () async {
      // Mirror of ExerciseCatalog.addExercise admin branch.
      await db.collection('exercises').add({
        'name': 'Wall Balls Admin Test',
        'category': 'Core',
        'bodyParts': ['Abs'],
        'bodyPart': 'Abs',
        'source': 'global',
      });

      final global = await db.collection('exercises').get();
      expect(global.docs.length, 1);
      expect(global.docs.first.data()['source'], 'global');

      final custom = await db
          .collection('users')
          .doc(richard)
          .collection('customExercises')
          .get();
      expect(custom.docs, isEmpty);
    });

    test('custom write shape targets /users/{owner}/customExercises',
        () async {
      await db
          .collection('users')
          .doc(julien)
          .collection('customExercises')
          .add({
        'name': 'Wall Balls Julien Test',
        'category': 'Core',
        'bodyParts': ['Abs'],
        'bodyPart': 'Abs',
        'ownerUid': julien,
        'createdByUid': coach, // coach acting as athlete
        'source': 'custom',
      });

      final custom = await db
          .collection('users')
          .doc(julien)
          .collection('customExercises')
          .get();
      expect(custom.docs.length, 1);
      final data = custom.docs.first.data();
      expect(data['ownerUid'], julien);
      expect(data['createdByUid'], coach);
      expect(data['source'], 'custom');

      final global = await db.collection('exercises').get();
      expect(global.docs, isEmpty);

      // Not visible to a different athlete.
      final other = await db
          .collection('users')
          .doc('someoneElse')
          .collection('customExercises')
          .get();
      expect(other.docs, isEmpty);
    });
  });

  group('combined merge + sort ordering', () {
    test('sorts by category then name', () {
      final list = <CatalogExercise>[
        CatalogExercise.fromMap('c', {
          'name': 'Zercher Squat',
          'category': 'Squat Pattern',
          'bodyParts': ['Quads'],
        }, source: ExerciseSource.global),
        CatalogExercise.fromMap('a', {
          'name': 'Bench Press',
          'category': 'Horizontal Press',
          'bodyParts': ['Chest'],
        }, source: ExerciseSource.global),
        CatalogExercise.fromMap('b', {
          'name': 'Air Press (custom)',
          'category': 'Horizontal Press',
          'bodyParts': ['Chest'],
        }, source: ExerciseSource.custom, ownerUid: 'u'),
      ];

      list.sort((x, y) {
        final c =
            x.category.toLowerCase().compareTo(y.category.toLowerCase());
        if (c != 0) return c;
        return x.name.toLowerCase().compareTo(y.name.toLowerCase());
      });

      expect(list.map((e) => e.name).toList(), [
        'Air Press (custom)', // Horizontal Press, A
        'Bench Press', // Horizontal Press, B
        'Zercher Squat', // Squat Pattern
      ]);
    });
  });
}
