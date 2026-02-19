import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

import 'login_screen.dart';   // only as a very defensive fallback

/// 🔐 UIDs that always have an "effective" active membership,
/// regardless of what Firestore says.
const freeMembershipUids = <String>{
  'yoVAqScwLMQLAgNHh8v9IK49fBw2', // Richard
  'wuiMe7phxYQh0MM39bfnhgv20yS2', // Campbell
  'SMTEVGPH1MXgOgbcBbJFU1HjU8G3', // Adam
  'ykx0RvDMc5OIuZ2R4kqWMhGbrGV2' // Google Play Reviewer Account
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
/// Screen shown when the user is logged in but their membership is inactive.
class MembershipInactiveScreen extends StatelessWidget {
  const MembershipInactiveScreen({super.key});

  // 🔗 Your marketing page (still used for "Learn more")
  static const String _websiteUrl =
      'https://www.razorsedgept.com/goodlift-membership';

  // 🔗 HTTPS Function URL for createCheckoutSession (used by _startCheckout)
  static const String _checkoutFunctionUrl =
      'https://createcheckoutsession-eot2loyyrq-uc.a.run.app';

  /// Open the website *with the current Firebase uid/email attached*,
  /// so the landing page can start Stripe Checkout for this user.
  Future<void> _openWebsiteWithUid() async {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid;
    final email = user?.email;

    // Base URL for your Wix membership landing page
    const baseUrl = 'https://www.razorsedgept.com/goodlift-membership';

    Uri uri;

    if (uid == null) {
      // If somehow no user is logged in, just open the landing page without params.
      uri = Uri.parse(baseUrl);
    } else {
      // Append uid (and email if available)
      uri = Uri.parse(baseUrl).replace(queryParameters: {
        'uid': uid,
        if (email != null && email.isNotEmpty) 'email': email,
      });
    }

    await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
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
      body: Padding(
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

                // ✅ Activate membership → Stripe Checkout
               /* ElevatedButton(
                  onPressed: () => _startCheckout(context),  // keep for now (dev / v1.1)
                  child: const Text('Activate membership'),
                ), */

                const SizedBox(height: 16),

                ElevatedButton(
                    onPressed: _openWebsiteWithUid,  // keep for now (dev / v1.1)
                  child: const Text('Activate membership'),
                ),


                const SizedBox(height: 20),

                // 🔴 Logout button so user isn't trapped on this screen
                ElevatedButton.icon(
                  onPressed: () => _logout(context),
                  icon: const Icon(Icons.logout, color: Colors.white),
                  label: const Text('Log out'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey.shade700,
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
            ),
          ),
        ),
      ),
    );
  }
}

