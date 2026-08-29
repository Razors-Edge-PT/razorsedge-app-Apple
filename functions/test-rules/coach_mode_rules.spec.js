'use strict';

// Firestore security-rules tests for Coach Mode, run against the REAL rules
// engine in the Firestore emulator:
//   npm run test:rules
//
// Fixtures (all seeded with rules disabled, exactly as Cloud Functions would):
//   cmCoachActive     – active entitlement + ACTIVE link to cmAthlete
//   cmCoachPending    – active entitlement + PENDING link to cmAthletePending
//   cmCoachSuspended  – SUSPENDED entitlement + ACTIVE link to cmAthleteSusp
//   cmCoachRevoked    – REVOKED entitlement + ACTIVE link to cmAthleteRev
//   cmCoachNoEnt      – NO entitlement + ACTIVE link (link alone must not do)
//   cmCoachSeeded     – LEGACY super-admin-seeded roster only
//   cmStranger        – a signed-in account with no coaching relationship
//   superadmin        – the app's single hardcoded super admin uid

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');

const SUPER = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const link = (c, a) => `coachAthleteLinks/${c}__${a}`;

let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'rules-test-coachmode',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8'),
    },
  });

  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const active = { coach: { state: 'active', source: 'manual_review' } };

    // ── Entitlements ──
    await db.doc('accountEntitlements/cmCoachActive').set(active);
    await db.doc('accountEntitlements/cmCoachPending').set(active);
    await db.doc('accountEntitlements/cmCoachSuspended').set({
      coach: { state: 'suspended', source: 'manual_review', suspensionReason: 'hold' },
    });
    await db.doc('accountEntitlements/cmCoachRevoked').set({
      coach: { state: 'revoked', source: 'manual_review', revocationReason: 'gone' },
    });
    // Deliberately malformed: must never authorise, and must never raise an
    // evaluation error that denies unrelated branches.
    await db.doc('accountEntitlements/cmCoachMalformed').set({ coach: {} });

    // ── Canonical links ──
    await db.doc(link('cmCoachActive', 'cmAthlete')).set({
      coachUid: 'cmCoachActive', athleteUid: 'cmAthlete', status: 'active',
    });
    await db.doc(link('cmCoachPending', 'cmAthletePending')).set({
      coachUid: 'cmCoachPending', athleteUid: 'cmAthletePending', status: 'pending',
    });
    await db.doc(link('cmCoachActive', 'cmAthleteDeclined')).set({
      coachUid: 'cmCoachActive', athleteUid: 'cmAthleteDeclined', status: 'declined',
    });
    await db.doc(link('cmCoachActive', 'cmAthleteCancelled')).set({
      coachUid: 'cmCoachActive', athleteUid: 'cmAthleteCancelled', status: 'cancelled',
    });
    await db.doc(link('cmCoachActive', 'cmAthleteRevoked')).set({
      coachUid: 'cmCoachActive', athleteUid: 'cmAthleteRevoked', status: 'revoked_by_athlete',
    });
    await db.doc(link('cmCoachActive', 'cmAthleteReleased')).set({
      coachUid: 'cmCoachActive', athleteUid: 'cmAthleteReleased', status: 'released_by_coach',
    });
    await db.doc(link('cmCoachSuspended', 'cmAthleteSusp')).set({
      coachUid: 'cmCoachSuspended', athleteUid: 'cmAthleteSusp', status: 'active',
    });
    await db.doc(link('cmCoachRevoked', 'cmAthleteRev')).set({
      coachUid: 'cmCoachRevoked', athleteUid: 'cmAthleteRev', status: 'active',
    });
    await db.doc(link('cmCoachNoEnt', 'cmAthleteNoEnt')).set({
      coachUid: 'cmCoachNoEnt', athleteUid: 'cmAthleteNoEnt', status: 'active',
    });

    // ── Legacy seeded roster ──
    await db.doc('coachAssignments/cmCoachSeeded').set({
      athletes: { cmAthleteSeeded: { email: 'seeded@x.com' } },
    });

    // ── CORRECTIVE PASS fixtures ──
    // Legacy approval, NO entitlement.
    await db.doc('athleteAssignments/cmLegacyAthlete').set({
      coaches: { cmLegacyApprovedNoEnt: { approved: true } },
    });
    // SUSPENDED entitlement + seeded assignment.
    await db.doc('accountEntitlements/cmCoachSuspSeeded').set({
      coach: { state: 'suspended', source: 'manual_review' },
    });
    await db.doc('coachAssignments/cmCoachSuspSeeded').set({
      athletes: { cmSuspSeededAthlete: { email: 's@x.com' } },
    });
    // REVOKED entitlement + legacy approval.
    await db.doc('accountEntitlements/cmCoachRevApproved').set({
      coach: { state: 'revoked', source: 'manual_review' },
    });
    await db.doc('athleteAssignments/cmRevApprovedAthlete').set({
      coaches: { cmCoachRevApproved: { approved: true } },
    });
    // ACTIVE entitlement + seeded assignment (documented compatibility).
    await db.doc('accountEntitlements/cmCoachEntSeeded').set(active);
    await db.doc('coachAssignments/cmCoachEntSeeded').set({
      athletes: { cmEntSeededAthlete: { email: 'es@x.com' } },
    });
    // ACTIVE entitlement + legacy approval.
    await db.doc('accountEntitlements/cmCoachEntApproved').set(active);
    await db.doc('athleteAssignments/cmEntApprovedAthlete').set({
      coaches: { cmCoachEntApproved: { approved: true } },
    });
    // ACTIVE entitlement + legacy approval + TERMINATED canonical link.
    await db.doc('accountEntitlements/cmCoachTerminated').set(active);
    await db.doc('athleteAssignments/cmTerminatedAthlete').set({
      coaches: { cmCoachTerminated: { approved: true } },
    });
    await db.doc(link('cmCoachTerminated', 'cmTerminatedAthlete')).set({
      coachUid: 'cmCoachTerminated', athleteUid: 'cmTerminatedAthlete',
      status: 'released_by_coach',
    });
    // ACTIVE entitlement + SEEDED assignment + TERMINATED link: seeding wins.
    await db.doc('accountEntitlements/cmCoachTermSeeded').set(active);
    await db.doc('coachAssignments/cmCoachTermSeeded').set({
      athletes: { cmTermSeededAthlete: { email: 'ts@x.com' } },
    });
    await db.doc(link('cmCoachTermSeeded', 'cmTermSeededAthlete')).set({
      coachUid: 'cmCoachTermSeeded', athleteUid: 'cmTermSeededAthlete',
      status: 'revoked_by_athlete',
    });

    // ── Applications, profiles, audit ──
    await db.doc('coachApplications/cmApplicant').set({
      uid: 'cmApplicant', status: 'submitted',
      answers: { intendedUse: 'private stuff' },
    });
    await db.doc('coachProfiles/cmCoachActive').set({
      uid: 'cmCoachActive', displayName: 'Coach Active', email: 'ca@x.com',
    });
    await db.doc('coachProfiles/cmCoachPending').set({
      uid: 'cmCoachPending', displayName: 'Coach Pending', email: 'cp@x.com',
    });
    await db.doc('coachAdminAudit/entry1').set({
      actorUid: SUPER, targetUid: 'cmCoachActive', action: 'direct_grant',
    });

    // ── Training data the access tests read ──
    for (const a of ['cmAthlete', 'cmAthletePending', 'cmAthleteSusp', 'cmAthleteRev',
      'cmAthleteNoEnt', 'cmAthleteSeeded', 'cmAthleteDeclined', 'cmAthleteCancelled',
      'cmAthleteRevoked', 'cmAthleteReleased', 'cmStrangerAthlete',
      'cmLegacyAthlete', 'cmSuspSeededAthlete', 'cmRevApprovedAthlete',
      'cmEntSeededAthlete', 'cmEntApprovedAthlete', 'cmTerminatedAthlete',
      'cmTermSeededAthlete']) {
      await db.doc(`users/${a}`).set({ email: `${a}@x.com` });
      await db.doc(`users/${a}/workouts/2026-08-10`).set({ exercises: [] });
      await db.doc(`planned_blocks/${a}`).set({ isActive: true });
      await db.doc(`coachAnalytics/${a}`).set({ enabledBy: {} });
    }

    // Subcollection fixtures for the fail-closed allowlist tests.
    for (const sub of ['workouts', 'weights', 'block_planner', 'block_data',
      'plannedExerciseDetails', 'templates', 'customExercises']) {
      await db.doc(`users/cmAthlete/${sub}/d1`).set({ seeded: true });
    }
    await db.doc('users/cmAthlete/planned_blocks/b1').set({ name: 'Block 1' });
    await db.doc('users/cmAthlete/planned_blocks/b1/weeks/w1').set({ n: 1 });
    await db.doc('users/cmAthlete/profile/membership')
      .set({ active: true, paywallTriggered: false });
    await db.doc('users/cmAthlete/buddyInvites/someSender')
      .set({ fromUid: 'someSender', buddyUid: 'cmAthlete' });
    for (const sub of ['someFutureFeature', 'billing', 'privateNotes',
      're_daily', 're_monthly', 're_cache', 'onboarding', 'posts']) {
      await db.doc(`users/cmAthlete/${sub}/d1`).set({ seeded: true });
    }

    // ── Social / DM fixtures, to prove Coach Mode is not a bypass ──
    await db.doc('posts/cmPost').set({ ownerUid: 'cmAthlete', caption: 'hi' });
    await db.doc('users/cmAthlete/liftVideos/v1').set({ url: 'x' });
    await db.doc(`conversations/${'cmAthlete'.padEnd(28, 'z')}_${'cmCoachActive'.padEnd(28, 'z')}`)
      .set({ participants: { cmAthlete: true, cmCoachActive: true } });
  });
});

