/// The ONE way a published post is deleted.
///
/// ── Why this is centralised ─────────────────────────────────────────────────
/// A post could be deleted from two places, and they did different things. The
/// profile grid removed the proof pointer named on the tile it was showing; the
/// feed's post detail page removed the Firestore document and the Storage
/// objects and nothing else. So deleting a proof video from the feed left
/// `users/{uid}/proofs/{fingerprint}` behind, still claiming an achievement is
/// proved by a post that no longer exists — a permanent broken tile on the
/// showcase that the owner had no way to clear.
///
/// The grid's version was not complete either. It only ever removed the ONE
/// pointer carried on the item it was handed, and a single post can be the
/// proof of more than one record: the relink flow attaches an existing video to
/// another fingerprint without re-uploading, and one set that is both an
/// athlete's best E1RM and their heaviest single is two fingerprints served by
/// one video.
///
/// So deletion asks the question the other way round — *which pointers name
/// this post?* — and removes every one of them.
///
/// ── Order ───────────────────────────────────────────────────────────────────
/// The order is deliberate and unchanged:
///   1. every proof pointer that referenced it, so a record never points at
///      media that is about to vanish,
///   2. the Storage objects,
///   3. the legacy per-user mirror document,
///   4. the post document, LAST.
/// A crash part-way leaves the post document present, so the next attempt
/// finishes the job — the opposite order would orphan Storage objects with
/// nothing left to find them by. Every step tolerates "already gone", so
/// repeating it is safe.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Deletes a published post and everything that points at it.
///
/// [storagePath] is the post's `storagePathOriginal` when the caller knows it.
/// It is only used for legacy posts whose object lives outside the per-post
/// folder; anything inside the folder is removed by the folder sweep.
Future<void> deletePostEverywhere({
  required FirebaseFirestore firestore,
  required FirebaseStorage storage,
  required String ownerUid,
  required String postId,
  String storagePath = '',
}) async {
  await deleteProofPointersForPost(
    firestore: firestore,
    ownerUid: ownerUid,
    postId: postId,
  );

  // The folder holds the original AND the generated poster frame, so listing
  // it is what makes thumbnail cleanup automatic rather than another thing to
  // remember.
  await _deleteStorageFolder(storage, 'users/$ownerUid/posts/$postId');
  if (storagePath.isNotEmpty &&
      !storagePath.startsWith('users/$ownerUid/posts/$postId/')) {
    await _deleteObject(storage, storagePath);
  }

  // Legacy per-user mirror. Absent on everything written by recent builds.
  try {
    await firestore
        .collection('users')
        .doc(ownerUid)
        .collection('posts')
        .doc(postId)
        .delete();
  } catch (_) {
    // Nothing there, or no permission. The post document below is what
    // matters, and it is deleted next.
  }

  await firestore.collection('posts').doc(postId).delete();
}

/// Removes EVERY proof pointer that references [postId].
///
/// Queried by `postId` rather than by a fingerprint the caller happens to be
/// holding, because one post can prove more than one record and the caller
/// usually knows about only one of them.
Future<int> deleteProofPointersForPost({
  required FirebaseFirestore firestore,
  required String ownerUid,
  required String postId,
}) async {
  try {
    final QuerySnapshot<Map<String, dynamic>> matches = await firestore
        .collection('users')
        .doc(ownerUid)
        .collection('proofs')
        .where('postId', isEqualTo: postId)
        .get();
    if (matches.docs.isEmpty) return 0;
    final WriteBatch batch = firestore.batch();
    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
        in matches.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
    return matches.docs.length;
  } catch (_) {
    // A viewer without proof access, or an offline read. The post deletion
    // still proceeds; a pointer whose post is gone stops resolving anyway, and
    // the next owner-side deletion attempt clears it.
    return 0;
  }
}

Future<void> _deleteStorageFolder(FirebaseStorage storage, String path) async {
  try {
    final ListResult listing = await storage.ref(path).listAll();
    for (final Reference item in listing.items) {
      await item.delete().catchError((Object _) {});
    }
  } catch (_) {
    // Nothing there, or no permission to list. Either way there is nothing
    // useful to do here, and the caller's next step still runs.
  }
}

Future<void> _deleteObject(FirebaseStorage storage, String path) async {
  if (path.isEmpty) return;
  try {
    await storage.ref(path).delete();
  } on FirebaseException catch (e) {
    // 'object-not-found' is the expected outcome of a repeat run.
    if (e.code != 'object-not-found') rethrow;
  }
}
