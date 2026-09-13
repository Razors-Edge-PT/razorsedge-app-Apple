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

enum PushKind {
  friendRequest,
  friendAccepted,
  directMessage,

  /// Somebody reacted with an emoji to a message THIS account sent.
  dmReaction,

  /// Somebody interacted with a post this account published. Where they found
  /// it — profile grid, Home feed or Buddy Hub — makes no difference: the
  /// interaction is recorded against the post.
  postComment,
  postLike,
  postGoodLift,
}

extension PushKindX on PushKind {
  /// True for the interactions that open a post.
  bool get isPostInteraction =>
      this == PushKind.postComment ||
      this == PushKind.postLike ||
      this == PushKind.postGoodLift;

  /// True for the interactions that have an activity record behind them —
  /// everything except the two friendship events, which have their own
  /// established surface in the Buddy Hub.
  bool get hasActivityRecord => isPostInteraction || this == PushKind.dmReaction;
}

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

/// The same key for any subject a group of alerts belongs to — a conversation,
/// or a post. Mirrors subjectTagKey in functions/push/push_model.js.
String subjectTagKey(String id) =>
    sha256.convert(utf8.encode(id)).toString().substring(0, 8);

/// Every alert about one post starts with this — a comment, a like and a Good
/// Lift alike. Reading that post cancels the lot, and nothing else.
String postTagPrefix(String postId) => 'post|${subjectTagKey(postId)}|';

/// The tag one post interaction's alert carries.
String postActivityTag({required String postId, required String activityId}) =>
    '${postTagPrefix(postId)}$activityId';

/// Every reaction alert for one conversation starts with this.
String dmReactionTagPrefix(String convId) => 'dmr|${subjectTagKey(convId)}|';

/// The tag the alert for a reaction to one message carries.
String dmReactionTag({required String convId, required String activityId}) =>
    '${dmReactionTagPrefix(convId)}$activityId';

/// The activity record a delivered alert is about, read back out of its tag.
///
/// Reconciliation starts from the alerts sitting in the tray — many of them
/// posted by the OS while Dart was not running — so the tag is the only thing
/// tying an alert to the record that says whether it still means anything.
/// Both interaction tags end with the record id: `post|<post>|<activity>` and
/// `dmr|<conversation>|<activity>`. Anything else (a message or friend alert,
/// or a tag from another build) returns null and is left alone.
String? activityIdFromTag(String tag) {
  final List<String> parts = tag.split('|');
  if (parts.length != 3) return null;
  if (parts[0] != 'post' && parts[0] != 'dmr') return null;
  final String id = parts[2].trim();
  return id.isEmpty ? null : id;
}

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

/// Android notification channel per kind. Mirrors ANDROID_CHANNEL in
/// functions/push/push_model.js and the channels MainActivity.kt creates —
/// a foreground-posted alert MUST land in the same channel a background one
/// would have, so the person's per-category settings (sound, importance,
/// or the category being switched off entirely) apply identically either
/// way.
String androidChannelFor(PushKind kind) {
  switch (kind) {
    case PushKind.friendRequest:
      return 'goodlift_friend_requests';
    case PushKind.friendAccepted:
      return 'goodlift_friend_accepted';
    case PushKind.directMessage:
      return 'goodlift_direct_messages';
    case PushKind.dmReaction:
      return 'goodlift_message_reactions';
    case PushKind.postComment:
      return 'goodlift_post_comments';
    case PushKind.postLike:
    case PushKind.postGoodLift:
      return 'goodlift_post_reactions';
  }
}

