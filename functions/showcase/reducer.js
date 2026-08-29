// Pure reducer that turns workout documents into the Big Five lifetime
// showcase. No Firebase imports — fully unit-testable, and pinned against
// lib/profile/core/showcase_reducer.dart.
//
// ── Shape ───────────────────────────────────────────────────────────────────
// Per (slot, dateKey) we keep ONE compact contribution: the day's best-E1RM
// candidate and the day's heaviest candidate. Lifetime state is a fold over
// those day contributions, so:
//   * a normal append folds one new day,
//   * an edit / delete / out-of-order write rebuilds ONE slot from ITS day
//     docs (bounded by how many days that athlete trained that lift),
//   * the snapshot is a pure function of the SURVIVING days — identical
//     whether reached by appending or rebuilding, which is what makes
//     at-least-once and out-of-order trigger delivery safe.
//
// ── Provenance ──────────────────────────────────────────────────────────────
// Every record carries workout date, exercise id, set identity, weight, reps,
// formula version and a fingerprint. The fingerprint identifies the SOURCE
// PERFORMANCE (slot + folded id + date + set key + weight + reps) and
// deliberately excludes the E1RM value, the formula version and which
// achievement it satisfies, so that:
//   * one video proves both achievements when they share a set, and
//   * bumping the E1RM curve does not orphan every attached proof,
//   * but editing the source set's weight or reps DOES retire the proof.

'use strict';

const crypto = require('crypto');
const { matchBigFive, bigFiveBySlot, SLOT_ORDER } = require('./big_five');
const { showcaseE1rm, SHOWCASE_FORMULA_VERSION } = require('./e1rm_spec');

/** Schema version of the compact snapshot mirrored into users_public. */
const PROFILE_SHOWCASE_SCHEMA = 'profileShowcaseV1';

/** Relative epsilon: absorbs float noise, never lets equality read as better. */
const EPS_REL = 1e-9;

function greater(a, b) {
  if (!Number.isFinite(a)) return false;
  if (!Number.isFinite(b)) return true;
  const scale = Math.max(Math.abs(a), Math.abs(b));
  return a - b > EPS_REL * (scale < 1 ? 1 : scale);
}

function cmpNum(a, b) {
  if (greater(a, b)) return 1;
  if (greater(b, a)) return -1;
  return 0;
}

/**
 * Deterministic fingerprint of a source performance.
 * Weight is canonicalised to 3dp so representation noise can never split one
 * performance into two fingerprints.
 */
function recordFingerprint({ slot, exerciseId, dateKey, setKey, weight, reps }) {
  const payload = [
    slot,
    String(exerciseId).toLowerCase(),
    dateKey,
    setKey,
    Number(weight).toFixed(3),
    String(reps),
  ].join('|');
  return crypto.createHash('sha256').update(payload, 'utf8').digest('hex').slice(0, 32);
}

/**
 * Extracts every valid completed Big Five set from one workout document.
 * A set participates only when weight > 0 AND reps > 0. RIR is never read.
 */
function extractBigFiveSets(workoutData) {
  const out = {};
  const ordinal = {}; // slot -> next positional index for that lift, that day
  const exercises = Array.isArray(workoutData && workoutData.exercises)
    ? workoutData.exercises
    : [];
  for (const row of exercises) {
    if (!row || typeof row !== 'object') continue;
    const rawId = row.exerciseId != null ? row.exerciseId : row.id;
    const lift = matchBigFive(rawId, row.name);
    if (!lift) continue;

    const sets = Array.isArray(row.sets) ? row.sets : [];
    for (const s of sets) {
      if (!s || typeof s !== 'object') continue;
      const rawW = s.weight != null ? s.weight : s.actualWeight;
      const rawR = s.reps != null ? s.reps : s.actualReps;
      if (typeof rawW !== 'number' || typeof rawR !== 'number') continue;
      const weight = rawW;
      const reps = rawR;
      if (!Number.isFinite(weight) || !Number.isFinite(reps)) continue;
      if (!(weight > 0) || !(reps > 0)) continue;

      // The positional fallback counts VALID sets of THIS lift within the day,
      // not the row/set position in the document. Reordering or deleting an
      // unrelated exercise therefore cannot shift another lift's set keys, so
      // fingerprints — and the proof videos attached to them — stay put.
      const n = ordinal[lift.slot] || 0;
      ordinal[lift.slot] = n + 1;

      const explicitId = s.id != null ? s.id : s.setId;
      const setKey =
        typeof explicitId === 'string' && explicitId.trim()
          ? explicitId.trim()
          : `s${n}`;

      if (!out[lift.slot]) out[lift.slot] = [];
      out[lift.slot].push({ setKey, weight, reps: Math.round(reps) });
    }
  }
  return out;
}

