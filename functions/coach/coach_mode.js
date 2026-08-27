// Coach Mode — server-authoritative onboarding, entitlements and
// coach⇄athlete relationships.
//
// Every state change in this file goes through an authenticated callable:
// clients can never fabricate an application status, an entitlement or an
// active relationship, because firestore.rules makes all of these
// collections client-unwritable (see the Coach Mode block in firestore.rules).
//
// Authorisation layers used here:
//   • super admin  — the single hard-coded UID (coach_mode_model.SUPER_ADMIN_UID)
//   • coach        — accountEntitlements/{uid}.coach.state === 'active'
//   • athlete      — the authenticated uid on the athlete side of a link
//
// Deployment note: newly created callables in this project need the Cloud Run
// invoker IAM check disabled once, out of band — see CALLABLE_OPTS in
// functions/coach/index.js and docs/coach_mode.md.

'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const M = require('./coach_mode_model');
const authz = require('./authz');

// Same defensive self-initialization as functions/coach/index.js, so this
// module can be required standalone (tests, the migration script) as well as
// through functions/index.js.
try { admin.initializeApp(); } catch (_) { /* already initialized */ }
const db = admin.firestore();
const FV = admin.firestore.FieldValue;

// Same posture as the existing coach callables — requests may reach the
// handler and every authorisation decision is made inside it.
const CALLABLE_OPTS = { invoker: 'public' };

// ── Refs ────────────────────────────────────────────────────────────────────
const applicationRef = (uid) => db.collection(M.COL_APPLICATIONS).doc(uid);
const entitlementRef = (uid) => db.collection(M.COL_ENTITLEMENTS).doc(uid);
const profileRef = (uid) => db.collection(M.COL_PROFILES).doc(uid);
const linkRef = (coachUid, athleteUid) =>
  db.collection(M.COL_LINKS).doc(M.linkId(coachUid, athleteUid));
const auditCol = () => db.collection(M.COL_AUDIT);

// ── Guards ──────────────────────────────────────────────────────────────────

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError('unauthenticated', 'Sign in required.');
  }
  return request.auth.uid;
}

/** The hard-coded super admin, enforced server-side on every admin action. */
function requireSuperAdmin(request) {
  const uid = requireAuth(request);
  if (!M.isSuperAdminUid(uid)) {
    throw new HttpsError('permission-denied', 'Super admin only.');
  }
  return uid;
}

/** An account that currently holds Coach Mode (super admin always does). */
async function requireActiveCoach(uid) {
  if (M.isSuperAdminUid(uid)) return;
  const snap = await entitlementRef(uid).get();
  if (!M.entitlementIsActive(snap.exists ? snap.data() : null)) {
    throw new HttpsError('permission-denied', 'Coach Mode is not active on this account.');
  }
}

/** Converts a ValidationError into the callable contract's error shape. */
function asHttps(err) {
  if (err instanceof M.ValidationError) {
    const e = new HttpsError('invalid-argument', err.message, { field: err.field });
    return e;
  }
  return err;
}

function optionalReason(value, field) {
  return M.requireString(value, field || 'reason', { max: M.LIMITS.reason, required: false });
}

// ── Identity snapshots ──────────────────────────────────────────────────────

/**
 * Best-effort display identity for an account, from Auth plus the users doc.
 * Never throws — a snapshot is a convenience, not an authorisation input.
 */
async function identityFor(uid) {
  let displayName = '';
  let email = '';
  let photoUrl = '';
  try {
    const rec = await admin.auth().getUser(uid);
    displayName = rec.displayName || '';
    email = rec.email || '';
    photoUrl = rec.photoURL || '';
  } catch (err) {
    logger.debug('identityFor: auth lookup failed', { uid, error: String(err) });
  }
  try {
    const snap = await db.collection('users').doc(uid).get();
    const d = snap.exists ? (snap.data() || {}) : {};
    displayName = displayName
      || String(d.username || d.displayName || d.fullName || '');
    email = email || String(d.email || '');
  } catch (err) {
    logger.debug('identityFor: user doc read failed', { uid, error: String(err) });
  }
  return { uid, displayName, email, photoUrl };
}

