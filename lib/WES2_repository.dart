import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'WES2_models.dart';
import 'progression_history_store.dart';

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

  /// Persist a new setCount for an existing row.
  /// Updates setCount only if [setCount] is higher than the stored value.
  /// Only modifies rows already present in exercises[] or wesPlannedExercises[].
  /// No-op if the row is not yet materialized in the workout document
  /// (e.g. BB3-planned rows with no actuals yet).
  Future<void> saveSetCount({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setCount,
  });

  /// Append a manually added blank exercise row to wesPlannedExercises[].
  /// No-op if exerciseId already exists in exercises[] or wesPlannedExercises[].
  /// Does NOT write isMarkedDone, hint values, or BB3 planned fields.
  Future<void> saveManualExercise({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
  });

  /// Remove one set from exercises[] or wesPlannedExercises[], compact
  /// remaining sets, and decrement setCount.
  /// No-op if the row has only one set — screen routes that to deleteExercise.
  ///
  /// [expectedSetCountBefore] makes a REPLAY safe. Removal is the one WES2
  /// operation whose repetition is destructive: applying it twice would delete
  /// whichever set slid into the gap. When supplied, the removal is skipped
  /// unless the stored setCount still matches — which is exactly the state a
  /// successful first application leaves behind. Null keeps the original
  /// unguarded behaviour for live callers.
  Future<void> removeSet({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    int? expectedSetCountBefore,
  });

  /// Remove an exercise from both exercises[] and wesPlannedExercises[].
  Future<void> deleteExercise({
    required String uid,
    required DateTime date,
    required String exerciseId,
  });

  /// Replace an exercise in-place (both arrays). Clears sets for the new entry.
  /// Replaces in exercises[] if present there; otherwise in wesPlannedExercises[].
  Future<void> replaceExercise({
    required String uid,
    required DateTime date,
    required String oldExerciseId,
    required String newExerciseId,
    required String newName,
  });

  /// Update circuitIndex for an exercise in both arrays.
  Future<void> moveExerciseToCircuit({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int targetCircuitIndex,
  });

  /// Patch executionNote on one set. [note] null removes the key.
  /// No-op if the row is not yet materialized in the workout document.
  Future<void> saveExecutionNote({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String? note,
  });

  /// Patch exerciseExecutionNote on an exercise row. [note] null removes the key.
  /// Searches exercises[] first, then wesPlannedExercises[].
  /// No-op if the row is not yet materialized in the workout document.
  Future<void> saveExerciseExecutionNote({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required String? note,
  });

  /// Replace the entire workout doc for [date] with template-loaded rows.
  /// Clears exercises[] and writes [rows] to wesPlannedExercises[] as blank rows.
  /// Preserves other doc fields (userId, date, etc.).
  Future<void> replaceAllWithTemplateRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
  });

  /// Clear all exercises for the current day by setting both arrays to empty.
  /// Uses merge: true so other doc fields are preserved.
  Future<void> deleteAllExercisesForDay({
    required String uid,
    required DateTime date,
  });

  /// Writes a stable [setId] onto one set, ADDITIVELY.
  ///
  /// Every other key on that set — weight, reps, RIR, velocity, notes, timing —
  /// and every neighbouring set and row is preserved. Used immediately before a
  /// recording is attached, so the identity the video is filed under is the
  /// same one the server's record fingerprint will be built from.
  ///
  /// A set that already carries `id` or `setId` is left alone: the showcase
  /// reducers read `s.id ?? s.setId`, and writing a competing value would
  /// change the fingerprint of an already-scored performance.
  Future<void> saveSetId({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String setId,
  });

  /// The performance currently SAVED for one exact set, located by stable
  /// identity rather than by display index.
  ///
  /// Returns null when the day, the row, or a set with that identity cannot be
  /// found — never a guess. A wrong performance here would produce a
  /// fingerprint that the server projection will never match, which would
  /// either publish nothing or, worse, publish against another set.
  Future<Wes2SavedSetPerformance?> savedPerformanceForSet({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required String setId,
  });
}

