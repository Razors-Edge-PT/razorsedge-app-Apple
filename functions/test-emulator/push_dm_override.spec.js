'use strict';

// Direct-message alerts with the support profile + DM override, against the
// Firestore emulator:
//   npm run test:emulator
//
// A DM is delivered between mutual friends — or when either participant
// holds accessGrants/{uid}.profileAndDmOverride. Nothing else changes: an
// ordinary non-friend pair is still dropped as 'not-friends', and so is a
// pair whose holder lost the grant before delivery.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const admin = require('firebase-admin');

let O;

test.before(() => {
  assert.ok(
    process.env.FIRESTORE_EMULATOR_HOST,
    'FIRESTORE_EMULATOR_HOST must be set — run through `npm run test:emulator`',
  );
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  }
  O = require('../push/outbox');
});

const db = () => admin.firestore();
const sha = (t) => crypto.createHash('sha256').update(t, 'utf8').digest('hex');
const TEST_ACCOUNT = 'jhIB7Yi1whYwPvBSmK27KltJGn23';

let seq = 0;
function people(...names) {
  seq += 1;
  const stamp = `${Date.now().toString(36)}${seq}`;
  const out = {};
  for (const n of names) out[n] = `${n}${stamp}`.padEnd(28, 'o').slice(0, 28);
  return out;
}
const convIdFor = (a, b) => [a, b].sort().join('_');

async function register(uid) {
  const token = `tok-${uid}`;
  await db().doc(`pushDevices/${sha(token)}`).set({
    uid, token, platform: 'android', appVersion: 'test',
    updatedAt: admin.firestore.Timestamp.now(),
  });
  return token;
}

async function grant(uid, on = true) {
  await db().doc(`accessGrants/${uid}`).set({ profileAndDmOverride: on });
}

async function openConversation(a, b) {
  const cid = convIdFor(a, b);
  await db().doc(`conversations/${cid}`).set({
    participants: { [a]: true, [b]: true },
    participantList: [a, b].sort(),
    participantState: { [a]: { unreadCount: 0 }, [b]: { unreadCount: 0 } },
  });
  return cid;
}

async function send(cid, id, senderId) {
  const data = { senderId, type: 'text', text: 'hello' };
  await db().doc(`conversations/${cid}/messages/${id}`).set(data);
  return O.enqueueDirectMessage(db(), {
    convId: cid, messageId: id, beforeData: null, afterData: data, eventId: `evt-${cid}-${id}`,
  });
}

function fakeMessaging() {
  const calls = [];
  return {
    calls,
    async sendEach(messages) {
      for (const m of messages) calls.push(m);
      return {
        responses: messages.map((_, i) => ({ success: true, messageId: `m/${i}` })),
        successCount: messages.length,
      };
    },
  };
}

const run = (jobId, messaging) =>
  O.processJob(db(), jobId, { messaging, accountState: async () => 'active' });

test('holder → non-friend: delivered; and the reply back is delivered too', async () => {
  const u = people('holder', 'athlete');
  await grant(u.holder);
  const tokAthlete = await register(u.athlete);
  const tokHolder = await register(u.holder);
  const cid = await openConversation(u.holder, u.athlete);

  const out = await send(cid, 'm1', u.holder);
  assert.equal(out.enqueued, true);
  let fcm = fakeMessaging();
  assert.equal((await run(out.jobId, fcm)).status, 'sent');
  assert.deepEqual(fcm.calls.map((m) => m.token), [tokAthlete]);

  const back = await send(cid, 'm2', u.athlete);
  fcm = fakeMessaging();
  assert.equal((await run(back.jobId, fcm)).status, 'sent');
  assert.deepEqual(fcm.calls.map((m) => m.token), [tokHolder]);
});

test('an ordinary non-friend pair is still not delivered', async () => {
  const u = people('ann', 'ben');
  await register(u.ben);
  const cid = await openConversation(u.ann, u.ben);
  const out = await send(cid, 'm1', u.ann);
  const fcm = fakeMessaging();
  assert.equal((await run(out.jobId, fcm)).reason, 'not-friends');
  assert.equal(fcm.calls.length, 0);
});

test('the test account holds no override: its non-friend DM is not delivered', async () => {
  const u = people('cat');
  await register(u.cat);
  const cid = await openConversation(TEST_ACCOUNT, u.cat);
  const out = await send(cid, `m-${u.cat}`, TEST_ACCOUNT);
  const fcm = fakeMessaging();
  assert.equal((await run(out.jobId, fcm)).reason, 'not-friends');
});

test('a grant withdrawn (or false) before delivery drops the alert', async () => {
  const u = people('dee', 'eli');
  await grant(u.dee);
  await register(u.eli);
  const cid = await openConversation(u.dee, u.eli);
  const out = await send(cid, 'm1', u.dee);
  await grant(u.dee, false);
  const fcm = fakeMessaging();
  assert.equal((await run(out.jobId, fcm)).reason, 'not-friends');
  assert.equal(await O.mayDirectMessage(db(), u.dee, u.eli), false);
});

test('mayDirectMessage: friends, or either participant holding the grant — nothing else', async () => {
  const u = people('fay', 'gus', 'hal');
  await grant(u.fay);
  assert.equal(await O.mayDirectMessage(db(), u.fay, u.gus), true);
  assert.equal(await O.mayDirectMessage(db(), u.gus, u.fay), true);
  assert.equal(await O.mayDirectMessage(db(), u.gus, u.hal), false);
  await db().doc(`buddyAssignments/${u.gus}`).set({ athletes: { [u.hal]: { status: 'accepted' } } });
  await db().doc(`buddyAssignments/${u.hal}`).set({ athletes: { [u.gus]: { status: 'accepted' } } });
  assert.equal(await O.mayDirectMessage(db(), u.gus, u.hal), true);
});

test('a reaction by the non-friend on the holder\'s message is announced', async () => {
  const u = people('ivy', 'jon');
  await grant(u.ivy);
  await register(u.ivy);
  const cid = await openConversation(u.ivy, u.jon);
  const before = { senderId: u.ivy, type: 'text', text: 'x' };
  const after = { ...before, reactions: { [u.jon]: '👍' } };
  await db().doc(`conversations/${cid}/messages/r1`).set(after);
  const r = await O.enqueueDmReactions(db(), {
    convId: cid, messageId: 'r1', beforeData: before, afterData: after, eventId: `evt-r-${cid}`,
  });
  assert.equal(r.enqueued, true, JSON.stringify(r));
});
