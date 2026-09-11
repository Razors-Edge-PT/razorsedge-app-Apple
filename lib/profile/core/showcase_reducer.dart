/// Pure, dependency-free reducer that turns workout documents into the Big Five
/// lifetime showcase.
///
/// Mirrored one-for-one by `functions/showcase/reducer.js`, which is what
/// actually maintains the projection in production. This Dart copy exists so
/// the semantics are pinned by Flutter tests and so the owner's own client can
/// recompute a missing snapshot without waiting on a backfill.
///
/// ── Shape ───────────────────────────────────────────────────────────────────
/// Per (slot, dateKey) we keep ONE compact contribution: the day's best-E1RM
/// candidate and the day's heaviest candidate. Lifetime state is a fold over
/// those day contributions, so:
///   * a normal append folds one new day,
///   * an edit/delete/out-of-order write rebuilds ONE slot from ITS day docs,
///   * the result is a pure function of the surviving days — identical whether
///     it was reached by appending or by rebuilding, which is what makes
///     duplicate and out-of-order trigger delivery safe.
///
/// ── Bodyweight-loaded lifts (the Chin-Up) ───────────────────────────────────
/// Their stored loads are not comparable as raw numbers, so their candidates
/// are ranked on the loads normalised by bodyweight_load.dart at the bodyweight
/// recorded for that day. Their day contributions also keep the day's sets and
/// that bodyweight. Every other lift keeps exactly its shape and ordering.
library;

import 'dart:math' as math;

import '../../bodyweight_load.dart';
import 'big_five.dart';
import 'e1rm_spec.dart';
import 'showcase_models.dart';

/// Relative epsilon. Absorbs float representation noise; genuine equality is
/// never reported as an improvement.
const double _epsRel = 1e-9;

/// `a > b`, ignoring representation noise.
bool _greater(double a, double b) {
  if (!a.isFinite) return false;
  if (!b.isFinite) return true;
  final double scale = math.max(a.abs(), b.abs());
  return (a - b) > _epsRel * (scale < 1.0 ? 1.0 : scale);
}

/// Three-way weight/E1RM comparison under the same epsilon.
int _cmpNum(double a, double b) {
  if (_greater(a, b)) return 1;
  if (_greater(b, a)) return -1;
  return 0;
}

Map<String, Object?> _setMap(ShowcaseSet s) => <String, Object?>{
      'setKey': s.setKey,
      'weight': s.weight,
      'reps': s.reps,
      if (s.basis != null) 'basis': s.basis,
      if (s.typedAddedKg != null) 'typedAddedKg': s.typedAddedKg,
    };

ShowcaseSet? _readSet(Object? m) {
  if (m is! Map) return null;
  final double w = (m['weight'] as num?)?.toDouble() ?? 0;
  final int r = (m['reps'] as num?)?.toInt() ?? 0;
  if (w <= 0 || r <= 0) return null;
  final Object? typed = m['typedAddedKg'];
  return ShowcaseSet(
    setKey: (m['setKey'] as String?) ?? '',
    weight: w,
    reps: r,
    basis: ShowcaseLoadBasis.parse(m['basis']),
    typedAddedKg: (typed is num && typed.isFinite) ? typed.toDouble() : null,
  );
}

/// A day's contribution for one slot: two candidate sets — plus, for a
/// bodyweight-loaded lift, the day's sets and the bodyweight they were ranked
/// at.
class ShowcaseDayContribution {
  const ShowcaseDayContribution({
    required this.slot,
    required this.dateKey,
    required this.exerciseId,
    required this.bestE1rmSet,
    required this.heaviestSet,
    this.sets,
    this.bodyweight,
  });

  final String slot;

  /// `YYYY-MM-DD` workout document id.
  final String dateKey;

  /// Best-known original casing of the catalogue id seen that day.
  final String exerciseId;
  final ShowcaseSet bestE1rmSet;
  final ShowcaseSet heaviestSet;

  /// Bodyweight-loaded lifts only: every valid set of the lift that day.
  final List<ShowcaseSet>? sets;

