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

import '../core/media_timeouts.dart';
import '../core/media_urls.dart';
import '../ui/cached_network_image.dart';

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
  VideoSourceResolver(
      {ProfileImageStore? store, this.readTimeout = kMediaCacheReadTimeout})
      : _injected = store;

  final ProfileImageStore? _injected;
  final Duration readTimeout;

  ProfileImageStore get _store => _injected ?? profileImageStore;

  /// Keys whose fill is running or done in this process, so opening the same
  /// clip repeatedly cannot start a download loop.
  static final Set<String> _filling = <String>{};

  /// For tests: forget which keys have been filled.
  static void resetFillTracking() => _filling.clear();

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

  /// Copies [url] into the store under [cacheKey], so the NEXT open resolves to
  /// a local file and works offline.
  ///
  /// Best-effort by design: it runs after playback has started, at most once
  /// per key per process, under [kVideoCacheFillTimeout], and never surfaces an
  /// error. Returns true when the bytes are now cached.
  Future<bool> fill({required String url, required String cacheKey}) async {
    if (_filling.contains(cacheKey)) return false;
    _filling.add(cacheKey);
    try {
      await _store.download(url, key: cacheKey).timeout(kVideoCacheFillTimeout);
      return true;
    } catch (_) {
      // Allow a later attempt: a fill that failed because the connection
      // dropped should not permanently mark this clip as un-cacheable.
      _filling.remove(cacheKey);
      return false;
    }
  }
}
