// Storage-shape core for the V2 profile showcase (categories + RE Points) —
// the INCREMENTAL paths the triggers run. Pure: persistence goes through an
// injected store, exactly like store.js, so the same code runs against
// Firestore and in memory.
//
// V2 is published BESIDE V1, never instead of it. Nothing here reads or
// writes V1 documents.
//
// ── Documents ───────────────────────────────────────────────────────────────
//   users/{uid}/showcase/stateV2
//     { schema, e1rmFormulaVersion, rePointsFormulaVersion,
//       aggregationVersion, latestDateKey }
//   users/{uid}/showcase/v2/days/{category}__{slot}__{dateKey}
//     one day contribution per (category, exercise, date) — see reducer_v2.
//   users_public/{uid}.profileShowcaseV2
//     the presentation-ready snapshot, replaced as one field.
//   profileRebuildJobs/{uid}
//     the bounded rebuild job (rebuild_job.js).
//
// ── Bounded by construction ─────────────────────────────────────────────────
// No path here ever reads an athlete's whole workout history. A workout write
// touches ONE date; a weigh-in touches only the dates whose as-of bodyweight
// it can change; a re-fold lists one exercise's day contributions, capped at
// MAX_SLOT_DAYS. Whenever the work would be larger — the athlete's first V2
// write, a stale snapshot, a change of sex, an over-long range or exercise —
// the trigger does its own date's bounded part and REQUESTS a rebuild job,
// which pages through the history outside any trigger transaction.
//
// While a job is active the triggers keep writing the day contributions of
// the dates they touch (so nothing a job has already passed goes stale) but
// never publish: a partially rebuilt profile is never shown, and the last
// complete snapshot (or the V1 fallback) stays visible until the job
// publishes atomically. Each touch is recorded on the job so it re-folds.

'use strict';

const { RE_EXERCISES, reExerciseBySlot } = require('./re_catalog');
const {
  PROFILE_SHOWCASE_V2_SCHEMA,
  SHOWCASE_V2_AGGREGATION_VERSION,
  RE_SLOT_ORDER,
  summarizeWorkoutDayV2,
  resummarizeDayV2,
  pointsRecordOf,
  exerciseEntry,
  foldExerciseV2,
  entriesFromDays,
  snapshotV2FromEntries,
  entriesOfSnapshotV2,
  isCurrentSnapshotV2,
} = require('./reducer_v2');
const { SHOWCASE_FORMULA_VERSION } = require('./e1rm_spec');
const { RE_POINTS_FORMULA_VERSION, scoringSexOf } = require('./re_points');
const { greater } = require('./reducer');
const {
  betterE1rmRecord,
  betterHeaviestRecord,
  candidateRecords,
  sameDay,
  resolveBodyweights,
  canResolveBodyweight,
  canonicalJson,
} = require('./store');

/** A trigger re-folds an exercise in place only up to this many day documents. */
const MAX_SLOT_DAYS = 400;

/** A weigh-in re-scores in place only up to this many day documents. */
const MAX_RANGE_DAYS = 400;

/** Document id of one V2 day contribution. */
function dayDocIdV2(slot, dateKey) {
  const def = reExerciseBySlot(slot);
  return `${def ? def.category : 'unknown'}__${slot}__${dateKey}`;
}

function stateV2(latestDateKey) {
  return {
    schema: PROFILE_SHOWCASE_V2_SCHEMA,
    e1rmFormulaVersion: SHOWCASE_FORMULA_VERSION,
    rePointsFormulaVersion: RE_POINTS_FORMULA_VERSION,
    aggregationVersion: SHOWCASE_V2_AGGREGATION_VERSION,
    latestDateKey: latestDateKey || '',
  };
}

function isCurrentState(state) {
  return !!(
    state &&
    state.schema === PROFILE_SHOWCASE_V2_SCHEMA &&
    state.e1rmFormulaVersion === SHOWCASE_FORMULA_VERSION &&
    state.rePointsFormulaVersion === RE_POINTS_FORMULA_VERSION &&
    state.aggregationVersion === SHOWCASE_V2_AGGREGATION_VERSION
  );
}

