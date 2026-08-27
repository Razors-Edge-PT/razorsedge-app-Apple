'use strict';

// Firestore security-rules tests, run against the REAL rules engine in the
// Firestore emulator:
//   npm run test:rules      (firebase emulators:exec … node --test …)
//
// Fixtures:
//   coachSeeded  – admin-seeded via coachAssignments.athletes[ath1]
//   coachOk      – athlete-approved via athleteAssignments coaches.approved:true
//   coachPending – request exists but approved is absent
//   coachDenied  – approved: false
//   superadmin   – the app's single hardcoded super admin uid

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');

const SUPER = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'rules-test',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8'),
    },
  });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    // Assignment fixtures.
    await db.doc('coachAssignments/coachSeeded').set({
      athletes: { ath1: { email: 'ath1@x.com' } },
    });
    await db.doc('athleteAssignments/ath2').set({
      coaches: {
        coachOk: { approved: true },
        coachPending: { status: 'pending' },
        coachDenied: { approved: false },
      },
    });
    // Feature documents.
    await db.doc('coachAnalytics/ath1').set({ enabledBy: { coachSeeded: true } });
    await db.doc('coachAnalytics/ath1/exercises/bench').set({ name: 'Bench' });
    await db.doc('coachAnalytics/ath1/events/e1').set({ exerciseId: 'bench', type: 'repPB' });
    await db.doc('coachAnalytics/ath1/exerciseDays/bench_2026-08-10').set({
      exerciseId: 'bench', dateKey: '2026-08-10', day: {},
    });
    await db.doc('coachAnalytics/ath2').set({ enabledBy: { coachOk: true } });

    await db.doc('coachCheckIns/coachSeeded').set({ timezone: 'Pacific/Auckland' });
    await db.doc('coachCheckIns/coachSeeded/athletes/ath1').set({
      reportingEnabled: true, goal: 'cut', goalSetAt: 1000,
      praisedWeeks: { '2026-08-03': 'r1' },
      praisedMilestones: { 'cut_110@1000': { reportId: 'r1' } },
      lastFinalizedCoverageEnd: '2026-08-10',
    });
    await db.doc('coachCheckIns/coachSeeded/reports/ath1_2026-08-10').set({
      athleteUid: 'ath1', checkpointKey: '2026-08-10', status: 'draft',
    });
    // Report whose embedded athlete the coach is NOT assigned to.
    await db.doc('coachCheckIns/coachSeeded/reports/ath2_2026-08-10').set({
      athleteUid: 'ath2', checkpointKey: '2026-08-10', status: 'draft',
    });
    await db.doc('coachCheckIns/coachOk/reports/ath2_2026-08-10').set({
      athleteUid: 'ath2', checkpointKey: '2026-08-10', status: 'draft',
    });
  });
});

test.after(async () => {
  if (env) await env.cleanup();
});

const as = (uid) => env.authenticatedContext(uid).firestore();

// ── Assignment / approval model (item A) ────────────────────────────────────

test('rules: seeded coach reads assigned athlete analytics', async () => {
  await assertSucceeds(as('coachSeeded').doc('coachAnalytics/ath1').get());
  await assertSucceeds(as('coachSeeded').doc('coachAnalytics/ath1/exercises/bench').get());
  await assertSucceeds(as('coachSeeded').doc('coachAnalytics/ath1/events/e1').get());
  await assertSucceeds(as('coachSeeded').doc('coachAnalytics/ath1/exerciseDays/bench_2026-08-10').get());
});

test('rules: approved coach reads assigned athlete analytics', async () => {
  await assertSucceeds(as('coachOk').doc('coachAnalytics/ath2').get());
});

test('rules: pending and approved:false coaches are denied analytics', async () => {
  await assertFails(as('coachPending').doc('coachAnalytics/ath2').get());
  await assertFails(as('coachDenied').doc('coachAnalytics/ath2').get());
});

test('rules: coach denied analytics for an unassigned athlete', async () => {
  await assertFails(as('coachSeeded').doc('coachAnalytics/ath2').get());
  await assertFails(as('coachOk').doc('coachAnalytics/ath1').get());
});

test('rules: athlete reads own analytics but can never write them', async () => {
  await assertSucceeds(as('ath1').doc('coachAnalytics/ath1').get());
  await assertFails(as('ath1').doc('coachAnalytics/ath1').set({ enabledBy: {} }));
  await assertFails(as('ath1').doc('coachAnalytics/ath1/events/forged').set({
    type: 'repPB', exerciseId: 'bench', dateKey: '2026-08-12', weightKg: 999,
  }));
  await assertFails(as('ath1').doc('coachAnalytics/ath1/exercises/bench').set({
    e1rmBest: { e1rmKg: 999 },
  }));
});

