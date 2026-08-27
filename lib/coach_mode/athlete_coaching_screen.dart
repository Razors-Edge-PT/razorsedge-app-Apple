// The athlete's Coaching area: incoming coach invitations and current coaches.
//
// This is the new, canonical athlete-side flow. It reads coachAthleteLinks and
// drives every change through the coachMode* callables — it does NOT use the
// old, disconnected ApproveRequestsScreen, and it is deliberately kept
// separate from Gymbro/buddy requests, which remain untouched.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'coach_mode_models.dart';
import 'coach_mode_service.dart';

class AthleteCoachingScreen extends StatefulWidget {
  const AthleteCoachingScreen({super.key, this.service});

  final CoachModeService? service;

  @override
  State<AthleteCoachingScreen> createState() => _AthleteCoachingScreenState();
}

class _AthleteCoachingScreenState extends State<AthleteCoachingScreen> {
  late final CoachModeService _service = widget.service ?? CoachModeService();
  final String? _uid = FirebaseAuth.instance.currentUser?.uid;
  String? _busyCoachUid;

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: Text('Sign in to see coaching.')));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Coaching')),
      body: StreamBuilder<List<CoachAthleteLink>>(
        stream: _service.watchAthleteLinks(uid),
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  "We couldn't load your coaching information. Check your "
                  'connection and try again.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final split = splitAthleteCoaching(snap.data!);
          if (split.isEmpty) return _emptyState();

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              if (split.invitations.isNotEmpty) ...[
                const _SectionHeader('Coach requests'),
                for (final link in split.invitations) _invitationCard(link),
                const SizedBox(height: 24),
              ],
              if (split.activeCoaches.isNotEmpty) ...[
                const _SectionHeader('Your coaches'),
                for (final link in split.activeCoaches) _activeCoachCard(link),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _emptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.supervisor_account_outlined, size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'No coaches yet',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              'When a coach invites you, their request will appear here. You '
              'choose whether to accept, and you can remove a coach at any time.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _invitationCard(CoachAthleteLink link) {
    final busy = _busyCoachUid == link.coachUid;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(child: Icon(Icons.person_add_alt)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(link.coachLabel,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                      if (link.coachEmail.isNotEmpty &&
                          link.coachEmail != link.coachLabel)
                        Text(link.coachEmail,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'wants to coach you. Accepting lets them see your training and '
              'plan your blocks. You can remove them at any time.',
              style: TextStyle(fontSize: 13, height: 1.35),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: busy ? null : () => _respond(link, accept: true),
                    child: const Text('Accept'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy ? null : () => _respond(link, accept: false),
                    child: const Text('Decline'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _activeCoachCard(CoachAthleteLink link) {
    final busy = _busyCoachUid == link.coachUid;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.supervisor_account)),
        title: Text(link.coachLabel),
        subtitle: Text(
          link.coachEmail.isNotEmpty && link.coachEmail != link.coachLabel
              ? link.coachEmail
              : coachLinkStatusLabel(link.status),
        ),
        trailing: busy
            ? const SizedBox(
                width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : TextButton(
                onPressed: () => _confirmRevoke(link),
                child: const Text('Remove', style: TextStyle(color: Colors.redAccent)),
              ),
      ),
    );
  }

  Future<void> _respond(CoachAthleteLink link, {required bool accept}) async {
    setState(() => _busyCoachUid = link.coachUid);
    try {
      if (accept) {
        await _service.acceptInvite(link.coachUid);
      } else {
        await _service.declineInvite(link.coachUid);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(accept
            ? '${link.coachLabel} is now your coach.'
            : 'Request declined.'),
      ));
    } on CoachModeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busyCoachUid = null);
    }
  }

  Future<void> _confirmRevoke(CoachAthleteLink link) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove coach?'),
        content: Text(
          '${link.coachLabel} will immediately lose access to your training '
          'data, planned blocks and check-ins.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove coach'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busyCoachUid = link.coachUid);
    try {
      await _service.revokeCoach(link.coachUid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${link.coachLabel} removed.')),
      );
    } on CoachModeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busyCoachUid = null);
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.1,
          color: Colors.grey,
        ),
      ),
    );
  }
}

/// Compact banner for HomeScreen2: shows only when the athlete has at least
/// one pending coach invitation, and opens the Coaching area.
///
/// Rendered as a zero-height SizedBox when there is nothing to show, so it
/// never disturbs the existing Home layout.
class CoachInvitationBanner extends StatelessWidget {
  const CoachInvitationBanner({super.key, this.service});

  final CoachModeService? service;

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    final svc = service ?? CoachModeService();

    return StreamBuilder<List<CoachAthleteLink>>(
      stream: svc.watchAthleteLinks(uid),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final pending = splitAthleteCoaching(snap.data!).invitations;
        if (pending.isEmpty) return const SizedBox.shrink();

        final label = pending.length == 1
            ? '${pending.first.coachLabel} wants to coach you'
            : '${pending.length} coaches want to coach you';

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Material(
            color: Colors.lightBlue.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AthleteCoachingScreen(service: service),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.supervisor_account,
                        color: Colors.lightBlueAccent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(label,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    const Icon(Icons.chevron_right, size: 20),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
