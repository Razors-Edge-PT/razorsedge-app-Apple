// Who has read which direct messages — the server-owned half.
//
// ── Why the server counts ───────────────────────────────────────────────────
// The unread number used to be maintained entirely by clients: the SENDER's
// app incremented the recipient's `participantState.{uid}.unreadCount` (text
// only — the photo and video paths never did), and the READER's app wrote a
// flat 0 back. That loses messages in both directions: media never counted,
// and a blind 0 erased anything that arrived while the chat was opening.
//
// Counting here instead makes ONE writer responsible, on the same event that
// already decides a message is deliverable (push/triggers.js), so text, a
// finished photo upload and a finished video upload all count exactly once,
// while upload shells, failed uploads, reactions, read receipts and URL
// rewrites count never.
//
// ── The ledger ──────────────────────────────────────────────────────────────
//   conversations/{c}.participantState.{recipient}.incoming    server-owned,
//       monotonic count of deliverable messages addressed to that person
//   conversations/{c}/messages/{m}.incomingSeq                 that message's
//       position in the ledger — its "this is message number N for you"
//   conversations/{c}.participantState.{me}.readIncoming       the client's
//       acknowledgement: the highest incomingSeq it has actually DISPLAYED
//
//   unread = max(0, incoming - readIncoming)
//
// The sequence is stamped onto the message itself, so a redelivered event or a
// concurrent invocation re-uses it instead of counting the message twice; and
// because acknowledgement names a sequence rather than resetting a counter, a
// message that arrives while the chat is being opened simply has a higher
// sequence and stays unread. firestore.rules keeps clients out of both
// server-owned fields.
//
// ── Existing conversations ──────────────────────────────────────────────────
// The ledger starts at whatever the legacy counter says the first time a
// message is counted, so unread messages from before this release are carried
// over once rather than being silently zeroed.

'use strict';

const admin = require('firebase-admin');

const COL_CONVERSATIONS = 'conversations';

function toInt(value) {
  return typeof value === 'number' && Number.isFinite(value) ? Math.floor(value) : 0;
}

/** `participantState.{uid}` of a conversation document, never null. */
function participantEntry(convData, uid) {
  const state = convData && convData.participantState;
  const entry = state && typeof state === 'object' ? state[uid] : null;
  return entry && typeof entry === 'object' ? entry : {};
}

/** The recipient's ledger position: how many messages they have been sent. */
function incomingTotal(convData, uid) {
  return toInt(participantEntry(convData, uid).incoming);
}

/** How far the recipient has acknowledged reading. */
function readIncoming(convData, uid) {
  return toInt(participantEntry(convData, uid).readIncoming);
}

/** Legacy client counter, used once to seed the ledger. */
function legacyUnread(convData, uid) {
  return toInt(participantEntry(convData, uid).unreadCount);
}

function unreadFor(convData, uid) {
  const total = incomingTotal(convData, uid);
  if (total <= 0) return legacyUnread(convData, uid);
  return Math.max(0, total - readIncoming(convData, uid));
}

/**
 * True when [seq] has already been acknowledged by [uid] — i.e. that exact
 * message has been displayed to them.
 *
 * Deliberately NOT "unread == 0": the message write and the counter write
 * reach Firestore separately, so a brand-new message can momentarily coexist
 * with a zero counter. Only the sequence proves this message was seen.
 */
function isAcknowledged(convData, uid, seq) {
  if (!Number.isFinite(seq) || seq <= 0) return false;
  return readIncoming(convData, uid) >= seq;
}

/**
 * Counts one deliverable message for its recipient, exactly once, and returns
 * its sequence.
 *
 * Idempotent: the sequence lives on the message, so a retry, a duplicate
 * event or a concurrent invocation returns the existing number and leaves the
 * ledger alone. Returns null when the conversation is gone.
 */
async function countIncomingMessage(db, { convId, messageId, recipientUid }) {
  const convRef = db.collection(COL_CONVERSATIONS).doc(convId);
  const msgRef = convRef.collection('messages').doc(messageId);

  return db.runTransaction(async (tx) => {
    const [convSnap, msgSnap] = await Promise.all([tx.get(convRef), tx.get(msgRef)]);
    if (!convSnap.exists || !msgSnap.exists) return null;

    const existing = toInt(msgSnap.data().incomingSeq);
    if (existing > 0) return existing;

    const convData = convSnap.data();
    const current = incomingTotal(convData, recipientUid);
    // First count on a conversation that predates the ledger: carry the
    // legacy unread number over so those messages are not lost.
    const base = current > 0 ? current : legacyUnread(convData, recipientUid);
    const seq = base + 1;

    tx.update(msgRef, { incomingSeq: seq });
    tx.set(
      convRef,
      {
        participantState: {
          [recipientUid]: {
            incoming: seq,
            incomingUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
        },
      },
      { merge: true },
    );
    return seq;
  });
}

module.exports = {
  COL_CONVERSATIONS,
  participantEntry,
  incomingTotal,
  readIncoming,
  legacyUnread,
  unreadFor,
  isAcknowledged,
  countIncomingMessage,
};
