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

// ── Category medal snapshots ────────────────────────────────────────────────

test('medal snapshots: readable by any signed-in user, never by a visitor', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc('leaderboardMedals/2026-09').set({
      schema: 'leaderboardMedals', schemaVersion: 1, periodKey: '2026-09', boardType: 'month', revision: 1,
      categories: { horizontalPress: [{ uid: OWNER, place: 1, pointsUnits: 1000000, achievedDateKey: '2026-09-02' }] },
    });
    await ctx.firestore().doc('leaderboardMedals/all_time').set({ schema: 'leaderboardMedals', periodKey: 'all_time', categories: {} });
    await ctx.firestore().doc('leaderboardMedalQueue/2026-09').set({ periodKey: '2026-09', dirty: true });
  });
  for (const uid of [OWNER, OTHER, SUPER]) {
    await assertSucceeds(as(uid).doc('leaderboardMedals/2026-09').get());
    await assertSucceeds(as(uid).doc('leaderboardMedals/all_time').get());
    await assertSucceeds(as(uid).doc('leaderboardMedals/2031-01').get());
  }
  await assertFails(anon().doc('leaderboardMedals/2026-09').get());
});

test('no client — not even a medallist or the super admin — may create, edit or delete a medal snapshot', async () => {
  for (const uid of [OWNER, OTHER, SUPER]) {
    await assertFails(as(uid).doc('leaderboardMedals/2026-09').set({ categories: {} }));
    await assertFails(as(uid).doc('leaderboardMedals/2026-09').update({ revision: 99 }));
    await assertFails(as(uid).doc('leaderboardMedals/2026-09').delete());
    await assertFails(as(uid).doc('leaderboardMedals/2027-01').set({ categories: {} }));
  }
});

test('the private medal refresh queue is closed to every client', async () => {
  for (const uid of [OWNER, OTHER, SUPER]) {
    await assertFails(as(uid).doc('leaderboardMedalQueue/2026-09').get());
    await assertFails(as(uid).collection('leaderboardMedalQueue').get());
    await assertFails(as(uid).doc('leaderboardMedalQueue/2026-10').set({ dirty: true }));
    await assertFails(as(uid).doc('leaderboardMedalQueue/2026-09').delete());
  }
});

test('old app versions: the unchanged ranked entry query still works beside the medal fields', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc(`leaderboards/2026-09/entries/${OTHER}`).set({
      uid: OTHER, username: 'other', totalPointsUnits: 500000, tieBreakDateKey: '2026-09-03',
      categoryTotalsUnits: { horizontalPress: 500000 }, categoryDateKeys: { horizontalPress: '2026-09-03' },
      medalRankKeys: { horizontalPress: '0000999999500000~2026-09-03~x' }, formulaVersion: 'v',
    });
  });
  await assertSucceeds(
    as(OWNER)
      .collection('leaderboards/2026-09/entries')
      .where('totalPointsUnits', '>', 0)
      .orderBy('totalPointsUnits', 'desc')
      .orderBy('tieBreakDateKey')
      .orderBy('uid')
      .limit(50)
      .get(),
  );
});

test('age view: board and entries readable by signed-in users only; never client-written', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc('leaderboardsAge/2026-10').set({
      periodKey: '2026-10', ageModelVersion: 'goodlift-age-usapl-2026-10-v1', silverUids: [OTHER], rankedCount: 1, incompleteCount: 0,
    });
    await ctx.firestore().doc(`leaderboardsAge/2026-10/entries/${OTHER}`).set({
      uid: OTHER, ageModelVersion: 'goodlift-age-usapl-2026-10-v1', ageComplete: true, adjustedTotalUnits: 10, tieBreakDateKey: '2026-10-01',
    });
  });
  await assertSucceeds(as(OWNER).doc('leaderboardsAge/2026-10').get());
  await assertSucceeds(
    as(OWNER).collection('leaderboardsAge/2026-10/entries')
      .where('ageModelVersion', '==', 'goodlift-age-usapl-2026-10-v1').where('ageComplete', '==', true)
      .orderBy('adjustedTotalUnits', 'desc').orderBy('tieBreakDateKey').orderBy('uid').limit(20).get(),
  );
  await assertFails(anon().doc('leaderboardsAge/2026-10').get());
  await assertFails(anon().doc(`leaderboardsAge/2026-10/entries/${OTHER}`).get());
  for (const uid of [OWNER, OTHER, SUPER]) {
    await assertFails(as(uid).doc('leaderboardsAge/2026-10').set({ silverUids: [uid] }, { merge: true }));
    await assertFails(as(uid).doc(`leaderboardsAge/2026-10/entries/${uid}`).set({ adjustedTotalUnits: 999 }));
    await assertFails(as(uid).doc(`leaderboardsAge/2026-10/entries/${OTHER}`).delete());
  }
});

test('public website snapshots are closed to every client (served only by the HTTP function)', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc('leaderboardPublic/all_time').set({ schemaVersion: 1, periodKey: 'all_time', entries: [] });
  });
  for (const db of [as(OWNER), as(SUPER), anon()]) {
    await assertFails(db.doc('leaderboardPublic/all_time').get());
    await assertFails(db.doc('leaderboardPublic/all_time').set({ entries: [] }));
  }
});

test('private demographics stay private: another athlete cannot read users/{uid}.dob', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc(`users/${OTHER}`).set({ dob: '01-01-1950', sex: 'male' });
  });
  await assertFails(as(OWNER).doc(`users/${OTHER}`).get());
});

test('derived sex-board root snapshots retain signed-in read and server-only write access', async () => {
  for (const col of ['leaderboards', 'leaderboardsAge']) for (const sex of ['male', 'female']) {
    const path = `${col}/2026-10_${sex}`;
    await env.withSecurityRulesDisabled(async ctx => {
      await ctx.firestore().doc(path).set({ sexBoardSchemaVersion: 1,
        periodKey: '2026-10', sexFilter: sex, entries: [{ uid: OWNER }] });
    });
    await assertSucceeds(as(OTHER).doc(path).get());
    await assertFails(anon().doc(path).get());
    for (const uid of [OWNER, OTHER, SUPER]) {
      await assertFails(as(uid).doc(path).set({ entries: [] }));
      await assertFails(as(uid).doc(path).delete());
    }
  }
});