  /// Bodyweight-loaded lifts only: the bodyweight recorded on or before
  /// [dateKey], or null when none was.
  final RecordedBodyweight? bodyweight;

  Map<String, Object?> toMap() => <String, Object?>{
        'slot': slot,
        'dateKey': dateKey,
        'exerciseId': exerciseId,
        'bestE1rm': _setMap(bestE1rmSet),
        'heaviest': _setMap(heaviestSet),
        if (isBodyweightLoadedSlot(slot)) ...<String, Object?>{
          'sets': <Object?>[for (final ShowcaseSet s in sets ?? const []) _setMap(s)],
          'bodyweight': bodyweight?.toMap(),
        },
      };

  static ShowcaseDayContribution? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final Object? slot = raw['slot'];
    final Object? dateKey = raw['dateKey'];
    if (slot is! String || dateKey is! String) return null;

    final ShowcaseSet? e = _readSet(raw['bestE1rm']);
    final ShowcaseSet? h = _readSet(raw['heaviest']);
    if (e == null || h == null) return null;
    final Object? rawSets = raw['sets'];
    return ShowcaseDayContribution(
      slot: slot,
      dateKey: dateKey,
      exerciseId: (raw['exerciseId'] as String?) ?? '',
      bestE1rmSet: e,
      heaviestSet: h,
      sets: rawSets is List
          ? <ShowcaseSet>[
              for (final Object? s in rawSets)
                if (_readSet(s) != null) _readSet(s)!,
            ]
          : null,
      bodyweight: RecordedBodyweight.fromMap(raw['bodyweight']),
    );
  }
}

/// Extracts every valid completed Big Five set from one workout document.
///
/// A set participates only when `weight > 0` AND `reps > 0` — the app's
/// completed-set convention. `actualWeight` / `actualReps` are accepted as the
/// WES2 aliases. RIR is never read here, in any form.
Map<String, List<ShowcaseSet>> extractBigFiveSets(Object? workoutData) {
  final Map<String, List<ShowcaseSet>> out = <String, List<ShowcaseSet>>{};
  if (workoutData is! Map) return out;
  final Object? exercises = workoutData['exercises'];
  if (exercises is! List) return out;

  final Map<String, int> ordinal = <String, int>{};

  for (final Object? row in exercises) {
    if (row is! Map) continue;
    final Object? rawId = row['exerciseId'] ?? row['id'];
    final BigFiveLift? lift = matchBigFive(rawId: rawId, rawName: row['name']);
    if (lift == null) continue;

    final Object? sets = row['sets'];
    if (sets is! List) continue;
    for (final Object? s in sets) {
      if (s is! Map) continue;
      final Object? rawW = s['weight'] ?? s['actualWeight'];
      final Object? rawR = s['reps'] ?? s['actualReps'];
      if (rawW is! num || rawR is! num) continue;
      final double w = rawW.toDouble();
      final double r = rawR.toDouble();
      if (!w.isFinite || !r.isFinite || w <= 0 || r <= 0) continue;

      // The positional fallback counts VALID sets of THIS lift within the day,
      // not the row/set position in the document. Reordering or deleting an
      // unrelated exercise therefore cannot shift another lift's set keys, so
      // fingerprints — and the proof videos attached to them — stay put.
      final int n = ordinal[lift.slot] ?? 0;
      ordinal[lift.slot] = n + 1;

      final Object? explicitId = s['id'] ?? s['setId'];
      final String setKey =
          (explicitId is String && explicitId.trim().isNotEmpty)
              ? explicitId.trim()
              : 's$n';

      // Bodyweight-loaded lifts only: what the stored weight means, and the
      // typed added load the legacy screen kept beside its total.
      final String? basis =
          lift.bodyweightLoaded ? ShowcaseLoadBasis.ofSetMap(s) : null;
      (out[lift.slot] ??= <ShowcaseSet>[]).add(ShowcaseSet(
        setKey: setKey,
        weight: w,
        reps: r.round(),
        basis: basis,
        typedAddedKg:
            basis == ShowcaseLoadBasis.absolute ? typedAddedKgOf(s) : null,
      ));
    }
  }
  return out;
}

