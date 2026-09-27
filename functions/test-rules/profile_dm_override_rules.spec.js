'use strict';

// The support profile + DM override, against the REAL rules engines
// (Firestore and Storage emulators):
//   npm run test:rules
//
// accessGrants/{uid}.profileAndDmOverride (server-written only) grants:
//   * friend-equivalent READ of a profile's friend-only content;
//   * a one-to-one conversation with anyone, the holder and that person its
//     only participants.
// And nothing else: no write to another account's data, no messaging as
// another uid, no conversation between two other people, no friendship
// change, and no way for any client to grant it.
//
// The privilege is tested on HOLDER — an ordinary account that is NOT the
// hard-coded super admin — so nothing here passes merely because of
// isSuperAdmin(). Richard's own account is covered at the end.

const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');
const { ref, uploadBytes, getBytes } = require('firebase/storage');

const pad = (s) => s.padEnd(28, 'x');
const RICHARD = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const TEST_ACCOUNT = 'jhIB7Yi1whYwPvBSmK27KltJGn23';
const HOLDER = pad('holder');   // holds the override; not a super admin
const ALICE = pad('alice');     // a non-friend of HOLDER
const BOB = pad('bob');         // ALICE's mutual friend
const CAROL = pad('carol');     // an ordinary non-friend of ALICE

const convId = (a, b) => [a, b].sort().join('_');
const IMAGE = { contentType: 'image/jpeg' };
const BYTES = new Uint8Array([1, 2, 3, 4]);

let env;

test.before(async () => {
  const root = path.join(__dirname, '..', '..');
  env = await initializeTestEnvironment({
    // The emulator project: Storage rules' firestore.get() reads this one.
    projectId: 'rules-test',
    firestore: { rules: fs.readFileSync(path.join(root, 'firestore.rules'), 'utf8') },
    storage: { rules: fs.readFileSync(path.join(root, 'storage.rules'), 'utf8') },
  });

  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc(`accessGrants/${HOLDER}`).set({ profileAndDmOverride: true });
    await db.doc(`accessGrants/${RICHARD}`).set({ profileAndDmOverride: true });

    await db.doc(`buddyAssignments/${ALICE}`).set({ athletes: { [BOB]: { status: 'accepted' } } });
    await db.doc(`buddyAssignments/${BOB}`).set({ athletes: { [ALICE]: { status: 'accepted' } } });

    await db.doc(`users/${ALICE}`).set({ bio: 'alice' });
    await db.doc(`users_public/${ALICE}`).set({ username: 'alice' });
    await db.doc('posts/p1').set({ ownerUid: ALICE, caption: 'hi', likeCount: 0 });
    await db.doc(`posts/p1/likes/${BOB}`).set({ at: 1 });
    await db.doc('posts/p1/comments/c1').set({ uid: BOB, text: 'nice' });
    await db.doc(`users/${ALICE}/liftVideos/v1`).set({ url: 'u' });
    await db.doc(`users/${ALICE}/proofs/f1`).set({ postId: 'p1' });
    await db.doc(`users/${ALICE}/stories/s1`).set({
      ownerUid: ALICE, publishedAt: new Date(), url: 'u',
    });
    await db.doc(`users/${ALICE}/stories/s1old`).set({
      ownerUid: ALICE, publishedAt: new Date(Date.now() - 48 * 3600 * 1000), url: 'u',
    });
    await db.doc(`users/${ALICE}/workouts/w1`).set({ date: '2026-09-01' });

    // An existing conversation between two OTHER people.
    await db.doc(`conversations/${convId(ALICE, BOB)}`).set({
      participants: { [ALICE]: true, [BOB]: true },
      participantList: [ALICE, BOB].sort(),
    });
    await db.doc(`conversations/${convId(ALICE, BOB)}/messages/m1`).set({ senderId: BOB, text: 'x' });

    const storage = ctx.storage();
    await uploadBytes(ref(storage, `users/${ALICE}/posts/p1/original.jpg`), BYTES, IMAGE);
    await uploadBytes(ref(storage, `users/${ALICE}/liftVideos/v1.jpg`), BYTES, IMAGE);
    await uploadBytes(ref(storage, `users/${ALICE}/stories/s1/image.jpg`), BYTES, IMAGE);
  });
});

test.after(async () => {
  await env.cleanup();
});

const fsOf = (uid) => env.authenticatedContext(uid).firestore();
const stOf = (uid) => env.authenticatedContext(uid).storage();

// ── Profile reads ─────────────────────────────────────────────────────────

test('holder reads a non-friend\'s friend-only profile content', async () => {
  const db = fsOf(HOLDER);
  await assertSucceeds(db.doc('posts/p1').get());
  await assertSucceeds(db.doc(`posts/p1/likes/${BOB}`).get());
  await assertSucceeds(db.doc('posts/p1/comments/c1').get());
  await assertSucceeds(db.doc(`users/${ALICE}/liftVideos/v1`).get());
  await assertSucceeds(db.doc(`users/${ALICE}/proofs/f1`).get());
  await assertSucceeds(db.doc(`users/${ALICE}/stories/s1`).get());
  await assertSucceeds(getBytes(ref(stOf(HOLDER), `users/${ALICE}/posts/p1/original.jpg`)));
  await assertSucceeds(getBytes(ref(stOf(HOLDER), `users/${ALICE}/liftVideos/v1.jpg`)));
  await assertSucceeds(getBytes(ref(stOf(HOLDER), `users/${ALICE}/stories/s1/image.jpg`)));
});

