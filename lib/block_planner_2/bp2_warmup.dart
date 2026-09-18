/// Non-blocking Block Planner 2 cache warm-up.
///
/// Called from `UserContext.refreshBlockMetaInBackground` — i.e. once after
/// login for the signed-in athlete and once per athlete switch in coach mode.
/// It only downloads what is not cached yet for THAT uid (shared catalogue,
/// the athlete's custom exercises, templates and block summaries) and never
/// throws, so login/home rendering is never blocked or broken by it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'bp2_cache.dart';
import 'bp2_repository.dart';
import 'bp2_sync_service.dart';

class Bp2Warmup {
  Bp2Warmup._();
  static final Bp2Warmup instance = Bp2Warmup._();

  Bp2SyncService? _sync;
  final Set<String> _warmedThisProcess = {};

  /// Lazily built production wiring shared with the screen.
  Bp2SyncService get sync => _sync ??= Bp2SyncService(
        repo: Bp2Repository(),
        cache: Bp2IsarCacheStore(),
      );

  void warm(String uid) {
    if (uid.isEmpty || _warmedThisProcess.contains(uid)) return;
    _warmedThisProcess.add(uid);
    unawaited(() async {
      try {
        await sync.warm(uid);
      } catch (e) {
        _warmedThisProcess.remove(uid);
        debugPrint('[BP2] warm-up skipped for $uid: $e');
      }
    }());
  }
}
