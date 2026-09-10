// The buddy feed: paging, deduplication, ordering and what never reaches a card.
//
// The defects these cover, all of which the legacy home feed had:
//   * `ownerUid whereIn [...]` silently stopped covering a viewer past 30
//     buddies, because that is Firestore's ceiling on the operator;
//   * paging by `startAfter([createdAt])` is an offset into a timestamp, so two
//     posts sharing one were repeated or skipped at the page boundary;
//   * RE Daily documents, records with no media and unknown media types were
//     fetched, then filtered out in the builder, leaving short pages and blank
//     tiles;
//   * nothing deduplicated, so a refresh racing a page load showed a post twice.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_identity.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/social/feed_repository.dart';

const String kViewer = 'viewer-uid';

/// Writes one row into the viewer's feed projection, the way
/// functions/social/feed.js does.
Future<void> seedFeedRow(
  FakeFirebaseFirestore db, {
  required String ownerUid,
  required String postId,
  required DateTime createdAt,
  String mediaType = MediaType.image,
  String smallUrl = 'https://example.test/small.jpg',
  String thumbUrl = 'https://example.test/thumb.jpg',
  String storagePathOriginal = 'posts/o/original.jpg',
  String thumbStoragePath = 'posts/o/thumb.jpg',
  String caption = '',
  String viewerUid = kViewer,
}) {
  return db
      .collection('users')
      .doc(viewerUid)
      .collection('feed')
      .doc('${ownerUid}__$postId')
      .set(<String, Object?>{
    'ownerUid': ownerUid,
    'postId': postId,
    'createdAt': Timestamp.fromDate(createdAt),
    'mediaType': mediaType,
    'smallUrl': smallUrl,
    'thumbUrl': thumbUrl,
    'storagePathOriginal': storagePathOriginal,
    'thumbStoragePath': thumbStoragePath,
    'caption': caption,
  });
}

FeedItem item(
  String id, {
  String ownerUid = 'o',
  DateTime? createdAt,
}) =>
    FeedItem(
      id: id,
      ownerUid: ownerUid,
      postId: id,
      mediaType: MediaType.image,
      smallUrl: 'https://example.test/$id.jpg',
      createdAt: createdAt,
    );

