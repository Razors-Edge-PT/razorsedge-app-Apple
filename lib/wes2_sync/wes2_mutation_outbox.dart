/// Durable write-ahead log for WES2 workout edits, backed by Drift/SQLite.
///
/// ── Why a write-ahead log and not a retry-on-catch ──────────────────────────
/// The obvious fix for a swallowed error is to create a retry entry inside the
/// `catch`. That still loses data: the process can die between the server
/// refusing the write and the entry being created, and nothing records that the
/// athlete ever typed anything. So the row is written FIRST, and the network
/// attempt is a retry of something that is already safe.
///
/// ── Why not the whole workout ───────────────────────────────────────────────
/// `Wes2LocalStore.enqueueOfflineSave` was declared as a whole-day snapshot and
/// left unimplemented. Replaying a snapshot would overwrite a coach's edit, a
/// second device, or a later change with whatever this phone happened to hold —
/// so this stores OPERATIONS instead, and each one is replayed through the
/// existing surgical repository transaction that preserves everything it does
/// not name.
///
/// ── Why the id is the coalescing key ────────────────────────────────────────
/// `120 → 125 → 130` on one field is one intent, not three. The id is
/// deterministic for coalescable kinds, so the third edit REPLACES the row and
/// an older in-flight attempt can never restore 120. Operations whose
/// repetition means something — removing a set, replacing an exercise — carry a
/// unique id and are never merged.
///
/// ── Why files, not Isar ─────────────────────────────────────────────────────
/// The two other durable queues in this app (`media_outbox.dart`,
/// `set_video_store.dart`) are Drift/SQLite in application support, with the
/// same `open()` / `memory()` split. Following them keeps the conventions and
/// the test story identical, and leaves the Isar schema — which holds the WES2
/// draft — untouched.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'wes2_mutation.dart';

part 'wes2_mutation_outbox.g.dart';

@DataClassName('Wes2MutationRow')
class Wes2Mutations extends Table {
  /// Coalescing identity. See the library comment.
  TextColumn get id => text()();

  /// Global application order. Assigned at enqueue and re-assigned when a row
  /// is coalesced, so the newest intent for a field is applied last.
  IntColumn get seq => integer()();

  /// The authenticated account that made the edit. Every claim filters on it,
  /// so a second account signing in on this device never replays the first
  /// account's queued work under its own credentials.
  TextColumn get actorUid => text()();

  /// The athlete whose workout document is written. Differs from [actorUid] in
  /// coach mode.
  TextColumn get athleteUid => text()();

  TextColumn get dateKey => text()();
  TextColumn get kind => text()();
  TextColumn get exerciseId => text().withDefault(const Constant(''))();
  IntColumn get setIndex => integer().nullable()();
  TextColumn get payloadJson => text()();

  TextColumn get state =>
      text().withDefault(const Constant(Wes2MutationState.pending))();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();

  /// Earliest time a pass may attempt this row again. Backoff after a
  /// transient failure, so a phone with no signal is not asked every second.
  IntColumn get nextAttemptAtMs => integer().withDefault(const Constant(0))();

  TextColumn get lastError => text().nullable()();

  IntColumn get createdAtMs => integer()();
  IntColumn get updatedAtMs => integer()();

  @override
  Set<Column> get primaryKey => <Column>{id};
}

@DriftDatabase(tables: <Type>[Wes2Mutations])
class Wes2MutationDatabase extends _$Wes2MutationDatabase {
  Wes2MutationDatabase(super.e);

  /// Opens in application support — backed up, and not swept like a cache.
  /// A queued lift must still be there after a week in a bag.
  static Future<Wes2MutationDatabase> open() async {
    final Directory dir = await getApplicationSupportDirectory();
    final File file = File(p.join(dir.path, 'goodlift_wes2_outbox.sqlite'));
    return Wes2MutationDatabase(NativeDatabase(file));
  }

  /// In-memory instance for tests.
  static Wes2MutationDatabase memory() =>
      Wes2MutationDatabase(NativeDatabase.memory());

