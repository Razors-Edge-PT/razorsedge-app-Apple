// Storage-shape core for the V2 profile showcase (categories + RE Points).
//
// Pure module: persistence goes through an injected store, exactly like
// store.js, so the same code runs against Firestore and in memory.
//
// V2 is published BESIDE V1, never instead of it: old clients keep reading
// profileShowcaseV1, maintained unchanged by store.js. Nothing here reads or
// writes V1 documents.
//
// ── Documents ───────────────────────────────────────────────────────────────
//   users/{uid}/showcase/stateV2
//     { schema, e1rmFormulaVersion, rePointsFormulaVersion, latestDateKey }
//     latestDateKey is the same monotonic high-water mark as V1's.
//
//   users/{uid}/showcase/v2/days/{category}__{slot}__{dateKey}
//     one day contribution per (category, exercise, date) — see reducer_v2.
//
//   users_public/{uid}.profileShowcaseV2
//     the presentation-ready snapshot, replaced as one field.
//
// Private scoring inputs — the athlete's sex and weigh-ins — are READ here and
// never published. The snapshot carries only derived points, plus the
// bodyweight context a bodyweight-loaded record has always shown.
//
// ── Paths ───────────────────────────────────────────────────────────────────
// applyWorkoutDayV2  a workout was written: the V1 append/rebuild split, per
//                    exercise. Points are scored for the exercises it touched.
// refreshV2          a weigh-in or the athlete's sex changed: re-ranks the
//                    bodyweight-loaded days the weigh-in can affect and
//                    re-scores every record whose bodyweight or sex changed.
// rebuildAllV2       deterministic whole-history rebuild (backfill).
// All are deterministic and idempotent.

'use strict';

const { RE_EXERCISES, reExerciseBySlot } = require('./re_catalog');
const {
  PROFILE_SHOWCASE_V2_SCHEMA,
  RE_SLOT_ORDER,
  summarizeWorkoutDayV2,
  resummarizeDayV2,
  scoreRecord,
  exerciseEntry,
  foldExerciseV2,
  snapshotV2FromEntries,
  entriesOfSnapshotV2,
  isCurrentSnapshotV2,
} = require('./reducer_v2');
const { SHOWCASE_FORMULA_VERSION } = require('./e1rm_spec');
const { RE_POINTS_FORMULA_VERSION, scoringSexOf } = require('./re_points');
const {
  betterE1rmRecord,
  betterHeaviestRecord,
  candidateRecords,
  sameDay,
  resolveBodyweights,
  canResolveBodyweight,
  canonicalJson,
} = require('./store');

/** Document id of one V2 day contribution. */
function dayDocIdV2(slot, dateKey) {
  const def = reExerciseBySlot(slot);
  return `${def ? def.category : 'unknown'}__${slot}__${dateKey}`;
}

function stateV2() {
  return {
    schema: PROFILE_SHOWCASE_V2_SCHEMA,
    e1rmFormulaVersion: SHOWCASE_FORMULA_VERSION,
    rePointsFormulaVersion: RE_POINTS_FORMULA_VERSION,
  };
}

function isCurrentState(state) {
  return !!(
    state &&
    state.schema === PROFILE_SHOWCASE_V2_SCHEMA &&
    state.e1rmFormulaVersion === SHOWCASE_FORMULA_VERSION &&
    state.rePointsFormulaVersion === RE_POINTS_FORMULA_VERSION
  );
}

async function scoringSex(store) {
  const raw = typeof store.getScoringSex === 'function' ? await store.getScoringSex() : null;
  return scoringSexOf(raw);
}

/**
 * A memoised as-of bodyweight lookup that uses the store's BOUNDED single-date
 * query per date — the workout trigger's per-write cost stays independent of
 * how many weigh-ins the athlete has.
 */
