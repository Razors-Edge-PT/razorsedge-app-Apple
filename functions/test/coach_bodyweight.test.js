'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const bw = require('../coach/bodyweight');

function e(dateKey, weightKg, tod) {
  return { dateKey, weightKg, tod };
}

// ── Per-day collapse ────────────────────────────────────────────────────────

test('collapse: duplicate same-TOD entries resolve to the latest timestamp', () => {
  const perDay = bw.collapsePerDay([
    { dateKey: '2026-08-10', weightKg: 100.0, tod: 'am', tsMillis: 1000 },
    { dateKey: '2026-08-10', weightKg: 100.6, tod: 'am', tsMillis: 2000 }, // corrected later
    { dateKey: '2026-08-10', weightKg: 99.0, tod: 'am', tsMillis: 500 },  // stale early entry
  ]);
  assert.deepEqual(perDay, { '2026-08-10': 100.6 });
});

test('collapse: entries without timestamps sort before timestamped ones', () => {
  const perDay = bw.collapsePerDay([
    { dateKey: '2026-08-10', weightKg: 99.0, tod: 'am' },              // legacy, no ts
    { dateKey: '2026-08-10', weightKg: 100.2, tod: 'am', tsMillis: 1 },
  ]);
  assert.deepEqual(perDay, { '2026-08-10': 100.2 });
});

test('collapse: AM preferred; PM only when no AM; no double-weighting', () => {
  const perDay = bw.collapsePerDay([
    e('2026-08-10', 100, 'am'),
    e('2026-08-10', 101.4, 'pm'),
    e('2026-08-11', 99.8, 'pm'),
    e('2026-08-12', 99.5), // missing tod → am (back-compat)
  ]);
  assert.deepEqual(perDay, {
    '2026-08-10': 100,
    '2026-08-11': 99.8,
    '2026-08-12': 99.5,
  });
});

// ── Rolling comparison ──────────────────────────────────────────────────────

test('rolling: current vs preceding 7-day windows', () => {
  const entries = [
    // previous window [Jul 27, Aug 3)
    e('2026-07-28', 102, 'am'),
    e('2026-07-30', 101.6, 'am'),
    // current window [Aug 3, Aug 10)
    e('2026-08-04', 101, 'am'),
    e('2026-08-08', 100.6, 'am'),
  ];
  const r = bw.rollingComparison(entries, '2026-08-10');
  assert.equal(r.previousAvg, 101.8);
  assert.equal(r.currentAvg, 100.8);
  assert.equal(r.currentCount, 2);
});

test('rolling: a single weigh-in in a window is still used', () => {
  const r = bw.rollingComparison([e('2026-08-09', 100, 'am')], '2026-08-10');
  assert.equal(r.currentAvg, 100);
  assert.equal(r.currentCount, 1);
  assert.equal(r.previousAvg, null);
});

test('rolling: checkpoint day itself is excluded (window end exclusive)', () => {
  const r = bw.rollingComparison([e('2026-08-10', 100, 'am')], '2026-08-10');
  assert.equal(r.currentAvg, null);
});

// ── Trend classification ────────────────────────────────────────────────────

test('trend: cutting downward → onTrack; flat/up → offTrack', () => {
  assert.equal(bw.classifyTrend('cut', 100.8, 101.8), 'onTrack');
  assert.equal(bw.classifyTrend('cut', 101.8, 101.8), 'offTrack');
  assert.equal(bw.classifyTrend('cut', 102.5, 101.8), 'offTrack');
});

test('trend: bulking upward → onTrack; flat/down → offTrack', () => {
  assert.equal(bw.classifyTrend('bulk', 82.4, 81.9), 'onTrack');
  assert.equal(bw.classifyTrend('bulk', 81.9, 81.9), 'offTrack');
  assert.equal(bw.classifyTrend('bulk', 81.2, 81.9), 'offTrack');
});

test('trend: maintaining within ±1% is stable, outside is drift', () => {
  assert.equal(bw.classifyTrend('maintain', 80.5, 80.0), 'stable');   // +0.6 %
  assert.equal(bw.classifyTrend('maintain', 81.0, 80.0), 'driftUp');  // +1.25 %
  assert.equal(bw.classifyTrend('maintain', 79.0, 80.0), 'driftDown');// −1.25 %
});

test('trend: empty window → insufficient', () => {
  assert.equal(bw.classifyTrend('cut', null, 100), 'insufficient');
  assert.equal(bw.classifyTrend('cut', 100, null), 'insufficient');
});

// ── Milestones ──────────────────────────────────────────────────────────────

