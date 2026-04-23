import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'bb3_models.dart';
import 'bb3_hint_service.dart';
import 'bb3_planned_exercise_service.dart';
import 'template_model.dart';
import 'periodization_model_utils.dart';
import 'exercise_details_screen.dart';

// ─── BB3DayPanel ─────────────────────────────────────────────────────────────
//
// Renders one day column in BB3.
//
// Layout contract (enforced by widget tree, not sort order):
//   ┌─ Completed section (always on top) ───────────────────────────────────┐
//   │  One row per completed exercise — shaded, italic, read-only           │
//   └────────────────────────────────────────────────────────────────────────┘
//   ┌─ Planned section (always beneath) ────────────────────────────────────┐
//   │  Reorderable + cross-day draggable planned rows                        │
//   │  [+ Add Exercise]  [Load Template]                                     │
//   └────────────────────────────────────────────────────────────────────────┘
//
// Save on unfocus: every text field fires a save when focus leaves.
// Override identity: exerciseId + setIndex (0-based). Never row-based.

typedef BB3SaveCallback = Future<void> Function(
    int dayIndex, List<BB3Exercise> exercises);
typedef BB3DropCallback = void Function(
    int sourceDayIndex, int targetDayIndex, BB3Exercise exercise);

class BB3DayPanel extends StatefulWidget {
  final int dayIndex;            // 0 = Monday … 6 = Sunday
  final DateTime date;
  final List<BB3Exercise> plannedExercises;
  final List<Map<String, dynamic>> completedExercises; // from users/{uid}/workouts/{date}
  final BB3BlockSettings? blockSettings;
  final int weekIndex;
  final int sessionIndex;        // how many times exercises appear earlier this week
  final String uid;
  final List<Map<String, dynamic>> allExercises; // for the add-exercise picker
  final List<Template> templates;               // for the template picker
  final BB3SaveCallback onSave;
  final BB3DropCallback onDrop;   // cross-day drag
  final bool isInsideBlock;       // whether this day is inside the active block range

  const BB3DayPanel({
    super.key,
    required this.dayIndex,
    required this.date,
    required this.plannedExercises,
    required this.completedExercises,
    required this.blockSettings,
    required this.weekIndex,
    required this.sessionIndex,
    required this.uid,
    required this.allExercises,
    required this.templates,
    required this.onSave,
    required this.onDrop,
    required this.isInsideBlock,
  });

  @override
  State<BB3DayPanel> createState() => _BB3DayPanelState();
}

class _BB3DayPanelState extends State<BB3DayPanel> {
  // Controllers keyed by exerciseId → set index (never row index)
  final Map<String, List<TextEditingController>> _weightCtrl = {};
  final Map<String, List<TextEditingController>> _repsCtrl = {};
  final Map<String, List<TextEditingController>> _rirCtrl = {};
  final Map<String, List<TextEditingController>> _notesCtrl = {};

  // Focus nodes keyed by exerciseId → [w0,r0,rir0, w1,r1,rir1, ...] (3 per set)
  final Map<String, List<FocusNode>> _focusNodes = {};

  // Velocity controllers and focus nodes (1 per set)
  final Map<String, List<TextEditingController>> _velocityCtrl = {};
  final Map<String, List<FocusNode>> _velocityFocusNodes = {};

  // UI state
  final Map<String, bool> _expandedByExId = {};
  final Set<String> _viewedNoteExIds = {};
  bool _saveInProgress = false;

  // Keep an ordered list of exerciseIds matching widget.plannedExercises
  List<String> _orderedExIds = [];

  // Staging map for newly added exercises before the parent reflects them back
  // through widget.plannedExercises (avoids name: exId fallback during that window)
  final Map<String, BB3Exercise> _localExercises = {};

  @override
  void initState() {
    super.initState();
    _rebuildControllers(widget.plannedExercises);
  }

  @override
  void didUpdateWidget(BB3DayPanel old) {
    super.didUpdateWidget(old);
    // Rebuild controllers when the exercise list changes (e.g. after a server refresh)
    final newIds = widget.plannedExercises.map((e) => e.exerciseId).toSet();
    final oldIds = _orderedExIds.toSet();
    if (newIds != oldIds ||
        widget.plannedExercises.length != old.plannedExercises.length) {
      _rebuildControllers(widget.plannedExercises);
    }
    // Evict local staging entries that the parent has now confirmed
    for (final id in newIds) {
      _localExercises.remove(id);
    }
  }

  @override
  void dispose() {
    for (final list in _weightCtrl.values) {
      for (final c in list) c.dispose();
    }
    for (final list in _repsCtrl.values) {
      for (final c in list) c.dispose();
    }
    for (final list in _rirCtrl.values) {
      for (final c in list) c.dispose();
    }
    for (final list in _notesCtrl.values) {
      for (final c in list) c.dispose();
    }
    for (final list in _focusNodes.values) {
      for (final fn in list) fn.dispose();
    }
    for (final list in _velocityCtrl.values) {
      for (final c in list) c.dispose();
    }
    for (final list in _velocityFocusNodes.values) {
      for (final fn in list) fn.dispose();
    }
    super.dispose();
  }

  // ── Controller management ─────────────────────────────────────────────────

