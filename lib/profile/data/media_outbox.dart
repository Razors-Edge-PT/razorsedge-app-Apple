/// Durable media-upload outbox, backed by Drift/SQLite.
///
/// This is the ONLY place this feature uses a local database, and it holds
/// exactly one kind of thing: media uploads that have been accepted from the
/// user but not yet proven to exist in Firestore. Structured profile data
/// (identity, bio, achievements, grid metadata) lives in Firestore's own
/// persistent cache — see ProfileRepository — and Isar is not extended here.
///
/// ── Why a database and not the upload task ──────────────────────────────────
/// Firebase Storage upload tasks do not survive process death. Pausing and
/// resuming one is a convenience, never a correctness mechanism. Correctness
/// comes from this table plus a deterministic retry: whatever the app was in
/// the middle of, the row is still here when it reopens.
///
/// ── The two crash windows ───────────────────────────────────────────────────
/// An upload is two writes — the Storage object, then the Firestore metadata —
/// and the app can die between them, in either direction:
///
///   1. Storage succeeded, Firestore did not. The retry re-uploads to the SAME
///      deterministic path (mediaId is chosen up front, not by the server), so
///      the second attempt overwrites byte-identical content and the metadata
///      commit finishes the job. No duplicate object, no duplicate post.
///
///   2. Firestore succeeded, the outbox row survived. The processor checks for
///      the metadata document BEFORE re-uploading; finding it, it skips
///      straight to cleanup. No duplicate post, no wasted upload.
///
/// ── Supersession ────────────────────────────────────────────────────────────
/// Replaceable assets (the avatar) carry a supersession key. Queueing a new
/// avatar marks every older pending avatar row superseded, and a superseded
/// row can never commit its metadata — so a slow upload chosen at 10:00 can
/// never overwrite the one chosen at 10:01, whatever order the network
/// finishes them in. Superseded rows still get their staged files and orphaned
/// Storage objects cleaned up.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'media_outbox.g.dart';

/// Lifecycle of an outbox row.
class OutboxState {
  /// Staged locally, waiting for a processor pass.
  static const String pending = 'pending';

  /// A processor pass is working on it right now.
  static const String uploading = 'uploading';

  /// Replaced by a newer choice for the same supersession key.
  static const String superseded = 'superseded';

  /// Repeated failures; kept for the user to retry explicitly.
  static const String failed = 'failed';
}

/// What the row is for. Drives the Storage path and the metadata commit.
class OutboxKind {
  static const String avatar = 'avatar';
  static const String post = 'post';
  static const String proof = 'proof';
  static const String story = 'story';
}

@DataClassName('OutboxItem')
class OutboxItems extends Table {
  /// Deterministic media id, chosen on the client BEFORE any upload. It is
  /// what makes the Storage path and the Firestore document id predictable,
  /// which is what makes a retry idempotent.
  TextColumn get mediaId => text()();

  TextColumn get ownerUid => text()();

  /// [OutboxKind].
  TextColumn get kind => text()();

  /// 'image' | 'video'.
  TextColumn get mediaType => text()();

  /// Fully-qualified Storage object path, decided up front.
  TextColumn get storagePath => text()();

  /// Copy of the picked file inside application support — NOT the picker's
  /// temporary path, which the OS may delete at any time.
  TextColumn get localFilePath => text()();

  /// Locally generated thumbnail, if any.
  TextColumn get localThumbPath => text().nullable()();

  TextColumn get caption => text().nullable()();

  /// Record fingerprint this upload is proof of, for [OutboxKind.proof].
  TextColumn get achievementFingerprint => text().nullable()();

  /// Big Five slot for a proof upload.
  TextColumn get achievementSlot => text().nullable()();

  /// [OutboxState].
  TextColumn get state =>
      text().withDefault(const Constant(OutboxState.pending))();

  IntColumn get attemptCount => integer().withDefault(const Constant(0))();

  TextColumn get lastError => text().nullable()();

  /// Identity of a replaceable asset (e.g. `avatar:<uid>`). Null for
  /// append-only media, which is never superseded.
  TextColumn get supersessionKey => text().nullable()();

  /// Monotonic generation within a supersession key. Higher always wins.
  IntColumn get generation => integer().withDefault(const Constant(0))();

  IntColumn get createdAtMs => integer()();
  IntColumn get updatedAtMs => integer()();

