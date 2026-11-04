// Who may appear on the public RE Points leaderboards.
//
// Two independent gates, both enforced in the server-derived write path:
// client filtering alone would leave medals and rankings incorrect, and a
// later rebuild could otherwise publish an athlete again.
//
// 1. EXCLUDED_LEADERBOARD_UIDS — test/demo accounts whose deliberately
//    unrealistic lifts are useful inside the app but must never compete with
//    real athletes. Permanent; not user-changeable.
//
// 2. users/{uid}.leaderboardVisible — the athlete's own choice (Settings →
//    Profile → "Show me on leaderboards"). Only an explicit `false` hides; a
//    missing field (every existing and new account) is visible. Owner-written
//    (firestore.rules), so whatever the athlete last saved always wins — no
//    UID list here can override it. A one-time default for a specific
//    account is seeded by scripts/seed_leaderboard_visibility.js, which only
//    ever writes a field that is still absent.
//
// Hiding withdraws the athlete's public projections (entries, age entries,
// medals, website snapshots); it never touches rePointDays, the profile
// showcase, workouts or any other private input, so opting back in rebuilds
// every board from data that is still there.

'use strict';

const EXCLUDED_LEADERBOARD_UIDS = Object.freeze([
  'LWXGJ5SlIzM4OxEkOdTuv6d1c5b2', // Real Deal Money
  'jhIB7Yi1whYwPvBSmK27KltJGn23', // Richard_lifts_a_wholet
]);

/** The users/{uid} field holding the athlete's leaderboard choice. */
const LEADERBOARD_VISIBLE_FIELD = 'leaderboardVisible';

const excluded = new Set(EXCLUDED_LEADERBOARD_UIDS);

function isLeaderboardEligibleUid(uid) {
  return typeof uid === 'string' && uid.length > 0 && !excluded.has(uid);
}

/**
 * The athlete's saved choice from their users/{uid} data (null/undefined for
 * a missing document). Only an explicit boolean false hides.
 */
function isLeaderboardVisible(userData) {
  return !(userData && userData[LEADERBOARD_VISIBLE_FIELD] === false);
}

/** Both gates: not a test/demo account AND not opted out. */
function isLeaderboardEligible(uid, userData) {
  return isLeaderboardEligibleUid(uid) && isLeaderboardVisible(userData);
}

module.exports = {
  EXCLUDED_LEADERBOARD_UIDS,
  LEADERBOARD_VISIBLE_FIELD,
  isLeaderboardEligibleUid,
  isLeaderboardVisible,
  isLeaderboardEligible,
};
