'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const en = require('../coach/enrollment');
const { E1RM_FORMULA_VERSION } = require('../coach/e1rm');

const VERSIONS = { formulaVersion: E1RM_FORMULA_VERSION, analyticsVersion: 2 };
const READY = {
  bootstrapStatus: 'complete',
  e1rmFormulaVersion: E1RM_FORMULA_VERSION,
  analyticsVersion: 2,
};

// ── Workout-trigger decisions ───────────────────────────────────────────────

test('trigger: no state or nobody enabled → skip (single-read exit)', () => {
  assert.equal(en.workoutTriggerDecision(null), 'skip');
  assert.equal(en.workoutTriggerDecision({ enabledBy: {} }), 'skip');
});

test('trigger: bootstrap running → defer into dirtyDates; settled → apply', () => {
  assert.equal(en.workoutTriggerDecision({
    enabledBy: { coachA: true }, bootstrapStatus: 'running',
  }), 'defer');
  assert.equal(en.workoutTriggerDecision({
    enabledBy: { coachA: true }, ...READY,
  }), 'apply');
});

// ── Settings transitions (CASE 1–4 semantics) ──────────────────────────────

test('CASE 1: single coach disables → deregister; maintenance then stops', () => {
  assert.equal(en.settingsTransition(
    { reportingEnabled: true }, { reportingEnabled: false }), 'deregister');
  const remaining = en.remainingEnabledBy({ coachA: true }, 'coachA');
  assert.deepEqual(remaining, {});
  assert.equal(en.workoutTriggerDecision({ enabledBy: remaining, ...READY }), 'skip');
});

test('CASE 2: two coaches, one disables → analytics stay maintained for the other', () => {
  const remaining = en.remainingEnabledBy({ coachA: true, coachB: true }, 'coachA');
  assert.deepEqual(remaining, { coachB: true });
  assert.equal(en.workoutTriggerDecision({ enabledBy: remaining, ...READY }), 'apply');
});

test('CASE 3: revocation auto-disable write is a deregister transition', () => {
  assert.equal(en.settingsTransition(
    { reportingEnabled: true },
    { reportingEnabled: false, disabledReason: 'assignment-revoked' },
  ), 'deregister');
});

test('CASE 4: re-enable after a maintenance gap always re-bootstraps', () => {
  assert.equal(en.needsBootstrap(READY, VERSIONS, /*maintenanceWasOff=*/true), true);
  assert.equal(en.needsBootstrap(READY, VERSIONS, /*maintenanceWasOff=*/false), false);
});

test('settings doc delete counts as deregister; irrelevant writes are none', () => {
  assert.equal(en.settingsTransition({ reportingEnabled: true }, null), 'deregister');
  assert.equal(en.settingsTransition({ reportingEnabled: false }, { reportingEnabled: false, goal: 'cut' }), 'none');
  assert.equal(en.settingsTransition(null, { reportingEnabled: true }), 'register');
});

// ── Analytics readiness (report gating, item F) ────────────────────────────

test('readiness: only complete + current formula + current schema is ready', () => {
  assert.equal(en.analyticsReady(READY, VERSIONS), true);
  assert.equal(en.analyticsReady(null, VERSIONS), false);
  assert.equal(en.analyticsReady({ ...READY, bootstrapStatus: 'running' }, VERSIONS), false);
  assert.equal(en.analyticsReady({ ...READY, bootstrapStatus: 'error' }, VERSIONS), false);
  assert.equal(en.analyticsReady({ ...READY, e1rmFormulaVersion: 0 }, VERSIONS), false);
  assert.equal(en.analyticsReady({ ...READY, analyticsVersion: 1 }, VERSIONS), false);
});

// ── Atomic claim / run ownership (item E) ──────────────────────────────────

test('claim: ready analytics → skip-ready; unready → claim', () => {
  const now = Date.now();
  assert.equal(en.claimDecision(READY, now, VERSIONS, false), 'skip-ready');
  assert.equal(en.claimDecision(null, now, VERSIONS, false), 'claim');
  assert.equal(en.claimDecision({ bootstrapStatus: 'error' }, now, VERSIONS, false), 'claim');
  assert.equal(en.claimDecision(READY, now, VERSIONS, true), 'claim'); // gap closure
});

test('claim: a FRESH running run blocks a second claim; a stale one does not', () => {
  const now = Date.now();
  const fresh = { bootstrapStatus: 'running', bootstrapAtMs: now - 60 * 1000 };
  const stale = { bootstrapStatus: 'running', bootstrapAtMs: now - en.BOOTSTRAP_FRESH_MS - 1 };
  assert.equal(en.claimDecision(fresh, now, VERSIONS, true), 'skip-fresh');
  assert.equal(en.claimDecision(stale, now, VERSIONS, true), 'claim'); // takeover
});

test('ownership: a superseded run no longer owns the state', () => {
  const mine = { bootstrapStatus: 'running', bootstrapRunId: 'run-1' };
  assert.equal(en.ownsRun(mine, 'run-1'), true);
  // A newer claim replaced the runId → the old run must not drain/complete.
  assert.equal(en.ownsRun({ ...mine, bootstrapRunId: 'run-2' }, 'run-1'), false);
  // Completion by the owner ends ownership for everyone.
  assert.equal(en.ownsRun({ bootstrapStatus: 'complete', bootstrapRunId: 'run-2' }, 'run-2'), false);
  assert.equal(en.ownsRun(null, 'run-1'), false);
});

test('two simultaneous enables: exactly one claim wins (transactional serialisation)', () => {
  // The claim decision runs inside a transaction on the state doc. Simulate
  // the serialised order the transaction guarantees: first claim sees no
  // fresh run → 'claim'; the second re-reads the claimed state → 'skip-fresh'.
  const now = Date.now();
  const before = null;
  assert.equal(en.claimDecision(before, now, VERSIONS, true), 'claim');
  const afterFirstClaim = { bootstrapStatus: 'running', bootstrapRunId: 'run-1', bootstrapAtMs: now };
  assert.equal(en.claimDecision(afterFirstClaim, now, VERSIONS, true), 'skip-fresh');
});

// ── Formula rebaseline detection (item M) ──────────────────────────────────

test('rebaseline: only an actual formula-version change counts', () => {
  assert.equal(en.isFormulaRebaseline({ e1rmFormulaVersion: E1RM_FORMULA_VERSION - 1 }, E1RM_FORMULA_VERSION), true);
  assert.equal(en.isFormulaRebaseline({ e1rmFormulaVersion: E1RM_FORMULA_VERSION }, E1RM_FORMULA_VERSION), false);
  assert.equal(en.isFormulaRebaseline(null, E1RM_FORMULA_VERSION), false);      // first-ever bootstrap
  assert.equal(en.isFormulaRebaseline({}, E1RM_FORMULA_VERSION), false);        // schema-only rebuild
});
