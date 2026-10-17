'use strict';

// PRODUCTION-HANDLER tests for the username reservation signup now depends
// on, run against the REAL Firestore emulator through firebase-admin:
//   npm run test:emulator
//
// Signup completes only after profileChangeUsername has reserved the name in
// its transaction. These prove the properties the app's retry logic relies
// on: a fresh account claims; a retry by the same account after a lost
// response is recognised as its own reservation; concurrent claimants end up
// with exactly one holder; a member who must pick another name after a
// collision releases nothing that belongs to anyone else; no auth, no claim.

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

let profileChangeUsername;
let usernameIndexKey;

test.before(() => {
  assert.ok(
    process.env.FIRESTORE_EMULATOR_HOST,
    'FIRESTORE_EMULATOR_HOST must be set — run through `npm run test:emulator`',
  );
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  }
  ({ profileChangeUsername } = require('../identity'));
  ({ usernameIndexKey } = require('../identity/username_rules'));
});

let seq = 0;
function freshUid() {
  seq += 1;
  return `signup_${Date.now()}_${seq}`;
}
function freshName(prefix = 'Lift') {
  return `${prefix}${Date.now() % 1e7}${seq}`;
}

function claim(uid, username) {
  return profileChangeUsername.run({
    auth: uid ? { uid, token: {} } : undefined,
    data: { username },
    rawRequest: {},
  });
}

async function holderOf(name) {
  const snap = await admin.firestore().collection('usernames')
    .doc(usernameIndexKey(name.trim().normalize('NFKC').toLowerCase())).get();
  return snap.exists ? snap.data().uid : null;
}

test('a fresh account claims and both profile documents carry the name', async () => {
  const uid = freshUid();
  const name = freshName();

  const res = await claim(uid, name);

  assert.equal(res.changed, true);
  assert.equal(res.username, name);
  assert.equal(res.usernameLower, name.toLowerCase());
  assert.equal(await holderOf(name), uid);
  const user = (await admin.firestore().doc(`users/${uid}`).get()).data();
  const pub = (await admin.firestore().doc(`users_public/${uid}`).get()).data();
  assert.equal(user.usernameLower, name.toLowerCase());
  assert.equal(pub.usernameLower, name.toLowerCase());
});

test('a retry by the same account (lost response) is accepted as its own', async () => {
  const uid = freshUid();
  const name = freshName();
  await claim(uid, name); // committed; pretend the client never saw this

  const retry = await claim(uid, name);

  assert.equal(retry.changed, false);
  assert.equal(retry.username, name);
  assert.equal(await holderOf(name), uid);
});

test('concurrent claimants for one name: exactly one holder', async () => {
  const name = freshName('Race');
  const uids = [freshUid(), freshUid(), freshUid(), freshUid()];

  const results = await Promise.allSettled(
    uids.map((u, i) => claim(u, i % 2 ? name.toUpperCase() : name)),
  );

  const won = results.filter((r) => r.status === 'fulfilled');
  const lost = results.filter((r) => r.status === 'rejected');
  assert.equal(won.length, 1, 'exactly one claimant wins');
  for (const r of lost) assert.equal(r.reason.code, 'already-exists');
  const winner = uids[results.findIndex((r) => r.status === 'fulfilled')];
  assert.equal(await holderOf(name), winner);
});

test('after a collision the member claims another name; the holder keeps theirs', async () => {
  const holder = freshUid();
  const member = freshUid();
  const taken = freshName('Taken');
  const fallback = freshName('Mine');
  await claim(holder, taken);

  await assert.rejects(claim(member, taken), (e) => e.code === 'already-exists');
  const res = await claim(member, fallback);

  assert.equal(res.changed, true);
  assert.equal(await holderOf(taken), holder);
  assert.equal(await holderOf(fallback), member);
});

test('a changed name before completion releases only the member\'s own old key', async () => {
  const member = freshUid();
  const first = freshName('First');
  const second = freshName('Second');
  await claim(member, first);

  await claim(member, second);

  assert.equal(await holderOf(first), null);
  assert.equal(await holderOf(second), member);
});

test('no auth session, no claim', async () => {
  await assert.rejects(claim(null, freshName()), (e) => e.code === 'unauthenticated');
});
