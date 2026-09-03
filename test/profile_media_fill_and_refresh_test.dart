/// Two things that must not cost the user bandwidth or a broken screen:
/// the background cache fill, and a stored URL whose access token was revoked.
///
/// ── The fill, and the one extra transfer ────────────────────────────────────
/// Streaming a video writes nothing that outlives the player, so a clip watched
/// online is still unavailable offline afterwards. Making the FIRST open
/// offline-capable means either downloading before playback — a spinner for the
/// length of the download — or fetching once more in the background while it
/// plays. Getting both would mean teeing the player's own byte stream into the
/// cache, which needs a local proxy or a caching data source: a new native
/// dependency in the playback path of a production app, to save one transfer
/// per clip ever opened. The trade is deliberate; what these tests pin down is
/// that "one extra transfer, once, ever" is actually true.
///
/// ── The refresh ────────────────────────────────────────────────────────────
/// A download URL embeds an access token that can be revoked. The object is
/// still there and the user is still allowed to see it; the stored string just
/// no longer opens it. One fresh URL, one retry, the same cache entry.
library;

import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_identity.dart';
import 'package:localtest222/profile/data/media_url_refresh.dart';
import 'package:localtest222/profile/data/media_video_source.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';

class _Store implements ProfileImageStore {
  _Store({this.onCached, this.onDownload});

  Future<File?> Function(String key)? onCached;
  Future<File> Function(String key, String url)? onDownload;

  final List<String> cachedKeys = <String>[];
  final List<String> downloadKeys = <String>[];
  final List<String> downloadUrls = <String>[];

  @override
  Future<File?> cached(String url, {String? key}) async {
    cachedKeys.add(key ?? url);
    final Future<File?> Function(String)? h = onCached;
    return h == null ? null : h(key ?? url);
  }

  @override
  Future<File> download(String url, {String? key}) {
    downloadKeys.add(key ?? url);
    downloadUrls.add(url);
    final Future<File> Function(String, String)? h = onDownload;
    if (h == null) return Future<File>.error(const SocketException('offline'));
    return h(key ?? url, url);
  }

  @override
  Future<void> evict(String key) async {}
}