/// The saved values behind one set, as Firestore currently holds them.
class Wes2SavedSetPerformance {
  const Wes2SavedSetPerformance({
    required this.exerciseId,
    required this.exerciseName,
    required this.setId,
    required this.weight,
    required this.reps,
  });

  final String exerciseId;
  final String exerciseName;
  final String setId;
  final double? weight;
  final int? reps;
}

/// Concrete Firestore implementation.
/// Phase 3: loadDay only. saveFieldPatch implemented in Phase 8.
/// Other write methods throw UnimplementedError until a later phase.
class FirestoreWes2Repository implements Wes2Repository {
  /// Injectable for tests; null means the app-wide instance. Resolved lazily
  /// through [_db] so constructing the repository never touches Firebase.
  final FirebaseFirestore? _firestore;

  FirestoreWes2Repository({FirebaseFirestore? firestore})
      : _firestore = firestore;

  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

  @override
  Future<List<Wes2ExerciseRow>> loadDay({
    required String uid,
    required DateTime date,
  }) async {
    final snap = await _db
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
      exerciseExecutionNote: raw['exerciseExecutionNote'] as String?,
    );
  }

  /// Firestore set decoding, exposed for round-trip tests. The Firestore
  /// shape is the one place a lost `setId` silently reassigns a video, so it is
  /// tested directly rather than through a live client.
  @visibleForTesting
  static List<Wes2SetState> parseSetsForTest(List<dynamic> rawSets, int count) =>
      _parseSets(rawSets, count);

  /// Firestore row encoding, exposed for round-trip tests.
  @visibleForTesting
  static Map<String, dynamic> buildRowMapForTest(Wes2ExerciseRow row) =>
      _buildRowMap(row);

  static List<Wes2SetState> _parseSets(List<dynamic> rawSets, int count) {
    return List.generate(count, (i) {
      if (i >= rawSets.length || rawSets[i] is! Map<String, dynamic>) {
        return Wes2SetState(setIndex: i);
      }
      final s = rawSets[i] as Map<String, dynamic>;
      return Wes2SetState(
        setIndex: i,
        // Same precedence the showcase reducers use, so a set loaded back from
        // Firestore keeps the identity its record fingerprint was built from.
        setId: readStableSetId(s),
        weight: _parseDouble(s['weight']),
        reps: _parseInt(s['reps']),
        rir: _parseDouble(s['rir']),
        velocity: _parseDouble(s['velocity']),
        executionNote: s['executionNote'] as String?,
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

  // ── Stable set identity ────────────────────────────────────────────────────

  @override
  Future<void> saveSetId({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String setId,
  }) async {
    final DocumentReference<Map<String, dynamic>> ref = FirebaseFirestore
        .instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));

    await _db.runTransaction((Transaction tx) async {
      final DocumentSnapshot<Map<String, dynamic>> snap = await tx.get(ref);
      final Map<String, dynamic> data = snap.data() ?? <String, dynamic>{};

      // Only ever touches exercises[]: a row with no execution values yet lives
      // in wesPlannedExercises[], and a PLAN carries no set identity. The
      // identity is written when the row is promoted by a real save.
      final List<dynamic> rawRows =
          (data['exercises'] as List<dynamic>?) ?? <dynamic>[];
      final List<Map<String, dynamic>> rows = rawRows
          .map((r) => r is Map<String, dynamic>
              ? Map<String, dynamic>.from(r)
              : <String, dynamic>{})
          .toList();

      final int rowIdx =
          rows.indexWhere((r) => r['exerciseId'] == exerciseId);
      if (rowIdx == -1) return;

      final Map<String, dynamic> row = Map<String, dynamic>.from(rows[rowIdx]);
      final List<Map<String, dynamic>> sets =
          ((row['sets'] as List<dynamic>?) ?? <dynamic>[])
              .map((x) => x is Map<String, dynamic>
                  ? Map<String, dynamic>.from(x)
                  : <String, dynamic>{})
              .toList();

      // Locate by stored setIndex, falling back to array position for legacy
      // sets written without the field — the same rule saveFieldPatch uses.
      int? pos;
      for (int i = 0; i < sets.length; i++) {
        final int? stored = (sets[i]['setIndex'] as num?)?.toInt();
        if (stored != null) {
          if (stored == setIndex) {
            pos = i;
            break;
          }
        } else if (i == setIndex) {
          pos = i;
          break;
        }
      }
      if (pos == null) {
        while (sets.length <= setIndex) {
          sets.add(<String, dynamic>{'setIndex': sets.length});
        }
        pos = setIndex;
      }

      // Never overwrite an identity that already exists: the reducers read
      // `s.id ?? s.setId`, so replacing one would move an existing record's
      // fingerprint and detach any proof already attached to it.
      final String? existing = readStableSetId(sets[pos]);
      if (existing != null) return;

      sets[pos] = <String, dynamic>{...sets[pos], 'setId': setId};
      row['sets'] = sets;
      rows[rowIdx] = row;

      tx.set(ref, <String, dynamic>{'exercises': rows},
          SetOptions(merge: true));
    });
  }

  @override
  Future<Wes2SavedSetPerformance?> savedPerformanceForSet({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required String setId,
  }) async {
    final String wanted = setId.trim();
    if (wanted.isEmpty) return null;

    final DocumentSnapshot<Map<String, dynamic>> snap = await FirebaseFirestore
        .instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date))
        .get();

    final Map<String, dynamic>? data = snap.data();
    if (data == null) return null;

    for (final dynamic rawRow
        in (data['exercises'] as List<dynamic>?) ?? <dynamic>[]) {
      if (rawRow is! Map<String, dynamic>) continue;
      if (rawRow['exerciseId'] != exerciseId) continue;

      for (final dynamic rawSet
          in (rawRow['sets'] as List<dynamic>?) ?? <dynamic>[]) {
        if (rawSet is! Map<String, dynamic>) continue;
        // Identity only. Deliberately never falls back to the display index:
        // an index match after a reindex would describe a DIFFERENT
        // performance, and the fingerprint built from it would be wrong.
        if (readStableSetId(rawSet) != wanted) continue;

        final Object? w = rawSet['weight'];
        final Object? r = rawSet['reps'];
        return Wes2SavedSetPerformance(
          exerciseId: exerciseId,
          exerciseName: (rawRow['name'] as String?) ?? '',
          setId: wanted,
          weight: w is num ? w.toDouble() : null,
          reps: r is num ? r.round() : null,
        );
      }
    }
    return null;
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
    // Any write to this day can change progression history for
    // this athlete. Mark the day dirty so the next history
    // hydration re-reads ONE document instead of everything.
    ProgressionHistoryStore.instance
        .markDayDirty(uid: uid, date: date);
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));

    await _db.runTransaction((txn) async {
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
      // Written only when the set actually carries one, so rows of sets that
      // predate stable identity serialise exactly as they always have.
      if (s.setId != null) setMap['setId'] = s.setId;
      if (s.weight.actualValue != null) setMap['weight'] = s.weight.actualValue;
      if (s.reps.actualValue != null) setMap['reps'] = s.reps.actualValue;
      if (s.rir.actualValue != null) setMap['rir'] = s.rir.actualValue;
      if (s.velocity.actualValue != null) {
        setMap['velocity'] = s.velocity.actualValue;
      }
      if (s.executionNote != null) setMap['executionNote'] = s.executionNote!;
      sets.add(setMap);
    }
    final rowMap = <String, dynamic>{
      'exerciseId': row.exerciseId,
      'name': row.name,
      'circuitIndex': row.circuitIndex,
      'orderIndex': row.orderIndex,
      'setCount': row.setCount,
      'isMarkedDone': false,
      'sets': sets,
    };
    if (row.exerciseExecutionNote != null) {
      rowMap['exerciseExecutionNote'] = row.exerciseExecutionNote!;
    }
    return rowMap;
  }

  /// Builds a minimal Firestore map for a wesPlannedExercises[] row.
  /// Intentionally omits isMarkedDone (lives only on exercises[]) and all
  /// hint/model values (never persisted to Firestore).
  static Map<String, dynamic> _buildWesPlannedRowMap(Wes2ExerciseRow row) {
    return {
      'exerciseId': row.exerciseId,
      'name': row.name,
      'circuitIndex': row.circuitIndex,
      'orderIndex': row.orderIndex,
      'setCount': row.setCount,
      'sets': <Map<String, dynamic>>[],
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
    // Any write to this day can change progression history for
    // this athlete. Mark the day dirty so the next history
    // hydration re-reads ONE document instead of everything.
    ProgressionHistoryStore.instance
        .markDayDirty(uid: uid, date: date);
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));

    await _db.runTransaction((txn) async {
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
  }

  // ── saveSetCount (Phase 10) ───────────────────────────────────────────────

  /// Updates setCount on an existing exercises[] or wesPlannedExercises[] row.
  /// setCount is only ever increased. If the row is not yet present in the
  /// workout document (BB3-planned with no actuals), this is a no-op — the
  /// caller must not pass unmaterialised rows.
  @override
  Future<void> saveSetCount({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setCount,
  }) async {
    // Any write to this day can change progression history for
    // this athlete. Mark the day dirty so the next history
    // hydration re-reads ONE document instead of everything.
    ProgressionHistoryStore.instance
        .markDayDirty(uid: uid, date: date);
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));

    await _db.runTransaction((txn) async {
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

      if (exIdx != -1) {
        final existing = (exercises[exIdx]['setCount'] as num?)?.toInt() ?? 0;
        if (setCount > existing) {
          exercises[exIdx] = Map<String, dynamic>.from(exercises[exIdx])
            ..['setCount'] = setCount;
        }
      } else if (wpIdx != -1) {
        final existing = (wesPlanned[wpIdx]['setCount'] as num?)?.toInt() ?? 0;
        if (setCount > existing) {
          wesPlanned[wpIdx] = Map<String, dynamic>.from(wesPlanned[wpIdx])
            ..['setCount'] = setCount;
        }
      }
      // Row not in either list → no-op. Screen prevents this for BB3-planned
      // rows that have no actuals yet.

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

  // ── saveManualExercise (Phase 11) ─────────────────────────────────────────

  /// Appends a manually added blank exercise row to wesPlannedExercises[].
  /// Server-side duplicate guard: no-op if exerciseId already in exercises[]
  /// or wesPlannedExercises[]. isMarkedDone is not written here — it lives
  /// only on exercises[] rows.
  @override
  Future<void> saveManualExercise({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
  }) async {
    // Any write to this day can change progression history for
    // this athlete. Mark the day dirty so the next history
    // hydration re-reads ONE document instead of everything.
    ProgressionHistoryStore.instance
        .markDayDirty(uid: uid, date: date);
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));

    await _db.runTransaction((txn) async {
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
      final alreadyExists =
          exercises.any((m) => m['exerciseId'] == exerciseId) ||
              wesPlanned.any((m) => m['exerciseId'] == exerciseId);

      if (alreadyExists) return; // server-side duplicate guard

      wesPlanned.add(_buildWesPlannedRowMap(row));

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

  // ── removeSet (Phase 14) ──────────────────────────────────────────────────

  @override
  Future<void> removeSet({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    int? expectedSetCountBefore,
  }) async {
    // Any write to this day can change progression history for
    // this athlete. Mark the day dirty so the next history
    // hydration re-reads ONE document instead of everything.
    ProgressionHistoryStore.instance
        .markDayDirty(uid: uid, date: date);
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));

    await _db.runTransaction((txn) async {
      final snap = await txn.get(docRef);
      if (!snap.exists) return;
      final data = snap.data() ?? <String, dynamic>{};

      final exercises = (data['exercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final wesPlanned = (data['wesPlannedExercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

      final exIdx =
          exercises.indexWhere((m) => m['exerciseId'] == exerciseId);
      final wpIdx =
          wesPlanned.indexWhere((m) => m['exerciseId'] == exerciseId);

      if (exIdx == -1 && wpIdx == -1) return;

      final rowList = exIdx != -1 ? exercises : wesPlanned;
      final rowPos = exIdx != -1 ? exIdx : wpIdx;
      final rowMap = Map<String, dynamic>.from(rowList[rowPos]);

      final storedSetCount = (rowMap['setCount'] as num?)?.toInt() ?? 0;
      if (storedSetCount <= 1) return; // screen handles delete exercise
      // Replay guard. A queued removal that already succeeded finds a count
      // one lower than it recorded, and stops rather than removing the set
      // that took the removed one's place.
      if (expectedSetCountBefore != null &&
          storedSetCount != expectedSetCountBefore) {
        return;
      }

      final rawSets = (rowMap['sets'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

      // Remove by stored setIndex field; fall back to array position for
      // legacy set maps that lack the field.
      List<Map<String, dynamic>> retained;
      if (rawSets.any((m) => m.containsKey('setIndex'))) {
        retained = rawSets
            .where((m) => (m['setIndex'] as num?)?.toInt() != setIndex)
            .toList()
          ..sort((a, b) => ((a['setIndex'] as num?)?.toInt() ?? 0)
              .compareTo((b['setIndex'] as num?)?.toInt() ?? 0));
      } else {
        retained = List<Map<String, dynamic>>.from(rawSets);
        if (setIndex < retained.length) retained.removeAt(setIndex);
      }

      // Compact: reassign setIndex = array position; preserve all other keys.
      final compacted = retained.asMap().entries.map((e) {
        final m = Map<String, dynamic>.from(e.value);
        m['setIndex'] = e.key;
        return m;
      }).toList();

      rowMap['sets'] = compacted;
      rowMap['setCount'] = storedSetCount - 1;
      rowList[rowPos] = rowMap;

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

  // ── deleteExercise (Phase 13) ─────────────────────────────────────────────

  @override
  Future<void> deleteExercise({
    required String uid,
    required DateTime date,
    required String exerciseId,
  }) async {
    // Any write to this day can change progression history for
    // this athlete. Mark the day dirty so the next history
    // hydration re-reads ONE document instead of everything.
    ProgressionHistoryStore.instance
        .markDayDirty(uid: uid, date: date);
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));

    await _db.runTransaction((txn) async {
      final snap = await txn.get(docRef);
      if (!snap.exists) return;
      final data = snap.data() ?? <String, dynamic>{};

      final exercises = (data['exercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final wesPlanned = (data['wesPlannedExercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

      exercises.removeWhere((m) => m['exerciseId'] == exerciseId);
      wesPlanned.removeWhere((m) => m['exerciseId'] == exerciseId);

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

  // ── replaceExercise (Phase 13b) ───────────────────────────────────────────
  // Old row is removed from BOTH arrays regardless of which it was in.
  // New blank row is always appended to wesPlannedExercises[] — never
  // exercises[], which is reserved for rows with actual logged values.
  // The existing saveFieldPatch promote-path will move it to exercises[] when
  // the user enters the first actual value.

  @override
  Future<void> replaceExercise({
    required String uid,
    required DateTime date,
    required String oldExerciseId,
    required String newExerciseId,
    required String newName,
  }) async {
    // Any write to this day can change progression history for
    // this athlete. Mark the day dirty so the next history
    // hydration re-reads ONE document instead of everything.
    ProgressionHistoryStore.instance
        .markDayDirty(uid: uid, date: date);
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));

    await _db.runTransaction((txn) async {
      final snap = await txn.get(docRef);
      if (!snap.exists) return;
      final data = snap.data() ?? <String, dynamic>{};

      final exercises = (data['exercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final wesPlanned = (data['wesPlannedExercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

      // Find old row in whichever array it lives in.
      final exIdx =
          exercises.indexWhere((m) => m['exerciseId'] == oldExerciseId);
      final wpIdx =
          wesPlanned.indexWhere((m) => m['exerciseId'] == oldExerciseId);

      // No-op if old row is not materialised in either array.
      if (exIdx == -1 && wpIdx == -1) return;

      // Preserve placement/count metadata from whichever array holds the row.
      final oldMap = exIdx != -1 ? exercises[exIdx] : wesPlanned[wpIdx];
      final circuitIndex = (oldMap['circuitIndex'] as num?)?.toInt() ?? 0;
      final orderIndex = (oldMap['orderIndex'] as num?)?.toInt() ?? 0;
      final setCount = (oldMap['setCount'] as num?)?.toInt() ?? 3;

      // No-op if newExerciseId already exists in either array under a
      // different row (same-id replace is harmless but still clears sets).
      final duplicateNewExists =
          exercises.any((m) => m['exerciseId'] == newExerciseId &&
              m['exerciseId'] != oldExerciseId) ||
          wesPlanned.any((m) => m['exerciseId'] == newExerciseId &&
              m['exerciseId'] != oldExerciseId);
      if (duplicateNewExists) return;

      // Remove old row from BOTH arrays.
      exercises.removeWhere((m) => m['exerciseId'] == oldExerciseId);
      wesPlanned.removeWhere((m) => m['exerciseId'] == oldExerciseId);

      // Append blank replacement row to wesPlannedExercises[] only.
      // exercises[] must only contain rows with actual logged values.
      wesPlanned.add({
        'exerciseId': newExerciseId,
        'name': newName,
        'circuitIndex': circuitIndex,
        'orderIndex': orderIndex,
        'setCount': setCount,
        'sets': <Map<String, dynamic>>[],
      });

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

  // ── saveExecutionNote (Phase 16) ─────────────────────────────────────────

  @override
  Future<void> saveExecutionNote({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String? note,
  }) async {
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));

    await _db.runTransaction((txn) async {
      final snap = await txn.get(docRef);
      if (!snap.exists) return;
      final data = snap.data() ?? <String, dynamic>{};

      final exercises = (data['exercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final wesPlanned = (data['wesPlannedExercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

      final exIdx = exercises.indexWhere((m) => m['exerciseId'] == exerciseId);
      final wpIdx =
          wesPlanned.indexWhere((m) => m['exerciseId'] == exerciseId);

      if (exIdx == -1 && wpIdx == -1) return; // unmaterialized row — no-op

      if (exIdx != -1) {
        exercises[exIdx] =
            _patchStringFieldInRow(exercises[exIdx], setIndex, 'executionNote', note);
      } else {
        wesPlanned[wpIdx] =
            _patchStringFieldInRow(wesPlanned[wpIdx], setIndex, 'executionNote', note);
      }

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

  /// Patches an arbitrary string field on one set inside an existing row map.
  /// Locates the set by stored setIndex key (preferred) or array index (legacy).
  /// Preserves all other fields. [value] null removes the key.
  static Map<String, dynamic> _patchStringFieldInRow(
    Map<String, dynamic> rowMap,
    int setIndex,
    String fieldKey,
    String? value,
  ) {
    final result = Map<String, dynamic>.from(rowMap);
    final rawSets = ((result['sets'] as List<dynamic>?) ?? [])
        .map((s) => s is Map<String, dynamic>
            ? Map<String, dynamic>.from(s)
            : <String, dynamic>{})
        .toList();

    int? arrayPos;
    for (int i = 0; i < rawSets.length; i++) {
      final stored = (rawSets[i]['setIndex'] as num?)?.toInt();
      if (stored != null) {
        if (stored == setIndex) {
          arrayPos = i;
          break;
        }
      } else {
        if (i == setIndex) {
          arrayPos = i;
          break;
        }
      }
    }

    if (arrayPos != null) {
      final updated = Map<String, dynamic>.from(rawSets[arrayPos]);
      if (value == null) {
        updated.remove(fieldKey);
      } else {
        updated[fieldKey] = value;
      }
      rawSets[arrayPos] = updated;
    } else if (value != null) {
      while (rawSets.length <= setIndex) {
        rawSets.add(<String, dynamic>{'setIndex': rawSets.length});
      }
      rawSets[setIndex] = Map<String, dynamic>.from(rawSets[setIndex])
        ..[fieldKey] = value;
    }

    final existingCount = (result['setCount'] as num?)?.toInt() ?? 0;
    result['setCount'] =
        (setIndex + 1) > existingCount ? (setIndex + 1) : existingCount;
    result['sets'] = rawSets;
    return result;
  }

  // ── saveExerciseExecutionNote ─────────────────────────────────────────────

  @override
  Future<void> saveExerciseExecutionNote({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required String? note,
  }) async {
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));

    await _db.runTransaction((txn) async {
      final snap = await txn.get(docRef);
      if (!snap.exists) return;
      final data = snap.data() ?? <String, dynamic>{};

      final exercises = (data['exercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final wesPlanned = (data['wesPlannedExercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

      final exIdx = exercises.indexWhere((m) => m['exerciseId'] == exerciseId);
      final wpIdx =
          wesPlanned.indexWhere((m) => m['exerciseId'] == exerciseId);

      if (exIdx == -1 && wpIdx == -1) return; // unmaterialized — no-op

      if (exIdx != -1) {
        if (note == null) {
          exercises[exIdx].remove('exerciseExecutionNote');
        } else {
          exercises[exIdx]['exerciseExecutionNote'] = note;
        }
      } else {
        if (note == null) {
          wesPlanned[wpIdx].remove('exerciseExecutionNote');
        } else {
          wesPlanned[wpIdx]['exerciseExecutionNote'] = note;
        }
      }

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

  // ── replaceAllWithTemplateRows (Phase 18) ──────────────────────────────

  @override
  Future<void> replaceAllWithTemplateRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
  }) async {
    // Any write to this day can change progression history for
    // this athlete. Mark the day dirty so the next history
    // hydration re-reads ONE document instead of everything.
    ProgressionHistoryStore.instance
        .markDayDirty(uid: uid, date: date);
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));
    final wesPlannedMaps = rows.map(_buildWesPlannedRowMap).toList();
    await docRef.set(
      {
        'userId': uid,
        'date': _dateDocId(date),
        'lastEditedAt': FieldValue.serverTimestamp(),
        'exercises': <Map<String, dynamic>>[],
        'wesPlannedExercises': wesPlannedMaps,
      },
      SetOptions(merge: true),
    );
  }

  // ── deleteAllExercisesForDay (Phase 18b) ─────────────────────────────────

  @override
  Future<void> deleteAllExercisesForDay({
    required String uid,
    required DateTime date,
  }) async {
    // Any write to this day can change progression history for
    // this athlete. Mark the day dirty so the next history
    // hydration re-reads ONE document instead of everything.
    ProgressionHistoryStore.instance
        .markDayDirty(uid: uid, date: date);
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));
    await docRef.set(
      {
        'userId': uid,
        'date': _dateDocId(date),
        'lastEditedAt': FieldValue.serverTimestamp(),
        'exercises': <Map<String, dynamic>>[],
        'wesPlannedExercises': <Map<String, dynamic>>[],
      },
      SetOptions(merge: true),
    );
  }

  // ── moveExerciseToCircuit (Phase 13) ──────────────────────────────────────

  @override
  Future<void> moveExerciseToCircuit({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int targetCircuitIndex,
  }) async {
    // Any write to this day can change progression history for
    // this athlete. Mark the day dirty so the next history
    // hydration re-reads ONE document instead of everything.
    ProgressionHistoryStore.instance
        .markDayDirty(uid: uid, date: date);
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date));

    await _db.runTransaction((txn) async {
      final snap = await txn.get(docRef);
      if (!snap.exists) return;
      final data = snap.data() ?? <String, dynamic>{};

      final exercises = (data['exercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final wesPlanned = (data['wesPlannedExercises'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

      final exIdx = exercises.indexWhere((m) => m['exerciseId'] == exerciseId);
      final wpIdx = wesPlanned.indexWhere((m) => m['exerciseId'] == exerciseId);

      if (exIdx != -1) {
        exercises[exIdx] = Map<String, dynamic>.from(exercises[exIdx])
          ..['circuitIndex'] = targetCircuitIndex;
      } else if (wpIdx != -1) {
        wesPlanned[wpIdx] = Map<String, dynamic>.from(wesPlanned[wpIdx])
          ..['circuitIndex'] = targetCircuitIndex;
      }

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
}
