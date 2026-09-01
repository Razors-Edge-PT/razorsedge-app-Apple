/// Applies durably-queued WES2 edits to Firestore, and keeps retrying until
/// they land.
///
/// ── The guarantee ───────────────────────────────────────────────────────────
/// A row is removed ONLY after the server write returns successfully. Every
/// other outcome leaves it exactly where it was. So the two crash windows both
/// resolve in the athlete's favour:
///
///   A. queued, then the process dies before the request — the row is still
///      here on the next launch and is applied then.
///   B. the request succeeded, then the process died before the row was
///      removed — the row is applied a second time. Every operation this
///      engine performs is therefore idempotent, or carries a guard that makes
///      a second application a no-op (see `removeSet`).
///
/// ── Single flight ───────────────────────────────────────────────────────────
/// Start-up, screen open, resume, a successful load and the periodic tick can
/// all fire within a second of each other. Two passes running together would
/// apply the same row twice concurrently and could reorder edits, so a pass
/// already running simply absorbs the trigger.
///
/// ── Ordering ────────────────────────────────────────────────────────────────
/// Rows are applied in `seq` order and a failure stops the pass for that
/// athlete's day, so a later edit can never be applied over an earlier one that
/// has not landed yet.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../WES2_models.dart';
import '../WES2_repository.dart';
import 'wes2_mutation.dart';
import 'wes2_mutation_outbox.dart';

/// What one pass did. Returned so triggers and tests can assert without
/// reaching into private state.
@immutable
class Wes2SyncPassResult {
  const Wes2SyncPassResult({
    this.applied = 0,
    this.deferred = 0,
    this.blocked = 0,
    this.skipped = false,
  });

  /// Rows confirmed by the server and removed.
  final int applied;

  /// Rows left queued after a transient failure.
  final int deferred;

  /// Rows parked because retrying cannot fix them on its own.
  final int blocked;

  /// True when a pass was already running, or there was nobody to run as.
  final bool skipped;

  bool get didWork => applied > 0;
}

/// Firestore error codes that mean "try again later", not "this will never
/// work". Anything not listed is treated as permanent and parked rather than
/// retried in a tight loop — but is still never deleted.
const Set<String> kWes2TransientCodes = <String>{
  'unavailable',
  'deadline-exceeded',
  'aborted',
  'internal',
  'resource-exhausted',
  'cancelled',
  'unknown',
  'network-request-failed',
  'failed-precondition',
};

/// Codes that mean the write was refused for who the caller is, or for what the
/// data looks like. Kept, parked, and retried only when something changes.
const Set<String> kWes2PermanentCodes = <String>{
  'permission-denied',
  'unauthenticated',
  'invalid-argument',
  'not-found',
  'already-exists',
  'out-of-range',
  'data-loss',
  'unimplemented',
};

typedef Wes2ConfirmedCallback = void Function(Wes2MutationRow row);

class Wes2SyncEngine {
  Wes2SyncEngine({
    required Wes2MutationOutbox outbox,
    required Wes2Repository repository,
    required String? Function() currentActorUid,
    Wes2ConfirmedCallback? onConfirmed,
    Duration periodicInterval = const Duration(seconds: 30),
    Duration baseBackoff = const Duration(seconds: 4),
    Duration maxBackoff = const Duration(minutes: 5),
    bool autoStartTimer = true,
    bool autoProcessOnSubmit = true,
  })  : _outbox = outbox,
        _repository = repository,
        _currentActorUid = currentActorUid,
        _onConfirmed = onConfirmed,
        _periodicInterval = periodicInterval,
        _baseBackoff = baseBackoff,
        _maxBackoff = maxBackoff,
        _autoStartTimer = autoStartTimer,
        _autoProcessOnSubmit = autoProcessOnSubmit;

  final Wes2MutationOutbox _outbox;
  final Wes2Repository _repository;
  final String? Function() _currentActorUid;
  final Wes2ConfirmedCallback? _onConfirmed;
  final Duration _periodicInterval;
  final Duration _baseBackoff;
  final Duration _maxBackoff;
  final bool _autoStartTimer;

  /// Test seam. Production always attempts immediately after queueing; tests
  /// that assert ordering or failure modes drive the passes themselves so a
  /// background attempt cannot race the assertion.
  final bool _autoProcessOnSubmit;

  bool _running = false;
  Timer? _timer;

  /// Broadcast so a screen can show "Saved on device — offline" without
  /// polling. Emits after every pass that changed something.
  final StreamController<Wes2SyncStatus> _status =
      StreamController<Wes2SyncStatus>.broadcast();

