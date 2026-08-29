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
//     one compact day contribution (two candidate sets), bounded per day.
//
//   users_public/{uid}.profileShowcaseV1
//     the presentation-ready snapshot, merged field-by-field.
//
// ── Cost model ──────────────────────────────────────────────────────────────
// FAST PATH (chronological append, the common case): 1 state read, 1 day read
// per slot touched, ≤5 day writes, 1 state write, 1 snapshot merge. Independent
// of history size.
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
  foldSlot,
  snapshotFromLifts,
  greater,
} = require('./reducer');
const { SLOT_ORDER, bigFiveBySlot } = require('./big_five');
const { showcaseE1rm } = require('./e1rm_spec');
const { recordFingerprint } = require('./reducer');

function dayDocId(slot, dateKey) {
  return `${slot}__${dateKey}`;
}

function cmpNum(a, b) {
  if (greater(a, b)) return 1;
  if (greater(b, a)) return -1;
  return 0;
}

function laterSource(a, b) {
  if (a.dateKey !== b.dateKey) return a.dateKey > b.dateKey;
  return a.setKey < b.setKey;
}

/** e1rm desc, weight desc, dateKey desc, setKey asc. */
function betterE1rmRecord(a, b) {
  if (!b) return true;
  if (!a) return false;
  const byE1rm = cmpNum(a.e1rm, b.e1rm);
  if (byE1rm !== 0) return byE1rm > 0;
  const byWeight = cmpNum(a.weight, b.weight);
  if (byWeight !== 0) return byWeight > 0;
  return laterSource(a, b);
}

/** weight desc, reps desc, dateKey desc, setKey asc. */
function betterHeaviestRecord(a, b) {
  if (!b) return true;
  if (!a) return false;
  const byWeight = cmpNum(a.weight, b.weight);
  if (byWeight !== 0) return byWeight > 0;
  if (a.reps !== b.reps) return a.reps > b.reps;
  return laterSource(a, b);
}

/** Day contribution → the two candidate records it offers. */
function candidateRecords(day) {
  const mk = (set) => ({
    slot: day.slot,
    exerciseId: day.exerciseId,
    dateKey: day.dateKey,
    setKey: set.setKey,
    weight: set.weight,
    reps: set.reps,
    e1rm: showcaseE1rm(set.weight, set.reps),
    formulaVersion: SHOWCASE_FORMULA_VERSION,
    fingerprint: recordFingerprint({
      slot: day.slot,
      exerciseId: day.exerciseId,
      dateKey: day.dateKey,
      setKey: set.setKey,
      weight: set.weight,
      reps: set.reps,
    }),
  });
  return { e1rm: mk(day.bestE1rm), heaviest: mk(day.heaviest) };
}

/** Structural equality of two day contributions (null-safe). */
function sameDay(a, b) {
  if (!a && !b) return true;
  if (!a || !b) return false;
  const eq = (x, y) => x.setKey === y.setKey && x.weight === y.weight && x.reps === y.reps;
  return (
    a.exerciseId === b.exerciseId &&
    eq(a.bestE1rm, b.bestE1rm) &&
    eq(a.heaviest, b.heaviest)
  );
}

/**
 * Applies ONE workout day. `workoutData` is null when the document was deleted.
 *
 * Returns { changed, slots, path } — `path` is 'noop' | 'append' | 'rebuild',
 * which the tests and the backfill verifier assert on.
 */
async function applyWorkoutDay(store, dateKey, workoutData) {
  const next = summarizeWorkoutDay(dateKey, workoutData);
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
    const rebuildSlots = versionCurrent ? changed : SLOT_ORDER;
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
  const allDays = [];
  let latestDateKey = '';
  for (const [dateKey, data] of sorted) {
    const day = summarizeWorkoutDay(dateKey, data);
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

/** In-memory store used by unit tests and by the migration's dry-run mode. */
function memoryStore() {
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
    _days: days,
  };
}

module.exports = {
  dayDocId,
  applyWorkoutDay,
  rebuildAll,
  memoryStore,
  betterE1rmRecord,
  betterHeaviestRecord,
  candidateRecords,
  sameDay,
  bigFiveBySlot,
};
