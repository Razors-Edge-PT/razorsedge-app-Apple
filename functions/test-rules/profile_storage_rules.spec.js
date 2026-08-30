'use strict';

// Cloud Storage security-rules tests, run against the REAL rules engine in the
// Storage emulator:
//   npm run test:rules
//
// storage.rules previously existed only as a loose note in firestore_rules/*.txt
// and was not referenced by firebase.json, so nothing verified it and nothing
// deployed it. These cases pin the same access model the Firestore rules
// enforce, with the same critical property: an assigned COACH is not a social
// bypass for avatars' neighbours — posts, proofs, stories and lift videos.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');
const {
  ref, uploadBytes, getBytes, deleteObject,
} = require('firebase/storage');

const SUPER = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const OWNER = 'stgOwner';
const FRIEND = 'stgFriend';
const STRANGER = 'stgStranger';
const COACH = 'stgCoach';

const IMAGE = { contentType: 'image/jpeg' };
const VIDEO = { contentType: 'video/mp4' };
const BYTES = new Uint8Array([1, 2, 3, 4]);

let env;

test.before(async () => {
  const root = path.join(__dirname, '..', '..');
  env = await initializeTestEnvironment({
    projectId: 'rules-test',
    firestore: {
      rules: fs.readFileSync(path.join(root, 'firestore.rules'), 'utf8'),
    },
    storage: {
      rules: fs.readFileSync(path.join(root, 'storage.rules'), 'utf8'),
    },
  });

  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    // The Storage rules read this document to decide friendship.
    await db.doc(`buddyAssignments/${OWNER}`).set({
      athletes: { [FRIEND]: { status: 'accepted' } },
    });
    // COACH is assigned but is NOT a friend — the whole point of these cases.
    await db.doc(`athleteAssignments/${OWNER}`).set({
      coaches: { [COACH]: { approved: true } },
    });
    await db.doc(`accountEntitlements/${COACH}`).set({
      coach: { state: 'active', source: 'manual_review' },
    });

    // A LIVE story document for s1. Story media is now reachable only through
    // one — see storage.rules and test-rules/story_expiry_rules.spec.js — so
    // the social gate below is tested on a story that actually exists.
    await db.doc(`users/${OWNER}/stories/s1`).set({
      ownerUid: OWNER,
      mediaType: 'image',
      storagePath: `users/${OWNER}/stories/s1/original.jpg`,
      publishedAt: new Date(),
    });

    const storage = ctx.storage();
    for (const p of [
      `users/${OWNER}/profile/profile.jpg`,
      `users/${OWNER}/posts/p1/original.jpg`,
      `users/${OWNER}/posts/p2/original.mp4`,
      `users/${OWNER}/stories/s1/original.jpg`,
      `users/${OWNER}/liftVideos/lv1.mp4`,
    ]) {
      await uploadBytes(ref(storage, p), BYTES, IMAGE);
    }
  });
});

test.after(async () => {
  if (env) await env.cleanup();
});

const as = (uid) => env.authenticatedContext(uid).storage();
const anon = () => env.unauthenticatedContext().storage();

const read = (storage, p) => getBytes(ref(storage, p));
const write = (storage, p, meta = IMAGE) => uploadBytes(ref(storage, p), BYTES, meta);

// ── Avatar: any signed-in user may read, owner only may write ───────────────

test('any signed-in user can read an avatar', async () => {
  for (const uid of [OWNER, FRIEND, STRANGER, COACH]) {
    await assertSucceeds(read(as(uid), `users/${OWNER}/profile/profile.jpg`));
  }
});

test('only the owner may replace an avatar', async () => {
  await assertSucceeds(write(as(OWNER), `users/${OWNER}/profile/profile.jpg`));
  await assertFails(write(as(FRIEND), `users/${OWNER}/profile/profile.jpg`));
  await assertFails(write(as(COACH), `users/${OWNER}/profile/profile.jpg`));
  await assertFails(write(as(STRANGER), `users/${OWNER}/profile/profile.jpg`));
});

test('an avatar must be an image', async () => {
  await assertFails(write(as(OWNER), `users/${OWNER}/profile/profile.jpg`, VIDEO));
});

