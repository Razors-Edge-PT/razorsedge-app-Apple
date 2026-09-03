/// No load may end in a permanent spinner.
///
/// PostDetailPage's image branch used to render `Image.file` only when the
/// future completed with data, and a `CircularProgressIndicator` for every
/// other state. A download error, a missing Storage object, an empty
/// `smallUrl`, a 404 or an offline cache miss all fell into that same branch,
/// so the page span for as long as it stayed open and there was nothing for the
/// user to do about it. Nothing bounded the wait either: neither
/// `getSingleFile` nor `VideoPlayerController.initialize` has a timeout of its
/// own, so a stalled connection meant a spinner for ever.
///
/// Every case below asserts the same contract: bytes, a bounded wait, or a
/// stated failure with a retry that starts a genuinely fresh attempt.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/data/media_url_refresh.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';
import 'package:localtest222/profile/ui/media_detail_page.dart';
import 'package:localtest222/profile/ui/media_grid.dart';

/// A store whose every operation is controlled by the test.
class _ScriptedStore implements ProfileImageStore {
  _ScriptedStore({this.onCached, this.onDownload});

  Future<File?> Function(String key)? onCached;
  Future<File> Function(String key)? onDownload;

  final List<String> cachedKeys = <String>[];
  final List<String> downloadKeys = <String>[];
  final List<String> evicted = <String>[];

  @override
  Future<File?> cached(String url, {String? key}) async {
    cachedKeys.add(key ?? url);
    final Future<File?> Function(String)? handler = onCached;
    return handler == null ? null : handler(key ?? url);
  }

  final List<String> downloadUrls = <String>[];

  @override
  Future<File> download(String url, {String? key}) {
    downloadKeys.add(key ?? url);
    downloadUrls.add(url);
    final Future<File> Function(String)? handler = onDownload;
    if (handler == null) throw StateError('no download scripted');
    return handler(key ?? url);
  }

