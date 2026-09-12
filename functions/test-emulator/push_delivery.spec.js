'use strict';

// PRODUCTION-ADAPTER tests for push notifications, against the Firestore
// emulator with FCM MOCKED (no message ever leaves this machine):
//
//   npm run test:emulator
//
// Every test calls the exact functions the triggers call — applyInviteWrite,
// enqueueFriendRequest, enqueueDirectMessage — then runs the delivery worker
// (processJob) with a fake `messaging.sendEach`, and asserts WHO was sent WHAT.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const admin = require('firebase-admin');

let N; // social/notifications
let O; // push/outbox
let P; // push/push_model

test.before(() => {
  assert.ok(
    process.env.FIRESTORE_EMULATOR_HOST,
    'FIRESTORE_EMULATOR_HOST must be set — run through `npm run test:emulator`',
  );
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  }
  N = require('../social/notifications');
  O = require('../push/outbox');
  P = require('../push/push_model');
});

const db = () => admin.firestore();
const Timestamp = () => admin.firestore.Timestamp;
const sha = (t) => crypto.createHash('sha256').update(t, 'utf8').digest('hex');

let seq = 0;
/** Fresh 28-character uids, so tests never share state. */
function people(...names) {
  seq += 1;
  const stamp = `${Date.now().toString(36)}${seq}`;
  const out = {};
  for (const n of names) out[n] = `${n}${stamp}`.padEnd(28, 'z').slice(0, 28);
  return out;
}
const convIdFor = (a, b) => [a, b].sort().join('_');

async function register(uid, token, { updatedAtMs } = {}) {
  await db().doc(`pushDevices/${sha(token)}`).set({
    uid,
    token,
    platform: 'android',
    appVersion: 'test',
    updatedAt: Timestamp().fromMillis(updatedAtMs || Date.now()),
  });
}

async function named(uid, displayName) {
  await db().doc(`users_public/${uid}`).set({ displayName });
}

async function befriend(a, b) {
  await db().doc(`buddyAssignments/${a}`).set({ athletes: { [b]: { status: 'accepted' } } }, { merge: true });
  await db().doc(`buddyAssignments/${b}`).set({ athletes: { [a]: { status: 'accepted' } } }, { merge: true });
}

async function unfriend(a, b) {
  const del = admin.firestore.FieldValue.delete();
  await db().doc(`buddyAssignments/${a}`).set({ athletes: { [b]: del } }, { merge: true });
  await db().doc(`buddyAssignments/${b}`).set({ athletes: { [a]: del } }, { merge: true });
}

/**
 * A fake FCM. `results` maps a token to an error code (or 'ok'); a function
 * value is called at send time, for tests that race the send.
 */
function fakeMessaging(results = {}) {
  const calls = [];
  return {
    calls,
    tokens: () => calls.map((m) => m.token),
    async sendEach(messages) {
      const responses = [];
      for (const m of messages) {
        calls.push(m);
        let r = results[m.token] || 'ok';
        if (typeof r === 'function') r = await r(m);
        responses.push(r === 'ok'
          ? { success: true, messageId: `projects/x/messages/${calls.length}` }
          : { success: false, error: { code: r } });
      }
      return { responses, successCount: responses.filter((x) => x.success).length };
    },
  };
}

const active = async () => 'active';

function run(jobId, messaging, extra = {}) {
  return O.processJob(db(), jobId, { messaging, accountState: active, ...extra });
}

async function jobsFor(uid) {
  const q = await db().collection('pushOutbox').where('recipientUid', '==', uid).get();
  return q.docs.map((d) => ({ id: d.id, ...d.data() }));
}

async function job(jobId) {
  return (await db().doc(`pushOutbox/${jobId}`).get()).data();
}

const at = (ms) => Timestamp().fromMillis(ms);

// ════════════════════════════════════════════════════════════════════════════
// 1. Incoming friend request
// ════════════════════════════════════════════════════════════════════════════

function pendingInvite(from, to, createdAtMs) {
  return { status: 'pending', fromUid: from, buddyUid: to, createdAt: at(createdAtMs), fromDisplayName: 'x' };
}

async function sendRequest(from, to, createdAtMs, eventId, before = null) {
  const data = pendingInvite(from, to, createdAtMs);
  await db().doc(`users/${to}/buddyInvites/${from}`).set(data);
  return O.enqueueFriendRequest(db(), {
    receiverUid: to, senderUid: from, beforeData: before, afterData: data, eventId,
  });
}

