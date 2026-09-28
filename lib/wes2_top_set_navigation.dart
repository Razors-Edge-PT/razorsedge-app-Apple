import 'WES2_models.dart';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// A Top Sets target is valid only when the exact day finished loading and its
/// source workout still contains the selected exercise. Planned or local-only
/// rows must not masquerade as the historical workout the athlete tapped.
bool wes2TopSetTargetIsLoaded({
  required DateTime selectedDate,
  required DateTime targetDate,
  required String exerciseId,
  required Iterable<Wes2ExerciseRow> rows,
  required bool serverLoadConfirmed,
}) {
  if (!serverLoadConfirmed || !_sameDay(selectedDate, targetDate)) return false;
  return rows.any(
    (Wes2ExerciseRow row) =>
        row.exerciseId == exerciseId &&
        row.source == Wes2RowSource.completedServer,
  );
}
