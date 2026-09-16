/// Loads everything a hint pass needs, then applies it exactly once.
///
/// ── Why this is its own object ──────────────────────────────────────────────
/// The pass awaits four things in turn — history, exercise settings, missing
/// defaults, exercise types — and each await is a chance for the athlete to
/// change date, switch athlete, reload, or save new settings. The old inline
/// version checked `mounted` in places and identity in none of the ones that
/// mattered: an older pass could still install its settings into the cache,
/// register its service and apply its hints over the day now on screen.
///
/// Here every await is followed by the same question — "is this still the
/// current pass?" — and the answer is also required BEFORE the two writes that
/// outlive the pass (the settings cache and the controller application).
library;

import 'package:flutter/foundation.dart';

import 'WES2_controller.dart';
import 'WES2_hint_service.dart';
import 'WES2_models.dart';
import 'WES2_plan_service.dart';
import 'wes2_hint_trace.dart';

/// Identity of one pass. A pass whose token no longer matches the controller
/// is stale and must not touch anything.
@immutable
class Wes2HintPassToken {
  const Wes2HintPassToken({
    required this.actingUid,
    required this.date,
    required this.blockId,
    required this.loadEpoch,
    required this.settingsGeneration,
  });

  final String actingUid;
  final DateTime date;
  final String blockId;
  final int loadEpoch;
  final int settingsGeneration;

  @override
  bool operator ==(Object other) =>
      other is Wes2HintPassToken &&
      other.actingUid == actingUid &&
      other.date == date &&
      other.blockId == blockId &&
      other.loadEpoch == loadEpoch &&
      other.settingsGeneration == settingsGeneration;

  @override
  int get hashCode =>
      Object.hash(actingUid, date, blockId, loadEpoch, settingsGeneration);

  @override
  String toString() => '$actingUid/${date.toIso8601String().substring(0, 10)}/'
      '$blockId/e$loadEpoch/s$settingsGeneration';
}

/// What one pass did, for tracing and tests.
enum Wes2HintPassOutcome {
  applied,
  noBlock,
  superseded,
  disposed,
  failed,
}

class Wes2HintLoadRunner {
  Wes2HintLoadRunner({
    required Wes2SessionController controller,
    required Wes2PlanService planService,
    required Future<void> Function(String exerciseId, String blockId)
        ensureExerciseDefaults,
    required bool Function(Map<String, dynamic>? settings) isSettingsUsable,
    Future<void> Function()? refreshHistory,
  })  : _controller = controller,
        _planService = planService,
        _ensureExerciseDefaults = ensureExerciseDefaults,
        _isSettingsUsable = isSettingsUsable,
        _refreshHistory = refreshHistory;

  final Wes2SessionController _controller;
  final Wes2PlanService _planService;
  final Future<void> Function(String exerciseId, String blockId)
      _ensureExerciseDefaults;
  final bool Function(Map<String, dynamic>? settings) _isSettingsUsable;
  final Future<void> Function()? _refreshHistory;

  Map<String, dynamic> _settings = const <String, dynamic>{};
  Map<String, String> _types = const <String, String>{};
  String? _settingsKey;
  int _settingsGeneration = 0;
  bool _disposed = false;

  /// Orders passes that share an identity token. Two passes started within the
  /// same load epoch and settings generation are indistinguishable by token
  /// alone, so the older one could still finish last and overwrite the newer
  /// one's settings.
  int _requestSeq = 0;

  /// The settings this runner has installed. The screen reads these for the
  /// settings sheet; they are only ever replaced by a current pass.
  Map<String, dynamic> get settings => _settings;
  Map<String, String> get exerciseTypes => _types;
  String? get settingsKey => _settingsKey;
  int get settingsGeneration => _settingsGeneration;

  /// Invalidates the settings cache and supersedes every pass in flight.
  ///
  /// Called BEFORE awaiting a settings save, so a response that was already on
  /// its way cannot reinstate what the athlete just changed.
  void invalidateSettings() {
    _settingsKey = null;
    _settingsGeneration++;
  }

  void dispose() => _disposed = true;

  Wes2HintPassToken? currentToken() {
    final String? blockId = _controller.activeBlockId;
    if (blockId == null || blockId.isEmpty) return null;
    return Wes2HintPassToken(
      actingUid: _controller.actingUid,
      date: _controller.selectedDate,
      blockId: blockId,
      loadEpoch: _controller.loadEpoch,
      settingsGeneration: _settingsGeneration,
    );
  }

