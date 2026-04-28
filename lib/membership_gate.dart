import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

import 'login_screen.dart';   // only as a very defensive fallback
import 'account_deletion_screen.dart';

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
class MembershipGate extends StatelessWidget {
  final Widget child;

  const MembershipGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    // If somehow we have no logged-in user here, punt back to login.
    if (user == null) {
      return const MaterialApp(home: LoginScreen());
    }

    final uid = user.uid;
    ensureMembershipDoc(uid); // 🔧 guarantee /profile/membership exists for brand-new users

    // 1) Free / comped users: always allowed in.
    if (freeMembershipUids.contains(uid)) {
      return child;
    }

    // 2) Everyone else: listen to membership doc.
    final membershipDocRef = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('profile')      // ← if you change the path, change here
        .doc('membership');

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: membershipDocRef.snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (!snap.hasData || !snap.data!.exists) {
          // No membership doc yet → treat as inactive.
          return const MembershipInactiveScreen();
        }

        final data = snap.data!.data() ?? {};
        final bool isActive = data['active'] == true;

        if (isActive) {
          return child;
        } else {
          return const MembershipInactiveScreen();
        }
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

  // IAP state — iOS only; fields are never set on Android.
  ProductDetails? _productDetails;
  bool _iapAvailable = false;
  bool _iapLoading = false;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;

  @override
  void initState() {
    super.initState();
    if (Platform.isIOS) {
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
    try {
      // Attach before any await so no StoreKit events are missed during setup.
      _purchaseSubscription =
          InAppPurchase.instance.purchaseStream.listen(_onPurchaseUpdate);

      _iapAvailable = await InAppPurchase.instance.isAvailable();
      if (!_iapAvailable || !mounted) return;

      final response = await InAppPurchase.instance
          .queryProductDetails({'goodlift.membership.monthly'});

      if (response.notFoundIDs.isNotEmpty) {
        debugPrint(
            '[IAP] Product not found in App Store: ${response.notFoundIDs}');
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
      if (purchase.productID != 'goodlift.membership.monthly') continue;

      if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        // TODO: Production must validate the App Store receipt server-side via a
        // Cloud Function before fully trusting this client-side membership activation.
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
              'source': 'apple_iap',
              'productId': purchase.productID,
              'purchaseId': purchase.purchaseID,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          }
        } catch (e) {
          debugPrint('[IAP] Firestore membership write failed: $e');
        } finally {
          // Always acknowledge — StoreKit will refund if not completed,
          // even when the Firestore write above failed.
          if (purchase.pendingCompletePurchase) {
            await InAppPurchase.instance.completePurchase(purchase);
          }
        }
        if (mounted) {
          setState(() => _iapLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Membership activated.')),
          );
        }
      } else if (purchase.status == PurchaseStatus.error) {
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
      // PurchaseStatus.pending: StoreKit handles natively; _iapLoading stays true.
    }
  }

  Future<void> _startApplePurchase(BuildContext context) async {
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
      final purchaseParam = PurchaseParam(productDetails: _productDetails!);
      await InAppPurchase.instance
          .buyNonConsumable(purchaseParam: purchaseParam);
      // Result arrives via purchaseStream → _onPurchaseUpdate.
    } catch (_) {
      // buyNonConsumable threw synchronously (e.g. already in a purchase flow).
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
    await FirebaseAuth.instance.signOut();

    // Ensures app returns to login screen cleanly.
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
      appBar: AppBar(
        title: const Text('GOODLIFT'),
        centerTitle: true,
        automaticallyImplyLeading: false, // no back button trap
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 64),
                const SizedBox(height: 16),
                const Text(
                  'Membership required',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Your GOODLIFT membership is inactive.\n\n'
                      'To activate your account and unlock your training plan, '
                      'tap the button below to start your subscription.',
                  style: TextStyle(fontSize: 15),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),

                // iOS  → Apple IAP via StoreKit
                // else → existing website / Stripe flow
                /* _startCheckout kept as fallback for non-IAP testing (dev / v1.1) */
                ElevatedButton(
                  onPressed: _iapLoading
                      ? null
                      : Platform.isIOS
                          ? () => _startApplePurchase(context)
                          : _openWebsiteWithUid,
                  child: _iapLoading && Platform.isIOS
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Activate membership'),
                ),

                if (Platform.isIOS) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'GoodLift Membership — \$29 per month, includes full access to GoodLift training.',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
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
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _iapLoading
                        ? null
                        : () => _startApplePurchase(context),
                    child: _iapLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Activate membership'),
                  ),
                ],

                if (Platform.isIOS) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _iapLoading
                        ? null
                        : () => InAppPurchase.instance.restorePurchases(),
                    child: const Text('Restore purchases'),
                  ),
                ],

                const SizedBox(height: 20),

                // 🔴 Logout button so user isn't trapped on this screen
                ElevatedButton.icon(
                  onPressed: () => _logout(context),
                  icon: const Icon(Icons.logout, color: Colors.white),
                  label: const Text('Log out'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),

                if (Platform.isIOS) ...[
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AccountDeletionScreen()),
                    ),
                    icon: const Icon(Icons.delete_forever, color: Colors.white),
                    label: const Text('Delete Account'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }
}

