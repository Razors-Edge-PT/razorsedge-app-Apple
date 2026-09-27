/// BB3's non-blocking gate on the viewed athlete's progression history.
///
/// Exposure-model hints (DUP, By Exposure / DUP, Signature) depend on the
/// athlete's complete progression history. BB3 never waits for it: the page
/// and its panels render at their normal time, and those rows simply show no
/// hint until the history is authoritative for THAT athlete. Hydration is
/// started (or joined) once per athlete in the background through
/// [ProgressionHistoryStore.ensureHydrated], which already de-duplicates
/// in-flight work with the app warmup and WES2 — so no extra Firestore read
/// is issued per row, per panel or per rebuild. When it completes, [ensure]'s
/// callback fires once so the caller can rebuild.
library;

import 'dart:async';

import 'periodization_model_utils.dart';
import 'progression_history_store.dart';

class Bb3HistoryGate {
  Bb3HistoryGate({
    bool Function(String uid)? isReady,
    Future<void> Function(String uid)? hydrate,
  })  : _isReady = isReady ?? defaultIsReady,
        _hydrate = hydrate ??
            ((String uid) =>
                ProgressionHistoryStore.instance.ensureHydrated(uid: uid));

  final bool Function(String uid) _isReady;
  final Future<void> Function(String uid) _hydrate;
  final Set<String> _requested = <String>{};

  /// Authoritative history exists for [uid] AND is the history currently
  /// published for hint computation (a coach viewing an athlete needs the
  /// athlete's, not their own).
  static bool defaultIsReady(String uid) =>
      uid.isNotEmpty &&
      (ProgressionHistoryStore.instance.snapshotFor(uid)?.authoritative ??
          false) &&
      PeriodizationModelUtils.historyUid == uid;

  bool isReady(String uid) => _isReady(uid);

  /// Starts or joins ONE background hydration for [uid] — never awaited by
  /// the caller. [onReady] runs once, after it completes with [uid]'s history
  /// ready. A failed hydration may be retried by a later [ensure] call; the
  /// hints stay withheld meanwhile (never guessed).
  void ensure(String uid, void Function() onReady) {
    if (uid.isEmpty || _requested.contains(uid) || _isReady(uid)) return;
    _requested.add(uid);
    unawaited(_hydrate(uid).then((_) {
      if (_isReady(uid)) onReady();
    }, onError: (Object _) {
      _requested.remove(uid);
    }));
  }
}
