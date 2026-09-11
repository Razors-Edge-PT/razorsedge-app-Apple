/// A network image that survives a process restart while offline.
///
/// ── Why not Image.network ───────────────────────────────────────────────────
/// `Image.network` caches decoded frames in Flutter's in-memory `ImageCache`
/// and delegates the bytes to the platform HTTP stack. Both are process-scoped
/// in the way that matters here: kill the app and reopen it with no connection
/// and every avatar, grid tile, story frame and previously viewed photo is a
/// broken-image icon, because nothing wrote those bytes anywhere that outlives
/// the process.
///
/// `flutter_cache_manager` writes them to a real file in the application
/// documents directory and remembers them in its own SQLite index, so the
/// second launch reads them off disk with no network at all. The app already
/// depends on it — the home feed and the post detail page use it — so this
/// reuses the mechanism the rest of the app already trusts rather than adding
/// one.
///
/// ── The two-stage build ─────────────────────────────────────────────────────
/// The disk is asked FIRST (one index read, no network), so a warm image
/// appears without a placeholder flash. Only a miss falls through to a
/// download, which persists the bytes for next time — including next launch.
///
/// ── Identity, and why it is not the URL ─────────────────────────────────────
/// Entries are keyed by [profileMediaCacheKey], not by the download URL. A
/// Firebase URL carries a rotating `token` query parameter, so URL-keyed
/// entries are orphaned — and the bytes fetched again — every time that token
/// turns over. See media_identity.dart.
///
/// ── Bounds ──────────────────────────────────────────────────────────────────
/// Every read and every download is bounded (media_timeouts.dart), so a stalled
/// connection reaches an error state instead of spinning; and the store itself
/// is bounded by [ProfileMediaCache]'s explicit eviction policy.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/media_identity.dart';
import '../core/media_timeouts.dart';
import '../core/media_urls.dart';
import '../data/media_cache_sweeper.dart';
import '../data/media_url_refresh.dart';

/// The disk store profile media is persisted in, with an EXPLICIT eviction
/// policy rather than an inherited one.
///
/// `DefaultCacheManager` keeps 200 objects for 30 days. A training gallery is
/// bigger and longer-lived than that: three columns of thumbnails plus the
/// stills and clips the user has opened runs past 200 quickly, and evicting a
/// month-old thumbnail defeats the point of caching a permanent gallery.
///
/// The policy, stated once so it can be reasoned about:
///
///   * at most [ProfileMediaCacheSweeper.kDefaultCeilingBytes] on disk — the
///     bound that actually matters, and the only one of the three that is
///     stated in bytes;
///   * at most [kMaxCachedObjects] objects;
///   * an object untouched for [kStalePeriod] is dropped.
///
/// The byte ceiling is enforced by [ProfileMediaCacheSweeper], not by the
/// package. `flutter_cache_manager` bounds a store by age and object COUNT
/// only, and a count is not a bound when the objects are videos: 600 entries is
/// a few megabytes of thumbnails or tens of gigabytes of clips, and the
/// configuration cannot tell the difference.
///
/// A separate store from `DefaultCacheManager` on purpose: the feed and the
/// post detail page share that one, and profile media should not be able to
/// evict their entries or be evicted by them. It is also what makes a
/// directory-level sweep safe — nothing else writes into this folder.
class ProfileMediaCache {
  ProfileMediaCache._();

  static const String kCacheKey = 'goodliftProfileMedia';
  static const int kMaxCachedObjects = 600;
  static const Duration kStalePeriod = Duration(days: 90);

  static CacheManager? _instance;

  /// Resolved lazily: constructing a CacheManager touches path_provider, which
  /// has no implementation under the test binding.
  static CacheManager get instance => _instance ??= CacheManager(
        Config(
          kCacheKey,
          stalePeriod: kStalePeriod,
          maxNrOfCacheObjects: kMaxCachedObjects,
          fileService: createFileService(),
        ),
      );

  /// The HTTP layer this store fetches through.
  ///
  /// Named rather than inlined so a test can state which one production uses
  /// without constructing the manager, which would need path_provider.
  static FileService createFileService() => StallGuardedFileService();

