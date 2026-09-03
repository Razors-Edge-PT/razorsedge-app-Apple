/// The gallery query: what is allowed to occupy a result slot.
///
/// `posts` is a mixed collection. RE Daily writes a summary record into it on
/// every training day — an `ownerUid`, a `createdAt`, some points, and NO media
/// of any kind. Filtering those out on the CLIENT meant `limit(60)` was spent
/// before the filter ran, so a user with sixty daily records since their last
/// upload saw an empty gallery and, before that, a wall of blank placeholders.
///
/// These tests state the contract in both directions: nothing without media may
/// take a slot, and nothing WITH media may be excluded — including the
/// pre-1.7.13 posts that carry no `showInGrid` field at all, which is the whole
/// reason that field is not the server-side clause.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_identity.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/data/media_outbox.dart';
import 'package:localtest222/profile/data/media_repository.dart';

void main() {
  const String owner = 'athlete1';

  late FakeFirebaseFirestore db;
  late MediaOutbox outbox;
  late MediaRepository media;

  setUp(() {
    db = FakeFirebaseFirestore();
    outbox = MediaOutbox(MediaOutboxDatabase.memory());
    media = MediaRepository(firestore: db, outbox: outbox);
  });

  tearDown(() async => outbox.close());

  Future<void> seedMedia(
    String id, {
    String mediaType = MediaType.image,
    DateTime? createdAt,
    bool? showInGrid,
    String? type,
  }) =>
      db.collection('posts').doc(id).set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': mediaType,
        if (type != null) 'type': type,
        'showInGrid': showInGrid ?? true,
        'smallUrl': 'https://example.invalid/$id.jpg',
        'thumbUrl': 'https://example.invalid/$id-thumb.jpg',
        'storagePathOriginal': 'users/$owner/posts/$id/original.jpg',
        'createdAt': Timestamp.fromDate(createdAt ?? DateTime(2025, 1, 1)),
      });

  /// Exactly what `_upsertDailyPost` in re_daily.dart writes: no mediaType, no
  /// showInGrid, no URLs.
  Future<void> seedReDaily(String id, DateTime createdAt) =>
      db.collection('posts').doc(id).set(<String, Object?>{
        'type': PostKind.reDaily,
        'ownerUid': owner,
        'dayKey': '2026-09-01',
        'monthKey': '2026-09',
        'dailyTotal': 12.5,
        'visibility': 'friends',
        'badges': <String>[],
        'createdAt': Timestamp.fromDate(createdAt),
      });

  group('non-media records cannot occupy gallery slots', () {
    test('an RE Daily record never reaches the grid', () async {
      await seedReDaily('daily1', DateTime(2026, 9, 1));
      await seedMedia('photo1');

      final List<ProfileMediaItem> grid = await media.watchGrid(owner).first;

      expect(grid.map((ProfileMediaItem i) => i.id), <String>['photo1']);
    });

    test('more than 60 newer RE Daily records cannot hide older real media',
        () async {
      // The genuine upload is the OLDEST document, so any filter that runs
      // after the limit puts it outside the window.
      await seedMedia('realPhoto', createdAt: DateTime(2025, 1, 1));
      for (int i = 0; i < 75; i++) {
        await seedReDaily('daily$i', DateTime(2026, 1, 1).add(Duration(days: i)));
      }

      final List<ProfileMediaItem> grid = await media.watchGrid(owner).first;

      expect(
        grid.map((ProfileMediaItem i) => i.id),
        contains('realPhoto'),
        reason: 'the limit must apply AFTER server-side eligibility, not '
            'before it',
      );
      expect(grid, hasLength(1));
    });

    test('more than 60 newer HIDDEN documents cannot hide older real media',
        () async {
      // The sharper form of the same defect. These carry a valid mediaType, so
      // filtering on type alone does not stop them: only `showInGrid == true`
      // in the query keeps them from spending the 60-document window before
      // eligibility is ever considered.
      await seedMedia('realPhoto', createdAt: DateTime(2025, 1, 1));
      for (int i = 0; i < 75; i++) {
        await seedMedia(
          'hidden$i',
          mediaType: i.isEven ? MediaType.image : MediaType.video,
          showInGrid: false,
          createdAt: DateTime(2026, 1, 1).add(Duration(days: i)),
        );
      }

      final List<ProfileMediaItem> grid = await media.watchGrid(owner).first;

      expect(grid.map((ProfileMediaItem i) => i.id), <String>['realPhoto']);
    });

    test('a mixed flood of hidden and non-media records still cannot bury it',
        () async {
      await seedMedia('realPhoto', createdAt: DateTime(2025, 1, 1));
      for (int i = 0; i < 40; i++) {
        await seedMedia(
          'hidden$i',
          showInGrid: false,
          createdAt: DateTime(2026, 1, 1).add(Duration(days: i)),
        );
        await seedReDaily(
            'daily$i', DateTime(2026, 6, 1).add(Duration(days: i)));
      }

      final List<ProfileMediaItem> grid = await media.watchGrid(owner).first;

      expect(grid.map((ProfileMediaItem i) => i.id), <String>['realPhoto']);
    });

    test('a record with no mediaType at all is excluded', () async {
      await db.collection('posts').doc('shapeless').set(<String, Object?>{
        'ownerUid': owner,
        'createdAt': Timestamp.fromDate(DateTime(2026, 1, 1)),
      });
      expect(await media.watchGrid(owner).first, isEmpty);
    });

    test('a record with an unknown mediaType is excluded', () async {
      await seedMedia('weird', mediaType: 'audio');
      expect(await media.watchGrid(owner).first, isEmpty);
    });
  });

  group('genuine media is never excluded', () {
    test('a pre-1.7.13 post with no showInGrid is deliberately absent',
        () async {
      // Gallery eligibility is decided by the SERVER now, before the
      // limit is spent, and `showInGrid` is the field that decides it.
      // Posts written before 1.7.13 carry no such field, so they are
      // deliberately absent: the alternative was leaving the clause on the
      // client, where sixty hidden or non-media documents swallow the whole
      // 60-document window and bury genuine media. Correctness of the
      // current system wins. Nothing is migrated to compensate.
      await db.collection('posts').doc('legacy').set(<String, Object?>{
        'ownerUid': owner,
        'type': PostKind.upload,
        'mediaType': MediaType.image,
        'smallUrl': 'https://example.invalid/legacy.jpg',
        'thumbUrl': 'https://example.invalid/legacy.jpg',
        'createdAt': Timestamp.fromDate(DateTime(2024, 5, 1)),
      });
      expect(await media.watchGrid(owner).first, isEmpty);
    });

    test('the same post appears the moment it carries showInGrid', () async {
      // The exclusion is about the FIELD, not about the age of the document -
      // there is no separate legacy code path, and nothing is special-cased.
      await db.collection('posts').doc('legacy').set(<String, Object?>{
        'ownerUid': owner,
        'type': PostKind.upload,
        'mediaType': MediaType.image,
        'showInGrid': true,
        'smallUrl': 'https://example.invalid/legacy.jpg',
        'createdAt': Timestamp.fromDate(DateTime(2024, 5, 1)),
      });
      expect(
        (await media.watchGrid(owner).first).map((ProfileMediaItem i) => i.id),
        <String>['legacy'],
      );
    });

    test('image, video and proof media all qualify', () async {
      await seedMedia('img', createdAt: DateTime(2026, 1, 3));
      await seedMedia('vid',
          mediaType: MediaType.video, createdAt: DateTime(2026, 1, 2));
      await seedMedia('proof',
          mediaType: MediaType.video,
          type: PostKind.proof,
          showInGrid: true,
          createdAt: DateTime(2026, 1, 1));

      expect(
        (await media.watchGrid(owner).first).map((ProfileMediaItem i) => i.id),
        <String>['img', 'vid', 'proof'],
      );
    });

    test('an explicitly hidden post is still excluded', () async {
      await seedMedia('hidden', showInGrid: false);
      expect(await media.watchGrid(owner).first, isEmpty);
    });

    test('one malformed record does not remove its valid neighbours', () async {
      await seedMedia('good1', createdAt: DateTime(2026, 1, 3));
      await db.collection('posts').doc('malformed').set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': 42, // not even a string
        'createdAt': Timestamp.fromDate(DateTime(2026, 1, 2)),
      });
      await seedMedia('good2', createdAt: DateTime(2026, 1, 1));

      expect(
        (await media.watchGrid(owner).first).map((ProfileMediaItem i) => i.id),
        <String>['good1', 'good2'],
      );
    });

    test('another account media is never returned', () async {
      await seedMedia('mine');
      await db.collection('posts').doc('theirs').set(<String, Object?>{
        'ownerUid': 'someoneElse',
        'mediaType': MediaType.image,
        'showInGrid': true,
        'createdAt': Timestamp.now(),
      });
      expect(
        (await media.watchGrid(owner).first).map((ProfileMediaItem i) => i.id),
        <String>['mine'],
      );
    });
  });

  group('stories are not gallery posts', () {
    test('a story document lives outside posts and cannot reach the grid',
        () async {
      await db
          .collection('users')
          .doc(owner)
          .collection('stories')
          .doc('s1')
          .set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': MediaType.image,
        'url': 'https://example.invalid/story.jpg',
        'publishedAt': Timestamp.now(),
      });
      expect(await media.watchGrid(owner).first, isEmpty);
    });

    test('a story keeps its 24-hour life, separate from the permanent gallery',
        () {
      final DateTime published = DateTime(2026, 9, 1, 12);
      final StoryItem live = StoryItem(
        id: 's1',
        ownerUid: owner,
        mediaType: MediaType.image,
        publishedAt: published,
      );

      expect(live.isLiveAt(published.add(const Duration(hours: 23, minutes: 59))),
          isTrue);
      // At EXACTLY 24 hours it is over.
      expect(live.isLiveAt(published.add(const Duration(hours: 24))), isFalse);
    });
  });

  group('media type validation', () {
    test('only image and video are gallery media types', () {
      expect(normalizedMediaType('image'), MediaType.image);
      expect(normalizedMediaType('VIDEO'), MediaType.video);
      expect(normalizedMediaType('audio'), isNull);
      expect(normalizedMediaType(null), isNull);
      expect(normalizedMediaType(''), isNull);
      expect(normalizedMediaType(7), isNull);
    });

    test('a missing mediaType is NOT silently an image', () async {
      final DocumentReference<Map<String, dynamic>> ref =
          db.collection('posts').doc('noType');
      await ref.set(<String, Object?>{
        'ownerUid': owner,
        'createdAt': Timestamp.now(),
      });
      final ProfileMediaItem item =
          ProfileMediaItem.fromSnapshot(await ref.get());

      expect(item.mediaType, isNot(MediaType.image));
      expect(item.isSupported, isFalse);
    });
  });
}
