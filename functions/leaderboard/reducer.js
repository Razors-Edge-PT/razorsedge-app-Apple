// Pure leaderboard scoring. No Firebase imports.
//
// ── One formula, reused ─────────────────────────────────────────────────────
// Nothing here restates the RE Points arithmetic. Every score comes from the
// profile engine (functions/showcase):
//   * exercise identity, category membership, factors  — re_catalog.js
//   * a day's best set per exercise, bodyweight-loaded normalisation,
//     combined Chin-Up / Triceps Dip load                — reducer.js via the
//                                                         V2 day contributions
//   * E1RM × factor × sex/bodyweight coefficient, 4 dp   — reducer_v2.scoreRecord
// The leaderboard only decides WHICH of those scores count, and adds them up in
// integer units.
//
// ── Units ───────────────────────────────────────────────────────────────────
// Points are stored by the profile engine rounded to 4 dp. The leaderboard
// converts each to an integer number of 1/10,000 points ONCE and only ever
// adds integers, so a monthly total is exact and independent of the order its
// days were summed in. Display values are produced only in the app.
//
// ── Monthly ─────────────────────────────────────────────────────────────────
// Per (athlete, training date): the best-scoring exercise of each category that
// date — one winner per category, however many exercises, rows or workout
// documents the date holds — summed into a daily total. A month is the sum of
// its daily totals.
//
// ── All time ────────────────────────────────────────────────────────────────
// The sum over categories of the score the PROFILE shows by default for that
// category (profileShowcaseV2 bestExerciseId → rePoints), so the all-time
// leaderboard and the profile cards can never disagree.

'use strict';

const { RE_CATEGORIES, RE_EXERCISES, reExerciseBySlot, reExerciseById } = require('../showcase/re_catalog');
const {
  pointsRecordOf,
  isCurrentSnapshotV2,
  SHOWCASE_V2_AGGREGATION_VERSION,
} = require('../showcase/reducer_v2');
const { SHOWCASE_FORMULA_VERSION } = require('../showcase/e1rm_spec');
const { RE_POINTS_FORMULA_VERSION } = require('../showcase/re_points');
const { medalRankKeysOf } = require('./medals');
const { isLeaderboardEligibleUid } = require('./eligibility');

/** 1 point = 10,000 units. */
const POINT_UNITS = 10000;

/**
 * Version stamped on every derived leaderboard document. It embeds the RE
 * Points (factor table) and E1RM versions, so a change to either makes every
 * document written under the old one detectably stale.
 */
//   1 — daily winners from each exercise's Best E1RM set (retired)
//   2 — daily winners and all time from the Best RE Points sets
const LEADERBOARD_VERSION = 2;
const LEADERBOARD_FORMULA_VERSION =
  `lb${LEADERBOARD_VERSION}-agg${SHOWCASE_V2_AGGREGATION_VERSION}` +
  `-re${RE_POINTS_FORMULA_VERSION}-e1rm${SHOWCASE_FORMULA_VERSION}`;

/** Period key of the all-time leaderboard. Never a YYYY-MM key. */
const ALL_TIME_PERIOD = 'all_time';

const CATEGORY_KEYS = RE_CATEGORIES.map((c) => c.key);
const CATALOGUE_ORDER = new Map(RE_EXERCISES.map((e, i) => [e.slot, i]));
const DATE_KEY_RE = /^\d{4}-\d{2}-\d{2}$/;
const PERIOD_KEY_RE = /^\d{4}-\d{2}$/;

/** Points (4 dp) → integer units. Null/invalid → null. */
function toUnits(points) {
  if (typeof points !== 'number' || !Number.isFinite(points)) return null;
  return Math.round(points * POINT_UNITS);
}

/** 'YYYY-MM-DD' → 'YYYY-MM'. The canonical training date decides the month. */
function periodKeyOf(dateKey) {
  if (typeof dateKey !== 'string' || !DATE_KEY_RE.test(dateKey)) return null;
  return dateKey.slice(0, 7);
}

function isMonthPeriod(periodKey) {
  return typeof periodKey === 'string' && PERIOD_KEY_RE.test(periodKey);
}

function zeroByCategory() {
  const out = {};
  for (const k of CATEGORY_KEYS) out[k] = 0;
  return out;
}

/**
 * The minimal public identity an entry carries: a display name and avatar URL.
 * Nothing else from the profile is ever copied.
 *
 * The name resolves username → displayName → fullName → null. fullName is a
 * DISPLAY fallback only, for legacy public profiles that never received a
 * username; it is never reserved or treated as a username anywhere. Every
 * source is the public profile (users_public), so no private field — email
 * included — can reach an entry.
 */
function identityOf(publicData) {
  const d = publicData && typeof publicData === 'object' ? publicData : {};
  const str = (v) => (typeof v === 'string' && v.trim() ? v.trim() : null);
  return {
    username: str(d.username) || str(d.displayName) || str(d.fullName),
    photoURL: str(d.photoURL) || str(d.photoUrl),
  };
}

