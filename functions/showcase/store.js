// Storage-shape core for the always-on Big Five profile showcase projection.
//
// Pure module: all persistence goes through an injected `store` object, so the
// exact same code runs against Firestore in production and an in-memory store
// in tests.
//
// This projection is deliberately INDEPENDENT of Coach Mode. coachAnalytics is
// gated on a coach entitlement and is maintained for enrolled athletes only;
// the profile showcase must exist for every user, so it has its own trigger,
// its own documents and its own lifetime semantics. It reuses the coach
// engine's E1RM curve (via showcase/e1rm_spec → coach/e1rm) and nothing else,
// which keeps the arithmetic single-sourced without coupling the lifecycles.
//
// It is also kept strictly apart from the rolling 12-month RE / GoodLift
// points calculation: nothing here reads or writes rePoints* fields, and the
// only key this module ever writes on users_public is `profileShowcaseV1`.
//
// ── Documents ───────────────────────────────────────────────────────────────
//   users/{uid}/showcase/state
//     { schema, formulaVersion, latestDateKey, updatedAt }
//     latestDateKey is a monotonic HIGH-WATER MARK of every date ever applied.
//     It never decreases, so it can only ever force an extra rebuild — never
//     wrongly authorise the append fast path.
//
//   users/{uid}/showcaseDays/{slot}__{dateKey}
//     one compact day contribution (two candidate sets; for a bodyweight-loaded
//     lift also the day's sets and the bodyweight they were ranked at),
//     bounded per day.
//
//   users_public/{uid}.profileShowcaseV1
//     the presentation-ready snapshot, merged field-by-field.
//
// ── Cost model ──────────────────────────────────────────────────────────────
// FAST PATH (chronological append, the common case): 1 state read, 1 day read
// per slot touched, ≤5 day writes, 1 state write, 1 snapshot merge — plus one
// bounded weigh-in query when the day holds a bodyweight-loaded lift.
// Independent of history size.
// REBUILD (edit / delete / out-of-order): lists ONLY the affected slots' day
// docs and re-folds them. Bounded by how many days that athlete trained that
// one lift, never by total workout count.
// Both paths are deterministic and idempotent, so at-least-once trigger
// delivery, retries and duplicate events are safe.

'use strict';

const {
  PROFILE_SHOWCASE_SCHEMA,
  SHOWCASE_FORMULA_VERSION,
  summarizeWorkoutDay,
  resummarizeDay,
  foldSlot,
  recordOf,
  e1rmKeyOfRecord,
  heaviestKeyOfRecord,
  compareKeys,
  snapshotFromLifts,
} = require('./reducer');
const { SLOT_ORDER, bigFiveBySlot } = require('./big_five');
const { isBodyweightSlot, sameRecordedBodyweight } = require('./bodyweight');

function dayDocId(slot, dateKey) {
  return `${slot}__${dateKey}`;
}

function laterSource(a, b) {
  if (a.dateKey !== b.dateKey) return a.dateKey > b.dateKey;
  return a.setKey < b.setKey;
}

/**
 * e1rm desc, weight desc, dateKey desc, setKey asc — on the normalised values
 * for a bodyweight-loaded lift (see bodyweight.e1rmRank).
 */
function betterE1rmRecord(a, b) {
  if (!b) return true;
  if (!a) return false;
  const byKey = compareKeys(e1rmKeyOfRecord(a), e1rmKeyOfRecord(b));
  if (byKey !== 0) return byKey > 0;
  return laterSource(a, b);
}

/**
 * weight desc, reps desc, dateKey desc, setKey asc — the added load for a
 * bodyweight-loaded lift (see bodyweight.heaviestRank).
 */
function betterHeaviestRecord(a, b) {
  if (!b) return true;
  if (!a) return false;
  const byKey = compareKeys(heaviestKeyOfRecord(a), heaviestKeyOfRecord(b));
  if (byKey !== 0) return byKey > 0;
  if (a.reps !== b.reps) return a.reps > b.reps;
  return laterSource(a, b);
}

