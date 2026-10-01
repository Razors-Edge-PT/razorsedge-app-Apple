/// Lets Aurelian drive a timed set's stopwatch (plank) without new timer
/// semantics: each mounted timed cell registers its own start/stop/cancel, so a
/// voice "begin plank set one timer" runs exactly what a tap on the cell runs,
/// and a voice stop saves the time through the cell's own stop path
/// (onChanged + onUnfocused → the durable outbox).
///
/// Session-local and in memory only. Only cells that are on screen are
/// registered (the workout list builds lazily), so callers scroll the exercise
/// into view first.
library;

class Wes2SetTimerHandle {
  const Wes2SetTimerHandle({
    required this.isRunning,
    required this.start,
    required this.stop,
    required this.cancel,
  });

  final bool Function() isRunning;

  /// Starts (or resumes) the stopwatch, exactly as tapping the cell does.
  final void Function() start;

  /// Stops it and saves the time, exactly as tapping a running cell does.
  final void Function() stop;

  /// Stops it WITHOUT saving: the display returns to the stored value.
  final void Function() cancel;
}

class Wes2SetTimerHub {
  Wes2SetTimerHub._();

  static final Wes2SetTimerHub instance = Wes2SetTimerHub._();

  final Map<String, Wes2SetTimerHandle> _cells = <String, Wes2SetTimerHandle>{};

  static String keyFor(String exerciseId, int setIndex) =>
      '$exerciseId#$setIndex';

  void register(String key, Wes2SetTimerHandle handle) => _cells[key] = handle;

  /// Removes [handle] only if it is still the one registered for [key] (a
  /// rebuilt cell may already have replaced it).
  void unregister(String key, Wes2SetTimerHandle handle) {
    if (identical(_cells[key], handle)) _cells.remove(key);
  }

  bool isMounted(String key) => _cells.containsKey(key);

  /// The running cell's key, if any.
  String? get runningKey {
    for (final MapEntry<String, Wes2SetTimerHandle> e in _cells.entries) {
      if (e.value.isRunning()) return e.key;
    }
    return null;
  }

  bool start(String key) {
    final Wes2SetTimerHandle? h = _cells[key];
    if (h == null) return false;
    if (!h.isRunning()) h.start();
    return h.isRunning();
  }

  bool stop(String key) {
    final Wes2SetTimerHandle? h = _cells[key];
    if (h == null || !h.isRunning()) return false;
    h.stop();
    return !h.isRunning();
  }

  bool cancel(String key) {
    final Wes2SetTimerHandle? h = _cells[key];
    if (h == null) return false;
    h.cancel();
    return !h.isRunning();
  }
}
