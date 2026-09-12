'use strict';

// The unread ledger against the Firestore emulator, through the exact
// functions the DM trigger and the delivery worker call. FCM is mocked; no
// message leaves this machine.
//
//   npm run test:emulator

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

let U; // push/dm_unread
let O; // push/outbox

test.before(() => {
  assert.ok(
    process.env.FIRESTORE_EMULATOR_HOST,
    'FIRESTORE_EMULATOR_HOST must be set — run through `npm run test:emulator`',
  );
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  }
  U = require('../push/dm_unread');
  O = require('../push/outbox');
});

const db = () => admin.firestore();
let seq = 0;
function pair() {
  seq += 1;
  const stamp = `${Date.now().toString(36)}${seq}`;
  const a = `alice${stamp}`.padEnd(28, 'z').slice(0, 28);
  const b = `bob${stamp}`.padEnd(28, 'z').slice(0, 28);
  return { a, b, convId: [a, b].sort().join('_') };
}

async function befriend(a, b) {
  await db().doc(`buddyAssignments/${a}`).set({ athletes: { [b]: { status: 'accepted' } } }, { merge: true });
  await db().doc(`buddyAssignments/${b}`).set({ athletes: { [a]: { status: 'accepted' } } }, { merge: true });
}

async function openConversation(p, extraState) {
  await db().doc(`conversations/${p.convId}`).set({
    participants: { [p.a]: true, [p.b]: true },
    participantState: { [p.a]: { unreadCount: 0 }, [p.b]: { unreadCount: 0 }, ...(extraState || {}) },
  });
}

const text = (from, body = 'hi') => ({ senderId: from, type: 'text', text: body });

/**
 * Writes a message and runs the enqueue path exactly as the trigger does.
 *
 * Merges, like the app: a message is created once and then only patched (the
 * media URL, a reaction). firestore.rules also stops a client from removing
 * the server's `incomingSeq`, so the stamp survives every client write.
 */
async function deliver(p, id, data, before = null) {
  await db().doc(`conversations/${p.convId}/messages/${id}`).set(data, { merge: true });
  return O.enqueueDirectMessage(db(), {
    convId: p.convId,
    messageId: id,
    beforeData: before,
    afterData: data,
    eventId: `evt-${id}-${Math.random()}`,
  });
}

async function convData(p) {
  return (await db().doc(`conversations/${p.convId}`).get()).data();
}

// ── Counting ────────────────────────────────────────────────────────────────

test('each deliverable message counts once, for the recipient only', async () => {
  const p = pair();
  await befriend(p.a, p.b);
  await openConversation(p);

  await deliver(p, 'm1', text(p.b));
  await deliver(p, 'm2', text(p.b));
  let c = await convData(p);
  assert.equal(U.unreadFor(c, p.a), 2);
  assert.equal(U.unreadFor(c, p.b), 0, 'the sender is never unread');

  // Alice replies: her own message does not make her unread, and it counts
  // for Bob.
  await deliver(p, 'm3', text(p.a));
  c = await convData(p);
  assert.equal(U.unreadFor(c, p.a), 2);
  assert.equal(U.unreadFor(c, p.b), 1);
});

test('photo and video count when the upload finishes — shells and failures never do', async () => {
  const p = pair();
  await befriend(p.a, p.b);
  await openConversation(p);

  const shell = { senderId: p.b, type: 'image', text: '' };
  assert.equal((await deliver(p, 'img', shell)).enqueued, false);
  assert.equal(U.unreadFor(await convData(p), p.a), 0, 'an empty shell is not a message');

  // A second upload that never completes.
  await deliver(p, 'failed', { senderId: p.b, type: 'video', text: '' });

  const ready = { ...shell, imageUrl: 'https://x/i.jpg' };
  await deliver(p, 'img', ready, shell);
  assert.equal(U.unreadFor(await convData(p), p.a), 1);

  const vid = { senderId: p.b, type: 'video', text: '' };
  await deliver(p, 'vid', vid);
  await deliver(p, 'vid', { ...vid, videoUrl: 'https://x/v.mp4' }, vid);
  assert.equal(U.unreadFor(await convData(p), p.a), 2);

  // Reactions, read receipts and a re-uploaded URL are not new messages.
  await deliver(p, 'img', { ...ready, reactions: { [p.a]: '🔥' } }, ready);
  await deliver(p, 'img', { ...ready, imageUrl: 'https://x/i2.jpg' }, ready);
  assert.equal(U.unreadFor(await convData(p), p.a), 2);
});

