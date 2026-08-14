// Atomic copy / undo / skip state-machine transactions.
//
// Every read that can affect a decision — current report status, previous
// and newer checkpoint statuses, lastFinalizedCoverageEnd, praise and
// milestone bookkeeping, goal phase — happens INSIDE the transaction, so
// concurrent Copy/Undo/Skip calls (same report or neighbouring checkpoints)
// serialise on the documents they read and converge:
//   – simultaneous Copy on the same report: one commits, the other observes
//     'copied' and idempotently returns the identical frozen text
//   – Copy vs Skip on the same report: only one wins (status check in-txn)
//   – Copy on an older draft vs Copy on a newer draft: the newer-checkpoint
//     status reads make them conflict; the loser retries and re-evaluates
//     canCopy / the coverage clamp, so overlapping coverage is impossible
//   – Undo restores only bookkeeping this report actually created (entries
//     are checked to point at this reportId before removal)
//
// This module takes a Firestore instance so the exact same code is exercised
// by the emulator integration tests. It throws TxnError (mapped to
// HttpsError by the callable layer) instead of importing firebase-functions.

'use strict';

const cov = require('./coverage');
const bwx = require('./bodyweight');
const { buildDraftText, computePraisedWeekKey } = require('./draft');

class TxnError extends Error {
  constructor(codeName, message) {
    super(message);
    this.codeName = codeName; // 'not-found' | 'failed-precondition' | 'aborted'
  }
}

function refs(db, coachUid, athleteUid) {
  const coach = db.collection('coachCheckIns').doc(coachUid);
  return {
    settings: coach.collection('athletes').doc(athleteUid),
    report: (key) => coach.collection('reports').doc(`${athleteUid}_${key}`),
  };
}

function nextCheckpointKey(checkpointKey) {
  const wd = cov.weekdayOfKey(checkpointKey);
  if (wd === 'Mon') return cov.addDaysKey(checkpointKey, 3);
  if (wd === 'Thu') return cov.addDaysKey(checkpointKey, 4);
  throw new TxnError('failed-precondition', `Not a checkpoint key: ${checkpointKey}`);
}

/** Checkpoint keys newer than checkpointKey, up to coach-local today. Drafts
 *  older than the previous checkpoint expire, so this list stays tiny. */
function newerCheckpointKeys(checkpointKey, todayKey, max = 8) {
  const keys = [];
  let k = checkpointKey;
  for (let i = 0; i < max; i++) {
    k = nextCheckpointKey(k);
    if (k > todayKey) break;
    keys.push(k);
  }
  return keys;
}

/**
 * Copy: freeze coverage + compose the authoritative final text.
 *
 * @param liveBodyweight  pre-fetched live rolling/staleness numbers (weights
 *        are athlete data, not state-machine state; the milestone decision —
 *        which IS bookkeeping-dependent — is recomputed in-txn from the
 *        transactional praise state).
 * @returns { text, coverageStart, coverageEnd, alreadyCopied? }
 */
async function copyTransaction(db, {
  coachUid, athleteUid, checkpointKey, todayKey, liveBodyweight,
}) {
  const r = refs(db, coachUid, athleteUid);
  const newerKeys = newerCheckpointKeys(checkpointKey, todayKey);

  return db.runTransaction(async (tx) => {
    const reportSnap = await tx.get(r.report(checkpointKey));
    if (!reportSnap.exists) throw new TxnError('not-found', 'Report not found.');
    const report = reportSnap.data();

    if (report.status === 'copied') {
      return {
        text: report.finalText || '',
        coverageStart: report.coverageStart,
        coverageEnd: report.coverageEnd,
        alreadyCopied: true,
      };
    }
    if (report.status !== 'draft') {
      throw new TxnError('failed-precondition', `Check-in is ${report.status}.`);
    }

    const newerStatuses = {};
    for (const k of newerKeys) {
      const s = await tx.get(r.report(k));
      if (s.exists) newerStatuses[k] = s.data();
    }
    if (!cov.canCopy(checkpointKey, newerStatuses)) {
      throw new TxnError('failed-precondition', 'A newer check-in was already finalised.');
    }

    const prevSnap = await tx.get(r.report(report.prevCheckpointKey));
    const prevCopied = prevSnap.exists && prevSnap.data().status === 'copied';

    const settingsSnap = await tx.get(r.settings);
    const settings = settingsSnap.exists ? settingsSnap.data() : {};

    const coverage = cov.effectiveCoverage(
      checkpointKey, prevCopied, settings.lastFinalizedCoverageEnd || null);

    // Milestone decision from transactional praise/goal-phase state.
    const goal = (report.bodyweight && report.bodyweight.goal) || 'maintain';
    const awarded = bwx.awardedForPhase(settings.praisedMilestones, settings.goalSetAt);
    const newMilestoneId = bwx.detectMilestone(
      goal, liveBodyweight.previousAvg, liveBodyweight.currentAvg, awarded);
    const finalBodyweight = { ...liveBodyweight, goal, newMilestoneId: newMilestoneId || null };

    const text = buildDraftText({
      events: report.events || [],
      completion: report.completion || null,
      settings,
      identity: { gender: report.gender, firstName: report.firstName },
      bodyweight: finalBodyweight,
      coverageStart: coverage.start,
      coverageEnd: coverage.end,
      variantSeed: report.variantSeed,
      e1rmPraiseFloorKey: report.e1rmPraiseFloorKey || null,
    });

    const praisedWeekKey = computePraisedWeekKey(report, settings, coverage);
    const milestonePraise = newMilestoneId
      ? bwx.milestonePraiseKey(newMilestoneId, settings.goalSetAt)
      : null;

    // Bounded praise maps: prune dead entries, then add this copy's records.
    const praisedWeeks = bwx.prunePraisedWeeks(settings.praisedWeeks, todayKey);
    if (praisedWeekKey) praisedWeeks[praisedWeekKey] = reportSnap.id;
    const praisedMilestones = bwx.prunePraisedMilestones(settings.praisedMilestones, settings.goalSetAt);
    if (milestonePraise) {
      praisedMilestones[milestonePraise] = { reportId: reportSnap.id, dateKey: todayKey };
    }

    tx.update(reportSnap.ref, {
      status: 'copied',
      copiedAtMs: Date.now(),
      coverageStart: coverage.start,
      coverageEnd: coverage.end,
      finalText: text,
      liveBodyweight: finalBodyweight,
      praisedWeekKey: praisedWeekKey || null,
      milestoneAwarded: milestonePraise || null,
      prevLastFinalizedCoverageEnd: settings.lastFinalizedCoverageEnd || null,
    });
    tx.set(r.settings, {
      lastFinalizedCoverageEnd: coverage.end,
      praisedWeeks,
      praisedMilestones,
    }, { merge: true });

    return { text, coverageStart: coverage.start, coverageEnd: coverage.end };
  });
}