test.after(async () => {
  if (env) await env.cleanup();
});

const as = (uid) => env.authenticatedContext(uid).firestore();
const anon = () => env.unauthenticatedContext().firestore();

// ══════════════════════════════════════════════════════════════════════════
// The closed vulnerability: coachAssignments self-seeding
// ══════════════════════════════════════════════════════════════════════════

test('rules: an ordinary signed-in account CANNOT self-seed coachAssignments', async () => {
  // This is the exact previous attack: write your own roster document naming
  // any athlete, and isCoachFor() would then hand you their training data.
  await assertFails(as('cmStranger').doc('coachAssignments/cmStranger').set({
    athletes: { cmStrangerAthlete: { email: 'victim@x.com' } },
  }));
  // Nor via a merge/update of a field path.
  await assertFails(as('cmStranger').doc('coachAssignments/cmStranger')
    .set({ athletes: { cmStrangerAthlete: {} } }, { merge: true }));

  // And the attack's payoff is unreachable.
  await assertFails(as('cmStranger').doc('users/cmStrangerAthlete').get());
  await assertFails(as('cmStranger').doc('users/cmStrangerAthlete/workouts/2026-08-10').get());
});

test('rules: even an ACTIVE coach cannot add athletes to their own seeded roster', async () => {
  await assertFails(as('cmCoachActive').doc('coachAssignments/cmCoachActive').set({
    athletes: { cmAthleteSeeded: {} },
  }));
  await assertFails(as('cmCoachSeeded').doc('coachAssignments/cmCoachSeeded').set({
    athletes: { cmAthlete: {} },
  }, { merge: true }));
});

