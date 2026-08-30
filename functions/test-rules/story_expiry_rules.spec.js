'use strict';

// Firestore AND Storage security-rules tests for the 24-hour story boundary,
// run against the REAL rules engines in the emulators:
//   npm run test:rules
//
// ── What was wrong ──────────────────────────────────────────────────────────
// Expiry used to live entirely in the client query and an hourly sweep. The
// Firestore rule was `allow read: if isSocial(userId)` with no clock in it at
// all, and the Storage rule carried a comment claiming the objects were "only
// ever reachable through a live story document" while checking for no such
// thing. So a friend who kept the document id — or the download URL, which is
// a bearer token — could read an expired story for the up-to-an-hour gap
// before the sweep, and a patched client could read it indefinitely.
//
// ── How the boundary is tested ──────────────────────────────────────────────
// A story is live while `now - publishedAt < 24h`. At EXACTLY 24 hours it is
// expired.
//
// `request.time` is the engine's own clock and cannot be frozen or advanced,
// so the age of a document is controlled by moving `publishedAt` instead. Three
// ages are covered on BOTH engines:
//
//   * inside the window   — a story with a few seconds of life left, read and
//                           allowed, then read AGAIN after its expiry passes
//                           and denied. The same document, no writes in
//                           between: that transition is the boundary being
//                           enforced against a live clock, which a single
//                           seeded age cannot demonstrate.
//   * exactly 24h         — publishedAt = now - 24h. Denied.
//   * after 24h           — publishedAt = now - 25h. Denied.
//
// The sub-millisecond strictness of `<` versus `<=` at the exact instant is
// unobservable through a wall clock and is pinned instead by the pure test in
// test/stories_expiry.test.js, which asserts isStoryLive() is false at exactly
// STORY_TTL_MS. The three rule constants agree by construction.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');
const { ref, uploadBytes, getBytes } = require('firebase/storage');

const SUPER = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const OWNER = 'storyExpiryOwner';
const FRIEND = 'storyExpiryFriend';
const STRANGER = 'storyExpiryStranger';

const TTL_MS = 24 * 60 * 60 * 1000;

/** How much life the "inside the window" story is seeded with. */
const EDGE_LIFE_MS = 4000;

const BYTES = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
const IMAGE = { contentType: 'image/jpeg' };

/** Story ids, one per case. */
const LIVE = 'expiryLive';     // published a minute ago
const EXACT = 'expiryExact';   // published exactly 24h ago  → expired
const PAST = 'expiryPast';     // published 25h ago          → expired
const ORPHAN = 'expiryOrphan'; // Storage object with NO story document

let env;

/**
 * The SAME project the emulator is configured for.
 *
 * Storage rules reach Firestore through `firestore.get`, and that lookup
 * resolves against the emulator's own Firestore project — not the projectId
 * this test environment was created with. Isolating this spec under its own
 * projectId (as the pure-Firestore specs do) writes the story documents
 * somewhere the Storage rules engine cannot see them, and every media read
 * fails for want of a document that is sitting right there.
 *
 * Sharing the project means never calling clearFirestore(): the other rules
 * specs run in the same process pool. Every id below is prefixed so nothing
 * this spec writes can collide with theirs.
 */
const PROJECT_ID = 'rules-test';

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8'),
    },
    storage: {
      rules: fs.readFileSync(path.join(__dirname, '..', '..', 'storage.rules'), 'utf8'),
    },
  });

  await env.withSecurityRulesDisabled(async (ctx) => {
    // A confirmed friendship, in one direction — the rule is bidirectional.
    await ctx.firestore().doc(`buddyAssignments/${OWNER}`).set({
      athletes: { [FRIEND]: { status: 'accepted' } },
    });
    await seedStory(ctx, LIVE, 60 * 1000);
    await seedStory(ctx, EXACT, TTL_MS);
    await seedStory(ctx, PAST, TTL_MS + 60 * 60 * 1000);
    // An object with no document at all, standing for what the cleanup sweep
    // leaves behind if it dies between deleting the file and the record.
    await uploadBytes(
      ref(ctx.storage(), `users/${OWNER}/stories/${ORPHAN}/original.jpg`), BYTES, IMAGE,
    );
  });
});