function bodyweightLookup(store, seed) {
  const cache = new Map(seed || []);
  return async (dateKey) => {
    if (cache.has(dateKey)) return cache.get(dateKey);
    let bw = null;
    if (typeof store.getBodyweightAsOf === 'function') {
      bw = (await store.getBodyweightAsOf(dateKey)) || null;
    } else if (canResolveBodyweight(store)) {
      bw = (await resolveBodyweights(store, [dateKey])).get(dateKey) || null;
    }
    cache.set(dateKey, bw);
    return bw;
  };
}

/** The published entry for [def] from its folded records, scored. */
async function scoredEntry(def, folded, bwAt, sex) {
  const e1rm = folded.e1rm || null;
  // A bodyweight-loaded record is scored at the bodyweight it carries; only
  // an ordinary exercise needs a lookup.
  const bw = e1rm && !def.bodyweightLoaded ? await bwAt(e1rm.dateKey) : null;
  return exerciseEntry(def, e1rm, folded.heaviest || null, scoreRecord(def, e1rm, bw, sex));
}

/**
 * Applies ONE workout day. `workoutData` is null when the document was deleted.
 * Returns { changed, slots, path } with path 'noop' | 'append' | 'rebuild'.
 */
async function applyWorkoutDayV2(store, dateKey, workoutData) {
  let next = summarizeWorkoutDayV2(dateKey, workoutData);
  const seed = [];
  // Every RE exercise is scored at a bodyweight, so any day holding one costs
  // one bounded weigh-in lookup (which also ranks its bodyweight-loaded sets).
  if (Object.keys(next).length > 0 && canResolveBodyweight(store)) {
    const bw = await bodyweightLookup(store)(dateKey);
    seed.push([dateKey, bw]);
    next = summarizeWorkoutDayV2(dateKey, workoutData, { bodyweight: bw });
  }
  const prior = await store.getDaysForDate(dateKey);

  const touched = new Set([...Object.keys(next), ...Object.keys(prior)]);
  const changed = [];
  for (const slot of touched) {
    if (!sameDay(next[slot] || null, prior[slot] || null)) changed.push(slot);
  }
  if (changed.length === 0) return { changed: false, slots: [], path: 'noop' };

  for (const slot of changed) {
    if (next[slot]) await store.setDay(slot, dateKey, next[slot]);
    else await store.deleteDay(slot, dateKey);
  }

  const state = (await store.getState()) || {};
  const highWater = state.latestDateKey || '';
  const snapshot = await store.getSnapshot();
  // An absent state and snapshot means V2 has never been built for this
  // athlete. When the store can list the athlete's workouts, build it ONCE
  // from the whole history, so the first write after rollout can never
  // publish a V2 that holds only the day just written. Otherwise (the unit
  // stores) it is a first write, not a stale one. Anything else that is not
  // current is rebuilt in full from the day documents.
  const fresh = !state.schema && !snapshot;
  if (fresh && typeof store.listWorkoutEntries === 'function') {
    const history = (await store.listWorkoutEntries()).filter(([d]) => d !== dateKey);
    if (workoutData) history.push([dateKey, workoutData]);
    await rebuildAllV2(store, history);
    return { changed: true, slots: changed, path: 'bootstrap' };
  }
  const current = fresh || (isCurrentState(state) && isCurrentSnapshotV2(snapshot));
  const entries = current && snapshot ? entriesOfSnapshotV2(snapshot) : {};

  const pureAddition = changed.every((slot) => !prior[slot]);
  const canAppend = current && pureAddition && dateKey > highWater;
  const sex = await scoringSex(store);
  const bwAt = bodyweightLookup(store, seed);

  if (canAppend) {
    for (const slot of changed) {
      const def = reExerciseBySlot(slot);
      const cand = candidateRecords(next[slot]);
      const cur = entries[slot] || {};
      const e1rm = betterE1rmRecord(cand.e1rm, cur.e1rm) ? cand.e1rm : cur.e1rm;
      const heaviest = betterHeaviestRecord(cand.heaviest, cur.heaviest)
        ? cand.heaviest
        : cur.heaviest;
      entries[slot] = await scoredEntry(def, { e1rm, heaviest }, bwAt, sex);
    }
  } else {
    const slots = current ? changed : RE_SLOT_ORDER;
    for (const slot of slots) {
      const def = reExerciseBySlot(slot);
      const folded = foldExerciseV2(def, await store.listDaysForSlot(slot));
      if (folded) entries[slot] = await scoredEntry(def, folded, bwAt, sex);
      else delete entries[slot];
    }
  }

  await store.setSnapshot(snapshotV2FromEntries(entries));
  await store.setState(
    Object.assign(stateV2(), { latestDateKey: dateKey > highWater ? dateKey : highWater }),
  );
  return { changed: true, slots: changed, path: canAppend ? 'append' : 'rebuild' };
}