test('rules: a coach may still READ their own seeded roster', async () => {
  await assertSucceeds(as('cmCoachSeeded').doc('coachAssignments/cmCoachSeeded').get());
  // But not somebody else's.
  await assertFails(as('cmCoachActive').doc('coachAssignments/cmCoachSeeded').get());
});

test('rules: only the super admin may write coachAssignments (seeding preserved)', async () => {
  await assertSucceeds(as(SUPER).doc('coachAssignments/cmCoachSeeded').set({
    athletes: { cmAthleteSeeded: { email: 'seeded@x.com' }, cmAthlete: { email: 'a@x.com' } },
  }));
  // Restore the fixture for the legacy-authorisation test below.
  await assertSucceeds(as(SUPER).doc('coachAssignments/cmCoachSeeded').set({
    athletes: { cmAthleteSeeded: { email: 'seeded@x.com' } },
  }));
});

// ══════════════════════════════════════════════════════════════════════════
// Canonical authorization
// ══════════════════════════════════════════════════════════════════════════

test('rules: active entitlement + ACTIVE link grants assigned training access', async () => {
  await assertSucceeds(as('cmCoachActive').doc('users/cmAthlete').get());
  await assertSucceeds(as('cmCoachActive').doc('users/cmAthlete/workouts/2026-08-10').get());
  await assertSucceeds(as('cmCoachActive').doc('planned_blocks/cmAthlete').get());
  await assertSucceeds(as('cmCoachActive').doc('coachAnalytics/cmAthlete').get());
});

test('rules: a PENDING invitation grants no training access at all', async () => {
  await assertFails(as('cmCoachPending').doc('users/cmAthletePending').get());
  await assertFails(as('cmCoachPending').doc('users/cmAthletePending/workouts/2026-08-10').get());
  await assertFails(as('cmCoachPending').doc('planned_blocks/cmAthletePending').get());
  await assertFails(as('cmCoachPending').doc('coachAnalytics/cmAthletePending').get());
});