  /// The store's directory, or null when it cannot be resolved.
  ///
  /// Never throws: under the test binding path_provider has no implementation,
  /// and a sweep that cannot find the directory simply does nothing.
  static Future<Directory?> resolveDirectory() async {
    try {
      final Directory base = await getTemporaryDirectory();
      final Directory dir = Directory(p.join(base.path, kCacheKey));
      return dir.existsSync() ? dir : null;
    } catch (_) {
      return null;
    }
  }

  static ProfileMediaCacheSweeper? _sweeper;

  /// The sweeper that keeps this store under its byte ceiling.
  static ProfileMediaCacheSweeper get sweeper => _sweeper ??=
      ProfileMediaCacheSweeper(volume: DirectoryCacheVolume(resolveDirectory));

  /// Replaces the sweeper. For tests.
  static set sweeper(ProfileMediaCacheSweeper value) => _sweeper = value;

  /// Starts a throttled sweep and returns immediately.
  ///
  /// Called AFTER media is already on screen, never before, and its result is
  /// never awaited by anything the user is waiting on. A cache that cannot be
  /// tidied is a disk-space problem; it is never a reason for a photo not to
  /// appear or a clip not to play.
  static void tidyInBackground() {
    unawaited(
      sweeper.maybeSweep().catchError((Object _) => null),
    );
  }
}

/// The operations the profile needs from a persistent media store.
///
/// A narrow interface rather than [BaseCacheManager] directly, for three
/// reasons. It says exactly what is required of the store — read from disk
/// without touching the network, download-and-persist, and forget one entry —
/// so "does an image survive a restart?" becomes a testable question instead of
/// an assumption. It keeps `package:file`'s `File` (which flutter_cache_manager
/// returns) out of every call site. And it makes the cache KEY an explicit
/// argument, so identity is something the caller decides rather than something
/// the URL happens to imply.
abstract class ProfileImageStore {
  /// The already-persisted file for [key] (defaulting to [url]), or null. MUST
  /// NOT hit the network: this is what has to work on a cold start with no
  /// connection.
  Future<File?> cached(String url, {String? key});

  /// Downloads [url] and persists it under [key]. Throws when it cannot.
  Future<File> download(String url, {String? key});

  /// Forgets one entry. Used when the bytes behind a key are known to have
  /// changed; never called merely because a refresh failed.
  Future<void> evict(String key);
}

/// The production store, backed by flutter_cache_manager.
class CacheManagerImageStore implements ProfileImageStore {
  CacheManagerImageStore([this._injected]);

  final BaseCacheManager? _injected;

  // Resolved LAZILY. Constructing the manager calls path_provider, which has no
  // implementation under the test binding — so building one eagerly would make
  // merely REFERENCING this class fail in a widget test, including from the
  // reset used in tearDown.
  BaseCacheManager? _resolved;

  BaseCacheManager get _manager =>
      _injected ?? (_resolved ??= ProfileMediaCache.instance);

  @override
  Future<File?> cached(String url, {String? key}) async {
    final String id = key ?? url;
    final FileInfo? hit = await _manager.getFileFromCache(id);
    // package:file's File implements dart:io's File, so this widens cleanly.
    final File? file = hit?.file;
    if (file != null && !isUsableCacheFile(file)) {
      // The record outlived its bytes — the disk sweep took them, or the OS
      // reclaimed the cache directory. Drop the record so it stops shadowing a
      // real fetch, then report the miss honestly.
      await _forget(id);
      return null;
    }
    return file;
  }

  @override
  Future<File> download(String url, {String? key}) {
    final String id = key ?? url;
    return fetchWithStaleRecovery(
      key: id,
      fetch: () => _manager.getSingleFile(url, key: id),
      forget: () => _forget(id),
    );
  }

  @override
  Future<void> evict(String key) => _manager.removeFile(key);

  /// Removes a cache record. Never throws: a record that cannot be forgotten
  /// costs one wasted fetch, which is strictly better than a failed load.
  Future<void> _forget(String key) async {
    try {
      await _manager.removeFile(key);
    } catch (_) {
      // Already gone, or the index is unavailable. Nothing to do.
    }
  }
}

