// Cloud Functions for Firebase (v2)
const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const { onRequest } = require('firebase-functions/v2/https');
const functions = require('firebase-functions');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');
const Stripe = require('stripe');

// -------------------------
// Stripe init (no functions.config; using env or hardcoded for now)
// -------------------------

// ⚠️ For now, simplest: read from env, with optional fallback literals.
// In production, you should move the literal keys into env via the new
// Firebase runtime config / GCP env vars instead of keeping them in code.
const stripeSecret = process.env.STRIPE_SECRET; 
const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;


//const stripeSecret = process.env.STRIPE_SECRET || 'sk_test_51PuTPmBoDt989R6zy9h9tkRoV9r9RjGyyJO7G5ukqv7sb8eFQdShoK4vRZ6e5satjZ0d7yzV0ixXWf9g7Ri00upN008Puqquqv'; // test key
//const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET || 'whsec_4tRDzNm2iM9BnpNXAqqkwO0yHMreBQU3'; // test key
if (!stripeSecret) {
  logger.error('❌ Missing Stripe secret key. Set STRIPE_SECRET env var.');
}

if (!webhookSecret) {
  logger.error('❌ Missing Stripe webhook secret. Set STRIPE_WEBHOOK_SECRET env var.');
}

const stripe = stripeSecret ? Stripe(stripeSecret) : null;


// -------------------------
// Firebase Admin init
// -------------------------
try { admin.initializeApp(); } catch (_) {}
const db = admin.firestore();

// -------------------------
// Stripe init (from env or functions:config)
// -------------------------


// -------------------------
// Constants
// -------------------------
const CANONICAL_LIFTS = [
  'Bench Press, Barbell',
  'Back Squat, Barbell',
  'Deadlift, Conventional',
  'Chin-Up',
  'Overhead Dumbbell Press, Unilateral',
];

const RE_DAILY_PATH = 'users/{uid}/re_daily/{dayKey}';

// Membership doc path
const MEMBERSHIP_DOC_PATH = (uid) => `users/${uid}/profile/membership`;


//const MONTHLY_PRICE_ID = 'price_1SKtWlBoDt989R6zJyzciOlF'; // < -- The real deal pricetag
//const MONTHLY_PRICE_ID = 'price_1SbxI4BoDt989R6zoUAC0L8w'; // <-- The test price tag
const MONTHLY_PRICE_ID = 'price_1SKtWlBoDt989R6zJyzciOlF'; // <-- CHANGE THIS


//$1 deal set up
const EARLY_BIRD_PRICE_ID = 'price_1SKtXpBoDt989R6zQB9GHcYG';



// -------------------------
// Helper functions (existing)
// -------------------------
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

