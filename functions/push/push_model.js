// Push notifications — the model, with no Firestore and no FCM in it.
//
// Exactly three notifications exist, and nothing else in the app sends one:
//
//   friendRequest   a request became pending at
//                   users/{receiver}/buddyInvites/{sender}      → the receiver
//   friendAccepted  that request moved pending → accepted and the pair is
//                   mutually accepted                            → the sender
//   directMessage   a message under conversations/{c}/messages became
//                   deliverable (text saved / media attached)    → the other
//                                                                  participant
//
// ── Delivery is keyed by OCCURRENCE, not by document ────────────────────────
// A friend pair reuses the same invite document and the same notice document
// every time they unfriend and ask again, so a document id cannot tell one
// request from the next. The invite's `createdAt` can: every send — the
// buddySendRequest callable and every older installed build — writes a fresh
// `createdAt`, and acceptance (callable merge, crossed-request merge, or the
// legacy client's status-only update) keeps it. So:
//
//   request occurrence   = (receiver, sender, invite.createdAt)
//   accepted occurrence  = (sender, acceptor, invite.createdAt)
//   message occurrence   = (recipient, conversation, message id)
//
// and a job id is a hash of (type, recipient, occurrence). Two deliveries of
// the same Firestore event, a receiver toggling one invite accepted → pending →
// accepted, or a shell message later patched with its URL all land on the SAME
// job id, and a job is created once.
//
// Only the enqueueing is exactly-once. FCM delivery is at-least-once at best —
// see outbox.js for the send-versus-record window.

'use strict';

const crypto = require('node:crypto');

const PushType = {
  FRIEND_REQUEST: 'friendRequest',
  FRIEND_ACCEPTED: 'friendAccepted',
  DIRECT_MESSAGE: 'directMessage',
};

const ALL_TYPES = Object.values(PushType);

/** Preference field that switches each type on and off. */
const PREFERENCE_FIELD = {
  [PushType.FRIEND_REQUEST]: 'friendRequests',
  [PushType.FRIEND_ACCEPTED]: 'friendAccepted',
  [PushType.DIRECT_MESSAGE]: 'directMessages',
};

/** Android notification channel per type. Mirrors MainActivity.kt. */
const ANDROID_CHANNEL = {
  [PushType.FRIEND_REQUEST]: 'goodlift_friend_requests',
  [PushType.FRIEND_ACCEPTED]: 'goodlift_friend_accepted',
  [PushType.DIRECT_MESSAGE]: 'goodlift_direct_messages',
};

const ANDROID_ICON = 'ic_stat_goodlift';

const HOUR_MS = 60 * 60 * 1000;

/**
 * How long a job may still be delivered after its event. A social alert that
 * arrives a day late is noise, and FCM would otherwise hold a message for an
 * offline device for up to 28 days — so the same deadline bounds our retries
 * AND is handed to FCM/APNs as the message's own expiry.
 */
const DELIVERY_WINDOW_MS = {
  [PushType.FRIEND_REQUEST]: 24 * HOUR_MS,
  [PushType.FRIEND_ACCEPTED]: 24 * HOUR_MS,
  [PushType.DIRECT_MESSAGE]: 12 * HOUR_MS,
};

/** Outbox documents are removed by a Firestore TTL policy on `purgeAt`. */
const PURGE_AFTER_MS = 7 * 24 * HOUR_MS;

/** Attempts before a job with only transient failures is given up. */
const MAX_ATTEMPTS = 8;

/** A worker's claim on a job. Longer than one send, far shorter than a retry. */
const LEASE_MS = 90 * 1000;

/** At most this many registrations are sent to per recipient. */
const MAX_DEVICES = 20;

/**
 * A registration not refreshed for this long is treated as abandoned. The app
 * refreshes weekly while it is used; FCM itself treats a month of silence as
 * stale. Sixty days leaves room for a phone left in a drawer.
 */
const STALE_DEVICE_MS = 60 * 24 * HOUR_MS;

const DM_PREVIEW_MAX = 120;

