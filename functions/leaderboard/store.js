// Storage-shape core for the RE Points leaderboard. Pure: persistence goes
// through an injected store, so the same code runs against Firestore (plain or
// transactional) and in memory.
//
// ── Documents ───────────────────────────────────────────────────────────────
//   users/{uid}/rePointDays/{dateKey}          private derived day score
//   users/{uid}/showcase/leaderboardState      { formulaVersion, builtAtMs }
//   leaderboards/{periodKey}                   period doc (YYYY-MM | all_time)
//   leaderboards/{periodKey}/entries/{uid}     public ranked entry
//
// Every one of them is derived — from the V2 day contributions, the weigh-ins,
// the athlete's sex, profileShowcaseV2 and the public identity — and can be
// deleted and rebuilt at any time.
//
// ── Idempotence ─────────────────────────────────────────────────────────────
// Nothing ever does "read total, add points". A changed date's day document is
// recomputed from its surviving sources, and each affected month's entry is
// RE-SUMMED from all of that month's day documents (at most 31). Duplicate,
// retried or out-of-order deliveries therefore converge on the same values.
//
// ── Cost ────────────────────────────────────────────────────────────────────
// A workout write touches one date: its V2 contributions, one bounded weigh-in
// query, the month's day documents and a handful of writes. A weigh-in touches
// only the dates whose as-of bodyweight it can change. Only a first build, a
// formula change or a change of sex rebuilds an athlete's whole history — from
// the derived V2 day contributions, never by re-reading workouts.

'use strict';

const {
  LEADERBOARD_FORMULA_VERSION,
  ALL_TIME_PERIOD,
  scoreDay,
  periodKeyOf,
  monthEntryFromDays,
  allTimeEntryFromSnapshot,
} = require('./reducer');
const { scoringSexOf } = require('../showcase/re_points');
const { resolveBodyweights, canonicalJson } = require('../showcase/store');

function withoutStamps(doc) {
  if (!doc) return null;
  const copy = Object.assign({}, doc);
  delete copy.updatedAt;
  delete copy.updatedAtMs;
  return copy;
}

function sameDoc(a, b) {
  return canonicalJson(withoutStamps(a)) === canonicalJson(withoutStamps(b));
}

/**
 * As-of bodyweights for [dateKeys]. A few dates (the per-workout path) use the
 * store's BOUNDED single-date query each; many dates use one bulk read.
 */
async function bodyweightsFor(store, dateKeys) {
  if (dateKeys.length <= 3 && typeof store.getBodyweightAsOf === 'function') {
    const out = new Map();
    for (const d of dateKeys) out.set(d, (await store.getBodyweightAsOf(d)) || null);
    return out;
  }
  return resolveBodyweights(store, dateKeys);
}

function groupByDate(v2Days) {
  const out = new Map();
  for (const d of v2Days || []) {
    if (!d || typeof d.dateKey !== 'string') continue;
    if (!out.has(d.dateKey)) out.set(d.dateKey, []);
    out.get(d.dateKey).push(d);
  }
  return out;
}

/** True when the athlete's leaderboard has been fully built under this formula. */
function isBuilt(state) {
  return !!(state && state.formulaVersion === LEADERBOARD_FORMULA_VERSION);
}

/**
 * Recomputes the day documents of [dateKeys] and re-sums every month they
 * belong to. `v2ByDate` optionally supplies the dates' V2 contributions (a
 * range read already made them available).
 *
 * Returns { days: [changed dateKeys], periods: [re-summed periodKeys] }.
 */
