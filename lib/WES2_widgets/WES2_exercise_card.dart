import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../WES2_controller.dart';
import '../WES2_models.dart';
import '../exercise_video_button.dart';
import '../periodization_model_utils.dart';
import 'WES2_set_row.dart';

// blueGrey.shade400 and blueGrey.shade700 as compile-time constants.
const _kBb3AccentColor = Color(0xFF455A64); // blueGrey.shade700
const _kBb3LabelColor = Color(0xFF78909C); // blueGrey.shade400

enum _ExerciseCardMenuAction { notes, replace, moveToCircuit, delete }

PopupMenuItem<_ExerciseCardMenuAction> _menuItem({
  required _ExerciseCardMenuAction value,
  required IconData icon,
  required String label,
  bool enabled = true,
  bool destructive = false,
}) {
  final color = destructive ? Colors.redAccent : null;
  return PopupMenuItem<_ExerciseCardMenuAction>(
    value: value,
    enabled: enabled,
    height: 40,
    child: SizedBox(
      width: 190,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color),
            ),
          ),
        ],
      ),
    ),
  );
}

/// WES2 exercise card — visually matches WES CompactDark card style.
/// Uses ExpansionTile for in-session expand/collapse (no state persisted to
/// controller in Phase 5). Fields are read-only display cells; no write
/// behavior is implemented until Phase 5 write path.
class Wes2ExerciseCard extends StatelessWidget {
  final Wes2ExerciseRow row;
  final void Function(
    String exerciseId,
    int setIndex,
    Wes2FieldKey fieldKey,
    String rawText,
  ) onFieldUnfocused;
  final void Function(bool isDone) onToggleMarkedDone;
  final void Function() onAddSet;
  final VoidCallback? onSettings;
  final VoidCallback? onDelete;
  final VoidCallback? onReplace;
  final VoidCallback? onMoveToCircuit;
  final VoidCallback? onNotes;
  final void Function(int setIndex)? onRemoveSet;
  final void Function(int setIndex)? onNoteTap;
  final VoidCallback? onExerciseDetails;
  final VoidCallback? onTopSets;
  final VoidCallback? onOpenExercisePlanNote;
  final bool isExercisePlanNoteRead;
  final bool showVelocityField;

  const Wes2ExerciseCard({
    super.key,
    required this.row,
    required this.onFieldUnfocused,
    required this.onToggleMarkedDone,
    required this.onAddSet,
    this.onSettings,
    this.onDelete,
    this.onReplace,
    this.onMoveToCircuit,
    this.onNotes,
    this.onRemoveSet,
    this.onNoteTap,
    this.onExerciseDetails,
    this.onTopSets,
    this.onOpenExercisePlanNote,
    this.isExercisePlanNoteRead = false,
    this.showVelocityField = false,
  });

  static bool _isCompletedEligible(
      Wes2ExerciseRow row, Wes2ExerciseEntryMode mode) {
    switch (mode) {
      case Wes2ExerciseEntryMode.timedBodyweight:
        return row.sets.any((s) => s.reps.hasActual);
      case Wes2ExerciseEntryMode.timedWeighted:
        return row.sets.any((s) => s.weight.hasActual && s.reps.hasActual);
      case Wes2ExerciseEntryMode.normal:
        return row.isCompletedPillEligible;
    }
  }

  static Wes2ExerciseEntryMode _resolveEntryMode(String id, String name) {
    if (PeriodizationModelUtils.isWeightedTimedExercise(id: id)) {
      return Wes2ExerciseEntryMode.timedWeighted;
    }
    if (PeriodizationModelUtils.isTimedExercise(
        id: id,
        name: name,
        type: PeriodizationModelUtils.exerciseTypeById[id])) {
      return Wes2ExerciseEntryMode.timedBodyweight;
    }
    return Wes2ExerciseEntryMode.normal;
  }