test('rules: declined / cancelled / revoked / released links grant no access', async () => {
  for (const athlete of ['cmAthleteDeclined', 'cmAthleteCancelled',
    'cmAthleteRevoked', 'cmAthleteReleased']) {
    await assertFails(as('cmCoachActive').doc(`users/${athlete}`).get());
    await assertFails(as('cmCoachActive').doc(`users/${athlete}/workouts/2026-08-10`).get());
    await assertFails(as('cmCoachActive').doc(`planned_blocks/${athlete}`).get());
  }
});

test('rules: a SUSPENDED coach loses access despite an ACTIVE link', async () => {
  await assertFails(as('cmCoachSuspended').doc('users/cmAthleteSusp').get());
  await assertFails(as('cmCoachSuspended').doc('users/cmAthleteSusp/workouts/2026-08-10').get());
  await assertFails(as('cmCoachSuspended').doc('coachAnalytics/cmAthleteSusp').get());
});

test('rules: a REVOKED coach loses access despite an ACTIVE link', async () => {
  await assertFails(as('cmCoachRevoked').doc('users/cmAthleteRev').get());
  await assertFails(as('cmCoachRevoked').doc('users/cmAthleteRev/workouts/2026-08-10').get());
  await assertFails(as('cmCoachRevoked').doc('coachAnalytics/cmAthleteRev').get());
});

test('rules: an ACTIVE link WITHOUT an entitlement grants nothing', async () => {
  await assertFails(as('cmCoachNoEnt').doc('users/cmAthleteNoEnt').get());
  await assertFails(as('cmCoachNoEnt').doc('users/cmAthleteNoEnt/workouts/2026-08-10').get());
});

test('rules: a malformed entitlement never authorises', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc(link('cmCoachMalformed', 'cmAthlete')).set({
      coachUid: 'cmCoachMalformed', athleteUid: 'cmAthlete', status: 'active',
    });
  });
  await assertFails(as('cmCoachMalformed').doc('users/cmAthlete').get());
});

test('rules: one coach cannot reach another coach\'s athlete', async () => {
  await assertFails(as('cmCoachPending').doc('users/cmAthlete').get());
  await assertFails(as('cmCoachSeeded').doc('users/cmAthlete').get());
  await assertFails(as('cmCoachActive').doc('users/cmAthleteSeeded').get());
});

test('rules: an unrelated signed-in account reaches no athlete data', async () => {
  await assertFails(as('cmStranger').doc('users/cmAthlete').get());
  await assertFails(as('cmStranger').doc('users/cmAthlete/workouts/2026-08-10').get());
  await assertFails(as('cmStranger').doc('planned_blocks/cmAthlete').get());
  await assertFails(as('cmStranger').doc('coachAnalytics/cmAthlete').get());
});

test('rules: LEGACY seeded relationships authorise ONLY with an entitlement', async () => {
  // cmCoachSeeded has the seed but no entitlement — denied (corrective pass).
  await assertFails(as('cmCoachSeeded').doc('users/cmAthleteSeeded').get());
  await assertFails(
    as('cmCoachSeeded').doc('users/cmAthleteSeeded/workouts/2026-08-10').get());

  // cmCoachEntSeeded has the same shape PLUS an active entitlement — allowed.
  await assertSucceeds(as('cmCoachEntSeeded').doc('users/cmEntSeededAthlete').get());
  await assertSucceeds(
    as('cmCoachEntSeeded').doc('users/cmEntSeededAthlete/workouts/2026-08-10').get());
});

// ══════════════════════════════════════════════════════════════════════════
// Application privacy
// ══════════════════════════════════════════════════════════════════════════

test('rules: an application is readable only by the applicant and super admin', async () => {
  await assertSucceeds(as('cmApplicant').doc('coachApplications/cmApplicant').get());
  await assertSucceeds(as(SUPER).doc('coachApplications/cmApplicant').get());

  // No other user — coach or otherwise — may read it.
  await assertFails(as('cmStranger').doc('coachApplications/cmApplicant').get());
  await assertFails(as('cmCoachActive').doc('coachApplications/cmApplicant').get());
  await assertFails(anon().doc('coachApplications/cmApplicant').get());
});

test('rules: applications cannot be created or edited from a client', async () => {
  // Not even by the applicant: submission goes through the callable, so a
  // client can never self-approve.
  await assertFails(as('cmApplicant').doc('coachApplications/cmApplicant')
    .set({ status: 'approved' }, { merge: true }));
  await assertFails(as('cmStranger').doc('coachApplications/cmStranger')
    .set({ uid: 'cmStranger', status: 'approved' }));
  await assertFails(as(SUPER).doc('coachApplications/cmApplicant')
    .set({ status: 'approved' }, { merge: true }));
  await assertFails(as('cmApplicant').doc('coachApplications/cmApplicant').delete());
});

