/// Honest offline behaviour for video.
///
/// The detail page used to call `getDownloadURL()` every single time a video
/// opened, even though the post document already carried the playable URL. That
/// round trip bought nothing when online and failed outright when offline — so
/// a clip whose bytes were sitting on the device could not be opened without a
/// connection, while the UI implied otherwise by having kept a `smallUrl`
/// string.
///
/// "Cached" here means the bytes are on disk. Nothing below claims offline
/// playback on the strength of a retained URL.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_identity.dart';
import 'package:localtest222/profile/data/media_video_source.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';

class _Store implements ProfileImageStore {
  _Store({this.onCached, this.onDownload});

  Future<File?> Function(String key)? onCached;
  Future<File> Function(String key)? onDownload;

  final List<String> cachedKeys = <String>[];
  final List<String> downloadKeys = <String>[];

  @override
  Future<File?> cached(String url, {String? key}) async {
    cachedKeys.add(key ?? url);
    final Future<File?> Function(String)? h = onCached;
    return h == null ? null : h(key ?? url);
  }

  @override
  Future<File> download(String url, {String? key}) {
    downloadKeys.add(key ?? url);
    final Future<File> Function(String)? h = onDownload;
    if (h == null) return Future<File>.error(const SocketException('offline'));
    return h(key ?? url);
  }

  @override
  Future<void> evict(String key) async {}
}

void main() {
  const String owner = 'athlete1';
  const String path = 'users/$owner/posts/clip1/original.mp4';
  const String url = 'https://firebasestorage.invalid/o/clip1.mp4'
      '?alt=media&token=rotates';

  final String key = profileMediaCacheKey(
    ownerUid: owner,
    variant: MediaVariant.original,
    storagePath: path,
  );

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gl_video_offline');
    VideoSourceResolver.resetFillTracking();
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  File cachedClip({int bytes = 1024}) {
    final File f = File('${tmp.path}/clip.mp4')..createSync(recursive: true);
    f.writeAsBytesSync(List<int>.filled(bytes, 7));
    return f;
  }

  group('a fully cached video opens offline from the local file', () {
    test('the cached file is used, and the network is never consulted',
        () async {
      final File local = cachedClip();
      final _Store store = _Store(onCached: (_) async => local);
      final VideoSourceResolver resolver = VideoSourceResolver(store: store);

      final VideoSource source =
          await resolver.resolve(url: url, cacheKey: key, online: false);

      expect(source.file?.path, local.path);
      expect(source.url, isNull);
      expect(store.downloadKeys, isEmpty);
    });

    test('the cache is asked for the stable key, not the tokened URL',
        () async {
      final _Store store = _Store(onCached: (_) async => cachedClip());
      await VideoSourceResolver(store: store)
          .resolve(url: url, cacheKey: key, online: false);

      expect(store.cachedKeys.single, key);
      expect(store.cachedKeys.single, isNot(contains('rotates')));
    });

    test('a zero-length cached file is not treated as playable', () async {
      final File empty = File('${tmp.path}/empty.mp4')..createSync();
      final _Store store = _Store(onCached: (_) async => empty);

      final VideoSource source = await VideoSourceResolver(store: store)
          .resolve(url: url, cacheKey: key, online: false);

      expect(source.file, isNull);
      expect(source.failure, MediaLoadFailure.offline);
    });
  });

  group('an uncached video offline says so', () {
    test('it reports offline rather than handing the player a dead URL',
        () async {
      final _Store store = _Store(onCached: (_) async => null);

      final VideoSource source = await VideoSourceResolver(store: store)
          .resolve(url: url, cacheKey: key, online: false);

      expect(source.isPlayable, isFalse);
      expect(source.failure, MediaLoadFailure.offline);
    });

    test('online, the same clip streams from the STORED url', () async {
      final _Store store = _Store(onCached: (_) async => null);

      final VideoSource source =
          await VideoSourceResolver(store: store).resolve(
        url: url,
        cacheKey: key,
      );

      expect(source.url, url);
      expect(source.fillFromUrl, url,
          reason: 'streaming leaves nothing on disk; the next open should not '
              'need the network either');
    });
  });

  group('staged media belongs to its owner and plays locally', () {
    test('a pending upload plays from the staged file, with no lookup',
        () async {
      final File staged = cachedClip(bytes: 32);
      final _Store store = _Store();

      final VideoSource source = await VideoSourceResolver(store: store)
          .resolve(
        url: '',
        cacheKey: key,
        localFilePath: staged.path,
        online: false,
      );

      expect(source.file?.path, staged.path);
      expect(store.cachedKeys, isEmpty);
      expect(store.downloadKeys, isEmpty);
    });

    test('a staged path that no longer exists falls through cleanly', () async {
      final _Store store = _Store(onCached: (_) async => null);

      final VideoSource source = await VideoSourceResolver(store: store)
          .resolve(
        url: url,
        cacheKey: key,
        localFilePath: '${tmp.path}/never-existed.mp4',
      );

      expect(source.url, url);
    });
  });

  group('a poster is never handed to the player', () {
    test('an image URL is refused with a stated reason', () async {
      final VideoSource source = await VideoSourceResolver(store: _Store())
          .resolve(url: 'https://example.invalid/poster.jpg', cacheKey: key);

      expect(source.isPlayable, isFalse);
      expect(source.failure, MediaLoadFailure.unusableSource);
    });

    test('an empty URL with no staged file is refused', () async {
      final VideoSource source = await VideoSourceResolver(store: _Store())
          .resolve(url: '', cacheKey: key);

      expect(source.failure, MediaLoadFailure.unusableSource);
    });
  });

  group('the background cache fill cannot become a download loop', () {
    test('a fill runs once per key', () async {
      int downloads = 0;
      final _Store store = _Store(onDownload: (_) async {
        downloads++;
        return cachedClip();
      });
      final VideoSourceResolver resolver = VideoSourceResolver(store: store);

      expect(await resolver.fill(url: url, cacheKey: key), isTrue);
      expect(await resolver.fill(url: url, cacheKey: key), isFalse);
      expect(downloads, 1);
    });

    test('a failed fill is never reported as an error, and may be retried',
        () async {
      final _Store store = _Store(
          onDownload: (_) => Future<File>.error(const SocketException('down')));
      final VideoSourceResolver resolver = VideoSourceResolver(store: store);

      expect(await resolver.fill(url: url, cacheKey: key), isFalse);
      // Allowed again: a fill that failed because the connection dropped must
      // not mark the clip permanently un-cacheable.
      expect(await resolver.fill(url: url, cacheKey: key), isFalse);
      expect(store.downloadKeys, hasLength(2));
    });

    test('a wedged cache index does not block playback', () async {
      final _Store store =
          _Store(onCached: (_) => Completer<File?>().future);

      final VideoSource source = await VideoSourceResolver(
        store: store,
        readTimeout: const Duration(milliseconds: 50),
      ).resolve(url: url, cacheKey: key);

      expect(source.url, url);
    });
  });
}