test('request: only the receiver is notified, once, with the requester\'s name', async () => {
  const u = people('ann', 'ben');
  await named(u.ann, 'Ann Archer');
  await register(u.ben, `tok-ben-1-${u.ben}`);
  await register(u.ben, `tok-ben-2-${u.ben}`);
  await register(u.ann, `tok-ann-${u.ann}`);

  const r = await sendRequest(u.ann, u.ben, 1_700_000_000_000, 'evt-1');
  assert.equal(r.enqueued, true);
  // The same event redelivered, and a second event for the SAME request.
  assert.equal((await O.enqueueFriendRequest(db(), {
    receiverUid: u.ben, senderUid: u.ann, beforeData: null,
    afterData: pendingInvite(u.ann, u.ben, 1_700_000_000_000), eventId: 'evt-1',
  })).reason, 'duplicate');
  assert.equal((await O.enqueueFriendRequest(db(), {
    receiverUid: u.ben, senderUid: u.ann, beforeData: null,
    afterData: pendingInvite(u.ann, u.ben, 1_700_000_000_000), eventId: 'evt-2',
  })).reason, 'duplicate');
  assert.equal((await jobsFor(u.ben)).length, 1);

  const fcm = fakeMessaging();
  const res = await run(r.jobId, fcm);
  assert.equal(res.status, 'sent');
  assert.deepEqual(fcm.tokens().sort(), [`tok-ben-1-${u.ben}`, `tok-ben-2-${u.ben}`].sort());
  const m = fcm.calls[0];
  assert.equal(m.notification.body, 'Ann Archer sent you a friend request');
  assert.deepEqual(
    { type: m.data.type, recipientUid: m.data.recipientUid, actorUid: m.data.actorUid },
    { type: 'friendRequest', recipientUid: u.ben, actorUid: u.ann },
  );
  assert.equal(m.android.notification.channelId, 'goodlift_friend_requests');
  assert.ok(m.android.ttl > 0 && m.android.ttl <= 24 * 3600_000);

  // A second worker run (a retry of the creation event) sends nothing.
  const again = fakeMessaging();
  assert.equal((await run(r.jobId, again)).reason, 'done');
  assert.equal(again.calls.length, 0);
  // Nothing was queued for the requester.
  assert.equal((await jobsFor(u.ann)).length, 0);
});

test('request: repeated Add, edits, declines and cancels create no alert', async () => {
  const u = people('cat', 'dan');
  const p = pendingInvite(u.cat, u.dan, 1_700_000_100_000);
  for (const [before, after] of [
    [p, p], // repeated Add
    [p, { ...p, fromDisplayName: 'repaired' }], // repair
    [p, { ...p, status: 'denied' }], // decline
    [p, null], // cancel
    [p, { ...p, status: 'accepted' }], // accept
  ]) {
    const r = await O.enqueueFriendRequest(db(), {
      receiverUid: u.dan, senderUid: u.cat, beforeData: before, afterData: after, eventId: 'e',
    });
    assert.equal(r.enqueued, false);
  }
  // A self-request is never enqueued.
  const self = await O.enqueueFriendRequest(db(), {
    receiverUid: u.cat, senderUid: u.cat, beforeData: null,
    afterData: pendingInvite(u.cat, u.cat, 1), eventId: 'e',
  });
  assert.equal(self.reason, 'invalid-pair');
  assert.equal((await jobsFor(u.dan)).length + (await jobsFor(u.cat)).length, 0);
});

