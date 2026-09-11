/// Opens the screen a notification tap asks for — once the app is ready.
///
/// A tap can arrive at any point of startup: from a killed app before
/// Firebase Auth has restored the session, while the membership gate is still
/// checking, or while the navigator does not exist yet. The router therefore
/// holds ONE pending intent and opens it only when all of these hold (see
/// [decideDispatch]):
///
///   • the signed-in account is the notification's recipient — never another
///     account, and the app never switches accounts to satisfy a tap;
///   • a [PushReadyScope] is mounted, which only happens INSIDE a membership
///     gate that has let the person through (Home or the restored WES2 route),
///     so a tap can never be used to step around the paywall;
///   • the intent is not stale.
///
/// Destinations are PUSHED on top of whatever is showing. A restored WES2
/// workout stays underneath, untouched, and back returns to it; the saved
/// startup route is not rewritten.
///
/// ── One tap at a time, but never blocked by an open screen ──────────────────
/// `Navigator.push` completes only when the pushed route is POPPED, so the
/// router never awaits it: a destination counts as opened once its push has
/// been issued. The busy guard covers only the asynchronous checks BEFORE the
/// push (the DM access lookup), so taps are serialized while a lookup is in
/// flight and a second tap opens immediately while the first screen is still
/// open. After every asynchronous step the navigator re-checks that the tap is
/// still for the signed-in account, that no logout happened meanwhile, and
/// that its context is still mounted.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../directMessages.dart';
import '../main.dart' show showAppSnack;
import '../social/buddy_hub_screen.dart';
import '../user_context.dart';
import 'foreground_conversation.dart';
import 'push_intent.dart';

/// Opens [intent] from [context]. Returns true when a route was pushed.
///
/// Must return as soon as the push has been ISSUED — never await the pushed
/// route. [stillValid] must be re-checked after any asynchronous step.
typedef PushNavigate = Future<bool> Function(
    BuildContext context, PushIntent intent, bool Function() stillValid);

/// A tap for the same destination within this window is a duplicate (a
/// double tap, or the same notification delivered twice) and is ignored.
const Duration kPushDuplicateTapWindow = Duration(seconds: 2);

class PushRouter {
  PushRouter({
    String? Function()? currentUid,
    PushNavigate? navigate,
    DateTime Function()? clock,
    void Function(String message)? notify,
  })  : _currentUid =
            currentUid ?? (() => FirebaseAuth.instance.currentUser?.uid),
        _navigate = navigate ?? const PushDestinations().navigate,
        _clock = clock ?? DateTime.now,
        _notify = notify ?? showAppSnack;

  static final PushRouter instance = PushRouter();

  final String? Function() _currentUid;
  final PushNavigate _navigate;
  final DateTime Function() _clock;
  final void Function(String message) _notify;

  PushIntent? _pending;
  bool _dispatching = false;
  Timer? _retry;

  /// Bumped by [clear] (explicit logout): an in-flight lookup started before
  /// it must not navigate afterwards.
  int _generation = 0;

  String? _lastOpenedKey;
  DateTime? _lastOpenedAt;

  /// Ready scopes, most recently mounted last. Each yields a context inside
  /// the authenticated app's navigator, or null once unmounted.
  final List<BuildContext? Function()> _scopes = <BuildContext? Function()>[];

  @visibleForTesting
  PushIntent? get pending => _pending;

  @visibleForTesting
  bool get dispatching => _dispatching;

  /// A tap (background, cold start, or the foreground banner). The most
  /// recent tap wins while an earlier one is still being checked.
  void submit(PushIntent intent) {
    _pending = intent;
    _schedule();
  }

  /// Registers a ready scope; returns the handle for [detachScope].
  Object attachScope(BuildContext? Function() contextOf) {
    _scopes.add(contextOf);
    _schedule();
    return contextOf;
  }

  void detachScope(Object? handle) {
    _scopes.remove(handle);
  }

  /// Auth state changed (signed in / restored). Re-evaluates a pending tap.
  void onAuthChanged() => _schedule();

  /// Explicit logout: a pending tap must not survive into the next account,
  /// and a lookup already in flight must not navigate when it returns.
  void clear() {
    _generation++;
    _pending = null;
    _lastOpenedKey = null;
    _lastOpenedAt = null;
    _retry?.cancel();
    _retry = null;
  }

  BuildContext? _readyContext() {
    for (int i = _scopes.length - 1; i >= 0; i--) {
      final BuildContext? c = _scopes[i]();
      if (c != null && c.mounted) return c;
    }
    return null;
  }

  static String _destinationKey(PushIntent i) => switch (i.kind) {
        PushKind.friendRequest || PushKind.friendAccepted => 'buddyHub',
        PushKind.directMessage => 'dm:${i.convId}',
      };

  void _schedule() {
    scheduleMicrotask(() => unawaited(_tryDispatch()));
  }

