// Bounded, resumable, idempotent rebuild of one athlete's derived data:
// profileShowcaseV2 (day contributions → snapshot) and then the RE Points
// leaderboard (rePointDays → monthly entries → all time).
//
// Pure: all I/O goes through an injected `io` (see rebuildStep), so the SAME
// state machine runs in the Firestore worker (a function triggered by writes
// to the job document), in the backfill script, and in the unit tests — the
// scoring and folding it calls are the reducers every other path uses.
//
// ── Why a job ───────────────────────────────────────────────────────────────
// No trigger may read or rewrite an athlete's whole history in one
// transaction. Triggers do the bounded part for the date they were fired for,
// and request a job for anything larger. The job advances ONE bounded unit per
// step and records its cursor, so a timeout or crash resumes where it stopped.
//
// ── Job document (profileRebuildJobs/{uid}, server-only) ────────────────────
//   status       queued | running | done | error
//   generation   bumped on every (re)start; a step only commits if the
//                generation AND step number it read are still current, so a
//                duplicate or stale invocation can never commit twice
//   step         bumped by every committed step (drives the self-chaining worker)
//   mode         full (days → …) | fold (fold → …) | leaderboard (lb → …)
//   phase        days | fold | publish | lbDays | lbMonths
//   cursor       phase-local position (a date key or '')
//   touches      bumped by every trigger that changed data while the job runs
//   foldTouches  `touches` when the current fold began — publish only if equal
//   touchedDates dates touched while running (replayed on the leaderboard)
//   entries      the folded exercise entries, published atomically at the end
//   months       leaderboard months still to re-sum
//   attempts / lastError   explicit failure state (status 'error' after
//                MAX_ATTEMPTS consecutive failures; reconciliation re-queues)
//
// ── Phases ──────────────────────────────────────────────────────────────────
//   days      page through the workouts (PAGE_DATES per step, in one small
//             transaction): write each date's V2 day contributions, delete the
//             contributions of dates in the page range that no longer exist
//   fold      one exercise per step: fold its day contributions into entries
//   publish   one transaction: if nothing was touched since the fold began,
//             publish snapshot + state; otherwise fold again (bounded cycles)
//   lbDays    page through the V2 day contributions: write rePointDays and
//             delete stale ones; collect the months they belong to
//   lbMonths  one month per step: re-sum its entry; then the all-time entry,
//             the leaderboard state, and — if anything was touched after the
//             publish — another fold/publish cycle replaying only those dates
//
// Until publish commits, the athlete's previous complete snapshot (or, for a
// first build, the V1 fallback) stays visible; nothing partial is published.

'use strict';

const { RE_SLOT_ORDER, snapshotV2FromEntries, summarizeWorkoutDayV2 } = require('./reducer_v2');
const { entriesFromDays } = require('./reducer_v2');
const { reExerciseBySlot } = require('./re_catalog');
const { scoringSexOf } = require('./re_points');
const { canonicalJson } = require('./store');

const PAGE_DATES = 25;
const LB_PAGE_DOCS = 300;
const MAX_TOUCHED_DATES = 200;
const MAX_CYCLES = 5;
const MAX_ATTEMPTS = 5;

const Status = { QUEUED: 'queued', RUNNING: 'running', DONE: 'done', ERROR: 'error' };
const Phase = {
  DAYS: 'days',
  FOLD: 'fold',
  PUBLISH: 'publish',
  LB_DAYS: 'lbDays',
  LB_MONTHS: 'lbMonths',
};
const MODE_RANK = { leaderboard: 1, fold: 2, full: 3 };

function isActive(job) {
  return !!(job && (job.status === Status.QUEUED || job.status === Status.RUNNING));
}

function startPhase(mode) {
  if (mode === 'leaderboard') return Phase.LB_DAYS;
  if (mode === 'fold') return Phase.FOLD;
  return Phase.DAYS;
}

