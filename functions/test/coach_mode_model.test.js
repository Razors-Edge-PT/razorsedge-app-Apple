'use strict';

// Unit tests for the pure Coach Mode domain model: application validation and
// length limits, the three state machines, deterministic link ids, custom-claim
// merging and invitation rate limiting.
//
// These are the security-relevant rules the callables lean on, so they are
// pinned here without needing an emulator.

const test = require('node:test');
const assert = require('node:assert/strict');

const M = require('../coach/coach_mode_model');

// ── Super admin ─────────────────────────────────────────────────────────────

test('super admin uid is the single hard-coded constant used everywhere', () => {
  assert.equal(M.SUPER_ADMIN_UID, 'yoVAqScwLMQLAgNHh8v9IK49fBw2');
  assert.equal(M.isSuperAdminUid('yoVAqScwLMQLAgNHh8v9IK49fBw2'), true);
  assert.equal(M.isSuperAdminUid('someoneElse'), false);
  assert.equal(M.isSuperAdminUid(null), false);
  assert.equal(M.isSuperAdminUid(undefined), false);
  assert.equal(M.isSuperAdminUid({}), false);
});

test('authz.js and the model agree on the super admin', () => {
  const authz = require('../coach/authz');
  assert.equal(authz.SUPER_ADMIN_UID, M.SUPER_ADMIN_UID);
  assert.deepEqual(authz.SUPER_ADMIN_UIDS, [M.SUPER_ADMIN_UID]);
});

// ── Application validation ──────────────────────────────────────────────────

const VALID = Object.freeze({
  athleteCountBand: '6-15',
  experienceBand: '4-7',
  coachingFocus: ['powerlifting', 'general_strength'],
  competitionExperience: ['powerlifting'],
  qualifications: 'NZ Powerlifting Level 2',
  competitionDetails: 'Competed 2019-2024',
  intendedUse: 'Programming blocks and reviewing weekly check-ins for my athletes.',
  profileUrl: 'https://example.com/coach',
  agreesToAthleteConsent: true,
});

function valid(overrides) {
  return Object.assign({}, VALID, overrides || {});
}

function expectInvalid(input, field) {
  assert.throws(
    () => M.validateApplication(input),
    (err) => {
      assert.ok(err instanceof M.ValidationError, 'expected ValidationError, got ' + err);
      if (field) assert.equal(err.field, field, 'wrong field: ' + err.field);
      return true;
    },
  );
}

test('application: a complete valid payload normalizes cleanly', () => {
  const out = M.validateApplication(valid());
  assert.equal(out.athleteCountBand, '6-15');
  assert.equal(out.experienceBand, '4-7');
  // Enum lists come back in canonical order regardless of input order.
  assert.deepEqual(out.coachingFocus, ['powerlifting', 'general_strength']);
  assert.deepEqual(out.competitionExperience, ['powerlifting']);
  assert.equal(out.agreesToAthleteConsent, true);
  // Unknown client keys are never persisted.
  const withJunk = M.validateApplication(valid({ isCoach: true, admin: true }));
  assert.equal(withJunk.isCoach, undefined);
  assert.equal(withJunk.admin, undefined);
  assert.deepEqual(Object.keys(withJunk).sort(), [
    'agreesToAthleteConsent', 'athleteCountBand', 'coachingFocus',
    'competitionDetails', 'competitionExperience', 'experienceBand',
    'intendedUse', 'profileUrl', 'qualifications',
  ]);
});

test('application: enum fields reject unsupported values', () => {
  expectInvalid(valid({ athleteCountBand: '100+' }), 'athleteCountBand');
  expectInvalid(valid({ athleteCountBand: 6 }), 'athleteCountBand');
  expectInvalid(valid({ experienceBand: 'forever' }), 'experienceBand');
  expectInvalid(valid({ coachingFocus: ['crossfit'] }), 'coachingFocus');
  expectInvalid(valid({ competitionExperience: ['strongman'] }), 'competitionExperience');
});

test('application: multi-selects require at least one value and must be lists', () => {
  expectInvalid(valid({ coachingFocus: [] }), 'coachingFocus');
  expectInvalid(valid({ coachingFocus: 'powerlifting' }), 'coachingFocus');
  expectInvalid(valid({ competitionExperience: [] }), 'competitionExperience');
});

