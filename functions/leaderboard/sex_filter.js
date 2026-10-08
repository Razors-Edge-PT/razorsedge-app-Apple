'use strict';

// Presentation groups use the actual profile choice, never scoring's fallback
// for an unknown/"Yes." value. The unfiltered board includes every athlete.
const SEX_FILTERS = Object.freeze(['all', 'male', 'female']);
const SEX_BOARD_SCHEMA_VERSION = 1;

function sexFilterOf(value) {
  if (typeof value !== 'string') return null;
  switch (value.trim().toLowerCase()) {
    case 'm': case 'male': return 'male';
    case 'f': case 'female': return 'female';
    default: return null;
  }
}

// Input is the full server-ranked pool. Filter BEFORE taking the top 20.
function selectSexEntries(entries, sexes, sex, limit = 20) {
  if (!SEX_FILTERS.includes(sex)) throw new Error('Invalid sex filter');
  return entries.filter(e => sex === 'all' || sexes.get(e.uid) === sex).slice(0, limit);
}

// Signed-in snapshots keep only the entry fields the app already reads. No
// private profile, birth date, age, scoring-sex fallback or sex value is copied.
function appSexBoard({ periodKey, sex, view, entries, generatedAt, ageModelVersion }) {
  if (!['male', 'female'].includes(sex) || !['raw', 'age'].includes(view)) throw new Error('Invalid sex board');
  const fields = view === 'age'
    ? ['uid', 'username', 'photoURL', 'tieBreakDateKey', 'ageModelVersion', 'ageComplete', 'adjustedTotalUnits', 'rawTotalPointsUnits']
    : ['uid', 'username', 'photoURL', 'tieBreakDateKey', 'totalPointsUnits', 'categoryExerciseBreakdown'];
  return { sexBoardSchemaVersion: SEX_BOARD_SCHEMA_VERSION, periodKey, sexFilter: sex,
    view, generatedAt, ...(view === 'age' ? { ageModelVersion } : {}),
    entries: entries.map(e => Object.fromEntries(fields.filter(k => e[k] !== undefined).map(k => [k, e[k]]))) };
}

module.exports = { SEX_FILTERS, SEX_BOARD_SCHEMA_VERSION, sexFilterOf, selectSexEntries, appSexBoard };
