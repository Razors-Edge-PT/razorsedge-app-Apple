// Coach bi-weekly check-ins — Firebase-bound layer.
//
// Pure business logic lives in the sibling modules (e1rm, pb_engine,
// coverage, bodyweight, praise, message); this file wires it to Firestore,
// triggers, the scheduler and callables. Style follows the existing
// functions/index.js: CommonJS + firebase-functions v2 APIs.
//
// Firestore schema introduced by this feature
// -------------------------------------------
// coachAnalytics/{athleteUid}                       (server-written only)
//   enabledBy: { [coachUid]: true }
//   analyticsVersion, e1rmFormulaVersion
//   bootstrapStatus: 'running'|'complete'|'error', bootstrapAt, bootstrapError
//   milestones: { [milestoneId]: dateKey }          10 kg milestones awarded
// coachAnalytics/{athleteUid}/exercises/{exerciseId}
//   name, formulaVersion, updatedAt
//   history: { [dateKey]: { name, bestByReps, bestE1rm, bestE1rmSet } }
//   repBest: { [reps]: { weightKg, dateKey } }, e1rmBest
// coachAnalytics/{athleteUid}/events/{eventId}      deterministic ids
//   (see pb_engine.deriveExerciseEvents)
// coachCheckIns/{coachUid}                          coach settings
//   timezone (IANA, default 'Pacific/Auckland'), lastCheckpointKey
// coachCheckIns/{coachUid}/athletes/{athleteUid}    per-athlete coach settings
//   reportingEnabled, goal: 'cut'|'bulk'|'maintain',
//   messageExerciseMode: 'automatic'|'custom', customExerciseIds: [],
//   praisedWeeks: { [weekStartKey]: reportId },     (server-written)
//   lastFinalizedCoverageEnd: dateKey               (server-written)
// coachCheckIns/{coachUid}/reports/{athleteUid_checkpointKey}
//   generated checkpoint report + draft variants + copy workflow state
//   (all mutations via server; clients read only)

'use strict';

const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const { E1RM_FORMULA_VERSION } = require('./e1rm');
const { summarizeWorkoutDay, deriveExerciseEvents } = require('./pb_engine');
const cov = require('./coverage');
const bwx = require('./bodyweight');
const { selectPraise } = require('./praise');
const { composeDraft } = require('./message');

try { admin.initializeApp(); } catch (_) {}
const db = admin.firestore();

const ANALYTICS_VERSION = 1;
const DEFAULT_TZ = 'Pacific/Auckland';
const DATE_KEY_RE = /^\d{4}-\d{2}-\d{2}$/;

// ── Small helpers ───────────────────────────────────────────────────────────

const analyticsRef = (uid) => db.collection('coachAnalytics').doc(uid);
const coachRef = (coachUid) => db.collection('coachCheckIns').doc(coachUid);
const athleteSettingsRef = (coachUid, athleteUid) =>
  coachRef(coachUid).collection('athletes').doc(athleteUid);
const reportRef = (coachUid, athleteUid, checkpointKey) =>
  coachRef(coachUid).collection('reports').doc(`${athleteUid}_${checkpointKey}`);

function todayKeyIn(tz) {
  return cov.localDateKey(new Date(), tz || DEFAULT_TZ);
}

/** Is coachUid an approved/assigned coach for athleteUid? (mirrors rules) */
async function isCoachFor(coachUid, athleteUid) {
  const ca = await db.collection('coachAssignments').doc(coachUid).get();
  if (ca.exists) {
    const athletes = ca.data().athletes || {};
    if (athletes[athleteUid] != null) return true;
  }
  const aa = await db.collection('athleteAssignments').doc(athleteUid).get();
  if (aa.exists) {
    const coaches = aa.data().coaches || {};
    if (coaches[coachUid] != null) return true;
  }
  return false;
}

/** Resolve gender/first-name from users/{uid} (never inferred from a name). */
async function resolveAthleteIdentity(athleteUid) {
  const snap = await db.collection('users').doc(athleteUid).get();
  const data = snap.exists ? snap.data() : {};
  let gender = null;
  const sex = typeof data.sex === 'string' ? data.sex.toUpperCase() : null;
  if (sex === 'M') gender = 'male';
  else if (sex === 'F') gender = 'female';
  if (!gender) {
    const pg = data.profile && typeof data.profile.gender === 'string'
      ? data.profile.gender.toLowerCase() : null;
    if (pg === 'male' || pg === 'female') gender = pg;
  }
  const nameSource = firstNonEmpty([
    data.fullName, data.displayName, data.username,
  ]);
  const firstName = nameSource ? String(nameSource).trim().split(/\s+/)[0] : null;
  return { gender, firstName, displayName: nameSource || athleteUid };
}

function firstNonEmpty(values) {
  for (const v of values) {
    if (typeof v === 'string' && v.trim()) return v.trim();
  }
  return null;
}

/** Weigh-in entries from users/{uid}/weights since a cutoff dateKey.
 *  Weigh-ins are stamped at device-local noon; interpreting the instant in
 *  the coach's time zone recovers the intended calendar day (a plain UTC
 *  slice would land on the previous day under NZDT). */