/** Day contribution → the two candidate records it offers. */
function candidateRecords(day) {
  return {
    e1rm: recordOf(day.slot, day, day.bestE1rm),
    heaviest: recordOf(day.slot, day, day.heaviest),
  };
}

function numOrNull(v) {
  return typeof v === 'number' ? v : null;
}

function sameSet(x, y) {
  return (
    x.setKey === y.setKey &&
    x.weight === y.weight &&
    x.reps === y.reps &&
    (x.basis || null) === (y.basis || null) &&
    numOrNull(x.typedAddedKg) === numOrNull(y.typedAddedKg)
  );
}

function sameSets(a, b) {
  const x = Array.isArray(a) ? a : null;
  const y = Array.isArray(b) ? b : null;
  if (!x || !y) return !x && !y;
  return x.length === y.length && x.every((s, i) => sameSet(s, y[i]));
}

/** Structural equality of two day contributions (null-safe). */
function sameDay(a, b) {
  if (!a && !b) return true;
  if (!a || !b) return false;
  // `basis`, the typed added load, the day's sets and its bodyweight are
  // compared so that a bodyweight-loaded day stored before it carried them
  // is rewritten the next time that date is saved.
  return (
    a.exerciseId === b.exerciseId &&
    sameSet(a.bestE1rm, b.bestE1rm) &&
    sameSet(a.heaviest, b.heaviest) &&
    sameSets(a.sets, b.sets) &&
    sameRecordedBodyweight(a.bodyweight, b.bodyweight)
  );
}

/**
 * The store's single-date bodyweight lookup, or null for a store that cannot
 * resolve one (every bodyweight-loaded set is then ranked as "bodyweight not
 * recorded").
 */
function bodyweightResolver(store) {
  return store && typeof store.getBodyweightAsOf === 'function'
    ? (dateKey) => store.getBodyweightAsOf(dateKey)
    : null;
}

function canResolveBodyweight(store) {
  return !!(store && (
    typeof store.getBodyweightAsOf === 'function' ||
    typeof store.getBodyweightAsOfMany === 'function'
  ));
}

/**
 * The bodyweight recorded on or before each of [dateKeys], as a Map. Uses the
 * store's bulk lookup when it has one (one weigh-in read for many dates).
 */
async function resolveBodyweights(store, dateKeys) {
  const out = new Map();
  const keys = [...new Set(dateKeys)];
  if (keys.length === 0 || !canResolveBodyweight(store)) return out;
  if (typeof store.getBodyweightAsOfMany === 'function') {
    const got = await store.getBodyweightAsOfMany(keys);
    for (const d of keys) out.set(d, (got && got.get(d)) || null);
    return out;
  }
  for (const d of keys) out.set(d, (await store.getBodyweightAsOf(d)) || null);
  return out;
}

function hasBodyweightSlot(summary) {
  return Object.keys(summary).some(isBodyweightSlot);
}

/**
 * Applies ONE workout day. `workoutData` is null when the document was deleted.
 *
 * Returns { changed, slots, path } — `path` is 'noop' | 'append' | 'rebuild',
 * which the tests and the backfill verifier assert on.
 */
