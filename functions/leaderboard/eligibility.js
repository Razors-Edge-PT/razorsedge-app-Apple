// Accounts intentionally excluded from every public RE Points leaderboard.
//
// These are test/demo accounts whose deliberately unrealistic lifts are useful
// inside the app but must never compete with real athletes. Keep the policy in
// the server-derived write path: client filtering alone would leave medals and
// rankings incorrect, and a later rebuild could otherwise publish them again.

'use strict';

const EXCLUDED_LEADERBOARD_UIDS = Object.freeze([
  'LWXGJ5SlIzM4OxEkOdTuv6d1c5b2', // Real Deal Money
  'jhIB7Yi1whYwPvBSmK27KltJGn23', // Richard_lifts_a_wholet
]);

const excluded = new Set(EXCLUDED_LEADERBOARD_UIDS);

function isLeaderboardEligibleUid(uid) {
  return typeof uid === 'string' && uid.length > 0 && !excluded.has(uid);
}

module.exports = {
  EXCLUDED_LEADERBOARD_UIDS,
  isLeaderboardEligibleUid,
};
