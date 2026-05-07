import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../WES2_controller.dart';
import '../WES2_models.dart';
import '../exercise_video_button.dart';
import 'WES2_set_row.dart';

// blueGrey.shade400 and blueGrey.shade700 as compile-time constants.
const _kBb3AccentColor = Color(0xFF455A64); // blueGrey.shade700
const _kBb3LabelColor = Color(0xFF78909C); // blueGrey.shade400

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

  const Wes2ExerciseCard({
    super.key,
    required this.row,
    required this.onFieldUnfocused,
    required this.onToggleMarkedDone,
    required this.onAddSet,
  });

  @override
  Widget build(BuildContext context) {
    // Pad sets list to row.setCount — build-time only, no model mutation.
    final paddedSets = List.generate(
      row.setCount,
      (i) => i < row.sets.length ? row.sets[i] : Wes2SetState(setIndex: i),
    );

    // Show velocity column only when at least one set has a velocity value.
    final showVelocity = row.sets.any(
      (s) => s.velocity.hasActual || s.velocity.hasHint,
    );

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
        // ── Title: exercise name + optional BB3 label ──────────────────────
        title: Row(
          children: [
            Expanded(
              child: Text(
                row.name,
                style: const TextStyle(fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isBb3)
              const Text(
                ' · BB3 Plan',
                style: TextStyle(
                  fontSize: 11,
                  color: _kBb3LabelColor,
                  fontStyle: FontStyle.italic,
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
            // Settings cog — inactive until exerciseSettings loading is wired.
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              icon: const Icon(Icons.settings, size: 20, color: Colors.grey),
              onPressed: null,
            ),
            // Exercise menu — inactive until delete/replace actions are wired.
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              icon: const Icon(Icons.more_vert, size: 18),
              onPressed: null,
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
                  Wes2SetColumnHeaders(showVelocity: showVelocity),
                  ...paddedSets.map((s) {
                    final wes2Ctrl = Provider.of<Wes2SessionController>(
                      context,
                      listen: false,
                    );
                    return Wes2SetRow(
                      key: ValueKey('${row.exerciseId}_${s.setIndex}'),
                      set: s,
                      showVelocity: showVelocity,
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
                if (row.isCompletedPillEligible && !isDone) ...[
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