/// True when [file] is bytes the app can actually use.
///
/// A record is not bytes. `CacheManager` hands back whatever its index says
/// without asking the filesystem, so "the cache has it" has to be checked
/// against the disk before it means anything.
bool isUsableCacheFile(File? file) {
  if (file == null) return false;
  try {
    return file.existsSync() && file.lengthSync() > 0;
  } catch (_) {
    // Unreadable is unusable.
    return false;
  }
}

/// Fetches through a cache that may hold a record whose bytes are gone.
///
/// `CacheManager.getSingleFile` returns the recorded file whenever the record
/// is still within its `validTill`, and it does NOT check that the file is
/// still on disk. After [ProfileMediaCacheSweeper] reclaims bytes the record
/// outlives them by up to the stale period, so without this a download hands
/// back a path to nothing: no re-fetch, and the failure surfaces later, inside
/// an image decoder, as though the media were corrupt.
///
/// So: fetch, and if what comes back is not usable, FORGET the record and fetch
/// once more — which now has no record to short-circuit on and must do real
/// work. Exactly one retry. If the second attempt is still unusable (the record
/// could not be forgotten, or the fetch produced an empty file) this throws,
/// so the caller reaches its own error state rather than being handed a path to
/// nothing.
///
/// Written against callbacks rather than [BaseCacheManager] so the rule is
/// testable on its own, with ordinary `dart:io` files.
Future<File> fetchWithStaleRecovery({
  required String key,
  required Future<File> Function() fetch,
  required Future<void> Function() forget,
}) async {
  final File first = await fetch();
  if (isUsableCacheFile(first)) return first;

  await forget();
  final File second = await fetch();
  if (isUsableCacheFile(second)) return second;

  throw FileSystemException('cached media is missing after refetch', key);
}

/// The store profile media is persisted in.
///
/// Injectable so a test can point it at a temporary directory and then prove a
/// *new* store over the *same* directory still serves the file — which is what
/// a process restart is.
ProfileImageStore profileImageStore = CacheManagerImageStore();

/// Resets [profileImageStore] and the shared loader state. For tests.
void resetProfileImageCache() {
  profileImageStore = CacheManagerImageStore();
  mediaLoader.reset();
}

/// Why a media load ended, when it did not end in bytes.
enum MediaLoadFailure {
  /// There was no usable URL to load — an empty field, or a URL that names a
  /// video container where an image was expected.
  unusableSource,

  /// The bytes are not on this device and could not be fetched.
  offline,

  /// The fetch reached the network and failed (404, permission, corrupt).
  unavailable,

  /// The fetch neither succeeded nor failed within its bound.
  timedOut,
}

/// True when [error] is the kind of failure that means "no connection" rather
/// than "this object is broken".
///
/// Distinguishing them is what lets the UI say *"You're offline"* instead of
/// *"This image is broken"* — the first is retryable by walking to a window,
/// the second is not retryable at all.
bool isConnectivityFailure(Object error) =>
    error is SocketException ||
    error is TimeoutException ||
    (error is HttpException &&
        error.message.toLowerCase().contains('connection')) ||
    error.toString().contains('Failed host lookup');

/// An HTTP layer that cannot hang.
///
/// `flutter_cache_manager` runs at most ten fetches at once and queues the
/// rest, and it keeps one entry per key while a fetch is in flight so that a
/// second request for the same media JOINS the first. Both of those are good,
/// and both assume every fetch eventually finishes.
///
/// Nothing underneath guarantees that. `dart:io` has no read timeout: a
/// transfer that starts and then stops arriving — a Wi-Fi handover, a radio
/// dropping to sleep, a NAT that forgot the flow — leaves a future that never
/// completes. The widget above gives up on schedule, but the transfer does
/// not: it keeps its fetch slot and its in-flight entry for the life of the
/// process. Ten of those and every later image, on every screen, queues behind
/// something that will never finish; one of those and every Retry for that
/// media joins the same dead transfer and fails again. "Retry stopped working
/// until I restarted the app" is exactly that shape.
///
/// So a response that never starts, and a transfer whose bytes stop arriving,
/// are both made to FAIL. Failing releases the slot and the entry, which is
/// what lets the recovery above — and the person's own Retry — actually run.
class StallGuardedFileService extends FileService {
  StallGuardedFileService({
    FileService? inner,
    this.responseTimeout = kMediaResponseTimeout,
    this.stallTimeout = kMediaStallTimeout,
  }) : _inner = inner ?? HttpFileService();