function sameIdentity(a, b) {
  const x = identityOf(a);
  const y = identityOf(b);
  return x.username === y.username && x.photoURL === y.photoURL;
}

function betterWinner(a, b) {
  if (!b) return true;
  if (a.pointsUnits !== b.pointsUnits) return a.pointsUnits > b.pointsUnits;
  // Equal score: catalogue (preference) order, as the profile's tie-break.
  return CATALOGUE_ORDER.get(a.slot) < CATALOGUE_ORDER.get(b.slot);
}

/**
 * The derived score for ONE training date.
 *
 * [v2Days] are that date's V2 day contributions (showcase/store_v2) — one per
 * exercise, already merged across every workout document and row of the
 * date. Each carries its day's highest-scoring set (`bestPoints`, chosen by
 * scoring EVERY set through the approved path) and the bodyweight recorded on
 * or before the date. [bodyweight] is only a fallback for a contribution
 * stored without one. [sex] is re_points.Sex.
 *
 * Per category the highest-scoring exercise wins (equal → catalogue order).
 * Returns null when the date holds no eligible exercise. An exercise without
 * a bodyweight scores nothing, exactly as on the profile.
 */
function scoreDay(dateKey, v2Days, bodyweight, sex) {
  const days = (v2Days || []).filter((d) => d && d.dateKey === dateKey && reExerciseBySlot(d.slot));
  if (days.length === 0) return null;
  const winners = {};
  for (const day of days) {
    const def = reExerciseBySlot(day.slot);
    if (!day.bestPoints) continue;
    const scoredDay = 'bodyweight' in day ? day : Object.assign({}, day, { bodyweight });
    const record = pointsRecordOf(def, scoredDay, day.bestPoints, sex);
    const units = toUnits(record.rePoints);
    if (units === null || units <= 0) continue;
    const cand = {
      slot: def.slot,
      exerciseId: def.exerciseId,
      displayName: def.displayName,
      pointsUnits: units,
      // Source identifiers: exactly which stored set won.
      setKey: record.setKey,
      weight: record.weight,
      reps: record.reps,
      fingerprint: record.fingerprint,
    };
    if (betterWinner(cand, winners[def.category])) winners[def.category] = cand;
  }
  let total = 0;
  const categories = {};
  for (const k of CATEGORY_KEYS) {
    if (!winners[k]) continue;
    categories[k] = winners[k];
    total += winners[k].pointsUnits;
  }
  return {
    formulaVersion: LEADERBOARD_FORMULA_VERSION,
    dateKey,
    periodKey: periodKeyOf(dateKey),
    categories,
    totalPointsUnits: total,
  };
}

/**
 * Attributes one day's category winner [c] (a rePointDays category, already
 * the single winner of its date — equal scores resolved by scoreDay's
 * catalogue order) to its exercise in [acc]: points summed, and the date
 * counted once however many workouts or sets it held. Only the exercise id,
 * its canonical catalogue name, points and the count are kept — never the
 * date, load, reps or any other detail of the set.
 */
function addBreakdown(acc, c, dateKey) {
  if (!Number.isInteger(c.pointsUnits) || c.pointsUnits <= 0) return;
  const def = reExerciseBySlot(c.slot) || reExerciseById(c.exerciseId);
  const exerciseId = def ? def.exerciseId : (typeof c.exerciseId === 'string' ? c.exerciseId : null);
  const displayName = def ? def.displayName : (typeof c.displayName === 'string' ? c.displayName : null);
  const key = exerciseId || `slot:${c.slot}`;
  let row = acc.get(key);
  if (!row) {
    row = { exerciseId, displayName, pointsUnits: 0, dates: new Set() };
    acc.set(key, row);
  }
  row.pointsUnits += c.pointsUnits;
  row.dates.add(dateKey);
}

/** Points descending, then canonical name, then id: fully deterministic. */
function sortedBreakdown(acc) {
  const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  return [...acc.values()]
    .map((r) => ({ exerciseId: r.exerciseId, displayName: r.displayName, pointsUnits: r.pointsUnits, sessionCount: r.dates.size }))
    .sort((a, b) => b.pointsUnits - a.pointsUnits || cmp(a.displayName || '', b.displayName || '') || cmp(a.exerciseId || '', b.exerciseId || ''));
}

/**
 * A monthly entry from EVERY day document of that month (deterministic: the
 * same surviving days always give the same entry). Null when nothing scored.
 *
 * tieBreakDateKey is the last date that added points — the day the total was
 * reached. Earlier wins a tie; the uid settles the rest. It is derived from
 * the data, so a rebuild reproduces it exactly.
 *
 * Per category (medals.js), categoryDateKeys[c] is likewise the last date
 * that added points to that category — the day its subtotal was reached —
 * and medalRankKeys[c] the category's sortable medal order.
 *
 * categoryExerciseBreakdown[c] (the monthly medal detail) attributes that
 * subtotal to the exercises that won the category's daily score — see
 * addBreakdown. Its pointsUnits always sum exactly to categoryTotalsUnits[c].
 */