  @override
  int get schemaVersion => 1;
}

/// All durable reads and writes for queued workout edits.
///
/// Owns the record of intent and nothing else. Deciding what to do with a row
/// is `Wes2SyncEngine`'s job.
class Wes2MutationOutbox {
  Wes2MutationOutbox(this._db, {int Function()? nowMs})
      : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Wes2MutationDatabase _db;
  final int Function() _nowMs;

  Wes2MutationDatabase get database => _db;

  Future<void> close() => _db.close();

  /// Writes [m] durably, superseding anything it invalidates, and returns the
  /// stored row.
  ///
  /// The supersession and the insert share ONE transaction, so there is never a
  /// moment where a removed set's queued edit and the removal are both live.
  Future<Wes2MutationRow> enqueue(Wes2Mutation m) {
    return _db.transaction(() async {
      await _supersedeFor(m);

      final int now = _nowMs();
      // A coalesced row moves to the BACK of the queue. That is deliberate: the
      // newest value for a field must be applied after everything the athlete
      // did before it, and re-using the original position could apply a fresh
      // value before a structural change that was queued in between.
      final int seq = await _nextSeq();

      final Wes2MutationRow? existing = await byId(m.id);
      await _db.into(_db.wes2Mutations).insert(
            Wes2MutationsCompanion.insert(
              id: m.id,
              seq: seq,
              actorUid: m.actorUid,
              athleteUid: m.athleteUid,
              dateKey: m.dateKey,
              kind: m.kind,
              exerciseId: Value<String>(m.exerciseId),
              setIndex: Value<int?>(m.setIndex),
              payloadJson: m.payloadJson,
              // A replaced row is fresh intent: its backoff and its error from
              // the previous value must not be inherited, or a field that
              // failed once would sit out the athlete's next three edits.
              state: const Value<String>(Wes2MutationState.pending),
              attemptCount: const Value<int>(0),
              nextAttemptAtMs: const Value<int>(0),
              lastError: const Value<String?>(null),
              createdAtMs: existing?.createdAtMs ?? now,
              updatedAtMs: now,
            ),
            mode: InsertMode.insertOrReplace,
          );
      return (await byId(m.id))!;
    });
  }

  /// Drops pending work that [m] makes meaningless or dangerous, and rewrites
  /// the set indices that [m] shifts.
  ///
  /// This is what stops a queued weight from resurrecting a removed set, and
  /// what stops a queued edit landing on the set that slid into a gap.
  Future<void> _supersedeFor(Wes2Mutation m) async {
    switch (m.kind) {
      case Wes2MutationKind.removeSet:
        final int removed = m.setIndex ?? -1;
        if (removed < 0) return;
        // Anything queued for the set being removed is void.
        await (_db.delete(_db.wes2Mutations)
              ..where((Wes2Mutations t) =>
                  t.actorUid.equals(m.actorUid) &
                  t.athleteUid.equals(m.athleteUid) &
                  t.dateKey.equals(m.dateKey) &
                  t.exerciseId.equals(m.exerciseId) &
                  t.setIndex.equals(removed)))
            .go();
        // The repository compacts set indices, so queued work for later sets
        // now describes a position one lower. Rewriting the stored index — and
        // the id, which embeds it — keeps each edit on the set it was made on.
        final List<Wes2MutationRow> later = await (_db.select(_db.wes2Mutations)
              ..where((Wes2Mutations t) =>
                  t.actorUid.equals(m.actorUid) &
                  t.athleteUid.equals(m.athleteUid) &
                  t.dateKey.equals(m.dateKey) &
                  t.exerciseId.equals(m.exerciseId) &
                  t.setIndex.isBiggerThanValue(removed))
              ..orderBy(<OrderingTerm Function(Wes2Mutations)>[
                (Wes2Mutations t) => OrderingTerm(expression: t.setIndex),
              ]))
            .get();
        for (final Wes2MutationRow row in later) {
          final int from = row.setIndex!;
          final String newId = row.id.replaceFirst('|$from|', '|${from - 1}|');
          await (_db.delete(_db.wes2Mutations)
                ..where((Wes2Mutations t) => t.id.equals(row.id)))
              .go();
          await _db.into(_db.wes2Mutations).insert(
                row.copyWith(
                  id: newId,
                  setIndex: Value<int?>(from - 1),
                  updatedAtMs: _nowMs(),
                ),
                mode: InsertMode.insertOrReplace,
              );
        }
        return;

      case Wes2MutationKind.deleteExercise:
      case Wes2MutationKind.replaceExercise:
        // The exercise is going away (or being emptied). Every queued edit for
        // it would either fail or recreate it.
        await (_db.delete(_db.wes2Mutations)
              ..where((Wes2Mutations t) =>
                  t.actorUid.equals(m.actorUid) &
                  t.athleteUid.equals(m.athleteUid) &
                  t.dateKey.equals(m.dateKey) &
                  t.exerciseId.equals(m.exerciseId)))
            .go();
        return;

      case Wes2MutationKind.deleteAllForDay:
      case Wes2MutationKind.templateReplaceAll:
        // The whole day is being replaced. Nothing queued for it survives.
        await (_db.delete(_db.wes2Mutations)
              ..where((Wes2Mutations t) =>
                  t.actorUid.equals(m.actorUid) &
                  t.athleteUid.equals(m.athleteUid) &
                  t.dateKey.equals(m.dateKey)))
            .go();
        return;

      default:
        return;
    }
  }