/** Best-known original casing of each slot's catalogue id within a document. */
function casingForDay(workoutData) {
  const casing = {};
  const exercises = Array.isArray(workoutData && workoutData.exercises)
    ? workoutData.exercises
    : [];
  for (const row of exercises) {
    if (!row || typeof row !== 'object') continue;
    const rawId = row.exerciseId != null ? row.exerciseId : row.id;
    const lift = matchBigFive(rawId, row.name);
    if (!lift) continue;
    if (typeof rawId === 'string' && rawId.trim()) {
      const id = rawId.trim();
      const existing = casing[lift.slot] || '';
      const existingIsFolded = existing === existing.toLowerCase();
      const candidateHasCase = id !== id.toLowerCase();
      if (!existing || (candidateHasCase && existingIsFolded)) casing[lift.slot] = id;
    } else if (!casing[lift.slot]) {
      casing[lift.slot] = lift.exerciseId;
    }
  }
  return casing;
}

function e1rmOf(set) {
  return showcaseE1rm(set.weight, set.reps);
}

function betterE1rmWithinDay(a, b) {
  const byE1rm = cmpNum(e1rmOf(a), e1rmOf(b));
  if (byE1rm !== 0) return byE1rm > 0;
  const byWeight = cmpNum(a.weight, b.weight);
  if (byWeight !== 0) return byWeight > 0;
  return a.setKey < b.setKey;
}

function betterHeaviestWithinDay(a, b) {
  const byWeight = cmpNum(a.weight, b.weight);
  if (byWeight !== 0) return byWeight > 0;
  if (a.reps !== b.reps) return a.reps > b.reps;
  return a.setKey < b.setKey;
}

/**
 * Reduces one workout document to at most five day contributions.
 * Within-day ordering is the lifetime ordering with the date term held
 * constant, so folding day winners equals scanning every set.
 */
function summarizeWorkoutDay(dateKey, workoutData) {
  const bySlot = extractBigFiveSets(workoutData);
  const casing = casingForDay(workoutData);
  const out = {};
  for (const slot of Object.keys(bySlot)) {
    const sets = bySlot[slot];
    if (!sets.length) continue;
    let bestE = sets[0];
    let bestH = sets[0];
    for (let i = 1; i < sets.length; i++) {
      if (betterE1rmWithinDay(sets[i], bestE)) bestE = sets[i];
      if (betterHeaviestWithinDay(sets[i], bestH)) bestH = sets[i];
    }
    out[slot] = {
      slot,
      dateKey,
      exerciseId: casing[slot] || bigFiveBySlot(slot).exerciseId,
      bestE1rm: { setKey: bestE.setKey, weight: bestE.weight, reps: bestE.reps },
      heaviest: { setKey: bestH.setKey, weight: bestH.weight, reps: bestH.reps },
    };
  }
  return out;
}

/** Later training date wins; same date → lexicographically smaller set key. */
function laterSource(aDate, bDate, aSetKey, bSetKey) {
  if (aDate !== bDate) return aDate > bDate;
  return aSetKey < bSetKey;
}

function betterE1rmAcrossDays(a, b) {
  const byE1rm = cmpNum(e1rmOf(a.bestE1rm), e1rmOf(b.bestE1rm));
  if (byE1rm !== 0) return byE1rm > 0;
  const byWeight = cmpNum(a.bestE1rm.weight, b.bestE1rm.weight);
  if (byWeight !== 0) return byWeight > 0;
  return laterSource(a.dateKey, b.dateKey, a.bestE1rm.setKey, b.bestE1rm.setKey);
}

