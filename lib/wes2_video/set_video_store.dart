/// Durable local record of the videos a user has filmed against their sets.
///
/// ── Why this is not the media outbox ────────────────────────────────────────
/// `media_outbox.dart` holds TRANSIENT intent: rows that exist only until an
/// upload is proven to have landed, and are then deleted. A set video is the
/// opposite — it is the user's own footage, it is device-only for the vast
/// majority of sets, and it must still be there next year when they reopen that
/// workout offline. Mixing the two would mean either the outbox stops being
/// self-cleaning or the videos start being swept. So: separate table, separate
/// database file, same conventions.
///
/// ── Why application support and not cache ───────────────────────────────────
/// The bytes live in application support for the same reason the outbox stages
/// there: a cache or temp directory is swept by the OS at will, and on iOS the
/// camera's own output path can be invalidated as soon as the capture UI
/// closes. A row here is a promise that the file is durable, so the file is
/// moved into place BEFORE the row is written.
///
/// ── Association ────────────────────────────────────────────────────────────
/// A record is keyed on the set's STABLE identity (`Wes2SetState.setId`), never
/// its index. Set positions are renumbered whenever a set is removed; identity
/// is not. [SetVideoRecord.setIndex] is carried as an advisory display hint
/// only, refreshed opportunistically, and is never used to find a record.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'set_video_store.g.dart';

/// Where a recording stands with respect to the server.
///
/// The overwhelmingly common state is [local]: an ordinary set's video is never
/// uploaded at all.
class SetVideoState {
  /// On this device only. No server object, no post, nothing queued.
  static const String local = 'local';

  /// Confirmed as a current PB and handed to the media outbox. Not yet live.
  static const String queued = 'queued';

  /// Live on the profile as a post and as proof for at least one record.
  static const String published = 'published';

  /// Soft-deleted while an Undo is still available. Files still on disk.
  static const String pendingDelete = 'pendingDelete';
}

@DataClassName('SetVideoRecord')
class SetVideos extends Table {
  /// Deterministic: `ownerUid|dateKey|exerciseId|setId`. Chosen by the client
  /// so re-attaching to the same set is an update, never a duplicate row.
  TextColumn get id => text()();

  /// The profile that owns the footage. Every query filters on this, so a
  /// second account signing in on the same device sees none of it.
  TextColumn get ownerUid => text()();

  /// `yyyy-MM-dd` of the workout day, matching the WES2 document id.
  TextColumn get dateKey => text()();

  TextColumn get exerciseId => text()();

  /// Stable set identity. The association key — never the index.
  TextColumn get setId => text()();

  /// Advisory display position, refreshed opportunistically. Never used to
  /// find a record.
  IntColumn get setIndex => integer().withDefault(const Constant(0))();

  /// Durable path inside application support.
  TextColumn get localVideoPath => text()();

  TextColumn get localPosterPath => text().nullable()();

  IntColumn get durationMs => integer().withDefault(const Constant(0))();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();

  IntColumn get createdAtMs => integer()();
  IntColumn get updatedAtMs => integer()();

  /// [SetVideoState].
  TextColumn get state =>
      text().withDefault(const Constant(SetVideoState.local))();

  /// Canonical lift slot ([BigFiveSlot]) when the exercise is one of them.
  TextColumn get liftSlot => text().nullable()();

  /// The exact record fingerprint this footage was confirmed against.
  TextColumn get fingerprint => text().nullable()();

  /// Media id shared with the outbox once queued, so one upload serves the
  /// gallery tile and every proof slot it satisfies.
  TextColumn get mediaId => text().nullable()();

  /// The published post holding the media.
  TextColumn get postId => text().nullable()();

  /// True once the user has explicitly deleted or detached this footage.
  ///
  /// Reconciliation is idempotent and runs often, so without this flag a
  /// deleted PB video would simply be re-queued on the next pass. Only a new
  /// recording or an explicit replace clears it.
  BoolColumn get suppressed => boolean().withDefault(const Constant(false))();

  /// Set while a soft delete is undoable; the files are only unlinked after it.
  IntColumn get deletedAtMs => integer().nullable()();

  /// The previous file, kept until the replacement is proven good. Deleting
  /// this is the LAST step of a replacement, never the first.
  TextColumn get supersededVideoPath => text().nullable()();

  TextColumn get supersededPosterPath => text().nullable()();

  /// Monotonic per record. An older async replacement that finishes late is
  /// rejected rather than allowed to restore a video the user already replaced.
  IntColumn get generation => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => <Column>{id};
}

