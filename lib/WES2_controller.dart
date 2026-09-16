import 'package:flutter/foundation.dart';
import 'WES2_hint_service.dart';
import 'WES2_models.dart';
import 'wes2_field_parser.dart';
import 'wes2_hint_trace.dart';
import 'wes2_video/set_identity.dart';

enum Wes2LoadState { idle, loading, loaded, empty, error }

/// Central session state for one WES2 day.
/// Owns selected date, exercise rows, undo stack, and loading state.
/// Identity is always date + exerciseId; row-index is never used as a key.
class Wes2SessionController extends ChangeNotifier {
  DateTime _selectedDate;
  String _actorUid = '';
  String _actingUid = '';
  bool _isCoach = false;
  Wes2LoadState _loadState = Wes2LoadState.idle;
  List<Wes2ExerciseRow> _rows = [];
  final List<List<Wes2ExerciseRow>> _undoStack = [];
  bool _identityInitialized = false;
  String? _activeBlockId;
  DateTime? _blockStartDate;
  DateTime? _blockEndDate;
  Map<String, dynamic> _exerciseSettings = const {};
  Wes2HintService? _hintService;
  // Positional BB3 prescriptions per exercise. The ONLY source of prescription
  // authority: a row's current hintValue is output, never input.
  Map<String, Wes2Prescriptions> _prescriptions = <String, Wes2Prescriptions>{};
  int _loadEpoch = 0;
  String? _loadErrorMessage;
  final List<({String exerciseId, String name})> _pendingExerciseAdds = [];
  final List<Wes2ExerciseRow> _flushedExercises = [];
  // Session-local set of plan-note keys that have been read.
  // Key format: "$exerciseId:$setIndex". Cleared on date change.
  final Set<String> _readPlanNotes = {};
  // Session-local set of exerciseIds whose exercise-level plan note has been read.
  final Set<String> _readExercisePlanNotes = {};

  Wes2SessionController(DateTime initialDate)
      : _selectedDate = DateTime(
          initialDate.year,
          initialDate.month,
          initialDate.day,
        );

  // ── Getters ──────────────────────────────────────────────────────────────

  DateTime get selectedDate => _selectedDate;
  String get actorUid => _actorUid;
  String get actingUid => _actingUid;
  bool get isCoach => _isCoach;
  Wes2LoadState get loadState => _loadState;
  List<Wes2ExerciseRow> get rows => List.unmodifiable(_rows);
  bool get canUndo => _undoStack.isNotEmpty;
  int get loadEpoch => _loadEpoch;
  String? get activeBlockId => _activeBlockId;
  DateTime? get blockStartDate => _blockStartDate;
  DateTime? get blockEndDate => _blockEndDate;
  String? get loadErrorMessage => _loadErrorMessage;
  bool get hasPendingExerciseAdds => _pendingExerciseAdds.isNotEmpty;

  // ── Identity ─────────────────────────────────────────────────────────────

  void initIdentity({
    required String actorUid,
    required String actingUid,
    required bool isCoach,
    String? activeBlockId,
    DateTime? blockStartDate,
    DateTime? blockEndDate,
  }) {
    if (_identityInitialized) return;
    _identityInitialized = true;
    _actorUid = actorUid;
    _actingUid = actingUid;
    _isCoach = isCoach;
    _activeBlockId = activeBlockId;
    _blockStartDate = blockStartDate;
    _blockEndDate = blockEndDate;
    // Load is triggered by the screen via beginLoad() after this returns.
  }

  /// Store block-level exerciseSettings for use by the hint service.
  void setExerciseSettings(Map<String, dynamic> settings) {
    _exerciseSettings = settings;
  }

  Map<String, dynamic> get exerciseSettings => _exerciseSettings;

  /// Register the hint service for same-set real-time recalculation.
  /// Called once per day load after exerciseSettings are fetched.
  void setHintService(Wes2HintService service, String blockId) {
    _hintService = service;
  }

