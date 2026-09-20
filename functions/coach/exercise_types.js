// Resolving an exercise's catalogue `type` on the server, at ONE bounded
// Firestore boundary.
//
// ── Why this exists ─────────────────────────────────────────────────────────
// An exercise is bodyweight-loaded when its id/name is in the hard-coded
// catalogue (bodyweight_exercises.js) OR its catalogue `type` is "Body Weight".
// WES2 now stamps that type onto every workout row it writes, so the normal
// incremental trigger and every offline write already carry it.
//
// HISTORICAL rows do not. For those the type is read from the canonical
// catalogue — `/exercises/{id}` first, then
// `/users/{athleteUid}/customExercises/{id}` — exactly the order the app's
// ExerciseCatalog.resolveExercise uses.
//
// ── The rules this module exists to enforce ─────────────────────────────────
//   * DISTINCT ids only, prefetched in one pass per workout day / per bulk
//     rebuild — never one read per set, and never one per row.
//   * The result is handed to the PURE engine (pb_engine, adherence) as plain
//     data. No Firestore read ever happens inside a per-set calculation.
//   * A per-instance cache, so a bulk rebuild over hundreds of days reads each
//     exercise document at most once. A NEGATIVE result (no such document, or
//     a document with no type) is cached too, so a missing exercise cannot
//     cause a re-read per day.
//
// `null` simply means "no type" — classification then falls back to the
// hard-coded id/name catalogue, which is exactly the pre-existing behaviour.

'use strict';

/** Every DISTINCT, non-empty exercise id in one workout document's rows. */
function exerciseIdsIn(workoutData) {
  const out = new Set();
  const exercises = Array.isArray(workoutData && workoutData.exercises)
    ? workoutData.exercises
    : [];
  for (const ex of exercises) {
    if (!ex || typeof ex !== 'object') continue;
    const raw = typeof ex.exerciseId === 'string' && ex.exerciseId
      ? ex.exerciseId
      : (typeof ex.id === 'string' ? ex.id : '');
    const id = String(raw || '').trim();
    if (id) out.add(id);
  }
  return [...out];
}

/**
 * The ids in [workoutData] whose rows carry NO `type` snapshot of their own —
 * the only ones a catalogue lookup can tell us anything new about.
 *
 * A row that carries its own type needs no read at all, which is what keeps
 * the normal incremental trigger free of extra Firestore work once WES2 has
 * been writing snapshots.
 */
function untypedExerciseIdsIn(workoutData) {
  const typed = new Set();
  const all = new Set(exerciseIdsIn(workoutData));
  const exercises = Array.isArray(workoutData && workoutData.exercises)
    ? workoutData.exercises
    : [];
  for (const ex of exercises) {
    if (!ex || typeof ex !== 'object') continue;
    if (typeof ex.type !== 'string' || !ex.type.trim()) continue;
    const raw = typeof ex.exerciseId === 'string' && ex.exerciseId
      ? ex.exerciseId
      : (typeof ex.id === 'string' ? ex.id : '');
    const id = String(raw || '').trim();
    if (id) typed.add(id);
  }
  return [...all].filter((id) => !typed.has(id));
}

/**
 * exerciseId → type, taken from the rows' OWN `type` snapshots. No I/O.
 *
 * This alone answers every workout written by a WES2 that stamps the snapshot.
 */
function typesFromRows(workoutData) {
  const out = new Map();
  const exercises = Array.isArray(workoutData && workoutData.exercises)
    ? workoutData.exercises
    : [];
  for (const ex of exercises) {
    if (!ex || typeof ex !== 'object') continue;
    if (typeof ex.type !== 'string' || !ex.type.trim()) continue;
    const raw = typeof ex.exerciseId === 'string' && ex.exerciseId
      ? ex.exerciseId
      : (typeof ex.id === 'string' ? ex.id : '');
    const id = String(raw || '').trim();
    if (id) out.set(id, ex.type.trim());
  }
  return out;
}

/**
 * A cached, batched exerciseId → catalogue-type resolver for one athlete.
 *
 * @param db           Firestore instance (admin SDK).
 * @param athleteUid   whose custom pool to fall back to.
 * @returns {{ resolve(ids: string[]): Promise<Map<string,string>>,
 *             forWorkout(workoutData): Promise<Map<string,string>> }}
 */
function makeExerciseTypeResolver(db, athleteUid) {
  // id → string type, or null for "looked up, has none". Both are cached, so a
  // bulk rebuild reads each exercise document at most once.
  const cache = new Map();

  async function resolve(ids) {
    const wanted = [...new Set((ids || [])
      .map((x) => String(x == null ? '' : x).trim())
      .filter(Boolean))];
    const missing = wanted.filter((id) => !cache.has(id));

    if (missing.length > 0 && db) {
      // Global pool first, in one getAll.
      const globalRefs = missing.map((id) => db.collection('exercises').doc(id));
      const globalSnaps = await db.getAll(...globalRefs);
      const stillMissing = [];
      globalSnaps.forEach((snap, i) => {
        const id = missing[i];
        if (snap && snap.exists) {
          cache.set(id, typeOf(snap.data()));
        } else {
          stillMissing.push(id);
        }
      });

      // Then this athlete's own custom pool, in one more getAll.
      if (stillMissing.length > 0 && athleteUid) {
        const customRefs = stillMissing.map((id) => db.collection('users')
          .doc(athleteUid).collection('customExercises').doc(id));
        const customSnaps = await db.getAll(...customRefs);
        customSnaps.forEach((snap, i) => {
          cache.set(stillMissing[i],
            snap && snap.exists ? typeOf(snap.data()) : null);
        });
      } else {
        for (const id of stillMissing) cache.set(id, null);
      }
    }

    const out = new Map();
    for (const id of wanted) {
      const t = cache.get(id);
      if (t) out.set(id, t);
    }
    return out;
  }

  /**
   * Every exercise type needed to classify [workoutData]: the rows' own
   * snapshots, plus a catalogue lookup for the ids that carry none.
   */
  async function forWorkout(workoutData) {
    const fromRows = typesFromRows(workoutData);
    const need = untypedExerciseIdsIn(workoutData);
    if (need.length === 0) return fromRows;
    const resolved = await resolve(need);
    for (const [id, t] of resolved) if (!fromRows.has(id)) fromRows.set(id, t);
    return fromRows;
  }

  return { resolve, forWorkout };
}

/** A catalogue document's `type`, trimmed, or null. */
function typeOf(data) {
  const t = data && data.type;
  if (typeof t !== 'string') return null;
  const trimmed = t.trim();
  return trimmed || null;
}

/** Merges several id→type maps into one (later entries never overwrite). */
function mergeTypeMaps(...maps) {
  const out = new Map();
  for (const m of maps) {
    if (!m) continue;
    for (const [k, v] of m) if (v && !out.has(k)) out.set(k, v);
  }
  return out;
}

module.exports = {
  exerciseIdsIn,
  untypedExerciseIdsIn,
  typesFromRows,
  makeExerciseTypeResolver,
  mergeTypeMaps,
};