// ══════════════════════════════════════════════════════════════════════════
// Forgery denial
// ══════════════════════════════════════════════════════════════════════════

test('rules: an account cannot forge itself an entitlement', async () => {
  await assertFails(as('cmStranger').doc('accountEntitlements/cmStranger')
    .set({ coach: { state: 'active', source: 'manual_review' } }));
  // Nor upgrade an existing one.
  await assertFails(as('cmCoachSuspended').doc('accountEntitlements/cmCoachSuspended')
    .set({ coach: { state: 'active' } }, { merge: true }));
  // Nor grant one to somebody else.
  await assertFails(as('cmStranger').doc('accountEntitlements/cmCoachActive')
    .set({ coach: { state: 'revoked' } }, { merge: true }));
  // Not even the super admin writes these from a client.
  await assertFails(as(SUPER).doc('accountEntitlements/cmStranger')
    .set({ coach: { state: 'active' } }));
});

test('rules: an entitlement is readable by its owner and super admin only', async () => {
  await assertSucceeds(as('cmCoachActive').doc('accountEntitlements/cmCoachActive').get());
  await assertSucceeds(as(SUPER).doc('accountEntitlements/cmCoachActive').get());
  await assertFails(as('cmStranger').doc('accountEntitlements/cmCoachActive').get());
  await assertFails(as('cmCoachPending').doc('accountEntitlements/cmCoachActive').get());
});

test('rules: an account cannot fabricate an active relationship', async () => {
  await assertFails(as('cmStranger').doc(link('cmStranger', 'cmAthlete')).set({
    coachUid: 'cmStranger', athleteUid: 'cmAthlete', status: 'active',
  }));
  // A coach cannot self-accept their own pending invitation.
  await assertFails(as('cmCoachPending').doc(link('cmCoachPending', 'cmAthletePending'))
    .set({ status: 'active' }, { merge: true }));
  // An athlete cannot flip a link either — it goes through the callable.
  await assertFails(as('cmAthletePending').doc(link('cmCoachPending', 'cmAthletePending'))
    .set({ status: 'active' }, { merge: true }));
  // Nor delete one to escape an audit trail.
  await assertFails(as('cmCoachActive').doc(link('cmCoachActive', 'cmAthlete')).delete());
});

test('rules: a relationship is readable only by its two parties and super admin', async () => {
  await assertSucceeds(as('cmCoachActive').doc(link('cmCoachActive', 'cmAthlete')).get());
  await assertSucceeds(as('cmAthlete').doc(link('cmCoachActive', 'cmAthlete')).get());
  await assertSucceeds(as(SUPER).doc(link('cmCoachActive', 'cmAthlete')).get());
  await assertFails(as('cmStranger').doc(link('cmCoachActive', 'cmAthlete')).get());
  await assertFails(as('cmCoachPending').doc(link('cmCoachActive', 'cmAthlete')).get());
  await assertFails(anon().doc(link('cmCoachActive', 'cmAthlete')).get());
});

test('rules: coach profiles are invitation-scoped, not a public directory', async () => {
  // The coach themselves and super admin.
  await assertSucceeds(as('cmCoachActive').doc('coachProfiles/cmCoachActive').get());
  await assertSucceeds(as(SUPER).doc('coachProfiles/cmCoachActive').get());
  // An athlete WITH a link may identify their coach — including a pending one,
  // which is the whole point of the invitation card.
  await assertSucceeds(as('cmAthlete').doc('coachProfiles/cmCoachActive').get());
  await assertSucceeds(as('cmAthletePending').doc('coachProfiles/cmCoachPending').get());
  // An unrelated account may not enumerate coaches.
  await assertFails(as('cmStranger').doc('coachProfiles/cmCoachActive').get());
  await assertFails(as('cmAthlete').doc('coachProfiles/cmCoachPending').get());
  // And nobody writes them from a client.
  await assertFails(as('cmCoachActive').doc('coachProfiles/cmCoachActive')
    .set({ displayName: 'Spoofed' }, { merge: true }));
});