// -------------------------
// RE Points Aggregator (unchanged)
// -------------------------
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

    // 2) Transaction: update this day in month doc + recompute totals.
    // Also atomically write monthly totals to users_public to prevent race conditions
    // where two concurrent invocations overwrite each other with stale partial sums.
    const publicRef = db.collection('users_public').doc(uid);
    let monthTotal = 0;
    let savedDays = {};

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(monthlyRef);
      const data = snap.exists ? snap.data() : {};
      const days = data.days || {};
      days[dayKey] = bestPerLift;

      let total = 0;
      for (const d of Object.values(days)) {
        if (typeof d === 'number') {
          total += num(d); // legacy scalar written by old client-side _updateMonthly()
        } else {
          for (const lift of CANONICAL_LIFTS) total += num(d[lift]);
        }
      }

      const perLiftMonthly = {};
      for (const lift of CANONICAL_LIFTS) {
        let liftTotal = 0;
        for (const d of Object.values(days)) liftTotal += num(d[lift]);
        perLiftMonthly[lift] = liftTotal;
      }

      tx.set(monthlyRef, {
        days,
        totalPoints: total,
        recomputedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      tx.set(publicRef, {
        rePointsMonthlyCurrent: total,
        rePointsMonthlyByLiftCurrent: perLiftMonthly,
        currentMonthKey: monthKey,
      }, { merge: true });

      monthTotal = total;
      savedDays = { ...days };
    });

    // 3) Values captured from transaction — no separate Firestore read needed
    const total = monthTotal;

    // ── All-time per-lift bests (Fix 2: scan-only-when-needed) ──────────────
    // A) Read current all-time state + provenance (1 read)
    const publicSnap = await publicRef.get();
    const publicData = publicSnap.exists ? publicSnap.data() : {};
    const currentBests = publicData.rePointsByLift || {};
    const provenance = publicData.rePointsByLiftSource || {};

    // B) This day's updated per-lift pts are already in savedDays (in memory)
    const dayPts = savedDays[dayKey] || {};

    // C) Decide per lift: update directly or flag for scan
    const newBests = { ...currentBests };
    const newProvenance = { ...provenance };
    const liftsToScan = [];

    for (const lift of CANONICAL_LIFTS) {
      const todayPts = num(dayPts[lift]);
      const currentBest = num(currentBests[lift]);

      if (todayPts >= currentBest) {
        // New PR or tie — update directly, no scan needed
        newBests[lift] = todayPts;
        newProvenance[lift] = { dayKey, monthKey };
      } else {
        // Score went down — only scan if this day was (or may have been) the source
        const src = provenance[lift];
        if (!src || src.dayKey === dayKey) {
          liftsToScan.push(lift);
        }
        // else: another day holds the best → current value still valid, skip
      }
    }

    // D) Scan re_monthly only for lifts that need invalidation (0 reads in common case)
    if (liftsToScan.length > 0) {
      const allMonthlySnaps = await db
        .collection('users').doc(uid).collection('re_monthly').get();

      for (const lift of liftsToScan) {
        let best = 0;
        let bestDayKey = null;
        let bestMonthKey = null;

        for (const mSnap of allMonthlySnaps.docs) {
          const mDays = mSnap.data().days || {};
          for (const [dk, dPts] of Object.entries(mDays)) {
            const pts = num(dPts[lift]);
            if (pts > best) {
              best = pts;
              bestDayKey = dk;
              bestMonthKey = mSnap.id;
            }
          }
        }

        newBests[lift] = best;
        if (bestDayKey) newProvenance[lift] = { dayKey: bestDayKey, monthKey: bestMonthKey };
        else delete newProvenance[lift];
      }
    }

    // E) Sum rePoints across all 5 canonical lifts
    let rePoints = 0;
    for (const lift of CANONICAL_LIFTS) rePoints += num(newBests[lift]);
    // ── End Fix 2 ────────────────────────────────────────────────────────────

logger.info('🟦 about to write users_public', { uid, monthKey, total });

    await publicRef.set({
      rePointsByLift: newBests,
      rePoints: rePoints,
      rePointsByLiftSource: newProvenance,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    logger.info('🟩 wrote users_public', { uid });


    // 4) Write/merge /posts/{uid}_{dayKey} for the Home feed
    const postId = `${uid}_${dayKey.replace(/-/g, '')}`;
    const postRef = db.collection('posts').doc(postId);
    const dailyTotal = num(after.totalPoints);

    // Build perLift deterministically (always include all canonical lifts)
    const perLift = {};
    for (const lift of CANONICAL_LIFTS) {
      const entry = lifts[lift];
      const pts =
        entry && typeof entry === 'object' && !Array.isArray(entry)
          ? num(entry.pts)
          : 0;
      perLift[lift] = { pts };
    }

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(postRef);
      const existing = snap.exists ? snap.data() : null;
      const hasCreatedAt = !!(existing && existing.createdAt);

      const postData = {
        type: 're_daily',
        ownerUid: uid,
        dayKey,
        monthKey,
        dailyTotal,
        perLift,
        badges: after.badges || [],
        visibility: 'friends',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      };

      if (after.bodyweightUsedKg != null) {
        postData.bodyweightUsedKg = num(after.bodyweightUsedKg);
      }

      // 🔑 Critical: ensure createdAt exists for orderBy('createdAt') queries
      if (!snap.exists || !hasCreatedAt) {
        postData.createdAt = admin.firestore.FieldValue.serverTimestamp();
      }

      tx.set(postRef, postData, { merge: true });
    });


    logger.info('✅ Monthly RE recomputed & synced + post written', { uid, dayKey, total, postId });
  } catch (err) {
    logger.error('❌ Monthly aggregator failed', { uid, dayKey, error: err });
    throw err;
  }
});


