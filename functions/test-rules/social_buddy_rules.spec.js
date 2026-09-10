'use strict';

// Firestore security-rules tests for buddy discovery, relationships and the
// feed, run against the REAL rules engine in the Firestore emulator:
//   npm run test:rules
//
// The access model under test:
//
//   Data / action                          | Access
//   ---------------------------------------|--------------------------------
//   userSearchIndex/{uid}                  | read: any signed-in; write: nobody
//   socialGraph/{uid}                      | read: owner; write: nobody
//   socialRateLimits/{uid}                 | nobody, either direction
//   users/{uid}/feed/{item}                | read: owner; write: nobody
//   users/{uid}/buddyInvites/{from}        | read: receiver; create: sender
//   buddyAssignments/{uid}                 | read/write: owner; update: the
//                                          |   listed athlete, own entry only
//   friend-only media                      | MUTUAL friends only
//
// Two properties carry most of the weight here, and both were live defects
// before this change:
//
//   1. A friendship could be ASSERTED BY ONE SIDE. buddyAssignments/{uid} is
//      writable by its owner, so writing `athletes.{victim} = accepted` into
//      your own document granted you the victim's posts, stories, lift videos
//      and Storage media. isBuddyOf() is now mutual.
//   2. REMOVING A FRIEND DID NOT REVOKE ACCESS, because the old rule accepted
//      whichever side had not been cleared.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');

const SUPER = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const ALICE = 'alice1';
const BOB = 'bob1';           // ALICE's confirmed, mutual friend
const CAROL = 'carol1';       // no relationship with ALICE
const MALLORY = 'mallory1';   // asserts a friendship ALICE never agreed to
const COACH = 'coach1';       // ALICE's assigned coach, NOT a friend

let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'rules-test-social',
    firestore: {
      rules: fs.readFileSync(
        path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8',
      ),
    },
  });

  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();

    // A real, mutual friendship between ALICE and BOB.
    await db.doc(`buddyAssignments/${ALICE}`).set({
      athletes: { [BOB]: { status: 'accepted' }, [CAROL]: { status: 'pending' } },
    });
    await db.doc(`buddyAssignments/${BOB}`).set({
      athletes: { [ALICE]: { status: 'accepted' } },
    });

    // MALLORY's unilateral claim on ALICE. This is the exact document an
    // attacker can write for themselves, so it is seeded as data rather than
    // asserted as a write.
    await db.doc(`buddyAssignments/${MALLORY}`).set({
      athletes: { [ALICE]: { status: 'accepted' } },
    });

    // COACH is assigned to ALICE for training, and is not a friend.
    await db.doc(`athleteAssignments/${ALICE}`).set({
      coaches: { [COACH]: { approved: true } },
    });
    await db.doc(`accountEntitlements/${COACH}`).set({
      coach: { state: 'active', source: 'manual_review' },
    });

    await db.doc(`users_public/${ALICE}`).set({
      username: 'AliceLifts', usernameLower: 'alicelifts', fullName: 'Alice Kaur',
    });
    await db.doc(`users_public/${BOB}`).set({
      username: 'BobLifts', usernameLower: 'boblifts', fullName: 'Bob Chen',
    });

    // The search projection.
    await db.doc(`userSearchIndex/${ALICE}`).set({
      uid: ALICE, username: 'AliceLifts', usernameLower: 'alicelifts',
      displayName: 'Alice Kaur', firstName: 'Alice', lastName: 'Kaur',
      photoURL: '', terms: ['alicelifts', 'alice', 'kaur', 'alice kaur'],
      prefixes: ['al', 'ali'], grams: ['$al'],
    });

    // The confirmed-friend projection.
    await db.doc(`socialGraph/${ALICE}`).set({ uid: ALICE, friends: [BOB] });
    await db.doc(`socialGraph/${BOB}`).set({ uid: BOB, friends: [ALICE] });

    // Rate-limit budget.
    await db.doc(`socialRateLimits/${ALICE}`).set({ windowStart: 1, count: 1 });

    // ALICE's gallery post, and BOB's feed row pointing at it.
    await db.doc('posts/aliceP1').set({
      ownerUid: ALICE, mediaType: 'image', type: 'upload', showInGrid: true,
      smallUrl: 'https://example.invalid/a.jpg', createdAt: new Date(),
    });
    await db.doc(`users/${BOB}/feed/${ALICE}__aliceP1`).set({
      ownerUid: ALICE, postId: 'aliceP1', mediaType: 'image',
      smallUrl: 'https://example.invalid/a.jpg', createdAt: new Date(),
    });

    // A pending request CAROL sent to ALICE.
    await db.doc(`users/${ALICE}/buddyInvites/${CAROL}`).set({
      status: 'pending', fromUid: CAROL, buddyUid: ALICE, createdAt: new Date(),
    });

    // ALICE's training data, for the coach-is-not-a-friend cases.
    await db.doc(`users/${ALICE}/workouts/2026-01-01`).set({ exercises: [] });
  });
});