  void _rebuildControllers(List<BB3Exercise> exercises) {
    // Preserve existing controller values for exercises still present
    final keep = exercises.map((e) => e.exerciseId).toSet();

    // Dispose removed exercises' controllers
    final toRemove = _weightCtrl.keys.where((id) => !keep.contains(id)).toList();
    for (final id in toRemove) {
      for (final c in _weightCtrl[id]!) c.dispose();
      for (final c in _repsCtrl[id]!) c.dispose();
      for (final c in _rirCtrl[id]!) c.dispose();
      for (final c in _notesCtrl[id]!) c.dispose();
      for (final fn in _focusNodes[id]!) fn.dispose();
      for (final c in _velocityCtrl[id] ?? []) c.dispose();
      for (final fn in _velocityFocusNodes[id] ?? []) fn.dispose();
      _weightCtrl.remove(id);
      _repsCtrl.remove(id);
      _rirCtrl.remove(id);
      _notesCtrl.remove(id);
      _focusNodes.remove(id);
      _velocityCtrl.remove(id);
      _velocityFocusNodes.remove(id);
    }

    // Add/grow controllers for new/changed exercises
    for (final ex in exercises) {
      final id = ex.exerciseId;
      final setCount = ex.sets.length;

      if (!_weightCtrl.containsKey(id)) {
        _weightCtrl[id] = [];
        _repsCtrl[id] = [];
        _rirCtrl[id] = [];
        _notesCtrl[id] = [];
        _focusNodes[id] = [];
        _velocityCtrl[id] = [];
        _velocityFocusNodes[id] = [];
      }

      // Grow if needed
      while (_weightCtrl[id]!.length < setCount) {
        final si = _weightCtrl[id]!.length;
        final s = si < ex.sets.length ? ex.sets[si] : const BB3Set();

        _weightCtrl[id]!.add(TextEditingController(
          text: s.weight != null ? _fmtNum(s.weight!) : '',
        ));
        _repsCtrl[id]!.add(TextEditingController(
          text: s.reps != null ? s.reps.toString() : '',
        ));
        _rirCtrl[id]!.add(TextEditingController(
          text: s.rir != null ? _fmtNum(s.rir!) : '',
        ));
        _notesCtrl[id]!.add(TextEditingController(
          text: s.notes ?? '',
        ));
        _velocityCtrl[id]!.add(TextEditingController(
          text: s.velocity != null ? _fmtNum(s.velocity!) : '',
        ));

        // 3 focus nodes per set: weight, reps, rir
        for (int f = 0; f < 3; f++) {
          final fn = FocusNode();
          fn.addListener(() {
            if (!fn.hasFocus) _saveIfDirty();
          });
          _focusNodes[id]!.add(fn);
        }
        // 1 focus node for velocity
        final velFn = FocusNode();
        velFn.addListener(() {
          if (!velFn.hasFocus) _saveIfDirty();
        });
        _velocityFocusNodes[id]!.add(velFn);
      }

      // Trim if shrunk
      while (_weightCtrl[id]!.length > setCount) {
        _weightCtrl[id]!.removeLast().dispose();
        _repsCtrl[id]!.removeLast().dispose();
        _rirCtrl[id]!.removeLast().dispose();
        _notesCtrl[id]!.removeLast().dispose();
        _focusNodes[id]!.removeLast().dispose();
        _focusNodes[id]!.removeLast().dispose();
        _focusNodes[id]!.removeLast().dispose();
        _velocityCtrl[id]!.removeLast().dispose();
        _velocityFocusNodes[id]!.removeLast().dispose();
      }
    }

    _orderedExIds = exercises.map((e) => e.exerciseId).toList();
  }

