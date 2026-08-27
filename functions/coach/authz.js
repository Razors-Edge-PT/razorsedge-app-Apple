// Coach⇄athlete authorization — the single backend implementation of the
// repository's real assignment/approval model, matching the Coach Dashboard
// and the Firestore rules exactly.
//
// CANONICAL (new — Coach Mode):
//   coachAthleteLinks/{coachUid}__{athleteUid}.status == 'active'
//   AND accountEntitlements/{coachUid}.coach.state == 'active'
//   Both are required. A suspended or revoked coach loses athlete access even
//   though the link document still exists.
//
// LEGACY (still honoured during the compatibility release):
//   1. Super-admin-seeded roster: coachAssignments/{coachUid}.athletes[athleteUid]
//      – any non-null entry is a valid seeded assignment. Only the hard-coded
//        super admin may create these (enforced in rules + callables); an
//        ordinary coach can no longer seed athletes into their own roster.
//   2. Athlete-approved flow: athleteAssignments/{athleteUid}
//        .coaches[coachUid].approved === true
//      – ONLY an explicit boolean true grants access. Pending requests,
//        approved:false, malformed entries or mere key presence do not.
//
// Any authorising source alone grants access; all removed ⇒ revoked.
// Super admin is handled by the hard-coded UID and never needs any document.

'use strict';

const {
  SUPER_ADMIN_UID,
  isSuperAdminUid,
  COL_ENTITLEMENTS,
  COL_LINKS,
  entitlementIsActive,
  linkIsActive,
  linkId,
} = require('./coach_mode_model');

// Super-admin: the same single hardcoded UID used by firestore.rules
// (isSuperAdmin()), coach_mode_model.js and the Flutter client
// (UserContext.isSuperAdmin). The super-admin is effectively coach for every
// athlete and therefore does not need an ordinary assignment document.
// Keeping one constant — rather than inventing a second authorisation source —
// means all three layers agree.
const SUPER_ADMIN_UIDS = Object.freeze([SUPER_ADMIN_UID]); // Richard

function isSuperAdmin(uid) {
  return isSuperAdminUid(uid);
}

/** Pure: does a coachAssignments athletes-map entry authorise? */
function seededEntryAuthorises(entry) {
  return entry !== null && entry !== undefined;
}

/** Pure: does an athleteAssignments coaches-map entry authorise?
 *  Strictly requires approved === true on an object entry. */
function approvedEntryAuthorises(entry) {
  return !!(entry && typeof entry === 'object' && entry.approved === true);
}

/**
 * Pure: does the canonical Coach Mode pair authorise?
 * Requires BOTH an active coach entitlement and an active relationship, so a
 * suspended/revoked coach is denied even with a stale active link, and a
 * pending/declined/cancelled/released/revoked link never grants access.
 */
function canonicalAuthorises(entitlementData, linkData) {
  return entitlementIsActive(entitlementData) && linkIsActive(linkData);
}

/**
 * Pure evaluation over every assignment source's data (any may be null).
 * Used by the db-backed check below and directly by unit tests.
 */
function evaluateAssignment({
  coachAssignData,
  athleteAssignData,
  entitlementData,
  linkData,
  coachUid,
  athleteUid,
}) {
  if (isSuperAdmin(coachUid)) return true;

  // Canonical first — this is the path all new UI and callables use.
  if (canonicalAuthorises(entitlementData, linkData)) return true;

  // Legacy super-admin-seeded roster.
  const seeded = coachAssignData && coachAssignData.athletes
    ? coachAssignData.athletes[athleteUid] : undefined;
  if (seededEntryAuthorises(seeded)) return true;

  // Legacy athlete-approved flow.
  const approved = athleteAssignData && athleteAssignData.coaches
    ? athleteAssignData.coaches[coachUid] : undefined;
  return approvedEntryAuthorises(approved);
}

/** Db-backed check used by triggers, scheduler and every athlete-specific
 *  callable at invocation time. */
async function isCoachFor(db, coachUid, athleteUid) {
  if (isSuperAdmin(coachUid)) return true; // no assignment reads needed
  const [ca, aa, ent, link] = await Promise.all([
    db.collection('coachAssignments').doc(coachUid).get(),
    db.collection('athleteAssignments').doc(athleteUid).get(),
    db.collection(COL_ENTITLEMENTS).doc(coachUid).get(),
    db.collection(COL_LINKS).doc(linkId(coachUid, athleteUid)).get(),
  ]);
  return evaluateAssignment({
    coachAssignData: ca.exists ? ca.data() : null,
    athleteAssignData: aa.exists ? aa.data() : null,
    entitlementData: ent.exists ? ent.data() : null,
    linkData: link.exists ? link.data() : null,
    coachUid,
    athleteUid,
  });
}

/**
 * Does this account currently hold Coach Mode at all (independent of any
 * particular athlete)? Super admin always does. Everyone else needs an
 * active entitlement document.
 */
async function hasActiveCoachEntitlement(db, uid) {
  if (isSuperAdmin(uid)) return true;
  const snap = await db.collection(COL_ENTITLEMENTS).doc(uid).get();
  return entitlementIsActive(snap.exists ? snap.data() : null);
}

module.exports = {
  SUPER_ADMIN_UIDS,
  SUPER_ADMIN_UID,
  isSuperAdmin,
  seededEntryAuthorises,
  approvedEntryAuthorises,
  canonicalAuthorises,
  evaluateAssignment,
  isCoachFor,
  hasActiveCoachEntitlement,
};
