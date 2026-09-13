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
// Records are created and never deleted by the server. Removing a like
// deliberately does NOT delete its record: deleting it would let the next like
// recreate it and alert again, which is precisely the notification spam the
// occurrence is there to prevent. The delivery worker re-checks the live
// interaction before sending, so a removed like that has not been delivered
// yet is dropped rather than announced.
//
// ── Withdrawn and edited interactions ───────────────────────────────────────
// An interaction that no longer exists must stop COUNTING while still being
// remembered, which is what [retireActivity] does:
//
//   { invalidated: true, invalidatedAt, invalidReason }
//
// The id stays, so the same occurrence returning is still a duplicate and
// still cannot alert; `invalidated` takes it out of the badge, the Activity
// list, the delivery worker's pre-send check and any replay. `read` is left
// exactly as it was, so an interaction that comes back — a like taken away
// and given again — comes back as it was rather than as freshly unread; see
// [reviveActivity].
//
// An interaction that CHANGED rather than went away — a comment edited, a
// reaction's emoji swapped — is refreshed in place by [refreshActivity], with
// no new record and so no second alert: the person has already been told.
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
    // Written explicitly so a withdrawn interaction is a field change rather
    // than a field appearing, and so the field can be queried on.
    invalidated: false,
    createdAt: now || admin.firestore.FieldValue.serverTimestamp(),
  };
}

/**
 * Stop [activityId] counting, without forgetting it happened.
 *
 * Absent record: nothing to do — the interaction was never notifiable (the
 * person's own action, a stranger's, a post that had gone), so there is no
 * badge to correct and no alert to cancel.
 */
async function retireActivity(db, recipientUid, activityId, reason) {
  if (!recipientUid || !activityId) return false;
  const ref = activityRef(db, recipientUid, activityId);
  try {
    await ref.update({
      invalidated: true,
      invalidatedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...(reason ? { invalidReason: String(reason).slice(0, 40) } : {}),
    });
    return true;
  } catch (err) {
    // NOT_FOUND: there is no record for this occurrence. Anything else is a
    // real failure and the caller's trigger should retry.
    if (err && (err.code === 5 || err.code === 'not-found')) return false;
    throw err;
  }
}

/** How many records one subject's cascade will retire in a single pass. */
const RETIRE_PAGE = 300;

/**
 * Retire every record for one subject — `post:<id>` when a post is deleted.
 *
 * One equality filter, so no composite index. Paged, because a popular post
 * can carry more interactions than one batch may hold.
 */
async function retireSubject(db, recipientUid, subject, reason) {
  if (!recipientUid || !subject) return 0;
  const col = db
    .collection(COL_USERS)
    .doc(recipientUid)
    .collection(SUB_ACTIVITY);
  let retired = 0;
  let cursor = null;
  for (;;) {
    let q = col.where('subject', '==', subject).limit(RETIRE_PAGE);
    if (cursor) q = q.startAfter(cursor);
    // eslint-disable-next-line no-await-in-loop
    const page = await q.get();
    if (page.empty) return retired;
    cursor = page.docs[page.docs.length - 1];
    const batch = db.batch();
    let writes = 0;
    for (const doc of page.docs) {
      if (doc.get('invalidated') === true) continue;
      writes += 1;
      batch.update(doc.ref, {
        invalidated: true,
        invalidatedAt: admin.firestore.FieldValue.serverTimestamp(),
        ...(reason ? { invalidReason: String(reason).slice(0, 40) } : {}),
      });
    }
    // eslint-disable-next-line no-await-in-loop
    if (writes > 0) await batch.commit();
    retired += writes;
    if (page.size < RETIRE_PAGE) return retired;
  }
}

/**
 * The interaction is back — a like taken away and given again, the same
 * occurrence exactly. The record returns to counting with the read state it
 * had, and no job is enqueued: one interaction, one alert, however many times
 * somebody changes their mind.
 *
 * Returns true only if it actually had to be revived.
 */
async function reviveActivity(db, recipientUid, activityId) {
  if (!recipientUid || !activityId) return false;
  const ref = activityRef(db, recipientUid, activityId);
  const snap = await ref.get();
  if (!snap.exists || snap.get('invalidated') !== true) return false;
  await ref.update({
    invalidated: false,
    invalidatedAt: admin.firestore.FieldValue.delete(),
    invalidReason: admin.firestore.FieldValue.delete(),
  });
  return true;
}

/**
 * Keep an existing record's wording true — an edited comment, a swapped
 * reaction emoji. Never creates a record and never enqueues a job: the person
 * has already been told about this interaction, and telling them again because
 * the other person fixed a typo would be noise.
 */
async function refreshActivity(db, recipientUid, activityId, { preview, emoji }) {
  if (!recipientUid || !activityId) return false;
  const patch = {
    ...(preview === undefined ? {} : { preview: truncatePreview(preview) }),
    ...(emoji === undefined ? {} : { emoji: String(emoji).slice(0, 8) }),
  };
  if (Object.keys(patch).length === 0) return false;
  try {
    await activityRef(db, recipientUid, activityId).update(patch);
    return true;
  } catch (err) {
    if (err && (err.code === 5 || err.code === 'not-found')) return false;
    throw err;
  }
}

module.exports = {
  SUB_ACTIVITY,
  PREVIEW_MAX,
  RETIRE_PAGE,
  activityIdFor,
  activityRef,
  activityRecord,
  subjectOf,
  truncatePreview,
  retireActivity,
  retireSubject,
  reviveActivity,
  refreshActivity,
};