  final FileService _inner;

  /// Bounds connect, TLS and the response headers.
  final Duration responseTimeout;

  /// Bounds the gap BETWEEN chunks, not the transfer. A slow download that
  /// keeps arriving is never cut off.
  final Duration stallTimeout;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final FileServiceResponse response =
        await _inner.get(url, headers: headers).timeout(responseTimeout);
    return _StallGuardedResponse(response, stallTimeout);
  }
}

/// [FileServiceResponse] whose body must keep arriving.
class _StallGuardedResponse implements FileServiceResponse {
  _StallGuardedResponse(this._inner, this._stallTimeout);

  final FileServiceResponse _inner;
  final Duration _stallTimeout;

  @override
  Stream<List<int>> get content => _inner.content.timeout(
        _stallTimeout,
        onTimeout: (EventSink<List<int>> sink) {
          sink.addError(
            TimeoutException('media transfer stalled', _stallTimeout),
          );
          sink.close();
        },
      );

  @override
  int? get contentLength => _inner.contentLength;

  @override
  String? get eTag => _inner.eTag;

  @override
  String get fileExtension => _inner.fileExtension;

  @override
  int get statusCode => _inner.statusCode;

  @override
  DateTime get validTill => _inner.validTill;
}

/// Why one attempt at a piece of media failed — the question that decides
/// whether trying again could possibly help.
///
/// The distinction is not cosmetic. Storage answers **403 for a deleted object
/// just as it does for a revoked token**, so "this is gone" and "this string
/// has expired" are indistinguishable at the HTTP layer and only a canonical
/// lookup can separate them. Meanwhile a dropped connection arrives as a
/// `ClientException` — no status code, not a `SocketException` — and treating
/// that as "this image is broken" is what left a card permanently blank after
/// one hiccup.
enum MediaFailureKind {
  /// No route to the network. Trying again immediately would only fail again.
  offline,

  /// The object is gone. Stable, and never retried.
  missing,

  /// Storage refused the URL: a rotated or revoked token — or an object that
  /// has been deleted behind a URL that still looks valid.
  refused,

  /// The attempt ran out of time. The transfer may well still be running.
  timedOut,

  /// A dropped connection, a server error: worth exactly one more try.
  transient,
}

/// [error], classified for recovery.
MediaFailureKind classifyMediaFailure(Object error) {
  if (error is TimeoutException) return MediaFailureKind.timedOut;
  // package:http's own socket failure implements SocketException, so this
  // catches "no network" however it is wrapped.
  if (error is SocketException) return MediaFailureKind.offline;

  final int? status = _statusCodeOf(error);
  if (status != null) {
    if (status == 404 || status == 410) return MediaFailureKind.missing;
    if (status == 401 || status == 403) return MediaFailureKind.refused;
    return MediaFailureKind.transient;
  }

  final String text = _withoutLocation(error.toString()).toLowerCase();
  if (text.contains('object-not-found') ||
      text.contains('404') ||
      text.contains('not found')) {
    return MediaFailureKind.missing;
  }
  if (text.contains('401') ||
      text.contains('403') ||
      text.contains('unauthorized') ||
      text.contains('unauthenticated') ||
      text.contains('permission denied') ||
      text.contains('forbidden')) {
    return MediaFailureKind.refused;
  }
  if (text.contains('failed host lookup') ||
      text.contains('network is unreachable')) {
    return MediaFailureKind.offline;
  }
  return MediaFailureKind.transient;
}

