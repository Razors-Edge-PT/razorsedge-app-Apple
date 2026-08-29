// The five lifts the profile showcase celebrates, and the ONLY rules by which
// a logged exercise row may claim one of those slots.
//
// Pinned mirror of lib/profile/core/big_five.dart —
// test/profile_big_five_test.dart and test/showcase_reducer.test.js assert the
// same ids, aliases and rejections on both sides.
//
// Matching order:
//   1. STABLE ID — `exerciseId` (WES2) or legacy `id`, compared CASE-FOLDED.
//      Production workout documents written between 2026-03-03 and 2026-05-07
//      persisted lowercased copies of catalogue ids (see coach/pb_engine.js),
//      so folding is required to reunite one lift's history.
//   2. EXPLICIT LEGACY NAME ALIAS — only for rows carrying NO id at all, and
//      only against a closed, exact, case-insensitive list. The catalogue
//      contains "Larsen Bench Press", "Bench Press, Larsen Press",
//      "Bench Press, Narrow Grip", "Back Squat, Low bar", "Sumo Deadlift",
//      "Pull-Up" and a BILATERAL "Overhead Dumbbell Press", every one of which
//      must stay out of the showcase.
//
// Ids verified 2026-08-29 against assets/exercise_dump_20251109_112626.json.

'use strict';

const SLOTS = {
  BENCH: 'bench',
  SQUAT: 'squat',
  DEADLIFT: 'deadlift',
  CHIN_UP: 'chinUp',
  OHP_UNILATERAL: 'ohpUnilateral',
};

/** Display order used by the showcase UI. Persisted keys — never rename. */
const SLOT_ORDER = [
  SLOTS.BENCH,
  SLOTS.SQUAT,
  SLOTS.DEADLIFT,
  SLOTS.CHIN_UP,
  SLOTS.OHP_UNILATERAL,
];

const BIG_FIVE = [
  {
    slot: SLOTS.BENCH,
    exerciseId: 'AmfUWbF1DH3I7qPAdh5k',
    displayName: 'Bench Press, Barbell',
    legacyNameAliases: ['Bench Press, Barbell', 'Bench Press'],
  },
  {
    slot: SLOTS.SQUAT,
    exerciseId: 'heeBViVINHO6tUScSd6y',
    displayName: 'Back Squat, Barbell',
    legacyNameAliases: ['Back Squat, Barbell', 'Back Squat'],
  },
  {
    slot: SLOTS.DEADLIFT,
    exerciseId: 'MsGl7e9yanDeEnYX0e4X',
    displayName: 'Deadlift, Conventional',
    legacyNameAliases: ['Deadlift, Conventional', 'Deadlift'],
  },
  {
    slot: SLOTS.CHIN_UP,
    exerciseId: 'XM9026peNIu0R8qh7UqY',
    displayName: 'Chin-Up',
    // "Pull-Up" is a DIFFERENT catalogue exercise and is deliberately absent.
    legacyNameAliases: ['Chin-Up', 'Chin Up'],
  },
  {
    slot: SLOTS.OHP_UNILATERAL,
    exerciseId: 'RdsGazgdH0xgpjek0n3u',
    displayName: 'Overhead Dumbbell Press, Unilateral',
    // Bare "Overhead Dumbbell Press" is the BILATERAL exercise.
    legacyNameAliases: ['Overhead Dumbbell Press, Unilateral'],
  },
];

const BY_SLOT = new Map(BIG_FIVE.map((l) => [l.slot, l]));
const BY_FOLDED_ID = new Map(
  BIG_FIVE.map((l) => [l.exerciseId.toLowerCase(), l]),
);
const BY_FOLDED_ALIAS = new Map();
for (const lift of BIG_FIVE) {
  for (const alias of lift.legacyNameAliases) {
    BY_FOLDED_ALIAS.set(alias.trim().toLowerCase(), lift);
  }
}

function bigFiveBySlot(slot) {
  return BY_SLOT.get(slot) || null;
}

/** Folds an exercise id the way every showcase stream key is folded. */
function foldExerciseId(rawId) {
  if (typeof rawId !== 'string') return null;
  const t = rawId.trim();
  return t ? t.toLowerCase() : null;
}

/**
 * Resolves a logged exercise row to a Big Five lift, or null.
 *
 * A present id ALWAYS decides, even when it resolves to nothing: a row
 * carrying a real catalogue id for some other exercise must never be rescued
 * by its name. Only a completely id-less row falls through to the alias list.
 */
function matchBigFive(rawId, rawName) {
  const folded = foldExerciseId(rawId);
  if (folded !== null) return BY_FOLDED_ID.get(folded) || null;
  if (typeof rawName !== 'string') return null;
  return BY_FOLDED_ALIAS.get(rawName.trim().toLowerCase()) || null;
}

module.exports = {
  SLOTS,
  SLOT_ORDER,
  BIG_FIVE,
  bigFiveBySlot,
  foldExerciseId,
  matchBigFive,
};
