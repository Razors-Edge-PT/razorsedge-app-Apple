// Cloud Functions for Firebase (v2 modular syntax)
const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

try { admin.initializeApp(); } catch (_) {}
const db = admin.firestore();

// **** YOUR PATH ****
// Users' RE Daily docs like: /users/{uid}/re_daily/{dayKey}
const RE_DAILY_PATH = 'users/{uid}/re_daily/{dayKey}';

// Canonical lift keys (must match app/UI keys)
const LIFTS = [
  'Back Squat, Barbell',
  'Bench Press, Barbell',
  'Deadlift, Conventional',
  'Chin-Up',
  'Overhead Dumbbell Press, Unilateral',
];

function monthKeyFromDate(d) {
  const yyyy = d.getFullYear();
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  return `${yyyy}-${mm}`;
}
const num = (v) => (typeof v === 'number' ? v : 0);

// Try to parse YYYY-MM-DD from the docId (dayKey)
function dateFromDayKey(dayKey) {
  // Safety: handle incorrect ids
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dayKey || '');
  if (!m) return new Date(); // fallback now
  const y = parseInt(m[1], 10);
  const mo = parseInt(m[2], 10) - 1;
  const d = parseInt(m[3], 10);
  return new Date(Date.UTC(y, mo, d, 12, 0, 0)); // noon UTC to avoid TZ drift
}

// Extract total points and per-lift points from your daily schema
function extractPointsFromDailyDoc(docData) {
  // Preferred: sum of lifts[*].pts
  const lifts = docData?.lifts || {};
  const perLift = {};
  let total = 0;

  for (const k of LIFTS) {
    const entry = lifts?.[k];
    const pts = num(entry?.pts);
    perLift[k] = pts;
    total += pts;
  }

  // Fallbacks if you ever store these directly:
  // - dailyTotal
  // - rePointsByLift / perLift
  if (total === 0) {
    if (typeof docData?.dailyTotal === 'number') total = docData.dailyTotal;
  }
  if (Object.values(perLift).every((v) => v === 0)) {
    const alt = docData?.rePointsByLift || docData?.perLift || {};
    for (const k of LIFTS) perLift[k] = num(alt[k]);
    const sumAlt = Object.values(perLift).reduce((a, b) => a + b, 0);
    if (sumAlt > 0) total = sumAlt;
  }

  return { total, perLift };
}

exports.repointsMonthlyAggregator = onDocumentWritten(RE_DAILY_PATH, async (event) => {
  const before = event.data?.before?.data() || null;
  const after  = event.data?.after?.data()  || null;

  // You only want to track daily RE docs, which in your schema are all docs here
  // (No need to check type == 're_daily' because the collection itself is re_daily)

  // Identify user + month key
  const uid = event.params?.uid;
  const dayKey = event.params?.dayKey;
  if (!uid || !dayKey) return;

  const dt = dateFromDayKey(dayKey);
  const mKey = monthKeyFromDate(dt);

  // Compute before/after points
  const { total: totalBefore, perLift: perLiftBefore } = before ? extractPointsFromDailyDoc(before) : { total: 0, perLift: {} };
  const { total: totalAfter,  perLift: perLiftAfter  } = after  ? extractPointsFromDailyDoc(after)  : { total: 0, perLift: {} };

  const deltaTotal = totalAfter - totalBefore;
  const deltaByLift = {};
  for (const k of LIFTS) {
    deltaByLift[k] = num(perLiftAfter[k]) - num(perLiftBefore[k]);
  }

  const userPubRef = db.collection('users_public').doc(uid);

  try {
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userPubRef);
      const m = snap.exists ? snap.data() : {};

      const curKey = m.currentMonthKey;
      const sameMonth = (curKey === mKey);

      // Initialize/reset structure on month change
      const currentByLift = sameMonth && m.rePointsMonthlyByLiftCurrent
        ? { ...m.rePointsMonthlyByLiftCurrent }
        : Object.fromEntries(LIFTS.map(k => [k, 0]));

      let currentTotal = sameMonth ? num(m.rePointsMonthlyCurrent) : 0;

      // Apply deltas (create/update/delete)
      currentTotal = num(currentTotal) + deltaTotal;
      for (const k of LIFTS) {
        currentByLift[k] = num(currentByLift[k]) + num(deltaByLift[k]);
      }

      // Clamp >= 0
      currentTotal = Math.max(0, currentTotal);
      for (const k of LIFTS) currentByLift[k] = Math.max(0, currentByLift[k]);

      tx.set(userPubRef, {
        currentMonthKey: mKey,
        rePointsMonthlyCurrent: currentTotal,
        rePointsMonthlyByLiftCurrent: currentByLift,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    logger.info('Monthly RE updated', { uid, dayKey, mKey, delta: deltaTotal });
  } catch (e) {
    logger.error('Monthly aggregator failed', { error: e, uid, dayKey });
    throw e;
  }
});