/// The HTTP status an error carries, by duck typing rather than by importing
/// another package's internals.
int? _statusCodeOf(Object error) {
  try {
    final Object? status = (error as dynamic).statusCode as Object?;
    return status is int ? status : null;
  } catch (_) {
    return null;
  }
}

/// [text] with the URL or file path it ends in removed.
///
/// A download token is thirty-two random hex characters and a cache file is
/// named after a UUID, so roughly one error message in a hundred contains
/// "404" or "403" purely by accident. Classifying a live object as deleted
/// because of the digits in its own URL is not a failure mode worth keeping.
String _withoutLocation(String text) {
  int cut = text.length;
  for (final String marker in const <String>[', uri', ', path']) {
    final int at = text.indexOf(marker);
    if (at >= 0 && at < cut) cut = at;
  }
  return text.substring(0, cut);
}

/// The outcome of one media load: bytes, or the reason there are none.
class MediaLoadResult {
  const MediaLoadResult.loaded(File this.file) : failure = null;
  const MediaLoadResult.failed(MediaLoadFailure this.failure) : file = null;

  final File? file;
  final MediaLoadFailure? failure;
}

/// One media load per piece of media, wherever it is drawn.
///
/// ── Why this is not simply "await the store" ────────────────────────────────
/// The store answers "is it on disk?" and "fetch it"; everything that decides
/// whether a card ends up showing a picture or a Retry button lives BETWEEN
/// those two calls, and it used to live in the widget — one copy per card, with
/// no memory of any other card and none of its own past. That produced the
/// reported bug in three ways:
///
///   * every failure was final. One dropped connection, one attempt that ran
///     out of time while the app was still starting, and that card was blank
///     until the reader tapped Retry — which simply ran the identical code
///     again, and worked, which is why Retry "fixed" it.
///   * an attempt that timed out was ABANDONED, though the transfer it started
///     was still running and usually finished moments later. The bytes landed;
///     nothing was watching. Retry then joined that same transfer, which is why
///     Retry was slow.
///   * two cards showing one photo, or the same card mounted twice, meant two
///     downloads of the same bytes.
///
/// So a load is an operation keyed by cache identity, not a method on a widget:
/// concurrent askers join it, a widget that goes away does not cancel it, and
/// its result — including bytes that arrive after the widget gave up — is on
/// disk for whoever asks next.
///
/// ── The one recovery, and its bounds ────────────────────────────────────────
/// Disk, then the network, then AT MOST one more attempt chosen by why the
/// first failed: a refused URL is refreshed through the canonical Storage path
/// and fetched once more; a timeout keeps waiting on the transfer already
/// running rather than starting a second copy of it; a dropped connection is
/// re-tried once. Offline and "gone" recover from nothing and say so
/// immediately. There is no third attempt and no loop — anything past this is
/// the reader's Retry, which starts a genuinely fresh operation.
class MediaLoader {
  MediaLoader();

  /// How many resolved file paths are remembered, so that a tile scrolled back
  /// to draws in its first frame instead of blinking through a placeholder.
  /// Paths only — the bytes live on disk under the cache's own byte ceiling.
  static const int kRememberedPaths = 256;

  final Map<String, Future<MediaLoadResult>> _running =
      <String, Future<MediaLoadResult>>{};
  final LinkedHashMap<String, String> _onDisk = LinkedHashMap<String, String>();

  /// Identity is the cache key, per store — so a test's store can never join
  /// or serve another's operation.
  static String _slot(ProfileImageStore store, String key) =>
      '${identityHashCode(store)} $key';

  /// The file for [key] if this process has already resolved it and the bytes
  /// are still there. Synchronous on purpose: it is read during `initState`.
  File? knownFile(ProfileImageStore store, String key) {
    final String slot = _slot(store, key);
    final String? path = _onDisk.remove(slot);
    if (path == null) return null;
    final File file = File(path);
    if (!isUsableCacheFile(file)) return null;
    _onDisk[slot] = path; // re-inserted: most recently used
    return file;
  }

  /// True while an operation for this media is in flight. For tests.
  bool isRunning(ProfileImageStore store, String key) =>
      _running.containsKey(_slot(store, key));

