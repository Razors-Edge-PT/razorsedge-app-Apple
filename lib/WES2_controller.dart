import 'package:flutter/foundation.dart';
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
  int _loadEpoch = 0;
  String? _loadErrorMessage;

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
  String? get loadErrorMessage => _loadErrorMessage;

  // ── Identity ─────────────────────────────────────────────────────────────

  void initIdentity({
    required String actorUid,
    required String actingUid,
    required bool isCoach,
    String? activeBlockId,
    DateTime? blockStartDate,
  }) {
    if (_identityInitialized) return;
    _identityInitialized = true;
    _actorUid = actorUid;
    _actingUid = actingUid;
    _isCoach = isCoach;
    _activeBlockId = activeBlockId;
    _blockStartDate = blockStartDate;
    // Load is triggered by the screen via beginLoad() after this returns.
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
    _loadState = rows.isEmpty ? Wes2LoadState.empty : Wes2LoadState.loaded;
    _loadErrorMessage = null;
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
    _loadEpoch++;
    _loadState = Wes2LoadState.idle;
    _loadErrorMessage = null;
    notifyListeners();
  }

  // ── Undo ──────────────────────────────────────────────────────────────────

  void undo() {
    if (_undoStack.isEmpty) return;
    _rows = _undoStack.removeLast();
    notifyListeners();
  }

  // ignore: unused_element — wired in Phase 7 when structural actions land
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
    notifyListeners();
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
}