test("application: competition 'none' is exclusive", () => {
  expectInvalid(
    valid({ competitionExperience: ['none', 'powerlifting'] }),
    'competitionExperience',
  );
  const ok = M.validateApplication(valid({ competitionExperience: ['none'] }));
  assert.deepEqual(ok.competitionExperience, ['none']);
});

test('application: length limits are enforced on every free-text field', () => {
  expectInvalid(
    valid({ qualifications: 'x'.repeat(M.LIMITS.qualifications + 1) }),
    'qualifications',
  );
  expectInvalid(
    valid({ competitionDetails: 'x'.repeat(M.LIMITS.competitionDetails + 1) }),
    'competitionDetails',
  );
  expectInvalid(
    valid({ intendedUse: 'x'.repeat(M.LIMITS.intendedUse + 1) }),
    'intendedUse',
  );
  // Exactly at the limit is accepted.
  const atLimit = M.validateApplication(
    valid({ qualifications: 'x'.repeat(M.LIMITS.qualifications) }),
  );
  assert.equal(atLimit.qualifications.length, M.LIMITS.qualifications);
});

test('application: intendedUse is required and has a minimum length', () => {
  expectInvalid(valid({ intendedUse: '' }), 'intendedUse');
  expectInvalid(valid({ intendedUse: undefined }), 'intendedUse');
  expectInvalid(valid({ intendedUse: 'too short' }), 'intendedUse');
  const ok = M.validateApplication(
    valid({ intendedUse: 'x'.repeat(M.INTENDED_USE_MIN) }),
  );
  assert.equal(ok.intendedUse.length, M.INTENDED_USE_MIN);
});

test('application: optional text fields may be omitted entirely', () => {
  const out = M.validateApplication(valid({
    qualifications: undefined,
    competitionDetails: '',
    profileUrl: undefined,
  }));
  assert.equal(out.qualifications, '');
  assert.equal(out.competitionDetails, '');
  assert.equal(out.profileUrl, '');
});

test('application: profileUrl must be a bounded http(s) link', () => {
  expectInvalid(valid({ profileUrl: 'javascript:alert(1)' }), 'profileUrl');
  expectInvalid(valid({ profileUrl: 'not a url' }), 'profileUrl');
  expectInvalid(valid({ profileUrl: 'ftp://example.com/x' }), 'profileUrl');
  expectInvalid(
    valid({ profileUrl: 'https://e.com/' + 'x'.repeat(M.LIMITS.profileUrl) }),
    'profileUrl',
  );
  assert.equal(
    M.validateApplication(valid({ profileUrl: 'http://example.com/a' })).profileUrl,
    'http://example.com/a',
  );
});

test('application: the athlete-consent confirmation is mandatory', () => {
  expectInvalid(valid({ agreesToAthleteConsent: false }), 'agreesToAthleteConsent');
  expectInvalid(valid({ agreesToAthleteConsent: undefined }), 'agreesToAthleteConsent');
  // Truthy-but-not-true must not pass.
  expectInvalid(valid({ agreesToAthleteConsent: 'yes' }), 'agreesToAthleteConsent');
  expectInvalid(valid({ agreesToAthleteConsent: 1 }), 'agreesToAthleteConsent');
});

test('application: a non-object payload is rejected, not coerced', () => {
  expectInvalid(null);
  expectInvalid(undefined);
  expectInvalid('powerlifting');
});

// ── Application state machine ───────────────────────────────────────────────