test.after(async () => {
  if (env) await env.cleanup();
});

const as = (uid) => env.authenticatedContext(uid).firestore();
const anon = () => env.unauthenticatedContext().firestore();

// ── The forgery that used to work ───────────────────────────────────────────

test('a self-asserted friendship grants NO access to the victim media', async () => {
  // MALLORY's own document says ALICE is an accepted buddy. ALICE's says
  // nothing. Under the previous either-side rule this read succeeded.
  await assertFails(as(MALLORY).doc('posts/aliceP1').get());
});

test('an account can still write its own assignment document, harmlessly', async () => {
  // The write is not what is blocked — it cannot be, since the owner owns the
  // document. What changed is that the claim no longer means anything.
  await assertSucceeds(
    as(MALLORY).doc(`buddyAssignments/${MALLORY}`).set({
      athletes: { [ALICE]: { status: 'accepted' } },
    }),
  );
  await assertFails(as(MALLORY).doc('posts/aliceP1').get());
});

test('a mutual friend reads friend-only media', async () => {
  await assertSucceeds(as(BOB).doc('posts/aliceP1').get());
});

test('a stranger reads no friend-only media', async () => {
  await assertFails(as(CAROL).doc('posts/aliceP1').get());
  await assertFails(anon().doc('posts/aliceP1').get());
});

test('an assigned coach who is not a friend gets training but not media', async () => {
  await assertSucceeds(as(COACH).doc(`users/${ALICE}/workouts/2026-01-01`).get());
  await assertFails(as(COACH).doc('posts/aliceP1').get());
});

// ── Search projection ───────────────────────────────────────────────────────

test('any signed-in user can read the search projection', async () => {
  for (const uid of [ALICE, BOB, CAROL, MALLORY, COACH]) {
    await assertSucceeds(as(uid).doc(`userSearchIndex/${ALICE}`).get());
  }
});

test('a logged-out visitor cannot read the search projection', async () => {
  await assertFails(anon().doc(`userSearchIndex/${ALICE}`).get());
});

test('no client can write the search projection', async () => {
  // Including the account it describes: a writable index is a way to become
  // findable under somebody else's name.
  await assertFails(
    as(ALICE).doc(`userSearchIndex/${ALICE}`).set({ uid: ALICE, terms: ['x'] }),
  );
  await assertFails(
    as(ALICE).doc(`userSearchIndex/${ALICE}`).update({ terms: ['x'] }),
  );
  await assertFails(as(ALICE).doc(`userSearchIndex/${ALICE}`).delete());
  await assertFails(
    as(MALLORY).doc(`userSearchIndex/${CAROL}`).set({ uid: CAROL, terms: ['x'] }),
  );
  await assertFails(
    as(SUPER).doc(`userSearchIndex/${ALICE}`).set({ uid: ALICE, terms: ['x'] }),
  );
});

test('the seeded projection carries no private fields', async () => {
  const snap = await as(CAROL).doc(`userSearchIndex/${ALICE}`).get();
  const data = snap.data();
  for (const forbidden of ['email', 'emailLower', 'phone', 'dob', 'sex', 'isCoach']) {
    assert.equal(data[forbidden], undefined, `projection exposed ${forbidden}`);
  }
});

// ── Confirmed-friend projection ─────────────────────────────────────────────

test('the friend projection is readable only by its owner', async () => {
  await assertSucceeds(as(ALICE).doc(`socialGraph/${ALICE}`).get());
  await assertFails(as(BOB).doc(`socialGraph/${ALICE}`).get());
  await assertFails(as(CAROL).doc(`socialGraph/${ALICE}`).get());
  await assertFails(anon().doc(`socialGraph/${ALICE}`).get());
});

