'use strict';

// Emulator integration tests for the Coach Mode callables.
//
// These exercise the REAL handlers (via onCall's .run()) against the Firestore
// emulator with Admin SDK privileges, exactly as production Cloud Functions
// run. They pin the authorization decisions, the state machines, idempotency,
// and the atomicity of competing responses.
//
//   npm run test:rules
//
// The Auth emulator is not required: identityFor()/uidForEmail() fall back to
// the users collection, and syncCoachClaim() failures are logged rather than
// thrown (the entitlement document remains authoritative). Claim MERGING
// itself is covered by test/coach_mode_model.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || 'rules-test';
process.env.FUNCTIONS_EMULATOR = 'true';

const admin = require('firebase-admin');
const M = require('../coach/coach_mode_model');
const authz = require('../coach/authz');
const cm = require('../coach/coach_mode');

const db = admin.firestore();

assert.ok(process.env.FIRESTORE_EMULATOR_HOST,
  'coach_mode.spec.js must run under firebase emulators:exec');

const SUPER = M.SUPER_ADMIN_UID;

let seq = 0;
function freshUid(prefix) {
  seq += 1;
  return `${prefix}_${Date.now()}_${seq}`;
}

/** Registers an account so uidForEmail() can resolve it. */
async function makeAccount(prefix) {
  const uid = freshUid(prefix);
  const email = `${uid.toLowerCase()}@example.com`;
  await db.doc(`users/${uid}`).set({ email, displayName: prefix, username: prefix });
  return { uid, email };
}

/** Calls a v2 callable handler as an authenticated user. */
function call(fn, uid, data) {
  return fn.run({
    auth: uid ? { uid, token: { uid } } : undefined,
    data: data || {},
    rawRequest: { headers: {} },
  });
}

/**
 * Asserts the call was rejected. `code` may be a single code or a list of
 * acceptable codes — some denials surface as not-found because the caller is
 * not a party to the link and therefore addresses a different (nonexistent)
 * deterministic document id. Either way the request is refused and no state
 * changes, which the callers below assert explicitly.
 */
async function expectHttpsError(promise, code) {
  const codes = code == null ? null : (Array.isArray(code) ? code : [code]);
  try {
    await promise;
  } catch (err) {
    assert.ok(err && err.code, 'expected an HttpsError, got: ' + err);
    if (codes) {
      assert.ok(codes.includes(err.code),
        `expected one of ${codes.join('/')}, got ${err.code}: ${err.message}`);
    }
    return err;
  }
  assert.fail('expected the call to be rejected, but it resolved');
}

/** Grants an active coach entitlement the way the super admin would. */
async function grantCoach(uid) {
  await call(cm.coachModeGrantCoach, SUPER, { targetUid: uid, reason: 'test' });
}

async function entitlementState(uid) {
  const s = await db.collection(M.COL_ENTITLEMENTS).doc(uid).get();
  const d = s.exists ? (s.data() || {}) : {};
  return d.coach ? d.coach.state : null;
}

async function linkStatus(coachUid, athleteUid) {
  const s = await db.collection(M.COL_LINKS).doc(M.linkId(coachUid, athleteUid)).get();
  return s.exists ? (s.data() || {}).status : null;
}

const VALID_APPLICATION = Object.freeze({
  athleteCountBand: '1-5',
  experienceBand: '1-3',
  coachingFocus: ['powerlifting'],
  competitionExperience: ['none'],
  qualifications: 'Level 1',
  competitionDetails: '',
  intendedUse: 'Programming and reviewing check-ins for my athletes.',
  profileUrl: '',
  agreesToAthleteConsent: true,
});

// ══════════════════════════════════════════════════════════════════════════
// Authentication
// ══════════════════════════════════════════════════════════════════════════

test('every callable requires authentication', async () => {
  await expectHttpsError(
    call(cm.coachModeSubmitApplication, null, VALID_APPLICATION), 'unauthenticated');
  await expectHttpsError(call(cm.coachModeWithdrawApplication, null), 'unauthenticated');
  await expectHttpsError(call(cm.coachModeInviteAthlete, null, { athleteEmail: 'a@b.co' }), 'unauthenticated');
  await expectHttpsError(call(cm.coachModeReviewApplication, null, {}), 'unauthenticated');
  await expectHttpsError(call(cm.coachModeGrantCoach, null, {}), 'unauthenticated');
  await expectHttpsError(call(cm.coachModeSetCoachState, null, {}), 'unauthenticated');
  await expectHttpsError(call(cm.coachModeAdminLookupAccount, null, {}), 'unauthenticated');
});

// ══════════════════════════════════════════════════════════════════════════
// Applications
// ══════════════════════════════════════════════════════════════════════════

test('application: submit validates and stores only the whitelisted answers', async () => {
  const a = await makeAccount('applicant');
  const res = await call(cm.coachModeSubmitApplication, a.uid,
    Object.assign({}, VALID_APPLICATION, { isCoach: true, status: 'approved' }));
  assert.equal(res.status, 'submitted');

  const doc = await db.collection(M.COL_APPLICATIONS).doc(a.uid).get();
  const d = doc.data();
  assert.equal(d.status, 'submitted', 'client-supplied status must be ignored');
  assert.equal(d.uid, a.uid);
  assert.equal(d.answers.isCoach, undefined, 'unknown keys must not be persisted');
  assert.equal(d.submissionCount, 1);
  // Submitting an application must NOT create an entitlement.
  assert.equal(await entitlementState(a.uid), null);
});

test('application: server-side validation rejects bad payloads', async () => {
  const a = await makeAccount('applicantBad');
  const bad = (o) => call(cm.coachModeSubmitApplication, a.uid,
    Object.assign({}, VALID_APPLICATION, o));

  await expectHttpsError(bad({ athleteCountBand: '99+' }), 'invalid-argument');
  await expectHttpsError(bad({ coachingFocus: [] }), 'invalid-argument');
  await expectHttpsError(bad({ intendedUse: 'short' }), 'invalid-argument');
  await expectHttpsError(
    bad({ intendedUse: 'x'.repeat(M.LIMITS.intendedUse + 1) }), 'invalid-argument');
  await expectHttpsError(bad({ agreesToAthleteConsent: false }), 'invalid-argument');
  await expectHttpsError(
    bad({ competitionExperience: ['none', 'powerlifting'] }), 'invalid-argument');

  // Nothing was written by any of the rejected attempts.
  const doc = await db.collection(M.COL_APPLICATIONS).doc(a.uid).get();
  assert.equal(doc.exists, false);
});

test('application: a rejected error names the offending field', async () => {
  const a = await makeAccount('applicantField');
  const err = await expectHttpsError(
    call(cm.coachModeSubmitApplication, a.uid,
      Object.assign({}, VALID_APPLICATION, { experienceBand: 'nope' })),
    'invalid-argument');
  assert.equal(err.details.field, 'experienceBand');
});

