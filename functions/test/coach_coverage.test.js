'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const cov = require('../coach/coverage');

// Calendar reference (2026): Aug 3 Mon, Aug 6 Thu, Aug 10 Mon, Aug 13 Thu,
// Aug 17 Mon.

// ── Time zone / checkpoint detection ────────────────────────────────────────

test('tz: coach-local Monday detected across the UTC boundary (Auckland)', () => {
  // 2026-08-09 13:00 UTC = 2026-08-10 01:00 NZST (Monday in Auckland,
  // still Sunday in UTC).
  const now = new Date(Date.UTC(2026, 7, 9, 13, 0, 0));
  assert.equal(cov.currentCheckpointKey(now, 'Pacific/Auckland'), '2026-08-10');
  assert.equal(cov.currentCheckpointKey(now, 'UTC'), null); // Sunday in UTC
});

test('tz: Thursday boundary just before local midnight is still Wednesday', () => {
  // 2026-08-12 11:30 UTC = 2026-08-12 23:30 NZST (Wednesday) → no checkpoint
  const now = new Date(Date.UTC(2026, 7, 12, 11, 30, 0));
  assert.equal(cov.currentCheckpointKey(now, 'Pacific/Auckland'), null);
  // Half an hour later it is Thursday 00:00 NZST
  const later = new Date(Date.UTC(2026, 7, 12, 12, 0, 0));
  assert.equal(cov.currentCheckpointKey(later, 'Pacific/Auckland'), '2026-08-13');
});

test('tz: DST-observing zone works (NZ DST starts 27 Sep 2026, UTC+13)', () => {
  // 2026-09-27 12:00 UTC = 2026-09-28 01:00 NZDT (Monday, UTC+13 after
  // the DST switch; under winter UTC+12 this would still be Sunday 24:00
  // edge). Intl handles the offset change for us.
  const now = new Date(Date.UTC(2026, 8, 27, 11, 30, 0));
  assert.equal(cov.currentCheckpointKey(now, 'Pacific/Auckland'), '2026-09-28');
});

test('checkpoint math: previous checkpoint alternates Mon↔Thu', () => {
  assert.equal(cov.previousCheckpointKey('2026-08-10'), '2026-08-06'); // Mon → prev Thu
  assert.equal(cov.previousCheckpointKey('2026-08-13'), '2026-08-10'); // Thu → this Mon
  assert.equal(cov.previousSameWeekdayKey('2026-08-10'), '2026-08-03');
});

test('checkpoint math: checkpointOnOrBefore finds the latest Mon/Thu', () => {
  assert.equal(cov.checkpointOnOrBefore('2026-08-12'), '2026-08-10'); // Wed → Mon
  assert.equal(cov.checkpointOnOrBefore('2026-08-13'), '2026-08-13'); // Thu → itself
  assert.equal(cov.checkpointOnOrBefore('2026-08-16'), '2026-08-13'); // Sun → Thu
});

// ── Coverage rules ──────────────────────────────────────────────────────────

test('coverage: previous Thursday copied → Monday covers Thu→Mon', () => {
  const c = cov.effectiveCoverage('2026-08-10', true, null);
  assert.deepEqual(c, { start: '2026-08-06', end: '2026-08-10' });
});

test('coverage: previous Thursday NOT copied → Monday covers Mon→Mon', () => {
  const c = cov.effectiveCoverage('2026-08-10', false, null);
  assert.deepEqual(c, { start: '2026-08-03', end: '2026-08-10' });
});

test('coverage: Monday copied → Thursday covers Mon→Thu', () => {
  const c = cov.effectiveCoverage('2026-08-13', true, null);
  assert.deepEqual(c, { start: '2026-08-10', end: '2026-08-13' });
});

test('coverage: Monday NOT copied → Thursday covers Thu→Thu', () => {
  const c = cov.effectiveCoverage('2026-08-13', false, null);
  assert.deepEqual(c, { start: '2026-08-06', end: '2026-08-13' });
});

test('coverage: prior copy-state change recalculates the current draft', () => {
  // Thursday morning: Monday not copied → Thu→Thu
  let c = cov.effectiveCoverage('2026-08-13', false, null);
  assert.equal(c.start, '2026-08-06');
  // Coach then copies Monday's outstanding draft → Thursday recalculates
  c = cov.effectiveCoverage('2026-08-13', true, null);
  assert.equal(c.start, '2026-08-10');
});

