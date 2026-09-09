/// Canonical, ceiling-free representation of an exercise's valid weights.
///
/// Historically every progression path materialised its valid weights as a
/// finite list built with `for (int i = 0; i < 100; i++) opts.add(i * primary)`.
/// With a 2.5 kg primary that list stopped at 247.5 kg, so any athlete working
/// above it had every suggestion silently clamped to the top of the list (a Lat
/// Pull Down at 265-285 kg could never be represented, so Smart Progression
/// snapped its centre down to 247.5 and compensated with reps).
///
/// [IncrementGrid] replaces the pre-generated list with the arithmetic lattice
/// it was always trying to approximate. Nothing is materialised: the nearest,
/// previous and next valid weights are computed locally from the target, so the
/// grid is valid at 27 kg, 270 kg or 2700 kg alike.
///
/// ## Semantics (unchanged from the pre-existing production behaviour)
///
/// With a primary increment `P` and no secondary, the valid weights are:
///
///     { k * P : k >= 0 }
///
/// With a primary `P` and an active secondary `S`, they are the union of the
/// primary sequence and the same sequence offset by `S`:
///
///     { k * P } ∪ { k * P + S }   for k >= 0
///
/// e.g. `P = 2.5, S = 1.25` → 0, 1.25, 2.5, 3.75, 5, … 267.5, 268.75, 270, …
///
/// A secondary is *not* a second independent increment: arbitrary sums such as
/// `2P + 3S` are not valid weights. This mirrors what
/// `PeriodizationModelUtils.expandIncrementOptions` has always produced and is
/// the semantics the WES2 increment settings UI writes.
class IncrementGrid {
  /// The fallback step used whenever a configured primary is missing, zero,
  /// negative or non-finite. Matches the long-standing 2.5 kg default.
  static const double defaultPrimary = 2.5;

  /// Comparison tolerance. Grid members are produced by `k * primary`, so
  /// floating point error stays many orders of magnitude below this.
  static const double _eps = 1e-6;

  /// The primary increment. Always finite and > 0.
  final double primary;

  /// The secondary offset, or null when the grid is primary-only. When present
  /// it is finite, > 0 and different from [primary].
  final double? secondary;

  const IncrementGrid._(this.primary, this.secondary);

  /// Builds a grid, applying the canonical validity rules to both values.
  ///
  /// A secondary equal to the primary adds nothing to the lattice (it would
  /// only re-generate the primary sequence), so it is dropped rather than
  /// duplicated — matching the `secondary != primary` guard that has always
  /// gated the secondary pass.
  factory IncrementGrid({required double primary, double? secondary}) {
    final double p =
        (primary.isFinite && primary > 0) ? primary : defaultPrimary;
    final double? s = (secondary != null &&
            secondary.isFinite &&
            secondary > 0 &&
            (secondary - p).abs() > _eps)
        ? secondary
        : null;
    return IncrementGrid._(p, s);
  }

  /// Builds a grid from a canonical increments map (the shape produced by
  /// `PeriodizationModelUtils.incMapFromRaw`).
  factory IncrementGrid.fromMap(Map<String, double>? inc) => IncrementGrid(
        primary: inc?['primary'] ?? defaultPrimary,
        secondary: inc?['secondary'],
      );

  /// Recovers the lattice a list of valid weights lies on.
  ///
  /// This is the compatibility bridge for the call sites that are still handed
  /// a `List<double> increments` rather than a grid. Every such list in the app
  /// is produced by `expandIncrementOptions`, whose output is exactly:
  ///
  ///  * primary only  → uniformly spaced, so the single gap is the primary;
  ///  * with secondary → gaps alternate `S, P - S`, so the first gap above the
  ///    lowest member is `S` and two consecutive gaps span one full `P`.
  ///
  /// Callers that know their configuration should build the grid from the
  /// settings map instead: an unusual hand-written list (for example one whose
  /// secondary exceeds its primary) cannot be recovered unambiguously from its
  /// values alone.
  factory IncrementGrid.fromWeights(List<double> weights) {
    final sorted = <double>[];
    for (final w in weights) {
      if (!w.isFinite) continue;
      sorted.add(w);
    }
    sorted.sort();
    // De-duplicate so repeated values cannot masquerade as a zero-width gap.
    final unique = <double>[];
    for (final w in sorted) {
      if (unique.isEmpty || (w - unique.last).abs() > _eps) unique.add(w);
    }

    if (unique.isEmpty) return IncrementGrid(primary: defaultPrimary);
    if (unique.length == 1) return IncrementGrid(primary: unique.first);

    final double gap0 = unique[1] - unique[0];
    if (unique.length == 2) return IncrementGrid(primary: gap0);

    final double gap1 = unique[2] - unique[1];
    if ((gap1 - gap0).abs() <= _eps) {
      // Uniform spacing — a primary-only lattice.
      return IncrementGrid(primary: gap0);
    }
    return IncrementGrid(primary: gap0 + gap1, secondary: gap0);
  }

  /// True when this grid carries a secondary offset sequence.
  bool get hasSecondary => secondary != null;

  /// The offsets of the sequences that make up the lattice.
  List<double> get _offsets =>
      secondary == null ? const <double>[0.0] : <double>[0.0, secondary!];

  /// Nearest valid weight on the sequence `offset + k * primary`, `k >= 0`.
  double _snapOnLine(double target, double offset) {
    if (target <= offset) return offset;
    final int k = ((target - offset) / primary).round();
    // Reproduces the exact expression the old pre-generated list used
    // (`i * primary`, or `i * primary + secondary`), so members below the old
    // ceiling are bit-identical to the values they replace.
    return offset == 0.0 ? k * primary : k * primary + offset;
  }