test('application: cannot submit twice while one is awaiting review', async () => {
  const a = await makeAccount('applicantDup');
  await call(cm.coachModeSubmitApplication, a.uid, VALID_APPLICATION);
  await expectHttpsError(
    call(cm.coachModeSubmitApplication, a.uid, VALID_APPLICATION), 'failed-precondition');
});

test('application: withdraw, then re-apply', async () => {
  const a = await makeAccount('applicantWithdraw');
  await call(cm.coachModeSubmitApplication, a.uid, VALID_APPLICATION);
  await call(cm.coachModeWithdrawApplication, a.uid);

  let doc = await db.collection(M.COL_APPLICATIONS).doc(a.uid).get();
  assert.equal(doc.data().status, 'withdrawn');

  // Withdrawing again is idempotent, not an error.
  await call(cm.coachModeWithdrawApplication, a.uid);

  await call(cm.coachModeSubmitApplication, a.uid, VALID_APPLICATION);
  doc = await db.collection(M.COL_APPLICATIONS).doc(a.uid).get();
  assert.equal(doc.data().status, 'submitted');
  assert.equal(doc.data().submissionCount, 2);
});

test('application: withdraw with no application is not-found', async () => {
  const a = await makeAccount('applicantNone');
  await expectHttpsError(call(cm.coachModeWithdrawApplication, a.uid), 'not-found');
});

test('application: only the super admin may review', async () => {
  const a = await makeAccount('applicantReview');
  const other = await makeAccount('nosyUser');
  await call(cm.coachModeSubmitApplication, a.uid, VALID_APPLICATION);

  // An ordinary user cannot review.
  await expectHttpsError(
    call(cm.coachModeReviewApplication, other.uid,
      { applicantUid: a.uid, action: 'approve' }), 'permission-denied');

  // Nor can an approved coach — Coach Mode is not admin.
  await grantCoach(other.uid);
  await expectHttpsError(
    call(cm.coachModeReviewApplication, other.uid,
      { applicantUid: a.uid, action: 'approve' }), 'permission-denied');

  // Not even the applicant can approve their own application.
  await expectHttpsError(
    call(cm.coachModeReviewApplication, a.uid,
      { applicantUid: a.uid, action: 'approve' }), 'permission-denied');

  assert.equal(await entitlementState(a.uid), null);
});

test('application: super-admin approval grants the entitlement and is idempotent', async () => {
  const a = await makeAccount('applicantApprove');
  await call(cm.coachModeSubmitApplication, a.uid, VALID_APPLICATION);

  await call(cm.coachModeReviewApplication, SUPER,
    { applicantUid: a.uid, action: 'approve', reason: 'looks good' });

  const doc = await db.collection(M.COL_APPLICATIONS).doc(a.uid).get();
  assert.equal(doc.data().status, 'approved');
  assert.equal(doc.data().reviewedBy, SUPER);
  assert.equal(await entitlementState(a.uid), 'active');

  const ent = await db.collection(M.COL_ENTITLEMENTS).doc(a.uid).get();
  assert.equal(ent.data().coach.source, 'manual_review');
  assert.equal(ent.data().coach.approvedBy, SUPER);

  // The invitation-safe profile exists and holds no application answers.
  const profile = await db.collection(M.COL_PROFILES).doc(a.uid).get();
  assert.equal(profile.exists, true);
  assert.equal(profile.data().intendedUse, undefined);
  assert.equal(profile.data().athleteCountBand, undefined);

  // Re-approving the same application changes nothing and does not throw.
  await call(cm.coachModeReviewApplication, SUPER,
    { applicantUid: a.uid, action: 'approve' });
  assert.equal(await entitlementState(a.uid), 'active');

  // An approved application is terminal.
  await expectHttpsError(
    call(cm.coachModeReviewApplication, SUPER,
      { applicantUid: a.uid, action: 'decline', reason: 'changed mind' }),
    'failed-precondition');
});

test('application: decline and request-more-information transitions', async () => {
  const a = await makeAccount('applicantInfo');
  await call(cm.coachModeSubmitApplication, a.uid, VALID_APPLICATION);

  await call(cm.coachModeReviewApplication, SUPER,
    { applicantUid: a.uid, action: 'request_info', reason: 'Which gym?' });
  let doc = await db.collection(M.COL_APPLICATIONS).doc(a.uid).get();
  assert.equal(doc.data().status, 'more_info_requested');
  assert.equal(doc.data().infoRequest, 'Which gym?');
  assert.equal(await entitlementState(a.uid), null, 'no entitlement yet');

  // Resubmitting answers the request and clears it.
  await call(cm.coachModeSubmitApplication, a.uid, VALID_APPLICATION);
  doc = await db.collection(M.COL_APPLICATIONS).doc(a.uid).get();
  assert.equal(doc.data().status, 'submitted');
  assert.equal(doc.data().infoRequest, null);

  await call(cm.coachModeReviewApplication, SUPER,
    { applicantUid: a.uid, action: 'decline', reason: 'Not this time' });
  doc = await db.collection(M.COL_APPLICATIONS).doc(a.uid).get();
  assert.equal(doc.data().status, 'declined');
  assert.equal(doc.data().decisionReason, 'Not this time');
  assert.equal(await entitlementState(a.uid), null, 'a decline grants nothing');

  // A declined applicant may re-apply.
  await call(cm.coachModeSubmitApplication, a.uid, VALID_APPLICATION);
  doc = await db.collection(M.COL_APPLICATIONS).doc(a.uid).get();
  assert.equal(doc.data().status, 'submitted');
});

test('application: review of a missing application is not-found', async () => {
  await expectHttpsError(
    call(cm.coachModeReviewApplication, SUPER,
      { applicantUid: 'doesNotExist', action: 'approve' }), 'not-found');
});

test('application: review action is enum-validated', async () => {
  const a = await makeAccount('applicantEnum');
  await call(cm.coachModeSubmitApplication, a.uid, VALID_APPLICATION);
  await expectHttpsError(
    call(cm.coachModeReviewApplication, SUPER,
      { applicantUid: a.uid, action: 'delete_everything' }), 'invalid-argument');
});

// ══════════════════════════════════════════════════════════════════════════
// Entitlements
// ══════════════════════════════════════════════════════════════════════════

test('entitlement: super admin grants Coach Mode directly with no application', async () => {
  const a = await makeAccount('directGrant');
  const res = await call(cm.coachModeGrantCoach, SUPER,
    { targetUid: a.uid, reason: 'known coach' });
  assert.equal(res.state, 'active');
  assert.equal(await entitlementState(a.uid), 'active');

  const ent = await db.collection(M.COL_ENTITLEMENTS).doc(a.uid).get();
  assert.equal(ent.data().coach.source, 'super_admin_grant');
  assert.equal(ent.data().coach.grantedBy, SUPER);

  // No application document is fabricated by a direct grant.
  const app = await db.collection(M.COL_APPLICATIONS).doc(a.uid).get();
  assert.equal(app.exists, false);

  // Idempotent.
  const again = await call(cm.coachModeGrantCoach, SUPER, { targetUid: a.uid });
  assert.equal(again.changed, false);
  assert.equal(await entitlementState(a.uid), 'active');
});

