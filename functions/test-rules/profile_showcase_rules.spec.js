'use strict';

// Firestore security-rules tests for the profile showcase feature, run against
// the REAL rules engine in the Firestore emulator:
//   npm run test:rules
//
// The access model under test:
//
//   Data / action                                    | Access
//   -------------------------------------------------|-----------------------------
//   identity, avatar, bio, achievement snapshot       | any signed-in user
//   proof videos, gallery media, stories              | owner, confirmed friend, super admin
//   upload / edit / delete profile + social media     | owner only (+ super admin)
//   training history                                  | owner, assigned coach, super admin
//   logged out                                        | nothing
//
// The point of most of these cases is that an ASSIGNED COACH is not a social
// bypass, and that the users/{uid} catch-all cannot re-grant what the narrower
// blocks withhold — Firestore rule matches are ORed, which is exactly how a
// broad wildcard leaks privileges.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');

const SUPER = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const OWNER = 'owner1';
const FRIEND = 'friend1';
const STRANGER = 'stranger1';
const COACH = 'coach1';       // assigned coach, NOT a friend
const COACH_FRIEND = 'coach2'; // assigned coach who IS also a friend

let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'rules-test-showcase',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8'),
    },
  });

  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();

    // Active coach entitlements — required by every authorization source.
    for (const uid of [COACH, COACH_FRIEND]) {
      await db.doc(`accountEntitlements/${uid}`).set({
        coach: { state: 'active', source: 'manual_review' },
      });
    }
    // Assigned coach⇄athlete relationships.
    await db.doc(`athleteAssignments/${OWNER}`).set({
      coaches: { [COACH]: { approved: true }, [COACH_FRIEND]: { approved: true } },
    });
    // Confirmed friendships (accepted, one direction — the rule is bidirectional).
    await db.doc(`buddyAssignments/${OWNER}`).set({
      athletes: {
        [FRIEND]: { status: 'accepted' },
        [COACH_FRIEND]: { status: 'accepted' },
      },
    });

    // Profile identity + the achievement snapshot mirror.
    await db.doc(`users_public/${OWNER}`).set({
      username: 'BenchKing',
      usernameLower: 'benchking',
      bio: 'Chasing a 200 bench.',
      photoURL: 'https://example.invalid/a.jpg',
      profileShowcaseV1: { schema: 'profileShowcaseV1', formulaVersion: 1, lifts: {} },
    });
    await db.doc(`users/${OWNER}`).set({ username: 'BenchKing', usernameLower: 'benchking' });

    // Social media.
    await db.doc('posts/p1').set({ ownerUid: OWNER, mediaType: 'image', type: 'upload' });
    await db.doc('posts/p2').set({ ownerUid: OWNER, mediaType: 'video', type: 'proof' });
    await db.doc(`users/${OWNER}/proofs/fp1`).set({ fingerprint: 'fp1', postId: 'p2' });
    await db.doc(`users/${OWNER}/stories/s1`).set({
      ownerUid: OWNER,
      mediaType: 'image',
      publishedAt: new Date(),
    });
    await db.doc(`users/${OWNER}/liftVideos/lv1`).set({ remoteUrl: 'x' });

    // Training data + the server-owned projection.
    await db.doc(`users/${OWNER}/workouts/2026-01-01`).set({ exercises: [] });
    await db.doc(`users/${OWNER}/showcase/state`).set({ schema: 'profileShowcaseV1' });
    await db.doc(`users/${OWNER}/showcaseDays/bench__2026-01-01`).set({ slot: 'bench' });

    // Username reservation index.
    await db.doc('usernames/deadbeef').set({ uid: OWNER, usernameLower: 'benchking' });
  });
});

test.after(async () => {
  if (env) await env.cleanup();
});

const as = (uid) => env.authenticatedContext(uid).firestore();
const anon = () => env.unauthenticatedContext().firestore();

// ── Identity + achievement snapshot: any signed-in user ─────────────────────

test('any signed-in user can read profile identity and the achievement snapshot', async () => {
  for (const uid of [OWNER, FRIEND, STRANGER, COACH]) {
    await assertSucceeds(as(uid).doc(`users_public/${OWNER}`).get());
  }
});

test('a logged-out visitor can read nothing at all', async () => {
  await assertFails(anon().doc(`users_public/${OWNER}`).get());
  await assertFails(anon().doc('posts/p1').get());
  await assertFails(anon().doc(`users/${OWNER}/stories/s1`).get());
  await assertFails(anon().doc(`users/${OWNER}`).get());
  await assertFails(anon().doc('usernames/deadbeef').get());
});

// ── Owner-only mutation of identity ─────────────────────────────────────────