test('request: a delayed alert is dropped once the request is resolved or superseded', async () => {
  const u = people('eve', 'fox');
  await register(u.fox, `tok-fox-${u.fox}`);

  // Cancelled before the worker ran.
  const r1 = await sendRequest(u.eve, u.fox, 1_700_000_200_000, 'e1');
  await db().doc(`users/${u.fox}/buddyInvites/${u.eve}`).delete();
  const fcm = fakeMessaging();
  assert.equal((await run(r1.jobId, fcm)).reason, 'request-gone');

  // Declined before the worker ran.
  const r2 = await sendRequest(u.eve, u.fox, 1_700_000_300_000, 'e2', { status: 'denied' });
  assert.notEqual(r2.jobId, r1.jobId, 'a valid new request after a cancel is a new occurrence');
  await db().doc(`users/${u.fox}/buddyInvites/${u.eve}`).update({ status: 'denied' });
  assert.equal((await run(r2.jobId, fcm)).reason, 'request-resolved');

  // Re-requested after that decline: the NEW request notifies…
  const r3 = await sendRequest(u.eve, u.fox, 1_700_000_400_000, 'e3', { status: 'denied' });
  assert.equal(r3.enqueued, true);
  // …and a late worker for the OLD one does not.
  await db().doc(`pushOutbox/${r2.jobId}`).update({ status: 'pending' });
  assert.equal((await run(r2.jobId, fcm)).reason, 'superseded-request');
  assert.equal(fcm.calls.length, 0);

  assert.equal((await run(r3.jobId, fcm)).status, 'sent');
  assert.equal(fcm.calls.length, 1);
});

// ════════════════════════════════════════════════════════════════════════════
// 2. Friend request accepted
// ════════════════════════════════════════════════════════════════════════════

const CREATED_1 = 1_700_001_000_000;
const CREATED_2 = 1_700_002_000_000;

/** requester asked acceptor (at createdAtMs); acceptor accepted via [shape]. */
async function accept(requester, acceptor, createdAtMs, eventId, shape = 'callable') {
  const base = pendingInvite(requester, acceptor, createdAtMs);
  const after = shape === 'legacy'
    // Older installed builds: status + respondedAt only, onto the invite.
    ? { ...base, status: 'accepted', respondedAt: at(createdAtMs + 5000) }
    // buddyRespondToRequest / crossed request in buddySendRequest:
    // writeAcceptance's merge.
    : { ...base, status: 'accepted', fromUid: requester, buddyUid: acceptor, respondedAt: at(createdAtMs + 5000) };
  await db().doc(`users/${acceptor}/buddyInvites/${requester}`).set(after);
  return N.applyInviteWrite(db(), {
    receiverUid: acceptor, senderUid: requester, beforeData: base, afterData: after, eventId,
  });
}

async function notice(owner, other) {
  return (await db().doc(`users/${owner}/socialNotifications/buddyAccepted_${other}`).get()).data();
}

test('accepted: only the original requester is notified — callable, crossed and legacy writes', async () => {
  for (const shape of ['callable', 'legacy']) {
    const u = people('gus', 'hal');
    await named(u.hal, 'Hal Hughes');
    await register(u.gus, `tok-gus-${u.gus}`);
    await register(u.hal, `tok-hal-${u.hal}`);
    await befriend(u.gus, u.hal);

    const r = await accept(u.gus, u.hal, CREATED_1, `evt-${shape}`, shape);
    assert.equal(r.action, 'create', shape);
    assert.ok(r.jobId, 'the push is enqueued with the notice');
    assert.equal((await notice(u.gus, u.hal)).occurrenceKey, P.inviteOccurrence({ createdAt: at(CREATED_1) }));

    const fcm = fakeMessaging();
    assert.equal((await run(r.jobId, fcm)).status, 'sent');
    assert.deepEqual(fcm.tokens(), [`tok-gus-${u.gus}`], 'never the acceptor');
    assert.equal(fcm.calls[0].notification.body, 'Hal Hughes accepted your friend request');
    assert.equal(fcm.calls[0].data.type, 'friendAccepted');
    assert.equal(fcm.calls[0].data.recipientUid, u.gus);
    assert.equal((await jobsFor(u.hal)).length, 0);
  }
});

test('accepted: duplicate deliveries and a re-toggled invite never re-notify or reset the badge', async () => {
  const u = people('ivy', 'jon');
  await befriend(u.ivy, u.jon);
  const first = await accept(u.ivy, u.jon, CREATED_1, 'evt-1');
  await Promise.all([accept(u.ivy, u.jon, CREATED_1, 'evt-1'), accept(u.ivy, u.jon, CREATED_1, 'evt-1')]);
  assert.equal((await jobsFor(u.ivy)).length, 1);

  // Ivy reads the notice in the People view.
  await db().doc(`users/${u.ivy}/socialNotifications/buddyAccepted_${u.jon}`)
    .update({ seen: true, seenAt: admin.firestore.FieldValue.serverTimestamp() });

  // Jon's old client flips the SAME invite accepted → pending → accepted.
  const again = await accept(u.ivy, u.jon, CREATED_1, 'evt-2', 'legacy');
  assert.deepEqual({ action: again.action, reason: again.reason }, { action: 'none', reason: 'same-occurrence' });
  assert.equal((await notice(u.ivy, u.jon)).seen, true, 'the badge is not reset');
  assert.equal((await jobsFor(u.ivy)).length, 1, 'no second alert');

  // And the push itself is dropped: she has already seen it in the app.
  const fcm = fakeMessaging();
  await register(u.ivy, `tok-ivy-${u.ivy}`);
  assert.equal((await run(first.jobId, fcm)).reason, 'already-seen');
  assert.equal(fcm.calls.length, 0);
});

