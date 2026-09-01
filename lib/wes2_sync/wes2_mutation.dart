/// The typed description of ONE thing the athlete did to their logged workout.
///
/// ── Why this type exists ────────────────────────────────────────────────────
/// Every WES2 write used to go straight to a Firestore transaction wrapped in a
/// `catch (_) {}`. A transaction needs a reachable server, so a lift logged in a
/// basement gym produced: a value on screen, a value in the controller, a value
/// in the local draft — and nothing in Firestore, with the failure discarded.
/// The athlete had no way to know, and history later showed a hole.
///
/// A mutation is the durable record of the athlete's INTENT, written before any
/// network call is attempted. The network attempt becomes a retry of something
/// already safe rather than the only chance to save it.
///
/// ── What is deliberately NOT in here ────────────────────────────────────────
/// Hints. A mutation is only ever created from a value the athlete actually
/// entered, cleared, or explicitly accepted through the normal entry
/// mechanism. `Wes2MutationKind.markDone` carries a boolean and nothing else,
/// so completing an exercise can never turn a displayed hint into stored
/// execution data.
///
/// BB3 prescription writes are also absent on purpose: the plan is not
/// execution data and must not be replayed by this queue.
///
/// No Firebase, Drift, or Flutter dependency — safe to import anywhere, and
/// testable on its own.
library;

import 'dart:convert';

import '../WES2_models.dart';

/// What a mutation does. The string values are persisted, so they are part of
/// the on-disk format and must not be renamed casually.
class Wes2MutationKind {
  /// One set field (weight / reps / RIR / velocity) set to a value, or
  /// explicitly cleared. A clear is a real intent, not an absence — see
  /// [Wes2Mutation.isClear].
  static const String field = 'field';

  /// Per-set execution note. Null note clears it.
  static const String setNote = 'setNote';

  /// Exercise-level execution note. Null note clears it.
  static const String exerciseNote = 'exerciseNote';

  /// Completion checkmark ONLY. Carries no execution values.
  static const String markDone = 'markDone';

  /// A raised set count (Add Set). Never lowers one.
  static const String setCount = 'setCount';

  /// A manually added blank exercise row.
  static const String manualExercise = 'manualExercise';

  /// Stable set identity, written additively before footage is attached.
  static const String setId = 'setId';

  // ── Structural ────────────────────────────────────────────────────────────

  static const String removeSet = 'removeSet';
  static const String deleteExercise = 'deleteExercise';
  static const String replaceExercise = 'replaceExercise';
  static const String moveCircuit = 'moveCircuit';
  static const String deleteAllForDay = 'deleteAllForDay';
  static const String templateReplaceAll = 'templateReplaceAll';

  /// Kinds that invalidate finer-grained pending work for the same target.
  /// Enqueuing one of these drops the pending rows it would otherwise
  /// resurrect — see `Wes2MutationOutbox.enqueue`.
  static const Set<String> structural = <String>{
    removeSet,
    deleteExercise,
    replaceExercise,
    deleteAllForDay,
    templateReplaceAll,
  };
}

/// Where one durable mutation stands.
class Wes2MutationState {
  /// Waiting for a processor pass, or waiting out a transient-failure backoff.
  static const String pending = 'pending';

  /// A pass is applying it right now.
  static const String inFlight = 'inFlight';

  /// Rejected for a reason retrying cannot fix on its own — denied by rules,
  /// unauthenticated, malformed. NEVER deleted: the athlete's data stays, and
  /// the row is retried when the auth/rules situation changes.
  static const String blocked = 'blocked';
}

