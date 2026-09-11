/// What one Big Five record column says, as plain strings.
///
/// Pure and widget-free, so the arithmetic is pinned by unit tests rather than
/// by reading pixels.
///
/// ── Bodyweight-loaded lifts (the Chin-Up) ──────────────────────────────────
/// A Chin-Up is lifted as bodyweight plus whatever hangs from the belt, and
/// the number an athlete recognises is the ADDED part: "+53.5 kg × 3, at 85 kg
/// BW". The server publishes, beside the record, the basis of the stored load
/// and the bodyweight recorded for THAT lift's own date. This file only does
/// the presentation arithmetic:
///
///   stored as bodyweight + added  (legacy workout screen)
///     best E1RM  = record E1RM − bodyweight
///     source     = source weight − bodyweight
///     heaviest   = record weight − bodyweight
///   stored as the added load      (WES2)
///     best E1RM  = E1RM(added + bodyweight, reps) − bodyweight
///     source     = heaviest = the stored added load
///
/// Each record uses its OWN bodyweight — the best-E1RM set and the heaviest set
/// are usually on different days. Nothing here changes which set holds a
/// record, the stored record, or its fingerprint.
///
/// When the context is missing the column says so instead of guessing: a record
/// published before it carried a basis is shown as the total it is, and a lift
/// with no weigh-in on or before its date says "BW not recorded". Today's
/// bodyweight is never substituted.
library;

import '../core/big_five.dart';
import '../core/e1rm_spec.dart';
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

  final String? basis = record.loadBasis;
  final double? bw = _validBodyweight(record.bodyweightKg);

  if (basis == null) {
    // Published before records carried a basis. The stored number is the
    // system total the legacy screen wrote, so say that — no subtraction.
    return RecordPresentation(
      value: totalValue,
      source: totalSource,
      bodyweightNote: 'Total incl. BW',
    );
  }

  if (basis == ShowcaseLoadBasis.added) {
    final double added = record.weight;
    final String source = '${units.formatAdded(added)} × ${record.reps}';
    if (bw == null) {
      // The added load is known; an E1RM of a bodyweight lift is not, without
      // the bodyweight it was lifted at.
      return RecordPresentation(
        value: isE1rm ? '—' : units.formatAdded(added),
        source: source,
        bodyweightNote: 'BW not recorded',
      );
    }
    return RecordPresentation(
      value: isE1rm
          ? units.formatAdded(showcaseE1rm(added + bw, record.reps) - bw)
          : units.formatAdded(added),
      source: source,
      bodyweightNote: 'at ${units.format(bw)} BW',
    );
  }

  // Stored as bodyweight + added.
  if (bw == null) {
    return RecordPresentation(
      value: totalValue,
      source: totalSource,
      bodyweightNote: 'Total · BW not recorded',
    );
  }
  final double addedLoad = record.weight - bw;
  return RecordPresentation(
    value: isE1rm
        ? units.formatAdded(record.e1rm - bw)
        : units.formatAdded(addedLoad),
    source: '${units.formatAdded(addedLoad)} × ${record.reps}',
    bodyweightNote: 'at ${units.format(bw)} BW',
  );
}

double? _validBodyweight(double? kg) =>
    (kg != null && kg.isFinite && kg > 0) ? kg : null;