/** Seeds one story document and its media object, aged [ageMs]. */
async function seedStory(ctx, id, ageMs) {
  await ctx.firestore().doc(`users/${OWNER}/stories/${id}`).set({
    ownerUid: OWNER,
    mediaType: 'image',
    storagePath: `users/${OWNER}/stories/${id}/original.jpg`,
    thumbPath: `users/${OWNER}/stories/${id}/thumb.jpg`,
    url: 'https://example.invalid/s.jpg',
    thumbUrl: 'https://example.invalid/s.jpg',
    publishedAt: new Date(Date.now() - ageMs),
  });
  await uploadBytes(
    ref(ctx.storage(), `users/${OWNER}/stories/${id}/original.jpg`), BYTES, IMAGE,
  );
}

/** A story seeded fresh, with [EDGE_LIFE_MS] of life left. */
async function seedExpiringStory(id) {
  await env.withSecurityRulesDisabled(
    (ctx) => seedStory(ctx, id, TTL_MS - EDGE_LIFE_MS),
  );
}

test.after(async () => { if (env) await env.cleanup(); });

const fsAs = (uid) => env.authenticatedContext(uid).firestore();
const stAs = (uid) => env.authenticatedContext(uid).storage();

const doc = (db, id) => db.doc(`users/${OWNER}/stories/${id}`);
const readObject = (storage, id) =>
  getBytes(ref(storage, `users/${OWNER}/stories/${id}/original.jpg`));

const wait = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

// ── Firestore: the three ages ───────────────────────────────────────────────

test('firestore: a friend can read a story still inside its 24 hours', async () => {
  await seedExpiringStory('expiryInsideFs');
  await assertSucceeds(doc(fsAs(FRIEND), 'expiryInsideFs').get());
});

test('firestore: a friend is DENIED a story published exactly 24h ago', async () => {
  await assertFails(doc(fsAs(FRIEND), EXACT).get());
});

test('firestore: a friend is DENIED a story published more than 24h ago', async () => {
  await assertFails(doc(fsAs(FRIEND), PAST).get());
});

test('firestore: the SAME story becomes unreadable as its 24 hours elapse', async () => {
  // Allowed, then denied, with no write in between: the rule is reading a live
  // clock rather than a stored flag.
  await seedExpiringStory('expiryCrossingFs');
  await assertSucceeds(doc(fsAs(FRIEND), 'expiryCrossingFs').get());
  await wait(EDGE_LIFE_MS + 2000);
  // A FRESH client for the second read, so the answer cannot come from the
  // first client's local cache.
  await assertFails(doc(fsAs(FRIEND), 'expiryCrossingFs').get());
});

// ── Firestore: who the boundary applies to ──────────────────────────────────

test('firestore: the OWNER can still read their own expired story', async () => {
  // They need it to see and delete their own content. The 24 hours are a
  // promise to the audience, not a lock on the author.
  await assertSucceeds(doc(fsAs(OWNER), PAST).get());
});

test('firestore: the super admin can read an expired story', async () => {
  await assertSucceeds(doc(fsAs(SUPER), PAST).get());
});

test('firestore: a stranger cannot read a story at any age', async () => {
  await assertFails(doc(fsAs(STRANGER), LIVE).get());
  await assertFails(doc(fsAs(STRANGER), PAST).get());
});

test('firestore: a logged-out reader gets nothing', async () => {
  await assertFails(doc(env.unauthenticatedContext().firestore(), LIVE).get());
});

// ── Firestore: the client query stays workable ──────────────────────────────

test('firestore: the app query for live stories is allowed for a friend', async () => {
  // Rules are not filters: a query whose result set contains a document the
  // reader cannot read fails in its entirety. The app's watchLive() query
  // constrains publishedAt to the live window, so the result set is exactly
  // the documents the rule permits — which is why that query has to carry a
  // clock-skew margin.
  const cutoff = new Date(Date.now() - TTL_MS + 90 * 1000);
  const q = await assertSucceeds(
    fsAs(FRIEND)
      .collection(`users/${OWNER}/stories`)
      .where('publishedAt', '>', cutoff)
      .orderBy('publishedAt')
      .get(),
  );
  // Every returned document is live, and the expired seeds are not among them.
  const ids = q.docs.map((d) => d.id);
  assert.ok(ids.includes(LIVE), 'the live story is returned');
  assert.ok(!ids.includes(EXACT), 'the exactly-24h story is not');
  assert.ok(!ids.includes(PAST), 'the 25h-old story is not');
});

test('firestore: an UNCONSTRAINED story query is refused for a friend', async () => {
  // The expired documents are in the result set, so the whole query is denied.
  // This is the property that makes the rule real rather than advisory.
  await assertFails(fsAs(FRIEND).collection(`users/${OWNER}/stories`).get());
});

