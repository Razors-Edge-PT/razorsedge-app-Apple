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
// ── Bodyweight-loaded lifts (the Chin-Up) ───────────────────────────────────
// Their stored loads are not comparable as raw numbers (see bodyweight.js), so
// their candidates are ranked on the normalised loads, at the bodyweight
// recorded for that day. A bodyweight-loaded day contribution therefore also
// keeps every valid set of the day and the bodyweight it was ranked with:
// when a weigh-in changes that bodyweight the day can be re-ranked without
// reading the workout again. Every other lift keeps exactly the shape and the
// ordering it always had.
//
// ── Provenance ──────────────────────────────────────────────────────────────
// Every record carries workout date, exercise id, set identity, weight, reps,
// formula version and a fingerprint. The fingerprint identifies the SOURCE
// PERFORMANCE (slot + folded id + date + set key + weight + reps) and
// deliberately excludes the E1RM value, the formula version, the bodyweight
// and which achievement it satisfies, so that:
//   * one video proves both achievements when they share a set, and
//   * bumping the E1RM curve does not orphan every attached proof,
//   * but editing the source set's weight or reps DOES retire the proof.

'use strict';

const crypto = require('crypto');
const { matchBigFive, bigFiveBySlot, SLOT_ORDER } = require('./big_five');
const { showcaseE1rm, SHOWCASE_FORMULA_VERSION } = require('./e1rm_spec');
const {
  LoadBasis,
  isBodyweightSlot,
  setLoadBasis,
  typedAddedKg,
  normalizeCandidate,
  normalizedOfRecord,
  e1rmRank,
  heaviestRank,
  recordedBodyweight,
  recordFields,
} = require('./bodyweight');

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
      const entry = { setKey, weight, reps: Math.round(reps) };
      // Bodyweight-loaded lifts only, so every other slot keeps its exact
      // shape: what the stored weight means, and the typed added load the
      // legacy screen kept beside its total.
      if (lift.bodyweightLoaded) {
        entry.basis = setLoadBasis(s);
        if (entry.basis === LoadBasis.ABSOLUTE) {
          const typed = typedAddedKg(s);
          if (typed !== null) entry.typedAddedKg = typed;
        }
      }
      out[lift.slot].push(entry);
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

// ── Ranking ─────────────────────────────────────────────────────────────────
//
// Each candidate is reduced to a rank key, compared tier desc, value desc,
// tie desc. For every lift but the bodyweight-loaded ones the tier is constant
// and value/tie are the raw E1RM/weight, which is exactly the ordering the
// showcase has always used.

/** Rank key of a candidate set for BEST E1RM, at the day's bodyweight [bw]. */
function e1rmKeyOfSet(slot, set, bw) {
  if (!isBodyweightSlot(slot)) {
    return { tier: 0, value: showcaseE1rm(set.weight, set.reps), tie: set.weight };
  }
  return e1rmRank(normalizeCandidate(set, bw), set.reps);
}

/** Rank key of a candidate set for HEAVIEST, at the day's bodyweight [bw]. */
function heaviestKeyOfSet(slot, set, bw) {
  if (!isBodyweightSlot(slot)) return { tier: 0, value: set.weight };
  return heaviestRank(normalizeCandidate(set, bw));
}

/** Rank key of a published record for BEST E1RM. */
function e1rmKeyOfRecord(r) {
  if (!isBodyweightSlot(r.slot)) return { tier: 0, value: r.e1rm, tie: r.weight };
  return e1rmRank(normalizedOfRecord(r), r.reps);
}

/** Rank key of a published record for HEAVIEST. */
function heaviestKeyOfRecord(r) {
  if (!isBodyweightSlot(r.slot)) return { tier: 0, value: r.weight };
  return heaviestRank(normalizedOfRecord(r));
}

/** Three-way comparison of two rank keys. */
function compareKeys(a, b) {
  if (a.tier !== b.tier) return a.tier > b.tier ? 1 : -1;
  const byValue = cmpNum(a.value, b.value);
  if (byValue !== 0) return byValue;
  if (a.tie === undefined && b.tie === undefined) return 0;
  return cmpNum(a.tie, b.tie);
}

/** Later training date wins; same date → lexicographically smaller set key. */
function laterSource(aDate, bDate, aSetKey, bSetKey) {
  if (aDate !== bDate) return aDate > bDate;
  return aSetKey < bSetKey;
}

function betterE1rmWithinDay(slot, a, b, bw) {
  const byKey = compareKeys(e1rmKeyOfSet(slot, a, bw), e1rmKeyOfSet(slot, b, bw));
  if (byKey !== 0) return byKey > 0;
  return a.setKey < b.setKey;
}

function betterHeaviestWithinDay(slot, a, b, bw) {
  const byKey = compareKeys(heaviestKeyOfSet(slot, a, bw), heaviestKeyOfSet(slot, b, bw));
  if (byKey !== 0) return byKey > 0;
  if (a.reps !== b.reps) return a.reps > b.reps;
  return a.setKey < b.setKey;
}

/** The compact candidate stored in a day contribution. */
function candidateSet(set) {
  const out = { setKey: set.setKey, weight: set.weight, reps: set.reps };
  if (set.basis) out.basis = set.basis;
  if (typeof set.typedAddedKg === 'number') out.typedAddedKg = set.typedAddedKg;
  return out;
}