  String _fmtNum(double v) {
    if (v == v.truncateToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(v.remainder(0.5) == 0 ? 1 : 2);
  }

  // ── Save on unfocus ───────────────────────────────────────────────────────
  // Fires when any field loses focus. Reads all current controller values
  // and saves the full day. _saveInProgress guards against concurrent saves.

  void _saveIfDirty() {
    if (_saveInProgress) return;
    _saveInProgress = true;
    _doSave().whenComplete(() => _saveInProgress = false);
  }

  Future<void> _doSave() async {
    final exercises = _buildCurrentExercises();
    await widget.onSave(widget.dayIndex, exercises);
  }

  List<BB3Exercise> _buildCurrentExercises() {
    final result = <BB3Exercise>[];
    for (int oi = 0; oi < _orderedExIds.length; oi++) {
      final exId = _orderedExIds[oi];
      final original = widget.plannedExercises.firstWhere(
        (e) => e.exerciseId == exId,
        orElse: () =>
            _localExercises[exId] ??
            BB3Exercise(
              exerciseId: exId,
              name: exId,
              circuitIndex: 0,
              orderIndex: oi,
              sets: const [],
            ),
      );

      final wList = _weightCtrl[exId] ?? [];
      final rList = _repsCtrl[exId] ?? [];
      final rirList = _rirCtrl[exId] ?? [];
      final nList = _notesCtrl[exId] ?? [];
      final vList = _velocityCtrl[exId] ?? [];
      final setCount = wList.length;

      final sets = List<BB3Set>.generate(setCount, (si) {
        final w = double.tryParse(wList[si].text.trim());
        final r = int.tryParse(rList[si].text.trim());
        final rir = double.tryParse(rirList[si].text.trim());
        final notes = nList.length > si ? nList[si].text.trim() : null;
        final vel = vList.length > si ? double.tryParse(vList[si].text.trim()) : null;
        return BB3Set(
          weight: w,
          reps: r,
          rir: rir,
          notes: notes?.isNotEmpty == true ? notes : null,
          velocity: vel,
        );
      });

      result.add(original.copyWith(sets: sets, orderIndex: oi));
    }
    return result;
  }

  // ── Identity helpers ──────────────────────────────────────────────────────

  Set<String> get _alreadyPresentExIds {
    final ids = <String>{};
    for (final e in widget.plannedExercises) {
      ids.add(e.exerciseId.toLowerCase());
    }
    // Include locally-staged exercises not yet reflected by the parent
    for (final id in _orderedExIds) {
      ids.add(id.toLowerCase());
    }
    for (final c in widget.completedExercises) {
      final id = (c['exerciseId'] ?? c['id'] ?? '').toString().toLowerCase();
      if (id.isNotEmpty) ids.add(id);
    }
    return ids;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dayNum = widget.date.day;
    String suffix = 'th';
    if (dayNum % 10 == 1 && dayNum % 100 != 11) suffix = 'st';
    if (dayNum % 10 == 2 && dayNum % 100 != 12) suffix = 'nd';
    if (dayNum % 10 == 3 && dayNum % 100 != 13) suffix = 'rd';

    final dateLabel =
        '${DateFormat('EEE').format(widget.date)} $dayNum$suffix ${DateFormat('MMMM').format(widget.date)}';

    return DragTarget<_BB3DragPayload>(
      onAcceptWithDetails: (details) {
        final payload = details.data;
        if (payload.sourceDayIndex != widget.dayIndex) {
          widget.onDrop(
            payload.sourceDayIndex,
            widget.dayIndex,
            payload.exercise,
          );
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isDragOver = candidateData.isNotEmpty;
        final bool anyExpanded =
        _orderedExIds.any((id) => _expandedByExId[id] == true);
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(
              color: isDragOver
                  ? theme.colorScheme.primary.withOpacity(0.6)
                  : Colors.grey.shade300,
              width: isDragOver ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
            color: isDragOver
                ? theme.colorScheme.primary.withOpacity(0.04)
                : theme.colorScheme.surface,
          ),

          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildDayHeader(theme, dateLabel),
              if (!anyExpanded) _buildColumnHeaderRow(theme, expandedMode: false),
              if (widget.completedExercises.isNotEmpty) _buildCompletedSection(theme),
              _buildPlannedSection(theme),
              _buildActionRow(theme),
            ],
          ),
        );
      },
    );
  }

  // ── Day header ────────────────────────────────────────────────────────────

  Widget _buildDayHeader(ThemeData theme, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withOpacity(0.4),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
      ),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          if (!widget.isInsideBlock) ...[
            const SizedBox(width: 6),
            Icon(Icons.info_outline, size: 14, color: Colors.orange.shade700),
          ],
        ],
      ),
    );
  }

  // ── Theme-aware completed surface ────────────────────────────────────────
  // Derives a slightly darker tint from the active surface color so completed
  // rows stay in the same color family as the theme instead of hardcoding grey.

  Color _completedSurface(ThemeData theme) {
    return Color.alphaBlend(
      Colors.black.withValues(alpha: -0.28),
      theme.colorScheme.surface,
    );
  }

  // ── Day-level column header row ───────────────────────────────────────────
  // Appears below the day-name row on every day.
  // expandedMode=true when any planned exercise on this day is expanded;
  // switches from "Exercise + field labels" layout to "set-label + field labels"
  // so it aligns with the per-set rows instead of the collapsed exercise rows.

  Widget _buildColumnHeaderRow(ThemeData theme, {required bool expandedMode}) {
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: Colors.grey.shade400,
      fontSize: 9,
    );

    Widget fl(String text, double width) => SizedBox(
          width: width,
          child: Text(text, style: labelStyle, textAlign: TextAlign.center),
        );

    if (expandedMode) {
      return Padding(
        padding: const EdgeInsets.only(left: 6, right: 6, bottom: 1),
        child: Row(
          children: [
            const SizedBox(width: 24), // aligns with S1/S2/… label
            fl('Weight', 42),
            const SizedBox(width: 8),
            fl('Reps', 36),
            const SizedBox(width: 3),
            fl('RIR', 36),
            const SizedBox(width: 1),
            fl('E1RM', 40),
            const SizedBox(width: 1),
            fl('Vel', 38),
            const SizedBox(width: 2),
            Text('Notes', style: labelStyle),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 6, bottom: 1),
      child: Row(
        children: [
          const SizedBox(width: 35), // space for expand + drag icons
          Expanded(child: Text('Exercise', style: labelStyle)),
          const SizedBox(width: 3),
          fl('Weight', 42),
          const SizedBox(width: 3),
          fl('Reps', 32),
          const SizedBox(width: 3),
          fl('RIR', 32),
          const SizedBox(width: 1),
          fl('E1RM', 36),
          const SizedBox(width: 1),
          fl('Vel', 34),
          const SizedBox(width: 2),
          Text('Notes', style: labelStyle),
        ],
      ),
    );
  }

  // ── Completed section ─────────────────────────────────────────────────────
  // ALWAYS renders above the planned section. Layout-enforced.

  Widget _buildCompletedSection(ThemeData theme) {
    // Group by exerciseId to show one row per exercise
    final Map<String, List<Map<String, dynamic>>> byExId = {};
    for (final ex in widget.completedExercises) {
      final id = (ex['exerciseId'] ?? ex['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      byExId.putIfAbsent(id, () => []).add(ex);
    }

    if (byExId.isEmpty) return const SizedBox.shrink();

    return Container(
      color: _completedSurface(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(
              'COMPLETED',
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.grey.shade600,
                letterSpacing: 0.8,
              ),
            ),
          ),
          ...byExId.entries.map((entry) =>
              _buildCompletedRow(theme, entry.key, entry.value)),
        ],
      ),
    );
  }

  Widget _buildCompletedRow(
    ThemeData theme,
    String exerciseId,
    List<Map<String, dynamic>> completedEntries,
  ) {
    final name = (completedEntries.first['name'] ??
            completedEntries.first['exercise'] ??
            exerciseId)
        .toString();

    final topSet = BB3HintService.getTopSet(
      exerciseId: exerciseId,
      completedExercisesForDay: widget.completedExercises,
    );

    final isExpanded = _expandedByExId[exerciseId] ?? false;

    // Collect all completed sets across entries
    final allSets = completedEntries
        .expand<Map>((e) => (e['sets'] as List?)?.whereType<Map>() ?? [])
        .toList();

    return Container(
      color: _completedSurface(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row header
          InkWell(
            onTap: () => setState(
                () => _expandedByExId[exerciseId] = !isExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Colors.grey.shade600,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                  if (topSet != null && !isExpanded)
                    Text(
                      BB3HintService.formatCompletedSet(topSet),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey.shade600,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Edit completed sets in WES',
                    child: Icon(Icons.lock_outline,
                        size: 14, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),
          // Expanded: show all completed sets read-only
          if (isExpanded && allSets.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 36, right: 12, bottom: 6),
              child: Column(
                children: allSets.asMap().entries.map((entry) {
                  final si = entry.key;
                  final s = entry.value;
                  final w = (s['weight'] as num?)?.toDouble();
                  final r = (s['reps'] as num?)?.toInt();
                  final rir = (s['rir'] as num?)?.toDouble();
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Row(
                      children: [
                        Text(
                          'Set ${si + 1}  ',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.grey.shade500,
                          ),
                        ),
                        if (w != null)
                          Text('${w}kg  ',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(fontStyle: FontStyle.italic)),
                        if (r != null)
                          Text('${r}r  ',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(fontStyle: FontStyle.italic)),
                        if (rir != null)
                          Text('@RIR $rir',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(fontStyle: FontStyle.italic)),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          Divider(height: 0.5, color: Colors.grey.shade200),
        ],
      ),
    );
  }

  // ── Planned section ───────────────────────────────────────────────────────
  // ALWAYS renders beneath completed. Layout-enforced.

  Widget _buildPlannedSection(ThemeData theme) {
    if (_orderedExIds.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          'No exercises planned',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: Colors.grey.shade500),
        ),
      );
    }

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _orderedExIds.length,
      onReorder: _onReorder,
      buildDefaultDragHandles: false,
      itemBuilder: (ctx, idx) {
        final exId = _orderedExIds[idx];
        final ex = widget.plannedExercises.firstWhere(
          (e) => e.exerciseId == exId,
          orElse: () =>
              _localExercises[exId] ??
              BB3Exercise(
                exerciseId: exId,
                name: exId,
                circuitIndex: 0,
                orderIndex: idx,
                sets: const [],
              ),
        );
        final locked = BB3HintService.isExerciseLocked(
          exerciseId: exId,
          completedExercisesForDay: widget.completedExercises,
        );
        return KeyedSubtree(
          key: ValueKey(exId),
          child: _buildExerciseCard(theme, ex, idx, locked),
        );
      },
    );
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    setState(() {
      final id = _orderedExIds.removeAt(oldIndex);
      _orderedExIds.insert(newIndex, id);
    });
    _saveIfDirty();
  }

  // Returns the 0-based index of the completed set with the highest E1RM for
  // [exId], capped at [maxIdx] so it never exceeds the planned-set count.
  int _topCompletedSetIndex(String exId, int maxIdx) {
    if (maxIdx < 0) return 0;
    final top = BB3HintService.getTopSet(
      exerciseId: exId,
      completedExercisesForDay: widget.completedExercises,
    );
    if (top == null) return 0;
    final topW = (top['weight'] as num?)?.toDouble();
    final topR = (top['reps'] as num?)?.toInt();
    if (topW == null || topR == null) return 0;
    for (final comp in widget.completedExercises) {
      final cId = (comp['exerciseId'] ?? comp['id'] ?? '').toString();
      if (cId != exId) continue;
      final sets = comp['sets'] as List?;
      if (sets == null) continue;
      for (int i = 0; i <= maxIdx && i < sets.length; i++) {
        final s = sets[i] as Map?;
        if (s == null) continue;
        final w = (s['weight'] as num?)?.toDouble();
        final r = (s['reps'] as num?)?.toInt();
        if (w == topW && r == topR) return i;
      }
    }
    return 0;
  }

  // ── Exercise card ─────────────────────────────────────────────────────────
  //
  // Collapsed: single compact row — name + all set fields + controls in one line.
  // Expanded: header row + one row per set (each with set# + same field layout).
  // Long-press required for both within-day reorder and cross-day drag.

  Widget _buildExerciseCard(
    ThemeData theme,
    BB3Exercise ex,
    int listIndex,
    bool locked,
  ) {
    final exId = ex.exerciseId;
    final isExpanded = _expandedByExId[exId] ?? false;
    final hasNote =
        ex.perExerciseNote != null && ex.perExerciseNote!.isNotEmpty;
    final noteViewed = _viewedNoteExIds.contains(exId);
    final cardColor =
        locked ? _completedSurface(theme) : theme.colorScheme.surface;

    final visibleSetIndex = locked
        ? _topCompletedSetIndex(ex.exerciseId, ex.sets.length - 1)
        : 0;

    Widget card = Container(
      color: cardColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isExpanded)
            // ── Collapsed: one row with name + set fields ───────────────
            InkWell(
              onTap: () =>
                  setState(() => _expandedByExId[exId] = true),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.expand_more,
                        size: 14, color: Colors.grey.shade400),
                    const SizedBox(width: 2),
                    if (!locked)
                      ReorderableDelayedDragStartListener(
                        index: listIndex,
                        child: Icon(Icons.drag_handle,
                            size: 16, color: Colors.grey.shade400),
                      ),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text(
                        ex.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          fontStyle: locked ? FontStyle.italic : null,
                          color: locked ? Colors.grey.shade600 : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 3),
                    ..._setFieldWidgets(
                        theme, ex, visibleSetIndex, locked,
                        expandedMode: false),
                    if (!locked) ...[
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () => _confirmDelete(ex),
                        child: Icon(Icons.close,
                            size: 14, color: Colors.red.shade300),
                      ),
                    ],
                  ],
                ),
              ),
            )
          else ...[
            // ── Expanded header row ─────────────────────────────────────
            InkWell(
              onTap: () =>
                  setState(() => _expandedByExId[exId] = false),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                child: Row(
                  children: [
                    Icon(Icons.expand_less,
                        size: 14, color: Colors.grey.shade500),
                    const SizedBox(width: 2),
                    if (!locked)
                      ReorderableDelayedDragStartListener(
                        index: listIndex,
                        child: Icon(Icons.drag_handle,
                            size: 16, color: Colors.grey.shade400),
                      ),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text(
                        ex.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          fontStyle: locked ? FontStyle.italic : null,
                          color: locked ? Colors.grey.shade600 : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ExerciseDetailsScreen(
                            exerciseId: exId,
                            exerciseName: ex.name,
                          ),
                        ),
                      ),
                      child: Icon(
                        Icons.insights,
                        size: 14,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    if (hasNote) ...[
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () => _showNote(ex),
                        child: Icon(
                          Icons.sticky_note_2_outlined,
                          size: 14,
                          color: noteViewed
                              ? Colors.grey.shade400
                              : theme.colorScheme.secondary,
                        ),
                      ),
                    ],
                    if (ex.circuitIndex > 0) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 3, vertical: 1),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text('C${ex.circuitIndex}',
                            style: theme.textTheme.labelSmall),
                      ),
                    ],
                    if (!locked) ...[
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () => _confirmDelete(ex),
                        child: Icon(Icons.close,
                            size: 14, color: Colors.red.shade300),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 6, bottom: 2),
              child: Row(
                children: [
                  const SizedBox(width: 24), // aligns with S1 / S2 / S3
                  SizedBox(
                    width: 46,
                    child: Text('Weight',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.grey.shade400,
                          fontSize: 9,
                        )),
                  ),
                  const SizedBox(width: 3),
                  SizedBox(
                    width: 36,
                    child: Text('Reps',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.grey.shade400,
                          fontSize: 9,
                        )),
                  ),
                  const SizedBox(width: 3),
                  SizedBox(
                    width: 36,
                    child: Text('RIR',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.grey.shade400,
                          fontSize: 9,
                        )),
                  ),
                  const SizedBox(width: 1),
                  SizedBox(
                    width: 40,
                    child: Text('E1RM',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.grey.shade400,
                          fontSize: 9,
                        )),
                  ),
                  const SizedBox(width: 1),
                  SizedBox(
                    width: 38,
                    child: Text('Vel',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.grey.shade400,
                          fontSize: 9,
                        )),
                  ),
                  const SizedBox(width: 2),
                  Text('Notes',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.grey.shade400,
                        fontSize: 9,
                      )),
                ],
              ),
            ),
            // ── Per-set rows ────────────────────────────────────────────
            for (int si = 0; si < ex.sets.length; si++)
              Padding(
                padding: EdgeInsets.only(
                    left: 6,
                    right: 6,
                    bottom: si < ex.sets.length - 1 ? 2 : 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        'S${si + 1}',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: Colors.grey.shade500),
                      ),
                    ),
                    ..._setFieldWidgets(theme, ex, si, locked,
                        expandedMode: true),
                  ],
                ),
              ),
            // Per-exercise note text (below sets)
            if (hasNote)
              Padding(
                padding:
                    const EdgeInsets.only(left: 6, right: 6, bottom: 4),
                child: Text(
                  'Note: ${ex.perExerciseNote}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade500,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
          Divider(height: 0.5, color: Colors.grey.shade100),
        ],
      ),
    );

    // Long-press required for cross-day drag
    if (!locked) {
      card = LongPressDraggable<_BB3DragPayload>(
        data: _BB3DragPayload(
            sourceDayIndex: widget.dayIndex, exercise: ex),
        feedback: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 160,
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              ex.name,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: card),
        child: card,
      );
    }

    return card;
  }

  // ── Set field widgets ──────────────────────────────────────────────────────
  //
  // Returns the inline compact field widgets for one set:
  //   [kg 42px] [reps 32px] [RIR 32px] [E1RM text 48px] [vel 36px] [note-btn]
  //
  // Used in both the collapsed single-row and each expanded per-set row.
  // Double-tap on an empty field with a hint value copies the hint in (item 6).
  // E1RM is computed live from entered/hint values. Velocity uses salmon text
  // color when user-entered, same as other fields.

  List<Widget> _setFieldWidgets(
    ThemeData theme,
    BB3Exercise ex,
    int setIndex,
    bool locked, {
    required bool expandedMode,
  }) {
    final exId = ex.exerciseId;
    final wCtrls = _weightCtrl[exId];
    final rCtrls = _repsCtrl[exId];
    final rirCtrls = _rirCtrl[exId];
    final fns = _focusNodes[exId];

    if (wCtrls == null ||
        setIndex >= wCtrls.length ||
        fns == null ||
        setIndex * 3 + 2 >= fns.length) {
      return [const SizedBox.shrink()];
    }

    final wCtrl = wCtrls[setIndex];
    final rCtrl = rCtrls![setIndex];
    final rirCtrl = rirCtrls![setIndex];
    final wFn = fns[setIndex * 3];
    final rFn = fns[setIndex * 3 + 1];
    final rirFn = fns[setIndex * 3 + 2];

    final double? userWeight =
        locked ? null : double.tryParse(wCtrl.text.trim());
    final int? userReps =
        locked ? null : int.tryParse(rCtrl.text.trim());
    final double? userRir =
        locked ? null : double.tryParse(rirCtrl.text.trim());

    // Hints: always attempt when blockSettings is available.
    // Outside block range, weekIndex falls outside plan week keys →
    // getRirFromPlan() returns 1.0 and getRepTargetForSet() returns 8 as
    // defaults → engine produces history-based weight hints at those defaults.
    final BB3SetHint hint;
    if (widget.blockSettings != null) {
      hint = BB3HintService.getHintsForSet(
        exerciseId: exId,
        exerciseName: ex.name,
        fullExerciseSettings: widget.blockSettings!.exerciseSettings,
        weekIndex: widget.weekIndex,
        sessionIndex: widget.sessionIndex,
        setIndex: setIndex,
        blockStartDate: widget.blockSettings!.startDate ?? widget.date,
        blockEndDate: widget.blockSettings!.endDate,
        selectedDate: widget.date,
        uid: widget.uid,
        circuitIndex: ex.circuitIndex,
        userWeight: userWeight,
        userReps: userReps,
        userRir: userRir,
      );
    } else {
      hint = const BB3SetHint();
    }

    Map<String, dynamic>? completedSet;
    if (locked) {
      for (final comp in widget.completedExercises) {
        final cId = (comp['exerciseId'] ?? comp['id'] ?? '').toString();
        if (cId != exId) continue;
        final sets = comp['sets'] as List?;
        if (sets != null && setIndex < sets.length && sets[setIndex] is Map) {
          completedSet =
              Map<String, dynamic>.from(sets[setIndex] as Map);
        }
      }
    }

    final double? dispW = userWeight ??
        (completedSet != null
            ? (completedSet['weight'] as num?)?.toDouble()
            : double.tryParse(hint.weightDisplay));
    final double? dispRRaw = (userReps ??
            (completedSet != null
                ? (completedSet['reps'] as num?)?.toInt()
                : int.tryParse(hint.repsDisplay)))
        ?.toDouble();
    final double dispRir = userRir ??
        (completedSet != null
            ? (completedSet['rir'] as num?)?.toDouble()
            : double.tryParse(hint.rirDisplay)) ??
        0.0;
    String e1rmLabel = '';
    if (dispW != null && dispW > 0 && dispRRaw != null && dispRRaw > 0) {
      final e1rm =
          PeriodizationModelUtils.calculateE1RM(dispW, dispRRaw, dispRir);
      if (e1rm > 0) e1rmLabel = _fmtNum(e1rm);
    }

    final velCtrls = _velocityCtrl[exId];
    final velFns = _velocityFocusNodes[exId];
    final velCtrl = (velCtrls != null && setIndex < velCtrls.length)
        ? velCtrls[setIndex]
        : null;
    final velFn = (velFns != null && setIndex < velFns.length)
        ? velFns[setIndex]
        : null;
    final velHasValue = velCtrl != null && velCtrl.text.isNotEmpty;

    final wWidth = expandedMode ? 57.0 : 40.0;
    final rWidth = expandedMode ? 40.0 : 32.0;
    final rirWidth = expandedMode ? 30.0 : 30.0;
    final e1rmWidth = expandedMode ? 48.0 : 36.0;
    final velWidth = expandedMode ? 38.0 : 34.0;

    return [
      SizedBox(
        width: wWidth,
        child: _fieldCell(
          theme: theme,
          ctrl: wCtrl,
          focusNode: wFn,
          hint: completedSet != null
              ? (completedSet['weight']?.toString() ?? '')
              : hint.weightDisplay,
          label: 'kg',
          locked: locked,
          hasUserValue: completedSet != null
              ? (completedSet['weight'] != null)
              : wCtrl.text.isNotEmpty,
          isCompleted:
              completedSet != null && completedSet['weight'] != null,
        ),
      ),
      const SizedBox(width: 3),
      SizedBox(
        width: rWidth,
        child: _fieldCell(
          theme: theme,
          ctrl: rCtrl,
          focusNode: rFn,
          hint: completedSet != null
              ? (completedSet['reps']?.toString() ?? '')
              : hint.repsDisplay,
          label: 'reps',
          locked: locked,
          hasUserValue: completedSet != null
              ? (completedSet['reps'] != null)
              : rCtrl.text.isNotEmpty,
          isCompleted:
              completedSet != null && completedSet['reps'] != null,
        ),
      ),
      const SizedBox(width: 3),
      SizedBox(
        width: rirWidth,
        child: _fieldCell(
          theme: theme,
          ctrl: rirCtrl,
          focusNode: rirFn,
          hint: completedSet != null
              ? (completedSet['rir']?.toString() ?? '')
              : hint.rirDisplay,
          label: 'RIR',
          locked: locked,
          hasUserValue: completedSet != null
              ? (completedSet['rir'] != null)
              : rirCtrl.text.isNotEmpty,
          isCompleted:
              completedSet != null && completedSet['rir'] != null,
        ),
      ),
      const SizedBox(width: 1),
      // Live E1RM (read-only, updates as fields change)
      SizedBox(
        width: e1rmWidth,
        child: Text(
          e1rmLabel,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            color: Colors.grey.shade500,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
      const SizedBox(width: 1),
      // Velocity field (salmon text when user-entered, same convention)
      if (velCtrl != null && velFn != null)
        SizedBox(
          width: velWidth,
          child: TextField(
            controller: velCtrl,
            focusNode: velFn,
            readOnly: locked,
            enabled: !locked,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.center,
            onChanged: locked ? null : (_) => setState(() {}),
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 10,
              color: velHasValue && !locked
                  ? Colors.deepOrange.shade300
                  : (locked ? Colors.grey.shade600 : null),
            ),
            decoration: InputDecoration(
              hintText: 'm/s',
              hintStyle: TextStyle(
                  color: Colors.grey.shade300, fontSize: 10),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide:
                    BorderSide(color: Colors.grey.shade300, width: 0.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide:
                    BorderSide(color: Colors.grey.shade300, width: 0.5),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(
                    color: theme.colorScheme.primary, width: 1),
              ),
            ),
          ),
        ),
      const SizedBox(width: 2),
      // Per-set note button — highlights when note is non-empty
      GestureDetector(
        onTap: () => _showSetNoteDialog(theme, exId, setIndex),
        child: Icon(
          Icons.edit_note,
          size: 14,
          color: (_notesCtrl[exId]?.elementAtOrNull(setIndex)?.text
                      .isNotEmpty ==
                  true)
              ? theme.colorScheme.secondary
              : Colors.grey.shade400,
        ),
      ),
    ];
  }

  Widget _fieldCell({
    required ThemeData theme,
    required TextEditingController ctrl,
    required FocusNode focusNode,
    required String hint,
    required String label,
    required bool locked,
    required bool hasUserValue,
    bool isCompleted = false,
  }) {
    // Text color coding (background stays neutral — only text color signals state):
    //  - completed value (locked/read-only data): grey italic
    //  - BB3 user-entered value: salmon pink text
    //  - hint-only: default theme text (no color override)
    Color? textColor;
    if (isCompleted) {
      textColor = Colors.grey.shade600;
    } else if (hasUserValue && !locked) {
      textColor = Colors.deepOrange.shade300; // salmon pink for BB3-entered values
    } else if (locked) {
      textColor = Colors.grey.shade600;
    }

    final Color? fillColor = isCompleted ? Colors.white : null;

    return GestureDetector(
      onDoubleTap: (!locked && ctrl.text.isEmpty && hint.isNotEmpty)
          ? () {
              ctrl.text = hint;
              setState(() {});
            }
          : null,
      child: TextField(
        controller: ctrl,
        focusNode: focusNode,
        readOnly: locked,
        enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.center,
        onChanged: locked ? null : (_) => setState(() {}),
        style: theme.textTheme.bodySmall?.copyWith(
          color: textColor,
          fontStyle: isCompleted ? FontStyle.italic : null,
        ),
        decoration: InputDecoration(
          hintText: hint.isEmpty ? label : hint,
          hintStyle: TextStyle(
            color: hint.isEmpty ? Colors.grey.shade300 : Colors.grey.shade400,
            fontSize: 11,
          ),
          filled: fillColor != null,
          fillColor: fillColor,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide:
                BorderSide(color: Colors.grey.shade300, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide:
                BorderSide(color: Colors.grey.shade300, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(
              color: theme.colorScheme.primary,
              width: 1,
            ),
          ),
        ),
      ),
    );
  }

  // ── Per-set note dialog ───────────────────────────────────────────────────

  void _showSetNoteDialog(ThemeData theme, String exId, int setIndex) {
    final nCtrls = _notesCtrl[exId];
    if (nCtrls == null || setIndex >= nCtrls.length) return;
    final noteCtrl = nCtrls[setIndex];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Set ${setIndex + 1} note',
          style: const TextStyle(fontSize: 14),
        ),
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        content: TextField(
          controller: noteCtrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Add a note for this set...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              noteCtrl.clear();
              Navigator.pop(ctx);
              _saveIfDirty();
            },
            child: const Text('Clear'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _saveIfDirty();
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  // ── Action row ────────────────────────────────────────────────────────────

  Widget _buildActionRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          TextButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => _showAddExerciseDialog(theme),
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            icon: const Icon(Icons.view_list_outlined, size: 16),
            label: const Text('Template', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: widget.templates.isEmpty
                ? null
                : () => _showTemplateDialog(theme),
          ),
        ],
      ),
    );
  }

  // ── Add exercise dialog ───────────────────────────────────────────────────

  void _showAddExerciseDialog(ThemeData theme) {
    final presentIds = _alreadyPresentExIds;

    // Same category ordering as WES
    const categoryOrder = [
      'Horizontal Press', 'Horizontal Pull',
      'Vertical Press', 'Vertical Pull',
      'Lateral Raise',
      'Arm Extension', 'Arm Curl',
      'Squat Pattern', 'Hip Hinge',
      'Leg Extension', 'Leg Curl',
      'Hip Abduction/adduction', 'Calf Raise',
      'Core',
    ];

    // Build ordered grouped map: category → sorted exercise list
    final Map<String, List<Map<String, dynamic>>> rawGroups = {};
    for (final ex in widget.allExercises) {
      final cat = (ex['category'] ?? 'Other').toString();
      rawGroups.putIfAbsent(cat, () => []).add(ex);
    }
    for (final list in rawGroups.values) {
      list.sort((a, b) => (a['name'] ?? '').toString().toLowerCase()
          .compareTo((b['name'] ?? '').toString().toLowerCase()));
    }
    final Map<String, List<Map<String, dynamic>>> orderedGroups = {};
    for (final cat in categoryOrder) {
      if (rawGroups.containsKey(cat)) orderedGroups[cat] = rawGroups[cat]!;
    }
    for (final entry in rawGroups.entries) {
      if (!orderedGroups.containsKey(entry.key)) {
        orderedGroups[entry.key] = entry.value;
      }
    }

    final Map<String, bool> expandedGroups = {};
    String searchQuery = '';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          // Flat alphabetical list used when the user is searching
          final List<Map<String, dynamic>>? searchResults =
              searchQuery.trim().isEmpty
                  ? null
                  : (widget.allExercises
                      .where((e) => (e['name'] ?? '')
                          .toString()
                          .toLowerCase()
                          .contains(searchQuery.toLowerCase()))
                      .toList()
                    ..sort((a, b) => (a['name'] ?? '')
                        .toString()
                        .toLowerCase()
                        .compareTo(
                            (b['name'] ?? '').toString().toLowerCase())));

          // Exercise tile — CheckboxListTile visual (mirrors WES style).
          // BB3 single-select: value=false=available, value=true=already added.
          // Tap adds immediately (no Save button needed for single-select).
          Widget tile(Map<String, dynamic> ex, {double leftPad = 10}) {
            final id = (ex['id'] ?? ex['exerciseId'] ?? ex['name'] ?? '')
                .toString()
                .toLowerCase();
            final name = (ex['name'] ?? id).toString();
            final alreadyPresent = presentIds.contains(id);
            return CheckboxListTile(
              value: alreadyPresent,
              dense: true,
              enabled: !alreadyPresent,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: leftPad, vertical: 0),
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: theme.colorScheme.primary,
              checkColor: Colors.white,
              title: Text(
                name,
                style: TextStyle(
                  fontSize: 13,
                  color: alreadyPresent ? Colors.grey.shade400 : null,
                ),
              ),
              subtitle: alreadyPresent
                  ? Text('already added',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade400))
                  : null,
              onChanged: alreadyPresent
                  ? null
                  : (_) {
                      Navigator.pop(ctx);
                      _addExercise(ex);
                    },
            );
          }

          return AlertDialog(
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            title: const Text('Select Exercise',
                style: TextStyle(fontSize: 13)),
            content: SizedBox(
              width: double.maxFinite,
              height: 480,
              child: Column(
                children: [
                  // Search bar — WES style
                  TextField(
                    onChanged: (v) => setDlg(() => searchQuery = v),
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Search exercises...',
                      hintStyle: const TextStyle(color: Colors.white54),
                      prefixIcon:
                          const Icon(Icons.search, color: Colors.white70),
                      isDense: true,
                      filled: true,
                      fillColor: theme.cardTheme.color ??
                          theme.colorScheme.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: searchResults != null
                        // ── Search results: flat alphabetical ──────────
                        ? ListView(
                            children: searchResults
                                .map((ex) => tile(ex))
                                .toList(),
                          )
                        // ── Category groups (WES pattern) ──────────────
                        : ListView(
                            children: orderedGroups.entries.map((entry) {
                              final cat = entry.key;
                              final exercises = entry.value;
                              final isExpanded =
                                  expandedGroups[cat] ?? false;
                              return Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  ListTile(
                                    dense: true,
                                    title: Text(
                                      cat,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold),
                                    ),
                                    trailing: Icon(
                                      isExpanded
                                          ? Icons.expand_less
                                          : Icons.expand_more,
                                      color: Colors.white70,
                                      size: 18,
                                    ),
                                    onTap: () => setDlg(() =>
                                        expandedGroups[cat] = !isExpanded),
                                  ),
                                  if (isExpanded)
                                    ...exercises.map(
                                        (ex) => tile(ex, leftPad: 20)),
                                  const Divider(
                                      height: 10, color: Colors.grey),
                                ],
                              );
                            }).toList(),
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _addExercise(Map<String, dynamic> ex) {
    final exerciseId =
        (ex['id'] ?? ex['exerciseId'] ?? ex['name'] ?? '').toString().trim();
    final name = (ex['name'] ?? exerciseId).toString();

    if (exerciseId.isEmpty) return;

    // Determine set count from block settings
    int setCount = 3;
    if (widget.blockSettings != null) {
      final exSettings = widget.blockSettings!.settingsFor(exerciseId);
      if (exSettings.isNotEmpty) {
        setCount = BB3PlannedExerciseService.resolveSetCount(
          exSettings: exSettings.isNotEmpty ? exSettings : null,
          weekIndex: widget.weekIndex,
          sessionIndex: widget.sessionIndex,
        );
      }
    }

    final newEx = BB3Exercise(
      exerciseId: exerciseId,
      name: name,
      circuitIndex: 0,
      orderIndex: _orderedExIds.length,
      sets: List.generate(setCount, (_) => const BB3Set()),
    );

    setState(() {
      // Stage the new exercise so the render path finds the correct name
      // before widget.plannedExercises is updated by the parent
      _localExercises[newEx.exerciseId] = newEx;

      // Append controllers for the new exercise
      final id = newEx.exerciseId;
      _weightCtrl[id] = [];
      _repsCtrl[id] = [];
      _rirCtrl[id] = [];
      _notesCtrl[id] = [];
      _focusNodes[id] = [];
      _velocityCtrl[id] = [];
      _velocityFocusNodes[id] = [];
      for (int si = 0; si < setCount; si++) {
        _weightCtrl[id]!.add(TextEditingController());
        _repsCtrl[id]!.add(TextEditingController());
        _rirCtrl[id]!.add(TextEditingController());
        _notesCtrl[id]!.add(TextEditingController());
        _velocityCtrl[id]!.add(TextEditingController());
        for (int f = 0; f < 3; f++) {
          final fn = FocusNode();
          fn.addListener(() {
            if (!fn.hasFocus) _saveIfDirty();
          });
          _focusNodes[id]!.add(fn);
        }
        final velFn = FocusNode();
        velFn.addListener(() {
          if (!velFn.hasFocus) _saveIfDirty();
        });
        _velocityFocusNodes[id]!.add(velFn);
      }
      _orderedExIds.add(id);
    });

    // Persist immediately
    _saveIfDirty();
  }

  // ── Template dialog ───────────────────────────────────────────────────────

  void _showTemplateDialog(ThemeData theme) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Load Template'),
        content: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Replaces planned exercises only. Completed exercises are not affected.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey.shade600),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.templates.length,
                  itemBuilder: (_, i) {
                    final t = widget.templates[i];
                    return ListTile(
                      dense: true,
                      title: Text(t.name, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                        '${t.exercises.length} exercise(s)',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _loadTemplate(t);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _loadTemplate(Template t) {
    int setCount = 3;

    final newExercises = <BB3Exercise>[];
    int oi = 0;
    for (final raw in t.exercises) {
      final name = (raw['name'] ?? raw['exercise'] ?? '').toString().trim();
      final exId = (raw['exerciseId'] ?? raw['id'] ?? name).toString().trim();
      final ci = (raw['circuitIndex'] as num?)?.toInt() ?? 0;
      if (exId.isEmpty || name.isEmpty) continue;

      // Determine set count for this exercise
      if (widget.blockSettings != null) {
        final exSettings = widget.blockSettings!.settingsFor(exId);
        if (exSettings.isNotEmpty) {
          setCount = BB3PlannedExerciseService.resolveSetCount(
            exSettings: exSettings,
            weekIndex: widget.weekIndex,
            sessionIndex: widget.sessionIndex,
          );
        }
      }

      newExercises.add(BB3Exercise(
        exerciseId: exId,
        name: name,
        circuitIndex: ci,
        orderIndex: oi++,
        sets: List.generate(setCount, (_) => const BB3Set()),
      ));
    }

    // Rebuild controllers for new exercise list (keeps completed untouched)
    setState(() {
      _rebuildControllers(newExercises);
    });

    // Save immediately
    widget.onSave(widget.dayIndex, newExercises);
  }

  // ── Delete confirm ────────────────────────────────────────────────────────

  void _confirmDelete(BB3Exercise ex) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove exercise?'),
        content: Text('Remove "${ex.name}" from this day\'s plan?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteExercise(ex);
            },
            style: TextButton.styleFrom(
                foregroundColor: Colors.red.shade600),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  void _deleteExercise(BB3Exercise ex) {
    setState(() {
      final id = ex.exerciseId;
      _orderedExIds.remove(id);
      for (final c in _weightCtrl[id] ?? []) c.dispose();
      for (final c in _repsCtrl[id] ?? []) c.dispose();
      for (final c in _rirCtrl[id] ?? []) c.dispose();
      for (final c in _notesCtrl[id] ?? []) c.dispose();
      for (final fn in _focusNodes[id] ?? []) fn.dispose();
      for (final c in _velocityCtrl[id] ?? []) c.dispose();
      for (final fn in _velocityFocusNodes[id] ?? []) fn.dispose();
      _weightCtrl.remove(id);
      _repsCtrl.remove(id);
      _rirCtrl.remove(id);
      _notesCtrl.remove(id);
      _focusNodes.remove(id);
      _velocityCtrl.remove(id);
      _velocityFocusNodes.remove(id);
    });
    _saveIfDirty();
  }

  // ── Note viewer ───────────────────────────────────────────────────────────

  void _showNote(BB3Exercise ex) {
    setState(() => _viewedNoteExIds.add(ex.exerciseId));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ex.name, style: const TextStyle(fontSize: 16)),
        content: Text(ex.perExerciseNote ?? ''),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

// ── Drag payload ──────────────────────────────────────────────────────────────

class _BB3DragPayload {
  final int sourceDayIndex;
  final BB3Exercise exercise;
  const _BB3DragPayload({required this.sourceDayIndex, required this.exercise});
}
