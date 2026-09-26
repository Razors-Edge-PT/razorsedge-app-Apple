// The RE Points exercise catalogue: the five profile CATEGORIES, the approved
// exercises inside each, their weighting factors, and the ONLY rules by which
// a logged exercise row may claim one of them.
//
// This is the single authoritative definition for the Functions runtime.
// Pinned mirror of lib/profile/core/re_catalog.dart — both suites assert
// functions/test/fixtures/re_catalog_parity.json, so ids, category
// membership, display names, bodyweight flags and factors cannot drift.
//
// ── Identity ────────────────────────────────────────────────────────────────
// Matching follows big_five.js exactly:
//   1. STABLE ID — `exerciseId` (WES2) or legacy `id`, compared CASE-FOLDED.
//      A present id ALWAYS decides, even when it resolves to nothing.
//   2. EXACT LEGACY NAME ALIAS — only for rows carrying NO id at all, against
//      a closed, case-insensitive list. Never fuzzy, never prefix: "Triceps Dip
//      Machine", "Bulgarian Split Squat, Deficit", "Pull-Up" and the bilateral
//      "Overhead Dumbbell Press" all stay out.
//
// ── `slot` ──────────────────────────────────────────────────────────────────
// Every exercise has a stable `slot` key. It is what the showcase records and
// fingerprints are keyed by. The five exercises that were the V1 Big Five keep
// their V1 slot keys (bench, squat, deadlift, chinUp, ohpUnilateral), so a V2
// record of the same performance has the SAME fingerprint as its V1 record and
// every proof video already attached keeps standing. Persisted — never rename.
//
// ── Loads ───────────────────────────────────────────────────────────────────
// `loadSemantics` records what the stored set weight means. None of them is
// ever doubled or otherwise rescaled: the factor already accounts for it.
//   total              the whole implement (barbell, machine stack)
//   perDumbbell        ONE dumbbell (the athlete holds one per hand, or presses
//                      one unilaterally)
//   bodyweightPlusAdded  bodyweight-loaded: see showcase/bodyweight.js

'use strict';

const { foldExerciseId } = require('./big_five');

const LoadSemantics = {
  TOTAL: 'total',
  PER_DUMBBELL: 'perDumbbell',
  BODYWEIGHT_PLUS_ADDED: 'bodyweightPlusAdded',
};

/** Semantic category keys. Persisted in profileShowcaseV2 — never rename. */
const CATEGORY_KEYS = {
  HORIZONTAL_PRESS: 'horizontalPress',
  VERTICAL_PULL: 'verticalPull',
  OVERHEAD_PRESS: 'overheadPress',
  HIP_HINGE: 'hipHinge',
  SQUAT_PATTERN: 'squatPattern',
};

/** Categories in display order. */
const RE_CATEGORIES = [
  { key: CATEGORY_KEYS.HORIZONTAL_PRESS, displayName: 'Horizontal Press' },
  { key: CATEGORY_KEYS.VERTICAL_PULL, displayName: 'Vertical Pull' },
  { key: CATEGORY_KEYS.OVERHEAD_PRESS, displayName: 'Overhead Press / Dip' },
  { key: CATEGORY_KEYS.HIP_HINGE, displayName: 'Hip Hinge' },
  { key: CATEGORY_KEYS.SQUAT_PATTERN, displayName: 'Squat Pattern' },
];

/**
 * Every approved exercise. Within a category the ORDER is the preference /
 * tie-break order, and the first entry is the category's primary exercise.
 */
