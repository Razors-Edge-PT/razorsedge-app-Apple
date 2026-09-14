// Current-training-week adherence. Pure module (no Firebase).
//
// Deliberately SEPARATE from the check-in coverage window in coverage.js.
// The two answer different questions and are allowed to disagree:
//
//   coverage window   – rolling, checkpoint-anchored (Mon↔Thu, extended to
//                       the same weekday 7d back when the previous check-in
//                       was not copied). Governs PB events, the "$n done"
//                       count and the copied/skipped state machine.
//   attendance week   – a FIXED Monday→Sunday calendar week chosen by the
//                       checkpoint (attendancePeriod): a Monday report shows
//                       the PRECEDING week, a Thursday report the current week
//                       counted through the checkpoint cutoff. Never anchored
//                       to the block start date.
//
// So a Thursday report legitimately reads "3 training days in the check-in
// window" beside "Training week … 1/4": three training dates inside the
// rolling coverage window, but only one calendar day since Monday.
//
// The weekly TARGET is the number of workout templates assigned to the block
// that governed the attendance week (resolveWeekBlock) — normally the active
// block, the same set the Workout Planner shows under it — NOT the
// planned_blocks weeks/days documents, which many athletes never populate.

'use strict';

const cov = require('./coverage');

/** Monday-first weekday order. */
const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/** Where a weekly target came from, or why it is unknown (never collapsed
 *  to 0). Only the two *Templates sources are KNOWN targets. */
const PLANNED_SOURCE = {
  templates: 'activeBlockTemplates',
  weekBlockTemplates: 'weekBlockTemplates',
  noActiveBlock: 'noActiveBlock',
  unavailable: 'unavailable',
  blockChanged: 'blockChangedDuringWeek',
  historicalUnavailable: 'historicalTargetUnavailable',
};

const KNOWN_SOURCES = new Set([PLANNED_SOURCE.templates, PLANNED_SOURCE.weekBlockTemplates]);

/**
 * The ATTENDANCE week a checkpoint report describes, in the coach's calendar
 * (checkpoint keys are already coach-timezone dates, so this is plain
 * calendar arithmetic — DST cannot move it).
 *
 *   Monday checkpoint   → the preceding Monday–Sunday, every day counted.
 *   Thursday checkpoint → the current Monday–Sunday, counted through the
 *                         report cutoff: days on/after the checkpoint itself
 *                         have not happened when the report is generated, so
 *                         they are `upcoming`, never missed sessions.
 *
 * cutoffKey is EXCLUSIVE and equals the checkpoint — the same boundary the
 * check-in coverage window uses (the checkpoint day's own training belongs to
 * the next report).
 *
 * @returns {{period: 'previousWeek'|'currentWeek', weekStart: string,
 *            weekEnd: string, cutoffKey: string}}
 */
function attendancePeriod(checkpointKey) {
  const wd = cov.weekdayOfKey(checkpointKey);
  if (wd === 'Mon') {
    const weekStart = cov.addDaysKey(checkpointKey, -7);
    return { period: 'previousWeek', weekStart, weekEnd: checkpointKey, cutoffKey: checkpointKey };
  }
  if (wd === 'Thu') {
    const weekStart = cov.addDaysKey(checkpointKey, -3);
    return {
      period: 'currentWeek', weekStart, weekEnd: cov.addDaysKey(weekStart, 7), cutoffKey: checkpointKey,
    };
  }
  throw new Error(`not a checkpoint key: ${checkpointKey} (${wd})`);
}

/** The date keys of [weekStart]'s week that fall before the cutoff — the
 *  only days whose training is read. */
function countedDateKeys(weekStart, cutoffKey) {
  return weekDateKeys(weekStart).filter((k) => !cutoffKey || k < cutoffKey);
}

/**
 * Which block's templates set the target for the attendance week.
 *
 * The weekly target is only meaningful for the block that governed that week.
 * A Monday report describes LAST week, so a block that became active on (or
 * after) the start of the reported week must not lend its target to it.
 *
 *   – active block with no start date, or starting on/before weekStart
 *       → the active block (the established template-based target; a missing
 *         start date keeps the pre-existing behaviour, since no block change
 *         can be detected);
 *   – active block starting inside the week (before weekEnd)
 *       → unknown: the week straddles two blocks;
 *   – active block starting on/after weekEnd (e.g. a new block from this
 *     Monday)
 *       → the latest other block starting on/before weekStart that had not
 *         ended before it; unknown when there is none.
 *
 * @param {{activeBlock: object|null, blocks: Array, weekStart: string, weekEnd: string}} opts
 *   blocks: [{blockId, name, startKey, endKey}] (may include the active block)
 * @returns {{block: object|null, historical: boolean, reason: string|null}}
 */
