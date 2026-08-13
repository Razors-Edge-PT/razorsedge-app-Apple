// Coach Weekly Review / Check-ins screen.
//
// Coach-only. Reads the server-generated checkpoint reports under
// coachCheckIns/{coachUid}/reports, shows a compact per-athlete summary and
// the prepared client draft, and drives the copy / undo / skip workflow via
// the coachPrepareCheckInCopy / coachUndoCheckIn / coachSkipCheckIn
// callables. Enabling athletes and per-athlete goal/message settings live in
// coachCheckIns/{coachUid}/athletes/{athleteUid}.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'coach_checkins_logic.dart';
import 'user_context.dart';

const List<String> kCoachTimezones = [
  'Pacific/Auckland',
  'Australia/Sydney',
  'Australia/Brisbane',
  'Australia/Perth',
  'Europe/London',
  'America/New_York',
  'America/Chicago',
  'America/Denver',
  'America/Los_Angeles',
];

class CoachWeeklyReviewScreen extends StatefulWidget {
  const CoachWeeklyReviewScreen({super.key});

  @override
  State<CoachWeeklyReviewScreen> createState() => _CoachWeeklyReviewScreenState();
}

enum _ReviewFilter { all, ready, needsWeighIn, pbs, noTraining }

class _AthleteReview {
  final String uid;
  final Map<String, dynamic> settings;
  Map<String, dynamic>? report; // current checkpoint report (may be null)
  Map<String, dynamic>? prevReport;
  String? liveLastWeighInKey;

  _AthleteReview({required this.uid, required this.settings});

  String get displayName =>
      (report?['displayName'] as String?) ??
      (settings['displayName'] as String?) ??
      uid;
}

class _CoachWeeklyReviewScreenState extends State<CoachWeeklyReviewScreen> {
  final _db = FirebaseFirestore.instance;
  final _functions = FirebaseFunctions.instance;

  bool _loading = true;
  String? _error;
  String _timezone = 'Pacific/Auckland';
  late String _currentKey;
  late String _prevKey;
  String _todayKey = CoachCheckinsLogic.dateKey(DateTime.now());
  List<_AthleteReview> _athletes = [];
  _ReviewFilter _filter = _ReviewFilter.all;
  final Set<String> _busy = {};

  String get _coachUid => UserContext.of(context, listen: false).actorUid;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _todayKey = CoachCheckinsLogic.dateKey(now);
    _currentKey = CoachCheckinsLogic.checkpointOnOrBefore(now);
    _prevKey = CoachCheckinsLogic.previousCheckpointKey(_currentKey);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final coachUid = _coachUid;
      final coachDoc = await _db.collection('coachCheckIns').doc(coachUid).get();
      _timezone = (coachDoc.data()?['timezone'] as String?) ?? 'Pacific/Auckland';

      final athletesSnap = await _db
          .collection('coachCheckIns')
          .doc(coachUid)
          .collection('athletes')
          .get();

      final enabled = <_AthleteReview>[];
      for (final doc in athletesSnap.docs) {
        final data = doc.data();
        if (data['reportingEnabled'] == true) {
          enabled.add(_AthleteReview(uid: doc.id, settings: data));
        }
      }

      // Bounded reads: two report direct-gets + one latest weigh-in per athlete.
      await Future.wait(enabled.map((a) async {
        final results = await Future.wait([
          _db
              .collection('coachCheckIns')
              .doc(coachUid)
              .collection('reports')
              .doc('${a.uid}_$_currentKey')
              .get(),
          _db
              .collection('coachCheckIns')
              .doc(coachUid)
              .collection('reports')
              .doc('${a.uid}_$_prevKey')
              .get(),
          _db
              .collection('users')
              .doc(a.uid)
              .collection('weights')
              .orderBy('timestamp', descending: true)
              .limit(1)
              .get(),
        ]);
        final cur = results[0] as DocumentSnapshot<Map<String, dynamic>>;
        final prev = results[1] as DocumentSnapshot<Map<String, dynamic>>;
        final w = results[2] as QuerySnapshot<Map<String, dynamic>>;
        a.report = cur.data();
        a.prevReport = prev.data();
        if (w.docs.isNotEmpty) {
          final ts = w.docs.first.data()['timestamp'];
          if (ts is Timestamp) {
            a.liveLastWeighInKey = CoachCheckinsLogic.dateKey(ts.toDate());
          }
        }
      }));