test('coverage: clamp prevents overlap with an already-finalised window', () => {
  // Previous Thursday not copied would give Mon 3rd start, but a finalised
  // checkpoint already covered up to Thu 6th → start clamps to Thu 6th.
  const c = cov.effectiveCoverage('2026-08-10', false, '2026-08-06');
  assert.deepEqual(c, { start: '2026-08-06', end: '2026-08-10' });
});

test('coverage: clamp never moves start past the checkpoint itself', () => {
  const c = cov.effectiveCoverage('2026-08-10', false, '2026-08-12');
  assert.deepEqual(c, { start: '2026-08-10', end: '2026-08-10' });
});

// ── State machine guards ────────────────────────────────────────────────────

test('state: old draft can be copied while newer checkpoint is not finalised', () => {
  const reports = {
    '2026-08-10': { status: 'draft' },
    '2026-08-13': { status: 'draft' },
  };
  assert.equal(cov.canCopy('2026-08-10', reports), true);
});

test('state: old draft cannot be copied after newer checkpoint finalised', () => {
  const reports = {
    '2026-08-10': { status: 'draft' },
    '2026-08-13': { status: 'copied' },
  };
  assert.equal(cov.canCopy('2026-08-10', reports), false);
});

test('state: undo allowed only while nothing newer is finalised', () => {
  assert.equal(cov.canUndo('2026-08-10', {
    '2026-08-10': { status: 'copied' },
    '2026-08-13': { status: 'draft' },
  }), true);
  assert.equal(cov.canUndo('2026-08-10', {
    '2026-08-10': { status: 'copied' },
    '2026-08-13': { status: 'skipped' },
  }), false);
});

test('state: drafts older than the previous checkpoint expire', () => {
  const reports = {
    '2026-08-03': { status: 'draft' },   // older than prev → expire
    '2026-08-06': { status: 'draft' },   // prev itself → keep (still copyable)
    '2026-08-10': { status: 'draft' },
  };
  assert.deepEqual(cov.keysToExpire('2026-08-10', reports), ['2026-08-03']);
});

// ── Spec walk-through (week-by-week example from the brief) ────────────────

test('scenario: alternating copy behaviour matches the spec examples', () => {
  // Week 1 Monday (Aug 3) sent → Week 1 Thursday (Aug 6) = Mon→Thu
  assert.deepEqual(cov.effectiveCoverage('2026-08-06', true, null),
    { start: '2026-08-03', end: '2026-08-06' });

  // Week 1 Thursday not sent → Week 2 Monday (Aug 10) = Mon→Mon
  assert.deepEqual(cov.effectiveCoverage('2026-08-10', false, '2026-08-03'),
    { start: '2026-08-03', end: '2026-08-10' });

  // Week 2 Monday sent → Week 2 Thursday (Aug 13) = Mon→Thu
  assert.deepEqual(cov.effectiveCoverage('2026-08-13', true, '2026-08-10'),
    { start: '2026-08-10', end: '2026-08-13' });

  // Week 2 Thursday sent → Week 3 Monday (Aug 17) = Thu→Mon
  assert.deepEqual(cov.effectiveCoverage('2026-08-17', true, '2026-08-13'),
    { start: '2026-08-13', end: '2026-08-17' });

  // Week 3 Monday not sent → Week 3 Thursday (Aug 20) = Thu→Thu
  assert.deepEqual(cov.effectiveCoverage('2026-08-20', false, '2026-08-13'),
    { start: '2026-08-13', end: '2026-08-20' });
});

// ── Training week resolution ────────────────────────────────────────────────

test('training week: block-anchored 7-day slices', () => {
  // Block starts Wednesday Aug 5.
  const w = cov.trainingWeekOf('2026-08-05', '2026-08-13');
  assert.deepEqual(w, { weekIndex: 1, weekStart: '2026-08-12', weekEnd: '2026-08-19' });
  assert.equal(cov.trainingWeekOf('2026-08-05', '2026-08-04'), null);
});
