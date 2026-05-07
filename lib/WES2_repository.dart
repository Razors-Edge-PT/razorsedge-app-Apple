import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'WES2_models.dart';

// Abstract interface — Phase 3 adds FirestoreWes2Repository below.
abstract class Wes2Repository {
  /// Load completed exercises[] + wesPlannedExercises[] for uid/date.
  Future<List<Wes2ExerciseRow>> loadDay({
    required String uid,
    required DateTime date,
  });

  /// Persist exercises[] (rows that have any execution value).
  Future<void> saveCompletedRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> completedRows,
  });

  /// Persist wesPlannedExercises[] (blank WES2-added rows with no values).
  Future<void> savePlannedRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> plannedRows,
  });

  /// Granular field-level save on unfocus. Uses a Firestore transaction so
  /// one device's field edit never wipes another device's unrelated fields.
  /// [row] supplies full row context for create/promote paths.
  /// [value] is the parsed actual value, or null to remove the field.
  Future<void> saveFieldPatch({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setIndex,
    required Wes2FieldKey fieldKey,
    required dynamic value,
  });

  /// Write isMarkedDone onto the exercises[] row.
  /// [row] supplies full row context for create/promote paths (BB3-planned rows
  /// that are not yet in exercises[] must be materialized using actual values only).
  Future<void> setMarkedDone({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required bool isDone,
  });
}

