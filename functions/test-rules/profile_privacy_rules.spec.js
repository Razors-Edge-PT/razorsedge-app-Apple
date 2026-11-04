'use strict';

// Firestore security-rules tests for training-profile privacy and the
// leaderboard visibility choice, against the REAL rules engine:
//   npm run test:rules
//
//   Data / action                                   | Access
//   ------------------------------------------------|------------------------------
//   users_showcase/{uid} (derived achievements)   | owner, confirmed friend, support
//                                                   | override holder, assigned coach,
//                                                   | super admin — read only
//   users_showcase/{uid} write                    | nobody (server / Admin SDK only)
//   users_public identity, usernames index          | any signed-in user (search)
//   users/{uid}.leaderboardVisible                  | owner (bool only) + super admin

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');

const SUPER = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const OWNER = 'priv_owner';
const FRIEND = 'priv_friend';
const STRANGER = 'priv_stranger';
const ONE_SIDED = 'priv_onesided'; // claims the owner in its OWN buddy doc only
const COACH = 'priv_coach';
const SUPPORT = 'priv_support'; // holds the profile + DM override

const SHOWCASE = {
  profileShowcaseV1: { schema: 'profileShowcaseV1', lifts: { bench: { e1rm: { value: 150 } } } },
  profileShowcaseV2: { schema: 'profileShowcaseV2', categories: {} },
};

let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'rules-test-privacy',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8'),
    },
  });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc(`accountEntitlements/${COACH}`).set({ coach: { state: 'active', source: 'manual_review' } });
    await db.doc(`athleteAssignments/${OWNER}`).set({ coaches: { [COACH]: { approved: true } } });
    await db.doc(`buddyAssignments/${OWNER}`).set({ athletes: { [FRIEND]: { status: 'accepted' } } });
    await db.doc(`buddyAssignments/${FRIEND}`).set({ athletes: { [OWNER]: { status: 'accepted' } } });
    await db.doc(`buddyAssignments/${ONE_SIDED}`).set({ athletes: { [OWNER]: { status: 'accepted' } } });
    await db.doc(`accessGrants/${SUPPORT}`).set({ profileAndDmOverride: true });
    await db.doc(`users_showcase/${OWNER}`).set(SHOWCASE);
    await db.doc(`users_public/${OWNER}`).set({ username: 'Lifter', usernameLower: 'lifter', photoURL: 'https://example.invalid/a.jpg' });
    await db.doc('usernames/lifter').set({ uid: OWNER });
    await db.doc(`users/${OWNER}`).set({ username: 'Lifter', usernameLower: 'lifter', sex: 'F' });
  });
});

test.after(async () => {
  if (env) await env.cleanup();
});

const as = (uid) => env.authenticatedContext(uid).firestore();
const anon = () => env.unauthenticatedContext().firestore();

// ── Training showcase ───────────────────────────────────────────────────────

test('the owner and a confirmed friend can read the training showcase', async () => {
  await assertSucceeds(as(OWNER).doc(`users_showcase/${OWNER}`).get());
  await assertSucceeds(as(FRIEND).doc(`users_showcase/${FRIEND}`).get());
  await assertSucceeds(as(FRIEND).doc(`users_showcase/${OWNER}`).get());
});

test('a non-friend cannot read another athlete\'s showcase directly, whatever the path', async () => {
  await assertFails(as(STRANGER).doc(`users_showcase/${OWNER}`).get());
  await assertFails(as(ONE_SIDED).doc(`users_showcase/${OWNER}`).get(), 'a self-asserted friendship is not one');
  await assertFails(as(STRANGER).collection('users_showcase').get(), 'no listing');
  await assertFails(anon().doc(`users_showcase/${OWNER}`).get());
});

test('privileged access stays deliberate: super admin, support override, assigned coach', async () => {
  await assertSucceeds(as(SUPER).doc(`users_showcase/${OWNER}`).get());
  await assertSucceeds(as(SUPPORT).doc(`users_showcase/${OWNER}`).get());
  await assertSucceeds(as(COACH).doc(`users_showcase/${OWNER}`).get());
});

test('nobody — not the owner, not the super admin — can write a showcase', async () => {
  for (const uid of [OWNER, FRIEND, COACH, SUPPORT, SUPER, STRANGER]) {
    await assertFails(as(uid).doc(`users_showcase/${OWNER}`).set({ profileShowcaseV2: { forged: true } }));
  }
  await assertFails(as(OWNER).doc(`users_showcase/${OWNER}`).delete());
});

test('discovery keeps working: public identity and the username index stay searchable', async () => {
  await assertSucceeds(as(STRANGER).doc(`users_public/${OWNER}`).get());
  await assertSucceeds(as(STRANGER).collection('users_public').where('usernameLower', '==', 'lifter').get());
  await assertSucceeds(as(STRANGER).doc('usernames/lifter').get());
  await assertFails(as(OWNER).doc(`users_public/${OWNER}`).set(SHOWCASE, { merge: true }),
    'the owner still cannot forge the transition mirror');
});

test('private training data stays private: a stranger reads no workouts or day scores', async () => {
  await assertFails(as(STRANGER).doc(`users/${OWNER}`).get());
  await assertFails(as(STRANGER).collection(`users/${OWNER}/workouts`).get());
  await assertFails(as(STRANGER).collection(`users/${OWNER}/rePointDays`).get());
  await assertFails(as(FRIEND).collection(`users/${OWNER}/workouts`).get(), 'friendship is not training access');
});

// ── Leaderboard visibility choice ───────────────────────────────────────────

test('the owner can turn leaderboard visibility off and on again', async () => {
  const ref = as(OWNER).doc(`users/${OWNER}`);
  await assertSucceeds(ref.set({ leaderboardVisible: false }, { merge: true }));
  await assertSucceeds(ref.set({ leaderboardVisible: true }, { merge: true }));
  await assertSucceeds(ref.set({ leaderboardVisible: false, leaderboardVisibilitySource: 'settings' }, { merge: true }));
});

test('the choice must be a real boolean', async () => {
  const ref = as(OWNER).doc(`users/${OWNER}`);
  for (const bad of ['false', 0, null, { v: false }]) {
    await assertFails(ref.set({ leaderboardVisible: bad }, { merge: true }), JSON.stringify(bad));
  }
});

test('a coach cannot change the athlete\'s choice; neither can a friend or stranger', async () => {
  for (const uid of [COACH, FRIEND, STRANGER, SUPPORT]) {
    await assertFails(as(uid).doc(`users/${OWNER}`).set({ leaderboardVisible: true }, { merge: true }), uid);
  }
  await assertSucceeds(as(SUPER).doc(`users/${OWNER}`).set({ leaderboardVisible: false }, { merge: true }));
});

test('unrelated owner writes to users/{uid} are unaffected', async () => {
  await assertSucceeds(as(OWNER).doc(`users/${OWNER}`).set({ prefs: { feedTab: 'home' } }, { merge: true }));
  await assertSucceeds(as(OWNER).doc(`users/${OWNER}`).set({ sex: 'F', dob: '01-01-1990' }, { merge: true }));
});