  /// Forgets every in-flight operation and remembered path. For tests.
  void reset() {
    _running.clear();
    _onDisk.clear();
  }

  /// Bytes for [url] under [key], joining an operation already running for it.
  Future<MediaLoadResult> load({
    required ProfileImageStore store,
    required String url,
    required String key,
    String storagePath = '',
    StorageUrlRefresher? refresher,
    Duration readTimeout = kMediaCacheReadTimeout,
    Duration downloadTimeout = kMediaDownloadTimeout,
  }) {
    final String slot = _slot(store, key);
    final Future<MediaLoadResult>? joined = _running[slot];
    if (joined != null) return joined;

    final Future<MediaLoadResult> run = _run(
      store: store,
      url: url,
      key: key,
      storagePath: storagePath,
      refresher: refresher,
      readTimeout: readTimeout,
      downloadTimeout: downloadTimeout,
    ).then((MediaLoadResult result) {
      final File? file = result.file;
      if (file != null) _remember(slot, file);
      return result;
    });

    _running[slot] = run;
    // Registered BEFORE any caller awaits, so a failed operation is out of the
    // map by the time the card that was waiting on it offers Retry.
    unawaited(run.whenComplete(() {
      if (identical(_running[slot], run)) _running.remove(slot);
    }));
    return run;
  }

  Future<MediaLoadResult> _run({
    required ProfileImageStore store,
    required String url,
    required String key,
    required String storagePath,
    required StorageUrlRefresher? refresher,
    required Duration readTimeout,
    required Duration downloadTimeout,
  }) async {
    try {
      // 1. Disk. A previously seen image appears with no network at all, which
      //    is the whole point of the store.
      final File? cached = await _fromDisk(store, url, key, readTimeout);
      if (cached != null) return MediaLoadResult.loaded(cached);

      // 2. The ordinary network path.
      final Future<File> attempt = _fetch(store, url, key);
      Object error;
      try {
        return MediaLoadResult.loaded(await attempt.timeout(downloadTimeout));
      } catch (e) {
        error = e;
      }

      // 3. One bounded recovery, chosen by why step 2 failed.
      switch (classifyMediaFailure(error)) {
        case MediaFailureKind.offline:
          return const MediaLoadResult.failed(MediaLoadFailure.offline);

        case MediaFailureKind.missing:
          return const MediaLoadResult.failed(MediaLoadFailure.unavailable);

        case MediaFailureKind.timedOut:
          // Slow is not broken. The transfer is still running; a second copy
          // of it would only compete with it for the same connection.
          return await _settle(() => attempt.timeout(downloadTimeout));

        case MediaFailureKind.refused:
          final String? fresh = await _canonicalUrl(
            url: url,
            storagePath: storagePath,
            refresher: refresher,
          );
          // No canonical URL means the object is gone, unreadable, or there is
          // nothing to look it up by. Repeating the refused URL cannot help.
          if (fresh == null) {
            return const MediaLoadResult.failed(MediaLoadFailure.unavailable);
          }
          return await _settle(
              () => _fetch(store, fresh, key).timeout(downloadTimeout));

        case MediaFailureKind.transient:
          // Another card's operation may have filled the entry meanwhile.
          final File? landed = await _fromDisk(store, url, key, readTimeout);
          if (landed != null) return MediaLoadResult.loaded(landed);
          return await _settle(
              () => _fetch(store, url, key).timeout(downloadTimeout));
      }
    } catch (e) {
      return MediaLoadResult.failed(_stateFor(e));
    }
  }

  Future<MediaLoadResult> _settle(Future<File> Function() attempt) async {
    try {
      return MediaLoadResult.loaded(await attempt());
    } catch (e) {
      return MediaLoadResult.failed(_stateFor(e));
    }
  }

  static MediaLoadFailure _stateFor(Object error) {
    switch (classifyMediaFailure(error)) {
      case MediaFailureKind.offline:
        return MediaLoadFailure.offline;
      case MediaFailureKind.timedOut:
        return MediaLoadFailure.timedOut;
      case MediaFailureKind.missing:
      case MediaFailureKind.refused:
      case MediaFailureKind.transient:
        return MediaLoadFailure.unavailable;
    }
  }