/** Exact, normalized-email account lookup. Never exposed to non-coaches. */
async function uidForEmail(email) {
  try {
    const rec = await admin.auth().getUserByEmail(email);
    if (rec && rec.uid) return rec.uid;
  } catch (err) {
    if (!err || err.code !== 'auth/user-not-found') {
      logger.debug('uidForEmail: auth lookup error', { error: String(err) });
    }
  }
  // Fallback for accounts whose Auth email differs from their profile email.
  try {
    const q = await db.collection('users').where('email', '==', email).limit(2).get();
    if (q.size === 1) return q.docs[0].id;
  } catch (err) {
    logger.debug('uidForEmail: users query failed', { error: String(err) });
  }
  return null;
}

// ── Audit ───────────────────────────────────────────────────────────────────

/**
 * Records a security-relevant super-admin action. Server-owned: firestore.rules
 * denies all client writes and all client reads except the super admin's.
 */
async function writeAudit(actorUid, targetUid, action, metadata) {
  try {
    await auditCol().add({
      actorUid,
      targetUid,
      action,
      at: FV.serverTimestamp(),
      metadata: metadata || {},
    });
  } catch (err) {
    // Auditing must never break the action it records; it is logged instead.
    logger.error('coach mode audit write failed', { actorUid, targetUid, action, error: String(err) });
  }
}

// ── Claims ──────────────────────────────────────────────────────────────────

/**
 * Mirrors the entitlement onto the `isCoach` custom claim for fast client
 * routing. Reads the account's existing claims and writes them back merged —
 * unrelated claims are preserved, never clobbered.
 */
async function syncCoachClaim(uid, isCoach) {
  try {
    const rec = await admin.auth().getUser(uid);
    const next = M.mergeCoachClaim(rec.customClaims, isCoach);
    await admin.auth().setCustomUserClaims(uid, next);
    return next;
  } catch (err) {
    logger.error('coach claim sync failed', { uid, isCoach, error: String(err) });
    // The entitlement document remains authoritative; the claim is a mirror.
    return null;
  }
}

// ── Entitlement mutation (shared by grant / approve / suspend / revoke) ──────

/**
 * Applies an entitlement transition atomically and keeps the mirrored claim
 * and the invitation-safe coach profile in step. Idempotent: re-applying the
 * state the account already has succeeds without changing grant provenance.
 */
async function applyEntitlementState(targetUid, nextState, {
  actorUid, source, reason, action,
}) {
  const now = FV.serverTimestamp();

  const result = await db.runTransaction(async (tx) => {
    const ref = entitlementRef(targetUid);
    const snap = await tx.get(ref);
    const data = snap.exists ? (snap.data() || {}) : {};
    const coach = data.coach || null;
    const from = coach ? coach.state : null;

    if (from === nextState) {
      return { changed: false, from, to: nextState };
    }
    if (!M.canTransitionEntitlement(from, nextState)) {
      throw new HttpsError(
        'failed-precondition',
        'Cannot change Coach Mode from ' + (from || 'none') + ' to ' + nextState + '.',
      );
    }

    const nextCoach = Object.assign({}, coach || {}, {
      state: nextState,
      updatedAt: now,
    });

    if (nextState === 'active') {
      nextCoach.source = source || (coach && coach.source) || 'manual_review';
      nextCoach.grantedAt = now;
      nextCoach.grantedBy = actorUid;
      if (nextCoach.source === 'manual_review') {
        nextCoach.approvedAt = now;
        nextCoach.approvedBy = actorUid;
      }
      // Clear the terminal-state metadata so a restored coach is not shown
      // with a stale suspension/revocation reason.
      nextCoach.suspendedAt = null;
      nextCoach.suspendedBy = null;
      nextCoach.suspensionReason = null;
      nextCoach.revokedAt = null;
      nextCoach.revokedBy = null;
      nextCoach.revocationReason = null;
    } else if (nextState === 'suspended') {
      nextCoach.suspendedAt = now;
      nextCoach.suspendedBy = actorUid;
      nextCoach.suspensionReason = reason || '';
    } else if (nextState === 'revoked') {
      nextCoach.revokedAt = now;
      nextCoach.revokedBy = actorUid;
      nextCoach.revocationReason = reason || '';
    }

    tx.set(ref, { uid: targetUid, coach: nextCoach, updatedAt: now }, { merge: true });
    return { changed: true, from, to: nextState };
  });

  await syncCoachClaim(targetUid, nextState === 'active');

  if (nextState === 'active') {
    const id = await identityFor(targetUid);
    await profileRef(targetUid).set(
      Object.assign(M.buildCoachProfile(id), { updatedAt: now }),
      { merge: true },
    );
  }

  await writeAudit(actorUid, targetUid, action, {
    from: result.from,
    to: result.to,
    source: source || null,
    reason: reason || '',
    idempotent: !result.changed,
  });

  // A coach who is no longer active must stop maintaining analytics for the
  // athletes they can no longer see. This only disables reporting where no
  // authorising source remains; it never rebuilds or resets analytics.
  if (nextState !== 'active') {
    await reevaluateCoachRosterEnrollment(targetUid, 'entitlement-' + nextState);
  }

  return result;
}

