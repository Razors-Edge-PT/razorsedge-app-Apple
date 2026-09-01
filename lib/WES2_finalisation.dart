// Finalisation of performed sets when a WES2 exercise is marked Done.
//
// The problem this exists to solve: WES2 shows a set's RIR from
// `rir.actualValue ?? rir.hintValue`, and computes the on-screen E1RM from the
// same resolved value. A BB3/model RIR the athlete simply accepted — never
// typed, never double-tapped — therefore drives what they SEE while logging,
// but lives only in `hintValue`, and `_buildRowMap` deliberately persists
// actualValues only. Marking the exercise Done used to write `isMarkedDone`
// without doing anything about that, so the completed workout stored
// `rir: null` for a set the athlete had watched at RIR 2.0, and every reader
// downstream (Top Sets, PBs, progression) then treated it as RIR 0.
//
// The rule below is the single definition of "what the athlete actually
// completed this set with". It is pure and dependency-free so it can be pinned
// by tests directly, and so the repository has exactly one place to consult.
//
// No external service dependencies — safe to import anywhere.

import 'WES2_models.dart';

/// The durable execution values one genuinely performed set must carry once
/// its exercise has been marked Done.
///
/// Only ever produced for a set that has BOTH an actual weight and actual
/// reps: those two fields are what make a set a performed set rather than a
/// prescription. A planned set carrying nothing but hints never yields one of
/// these, so completion can never mint fake execution data.
class Wes2FinalisedSet {
  const Wes2FinalisedSet({
    required this.setIndex,
    required this.weight,
    required this.reps,
    this.rir,
    this.velocity,
  });

  final int setIndex;

  /// Actual weight. Never a hint.
  final double weight;

  /// Actual reps. Never a hint.
  final int reps;

  /// The RIR the athlete completed the set with: their typed value when they
  /// entered one, otherwise the RIR that was resolved and displayed to them.
  /// Null only when the set carried no RIR at all — a timed exercise, or a
  /// row the model produced no RIR for.
  final double? rir;

  /// Actual velocity, when one was entered. Never a hint — velocity has no
  /// displayed-and-accepted semantics the way RIR does.
  final double? velocity;

  @override
  bool operator ==(Object other) =>
      other is Wes2FinalisedSet &&
      other.setIndex == setIndex &&
      other.weight == weight &&
      other.reps == reps &&
      other.rir == rir &&
      other.velocity == velocity;

  @override
  int get hashCode => Object.hash(setIndex, weight, reps, rir, velocity);

  @override
  String toString() => 'Wes2FinalisedSet(set=$setIndex, w=$weight, r=$reps, '
      'rir=$rir, v=$velocity)';
}

/// True when [s] is a genuinely performed set: the athlete entered an actual
/// weight AND actual reps for it.
///
/// Deliberately independent of set index, so an originally prescribed set and
/// a set added with Add Set are judged by exactly the same test. There is no
/// "sets 1-4 behave differently from added sets" rule anywhere in this file.
bool wes2SetIsPerformed(Wes2SetState s) =>
    s.weight.actualValue != null && s.reps.actualValue != null;

/// The values the completed workout must hold for every performed set in
/// [row], in set order.
///
/// Rules, in priority order:
///   1. A set without actual weight AND actual reps is skipped entirely. A
///      planned set holding only hints stays plan data; completion never
///      promotes it to execution data just because a sibling set was performed.
///   2. `rir.actualValue` — typed, or explicitly double-tap accepted — is
///      returned exactly as it stands, including a deliberate 0.0. A hint
///      never replaces it.
///   3. Otherwise the currently resolved `rir.hintValue` is returned: that is
///      the number the athlete watched on the row and that the on-screen E1RM
///      was computed from, so accepting it by logging the set and pressing
///      Done is a real acceptance.
///   4. Weight, reps and velocity are taken from actualValue only. Their hints
///      are prescription and are never converted.
List<Wes2FinalisedSet> wes2FinalisedPerformedSets(Wes2ExerciseRow row) {
  final out = <Wes2FinalisedSet>[];
  for (final s in row.sets) {
    if (!wes2SetIsPerformed(s)) continue;
    out.add(Wes2FinalisedSet(
      setIndex: s.setIndex,
      weight: s.weight.actualValue!,
      reps: s.reps.actualValue!,
      rir: s.rir.actualValue ?? s.rir.hintValue,
      velocity: s.velocity.actualValue,
    ));
  }
  return out;
}