async function recomputeDates(store, dateKeys, v2ByDate) {
  const keys = [...new Set(dateKeys.filter((d) => periodKeyOf(d)))].sort();
  if (keys.length === 0) return { days: [], periods: [] };
  const periods = [...new Set(keys.map(periodKeyOf))].sort();

  // Reads first (transaction contract): sources, then the months' days.
  const byDate = v2ByDate || (await store.getV2DaysForDates(keys));
  const scoredDates = keys.filter((d) => (byDate.get(d) || []).length > 0);
  const bwByDate = await bodyweightsFor(store, scoredDates);
  const sex = scoringSexOf(await store.getScoringSex());
  const identity = await store.getPublicProfile();
  const monthDays = new Map();
  for (const p of periods) monthDays.set(p, await store.listRePointDaysForPeriod(p));

  const changedDays = [];
  for (const d of keys) {
    const next = scoreDay(d, byDate.get(d) || [], bwByDate.get(d) || null, sex);
    const p = periodKeyOf(d);
    const list = monthDays.get(p);
    const i = list.findIndex((x) => x.dateKey === d);
    const prev = i >= 0 ? list[i] : null;
    if (sameDoc(next, prev)) continue;
    changedDays.push(d);
    if (next) {
      await store.setRePointDay(d, next);
      if (i >= 0) list[i] = next;
      else list.push(next);
    } else {
      await store.deleteRePointDay(d);
      list.splice(i, 1);
    }
  }

  for (const p of periods) {
    const entry = monthEntryFromDays(store.uid, p, monthDays.get(p), identity);
    if (entry) await store.setEntry(p, entry);
    else await store.deleteEntry(p);
  }
  if (typeof store.notePeriods === 'function') store.notePeriods(periods);
  return { days: changedDays, periods };
}

/**
 * Rewrites the all-time entry from the published profileShowcaseV2.
 * Returns 'set' | 'deleted' | 'stale' (left alone: another formula version).
 */
async function refreshAllTime(store) {
  const profile = await store.getPublicProfile();
  const snapshot = profile ? profile.profileShowcaseV2 : null;
  const res = allTimeEntryFromSnapshot(store.uid, snapshot, profile);
  if (res.stale) return 'stale';
  if (res.entry) {
    await store.setEntry(ALL_TIME_PERIOD, res.entry);
    if (typeof store.notePeriods === 'function') store.notePeriods([ALL_TIME_PERIOD]);
    return 'set';
  }
  await store.deleteEntry(ALL_TIME_PERIOD);
  return 'deleted';
}

/**
 * Deterministic whole-athlete rebuild from the V2 day contributions: every day
 * document, every month the athlete has (or had) entries for, the all-time
 * entry, and the state marker. Day documents no source produces any more are
 * deleted.
 */
async function rebuildUser(store) {
  const byDate = groupByDate(await store.listAllV2Days());
  const existing = await store.listAllRePointDays();
  const bwByDate = await resolveBodyweights(store, [...byDate.keys()]);
  const sex = scoringSexOf(await store.getScoringSex());
  const identity = await store.getPublicProfile();

  const next = new Map();
  for (const [d, days] of byDate) {
    const doc = scoreDay(d, days, bwByDate.get(d) || null, sex);
    if (doc) next.set(d, doc);
  }
  const periods = new Set();
  for (const doc of existing) if (doc && doc.periodKey) periods.add(doc.periodKey);
  for (const doc of next.values()) periods.add(doc.periodKey);

  const prevByDate = new Map(existing.map((d) => [d.dateKey, d]));
  for (const [d, doc] of next) {
    if (!sameDoc(doc, prevByDate.get(d))) await store.setRePointDay(d, doc);
  }
  for (const d of prevByDate.keys()) {
    if (!next.has(d)) await store.deleteRePointDay(d);
  }
  const all = [...next.values()];
  for (const p of [...periods].sort()) {
    const entry = monthEntryFromDays(store.uid, p, all.filter((x) => x.periodKey === p), identity);
    if (entry) await store.setEntry(p, entry);
    else await store.deleteEntry(p);
  }
  if (typeof store.notePeriods === 'function') store.notePeriods([...periods]);
  const allTime = await refreshAllTime(store);
  // Only mark the athlete built once their profile V2 exists: a build from no
  // V2 at all must not stop the first real V2 build from being picked up.
  const v2Built = typeof store.getV2State === 'function' ? !!(await store.getV2State()) : true;
  if (v2Built) await store.setState({ formulaVersion: LEADERBOARD_FORMULA_VERSION });
  return { days: next.size, periods: [...periods].sort(), allTime, built: v2Built };
}

