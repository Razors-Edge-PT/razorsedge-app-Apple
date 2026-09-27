/// The canonical active training instance of one exercise on one date.
///
/// ONE exposure position drives both the rep target and the RIR, for WES2 and
/// for BB3. The two surfaces differ in exactly one input: BB3 also counts the
/// eligible PLANNED dates between today and a future selected date.
///
/// ── Exposure position ───────────────────────────────────────────────────────
/// The number of distinct calendar dates that precede the selected date:
///   * completed — valid performed dates in [blockStart, selectedDate)
///   * planned (BB3 only, future selected date) — dates in [today, selectedDate)
/// A date both completed and planned counts once. Plans before today (missed)
/// never count, the selected date never counts itself, and nothing on or
/// after the selected date is ever counted — so later history can never move
/// an earlier date.
///
/// ── Rep slot and RIR session ────────────────────────────────────────────────
/// Both come from the SAME position, each wrapped over its OWN configured
/// length:
///   repInstanceIndex = position % repInstanceCount   (repTargets instanceN)
///   rirSessionIndex  = position % rirSessionCount    (rirPlan sessionN)
/// When the two lengths are equal they coincide. When they differ, each still
/// cycles deterministically through its own list — the rep modulo never picks
/// the RIR session, and no missing key is ever relied upon. An unconfigured
/// list resolves to index 0.
///
/// Weekday position (`days % 7`) and calendar distance are never used.
library;

import 'periodization_model_utils.dart';

class ActiveInstance {
  const ActiveInstance({
    required this.exposurePosition,
    required this.repInstanceIndex,
    required this.rirSessionIndex,
  });

  /// 0-based count of prior exposures (unwrapped).
  final int exposurePosition;

  /// 0-based index into `repTargets.week1.instanceN` (N = index + 1).
  final int repInstanceIndex;

  /// 0-based index into `rirPlan.<week>.sessionN` (N = index + 1).
  final int rirSessionIndex;

  @override
  bool operator ==(Object other) =>
      other is ActiveInstance &&
      other.exposurePosition == exposurePosition &&
      other.repInstanceIndex == repInstanceIndex &&
      other.rirSessionIndex == rirSessionIndex;

  @override
  int get hashCode =>
      Object.hash(exposurePosition, repInstanceIndex, rirSessionIndex);

  @override
  String toString() => 'ActiveInstance(position=$exposurePosition, '
      'rep=$repInstanceIndex, rir=$rirSessionIndex)';
}

class ActiveInstanceResolver {
  ActiveInstanceResolver._();

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime? _parseDay(String ymd) {
    final DateTime? d = DateTime.tryParse(ymd.trim());
    return d == null ? null : _day(d);
  }

  /// yyyy-MM-dd of [d].
  static String dateKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// The exposure position of [selectedDate] (see the library doc).
  ///
  /// [completedDates] are yyyy-MM-dd dates with a valid performed set.
  /// [plannedDates] (BB3 only) are yyyy-MM-dd dates the exercise is planned
  /// on; they count only for a future selected date and only from [today].
  static int exposurePosition({
    required DateTime selectedDate,
    required Iterable<String> completedDates,
    Iterable<String> plannedDates = const <String>[],
    DateTime? today,
    DateTime? blockStartDate,
  }) {
    final DateTime sel = _day(selectedDate);
    final DateTime? start =
        blockStartDate == null ? null : _day(blockStartDate);
    final Set<DateTime> counted = <DateTime>{};

    bool inBlockBefore(DateTime d) =>
        d.isBefore(sel) && (start == null || !d.isBefore(start));

    for (final String ymd in completedDates) {
      final DateTime? d = _parseDay(ymd);
      if (d != null && inBlockBefore(d)) counted.add(d);
    }

    final DateTime t = _day(today ?? DateTime.now());
    if (sel.isAfter(t)) {
      for (final String ymd in plannedDates) {
        final DateTime? d = _parseDay(ymd);
        if (d != null && !d.isBefore(t) && inBlockBefore(d)) counted.add(d);
      }
    }
    return counted.length;
  }

  /// Rep slot and RIR session for [exposurePosition], each wrapped over its
  /// own configured length.
  static ActiveInstance resolve({
    required int exposurePosition,
    required int repInstanceCount,
    required int rirSessionCount,
  }) {
    final int p = exposurePosition < 0 ? 0 : exposurePosition;
    return ActiveInstance(
      exposurePosition: p,
      repInstanceIndex: repInstanceCount > 0 ? p % repInstanceCount : 0,
      rirSessionIndex: rirSessionCount > 0 ? p % rirSessionCount : 0,
    );
  }

  static int _contiguous(Object? map, String prefix) {
    if (map is! Map) return 0;
    int n = 0;
    while (map.containsKey('$prefix${n + 1}')) {
      n++;
    }
    return n;
  }

  /// Contiguous `instanceN` keys in `repTargets.week1`.
  static int repInstanceCount(Map<String, dynamic>? exSettings) {
    final Object? rt = exSettings?['repTargets'];
    return rt is Map ? _contiguous(rt['week1'], 'instance') : 0;
  }

  /// Contiguous `sessionN` keys in the RIR plan for [weekIndex] (0-based),
  /// falling back to `week1` — the same week selection as the RIR lookup.
  static int rirSessionCount(Map<String, dynamic>? exSettings,
      {int weekIndex = 0}) {
    final Object? plan = exSettings?['rirPlan'];
    if (plan is! Map) return 0;
    final String wk = 'week${weekIndex + 1}';
    return _contiguous(
        plan.containsKey(wk) ? plan[wk] : plan['week1'], 'session');
  }

  /// True for the models whose rep target and RIR follow block-wide exposure.
  static bool usesExposureInstance(Map<String, dynamic>? exSettings) {
    final Object? m = exSettings?['periodizationModel'];
    return m == 'DUP, By Exposure' || m == 'DUP, Signature';
  }

  /// Valid completed exposure dates of this exercise from the in-memory
  /// history index (the same source the progression engine uses).
  static Set<String> completedExposureDates({
    required String exerciseId,
    required String exerciseName,
  }) =>
      PeriodizationModelUtils.exposureDatesFor(
          exerciseId: exerciseId, exerciseName: exerciseName);

  /// The instance for [exSettings] at [exposurePosition].
  static ActiveInstance forSettings({
    required Map<String, dynamic>? exSettings,
    required int exposurePosition,
    int weekIndex = 0,
  }) =>
      resolve(
        exposurePosition: exposurePosition,
        repInstanceCount: repInstanceCount(exSettings),
        rirSessionCount: rirSessionCount(exSettings, weekIndex: weekIndex),
      );

  /// WES2's active instance: completed exposures only.
  static ActiveInstance forWes2({
    required String exerciseId,
    required String exerciseName,
    required Map<String, dynamic>? exSettings,
    required DateTime blockStartDate,
    required DateTime selectedDate,
    int weekIndex = 0,
  }) =>
      forSettings(
        exSettings: exSettings,
        weekIndex: weekIndex,
        exposurePosition: exposurePosition(
          selectedDate: selectedDate,
          completedDates: completedExposureDates(
              exerciseId: exerciseId, exerciseName: exerciseName),
          blockStartDate: blockStartDate,
        ),
      );
}
