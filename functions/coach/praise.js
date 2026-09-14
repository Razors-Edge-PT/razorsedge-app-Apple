// Achievement selection for the client draft message. Pure module.
//
// The draft is a factual list: one line per distinct qualifying PERFORMANCE
// (exercise + day + load + reps) inside the effective coverage window. There
// is no slot cap — every qualifying performance is listed — and nothing is
// fabricated when none qualifies. Weekly-completion praise is no longer part
// of the draft (attendance stays on the coach card only).
//
// Line priority (a performance is ranked by its highest kind):
//   1. maxWeightPB   – new all-time heaviest weight on the exercise
//   2. repPB         – new rep-target PB (dominance-aware, see pb_engine.js)
//   3. e1rmPB        – new lifetime E1RM PB that is not also one of the above
//   4. rirMatchPB    – matched a standing PB at a strictly HIGHER logged RIR
// then by improvement (desc), newer day, exercise id, reps — fully
// deterministic.
//
// Provenance. Every event carries the load and reps of the set it describes
// (an e1rmPB event carries its contributing set's weightKg/reps). An E1RM PB is
// therefore attached to a line ONLY when that contributing set IS the line's
// performance: same exercise id, same day, same load (within the engine's
// numeric tolerance) and same reps. Exercise/day matching alone is never
// enough; otherwise the E1RM PB gets its own line with its own set.
//
// Deduplication.
//   – One performance, several PB kinds (all-time heaviest + rep target +
//     E1RM, the normal case) → ONE line.
//   – Within one exercise on one day, a rep-target or RIR-match performance
//     that another listed performance of that session dominates (at least the
//     load AND at least the reps) is not listed again: e.g. a 145kg×6 back-off
//     set beside the same session's 150kg×8. All-time-heaviest and E1RM lines
//     are never removed this way.
// Identity is the stable (case-folded) exercise id — never the display name —
// so "Bench Press, Larsen Press" and "Bench Press, Barbell" stay distinct.

'use strict';

const { approxEqual, strictlyGreater } = require('./pb_engine');

const KIND_RANK = { maxWeightPB: 0, repPB: 1, e1rmPB: 2, rirMatchPB: 3 };

/**
 * @param {Object} opts
 *   maxWeightEvents / repEvents / e1rmEvents / rirMatchEvents
 *                   events of each type inside the effective window (already
 *                   E1RM-floor filtered, see draft.js)
 *   allowedExerciseIds  null (automatic mode) or an array/Set of exercise ids
 *                       eligible for the client message (custom mode).
 * @returns {Array<Object>} achievements, in presentation order:
 *   { exerciseId, catalogExerciseId, exerciseName, dateKey, weightKg, reps,
 *     bodyweightKg, maxWeight?: event, rep?: event, rirMatch?: event,
 *     e1rm?: event, kind }
 *   An E1RM event with no contributing set recorded (legacy data) yields an
 *   achievement with weightKg/reps null.
 */
function selectAchievements({
  maxWeightEvents, repEvents, e1rmEvents, rirMatchEvents, allowedExerciseIds,
}) {
  const allowed = normalizeAllowed(allowedExerciseIds);
  const keep = (e) => !!e && (allowed === null
    || allowed.has(String(e.exerciseId || '').toLowerCase())
    || allowed.has(String(e.catalogExerciseId || '').toLowerCase()));

  const items = [];
  const findPerformance = (ev) => items.find((it) => it.weightKg != null
    && it.exerciseId === ev.exerciseId
    && it.dateKey === ev.dateKey
    && it.reps === ev.reps
    && approxEqual(it.weightKg, ev.weightKg));

  const addToPerformance = (slot, ev) => {
    let it = findPerformance(ev);
    if (!it) {
      it = baseItem(ev, ev.weightKg, ev.reps);
      items.push(it);
    }
    if (!it[slot]) it[slot] = ev;
    return it;
  };

  for (const ev of (maxWeightEvents || []).filter(keep)) addToPerformance('maxWeight', ev);
  for (const ev of (repEvents || []).filter(keep)) addToPerformance('rep', ev);
  for (const ev of (rirMatchEvents || []).filter(keep)) addToPerformance('rirMatch', ev);
  for (const ev of (e1rmEvents || []).filter(keep)) {
    if (hasSet(ev)) {
      addToPerformance('e1rm', ev);
    } else {
      const it = baseItem(ev, null, null);
      it.e1rm = ev;
      items.push(it);
    }
  }

  const listed = items.filter((it) => !isDominatedInSession(it, items));
  for (const it of listed) it.kind = kindOf(it);
  return listed.sort(byPresentation);
}

function baseItem(ev, weightKg, reps) {
  return {
    exerciseId: ev.exerciseId,
    catalogExerciseId: ev.catalogExerciseId || null,
    exerciseName: ev.exerciseName,
    dateKey: ev.dateKey,
    weightKg,
    reps,
    bodyweightKg: typeof ev.bodyweightKg === 'number' ? ev.bodyweightKg : null,
  };
}

function hasSet(ev) {
  return typeof ev.weightKg === 'number' && ev.weightKg > 0
    && typeof ev.reps === 'number' && ev.reps > 0;
}

function kindOf(it) {
  if (it.maxWeight) return 'maxWeightPB';
  if (it.rep) return 'repPB';
  if (it.e1rm) return 'e1rmPB';
  return 'rirMatchPB';
}

/** A rep/RIR-only performance another performance of the SAME exercise-day
 *  session beats on load and reps (and differs from). */
function isDominatedInSession(it, all) {
  if (it.maxWeight || it.e1rm || it.weightKg == null) return false;
  return all.some((o) => o !== it
    && o.weightKg != null
    && o.exerciseId === it.exerciseId
    && o.dateKey === it.dateKey
    && !strictlyGreater(it.weightKg, o.weightKg)
    && o.reps >= it.reps
    && (strictlyGreater(o.weightKg, it.weightKg) || o.reps > it.reps));
}

/** Case-folded allow-set. Event.exerciseId is the folded stream key, while the
 *  coach's saved customExerciseIds are catalog ids in their original casing —
 *  fold both sides so a custom selection still matches after the identity
 *  canonicalisation (see pb_engine.canonicalExerciseId). */
function normalizeAllowed(allowedExerciseIds) {
  if (allowedExerciseIds == null) return null;
  const out = new Set();
  for (const id of allowedExerciseIds) {
    if (typeof id === 'string' && id.trim()) out.add(id.trim().toLowerCase());
  }
  return out;
}

function improvementOf(it) {
  const ev = it.maxWeight || it.rep || it.e1rm;
  if (ev) return ev.pctImprovement || 0;
  const r = it.rirMatch;
  return r ? (r.rir || 0) - (r.prevRir || 0) : 0;
}

function byPresentation(a, b) {
  const k = KIND_RANK[a.kind] - KIND_RANK[b.kind];
  if (k !== 0) return k;
  const p = improvementOf(b) - improvementOf(a);
  if (p !== 0) return p;
  if (a.dateKey !== b.dateKey) return a.dateKey < b.dateKey ? 1 : -1;
  if (a.exerciseId !== b.exerciseId) return a.exerciseId < b.exerciseId ? -1 : 1;
  const r = (a.reps || 0) - (b.reps || 0);
  if (r !== 0) return r;
  return (b.weightKg || 0) - (a.weightKg || 0);
}

module.exports = { selectAchievements };