/** Undo / Mark-Not-Sent. Reverts only what this report's copy created. */
async function undoTransaction(db, { coachUid, athleteUid, checkpointKey, todayKey }) {
  const r = refs(db, coachUid, athleteUid);
  const newerKeys = newerCheckpointKeys(checkpointKey, todayKey);

  return db.runTransaction(async (tx) => {
    const reportSnap = await tx.get(r.report(checkpointKey));
    if (!reportSnap.exists) throw new TxnError('not-found', 'Report not found.');
    const report = reportSnap.data();
    if (report.status !== 'copied') {
      throw new TxnError('failed-precondition', 'Only a copied check-in can be undone.');
    }

    const newerStatuses = {};
    for (const k of newerKeys) {
      const s = await tx.get(r.report(k));
      if (s.exists) newerStatuses[k] = s.data();
    }
    if (!cov.canUndo(checkpointKey, newerStatuses)) {
      throw new TxnError('failed-precondition', 'A newer check-in was finalised; undo is no longer safe.');
    }

    const settingsSnap = await tx.get(r.settings);
    const settings = settingsSnap.exists ? settingsSnap.data() : {};

    const settingsUpdate = {};
    // Restore the coverage watermark only if it is still the one we set.
    if ((settings.lastFinalizedCoverageEnd || null) === (report.coverageEnd || null)) {
      settingsUpdate.lastFinalizedCoverageEnd = report.prevLastFinalizedCoverageEnd || null;
    }
    // Remove praise entries only when they were created by THIS report.
    const praisedWeeks = { ...(settings.praisedWeeks || {}) };
    if (report.praisedWeekKey && praisedWeeks[report.praisedWeekKey] === reportSnap.id) {
      delete praisedWeeks[report.praisedWeekKey];
      settingsUpdate.praisedWeeks = praisedWeeks;
    }
    const praisedMilestones = { ...(settings.praisedMilestones || {}) };
    const m = report.milestoneAwarded;
    if (m && praisedMilestones[m] && praisedMilestones[m].reportId === reportSnap.id) {
      delete praisedMilestones[m];
      settingsUpdate.praisedMilestones = praisedMilestones;
    }

    tx.update(reportSnap.ref, {
      status: 'draft',
      copiedAtMs: null,
      coverageStart: null,
      coverageEnd: null,
      finalText: null,
      liveBodyweight: null,
      praisedWeekKey: null,
      milestoneAwarded: null,
      prevLastFinalizedCoverageEnd: null,
    });
    if (Object.keys(settingsUpdate).length > 0) {
      tx.set(r.settings, settingsUpdate, { merge: true });
    }
    return { ok: true };
  });
}

/** Skip: deliberately closes an unused draft. Counts as NOT copied for the
 *  next window, but (as a finalised state) blocks late copies of itself. */
async function skipTransaction(db, { coachUid, athleteUid, checkpointKey }) {
  const r = refs(db, coachUid, athleteUid);
  return db.runTransaction(async (tx) => {
    const reportSnap = await tx.get(r.report(checkpointKey));
    if (!reportSnap.exists) throw new TxnError('not-found', 'Report not found.');
    if (reportSnap.data().status !== 'draft') {
      throw new TxnError('failed-precondition', 'Only a draft can be skipped.');
    }
    tx.update(reportSnap.ref, { status: 'skipped', skippedAtMs: Date.now() });
    return { ok: true };
  });
}

module.exports = {
  TxnError,
  copyTransaction,
  undoTransaction,
  skipTransaction,
  newerCheckpointKeys,
};
