// WES2 hint debug trace — Phase: intermittent hint-bug instrumentation.
//
// PURPOSE: capture enough evidence in the field to distinguish, when a hint
// goes wrong, between:
//   A. race — user edits before the initial hint pass / baseline capture
//   B. stale async hint pass (old date/athlete/block) applied to visible rows
//   C. history key mismatch (Top Sets finds by name, hints look up by id)
//   D. BB3HintService returned empty → plan/default fallback (e.g. 5 kg)
//   E. history refresh silently failed or skipped by the refresh key
//   F. baseline captured AFTER the user typed (actuals baked into baseline)
//
// ZERO release impact: [Wes2HintTrace.enabled] is a compile-time constant
// (kDebugMode && kWes2HintTrace); in release builds every
// `if (Wes2HintTrace.enabled)` block is dead code and is tree-shaken.
// Flip [kWes2HintTrace] to false to silence the trace in debug builds too.
//
// This file adds logging and a copyable snapshot ONLY — it never changes
// hint computation or persisted data.

import 'package:flutter/foundation.dart';

import 'WES2_models.dart';

/// Master switch. Only effective in debug builds (see [Wes2HintTrace.enabled]).
// ignore: constant_identifier_names
const bool WES2_HINT_TRACE = true;

class Wes2HintTrace {
  Wes2HintTrace._();

  /// Compile-time gate: const so release builds tree-shake all trace blocks.
  static const bool enabled = kDebugMode && WES2_HINT_TRACE;

  static const int _cap = 800;

  // Ring buffer of (time, tag, exerciseId?, message).
  static final List<_Wes2TraceEvent> _events = <_Wes2TraceEvent>[];

  /// Record one event. [exerciseId] enables per-exercise filtering in the
  /// snapshot. Also mirrors to debugPrint with a greppable [W2HT] prefix.
  static void log(String tag, String message, {String? exerciseId}) {
    if (!enabled) return;
    final ev = _Wes2TraceEvent(
      at: DateTime.now(),
      tag: tag,
      exerciseId: exerciseId,
      message: message,
    );
    _events.add(ev);
    if (_events.length > _cap) {
      _events.removeRange(0, _events.length - _cap);
    }
    debugPrint('[W2HT][$tag] ${exerciseId != null ? '($exerciseId) ' : ''}'
        '$message');
  }

  /// Last [n] events, optionally filtered to one exerciseId (events logged
  /// without an exerciseId are excluded when a filter is given).
  static List<String> tail({int n = 100, String? exerciseId}) {
    final src = exerciseId == null
        ? _events
        : _events.where((e) => e.exerciseId == exerciseId).toList();
    final start = src.length > n ? src.length - n : 0;
    return [for (var i = start; i < src.length; i++) src[i].format()];
  }

  static int get eventCount => _events.length;

  static void clear() => _events.clear();

  // ── Compact formatters for models ─────────────────────────────────────────

  /// `a=<actual> h=<hint> o=<origin> ho=<hintOrigin>` with '-' for null.
  static String fmtField<T extends Object>(Wes2FieldState<T> f) =>
      'a=${f.actualValue ?? '-'} h=${f.hintValue ?? '-'} '
      'o=${f.origin.name} ho=${f.hintOrigin.name}';

  /// One-line set summary: 'S0 w[a=30 h=30 …] r[…] rir[…]'.
  static String fmtSet(Wes2SetState s) =>
      'S${s.setIndex} w[${fmtField(s.weight)}] r[${fmtField(s.reps)}] '
      'rir[${fmtField(s.rir)}]';

  /// Multi-set row summary on one line.
  static String fmtRow(Wes2ExerciseRow r) =>
      '"${r.name}" id=${r.exerciseId} src=${r.source.name} '
      'setCount=${r.setCount} sets={${r.sets.map(fmtSet).join(' | ')}}';

  /// True when any set of [r] carries a user actual (weight/reps/rir/velocity).
  static bool rowHasActuals(Wes2ExerciseRow r) =>
      r.sets.any((s) => s.hasAnyActual);
}

class _Wes2TraceEvent {
  final DateTime at;
  final String tag;
  final String? exerciseId;
  final String message;

  const _Wes2TraceEvent({
    required this.at,
    required this.tag,
    this.exerciseId,
    required this.message,
  });

  String format() {
    String two(int v) => v.toString().padLeft(2, '0');
    final t = '${two(at.hour)}:${two(at.minute)}:${two(at.second)}.'
        '${at.millisecond.toString().padLeft(3, '0')}';
    return '$t [$tag]${exerciseId != null ? ' ($exerciseId)' : ''} $message';
  }
}
