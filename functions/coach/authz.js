// Coach⇄athlete authorization — the single backend implementation of the
// repository's real assignment/approval model, matching the Coach Dashboard
// and the Firestore rules exactly.
//
// THE RULE — an ACTIVE coach entitlement is MANDATORY for every ordinary
// authorization source. The hard-coded super admin is the sole unconditional
// bypass; for everyone else a suspended, revoked, missing or malformed
// accountEntitlements/{coachUid} denies athlete access outright, even when a
// legacy assignment exists.
//
// Given an active entitlement, any ONE of these authorises the pair:
//
//   CANONICAL:
//     coachAthleteLinks/{coachUid}__{athleteUid}.status == 'active'
//
//   LEGACY (compatibility release only — see docs/coach_mode.md §8):
//     1. Super-admin-seeded roster: coachAssignments/{coachUid}.athletes[athleteUid]
//        – any non-null entry. ONLY the hard-coded super admin may create
//          these; an ordinary coach can no longer seed athletes into their own
//          roster. Not overridden by a terminal canonical link.
//     2. Athlete-approved flow: athleteAssignments/{athleteUid}
//          .coaches[coachUid].approved === true
//        – ONLY an explicit boolean true. Pending requests, approved:false,
//          malformed entries or mere key presence do not.
//        – OVERRIDDEN by a terminal canonical link (declined / cancelled /
//          revoked_by_athlete / released_by_coach): the link is the newer,
//          explicit decision, so an athlete revocation or coach release is not
//          silently undone by the stale approval flag it was migrated from.
//
// The legacy collections may narrow WHICH athletes a coach reaches, but they
// can never confer coach status — historically coachAssignments was
// self-writable, so trusting it alone was the original vulnerability.

'use strict';

const {
  SUPER_ADMIN_UID,
  isSuperAdminUid,
  COL_ENTITLEMENTS,
  COL_LINKS,
  entitlementIsActive,
  linkIsActive,
  linkIsTerminal,
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
 * Names the source that authorised (or would authorise) a coach⇄athlete pair.
 * Returned by evaluateAssignmentDetail so roster removal can be source-aware
 * and truthful about what still grants access.
 *
 *   'super_admin'      the hard-coded super admin — unconditional
 *   'canonical'        active entitlement + active coachAthleteLinks doc
 *   'legacy_seeded'    super-admin-seeded coachAssignments entry
 *   'legacy_approved'  athleteAssignments coaches[uid].approved === true
 */
const SOURCE_SUPER_ADMIN = 'super_admin';
const SOURCE_CANONICAL = 'canonical';
const SOURCE_LEGACY_SEEDED = 'legacy_seeded';
const SOURCE_LEGACY_APPROVED = 'legacy_approved';

/**
 * Full pure evaluation over every assignment source's data (any may be null).
 * Returns { authorised, sources, entitlementActive, linkTerminal } so callers
 * can both decide access AND explain it.
 *
 * THE RULE, in order:
 *
 *  1. The hard-coded super admin is the ONLY unconditional bypass.
 *
 *  2. Every other account MUST hold an ACTIVE coach entitlement. A suspended,
 *     revoked, missing or malformed entitlement denies everything — including
 *     when a legacy seeded assignment or a legacy approved entry exists. The
 *     legacy collections were never a trustworthy grant of Coach Mode
 *     (historically `coachAssignments` was self-writable), so they may narrow
 *     which athletes a coach reaches but can never confer coach status.
 *
 *  3. Given an active entitlement, any of these authorises the pair:
 *       • an ACTIVE canonical link, or
 *       • a super-admin-seeded assignment, or
 *       • a legacy approved entry — UNLESS a canonical link records a
 *         deliberate termination, which is the newer explicit decision and
 *         wins over the stale approval flag it was migrated from.
 *
 *     A seeded assignment is deliberately NOT overridden by a terminal link:
 *     seeding is an admin-controlled compatibility path that only the super
 *     admin can create, and this pass does not redesign it.
 */
function evaluateAssignmentDetail({
  coachAssignData,
  athleteAssignData,
  entitlementData,
  linkData,
  coachUid,
  athleteUid,
}) {
  if (isSuperAdmin(coachUid)) {
    return {
      authorised: true,
      sources: [SOURCE_SUPER_ADMIN],
      entitlementActive: true,
      linkTerminal: false,
    };
  }

  const entitlementActive = entitlementIsActive(entitlementData);
  const linkTerminal = linkIsTerminal(linkData);

  const seeded = coachAssignData && coachAssignData.athletes
    ? coachAssignData.athletes[athleteUid] : undefined;
  const approved = athleteAssignData && athleteAssignData.coaches
    ? athleteAssignData.coaches[coachUid] : undefined;

  // Which sources WOULD authorise if the entitlement were active. Computed
  // regardless so removal flows can report what is still present.
  const sources = [];
  if (linkIsActive(linkData)) sources.push(SOURCE_CANONICAL);
  if (seededEntryAuthorises(seeded)) sources.push(SOURCE_LEGACY_SEEDED);
  // A terminal canonical link cancels a stale legacy approval, but never a
  // super-admin seed.
  if (approvedEntryAuthorises(approved) && !linkTerminal) {
    sources.push(SOURCE_LEGACY_APPROVED);
  }

  return {
    // Active entitlement is mandatory for EVERY ordinary source.
    authorised: entitlementActive && sources.length > 0,
    sources,
    entitlementActive,
    linkTerminal,
  };
}

/**
 * Pure boolean evaluation over every assignment source's data.
 * Used by the db-backed check below and directly by unit tests.
 */
function evaluateAssignment(args) {
  return evaluateAssignmentDetail(args).authorised;
}

/** Reads all four assignment sources for one pair. */
async function loadAssignmentData(db, coachUid, athleteUid) {
  const [ca, aa, ent, link] = await Promise.all([
    db.collection('coachAssignments').doc(coachUid).get(),
    db.collection('athleteAssignments').doc(athleteUid).get(),
    db.collection(COL_ENTITLEMENTS).doc(coachUid).get(),
    db.collection(COL_LINKS).doc(linkId(coachUid, athleteUid)).get(),
  ]);
  return {
    coachAssignData: ca.exists ? ca.data() : null,
    athleteAssignData: aa.exists ? aa.data() : null,
    entitlementData: ent.exists ? ent.data() : null,
    linkData: link.exists ? link.data() : null,
    coachUid,
    athleteUid,
  };
}

/** Db-backed check used by triggers, scheduler and every athlete-specific
 *  callable at invocation time. */
async function isCoachFor(db, coachUid, athleteUid) {
  if (isSuperAdmin(coachUid)) return true; // no assignment reads needed
  return evaluateAssignment(await loadAssignmentData(db, coachUid, athleteUid));
}

/** Db-backed detail used by the source-aware roster-removal callable. */
async function describeCoachFor(db, coachUid, athleteUid) {
  if (isSuperAdmin(coachUid)) {
    return {
      authorised: true,
      sources: [SOURCE_SUPER_ADMIN],
      entitlementActive: true,
      linkTerminal: false,
    };
  }
  return evaluateAssignmentDetail(await loadAssignmentData(db, coachUid, athleteUid));
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
  evaluateAssignmentDetail,
  isCoachFor,
  describeCoachFor,
  loadAssignmentData,
  hasActiveCoachEntitlement,
  SOURCE_SUPER_ADMIN,
  SOURCE_CANONICAL,
  SOURCE_LEGACY_SEEDED,
  SOURCE_LEGACY_APPROVED,
};
