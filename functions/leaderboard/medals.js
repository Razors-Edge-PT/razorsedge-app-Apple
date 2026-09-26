// Pure category-medal allocation for the RE Points leaderboard. No Firebase
// imports.
//
// ── What a medal is ─────────────────────────────────────────────────────────
// Every leaderboard period (each 'YYYY-MM' month and 'all_time') awards, per
// RE category, a gold, a silver and a bronze: at most 3 × 5 = 15 medals. The
// score a category is ranked by is ALREADY on the athlete's entry, computed by
// the existing reducer — nothing here restates RE Points arithmetic:
//   * month     categoryTotalsUnits[c]  the sum of that month's daily category
//               winners (one exercise per category per training date)
//   * all time  categoryBestUnits[c]    the points of the exercise the profile
//               card shows by default for that category
// Both are integers of 1/10,000 point. Only a positive score is eligible, so a
// category with fewer than three scorers awards fewer than three medals.
//
// ── Order ───────────────────────────────────────────────────────────────────
// Higher points, then the EARLIER achievement date, then uid ascending — all
// data-derived, so any rebuild reproduces the same winners:
//   * month     the last training date that added points to the category —
//               the day the current subtotal was reached
//   * all time  the training date of the winning record
// Each entry carries that order as ONE sortable string per category
// (medalRankKeys[c]), so a bounded `orderBy(medalRankKeys.c).limit(3)` query
// returns exactly the medallists. A category an athlete has not scored in has
// no key and never appears in that query.

'use strict';

const { RE_CATEGORIES } = require('../showcase/re_catalog');

const CATEGORY_KEYS = RE_CATEGORIES.map((c) => c.key);
const PLACES = 3;
const MEDALS = ['gold', 'silver', 'bronze'];

/** Schema of leaderboardMedals/{periodKey}. */
const MEDAL_SNAPSHOT_SCHEMA = 'leaderboardMedals';
const MEDAL_SNAPSHOT_VERSION = 1;

/** Collections: public snapshots, and the private dirty-board queue. */
const MEDALS_COLLECTION = 'leaderboardMedals';
const MEDAL_QUEUE_COLLECTION = 'leaderboardMedalQueue';

/** Units are far below this (a 1,000,000-point score is 1e10 units). */
const RANK_UNITS_CEILING = 1e12;
const RANK_UNITS_WIDTH = 13;
const DATE_KEY_RE = /^\d{4}-\d{2}-\d{2}$/;

function isScore(units) {
  return Number.isSafeInteger(units) && units > 0 && units < RANK_UNITS_CEILING;
}

/**
 * The ascending sort key of one category score: better scores sort first.
 * `(ceiling − units)` zero-padded, then the achievement date (earlier first),
 * then the uid. Null when the score is not eligible.
 */
function medalRankKey(units, dateKey, uid) {
  if (!isScore(units) || typeof uid !== 'string' || !uid) return null;
  const date = typeof dateKey === 'string' && DATE_KEY_RE.test(dateKey) ? dateKey : '9999-99-99';
  const inverted = String(RANK_UNITS_CEILING - units).padStart(RANK_UNITS_WIDTH, '0');
  return `${inverted}~${date}~${uid}`;
}

/**
 * { medalRankKeys } for an entry from its per-category units and dates. Only
 * eligible categories get a key.
 */
function medalRankKeysOf(uid, unitsByCategory, dateKeyByCategory) {
  const out = {};
  for (const k of CATEGORY_KEYS) {
    const key = medalRankKey(unitsByCategory && unitsByCategory[k], dateKeyByCategory && dateKeyByCategory[k], uid);
    if (key) out[k] = key;
  }
  return out;
}

/** The per-category score an entry is ranked by (month or all time). */
function categoryUnitsOf(entry) {
  if (!entry) return {};
  return entry.categoryTotalsUnits || entry.categoryBestUnits || {};
}

/**
 * The medallists of ONE category from candidate entries (any order; the query
 * already returns them ordered, this re-sorts defensively). Returns up to
 * three { uid, place, pointsUnits, achievedDateKey, exerciseId?, recordDateKey? }.
 */