  @override
  Widget build(BuildContext context) {
    // Pad sets list to row.setCount — build-time only, no model mutation.
    final paddedSets = List.generate(
      row.setCount,
      (i) => i < row.sets.length ? row.sets[i] : Wes2SetState(setIndex: i),
    );

    final showVelocity = showVelocityField ||
        row.sets.any((s) => s.velocity.hasActual || s.velocity.hasHint);

    final entryMode = _resolveEntryMode(row.exerciseId, row.name);
    final wes2Ctrl = Provider.of<Wes2SessionController>(context, listen: false);
    final bwDisplayText = entryMode == Wes2ExerciseEntryMode.timedBodyweight
        ? 'BW [${PeriodizationModelUtils.bodyweightKgForDate(
              uid: wes2Ctrl.actingUid,
              asOf: wes2Ctrl.selectedDate,
            ).toStringAsFixed(1)}kg]'
        : null;

    final bool isBb3 = row.source == Wes2RowSource.bb3Planned;
    final bool isDone = row.isMarkedDone;
    final cs = Theme.of(context).colorScheme;

    // ignore: deprecated_member_use
    final doneBg = cs.surfaceVariant.withValues(alpha: 0.6);
    final normalBg = cs.surface;

    final card = Card(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
      ),
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        key: ValueKey('${row.exerciseId}_done_$isDone'),
        initiallyExpanded: !isDone,
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        backgroundColor: isDone ? doneBg : normalBg,
        collapsedBackgroundColor: isDone ? doneBg : normalBg,
        // ── Title: exercise name + optional note icon ──
        title: Row(
          children: [
            Expanded(
              child: isBb3
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: _kBb3LabelColor.withValues(alpha: 0.65),
                          width: 1,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        row.name,
                        style: const TextStyle(fontSize: 14, height: 1.0),
                        maxLines: 2,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                      ),
                    )
                  : Text(
                      row.name,
                      style: const TextStyle(fontSize: 14, height: 1.0),
                      maxLines: 2,
                      softWrap: true,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            if (onOpenExercisePlanNote != null)
              GestureDetector(
                onTap: onOpenExercisePlanNote,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    Icons.sticky_note_2_outlined,
                    size: isExercisePlanNoteRead ? 16 : 20,
                    color: isExercisePlanNoteRead
                        ? Colors.grey.shade400
                        : Colors.amberAccent,
                  ),
                ),
              ),
          ],
        ),
        // ── Trailing: Done chip + active video + inactive settings/menu ────
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isDone) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                margin: const EdgeInsets.only(right: 1),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: Colors.green.withValues(alpha: 0.6)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle, size: 14, color: Colors.green),
                    SizedBox(width: 4),
                    Text(
                      'Done',
                      style: TextStyle(fontSize: 11, color: Colors.green),
                    ),
                  ],
                ),
              ),
            ],
            // Active — reuses existing ExerciseVideoButton; returns
            // SizedBox.shrink() when no asset exists for this exerciseId.
            ExerciseVideoButton(exerciseId: row.exerciseId),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              icon: Icon(Icons.insights, size: 20, color: cs.primary),
              onPressed: onExerciseDetails,
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              tooltip: 'Top Sets',
              icon: const Icon(Icons.bar_chart, size: 20, color: Colors.white70),
              onPressed: onTopSets,
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              icon: const Icon(Icons.settings, size: 20, color: Colors.grey),
              onPressed: onSettings,
            ),
            PopupMenuButton<_ExerciseCardMenuAction>(
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.more_vert, size: 18),
              onSelected: (action) {
                switch (action) {
                  case _ExerciseCardMenuAction.notes:
                    onNotes?.call();
                    break;
                  case _ExerciseCardMenuAction.replace:
                    onReplace?.call();
                    break;
                  case _ExerciseCardMenuAction.moveToCircuit:
                    onMoveToCircuit?.call();
                    break;
                  case _ExerciseCardMenuAction.delete:
                    onDelete?.call();
                    break;
                }
              },
              itemBuilder: (_) => [
                _menuItem(
                  value: _ExerciseCardMenuAction.notes,
                  icon: Icons.notes,
                  label: 'Notes',
                  enabled: onNotes != null,
                ),
                _menuItem(
                  value: _ExerciseCardMenuAction.replace,
                  icon: Icons.swap_horiz,
                  label: 'Replace Exercise',
                  enabled: onReplace != null,
                ),
                _menuItem(
                  value: _ExerciseCardMenuAction.moveToCircuit,
                  icon: Icons.move_down,
                  label: 'Move to Circuit',
                  enabled: onMoveToCircuit != null,
                ),
                _menuItem(
                  value: _ExerciseCardMenuAction.delete,
                  icon: Icons.delete_outline,
                  label: 'Delete Exercise',
                  enabled: onDelete != null,
                  destructive: true,
                ),
              ],
            ),
          ],
        ),
        children: [
          // ── Set rows (horizontal scroll prevents overflow on narrow screens)
          Padding(
            padding: const EdgeInsets.only(left: 6, right: 6, bottom: 2),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 2),
                  Wes2SetColumnHeaders(
                      showVelocity: showVelocity, entryMode: entryMode),
                  ...paddedSets.map((s) {
                    return Wes2SetRow(
                      key: ValueKey('${row.exerciseId}_${s.setIndex}'),
                      set: s,
                      showVelocity: showVelocity,
                      entryMode: entryMode,
                      bwDisplayText: bwDisplayText,
                      uid: wes2Ctrl.actingUid,
                      selectedDate: wes2Ctrl.selectedDate,
                      baselineRirHint: wes2Ctrl.baselineRirHintFor(
                          row.exerciseId, s.setIndex),
                      onFieldChanged: (fieldKey, rawText) =>
                          wes2Ctrl.updateSetField(
                        exerciseId: row.exerciseId,
                        setIndex: s.setIndex,
                        fieldKey: fieldKey,
                        rawText: rawText,
                      ),
                      onFieldUnfocused: (fieldKey, rawText) => onFieldUnfocused(
                        row.exerciseId,
                        s.setIndex,
                        fieldKey,
                        rawText,
                      ),
                      onRemoveSet: onRemoveSet == null
                          ? null
                          : () => onRemoveSet!(s.setIndex),
                      onNoteTap: onNoteTap == null
                          ? null
                          : () => onNoteTap!(s.setIndex),
                      isPlanNoteRead:
                          wes2Ctrl.isPlanNoteRead(row.exerciseId, s.setIndex),
                    );
                  }),
                ],
              ),
            ),
          ),
          // ── Bottom action row ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // "Completed?" — inactive; shown when eligible and not yet done.
                if (_isCompletedEligible(row, entryMode) && !isDone) ...[
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 6),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => onToggleMarkedDone(true),
                    icon: const Icon(Icons.check_circle_outline, size: 14),
                    label: const Text(
                      'Completed?',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // "Mark as not done" — inactive; shown when exercise is done.
                if (isDone) ...[
                  TextButton(
                    onPressed: () => onToggleMarkedDone(false),
                    child: const Text(
                      'Mark as not done',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: onAddSet,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    // BB3 planned rows get a subtle left accent border.
    if (isBb3) {
      return Container(
        margin: const EdgeInsets.only(top: 2),
        decoration: const BoxDecoration(
          border: Border(
            left: BorderSide(color: _kBb3AccentColor, width: 3),
          ),
        ),
        child: card,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: card,
    );
  }
}
