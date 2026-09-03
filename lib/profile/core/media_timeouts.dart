/// The bounds every profile-media load runs under.
///
/// A load with no bound is not a slow load — it is a permanent spinner. A
/// stalled TCP connection (a captive portal, a dying cell handover, a Storage
/// object whose bytes never arrive) leaves `getSingleFile` and
/// `VideoPlayerController.initialize` pending FOREVER; neither has a timeout of
/// its own. Every one of them is wrapped here so the UI always reaches a state
/// the user can act on.
///
/// The values follow the app's existing convention — the 8 and 10 second
/// timeouts already used around Firestore and Storage work — scaled by how much
/// data each operation actually moves:
///
///   * [kMediaCacheReadTimeout] is a local SQLite index read plus a `stat`. If
///     that has not answered in three seconds the cache index is wedged, and
///     falling through to the network is strictly better than waiting.
///   * [kMediaDownloadTimeout] covers a thumbnail or a compressed still over a
///     poor mobile connection. Fifteen seconds is generous for objects of that
///     size and short enough that a stalled fetch surfaces while the user is
///     still looking at the screen.
///   * [kVideoInitTimeout] covers container probing and the first keyframe, not
///     the whole clip. Twenty seconds allows for a slow first byte on a set
///     video without leaving a dead player on screen indefinitely.
///   * [kVideoCacheFillTimeout] bounds the BACKGROUND copy that makes a clip
///     available offline next time. It is long because nothing waits on it, and
///     bounded so a stalled fill cannot hold a connection open for ever.
///
/// A timeout is never treated as "the content is gone": nothing valid is
/// evicted because a refresh expired, and every timeout resolves to a state
/// with a retry.
library;

/// Reading an already-persisted file out of the cache index.
const Duration kMediaCacheReadTimeout = Duration(seconds: 3);

/// Downloading and persisting an image (thumbnail, small, avatar).
const Duration kMediaDownloadTimeout = Duration(seconds: 15);

/// Initialising a video player against a local file or a remote URL.
const Duration kVideoInitTimeout = Duration(seconds: 20);

/// Filling the disk cache with a video that is already playing.
const Duration kVideoCacheFillTimeout = Duration(minutes: 3);
