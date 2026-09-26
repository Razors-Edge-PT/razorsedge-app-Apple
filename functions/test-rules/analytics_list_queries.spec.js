'use strict';

// Analytics reads a SELECTED athlete's data with the exact queries the app
// runs (lib/analytics_history_loader.dart, lib/exercise_details_screen.dart,
// lib/exercise_catalog.dart), as the athlete, their active coach, the super
// admin, and outsiders. Collection (list) queries are evaluated differently
// from single-document reads, so these are asserted as queries, not .get().
//
//   npm run test:rules

const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');

const SUPER = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const ATHLETE = 'anAthlete';
const COACH = 'anCoach';
const OTHER_COACH = 'anOtherCoach';
const STRANGER = 'anStranger';
const SEEDED_COACH = 'anSeededCoach';
const LEGACY_COACH = 'anLegacyCoach';

let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'rules-test-analytics',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8'),
    },
  });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const active = { coach: { state: 'active', source: 'manual_review' } };
    await db.doc(`accountEntitlements/${COACH}`).set(active);
    await db.doc(`accountEntitlements/${OTHER_COACH}`).set(active);
    await db.doc(`coachAthleteLinks/${COACH}__${ATHLETE}`).set({
      coachUid: COACH, athleteUid: ATHLETE, status: 'active',
    });
    // The other two coach sources isCoachFor() accepts (with an entitlement).
    await db.doc(`accountEntitlements/${SEEDED_COACH}`).set(active);
    await db.doc(`coachAssignments/${SEEDED_COACH}`).set({ athletes: { [ATHLETE]: true } });
    await db.doc(`accountEntitlements/${LEGACY_COACH}`).set(active);
    await db.doc(`athleteAssignments/${ATHLETE}`).set({ coaches: { [LEGACY_COACH]: { approved: true } } });
    await db.doc(`users/${ATHLETE}`).set({ username: 'athlete' });
    // Both stored date shapes the loader queries for.
    await db.doc(`users/${ATHLETE}/workouts/2026-09-01`).set({
      date: new Date('2026-09-01T00:00:00Z'), exercises: [],
    });
    await db.doc(`users/${ATHLETE}/workouts/2026-09-02`).set({ date: '2026-09-02', exercises: [] });
    await db.doc(`users/${ATHLETE}/weights/w1`).set({ weight: 80, timestamp: new Date() });
    await db.doc(`users/${ATHLETE}/customExercises/c1`).set({ name: 'Custom', ownerUid: ATHLETE });
  });
});

test.after(async () => {
  if (env) await env.cleanup();
});

const as = (uid) => env.authenticatedContext(uid).firestore();

/** The Analytics reads, in the app's exact query shapes. */
function analyticsReads(db, uid) {
  const since = new Date('2026-06-01T00:00:00Z');
  const workouts = db.collection(`users/${uid}/workouts`);
  return {
    workoutsByTimestamp: () => workouts
      .where('date', '>=', since).orderBy('date', 'desc').limit(50).get(),
    workoutsByDateKey: () => workouts
      .where('date', '>=', '2026-06-01').orderBy('date', 'desc').limit(50).get(),
    weights: () => db.collection(`users/${uid}/weights`).orderBy('timestamp').get(),
    customExercises: () => db.collection(`users/${uid}/customExercises`).get(),
  };
}

for (const [who, uid, allowed] of [
  ['the athlete (self view)', ATHLETE, true],
  ['their active coach (selected athlete)', COACH, true],
  ['the super admin (selected athlete)', SUPER, true],
  ['a seeded-roster coach (selected athlete)', SEEDED_COACH, true],
  ['a legacy-approved coach (selected athlete)', LEGACY_COACH, true],
  ['an entitled coach with no link', OTHER_COACH, false],
  ['a stranger', STRANGER, false],
]) {
  test(`Analytics list queries for a selected athlete: ${who} → ${allowed ? 'allowed' : 'denied'}`, async () => {
    const reads = analyticsReads(as(uid), ATHLETE);
    for (const [name, run] of Object.entries(reads)) {
      if (allowed) await assertSucceeds(run(), name);
      else await assertFails(run(), name);
    }
  });
}