test('no client can write the friend projection', async () => {
  // A client-writable friend list would put "who are my friends" back in the
  // client's hands, which is the question the projection exists to answer.
  await assertFails(
    as(ALICE).doc(`socialGraph/${ALICE}`).set({ uid: ALICE, friends: [CAROL] }),
  );
  await assertFails(as(ALICE).doc(`socialGraph/${ALICE}`).delete());
  await assertFails(
    as(MALLORY).doc(`socialGraph/${MALLORY}`).set({ uid: MALLORY, friends: [ALICE] }),
  );
});

// ── Rate limits ─────────────────────────────────────────────────────────────

test('the request budget is invisible and untouchable from a device', async () => {
  await assertFails(as(ALICE).doc(`socialRateLimits/${ALICE}`).get());
  await assertFails(
    as(ALICE).doc(`socialRateLimits/${ALICE}`).set({ windowStart: 0, count: 0 }),
  );
  await assertFails(as(SUPER).doc(`socialRateLimits/${ALICE}`).get());
});

// ── Feed projection ─────────────────────────────────────────────────────────

test('a viewer reads their own feed and nobody else reads it', async () => {
  await assertSucceeds(as(BOB).doc(`users/${BOB}/feed/${ALICE}__aliceP1`).get());
  await assertSucceeds(as(BOB).collection(`users/${BOB}/feed`).get());
  await assertFails(as(ALICE).doc(`users/${BOB}/feed/${ALICE}__aliceP1`).get());
  await assertFails(as(CAROL).collection(`users/${BOB}/feed`).get());
  await assertFails(anon().collection(`users/${BOB}/feed`).get());
});

test('a client cannot forge a feed row, not even in its own feed', async () => {
  // The users/{subcoll} catch-all grants the owner writes; 'feed' is listed in
  // hasOwnWriteRule() precisely so it does not apply here. Without that, this
  // is how an arbitrary URL gets rendered as a buddy's post.
  await assertFails(
    as(BOB).doc(`users/${BOB}/feed/${CAROL}__forged`).set({
      ownerUid: CAROL, postId: 'forged', mediaType: 'image',
      smallUrl: 'https://evil.invalid/x.jpg', createdAt: new Date(),
    }),
  );
  await assertFails(
    as(BOB).doc(`users/${BOB}/feed/${ALICE}__aliceP1`).update({ caption: 'edited' }),
  );
  await assertFails(as(BOB).doc(`users/${BOB}/feed/${ALICE}__aliceP1`).delete());
  await assertFails(
    as(MALLORY).doc(`users/${MALLORY}/feed/${ALICE}__aliceP1`).set({
      ownerUid: ALICE, postId: 'aliceP1', mediaType: 'image', createdAt: new Date(),
    }),
  );
});

test('holding a feed row does not grant the media it points at', async () => {
  // Defence in depth: the row is a reference, and the posts rules are still
  // evaluated on their own terms.
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc(`users/${CAROL}/feed/${ALICE}__aliceP1`).set({
      ownerUid: ALICE, postId: 'aliceP1', mediaType: 'image', createdAt: new Date(),
    });
  });
  await assertSucceeds(as(CAROL).doc(`users/${CAROL}/feed/${ALICE}__aliceP1`).get());
  await assertFails(as(CAROL).doc('posts/aliceP1').get());
});

// ── Requests ────────────────────────────────────────────────────────────────

test('only the receiver reads a request addressed to them', async () => {
  await assertSucceeds(as(ALICE).doc(`users/${ALICE}/buddyInvites/${CAROL}`).get());
  await assertSucceeds(as(ALICE).collection(`users/${ALICE}/buddyInvites`).get());
  // Not even the sender: the invite lives under the receiver's account.
  await assertFails(as(CAROL).doc(`users/${ALICE}/buddyInvites/${CAROL}`).get());
  await assertFails(as(MALLORY).doc(`users/${ALICE}/buddyInvites/${CAROL}`).get());
});

