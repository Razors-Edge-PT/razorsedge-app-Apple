/// Deciding what a video player should actually be pointed at.
///
/// Pulled out of the viewer widgets because it is the whole of the offline
/// story for video, and a widget that owns a platform player is the worst place
/// to test it. Nothing here touches `video_player`: it answers "file, URL, or
/// nothing — and if nothing, why", and the widget acts on the answer.
///
/// ── The order, and why ──────────────────────────────────────────────────────
/// 1. A STAGED local file, for the owner's own upload that has not published
///    yet. Its bytes exist nowhere else, so nothing else could work.
/// 2. A CACHED file, keyed by [profileMediaCacheKey]. This is what makes a clip
///    the user has already watched reopen with no connection — the honest
///    version of "works offline", as opposed to merely having kept a `smallUrl`
///    string that needs the network to mean anything.
/// 3. The STORED URL, streamed. Note what is NOT here: a `getDownloadURL()`
///    round trip. The post document already carries the download URL, so asking
///    Storage to mint another one is a network call the player does not need,
///    and one that fails outright when offline — turning a playable cached clip
///    into an error. Storage is consulted only when the document has no URL at
///    all.
///
/// ── Filling the cache ───────────────────────────────────────────────────────
/// Streaming does not populate the disk cache, so step 3 leaves the next open
/// exactly as network-dependent as this one. [VideoSourceResolver.fill] copies
/// the bytes into the store AFTER playback has started, so nothing waits on it
/// and the second open takes step 2. It runs at most once per key, is bounded,
/// and swallows its own failures: a fill that does not finish is a missed
/// optimisation, never a visible error.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/media_timeouts.dart';
import '../core/media_urls.dart';
import '../ui/cached_network_image.dart';
import 'media_url_refresh.dart';

/// What the player should be pointed at.
class VideoSource {
  /// A playable local file: staged, or already fully cached.
  VideoSource.localFile(File this.file, {this.fillFromUrl})
      : url = null,
        failure = null;

  /// A remote URL to stream. [fillFromUrl] is the same URL, offered so the
  /// caller can populate the cache once playback is under way.
  VideoSource.network(String this.url)
      : file = null,
        failure = null,
        fillFromUrl = url;

  /// Nothing is playable, and this is why.
  const VideoSource.unplayable(MediaLoadFailure this.failure)
      : file = null,
        url = null,
        fillFromUrl = null;

  final File? file;
  final String? url;
  final MediaLoadFailure? failure;

  /// Set when the cache does not yet hold these bytes and could.
  final String? fillFromUrl;

  bool get isPlayable => file != null || url != null;
}

/// Resolves a [VideoSource], and fills the cache behind one.
class VideoSourceResolver {
  VideoSourceResolver({
    ProfileImageStore? store,
    this.readTimeout = kMediaCacheReadTimeout,
    VoidCallback? onFilled,
  })  : _injected = store,
        onFilled = onFilled ?? ProfileMediaCache.tidyInBackground;

  final ProfileImageStore? _injected;
  final Duration readTimeout;

  /// Called after a fill writes new bytes. Defaults to the disk-ceiling sweep,
  /// which is started and never awaited.
  final VoidCallback? onFilled;

  ProfileImageStore get _store => _injected ?? profileImageStore;

  /// Fills running or already done in this process, keyed by media key.
  ///
  /// The value is the running future, so a second caller for the same clip
  /// JOINS the fill in flight instead of starting a second download of the
  /// same bytes. That is what makes reopening the page, rotating the device or
  /// rebuilding the widget free rather than expensive.
  static final Map<String, Future<bool>> _filling = <String, Future<bool>>{};

  /// Keys whose bytes are known to be on disk already, so a rebuild does not
  /// even ask the store.
  static final Set<String> _filled = <String>{};

  /// A hard cap on the bookkeeping itself, so a long session browsing hundreds
  /// of clips cannot grow this without bound. Dropping an entry only costs one
  /// extra cache lookup later; it can never cause a duplicate download,
  /// because [fill] checks the store before fetching anything.
  static const int _kMaxTrackedKeys = 500;

  /// For tests: forget which keys have been filled.
  static void resetFillTracking() {
    _filling.clear();
    _filled.clear();
  }

  /// True when a fill for [cacheKey] is running right now. For tests.
  static bool isFilling(String cacheKey) => _filling.containsKey(cacheKey);