function resolveWeekBlock({ activeBlock, blocks, weekStart, weekEnd }) {
  if (!activeBlock) return { block: null, historical: false, reason: PLANNED_SOURCE.noActiveBlock };
  if (!activeBlock.startKey || activeBlock.startKey <= weekStart) {
    return { block: activeBlock, historical: false, reason: null };
  }
  if (activeBlock.startKey < weekEnd) {
    return { block: null, historical: false, reason: PLANNED_SOURCE.blockChanged };
  }
  let best = null;
  for (const b of blocks || []) {
    if (!b || !b.blockId || b.blockId === activeBlock.blockId) continue;
    if (!b.startKey || b.startKey > weekStart) continue;
    if (b.endKey && b.endKey < weekStart) continue;
    if (!best || b.startKey > best.startKey
        || (b.startKey === best.startKey && b.blockId < best.blockId)) {
      best = b;
    }
  }
  // Another block starting inside the week also makes the target ambiguous.
  const straddled = (blocks || []).some((b) => b && b.startKey
    && b.startKey > weekStart && b.startKey < weekEnd);
  if (!best || straddled) {
    return { block: null, historical: true, reason: PLANNED_SOURCE.historicalUnavailable };
  }
  return { block: best, historical: true, reason: null };
}

/**
 * The target for the attendance week from the resolved block and the
 * athlete's templates. A HISTORICAL block with no templates still pointing at
 * it is unknown rather than 0: templates are re-pointed between blocks
 * (template repair, reassignment), so an empty result there is missing data,
 * not a rest week.
 */
function plannedForWeek(resolution, templates) {
  if (!resolution.block) return plannedTarget(null, resolution.reason || PLANNED_SOURCE.unavailable);
  if (!resolution.historical) return plannedFromTemplates(templates, resolution.block);
  const n = templatesForBlock(templates, resolution.block).length;
  return n > 0
    ? plannedTarget(n, PLANNED_SOURCE.weekBlockTemplates)
    : plannedTarget(null, PLANNED_SOURCE.historicalUnavailable);
}

/** HomeV2CalendarService._toNum: numbers as-is, numeric strings parsed,
 *  anything else 0. */
function calendarNum(v) {
  if (typeof v === 'number') return Number.isFinite(v) ? v : 0;
  if (typeof v === 'string') {
    const n = Number(v.trim());
    return v.trim() !== '' && Number.isFinite(n) ? n : 0;
  }
  return 0;
}

/**
 * Completed-workout day detection identical to HomeV2CalendarService
 * (_hasCompletedSets), the rule the planner/calendar shares: any set in the
 * logged `exercises[]` with weight > 0 AND reps > 0, reading the current
 * `weight`/`reps` fields and falling back to legacy `actualWeight`/
 * `actualReps`. Planner/plan fields (wesPlannedExercises, planned days) are
 * never consulted, so a completed workout on a "No exercises planned" day
 * counts and a planned-only or empty placeholder document does not.
 */
function hasCompletedSets(data) {
  const exercises = data && data.exercises;
  if (!Array.isArray(exercises)) return false;
  for (const ex of exercises) {
    if (!ex || typeof ex !== 'object') continue;
    const sets = ex.sets;
    if (!Array.isArray(sets)) continue;
    for (const s of sets) {
      if (!s || typeof s !== 'object') continue;
      const w = calendarNum(s.weight != null ? s.weight : s.actualWeight);
      const r = calendarNum(s.reps != null ? s.reps : s.actualReps);
      if (w > 0 && r > 0) return true;
    }
  }
  return false;
}

/** The Monday on or before dateKey. */
function mondayOfKey(dateKey) {
  const idx = WEEKDAYS.indexOf(cov.weekdayOfKey(dateKey));
  if (idx < 0) throw new Error(`bad dateKey: ${dateKey}`);
  return cov.addDaysKey(dateKey, -idx);
}

/**
 * The fixed calendar week containing dateKey.
 * @returns {{weekStart: string, weekEnd: string}} weekEnd is EXCLUSIVE (the
 *          following Monday), so Sunday belongs to this week and the next
 *          Monday does not.
 */
function calendarWeekOf(dateKey) {
  const weekStart = mondayOfKey(dateKey);
  return { weekStart, weekEnd: cov.addDaysKey(weekStart, 7) };
}

/** The seven date keys of the week starting at weekStart (Mon…Sun). */
function weekDateKeys(weekStart) {
  const out = [];
  for (let i = 0; i < 7; i++) out.push(cov.addDaysKey(weekStart, i));
  return out;
}

