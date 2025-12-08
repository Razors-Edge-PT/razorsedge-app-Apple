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
const stripeSecret = process.env.STRIPE_SECRET || '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';
const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET || 'whsec_Ki7kQNYi73ipyEZPImu6BBDg08to5OF5';

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

// TODO: put your actual Stripe Price ID here (NZD $29/month)
const MONTHLY_PRICE_ID = 'price_1SKtWlBoDt989R6zJyzciOlF'; // <-- CHANGE THIS

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
  { cors: true },
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
          'https://your-site.com/success?session_id={CHECKOUT_SESSION_ID}',
        cancel_url:
          cancel_url || 'https://your-site.com/cancel',
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


// ====================================
// stripeWebhook (Stripe → Firestore)
// ====================================
exports.stripeWebhook = onRequest(
  {
    maxBodySize: '1mb',
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
