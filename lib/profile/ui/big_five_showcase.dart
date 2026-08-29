/// The Big Five achievement showcase, directly beneath the header.
///
/// Each lift shows two lifetime results side by side:
///   BEST E1RM   — the heaviest estimated single the athlete has earned,
///                 calculated WITHOUT RIR, with the source set spelled out
///                 ("180 kg × 2 → 192 kg E1RM").
///   HEAVIEST    — the heaviest absolute load, whatever the rep count.
///
/// The source performance and its date are always visible, because a record
/// that does not say where it came from is a claim rather than an achievement.
/// The owner can attach a proof video to either result; when both come from
/// the SAME set, one upload covers both and the card says so.
///
/// Nothing here is ever labelled "verified" — the wording is "Proof attached",
/// which is what the video actually establishes.
library;

import 'package:flutter/material.dart';

import '../core/big_five.dart';
import '../core/showcase_models.dart';
import '../data/showcase_repository.dart';
import 'profile_theme.dart';
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
          child:
              Text('LIFETIME BESTS', style: ProfileText.sectionTitle(context)),
        ),
        ...BigFiveSlot.ordered.map((String slot) => _LiftCard(
              snapshot: view.lift(slot),
              view: view,
              units: units,
              isOwner: isOwner,
              onAddProof: onAddProof,
              onOpenProof: onOpenProof,
              onRemoveProof: onRemoveProof,
            )),
      ],
    );
  }
}

class _LiftCard extends StatelessWidget {
  const _LiftCard({
    required this.snapshot,
    required this.view,
    required this.units,
    required this.isOwner,
    required this.onAddProof,
    required this.onOpenProof,
    required this.onRemoveProof,
  });

  final ShowcaseLiftSnapshot snapshot;
  final ShowcaseView view;
  final WeightUnits units;
  final bool isOwner;
  final void Function(ShowcaseRecord record) onAddProof;
  final void Function(ProofRecord proof) onOpenProof;
  final void Function(ShowcaseRecord record, ProofRecord proof) onRemoveProof;

  @override
  Widget build(BuildContext context) {
    final BigFiveLift? lift = snapshot.lift;
    if (lift == null) return const SizedBox.shrink();

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
          Row(
            children: <Widget>[
              Expanded(
                child: Text(lift.displayName,
                    style: ProfileText.liftName(context)),
              ),
              if (snapshot.sharesOneSource)
                const ProfilePill(
                  label: 'ONE SET, BOTH',
                  icon: Icons.bolt_rounded,
                  color: ProfilePalette.accent,
                ),
            ],
          ),
          const SizedBox(height: ProfileSpacing.md),
          if (snapshot.isEmpty)
            _EmptyLift(lift: lift)
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: _RecordColumn(
                    label: 'BEST E1RM',
                    record: snapshot.bestE1rm,
                    units: units,
                    view: view,
                    isOwner: isOwner,
                    isE1rm: true,
                    onAddProof: onAddProof,
                    onOpenProof: onOpenProof,
                    onRemoveProof: onRemoveProof,
                  ),
                ),
                Container(
                  width: 1,
                  height: 78,
                  margin:
                      const EdgeInsets.symmetric(horizontal: ProfileSpacing.md),
                  color: ProfilePalette.outline,
                ),
                Expanded(
                  child: _RecordColumn(
                    label: 'HEAVIEST',
                    record: snapshot.heaviest,
                    units: units,
                    view: view,
                    isOwner: isOwner,
                    isE1rm: false,
                    onAddProof: onAddProof,
                    onOpenProof: onOpenProof,
                    onRemoveProof: onRemoveProof,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _EmptyLift extends StatelessWidget {
  const _EmptyLift({required this.lift});

  final BigFiveLift lift;

  @override
  Widget build(BuildContext context) {
    return Text(
      'No completed sets logged yet.',
      style: ProfileText.recordDetail(context)
          .copyWith(color: ProfilePalette.textMuted),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: ProfileText.recordLabel(context)),
        const SizedBox(height: ProfileSpacing.xs),
        Text(
          isE1rm ? units.format(r.e1rm) : units.format(r.weight),
          style: ProfileText.recordValue(context),
        ),
        const SizedBox(height: 2),
        Text(
          // The source performance, always. "180 kg × 2" for an E1RM, and the
          // rep count for the heaviest load, so the number can be checked.
          '${units.format(r.weight)} × ${r.reps}',
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
