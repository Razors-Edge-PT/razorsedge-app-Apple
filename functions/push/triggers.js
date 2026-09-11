// Push notification triggers. See outbox.js for the delivery design and
// push_model.js for what counts as a notification.
//
//   pushOnDirectMessageWritten  conversations/{convId}/messages/{messageId}
//                               → enqueues a directMessage job the first time
//                                 the message becomes deliverable
//   pushOutboxOnCreated         pushOutbox/{jobId}
//                               → delivers one job through FCM
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

const { onDocumentWritten, onDocumentCreated } = require('firebase-functions/v2/firestore');
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
    const result = await O.enqueueDirectMessage(admin.firestore(), {
      convId,
      messageId,
      beforeData: before && before.exists ? before.data() : null,
      afterData: after && after.exists ? after.data() : null,
      eventId: event.id,
      eventTimeMs: eventTimeMs(event),
    });
    if (result.reason !== 'not-newly-deliverable') {
      // Ids only — never message content.
      logger.info('[push] dm %s/%s: %s', convId, messageId, result.reason);
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
  pushOutboxOnCreated,
};