test('entitlement: direct grant can resolve the account by exact email', async () => {
  const a = await makeAccount('grantByEmail');
  const res = await call(cm.coachModeGrantCoach, SUPER, { email: a.email.toUpperCase() });
  assert.equal(res.targetUid, a.uid);
  assert.equal(await entitlementState(a.uid), 'active');
});

test('entitlement: only the super admin may grant, suspend, revoke or restore', async () => {
  const coach = await makeAccount('coachActor');
  const victim = await makeAccount('victim');
  await grantCoach(coach.uid);
  await grantCoach(victim.uid);

  // An active coach has no admin powers whatsoever.
  await expectHttpsError(
    call(cm.coachModeGrantCoach, coach.uid, { targetUid: victim.uid }), 'permission-denied');
  await expectHttpsError(
    call(cm.coachModeSetCoachState, coach.uid,
      { targetUid: victim.uid, action: 'revoke', reason: 'x' }), 'permission-denied');
  await expectHttpsError(
    call(cm.coachModeAdminLookupAccount, coach.uid, { email: victim.email }),
    'permission-denied');

  // Nor can an account act on itself.
  await expectHttpsError(
    call(cm.coachModeGrantCoach, victim.uid, { targetUid: victim.uid }), 'permission-denied');

  assert.equal(await entitlementState(victim.uid), 'active');
});

test('entitlement: suspend, restore and revoke drive the state machine', async () => {
  const a = await makeAccount('stateMachine');
  await grantCoach(a.uid);

  await call(cm.coachModeSetCoachState, SUPER,
    { targetUid: a.uid, action: 'suspend', reason: 'under review' });
  assert.equal(await entitlementState(a.uid), 'suspended');
  let ent = await db.collection(M.COL_ENTITLEMENTS).doc(a.uid).get();
  assert.equal(ent.data().coach.suspensionReason, 'under review');
  assert.equal(ent.data().coach.suspendedBy, SUPER);

  await call(cm.coachModeSetCoachState, SUPER, { targetUid: a.uid, action: 'restore' });
  assert.equal(await entitlementState(a.uid), 'active');
  ent = await db.collection(M.COL_ENTITLEMENTS).doc(a.uid).get();
  assert.equal(ent.data().coach.suspensionReason, null,
    'a restored coach must not keep a stale suspension reason');

  await call(cm.coachModeSetCoachState, SUPER,
    { targetUid: a.uid, action: 'revoke', reason: 'policy breach' });
  assert.equal(await entitlementState(a.uid), 'revoked');

  // Revoking twice is idempotent.
  const again = await call(cm.coachModeSetCoachState, SUPER,
    { targetUid: a.uid, action: 'revoke', reason: 'policy breach' });
  assert.equal(again.changed, false);
});

test('entitlement: super admin access is never an entitlement and cannot be changed', async () => {
  await expectHttpsError(
    call(cm.coachModeGrantCoach, SUPER, { targetUid: SUPER }), 'failed-precondition');
  await expectHttpsError(
    call(cm.coachModeSetCoachState, SUPER,
      { targetUid: SUPER, action: 'revoke', reason: 'x' }), 'failed-precondition');

  // Super admin is still authorised for any athlete, with no documents at all.
  assert.equal(await authz.isCoachFor(db, SUPER, 'anyAthleteAtAll'), true);
  assert.equal(await authz.hasActiveCoachEntitlement(db, SUPER), true);
});

test('entitlement: admin account lookup is super-admin only and reports state', async () => {
  const a = await makeAccount('lookupTarget');
  await grantCoach(a.uid);
  const res = await call(cm.coachModeAdminLookupAccount, SUPER, { email: a.email });
  assert.equal(res.found, true);
  assert.equal(res.uid, a.uid);
  assert.equal(res.coachState, 'active');

  const missing = await call(cm.coachModeAdminLookupAccount, SUPER,
    { email: 'nobody-at-all@example.com' });
  assert.equal(missing.found, false);
});

// ══════════════════════════════════════════════════════════════════════════
// Invitations and relationships
// ══════════════════════════════════════════════════════════════════════════

test('invite: an account without an active entitlement cannot invite', async () => {
  const notCoach = await makeAccount('notCoach');
  const athlete = await makeAccount('athlete1');
  await expectHttpsError(
    call(cm.coachModeInviteAthlete, notCoach.uid, { athleteEmail: athlete.email }),
    'permission-denied');
  assert.equal(await linkStatus(notCoach.uid, athlete.uid), null);
});

test('invite: a suspended or revoked coach cannot invite', async () => {
  const coach = await makeAccount('coachSusp');
  const athlete = await makeAccount('athleteSusp');
  await grantCoach(coach.uid);

  await call(cm.coachModeSetCoachState, SUPER,
    { targetUid: coach.uid, action: 'suspend', reason: 'hold' });
  await expectHttpsError(
    call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email }),
    'permission-denied');

  await call(cm.coachModeSetCoachState, SUPER,
    { targetUid: coach.uid, action: 'revoke', reason: 'gone' });
  await expectHttpsError(
    call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email }),
    'permission-denied');
});

test('invite: self-invite is rejected', async () => {
  const coach = await makeAccount('selfInvite');
  await grantCoach(coach.uid);
  await expectHttpsError(
    call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: coach.email }),
    'invalid-argument');
  assert.equal(await linkStatus(coach.uid, coach.uid), null);
});

test('invite: unknown email is not-found and creates nothing', async () => {
  const coach = await makeAccount('coachUnknown');
  await grantCoach(coach.uid);
  await expectHttpsError(
    call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: 'ghost@example.com' }),
    'not-found');
});

test('invite: malformed email is rejected before any lookup', async () => {
  const coach = await makeAccount('coachBadEmail');
  await grantCoach(coach.uid);
  await expectHttpsError(
    call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: 'nope' }),
    'invalid-argument');
});

test('invite: creates a PENDING link that grants no access', async () => {
  const coach = await makeAccount('coachPending');
  const athlete = await makeAccount('athletePending');
  await grantCoach(coach.uid);

  const res = await call(cm.coachModeInviteAthlete, coach.uid,
    { athleteEmail: athlete.email.toUpperCase() });
  assert.equal(res.status, 'pending');
  assert.equal(res.athleteUid, athlete.uid);
  assert.equal(res.linkId, M.linkId(coach.uid, athlete.uid));

  // A pending invitation is NOT authorisation.
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);

  const doc = await db.collection(M.COL_LINKS).doc(res.linkId).get();
  assert.equal(doc.data().coachUid, coach.uid);
  assert.equal(doc.data().athleteUid, athlete.uid);
  assert.equal(doc.data().requestedBy, coach.uid);
  assert.equal(doc.data().respondedAt, null);
});