const RE_EXERCISES = [
  // ── Horizontal Press ──
  {
    slot: 'bench',
    category: CATEGORY_KEYS.HORIZONTAL_PRESS,
    exerciseId: 'AmfUWbF1DH3I7qPAdh5k',
    displayName: 'Bench Press, Barbell',
    legacyNameAliases: ['Bench Press, Barbell', 'Bench Press'],
    factor: 1.0,
    bodyweightLoaded: false,
    loadSemantics: LoadSemantics.TOTAL,
  },
  {
    slot: 'dbBenchFlat',
    category: CATEGORY_KEYS.HORIZONTAL_PRESS,
    exerciseId: 'kTs5fLSTKjUkUZL10iii',
    displayName: 'Flat Bench Dumbbell Press',
    legacyNameAliases: ['Flat Bench Dumbbell Press'],
    factor: 2.11,
    bodyweightLoaded: false,
    loadSemantics: LoadSemantics.PER_DUMBBELL,
  },
  // ── Vertical Pull ──
  {
    slot: 'chinUp',
    category: CATEGORY_KEYS.VERTICAL_PULL,
    exerciseId: 'XM9026peNIu0R8qh7UqY',
    displayName: 'Chin-Up',
    // "Pull-Up" is a DIFFERENT catalogue exercise and is deliberately absent.
    legacyNameAliases: ['Chin-Up', 'Chin Up'],
    factor: 1.0,
    bodyweightLoaded: true,
    loadSemantics: LoadSemantics.BODYWEIGHT_PLUS_ADDED,
  },
  {
    slot: 'latPulldownSupinated',
    category: CATEGORY_KEYS.VERTICAL_PULL,
    exerciseId: '1XOIXxeLFhgmgjZS9Cyq',
    displayName: 'Lat Pull Down, Supinated',
    legacyNameAliases: ['Lat Pull Down, Supinated'],
    factor: 0.85,
    bodyweightLoaded: false,
    loadSemantics: LoadSemantics.TOTAL,
  },
  // ── Overhead Press / Dip ──
  {
    slot: 'ohpUnilateral',
    category: CATEGORY_KEYS.OVERHEAD_PRESS,
    exerciseId: 'RdsGazgdH0xgpjek0n3u',
    displayName: 'Overhead Dumbbell Press, Unilateral',
    // Bare "Overhead Dumbbell Press" is the BILATERAL exercise.
    legacyNameAliases: ['Overhead Dumbbell Press, Unilateral'],
    factor: 2.61,
    bodyweightLoaded: false,
    loadSemantics: LoadSemantics.PER_DUMBBELL,
  },
  {
    slot: 'ohpBarbell',
    category: CATEGORY_KEYS.OVERHEAD_PRESS,
    exerciseId: 'lVDG90yN6Z8aPjRNV2wc',
    displayName: 'Overhead Barbell Press',
    legacyNameAliases: ['Overhead Barbell Press'],
    factor: 1.53,
    bodyweightLoaded: false,
    loadSemantics: LoadSemantics.TOTAL,
  },
  {
    slot: 'tricepsDip',
    category: CATEGORY_KEYS.OVERHEAD_PRESS,
    exerciseId: 'FtayDmR5BVnGS1FXlXLL',
    displayName: 'Triceps Dip',
    // "Triceps Dip Machine" is a different exercise and is deliberately absent.
    legacyNameAliases: ['Triceps Dip'],
    factor: 0.63,
    bodyweightLoaded: true,
    loadSemantics: LoadSemantics.BODYWEIGHT_PLUS_ADDED,
  },
  // ── Hip Hinge ──
  {
    slot: 'deadlift',
    category: CATEGORY_KEYS.HIP_HINGE,
    exerciseId: 'MsGl7e9yanDeEnYX0e4X',
    displayName: 'Deadlift, Conventional',
    legacyNameAliases: ['Deadlift, Conventional', 'Deadlift'],
    factor: 0.74,
    bodyweightLoaded: false,
    loadSemantics: LoadSemantics.TOTAL,
  },
  {
    slot: 'deadliftSumo',
    category: CATEGORY_KEYS.HIP_HINGE,
    exerciseId: '10pEctikt6PP8eAg9Eip',
    // Catalogue name "Sumo Deadlift"; the profile shows the unambiguous form.
    displayName: 'Deadlift, Sumo',
    legacyNameAliases: ['Sumo Deadlift', 'Deadlift, Sumo'],
    factor: 0.74,
    bodyweightLoaded: false,
    loadSemantics: LoadSemantics.TOTAL,
  },
  {
    slot: 'hipThrustBarbell',
    category: CATEGORY_KEYS.HIP_HINGE,
    exerciseId: 'LGhFj8o0sG3X12296UAh',
    displayName: 'Hip Thrust, Barbell',
    legacyNameAliases: ['Hip Thrust, Barbell'],
    factor: 0.55,
    bodyweightLoaded: false,
    loadSemantics: LoadSemantics.TOTAL,
  },
  // ── Squat Pattern ──
  {
    slot: 'squat',
    category: CATEGORY_KEYS.SQUAT_PATTERN,
    exerciseId: 'heeBViVINHO6tUScSd6y',
    displayName: 'Back Squat, Barbell',
    legacyNameAliases: ['Back Squat, Barbell', 'Back Squat'],
    factor: 0.8,
    bodyweightLoaded: false,
    loadSemantics: LoadSemantics.TOTAL,
  },
  {
    slot: 'bulgarianSplitSquatDumbbell',
    category: CATEGORY_KEYS.SQUAT_PATTERN,
    exerciseId: 'ISXQqOEXLjMrPEs0xjgJ',
    // Catalogue name "Bulgarian Split Squat".
    displayName: 'Bulgarian Split Squat, Dumbbell',
    legacyNameAliases: ['Bulgarian Split Squat'],
    factor: 2.5,
    bodyweightLoaded: false,
    loadSemantics: LoadSemantics.PER_DUMBBELL,
  },
  {
    slot: 'bulgarianSplitSquatBarbell',
    category: CATEGORY_KEYS.SQUAT_PATTERN,
    exerciseId: 'VUEvvjuo4cxBghNuux66',
    displayName: 'Bulgarian Split Squat, Barbell',
    legacyNameAliases: ['Bulgarian Split Squat, Barbell'],
    factor: 1.25,
    bodyweightLoaded: false,
    loadSemantics: LoadSemantics.TOTAL,
  },
];

