# GoodLift — Website Launch Facts

**Purpose:** Minimum factual, code-verified information needed to launch the GoodLift website (privacy, support, subscription and account-deletion copy).
**Scope:** Read-only audit of the current Flutter app (`lib/`) and Cloud Functions (`functions/`). No files other than this one were created or modified.
**Date:** 2026-06-21 · **App version:** `1.1.1+40` (`pubspec.yaml`) · **Bundle/Package ID:** `com.goodlift.razorsedge` · **Firebase project:** `goodlift-us-storage`

> Method note: conclusions below reflect the active code. External web pages (privacy/support) were **not** fetched; values stored in the Apple App Store, Google Play, Stripe and Firebase consoles must be verified separately (see Section F).

---

## 1. Authentication

| Question | Finding | Reference |
|---|---|---|
| Sign-in methods active on **iOS** | **Email + password only.** Google button is hidden on iOS (`if (!Platform.isIOS)`); Apple Sign-In code exists but its UI is commented out ("removed for App Review compliance (Guideline 4.8)"). | `login_screen.dart` (`signInWithEmailAndPassword`, Google block ~L329, Apple block commented ~L342) |
| Sign-in methods active on **Android** | **Email + password** and **Google Sign-In.** | `login_screen.dart` (`signInWithGoogle`, Google button shown when `!Platform.isIOS`) |
| Account creation | Email + password, with profile fields (username, full name, DOB, sex) + onboarding. | `create_new_account_screen.dart` (`_register`, `OnboardingPageTwo`) |
| Anonymous Firebase Auth used internally? | **Yes.** A temporary anonymous sign-in is performed during signup to allow username/email availability checks before the real account exists. Anonymous users are treated as "not signed in" by the root router. | `create_new_account_screen.dart` `_ensureAnonAuthForAvailability()` → `signInAnonymously()` (~L168, called in `initState`); `main.dart` `_AppRootState` ignores `user.isAnonymous` |
| Same account on multiple devices / both platforms? | **Yes.** Identity is a single Firebase Auth user (UID); the email/password credential works on any device and either platform. Entitlement (`profile/membership`) and all data are keyed by UID, so they follow the account across devices. Google Sign-In is offered in the UI on Android only. | `main.dart` (`actorUid`), `membership_gate.dart` |

---

## 2. Data collected and stored (categories)

Primary store is **Cloud Firestore**, keyed by Firebase UID. Categories:

- **Account / profile:** email, display name, photo URL, provider IDs, created/last-login timestamps; username, full name, date of birth, sex. Public mirror in `users_public`. (`login_screen.dart` `_upsertUserDoc`, `create_new_account_screen.dart`)
- **Onboarding / training profile:** goals, body-focus targets, injuries + pain levels, training experience, equipment/environment, best-effort lifts, training days/effort. (`create_new_account_screen.dart` `OnboardingAnswers`)
- **Workout plans, planned blocks & templates:** `users/{uid}/planned_blocks/...`, templates. (`Block_Planner.dart`, `templates.dart`, `WES2_template_service.dart`)
- **Exercises & completed workouts:** per-set **weight, reps, RIR, velocity**, plus completion state. (`WES2_models.dart` — `Wes2FieldKey { weight, reps, rir, velocity }`)
- **Workout / training history:** `users/{uid}/workouts`, daily/monthly rollups `re_daily`, `re_monthly`. (`functions/index.js` `repointsMonthlyAggregator`)
- **Progression / calculated insights (RE Points):** per-lift bests, monthly totals, badges, feed posts. (`functions/index.js`; `progression_engine.dart`, `periodization_model_utils.dart`)
- **Body-weight tracking:** `users/{uid}/weights` (AM/PM entries). (`body_weight_tracker.dart`)
- **Subscription / membership status:** `users/{uid}/profile/membership` (active, status, source, product/subscription IDs, period end). (`membership_gate.dart`, `functions/index.js`)
- **Social / messaging:** feed `posts`, direct messages in `conversations/{id}/messages` with media in **Firebase Storage**. (`directMessages.dart`, `post_service.dart`)
- **Media:** profile photos, lift videos, post images in Firebase Storage. (`profile_page.dart`)
- **Local cached data (on device):** Isar local DB (block plans, snapshots) and SharedPreferences (cached block metadata, coach flag, login-state flags). (`local_cache/isar_*`, `user_context.dart`, `main.dart`)
- **Account-deletion audit:** `account_deletion_requests/{uid}` (uid, email, reason). (`account_deletion_screen.dart`)