/** True when the athlete's published V2 is complete and current. */
function isBuiltV2(state, snapshot) {
  return isCurrentState(state) && isCurrentSnapshotV2(snapshot);
}

function isJobActive(job) {
  return !!(job && (job.status === 'queued' || job.status === 'running'));
}

/** Structural equality of two V2 day contributions (null-safe). */
function sameDayV2(a, b) {
  if (!sameDay(a, b)) return false;
  if (!a && !b) return true;
  return (
    (a.category || null) === (b.category || null) &&
    canonicalJson(a.bestPoints || null) === canonicalJson(b.bestPoints || null)
  );
}

async function scoringSex(store) {
  const raw = typeof store.getScoringSex === 'function' ? await store.getScoringSex() : null;
  return scoringSexOf(raw);
}

/**
 * A memoised as-of bodyweight lookup using the store's BOUNDED single-date
 * query per date.
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

/** Candidate (points first) wins over current only on strictly more points. */
function betterPointsRecord(cand, cur) {
  if (!cand || typeof cand.rePoints !== 'number') return false;
  if (!cur || typeof cur.rePoints !== 'number') return true;
  if (greater(cand.rePoints, cur.rePoints)) return true;
  if (greater(cur.rePoints, cand.rePoints)) return false;
  if (cand.dateKey !== cur.dateKey) return cand.dateKey < cur.dateKey;
  return cand.setKey < cur.setKey;
}

/**
 * Re-folds [slot] from its day contributions. Returns the entry (or null when
 * the exercise has no day left), or `{ overflow: true }` when the exercise has
 * more days than a trigger may fold in place.
 */
async function refoldSlot(store, slot, sex) {
  const def = reExerciseBySlot(slot);
  const days = await store.listDaysForSlot(slot, MAX_SLOT_DAYS + 1);
  if (days.length > MAX_SLOT_DAYS) return { overflow: true };
  const folded = foldExerciseV2(def, days, sex);
  return { entry: folded ? exerciseEntry(def, folded.e1rm, folded.heaviest, folded.points) : null };
}

async function requestRebuild(store, request) {
  if (typeof store.requestRebuild === 'function') await store.requestRebuild(request);
}

/**
 * Applies ONE workout day. `workoutData` is null when the document was deleted.
 *
 * Returns { changed, slots, path } with path:
 *   'noop'     nothing changed
 *   'append'   folded in place (chronological addition)
 *   'rebuild'  the changed exercises were re-folded from their days
 *   'queued'   the date's day contributions were written and a rebuild job
 *              requested or notified; nothing published
 */