/**
 * Disables reporting for every athlete this coach still has enabled but can no
 * longer access. Bounded by the coach's own reporting-enabled settings docs.
 */
async function reevaluateCoachRosterEnrollment(coachUid, reason) {
  let coachIndex;
  try {
    coachIndex = require('./index');
  } catch (err) {
    logger.error('coach index load failed for enrollment cleanup', { error: String(err) });
    return;
  }
  const reevaluate = coachIndex
    && coachIndex._internals
    && coachIndex._internals.reevaluateEnrollment;
  if (typeof reevaluate !== 'function') return;

  try {
    const q = await db.collection('coachCheckIns').doc(coachUid)
      .collection('athletes').where('reportingEnabled', '==', true).get();
    for (const doc of q.docs) {
      try {
        await reevaluate(coachUid, doc.id, reason);
      } catch (err) {
        logger.error('enrollment cleanup failed', { coachUid, athleteUid: doc.id, error: String(err) });
      }
    }
  } catch (err) {
    logger.error('enrollment cleanup query failed', { coachUid, error: String(err) });
  }
}

// ══════════════════════════════════════════════════════════════════════════
// 1. Applicant callables
// ══════════════════════════════════════════════════════════════════════════

/**
 * Submit or resubmit the caller's own coach application.
 * Any signed-in account may apply, including one whose membership is
 * currently inactive — Coach Mode application is not gated by the paywall.
 */
const coachModeSubmitApplication = onCall(CALLABLE_OPTS, async (request) => {
  const uid = requireAuth(request);

  let answers;
  try {
    answers = M.validateApplication(request.data);
  } catch (err) {
    throw asHttps(err);
  }

  const identity = await identityFor(uid);
  const now = FV.serverTimestamp();

  return db.runTransaction(async (tx) => {
    const ref = applicationRef(uid);
    const snap = await tx.get(ref);
    const existing = snap.exists ? (snap.data() || {}) : null;
    const from = existing ? existing.status : null;

    if (!M.canSubmitApplication(from)) {
      throw new HttpsError(
        'failed-precondition',
        from === 'approved'
          ? 'Coach Mode is already approved on this account.'
          : 'An application is already awaiting review.',
      );
    }

    tx.set(ref, {
      uid,
      status: 'submitted',
      answers,
      applicantSnapshot: M.buildPartySnapshot(identity),
      submittedAt: now,
      updatedAt: now,
      submissionCount: FV.increment(1),
      // A resubmission answers any outstanding information request.
      infoRequest: null,
      decisionReason: null,
      reviewedAt: null,
      reviewedBy: null,
    }, { merge: true });

    return { status: 'submitted', previousStatus: from };
  });
});

