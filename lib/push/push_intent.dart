/// Push notifications — the pure client model. No Firebase, no widgets.
///
/// Exactly three notifications exist (see functions/push/push_model.js):
/// an incoming friend request, a friend request accepted, and a direct
/// message. This file decides what a received notification MEANS, whether it
/// may be shown or opened for the account signed in on this device, and what
/// the account's preferences are. Everything here is deterministic and is
/// covered by test/push_notifications_test.dart.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

enum PushKind { friendRequest, friendAccepted, directMessage }

/// OS permission for notifications on this device, independent of plugin
/// types so the decisions below stay testable.
enum PushPermission { notDetermined, denied, granted, provisional }

extension PushPermissionX on PushPermission {
  /// Whether the OS will display what we send.
  bool get allowsDelivery =>
      this == PushPermission.granted || this == PushPermission.provisional;
}

enum PushOsPlatform { android, ios, other }

/// What the permission rules need to know about this device.
///
/// Android 13 (API 33) introduced the runtime POST_NOTIFICATIONS prompt, and
/// on 13+ Firebase reports `denied` BOTH before the prompt has ever been shown
/// and after the person refused it — it is up to the app to remember whether
/// it asked (see resolvePushPermission). Android 12 and earlier have no prompt
/// at all: notifications are on unless switched off in system settings. iOS
/// reports `notDetermined` until asked.
class PushPlatformInfo {
  const PushPlatformInfo({required this.platform, this.androidSdkInt = 0});

  const PushPlatformInfo.android(int sdkInt)
      : platform = PushOsPlatform.android,
        androidSdkInt = sdkInt;

  const PushPlatformInfo.ios()
      : platform = PushOsPlatform.ios,
        androidSdkInt = 0;

  final PushOsPlatform platform;
  final int androidSdkInt;

  /// Android 13+ — where "denied" is ambiguous until the app has asked.
  bool get hasAmbiguousDenied =>
      platform == PushOsPlatform.android && androidSdkInt >= 33;
}

/// The conversation id both participants derive: the two uids, sorted, joined
/// by `_`. Mirrors `convIdFor` in directMessages.dart and the server.
String conversationIdFor(String a, String b) {
  final List<String> pair = <String>[a, b]..sort();
  return '${pair[0]}_${pair[1]}';
}

/// Registration document id for [token]: lowercase hex SHA-256. The Firestore
/// rules bind `pushDevices/{id}` to its token by this hash, so a token has
/// exactly one owning account.
String pushDeviceIdForToken(String token) =>
    sha256.convert(utf8.encode(token)).toString();

// ── Notification tags ───────────────────────────────────────────────────────
// The OS keeps a delivered notification's tag (Android) / identifier (iOS),
// and that is ALL the app has to go on for an alert the system posted while
// Dart was not running. These mirror presentationTag() in
// functions/push/push_model.js exactly.

/// Short key for a conversation inside a notification tag (the server hashes
/// because an APNs collapse id is capped at 64 bytes).
String dmConversationTagKey(String convId) =>
    sha256.convert(utf8.encode(convId)).toString().substring(0, 8);

/// Every alert for one conversation starts with this.
String dmConversationTagPrefix(String convId) =>
    'dm|${dmConversationTagKey(convId)}|';

/// The tag one message's alert carries.
String dmMessageTag({required String convId, required String messageId}) =>
    '${dmConversationTagPrefix(convId)}$messageId';

/// Alerts sent by builds before the conversation-scoped tag existed. They can
/// still be cancelled when the message id is known.
String dmLegacyMessageTag(String messageId) => 'dm_$messageId';

String friendRequestTag(String actorUid) => 'fr_$actorUid';

String friendAcceptedTag(String actorUid) => 'fa_$actorUid';

/// What a tapped (or foreground-received) notification asks the app to open.
class PushIntent {
  const PushIntent({
    required this.kind,
    required this.recipientUid,
    required this.actorUid,
    required this.receivedAt,
    this.convId,
    this.messageId,
    this.incomingSeq,
  });

  final PushKind kind;

  /// The account the notification was addressed to. Never acted on unless it
  /// is the account signed in here — the app does not switch accounts.
  final String recipientUid;

  /// Who sent the request / accepted it / sent the message.
  final String actorUid;

  /// Direct messages only: the exact conversation.
  final String? convId;

  /// Direct messages only, and only from 1.7.24 onwards: which message this
  /// alert is about, and its position in the recipient's unread ledger. Used
  /// to cancel exactly this alert and to drop a banner for a message already
  /// read. Older payloads have neither.
  final String? messageId;
  final int? incomingSeq;

  final DateTime receivedAt;

