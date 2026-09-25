/// The lifetime showcase, directly beneath the header: five CATEGORY cards.
///
/// Each card shows ONE exercise of its category — by default the one with the
/// highest RE Points (ShowcaseCategorySnapshot.defaultExercise) — and, when
/// the category offers more than one, an arrow to display another. That choice
/// is presentation state only: it lives in this widget, is never written, and
/// reopening the profile shows the highest scorer again. Owner, friend and
/// cached/offline profiles all render through this same component and the
/// same selection rule.
///
/// For the displayed exercise, two lifetime results side by side:
///   BEST E1RM   — the heaviest estimated single the athlete has earned,
///                 calculated WITHOUT RIR, with the source set spelled out
///                 ("180 kg × 2 → 192 kg E1RM").
///   HEAVIEST    — the heaviest absolute load, whatever the rep count.
/// plus its RE Points, scored from the Best E1RM performance.
///
/// The source performance and its date are always visible, because a record
/// that does not say where it came from is a claim rather than an achievement.
/// The owner can attach a proof video to either result; when both come from
/// the SAME set, one upload covers both and the card says so.
///
/// Nothing here is ever labelled "verified" — the wording is "Proof attached",
/// which is what the video actually establishes.
///
/// A bodyweight-loaded exercise (Chin-Up, Triceps Dip) shows the ADDED load,
/// with the bodyweight recorded for that lift on its own line — see
/// record_presentation.dart for the arithmetic and the fallbacks.
library;

import 'package:flutter/material.dart';

import '../core/showcase_models.dart';
import '../core/showcase_v2_models.dart';
import '../data/showcase_repository.dart';
import 'profile_theme.dart';
import 'record_presentation.dart';
import 'units.dart';

class BigFiveShowcase extends StatelessWidget {
  const BigFiveShowcase({
    super.key,
    required this.view,
    required this.units,
    required this.isOwner,
    required this.onAddProof,
    required this.onOpenProof,
    required this.onRemoveProof,
  });

  final ShowcaseView view;
  final WeightUnits units;
  final bool isOwner;

  /// Owner taps "Add proof" for a specific record.
  final void Function(ShowcaseRecord record) onAddProof;

  /// Anyone allowed to see it taps an attached proof.
  final void Function(ProofRecord proof) onOpenProof;

  /// Owner detaches a proof. The media stays in the gallery.
  final void Function(ShowcaseRecord record, ProofRecord proof) onRemoveProof;

  @override
  Widget build(BuildContext context) {
    final ProfileShowcaseV2 showcase = view.categories;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ProfileSpacing.lg,
            ProfileSpacing.sm,
            ProfileSpacing.lg,
            ProfileSpacing.sm,
          ),
          child: Text(
            'LIFETIME BESTS',
            style: ProfileText.sectionTitle(context),
          ),
        ),
        ...showcase.categories.map(
          (ShowcaseCategorySnapshot c) => CategoryCard(
            key: ValueKey<String>('showcase-category-${c.category.key}'),
            category: c,
            showsPoints: showcase.showsPoints,
            view: view,
            units: units,
            isOwner: isOwner,
            onAddProof: onAddProof,
            onOpenProof: onOpenProof,
            onRemoveProof: onRemoveProof,
          ),
        ),
      ],
    );
  }
}

/// One category card. Stateful only for the viewer's exercise choice.
class CategoryCard extends StatefulWidget {
  const CategoryCard({
    super.key,
    required this.category,
    required this.showsPoints,
    required this.view,
    required this.units,
    required this.isOwner,
    required this.onAddProof,
    required this.onOpenProof,
    required this.onRemoveProof,
  });

  final ShowcaseCategorySnapshot category;

  /// False for the V1 fallback, whose points are not known.
  final bool showsPoints;
  final ShowcaseView view;
  final WeightUnits units;
  final bool isOwner;
  final void Function(ShowcaseRecord record) onAddProof;
  final void Function(ProofRecord proof) onOpenProof;
  final void Function(ShowcaseRecord record, ProofRecord proof) onRemoveProof;

  @override
  State<CategoryCard> createState() => _CategoryCardState();
}