const BY_SLOT = new Map(RE_EXERCISES.map((e) => [e.slot, e]));
const BY_FOLDED_ID = new Map(RE_EXERCISES.map((e) => [e.exerciseId.toLowerCase(), e]));
const BY_FOLDED_ALIAS = new Map();
for (const ex of RE_EXERCISES) {
  for (const alias of ex.legacyNameAliases) {
    BY_FOLDED_ALIAS.set(alias.trim().toLowerCase(), ex);
  }
}
const BY_CATEGORY = new Map(
  RE_CATEGORIES.map((c) => [c.key, RE_EXERCISES.filter((e) => e.category === c.key)]),
);

/** The exercise for a stable slot key, or null. */
function reExerciseBySlot(slot) {
  return BY_SLOT.get(slot) || null;
}

/** The exercise for a catalogue id (any casing), or null. */
function reExerciseById(rawId) {
  if (typeof rawId !== 'string') return null;
  return BY_FOLDED_ID.get(rawId.trim().toLowerCase()) || null;
}

/** The category's exercises, in preference order. */
function reExercisesOfCategory(categoryKey) {
  return BY_CATEGORY.get(categoryKey) || [];
}

/**
 * Resolves a logged exercise row to an RE exercise, or null. Identical rules
 * to big_five.matchBigFive: a present id always decides.
 */
function matchReExercise(rawId, rawName) {
  const folded = foldExerciseId(rawId);
  if (folded !== null) return BY_FOLDED_ID.get(folded) || null;
  if (typeof rawName !== 'string') return null;
  return BY_FOLDED_ALIAS.get(rawName.trim().toLowerCase()) || null;
}

module.exports = {
  LoadSemantics,
  CATEGORY_KEYS,
  RE_CATEGORIES,
  RE_EXERCISES,
  reExerciseBySlot,
  reExerciseById,
  reExercisesOfCategory,
  matchReExercise,
};
