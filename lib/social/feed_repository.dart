/// The buddy feed: one ordered, cursor-paginated query over the per-viewer
/// projection at `users/{uid}/feed`.
///
/// ── Why the query is this simple ───────────────────────────────────────────
/// All of the difficulty was moved to the server (see functions/social/feed.js
/// for the fan-out and the comparison against a chunked `posts` query). What
/// is left here is a single collection, already filtered to exactly what this
/// viewer may see, ordered by one field. That means:
///
///   * correct global ordering, not a merge of N per-friend cursors;
///   * `startAfterDocument` pagination that stays stable while new posts
///     arrive at the top, because a document cursor is a position in the
///     index rather than an offset;
///   * a page's cost independent of how many friends the viewer has.
///
/// ── What is NOT stored, and why the feed still knows who posted ────────────
/// Feed rows carry no username, display name or avatar. Denormalising those
/// would make one rename rewrite every row that account appears in, for every
/// friend. Instead each page resolves its DISTINCT owners once, through
/// [UserSearchRepository.lookupUsers], which batches and memoises — so a page
/// of twelve posts by three people costs one lookup of three accounts, not
/// twelve profile reads, and a new avatar appears immediately with no backfill.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../profile/core/media_identity.dart';
import '../profile/core/media_models.dart';

/// One card in the feed.
class FeedItem {
  const FeedItem({
    required this.id,
    required this.ownerUid,
    required this.postId,
    required this.mediaType,
    this.thumbUrl = '',
    this.smallUrl = '',
    this.storagePath = '',
    this.thumbStoragePath = '',
    this.caption = '',
    this.createdAt,
  });

  /// `{ownerUid}__{postId}`. Derived server-side, so the same post can never
  /// occupy two rows in one feed.
  final String id;

  final String ownerUid;
  final String postId;
  final String mediaType;
  final String thumbUrl;
  final String smallUrl;
  final String storagePath;
  final String thumbStoragePath;
  final String caption;
  final DateTime? createdAt;

  bool get isVideo => mediaType == MediaType.video;

  /// True when this row can actually be drawn.
  ///
  /// The server already applies this rule, so a false here means a row written
  /// by an older version of the function or a document mid-write. Checking
  /// again costs nothing and is what keeps an unknown media type out of an
  /// image decoder.
  bool get isRenderable =>
      isSupportedMediaType(mediaType) &&
      (smallUrl.isNotEmpty || thumbUrl.isNotEmpty || storagePath.isNotEmpty);

  /// The image a card shows: the poster for a video, the photo for an image.
  ///
  /// A video has NO fallback. `smallUrl` on a video row is the clip itself, and
  /// falling back to it asks a feed card to fetch tens of megabytes of video to
  /// draw a still. Today that is usually caught downstream by the container
  /// extension — but an extensionless Storage URL passes that check, and the
  /// card would download the clip. A video with no poster has nothing to draw,
  /// and saying so costs nothing.
  String get displayUrl {
    if (isVideo) return thumbUrl;
    return smallUrl.isNotEmpty ? smallUrl : thumbUrl;
  }

  /// The Storage object behind [displayUrl], when it is known.
  String get displayStoragePath =>
      isVideo ? thumbStoragePath : (storagePath.isNotEmpty ? storagePath : '');

  /// The cache identity of what this card draws.
  ///
  /// The SAME key the profile grid uses for the same object — owner, variant
  /// and Storage path, with the rotating download token excluded. That is what
  /// makes a photo already cached by a profile visit render instantly here
  /// with no second download and no second copy on disk. See
  /// lib/profile/core/media_identity.dart.
  String get displayCacheKey => profileMediaCacheKey(
        ownerUid: ownerUid,
        variant: isVideo ? MediaVariant.thumb : MediaVariant.small,
        storagePath: displayStoragePath,
        mediaId: postId,
        url: displayUrl,
      );

  static FeedItem fromSnapshot(DocumentSnapshot<Map<String, dynamic>> snap) {
    final Map<String, dynamic> d = snap.data() ?? const <String, dynamic>{};
    String s(String key) {
      final Object? v = d[key];
      return v is String ? v : '';
    }

    final Object? created = d['createdAt'];
    return FeedItem(
      id: snap.id,
      ownerUid: s('ownerUid'),
      postId: s('postId'),
      // Not defaulted to `image`: a row with the field missing is one this
      // build cannot render, and saying so is what keeps a video URL out of
      // the image decoder.
      mediaType: s('mediaType').trim().toLowerCase(),
      thumbUrl: s('thumbUrl'),
      smallUrl: s('smallUrl'),
      storagePath: s('storagePathOriginal'),
      thumbStoragePath: s('thumbStoragePath'),
      caption: s('caption'),
      createdAt: created is Timestamp ? created.toDate() : null,
    );
  }
}

/// One page of the feed, and where the next one starts.
class FeedPage {
  const FeedPage({
    required this.items,
    this.cursor,
    this.hasMore = false,
    this.fromCache = false,
  });

  final List<FeedItem> items;

  /// The last document of this page, used as `startAfterDocument` for the
  /// next. A DOCUMENT rather than a timestamp: two posts can share a
  /// timestamp, and an offset would skip or repeat rows as the feed grows.
  final DocumentSnapshot<Map<String, dynamic>>? cursor;