/** A fresh job for [request], superseding [prev]. */
function newJob(prev, request, nowMs) {
  const mode = MODE_RANK[request && request.mode] ? request.mode : 'full';
  return {
    status: Status.QUEUED,
    generation: ((prev && prev.generation) || 0) + 1,
    step: ((prev && prev.step) || 0) + 1,
    mode,
    phase: startPhase(mode),
    cursor: '',
    foldIndex: 0,
    entries: {},
    latestDateKey: '',
    touches: 0,
    foldTouches: 0,
    lbTouches: 0,
    touchedDates: [],
    touchOverflow: false,
    lbMode: 'full',
    lbDates: [],
    months: [],
    cycles: 0,
    attempts: 0,
    lastError: null,
    reasons: [request && request.reason].filter(Boolean),
    requestedAtMs: nowMs,
    updatedAtMs: nowMs,
  };
}

/**
 * Merges a rebuild request into the current job (pure). An idle job starts a
 * new generation. An active job keeps running unless the request needs MORE
 * (a stronger mode, or a weigh-in rewind the job has already paged past), in
 * which case it restarts as a new generation — never two jobs at once.
 */
function mergeRebuildRequest(prev, request, nowMs) {
  const req = request || {};
  if (!isActive(prev)) return newJob(prev, req, nowMs);
  const job = Object.assign({}, prev);
  job.reasons = [...new Set([...(job.reasons || []), req.reason].filter(Boolean))].slice(-10);
  if ((MODE_RANK[req.mode] || 3) > (MODE_RANK[job.mode] || 3)) return newJob(prev, req, nowMs);
  if (typeof req.sinceDateKey === 'string' && job.mode === 'full') {
    if (job.phase !== Phase.DAYS) return newJob(prev, { mode: 'full', reason: req.reason }, nowMs);
    const cur = typeof job.rewindDateKey === 'string' ? job.rewindDateKey : null;
    job.rewindDateKey = cur === null || req.sinceDateKey < cur ? req.sinceDateKey : cur;
  }
  job.updatedAtMs = nowMs;
  return job;
}

/**
 * Records that a trigger changed data while the job is active (pure).
 * touch: { dateKeys?: string[] } — a workout date; { sinceDateKey } — a
 * weigh-in (merged as a rewind / restart, see mergeRebuildRequest).
 */
function noteTouch(prev, touch, nowMs) {
  if (!isActive(prev)) return prev;
  let job = Object.assign({}, prev);
  if (touch && typeof touch.sinceDateKey === 'string') {
    job = mergeRebuildRequest(job, { mode: 'full', sinceDateKey: touch.sinceDateKey, reason: 'weigh-in' }, nowMs);
  }
  job.touches = (job.touches || 0) + 1;
  const dates = new Set([...(job.touchedDates || []), ...((touch && touch.dateKeys) || [])]);
  if (dates.size > MAX_TOUCHED_DATES) {
    job.touchOverflow = true;
    job.touchedDates = [];
  } else {
    job.touchedDates = [...dates].sort();
  }
  job.updatedAtMs = nowMs;
  return job;
}

function maxKey(a, b) {
  return (a || '') > (b || '') ? a : b;
}

// ── Steps ────────────────────────────────────────────────────────────────────
//
// io:
//   now()                          epoch ms
//   getJob()                       the job (plain read)
//   unit(expect, fn)               runs fn({ v2, lb, job }) atomically when the
//                                  job's generation and step still equal
//                                  `expect`; fn returns a patch for the job
//                                  (or null to commit nothing)
//   v2 / lb                        plain stores for reads outside the unit
//   leaderboard                    { scoreDay, periodKeyOf, recomputeMonth,
//                                    recomputeDates, refreshAllTime,
//                                    LEADERBOARD_FORMULA_VERSION }