  /// Greatest valid weight on one sequence that is strictly below [weight].
  double? _previousOnLine(double weight, double offset) {
    if (weight <= offset + _eps) return null;
    int k = ((weight - offset) / primary).floor();
    double v = offset == 0.0 ? k * primary : k * primary + offset;
    while (v > weight - _eps) {
      k -= 1;
      if (k < 0) return null;
      v = offset == 0.0 ? k * primary : k * primary + offset;
    }
    return v;
  }

  /// Smallest valid weight on one sequence that is strictly above [weight].
  double _nextOnLine(double weight, double offset) {
    if (weight < offset - _eps) return offset;
    int k = ((weight - offset) / primary).ceil();
    double v = offset == 0.0 ? k * primary : k * primary + offset;
    while (v < weight + _eps) {
      k += 1;
      v = offset == 0.0 ? k * primary : k * primary + offset;
    }
    return v;
  }

  /// The valid weight closest to [target].
  ///
  /// Never negative — the lattice starts at 0. Ties resolve UPWARD, which is
  /// what the list this replaces did: `list.reduce((a, b) => (a - t).abs() <
  /// (b - t).abs() ? a : b)` over an ascending list keeps `b` when the two are
  /// equidistant, i.e. the higher member. `(x / primary).round()` rounds halves
  /// away from zero and so agrees on the primary sequence for free.
  double snap(double target) {
    final double best = _snapOnLine(target, 0.0);
    if (secondary == null) return best;
    final double bestDist = (best - target).abs();
    final double other = _snapOnLine(target, secondary!);
    final double otherDist = (other - target).abs();
    if ((otherDist - bestDist).abs() <= _eps) {
      return other > best ? other : best;
    }
    return otherDist < bestDist ? other : best;
  }

  /// The greatest valid weight strictly below [weight], or null at the bottom
  /// of the lattice.
  double? previous(double weight) {
    double? best;
    for (final offset in _offsets) {
      final v = _previousOnLine(weight, offset);
      if (v == null) continue;
      if (best == null || v > best) best = v;
    }
    return best;
  }

  /// The greatest valid weight at or below [weight], or null when [weight] is
  /// below the bottom of the lattice.
  double? previousOrSame(double weight) {
    if (contains(weight)) return snap(weight);
    return previous(weight);
  }

  /// The smallest valid weight strictly above [weight]. Always defined — the
  /// lattice has no upper bound, which is the whole point of this class.
  double next(double weight) {
    double? best;
    for (final offset in _offsets) {
      final v = _nextOnLine(weight, offset);
      if (best == null || v < best) best = v;
    }
    return best!;
  }

  /// True when [weight] is itself a member of the lattice.
  bool contains(double weight) {
    if (!weight.isFinite || weight < -_eps) return false;
    for (final offset in _offsets) {
      if (weight < offset - _eps) continue;
      final double k = (weight - offset) / primary;
      if ((k - k.roundToDouble()).abs() * primary <= _eps && k >= -_eps) {
        return true;
      }
    }
    return false;
  }

  /// The local window of valid weights around [target]: [span] members below
  /// the snapped centre, the centre, and [span] members above — sorted,
  /// de-duplicated and clamped to the bottom of the lattice.
  ///
  /// This replaces the old `centre - delta / centre / centre + delta`
  /// construction, which could invent weights that are not on the lattice when
  /// the spacing is non-uniform (primary 2.5 + secondary 1.0 gives 0, 1, 2.5,
  /// 3.5, 5 … where `2.5 - 1.0 = 1.5` is not a valid weight).
  List<double> neighborhood(double target, {int span = 1}) {
    final double centre = snap(target);
    final out = <double>[centre];

    double cursor = centre;
    for (int i = 0; i < span; i++) {
      final p = previous(cursor);
      if (p == null) break;
      out.add(p);
      cursor = p;
    }

    cursor = centre;
    for (int i = 0; i < span; i++) {
      cursor = next(cursor);
      out.add(cursor);
    }

    out.sort();
    final deduped = <double>[];
    for (final w in out) {
      if (deduped.isEmpty || (w - deduped.last).abs() > _eps) deduped.add(w);
    }
    return deduped;
  }

  /// Materialises the first [positions] primary steps (plus their secondary
  /// offsets) as a sorted list.
  ///
  /// Retained ONLY for the display/compatibility callers that still need a
  /// `List<double>`. No progression decision may be taken from this list: it is
  /// finite, and that finiteness is precisely the bug this class removes.
  List<double> expand({int positions = 100}) {
    final opts = <double>{};
    for (int i = 0; i < positions; i++) {
      opts.add(i * primary);
    }
    final s = secondary;
    if (s != null) {
      for (final base in opts.toList()) {
        opts.add(base + s);
      }
    }
    final list = opts.toList()..sort();
    return list;
  }

  @override
  String toString() => 'IncrementGrid(primary: $primary'
      '${secondary == null ? '' : ', secondary: $secondary'})';

  @override
  bool operator ==(Object other) =>
      other is IncrementGrid &&
      (other.primary - primary).abs() <= _eps &&
      ((other.secondary == null && secondary == null) ||
          (other.secondary != null &&
              secondary != null &&
              (other.secondary! - secondary!).abs() <= _eps));

  @override
  int get hashCode => Object.hash(primary, secondary);
}
