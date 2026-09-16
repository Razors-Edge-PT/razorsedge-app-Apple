/// The single way a row becomes input for hint calculation.
///
/// ── Why every path must go through here ─────────────────────────────────────
/// Recalculation used to be fed the CURRENT row, whose hints are the previous
/// pass's output. That made a set's own generated numbers an input to its own
/// regeneration (Set 3 walked 15×14 → 12.5×19 → 10×22 over three passes), and
/// it made a recovered draft hint indistinguishable from a BB3 prescription.
///
/// The builder produces a row carrying ONLY:
///   • the athlete's actual values, copied unconditionally — including a value
///     equal to the hint, an RIR of 0, and velocity;
///   • the positional BB3 prescription, as a `bb3Hint` hintValue.
///
/// No generated hint, no cue flag and no previous-pass residue survives it, so
/// the same entries always produce the same hints no matter how the row got
/// into that state.
library;

import 'WES2_models.dart';

class Wes2HintInput {
  Wes2HintInput._();

  /// Builds the calculation input for [row] under [prescriptions].
  ///
  /// [setCount] defaults to the row's own count. Sets are padded so the input
  /// always covers the whole row; padding never invents actuals.
  static Wes2ExerciseRow build(
    Wes2ExerciseRow row, {
    Wes2Prescriptions prescriptions = Wes2Prescriptions.none,
    int? setCount,
  }) {
    final int count = setCount ?? row.setCount;
    final List<Wes2SetState> sets = List<Wes2SetState>.generate(count, (int i) {
      final Wes2SetState? s = i < row.sets.length ? row.sets[i] : null;
      final Wes2PrescribedSet p = prescriptions.at(i);
      return Wes2SetState(
        setIndex: i,
        setId: s?.setId,
        weight: _field<double>(s?.weight, p.weight),
        reps: _field<int>(s?.reps, p.reps),
        rir: _field<double>(s?.rir, p.rir),
        velocity: _field<double>(s?.velocity, p.velocity),
        executionNote: s?.executionNote,
        planNote: p.planNote ?? s?.planNote,
      );
    });
    return row.copyWith(
      sets: sets,
      setCount: count,
      exercisePlanNote: prescriptions.exercisePlanNote ?? row.exercisePlanNote,
    );
  }

  /// Actual from the row (never suppressed), hint from the prescription only.
  static Wes2FieldState<T> _field<T extends Object>(
    Wes2FieldState<T>? current,
    T? prescribed,
  ) {
    final T? actual = current?.actualValue;
    return Wes2FieldState<T>(
      actualValue: actual,
      hintValue: prescribed,
      hintOrigin: prescribed != null ? FieldOrigin.bb3Hint : FieldOrigin.empty,
      origin: actual != null
          ? FieldOrigin.typed
          : (prescribed != null ? FieldOrigin.bb3Hint : FieldOrigin.empty),
      dirty: current?.dirty ?? false,
      lastEditedAt: current?.lastEditedAt,
    );
  }

  /// Reads the prescriptions already carried by a row's `bb3Hint` fields.
  ///
  /// Used where the caller (the BB3 day panel, a planned-day load) has already
  /// produced a row whose hints ARE the prescription. Fields whose hintOrigin
  /// is anything else are ignored, so a generated or recovered display hint can
  /// never be promoted to a prescription here.
  static Wes2Prescriptions prescriptionsFromRow(
    Wes2ExerciseRow row, {
    Wes2PrescriptionSource source = Wes2PrescriptionSource.server,
  }) {
    bool locked<T extends Object>(Wes2FieldState<T> f) =>
        f.hintOrigin == FieldOrigin.bb3Hint && f.hintValue != null;
    return Wes2Prescriptions(
      source: source,
      exercisePlanNote: row.exercisePlanNote,
      sets: <Wes2PrescribedSet>[
        for (final Wes2SetState s in row.sets)
          Wes2PrescribedSet(
            weight: locked(s.weight) ? s.weight.hintValue : null,
            reps: locked(s.reps) ? s.reps.hintValue : null,
            rir: locked(s.rir) ? s.rir.hintValue : null,
            velocity: locked(s.velocity) ? s.velocity.hintValue : null,
            planNote: s.planNote,
          ),
      ],
    );
  }
}
