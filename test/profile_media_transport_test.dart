/// A media transfer must be able to fail.
///
/// `flutter_cache_manager` runs ten fetches at once, queues the rest, and keeps
/// one in-flight entry per cache key so a second request for the same media
/// joins the first instead of downloading it twice. All three behaviours assume
/// a fetch eventually finishes, and nothing underneath guarantees that:
/// `dart:io` has no read timeout, so a transfer that starts and then stops
/// arriving leaves a future that never completes. The slot is never released
/// and the in-flight entry is never cleared, so every later retry for that
/// media joins a transfer that is already dead.
///
/// The control case below reproduces exactly that. The guarded case is the
/// contract: a stalled transfer fails, and the retry after it does real work.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// flutter_cache_manager's FileSystem hands back package:file's File, so a test
// that supplies a directory has to name that type.
// ignore_for_file: depend_on_referenced_packages
import 'package:file/file.dart' as pkg;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';

const String kUrl = 'https://example.invalid/o/photo.jpg';
const String kKey = 'glmedia|u1|small|users/u1/posts/m1/original.jpg';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('media_transport'));
  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold a handle; the OS reclaims it.
    }
  });

  ProfileImageStore storeOver(FileService service, String name) =>
      CacheManagerImageStore(CacheManager(Config(
        name,
        repo: JsonCacheInfoRepository.withFile(File('${tmp.path}/$name.json')),
        fileSystem: _Files(Directory('${tmp.path}/$name')..createSync()),
        fileService: service,
      )));

  test('UNGUARDED: a stalled transfer wedges every later attempt at that media',
      () async {
    // The reported shape: Retry stops working until the app is restarted.
    final _Scripted net = _Scripted()..stallAfterFirstChunk = true;
    final ProfileImageStore store = storeOver(net, 'unguarded');

    await expectLater(
      store.download(kUrl, key: kKey).timeout(const Duration(seconds: 1)),
      throwsA(isA<TimeoutException>()),
    );

    // The connection is healthy again — but the dead transfer is still the one
    // in flight for this key, so the retry joins it and waits for ever.
    net.stallAfterFirstChunk = false;
    await expectLater(
      store.download(kUrl, key: kKey).timeout(const Duration(seconds: 1)),
      throwsA(isA<TimeoutException>()),
    );
    expect(net.gets, 1, reason: 'the retry never reached the network at all');
  });

  test('a stalled transfer fails, and the next attempt does real work',
      () async {
    final _Scripted net = _Scripted()..stallAfterFirstChunk = true;
    final ProfileImageStore store = storeOver(
      StallGuardedFileService(
        inner: net,
        responseTimeout: const Duration(milliseconds: 400),
        stallTimeout: const Duration(milliseconds: 200),
      ),
      'guarded',
    );

    await expectLater(store.download(kUrl, key: kKey), throwsA(anything));

    net.stallAfterFirstChunk = false;
    final File file =
        await store.download(kUrl, key: kKey).timeout(const Duration(seconds: 5));

    expect(file.lengthSync(), greaterThan(0));
    expect(net.gets, 2, reason: 'the retry opened a genuinely new transfer');
  });

  test('a response that never starts fails inside its bound', () async {
    final _Scripted net = _Scripted()..neverRespond = true;
    final ProfileImageStore store = storeOver(
      StallGuardedFileService(
        inner: net,
        responseTimeout: const Duration(milliseconds: 200),
        stallTimeout: const Duration(milliseconds: 200),
      ),
      'silent',
    );

    final Stopwatch sw = Stopwatch()..start();
    await expectLater(store.download(kUrl, key: kKey), throwsA(anything));
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('a slow transfer that keeps arriving is never cut off', () async {
    // Chunk every 40ms under a 300ms stall bound: slow, but alive.
    final _Scripted net = _Scripted()
      ..chunks = 6
      ..gap = const Duration(milliseconds: 40);
    final ProfileImageStore store = storeOver(
      StallGuardedFileService(
        inner: net,
        responseTimeout: const Duration(seconds: 2),
        stallTimeout: const Duration(milliseconds: 300),
      ),
      'slow',
    );

    final File file =
        await store.download(kUrl, key: kKey).timeout(const Duration(seconds: 5));
    expect(file.lengthSync(), _onePixelJpeg.length);
  });

  test('the app-wide store fetches through the guard', () {
    expect(ProfileMediaCache.createFileService(), isA<StallGuardedFileService>());
  });
}

/// A [FileService] whose response the test drives byte by byte.
class _Scripted extends FileService {
  int gets = 0;
  bool stallAfterFirstChunk = false;
  bool neverRespond = false;
  int chunks = 1;
  Duration gap = Duration.zero;

  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    if (neverRespond) return Completer<FileServiceResponse>().future;
    gets++;
    return _Response(
      stalls: stallAfterFirstChunk,
      chunks: chunks,
      gap: gap,
    );
  }
}

class _Response implements FileServiceResponse {
  _Response({required this.stalls, required this.chunks, required this.gap});

  final bool stalls;
  final int chunks;
  final Duration gap;

  @override
  Stream<List<int>> get content {
    if (stalls) {
      // One chunk, then silence for ever: a transfer that began and stopped.
      // A controller rather than a generator, so that cancelling it behaves
      // like cancelling a socket rather than like a parked function.
      final StreamController<List<int>> stalled =
          StreamController<List<int>>();
      stalled.add(_onePixelJpeg.sublist(0, 4));
      return stalled.stream;
    }
    return _chunked();
  }

  Stream<List<int>> _chunked() async* {
    final int size = (_onePixelJpeg.length / chunks).ceil();
    for (int i = 0; i < _onePixelJpeg.length; i += size) {
      if (gap > Duration.zero) await Future<void>.delayed(gap);
      yield _onePixelJpeg.sublist(
          i, i + size > _onePixelJpeg.length ? _onePixelJpeg.length : i + size);
    }
  }

  @override
  int? get contentLength => stalls ? null : _onePixelJpeg.length;

  @override
  String? get eTag => null;

  @override
  String get fileExtension => '.jpg';

  @override
  int get statusCode => 200;

  @override
  DateTime get validTill => DateTime.now().add(const Duration(days: 7));
}

/// The cache's files, in a directory this test owns.
class _Files implements FileSystem {
  _Files(this.dir);

  final Directory dir;

  @override
  Future<pkg.File> createFile(String name) async =>
      const LocalFileSystem().directory(dir.path).childFile(name);
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