test('holder sees only what a friend sees: an expired story stays hidden', async () => {
  await assertFails(fsOf(HOLDER).doc(`users/${ALICE}/stories/s1old`).get());
});

test('holder gains no private or training access', async () => {
  const db = fsOf(HOLDER);
  await assertFails(db.doc(`users/${ALICE}`).get());
  await assertFails(db.doc(`users/${ALICE}/workouts/w1`).get());
  await assertFails(db.doc(`buddyAssignments/${ALICE}`).get());
});

test('an ordinary non-friend still cannot read friend-only content', async () => {
  for (const uid of [CAROL, TEST_ACCOUNT]) {
    const db = fsOf(uid);
    await assertFails(db.doc('posts/p1').get());
    await assertFails(db.doc('posts/p1/comments/c1').get());
    await assertFails(db.doc(`users/${ALICE}/liftVideos/v1`).get());
    await assertFails(db.doc(`users/${ALICE}/stories/s1`).get());
    await assertFails(getBytes(ref(stOf(uid), `users/${ALICE}/posts/p1/original.jpg`)));
    await assertFails(getBytes(ref(stOf(uid), `users/${ALICE}/stories/s1/image.jpg`)));
  }
  // …while a real friend still can (unchanged).
  await assertSucceeds(fsOf(BOB).doc('posts/p1').get());
});

// ── No writes to anybody else's content ───────────────────────────────────

test('holder cannot edit the profile owner\'s content or data', async () => {
  const db = fsOf(HOLDER);
  await assertFails(db.doc(`users/${ALICE}`).set({ bio: 'x' }, { merge: true }));
  await assertFails(db.doc(`users_public/${ALICE}`).set({ username: 'x' }, { merge: true }));
  await assertFails(db.doc('posts/p1').update({ caption: 'x' }));
  await assertFails(db.doc('posts/p1').update({ likeCount: 1 }));
  await assertFails(db.doc('posts/p1').delete());
  await assertFails(db.doc(`posts/p1/likes/${HOLDER}`).set({ at: 1 }));
  await assertFails(db.collection('posts/p1/comments').add({ uid: HOLDER, text: 'x' }));
  await assertFails(db.doc(`users/${ALICE}/stories/s1`).update({ caption: 'x' }));
  await assertFails(db.doc(`users/${ALICE}/liftVideos/v1`).set({ url: 'x' }));
  await assertFails(db.doc(`users/${ALICE}/workouts/w1`).set({ date: 'x' }));
  await assertFails(uploadBytes(ref(stOf(HOLDER), `users/${ALICE}/posts/p1/x.jpg`), BYTES, IMAGE));
});

test('holder cannot change a friendship except through the normal flow', async () => {
  const db = fsOf(HOLDER);
  await assertFails(db.doc(`buddyAssignments/${ALICE}`).set(
    { athletes: { [HOLDER]: { status: 'accepted' } } }, { merge: true }));
  await assertFails(db.doc(`socialGraph/${ALICE}`).set({ friends: [HOLDER] }));
});

// ── Direct messages ───────────────────────────────────────────────────────

const newConv = (a, b) => ({
  participants: { [a]: true, [b]: true },
  participantList: [a, b].sort(),
  lastMessage: null,
  participantState: { [a]: { unreadCount: 0 }, [b]: { unreadCount: 0 } },
});

test('holder opens and uses a conversation with a non-friend; the other person replies', async () => {
  const id = convId(HOLDER, ALICE);
  await assertSucceeds(fsOf(HOLDER).doc(`conversations/${id}`).set(newConv(HOLDER, ALICE)));
  await assertSucceeds(fsOf(HOLDER).doc(`conversations/${id}`).update({ updatedAt: 1 }));
  await assertSucceeds(fsOf(HOLDER).doc(`conversations/${id}/messages/h1`)
    .set({ senderId: HOLDER, text: 'hello' }));
  // The recipient reads and replies — no friendship involved.
  await assertSucceeds(fsOf(ALICE).doc(`conversations/${id}`).get());
  await assertSucceeds(fsOf(ALICE).doc(`conversations/${id}/messages/h1`).get());
  await assertSucceeds(fsOf(ALICE).doc(`conversations/${id}/messages/a1`)
    .set({ senderId: ALICE, text: 'hi' }));
  await assertSucceeds(fsOf(HOLDER).doc(`conversations/${id}/messages/a1`).get());
  // DM media, both ways.
  await assertSucceeds(uploadBytes(ref(stOf(HOLDER), `dm/${id}/h1/image_1.jpg`), BYTES, IMAGE));
  await assertSucceeds(getBytes(ref(stOf(ALICE), `dm/${id}/h1/image_1.jpg`)));
  // A third account sees none of it.
  await assertFails(fsOf(CAROL).doc(`conversations/${id}`).get());
  await assertFails(fsOf(CAROL).doc(`conversations/${id}/messages/h1`).get());
  await assertFails(getBytes(ref(stOf(CAROL), `dm/${id}/h1/image_1.jpg`)));
});

