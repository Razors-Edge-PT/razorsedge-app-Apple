// Training-praise selection for the client draft message. Pure module.
//
// Priority: rep-target PBs > E1RM PBs > all-planned-completed > 3+ workouts.
// Up to three slots; nothing is fabricated when no achievement qualifies.
//
// Deduplication: when one lift produced both a rep PB and an E1RM PB on the
// same exercise+day, the rep PB wins the slot and the E1RM fact is attached
// to it (`alsoE1rm`) so the same achievement never consumes two slots.

'use strict';

const MAX_SLOTS = 3;

/**
 * @param {Object} opts
 *   repEvents    Array of repPB events inside the effective window.
 *   e1rmEvents   Array of e1rmPB events inside the effective window.
 *   completion   { completedAll: bool, count: number, planned: number,
 *                  weekAlreadyPraised: bool } | null
 *   allowedExerciseIds  null (automatic mode) or Set/Array of exerciseIds
 *                       eligible for the client message (custom mode).
 * @returns {{ praises: Array, usedCompletion: 'all'|'threePlus'|null }}
 *   praises items:
 *     { kind:'repPB', event, alsoE1rm?: event }
 *     { kind:'e1rmPB', event }
 *     { kind:'completedAll' } | { kind:'threePlus', count }
 */
function selectPraise({ repEvents, e1rmEvents, completion, allowedExerciseIds }) {
  const allowed = normalizeAllowed(allowedExerciseIds);
  const reps = (repEvents || [])
    .filter((e) => allowed === null || allowed.has(e.exerciseId))
    .slice()
    .sort(byImprovementDesc);
  const e1rms = (e1rmEvents || [])
    .filter((e) => allowed === null || allowed.has(e.exerciseId))
    .slice()
    .sort(byImprovementDesc);

  const praises = [];
  const usedExerciseDay = new Set();

  for (const ev of reps) {
    if (praises.length >= MAX_SLOTS) break;
    const dayKey = `${ev.exerciseId}_${ev.dateKey}`;
    usedExerciseDay.add(dayKey);
    // Attach a same-exercise E1RM PB from the same day instead of letting it
    // occupy its own slot later.
    const twin = e1rms.find(
      (x) => x.exerciseId === ev.exerciseId && x.dateKey === ev.dateKey
    );
    praises.push(twin ? { kind: 'repPB', event: ev, alsoE1rm: twin } : { kind: 'repPB', event: ev });
  }

  for (const ev of e1rms) {
    if (praises.length >= MAX_SLOTS) break;
    if (usedExerciseDay.has(`${ev.exerciseId}_${ev.dateKey}`)) continue; // already covered
    praises.push({ kind: 'e1rmPB', event: ev });
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

function normalizeAllowed(allowedExerciseIds) {
  if (allowedExerciseIds == null) return null;
  if (allowedExerciseIds instanceof Set) return allowedExerciseIds;
  return new Set(allowedExerciseIds);
}

/** Deterministic ranking: pct improvement desc, then dateKey desc (newer
 *  first), then exerciseId asc, then reps asc — no ties left to chance. */
function byImprovementDesc(a, b) {
  const p = (b.pctImprovement || 0) - (a.pctImprovement || 0);
  if (p !== 0) return p;
  if (a.dateKey !== b.dateKey) return a.dateKey < b.dateKey ? 1 : -1;
  if (a.exerciseId !== b.exerciseId) return a.exerciseId < b.exerciseId ? -1 : 1;
  return (a.reps || 0) - (b.reps || 0);
}

module.exports = { selectPraise, MAX_SLOTS };