---

## 3. Third-party services (active vs not)

| Service | Active? | Purpose | Disclose in Privacy Policy? |
|---|---|---|---|
| Firebase Authentication | ✅ | Sign-in / identity | Yes |
| Cloud Firestore | ✅ | Primary database | Yes |
| Firebase App Check | ✅ | API abuse protection (Play Integrity on Android, DeviceCheck on iOS) | Yes (security; DeviceCheck note) |
| Firebase Analytics | ❌ | Not in dependencies or code | — |
| Firebase Crashlytics | ❌ | Not in dependencies or code | — |
| Firebase Cloud Messaging | ❌ | Not in dependencies or code | — |
| Firebase Storage | ✅ | Profile photos, lift videos, message/post media | Yes |
| Firebase Realtime Database | ⚠️ Dependency only | `firebase_database` is declared in `pubspec.yaml` but **no active `FirebaseDatabase` usage found**; DMs use Firestore + Storage | No (verify before claiming) |
| Google Sign-In | ✅ (Android UI) | Google login | Yes |
| Meta / Facebook App Events | ✅ | App-event tracking (iOS) + server-side Meta Conversions API "Purchase" events | **Yes (advertising/attribution)** |
| Apple In-App Purchases | ✅ (iOS) | Membership subscription billing | Yes |
| Google Play Billing | ❌ in code | No native Play Billing integration; Android paywall opens website → Stripe | n/a now (see §5) |
| Stripe | ✅ | Subscription billing via website/Cloud Functions | Yes (payment processor) |
| RevenueCat | ❌ | Not used | — |
| Isar (local DB) | ✅ | Offline on-device storage | Yes (on-device storage) |

Also present: `cloud_functions`, `device_info_plus`, `package_info_plus`, `image_picker`, `video_player` (standard utility/diagnostic, minor).

---

## 4. Analytics, advertising and diagnostics

- **Firebase Analytics:** ❌ not present.
- **Crashlytics:** ❌ not present.
- **Meta / Facebook App Events:** ✅ — `FacebookAppEvents().activateApp()` on **iOS only** (`main.dart`), plus a **server-side Meta Conversions API Purchase event** (`functions/index.js` `sendMetaPurchaseEvent`, NZD value). This is advertising/attribution and **must be disclosed**.
- **Advertising identifiers / attribution:** the Meta SDK on iOS may access the advertising identifier (IDFA) → **App Tracking Transparency (ATT)** must be reviewed; App Check uses DeviceCheck. Verify in console / Info.plist (Section F).
- **Other diagnostic SDKs needing disclosure:** none significant beyond the above. App writes local auth "breadcrumb" diagnostics (`auth_debug.dart`).

---

## 5. Subscriptions

### iOS
- **Apple billing live:** ✅ via StoreKit / `in_app_purchase`. (`membership_gate.dart` `MembershipInactiveScreen`)
- **Product ID:** `goodlift.membership.monthly` (auto-renewable monthly). (`membership_gate.dart` `_initIAP`, `_onPurchaseUpdate`)
- **Restore purchases:** ✅ implemented (`InAppPurchase.instance.restorePurchases()`).
- **Membership status stored:** Firestore `users/{uid}/profile/membership` (`source: 'apple_iap'`, productId, purchaseId, active/status).
- **Server-side validation:** ❌ **None.** Activation is written **client-side** on a successful purchase; code carries an explicit TODO that production must validate the App Store receipt server-side. (`membership_gate.dart` `_onPurchaseUpdate`, ~L201)
- **Cancellation / expiry / refund / revocation:** ❌ no server handling for Apple (no App Store Server Notifications function). Once set, `active:true` is not automatically reverted for Apple subscriptions. (See Section E.)