  /// Installs the positional BB3 prescriptions for the day.
  ///
  /// Prescriptions are held here, apart from the rows, because a row's
  /// `hintValue` is calculation OUTPUT. Reading prescriptions back out of it
  /// is what let a generated — or draft-recovered — number act as a BB3 lock.
  void setPrescriptions(Map<String, Wes2Prescriptions> byExerciseId,
      {bool recompute = true}) {
    _prescriptions = Map<String, Wes2Prescriptions>.from(byExerciseId);
    if (recompute && _hintService != null) {
      _recomputeAll();
      notifyListeners();
    }
  }

  Wes2Prescriptions prescriptionsFor(String exerciseId) =>
      _prescriptions[exerciseId] ?? Wes2Prescriptions.none;

  /// Applies a freshly built hint context: registers the service and resolves
  /// every row once, from the CURRENT entries and structure, with a single
  /// assignment and a single notification.
  void applyHintContext(Wes2HintService service, String blockId,
      {Map<String, Wes2Prescriptions>? prescriptions}) {
    _hintService = service;
    if (prescriptions != null) {
      _prescriptions = Map<String, Wes2Prescriptions>.from(prescriptions);
    }
    _recomputeAll();
    notifyListeners();
  }

  // ── Load state management ─────────────────────────────────────────────────

  /// Increments the load epoch, transitions to loading, notifies listeners,
  /// and returns the new epoch value. The caller must pass this epoch into
  /// [setRows] or [setLoadError] — stale async callbacks that carry a
  /// mismatched epoch are silently discarded.
  int beginLoad() {
    _loadEpoch++;
    _loadState = Wes2LoadState.loading;
    _loadErrorMessage = null;
    notifyListeners();
    return _loadEpoch;
  }

  /// Apply freshly loaded rows. No-op if [epoch] no longer matches.
  void setRows(List<Wes2ExerciseRow> rows, int epoch) {
    if (epoch != _loadEpoch) return;
    _rows = rows;
    _recomputeAll();
    _loadState = rows.isEmpty ? Wes2LoadState.empty : Wes2LoadState.loaded;
    _loadErrorMessage = null;
    _originHadBb3Rows = rows.any((r) => r.source == Wes2RowSource.bb3Planned);
    _flushPendingAdds();
    notifyListeners();
  }

  /// Transition to error state with a message. No-op if [epoch] no longer matches.
  void setLoadError(String message, int epoch) {
    if (epoch != _loadEpoch) return;
    _loadState = Wes2LoadState.error;
    _loadErrorMessage = message;
    notifyListeners();
  }

  // ── Date navigation ───────────────────────────────────────────────────────

  /// Reset to a new date. Increments epoch to invalidate any in-flight loads
  /// for the previous date. Screen must call [beginLoad] then trigger its
  /// load method after this.
  void changeDate(DateTime date) {
    _selectedDate = DateTime(date.year, date.month, date.day);
    _rows = [];
    _undoStack.clear();
    _pendingExerciseAdds.clear();
    _flushedExercises.clear();
    _readPlanNotes.clear();
    _readExercisePlanNotes.clear();
    _prescriptions = <String, Wes2Prescriptions>{};
    _loadEpoch++;
    _loadState = Wes2LoadState.idle;
    _loadErrorMessage = null;
    _templateWasLoaded = false;
    _originHadBb3Rows = false;
    notifyListeners();
  }

  // ── Undo ──────────────────────────────────────────────────────────────────

  void undo() {
    if (_undoStack.isEmpty) return;
    _rows = _undoStack.removeLast();
    // A restored row re-cascades immediately, so recovered sets agree with a
    // fresh pass instead of keeping the hints they had before the removal.
    _recomputeAll();
    // Restore load state to match the recovered row count.
    _loadState = _rows.isEmpty ? Wes2LoadState.empty : Wes2LoadState.loaded;
    notifyListeners();
  }