async function applyWorkoutDay(store, dateKey, workoutData) {
  let next = summarizeWorkoutDay(dateKey, workoutData);
  // A bodyweight-loaded lift is ranked at the bodyweight recorded for this
  // date, so only a day that holds one costs a weigh-in lookup.
  if (hasBodyweightSlot(next) && canResolveBodyweight(store)) {
    const bw = (await resolveBodyweights(store, [dateKey])).get(dateKey) || null;
    next = summarizeWorkoutDay(dateKey, workoutData, { bodyweight: bw });
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
  // An ABSENT state is not a stale one: the athlete has simply never had a
  // showcase written. Only a state that exists and disagrees with the current
  // schema/formula forces the full rebuild.
  const hasState = !!state.schema;
  const versionCurrent =
    !hasState ||
    (state.formulaVersion === SHOWCASE_FORMULA_VERSION &&
      state.schema === PROFILE_SHOWCASE_SCHEMA);

  // The append fast path is only safe when every changed slot is a pure
  // ADDITION on a date strictly newer than anything ever applied, and the
  // stored snapshot was produced by the current schema + formula.
  const pureAddition = changed.every((slot) => !prior[slot]);
  const canAppend = versionCurrent && pureAddition && dateKey > highWater;

  const snapshot = (await store.getSnapshot()) || { lifts: {} };
  const lifts = Object.assign({}, snapshot.lifts || {});
  const rebuildSlots = versionCurrent ? changed : SLOT_ORDER;

  if (canAppend) {
    for (const slot of changed) {
      const cand = candidateRecords(next[slot]);
      const cur = lifts[slot] || { slot };
      lifts[slot] = {
        slot,
        e1rm: betterE1rmRecord(cand.e1rm, cur.e1rm) ? cand.e1rm : cur.e1rm,
        heaviest: betterHeaviestRecord(cand.heaviest, cur.heaviest)
          ? cand.heaviest
          : cur.heaviest,
      };
    }
  } else {
    for (const slot of rebuildSlots) {
      const days = await store.listDaysForSlot(slot);
      lifts[slot] = foldSlot(slot, days);
    }
  }

  await store.setSnapshot(snapshotFromLifts(lifts));
  await store.setState({
    schema: PROFILE_SHOWCASE_SCHEMA,
    formulaVersion: SHOWCASE_FORMULA_VERSION,
    latestDateKey: dateKey > highWater ? dateKey : highWater,
  });

  return {
    changed: true,
    slots: changed,
    path: canAppend ? 'append' : 'rebuild',
  };
}

/**
 * Deterministic whole-history rebuild for one athlete.
 * `entries` is [[dateKey, workoutData], ...] in any order — it is sorted here,
 * so the outcome cannot depend on read order.
 *
 * Never reads or writes workout documents; it only consumes what the caller
 * already read.
 */
async function rebuildAll(store, entries) {
  const sorted = [...entries].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  const plain = sorted.map(([dateKey, data]) => [dateKey, data, summarizeWorkoutDay(dateKey, data)]);
  const bwByDate = await resolveBodyweights(
    store,
    plain.filter(([, , day]) => hasBodyweightSlot(day)).map(([dateKey]) => dateKey),
  );
  const allDays = [];
  let latestDateKey = '';
  for (const [dateKey, data, plainDay] of plain) {
    const day = bwByDate.has(dateKey)
      ? summarizeWorkoutDay(dateKey, data, { bodyweight: bwByDate.get(dateKey) })
      : plainDay;
    for (const slot of Object.keys(day)) {
      allDays.push(day[slot]);
      await store.setDay(slot, dateKey, day[slot]);
    }
    if (dateKey > latestDateKey) latestDateKey = dateKey;
  }
  const lifts = {};
  for (const slot of SLOT_ORDER) lifts[slot] = foldSlot(slot, allDays);
  const snapshot = snapshotFromLifts(lifts);
  await store.setSnapshot(snapshot);
  await store.setState({
    schema: PROFILE_SHOWCASE_SCHEMA,
    formulaVersion: SHOWCASE_FORMULA_VERSION,
    latestDateKey,
  });
  return snapshot;
}

/** Key-order-independent JSON form, for value comparisons. */
function canonicalJson(value) {
  const canon = (v) => {
    if (Array.isArray(v)) return v.map(canon);
    if (v && typeof v === 'object') {
      const out = {};
      for (const k of Object.keys(v).sort()) out[k] = canon(v[k]);
      return out;
    }
    return v;
  };
  return JSON.stringify(canon(value === undefined ? null : value));
}

/**
 * Re-ranks the bodyweight-loaded days a weigh-in change can affect, and
 * republishes their lifts — used when a weigh-in is added, edited or deleted,
 * which changes the bodyweight for a lift date without touching any workout.
 *
 * `options.sinceDateKey`: the earliest day the changed weigh-in counted for
 * (before or after the change). Only days on or after it can have a different
 * bodyweight; without it every day of the lift is re-checked.
 *
 * Re-ranks from the sets each day contribution keeps, so no workout is read.
 * Writes nothing when nothing changed, so a repeated delivery is a no-op, and
 * it leaves a snapshot from another schema or formula alone for the next
 * workout write to rebuild.
 */
async function refreshBodyweight(store, options) {
  const sinceDateKey = (options && options.sinceDateKey) || '';
  if (!canResolveBodyweight(store)) return { changed: false, reason: 'no-resolver' };
  const snapshot = await store.getSnapshot();
  if (!snapshot || !snapshot.lifts) return { changed: false, reason: 'no-snapshot' };
  if (
    snapshot.schema !== PROFILE_SHOWCASE_SCHEMA ||
    snapshot.formulaVersion !== SHOWCASE_FORMULA_VERSION
  ) {
    return { changed: false, reason: 'stale-version' };
  }
  const slots = Object.keys(snapshot.lifts).filter(isBodyweightSlot);
  if (slots.length === 0) return { changed: false, reason: 'no-bodyweight-lift' };

  const lifts = Object.assign({}, snapshot.lifts);
  const moved = [];
  for (const slot of slots) {
    const days = await store.listDaysForSlot(slot);
    const affected = days.filter((d) => d.dateKey >= sinceDateKey);
    const bwByDate = await resolveBodyweights(store, affected.map((d) => d.dateKey));
    const nextDays = [];
    const rewritten = [];
    for (const d of days) {
      if (d.dateKey < sinceDateKey) {
        nextDays.push(d);
        continue;
      }
      const re = resummarizeDay(d, bwByDate.get(d.dateKey) || null);
      nextDays.push(re);
      if (!sameDay(re, d)) rewritten.push(re);
    }
    const folded = foldSlot(slot, nextDays);
    if (rewritten.length === 0 && canonicalJson(folded) === canonicalJson(snapshot.lifts[slot])) {
      continue;
    }
    for (const d of rewritten) await store.setDay(slot, d.dateKey, d);
    lifts[slot] = folded;
    moved.push(slot);
  }
  if (moved.length === 0) return { changed: false, reason: 'unchanged' };

  await store.setSnapshot(snapshotFromLifts(lifts));
  return { changed: true, slots: moved };
}

/**
 * In-memory store used by unit tests and by the migration's dry-run mode.
 *
 * `options.bodyweightAsOf(dateKey)` supplies the recorded bodyweight; without
 * it the store cannot resolve one, and bodyweight-loaded sets are ranked as
 * "bodyweight not recorded".
 */
function memoryStore(options) {
  const bodyweightAsOf = options && options.bodyweightAsOf;
  const days = new Map(); // dayDocId -> contribution
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
      for (const slot of SLOT_ORDER) {
        const d = days.get(dayDocId(slot, dateKey));
        if (d) out[slot] = d;
      }
      return out;
    },
    async listDaysForSlot(slot) {
      const out = [];
      for (const [id, d] of days) {
        if (id.startsWith(`${slot}__`)) out.push(d);
      }
      return out.sort((a, b) => (a.dateKey < b.dateKey ? -1 : 1));
    },
    async setDay(slot, dateKey, day) {
      days.set(dayDocId(slot, dateKey), day);
    },
    async deleteDay(slot, dateKey) {
      days.delete(dayDocId(slot, dateKey));
    },
    async flush() {},
    ...(typeof bodyweightAsOf === 'function'
      ? { getBodyweightAsOf: (dateKey) => bodyweightAsOf(dateKey) }
      : {}),
    _days: days,
  };
}

module.exports = {
  dayDocId,
  applyWorkoutDay,
  rebuildAll,
  refreshBodyweight,
  memoryStore,
  betterE1rmRecord,
  betterHeaviestRecord,
  candidateRecords,
  sameDay,
  bigFiveBySlot,
};
