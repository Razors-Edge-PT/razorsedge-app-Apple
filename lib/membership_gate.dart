import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'auth_signout.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_debug.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

import 'login_screen.dart';   // only as a very defensive fallback
import 'account_deletion_screen.dart';
import 'app_check_ready.dart';
import 'startup_route_service.dart';
import 'startup_trace.dart';
import 'WES2_screen.dart';

/// Wraps [Wes2Screen] in a [MembershipGate] so EVERY route capable of showing
/// WES2 stays membership-governed (cold restore, named routes, and all in-app
/// pushes). Restored cold starts pass no [initialDate] → WES2 opens today.
Widget gatedWes2({DateTime? initialDate}) =>
    MembershipGate(child: Wes2Screen(initialDate: initialDate));

/// 🔐 UIDs that always have an "effective" active membership,
/// regardless of what Firestore says.
const freeMembershipUids = <String>{
  'yoVAqScwLMQLAgNHh8v9IK49fBw2', // Richard
  'wuiMe7phxYQh0MM39bfnhgv20yS2', // Campbell
  'SMTEVGPH1MXgOgbcBbJFU1HjU8G3', // Adam
  'ykx0RvDMc5OIuZ2R4kqWMhGbrGV2', // Google Play Reviewer Account
  'L7YjSMnm7tXD3BwyskmmrgVhKsS2' // Ruby cakes
  // add more testers here later
};

/// Ensure that /users/{uid}/profile/membership exists.
/// - If missing → create with active=false, status="inactive".
/// - If it already exists → do nothing (do NOT overwrite active=true).
Future<void> ensureMembershipDoc(String uid) async {
  try {
    // Sequence behind App Check activation (see app_check_ready.dart). Settles
    // even on failure/timeout, so this never deadlocks.
    await appCheckReady;
    print('🔎 ensureMembershipDoc: checking membership for uid=$uid');

    final membershipDocRef = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('profile')
        .doc('membership');

    final snap = await membershipDocRef.get();

    if (!snap.exists) {
      print('🆕 ensureMembershipDoc: creating membership doc for $uid');
      await membershipDocRef.set({
        'active': false,
        'status': 'inactive',
        'createdAt': FieldValue.serverTimestamp(),
      });
      print('✅ ensureMembershipDoc: created membership doc for $uid');
    } else {
      print('✅ ensureMembershipDoc: membership doc already exists for $uid');
    }
  } catch (e, st) {
    print('❌ ensureMembershipDoc ERROR for uid=$uid → $e');
    print(st);
  }
}



/// Wraps any screen that should only be visible to active members.
///
/// States are kept distinct so an error can never become a bypass:
///   • confirmed MISSING document → brand-new user → pass through (business
///     rule preserved),
///   • confirmed EXISTING document → evaluate active / paywallTriggered,
///   • stream / network / App Check ERROR → show a retryable verification
///     screen (NOT protected content, NOT the missing-doc pass-through).
///
/// [sessionAllowed] (in-memory, per-process, UID-keyed, NOT persisted) lets an
/// already-confirmed paying user reopen WES2 within the same session without a
/// fresh full-screen spinner. It is set ONLY from a confirmed live allowed
/// result, never from an error, and is cleared on logout / account deletion /
/// UID change. Even when fast-passing, the live stream is attached and will
/// demote to the paywall if membership actually changed.
class MembershipGate extends StatefulWidget {
  final Widget child;

  const MembershipGate({super.key, required this.child});

  /// UID confirmed allowed earlier in this process session (in-memory only).
  static String? _sessionAllowedUid;

  /// Clears the in-memory session-allow (logout / account deletion / UID change).
  static void clearSessionAllowed() => _sessionAllowedUid = null;

  @override
  State<MembershipGate> createState() => _MembershipGateState();
}

class _MembershipGateState extends State<MembershipGate> {
  User? _user;
  String? _uid;
  bool _isFree = false;
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _stream;

