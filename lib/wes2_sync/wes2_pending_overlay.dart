/// Reconciles what the server confirmed with what the athlete has queued but
/// not yet synced.
///
/// ── The three kinds of value ────────────────────────────────────────────────
/// CONFIRMED   Firestore holds it. Canonical.
/// PENDING     The athlete changed it and the server has not accepted it yet.
///             Newer than confirmed by definition, so it wins.
/// DRAFT       Whatever this device last displayed. Neither of the above — it
///             is a cache, and a stale one after a coach or a second device
///             edits the same day.
///
/// The bug this closes: the draft used to beat the server unconditionally, so a
/// value that never reached Firestore kept reappearing on the phone that typed
/// it while history showed a hole. Nothing surfaced the disagreement. Now only
/// genuinely pending intent overrides the server, and pending intent is
/// removed only once the server has confirmed it — so the overlay covers
/// exactly the gap and nothing more.
///
/// Pure: no Firestore, no Drift, no Flutter. Every rule here is unit-testable.
library;

import '../WES2_models.dart';
import 'wes2_mutation.dart';

/// One queued change, reduced to just what the overlay needs. Decoupled from
/// the Drift row so this file stays dependency-free and testable.
class Wes2PendingChange {
  const Wes2PendingChange({
    required this.seq,
    required this.kind,
    required this.exerciseId,
    this.setIndex,
    this.payload = const <String, dynamic>{},
  });

  final int seq;
  final String kind;
  final String exerciseId;
  final int? setIndex;
  final Map<String, dynamic> payload;
}

/// Applies queued intent over [rows], which are the server/plan/draft merge.
///
/// Changes are applied in `seq` order, so the last thing the athlete did is the
/// thing that shows. Only kinds that affect what a row DISPLAYS are handled —
/// structural removals have already been applied to the local controller state
/// that produced [rows], and re-applying them here would double up.
List<Wes2ExerciseRow> wes2ApplyPendingOverlay(
  List<Wes2ExerciseRow> rows,
  List<Wes2PendingChange> pending,
) {
  if (pending.isEmpty) return rows;

  final List<Wes2PendingChange> ordered = List<Wes2PendingChange>.from(pending)
    ..sort((Wes2PendingChange a, Wes2PendingChange b) =>
        a.seq.compareTo(b.seq));

  List<Wes2ExerciseRow> result = List<Wes2ExerciseRow>.from(rows);

  for (final Wes2PendingChange change in ordered) {
    final int rowIdx =
        result.indexWhere((Wes2ExerciseRow r) => r.exerciseId == change.exerciseId);
    if (rowIdx == -1) continue;
    final Wes2ExerciseRow row = result[rowIdx];

    switch (change.kind) {
      case Wes2MutationKind.field:
        final int? setIndex = change.setIndex;
        final Wes2FieldKey? key = Wes2Mutation.fieldKeyFrom(change.payload);
        if (setIndex == null || key == null) continue;
        result[rowIdx] = _withField(
          row,
          setIndex,
          key,
          Wes2Mutation.fieldValueFrom(change.payload),
        );
        break;

      case Wes2MutationKind.setNote:
        final int? setIndex = change.setIndex;
        if (setIndex == null) continue;
        result[rowIdx] = _withSetNote(
          row,
          setIndex,
          change.payload['value'] as String?,
        );
        break;

      case Wes2MutationKind.exerciseNote:
        final Object? note = change.payload['value'];
        result[rowIdx] = note is String
            ? row.copyWith(exerciseExecutionNote: note)
            : row.copyWith(clearExerciseExecutionNote: true);
        break;

      case Wes2MutationKind.markDone:
        result[rowIdx] = row.copyWith(isMarkedDone: change.payload['isDone'] == true);
        break;

      case Wes2MutationKind.setCount:
        final Object? count = change.payload['setCount'];
        if (count is! num) continue;
        final int wanted = count.toInt();
        if (wanted <= row.setCount) continue;
        result[rowIdx] = row.copyWith(
          setCount: wanted,
          sets: _padTo(row.sets, wanted),
        );
        break;

      default:
        // Structural kinds are already reflected in the rows handed in.
        break;
    }
  }

  return result;
}

/// Sets or CLEARS one field's actualValue, leaving the hint alone.
///
/// A null value is a tombstone, not an absence: the athlete deleted the value,
/// so `withActual(null)` is applied and the server's old number does not show
/// through while the delete is still queued.
Wes2ExerciseRow _withField(
  Wes2ExerciseRow row,
  int setIndex,
  Wes2FieldKey key,
  Object? value,
) {
  final List<Wes2SetState> sets = _padTo(row.sets, setIndex + 1);
  final Wes2SetState s = sets[setIndex];
  switch (key) {
    case Wes2FieldKey.weight:
      sets[setIndex] =
          s.copyWith(weight: s.weight.withActual((value as num?)?.toDouble()));
      break;
    case Wes2FieldKey.reps:
      sets[setIndex] =
          s.copyWith(reps: s.reps.withActual((value as num?)?.toInt()));
      break;
    case Wes2FieldKey.rir:
      sets[setIndex] =
          s.copyWith(rir: s.rir.withActual((value as num?)?.toDouble()));
      break;
    case Wes2FieldKey.velocity:
      sets[setIndex] = s.copyWith(
          velocity: s.velocity.withActual((value as num?)?.toDouble()));
      break;
  }
  return row.copyWith(
    sets: sets,
    setCount: sets.length > row.setCount ? sets.length : row.setCount,
  );
}