  Future<void> _tryDispatch() async {
    final PushIntent? intent = _pending;
    if (intent == null || _dispatching) return;
    final BuildContext? ctx = _readyContext();
    final PushDispatch decision = decideDispatch(
      intent: intent,
      currentUid: _currentUid(),
      uiReady: ctx != null,
      now: _clock(),
    );
    switch (decision) {
      case PushDispatch.wait:
        // Auth restoration does not always announce itself to us; look again
        // shortly, until the intent expires.
        _retry?.cancel();
        _retry = Timer(const Duration(seconds: 1), _schedule);
        return;
      case PushDispatch.dropExpired:
        _pending = null;
        return;
      case PushDispatch.dropOtherAccount:
        _pending = null;
        _notify('That notification was for a different GoodLift account.');
        return;
      case PushDispatch.open:
        _pending = null;
        _retry?.cancel();
        final String key = _destinationKey(intent);
        final DateTime now = _clock();
        if (_lastOpenedKey == key &&
            _lastOpenedAt != null &&
            now.difference(_lastOpenedAt!) < kPushDuplicateTapWindow) {
          return;
        }
        final int generation = _generation;
        bool stillValid() =>
            generation == _generation &&
            _currentUid() == intent.recipientUid &&
            ctx!.mounted;
        _dispatching = true;
        try {
          // Returns once the push is ISSUED; the screen may stay open.
          final bool opened = await _navigate(ctx!, intent, stillValid);
          if (opened) {
            _lastOpenedKey = key;
            _lastOpenedAt = _clock();
          }
        } catch (e) {
          debugPrint('[push] could not open notification: $e');
        } finally {
          _dispatching = false;
        }
        // A tap that arrived during a lookup opens next.
        if (_pending != null) _schedule();
    }
  }
}

/// The production destinations. The screen builders and the DM access lookup
/// are injectable so the routing logic can run against a real Navigator in
/// tests without Firebase.
class PushDestinations {
  const PushDestinations({
    this.buddyHub = _defaultBuddyHub,
    this.conversation = _defaultConversation,
    this.conversationList = _defaultConversationList,
    this.conversationAccessible = defaultConversationAccessible,
    this.notice = showAppSnack,
  });

  /// Buddy Hub → People. [actingAsOtherAccount] is presentation only.
  final Widget Function(PushIntent intent, bool actingAsOtherAccount) buddyHub;
  final Widget Function(PushIntent intent) conversation;
  final Widget Function() conversationList;

  /// false: the rules now deny it, or it is gone. null: unknown (offline).
  final Future<bool?> Function(String convId) conversationAccessible;
  final void Function(String message) notice;

  Future<bool> navigate(
    BuildContext context,
    PushIntent intent,
    bool Function() stillValid,
  ) async {
    final NavigatorState nav = Navigator.of(context, rootNavigator: true);
    switch (intent.kind) {
      case PushKind.friendRequest:
      case PushKind.friendAccepted:
        // The People view: REQUESTS lists incoming requests; NEW BUDDIES shows
        // (and, once actually displayed, marks seen) the acceptance. A request
        // already answered simply is not there any more.
        if (!stillValid()) return false;
        bool actingAsOther = false;
        try {
          final UserContext? userContext = context.read<UserContext?>();
          actingAsOther = userContext != null && !userContext.isActingAsSelf;
        } catch (_) {}
        unawaited(nav.push(MaterialPageRoute<void>(
          builder: (_) => buddyHub(intent, actingAsOther),
        )));
        return true;
      case PushKind.directMessage:
        final String convId = intent.convId!;
        // Already the thread in front of the person: nothing to open.
        if (ForegroundConversation.visibleConvId == convId) return false;
        final bool? accessible = await conversationAccessible(convId);
        // The lookup took time: the account may have logged out or switched,
        // the scope may be gone, or the thread may have been opened meanwhile.
        if (!stillValid() || !nav.mounted) return false;
        if (ForegroundConversation.visibleConvId == convId) return false;
        if (accessible == false) {
          notice('That conversation is no longer available.');
          unawaited(nav.push(MaterialPageRoute<void>(
            builder: (_) => conversationList(),
          )));
          return true;
        }
        unawaited(nav.push(MaterialPageRoute<void>(
          builder: (_) => conversation(intent),
        )));
        return true;
    }
  }
}

Widget _defaultBuddyHub(PushIntent intent, bool actingAsOtherAccount) =>
    BuddyHubScreen(
      initialTab: BuddyHubTab.people,
      showOwnAccountNotice: actingAsOtherAccount,
    );

Widget _defaultConversation(PushIntent intent) => ConversationPage(
      convId: intent.convId!,
      otherUid: intent.actorUid,
    );

Widget _defaultConversationList() => const DirectMessages();

/// false when the rules now deny the conversation (friendship ended) or it no
/// longer exists; null when it could not be checked (offline) — the page
/// itself then works from cache as it always has.
Future<bool?> defaultConversationAccessible(String convId) async {
  try {
    final DocumentSnapshot<Map<String, dynamic>> snap = await FirebaseFirestore
        .instance
        .collection('conversations')
        .doc(convId)
        .get()
        .timeout(const Duration(seconds: 4));
    return snap.exists;
  } on FirebaseException catch (e) {
    if (e.code == 'permission-denied') return false;
    return null;
  } catch (_) {
    return null;
  }
}