function betterHeaviestAcrossDays(a, b) {
  const byWeight = cmpNum(a.heaviest.weight, b.heaviest.weight);
  if (byWeight !== 0) return byWeight > 0;
  if (a.heaviest.reps !== b.heaviest.reps) return a.heaviest.reps > b.heaviest.reps;
  return laterSource(a.dateKey, b.dateKey, a.heaviest.setKey, b.heaviest.setKey);
}

function recordOf(slot, day, set) {
  return {
    slot,
    exerciseId: day.exerciseId,
    dateKey: day.dateKey,
    setKey: set.setKey,
    weight: set.weight,
    reps: set.reps,
    e1rm: showcaseE1rm(set.weight, set.reps),
    formulaVersion: SHOWCASE_FORMULA_VERSION,
    fingerprint: recordFingerprint({
      slot,
      exerciseId: day.exerciseId,
      dateKey: day.dateKey,
      setKey: set.setKey,
      weight: set.weight,
      reps: set.reps,
    }),
  };
}

/** Folds day contributions for ONE slot into that slot's lifetime snapshot. */
function foldSlot(slot, days) {
  let bestE = null;
  let bestH = null;
  for (const d of days) {
    if (!d || d.slot !== slot) continue;
    if (!bestE || betterE1rmAcrossDays(d, bestE)) bestE = d;
    if (!bestH || betterHeaviestAcrossDays(d, bestH)) bestH = d;
  }
  if (!bestE || !bestH) return { slot };
  return {
    slot,
    e1rm: recordOf(slot, bestE, bestE.bestE1rm),
    heaviest: recordOf(slot, bestH, bestH.heaviest),
  };
}

function isEmptySnapshot(snap) {
  return !snap || (!snap.e1rm && !snap.heaviest);
}

/**
 * Presentation-ready snapshot mirrored into
 * users_public/{uid}.profileShowcaseV1. Deliberately carries no proof
 * pointers: proof media is social-gated and lives under users/{uid}/proofs.
 */
function snapshotFromLifts(liftSnapshots) {
  const lifts = {};
  for (const slot of SLOT_ORDER) {
    const s = liftSnapshots[slot];
    if (!isEmptySnapshot(s)) lifts[slot] = s;
  }
  return {
    schema: PROFILE_SHOWCASE_SCHEMA,
    formulaVersion: SHOWCASE_FORMULA_VERSION,
    lifts,
  };
}

/** Whole-history rebuild. workoutsByDate: { 'YYYY-MM-DD': workoutData }. */
function buildShowcase(workoutsByDate) {
  const all = [];
  for (const dateKey of Object.keys(workoutsByDate).sort()) {
    const day = summarizeWorkoutDay(dateKey, workoutsByDate[dateKey]);
    for (const slot of Object.keys(day)) all.push(day[slot]);
  }
  const lifts = {};
  for (const slot of SLOT_ORDER) lifts[slot] = foldSlot(slot, all);
  return snapshotFromLifts(lifts);
}

/** Every fingerprint standing as a live record in a snapshot. */
function liveFingerprints(snapshot) {
  const out = new Set();
  const lifts = (snapshot && snapshot.lifts) || {};
  for (const slot of Object.keys(lifts)) {
    const s = lifts[slot];
    if (s && s.e1rm) out.add(s.e1rm.fingerprint);
    if (s && s.heaviest) out.add(s.heaviest.fingerprint);
  }
  return out;
}

module.exports = {
  PROFILE_SHOWCASE_SCHEMA,
  SHOWCASE_FORMULA_VERSION,
  recordFingerprint,
  extractBigFiveSets,
  summarizeWorkoutDay,
  foldSlot,
  snapshotFromLifts,
  buildShowcase,
  liveFingerprints,
  isEmptySnapshot,
  greater,
};