  Stream<Wes2SyncStatus> get status => _status.stream;

  /// Rows the server has just accepted.
  ///
  /// A screen listens so post-save side effects still happen when the write
  /// lands minutes later, or on a later launch — the membership qualifying-day
  /// check and set-video reconciliation used to run only inside the save that
  /// succeeded immediately, so an offline day never triggered them at all.
  final StreamController<Wes2MutationRow> _confirmed =
      StreamController<Wes2MutationRow>.broadcast();

  Stream<Wes2MutationRow> get confirmed => _confirmed.stream;

  Wes2MutationOutbox get outbox => _outbox;

  /// True while a pass is applying rows.
  bool get isRunning => _running;

  /// Makes [m] durable, then attempts it.
  ///
  /// The await covers the LOCAL write only. The remote attempt is deliberately
  /// not awaited so typing and navigation stay instant — by the time this
  /// returns the athlete's intent already survives process death, which is the
  /// property that matters.
  Future<void> submit(Wes2Mutation m) async {
    await _outbox.enqueue(m);
    if (_autoProcessOnSubmit) unawaited(process());
  }

  /// Runs one pass for the signed-in account. Absorbed if one is already going.
  Future<Wes2SyncPassResult> process() async {
    if (_running) return const Wes2SyncPassResult(skipped: true);
    final String? actorUid = _currentActorUid();
    if (actorUid == null || actorUid.isEmpty) {
      // Nobody is signed in. Rows wait; being signed out is not a failure and
      // must not consume an attempt.
      return const Wes2SyncPassResult(skipped: true);
    }

    _running = true;
    int applied = 0;
    int deferred = 0;
    int blocked = 0;
    try {
      final List<Wes2MutationRow> rows =
          await _outbox.claimable(actorUid: actorUid);
      // A day whose earlier edit could not land is left alone for the rest of
      // the pass, so nothing is ever applied out of order.
      final Set<String> stalledScopes = <String>{};

      for (final Wes2MutationRow row in rows) {
        final String scope = '${row.athleteUid}|${row.dateKey}';
        if (stalledScopes.contains(scope)) continue;

        await _outbox.markInFlight(row.id);
        try {
          await _apply(row);
          // Confirmed. Only now may the durable record go.
          await _outbox.remove(row.id);
          applied++;
          _onConfirmed?.call(row);
          if (!_confirmed.isClosed) _confirmed.add(row);
        } on FormatException catch (e) {
          // A payload we cannot decode will never become decodable. Retrying it
          // forever would wedge the queue for that day.
          await _outbox.markBlocked(row.id, 'malformed payload: $e');
          blocked++;
        } catch (e) {
          if (_isTransient(e)) {
            await _outbox.markTransientFailure(
              row.id,
              e.toString(),
              _backoffFor(row.attemptCount),
            );
            deferred++;
            stalledScopes.add(scope);
          } else {
            await _outbox.markBlocked(row.id, e.toString());
            blocked++;
          }
        }
      }
    } finally {
      _running = false;
    }

    final Wes2SyncPassResult result = Wes2SyncPassResult(
      applied: applied,
      deferred: deferred,
      blocked: blocked,
    );
    await _publishStatus(actorUid);
    _syncTimer();
    return result;
  }

  /// Called when something else proves the network is back — a successful day
  /// load, or app resume. Drops every backoff so the queue drains at once
  /// instead of waiting out a timer set while there was no signal.
  Future<Wes2SyncPassResult> processNow() async {
    final String? actorUid = _currentActorUid();
    if (actorUid == null || actorUid.isEmpty) {
      return const Wes2SyncPassResult(skipped: true);
    }
    await _outbox.clearBackoff(actorUid: actorUid);
    return process();
  }

  /// Returns parked rows to the queue and runs a pass. For an explicit retry,
  /// or after the auth/rules situation changes.
  Future<Wes2SyncPassResult> retryBlocked() async {
    final String? actorUid = _currentActorUid();
    if (actorUid == null || actorUid.isEmpty) {
      return const Wes2SyncPassResult(skipped: true);
    }
    await _outbox.unblock(actorUid: actorUid);
    return processNow();
  }

  Future<Wes2SyncStatus> currentStatus() async {
    final String? actorUid = _currentActorUid();
    if (actorUid == null || actorUid.isEmpty) {
      return const Wes2SyncStatus(pending: 0, blocked: 0);
    }
    return Wes2SyncStatus(
      pending: await _outbox.countFor(actorUid),
      blocked: await _outbox.blockedCountFor(actorUid),
    );
  }

