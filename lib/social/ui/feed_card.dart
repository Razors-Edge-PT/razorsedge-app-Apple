/// One post in the buddy feed.
///
/// ── What a card costs when it scrolls past ────────────────────────────────
/// One image: the photo, or the POSTER for a video. Never the video itself.
/// A feed card entering the viewport must not start downloading a clip — on a
/// phone feed that is the difference between a few hundred kilobytes and tens
/// of megabytes for content the person never stopped on. The video is fetched
/// only when the card is opened, by the existing detail page and player.
///
/// There is deliberately no autoplay. The app has never autoplayed video
/// anywhere else, and adding it here would be a new behaviour, a new battery
/// cost and a new data cost that nothing asked for.
///
/// The image is drawn by [CachedProfileImage] under the SAME cache key the
/// profile grid uses for the same object, so a photo already seen on someone's
/// profile is already on disk here — no second download, no second copy.
library;

import 'package:flutter/material.dart';

import '../../profile/core/media_urls.dart';
import '../../profile/ui/cached_network_image.dart';
import '../../profile/ui/profile_theme.dart';
import '../feed_repository.dart';
import '../user_search_result.dart';
import 'user_row.dart';

/// How far past the bottom of the screen a card starts loading its picture,
/// as a fraction of the viewport.
///
/// Half a screen is about one card ahead: far enough that an ordinary scroll
/// meets pictures already there, near enough that opening the home page does
/// not fetch a feed nobody has scrolled to. The home page needs this stated
/// explicitly — its feed is a plain column inside the page's own scroll view,
/// so every card of every loaded page is BUILT whether or not it is on screen.
/// Without a gate, arriving at the home page started a download for every post
/// at once, during the busiest second of startup; the Buddy Hub, whose list
/// builds lazily, only ever started the two or three on screen. That is the
/// whole of the difference the two screens showed.
const double kFeedMediaLookAhead = 0.5;

/// How far a card must travel OFF screen before its picture is released.
///
/// Larger than the look-ahead so a small scroll back and forth does not unload
/// and reload the same image, and bounded so that a long scroll through the
/// feed holds a screenful of decoded pictures rather than all of them.
const double kFeedMediaKeepAlive = 1.5;

/// A concise relative time: `now`, `4m`, `3h`, `2d`, then a date.
///
/// Short because it sits beside a name on one line, and a feed reads better
/// when the timestamp is a glance rather than a sentence.
String formatRelativeTime(DateTime? when, {DateTime? now}) {
  if (when == null) return '';
  final DateTime reference = now ?? DateTime.now();
  final Duration d = reference.difference(when);
  if (d.isNegative) return 'now';
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  if (d.inDays < 365) return '${(d.inDays / 7).floor()}w';
  return '${(d.inDays / 365).floor()}y';
}

class FeedCard extends StatelessWidget {
  const FeedCard({
    super.key,
    required this.item,
    this.owner,
    this.onOpen,
    this.onOpenProfile,
    this.now,
  });

  final FeedItem item;

  /// The poster's identity, resolved once per DISTINCT account per page.
  /// Null while that lookup is in flight, or when it failed offline.
  final UserSearchResult? owner;

  final VoidCallback? onOpen;
  final VoidCallback? onOpenProfile;

  /// Injectable clock, so the relative time is testable.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final String name = owner?.bestName ?? 'GoodLift member';
    final String handle = owner?.handle ?? '';
    final String age = formatRelativeTime(item.createdAt, now: now);