test('invite: repeating a pending invitation is idempotent, not a duplicate', async () => {
  const coach = await makeAccount('coachIdem');
  const athlete = await makeAccount('athleteIdem');
  await grantCoach(coach.uid);

  const first = await call(cm.coachModeInviteAthlete, coach.uid,
    { athleteEmail: athlete.email });
  assert.equal(first.changed, true);
  const second = await call(cm.coachModeInviteAthlete, coach.uid,
    { athleteEmail: athlete.email });
  assert.equal(second.changed, false);
  assert.equal(await linkStatus(coach.uid, athlete.uid), 'pending');

  const all = await db.collection(M.COL_LINKS)
    .where('coachUid', '==', coach.uid).get();
  assert.equal(all.size, 1, 'exactly one deterministic link document');
});

test('invite: re-inviting an already-active athlete is rejected', async () => {
  const coach = await makeAccount('coachActiveDup');
  const athlete = await makeAccount('athleteActiveDup');
  await grantCoach(coach.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });
  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: coach.uid, action: 'accept' });

  await expectHttpsError(
    call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email }),
    'already-exists');
});

test('relationship: accepting activates access; declining does not', async () => {
  const coach = await makeAccount('coachAccept');
  const a1 = await makeAccount('athleteAccept');
  const a2 = await makeAccount('athleteDecline');
  await grantCoach(coach.uid);

  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: a1.email });
  await call(cm.coachModeRespondToInvite, a1.uid,
    { coachUid: coach.uid, action: 'accept' });
  assert.equal(await linkStatus(coach.uid, a1.uid), 'active');
  assert.equal(await authz.isCoachFor(db, coach.uid, a1.uid), true);

  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: a2.email });
  await call(cm.coachModeRespondToInvite, a2.uid,
    { coachUid: coach.uid, action: 'decline' });
  assert.equal(await linkStatus(coach.uid, a2.uid), 'declined');
  assert.equal(await authz.isCoachFor(db, coach.uid, a2.uid), false);
});

test('relationship: a coach cannot accept on the athlete\'s behalf', async () => {
  const coach = await makeAccount('coachForge');
  const athlete = await makeAccount('athleteForge');
  await grantCoach(coach.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });

  // The responding callable always uses the CALLER as the athlete side, so a
  // coach calling it can only ever address coach__coach — never the athlete's
  // link. The invitation stays pending and grants nothing.
  await expectHttpsError(
    call(cm.coachModeRespondToInvite, coach.uid,
      { coachUid: coach.uid, action: 'accept' }),
    ['permission-denied', 'not-found']);
  assert.equal(await linkStatus(coach.uid, athlete.uid), 'pending');
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);
});

test('relationship: the party check rejects a caller who is not on the link', async () => {
  // Direct test of transitionLink's authorization guard: it validates the
  // caller against the STORED parties, not the request payload, so a future
  // caller that passes both uids cannot drive somebody else's relationship.
  const coach = await makeAccount('partyCoach');
  const athlete = await makeAccount('partyAthlete');
  const impostor = await makeAccount('partyImpostor');
  await grantCoach(coach.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });

  await expectHttpsError(
    cm._internals.transitionLink({
      callerUid: impostor.uid,
      coachUid: coach.uid,
      athleteUid: athlete.uid,
      toStatus: 'active',
      actorRole: 'athlete',
    }), 'permission-denied');

  // And the role check rejects the right actor driving the wrong transition.
  await expectHttpsError(
    cm._internals.transitionLink({
      callerUid: coach.uid,
      coachUid: coach.uid,
      athleteUid: athlete.uid,
      toStatus: 'active',
      actorRole: 'coach',
    }), 'permission-denied');

  assert.equal(await linkStatus(coach.uid, athlete.uid), 'pending');
});

test('relationship: an unrelated third party cannot drive the link', async () => {
  const coach = await makeAccount('coachThird');
  const athlete = await makeAccount('athleteThird');
  const stranger = await makeAccount('stranger');
  await grantCoach(coach.uid);
  await grantCoach(stranger.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });

  // A stranger can only ever address their OWN deterministic link ids, so
  // neither call can touch this relationship.
  await expectHttpsError(
    call(cm.coachModeRespondToInvite, stranger.uid,
      { coachUid: coach.uid, action: 'accept' }),
    ['permission-denied', 'not-found']);
  await expectHttpsError(
    call(cm.coachModeCancelInvite, stranger.uid, { athleteUid: athlete.uid }),
    ['permission-denied', 'not-found']);
  await expectHttpsError(
    call(cm.coachModeReleaseAthlete, stranger.uid, { athleteUid: athlete.uid }),
    ['permission-denied', 'not-found']);
  await expectHttpsError(
    call(cm.coachModeRevokeCoach, stranger.uid, { coachUid: coach.uid }),
    ['permission-denied', 'not-found']);

  assert.equal(await linkStatus(coach.uid, athlete.uid), 'pending');
  assert.equal(await authz.isCoachFor(db, stranger.uid, athlete.uid), false);
});

test('relationship: coach cancels a pending invitation', async () => {
  const coach = await makeAccount('coachCancel');
  const athlete = await makeAccount('athleteCancel');
  await grantCoach(coach.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });

  await call(cm.coachModeCancelInvite, coach.uid, { athleteUid: athlete.uid });
  assert.equal(await linkStatus(coach.uid, athlete.uid), 'cancelled');
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);

  // The athlete can no longer accept a cancelled invitation.
  await expectHttpsError(
    call(cm.coachModeRespondToInvite, athlete.uid,
      { coachUid: coach.uid, action: 'accept' }), 'failed-precondition');
});

test('relationship: athlete revokes an active coach; access ends immediately', async () => {
  const coach = await makeAccount('coachRevoked');
  const athlete = await makeAccount('athleteRevoker');
  await grantCoach(coach.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });
  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: coach.uid, action: 'accept' });
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), true);

  await call(cm.coachModeRevokeCoach, athlete.uid,
    { coachUid: coach.uid, reason: 'moving on' });
  assert.equal(await linkStatus(coach.uid, athlete.uid), 'revoked_by_athlete');
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);
});

test('relationship: coach releases an active athlete; access ends immediately', async () => {
  const coach = await makeAccount('coachRelease');
  const athlete = await makeAccount('athleteReleased');
  await grantCoach(coach.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });
  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: coach.uid, action: 'accept' });

  await call(cm.coachModeReleaseAthlete, coach.uid,
    { athleteUid: athlete.uid, reason: 'season over' });
  assert.equal(await linkStatus(coach.uid, athlete.uid), 'released_by_coach');
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);
});

test('relationship: a terminated relationship can be re-invited and re-accepted', async () => {
  const coach = await makeAccount('coachReinvite');
  const athlete = await makeAccount('athleteReinvite');
  await grantCoach(coach.uid);

  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });
  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: coach.uid, action: 'accept' });
  await call(cm.coachModeRevokeCoach, athlete.uid, { coachUid: coach.uid });
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);

  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });
  assert.equal(await linkStatus(coach.uid, athlete.uid), 'pending');
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false,
    'a re-invitation is still only pending');

  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: coach.uid, action: 'accept' });
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), true);
});