function categoryWinners(category, entries, { allTime = false } = {}) {
  const cands = [];
  const seen = new Set();
  for (const e of entries || []) {
    if (!e || typeof e.uid !== 'string' || seen.has(e.uid)) continue;
    const units = categoryUnitsOf(e)[category];
    if (!isScore(units)) continue;
    const dateKey = e.categoryDateKeys && e.categoryDateKeys[category];
    const key = medalRankKey(units, dateKey, e.uid);
    seen.add(e.uid);
    cands.push({ e, units, dateKey: typeof dateKey === 'string' ? dateKey : null, key });
  }
  cands.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  return cands.slice(0, PLACES).map((c, i) => {
    const w = { uid: c.e.uid, place: i + 1, pointsUnits: c.units, achievedDateKey: c.dateKey };
    if (allTime) {
      const ex = c.e.winningExerciseIds && c.e.winningExerciseIds[category];
      w.exerciseId = typeof ex === 'string' ? ex : null;
      w.recordDateKey = c.dateKey;
    }
    return w;
  });
}

/**
 * Every category's medallists from per-category candidate lists
 * ({ [category]: [entry] }, e.g. the five top-3 queries).
 */
function allocateMedals(candidatesByCategory, { allTime = false } = {}) {
  const out = {};
  for (const k of CATEGORY_KEYS) out[k] = categoryWinners(k, (candidatesByCategory || {})[k], { allTime });
  return out;
}

/** Awards as a comparable string (order of keys fixed). */
function awardsFingerprint(categories) {
  return JSON.stringify(CATEGORY_KEYS.map((k) => (categories && categories[k]) || []));
}

/**
 * The snapshot document for [periodKey], or null when [prev] already holds
 * exactly these awards (nothing to write — idempotent). `revision` counts
 * changes of the awards; stamps are added by the caller.
 */
function medalSnapshot(periodKey, categories, { formulaVersion, rePointsFormulaVersion, prev } = {}) {
  const month = /^\d{4}-\d{2}$/.test(periodKey);
  if (
    prev &&
    prev.schemaVersion === MEDAL_SNAPSHOT_VERSION &&
    prev.formulaVersion === formulaVersion &&
    awardsFingerprint(prev.categories) === awardsFingerprint(categories)
  ) {
    return null;
  }
  return {
    schema: MEDAL_SNAPSHOT_SCHEMA,
    schemaVersion: MEDAL_SNAPSHOT_VERSION,
    periodKey,
    boardType: month ? 'month' : 'allTime',
    monthKey: month ? periodKey : null,
    formulaVersion,
    rePointsFormulaVersion,
    revision: (prev && Number.isInteger(prev.revision) ? prev.revision : 0) + 1,
    categories: Object.fromEntries(CATEGORY_KEYS.map((k) => [k, (categories && categories[k]) || []])),
  };
}

function holders(snapshot) {
  const out = new Set();
  for (const k of CATEGORY_KEYS) for (const w of (snapshot && snapshot.categories && snapshot.categories[k]) || []) out.add(w.uid);
  return out;
}

/**
 * Whether an entry write can change [snapshot]'s awards (pure). [before] /
 * [after] are the entry sides (null when absent). False only when certain:
 * the ranked scores did not change, or the athlete neither holds a medal nor
 * now ranks ahead of a current medallist in any category.
 */
function entryWriteAffectsMedals(before, after, snapshot, formulaVersion) {
  const keysB = (before && before.medalRankKeys) || {};
  const keysA = (after && after.medalRankKeys) || {};
  const versionB = before ? before.formulaVersion : null;
  const versionA = after ? after.formulaVersion : null;
  const same =
    versionA === versionB && CATEGORY_KEYS.every((k) => (keysB[k] || null) === (keysA[k] || null));
  if (same) return false;
  if (!snapshot || snapshot.formulaVersion !== formulaVersion) return true;
  const uid = (after && after.uid) || (before && before.uid);
  if (holders(snapshot).has(uid)) return true;
  if (!after || versionA !== formulaVersion) return false;
  for (const k of CATEGORY_KEYS) {
    const mine = keysA[k];
    if (!mine) continue;
    const winners = (snapshot.categories && snapshot.categories[k]) || [];
    if (winners.length < PLACES) return true;
    const last = winners[winners.length - 1];
    const lastKey = medalRankKey(last.pointsUnits, last.achievedDateKey, last.uid);
    if (!lastKey || mine < lastKey) return true;
  }
  return false;
}

module.exports = {
  CATEGORY_KEYS,
  PLACES,
  MEDALS,
  MEDAL_SNAPSHOT_SCHEMA,
  MEDAL_SNAPSHOT_VERSION,
  MEDALS_COLLECTION,
  MEDAL_QUEUE_COLLECTION,
  medalRankKey,
  medalRankKeysOf,
  categoryUnitsOf,
  categoryWinners,
  allocateMedals,
  awardsFingerprint,
  medalSnapshot,
  entryWriteAffectsMedals,
};
