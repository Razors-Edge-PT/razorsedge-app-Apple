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

typedef PushNavigate = Future<void> Function(
    BuildContext context, PushIntent intent);

class PushRouter {
  PushRouter({
    String? Function()? currentUid,
    PushNavigate? navigate,
    DateTime Function()? clock,
    void Function(String message)? notify,
  })  : _currentUid =
            currentUid ?? (() => FirebaseAuth.instance.currentUser?.uid),
        _navigate = navigate ?? defaultPushNavigate,
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

  /// Ready scopes, most recently mounted last. Each yields a context inside
  /// the authenticated app's navigator, or null once unmounted.
  final List<BuildContext? Function()> _scopes = <BuildContext? Function()>[];

  @visibleForTesting
  PushIntent? get pending => _pending;

  /// A tap (background, cold start, or the foreground banner).
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

  /// Explicit logout: a pending tap must not survive into the next account.
  void clear() {
    _pending = null;
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
        _dispatching = true;
        try {
          await _navigate(ctx!, intent);
        } catch (e) {
          debugPrint('[push] could not open notification: $e');
        } finally {
          _dispatching = false;
        }
        // Another tap may have arrived while navigating.
        if (_pending != null) _schedule();
    }
  }
}

/// The production destinations.
Future<void> defaultPushNavigate(BuildContext context, PushIntent intent) async {
  final NavigatorState nav = Navigator.of(context, rootNavigator: true);
  switch (intent.kind) {
    case PushKind.friendRequest:
    case PushKind.friendAccepted:
      // The People view: REQUESTS lists incoming requests; NEW BUDDIES shows
      // (and, once actually displayed, marks seen) the acceptance. A request
      // already answered simply is not there any more.
      UserContext? userContext;
      try {
        userContext = context.read<UserContext?>();
      } catch (_) {}
      await nav.push(MaterialPageRoute<void>(
        builder: (_) => BuddyHubScreen(
          initialTab: BuddyHubTab.people,
          showOwnAccountNotice:
              userContext != null && !userContext.isActingAsSelf,
        ),
      ));
      return;
    case PushKind.directMessage:
      final String convId = intent.convId!;
      if (ForegroundConversation.visibleConvId == convId) return;
      final bool? accessible = await _conversationAccessible(convId);
      if (!nav.mounted) return;
      if (accessible == false) {
        showAppSnack('That conversation is no longer available.');
        await nav.push(MaterialPageRoute<void>(
          builder: (_) => const DirectMessages(),
        ));
        return;
      }
      await nav.push(MaterialPageRoute<void>(
        builder: (_) => ConversationPage(
          convId: convId,
          otherUid: intent.actorUid,
        ),
      ));
      return;
  }
}

/// false when the rules now deny the conversation (friendship ended) or it no
/// longer exists; null when it could not be checked (offline) — the page
/// itself then works from cache as it always has.
Future<bool?> _conversationAccessible(String convId) async {
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