test('accepted: unfriend → re-request → re-accept notifies again; the old event replayed does not', async () => {
  const u = people('kim', 'lou');
  await register(u.kim, `tok-kim-${u.kim}`);
  await befriend(u.kim, u.lou);
  const first = await accept(u.kim, u.lou, CREATED_1, 'evt-1');

  // buddyRemoveFriend: both sides cleared, invites deleted.
  await unfriend(u.kim, u.lou);
  await db().doc(`users/${u.lou}/buddyInvites/${u.kim}`).delete();
  const removed = await N.applyInviteWrite(db(), {
    receiverUid: u.lou, senderUid: u.kim,
    beforeData: { status: 'accepted', createdAt: at(CREATED_1) }, afterData: null, eventId: 'evt-2',
  });
  assert.equal(removed.action, 'delete');

  // The OLD acceptance event redelivered after the removal: nothing revives.
  const lateOld = await N.applyInviteWrite(db(), {
    receiverUid: u.lou, senderUid: u.kim,
    beforeData: pendingInvite(u.kim, u.lou, CREATED_1),
    afterData: { ...pendingInvite(u.kim, u.lou, CREATED_1), status: 'accepted' },
    eventId: 'evt-1-replay',
  });
  assert.equal(lateOld.action, 'none');
  assert.equal(await notice(u.kim, u.lou), undefined);

  // They become friends again through a NEW request.
  await befriend(u.kim, u.lou);
  const second = await accept(u.kim, u.lou, CREATED_2, 'evt-3');
  assert.equal(second.action, 'create');
  assert.notEqual(second.jobId, first.jobId);

  // The old event replayed once more, now out of order: still nothing.
  const replay = await N.applyInviteWrite(db(), {
    receiverUid: u.lou, senderUid: u.kim,
    beforeData: pendingInvite(u.kim, u.lou, CREATED_1),
    afterData: { ...pendingInvite(u.kim, u.lou, CREATED_1), status: 'accepted' },
    eventId: 'evt-1-replay-2',
  });
  assert.deepEqual({ action: replay.action, reason: replay.reason }, { action: 'none', reason: 'stale-event' });
  assert.equal((await notice(u.kim, u.lou)).sourceEventId, 'evt-3');

  // The delete event arriving late, after the re-accept, keeps the notice.
  const lateDelete = await N.applyInviteWrite(db(), {
    receiverUid: u.lou, senderUid: u.kim,
    beforeData: { status: 'accepted' }, afterData: null, eventId: 'evt-2-late',
  });
  assert.equal(lateDelete.reason, 'still-friends');

  const fcm = fakeMessaging();
  // The first occurrence's job, delivered late: superseded.
  assert.equal((await run(first.jobId, fcm)).reason, 'superseded-acceptance');
  assert.equal((await run(second.jobId, fcm)).status, 'sent');
  assert.equal(fcm.calls.length, 1);
});

test('accepted: a half-written (not mutual) acceptance announces nothing', async () => {
  const u = people('max', 'ned');
  await db().doc(`buddyAssignments/${u.ned}`).set({ athletes: { [u.max]: { status: 'accepted' } } });
  const r = await accept(u.max, u.ned, CREATED_1, 'evt-1');
  assert.equal(r.reason, 'not-mutual');
  assert.equal((await jobsFor(u.max)).length, 0);
});

test('accepted: an unfriend before delivery drops the alert', async () => {
  const u = people('oli', 'pat');
  await register(u.oli, `tok-oli-${u.oli}`);
  await befriend(u.oli, u.pat);
  const r = await accept(u.oli, u.pat, CREATED_1, 'evt-1');
  await unfriend(u.oli, u.pat);
  const fcm = fakeMessaging();
  assert.equal((await run(r.jobId, fcm)).reason, 'not-friends');
  assert.equal(fcm.calls.length, 0);
});