test('relationship: an athlete may have several coaches at once', async () => {
  const c1 = await makeAccount('multiCoach1');
  const c2 = await makeAccount('multiCoach2');
  const athlete = await makeAccount('multiAthlete');
  await grantCoach(c1.uid);
  await grantCoach(c2.uid);

  for (const c of [c1, c2]) {
    await call(cm.coachModeInviteAthlete, c.uid, { athleteEmail: athlete.email });
    await call(cm.coachModeRespondToInvite, athlete.uid,
      { coachUid: c.uid, action: 'accept' });
  }
  assert.equal(await authz.isCoachFor(db, c1.uid, athlete.uid), true);
  assert.equal(await authz.isCoachFor(db, c2.uid, athlete.uid), true);

  // Revoking one leaves the other untouched.
  await call(cm.coachModeRevokeCoach, athlete.uid, { coachUid: c1.uid });
  assert.equal(await authz.isCoachFor(db, c1.uid, athlete.uid), false);
  assert.equal(await authz.isCoachFor(db, c2.uid, athlete.uid), true);
});

test('relationship: competing accept and decline are atomic — exactly one wins', async () => {
  const coach = await makeAccount('coachRace');
  const athlete = await makeAccount('athleteRace');
  await grantCoach(coach.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });

  const results = await Promise.allSettled([
    call(cm.coachModeRespondToInvite, athlete.uid,
      { coachUid: coach.uid, action: 'accept' }),
    call(cm.coachModeRespondToInvite, athlete.uid,
      { coachUid: coach.uid, action: 'decline' }),
  ]);

  const fulfilled = results.filter((r) => r.status === 'fulfilled');
  assert.ok(fulfilled.length >= 1, 'at least one response must succeed');

  // Whatever the interleaving, the stored status is a single legal outcome of
  // the pending state — never something in between.
  const status = await linkStatus(coach.uid, athlete.uid);
  assert.ok(['active', 'declined'].includes(status),
    'unexpected terminal status: ' + status);

  // And authorization agrees with the stored status.
  assert.equal(
    await authz.isCoachFor(db, coach.uid, athlete.uid),
    status === 'active',
  );
});

test('relationship: suspending a coach kills access despite an ACTIVE link', async () => {
  const coach = await makeAccount('coachSuspendedLink');
  const athlete = await makeAccount('athleteSuspendedLink');
  await grantCoach(coach.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });
  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: coach.uid, action: 'accept' });
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), true);

  await call(cm.coachModeSetCoachState, SUPER,
    { targetUid: coach.uid, action: 'suspend', reason: 'hold' });

  // The link is still 'active' — the entitlement is what withdrew access.
  assert.equal(await linkStatus(coach.uid, athlete.uid), 'active');
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);

  // Restoring brings the same relationship back without re-inviting.
  await call(cm.coachModeSetCoachState, SUPER,
    { targetUid: coach.uid, action: 'restore' });
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), true);
});

test('relationship: one coach cannot reach another coach\'s athlete', async () => {
  const c1 = await makeAccount('isolatedCoach1');
  const c2 = await makeAccount('isolatedCoach2');
  const athlete = await makeAccount('isolatedAthlete');
  await grantCoach(c1.uid);
  await grantCoach(c2.uid);
  await call(cm.coachModeInviteAthlete, c1.uid, { athleteEmail: athlete.email });
  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: c1.uid, action: 'accept' });

  assert.equal(await authz.isCoachFor(db, c1.uid, athlete.uid), true);
  assert.equal(await authz.isCoachFor(db, c2.uid, athlete.uid), false);
});

test('invite: the rate limit blocks a burst of invitations', async () => {
  const coach = await makeAccount('coachFlood');
  await grantCoach(coach.uid);

  // Pre-fill the sliding window so the very next invite is over the cap.
  const now = Date.now();
  await db.collection(M.COL_ENTITLEMENTS).doc(coach.uid).set({
    coachInviteRate: {
      recentMs: Array.from({ length: M.INVITE_RATE_MAX }, (_, i) => now - i),
    },
  }, { merge: true });

  const athlete = await makeAccount('athleteFlood');
  await expectHttpsError(
    call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email }),
    'resource-exhausted');
  assert.equal(await linkStatus(coach.uid, athlete.uid), null);
});

// ══════════════════════════════════════════════════════════════════════════
// Legacy compatibility
// ══════════════════════════════════════════════════════════════════════════

test('legacy: a super-admin-seeded assignment authorises WITH an entitlement', async () => {
  const coach = await makeAccount('seededCoach');
  const athlete = await makeAccount('seededAthlete');
  await db.collection('coachAssignments').doc(coach.uid).set({
    athletes: { [athlete.uid]: { email: athlete.email } },
  });

  // An active entitlement is now MANDATORY for every ordinary source: the
  // seeded assignment alone confers nothing.
  assert.equal(await entitlementState(coach.uid), null);
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);

  // With the entitlement, the seeded assignment authorises as documented.
  await grantCoach(coach.uid);
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), true);
});

test('legacy: an athlete-approved assignment authorises WITH an entitlement', async () => {
  const coach = await makeAccount('approvedCoach');
  const athlete = await makeAccount('approvedAthlete');
  await db.collection('athleteAssignments').doc(athlete.uid).set({
    coaches: { [coach.uid]: { approved: true } },
  });

  // Legacy approval alone no longer confers Coach Mode.
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);
  await grantCoach(coach.uid);
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), true);

  // approved:false and pending entries still grant nothing, entitlement or not.
  const pendingCoach = await makeAccount('pendingCoach');
  await grantCoach(pendingCoach.uid);
  await db.collection('athleteAssignments').doc(athlete.uid).set({
    coaches: {
      [coach.uid]: { approved: true },
      [pendingCoach.uid]: { status: 'pending' },
    },
  });
  assert.equal(await authz.isCoachFor(db, pendingCoach.uid, athlete.uid), false);
});

test('legacy: seeded-athlete removal is removal-only and correctly authorised', async () => {
  const coach = await makeAccount('seedRemoveCoach');
  const athlete = await makeAccount('seedRemoveAthlete');
  const other = await makeAccount('seedOtherCoach');
  await db.collection('coachAssignments').doc(coach.uid).set({
    athletes: { [athlete.uid]: { email: athlete.email } },
  });

  // A different coach cannot edit this roster.
  await expectHttpsError(
    call(cm.coachModeRemoveSeededAthlete, other.uid,
      { coachUid: coach.uid, athleteUid: athlete.uid }), 'permission-denied');

  // The coach may remove their own seeded athlete.
  const res = await call(cm.coachModeRemoveSeededAthlete, coach.uid,
    { athleteUid: athlete.uid });
  assert.equal(res.removed, true);
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);

  // Removing again is idempotent (nothing left to remove).
  const again = await call(cm.coachModeRemoveSeededAthlete, coach.uid,
    { athleteUid: athlete.uid });
  assert.equal(again.removed, false);

  // The callable can never ADD: the roster document holds no new entries.
  const doc = await db.collection('coachAssignments').doc(coach.uid).get();
  const athletes = (doc.data() || {}).athletes || {};
  assert.equal(Object.keys(athletes).length, 0);
});