/** Withdraw the caller's own pending application. */
const coachModeWithdrawApplication = onCall(CALLABLE_OPTS, async (request) => {
  const uid = requireAuth(request);
  const now = FV.serverTimestamp();

  return db.runTransaction(async (tx) => {
    const ref = applicationRef(uid);
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new HttpsError('not-found', 'No application to withdraw.');
    }
    const from = (snap.data() || {}).status || null;
    if (from === 'withdrawn') return { status: 'withdrawn', previousStatus: from };
    if (!M.canTransitionApplication(from, 'withdrawn')) {
      throw new HttpsError('failed-precondition', 'This application can no longer be withdrawn.');
    }
    tx.set(ref, { status: 'withdrawn', updatedAt: now, withdrawnAt: now }, { merge: true });
    return { status: 'withdrawn', previousStatus: from };
  });
});

// ══════════════════════════════════════════════════════════════════════════
// 2. Super-admin review + entitlement callables
// ══════════════════════════════════════════════════════════════════════════

const REVIEW_ACTIONS = Object.freeze({
  approve: 'approved',
  decline: 'declined',
  request_info: 'more_info_requested',
});

/** Super admin reviews an application: approve / decline / request more info. */
const coachModeReviewApplication = onCall(CALLABLE_OPTS, async (request) => {
  const actorUid = requireSuperAdmin(request);
  const d = request.data || {};

  let applicantUid;
  let action;
  let reason;
  try {
    applicantUid = M.requireString(d.applicantUid, 'applicantUid', { max: 128 });
    action = M.requireEnum(d.action, 'action', Object.keys(REVIEW_ACTIONS));
    reason = optionalReason(d.reason);
  } catch (err) {
    throw asHttps(err);
  }

  const nextStatus = REVIEW_ACTIONS[action];
  const now = FV.serverTimestamp();

  const outcome = await db.runTransaction(async (tx) => {
    const ref = applicationRef(applicantUid);
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError('not-found', 'Application not found.');
    const from = (snap.data() || {}).status || null;

    // Idempotent: reviewing to the status it already holds is a no-op.
    if (from === nextStatus) return { changed: false, from, to: nextStatus };

    if (!M.canTransitionApplication(from, nextStatus)) {
      throw new HttpsError(
        'failed-precondition',
        'Cannot move an application from ' + (from || 'none') + ' to ' + nextStatus + '.',
      );
    }

    const patch = {
      status: nextStatus,
      updatedAt: now,
      reviewedAt: now,
      reviewedBy: actorUid,
    };
    if (nextStatus === 'more_info_requested') {
      patch.infoRequest = reason;
      patch.decisionReason = null;
    } else {
      patch.decisionReason = reason;
      patch.infoRequest = null;
    }
    tx.set(ref, patch, { merge: true });
    return { changed: true, from, to: nextStatus };
  });

  if (nextStatus === 'approved') {
    // Approval grants the real entitlement; the application itself never
    // authorises anything.
    await applyEntitlementState(applicantUid, 'active', {
      actorUid,
      source: 'manual_review',
      reason,
      action: 'application_approved',
    });
  } else {
    await writeAudit(actorUid, applicantUid, 'application_' + action, {
      from: outcome.from,
      to: outcome.to,
      reason,
      idempotent: !outcome.changed,
    });
  }

  return { status: nextStatus, previousStatus: outcome.from };
});

/**
 * Super admin grants Coach Mode directly to an existing account, with or
 * without an application. This is the documented escape hatch that replaces
 * adding UIDs to hard-coded lists and redeploying.
 */
