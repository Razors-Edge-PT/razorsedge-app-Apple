// Client-draft composition shared by report generation and the copy
// transaction. Pure module.
//
// E1RM rebaseline semantics: when the E1RM formula version changes, the
// athlete's history is recomputed under the new formula and the state doc
// records e1rmRebaselinedAtKey (the rebaseline date). E1RM events dated
// BEFORE that key remain visible in the coach summary (reference), but are
// never praise-eligible in the client draft — so a formula change alone can
// never produce a "new E1RM PB" message. A genuine improvement lifted after
// the rebaseline is dated on/after the key and praises normally. Rep-target
// events are formula-independent and unaffected.

'use strict';

const { selectPraise } = require('./praise');
const { composeDraft } = require('./message');

/** Praise-eligible event split for a coverage window. */
function eligibleEvents({ events, coverageStart, coverageEnd, e1rmPraiseFloorKey }) {
  const inWindow = (e) => e.dateKey >= coverageStart && e.dateKey < coverageEnd;
  const all = events || [];
  const maxWeightEvents = all.filter((e) => e.type === 'maxWeightPB' && inWindow(e));
  const repEvents = all.filter((e) => e.type === 'repPB' && inWindow(e));
  const rirMatchEvents = all.filter((e) => e.type === 'rirMatchPB' && inWindow(e));
  const e1rmEvents = all.filter((e) => e.type === 'e1rmPB' && inWindow(e)
    && (!e1rmPraiseFloorKey || e.dateKey >= e1rmPraiseFloorKey));
  return { maxWeightEvents, repEvents, e1rmEvents, rirMatchEvents };
}

function completionInputFrom(completion, settings) {
  if (!completion) return null;
  const praisedWeeks = (settings && settings.praisedWeeks) || {};
  return {
    completedAll: !!completion.completedAll,
    count: completion.completedCount,
    planned: completion.plannedCount,
    weekAlreadyPraised: Object.prototype.hasOwnProperty.call(praisedWeeks, completion.weekKey),
  };
}

function allowedExercisesFrom(settings) {
  return (settings && settings.messageExerciseMode === 'custom')
    ? (Array.isArray(settings.customExerciseIds) ? settings.customExerciseIds : [])
    : null;
}

/**
 * Composes a client draft for a coverage window. Deterministic: same inputs
 * (including variantSeed) always produce the identical string.
 */
function buildDraftText({
  events, completion, settings, identity, bodyweight,
  coverageStart, coverageEnd, variantSeed, e1rmPraiseFloorKey,
}) {
  const { maxWeightEvents, repEvents, e1rmEvents, rirMatchEvents } = eligibleEvents({
    events, coverageStart, coverageEnd, e1rmPraiseFloorKey,
  });
  const { praises } = selectPraise({
    maxWeightEvents,
    repEvents,
    e1rmEvents,
    rirMatchEvents,
    completion: completionInputFrom(completion, settings),
    allowedExerciseIds: allowedExercisesFrom(settings),
  });
  return composeDraft({
    praises,
    bodyweight,
    gender: identity.gender,
    firstName: identity.firstName,
    variantSeed,
  }) || '';
}

/**
 * Which training week gets its completion praise recorded by a copy — only
 * when the deterministic praise selection actually used the completion slot
 * for this window (mirrors buildDraftText exactly).
 */
function computePraisedWeekKey(report, settings, coverage) {
  const completion = report.completion;
  if (!completion) return null;
  const praisedWeeks = (settings && settings.praisedWeeks) || {};
  if (Object.prototype.hasOwnProperty.call(praisedWeeks, completion.weekKey)) return null;
  const qualifies = completion.completedAll || completion.completedCount >= 3;
  if (!qualifies) return null;

  const { maxWeightEvents, repEvents, e1rmEvents, rirMatchEvents } = eligibleEvents({
    events: report.events || [],
    coverageStart: coverage.start,
    coverageEnd: coverage.end,
    e1rmPraiseFloorKey: report.e1rmPraiseFloorKey || null,
  });
  const { usedCompletion } = selectPraise({
    maxWeightEvents,
    repEvents,
    e1rmEvents,
    rirMatchEvents,
    completion: {
      completedAll: !!completion.completedAll,
      count: completion.completedCount,
      planned: completion.plannedCount,
      weekAlreadyPraised: false,
    },
    allowedExerciseIds: allowedExercisesFrom(settings),
  });
  return usedCompletion ? completion.weekKey : null;
}

module.exports = { buildDraftText, computePraisedWeekKey, eligibleEvents };
