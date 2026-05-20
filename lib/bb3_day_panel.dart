import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'bb3_models.dart';
import 'bb3_hint_service.dart';
import 'bb3_planned_exercise_service.dart';
import 'bb3_template_picker.dart';
import 'template_model.dart';
import 'periodization_model_utils.dart';
import 'exercise_details_screen.dart';
import 'user_context.dart';
import 'WES2_screen.dart';
import 'WES2_widgets/WES2_exercise_settings_dialog.dart';
import 'WES2_plan_service.dart';
import 'WES2_hint_service.dart';
import 'WES2_models.dart';

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
typedef BB3MoveAllCallback = void Function(int sourceDayIndex);

class BB3DayPanel extends StatefulWidget {
  final int dayIndex;            // 0 = Monday … 6 = Sunday
  final DateTime date;
  final List<BB3Exercise> plannedExercises;
  final List<Map<String, dynamic>> completedExercises; // from users/{uid}/workouts/{date}
  final BB3BlockSettings? blockSettings;
  final int weekIndex;
  final int sessionIndex;        // fallback: 0 when sessionIndexByExerciseId is absent
  final Map<String, int>? sessionIndexByExerciseId; // per-exercise session index
  final String uid;
  final List<Map<String, dynamic>> allExercises; // for the add-exercise picker
  final List<Template> templates;               // for the template picker
  final BB3SaveCallback onSave;
  final BB3DropCallback onDrop;   // cross-day drag
  final BB3MoveAllCallback onMoveAllToNextDay;
  final bool isInsideBlock;       // whether this day is inside the active block range
  final String? blockId;          // needed for direct savePlannedDay on dispose
  final void Function()? onBlockSettingsChanged; // fired after settings dialog saves
  final List<List<BB3Exercise>> allWeekPlannedByDay;
  final List<List<Map<String, dynamic>>> allWeekCompletedByDay;