/**
 * Templates assigned to a block, using the association rules already
 * implemented client-side in lib/templates.dart (_templatesForBlock):
 *
 *   1. template.blockId === block doc id            (primary)
 *   2. template.blockAssignment === block.name      (legacy fallback, still
 *      present in production data written before blockId existed)
 *
 * Deduplicated by template document id, so a template that matches on both
 * rules is counted once.
 *
 * @param {Array<{id: string, blockId?: string, blockAssignment?: string}>} templates
 * @param {{blockId: string, name?: string|null}} block
 * @returns {Array} the matching templates, input order, deduplicated.
 */
function templatesForBlock(templates, block) {
  if (!block || !block.blockId) return [];
  const wantId = String(block.blockId).trim();
  const wantName = typeof block.name === 'string' ? block.name.trim() : '';

  const seen = new Set();
  const out = [];
  for (const t of templates || []) {
    if (!t || typeof t !== 'object') continue;
    const id = typeof t.id === 'string' ? t.id : null;
    if (!id || seen.has(id)) continue;

    const tmplBlockId = typeof t.blockId === 'string' ? t.blockId.trim() : '';
    const assign = typeof t.blockAssignment === 'string' ? t.blockAssignment.trim() : '';

    const matches = (tmplBlockId !== '' && tmplBlockId === wantId)
      || (wantName !== '' && assign !== '' && assign === wantName);
    if (!matches) continue;

    seen.add(id);
    out.push(t);
  }
  return out;
}

/**
 * A weekly target. `count` is null whenever the target is genuinely unknown
 * (no active block, or a read/schema failure) — never 0, because 0 would
 * read as "every planned workout completed".
 */
function plannedTarget(count, source) {
  const known = KNOWN_SOURCES.has(source) && Number.isFinite(count);
  return {
    count: known ? count : null,
    known,
    source,
  };
}

/** Target for an active block whose templates were read successfully. */
function plannedFromTemplates(templates, block) {
  return plannedTarget(templatesForBlock(templates, block).length, PLANNED_SOURCE.templates);
}

/**
 * Assembles the report payload for one calendar week.
 *
 * @param {Object} opts
 *   weekStart  Monday key of the week.
 *   planned    a plannedTarget().
 *   dayStats   map dateKey → { trained: bool, exerciseCount: number }; days
 *              absent from the map are untrained.
 *   blockId / blockName  provenance for the coach UI (may be null).
 *   cutoffKey  optional EXCLUSIVE cutoff: days on/after it are `upcoming`
 *              (counted:false, never trained, never a missed session).
 *   period     optional 'previousWeek' | 'currentWeek' (see attendancePeriod).
 * @returns {Object} currentWeekAdherence payload. `days` always has seven
 *          entries, Monday first.
 */
function buildWeekAdherence({
  weekStart, planned, dayStats, blockId, blockName, cutoffKey, period,
}) {
  const stats = dayStats || {};
  const days = weekDateKeys(weekStart).map((dateKey, i) => {
    const counted = !cutoffKey || dateKey < cutoffKey;
    const s = counted ? (stats[dateKey] || null) : null;
    const trained = !!(s && s.trained);
    const exerciseCount = trained && Number.isFinite(s.exerciseCount)
      ? s.exerciseCount : 0;
    return { dateKey, weekday: WEEKDAYS[i], trained, exerciseCount, counted };
  });

  const out = {
    weekStart,
    weekEnd: cov.addDaysKey(weekStart, 7),
    plannedCount: planned ? planned.count : null,
    plannedKnown: planned ? planned.known : false,
    plannedSource: planned ? planned.source : PLANNED_SOURCE.unavailable,
    blockId: blockId || null,
    blockName: blockName || null,
    // Unique calendar training DAYS — two sessions on one date count once.
    completedCount: days.filter((d) => d.trained).length,
    days,
  };
  if (cutoffKey) out.cutoffKey = cutoffKey;
  if (period) out.period = period;
  return out;
}

/**
 * Weekly-completion candidate for praise selection, on calendar weeks.
 *
 * `completedAll` is true only when the target is KNOWN and positive, so an
 * unknown or empty target can never be praised as "completed everything".
 */
function completionFromWeek(weekAdherence) {
  const planned = weekAdherence.plannedCount;
  const known = !!weekAdherence.plannedKnown;
  return {
    weekKey: weekAdherence.weekStart,
    weekStart: weekAdherence.weekStart,
    weekEnd: weekAdherence.weekEnd,
    plannedCount: planned,
    plannedKnown: known,
    completedCount: weekAdherence.completedCount,
    completedAll: known && planned > 0 && weekAdherence.completedCount >= planned,
  };
}

module.exports = {
  WEEKDAYS,
  PLANNED_SOURCE,
  hasCompletedSets,
  mondayOfKey,
  calendarWeekOf,
  attendancePeriod,
  countedDateKeys,
  weekDateKeys,
  templatesForBlock,
  plannedTarget,
  plannedFromTemplates,
  resolveWeekBlock,
  plannedForWeek,
  buildWeekAdherence,
  completionFromWeek,
};
