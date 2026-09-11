/// Bodyweight-loaded exercises (Chin-Up, Pull-Up, Dips, weighted push-ups …):
/// the ONE place a stored set is turned into comparable numbers.
///
/// Pinned mirror of `functions/showcase/bodyweight.js`. Both suites assert
/// `functions/showcase/bodyweight_vectors.json`, so progression history, the
/// history screens, the profile showcase mirror and the server's showcase
/// records all read a set the same way.
///
/// ── Why ─────────────────────────────────────────────────────────────────────
/// A bodyweight exercise is lifted as the athlete's bodyweight plus whatever
/// hangs from the belt, and history stores it in two shapes:
///
///   * the legacy workout screen stored the TOTAL (its bodyweight + the added
///     load) in `weight`, and on most sets the typed added load beside it in
///     `weightAdded` / `addedWeight`;
///   * WES2 stores exactly what was typed — the ADDED load — and is the only
///     writer that stamps `setIndex` on a set.
///
/// So every set is normalised:
///
///   stored as                     added load            total load
///   WES2 (setIndex)               stored                stored + BW
///   legacy, typed added present   typed (weightAdded)   typed + BW
///   legacy, no typed added        stored − BW           stored
///
///   total E1RM = the showcase E1RM curve on the TOTAL load
///   added E1RM = total E1RM − BW
///
/// BW is the bodyweight RECORDED on or before that lift's own date
/// ([pickBodyweightAsOf]) — never today's, never a later weigh-in, never a
/// default. Anything that needs a bodyweight that was never recorded is null,
/// except that a legacy set with no recorded bodyweight keeps the total the
/// legacy screen stored as its total (which invents nothing).
///
/// The stored set itself is never rewritten.
library;

import 'profile/core/e1rm_spec.dart';

/// How a stored set weight relates to the athlete's bodyweight.
class BodyweightLoadBasis {
  BodyweightLoadBasis._();

  /// Stored weight is bodyweight + added load (the legacy workout screen).
  static const String absolute = 'absolute';

  /// Stored weight is the added load alone (WES2, which saves what was typed).
  static const String added = 'added';

  /// The basis of one stored set map. WES2 is the only writer that stamps
  /// `setIndex` on a set.
  static String ofSetMap(Map<Object?, Object?>? setMap) {
    final Object? idx = setMap?['setIndex'];
    return (idx is num && idx.isFinite) ? added : absolute;
  }
}

/// The added load the legacy screen stored beside its total (`weightAdded`, or
/// its older twin `addedWeight`), or null.
double? typedAddedKgOf(Map<Object?, Object?>? setMap) {
  if (setMap == null) return null;
  final Object? a = setMap['weightAdded'];
  final Object? b = setMap['addedWeight'];
  final Object? v = a is num ? a : (b is num ? b : null);
  if (v is! num) return null;
  final double d = v.toDouble();
  return (d.isFinite && d >= 0) ? d : null;
}

double? _validKg(double? v) => (v != null && v.isFinite && v > 0) ? v : null;

double? _finite(double? v) => (v != null && v.isFinite) ? v : null;

/// One set's loads, normalised. Unknown values are null.
class NormalizedLoad {
  const NormalizedLoad({
    this.addedKg,
    this.totalKg,
    this.totalE1rm,
    this.addedE1rm,
  });

  final double? addedKg;
  final double? totalKg;
  final double? totalE1rm;
  final double? addedE1rm;
}

/// The TOTAL load of one stored set (see the table above), or null when it
/// needs a bodyweight that was never recorded.
double? totalLoadKg({
  required String? basis,
  required double? storedKg,
  double? typedAddedKg,
  double? bodyweightKg,
}) =>
    normalizeLoad(
      basis: basis,
      storedKg: storedKg,
      reps: 0,
      typedAddedKg: typedAddedKg,
      bodyweightKg: bodyweightKg,
    ).totalKg;

/// Normalises one set of a bodyweight-loaded exercise.
NormalizedLoad normalizeLoad({
  required String? basis,
  required double? storedKg,
  required int reps,
  double? typedAddedKg,
  double? bodyweightKg,
}) {
  final double? bw = _validKg(bodyweightKg);
  final double? stored = _finite(storedKg);
  final double? typed =
      basis == BodyweightLoadBasis.added ? null : _finite(typedAddedKg);
  double? addedKg;
  double? totalKg;
  if (basis == BodyweightLoadBasis.added) {
    addedKg = stored;
    totalKg = (stored != null && bw != null) ? stored + bw : null;
  } else if (typed != null && typed >= 0) {
    addedKg = typed;
    totalKg = bw != null ? typed + bw : stored;
  } else {
    totalKg = stored;
    addedKg = (stored != null && bw != null) ? stored - bw : null;
  }
  final double? totalE1rm = (totalKg != null && totalKg > 0 && reps > 0)
      ? showcaseE1rm(totalKg, reps)
      : null;
  final double? addedE1rm =
      (totalE1rm != null && bw != null) ? totalE1rm - bw : null;
  return NormalizedLoad(
    addedKg: addedKg,
    totalKg: totalKg,
    totalE1rm: totalE1rm,
    addedE1rm: addedE1rm,
  );
}

