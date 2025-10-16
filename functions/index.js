// Cloud Functions for Firebase (v2)
const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');
try { admin.initializeApp(); } catch (_) {}
const db = admin.firestore();

// --- Constants ---
const CANONICAL_LIFTS = [
  'Bench Press, Barbell',
  'Back Squat, Barbell',
  'Deadlift, Conventional',
  'Chin-Up',
  'Overhead Dumbbell Press, Unilateral',
];

const RE_DAILY_PATH = 'users/{uid}/re_daily/{dayKey}';

// --- Helpers ---
function monthKeyFromDate(d) {
  const yyyy = d.getFullYear();
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  return `${yyyy}-${mm}`;
}

function parseDate(dayKey) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dayKey || '');
  if (!m) return new Date();
  return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], 12, 0, 0));
}

function num(v) {
  return typeof v === 'number' && !isNaN(v) ? v : 0;
}

// --- Function ---
exports.repointsMonthlyAggregator = onDocumentWritten(RE_DAILY_PATH, async (event) => {
  const uid = event.params?.uid;
  const dayKey = event.params?.dayKey;
  const after = event.data?.after?.data();

  if (!uid || !dayKey) return;
  if (!after) return; // deleted day → nothing to aggregate

  try {
    const monthKey = monthKeyFromDate(parseDate(dayKey));
    const monthlyRef = db.collection('users').doc(uid)
                         .collection('re_monthly').doc(monthKey);

    // 1) Extract best score per canonical lift from today's doc (safe for arrays/empty)
    const lifts = after.lifts || {};
    const bestPerLift = {};
    for (const lift of CANONICAL_LIFTS) {
      const entry = lifts[lift];
      if (!entry) { bestPerLift[lift] = 0; continue; }
      if (Array.isArray(entry)) {
        const arr = entry.map(e => num(e?.pts || 0));
        bestPerLift[lift] = arr.length ? Math.max(...arr) : 0;
      } else {
        bestPerLift[lift] = num(entry.pts);
      }
    }

    // 2) Transaction: update this day in month doc + recompute totals
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(monthlyRef);
      const data = snap.exists ? snap.data() : {};
      const days = data.days || {};
      days[dayKey] = bestPerLift;

      let total = 0;
      for (const d of Object.values(days)) {
        for (const lift of CANONICAL_LIFTS) total += num(d[lift]);
      }

      tx.set(monthlyRef, {
        days,
        totalPoints: total,
        recomputedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    // 3) Read back the saved total and sync to users_public for the client
    const monthlySnap = await monthlyRef.get();
    const total = monthlySnap.exists ? num(monthlySnap.data().totalPoints) : 0;

    await db.collection('users_public').doc(uid).set({
      rePointsMonthlyCurrent: total,
      currentMonthKey: monthKey,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    logger.info('✅ Monthly RE recomputed & synced', { uid, dayKey, total });
  } catch (err) {
    logger.error('❌ Monthly aggregator failed', { uid, dayKey, error: err });
    throw err;
  }
});
