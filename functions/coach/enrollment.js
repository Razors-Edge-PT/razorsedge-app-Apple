// Enrollment / maintenance / bootstrap-ownership decision logic for coach
// analytics. Pure module.
//
// The athlete-level analytics state doc (coachAnalytics/{athleteUid}) carries:
//   enabledBy:        { [coachUid]: true }   which coaches want reporting
//   bootstrapStatus:  'running' | 'complete' | 'error'
//   bootstrapRunId:   unique id of the run that owns the current bootstrap
//   bootstrapAtMs:    claim time (freshness / crashed-owner takeover)
//   dirtyDates:       [dateKey]  workout days written while a bootstrap runs
//   analyticsVersion / e1rmFormulaVersion: schema + formula generations
//
// Every decision the Firebase layer makes is defined here so the
// concurrency/enrollment semantics are unit-testable without an emulator.

'use strict';

/**
 * What the workout-write trigger should do for a given analytics state.
 *   'skip'  – nobody has reporting enabled → no maintenance work at all
 *   'defer' – a bootstrap is running → record the dateKey in dirtyDates and
 *             let the owning run's reconciliation loop process it
 *   'apply' – maintain incrementally
 * The caller evaluates this INSIDE a transaction on the state doc, so the
 * decision is atomic with respect to the bootstrap's claim/completion
 * transactions.
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
 * Whether analytics are fully ready to serve reports: bootstrap complete on
 * the current storage schema and E1RM formula generation.
 */
function analyticsReady(stateData, { formulaVersion, analyticsVersion }) {
  if (!stateData) return false;
  if (stateData.bootstrapStatus !== 'complete') return false;
  if (stateData.e1rmFormulaVersion !== formulaVersion) return false;
  if (stateData.analyticsVersion !== analyticsVersion) return false;
  return true;
}

/**
 * Whether (re-)registering must run the bounded per-athlete bootstrap.
 *
 * @param maintenanceWasOff true when enabledBy was empty before this
 *        registration: while nobody is enabled the workout trigger skips all
 *        maintenance, so any gap must be closed by a fresh bootstrap even if
 *        the previous one had completed.
 */
function needsBootstrap(stateData, versions, maintenanceWasOff) {
  if (maintenanceWasOff) return true;
  return !analyticsReady(stateData, versions);
}

/**
 * A 'running' bootstrap only blocks a new claim while it is plausibly still
 * alive. A crashed owner (stale bootstrapAtMs) never acts as a permanent
 * lock — a new run may take over its runId.
 */
const BOOTSTRAP_FRESH_MS = 15 * 60 * 1000;

function bootstrapIsFreshlyRunning(stateData, nowMs) {
  if (!stateData || stateData.bootstrapStatus !== 'running') return false;
  const at = stateData.bootstrapAtMs;
  if (typeof at !== 'number') return false;
  return nowMs - at < BOOTSTRAP_FRESH_MS;
}

/**
 * Atomic claim decision, evaluated INSIDE a transaction on the state doc.
 *   'skip-fresh' – another live run owns the bootstrap
 *   'skip-ready' – analytics already ready and no forced rebuild required
 *   'claim'      – caller should claim ownership with a new runId
 */
function claimDecision(stateData, nowMs, versions, maintenanceWasOff) {
  if (bootstrapIsFreshlyRunning(stateData, nowMs)) return 'skip-fresh';
  if (!needsBootstrap(stateData, versions, maintenanceWasOff)) return 'skip-ready';
  return 'claim';
}

/** Does runId still own the bootstrap recorded in state? Superseded runs
 *  must never drain dirty dates, flip status, or write errors. */
function ownsRun(stateData, runId) {
  return !!(stateData && stateData.bootstrapRunId === runId
    && stateData.bootstrapStatus === 'running');
}

/**
 * Rebaseline detection at claim time: a formula-version change re-baselines
 * E1RM praise (see index.js e1rmRebaselinedAtKey). Schema-only or first-ever
 * bootstraps do not.
 */
function isFormulaRebaseline(stateData, formulaVersion) {
  return !!(stateData
    && typeof stateData.e1rmFormulaVersion === 'number'
    && stateData.e1rmFormulaVersion !== formulaVersion);
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
  analyticsReady,
  needsBootstrap,
  bootstrapIsFreshlyRunning,
  claimDecision,
  ownsRun,
  isFormulaRebaseline,
  remainingEnabledBy,
  BOOTSTRAP_FRESH_MS,
};
