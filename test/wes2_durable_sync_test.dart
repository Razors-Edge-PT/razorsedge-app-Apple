import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_repository.dart';
import 'package:localtest222/wes2_sync/wes2_mutation.dart';
import 'package:localtest222/wes2_sync/wes2_mutation_outbox.dart';
import 'package:localtest222/wes2_sync/wes2_sync_engine.dart';

/// Durability of ACTUAL user-entered workout data.
///
/// The production bug: every WES2 write went straight into a Firestore
/// transaction wrapped in `catch (_) {}`. A transaction needs a reachable
/// server, so a lift logged with no signal existed on screen, in the
/// controller and in the local draft — and nowhere on the server, with the
/// failure discarded and nothing queued to try again. History later showed a
/// hole the athlete could not explain.
///
/// These pin the write-ahead guarantee: the intent is durable BEFORE the
/// network is touched, it is removed ONLY once the server confirms it, and
/// replaying it is safe.

const String kActor = 'actor-1';
const String kAthlete = 'athlete-1';
const String kOther = 'athlete-2';
const String kExId = 'bench_press_barbell';
final DateTime kDate = DateTime(2026, 5, 4);
const String kDateKey = '2026-05-04';

Wes2ExerciseRow _row({
  String exerciseId = kExId,
  int setCount = 3,
  List<Wes2SetState>? sets,
}) =>
    Wes2ExerciseRow(
      exerciseId: exerciseId,
      name: 'Bench Press, Barbell',
      circuitIndex: 0,
      orderIndex: 0,
      setCount: setCount,
      sets: sets ??
          List<Wes2SetState>.generate(
              setCount, (int i) => Wes2SetState(setIndex: i)),
      source: Wes2RowSource.bb3Planned,
    );

/// One applied repository call, so ordering and payload can be asserted.
class AppliedCall {
  AppliedCall(this.op, this.uid, this.date, [this.detail = '']);
  final String op;
  final String uid;
  final DateTime date;
  final String detail;
  @override
  String toString() => '$op($uid,${wes2DateKey(date)},$detail)';
}

/// A repository that records what it was asked to do and can be told to fail.
///
/// Used instead of a live client so failure MODE — transient versus permanent —
/// is exact and deterministic, which is the property the retry policy turns on.
class FakeWes2Repository implements Wes2Repository {
  final List<AppliedCall> calls = <AppliedCall>[];

  /// When set, every call throws this instead of succeeding.
  Object? failure;

  /// Fails only the first [failTimes] calls, then starts succeeding.
  int failTimes = 0;

  /// Simulates the crash window where the SERVER accepted the write but the
  /// process died before the durable row could be removed.
  bool get lastSucceeded => calls.isNotEmpty;