test('legacy: super admin may remove a seeded athlete from any roster', async () => {
  const coach = await makeAccount('adminSeedRemoveCoach');
  const athlete = await makeAccount('adminSeedRemoveAthlete');
  await db.collection('coachAssignments').doc(coach.uid).set({
    athletes: { [athlete.uid]: { email: athlete.email } },
  });
  const res = await call(cm.coachModeRemoveSeededAthlete, SUPER,
    { coachUid: coach.uid, athleteUid: athlete.uid });
  assert.equal(res.removed, true);
});

// ══════════════════════════════════════════════════════════════════════════
// Audit
// ══════════════════════════════════════════════════════════════════════════

test('audit: super-admin actions are recorded with actor, target and action', async () => {
  const a = await makeAccount('auditTarget');
  await call(cm.coachModeGrantCoach, SUPER, { targetUid: a.uid, reason: 'audit test' });
  await call(cm.coachModeSetCoachState, SUPER,
    { targetUid: a.uid, action: 'suspend', reason: 'audit suspend' });
  await call(cm.coachModeSetCoachState, SUPER,
    { targetUid: a.uid, action: 'revoke', reason: 'audit revoke' });

  const q = await db.collection(M.COL_AUDIT).where('targetUid', '==', a.uid).get();
  const actions = q.docs.map((d) => d.data().action).sort();
  assert.deepEqual(actions, ['coach_revoke', 'coach_suspend', 'direct_grant']);
  for (const doc of q.docs) {
    const d = doc.data();
    assert.equal(d.actorUid, SUPER);
    assert.equal(d.targetUid, a.uid);
    assert.ok(d.at, 'audit entries carry a timestamp');
  }
});

test('audit: application decisions are recorded', async () => {
  const a = await makeAccount('auditApp');
  await call(cm.coachModeSubmitApplication, a.uid, VALID_APPLICATION);
  await call(cm.coachModeReviewApplication, SUPER,
    { applicantUid: a.uid, action: 'request_info', reason: 'more please' });
  await call(cm.coachModeReviewApplication, SUPER,
    { applicantUid: a.uid, action: 'decline', reason: 'no' });

  const q = await db.collection(M.COL_AUDIT).where('targetUid', '==', a.uid).get();
  const actions = q.docs.map((d) => d.data().action).sort();
  assert.deepEqual(actions, ['application_decline', 'application_request_info']);
});

// ══════════════════════════════════════════════════════════════════════════
// Analytics enrollment interaction
// ══════════════════════════════════════════════════════════════════════════

test('enrollment: revoking a relationship disables reporting but never rebuilds analytics', async () => {
  const coach = await makeAccount('enrollCoach');
  const athlete = await makeAccount('enrollAthlete');
  await grantCoach(coach.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });
  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: coach.uid, action: 'accept' });

  // Existing coach check-ins state, as the current reporting flow creates it.
  await db.doc(`coachCheckIns/${coach.uid}/athletes/${athlete.uid}`)
    .set({ reportingEnabled: true, goal: 'cut' });
  await db.doc(`coachAnalytics/${athlete.uid}`).set({
    enabledBy: { [coach.uid]: true },
    bootstrapStatus: 'complete',
  });

  await call(cm.coachModeRevokeCoach, athlete.uid, { coachUid: coach.uid });

  const settings = await db.doc(`coachCheckIns/${coach.uid}/athletes/${athlete.uid}`).get();
  assert.equal(settings.data().reportingEnabled, false,
    'a revoked coach must stop reporting');

  const analytics = await db.doc(`coachAnalytics/${athlete.uid}`).get();
  const d = analytics.data();
  assert.equal((d.enabledBy || {})[coach.uid], undefined,
    'the revoked coach is deregistered');
  assert.equal(d.bootstrapStatus, 'complete',
    'existing bootstrap state must be preserved, never reset');
});

test('enrollment: reporting stays untouched while the relationship is still valid', async () => {
  const coach = await makeAccount('enrollKeepCoach');
  const athlete = await makeAccount('enrollKeepAthlete');
  await grantCoach(coach.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });
  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: coach.uid, action: 'accept' });

  await db.doc(`coachCheckIns/${coach.uid}/athletes/${athlete.uid}`)
    .set({ reportingEnabled: true });

  // Accepting an invitation must not disturb reporting or bootstrap state.
  const settings = await db.doc(`coachCheckIns/${coach.uid}/athletes/${athlete.uid}`).get();
  assert.equal(settings.data().reportingEnabled, true);
});

// ══════════════════════════════════════════════════════════════════════════
// CORRECTIVE PASS
// ══════════════════════════════════════════════════════════════════════════

test('entitlement: a legacy source alone no longer authorises', async () => {
  const coach = await makeAccount('legacyNoEnt');
  const athlete = await makeAccount('legacyNoEntAthlete');

  // Both legacy sources present, NO entitlement.
  await db.collection('coachAssignments').doc(coach.uid).set({
    athletes: { [athlete.uid]: { email: athlete.email } },
  });
  await db.collection('athleteAssignments').doc(athlete.uid).set({
    coaches: { [coach.uid]: { approved: true } },
  });

  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false,
    'legacy data must not confer Coach Mode without an entitlement');

  // Granting the entitlement makes the same legacy data authorise.
  await grantCoach(coach.uid);
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), true);

  // Suspending removes it again, legacy data untouched.
  await call(cm.coachModeSetCoachState, SUPER,
    { targetUid: coach.uid, action: 'suspend', reason: 'hold' });
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);
});

test('relationship: coach release beats a stale legacy approval', async () => {
  const coach = await makeAccount('staleReleaseCoach');
  const athlete = await makeAccount('staleReleaseAthlete');
  await grantCoach(coach.uid);

  // Post-migration shape: canonical ACTIVE link AND the old approved entry.
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });
  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: coach.uid, action: 'accept' });
  await db.collection('athleteAssignments').doc(athlete.uid).set({
    coaches: { [coach.uid]: { approved: true } },
  });
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), true);

  await call(cm.coachModeReleaseAthlete, coach.uid, { athleteUid: athlete.uid });

  assert.equal(await linkStatus(coach.uid, athlete.uid), 'released_by_coach');
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false,
    'the stale legacy approval must not resurrect access');
});