const coachModeGrantCoach = onCall(CALLABLE_OPTS, async (request) => {
  const actorUid = requireSuperAdmin(request);
  const d = request.data || {};

  let targetUid = null;
  let reason;
  try {
    reason = optionalReason(d.reason);
    if (d.targetUid !== undefined && d.targetUid !== null && d.targetUid !== '') {
      targetUid = M.requireString(d.targetUid, 'targetUid', { max: 128 });
    } else {
      const email = M.requireEmail(d.email, 'email');
      targetUid = await uidForEmail(email);
      if (!targetUid) throw new HttpsError('not-found', 'No GoodLift account uses that email.');
    }
  } catch (err) {
    throw asHttps(err);
  }

  if (M.isSuperAdminUid(targetUid)) {
    // Super admin access is the hard-coded constant, never an entitlement.
    throw new HttpsError(
      'failed-precondition',
      'The super admin already has full access and does not use an entitlement.',
    );
  }

  const result = await applyEntitlementState(targetUid, 'active', {
    actorUid,
    source: 'super_admin_grant',
    reason,
    action: 'direct_grant',
  });
  return { targetUid, state: 'active', changed: result.changed };
});

const STATE_ACTIONS = Object.freeze({
  suspend: 'suspended',
  revoke: 'revoked',
  restore: 'active',
});

/** Super admin suspends, revokes or restores Coach Mode. */
const coachModeSetCoachState = onCall(CALLABLE_OPTS, async (request) => {
  const actorUid = requireSuperAdmin(request);
  const d = request.data || {};

  let targetUid;
  let action;
  let reason;
  try {
    targetUid = M.requireString(d.targetUid, 'targetUid', { max: 128 });
    action = M.requireEnum(d.action, 'action', Object.keys(STATE_ACTIONS));
    reason = optionalReason(d.reason);
  } catch (err) {
    throw asHttps(err);
  }

  if (M.isSuperAdminUid(targetUid)) {
    throw new HttpsError('failed-precondition', 'Super admin access cannot be changed.');
  }

  const nextState = STATE_ACTIONS[action];
  const result = await applyEntitlementState(targetUid, nextState, {
    actorUid,
    source: nextState === 'active' ? 'super_admin_grant' : undefined,
    reason,
    action: 'coach_' + action,
  });
  return { targetUid, state: nextState, changed: result.changed };
});

/**
 * Super-admin-only account lookup used by the direct-grant UI.
 * Deliberately NOT a general search endpoint: it is unreachable for every
 * other account, so it cannot be used for email enumeration.
 */
const coachModeAdminLookupAccount = onCall(CALLABLE_OPTS, async (request) => {
  requireSuperAdmin(request);
  let email;
  try {
    email = M.requireEmail((request.data || {}).email, 'email');
  } catch (err) {
    throw asHttps(err);
  }
  const uid = await uidForEmail(email);
  if (!uid) return { found: false };
  const [identity, entSnap] = await Promise.all([identityFor(uid), entitlementRef(uid).get()]);
  const coach = entSnap.exists ? ((entSnap.data() || {}).coach || null) : null;
  return {
    found: true,
    uid,
    displayName: identity.displayName,
    email: identity.email,
    coachState: coach ? coach.state : null,
    coachSource: coach ? (coach.source || null) : null,
    isSuperAdmin: M.isSuperAdminUid(uid),
  };
});

// ══════════════════════════════════════════════════════════════════════════
// 3. Relationship callables
// ══════════════════════════════════════════════════════════════════════════

/**
 * Approved coach invites an athlete by exact normalized email.
 * Rejects self-invites and duplicate pending/active invitations, and applies a
 * sliding-window rate limit so the invitation path cannot be used to probe
 * which emails have accounts.
 */
