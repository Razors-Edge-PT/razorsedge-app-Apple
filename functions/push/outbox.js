// Push notifications — the durable outbox and its delivery worker.
//
// ── Shape ───────────────────────────────────────────────────────────────────
//   pushOutbox/{jobId}          server-only (rules deny every client)
//     type, recipientUid, actorUid, occurrence, sourceEventId,
//     inviteOccurrence | conversationId + messageId,
//     status  pending | sending | sent | skipped | expired | failed
//     attempts, lease {id, until}, devices {deviceId: sent|invalid|failed|retry},
//     createdAt, expiresAt, purgeAt (Firestore TTL), lastReason
//
//   pushDevices/{sha256(token)} { uid, token, platform, appVersion, updatedAt }
//   pushPreferences/{uid}       { friendRequests, friendAccepted,
//                                 directMessages, messagePreviews, updatedAt }
//   pushConfig/delivery         { enabled: false } — the kill switch
//
// ── Why an outbox ───────────────────────────────────────────────────────────
// The event triggers decide THAT a notification exists and write one job with
// a deterministic id, idempotently (create-if-absent). They never call FCM.
// A separate worker (pushOutboxOnCreated) sends it. So:
//   • a network send is never inside a Firestore transaction;
//   • a redelivered or concurrent event cannot enqueue a second job;
//   • the worker can be retried, disabled or deleted without touching the
//     acceptance notices or messaging, which do not depend on it.
//
// ── One attempt ─────────────────────────────────────────────────────────────
//   1. CLAIM (transaction): skip terminal jobs; expire past the deadline;
//      give up after MAX_ATTEMPTS; refuse a job another worker holds a live
//      lease on (the caller throws, so the platform retries it later).
//   2. VALIDATE against CURRENT state, not the event: the request is still
//      pending and is the same occurrence; the acceptance notice is the same
//      occurrence and still unseen; the message is still deliverable from the
//      same sender; the pair is still mutually accepted; the recipient still
//      exists and has this category switched on.
//   3. SEND to the recipient's registrations that have not already had it.
//   4. RECORD each device's result (transaction). Delivered devices are never
//      sent to again for this job; invalid registrations are deleted with a
//      guard; transient failures leave the job pending and the worker throws
//      so the platform retries it (10 s → 600 s backoff, 24 h window), bounded
//      by the job's own expiry and attempt budget.
//
// ── What this cannot promise ────────────────────────────────────────────────
// Exactly-once FCM delivery. If the worker dies after FCM accepted a message
// but before step 4 committed, the retry sends it again. The stable Android
// `tag` / APNs `apns-collapse-id` make that second copy REPLACE the first on
// the device rather than stack, but a second alert sound is possible.

'use strict';

const crypto = require('node:crypto');
const admin = require('firebase-admin');
const logger = require('firebase-functions/logger');

const P = require('./push_model');
const M = require('../social/buddy_model');

const COL_OUTBOX = 'pushOutbox';
const COL_DEVICES = 'pushDevices';
const COL_PREFS = 'pushPreferences';
const CONFIG_PATH = 'pushConfig/delivery';

class RetryableDeliveryError extends Error {
  constructor(message) {
    super(message);
    this.name = 'RetryableDeliveryError';
  }
}

const FieldValue = () => admin.firestore.FieldValue;
const Timestamp = () => admin.firestore.Timestamp;

function dataOf(snap) {
  return snap && snap.exists ? snap.data() : null;
}

function outboxRef(db, jobId) {
  return db.collection(COL_OUTBOX).doc(jobId);
}

// ── Enqueue ─────────────────────────────────────────────────────────────────

/**
 * The job document for one occurrence. [eventTimeMs] is when the source write
 * happened, so a trigger that runs late does not extend the deadline.
 */
