/// "Show me THAT one" — for a destination that is already open.
///
/// ── Why this exists ─────────────────────────────────────────────────────────
/// Two alerts can point at the same screen but at different things: two
/// comments on one post, two reactions to different messages in one
/// conversation. Routing used to give up whenever the post or the chat was
/// already open, on the grounds that a second copy would only bury the first.
/// True — but the tap was not asking for a second copy, it was asking to be
/// shown a particular comment or message, and dropping it left the person
/// looking at a screen that had not moved.
///
/// So the router publishes a focus request instead of navigating, and the open
/// page reveals the target itself. One request at a time, newest wins, with a
/// timestamp so an identical target asked for twice is still a new request.
library;

import 'package:flutter/foundation.dart';

@immutable
class FocusRequest {
  const FocusRequest({
    required this.subjectId,
    required this.targetId,
    required this.at,
  });

  /// The post id or conversation id the open page is showing.
  final String subjectId;

  /// The comment or message to reveal.
  final String targetId;

  final DateTime at;

  /// True when [subjectId] names this page and there is something to reveal.
  bool isFor(String subject) => subjectId == subject && targetId.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is FocusRequest &&
      other.subjectId == subjectId &&
      other.targetId == targetId &&
      other.at == at;

  @override
  int get hashCode => Object.hash(subjectId, targetId, at);
}

class ForegroundFocus {
  ForegroundFocus._();

  /// The most recent request. Pages listen; nothing else writes it.
  static final ValueNotifier<FocusRequest?> requests =
      ValueNotifier<FocusRequest?>(null);

  /// Asks whichever page is showing [subjectId] to reveal [targetId].
  static void request({
    required String subjectId,
    required String targetId,
    DateTime? at,
  }) {
    if (subjectId.isEmpty || targetId.isEmpty) return;
    requests.value = FocusRequest(
      subjectId: subjectId,
      targetId: targetId,
      at: at ?? DateTime.now(),
    );
  }

  @visibleForTesting
  static void reset() => requests.value = null;
}