  @override
  Future<void> evict(String key) async => evicted.add(key);
}

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  const String url = 'https://example.invalid/photo.jpg';

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gl_media_states');
  });

  tearDown(() async {
    resetProfileImageCache();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  File writeJpeg(String name) {
    final File f = File('${tmp.path}/$name')..createSync(recursive: true);
    f.writeAsBytesSync(_onePixelJpeg);
    return f;
  }

  group('an image load always resolves', () {
    testWidgets('a download error reaches a retryable error state, not a spinner',
        (WidgetTester t) async {
      final _ScriptedStore store = _ScriptedStore(
        onDownload: (_) => Future<File>.error(
            const HttpException('404 object not found')),
      );

      await t.pumpWidget(_wrap(CachedProfileImage(
        url: url,
        store: store,
        placeholder: const CircularProgressIndicator(),
        errorBuilder: (BuildContext c, MediaLoadFailure f, VoidCallback retry) =>
            MediaFailureView(failure: f, isVideo: false, onRetry: retry),
      )));
      await t.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a missing Storage object cannot leave a spinner',
        (WidgetTester t) async {
      // The classic 404 shape: the cache has nothing and the fetch fails.
      final _ScriptedStore store = _ScriptedStore(
        onCached: (_) async => null,
        onDownload: (_) =>
            Future<File>.error(const FileSystemException('object-not-found')),
      );

      await t.pumpWidget(_wrap(CachedProfileImage(
        url: url,
        store: store,
        placeholder: const CircularProgressIndicator(),
        errorBuilder: (BuildContext c, MediaLoadFailure f, VoidCallback retry) =>
            MediaFailureView(failure: f, isVideo: false, onRetry: retry),
      )));
      await t.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('could not be loaded'), findsOneWidget);
    });

    testWidgets('a stalled resolution times out rather than spinning for ever',
        (WidgetTester t) async {
      // Neither operation ever completes: exactly a dead TCP connection.
      final Completer<File> never = Completer<File>();
      final _ScriptedStore store = _ScriptedStore(
        onCached: (_) => Completer<File?>().future,
        onDownload: (_) => never.future,
      );

      await t.pumpWidget(_wrap(CachedProfileImage(
        url: url,
        store: store,
        readTimeout: const Duration(milliseconds: 50),
        downloadTimeout: const Duration(milliseconds: 100),
        placeholder: const CircularProgressIndicator(),
        errorBuilder: (BuildContext c, MediaLoadFailure f, VoidCallback retry) =>
            MediaFailureView(failure: f, isVideo: false, onRetry: retry),
      )));

      // Still a BOUNDED wait at this point — the spinner is legitimate here.
      await t.pump(const Duration(milliseconds: 10));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await t.pump(const Duration(milliseconds: 200));
      await t.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('took too long'), findsOneWidget);
    });

    testWidgets('an empty URL is a stated failure, never a spinner',
        (WidgetTester t) async {
      await t.pumpWidget(_wrap(CachedProfileImage(
        url: '',
        store: _ScriptedStore(),
        placeholder: const CircularProgressIndicator(),
        errorBuilder: (BuildContext c, MediaLoadFailure f, VoidCallback retry) =>
            MediaFailureView(failure: f, isVideo: false, onRetry: retry),
      )));
      await t.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('cannot be displayed'), findsOneWidget);
    });

    testWidgets('a cached entry whose file has vanished falls through, and '
        'the failure is stated', (WidgetTester t) async {
      // The index still names a file the OS no longer has - a cleared cache
      // directory, a restore onto a new device. Trusting the index blindly is
      // how that became a permanently blank tile.
      final File ghost = File('${tmp.path}/gone.jpg');
      final _ScriptedStore store = _ScriptedStore(
        onCached: (_) async => ghost,
        onDownload: (_) =>
            Future<File>.error(const HttpException('404 object not found')),
      );

      await t.pumpWidget(_wrap(CachedProfileImage(
        url: url,
        store: store,
        placeholder: const CircularProgressIndicator(),
        errorBuilder: (BuildContext c, MediaLoadFailure f, VoidCallback retry) =>
            MediaFailureView(failure: f, isVideo: false, onRetry: retry),
      )));
      await t.pumpAndSettle();

      expect(store.downloadKeys, hasLength(1),
          reason: 'a missing file must not be served from the index');
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('could not be loaded'), findsOneWidget);
    });

    testWidgets('corrupt bytes decode to the failure view, not a blank tile',
        (WidgetTester t) async {
      // Decoding is asynchronous and does not settle deterministically under
      // the test binding, so this asserts the wiring: the Image the widget
      // builds carries an errorBuilder, and that builder produces the stated
      // failure rather than an empty box.
      final _ScriptedStore store =
          _ScriptedStore(onCached: (_) async => writeJpeg('bytes.jpg'));

      await t.pumpWidget(_wrap(CachedProfileImage(
        url: url,
        store: store,
        errorBuilder: (BuildContext c, MediaLoadFailure f, VoidCallback retry) =>
            MediaFailureView(failure: f, isVideo: false, onRetry: retry),
      )));
      await t.pumpAndSettle();

      final Image image = t.widget<Image>(find.byType(Image));
      expect(image.errorBuilder, isNotNull);

      final Widget onDecodeFailure = image.errorBuilder!(
        t.element(find.byType(Image)),
        Exception('Invalid image data'),
        StackTrace.empty,
      );
      expect(onDecodeFailure, isA<MediaFailureView>());
      expect((onDecodeFailure as MediaFailureView).failure,
          MediaLoadFailure.unavailable);
    });

    testWidgets('offline is reported as offline, not as a broken image',
        (WidgetTester t) async {
      final _ScriptedStore store = _ScriptedStore(
        onDownload: (_) =>
            Future<File>.error(const SocketException('Failed host lookup')),
      );

      await t.pumpWidget(_wrap(CachedProfileImage(
        url: url,
        store: store,
        errorBuilder: (BuildContext c, MediaLoadFailure f, VoidCallback retry) =>
            MediaFailureView(failure: f, isVideo: false, onRetry: retry),
      )));
      await t.pumpAndSettle();

      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
    });
  });

  group('retry starts a fresh attempt', () {
    testWidgets('a retry after a failure succeeds and shows the image',
        (WidgetTester t) async {
      int attempts = 0;
      final _ScriptedStore store = _ScriptedStore(
        onCached: (_) async => null,
        onDownload: (_) async {
          attempts++;
          if (attempts == 1) throw const SocketException('down');
          return writeJpeg('retried.jpg');
        },
      );

      await t.pumpWidget(_wrap(CachedProfileImage(
        url: url,
        store: store,
        errorBuilder: (BuildContext c, MediaLoadFailure f, VoidCallback retry) =>
            MediaFailureView(failure: f, isVideo: false, onRetry: retry),
      )));
      await t.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);

      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();

      expect(attempts, 2, reason: 'the failed future must not be re-awaited');
      expect(find.text('Try again'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('a load that completes after disposal touches no state',
        (WidgetTester t) async {
      final Completer<File> late = Completer<File>();
      final _ScriptedStore store = _ScriptedStore(
        onCached: (_) async => null,
        onDownload: (_) => late.future,
      );

      await t.pumpWidget(_wrap(CachedProfileImage(url: url, store: store)));
      await t.pump();

      // Tear the widget down with the fetch still in flight, then let it land.
      await t.pumpWidget(_wrap(const SizedBox.shrink()));
      late.complete(writeJpeg('late.jpg'));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
    });
  });

  group('the cache is asked for a stable key, not the URL', () {
    testWidgets('the caller chosen key is what reaches the store',
        (WidgetTester t) async {
      final _ScriptedStore store =
          _ScriptedStore(onCached: (_) async => writeJpeg('keyed.jpg'));

      await t.pumpWidget(_wrap(CachedProfileImage(
        url: '$url?alt=media&token=rotates-every-time',
        cacheKey: 'glmedia|athlete1|small|users/athlete1/posts/m1/original.jpg',
        store: store,
      )));
      await t.pumpAndSettle();

      expect(store.cachedKeys.single,
          'glmedia|athlete1|small|users/athlete1/posts/m1/original.jpg');
      expect(store.cachedKeys.single, isNot(contains('token')));
    });
  });


  group('a revoked access token is recovered from, once', () {
    // A Firebase download URL embeds an access token that can be REVOKED. The
    // object is still there and the user is still allowed to see it; the URL
    // stored in the post document just no longer opens it. Asking Storage for
    // a fresh one is the honest response - bounded to a single attempt, and
    // without disturbing the cache entry the bytes belong to.
    const String storagePath = 'users/athlete1/posts/m1/original.jpg';
    const String stableKey = 'glmedia|athlete1|small|$storagePath';

    testWidgets('a 403 is retried once with a fresh URL, under the SAME key',
        (WidgetTester t) async {
      final _ScriptedStore store = _ScriptedStore(
        onCached: (_) async => null,
        onDownload: (_) => throw const _HttpStatus(403),
      );
      // The second attempt succeeds; scripted after construction so the first
      // failure is unambiguous.
      int attempts = 0;
      store.onDownload = (_) async {
        attempts++;
        if (attempts == 1) throw const _HttpStatus(403);
        return writeJpeg('refreshed.jpg');
      };

      await t.pumpWidget(_wrap(CachedProfileImage(
        url: '$url?alt=media&token=revoked',
        cacheKey: stableKey,
        storagePath: storagePath,
        urlRefresher:
            StorageUrlRefresher(lookup: (_) async => '$url?alt=media&token=new'),
        store: store,
        errorBuilder: (BuildContext c, MediaLoadFailure f, VoidCallback retry) =>
            MediaFailureView(failure: f, isVideo: false, onRetry: retry),
      )));
      await t.pumpAndSettle();

      expect(attempts, 2, reason: 'exactly one retry');
      expect(store.downloadUrls.last, contains('token=new'));
      expect(store.downloadKeys, <String>[stableKey, stableKey],
          reason: 'a refreshed URL is the same media, so the same cache entry');
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('a 404 is NOT retried - the object is genuinely gone',
        (WidgetTester t) async {
      int lookups = 0;
      final _ScriptedStore store = _ScriptedStore(
        onCached: (_) async => null,
        onDownload: (_) => throw const _HttpStatus(404),
      );

      await t.pumpWidget(_wrap(CachedProfileImage(
        url: url,
        cacheKey: stableKey,
        storagePath: storagePath,
        urlRefresher: StorageUrlRefresher(lookup: (_) async {
          lookups++;
          return '$url?token=new';
        }),
        store: store,
        errorBuilder: (BuildContext c, MediaLoadFailure f, VoidCallback retry) =>
            MediaFailureView(failure: f, isVideo: false, onRetry: retry),
      )));
      await t.pumpAndSettle();

      expect(lookups, 0, reason: 'no Storage call is spent on a missing object');
      expect(store.downloadKeys, hasLength(1));
      expect(find.textContaining('could not be loaded'), findsOneWidget);
    });

    testWidgets('a refreshed URL that also fails reaches a clear error state',
        (WidgetTester t) async {
      int attempts = 0;
      final _ScriptedStore store = _ScriptedStore(onCached: (_) async => null);
      store.onDownload = (_) async {
        attempts++;
        throw const _HttpStatus(403);
      };

      await t.pumpWidget(_wrap(CachedProfileImage(
        url: url,
        cacheKey: stableKey,
        storagePath: storagePath,
        urlRefresher: StorageUrlRefresher(lookup: (_) async => '$url?token=new'),
        store: store,
        errorBuilder: (BuildContext c, MediaLoadFailure f, VoidCallback retry) =>
            MediaFailureView(failure: f, isVideo: false, onRetry: retry),
      )));
      await t.pumpAndSettle();

      expect(attempts, 2, reason: 'two attempts and no more: never a loop');
      expect(find.textContaining('could not be loaded'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('with no storagePath there is nothing to refresh from',
        (WidgetTester t) async {
      int attempts = 0;
      final _ScriptedStore store = _ScriptedStore(onCached: (_) async => null);
      store.onDownload = (_) async {
        attempts++;
        throw const _HttpStatus(403);
      };

      await t.pumpWidget(_wrap(CachedProfileImage(
        url: url,
        cacheKey: stableKey,
        store: store,
        errorBuilder: (BuildContext c, MediaLoadFailure f, VoidCallback retry) =>
            MediaFailureView(failure: f, isVideo: false, onRetry: retry),
      )));
      await t.pumpAndSettle();

      expect(attempts, 1);
      expect(find.textContaining('could not be loaded'), findsOneWidget);
    });

    testWidgets('a cached copy is served without any refresh at all',
        (WidgetTester t) async {
      int lookups = 0;
      final _ScriptedStore store =
          _ScriptedStore(onCached: (_) async => writeJpeg('cached.jpg'));

      await t.pumpWidget(_wrap(CachedProfileImage(
        url: '$url?alt=media&token=long-since-revoked',
        cacheKey: stableKey,
        storagePath: storagePath,
        urlRefresher: StorageUrlRefresher(lookup: (_) async {
          lookups++;
          return 'x';
        }),
        store: store,
      )));
      await t.pumpAndSettle();

      expect(store.downloadKeys, isEmpty);
      expect(lookups, 0,
          reason: 'token rotation is irrelevant to bytes already on disk');
      expect(find.byType(Image), findsOneWidget);
    });
  });

  group('the gallery grid', () {
    ProfileMediaItem item({
      required String id,
      String mediaType = MediaType.image,
    }) =>
        ProfileMediaItem(
          id: id,
          ownerUid: 'athlete1',
          mediaType: mediaType,
          kind: PostKind.upload,
          storagePath: 'users/athlete1/posts/$id/original.jpg',
          thumbUrl: 'https://example.invalid/$id.jpg',
          smallUrl: 'https://example.invalid/$id.jpg',
          createdAt: DateTime(2026, 1, 1),
        );

    Widget grid({
      List<ProfileMediaItem> items = const <ProfileMediaItem>[],
      bool failed = false,
      VoidCallback? onRetryGallery,
    }) =>
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: <Widget>[
                MediaGrid(
                  items: items,
                  isOwner: true,
                  onOpen: (_) {},
                  onRetry: (_) {},
                  onDelete: (_) {},
                  failed: failed,
                  onRetryGallery: onRetryGallery,
                ),
              ],
            ),
          ),
        );

    testWidgets('an empty gallery and a FAILED gallery read differently',
        (WidgetTester t) async {
      await t.pumpWidget(grid());
      await t.pump();
      expect(find.textContaining('Add a photo'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);

      await t.pumpWidget(grid(failed: true, onRetryGallery: () {}));
      await t.pump();
      expect(find.textContaining('could not be loaded'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('an unsupported media type never reaches the image decoder',
        (WidgetTester t) async {
      profileImageStore = _ScriptedStore(
        onCached: (_) async => throw StateError('must not be asked'),
      );

      await t.pumpWidget(grid(items: <ProfileMediaItem>[
        item(id: 'weird', mediaType: 'audio'),
      ]));
      await t.pump();

      expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
      expect(find.byType(CachedProfileImage), findsNothing);
    });

    testWidgets('one malformed tile does not stop its neighbours rendering',
        (WidgetTester t) async {
      profileImageStore =
          _ScriptedStore(onCached: (_) async => writeJpeg('tile.jpg'));

      await t.pumpWidget(grid(items: <ProfileMediaItem>[
        item(id: 'ok1'),
        item(id: 'broken', mediaType: ''),
        item(id: 'ok2'),
      ]));
      await t.pumpAndSettle();

      expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
      expect(find.byType(CachedProfileImage), findsNWidgets(2));
    });

    testWidgets('no video autoplays in the grid', (WidgetTester t) async {
      profileImageStore =
          _ScriptedStore(onCached: (_) async => writeJpeg('poster.jpg'));

      await t.pumpWidget(grid(items: <ProfileMediaItem>[
        item(id: 'clip', mediaType: MediaType.video),
      ]));
      await t.pumpAndSettle();

      // A tile is a still poster plus a play affordance, and nothing else.
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byType(MediaDetailPage), findsNothing);
    });
  });
}

/// The smallest valid JPEG the Flutter decoder accepts: 1x1, black.
final Uint8List _onePixelJpeg = Uint8List.fromList(<int>[
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, //
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
  0x00, 0x03, 0x02, 0x02, 0x02, 0x02, 0x02, 0x03, 0x02, 0x02, 0x02, 0x03,
  0x03, 0x03, 0x03, 0x04, 0x06, 0x04, 0x04, 0x04, 0x04, 0x04, 0x08, 0x06,
  0x06, 0x05, 0x06, 0x09, 0x08, 0x0A, 0x0A, 0x09, 0x08, 0x09, 0x09, 0x0A,
  0x0C, 0x0F, 0x0C, 0x0A, 0x0B, 0x0E, 0x0B, 0x09, 0x09, 0x0D, 0x11, 0x0D,
  0x0E, 0x0F, 0x10, 0x10, 0x11, 0x10, 0x0A, 0x0C, 0x12, 0x13, 0x12, 0x10,
  0x13, 0x0F, 0x10, 0x10, 0x10, 0xFF, 0xC9, 0x00, 0x0B, 0x08, 0x00, 0x01,
  0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xCC, 0x00, 0x06, 0x00, 0x10,
  0x10, 0x05, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
  0xD2, 0xCF, 0x20, 0xFF, 0xD9,
]);

/// Models flutter_cache_manager's HttpExceptionWithStatus without importing it.
class _HttpStatus implements Exception {
  const _HttpStatus(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'HttpException: Invalid statusCode: $statusCode';
}