// ════════════════════════════════════════════════════════════════════════════
// 3. Direct messages
// ════════════════════════════════════════════════════════════════════════════

async function openConversation(a, b) {
  const cid = convIdFor(a, b);
  await db().doc(`conversations/${cid}`).set({
    participants: { [a]: true, [b]: true },
    participantList: [a, b].sort(),
    participantState: { [a]: { unreadCount: 0 }, [b]: { unreadCount: 0 } },
  });
  return cid;
}

async function writeMessage(cid, id, before, after) {
  const ref = db().doc(`conversations/${cid}/messages/${id}`);
  if (after) await ref.set(after); else await ref.delete();
  return O.enqueueDirectMessage(db(), {
    convId: cid, messageId: id, beforeData: before, afterData: after, eventId: `evt-${id}-${Math.random()}`,
  });
}

test('dm: text goes to the other participant only; no preview by default', async () => {
  const u = people('quin', 'rae');
  await named(u.quin, 'Quin Q');
  await befriend(u.quin, u.rae);
  await register(u.rae, `tok-rae-${u.rae}`);
  await register(u.quin, `tok-quin-${u.quin}`);
  const cid = await openConversation(u.quin, u.rae);

  const text = { senderId: u.quin, type: 'text', text: 'my locker code is 4321', sentAt: at(Date.now()) };
  const r = await writeMessage(cid, 'm1', null, text);
  assert.equal(r.enqueued, true);
  const fcm = fakeMessaging();
  assert.equal((await run(r.jobId, fcm)).status, 'sent');
  assert.deepEqual(fcm.tokens(), [`tok-rae-${u.rae}`]);
  const m = fcm.calls[0];
  assert.equal(m.notification.title, 'New message');
  assert.equal(m.notification.body, 'Quin Q sent you a message');
  assert.ok(!JSON.stringify(m).includes('4321'), 'message text is not in the payload');
  assert.deepEqual(m.data, {
    v: '1',
    type: 'directMessage',
    recipientUid: u.rae,
    actorUid: u.quin,
    convId: cid,
    msgId: 'm1',
    seq: '1',
  });
  assert.equal(m.android.notification.tag, `dm|${P.conversationTagKey(cid)}|m1`);

  // A reaction and a read receipt afterwards create nothing.
  assert.equal((await writeMessage(cid, 'm1', text, { ...text, reactions: { [u.rae]: '🔥' } })).enqueued, false);
  await db().doc(`conversations/${cid}`).update({ [`participantState.${u.rae}.unreadCount`]: 0 });
  assert.equal((await jobsFor(u.rae)).length, 1);
  assert.equal((await jobsFor(u.quin)).length, 0, 'never a self-notification');
});

test('dm: previews ON put the text in the payload', async () => {
  const u = people('sid', 'tia');
  await named(u.sid, 'Sid');
  await befriend(u.sid, u.tia);
  await register(u.tia, `tok-tia-${u.tia}`);
  await db().doc(`pushPreferences/${u.tia}`).set({ messagePreviews: true });
  const cid = await openConversation(u.sid, u.tia);
  const r = await writeMessage(cid, 'm1', null, { senderId: u.sid, type: 'text', text: 'see you at 6' });
  const fcm = fakeMessaging();
  await run(r.jobId, fcm);
  assert.deepEqual(fcm.calls[0].notification, { title: 'Sid', body: 'see you at 6' });
});