test('application transitions: only the intended moves are allowed', () => {
  // First submission.
  assert.equal(M.canTransitionApplication(null, 'submitted'), true);
  // Review outcomes from submitted.
  assert.equal(M.canTransitionApplication('submitted', 'approved'), true);
  assert.equal(M.canTransitionApplication('submitted', 'declined'), true);
  assert.equal(M.canTransitionApplication('submitted', 'more_info_requested'), true);
  assert.equal(M.canTransitionApplication('submitted', 'withdrawn'), true);
  // Resubmission after a request for information / decline / withdrawal.
  assert.equal(M.canTransitionApplication('more_info_requested', 'submitted'), true);
  assert.equal(M.canTransitionApplication('declined', 'submitted'), true);
  assert.equal(M.canTransitionApplication('withdrawn', 'submitted'), true);
  // Approved is terminal: access is managed via the entitlement afterwards.
  assert.equal(M.canTransitionApplication('approved', 'declined'), false);
  assert.equal(M.canTransitionApplication('approved', 'submitted'), false);
  assert.equal(M.canTransitionApplication('approved', 'withdrawn'), false);
  // Nonsense transitions.
  assert.equal(M.canTransitionApplication('declined', 'approved'), false);
  assert.equal(M.canTransitionApplication('withdrawn', 'approved'), false);
  assert.equal(M.canTransitionApplication('submitted', 'submitted'), false);
  assert.equal(M.canTransitionApplication('bogus', 'submitted'), false);
});

test('canSubmitApplication mirrors the transition table', () => {
  assert.equal(M.canSubmitApplication(null), true);
  assert.equal(M.canSubmitApplication(undefined), true);
  assert.equal(M.canSubmitApplication('declined'), true);
  assert.equal(M.canSubmitApplication('withdrawn'), true);
  assert.equal(M.canSubmitApplication('more_info_requested'), true);
  assert.equal(M.canSubmitApplication('submitted'), false);
  assert.equal(M.canSubmitApplication('approved'), false);
});

// ── Entitlement state machine ───────────────────────────────────────────────

test('entitlement transitions cover grant, suspend, revoke and restore', () => {
  assert.equal(M.canTransitionEntitlement(null, 'active'), true);
  assert.equal(M.canTransitionEntitlement('active', 'suspended'), true);
  assert.equal(M.canTransitionEntitlement('active', 'revoked'), true);
  assert.equal(M.canTransitionEntitlement('suspended', 'active'), true);
  assert.equal(M.canTransitionEntitlement('suspended', 'revoked'), true);
  assert.equal(M.canTransitionEntitlement('revoked', 'active'), true);
  // Never from nothing straight to a terminal state.
  assert.equal(M.canTransitionEntitlement(null, 'suspended'), false);
  assert.equal(M.canTransitionEntitlement(null, 'revoked'), false);
});

test('entitlementIsActive: ONLY an explicit active state grants coach access', () => {
  assert.equal(M.entitlementIsActive({ coach: { state: 'active' } }), true);
  assert.equal(M.entitlementIsActive({ coach: { state: 'suspended' } }), false);
  assert.equal(M.entitlementIsActive({ coach: { state: 'revoked' } }), false);
  // Malformed / partial / forged shapes must never authorise.
  assert.equal(M.entitlementIsActive(null), false);
  assert.equal(M.entitlementIsActive(undefined), false);
  assert.equal(M.entitlementIsActive({}), false);
  assert.equal(M.entitlementIsActive({ coach: {} }), false);
  assert.equal(M.entitlementIsActive({ coach: null }), false);
  assert.equal(M.entitlementIsActive({ coach: 'active' }), false);
  assert.equal(M.entitlementIsActive({ state: 'active' }), false);
  assert.equal(M.entitlementIsActive({ isCoach: true }), false);
});

// ── Relationship state machine ──────────────────────────────────────────────

test('link ids are deterministic and round-trip', () => {
  assert.equal(M.linkId('coachA', 'athleteB'), 'coachA__athleteB');
  assert.deepEqual(M.parseLinkId('coachA__athleteB'), {
    coachUid: 'coachA', athleteUid: 'athleteB',
  });
  // Malformed ids are rejected rather than half-parsed.
  assert.equal(M.parseLinkId('noseparator'), null);
  assert.equal(M.parseLinkId('a__b__c'), null);
  assert.equal(M.parseLinkId('__b'), null);
  assert.equal(M.parseLinkId('a__'), null);
  assert.equal(M.parseLinkId(null), null);
  assert.equal(M.parseLinkId(42), null);
});