/// A rank key, compared tier desc, value desc, tie desc.
class RankKey {
  const RankKey(this.tier, this.value, [this.tie]);

  final int tier;
  final double value;
  final double? tie;
}

/// How a normalised set ranks for BEST E1RM. A higher tier always wins, so a
/// set whose added E1RM is unknown can never outrank one whose is known:
///
///   2  added E1RM known            value = added E1RM, tie = added load
///   1  only the added load known   value = E1RM of the added load, tie = added
///   0  only the total known        value = total E1RM, tie = total load
RankKey e1rmRank(NormalizedLoad n, int reps) {
  if (n.addedE1rm != null) return RankKey(2, n.addedE1rm!, n.addedKg);
  if (n.addedKg != null) {
    final double v =
        (n.addedKg! > 0 && reps > 0) ? showcaseE1rm(n.addedKg!, reps) : 0;
    return RankKey(1, v, n.addedKg);
  }
  return RankKey(0, n.totalE1rm ?? 0, n.totalKg ?? 0);
}

/// How a normalised set ranks for HEAVIEST: the added load when it is known
/// (tier 1); otherwise, below every known one, the total (tier 0).
RankKey heaviestRank(NormalizedLoad n) {
  if (n.addedKg != null) return RankKey(1, n.addedKg!);
  return RankKey(0, n.totalKg ?? 0);
}

// ── Which bodyweight ────────────────────────────────────────────────────────

/// A weigh-in recorded for a lift date.
class RecordedBodyweight {
  const RecordedBodyweight({required this.weightKg, required this.dateKey});

  final double weightKg;

  /// `YYYY-MM-DD` day the weigh-in counts for.
  final String dateKey;

  Map<String, Object?> toMap() =>
      <String, Object?>{'weightKg': weightKg, 'dateKey': dateKey};

  /// [raw] when it is a valid `{ weightKg, dateKey }`, otherwise null.
  static RecordedBodyweight? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final Object? kg = raw['weightKg'];
    final Object? day = raw['dateKey'];
    if (kg is! num || day is! String || day.isEmpty) return null;
    final double? w = _validKg(kg.toDouble());
    return w == null ? null : RecordedBodyweight(weightKg: w, dateKey: day);
  }

  @override
  bool operator ==(Object other) =>
      other is RecordedBodyweight &&
      other.weightKg == weightKg &&
      other.dateKey == dateKey;

  @override
  int get hashCode => Object.hash(weightKg, dateKey);
}

/// One `users/{uid}/weights` entry, as the pick rule reads it.
class BodyweightEntry {
  const BodyweightEntry({
    required this.weight,
    this.unit,
    this.tod,
    this.dateKey,
    this.tsMillis,
    this.id = '',
  });

  final double? weight;
  final String? unit;

  /// 'am' | 'pm' | null (a missing time of day is AM).
  final String? tod;

  /// The calendar day the entry counts for. On the device this is the local
  /// day of its stamp; the server reads the stamp in Pacific/Auckland.
  final String? dateKey;
  final int? tsMillis;
  final String id;
}

/// `YYYY-MM-DD` of [d]'s own calendar day.
String bodyweightDateKeyOf(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

bool _isKg(String? unit) {
  if (unit == null || unit.isEmpty) return true;
  return unit.trim().toLowerCase() == 'kg';
}

final RegExp _dateKeyRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// The bodyweight recorded for a lift on [dateKey]:
///   * only kilogram entries with a finite, positive weight and a day count;
///   * days AFTER [dateKey] are excluded, the lift's own day is included;
///   * the latest qualifying day wins; on that day an AM entry is preferred,
///     then the latest stamp, then the id — so the choice is deterministic.
RecordedBodyweight? pickBodyweightAsOf(
  Iterable<BodyweightEntry> entries,
  String dateKey,
) {
  _Pick? best;
  for (final BodyweightEntry e in entries) {
    if (!_isKg(e.unit)) continue;
    final double? w = e.weight;
    if (w == null || !w.isFinite || w <= 0) continue;
    final int? ts = e.tsMillis;
    String? day;
    if (e.dateKey != null && _dateKeyRe.hasMatch(e.dateKey!)) {
      day = e.dateKey;
    } else if (ts != null) {
      day = bodyweightDateKeyOf(DateTime.fromMillisecondsSinceEpoch(ts));
    }
    if (day == null || day.compareTo(dateKey) > 0) continue;
    final _Pick cand = _Pick(
      weightKg: w,
      dateKey: day,
      am: (e.tod ?? '').trim().toLowerCase() != 'pm',
      ts: ts ?? 0,
      id: e.id,
    );
    if (best == null || cand.beats(best)) best = cand;
  }
  return best == null
      ? null
      : RecordedBodyweight(weightKg: best.weightKg, dateKey: best.dateKey);
}

class _Pick {
  const _Pick({
    required this.weightKg,
    required this.dateKey,
    required this.am,
    required this.ts,
    required this.id,
  });

  final double weightKg;
  final String dateKey;
  final bool am;
  final int ts;
  final String id;

  bool beats(_Pick b) {
    final int byDay = dateKey.compareTo(b.dateKey);
    if (byDay != 0) return byDay > 0;
    if (am != b.am) return am;
    if (ts != b.ts) return ts > b.ts;
    return id.compareTo(b.id) < 0;
  }
}
