/// The social actions on ANOTHER athlete's profile: Add friend, the pending
/// request states, and Message for a confirmed friend.
///
/// Every relationship and every action belongs to the SIGNED-IN account
/// ([BuddyRepository.currentUid] resolves FirebaseAuth, never the athlete a
/// coach has selected), so a coach looking at an athlete's profile acts as
/// themselves. Nothing renders on one's own profile, or before the viewer's
/// social state has loaded (so "Add friend" is never offered for somebody who
/// is already a friend or already asked).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../directMessages.dart' show ConversationPage, ensureDirectConversation;
import '../../main.dart' show showAppSnack;
import '../../profile/ui/profile_theme.dart';
import '../buddy_repository.dart';

/// Opens the one-to-one conversation between the signed-in account and a
/// friend. Replaceable in tests.
typedef OpenConversation = Future<void> Function(
    BuildContext context, String myUid, String otherUid);

Future<void> openDirectConversation(
    BuildContext context, String myUid, String otherUid) async {
  final String convId =
      await ensureDirectConversation(myUid: myUid, otherUid: otherUid);
  if (!context.mounted) return;
  // A normal push: Back returns to the profile.
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => ConversationPage(convId: convId, otherUid: otherUid),
  ));
}

class ProfileSocialActions extends StatefulWidget {
  const ProfileSocialActions({
    super.key,
    required this.targetUid,
    this.buddies,
    this.openConversation,
  });

  /// The profile being viewed.
  final String targetUid;

  /// For tests. Production uses the signed-in account's repository.
  final BuddyRepository? buddies;

  final OpenConversation? openConversation;

  @override
  State<ProfileSocialActions> createState() => _ProfileSocialActionsState();
}

class _ProfileSocialActionsState extends State<ProfileSocialActions> {
  late final BuddyRepository _buddies = widget.buddies ?? BuddyRepository();
  late final Stream<BuddyState> _state = _buddies.watchState();
  bool _busy = false;

  /// What the server answered for the last action, shown until the live
  /// state catches up — so a just-sent request can never be sent again.
  BuddyRelationship? _answered;

  /// The relationship the buttons were last built for.
  BuddyRelationship? _shown;

  Future<void> _run(BuddyRelationship expected,
      Future<BuddyRelationship> Function() action) async {
    // A stale, not-yet-rebuilt button can never act twice.
    if (_busy || (_answered ?? _shown) != expected) return;
    setState(() => _busy = true);
    try {
      final BuddyRelationship r = await action();
      if (mounted) setState(() => _answered = r);
    } catch (err) {
      if (mounted) showAppSnack(describeSocialError(err));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _message(String me) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await (widget.openConversation ?? openDirectConversation)(
          context, me, widget.targetUid);
    } catch (err) {
      if (mounted) showAppSnack(describeSocialError(err));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? me = _buddies.currentUid;
    final String target = widget.targetUid;
    if (me == null || target.isEmpty || me == target) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<BuddyState>(
      stream: _state,
      builder: (BuildContext context, AsyncSnapshot<BuddyState> snap) {
        final BuddyState? state = snap.data;
        if (state == null || !state.loaded) return const SizedBox.shrink();
        final BuddyRelationship live = state.relationshipWith(target);
        if (_answered != null && live == _answered) {
          // The live state agrees; stop overriding it.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _answered == live) setState(() => _answered = null);
          });
        }
        final BuddyRelationship rel = _answered ?? live;
        _shown = rel;
        return Padding(
          key: const ValueKey<String>('profile-social-actions'),
          padding: const EdgeInsets.fromLTRB(
              ProfileSpacing.lg, 0, ProfileSpacing.lg, ProfileSpacing.sm),
          child: _buttons(rel, me),
        );
      },
    );
  }

  Widget _buttons(BuddyRelationship rel, String me) {
    if (_busy) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
              key: ValueKey<String>('profile-social-busy'), strokeWidth: 2),
        ),
      );
    }
    switch (rel) {
      case BuddyRelationship.none:
        return FilledButton.icon(
          key: const ValueKey<String>('profile-social-add'),
          onPressed: () => _run(BuddyRelationship.none,
              () => _buddies.sendRequest(widget.targetUid)),
          icon: const Icon(Icons.person_add_alt_1),
          label: const Text('Add friend'),
        );
      case BuddyRelationship.requested:
        return OutlinedButton.icon(
          key: const ValueKey<String>('profile-social-cancel'),
          onPressed: () => _run(BuddyRelationship.requested,
              () => _buddies.cancelRequest(widget.targetUid)),
          icon: const Icon(Icons.hourglass_top),
          label: const Text('Requested · Cancel'),
        );
      case BuddyRelationship.incoming:
        return Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey<String>('profile-social-accept'),
                onPressed: () => _run(BuddyRelationship.incoming,
                    () => _buddies.acceptRequest(widget.targetUid)),
                icon: const Icon(Icons.check),
                label: const Text('Accept request'),
              ),
            ),
            const SizedBox(width: ProfileSpacing.sm),
            OutlinedButton(
              key: const ValueKey<String>('profile-social-decline'),
              onPressed: () => _run(BuddyRelationship.incoming,
                  () => _buddies.declineRequest(widget.targetUid)),
              child: const Text('Decline'),
            ),
          ],
        );
      case BuddyRelationship.friends:
        return FilledButton.icon(
          key: const ValueKey<String>('profile-social-message'),
          onPressed: () => unawaited(_message(me)),
          icon: const Icon(Icons.chat_bubble_outline),
          label: const Text('Message'),
        );
      case BuddyRelationship.self:
        return const SizedBox.shrink();
    }
  }
}
