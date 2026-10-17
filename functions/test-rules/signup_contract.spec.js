'use strict';

// Firestore security-rules tests for the SIGNUP write contract, run against
// the REAL rules engine in the Firestore emulator:
//   npm run test:rules
//
// 1. Reproduces the signup blocker: the pre-account availability read the
//    app used to run at Finish (users_public by usernameLower) and the
//    reservation-index read are refused to a caller with no auth session —
//    which is every logged-out device, because anonymous sign-in is not
//    enabled on the production project. That refusal is correct and stays.
// 2. Pins what the fixed flow writes after profileChangeUsername has
//    reserved the name: the profile payload WITHOUT identity fields, the
//    onboarding answers, the inactive membership document and the first
//    block + pointer — all allowed to the owner.
// 3. Pins why the client must not rewrite the reserved username: a raw value
//    that differs from the callable's canonical one is a rename, and is
//    denied.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');

const NEW_UID = 'signupNewMember';
const OTHER = 'signupOther';

let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'rules-test-signup',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8'),
    },
  });
});

test.beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    // Another member already holds "lifter".
    await db.doc(`users_public/${OTHER}`).set({ username: 'Lifter', usernameLower: 'lifter' });
    await db.doc('usernames/abc123').set({ uid: OTHER, username: 'Lifter', usernameLower: 'lifter' });
    // What profileChangeUsername's transaction leaves for the new member.
    await db.doc(`users/${NEW_UID}`).set({ username: 'IronAnna', usernameLower: 'ironanna' });
    await db.doc(`users_public/${NEW_UID}`).set({
      username: 'IronAnna', usernameLower: 'ironanna', displayName: 'IronAnna',
    });
  });
});

test.after(async () => {
  await env.cleanup();
});

test('logged out: the old pre-account availability query is refused', async () => {
  const anon = env.unauthenticatedContext().firestore();
  await assertFails(
    anon.collection('users_public').where('usernameLower', '==', 'lifter').limit(1).get(),
  );
  await assertFails(anon.doc('usernames/abc123').get());
});

test('signed in: the same reads are allowed (why it only failed logged out)', async () => {
  const db = env.authenticatedContext(NEW_UID).firestore();
  await assertSucceeds(
    db.collection('users_public').where('usernameLower', '==', 'lifter').limit(1).get(),
  );
  await assertSucceeds(db.doc('usernames/abc123').get());
});

test('the reservation index stays server-only', async () => {
  const db = env.authenticatedContext(NEW_UID).firestore();
  await assertFails(db.doc('usernames/new').set({ uid: NEW_UID, usernameLower: 'x' }));
});

test('after the claim, the owner writes the profile without identity fields', async () => {
  const db = env.authenticatedContext(NEW_UID).firestore();
  const payload = {
    email: 'anna@example.test',
    fullName: 'Anna Lift',
    sex: 'F',
    dob: '07-04-1992',
    createdAt: new Date(),
  };
  await assertSucceeds(db.doc(`users/${NEW_UID}`).set(payload, { merge: true }));
  await assertSucceeds(db.doc(`users_public/${NEW_UID}`).set(payload, { merge: true }));
});

test('rewriting the reserved username with a differing raw value is denied', async () => {
  const db = env.authenticatedContext(NEW_UID).firestore();
  // e.g. raw input differing from the callable's canonical (NFKC) form.
  await assertFails(db.doc(`users/${NEW_UID}`).set(
    { username: 'ironanna', usernameLower: 'ironanna' }, { merge: true },
  ));
  await assertFails(db.doc(`users_public/${NEW_UID}`).set(
    { username: 'IronAnna2', usernameLower: 'ironanna2' }, { merge: true },
  ));
});

test('the owner writes onboarding, membership and the first block + pointer', async () => {
  const db = env.authenticatedContext(NEW_UID).firestore();
  await assertSucceeds(db.doc(`users/${NEW_UID}/profile/fitness_onboarding`).set(
    { goalsRanked: ['Get stronger'], painNow: { Knees: 7 }, environment: 'home' },
    { merge: true },
  ));
  await assertSucceeds(db.doc(`users/${NEW_UID}/profile/membership`).set(
    { active: false, status: 'inactive', createdAt: new Date() },
  ));
  await assertSucceeds(db.doc(`users/${NEW_UID}/planned_blocks/b1`).set(
    { name: "IronAnna's First Block", isActive: true },
  ));
  await assertSucceeds(db.doc(`users/${NEW_UID}/planned_blocks/b1/weeks/week_0/days/day_0`).set(
    { exists: true },
  ));
  await assertSucceeds(db.doc(`users/${NEW_UID}/block_planner/current_block`).set(
    { blockId: 'b1' }, { merge: true },
  ));
});

test('signup can never write into another account', async () => {
  const db = env.authenticatedContext(NEW_UID).firestore();
  await assertFails(db.doc(`users/${OTHER}`).set({ fullName: 'x' }, { merge: true }));
  await assertFails(db.doc(`users/${OTHER}/profile/fitness_onboarding`).set({ x: 1 }));
});
