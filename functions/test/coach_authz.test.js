'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const authz = require('../coach/authz');

// An ACTIVE coach entitlement is now MANDATORY for every ordinary source, so
// the legacy-source matrix below is evaluated WITH one. Tests that a legacy
// source alone is not enough live in the entitlement section further down.
const ACTIVE_ENTITLEMENT = { coach: { state: 'active', source: 'manual_review' } };

function evaluate(coachAssignData, athleteAssignData, extra) {
  return authz.evaluateAssignment(Object.assign({
    coachAssignData, athleteAssignData,
    entitlementData: ACTIVE_ENTITLEMENT,
    linkData: null,
    coachUid: 'coachA', athleteUid: 'ath1',
  }, extra || {}));
}

// Matrix from stabilisation item A (now entitlement-gated).

test('authz: approved athleteAssignments entry grants access (with entitlement)', () => {
  assert.equal(evaluate(null, { coaches: { coachA: { approved: true } } }), true);
});

test('authz: admin-seeded coachAssignments entry grants access (with entitlement)', () => {
  assert.equal(evaluate({ athletes: { ath1: { email: 'a@b.c' } } }, null), true);
  // Seeded entries may be any non-null shape (the app writes {email}).
  assert.equal(evaluate({ athletes: { ath1: {} } }, null), true);
});

test('authz: pending/unapproved athleteAssignments entry does NOT grant access', () => {
  assert.equal(evaluate(null, { coaches: { coachA: {} } }), false);
  assert.equal(evaluate(null, { coaches: { coachA: { status: 'pending' } } }), false);
});

test('authz: explicitly false approval does NOT grant access', () => {
  assert.equal(evaluate(null, { coaches: { coachA: { approved: false } } }), false);
});

test('authz: missing relationship does NOT grant access', () => {
  assert.equal(evaluate(null, null), false);
  assert.equal(evaluate({ athletes: {} }, { coaches: {} }), false);
  assert.equal(evaluate({ athletes: { other: {} } }, { coaches: { otherCoach: { approved: true } } }), false);
});

test('authz: malformed relationships do NOT grant access', () => {
  assert.equal(evaluate(null, { coaches: { coachA: true } }), false);        // boolean, not object
  assert.equal(evaluate(null, { coaches: { coachA: 'approved' } }), false);  // string
  assert.equal(evaluate(null, { coaches: { coachA: { approved: 'true' } } }), false); // string true
  assert.equal(evaluate(null, { coaches: { coachA: { approved: 1 } } }), false);      // truthy non-bool
  assert.equal(evaluate({ athletes: { ath1: null } }, null), false);         // explicit null seeded
});

// ── Super-admin (regression: super-admin had no backend authorisation path) ──

test('authz: super-admin is authorised for any athlete with no assignment doc', () => {
  const superUid = authz.SUPER_ADMIN_UIDS[0];
  assert.equal(authz.isSuperAdmin(superUid), true);
  assert.equal(authz.evaluateAssignment({
    coachAssignData: null, athleteAssignData: null,
    coachUid: superUid, athleteUid: 'anyAthlete',
  }), true);
});

test('authz: super-admin stays authorised even when explicitly unapproved', () => {
  const superUid = authz.SUPER_ADMIN_UIDS[0];
  assert.equal(authz.evaluateAssignment({
    coachAssignData: { athletes: {} },
    athleteAssignData: { coaches: { [superUid]: { approved: false } } },
    coachUid: superUid, athleteUid: 'ath1',
  }), true);
});

test('authz: super-admin status is exact — no near-miss uid is elevated', () => {
  const superUid = authz.SUPER_ADMIN_UIDS[0];
  assert.equal(authz.isSuperAdmin(`${superUid}x`), false);
  assert.equal(authz.isSuperAdmin(superUid.toLowerCase()), false);
  assert.equal(authz.isSuperAdmin(''), false);
  assert.equal(authz.isSuperAdmin(null), false);
  assert.equal(authz.isSuperAdmin(undefined), false);
  // An ordinary coach with no assignment is still denied.
  assert.equal(evaluate(null, null), false);
});