// ── Post media and proof videos ─────────────────────────────────────────────

test('a confirmed friend can read post media and proof videos', async () => {
  await assertSucceeds(read(as(FRIEND), `users/${OWNER}/posts/p1/original.jpg`));
  await assertSucceeds(read(as(FRIEND), `users/${OWNER}/posts/p2/original.mp4`));
});

test('a non-friend cannot read post media', async () => {
  await assertFails(read(as(STRANGER), `users/${OWNER}/posts/p1/original.jpg`));
});

test('an ASSIGNED COACH who is not a friend cannot read post or proof media', async () => {
  await assertFails(read(as(COACH), `users/${OWNER}/posts/p1/original.jpg`));
  await assertFails(read(as(COACH), `users/${OWNER}/posts/p2/original.mp4`));
});

test('only the owner may upload or delete post media', async () => {
  await assertSucceeds(write(as(OWNER), `users/${OWNER}/posts/p3/original.jpg`));
  await assertFails(write(as(FRIEND), `users/${OWNER}/posts/p4/original.jpg`));
  await assertFails(write(as(COACH), `users/${OWNER}/posts/p5/original.jpg`));
  await assertFails(
    deleteObject(ref(as(FRIEND), `users/${OWNER}/posts/p1/original.jpg`)),
  );
});

// ── Stories ─────────────────────────────────────────────────────────────────

test('live story media follows the same social gate as posts', async () => {
  await assertSucceeds(read(as(OWNER), `users/${OWNER}/stories/s1/original.jpg`));
  await assertSucceeds(read(as(FRIEND), `users/${OWNER}/stories/s1/original.jpg`));
  await assertFails(read(as(STRANGER), `users/${OWNER}/stories/s1/original.jpg`));
  await assertFails(read(as(COACH), `users/${OWNER}/stories/s1/original.jpg`));
});

test('story media with no story document is unreachable, friend or not', async () => {
  // s4 has an object and no record. Requiring the document is what stops a
  // download URL outliving the story it belonged to.
  await assertSucceeds(write(as(OWNER), `users/${OWNER}/stories/s4/original.jpg`));
  await assertFails(read(as(FRIEND), `users/${OWNER}/stories/s4/original.jpg`));
  await assertFails(read(as(OWNER), `users/${OWNER}/stories/s4/original.jpg`));
});

test('only the owner may upload a story', async () => {
  await assertSucceeds(write(as(OWNER), `users/${OWNER}/stories/s2/original.jpg`));
  await assertFails(write(as(FRIEND), `users/${OWNER}/stories/s3/original.jpg`));
});

// ── Legacy lift videos ──────────────────────────────────────────────────────

test('legacy lift videos keep their existing social gate', async () => {
  await assertSucceeds(read(as(FRIEND), `users/${OWNER}/liftVideos/lv1.mp4`));
  await assertFails(read(as(COACH), `users/${OWNER}/liftVideos/lv1.mp4`));
  await assertFails(read(as(STRANGER), `users/${OWNER}/liftVideos/lv1.mp4`));
});

// ── Logged out, super admin, and the fail-closed default ────────────────────

test('a logged-out visitor can read nothing', async () => {
  await assertFails(read(anon(), `users/${OWNER}/profile/profile.jpg`));
  await assertFails(read(anon(), `users/${OWNER}/posts/p1/original.jpg`));
  await assertFails(read(anon(), `users/${OWNER}/stories/s1/original.jpg`));
});

test('the super admin retains cross-account read', async () => {
  await assertSucceeds(read(as(SUPER), `users/${OWNER}/posts/p2/original.mp4`));
  await assertSucceeds(read(as(SUPER), `users/${OWNER}/stories/s1/original.jpg`));
});

test('an unlisted path fails closed even for the owner', async () => {
  await assertFails(write(as(OWNER), `users/${OWNER}/somethingInvented/x.jpg`));
  await assertFails(write(as(OWNER), 'random/top/level.jpg'));
  await assertFails(read(as(OWNER), 'random/top/level.jpg'));
});