  Future<int> _nextSeq() async {
    final Expression<int> maxSeq = _db.wes2Mutations.seq.max();
    final int? current = await (_db.selectOnly(_db.wes2Mutations)
          ..addColumns(<Expression<Object>>[maxSeq]))
        .map((TypedResult r) => r.read(maxSeq))
        .getSingleOrNull();
    return (current ?? 0) + 1;
  }

  Future<Wes2MutationRow?> byId(String id) => (_db.select(_db.wes2Mutations)
        ..where((Wes2Mutations t) => t.id.equals(id)))
      .getSingleOrNull();

  /// Rows [actorUid] may attempt now, oldest intent first.
  ///
  /// Rows belonging to another account simply wait — they are claimed again the
  /// next time their owner signs in, which is what a durable queue should do.
  /// Blocked rows are excluded: they need an auth or rules change, not another
  /// attempt in this pass.
  Future<List<Wes2MutationRow>> claimable({
    required String actorUid,
    int limit = 50,
  }) =>
      (_db.select(_db.wes2Mutations)
            ..where((Wes2Mutations t) =>
                t.actorUid.equals(actorUid) &
                t.state.isNotValue(Wes2MutationState.blocked) &
                t.nextAttemptAtMs.isSmallerOrEqualValue(_nowMs()))
            ..orderBy(<OrderingTerm Function(Wes2Mutations)>[
              (Wes2Mutations t) => OrderingTerm(expression: t.seq),
            ])
            ..limit(limit))
          .get();

  /// Everything still owed for one day, in application order. This is what the
  /// screen overlays on the server load so unsynced intent stays visible.
  Future<List<Wes2MutationRow>> pendingForDay({
    required String actorUid,
    required String athleteUid,
    required String dateKey,
  }) =>
      (_db.select(_db.wes2Mutations)
            ..where((Wes2Mutations t) =>
                t.actorUid.equals(actorUid) &
                t.athleteUid.equals(athleteUid) &
                t.dateKey.equals(dateKey))
            ..orderBy(<OrderingTerm Function(Wes2Mutations)>[
              (Wes2Mutations t) => OrderingTerm(expression: t.seq),
            ]))
          .get();

  /// How much work [actorUid] still has, including blocked rows so the UI can
  /// say something is wrong rather than silently showing nothing.
  Future<int> countFor(String actorUid) async {
    final List<Wes2MutationRow> rows = await (_db.select(_db.wes2Mutations)
          ..where((Wes2Mutations t) => t.actorUid.equals(actorUid)))
        .get();
    return rows.length;
  }