function newJob({
  type,
  recipientUid,
  actorUid,
  occurrence,
  sourceEventId,
  eventTimeMs,
  nowMs,
  extra,
}) {
  const base = Number.isFinite(eventTimeMs) ? eventTimeMs : nowMs;
  const id = P.jobIdFor(type, recipientUid, occurrence);
  return {
    id,
    data: {
      type,
      recipientUid,
      actorUid,
      occurrence,
      sourceEventId: sourceEventId || null,
      ...(extra || {}),
      status: P.JobStatus.PENDING,
      attempts: 0,
      devices: {},
      createdAt: FieldValue().serverTimestamp(),
      expiresAt: Timestamp().fromMillis(base + P.DELIVERY_WINDOW_MS[type]),
      purgeAt: Timestamp().fromMillis(base + P.PURGE_AFTER_MS),
    },
  };
}

function isAlreadyExists(err) {
  return !!err && (err.code === 6 || err.code === 'already-exists' ||
    /ALREADY_EXISTS/.test(String(err.message)));
}

/** Creates the job if absent. Returns true when this call created it. */
async function enqueueJob(db, job) {
  try {
    await outboxRef(db, job.id).create(job.data);
    return true;
  } catch (err) {
    if (isAlreadyExists(err)) return false;
    throw err;
  }
}

// ── Friend requests (enqueued from the invite trigger) ──────────────────────

/**
 * Enqueues "X sent you a friend request" for a genuine pending transition at
 * users/{receiverUid}/buddyInvites/{senderUid}. Validity is re-checked at
 * delivery, so a request cancelled or answered before the worker runs is
 * dropped there.
 */
async function enqueueFriendRequest(db, {
  receiverUid, senderUid, beforeData, afterData, eventId, eventTimeMs, nowMs,
}) {
  if (!P.isNewPendingRequest(beforeData, afterData)) {
    return { enqueued: false, reason: 'not-a-new-request' };
  }
  if (!P.inviteMatchesPath(afterData, receiverUid, senderUid)) {
    return { enqueued: false, reason: 'invalid-pair' };
  }
  const inviteOccurrence = P.inviteOccurrence(afterData, eventId);
  const job = newJob({
    type: P.PushType.FRIEND_REQUEST,
    recipientUid: receiverUid,
    actorUid: senderUid,
    occurrence: `${senderUid}|${inviteOccurrence}`,
    sourceEventId: eventId,
    eventTimeMs,
    nowMs: nowMs == null ? Date.now() : nowMs,
    extra: { inviteOccurrence },
  });
  const created = await enqueueJob(db, job);
  return { enqueued: created, reason: created ? 'enqueued' : 'duplicate', jobId: job.id };
}

/**
 * The "X accepted your friend request" job for one acceptance, to be created
 * INSIDE the transaction that writes the acceptance notice — so a notice and
 * its push are one decision, and nothing else enqueues acceptances.
 */
function friendAcceptedJob({
  senderUid, acceptorUid, inviteOccurrence, eventId, eventTimeMs, nowMs,
}) {
  return newJob({
    type: P.PushType.FRIEND_ACCEPTED,
    recipientUid: senderUid,
    actorUid: acceptorUid,
    occurrence: `${acceptorUid}|${inviteOccurrence}`,
    sourceEventId: eventId,
    eventTimeMs,
    nowMs: nowMs == null ? Date.now() : nowMs,
    extra: { inviteOccurrence },
  });
}

// ── Direct messages (enqueued from the message trigger) ─────────────────────