/**
 * Deterministic whole-history rebuild. `entries` is [[dateKey, workoutData]]
 * in any order. Never reads or writes a workout document.
 */
async function rebuildAllV2(store, workoutEntries) {
  const sorted = [...workoutEntries].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  const plain = sorted.map(([dateKey, data]) => [dateKey, data, summarizeWorkoutDayV2(dateKey, data)]);
  const bwByDate = await resolveBodyweights(
    store,
    plain.filter(([, , day]) => Object.keys(day).length > 0).map(([dateKey]) => dateKey),
  );
  const allDays = [];
  let latestDateKey = '';
  for (const [dateKey, data, plainDay] of plain) {
    const day = bwByDate.has(dateKey)
      ? summarizeWorkoutDayV2(dateKey, data, { bodyweight: bwByDate.get(dateKey) })
      : plainDay;
    for (const slot of Object.keys(day)) {
      allDays.push(day[slot]);
      await store.setDay(slot, dateKey, day[slot]);
    }
    if (dateKey > latestDateKey) latestDateKey = dateKey;
  }
  const sex = await scoringSex(store);
  const bwAt = async (dateKey) => bwByDate.get(dateKey) || null;
  const entries = {};
  for (const def of RE_EXERCISES) {
    const folded = foldExerciseV2(def, allDays);
    if (folded) entries[def.slot] = await scoredEntry(def, folded, bwAt, sex);
  }
  const snapshot = snapshotV2FromEntries(entries);
  await store.setSnapshot(snapshot);
  await store.setState(Object.assign(stateV2(), { latestDateKey }));
  return { snapshot, dayIds: allDays.map((d) => dayDocIdV2(d.slot, d.dateKey)) };
}

/**
 * Refreshes a published V2 snapshot after a scoring input changed without any
 * workout being written.
 *
 * options:
 *   sinceDateKey   the earliest day a changed weigh-in counted for (see
 *                  bodyweight.weighInSinceDateKey); '' or absent = every day.
 *   bodyweight     true for a weigh-in change: bodyweight-loaded days on or
 *                  after sinceDateKey are re-ranked, and every record dated on
 *                  or after it is re-scored — for EVERY exercise, since each
 *                  one's points use the bodyweight as of its record date.
 *   sex            true for a change of the athlete's sex: every record is
 *                  re-scored.
 *
 * Writes nothing when nothing changed; leaves a missing or stale snapshot for
 * the next workout write or the backfill to rebuild.
 */
