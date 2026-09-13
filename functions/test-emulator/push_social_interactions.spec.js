'use strict';

// PRODUCTION-ADAPTER tests for comments, likes, Good Lifts and message
// reactions, against the Firestore emulator with FCM MOCKED:
//
//   npm run test:emulator
//
// Every test calls the exact functions the triggers call — enqueuePostComment,
// enqueuePostReaction, enqueueDmReactions — then runs the real delivery worker
// (processJob) with a fake `messaging.sendEach`, and asserts who was told what,
// what the activity record says, and what a replay does.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const admin = require('firebase-admin');

let O; // push/outbox
let P; // push/push_model
let A; // push/activity
let U; // push/dm_unread

test.before(() => {
  assert.ok(
    process.env.FIRESTORE_EMULATOR_HOST,
    'FIRESTORE_EMULATOR_HOST must be set — run through `npm run test:emulator`',
  );
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  }
  O = require('../push/outbox');
  P = require('../push/push_model');
  A = require('../push/activity');
  U = require('../push/dm_unread');
});

const db = () => admin.firestore();
const Timestamp = () => admin.firestore.Timestamp;
const sha = (t) => crypto.createHash('sha256').update(t, 'utf8').digest('hex');

let seq = 0;
function people(...names) {
  seq += 1;
  const stamp = `${Date.now().toString(36)}${seq}`;
  const out = {};
  for (const n of names) out[n] = `${n}${stamp}`.padEnd(28, 'z').slice(0, 28);
  return out;
}

const convIdFor = (a, b) => [a, b].sort().join('_');