async function applyWorkoutDayV2(store, dateKey, workoutData) {
  const sex = await scoringSex(store);
  let next = summarizeWorkoutDayV2(dateKey, workoutData, { sex });
  const seed = [];
  // Every RE exercise is scored at a bodyweight, so any day holding one costs
  // one bounded weigh-in lookup.
  if (Object.keys(next).length > 0 && canResolveBodyweight(store)) {
    const bw = await bodyweightLookup(store)(dateKey);
    seed.push([dateKey, bw]);
    next = summarizeWorkoutDayV2(dateKey, workoutData, { bodyweight: bw, sex });
  }
  const prior = await store.getDaysForDate(dateKey);

  const touched = new Set([...Object.keys(next), ...Object.keys(prior)]);
  const changed = [];
  for (const slot of touched) {
    if (!sameDayV2(next[slot] || null, prior[slot] || null)) changed.push(slot);
  }
  if (changed.length === 0) return { changed: false, slots: [], path: 'noop' };

  for (const slot of changed) {
    if (next[slot]) await store.setDay(slot, dateKey, next[slot]);
    else await store.deleteDay(slot, dateKey);
  }

  const job = typeof store.getRebuildJob === 'function' ? await store.getRebuildJob() : null;
  if (isJobActive(job)) {
    await store.noteRebuildTouch({ dateKeys: [dateKey] });
    return { changed: true, slots: changed, path: 'queued' };
  }

  const state = (await store.getState()) || {};
  const snapshot = await store.getSnapshot();
  if (!isBuiltV2(state, snapshot)) {
    // A genuinely first training day (no V2 yet and no other workout) can be
    // published directly; anything else is a history rebuild — as a job.
    const fresh =
      !state.schema &&
      !snapshot &&
      !(typeof store.hasOtherWorkouts === 'function' && (await store.hasOtherWorkouts(dateKey)));
    if (!fresh) {
      await requestRebuild(store, { mode: 'full', reason: state.schema ? 'stale' : 'first' });
      return { changed: true, slots: changed, path: 'queued' };
    }
  }

  const highWater = state.latestDateKey || '';
  const entries = snapshot && isCurrentSnapshotV2(snapshot) ? entriesOfSnapshotV2(snapshot) : {};
  const canAppend = changed.every((slot) => !prior[slot]) && dateKey > highWater;

  if (canAppend) {
    for (const slot of changed) {
      const def = reExerciseBySlot(slot);
      const day = next[slot];
      const cand = candidateRecords(day);
      const cur = entries[slot] || {};
      const e1rm = betterE1rmRecord(cand.e1rm, cur.e1rm) ? cand.e1rm : cur.e1rm;
      const heaviest = betterHeaviestRecord(cand.heaviest, cur.heaviest) ? cand.heaviest : cur.heaviest;
      const candPoints = day.bestPoints ? pointsRecordOf(def, day, day.bestPoints, sex) : null;
      const points = betterPointsRecord(candPoints, cur.points) ? candPoints : cur.points || null;
      entries[slot] = exerciseEntry(def, e1rm, heaviest, points);
    }
  } else {
    for (const slot of changed) {
      const res = await refoldSlot(store, slot, sex);
      if (res.overflow) {
        await requestRebuild(store, { mode: 'fold', reason: 'long-history' });
        return { changed: true, slots: changed, path: 'queued' };
      }
      if (res.entry) entries[slot] = res.entry;
      else delete entries[slot];
    }
  }

  await store.setSnapshot(snapshotV2FromEntries(entries));
  await store.setState(stateV2(dateKey > highWater ? dateKey : highWater));
  return { changed: true, slots: changed, path: canAppend ? 'append' : 'rebuild' };
}

/**
 * A weigh-in changed the bodyweight recorded for the dates in
 * [sinceDateKey, untilDateKey) (until exclusive; absent = open-ended). Every
 * exercise's day contributions in that range are re-scored — the bodyweight
 * affects every exercise's points, not only the bodyweight-loaded ones — and
 * the exercises that moved are re-folded.
 *
 * A change of sex (options.sex) re-scores everything and is requested as a
 * rebuild job.
 *
 * Returns { changed, reason?, slots?, path? }.
 */
async function refreshV2(store, options) {
  const opts = options || {};
  const job = typeof store.getRebuildJob === 'function' ? await store.getRebuildJob() : null;
  if (opts.sex) {
    const state = await store.getState();
    if (!state && !isJobActive(job)) return { changed: false, reason: 'no-snapshot' };
    await requestRebuild(store, { mode: 'fold', reason: 'sex' });
    return { changed: false, reason: 'queued', path: 'queued' };
  }
  const since = opts.sinceDateKey || '';
  const until = opts.untilDateKey || null;
  if (isJobActive(job)) {
    await store.noteRebuildTouch({ sinceDateKey: since });
    return { changed: false, reason: 'queued', path: 'queued' };
  }
  const state = await store.getState();
  const snapshot = await store.getSnapshot();
  if (!snapshot && !state) return { changed: false, reason: 'no-snapshot' };
  if (!isBuiltV2(state, snapshot)) {
    await requestRebuild(store, { mode: 'full', reason: 'stale' });
    return { changed: false, reason: 'queued', path: 'queued' };
  }
  if (!canResolveBodyweight(store)) return { changed: false, reason: 'no-resolver' };

  const days = await store.listDaysInRange(since, until, MAX_RANGE_DAYS + 1);
  if (days.length > MAX_RANGE_DAYS) {
    await requestRebuild(store, { mode: 'full', reason: 'weigh-in-range', sinceDateKey: since });
    return { changed: false, reason: 'queued', path: 'queued' };
  }
  const sex = await scoringSex(store);
  const bwByDate = await resolveBodyweights(store, [...new Set(days.map((d) => d.dateKey))]);
  const moved = new Set();
  for (const d of days) {
    const re = resummarizeDayV2(d, bwByDate.get(d.dateKey) || null, sex);
    if (sameDayV2(re, d)) continue;
    await store.setDay(re.slot, re.dateKey, re);
    moved.add(re.slot);
  }
  if (moved.size === 0) return { changed: false, reason: 'unchanged' };

  const entries = entriesOfSnapshotV2(snapshot);
  for (const slot of moved) {
    const res = await refoldSlot(store, slot, sex);
    if (res.overflow) {
      await requestRebuild(store, { mode: 'fold', reason: 'long-history' });
      return { changed: true, reason: 'queued', path: 'queued' };
    }
    if (res.entry) entries[slot] = res.entry;
    else delete entries[slot];
  }
  const next = snapshotV2FromEntries(entries);
  if (canonicalJson(next.categories) === canonicalJson(snapshot.categories)) {
    return { changed: true, reason: 'days-only', slots: [...moved] };
  }
  await store.setSnapshot(next);
  return { changed: true, slots: [...moved], path: 'range' };
}