@DriftDatabase(tables: <Type>[SetVideos])
class SetVideoDatabase extends _$SetVideoDatabase {
  SetVideoDatabase(super.e);

  /// Opens in application support — backed up, and not swept like a cache.
  static Future<SetVideoDatabase> open() async {
    final Directory dir = await getApplicationSupportDirectory();
    final File file = File(p.join(dir.path, 'goodlift_set_videos.sqlite'));
    return SetVideoDatabase(NativeDatabase(file));
  }

  /// In-memory instance for tests.
  static SetVideoDatabase memory() => SetVideoDatabase(NativeDatabase.memory());

  @override
  int get schemaVersion => 1;
}

/// The deterministic record id for one set's footage.
String setVideoIdFor({
  required String ownerUid,
  required String dateKey,
  required String exerciseId,
  required String setId,
}) =>
    '$ownerUid|$dateKey|$exerciseId|$setId';

/// All reads and writes for durable set footage.
///
/// Deliberately explicit: this owns the record and the on-disk lifetime of the
/// files, and nothing else. Deciding whether footage may be uploaded is the
/// reconciler's job, and doing the upload is the outbox's.
class SetVideoStore {
  SetVideoStore(this._db);

  final SetVideoDatabase _db;

  SetVideoDatabase get database => _db;

  Future<void> close() => _db.close();

  int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<SetVideoRecord?> byId(String id) =>
      (_db.select(_db.setVideos)..where(($SetVideosTable t) => t.id.equals(id)))
          .getSingleOrNull();

  /// The footage for one exact set, or null. Identity-keyed, so it is immune to
  /// set renumbering.
  Future<SetVideoRecord?> forSet({
    required String ownerUid,
    required String dateKey,
    required String exerciseId,
    required String setId,
  }) =>
      byId(setVideoIdFor(
        ownerUid: ownerUid,
        dateKey: dateKey,
        exerciseId: exerciseId,
        setId: setId,
      ));

  /// Everything filmed on one day, for one owner. Excludes soft-deleted rows.
  ///
  /// This is what makes footage reappear when the user reopens that date, with
  /// no network involved.
  Future<List<SetVideoRecord>> forDay({
    required String ownerUid,
    required String dateKey,
  }) =>
      (_db.select(_db.setVideos)
            ..where(($SetVideosTable t) =>
                t.ownerUid.equals(ownerUid) &
                t.dateKey.equals(dateKey) &
                t.deletedAtMs.isNull()))
          .get();

  /// Records that a reconciliation pass should consider, for one owner.
  ///
  /// Excludes anything suppressed, soft-deleted, or already live: republishing
  /// those is exactly the resurrection the user asked us not to do.
  Future<List<SetVideoRecord>> publishCandidates(String ownerUid) =>
      (_db.select(_db.setVideos)
            ..where(($SetVideosTable t) =>
                t.ownerUid.equals(ownerUid) &
                t.deletedAtMs.isNull() &
                t.suppressed.equals(false) &
                t.state.equals(SetVideoState.local)))
          .get();

  /// Creates or replaces the footage for one set.
  ///
  /// Loss-safe by construction: the caller must already have written the new
  /// file to [localVideoPath]. Any file this record previously pointed at is
  /// recorded in `supersededVideoPath` for the caller to delete only AFTER this
  /// returns — the old video is never unlinked before the new one is committed.
  ///
  /// A replacement clears [suppressed] (the user deliberately supplied new
  /// footage) and resets publication state, so the new clip is reconsidered on
  /// its own merits.
  Future<SetVideoRecord> put({
    required String ownerUid,
    required String dateKey,
    required String exerciseId,
    required String setId,
    required String localVideoPath,
    String? localPosterPath,
    int setIndex = 0,
    int durationMs = 0,
    int sizeBytes = 0,
    String? liftSlot,
  }) async {
    final String id = setVideoIdFor(
      ownerUid: ownerUid,
      dateKey: dateKey,
      exerciseId: exerciseId,
      setId: setId,
    );
    return _db.transaction(() async {
      final SetVideoRecord? existing = await byId(id);
      final int now = _now();

      await _db.into(_db.setVideos).insert(
            SetVideosCompanion.insert(
              id: id,
              ownerUid: ownerUid,
              dateKey: dateKey,
              exerciseId: exerciseId,
              setId: setId,
              setIndex: Value<int>(setIndex),
              localVideoPath: localVideoPath,
              localPosterPath: Value<String?>(localPosterPath),
              durationMs: Value<int>(durationMs),
              sizeBytes: Value<int>(sizeBytes),
              createdAtMs: existing?.createdAtMs ?? now,
              updatedAtMs: now,
              state: const Value<String>(SetVideoState.local),
              liftSlot: Value<String?>(liftSlot),
              // A replacement is a fresh candidate: it has not been confirmed
              // against any record yet, and it is not the old post's media.
              fingerprint: const Value<String?>(null),
              mediaId: const Value<String?>(null),
              postId: const Value<String?>(null),
              suppressed: const Value<bool>(false),
              deletedAtMs: const Value<int?>(null),
              // Only carry a superseded path when it is genuinely a DIFFERENT
              // file, so re-saving the same path cannot schedule its own
              // deletion.
              supersededVideoPath: Value<String?>(
                existing != null && existing.localVideoPath != localVideoPath
                    ? existing.localVideoPath
                    : null,
              ),
              supersededPosterPath: Value<String?>(
                existing != null &&
                        existing.localPosterPath != null &&
                        existing.localPosterPath != localPosterPath
                    ? existing.localPosterPath
                    : null,
              ),
              generation: Value<int>((existing?.generation ?? -1) + 1),
            ),
            mode: InsertMode.insertOrReplace,
          );
      return (await byId(id))!;
    });
  }

