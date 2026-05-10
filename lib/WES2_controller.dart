import 'package:flutter/foundation.dart';
import 'WES2_hint_service.dart';
import 'WES2_models.dart';

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
  String? _hintBlockId;
  // Per-exercise snapshot of rows immediately after initial hint application.
  // Same-set recalculation rebuilds from this baseline so clearing actuals
  // always restores the original loaded hints.
  Map<String, Wes2ExerciseRow> _baselineHintRows = {};
  int _loadEpoch = 0;
  String? _loadErrorMessage;
  final List<({String exerciseId, String name})> _pendingExerciseAdds = [];
  final List<Wes2ExerciseRow> _flushedExercises = [];
  // Session-local set of plan-note keys that have been read.
  // Key format: "$exerciseId:$setIndex". Cleared on date change.
  final Set<String> _readPlanNotes = {};

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
    _hintBlockId = blockId;
  }

  /// Snapshot the current rows as the hint baseline.
  /// Called once after all initial applyModelHints() calls complete so that
  /// same-set recalculation can restore original hints when actuals are cleared.
  void captureBaselineHintRows() {
    _baselineHintRows = {for (final r in _rows) r.exerciseId: r};
  }

  /// Returns the original planned/model RIR hint value for [setIndex] of
  /// [exerciseId] as captured at load time.  Used by Wes2SetRow to compute
  /// the Phase 21F RIR direction cue without exposing the full baseline map.
  double? baselineRirHintFor(String exerciseId, int setIndex) {
    final baselineRow = _baselineHintRows[exerciseId];
    if (baselineRow == null) return null;
    if (setIndex >= baselineRow.sets.length) return null;
    return baselineRow.sets[setIndex].rir.hintValue;
  }

  /// Apply model hints from a pre-computed hinted row onto the current row state.
  /// Uses the CURRENT row (not a snapshot) to avoid overwriting actuals typed
  /// between hint computation and application.
  /// BB3-origin hints on the current row are preserved — they take priority.
  void applyModelHints(String exerciseId, Wes2ExerciseRow hintedRow) {
    final idx = _rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (idx == -1) return;
    final current = _rows[idx];
    final count = current.setCount;
    bool changed = false;
    final newSets = List<Wes2SetState>.generate(count, (i) {
      final cs =
          i < current.sets.length ? current.sets[i] : Wes2SetState(setIndex: i);
      final hs = i < hintedRow.sets.length ? hintedRow.sets[i] : null;
      if (hs == null) return cs;
      final nw = cs.weight.withHint(hs.weight.hintValue, hs.weight.hintOrigin);
      final nr = cs.reps.withHint(hs.reps.hintValue, hs.reps.hintOrigin);
      final nrir = cs.rir.withHint(hs.rir.hintValue, hs.rir.hintOrigin);
      if (nw == cs.weight && nr == cs.reps && nrir == cs.rir) return cs;
      changed = true;
      return cs.copyWith(weight: nw, reps: nr, rir: nrir);
    });
    if (!changed) return;
    final newRows = List<Wes2ExerciseRow>.from(_rows);
    newRows[idx] = current.copyWith(sets: newSets);
    _rows = newRows;
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
    _baselineHintRows = {};
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
    _baselineHintRows = {};
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
    if (text.isNotEmpty && !_canParse(fieldKey, text)) return;

    final rowIdx = _rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _rows[rowIdx];
    final sets = List<Wes2SetState>.from(row.sets);
    while (sets.length <= setIndex) {
      sets.add(Wes2SetState(setIndex: sets.length));
    }
    sets[setIndex] = _applyFieldUpdate(sets[setIndex], fieldKey, text);
    final newRows = List<Wes2ExerciseRow>.from(_rows);
    newRows[rowIdx] = row.copyWith(sets: sets);
    _rows = newRows;
    // Phase 21C: same-set hint recalculation (synchronous).
    _applyHintsForRow(rowIdx);
    notifyListeners();
  }

  /// Recomputes hints for row at [rowIdx] using the registered hint service
  /// and merges the results into [_rows]. No-op when no service is registered.
  ///
  /// Builds the recalculation input from the baseline hint row overlaid with
  /// the current actual values so clearing actuals always restores original hints.
  void _applyHintsForRow(int rowIdx) {
    final svc = _hintService;
    final blockId = _hintBlockId;
    if (svc == null || blockId == null) return;
    final current = _rows[rowIdx];
    final baseline = _baselineHintRows[current.exerciseId];
    final rowForRecalc = baseline != null
        ? _rowWithCurrentActualsOverBaseline(current, baseline)
        : current;
    Wes2ExerciseRow hinted;
    try {
      hinted = svc.computeRowHints(
        row: rowForRecalc,
        blockId: blockId,
        uid: _actingUid,
        date: _selectedDate,
      );
    } catch (_) {
      return; // hint failure is non-fatal; typed values are unaffected
    }
    _mergeHintsIntoRow(rowIdx, hinted);
  }

  /// Returns true when [actual] equals [hint] within floating-point tolerance.
  /// Suppresses same-value constraints so BB3HintService sees the value as
  /// unconstrained and solves siblings identically to the initial hint pass.
  static bool _sameAsHint(double? actual, double? hint) {
    if (actual == null || hint == null) return false;
    return (actual - hint).abs() < 0.001;
  }

  static bool _sameAsHintInt(int? actual, int? hint) {
    if (actual == null || hint == null) return false;
    return actual == hint;
  }

  /// Builds a row that combines [baseline] hint values/origins with
  /// [current] actual values. Direct field construction avoids the
  /// withActual(null) origin mis-labeling that would treat stale model hints
  /// as BB3 constraints on subsequent recalculation.
  ///
  /// Same-value actuals (where the user accepted a displayed hint verbatim)
  /// are suppressed so that BB3HintService solves siblings using the same
  /// unconstrained path it used during the initial hint pass.
  static Wes2ExerciseRow _rowWithCurrentActualsOverBaseline(
      Wes2ExerciseRow current, Wes2ExerciseRow baseline) {
    final count = current.setCount > baseline.setCount
        ? current.setCount
        : baseline.setCount;
    final newSets = List<Wes2SetState>.generate(count, (i) {
      final cs =
          i < current.sets.length ? current.sets[i] : Wes2SetState(setIndex: i);
      final bs =
          i < baseline.sets.length ? baseline.sets[i] : Wes2SetState(setIndex: i);
      // Suppress actuals that equal the baseline hint — the user accepted the
      // displayed value without changing it. Passing the same numeric value as
      // a hard constraint changes BB3HintService's solving path and produces
      // different sibling hints than the unconstrained initial pass.
      final weightActual = _sameAsHint(cs.weight.actualValue, bs.weight.hintValue)
          ? null
          : cs.weight.actualValue;
      final repsActual = _sameAsHintInt(cs.reps.actualValue, bs.reps.hintValue)
          ? null
          : cs.reps.actualValue;
      final rirActual = _sameAsHint(cs.rir.actualValue, bs.rir.hintValue)
          ? null
          : cs.rir.actualValue;
      return Wes2SetState(
        setIndex: i,
        weight: Wes2FieldState<double>(
          actualValue: weightActual,
          hintValue: bs.weight.hintValue,
          hintOrigin: bs.weight.hintOrigin,
          origin: weightActual != null
              ? FieldOrigin.typed
              : bs.weight.hintOrigin,
          dirty: cs.weight.dirty,
          lastEditedAt: cs.weight.lastEditedAt,
        ),
        reps: Wes2FieldState<int>(
          actualValue: repsActual,
          hintValue: bs.reps.hintValue,
          hintOrigin: bs.reps.hintOrigin,
          origin: repsActual != null
              ? FieldOrigin.typed
              : bs.reps.hintOrigin,
          dirty: cs.reps.dirty,
          lastEditedAt: cs.reps.lastEditedAt,
        ),
        rir: Wes2FieldState<double>(
          actualValue: rirActual,
          hintValue: bs.rir.hintValue,
          hintOrigin: bs.rir.hintOrigin,
          origin: rirActual != null
              ? FieldOrigin.typed
              : bs.rir.hintOrigin,
          dirty: cs.rir.dirty,
          lastEditedAt: cs.rir.lastEditedAt,
        ),
        velocity: Wes2FieldState<double>(
          actualValue: cs.velocity.actualValue,
          hintValue: bs.velocity.hintValue,
          hintOrigin: bs.velocity.hintOrigin,
          origin: cs.velocity.actualValue != null
              ? FieldOrigin.typed
              : bs.velocity.hintOrigin,
          dirty: cs.velocity.dirty,
          lastEditedAt: cs.velocity.lastEditedAt,
        ),
        executionNote: cs.executionNote,
        planNote: bs.planNote ?? cs.planNote,
      );
    });
    return baseline.copyWith(
      sets: newSets,
      setCount: count,
      isMarkedDone: current.isMarkedDone,
      isExpanded: current.isExpanded,
    );
  }

  /// Merges hintValues from [hintedRow] into the row at [rowIdx].
  /// actualValues and executionNote/planNote are never changed.
  void _mergeHintsIntoRow(int rowIdx, Wes2ExerciseRow hintedRow) {
    final current = _rows[rowIdx];
    final count = current.setCount;
    final newSets = List<Wes2SetState>.generate(count, (i) {
      final cs =
          i < current.sets.length ? current.sets[i] : Wes2SetState(setIndex: i);
      final hs = i < hintedRow.sets.length ? hintedRow.sets[i] : null;
      if (hs == null) return cs;
      return cs.copyWith(
        weight: cs.weight.withHint(hs.weight.hintValue, hs.weight.hintOrigin),
        reps: cs.reps.withHint(hs.reps.hintValue, hs.reps.hintOrigin),
        rir: cs.rir.withHint(hs.rir.hintValue, hs.rir.hintOrigin),
        weightLockedByBb3OverrideCue: hs.weightLockedByBb3OverrideCue,
        repsLockedByBb3OverrideCue: hs.repsLockedByBb3OverrideCue,
        rirLockedByBb3OverrideCue: hs.rirLockedByBb3OverrideCue,
      );
    });
    final newRows = List<Wes2ExerciseRow>.from(_rows);
    newRows[rowIdx] = current.copyWith(sets: newSets);
    _rows = newRows;
  }

  static bool _canParse(Wes2FieldKey key, String text) {
    switch (key) {
      case Wes2FieldKey.weight:
        return double.tryParse(text) != null;
      case Wes2FieldKey.reps:
        return int.tryParse(text) != null;
      case Wes2FieldKey.rir:
        return double.tryParse(text) != null;
      case Wes2FieldKey.velocity:
        return double.tryParse(text) != null;
    }
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
            text.isEmpty ? null : double.tryParse(text),
          ),
        );
      case Wes2FieldKey.reps:
        return set.copyWith(
          reps: set.reps.withActual(
            text.isEmpty ? null : int.tryParse(text),
          ),
        );
      case Wes2FieldKey.rir:
        return set.copyWith(
          rir: set.rir.withActual(
            text.isEmpty ? null : double.tryParse(text),
          ),
        );
      case Wes2FieldKey.velocity:
        return set.copyWith(
          velocity: set.velocity.withActual(
            text.isEmpty ? null : double.tryParse(text),
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
    newRows[rowIdx] = row.copyWith(sets: sets, setCount: newSetCount);
    _rows = newRows;
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
      return Wes2SetState(
        setIndex: i,
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
    );
    _rows = newRows;
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
    _baselineHintRows.remove(exerciseId);
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
    _baselineHintRows.remove(oldExerciseId);
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
    _baselineHintRows = {};
    _templateWasLoaded = true;
    _loadState = _rows.isEmpty ? Wes2LoadState.empty : Wes2LoadState.loaded;
    notifyListeners();
  }

  /// Delete all exercise rows for the current day in one undo-able step.
  void deleteAllExercises() {
    if (_rows.isEmpty) return;
    _pushUndo();
    _rows = [];
    _baselineHintRows = {};
    _loadState = Wes2LoadState.empty;
    _templateWasLoaded = false;
    _originHadBb3Rows = false;
    notifyListeners();
  }
}