void main() {
  group('renderability', () {
    test('a complete image row renders', () {
      expect(
        const FeedItem(
          id: 'a__1',
          ownerUid: 'a',
          postId: '1',
          mediaType: MediaType.image,
          smallUrl: 'https://example.test/s.jpg',
        ).isRenderable,
        isTrue,
      );
    });

    test('an unknown or missing media type never reaches a decoder', () {
      // The defect this prevents: defaulting a missing mediaType to `image`
      // is how a video URL ends up in an image decoder, and how an RE Daily
      // record with no media at all claims a tile.
      for (final String type in <String>['', 're_daily', 'audio', 'unknown']) {
        expect(
          FeedItem(
            id: 'a__1',
            ownerUid: 'a',
            postId: '1',
            mediaType: type,
            smallUrl: 'https://example.test/s.jpg',
          ).isRenderable,
          isFalse,
          reason: 'media type "$type" must not render',
        );
      }
    });

    test('a row with no media at all does not render', () {
      expect(
        const FeedItem(
          id: 'a__1',
          ownerUid: 'a',
          postId: '1',
          mediaType: MediaType.image,
        ).isRenderable,
        isFalse,
      );
    });

    test('a video shows its poster, never the clip', () {
      const FeedItem video = FeedItem(
        id: 'a__1',
        ownerUid: 'a',
        postId: '1',
        mediaType: MediaType.video,
        thumbUrl: 'https://example.test/poster.jpg',
        smallUrl: 'https://example.test/small.jpg',
        thumbStoragePath: 'posts/a/poster.jpg',
        storagePath: 'posts/a/clip.mp4',
      );
      expect(video.isVideo, isTrue);
      expect(video.displayUrl, 'https://example.test/poster.jpg');
      // The Storage path behind the drawn image is the POSTER's, so nothing
      // here can start fetching a video container.
      expect(video.displayStoragePath, 'posts/a/poster.jpg');
    });
  });

  group('cache identity', () {
    test('a feed card and the profile grid key the same object identically', () {
      // This is what makes an already-seen photo appear with no second
      // download and no second copy on disk. If these two ever diverge the
      // feature still works and silently doubles the cache.
      const FeedItem photo = FeedItem(
        id: 'owner__p1',
        ownerUid: 'owner',
        postId: 'p1',
        mediaType: MediaType.image,
        smallUrl: 'https://example.test/s.jpg?token=rotating-one',
        storagePath: 'posts/owner/p1.jpg',
      );
      expect(
        photo.displayCacheKey,
        profileMediaCacheKey(
          ownerUid: 'owner',
          variant: MediaVariant.small,
          storagePath: 'posts/owner/p1.jpg',
          mediaId: 'p1',
          url: 'https://example.test/s.jpg?token=rotating-one',
        ),
      );
    });

    test('a rotating download token does not change the key', () {
      String keyFor(String token) => FeedItem(
            id: 'owner__p1',
            ownerUid: 'owner',
            postId: 'p1',
            mediaType: MediaType.image,
            smallUrl: 'https://example.test/s.jpg?alt=media&token=$token',
            storagePath: 'posts/owner/p1.jpg',
          ).displayCacheKey;
      // A token rotation must not orphan the cached bytes and re-download
      // the same photo.
      expect(keyFor('aaaa'), keyFor('bbbb'));
    });

    test('two accounts never share a cache entry', () {
      String keyFor(String owner) => FeedItem(
            id: '${owner}__p1',
            ownerUid: owner,
            postId: 'p1',
            mediaType: MediaType.image,
            smallUrl: 'https://example.test/s.jpg',
            storagePath: 'posts/$owner/p1.jpg',
          ).displayCacheKey;
      expect(keyFor('alice'), isNot(keyFor('bob')));
    });
  });

  group('merge', () {
    test('newest first', () {
      final DateTime t0 = DateTime.utc(2026, 1, 1);
      final List<FeedItem> merged = FeedRepository.merge(
        <FeedItem>[item('a', createdAt: t0)],
        <FeedItem>[
          item('b', createdAt: t0.add(const Duration(hours: 1))),
          item('c', createdAt: t0.subtract(const Duration(hours: 1))),
        ],
      );
      expect(merged.map((FeedItem i) => i.id).toList(), <String>['b', 'a', 'c']);
    });

    test('a post arriving twice appears once', () {
      final DateTime t = DateTime.utc(2026, 1, 1);
      final List<FeedItem> merged = FeedRepository.merge(
        <FeedItem>[item('a', createdAt: t)],
        <FeedItem>[item('a', createdAt: t), item('b', createdAt: t)],
      );
      expect(merged.length, 2);
      expect(merged.where((FeedItem i) => i.id == 'a').length, 1);
    });

    test('posts sharing a timestamp get a stable, deterministic order', () {
      // The exact case the timestamp cursor could not serve: without a
      // tie-break these two swap between rebuilds, and a reader watching the
      // list sees content jump.
      final DateTime t = DateTime.utc(2026, 1, 1);
      final List<FeedItem> a = FeedRepository.merge(
        const <FeedItem>[],
        <FeedItem>[item('z', createdAt: t), item('y', createdAt: t)],
      );
      final List<FeedItem> b = FeedRepository.merge(
        const <FeedItem>[],
        <FeedItem>[item('y', createdAt: t), item('z', createdAt: t)],
      );
      expect(a.map((FeedItem i) => i.id).toList(),
          b.map((FeedItem i) => i.id).toList());
      expect(a.map((FeedItem i) => i.id).toList(), <String>['y', 'z']);
    });

    test('a row with no timestamp sinks rather than displacing real content', () {
      final List<FeedItem> merged = FeedRepository.merge(
        const <FeedItem>[],
        <FeedItem>[
          item('undated'),
          item('dated', createdAt: DateTime.utc(2020, 1, 1)),
        ],
      );
      expect(merged.first.id, 'dated');
      expect(merged.last.id, 'undated');
    });

    test('merging is not destructive of what is already on screen', () {
      final DateTime t = DateTime.utc(2026, 1, 1);
      final List<FeedItem> existing = <FeedItem>[item('a', createdAt: t)];
      final List<FeedItem> merged =
          FeedRepository.merge(existing, const <FeedItem>[]);
      expect(merged.map((FeedItem i) => i.id), contains('a'));
    });
  });

  group('distinctOwners', () {
    test('resolves each account once, however many posts they have', () {
      final List<String> owners = FeedRepository.distinctOwners(<FeedItem>[
        item('1', ownerUid: 'a'),
        item('2', ownerUid: 'a'),
        item('3', ownerUid: 'b'),
        item('4', ownerUid: ''),
      ]);
      expect(owners.toSet(), <String>{'a', 'b'});
    });
  });

  group('paging against the projection', () {
    late FakeFirebaseFirestore db;
    late FeedRepository repo;
    final DateTime base = DateTime.utc(2026, 3, 1, 12);

    setUp(() async {
      db = FakeFirebaseFirestore();
      repo = FeedRepository(firestore: db, overrideUid: kViewer, pageSize: 3);
      for (int i = 0; i < 7; i += 1) {
        await seedFeedRow(
          db,
          ownerUid: i.isEven ? 'friend-a' : 'friend-b',
          postId: 'p$i',
          createdAt: base.subtract(Duration(hours: i)),
        );
      }
    });

    test('the first page is bounded and newest first', () async {
      final FeedPage page = await repo.loadPage();
      expect(page.items.length, 3);
      expect(page.hasMore, isTrue);
      expect(
        page.items.map((FeedItem i) => i.postId).toList(),
        <String>['p0', 'p1', 'p2'],
      );
    });

    test('paging walks the whole feed without repeating or skipping', () async {
      final List<FeedItem> all = <FeedItem>[];
      DocumentSnapshot<Map<String, dynamic>>? cursor;
      bool more = true;
      int guard = 0;
      while (more && guard < 10) {
        final FeedPage page = await repo.loadPage(cursor: cursor);
        all.addAll(page.items);
        cursor = page.cursor;
        more = page.hasMore;
        guard += 1;
      }
      expect(all.length, 7);
      expect(all.map((FeedItem i) => i.postId).toSet().length, 7,
          reason: 'no post may appear on two pages');
      expect(
        all.map((FeedItem i) => i.postId).toList(),
        <String>['p0', 'p1', 'p2', 'p3', 'p4', 'p5', 'p6'],
      );
    });

    test('the last page reports that there is no more', () async {
      DocumentSnapshot<Map<String, dynamic>>? cursor;
      FeedPage page = await repo.loadPage();
      while (page.hasMore) {
        cursor = page.cursor;
        page = await repo.loadPage(cursor: cursor);
      }
      expect(page.hasMore, isFalse);
    });

    test('posts sharing an exact timestamp are neither skipped nor repeated',
        () async {
      // The document cursor's whole reason for existing. A timestamp offset
      // either re-serves or steps over rows that tie.
      final FakeFirebaseFirestore tied = FakeFirebaseFirestore();
      final DateTime same = DateTime.utc(2026, 4, 1, 9);
      for (int i = 0; i < 5; i += 1) {
        await seedFeedRow(
          tied,
          ownerUid: 'friend',
          postId: 'tie$i',
          createdAt: same,
        );
      }
      final FeedRepository r =
          FeedRepository(firestore: tied, overrideUid: kViewer, pageSize: 2);

      final List<String> seen = <String>[];
      DocumentSnapshot<Map<String, dynamic>>? cursor;
      bool more = true;
      int guard = 0;
      while (more && guard < 10) {
        final FeedPage page = await r.loadPage(cursor: cursor);
        seen.addAll(page.items.map((FeedItem i) => i.postId));
        cursor = page.cursor;
        more = page.hasMore;
        guard += 1;
      }
      expect(seen.length, 5);
      expect(seen.toSet().length, 5);
    });

    test('an empty feed is an empty page, not an error', () async {
      final FeedRepository empty = FeedRepository(
        firestore: FakeFirebaseFirestore(),
        overrideUid: kViewer,
      );
      final FeedPage page = await empty.loadPage();
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('a malformed row is dropped rather than drawn as a blank tile',
        () async {
      final FakeFirebaseFirestore mixed = FakeFirebaseFirestore();
      await seedFeedRow(
        mixed,
        ownerUid: 'friend',
        postId: 'good',
        createdAt: base,
      );
      // An RE Daily record that somehow reached a feed, and a row whose media
      // fields are all empty. Both would have been blank tiles.
      await mixed
          .collection('users')
          .doc(kViewer)
          .collection('feed')
          .doc('friend__daily')
          .set(<String, Object?>{
        'ownerUid': 'friend',
        'postId': 'daily',
        'createdAt': Timestamp.fromDate(base),
        'mediaType': 're_daily',
      });
      await mixed
          .collection('users')
          .doc(kViewer)
          .collection('feed')
          .doc('friend__empty')
          .set(<String, Object?>{
        'ownerUid': 'friend',
        'postId': 'empty',
        'createdAt': Timestamp.fromDate(base),
        'mediaType': 'image',
      });

      final FeedPage page = await FeedRepository(
        firestore: mixed,
        overrideUid: kViewer,
      ).loadPage();
      expect(page.items.map((FeedItem i) => i.postId).toList(), <String>['good']);
    });

    test('an unfriended account\'s rows stop arriving once removed', () async {
      // The projection is server-maintained: purging the rows is what ends the
      // visibility, and the client simply reads what is there.
      final FeedPage before = await repo.loadPage();
      expect(before.items, isNotEmpty);

      final QuerySnapshot<Map<String, dynamic>> rows = await db
          .collection('users')
          .doc(kViewer)
          .collection('feed')
          .where('ownerUid', isEqualTo: 'friend-a')
          .get();
      for (final QueryDocumentSnapshot<Map<String, dynamic>> d in rows.docs) {
        await d.reference.delete();
      }

      final FeedPage after = await repo.loadPage();
      expect(
        after.items.map((FeedItem i) => i.ownerUid),
        isNot(contains('friend-a')),
      );
      expect(after.items, isNotEmpty, reason: 'the other friend still shows');
    });
  });
}
