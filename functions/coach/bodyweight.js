// Bodyweight analytics for coach check-ins. Pure module.
//
// Input entries mirror users/{uid}/weights docs:
//   { dateKey: 'YYYY-MM-DD', weightKg: number, tod: 'am'|'pm'|undefined }
// (missing tod is treated as 'am', matching BodyWeightTracker back-compat).
//
// Per-day collapse: one value per calendar day — AM preferred, PM used only
// when no AM entry exists that day. This follows the app's convention that
// averages are computed from a single AM/PM source (AM default) and prevents
// double-weighting a day that has both entries.
//
// Rolling comparison at a checkpoint date D (exclusive):
//   current  = mean of per-day values in [D-7, D)
//   previous = mean of per-day values in [D-14, D-7)
// Any number of weigh-ins (even one) makes a window usable.

'use strict';

const { addDaysKey } = require('./coverage');

const GOALS = ['cut', 'bulk', 'maintain'];
const MAINTAIN_BAND = 0.01;        // ±1 % of previous average counts as stable
const TREND_EPSILON_KG = 0.05;     // below this |delta| treat as flat for cut/bulk

/** Collapse raw entries to per-day values (AM preferred, else PM).
 *  Duplicate entries for the same day+TOD resolve deterministically to the
 *  one with the LATEST timestamp (tsMillis), matching the app's
 *  newest-first collapse in BodyWeightTracker; entries without a timestamp
 *  sort before any timestamped entry. */
function collapsePerDay(entries) {
  const byDay = {};
  for (const e of entries || []) {
    if (!e || typeof e.dateKey !== 'string') continue;
    const w = Number(e.weightKg);
    if (!Number.isFinite(w) || w <= 0) continue;
    const tod = e.tod === 'pm' ? 'pm' : 'am';
    const ts = Number.isFinite(e.tsMillis) ? e.tsMillis : -1;
    const cur = byDay[e.dateKey] || {};
    const prev = cur[tod];
    if (!prev || ts >= prev.ts) cur[tod] = { w, ts };
    byDay[e.dateKey] = cur;
  }
  const out = {};
  for (const [dateKey, v] of Object.entries(byDay)) {
    out[dateKey] = v.am ? v.am.w : v.pm.w;
  }
  return out;
}

function windowAverage(perDay, startKey, endKeyExclusive) {
  let sum = 0;
  let n = 0;
  for (const [dateKey, w] of Object.entries(perDay)) {
    if (dateKey >= startKey && dateKey < endKeyExclusive) {
      sum += w;
      n += 1;
    }
  }
  return n === 0 ? null : { average: sum / n, count: n };
}

/**
 * Rolling 7-day comparison at `checkpointKey`.
 * @returns {{ currentAvg, currentCount, previousAvg, previousCount }}
 *          averages are null when the window has no weigh-in.
 */
function rollingComparison(entries, checkpointKey) {
  const perDay = collapsePerDay(entries);
  const cur = windowAverage(perDay, addDaysKey(checkpointKey, -7), checkpointKey);
  const prev = windowAverage(perDay, addDaysKey(checkpointKey, -14), addDaysKey(checkpointKey, -7));
  return {
    currentAvg: cur ? round1(cur.average) : null,
    currentCount: cur ? cur.count : 0,
    previousAvg: prev ? round1(prev.average) : null,
    previousCount: prev ? prev.count : 0,
  };
}

/**
 * Classify the trend for a goal.
 * @returns one of:
 *   'onTrack'      – moving the right way (cut: down, bulk: up)
 *   'offTrack'     – flat or moving the wrong way for cut/bulk
 *   'stable'       – maintain within ±1 %
 *   'driftUp'      – maintain, above +1 %
 *   'driftDown'    – maintain, below −1 %
 *   'insufficient' – can't compare (either window empty)
 */
function classifyTrend(goal, currentAvg, previousAvg) {
  if (currentAvg == null || previousAvg == null) return 'insufficient';
  const delta = currentAvg - previousAvg;
  if (goal === 'maintain') {
    const band = MAINTAIN_BAND * previousAvg;
    if (Math.abs(delta) <= band) return 'stable';
    return delta > 0 ? 'driftUp' : 'driftDown';
  }
  if (goal === 'cut') return delta < -TREND_EPSILON_KG ? 'onTrack' : 'offTrack';
  if (goal === 'bulk') return delta > TREND_EPSILON_KG ? 'onTrack' : 'offTrack';
  return 'insufficient';
}

/**
 * 10 kg milestone detection on the ROLLING AVERAGE (not single weigh-ins).
 *
 * For cutting, crossing below a decade boundary (e.g. 110 → 109.x) awards
 * milestone id `cut_110`. For bulking, crossing at/above a boundary
 * (e.g. 89.x → 90.y) awards `bulk_90`. Maintaining awards nothing.
 *
 * @param {string} goal
 * @param {number|null} previousAvg  rolling avg from the preceding window
 * @param {number|null} currentAvg   rolling avg from the current window
 * @param {Object} awarded           { [milestoneId]: true } already-awarded set
 * @returns {string|null} newly awarded milestone id, or null
 */