test('counting is idempotent across retries, duplicates and concurrency', async () => {
  const p = pair();
  await befriend(p.a, p.b);
  await openConversation(p);
  const msg = text(p.b);
  await db().doc(`conversations/${p.convId}/messages/m1`).set(msg);

  const runs = await Promise.all([
    U.countIncomingMessage(db(), { convId: p.convId, messageId: 'm1', recipientUid: p.a }),
    U.countIncomingMessage(db(), { convId: p.convId, messageId: 'm1', recipientUid: p.a }),
    U.countIncomingMessage(db(), { convId: p.convId, messageId: 'm1', recipientUid: p.a }),
  ]);
  assert.deepEqual(runs, [1, 1, 1], 'one message, one position');
  assert.equal(U.unreadFor(await convData(p), p.a), 1);

  // The same event redelivered through the whole enqueue path.
  await deliver(p, 'm1', msg);
  await deliver(p, 'm1', msg);
  assert.equal(U.unreadFor(await convData(p), p.a), 1);

  const stored = (await db().doc(`conversations/${p.convId}/messages/m1`).get()).data();
  assert.equal(stored.incomingSeq, 1);
});

test('two messages arriving at once get distinct positions', async () => {
  const p = pair();
  await befriend(p.a, p.b);
  await openConversation(p);
  await db().doc(`conversations/${p.convId}/messages/x1`).set(text(p.b));
  await db().doc(`conversations/${p.convId}/messages/x2`).set(text(p.b));
  const [s1, s2] = await Promise.all([
    U.countIncomingMessage(db(), { convId: p.convId, messageId: 'x1', recipientUid: p.a }),
    U.countIncomingMessage(db(), { convId: p.convId, messageId: 'x2', recipientUid: p.a }),
  ]);
  assert.deepEqual([s1, s2].sort(), [1, 2]);
  assert.equal(U.unreadFor(await convData(p), p.a), 2);
});

test('unread from before the ledger is carried over, not lost', async () => {
  const p = pair();
  await befriend(p.a, p.b);
  // An installed build left three unread messages behind.
  await openConversation(p, { [p.a]: { unreadCount: 3 } });
  assert.equal(U.unreadFor(await convData(p), p.a), 3, 'legacy count still shows');

  await deliver(p, 'new1', text(p.b));
  const c = await convData(p);
  assert.equal(U.incomingTotal(c, p.a), 4);
  assert.equal(U.unreadFor(c, p.a), 4, 'three old plus the new one');
});

// ── Reading ─────────────────────────────────────────────────────────────────

/** What the app writes when a chat displays up to [upTo]. */
async function acknowledge(p, uid, upTo) {
  await db().doc(`conversations/${p.convId}`).update({
    [`participantState.${uid}.readIncoming`]: upTo,
    [`participantState.${uid}.unreadCount`]: 0,
  });
}

test('reading one conversation clears only its own count', async () => {
  const one = pair();
  const two = { ...pair(), a: null };
  // Two conversations for the same person: B sends 3, C sends 2.
  const me = one.a;
  const c = `carol${Date.now().toString(36)}`.padEnd(28, 'z').slice(0, 28);
  const convWithC = [me, c].sort().join('_');
  await befriend(me, one.b);
  await befriend(me, c);
  await openConversation(one);
  await db().doc(`conversations/${convWithC}`).set({
    participants: { [me]: true, [c]: true },
    participantState: { [me]: { unreadCount: 0 }, [c]: { unreadCount: 0 } },
  });
  const withC = { a: me, b: c, convId: convWithC };

  for (const id of ['b1', 'b2', 'b3']) await deliver(one, id, text(one.b));
  for (const id of ['c1', 'c2']) await deliver(withC, id, text(c));

  assert.equal(U.unreadFor(await convData(one), me), 3);
  assert.equal(U.unreadFor(await convData(withC), me), 2);

  // Reading B's conversation.
  await acknowledge(one, me, 3);
  assert.equal(U.unreadFor(await convData(one), me), 0);
  assert.equal(U.unreadFor(await convData(withC), me), 2, "C's messages are untouched");

  // Then C's.
  await acknowledge(withC, me, 2);
  assert.equal(U.unreadFor(await convData(withC), me), 0);
  assert.ok(two);
});

