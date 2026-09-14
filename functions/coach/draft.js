// Client-draft composition shared by report generation, the existing-draft
// refresh and the copy transaction. Pure module.
//
// E1RM rebaseline semantics: when the E1RM formula version changes, the
// athlete's history is recomputed under the new formula and the state doc
// records e1rmRebaselinedAtKey (the rebaseline date). E1RM events dated
// BEFORE that key remain visible in the coach summary (reference), but are
// never eligible for the client draft — so a formula change alone can never
// produce a "New E1RM PB" line. A genuine improvement lifted after the
// rebaseline is dated on/after the key and is listed normally. Rep-target
// events are formula-independent and unaffected.

'use strict';

const { selectAchievements } = require('./praise');
const { composeDraft } = require('./message');

/**
 * Version of the draft COMPOSITION stored on a report (report.compositionVersion,
 * absent = 1). Bumping it makes coachReviewContext recompose eligible drafts
 * in place (see index.js refreshDraftReport).
 *   1: greeting/praise paragraphs, 3-slot cap, calendar week of the checkpoint
 *   2: factual achievement lines, un-addressed bodyweight lines, checkpoint-
 *      anchored attendance week
 */
const COMPOSITION_VERSION = 2;

/** Draft-eligible event split for a coverage window. */
function eligibleEvents({ events, coverageStart, coverageEnd, e1rmPraiseFloorKey }) {
  const inWindow = (e) => e && e.dateKey >= coverageStart && e.dateKey < coverageEnd;
  const all = events || [];
  const maxWeightEvents = all.filter((e) => inWindow(e) && e.type === 'maxWeightPB');
  const repEvents = all.filter((e) => inWindow(e) && e.type === 'repPB');
  const rirMatchEvents = all.filter((e) => inWindow(e) && e.type === 'rirMatchPB');
  const e1rmEvents = all.filter((e) => inWindow(e) && e.type === 'e1rmPB'
    && (!e1rmPraiseFloorKey || e.dateKey >= e1rmPraiseFloorKey));
  return { maxWeightEvents, repEvents, e1rmEvents, rirMatchEvents };
}

function allowedExercisesFrom(settings) {
  return (settings && settings.messageExerciseMode === 'custom')
    ? (Array.isArray(settings.customExerciseIds) ? settings.customExerciseIds : [])
    : null;
}

/** The achievements a draft for this window lists. */
function achievementsFor({ events, settings, coverageStart, coverageEnd, e1rmPraiseFloorKey }) {
  return selectAchievements({
    ...eligibleEvents({ events, coverageStart, coverageEnd, e1rmPraiseFloorKey }),
    allowedExerciseIds: allowedExercisesFrom(settings),
  });
}

/**
 * Composes a client draft for a coverage window. Deterministic: same inputs
 * (including variantSeed) always produce the identical string. `completion`
 * and `identity` are accepted for call-site compatibility and deliberately
 * unused: the draft carries no workout congratulations and no names.
 */
function buildDraftText({
  events, settings, bodyweight, coverageStart, coverageEnd, variantSeed, e1rmPraiseFloorKey,
}) {
  return composeDraft({
    achievements: achievementsFor({
      events, settings, coverageStart, coverageEnd, e1rmPraiseFloorKey,
    }),
    bodyweight,
    variantSeed,
  }) || '';
}

/**
 * Which training week a copy records as consistency-praised. Always null now:
 * the draft no longer contains a completion message, so nothing may be marked
 * as consumed. (Undo still removes entries that older copies recorded — see
 * checkin_txns.js.)
 */
function computePraisedWeekKey() {
  return null;
}

module.exports = {
  COMPOSITION_VERSION,
  buildDraftText,
  achievementsFor,
  computePraisedWeekKey,
  eligibleEvents,
};