  /// Parses the routing data the server attaches. Returns null for anything
  /// that is not one of the three notifications or is internally
  /// inconsistent — a self-addressed notification, or a conversation id that
  /// is not this exact pair.
  static PushIntent? fromData(Map<String, dynamic> data, {DateTime? now}) {
    String? s(String key) {
      final Object? v = data[key];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    final PushKind? kind = switch (s('type')) {
      'friendRequest' => PushKind.friendRequest,
      'friendAccepted' => PushKind.friendAccepted,
      'directMessage' => PushKind.directMessage,
      _ => null,
    };
    final String? recipient = s('recipientUid');
    final String? actor = s('actorUid');
    if (kind == null || recipient == null || actor == null) return null;
    if (recipient == actor) return null;

    String? convId;
    if (kind == PushKind.directMessage) {
      convId = s('convId');
      if (convId == null || convId != conversationIdFor(recipient, actor)) {
        return null;
      }
    }
    return PushIntent(
      kind: kind,
      recipientUid: recipient,
      actorUid: actor,
      convId: convId,
      messageId: s('msgId'),
      incomingSeq: int.tryParse(s('seq') ?? ''),
      receivedAt: now ?? DateTime.now(),
    );
  }
}

/// What to do with a pending tap right now.
enum PushDispatch {
  /// Auth not restored yet, membership gate not passed, or no navigator yet.
  wait,

  /// Everything is ready: navigate.
  open,

  /// Addressed to an account that is not the one signed in here.
  dropOtherAccount,

  /// Waited too long for the app to become ready; forget it.
  dropExpired,
}

/// How long a tap may wait for startup (auth restoration, membership check).
const Duration kPushTapMaxWait = Duration(minutes: 2);

PushDispatch decideDispatch({
  required PushIntent intent,
  required String? currentUid,
  required bool uiReady,
  required DateTime now,
  Duration maxWait = kPushTapMaxWait,
}) {
  if (now.difference(intent.receivedAt) > maxWait) {
    return PushDispatch.dropExpired;
  }
  // A signed-out phone (restoring, or explicitly logged out) keeps waiting;
  // the intent expires rather than ever opening for someone else.
  if (currentUid == null) return PushDispatch.wait;
  if (currentUid != intent.recipientUid) return PushDispatch.dropOtherAccount;
  if (!uiReady) return PushDispatch.wait;
  return PushDispatch.open;
}

/// Whether a notification received while the app is in the foreground should
/// show the in-app banner.
///
/// Never for another account. Never for a message in the conversation the
/// person is actually looking at — "actually" meaning the app is resumed and
/// that conversation is the visible route, not merely mounted underneath
/// something else.
bool shouldShowForegroundBanner({
  required PushIntent intent,
  required String? currentUid,
  required String? visibleConvId,
  required bool appResumed,
}) {
  if (currentUid == null || currentUid != intent.recipientUid) return false;
  if (intent.kind == PushKind.directMessage &&
      appResumed &&
      visibleConvId != null &&
      visibleConvId == intent.convId) {
    return false;
  }
  return true;
}

/// Whether to show the one-time explanation before the OS permission prompt.
///
/// Only when the OS has not been asked yet: a person who already allowed or
/// denied notifications is never re-prompted (Android 12 and older, where
/// there is no runtime prompt, reports [PushPermission.granted]). [status] is
/// the RESOLVED state from resolvePushPermission — on Android 13+ a raw
/// "denied" that GoodLift never asked about arrives here as notDetermined.
bool shouldOfferPermissionPrimer({
  required PushPermission status,
  required bool alreadyShown,
  required bool signedIn,
}) {
  return signedIn && !alreadyShown && status == PushPermission.notDetermined;
}

/// The account's notification switches. Stored at `pushPreferences/{uid}`.
///
/// Categories default ON; message previews default OFF. The server applies
/// the same defaults to a missing document or field, so the two can never
/// disagree about what an untouched account receives.
class PushPreferences {
  const PushPreferences({
    this.friendRequests = true,
    this.friendAccepted = true,
    this.directMessages = true,
    this.messagePreviews = false,
  });

  final bool friendRequests;
  final bool friendAccepted;
  final bool directMessages;
  final bool messagePreviews;

  static const String fFriendRequests = 'friendRequests';
  static const String fFriendAccepted = 'friendAccepted';
  static const String fDirectMessages = 'directMessages';
  static const String fMessagePreviews = 'messagePreviews';

  static PushPreferences fromMap(Map<String, dynamic>? data) {
    bool b(String key, bool fallback) {
      final Object? v = data?[key];
      return v is bool ? v : fallback;
    }

    return PushPreferences(
      friendRequests: b(fFriendRequests, true),
      friendAccepted: b(fFriendAccepted, true),
      directMessages: b(fDirectMessages, true),
      messagePreviews: b(fMessagePreviews, false),
    );
  }

  PushPreferences withField(String field, bool value) {
    return PushPreferences(
      friendRequests: field == fFriendRequests ? value : friendRequests,
      friendAccepted: field == fFriendAccepted ? value : friendAccepted,
      directMessages: field == fDirectMessages ? value : directMessages,
      messagePreviews: field == fMessagePreviews ? value : messagePreviews,
    );
  }

  bool valueOf(String field) {
    switch (field) {
      case fFriendRequests:
        return friendRequests;
      case fFriendAccepted:
        return friendAccepted;
      case fDirectMessages:
        return directMessages;
      case fMessagePreviews:
        return messagePreviews;
    }
    return false;
  }
}