  @override
  Set<Column> get primaryKey => <Column>{mediaId};
}

@DriftDatabase(tables: <Type>[OutboxItems])
class MediaOutboxDatabase extends _$MediaOutboxDatabase {
  MediaOutboxDatabase(super.e);

  /// Opens the database in application support, which is backed up and is not
  /// swept by the OS the way a cache or temp directory is.
  static Future<MediaOutboxDatabase> open() async {
    final Directory dir = await getApplicationSupportDirectory();
    final File file = File(p.join(dir.path, 'goodlift_media_outbox.sqlite'));
    return MediaOutboxDatabase(NativeDatabase(file));
  }

  /// In-memory instance for tests.
  static MediaOutboxDatabase memory() =>
      MediaOutboxDatabase(NativeDatabase.memory());

  @override
  int get schemaVersion => 1;
}

/// All outbox reads and writes. Deliberately small and explicit — the uploader
/// owns the network, this owns the durable record of intent.
class MediaOutbox {
  MediaOutbox(this._db);

  final MediaOutboxDatabase _db;

  MediaOutboxDatabase get database => _db;

  Future<void> close() => _db.close();

  int _now() => DateTime.now().millisecondsSinceEpoch;

  /// Queues an upload. The caller must ALREADY have copied the picked file to
  /// [localFilePath] inside application support — a row is a promise that the
  /// bytes are safe, so it must not be made before they are.
  ///
  /// When [supersessionKey] is set, every older pending row for that key is
  /// marked superseded in the same transaction, so there is never a window in
  /// which two generations both look live.
  Future<OutboxItem> enqueue({
    required String mediaId,
    required String ownerUid,
    required String kind,
    required String mediaType,
    required String storagePath,
    required String localFilePath,
    String? localThumbPath,
    String? caption,
    String? achievementFingerprint,
    String? achievementSlot,
    String? supersessionKey,
  }) async {
    return _db.transaction(() async {
      int generation = 0;
      if (supersessionKey != null) {
        final List<OutboxItem> siblings = await (_db.select(_db.outboxItems)
              ..where(($OutboxItemsTable t) =>
                  t.supersessionKey.equals(supersessionKey)))
            .get();
        for (final OutboxItem s in siblings) {
          if (s.generation >= generation) generation = s.generation + 1;
        }
        await (_db.update(_db.outboxItems)
              ..where(($OutboxItemsTable t) =>
                  t.supersessionKey.equals(supersessionKey) &
                  t.state.isNotValue(OutboxState.superseded)))
            .write(OutboxItemsCompanion(
          state: const Value<String>(OutboxState.superseded),
          updatedAtMs: Value<int>(_now()),
        ));
      }

      final OutboxItemsCompanion row = OutboxItemsCompanion.insert(
        mediaId: mediaId,
        ownerUid: ownerUid,
        kind: kind,
        mediaType: mediaType,
        storagePath: storagePath,
        localFilePath: localFilePath,
        localThumbPath: Value<String?>(localThumbPath),
        caption: Value<String?>(caption),
        achievementFingerprint: Value<String?>(achievementFingerprint),
        achievementSlot: Value<String?>(achievementSlot),
        supersessionKey: Value<String?>(supersessionKey),
        generation: Value<int>(generation),
        state: const Value<String>(OutboxState.pending),
        createdAtMs: _now(),
        updatedAtMs: _now(),
      );
      await _db
          .into(_db.outboxItems)
          .insert(row, mode: InsertMode.insertOrReplace);
      return (await byId(mediaId))!;
    });
  }

  Future<OutboxItem?> byId(String mediaId) => (_db.select(_db.outboxItems)
        ..where(($OutboxItemsTable t) => t.mediaId.equals(mediaId)))
      .getSingleOrNull();

  /// Everything still owed to the user, newest first. Includes failed rows so
  /// the UI can offer a retry; excludes superseded rows, which are only
  /// waiting for cleanup.
  Future<List<OutboxItem>> pendingFor(String ownerUid) =>
      (_db.select(_db.outboxItems)
            ..where(($OutboxItemsTable t) =>
                t.ownerUid.equals(ownerUid) &
                t.state.isNotValue(OutboxState.superseded))
            ..orderBy(<OrderingTerm Function($OutboxItemsTable)>[
              ($OutboxItemsTable t) => OrderingTerm(
                  expression: t.createdAtMs, mode: OrderingMode.desc),
            ]))
          .get();