test('only the owner may edit their own bio and avatar', async () => {
  await assertSucceeds(
    as(OWNER).doc(`users_public/${OWNER}`).set({ bio: 'New bio' }, { merge: true }),
  );
  await assertFails(
    as(FRIEND).doc(`users_public/${OWNER}`).set({ bio: 'hacked' }, { merge: true }),
  );
  await assertFails(
    as(STRANGER).doc(`users_public/${OWNER}`).set({ photoURL: 'x' }, { merge: true }),
  );
});

test('an assigned coach cannot edit the athlete profile they coach', async () => {
  await assertFails(
    as(COACH).doc(`users_public/${OWNER}`).set({ bio: 'coach wrote this' }, { merge: true }),
  );
  await assertFails(
    as(COACH).doc(`users/${OWNER}`).set({ username: 'renamed' }, { merge: true }),
  );
});

// ── The achievement snapshot is server-owned ────────────────────────────────

test('not even the owner may forge their own achievement snapshot', async () => {
  await assertFails(
    as(OWNER).doc(`users_public/${OWNER}`).set(
      { profileShowcaseV1: { schema: 'profileShowcaseV1', lifts: { bench: {} } } },
      { merge: true },
    ),
  );
});

test('the owner can still write every other public field', async () => {
  await assertSucceeds(
    as(OWNER).doc(`users_public/${OWNER}`).set(
      { bio: 'still editable', displayName: 'BenchKing' },
      { merge: true },
    ),
  );
});

test('the server-owned projection is readable by its owner and unwritable by them', async () => {
  await assertSucceeds(as(OWNER).doc(`users/${OWNER}/showcase/state`).get());
  await assertSucceeds(as(OWNER).doc(`users/${OWNER}/showcaseDays/bench__2026-01-01`).get());
  await assertFails(
    as(OWNER).doc(`users/${OWNER}/showcase/state`).set({ schema: 'forged' }, { merge: true }),
  );
  await assertFails(
    as(OWNER).doc(`users/${OWNER}/showcaseDays/bench__2026-01-01`)
      .set({ slot: 'bench', forged: true }, { merge: true }),
  );
});

test('the projection is not readable by friends, strangers or the coach', async () => {
  for (const uid of [FRIEND, STRANGER, COACH]) {
    await assertFails(as(uid).doc(`users/${OWNER}/showcase/state`).get());
  }
});

// ── Social media: owner, confirmed friend, super admin ──────────────────────

test('a confirmed friend can read gallery posts, proofs and stories', async () => {
  await assertSucceeds(as(FRIEND).doc('posts/p1').get());
  await assertSucceeds(as(FRIEND).doc('posts/p2').get());
  await assertSucceeds(as(FRIEND).doc(`users/${OWNER}/proofs/fp1`).get());
  await assertSucceeds(as(FRIEND).doc(`users/${OWNER}/stories/s1`).get());
  await assertSucceeds(as(FRIEND).doc(`users/${OWNER}/liftVideos/lv1`).get());
});

test('a non-friend is denied all social media', async () => {
  await assertFails(as(STRANGER).doc('posts/p1').get());
  await assertFails(as(STRANGER).doc('posts/p2').get());
  await assertFails(as(STRANGER).doc(`users/${OWNER}/proofs/fp1`).get());
  await assertFails(as(STRANGER).doc(`users/${OWNER}/stories/s1`).get());
});

test('an ASSIGNED COACH who is not a friend is denied all social media', async () => {
  await assertFails(as(COACH).doc('posts/p1').get());
  await assertFails(as(COACH).doc('posts/p2').get(), 'proof video must not leak to a coach');
  await assertFails(as(COACH).doc(`users/${OWNER}/proofs/fp1`).get());
  await assertFails(as(COACH).doc(`users/${OWNER}/stories/s1`).get());
  await assertFails(as(COACH).doc(`users/${OWNER}/liftVideos/lv1`).get());
});

test('a coach who IS also a confirmed friend sees social media as a friend', async () => {
  await assertSucceeds(as(COACH_FRIEND).doc('posts/p2').get());
  await assertSucceeds(as(COACH_FRIEND).doc(`users/${OWNER}/stories/s1`).get());
  await assertSucceeds(as(COACH_FRIEND).doc(`users/${OWNER}/proofs/fp1`).get());
});

test('only the owner may mutate social media', async () => {
  await assertSucceeds(
    as(OWNER).doc(`users/${OWNER}/proofs/fp1`).set({ postId: 'p2' }, { merge: true }),
  );
  await assertFails(
    as(FRIEND).doc(`users/${OWNER}/proofs/fp1`).set({ postId: 'evil' }, { merge: true }),
  );
  await assertFails(as(FRIEND).doc(`users/${OWNER}/stories/s1`).delete());
  await assertFails(as(COACH).doc(`users/${OWNER}/proofs/fp1`).set({ x: 1 }, { merge: true }));
  await assertFails(as(FRIEND).doc('posts/p1').delete());
});

// ── Training data: owner, assigned coach, super admin ───────────────────────