  /// What to play for a piece of media.
  ///
  /// [localFilePath] is the staged copy of a not-yet-published upload;
  /// [url] is the stored download URL; [cacheKey] is its stable identity.
  /// [online] is the caller's best knowledge of connectivity — pass false to
  /// get an honest offline answer instead of a doomed stream attempt.
  Future<VideoSource> resolve({
    required String? url,
    required String cacheKey,
    String? localFilePath,
    bool online = true,
  }) async {
    // 1. Staged bytes for an upload in flight.
    if (localFilePath != null && localFilePath.isNotEmpty) {
      final File staged = File(localFilePath);
      if (staged.existsSync()) return VideoSource.localFile(staged);
    }

    // A poster URL is not a video. Callers have handed one here before — a
    // showcase proof's `thumbUrl` — and the player then initialised against a
    // JPEG and spun for ever.
    final String? playable = safeVideoSource(url);
    if (playable == null) {
      return const VideoSource.unplayable(MediaLoadFailure.unusableSource);
    }

    // 2. Already on disk: plays with no connection at all.
    try {
      final File? hit =
          await _store.cached(playable, key: cacheKey).timeout(readTimeout);
      if (hit != null && hit.existsSync() && hit.lengthSync() > 0) {
        return VideoSource.localFile(hit);
      }
    } catch (_) {
      // A wedged or corrupt index entry falls through to streaming. Nothing is
      // deleted on the way past.
    }

    // 3. Not cached. Streaming needs the network; saying so plainly is better
    //    than a player that initialises against nothing.
    if (!online) {
      return const VideoSource.unplayable(MediaLoadFailure.offline);
    }
    return VideoSource.network(playable);
  }

  /// A replacement source after a network attempt failed, or null.
  ///
  /// Video initialisation failures do not classify reliably — a revoked token
  /// reaches Flutter as a PlatformException whose message is whatever the
  /// platform player chose to say — so rather than guessing, this offers a
  /// SINGLE fresh URL when a `storagePath` is available and Storage returns
  /// something genuinely different from what just failed. One bounded retry,
  /// no classification, no loop, and the cache key is untouched.
  Future<String?> refreshedSource({
    required String storagePath,
    required String failedUrl,
    StorageUrlRefresher? refresher,
  }) {
    if (storagePath.trim().isEmpty) return Future<String?>.value(null);
    return (refresher ?? profileUrlRefresher)
        .replacementFor(storagePath, failedUrl);
  }

  /// Copies [url] into the store under [cacheKey], so the NEXT open resolves to
  /// a local file and works offline.
  ///
  /// ── The one extra transfer, and why it is accepted ─────────────────────────
  /// Streaming a video does not write it anywhere that outlives the player, so
  /// a clip watched online is still unavailable offline afterwards. Making the
  /// FIRST open offline-capable therefore means either downloading before
  /// playback — which makes the user stare at a spinner for the length of the
  /// download — or fetching once more in the background while it plays. The
  /// only way to get both is to tee the player's own byte stream into the
  /// cache, which needs a local proxy server or a caching data-source: a new
  /// native dependency in the playback path, on a production app, for one
  /// avoided transfer per clip ever opened.
  ///
  /// So the trade is deliberate: playback starts immediately from the network,
  /// and the clip costs at most ONE additional transfer, once, ever. Every
  /// subsequent open — this session or any later one, online or off — is local.
  /// The guards that make "once, ever" true rather than aspirational:
  ///
  ///   * a fill already in flight is JOINED, not restarted, so reopening the
  ///     page or rebuilding the widget cannot double up;
  ///   * a key already known to be cached returns immediately;
  ///   * otherwise the STORE is asked before anything is fetched, which is what
  ///     covers a fresh process that has no memory of earlier fills;
  ///   * staged local media never reaches here at all, because [resolve]
  ///     returns it with no `fillFromUrl`.
  ///
  /// Best-effort throughout: bounded by [kVideoCacheFillTimeout], never
  /// awaited by anything the user is waiting on, and silent on failure — a
  /// dropped connection leaves the clip fetchable again next time rather than
  /// marking it permanently un-cacheable.
  Future<bool> fill({required String url, required String cacheKey}) {
    if (_filled.contains(cacheKey)) return Future<bool>.value(false);
    final Future<bool>? running = _filling[cacheKey];
    if (running != null) return running;

    final Future<bool> run = _fill(url: url, cacheKey: cacheKey);
    _filling[cacheKey] = run;
    return run.whenComplete(() => _filling.remove(cacheKey));
  }

  Future<bool> _fill({required String url, required String cacheKey}) async {
    // Ask the store first. `getSingleFile` would serve a valid entry without
    // re-fetching anyway, but checking here means a process that restarted
    // mid-session never even opens a connection for bytes it already holds.
    try {
      final File? hit =
          await _store.cached(url, key: cacheKey).timeout(readTimeout);
      if (hit != null && hit.existsSync() && hit.lengthSync() > 0) {
        _remember(cacheKey);
        return false;
      }
    } catch (_) {
      // A wedged index is not a reason to skip the fill.
    }

    try {
      await _store.download(url, key: cacheKey).timeout(kVideoCacheFillTimeout);
      _remember(cacheKey);
      // New bytes landed: check the disk ceiling, without waiting for it.
      onFilled?.call();
      return true;
    } catch (_) {
      // Not remembered, so a later attempt is allowed: a fill that failed
      // because the connection dropped must not mark the clip un-cacheable.
      return false;
    }
  }

  static void _remember(String cacheKey) {
    if (_filled.length >= _kMaxTrackedKeys) _filled.clear();
    _filled.add(cacheKey);
  }
}