  /// Live view of pending items, for the grid's optimistic tiles.
  Stream<List<OutboxItem>> watchPendingFor(String ownerUid) =>
      (_db.select(_db.outboxItems)
            ..where(($OutboxItemsTable t) =>
                t.ownerUid.equals(ownerUid) &
                t.state.isNotValue(OutboxState.superseded))
            ..orderBy(<OrderingTerm Function($OutboxItemsTable)>[
              ($OutboxItemsTable t) => OrderingTerm(
                  expression: t.createdAtMs, mode: OrderingMode.desc),
            ]))
          .watch();

  /// Work the processor should attempt, oldest first so the queue drains in
  /// the order the user chose things. Superseded rows are never uploaded.
  Future<List<OutboxItem>> claimable({int limit = 10}) =>
      (_db.select(_db.outboxItems)
            ..where(($OutboxItemsTable t) => t.state.isIn(<String>[
                  OutboxState.pending,
                  OutboxState.uploading,
                ]))
            ..orderBy(<OrderingTerm Function($OutboxItemsTable)>[
              ($OutboxItemsTable t) => OrderingTerm(expression: t.createdAtMs),
            ])
            ..limit(limit))
          .get();

  /// Rows superseded by a newer generation, whose staged files and possibly
  /// uploaded Storage objects still need cleaning up.
  Future<List<OutboxItem>> superseded() => (_db.select(_db.outboxItems)
        ..where(
            ($OutboxItemsTable t) => t.state.equals(OutboxState.superseded)))
      .get();

  Future<void> markUploading(String mediaId) => (_db.update(_db.outboxItems)
            ..where(($OutboxItemsTable t) => t.mediaId.equals(mediaId)))
          .write(OutboxItemsCompanion(
        state: const Value<String>(OutboxState.uploading),
        updatedAtMs: Value<int>(_now()),
      ));

  Future<void> markFailed(String mediaId, String error,
          {required bool terminal}) =>
      (_db.update(_db.outboxItems)
            ..where(($OutboxItemsTable t) => t.mediaId.equals(mediaId)))
          .write(OutboxItemsCompanion(
        state:
            Value<String>(terminal ? OutboxState.failed : OutboxState.pending),
        lastError: Value<String?>(error),
        updatedAtMs: Value<int>(_now()),
      ));

  Future<void> bumpAttempt(String mediaId) async {
    final OutboxItem? row = await byId(mediaId);
    if (row == null) return;
    await (_db.update(_db.outboxItems)
          ..where(($OutboxItemsTable t) => t.mediaId.equals(mediaId)))
        .write(OutboxItemsCompanion(
      attemptCount: Value<int>(row.attemptCount + 1),
      updatedAtMs: Value<int>(_now()),
    ));
  }

  /// Retries a failed row. Explicit user action; clears the error so the UI
  /// stops showing it immediately.
  Future<void> retry(String mediaId) => (_db.update(_db.outboxItems)
            ..where(($OutboxItemsTable t) => t.mediaId.equals(mediaId)))
          .write(OutboxItemsCompanion(
        state: const Value<String>(OutboxState.pending),
        lastError: const Value<String?>(null),
        updatedAtMs: Value<int>(_now()),
      ));

  /// Removes the row. Called ONLY after the Firestore metadata is confirmed —
  /// deleting it earlier is what would lose an upload.
  Future<void> remove(String mediaId) => (_db.delete(_db.outboxItems)
        ..where(($OutboxItemsTable t) => t.mediaId.equals(mediaId)))
      .go();

  /// True when a newer generation exists for this row's supersession key.
  /// Checked immediately before the metadata commit, which is what stops a
  /// stale upload from ever becoming the live asset.
  Future<bool> isSuperseded(OutboxItem item) async {
    if (item.supersessionKey == null) return false;
    final List<OutboxItem> siblings = await (_db.select(_db.outboxItems)
          ..where(($OutboxItemsTable t) =>
              t.supersessionKey.equals(item.supersessionKey!)))
        .get();
    if (item.state == OutboxState.superseded) return true;
    return siblings.any((OutboxItem s) => s.generation > item.generation);
  }
}
