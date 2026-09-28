'use strict';

// Pure, Firestore-free planner for the week-1 RIR backfill.
//
// A port of the app's canonical rule, BlockExerciseDefaultsRepository
// .healWeek1RirPlan (lib/block_exercise_defaults_repository.dart), pinned to
// the Dart implementation by the shared vectors in
// test/fixtures/week1_rir_fill_vectors.json (asserted by BOTH
// functions/test/week1_rir_fill.test.js and test/week1_rir_heal_parity_test.dart).
//
// For one exercise's settings it returns ONLY the genuinely absent leaves:
//   * a whole `rirPlan.week1.sessionN.setM` entry that does not exist, for
//     sessions 1..(number of week-1 rep-target instances) and sets
//     1..(the session's planned set count: "reps x SETS" in its rep target,
//     else the exercise's own integer defaultSets), with the canonical
//     default RIR for that session/set and the session's reps;
//   * a `reps` leaf on an EXISTING set that has no `reps` key.
// It never touches a present value: an existing set without `rir` (an
// intentional blank), '' / 0 values, other weeks, other keys and unknown data
// are left alone. Anything it cannot derive without guessing is reported as
// ambiguous and produces no fill.

// Same matrix as BlockExerciseDefaultsRepository._defaultRirMatrix.
// Rows = sessions 1-4; columns = set1..set4.
const DEFAULT_RIR_MATRIX = [
  [2.0, 2.0, 2.5, 3.0],
  [2.0, 2.0, 2.5, 3.0],
  [2.0, 2.0, 2.5, 3.5],
  [2.5, 3.0, 3.0, 3.5],
];

const isMap = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

function defaultRir(sessionIndex, setIndex) {
  const row = DEFAULT_RIR_MATRIX[sessionIndex % DEFAULT_RIR_MATRIX.length];
  const col = setIndex < row.length ? setIndex : row.length - 1;
  return row[col].toFixed(1);
}

/**
 * @returns {{status: 'complete'|'fill'|'ambiguous'|'not-applicable',
 *            fills: Array<{path: string[], value: any, kind: 'set'|'reps'}>,
 *            reasons: string[]}}
 * `path` is relative to the exercise's settings object.
 */
function planWeek1RirFill(settings) {
  const fills = [];
  const reasons = [];
  if (!isMap(settings)) {
    return { status: 'ambiguous', fills, reasons: ['settings is not a map'] };
  }
  const repTargets = settings.repTargets;
  const week1Reps = isMap(repTargets) ? repTargets.week1 : undefined;
  if (!isMap(week1Reps)) {
    // No week-1 instances (e.g. DUP, Signature {min,max}): the app derives no
    // week-1 RIR structure from these, so there is nothing to fill.
    return { status: 'not-applicable', fills, reasons: ['no repTargets.week1 map'] };
  }
  const instanceKeys = Object.keys(week1Reps).filter((k) => k.startsWith('instance'));
  const sessionCount = instanceKeys.length;
  if (sessionCount === 0) {
    return { status: 'not-applicable', fills, reasons: ['no week-1 rep-target instances'] };
  }
  for (let i = 1; i <= sessionCount; i += 1) {
    if (!has(week1Reps, `instance${i}`)) {
      return {
        status: 'ambiguous',
        fills: [],
        reasons: [`week-1 instances are not contiguous (instance${i} missing)`],
      };
    }
  }

  const ds = settings.defaultSets;
  const defaultSets = Number.isInteger(ds) ? ds : null;

  const rirPlan = settings.rirPlan;
  if (rirPlan !== undefined && rirPlan !== null && !isMap(rirPlan)) {
    return { status: 'ambiguous', fills: [], reasons: ['rirPlan is not a map'] };
  }
  const week1 = isMap(rirPlan) ? rirPlan.week1 : undefined;
  if (week1 !== undefined && week1 !== null && !isMap(week1)) {
    return { status: 'ambiguous', fills: [], reasons: ['rirPlan.week1 is not a map'] };
  }

  for (let i = 0; i < sessionCount; i += 1) {
    const sessionKey = `session${i + 1}`;
    const repStr = String(week1Reps[`instance${i + 1}`] ?? '');
    const repMatch = /^(\d+)/.exec(repStr);
    const repsVal = repMatch ? repMatch[1] : null;
    const setsMatch = /x\s*(\d+)/.exec(repStr);
    let sessionSets;
    if (setsMatch) {
      sessionSets = parseInt(setsMatch[1], 10);
    } else if (defaultSets !== null) {
      sessionSets = defaultSets;
    } else {
      reasons.push(`${sessionKey}: set count unknown (no "x N" in rep target, `
        + `defaultSets ${ds === undefined ? 'absent' : JSON.stringify(ds)})`);
      continue;
    }
    if (sessionSets <= 0) continue;

    const session = isMap(week1) ? week1[sessionKey] : undefined;
    if (session !== undefined && session !== null && !isMap(session)) {
      reasons.push(`${sessionKey} is not a map`);
      continue;
    }
    for (let s = 0; s < sessionSets; s += 1) {
      const setKey = `set${s + 1}`;
      const existing = isMap(session) ? session[setKey] : undefined;
      if (existing === undefined || existing === null) {
        if (existing === null) {
          reasons.push(`${sessionKey}.${setKey} is null (explicit)`);
          continue;
        }
        fills.push({
          kind: 'set',
          path: ['rirPlan', 'week1', sessionKey, setKey],
          value: { rir: defaultRir(i, s), ...(repsVal !== null ? { reps: repsVal } : {}) },
        });
      } else if (!isMap(existing)) {
        reasons.push(`${sessionKey}.${setKey} is not a map`);
      } else if (repsVal !== null && !has(existing, 'reps')) {
        fills.push({
          kind: 'reps',
          path: ['rirPlan', 'week1', sessionKey, setKey, 'reps'],
          value: repsVal,
        });
      }
    }
  }

  if (reasons.length > 0) return { status: 'ambiguous', fills: [], reasons };
  return { status: fills.length ? 'fill' : 'complete', fills, reasons };
}

/** Applies [fills] to a deep copy of [settings] (for tests and parity). */
function applyFills(settings, fills) {
  const out = JSON.parse(JSON.stringify(settings));
  for (const f of fills) {
    let node = out;
    for (let i = 0; i < f.path.length - 1; i += 1) {
      const k = f.path[i];
      if (!isMap(node[k])) node[k] = {};
      node = node[k];
    }
    node[f.path[f.path.length - 1]] = f.value;
  }
  return out;
}

module.exports = { planWeek1RirFill, applyFills, DEFAULT_RIR_MATRIX };
