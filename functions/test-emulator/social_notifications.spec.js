'use strict';

// PRODUCTION-ADAPTER tests for "your buddy request was accepted".
//
// Runs applyInviteWrite — the exact function the trigger calls — against the
// Firestore emulator, with the documents laid out the way buddies.js writes
// them, so the mutual check, the transaction and the retry guard are proved
// against real Firestore semantics.
//
//   npm run test:emulator

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

let N;

test.before(() => {
  assert.ok(
    process.env.FIRESTORE_EMULATOR_HOST,
    'FIRESTORE_EMULATOR_HOST must be set — run through `npm run test:emulator`',
  );
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  }
  N = require('../social/notifications');
});

let seq = 0;
function pair() {
  seq += 1;
  const stamp = `${Date.now()}_${seq}`;
  return { alice: `alice_${stamp}`, bob: `bob_${stamp}` };
}

const db = () => admin.firestore();

async function wipe(...uids) {
  for (const uid of uids) {
    await db().recursiveDelete(db().collection('users').doc(uid));
    await db().collection('buddyAssignments').doc(uid).delete().catch(() => {});
  }
}

/** Both sides accepted — what writeAcceptance leaves behind. */
async function befriend(a, b) {
  await db().doc(`buddyAssignments/${a}`).set({ athletes: { [b]: { status: 'accepted' } } }, { merge: true });
  await db().doc(`buddyAssignments/${b}`).set({ athletes: { [a]: { status: 'accepted' } } }, { merge: true });
}

async function unfriend(a, b) {
  const del = admin.firestore.FieldValue.delete();
  await db().doc(`buddyAssignments/${a}`).set({ athletes: { [b]: del } }, { merge: true });
  await db().doc(`buddyAssignments/${b}`).set({ athletes: { [a]: del } }, { merge: true });
}

const pending = (from, to) => ({ status: 'pending', fromUid: from, buddyUid: to });
const accepted = (from, to) => ({
  status: 'accepted',
  fromUid: from,
  buddyUid: to,
  respondedAt: admin.firestore.Timestamp.fromMillis(Date.UTC(2026, 8, 1)),
});

/** alice asked bob; bob accepted. */
function acceptance({ alice, bob }, eventId) {
  return N.applyInviteWrite(db(), {
    receiverUid: bob,
    senderUid: alice,
    beforeData: pending(alice, bob),
    afterData: accepted(alice, bob),
    eventId,
  });
}

async function noticesOf(uid) {
  const q = await db().collection('users').doc(uid).collection('socialNotifications').get();
  return q.docs.map((d) => ({ id: d.id, ...d.data() }));
}

test('the sender receives exactly one unread acceptance', async () => {
  const p = pair();
  try {
    await befriend(p.alice, p.bob);
    const r = await acceptance(p, 'evt-1');
    assert.equal(r.action, 'create');

    const notices = await noticesOf(p.alice);
    assert.equal(notices.length, 1);
    assert.equal(notices[0].id, `buddyAccepted_${p.bob}`);
    assert.equal(notices[0].type, 'buddyAccepted');
    assert.equal(notices[0].otherUid, p.bob);
    assert.equal(notices[0].seen, false);
    assert.ok(notices[0].createdAt, 'createdAt stamped by the server');
    assert.equal(notices[0].acceptedAt.toMillis(), Date.UTC(2026, 8, 1));
  } finally {
    await wipe(p.alice, p.bob);
  }
});

test('the receiver does not receive the sender\'s notice', async () => {
  const p = pair();
  try {
    await befriend(p.alice, p.bob);
    await acceptance(p, 'evt-1');
    assert.deepEqual(await noticesOf(p.bob), []);
  } finally {
    await wipe(p.alice, p.bob);
  }
});