/// Best-known original casing of each slot's catalogue id within one document.
Map<String, String> _casingForDay(Object? workoutData) {
  final Map<String, String> casing = <String, String>{};
  if (workoutData is! Map) return casing;
  final Object? exercises = workoutData['exercises'];
  if (exercises is! List) return casing;
  for (final Object? row in exercises) {
    if (row is! Map) continue;
    final Object? rawId = row['exerciseId'] ?? row['id'];
    final BigFiveLift? lift = matchBigFive(rawId: rawId, rawName: row['name']);
    if (lift == null) continue;
    if (rawId is String && rawId.trim().isNotEmpty) {
      final String id = rawId.trim();
      final String existing = casing[lift.slot] ?? '';
      // Prefer a casing that still carries capitals: production wrote
      // lowercased copies of catalogue ids for two months in 2026.
      final bool existingIsFolded = existing == existing.toLowerCase();
      final bool candidateHasCase = id != id.toLowerCase();
      if (existing.isEmpty || (candidateHasCase && existingIsFolded)) {
        casing[lift.slot] = id;
      }
    } else {
      // Id-less legacy row matched by alias: use the catalogue id it means.
      casing[lift.slot] ??= lift.exerciseId;
    }
  }
  return casing;
}

// ── Ranking ─────────────────────────────────────────────────────────────────
// Each candidate reduces to a rank key (tier desc, value desc, tie desc). For
// every lift but the bodyweight-loaded ones the tier is constant and value/tie
// are the raw E1RM/weight — the ordering the showcase has always used.

NormalizedLoad _normalize(ShowcaseSet s, RecordedBodyweight? bw) =>
    normalizeLoad(
      basis: s.basis == ShowcaseLoadBasis.added
          ? BodyweightLoadBasis.added
          : BodyweightLoadBasis.absolute,
      storedKg: s.weight,
      reps: s.reps,
      typedAddedKg: s.typedAddedKg,
      bodyweightKg: bw?.weightKg,
    );

RankKey _e1rmKey(String slot, ShowcaseSet s, RecordedBodyweight? bw) =>
    isBodyweightLoadedSlot(slot)
        ? e1rmRank(_normalize(s, bw), s.reps)
        : RankKey(0, s.e1rm, s.weight);

RankKey _heaviestKey(String slot, ShowcaseSet s, RecordedBodyweight? bw) =>
    isBodyweightLoadedSlot(slot)
        ? heaviestRank(_normalize(s, bw))
        : RankKey(0, s.weight);

int _compareKeys(RankKey a, RankKey b) {
  if (a.tier != b.tier) return a.tier > b.tier ? 1 : -1;
  final int byValue = _cmpNum(a.value, b.value);
  if (byValue != 0) return byValue;
  if (a.tie == null && b.tie == null) return 0;
  return _cmpNum(a.tie ?? 0, b.tie ?? 0);
}