// ====================================
// Membership helpers
// ====================================
async function updateMembershipForUid(uid, partial) {
  const ref = db.doc(MEMBERSHIP_DOC_PATH(uid));
  const updateData = {
    ...partial,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  await ref.set(updateData, { merge: true });
  logger.info(`✅ Updated membership for uid=${uid}`, updateData);
}

async function resolveUidFromStripeCustomer(customerId, fallbackMeta) {
  // 1) Try metadata.firebaseUid from direct payload
  if (fallbackMeta && fallbackMeta.firebaseUid) {
    return fallbackMeta.firebaseUid;
  }

  if (!stripe) {
    logger.error('Stripe not initialized');
    return null;
  }

  // 2) Fetch customer and look at metadata
  try {
    const customer = await stripe.customers.retrieve(customerId);
    if (customer.metadata && customer.metadata.firebaseUid) {
      return customer.metadata.firebaseUid;
    }

    logger.warn(`No firebaseUid metadata found for customer ${customerId}`);
    return null;
  } catch (err) {
    logger.error(`Error fetching customer ${customerId}`, err);
    return null;
  }
}


// ====================================
// createCheckoutSession (website → Stripe)
// ====================================
exports.createCheckoutSession = onRequest(
 { cors: true, secrets: ['STRIPE_SECRET'] },

  async (req, res) => {
    if (req.method !== 'POST') {
      return res.status(405).send('Method Not Allowed');
    }

    if (!stripe) {
      logger.error('Stripe not initialized in createCheckoutSession');
      return res.status(500).json({ error: 'Stripe not configured' });
    }

    try {
      const { uid, success_url, cancel_url } = req.body || {};

      if (!uid) {
        logger.warn('Missing uid in createCheckoutSession');
        return res.status(400).json({ error: 'Missing uid' });
      }

      const membershipRef = db.doc(MEMBERSHIP_DOC_PATH(uid));
      const membershipSnap = await membershipRef.get();
      let stripeCustomerId = null;

      if (membershipSnap.exists) {
        const data = membershipSnap.data();
        if (data && data.stripeCustomerId) {
          stripeCustomerId = data.stripeCustomerId;
        }
      }

      if (!stripeCustomerId) {
        // Create Stripe customer
        const customer = await stripe.customers.create({
          metadata: { firebaseUid: uid },
        });
        stripeCustomerId = customer.id;

        await updateMembershipForUid(uid, {
          stripeCustomerId: stripeCustomerId,
        });
      }

      const session = await stripe.checkout.sessions.create({
        mode: 'subscription',
        customer: stripeCustomerId,
        line_items: [
          {
            price: MONTHLY_PRICE_ID,
            quantity: 1,
          },
        ],
       success_url:
         success_url ||
         'https://www.razorsedgept.com/goodlift-membership?status=success&session_id={CHECKOUT_SESSION_ID}',
       cancel_url:
         cancel_url ||
         'https://www.razorsedgept.com/goodlift-membership?status=cancel',

        metadata: {
          firebaseUid: uid,
        },
      });

      return res.status(200).json({ url: session.url });
    } catch (err) {
      logger.error('Error in createCheckoutSession', err);
      return res.status(500).json({ error: 'Internal Server Error' });
    }
  }
);

exports.createEarlyBirdCheckoutSession = onRequest(
 { cors: true, secrets: ['STRIPE_SECRET'] },
  async (req, res) => {
    if (req.method !== 'POST') {
      return res.status(405).send('Method Not Allowed');
    }

    if (!stripe) {
      logger.error('Stripe not initialized in createEarlyBirdCheckoutSession');
      return res.status(500).json({ error: 'Stripe not configured' });
    }

    try {
      const { uid, success_url, cancel_url } = req.body || {};

      if (!uid) {
        logger.warn('Missing uid in createEarlyBirdCheckoutSession');
        return res.status(400).json({ error: 'Missing uid' });
      }

      // --- Fetch or create Stripe Customer ---
      const membershipRef = db.doc(MEMBERSHIP_DOC_PATH(uid));
      const membershipSnap = await membershipRef.get();
      let stripeCustomerId = null;

      if (membershipSnap.exists) {
        const data = membershipSnap.data();
        if (data && data.stripeCustomerId) {
          stripeCustomerId = data.stripeCustomerId;
        }
      }

      if (!stripeCustomerId) {
        const customer = await stripe.customers.create({
          metadata: { firebaseUid: uid },
        });
        stripeCustomerId = customer.id;

        await updateMembershipForUid(uid, {
          stripeCustomerId: stripeCustomerId,
        });
      }

      // --- Create Early Bird Checkout Session ---
      const session = await stripe.checkout.sessions.create({
        mode: 'subscription',
        customer: stripeCustomerId,
        line_items: [
          // Recurring monthly subscription
          {
            price: MONTHLY_PRICE_ID,
            quantity: 1,
          },
          // One-time $1 Early Bird charge
          {
            price: EARLY_BIRD_PRICE_ID,
            quantity: 1,
          },
        ],
        // Your success & cancel URLs (fallbacks preserved)
        success_url:
          success_url ||
          'https://www.razorsedgept.com/goodlift-membership?status=success&session_id={CHECKOUT_SESSION_ID}',

        cancel_url:
          cancel_url ||
          'https://www.razorsedgept.com/goodlift-membership?status=cancel',


        // --- Metadata passed through to Stripe & webhook ---
        metadata: {
          firebaseUid: uid,
          planType: 'earlyBird',
        },
        subscription_data: {
          metadata: {
            firebaseUid: uid,
            planType: 'earlyBird',
          },
          // KEEP YOUR TRIAL LOGIC CONSISTENT
          trial_period_days: 7,
        },
      });

      return res.status(200).json({ url: session.url });
    } catch (err) {
      logger.error('Error in createEarlyBirdCheckoutSession', err);
      return res.status(500).json({ error: 'Internal Server Error' });
    }
  }
);



// ====================================
// stripeWebhook (Stripe → Firestore)
// ====================================
exports.stripeWebhook = onRequest(
 {
  maxBodySize: '1mb',
  secrets: ['STRIPE_SECRET', 'STRIPE_WEBHOOK_SECRET', 'META_DATASET_ID', 'META_ACCESS_TOKEN', 'META_TEST_EVENT_CODE'],
},

  async (req, res) => {
    if (!stripe || !webhookSecret) {
      logger.error('Stripe or webhook secret not configured');
      return res.status(500).send('Stripe not configured');
    }

    const sig = req.headers['stripe-signature'];

    let event;

    try {
      // v2 onRequest gives us req.rawBody for signature verification
      event = stripe.webhooks.constructEvent(
        req.rawBody,
        sig,
        webhookSecret
      );
    } catch (err) {
      logger.error('⚠️  Webhook signature verification failed.', err);
      return res.status(400).send(`Webhook Error: ${err.message}`);
    }

    logger.info(`➡️ Stripe event received: ${event.type}`);

    try {
      switch (event.type) {
        case 'checkout.session.completed':
          await handleCheckoutSessionCompleted(event);
          break;
        case 'customer.subscription.created':
        case 'customer.subscription.updated':
          await handleSubscriptionUpdated(event);
          break;
        case 'customer.subscription.deleted':
          await handleSubscriptionDeleted(event);
          break;
        case 'invoice.payment_failed':
          await handleInvoicePaymentFailed(event);
          break;
        default:
          logger.info(`Unhandled event type: ${event.type}`);
      }

      res.status(200).send('OK');
    } catch (err) {
      logger.error('Error handling Stripe event', err);
      // For now, respond 200 so Stripe doesn’t spam retries; you can
      // tighten this once you’re confident in idempotency.
      res.status(200).send('OK (with internal error logged)');
    }
  }
);


// ====================================
// Stripe event handlers
// ====================================
// Meta Conversions API — server-side Purchase event
// ====================================
async function sendMetaPurchaseEvent(sessionId, email, uid, eventTime) {
  const datasetId = process.env.META_DATASET_ID;
  const accessToken = process.env.META_ACCESS_TOKEN;
  const testEventCode = process.env.META_TEST_EVENT_CODE;

  if (!datasetId || !accessToken) {
    logger.warn('⚠️ Meta CAPI skipped: META_DATASET_ID or META_ACCESS_TOKEN not set');
    return;
  }

  try {
    const crypto = require('crypto');
    function sha256(value) {
      return crypto.createHash('sha256').update(value).digest('hex');
    }

    const userData = {};
    if (email) {
      userData.em = sha256(email.toLowerCase().trim());
    }
    if (uid) {
      userData.external_id = sha256(uid);
    }

    const eventPayload = {
      event_name: 'Purchase',
      action_source: 'website',
      event_source_url: 'https://www.razorsedgept.com/goodlift-thank-you',
      event_id: sessionId,
      event_time: eventTime,
      custom_data: { currency: 'NZD', value: 1.00 },
      user_data: userData,
    };

    const body = { data: [eventPayload] };
    if (testEventCode) {
      body.test_event_code = testEventCode;
    }

    const url = `https://graph.facebook.com/v19.0/${datasetId}/events?access_token=${accessToken}`;

    const response = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });

    if (response.ok) {
      logger.info('✅ Meta CAPI Purchase sent', { sessionId, status: response.status });
    } else {
      const responseText = await response.text();
      logger.error('❌ Meta CAPI non-2xx response', { status: response.status, body: responseText });
    }
  } catch (err) {
    logger.error('❌ Meta CAPI fetch failed', err);
  }
}

