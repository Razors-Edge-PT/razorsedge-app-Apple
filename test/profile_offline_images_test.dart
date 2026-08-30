import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';

/// Avatars, grid thumbnails, story frames and previously viewed photos have to
/// survive a process restart with no connection.
///
/// `Image.network` cannot do that. It caches decoded frames in Flutter's
/// in-memory `ImageCache` and hands the bytes to the platform HTTP stack, and
/// both die with the process — so killing the app and reopening it in
/// aeroplane mode used to give a grid of broken-image icons.
///
/// [CachedProfileImage] writes the bytes to a real file through
/// `flutter_cache_manager` and reads them back from that file. These tests
/// model a RESTART the only way that means anything: build a completely new
/// cache manager and a completely new widget tree over the SAME store, with
/// the network guaranteed to fail, and assert the image still renders.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingCacheStore store;

  setUp(() {
    store = _RecordingCacheStore();
  });

  tearDown(() {
    store.dispose();
    resetProfileImageCache();
  });

  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  /// Lets the REAL file I/O behind the store actually run.
  ///
  /// pumpAndSettle alone drives the fake clock and the microtask queue; it does
  /// not wait for a genuine disk read or write. runAsync does, which is what
  /// makes "is it on disk?" a real question in this test rather than a
  /// simulated one.
  Future<void> settle(WidgetTester t) async {
    // A few rounds: the store's read and its write are separate real I/O
    // steps, and each one that completes schedules another rebuild.
    for (int i = 0; i < 4; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pumpAndSettle();
    }
  }

  const String url = 'https://example.invalid/users/u1/posts/p1/thumb.jpg';

  group('a viewed image survives a process restart while offline', () {
    testWidgets('the first view downloads and PERSISTS it',
        (WidgetTester t) async {
      final _FakeStore online = _FakeStore(store, online: true);
      await t.pumpWidget(wrap(CachedProfileImage(
        url: url,
        store: online,
        placeholder: const Text('loading'),
        fallback: const Text('missing'),
      )));
      await settle(t);

      expect(find.byType(Image), findsOneWidget);
      expect(online.downloads, 1);
      expect(store.contains(url), isTrue,
          reason: 'the bytes are on disk, not only in the process');
    });

    testWidgets('a NEW manager over the same store renders it with no network',
        (WidgetTester t) async {
      // Warm the store.
      final _FakeStore online = _FakeStore(store, online: true);
      await t.pumpWidget(wrap(CachedProfileImage(url: url, store: online)));
      await settle(t);

      // The restart: a brand-new widget tree and a brand-new cache manager
      // over the same on-disk store, with every download guaranteed to fail.
      await t.pumpWidget(const SizedBox.shrink());
      await settle(t);

      final _FakeStore offline = _FakeStore(store, online: false);
      await t.pumpWidget(wrap(CachedProfileImage(
        url: url,
        store: offline,
        placeholder: const Text('loading'),
        fallback: const Text('missing'),
      )));
      await settle(t);

      expect(find.byType(Image), findsOneWidget,
          reason: 'the second launch reads the file, with no connection');
      expect(find.text('missing'), findsNothing);
      expect(offline.downloads, 0,
          reason: 'a disk hit must not go to the network at all');
    });

    testWidgets('an image never seen before shows the fallback offline',
        (WidgetTester t) async {
      final _FakeStore offline = _FakeStore(store, online: false);
      await t.pumpWidget(wrap(CachedProfileImage(
        url: 'https://example.invalid/never-seen.jpg',
        store: offline,
        placeholder: const Text('loading'),
        fallback: const Text('missing'),
      )));
      await settle(t);
      expect(find.text('missing'), findsOneWidget);
    });

    testWidgets('several images each persist independently',
        (WidgetTester t) async {
      const List<String> urls = <String>[
        'https://example.invalid/a.jpg',
        'https://example.invalid/b.jpg',
        'https://example.invalid/c.jpg',
      ];
      final _FakeStore online = _FakeStore(store, online: true);
      await t.pumpWidget(wrap(Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final String u in urls)
            SizedBox(
              width: 40,
              height: 40,
              child: CachedProfileImage(url: u, store: online),
            ),
        ],
      )));
      await settle(t);
      for (final String u in urls) {
        expect(store.contains(u), isTrue, reason: u);
      }

      await t.pumpWidget(const SizedBox.shrink());
      await settle(t);

      final _FakeStore offline = _FakeStore(store, online: false);
      await t.pumpWidget(wrap(Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final String u in urls)
            SizedBox(
              width: 40,
              height: 40,
              child: CachedProfileImage(
                url: u,
                store: offline,
                fallback: const Text('missing'),
              ),
            ),
        ],
      )));
      await settle(t);
      expect(find.byType(Image), findsNWidgets(3));
      expect(find.text('missing'), findsNothing);
    });
  });

  group('a video URL is never handed to the image decoder', () {
    testWidgets('an mp4 URL renders the fallback, not a broken image',
        (WidgetTester t) async {
      final _FakeStore online = _FakeStore(store, online: true);
      await t.pumpWidget(wrap(CachedProfileImage(
        url: 'https://example.invalid/users/u1/posts/p1/original.mp4',
        store: online,
        fallback: const Text('missing'),
      )));
      await settle(t);

      expect(find.text('missing'), findsOneWidget);
      expect(online.downloads, 0,
          reason: 'it is not even fetched — an mp4 cannot be a poster frame');
    });

    testWidgets('a null or empty URL renders the fallback',
        (WidgetTester t) async {
      final _FakeStore online = _FakeStore(store, online: true);
      for (final String? u in <String?>[null, '', '   ']) {
        await t.pumpWidget(wrap(CachedProfileImage(
          url: u,
          store: online,
          fallback: const Text('missing'),
        )));
        await settle(t);
        expect(find.text('missing'), findsOneWidget, reason: '$u');
      }
    });
  });
}