function monthEntryFromDays(uid, periodKey, dayDocs, identity) {
  if (!isLeaderboardEligibleUid(uid)) return null;
  const categoryTotalsUnits = zeroByCategory();
  const categoryDateKeys = {};
  const breakdown = {};
  for (const k of CATEGORY_KEYS) {
    categoryDateKeys[k] = null;
    breakdown[k] = new Map();
  }
  let total = 0;
  let scoredDayCount = 0;
  let tieBreakDateKey = null;
  for (const d of dayDocs || []) {
    if (!d || d.periodKey !== periodKey) continue;
    const t = Number.isInteger(d.totalPointsUnits) ? d.totalPointsUnits : 0;
    if (t <= 0) continue;
    total += t;
    scoredDayCount += 1;
    for (const k of CATEGORY_KEYS) {
      const c = d.categories && d.categories[k];
      if (c && Number.isInteger(c.pointsUnits)) {
        categoryTotalsUnits[k] += c.pointsUnits;
        addBreakdown(breakdown[k], c, d.dateKey);
        if (c.pointsUnits > 0 && (!categoryDateKeys[k] || d.dateKey > categoryDateKeys[k])) {
          categoryDateKeys[k] = d.dateKey;
        }
      }
    }
    if (!tieBreakDateKey || d.dateKey > tieBreakDateKey) tieBreakDateKey = d.dateKey;
  }
  if (total <= 0) return null;
  const id = identityOf(identity);
  return {
    uid,
    periodKey,
    username: id.username,
    photoURL: id.photoURL,
    totalPointsUnits: total,
    categoryTotalsUnits,
    categoryDateKeys,
    categoryExerciseBreakdown: Object.fromEntries(CATEGORY_KEYS.map((k) => [k, sortedBreakdown(breakdown[k])])),
    medalRankKeys: medalRankKeysOf(uid, categoryTotalsUnits, categoryDateKeys),
    scoredDayCount,
    tieBreakDateKey,
    formulaVersion: LEADERBOARD_FORMULA_VERSION,
  };
}

/**
 * The all-time entry from the athlete's published profileShowcaseV2: per
 * category, the points of the exercise the profile shows by default.
 *
 * Returns { entry } — entry null when nothing scored — or { stale: true } when
 * the snapshot was produced by another formula version (never mixed in).
 */
function allTimeEntryFromSnapshot(uid, snapshot, identity) {
  if (!isLeaderboardEligibleUid(uid)) return { entry: null };
  if (!snapshot) return { entry: null };
  if (!isCurrentSnapshotV2(snapshot)) return { stale: true, entry: null };
  const categoryBestUnits = zeroByCategory();
  const winningExerciseIds = {};
  // Per category: the training date of the winning record (medal order).
  const categoryDateKeys = {};
  let total = 0;
  let tieBreakDateKey = null;
  for (const k of CATEGORY_KEYS) {
    winningExerciseIds[k] = null;
    categoryDateKeys[k] = null;
    const cat = snapshot.categories[k];
    const best = cat && cat.exercises && cat.exercises[cat.bestExerciseId];
    const units = best ? toUnits(best.rePoints) : null;
    if (units === null || units <= 0) continue;
    categoryBestUnits[k] = units;
    winningExerciseIds[k] = best.exerciseId;
    total += units;
    // Reached on the Best RE Points record's own date.
    const d = best.points && best.points.dateKey;
    if (typeof d === 'string') categoryDateKeys[k] = d;
    if (d && (!tieBreakDateKey || d > tieBreakDateKey)) tieBreakDateKey = d;
  }
  if (total <= 0) return { entry: null };
  const id = identityOf(identity);
  return {
    entry: {
      uid,
      periodKey: ALL_TIME_PERIOD,
      username: id.username,
      photoURL: id.photoURL,
      totalPointsUnits: total,
      categoryBestUnits,
      winningExerciseIds,
      categoryDateKeys,
      medalRankKeys: medalRankKeysOf(uid, categoryBestUnits, categoryDateKeys),
      tieBreakDateKey,
      formulaVersion: LEADERBOARD_FORMULA_VERSION,
    },
  };
}

module.exports = {
  POINT_UNITS,
  LEADERBOARD_FORMULA_VERSION,
  ALL_TIME_PERIOD,
  CATEGORY_KEYS,
  toUnits,
  periodKeyOf,
  isMonthPeriod,
  identityOf,
  sameIdentity,
  scoreDay,
  monthEntryFromDays,
  allTimeEntryFromSnapshot,
};