async function stepDays(io, job) {
  let from = job.cursor || '';
  if (typeof job.rewindDateKey === 'string' && job.rewindDateKey < from) from = job.rewindDateKey;
  const sex = scoringSexOf(await io.v2.getScoringSex());
  // Page boundaries and weigh-ins are read first (outside the unit).
  const preview = await io.v2.listWorkoutsFrom(from, PAGE_DATES + 1);
  const dates = preview.slice(0, PAGE_DATES).map(([d]) => d);
  const bwByDate = dates.length ? await io.v2.bodyweightsForDates(dates) : new Map();
  return io.unit(job, async ({ v2 }) => {
    // Re-read inside the unit so a concurrent workout write is seen.
    const page = await v2.listWorkoutsFrom(from, PAGE_DATES + 1);
    const nextFrom = page.length > PAGE_DATES ? page[PAGE_DATES][0] : null;
    const rows = page.slice(0, PAGE_DATES);
    const existing = await v2.listDaysInRange(from, nextFrom);
    const produced = new Set();
    let latest = job.latestDateKey || '';
    for (const [dateKey, data] of rows) {
      const bw = bwByDate.has(dateKey)
        ? bwByDate.get(dateKey)
        : (await io.v2.bodyweightsForDates([dateKey])).get(dateKey) || null;
      const next = summarizeWorkoutDayV2(dateKey, data, { bodyweight: bw, sex });
      for (const slot of Object.keys(next)) {
        produced.add(`${slot}__${dateKey}`);
        const prev = existing.find((d) => d.slot === slot && d.dateKey === dateKey);
        if (!prev || canonicalJson(prev) !== canonicalJson(next[slot])) {
          await v2.setDay(slot, dateKey, next[slot]);
        }
      }
      if (Object.keys(next).length) latest = maxKey(latest, dateKey);
    }
    for (const d of existing) {
      if (!produced.has(`${d.slot}__${d.dateKey}`)) await v2.deleteDay(d.slot, d.dateKey);
    }
    const patch = { cursor: nextFrom || '', latestDateKey: latest, rewindDateKey: null };
    if (nextFrom === null) {
      Object.assign(patch, { phase: Phase.FOLD, foldIndex: 0, entries: {}, foldTouches: job.touches || 0 });
    }
    return patch;
  });
}

async function stepFold(io, job) {
  const sex = scoringSexOf(await io.v2.getScoringSex());
  const slot = RE_SLOT_ORDER[job.foldIndex || 0];
  const days = await io.v2.listDaysForSlot(slot);
  const entry = entriesFromDays(days, sex)[slot] || null;
  return io.unit(job, async () => {
    const entries = Object.assign({}, job.entries || {});
    if (entry) entries[slot] = entry;
    else delete entries[slot];
    const nextIndex = (job.foldIndex || 0) + 1;
    return {
      entries,
      foldIndex: nextIndex,
      phase: nextIndex >= RE_SLOT_ORDER.length ? Phase.PUBLISH : Phase.FOLD,
    };
  });
}

async function stepPublish(io, job) {
  return io.unit(job, async ({ v2, job: fresh }) => {
    if ((fresh.touches || 0) !== (fresh.foldTouches || 0)) {
      // Data changed while folding: fold again (bounded).
      const cycles = (fresh.cycles || 0) + 1;
      if (cycles > MAX_CYCLES) {
        return { status: Status.ERROR, lastError: 'too many concurrent changes during rebuild' };
      }
      return { phase: Phase.FOLD, foldIndex: 0, foldTouches: fresh.touches || 0, cycles };
    }
    const { stateV2 } = require('./store_v2');
    const state = (await v2.getState()) || {};
    const latest = maxKey(fresh.latestDateKey, fresh.mode === 'full' ? '' : state.latestDateKey);
    await v2.setSnapshot(snapshotV2FromEntries(fresh.entries || {}));
    await v2.setState(stateV2(latest));
    const replay = (fresh.cycles || 0) > 0 && !fresh.touchOverflow && fresh.lbMode === 'dates';
    return {
      phase: Phase.LB_DAYS,
      cursor: '',
      months: [],
      lbTouches: fresh.touches || 0,
      lbMode: replay ? 'dates' : 'full',
    };
  });
}