  void _pushUndo() {
    _undoStack.add(List<Wes2ExerciseRow>.from(_rows));
    if (_undoStack.length > 50) _undoStack.removeAt(0);
  }

  // ── Field edits (Phase 6) ─────────────────────────────────────────────────

  /// Updates a single set field in local state only. No Firestore write.
  /// blank → clears actualValue (reveals hint)
  /// valid → updates actualValue
  /// invalid non-empty → no-op (model unchanged, no notifyListeners)
  void updateSetField({
    required String exerciseId,
    required int setIndex,
    required Wes2FieldKey fieldKey,
    required String rawText,
  }) {
    final text = rawText.trim();
    // Invalid non-empty text (a lone "-", "NaN", "1e3") leaves the model
    // exactly as it was: the athlete is mid-keystroke, and the last valid
    // number keeps driving the cascade until they finish.
    if (Wes2FieldParser.isInvalidEntry(fieldKey, text)) return;

    final rowIdx = _rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _rows[rowIdx];
    if (Wes2HintTrace.enabled) {
      Wes2HintTrace.log(
          'edit',
          'updateSetField "${row.name}" set=$setIndex field=${fieldKey.name} '
          'rawText="$rawText" hintServiceNull=${_hintService == null}',
          exerciseId: exerciseId);
    }
    final sets = List<Wes2SetState>.from(row.sets);
    while (sets.length <= setIndex) {
      sets.add(Wes2SetState(setIndex: sets.length));
    }
    sets[setIndex] = _applyFieldUpdate(sets[setIndex], fieldKey, text);
    final newRows = List<Wes2ExerciseRow>.from(_rows);
    newRows[rowIdx] = row.copyWith(sets: sets);
    _rows = newRows;
    // Sibling hints for THIS set first, then every later set from its result.
    // Earlier sets are untouched — an edit never reaches backwards.
    _recomputeRow(rowIdx, fromSet: setIndex);
    notifyListeners();
  }

  /// Recomputes [rowIdx] from [fromSet] onward and stores the result.
  ///
  /// The input is rebuilt from actuals + prescriptions only, so the row's own
  /// previous hints can never feed their own regeneration, and sets before
  /// [fromSet] are carried across untouched.
  void _recomputeRow(int rowIdx, {int fromSet = 0}) {
    final svc = _hintService;
    if (svc == null) return;
    final current = _rows[rowIdx];
    Wes2ExerciseRow resolved;
    try {
      resolved = svc.resolveRow(
        row: current,
        prescriptions: prescriptionsFor(current.exerciseId),
        uid: _actingUid,
        date: _selectedDate,
        fromSet: fromSet,
        existingFinals: current.sets,
      );
    } catch (e) {
      if (Wes2HintTrace.enabled) {
        Wes2HintTrace.log('recalc', '❌ resolveRow threw: $e',
            exerciseId: current.exerciseId);
      }
      return; // hint failure is non-fatal; typed values are unaffected
    }
    final newRows = List<Wes2ExerciseRow>.from(_rows);
    newRows[rowIdx] = resolved;
    _rows = newRows;
    if (Wes2HintTrace.enabled) {
      Wes2HintTrace.log(
          'recalc', 'from=$fromSet ${Wes2HintTrace.fmtRow(resolved)}',
          exerciseId: current.exerciseId);
    }
  }

  /// Recomputes every row in place. One assignment; the caller notifies.
  void _recomputeAll() {
    final svc = _hintService;
    if (svc == null) return;
    final List<Wes2ExerciseRow> next = <Wes2ExerciseRow>[];
    for (final row in _rows) {
      try {
        next.add(svc.resolveRow(
          row: row,
          prescriptions: prescriptionsFor(row.exerciseId),
          uid: _actingUid,
          date: _selectedDate,
        ));
      } catch (e) {
        if (Wes2HintTrace.enabled) {
          Wes2HintTrace.log('recalc', '❌ resolveRow threw: $e',
              exerciseId: row.exerciseId);
        }
        next.add(row);
      }
    }
    _rows = next;
  }

