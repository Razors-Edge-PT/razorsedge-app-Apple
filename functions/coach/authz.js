// Coach⇄athlete authorization — the single backend implementation of the
// repository's real assignment/approval model, matching CoachHomeScreen and
// the Firestore rules exactly:
//
//   1. Admin-seeded roster:   coachAssignments/{coachUid}.athletes[athleteUid]
//      – any non-null entry is a valid seeded assignment (the app treats the
//        seeded map as authoritative; entries are objects like {email}).
//   2. Athlete-approved flow: athleteAssignments/{athleteUid}
//        .coaches[coachUid].approved === true
//      – ONLY an explicit boolean true grants access. Pending requests,
//        approved:false, malformed entries or mere key presence do not.
//
// Either source alone authorises; both removed ⇒ revoked. Superadmin is
// handled by rules / hardcoded app lists, not here — server code runs with
// Admin SDK privileges and performs its own checks with this module.

'use strict';

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
 * Pure evaluation over both assignment documents' data (either may be null).
 * Used by the db-backed check below and directly by unit tests.
 */
function evaluateAssignment({ coachAssignData, athleteAssignData, coachUid, athleteUid }) {
  const seeded = coachAssignData && coachAssignData.athletes
    ? coachAssignData.athletes[athleteUid] : undefined;
  if (seededEntryAuthorises(seeded)) return true;
  const approved = athleteAssignData && athleteAssignData.coaches
    ? athleteAssignData.coaches[coachUid] : undefined;
  return approvedEntryAuthorises(approved);
}

/** Db-backed check used by triggers, scheduler and every athlete-specific
 *  callable at invocation time. */
async function isCoachFor(db, coachUid, athleteUid) {
  const [ca, aa] = await Promise.all([
    db.collection('coachAssignments').doc(coachUid).get(),
    db.collection('athleteAssignments').doc(athleteUid).get(),
  ]);
  return evaluateAssignment({
    coachAssignData: ca.exists ? ca.data() : null,
    athleteAssignData: aa.exists ? aa.data() : null,
    coachUid,
    athleteUid,
  });
}

module.exports = {
  seededEntryAuthorises,
  approvedEntryAuthorises,
  evaluateAssignment,
  isCoachFor,
};