/// Reduces one workout document to at most five day contributions.
///
/// [bodyweight] is the weigh-in recorded on or before [dateKey] (or null).
/// Only bodyweight-loaded lifts read it.
///
/// Within a day the winners are picked by:
///   * best E1RM  → e1rm desc, weight desc, setKey asc
///   * heaviest   → weight desc, reps desc, setKey asc
/// (normalised values for a bodyweight-loaded lift), which is exactly the
/// lifetime ordering with the date term held constant, so folding day winners
/// is equivalent to scanning every set of every day.
Map<String, ShowcaseDayContribution> summarizeWorkoutDay(
  String dateKey,
  Object? workoutData, {
  RecordedBodyweight? bodyweight,
}) {
  final Map<String, List<ShowcaseSet>> bySlot = extractBigFiveSets(workoutData);
  final Map<String, String> casing = _casingForDay(workoutData);
  final Map<String, ShowcaseDayContribution> out =
      <String, ShowcaseDayContribution>{};

  for (final MapEntry<String, List<ShowcaseSet>> entry in bySlot.entries) {
    final List<ShowcaseSet> sets = entry.value;
    if (sets.isEmpty) continue;
    final String slot = entry.key;
    final bool bwLoaded = isBodyweightLoadedSlot(slot);
    final RecordedBodyweight? bw = bwLoaded ? bodyweight : null;

    ShowcaseSet bestE = sets.first;
    ShowcaseSet bestH = sets.first;
    for (final ShowcaseSet s in sets.skip(1)) {
      if (_betterE1rmWithinDay(slot, s, bestE, bw)) bestE = s;
      if (_betterHeaviestWithinDay(slot, s, bestH, bw)) bestH = s;
    }

    out[slot] = ShowcaseDayContribution(
      slot: slot,
      dateKey: dateKey,
      exerciseId: casing[slot] ?? bigFiveBySlot(slot)!.exerciseId,
      bestE1rmSet: bestE,
      heaviestSet: bestH,
      sets: bwLoaded ? List<ShowcaseSet>.unmodifiable(sets) : null,
      bodyweight: bw,
    );
  }
  return out;
}

bool _betterE1rmWithinDay(
    String slot, ShowcaseSet a, ShowcaseSet b, RecordedBodyweight? bw) {
  final int byKey = _compareKeys(_e1rmKey(slot, a, bw), _e1rmKey(slot, b, bw));
  if (byKey != 0) return byKey > 0;
  return a.setKey.compareTo(b.setKey) < 0;
}

bool _betterHeaviestWithinDay(
    String slot, ShowcaseSet a, ShowcaseSet b, RecordedBodyweight? bw) {
  final int byKey =
      _compareKeys(_heaviestKey(slot, a, bw), _heaviestKey(slot, b, bw));
  if (byKey != 0) return byKey > 0;
  if (a.reps != b.reps) return a.reps > b.reps;
  return a.setKey.compareTo(b.setKey) < 0;
}

/// Folds day contributions for ONE slot into that slot's lifetime snapshot.
///
/// Cross-day ordering:
///   * best E1RM → e1rm desc, weight desc, dateKey desc, setKey asc
///   * heaviest  → weight desc, reps desc, dateKey desc, setKey asc
/// (normalised values for a bodyweight-loaded lift).
///
/// The date term makes the later of two identical performances the winner, and
/// setKey makes the last resort stable, so the fold is deterministic no matter
/// what order the days arrive in.
ShowcaseLiftSnapshot foldSlot(
  String slot,
  Iterable<ShowcaseDayContribution> days,
) {
  ShowcaseDayContribution? bestE;
  ShowcaseDayContribution? bestH;

  for (final ShowcaseDayContribution d in days) {
    if (d.slot != slot) continue;

    if (bestE == null || _betterE1rmAcrossDays(d, bestE)) bestE = d;
    if (bestH == null || _betterHeaviestAcrossDays(d, bestH)) bestH = d;
  }

  if (bestE == null || bestH == null) return ShowcaseLiftSnapshot(slot: slot);
  return ShowcaseLiftSnapshot(
    slot: slot,
    bestE1rm: _recordOf(slot, bestE, bestE.bestE1rmSet),
    heaviest: _recordOf(slot, bestH, bestH.heaviestSet),
  );
}

bool _betterE1rmAcrossDays(
  ShowcaseDayContribution a,
  ShowcaseDayContribution b,
) {
  final int byKey = _compareKeys(
    _e1rmKey(a.slot, a.bestE1rmSet, a.bodyweight),
    _e1rmKey(b.slot, b.bestE1rmSet, b.bodyweight),
  );
  if (byKey != 0) return byKey > 0;
  return _laterSource(
      a.dateKey, b.dateKey, a.bestE1rmSet.setKey, b.bestE1rmSet.setKey);
}

