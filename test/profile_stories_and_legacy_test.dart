import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/big_five.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/core/showcase_models.dart';
import 'package:localtest222/profile/core/showcase_reducer.dart';
import 'package:localtest222/profile/data/media_outbox.dart';
import 'package:localtest222/profile/data/media_repository.dart';
import 'package:localtest222/profile/data/showcase_repository.dart';
import 'package:localtest222/profile/data/story_repository.dart';

void main() {
  const String owner = 'ownerUid';
  const String bench = 'AmfUWbF1DH3I7qPAdh5k';

  late FakeFirebaseFirestore db;
  late MediaOutbox outbox;

  setUp(() {
    db = FakeFirebaseFirestore();
    outbox = MediaOutbox(MediaOutboxDatabase.memory());
  });

  tearDown(() async {
    await outbox.close();
  });

  group('story expiry is exactly 24 hours', () {
    final DateTime published = DateTime.utc(2026, 8, 29, 12);

    StoryItem storyAt(DateTime? publishedAt) => StoryItem(
          id: 's1',
          ownerUid: owner,
          mediaType: MediaType.image,
          publishedAt: publishedAt,
        );

    test('the lifetime is 24 hours', () {
      expect(StoryItem.ttl, const Duration(hours: 24));
    });

    test('live for the whole window', () {
      final StoryItem s = storyAt(published);
      expect(s.isLiveAt(published), isTrue);
      expect(
          s.isLiveAt(published.add(const Duration(milliseconds: 1))), isTrue);
      expect(s.isLiveAt(published.add(const Duration(hours: 23, minutes: 59))),
          isTrue);
      expect(
        s.isLiveAt(published
            .add(const Duration(hours: 24) - const Duration(milliseconds: 1))),
        isTrue,
      );
    });

    test('at EXACTLY 24 hours it is expired', () {
      expect(
          storyAt(published).isLiveAt(published.add(const Duration(hours: 24))),
          isFalse);
    });

    test('and it stays expired afterwards', () {
      final StoryItem s = storyAt(published);
      expect(
          s.isLiveAt(published.add(
              const Duration(hours: 24) + const Duration(milliseconds: 1))),
          isFalse);
      expect(s.isLiveAt(published.add(const Duration(days: 7))), isFalse);
    });

    test('expiresAt is publication plus the TTL, to the millisecond', () {
      expect(storyAt(published).expiresAt,
          published.add(const Duration(hours: 24)));
    });

    test('a story with no publication time has NOT started expiring', () {
      // The offline case: staged locally, never published. It is not live to
      // anyone, and its clock has not begun.
      final StoryItem s = storyAt(null);
      expect(s.isLiveAt(published), isFalse);
      expect(s.expiresAt, isNull);
    });

    test('the boundary matches the Cloud Functions sweep', () {
      // The scheduler deletes publishedAt <= now - 24h. A story exactly at that
      // cutoff must also read as not live here, or one side would show a story
      // the other has deleted.
      final DateTime now = published.add(const Duration(hours: 24));
      final DateTime cutoff = now.subtract(const Duration(hours: 24));
      expect(storyAt(cutoff).isLiveAt(now), isFalse);
      expect(
        storyAt(cutoff.add(const Duration(milliseconds: 1))).isLiveAt(now),
        isTrue,
      );
    });
  });

  group('the story query', () {
    late StoryRepository stories;

    setUp(() {
      stories = StoryRepository(firestore: db, outbox: outbox);
    });

    Future<void> seedStory(String id, Duration ago) =>
        db.collection('users').doc(owner).collection('stories').doc(id).set(
          <String, Object?>{
            'ownerUid': owner,
            'mediaType': MediaType.image,
            'publishedAt': Timestamp.fromDate(DateTime.now().subtract(ago)),
          },
        );

    test('hides expired stories and keeps live ones, oldest first', () async {
      await seedStory('expired', const Duration(hours: 30));
      await seedStory('newest', const Duration(minutes: 5));
      await seedStory('older', const Duration(hours: 20));

      final List<StoryItem> live = await stories.watchLive(owner).first;
      expect(live.map((StoryItem s) => s.id), <String>['older', 'newest']);
    });

    test('supports several current stories', () async {
      for (int i = 1; i <= 4; i++) {
        await seedStory('s$i', Duration(hours: i));
      }
      final List<StoryItem> live = await stories.watchLive(owner).first;
      expect(live, hasLength(4));
    });

    test('a story just under 24 hours old is still returned', () async {
      await seedStory('edge', const Duration(hours: 23, minutes: 55));
      final List<StoryItem> live = await stories.watchLive(owner).first;
      expect(live.map((StoryItem s) => s.id), <String>['edge']);
    });

    test(
        'the final ${kStoryQuerySkewMargin.inSeconds}s is given up to the '
        'clock-skew margin', () async {
      // The security rule now enforces the same 24 hours on the SERVER clock,
      // and Firestore denies a whole query whose result set contains one
      // unreadable document. A device whose clock runs slow would otherwise
      // ask for a story the server calls expired and lose EVERY story on the
      // profile. Moving the cutoff forward by the margin trades the story's
      // last minute — which the viewer was about to lose anyway — for that.
      await seedStory(
        'lastMinute',
        StoryItem.ttl - (kStoryQuerySkewMargin ~/ 2),
      );
      final List<StoryItem> live = await stories.watchLive(owner).first;
      expect(live, isEmpty);
    });

    test('publishing sends a server timestamp and no client expiry', () async {
      await stories.publish(
        ownerUid: owner,
        storyId: 's1',
        mediaType: MediaType.image,
        storagePath: 'users/$owner/stories/s1/original.jpg',
        url: 'https://example.invalid/s1.jpg',
      );
      final Map<String, dynamic> data = (await db
              .collection('users')
              .doc(owner)
              .collection('stories')
              .doc('s1')
              .get())
          .data()!;
      expect(data['publishedAt'], isNotNull);
      expect(data.containsKey('expiresAt'), isFalse);
      expect(data['ownerUid'], owner);
    });

    test('exists() is what makes a re-publish a no-op', () async {
      expect(await stories.exists(owner, 's1'), isFalse);
      await stories.publish(
        ownerUid: owner,
        storyId: 's1',
        mediaType: MediaType.image,
        storagePath: 'p',
        url: 'u',
      );
      expect(await stories.exists(owner, 's1'), isTrue);
    });

    test('deleting a story removes it', () async {
      await seedStory('s1', const Duration(hours: 1));
      await stories.delete(owner, 's1');
      expect(await stories.watchLive(owner).first, isEmpty);
    });
  });

  group('existing posts stay compatible', () {
    late MediaRepository media;

    setUp(() {
      media = MediaRepository(firestore: db, outbox: outbox);
    });

    test('a legacy post with no type and no showInGrid still appears',
        () async {
      await db.collection('posts').doc('legacy').set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': 'image',
        'storagePathOriginal': 'users/$owner/posts/legacy/original.jpg',
        'smallUrl': 'https://example.invalid/small.jpg',
        'thumbUrl': 'https://example.invalid/thumb.jpg',
        'caption': 'An old caption',
        'likeCount': 3,
        'goodLiftCount': 2,
        'commentCount': 5,
        'createdAt': Timestamp.fromDate(DateTime(2024, 6, 1)),
      });

      final List<ProfileMediaItem> grid = await media.watchGrid(owner).first;
      expect(grid, hasLength(1));
      final ProfileMediaItem item = grid.single;
      expect(item.kind, PostKind.upload);
      expect(item.showInGrid, isTrue);
      // Everything the old page displayed is still read.
      expect(item.caption, 'An old caption');
      expect(item.likeCount, 3);
      expect(item.goodLiftCount, 2);
      expect(item.commentCount, 5);
      expect(item.smallUrl, 'https://example.invalid/small.jpg');
      expect(item.storagePath, 'users/$owner/posts/legacy/original.jpg');
    });

    test('an RE Daily record is not gallery media and never takes a slot',
        () async {
      // This used to assert the opposite - that an RE Daily card belongs in the
      // grid. It does not. RE Daily writes a summary record into `posts` on
      // every training day with no media of any kind (see `_upsertDailyPost` in
      // re_daily.dart): no mediaType, no smallUrl, no thumbUrl. Each one
      // rendered as a blank image placeholder, and because the eligibility test
      // ran on the CLIENT after limit(60), enough of them pushed the owner's
      // real photos out of the query window entirely.
      await db.collection('posts').doc('daily').set(<String, Object?>{
        'ownerUid': owner,
        'type': PostKind.reDaily,
        'dayKey': '2026-09-01',
        'dailyTotal': 12.5,
        'createdAt': Timestamp.now(),
      });
      await db.collection('posts').doc('realPhoto').set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': 'image',
        'smallUrl': 'https://example.invalid/real.jpg',
        'createdAt': Timestamp.fromDate(DateTime(2024, 1, 1)),
      });

      final List<ProfileMediaItem> grid = await media.watchGrid(owner).first;

      expect(grid.map((ProfileMediaItem i) => i.id), <String>['realPhoto']);
    });

    test('a legacy video post is recognised as a video', () async {
      await db.collection('posts').doc('vid').set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': 'video',
        'createdAt': Timestamp.now(),
      });
      expect((await media.watchGrid(owner).first).single.isVideo, isTrue);
    });

    test('one account never sees another account media', () async {
      await db.collection('posts').doc('mine').set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': 'image',
        'createdAt': Timestamp.now(),
      });
      await db.collection('posts').doc('theirs').set(<String, Object?>{
        'ownerUid': 'someoneElse',
        'mediaType': 'image',
        'createdAt': Timestamp.now(),
      });
      expect(
        (await media.watchGrid(owner).first).map((ProfileMediaItem i) => i.id),
        <String>['mine'],
      );
    });
  });

  group('legacy lift videos are never auto-claimed as proof', () {
    late ShowcaseRepository showcase;

    ShowcaseRecord recordFor() => buildShowcase(<String, Object?>{
          '2026-04-17': <String, Object?>{
            'exercises': <Object?>[
              <String, Object?>{
                'exerciseId': bench,
                'sets': <Object?>[
                  <String, Object?>{'weight': 180, 'reps': 2},
                ],
              },
            ],
          },
        }).forSlot(BigFiveSlot.bench).heaviest!;

    setUp(() {
      showcase = ShowcaseRepository(firestore: db);
    });

    test('an existing liftVideos document creates no proof pointer', () async {
      // These predate record provenance: nothing about the old video says WHICH
      // performance it shows, so claiming it would put an unearned badge on a
      // record.
      await db
          .collection('users')
          .doc(owner)
          .collection('liftVideos')
          .doc('bench_barbell')
          .set(<String, Object?>{
        'liftId': 'bench_barbell',
        'remoteUrl': 'https://example.invalid/old.mp4',
        'thumbUrl': 'https://example.invalid/old.jpg',
      });

      final Map<String, ProofRecord> proofs =
          await showcase.watchProofs(owner).first;
      expect(proofs, isEmpty);
    });

    test('an explicit relink attaches existing media with no re-upload',
        () async {
      final ShowcaseRecord record = recordFor();
      const ProfileMediaItem existing = ProfileMediaItem(
        id: 'oldPost',
        ownerUid: owner,
        mediaType: MediaType.video,
        kind: PostKind.upload,
        storagePath: 'users/ownerUid/posts/oldPost/original.mp4',
        thumbUrl: 'https://example.invalid/old.jpg',
      );

      await showcase.relinkExistingMedia(
        ownerUid: owner,
        record: record,
        postId: existing.id,
        storagePath: existing.storagePath,
        mediaType: existing.mediaType,
        thumbUrl: existing.thumbUrl,
      );

      final Map<String, ProofRecord> proofs =
          await showcase.watchProofs(owner).first;
      expect(proofs.keys, <String>[record.fingerprint]);
      expect(proofs[record.fingerprint]!.postId, 'oldPost',
          reason: 'the same asset is reused; nothing was uploaded again');
      expect(proofs[record.fingerprint]!.storagePath, existing.storagePath);
    });

    test('a relink records the provenance of the record it claims', () async {
      final ShowcaseRecord record = recordFor();
      await showcase.attachProof(
        ownerUid: owner,
        record: record,
        postId: 'p1',
        storagePath: 'users/ownerUid/posts/p1/original.mp4',
      );
      final Map<String, dynamic> data = (await db
              .collection('users')
              .doc(owner)
              .collection('proofs')
              .doc(record.fingerprint)
              .get())
          .data()!;
      expect(data['recordDateKey'], '2026-04-17');
      expect(data['recordWeight'], 180);
      expect(data['recordReps'], 2);
      expect(data['recordSetKey'], record.setKey);
      expect(data['formulaVersion'], record.formulaVersion);
    });

    test('attaching twice repoints rather than duplicating', () async {
      final ShowcaseRecord record = recordFor();
      await showcase.attachProof(
        ownerUid: owner,
        record: record,
        postId: 'first',
        storagePath: 'a',
      );
      await showcase.attachProof(
        ownerUid: owner,
        record: record,
        postId: 'second',
        storagePath: 'b',
      );
      final QuerySnapshot<Map<String, dynamic>> all =
          await db.collection('users').doc(owner).collection('proofs').get();
      expect(all.docs, hasLength(1));
      expect(all.docs.single.data()['postId'], 'second');
    });

    test('detaching removes only the claim, never the media', () async {
      final ShowcaseRecord record = recordFor();
      await db.collection('posts').doc('p1').set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': 'video',
        'createdAt': Timestamp.now(),
      });
      await showcase.attachProof(
        ownerUid: owner,
        record: record,
        postId: 'p1',
        storagePath: 'users/ownerUid/posts/p1/original.mp4',
      );

      await showcase.detachProof(owner, record.fingerprint);

      expect(await showcase.watchProofs(owner).first, isEmpty);
      expect((await db.collection('posts').doc('p1').get()).exists, isTrue,
          reason: 'the video stays in the gallery');
    });
  });
}