test('relationship: athlete revoke beats a stale legacy approval', async () => {
  const coach = await makeAccount('staleRevokeCoach');
  const athlete = await makeAccount('staleRevokeAthlete');
  await grantCoach(coach.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });
  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: coach.uid, action: 'accept' });
  await db.collection('athleteAssignments').doc(athlete.uid).set({
    coaches: { [coach.uid]: { approved: true } },
  });

  await call(cm.coachModeRevokeCoach, athlete.uid, { coachUid: coach.uid });
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);
});

test('relationship: termination works on a LEGACY-ONLY relationship', async () => {
  // No canonical link at all — only the old approved entry, which neither
  // party may edit from a client. A tombstone must be written instead.
  const coach = await makeAccount('legacyOnlyCoach');
  const athlete = await makeAccount('legacyOnlyAthlete');
  await grantCoach(coach.uid);
  await db.collection('athleteAssignments').doc(athlete.uid).set({
    coaches: { [coach.uid]: { approved: true } },
  });
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), true);
  assert.equal(await linkStatus(coach.uid, athlete.uid), null);

  await call(cm.coachModeReleaseAthlete, coach.uid, { athleteUid: athlete.uid });

  assert.equal(await linkStatus(coach.uid, athlete.uid), 'released_by_coach');
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);
});

test('relationship: athlete can revoke a LEGACY-ONLY coach', async () => {
  const coach = await makeAccount('legacyOnlyRevCoach');
  const athlete = await makeAccount('legacyOnlyRevAthlete');
  await grantCoach(coach.uid);
  await db.collection('athleteAssignments').doc(athlete.uid).set({
    coaches: { [coach.uid]: { approved: true } },
  });

  await call(cm.coachModeRevokeCoach, athlete.uid, { coachUid: coach.uid });
  assert.equal(await linkStatus(coach.uid, athlete.uid), 'revoked_by_athlete');
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);
});

test('roster removal: truthful when every source is removable', async () => {
  const coach = await makeAccount('rmAllCoach');
  const athlete = await makeAccount('rmAllAthlete');
  await grantCoach(coach.uid);

  // All three sources at once.
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });
  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: coach.uid, action: 'accept' });
  await db.collection('coachAssignments').doc(coach.uid).set({
    athletes: { [athlete.uid]: { email: athlete.email } },
  });
  await db.collection('athleteAssignments').doc(athlete.uid).set({
    coaches: { [coach.uid]: { approved: true } },
  });

  const res = await call(cm.coachModeRemoveAthleteFromRoster, coach.uid,
    { athleteUid: athlete.uid });

  assert.deepEqual(res.previousSources.slice().sort(),
    ['canonical', 'legacy_approved', 'legacy_seeded']);
  assert.deepEqual(res.remainingSources, []);
  assert.equal(res.stillAuthorized, false);
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);
});

test('roster removal: removes a seeded-only athlete', async () => {
  const coach = await makeAccount('rmSeedCoach');
  const athlete = await makeAccount('rmSeedAthlete');
  await grantCoach(coach.uid);
  await db.collection('coachAssignments').doc(coach.uid).set({
    athletes: { [athlete.uid]: { email: athlete.email } },
  });

  const res = await call(cm.coachModeRemoveAthleteFromRoster, coach.uid,
    { athleteUid: athlete.uid });
  assert.deepEqual(res.removedSources, ['legacy_seeded']);
  assert.equal(res.stillAuthorized, false);
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);
});

test('roster removal: removes a legacy-approved-only athlete', async () => {
  const coach = await makeAccount('rmApprCoach');
  const athlete = await makeAccount('rmApprAthlete');
  await grantCoach(coach.uid);
  await db.collection('athleteAssignments').doc(athlete.uid).set({
    coaches: { [coach.uid]: { approved: true } },
  });

  const res = await call(cm.coachModeRemoveAthleteFromRoster, coach.uid,
    { athleteUid: athlete.uid });
  assert.deepEqual(res.previousSources, ['legacy_approved']);
  assert.equal(res.stillAuthorized, false);
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);
});

test('roster removal: rejects an athlete who is not on the roster', async () => {
  const coach = await makeAccount('rmNoneCoach');
  const athlete = await makeAccount('rmNoneAthlete');
  await grantCoach(coach.uid);
  await expectHttpsError(
    call(cm.coachModeRemoveAthleteFromRoster, coach.uid,
      { athleteUid: athlete.uid }), 'not-found');
});

test('roster removal: is idempotent', async () => {
  const coach = await makeAccount('rmIdemCoach');
  const athlete = await makeAccount('rmIdemAthlete');
  await grantCoach(coach.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });
  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: coach.uid, action: 'accept' });

  await call(cm.coachModeRemoveAthleteFromRoster, coach.uid,
    { athleteUid: athlete.uid });
  // A second removal finds nothing left to remove.
  await expectHttpsError(
    call(cm.coachModeRemoveAthleteFromRoster, coach.uid,
      { athleteUid: athlete.uid }), 'not-found');
  assert.equal(await authz.isCoachFor(db, coach.uid, athlete.uid), false);
});

test('roster removal: ends analytics enrollment', async () => {
  const coach = await makeAccount('rmEnrollCoach');
  const athlete = await makeAccount('rmEnrollAthlete');
  await grantCoach(coach.uid);
  await call(cm.coachModeInviteAthlete, coach.uid, { athleteEmail: athlete.email });
  await call(cm.coachModeRespondToInvite, athlete.uid,
    { coachUid: coach.uid, action: 'accept' });

  await db.doc('coachCheckIns/' + coach.uid + '/athletes/' + athlete.uid)
    .set({ reportingEnabled: true });
  await db.doc('coachAnalytics/' + athlete.uid).set({
    enabledBy: { [coach.uid]: true }, bootstrapStatus: 'complete',
  });

  await call(cm.coachModeRemoveAthleteFromRoster, coach.uid,
    { athleteUid: athlete.uid });

  const settings = await db.doc(
    'coachCheckIns/' + coach.uid + '/athletes/' + athlete.uid).get();
  assert.equal(settings.data().reportingEnabled, false);
  const analytics = await db.doc('coachAnalytics/' + athlete.uid).get();
  assert.equal((analytics.data().enabledBy || {})[coach.uid], undefined);
  assert.equal(analytics.data().bootstrapStatus, 'complete',
    'analytics must never be rebuilt or reset by a relationship change');
});