### Android
- **Google Play Billing:** ❌ **not implemented in current code** (WIP). The Android paywall CTA opens the website with the UID/email attached for Stripe checkout. (`membership_gate.dart` `_openWebsiteWithUid`; IAP code is `if (Platform.isIOS)` only)
- **Product / base-plan identifiers:** none in app code. Billing is Stripe price IDs server-side (monthly + a $1 early-bird price) in `functions/index.js`. No Play base-plan IDs exist yet.
- **Purchase restoration:** n/a (no Play Billing).
- **Membership status stored:** same Firestore `profile/membership` doc, written by the **Stripe webhook**.
- **Server-side validation:** ✅ for Stripe — signed webhook handles `checkout.session.completed`, `customer.subscription.created/updated/deleted`, `invoice.payment_failed`, updating `active`/`status`/`currentPeriodEnd`. (`functions/index.js` `stripeWebhook`)

### Cross-platform
- Entitlement is a **single shared `profile/membership` doc keyed by UID**, read by `MembershipGate` on all platforms. So an active membership obtained on one platform unlocks the **same account** on the other.
- **An Apple purchase unlocking Android, or vice-versa:** at the entitlement-doc level this works for the same account, but there is **no cross-store reconciliation** and restore is platform-specific (Apple restore on iOS only; Stripe billing managed via website). **Treat full cross-store entitlement as UNRESOLVED** for public promises.

---

## 6. Account deletion

Flow: `account_deletion_screen.dart` (`_deleteAccount`). Reachable from **Settings** (`user_settings.dart`, appears on all platforms) and from the iOS paywall screen (`membership_gate.dart`, iOS-only entry there).

| Item | Status |
|---|---|
| Deletion available in-app | ✅ (Settings; plus iOS paywall) |
| Firebase Auth user deleted | ✅ `currentUser.delete()` |
| Main Firestore user doc deleted | ✅ `users/{uid}` and `users_public/{uid}` |
| Subcollections recursively deleted | ⚠️ **Partial.** Only `workouts`, `weights`, `re_cache`, `re_daily`, and top-level `planned_blocks` documents are deleted (one level). |
| Local Isar / cached data cleared | ❌ Not cleared by the deletion flow (user is signed out afterward) |
| Records that may remain | `re_monthly`; `profile/*` (incl. `membership`); `users/{uid}/planned_blocks/...` (deep nesting, TODO); `posts`; `conversations/{id}/messages` (parent conv doc deleted, messages subcollection not recursed); `account_deletion_requests/{uid}` (kept by design as audit) |
| User told deletion ≠ subscription cancellation | ❌ **No such warning** in the deletion screen |

**Deletion gaps to fix or disclose (see Section E):** residual data in several collections, no local-cache wipe, and no notice that deleting the account does not cancel the Apple/Google/Stripe subscription.

---

## 7. Existing-policy conflicts (material items only)

Live privacy/support pages were not fetched; the following are the **code-driven disclosures the pages must contain** — verify each is present and accurate:

- **Must be disclosed and may be missing:** Meta/Facebook (App Events + server-side Conversions API for ad attribution); Stripe as payment processor; Apple In-App Purchase; Firebase App Check / DeviceCheck; anonymous-auth usage during signup; on-device storage (Isar/SharedPreferences); direct messaging + media in Firebase Storage.
- **Do not over-claim:** if the privacy page lists Realtime Database, Analytics, Crashlytics, FCM, RevenueCat or Google Play Billing as in use, that is **inaccurate** for current code.
- **Support page should include:** how to delete an account, and that cancelling a subscription is done in Apple ID settings (iOS) or via the billing portal (web/Stripe) — separate from account deletion.
- **Paywall wording:** the in-app threshold (`paywallTriggered`; comments reference "fewer than 4 qualifying workout dates", while the headline says "You logged your first workout") is **inconsistent and may change** — do not turn the exact trigger into a permanent public promise.

