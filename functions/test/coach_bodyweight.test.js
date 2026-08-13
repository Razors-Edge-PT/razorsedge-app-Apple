'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const bw = require('../coach/bodyweight');

function e(dateKey, weightKg, tod) {
  return { dateKey, weightKg, tod };
}

// ── Per-day collapse ────────────────────────────────────────────────────────

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

// ── Weigh-in staleness ──────────────────────────────────────────────────────

test('staleness: <3 days ok, 3 days due, 4+ days overdue', () => {
  assert.equal(bw.weighInStatus('2026-08-12', '2026-08-14'), 'ok');      // 2 days
  assert.equal(bw.weighInStatus('2026-08-11', '2026-08-14'), 'due');     // 3 days
  assert.equal(bw.weighInStatus('2026-08-10', '2026-08-14'), 'overdue'); // 4 days
  assert.equal(bw.weighInStatus(null, '2026-08-14'), 'overdue');
});
