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

// ── Profile rebuild jobs and per-exercise unit metadata ─────────────────────

test('profile rebuild jobs are closed to every client', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc(`profileRebuildJobs/${OWNER}`).set({ status: 'running', generation: 1 });
  });
  for (const uid of [OWNER, OTHER, SUPER]) {
    await assertFails(as(uid).doc(`profileRebuildJobs/${OWNER}`).get());
    await assertFails(as(uid).doc(`profileRebuildJobs/${uid}`).set({ status: 'queued' }));
    await assertFails(as(uid).doc(`profileRebuildJobs/${OWNER}`).update({ kick: 1 }));
  }
});

test('the owner edits weightUnit in their own exerciseSettings (the settings path)', async () => {
  const block = `users/${OWNER}/planned_blocks/b1`;
  await assertSucceeds(as(OWNER).doc(block).set({
    exerciseSettings: { AmfUWbF1DH3I7qPAdh5k: { weightUnit: 'lb' } },
  }, { merge: true }));
  // Settings are free-form by design; an invalid unit is ACCEPTED here and
  // safely ignored everywhere it is read (the app parses it as kg, and the
  // publication trigger never copies it).
  await assertSucceeds(as(OWNER).doc(block).set({
    exerciseSettings: { AmfUWbF1DH3I7qPAdh5k: { weightUnit: 'stone' } },
  }, { merge: true }));
  await assertFails(as(OTHER).doc(block).set({
    exerciseSettings: { AmfUWbF1DH3I7qPAdh5k: { weightUnit: 'lb' } },
  }, { merge: true }));
});

test('public unit metadata is readable by signed-in users and writable by no client', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc(`users_public/${OWNER}`).set({
      username: 'owner',
      exerciseWeightUnits: { AmfUWbF1DH3I7qPAdh5k: 'lb' },
    }, { merge: true });
  });
  const snap = await assertSucceeds(as(OTHER).doc(`users_public/${OWNER}`).get());
  if (snap.data().exerciseWeightUnits.AmfUWbF1DH3I7qPAdh5k !== 'lb') throw new Error('unit not readable');
  await assertFails(as(OWNER).doc(`users_public/${OWNER}`).set(
    { exerciseWeightUnits: { AmfUWbF1DH3I7qPAdh5k: 'kg' } },
    { merge: true },
  ));
  await assertFails(as(OWNER).doc(`users_public/${OWNER}`).update({ 'exerciseWeightUnits.x': 'lb' }));
  // Every other public field stays owner-editable.
  await assertSucceeds(as(OWNER).doc(`users_public/${OWNER}`).set({ bio: 'hi' }, { merge: true }));
});
