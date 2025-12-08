import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'login_screen.dart';   // only as a very defensive fallback

/// 🔐 UIDs that always have an "effective" active membership,
/// regardless of what Firestore says.
const freeMembershipUids = <String>{
  'yoVAqScwLMQLAgNHh8v9IK49fBw2', // Richard
  'wuiMe7phxYQh0MM39bfnhgv20yS2', // Campbell
  'SMTEVGPH1MXgOgbcBbJFU1HjU8G3', // Adam
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
class MembershipInactiveScreen extends StatelessWidget {
  const MembershipInactiveScreen({super.key});

  static const String _websiteUrl = 'https://www.razorsedgept.com/goodlift-membership';

  Future<void> _openWebsite() async {
    final uri = Uri.parse(_websiteUrl);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _logout(BuildContext context) async {
    await FirebaseAuth.instance.signOut();

    // Ensures app returns to login screen cleanly.
    Navigator.pushReplacementNamed(context, '/login');
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
                      'please visit our website.',
                  style: TextStyle(fontSize: 15),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),

                // 🔵 Learn More → Website button
                ElevatedButton(
                  onPressed: _openWebsite,
                  child: const Text('Learn more'),
                ),

                const SizedBox(height: 20),

                // 🔴 Logout button so user isn't trapped on this screen
                ElevatedButton.icon(
                  onPressed: () => _logout(context),
                  icon: const Icon(Icons.logout, color: Colors.white),
                  label: const Text('Log out'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey.shade700,   // same as Learn More
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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

