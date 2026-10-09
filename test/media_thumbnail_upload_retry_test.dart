/// A video's poster frame is uploaded beside the clip. Whether a failure there
/// is retried decides whether the post ever gets a feed preview — and whether
/// it gets published at all.
library;

import 'dart:async';
import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/data/media_outbox.dart';
import 'package:localtest222/profile/data/media_uploader.dart';
import 'package:localtest222/profile/data/profile_repository.dart';
import 'package:localtest222/profile/data/showcase_repository.dart';
import 'package:localtest222/profile/data/story_repository.dart';

void main() {
  const String owner = 'ownerUid';
  const String videoPath = 'users/$owner/posts/v1/original.mov';
  const String thumbPath = 'users/$owner/posts/v1/thumb.jpg';

  late Directory tmp;
  late MediaOutbox outbox;
  late FakeFirebaseFirestore db;
  late _Storage storage;
  late MediaUploader uploader;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('thumb_retry');
    outbox = MediaOutbox(MediaOutboxDatabase.memory());
    db = FakeFirebaseFirestore();
    storage = _Storage();
    uploader = MediaUploader(
      firestore: db,
      storage: storage,
      outbox: outbox,
      profiles: ProfileRepository(firestore: db),
      showcase: ShowcaseRepository(firestore: db),
      stories: StoryRepository(firestore: db, outbox: outbox),
      ownerUidOverride: () => owner,
    );
  });

  tearDown(() async {
    await outbox.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<OutboxItem> queueVideo({bool withThumb = true}) {
    final File video = File('${tmp.path}/v1.mov')..writeAsBytesSync(<int>[1]);
    final File thumb = File('${tmp.path}/v1.jpg');
    if (withThumb) thumb.writeAsBytesSync(<int>[0xFF, 0xD8]);
    return outbox.enqueue(
      mediaId: 'v1',
      ownerUid: owner,
      kind: OutboxKind.post,
      mediaType: MediaType.video,
      storagePath: videoPath,
      localFilePath: video.path,
      localThumbPath: thumb.path,
    );
  }

  group('uploadThumbnail', () {
    test('a transient failure is rethrown so the outbox retries it', () async {
      final OutboxItem item = await queueVideo();
      storage.failures[thumbPath] =
          FirebaseException(plugin: 'firebase_storage', code: 'unknown');
      await expectLater(
          uploader.uploadThumbnail(item), throwsA(isA<FirebaseException>()));

      storage.failures[thumbPath] = const SocketException('no route');
      await expectLater(
          uploader.uploadThumbnail(item), throwsA(isA<SocketException>()));
    });

    test('a permanent refusal yields no preview rather than an error',
        () async {
      final OutboxItem item = await queueVideo();
      storage.failures[thumbPath] =
          FirebaseException(plugin: 'firebase_storage', code: 'unauthorized');
      expect(await uploader.uploadThumbnail(item), isNull);
    });

    test('a video with no local still is not an error', () async {
      final OutboxItem item = await queueVideo(withThumb: false);
      expect(await uploader.uploadThumbnail(item), isNull);
      expect(storage.uploads, isEmpty);
    });

    test('a still that uploads returns the poster URL, never the clip',
        () async {
      final OutboxItem item = await queueVideo();
      expect(await uploader.uploadThumbnail(item), 'https://fake/$thumbPath');
      expect(storage.uploads, <String>[thumbPath]);
    });
  });

  group('a pass over the outbox', () {
    test('a transient poster failure publishes nothing, keeps the local '
        'still and costs no attempt; the next pass publishes with a preview',
        () async {
      final OutboxItem item = await queueVideo();
      storage.failures[thumbPath] =
          FirebaseException(plugin: 'firebase_storage', code: 'unknown');

      await uploader.processAll();
      expect((await db.collection('posts').doc('v1').get()).exists, isFalse,
          reason: 'a post without its preview must not be published yet');
      final OutboxItem? waiting = await outbox.byId('v1');
      expect(waiting, isNotNull);
      expect(waiting!.state, OutboxState.pending);
      expect(waiting.attemptCount, 0);
      expect(File(item.localThumbPath!).existsSync(), isTrue,
          reason: 'the still is the only copy; a retry needs it');

      storage.failures.clear();
      await uploader.processAll();
      final Map<String, dynamic>? post =
          (await db.collection('posts').doc('v1').get()).data();
      expect(post, isNotNull);
      expect(post!['thumbUrl'], 'https://fake/$thumbPath');
      expect(post['thumbUrl'], isNot(contains('original')));
    });

    test('a permanently refused poster still publishes the playable clip',
        () async {
      await queueVideo();
      storage.failures[thumbPath] =
          FirebaseException(plugin: 'firebase_storage', code: 'unauthorized');

      await uploader.processAll();
      final Map<String, dynamic>? post =
          (await db.collection('posts').doc('v1').get()).data();
      expect(post, isNotNull,
          reason: 'a refused preview must not cost the clip its publication');
      expect(post!['thumbUrl'], '');
      expect(post['smallUrl'], 'https://fake/$videoPath');
    });
  });
}

/// A bucket whose per-path outcome the test decides.
class _Storage extends Fake implements FirebaseStorage {
  final Map<String, Object> failures = <String, Object>{};
  final List<String> uploads = <String>[];

  @override
  Reference ref([String? path]) => _Ref(this, path ?? '');
}

class _Ref extends Fake implements Reference {
  _Ref(this._storage, this._path);

  final _Storage _storage;
  final String _path;

  @override
  UploadTask putFile(File file, [SettableMetadata? metadata]) {
    final Object? failure = _storage.failures[_path];
    if (failure != null) throw failure;
    _storage.uploads.add(_path);
    return _Task();
  }

  @override
  Future<String> getDownloadURL() async => 'https://fake/$_path';

  @override
  Future<void> delete() async {}
}

class _Task extends Fake implements UploadTask {
  final Future<TaskSnapshot> _done =
      Future<TaskSnapshot>.value(_Snapshot());

  @override
  Future<R> then<R>(
    FutureOr<R> Function(TaskSnapshot value) onValue, {
    Function? onError,
  }) =>
      _done.then(onValue, onError: onError);
}

class _Snapshot extends Fake implements TaskSnapshot {}