---

## A. Confirmed facts safe for the website

- GoodLift is a strength-training app available on iOS and Android. ✅ (store listings for both exist)
- Users can plan workouts and create reusable templates. ✅
- Users can record exercises, sets, weight, repetitions and RIR (and velocity). ✅
- Users can review workout and training history. ✅
- GoodLift provides progression recommendations based on recorded training. ✅
- GoodLift uses accounts, subscriptions and in-app purchases. ✅
- GoodLift is built with Flutter. ✅
- **Hold / do not publish as live:** Online coaching at NZ$69/week (no code/product exists); any specific free-trial/paywall threshold; cross-store "buy once, use everywhere" entitlement; the exact NZ$29 figure until console-verified (below).

## B. Privacy Policy facts

Data stored (Firestore, keyed by UID): account/profile, onboarding/training profile, workouts (weight/reps/RIR/velocity), plans/templates, training history, RE-Points/progression insights, body weight, membership status, social posts, direct messages + media. Local on-device cache (Isar, SharedPreferences). Third parties to name: Firebase (Auth, Firestore, Storage, App Check/DeviceCheck), Google Sign-In, **Meta/Facebook (ad attribution)**, **Apple IAP**, **Stripe**. Anonymous auth is used transiently during signup. No Analytics/Crashlytics/FCM/RevenueCat.

## C. Subscription and cancellation facts

- iOS: auto-renewable monthly via Apple (`goodlift.membership.monthly`); cancel in Apple ID settings; restore available in-app.
- Web/Android: billed via Stripe through the website (no native Play Billing yet); managed via Stripe.
- Membership is per-account (Firebase UID) and shared across devices for the same login.
- Price NZ$29/month is the **intended** standard price — confirm the live amount in App Store Connect and Stripe before publishing it.

## D. Account-deletion facts

- Users can delete their account in-app (Settings). This deletes the Firebase login and the main profile, and signs the user out.
- Some training/history/social records and on-device cache may persist after deletion (cleanup is incomplete in code).
- **Deleting the account does NOT cancel an active Apple/Google/Stripe subscription** — the support/website copy must state this, and the in-app screen should too.

## E. Important issues to fix before launch

1. **No server-side Apple receipt validation** — iOS membership is activated client-side (spoofable). (`membership_gate.dart` ~L201)
2. **No Apple subscription lifecycle handling** — no App Store Server Notifications; `active:true` is never auto-revoked on Apple cancellation/expiry/refund. (Stripe path is handled.)
3. **Incomplete account deletion** — residual data in `re_monthly`, `profile/*` (incl. `membership`), nested `planned_blocks`, `posts`, conversation `messages`; local Isar/SharedPreferences not cleared. Fix (recursive Cloud Function) or disclose accurately.
4. **No "deletion ≠ cancellation" warning** in the deletion flow.
5. **Meta/ATT exposure** — confirm ATT prompt / IDFA handling and that the privacy page + App Store privacy labels cover Meta.
6. **Paywall messaging inconsistency** — headline vs. "4 workouts" trigger; keep website copy generic.

## F. Items requiring Apple / Google Play / Firebase / Stripe console verification

- App Store Connect: live price of `goodlift.membership.monthly` (confirm NZ$29), subscription status, and App Privacy labels (incl. Meta/tracking).
- Stripe dashboard: amount/currency of `MONTHLY_PRICE_ID` and the early-bird price; webhook endpoint live and secrets set (`STRIPE_SECRET`, `STRIPE_WEBHOOK_SECRET`).
- Google Play: whether Play Billing / a base plan is being configured (not in code); current billing route for Android users is the Stripe website.
- Firebase console: App Check enforcement (Play Integrity / DeviceCheck); whether Realtime Database is provisioned/used (code shows it unused).
- iOS project: ATT/`NSUserTrackingUsageDescription` and Meta SDK configuration.