test('dm: photo and video notify when the upload is attached — not for the shell, a failure or later edits', async () => {
  for (const [kind, field, wording] of [['image', 'imageUrl', 'a photo'], ['video', 'videoUrl', 'a video']]) {
    const u = people('uma', 'vic');
    await named(u.uma, 'Uma');
    await befriend(u.uma, u.vic);
    await register(u.vic, `tok-vic-${u.vic}`);
    const cid = await openConversation(u.uma, u.vic);

    const shell = { senderId: u.uma, type: kind, text: '', localSentAt: Date.now() };
    assert.equal((await writeMessage(cid, 'media', null, shell)).reason, 'not-newly-deliverable');
    // A second shell whose upload FAILED — it is never patched.
    assert.equal((await writeMessage(cid, 'failed', null, shell)).enqueued, false);
    assert.equal((await jobsFor(u.vic)).length, 0);

    const ready = { ...shell, [field]: `https://storage.test/${kind}` };
    const r = await writeMessage(cid, 'media', shell, ready);
    assert.equal(r.enqueued, true, kind);
    // The patch event redelivered; then a reaction; then a URL rewrite.
    assert.equal((await O.enqueueDirectMessage(db(), {
      convId: cid, messageId: 'media', beforeData: shell, afterData: ready, eventId: 'other-event',
    })).reason, 'duplicate');
    assert.equal((await writeMessage(cid, 'media', ready, { ...ready, reactions: { [u.vic]: '👍' } })).enqueued, false);
    assert.equal((await writeMessage(cid, 'media', ready, { ...ready, [field]: 'https://storage.test/new' })).enqueued, false);
    assert.equal((await jobsFor(u.vic)).length, 1);

    const fcm = fakeMessaging();
    await run(r.jobId, fcm);
    assert.equal(fcm.calls[0].notification.body, `Uma sent you ${wording}`);
  }
});

test('dm: forged senders and inconsistent conversations are never delivered', async () => {
  const u = people('wes', 'xia', 'yan');
  await befriend(u.wes, u.xia);
  await register(u.xia, `tok-xia-${u.xia}`);
  await register(u.wes, `tok-wes-${u.wes}`);
  const cid = await openConversation(u.wes, u.xia);

  // A sender who is not in the conversation.
  assert.equal((await writeMessage(cid, 'f1', null, { senderId: u.yan, type: 'text', text: 'x' })).reason,
    'sender-not-in-conversation');
  // Participants rewritten to include a third account.
  await db().doc(`conversations/${cid}`).set({ participants: { [u.wes]: true, [u.yan]: true } });
  assert.equal((await writeMessage(cid, 'f2', null, { senderId: u.wes, type: 'text', text: 'x' })).reason,
    'participants-mismatch');
  // No conversation document at all.
  const orphan = convIdFor(u.wes, u.yan);
  assert.equal((await writeMessage(orphan, 'f3', null, { senderId: u.wes, type: 'text', text: 'x' })).reason,
    'no-participants');
  assert.equal((await jobsFor(u.xia)).length + (await jobsFor(u.wes)).length + (await jobsFor(u.yan)).length, 0);
});

test('dm: a friendship or message that is gone by delivery time is not announced', async () => {
  const u = people('zed', 'amy');
  await befriend(u.zed, u.amy);
  await register(u.amy, `tok-amy-${u.amy}`);
  const cid = await openConversation(u.zed, u.amy);
  const r = await writeMessage(cid, 'm1', null, { senderId: u.zed, type: 'text', text: 'x' });
  await unfriend(u.zed, u.amy);
  const fcm = fakeMessaging();
  assert.equal((await run(r.jobId, fcm)).reason, 'not-friends');
  assert.equal(fcm.calls.length, 0);
});

// ════════════════════════════════════════════════════════════════════════════
// 4. Outbox mechanics
// ════════════════════════════════════════════════════════════════════════════

async function dmJob(names = ['bea', 'cal']) {
  const u = people(...names);
  const [s, r] = names.map((n) => u[n]);
  await befriend(s, r);
  const cid = await openConversation(s, r);
  const res = await writeMessage(cid, 'm', null, { senderId: s, type: 'text', text: 'hi' });
  return { sender: s, recipient: r, jobId: res.jobId, cid };
}

test('outbox: concurrent workers deliver each device once', async () => {
  const j = await dmJob();
  await register(j.recipient, `tok-a-${j.recipient}`);
  await register(j.recipient, `tok-b-${j.recipient}`);
  const fcm = fakeMessaging();
  const results = await Promise.allSettled([run(j.jobId, fcm), run(j.jobId, fcm), run(j.jobId, fcm)]);
  assert.equal(fcm.calls.length, 2, 'two devices, two sends — however many workers');
  for (const r of results) {
    if (r.status === 'rejected') assert.ok(r.reason instanceof O.RetryableDeliveryError, String(r.reason));
  }
  assert.equal((await job(j.jobId)).status, 'sent');
});