function detectMilestone(goal, previousAvg, currentAvg, awarded) {
  if (previousAvg == null || currentAvg == null) return null;
  const has = (id) => awarded && Object.prototype.hasOwnProperty.call(awarded, id);
  if (goal === 'cut') {
    const prevDecade = Math.floor(previousAvg / 10);
    const curDecade = Math.floor(currentAvg / 10);
    if (curDecade < prevDecade) {
      const boundary = (curDecade + 1) * 10; // e.g. dropped below 110
      const id = `cut_${boundary}`;
      return has(id) ? null : id;
    }
  } else if (goal === 'bulk') {
    const prevDecade = Math.floor(previousAvg / 10);
    const curDecade = Math.floor(currentAvg / 10);
    if (curDecade > prevDecade) {
      const boundary = curDecade * 10; // e.g. reached 90
      const id = `bulk_${boundary}`;
      return has(id) ? null : id;
    }
  }
  return null;
}

// ── Milestone praise ownership ──────────────────────────────────────────────
//
// Milestone DETECTION (detectMilestone above) is an objective computation
// from the athlete's rolling averages and the coach's configured goal.
// Milestone PRAISE is coach-owned bookkeeping: each coach records which
// milestones THEY have praised, scoped to their current goal phase, in their
// own coachCheckIns/{coachUid}/athletes/{athleteUid}.praisedMilestones map.
// Consequences:
//   – two coaches never suppress each other (separate settings docs)
//   – undo removes only that coach's praise entry
//   – oscillation around a threshold stays suppressed within a phase because
//     the praise key is stable for that phase
//   – a later legitimate coaching phase (the coach re-sets the goal, which
//     stamps a new goalSetAt) produces a new phase key, so the same boundary
//     can be praised again years later
//   – cut_N and bulk_N are distinct ids and detection is goal-gated, so
//     directions never conflict and maintaining athletes get nothing.

/** Stable praise key for a milestone within a coach's current goal phase.
 *  goalPhase is the settings doc's goalSetAt (epoch ms, stamped whenever the
 *  coach changes the goal); absent → legacy single-phase key. */
function milestonePraiseKey(milestoneId, goalPhase) {
  const phase = (goalPhase === null || goalPhase === undefined || goalPhase === '')
    ? 'p0'
    : String(goalPhase);
  return `${milestoneId}@${phase}`;
}

/** Filters a praisedMilestones map down to { milestoneId: true } for one
 *  goal phase — the shape detectMilestone expects as its `awarded` set. */
function awardedForPhase(praisedMilestones, goalPhase) {
  const out = {};
  if (!praisedMilestones) return out;
  const suffix = `@${(goalPhase === null || goalPhase === undefined || goalPhase === '') ? 'p0' : String(goalPhase)}`;
  for (const key of Object.keys(praisedMilestones)) {
    if (key.endsWith(suffix)) out[key.slice(0, key.length - suffix.length)] = true;
  }
  return out;
}

// ── Bounded praise bookkeeping ──────────────────────────────────────────────
//
// praisedWeeks / praisedMilestones live on the coach's per-athlete settings
// doc. Both are pruned inside the copy transaction so neither map can grow
// indefinitely:
//   – praisedWeeks: message windows only look back days and completion
//     candidates only cover recent training weeks, so entries older than
//     ~26 weeks can never be consulted again.
//   – praisedMilestones: awardedForPhase only ever consults the CURRENT goal
//     phase, and a phase id is never reused (each goal change stamps a fresh
//     goalSetAt), so entries from other phases are dead and safe to drop.

const PRAISED_WEEKS_RETENTION_DAYS = 26 * 7;

function prunePraisedWeeks(praisedWeeks, todayKey) {
  const out = {};
  if (!praisedWeeks) return out;
  for (const [weekKey, v] of Object.entries(praisedWeeks)) {
    if (typeof weekKey === 'string'
        && daysBetween(weekKey, todayKey) <= PRAISED_WEEKS_RETENTION_DAYS) {
      out[weekKey] = v;
    }
  }
  return out;
}

function prunePraisedMilestones(praisedMilestones, goalPhase) {
  const out = {};
  if (!praisedMilestones) return out;
  const suffix = `@${(goalPhase === null || goalPhase === undefined || goalPhase === '') ? 'p0' : String(goalPhase)}`;
  for (const [key, v] of Object.entries(praisedMilestones)) {
    if (key.endsWith(suffix)) out[key] = v;
  }
  return out;
}

/**
 * Weigh-in staleness from the most recent valid weigh-in date.
 * @returns {'ok'|'due'|'overdue'}  due at 3 calendar days, overdue at 4+.
 */
function weighInStatus(lastWeighInKey, todayKey) {
  if (!lastWeighInKey) return 'overdue';
  const days = daysBetween(lastWeighInKey, todayKey);
  if (days >= 4) return 'overdue';
  if (days >= 3) return 'due';
  return 'ok';
}

function daysBetween(aKey, bKey) {
  const [ay, am, ad] = aKey.split('-').map(Number);
  const [by, bm, bd] = bKey.split('-').map(Number);
  const a = Date.UTC(ay, am - 1, ad);
  const b = Date.UTC(by, bm - 1, bd);
  return Math.round((b - a) / 86400000);
}

function round1(v) {
  return Math.round(v * 10) / 10;
}

module.exports = {
  GOALS,
  collapsePerDay,
  rollingComparison,
  classifyTrend,
  detectMilestone,
  milestonePraiseKey,
  awardedForPhase,
  prunePraisedWeeks,
  prunePraisedMilestones,
  PRAISED_WEEKS_RETENTION_DAYS,
  weighInStatus,
  daysBetween,
};