async function enqueueDirectMessage(db, {
  convId, messageId, beforeData, afterData, eventId, eventTimeMs, nowMs,
}) {
  if (!P.becameDeliverable(beforeData, afterData)) {
    return { enqueued: false, reason: 'not-newly-deliverable' };
  }
  const parties = P.resolveDmParties({ convId, messageData: afterData });
  if (parties.reason) return { enqueued: false, reason: parties.reason };

  // Membership is checked against the conversation NOW, before a job exists.
  // The worker checks it again at delivery.
  const conv = await db.collection('conversations').doc(convId).get();
  const checked = P.resolveDmParties({
    convId,
    messageData: afterData,
    conversationData: dataOf(conv) || {},
  });
  if (checked.reason) return { enqueued: false, reason: checked.reason };

  const job = newJob({
    type: P.PushType.DIRECT_MESSAGE,
    recipientUid: checked.recipientUid,
    actorUid: checked.senderUid,
    occurrence: `${convId}|${messageId}`,
    sourceEventId: eventId,
    eventTimeMs,
    nowMs: nowMs == null ? Date.now() : nowMs,
    extra: { conversationId: convId, messageId },
  });
  const created = await enqueueJob(db, job);
  return { enqueued: created, reason: created ? 'enqueued' : 'duplicate', jobId: job.id };
}

// ── Validation at delivery ──────────────────────────────────────────────────

async function mutualFriends(db, a, b) {
  const [sa, sb] = await Promise.all([
    db.collection(M.COL_ASSIGNMENTS).doc(a).get(),
    db.collection(M.COL_ASSIGNMENTS).doc(b).get(),
  ]);
  return M.areMutualFriends(dataOf(sa), dataOf(sb), a, b);
}

/**
 * Is [job] still worth delivering, judged on current state? Returns
 * `{ ok: true, kind, text }` or `{ ok: false, reason }`.
 */
async function checkValidity(db, job) {
  const { type, recipientUid, actorUid } = job;
  if (!recipientUid || !actorUid || recipientUid === actorUid) {
    return { ok: false, reason: 'self-or-missing-party' };
  }

  if (type === P.PushType.FRIEND_REQUEST) {
    const invite = dataOf(await db
      .collection(M.COL_USERS).doc(recipientUid)
      .collection(M.SUB_INVITES).doc(actorUid).get());
    if (!invite) return { ok: false, reason: 'request-gone' };
    if (invite.status !== M.InviteStatus.PENDING) return { ok: false, reason: 'request-resolved' };
    if (!P.inviteMatchesPath(invite, recipientUid, actorUid)) return { ok: false, reason: 'invalid-pair' };
    if (P.inviteOccurrence(invite, job.sourceEventId) !== job.inviteOccurrence) {
      return { ok: false, reason: 'superseded-request' };
    }
    return { ok: true };
  }

  if (type === P.PushType.FRIEND_ACCEPTED) {
    const notice = dataOf(await db
      .collection(M.COL_USERS).doc(recipientUid)
      .collection('socialNotifications').doc(`buddyAccepted_${actorUid}`).get());
    if (!notice) return { ok: false, reason: 'notice-gone' };
    const sameOccurrence = notice.occurrenceKey
      ? notice.occurrenceKey === job.inviteOccurrence
      : notice.sourceEventId === job.sourceEventId;
    if (!sameOccurrence) return { ok: false, reason: 'superseded-acceptance' };
    // Seen in the app already: the person has had the news, so the banner
    // would only repeat it.
    if (notice.seen === true) return { ok: false, reason: 'already-seen' };
    if (!(await mutualFriends(db, recipientUid, actorUid))) {
      return { ok: false, reason: 'not-friends' };
    }
    return { ok: true };
  }

  if (type === P.PushType.DIRECT_MESSAGE) {
    const convRef = db.collection('conversations').doc(job.conversationId);
    const [conv, msg] = await Promise.all([
      convRef.get(),
      convRef.collection('messages').doc(job.messageId).get(),
    ]);
    const convData = dataOf(conv);
    const msgData = dataOf(msg);
    if (!convData) return { ok: false, reason: 'conversation-gone' };
    if (!msgData) return { ok: false, reason: 'message-gone' };
    const parties = P.resolveDmParties({
      convId: job.conversationId,
      messageData: msgData,
      conversationData: convData,
    });
    if (parties.reason) return { ok: false, reason: parties.reason };
    if (parties.senderUid !== actorUid || parties.recipientUid !== recipientUid) {
      return { ok: false, reason: 'parties-changed' };
    }
    const kind = P.messageKind(msgData);
    if (!kind) return { ok: false, reason: 'not-deliverable' };
    if (!(await mutualFriends(db, recipientUid, actorUid))) {
      return { ok: false, reason: 'not-friends' };
    }
    return { ok: true, kind, text: kind === 'text' ? String(msgData.text) : '' };
  }

  return { ok: false, reason: 'unknown-type' };
}