class _CategoryCardState extends State<CategoryCard> {
  /// The viewer's choice, or null for the default (highest scorer). Never
  /// persisted, never written: presentation state only.
  String? _chosenExerciseId;

  ShowcaseExerciseSnapshot get _shown =>
      widget.category.exerciseById(_chosenExerciseId) ??
      widget.category.defaultExercise;

  @override
  Widget build(BuildContext context) {
    final ShowcaseCategorySnapshot category = widget.category;
    final ShowcaseExerciseSnapshot shown = _shown;
    final String key = category.category.key;
    // Loads are shown in the OWNER's unit for this exercise, for every viewer.
    final WeightUnits units = widget.view.unitsFor(shown.exerciseId);

    return Container(
      margin: const EdgeInsets.fromLTRB(
        ProfileSpacing.lg,
        0,
        ProfileSpacing.lg,
        ProfileSpacing.sm,
      ),
      padding: const EdgeInsets.all(ProfileSpacing.md),
      decoration: BoxDecoration(
        color: ProfilePalette.surface,
        borderRadius: BorderRadius.circular(ProfileSpacing.radius),
        border: Border.all(color: ProfilePalette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            category.category.displayName.toUpperCase(),
            style: ProfileText.recordLabel(context),
          ),
          const SizedBox(height: ProfileSpacing.xs),
          Row(
            children: <Widget>[
              Expanded(
                child: category.hasChoice
                    ? _ExercisePicker(
                        key: ValueKey<String>('showcase-exercise-picker-$key'),
                        category: category,
                        shown: shown,
                        showsPoints: widget.showsPoints,
                        onSelected: (String id) =>
                            setState(() => _chosenExerciseId = id),
                      )
                    : Text(
                        shown.exercise.displayName,
                        key: ValueKey<String>('showcase-exercise-name-$key'),
                        style: ProfileText.liftName(context),
                      ),
              ),
              if (shown.sharesOneSource)
                const ProfilePill(
                  label: 'ONE SET, BOTH',
                  icon: Icons.bolt_rounded,
                  color: ProfilePalette.accent,
                ),
            ],
          ),
          if (widget.showsPoints && shown.hasRecord) ...<Widget>[
            const SizedBox(height: ProfileSpacing.xs),
            _PointsLine(
              key: ValueKey<String>('showcase-points-$key'),
              points: shown.rePoints,
            ),
            // Best RE Points is its own set. When it is not the Best E1RM or
            // Heaviest set, say which set it was — and let a proof attach to
            // THAT set, never to another one.
            if (shown.pointsSetIsDistinct)
              _PointsSource(
                key: ValueKey<String>('showcase-points-source-$key'),
                record: shown.pointsRecord!,
                units: units,
                view: widget.view,
                isOwner: widget.isOwner,
                onAddProof: widget.onAddProof,
                onOpenProof: widget.onOpenProof,
                onRemoveProof: widget.onRemoveProof,
              ),
          ],
          const SizedBox(height: ProfileSpacing.md),
          if (!shown.hasRecord)
            Text(
              category.hasChoice
                  ? 'No result yet.'
                  : 'No completed sets logged yet.',
              style: ProfileText.recordDetail(context)
                  .copyWith(color: ProfilePalette.textMuted),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: _RecordColumn(
                    label: 'BEST E1RM',
                    record: shown.bestE1rm,
                    units: units,
                    view: widget.view,
                    isOwner: widget.isOwner,
                    isE1rm: true,
                    onAddProof: widget.onAddProof,
                    onOpenProof: widget.onOpenProof,
                    onRemoveProof: widget.onRemoveProof,
                  ),
                ),
                Container(
                  width: 1,
                  // A bodyweight-loaded exercise carries one more line per
                  // column ("at 85 kg BW"); the rule grows with it.
                  height: shown.exercise.bodyweightLoaded ? 94 : 78,
                  margin: const EdgeInsets.symmetric(
                    horizontal: ProfileSpacing.md,
                  ),
                  color: ProfilePalette.outline,
                ),
                Expanded(
                  child: _RecordColumn(
                    label: 'HEAVIEST',
                    record: shown.heaviest,
                    units: units,
                    view: widget.view,
                    isOwner: widget.isOwner,
                    isE1rm: false,
                    onAddProof: widget.onAddProof,
                    onOpenProof: widget.onOpenProof,
                    onRemoveProof: widget.onRemoveProof,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The displayed exercise's name with an arrow that opens the category's
/// other exercises.
class _ExercisePicker extends StatelessWidget {
  const _ExercisePicker({
    super.key,
    required this.category,
    required this.shown,
    required this.showsPoints,
    required this.onSelected,
  });

  final ShowcaseCategorySnapshot category;
  final ShowcaseExerciseSnapshot shown;
  final bool showsPoints;
  final ValueChanged<String> onSelected;

  String _trailing(ShowcaseExerciseSnapshot e) {
    if (!e.hasRecord) return 'No result yet';
    if (!showsPoints) return '';
    final double? p = e.rePoints;
    return p == null ? 'Points unavailable' : '${formatRePoints(p)} pts';
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Show another ${category.category.displayName} exercise',
      color: ProfilePalette.surface,
      initialValue: shown.exerciseId,
      onSelected: onSelected,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        for (final ShowcaseExerciseSnapshot e in category.exercises)
          PopupMenuItem<String>(
            key: ValueKey<String>('showcase-option-${e.exerciseId}'),
            value: e.exerciseId,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    e.exercise.displayName,
                    style: ProfileText.recordDetail(context).copyWith(
                      color: ProfilePalette.textPrimary,
                      fontWeight: e.exerciseId == shown.exerciseId
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(width: ProfileSpacing.sm),
                Text(_trailing(e), style: ProfileText.caption(context)),
              ],
            ),
          ),
      ],
      child: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              shown.exercise.displayName,
              style: ProfileText.liftName(context),
            ),
          ),
          const SizedBox(width: ProfileSpacing.xs),
          const Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 22,
            color: ProfilePalette.action,
            semanticLabel: 'Choose exercise',
          ),
        ],
      ),
    );
  }
}