test('retries stay idempotent, and never reset a notice already seen', async () => {
  const p = pair();
  try {
    await befriend(p.alice, p.bob);
    await acceptance(p, 'evt-1');
    // Redelivered, and delivered concurrently with itself.
    await Promise.all([acceptance(p, 'evt-1'), acceptance(p, 'evt-1')]);
    assert.equal((await noticesOf(p.alice)).length, 1);

    // Alice opens the People view.
    await db()
      .doc(`users/${p.alice}/socialNotifications/buddyAccepted_${p.bob}`)
      .update({ seen: true, seenAt: admin.firestore.FieldValue.serverTimestamp() });
    const again = await acceptance(p, 'evt-1');
    assert.deepEqual(again, { action: 'none', reason: 'duplicate-delivery' });
    const [n] = await noticesOf(p.alice);
    assert.equal(n.seen, true, 'a retry must not make a seen notice unread');
  } finally {
    await wipe(p.alice, p.bob);
  }
});

test('an acceptance the other side has not confirmed announces nothing', async () => {
  const p = pair();
  try {
    // Only bob's side is accepted — a half-written legacy acceptance.
    await db().doc(`buddyAssignments/${p.bob}`).set({
      athletes: { [p.alice]: { status: 'accepted' } },
    });
    await db().doc(`buddyAssignments/${p.alice}`).set({
      athletes: { [p.bob]: { status: 'pending' } },
    });
    const r = await acceptance(p, 'evt-1');
    assert.deepEqual(r, { action: 'none', reason: 'not-mutual' });
    assert.deepEqual(await noticesOf(p.alice), []);
  } finally {
    await wipe(p.alice, p.bob);
  }
});

test('an old accepted friendship does not become unread', async () => {
  const p = pair();
  try {
    await befriend(p.alice, p.bob);
    // A merge onto an invite that was accepted long before deployment.
    const r = await N.applyInviteWrite(db(), {
      receiverUid: p.bob,
      senderUid: p.alice,
      beforeData: accepted(p.alice, p.bob),
      afterData: { ...accepted(p.alice, p.bob), respondedAt: admin.firestore.Timestamp.now() },
      eventId: 'evt-old',
    });
    assert.equal(r.action, 'none');
    assert.deepEqual(await noticesOf(p.alice), []);
  } finally {
    await wipe(p.alice, p.bob);
  }
});

test('unfriending removes the notice; tidying an invite while friends keeps it', async () => {
  const p = pair();
  try {
    await befriend(p.alice, p.bob);
    await acceptance(p, 'evt-1');

    // Bob deletes the old invite but they are still friends.
    const kept = await N.applyInviteWrite(db(), {
      receiverUid: p.bob, senderUid: p.alice,
      beforeData: accepted(p.alice, p.bob), afterData: null, eventId: 'evt-2',
    });
    assert.deepEqual(kept, { action: 'none', reason: 'still-friends' });
    assert.equal((await noticesOf(p.alice)).length, 1);

    // buddyRemoveFriend clears both sides and deletes the invites.
    await unfriend(p.alice, p.bob);
    const gone = await N.applyInviteWrite(db(), {
      receiverUid: p.bob, senderUid: p.alice,
      beforeData: accepted(p.alice, p.bob), afterData: null, eventId: 'evt-3',
    });
    assert.deepEqual(gone, { action: 'delete', reason: 'friendship-ended' });
    assert.deepEqual(await noticesOf(p.alice), []);
  } finally {
    await wipe(p.alice, p.bob);
  }
});

test('asking again after an unfriend notifies again', async () => {
  const p = pair();
  try {
    await befriend(p.alice, p.bob);
    await acceptance(p, 'evt-1');
    await db()
      .doc(`users/${p.alice}/socialNotifications/buddyAccepted_${p.bob}`)
      .update({ seen: true, seenAt: admin.firestore.FieldValue.serverTimestamp() });
    await unfriend(p.alice, p.bob);
    await befriend(p.alice, p.bob);
    const r = await acceptance(p, 'evt-9');
    assert.equal(r.action, 'create');
    const [n] = await noticesOf(p.alice);
    assert.equal(n.seen, false);
    assert.equal(n.sourceEventId, 'evt-9');
  } finally {
    await wipe(p.alice, p.bob);
  }
});
