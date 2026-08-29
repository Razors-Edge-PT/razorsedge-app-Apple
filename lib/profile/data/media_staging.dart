/// Turns a picked file into a durably queued upload.
///
/// The order here is the safety property: the bytes are COPIED into
/// application support BEFORE an outbox row is created. A row is a promise that
/// the file is safe to upload later, and the picker's own path is not — it lives
/// in a cache directory the OS may clear at any moment, and on iOS it can be
/// invalidated as soon as the picker closes.
///
/// Compression happens here too, so what is queued is what will be sent: the
/// queued file's size is the size that must satisfy the Storage rules.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../core/media_models.dart';
import 'media_outbox.dart';

/// Must match the limits in storage.rules, so a file that would be rejected by
/// the server is rejected before the user is told it is queued.
const int kMaxImageBytes = 10 * 1024 * 1024;
const int kMaxVideoBytes = 100 * 1024 * 1024;

/// Raised when a picked file cannot be accepted.
class MediaRejected implements Exception {
  MediaRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

class MediaStaging {
  MediaStaging({required MediaOutbox outbox}) : _outbox = outbox;

  final MediaOutbox _outbox;
  final Random _random = Random.secure();

  /// A deterministic, client-chosen media id. Chosen BEFORE any upload so the
  /// Storage path and the Firestore document id are both known in advance,
  /// which is what makes a retry an overwrite rather than a duplicate.
  String newMediaId() {
    const String alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final StringBuffer buf = StringBuffer();
    for (int i = 0; i < 20; i++) {
      buf.write(alphabet[_random.nextInt(alphabet.length)]);
    }
    return buf.toString();
  }

  Future<Directory> _stagingDir() async {
    final Directory support = await getApplicationSupportDirectory();
    final Directory dir = Directory(p.join(support.path, 'media_outbox'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Copies (and for images, compresses) [source] into application support.
  Future<File> _stage(File source, String mediaId, String mediaType) async {
    final Directory dir = await _stagingDir();
    final String ext = mediaType == MediaType.video ? '.mp4' : '.jpg';
    final File target = File(p.join(dir.path, '$mediaId$ext'));

    if (mediaType == MediaType.image) {
      final File? compressed = await _compressImage(source, target);
      if (compressed != null) return compressed;
    }
    return source.copy(target.path);
  }

  Future<File?> _compressImage(File source, File target) async {
    try {
      final XFile? out = await FlutterImageCompress.compressAndGetFile(
        source.absolute.path,
        target.path,
        quality: 82,
        minWidth: 1440,
        minHeight: 1440,
      );
      if (out == null) return null;
      return File(out.path);
    } catch (_) {
      // Compression is an optimisation, not a requirement. Fall back to a
      // straight copy rather than refusing the user's photo.
      return null;
    }
  }

  Future<String?> _videoThumb(File video, String mediaId) async {
    try {
      final Directory dir = await _stagingDir();
      final String? path = await VideoThumbnail.thumbnailFile(
        video: video.path,
        thumbnailPath: p.join(dir.path, '${mediaId}_thumb.jpg'),
        imageFormat: ImageFormat.JPEG,
        maxWidth: 720,
        quality: 70,
      );
      return path;
    } catch (_) {
      return null;
    }
  }

  void _checkSize(File file, String mediaType) {
    final int bytes = file.lengthSync();
    final int limit =
        mediaType == MediaType.video ? kMaxVideoBytes : kMaxImageBytes;
    if (bytes > limit) {
      final int mb = limit ~/ (1024 * 1024);
      throw MediaRejected(
        mediaType == MediaType.video
            ? 'That video is too large — keep it under $mb MB.'
            : 'That image is too large — keep it under $mb MB.',
      );
    }
  }

  /// Queues a grid upload (an ordinary training image or video).
  Future<OutboxItem> queuePost({
    required String ownerUid,
    required File source,
    required String mediaType,
    String? caption,
  }) async {
    final String mediaId = newMediaId();
    final File staged = await _stage(source, mediaId, mediaType);
    _checkSize(staged, mediaType);
    final String? thumb = mediaType == MediaType.video
        ? await _videoThumb(staged, mediaId)
        : staged.path;

    return _outbox.enqueue(
      mediaId: mediaId,
      ownerUid: ownerUid,
      kind: OutboxKind.post,
      mediaType: mediaType,
      storagePath: 'users/$ownerUid/posts/$mediaId/'
          '${mediaType == MediaType.video ? 'original.mp4' : 'original.jpg'}',
      localFilePath: staged.path,
      localThumbPath: thumb,
      caption: caption,
    );
  }

  /// Queues a proof video for one exact record fingerprint.
  ///
  /// The SAME asset becomes the grid tile and the proof — there is never a
  /// second upload of the same file.
  Future<OutboxItem> queueProof({
    required String ownerUid,
    required File source,
    required String fingerprint,
    required String slot,
    String mediaType = MediaType.video,
    String? caption,
  }) async {
    final String mediaId = newMediaId();
    final File staged = await _stage(source, mediaId, mediaType);
    _checkSize(staged, mediaType);
    final String? thumb = mediaType == MediaType.video
        ? await _videoThumb(staged, mediaId)
        : staged.path;

    return _outbox.enqueue(
      mediaId: mediaId,
      ownerUid: ownerUid,
      kind: OutboxKind.proof,
      mediaType: mediaType,
      storagePath: 'users/$ownerUid/posts/$mediaId/'
          '${mediaType == MediaType.video ? 'original.mp4' : 'original.jpg'}',
      localFilePath: staged.path,
      localThumbPath: thumb,
      caption: caption,
      achievementFingerprint: fingerprint,
      achievementSlot: slot,
    );
  }

  /// Queues a story. Its 24 hours do not begin here — they begin when the
  /// upload and the Firestore publication both succeed.
  Future<OutboxItem> queueStory({
    required String ownerUid,
    required File source,
    required String mediaType,
  }) async {
    final String mediaId = newMediaId();
    final File staged = await _stage(source, mediaId, mediaType);
    _checkSize(staged, mediaType);
    final String? thumb = mediaType == MediaType.video
        ? await _videoThumb(staged, mediaId)
        : staged.path;

    return _outbox.enqueue(
      mediaId: mediaId,
      ownerUid: ownerUid,
      kind: OutboxKind.story,
      mediaType: mediaType,
      storagePath: 'users/$ownerUid/stories/$mediaId/'
          '${mediaType == MediaType.video ? 'original.mp4' : 'original.jpg'}',
      localFilePath: staged.path,
      localThumbPath: thumb,
    );
  }

  /// Queues a replacement avatar.
  ///
  /// The supersession key makes every older pending avatar stale in the same
  /// transaction, so a slow earlier upload can never overwrite this choice —
  /// however long it takes to finish.
  Future<OutboxItem> queueAvatar({
    required String ownerUid,
    required File source,
  }) async {
    final String mediaId = newMediaId();
    final File staged = await _stage(source, mediaId, MediaType.image);
    _checkSize(staged, MediaType.image);

    return _outbox.enqueue(
      mediaId: mediaId,
      ownerUid: ownerUid,
      kind: OutboxKind.avatar,
      mediaType: MediaType.image,
      // Generation-stamped path: two competing avatars never write the same
      // object, so the loser can be deleted without touching the winner.
      storagePath: 'users/$ownerUid/profile/$mediaId.jpg',
      localFilePath: staged.path,
      localThumbPath: staged.path,
      supersessionKey: 'avatar:$ownerUid',
    );
  }
}
