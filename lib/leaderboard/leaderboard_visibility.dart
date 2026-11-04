/// "Show me on leaderboards" — the signed-in athlete's own choice, stored as
/// `users/{uid}.leaderboardVisible`.
///
/// ── Whose choice ────────────────────────────────────────────────────────────
/// Always the SIGNED-IN Firebase Auth account, never the athlete a coach is
/// acting as. The rules agree: only the owner (or the super admin) can write
/// `users/{uid}`, so a coach could not change an athlete's choice even by
/// mistake; the widget does not offer it.
///
/// ── Meaning ─────────────────────────────────────────────────────────────────
/// Only an explicit `false` hides. A missing field — every existing and new
/// account — is visible. The server enforces it: hiding withdraws the
/// athlete's entries from every monthly, all-time, age-adjusted and
/// sex-filtered board, the medals and the public website snapshots
/// (functions/leaderboard). Private training data is untouched, so turning it
/// back on rebuilds every board from data that is still there.
///
/// ── Honest saving ───────────────────────────────────────────────────────────
/// The write is a TRANSACTION: unlike a plain set it is never queued offline,
/// so it either reaches the server or fails. The switch keeps showing the
/// SAVED value until the server confirms, and a failure leaves it unchanged
/// with a message — it never claims a change that did not happen.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// The users/{uid} field (functions/leaderboard/eligibility.js).
const String kLeaderboardVisibleField = 'leaderboardVisible';

const String kLeaderboardVisibilityTitle = 'Show me on leaderboards';
const String kLeaderboardVisibilityHelp =
    "When turned off, your name and RE Points won't appear on GoodLift's "
    'monthly, all-time or public website leaderboards.';
const String kLeaderboardVisibilityCoachNote =
    "This is the athlete's own setting. Only they can change it, from their "
    'own account.';
const String kLeaderboardHiddenSaved =
    "Saved. You'll be removed from the in-app leaderboards within a few "
    'minutes. The public website can take up to two hours to update.';
const String kLeaderboardVisibleSaved =
    "Saved. You'll reappear on the in-app leaderboards once your rankings are "
    'rebuilt, usually within a few minutes. The public website can take up to '
    'three hours to update.';
const String kLeaderboardSaveFailed =
    "Couldn't save this setting. Check your connection and try again.";
const String kLeaderboardLoadFailed =
    "Couldn't load this setting. Check your connection and try again.";

class LeaderboardVisibilityRepository {
  LeaderboardVisibilityRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// How long a save may take before it is reported as failed.
  static const Duration saveTimeout = Duration(seconds: 15);

  DocumentReference<Map<String, dynamic>> _ref(String uid) =>
      _db.collection('users').doc(uid);

  /// Only an explicit `false` hides; anything else — including a missing
  /// document or field — is visible.
  static bool visibleOf(Map<String, dynamic>? data) =>
      data?[kLeaderboardVisibleField] != false;

  /// The saved choice of [uid], live.
  Stream<bool> watch(String uid) => _ref(uid)
      .snapshots()
      .map((DocumentSnapshot<Map<String, dynamic>> s) => visibleOf(s.data()));

  /// Saves [visible] for [uid]. Completes only once the SERVER has it;
  /// throws on failure (including no connection).
  Future<void> setVisible(String uid, bool visible) {
    return _db.runTransaction<void>(
      (Transaction tx) async {
        final DocumentReference<Map<String, dynamic>> ref = _ref(uid);
        final Map<String, Object?> fields = <String, Object?>{
          kLeaderboardVisibleField: visible,
          'leaderboardVisibilityUpdatedAt': FieldValue.serverTimestamp(),
          'leaderboardVisibilitySource': 'settings',
        };
        // A field-level patch: no other profile field can be touched.
        if ((await tx.get(ref)).exists) {
          tx.update(ref, fields);
        } else {
          tx.set(ref, fields, SetOptions(merge: true));
        }
      },
      timeout: saveTimeout,
    );
  }
}

