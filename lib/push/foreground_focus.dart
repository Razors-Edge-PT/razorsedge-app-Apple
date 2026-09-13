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
/// page reveals the target itself.
///
/// ── What a request has to carry ─────────────────────────────────────────────
/// A subject and a target were not enough.
///
///   * The RECORD. An alert names the interaction it is about, and that is the
///     only way to read and clear an interaction sitting outside every query
///     window. A request that carried only "scroll to comment c17" revealed
///     the comment and left its badge and its alert exactly where they were.
///   * The ACCOUNT it was addressed to, so a request left over from the
///     previous account cannot act on the new one's screen.
///   * A SERIAL. Requests are not values to be de-duplicated: asking twice for
///     the message you have since scrolled away from is a second, meaningful
///     ask. The serial rises with every request, so a page can tell a repeat
///     from a stale rebuild, and an async lookup that returns late can tell
///     that a newer request has overtaken it.
///
/// A target is optional: a like or a Good Lift has nothing to scroll to — the
/// post is already showing it — but it still has a record to acknowledge.
library;

import 'package:flutter/foundation.dart';

@immutable
class FocusRequest {
  const FocusRequest({
    required this.subjectId,
    required this.serial,
    required this.at,
    this.targetId,
    this.activityId,
    this.recipientUid,
  });

  /// The post id or conversation id the open page is showing.
  final String subjectId;

  /// The comment or message to reveal, when there is one.
  final String? targetId;

  /// The activity record this tap was about, to be read and cleared.
  final String? activityId;

  /// The account the alert was addressed to, or null when it was not said.
  final String? recipientUid;

  /// Rises with every request ever made.
  final int serial;

  final DateTime at;

  /// True when this names the given page and asks for something.
  bool isFor(String subject) =>
      subjectId == subject &&
      ((targetId != null && targetId!.isNotEmpty) ||
          (activityId != null && activityId!.isNotEmpty));

  /// True when this request belongs to [uid] — or did not say who it was for.
  bool isForAccount(String? uid) =>
      recipientUid == null || uid == null || recipientUid == uid;

  @override
  bool operator ==(Object other) =>
      other is FocusRequest &&
      other.subjectId == subjectId &&
      other.targetId == targetId &&
      other.activityId == activityId &&
      other.recipientUid == recipientUid &&
      other.serial == serial &&
      other.at == at;

  @override
  int get hashCode =>
      Object.hash(subjectId, targetId, activityId, recipientUid, serial, at);
}

/// Should the page showing [subjectId] act on [req]?
///
/// The rule both open destinations use, in one place because both got it
/// wrong in the same way: they compared the TARGET, so a second tap on the
/// alert you had scrolled away from was discarded as a duplicate for ever.
/// The serial settles it instead — every request has a higher one than the
/// last, so a repeat is acted on and a rebuild replaying the current value is
/// not — and a request addressed to another account is never acted on at all.
bool shouldActOnFocus({
  required FocusRequest? req,
  required String subjectId,
  required int lastSerial,
  String? viewerUid,
}) {
  if (req == null) return false;
  if (!req.isFor(subjectId)) return false;
  if (req.serial <= lastSerial) return false;
  return req.isForAccount(viewerUid);
}

class ForegroundFocus {
  ForegroundFocus._();

  /// The most recent request. Pages listen; nothing else writes it.
  static final ValueNotifier<FocusRequest?> requests =
      ValueNotifier<FocusRequest?>(null);

  static int _serial = 0;

  /// Asks whichever page is showing [subjectId] to reveal [targetId] and to
  /// deal with [activityId]. Returns false when there is nothing to ask for.
  static bool request({
    required String subjectId,
    String? targetId,
    String? activityId,
    String? recipientUid,
    DateTime? at,
  }) {
    final bool hasTarget = targetId != null && targetId.isNotEmpty;
    final bool hasRecord = activityId != null && activityId.isNotEmpty;
    if (subjectId.isEmpty || (!hasTarget && !hasRecord)) return false;
    _serial++;
    requests.value = FocusRequest(
      subjectId: subjectId,
      targetId: hasTarget ? targetId : null,
      activityId: hasRecord ? activityId : null,
      recipientUid: recipientUid,
      serial: _serial,
      at: at ?? DateTime.now(),
    );
    return true;
  }

  @visibleForTesting
  static void reset() {
    requests.value = null;
    _serial = 0;
  }
}