  Future<int> blockedCountFor(String actorUid) async {
    final List<Wes2MutationRow> rows = await (_db.select(_db.wes2Mutations)
          ..where((Wes2Mutations t) =>
              t.actorUid.equals(actorUid) &
              t.state.equals(Wes2MutationState.blocked)))
        .get();
    return rows.length;
  }

  /// Total rows for every account. Used to decide whether the periodic pass
  /// still has anything to do at all.
  Future<int> totalCount() async =>
      (await _db.select(_db.wes2Mutations).get()).length;

  Future<void> markInFlight(String id) => (_db.update(_db.wes2Mutations)
            ..where((Wes2Mutations t) => t.id.equals(id)))
          .write(Wes2MutationsCompanion(
        state: const Value<String>(Wes2MutationState.inFlight),
        updatedAtMs: Value<int>(_nowMs()),
      ));

  /// A transient failure — no signal, a timeout, the server briefly refusing.
  /// The row stays pending and waits out [backoff]. The athlete's value is
  /// untouched.
  Future<void> markTransientFailure(
    String id,
    String error,
    Duration backoff,
  ) async {
    final Wes2MutationRow? row = await byId(id);
    if (row == null) return;
    await (_db.update(_db.wes2Mutations)
          ..where((Wes2Mutations t) => t.id.equals(id)))
        .write(Wes2MutationsCompanion(
      state: const Value<String>(Wes2MutationState.pending),
      attemptCount: Value<int>(row.attemptCount + 1),
      nextAttemptAtMs: Value<int>(_nowMs() + backoff.inMilliseconds),
      lastError: Value<String?>(error),
      updatedAtMs: Value<int>(_nowMs()),
    ));
  }

  /// Rejected for a reason another attempt cannot fix — denied by rules, not
  /// authenticated, malformed. The row is KEPT: this is the athlete's data, and
  /// a rules or sign-in change can make it writable later.
  Future<void> markBlocked(String id, String error) async {
    final Wes2MutationRow? row = await byId(id);
    if (row == null) return;
    await (_db.update(_db.wes2Mutations)
          ..where((Wes2Mutations t) => t.id.equals(id)))
        .write(Wes2MutationsCompanion(
      state: const Value<String>(Wes2MutationState.blocked),
      attemptCount: Value<int>(row.attemptCount + 1),
      lastError: Value<String?>(error),
      updatedAtMs: Value<int>(_nowMs()),
    ));
  }

  /// Returns blocked rows to the queue. Called when the auth situation changes
  /// or the athlete asks for a retry — never automatically in a loop.
  Future<void> unblock({required String actorUid}) =>
      (_db.update(_db.wes2Mutations)
            ..where((Wes2Mutations t) =>
                t.actorUid.equals(actorUid) &
                t.state.equals(Wes2MutationState.blocked)))
          .write(Wes2MutationsCompanion(
        state: const Value<String>(Wes2MutationState.pending),
        attemptCount: const Value<int>(0),
        nextAttemptAtMs: const Value<int>(0),
        updatedAtMs: Value<int>(_nowMs()),
      ));

  /// Clears a backoff so the next pass attempts everything immediately. Used
  /// when something proves the network is back (a successful server load).
  Future<void> clearBackoff({required String actorUid}) =>
      (_db.update(_db.wes2Mutations)
            ..where((Wes2Mutations t) =>
                t.actorUid.equals(actorUid) &
                t.state.isNotValue(Wes2MutationState.blocked)))
          .write(Wes2MutationsCompanion(
        nextAttemptAtMs: const Value<int>(0),
        updatedAtMs: Value<int>(_nowMs()),
      ));

  /// Removes the row. Called ONLY after the server write is confirmed —
  /// deleting it any earlier is exactly how the data was being lost.
  Future<void> remove(String id) => (_db.delete(_db.wes2Mutations)
        ..where((Wes2Mutations t) => t.id.equals(id)))
      .go();
}
