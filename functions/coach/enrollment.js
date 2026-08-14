// Enrollment / maintenance decision logic for coach analytics. Pure module.
//
// The athlete-level analytics state doc (coachAnalytics/{athleteUid}) carries:
//   enabledBy:       { [coachUid]: true }   which coaches want reporting
//   bootstrapStatus: 'running' | 'complete' | 'error'
//   dirtyDates:      [dateKey]  workout days written while a bootstrap runs
//
// These pure functions define every decision the Firebase layer makes so the
// concurrency/enrollment semantics are unit-testable without an emulator.

'use strict';

/**
 * What the workout-write trigger should do for a given analytics state.
 *   'skip'  – nobody has reporting enabled → no maintenance work at all
 *   'defer' – a bootstrap is running → record the dateKey in dirtyDates and
 *             let the bootstrap's reconciliation loop process it
 *   'apply' – maintain incrementally
 * The caller evaluates this INSIDE a transaction on the state doc, so the
 * decision is atomic with respect to the bootstrap's completion transaction.
 */
function workoutTriggerDecision(stateData) {
  if (!stateData) return 'skip';
  const enabledBy = stateData.enabledBy || {};
  if (Object.keys(enabledBy).length === 0) return 'skip';
  if (stateData.bootstrapStatus === 'running') return 'defer';
  return 'apply';
}

/**
 * Settings-doc transition → enrollment action.
 *   'register'   – reporting is enabled (idempotent re-register is fine)
 *   'deregister' – reporting was enabled and no longer is (incl. doc delete)
 *   'none'       – no enrollment-relevant change
 */
function settingsTransition(before, after) {
  const wasEnabled = !!(before && before.reportingEnabled);
  const isEnabled = !!(after && after.reportingEnabled);
  if (isEnabled) return 'register';
  if (wasEnabled) return 'deregister';
  return 'none';
}

/**
 * Whether (re-)registering must run the bounded per-athlete bootstrap.
 *
 * @param stateData        current analytics state (or null)
 * @param formulaVersion   the engine's current E1RM formula version
 * @param maintenanceWasOff true when enabledBy was empty before this
 *        registration: while nobody is enabled the workout trigger skips all
 *        maintenance, so any gap must be closed by a fresh bootstrap even if
 *        the previous one had completed.
 */
function needsBootstrap(stateData, formulaVersion, maintenanceWasOff) {
  if (maintenanceWasOff) return true;
  if (!stateData) return true;
  if (stateData.bootstrapStatus !== 'complete') return true;
  if (stateData.e1rmFormulaVersion !== formulaVersion) return true;
  return false;
}

/**
 * A 'running' bootstrap only blocks a new one while it is plausibly still
 * alive. A crashed bootstrap (stale bootstrapAt) must never act as a
 * permanent lock.
 */
const BOOTSTRAP_FRESH_MS = 15 * 60 * 1000;

function bootstrapIsFreshlyRunning(stateData, nowMs) {
  if (!stateData || stateData.bootstrapStatus !== 'running') return false;
  const at = stateData.bootstrapAtMs;
  if (typeof at !== 'number') return false;
  return nowMs - at < BOOTSTRAP_FRESH_MS;
}

/** enabledBy after removing one coach; used to decide CASE 1 vs CASE 2. */
function remainingEnabledBy(enabledBy, removedCoachUid) {
  const out = { ...(enabledBy || {}) };
  delete out[removedCoachUid];
  return out;
}

module.exports = {
  workoutTriggerDecision,
  settingsTransition,
  needsBootstrap,
  bootstrapIsFreshlyRunning,
  remainingEnabledBy,
  BOOTSTRAP_FRESH_MS,
};