/// Models flutter_cache_manager's HttpExceptionWithStatus without importing it.
class _HttpStatusError implements Exception {
  const _HttpStatusError(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'HttpException: Invalid statusCode: $statusCode';
}

void main() {
  const String owner = 'athlete1';
  const String path = 'users/$owner/posts/clip1/original.mp4';
  const String url = 'https://firebasestorage.invalid/o/clip1.mp4'
      '?alt=media&token=original';

  final String key = profileMediaCacheKey(
    ownerUid: owner,
    variant: MediaVariant.original,
    storagePath: path,
  );

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gl_fill_refresh');
    VideoSourceResolver.resetFillTracking();
  });

  tearDown(() async {
    VideoSourceResolver.resetFillTracking();
    resetProfileUrlRefresher();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  File clip({String name = 'clip.mp4', int bytes = 4096}) {
    final File f = File('${tmp.path}/$name')..createSync(recursive: true);
    f.writeAsBytesSync(List<int>.filled(bytes, 3));
    return f;
  }

  group('the background fill transfers a clip at most once', () {
    test('a second call while one is in flight JOINS it, and does not download',
        () async {
      final Completer<File> gate = Completer<File>();
      int downloads = 0;
      final _Store store = _Store(
        onCached: (_) async => null,
        onDownload: (_, __) {
          downloads++;
          return gate.future;
        },
      );
      final VideoSourceResolver r =
          VideoSourceResolver(store: store, onFilled: () {});

      final Future<bool> first = r.fill(url: url, cacheKey: key);
      final Future<bool> second = r.fill(url: url, cacheKey: key);
      expect(VideoSourceResolver.isFilling(key), isTrue);

      gate.complete(clip());
      final List<bool> both = await Future.wait(<Future<bool>>[first, second]);

      expect(downloads, 1, reason: 'one clip, one transfer');
      expect(both, <bool>[true, true], reason: 'the second joined the first');
    });

    test('reopening after a completed fill never downloads again', () async {
      int downloads = 0;
      final _Store store = _Store(
        onCached: (_) async => null,
        onDownload: (_, __) async {
          downloads++;
          return clip();
        },
      );
      final VideoSourceResolver r =
          VideoSourceResolver(store: store, onFilled: () {});

      expect(await r.fill(url: url, cacheKey: key), isTrue);
      for (int i = 0; i < 5; i++) {
        expect(await r.fill(url: url, cacheKey: key), isFalse);
      }
      expect(downloads, 1);
    });

    test('a fresh process asks the STORE before fetching anything', () async {
      // No memory of earlier fills, but the bytes are already on disk.
      int downloads = 0;
      final File onDisk = clip();
      final _Store store = _Store(
        onCached: (_) async => onDisk,
        onDownload: (_, __) async {
          downloads++;
          return onDisk;
        },
      );
      VideoSourceResolver.resetFillTracking();

      final bool filled =
          await VideoSourceResolver(store: store, onFilled: () {})
              .fill(url: url, cacheKey: key);

      expect(filled, isFalse);
      expect(downloads, 0, reason: 'already cached: nothing to transfer');
      expect(store.cachedKeys, <String>[key]);
    });

    test('a zero-length cached file is not mistaken for a completed fill',
        () async {
      int downloads = 0;
      final File empty = File('${tmp.path}/empty.mp4')..createSync();
      final _Store store = _Store(
        onCached: (_) async => empty,
        onDownload: (_, __) async {
          downloads++;
          return clip();
        },
      );

      expect(
        await VideoSourceResolver(store: store, onFilled: () {})
            .fill(url: url, cacheKey: key),
        isTrue,
      );
      expect(downloads, 1);
    });

    test('a failed fill is silent, and the clip stays fetchable', () async {
      int downloads = 0;
      final _Store store = _Store(
        onCached: (_) async => null,
        onDownload: (_, __) async {
          downloads++;
          if (downloads == 1) throw const SocketException('dropped');
          return clip();
        },
      );
      final VideoSourceResolver r =
          VideoSourceResolver(store: store, onFilled: () {});

      expect(await r.fill(url: url, cacheKey: key), isFalse);
      expect(await r.fill(url: url, cacheKey: key), isTrue);
      expect(downloads, 2);
    });

    test('two different clips fill independently', () async {
      final _Store store = _Store(
        onCached: (_) async => null,
        onDownload: (_, __) async => clip(),
      );
      final VideoSourceResolver r =
          VideoSourceResolver(store: store, onFilled: () {});

      expect(await r.fill(url: url, cacheKey: key), isTrue);
      expect(await r.fill(url: 'https://x/b.mp4', cacheKey: 'other'), isTrue);
      expect(store.downloadKeys, <String>[key, 'other']);
    });

    test('the disk ceiling is checked after a fill, never before', () async {
      final List<String> events = <String>[];
      final _Store store = _Store(
        onCached: (_) async => null,
        onDownload: (_, __) async {
          events.add('download');
          return clip();
        },
      );

      await VideoSourceResolver(
        store: store,
        onFilled: () => events.add('sweep'),
      ).fill(url: url, cacheKey: key);

      expect(events, <String>['download', 'sweep']);
    });
  });

  group('staged uploader media never triggers a remote transfer', () {
    test('a pending upload resolves to its staged file with no fill offered',
        () async {
      final File staged = clip(name: 'staged.mp4');
      final _Store store = _Store(
        onCached: (_) async => throw StateError('must not be asked'),
      );

      final VideoSource s = await VideoSourceResolver(store: store)
          .resolve(url: url, cacheKey: key, localFilePath: staged.path);

      expect(s.file?.path, staged.path);
      expect(s.fillFromUrl, isNull,
          reason: 'nothing to fetch: the bytes are already local');
      expect(store.downloadKeys, isEmpty);
    });

    test('a cached clip resolves to a file with no fill offered', () async {
      final File onDisk = clip();
      final _Store store = _Store(onCached: (_) async => onDisk);

      final VideoSource s = await VideoSourceResolver(store: store)
          .resolve(url: url, cacheKey: key);

      expect(s.file?.path, onDisk.path);
      expect(s.fillFromUrl, isNull);
      expect(store.downloadKeys, isEmpty);
    });

    test('only a streamed source offers a fill', () async {
      final _Store store = _Store(onCached: (_) async => null);
      final VideoSource s = await VideoSourceResolver(store: store)
          .resolve(url: url, cacheKey: key);

      expect(s.url, url);
      expect(s.fillFromUrl, url);
    });
  });

  group('classifying a dead URL', () {
    test('401 and 403 are authorization failures', () {
      expect(isAuthorizationFailure(const _HttpStatusError(401)), isTrue);
      expect(isAuthorizationFailure(const _HttpStatusError(403)), isTrue);
    });

    test('404 is not — the object is genuinely gone', () {
      expect(isAuthorizationFailure(const _HttpStatusError(404)), isFalse);
      expect(
        isAuthorizationFailure(
            FirebaseException(plugin: 'storage', code: 'object-not-found')),
        isFalse,
      );
    });

    test('a Storage unauthorized error is', () {
      expect(
        isAuthorizationFailure(
            FirebaseException(plugin: 'storage', code: 'unauthorized')),
        isTrue,
      );
    });

    test('a dropped connection is not', () {
      expect(
          isAuthorizationFailure(const SocketException('Failed host lookup')),
          isFalse);
    });
  });

  group('a refreshed URL keeps the same cache identity', () {
    test('a genuinely different URL is offered', () async {
      final StorageUrlRefresher r = StorageUrlRefresher(
        lookup: (String p) async => '$url-rotated',
      );
      expect(await r.replacementFor(path, url), '$url-rotated');
    });

    test('an IDENTICAL URL is refused, so nothing retries pointlessly',
        () async {
      final StorageUrlRefresher r =
          StorageUrlRefresher(lookup: (String p) async => url);
      expect(await r.replacementFor(path, url), isNull);
    });

    test('a lookup that fails is null rather than an exception', () async {
      final StorageUrlRefresher r = StorageUrlRefresher(
        lookup: (String p) async => throw const SocketException('offline'),
      );
      expect(await r.freshUrl(path), isNull);
      expect(await r.replacementFor(path, url), isNull);
    });

    test('an empty storage path is never looked up', () async {
      int calls = 0;
      final StorageUrlRefresher r =
          StorageUrlRefresher(lookup: (String p) async {
        calls++;
        return 'x';
      });
      expect(await r.freshUrl('  '), isNull);
      expect(calls, 0);
    });

    test('the video resolver offers one replacement, and only a real one',
        () async {
      final VideoSourceResolver r = VideoSourceResolver(store: _Store());

      expect(
        await r.refreshedSource(
          storagePath: path,
          failedUrl: url,
          refresher: StorageUrlRefresher(lookup: (_) async => '$url-new'),
        ),
        '$url-new',
      );
      expect(
        await r.refreshedSource(
          storagePath: '',
          failedUrl: url,
          refresher: StorageUrlRefresher(lookup: (_) async => '$url-new'),
        ),
        isNull,
        reason: 'no storagePath means nothing to look the object up by',
      );
      expect(
        await r.refreshedSource(
          storagePath: path,
          failedUrl: url,
          refresher: StorageUrlRefresher(lookup: (_) async => url),
        ),
        isNull,
        reason: 'the same URL would fail the same way',
      );
    });

    test('the cache key is unaffected by which URL succeeded', () {
      final String withOriginal = profileMediaCacheKey(
        ownerUid: owner,
        variant: MediaVariant.original,
        storagePath: path,
        url: url,
      );
      final String withRefreshed = profileMediaCacheKey(
        ownerUid: owner,
        variant: MediaVariant.original,
        storagePath: path,
        url: '$url-completely-different-token',
      );
      expect(withRefreshed, withOriginal);
    });
  });
}
