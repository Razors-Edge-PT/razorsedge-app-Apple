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
import 'coach_roster.dart';
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
  final String? rosterName;
  Map<String, dynamic>? report; // current checkpoint report (may be null)
  Map<String, dynamic>? prevReport;
  String? liveLastWeighInKey; // server-derived (coach timezone)
  String? liveWeighInStatus; // 'ok' | 'due' | 'overdue' (server-derived)

  _AthleteReview({required this.uid, required this.settings, this.rosterName});

  String get displayName {
    for (final v in [
      report?['displayName'] as String?,
      settings['displayName'] as String?,
      rosterName,
    ]) {
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return uid;
  }
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
  int _rosterSize = 0;
  bool _contextDegraded = false;

  String get _coachUid => UserContext.of(context, listen: false).actorUid;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _todayKey = CoachCheckinsLogic.dateKey(now);
    // Seed only; _load() replaces this with the server's coach-timezone
    // checkpoint key before anything is fetched or rendered.
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
      final userCtx = UserContext.of(context, listen: false);

      // 1) Shared roster — super-admin gets every athlete, ordinary coaches
      //    only their approved/seeded assignments. Identical source to the
      //    Coach Dashboard and Check-in Athletes screens.
      final roster = await CoachRosterService().loadRoster(userCtx);

      // 2) Per-athlete settings; only reporting-enabled athletes appear here.
      //    Reporting stays off until a coach toggles it on.
      final enabled = <_AthleteReview>[];
      await Future.wait(roster.map((athlete) async {
        try {
          final s = await _db
              .collection('coachCheckIns')
              .doc(coachUid)
              .collection('athletes')
              .doc(athlete.uid)
              .get();
          final data = s.data();
          if (data != null && data['reportingEnabled'] == true) {
            enabled.add(_AthleteReview(
              uid: athlete.uid,
              settings: data,
              rosterName: athlete.label,
            ));
          }
        } catch (e) {
          debugPrint('⚠️ [WeeklyReview] settings read failed for ${athlete.uid}: $e');
        }
      }));
      _rosterSize = roster.length;

      // 3) Server-derived coach-local context: today, checkpoint identity and
      //    live weigh-in staleness, all in the coach's configured timezone.
      //    Non-fatal: if it fails the screen still opens (with a banner) using
      //    device-derived dates, rather than dying with a generic error.
      _contextDegraded = false;
      try {
        final ctxRes = await _functions.httpsCallable('coachReviewContext').call({
          'athleteUids': enabled.map((a) => a.uid).toList(),
        });
        final ctx = Map<String, dynamic>.from(ctxRes.data as Map);
        _timezone = (ctx['timezone'] as String?) ?? _timezone;
        _todayKey = (ctx['todayKey'] as String?) ??
            CoachCheckinsLogic.dateKey(DateTime.now());
        _currentKey = (ctx['currentCheckpointKey'] as String?) ??
            CoachCheckinsLogic.checkpointOnOrBefore(DateTime.now());
        _prevKey = (ctx['prevCheckpointKey'] as String?) ??
            CoachCheckinsLogic.previousCheckpointKey(_currentKey);
        final ctxAthletes =
            Map<String, dynamic>.from(ctx['athletes'] as Map? ?? {});
        for (final a in enabled) {
          final info = ctxAthletes[a.uid];
          if (info is Map) {
            a.liveLastWeighInKey = info['lastWeighInKey'] as String?;
            a.liveWeighInStatus = info['weighInStatus'] as String?;
          }
        }
      } catch (e) {
        debugPrint('⚠️ [WeeklyReview] coachReviewContext unavailable: $e');
        _contextDegraded = true;
        final now = DateTime.now();
        _todayKey = CoachCheckinsLogic.dateKey(now);
        _currentKey = CoachCheckinsLogic.checkpointOnOrBefore(now);
        _prevKey = CoachCheckinsLogic.previousCheckpointKey(_currentKey);
      }

      // 4) Bounded report reads: two direct gets per athlete.
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
        ]);
        a.report = results[0].data();
        a.prevReport = results[1].data();
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
        _error = 'Couldn\'t load the Weekly Review. '
            'Check your connection and tap Refresh to try again.';
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

  /// Server-derived (coach-timezone) staleness; falls back to the report's
  /// generation-time status when the context omitted this athlete.
  String _liveWeighInStatus(_AthleteReview a) =>
      a.liveWeighInStatus ??
      (a.report?['bodyweight']?['weighInStatus'] as String?) ??
      'ok';

  String _draftPreview(_AthleteReview a) {
    final report = a.report;
    if (report == null) return '';
    return CoachCheckinsLogic.visibleMessageText(
      status: report['status'] as String?,
      finalText: report['finalText'] as String?,
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
        return _eventsInWindow(a, 'maxWeightPB').isNotEmpty ||
            _eventsInWindow(a, 'repPB').isNotEmpty ||
            _eventsInWindow(a, 'e1rmPB').isNotEmpty ||
            _eventsInWindow(a, 'rirMatchPB').isNotEmpty;
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
      // The server's finalText is the single source: it is what gets frozen
      // on the report, what goes on the clipboard, and what the card shows —
      // update the visible card to this exact string before anything else.
      setState(() {
        a.report = {
          ...?a.report,
          'status': CheckInStatus.copied,
          'finalText': text,
          if (data['coverageStart'] != null) 'coverageStart': data['coverageStart'],
          if (data['coverageEnd'] != null) 'coverageEnd': data['coverageEnd'],
        };
      });
      await _copyToClipboard(text, a.displayName);
      await _load();
    } on FirebaseFunctionsException catch (e) {
      _showError(_friendlyFunctionsError('Copy', e));
    } catch (e) {
      debugPrint('❌ [WeeklyReview] copy failed: $e');
      _showError('Copy didn\'t go through. Please try again.');
    } finally {
      if (mounted) setState(() => _busy.remove(a.uid));
    }
  }

  /// Puts [text] on the clipboard. On failure the coach is told clearly and
  /// offered the full text to copy manually — we never claim success when
  /// the clipboard write failed.
  Future<void> _copyToClipboard(String text, String athleteName) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text.isEmpty
            ? 'Nothing to send for $athleteName — marked as sent.'
            : 'Message copied for $athleteName.'),
      ));
    } catch (e) {
      debugPrint('❌ [WeeklyReview] clipboard write failed: $e');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Copy to clipboard failed'),
          content: SingleChildScrollView(
            child: SelectableText(
              text.isEmpty ? '(empty message)' : text,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _copyToClipboard(text, athleteName);
              },
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }
  }

  String _friendlyFunctionsError(String action, FirebaseFunctionsException e) {
    debugPrint('❌ [WeeklyReview] $action failed: ${e.code} ${e.message}');
    switch (e.code) {
      case 'failed-precondition':
        return e.message ?? '$action isn\'t possible for this check-in anymore.';
      case 'permission-denied':
        return 'You\'re no longer an assigned coach for this athlete.';
      case 'not-found':
        return 'This report isn\'t available yet — try Refresh.';
      case 'unauthenticated':
        return 'Please sign in again.';
      default:
        return '$action didn\'t go through. Please try again.';
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
      _showError(_friendlyFunctionsError('Undo', e));
    } catch (e) {
      debugPrint('❌ [WeeklyReview] undo failed: $e');
      _showError('Undo didn\'t go through. Please try again.');
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
      _showError(_friendlyFunctionsError('Skip', e));
    } catch (e) {
      debugPrint('❌ [WeeklyReview] skip failed: $e');
      _showError('Skip didn\'t go through. Please try again.');
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
                              'Checkpoint ${_weekdayLabel(_currentKey)} $_currentKey'
                              ' · today $_todayKey',
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
                    if (_contextDegraded)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.amber.withValues(alpha: 0.5)),
                        ),
                        child: Text(
                          'Live coach-timezone context is unavailable, so dates below '
                          'come from this device. Tap Refresh to retry.',
                          style: TextStyle(
                              color: Colors.amber[200], fontSize: 12),
                        ),
                      ),
                    Expanded(
                      child: _athletes.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.fact_check_outlined,
                                        size: 40, color: Colors.white38),
                                    const SizedBox(height: 12),
                                    const Text(
                                      'No athletes enabled for check-ins yet',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      _rosterSize == 0
                                          ? 'No athletes are assigned to you yet. '
                                              'Add athletes from the Coach Dashboard first.'
                                          : 'Reporting is off for all $_rosterSize of your athletes. '
                                              'Open Check-in Athletes to enable the ones you are '
                                              'actively coaching — reports then run every Monday '
                                              'and Thursday.',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: Colors.white70, fontSize: 13),
                                    ),
                                    const SizedBox(height: 16),
                                    ElevatedButton.icon(
                                      icon: const Icon(Icons.tune, size: 16),
                                      label: const Text('Open Check-in Athletes'),
                                      onPressed: () async {
                                        await Navigator.of(context).push(
                                            MaterialPageRoute(
                                          builder: (_) =>
                                              ChangeNotifierProvider<UserContext>.value(
                                            value: context.read<UserContext>(),
                                            child:
                                                const CoachCheckinAthletesScreen(),
                                          ),
                                        ));
                                        _load();
                                      },
                                    ),
                                  ],
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
    final maxWeightPBs = _eventsInWindow(a, 'maxWeightPB');
    final repPBs = _eventsInWindow(a, 'repPB');
    final e1rmPBs = _eventsInWindow(a, 'e1rmPB');
    final rirMatchPBs = _eventsInWindow(a, 'rirMatchPB');
    // A set that is both an all-time heaviest lift and a rep-target PB is ONE
    // achievement (the backend praises it once, as the heaviest lift), so the
    // rep-PB evidence list hides the duplicate rather than showing it twice.
    final maxWeightKeys = maxWeightPBs
        .map((e) => '${e['exerciseId']}_${e['dateKey']}')
        .toSet();
    final repOnlyPBs = repPBs
        .where((e) => !maxWeightKeys.contains('${e['exerciseId']}_${e['dateKey']}'))
        .toList();
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
                if (maxWeightPBs.isNotEmpty)
                  _fact(Icons.military_tech,
                      '${maxWeightPBs.length} all-time heaviest'),
                _fact(Icons.emoji_events,
                    '${repOnlyPBs.length} rep PB${repOnlyPBs.length == 1 ? '' : 's'}'),
                _fact(Icons.trending_up, '${e1rmPBs.length} E1RM PB${e1rmPBs.length == 1 ? '' : 's'}'),
                if (rirMatchPBs.isNotEmpty)
                  _fact(Icons.bolt,
                      '${rirMatchPBs.length} PB match at lower RIR'),
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
                  // milestoneAwarded is phase-scoped ('cut_110@<phase>');
                  // show only the objective boundary part.
                  _fact(
                      Icons.celebration,
                      'Milestone ${(report?['milestoneAwarded'] ?? bodyweight?['newMilestoneId']).toString().split('@').first}'),
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
            if (maxWeightPBs.isNotEmpty ||
                repOnlyPBs.isNotEmpty ||
                e1rmPBs.isNotEmpty ||
                rirMatchPBs.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final e in maxWeightPBs)
                Text(
                  '• ${e['exerciseName']}: all-time heaviest ${e['weightKg']}kg × ${e['reps']} '
                  '(prev ${e['prevWeightKg']}kg)',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              for (final e in repOnlyPBs)
                Text(
                  '• ${e['exerciseName']}: ${e['weightKg']}kg × ${e['reps']} '
                  '(prev ${e['prevWeightKg']}kg at ≥ ${e['reps']} reps)',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              for (final e in e1rmPBs)
                Text(
                  '• ${e['exerciseName']}: E1RM ${(e['e1rmKg'] as num).toStringAsFixed(1)}kg '
                  '(prev ${(e['prevE1rmKg'] as num).toStringAsFixed(1)}kg, no RIR)',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              for (final e in rirMatchPBs)
                Text(
                  '• ${e['exerciseName']}: matched ${e['weightKg']}kg × ${e['reps']} '
                  'at RIR ${e['rir']} (prev RIR ${e['prevRir']}) — effort, not a new PB',
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
                  color: Colors.black.withValues(alpha: 0.25),
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
                  IconButton(
                    tooltip: 'Copy the sent message again',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.copy, size: 16, color: Colors.white70),
                    onPressed: busy
                        ? null
                        : () => _copyToClipboard(
                            (report['finalText'] as String?) ?? '',
                            a.displayName),
                  ),
                  const SizedBox(width: 4),
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
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.6)),
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
        color: Colors.red.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.6)),
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
  String? _error;
  // Shared roster (super-admin: all users; coach: approved + seeded).
  final List<CoachAthlete> _roster = [];
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
      final ctx = UserContext.of(context, listen: false);

      // Shared roster: super-admin gets the full user roster (same as Coach
      // Dashboard); ordinary coaches get only their approved/seeded athletes.
      final roster = await CoachRosterService().loadRoster(ctx);
      _roster
        ..clear()
        ..addAll(roster);

      // Existing per-athlete settings (absent = reporting off, the default).
      await Future.wait(roster.map((a) async {
        try {
          final s = await _db
              .collection('coachCheckIns')
              .doc(coachUid)
              .collection('athletes')
              .doc(a.uid)
              .get();
          final data = s.data();
          if (data != null) _settings[a.uid] = Map<String, dynamic>.from(data);
        } catch (e) {
          debugPrint('⚠️ [CheckinAthletes] settings read failed for ${a.uid}: $e');
        }
      }));

      if (mounted) setState(() => _loading = false);
    } catch (e) {
      debugPrint('❌ [CheckinAthletes] load failed: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Couldn\'t load your athlete list. Tap refresh to try again.';
        });
      }
    }
  }

  Future<void> _save(String uid, Map<String, dynamic> patch) async {
    final name = _roster
        .firstWhere((a) => a.uid == uid,
            orElse: () => CoachAthlete(uid: uid))
        .label;
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Check-in Athletes'),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
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
              : _roster.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No athletes are assigned to you yet.\n'
                          'Add athletes from the Coach Dashboard first.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    )
                  : ListView.separated(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
              itemCount: _roster.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, i) {
                final athlete = _roster[i];
                final uid = athlete.uid;
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
                            athlete.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(athlete.email,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
                                onChanged: (v) {
                                  if (v == null || v == goal) return;
                                  // The server stamps the milestone goal
                                  // phase (goalSetAt) when it sees the goal
                                  // change — clients cannot manufacture
                                  // phases to repeat milestone praise.
                                  _save(uid, {'goal': v});
                                },
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