/**
 * In-memory V2 store for unit tests and dry runs. Supports the rebuild job
 * interface consumed by rebuild_job.js.
 *
 * options: bodyweightAsOf(dateKey), sex (raw users/{uid}.sex),
 *          workouts() → [[dateKey, workoutData]] (the athlete's history).
 */
function memoryStoreV2(options) {
  const bodyweightAsOf = options && options.bodyweightAsOf;
  const workouts = options && options.workouts;
  let sex = options ? options.sex : undefined;
  const days = new Map();
  let state = null;
  let snapshot = null;
  let job = null;
  const allDays = () => [...days.values()].sort((a, b) =>
    a.dateKey < b.dateKey ? -1 : a.dateKey > b.dateKey ? 1 : a.slot < b.slot ? -1 : 1);
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
    async listDaysForSlot(slot, limit) {
      const out = allDays().filter((d) => d.slot === slot);
      return limit ? out.slice(0, limit) : out;
    },
    async listDaysInRange(since, until, limit) {
      const out = allDays().filter((d) => d.dateKey >= (since || '') && (!until || d.dateKey < until));
      return limit ? out.slice(0, limit) : out;
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
    async hasOtherWorkouts(dateKey) {
      if (typeof workouts !== 'function') return false;
      return workouts().some(([d]) => d !== dateKey);
    },
    async listWorkoutsFrom(fromDateKey, limit) {
      if (typeof workouts !== 'function') return [];
      return workouts()
        .filter(([d]) => d >= (fromDateKey || ''))
        .sort((a, b) => (a[0] < b[0] ? -1 : 1))
        .slice(0, limit);
    },
    // ── rebuild job ──
    async getRebuildJob() {
      return job ? JSON.parse(JSON.stringify(job)) : null;
    },
    async setRebuildJob(next) {
      job = next ? JSON.parse(JSON.stringify(next)) : null;
    },
    async requestRebuild(request) {
      const { mergeRebuildRequest } = require('./rebuild_job');
      job = mergeRebuildRequest(job, request, Date.now());
    },
    async noteRebuildTouch(touch) {
      const { noteTouch } = require('./rebuild_job');
      job = noteTouch(job, touch, Date.now());
    },
    async flush() {},
    ...(typeof bodyweightAsOf === 'function'
      ? { getBodyweightAsOf: (dateKey) => bodyweightAsOf(dateKey) }
      : {}),
    _days: days,
  };
}

module.exports = {
  MAX_SLOT_DAYS,
  MAX_RANGE_DAYS,
  dayDocIdV2,
  stateV2,
  isCurrentState,
  isBuiltV2,
  isJobActive,
  sameDayV2,
  applyWorkoutDayV2,
  refreshV2,
  memoryStoreV2,
  entriesFromDays,
  RE_EXERCISES,
};
