// Coach Mode — the prospective coach's screen.
//
// Renders exactly one state at a time (not applied / form / submitted /
// more info requested / approved / declined / suspended / revoked), derived
// once by resolveCoachModeScreenState() so precedence between the entitlement
// and the application is never re-decided in the widget tree.
//
// Reachable from Settings AND from the inactive-membership screen: any
// signed-in account may apply for Coach Mode, including one whose normal
// membership is currently inactive.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'coach_mode_models.dart';
import 'coach_mode_service.dart';

class CoachModeScreen extends StatefulWidget {
  const CoachModeScreen({super.key, this.service});

  /// Injectable for tests; defaults to the live service.
  final CoachModeService? service;

  @override
  State<CoachModeScreen> createState() => _CoachModeScreenState();
}

class _CoachModeScreenState extends State<CoachModeScreen> {
  late final CoachModeService _service = widget.service ?? CoachModeService();
  final String? _uid = FirebaseAuth.instance.currentUser?.uid;

  CoachEntitlement _entitlement = CoachEntitlement.none;
  CoachApplication? _application;
  bool _showForm = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    if (uid == null) {
      return const Scaffold(
        body: Center(child: Text('Sign in to apply for Coach Mode.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Coach Mode')),
      body: StreamBuilder<CoachEntitlement>(
        stream: _service.watchMyEntitlement(uid),
        builder: (context, entSnap) {
          if (entSnap.hasData) _entitlement = entSnap.data!;
          return StreamBuilder<CoachApplication>(
            stream: _service.watchMyApplication(uid),
            builder: (context, appSnap) {
              if (appSnap.connectionState == ConnectionState.waiting &&
                  _application == null) {
                return const Center(child: CircularProgressIndicator());
              }
              if (appSnap.hasData) _application = appSnap.data;
              final application = _application ?? CoachApplication.none(uid);

              final state = resolveCoachModeScreenState(
                uid: uid,
                entitlement: _entitlement,
                applicationStatus: application.status,
              );

              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                child: _body(state, application),
              );
            },
          );
        },
      ),
    );
  }

  Widget _body(CoachModeScreenState state, CoachApplication application) {
    switch (state) {
      case CoachModeScreenState.superAdmin:
        return const _StatusCard(
          icon: Icons.verified_user,
          color: Colors.amber,
          title: 'You are the GoodLift super admin',
          body: 'You already have full coaching access. Manage coach '
              'applications and coach accounts from Coach Management.',
        );

      case CoachModeScreenState.approvedActive:
        return _StatusCard(
          icon: Icons.check_circle,
          color: Colors.green,
          title: 'Coach Mode is active',
          body: _entitlement.source == CoachEntitlementSource.superAdminGrant
              ? 'Coach Mode was granted to your account. Open the Coach '
                  'Dashboard to invite and manage your athletes.'
              : 'Your application was approved. Open the Coach Dashboard to '
                  'invite and manage your athletes.',
        );

      case CoachModeScreenState.suspended:
        return _StatusCard(
          icon: Icons.pause_circle_filled,
          color: Colors.orange,
          title: 'Coach Mode is suspended',
          body: _entitlement.reason.isNotEmpty
              ? 'Your coach access is temporarily suspended.\n\n'
                  'Reason: ${_entitlement.reason}'
              : 'Your coach access is temporarily suspended. Contact GoodLift '
                  'support if you think this is a mistake.',
        );

      case CoachModeScreenState.revoked:
        return _StatusCard(
          icon: Icons.cancel,
          color: Colors.redAccent,
          title: 'Coach Mode has been revoked',
          body: _entitlement.reason.isNotEmpty
              ? 'Your coach access has been revoked.\n\nReason: ${_entitlement.reason}'
              : 'Your coach access has been revoked. Contact GoodLift support '
                  'if you think this is a mistake.',
        );

      case CoachModeScreenState.submitted:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _StatusCard(
              icon: Icons.hourglass_top,
              color: Colors.lightBlueAccent,
              title: 'Application received',
              body: "We're reviewing your application. You'll see Coach Mode "
                  'unlock here as soon as it is approved.',
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _busy ? null : _withdraw,
              child: const Text('Withdraw application'),
            ),
          ],
        );

      case CoachModeScreenState.moreInfoRequested:
        if (_showForm) return _form(application, resubmitting: true);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusCard(
              icon: Icons.help_outline,
              color: Colors.amberAccent,
              title: 'We need a little more information',
              body: application.infoRequest.isNotEmpty
                  ? application.infoRequest
                  : 'Please review and resubmit your application.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => setState(() => _showForm = true),
              child: const Text('Update and resubmit'),
            ),
          ],
        );

      case CoachModeScreenState.declined:
        if (_showForm) return _form(application, resubmitting: true);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusCard(
              icon: Icons.info_outline,
              color: Colors.redAccent,
              title: 'Application declined',
              body: application.decisionReason.isNotEmpty
                  ? application.decisionReason
                  : 'Your application was not approved at this time.',
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => setState(() => _showForm = true),
              child: const Text('Apply again'),
            ),
          ],
        );

      case CoachModeScreenState.notApplied:
        if (_showForm) return _form(application, resubmitting: false);
        return _intro();
    }
  }

  Widget _intro() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Coach your athletes in GoodLift',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        const Text(
          'Coach Mode lets you invite the athletes you already coach, plan '
          'their blocks, and follow their training and check-ins — with their '
          'permission, and only for as long as they allow it.',
          style: TextStyle(fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 20),
        const _Bullet('Invite athletes by their exact GoodLift email'),
        const _Bullet('Athletes accept, and can revoke access at any time'),
        const _Bullet('Plan blocks and review check-ins for your roster'),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: () => setState(() => _showForm = true),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text('Apply for Coach Mode'),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Applications are reviewed by the GoodLift team. It takes about two '
          'minutes to apply.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _form(CoachApplication application, {required bool resubmitting}) {
    return _CoachApplicationForm(
      initial: resubmitting ? application.answers : const CoachApplicationDraft(),
      busy: _busy,
      onCancel: () => setState(() => _showForm = false),
      onSubmit: _submit,
    );
  }

  Future<void> _submit(CoachApplicationDraft draft) async {
    setState(() => _busy = true);
    try {
      await _service.submitApplication(draft);
      if (!mounted) return;
      setState(() => _showForm = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Application submitted — thanks!')),
      );
    } on CoachModeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _withdraw() async {
    setState(() => _busy = true);
    try {
      await _service.withdrawApplication();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Application withdrawn.')),
      );
    } on CoachModeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ── The form ────────────────────────────────────────────────────────────────

class _CoachApplicationForm extends StatefulWidget {
  const _CoachApplicationForm({
    required this.initial,
    required this.busy,
    required this.onCancel,
    required this.onSubmit,
  });

  final CoachApplicationDraft initial;
  final bool busy;
  final VoidCallback onCancel;
  final Future<void> Function(CoachApplicationDraft) onSubmit;

  @override
  State<_CoachApplicationForm> createState() => _CoachApplicationFormState();
}

class _CoachApplicationFormState extends State<_CoachApplicationForm> {
  late CoachApplicationDraft _draft = widget.initial;
  late final TextEditingController _qualifications =
      TextEditingController(text: widget.initial.qualifications);
  late final TextEditingController _competitionDetails =
      TextEditingController(text: widget.initial.competitionDetails);
  late final TextEditingController _intendedUse =
      TextEditingController(text: widget.initial.intendedUse);
  late final TextEditingController _profileUrl =
      TextEditingController(text: widget.initial.profileUrl);

  // Errors are only shown after the first submit attempt, so the form does not
  // scold someone who has simply not reached a field yet.
  bool _showErrors = false;

  @override
  void dispose() {
    _qualifications.dispose();
    _competitionDetails.dispose();
    _intendedUse.dispose();
    _profileUrl.dispose();
    super.dispose();
  }

  CoachApplicationDraft get _current => _draft.copyWith(
        qualifications: _qualifications.text,
        competitionDetails: _competitionDetails.text,
        intendedUse: _intendedUse.text,
        profileUrl: _profileUrl.text,
      );

  String? _errorFor(String field) {
    if (!_showErrors) return null;
    for (final e in _current.validate()) {
      if (e.field == field) return e.message;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Apply for Coach Mode',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          'Six quick questions.',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        const SizedBox(height: 24),

        _Question(
          'How many athletes do you coach right now?',
          error: _errorFor('athleteCountBand'),
          child: _ChoiceChips(
            options: kAthleteCountBands,
            labels: kAthleteCountBandLabels,
            selected: {
              if (_draft.athleteCountBand != null) _draft.athleteCountBand!
            },
            onTap: (v) => setState(
                () => _draft = _draft.copyWith(athleteCountBand: v)),
          ),
        ),

        _Question(
          'How long have you been coaching?',
          error: _errorFor('experienceBand'),
          child: _ChoiceChips(
            options: kExperienceBands,
            labels: kExperienceBandLabels,
            selected: {
              if (_draft.experienceBand != null) _draft.experienceBand!
            },
            onTap: (v) =>
                setState(() => _draft = _draft.copyWith(experienceBand: v)),
          ),
        ),

        _Question(
          'What do you coach?',
          subtitle: 'Choose all that apply',
          error: _errorFor('coachingFocus'),
          child: _ChoiceChips(
            options: kCoachingFocus,
            labels: kCoachingFocusLabels,
            selected: _draft.coachingFocus,
            multi: true,
            onTap: (v) {
              final next = Set<String>.from(_draft.coachingFocus);
              next.contains(v) ? next.remove(v) : next.add(v);
              setState(() => _draft = _draft.copyWith(coachingFocus: next));
            },
          ),
        ),

        _Question(
          'Have you competed?',
          subtitle: 'Choose all that apply',
          error: _errorFor('competitionExperience'),
          child: _ChoiceChips(
            options: kCompetitionExperience,
            labels: kCompetitionExperienceLabels,
            selected: _draft.competitionExperience,
            multi: true,
            onTap: (v) {
              var next = Set<String>.from(_draft.competitionExperience);
              if (next.contains(v)) {
                next.remove(v);
              } else if (v == 'none') {
                // 'none' is exclusive, matching the server's validation.
                next = {'none'};
              } else {
                next.remove('none');
                next.add(v);
              }
              setState(
                  () => _draft = _draft.copyWith(competitionExperience: next));
            },
          ),
        ),

        _Question(
          'How will you use GoodLift with your athletes?',
          error: _errorFor('intendedUse'),
          child: TextField(
            controller: _intendedUse,
            maxLines: 4,
            maxLength: CoachApplicationLimits.intendedUse,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'e.g. Programming blocks and reviewing weekly '
                  'check-ins for my in-person powerlifting athletes.',
              border: OutlineInputBorder(),
            ),
          ),
        ),

        _Question(
          'Qualifications (optional)',
          error: _errorFor('qualifications'),
          child: TextField(
            controller: _qualifications,
            maxLines: 2,
            maxLength: CoachApplicationLimits.qualifications,
            decoration: const InputDecoration(
              hintText: 'Certifications, federation roles, etc.',
              border: OutlineInputBorder(),
            ),
          ),
        ),

        _Question(
          'Competition details (optional)',
          error: _errorFor('competitionDetails'),
          child: TextField(
            controller: _competitionDetails,
            maxLines: 2,
            maxLength: CoachApplicationLimits.competitionDetails,
            decoration: const InputDecoration(
              hintText: 'Federations, divisions, notable results.',
              border: OutlineInputBorder(),
            ),
          ),
        ),

        _Question(
          'Website or profile link (optional)',
          error: _errorFor('profileUrl'),
          child: TextField(
            controller: _profileUrl,
            keyboardType: TextInputType.url,
            maxLength: CoachApplicationLimits.profileUrl,
            decoration: const InputDecoration(
              hintText: 'https://',
              border: OutlineInputBorder(),
            ),
          ),
        ),

        CheckboxListTile(
          value: _draft.agreesToAthleteConsent,
          onChanged: (v) => setState(() =>
              _draft = _draft.copyWith(agreesToAthleteConsent: v ?? false)),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'I will only invite athletes I genuinely coach, and I will respect '
            'their training data and privacy.',
            style: TextStyle(fontSize: 13),
          ),
        ),
        if (_errorFor('agreesToAthleteConsent') != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              _errorFor('agreesToAthleteConsent')!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ),

        const SizedBox(height: 16),
        FilledButton(
          onPressed: widget.busy ? null : _trySubmit,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(widget.busy ? 'Submitting…' : 'Submit application'),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: widget.busy ? null : widget.onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  void _trySubmit() {
    final draft = _current;
    final errors = draft.validate();
    setState(() => _showErrors = true);
    if (errors.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errors.first.message)),
      );
      return;
    }
    widget.onSubmit(draft);
  }
}

// ── Small shared pieces ─────────────────────────────────────────────────────

class _Question extends StatelessWidget {
  const _Question(this.title, {required this.child, this.subtitle, this.error});
  final String title;
  final String? subtitle;
  final String? error;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(subtitle!,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          const SizedBox(height: 10),
          child,
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(error!,
                  style:
                      const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

class _ChoiceChips extends StatelessWidget {
  const _ChoiceChips({
    required this.options,
    required this.labels,
    required this.selected,
    required this.onTap,
    this.multi = false,
  });

  final List<String> options;
  final Map<String, String> labels;
  final Set<String> selected;
  final ValueChanged<String> onTap;
  final bool multi;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final o in options)
          multi
              ? FilterChip(
                  label: Text(labels[o] ?? o),
                  selected: selected.contains(o),
                  onSelected: (_) => onTap(o),
                )
              : ChoiceChip(
                  label: Text(labels[o] ?? o),
                  selected: selected.contains(o),
                  onSelected: (_) => onTap(o),
                ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(body, style: const TextStyle(fontSize: 14, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check, size: 18, color: Colors.lightBlueAccent),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }
}