  static Wes2SetState _applyFieldUpdate(
    Wes2SetState set,
    Wes2FieldKey key,
    String text,
  ) {
    switch (key) {
      case Wes2FieldKey.weight:
        return set.copyWith(
          weight: set.weight.withActual(
            text.isEmpty
                ? null
                : Wes2FieldParser.valueOrNull(key, text) as double?,
          ),
        );
      case Wes2FieldKey.reps:
        return set.copyWith(
          reps: set.reps.withActual(
            text.isEmpty
                ? null
                : Wes2FieldParser.valueOrNull(key, text) as int?,
          ),
        );
      case Wes2FieldKey.rir:
        return set.copyWith(
          rir: set.rir.withActual(
            text.isEmpty
                ? null
                : Wes2FieldParser.valueOrNull(key, text) as double?,
          ),
        );
      case Wes2FieldKey.velocity:
        return set.copyWith(
          velocity: set.velocity.withActual(
            text.isEmpty
                ? null
                : Wes2FieldParser.valueOrNull(key, text) as double?,
          ),
        );
    }
  }

  // ── Done state (Phase 9) ──────────────────────────────────────────────────

  void toggleMarkedDone(String exerciseId, bool isDone) {
    final idx = _rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (idx == -1) return;
    final newRows = List<Wes2ExerciseRow>.from(_rows);
    newRows[idx] = _rows[idx].copyWith(isMarkedDone: isDone);
    _rows = newRows;
    notifyListeners();
  }

  // ── Add Set (Phase 10) ────────────────────────────────────────────────────

  /// Appends one blank set to the exercise in memory.
  /// newSetIndex = max(setCount, highest stored setIndex + 1) so sparse
  /// in-memory sets from prior updateSetField calls are never overwritten.
  /// setCount is incremented to newSetIndex + 1 and never shrinks.
  void addSet(String exerciseId) {
    final rowIdx = _rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    _pushUndo();
    final row = _rows[rowIdx];

    final highestStored = row.sets.fold(
      -1,
      (int m, Wes2SetState s) => s.setIndex > m ? s.setIndex : m,
    );
    final newSetIndex =
        highestStored + 1 > row.setCount ? highestStored + 1 : row.setCount;
    final newSetCount = newSetIndex + 1;

    final sets = List<Wes2SetState>.from(row.sets);
    while (sets.length <= newSetIndex) {
      sets.add(Wes2SetState(setIndex: sets.length));
    }

    final newRows = List<Wes2ExerciseRow>.from(_rows);
    newRows[rowIdx] = row.copyWith(
      sets: sets,
      setCount: newSetCount,
      // An added set is session structure: a later hint pass must not treat
      // the plan count as authoritative and drop it again.
      structureEstablished: true,
    );
    _rows = newRows;
    _recomputeRow(rowIdx, fromSet: newSetIndex);
    notifyListeners();
  }

  // ── Add Exercise (Phase 11) ───────────────────────────────────────────────

  /// Adds a new blank wes2Manual exercise row in memory.
  /// Returns false if [exerciseId] is already present — caller skips silently.
  /// If the day is still loading, queues the add for [setRows] to flush.
  bool addExercise(String exerciseId, String name, {int circuitIndex = 0}) {
    if (_rows.any((r) => r.exerciseId == exerciseId)) return false;
    if (_loadState == Wes2LoadState.loading ||
        _loadState == Wes2LoadState.idle) {
      if (!_pendingExerciseAdds.any((p) => p.exerciseId == exerciseId)) {
        _pendingExerciseAdds.add((exerciseId: exerciseId, name: name));
        notifyListeners();
      }
      return true;
    }
    _doAddExercise(exerciseId, name, circuitIndex: circuitIndex);
    notifyListeners();
    return true;
  }