// ====================================
async function handleCheckoutSessionCompleted(event) {
  const session = event.data.object;

  const customerId = session.customer;
  const subscriptionId = session.subscription;

  const uid = await resolveUidFromStripeCustomer(
    customerId,
    session.metadata
  );

  if (!uid) {
    logger.error(
      'No UID resolved for checkout.session.completed',
      customerId
    );
    return;
  }

  let subscription = null;
  if (subscriptionId) {
    subscription = await stripe.subscriptions.retrieve(subscriptionId);
  }

  const status = subscription ? subscription.status : 'active';
  const currentPeriodEnd = subscription
    ? new Date(subscription.current_period_end * 1000)
    : null;

  const membershipUpdate = {
    active: status === 'active' || status === 'trialing',
    status,
    stripeCustomerId: customerId,
    stripeSubscriptionId: subscriptionId || null,
  };

  if (currentPeriodEnd) {
    membershipUpdate.currentPeriodEnd =
      admin.firestore.Timestamp.fromDate(currentPeriodEnd);
  }

  await updateMembershipForUid(uid, membershipUpdate);

  // --- Meta CAPI server-side Purchase (non-fatal, deduplicated via session.id) ---
  const email =
    session.customer_details?.email ||
    session.customer_email ||
    null;

  try {
    await sendMetaPurchaseEvent(session.id, email, uid, event.created);
  } catch (capiErr) {
    logger.error('❌ Meta CAPI wrapper error (non-fatal)', capiErr);
  }
}

