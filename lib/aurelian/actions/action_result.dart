/// Structured results of Aurelian actions (envelope schema v1).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'action_envelope.dart';

/// Largest result JSON sent back over the bridge.
const int kAurelianMaxResult = 4096;
const int kActionMaxSummary = 200;
const int kActionMaxCandidates = 8;

enum ActionStatus {
  success('success'),

  /// Nothing ran: say yes (resend with the confirmation token) to go ahead.
  requiresConfirmation('requires_confirmation'),

  /// Several credible matches: ask which (resend with `choices`).
  ambiguous('ambiguous'),
  notFound('not_found'),
  invalid('invalid'),
  unauthorized('unauthorized'),

  /// The state changed under us (undo after a later edit, a reused key with a
  /// different request): nothing ran.
  conflict('conflict'),

  /// GoodLift has no such operation (renaming circuits, for example).
  unsupported('unsupported'),
  failure('failure');

  const ActionStatus(this.wire);
  final String wire;
}

@immutable
class AurelianActionResult {
  const AurelianActionResult(
    this.status,
    this.summary, {
    this.data = const <String, Object?>{},
    this.candidates = const <String>[],
    this.undoToken,
    this.confirmationToken,
    this.verified = false,
  });

  const AurelianActionResult.invalid(String summary)
      : this(ActionStatus.invalid, summary);
  const AurelianActionResult.notFound(String summary)
      : this(ActionStatus.notFound, summary);
  const AurelianActionResult.unauthorized(String summary)
      : this(ActionStatus.unauthorized, summary);
  const AurelianActionResult.conflict(String summary)
      : this(ActionStatus.conflict, summary);
  const AurelianActionResult.unsupported(String summary)
      : this(ActionStatus.unsupported, summary);
  const AurelianActionResult.failure(String summary)
      : this(ActionStatus.failure, summary);

  factory AurelianActionResult.ambiguous(
          String summary, Iterable<String> candidates) =>
      AurelianActionResult(ActionStatus.ambiguous, summary,
          candidates: candidates.take(kActionMaxCandidates).toList());

  final ActionStatus status;

  /// Short, user-facing ("Bench Press, Barbell · set 1: 150 kg · 5 reps").
  final String summary;

  /// Read-back of the resulting state (no ids, no tokens).
  final Map<String, Object?> data;
  final List<String> candidates;
  final String? undoToken;
  final String? confirmationToken;

  /// True only when the state was read back after the change and matched.
  final bool verified;

  bool get isSuccess => status == ActionStatus.success;

  AurelianActionResult withUndo(String? token) =>
      AurelianActionResult(status, summary,
          data: data,
          candidates: candidates,
          undoToken: token,
          confirmationToken: confirmationToken,
          verified: verified);

  Map<String, Object?> toJson(String requestId) {
    String clip(String s, int n) => s.length > n ? s.substring(0, n) : s;
    final Map<String, Object?> out = <String, Object?>{
      'schemaVersion': kAurelianActionSchemaVersion,
      'requestId': requestId,
      'status': status.wire,
      'summary': clip(summary, kActionMaxSummary),
      'verified': verified,
      if (data.isNotEmpty) 'data': data,
      if (candidates.isNotEmpty)
        'candidates': candidates
            .take(kActionMaxCandidates)
            .map((String c) => clip(c, kActionMaxName))
            .toList(),
      if (undoToken != null) 'undoToken': undoToken,
      if (confirmationToken != null) 'confirmationToken': confirmationToken,
    };
    return out;
  }

  /// The JSON text for the bridge, bounded: oversized read-back data is dropped
  /// rather than truncated mid-structure.
  String encode(String requestId) {
    final Map<String, Object?> full = toJson(requestId);
    final String text = jsonEncode(full);
    if (text.length <= kAurelianMaxResult) return text;
    full.remove('data');
    full['dataOmitted'] = true;
    return jsonEncode(full);
  }

  @override
  String toString() => 'AurelianActionResult(${status.wire}: $summary)';
}
