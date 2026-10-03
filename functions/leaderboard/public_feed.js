// Pure core of the public raw leaderboard feed for goodliftapp.com (schema 1,
// goodlift-website docs/public-leaderboard-contract.md). No Firebase imports.
//
// The feed is a strict ALLOWLIST: a snapshot row is built field by field from
// the raw top-20 entries, the board's existing medal snapshot, the athletes'
// actual public usernames and the server-derived silver set. Nothing else —
// no uid, birth date, age, band, sex, email, legal name, avatar URL, record or
// administrative field — can reach it, whatever extra fields the sources hold.

'use strict';

const PUBLIC_SCHEMA_VERSION = 1;
const PUBLIC_MAX_ROWS = 20;
const FALLBACK_USERNAME = 'GoodLift athlete';
const CATEGORY_KEYS = Object.freeze(['horizontalPress', 'verticalPull', 'overheadPress', 'hipHinge', 'squatPattern']);
const PERIOD_RE = /^\d{4}-(0[1-9]|1[0-2])$/;

/**
 * The public username of a users_public document: its `username` only. Never
 * displayName or fullName (those may be legal names).
 */
function publicUsernameOf(publicData) {
  const v = publicData && typeof publicData === 'object' ? publicData.username : null;
  if (typeof v !== 'string') return FALLBACK_USERNAME;
  const s = v.trim();
  return s && s.length <= 60 ? s : FALLBACK_USERNAME;
}

/** uid → [{ categoryKey, place }] from a leaderboardMedals snapshot. */
function medalsByUid(medalSnapshot) {
  const out = new Map();
  const cats = medalSnapshot && medalSnapshot.categories;
  if (!cats || typeof cats !== 'object') return out;
  for (const k of CATEGORY_KEYS) {
    const winners = Array.isArray(cats[k]) ? cats[k] : [];
    for (const w of winners) {
      if (!w || typeof w.uid !== 'string' || ![1, 2, 3].includes(w.place)) continue;
      const list = out.get(w.uid) || [];
      if (list.some((m) => m.categoryKey === k)) continue; // at most one per category
      list.push({ categoryKey: k, place: w.place });
      out.set(w.uid, list);
    }
  }
  return out;
}

/**
 * The public snapshot of one board.
 *   rawEntries     raw entries in the server's order (totalPointsUnits desc,
 *                  tieBreakDateKey asc, uid asc), already excluding ineligible
 *                  accounts — only the first 20 positive ones are used
 *   publicProfiles uid → users_public data (only `username` is read)
 *   medalSnapshot  leaderboardMedals/{periodKey} (or null)
 *   silverUids     Set of uids with raw-board silver
 */
function buildPublicSnapshot({ periodKey, rawEntries, publicProfiles, medalSnapshot, silverUids, generatedAt, isEligible }) {
  const medals = medalsByUid(medalSnapshot);
  const silver = silverUids instanceof Set ? silverUids : new Set(silverUids || []);
  const entries = [];
  for (const e of rawEntries || []) {
    if (entries.length >= PUBLIC_MAX_ROWS) break;
    if (!e || typeof e.uid !== 'string') continue;
    if (typeof isEligible === 'function' && !isEligible(e.uid)) continue;
    if (!Number.isSafeInteger(e.totalPointsUnits) || e.totalPointsUnits <= 0) continue;
    entries.push({
      rank: entries.length + 1,
      username: publicUsernameOf(publicProfiles && publicProfiles.get ? publicProfiles.get(e.uid) : null),
      totalPointsUnits: e.totalPointsUnits,
      silverEligible: silver.has(e.uid),
      medals: medals.get(e.uid) || [],
    });
  }
  return { schemaVersion: PUBLIC_SCHEMA_VERSION, periodKey, generatedAt, entries };
}

/** The rows of a snapshot as a comparable string (freshness excluded). */
function rowsFingerprint(snapshot) {
  return JSON.stringify(snapshot && Array.isArray(snapshot.entries) ? snapshot.entries : null);
}

/**
 * Re-applies the allowlist to a stored snapshot before it is served (defence
 * in depth: a stray field written by any future code never escapes). Returns
 * null when the snapshot is not a valid schema-1 board for [expectedPeriodKey].
 */
function sanitizeSnapshot(stored, expectedPeriodKey) {
  if (!stored || typeof stored !== 'object') return null;
  if (stored.schemaVersion !== PUBLIC_SCHEMA_VERSION || stored.periodKey !== expectedPeriodKey) return null;
  if (typeof stored.generatedAt !== 'string' || Number.isNaN(Date.parse(stored.generatedAt))) return null;
  if (!Array.isArray(stored.entries) || stored.entries.length > PUBLIC_MAX_ROWS) return null;
  const entries = [];
  for (let i = 0; i < stored.entries.length; i += 1) {
    const e = stored.entries[i];
    if (!e || e.rank !== i + 1 || !Number.isSafeInteger(e.totalPointsUnits) || e.totalPointsUnits <= 0) return null;
    const medals = [];
    const seen = new Set();
    for (const m of Array.isArray(e.medals) ? e.medals : []) {
      if (!m || !CATEGORY_KEYS.includes(m.categoryKey) || ![1, 2, 3].includes(m.place) || seen.has(m.categoryKey)) continue;
      seen.add(m.categoryKey);
      medals.push({ categoryKey: m.categoryKey, place: m.place });
    }
    entries.push({
      rank: i + 1,
      username: typeof e.username === 'string' && e.username.trim() ? e.username.trim().slice(0, 60) : FALLBACK_USERNAME,
      totalPointsUnits: e.totalPointsUnits,
      silverEligible: e.silverEligible === true,
      medals,
    });
  }
  return { schemaVersion: PUBLIC_SCHEMA_VERSION, periodKey: stored.periodKey, generatedAt: stored.generatedAt, entries };
}

/**
 * Validates a public request. [method] the HTTP method; [rawQuery] the raw
 * query string (no leading '?'). Returns { period: 'current' | 'all_time' } or
 * { status, error }.
 */
function parsePublicRequest(method, rawQuery) {
  if (method !== 'GET' && method !== 'HEAD') return { status: 405, error: 'method-not-allowed' };
  const q = typeof rawQuery === 'string' ? rawQuery : '';
  const params = new URLSearchParams(q);
  const keys = [...params.keys()];
  if (keys.some((k) => k !== 'period')) return { status: 400, error: 'unknown-parameter' };
  const values = params.getAll('period');
  if (values.length > 1) return { status: 400, error: 'duplicate-parameter' };
  const period = values.length === 0 ? 'current' : values[0];
  if (period !== 'current' && period !== 'all_time') return { status: 400, error: 'unknown-period' };
  return { period };
}

/** The snapshot document id for a public period at [currentMonthKey]. */
function snapshotKeyFor(period, currentMonthKey) {
  if (period === 'all_time') return 'all_time';
  return PERIOD_RE.test(currentMonthKey) ? currentMonthKey : null;
}

module.exports = {
  PUBLIC_SCHEMA_VERSION,
  PUBLIC_MAX_ROWS,
  FALLBACK_USERNAME,
  publicUsernameOf,
  medalsByUid,
  buildPublicSnapshot,
  rowsFingerprint,
  sanitizeSnapshot,
  parsePublicRequest,
  snapshotKeyFor,
};
