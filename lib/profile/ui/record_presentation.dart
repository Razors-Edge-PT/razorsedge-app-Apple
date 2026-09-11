/// What one Big Five record column says, as plain strings.
///
/// Pure and widget-free, so the arithmetic is pinned by unit tests rather than
/// by reading pixels.
///
/// ── Bodyweight-loaded lifts (the Chin-Up) ──────────────────────────────────
/// A Chin-Up is lifted as bodyweight plus whatever hangs from the belt, and
/// the number an athlete recognises is the ADDED part: "+53.5 kg × 3, at 85 kg
/// BW". The server publishes, beside the record, its loads normalised at the
/// bodyweight recorded for THAT lift's own date (bodyweight_load.dart):
///
///   best E1RM  = added E1RM  (E1RM of the total, minus that bodyweight)
///   heaviest   = added load
///   source     = added load × reps
///
/// A record published before those fields existed is normalised here from its
/// basis and bodyweight by the same boundary. Each record uses its OWN
/// bodyweight — the best-E1RM set and the heaviest set are usually on
/// different days. Nothing here changes the stored record or its fingerprint.
///
/// When the context is missing the column says so instead of guessing: a record
/// published before it carried a basis is shown as the total it is, and a lift
/// with no weigh-in on or before its date says "BW not recorded". Today's
/// bodyweight is never substituted.
library;

import '../../bodyweight_load.dart';
import '../core/big_five.dart';
import '../core/showcase_models.dart';
import 'units.dart';

/// The strings for one record column.
class RecordPresentation {
  const RecordPresentation({
    required this.value,
    required this.source,
    this.bodyweightNote,
  });

  /// The headline number: the E1RM or the heaviest load.
  final String value;

  /// The source performance: "180 kg × 2", or "+53.5 kg × 3".
  final String source;

  /// Bodyweight-loaded lifts only: "at 85 kg BW", or why it is absent.
  final String? bodyweightNote;
}

/// Presents [record] for the BEST E1RM column when [isE1rm], otherwise for the
/// HEAVIEST column.
RecordPresentation presentShowcaseRecord({
  required ShowcaseRecord record,
  required bool isE1rm,
  required WeightUnits units,
}) {
  final String totalValue =
      isE1rm ? units.format(record.e1rm) : units.format(record.weight);
  final String totalSource = '${units.format(record.weight)} × ${record.reps}';

  if (!isBodyweightLoadedSlot(record.slot)) {
    // Every other lift: exactly the strings the showcase has always shown.
    return RecordPresentation(value: totalValue, source: totalSource);
  }

  if (record.loadBasis == null) {
    // Published before records carried a basis. The stored number is the
    // system total the legacy screen wrote, so say that — no subtraction.
    return RecordPresentation(
      value: totalValue,
      source: totalSource,
      bodyweightNote: 'Total incl. BW',
    );
  }

  final double? bw = _validBodyweight(record.bodyweightKg);
  final NormalizedLoad n = _normalizedOf(record, bw);
  final double? added = n.addedKg;

  if (added != null && bw != null) {
    final double? addedE1rm = n.addedE1rm;
    return RecordPresentation(
      value: isE1rm
          ? (addedE1rm == null ? '—' : units.formatAdded(addedE1rm))
          : units.formatAdded(added),
      source: '${units.formatAdded(added)} × ${record.reps}',
      bodyweightNote: 'at ${units.format(bw)} BW',
    );
  }

  if (added != null) {
    // The added load is known; an E1RM of a bodyweight lift is not, without
    // the bodyweight it was lifted at.
    return RecordPresentation(
      value: isE1rm ? '—' : units.formatAdded(added),
      source: '${units.formatAdded(added)} × ${record.reps}',
      bodyweightNote: 'BW not recorded',
    );
  }

  // Only the total is known.
  final double total = n.totalKg ?? record.weight;
  return RecordPresentation(
    value: isE1rm
        ? units.format(n.totalE1rm ?? record.e1rm)
        : units.format(total),
    source: '${units.format(total)} × ${record.reps}',
    bodyweightNote: 'Total · BW not recorded',
  );
}

/// The record's normalised loads: its published fields, or — for a record
/// published before it carried them — derived from its basis and bodyweight.
NormalizedLoad _normalizedOf(ShowcaseRecord r, double? bw) {
  if (r.addedKg != null || r.totalKg != null) {
    return NormalizedLoad(
      addedKg: r.addedKg,
      totalKg: r.totalKg,
      totalE1rm: r.totalE1rm,
      addedE1rm: bw == null ? null : r.addedE1rm,
    );
  }
  return normalizeLoad(
    basis: r.loadBasis,
    storedKg: r.weight,
    reps: r.reps,
    bodyweightKg: bw,
  );
}

double? _validBodyweight(double? kg) =>
    (kg != null && kg.isFinite && kg > 0) ? kg : null;