Wes2ExerciseRow _withSetNote(Wes2ExerciseRow row, int setIndex, String? note) {
  final List<Wes2SetState> sets = _padTo(row.sets, setIndex + 1);
  final Wes2SetState s = sets[setIndex];
  sets[setIndex] = Wes2SetState(
    setIndex: s.setIndex,
    setId: s.setId,
    weight: s.weight,
    reps: s.reps,
    rir: s.rir,
    velocity: s.velocity,
    // copyWith cannot express "clear", and a cleared note must not fall back
    // to the server's old text while the delete is queued.
    executionNote: note,
    planNote: s.planNote,
    weightLockedByBb3OverrideCue: s.weightLockedByBb3OverrideCue,
    repsLockedByBb3OverrideCue: s.repsLockedByBb3OverrideCue,
    rirLockedByBb3OverrideCue: s.rirLockedByBb3OverrideCue,
  );
  return row.copyWith(sets: sets);
}

List<Wes2SetState> _padTo(List<Wes2SetState> sets, int count) {
  final List<Wes2SetState> out = List<Wes2SetState>.from(sets);
  while (out.length < count) {
    out.add(Wes2SetState(setIndex: out.length));
  }
  return out;
}

/// Overlays a local draft onto the server/plan merge, for the case where the
/// server load SUCCEEDED.
///
/// The rule that changed: a confirmed server value is never replaced by a
/// draft. The draft may only FILL a field the server does not hold at all.
///
/// ── Why fill rather than ignore entirely ────────────────────────────────────
/// Drafts written before this queue existed may hold the only copy of a value
/// whose write was swallowed. Blanking those on upgrade would destroy the very
/// data this work exists to protect, so a draft-only value is still shown. It
/// is shown, not re-uploaded: recovering it to Firestore is a separate,
/// deliberate decision and is not made here.
List<Wes2ExerciseRow> wes2ApplyDraftWithoutOverridingServer(
  List<Wes2ExerciseRow> merged,
  List<Wes2ExerciseRow>? draft,
) {
  if (draft == null || draft.isEmpty) return merged;
  final Map<String, Wes2ExerciseRow> byId = <String, Wes2ExerciseRow>{
    for (final Wes2ExerciseRow r in draft) r.exerciseId: r,
  };

  return merged.map((Wes2ExerciseRow row) {
    final Wes2ExerciseRow? d = byId[row.exerciseId];
    if (d == null) return row;

    final int highestDraftActualIdx = d.sets.fold(
      -1,
      (int m, Wes2SetState s) => s.hasAnyActual && s.setIndex > m ? s.setIndex : m,
    );
    final int effectiveCount = <int>[
      row.setCount,
      d.setCount,
      highestDraftActualIdx + 1,
    ].reduce((int a, int b) => a > b ? a : b);

    final List<Wes2SetState> sets = List<Wes2SetState>.generate(
      effectiveCount,
      (int i) {
        final Wes2SetState serverSet =
            i < row.sets.length ? row.sets[i] : Wes2SetState(setIndex: i);
        final Wes2SetState? draftSet = i < d.sets.length ? d.sets[i] : null;
        if (draftSet == null) return serverSet;
        return serverSet.copyWith(
          weight: _fill(serverSet.weight, draftSet.weight),
          reps: _fill(serverSet.reps, draftSet.reps),
          rir: _fill(serverSet.rir, draftSet.rir),
          velocity: _fill(serverSet.velocity, draftSet.velocity),
          executionNote: serverSet.executionNote ?? draftSet.executionNote,
          // Identity is additive and never contested: keep whichever exists so
          // a recording filed against a draft-minted id stays associated.
          setId: serverSet.setId ?? draftSet.setId,
        );
      },
    );

    return row.copyWith(
      sets: sets,
      setCount: effectiveCount,
      isMarkedDone: row.isMarkedDone || d.isMarkedDone,
      exerciseExecutionNote:
          row.exerciseExecutionNote ?? d.exerciseExecutionNote,
    );
  }).toList();
}

/// Server value wins whenever it exists; the draft may only fill a gap.
Wes2FieldState<T> _fill<T extends Object>(
  Wes2FieldState<T> server,
  Wes2FieldState<T> draft,
) =>
    server.hasActual || !draft.hasActual
        ? server
        : server.withActual(draft.actualValue);