  const BB3DayPanel({
    super.key,
    required this.dayIndex,
    required this.date,
    required this.plannedExercises,
    required this.completedExercises,
    required this.blockSettings,
    required this.weekIndex,
    required this.sessionIndex,
    this.sessionIndexByExerciseId,
    required this.uid,
    required this.allExercises,
    required this.templates,
    required this.onSave,
    required this.onDrop,
    required this.onMoveAllToNextDay,
    required this.isInsideBlock,
    this.blockId,
    this.onBlockSettingsChanged,
    this.allWeekPlannedByDay = const [],
    this.allWeekCompletedByDay = const [],
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
  bool _pendingSave = false;

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
    // Best-effort flush: snapshot current controller state before controllers are
    // disposed. Calls savePlannedDay directly — no setState — so this is safe even
    // after the parent (BB3WeekPlanner) has been deactivated. The returned Future is
    // intentionally unawaited; Firestore's offline queue guarantees the write.
    final bid = widget.blockId;
    if (_orderedExIds.isNotEmpty && bid != null && bid.isNotEmpty) {
      final exercises = _buildCurrentExercises();
      debugPrint('[BB3 dispose flush] day=${widget.dayIndex} count=${exercises.length}');
      final blockDayIndex = widget.blockSettings?.startDate != null
          ? BB3PlannedExerciseService.dateToWeekDay(
              widget.blockSettings!.startDate!, widget.date).dayIndex
          : widget.dayIndex;
      // ignore: discarded_futures
      BB3PlannedExerciseService.savePlannedDay(
        uid: widget.uid,
        blockId: bid,
        weekIndex: widget.weekIndex,
        dayIndex: blockDayIndex,
        exercises: exercises,
      );
    }

    for (final list in _weightCtrl.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    for (final list in _repsCtrl.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    for (final list in _rirCtrl.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    for (final list in _notesCtrl.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    for (final list in _focusNodes.values) {
      for (final fn in list) {
        fn.dispose();
      }
    }
    for (final list in _velocityCtrl.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    for (final list in _velocityFocusNodes.values) {
      for (final fn in list) {
        fn.dispose();
      }
    }
    super.dispose();
  }

  // ── Controller management ─────────────────────────────────────────────────

  void _rebuildControllers(List<BB3Exercise> exercises) {
    // Preserve existing controller values for exercises still present
    final keep = exercises.map((e) => e.exerciseId).toSet();

    // Dispose removed exercises' controllers — spare locally-staged ones
    final toRemove = _weightCtrl.keys
        .where((id) => !keep.contains(id) && !_localExercises.containsKey(id))
        .toList();
    for (final id in toRemove) {
      for (final c in _weightCtrl[id]!) {
        c.dispose();
      }
      for (final c in _repsCtrl[id]!) {
        c.dispose();
      }
      for (final c in _rirCtrl[id]!) {
        c.dispose();
      }
      for (final c in _notesCtrl[id]!) {
        c.dispose();
      }
      for (final fn in _focusNodes[id]!) {
        fn.dispose();
      }
      for (final c in _velocityCtrl[id] ?? []) {
        c.dispose();
      }
      for (final fn in _velocityFocusNodes[id] ?? []) {
        fn.dispose();
      }
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

    // Append locally-staged IDs not yet reflected by the parent
    final localOnlyIds = _orderedExIds
        .where((id) => _localExercises.containsKey(id) && !keep.contains(id))
        .toList();
    _orderedExIds = [...exercises.map((e) => e.exerciseId), ...localOnlyIds];
  }

  String _fmtNum(double v) {
    if (v == v.truncateToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(v.remainder(0.5) == 0 ? 1 : 2);
  }

  // ── Save on unfocus ───────────────────────────────────────────────────────
  // Fires when any field loses focus. Reads all current controller values
  // and saves the full day. _saveInProgress guards against concurrent saves.

  void _saveIfDirty() {
    if (!mounted) return;
    if (_saveInProgress) {
      _pendingSave = true;
      debugPrint('[BB3 save queued] day=${widget.dayIndex}');
      return;
    }
    _saveInProgress = true;
    _pendingSave = false;
    debugPrint('[BB3 save] start day=${widget.dayIndex} count=${_orderedExIds.length}');
    _doSave().whenComplete(() {
      _saveInProgress = false;
      debugPrint('[BB3 save] complete day=${widget.dayIndex} count=${_orderedExIds.length}');
      // Re-enter with a fresh _buildCurrentExercises() snapshot if a save was
      // requested while this one was in flight.
      if (_pendingSave && mounted) {
        _saveIfDirty();
      }
    });
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
                  ? theme.colorScheme.primary.withValues(alpha: 0.6)
                  : Colors.grey.shade300,
              width: isDragOver ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
            color: isDragOver
                ? theme.colorScheme.primary.withValues(alpha: 0.04)
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

  void _goToWorkoutForDay() {
    final userContext = UserContext.of(context, listen: false);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider<UserContext>.value(
          value: userContext,
          child: Wes2Screen(
            initialDate: widget.date,

          ),
        ),
      ),
    );
  }

  Widget _buildDayHeader(ThemeData theme, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.4),
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
            Icon(Icons.info_outline, size: 14, color: Colors.pink.shade200),
          ],
          const Spacer(),
          TextButton.icon(
            onPressed: _goToWorkoutForDay,
            icon: const Icon(Icons.fitness_center, size: 14),
            label: const Text('Go to Workout', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          PopupMenuButton<_BB3DayMenuAction>(
            padding: EdgeInsets.zero,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 5),
              child: SizedBox(
                width: 26,
                height: 22,
                child: Center(
                  child: Icon(Icons.more_vert, size: 18),
                ),
              ),
            ),
            onSelected: (action) {
              if (action == _BB3DayMenuAction.deleteAllExercises) {
                _confirmDeleteAllExercises();
              } else {
                widget.onMoveAllToNextDay(widget.dayIndex);
              }
            },
            itemBuilder: (_) {
              final hasUnlocked = _orderedExIds.any((id) =>
              !BB3HintService.isExerciseLocked(
                exerciseId: id,
                completedExercisesForDay: widget.completedExercises,
              ));
              return [
                PopupMenuItem(
                  value: _BB3DayMenuAction.deleteAllExercises,
                  enabled: hasUnlocked,
                  child: const Text('Delete all exercises'),
                ),
                PopupMenuItem(
                  value: _BB3DayMenuAction.moveAllToNextDay,
                  enabled: hasUnlocked,
                  child: const Text('Move all exercises to next day'),
                ),
              ];
            },
          ),
        ],
      ),
    );
  }

  // ── Theme-aware completed surface ────────────────────────────────────────
  // Derives a slightly darker tint from the active surface color so completed
  // rows stay in the same color family as the theme instead of hardcoding grey.

  Color _completedSurface(ThemeData theme) {
    return Color.alphaBlend(
      Colors.black.withValues(alpha: -0.62),
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
            const SizedBox(width: 18),
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

    //collapsed exercises labels header
    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 8, bottom: 1),
      child: Row(
        children: [
          const SizedBox(width: 49), // space for expand + drag icons
          Expanded(child: Text('Exercise', style: labelStyle)),
          const SizedBox(width: 7),
          fl('Weight', 32),
          const SizedBox(width:8),
          fl('Reps', 28),
          const SizedBox(width: 1),
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
    // Completed exercises that are already represented in the planned list
    // will render as locked BB3-style rows inside _buildPlannedSection().
    // Do not also render them here, or the same completed exercise appears twice
    // and shares the same _expandedByExId expansion state.
    final plannedIdentityKeys = <String>{};

    for (final ex in widget.plannedExercises) {
      final id = ex.exerciseId.trim().toLowerCase();
      final name = ex.name.trim().toLowerCase();
      if (id.isNotEmpty) plannedIdentityKeys.add(id);
      if (name.isNotEmpty) plannedIdentityKeys.add(name);
    }

    for (final id in _orderedExIds) {
      final key = id.trim().toLowerCase();
      if (key.isNotEmpty) plannedIdentityKeys.add(key);

      final local = _localExercises[id];
      final localName = local?.name.trim().toLowerCase();
      if (localName != null && localName.isNotEmpty) {
        plannedIdentityKeys.add(localName);
      }
    }

    // Group by exerciseId to show one row per completed-only exercise.
    // Planned+completed exercises are intentionally skipped because they are
    // shown once, in the better BB3-style locked row below.
    final Map<String, List<Map<String, dynamic>>> byExId = {};

    for (final ex in widget.completedExercises) {
      final id = (ex['exerciseId'] ?? ex['id'] ?? '').toString().trim();
      final name = (ex['name'] ?? ex['exercise'] ?? '').toString().trim();

      final idKey = id.toLowerCase();
      final nameKey = name.toLowerCase();

      final alreadyShownAsPlannedLockedRow =
          (idKey.isNotEmpty && plannedIdentityKeys.contains(idKey)) ||
              (nameKey.isNotEmpty && plannedIdentityKeys.contains(nameKey));

      if (alreadyShownAsPlannedLockedRow) {
        continue;
      }

      final groupKey = id.isNotEmpty ? id : name;
      if (groupKey.isEmpty) continue;

      byExId.putIfAbsent(groupKey, () => []).add(ex);
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
          ...byExId.entries.map((entry) {
            final stub = _completedOnlyStub(entry.key, entry.value);
            return _buildExerciseCard(theme, stub, true);
          }),
        ],
      ),
    );
  }

  BB3Exercise _completedOnlyStub(
    String exerciseId,
    List<Map<String, dynamic>> completedEntries,
  ) {
    final name = (completedEntries.first['name'] ??
            completedEntries.first['exercise'] ??
            exerciseId)
        .toString();
    final maxSets = completedEntries
        .map((e) => ((e['sets'] as List?)?.length ?? 0))
        .fold(0, (a, b) => a > b ? a : b);
    return BB3Exercise(
      exerciseId: exerciseId,
      name: name,
      circuitIndex: 0,
      orderIndex: 999,
      sets: List.generate(maxSets, (_) => const BB3Set()),
    );
  }

  // ignore: unused_element
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

    return Column(
      children: _orderedExIds.map((exId) {
        final idx = _orderedExIds.indexOf(exId);
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
        return DragTarget<_BB3DragPayload>(
          key: ValueKey(exId),
          onAcceptWithDetails: (details) {
            final payload = details.data;
            if (payload.sourceDayIndex == widget.dayIndex) {
              final fromIdx = _orderedExIds.indexOf(payload.exercise.exerciseId);
              final toIdx = _orderedExIds.indexOf(exId);
              if (fromIdx >= 0 && toIdx >= 0 && fromIdx != toIdx) {
                _onReorder(fromIdx, toIdx);
              }
            } else {
              widget.onDrop(payload.sourceDayIndex, widget.dayIndex, payload.exercise);
            }
          },
          builder: (ctx, candidateData, rejectedData) =>
              _buildExerciseCard(theme, ex, locked),
        );
      }).toList(),
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

  // ── Settings dialog ───────────────────────────────────────────────────────
  //
  // Opens Wes2ExerciseSettingsDialog for the given planned exercise.
  // Computes completedInstanceCount (Task B) and resolvedActiveInstanceOverride
  // (Task C Level 2) asynchronously before showing the dialog.

  Future<void> _openExerciseSettings(BB3Exercise ex) async {
    final blockId = widget.blockId;
    if (blockId == null || blockId.isEmpty) return;

    final exSettings =
        widget.blockSettings?.exerciseSettings[ex.exerciseId] as Map<String, dynamic>?;
    final model = (exSettings?['periodizationModel'] as String?) ?? '';

    int totalBlockWeeks = 12;
    if (widget.blockSettings?.startDate != null &&
        widget.blockSettings?.endDate != null) {
      final days = widget.blockSettings!.endDate!
          .difference(widget.blockSettings!.startDate!)
          .inDays;
      totalBlockWeeks = (days / 7).ceil().clamp(1, 100);
    }

    int? completedCount;
    int? resolvedInstance;

    if (widget.blockSettings?.startDate != null) {
      final d = widget.date;
      final currentWeekStart = DateTime(d.year, d.month, d.day)
          .subtract(Duration(days: widget.dayIndex));
      final allWeekPlanned = widget.allWeekPlannedByDay.isNotEmpty
          ? widget.allWeekPlannedByDay
          : List.generate(7, (_) => <BB3Exercise>[]);
      final allWeekCompleted = widget.allWeekCompletedByDay.isNotEmpty
          ? widget.allWeekCompletedByDay
          : List.generate(7, (_) => <Map<String, dynamic>>[]);

      try {
        completedCount =
            await BB3PlannedExerciseService.getGlobalBlockExposureCount(
          exerciseId: ex.exerciseId,
          exerciseName: ex.name,
          blockStartDate: widget.blockSettings!.startDate!,
          selectedDate: widget.date,
          uid: widget.uid,
          blockId: blockId,
          currentWeekPlannedByDay: allWeekPlanned,
          currentWeekCompletedByDay: allWeekCompleted,
          currentWeekStart: currentWeekStart,
          currentDayIndexInWeek: widget.dayIndex,
        );
      } catch (_) {}

      if (model == 'DUP, By Exposure' || model == 'DUP, Signature') {
        try {
          resolvedInstance =
              await BB3PlannedExerciseService.resolveBb3ModelInstanceIndex(
            exerciseId: ex.exerciseId,
            exerciseName: ex.name,
            periodizationModel: model,
            blockStartDate: widget.blockSettings!.startDate!,
            selectedDate: widget.date,
            uid: widget.uid,
            blockId: blockId,
            currentWeekPlannedByDay: allWeekPlanned,
            currentWeekCompletedByDay: allWeekCompleted,
            currentWeekStart: currentWeekStart,
            currentDayIndexInWeek: widget.dayIndex,
          );
        } catch (_) {}
      }
    }

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => Wes2ExerciseSettingsDialog(
        uid: widget.uid,
        blockId: blockId,
        exerciseId: ex.exerciseId,
        exerciseName: ex.name,
        weekIndex: widget.weekIndex,
        dayIndex: widget.dayIndex,
        totalBlockWeeks: totalBlockWeeks,
        planService: FirestoreWes2PlanService(),
        completedInstanceCount: completedCount,
        resolvedActiveInstanceOverride: resolvedInstance,
      ),
    );

    widget.onBlockSettingsChanged?.call();
  }

  // ── Row hint cascade (Task D) ─────────────────────────────────────────────
  //
  // Pre-computes all set hints for one exercise using WES2 cascade:
  //   Set 0: BB3HintService.getHintsForSet with correct BB3 session index.
  //   Sets 1+: Wes2HintServiceImpl.computeRowHints cascades from Set 0.
  // Set 0 is marked FieldOrigin.bb3Hint so computeRowHints never overwrites it.
  // Returns an empty list for locked (completed) rows — hints are not shown there.

  List<BB3SetHint> _computeRowHintsViaCascade(BB3Exercise ex) {
    if (widget.blockSettings == null ||
        widget.blockSettings!.startDate == null) {
      return List.generate(ex.sets.length, (_) => const BB3SetHint());
    }

    final exId = ex.exerciseId;
    final sessionIndex =
        widget.sessionIndexByExerciseId?[exId] ?? widget.sessionIndex;

    final wCtrls = _weightCtrl[exId];
    final rCtrls = _repsCtrl[exId];
    final rirCtrls = _rirCtrl[exId];
    final double? userW0 = (wCtrls != null && wCtrls.isNotEmpty)
        ? double.tryParse(wCtrls[0].text.trim())
        : null;
    final int? userR0 = (rCtrls != null && rCtrls.isNotEmpty)
        ? int.tryParse(rCtrls[0].text.trim())
        : null;
    final double? userRir0 = (rirCtrls != null && rirCtrls.isNotEmpty)
        ? double.tryParse(rirCtrls[0].text.trim())
        : null;

    // Set 0: use correct BB3 session index
    final set0 = BB3HintService.getHintsForSet(
      exerciseId: exId,
      exerciseName: ex.name,
      fullExerciseSettings: widget.blockSettings!.exerciseSettings,
      weekIndex: widget.weekIndex,
      sessionIndex: sessionIndex,
      setIndex: 0,
      blockStartDate: widget.blockSettings!.startDate!,
      blockEndDate: widget.blockSettings!.endDate,
      selectedDate: widget.date,
      uid: widget.uid,
      circuitIndex: ex.circuitIndex,
      userWeight: userW0,
      userReps: userR0,
      userRir: userRir0,
    );

    if (ex.sets.length <= 1) return [set0];

    final blockId = widget.blockId;
    if (blockId == null || blockId.isEmpty) {
      return [set0, ...List.generate(ex.sets.length - 1, (_) => const BB3SetHint())];
    }

    // Build Wes2ExerciseRow with Set 0 locked as bb3Hint
    final rawW0 =
        double.tryParse(set0.weightDisplay.split('–').first.trim());
    final rawR0 = int.tryParse(set0.repsDisplay);
    final rawRir0 = double.tryParse(set0.rirDisplay);

    final setStates = <Wes2SetState>[
      Wes2SetState(
        setIndex: 0,
        weight: Wes2FieldState<double>(
          hintValue: rawW0,
          hintOrigin: FieldOrigin.bb3Hint,
          origin: FieldOrigin.bb3Hint,
          actualValue: userW0,
        ),
        reps: Wes2FieldState<int>(
          hintValue: rawR0,
          hintOrigin: FieldOrigin.bb3Hint,
          origin: FieldOrigin.bb3Hint,
          actualValue: userR0,
        ),
        rir: Wes2FieldState<double>(
          hintValue: rawRir0,
          hintOrigin: FieldOrigin.bb3Hint,
          origin: FieldOrigin.bb3Hint,
          actualValue: userRir0,
        ),
      ),
      for (int i = 1; i < ex.sets.length; i++) Wes2SetState(setIndex: i),
    ];

    final tempRow = Wes2ExerciseRow(
      exerciseId: exId,
      name: ex.name,
      circuitIndex: ex.circuitIndex,
      orderIndex: ex.orderIndex,
      setCount: ex.sets.length,
      sets: setStates,
      source: Wes2RowSource.bb3Planned,
    );

    final hintSvc = Wes2HintServiceImpl(
      exerciseSettings: widget.blockSettings!.exerciseSettings,
      blockStartDate: widget.blockSettings!.startDate!,
      blockEndDate: widget.blockSettings!.endDate,
      uid: widget.uid,
    );

    final resultRow = hintSvc.computeRowHints(
      row: tempRow,
      blockId: blockId,
      uid: widget.uid,
      date: widget.date,
    );

    return List.generate(ex.sets.length, (i) {
      if (i == 0) return set0;
      final s = i < resultRow.sets.length
          ? resultRow.sets[i]
          : Wes2SetState(setIndex: i);
      final w = s.weight.hintValue;
      final r = s.reps.hintValue;
      final rir = s.rir.hintValue;
      return BB3SetHint(
        weightDisplay: w != null ? _fmtNum(w) : '',
        repsDisplay: r != null ? r.toString() : '',
        rirDisplay: rir != null ? _fmtNum(rir) : '',
      );
    });
  }

  // ── Exercise card ─────────────────────────────────────────────────────────
  //
  // Collapsed: single compact row — name + all set fields + controls in one line.
  // Expanded: header row + one row per set (each with set# + same field layout).
  // Long-press required for both within-day reorder and cross-day drag.

  Widget _buildExerciseCard(
    ThemeData theme,
    BB3Exercise ex,
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

    // Pre-compute all set hints once (Task D cascade). Locked rows don't show hints.
    final hints = locked ? <BB3SetHint>[] : _computeRowHintsViaCascade(ex);
    BB3SetHint hintFor(int si) =>
        si < hints.length ? hints[si] : const BB3SetHint();

    Widget card = Container(
      color: cardColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isExpanded)
            // ── Collapsed: horizontally scrollable row ──────────────────
            InkWell(
              onTap: () =>
                  setState(() => _expandedByExId[exId] = true),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.expand_more,
                          size: 14, color: Colors.grey.shade400),
                      const SizedBox(width: 2),
                      if (!locked)
                        Icon(Icons.drag_handle,
                            size: 1, color: Colors.grey.shade400),
                      const SizedBox(width: 3),
                      SizedBox(
                        width: 110,
                        child: Text(
                          ex.name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            fontSize: 10,
                            fontStyle: locked ? FontStyle.italic : null,
                            color: locked ? Colors.grey.shade100 : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 1),
                      ..._setFieldWidgets(
                          theme, ex, visibleSetIndex, locked,
                          expandedMode: false,
                          hint: hintFor(visibleSetIndex)),
                      if (!locked) ...[
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () => _openExerciseSettings(ex),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: Icon(Icons.settings,
                                size: 20, color: Colors.grey.shade400),
                          ),
                        ),
                        PopupMenuButton<_BB3ExMenuAction>(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 28, minHeight: 22),
                          child: SizedBox(
                            width: 24,
                            height: 22,
                            child: Icon(Icons.more_vert,
                                size: 16, color: Colors.grey.shade400),
                          ),
                          onSelected: (action) {
                            if (action == _BB3ExMenuAction.deleteExercise) {
                              _confirmDelete(ex);
                            } else {
                              _showReplaceExerciseDialog(theme, ex);
                            }
                          },
                          itemBuilder: (_) => _buildExMenuItems(),
                        ),
                      ],
                    ],
                  ),
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
                      Icon(Icons.drag_handle,
                          size: 16, color: Colors.grey.shade400),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text(
                        ex.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          fontStyle: locked ? FontStyle.italic : null,
                          color: locked ? Colors.grey.shade100 : null,
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
                        size: 18,
                        color: Colors.cyanAccent,
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
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () => _openExerciseSettings(ex),
                        child: Icon(Icons.settings,
                            size: 20, color: Colors.grey.shade400),
                      ),
                      const SizedBox(width: 2),
                      PopupMenuButton<_BB3ExMenuAction>(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                            minWidth: 30, minHeight: 22),
                        child: SizedBox(
                          width: 24,
                          height: 22,
                          child: Icon(Icons.more_vert,
                              size: 16, color: Colors.grey.shade400),
                        ),
                        onSelected: (action) {
                          if (action == _BB3ExMenuAction.deleteExercise) {
                            _confirmDelete(ex);
                          } else {
                            _showReplaceExerciseDialog(theme, ex);
                          }
                        },
                        itemBuilder: (_) => _buildExMenuItems(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 7, right: 6, bottom: 2),
              child: Row(
                children: [
                  const SizedBox(width: 22), // aligns with S1 / S2 / S3
                  SizedBox(
                    width: 47,
                    child: Text('Weight',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.grey.shade100,
                          fontSize: 10,
                        )),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 36,
                    child: Text('Reps',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.grey.shade100,
                          fontSize: 10,
                        )),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 36,
                    child: Text('RIR',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.grey.shade100,
                          fontSize: 10,
                        )),
                  ),
                  const SizedBox(width: 7),
                  SizedBox(
                    width: 40,
                    child: Text('E1RM',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.grey.shade100,
                          fontSize: 10,
                        )),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 38,
                    child: Text('Vel',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.grey.shade100,
                          fontSize: 10,
                        )),
                  ),
                  const SizedBox(width: 8),
                  Text('Notes',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.grey.shade100,
                        fontSize: 10,
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
                            ?.copyWith(color: Colors.grey.shade100),
                      ),
                    ),
                    ..._setFieldWidgets(theme, ex, si, locked,
                        expandedMode: true, hint: hintFor(si)),
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
          Divider(height: 0.5, color: Colors.grey.shade400),
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
    required BB3SetHint hint,
  }) {
    final exId = ex.exerciseId;
    final wCtrls = _weightCtrl[exId];
    final rCtrls = _repsCtrl[exId];
    final rirCtrls = _rirCtrl[exId];
    final fns = _focusNodes[exId];

    Map<String, dynamic>? completedSet;
    if (locked) {
      for (final comp in widget.completedExercises) {
        final cId = (comp['exerciseId'] ?? comp['id'] ?? '').toString();
        if (cId != exId) continue;
        final sets = comp['sets'] as List?;
        if (sets != null && setIndex < sets.length && sets[setIndex] is Map) {
          completedSet = Map<String, dynamic>.from(sets[setIndex] as Map);
        }
      }
    }

    final bool controllersPresent = wCtrls != null &&
        setIndex < wCtrls.length &&
        fns != null &&
        setIndex * 3 + 2 < fns.length;

    if (!controllersPresent) {
      if (locked && completedSet != null) {
        return _buildLockedCompletedSetWidgets(
            theme, ex, setIndex, completedSet, expandedMode: expandedMode);
      }
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

    // Hint is pre-computed by _computeRowHintsViaCascade in _buildExerciseCard.

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

    final wWidth = expandedMode ? 60.0 : 55.0;
    final rWidth = expandedMode ? 40.0 : 32.0;
    final rirWidth = expandedMode ? 41.0 : 41.0;
    final e1rmWidth = expandedMode ? 48.0 : 41.0;
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
            color: Colors.white,
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
                  ? Colors.pink.shade200
                  : (locked ? Colors.grey.shade100 : null),
            ),
            decoration: InputDecoration(
              hintText: 'm/s',
              hintStyle: TextStyle(
                  color: Colors.grey.shade100, fontSize: 10),
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
      const SizedBox(width: 6),
      // Per-set note button — highlights when note is non-empty
      GestureDetector(
        onTap: () => _showSetNoteDialog(theme, exId, setIndex),
        child: Icon(
          Icons.edit_note,
          size: 24,
          color: (_notesCtrl[exId]?.elementAtOrNull(setIndex)?.text
                      .isNotEmpty ==
                  true)
              ? theme.colorScheme.secondary
              : Colors.grey.shade100,
        ),
      ),
    ];
  }

  List<Widget> _buildLockedCompletedSetWidgets(
    ThemeData theme,
    BB3Exercise ex,
    int setIndex,
    Map<String, dynamic> completedSet, {
    required bool expandedMode,
  }) {
    final exId = ex.exerciseId;
    final wWidth = expandedMode ? 60.0 : 55.0;
    final rWidth = expandedMode ? 40.0 : 32.0;
    const rirWidth = 41.0;
    final e1rmWidth = expandedMode ? 48.0 : 41.0;
    final velWidth = expandedMode ? 38.0 : 34.0;

    final double? dispW = (completedSet['weight'] as num?)?.toDouble();
    final double? dispR = (completedSet['reps'] as num?)?.toDouble();
    final double dispRir = (completedSet['rir'] as num?)?.toDouble() ?? 0.0;
    String e1rmLabel = '';
    if (dispW != null && dispW > 0 && dispR != null && dispR > 0) {
      final e1rm = PeriodizationModelUtils.calculateE1RM(dispW, dispR, dispRir);
      if (e1rm > 0) e1rmLabel = _fmtNum(e1rm);
    }
    final String velValue = completedSet['velocity']?.toString() ?? '';

    return [
      _lockedReadOnlyCell(
          theme: theme,
          value: completedSet['weight']?.toString() ?? '',
          label: 'kg',
          width: wWidth),
      const SizedBox(width: 3),
      _lockedReadOnlyCell(
          theme: theme,
          value: completedSet['reps']?.toString() ?? '',
          label: 'reps',
          width: rWidth),
      const SizedBox(width: 3),
      _lockedReadOnlyCell(
          theme: theme,
          value: completedSet['rir']?.toString() ?? '',
          label: 'RIR',
          width: rirWidth),
      const SizedBox(width: 1),
      SizedBox(
        width: e1rmWidth,
        child: Text(
          e1rmLabel,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 10, color: Colors.white, fontStyle: FontStyle.italic),
        ),
      ),
      const SizedBox(width: 1),
      _lockedReadOnlyCell(
          theme: theme, value: velValue, label: 'm/s', width: velWidth),
      const SizedBox(width: 6),
      GestureDetector(
        onTap: () => _showSetNoteDialog(theme, exId, setIndex),
        child: Icon(Icons.edit_note, size: 24, color: Colors.grey.shade100),
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
      textColor = Colors.pink.shade200; // salmon pink for BB3-entered values
    } else if (locked) {
      textColor = Colors.grey.shade600;
    }

    final Color? fillColor = isCompleted ? Colors.grey.shade800 : null;

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
            color: hint.isEmpty ? Colors.grey.shade300 : Colors.white,
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

  Widget _lockedReadOnlyCell({
    required ThemeData theme,
    required String value,
    required String label,
    required double width,
  }) {
    final bool hasValue = value.isNotEmpty;
    return SizedBox(
      width: width,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade800,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.grey.shade300, width: 0.5),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        alignment: Alignment.center,
        child: Text(
          hasValue ? value : label,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 11,
            color: hasValue ? Colors.white : Colors.grey.shade300,
            fontStyle: hasValue ? FontStyle.italic : null,
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
            onPressed: () { _showAddExerciseDialog(theme); },
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
                : () { _showTemplateDialog(theme); },
          ),
        ],
      ),
    );
  }

  // ── Add exercise dialog ───────────────────────────────────────────────────

  Future<void> _showAddExerciseDialog(ThemeData theme) async {
    final selected = await showModalBottomSheet<List<Map<String, dynamic>>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _BB3AddExercisePicker(
        allExercises: widget.allExercises,
        alreadyPresentIds: _alreadyPresentExIds,
        blockSettings: widget.blockSettings,
      ),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    for (final ex in selected) {
      _addExercise(ex);
    }
  }

  BB3Exercise? _buildExerciseFromLibraryMap(
    Map<String, dynamic> ex, {
    required int orderIndex,
    int circuitIndex = 0,
  }) {
    final exerciseId =
        (ex['id'] ?? ex['exerciseId'] ?? ex['name'] ?? '').toString().trim();
    final name = (ex['name'] ?? exerciseId).toString();
    if (exerciseId.isEmpty) return null;

    int setCount = 3;
    if (widget.blockSettings != null) {
      final exSettings = widget.blockSettings!.settingsFor(exerciseId);
      if (exSettings.isNotEmpty) {
        setCount = BB3PlannedExerciseService.resolveSetCount(
          exSettings: exSettings,
          weekIndex: widget.weekIndex,
          sessionIndex:
              widget.sessionIndexByExerciseId?[exerciseId] ?? widget.sessionIndex,
        );
      }
    }

    return BB3Exercise(
      exerciseId: exerciseId,
      name: name,
      circuitIndex: circuitIndex,
      orderIndex: orderIndex,
      sets: List.generate(setCount, (_) => const BB3Set()),
    );
  }

  void _initControllersForExercise(String id, int setCount) {
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
  }

  void _addExercise(Map<String, dynamic> ex) {
    final newEx = _buildExerciseFromLibraryMap(
      ex,
      orderIndex: _orderedExIds.length,
    );
    if (newEx == null) return;
    final setCount = newEx.sets.length;

    setState(() {
      _localExercises[newEx.exerciseId] = newEx;
      _initControllersForExercise(newEx.exerciseId, setCount);
      _orderedExIds.add(newEx.exerciseId);
    });

    // Persist immediately
    _saveIfDirty();
  }

  // ── Replace exercise ──────────────────────────────────────────────────────

  Future<void> _showReplaceExerciseDialog(
      ThemeData theme, BB3Exercise oldEx) async {
    final blockedIds = Set<String>.from(_alreadyPresentExIds)
      ..remove(oldEx.exerciseId.toLowerCase());
    final result = await showModalBottomSheet<List<Map<String, dynamic>>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _BB3AddExercisePicker(
        allExercises: widget.allExercises,
        alreadyPresentIds: blockedIds,
        blockSettings: widget.blockSettings,
        multiSelect: false,
        title: 'Replace Exercise',
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    _replaceExercise(oldEx, result.first);
  }

  void _replaceExercise(BB3Exercise oldEx, Map<String, dynamic> replacementMap) {
    final replacement = _buildExerciseFromLibraryMap(
      replacementMap,
      orderIndex: oldEx.orderIndex,
      circuitIndex: oldEx.circuitIndex,
    );
    if (replacement == null) return;

    final newId = replacement.exerciseId;
    if (newId == oldEx.exerciseId) return;

    final otherIds =
        _orderedExIds.where((id) => id != oldEx.exerciseId).toSet();
    if (otherIds.contains(newId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Exercise already exists on this day.')),
      );
      return;
    }

    setState(() {
      final idx = _orderedExIds.indexOf(oldEx.exerciseId);
      if (idx >= 0) {
        _orderedExIds[idx] = newId;
      }
      _disposeExerciseControllers(oldEx.exerciseId);
      _localExercises.remove(oldEx.exerciseId);
      _expandedByExId.remove(oldEx.exerciseId);
      _viewedNoteExIds.remove(oldEx.exerciseId);
      // Stage replacement before _saveIfDirty so _buildCurrentExercises resolves it
      _localExercises[newId] = replacement;
      _initControllersForExercise(newId, replacement.sets.length);
    });

    _saveIfDirty();
    // ignore: discarded_futures
    BB3PlannedExerciseService.removeExerciseFromWorkoutDoc(
      uid: widget.uid,
      date: widget.date,
      exerciseId: oldEx.exerciseId,
    );
  }

  // ── Template dialog ───────────────────────────────────────────────────────

  Future<void> _showTemplateDialog(ThemeData theme) async {
    final templateId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => BB3TemplatePicker(
        uid: widget.uid,
        activeBlockId: widget.blockId,
      ),
    );
    if (templateId == null || !mounted) return;
    Template? selected;
    for (final t in widget.templates) {
      if (t.id == templateId) {
        selected = t;
        break;
      }
    }
    if (selected != null) {
      _loadTemplate(selected);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Template could not be loaded.')),
      );
    }
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
            sessionIndex: widget.sessionIndexByExerciseId?[exId] ?? widget.sessionIndex,
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

    // Stage each exercise locally so _rebuildControllers preserves them if
    // didUpdateWidget fires before the parent reflects the new list.
    setState(() {
      for (final ex in newExercises) {
        _localExercises[ex.exerciseId] = ex;
      }
      _rebuildControllers(newExercises);
    });

    // Save immediately
    widget.onSave(widget.dayIndex, newExercises);
  }

  // ── Per-exercise menu ─────────────────────────────────────────────────────

  List<PopupMenuEntry<_BB3ExMenuAction>> _buildExMenuItems() {
    return [
      PopupMenuItem<_BB3ExMenuAction>(
        value: _BB3ExMenuAction.deleteExercise,
        child: Row(
          children: [
            Icon(Icons.close, size: 16, color: Colors.red.shade400),
            const SizedBox(width: 8),
            const Text('Delete exercise'),
          ],
        ),
      ),
      const PopupMenuItem<_BB3ExMenuAction>(
        value: _BB3ExMenuAction.replaceExercise,
        child: Row(
          children: [
            Icon(Icons.swap_horiz, size: 16),
            SizedBox(width: 8),
            Text('Replace exercise'),
          ],
        ),
      ),
    ];
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

  void _disposeExerciseControllers(String id) {
    for (final c in _weightCtrl[id] ?? []) {
      c.dispose();
    }
    for (final c in _repsCtrl[id] ?? []) {
      c.dispose();
    }
    for (final c in _rirCtrl[id] ?? []) {
      c.dispose();
    }
    for (final c in _notesCtrl[id] ?? []) {
      c.dispose();
    }
    for (final fn in _focusNodes[id] ?? []) {
      fn.dispose();
    }
    for (final c in _velocityCtrl[id] ?? []) {
      c.dispose();
    }
    for (final fn in _velocityFocusNodes[id] ?? []) {
      fn.dispose();
    }
    _weightCtrl.remove(id);
    _repsCtrl.remove(id);
    _rirCtrl.remove(id);
    _notesCtrl.remove(id);
    _focusNodes.remove(id);
    _velocityCtrl.remove(id);
    _velocityFocusNodes.remove(id);
  }

  void _deleteExercise(BB3Exercise ex) {
    setState(() {
      _orderedExIds.remove(ex.exerciseId);
      _disposeExerciseControllers(ex.exerciseId);
    });
    _saveIfDirty();
    // ignore: discarded_futures
    BB3PlannedExerciseService.removeExerciseFromWorkoutDoc(
      uid: widget.uid,
      date: widget.date,
      exerciseId: ex.exerciseId,
    );
  }

  Future<void> _confirmDeleteAllExercises() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete All exercises'),
        content: const Text(
            'This will delete all exercises for this day, are you sure?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade600),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) _deleteAllExercises();
  }

  void _deleteAllExercises() {
    final toDelete = _orderedExIds
        .where((id) => !BB3HintService.isExerciseLocked(
              exerciseId: id,
              completedExercisesForDay: widget.completedExercises,
            ))
        .toList();
    if (toDelete.isEmpty) return;

    final exerciseRefs = toDelete.map((id) {
      return widget.plannedExercises.firstWhere(
        (e) => e.exerciseId == id,
        orElse: () =>
            _localExercises[id] ??
            BB3Exercise(
              exerciseId: id,
              name: id,
              circuitIndex: 0,
              orderIndex: 0,
              sets: const [],
            ),
      );
    }).toList();

    setState(() {
      for (final id in toDelete) {
        _orderedExIds.remove(id);
        _disposeExerciseControllers(id);
        _localExercises.remove(id);
        _expandedByExId.remove(id);
        _viewedNoteExIds.remove(id);
      }
    });

    _saveIfDirty();

    for (final ex in exerciseRefs) {
      // ignore: discarded_futures
      BB3PlannedExerciseService.removeExerciseFromWorkoutDoc(
        uid: widget.uid,
        date: widget.date,
        exerciseId: ex.exerciseId,
      );
    }
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

// ── Day menu action ───────────────────────────────────────────────────────────

enum _BB3DayMenuAction { deleteAllExercises, moveAllToNextDay }
enum _BB3ExMenuAction { deleteExercise, replaceExercise }

// ── Drag payload ──────────────────────────────────────────────────────────────

class _BB3DragPayload {
  final int sourceDayIndex;
  final BB3Exercise exercise;
  const _BB3DragPayload({required this.sourceDayIndex, required this.exercise});
}

// ── Add Exercise picker ───────────────────────────────────────────────────────

class _BB3AddExercisePicker extends StatefulWidget {
  final List<Map<String, dynamic>> allExercises;
  final Set<String> alreadyPresentIds;
  final BB3BlockSettings? blockSettings;
  final bool multiSelect;
  final String title;

  const _BB3AddExercisePicker({
    required this.allExercises,
    required this.alreadyPresentIds,
    this.blockSettings,
    this.multiSelect = true,
    this.title = 'Add Exercise',
  });

  @override
  State<_BB3AddExercisePicker> createState() => _BB3AddExercisePickerState();
}

class _BB3AddExercisePickerState extends State<_BB3AddExercisePicker> {
  static const List<String> _categoryOrder = [
    'Horizontal Press', 'Horizontal Pull',
    'Vertical Press', 'Vertical Pull',
    'Lateral Raise',
    'Arm Extension', 'Arm Curl',
    'Squat Pattern', 'Hip Hinge',
    'Leg Extension', 'Leg Curl',
    'Hip Abduction/adduction', 'Calf Raise',
    'Core',
  ];

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  bool _showPlannedOnly = false;
  Set<String> _plannedIds = {};
  late final Set<String> _expandedCategories;
  final Set<String> _selectedIds = {};
  final Map<String, Map<String, dynamic>> _selectedById = {};

  @override
  void initState() {
    super.initState();
    if (widget.blockSettings != null) {
      _plannedIds = widget.blockSettings!.exerciseSettings.keys.toSet();
      _showPlannedOnly = _plannedIds.isNotEmpty;
    }
    _expandedCategories = {..._categoryOrder, 'Other'};
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _visibleExercises() {
    var list = widget.allExercises.where((ex) {
      final id = (ex['id'] ?? ex['exerciseId'] ?? ex['name'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      return !widget.alreadyPresentIds.contains(id);
    }).toList();
    if (_showPlannedOnly && _plannedIds.isNotEmpty) {
      list = list.where((ex) {
        final id = (ex['id'] ?? ex['exerciseId'] ?? ex['name'] ?? '')
            .toString()
            .trim();
        return _plannedIds.contains(id);
      }).toList();
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list
          .where(
              (ex) => (ex['name'] ?? '').toString().toLowerCase().contains(q))
          .toList();
    }
    return list;
  }

  Map<String, List<Map<String, dynamic>>> _groupedExercises(
      List<Map<String, dynamic>> exercises) {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final cat in _categoryOrder) {
      map[cat] = [];
    }
    map['Other'] = [];
    for (final ex in exercises) {
      final cat = (ex['category'] ?? 'Other').toString();
      if (_categoryOrder.contains(cat)) {
        map[cat]!.add(ex);
      } else {
        map['Other']!.add(ex);
      }
    }
    for (final list in map.values) {
      list.sort((a, b) => (a['name'] ?? '')
          .toString()
          .toLowerCase()
          .compareTo((b['name'] ?? '').toString().toLowerCase()));
    }
    map.removeWhere((_, list) => list.isEmpty);
    return map;
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollCtrl) => Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                if (_plannedIds.isNotEmpty) _buildPlannedToggle(),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: 'Search exercises…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(child: _buildList(scrollCtrl)),
          const Divider(height: 1),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('Cancel'),
                  ),
                  if (widget.multiSelect) ...[
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _selectedIds.isEmpty ? null : _onSave,
                      child: Text(
                        _selectedIds.isEmpty
                            ? 'Add'
                            : 'Add (${_selectedIds.length})',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlannedToggle() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Planned',
          style: TextStyle(fontSize: 12, color: Colors.white70),
        ),
        Switch(
          value: _showPlannedOnly,
          onChanged: (v) => setState(() => _showPlannedOnly = v),
        ),
      ],
    );
  }

  Widget _buildList(ScrollController scrollCtrl) {
    final visible = _visibleExercises();
    if (visible.isEmpty) {
      return const Center(
        child: Text(
          'No exercises found.',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    if (_query.isNotEmpty) {
      final sorted = List.of(visible)
        ..sort((a, b) => (a['name'] ?? '')
            .toString()
            .toLowerCase()
            .compareTo((b['name'] ?? '').toString().toLowerCase()));
      return ListView.builder(
        controller: scrollCtrl,
        itemCount: sorted.length,
        itemBuilder: (_, i) => _buildTile(sorted[i]),
      );
    }
    final groups = _groupedExercises(visible);
    final items = <Widget>[];
    for (final entry in groups.entries) {
      final cat = entry.key;
      final exercises = entry.value;
      final isExpanded = _expandedCategories.contains(cat);
      items.add(_buildCategoryHeader(cat, isExpanded));
      if (isExpanded) {
        for (final ex in exercises) {
          items.add(_buildTile(ex));
        }
      }
    }
    return ListView(controller: scrollCtrl, children: items);
  }

  Widget _buildCategoryHeader(String category, bool isExpanded) {
    return InkWell(
      onTap: () => setState(() {
        if (isExpanded) {
          _expandedCategories.remove(category);
        } else {
          _expandedCategories.add(category);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Row(
          children: [
            Text(
              category.toUpperCase(),
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white38,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
              ),
            ),
            const Spacer(),
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              size: 16,
              color: Colors.white38,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTile(Map<String, dynamic> ex) {
    final rawId =
        (ex['id'] ?? ex['exerciseId'] ?? ex['name'] ?? '').toString().trim();
    final idKey = rawId.toLowerCase();
    final name = (ex['name'] ?? rawId).toString();

    if (!widget.multiSelect) {
      return ListTile(
        dense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        title: Text(
          name,
          style: const TextStyle(fontSize: 14),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        onTap: () => Navigator.of(context).pop([ex]),
      );
    }

    final isSelected = _selectedIds.contains(idKey);
    return CheckboxListTile(
      value: isSelected,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(
        name,
        style: const TextStyle(fontSize: 14),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
      onChanged: (checked) {
        setState(() {
          if (checked == true) {
            _selectedIds.add(idKey);
            _selectedById[idKey] = ex;
          } else {
            _selectedIds.remove(idKey);
            _selectedById.remove(idKey);
          }
        });
      },
    );
  }

  void _onSave() {
    final ordered = widget.allExercises.where((ex) {
      final id = (ex['id'] ?? ex['exerciseId'] ?? ex['name'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      return _selectedIds.contains(id);
    }).toList();
    Navigator.of(context).pop(ordered);
  }
}