  /// The already-persisted file, or null. A wedged or corrupt index is a miss,
  /// never a failure — and nothing is deleted on the way past.
  Future<File?> _fromDisk(
    ProfileImageStore store,
    String url,
    String key,
    Duration timeout,
  ) async {
    try {
      final File? hit = await store.cached(url, key: key).timeout(timeout);
      return isUsableCacheFile(hit) ? hit : null;
    } catch (_) {
      return null;
    }
  }

  Future<File> _fetch(ProfileImageStore store, String url, String key) async {
    final File file = await store.download(url, key: key);
    // New bytes just landed, so this is the moment to check the disk ceiling.
    // Started, never awaited: the image is already about to be shown.
    ProfileMediaCache.tidyInBackground();
    return file;
  }

  /// A fresh URL for the object [url] actually names, or null.
  ///
  /// The URL wins over the caller's [storagePath] when it carries one, so a
  /// refresh can never swap one rendition for another — and a legacy row with
  /// no recorded path still has a canonical object to ask about.
  Future<String?> _canonicalUrl({
    required String url,
    required String storagePath,
    required StorageUrlRefresher? refresher,
  }) async {
    final String path = storagePathFromDownloadUrl(url) ?? storagePath.trim();
    if (path.isEmpty) return null;
    try {
      return await (refresher ?? profileUrlRefresher)
          .replacementFor(path, url)
          .timeout(kMediaUrlRefreshTimeout);
    } catch (_) {
      return null;
    }
  }

  void _remember(String slot, File file) {
    _onDisk.remove(slot);
    _onDisk[slot] = file.path;
    while (_onDisk.length > kRememberedPaths) {
      _onDisk.remove(_onDisk.keys.first);
    }
  }
}

/// The loader every media surface shares. Replaceable for tests.
MediaLoader mediaLoader = MediaLoader();

/// An image loaded from [url], persisted to disk so it renders after a restart
/// with no connection.
///
/// [url] is passed through [safeThumbnailUrl], so a URL that actually names a
/// video container never reaches the image decoder; [fallback] is drawn
/// instead.
///
/// Every attempt is bounded, and every outcome is one of: bytes on screen, a
/// bounded placeholder, or an error state. [errorBuilder] receives a callback
/// that starts a genuinely FRESH attempt — the failed future is never awaited
/// again, which is the difference between a retry button that works and one
/// that re-delivers the same error.
class CachedProfileImage extends StatefulWidget {
  const CachedProfileImage({
    super.key,
    required this.url,
    this.cacheKey,
    this.storagePath = '',
    this.urlRefresher,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
    this.fallback,
    this.errorBuilder,
    this.store,
    this.readTimeout = kMediaCacheReadTimeout,
    this.downloadTimeout = kMediaDownloadTimeout,
  });

  final String? url;

  /// Stable identity for these bytes. Defaults to [url], which is correct for
  /// a caller that has nothing better, but every profile surface passes a
  /// [profileMediaCacheKey] so token rotation does not orphan the entry.
  final String? cacheKey;

  /// The Storage object behind [url], when the caller knows it.
  ///
  /// Only used for recovery: if the stored URL is refused because its access
  /// token was revoked, a fresh one is fetched for this path and the download
  /// is retried ONCE. The cache key does not change — the URL is transport, the
  /// key is identity. Leave empty and a dead URL is simply reported as such.
  final String storagePath;

  /// Overrides the URL refresher. For tests.
  final StorageUrlRefresher? urlRefresher;

  final BoxFit fit;
  final double? width;
  final double? height;

  /// Shown while the bytes are being fetched for the first time.
  final Widget? placeholder;

  /// Shown when there is no usable URL, or the fetch failed and nothing is on
  /// disk. Used when [errorBuilder] is null — the quiet option, for a dense
  /// grid where an error affordance on every tile would be noise.
  final Widget? fallback;