  /// Refreshes the advisory display index after a reindex. Never moves footage.
  Future<void> touchSetIndex(String id, int setIndex) =>
      (_db.update(_db.setVideos)..where(($SetVideosTable t) => t.id.equals(id)))
          .write(SetVideosCompanion(
        setIndex: Value<int>(setIndex),
        updatedAtMs: Value<int>(_now()),
      ));

  /// Records that this footage has been handed to the outbox for one exact
  /// fingerprint. Rejected if [generation] is stale.
  Future<bool> markQueued({
    required String id,
    required String mediaId,
    required String fingerprint,
    required String liftSlot,
    required int generation,
  }) async {
    final SetVideoRecord? row = await byId(id);
    if (row == null || row.generation != generation) return false;
    await (_db.update(_db.setVideos)
          ..where(($SetVideosTable t) => t.id.equals(id)))
        .write(SetVideosCompanion(
      state: const Value<String>(SetVideoState.queued),
      mediaId: Value<String?>(mediaId),
      fingerprint: Value<String?>(fingerprint),
      liftSlot: Value<String?>(liftSlot),
      updatedAtMs: Value<int>(_now()),
    ));
    return true;
  }

  /// Records a successful publication. Rejected if [generation] is stale, so a
  /// slow upload cannot mark a record the user has since replaced.
  Future<bool> markPublished({
    required String id,
    required String postId,
    required int generation,
  }) async {
    final SetVideoRecord? row = await byId(id);
    if (row == null || row.generation != generation) return false;
    await (_db.update(_db.setVideos)
          ..where(($SetVideosTable t) => t.id.equals(id)))
        .write(SetVideosCompanion(
      state: const Value<String>(SetVideoState.published),
      postId: Value<String?>(postId),
      updatedAtMs: Value<int>(_now()),
    ));
    return true;
  }

  /// Returns a queued record to local-only, e.g. when the candidate turned out
  /// to have been superseded before the upload committed.
  Future<void> markLocalOnly(String id) =>
      (_db.update(_db.setVideos)..where(($SetVideosTable t) => t.id.equals(id)))
          .write(SetVideosCompanion(
        state: const Value<String>(SetVideoState.local),
        mediaId: const Value<String?>(null),
        updatedAtMs: Value<int>(_now()),
      ));

  /// Clears the superseded paths once the caller has unlinked those files.
  Future<void> clearSuperseded(String id) =>
      (_db.update(_db.setVideos)..where(($SetVideosTable t) => t.id.equals(id)))
          .write(SetVideosCompanion(
        supersededVideoPath: const Value<String?>(null),
        supersededPosterPath: const Value<String?>(null),
        updatedAtMs: Value<int>(_now()),
      ));

  /// Soft-deletes while an Undo is still on offer. Files stay on disk.
  ///
  /// [suppress] is what stops a PB video the user deliberately removed from
  /// being re-queued by the next reconciliation pass.
  Future<void> softDelete(String id, {bool suppress = true}) =>
      (_db.update(_db.setVideos)..where(($SetVideosTable t) => t.id.equals(id)))
          .write(SetVideosCompanion(
        state: const Value<String>(SetVideoState.pendingDelete),
        deletedAtMs: Value<int?>(_now()),
        suppressed: Value<bool>(suppress),
        updatedAtMs: Value<int>(_now()),
      ));