test('outbox: partial failure — invalid token removed, transient device retried, delivered device not resent', async () => {
  const j = await dmJob();
  const ok = `tok-ok-${j.recipient}`;
  const dead = `tok-dead-${j.recipient}`;
  const flaky = `tok-flaky-${j.recipient}`;
  for (const t of [ok, dead, flaky]) await register(j.recipient, t);

  const first = fakeMessaging({
    [dead]: 'messaging/registration-token-not-registered',
    [flaky]: 'messaging/server-unavailable',
  });
  await assert.rejects(run(j.jobId, first), O.RetryableDeliveryError);
  let state = await job(j.jobId);
  assert.equal(state.status, 'pending');
  assert.equal(state.devices[sha(ok)], 'sent');
  assert.equal(state.devices[sha(dead)], 'invalid');
  assert.equal(state.devices[sha(flaky)], 'retry');
  assert.equal((await db().doc(`pushDevices/${sha(dead)}`).get()).exists, false, 'invalid registration deleted');
  assert.equal((await db().doc(`pushDevices/${sha(ok)}`).get()).exists, true);

  const second = fakeMessaging();
  assert.equal((await run(j.jobId, second)).status, 'sent');
  assert.deepEqual(second.tokens(), [flaky], 'only the device that has not had it');
  state = await job(j.jobId);
  assert.equal(state.devices[sha(flaky)], 'sent');
  assert.equal(state.attempts, 2);
});

test('outbox: an error for an old registration never deletes a refreshed one', async () => {
  const j = await dmJob();
  const tok = `tok-refresh-${j.recipient}`;
  await register(j.recipient, tok, { updatedAtMs: Date.now() - 1000 });
  const fcm = fakeMessaging({
    // While the send is in flight the phone re-registers the same token.
    [tok]: async () => {
      await register(j.recipient, tok, { updatedAtMs: Date.now() + 60_000 });
      return 'messaging/registration-token-not-registered';
    },
  });
  await run(j.jobId, fcm);
  assert.equal((await db().doc(`pushDevices/${sha(tok)}`).get()).exists, true);
});

test('outbox: a token now owned by another account is not deleted or used for this one', async () => {
  const j = await dmJob();
  const other = people('own').own;
  const shared = `tok-shared-${j.recipient}`;
  await register(other, shared); // the phone now belongs to `other`
  const fcm = fakeMessaging();
  assert.equal((await run(j.jobId, fcm)).reason, 'no-devices');
  assert.equal(fcm.calls.length, 0, 'the previous account\'s alerts do not reach the new owner');
});

test('outbox: INVALID_ARGUMENT deletes only when the same payload succeeded elsewhere', async () => {
  const lone = await dmJob();
  const t1 = `tok-inv-${lone.recipient}`;
  await register(lone.recipient, t1);
  await run(lone.jobId, fakeMessaging({ [t1]: 'messaging/invalid-argument' }));
  assert.equal((await db().doc(`pushDevices/${sha(t1)}`).get()).exists, true);
  assert.equal((await job(lone.jobId)).status, 'failed');

  const pair = await dmJob();
  const good = `tok-good-${pair.recipient}`;
  const bad = `tok-bad-${pair.recipient}`;
  await register(pair.recipient, good);
  await register(pair.recipient, bad);
  await run(pair.jobId, fakeMessaging({ [bad]: 'messaging/invalid-argument' }));
  assert.equal((await db().doc(`pushDevices/${sha(bad)}`).get()).exists, false);
  assert.equal((await db().doc(`pushDevices/${sha(good)}`).get()).exists, true);
});

test('outbox: a worker interrupted mid-delivery resumes without resending delivered devices', async () => {
  const j = await dmJob();
  const done = `tok-done-${j.recipient}`;
  const todo = `tok-todo-${j.recipient}`;
  await register(j.recipient, done);
  await register(j.recipient, todo);
  // A previous worker delivered to `done`, then died holding the lease.
  await db().doc(`pushOutbox/${j.jobId}`).update({
    status: 'sending', attempts: 1,
    lease: { id: 'dead-worker', until: at(Date.now() - 1000) },
    [`devices.${sha(done)}`]: 'sent',
  });
  const fcm = fakeMessaging();
  assert.equal((await run(j.jobId, fcm)).status, 'sent');
  assert.deepEqual(fcm.tokens(), [todo]);
});