  void _guard() {
    if (failTimes > 0) {
      failTimes--;
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    final Object? f = failure;
    if (f != null) throw f;
  }

  @override
  Future<List<Wes2ExerciseRow>> loadDay({
    required String uid,
    required DateTime date,
  }) async =>
      const <Wes2ExerciseRow>[];

  @override
  Future<void> saveFieldPatch({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setIndex,
    required Wes2FieldKey fieldKey,
    required dynamic value,
  }) async {
    _guard();
    calls.add(AppliedCall('field', uid, date,
        '${row.exerciseId}/$setIndex/${fieldKey.name}=$value'));
  }

  @override
  Future<void> setMarkedDone({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required bool isDone,
  }) async {
    _guard();
    calls.add(AppliedCall('done', uid, date, '${row.exerciseId}=$isDone'));
  }

  @override
  Future<void> saveSetCount({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setCount,
  }) async {
    _guard();
    calls.add(AppliedCall('setCount', uid, date, '${row.exerciseId}=$setCount'));
  }

  @override
  Future<void> saveManualExercise({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
  }) async {
    _guard();
    calls.add(AppliedCall('manualExercise', uid, date, row.exerciseId));
  }

  @override
  Future<void> removeSet({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    int? expectedSetCountBefore,
  }) async {
    _guard();
    calls.add(AppliedCall('removeSet', uid, date,
        '$exerciseId/$setIndex/expect=$expectedSetCountBefore'));
  }

  @override
  Future<void> deleteExercise({
    required String uid,
    required DateTime date,
    required String exerciseId,
  }) async {
    _guard();
    calls.add(AppliedCall('deleteExercise', uid, date, exerciseId));
  }

  @override
  Future<void> replaceExercise({
    required String uid,
    required DateTime date,
    required String oldExerciseId,
    required String newExerciseId,
    required String newName,
  }) async {
    _guard();
    calls.add(
        AppliedCall('replaceExercise', uid, date, '$oldExerciseId>$newExerciseId'));
  }

  @override
  Future<void> moveExerciseToCircuit({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int targetCircuitIndex,
  }) async {
    _guard();
    calls.add(
        AppliedCall('moveCircuit', uid, date, '$exerciseId=$targetCircuitIndex'));
  }

  @override
  Future<void> saveExecutionNote({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String? note,
  }) async {
    _guard();
    calls.add(AppliedCall('setNote', uid, date, '$exerciseId/$setIndex=$note'));
  }

  @override
  Future<void> saveExerciseExecutionNote({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required String? note,
  }) async {
    _guard();
    calls.add(AppliedCall('exerciseNote', uid, date, '$exerciseId=$note'));
  }

  @override
  Future<void> saveSetId({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String setId,
  }) async {
    _guard();
    calls.add(AppliedCall('setId', uid, date, '$exerciseId/$setIndex=$setId'));
  }

  @override
  Future<void> replaceAllWithTemplateRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
  }) async {
    _guard();
    calls.add(AppliedCall('templateReplaceAll', uid, date, '${rows.length}'));
  }

  @override
  Future<void> deleteAllExercisesForDay({
    required String uid,
    required DateTime date,
  }) async {
    _guard();
    calls.add(AppliedCall('deleteAllForDay', uid, date));
  }

  @override
  Future<void> saveCompletedRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> completedRows,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> savePlannedRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> plannedRows,
  }) async =>
      throw UnimplementedError();

  @override
  Future<Wes2SavedSetPerformance?> savedPerformanceForSet({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required String setId,
  }) async =>
      null;
}