test('milestone: cutting crossing under a 10kg boundary awarded once', () => {
  const awarded = {};
  const m1 = bw.detectMilestone('cut', 110.4, 109.8, awarded);
  assert.equal(m1, 'cut_110');
  awarded[m1] = true;
  // Oscillating back above and below again must NOT re-award
  assert.equal(bw.detectMilestone('cut', 110.2, 109.9, awarded), null);
});

test('milestone: bulking crossing over a boundary; maintaining never awards', () => {
  assert.equal(bw.detectMilestone('bulk', 89.6, 90.2, {}), 'bulk_90');
  assert.equal(bw.detectMilestone('maintain', 89.6, 90.2, {}), null);
});

test('milestone: uses rolling averages, no award without both windows', () => {
  assert.equal(bw.detectMilestone('cut', null, 109.8, {}), null);
});

// ── Milestone praise ownership (coach- and phase-scoped) ────────────────────

test('praise ownership: two coaches never suppress each other', () => {
  // Each coach's praisedMilestones map lives in their own settings doc.
  const coachAPraised = { [bw.milestonePraiseKey('cut_110', 1000)]: { reportId: 'r1' } };
  const coachBPraised = {}; // coach B has praised nothing

  const awardedA = bw.awardedForPhase(coachAPraised, 1000);
  const awardedB = bw.awardedForPhase(coachBPraised, 2000);

  // Coach A: suppressed. Coach B: still awardable for the same objective fact.
  assert.equal(bw.detectMilestone('cut', 110.4, 109.8, awardedA), null);
  assert.equal(bw.detectMilestone('cut', 110.4, 109.8, awardedB), 'cut_110');
});

test('praise ownership: undo removes only that coach\'s entry and re-enables praise', () => {
  const key = bw.milestonePraiseKey('cut_110', 1000);
  const praised = { [key]: { reportId: 'r1' } };
  assert.equal(bw.detectMilestone('cut', 110.4, 109.8, bw.awardedForPhase(praised, 1000)), null);
  delete praised[key]; // what coachUndoCheckIn does in the settings doc
  assert.equal(bw.detectMilestone('cut', 110.4, 109.8, bw.awardedForPhase(praised, 1000)), 'cut_110');
});

test('praise ownership: oscillation around the threshold stays suppressed within a phase', () => {
  const phase = 1000;
  const praised = {};
  const first = bw.detectMilestone('cut', 110.4, 109.8, bw.awardedForPhase(praised, phase));
  assert.equal(first, 'cut_110');
  praised[bw.milestonePraiseKey(first, phase)] = { reportId: 'r1' };
  // Weight bobs above and re-crosses the boundary — same phase, no re-award.
  assert.equal(bw.detectMilestone('cut', 110.2, 109.9, bw.awardedForPhase(praised, phase)), null);
  assert.equal(bw.detectMilestone('cut', 110.6, 109.7, bw.awardedForPhase(praised, phase)), null);
});

test('praise ownership: a later legitimate goal phase can praise the same boundary again', () => {
  // Praised during a cut in 2024 (phase 1000); athlete later bulked back up;
  // the coach re-sets the goal for a new cut in 2026 (phase 2000).
  const praised = { [bw.milestonePraiseKey('cut_110', 1000)]: { reportId: 'old' } };
  assert.equal(bw.detectMilestone('cut', 110.4, 109.8, bw.awardedForPhase(praised, 1000)), null);
  assert.equal(bw.detectMilestone('cut', 110.4, 109.8, bw.awardedForPhase(praised, 2000)), 'cut_110');
});

test('praise ownership: cut and bulk boundaries are distinct ids; maintain awards nothing', () => {
  const praised = { [bw.milestonePraiseKey('cut_110', 1000)]: {} };
  // A bulking phase through the same number is a different milestone id.
  assert.equal(bw.detectMilestone('bulk', 109.6, 110.2, bw.awardedForPhase(praised, 1000)), 'bulk_110');
  assert.equal(bw.detectMilestone('maintain', 110.4, 109.8, {}), null);
});

test('praise ownership: pruning keeps maps bounded without losing live entries', () => {
  // praisedWeeks: entries older than the retention horizon are dropped.
  const weeks = {
    '2026-08-03': 'r1',          // recent → kept
    '2025-01-06': 'ancient',     // > 26 weeks old → pruned
  };
  assert.deepEqual(bw.prunePraisedWeeks(weeks, '2026-08-14'), { '2026-08-03': 'r1' });

  // praisedMilestones: only the current goal phase's entries survive —
  // other phases are never consulted again (phase ids are never reused).
  const milestones = {
    'cut_110@1000': { reportId: 'old' },
    'cut_100@2000': { reportId: 'current' },
  };
  assert.deepEqual(bw.prunePraisedMilestones(milestones, 2000),
    { 'cut_100@2000': { reportId: 'current' } });
});