// ── Identity ────────────────────────────────────────────────────────────────

function sha256Hex(s) {
  return crypto.createHash('sha256').update(String(s), 'utf8').digest('hex');
}

/**
 * Registration document id for [token]: lowercase hex SHA-256. The rules bind
 * the id to the token, so one token has exactly one document, and therefore
 * exactly one owning account at a time.
 */
function deviceIdForToken(token) {
  return sha256Hex(token);
}

/** Short, non-reversible token label for logs. Never log a whole token. */
function tokenLabel(token) {
  return sha256Hex(token).slice(0, 10);
}

function isNonEmptyString(v) {
  return typeof v === 'string' && v.trim().length > 0;
}

function isTimestamp(v) {
  return (
    !!v &&
    typeof v === 'object' &&
    typeof v.seconds === 'number' &&
    typeof v.nanoseconds === 'number'
  );
}

function millisOf(v) {
  if (!v) return null;
  if (typeof v.toMillis === 'function') return v.toMillis();
  if (v instanceof Date) return v.getTime();
  if (isTimestamp(v)) return v.seconds * 1000 + Math.floor(v.nanoseconds / 1e6);
  return null;
}

/**
 * The identity of one friend-request occurrence: its `createdAt`, to the
 * nanosecond. Falls back to the triggering event id for an invite written
 * without one (no current or historical client does that, but a hand-edited
 * document might).
 */
function inviteOccurrence(inviteData, eventId) {
  const c = inviteData && inviteData.createdAt;
  if (isTimestamp(c)) {
    return `c:${c.seconds}.${String(c.nanoseconds).padStart(9, '0')}`;
  }
  return `e:${eventId || 'unknown'}`;
}

/** Deterministic outbox id for one notification occurrence. */
function jobIdFor(type, recipientUid, occurrence) {
  const short = {
    [PushType.FRIEND_REQUEST]: 'fr',
    [PushType.FRIEND_ACCEPTED]: 'fa',
    [PushType.DIRECT_MESSAGE]: 'dm',
  }[type];
  if (!short) throw new Error(`unknown push type ${type}`);
  return `${short}_${sha256Hex(`${type}|${recipientUid}|${occurrence}`).slice(0, 40)}`;
}

// ── Friend requests ─────────────────────────────────────────────────────────

/**
 * True when an invite write is a request becoming pending: created pending,
 * or re-sent over a declined/accepted document. pending → pending (a repeated
 * Add is a no-op, a repair touching other fields) is NOT a new request.
 */
function isNewPendingRequest(beforeData, afterData) {
  if (!afterData || afterData.status !== 'pending') return false;
  return !beforeData || beforeData.status !== 'pending';
}

/** The invite names the path's own parties (never re-addressed). */
function inviteMatchesPath(data, receiverUid, senderUid) {
  if (!data) return false;
  if (!receiverUid || !senderUid || receiverUid === senderUid) return false;
  if (data.fromUid !== undefined && data.fromUid !== senderUid) return false;
  if (data.buddyUid !== undefined && data.buddyUid !== receiverUid) return false;
  return true;
}

// ── Direct messages ─────────────────────────────────────────────────────────

/**
 * The two participants named by a conversation id: `uidA_uidB`, sorted. The
 * rules slice a 57-character id at 28/29; other shapes (none exist) split on
 * the single underscore. Anything else is not a conversation we deliver for.
 */
function parseConversationId(convId) {
  if (typeof convId !== 'string') return null;
  let a;
  let b;
  if (convId.length === 57 && convId[28] === '_') {
    a = convId.slice(0, 28);
    b = convId.slice(29);
  } else {
    const parts = convId.split('_');
    if (parts.length !== 2) return null;
    [a, b] = parts;
  }
  if (!a || !b || a === b) return null;
  return [a, b];
}