  @override
  void initState() {
    super.initState();
    _user = FirebaseAuth.instance.currentUser;
    _uid = _user?.uid;

    // A UID change invalidates any prior session-allow.
    if (MembershipGate._sessionAllowedUid != null &&
        MembershipGate._sessionAllowedUid != _uid) {
      MembershipGate.clearSessionAllowed();
    }

    _isFree = _uid != null && freeMembershipUids.contains(_uid);
    if (_uid != null && !_isFree) {
      _attachStream();
    }
  }

  /// Guarantees the membership doc exists and attaches the live stream — but
  /// only after App Check activation settles, so the read carries a token when
  /// enforcement is on. Safe to call again from the retry action.
  Future<void> _attachStream() async {
    final uid = _uid;
    if (uid == null) return;
    unawaited(ensureMembershipDoc(uid)); // awaits appCheckReady internally
    await appCheckReady;
    if (!mounted) return;
    setState(() {
      _stream = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('profile') // ← if you change the path, change here
          .doc('membership')
          .snapshots();
    });
  }

  Widget _loading() =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));

  /// Retryable membership-verification error — shown on stream/network/App
  /// Check failure. Never falls through to protected content.
  Widget _verificationError() {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 40, color: Theme.of(context).colorScheme.secondary),
              const SizedBox(height: 16),
              const Text(
                "We couldn't verify your membership",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                'Check your connection and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: () => _attachStream(),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;

    // Defensive: if auth state is transiently null here, return LoginScreen
    // directly — do NOT wrap in a new MaterialApp (would create a nested
    // Navigator that AppRoot cannot unwind).
    if (_user == null || uid == null) {
      debugPrint('[MEMBERSHIP] currentUser null — falling back to LoginScreen');
      unawaited(writeAuthBreadcrumb(
          'MEMBERSHIP currentUser null fallback to LoginScreen'));
      return const LoginScreen();
    }

    // 1) Free / comped users: always allowed in (no stream, no App Check wait).
    if (_isFree) {
      debugPrint('[MEMBERSHIP] free-membership uid — access granted');
      return widget.child;
    }

    final canFastPass = MembershipGate._sessionAllowedUid == uid;

    // Stream not attached yet (App Check still settling / first attach).
    if (_stream == null) {
      // Already confirmed allowed this session → show content immediately while
      // the live stream re-attaches (it will demote if membership changed).
      return canFastPass ? widget.child : _loading();
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        // ERROR: never pass through, never establish/retain allowed from it.
        if (snap.hasError) {
          debugPrint('[MEMBERSHIP] stream error: ${snap.error}');
          // If already confirmed allowed earlier this session, keep showing
          // content (the error is transient; allow was established from a prior
          // confirmed result, not from this error). Otherwise show retry.
          return canFastPass ? widget.child : _verificationError();
        }

        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return canFastPass ? widget.child : _loading();
        }

        // CONFIRMED missing document → brand-new user, no real set logged yet.
        if (!snap.hasData || !snap.data!.exists) {
          debugPrint('[MEMBERSHIP] confirmed no doc — new user, access granted');
          return widget.child;
        }

        // CONFIRMED existing document.
        final data = snap.data!.data() ?? {};
        final active = data['active'] == true;
        final inFreeTrial = data['paywallTriggered'] != true;

        if (active || inFreeTrial) {
          debugPrint('[MEMBERSHIP] '
              '${active ? "active" : "free-trial"} — access granted');
          // Set ONLY from a confirmed live allowed result.
          MembershipGate._sessionAllowedUid = uid;
          StartupTrace.membershipUiSelected('allowed');
          return widget.child;
        }

        // Confirmed inactive + paywallTriggered → demote; never retain allowed.
        debugPrint('[MEMBERSHIP] paywallTriggered=true inactive — showing paywall');
        MembershipGate.clearSessionAllowed();
        StartupTrace.membershipUiSelected('paywall');
        return const MembershipInactiveScreen();
      },
    );
  }
}

