/// Settings → Notifications.
///
/// Three category switches — Friend requests, Friend request accepted, Direct
/// messages — plus "Show message previews" (off by default; when off the
/// server leaves message text out of the notification entirely).
///
/// The switches belong to the SIGNED-IN account (`pushPreferences/{uid}`,
/// FirebaseAuth uid — never a coach's selected athlete) and follow it across
/// devices. Whether THIS phone may show notifications at all is the OS
/// permission, shown above them: the app asks only when the person chooses
/// to, and after a denial offers the system settings instead of asking again.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'push_intent.dart';
import 'push_notification_service.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({
    super.key,
    this.service,
    this.firestore,
    this.uid,
  });

  /// Injectable for tests.
  final PushNotificationService? service;
  final FirebaseFirestore? firestore;
  final String? uid;

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen>
    with WidgetsBindingObserver {
  late final PushNotificationService _service;
  late final FirebaseFirestore _db;
  late final String? _uid;
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _prefsStream;

  PushPermission? _permission;

  /// Values written on this visit, shown until the snapshot confirms them.
  final Map<String, bool> _optimistic = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? PushNotificationService.instance;
    _db = widget.firestore ?? FirebaseFirestore.instance;
    _uid = widget.uid ?? FirebaseAuth.instance.currentUser?.uid;
    if (_uid != null) {
      _prefsStream = _db.collection('pushPreferences').doc(_uid).snapshots();
    }
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadPermission());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system settings: show what the person chose there.
    if (state == AppLifecycleState.resumed) unawaited(_loadPermission());
  }

  Future<void> _loadPermission() async {
    final PushPermission p = await _service.permissionStatus();
    if (mounted) setState(() => _permission = p);
  }

  Future<void> _turnOn() async {
    final PushPermission p = await _service.requestPermission();
    if (mounted) setState(() => _permission = p);
  }

  Future<void> _set(String field, bool value) async {
    final String? uid = _uid;
    if (uid == null) return;
    setState(() => _optimistic[field] = value);
    try {
      // Queued offline like any Firestore write; the switch shows the new
      // value straight away either way.
      await _db.collection('pushPreferences').doc(uid).set(
        <String, Object?>{field: value, 'updatedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _optimistic.remove(field));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't save that setting. Try again.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: SafeArea(
        child: _uid == null
            ? const Center(child: Text('Sign in to manage notifications.'))
            : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: _prefsStream,
                builder: (BuildContext context,
                    AsyncSnapshot<DocumentSnapshot<Map<String, dynamic>>> snap) {
                  PushPreferences prefs =
                      PushPreferences.fromMap(snap.data?.data());
                  final Map<String, dynamic>? stored = snap.data?.data();
                  _optimistic.removeWhere(
                      (String k, bool v) => stored != null && stored[k] == v);
                  _optimistic.forEach((String k, bool v) {
                    prefs = prefs.withField(k, v);
                  });
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: <Widget>[
                      _PermissionCard(
                        permission: _permission,
                        onTurnOn: _turnOn,
                        onOpenSettings: _service.openSystemSettings,
                      ),
                      const SizedBox(height: 16),
                      Card(
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        child: Column(
                          children: <Widget>[
                            _toggle(
                              prefs,
                              PushPreferences.fFriendRequests,
                              'Friend requests',
                              'When someone sends you a friend request',
                            ),
                            _toggle(
                              prefs,
                              PushPreferences.fFriendAccepted,
                              'Friend request accepted',
                              'When someone accepts your friend request',
                            ),
                            _toggle(
                              prefs,
                              PushPreferences.fDirectMessages,
                              'Direct messages',
                              'When a friend sends you a message',
                            ),
                            const Divider(height: 1),
                            _toggle(
                              prefs,
                              PushPreferences.fMessagePreviews,
                              'Show message previews',
                              'Include the message text. When off, '
                                  'notifications only say who messaged you.',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          'These settings belong to your account and apply on '
                          'every device you sign in to. Coaching an athlete '
                          'never changes them.',
                          style: TextStyle(fontSize: 12, color: Colors.white60),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  Widget _toggle(
    PushPreferences prefs,
    String field,
    String title,
    String subtitle,
  ) {
    return SwitchListTile(
      key: ValueKey<String>('push-pref-$field'),
      title: Text(title),
      subtitle: Text(subtitle),
      value: prefs.valueOf(field),
      onChanged: (bool v) => _set(field, v),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.permission,
    required this.onTurnOn,
    required this.onOpenSettings,
  });

  final PushPermission? permission;
  final VoidCallback onTurnOn;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final PushPermission? p = permission;
    final String text;
    Widget? action;
    IconData icon;
    if (p == null) {
      text = 'Checking this device…';
      icon = Icons.notifications_none;
    } else if (p.allowsDelivery) {
      text = 'Notifications are on for this device.';
      icon = Icons.notifications_active_outlined;
    } else if (p == PushPermission.denied) {
      text = "Notifications are turned off for GoodLift in your phone's "
          'settings.';
      icon = Icons.notifications_off_outlined;
      action = TextButton(
        key: const ValueKey<String>('push-open-settings'),
        onPressed: onOpenSettings,
        child: const Text('Open settings'),
      );
    } else {
      text = 'Allow GoodLift to show notifications on this device.';
      icon = Icons.notifications_none;
      action = TextButton(
        key: const ValueKey<String>('push-turn-on'),
        onPressed: onTurnOn,
        child: const Text('Turn on'),
      );
    }
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.tertiary),
        title: Text(text),
        trailing: action,
      ),
    );
  }
}