/// `yyyy-MM-dd`, matching the WES2 workout document id.
String wes2DateKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime wes2DateFromKey(String key) {
  final List<String> parts = key.split('-');
  return DateTime(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

/// One durable unit of athlete intent.
///
/// [id] is the coalescing key. Two edits to the SAME field of the same set on
/// the same day share an id, so `120 → 125 → 130` collapses to a single row
/// holding 130 and an older in-flight attempt can never restore 120. Anything
/// whose repetition is meaningful — removing a set, replacing an exercise —
/// gets a unique id instead and is never merged with anything.
class Wes2Mutation {
  const Wes2Mutation({
    required this.id,
    required this.actorUid,
    required this.athleteUid,
    required this.dateKey,
    required this.kind,
    this.exerciseId = '',
    this.setIndex,
    this.payload = const <String, dynamic>{},
  });

  /// Coalescing identity. Deterministic for coalescable kinds.
  final String id;

  /// The authenticated account that made the edit. A mutation is only ever
  /// replayed while THIS account is signed in, so one athlete's queued work can
  /// never be pushed under another's credentials.
  final String actorUid;

  /// The athlete whose workout is being edited. Differs from [actorUid] in
  /// coach mode, and is the uid the Firestore path is built from.
  final String athleteUid;

  final String dateKey;
  final String kind;
  final String exerciseId;

  /// Present for set-scoped kinds. Rewritten when an earlier set is removed,
  /// so a queued edit never lands on the set that took its place.
  final int? setIndex;

  final Map<String, dynamic> payload;

  DateTime get date => wes2DateFromKey(dateKey);

  String get payloadJson => jsonEncode(payload);

  /// True when this mutation clears a value rather than setting one.
  ///
  /// The distinction is the whole point of a tombstone: "no local value" and
  /// "the athlete deleted this value" must not look the same, or a server value
  /// the athlete deliberately removed reappears at the next merge.
  bool get isClear =>
      (kind == Wes2MutationKind.field ||
          kind == Wes2MutationKind.setNote ||
          kind == Wes2MutationKind.exerciseNote) &&
      payload['value'] == null;

  static Map<String, dynamic> decodePayload(String json) {
    try {
      final Object? decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // A corrupt payload must not wedge the queue; the row is dropped by the
      // processor rather than retried forever.
    }
    return const <String, dynamic>{};
  }

  // ── Constructors, one per repository operation ────────────────────────────

  /// A set field the athlete typed, or explicitly cleared with [value] null.
  ///
  /// [row] is carried because `saveFieldPatch` needs full row context on the
  /// create/promote path — a BB3-planned row that is not in the workout
  /// document yet. It is used ONLY to create the row, and `_buildRowMap`
  /// serialises actualValues only, so no hint can reach Firestore through it.
  static Wes2Mutation fieldPatch({
    required String actorUid,
    required String athleteUid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setIndex,
    required Wes2FieldKey fieldKey,
    required Object? value,
  }) {
    final String dk = wes2DateKey(date);
    return Wes2Mutation(
      id: '$actorUid|$athleteUid|$dk|${row.exerciseId}|$setIndex|'
          '${Wes2MutationKind.field}|${fieldKey.name}',
      actorUid: actorUid,
      athleteUid: athleteUid,
      dateKey: dk,
      kind: Wes2MutationKind.field,
      exerciseId: row.exerciseId,
      setIndex: setIndex,
      payload: <String, dynamic>{
        'fieldKey': fieldKey.name,
        'value': value,
        'row': row.toJson(),
      },
    );
  }

  static Wes2Mutation setNote({
    required String actorUid,
    required String athleteUid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String? note,
  }) {
    final String dk = wes2DateKey(date);
    return Wes2Mutation(
      id: '$actorUid|$athleteUid|$dk|$exerciseId|$setIndex|'
          '${Wes2MutationKind.setNote}',
      actorUid: actorUid,
      athleteUid: athleteUid,
      dateKey: dk,
      kind: Wes2MutationKind.setNote,
      exerciseId: exerciseId,
      setIndex: setIndex,
      payload: <String, dynamic>{'value': note},
    );
  }

  static Wes2Mutation exerciseNote({
    required String actorUid,
    required String athleteUid,
    required DateTime date,
    required String exerciseId,
    required String? note,
  }) {
    final String dk = wes2DateKey(date);
    return Wes2Mutation(
      id: '$actorUid|$athleteUid|$dk|$exerciseId|'
          '${Wes2MutationKind.exerciseNote}',
      actorUid: actorUid,
      athleteUid: athleteUid,
      dateKey: dk,
      kind: Wes2MutationKind.exerciseNote,
      exerciseId: exerciseId,
      payload: <String, dynamic>{'value': note},
    );
  }

  /// Completion state only. The row is carried for the create/promote path the
  /// repository already had; it contributes actualValues alone.
  static Wes2Mutation markDone({
    required String actorUid,
    required String athleteUid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required bool isDone,
  }) {
    final String dk = wes2DateKey(date);
    return Wes2Mutation(
      id: '$actorUid|$athleteUid|$dk|${row.exerciseId}|'
          '${Wes2MutationKind.markDone}',
      actorUid: actorUid,
      athleteUid: athleteUid,
      dateKey: dk,
      kind: Wes2MutationKind.markDone,
      exerciseId: row.exerciseId,
      payload: <String, dynamic>{
        'isDone': isDone,
        'row': row.toJson(),
      },
    );
  }

  static Wes2Mutation setCount({
    required String actorUid,
    required String athleteUid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setCount,
  }) {
    final String dk = wes2DateKey(date);
    return Wes2Mutation(
      id: '$actorUid|$athleteUid|$dk|${row.exerciseId}|'
          '${Wes2MutationKind.setCount}',
      actorUid: actorUid,
      athleteUid: athleteUid,
      dateKey: dk,
      kind: Wes2MutationKind.setCount,
      exerciseId: row.exerciseId,
      payload: <String, dynamic>{
        'setCount': setCount,
        'row': row.toJson(),
      },
    );
  }

  static Wes2Mutation manualExercise({
    required String actorUid,
    required String athleteUid,
    required DateTime date,
    required Wes2ExerciseRow row,
  }) {
    final String dk = wes2DateKey(date);
    return Wes2Mutation(
      id: '$actorUid|$athleteUid|$dk|${row.exerciseId}|'
          '${Wes2MutationKind.manualExercise}',
      actorUid: actorUid,
      athleteUid: athleteUid,
      dateKey: dk,
      kind: Wes2MutationKind.manualExercise,
      exerciseId: row.exerciseId,
      payload: <String, dynamic>{'row': row.toJson()},
    );
  }

  static Wes2Mutation stableSetId({
    required String actorUid,
    required String athleteUid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String setId,
  }) {
    final String dk = wes2DateKey(date);
    return Wes2Mutation(
      id: '$actorUid|$athleteUid|$dk|$exerciseId|$setIndex|'
          '${Wes2MutationKind.setId}',
      actorUid: actorUid,
      athleteUid: athleteUid,
      dateKey: dk,
      kind: Wes2MutationKind.setId,
      exerciseId: exerciseId,
      setIndex: setIndex,
      payload: <String, dynamic>{'setId': setId},
    );
  }

  /// Removing a set is the one operation whose repetition is NOT harmless: a
  /// blind replay after a crash would delete whichever set slid into the gap.
  /// [expectedSetCountBefore] is the guard — the repository skips the removal
  /// when the stored count no longer matches, which is exactly the state a
  /// successful first attempt leaves behind.
  static Wes2Mutation removeSet({
    required String actorUid,
    required String athleteUid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required int expectedSetCountBefore,
    required int localSeq,
  }) {
    final String dk = wes2DateKey(date);
    return Wes2Mutation(
      id: '$actorUid|$athleteUid|$dk|$exerciseId|'
          '${Wes2MutationKind.removeSet}|$setIndex|$localSeq',
      actorUid: actorUid,
      athleteUid: athleteUid,
      dateKey: dk,
      kind: Wes2MutationKind.removeSet,
      exerciseId: exerciseId,
      setIndex: setIndex,
      payload: <String, dynamic>{
        'expectedSetCountBefore': expectedSetCountBefore,
      },
    );
  }

  static Wes2Mutation deleteExercise({
    required String actorUid,
    required String athleteUid,
    required DateTime date,
    required String exerciseId,
  }) {
    final String dk = wes2DateKey(date);
    return Wes2Mutation(
      id: '$actorUid|$athleteUid|$dk|$exerciseId|'
          '${Wes2MutationKind.deleteExercise}',
      actorUid: actorUid,
      athleteUid: athleteUid,
      dateKey: dk,
      kind: Wes2MutationKind.deleteExercise,
      exerciseId: exerciseId,
    );
  }

  static Wes2Mutation replaceExercise({
    required String actorUid,
    required String athleteUid,
    required DateTime date,
    required String oldExerciseId,
    required String newExerciseId,
    required String newName,
  }) {
    final String dk = wes2DateKey(date);
    return Wes2Mutation(
      id: '$actorUid|$athleteUid|$dk|$oldExerciseId|'
          '${Wes2MutationKind.replaceExercise}|$newExerciseId',
      actorUid: actorUid,
      athleteUid: athleteUid,
      dateKey: dk,
      kind: Wes2MutationKind.replaceExercise,
      exerciseId: oldExerciseId,
      payload: <String, dynamic>{
        'newExerciseId': newExerciseId,
        'newName': newName,
      },
    );
  }

  static Wes2Mutation moveCircuit({
    required String actorUid,
    required String athleteUid,
    required DateTime date,
    required String exerciseId,
    required int targetCircuitIndex,
  }) {
    final String dk = wes2DateKey(date);
    return Wes2Mutation(
      id: '$actorUid|$athleteUid|$dk|$exerciseId|'
          '${Wes2MutationKind.moveCircuit}',
      actorUid: actorUid,
      athleteUid: athleteUid,
      dateKey: dk,
      kind: Wes2MutationKind.moveCircuit,
      exerciseId: exerciseId,
      payload: <String, dynamic>{'circuitIndex': targetCircuitIndex},
    );
  }

  static Wes2Mutation deleteAllForDay({
    required String actorUid,
    required String athleteUid,
    required DateTime date,
    required int localSeq,
  }) {
    final String dk = wes2DateKey(date);
    return Wes2Mutation(
      id: '$actorUid|$athleteUid|$dk|'
          '${Wes2MutationKind.deleteAllForDay}|$localSeq',
      actorUid: actorUid,
      athleteUid: athleteUid,
      dateKey: dk,
      kind: Wes2MutationKind.deleteAllForDay,
    );
  }

  static Wes2Mutation templateReplaceAll({
    required String actorUid,
    required String athleteUid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
    required int localSeq,
  }) {
    final String dk = wes2DateKey(date);
    return Wes2Mutation(
      id: '$actorUid|$athleteUid|$dk|'
          '${Wes2MutationKind.templateReplaceAll}|$localSeq',
      actorUid: actorUid,
      athleteUid: athleteUid,
      dateKey: dk,
      kind: Wes2MutationKind.templateReplaceAll,
      payload: <String, dynamic>{
        'rows': rows.map((Wes2ExerciseRow r) => r.toJson()).toList(),
      },
    );
  }

  // ── Payload readers ───────────────────────────────────────────────────────

  static Wes2ExerciseRow? rowFrom(Map<String, dynamic> payload) {
    final Object? raw = payload['row'];
    if (raw is! Map<String, dynamic>) return null;
    try {
      return Wes2ExerciseRow.fromJson(raw);
    } catch (_) {
      return null;
    }
  }

  static Wes2FieldKey? fieldKeyFrom(Map<String, dynamic> payload) {
    final Object? raw = payload['fieldKey'];
    if (raw is! String) return null;
    for (final Wes2FieldKey k in Wes2FieldKey.values) {
      if (k.name == raw) return k;
    }
    return null;
  }

  /// The parsed value for a field mutation, typed the way the repository
  /// expects it. Reps are integers; everything else is a double. Null means an
  /// explicit clear and is returned as null.
  static Object? fieldValueFrom(Map<String, dynamic> payload) {
    final Object? raw = payload['value'];
    if (raw == null) return null;
    if (raw is! num) return null;
    return fieldKeyFrom(payload) == Wes2FieldKey.reps
        ? raw.toInt()
        : raw.toDouble();
  }
}