/// A real on-disk store, standing in for the app's cache directory. It
/// deliberately OUTLIVES the cache manager, which is what makes the restart in
/// these tests a real one.
class _RecordingCacheStore {
  _RecordingCacheStore()
      : dir = Directory.systemTemp.createTempSync('profile_image_cache');

  final Directory dir;

  File fileFor(String url) =>
      File('${dir.path}/${url.hashCode.toUnsigned(32)}.jpg');

  bool contains(String url) => fileFor(url).existsSync();

  void dispose() {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle open while a decoded Image still references the
      // file. The temp directory is the OS's to reclaim; failing the test over
      // it would be noise.
    }
  }
}

/// A [ProfileImageStore] backed by [_RecordingCacheStore].
///
/// `online: false` models a device with no connection: every download throws,
/// so anything that renders must have come off the disk.
class _FakeStore implements ProfileImageStore {
  _FakeStore(this._store, {required this.online});

  final _RecordingCacheStore _store;
  final bool online;

  int downloads = 0;

  @override
  Future<File?> cached(String url) async {
    final File f = _store.fileFor(url);
    return f.existsSync() ? f : null;
  }

  @override
  Future<File> download(String url) async {
    if (!online) throw const SocketException('No connection');
    downloads++;
    final File f = _store.fileFor(url);
    await f.writeAsBytes(_onePixelJpeg);
    return f;
  }
}

