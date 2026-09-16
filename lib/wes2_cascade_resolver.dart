/// The forward cascade and the accepted-hint view.
///
/// ── The contract ────────────────────────────────────────────────────────────
/// Set 1 is resolved, then Set 2 from Set 1's FINAL mixture of actuals and
/// hints, then Set 3 from Set 2's, and so on. "Final" means the values the row
/// actually shows: `actual ?? hint` per field, with actual/hint provenance kept
/// separate so the weight cap still only answers to an ENTERED RIR.
///
/// ── Why the view exists ─────────────────────────────────────────────────────
/// Typing the number a set is already suggesting must not change that set.
/// Without this, accepting a hinted 10 reps at 40 kg re-solved the set and
/// moved its RIR 2 → 1.5, which then moved every later set. The view asks a
/// cheaper question first: "if this entry were removed, would the set have
/// hinted exactly this?" If so the entry is an acceptance, and the set keeps
/// the hints it already had; the entry is still a real actual and still flows
/// downstream, carrying its own authority.
///
/// Matching uses the SAME formatters the row renders with ([Wes2HintFormat]),
/// because the athlete accepted what they saw. A numeric tolerance disagrees
/// with the display: `0.15` renders as "0.1" and `2.55` as "2.5", so ±0.05
/// would accept values that were never on screen.
library;

import 'WES2_models.dart';

/// The display formatters. Shared by the row widget and by acceptance
/// matching so the two can never drift apart.
class Wes2HintFormat {
  Wes2HintFormat._();