/// The Best RE Points set when it differs from the two other records:
/// "from 140 kg × 1 · 10 Mar 2026", and its own proof control.
class _PointsSource extends StatelessWidget {
  const _PointsSource({
    super.key,
    required this.record,
    required this.units,
    required this.view,
    required this.isOwner,
    required this.onAddProof,
    required this.onOpenProof,
    required this.onRemoveProof,
  });

  final ShowcaseRecord record;
  final WeightUnits units;
  final ShowcaseView view;
  final bool isOwner;
  final void Function(ShowcaseRecord record) onAddProof;
  final void Function(ProofRecord proof) onOpenProof;
  final void Function(ShowcaseRecord record, ProofRecord proof) onRemoveProof;

  @override
  Widget build(BuildContext context) {
    final RecordPresentation shown =
        presentShowcaseRecord(record: record, isE1rm: false, units: units);
    final String note =
        shown.bodyweightNote == null ? '' : ' (${shown.bodyweightNote})';
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: ProfileSpacing.sm,
        runSpacing: ProfileSpacing.xs,
        children: <Widget>[
          Text(
            'from ${shown.source}$note · ${units.formatDate(record.dateKey)}',
            style: ProfileText.caption(context),
          ),
          _ProofControl(
            record: record,
            proof: view.proofFor(record),
            isOwner: isOwner,
            onAddProof: onAddProof,
            onOpenProof: onOpenProof,
            onRemoveProof: onRemoveProof,
          ),
        ],
      ),
    );
  }
}

/// "RE POINTS 123.45", or why there are none. Unavailable is not zero.
class _PointsLine extends StatelessWidget {
  const _PointsLine({super.key, required this.points});

  final double? points;

  @override
  Widget build(BuildContext context) {
    final double? p = points;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Text('RE POINTS', style: ProfileText.recordLabel(context)),
        const SizedBox(width: ProfileSpacing.sm),
        Text(
          p == null ? '—' : formatRePoints(p),
          style: ProfileText.recordValue(context),
        ),
        if (p == null) ...<Widget>[
          const SizedBox(width: ProfileSpacing.sm),
          Flexible(
            child: Text(
              'No bodyweight recorded for this lift',
              style: ProfileText.caption(context),
            ),
          ),
        ],
      ],
    );
  }
}
class _RecordColumn extends StatelessWidget {
  const _RecordColumn({
    required this.label,
    required this.record,
    required this.units,
    required this.view,
    required this.isOwner,
    required this.isE1rm,
    required this.onAddProof,
    required this.onOpenProof,
    required this.onRemoveProof,
  });