/// The smallest valid JPEG the Flutter decoder will accept: 1×1, black.
final Uint8List _onePixelJpeg = Uint8List.fromList(<int>[
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  0x00,
  0x10,
  0x4A,
  0x46,
  0x49,
  0x46,
  0x00,
  0x01,
  0x01,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x00,
  0x00,
  0xFF,
  0xDB,
  0x00,
  0x43,
  0x00,
  0x08,
  0x06,
  0x06,
  0x07,
  0x06,
  0x05,
  0x08,
  0x07,
  0x07,
  0x07,
  0x09,
  0x09,
  0x08,
  0x0A,
  0x0C,
  0x14,
  0x0D,
  0x0C,
  0x0B,
  0x0B,
  0x0C,
  0x19,
  0x12,
  0x13,
  0x0F,
  0x14,
  0x1D,
  0x1A,
  0x1F,
  0x1E,
  0x1D,
  0x1A,
  0x1C,
  0x1C,
  0x20,
  0x24,
  0x2E,
  0x27,
  0x20,
  0x22,
  0x2C,
  0x23,
  0x1C,
  0x1C,
  0x28,
  0x37,
  0x29,
  0x2C,
  0x30,
  0x31,
  0x34,
  0x34,
  0x34,
  0x1F,
  0x27,
  0x39,
  0x3D,
  0x38,
  0x32,
  0x3C,
  0x2E,
  0x33,
  0x34,
  0x32,
  0xFF,
  0xC0,
  0x00,
  0x0B,
  0x08,
  0x00,
  0x01,
  0x00,
  0x01,
  0x01,
  0x01,
  0x11,
  0x00,
  0xFF,
  0xC4,
  0x00,
  0x1F,
  0x00,
  0x00,
  0x01,
  0x05,
  0x01,
  0x01,
  0x01,
  0x01,
  0x01,
  0x01,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
  0x02,
  0x03,
  0x04,
  0x05,
  0x06,
  0x07,
  0x08,
  0x09,
  0x0A,
  0x0B,
  0xFF,
  0xC4,
  0x00,
  0xB5,
  0x10,
  0x00,
  0x02,
  0x01,
  0x03,
  0x03,
  0x02,
  0x04,
  0x03,
  0x05,
  0x05,
  0x04,
  0x04,
  0x00,
  0x00,
  0x01,
  0x7D,
  0x01,
  0x02,
  0x03,
  0x00,
  0x04,
  0x11,
  0x05,
  0x12,
  0x21,
  0x31,
  0x41,
  0x06,
  0x13,
  0x51,
  0x61,
  0x07,
  0x22,
  0x71,
  0x14,
  0x32,
  0x81,
  0x91,
  0xA1,
  0x08,
  0x23,
  0x42,
  0xB1,
  0xC1,
  0x15,
  0x52,
  0xD1,
  0xF0,
  0x24,
  0x33,
  0x62,
  0x72,
  0x82,
  0x09,
  0x0A,
  0x16,
  0x17,
  0x18,
  0x19,
  0x1A,
  0x25,
  0x26,
  0x27,
  0x28,
  0x29,
  0x2A,
  0x34,
  0x35,
  0x36,
  0x37,
  0x38,
  0x39,
  0x3A,
  0x43,
  0x44,
  0x45,
  0x46,
  0x47,
  0x48,
  0x49,
  0x4A,
  0x53,
  0x54,
  0x55,
  0x56,
  0x57,
  0x58,
  0x59,
  0x5A,
  0x63,
  0x64,
  0x65,
  0x66,
  0x67,
  0x68,
  0x69,
  0x6A,
  0x73,
  0x74,
  0x75,
  0x76,
  0x77,
  0x78,
  0x79,
  0x7A,
  0x83,
  0x84,
  0x85,
  0x86,
  0x87,
  0x88,
  0x89,
  0x8A,
  0x92,
  0x93,
  0x94,
  0x95,
  0x96,
  0x97,
  0x98,
  0x99,
  0x9A,
  0xA2,
  0xA3,
  0xA4,
  0xA5,
  0xA6,
  0xA7,
  0xA8,
  0xA9,
  0xAA,
  0xB2,
  0xB3,
  0xB4,
  0xB5,
  0xB6,
  0xB7,
  0xB8,
  0xB9,
  0xBA,
  0xC2,
  0xC3,
  0xC4,
  0xC5,
  0xC6,
  0xC7,
  0xC8,
  0xC9,
  0xCA,
  0xD2,
  0xD3,
  0xD4,
  0xD5,
  0xD6,
  0xD7,
  0xD8,
  0xD9,
  0xDA,
  0xE1,
  0xE2,
  0xE3,
  0xE4,
  0xE5,
  0xE6,
  0xE7,
  0xE8,
  0xE9,
  0xEA,
  0xF1,
  0xF2,
  0xF3,
  0xF4,
  0xF5,
  0xF6,
  0xF7,
  0xF8,
  0xF9,
  0xFA,
  0xFF,
  0xDA,
  0x00,
  0x08,
  0x01,
  0x01,
  0x00,
  0x00,
  0x3F,
  0x00,
  0xFB,
  0xFE,
  0x8F,
  0xFF,
  0xD9,
]);