/// The tag a notification for [intent] carries — identical to what the
/// server would have used (presentationTag in functions/push/push_model.js)
/// — so a foreground-posted alert and existing cancellation/tap handling
/// agree on identity regardless of which path posted it. Null when the
/// intent lacks what its tag needs (an older or malformed payload); callers
/// must not post a system notification in that case, since it could never be
/// found again to cancel.
String? notificationTagFor(PushIntent intent) {
  switch (intent.kind) {
    case PushKind.friendRequest:
      return friendRequestTag(intent.actorUid);
    case PushKind.friendAccepted:
      return friendAcceptedTag(intent.actorUid);
    case PushKind.directMessage:
      return (intent.convId != null && intent.messageId != null)
          ? dmMessageTag(convId: intent.convId!, messageId: intent.messageId!)
          : null;
    case PushKind.dmReaction:
      return (intent.convId != null && intent.activityId != null)
          ? dmReactionTag(convId: intent.convId!, activityId: intent.activityId!)
          : null;
    case PushKind.postComment:
    case PushKind.postLike:
    case PushKind.postGoodLift:
      return (intent.postId != null && intent.activityId != null)
          ? postActivityTag(postId: intent.postId!, activityId: intent.activityId!)
          : null;
  }
}

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
    this.postId,
    this.commentId,
    this.activityId,
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

  /// Post interactions only: the post to open, and — for a comment — the one
  /// to reveal, which may be far outside the page the screen loads by default.
  final String? postId;
  final String? commentId;

  /// The activity record this alert belongs to, so that opening it marks
  /// exactly this interaction read rather than a screen's worth.
  final String? activityId;

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
      'dmReaction' => PushKind.dmReaction,
      'postComment' => PushKind.postComment,
      'postLike' => PushKind.postLike,
      'postGoodLift' => PushKind.postGoodLift,
      _ => null,
    };
    final String? recipient = s('recipientUid');
    final String? actor = s('actorUid');
    if (kind == null || recipient == null || actor == null) return null;
    if (recipient == actor) return null;

    String? convId;
    if (kind == PushKind.directMessage || kind == PushKind.dmReaction) {
      convId = s('convId');
      if (convId == null || convId != conversationIdFor(recipient, actor)) {
        return null;
      }
    }
    final String? postId = s('postId');
    // A post interaction with nothing to open is not actionable.
    if (kind.isPostInteraction && postId == null) return null;
    // A reaction alert names the message it is about; without it there is
    // nothing to reveal and nothing to cancel precisely.
    if (kind == PushKind.dmReaction && s('msgId') == null) return null;

    return PushIntent(
      kind: kind,
      recipientUid: recipient,
      actorUid: actor,
      convId: convId,
      messageId: s('msgId'),
      incomingSeq: int.tryParse(s('seq') ?? ''),
      postId: postId,
      commentId: s('commentId'),
      activityId: s('activityId'),
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
/// [targetOnScreen] answers the only question that matters for an interaction
/// with a specific target: is THAT comment, or THAT reacted-to message,
/// actually in the viewport? Having the post or the chat open is not the same
/// thing — an older comment may be far up the thread, or not even loaded — and
/// suppressing on the open screen alone silently swallowed news the person had
/// no way of seeing. [alreadyAcknowledged] covers the other honest case: the
/// interaction was positively read a moment ago.
bool shouldShowForegroundBanner({
  required PushIntent intent,
  required String? currentUid,
  required String? visibleConvId,
  required bool appResumed,
  String? visiblePostId,
  bool targetOnScreen = false,
  bool alreadyAcknowledged = false,
}) {
  if (currentUid == null || currentUid != intent.recipientUid) return false;
  if (alreadyAcknowledged) return false;
  if (!appResumed) return true;
  // A new MESSAGE lands at the bottom of the thread in front of the person:
  // opening that thread does show it.
  if (intent.kind == PushKind.directMessage &&
      visibleConvId != null &&
      visibleConvId == intent.convId) {
    return false;
  }
  // A REACTION is about one particular message: only its being on screen
  // counts.
  if (intent.kind == PushKind.dmReaction) {
    return !(visibleConvId == intent.convId && targetOnScreen);
  }
  // A COMMENT is about one particular comment, likewise.
  if (intent.kind == PushKind.postComment) {
    return !(visiblePostId == intent.postId && targetOnScreen);
  }
  // A like or a Good Lift is presented by the post itself — its counts are on
  // screen — so the open post does suppress it, and only for THIS post.
  if (intent.kind.isPostInteraction &&
      visiblePostId != null &&
      visiblePostId == intent.postId) {
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
    this.messageReactions = true,
    this.postComments = true,
    this.postReactions = true,
    this.messagePreviews = false,
    this.commentPreviews = false,
  });

  final bool friendRequests;
  final bool friendAccepted;
  final bool directMessages;

  /// Emoji reactions to messages this account sent.
  final bool messageReactions;

  /// Comments on this account's posts.
  final bool postComments;

  /// Likes and Good Lifts on this account's posts — one switch, because they
  /// are the same gesture and splitting them would make the setting's effect
  /// depend on whether the post happens to be a video.
  final bool postReactions;

  final bool messagePreviews;

  /// Whether a comment's words may appear in a notification.
  final bool commentPreviews;

  static const String fFriendRequests = 'friendRequests';
  static const String fFriendAccepted = 'friendAccepted';
  static const String fDirectMessages = 'directMessages';
  static const String fMessageReactions = 'messageReactions';
  static const String fPostComments = 'postComments';
  static const String fPostReactions = 'postReactions';
  static const String fMessagePreviews = 'messagePreviews';
  static const String fCommentPreviews = 'commentPreviews';

  /// Defaults mirror DEFAULT_PREFERENCES in functions/push/push_model.js. A
  /// field an older build never wrote takes the default, so a new category is
  /// on for existing accounts without a migration and without overwriting the
  /// answers they have already given.
  static PushPreferences fromMap(Map<String, dynamic>? data) {
    bool b(String key, bool fallback) {
      final Object? v = data?[key];
      return v is bool ? v : fallback;
    }

    return PushPreferences(
      friendRequests: b(fFriendRequests, true),
      friendAccepted: b(fFriendAccepted, true),
      directMessages: b(fDirectMessages, true),
      messageReactions: b(fMessageReactions, true),
      postComments: b(fPostComments, true),
      postReactions: b(fPostReactions, true),
      messagePreviews: b(fMessagePreviews, false),
      commentPreviews: b(fCommentPreviews, false),
    );
  }

  PushPreferences withField(String field, bool value) {
    return PushPreferences(
      friendRequests: field == fFriendRequests ? value : friendRequests,
      friendAccepted: field == fFriendAccepted ? value : friendAccepted,
      directMessages: field == fDirectMessages ? value : directMessages,
      messageReactions: field == fMessageReactions ? value : messageReactions,
      postComments: field == fPostComments ? value : postComments,
      postReactions: field == fPostReactions ? value : postReactions,
      messagePreviews: field == fMessagePreviews ? value : messagePreviews,
      commentPreviews: field == fCommentPreviews ? value : commentPreviews,
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
      case fMessageReactions:
        return messageReactions;
      case fPostComments:
        return postComments;
      case fPostReactions:
        return postReactions;
      case fMessagePreviews:
        return messagePreviews;
      case fCommentPreviews:
        return commentPreviews;
    }
    return false;
  }
}
