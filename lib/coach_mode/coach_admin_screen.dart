// Super-admin Coach Management.
//
// Visible ONLY to the hard-coded super-admin UID (kSuperAdminUid). The guard
// here is defence in depth: every action below is also enforced server-side by
// requireSuperAdmin() in functions/coach/coach_mode.js, and the underlying
// documents are unreadable to anyone else by firestore.rules.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../profile/ui/live_identity.dart';

import 'coach_mode_models.dart';
import 'coach_mode_service.dart';

class CoachAdminScreen extends StatefulWidget {
  const CoachAdminScreen({super.key, this.service});

  final CoachModeService? service;

  @override
  State<CoachAdminScreen> createState() => _CoachAdminScreenState();
}

class _CoachAdminScreenState extends State<CoachAdminScreen>
    with SingleTickerProviderStateMixin {
  late final CoachModeService _service = widget.service ?? CoachModeService();
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != kSuperAdminUid) {
      // Never reachable through the UI; kept so a stray push cannot show it.
      return const Scaffold(
        body: Center(child: Text('Not available.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Coach Management'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Pending'),
            Tab(text: 'Coaches'),
            Tab(text: 'Grant'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _PendingApplicationsTab(service: _service),
          _CoachesTab(service: _service),
          _DirectGrantTab(service: _service),
        ],
      ),
    );
  }
}

// ── Pending applications ────────────────────────────────────────────────────