  Wes2ExerciseRow _doAddExercise(String exerciseId, String name,
      {int circuitIndex = 0}) {
    _pushUndo();
    final nextOrder = _rows.isEmpty
        ? 0
        : _rows.map((r) => r.orderIndex).reduce((a, b) => a > b ? a : b) + 1;
    final newRow = Wes2ExerciseRow(
      exerciseId: exerciseId,
      name: name,
      circuitIndex: circuitIndex,
      orderIndex: nextOrder,
      setCount: 3,
      sets: const [],
      source: Wes2RowSource.wes2Manual,
    );
    _rows = [..._rows, newRow];
    // Empty-state day transitions to loaded once a row is added.
    if (_loadState == Wes2LoadState.empty) {
      _loadState = Wes2LoadState.loaded;
    }
    return newRow;
  }

  void _flushPendingAdds() {
    if (_pendingExerciseAdds.isEmpty) return;
    final pending =
        List<({String exerciseId, String name})>.from(_pendingExerciseAdds);
    _pendingExerciseAdds.clear();
    for (final p in pending) {
      if (_rows.any((r) => r.exerciseId == p.exerciseId)) continue;
      _flushedExercises.add(_doAddExercise(p.exerciseId, p.name));
    }
  }

  /// Returns and clears the list of rows applied from the pending queue.
  /// Screen calls this after setRows to persist flushed exercises to Firestore.
  List<Wes2ExerciseRow> consumeFlushedExercises() {
    final flushed = List<Wes2ExerciseRow>.from(_flushedExercises);
    _flushedExercises.clear();
    return flushed;
  }

  // ── Stable set identity ──────────────────────────────────────────────────

  /// Overridable so tests can mint deterministic ids.
  @visibleForTesting
  String Function() setIdGenerator = newWes2SetId;

  /// Returns the stable id of the set at [setIndex], minting one if the set
  /// does not already carry it. Returns null when the row or set is not found.
  ///
  /// Identity is minted LAZILY — only here, immediately before a recording is
  /// attached — rather than for every new set. Minting eagerly would turn every
  /// future set's showcase `setKey` into a uuid for every user, including those
  /// who never record a video, and a device still on an older build re-saving
  /// that workout would drop the field and flip the fingerprint back. Confining
  /// identity to sets that actually carry a video keeps that blast radius as
  /// small as the feature allows.
  ///
  /// Deliberately does NOT push undo: giving a set its identity is bookkeeping,
  /// not a user-visible edit, and must not consume an undo slot.
  String? ensureSetId(String exerciseId, int setIndex) {
    final rowIdx = _rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return null;
    final row = _rows[rowIdx];
    final i = row.sets.indexWhere((s) => s.setIndex == setIndex);
    if (i == -1) return null;

    final existing = row.sets[i].setId;
    if (existing != null && existing.trim().isNotEmpty) return existing;

    final minted = setIdGenerator();
    final sets = List<Wes2SetState>.from(row.sets);
    sets[i] = sets[i].copyWith(setId: minted);
    final newRows = List<Wes2ExerciseRow>.from(_rows);
    newRows[rowIdx] = row.copyWith(sets: sets);
    _rows = newRows;
    notifyListeners();
    return minted;
  }

  /// The stable id of a set, or null when it has none yet. Never mints.
  String? setIdAt(String exerciseId, int setIndex) {
    final rowIdx = _rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return null;
    final i = _rows[rowIdx].sets.indexWhere((s) => s.setIndex == setIndex);
    if (i == -1) return null;
    return _rows[rowIdx].sets[i].setId;
  }

  // ── Remove Set (Phase 14) ────────────────────────────────────────────────