async function handleSubscriptionUpdated(event) {
  const subscription = event.data.object;

  const customerId = subscription.customer;
  const status = subscription.status;
  const subscriptionId = subscription.id;
  const currentPeriodEnd = new Date(subscription.current_period_end * 1000);

  const uid = await resolveUidFromStripeCustomer(
    customerId,
    subscription.metadata
  );

  if (!uid) {
    logger.error(
      'No UID resolved for customer.subscription.*',
      customerId
    );
    return;
  }

  const active = status === 'active' || status === 'trialing';

  const membershipUpdate = {
    active,
    status,
    stripeCustomerId: customerId,
    stripeSubscriptionId: subscriptionId,
    currentPeriodEnd: admin.firestore.Timestamp.fromDate(currentPeriodEnd),
  };

  await updateMembershipForUid(uid, membershipUpdate);
}

async function handleSubscriptionDeleted(event) {
  const subscription = event.data.object;
  const customerId = subscription.customer;
  const subscriptionId = subscription.id;

  const uid = await resolveUidFromStripeCustomer(
    customerId,
    subscription.metadata
  );

  if (!uid) {
    logger.error(
      'No UID resolved for customer.subscription.deleted',
      customerId
    );
    return;
  }

  const membershipUpdate = {
    active: false,
    status: 'canceled',
    stripeCustomerId: customerId,
    stripeSubscriptionId: subscriptionId,
  };

  await updateMembershipForUid(uid, membershipUpdate);
}