test('rules: canonical nested planned blocks use the training-access gate', async () => {
  const block = as('ath1').doc('users/ath1/planned_blocks/blockA');
  const day = as('ath1').doc(
    'users/ath1/planned_blocks/blockA/weeks/week_0/days/day_1',
  );

  await assertSucceeds(block.set({ name: 'Block A', isActive: true }));
  await assertSucceeds(day.set({ exercises: [] }));
  await assertSucceeds(
    as('coachSeeded').doc('users/ath1/planned_blocks/blockA').get(),
  );
  await assertSucceeds(
    as('coachSeeded')
      .doc('users/ath1/planned_blocks/blockA')
      .update({ name: 'Coach edit' }),
  );
  await assertFails(
    as('coachOk').doc('users/ath1/planned_blocks/blockA').get(),
  );
});

test('rules: legacy planned-block path remains available during rollout', async () => {
  const legacy = as('ath1').doc('planned_blocks/ath1/blocks/blockA');
  await assertSucceeds(legacy.set({ name: 'Legacy block' }));
  await assertSucceeds(
    as('coachSeeded').doc('planned_blocks/ath1/blocks/blockA').get(),
  );
  await assertFails(
    as('coachOk').doc('planned_blocks/ath1/blocks/blockA').get(),
  );
});

// ── Coach workspace isolation (item B) ──────────────────────────────────────

test('rules: Coach A cannot read Coach B reports or settings', async () => {
  await assertFails(as('coachOk').doc('coachCheckIns/coachSeeded/reports/ath1_2026-08-10').get());
  await assertFails(as('coachOk').doc('coachCheckIns/coachSeeded/athletes/ath1').get());
  await assertFails(as('coachOk').doc('coachCheckIns/coachSeeded').get());
});

test('rules: reports verify their embedded athleteUid, not just the path', async () => {
  await assertSucceeds(as('coachSeeded').doc('coachCheckIns/coachSeeded/reports/ath1_2026-08-10').get());
  // Same coach path, but the embedded athlete is not assigned to them.
  await assertFails(as('coachSeeded').doc('coachCheckIns/coachSeeded/reports/ath2_2026-08-10').get());
});

test('rules: athlete cannot read or forge coach reports', async () => {
  await assertFails(as('ath1').doc('coachCheckIns/coachSeeded/reports/ath1_2026-08-10').get());
  await assertFails(as('ath1').doc('coachCheckIns/coachSeeded/reports/ath1_2026-08-13').set({
    athleteUid: 'ath1', status: 'copied', finalText: 'forged',
  }));
});

test('rules: coach cannot forge copiedAt/finalText or any report mutation', async () => {
  await assertFails(as('coachSeeded').doc('coachCheckIns/coachSeeded/reports/ath1_2026-08-10')
    .update({ status: 'copied', finalText: 'forged', copiedAtMs: 1 }));
});

test('rules: revoked coach immediately loses settings/reports/analytics access', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc('coachAssignments/coachRevoked').set({
      athletes: { ath9: {} },
    });
    await ctx.firestore().doc('coachAnalytics/ath9').set({ enabledBy: { coachRevoked: true } });
    await ctx.firestore().doc('coachCheckIns/coachRevoked/athletes/ath9').set({ reportingEnabled: true });
    await ctx.firestore().doc('coachCheckIns/coachRevoked/reports/ath9_2026-08-10').set({
      athleteUid: 'ath9', status: 'draft',
    });
  });
  // Assigned: everything readable.
  await assertSucceeds(as('coachRevoked').doc('coachAnalytics/ath9').get());
  await assertSucceeds(as('coachRevoked').doc('coachCheckIns/coachRevoked/athletes/ath9').get());
  await assertSucceeds(as('coachRevoked').doc('coachCheckIns/coachRevoked/reports/ath9_2026-08-10').get());
  // Revoke (remove the seeded entry).
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc('coachAssignments/coachRevoked').set({ athletes: {} });
  });
  await assertFails(as('coachRevoked').doc('coachAnalytics/ath9').get());
  await assertFails(as('coachRevoked').doc('coachCheckIns/coachRevoked/athletes/ath9').get());
  await assertFails(as('coachRevoked').doc('coachCheckIns/coachRevoked/reports/ath9_2026-08-10').get());
  await assertFails(as('coachRevoked').doc('coachCheckIns/coachRevoked/athletes/ath9')
    .update({ reportingEnabled: true }));
});

// ── Server-owned bookkeeping protection (item C) ────────────────────────────

