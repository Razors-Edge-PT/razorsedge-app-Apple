/// Models for the profile media grid, proof videos and stories.
///
/// These read the EXISTING `posts` documents field-for-field, so every post,
/// caption, comment and video written by earlier builds keeps working. The new
/// fields are additive and every one of them has a backward-compatible default:
///
///   type            'upload' | 'proof' | 're_daily'   (absent ⇒ 'upload')
///   showInGrid      bool                              (absent ⇒ true)
///   achievement     { fingerprint, slot }             (absent ⇒ not a proof)
///   mediaId         deterministic client id           (absent ⇒ use the doc id)
///
/// Stories are NOT posts. They live in `users/{uid}/stories`, expire, and are
/// deliberately excluded from the permanent grid unless the user separately
/// publishes the asset as a post.
library;

import 'package:cloud_firestore/cloud_firestore.dart';

import 'media_identity.dart';

/// What a media document is for.
class MediaType {
  static const String image = 'image';
  static const String video = 'video';
}

/// The `type` field on a post document.
class PostKind {
  /// An ordinary training image or video the owner added.
  static const String upload = 'upload';

  /// A video attached as proof of a specific Big Five record.
  static const String proof = 'proof';

  /// A generated daily RE summary card.
  static const String reDaily = 're_daily';
}

/// The achievement a proof video is attached to.
class ProofLink {
  const ProofLink({required this.fingerprint, required this.slot});

  /// The record fingerprint (see `recordFingerprint`). A proof belongs to the
  /// exact source performance, not to a lift slot in general — which is what
  /// lets an old video stay in the gallery without silently re-labelling a
  /// record it did not produce.
  final String fingerprint;

  /// The Big Five slot the record belongs to, for display only.
  final String slot;

  Map<String, Object?> toMap() =>
      <String, Object?>{'fingerprint': fingerprint, 'slot': slot};

  static ProofLink? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final Object? fp = raw['fingerprint'];
    if (fp is! String || fp.isEmpty) return null;
    return ProofLink(fingerprint: fp, slot: (raw['slot'] as String?) ?? '');
  }
}

/// One tile in the profile grid.
class ProfileMediaItem {
  const ProfileMediaItem({
    required this.id,
    required this.ownerUid,
    required this.mediaType,
    required this.kind,
    this.storagePath = '',
    this.thumbStoragePath,
    this.thumbUrl = '',
    this.smallUrl = '',
    this.caption,
    this.createdAt,
    this.proof,
    this.showInGrid = true,
    this.commentCount = 0,
    this.likeCount = 0,
    this.goodLiftCount = 0,
    this.localFilePath,
    this.localThumbPath,
    this.pending = false,
    this.failed = false,
    this.lastError,
  });

  final String id;
  final String ownerUid;

  /// [MediaType].
  final String mediaType;

  /// [PostKind].
  final String kind;

  final String storagePath;

  /// Where the poster object lives, when the writer recorded it. Only used to
  /// key the cache; the thumbnail is still fetched from [thumbUrl].
  final String? thumbStoragePath;

  final String thumbUrl;
  final String smallUrl;
  final String? caption;
  final DateTime? createdAt;

  /// Set when this item was uploaded as proof of a record.
  final ProofLink? proof;

  final bool showInGrid;
  final int commentCount;
  final int likeCount;
  final int goodLiftCount;

  /// Local staging paths, for an item that is still uploading.
  final String? localFilePath;
  final String? localThumbPath;

  /// True for an optimistic tile backed by the outbox rather than Firestore.
  final bool pending;

  /// True when the upload has stopped retrying and needs the user.
  final bool failed;
  final String? lastError;

  bool get isVideo => mediaType == MediaType.video;
  bool get isProof => kind == PostKind.proof && proof != null;

  /// True when this item's `mediaType` is one the app can actually render.
  ///
  /// False for a record with the field missing or set to something unknown.
  /// Those used to be indistinguishable from images — [fromSnapshot] defaulted
  /// the field — which is how a video with a dropped `mediaType`, and an RE
  /// Daily record with no media at all, both ended up in the image decoder.
  bool get isSupported => isSupportedMediaType(mediaType);