  final bool hasMore;

  /// True when Firestore answered from its own persistence rather than the
  /// server. The content is real and is shown; the UI just does not claim it
  /// is fresh.
  final bool fromCache;

  static const FeedPage empty = FeedPage(items: <FeedItem>[]);
}

class FeedRepository {
  FeedRepository({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    String? overrideUid,
    this.pageSize = 12,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _auth = auth,
        _overrideUid = overrideUid;

  final FirebaseFirestore _db;
  final FirebaseAuth? _auth;
  final String? _overrideUid;

  /// Rows per page. Small enough that a page is cheap and the first screen
  /// appears quickly, large enough that scrolling does not fetch constantly.
  final int pageSize;

  /// The signed-in account. A coach's selected athlete has no feed of their
  /// own to show here — the feed belongs to the person holding the phone.
  String? get currentUid {
    if (_overrideUid != null) return _overrideUid;
    return (_auth ?? FirebaseAuth.instance).currentUser?.uid;
  }

  /// How long the first page waits for a session that is still being restored.
  static const Duration kAccountWait = Duration(seconds: 10);

  /// The signed-in account, waiting briefly for one that has not arrived yet.
  ///
  /// The home feed mounts during startup, and `currentUser` can still be null
  /// for the moment it takes Firebase to restore the session. Reading that as
  /// "this person has no posts" is how a feed became a permanent *Nothing here
  /// yet* — nothing re-queries, because as far as the view is concerned the
  /// answer arrived. Waiting for the account instead costs one spinner and
  /// makes the empty state mean what it says.
  Future<String?> resolveUid() async {
    final String? now = currentUid;
    if (now != null) return now;
    try {
      final User? user = await (_auth ?? FirebaseAuth.instance)
          .authStateChanges()
          .firstWhere((User? u) => u != null)
          .timeout(kAccountWait);
      return user?.uid;
    } catch (_) {
      // No session within the window: genuinely signed out, as far as the feed
      // is concerned.
      return null;
    }
  }

  Query<Map<String, dynamic>> _baseQuery(String uid) => _db
      .collection('users')
      .doc(uid)
      .collection('feed')
      .orderBy('createdAt', descending: true);

  /// Loads one page, starting after [cursor] when continuing.
  ///
  /// [fromServer] forces a network read for pull-to-refresh; everything else
  /// takes Firestore's default, which serves the local copy immediately when
  /// there is one. That is what makes the feed appear instantly on launch,
  /// including offline, before any refresh completes.
  Future<FeedPage> loadPage({
    DocumentSnapshot<Map<String, dynamic>>? cursor,
    bool fromServer = false,
  }) async {
    final String? uid = await resolveUid();
    if (uid == null) return FeedPage.empty;

    Query<Map<String, dynamic>> q = _baseQuery(uid);
    if (cursor != null) q = q.startAfterDocument(cursor);
    // One extra row is fetched purely to answer "is there another page?"
    // without a second query, and is dropped before the page is returned.
    q = q.limit(pageSize + 1);

    final QuerySnapshot<Map<String, dynamic>> snap = await q.get(
      fromServer ? const GetOptions(source: Source.server) : null,
    );

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = snap.docs;
    final bool hasMore = docs.length > pageSize;
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> pageDocs =
        hasMore ? docs.sublist(0, pageSize) : docs;

    return FeedPage(
      items: pageDocs
          .map(FeedItem.fromSnapshot)
          .where((FeedItem i) => i.isRenderable)
          .toList(growable: false),
      cursor: pageDocs.isEmpty ? cursor : pageDocs.last,
      hasMore: hasMore,
      fromCache: snap.metadata.isFromCache,
    );
  }

  /// Merges [next] into [existing], newest first and without duplicates.
  ///
  /// Deduplication is by feed-item id, which is `{ownerUid}__{postId}` — so a
  /// post that arrives in two overlapping pages (a refresh racing a page load)
  /// appears once, and a post replaced by its owner replaces its own row
  /// rather than sitting beside it.
  static List<FeedItem> merge(List<FeedItem> existing, List<FeedItem> next) {
    final Map<String, FeedItem> byId = <String, FeedItem>{};
    for (final FeedItem item in <FeedItem>[...existing, ...next]) {
      byId[item.id] = item;
    }
    final List<FeedItem> merged = byId.values.toList()
      ..sort((FeedItem a, FeedItem b) {
        final DateTime? x = a.createdAt;
        final DateTime? y = b.createdAt;
        if (x == null && y == null) return a.id.compareTo(b.id);
        // A row with no timestamp cannot be placed in time, so it goes last
        // rather than to the top, where it would displace real content.
        if (x == null) return 1;
        if (y == null) return -1;
        final int byTime = y.compareTo(x);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    return List<FeedItem>.unmodifiable(merged);
  }

  /// The distinct accounts appearing in [items], for a single batched lookup.
  static List<String> distinctOwners(Iterable<FeedItem> items) =>
      items.map((FeedItem i) => i.ownerUid).where((String u) => u.isNotEmpty).toSet().toList(growable: false);
}