  /// Up to 3 dp of genuine increment precision, trailing zeros stripped.
  /// Bounded precision first also collapses artefacts (16.249999999 → "16.25").
  static String weight(double v) {
    final String s = v.toStringAsFixed(3);
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  static String reps(int v) => v.toString();

  static String rir(double v) => v.toStringAsFixed(1);

  static String velocity(double v) {
    final String s = v.toStringAsFixed(3);
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  static bool weightAccepts(double actual, double? hint) =>
      hint != null && weight(actual) == weight(hint);

  static bool repsAccepts(int actual, int? hint) => hint != null && actual == hint;

  static bool rirAccepts(double actual, double? hint) =>
      hint != null && rir(actual) == rir(hint);
}

/// One set's hint computation, with its predecessor supplied explicitly.
/// Implemented by the hint service; the resolver never knows about
/// progression models, drop groups or E1RM.
abstract class Wes2SetHintComputer {
  /// Computes hints for [input] at [setIdx]. [input] carries only actuals and
  /// prescriptions. [prevResolved] is the previous set's FINAL state, or null
  /// for Set 1.
  Wes2SetState computeSet({
    required int setIdx,
    required Wes2SetState input,
    required Wes2SetState? prevResolved,
  });
}

/// Which entered fields a view is being asked about.
class _Mask {
  const _Mask(this.w, this.r, this.rir);
  final bool w, r, rir;
  int get key => (w ? 1 : 0) | (r ? 2 : 0) | (rir ? 4 : 0);
  _Mask without(int field) => _Mask(
        field == 0 ? false : w,
        field == 1 ? false : r,
        field == 2 ? false : rir,
      );
}

class Wes2CascadeResolver {
  Wes2CascadeResolver._();

  /// Resolves [input] (builder output) forward from [fromSet].
  ///
  /// Sets before [fromSet] are taken from [existingFinals] verbatim — an edit
  /// to a later set must not disturb an earlier one — and the last of them
  /// becomes the first predecessor.
  static Wes2ExerciseRow resolveRow({
    required Wes2ExerciseRow input,
    required Wes2SetHintComputer computer,
    int fromSet = 0,
    List<Wes2SetState> existingFinals = const <Wes2SetState>[],
  }) {
    final int count = input.setCount;
    final List<Wes2SetState> out = <Wes2SetState>[];

    for (int i = 0; i < count && i < fromSet; i++) {
      out.add(i < existingFinals.length
          ? existingFinals[i]
          : (i < input.sets.length ? input.sets[i] : Wes2SetState(setIndex: i)));
    }

    Wes2SetState? prev = out.isEmpty ? null : out.last;

    for (int i = out.length; i < count; i++) {
      final Wes2SetState set =
          i < input.sets.length ? input.sets[i] : Wes2SetState(setIndex: i);
      final Wes2SetState resolved = _resolveSet(
        computer: computer,
        setIdx: i,
        set: set,
        prev: prev,
      );
      out.add(resolved);
      prev = resolved;
    }

    return input.copyWith(sets: out, setCount: count);
  }

  static Wes2SetState _resolveSet({
    required Wes2SetHintComputer computer,
    required int setIdx,
    required Wes2SetState set,
    required Wes2SetState? prev,
  }) {
    final _Mask full = _Mask(
      set.weight.actualValue != null,
      set.reps.actualValue != null,
      set.rir.actualValue != null,
    );
    final Map<int, Wes2SetState> memo = <int, Wes2SetState>{};

    final Wes2SetState view = _view(
      computer: computer,
      setIdx: setIdx,
      set: set,
      prev: prev,
      mask: full,
      memo: memo,
    );

    // The RIR direction cue's reference: this set's RIR hint with its own
    // weight/reps entries removed, for the CURRENT predecessor.
    final Wes2SetState free = _view(
      computer: computer,
      setIdx: setIdx,
      set: set,
      prev: prev,
      mask: _Mask(false, false, full.rir),
      memo: memo,
    );

    return _attachActuals(set, view, rirReference: free.rir.hintValue);
  }

  /// view(E) — see the library comment.
  static Wes2SetState _view({
    required Wes2SetHintComputer computer,
    required int setIdx,
    required Wes2SetState set,
    required Wes2SetState? prev,
    required _Mask mask,
    required Map<int, Wes2SetState> memo,
  }) {
    final Wes2SetState? cached = memo[mask.key];
    if (cached != null) return cached;

    // Deterministic field order: weight, reps, RIR.
    for (int field = 0; field < 3; field++) {
      final bool entered = field == 0 ? mask.w : (field == 1 ? mask.r : mask.rir);
      if (!entered) continue;

      final Wes2SetState sub = _view(
        computer: computer,
        setIdx: setIdx,
        set: set,
        prev: prev,
        mask: mask.without(field),
        memo: memo,
      );

      final bool accepted;
      switch (field) {
        case 0:
          accepted = Wes2HintFormat.weightAccepts(
              set.weight.actualValue!, sub.weight.hintValue);
          break;
        case 1:
          accepted =
              Wes2HintFormat.repsAccepts(set.reps.actualValue!, sub.reps.hintValue);
          break;
        default:
          accepted =
              Wes2HintFormat.rirAccepts(set.rir.actualValue!, sub.rir.hintValue);
      }

      if (accepted) {
        // The entry is an acceptance: keep the subview's hints and cues.
        memo[mask.key] = sub;
        return sub;
      }
    }

    final Wes2SetState raw = computer.computeSet(
      setIdx: setIdx,
      input: _withMask(set, mask),
      prevResolved: prev,
    );
    memo[mask.key] = raw;
    return raw;
  }

  /// The same set with only the masked actuals present. Prescriptions, ids and
  /// notes are untouched — only the athlete's entries are hidden.
  static Wes2SetState _withMask(Wes2SetState set, _Mask mask) {
    if (mask.w && mask.r && mask.rir) return set;
    return set.copyWith(
      weight: mask.w ? set.weight : _hintOnly<double>(set.weight),
      reps: mask.r ? set.reps : _hintOnly<int>(set.reps),
      rir: mask.rir ? set.rir : _hintOnly<double>(set.rir),
    );
  }

  static Wes2FieldState<T> _hintOnly<T extends Object>(Wes2FieldState<T> f) =>
      Wes2FieldState<T>(
        actualValue: null,
        hintValue: f.hintValue,
        hintOrigin: f.hintOrigin,
        origin: f.hintOrigin,
        dirty: f.dirty,
        lastEditedAt: f.lastEditedAt,
      );

  /// Reattaches every real actual of [set] to the hints/cues of [view].
  static Wes2SetState _attachActuals(
    Wes2SetState set,
    Wes2SetState view, {
    double? rirReference,
  }) {
    return Wes2SetState(
      setIndex: set.setIndex,
      setId: set.setId,
      weight: _merge<double>(set.weight, view.weight),
      reps: _merge<int>(set.reps, view.reps),
      rir: _merge<double>(set.rir, view.rir),
      velocity: _merge<double>(set.velocity, view.velocity),
      executionNote: set.executionNote,
      planNote: set.planNote ?? view.planNote,
      weightLockedByBb3OverrideCue: view.weightLockedByBb3OverrideCue,
      repsLockedByBb3OverrideCue: view.repsLockedByBb3OverrideCue,
      rirLockedByBb3OverrideCue: view.rirLockedByBb3OverrideCue,
      rirReferenceHint: rirReference,
    );
  }

  static Wes2FieldState<T> _merge<T extends Object>(
    Wes2FieldState<T> actualSide,
    Wes2FieldState<T> hintSide,
  ) =>
      Wes2FieldState<T>(
        actualValue: actualSide.actualValue,
        hintValue: hintSide.hintValue,
        hintOrigin: hintSide.hintOrigin,
        origin: actualSide.actualValue != null
            ? (actualSide.origin == FieldOrigin.completed
                ? FieldOrigin.completed
                : FieldOrigin.typed)
            : hintSide.hintOrigin,
        dirty: actualSide.dirty,
        lastEditedAt: actualSide.lastEditedAt,
      );

  /// The values the next set consumes: `actual ?? hint` per field.
  static ({double? weight, int? reps, double? rir}) resolvedValues(
          Wes2SetState s) =>
      (
        weight: s.weight.actualValue ?? s.weight.hintValue,
        reps: s.reps.actualValue ?? s.reps.hintValue,
        rir: s.rir.actualValue ?? s.rir.hintValue,
      );
}