class _PendingApplicationsTab extends StatelessWidget {
  const _PendingApplicationsTab({required this.service});
  final CoachModeService service;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<CoachApplication>>(
      stream: service.watchApplicationsByStatus('submitted'),
      builder: (context, snap) {
        if (snap.hasError) {
          return _ErrorBox('Could not load applications.\n${snap.error}');
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final apps = snap.data!;
        if (apps.isEmpty) {
          return const _EmptyBox(
            icon: Icons.inbox_outlined,
            title: 'No applications waiting',
            body: 'New Coach Mode applications appear here first.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: apps.length,
          itemBuilder: (context, i) {
            final app = apps[i];
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                title: Text(app.applicantLabel),
                subtitle: Text(
                  '${kAthleteCountBandLabels[app.answers.athleteCountBand] ?? '—'} · '
                  '${kExperienceBandLabels[app.answers.experienceBand] ?? '—'}',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => _ApplicationDetailScreen(
                      application: app,
                      service: service,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ApplicationDetailScreen extends StatefulWidget {
  const _ApplicationDetailScreen(
      {required this.application, required this.service});
  final CoachApplication application;
  final CoachModeService service;

  @override
  State<_ApplicationDetailScreen> createState() =>
      _ApplicationDetailScreenState();
}

class _ApplicationDetailScreenState extends State<_ApplicationDetailScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.application;
    final ans = a.answers;

    return Scaffold(
      appBar: AppBar(title: Text(a.applicantLabel)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          _Field('Account', '${a.applicantEmail}\n${a.uid}'),
          _Field('Athletes coached',
              kAthleteCountBandLabels[ans.athleteCountBand] ?? '—'),
          _Field(
              'Experience', kExperienceBandLabels[ans.experienceBand] ?? '—'),
          _Field(
            'Coaching focus',
            ans.coachingFocus
                .map((f) => kCoachingFocusLabels[f] ?? f)
                .join(', '),
          ),
          _Field(
            'Competition experience',
            ans.competitionExperience
                .map((f) => kCompetitionExperienceLabels[f] ?? f)
                .join(', '),
          ),
          if (ans.competitionDetails.isNotEmpty)
            _Field('Competition details', ans.competitionDetails),
          if (ans.qualifications.isNotEmpty)
            _Field('Qualifications', ans.qualifications),
          _Field('Intended use', ans.intendedUse),
          if (ans.profileUrl.isNotEmpty) _Field('Profile link', ans.profileUrl),
          _Field(
            'Athlete consent confirmed',
            ans.agreesToAthleteConsent ? 'Yes' : 'No',
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy ? null : _approve,
            icon: const Icon(Icons.check),
            label: const Text('Approve — grant Coach Mode'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _requestInfo,
            icon: const Icon(Icons.help_outline),
            label: const Text('Request more information'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: _busy ? null : _decline,
            icon: const Icon(Icons.close),
            label: const Text('Decline'),
          ),
        ],
      ),
    );
  }

  Future<void> _approve() async {
    final ok = await _confirm(
      context,
      title: 'Approve Coach Mode?',
      body: '${widget.application.applicantLabel} will immediately be able to '
          'invite athletes. Athletes must still accept each invitation.',
      confirmLabel: 'Approve',
    );
    if (ok != true) return;
    await _run(() => widget.service.approveApplication(widget.application.uid),
        'Coach Mode approved.');
  }

  Future<void> _decline() async {
    final reason = await _promptReason(context,
        title: 'Decline application',
        hint: 'Reason shown to the applicant',
        required: true);
    if (reason == null) return;
    await _run(
        () => widget.service
            .declineApplication(widget.application.uid, reason: reason),
        'Application declined.');
  }

  Future<void> _requestInfo() async {
    final reason = await _promptReason(context,
        title: 'Request more information',
        hint: 'What do you need from them?',
        required: true);
    if (reason == null) return;
    await _run(
        () => widget.service
            .requestMoreInfo(widget.application.uid, reason: reason),
        'Information requested.');
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(success)));
      Navigator.of(context).pop();
    } on CoachModeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ── Active / suspended / revoked coaches ────────────────────────────────────

class _CoachesTab extends StatefulWidget {
  const _CoachesTab({required this.service});
  final CoachModeService service;

  @override
  State<_CoachesTab> createState() => _CoachesTabState();
}

class _CoachesTabState extends State<_CoachesTab> {
  String _state = 'active';
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'active', label: Text('Active')),
              ButtonSegment(value: 'suspended', label: Text('Suspended')),
              ButtonSegment(value: 'revoked', label: Text('Revoked')),
            ],
            selected: {_state},
            onSelectionChanged: (s) => setState(() => _state = s.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search by name, email or UID',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        ),
        Expanded(
          child: StreamBuilder<List<CoachProfileSummary>>(
            stream: widget.service.watchCoachesByState(_state),
            builder: (context, snap) {
              if (snap.hasError) {
                return _ErrorBox('Could not load coaches.\n${snap.error}');
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final all = snap.data!;
              final coaches = all.where((c) => c.matches(_query)).toList();
              if (coaches.isEmpty) {
                return _EmptyBox(
                  icon: Icons.people_outline,
                  title: 'No $_state coaches',
                  body: _state == 'active'
                      ? 'Approve an application or grant Coach Mode directly.'
                      : 'Nothing here.',
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: coaches.length,
                itemBuilder: (context, i) => _coachTile(coaches[i]),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _coachTile(CoachProfileSummary c) {
    final source = switch (c.source) {
      CoachEntitlementSource.manualReview => 'Approved application',
      CoachEntitlementSource.superAdminGrant => 'Granted directly',
      CoachEntitlementSource.iap => 'Subscription',
      CoachEntitlementSource.unknown => 'Unknown source',
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        title: LiveUserName(
            uid: c.uid,
            fallback: c.label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (c.email.isNotEmpty && c.email != c.label)
              Text(c.email, style: const TextStyle(fontSize: 12)),
            Text(c.uid,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            Text(
              c.entitlement.reason.isNotEmpty
                  ? '$source · ${c.entitlement.reason}'
                  : source,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (v) => _action(c, v),
          itemBuilder: (_) => [
            if (c.entitlement.isActive) ...[
              const PopupMenuItem(value: 'suspend', child: Text('Suspend')),
              const PopupMenuItem(value: 'revoke', child: Text('Revoke')),
            ] else ...[
              const PopupMenuItem(value: 'restore', child: Text('Restore')),
              if (!c.entitlement.isRevoked)
                const PopupMenuItem(value: 'revoke', child: Text('Revoke')),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _action(CoachProfileSummary c, String action) async {
    try {
      switch (action) {
        case 'suspend':
          final reason = await _promptReason(context,
              title: 'Suspend Coach Mode',
              hint: 'Reason (shown to the coach)',
              required: true);
          if (reason == null || !mounted) return;
          final ok = await _confirm(context,
              title: 'Suspend this coach?',
              body: 'They immediately lose access to every athlete on their '
                  'roster. Relationships are kept and restored if you '
                  'reactivate them.',
              confirmLabel: 'Suspend');
          if (ok != true) return;
          await widget.service.suspendCoach(c.uid, reason: reason);
          break;

        case 'revoke':
          final reason = await _promptReason(context,
              title: 'Revoke Coach Mode',
              hint: 'Reason (shown to the coach)',
              required: true);
          if (reason == null || !mounted) return;
          final ok = await _confirm(context,
              title: 'Revoke Coach Mode?',
              body: 'They immediately lose access to every athlete and can no '
                  'longer invite anyone. This is the strongest action.',
              confirmLabel: 'Revoke',
              destructive: true);
          if (ok != true) return;
          await widget.service.revokeCoachMode(c.uid, reason: reason);
          break;

        case 'restore':
          final ok = await _confirm(context,
              title: 'Restore Coach Mode?',
              body: 'Their existing active relationships become usable again.',
              confirmLabel: 'Restore');
          if (ok != true) return;
          await widget.service.restoreCoach(c.uid);
          break;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Updated.')));
    } on CoachModeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

// ── Direct grant ────────────────────────────────────────────────────────────

class _DirectGrantTab extends StatefulWidget {
  const _DirectGrantTab({required this.service});
  final CoachModeService service;

  @override
  State<_DirectGrantTab> createState() => _DirectGrantTabState();
}

class _DirectGrantTabState extends State<_DirectGrantTab> {
  final _email = TextEditingController();
  Map<String, dynamic>? _result;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Grant Coach Mode directly',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        const Text(
          'For coaches you already know. No application is required — and no '
          'code change, rules change or deploy.',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Account email (exact)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _busy ? null : _lookup,
          child: const Text('Find account'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ),
        if (_result != null) ...[
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${_result!['displayName'] ?? ''}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('${_result!['email'] ?? ''}',
                      style: const TextStyle(fontSize: 12)),
                  Text('${_result!['uid'] ?? ''}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  const SizedBox(height: 10),
                  Text(
                    _result!['isSuperAdmin'] == true
                        ? 'Super admin — already has full access.'
                        : 'Coach Mode: ${_result!['coachState'] ?? 'none'}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_result!['isSuperAdmin'] != true &&
              _result!['coachState'] != 'active')
            FilledButton.icon(
              onPressed: _busy ? null : _grant,
              icon: const Icon(Icons.workspace_premium),
              label: const Text('Grant Coach Mode'),
            ),
        ],
      ],
    );
  }

  Future<void> _lookup() async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final res = await widget.service.lookupAccount(_email.text);
      if (!mounted) return;
      if (res['found'] != true) {
        setState(() => _error = 'No GoodLift account uses that email.');
      } else {
        setState(() => _result = res);
      }
    } on CoachModeException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _grant() async {
    final uid = _result?['uid']?.toString();
    if (uid == null) return;
    final ok = await _confirm(context,
        title: 'Grant Coach Mode?',
        body: 'This account will immediately be able to invite athletes. '
            'Athletes must still accept each invitation.',
        confirmLabel: 'Grant');
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      await widget.service.grantCoach(targetUid: uid, reason: 'Direct grant');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Coach Mode granted.')));
      setState(() {
        _result = null;
        _email.clear();
      });
    } on CoachModeException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ── Shared bits ─────────────────────────────────────────────────────────────

Future<bool?> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  bool destructive = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: Colors.redAccent)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

Future<String?> _promptReason(
  BuildContext context, {
  required String title,
  required String hint,
  bool required = false,
}) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        maxLines: 3,
        maxLength: CoachApplicationLimits.reason,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final v = controller.text.trim();
            if (required && v.isEmpty) return;
            Navigator.pop(ctx, v);
          },
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.0,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey)),
          const SizedBox(height: 4),
          Text(value.isEmpty ? '—' : value,
              style: const TextStyle(fontSize: 14, height: 1.35)),
        ],
      ),
    );
  }
}

class _EmptyBox extends StatelessWidget {
  const _EmptyBox(
      {required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: Colors.grey),
            const SizedBox(height: 14),
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }
}