  /// Removes the set at [setIndex] and compacts remaining sets so their
  /// setIndex equals their new position. No-op if the row has only one set —
  /// the screen routes that case to deleteExercise after confirmation.
  void removeSet(String exerciseId, int setIndex) {
    final rowIdx = _rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _rows[rowIdx];
    if (row.setCount <= 1) return;
    if (setIndex < 0 || setIndex >= row.setCount) return;

    _pushUndo();

    // Drop the target set; sort survivors by original setIndex; reindex to 0-based.
    final kept = row.sets
        .where((s) => s.setIndex != setIndex)
        .toList()
      ..sort((a, b) => a.setIndex.compareTo(b.setIndex));

    final compacted = List<Wes2SetState>.generate(kept.length, (i) {
      final s = kept[i];
      // Construct with updated setIndex; copyWith intentionally omits setIndex.
      // setId is carried across verbatim: compaction renumbers POSITIONS, and a
      // set's identity — and therefore any video attached to it — must not move
      // with them.
      return Wes2SetState(
        setIndex: i,
        setId: s.setId,
        weight: s.weight,
        reps: s.reps,
        rir: s.rir,
        velocity: s.velocity,
        executionNote: s.executionNote,
        planNote: s.planNote,
      );
    });

    final newRows = List<Wes2ExerciseRow>.from(_rows);
    newRows[rowIdx] = row.copyWith(
      sets: compacted,
      setCount: row.setCount - 1,
      // The surviving sets are now the session's structure.
      structureEstablished: true,
    );
    _rows = newRows;
    // The set that moved into the gap has a NEW predecessor, so it and every
    // set after it re-cascade now rather than on some later pass.
    _recomputeRow(rowIdx, fromSet: setIndex);
    notifyListeners();
  }

  // ── Structural mutations (Phase 13) ──────────────────────────────────────

  /// Removes an exercise row by exerciseId. Pushes undo first.
  /// No-op if exerciseId not found.
  void deleteExercise(String exerciseId) {
    final idx = _rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (idx == -1) return;
    _pushUndo();
    _rows = List<Wes2ExerciseRow>.from(_rows)..removeAt(idx);
    if (_rows.isEmpty) _loadState = Wes2LoadState.empty;
    notifyListeners();
  }

  /// Replaces an exercise row in-place, preserving circuitIndex and orderIndex.
  /// Pushes undo first. No-op if oldExerciseId not found or newExerciseId
  /// already exists (except when old == new).
  void replaceExercise({
    required String oldExerciseId,
    required String newExerciseId,
    required String newName,
  }) {
    final idx = _rows.indexWhere((r) => r.exerciseId == oldExerciseId);
    if (idx == -1) return;
    if (newExerciseId != oldExerciseId &&
        _rows.any((r) => r.exerciseId == newExerciseId)) {
      return;
    }
    _pushUndo();
    final old = _rows[idx];
    final newRow = Wes2ExerciseRow(
      exerciseId: newExerciseId,
      name: newName,
      circuitIndex: old.circuitIndex,
      orderIndex: old.orderIndex,
      setCount: old.setCount,
      sets: const [],
      source: old.source == Wes2RowSource.bb3Planned
          ? Wes2RowSource.bb3Planned
          : Wes2RowSource.wes2Manual,
    );
    final newRows = List<Wes2ExerciseRow>.from(_rows);
    newRows[idx] = newRow;
    _rows = newRows;
    _recomputeRow(idx);
    notifyListeners();
  }

  /// Moves an exercise row to a different circuit. Pushes undo first.
  /// No-op if exerciseId not found or already in targetCircuitIndex.
  void moveExerciseToCircuit(String exerciseId, int targetCircuitIndex) {
    final idx = _rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (idx == -1) return;
    if (_rows[idx].circuitIndex == targetCircuitIndex) return;
    _pushUndo();
    final newRows = List<Wes2ExerciseRow>.from(_rows);
    newRows[idx] = _rows[idx].copyWith(circuitIndex: targetCircuitIndex);
    _rows = newRows;
    notifyListeners();
  }

  // ── Notes (Phase 16) ──────────────────────────────────────────────────────