test('rules: coach can update only legitimate settings fields', async () => {
  await assertSucceeds(as('coachSeeded').doc('coachCheckIns/coachSeeded/athletes/ath1')
    .update({ reportingEnabled: false, updatedAt: 1 }));
  await assertSucceeds(as('coachSeeded').doc('coachCheckIns/coachSeeded/athletes/ath1')
    .update({ goal: 'bulk' }));
  await assertSucceeds(as('coachSeeded').doc('coachCheckIns/coachSeeded/athletes/ath1')
    .update({ messageExerciseMode: 'custom', customExerciseIds: ['a', 'b'] }));
});

test('rules: coach cannot touch server bookkeeping or goalSetAt', async () => {
  const doc = as('coachSeeded').doc('coachCheckIns/coachSeeded/athletes/ath1');
  await assertFails(doc.update({ praisedWeeks: {} }));
  await assertFails(doc.update({ praisedMilestones: {} }));
  await assertFails(doc.update({ lastFinalizedCoverageEnd: '2020-01-01' }));
  await assertFails(doc.update({ disabledReason: 'x' }));
  await assertFails(doc.update({ goalSetAt: 999 })); // no manufactured phases
});

test('rules: coach cannot delete the settings document (server state reset)', async () => {
  await assertFails(as('coachSeeded').doc('coachCheckIns/coachSeeded/athletes/ath1').delete());
});

test('rules: invalid setting values are rejected', async () => {
  const doc = as('coachSeeded').doc('coachCheckIns/coachSeeded/athletes/ath1');
  await assertFails(doc.update({ goal: 'shred' }));
  await assertFails(doc.update({ reportingEnabled: 'yes' }));
  await assertFails(doc.update({ messageExerciseMode: 'llm' }));
  await assertFails(doc.update({ customExerciseIds: 'bench' }));
});

test('rules: coach cannot create settings for an unassigned athlete', async () => {
  await assertFails(as('coachSeeded').doc('coachCheckIns/coachSeeded/athletes/ath2')
    .set({ reportingEnabled: true }));
});

test('rules: coach timezone writes validated; watermark unreachable', async () => {
  const doc = as('coachSeeded').doc('coachCheckIns/coachSeeded');
  await assertSucceeds(doc.update({ timezone: 'Australia/Sydney', updatedAt: 1 }));
  await assertFails(doc.update({ timezone: 123 }));
  await assertFails(doc.update({ timezone: 'x'.repeat(80) }));
  await assertFails(doc.update({ lastCheckpointKey: '2030-01-01' }));
});

// ── Superadmin (intentional, consistent with the app) ───────────────────────

test('rules: superadmin reaches an athlete with NO assignment document at all', async () => {
  // Regression: super-admin is effectively coach for every athlete and must
  // not need a seeded or approved assignment. athOrphan has no entry in
  // either assignment collection.
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('coachAnalytics/athOrphan').set({ enabledBy: {} });
    await db.doc('coachAnalytics/athOrphan/events/e1').set({ exerciseId: 'bench' });
    await db.doc(`coachCheckIns/${SUPER}/athletes/athOrphan`).set({ reportingEnabled: false });
    await db.doc(`coachCheckIns/${SUPER}/reports/athOrphan_2026-08-10`).set({
      athleteUid: 'athOrphan', status: 'draft',
    });
  });

  await assertSucceeds(as(SUPER).doc('coachAnalytics/athOrphan').get());
  await assertSucceeds(as(SUPER).doc('coachAnalytics/athOrphan/events/e1').get());
  await assertSucceeds(as(SUPER).doc(`coachCheckIns/${SUPER}/athletes/athOrphan`).get());
  await assertSucceeds(as(SUPER).doc(`coachCheckIns/${SUPER}/reports/athOrphan_2026-08-10`).get());
  // Super-admin may configure reporting for that athlete.
  await assertSucceeds(as(SUPER).doc(`coachCheckIns/${SUPER}/athletes/athOrphan`)
    .update({ reportingEnabled: true, goal: 'cut' }));

  // An ordinary coach with no assignment to athOrphan remains denied.
  await assertFails(as('coachSeeded').doc('coachAnalytics/athOrphan').get());
  await assertFails(as('coachOk').doc('coachAnalytics/athOrphan').get());
  await assertFails(as('coachSeeded').doc('coachCheckIns/coachSeeded/athletes/athOrphan')
    .set({ reportingEnabled: true }));
});

test('rules: superadmin retains read/manage access', async () => {
  await assertSucceeds(as(SUPER).doc('coachAnalytics/ath1').get());
  await assertSucceeds(as(SUPER).doc('coachCheckIns/coachSeeded/reports/ath1_2026-08-10').get());
  await assertSucceeds(as(SUPER).doc('coachCheckIns/coachSeeded/athletes/ath1').get());
  await assertSucceeds(as(SUPER).doc('coachCheckIns/coachSeeded/athletes/ath1').delete());
});