/** photo | video | text | null (not deliverable yet). */
function messageKind(data) {
  if (!data || typeof data !== 'object') return null;
  if (isNonEmptyString(data.videoUrl)) return 'video';
  if (isNonEmptyString(data.imageUrl)) return 'photo';
  const type = data.type;
  if (type === 'image' || type === 'video') return null; // shell, upload pending
  if (isNonEmptyString(data.text)) return 'text';
  return null;
}

/**
 * A message is deliverable once a person would see something in it: text that
 * was saved, or a photo/video whose upload finished and was attached. The
 * shell the app writes BEFORE a media upload is not deliverable, so a failed
 * upload never notifies.
 */
function isDeliverable(data) {
  return messageKind(data) !== null;
}

/**
 * True exactly once per message: on the write that first makes it
 * deliverable. A reaction, a read receipt, a URL rewrite or a retry of an
 * already-deliverable message is not a transition.
 */
function becameDeliverable(beforeData, afterData) {
  return !isDeliverable(beforeData) && isDeliverable(afterData);
}

/**
 * Who a message goes to, validated against the conversation. Returns
 * `{ senderUid, recipientUid }` or `{ reason }`.
 */
function resolveDmParties({ convId, messageData, conversationData }) {
  const pair = parseConversationId(convId);
  if (!pair) return { reason: 'bad-conversation-id' };
  const senderUid = messageData && messageData.senderId;
  if (!isNonEmptyString(senderUid)) return { reason: 'no-sender' };
  if (!pair.includes(senderUid)) return { reason: 'sender-not-in-conversation' };
  const recipientUid = pair[0] === senderUid ? pair[1] : pair[0];
  if (conversationData) {
    const p = conversationData.participants;
    if (!p || typeof p !== 'object') return { reason: 'no-participants' };
    const keys = Object.keys(p);
    if (
      keys.length !== 2 ||
      !keys.includes(pair[0]) ||
      !keys.includes(pair[1]) ||
      p[pair[0]] !== true ||
      p[pair[1]] !== true
    ) {
      return { reason: 'participants-mismatch' };
    }
  }
  return { senderUid, recipientUid };
}

// ── Preferences ─────────────────────────────────────────────────────────────

const DEFAULT_PREFERENCES = Object.freeze({
  friendRequests: true,
  friendAccepted: true,
  directMessages: true,
  messagePreviews: false,
});

function preferencesFrom(data) {
  const d = data && typeof data === 'object' ? data : {};
  const out = { ...DEFAULT_PREFERENCES };
  for (const k of Object.keys(DEFAULT_PREFERENCES)) {
    if (typeof d[k] === 'boolean') out[k] = d[k];
  }
  return out;
}

function typeEnabled(prefs, type) {
  const field = PREFERENCE_FIELD[type];
  return !!field && prefs[field] !== false;
}

// ── Presentation ────────────────────────────────────────────────────────────

/** Best human name from a users_public document — the app's bestName order. */
function displayNameFrom(publicData) {
  const d = publicData || {};
  for (const k of ['displayName', 'fullName', 'username']) {
    if (isNonEmptyString(d[k])) return d[k].trim().slice(0, 60);
  }
  return 'A GoodLift member';
}

function truncate(text, max) {
  const runes = Array.from(String(text).replace(/\s+/g, ' ').trim());
  if (runes.length <= max) return runes.join('');
  return `${runes.slice(0, max - 1).join('')}…`;
}

/**
 * Title and body. Message text is included ONLY when the recipient turned
 * previews on; otherwise it never enters the payload at all, so it cannot
 * appear on a lock screen, in a notification log, or on a watch.
 */
function renderNotification({ type, actorName, kind, text, previews }) {
  const name = actorName || 'A GoodLift member';
  switch (type) {
    case PushType.FRIEND_REQUEST:
      return { title: 'Friend request', body: `${name} sent you a friend request` };
    case PushType.FRIEND_ACCEPTED:
      return { title: 'Friend request accepted', body: `${name} accepted your friend request` };
    case PushType.DIRECT_MESSAGE: {
      if (previews) {
        if (kind === 'photo') return { title: name, body: '📷 Photo' };
        if (kind === 'video') return { title: name, body: '🎬 Video' };
        return { title: name, body: truncate(text || '', DM_PREVIEW_MAX) || 'New message' };
      }
      const what = kind === 'photo' ? 'a photo' : kind === 'video' ? 'a video' : 'a message';
      return { title: 'New message', body: `${name} sent you ${what}` };
    }
    default:
      throw new Error(`unknown push type ${type}`);
  }
}