test('a sender may create a request only under their own uid', async () => {
  await assertSucceeds(
    as(MALLORY).doc(`users/${BOB}/buddyInvites/${MALLORY}`).set({
      status: 'pending', fromUid: MALLORY, buddyUid: BOB, createdAt: new Date(),
    }),
  );
  // Forging a request as somebody else.
  await assertFails(
    as(MALLORY).doc(`users/${BOB}/buddyInvites/${CAROL}`).set({
      status: 'pending', fromUid: CAROL, buddyUid: BOB, createdAt: new Date(),
    }),
  );
  // Claiming a different sender than the document id.
  await assertFails(
    as(MALLORY).doc(`users/${BOB}/buddyInvites/${MALLORY}`).set({
      status: 'pending', fromUid: CAROL, buddyUid: BOB, createdAt: new Date(),
    }),
  );
});

test('a self-request is rejected', async () => {
  // It would sit in the sender's own pending list and inflate their badge.
  await assertFails(
    as(CAROL).doc(`users/${CAROL}/buddyInvites/${CAROL}`).set({
      status: 'pending', fromUid: CAROL, buddyUid: CAROL, createdAt: new Date(),
    }),
  );
});

test('a user cannot answer a request addressed to somebody else', async () => {
  await assertFails(
    as(MALLORY).doc(`users/${ALICE}/buddyInvites/${CAROL}`)
      .update({ status: 'accepted' }),
  );
  await assertFails(
    as(CAROL).doc(`users/${ALICE}/buddyInvites/${CAROL}`)
      .update({ status: 'accepted' }),
  );
});

test('a receiver may answer, but may not re-address, a request', async () => {
  await assertSucceeds(
    as(ALICE).doc(`users/${ALICE}/buddyInvites/${CAROL}`)
      .update({ status: 'denied', respondedAt: new Date() }),
  );
  // Rewriting the participants would re-point somebody else's request.
  await assertFails(
    as(ALICE).doc(`users/${ALICE}/buddyInvites/${CAROL}`)
      .update({ status: 'accepted', fromUid: MALLORY }),
  );
  await assertFails(
    as(ALICE).doc(`users/${ALICE}/buddyInvites/${CAROL}`)
      .update({ buddyUid: BOB }),
  );
});

// ── Assignment writes ───────────────────────────────────────────────────────

test('the owner reads and writes their own assignment document', async () => {
  await assertSucceeds(as(ALICE).doc(`buddyAssignments/${ALICE}`).get());
  await assertFails(as(BOB).doc(`buddyAssignments/${ALICE}`).get());
  await assertFails(as(CAROL).doc(`buddyAssignments/${ALICE}`).get());
});

test('a listed athlete may update only their OWN entry', async () => {
  // The legacy accept/deny path: BOB is in ALICE's map and touches athletes.BOB.
  await assertSucceeds(
    as(BOB).doc(`buddyAssignments/${ALICE}`).update({
      [`athletes.${BOB}.status`]: 'accepted',
      [`athletes.${BOB}.acceptedAt`]: new Date(),
    }),
  );
});

test('a listed athlete cannot manufacture a friendship for a third party', async () => {
  // Without the per-key diff clause, BOB — already inside ALICE's map — could
  // rewrite the whole map. Pairing that with CAROL writing her own side would
  // produce an ALICE⇄CAROL friendship neither of them agreed to.
  await assertFails(
    as(BOB).doc(`buddyAssignments/${ALICE}`).update({
      [`athletes.${CAROL}.status`]: 'accepted',
    }),
  );
  await assertFails(
    as(BOB).doc(`buddyAssignments/${ALICE}`).set({
      athletes: {
        [BOB]: { status: 'accepted' },
        [CAROL]: { status: 'accepted' },
      },
    }),
  );
  // Nor may they smuggle other fields in alongside their own entry.
  await assertFails(
    as(BOB).doc(`buddyAssignments/${ALICE}`).update({
      [`athletes.${BOB}.status`]: 'accepted',
      ownerOverride: MALLORY,
    }),
  );
});

test('a stranger cannot touch an assignment document at all', async () => {
  await assertFails(
    as(MALLORY).doc(`buddyAssignments/${ALICE}`).update({
      [`athletes.${MALLORY}.status`]: 'accepted',
    }),
  );
  await assertFails(
    as(MALLORY).doc(`buddyAssignments/${CAROL}`).set({
      athletes: { [MALLORY]: { status: 'accepted' } },
    }),
  );
  await assertFails(as(MALLORY).doc(`buddyAssignments/${ALICE}`).delete());
});

test('only the owner deletes their assignment document', async () => {
  await assertFails(as(BOB).doc(`buddyAssignments/${ALICE}`).delete());
});