/** 'active' | 'missing' | 'disabled'. Injectable for tests. */
async function defaultAccountState(uid) {
  try {
    const user = await admin.auth().getUser(uid);
    return user.disabled ? 'disabled' : 'active';
  } catch (err) {
    if (err && err.code === 'auth/user-not-found') return 'missing';
    throw err;
  }
}

// ── Registrations ───────────────────────────────────────────────────────────

async function devicesOf(db, uid) {
  const q = await db.collection(COL_DEVICES).where('uid', '==', uid).limit(P.MAX_DEVICES).get();
  return q.docs.map((d) => ({ id: d.id, ...d.data() }));
}

/**
 * Deletes a registration ONLY if it is still the one that failed: same owner,
 * same token, and not refreshed since [notAfterMs]. A device that re-registered
 * (or changed hands) after the send is left alone.
 */
async function guardedDeleteDevice(db, { deviceId, uid, token, notAfterMs }) {
  const ref = db.collection(COL_DEVICES).doc(deviceId);
  return db.runTransaction(async (tx) => {
    const d = dataOf(await tx.get(ref));
    if (!d) return false;
    if (d.uid !== uid || d.token !== token) return false;
    const updated = P.millisOf(d.updatedAt);
    if (updated !== null && updated > notAfterMs) return false;
    tx.delete(ref);
    return true;
  });
}

// ── The worker ──────────────────────────────────────────────────────────────

function newLeaseId() {
  return crypto.randomBytes(8).toString('hex');
}

async function finalizeTerminal(db, jobId, leaseId, status, reason) {
  const ref = outboxRef(db, jobId);
  await db.runTransaction(async (tx) => {
    const job = dataOf(await tx.get(ref));
    if (!job) return;
    if (leaseId && (!job.lease || job.lease.id !== leaseId)) return;
    tx.update(ref, {
      status,
      lastReason: reason,
      lease: FieldValue().delete(),
      finishedAt: FieldValue().serverTimestamp(),
    });
  });
}

/**
 * Runs one delivery attempt for [jobId]. Throws RetryableDeliveryError when
 * the platform should retry later; returns a summary otherwise.
 *
 * [deps]: { messaging: { sendEach(messages) }, accountState(uid), nowMs() }.
 */
