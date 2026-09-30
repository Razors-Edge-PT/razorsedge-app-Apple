/// The exercise voice commands act on in WES2 ("set one weight 50" goes to it).
///
/// Session-local and in memory only: it is not part of the workout, is never
/// saved, and changes nothing about the rows. Order is the workout's own
/// logical order (the controller's rows, as the screen lists them).
library;

class Wes2VoiceTarget {
  String? _exerciseId;

  String? get exerciseId => _exerciseId;

  /// The target among [rowIds]: the chosen one while it is still in the
  /// workout, otherwise the first exercise (null for an empty workout).
  String? resolve(List<String> rowIds) {
    if (rowIds.isEmpty) return null;
    final String? current = _exerciseId;
    if (current != null && rowIds.contains(current)) return current;
    _exerciseId = rowIds.first;
    return _exerciseId;
  }

  void select(String exerciseId) => _exerciseId = exerciseId;

  /// Moves to the next exercise; null when already on the last (target unchanged).
  String? next(List<String> rowIds) => _step(rowIds, 1);

  /// Moves to the previous exercise; null when already on the first.
  String? previous(List<String> rowIds) => _step(rowIds, -1);

  String? _step(List<String> rowIds, int delta) {
    final String? current = resolve(rowIds);
    if (current == null) return null;
    final int i = rowIds.indexOf(current) + delta;
    if (i < 0 || i >= rowIds.length) return null;
    _exerciseId = rowIds[i];
    return _exerciseId;
  }
}