const coachModeInviteAthlete = onCall(CALLABLE_OPTS, async (request) => {
  const coachUid = requireAuth(request);
  await requireActiveCoach(coachUid);

  let email;
  try {
    email = M.requireEmail((request.data || {}).athleteEmail, 'athleteEmail');
  } catch (err) {
    throw asHttps(err);
  }

  // Rate limit BEFORE the account lookup, so a throttled coach learns nothing
  // about whether the email exists.
  const nowMs = Date.now();
  await db.runTransaction(async (tx) => {
    const ref = entitlementRef(coachUid);
    const snap = await tx.get(ref);
    const data = snap.exists ? (snap.data() || {}) : {};
    const recent = (data.coachInviteRate && data.coachInviteRate.recentMs) || [];
    const decision = M.inviteRateDecision(recent, nowMs);
    if (!decision.allowed) {
      throw new HttpsError('resource-exhausted', 'Too many invitations sent today. Try again tomorrow.');
    }
    tx.set(ref, { coachInviteRate: { recentMs: decision.retained } }, { merge: true });
  });

  const athleteUid = await uidForEmail(email);
  if (!athleteUid) throw new HttpsError('not-found', 'No GoodLift account uses that email.');
  if (athleteUid === coachUid) {
    throw new HttpsError('invalid-argument', 'You cannot invite yourself.');
  }

  const [coachIdentity, athleteIdentity] = await Promise.all([
    identityFor(coachUid), identityFor(athleteUid),
  ]);
  const now = FV.serverTimestamp();

  const outcome = await db.runTransaction(async (tx) => {
    const ref = linkRef(coachUid, athleteUid);
    const snap = await tx.get(ref);
    const from = snap.exists ? ((snap.data() || {}).status || null) : null;

    if (from === 'pending') {
      return { status: 'pending', changed: false };
    }
    if (from === 'active') {
      throw new HttpsError('already-exists', 'This athlete is already on your roster.');
    }
    if (!M.canTransitionLink(from, 'pending')) {
      throw new HttpsError('failed-precondition', 'Cannot invite this athlete right now.');
    }

    tx.set(ref, {
      coachUid,
      athleteUid,
      status: 'pending',
      coachSnapshot: M.buildPartySnapshot(coachIdentity),
      athleteSnapshot: M.buildPartySnapshot(athleteIdentity),
      requestedAt: now,
      requestedBy: coachUid,
      respondedAt: null,
      respondedBy: null,
      endedAt: null,
      endedBy: null,
      lastAction: 'invited',
      lastActorUid: coachUid,
      reason: null,
      createdAt: snap.exists ? (snap.data().createdAt || now) : now,
      updatedAt: now,
    }, { merge: true });

    return { status: 'pending', changed: true, previousStatus: from };
  });

  // Keep the invitation-safe coach profile fresh so the athlete can identify
  // who is asking without any access to the coach's application.
  await profileRef(coachUid).set(
    Object.assign(M.buildCoachProfile(coachIdentity), { updatedAt: now }),
    { merge: true },
  );

  return {
    linkId: M.linkId(coachUid, athleteUid),
    athleteUid,
    status: outcome.status,
    changed: outcome.changed,
  };
});

/**
 * Shared, transactional relationship transition.
 * The caller's role is derived from the link document itself, never from the
 * request, so a coach cannot accept on an athlete's behalf and vice versa.
 */
async function transitionLink({
  callerUid, coachUid, athleteUid, toStatus, actorRole, reason,
}) {
  const now = FV.serverTimestamp();
  return db.runTransaction(async (tx) => {
    const ref = linkRef(coachUid, athleteUid);
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError('not-found', 'Relationship not found.');
    const data = snap.data() || {};
    const from = data.status || null;

    // Authorise against the stored parties, not the request payload.
    const expected = actorRole === 'coach' ? data.coachUid : data.athleteUid;
    if (expected !== callerUid) {
      throw new HttpsError('permission-denied', 'Not a party to this relationship.');
    }
    if (!M.actorMayDriveLink(toStatus, actorRole)) {
      throw new HttpsError('permission-denied', 'This action is not available to you.');
    }

    // Idempotent: repeating the transition that already happened succeeds.
    if (from === toStatus) return { status: toStatus, changed: false, previousStatus: from };

    if (!M.canTransitionLink(from, toStatus)) {
      throw new HttpsError(
        'failed-precondition',
        'This invitation has already been ' + (from || 'removed') + '.',
      );
    }

    const patch = {
      status: toStatus,
      lastAction: toStatus,
      lastActorUid: callerUid,
      reason: reason || null,
      updatedAt: now,
    };
    if (toStatus === 'active' || toStatus === 'declined') {
      patch.respondedAt = now;
      patch.respondedBy = callerUid;
    }
    if (M.LINK_TERMINAL_STATUSES.includes(toStatus)) {
      patch.endedAt = now;
      patch.endedBy = callerUid;
    }
    tx.set(ref, patch, { merge: true });
    return { status: toStatus, changed: true, previousStatus: from };
  });
}