test('holder cannot message as another account', async () => {
  const id = convId(HOLDER, ALICE);
  await env.withSecurityRulesDisabled((ctx) => ctx.firestore().doc(`conversations/${id}`)
    .set(newConv(HOLDER, ALICE)));
  await assertFails(fsOf(HOLDER).doc(`conversations/${id}/messages/forged`)
    .set({ senderId: ALICE, text: 'as alice' }));
  await assertFails(fsOf(HOLDER).doc(`conversations/${id}`)
    .update({ participants: { [HOLDER]: true, [CAROL]: true } }));
});

test('holder cannot create or use a conversation between other people', async () => {
  const id = convId(ALICE, CAROL);
  await assertFails(fsOf(HOLDER).doc(`conversations/${id}`).set(newConv(ALICE, CAROL)));
  // Nor sneak itself into a pair id that is not its own.
  await assertFails(fsOf(HOLDER).doc(`conversations/${id}`).set({
    ...newConv(ALICE, CAROL),
    participants: { [ALICE]: true, [CAROL]: true, [HOLDER]: true },
  }));
  const ab = convId(ALICE, BOB);
  await assertFails(fsOf(HOLDER).doc(`conversations/${ab}/messages/x`)
    .set({ senderId: HOLDER, text: 'x' }));
  await assertFails(fsOf(HOLDER).doc(`conversations/${ab}`).update({ updatedAt: 2 }));
  await assertFails(uploadBytes(ref(stOf(HOLDER), `dm/${ab}/x/image_1.jpg`), BYTES, IMAGE));
});

test('only the holder may OPEN a non-friend conversation; the other person cannot start one', async () => {
  const id = convId(CAROL, HOLDER);
  await assertFails(fsOf(CAROL).doc(`conversations/${id}`).set(newConv(CAROL, HOLDER)));
});

test('an ordinary non-friend still cannot create a DM', async () => {
  for (const uid of [CAROL, TEST_ACCOUNT]) {
    const id = convId(uid, ALICE);
    await assertFails(fsOf(uid).doc(`conversations/${id}`).set(newConv(uid, ALICE)));
  }
  // Friends still can (unchanged).
  const ab = convId(ALICE, BOB);
  await assertSucceeds(fsOf(ALICE).doc(`conversations/${ab}/messages/m2`)
    .set({ senderId: ALICE, text: 'y' }));
});

// ── The grant itself ──────────────────────────────────────────────────────

test('no client can assign, extend or alter the privilege — not even the super admin', async () => {
  await assertFails(fsOf(CAROL).doc(`accessGrants/${CAROL}`).set({ profileAndDmOverride: true }));
  await assertFails(fsOf(TEST_ACCOUNT).doc(`accessGrants/${TEST_ACCOUNT}`)
    .set({ profileAndDmOverride: true }));
  await assertFails(fsOf(HOLDER).doc(`accessGrants/${CAROL}`).set({ profileAndDmOverride: true }));
  await assertFails(fsOf(HOLDER).doc(`accessGrants/${HOLDER}`).set({ other: true }, { merge: true }));
  await assertFails(fsOf(HOLDER).doc(`accessGrants/${HOLDER}`).delete());
  await assertFails(fsOf(RICHARD).doc(`accessGrants/${CAROL}`).set({ profileAndDmOverride: true }));
  await assertFails(fsOf(RICHARD).doc(`accessGrants/${TEST_ACCOUNT}`).set({ profileAndDmOverride: true }));
});

test('the grant list is readable when signed in (it drives display only)', async () => {
  await assertSucceeds(fsOf(CAROL).collection('accessGrants')
    .where('profileAndDmOverride', '==', true).get());
  await assertFails(env.unauthenticatedContext().firestore().collection('accessGrants').get());
});

test('the test account has no override: it cannot open a non-friend profile or DM', async () => {
  const db = fsOf(TEST_ACCOUNT);
  await assertFails(db.doc('posts/p1').get());
  await assertFails(db.doc(`conversations/${convId(TEST_ACCOUNT, ALICE)}`)
    .set(newConv(TEST_ACCOUNT, ALICE)));
});

// ── Richard's own account ─────────────────────────────────────────────────

test('Richard (holder) opens a DM with a non-friend and lists his conversations', async () => {
  const id = convId(RICHARD, CAROL);
  await assertSucceeds(fsOf(RICHARD).doc(`conversations/${id}`).set(newConv(RICHARD, CAROL)));
  await assertSucceeds(fsOf(CAROL).doc(`conversations/${id}/messages/c1`)
    .set({ senderId: CAROL, text: 'hi Richard' }));
  await assertSucceeds(fsOf(RICHARD).collection('conversations')
    .where('participantList', 'array-contains', RICHARD).get());
  await assertFails(fsOf(RICHARD).doc(`conversations/${id}/messages/forged`)
    .set({ senderId: CAROL, text: 'x' }));
});