/// The Settings → Profile switch.
///
/// [ownerUid] is the signed-in Firebase Auth uid (null when signed out).
/// [actingAsSelf] is false while a coach is acting as an athlete: the switch
/// is then replaced by a note, and nobody's choice is read or written.
class LeaderboardVisibilitySetting extends StatefulWidget {
  const LeaderboardVisibilitySetting({
    super.key,
    required this.ownerUid,
    required this.actingAsSelf,
    this.repository,
  });

  final String? ownerUid;
  final bool actingAsSelf;
  final LeaderboardVisibilityRepository? repository;

  @override
  State<LeaderboardVisibilitySetting> createState() =>
      _LeaderboardVisibilitySettingState();
}

class _LeaderboardVisibilitySettingState
    extends State<LeaderboardVisibilitySetting> {
  late final LeaderboardVisibilityRepository _repo =
      widget.repository ?? LeaderboardVisibilityRepository();
  StreamSubscription<bool>? _sub;

  bool? _saved; // null while loading
  bool _loadFailed = false;
  bool _saving = false;
  String? _message;
  bool _messageIsError = false;

  bool get _editable => widget.actingAsSelf && widget.ownerUid != null;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(LeaderboardVisibilitySetting old) {
    super.didUpdateWidget(old);
    if (old.ownerUid != widget.ownerUid ||
        old.actingAsSelf != widget.actingAsSelf) {
      _saved = null;
      _message = null;
      _listen();
    }
  }

  void _listen() {
    _sub?.cancel();
    _sub = null;
    _loadFailed = false;
    final String? uid = widget.ownerUid;
    if (!_editable || uid == null) return;
    _sub = _repo.watch(uid).listen(
      (bool visible) {
        if (!mounted) return;
        setState(() {
          _saved = visible;
          _loadFailed = false;
        });
      },
      onError: (Object _) {
        if (!mounted) return;
        setState(() => _loadFailed = true);
      },
    );
  }

  Future<void> _change(bool visible) async {
    final String? uid = widget.ownerUid;
    if (!_editable || uid == null || _saving || _saved == null) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await _repo.setVisible(uid, visible);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved = visible; // confirmed by the server
        _message = visible ? kLeaderboardVisibleSaved : kLeaderboardHiddenSaved;
        _messageIsError = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false; // _saved is unchanged: nothing was applied
        _message = kLeaderboardSaveFailed;
        _messageIsError = true;
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (!_editable) {
      return ListTile(
        key: const Key('leaderboardVisibilityCoachNote'),
        contentPadding: EdgeInsets.zero,
        leading:
            Icon(Icons.leaderboard_outlined, color: theme.colorScheme.tertiary),
        title: const Text(kLeaderboardVisibilityTitle,
            style: TextStyle(color: Colors.white)),
        subtitle: const Text(kLeaderboardVisibilityCoachNote,
            style: TextStyle(color: Colors.white70)),
      );
    }

    Widget? trailing;
    if (_saving || (_saved == null && !_loadFailed)) {
      trailing = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    final List<Widget> notes = <Widget>[
      const Text(kLeaderboardVisibilityHelp,
          style: TextStyle(color: Colors.white70)),
      if (_loadFailed && _saved == null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: <Widget>[
              const Expanded(
                child: Text(kLeaderboardLoadFailed,
                    style: TextStyle(color: Colors.redAccent)),
              ),
              TextButton(
                key: const Key('leaderboardVisibilityRetry'),
                onPressed: () => setState(_listen),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      if (_saving)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Saving…', style: TextStyle(color: Colors.white70)),
        ),
      if (_message != null && !_saving)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            _message!,
            key: const Key('leaderboardVisibilityMessage'),
            style: TextStyle(
                color: _messageIsError ? Colors.redAccent : Colors.white70),
          ),
        ),
    ];

    return SwitchListTile(
      key: const Key('leaderboardVisibilitySwitch'),
      contentPadding: EdgeInsets.zero,
      title: const Text(kLeaderboardVisibilityTitle,
          style: TextStyle(color: Colors.white)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: notes,
      ),
      // Always the SAVED value: never the one still being written.
      value: _saved ?? true,
      onChanged: (_saved == null || _saving) ? null : _change,
      secondary: trailing ??
          Icon(Icons.leaderboard_outlined, color: theme.colorScheme.tertiary),
    );
  }
}
