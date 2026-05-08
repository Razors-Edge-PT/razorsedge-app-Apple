import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'WES2_controller.dart';
import 'WES2_models.dart';
import 'WES2_plan_service.dart';
import 'WES2_repository.dart';
import 'WES2_widgets/WES2_day_header.dart';
import 'WES2_widgets/WES2_empty_state.dart';
import 'WES2_widgets/WES2_day_actions_row.dart';
import 'WES2_widgets/WES2_exercise_card.dart';
import 'WES2_widgets/WES2_exercise_picker.dart';
import 'WES2_local_store.dart';

/// WES2 beta route shell.
/// Receives an optional [initialDate]; defaults to today when omitted.
/// Accesses athlete identity via UserContext — never via FirebaseAuth directly.
class Wes2Screen extends StatefulWidget {
  final DateTime? initialDate;

  const Wes2Screen({super.key, this.initialDate});

  @override
  State<Wes2Screen> createState() => _Wes2ScreenState();
}

class _Wes2ScreenState extends State<Wes2Screen> with WidgetsBindingObserver {
  late final Wes2SessionController _controller;
  final Wes2Repository _repository = FirestoreWes2Repository();
  final Wes2PlanService _planService = FirestoreWes2PlanService();
  final Wes2LocalStore _localStore = IsarWes2LocalStore();
  bool _loadStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final raw = widget.initialDate ?? DateTime.now();
    _controller = Wes2SessionController(raw);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // listen: false — identity is read once; UserContext.currentUid is the
    // acting athlete UID, never FirebaseAuth.currentUser.uid directly.
    final uc = UserContext.of(context, listen: false);
    _controller.initIdentity(
      actorUid: uc.actorUid,
      actingUid: uc.currentUid,
      isCoach: uc.isCoach,
      activeBlockId: uc.activeBlockId,
      blockStartDate: uc.blockStartDate,
    );
    if (!_loadStarted) {
      _loadStarted = true;
      _loadDay();
    }
  }

  @override
  void dispose() {
    _saveDraftNow();
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _saveDraftNow();
    }
  }

  /// Fire-and-forget draft save. Returns void so it can be called from
  /// dispose/didChangeAppLifecycleState without an unawaited-future lint.
  void _saveDraftNow() {
    if (_controller.actingUid.isEmpty) return;
    // ignore: discarded_futures
    _localStore.saveDraft(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      rows: _controller.rows.toList(),
    );
  }

  /// Load completed workout + BB3 planned rows for the current date, then merge.
  /// beginLoad() increments the epoch; stale completions are discarded.
  Future<void> _loadDay() async {
    final epoch = _controller.beginLoad();
    try {
      // Phase 3: completed workout document (exercises[] + wesPlannedExercises[])
      final completedRows = await _repository.loadDay(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
      );

      // Phase 4: BB3 planned day — skip if block context is absent or if
      // selectedDate is before blockStartDate (no negative week/day paths).
      var bb3Rows = const <Wes2ExerciseRow>[];
      final blockId = _controller.activeBlockId;
      final blockStart = _controller.blockStartDate;
      if (blockId != null &&
          blockId.isNotEmpty &&
          blockStart != null &&
          !_isBeforeBlockStart(_controller.selectedDate, blockStart)) {
        final wd = _weekDayFromDate(blockStart, _controller.selectedDate);
        bb3Rows = await _planService.loadPlannedDay(
          uid: _controller.actingUid,
          blockId: blockId,
          weekIndex: wd.weekIndex,
          dayIndex: wd.dayIndex,
        );
      }

      // Phase 7: overlay local draft actuals onto server/BB3 merged structure.
      final draft = await _localStore.loadDraft(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
      );
      if (!mounted) return;
      _controller.setRows(
        _applyDraftActuals(_mergeRows(completedRows, bb3Rows), draft),
        epoch,
      );
      // Persist any exercises queued during loading, deduplicated against
      // freshly loaded server/BB3 data inside setRows/_flushPendingAdds.
      final flushed = _controller.consumeFlushedExercises();
      if (flushed.isNotEmpty) {
        _saveDraftNow();
        for (final row in flushed) {
          // ignore: discarded_futures
          _saveManualExerciseSilently(
            uid: _controller.actingUid,
            date: _controller.selectedDate,
            row: row,
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      _controller.setLoadError(e.toString(), epoch);
    }
  }

  /// Returns true if [date] (midnight-normalised) is strictly before
  /// [blockStart] (midnight-normalised). Prevents negative week/day indices.
  static bool _isBeforeBlockStart(DateTime date, DateTime blockStart) {
    final d = DateTime(date.year, date.month, date.day);
    final b = DateTime(blockStart.year, blockStart.month, blockStart.day);
    return d.isBefore(b);
  }

  /// Converts blockStart + selected date to BB3 weekIndex / dayIndex.
  /// Matches BB3PlannedExerciseService.dateToWeekDay logic; no import needed.
  static ({int weekIndex, int dayIndex}) _weekDayFromDate(
    DateTime blockStart,
    DateTime date,
  ) {
    final base = DateTime(blockStart.year, blockStart.month, blockStart.day);
    final sel = DateTime(date.year, date.month, date.day);
    final days = sel.difference(base).inDays;
    return (weekIndex: days ~/ 7, dayIndex: days % 7);
  }

  /// Merges completed + WES2-planned rows (Phase 3) with BB3 rows (Phase 4).
  /// Priority: completedServer → wes2Manual → bb3Planned.
  /// Deduplication by exerciseId via putIfAbsent. Sorted by orderIndex.
  static List<Wes2ExerciseRow> _mergeRows(
    List<Wes2ExerciseRow> completedRows,
    List<Wes2ExerciseRow> bb3Rows,
  ) {
    final seen = <String, Wes2ExerciseRow>{};
    for (final r in completedRows) {
      seen.putIfAbsent(r.exerciseId, () => r);
    }
    for (final r in bb3Rows) {
      seen.putIfAbsent(r.exerciseId, () => r);
    }
    return seen.values.toList()
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  }

  /// Overlays local draft actualValues onto the server/BB3 merged row list.
  /// Server/BB3 is structural authority: row presence, names, circuitIndex,
  /// orderIndex, source, and hintValues are always preserved from [merged].
  /// Draft rows not present in [merged] are dropped (orphan guard).
  /// draft actualValues and isMarkedDone are the only things restored.
  static List<Wes2ExerciseRow> _applyDraftActuals(
    List<Wes2ExerciseRow> merged,
    List<Wes2ExerciseRow>? draft,
  ) {
    if (draft == null || draft.isEmpty) return merged;
    final draftMap = <String, Wes2ExerciseRow>{
      for (final r in draft) r.exerciseId: r,
    };
    return merged.map((row) {
      final d = draftMap[row.exerciseId];
      if (d == null) return row;
      // Highest setIndex in draft that carries any actual value.
      // Using index rather than count handles sparse/higher-index edited sets
      // (e.g. set at index 4 typed without Add Set — count=1 but span=5).
      final highestDraftActualIdx = d.sets.fold(
        -1,
        (int m, Wes2SetState s) =>
            s.hasAnyActual && s.setIndex > m ? s.setIndex : m,
      );
      // effectiveCount = max of server setCount, draft setCount (preserves
      // blank added sets), and span required to reach the highest actual.
      final effectiveCount = [
        row.setCount,
        d.setCount,
        highestDraftActualIdx + 1,
      ].reduce((a, b) => a > b ? a : b);
      final overlaidSets = List.generate(effectiveCount, (i) {
        final serverSet =
            i < row.sets.length ? row.sets[i] : Wes2SetState(setIndex: i);
        final draftSet = i < d.sets.length ? d.sets[i] : null;
        if (draftSet == null) return serverSet;
        // Overlay only draft actualValues; server/BB3 hintValues are untouched.
        return serverSet.copyWith(
          weight: draftSet.weight.hasActual
              ? serverSet.weight.withActual(draftSet.weight.actualValue)
              : serverSet.weight,
          reps: draftSet.reps.hasActual
              ? serverSet.reps.withActual(draftSet.reps.actualValue)
              : serverSet.reps,
          rir: draftSet.rir.hasActual
              ? serverSet.rir.withActual(draftSet.rir.actualValue)
              : serverSet.rir,
          velocity: draftSet.velocity.hasActual
              ? serverSet.velocity.withActual(draftSet.velocity.actualValue)
              : serverSet.velocity,
        );
      });
      return row.copyWith(
        sets: overlaidSets,
        setCount: effectiveCount,
        isMarkedDone: d.isMarkedDone,
      );
    }).toList();
  }

  /// Called when any set field loses focus. Parses the raw text and fires a
  /// fire-and-forget Firestore field patch via [_saveFieldSilently].
  void _onFieldUnfocused(
    String exerciseId,
    int setIndex,
    Wes2FieldKey fieldKey,
    String rawText,
  ) {
    final text = rawText.trim();
    final dynamic value;
    if (text.isEmpty) {
      value = null; // blank → remove field from Firestore set map
    } else {
      value = _parseFieldValue(fieldKey, text);
      if (value == null) return; // invalid non-empty → skip save
    }
    final rowIdx =
        _controller.rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _controller.rows[rowIdx];
    // ignore: discarded_futures
    _saveFieldSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      row: row,
      setIndex: setIndex,
      fieldKey: fieldKey,
      value: value,
    );
  }

  /// Calls [_repository.saveFieldPatch] and silently swallows any error.
  /// UI state and local draft are intentionally left intact on failure.
  Future<void> _saveFieldSilently({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setIndex,
    required Wes2FieldKey fieldKey,
    required dynamic value,
  }) async {
    try {
      await _repository.saveFieldPatch(
        uid: uid,
        date: date,
        row: row,
        setIndex: setIndex,
        fieldKey: fieldKey,
        value: value,
      );
    } catch (_) {
      // Silent failure for Phase 8.
      // Retry queue and error indicator deferred to a future phase.
    }
  }

  void _onToggleMarkedDone(String exerciseId, bool isDone) {
    _controller.toggleMarkedDone(exerciseId, isDone);
    final rowIdx =
        _controller.rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _controller.rows[rowIdx];
    // ignore: discarded_futures
    _setMarkedDoneSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      row: row,
      isDone: isDone,
    );
  }

  Future<void> _setMarkedDoneSilently({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required bool isDone,
  }) async {
    try {
      await _repository.setMarkedDone(
        uid: uid,
        date: date,
        row: row,
        isDone: isDone,
      );
    } catch (e, st) {
      debugPrint('[WES2] setMarkedDone FAILED: $e\n$st');
    }
  }

  // ── Add Set (Phase 10) ────────────────────────────────────────────────────

  void _onAddSet(String exerciseId) {
    _controller.addSet(exerciseId);
    // Persist new setCount to local draft immediately so blank added sets
    // survive fast reopen, especially for BB3-planned rows where no Firestore
    // write occurs until the user types an actual value.
    _saveDraftNow();
    _showUndoSnackBar('Set added');

    final rowIdx =
        _controller.rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _controller.rows[rowIdx];

    // BB3-planned rows with no actuals are not yet materialised in the workout
    // document — skip Firestore until the first actual value is typed.
    if (row.source == Wes2RowSource.bb3Planned && !row.hasAnyExecutionValue) {
      return;
    }

    // ignore: discarded_futures
    _saveSetCountSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      row: row,
      setCount: row.setCount,
    );
  }

  Future<void> _saveSetCountSilently({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setCount,
  }) async {
    try {
      await _repository.saveSetCount(
        uid: uid,
        date: date,
        row: row,
        setCount: setCount,
      );
    } catch (_) {
      // Silent failure; local draft preserves setCount for next reopen.
    }
  }

  /// Parses [text] into the correct Dart type for [fieldKey].
  /// Returns null if [text] cannot be parsed (invalid non-empty input).
  static dynamic _parseFieldValue(Wes2FieldKey fieldKey, String text) {
    switch (fieldKey) {
      case Wes2FieldKey.weight:
        return double.tryParse(text);
      case Wes2FieldKey.reps:
        return int.tryParse(text);
      case Wes2FieldKey.rir:
        return double.tryParse(text);
      case Wes2FieldKey.velocity:
        return double.tryParse(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<Wes2SessionController>.value(
      value: _controller,
      child: Consumer<Wes2SessionController>(
        builder: (context, controller, _) => Scaffold(
          appBar: AppBar(
            title: const Text('WES2 (Beta)'),
            actions: [
              IconButton(
                icon: const Icon(Icons.undo),
                tooltip: 'Undo',
                onPressed: controller.canUndo ? _performUndo : null,
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: () {
                  _saveDraftNow();
                  _loadDay();
                },
              ),
              PopupMenuButton<VoidCallback>(
                icon: const Icon(Icons.more_vert),
                onSelected: (fn) => fn(),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: _showTimerPlaceholder,
                    child: const ListTile(
                      dense: true,
                      leading: Icon(Icons.timer_outlined),
                      title: Text('Timer'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _showTemplatesPlaceholder,
                    child: const ListTile(
                      dense: true,
                      leading: Icon(Icons.layers_outlined),
                      title: Text('Templates'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              Wes2DayHeader(
                date: controller.selectedDate,
                onSelectDate: _onSelectDate,
                onPrevDay: _onPrevDay,
                onNextDay: _onNextDay,
              ),
              const Divider(height: 1),
              Expanded(child: _buildBody(context, controller)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, Wes2SessionController controller) {
    // Error state: full-screen message, no action bar.
    if (controller.loadState == Wes2LoadState.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not load workout.\n${controller.loadErrorMessage ?? ''}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.red, fontSize: 14),
          ),
        ),
      );
    }
    // All non-error states show the top action bar so Add Exercise is always
    // reachable — including during loading (queues the add until data arrives).
    return Column(
      children: [
        Wes2TopActionsBar(onAddExercise: _onAddExercise),
        if (controller.hasPendingExerciseAdds &&
            (controller.loadState == Wes2LoadState.loading ||
                controller.loadState == Wes2LoadState.idle))
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              'Adding exercises when loaded…',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ),
        Expanded(child: _buildContentArea(context, controller)),
      ],
    );
  }

  Widget _buildContentArea(
      BuildContext context, Wes2SessionController controller) {
    switch (controller.loadState) {
      case Wes2LoadState.idle:
      case Wes2LoadState.loading:
        return const Center(child: Wes2WaitForIt());
      case Wes2LoadState.empty:
        return ListView(
          children: [
            const Wes2EmptyState(),
            Wes2BottomActionsRow(
              setsLogged: 0,
              onAddCircuit: _onAddCircuit,
            ),
          ],
        );
      case Wes2LoadState.loaded:
        final rows = controller.rows;
        final setsLogged =
            rows.expand((r) => r.sets).where((s) => s.hasAnyActual).length;

        // Build flat item list: circuit headers inserted when circuitIndex changes.
        final items = <Widget>[];
        int? prevCi;
        for (final row in rows) {
          if (prevCi == null || row.circuitIndex != prevCi) {
            final ci = row.circuitIndex;
            items.add(
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  children: [
                    Text(
                      'Circuit ${ci + 1}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text(
                        'Add Exercise',
                        style: TextStyle(fontSize: 12),
                      ),
                      onPressed: () => _onAddExerciseToCircuit(ci),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.primary,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
            );
            prevCi = ci;
          }
          items.add(Wes2ExerciseCard(
            row: row,
            onFieldUnfocused: _onFieldUnfocused,
            onToggleMarkedDone: (isDone) =>
                _onToggleMarkedDone(row.exerciseId, isDone),
            onAddSet: () => _onAddSet(row.exerciseId),
            onSettings: () => _showExerciseSettingsDialog(row),
            onDelete: () => _onDeleteExercise(row),
            onReplace: () => _onReplaceExercise(row),
            onMoveToCircuit: () => _onMoveExerciseToCircuit(row),
            onNotes: () => _showNotesPlaceholder(),
            onRemoveSet: (setIndex) => _onRemoveSet(row, setIndex),
          ));
        }

        items.add(Wes2BottomActionsRow(
          setsLogged: setsLogged,
          onAddCircuit: _onAddCircuit,
        ));
        return ListView(children: items);
      case Wes2LoadState.error:
        return const SizedBox.shrink(); // unreachable: handled in _buildBody
    }
  }

  // ── Add Exercise / Add Circuit (Phase 13) ────────────────────────────────

  /// Opens the picker and returns the selection including chosen circuit,
  /// or null if dismissed.
  /// [excludedIds] defaults to all current row IDs when omitted.
  /// [titleOverride] replaces the default "Add Exercise to Circuit N" header.
  Future<({String exerciseId, String name, int circuitIndex})?>
      _openExercisePicker({
    required List<int> availableCircuits,
    required int initialCircuitIndex,
    Set<String>? excludedIds,
    String? titleOverride,
  }) {
    final excluded =
        excludedIds ?? _controller.rows.map((r) => r.exerciseId).toSet();
    return showModalBottomSheet<
        ({String exerciseId, String name, int circuitIndex})>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => Wes2ExercisePicker(
        excludedIds: excluded,
        actingUid: _controller.actingUid,
        activeBlockId: _controller.activeBlockId,
        availableCircuits: availableCircuits,
        initialCircuitIndex: initialCircuitIndex,
        titleOverride: titleOverride,
      ),
    );
  }

  /// Applies a picker result to the controller, local draft, and Firestore.
  /// Immediate path: day loaded — persists via saveManualExercise now.
  /// Queue path (loading/idle): deferred to consumeFlushedExercises in _loadDay.
  void _addExerciseFromPicker(
      ({String exerciseId, String name, int circuitIndex}) result) {
    final added = _controller.addExercise(
      result.exerciseId,
      result.name,
      circuitIndex: result.circuitIndex,
    );
    if (!added) return;
    _saveDraftNow();
    _showUndoSnackBar('Exercise added');
    if (_controller.loadState == Wes2LoadState.loaded) {
      final rowIdx =
          _controller.rows.indexWhere((r) => r.exerciseId == result.exerciseId);
      if (rowIdx != -1) {
        // ignore: discarded_futures
        _saveManualExerciseSilently(
          uid: _controller.actingUid,
          date: _controller.selectedDate,
          row: _controller.rows[rowIdx],
        );
      }
    }
  }

  /// Top "Add Exercise" button — defaults to Circuit 1.
  /// Shows circuit selector inside picker when multiple circuits exist.
  Future<void> _onAddExercise() async {
    final circuits =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final result = await _openExercisePicker(
      availableCircuits: circuits,
      initialCircuitIndex: 0,
    );
    if (result == null) return;
    _addExerciseFromPicker(result);
  }

  /// Per-circuit header "Add Exercise" button — pre-selects that circuit.
  Future<void> _onAddExerciseToCircuit(int targetCircuitIndex) async {
    final circuits =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final result = await _openExercisePicker(
      availableCircuits: circuits,
      initialCircuitIndex: targetCircuitIndex,
    );
    if (result == null) return;
    _addExerciseFromPicker(result);
  }

  /// Bottom "Add Circuit" button — pre-selects a new circuit index.
  /// Passes existing circuits + new one so the user may redirect to any.
  Future<void> _onAddCircuit() async {
    if (_controller.loadState != Wes2LoadState.loaded) return;
    final existing =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final nextCircuitIndex = existing.isEmpty ? 0 : existing.last + 1;
    final result = await _openExercisePicker(
      availableCircuits: [...existing, nextCircuitIndex],
      initialCircuitIndex: nextCircuitIndex,
    );
    if (result == null) return;
    _addExerciseFromPicker(result);
  }

  Future<void> _saveManualExerciseSilently({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
  }) async {
    try {
      await _repository.saveManualExercise(
        uid: uid,
        date: date,
        row: row,
      );
    } catch (_) {
      // Silent failure; local draft preserves the row for next reopen.
    }
  }

  // ── Date navigation (Phase 13) ────────────────────────────────────────────

  void _onPrevDay() {
    _saveDraftNow();
    _controller
        .changeDate(_controller.selectedDate.subtract(const Duration(days: 1)));
    _loadDay();
  }

  void _onNextDay() {
    _saveDraftNow();
    _controller
        .changeDate(_controller.selectedDate.add(const Duration(days: 1)));
    _loadDay();
  }

  Future<void> _onSelectDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _controller.selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day + 365),
    );
    if (picked == null || !mounted) return;
    _saveDraftNow();
    _controller.changeDate(picked);
    _loadDay();
  }

  // ── Undo (Phase 15) ──────────────────────────────────────────────────────

  void _performUndo() {
    _controller.undo();
    _saveDraftNow();
  }

  void _showUndoSnackBar(String label) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(label),
          action: SnackBarAction(label: 'Undo', onPressed: _performUndo),
        ),
      );
  }

  // ── Snackbar / confirm helpers (Phase 13) ─────────────────────────────────

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _showConfirmDialog({
    required String title,
    required String content,
  }) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<int?> _showCircuitPickerDialog(List<int> circuits) async {
    if (!mounted) return null;
    return showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Move to Circuit'),
        children: circuits
            .map((ci) => SimpleDialogOption(
                  onPressed: () => Navigator.of(ctx).pop(ci),
                  child: Text('Circuit ${ci + 1}'),
                ))
            .toList(),
      ),
    );
  }

  // ── Placeholder dialogs (Phase 13) ────────────────────────────────────────

  void _showExerciseSettingsDialog(Wes2ExerciseRow row) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(row.name),
        content: const Text('Exercise settings coming soon.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showNotesPlaceholder() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Notes'),
        content: const Text('Exercise notes coming soon.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showTimerPlaceholder() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Timer'),
        content: const Text('Rest timer coming soon.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showTemplatesPlaceholder() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Templates'),
        content: const Text('Template loading coming soon.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ── Structural exercise actions (Phase 13) ────────────────────────────────

  Future<void> _onDeleteExercise(Wes2ExerciseRow row) async {
    if (row.source == Wes2RowSource.bb3Planned) {
      _showSnackBar(
          'BB3 planned exercises cannot be removed here. Use the Block Builder.');
      return;
    }
    final confirmed = await _showConfirmDialog(
      title: 'Delete Exercise',
      content: 'Remove "${row.name}" from today\'s workout?',
    );
    if (!confirmed) return;
    _controller.deleteExercise(row.exerciseId);
    _saveDraftNow();
    _showUndoSnackBar('Exercise deleted');
    // ignore: discarded_futures
    _deleteExerciseSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      exerciseId: row.exerciseId,
    );
  }

  Future<void> _onReplaceExercise(Wes2ExerciseRow row) async {
    if (row.source == Wes2RowSource.bb3Planned) {
      _showSnackBar(
          'BB3 planned exercises cannot be replaced here. Use the Block Builder.');
      return;
    }
    final excludedIds = _controller.rows
        .map((r) => r.exerciseId)
        .where((id) => id != row.exerciseId)
        .toSet();
    final circuits =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final result = await _openExercisePicker(
      availableCircuits: circuits,
      initialCircuitIndex: row.circuitIndex,
      excludedIds: excludedIds,
      titleOverride: 'Replace "${row.name}"',
    );
    if (result == null) return;
    _controller.replaceExercise(
      oldExerciseId: row.exerciseId,
      newExerciseId: result.exerciseId,
      newName: result.name,
    );
    _saveDraftNow();
    _showUndoSnackBar('Exercise replaced');
    // ignore: discarded_futures
    _replaceExerciseSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      oldExerciseId: row.exerciseId,
      newExerciseId: result.exerciseId,
      newName: result.name,
    );
  }

  Future<void> _onMoveExerciseToCircuit(Wes2ExerciseRow row) async {
    if (row.source == Wes2RowSource.bb3Planned) {
      _showSnackBar(
          'BB3 planned exercises cannot be moved here. Use the Block Builder.');
      return;
    }
    final circuits =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final available = circuits.where((ci) => ci != row.circuitIndex).toList();
    if (available.isEmpty) {
      _showSnackBar('Only one circuit — add another circuit first.');
      return;
    }
    final targetCi = await _showCircuitPickerDialog(available);
    if (targetCi == null) return;
    _controller.moveExerciseToCircuit(row.exerciseId, targetCi);
    _saveDraftNow();
    _showUndoSnackBar('Exercise moved to Circuit ${targetCi + 1}');
    // ignore: discarded_futures
    _moveExerciseToCircuitSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      exerciseId: row.exerciseId,
      targetCircuitIndex: targetCi,
    );
  }

  // ── Silent Firestore wrappers (Phase 13) ──────────────────────────────────

  Future<void> _deleteExerciseSilently({
    required String uid,
    required DateTime date,
    required String exerciseId,
  }) async {
    try {
      await _repository.deleteExercise(
        uid: uid,
        date: date,
        exerciseId: exerciseId,
      );
    } catch (_) {
      // Silent failure; row already removed from local state and draft.
    }
  }

  Future<void> _replaceExerciseSilently({
    required String uid,
    required DateTime date,
    required String oldExerciseId,
    required String newExerciseId,
    required String newName,
  }) async {
    try {
      await _repository.replaceExercise(
        uid: uid,
        date: date,
        oldExerciseId: oldExerciseId,
        newExerciseId: newExerciseId,
        newName: newName,
      );
    } catch (_) {
      // Silent failure; local draft preserves updated row.
    }
  }

  Future<void> _moveExerciseToCircuitSilently({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int targetCircuitIndex,
  }) async {
    try {
      await _repository.moveExerciseToCircuit(
        uid: uid,
        date: date,
        exerciseId: exerciseId,
        targetCircuitIndex: targetCircuitIndex,
      );
    } catch (_) {
      // Silent failure; local draft preserves circuit assignment.
    }
  }

  // ── Remove Set (Phase 14) ─────────────────────────────────────────────────

  Future<void> _onRemoveSet(Wes2ExerciseRow row, int setIndex) async {
    // Always re-fetch by exerciseId so we have the latest in-memory state.
    final currentRow = _controller.rows.firstWhere(
      (r) => r.exerciseId == row.exerciseId,
      orElse: () => row,
    );

    if (currentRow.source == Wes2RowSource.bb3Planned) {
      _showSnackBar(
          'Removing sets from BB3 planned exercises will be added in a later phase.');
      return;
    }

    // One-set removal routes to exercise deletion.
    if (currentRow.setCount <= 1) {
      final confirmed = await _showConfirmDialog(
        title: 'Delete Exercise',
        content:
            'This is the only set. Removing it will delete "${currentRow.name}". Continue?',
      );
      if (!confirmed || !mounted) return;
      _controller.deleteExercise(currentRow.exerciseId);
      _saveDraftNow();
      _showUndoSnackBar('Exercise deleted');
      // ignore: discarded_futures
      _deleteExerciseSilently(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
        exerciseId: currentRow.exerciseId,
      );
      return;
    }

    // Find the target set in current in-memory state.
    final targetSet = currentRow.sets.firstWhere(
      (s) => s.setIndex == setIndex,
      orElse: () => Wes2SetState(setIndex: setIndex),
    );

    // Confirm only when the set carries actual logged values.
    if (targetSet.hasAnyActual) {
      final confirmed = await _showConfirmDialog(
        title: 'Remove Set',
        content: 'Removing this set will remove its logged values. Continue?',
      );
      if (!confirmed || !mounted) return;
    }

    _controller.removeSet(currentRow.exerciseId, setIndex);
    _saveDraftNow();
    _showUndoSnackBar('Set removed');
    // ignore: discarded_futures
    _removeSetSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      exerciseId: currentRow.exerciseId,
      setIndex: setIndex,
    );
  }

  Future<void> _removeSetSilently({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
  }) async {
    try {
      await _repository.removeSet(
        uid: uid,
        date: date,
        exerciseId: exerciseId,
        setIndex: setIndex,
      );
    } catch (_) {
      // Silent failure; local draft preserves current set state.
    }
  }
}