// ── Firestore: the clock and the media are immutable ────────────────────────

test('firestore: the owner cannot move publishedAt', async () => {
  await assertFails(doc(fsAs(OWNER), LIVE).update({ publishedAt: new Date() }));
});

test('firestore: the owner cannot stamp expiresAt', async () => {
  // expiresAt is written by storyOnPublished with admin credentials. A client
  // that could set it could claim any expiry it liked.
  await assertFails(
    doc(fsAs(OWNER), LIVE).update({ expiresAt: new Date(Date.now() + TTL_MS * 7) }),
  );
});

test('firestore: the owner cannot change ownerUid', async () => {
  await assertFails(doc(fsAs(OWNER), LIVE).update({ ownerUid: STRANGER }));
});

test('firestore: the owner cannot re-point the media path or URL', async () => {
  const db = fsAs(OWNER);
  await assertFails(
    doc(db, LIVE).update({ storagePath: `users/${STRANGER}/stories/x/original.jpg` }),
  );
  await assertFails(doc(db, LIVE).update({ url: 'https://example.invalid/other.jpg' }));
  await assertFails(doc(db, LIVE).update({ thumbUrl: 'https://example.invalid/other.jpg' }));
  await assertFails(
    doc(db, LIVE).update({ thumbPath: `users/${STRANGER}/stories/x/thumb.jpg` }),
  );
});

test('firestore: the owner may still edit a presentational field', async () => {
  // The guard must pin the clock and the media, not freeze the document.
  await assertSucceeds(doc(fsAs(OWNER), LIVE).update({ caption: 'Heavy day.' }));
});

test('firestore: create still requires a server publication time', async () => {
  const db = fsAs(OWNER);
  await assertFails(db.doc(`users/${OWNER}/stories/new1`).set({
    ownerUid: OWNER, mediaType: 'image', publishedAt: new Date(0),
  }));
  await assertFails(db.doc(`users/${OWNER}/stories/new2`).set({
    ownerUid: OWNER, mediaType: 'image', publishedAt: new Date(), expiresAt: new Date(),
  }));
});

test('firestore: the owner can delete their own story at any age', async () => {
  await seedExpiringStory('expiryDeletable');
  await assertSucceeds(doc(fsAs(OWNER), 'expiryDeletable').delete());
});

// ── Storage: the same boundary, on the object ───────────────────────────────

test('storage: a friend can read story media still inside its 24 hours', async () => {
  await seedExpiringStory('expiryInsideSt');
  await assertSucceeds(readObject(stAs(FRIEND), 'expiryInsideSt'));
});

test('storage: a friend is DENIED story media published exactly 24h ago', async () => {
  await assertFails(readObject(stAs(FRIEND), EXACT));
});

test('storage: a friend is DENIED story media published more than 24h ago', async () => {
  await assertFails(readObject(stAs(FRIEND), PAST));
});

test('storage: the SAME object becomes unreadable as its 24 hours elapse', async () => {
  // A Storage download URL is a bearer token. Without this, seeing a story
  // once meant keeping a permanently working link to its bytes.
  await seedExpiringStory('expiryCrossingSt');
  await assertSucceeds(readObject(stAs(FRIEND), 'expiryCrossingSt'));
  await wait(EDGE_LIFE_MS + 2000);
  await assertFails(readObject(stAs(FRIEND), 'expiryCrossingSt'));
});

test('storage: an object with NO story document is unreachable', async () => {
  // The object outlives its document if the cleanup sweep dies between the two
  // deletes. Requiring the document is what stops that leftover being a
  // permanently readable copy.
  await assertFails(readObject(stAs(FRIEND), ORPHAN));
  await assertFails(readObject(stAs(OWNER), ORPHAN));
});

test('storage: a stranger is denied story media at any age', async () => {
  await assertFails(readObject(stAs(STRANGER), LIVE));
  await assertFails(readObject(stAs(STRANGER), PAST));
});

test('storage: the owner keeps access to their own expired media', async () => {
  await assertSucceeds(readObject(stAs(OWNER), PAST));
});

test('storage: the owner can still upload and delete story media', async () => {
  const st = stAs(OWNER);
  await assertSucceeds(
    uploadBytes(ref(st, `users/${OWNER}/stories/upload1/original.jpg`), BYTES, IMAGE),
  );
});