function groupByDate(days) {
  const out = new Map();
  for (const d of days) {
    if (!out.has(d.dateKey)) out.set(d.dateKey, []);
    out.get(d.dateKey).push(d);
  }
  return out;
}

async function stepLbDays(io, job) {
  const L = io.leaderboard;
  if (job.lbMode === 'dates') {
    const dates = [...(job.lbDates || [])];
    return io.unit(job, async ({ lb }) => {
      if (dates.length) await L.recomputeDates(lb, dates);
      return { phase: Phase.LB_MONTHS, months: [], lbDates: [] };
    });
  }
  const from = job.cursor || '';
  const sex = scoringSexOf(await io.v2.getScoringSex());
  let docs = await io.v2.listDaysInRange(from, null, LB_PAGE_DOCS);
  let nextFrom = null;
  if (docs.length >= LB_PAGE_DOCS) {
    // The last date may be cut off mid-way: it starts the next page.
    nextFrom = docs[docs.length - 1].dateKey;
    docs = docs.filter((d) => d.dateKey < nextFrom);
    if (docs.length === 0) {
      // One date filled the whole page (not reachable with 13 exercises).
      docs = await io.v2.listDaysInRange(from, null, LB_PAGE_DOCS * 4);
      nextFrom = null;
    }
  }
  const byDate = groupByDate(docs);
  return io.unit(job, async ({ lb }) => {
    const existing = await lb.listRePointDaysInRange(from, nextFrom);
    const months = new Set(job.months || []);
    const produced = new Set();
    for (const [dateKey, days] of byDate) {
      const doc = L.scoreDay(dateKey, days, null, sex);
      if (!doc) continue;
      produced.add(dateKey);
      months.add(doc.periodKey);
      const prev = existing.find((d) => d.dateKey === dateKey);
      if (!prev || !L.sameDoc(prev, doc)) await lb.setRePointDay(dateKey, doc);
    }
    for (const d of existing) {
      if (produced.has(d.dateKey)) continue;
      await lb.deleteRePointDay(d.dateKey);
      if (d.periodKey) months.add(d.periodKey);
    }
    return {
      cursor: nextFrom || '',
      months: [...months].sort(),
      phase: nextFrom === null ? Phase.LB_MONTHS : Phase.LB_DAYS,
    };
  });
}

async function stepLbMonths(io, job) {
  const L = io.leaderboard;
  const months = [...(job.months || [])];
  if (months.length) {
    const month = months.shift();
    return io.unit(job, async ({ lb }) => {
      await L.recomputeMonth(lb, month);
      return { months };
    });
  }
  return io.unit(job, async ({ lb, job: fresh }) => {
    await L.refreshAllTime(lb);
    if ((fresh.touches || 0) !== (fresh.lbTouches || 0)) {
      const cycles = (fresh.cycles || 0) + 1;
      if (cycles > MAX_CYCLES) {
        return { status: Status.ERROR, lastError: 'too many concurrent changes during rebuild' };
      }
      // Touched after publish: fold/publish again, then replay those dates.
      return {
        phase: Phase.FOLD,
        foldIndex: 0,
        foldTouches: fresh.touches || 0,
        cycles,
        lbMode: fresh.touchOverflow ? 'full' : 'dates',
        lbDates: fresh.touchOverflow ? [] : [...(fresh.touchedDates || [])],
        touchedDates: [],
        touchOverflow: false,
      };
    }
    await lb.setState({ formulaVersion: L.LEADERBOARD_FORMULA_VERSION });
    return { status: Status.DONE, finishedAtMs: io.now(), attempts: 0, lastError: null };
  });
}

