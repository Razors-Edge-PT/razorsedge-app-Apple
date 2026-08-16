// Training-praise selection for the client draft message. Pure module.
//
// Priority (highest first):
//   1. maxWeightPB   – new all-time heaviest weight on the exercise
//   2. repPB         – new rep-target PB (dominance-aware, see pb_engine.js)
//   3. e1rmPB        – new lifetime E1RM PB
//   4. rirMatchPB    – matched a standing PB at a strictly HIGHER logged RIR
//                      (same weight and reps, more reps in reserve)
//   5. completedAll  – completed every planned workout
//   6. threePlus     – completed at least three workouts
//
// Up to three slots; nothing is fabricated when no achievement qualifies.
// Bodyweight commentary and weigh-in prompts are composed separately and are
// NOT subject to this cap (see message.js).
//
// Deduplication: one performance never consumes two slots. A set that is both
// a new all-time heaviest weight AND a rep-target PB (which is the normal
// case — beating every prior weight necessarily beats every prior weight at
// reps >= R) is presented once, as the top-ranked all-time-heaviest item, with
// any same-day E1RM PB on that exercise attached as `alsoE1rm` rather than
// taking its own slot. Dedupe granularity is exerciseId+dateKey, so a single
// session's work on one lift reads as one achievement.

'use strict';

const MAX_SLOTS = 3;

/**
 * @param {Object} opts
 *   maxWeightEvents Array of maxWeightPB events inside the effective window.
 *   repEvents       Array of repPB events inside the effective window.
 *   e1rmEvents      Array of e1rmPB events inside the effective window.
 *   rirMatchEvents  Array of rirMatchPB events inside the effective window.
 *   completion      { completedAll, count, planned, weekAlreadyPraised } | null
 *   allowedExerciseIds  null (automatic mode) or Set/Array of exerciseIds
 *                       eligible for the client message (custom mode).
 * @returns {{ praises: Array, usedCompletion: 'all'|'threePlus'|null }}
 *   praises items:
 *     { kind:'maxWeightPB', event, alsoE1rm?: event }
 *     { kind:'repPB',       event, alsoE1rm?: event }
 *     { kind:'e1rmPB',      event }
 *     { kind:'rirMatchPB',  event }
 *     { kind:'completedAll' } | { kind:'threePlus', count }
 */
function selectPraise({
  maxWeightEvents, repEvents, e1rmEvents, rirMatchEvents, completion, allowedExerciseIds,
}) {
  const allowed = normalizeAllowed(allowedExerciseIds);
  const keep = (e) => allowed === null
    || allowed.has(String(e.exerciseId || '').toLowerCase())
    || allowed.has(String(e.catalogExerciseId || '').toLowerCase());

  const maxWeights = (maxWeightEvents || []).filter(keep).slice().sort(byImprovementDesc);
  const reps = (repEvents || []).filter(keep).slice().sort(byImprovementDesc);
  const e1rms = (e1rmEvents || []).filter(keep).slice().sort(byImprovementDesc);
  const rirMatches = (rirMatchEvents || []).filter(keep).slice().sort(byRirGainDesc);

  const praises = [];
  const usedExerciseDay = new Set();
  const dayKeyOf = (e) => `${e.exerciseId}_${e.dateKey}`;

  // Attaches a same-exercise, same-day E1RM PB to a weight-based praise so it
  // never consumes a second slot.
  const withTwin = (kind, ev) => {
    const twin = e1rms.find((x) => x.exerciseId === ev.exerciseId && x.dateKey === ev.dateKey);
    return twin ? { kind, event: ev, alsoE1rm: twin } : { kind, event: ev };
  };

  for (const ev of maxWeights) {
    if (praises.length >= MAX_SLOTS) break;
    if (usedExerciseDay.has(dayKeyOf(ev))) continue;
    usedExerciseDay.add(dayKeyOf(ev));
    praises.push(withTwin('maxWeightPB', ev));
  }

  for (const ev of reps) {
    if (praises.length >= MAX_SLOTS) break;
    if (usedExerciseDay.has(dayKeyOf(ev))) continue; // already told as all-time heaviest
    usedExerciseDay.add(dayKeyOf(ev));
    praises.push(withTwin('repPB', ev));
  }

  for (const ev of e1rms) {
    if (praises.length >= MAX_SLOTS) break;
    if (usedExerciseDay.has(dayKeyOf(ev))) continue; // already covered
    usedExerciseDay.add(dayKeyOf(ev));
    praises.push({ kind: 'e1rmPB', event: ev });
  }

  for (const ev of rirMatches) {
    if (praises.length >= MAX_SLOTS) break;
    if (usedExerciseDay.has(dayKeyOf(ev))) continue;
    usedExerciseDay.add(dayKeyOf(ev));
    praises.push({ kind: 'rirMatchPB', event: ev });
  }

  let usedCompletion = null;
  if (praises.length < MAX_SLOTS && completion && !completion.weekAlreadyPraised) {
    if (completion.completedAll && completion.planned > 0) {
      praises.push({ kind: 'completedAll' });
      usedCompletion = 'all';
    } else if (completion.count >= 3) {
      praises.push({ kind: 'threePlus', count: completion.count });
      usedCompletion = 'threePlus';
    }
  }

  return { praises, usedCompletion };
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

/** Deterministic ranking: pct improvement desc, then dateKey desc (newer
 *  first), then exerciseId asc, then reps asc — no ties left to chance. */
function byImprovementDesc(a, b) {
  const p = (b.pctImprovement || 0) - (a.pctImprovement || 0);
  if (p !== 0) return p;
  return byRecency(a, b);
}

/** RIR-match ranking: biggest GAIN in reps-in-reserve first (the performance
 *  that got easiest), then the same tiebreakers. */
function byRirGainDesc(a, b) {
  const ga = (a.rir || 0) - (a.prevRir || 0);
  const gb = (b.rir || 0) - (b.prevRir || 0);
  if (ga !== gb) return gb - ga;
  return byRecency(a, b);
}

function byRecency(a, b) {
  if (a.dateKey !== b.dateKey) return a.dateKey < b.dateKey ? 1 : -1;
  if (a.exerciseId !== b.exerciseId) return a.exerciseId < b.exerciseId ? -1 : 1;
  return (a.reps || 0) - (b.reps || 0);
}

module.exports = { selectPraise, MAX_SLOTS };