  /// Reverses a soft delete while it is still undoable.
  ///
  /// Restores to local-only rather than to whatever it was: if it really is
  /// still a PB, the next reconciliation pass will confirm that from the server
  /// and re-queue it. Guessing here would be a second PB algorithm.
  Future<void> undoDelete(String id) =>
      (_db.update(_db.setVideos)..where(($SetVideosTable t) => t.id.equals(id)))
          .write(SetVideosCompanion(
        state: const Value<String>(SetVideoState.local),
        deletedAtMs: const Value<int?>(null),
        suppressed: const Value<bool>(false),
        updatedAtMs: Value<int>(_now()),
      ));

  /// Marks footage as detached from its achievement but kept in the gallery.
  /// The post survives; only automatic re-attachment is suppressed.
  Future<void> detach(String id) =>
      (_db.update(_db.setVideos)..where(($SetVideosTable t) => t.id.equals(id)))
          .write(SetVideosCompanion(
        fingerprint: const Value<String?>(null),
        liftSlot: const Value<String?>(null),
        suppressed: const Value<bool>(true),
        updatedAtMs: Value<int>(_now()),
      ));

  /// Soft-deleted rows whose Undo window has elapsed, for ONE owner.
  ///
  /// Owner-scoped deliberately. A pass run while one account is signed in must
  /// never finalise — and therefore unlink the files of — footage belonging to
  /// another account that has used the same device.
  Future<List<SetVideoRecord>> finalizable({
    required String ownerUid,
    required DateTime before,
  }) {
    final int cutoff = before.millisecondsSinceEpoch;
    return (_db.select(_db.setVideos)
          ..where(($SetVideosTable t) =>
              t.ownerUid.equals(ownerUid) &
              t.deletedAtMs.isNotNull() &
              t.deletedAtMs.isSmallerThanValue(cutoff)))
        .get();
  }

  /// Removes the row for good. Idempotent: deleting an absent row is a no-op,
  /// so a retried or duplicated cleanup pass is harmless.
  Future<void> purge(String id) =>
      (_db.delete(_db.setVideos)..where(($SetVideosTable t) => t.id.equals(id)))
          .go();

  /// Suppresses the local record behind a published proof, by fingerprint.
  ///
  /// The bridge between a removal made on the PROFILE and the local footage
  /// that produced it. Without it, detaching or deleting a PB video on the
  /// profile would be undone by the next reconciliation pass, which would find
  /// the clip still local, still a PB, and queue it again.
  ///
  /// Returns the number of records suppressed. Idempotent.
  Future<int> suppressByFingerprint({
    required String ownerUid,
    required String fingerprint,
  }) async {
    if (fingerprint.trim().isEmpty) return 0;
    return (_db.update(_db.setVideos)
          ..where(($SetVideosTable t) =>
              t.ownerUid.equals(ownerUid) & t.fingerprint.equals(fingerprint)))
        .write(SetVideosCompanion(
      suppressed: const Value<bool>(true),
      updatedAtMs: Value<int>(_now()),
    ));
  }

  /// Suppresses the local record behind a published post, by post id.
  ///
  /// Used when the user deletes the media itself rather than detaching it.
  /// Returns the number of records suppressed. Idempotent.
  Future<int> suppressByPostId({
    required String ownerUid,
    required String postId,
  }) async {
    if (postId.trim().isEmpty) return 0;
    return (_db.update(_db.setVideos)
          ..where(($SetVideosTable t) =>
              t.ownerUid.equals(ownerUid) & t.postId.equals(postId)))
        .write(SetVideosCompanion(
      suppressed: const Value<bool>(true),
      updatedAtMs: Value<int>(_now()),
    ));
  }

  /// Suppresses by the media id the outbox knows it as, for a deletion that
  /// happens before the post document exists. Idempotent.
  Future<int> suppressByMediaId({
    required String ownerUid,
    required String mediaId,
  }) async {
    if (mediaId.trim().isEmpty) return 0;
    return (_db.update(_db.setVideos)
          ..where(($SetVideosTable t) =>
              t.ownerUid.equals(ownerUid) & t.mediaId.equals(mediaId)))
        .write(SetVideosCompanion(
      suppressed: const Value<bool>(true),
      updatedAtMs: Value<int>(_now()),
    ));
  }

  /// Every record for an owner, including soft-deleted ones. For account
  /// teardown and diagnostics.
  Future<List<SetVideoRecord>> allFor(String ownerUid) =>
      (_db.select(_db.setVideos)
            ..where(($SetVideosTable t) => t.ownerUid.equals(ownerUid)))
          .get();
}