/**
 * Stable presentation id: Android `tag` and APNs `apns-collapse-id`. A second
 * delivery of the same occurrence REPLACES the banner instead of stacking a
 * duplicate. Per message for DMs (so two real messages are two banners), per
 * person for the social pair (a newer request from the same person replaces
 * an older one).
 */
function presentationTag(job) {
  switch (job.type) {
    case PushType.FRIEND_REQUEST:
      return `fr_${job.actorUid}`;
    case PushType.FRIEND_ACCEPTED:
      return `fa_${job.actorUid}`;
    case PushType.DIRECT_MESSAGE:
      // `dm|<conversation>|<message>`. The conversation part lets the app
      // cancel exactly one thread's delivered alerts when that thread is
      // read — including alerts the OS posted while the app was not running,
      // which it can only match by tag. Hashed and truncated because an APNs
      // collapse id is limited to 64 bytes and a conversation id is 57.
      // Mirrored by dmConversationTagPrefix in lib/push/push_intent.dart.
      return `dm|${conversationTagKey(job.conversationId)}|${job.messageId}`;
    default:
      return job.id;
  }
}

/** Short, stable key for a conversation id inside a notification tag. */
function conversationTagKey(conversationId) {
  return sha256Hex(String(conversationId)).slice(0, 8);
}

/** Routing data the app needs to open the right screen. Strings only. */
function routingData(job) {
  const data = {
    v: '1',
    type: job.type,
    recipientUid: job.recipientUid,
    actorUid: job.actorUid,
  };
  if (job.type === PushType.DIRECT_MESSAGE) {
    data.convId = job.conversationId;
    // The message this alert is about, so the app can cancel exactly it and
    // can tell an already-read message from a new one before showing a
    // foreground banner. Older payloads carry neither; the app copes.
    if (job.messageId) data.msgId = String(job.messageId);
    if (Number.isFinite(job.incomingSeq)) data.seq = String(job.incomingSeq);
  }
  return data;
}

/**
 * One FCM message (without the token). A user-visible notification — the OS
 * shows it in the background and when the app is killed — carrying routing
 * data for the tap. Expiry is the job's own deadline, so FCM and APNs discard
 * it rather than delivering a stale alert when a phone reconnects days later.
 */
function buildMessage({ job, rendered, nowMs }) {
  const expiresMs = millisOf(job.expiresAt);
  const ttlMs = Math.max(0, (expiresMs || nowMs) - nowMs);
  const tag = presentationTag(job);
  return {
    notification: { title: rendered.title, body: rendered.body },
    data: routingData(job),
    android: {
      priority: 'high',
      ttl: ttlMs,
      notification: {
        channelId: ANDROID_CHANNEL[job.type],
        tag,
        icon: ANDROID_ICON,
      },
    },
    apns: {
      headers: {
        'apns-priority': '10',
        'apns-push-type': 'alert',
        'apns-expiration': String(Math.floor((expiresMs || nowMs) / 1000)),
        'apns-collapse-id': tag,
      },
      payload: {
        aps: {
          sound: 'default',
          'thread-id': job.type === PushType.DIRECT_MESSAGE ? `dm_${job.conversationId}` : job.type,
        },
      },
    },
  };
}

// ── FCM results ─────────────────────────────────────────────────────────────

const Outcome = {
  SENT: 'sent',
  INVALID_TOKEN: 'invalid', // delete the registration (guarded)
  PERMANENT: 'failed', // do not retry this device for this job
  TRANSIENT: 'retry', // retry this device later
};

const INVALID_TOKEN_CODES = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
  'messaging/mismatched-credential',
  'messaging/sender-id-mismatch',
]);