async function loadWeightEntries(athleteUid, sinceKey, tz) {
  const [y, m, d] = sinceKey.split('-').map(Number);
  const cutoff = admin.firestore.Timestamp.fromDate(new Date(Date.UTC(y, m - 1, d - 1)));
  const snap = await db.collection('users').doc(athleteUid)
    .collection('weights')
    .where('timestamp', '>=', cutoff)
    .get();
  const entries = [];
  for (const doc of snap.docs) {
    const w = doc.data();
    const ts = w.timestamp;
    if (!ts || typeof ts.toDate !== 'function') continue;
    const weight = Number(w.weight);
    if (!Number.isFinite(weight) || weight <= 0) continue;
    entries.push({
      dateKey: cov.localDateKey(ts.toDate(), tz || DEFAULT_TZ),
      weightKg: weight,
      tod: (typeof w.tod === 'string' && w.tod.toLowerCase() === 'pm') ? 'pm' : 'am',
    });
  }
  return entries;
}

/** Latest weigh-in dateKey (any age). One indexed read. */
async function latestWeighInKey(athleteUid, tz) {
  const snap = await db.collection('users').doc(athleteUid)
    .collection('weights')
    .orderBy('timestamp', 'desc')
    .limit(1)
    .get();
  if (snap.empty) return null;
  const ts = snap.docs[0].data().timestamp;
  if (!ts || typeof ts.toDate !== 'function') return null;
  return cov.localDateKey(ts.toDate(), tz || DEFAULT_TZ);
}

// ── Per-exercise analytics maintenance ──────────────────────────────────────

/**
 * Applies one workout day's summaries to the athlete's per-exercise analytics
 * docs and reconciles the derived PB event docs for the touched exercises.
 * Deterministic and idempotent: recomputes each touched exercise's event
 * stream from its compact per-day history, so edits and deletions self-heal.
 */