async function refreshV2(store, options) {
  const opts = options || {};
  const since = opts.sinceDateKey || '';
  const snapshot = await store.getSnapshot();
  if (!snapshot) return { changed: false, reason: 'no-snapshot' };
  if (!isCurrentSnapshotV2(snapshot)) return { changed: false, reason: 'stale-version' };

  const entries = entriesOfSnapshotV2(snapshot);
  const slots = Object.keys(entries);
  if (slots.length === 0) return { changed: false, reason: 'empty' };

  const sex = await scoringSex(store);
  const rescored = new Set();

  if (opts.bodyweight && canResolveBodyweight(store)) {
    for (const slot of slots) {
      const def = reExerciseBySlot(slot);
      if (!def.bodyweightLoaded) continue;
      const days = await store.listDaysForSlot(slot);
      const affected = days.filter((d) => d.dateKey >= since);
      if (affected.length === 0) continue;
      const bwByDate = await resolveBodyweights(store, affected.map((d) => d.dateKey));
      const nextDays = [];
      for (const d of days) {
        if (d.dateKey < since) {
          nextDays.push(d);
          continue;
        }
        const re = resummarizeDayV2(d, bwByDate.get(d.dateKey) || null);
        nextDays.push(re);
        if (!sameDay(re, d)) await store.setDay(slot, re.dateKey, re);
      }
      const folded = foldExerciseV2(def, nextDays);
      if (!folded) continue;
      entries[slot] = Object.assign({}, entries[slot], {
        e1rm: folded.e1rm,
        heaviest: folded.heaviest,
      });
      rescored.add(slot);
    }
  }

  for (const slot of slots) {
    const e = entries[slot];
    if (opts.sex || (opts.bodyweight && e.e1rm && e.e1rm.dateKey >= since)) rescored.add(slot);
  }
  if (rescored.size === 0) return { changed: false, reason: 'unchanged' };

  const needDates = [...rescored]
    .map((slot) => entries[slot])
    .filter((e) => e.e1rm && !reExerciseBySlot(e.slot).bodyweightLoaded)
    .map((e) => e.e1rm.dateKey);
  const bwByDate = await resolveBodyweights(store, needDates);
  const bwAt = async (dateKey) => bwByDate.get(dateKey) || null;
  for (const slot of rescored) {
    const e = entries[slot];
    entries[slot] = await scoredEntry(reExerciseBySlot(slot), e, bwAt, sex);
  }

  const next = snapshotV2FromEntries(entries);
  if (canonicalJson(next.categories) === canonicalJson(snapshot.categories)) {
    return { changed: false, reason: 'unchanged' };
  }
  await store.setSnapshot(next);
  return { changed: true, slots: [...rescored] };
}

/**
 * In-memory V2 store for unit tests and dry runs.
 * options: bodyweightAsOf(dateKey), sex (the raw users/{uid}.sex value),
 * workouts() → [[dateKey, workoutData]] (enables the first-write bootstrap).
 */
function memoryStoreV2(options) {
  const bodyweightAsOf = options && options.bodyweightAsOf;
  const workouts = options && options.workouts;
  let sex = options ? options.sex : undefined;
  const days = new Map();
  let state = null;
  let snapshot = null;
  return {
    async getState() {
      return state;
    },
    async setState(next) {
      state = Object.assign({}, next);
    },
    async getSnapshot() {
      return snapshot;
    },
    async setSnapshot(next) {
      snapshot = next;
    },
    async getDaysForDate(dateKey) {
      const out = {};
      for (const slot of RE_SLOT_ORDER) {
        const d = days.get(dayDocIdV2(slot, dateKey));
        if (d) out[slot] = d;
      }
      return out;
    },
    async listDaysForSlot(slot) {
      const out = [];
      for (const d of days.values()) if (d.slot === slot) out.push(d);
      return out.sort((a, b) => (a.dateKey < b.dateKey ? -1 : 1));
    },
    async setDay(slot, dateKey, day) {
      days.set(dayDocIdV2(slot, dateKey), day);
    },
    async deleteDay(slot, dateKey) {
      days.delete(dayDocIdV2(slot, dateKey));
    },
    async getScoringSex() {
      return sex === undefined ? null : sex;
    },
    setSex(next) {
      sex = next;
    },
    async flush() {},
    ...(typeof bodyweightAsOf === 'function'
      ? { getBodyweightAsOf: (dateKey) => bodyweightAsOf(dateKey) }
      : {}),
    ...(typeof workouts === 'function'
      ? { listWorkoutEntries: async () => workouts() }
      : {}),
    _days: days,
  };
}

module.exports = {
  dayDocIdV2,
  applyWorkoutDayV2,
  rebuildAllV2,
  refreshV2,
  memoryStoreV2,
};