const PERMANENT_CODES = new Set([
  // APNs rejected OUR credentials (missing/invalid APNs key in Firebase).
  // Retrying cannot fix it and the token is not at fault.
  'messaging/third-party-auth-error',
  'messaging/payload-size-limit-exceeded',
  'messaging/invalid-package-name',
  'messaging/invalid-apns-credentials',
]);

/**
 * Classifies one send error. `messaging/invalid-argument` means a bad token
 * only when the SAME payload succeeded for another device (FCM: INVALID_ARGUMENT
 * "signals an invalid registration only if the payload is completely valid");
 * otherwise it is a permanent failure that must not delete anything.
 */
function classifySendError(code, { payloadProvenValid } = {}) {
  if (INVALID_TOKEN_CODES.has(code)) return Outcome.INVALID_TOKEN;
  if (code === 'messaging/invalid-argument') {
    return payloadProvenValid ? Outcome.INVALID_TOKEN : Outcome.PERMANENT;
  }
  if (PERMANENT_CODES.has(code)) return Outcome.PERMANENT;
  return Outcome.TRANSIENT;
}

/** Terminal job states. */
const JobStatus = {
  PENDING: 'pending',
  SENDING: 'sending',
  SENT: 'sent',
  SKIPPED: 'skipped',
  EXPIRED: 'expired',
  FAILED: 'failed',
};

const TERMINAL = new Set([JobStatus.SENT, JobStatus.SKIPPED, JobStatus.EXPIRED, JobStatus.FAILED]);

/**
 * Whether a worker may claim [job] now. Pure; the caller runs it inside the
 * claim transaction.
 */
function claimDecision(job, nowMs) {
  if (!job) return { claim: false, reason: 'missing' };
  if (TERMINAL.has(job.status)) return { claim: false, reason: 'done' };
  const expires = millisOf(job.expiresAt);
  if (expires !== null && nowMs >= expires) return { claim: false, reason: 'expired', finalize: JobStatus.EXPIRED };
  if ((job.attempts || 0) >= MAX_ATTEMPTS) return { claim: false, reason: 'attempts-exhausted', finalize: JobStatus.FAILED };
  const leaseUntil = millisOf(job.lease && job.lease.until);
  if (job.status === JobStatus.SENDING && leaseUntil !== null && leaseUntil > nowMs) {
    return { claim: false, reason: 'busy' };
  }
  return { claim: true, reason: job.status === JobStatus.SENDING ? 'lease-expired' : 'claimable' };
}

/**
 * The job's status after one attempt, given every targeted device's outcome
 * (including ones delivered on earlier attempts).
 */
function statusAfterAttempt(deviceStates) {
  const states = Object.values(deviceStates || {});
  if (states.some((s) => s === Outcome.TRANSIENT)) return JobStatus.PENDING;
  if (states.some((s) => s === Outcome.SENT)) return JobStatus.SENT;
  return JobStatus.FAILED;
}

module.exports = {
  PushType,
  ALL_TYPES,
  PREFERENCE_FIELD,
  ANDROID_CHANNEL,
  ANDROID_ICON,
  DELIVERY_WINDOW_MS,
  PURGE_AFTER_MS,
  MAX_ATTEMPTS,
  LEASE_MS,
  MAX_DEVICES,
  STALE_DEVICE_MS,
  DEFAULT_PREFERENCES,
  Outcome,
  JobStatus,
  sha256Hex,
  deviceIdForToken,
  tokenLabel,
  millisOf,
  inviteOccurrence,
  jobIdFor,
  isNewPendingRequest,
  inviteMatchesPath,
  parseConversationId,
  messageKind,
  isDeliverable,
  becameDeliverable,
  resolveDmParties,
  preferencesFrom,
  typeEnabled,
  displayNameFrom,
  renderNotification,
  presentationTag,
  conversationTagKey,
  routingData,
  buildMessage,
  classifySendError,
  claimDecision,
  statusAfterAttempt,
};