/** Coach cancels a pending invitation. */
const coachModeCancelInvite = onCall(CALLABLE_OPTS, async (request) => {
  const coachUid = requireAuth(request);
  let athleteUid;
  try {
    athleteUid = M.requireString((request.data || {}).athleteUid, 'athleteUid', { max: 128 });
  } catch (err) {
    throw asHttps(err);
  }
  return transitionLink({
    callerUid: coachUid, coachUid, athleteUid,
    toStatus: 'cancelled', actorRole: 'coach',
  });
});

/** Athlete accepts or declines an invitation. */
const coachModeRespondToInvite = onCall(CALLABLE_OPTS, async (request) => {
  const athleteUid = requireAuth(request);
  const d = request.data || {};
  let coachUid;
  let action;
  try {
    coachUid = M.requireString(d.coachUid, 'coachUid', { max: 128 });
    action = M.requireEnum(d.action, 'action', ['accept', 'decline']);
  } catch (err) {
    throw asHttps(err);
  }

  const result = await transitionLink({
    callerUid: athleteUid, coachUid, athleteUid,
    toStatus: action === 'accept' ? 'active' : 'declined',
    actorRole: 'athlete',
  });

  if (result.status !== 'active') {
    await reevaluateLinkEnrollment(coachUid, athleteUid, 'relationship-' + result.status);
  }
  return result;
});

/** Athlete revokes an active coach. */
const coachModeRevokeCoach = onCall(CALLABLE_OPTS, async (request) => {
  const athleteUid = requireAuth(request);
  const d = request.data || {};
  let coachUid;
  let reason;
  try {
    coachUid = M.requireString(d.coachUid, 'coachUid', { max: 128 });
    reason = optionalReason(d.reason);
  } catch (err) {
    throw asHttps(err);
  }
  const result = await transitionLink({
    callerUid: athleteUid, coachUid, athleteUid,
    toStatus: 'revoked_by_athlete', actorRole: 'athlete', reason,
  });
  await reevaluateLinkEnrollment(coachUid, athleteUid, 'relationship-revoked');
  return result;
});

/** Coach releases an active athlete. */
const coachModeReleaseAthlete = onCall(CALLABLE_OPTS, async (request) => {
  const coachUid = requireAuth(request);
  const d = request.data || {};
  let athleteUid;
  let reason;
  try {
    athleteUid = M.requireString(d.athleteUid, 'athleteUid', { max: 128 });
    reason = optionalReason(d.reason);
  } catch (err) {
    throw asHttps(err);
  }
  const result = await transitionLink({
    callerUid: coachUid, coachUid, athleteUid,
    toStatus: 'released_by_coach', actorRole: 'coach', reason,
  });
  await reevaluateLinkEnrollment(coachUid, athleteUid, 'relationship-released');
  return result;
});

/**
 * Legacy seeded-assignment removal — REMOVAL ONLY.
 * Coaches can no longer write coachAssignments directly (that was the
 * self-seeding hole). This callable lets a coach drop a super-admin-seeded
 * athlete from their own roster, and lets the super admin drop any; it can
 * never add an entry.
 */
const coachModeRemoveSeededAthlete = onCall(CALLABLE_OPTS, async (request) => {
  const callerUid = requireAuth(request);
  const d = request.data || {};
  let athleteUid;
  let coachUid;
  try {
    athleteUid = M.requireString(d.athleteUid, 'athleteUid', { max: 128 });
    coachUid = d.coachUid
      ? M.requireString(d.coachUid, 'coachUid', { max: 128 })
      : callerUid;
  } catch (err) {
    throw asHttps(err);
  }

  if (coachUid !== callerUid && !M.isSuperAdminUid(callerUid)) {
    throw new HttpsError('permission-denied', 'You may only edit your own roster.');
  }

  const ref = db.collection('coachAssignments').doc(coachUid);
  const removed = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return false;
    const athletes = (snap.data() || {}).athletes || {};
    if (athletes[athleteUid] === undefined) return false;
    // Field-path delete only: no code path here can ever add an athlete.
    tx.update(ref, { ['athletes.' + athleteUid]: FV.delete() });
    return true;
  });

  await reevaluateLinkEnrollment(coachUid, athleteUid, 'seeded-assignment-removed');
  return { coachUid, athleteUid, removed };
});