test('outbox: a live lease held by another worker is retried later, not doubled', async () => {
  const j = await dmJob();
  await register(j.recipient, `tok-${j.recipient}`);
  await db().doc(`pushOutbox/${j.jobId}`).update({
    status: 'sending', lease: { id: 'other', until: at(Date.now() + 60_000) },
  });
  const fcm = fakeMessaging();
  await assert.rejects(run(j.jobId, fcm), O.RetryableDeliveryError);
  assert.equal(fcm.calls.length, 0);
});

test('outbox: retries are bounded by expiry and by attempts', async () => {
  const late = await dmJob();
  await register(late.recipient, `tok-${late.recipient}`);
  const fcm = fakeMessaging();
  const res = await run(late.jobId, fcm, { nowMs: () => Date.now() + 13 * 3600_000 });
  assert.equal(res.status, 'expired');
  assert.equal(fcm.calls.length, 0, 'a DM alert is not delivered hours late');

  const stuck = await dmJob();
  const t = `tok-stuck-${stuck.recipient}`;
  await register(stuck.recipient, t);
  const always = fakeMessaging({ [t]: 'messaging/internal-error' });
  let thrown = 0;
  for (let i = 0; i < P.MAX_ATTEMPTS + 3; i += 1) {
    try { await run(stuck.jobId, always); } catch (err) {
      assert.ok(err instanceof O.RetryableDeliveryError);
      thrown += 1;
    }
  }
  assert.equal(always.calls.length, P.MAX_ATTEMPTS, 'no more sends than the attempt budget');
  assert.equal(thrown, P.MAX_ATTEMPTS - 1, 'the last attempt settles instead of asking for a retry');
  assert.equal((await job(stuck.jobId)).status, 'failed');
});

test('outbox: category preferences, the kill switch and deleted accounts', async () => {
  const off = await dmJob();
  await register(off.recipient, `tok-${off.recipient}`);
  await db().doc(`pushPreferences/${off.recipient}`).set({ directMessages: false });
  const fcm = fakeMessaging();
  assert.equal((await run(off.jobId, fcm)).reason, 'preference-off');

  const killed = await dmJob();
  await register(killed.recipient, `tok-${killed.recipient}`);
  await db().doc('pushConfig/delivery').set({ enabled: false });
  try {
    assert.equal((await run(killed.jobId, fcm)).reason, 'delivery-disabled');
  } finally {
    await db().doc('pushConfig/delivery').delete();
  }

  const gone = await dmJob();
  await register(gone.recipient, `tok-gone-${gone.recipient}`);
  const res = await O.processJob(db(), gone.jobId, {
    messaging: fcm, accountState: async () => 'missing',
  });
  assert.equal(res.reason, 'account-missing');
  assert.equal((await db().doc(`pushDevices/${sha(`tok-gone-${gone.recipient}`)}`).get()).exists, false);
  assert.equal(fcm.calls.length, 0);
});

test('outbox: abandoned registrations are pruned, not sent to', async () => {
  const j = await dmJob();
  const old = `tok-old-${j.recipient}`;
  const fresh = `tok-fresh-${j.recipient}`;
  await register(j.recipient, old, { updatedAtMs: Date.now() - 90 * 24 * 3600_000 });
  await register(j.recipient, fresh);
  const fcm = fakeMessaging();
  await run(j.jobId, fcm);
  assert.deepEqual(fcm.tokens(), [fresh]);
  assert.equal((await db().doc(`pushDevices/${sha(old)}`).get()).exists, false);
});

test('no backfill: pre-existing friendships, notices and messages produce nothing', async () => {
  const u = people('old', 'pal');
  await befriend(u.old, u.pal);
  const cid = await openConversation(u.old, u.pal);
  const accepted = { ...pendingInvite(u.old, u.pal, CREATED_1), status: 'accepted' };
  await db().doc(`users/${u.pal}/buddyInvites/${u.old}`).set(accepted);

  // Later writes touching historic documents.
  const r1 = await N.applyInviteWrite(db(), {
    receiverUid: u.pal, senderUid: u.old, beforeData: accepted,
    afterData: { ...accepted, respondedAt: at(Date.now()) }, eventId: 'merge',
  });
  assert.equal(r1.action, 'none');
  const oldMsg = { senderId: u.old, type: 'image', text: '', imageUrl: 'https://x/i' };
  await writeMessage(cid, 'historic', oldMsg, { ...oldMsg, reactions: { [u.pal]: '🔥' } });
  assert.equal((await jobsFor(u.pal)).length + (await jobsFor(u.old)).length, 0);
});