  /// Builds the failure state, given the reason and a retry callback.
  final Widget Function(
    BuildContext context,
    MediaLoadFailure failure,
    VoidCallback retry,
  )? errorBuilder;

  /// Overrides [profileImageStore] for this widget. For tests.
  final ProfileImageStore? store;

  final Duration readTimeout;
  final Duration downloadTimeout;

  @override
  State<CachedProfileImage> createState() => _CachedProfileImageState();
}

class _CachedProfileImageState extends State<CachedProfileImage> {
  File? _file;
  MediaLoadFailure? _failure;

  /// Identifies the attempt whose result is allowed to land. Bumped by every
  /// resolve, so a slow first attempt cannot overwrite the state of the retry
  /// that replaced it, and nothing lands after disposal.
  int _attempt = 0;
  String? _resolvedFor;

  ProfileImageStore get _store => widget.store ?? profileImageStore;

  String _keyFor(String url) => widget.cacheKey ?? url;

  @override
  void initState() {
    super.initState();
    _resolve(duringInit: true);
  }

  @override
  void didUpdateWidget(covariant CachedProfileImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url ||
        old.cacheKey != widget.cacheKey ||
        old.store != widget.store) {
      _resolve();
    }
  }

  /// Starts a fresh attempt. Safe to call from a retry button: the previous
  /// attempt is abandoned rather than reused.
  void _retry() => _resolve();

  /// Resolves the bytes this widget draws, through [mediaLoader] — so a card
  /// that is drawn twice, or torn down and rebuilt, shares ONE operation with
  /// its own recovery rather than starting a private one that fails alone.
  Future<void> _resolve({bool duringInit = false}) async {
    final int attempt = ++_attempt;
    final String? url = safeThumbnailUrl(widget.url);
    _resolvedFor = url;

    if (url == null) {
      _set(duringInit, failure: MediaLoadFailure.unusableSource);
      return;
    }

    final String key = _keyFor(url);

    // Bytes this process has already drawn are shown in the FIRST frame: a
    // tile scrolled past and come back to must not blink through a placeholder
    // to arrive at a picture that was on disk all along.
    final File? known = mediaLoader.knownFile(_store, key);
    if (known != null) {
      _set(duringInit, file: known);
      return;
    }

    _set(duringInit);

    final MediaLoadResult result = await mediaLoader.load(
      store: _store,
      url: url,
      key: key,
      storagePath: widget.storagePath,
      refresher: widget.urlRefresher,
      readTimeout: widget.readTimeout,
      downloadTimeout: widget.downloadTimeout,
    );

    if (!_stillCurrent(attempt, url)) return;
    setState(() {
      _file = result.file;
      _failure = result.failure;
    });
  }

  /// Applies state that is known synchronously. During `initState` there is no
  /// frame to rebuild yet, so the fields are simply set.
  void _set(bool duringInit, {File? file, MediaLoadFailure? failure}) {
    if (duringInit) {
      _file = file;
      _failure = failure;
      return;
    }
    if (!mounted) return;
    setState(() {
      _file = file;
      _failure = failure;
    });
  }

  /// True when this attempt is still the live one and the widget is still
  /// mounted. Guards every `setState` after an await.
  bool _stillCurrent(int attempt, String url) =>
      mounted && attempt == _attempt && _resolvedFor == url;

  @override
  Widget build(BuildContext context) {
    final File? file = _file;
    if (file != null) {
      return Image.file(
        file,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        // Corrupt or truncated bytes on disk decode to nothing. That is a
        // failure state, not a blank tile.
        errorBuilder: (_, __, ___) => _error(MediaLoadFailure.unavailable),
      );
    }
    final MediaLoadFailure? failure = _failure;
    if (failure != null) return _error(failure);
    // Still resolving, or the very first frame.
    return widget.placeholder ?? const SizedBox.shrink();
  }

  Widget _error(MediaLoadFailure failure) {
    final Widget Function(BuildContext, MediaLoadFailure, VoidCallback)?
        builder = widget.errorBuilder;
    if (builder != null) return builder(context, failure, _retry);
    return widget.fallback ?? widget.placeholder ?? const SizedBox.shrink();
  }
}
