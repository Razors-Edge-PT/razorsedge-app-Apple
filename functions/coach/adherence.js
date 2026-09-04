// Current-training-week adherence. Pure module (no Firebase).
//
// Deliberately SEPARATE from the check-in coverage window in coverage.js.
// The two answer different questions and are allowed to disagree:
//
//   coverage window   – rolling, checkpoint-anchored (Mon↔Thu, extended to
//                       the same weekday 7d back when the previous check-in
//                       was not copied). Governs PB events, the "$n done"
//                       count and the copied/skipped state machine.
//   adherence week    – a FIXED calendar week: Monday inclusive → the
//                       following Monday exclusive. Never anchored to the
//                       block start date.
//
// So a Thursday report legitimately reads "3 done · week 1/4 planned": three
// training dates inside the rolling coverage window, but only one calendar
// day since Monday.
//
// The weekly TARGET is the number of workout templates assigned to the
// athlete's currently-active block — the same set the Workout Planner shows
// under that block — NOT the planned_blocks weeks/days documents, which many
// athletes never populate.

'use strict';

const cov = require('./coverage');

/** Monday-first weekday order. */
const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/** Reasons a weekly target may be unknown (never collapsed to 0). */
const PLANNED_SOURCE = {
  templates: 'activeBlockTemplates',
  noActiveBlock: 'noActiveBlock',
  unavailable: 'unavailable',
};

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
  const known = source === PLANNED_SOURCE.templates && Number.isFinite(count);
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
 * @returns {Object} currentWeekAdherence payload. `days` always has seven
 *          entries, Monday first.
 */
function buildWeekAdherence({ weekStart, planned, dayStats, blockId, blockName }) {
  const stats = dayStats || {};
  const days = weekDateKeys(weekStart).map((dateKey, i) => {
    const s = stats[dateKey] || null;
    const trained = !!(s && s.trained);
    const exerciseCount = trained && Number.isFinite(s.exerciseCount)
      ? s.exerciseCount : 0;
    return { dateKey, weekday: WEEKDAYS[i], trained, exerciseCount };
  });

  return {
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
  mondayOfKey,
  calendarWeekOf,
  weekDateKeys,
  templatesForBlock,
  plannedTarget,
  plannedFromTemplates,
  buildWeekAdherence,
  completionFromWeek,
};
