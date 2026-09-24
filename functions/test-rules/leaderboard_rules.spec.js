'use strict';

// Firestore rules for the RE Points leaderboard projections.
//
//   npm run test:rules

const test = require('node:test');
const fs = require('fs');
const path = require('path');
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');

const OWNER = 'lbOwnerUid';
const OTHER = 'lbOtherUid';
const SUPER = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';

let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'rules-test-leaderboard',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8'),
    },
  });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('leaderboards/2026-09').set({ periodKey: '2026-09', status: 'open' });
    await db.doc(`leaderboards/2026-09/entries/${OWNER}`).set({
      uid: OWNER, username: 'owner', totalPointsUnits: 1000000, tieBreakDateKey: '2026-09-02',
    });
    await db.doc(`leaderboards/all_time/entries/${OWNER}`).set({
      uid: OWNER, username: 'owner', totalPointsUnits: 2000000, tieBreakDateKey: '2026-09-02',
    });
    await db.doc(`leaderboardRecalcQueue/${OWNER}`).set({ uid: OWNER, full: true });
    await db.doc(`users/${OWNER}/rePointDays/2026-09-02`).set({ totalPointsUnits: 1000000 });
  });
});

test.after(async () => {
  if (env) await env.cleanup();
});

const as = (uid) => env.authenticatedContext(uid).firestore();
const anon = () => env.unauthenticatedContext().firestore();

test('any signed-in user can read periods and ranked entries', async () => {
  for (const uid of [OWNER, OTHER]) {
    await assertSucceeds(as(uid).doc('leaderboards/2026-09').get());
    await assertSucceeds(as(uid).doc(`leaderboards/2026-09/entries/${OWNER}`).get());
    await assertSucceeds(
      as(uid)
        .collection('leaderboards/all_time/entries')
        .orderBy('totalPointsUnits', 'desc')
        .limit(50)
        .get(),
    );
  }
});

test('a logged-out visitor cannot read the leaderboard', async () => {
  await assertFails(anon().doc(`leaderboards/2026-09/entries/${OWNER}`).get());
  await assertFails(anon().collection('leaderboards/2026-09/entries').get());
});

test('no client — not even the owner — may write a leaderboard projection', async () => {
  for (const uid of [OWNER, OTHER, SUPER]) {
    await assertFails(
      as(uid).doc(`leaderboards/2026-09/entries/${OWNER}`).set({ totalPointsUnits: 999999999 }),
    );
    await assertFails(
      as(uid).doc(`leaderboards/2026-09/entries/${OWNER}`).update({ totalPointsUnits: 1 }),
    );
    await assertFails(as(uid).doc(`leaderboards/2026-09/entries/${OWNER}`).delete());
    await assertFails(as(uid).doc(`leaderboards/all_time/entries/${uid}`).set({ totalPointsUnits: 5 }));
    await assertFails(as(uid).doc('leaderboards/2026-10').set({ status: 'open' }));
  }
});

test('the recalculation queue is closed to every client', async () => {
  for (const uid of [OWNER, OTHER, SUPER]) {
    await assertFails(as(uid).doc(`leaderboardRecalcQueue/${OWNER}`).get());
    await assertFails(as(uid).doc(`leaderboardRecalcQueue/${uid}`).set({ full: true }));
  }
});

test('day scores are readable by their owner only and writable by no client', async () => {
  const day = `users/${OWNER}/rePointDays/2026-09-02`;
  await assertSucceeds(as(OWNER).doc(day).get());
  await assertFails(as(OTHER).doc(day).get());
  await assertFails(as(OWNER).doc(day).set({ totalPointsUnits: 999999999 }));
  await assertFails(as(OWNER).doc(`users/${OWNER}/rePointDays/2026-09-03`).set({ totalPointsUnits: 1 }));
  await assertFails(as(OTHER).doc(day).set({ totalPointsUnits: 1 }));
});

test('the owner keeps writing their ordinary subcollections (catch-all intact)', async () => {
  await assertSucceeds(
    as(OWNER).doc(`users/${OWNER}/workouts/2026-09-02`).set({ exercises: [] }),
  );
});