async function register(uid, token) {
  await db().doc(`pushDevices/${sha(token)}`).set({
    uid, token, platform: 'android', appVersion: 'test',
    updatedAt: Timestamp().fromMillis(Date.now()),
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

function fakeMessaging(results = {}) {
  const calls = [];
  return {
    calls,
    async sendEach(messages) {
      const responses = [];
      for (const m of messages) {
        calls.push(m);
        const r = results[m.token] || 'ok';
        responses.push(r === 'ok'
          ? { success: true, messageId: `m${calls.length}` }
          : { success: false, error: { code: r } });
      }
      return { responses, successCount: responses.filter((x) => x.success).length };
    },
  };
}

const active = async () => 'active';
const run = (jobId, messaging, extra = {}) =>
  O.processJob(db(), jobId, { messaging, accountState: active, ...extra });

async function post(ownerUid, postId, extra = {}) {
  await db().doc(`posts/${postId}`).set({
    ownerUid, mediaType: 'image', showInGrid: true,
    createdAt: Timestamp().fromMillis(Date.now()), ...extra,
  });
}

async function comment(postId, commentId, uid, text) {
  const data = { uid, username: 'x', text, createdAt: Timestamp().fromMillis(Date.now()) };
  await db().doc(`posts/${postId}/comments/${commentId}`).set(data);
  return data;
}

const activityOf = async (uid, id) =>
  (await db().doc(`users/${uid}/socialActivity/${id}`).get()).data();

async function activityList(uid) {
  const q = await db().collection(`users/${uid}/socialActivity`).get();
  return q.docs.map((d) => ({ id: d.id, ...d.data() }));
}

// ════════════════════════════════════════════════════════════════════════════
// Comments
// ════════════════════════════════════════════════════════════════════════════

test('a comment tells the POST OWNER, and records it', async () => {
  const { owner, friend } = people('owner', 'friend');
  await Promise.all([named(friend, 'Sam'), befriend(owner, friend), register(owner, 'tok-owner')]);
  await post(owner, 'p1');
  const data = await comment('p1', 'c1', friend, 'great set');

  const res = await O.enqueuePostComment(db(), {
    postId: 'p1', commentId: 'c1', beforeData: null, afterData: data, eventId: 'e1',
  });
  assert.equal(res.enqueued, true);

  const record = await activityOf(owner, res.activityId);
  assert.equal(record.type, 'postComment');
  assert.equal(record.actorUid, friend);
  assert.equal(record.subject, 'post:p1');
  assert.equal(record.commentId, 'c1');
  assert.equal(record.read, false);
  assert.equal(record.preview, 'great set');

  const fcm = fakeMessaging();
  const out = await run(res.jobId, fcm);
  assert.equal(out.status, 'sent');
  assert.equal(fcm.calls.length, 1);
  assert.equal(fcm.calls[0].token, 'tok-owner');
  assert.equal(fcm.calls[0].data.postId, 'p1');
  assert.equal(fcm.calls[0].data.commentId, 'c1');
  assert.equal(fcm.calls[0].data.activityId, res.activityId);
  assert.equal(fcm.calls[0].notification.body, 'Sam commented on your post');
  assert.ok(!JSON.stringify(fcm.calls[0]).includes('great set'),
    'the comment text stays out of the payload while previews are off');
});

test('commenting on your OWN post tells nobody', async () => {
  const { owner } = people('owner');
  await post(owner, 'p2');
  const data = await comment('p2', 'c1', owner, 'note to self');
  const res = await O.enqueuePostComment(db(), {
    postId: 'p2', commentId: 'c1', beforeData: null, afterData: data, eventId: 'e1',
  });
  assert.equal(res.enqueued, false);
  assert.equal(res.reason, 'self-action');
  assert.deepEqual(await activityList(owner), []);
});

test('an edit and a deletion are not new comments', async () => {
  const { owner, friend } = people('owner', 'friend');
  await befriend(owner, friend);
  await post(owner, 'p3');
  const first = { uid: friend, text: 'nice' };
  const edited = { uid: friend, text: 'nice!!' };
  for (const after of [edited, null]) {
    assert.equal((await O.enqueuePostComment(db(), {
      postId: 'p3', commentId: 'c1', beforeData: first, afterData: after, eventId: 'e2',
    })).reason, 'no-such-activity', 'nothing was ever recorded to change');
  }
  assert.deepEqual(await activityList(owner), []);
});

// ════════════════════════════════════════════════════════════════════════════
// Replays and events out of order
//
// Firestore events are at-least-once and unordered. Each of these is a real
// sequence that used to leave the owner with activity contradicting the post.
// ════════════════════════════════════════════════════════════════════════════

test('a creation event replayed after the like was taken back does not revive it',
  async () => {
    const { owner, friend } = people('owner', 'friend');
    await Promise.all([befriend(owner, friend), register(owner, 'tok-rp')]);
    await post(owner, 'pr1');
    const like = { createdAt: Timestamp().fromMillis(Date.now()) };
    await db().doc(`posts/pr1/likes/${friend}`).set(like);

    const first = await O.enqueuePostReaction(db(), {
      kind: 'like', postId: 'pr1', actorUid: friend, beforeData: null, afterData: like, eventId: 'e1',
    });
    assert.equal(first.enqueued, true);

    // The like is taken back, and the withdrawal is processed.
    await db().doc(`posts/pr1/likes/${friend}`).delete();
    assert.equal((await O.enqueuePostReaction(db(), {
      kind: 'like', postId: 'pr1', actorUid: friend, beforeData: like, afterData: null, eventId: 'e2',
    })).reason, 'reaction-retired');

    // Now the ORIGINAL creation event is delivered again.
    const replay = await O.enqueuePostReaction(db(), {
      kind: 'like', postId: 'pr1', actorUid: friend, beforeData: null, afterData: like, eventId: 'e1',
    });
    assert.equal(replay.enqueued, false);
    assert.match(replay.reason, /^interaction-gone/);
    const record = await activityOf(owner, first.activityId);
    assert.equal(record.invalidated, true,
      'the like is not there, so neither is the activity');
  });

test('a deletion processed before the creation leaves no active activity',
  async () => {
    const { owner, friend } = people('owner', 'friend');
    await Promise.all([befriend(owner, friend), register(owner, 'tok-oo')]);
    await post(owner, 'pr2');
    const like = { createdAt: Timestamp().fromMillis(Date.now()) };
    // The like existed and is already gone; only the events are in flight.
    const deletion = await O.enqueuePostReaction(db(), {
      kind: 'like', postId: 'pr2', actorUid: friend, beforeData: like, afterData: null, eventId: 'e2',
    });
    assert.equal(deletion.reason, 'no-such-activity');

    // The creation event arrives late.
    const late = await O.enqueuePostReaction(db(), {
      kind: 'like', postId: 'pr2', actorUid: friend, beforeData: null, afterData: like, eventId: 'e1',
    });
    assert.equal(late.enqueued, false);
    assert.equal(late.reason, 'interaction-gone');
    assert.deepEqual(await activityList(owner), [],
      'no unread activity for a like nobody can see');
    const jobs = await db().collection('pushOutbox')
      .where('recipientUid', '==', owner).get();
    assert.equal(jobs.size, 0, 'and no alert to deliver');
  });

test('a deletion event arriving after a genuine re-add leaves the record counting',
  async () => {
    const { owner, friend } = people('owner', 'friend');
    await Promise.all([befriend(owner, friend), register(owner, 'tok-ra')]);
    await post(owner, 'pr3');
    const like = { createdAt: Timestamp().fromMillis(Date.now()) };
    await db().doc(`posts/pr3/likes/${friend}`).set(like);
    const first = await O.enqueuePostReaction(db(), {
      kind: 'like', postId: 'pr3', actorUid: friend, beforeData: null, afterData: like, eventId: 'e1',
    });

    // Taken back and given again before the withdrawal event is processed.
    await db().doc(`posts/pr3/likes/${friend}`).delete();
    await db().doc(`posts/pr3/likes/${friend}`).set(like);

    const late = await O.enqueuePostReaction(db(), {
      kind: 'like', postId: 'pr3', actorUid: friend, beforeData: like, afterData: null, eventId: 'e2',
    });
    assert.equal(late.reason, 'not-a-new-reaction',
      'the like is there: nothing to retire');
    const record = await activityOf(owner, first.activityId);
    assert.equal(record.invalidated, false, 'still counts, because it is real');
    assert.equal(record.read, false);
  });

test('an edit event out of order never restores older words', async () => {
  const { owner, friend } = people('owner', 'friend');
  await Promise.all([befriend(owner, friend), register(owner, 'tok-ed2')]);
  await post(owner, 'pr4');
  const v1 = await comment('pr4', 'c1', friend, 'first words');
  const created = await O.enqueuePostComment(db(), {
    postId: 'pr4', commentId: 'c1', beforeData: null, afterData: v1, eventId: 'e1',
  });
  assert.equal(created.enqueued, true);

  // The comment is edited twice; only the second is in the store.
  const v2 = { ...v1, text: 'second words' };
  const v3 = { ...v1, text: 'final words' };
  await db().doc('posts/pr4/comments/c1').set(v3);

  // The FIRST edit's event arrives last, carrying stale text.
  const stale = await O.enqueuePostComment(db(), {
    postId: 'pr4', commentId: 'c1', beforeData: v1, afterData: v2, eventId: 'e2',
  });
  assert.equal(stale.enqueued, false);
  assert.equal((await activityOf(owner, created.activityId)).preview, 'final words',
    'the row says what the comment says, not what an old event carried');
  assert.equal(stale.reason, 'comment-refreshed');
});

test('a message deletion event after the message came back keeps the reaction',
  async () => {
    const { sender, other } = people('sender', 'other');
    const convId = convIdFor(sender, other);
    await Promise.all([befriend(sender, other), register(sender, 'tok-mb')]);
    await db().doc(`conversations/${convId}`).set({
      participants: { [sender]: true, [other]: true },
    });
    const base = { senderId: sender, text: 'hi' };
    const withClap = { ...base, reactions: { [other]: '👏' } };
    await db().doc(`conversations/${convId}/messages/m1`).set(withClap);
    const res = await O.enqueueDmReactions(db(), {
      convId, messageId: 'm1', beforeData: base, afterData: withClap, eventId: 'e1',
    });
    const activityId = res.results[0].activityId;

    // A stale deletion event, while the message and its reaction are there.
    await O.enqueueDmReactions(db(), {
      convId, messageId: 'm1', beforeData: withClap, afterData: null, eventId: 'e2',
    });
    assert.equal((await activityOf(sender, activityId)).invalidated, false,
      'the reaction is on the message right now');
  });

test('a post-deletion event delivered after the post is back retires nothing',
  async () => {
    const { owner, friend } = people('owner', 'friend');
    await befriend(owner, friend);
    await post(owner, 'pr5');
    const c = await comment('pr5', 'c1', friend, 'still here');
    const made = await O.enqueuePostComment(db(), {
      postId: 'pr5', commentId: 'c1', beforeData: null, afterData: c, eventId: 'e1',
    });
    const postData = (await db().doc('posts/pr5').get()).data();

    const out = await O.retirePostActivity(db(), { postId: 'pr5', beforeData: postData });
    assert.equal(out.reason, 'post-present');
    assert.equal((await activityOf(owner, made.activityId)).invalidated, false);
  });

test('a deleted comment stops counting but is not forgotten', async () => {
  const { owner, friend } = people('owner', 'friend');
  await Promise.all([befriend(owner, friend), register(owner, 'tok-del')]);
  await post(owner, 'pd1');
  const data = await comment('pd1', 'c1', friend, 'oops wrong post');
  const res = await O.enqueuePostComment(db(), {
    postId: 'pd1', commentId: 'c1', beforeData: null, afterData: data, eventId: 'e1',
  });
  assert.equal(res.enqueued, true);

  await db().doc(`posts/pd1/comments/c1`).delete();
  const gone = await O.enqueuePostComment(db(), {
    postId: 'pd1', commentId: 'c1', beforeData: data, afterData: null, eventId: 'e2',
  });
  assert.equal(gone.reason, 'comment-retired');

  const record = await activityOf(owner, res.activityId);
  assert.equal(record.invalidated, true, 'out of the badge and the list');
  assert.equal(record.invalidReason, 'comment-deleted');

  // Nothing left to announce, so a job still waiting is dropped rather than
  // sent — and the record is still there, so a replayed create cannot alert
  // a second time.
  const fcm = fakeMessaging();
  const out = await run(res.jobId, fcm);
  assert.equal(fcm.calls.length, 0, 'a comment that is gone is never announced');
  assert.notEqual(out.status, 'sent');

  const replay = await O.enqueuePostComment(db(), {
    postId: 'pd1', commentId: 'c1', beforeData: null, afterData: data, eventId: 'e1',
  });
  assert.equal(replay.enqueued, false, 'no second alert');
  assert.equal((await activityList(owner)).length, 1, 'and no second record');
});

test('an edited comment corrects its Activity row without alerting again', async () => {
  const { owner, friend } = people('owner', 'friend');
  await Promise.all([befriend(owner, friend), register(owner, 'tok-ed')]);
  await post(owner, 'pe1');
  const first = await comment('pe1', 'c1', friend, 'grate set');
  const res = await O.enqueuePostComment(db(), {
    postId: 'pe1', commentId: 'c1', beforeData: null, afterData: first, eventId: 'e1',
  });
  assert.equal(res.enqueued, true);

  const edited = { ...first, text: 'great set' };
  await db().doc('posts/pe1/comments/c1').set(edited);
  const after = await O.enqueuePostComment(db(), {
    postId: 'pe1', commentId: 'c1', beforeData: first, afterData: edited, eventId: 'e2',
  });
  assert.equal(after.enqueued, false, 'a typo fixed is not news');
  assert.equal(after.reason, 'comment-refreshed');

  const record = await activityOf(owner, res.activityId);
  assert.equal(record.preview, 'great set');
  assert.equal(record.read, false, 'still unread — it was never presented');
  assert.equal(record.invalidated, false);
  const jobs = await db().collection('pushOutbox')
    .where('recipientUid', '==', owner).get();
  assert.equal(jobs.size, 1, 'one interaction, one job');
});

test('deleting the post retires everything on it', async () => {
  const { owner, friend, other } = people('owner', 'friend', 'other');
  await Promise.all([befriend(owner, friend), befriend(owner, other)]);
  await post(owner, 'pk1');
  const c = await comment('pk1', 'c1', friend, 'strong');
  const commented = await O.enqueuePostComment(db(), {
    postId: 'pk1', commentId: 'c1', beforeData: null, afterData: c, eventId: 'e1',
  });
  const likeData = { createdAt: Timestamp().fromMillis(Date.now()) };
  await db().doc(`posts/pk1/likes/${other}`).set(likeData);
  const liked = await O.enqueuePostReaction(db(), {
    kind: 'like', postId: 'pk1', actorUid: other, beforeData: null, afterData: likeData, eventId: 'e2',
  });
  assert.equal(commented.enqueued, true);
  assert.equal(liked.enqueued, true);

  const postData = (await db().doc('posts/pk1').get()).data();
  await db().doc('posts/pk1').delete();
  const out = await O.retirePostActivity(db(), { postId: 'pk1', beforeData: postData });
  assert.equal(out.retired, 2, 'the comment and the like both stop counting');

  for (const id of [commented.activityId, liked.activityId]) {
    const record = await activityOf(owner, id);
    assert.equal(record.invalidated, true, id);
    assert.equal(record.invalidReason, 'post-deleted', id);
  }
  // Running it again is harmless and writes nothing further.
  assert.equal((await O.retirePostActivity(db(), {
    postId: 'pk1', beforeData: postData,
  })).retired, 0);
});

test('a replayed event neither alerts twice nor un-reads what was read',
  async () => {
    const { owner, friend } = people('owner', 'friend');
    await Promise.all([befriend(owner, friend), register(owner, 'tok-r')]);
    await post(owner, 'p4');
    const data = await comment('p4', 'c1', friend, 'hi');
    const first = await O.enqueuePostComment(db(), {
      postId: 'p4', commentId: 'c1', beforeData: null, afterData: data, eventId: 'e1',
    });
    assert.equal(first.enqueued, true);

    // The person reads it in the app.
    await db().doc(`users/${owner}/socialActivity/${first.activityId}`)
      .update({ read: true, readAt: Timestamp().fromMillis(Date.now()) });

    // The same event is delivered again.
    const replay = await O.enqueuePostComment(db(), {
      postId: 'p4', commentId: 'c1', beforeData: null, afterData: data, eventId: 'e1',
    });
    assert.equal(replay.enqueued, false);
    assert.equal(replay.reason, 'duplicate');
    assert.equal((await activityOf(owner, first.activityId)).read, true,
      'the record stays read');
    assert.equal((await activityList(owner)).length, 1, 'and there is still one');

    // And a worker that runs late does not alert about something already read.
    const fcm = fakeMessaging();
    const out = await run(first.jobId, fcm);
    assert.equal(out.reason, 'already-read');
    assert.equal(fcm.calls.length, 0);
  });

test('a comment on a post that has since been deleted is dropped', async () => {
  const { owner, friend } = people('owner', 'friend');
  await Promise.all([befriend(owner, friend), register(owner, 'tok-d')]);
  await post(owner, 'p5');
  const data = await comment('p5', 'c1', friend, 'hi');
  const res = await O.enqueuePostComment(db(), {
    postId: 'p5', commentId: 'c1', beforeData: null, afterData: data, eventId: 'e1',
  });
  await db().doc('posts/p5').delete();

  const fcm = fakeMessaging();
  const out = await run(res.jobId, fcm);
  assert.equal(out.status, 'skipped');
  assert.equal(out.reason, 'post-gone');
  assert.equal(fcm.calls.length, 0);
});

test('a comment deleted before the alert goes out is dropped', async () => {
  const { owner, friend } = people('owner', 'friend');
  await Promise.all([befriend(owner, friend), register(owner, 'tok-c')]);
  await post(owner, 'p6');
  const data = await comment('p6', 'c1', friend, 'oops');
  const res = await O.enqueuePostComment(db(), {
    postId: 'p6', commentId: 'c1', beforeData: null, afterData: data, eventId: 'e1',
  });
  await db().doc('posts/p6/comments/c1').delete();
  const out = await run(res.jobId, fakeMessaging());
  assert.equal(out.reason, 'comment-gone');
});

test('previews on put the comment in the alert; off keeps it out', async () => {
  const { owner, friend } = people('owner', 'friend');
  await Promise.all([named(friend, 'Sam'), befriend(owner, friend), register(owner, 'tok-p')]);
  await db().doc(`pushPreferences/${owner}`).set({ commentPreviews: true });
  await post(owner, 'p7');
  const data = await comment('p7', 'c1', friend, 'my door code is 4417');
  const res = await O.enqueuePostComment(db(), {
    postId: 'p7', commentId: 'c1', beforeData: null, afterData: data, eventId: 'e1',
  });
  const fcm = fakeMessaging();
  await run(res.jobId, fcm);
  assert.equal(fcm.calls[0].notification.title, 'Sam commented');
  assert.equal(fcm.calls[0].notification.body, 'my door code is 4417');
});

test('switching the comment category off stops the alert but keeps the record',
  async () => {
    const { owner, friend } = people('owner', 'friend');
    await Promise.all([befriend(owner, friend), register(owner, 'tok-off')]);
    await db().doc(`pushPreferences/${owner}`).set({ postComments: false });
    await post(owner, 'p8');
    const data = await comment('p8', 'c1', friend, 'hi');
    const res = await O.enqueuePostComment(db(), {
      postId: 'p8', commentId: 'c1', beforeData: null, afterData: data, eventId: 'e1',
    });
    const fcm = fakeMessaging();
    const out = await run(res.jobId, fcm);
    assert.equal(out.reason, 'preference-off');
    assert.equal(fcm.calls.length, 0);
    const record = await activityOf(owner, res.activityId);
    assert.equal(record.read, false,
      'in-app activity does not depend on the push category');
  });

// ════════════════════════════════════════════════════════════════════════════
// Likes and Good Lifts
// ════════════════════════════════════════════════════════════════════════════

test('a like tells the owner once, however often it is taken back and given again',
  async () => {
    const { owner, friend } = people('owner', 'friend');
    await Promise.all([named(friend, 'Sam'), befriend(owner, friend), register(owner, 'tok-l')]);
    await post(owner, 'p9');
    const like = { createdAt: Timestamp().fromMillis(Date.now()) };
    await db().doc(`posts/p9/likes/${friend}`).set(like);

    const first = await O.enqueuePostReaction(db(), {
      kind: 'like', postId: 'p9', actorUid: friend, beforeData: null, afterData: like, eventId: 'e1',
    });
    assert.equal(first.enqueued, true);
    const fcm = fakeMessaging();
    await run(first.jobId, fcm);
    assert.equal(fcm.calls[0].notification.body, 'Sam liked your post');

    // Un-like: no new alert, and the like stops counting.
    await db().doc(`posts/p9/likes/${friend}`).delete();
    const removed = await O.enqueuePostReaction(db(), {
      kind: 'like', postId: 'p9', actorUid: friend, beforeData: like, afterData: null, eventId: 'e2',
    });
    assert.equal(removed.reason, 'reaction-retired');
    assert.equal((await activityOf(owner, first.activityId)).invalidated, true);

    // Re-like: the same occurrence, so no second job and no second record —
    // the one that is already there simply counts again.
    await db().doc(`posts/p9/likes/${friend}`).set(like);
    const again = await O.enqueuePostReaction(db(), {
      kind: 'like', postId: 'p9', actorUid: friend, beforeData: null, afterData: like, eventId: 'e3',
    });
    assert.equal(again.enqueued, false);
    assert.equal(again.reason, 'revived');
    const record = await activityOf(owner, first.activityId);
    assert.equal(record.invalidated, false);
    assert.equal(record.read, false, 'it was never presented, so it is still unread');
    assert.equal((await activityList(owner)).length, 1);
    const jobs = await db().collection('pushOutbox')
      .where('recipientUid', '==', owner).get();
    assert.equal(jobs.size, 1, 'one alert, however many times they change their mind');
  });

test('a Good Lift is its own alert, with its own wording', async () => {
  const { owner, friend } = people('owner', 'friend');
  await Promise.all([named(friend, 'Sam'), befriend(owner, friend), register(owner, 'tok-g')]);
  await post(owner, 'p10', { mediaType: 'video' });
  const gl = { createdAt: Timestamp().fromMillis(Date.now()) };
  await db().doc(`posts/p10/goodLifts/${friend}`).set(gl);
  const res = await O.enqueuePostReaction(db(), {
    kind: 'goodLift', postId: 'p10', actorUid: friend, beforeData: null, afterData: gl, eventId: 'e1',
  });
  const fcm = fakeMessaging();
  await run(res.jobId, fcm);
  assert.equal(fcm.calls[0].notification.body, 'Sam gave your video a Good Lift');
  assert.equal(fcm.calls[0].android.notification.channelId, 'goodlift_post_reactions');
});

test('a like withdrawn before delivery is never announced', async () => {
  const { owner, friend } = people('owner', 'friend');
  await Promise.all([befriend(owner, friend), register(owner, 'tok-w')]);
  await post(owner, 'p11');
  const like = { createdAt: Timestamp().fromMillis(Date.now()) };
  await db().doc(`posts/p11/likes/${friend}`).set(like);
  const res = await O.enqueuePostReaction(db(), {
    kind: 'like', postId: 'p11', actorUid: friend, beforeData: null, afterData: like, eventId: 'e1',
  });
  await db().doc(`posts/p11/likes/${friend}`).delete();
  const fcm = fakeMessaging();
  const out = await run(res.jobId, fcm);
  assert.equal(out.reason, 'reaction-withdrawn');
  assert.equal(fcm.calls.length, 0);
});

test('somebody who is no longer a friend is not enqueued, and a friendship that '
  + 'ends before delivery stops the alert', async () => {
  const { owner, friend, stranger } = people('owner', 'friend', 'stranger');
  await Promise.all([befriend(owner, friend), register(owner, 'tok-f')]);
  await post(owner, 'p12');
  const like = { createdAt: Timestamp().fromMillis(Date.now()) };

  const outsider = await O.enqueuePostReaction(db(), {
    kind: 'like', postId: 'p12', actorUid: stranger, beforeData: null, afterData: like, eventId: 'e1',
  });
  assert.equal(outsider.reason, 'not-friends');

  await db().doc(`posts/p12/likes/${friend}`).set(like);
  const res = await O.enqueuePostReaction(db(), {
    kind: 'like', postId: 'p12', actorUid: friend, beforeData: null, afterData: like, eventId: 'e2',
  });
  await unfriend(owner, friend);
  const out = await run(res.jobId, fakeMessaging());
  assert.equal(out.reason, 'not-friends');
});

test('two people liking one post are two records and two alerts', async () => {
  const { owner, a, b } = people('owner', 'a', 'b');
  await Promise.all([befriend(owner, a), befriend(owner, b), register(owner, 'tok-2')]);
  await post(owner, 'p13');
  const like = { createdAt: Timestamp().fromMillis(Date.now()) };
  await db().doc(`posts/p13/likes/${a}`).set(like);
  await db().doc(`posts/p13/likes/${b}`).set(like);
  const first = await O.enqueuePostReaction(db(), {
    kind: 'like', postId: 'p13', actorUid: a, beforeData: null, afterData: like, eventId: 'e1',
  });
  const second = await O.enqueuePostReaction(db(), {
    kind: 'like', postId: 'p13', actorUid: b, beforeData: null, afterData: like, eventId: 'e2',
  });
  assert.notEqual(first.activityId, second.activityId);
  assert.equal((await activityList(owner)).length, 2);

  const fcm = fakeMessaging();
  await run(first.jobId, fcm);
  await run(second.jobId, fcm);
  assert.equal(fcm.calls.length, 2);
  assert.notEqual(
    fcm.calls[0].android.notification.tag,
    fcm.calls[1].android.notification.tag,
    'two interactions are two alerts, not one replacing the other',
  );
  // Both belong to the same post, so reading it cancels both.
  const prefix = `post|${P.subjectTagKey('p13')}|`;
  assert.ok(fcm.calls.every((m) => m.android.notification.tag.startsWith(prefix)));
});

// ════════════════════════════════════════════════════════════════════════════
// Message reactions
// ════════════════════════════════════════════════════════════════════════════

test('a reaction tells the message SENDER and never counts as a message',
  async () => {
    const { sender, other } = people('sender', 'other');
    const convId = convIdFor(sender, other);
    await Promise.all([named(other, 'Sam'), befriend(sender, other), register(sender, 'tok-x')]);
    await db().doc(`conversations/${convId}`).set({
      participants: { [sender]: true, [other]: true },
    });
    const before = { senderId: sender, text: 'session done' };
    await db().doc(`conversations/${convId}/messages/m1`).set(before);
    const after = { ...before, reactions: { [other]: '🔥' } };
    await db().doc(`conversations/${convId}/messages/m1`).set(after);

    const res = await O.enqueueDmReactions(db(), {
      convId, messageId: 'm1', beforeData: before, afterData: after, eventId: 'e1',
    });
    assert.equal(res.enqueued, true);
    const created = res.results[0];
    const record = await activityOf(sender, created.activityId);
    assert.equal(record.type, 'dmReaction');
    assert.equal(record.actorUid, other);
    assert.equal(record.emoji, '🔥');
    assert.equal(record.subject, `dm:${convId}`);

    const fcm = fakeMessaging();
    const out = await run(created.jobId, fcm);
    assert.equal(out.status, 'sent');
    assert.equal(fcm.calls[0].notification.body, 'Sam reacted 🔥 to your message');
    assert.equal(fcm.calls[0].data.msgId, 'm1');

    // The unread-MESSAGE ledger is untouched by a reaction.
    const conv = (await db().doc(`conversations/${convId}`).get()).data();
    const state = (conv.participantState || {})[sender] || {};
    assert.ok(!state.incoming, 'a reaction is not an incoming message');
    assert.equal(U.isAcknowledged(conv, sender, 1), false);
  });

test('changing the emoji, and removing it, do not alert again', async () => {
  const { sender, other } = people('sender', 'other');
  const convId = convIdFor(sender, other);
  await Promise.all([befriend(sender, other), register(sender, 'tok-y')]);
  await db().doc(`conversations/${convId}`).set({
    participants: { [sender]: true, [other]: true },
  });
  const base = { senderId: sender, text: 'hi' };
  const withFire = { ...base, reactions: { [other]: '🔥' } };
  const withHeart = { ...base, reactions: { [other]: '❤️' } };
  await db().doc(`conversations/${convId}/messages/m1`).set(withFire);

  const first = await O.enqueueDmReactions(db(), {
    convId, messageId: 'm1', beforeData: base, afterData: withFire, eventId: 'e1',
  });
  assert.equal(first.enqueued, true);

  const activityId = first.results[0].activityId;

  await db().doc(`conversations/${convId}/messages/m1`).set(withHeart);
  const changed = await O.enqueueDmReactions(db(), {
    convId, messageId: 'm1', beforeData: withFire, afterData: withHeart, eventId: 'e2',
  });
  assert.equal(changed.enqueued, false, 'a swapped emoji is not a new interaction');
  assert.equal(changed.reason, 'reaction-refreshed');
  // The list must not go on showing the emoji they changed their mind about.
  assert.equal((await activityOf(sender, activityId)).emoji, '❤️');

  await db().doc(`conversations/${convId}/messages/m1`).set(base);
  const removed = await O.enqueueDmReactions(db(), {
    convId, messageId: 'm1', beforeData: withHeart, afterData: base, eventId: 'e3',
  });
  assert.equal(removed.enqueued, false);
  assert.equal(removed.reason, 'reaction-retired');
  assert.equal((await activityOf(sender, activityId)).invalidated, true,
    'a reaction that is no longer there stops counting');
  assert.equal((await activityList(sender)).length, 1, 'one record throughout');
});

test('deleting the message takes its reaction activity with it', async () => {
  const { sender, other } = people('sender', 'other');
  const convId = convIdFor(sender, other);
  await Promise.all([befriend(sender, other), register(sender, 'tok-md')]);
  await db().doc(`conversations/${convId}`).set({
    participants: { [sender]: true, [other]: true },
  });
  const base = { senderId: sender, text: 'hi' };
  const after = { ...base, reactions: { [other]: '👏' } };
  await db().doc(`conversations/${convId}/messages/m1`).set(after);
  const res = await O.enqueueDmReactions(db(), {
    convId, messageId: 'm1', beforeData: base, afterData: after, eventId: 'e1',
  });
  const activityId = res.results[0].activityId;

  await db().doc(`conversations/${convId}/messages/m1`).delete();
  const gone = await O.enqueueDmReactions(db(), {
    convId, messageId: 'm1', beforeData: after, afterData: null, eventId: 'e2',
  });
  assert.equal(gone.reason, 'reaction-retired');
  const record = await activityOf(sender, activityId);
  assert.equal(record.invalidated, true);
  assert.equal(record.invalidReason, 'message-deleted');
});

test('reacting to your own message tells nobody', async () => {
  const { sender, other } = people('sender', 'other');
  const convId = convIdFor(sender, other);
  await befriend(sender, other);
  const base = { senderId: sender, text: 'hi' };
  const after = { ...base, reactions: { [sender]: '👍' } };
  const res = await O.enqueueDmReactions(db(), {
    convId, messageId: 'm1', beforeData: base, afterData: after, eventId: 'e1',
  });
  assert.equal(res.enqueued, false);
  assert.deepEqual(await activityList(sender), []);
});

test('a reaction the sender has already read is not alerted about', async () => {
  const { sender, other } = people('sender', 'other');
  const convId = convIdFor(sender, other);
  await Promise.all([befriend(sender, other), register(sender, 'tok-z')]);
  await db().doc(`conversations/${convId}`).set({
    participants: { [sender]: true, [other]: true },
  });
  const base = { senderId: sender, text: 'hi' };
  const after = { ...base, reactions: { [other]: '👏' } };
  await db().doc(`conversations/${convId}/messages/m1`).set(after);
  const res = await O.enqueueDmReactions(db(), {
    convId, messageId: 'm1', beforeData: base, afterData: after, eventId: 'e1',
  });
  const created = res.results[0];
  await db().doc(`users/${sender}/socialActivity/${created.activityId}`)
    .update({ read: true, readAt: Timestamp().fromMillis(Date.now()) });

  const fcm = fakeMessaging();
  const out = await run(created.jobId, fcm);
  assert.equal(out.reason, 'already-read');
  assert.equal(fcm.calls.length, 0);
});

test('a message deleted before delivery drops its reaction alert', async () => {
  const { sender, other } = people('sender', 'other');
  const convId = convIdFor(sender, other);
  await Promise.all([befriend(sender, other), register(sender, 'tok-q')]);
  await db().doc(`conversations/${convId}`).set({
    participants: { [sender]: true, [other]: true },
  });
  const base = { senderId: sender, text: 'hi' };
  const after = { ...base, reactions: { [other]: '👍' } };
  await db().doc(`conversations/${convId}/messages/m1`).set(after);
  const res = await O.enqueueDmReactions(db(), {
    convId, messageId: 'm1', beforeData: base, afterData: after, eventId: 'e1',
  });
  await db().doc(`conversations/${convId}/messages/m1`).delete();
  const out = await run(res.results[0].jobId, fakeMessaging());
  assert.equal(out.reason, 'message-gone');
});

// ════════════════════════════════════════════════════════════════════════════
// No backlog on deployment
// ════════════════════════════════════════════════════════════════════════════

test('interactions that already exist produce nothing until something changes',
  async () => {
    // What deploying looks like: history is in place, and no event fires for
    // it. The triggers act only on writes, and only on transitions.
    const { owner, friend } = people('owner', 'friend');
    await befriend(owner, friend);
    await post(owner, 'p14');
    await db().doc(`posts/p14/likes/${friend}`).set({ createdAt: Timestamp().fromMillis(1) });
    await comment('p14', 'old', friend, 'from last year');

    assert.deepEqual(await activityList(owner), [],
      'no records exist for history nobody wrote today');
    const jobs = await db().collection('pushOutbox')
      .where('recipientUid', '==', owner).get();
    assert.equal(jobs.size, 0);
  });