async function handleInvoicePaymentFailed(event) {
  const invoice = event.data.object;
  const subscriptionId = invoice.subscription;
  const customerId = invoice.customer;

  const uid = await resolveUidFromStripeCustomer(
    customerId,
    invoice.metadata
  );

  if (!uid) {
    logger.error(
      'No UID resolved for invoice.payment_failed',
      customerId
    );
    return;
  }

  await updateMembershipForUid(uid, {
    active: false,
    status: 'past_due',
    stripeCustomerId: customerId,
    stripeSubscriptionId: subscriptionId || null,
  });
}

// ====================================
// Coach bi-weekly check-ins
// ====================================
// Additive module: triggers, scheduler and callables for the coach
// Monday+Thursday athlete review system. Everything above is untouched.
const coachCheckins = require('./coach');
exports.coachAnalyticsOnWorkoutWrite = coachCheckins.coachAnalyticsOnWorkoutWrite;
exports.coachOnAthleteSettingsWritten = coachCheckins.coachOnAthleteSettingsWritten;
exports.coachOnAthleteAssignmentsWritten = coachCheckins.coachOnAthleteAssignmentsWritten;
exports.coachOnCoachAssignmentsWritten = coachCheckins.coachOnCoachAssignmentsWritten;
exports.coachCheckpointScheduler = coachCheckins.coachCheckpointScheduler;
exports.coachReviewContext = coachCheckins.coachReviewContext;
exports.coachPrepareCheckInCopy = coachCheckins.coachPrepareCheckInCopy;
exports.coachUndoCheckIn = coachCheckins.coachUndoCheckIn;
exports.coachSkipCheckIn = coachCheckins.coachSkipCheckIn;

// ── Coach Mode: onboarding, entitlements and coach⇄athlete relationships ────
// Required once per NEW callable in this project (Domain Restricted Sharing —
// see CALLABLE_OPTS in functions/coach/index.js and docs/coach_mode.md):
//   gcloud run services update <lowercased-function-name>
//     --no-invoker-iam-check --region=us-central1 --project=goodlift-us-storage
const coachMode = require('./coach/coach_mode');
exports.coachModeSubmitApplication = coachMode.coachModeSubmitApplication;
exports.coachModeWithdrawApplication = coachMode.coachModeWithdrawApplication;
exports.coachModeReviewApplication = coachMode.coachModeReviewApplication;
exports.coachModeGrantCoach = coachMode.coachModeGrantCoach;
exports.coachModeSetCoachState = coachMode.coachModeSetCoachState;
exports.coachModeAdminLookupAccount = coachMode.coachModeAdminLookupAccount;
exports.coachModeInviteAthlete = coachMode.coachModeInviteAthlete;
exports.coachModeCancelInvite = coachMode.coachModeCancelInvite;
exports.coachModeRespondToInvite = coachMode.coachModeRespondToInvite;
exports.coachModeRevokeCoach = coachMode.coachModeRevokeCoach;
exports.coachModeReleaseAthlete = coachMode.coachModeReleaseAthlete;
exports.coachModeRemoveSeededAthlete = coachMode.coachModeRemoveSeededAthlete;
exports.coachModeRemoveAthleteFromRoster = coachMode.coachModeRemoveAthleteFromRoster;
exports.coachOnCoachAthleteLinkWritten = coachMode.coachOnCoachAthleteLinkWritten;
exports.coachOnAccountEntitlementWritten = coachMode.coachOnAccountEntitlementWritten;

// ====================================
// Planned-blocks schema transition
// ====================================
// Temporary two-way compatibility mirror. It lets released app builds that
// still use /planned_blocks/{uid}/blocks/... coexist safely with the canonical
// /users/{uid}/planned_blocks/... hierarchy during rollout.
const plannedBlocksCompat = require('./planned_blocks_compat');
exports.mirrorLegacyPlannedBlocksToUsers =
  plannedBlocksCompat.mirrorLegacyPlannedBlocksToUsers;
exports.mirrorUserPlannedBlocksToLegacy =
  plannedBlocksCompat.mirrorUserPlannedBlocksToLegacy;