test('rules: the audit log is super-admin read-only and client-unwritable', async () => {
  await assertSucceeds(as(SUPER).doc('coachAdminAudit/entry1').get());
  await assertFails(as('cmCoachActive').doc('coachAdminAudit/entry1').get());
  await assertFails(as('cmStranger').doc('coachAdminAudit/entry1').get());
  await assertFails(as(SUPER).doc('coachAdminAudit/forged')
    .set({ actorUid: SUPER, action: 'x' }));
  await assertFails(as('cmStranger').doc('coachAdminAudit/forged')
    .set({ actorUid: SUPER, action: 'x' }));
});

// ══════════════════════════════════════════════════════════════════════════
// Coach Mode is not a bypass for social, DMs or media
// ══════════════════════════════════════════════════════════════════════════

test('rules: an active coach gets NO social, media or DM access from Coach Mode', async () => {
  // Post of their own athlete — social visibility only, coach is not social.
  await assertFails(as('cmCoachActive').doc('posts/cmPost').get());
  // Lift video metadata is social-gated too.
  await assertFails(as('cmCoachActive').doc('users/cmAthlete/liftVideos/v1').get());
  await assertFails(as('cmCoachActive').doc('users/cmAthlete/liftVideos/v2')
    .set({ url: 'forged' }));
  // DMs require a confirmed buddy relationship, which coaching does not create.
  const convId = `${'cmAthlete'.padEnd(28, 'z')}_${'cmCoachActive'.padEnd(28, 'z')}`;
  await assertFails(as('cmCoachActive').doc(`conversations/${convId}`).get());
  await assertFails(as('cmCoachActive').doc(`conversations/${convId}/messages/m1`)
    .set({ text: 'hi' }));
});

test('rules: a coach cannot edit their athlete\'s identity document', async () => {
  // Read is allowed (training access), write is not.
  await assertSucceeds(as('cmCoachActive').doc('users/cmAthlete').get());
  await assertFails(as('cmCoachActive').doc('users/cmAthlete')
    .set({ email: 'hijacked@x.com' }, { merge: true }));
});

// ══════════════════════════════════════════════════════════════════════════
// Super admin
// ══════════════════════════════════════════════════════════════════════════

test('rules: super admin retains every intended access path', async () => {
  await assertSucceeds(as(SUPER).doc('users/cmAthlete').get());
  await assertSucceeds(as(SUPER).doc('users/cmAthlete/workouts/2026-08-10').get());
  await assertSucceeds(as(SUPER).doc('planned_blocks/cmAthlete').get());
  await assertSucceeds(as(SUPER).doc('coachAnalytics/cmAthlete').get());
  await assertSucceeds(as(SUPER).doc('coachApplications/cmApplicant').get());
  await assertSucceeds(as(SUPER).doc('accountEntitlements/cmCoachSuspended').get());
  await assertSucceeds(as(SUPER).doc(link('cmCoachActive', 'cmAthlete')).get());
  await assertSucceeds(as(SUPER).doc('coachAdminAudit/entry1').get());
  await assertSucceeds(as(SUPER).doc('coachProfiles/cmCoachActive').get());
  // Reaches an athlete with no assignment document of any kind.
  await assertSucceeds(as(SUPER).doc('users/cmStrangerAthlete').get());
});

test('rules: super admin access does not depend on an entitlement document', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    // Even an explicitly revoked entitlement on the super admin uid must not
    // reduce their access — super admin is the hard-coded constant.
    await ctx.firestore().doc(`accountEntitlements/${SUPER}`)
      .set({ coach: { state: 'revoked' } });
  });
  await assertSucceeds(as(SUPER).doc('users/cmAthlete').get());
  await assertSucceeds(as(SUPER).doc('coachAssignments/cmCoachSeeded').get());
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc(`accountEntitlements/${SUPER}`).delete();
  });
});

test('rules: logged-out users see nothing', async () => {
  await assertFails(anon().doc('users/cmAthlete').get());
  await assertFails(anon().doc('accountEntitlements/cmCoachActive').get());
  await assertFails(anon().doc('coachApplications/cmApplicant').get());
  await assertFails(anon().doc('coachProfiles/cmCoachActive').get());
  await assertFails(anon().doc('coachAdminAudit/entry1').get());
});

// ══════════════════════════════════════════════════════════════════════════
// Athlete control
// ══════════════════════════════════════════════════════════════════════════

test('rules: an athlete can always read their own data and their own links', async () => {
  await assertSucceeds(as('cmAthlete').doc('users/cmAthlete').get());
  await assertSucceeds(as('cmAthlete').doc('users/cmAthlete/workouts/2026-08-10').get());
  await assertSucceeds(as('cmAthlete').doc(link('cmCoachActive', 'cmAthlete')).get());
  await assertSucceeds(as('cmAthletePending').doc(link('cmCoachPending', 'cmAthletePending')).get());
});