/**
 * The single entry point for a change of a date or range. Rebuilds the whole
 * athlete when their leaderboard was never built or was built under another
 * formula; otherwise recomputes only the requested dates.
 *
 * request: { dateKeys?: string[], sinceDateKey?, untilDateKey?, full? }
 *   sinceDateKey/untilDateKey select every date with V2 contributions in
 *   [since, until) — until exclusive, absent = open-ended.
 */
async function applyRequest(store, request) {
  const req = request || {};
  const state = await store.getState();
  if (req.full || !isBuilt(state)) {
    return Object.assign({ path: 'rebuild' }, await rebuildUser(store));
  }
  if (req.sinceDateKey !== undefined) {
    const v2 = await store.listV2DaysInRange(req.sinceDateKey || '', req.untilDateKey || null);
    const byDate = groupByDate(v2);
    // A date whose last contribution vanished still has a day document to drop.
    const existing = await store.listRePointDaysInRange(req.sinceDateKey || '', req.untilDateKey || null);
    const dates = [...new Set([...byDate.keys(), ...existing.map((d) => d.dateKey)])];
    return Object.assign({ path: 'range' }, await recomputeDates(store, dates, byDate));
  }
  return Object.assign({ path: 'dates' }, await recomputeDates(store, req.dateKeys || []));
}

/**
 * In-memory store for unit tests and the backfill dry run.
 *
 * `v2Days()` returns the athlete's V2 day contributions (array); the other
 * options mirror memoryStoreV2 (bodyweightAsOf, sex) plus `publicProfile()`.
 * `entries` may be shared between several athletes' stores to model the
 * leaderboard collections.
 */
function memoryLeaderboardStore(uid, options) {
  const o = options || {};
  const days = new Map();
  const entries = o.entries || new Map(); // `${periodKey}/${uid}` -> entry
  let state = null;
  const periods = o.periods || new Set();
  const v2 = () => (typeof o.v2Days === 'function' ? o.v2Days() : []);
  return {
    uid,
    async getState() {
      return state;
    },
    async getV2State() {
      return o.v2Built === false ? null : { schema: 'profileShowcaseV2' };
    },
    async setState(next) {
      state = Object.assign({}, next);
    },
    async getV2DaysForDates(dateKeys) {
      const out = new Map();
      const all = v2();
      for (const d of dateKeys) out.set(d, all.filter((x) => x.dateKey === d));
      return out;
    },
    async listV2DaysInRange(since, until) {
      return v2().filter((x) => x.dateKey >= since && (!until || x.dateKey < until));
    },
    async listAllV2Days() {
      return v2();
    },
    async getScoringSex() {
      return typeof o.sex === 'function' ? o.sex() : o.sex === undefined ? null : o.sex;
    },
    async getPublicProfile() {
      return typeof o.publicProfile === 'function' ? o.publicProfile() : o.publicProfile || null;
    },
    async listRePointDaysForPeriod(p) {
      return [...days.values()].filter((d) => d.periodKey === p);
    },
    async listRePointDaysInRange(since, until) {
      return [...days.values()].filter((d) => d.dateKey >= since && (!until || d.dateKey < until));
    },
    async listAllRePointDays() {
      return [...days.values()];
    },
    async setRePointDay(d, doc) {
      days.set(d, doc);
    },
    async deleteRePointDay(d) {
      days.delete(d);
    },
    async setEntry(p, entry) {
      entries.set(`${p}/${uid}`, entry);
    },
    async deleteEntry(p) {
      entries.delete(`${p}/${uid}`);
    },
    notePeriods(list) {
      for (const p of list) periods.add(p);
    },
    ...(typeof o.bodyweightAsOf === 'function'
      ? { getBodyweightAsOf: (d) => o.bodyweightAsOf(d) }
      : {}),
    async flush() {},
    _days: days,
    _entries: entries,
    _periods: periods,
  };
}

module.exports = {
  isBuilt,
  recomputeDates,
  refreshAllTime,
  rebuildUser,
  applyRequest,
  memoryLeaderboardStore,
};
