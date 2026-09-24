// Daily leaderboard reconciliation — the pure control loop. Firestore access is
// injected (see firestore_store.js), so the bounds and the idempotence are
// unit-tested without an emulator.
//
// One run:
//   1. closes every open MONTH period older than the current one. Closing only
//      stamps the period document; its entries are kept as the historical
//      snapshot. The visible month never depends on this having run: clients
//      select the period by its key, so a late scheduler changes nothing.
//   2. enqueues athletes whose visible entries (current month, all time) were
//      written under another formula version — bounded by staleScanLimit.
//   3. works the queue in pages, oldest first, up to maxUsers items: each item
//      is recomputed from its sources (idempotent), then removed; a failure
//      increments its attempt count and leaves it for the next run. Items that
//      exhausted maxAttempts are skipped (and counted) so they cannot starve
//      the rest.
// The queue itself is the checkpoint, so an interrupted run simply resumes.

'use strict';

const { isMonthPeriod } = require('./reducer');

const DEFAULT_LIMITS = {
  maxUsers: 200,
  pageSize: 50,
  maxAttempts: 5,
  staleScanLimit: 100,
};

/**
 * deps:
 *   currentPeriodKey()                 → 'YYYY-MM'
 *   listOpenPeriods()                  → [periodKey]
 *   closePeriod(periodKey)
 *   listStaleUids(limit)               → [uid]
 *   enqueue(uid, request, reason)
 *   listQueue(pageSize, afterItem)     → [{ uid, attempts, ... }] oldest first
 *   processItem(item)                  throws on failure
 *   markDone(item)
 *   markFailed(item, error)
 */
async function runReconciliation(deps, limits) {
  const L = Object.assign({}, DEFAULT_LIMITS, limits || {});
  const counts = {
    periodsClosed: 0,
    staleEnqueued: 0,
    processed: 0,
    succeeded: 0,
    failed: 0,
    skippedExhausted: 0,
    pages: 0,
  };
  const failures = [];

  const current = deps.currentPeriodKey();
  for (const p of await deps.listOpenPeriods()) {
    if (isMonthPeriod(p) && p < current) {
      await deps.closePeriod(p);
      counts.periodsClosed += 1;
    }
  }

  const stale = await deps.listStaleUids(L.staleScanLimit);
  for (const uid of stale) {
    await deps.enqueue(uid, { full: true }, 'stale-formula');
    counts.staleEnqueued += 1;
  }

  let after = null;
  let seen = 0;
  while (seen < L.maxUsers) {
    const page = await deps.listQueue(L.pageSize, after);
    counts.pages += 1;
    if (!page || page.length === 0) break;
    for (const item of page) {
      if (seen >= L.maxUsers) break;
      seen += 1;
      after = item;
      if ((item.attempts || 0) >= L.maxAttempts) {
        counts.skippedExhausted += 1;
        continue;
      }
      counts.processed += 1;
      try {
        await deps.processItem(item);
        await deps.markDone(item);
        counts.succeeded += 1;
      } catch (err) {
        counts.failed += 1;
        if (failures.length < 20) failures.push({ uid: item.uid, error: String(err && err.message) });
        await deps.markFailed(item, err);
      }
    }
    if (page.length < L.pageSize) break;
  }
  return { counts, failures };
}

/**
 * The request a queue item stands for. `full` wins; otherwise the range (from
 * the earliest queued weigh-in change) and the explicit dates.
 */
function requestsOfItem(item) {
  if (!item || item.full) return [{ full: true }];
  const out = [];
  if (typeof item.sinceDateKey === 'string') out.push({ sinceDateKey: item.sinceDateKey });
  const dates = Array.isArray(item.dates) ? item.dates.filter((d) => typeof d === 'string') : [];
  if (dates.length) out.push({ dateKeys: dates });
  return out.length ? out : [{ full: true }];
}

/**
 * Merges a new request into a queue item (pure). Too many dates collapse into
 * a full rebuild, which is cheaper than tracking them.
 */
function mergeQueueItem(existing, request, reason, maxDates) {
  const cap = maxDates || 60;
  const prev = existing || {};
  const next = {
    full: !!(prev.full || (request && request.full)),
    dates: [...new Set([...(prev.dates || []), ...((request && request.dateKeys) || [])])].sort(),
    reasons: [...new Set([...(prev.reasons || []), reason].filter(Boolean))].slice(-10),
    attempts: 0,
  };
  const sinces = [prev.sinceDateKey, request && request.sinceDateKey].filter((d) => typeof d === 'string');
  if (sinces.length) next.sinceDateKey = sinces.sort()[0];
  if (next.full || next.dates.length > cap) {
    next.full = true;
    next.dates = [];
    delete next.sinceDateKey;
  }
  return next;
}

module.exports = { DEFAULT_LIMITS, runReconciliation, requestsOfItem, mergeQueueItem };