  /// The stable cache identity of one rendition of this item.
  ///
  /// Derived from the owner and the object's own Storage path, so it survives
  /// download-token rotation and changes when the content is genuinely
  /// replaced — every upload gets a fresh `mediaId`, and therefore a fresh
  /// path. See media_identity.dart.
  String cacheKey(String variant) => profileMediaCacheKey(
        ownerUid: ownerUid,
        variant: variant,
        storagePath: variant == MediaVariant.thumb
            ? (thumbStoragePath ?? '')
            : storagePath,
        mediaId: id,
        url: variant == MediaVariant.thumb ? thumbUrl : smallUrl,
      );

  static ProfileMediaItem fromSnapshot(
    DocumentSnapshot<Map<String, dynamic>> snap,
  ) {
    final Map<String, dynamic> d = snap.data() ?? const <String, dynamic>{};
    final Object? created = d['createdAt'];
    return ProfileMediaItem(
      id: snap.id,
      ownerUid: (d['ownerUid'] as String?) ?? '',
      // NOT defaulted to `image`. A record with the field missing is not an
      // image — it is a record this build cannot render, and saying so is what
      // keeps a video URL out of the image decoder and an RE Daily summary out
      // of the gallery. See ProfileMediaItem.isSupported.
      mediaType: (d['mediaType'] as String?)?.trim().toLowerCase() ?? '',
      // Legacy uploads carry no `type` at all.
      kind: (d['type'] as String?) ?? PostKind.upload,
      storagePath: (d['storagePathOriginal'] as String?) ?? '',
      thumbStoragePath: d['thumbStoragePath'] as String?,
      thumbUrl: (d['thumbUrl'] as String?) ?? '',
      smallUrl: (d['smallUrl'] as String?) ?? '',
      caption: d['caption'] as String?,
      createdAt: created is Timestamp ? created.toDate() : null,
      proof: ProofLink.fromMap(d['achievement']),
      // Absent means "yes" — every pre-existing post stays in the grid.
      showInGrid: d['showInGrid'] is bool ? d['showInGrid'] as bool : true,
      commentCount: (d['commentCount'] as num?)?.toInt() ?? 0,
      likeCount: (d['likeCount'] as num?)?.toInt() ?? 0,
      goodLiftCount: (d['goodLiftCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A 24-hour story.
class StoryItem {
  const StoryItem({
    required this.id,
    required this.ownerUid,
    required this.mediaType,
    this.url = '',
    this.thumbUrl = '',
    this.storagePath = '',
    this.publishedAt,
    this.pending = false,
    this.localFilePath,
  });

  final String id;
  final String ownerUid;
  final String mediaType;
  final String url;
  final String thumbUrl;
  final String storagePath;

  /// Server-assigned publication time. Null only for a pending local item that
  /// has not published yet — and a story with no publication time has not
  /// started its 24 hours.
  final DateTime? publishedAt;

  /// True for an owner-only local item still waiting to upload.
  final bool pending;
  final String? localFilePath;

  static const Duration ttl = Duration(hours: 24);

  /// A story is live for exactly 24 hours from publication. At EXACTLY 24
  /// hours it is expired. Mirrors `isStoryLive` in functions/social/stories.js.
  bool isLiveAt(DateTime now) {
    final DateTime? published = publishedAt;
    if (published == null) return false;
    return now.difference(published) < ttl;
  }

  DateTime? get expiresAt => publishedAt?.add(ttl);

  static StoryItem fromSnapshot(DocumentSnapshot<Map<String, dynamic>> snap) {
    final Map<String, dynamic> d = snap.data() ?? const <String, dynamic>{};
    final Object? published = d['publishedAt'];
    return StoryItem(
      id: snap.id,
      ownerUid: (d['ownerUid'] as String?) ?? '',
      // Stories are written only by the current publisher, which always sets
      // this. Left defaulted deliberately: the gallery's eligibility rules are
      // about `posts`, and a story is not a post.
      mediaType: (d['mediaType'] as String?) ?? MediaType.image,
      url: (d['url'] as String?) ?? '',
      thumbUrl: (d['thumbUrl'] as String?) ?? '',
      storagePath: (d['storagePath'] as String?) ?? '',
      publishedAt: published is Timestamp ? published.toDate() : null,
    );
  }
}