test('rules: an athlete cannot read another athlete\'s links', async () => {
  await assertFails(as('cmAthlete').doc(link('cmCoachPending', 'cmAthletePending')).get());
  await assertFails(as('cmAthletePending').doc(link('cmCoachActive', 'cmAthlete')).get());
});

// Sanity: the constant under test is the one the whole app uses.
test('rules: the hard-coded super admin uid is unchanged', () => {
  const rules = fs.readFileSync(
    path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8');
  assert.ok(rules.includes(`request.auth.uid == "${SUPER}"`),
    'firestore.rules must keep the single hard-coded super-admin uid');
  const model = require('../coach/coach_mode_model');
  assert.equal(model.SUPER_ADMIN_UID, SUPER);
});

// ══════════════════════════════════════════════════════════════════════════
// CORRECTIVE PASS — active entitlement mandatory for EVERY source
// ══════════════════════════════════════════════════════════════════════════

test('rules: a LEGACY SEEDED assignment alone (no entitlement) DENIES', async () => {
  // cmCoachSeeded has a seeded roster but no accountEntitlements document.
  await assertFails(as('cmCoachSeeded').doc('users/cmAthleteSeeded').get());
  await assertFails(
    as('cmCoachSeeded').doc('users/cmAthleteSeeded/workouts/2026-08-10').get());
  await assertFails(as('cmCoachSeeded').doc('coachAnalytics/cmAthleteSeeded').get());
});

test('rules: a LEGACY APPROVED assignment alone (no entitlement) DENIES', async () => {
  await assertFails(as('cmLegacyApprovedNoEnt').doc('users/cmLegacyAthlete').get());
  await assertFails(
    as('cmLegacyApprovedNoEnt').doc('users/cmLegacyAthlete/workouts/2026-08-10').get());
});

test('rules: SUSPENDED entitlement plus SEEDED assignment DENIES', async () => {
  await assertFails(as('cmCoachSuspSeeded').doc('users/cmSuspSeededAthlete').get());
  await assertFails(
    as('cmCoachSuspSeeded').doc('users/cmSuspSeededAthlete/workouts/2026-08-10').get());
});

test('rules: REVOKED entitlement plus LEGACY APPROVED assignment DENIES', async () => {
  await assertFails(as('cmCoachRevApproved').doc('users/cmRevApprovedAthlete').get());
  await assertFails(
    as('cmCoachRevApproved').doc('users/cmRevApprovedAthlete/workouts/2026-08-10').get());
});

test('rules: an ACTIVE entitlement plus a legacy source authorises', async () => {
  // The intentionally documented compatibility behaviour.
  await assertSucceeds(as('cmCoachEntSeeded').doc('users/cmEntSeededAthlete').get());
  await assertSucceeds(
    as('cmCoachEntSeeded').doc('users/cmEntSeededAthlete/workouts/2026-08-10').get());
  await assertSucceeds(as('cmCoachEntApproved').doc('users/cmEntApprovedAthlete').get());
});

test('rules: a TERMINATED link overrides a stale legacy approval', async () => {
  // Active entitlement + legacy approved entry, but the canonical link says
  // the coach released the athlete. The newer explicit decision wins.
  await assertFails(as('cmCoachTerminated').doc('users/cmTerminatedAthlete').get());
  await assertFails(
    as('cmCoachTerminated').doc('users/cmTerminatedAthlete/workouts/2026-08-10').get());
});

test('rules: a terminated link does NOT override a super-admin seed', async () => {
  await assertSucceeds(as('cmCoachTermSeeded').doc('users/cmTermSeededAthlete').get());
});

// ══════════════════════════════════════════════════════════════════════════
// CORRECTIVE PASS — fail-closed users subcollections
// ══════════════════════════════════════════════════════════════════════════

test('rules: an assigned coach CAN reach every training subcollection', async () => {
  const c = as('cmCoachActive');
  for (const sub of ['workouts', 'weights', 'block_planner', 'block_data',
    'plannedExerciseDetails', 'templates', 'customExercises']) {
    await assertSucceeds(c.doc(`users/cmAthlete/${sub}/d1`).get());
    await assertSucceeds(c.doc(`users/cmAthlete/${sub}/d1`).set({ x: 1 }));
  }
});

test('rules: an assigned coach CAN reach canonical nested planned blocks', async () => {
  const c = as('cmCoachActive');
  await assertSucceeds(c.doc('users/cmAthlete/planned_blocks/b1').get());
  await assertSucceeds(c.doc('users/cmAthlete/planned_blocks/b1').set({ n: 1 }));
  // Deeply nested documents under a block are reachable too.
  await assertSucceeds(
    c.doc('users/cmAthlete/planned_blocks/b1/weeks/w1').get());
  await assertSucceeds(
    c.doc('users/cmAthlete/planned_blocks/b1/weeks/w1').set({ n: 1 }));
});

test('rules: an assigned coach CANNOT read or write profile/membership', async () => {
  const c = as('cmCoachActive');
  await assertFails(c.doc('users/cmAthlete/profile/membership').get());
  await assertFails(
    c.doc('users/cmAthlete/profile/membership').set({ active: true }));
  await assertFails(
    c.doc('users/cmAthlete/profile/membership')
      .set({ active: true }, { merge: true }));
  // The athlete keeps full access to their own membership document.
  await assertSucceeds(as('cmAthlete').doc('users/cmAthlete/profile/membership').get());
});

test('rules: an assigned coach CANNOT read athlete buddyInvites', async () => {
  const c = as('cmCoachActive');
  // Coach Mode grants no visibility into the athlete's social invitations.
  await assertFails(c.doc('users/cmAthlete/buddyInvites/someSender').get());
  // Nor may a coach forge or tamper with an invite from someone else.
  await assertFails(c.doc('users/cmAthlete/buddyInvites/someSender')
    .set({ status: 'accepted' }, { merge: true }));
  await assertFails(c.doc('users/cmAthlete/buddyInvites/otherPerson')
    .set({ fromUid: 'otherPerson', buddyUid: 'cmAthlete' }));

  // NOTE: a coach sending their OWN buddy invite is ordinary social behaviour
  // available to every signed-in account (the buddyInvites block allows the
  // sender to create their own invite). That is not a Coach Mode privilege,
  // and it is unchanged by this work.

  // The athlete still reads their own invites.
  await assertSucceeds(as('cmAthlete').doc('users/cmAthlete/buddyInvites/someSender').get());
});

test('rules: an assigned coach CANNOT access or write liftVideos', async () => {
  const c = as('cmCoachActive');
  await assertFails(c.doc('users/cmAthlete/liftVideos/v1').get());
  await assertFails(c.doc('users/cmAthlete/liftVideos/v1').set({ url: 'x' }));
  await assertFails(c.doc('users/cmAthlete/liftVideos/v2').set({ url: 'new' }));
  // The owner still controls their own media metadata.
  await assertSucceeds(as('cmAthlete').doc('users/cmAthlete/liftVideos/v1').get());
});

test('rules: an UNKNOWN future users subcollection fails closed for a coach', async () => {
  const c = as('cmCoachActive');
  for (const sub of ['someFutureFeature', 'billing', 'privateNotes', 're_daily',
    're_monthly', 're_cache', 'onboarding', 'posts']) {
    await assertFails(c.doc(`users/cmAthlete/${sub}/d1`).get(),
      `coach must not read users/cmAthlete/${sub}`);
    await assertFails(c.doc(`users/cmAthlete/${sub}/d1`).set({ x: 1 }),
      `coach must not write users/cmAthlete/${sub}`);
  }
  // But the athlete keeps full access to all of their own data.
  const a = as('cmAthlete');
  await assertSucceeds(a.doc('users/cmAthlete/someFutureFeature/d1').set({ x: 1 }));
  await assertSucceeds(a.doc('users/cmAthlete/re_daily/d1').set({ x: 1 }));
});

test('rules: super admin still reaches every users subcollection', async () => {
  const s = as(SUPER);
  await assertSucceeds(s.doc('users/cmAthlete/profile/membership').get());
  await assertSucceeds(s.doc('users/cmAthlete/someFutureFeature/d1').get());
  await assertSucceeds(s.doc('users/cmAthlete/workouts/2026-08-10').get());
  await assertSucceeds(s.doc('users/cmAthlete/planned_blocks/b1').get());
});

test('rules: legacy top-level planned_blocks stays entitlement-gated', async () => {
  // The legacy compatibility hierarchy is still readable by an authorised
  // coach, and still denied to a suspended one. No active read/write path to
  // planned_blocks/{uid}/blocks/... is reintroduced here.
  await assertSucceeds(as('cmCoachActive').doc('planned_blocks/cmAthlete').get());
  await assertFails(as('cmCoachSuspended').doc('planned_blocks/cmAthleteSusp').get());
  await assertFails(as('cmCoachSeeded').doc('planned_blocks/cmAthleteSeeded').get());
});