/**
 * Runs ONE bounded step of the athlete's active job. Returns
 * { done: boolean, phase, committed }. Never throws for a step failure: the
 * failure is recorded on the job (attempts / lastError / status 'error').
 */
async function rebuildStep(io) {
  const job = await io.getJob();
  if (!isActive(job)) return { done: true, phase: job ? job.status : null, committed: false };
  try {
    let committed;
    switch (job.phase) {
      case Phase.DAYS:
        committed = await stepDays(io, job);
        break;
      case Phase.FOLD:
        committed = await stepFold(io, job);
        break;
      case Phase.PUBLISH:
        committed = await stepPublish(io, job);
        break;
      case Phase.LB_DAYS:
        committed = await stepLbDays(io, job);
        break;
      case Phase.LB_MONTHS:
        committed = await stepLbMonths(io, job);
        break;
      default:
        committed = await io.unit(job, async () => ({ status: Status.ERROR, lastError: `unknown phase ${job.phase}` }));
    }
    const after = await io.getJob();
    return { done: !isActive(after), phase: after && after.phase, committed: !!committed };
  } catch (err) {
    const attempts = (job.attempts || 0) + 1;
    await io.unit(job, async () => ({
      attempts,
      lastError: String((err && err.message) || err).slice(0, 300),
      status: attempts >= MAX_ATTEMPTS ? Status.ERROR : Status.RUNNING,
    })).catch(() => {});
    return { done: attempts >= MAX_ATTEMPTS, phase: job.phase, committed: false, error: err };
  }
}

/** Drives [rebuildStep] until the job is finished (backfill, tests). */
async function runRebuildToCompletion(io, maxSteps) {
  const limit = maxSteps || 10000;
  for (let i = 0; i < limit; i += 1) {
    const r = await rebuildStep(io);
    if (r.done) return { steps: i + 1, job: await io.getJob() };
  }
  return { steps: limit, job: await io.getJob(), exhausted: true };
}

/**
 * A memory `io` over a memoryStoreV2 and a memoryLeaderboardStore (tests,
 * dry run). `beforeUnit` lets a test inject a concurrent change.
 */
function memoryIo(v2, lb, options) {
  const L = require('../leaderboard/store');
  const R = require('../leaderboard/reducer');
  const o = options || {};
  return {
    now: () => Date.now(),
    getJob: () => v2.getRebuildJob(),
    v2: Object.assign(Object.create(v2), {
      async bodyweightsForDates(dates) {
        const { resolveBodyweights } = require('./store');
        return resolveBodyweights(v2, dates);
      },
    }),
    lb,
    leaderboard: {
      scoreDay: R.scoreDay,
      sameDoc: L.sameDoc,
      recomputeMonth: L.recomputeMonth,
      recomputeDates: L.recomputeDates,
      refreshAllTime: L.refreshAllTime,
      LEADERBOARD_FORMULA_VERSION: R.LEADERBOARD_FORMULA_VERSION,
    },
    async unit(expect, fn) {
      if (typeof o.beforeUnit === 'function') await o.beforeUnit();
      const job = await v2.getRebuildJob();
      if (!isActive(job) || job.generation !== expect.generation || job.step !== expect.step) return false;
      const patch = await fn({ v2, lb, job });
      if (!patch) return false;
      await v2.setRebuildJob(Object.assign({}, job, patch, {
        step: job.step + 1,
        status: patch.status || Status.RUNNING,
        updatedAtMs: Date.now(),
      }));
      return true;
    },
  };
}

module.exports = {
  PAGE_DATES,
  LB_PAGE_DOCS,
  MAX_ATTEMPTS,
  MAX_CYCLES,
  MAX_TOUCHED_DATES,
  Status,
  Phase,
  isActive,
  newJob,
  mergeRebuildRequest,
  noteTouch,
  rebuildStep,
  runRebuildToCompletion,
  memoryIo,
  reExerciseBySlot,
};