async function applyWorkoutDay(athleteUid, dateKey, beforeData, afterData) {
  const beforeSummary = summarizeWorkoutDay(beforeData || {});
  const afterSummary = summarizeWorkoutDay(afterData || {});
  const touched = new Set([
    ...Object.keys(beforeSummary),
    ...Object.keys(afterSummary),
  ]);
  if (touched.size === 0) return;

  for (const exerciseId of touched) {
    const exRef = analyticsRef(athleteUid).collection('exercises').doc(exerciseId);
    const exSnap = await exRef.get();
    const history = exSnap.exists ? (exSnap.data().history || {}) : {};

    if (afterSummary[exerciseId]) {
      history[dateKey] = afterSummary[exerciseId];
    } else {
      delete history[dateKey];
    }

    const derived = deriveExerciseEvents(exerciseId, history);

    const batch = db.batch();
    if (Object.keys(history).length === 0) {
      batch.delete(exRef);
    } else {
      batch.set(exRef, {
        name: derived.name,
        history,
        repBest: derived.repBest,
        e1rmBest: derived.e1rmBest,
        formulaVersion: E1RM_FORMULA_VERSION,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // Reconcile event docs for this exercise: delete stale, upsert current.
    const eventsCol = analyticsRef(athleteUid).collection('events');
    const existing = await eventsCol.where('exerciseId', '==', exerciseId).get();
    const wantedIds = new Set(derived.events.map((e) => e.id));
    for (const doc of existing.docs) {
      if (!wantedIds.has(doc.id)) batch.delete(doc.ref);
    }
    for (const ev of derived.events) {
      batch.set(eventsCol.doc(ev.id), ev);
    }
    await batch.commit();
  }
}

/**
 * Trigger: keeps coach analytics in sync with workout writes (create, edit,
 * delete). Exits after one read when the athlete has no reporting enabled.
 * Runs alongside (never replaces) the existing repointsMonthlyAggregator.
 */
const coachAnalyticsOnWorkoutWrite = onDocumentWritten(
  'users/{uid}/workouts/{workoutId}',
  async (event) => {
    const uid = event.params.uid;
    const workoutId = event.params.workoutId;
    if (!DATE_KEY_RE.test(workoutId)) return; // only date-keyed workout docs

    const stateSnap = await analyticsRef(uid).get();
    if (!stateSnap.exists) return;
    const enabledBy = stateSnap.data().enabledBy || {};
    if (Object.keys(enabledBy).length === 0) return;

    try {
      await applyWorkoutDay(
        uid,
        workoutId,
        event.data.before.exists ? event.data.before.data() : null,
        event.data.after.exists ? event.data.after.data() : null,
      );
    } catch (err) {
      logger.error('coachAnalyticsOnWorkoutWrite failed', { uid, workoutId, error: err });
      throw err;
    }
  }
);

// ── Historical bootstrap ────────────────────────────────────────────────────

/**
 * One-time, bounded, idempotent per-athlete backfill. Streams the athlete's
 * workout docs in chronological order (doc ids are YYYY-MM-DD), rebuilds all
 * per-exercise histories and event docs from scratch.
 */
async function bootstrapAthlete(athleteUid) {
  const stateRef = analyticsRef(athleteUid);
  await stateRef.set({
    bootstrapStatus: 'running',
    analyticsVersion: ANALYTICS_VERSION,
    e1rmFormulaVersion: E1RM_FORMULA_VERSION,
    bootstrapAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  try {
    const histories = {}; // exerciseId -> { dateKey: daySummary }
    const PAGE = 300;
    let last = null;
    for (;;) {
      let q = db.collection('users').doc(athleteUid).collection('workouts')
        .orderBy(admin.firestore.FieldPath.documentId())
        .limit(PAGE);
      if (last) q = q.startAfter(last);
      const page = await q.get();
      if (page.empty) break;
      for (const doc of page.docs) {
        if (!DATE_KEY_RE.test(doc.id)) continue;
        const summary = summarizeWorkoutDay(doc.data());
        for (const [exerciseId, day] of Object.entries(summary)) {
          (histories[exerciseId] = histories[exerciseId] || {})[doc.id] = day;
        }
      }
      last = page.docs[page.docs.length - 1];
      if (page.size < PAGE) break;
    }

    // Replace exercises + events wholesale (deterministic ids make this
    // idempotent; stale docs from earlier runs are removed).
    await deleteCollection(stateRef.collection('exercises'));
    await deleteCollection(stateRef.collection('events'));

    let batch = db.batch();
    let ops = 0;
    const flush = async () => { if (ops > 0) { await batch.commit(); batch = db.batch(); ops = 0; } };

    for (const [exerciseId, history] of Object.entries(histories)) {
      const derived = deriveExerciseEvents(exerciseId, history);
      batch.set(stateRef.collection('exercises').doc(exerciseId), {
        name: derived.name,
        history,
        repBest: derived.repBest,
        e1rmBest: derived.e1rmBest,
        formulaVersion: E1RM_FORMULA_VERSION,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      ops += 1;
      for (const ev of derived.events) {
        batch.set(stateRef.collection('events').doc(ev.id), ev);
        ops += 1;
        if (ops >= 400) await flush();
      }
      if (ops >= 400) await flush();
    }
    await flush();

    await stateRef.set({
      bootstrapStatus: 'complete',
      bootstrapError: admin.firestore.FieldValue.delete(),
      e1rmFormulaVersion: E1RM_FORMULA_VERSION,
    }, { merge: true });
    logger.info('coach bootstrap complete', { athleteUid, exercises: Object.keys(histories).length });
  } catch (err) {
    logger.error('coach bootstrap failed', { athleteUid, error: err });
    await stateRef.set({
      bootstrapStatus: 'error',
      bootstrapError: String(err && err.message ? err.message : err),
    }, { merge: true });
    throw err;
  }
}

async function deleteCollection(colRef) {
  for (;;) {
    const page = await colRef.limit(400).get();
    if (page.empty) return;
    const batch = db.batch();
    page.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
    if (page.size < 400) return;
  }
}

/**
 * Trigger: coach flips reporting on/off for an athlete. Enabling registers
 * the coach in coachAnalytics.enabledBy and runs the bootstrap when needed
 * (missing, failed, or stale-formula analytics). Disabling deregisters the
 * coach; analytics are kept so re-enabling is instant.
 */
const coachOnAthleteSettingsWritten = onDocumentWritten(
  { document: 'coachCheckIns/{coachUid}/athletes/{athleteUid}', timeoutSeconds: 540, memory: '512MiB' },
  async (event) => {
    const { coachUid, athleteUid } = event.params;
    const after = event.data.after.exists ? event.data.after.data() : null;
    const before = event.data.before.exists ? event.data.before.data() : null;

    const enabledNow = !!(after && after.reportingEnabled);
    const enabledBefore = !!(before && before.reportingEnabled);

    if (enabledNow) {
      if (!(await isCoachFor(coachUid, athleteUid))) {
        logger.warn('settings write for non-assigned athlete ignored', { coachUid, athleteUid });
        return;
      }
      // Materialise the coach settings doc: subcollection writes alone leave
      // the parent doc virtual, and virtual docs never appear in the
      // scheduler's coachCheckIns collection scan.
      const coachSnap = await coachRef(coachUid).get();
      if (!coachSnap.exists) {
        await coachRef(coachUid).set({ timezone: DEFAULT_TZ }, { merge: true });
      }
      await analyticsRef(athleteUid).set({
        enabledBy: { [coachUid]: true },
      }, { merge: true });

      const state = await analyticsRef(athleteUid).get();
      const s = state.exists ? state.data() : {};
      const needsBootstrap = s.bootstrapStatus !== 'complete'
        || s.e1rmFormulaVersion !== E1RM_FORMULA_VERSION;
      if (needsBootstrap && s.bootstrapStatus !== 'running') {
        await bootstrapAthlete(athleteUid);
      }
    } else if (enabledBefore && !enabledNow) {
      await analyticsRef(athleteUid).set({
        enabledBy: { [coachUid]: admin.firestore.FieldValue.delete() },
      }, { merge: true });
    }
  }
);

// ── Checkpoint report generation ────────────────────────────────────────────

/** Completed-workout day detection identical to HomeV2CalendarService. */
function hasCompletedSets(data) {
  const exercises = data && data.exercises;
  if (!Array.isArray(exercises)) return false;
  for (const ex of exercises) {
    if (!ex || typeof ex !== 'object') continue;
    const sets = ex.sets;
    if (!Array.isArray(sets)) continue;
    for (const s of sets) {
      if (!s || typeof s !== 'object') continue;
      const w = Number(s.weight != null ? s.weight : s.actualWeight) || 0;
      const r = Number(s.reps != null ? s.reps : s.actualReps) || 0;
      if (w > 0 && r > 0) return true;
    }
  }
  return false;
}

/** Which of the dateKeys have a completed workout doc. Bounded direct gets. */
async function completedWorkoutDays(athleteUid, dateKeys) {
  const refs = dateKeys.map((k) =>
    db.collection('users').doc(athleteUid).collection('workouts').doc(k));
  if (refs.length === 0) return [];
  const snaps = await db.getAll(...refs);
  const out = [];
  snaps.forEach((snap, i) => {
    if (snap.exists && hasCompletedSets(snap.data())) out.push(dateKeys[i]);
  });
  return out;
}

/** Active block meta ({blockId, startKey, endKey}) or null. Timestamps are
 *  local-midnight stamps, so resolve the calendar day in the coach zone. */
async function activeBlock(athleteUid, tz) {
  const q = await db.collection('planned_blocks').doc(athleteUid)
    .collection('blocks')
    .where('isActive', '==', true)
    .limit(1)
    .get();
  if (q.empty) return null;
  const doc = q.docs[0];
  const d = doc.data();
  const start = d.startDate && typeof d.startDate.toDate === 'function' ? d.startDate.toDate() : null;
  const end = d.endDate && typeof d.endDate.toDate === 'function' ? d.endDate.toDate() : null;
  if (!start) return null;
  return {
    blockId: doc.id,
    startKey: cov.localDateKey(start, tz || DEFAULT_TZ),
    endKey: end ? cov.localDateKey(end, tz || DEFAULT_TZ) : null,
  };
}

/** Planned-workout day count for a block-anchored training week. */
async function plannedCountForWeek(athleteUid, block, weekIndex) {
  const refs = [];
  for (let i = 0; i < 7; i++) {
    refs.push(db.collection('planned_blocks').doc(athleteUid)
      .collection('blocks').doc(block.blockId)
      .collection('weeks').doc(`week_${weekIndex}`)
      .collection('days').doc(`day_${i}`));
  }
  const snaps = await db.getAll(...refs);
  let count = 0;
  for (const snap of snaps) {
    if (!snap.exists) continue;
    const ex = snap.data().exercises;
    if (Array.isArray(ex) && ex.length > 0) count += 1;
  }
  return count;
}

function rangeKeys(startKey, endKeyExclusive) {
  const out = [];
  for (let k = startKey; k < endKeyExclusive; k = cov.addDaysKey(k, 1)) out.push(k);
  return out;
}

/**
 * Evaluates the weekly-completion candidate for a checkpoint: the training
 * week (block-anchored) that most recently finished on/before the
 * checkpoint, or the in-progress week when it is already fully completed.
 */
async function completionCandidate(athleteUid, block, checkpointKey) {
  if (!block) return null;
  const current = cov.trainingWeekOf(block.startKey, cov.addDaysKey(checkpointKey, -1));
  if (!current) return null;

  const evaluate = async (week) => {
    const planned = await plannedCountForWeek(athleteUid, block, week.weekIndex);
    const doneDays = await completedWorkoutDays(athleteUid, rangeKeys(week.weekStart, week.weekEnd));
    return {
      weekKey: week.weekStart,
      weekStart: week.weekStart,
      weekEnd: week.weekEnd,
      weekIndex: week.weekIndex,
      plannedCount: planned,
      completedCount: doneDays.length,
      completedAll: planned > 0 && doneDays.length >= planned,
    };
  };

  // Candidates: the in-progress week and the last fully-elapsed week. The
  // weekly achievement is judged per block-anchored training week — never
  // split by Mon/Thu message windows — and becomes eligible at the first
  // checkpoint after it is known.
  const candidates = [await evaluate(current)];
  if (current.weekIndex > 0) {
    const prevWeek = cov.trainingWeekOf(block.startKey, cov.addDaysKey(current.weekStart, -1));
    if (prevWeek) candidates.push(await evaluate(prevWeek));
  }
  const qualifies = (c) => c.completedAll || c.completedCount >= 3;
  const qualifying = candidates.filter(qualifies).sort((a, b) => {
    if (a.completedAll !== b.completedAll) return a.completedAll ? -1 : 1;
    return a.weekStart < b.weekStart ? 1 : -1; // newer first
  });
  if (qualifying.length > 0) return qualifying[0];
  const withActivity = candidates.find((c) => c.completedCount > 0);
  return withActivity || null;
}

/** Most recent trained week (for the no-training coach fallback label). */
async function lastTrainedWeek(athleteUid, block, beforeKey) {
  const q = await db.collection('users').doc(athleteUid).collection('workouts')
    .orderBy(admin.firestore.FieldPath.documentId(), 'desc')
    .startAfter(beforeKey)
    .limit(14)
    .get();
  for (const doc of q.docs) {
    if (!DATE_KEY_RE.test(doc.id)) continue;
    if (!hasCompletedSets(doc.data())) continue;
    if (block) {
      const wk = cov.trainingWeekOf(block.startKey, doc.id);
      if (wk) {
        const days = await completedWorkoutDays(athleteUid, rangeKeys(wk.weekStart, wk.weekEnd));
        return { weekStart: wk.weekStart, weekEnd: wk.weekEnd, workoutDates: days };
      }
    }
    return { weekStart: doc.id, weekEnd: cov.addDaysKey(doc.id, 1), workoutDates: [doc.id] };
  }
  return null;
}

/**
 * Generates one athlete's checkpoint report document. Idempotent: refuses to
 * overwrite an existing report for the same checkpoint.
 */
async function generateReport(coachUid, athleteUid, checkpointKey, tz) {
  const ref = reportRef(coachUid, athleteUid, checkpointKey);
  if ((await ref.get()).exists) return false;

  const settingsSnap = await athleteSettingsRef(coachUid, athleteUid).get();
  const settings = settingsSnap.exists ? settingsSnap.data() : {};
  const goal = bwx.GOALS.includes(settings.goal) ? settings.goal : 'maintain';

  const prevKey = cov.previousCheckpointKey(checkpointKey);
  const maxStartKey = cov.previousSameWeekdayKey(checkpointKey);

  // PB events inside the widest possible window [maxStart, checkpoint).
  const eventsSnap = await analyticsRef(athleteUid).collection('events')
    .where('dateKey', '>=', maxStartKey)
    .where('dateKey', '<', checkpointKey)
    .get();
  const events = eventsSnap.docs.map((d) => d.data());

  // Completed workout days across the max window.
  const workoutDates = await completedWorkoutDays(
    athleteUid, rangeKeys(maxStartKey, checkpointKey));

  const block = await activeBlock(athleteUid, tz);
  const completion = await completionCandidate(athleteUid, block, checkpointKey);
  const fallbackWeek = workoutDates.length === 0
    ? await lastTrainedWeek(athleteUid, block, checkpointKey)
    : null;

  // Bodyweight state at the checkpoint.
  const weightEntries = await loadWeightEntries(athleteUid, cov.addDaysKey(checkpointKey, -21), tz);
  const rolling = bwx.rollingComparison(weightEntries, checkpointKey);
  const trend = bwx.classifyTrend(goal, rolling.currentAvg, rolling.previousAvg);
  const stateSnap = await analyticsRef(athleteUid).get();
  const awarded = stateSnap.exists ? (stateSnap.data().milestones || {}) : {};
  const newMilestoneId = bwx.detectMilestone(goal, rolling.previousAvg, rolling.currentAvg, awarded);
  const lastWeighKey = await latestWeighInKey(athleteUid, tz);
  const weighInStatus = bwx.weighInStatus(lastWeighKey, todayKeyIn(tz));

  const identity = await resolveAthleteIdentity(athleteUid);
  const variantSeed = seedFrom(`${athleteUid}|${checkpointKey}`);

  const bodyweight = {
    goal,
    currentAvg: rolling.currentAvg,
    currentCount: rolling.currentCount,
    previousAvg: rolling.previousAvg,
    previousCount: rolling.previousCount,
    trend,
    newMilestoneId: newMilestoneId || null,
    lastWeighInKey: lastWeighKey,
    weighInStatus,
  };

  // Draft previews for both candidate windows. The authoritative final text
  // is recomposed at copy time (live bodyweight recheck + praise dedup).
  const draftFor = (startKey) => buildDraftText({
    events, completion, settings, identity, bodyweight,
    coverageStart: startKey, coverageEnd: checkpointKey, variantSeed,
  });

  await ref.create({
    athleteUid,
    checkpointKey,
    weekday: cov.weekdayOfKey(checkpointKey),
    status: 'draft',
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    variantSeed,
    gender: identity.gender,
    firstName: identity.firstName,
    displayName: identity.displayName,
    prevCheckpointKey: prevKey,
    maxStartKey,
    events,
    workoutDates,
    completion: completion || null,
    fallbackWeek: fallbackWeek || null,
    blockStartKey: block ? block.startKey : null,
    bodyweight,
    draftIfPrevCopied: draftFor(prevKey),
    draftIfPrevNotCopied: draftFor(maxStartKey),
    analyticsVersion: ANALYTICS_VERSION,
    e1rmFormulaVersion: E1RM_FORMULA_VERSION,
  });
  return true;
}

/** Deterministic 32-bit seed from a string. */
function seedFrom(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h;
}

/**
 * Composes a client draft for a given coverage window from report inputs.
 * Praise rules: events filtered to window; already-praised weeks excluded;
 * custom exercise mode filters the client draft (never the coach summary).
 */
function buildDraftText({
  events, completion, settings, identity, bodyweight,
  coverageStart, coverageEnd, variantSeed,
}) {
  const inWindow = (e) => e.dateKey >= coverageStart && e.dateKey < coverageEnd;
  const repEvents = events.filter((e) => e.type === 'repPB' && inWindow(e));
  const e1rmEvents = events.filter((e) => e.type === 'e1rmPB' && inWindow(e));

  const praisedWeeks = (settings && settings.praisedWeeks) || {};
  const completionInput = completion ? {
    completedAll: !!completion.completedAll,
    count: completion.completedCount,
    planned: completion.plannedCount,
    weekAlreadyPraised: Object.prototype.hasOwnProperty.call(praisedWeeks, completion.weekKey),
  } : null;

  const allowed = (settings && settings.messageExerciseMode === 'custom')
    ? (Array.isArray(settings.customExerciseIds) ? settings.customExerciseIds : [])
    : null;

  const { praises } = selectPraise({
    repEvents, e1rmEvents, completion: completionInput, allowedExerciseIds: allowed,
  });

  return composeDraft({
    praises,
    bodyweight,
    gender: identity.gender,
    firstName: identity.firstName,
    variantSeed,
  }) || '';
}

/**
 * Scheduler: hourly sweep. For every coach whose local calendar is currently
 * on a Monday or Thursday and whose checkpoint has not been generated yet,
 * generates reports for all reporting-enabled, still-assigned athletes and
 * expires over-aged drafts. Watermark (lastCheckpointKey) keeps re-runs to a
 * single document read per coach per hour.
 */
const coachCheckpointScheduler = onSchedule(
  { schedule: 'every 60 minutes', timeoutSeconds: 540, memory: '512MiB' },
  async () => {
    const coaches = await db.collection('coachCheckIns').get();
    const now = new Date();

    for (const coachDoc of coaches.docs) {
      const coachUid = coachDoc.id;
      const data = coachDoc.data() || {};
      const tz = data.timezone || DEFAULT_TZ;
      const checkpointKey = cov.currentCheckpointKey(now, tz);
      if (!checkpointKey) continue;
      if (data.lastCheckpointKey === checkpointKey) continue;

      try {
        const athletes = await coachRef(coachUid).collection('athletes')
          .where('reportingEnabled', '==', true)
          .get();

        let allOk = true;
        for (const aDoc of athletes.docs) {
          const athleteUid = aDoc.id;
          try {
            if (!(await isCoachFor(coachUid, athleteUid))) {
              logger.warn('skipping unassigned athlete at checkpoint', { coachUid, athleteUid });
              continue;
            }
            await generateReport(coachUid, athleteUid, checkpointKey, tz);
            await expireStaleDraft(coachUid, athleteUid, checkpointKey);
          } catch (err) {
            allOk = false;
            logger.error('report generation failed', { coachUid, athleteUid, checkpointKey, error: err });
          }
        }

        if (allOk) {
          await coachRef(coachUid).set({ lastCheckpointKey: checkpointKey }, { merge: true });
        }
      } catch (err) {
        logger.error('checkpoint sweep failed for coach', { coachUid, error: err });
      }
    }
  }
);

/** Expires the draft two checkpoints back (older than the new "previous"). */
async function expireStaleDraft(coachUid, athleteUid, checkpointKey) {
  const prev = cov.previousCheckpointKey(checkpointKey);
  const prevPrev = cov.previousCheckpointKey(prev);
  const ref = reportRef(coachUid, athleteUid, prevPrev);
  const snap = await ref.get();
  if (snap.exists && snap.data().status === 'draft') {
    await ref.set({ status: 'expired', expiredAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
  }
}

// ── Copy / undo / skip callables ────────────────────────────────────────────

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError('unauthenticated', 'Sign in required.');
  }
  return request.auth.uid;
}

/** Loads report + neighbour statuses needed by the state machine guards. */
async function loadReportContext(coachUid, athleteUid, checkpointKey) {
  const ref = reportRef(coachUid, athleteUid, checkpointKey);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError('not-found', 'Report not found.');

  // Enumerate potentially newer checkpoints up to today (drafts older than
  // the previous checkpoint are expired, so this stays tiny).
  const reports = { [checkpointKey]: snap.data() };
  let k = checkpointKey;
  const today = todayKeyIn(null);
  for (let i = 0; i < 8; i++) {
    k = nextCheckpointKey(k);
    if (k > today) break;
    const s = await reportRef(coachUid, athleteUid, k).get();
    if (s.exists) reports[k] = s.data();
  }
  return { ref, report: snap.data(), reports };
}

function nextCheckpointKey(checkpointKey) {
  const wd = cov.weekdayOfKey(checkpointKey);
  if (wd === 'Mon') return cov.addDaysKey(checkpointKey, 3);
  if (wd === 'Thu') return cov.addDaysKey(checkpointKey, 4);
  throw new Error(`not a checkpoint key: ${checkpointKey}`);
}

/**
 * Copy-time preparation: recomputes the effective coverage from the previous
 * checkpoint's LIVE copy state, re-checks bodyweight/weigh-in state live,
 * composes the authoritative message, freezes everything, and records praise
 * bookkeeping. Returns { text, coverageStart, coverageEnd }.
 */
const coachPrepareCheckInCopy = onCall(async (request) => {
  const coachUid = requireAuth(request);
  const { athleteUid, checkpointKey } = request.data || {};
  if (typeof athleteUid !== 'string' || !DATE_KEY_RE.test(String(checkpointKey || ''))) {
    throw new HttpsError('invalid-argument', 'athleteUid and checkpointKey required.');
  }
  if (!(await isCoachFor(coachUid, athleteUid))) {
    throw new HttpsError('permission-denied', 'Not an assigned coach for this athlete.');
  }

  const { ref, report, reports } = await loadReportContext(coachUid, athleteUid, checkpointKey);
  if (report.status === 'copied') {
    // Re-copy of an already-copied report returns the frozen text unchanged.
    return { text: report.finalText || '', coverageStart: report.coverageStart, coverageEnd: report.coverageEnd, alreadyCopied: true };
  }
  if (report.status === 'expired' || report.status === 'skipped') {
    throw new HttpsError('failed-precondition', `Check-in is ${report.status}.`);
  }
  if (!cov.canCopy(checkpointKey, reports)) {
    throw new HttpsError('failed-precondition', 'A newer check-in was already finalised.');
  }

  const settingsRef = athleteSettingsRef(coachUid, athleteUid);
  const settingsSnap = await settingsRef.get();
  const settings = settingsSnap.exists ? settingsSnap.data() : {};

  // Effective coverage from the previous checkpoint's live status.
  const prevSnap = await reportRef(coachUid, athleteUid, report.prevCheckpointKey).get();
  const prevCopied = prevSnap.exists && prevSnap.data().status === 'copied';
  const coverage = cov.effectiveCoverage(
    checkpointKey, prevCopied, settings.lastFinalizedCoverageEnd || null);

  // LIVE bodyweight recheck (training achievements stay frozen to the
  // checkpoint cutoff; only the bodyweight portion refreshes).
  const coachSnap = await coachRef(coachUid).get();
  const tz = (coachSnap.exists && coachSnap.data().timezone) || DEFAULT_TZ;
  const todayKey = todayKeyIn(tz);
  const goal = (report.bodyweight && report.bodyweight.goal) || 'maintain';
  const entries = await loadWeightEntries(athleteUid, cov.addDaysKey(todayKey, -21), tz);
  const rolling = bwx.rollingComparison(entries, todayKey);
  const trend = bwx.classifyTrend(goal, rolling.currentAvg, rolling.previousAvg);
  const stateSnap = await analyticsRef(athleteUid).get();
  const awarded = stateSnap.exists ? (stateSnap.data().milestones || {}) : {};
  const newMilestoneId = bwx.detectMilestone(goal, rolling.previousAvg, rolling.currentAvg, awarded);
  const lastWeighKey = await latestWeighInKey(athleteUid, tz);
  const liveBodyweight = {
    goal,
    currentAvg: rolling.currentAvg,
    currentCount: rolling.currentCount,
    previousAvg: rolling.previousAvg,
    previousCount: rolling.previousCount,
    trend,
    newMilestoneId: newMilestoneId || null,
    lastWeighInKey: lastWeighKey,
    weighInStatus: bwx.weighInStatus(lastWeighKey, todayKey),
  };

  const identity = { gender: report.gender, firstName: report.firstName };
  const text = buildDraftText({
    events: report.events || [],
    workoutDates: report.workoutDates || [],
    completion: report.completion || null,
    settings,
    identity,
    bodyweight: liveBodyweight,
    coverageStart: coverage.start,
    coverageEnd: coverage.end,
    variantSeed: report.variantSeed,
  });

  // Freeze + bookkeeping in one transaction.
  const praisedWeekKey = computePraisedWeekKey(report, settings, coverage);
  await db.runTransaction(async (tx) => {
    const fresh = await tx.get(ref);
    if (!fresh.exists || fresh.data().status !== 'draft') {
      throw new HttpsError('aborted', 'Report changed underneath the copy.');
    }
    tx.update(ref, {
      status: 'copied',
      copiedAt: admin.firestore.FieldValue.serverTimestamp(),
      coverageStart: coverage.start,
      coverageEnd: coverage.end,
      finalText: text,
      liveBodyweight,
      praisedWeekKey: praisedWeekKey || null,
      milestoneAwarded: newMilestoneId || null,
      prevLastFinalizedCoverageEnd: settings.lastFinalizedCoverageEnd || null,
    });
    const settingsUpdate = { lastFinalizedCoverageEnd: coverage.end };
    if (praisedWeekKey) {
      settingsUpdate.praisedWeeks = { [praisedWeekKey]: ref.id };
    }
    tx.set(settingsRef, settingsUpdate, { merge: true });
    if (newMilestoneId) {
      tx.set(analyticsRef(athleteUid), {
        milestones: { [newMilestoneId]: todayKey },
      }, { merge: true });
    }
  });

  return { text, coverageStart: coverage.start, coverageEnd: coverage.end };
});

/** Which training week gets its completion praise recorded by this copy. */
function computePraisedWeekKey(report, settings, coverage) {
  const completion = report.completion;
  if (!completion) return null;
  const praisedWeeks = settings.praisedWeeks || {};
  if (Object.prototype.hasOwnProperty.call(praisedWeeks, completion.weekKey)) return null;
  const qualifies = completion.completedAll || completion.completedCount >= 3;
  if (!qualifies) return null;
  // Only record when the draft could actually praise it (some PB-heavy drafts
  // fill all three slots; praising later would then be wrong — the selection
  // is deterministic, so re-derive it the same way buildDraftText does).
  const inWindow = (e) => e.dateKey >= coverage.start && e.dateKey < coverage.end;
  const repEvents = (report.events || []).filter((e) => e.type === 'repPB' && inWindow(e));
  const e1rmEvents = (report.events || []).filter((e) => e.type === 'e1rmPB' && inWindow(e));
  const allowed = settings.messageExerciseMode === 'custom'
    ? (Array.isArray(settings.customExerciseIds) ? settings.customExerciseIds : [])
    : null;
  const { usedCompletion } = selectPraise({
    repEvents,
    e1rmEvents,
    completion: {
      completedAll: !!completion.completedAll,
      count: completion.completedCount,
      planned: completion.plannedCount,
      weekAlreadyPraised: false,
    },
    allowedExerciseIds: allowed,
  });
  return usedCompletion ? completion.weekKey : null;
}

/** Undo / Mark-Not-Sent: reverts a copy while it is still safe to do so. */
const coachUndoCheckIn = onCall(async (request) => {
  const coachUid = requireAuth(request);
  const { athleteUid, checkpointKey } = request.data || {};
  if (typeof athleteUid !== 'string' || !DATE_KEY_RE.test(String(checkpointKey || ''))) {
    throw new HttpsError('invalid-argument', 'athleteUid and checkpointKey required.');
  }

  const { ref, report, reports } = await loadReportContext(coachUid, athleteUid, checkpointKey);
  if (report.status !== 'copied') {
    throw new HttpsError('failed-precondition', 'Only a copied check-in can be undone.');
  }
  if (!cov.canUndo(checkpointKey, reports)) {
    throw new HttpsError('failed-precondition', 'A newer check-in was finalised; undo is no longer safe.');
  }

  const settingsRef = athleteSettingsRef(coachUid, athleteUid);
  await db.runTransaction(async (tx) => {
    const fresh = await tx.get(ref);
    if (!fresh.exists || fresh.data().status !== 'copied') {
      throw new HttpsError('aborted', 'Report changed underneath the undo.');
    }
    const data = fresh.data();
    tx.update(ref, {
      status: 'draft',
      copiedAt: admin.firestore.FieldValue.delete(),
      coverageStart: admin.firestore.FieldValue.delete(),
      coverageEnd: admin.firestore.FieldValue.delete(),
      finalText: admin.firestore.FieldValue.delete(),
      liveBodyweight: admin.firestore.FieldValue.delete(),
      praisedWeekKey: admin.firestore.FieldValue.delete(),
      milestoneAwarded: admin.firestore.FieldValue.delete(),
      prevLastFinalizedCoverageEnd: admin.firestore.FieldValue.delete(),
    });
    const settingsUpdate = {
      lastFinalizedCoverageEnd: data.prevLastFinalizedCoverageEnd || admin.firestore.FieldValue.delete(),
    };
    if (data.praisedWeekKey) {
      settingsUpdate.praisedWeeks = {
        [data.praisedWeekKey]: admin.firestore.FieldValue.delete(),
      };
    }
    tx.set(settingsRef, settingsUpdate, { merge: true });
    if (data.milestoneAwarded) {
      tx.set(analyticsRef(athleteUid), {
        milestones: { [data.milestoneAwarded]: admin.firestore.FieldValue.delete() },
      }, { merge: true });
    }
  });

  return { ok: true };
});

/** Skip: deliberately closes an unused opportunity (counts as NOT copied for
 *  the next window, but blocks late copies of this checkpoint). */
const coachSkipCheckIn = onCall(async (request) => {
  const coachUid = requireAuth(request);
  const { athleteUid, checkpointKey } = request.data || {};
  if (typeof athleteUid !== 'string' || !DATE_KEY_RE.test(String(checkpointKey || ''))) {
    throw new HttpsError('invalid-argument', 'athleteUid and checkpointKey required.');
  }
  const { ref, report } = await loadReportContext(coachUid, athleteUid, checkpointKey);
  if (report.status !== 'draft') {
    throw new HttpsError('failed-precondition', 'Only a draft can be skipped.');
  }
  await ref.update({
    status: 'skipped',
    skippedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  return { ok: true };
});

module.exports = {
  coachAnalyticsOnWorkoutWrite,
  coachOnAthleteSettingsWritten,
  coachCheckpointScheduler,
  coachPrepareCheckInCopy,
  coachUndoCheckIn,
  coachSkipCheckIn,
};