/// Screen shown when the user is logged in but their membership is inactive.
class MembershipInactiveScreen extends StatefulWidget {
  const MembershipInactiveScreen({super.key});

  @override
  State<MembershipInactiveScreen> createState() =>
      _MembershipInactiveScreenState();
}

class _MembershipInactiveScreenState extends State<MembershipInactiveScreen> {
  // 🔗 HTTPS Function URL for createCheckoutSession (used by _startCheckout)
  static const String _checkoutFunctionUrl =
      'https://createcheckoutsession-eot2loyyrq-uc.a.run.app';

  /// App Store product ID (auto-renewable subscription).
  static const String _iosProductId = 'goodlift.membership.monthly';

  /// Google Play product ID (subscription). This is the *product* ID, not the
  /// base plan ID (`monthly-basic`) — Play Billing queries by product ID and
  /// resolves the base plan/offer via the returned offer token.
  static const String _androidProductId = 'goodlift_monthly';

  /// Both store IDs — a purchase update is ours if it matches either.
  static const Set<String> _membershipProductIds = {
    _iosProductId,
    _androidProductId,
  };

  /// True on the two platforms that have a native store we can purchase from.
  static bool get _iapSupported => Platform.isIOS || Platform.isAndroid;

  /// Product ID to query/purchase on the current platform.
  static String get _storeProductId =>
      Platform.isAndroid ? _androidProductId : _iosProductId;

  // IAP state — iOS + Android; fields are never set on desktop.
  ProductDetails? _productDetails;
  bool _iapAvailable = false;
  bool _iapLoading = false;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;

  @override
  void initState() {
    super.initState();
    if (_iapSupported) {
      _iapLoading = true; // disable button from first frame until query completes
      _initIAP();
    }
  }

