import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'startup_route_service.dart';
import 'membership_gate.dart';
import 'auth_signout.dart';

class AccountDeletionScreen extends StatefulWidget {
  const AccountDeletionScreen({super.key});

  @override
  State<AccountDeletionScreen> createState() => _AccountDeletionScreenState();
}

class _AccountDeletionScreenState extends State<AccountDeletionScreen> {
  bool? _q1; // null = unanswered
  bool? _q2;
  final _reasonCtrl = TextEditingController();
  String? _reasonError;
  bool _deleting = false;
  String? _error;

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  bool get _canDelete =>
      _q1 == true && _q2 == true && _reasonCtrl.text.trim().length >= 4;

  void _onReasonChanged(String _) {
    setState(() {
      _reasonError = _reasonCtrl.text.trim().length < 4
          ? 'Please enter at least 4 characters.'
          : null;
    });
  }

  Future<void> _deleteAccount() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      setState(() => _error =
          'Could not find your account. Please log out and try again.');
      return;
    }

    final uid = currentUser.uid;
    final email = currentUser.email ?? '';
    final reason = _reasonCtrl.text.trim();
    final db = FirebaseFirestore.instance;

    setState(() {
      _deleting = true;
      _error = null;
    });

    try {
      // Write audit record before any deletion — best-effort, does not block if it fails.
      try {
        await db.collection('account_deletion_requests').doc(uid).set({
          'uid': uid,
          'email': email,
          'reason': reason,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (_) {}

      // Delete known direct subcollections under users/{uid}.
      // TODO (Cloud Function follow-up): recursive deletion of any deeper nesting
      // not covered here (e.g. sub-docs within re_daily entries).
      for (final sub in [
        'workouts',
        'weights',
        're_cache',
        're_daily',
        'planned_blocks',
      ]) {
        try {
          final snap =
              await db.collection('users').doc(uid).collection(sub).get();
          for (final doc in snap.docs) {
            await doc.reference.delete();
          }
        } catch (_) {
          // Best-effort: continue even if a subcollection is unreachable.
        }
      }

      await db.collection('users').doc(uid).delete();
      await db.collection('users_public').doc(uid).delete();

      // TODO (Cloud Function follow-up): nested documents below
      // users/{uid}/planned_blocks/{blockId} still require recursive deletion.

      // Delete conversation docs where this user is a participant.

      // conversation doc require server-side recursive deletion.
      try {
        final convSnap = await db
            .collection('conversations')
            .where('participants.$uid', isEqualTo: true)
            .get();
        for (final doc in convSnap.docs) {
          await doc.reference.delete();
        }
      } catch (_) {}

      // Clear the restored-route marker + in-memory session-allow for this UID
      // before tearing down auth.
      await StartupRouteService.clearForLogout(uid);
      MembershipGate.clearSessionAllowed();

      await FirebaseAuth.instance.currentUser?.delete();
      await performSignOut(
        reason: SignOutReason.accountDeletion,
        caller: 'AccountDeletionScreen',
        google: false, // parity with prior behaviour (Firebase-only)
      );

      if (mounted) {
        Navigator.pushReplacementNamed(context, '/login');
      }
    } on FirebaseAuthException catch (e) {
      setState(() {
        _deleting = false;
        _error = e.code == 'requires-recent-login'
            ? 'For security, please log out and log back in, then try deleting your account again.'
            : 'Deletion failed. Please try again or contact support.';
      });
    } catch (_) {
      setState(() {
        _deleting = false;
        _error = 'Deletion failed. Please try again or contact support.';
      });
    }
  }

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Permanently delete account?'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This cannot be undone.'),
            SizedBox(height: 16),
            Text(
              'Deleting your GoodLift account does not cancel an active subscription. '
              'Cancel your subscription separately through Apple or your billing provider.',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete Account'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _deleteAccount();
    }
  }

  Widget _yesNoRow({
    required String question,
    required bool? value,
    required ValueChanged<bool> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(question, style: const TextStyle(fontSize: 15)),
        const SizedBox(height: 4),
        Row(
          children: [
            Radio<bool>(
              value: true,
              groupValue: value,
              onChanged: (v) => onChanged(v!),
            ),
            const Text('Yes'),
            const SizedBox(width: 24),
            Radio<bool>(
              value: false,
              groupValue: value,
              onChanged: (v) => onChanged(v!),
            ),
            const Text('No'),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bothYes = _q1 == true && _q2 == true;

    return Scaffold(
      appBar: AppBar(title: const Text('Account Deletion')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.7),
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.orange,
                      size: 22,
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Deleting your GoodLift account does not cancel an active subscription. '
                        'Cancel your subscription separately through Apple or your billing provider.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.35,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _yesNoRow(
                question: 'I want to delete my account permanently.',
                value: _q1,
                onChanged: (v) => setState(() => _q1 = v),
              ),
              const SizedBox(height: 24),
              _yesNoRow(
                question:
                    'I understand my account will be permanently deleted, and I will have to create a new account from scratch if I want to use the app again.',
                value: _q2,
                onChanged: (v) => setState(() => _q2 = v),
              ),
              if (bothYes) ...[
                const SizedBox(height: 24),
                TextField(
                  controller: _reasonCtrl,
                  onChanged: _onReasonChanged,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: 'Reason for deleting',
                    errorText: _reasonError,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed:
                    (_canDelete && !_deleting) ? _confirmAndDelete : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.red.withValues(alpha: 0.3),
                ),
                child: _deleting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Delete Account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