    return Padding(
      padding: const EdgeInsets.only(bottom: ProfileSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Header(
            name: name,
            handle: handle,
            age: age,
            photoURL: owner?.photoURL ?? '',
            onOpenProfile: onOpenProfile,
          ),
          const SizedBox(height: ProfileSpacing.sm),
          _Media(item: item, onOpen: onOpen, authorName: name),
          if (item.caption.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: ProfileSpacing.sm),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: ProfileSpacing.lg),
              child: Text(
                item.caption.trim(),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: ProfileText.bio(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.handle,
    required this.age,
    required this.photoURL,
    this.onOpenProfile,
  });

  final String name;
  final String handle;
  final String age;
  final String photoURL;
  final VoidCallback? onOpenProfile;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onOpenProfile != null,
      label: 'Open $name\'s profile',
      child: InkWell(
        onTap: onOpenProfile,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ProfileSpacing.lg,
            vertical: ProfileSpacing.xs,
          ),
          child: Row(
            children: <Widget>[
              BuddyAvatar(photoURL: photoURL, size: 34),
              const SizedBox(width: ProfileSpacing.sm + 2),
              Expanded(
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ProfileText.liftName(context),
                      ),
                    ),
                    if (handle.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          handle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ProfileText.caption(context),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (age.isNotEmpty) ...<Widget>[
                const SizedBox(width: ProfileSpacing.sm),
                Text(age, style: ProfileText.caption(context)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Media extends StatelessWidget {
  const _Media({required this.item, required this.authorName, this.onOpen});

  final FeedItem item;
  final String authorName;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    // Decided here rather than inside the image: a post with nothing safe to
    // draw — a video whose poster never uploaded — gets a quiet placeholder,
    // not an error with a Retry button that cannot possibly help.
    final String? source = safeThumbnailUrl(item.displayUrl);

    return Semantics(
      button: onOpen != null,
      label: item.isVideo
          ? 'Play $authorName\'s video'
          : 'Open $authorName\'s photo',
      child: GestureDetector(
        onTap: onOpen,
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (source == null)
                _NoMedia(isVideo: item.isVideo)
              else
                _WhenNearViewport(
                  placeholder: const _MediaPlaceholder(),
                  builder: (BuildContext context) => CachedProfileImage(
                    url: source,
                    // The same object's key on every surface. Sharing it is
                    // what makes an already-seen photo appear with no download.
                    cacheKey: item.displayCacheKey,
                    storagePath: item.displayStoragePath,
                    fit: BoxFit.cover,
                    placeholder: const _MediaPlaceholder(),
                    errorBuilder: (
                      BuildContext context,
                      MediaLoadFailure failure,
                      VoidCallback retry,
                    ) =>
                        failure == MediaLoadFailure.unusableSource
                            ? _NoMedia(isVideo: item.isVideo)
                            : _MediaFailure(failure: failure, onRetry: retry),
                  ),
                ),
              if (item.isVideo)
                const Positioned(
                  right: ProfileSpacing.sm,
                  bottom: ProfileSpacing.sm,
                  child: _VideoBadge(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Builds its child only while it is on screen or about to be.
///
/// The feed is drawn by one widget in two hosts. In the Buddy Hub it owns a
/// lazy list, so the list itself decides what exists. On the home page it is a
/// column inside the page's scroll view, where EVERY card of every loaded page
/// is built at once — so without this, arriving at the home page starts a
/// download for every post in the feed simultaneously, and a long scroll keeps
/// every decoded picture in memory at the same time.
///
/// Measuring against the enclosing viewport rather than counting index numbers
/// means both hosts get the same answer, and so does a card in any host added
/// later. With no scroll view above it — a card drawn on its own, a test — the
/// answer is simply yes.
class _WhenNearViewport extends StatefulWidget {
  const _WhenNearViewport({required this.builder, required this.placeholder});

  final WidgetBuilder builder;
  final Widget placeholder;

  @override
  State<_WhenNearViewport> createState() => _WhenNearViewportState();
}

class _WhenNearViewportState extends State<_WhenNearViewport> {
  bool _near = false;
  bool _pendingCheck = false;
  ScrollableState? _scrollable;
  ScrollPosition? _position;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    _scrollable = scrollable;
    final ScrollPosition? position = scrollable?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_check);
      _position = position;
      _position?.addListener(_check);
    }
    if (scrollable == null) {
      // Nothing scrolls above this card, so it is exactly as visible as the
      // screen it is on.
      _near = true;
      return;
    }
    _scheduleCheck();
  }

  @override
  void dispose() {
    _position?.removeListener(_check);
    super.dispose();
  }

  /// Measured after layout: before it, the card has no position to measure.
  void _scheduleCheck() {
    if (_pendingCheck) return;
    _pendingCheck = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingCheck = false;
      _check();
    });
  }

  void _check() {
    if (!mounted) return;
    final bool? near = _measure();
    if (near == null || near == _near) return;
    setState(() => _near = near);
  }

  /// Whether this card is inside the load window, or null when that cannot be
  /// answered yet.
  bool? _measure() {
    final ScrollPosition? position = _position;
    final RenderObject? self = context.findRenderObject();
    final RenderObject? viewport = _scrollable?.context.findRenderObject();
    if (position == null ||
        !position.hasViewportDimension ||
        self is! RenderBox ||
        !self.attached ||
        !self.hasSize ||
        viewport is! RenderBox ||
        !viewport.attached) {
      return null;
    }

    final Offset offset = self.localToGlobal(Offset.zero, ancestor: viewport);
    final bool vertical = position.axis == Axis.vertical;
    final double leading = vertical ? offset.dy : offset.dx;
    final double extent = vertical ? self.size.height : self.size.width;
    final double viewportExtent = position.viewportDimension;

    // Hysteresis: a card is taken in early and let go late, so that scrolling
    // back and forth across one edge cannot thrash a download.
    final double margin =
        viewportExtent * (_near ? kFeedMediaKeepAlive : kFeedMediaLookAhead);
    return leading < viewportExtent + margin && leading + extent > -margin;
  }

  @override
  Widget build(BuildContext context) {
    if (!_near) _scheduleCheck();
    return _near ? widget.builder(context) : widget.placeholder;
  }
}

/// A post with nothing to draw: a video whose poster frame never uploaded.
///
/// Deliberately not an error. The clip is fine and opening the card plays it;
/// there is simply no still to show, and offering Retry for bytes that do not
/// exist is an invitation to tap something that can never work.
class _NoMedia extends StatelessWidget {
  const _NoMedia({required this.isVideo});

  final bool isVideo;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: ProfilePalette.surface,
        child: Center(
          child: Icon(
            isVideo ? Icons.movie_outlined : Icons.image_outlined,
            size: 28,
            color: ProfilePalette.textMuted,
          ),
        ),
      );
}

/// What a card shows before its picture: a still, faintly lit panel.
///
/// Static on purpose. A pulsing skeleton on a page of them reads as activity
/// the app is not performing, and an animation that never stops is a battery
/// cost on a feed that may sit on screen. A quiet surface that resolves into a
/// photograph is the calmer of the two, and the honest one.
class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[ProfilePalette.surface, ProfilePalette.navy],
          ),
        ),
      );
}

/// A failed image, with a way out.
///
/// Never an indefinite spinner: a card that cannot load its picture says so
/// and offers Retry, because a spinner that never resolves is indistinguishable
/// from an app that has stopped working.
class _MediaFailure extends StatelessWidget {
  const _MediaFailure({required this.failure, required this.onRetry});

  final MediaLoadFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final bool offline = failure == MediaLoadFailure.offline;
    return Container(
      color: ProfilePalette.surface,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            offline ? Icons.cloud_off_rounded : Icons.broken_image_outlined,
            color: ProfilePalette.textMuted,
            size: 28,
          ),
          const SizedBox(height: ProfileSpacing.sm),
          Text(
            offline ? "Not downloaded yet" : "Couldn't load",
            style: ProfileText.caption(context),
          ),
          const SizedBox(height: ProfileSpacing.sm),
          TextButton(
            onPressed: onRetry,
            child: Text(
              'Retry',
              style: ProfileText.button(context)
                  .copyWith(color: ProfilePalette.action),
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoBadge extends StatelessWidget {
  const _VideoBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.play_arrow_rounded,
        color: Colors.white,
        size: 18,
      ),
    );
  }
}