test('an assigned coach reaches training data and nothing else under users/', async () => {
  await assertSucceeds(as(COACH).doc(`users/${OWNER}/workouts/2026-01-01`).get());
  // ...but not the social or server-owned subcollections.
  await assertFails(as(COACH).doc(`users/${OWNER}/stories/s1`).get());
  await assertFails(as(COACH).doc(`users/${OWNER}/showcaseDays/bench__2026-01-01`).get());
});

test('a friend cannot read training history', async () => {
  await assertFails(as(FRIEND).doc(`users/${OWNER}/workouts/2026-01-01`).get());
  await assertFails(as(STRANGER).doc(`users/${OWNER}/workouts/2026-01-01`).get());
});

// ── No broad-wildcard privilege leak ────────────────────────────────────────

test('the users/{uid} catch-all does not re-grant owner writes to gated subcollections', async () => {
  // These would all SUCCEED if `stories`, `showcase` and `showcaseDays` were
  // still covered by the catch-all's write clause, because rule matches are
  // ORed and the catch-all grants the owner unconstrained write.
  await assertFails(
    as(OWNER).doc(`users/${OWNER}/stories/forged`).set({
      ownerUid: OWNER,
      // A client-chosen publication time would let a story be backdated or
      // kept alive indefinitely.
      publishedAt: new Date(2000, 0, 1),
    }),
  );
  await assertFails(as(OWNER).doc(`users/${OWNER}/showcase/forged`).set({ x: 1 }));
});

test('a coach cannot reach a NEW subcollection just because it exists', async () => {
  await assertFails(as(COACH).doc(`users/${OWNER}/proofs/fp1`).get());
  await assertFails(as(COACH).doc(`users/${OWNER}/somethingInvented/x`).get());
});

// ── Stories: server clock ───────────────────────────────────────────────────

test('a story must be created with the server publication time', async () => {
  const db = as(OWNER);
  const { serverTimestamp } = require('firebase/firestore');
  await assertSucceeds(
    db.doc(`users/${OWNER}/stories/good`).set({
      ownerUid: OWNER,
      mediaType: 'image',
      publishedAt: serverTimestamp(),
    }),
  );
  await assertFails(
    db.doc(`users/${OWNER}/stories/bad`).set({
      ownerUid: OWNER,
      mediaType: 'image',
      publishedAt: new Date(),
    }),
  );
});

test('a client may not supply expiresAt', async () => {
  const { serverTimestamp } = require('firebase/firestore');
  await assertFails(
    as(OWNER).doc(`users/${OWNER}/stories/badExpiry`).set({
      ownerUid: OWNER,
      mediaType: 'image',
      publishedAt: serverTimestamp(),
      expiresAt: new Date(Date.now() + 999 * 24 * 3600 * 1000),
    }),
  );
});

test('a story owner cannot move their own publication clock', async () => {
  const { serverTimestamp } = require('firebase/firestore');
  await assertFails(
    as(OWNER).doc(`users/${OWNER}/stories/s1`).set(
      { publishedAt: serverTimestamp() },
      { merge: true },
    ),
  );
});

test('nobody may write a story into another account', async () => {
  const { serverTimestamp } = require('firebase/firestore');
  await assertFails(
    as(FRIEND).doc(`users/${OWNER}/stories/injected`).set({
      ownerUid: OWNER,
      publishedAt: serverTimestamp(),
    }),
  );
});

// ── Username reservation index ──────────────────────────────────────────────

test('the username index is readable by signed-in users and writable by nobody', async () => {
  await assertSucceeds(as(STRANGER).doc('usernames/deadbeef').get());
  await assertFails(as(OWNER).doc('usernames/deadbeef').set({ uid: OWNER }));
  await assertFails(as(OWNER).doc('usernames/newkey').set({ uid: OWNER }));
  await assertFails(as(STRANGER).doc('usernames/deadbeef').set({ uid: STRANGER }));
  await assertFails(as(OWNER).doc('usernames/deadbeef').delete());
});

test('not even the super admin can write the username index from a client', async () => {
  // Reservations are only ever made inside the callable's transaction.
  await assertFails(as(SUPER).doc('usernames/deadbeef').set({ uid: SUPER }));
});

// ── Super admin ─────────────────────────────────────────────────────────────

test('the super admin retains the existing cross-account access', async () => {
  await assertSucceeds(as(SUPER).doc('posts/p2').get());
  await assertSucceeds(as(SUPER).doc(`users/${OWNER}/stories/s1`).get());
  await assertSucceeds(as(SUPER).doc(`users/${OWNER}/proofs/fp1`).get());
  await assertSucceeds(as(SUPER).doc(`users/${OWNER}/workouts/2026-01-01`).get());
  await assertSucceeds(
    as(SUPER).doc(`users_public/${OWNER}`).set({ bio: 'admin edit' }, { merge: true }),
  );
});