  /// Updates executionNote for a set in local state. No _pushUndo — note edits
  /// are not structural actions. Blank rawText clears the note (null).
  void updateExecutionNote({
    required String exerciseId,
    required int setIndex,
    required String rawText,
  }) {
    final text = rawText.trim();
    final rowIdx = _rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _rows[rowIdx];
    final sets = List<Wes2SetState>.from(row.sets);
    while (sets.length <= setIndex) {
      sets.add(Wes2SetState(setIndex: sets.length));
    }
    final s = sets[setIndex];
    // Construct directly to allow clearing (null) without a copyWith sentinel.
    sets[setIndex] = Wes2SetState(
      setIndex: s.setIndex,
      setId: s.setId,
      weight: s.weight,
      reps: s.reps,
      rir: s.rir,
      velocity: s.velocity,
      executionNote: text.isEmpty ? null : text,
      planNote: s.planNote,
    );
    final newRows = List<Wes2ExerciseRow>.from(_rows);
    newRows[rowIdx] = row.copyWith(sets: sets);
    _rows = newRows;
    notifyListeners();
  }

  /// Updates exerciseExecutionNote for an exercise in local state. No _pushUndo.
  /// Blank rawText clears the note (null). Direct construction mirrors the
  /// per-set updateExecutionNote pattern — clearExerciseExecutionNote avoids
  /// the copyWith null-coalescing limitation.
  void updateExerciseExecutionNote({
    required String exerciseId,
    required String rawText,
  }) {
    final text = rawText.trim();
    final rowIdx = _rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _rows[rowIdx];
    final newRows = List<Wes2ExerciseRow>.from(_rows);
    newRows[rowIdx] = row.copyWith(
      exerciseExecutionNote: text.isEmpty ? null : text,
      clearExerciseExecutionNote: text.isEmpty,
    );
    _rows = newRows;
    notifyListeners();
  }

  /// Returns true if the plan note for this set has been read this session.
  bool isPlanNoteRead(String exerciseId, int setIndex) =>
      _readPlanNotes.contains('$exerciseId:$setIndex');

  /// Marks the plan note for this set as read. Notifies listeners so the
  /// note icon updates from amber to subdued immediately.
  void markPlanNoteRead(String exerciseId, int setIndex) {
    final key = '$exerciseId:$setIndex';
    if (_readPlanNotes.contains(key)) return;
    _readPlanNotes.add(key);
    notifyListeners();
  }

  bool isExercisePlanNoteRead(String exerciseId) =>
      _readExercisePlanNotes.contains(exerciseId);

  void markExercisePlanNoteRead(String exerciseId) {
    if (_readExercisePlanNotes.contains(exerciseId)) return;
    _readExercisePlanNotes.add(exerciseId);
    notifyListeners();
  }

  // ── Template tracking (Phase 18) ────────────────────────────────────────

  bool _templateWasLoaded = false;
  bool _originHadBb3Rows = false;

  bool get templateWasLoaded => _templateWasLoaded;

  /// True when all eligibility conditions for Save Workout to Templates hold.
  bool get canSaveAsTemplate {
    if (_rows.isEmpty) return false;
    if (_templateWasLoaded) return false;
    if (_originHadBb3Rows) return false;
    if (!_rows.every((r) => r.isMarkedDone)) return false;
    if (_rows.any((r) => r.source == Wes2RowSource.bb3Planned)) return false;
    return true;
  }

  /// Replace all current rows with template rows in one undo-able step.
  void replaceWithTemplateRows(List<Wes2ExerciseRow> templateRows) {
    _pushUndo();
    _rows = List<Wes2ExerciseRow>.from(templateRows);
    _recomputeAll();
    _templateWasLoaded = true;
    _loadState = _rows.isEmpty ? Wes2LoadState.empty : Wes2LoadState.loaded;
    notifyListeners();
  }

  /// Delete all exercise rows for the current day in one undo-able step.
  void deleteAllExercises() {
    if (_rows.isEmpty) return;
    _pushUndo();
    _rows = [];
    _loadState = Wes2LoadState.empty;
    _templateWasLoaded = false;
    _originHadBb3Rows = false;
    notifyListeners();
  }
}