test('link transitions: invite, respond, terminate and re-invite', () => {
  assert.equal(M.canTransitionLink(null, 'pending'), true);
  assert.equal(M.canTransitionLink('pending', 'active'), true);
  assert.equal(M.canTransitionLink('pending', 'declined'), true);
  assert.equal(M.canTransitionLink('pending', 'cancelled'), true);
  assert.equal(M.canTransitionLink('active', 'revoked_by_athlete'), true);
  assert.equal(M.canTransitionLink('active', 'released_by_coach'), true);
  // Every terminated state can be re-invited.
  for (const s of M.LINK_TERMINAL_STATUSES) {
    assert.equal(M.canTransitionLink(s, 'pending'), true, s + ' -> pending');
  }
  // Illegal moves.
  assert.equal(M.canTransitionLink(null, 'active'), false, 'cannot fabricate active');
  assert.equal(M.canTransitionLink('declined', 'active'), false);
  assert.equal(M.canTransitionLink('cancelled', 'active'), false);
  assert.equal(M.canTransitionLink('revoked_by_athlete', 'active'), false);
  assert.equal(M.canTransitionLink('released_by_coach', 'active'), false);
  assert.equal(M.canTransitionLink('active', 'pending'), false);
  assert.equal(M.canTransitionLink('active', 'declined'), false);
  assert.equal(M.canTransitionLink('pending', 'revoked_by_athlete'), false);
});

test('link transitions are bound to the correct actor role', () => {
  // Coach-driven.
  assert.equal(M.actorMayDriveLink('pending', 'coach'), true);
  assert.equal(M.actorMayDriveLink('cancelled', 'coach'), true);
  assert.equal(M.actorMayDriveLink('released_by_coach', 'coach'), true);
  // Athlete-driven.
  assert.equal(M.actorMayDriveLink('active', 'athlete'), true);
  assert.equal(M.actorMayDriveLink('declined', 'athlete'), true);
  assert.equal(M.actorMayDriveLink('revoked_by_athlete', 'athlete'), true);
  // A coach can NEVER accept on the athlete's behalf.
  assert.equal(M.actorMayDriveLink('active', 'coach'), false);
  assert.equal(M.actorMayDriveLink('declined', 'coach'), false);
  assert.equal(M.actorMayDriveLink('revoked_by_athlete', 'coach'), false);
  // An athlete can never invite themselves onto a coach's roster.
  assert.equal(M.actorMayDriveLink('pending', 'athlete'), false);
  assert.equal(M.actorMayDriveLink('cancelled', 'athlete'), false);
  assert.equal(M.actorMayDriveLink('released_by_coach', 'athlete'), false);
});

test('linkIsActive: only the active status is a real relationship', () => {
  assert.equal(M.linkIsActive({ status: 'active' }), true);
  for (const s of ['pending'].concat(M.LINK_TERMINAL_STATUSES)) {
    assert.equal(M.linkIsActive({ status: s }), false, s + ' must not authorise');
  }
  assert.equal(M.linkIsActive(null), false);
  assert.equal(M.linkIsActive({}), false);
  assert.equal(M.linkIsActive({ status: true }), false);
});

// ── Custom-claim merging ────────────────────────────────────────────────────

test('mergeCoachClaim preserves every unrelated claim', () => {
  const existing = { stripeRole: 'premium', tier: 3, admin: false };
  const next = M.mergeCoachClaim(existing, true);
  assert.equal(next.isCoach, true);
  assert.equal(next.stripeRole, 'premium');
  assert.equal(next.tier, 3);
  assert.equal(next.admin, false);
  // The original object is not mutated.
  assert.equal(existing.isCoach, undefined);
});

test('mergeCoachClaim removes only isCoach when revoking', () => {
  const next = M.mergeCoachClaim({ stripeRole: 'premium', isCoach: true }, false);
  assert.equal(next.isCoach, undefined);
  assert.equal('isCoach' in next, false);
  assert.equal(next.stripeRole, 'premium');
});

test('mergeCoachClaim tolerates a missing or malformed claims object', () => {
  assert.deepEqual(M.mergeCoachClaim(undefined, true), { isCoach: true });
  assert.deepEqual(M.mergeCoachClaim(null, true), { isCoach: true });
  assert.deepEqual(M.mergeCoachClaim('nonsense', true), { isCoach: true });
  assert.deepEqual(M.mergeCoachClaim(undefined, false), {});
});

// ── Email normalization ─────────────────────────────────────────────────────