  Future<void> _publishStatus(String actorUid) async {
    if (_status.isClosed) return;
    _status.add(Wes2SyncStatus(
      pending: await _outbox.countFor(actorUid),
      blocked: await _outbox.blockedCountFor(actorUid),
    ));
  }

  /// Keeps a bounded periodic pass alive only while there is work.
  ///
  /// This is what makes Scenario 7 work: the athlete turns data back on and
  /// makes no further edit, and the queue still drains. It is also why no
  /// connectivity plugin is needed — a connectivity signal would only be a
  /// hint, and Firestore's own answer is the authority either way.
  void _syncTimer() {
    if (!_autoStartTimer) return;
    unawaited(_outbox.totalCount().then((int total) {
      if (total > 0) {
        _timer ??= Timer.periodic(_periodicInterval, (_) => unawaited(process()));
      } else {
        _timer?.cancel();
        _timer = null;
      }
    }).catchError((Object _) {}));
  }

  /// Starts the periodic pass if anything is already queued from a previous
  /// launch. Call once after the outbox opens.
  Future<void> start() async {
    _syncTimer();
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _status.close();
    await _confirmed.close();
  }

  Duration _backoffFor(int attemptCount) {
    final int factor = attemptCount < 0 ? 0 : attemptCount;
    final int ms = _baseBackoff.inMilliseconds * (1 << (factor > 6 ? 6 : factor));
    return ms > _maxBackoff.inMilliseconds ? _maxBackoff : Duration(milliseconds: ms);
  }

  static bool _isTransient(Object e) {
    if (e is FirebaseException) {
      if (kWes2PermanentCodes.contains(e.code)) return false;
      if (kWes2TransientCodes.contains(e.code)) return true;
      // An unrecognised Firebase code is treated as transient: keeping the row
      // moving is safer than parking data we might be able to write.
      return true;
    }
    // A plain network/IO error, a timeout, a platform channel hiccup. All are
    // worth another try; none of them mean the data is unwritable.
    return true;
  }

  // ── Application ───────────────────────────────────────────────────────────