/**
 * Re-evaluates one relationship's analytics enrollment after a status change.
 * Delegates to the existing reevaluateEnrollment, which disables reporting
 * only when NO authorising source remains and never fabricates, resets or
 * rebuilds analytics.
 */
async function reevaluateLinkEnrollment(coachUid, athleteUid, reason) {
  let coachIndex;
  try {
    coachIndex = require('./index');
  } catch (err) {
    logger.error('coach index load failed', { error: String(err) });
    return;
  }
  const reevaluate = coachIndex
    && coachIndex._internals
    && coachIndex._internals.reevaluateEnrollment;
  if (typeof reevaluate !== 'function') return;
  try {
    await reevaluate(coachUid, athleteUid, reason);
  } catch (err) {
    logger.error('link enrollment cleanup failed', { coachUid, athleteUid, error: String(err) });
  }
}

// ══════════════════════════════════════════════════════════════════════════
// 4. Triggers
// ══════════════════════════════════════════════════════════════════════════

/**
 * Immediate analytics cleanup when a canonical relationship leaves `active`.
 * Activation deliberately does nothing here: reporting stays opt-in through
 * the existing coachCheckIns settings flow, preserving the current
 * reporting-enabled and bootstrap semantics.
 */
const coachOnCoachAthleteLinkWritten = onDocumentWritten(
  M.COL_LINKS + '/{linkDocId}',
  async (event) => {
    const parsed = M.parseLinkId(event.params.linkDocId);
    if (!parsed) return;
    const before = event.data.before.exists ? (event.data.before.data() || {}) : {};
    const after = event.data.after.exists ? (event.data.after.data() || {}) : {};
    const wasActive = before.status === 'active';
    const isActive = after.status === 'active';
    if (!wasActive || isActive) return;
    await reevaluateLinkEnrollment(
      parsed.coachUid, parsed.athleteUid,
      'relationship-' + (after.status || 'deleted'),
    );
  },
);

/**
 * Immediate analytics cleanup when a coach's entitlement leaves `active`
 * (suspension or revocation). Bounded by that coach's reporting-enabled
 * athletes.
 */
const coachOnAccountEntitlementWritten = onDocumentWritten(
  M.COL_ENTITLEMENTS + '/{uid}',
  async (event) => {
    const uid = event.params.uid;
    const before = event.data.before.exists ? (event.data.before.data() || {}) : {};
    const after = event.data.after.exists ? (event.data.after.data() || {}) : {};
    if (!M.entitlementIsActive(before)) return;
    if (M.entitlementIsActive(after)) return;
    const state = (after.coach && after.coach.state) || 'removed';
    await reevaluateCoachRosterEnrollment(uid, 'entitlement-' + state);
  },
);

module.exports = {
  coachModeSubmitApplication,
  coachModeWithdrawApplication,
  coachModeReviewApplication,
  coachModeGrantCoach,
  coachModeSetCoachState,
  coachModeAdminLookupAccount,
  coachModeInviteAthlete,
  coachModeCancelInvite,
  coachModeRespondToInvite,
  coachModeRevokeCoach,
  coachModeReleaseAthlete,
  coachModeRemoveSeededAthlete,
  coachOnCoachAthleteLinkWritten,
  coachOnAccountEntitlementWritten,
  // Exported for tests (not deployed as functions):
  _internals: {
    applyEntitlementState,
    transitionLink,
    identityFor,
    uidForEmail,
    syncCoachClaim,
    reevaluateCoachRosterEnrollment,
    reevaluateLinkEnrollment,
    writeAudit,
    CALLABLE_OPTS,
  },
};
