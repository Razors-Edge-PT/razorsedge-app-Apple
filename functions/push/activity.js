// Social activity — what somebody did to your content, kept where you can see
// it whether or not a phone alert ever arrived.
//
// ── Why a record, and not just a push ───────────────────────────────────────
// A push notification is a courtesy: it needs permission, it needs a category
// left switched on, it can be swiped away, and it is gone the moment the
// person taps it or the OS decides to age it out. None of that is a good place
// to keep "three people commented on your post". So every interaction writes a
// durable record under the person it is addressed to, and the alert is a view
// OF that record — not the other way round. The unread badge, the Activity
// list, and which phone alerts get cancelled when something is read all come
// from this one collection.
//
//   users/{recipientUid}/socialActivity/{activityId}
//     { type, actorUid, subject, postId?, commentId?,
//       conversationId?, messageId?, emoji?, preview?, tag,
//       read: false, createdAt, occurrence }
//
// ── Identity, replays and read state ────────────────────────────────────────
// The id is derived from the interaction's OCCURRENCE (push_model.js), so:
//
//   * a redelivered Firestore event, a retry, or an out-of-order write finds
//     the record already there and writes nothing — an interaction the person
//     has already read is never resurrected as unread;
//   * a like removed and given again, or a reaction whose emoji is swapped, is
//     the same occurrence and so stays one record and one alert;
//   * two different people reacting are two occurrences and two records.
//
// Records are created, never updated by the server and never deleted by it.
// Removing a like deliberately does NOT delete its record: deleting it would
// let the next like recreate it and alert again, which is precisely the
// notification spam the occurrence is there to prevent. The delivery worker
// re-checks the live interaction before sending, so a removed like that has
// not been delivered yet is dropped rather than announced.
//
// The ONE field a client may change is `read` (false → true, with `readAt`),
// and only its owner may change it — see firestore.rules. That makes read
// state monotonic: no screen, no replay and no offline write can move an
// interaction back to unread.

'use strict';

const admin = require('firebase-admin');

const P = require('./push_model');

const SUB_ACTIVITY = 'socialActivity';
const COL_USERS = 'users';

/** How much of a comment is kept for the in-app list. */
const PREVIEW_MAX = 140;

/** Deterministic record id for one occurrence. */
function activityIdFor(type, recipientUid, occurrence) {
  const prefix = {
    [P.PushType.DM_REACTION]: 'dr',
    [P.PushType.POST_COMMENT]: 'pc',
    [P.PushType.POST_LIKE]: 'pl',
    [P.PushType.POST_GOOD_LIFT]: 'pg',
  }[type];
  if (!prefix) throw new Error(`no activity record for push type ${type}`);
  return `${prefix}_${P.sha256Hex(`${type}|${recipientUid}|${occurrence}`).slice(0, 40)}`;
}

function activityRef(db, recipientUid, activityId) {
  return db
    .collection(COL_USERS)
    .doc(recipientUid)
    .collection(SUB_ACTIVITY)
    .doc(activityId);
}

/** `post:<id>` / `dm:<convId>` — what reading this interaction means reading. */
function subjectOf({ type, postId, conversationId }) {
  return P.POST_TYPES.has(type) ? `post:${postId}` : `dm:${conversationId}`;
}

function truncatePreview(text) {
  const s = String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
  if (s.length <= PREVIEW_MAX) return s;
  return `${s.slice(0, PREVIEW_MAX - 1)}…`;
}

/**
 * The record for one interaction. [tag] is the notification tag its alert
 * carries, stored so that reading THIS interaction cancels exactly its alert
 * rather than everything for the post or conversation.
 */
function activityRecord({
  type,
  actorUid,
  occurrence,
  postId,
  commentId,
  conversationId,
  messageId,
  emoji,
  preview,
  tag,
  now,
}) {
  return {
    type,
    actorUid,
    subject: subjectOf({ type, postId, conversationId }),
    occurrence,
    ...(postId ? { postId } : {}),
    ...(commentId ? { commentId } : {}),
    ...(conversationId ? { conversationId } : {}),
    ...(messageId ? { messageId } : {}),
    ...(emoji ? { emoji } : {}),
    ...(preview ? { preview: truncatePreview(preview) } : {}),
    ...(tag ? { tag } : {}),
    read: false,
    createdAt: now || admin.firestore.FieldValue.serverTimestamp(),
  };
}

module.exports = {
  SUB_ACTIVITY,
  PREVIEW_MAX,
  activityIdFor,
  activityRef,
  activityRecord,
  subjectOf,
  truncatePreview,
};