  @override
  void dispose() {
    _purchaseSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initIAP() async {
    final platform = Platform.isAndroid ? 'android' : 'ios';
    final productId = _storeProductId;
    debugPrint('[IAP] init platform=$platform');

    try {
      // Attach before any await so no store events are missed during setup.
      _purchaseSubscription =
          InAppPurchase.instance.purchaseStream.listen(_onPurchaseUpdate);

      _iapAvailable = await InAppPurchase.instance.isAvailable();
      debugPrint('[IAP] available=$_iapAvailable');
      if (!_iapAvailable || !mounted) return;

      debugPrint('[IAP] querying productId=$productId');
      final response =
          await InAppPurchase.instance.queryProductDetails({productId});

      if (response.notFoundIDs.isNotEmpty) {
        debugPrint('[IAP] notFoundIDs=${response.notFoundIDs}');
      }
      if (response.error != null) {
        debugPrint('[IAP] query error=${response.error}');
      }

      // On Android a subscription returns one ProductDetails per base
      // plan/offer, all sharing the same product ID; the first carries the
      // offer token that buyNonConsumable needs. On iOS there is exactly one.
      for (final p in response.productDetails) {
        debugPrint('[IAP] product found id=${p.id} price=${p.price}');
      }

      if (response.productDetails.isNotEmpty && mounted) {
        setState(() => _productDetails = response.productDetails.first);
      }
    } finally {
      if (mounted) setState(() => _iapLoading = false);
    }
  }

  Future<void> _onPurchaseUpdate(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (!_membershipProductIds.contains(purchase.productID)) continue;

      debugPrint('[IAP] purchase update productId=${purchase.productID} '
          'status=${purchase.status} '
          'pendingCompletePurchase=${purchase.pendingCompletePurchase}');

      if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        // TODO: Production must validate the App Store / Play Billing receipt
        // server-side via a Cloud Function before fully trusting this
        // client-side membership activation.
        final uid = FirebaseAuth.instance.currentUser?.uid;
        try {
          if (uid != null) {
            await FirebaseFirestore.instance
                .collection('users')
                .doc(uid)
                .collection('profile')
                .doc('membership')
                .set({
              'active': true,
              'status': 'active',
              'source':
                  Platform.isAndroid ? 'google_play_billing' : 'apple_iap',
              'productId': purchase.productID,
              'purchaseId': purchase.purchaseID,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            debugPrint('[IAP] membership write succeeded');
          }
        } catch (e) {
          debugPrint('[IAP] membership write failed: $e');
        } finally {
          // Always acknowledge. StoreKit and Play Billing both auto-refund a
          // purchase that is never completed/acknowledged — so this must run
          // even when the Firestore write above failed.
          if (purchase.pendingCompletePurchase) {
            await InAppPurchase.instance.completePurchase(purchase);
            debugPrint('[IAP] completePurchase called');
          } else {
            debugPrint('[IAP] completePurchase not needed');
          }
        }
        if (mounted) {
          setState(() => _iapLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Membership activated.')),
          );
        }
      } else if (purchase.status == PurchaseStatus.pending) {
        // Play Billing can park a purchase here for days (e.g. cash/voucher
        // payment). Release the CTA so it is never permanently disabled, and
        // do NOT activate membership — activation only happens on
        // purchased/restored above.
        if (mounted) {
          setState(() => _iapLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Waiting for payment confirmation…')),
          );
        }
      } else if (purchase.status == PurchaseStatus.error) {
        debugPrint('[IAP] purchase error=${purchase.error}');
        if (mounted) {
          setState(() => _iapLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Purchase failed. Please try again.')),
          );
        }
      } else if (purchase.status == PurchaseStatus.canceled) {
        if (mounted) {
          setState(() => _iapLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Purchase cancelled.')),
          );
        }
      }
    }
  }

  /// Launches the native store purchase sheet for the current platform.
  ///
  /// iOS  → StoreKit sheet for [_iosProductId].
  /// Android → Google Play Billing sheet for [_androidProductId].
  ///
  /// No browser, no Stripe, no intermediate confirmation screen: the only step
  /// after this is the store's own payment/auth UI.
  Future<void> _startMembershipPurchase(BuildContext context) async {
    if (!_iapAvailable || _productDetails == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Membership purchase is currently unavailable. Please try again shortly.'),
        ),
      );
      return;
    }
    setState(() => _iapLoading = true);
    try {
      // A subscription is bought with buyNonConsumable on both platforms. On
      // Android the ProductDetails returned by queryProductDetails is a
      // GooglePlayProductDetails, and the plugin reads its offer token off it —
      // so the plain PurchaseParam is correct for our backwards-compatible
      // `monthly-basic` base plan; no GooglePlayPurchaseParam is needed.
      final purchaseParam = PurchaseParam(productDetails: _productDetails!);
      await InAppPurchase.instance
          .buyNonConsumable(purchaseParam: purchaseParam);
      // Result arrives via purchaseStream → _onPurchaseUpdate.
    } catch (e) {
      // buyNonConsumable threw synchronously (e.g. already in a purchase flow).
      debugPrint('[IAP] buyNonConsumable threw: $e');
      if (mounted) setState(() => _iapLoading = false);
    }
  }

  /// Opens the website with the current Firebase uid/email attached,
  /// so the landing page can start Stripe Checkout for this user.
  Future<void> _openWebsiteWithUid() async {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid;
    final email = user?.email;

    const baseUrl = 'https://www.razorsedgept.com/goodlift-membership';

    Uri uri;
    if (uid == null) {
      uri = Uri.parse(baseUrl);
    } else {
      uri = Uri.parse(baseUrl).replace(queryParameters: {
        'uid': uid,
        if (email != null && email.isNotEmpty) 'email': email,
      });
    }

    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _logout(BuildContext context) async {
    debugPrint('[AUTHLOGOUT] MembershipInactiveScreen logout');
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('goodlift_explicit_logout', true);
    await writeAuthBreadcrumb('AUTHLOGOUT membershipInactive uid=$uid');
    // Clear the restored-route marker + in-memory session-allow for this UID.
    if (uid != null) await StartupRouteService.clearForLogout(uid);
    MembershipGate.clearSessionAllowed();
    await performSignOut(
      reason: SignOutReason.explicitLogoutPaywall,
      caller: 'MembershipInactiveScreen.logout',
    );
    Navigator.pushReplacementNamed(context, '/login');
  }

  Future<void> _startCheckout(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You must be logged in to subscribe.')),
      );
      return;
    }

    final uid = user.uid;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Opening Stripe checkout…')),
    );

    try {
      final uri = Uri.parse(_checkoutFunctionUrl);

      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{
          'uid': uid,
          // Optional: you can override these later if you build a hosted success page.
          // 'success_url': 'https://your-site.com/success',
          // 'cancel_url': 'https://your-site.com/cancel',
        }),
      );
      debugPrint("STATUS: ${response.statusCode}");
      debugPrint("BODY: ${response.body}");

      if (response.statusCode != 200) {
        debugPrint(
          'createCheckoutSession failed: ${response.statusCode} ${response.body}',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error starting checkout (${response.statusCode}). Please try again.',
            ),
          ),
        );
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final url = data['url'] as String?;

      if (url == null || url.isEmpty) {
        debugPrint('createCheckoutSession returned no URL: ${response.body}');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No checkout URL returned. Please try again later.'),
          ),
        );
        return;
      }

      final checkoutUri = Uri.parse(url);
      final launched = await launchUrl(
        checkoutUri,
        mode: LaunchMode.externalApplication,
      );

      if (!launched) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open Stripe checkout.'),
          ),
        );
      }
    } catch (e, st) {
      debugPrint('Error in _startCheckout: $e');
      debugPrint(st.toString());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unexpected error starting checkout.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // GoodLift branding
                  Image.asset(
                    'assets/InApp/transparent_good_lift_logo_inApp.png',
                    height: 90,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 22),

                  // Premium card
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.4),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.15),
                          blurRadius: 24,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Headline
                        const Text(
                          'You logged your first workout. Now unlock GoodLift.',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        // Subheadline
                        Text(
                          'GoodLift uses your workouts, rep targets, RIR and '
                          'training history to guide what to do next.',
                          style: TextStyle(
                            fontSize: 15,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.7),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        // Value bullets
                        ..._buildBullets(),
                        const SizedBox(height: 24),
                        // Price line — store-localised price, shown on iOS and
                        // Android once the store product has loaded.
                        if (_productDetails != null) ...[
                          Text(
                            '${_productDetails!.price} / month',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                        ],
                        // Primary CTA
                        // iOS → StoreKit sheet, Android → Google Play sheet.
                        // Unsupported platforms (desktop) fall back to the web
                        // page; _startCheckout is kept for non-IAP dev testing.
                        _AnimatedMembershipCta(
                          onPressed: _iapLoading
                              ? null
                              : _iapSupported
                                  ? () => _startMembershipPurchase(context)
                                  : _openWebsiteWithUid,
                          showLoadingSpinner: _iapLoading,
                        ),
                        const SizedBox(height: 12),
                        // Trust copy
                        Text(
                          'Cancel anytime. Your training data stays saved.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.55),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),

                  // Restore — both stores support it (StoreKit / Play queryPurchases);
                  // restored purchases arrive via purchaseStream.
                  if (_iapSupported) ...[
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _iapLoading
                          ? null
                          : () => InAppPurchase.instance.restorePurchases(),
                      child: const Text('Restore purchases'),
                    ),
                  ],

                  // iOS-only: Apple legal disclosure + links
                  if (Platform.isIOS) ...[
                    const SizedBox(height: 16),
                    // Apple subscription legal disclosure (required by App Store guidelines)
                    const Text(
                      'GoodLift Membership is an auto-renewable monthly subscription. '
                      'Your subscription provides access to all training features during each billing period. '
                      'Payment will be charged to your Apple ID at confirmation of purchase. '
                      'The subscription automatically renews unless cancelled at least 24 hours before the end of the current period. '
                      'You can manage or cancel your subscription in your Apple ID account settings.',
                      style: TextStyle(fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () async {
                        final uri = Uri.parse(
                            'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/');
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      },
                      child: const Text(
                        'Terms of Use',
                        style: TextStyle(
                          color: Colors.blue,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () async {
                        final uri = Uri.parse(
                            'https://www.razorsedgept.com/goodlift-privacy');
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      },
                      child: const Text(
                        'Privacy Policy',
                        style: TextStyle(
                          color: Colors.blue,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),

                  // Footer: logout always visible; delete account iOS only
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: () => _logout(context),
                        icon: const Icon(Icons.logout, size: 20),
                        label: const Text('Log out'),
                      ),
                      if (Platform.isIOS) ...[
                        const SizedBox(width: 16),
                        TextButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const AccountDeletionScreen()),
                          ),
                          icon: const Icon(Icons.delete_forever,
                              size: 16, color: Colors.redAccent),
                          label: const Text(
                            'Delete Account',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildBullets() {
    const bullets = [
      'Know what to lift next',
      'Keep your workouts structured',
      'Track reps, weight, RIR and progress',
      'Built for lifters who want measurable progression',
    ];
    return bullets
        .map(
          (text) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.check_circle_outline,
                    size: 18, color: Colors.greenAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
        )
        .toList();
  }
}

/// Animated wrapper for the primary membership CTA.
/// Applies a subtle scale bump every 1.5 s and a slow glow pulse over 3 s.
/// Scale bump is suppressed while the button is disabled or loading.
class _AnimatedMembershipCta extends StatefulWidget {
  final VoidCallback? onPressed;
  final bool showLoadingSpinner;

  const _AnimatedMembershipCta({
    required this.onPressed,
    required this.showLoadingSpinner,
  });

  @override
  State<_AnimatedMembershipCta> createState() => _AnimatedMembershipCtaState();
}

class _AnimatedMembershipCtaState extends State<_AnimatedMembershipCta>
    with TickerProviderStateMixin {
  late final AnimationController _scaleController;
  late final AnimationController _glowController;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();

    // Scale bump: 1500 ms total period (250 ms rise + 250 ms fall + 1000 ms pause).
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    _scaleAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.025)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 250,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.025, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 250,
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 1000,
      ),
    ]).animate(_scaleController);

    // Glow pulse: 3 s ping-pong between dim primary and soft secondary.
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _scaleController.dispose();
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final secondaryColor = Theme.of(context).colorScheme.secondary;

    return AnimatedBuilder(
      animation: Listenable.merge([_scaleController, _glowController]),
      builder: (context, child) {
        // Scale bump: held at 1.0 while disabled to avoid bouncing during load.
        final scale = widget.onPressed != null ? _scaleAnim.value : 1.0;

        // Glow: slow lerp between dim primary and soft secondary.
        final glowT = _glowController.value;
        final glowColor = Color.lerp(
          primaryColor.withValues(alpha: 0.22),
          secondaryColor.withValues(alpha: 0.40),
          glowT,
        )!;

        return Transform.scale(
          scale: scale,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: glowColor,
                  blurRadius: 12.0 + glowT * 8.0,
                  spreadRadius: glowT * 2.0,
                ),
              ],
            ),
            child: child,
          ),
        );
      },
      // child is static — only builder rebuilds on each animation tick.
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: widget.onPressed,
          child: widget.showLoadingSpinner
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Start GoodLift Membership'),
        ),
      ),
    );
  }
}