test('praise ownership: absent goalSetAt falls back to a stable legacy phase', () => {
  assert.equal(bw.milestonePraiseKey('cut_110', undefined), 'cut_110@p0');
  assert.equal(bw.milestonePraiseKey('cut_110', null), 'cut_110@p0');
  const praised = { 'cut_110@p0': {} };
  assert.deepEqual(bw.awardedForPhase(praised, undefined), { cut_110: true });
});

// ── Weigh-in staleness ──────────────────────────────────────────────────────

test('staleness: <3 days ok, 3 days due, 4+ days overdue', () => {
  assert.equal(bw.weighInStatus('2026-08-12', '2026-08-14'), 'ok');      // 2 days
  assert.equal(bw.weighInStatus('2026-08-11', '2026-08-14'), 'due');     // 3 days
  assert.equal(bw.weighInStatus('2026-08-10', '2026-08-14'), 'overdue'); // 4 days
  assert.equal(bw.weighInStatus(null, '2026-08-14'), 'overdue');
});

// ── Latest recorded weigh-in (date + its own weight) ───────────────────────

// BodyWeightTracker stamps an entry at device-local NOON of its chosen day.
const nzNoon = (dateKey) => Date.parse(`${dateKey}T00:00:00Z`); // 12:00 NZST
const TZ = 'Pacific/Auckland';

test('latest weigh-in: date and weight come from the same newest entry, not an average', () => {
  const latest = bw.pickLatestWeighIn([
    { id: 'a', weight: 74.0, unit: 'kg', tod: 'am', tsMillis: nzNoon('2026-09-08') },
    { id: 'b', weight: 73.2, unit: 'kg', tod: 'am', tsMillis: nzNoon('2026-09-10') },
    { id: 'c', weight: 73.9, unit: 'kg', tod: 'am', tsMillis: nzNoon('2026-09-09') },
  ], TZ);
  assert.deepEqual(latest, { dateKey: '2026-09-10', weight: 73.2, unit: 'kg', tod: 'am', entryId: 'b' });
});

test('latest weigh-in: same-day AM/PM entries share a timestamp — the tracker order decides', () => {
  const ts = nzNoon('2026-09-10');
  const entries = [
    { id: 'Aaa', weight: 73.2, tod: 'am', tsMillis: ts },
    { id: 'Zzz', weight: 73.9, tod: 'pm', tsMillis: ts },
  ];
  // Firestore orders equal timestamps by document id DESC under a desc order.
  const latest = bw.pickLatestWeighIn(entries, TZ);
  assert.equal(latest.entryId, 'Zzz');
  assert.equal(latest.weight, 73.9);
  assert.equal(latest.tod, 'pm');
  assert.deepEqual(bw.pickLatestWeighIn([...entries].reverse(), TZ), latest);
});

test('latest weigh-in: an edited latest entry reports its edited value and date', () => {
  const before = [{ id: 'x', weight: 80, tsMillis: nzNoon('2026-09-10') }];
  const after = [{ id: 'x', weight: 79.4, tsMillis: nzNoon('2026-09-11') }];
  assert.equal(bw.pickLatestWeighIn(before, TZ).weight, 80);
  assert.deepEqual(bw.pickLatestWeighIn(after, TZ),
    { dateKey: '2026-09-11', weight: 79.4, unit: 'kg', tod: 'am', entryId: 'x' });
});

test('latest weigh-in: deleting the latest falls back to the previous entry intact', () => {
  const remaining = [{ id: 'old', weight: 81.25, tsMillis: nzNoon('2026-06-02') }];
  const latest = bw.pickLatestWeighIn(remaining, TZ);
  assert.deepEqual(latest, { dateKey: '2026-06-02', weight: 81.25, unit: 'kg', tod: 'am', entryId: 'old' });
  // An old entry far outside every rolling-average window is still the latest.
  assert.equal(bw.weighInStatus(latest.dateKey, '2026-09-15'), 'overdue');
});

test('latest weigh-in: no history is null; an unusable weight is null, never 0', () => {
  assert.equal(bw.pickLatestWeighIn([], TZ), null);
  assert.equal(bw.pickLatestWeighIn([{ id: 'n', weight: 70, tsMillis: Number.NaN }], TZ), null);
  const bad = bw.pickLatestWeighIn([{ id: 'z', weight: 0, unit: 'LB', tsMillis: nzNoon('2026-09-10') }], TZ);
  assert.equal(bad.weight, null);
  assert.equal(bad.unit, 'lb');
});
