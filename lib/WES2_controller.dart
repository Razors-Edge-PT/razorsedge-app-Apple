import 'package:flutter/foundation.dart';
import 'WES2_models.dart';

enum Wes2LoadState { idle, loading, loaded, empty }

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
  bool _disposed = false;

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

  // ── Identity ─────────────────────────────────────────────────────────────

  void initIdentity({
    required String actorUid,
    required String actingUid,
    required bool isCoach,
  }) {
    if (_identityInitialized) return;
    _identityInitialized = true;
    _actorUid = actorUid;
    _actingUid = actingUid;
    _isCoach = isCoach;
    _beginLoad();
  }

  // ── Date navigation ───────────────────────────────────────────────────────

  void changeDate(DateTime date) {
    _selectedDate = DateTime(date.year, date.month, date.day);
    _rows = [];
    _undoStack.clear();
    _beginLoad();
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

  // ── Load (stub — replaced in Phase 2) ────────────────────────────────────

  void _beginLoad() {
    _loadState = Wes2LoadState.loading;
    // Simulate empty day after a brief pause. Phase 2 replaces this with
    // real Firestore + Isar loading.
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (_disposed) return;
      _loadState = Wes2LoadState.empty;
      notifyListeners();
    });
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
