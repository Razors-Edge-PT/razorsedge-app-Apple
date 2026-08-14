'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const en = require('../coach/enrollment');
const { E1RM_FORMULA_VERSION } = require('../coach/e1rm');

const V = E1RM_FORMULA_VERSION;

// ── Workout-trigger decisions ───────────────────────────────────────────────

test('trigger: no state or nobody enabled → skip (single-read exit)', () => {
  assert.equal(en.workoutTriggerDecision(null), 'skip');
  assert.equal(en.workoutTriggerDecision({ enabledBy: {} }), 'skip');
  assert.equal(en.workoutTriggerDecision({ enabledBy: {}, bootstrapStatus: 'complete' }), 'skip');
});

test('trigger: bootstrap running → defer into dirtyDates', () => {
  assert.equal(en.workoutTriggerDecision({
    enabledBy: { coachA: true }, bootstrapStatus: 'running',
  }), 'defer');
});

test('trigger: enabled and settled → apply incrementally', () => {
  assert.equal(en.workoutTriggerDecision({
    enabledBy: { coachA: true }, bootstrapStatus: 'complete',
  }), 'apply');
});

// ── Settings transitions (CASE 1–4 semantics) ──────────────────────────────

test('CASE 1: single coach disables → deregister; maintenance then stops', () => {
  assert.equal(en.settingsTransition(
    { reportingEnabled: true }, { reportingEnabled: false }), 'deregister');
  const remaining = en.remainingEnabledBy({ coachA: true }, 'coachA');
  assert.deepEqual(remaining, {});
  // With enabledBy now empty the workout trigger does no analytics work.
  assert.equal(en.workoutTriggerDecision({ enabledBy: remaining, bootstrapStatus: 'complete' }), 'skip');
});

test('CASE 2: two coaches, one disables → analytics stay maintained for the other', () => {
  const remaining = en.remainingEnabledBy({ coachA: true, coachB: true }, 'coachA');
  assert.deepEqual(remaining, { coachB: true });
  assert.equal(en.workoutTriggerDecision({ enabledBy: remaining, bootstrapStatus: 'complete' }), 'apply');
});

test('CASE 3: revocation auto-disable write is a deregister transition', () => {
  // The scheduler writes {reportingEnabled: false, disabledReason:
  // 'assignment-revoked'} when isCoachFor() fails; the settings trigger then
  // deregisters exactly like a manual disable.
  assert.equal(en.settingsTransition(
    { reportingEnabled: true },
    { reportingEnabled: false, disabledReason: 'assignment-revoked' },
  ), 'deregister');
});

test('CASE 4: re-enable after a maintenance gap always re-bootstraps', () => {
  // While enabledBy was empty the trigger skipped all writes, so a
  // registration that flips maintenance back on must bootstrap even when the
  // previous bootstrap had completed on the current formula version.
  const settled = { bootstrapStatus: 'complete', e1rmFormulaVersion: V };
  assert.equal(en.needsBootstrap(settled, V, /*maintenanceWasOff=*/true), true);
  // Second coach enabling while the first kept maintenance alive: no re-run.
  assert.equal(en.needsBootstrap(settled, V, /*maintenanceWasOff=*/false), false);
});

test('settings doc delete counts as deregister; irrelevant writes are none', () => {
  assert.equal(en.settingsTransition({ reportingEnabled: true }, null), 'deregister');
  assert.equal(en.settingsTransition({ reportingEnabled: false }, { reportingEnabled: false, goal: 'cut' }), 'none');
  assert.equal(en.settingsTransition(null, { reportingEnabled: true }), 'register');
  assert.equal(en.settingsTransition({ reportingEnabled: true }, { reportingEnabled: true, goal: 'cut' }), 'register');
});

// ── Bootstrap need / freshness (no permanently-stuck lock) ─────────────────

test('bootstrap needed on missing/error state or formula-version change', () => {
  assert.equal(en.needsBootstrap(null, V, false), true);
  assert.equal(en.needsBootstrap({ bootstrapStatus: 'error' }, V, false), true);
  assert.equal(en.needsBootstrap(
    { bootstrapStatus: 'complete', e1rmFormulaVersion: V - 1 }, V, false), true);
});

test('a running bootstrap blocks re-entry only while fresh', () => {
  const now = Date.now();
  assert.equal(en.bootstrapIsFreshlyRunning(
    { bootstrapStatus: 'running', bootstrapAtMs: now - 60 * 1000 }, now), true);
  // Crashed run: stale timestamp no longer acts as a lock.
  assert.equal(en.bootstrapIsFreshlyRunning(
    { bootstrapStatus: 'running', bootstrapAtMs: now - en.BOOTSTRAP_FRESH_MS - 1 }, now), false);
  // Missing timestamp (legacy/crashed early) never locks.
  assert.equal(en.bootstrapIsFreshlyRunning({ bootstrapStatus: 'running' }, now), false);
  // And needsBootstrap regards 'running' as unfinished:
  assert.equal(en.needsBootstrap({ bootstrapStatus: 'running' }, V, false), true);
});