bool _betterHeaviestAcrossDays(
  ShowcaseDayContribution a,
  ShowcaseDayContribution b,
) {
  final int byKey = _compareKeys(
    _heaviestKey(a.slot, a.heaviestSet, a.bodyweight),
    _heaviestKey(b.slot, b.heaviestSet, b.bodyweight),
  );
  if (byKey != 0) return byKey > 0;
  if (a.heaviestSet.reps != b.heaviestSet.reps) {
    return a.heaviestSet.reps > b.heaviestSet.reps;
  }
  return _laterSource(
      a.dateKey, b.dateKey, a.heaviestSet.setKey, b.heaviestSet.setKey);
}

/// Final tie-breaker: the later training date wins; on the same date the
/// lexicographically smaller set key wins, which is stable across rebuilds.
bool _laterSource(
  String candidateDate,
  String incumbentDate,
  String candidateSetKey,
  String incumbentSetKey,
) {
  final int byDate = candidateDate.compareTo(incumbentDate);
  if (byDate != 0) return byDate > 0;
  return candidateSetKey.compareTo(incumbentSetKey) < 0;
}

ShowcaseRecord _recordOf(
  String slot,
  ShowcaseDayContribution day,
  ShowcaseSet set,
) {
  final String fingerprint = recordFingerprint(
    slot: slot,
    exerciseId: day.exerciseId,
    dateKey: day.dateKey,
    setKey: set.setKey,
    weight: set.weight,
    reps: set.reps,
  );
  if (!isBodyweightLoadedSlot(slot)) {
    return ShowcaseRecord(
      slot: slot,
      exerciseId: day.exerciseId,
      dateKey: day.dateKey,
      setKey: set.setKey,
      weight: set.weight,
      reps: set.reps,
      e1rm: set.e1rm,
      formulaVersion: kE1rmFormulaVersion,
      loadBasis: set.basis,
      fingerprint: fingerprint,
    );
  }
  final RecordedBodyweight? bw = day.bodyweight;
  final NormalizedLoad n = _normalize(set, bw);
  return ShowcaseRecord(
    slot: slot,
    exerciseId: day.exerciseId,
    dateKey: day.dateKey,
    setKey: set.setKey,
    weight: set.weight,
    reps: set.reps,
    // The E1RM of what was actually lifted, bodyweight included, whenever the
    // bodyweight is known; the stored number's otherwise.
    e1rm: n.totalE1rm ?? set.e1rm,
    formulaVersion: kE1rmFormulaVersion,
    loadBasis: set.basis == ShowcaseLoadBasis.added
        ? ShowcaseLoadBasis.added
        : ShowcaseLoadBasis.absolute,
    fingerprint: fingerprint,
    addedKg: n.addedKg,
    totalKg: n.totalKg,
    totalE1rm: n.totalE1rm,
    addedE1rm: n.addedE1rm,
    bodyweightKg: bw?.weightKg,
    bodyweightDateKey: bw?.dateKey,
  );
}

/// Whole-history rebuild. `workoutsByDate` maps `YYYY-MM-DD` → workout data;
/// [bodyweightByDate] maps the same keys → the weigh-in recorded on or before
/// that date. Pure: the same surviving history always produces the same
/// snapshot.
ProfileShowcase buildShowcase(
  Map<String, Object?> workoutsByDate, {
  Map<String, RecordedBodyweight?> bodyweightByDate =
      const <String, RecordedBodyweight?>{},
}) {
  final List<ShowcaseDayContribution> all = <ShowcaseDayContribution>[];
  final List<String> dates = workoutsByDate.keys.toList()..sort();
  for (final String dateKey in dates) {
    all.addAll(summarizeWorkoutDay(
      dateKey,
      workoutsByDate[dateKey],
      bodyweight: bodyweightByDate[dateKey],
    ).values);
  }
  final Map<String, ShowcaseLiftSnapshot> lifts =
      <String, ShowcaseLiftSnapshot>{};
  for (final String slot in BigFiveSlot.ordered) {
    final ShowcaseLiftSnapshot s = foldSlot(slot, all);
    if (!s.isEmpty) lifts[slot] = s;
  }
  return ProfileShowcase(lifts: lifts);
}