  final String label;
  final ShowcaseRecord? record;
  final WeightUnits units;
  final ShowcaseView view;
  final bool isOwner;
  final bool isE1rm;
  final void Function(ShowcaseRecord record) onAddProof;
  final void Function(ProofRecord proof) onOpenProof;
  final void Function(ShowcaseRecord record, ProofRecord proof) onRemoveProof;

  @override
  Widget build(BuildContext context) {
    final ShowcaseRecord? r = record;
    if (r == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: ProfileText.recordLabel(context)),
          const SizedBox(height: ProfileSpacing.xs),
          Text('—', style: ProfileText.recordValue(context)),
        ],
      );
    }

    final ProofRecord? proof = view.proofFor(r);
    final RecordPresentation shown =
        presentShowcaseRecord(record: r, isE1rm: isE1rm, units: units);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: ProfileText.recordLabel(context)),
        const SizedBox(height: ProfileSpacing.xs),
        Text(
          shown.value,
          style: ProfileText.recordValue(context),
        ),
        const SizedBox(height: 2),
        Text(
          // The source performance, always. "180 kg × 2" for an E1RM, and the
          // rep count for the heaviest load, so the number can be checked.
          shown.source,
          style: ProfileText.recordDetail(context),
        ),
        if (shown.bodyweightNote != null)
          Text(
            shown.bodyweightNote!,
            style: ProfileText.recordDetail(context),
          ),
        Text(
          units.formatDate(r.dateKey),
          style: ProfileText.caption(context),
        ),
        const SizedBox(height: ProfileSpacing.sm),
        _ProofControl(
          record: r,
          proof: proof,
          isOwner: isOwner,
          onAddProof: onAddProof,
          onOpenProof: onOpenProof,
          onRemoveProof: onRemoveProof,
        ),
      ],
    );
  }
}

/// The proof affordance for one record.
///
/// A visitor who is not allowed to see proofs simply gets nothing here — the
/// social gate is enforced in the rules, and the absence of a readable proof
/// document is what this reflects.
class _ProofControl extends StatelessWidget {
  const _ProofControl({
    required this.record,
    required this.proof,
    required this.isOwner,
    required this.onAddProof,
    required this.onOpenProof,
    required this.onRemoveProof,
  });

  final ShowcaseRecord record;
  final ProofRecord? proof;
  final bool isOwner;
  final void Function(ShowcaseRecord record) onAddProof;
  final void Function(ProofRecord proof) onOpenProof;
  final void Function(ShowcaseRecord record, ProofRecord proof) onRemoveProof;

  @override
  Widget build(BuildContext context) {
    final ProofRecord? p = proof;

    if (p != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InkWell(
            onTap: () => onOpenProof(p),
            borderRadius: BorderRadius.circular(999),
            // Deliberately "Proof attached", never "verified": a video is
            // evidence the athlete chose to show, not an adjudication.
            child: const ProfilePill(
              label: 'PROOF ATTACHED',
              icon: Icons.play_circle_fill_rounded,
              color: ProfilePalette.accent,
            ),
          ),
          if (isOwner) ...<Widget>[
            const SizedBox(width: ProfileSpacing.xs),
            Semantics(
              button: true,
              label: 'Remove proof',
              child: InkResponse(
                onTap: () => onRemoveProof(record, p),
                radius: 16,
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close_rounded,
                      size: 14, color: ProfilePalette.textMuted),
                ),
              ),
            ),
          ],
        ],
      );
    }

    if (!isOwner) return const SizedBox.shrink();

    return InkWell(
      onTap: () => onAddProof(record),
      borderRadius: BorderRadius.circular(999),
      child: const ProfilePill(
        label: 'ADD PROOF',
        icon: Icons.videocam_rounded,
        color: ProfilePalette.action,
      ),
    );
  }
}
