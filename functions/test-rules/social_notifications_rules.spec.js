'use strict';

// Firestore security-rules tests for "your buddy request was accepted"
// notices, against the REAL rules engine in the Firestore emulator:
//   npm run test:rules
//
//   users/{uid}/socialNotifications/{id}
//     read    owner, super admin — nobody else, not an assigned coach
//     update  owner only, and only `seen: true` with `seenAt == request.time`
//     create  nobody (server only)
//     delete  nobody (server only)
//
// The property that matters most: no device can ANNOUNCE an acceptance. A
// notice is written by socialOnBuddyInviteWritten after it has read both
// assignment documents; a client that could create one could tell somebody a
// friendship exists that nobody accepted.

const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');
const { serverTimestamp } = require('firebase/firestore');

const SUPER = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const ALICE = 'alice1';   // sent a request; BOB accepted it
const BOB = 'bob1';       // the acceptor
const CAROL = 'carol1';   // a stranger
const COACH = 'coach1';   // ALICE's assigned coach, not a friend

const notice = (other) => ({
  type: 'buddyAccepted',
  otherUid: other,
  seen: false,
  createdAt: new Date('2026-09-01T00:00:00Z'),
  acceptedAt: new Date('2026-09-01T00:00:00Z'),
  sourceEventId: `evt-${other}`,
});

let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'rules-test-social-notices',
    firestore: {
      rules: fs.readFileSync(
        path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8',
      ),
    },
  });

  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc(`buddyAssignments/${ALICE}`).set({
      athletes: { [BOB]: { status: 'accepted' } },
    });
    await db.doc(`buddyAssignments/${BOB}`).set({
      athletes: { [ALICE]: { status: 'accepted' } },
    });
    for (const id of ['ack', 'neg1', 'neg2', 'neg3', 'neg4', 'coach', 'stranger']) {
      await db.doc(`users/${ALICE}/socialNotifications/${id}`).set(notice(BOB));
    }
    await db.doc(`users/${BOB}/socialNotifications/buddyAccepted_${CAROL}`).set(notice(CAROL));

    // COACH is assigned to ALICE for training.
    await db.doc(`athleteAssignments/${ALICE}`).set({
      coaches: { [COACH]: { approved: true } },
    });
    await db.doc(`accountEntitlements/${COACH}`).set({
      coach: { state: 'active', source: 'manual_review' },
    });
  });
});

test.after(async () => {
  if (env) await env.cleanup();
});

const as = (uid) => env.authenticatedContext(uid).firestore();
const anon = () => env.unauthenticatedContext().firestore();
const noticePath = (id) => `users/${ALICE}/socialNotifications/${id}`;

// ── Read ────────────────────────────────────────────────────────────────────

test('the owner reads their own notices, singly and as the unseen query', async () => {
  await assertSucceeds(as(ALICE).doc(noticePath('ack')).get());
  await assertSucceeds(
    as(ALICE)
      .collection(`users/${ALICE}/socialNotifications`)
      .where('seen', '==', false)
      .get(),
  );
});

test('nobody else reads them — not the acceptor, a stranger, a coach, or a visitor', async () => {
  for (const reader of [as(BOB), as(CAROL), as(COACH), anon()]) {
    await assertFails(reader.doc(noticePath('ack')).get());
    await assertFails(reader.collection(`users/${ALICE}/socialNotifications`).get());
  }
});

test('the super admin can read notices for moderation', async () => {
  await assertSucceeds(as(SUPER).doc(noticePath('ack')).get());
});

// ── The owner's one write ───────────────────────────────────────────────────

test('the owner marks a notice seen at the server clock', async () => {
  await assertSucceeds(
    as(ALICE).doc(noticePath('ack')).update({ seen: true, seenAt: serverTimestamp() }),
  );
});

test('the owner cannot fabricate an acceptance', async () => {
  // A new notice, under any id, in their own collection.
  await assertFails(
    as(ALICE).doc(`users/${ALICE}/socialNotifications/buddyAccepted_${CAROL}`).set(notice(CAROL)),
  );
  await assertFails(
    as(ALICE).collection(`users/${ALICE}/socialNotifications`).add(notice(CAROL)),
  );
});

test('the owner cannot change what a notice says', async () => {
  await assertFails(as(ALICE).doc(noticePath('neg1')).update({ otherUid: CAROL }));
  await assertFails(as(ALICE).doc(noticePath('neg1')).update({ type: 'somethingElse' }));
  await assertFails(
    as(ALICE).doc(noticePath('neg1')).update({
      seen: true, seenAt: serverTimestamp(), otherUid: CAROL,
    }),
  );
  // Replacing the whole document is a change to every field.
  await assertFails(
    as(ALICE).doc(noticePath('neg1')).set({ ...notice(CAROL), seen: true, seenAt: serverTimestamp() }),
  );
});

test('seen means seen: no backdating and no un-seeing', async () => {
  await assertFails(
    as(ALICE).doc(noticePath('neg2')).update({ seen: true, seenAt: new Date('2020-01-01') }),
  );
  await assertFails(
    as(ALICE).doc(noticePath('neg2')).update({ seen: false, seenAt: serverTimestamp() }),
  );
  await assertFails(as(ALICE).doc(noticePath('neg2')).update({ seen: true }));
});

test('the owner cannot delete a notice', async () => {
  await assertFails(as(ALICE).doc(noticePath('neg3')).delete());
});

// ── Other accounts ──────────────────────────────────────────────────────────

test('another account can neither acknowledge nor plant a notice', async () => {
  await assertFails(
    as(BOB).doc(noticePath('stranger')).update({ seen: true, seenAt: serverTimestamp() }),
  );
  await assertFails(
    as(CAROL).doc(`users/${ALICE}/socialNotifications/planted`).set(notice(CAROL)),
  );
  await assertFails(as(CAROL).doc(noticePath('neg4')).delete());
});

test('a coach acting as the athlete cannot touch the athlete\'s notices', async () => {
  await assertFails(as(COACH).doc(noticePath('coach')).get());
  await assertFails(
    as(COACH).doc(noticePath('coach')).update({ seen: true, seenAt: serverTimestamp() }),
  );
  await assertFails(
    as(COACH).doc(`users/${ALICE}/socialNotifications/fromCoach`).set(notice(COACH)),
  );
});

test('a signed-out visitor cannot write anything', async () => {
  await assertFails(
    anon().doc(noticePath('stranger')).update({ seen: true, seenAt: serverTimestamp() }),
  );
  await assertFails(anon().doc(`users/${ALICE}/socialNotifications/x`).set(notice(BOB)));
});