test('entitlement: RESTORE preserves the original provenance', async () => {
  const a = await makeAccount('provenance');

  // Original grant: manual_review via an approved application.
  await call(cm.coachModeSubmitApplication, a.uid, VALID_APPLICATION);
  await call(cm.coachModeReviewApplication, SUPER,
    { applicantUid: a.uid, action: 'approve', reason: 'first grant' });

  const first = (await db.collection(M.COL_ENTITLEMENTS).doc(a.uid).get()).data().coach;
  assert.equal(first.source, 'manual_review');
  assert.ok(first.grantedAt);
  assert.ok(first.approvedAt);
  assert.equal(first.approvedBy, SUPER);

  await call(cm.coachModeSetCoachState, SUPER,
    { targetUid: a.uid, action: 'suspend', reason: 'hold' });
  await call(cm.coachModeSetCoachState, SUPER,
    { targetUid: a.uid, action: 'restore', reason: 'cleared' });

  const restored = (await db.collection(M.COL_ENTITLEMENTS).doc(a.uid).get()).data().coach;
  assert.equal(restored.state, 'active');
  // Provenance is IMMUTABLE.
  assert.equal(restored.source, 'manual_review',
    'restore must not rewrite the original source to super_admin_grant');
  assert.deepEqual(restored.grantedAt, first.grantedAt,
    'grantedAt must be preserved');
  assert.equal(restored.grantedBy, first.grantedBy);
  assert.deepEqual(restored.approvedAt, first.approvedAt,
    'approvedAt must be preserved');
  assert.equal(restored.approvedBy, first.approvedBy);
  // Restoration is recorded separately.
  assert.ok(restored.restoredAt, 'restoration is recorded');
  assert.equal(restored.restoredBy, SUPER);
  assert.equal(restored.restoredFrom, 'suspended');
  assert.equal(restored.restoreReason, 'cleared');
  assert.equal(restored.restoreCount, 1);
  // Stale suspension metadata is cleared.
  assert.equal(restored.suspensionReason, null);
});

test('entitlement: repeated restores increment without rewriting provenance', async () => {
  const a = await makeAccount('provenance2');
  await call(cm.coachModeGrantCoach, SUPER,
    { targetUid: a.uid, reason: 'direct' });
  const first = (await db.collection(M.COL_ENTITLEMENTS).doc(a.uid).get()).data().coach;
  assert.equal(first.source, 'super_admin_grant');

  for (let i = 1; i <= 2; i += 1) {
    await call(cm.coachModeSetCoachState, SUPER,
      { targetUid: a.uid, action: 'revoke', reason: 'r' + i });
    await call(cm.coachModeSetCoachState, SUPER,
      { targetUid: a.uid, action: 'restore' });
    const now = (await db.collection(M.COL_ENTITLEMENTS).doc(a.uid).get()).data().coach;
    assert.equal(now.restoreCount, i);
    assert.equal(now.source, 'super_admin_grant',
      'a restore must never rewrite the original grant source');
    assert.deepEqual(now.grantedAt, first.grantedAt);
    assert.equal(now.restoredFrom, 'revoked');
    assert.equal(now.revocationReason, null);
  }
});

// ══════════════════════════════════════════════════════════════════════════
// Migration CLI — exit code 3 (unresolved legacy coaches)
// ══════════════════════════════════════════════════════════════════════════
//
// Exercised through the EMULATOR: GCLOUD_PROJECT is the production id so the
// project guard passes, but FIRESTORE_EMULATOR_HOST redirects every read and
// write to the local emulator. Production is never contacted.

test('migration CLI: --apply exits 3 on unresolved legacy coach uids', async () => {
  const path = require('node:path');
  const { spawnSync } = require('node:child_process');
  const migration = require('../migrate_coach_mode');

  // A coach uid that legacy data authorises but that has no entitlement and is
  // not in the reviewed set.
  const strayCoach = freshUid('strayLegacyCoach');
  const athlete = await makeAccount('strayLegacyAthlete');
  await db.collection('athleteAssignments').doc(athlete.uid).set({
    coaches: { [strayCoach]: { approved: true } },
  });

  const script = path.join(__dirname, '..', 'migrate_coach_mode.js');
  const env = Object.assign({}, process.env, {
    GCLOUD_PROJECT: migration.REQUIRED_PROJECT_ID,
    FIRESTORE_EMULATOR_HOST: process.env.FIRESTORE_EMULATOR_HOST,
  });

  const res = spawnSync(process.execPath, [script, '--apply', '--json'], {
    env, encoding: 'utf8', timeout: 120000,
  });

  assert.equal(res.status, migration.EXIT_UNRESOLVED_COACHES,
    'unresolved legacy coaches must block with status 3\nstdout:\n'
    + res.stdout + '\nstderr:\n' + res.stderr);
  assert.match(res.stderr, /REFUSING TO APPLY/);

  const report = JSON.parse(res.stdout);
  assert.equal(report.blocked, true);
  assert.equal(report.auditComplete, true,
    'gate 3 is only meaningful when the audit genuinely completed');
  assert.ok(report.counts.legacyCoachesUnresolved >= 1);
  assert.ok(
    report.unresolvedLegacyCoaches.some((u) => u.uid === strayCoach),
    'the stray coach uid must be named in the report',
  );

  // The counts are PLAN counts (what WOULD be done) — the preflight now runs
  // before the gates so the report can say what is pending. What matters is
  // that a blocked run wrote NOTHING, which is asserted against the database.
  const ent = await db.collection(M.COL_ENTITLEMENTS).doc(strayCoach).get();
  assert.equal(ent.exists, false,
    'a discovered legacy uid must NEVER be auto-entitled');

  for (const uid of migration.LEGACY_COACH_UIDS) {
    const e = await db.collection(M.COL_ENTITLEMENTS).doc(uid).get();
    assert.equal(e.exists, false,
      'a blocked apply must not write entitlement for ' + uid);
  }
  const links = await db.collection(M.COL_LINKS)
    .where('migratedFrom', '==', 'athleteAssignments').get();
  assert.equal(links.size, 0, 'a blocked apply must not create links');
});

test('migration CLI: --allow-unresolved proceeds past the gate', async () => {
  const path = require('node:path');
  const { spawnSync } = require('node:child_process');
  const migration = require('../migrate_coach_mode');

  const script = path.join(__dirname, '..', 'migrate_coach_mode.js');
  const env = Object.assign({}, process.env, {
    GCLOUD_PROJECT: migration.REQUIRED_PROJECT_ID,
    FIRESTORE_EMULATOR_HOST: process.env.FIRESTORE_EMULATOR_HOST,
  });

  // A dry run is never blocked by gate 2 in the first place.
  const dry = spawnSync(process.execPath, [script, '--json'], {
    env, encoding: 'utf8', timeout: 120000,
  });
  assert.equal(dry.status, migration.EXIT_OK,
    'a dry run must always exit 0\nstderr:\n' + dry.stderr);
  const dryReport = JSON.parse(dry.stdout);
  assert.equal(dryReport.mode, 'DRY-RUN');
  assert.notEqual(dryReport.blocked, true);

  // The reviewed escape hatch clears gate 2 and completes.
  const applied = spawnSync(
    process.execPath, [script, '--apply', '--allow-unresolved', '--json'],
    { env, encoding: 'utf8', timeout: 120000 },
  );
  assert.equal(applied.status, migration.EXIT_OK,
    'an allowed apply must exit 0\nstderr:\n' + applied.stderr);
  const report = JSON.parse(applied.stdout);
  assert.notEqual(report.blocked, true);
  // Still reports the unresolved uids for the operator.
  assert.ok(report.counts.legacyCoachesUnresolved >= 1);
});