test('email normalization and validation', () => {
  assert.equal(M.normalizeEmail('  Coach@Example.COM '), 'coach@example.com');
  assert.equal(M.normalizeEmail(null), '');
  assert.equal(M.requireEmail(' A@B.co '), 'a@b.co');
  assert.throws(() => M.requireEmail('not-an-email'), M.ValidationError);
  assert.throws(() => M.requireEmail(''), M.ValidationError);
  assert.throws(() => M.requireEmail('a@b'), M.ValidationError);
  assert.throws(() => M.requireEmail('x'.repeat(300) + '@b.co'), M.ValidationError);
});

// ── Snapshots and profiles ──────────────────────────────────────────────────

test('coach profile carries only invitation-safe identity fields', () => {
  const profile = M.buildCoachProfile({
    uid: 'c1',
    displayName: 'Coach Rich',
    email: 'Coach@Example.com',
    photoUrl: 'https://example.com/p.jpg',
  });
  assert.deepEqual(Object.keys(profile).sort(),
    ['displayName', 'email', 'photoUrl', 'uid']);
  assert.equal(profile.email, 'coach@example.com');
});

test('snapshots bound their fields so a link document cannot be inflated', () => {
  const snap = M.buildPartySnapshot({
    displayName: 'n'.repeat(500),
    email: 'A@B.CO',
  });
  assert.equal(snap.displayName.length, M.LIMITS.displayName);
  assert.equal(snap.email, 'a@b.co');
  assert.deepEqual(Object.keys(snap).sort(), ['displayName', 'email']);
});

// ── Invitation rate limiting ────────────────────────────────────────────────

test('invite rate limit: allows up to the cap inside the window', () => {
  const now = 1_000_000_000_000;
  let window = [];
  for (let i = 0; i < M.INVITE_RATE_MAX; i += 1) {
    const d = M.inviteRateDecision(window, now + i);
    assert.equal(d.allowed, true, 'invite ' + i + ' should be allowed');
    window = d.retained;
  }
  const blocked = M.inviteRateDecision(window, now + M.INVITE_RATE_MAX);
  assert.equal(blocked.allowed, false, 'the cap must block the next invite');
});

test('invite rate limit: entries outside the window are pruned', () => {
  const now = 1_000_000_000_000;
  const stale = Array.from(
    { length: M.INVITE_RATE_MAX },
    (_, i) => now - M.INVITE_RATE_WINDOW_MS - 1000 - i,
  );
  const d = M.inviteRateDecision(stale, now);
  assert.equal(d.allowed, true, 'stale entries must not block');
  assert.equal(d.retained.length, 1, 'only the new entry is retained');
});

test('invite rate limit: malformed stored state degrades safely', () => {
  const now = 1_000_000_000_000;
  assert.equal(M.inviteRateDecision(null, now).allowed, true);
  assert.equal(M.inviteRateDecision('nonsense', now).allowed, true);
  const mixed = M.inviteRateDecision([now, 'x', null, NaN, now - 5], now);
  assert.equal(mixed.allowed, true);
  assert.deepEqual(mixed.retained, [now - 5, now, now]);
});

// ── Terminal-link detection (corrective pass) ───────────────────────────────

test('linkIsTerminal: only deliberate endings are terminal', () => {
  for (const s of M.LINK_TERMINAL_STATUSES) {
    assert.equal(M.linkIsTerminal({ status: s }), true, s + ' is terminal');
  }
  // In-flight states are NOT terminal — pending must never cancel a legacy
  // approval, and active obviously must not.
  assert.equal(M.linkIsTerminal({ status: 'pending' }), false);
  assert.equal(M.linkIsTerminal({ status: 'active' }), false);
  // Missing / malformed never counts as a deliberate termination.
  assert.equal(M.linkIsTerminal(null), false);
  assert.equal(M.linkIsTerminal(undefined), false);
  assert.equal(M.linkIsTerminal({}), false);
  assert.equal(M.linkIsTerminal({ status: 'bogus' }), false);
  assert.equal(M.linkIsTerminal({ status: true }), false);
});

test('linkIsActive and linkIsTerminal are mutually exclusive', () => {
  for (const s of M.LINK_STATUSES) {
    const data = { status: s };
    assert.equal(M.linkIsActive(data) && M.linkIsTerminal(data), false,
      s + ' cannot be both active and terminal');
  }
});