async function processJob(db, jobId, deps = {}) {
  const nowMs = deps.nowMs || (() => Date.now());
  const messaging = deps.messaging || admin.messaging();
  const accountState = deps.accountState || defaultAccountState;
  const ref = outboxRef(db, jobId);
  const leaseId = newLeaseId();

  // 1. Claim.
  const claim = await db.runTransaction(async (tx) => {
    const job = dataOf(await tx.get(ref));
    const decision = P.claimDecision(job, nowMs());
    if (decision.finalize) {
      tx.update(ref, {
        status: decision.finalize,
        lastReason: decision.reason,
        lease: FieldValue().delete(),
        finishedAt: FieldValue().serverTimestamp(),
      });
      return { decision };
    }
    if (!decision.claim) return { decision };
    const attempts = (job.attempts || 0) + 1;
    tx.update(ref, {
      status: P.JobStatus.SENDING,
      attempts,
      lease: { id: leaseId, until: Timestamp().fromMillis(nowMs() + P.LEASE_MS) },
    });
    return { decision, job: { ...job, id: jobId, attempts } };
  });

  if (!claim.job) {
    if (claim.decision.reason === 'busy') {
      throw new RetryableDeliveryError(`job ${jobId} is being delivered by another worker`);
    }
    return { status: claim.decision.finalize || 'noop', reason: claim.decision.reason };
  }

  const job = claim.job;
  try {
    // 2. Validate.
    const config = dataOf(await db.doc(CONFIG_PATH).get());
    if (config && config.enabled === false) {
      await finalizeTerminal(db, jobId, leaseId, P.JobStatus.SKIPPED, 'delivery-disabled');
      return { status: P.JobStatus.SKIPPED, reason: 'delivery-disabled' };
    }

    const account = await accountState(job.recipientUid);
    if (account !== 'active') {
      if (account === 'missing') {
        // A deleted account keeps no registrations. Guarded per device, so a
        // token already re-registered by someone else is untouched.
        for (const d of await devicesOf(db, job.recipientUid)) {
          await guardedDeleteDevice(db, {
            deviceId: d.id, uid: job.recipientUid, token: d.token, notAfterMs: nowMs(),
          });
        }
      }
      await finalizeTerminal(db, jobId, leaseId, P.JobStatus.SKIPPED, `account-${account}`);
      return { status: P.JobStatus.SKIPPED, reason: `account-${account}` };
    }

    const validity = await checkValidity(db, job);
    if (!validity.ok) {
      await finalizeTerminal(db, jobId, leaseId, P.JobStatus.SKIPPED, validity.reason);
      return { status: P.JobStatus.SKIPPED, reason: validity.reason };
    }

    const prefs = P.preferencesFrom(dataOf(await db.collection(COL_PREFS).doc(job.recipientUid).get()));
    if (!P.typeEnabled(prefs, job.type)) {
      await finalizeTerminal(db, jobId, leaseId, P.JobStatus.SKIPPED, 'preference-off');
      return { status: P.JobStatus.SKIPPED, reason: 'preference-off' };
    }

    // 3. Targets: current registrations of the recipient, minus devices this
    // job already reached (or permanently failed on), minus abandoned ones.
    const done = job.devices || {};
    const sendStartMs = nowMs();
    const all = await devicesOf(db, job.recipientUid);
    const targets = [];
    for (const d of all) {
      if (typeof d.token !== 'string' || d.uid !== job.recipientUid) continue;
      if (P.deviceIdForToken(d.token) !== d.id) continue;
      if (done[d.id] && done[d.id] !== P.Outcome.TRANSIENT) continue;
      const updated = P.millisOf(d.updatedAt);
      if (updated !== null && sendStartMs - updated > P.STALE_DEVICE_MS) {
        await guardedDeleteDevice(db, {
          deviceId: d.id, uid: d.uid, token: d.token, notAfterMs: updated,
        });
        continue;
      }
      targets.push(d);
    }

    if (targets.length === 0) {
      const anySent = Object.values(done).includes(P.Outcome.SENT);
      const status = anySent ? P.JobStatus.SENT : P.JobStatus.SKIPPED;
      await finalizeTerminal(db, jobId, leaseId, status, anySent ? 'delivered' : 'no-devices');
      return { status, reason: anySent ? 'delivered' : 'no-devices' };
    }

    const actorName = P.displayNameFrom(dataOf(
      await db.collection('users_public').doc(job.actorUid).get(),
    ));
    const rendered = P.renderNotification({
      type: job.type,
      actorName,
      kind: validity.kind,
      text: validity.text,
      previews: prefs.messagePreviews === true,
    });
    const base = P.buildMessage({ job, rendered, nowMs: sendStartMs });

    // 4. Send — outside any transaction.
    let responses;
    try {
      const batch = await messaging.sendEach(targets.map((d) => ({ ...base, token: d.token })));
      responses = batch.responses;
    } catch (err) {
      logger.warn('[push] %s send failed as a whole: %s', jobId, err && (err.code || err.message));
      responses = targets.map(() => ({ success: false, error: { code: (err && err.code) || 'unknown' } }));
    }

    const payloadProvenValid = responses.some((r) => r && r.success);
    const results = {};
    const invalid = [];
    targets.forEach((d, i) => {
      const r = responses[i] || { success: false, error: { code: 'missing-response' } };
      if (r.success) {
        results[d.id] = P.Outcome.SENT;
        return;
      }
      const code = r.error && r.error.code;
      const outcome = P.classifySendError(code, { payloadProvenValid });
      results[d.id] = outcome;
      if (outcome === P.Outcome.INVALID_TOKEN) invalid.push(d);
      logger.info('[push] %s device %s: %s (%s)', jobId, P.tokenLabel(d.token), outcome, code);
    });

    // 5. Record.
    const merged = { ...done, ...results };
    for (const [id, s] of Object.entries(done)) {
      if (s === P.Outcome.SENT) merged[id] = P.Outcome.SENT; // never downgrade
    }
    let status = P.statusAfterAttempt(merged);
    let reason = status === P.JobStatus.SENT ? 'delivered' : status === P.JobStatus.FAILED ? 'all-devices-failed' : 'transient';
    if (status === P.JobStatus.PENDING) {
      const expires = P.millisOf(job.expiresAt);
      if (job.attempts >= P.MAX_ATTEMPTS) {
        status = Object.values(merged).includes(P.Outcome.SENT) ? P.JobStatus.SENT : P.JobStatus.FAILED;
        reason = 'attempts-exhausted';
      } else if (expires !== null && nowMs() >= expires) {
        status = P.JobStatus.EXPIRED;
        reason = 'expired';
      }
    }

    await db.runTransaction(async (tx) => {
      const current = dataOf(await tx.get(ref));
      if (!current) return;
      const update = {};
      for (const [id, s] of Object.entries(results)) {
        const prev = current.devices && current.devices[id];
        if (prev === P.Outcome.SENT) continue;
        update[`devices.${id}`] = s;
      }
      if (current.lease && current.lease.id === leaseId) {
        update.status = status;
        update.lastReason = reason;
        update.lease = FieldValue().delete();
        if (status !== P.JobStatus.PENDING) update.finishedAt = FieldValue().serverTimestamp();
      }
      if (Object.keys(update).length) tx.update(ref, update);
    });

    for (const d of invalid) {
      await guardedDeleteDevice(db, {
        deviceId: d.id, uid: job.recipientUid, token: d.token, notAfterMs: sendStartMs,
      }).catch((err) => logger.warn('[push] %s cleanup of %s failed: %s', jobId, P.tokenLabel(d.token), err.message));
    }

    const sent = Object.values(results).filter((s) => s === P.Outcome.SENT).length;
    logger.info('[push] %s %s: %d/%d sent, status %s', jobId, job.type, sent, targets.length, status);

    if (status === P.JobStatus.PENDING) {
      throw new RetryableDeliveryError(`job ${jobId}: transient failures, will retry`);
    }
    return { status, reason, sent, targeted: targets.length };
  } catch (err) {
    if (err instanceof RetryableDeliveryError) throw err;
    // Unexpected failure mid-attempt: hand the job back so the retry can
    // claim it straight away instead of waiting out the lease.
    await db.runTransaction(async (tx) => {
      const current = dataOf(await tx.get(ref));
      if (current && current.lease && current.lease.id === leaseId) {
        tx.update(ref, { status: P.JobStatus.PENDING, lastReason: 'error', lease: FieldValue().delete() });
      }
    }).catch(() => {});
    throw err;
  }
}

module.exports = {
  COL_OUTBOX,
  COL_DEVICES,
  COL_PREFS,
  CONFIG_PATH,
  RetryableDeliveryError,
  outboxRef,
  newJob,
  enqueueJob,
  enqueueFriendRequest,
  friendAcceptedJob,
  enqueueDirectMessage,
  checkValidity,
  guardedDeleteDevice,
  processJob,
};
