'use strict';

// The support profile + DM override, server side.
//
// accessGrants/{uid} { profileAndDmOverride: true } is written only by
// scripts/grant_profile_dm_override.js (Admin SDK); firestore.rules forbids
// every client write. It lets the holder read profiles as a friend would and
// hold a one-to-one conversation with anyone. Here it only decides whether a
// DM between two accounts may be delivered without a friendship — it never
// creates, changes or implies one.

const COL_ACCESS_GRANTS = 'accessGrants';
const FIELD_PROFILE_DM_OVERRIDE = 'profileAndDmOverride';

/** True when [uid] holds the support profile + DM override. */
async function hasProfileDmOverride(db, uid) {
  if (typeof uid !== 'string' || !uid) return false;
  const snap = await db.collection(COL_ACCESS_GRANTS).doc(uid).get();
  return snap.exists && snap.get(FIELD_PROFILE_DM_OVERRIDE) === true;
}

/** True when either of the two accounts holds the override. */
async function eitherHoldsOverride(db, a, b) {
  const [x, y] = await Promise.all([
    hasProfileDmOverride(db, a),
    hasProfileDmOverride(db, b),
  ]);
  return x || y;
}

module.exports = {
  COL_ACCESS_GRANTS,
  FIELD_PROFILE_DM_OVERRIDE,
  hasProfileDmOverride,
  eitherHoldsOverride,
};