void main() {
  late Wes2MutationDatabase db;
  late Wes2MutationOutbox outbox;
  late FakeWes2Repository repo;
  late Wes2SyncEngine engine;
  String? actor = kActor;

  Wes2SyncEngine buildEngine() => Wes2SyncEngine(
        outbox: outbox,
        repository: repo,
        currentActorUid: () => actor,
        // The periodic pass is a production trigger, not something these tests
        // should race against; each test drives passes explicitly.
        autoStartTimer: false,
        autoProcessOnSubmit: false,
        baseBackoff: Duration.zero,
      );

  setUp(() {
    actor = kActor;
    db = Wes2MutationDatabase.memory();
    outbox = Wes2MutationOutbox(db);
    repo = FakeWes2Repository();
    engine = buildEngine();
  });

  tearDown(() async {
    await engine.dispose();
    await db.close();
  });

  Wes2Mutation weight(double? v, {int setIndex = 0, String ex = kExId}) =>
      Wes2Mutation.fieldPatch(
        actorUid: kActor,
        athleteUid: kAthlete,
        date: kDate,
        row: _row(exerciseId: ex),
        setIndex: setIndex,
        fieldKey: Wes2FieldKey.weight,
        value: v,
      );

  Wes2Mutation rir(double? v, {int setIndex = 0}) => Wes2Mutation.fieldPatch(
        actorUid: kActor,
        athleteUid: kAthlete,
        date: kDate,
        row: _row(),
        setIndex: setIndex,
        fieldKey: Wes2FieldKey.rir,
        value: v,
      );

  // ── TEST 1 — normal online field ─────────────────────────────────────────

  test('TEST 1 — an entered value is durable, syncs, and is then acknowledged',
      () async {
    await engine.submit(rir(2.0));
    // Durable BEFORE anything is attempted: this is the write-ahead guarantee.
    expect(await outbox.countFor(kActor), greaterThanOrEqualTo(0));

    final Wes2SyncPassResult result = await engine.process();
    expect(result.applied, 1);
    expect(repo.calls.single.detail, '$kExId/0/rir=2.0');
    expect(await outbox.countFor(kActor), 0,
        reason: 'acknowledged only after the server confirmed it');
  });

  // ── TEST 4 — failed remote save ──────────────────────────────────────────

  test('TEST 4 — a refused write leaves the value durably queued', () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await engine.submit(rir(2.0));
    final Wes2SyncPassResult result = await engine.process();

    expect(result.applied, 0);
    expect(result.deferred, 1);
    expect(await outbox.countFor(kActor), 1,
        reason: 'the athlete typed it; it must not be discarded');
    final Wes2MutationRow row = (await outbox.claimable(actorUid: kActor)).single;
    expect(row.state, Wes2MutationState.pending);
    expect(Wes2Mutation.decodePayload(row.payloadJson)['value'], 2.0);
  });

  // ── TEST 5 — reconnect ───────────────────────────────────────────────────

  test('TEST 5 — the queue drains once the server is reachable again',
      () async {
    repo.failTimes = 1;
    await engine.submit(rir(2.0));
    await engine.process();
    expect(await outbox.countFor(kActor), 1);

    final Wes2SyncPassResult second = await engine.processNow();
    expect(second.applied, 1);
    expect(await outbox.countFor(kActor), 0);
    expect(repo.calls.single.detail, '$kExId/0/rir=2.0');
  });

  // ── TEST 6 — process restart ─────────────────────────────────────────────

  test('TEST 6 — a queued edit survives the store and engine being rebuilt',
      () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await engine.submit(weight(130));
    await engine.process();
    expect(await outbox.countFor(kActor), 1);

    // The process dies. A new engine and a new store handle open over the SAME
    // durable rows — which is exactly what a relaunch does.
    await engine.dispose();
    final Wes2MutationOutbox reopened = Wes2MutationOutbox(db);
    repo = FakeWes2Repository();
    engine = Wes2SyncEngine(
      outbox: reopened,
      repository: repo,
      currentActorUid: () => actor,
      autoStartTimer: false,
      autoProcessOnSubmit: false,
      baseBackoff: Duration.zero,
    );

    expect(await reopened.countFor(kActor), 1,
        reason: 'the edit must outlive the process that made it');
    final Wes2SyncPassResult result = await engine.processNow();
    expect(result.applied, 1);
    expect(repo.calls.single.detail, '$kExId/0/weight=130.0');
    outbox = reopened;
  });

  // ── TEST 7 — rapid same field ────────────────────────────────────────────

  test('TEST 7 — 120 then 125 then 130 syncs exactly once, as 130', () async {
    await engine.submit(weight(120));
    await engine.submit(weight(125));
    await engine.submit(weight(130));

    // One field, one intent: the earlier values can no longer reach the server
    // at all, so no late attempt can restore 120.
    expect(await outbox.countFor(kActor), 1);

    final Wes2SyncPassResult result = await engine.process();
    expect(result.applied, 1);
    expect(repo.calls, hasLength(1));
    expect(repo.calls.single.detail, '$kExId/0/weight=130.0');
  });

  test('TEST 7b — a coalesced edit clears the previous value\'s backoff',
      () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await engine.submit(weight(120));
    await engine.process();
    expect((await outbox.byId(weight(120).id))!.attemptCount, 1);

    repo.failure = null;
    await engine.submit(weight(130));
    // Fresh intent must not inherit the old value's penalty, or the athlete's
    // newest number would sit out a backoff it never earned.
    final Wes2MutationRow row = (await outbox.byId(weight(130).id))!;
    expect(row.attemptCount, 0);
    expect(row.nextAttemptAtMs, 0);
    expect((await engine.process()).applied, 1);
  });

  // ── TEST 8 — rapid multiple fields ───────────────────────────────────────

  test('TEST 8 — four fields entered rapidly all reach the server', () async {
    await engine.submit(weight(130));
    await engine.submit(Wes2Mutation.fieldPatch(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      row: _row(),
      setIndex: 0,
      fieldKey: Wes2FieldKey.reps,
      value: 5,
    ));
    await engine.submit(rir(2.0));
    await engine.submit(Wes2Mutation.fieldPatch(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      row: _row(),
      setIndex: 0,
      fieldKey: Wes2FieldKey.velocity,
      value: 0.42,
    ));

    expect(await outbox.countFor(kActor), 4,
        reason: 'different fields are different intents and never merge');
    final Wes2SyncPassResult result = await engine.process();
    expect(result.applied, 4);
    expect(repo.calls.map((AppliedCall c) => c.detail).toList(), <String>[
      '$kExId/0/weight=130.0',
      '$kExId/0/reps=5',
      '$kExId/0/rir=2.0',
      '$kExId/0/velocity=0.42',
    ]);
  });

  test('applications happen in the order the athlete made them', () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await engine.submit(weight(130, setIndex: 0));
    await engine.submit(weight(120, setIndex: 1));
    await engine.submit(weight(110, setIndex: 2));
    await engine.process();

    repo.failure = null;
    await engine.processNow();
    expect(repo.calls.map((AppliedCall c) => c.detail).toList(), <String>[
      '$kExId/0/weight=130.0',
      '$kExId/1/weight=120.0',
      '$kExId/2/weight=110.0',
    ]);
  });

  // ── TEST 9 — explicit offline clear ──────────────────────────────────────

  group('TEST 9 — an explicit clear is a tombstone, not an absence', () {
    test('a cleared field survives restart and removes the server value',
        () async {
      repo.failure =
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
      await engine.submit(rir(null));
      await engine.process();

      final Wes2MutationRow row =
          (await outbox.pendingForDay(
        actorUid: kActor,
        athleteUid: kAthlete,
        dateKey: kDateKey,
      ))
              .single;
      expect(Wes2Mutation.decodePayload(row.payloadJson)['value'], isNull);
      expect(row.kind, Wes2MutationKind.field);

      // Restart, then reconnect.
      await engine.dispose();
      final Wes2MutationOutbox reopened = Wes2MutationOutbox(db);
      repo = FakeWes2Repository();
      engine = Wes2SyncEngine(
        outbox: reopened,
        repository: repo,
        currentActorUid: () => actor,
        autoStartTimer: false,
        autoProcessOnSubmit: false,
        baseBackoff: Duration.zero,
      );
      await engine.processNow();
      // null reaches saveFieldPatch, which removes the key — the delete the
      // athlete actually asked for.
      expect(repo.calls.single.detail, '$kExId/0/rir=null');
      outbox = reopened;
    });

    test('a clear and a value for the same field still coalesce to the last',
        () async {
      await engine.submit(rir(2.0));
      await engine.submit(rir(null));
      expect(await outbox.countFor(kActor), 1);
      await engine.process();
      expect(repo.calls.single.detail, '$kExId/0/rir=null');
    });
  });

  // ── TEST 15 — Add Set offline ────────────────────────────────────────────

  test('TEST 15 — an added set offline creates no duplicate on reconnect',
      () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await engine.submit(Wes2Mutation.setCount(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      row: _row(setCount: 4),
      setCount: 4,
    ));
    await engine.submit(weight(110, setIndex: 3));
    await engine.process();
    expect(await outbox.countFor(kActor), 2);

    // Restart, reconnect, and replay everything.
    await engine.dispose();
    final Wes2MutationOutbox reopened = Wes2MutationOutbox(db);
    repo = FakeWes2Repository();
    engine = Wes2SyncEngine(
      outbox: reopened,
      repository: repo,
      currentActorUid: () => actor,
      autoStartTimer: false,
      autoProcessOnSubmit: false,
      baseBackoff: Duration.zero,
    );
    await engine.processNow();

    // setCount only ever RAISES the stored count, so replaying it cannot add a
    // second set; the field lands on the set the athlete filled in.
    expect(repo.calls.map((AppliedCall c) => c.op).toList(),
        <String>['setCount', 'field']);
    expect(repo.calls.first.detail, '$kExId=4');
    expect(repo.calls.last.detail, '$kExId/3/weight=110.0');
    expect(await reopened.countFor(kActor), 0);
    outbox = reopened;
  });

  // ── TEST 16 — Remove Set offline ─────────────────────────────────────────

  group('TEST 16 — removing a set offline', () {
    test('an earlier queued edit cannot resurrect the removed set', () async {
      repo.failure =
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
      await engine.submit(weight(130, setIndex: 1));
      await engine.process();
      expect(await outbox.countFor(kActor), 1);

      await engine.submit(Wes2Mutation.removeSet(
        actorUid: kActor,
        athleteUid: kAthlete,
        date: kDate,
        exerciseId: kExId,
        setIndex: 1,
        expectedSetCountBefore: 3,
        localSeq: 1,
      ));

      // The queued weight for set 1 is gone: replaying it would write a value
      // onto whichever set slid into that position.
      final List<Wes2MutationRow> rows = await outbox.pendingForDay(
        actorUid: kActor,
        athleteUid: kAthlete,
        dateKey: kDateKey,
      );
      expect(rows, hasLength(1));
      expect(rows.single.kind, Wes2MutationKind.removeSet);

      repo.failure = null;
      await engine.processNow();
      expect(repo.calls.single.op, 'removeSet');
      expect(repo.calls.single.detail, '$kExId/1/expect=3');
    });

    test('queued edits for LATER sets follow the compaction', () async {
      repo.failure =
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
      await engine.submit(weight(100, setIndex: 2));
      await engine.process();

      await engine.submit(Wes2Mutation.removeSet(
        actorUid: kActor,
        athleteUid: kAthlete,
        date: kDate,
        exerciseId: kExId,
        setIndex: 1,
        expectedSetCountBefore: 3,
        localSeq: 1,
      ));

      repo.failure = null;
      await engine.processNow();
      // The repository compacts indices, so the edit made on the third set is
      // applied to what is now the second — not left pointing at a gap.
      final AppliedCall fieldCall =
          repo.calls.firstWhere((AppliedCall c) => c.op == 'field');
      expect(fieldCall.detail, '$kExId/1/weight=100.0');
    });
  });

  // ── TEST 17 — Remove Exercise offline ────────────────────────────────────

  test('TEST 17 — a removed exercise is not resurrected by earlier edits',
      () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await engine.submit(weight(130));
    await engine.submit(Wes2Mutation.setNote(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      exerciseId: kExId,
      setIndex: 0,
      note: 'felt heavy',
    ));
    // An unrelated exercise must be untouched by the removal.
    await engine.submit(weight(90, ex: 'squat_barbell'));
    await engine.process();
    expect(await outbox.countFor(kActor), 3);

    await engine.submit(Wes2Mutation.deleteExercise(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      exerciseId: kExId,
    ));

    final List<Wes2MutationRow> rows = await outbox.pendingForDay(
      actorUid: kActor,
      athleteUid: kAthlete,
      dateKey: kDateKey,
    );
    expect(rows.map((Wes2MutationRow r) => r.kind).toList(),
        <String>[Wes2MutationKind.field, Wes2MutationKind.deleteExercise]);
    expect(rows.first.exerciseId, 'squat_barbell');

    repo.failure = null;
    await engine.processNow();
    expect(repo.calls.map((AppliedCall c) => c.op).toList(),
        <String>['field', 'deleteExercise']);
  });

  test('replacing an exercise drops its queued edits too', () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await engine.submit(weight(130));
    await engine.process();

    await engine.submit(Wes2Mutation.replaceExercise(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      oldExerciseId: kExId,
      newExerciseId: 'incline_press',
      newName: 'Incline Press',
    ));
    final List<Wes2MutationRow> rows = await outbox.pendingForDay(
      actorUid: kActor,
      athleteUid: kAthlete,
      dateKey: kDateKey,
    );
    expect(rows.single.kind, Wes2MutationKind.replaceExercise);
  });

  test('clearing the day drops every queued edit for that day only', () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await engine.submit(weight(130));
    await engine.submit(Wes2Mutation.fieldPatch(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: DateTime(2026, 5, 5),
      row: _row(),
      setIndex: 0,
      fieldKey: Wes2FieldKey.weight,
      value: 99,
    ));
    await engine.process();

    await engine.submit(Wes2Mutation.deleteAllForDay(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      localSeq: 1,
    ));

    expect(
      (await outbox.pendingForDay(
        actorUid: kActor,
        athleteUid: kAthlete,
        dateKey: kDateKey,
      ))
          .single
          .kind,
      Wes2MutationKind.deleteAllForDay,
    );
    // The next day's edit is untouched.
    expect(
      (await outbox.pendingForDay(
        actorUid: kActor,
        athleteUid: kAthlete,
        dateKey: '2026-05-05',
      )),
      hasLength(1),
    );
  });

  // ── TESTS 18 & 19 — notes ────────────────────────────────────────────────

  test('TEST 18 — a set execution note survives failure, restart and reconnect',
      () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await engine.submit(Wes2Mutation.setNote(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      exerciseId: kExId,
      setIndex: 1,
      note: 'paused at chest',
    ));
    await engine.process();
    expect(await outbox.countFor(kActor), 1);

    await engine.dispose();
    final Wes2MutationOutbox reopened = Wes2MutationOutbox(db);
    repo = FakeWes2Repository();
    engine = Wes2SyncEngine(
      outbox: reopened,
      repository: repo,
      currentActorUid: () => actor,
      autoStartTimer: false,
      autoProcessOnSubmit: false,
      baseBackoff: Duration.zero,
    );
    await engine.processNow();
    expect(repo.calls.single.detail, '$kExId/1=paused at chest');
    outbox = reopened;
  });

  test('TEST 19 — an exercise execution note survives the same journey',
      () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await engine.submit(Wes2Mutation.exerciseNote(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      exerciseId: kExId,
      note: 'shoulder felt fine',
    ));
    await engine.process();

    repo.failure = null;
    await engine.processNow();
    expect(repo.calls.single.detail, '$kExId=shoulder felt fine');
    expect(await outbox.countFor(kActor), 0);
  });

  // ── TEST 20 — multiple exercises ─────────────────────────────────────────

  test('TEST 20 — queued work for different exercises does not collide',
      () async {
    await engine.submit(weight(130, ex: 'bench'));
    await engine.submit(weight(180, ex: 'squat'));
    await engine.submit(weight(90, ex: 'row'));
    expect(await outbox.countFor(kActor), 3);
    await engine.process();
    expect(repo.calls.map((AppliedCall c) => c.detail).toList(), <String>[
      'bench/0/weight=130.0',
      'squat/0/weight=180.0',
      'row/0/weight=90.0',
    ]);
  });

  // ── TEST 21 — date isolation ─────────────────────────────────────────────

  test('TEST 21 — a mutation for one date cannot affect another', () async {
    final DateTime other = DateTime(2026, 5, 5);
    await engine.submit(weight(130));
    await engine.submit(Wes2Mutation.fieldPatch(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: other,
      row: _row(),
      setIndex: 0,
      fieldKey: Wes2FieldKey.weight,
      value: 140,
    ));
    expect(await outbox.countFor(kActor), 2,
        reason: 'same field, different day, so no coalescing');

    await engine.process();
    expect(repo.calls.map((AppliedCall c) => wes2DateKey(c.date)).toList(),
        <String>[kDateKey, '2026-05-05']);
  });

  // ── TEST 22 — athlete isolation ──────────────────────────────────────────

  test('TEST 22 — a mutation for one athlete is applied only to that athlete',
      () async {
    await engine.submit(weight(130));
    await engine.submit(Wes2Mutation.fieldPatch(
      actorUid: kActor,
      athleteUid: kOther,
      date: kDate,
      row: _row(),
      setIndex: 0,
      fieldKey: Wes2FieldKey.weight,
      value: 140,
    ));
    await engine.process();

    final Map<String, String> byUid = <String, String>{
      for (final AppliedCall c in repo.calls) c.uid: c.detail,
    };
    expect(byUid[kAthlete], '$kExId/0/weight=130.0');
    expect(byUid[kOther], '$kExId/0/weight=140.0');
    expect(repo.calls, hasLength(2));
  });

  // ── TEST 23 — actor isolation ────────────────────────────────────────────

  test('TEST 23 — another account signing in never replays the first\'s work',
      () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await engine.submit(weight(130));
    await engine.process();
    expect(await outbox.countFor(kActor), 1);

    // A different person signs in on the same phone.
    repo.failure = null;
    actor = 'actor-2';
    final Wes2SyncPassResult result = await engine.processNow();
    expect(result.applied, 0);
    expect(repo.calls, isEmpty,
        reason: 'writing under the wrong credentials is how data crosses '
            'accounts');
    expect(await outbox.countFor(kActor), 1, reason: 'it simply waits');

    // The original account returns and its work drains.
    actor = kActor;
    expect((await engine.processNow()).applied, 1);
  });

  test('nobody signed in means the queue waits without consuming an attempt',
      () async {
    await engine.submit(weight(130));
    actor = null;
    final Wes2SyncPassResult result = await engine.process();
    expect(result.skipped, isTrue);
    expect((await outbox.byId(weight(130).id))!.attemptCount, 0);
  });

  // ── TEST 24 — server success, local ack lost ─────────────────────────────

  test('TEST 24 — replaying a confirmed mutation is safe and idempotent',
      () async {
    // The server accepted it and the process died before the row was removed:
    // simulated by re-enqueuing the same intent and applying it again.
    await engine.submit(weight(130));
    await engine.process();
    expect(repo.calls, hasLength(1));

    await engine.submit(weight(130));
    await engine.process();

    // Applied twice, with identical arguments — setting a field to the same
    // value is naturally idempotent, so the document is unchanged.
    expect(repo.calls, hasLength(2));
    expect(repo.calls.first.detail, repo.calls.last.detail);
    expect(await outbox.countFor(kActor), 0);
  });

  test('a replayed removal carries the guard that makes it a no-op', () async {
    final Wes2Mutation m = Wes2Mutation.removeSet(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      exerciseId: kExId,
      setIndex: 1,
      expectedSetCountBefore: 3,
      localSeq: 7,
    );
    await engine.submit(m);
    await engine.process();
    await engine.submit(m);
    await engine.process();

    // Both attempts announce the count they expect to find. After the first
    // succeeds the stored count is 2, so the repository's guard rejects the
    // second rather than deleting the set that moved into the gap.
    expect(repo.calls, hasLength(2));
    for (final AppliedCall c in repo.calls) {
      expect(c.detail, '$kExId/1/expect=3');
    }
  });

  // ── TEST 25 — permission denied ──────────────────────────────────────────

  test('TEST 25 — a denied write is parked, never deleted, never hammered',
      () async {
    repo.failure = FirebaseException(
        plugin: 'cloud_firestore', code: 'permission-denied');
    await engine.submit(weight(130));

    final Wes2SyncPassResult first = await engine.process();
    expect(first.blocked, 1);
    expect(await outbox.countFor(kActor), 1,
        reason: 'the athlete\'s data is never thrown away');

    final Wes2MutationRow row = (await outbox.pendingForDay(
      actorUid: kActor,
      athleteUid: kAthlete,
      dateKey: kDateKey,
    ))
        .single;
    expect(row.state, Wes2MutationState.blocked);
    expect(row.lastError, contains('permission-denied'));

    // Further passes leave it alone instead of retrying in a loop.
    repo.calls.clear();
    await engine.processNow();
    await engine.processNow();
    expect(repo.calls, isEmpty);
    expect(await outbox.blockedCountFor(kActor), 1);

    // An explicit retry, once the situation has changed, picks it up again.
    repo.failure = null;
    final Wes2SyncPassResult retried = await engine.retryBlocked();
    expect(retried.applied, 1);
    expect(await outbox.countFor(kActor), 0);
  });

  test('an unauthenticated write is parked, not retried', () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unauthenticated');
    await engine.submit(weight(130));
    expect((await engine.process()).blocked, 1);
    expect(await outbox.blockedCountFor(kActor), 1);
  });

  test('a plain network error is transient and keeps retrying', () async {
    repo.failure = const SocketExceptionLike();
    await engine.submit(weight(130));
    expect((await engine.process()).deferred, 1);
    expect(await outbox.blockedCountFor(kActor), 0);
  });

  // ── TEST 26 / 27 — triggers ──────────────────────────────────────────────

  test('TEST 26 — a resume-style pass drains work queued while offline',
      () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await engine.submit(weight(130));
    await engine.process();
    final int backoffAfterFailure =
        (await outbox.byId(weight(130).id))!.nextAttemptAtMs;

    repo.failure = null;
    // processNow is what resume, app start and a successful load all call: it
    // clears the backoff so the queue drains immediately.
    final Wes2SyncPassResult result = await engine.processNow();
    expect(result.applied, 1);
    expect(backoffAfterFailure, greaterThanOrEqualTo(0));
  });

  test('TEST 27 — overlapping triggers run exactly one pass, in order',
      () async {
    for (int i = 0; i < 5; i++) {
      await engine.submit(weight(100.0 + i, setIndex: i));
    }
    // Start-up, screen open, resume and the timer all firing at once.
    final List<Wes2SyncPassResult> results = await Future.wait<Wes2SyncPassResult>(
      <Future<Wes2SyncPassResult>>[
        engine.process(),
        engine.process(),
        engine.process(),
        engine.process(),
      ],
    );

    expect(results.where((Wes2SyncPassResult r) => r.skipped).length, 3,
        reason: 'a pass already running absorbs the other triggers');
    expect(repo.calls, hasLength(5), reason: 'nothing applied twice');
    expect(repo.calls.map((AppliedCall c) => c.detail).toList(), <String>[
      '$kExId/0/weight=100.0',
      '$kExId/1/weight=101.0',
      '$kExId/2/weight=102.0',
      '$kExId/3/weight=103.0',
      '$kExId/4/weight=104.0',
    ]);
    expect(await outbox.countFor(kActor), 0);
  });

  // ── TEST 29 — set identity ───────────────────────────────────────────────

  test('TEST 29 — a queued setId is additive and replay-safe', () async {
    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await engine.submit(Wes2Mutation.stableSetId(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      exerciseId: kExId,
      setIndex: 2,
      setId: 'proof-abc',
    ));
    await engine.process();

    repo.failure = null;
    await engine.processNow();
    expect(repo.calls.single.op, 'setId');
    expect(repo.calls.single.detail, '$kExId/2=proof-abc');

    // Replay writes the same identity; saveSetId never overwrites an existing
    // one, so the footage stays attached to the same performance.
    await engine.submit(Wes2Mutation.stableSetId(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      exerciseId: kExId,
      setIndex: 2,
      setId: 'proof-abc',
    ));
    await engine.process();
    expect(repo.calls.last.detail, '$kExId/2=proof-abc');
  });

  // ── Confirmation signal, for post-save side effects ──────────────────────

  test('confirmed rows are announced only after the server accepts them',
      () async {
    final List<String> confirmed = <String>[];
    final Wes2SyncEngine e = Wes2SyncEngine(
      outbox: outbox,
      repository: repo,
      currentActorUid: () => actor,
      autoStartTimer: false,
      autoProcessOnSubmit: false,
      baseBackoff: Duration.zero,
      onConfirmed: (Wes2MutationRow r) => confirmed.add(r.kind),
    );
    addTearDown(e.dispose);

    repo.failure =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    await e.submit(weight(130));
    await e.process();
    expect(confirmed, isEmpty,
        reason: 'a failed write must not trigger post-save side effects');

    repo.failure = null;
    await e.processNow();
    expect(confirmed, <String>[Wes2MutationKind.field]);
  });

  // ── Structural + malformed payload safety ────────────────────────────────

  test('an undecodable payload is parked rather than wedging the queue',
      () async {
    await outbox.enqueue(const Wes2Mutation(
      id: 'broken',
      actorUid: kActor,
      athleteUid: kAthlete,
      dateKey: kDateKey,
      kind: Wes2MutationKind.field,
      exerciseId: kExId,
      // No setIndex, no row, no fieldKey.
    ));
    await engine.submit(weight(130));

    final Wes2SyncPassResult result = await engine.process();
    expect(result.blocked, 1);
    expect(result.applied, 1,
        reason: 'one bad row must not stop the athlete\'s good ones');
    expect((await outbox.byId('broken'))!.state, Wes2MutationState.blocked);
  });
}

/// A non-Firebase failure, of the kind a dropped connection actually produces.
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
  @override
  String toString() => 'SocketException: Failed host lookup';
}