test('authz: super-admin uid matches the one used by rules and the client', () => {
  // firestore.rules isSuperAdmin() and UserContext.isSuperAdmin must agree.
  assert.deepEqual(authz.SUPER_ADMIN_UIDS, ['yoVAqScwLMQLAgNHh8v9IK49fBw2']);
});

test('authz: removed relationship revokes; one remaining valid source preserves', () => {
  // Both sources present → authorised.
  assert.equal(evaluate(
    { athletes: { ath1: {} } },
    { coaches: { coachA: { approved: true } } }), true);
  // Seeded removed, approval remains → still authorised.
  assert.equal(evaluate(
    { athletes: {} },
    { coaches: { coachA: { approved: true } } }), true);
  // Approval flipped false, seeded remains → still authorised.
  assert.equal(evaluate(
    { athletes: { ath1: {} } },
    { coaches: { coachA: { approved: false } } }), true);
  // Both removed → revoked.
  assert.equal(evaluate({ athletes: {} }, { coaches: {} }), false);
});

// ══════════════════════════════════════════════════════════════════════════
// CORRECTIVE PASS — an ACTIVE entitlement is mandatory for EVERY ordinary
// source, and a terminal canonical link overrides a stale legacy approval.
// ══════════════════════════════════════════════════════════════════════════

const SEEDED = { athletes: { ath1: { email: 'a@b.c' } } };
const APPROVED = { coaches: { coachA: { approved: true } } };
const ACTIVE_LINK = { status: 'active' };

function detail(overrides) {
  return authz.evaluateAssignmentDetail(Object.assign({
    coachAssignData: null,
    athleteAssignData: null,
    entitlementData: null,
    linkData: null,
    coachUid: 'coachA',
    athleteUid: 'ath1',
  }, overrides || {}));
}

function authorised(overrides) {
  return detail(overrides).authorised;
}

test('authz: SUSPENDED entitlement plus seeded assignment DENIES', () => {
  assert.equal(authorised({
    coachAssignData: SEEDED,
    entitlementData: { coach: { state: 'suspended' } },
  }), false);
});

test('authz: REVOKED entitlement plus legacy approved assignment DENIES', () => {
  assert.equal(authorised({
    athleteAssignData: APPROVED,
    entitlementData: { coach: { state: 'revoked' } },
  }), false);
});

test('authz: suspended/revoked entitlement denies even with an ACTIVE link', () => {
  for (const state of ['suspended', 'revoked']) {
    assert.equal(authorised({
      linkData: ACTIVE_LINK,
      coachAssignData: SEEDED,
      athleteAssignData: APPROVED,
      entitlementData: { coach: { state } },
    }), false, state + ' must deny every source at once');
  }
});

test('authz: MISSING entitlement denies all ordinary coach access', () => {
  assert.equal(authorised({ coachAssignData: SEEDED }), false);
  assert.equal(authorised({ athleteAssignData: APPROVED }), false);
  assert.equal(authorised({ linkData: ACTIVE_LINK }), false);
  assert.equal(authorised({
    coachAssignData: SEEDED, athleteAssignData: APPROVED, linkData: ACTIVE_LINK,
  }), false);
});

test('authz: MALFORMED entitlement denies all ordinary coach access', () => {
  const malformed = [
    {},
    { coach: null },
    { coach: {} },
    { coach: 'active' },
    { coach: { state: 'ACTIVE' } },   // wrong case is not active
    { coach: { state: true } },
    { state: 'active' },              // wrong nesting
    { isCoach: true },                // a forged claim-shaped document
  ];
  for (const entitlementData of malformed) {
    assert.equal(authorised({
      entitlementData,
      coachAssignData: SEEDED,
      athleteAssignData: APPROVED,
      linkData: ACTIVE_LINK,
    }), false, 'must deny: ' + JSON.stringify(entitlementData));
  }
});