  /// Runs one pass. Returns what it did, so callers and tests do not have to
  /// infer it from side effects.
  Future<Wes2HintPassOutcome> run() async {
    if (_disposed) return Wes2HintPassOutcome.disposed;
    final int request = ++_requestSeq;
    final Wes2HintPassToken? token = currentToken();
    final DateTime? blockStart = _controller.blockStartDate;
    if (token == null || blockStart == null) {
      if (Wes2HintTrace.enabled) {
        Wes2HintTrace.log('hints', 'abort: no block context');
      }
      return Wes2HintPassOutcome.noBlock;
    }

    bool current() =>
        !_disposed && currentToken() == token && _requestSeq == request;

    if (Wes2HintTrace.enabled) {
      Wes2HintTrace.log('hints', 'start $token');
    }

    try {
      final Future<void> Function()? refresh = _refreshHistory;
      if (refresh != null) {
        try {
          await refresh();
        } catch (e) {
          // History hydration is best effort: offline, or with the store
          // unavailable, the pass still computes hints from plan and settings.
          debugPrint('[WES2] history refresh failed: $e');
        }
        if (!current()) return _superseded(token);
      }

      // ── Settings ────────────────────────────────────────────────────────
      final String key = '${token.actingUid}|${token.blockId}';
      if (_settingsKey != key) {
        final Map<String, dynamic> loaded = await _planService
            .loadExerciseSettings(uid: token.actingUid, blockId: token.blockId);
        // Guarded BEFORE the cache write: a late response from an older pass
        // must never replace settings a newer pass already installed.
        if (!current()) return _superseded(token);
        _settings = loaded;
        _settingsKey = key;
        _controller.setExerciseSettings(_settings);
      }

      // ── Defaults for exercises that have none ───────────────────────────
      final Set<String> missing = _controller.rows
          .map((Wes2ExerciseRow r) => r.exerciseId)
          .where((String id) =>
              id.isNotEmpty &&
              !_isSettingsUsable(_settings[id] is Map<String, dynamic>
                  ? _settings[id] as Map<String, dynamic>
                  : null))
          .toSet();
      if (missing.isNotEmpty) {
        for (final String id in missing) {
          try {
            await _ensureExerciseDefaults(id, token.blockId);
          } catch (e) {
            debugPrint('[WES2] ensureDefaults failed for $id: $e');
          }
          if (!current()) return _superseded(token);
        }
        final Map<String, dynamic> reloaded = await _planService
            .loadExerciseSettings(uid: token.actingUid, blockId: token.blockId);
        if (!current()) return _superseded(token);
        _settings = reloaded;
        _controller.setExerciseSettings(_settings);
      }

      // ── Exercise types (only for ids we have not seen) ──────────────────
      final List<String> uncached = _controller.rows
          .map((Wes2ExerciseRow r) => r.exerciseId)
          .where((String id) => !_types.containsKey(id))
          .toSet()
          .toList();
      if (uncached.isNotEmpty) {
        try {
          final Map<String, String> fetched = await _planService
              .loadExerciseTypes(uncached, uid: token.actingUid);
          if (!current()) return _superseded(token);
          _types = <String, String>{..._types, ...fetched};
        } catch (_) {
          // Type information is an enhancement; hints work without it.
          if (!current()) return _superseded(token);
        }
      }

      // ── Application ─────────────────────────────────────────────────────
      if (!current()) return _superseded(token);
      _controller.applyHintContext(
        Wes2HintServiceImpl(
          exerciseSettings: _settings,
          exerciseTypes: _types,
          blockStartDate: blockStart,
          blockEndDate: _controller.blockEndDate,
          uid: token.actingUid,
        ),
        token.blockId,
      );
      if (Wes2HintTrace.enabled) {
        Wes2HintTrace.log('hints', 'applied $token');
      }
      return Wes2HintPassOutcome.applied;
    } catch (e) {
      debugPrint('[WES2] Hint computation failed: $e');
      if (Wes2HintTrace.enabled) {
        Wes2HintTrace.log('hints', '❌ hint pass failed: $e');
      }
      return Wes2HintPassOutcome.failed;
    }
  }

  Wes2HintPassOutcome _superseded(Wes2HintPassToken token) {
    if (Wes2HintTrace.enabled) {
      Wes2HintTrace.log(
          'hints', '⚠️ discarded superseded pass $token (now ${currentToken()})');
    }
    return _disposed
        ? Wes2HintPassOutcome.disposed
        : Wes2HintPassOutcome.superseded;
  }
}