/// Concrete Firestore implementation.
/// Phase 3: loadDay only. saveFieldPatch implemented in Phase 8.
/// Other write methods throw UnimplementedError until a later phase.
class FirestoreWes2Repository implements Wes2Repository {
  @override
  Future<List<Wes2ExerciseRow>> loadDay({
    required String uid,
    required DateTime date,
  }) async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date))
        .get();

    if (!snap.exists) return const [];
    final data = snap.data();
    if (data == null) return const [];

    final exercises = (data['exercises'] as List<dynamic>?) ?? const [];
    final wesPlanned =
        (data['wesPlannedExercises'] as List<dynamic>?) ?? const [];

    // exercises[] is processed first: completedServer rows win deduplication.
    final Map<String, Wes2ExerciseRow> seen = {};

    for (int i = 0; i < exercises.length; i++) {
      final row = _parseRow(exercises[i], Wes2RowSource.completedServer, i);
      if (row == null) continue;
      seen.putIfAbsent(row.exerciseId, () => row);
    }

    // wesPlannedExercises[]: only inserted if exerciseId not already present.
    for (int i = 0; i < wesPlanned.length; i++) {
      final row = _parseRow(
        wesPlanned[i],
        Wes2RowSource.wes2Manual,
        exercises.length + i, // fallback order starts after all exercises[]
      );
      if (row == null) continue;
      seen.putIfAbsent(row.exerciseId, () => row);
    }

    return seen.values.toList()
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  }

  // ── Parse helpers ─────────────────────────────────────────────────────────

  static Wes2ExerciseRow? _parseRow(
    dynamic raw,
    Wes2RowSource source,
    int fallbackOrder,
  ) {
    if (raw is! Map<String, dynamic>) return null;

    final exerciseId = (raw['exerciseId'] as String?) ?? '';
    if (exerciseId.isEmpty) return null;

    final rawName = raw['name'] as String?;
    final name = (rawName != null && rawName.isNotEmpty) ? rawName : exerciseId;

    final circuitIndex = (raw['circuitIndex'] as num?)?.toInt() ?? 0;
    final orderIndex = (raw['orderIndex'] as num?)?.toInt() ?? fallbackOrder;
    final storedSetCount = (raw['setCount'] as num?)?.toInt() ?? 0;
    final isMarkedDone = (raw['isMarkedDone'] as bool?) ?? false;

    final rawSets = (raw['sets'] as List<dynamic>?) ?? const [];
    // setCount = max(stored, actual sets length) so we never lose data.
    final setCount =
        storedSetCount > rawSets.length ? storedSetCount : rawSets.length;

    return Wes2ExerciseRow(
      exerciseId: exerciseId,
      name: name,
      circuitIndex: circuitIndex,
      orderIndex: orderIndex,
      setCount: setCount,
      sets: _parseSets(rawSets, setCount),
      source: source,
      isMarkedDone: isMarkedDone,
    );
  }

  static List<Wes2SetState> _parseSets(List<dynamic> rawSets, int count) {
    return List.generate(count, (i) {
      if (i >= rawSets.length || rawSets[i] is! Map<String, dynamic>) {
        return Wes2SetState(setIndex: i);
      }
      final s = rawSets[i] as Map<String, dynamic>;
      return Wes2SetState(
        setIndex: i,
        weight: _parseDouble(s['weight']),
        reps: _parseInt(s['reps']),
        rir: _parseDouble(s['rir']),
        velocity: _parseDouble(s['velocity']),
      );
    });
  }

  static Wes2FieldState<double> _parseDouble(dynamic v) {
    if (v is! num) return const Wes2FieldState<double>();
    return Wes2FieldState<double>(
      actualValue: v.toDouble(),
      origin: FieldOrigin.completed,
    );
  }

  static Wes2FieldState<int> _parseInt(dynamic v) {
    if (v is! num) return const Wes2FieldState<int>();
    return Wes2FieldState<int>(
      actualValue: v.toInt(),
      origin: FieldOrigin.completed,
    );
  }

  static String _dateDocId(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  // ── saveFieldPatch (Phase 8) ───────────────────────────────────────────────

  /// Runs a Firestore transaction to patch a single field on a single set of
  /// a single exercise row, preserving all unrelated rows/sets/fields.
  ///
  /// Decision table (exerciseId location → action):
  ///   exercises[]       → surgical single-field patch of existing row
  ///   wesPlanned, null  → patch wesPlanned in place (keep blank row)
  ///   wesPlanned, !null → promote row to exercises[], rebuild from [row]
  ///   neither,   !null  → create new row in exercises[], built from [row]
  ///   neither,   null   → no-op (nothing to clear)
  ///
  /// Errors are NOT caught here; the caller wraps in a silent-catch helper.
  @override
  Future<void> saveFieldPatch({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setIndex,
    required Wes2FieldKey fieldKey,
    required dynamic value,
  }) async {
    final docRef = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));

    await FirebaseFirestore.instance.runTransaction((txn) async {
      final snap = await txn.get(docRef);
      final data = snap.exists
          ? (snap.data() ?? <String, dynamic>{})
          : <String, dynamic>{};

      // Defensive copy — we mutate these lists during the transaction.
      final exercises = (data['exercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final wesPlanned = (data['wesPlannedExercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

      final exerciseId = row.exerciseId;
      final exIdx = exercises.indexWhere((m) => m['exerciseId'] == exerciseId);
      final wpIdx = wesPlanned.indexWhere((m) => m['exerciseId'] == exerciseId);

      if (exIdx != -1) {
        // Surgical patch of the one field — preserves all other fields/sets.
        exercises[exIdx] =
            _patchSetInRow(exercises[exIdx], setIndex, fieldKey, value);
      } else if (wpIdx != -1) {
        if (value == null) {
          // Clearing a field on a wesPlanned-only row — patch in place.
          wesPlanned[wpIdx] =
              _patchSetInRow(wesPlanned[wpIdx], setIndex, fieldKey, value);
        } else {
          // Real value typed → promote row to exercises[] using in-memory state.
          exercises.add(_buildRowMap(row));
          wesPlanned.removeAt(wpIdx);
        }
      } else if (value != null) {
        // BB3 or new row not yet in the workout doc → create in exercises[].
        exercises.add(_buildRowMap(row));
      }
      // value == null and row not found → no-op (nothing to clear).

      txn.set(
        docRef,
        {
          'userId': uid,
          'date': _dateDocId(date),
          'lastEditedAt': FieldValue.serverTimestamp(),
          'exercises': exercises,
          'wesPlannedExercises': wesPlanned,
        },
        SetOptions(merge: true),
      );
    });
  }

  // ── saveFieldPatch helpers ─────────────────────────────────────────────────

  /// Patches one field on one set inside an existing Firestore row map.
  /// Locates the set by stored setIndex key (preferred) or array index
  /// (fallback for legacy sets that lack a setIndex field).
  /// Preserves all other fields in the set map and in the row map.
  static Map<String, dynamic> _patchSetInRow(
    Map<String, dynamic> rowMap,
    int setIndex,
    Wes2FieldKey fieldKey,
    dynamic value,
  ) {
    final result = Map<String, dynamic>.from(rowMap);
    final rawSets = ((result['sets'] as List<dynamic>?) ?? [])
        .map((s) => s is Map<String, dynamic>
            ? Map<String, dynamic>.from(s)
            : <String, dynamic>{})
        .toList();

    // Locate target set: prefer stored setIndex key; fall back to array index
    // for legacy WES sets that were written without a setIndex field.
    int? arrayPos;
    for (int i = 0; i < rawSets.length; i++) {
      final stored = (rawSets[i]['setIndex'] as num?)?.toInt();
      if (stored != null) {
        if (stored == setIndex) {
          arrayPos = i;
          break;
        }
      } else {
        // Legacy: no setIndex key — array position IS the set identity.
        if (i == setIndex) {
          arrayPos = i;
          break;
        }
      }
    }

    if (arrayPos != null) {
      rawSets[arrayPos] =
          _applyFieldToSetMap(rawSets[arrayPos], fieldKey, value);
    } else if (value != null) {
      // New set index not yet in Firestore — pad and insert at correct position.
      while (rawSets.length <= setIndex) {
        rawSets.add(<String, dynamic>{'setIndex': rawSets.length});
      }
      rawSets[setIndex] =
          _applyFieldToSetMap(rawSets[setIndex], fieldKey, value);
    }
    // value == null and set not found → no-op.

    // setCount is only ever increased, never decreased.
    final existingCount = (result['setCount'] as num?)?.toInt() ?? 0;
    result['setCount'] =
        (setIndex + 1) > existingCount ? (setIndex + 1) : existingCount;
    result['sets'] = rawSets;
    return result;
  }

  /// Sets or removes [fieldKey] in a set map copy; all other keys are kept.
  /// null value → removes the key (no empty/zero/null stored in Firestore).
  static Map<String, dynamic> _applyFieldToSetMap(
    Map<String, dynamic> setMap,
    Wes2FieldKey fieldKey,
    dynamic value,
  ) {
    final result = Map<String, dynamic>.from(setMap);
    if (value == null) {
      result.remove(fieldKey.name);
    } else {
      result[fieldKey.name] = value;
    }
    return result;
  }

  /// Serialises the full in-memory [row] to a Firestore row map.
  /// Only actualValues are written — hintValues are never persisted as actuals.
  /// Used for create (BB3/new row) and promote (wesPlanned → exercises) paths.
  static Map<String, dynamic> _buildRowMap(Wes2ExerciseRow row) {
    final sets = <Map<String, dynamic>>[];
    for (final s in row.sets) {
      final setMap = <String, dynamic>{'setIndex': s.setIndex};
      if (s.weight.actualValue != null) setMap['weight'] = s.weight.actualValue;
      if (s.reps.actualValue != null) setMap['reps'] = s.reps.actualValue;
      if (s.rir.actualValue != null) setMap['rir'] = s.rir.actualValue;
      if (s.velocity.actualValue != null) {
        setMap['velocity'] = s.velocity.actualValue;
      }
      sets.add(setMap);
    }
    return {
      'exerciseId': row.exerciseId,
      'name': row.name,
      'circuitIndex': row.circuitIndex,
      'orderIndex': row.orderIndex,
      'setCount': row.setCount,
      'isMarkedDone': false,
      'sets': sets,
    };
  }

  // ── Write stubs (future phases) ───────────────────────────────────────────

  @override
  Future<void> saveCompletedRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> completedRows,
  }) =>
      throw UnimplementedError('saveCompletedRows not implemented yet');

  @override
  Future<void> savePlannedRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> plannedRows,
  }) =>
      throw UnimplementedError('savePlannedRows not implemented yet');

  @override
  Future<void> setMarkedDone({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required bool isDone,
  }) async {
    debugPrint(
      '[WES2] setMarkedDone called — uid=${uid.isEmpty ? "EMPTY" : uid}, '
      'date=${_dateDocId(date)}, exerciseId=${row.exerciseId}, isDone=$isDone',
    );

    final docRef = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));

    await FirebaseFirestore.instance.runTransaction((txn) async {
      final snap = await txn.get(docRef);
      final data = snap.exists
          ? (snap.data() ?? <String, dynamic>{})
          : <String, dynamic>{};

      final exercises = (data['exercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final wesPlanned = (data['wesPlannedExercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

      final exerciseId = row.exerciseId;
      final exIdx = exercises.indexWhere((m) => m['exerciseId'] == exerciseId);
      final wpIdx = wesPlanned.indexWhere((m) => m['exerciseId'] == exerciseId);

      debugPrint(
        '[WES2] setMarkedDone branch — exIdx=$exIdx, wpIdx=$wpIdx',
      );

      if (exIdx != -1) {
        // Surgical patch of top-level isMarkedDone — preserves all other fields/sets.
        exercises[exIdx] = Map<String, dynamic>.from(exercises[exIdx])
          ..['isMarkedDone'] = isDone;
      } else if (wpIdx != -1) {
        // Promote wesPlanned row to exercises[] with isMarkedDone set.
        // Actual values only — _buildRowMap never writes hintValues.
        exercises.add(_buildRowMap(row)..['isMarkedDone'] = isDone);
        wesPlanned.removeAt(wpIdx);
      } else if (isDone) {
        // BB3-planned or new row — create in exercises[] using actual values only.
        exercises.add(_buildRowMap(row)..['isMarkedDone'] = isDone);
      }
      // isDone == false and row not found → no-op (nothing to un-mark).

      txn.set(
        docRef,
        {
          'userId': uid,
          'date': _dateDocId(date),
          'lastEditedAt': FieldValue.serverTimestamp(),
          'exercises': exercises,
          'wesPlannedExercises': wesPlanned,
        },
        SetOptions(merge: true),
      );
    });

    debugPrint(
      '[WES2] setMarkedDone transaction committed — ${row.exerciseId} isDone=$isDone',
    );
  }
}