test('a message arriving during the acknowledgement is not swallowed', async () => {
  const p = pair();
  await befriend(p.a, p.b);
  await openConversation(p);
  for (const id of ['m1', 'm2']) await deliver(p, id, text(p.b));

  // The chat displayed two messages; a third lands before the write.
  await deliver(p, 'm3', text(p.b));
  await acknowledge(p, p.a, 2); // the position actually displayed

  const c = await convData(p);
  assert.equal(U.unreadFor(c, p.a), 1, 'the message that arrived stays unread');
  assert.equal(U.isAcknowledged(c, p.a, 3), false);
});

// ── Delivery ────────────────────────────────────────────────────────────────

function fakeMessaging() {
  const calls = [];
  return {
    calls,
    async sendEach(messages) {
      for (const m of messages) calls.push(m);
      return { responses: messages.map(() => ({ success: true, messageId: 'x' })) };
    },
  };
}

async function register(uid, token) {
  const crypto = require('node:crypto');
  const id = crypto.createHash('sha256').update(token).digest('hex');
  await db().doc(`pushDevices/${id}`).set({
    uid, token, platform: 'android', updatedAt: admin.firestore.Timestamp.now(),
  });
}

test('a queued push for an already-read message is skipped', async () => {
  const p = pair();
  await befriend(p.a, p.b);
  await openConversation(p);
  await register(p.a, `tok-${p.a}`);
  const r = await deliver(p, 'm1', text(p.b));
  assert.equal(r.incomingSeq, 1);

  // Read in the app before the worker ran.
  await acknowledge(p, p.a, 1);

  const fcm = fakeMessaging();
  const res = await O.processJob(db(), r.jobId, { messaging: fcm, accountState: async () => 'active' });
  assert.equal(res.reason, 'already-read');
  assert.equal(fcm.calls.length, 0);
});

test('a NEW message is still delivered when its counter write has not landed', async () => {
  const p = pair();
  await befriend(p.a, p.b);
  await openConversation(p);
  await register(p.a, `tok-${p.a}`);

  // Everything so far has been read…
  await deliver(p, 'm1', text(p.b));
  await acknowledge(p, p.a, 1);
  // …and a new message arrives. Its own position is 2, which has NOT been
  // acknowledged — even though a stale zero unreadCount is sitting there.
  await db().doc(`conversations/${p.convId}`).update({ [`participantState.${p.a}.unreadCount`]: 0 });
  const r = await deliver(p, 'm2', text(p.b));
  assert.equal(r.incomingSeq, 2);

  const fcm = fakeMessaging();
  const res = await O.processJob(db(), r.jobId, { messaging: fcm, accountState: async () => 'active' });
  assert.equal(res.status, 'sent');
  assert.equal(fcm.calls.length, 1);
  assert.equal(fcm.calls[0].data.msgId, 'm2');
  assert.equal(fcm.calls[0].data.seq, '2');
  assert.ok(fcm.calls[0].android.notification.tag.startsWith('dm|'));
});

test('reading between retries stops the retry', async () => {
  const p = pair();
  await befriend(p.a, p.b);
  await openConversation(p);
  await register(p.a, `tok-fail-${p.a}`);
  const r = await deliver(p, 'm1', text(p.b));

  // First attempt fails transiently.
  const failing = {
    calls: [],
    async sendEach(messages) {
      for (const m of messages) failing.calls.push(m);
      return { responses: messages.map(() => ({ success: false, error: { code: 'messaging/server-unavailable' } })) };
    },
  };
  await assert.rejects(
    O.processJob(db(), r.jobId, { messaging: failing, accountState: async () => 'active' }),
    O.RetryableDeliveryError,
  );
  assert.equal(failing.calls.length, 1);

  // The person reads the conversation before the retry runs.
  await acknowledge(p, p.a, 1);
  const fcm = fakeMessaging();
  const res = await O.processJob(db(), r.jobId, { messaging: fcm, accountState: async () => 'active' });
  assert.equal(res.reason, 'already-read');
  assert.equal(fcm.calls.length, 0);
});