test('authz: ACTIVE entitlement plus a valid legacy source authorises', () => {
  // This is the intentionally documented compatibility behaviour.
  assert.equal(authorised({
    entitlementData: ACTIVE_ENTITLEMENT, coachAssignData: SEEDED,
  }), true);
  assert.equal(authorised({
    entitlementData: ACTIVE_ENTITLEMENT, athleteAssignData: APPROVED,
  }), true);
  assert.equal(authorised({
    entitlementData: ACTIVE_ENTITLEMENT, linkData: ACTIVE_LINK,
  }), true);
});

test('authz: an active entitlement ALONE authorises nothing', () => {
  // The entitlement says "this account may coach"; it never says which
  // athletes. Without any assignment source there is no access.
  assert.equal(authorised({ entitlementData: ACTIVE_ENTITLEMENT }), false);
});

test('authz: a TERMINAL canonical link overrides a stale legacy approval', () => {
  for (const status of
    ['declined', 'cancelled', 'revoked_by_athlete', 'released_by_coach']) {
    assert.equal(authorised({
      entitlementData: ACTIVE_ENTITLEMENT,
      athleteAssignData: APPROVED,
      linkData: { status },
    }), false, status + ' must cancel the stale legacy approval');
  }
});

test('authz: a PENDING link does not override a legacy approval', () => {
  // Pending is not a decision — it must neither grant nor terminate.
  assert.equal(authorised({
    entitlementData: ACTIVE_ENTITLEMENT,
    athleteAssignData: APPROVED,
    linkData: { status: 'pending' },
  }), true);
  // And pending alone still grants nothing.
  assert.equal(authorised({
    entitlementData: ACTIVE_ENTITLEMENT,
    linkData: { status: 'pending' },
  }), false);
});

test('authz: a terminal link does NOT override a super-admin seed', () => {
  // Seeding is a separate admin-controlled compatibility path; this pass
  // deliberately does not redesign it.
  assert.equal(authorised({
    entitlementData: ACTIVE_ENTITLEMENT,
    coachAssignData: SEEDED,
    linkData: { status: 'revoked_by_athlete' },
  }), true);
});

test('authz: reported sources explain the decision', () => {
  const all = detail({
    entitlementData: ACTIVE_ENTITLEMENT,
    coachAssignData: SEEDED,
    athleteAssignData: APPROVED,
    linkData: ACTIVE_LINK,
  });
  assert.deepEqual(all.sources.sort(),
    ['canonical', 'legacy_approved', 'legacy_seeded']);
  assert.equal(all.authorised, true);

  // After a coach release, only the seed remains.
  const afterRelease = detail({
    entitlementData: ACTIVE_ENTITLEMENT,
    coachAssignData: SEEDED,
    athleteAssignData: APPROVED,
    linkData: { status: 'released_by_coach' },
  });
  assert.deepEqual(afterRelease.sources, ['legacy_seeded']);
  assert.equal(afterRelease.authorised, true);

  // Remove the seed too and nothing is left.
  const afterBoth = detail({
    entitlementData: ACTIVE_ENTITLEMENT,
    coachAssignData: { athletes: {} },
    athleteAssignData: APPROVED,
    linkData: { status: 'released_by_coach' },
  });
  assert.deepEqual(afterBoth.sources, []);
  assert.equal(afterBoth.authorised, false);
});

test('authz: sources are reported even when the entitlement denies', () => {
  // So the removal flow can still describe what exists.
  const d = detail({
    entitlementData: { coach: { state: 'suspended' } },
    coachAssignData: SEEDED,
  });
  assert.deepEqual(d.sources, ['legacy_seeded']);
  assert.equal(d.entitlementActive, false);
  assert.equal(d.authorised, false);
});

test('authz: super admin needs no entitlement and no assignment', () => {
  const d = authz.evaluateAssignmentDetail({
    coachAssignData: null,
    athleteAssignData: null,
    entitlementData: { coach: { state: 'revoked' } },
    linkData: { status: 'revoked_by_athlete' },
    coachUid: authz.SUPER_ADMIN_UID,
    athleteUid: 'anyone',
  });
  assert.equal(d.authorised, true);
  assert.deepEqual(d.sources, ['super_admin']);
});
