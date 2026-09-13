// Push notification triggers. See outbox.js for the delivery design and
// push_model.js for what counts as a notification.
//
//   pushOnDirectMessageWritten  conversations/{convId}/messages/{messageId}
//                               → a directMessage job the first time the
//                                 message becomes deliverable, and a
//                                 dmReaction job (to the message's SENDER) for
//                                 each reaction that arrives on it
//   pushOnPostCommentWritten    posts/{postId}/comments/{commentId}
//   pushOnPostLikeWritten       posts/{postId}/likes/{actorUid}
//   pushOnPostGoodLiftWritten   posts/{postId}/goodLifts/{actorUid}
//                               → the post owner's activity record + job
//   pushOnPostDeleted           posts/{postId} (deleted)
//                               → retires every activity record for the post
//   pushOutboxOnCreated         pushOutbox/{jobId}
//                               → delivers one job through FCM
//
// Every one of these triggers on the AUTHORITATIVE interaction document, never
// on a denormalised counter: `likeCount` is written by the visitor's own
// client, carries no identity, and moves for removals and edits as well.
//
// Friend-request and acceptance jobs are enqueued by the EXISTING invite
// trigger (social/notifications.js), the acceptance inside the same
// transaction that writes the acceptance notice. There is deliberately no
// trigger on socialNotifications: that would be a second path to the same
// alert.
//
// ── Rollback ────────────────────────────────────────────────────────────────
// Set pushConfig/delivery {enabled: false} (console) to stop all sends within
// seconds; or delete pushOutboxOnCreated. Neither touches acceptance notices,
// friendships or messaging. See docs/push_notifications.md.

'use strict';

const {
  onDocumentWritten,
  onDocumentCreated,
  onDocumentDeleted,
} = require('firebase-functions/v2/firestore');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const O = require('./outbox');

function eventTimeMs(event) {
  const t = Date.parse(event && event.time);
  return Number.isFinite(t) ? t : undefined;
}

const pushOnDirectMessageWritten = onDocumentWritten(
  { document: 'conversations/{convId}/messages/{messageId}', retry: true },
  async (event) => {
    const { convId, messageId } = event.params;
    const before = event.data && event.data.before;
    const after = event.data && event.data.after;
    const beforeData = before && before.exists ? before.data() : null;
    const afterData = after && after.exists ? after.data() : null;
    const db = admin.firestore();
    const common = {
      convId,
      messageId,
      beforeData,
      afterData,
      eventId: event.id,
      eventTimeMs: eventTimeMs(event),
    };
    // Counting happens here too, on the same "this message is deliverable"
    // decision, so the unread number is right even when this person has push
    // switched off or has never granted the OS permission. See dm_unread.js.
    const result = await O.enqueueDirectMessage(db, common);
    if (result.reason !== 'not-newly-deliverable') {
      // Ids only — never message content.
      logger.info('[push] dm %s/%s: %s', convId, messageId, result.reason);
    }
    // A reaction is a write to the SAME document, and goes to the person who
    // sent the message rather than the one who receives them. It never counts
    // as an incoming message, so the unread-message number cannot move.
    const reacted = await O.enqueueDmReactions(db, common);
    if (reacted.reason !== 'no-new-reaction') {
      logger.info('[push] dm reaction %s/%s: %s', convId, messageId, reacted.reason);
    }
  },
);

/**
 * "X commented on your post" — for the post's owner.
 *
 * On the comment document itself, not on the denormalised `commentCount`: the
 * counter is written by the commenter's own client, says nothing about who
 * wrote what, and moves for edits and deletions too.
 */
const pushOnPostCommentWritten = onDocumentWritten(
  { document: 'posts/{postId}/comments/{commentId}', retry: true },
  async (event) => {
    const { postId, commentId } = event.params;
    const before = event.data && event.data.before;
    const after = event.data && event.data.after;
    const result = await O.enqueuePostComment(admin.firestore(), {
      postId,
      commentId,
      beforeData: before && before.exists ? before.data() : null,
      afterData: after && after.exists ? after.data() : null,
      eventId: event.id,
      eventTimeMs: eventTimeMs(event),
    });
    if (result.reason !== 'not-a-new-comment') {
      // Ids only — never the comment's words.
      logger.info('[push] comment %s/%s: %s', postId, commentId, result.reason);
    }
  },
);

/** "X liked your post" — for the post's owner. */
const pushOnPostLikeWritten = onDocumentWritten(
  { document: 'posts/{postId}/likes/{actorUid}', retry: true },
  async (event) => {
    const { postId, actorUid } = event.params;
    const before = event.data && event.data.before;
    const after = event.data && event.data.after;
    const result = await O.enqueuePostReaction(admin.firestore(), {
      kind: 'like',
      postId,
      actorUid,
      beforeData: before && before.exists ? before.data() : null,
      afterData: after && after.exists ? after.data() : null,
      eventId: event.id,
      eventTimeMs: eventTimeMs(event),
    });
    if (result.reason !== 'not-a-new-reaction') {
      logger.info('[push] like %s by %s: %s', postId, actorUid, result.reason);
    }
  },
);

/** "X gave your video a Good Lift" — for the post's owner. */
const pushOnPostGoodLiftWritten = onDocumentWritten(
  { document: 'posts/{postId}/goodLifts/{actorUid}', retry: true },
  async (event) => {
    const { postId, actorUid } = event.params;
    const before = event.data && event.data.before;
    const after = event.data && event.data.after;
    const result = await O.enqueuePostReaction(admin.firestore(), {
      kind: 'goodLift',
      postId,
      actorUid,
      beforeData: before && before.exists ? before.data() : null,
      afterData: after && after.exists ? after.data() : null,
      eventId: event.id,
      eventTimeMs: eventTimeMs(event),
    });
    if (result.reason !== 'not-a-new-reaction') {
      logger.info('[push] goodLift %s by %s: %s', postId, actorUid, result.reason);
    }
  },
);

/**
 * A deleted post: its comments, likes and Good Lifts stop counting.
 *
 * Deleting a post does not fire the subcollection triggers, so without this
 * the owner keeps a badge and an Activity list pointing at something that
 * cannot be opened. Records are retired, never deleted, so the ids still
 * suppress a replay.
 */
const pushOnPostDeleted = onDocumentDeleted(
  { document: 'posts/{postId}', retry: true },
  async (event) => {
    const { postId } = event.params;
    const before = event.data;
    const result = await O.retirePostActivity(admin.firestore(), {
      postId,
      beforeData: before && before.exists ? before.data() : null,
    });
    if (result.retired > 0) {
      logger.info('[push] post %s deleted: %d activity records retired', postId, result.retired);
    }
  },
);

const pushOutboxOnCreated = onDocumentCreated(
  { document: `${O.COL_OUTBOX}/{jobId}`, retry: true, memory: '256MiB', timeoutSeconds: 60 },
  async (event) => {
    const { jobId } = event.params;
    try {
      await O.processJob(admin.firestore(), jobId);
    } catch (err) {
      if (err instanceof O.RetryableDeliveryError) {
        // Thrown on purpose so the platform retries with backoff. Bounded by
        // the job's expiry and attempt budget, which the next claim enforces.
        logger.warn('[push] %s', err.message);
      } else {
        logger.error('[push] job %s failed: %s', jobId, err && err.message);
      }
      throw err;
    }
  },
);

module.exports = {
  pushOnDirectMessageWritten,
  pushOnPostCommentWritten,
  pushOnPostLikeWritten,
  pushOnPostGoodLiftWritten,
  pushOnPostDeleted,
  pushOutboxOnCreated,
};