  /// Replays exactly one row through the ordinary surgical repository
  /// operation, so a queued edit preserves every unrelated exercise, set and
  /// field the same way a live edit does.
  Future<void> _apply(Wes2MutationRow row) async {
    final Map<String, dynamic> payload =
        Wes2Mutation.decodePayload(row.payloadJson);
    final String uid = row.athleteUid;
    final DateTime date = wes2DateFromKey(row.dateKey);

    switch (row.kind) {
      case Wes2MutationKind.field:
        final Wes2ExerciseRow? exRow = Wes2Mutation.rowFrom(payload);
        final Wes2FieldKey? key = Wes2Mutation.fieldKeyFrom(payload);
        final int? setIndex = row.setIndex;
        if (exRow == null || key == null || setIndex == null) {
          throw const FormatException('field mutation missing row/key/index');
        }
        // A null value is an explicit clear. saveFieldPatch removes the key,
        // which is exactly the tombstone the athlete asked for.
        await _repository.saveFieldPatch(
          uid: uid,
          date: date,
          row: exRow,
          setIndex: setIndex,
          fieldKey: key,
          value: Wes2Mutation.fieldValueFrom(payload),
        );
        return;

      case Wes2MutationKind.setNote:
        final int? setIndex = row.setIndex;
        if (setIndex == null) {
          throw const FormatException('setNote mutation missing index');
        }
        await _repository.saveExecutionNote(
          uid: uid,
          date: date,
          exerciseId: row.exerciseId,
          setIndex: setIndex,
          note: payload['value'] as String?,
        );
        return;

      case Wes2MutationKind.exerciseNote:
        await _repository.saveExerciseExecutionNote(
          uid: uid,
          date: date,
          exerciseId: row.exerciseId,
          note: payload['value'] as String?,
        );
        return;

      case Wes2MutationKind.markDone:
        final Wes2ExerciseRow? exRow = Wes2Mutation.rowFrom(payload);
        if (exRow == null) {
          throw const FormatException('markDone mutation missing row');
        }
        await _repository.setMarkedDone(
          uid: uid,
          date: date,
          row: exRow,
          isDone: payload['isDone'] == true,
        );
        return;

      case Wes2MutationKind.setCount:
        final Wes2ExerciseRow? exRow = Wes2Mutation.rowFrom(payload);
        final Object? count = payload['setCount'];
        if (exRow == null || count is! num) {
          throw const FormatException('setCount mutation missing row/count');
        }
        // Only ever raises the stored count, so replaying it cannot duplicate
        // a set or corrupt the count.
        await _repository.saveSetCount(
          uid: uid,
          date: date,
          row: exRow,
          setCount: count.toInt(),
        );
        return;

      case Wes2MutationKind.manualExercise:
        final Wes2ExerciseRow? exRow = Wes2Mutation.rowFrom(payload);
        if (exRow == null) {
          throw const FormatException('manualExercise mutation missing row');
        }
        // No-ops when the exerciseId is already present, so a replay cannot
        // duplicate the exercise.
        await _repository.saveManualExercise(uid: uid, date: date, row: exRow);
        return;

      case Wes2MutationKind.setId:
        final Object? setId = payload['setId'];
        final int? setIndex = row.setIndex;
        if (setId is! String || setIndex == null) {
          throw const FormatException('setId mutation missing id/index');
        }
        // Never overwrites an identity that already exists, so a replay leaves
        // an attached proof video pointing at the same performance.
        await _repository.saveSetId(
          uid: uid,
          date: date,
          exerciseId: row.exerciseId,
          setIndex: setIndex,
          setId: setId,
        );
        return;

      case Wes2MutationKind.removeSet:
        final int? setIndex = row.setIndex;
        final Object? expected = payload['expectedSetCountBefore'];
        if (setIndex == null) {
          throw const FormatException('removeSet mutation missing index');
        }
        // The guard is what makes a replay safe: after a successful removal the
        // stored count no longer matches, and the repository does nothing
        // rather than deleting the set that moved into the gap.
        await _repository.removeSet(
          uid: uid,
          date: date,
          exerciseId: row.exerciseId,
          setIndex: setIndex,
          expectedSetCountBefore: expected is num ? expected.toInt() : null,
        );
        return;

      case Wes2MutationKind.deleteExercise:
        // Removing an exercise that is already gone is a no-op.
        await _repository.deleteExercise(
          uid: uid,
          date: date,
          exerciseId: row.exerciseId,
        );
        return;

      case Wes2MutationKind.replaceExercise:
        final Object? newId = payload['newExerciseId'];
        final Object? newName = payload['newName'];
        if (newId is! String || newName is! String) {
          throw const FormatException('replaceExercise mutation missing target');
        }
        // A replay finds the old id absent and does nothing.
        await _repository.replaceExercise(
          uid: uid,
          date: date,
          oldExerciseId: row.exerciseId,
          newExerciseId: newId,
          newName: newName,
        );
        return;

      case Wes2MutationKind.moveCircuit:
        final Object? ci = payload['circuitIndex'];
        if (ci is! num) {
          throw const FormatException('moveCircuit mutation missing index');
        }
        await _repository.moveExerciseToCircuit(
          uid: uid,
          date: date,
          exerciseId: row.exerciseId,
          targetCircuitIndex: ci.toInt(),
        );
        return;

      case Wes2MutationKind.deleteAllForDay:
        await _repository.deleteAllExercisesForDay(uid: uid, date: date);
        return;

      case Wes2MutationKind.templateReplaceAll:
        final Object? raw = payload['rows'];
        if (raw is! List) {
          throw const FormatException('templateReplaceAll missing rows');
        }
        await _repository.replaceAllWithTemplateRows(
          uid: uid,
          date: date,
          rows: raw
              .whereType<Map<String, dynamic>>()
              .map(Wes2ExerciseRow.fromJson)
              .toList(),
        );
        return;

      default:
        throw FormatException('unknown mutation kind ${row.kind}');
    }
  }
}

/// How much work is still owed, for an optional unobtrusive indicator.
@immutable
class Wes2SyncStatus {
  const Wes2SyncStatus({required this.pending, required this.blocked});

  /// Rows still queued, including blocked ones.
  final int pending;

  /// Rows parked awaiting an auth or rules change.
  final int blocked;

  bool get isIdle => pending == 0;
  bool get hasIssue => blocked > 0;

  @override
  bool operator ==(Object other) =>
      other is Wes2SyncStatus &&
      other.pending == pending &&
      other.blocked == blocked;

  @override
  int get hashCode => Object.hash(pending, blocked);

  @override
  String toString() => 'Wes2SyncStatus(pending: $pending, blocked: $blocked)';
}
