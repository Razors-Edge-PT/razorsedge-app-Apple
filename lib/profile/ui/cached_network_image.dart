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
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../core/media_identity.dart';
import '../core/media_timeouts.dart';
import '../core/media_urls.dart';

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
///   * at most [kMaxCachedObjects] objects, evicted least-recently-used first;
///   * an object untouched for [kStalePeriod] is dropped;
///   * eviction is by COUNT, not by byte budget — that is what the package
///     offers — so the ceiling is deliberately modest given a cached video is
///     far larger than a thumbnail.
///
/// A separate store from `DefaultCacheManager` on purpose: the feed and the
/// post detail page share that one, and profile media should not be able to
/// evict their entries or be evicted by them.
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
        ),
      );
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
    final FileInfo? hit = await _manager.getFileFromCache(key ?? url);
    // package:file's File implements dart:io's File, so this widens cleanly.
    return hit?.file;
  }

  @override
  Future<File> download(String url, {String? key}) =>
      _manager.getSingleFile(url, key: key ?? url);

  @override
  Future<void> evict(String key) => _manager.removeFile(key);
}

/// The store profile media is persisted in.
///
/// Injectable so a test can point it at a temporary directory and then prove a
/// *new* store over the *same* directory still serves the file — which is what
/// a process restart is.
ProfileImageStore profileImageStore = CacheManagerImageStore();

/// Resets [profileImageStore] to the app-wide default. For tests.
void resetProfileImageCache() => profileImageStore = CacheManagerImageStore();

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
    _resolve();
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

  Future<void> _resolve() async {
    final int attempt = ++_attempt;
    final String? url = safeThumbnailUrl(widget.url);
    _resolvedFor = url;

    if (url == null) {
      if (mounted) {
        setState(() {
          _file = null;
          _failure = MediaLoadFailure.unusableSource;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _file = null;
        _failure = null;
      });
    }

    final String key = _keyFor(url);

    // 1. Disk first. A previously viewed image is available with no network,
    //    which is the whole point. Bounded: a wedged cache index must not hold
    //    the tile hostage when the network would have answered.
    try {
      final File? hit =
          await _store.cached(url, key: key).timeout(widget.readTimeout);
      if (hit != null && hit.existsSync()) {
        if (!_stillCurrent(attempt, url)) return;
        setState(() => _file = hit);
        return;
      }
    } catch (_) {
      // A corrupt or slow index entry is not worth failing over, and it is
      // certainly not worth deleting anything over; fall through to the
      // download, which rewrites it.
    }

    // 2. Miss: download, and persist for next time — including next launch.
    try {
      final File downloaded =
          await _store.download(url, key: key).timeout(widget.downloadTimeout);
      if (!_stillCurrent(attempt, url)) return;
      setState(() => _file = downloaded);
    } on TimeoutException {
      if (!_stillCurrent(attempt, url)) return;
      setState(() => _failure = MediaLoadFailure.timedOut);
    } catch (e) {
      if (!_stillCurrent(attempt, url)) return;
      setState(() => _failure = isConnectivityFailure(e)
          ? MediaLoadFailure.offline
          : MediaLoadFailure.unavailable);
    }
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
        errorBuilder: (_, __, ___) =>
            _error(MediaLoadFailure.unavailable),
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