      enabled.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _athletes = enabled;
        _loading = false;
      });
    } catch (e) {
      debugPrint('❌ [WeeklyReview] load failed: $e');
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load check-ins: $e';
        _loading = false;
      });
    }
  }

  // ── Report helpers ─────────────────────────────────────────────────────────

  bool _prevWasCopied(_AthleteReview a) =>
      (a.prevReport?['status'] as String?) == CheckInStatus.copied;

  ({String start, String end}) _coverage(_AthleteReview a) {
    return CoachCheckinsLogic.effectiveCoverage(
      _currentKey,
      previousWasCopied: _prevWasCopied(a),
      lastFinalizedCoverageEnd: a.settings['lastFinalizedCoverageEnd'] as String?,
    );
  }

  List<Map<String, dynamic>> _eventsInWindow(_AthleteReview a, String type) {
    final report = a.report;
    if (report == null) return const [];
    final status = report['status'] as String?;
    final String start;
    final String end;
    if (status == CheckInStatus.copied && report['coverageStart'] != null) {
      start = report['coverageStart'] as String;
      end = report['coverageEnd'] as String;
    } else {
      final c = _coverage(a);
      start = c.start;
      end = c.end;
    }
    final events = (report['events'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((e) =>
            e['type'] == type &&
            (e['dateKey'] as String? ?? '').compareTo(start) >= 0 &&
            (e['dateKey'] as String? ?? '').compareTo(end) < 0)
        .toList();
    return events;
  }

  int _workoutsInWindow(_AthleteReview a) {
    final report = a.report;
    if (report == null) return 0;
    final c = _coverage(a);
    return (report['workoutDates'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .where((d) => d.compareTo(c.start) >= 0 && d.compareTo(c.end) < 0)
        .length;
  }

  String _liveWeighInStatus(_AthleteReview a) => CoachCheckinsLogic.weighInStatus(
      a.liveLastWeighInKey ?? (a.report?['bodyweight']?['lastWeighInKey'] as String?),
      _todayKey);

  String _draftPreview(_AthleteReview a) {
    final report = a.report;
    if (report == null) return '';
    if (report['status'] == CheckInStatus.copied) {
      return (report['finalText'] as String?) ?? '';
    }
    return CoachCheckinsLogic.pickDraftPreview(
      previousWasCopied: _prevWasCopied(a),
      draftIfPrevCopied: report['draftIfPrevCopied'] as String?,
      draftIfPrevNotCopied: report['draftIfPrevNotCopied'] as String?,
    );
  }

  bool _matchesFilter(_AthleteReview a) {
    switch (_filter) {
      case _ReviewFilter.all:
        return true;
      case _ReviewFilter.ready:
        return a.report != null &&
            a.report!['status'] == CheckInStatus.draft &&
            _draftPreview(a).isNotEmpty;
      case _ReviewFilter.needsWeighIn:
        return _liveWeighInStatus(a) != 'ok';
      case _ReviewFilter.pbs:
        return _eventsInWindow(a, 'repPB').isNotEmpty ||
            _eventsInWindow(a, 'e1rmPB').isNotEmpty;
      case _ReviewFilter.noTraining:
        return a.report != null && _workoutsInWindow(a) == 0;
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _copyMessage(_AthleteReview a) async {
    if (_busy.contains(a.uid)) return;
    setState(() => _busy.add(a.uid));
    try {
      final res = await _functions.httpsCallable('coachPrepareCheckInCopy').call({
        'athleteUid': a.uid,
        'checkpointKey': _currentKey,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      final text = (data['text'] as String?) ?? '';
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text.isEmpty
            ? 'Nothing to send for ${a.displayName} — marked as copied.'
            : 'Message copied for ${a.displayName}.'),
      ));
      await _load();
    } on FirebaseFunctionsException catch (e) {
      _showError('Copy failed: ${e.message ?? e.code}');
    } catch (e) {
      _showError('Copy failed: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(a.uid));
    }
  }

  Future<void> _undo(_AthleteReview a) async {
    if (_busy.contains(a.uid)) return;
    setState(() => _busy.add(a.uid));
    try {
      await _functions.httpsCallable('coachUndoCheckIn').call({
        'athleteUid': a.uid,
        'checkpointKey': _currentKey,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Marked not sent for ${a.displayName}.')));
      await _load();
    } on FirebaseFunctionsException catch (e) {
      _showError('Undo failed: ${e.message ?? e.code}');
    } catch (e) {
      _showError('Undo failed: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(a.uid));
    }
  }

  Future<void> _skip(_AthleteReview a) async {
    if (_busy.contains(a.uid)) return;
    setState(() => _busy.add(a.uid));
    try {
      await _functions.httpsCallable('coachSkipCheckIn').call({
        'athleteUid': a.uid,
        'checkpointKey': _currentKey,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Check-in skipped for ${a.displayName}.')));
      await _load();
    } on FirebaseFunctionsException catch (e) {
      _showError('Skip failed: ${e.message ?? e.code}');
    } catch (e) {
      _showError('Skip failed: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(a.uid));
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _editTimezone() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Coach timezone'),
        children: [
          for (final tz in kCoachTimezones)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, tz),
              child: Row(
                children: [
                  Expanded(child: Text(tz)),
                  if (tz == _timezone) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == _timezone) return;
    try {
      await _db.collection('coachCheckIns').doc(_coachUid).set({
        'timezone': picked,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      setState(() => _timezone = picked);
    } catch (e) {
      _showError('Failed to save timezone: $e');
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final userContext = UserContext.maybeOf(context);
    if (userContext == null || !userContext.isCoach) {
      return const Scaffold(
        body: Center(child: Text('Coach access only.')),
      );
    }

    final filtered = _athletes.where(_matchesFilter).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Weekly Review'),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Coach timezone ($_timezone)',
            icon: const Icon(Icons.schedule),
            onPressed: _editTimezone,
          ),
          IconButton(
            tooltip: 'Manage monitored athletes',
            icon: const Icon(Icons.tune),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider<UserContext>.value(
                  value: context.read<UserContext>(),
                  child: const CoachCheckinAthletesScreen(),
                ),
              ));
              _load();
            },
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Checkpoint ${_weekdayLabel(_currentKey)} $_currentKey',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13),
                            ),
                          ),
                          Text(_timezone,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 11)),
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 42,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        children: [
                          _filterChip('All', _ReviewFilter.all),
                          _filterChip('Ready', _ReviewFilter.ready),
                          _filterChip('Needs weigh-in', _ReviewFilter.needsWeighIn),
                          _filterChip('PBs', _ReviewFilter.pbs),
                          _filterChip('No training', _ReviewFilter.noTraining),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _athletes.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: Text(
                                  'No athletes enabled for check-ins yet.\n'
                                  'Use the settings icon (top right) to enable reporting '
                                  'for the athletes you are actively coaching.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.white70),
                                ),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(8, 6, 8, 24),
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 6),
                              itemBuilder: (context, i) => _athleteCard(filtered[i]),
                            ),
                    ),
                  ],
                ),
    );
  }

  Widget _filterChip(String label, _ReviewFilter value) {
    final selected = _filter == value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _filter = value),
      ),
    );
  }

  String _weekdayLabel(String key) {
    final wd = CoachCheckinsLogic.parseKey(key).weekday;
    return wd == DateTime.monday ? 'Monday' : 'Thursday';
  }

  Widget _athleteCard(_AthleteReview a) {
    final theme = Theme.of(context);
    final report = a.report;
    final status = report?['status'] as String? ?? 'pending';
    final coverage = _coverage(a);
    final repPBs = _eventsInWindow(a, 'repPB');
    final e1rmPBs = _eventsInWindow(a, 'e1rmPB');
    final workouts = _workoutsInWindow(a);
    final completion = report?['completion'] as Map<String, dynamic>?;
    final bodyweight = report?['bodyweight'] as Map<String, dynamic>?;
    final fallbackWeek = report?['fallbackWeek'] as Map<String, dynamic>?;
    final weighStatus = _liveWeighInStatus(a);
    final draft = _draftPreview(a);
    final busy = _busy.contains(a.uid);

    final statusByKey = <String, String>{
      if (report != null) _currentKey: status,
      if (a.prevReport != null) _prevKey: a.prevReport!['status'] as String? ?? 'draft',
    };
    final mutable = CoachCheckinsLogic.canMutate(_currentKey, statusByKey);

    return Card(
      elevation: 0,
      color: theme.cardTheme.color ?? theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    a.displayName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _statusChip(status),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Coverage ${coverage.start} → ${coverage.end}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                _fact(Icons.emoji_events, '${repPBs.length} rep PB${repPBs.length == 1 ? '' : 's'}'),
                _fact(Icons.trending_up, '${e1rmPBs.length} E1RM PB${e1rmPBs.length == 1 ? '' : 's'}'),
                _fact(
                  Icons.fitness_center,
                  completion != null
                      ? '$workouts done · week ${completion['completedCount']}/${completion['plannedCount']} planned'
                      : '$workouts workouts',
                ),
                if (bodyweight?['currentAvg'] != null)
                  _fact(Icons.monitor_weight,
                      '7d avg ${bodyweight!['currentAvg']} kg · ${_trendLabel(bodyweight)}'),
                if (bodyweight?['newMilestoneId'] != null ||
                    report?['milestoneAwarded'] != null)
                  _fact(Icons.celebration,
                      'Milestone ${(report?['milestoneAwarded'] ?? bodyweight?['newMilestoneId'])}'),
                if (weighStatus != 'ok')
                  _warn(weighStatus == 'due' ? 'Weigh-in due' : 'Weigh-in overdue'),
              ],
            ),
            if (fallbackWeek != null && workouts == 0) ...[
              const SizedBox(height: 6),
              Text(
                'No training logged in the latest period — showing most recent '
                'trained week: ${fallbackWeek['weekStart']} → ${fallbackWeek['weekEnd']}.',
                style: TextStyle(color: Colors.amber[200], fontSize: 12),
              ),
            ],
            if (repPBs.isNotEmpty || e1rmPBs.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final e in repPBs)
                Text(
                  '• ${e['exerciseName']}: ${e['weightKg']}kg × ${e['reps']} '
                  '(prev ${e['prevWeightKg']}kg)',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              for (final e in e1rmPBs)
                Text(
                  '• ${e['exerciseName']}: E1RM ${(e['e1rmKg'] as num).toStringAsFixed(1)}kg '
                  '(prev ${(e['prevE1rmKg'] as num).toStringAsFixed(1)}kg, no RIR)',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
            ],
            const SizedBox(height: 8),
            if (report == null)
              const Text(
                'Report not generated yet — reports run on Monday and Thursday.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              )
            else if (draft.isEmpty)
              const Text(
                'No client message for this window (no praise-worthy training and '
                'nothing to say about bodyweight).',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              )
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white12),
                ),
                child: Text(draft,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (report != null && status == CheckInStatus.draft)
                  ElevatedButton.icon(
                    onPressed: busy || !mutable ? null : () => _copyMessage(a),
                    icon: busy
                        ? const SizedBox(
                            width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.copy, size: 16),
                    label: const Text('Copy Message'),
                  ),
                if (report != null && status == CheckInStatus.copied) ...[
                  Icon(Icons.check_circle,
                      size: 18, color: Theme.of(context).colorScheme.secondary),
                  const SizedBox(width: 6),
                  const Text('Copied',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: busy || !mutable ? null : () => _undo(a),
                    child: const Text('Undo / Mark Not Sent'),
                  ),
                ],
                const Spacer(),
                if (report != null && status == CheckInStatus.draft)
                  TextButton(
                    onPressed: busy ? null : () => _skip(a),
                    child: const Text('Skip'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _trendLabel(Map<String, dynamic> bw) {
    switch (bw['trend'] as String?) {
      case 'onTrack':
        return bw['goal'] == 'bulk' ? 'going up 👍' : 'coming down 👍';
      case 'offTrack':
        return bw['goal'] == 'bulk' ? 'not going up' : 'not coming down';
      case 'stable':
        return 'stable';
      case 'driftUp':
        return 'drifting up';
      case 'driftDown':
        return 'drifting down';
      default:
        return 'not enough data';
    }
  }

  Widget _statusChip(String status) {
    Color color;
    String label;
    switch (status) {
      case CheckInStatus.copied:
        color = Colors.green;
        label = 'Copied';
        break;
      case CheckInStatus.skipped:
        color = Colors.blueGrey;
        label = 'Skipped';
        break;
      case CheckInStatus.expired:
        color = Colors.brown;
        label = 'Expired';
        break;
      case CheckInStatus.draft:
        color = Colors.orange;
        label = 'Draft';
        break;
      default:
        color = Colors.white24;
        label = 'Pending';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11)),
    );
  }

  Widget _fact(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.white54),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }

  Widget _warn(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.redAccent.withOpacity(0.6)),
      ),
      child: Text(text,
          style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Athlete monitoring settings
// ═══════════════════════════════════════════════════════════════════════════

class CoachCheckinAthletesScreen extends StatefulWidget {
  const CoachCheckinAthletesScreen({super.key});

  @override
  State<CoachCheckinAthletesScreen> createState() =>
      _CoachCheckinAthletesScreenState();
}

class _CoachCheckinAthletesScreenState
    extends State<CoachCheckinAthletesScreen> {
  final _db = FirebaseFirestore.instance;
  bool _loading = true;
  // uid -> {name, email}
  final Map<String, Map<String, String>> _assigned = {};
  // uid -> settings doc data
  final Map<String, Map<String, dynamic>> _settings = {};

  String get _coachUid => UserContext.of(context, listen: false).actorUid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final coachUid = _coachUid;

      // Same two assignment sources CoachHomeScreen uses.
      final q1 = await _db
          .collection('athleteAssignments')
          .where('coaches.$coachUid.approved', isEqualTo: true)
          .get();
      for (final doc in q1.docs) {
        _assigned[doc.id] = {};
      }
      final doc2 = await _db.collection('coachAssignments').doc(coachUid).get();
      if (doc2.exists) {
        final seeded = Map<String, dynamic>.from(doc2.data()?['athletes'] ?? {});
        for (final e in seeded.entries) {
          _assigned.putIfAbsent(e.key, () => {
                'email': (e.value is Map ? e.value['email'] ?? '' : '').toString(),
              });
        }
      }

      // Hydrate names + existing settings.
      await Future.wait(_assigned.keys.map((uid) async {
        final results = await Future.wait([
          _db.collection('users').doc(uid).get(),
          _db
              .collection('coachCheckIns')
              .doc(coachUid)
              .collection('athletes')
              .doc(uid)
              .get(),
        ]);
        final u = results[0].data() ?? {};
        final name = (u['username'] ?? u['displayName'] ?? u['fullName'] ?? '')
            .toString()
            .trim();
        _assigned[uid] = {
          'name': name,
          'email': (u['email'] ?? _assigned[uid]?['email'] ?? '').toString(),
        };
        final s = results[1].data();
        if (s != null) _settings[uid] = Map<String, dynamic>.from(s);
      }));

      if (mounted) setState(() => _loading = false);
    } catch (e) {
      debugPrint('❌ [CheckinAthletes] load failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(String uid, Map<String, dynamic> patch) async {
    final name = _assigned[uid]?['name'] ?? '';
    try {
      await _db
          .collection('coachCheckIns')
          .doc(_coachUid)
          .collection('athletes')
          .doc(uid)
          .set({
        ...patch,
        if (name.isNotEmpty) 'displayName': name,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      setState(() {
        _settings[uid] = {...?_settings[uid], ...patch};
      });
    } catch (e) {
      debugPrint('❌ [CheckinAthletes] save failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
  }

  Future<void> _pickCustomExercises(String uid) async {
    // Exercise list comes from the athlete's server-built analytics docs
    // (small, coach-readable) — no workout scanning.
    final snap = await _db
        .collection('coachAnalytics')
        .doc(uid)
        .collection('exercises')
        .get();
    if (!mounted) return;
    final all = <String, String>{
      for (final d in snap.docs) d.id: (d.data()['name'] ?? d.id).toString(),
    };
    final selected = Set<String>.from(
        (_settings[uid]?['customExerciseIds'] as List<dynamic>? ?? const [])
            .whereType<String>());

    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) {
        final local = Set<String>.from(selected);
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: const Text('Message exercises'),
            content: SizedBox(
              width: 340,
              height: 400,
              child: all.isEmpty
                  ? const Center(
                      child: Text(
                          'No analysed exercises yet.\nEnable reporting first — '
                          'the bootstrap builds the exercise list.'))
                  : ListView(
                      children: [
                        for (final e in all.entries)
                          CheckboxListTile(
                            dense: true,
                            value: local.contains(e.key),
                            title: Text(e.value,
                                style: const TextStyle(fontSize: 13)),
                            onChanged: (v) => setLocal(() {
                              if (v == true) {
                                local.add(e.key);
                              } else {
                                local.remove(e.key);
                              }
                            }),
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, local),
                  child: const Text('Save')),
            ],
          ),
        );
      },
    );
    if (result != null) {
      await _save(uid, {'customExerciseIds': result.toList()..sort()});
    }
  }

  @override
  Widget build(BuildContext context) {
    final uids = _assigned.keys.toList()
      ..sort((a, b) => (_assigned[a]?['name'] ?? '')
          .toLowerCase()
          .compareTo((_assigned[b]?['name'] ?? '').toLowerCase()));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Check-in Athletes'),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
              itemCount: uids.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, i) {
                final uid = uids[i];
                final info = _assigned[uid] ?? {};
                final s = _settings[uid] ?? {};
                final enabled = s['reportingEnabled'] == true;
                final goal = (s['goal'] as String?) ?? 'maintain';
                final mode = (s['messageExerciseMode'] as String?) ?? 'automatic';
                final customCount =
                    (s['customExerciseIds'] as List<dynamic>? ?? const []).length;

                return Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(
                            (info['name']?.isNotEmpty ?? false)
                                ? info['name']!
                                : (info['email'] ?? uid),
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(info['email'] ?? '',
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                          value: enabled,
                          onChanged: (v) => _save(uid, {
                            'reportingEnabled': v,
                            if (v && s['goal'] == null) 'goal': 'maintain',
                            if (v && s['messageExerciseMode'] == null)
                              'messageExerciseMode': 'automatic',
                            if (v) 'enabledAt': DateTime.now().toIso8601String(),
                          }),
                        ),
                        if (enabled)
                          Row(
                            children: [
                              DropdownButton<String>(
                                value: goal,
                                dropdownColor:
                                    Theme.of(context).colorScheme.surface,
                                items: const [
                                  DropdownMenuItem(
                                      value: 'cut', child: Text('Cutting')),
                                  DropdownMenuItem(
                                      value: 'bulk', child: Text('Bulking')),
                                  DropdownMenuItem(
                                      value: 'maintain',
                                      child: Text('Maintaining')),
                                ],
                                onChanged: (v) =>
                                    v == null ? null : _save(uid, {'goal': v}),
                              ),
                              const SizedBox(width: 16),
                              DropdownButton<String>(
                                value: mode,
                                dropdownColor:
                                    Theme.of(context).colorScheme.surface,
                                items: const [
                                  DropdownMenuItem(
                                      value: 'automatic',
                                      child: Text('Auto lifts')),
                                  DropdownMenuItem(
                                      value: 'custom',
                                      child: Text('Custom lifts')),
                                ],
                                onChanged: (v) => v == null
                                    ? null
                                    : _save(uid, {'messageExerciseMode': v}),
                              ),
                              const Spacer(),
                              if (mode == 'custom')
                                TextButton(
                                  onPressed: () => _pickCustomExercises(uid),
                                  child: Text('Lifts ($customCount)'),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