/**
 * One slot's contribution for one day, from that day's valid sets of the lift.
 * Within-day ordering is the lifetime ordering with the date term held
 * constant, so folding day winners equals scanning every set.
 */
function summarizeSlotDay(slot, dateKey, exerciseId, sets, bodyweight) {
  const bwLoaded = isBodyweightSlot(slot);
  const bw = bwLoaded ? recordedBodyweight(bodyweight) : null;
  let bestE = sets[0];
  let bestH = sets[0];
  for (let i = 1; i < sets.length; i++) {
    if (betterE1rmWithinDay(slot, sets[i], bestE, bw)) bestE = sets[i];
    if (betterHeaviestWithinDay(slot, sets[i], bestH, bw)) bestH = sets[i];
  }
  const out = {
    slot,
    dateKey,
    exerciseId,
    bestE1rm: candidateSet(bestE),
    heaviest: candidateSet(bestH),
  };
  if (bwLoaded) {
    out.sets = sets.map(candidateSet);
    out.bodyweight = bw;
  }
  return out;
}

/**
 * Reduces one workout document to at most five day contributions.
 *
 * `options.bodyweight` is the `{ weightKg, dateKey }` recorded on or before
 * [dateKey] (or null). Only bodyweight-loaded lifts read it.
 */
function summarizeWorkoutDay(dateKey, workoutData, options) {
  const bodyweight = (options && options.bodyweight) || null;
  const bySlot = extractBigFiveSets(workoutData);
  const casing = casingForDay(workoutData);
  const out = {};
  for (const slot of Object.keys(bySlot)) {
    const sets = bySlot[slot];
    if (!sets.length) continue;
    out[slot] = summarizeSlotDay(
      slot,
      dateKey,
      casing[slot] || bigFiveBySlot(slot).exerciseId,
      sets,
      bodyweight,
    );
  }
  return out;
}

/**
 * A stored bodyweight-loaded day contribution re-ranked at [bodyweight].
 *
 * Uses the day's stored sets; a contribution written before days kept them
 * falls back to its two candidates, which is the best it can do until that
 * workout is written again (or the backfill rebuilds it).
 */
function resummarizeDay(day, bodyweight) {
  let sets = Array.isArray(day.sets) && day.sets.length ? day.sets : null;
  if (!sets) {
    sets = [day.bestE1rm];
    if (day.heaviest && day.heaviest.setKey !== day.bestE1rm.setKey) sets.push(day.heaviest);
  }
  return summarizeSlotDay(day.slot, day.dateKey, day.exerciseId, sets.map(candidateSet), bodyweight);
}

function betterE1rmAcrossDays(a, b) {
  const byKey = compareKeys(
    e1rmKeyOfSet(a.slot, a.bestE1rm, a.bodyweight),
    e1rmKeyOfSet(b.slot, b.bestE1rm, b.bodyweight),
  );
  if (byKey !== 0) return byKey > 0;
  return laterSource(a.dateKey, b.dateKey, a.bestE1rm.setKey, b.bestE1rm.setKey);
}

function betterHeaviestAcrossDays(a, b) {
  const byKey = compareKeys(
    heaviestKeyOfSet(a.slot, a.heaviest, a.bodyweight),
    heaviestKeyOfSet(b.slot, b.heaviest, b.bodyweight),
  );
  if (byKey !== 0) return byKey > 0;
  if (a.heaviest.reps !== b.heaviest.reps) return a.heaviest.reps > b.heaviest.reps;
  return laterSource(a.dateKey, b.dateKey, a.heaviest.setKey, b.heaviest.setKey);
}

/** The published record for candidate [set] of day contribution [day]. */
function recordOf(slot, day, set) {
  const record = {
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
  if (isBodyweightSlot(slot)) {
    const n = normalizeCandidate(set, day.bodyweight);
    // The E1RM of what was actually lifted, bodyweight included, whenever
    // the bodyweight is known; the stored number's otherwise.
    if (n.totalE1rm !== null) record.e1rm = n.totalE1rm;
    record.loadBasis = set.basis === LoadBasis.ADDED ? LoadBasis.ADDED : LoadBasis.ABSOLUTE;
    Object.assign(record, recordFields(n, day.bodyweight));
  }
  return record;
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

/**
 * Whole-history rebuild. workoutsByDate: { 'YYYY-MM-DD': workoutData }.
 * `options.bodyweightByDate`: { 'YYYY-MM-DD': { weightKg, dateKey } | null },
 * the bodyweight recorded on or before each date.
 */
function buildShowcase(workoutsByDate, options) {
  const bodyweightByDate = (options && options.bodyweightByDate) || {};
  const all = [];
  for (const dateKey of Object.keys(workoutsByDate).sort()) {
    const day = summarizeWorkoutDay(dateKey, workoutsByDate[dateKey], {
      bodyweight: bodyweightByDate[dateKey] || null,
    });
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
  resummarizeDay,
  foldSlot,
  recordOf,
  e1rmKeyOfRecord,
  heaviestKeyOfRecord,
  compareKeys,
  snapshotFromLifts,
  buildShowcase,
  liveFingerprints,
  isEmptySnapshot,
  greater,
};
