// Coach Weekly Review / Check-ins screen.
//
// Coach-only. Reads the server-generated checkpoint reports under
// coachCheckIns/{coachUid}/reports, shows a compact per-athlete summary and
// the prepared client draft, and drives the copy / undo / skip workflow via
// the coachPrepareCheckInCopy / coachUndoCheckIn / coachSkipCheckIn
// callables. Enabling athletes and per-athlete goal/message settings live in
// coachCheckIns/{coachUid}/athletes/{athleteUid}.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'profile/ui/live_identity.dart';

import 'bb3_week_planner.dart';
import 'coach_checkin_copy_action.dart';
import 'coach_checkins_logic.dart';
import 'coach_roster.dart';
import 'user_context.dart';

/// A PB load as the coach reads it. A bodyweight exercise's event (Chin-Up,
/// Pull-Up, Dips …) carries the bodyweight its totals were computed at and
/// reads as the load ADDED to it ("+60kg", "BW"); every other event reads
/// exactly as before ("145kg").
String _pbLoad(Map<dynamic, dynamic> e, Object? kg) {
  final Object? bw = e['bodyweightKg'];
  if (kg is num && bw is num && bw > 0) {
    final double r = ((kg - bw) * 10).roundToDouble() / 10;
    if (r == 0) return 'BW';
    final double a = r.abs();
    final String v =
        a == a.roundToDouble() ? a.toStringAsFixed(0) : a.toStringAsFixed(1);
    return '${r > 0 ? '+' : '−'}${v}kg';
  }
  return '${kg}kg';
}

/// A PREVIOUS load on a PB line: for a bodyweight exercise it is a total at an
/// earlier bodyweight, so it says so.
String _pbPrev(Map<dynamic, dynamic> e, Object? kg) =>
    e['bodyweightKg'] is num ? '${kg}kg total' : '${kg}kg';

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

// ═══════════════════════════════════════════════════════════════════════════
// Athlete week-planner navigation
// ═══════════════════════════════════════════════════════════════════════════

/// Pushes the existing BB3 Week Planner for whoever [userContext] is currently
/// acting as. This is verbatim the mechanism the Coach Dashboard and the app
/// drawer already use — same screen, same provider wiring — so there is only
/// ever one planner implementation.
Future<void> pushBB3WeekPlanner(
    BuildContext context, UserContext userContext) async {
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ChangeNotifierProvider<UserContext>.value(
      value: userContext,
      child: const BB3WeekPlanner(),
    ),
  ));
}

/// Seam so tests can assert the navigation without mounting the Firebase-backed
/// planner screen.
typedef PlannerPusher = Future<void> Function(
    BuildContext context, UserContext userContext);

/// Opens [athleteUid]'s BB3 Week Planner on their current week.
///
/// Coach Mode already models "which athlete am I looking at" as
/// [UserContext.actingAsUid], and BB3WeekPlanner reads exactly that. So this
/// switches the acting athlete to the card's uid — never the signed-in
/// coach's — and pushes the existing planner, which resolves the current week
/// itself (it opens on the calendar week of the athlete's active block; no
/// Monday / current-week arithmetic is duplicated here).
///
/// Navigation only: nothing about the workout, planner or report data is
/// mutated. Missing athlete context is reported instead of crashing.
Future<void> openAthleteWeekPlanner(
  BuildContext context, {
  required String athleteUid,
  String? athleteName,
  PlannerPusher pushPlanner = pushBB3WeekPlanner,
}) async {
  // listen: false — this runs from a tap handler, not a build.
  final userContext = UserContext.maybeOf(context, listen: false);
  if (userContext == null || athleteUid.trim().isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          'Can\'t open the week planner for ${athleteName ?? 'this athlete'} '
          'yet — their training context isn\'t available.'),
    ));
    return;
  }
  // The same call the Coach Dashboard makes when a coach taps an athlete row.
  userContext.switchAthlete(athleteUid);
  await pushPlanner(context, userContext);
}

class CoachWeeklyReviewScreen extends StatefulWidget {
  const CoachWeeklyReviewScreen({super.key});

  @override
  State<CoachWeeklyReviewScreen> createState() =>
      _CoachWeeklyReviewScreenState();
}

enum _ReviewFilter { all, ready, needsWeighIn, pbs, noTraining }

/// One athlete's row of the Weekly Review, plus the derived read-only views
/// the card and the filters need. Public so the card widget — and its tests —
/// can build one without the screen.
class AthleteReview {
  final String uid;
  Map<String, dynamic> settings;
  final String? rosterName;
  Map<String, dynamic>? report; // current checkpoint report (may be null)
  Map<String, dynamic>? prevReport;
  String? liveLastWeighInKey; // server-derived (coach timezone)
  String? liveWeighInStatus; // 'ok' | 'due' | 'overdue' (server-derived)
  /// Set when this athlete's report documents could not be read. The card
  /// still renders (saying so) instead of the whole screen failing.
  String? reportLoadError;

  AthleteReview({required this.uid, required this.settings, this.rosterName});

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

  String get status => report?['status'] as String? ?? 'pending';

  bool get prevWasCopied =>
      (prevReport?['status'] as String?) == CheckInStatus.copied;

  /// The window this card describes.
  ///
  /// Once a report is copied the server has FROZEN its coverage, so the frozen
  /// pair is the answer — recomputing would re-apply the clamp that same copy
  /// just wrote (`lastFinalizedCoverageEnd == checkpointKey`) and collapse the
  /// window to zero days. Drafts still resolve live, exactly as before.
  ({String start, String end}) coverage(String currentKey) {
    final r = report;
    if (r != null &&
        r['status'] == CheckInStatus.copied &&
        r['coverageStart'] is String &&
        r['coverageEnd'] is String) {
      return (
        start: r['coverageStart'] as String,
        end: r['coverageEnd'] as String
      );
    }
    return CoachCheckinsLogic.effectiveCoverage(
      currentKey,
      previousWasCopied: prevWasCopied,
      lastFinalizedCoverageEnd: settings['lastFinalizedCoverageEnd'] as String?,
    );
  }

  List<Map<String, dynamic>> eventsInWindow(String currentKey, String type) {
    final r = report;
    if (r == null) return const [];
    final c = coverage(currentKey);
    return (r['events'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((e) =>
            e['type'] == type &&
            (e['dateKey'] as String? ?? '').compareTo(c.start) >= 0 &&
            (e['dateKey'] as String? ?? '').compareTo(c.end) < 0)
        .toList();
  }

  int workoutsInWindow(String currentKey) {
    final r = report;
    if (r == null) return 0;
    final c = coverage(currentKey);
    return (r['workoutDates'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .where((d) => d.compareTo(c.start) >= 0 && d.compareTo(c.end) < 0)
        .length;
  }

  /// Server-derived (coach-timezone) staleness; falls back to the report's
  /// generation-time status when the context omitted this athlete.
  String get weighInStatus =>
      liveWeighInStatus ??
      (report?['bodyweight']?['weighInStatus'] as String?) ??
      'ok';

  String get draftPreview {
    final r = report;
    if (r == null) return '';
    return CoachCheckinsLogic.visibleMessageText(
      status: r['status'] as String?,
      finalText: r['finalText'] as String?,
      previousWasCopied: prevWasCopied,
      draftIfPrevCopied: r['draftIfPrevCopied'] as String?,
      draftIfPrevNotCopied: r['draftIfPrevNotCopied'] as String?,
    );
  }

  /// Merges the authoritative fields the copy callable returned into the local
  /// report, so no screen-wide reload is needed to render the copied state.
  void applyCopyOutcome(CheckInCopyOutcome outcome) {
    report = {...?report, ...outcome.reportPatch};
    if (outcome.coverageEnd != null) {
      // The same transaction that froze the report advanced this watermark.
      settings = {
        ...settings,
        'lastFinalizedCoverageEnd': outcome.coverageEnd,
      };
    }
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
  List<AthleteReview> _athletes = [];
  _ReviewFilter _filter = _ReviewFilter.all;
  final Set<String> _busy = {};
  int _rosterSize = 0;
  bool _contextDegraded = false;

  /// Per-card pending state for Copy. Deliberately separate from [_loading]:
  /// a copy must never put the screen into a loading state.
  final Set<String> _copyPending = {};

  /// Owns the in-flight guard, so a double tap cannot start a second
  /// finalisation even inside a single frame.
  late final CheckInCopyAction _copyAction = CheckInCopyAction(
    invoke: ({required athleteUid, required checkpointKey}) async {
      final res =
          await _functions.httpsCallable('coachPrepareCheckInCopy').call({
        'athleteUid': athleteUid,
        'checkpointKey': checkpointKey,
      });
      return Map<String, dynamic>.from(res.data as Map);
    },
    writeClipboard: (text) => Clipboard.setData(ClipboardData(text: text)),
  );

  /// Athletes acted on since the last full load. They stay visible under the
  /// current filter so a copy never makes the card the coach is looking at
  /// vanish and reflow the list under their finger.
  final Set<String> _stickyVisible = {};

  /// Owned by this screen (not rebuilt per load) so the list keeps its offset
  /// across every per-card action.
  final ScrollController _listController = ScrollController();

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

  @override
  void dispose() {
    _listController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _stickyVisible.clear();
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
      final enabled = <AthleteReview>[];
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
            enabled.add(AthleteReview(
              uid: athlete.uid,
              settings: data,
              rosterName: athlete.label,
            ));
          }
        } catch (e) {
          debugPrint(
              '⚠️ [WeeklyReview] settings read failed for ${athlete.uid}: $e');
        }
      }));
      _rosterSize = roster.length;

      // 3) Server-derived coach-local context: today, checkpoint identity and
      //    live weigh-in staleness, all in the coach's configured timezone.
      //    Non-fatal: if it fails the screen still opens (with a banner) using
      //    device-derived dates, rather than dying with a generic error.
      _contextDegraded = false;
      try {
        final ctxRes =
            await _functions.httpsCallable('coachReviewContext').call({
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
      //    Isolated per athlete, like steps 2 and 3. A transient Firestore
      //    'unavailable' on ONE athlete used to propagate out of Future.wait
      //    and hit the outer catch, discarding an otherwise fully-loaded
      //    screen and showing a generic "check your connection" message even
      //    though the backend was healthy — the 2026-08-14T21:28Z incident,
      //    where coachReviewContext had just returned HTTP 200 in 134ms and
      //    no Cloud Run service logged a single non-2xx all hour. These are
      //    direct client reads, so such a failure leaves no server-side trace
      //    at all. Failing softly here preserves the diagnosis: the affected
      //    card says so, and the real error is logged rather than relabelled.
      await Future.wait(enabled.map((a) async {
        try {
          final results = await Future.wait([
            _reportRef(coachUid, a.uid, _currentKey).get(),
            _reportRef(coachUid, a.uid, _prevKey).get(),
          ]);
          a.report = results[0].data();
          a.prevReport = results[1].data();
        } catch (e) {
          debugPrint('⚠️ [WeeklyReview] report read failed for ${a.uid}: $e');
          a.reportLoadError =
              e is FirebaseException ? (e.code) : e.runtimeType.toString();
        }
      }));

      enabled.sort((a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _athletes = enabled;
        _loading = false;
      });
    } catch (e) {
      // Reaching here now means the ROSTER itself failed (step 1) — the only
      // genuinely fatal step. Name the real cause instead of always blaming
      // the network, so a recurring backend/permission fault stays visible.
      debugPrint('❌ [WeeklyReview] load failed: $e');
      if (!mounted) return;
      final code = e is FirebaseException ? e.code : e.runtimeType.toString();
      setState(() {
        _error = 'Couldn\'t load the Weekly Review ($code). '
            'Tap Refresh to try again.';
        _loading = false;
      });
    }
  }

  DocumentReference<Map<String, dynamic>> _reportRef(
          String coachUid, String athleteUid, String key) =>
      _db
          .collection('coachCheckIns')
          .doc(coachUid)
          .collection('reports')
          .doc('${athleteUid}_$key');

  // ── Report helpers ─────────────────────────────────────────────────────────

  /// Defensive map cast: a report field written by an older server build (or
  /// a malformed document) must degrade to "absent", never throw inside build.
  static Map<String, dynamic>? _mapOf(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  bool _matchesFilter(AthleteReview a) {
    // An athlete acted on since the last load stays put, whatever the filter
    // now says about them — the list must not reflow under the coach.
    if (_stickyVisible.contains(a.uid)) return true;
    switch (_filter) {
      case _ReviewFilter.all:
        return true;
      case _ReviewFilter.ready:
        return a.report != null &&
            a.report!['status'] == CheckInStatus.draft &&
            a.draftPreview.isNotEmpty;
      case _ReviewFilter.needsWeighIn:
        return a.weighInStatus != 'ok';
      case _ReviewFilter.pbs:
        return a.eventsInWindow(_currentKey, 'maxWeightPB').isNotEmpty ||
            a.eventsInWindow(_currentKey, 'repPB').isNotEmpty ||
            a.eventsInWindow(_currentKey, 'e1rmPB').isNotEmpty ||
            a.eventsInWindow(_currentKey, 'rirMatchPB').isNotEmpty;
      case _ReviewFilter.noTraining:
        return a.report != null && a.workoutsInWindow(_currentKey) == 0;
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  /// Copy / finalise, scoped entirely to one card.
  ///
  /// Deliberately NEVER calls [_load] and never touches [_loading]: the whole
  /// point is that the coach stays exactly where they were. The callable's
  /// response is authoritative for everything the card renders, so the card is
  /// reconciled from it directly.
  ///
  /// The clipboard write follows the callable rather than preceding it,
  /// because coachPrepareCheckInCopy composes finalText at copy time from live
  /// bodyweight and in-transaction milestone/coverage state — see
  /// coach_checkin_copy_action.dart. Waiting is the only way to keep the
  /// clipboard text and the report's finalText identical.
  Future<void> _copyMessage(AthleteReview a) async {
    if (_busy.contains(a.uid) || _copyPending.contains(a.uid)) return;
    setState(() => _copyPending.add(a.uid));

    final CheckInCopyOutcome outcome;
    try {
      outcome = await _copyAction.run(
        athleteUid: a.uid,
        checkpointKey: _currentKey,
        onFinalised: (o) {
          // The server's finalText is the single source: it is what is frozen
          // on the report, what goes on the clipboard, and what the card now
          // shows. Applied the instant the authoritative answer arrives.
          if (!mounted) return;
          setState(() {
            a.applyCopyOutcome(o);
            _stickyVisible.add(a.uid);
          });
        },
      );
    } finally {
      if (mounted) setState(() => _copyPending.remove(a.uid));
    }
    if (!mounted) return;

    switch (outcome.status) {
      case CheckInCopyStatus.duplicateIgnored:
        return; // a copy for this athlete was already in flight
      case CheckInCopyStatus.copied:
        _showBrief(outcome.text.isEmpty
            ? 'Nothing to send for ${a.displayName} — marked as sent.'
            : 'Copied');
        // Server-only fields the callable does not return (milestoneAwarded,
        // copiedAtMs). One document read, after the coach already has their
        // text — never a screen reload.
        unawaited(_reconcileCopiedReport(a));
        return;
      case CheckInCopyStatus.clipboardFailed:
        // The check-in IS recorded — say so, and hand over the exact text.
        debugPrint('❌ [WeeklyReview] clipboard write failed: ${outcome.error}');
        unawaited(_reconcileCopiedReport(a));
        await _showManualCopyDialog(outcome.text, a.displayName,
            recorded: true);
        return;
      case CheckInCopyStatus.failed:
        final e = outcome.error;
        if (e is FirebaseFunctionsException) {
          _showError(_friendlyFunctionsError('Copy', e));
        } else {
          debugPrint('❌ [WeeklyReview] copy failed: $e');
          _showError('Copy didn\'t go through. Please try again.');
        }
        return;
    }
  }

  /// Refreshes ONE athlete's current report document after a successful copy,
  /// picking up the fields the callable does not return. Silent and optional:
  /// the authoritative status / finalText / coverage are already applied, so a
  /// failure here changes nothing the coach can see.
  Future<void> _reconcileCopiedReport(AthleteReview a) async {
    try {
      final snap = await _reportRef(_coachUid, a.uid, _currentKey).get();
      final data = snap.data();
      if (data == null || !mounted) return;
      setState(() => a.report = data);
    } catch (e) {
      debugPrint('⚠️ [WeeklyReview] post-copy reconcile skipped: $e');
    }
  }

  /// Puts [text] on the clipboard for the re-copy control on an already-copied
  /// card. On failure the coach is told clearly and offered the full text to
  /// copy manually — we never claim success when the clipboard write failed.
  Future<void> _copyToClipboard(String text, String athleteName) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      _showBrief(text.isEmpty
          ? 'Nothing to send for $athleteName — marked as sent.'
          : 'Copied');
    } catch (e) {
      debugPrint('❌ [WeeklyReview] clipboard write failed: $e');
      if (!mounted) return;
      await _showManualCopyDialog(text, athleteName, recorded: false);
    }
  }

  /// Truthful fallback when the clipboard itself refuses. [recorded] says
  /// whether the server-side finalisation nevertheless succeeded.
  Future<void> _showManualCopyDialog(String text, String athleteName,
      {required bool recorded}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(recorded
            ? 'Copied, but couldn\'t reach the clipboard'
            : 'Copy to clipboard failed'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (recorded)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'The check-in is recorded as sent. Only the clipboard '
                    'write failed — here is the exact message.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              SelectableText(
                text.isEmpty ? '(empty message)' : text,
                style: const TextStyle(fontSize: 13),
              ),
            ],
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

  String _friendlyFunctionsError(String action, FirebaseFunctionsException e) {
    debugPrint('❌ [WeeklyReview] $action failed: ${e.code} ${e.message}');
    switch (e.code) {
      case 'failed-precondition':
        return e.message ??
            '$action isn\'t possible for this check-in anymore.';
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

  Future<void> _undo(AthleteReview a) async {
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

  Future<void> _skip(AthleteReview a) async {
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

  /// Compact, short-lived confirmation. Never blocks and never moves the list.
  void _showBrief(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ));
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
                          _filterChip(
                              'Needs weigh-in', _ReviewFilter.needsWeighIn),
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
                          style:
                              TextStyle(color: Colors.amber[200], fontSize: 12),
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
                                      label:
                                          const Text('Open Check-in Athletes'),
                                      onPressed: () async {
                                        await Navigator.of(context)
                                            .push(MaterialPageRoute(
                                          builder: (_) =>
                                              ChangeNotifierProvider<
                                                  UserContext>.value(
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
                              controller: _listController,
                              padding: const EdgeInsets.fromLTRB(8, 6, 8, 24),
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (context, i) =>
                                  _athleteCard(filtered[i]),
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
        onSelected: (_) => setState(() {
          _filter = value;
          _stickyVisible.clear();
        }),
      ),
    );
  }

  String _weekdayLabel(String key) {
    final wd = CoachCheckinsLogic.parseKey(key).weekday;
    return wd == DateTime.monday ? 'Monday' : 'Thursday';
  }

  Widget _athleteCard(AthleteReview a) {
    final statusByKey = <String, String>{
      if (a.report != null) _currentKey: a.status,
      if (a.prevReport != null)
        _prevKey: a.prevReport!['status'] as String? ?? 'draft',
    };
    return CoachAthleteReviewCard(
      // Stable identity: a per-card action must never remount its neighbours.
      key: ValueKey('weeklyReviewCard_${a.uid}'),
      review: a,
      currentKey: _currentKey,
      adherence: _mapOf(a.report?['currentWeekAdherence']),
      busy: _busy.contains(a.uid) || _copyPending.contains(a.uid),
      mutable: CoachCheckinsLogic.canMutate(_currentKey, statusByKey),
      onCopy: () => _copyMessage(a),
      onRecopy: () => _copyToClipboard(
          (a.report?['finalText'] as String?) ?? '', a.displayName),
      onUndo: () => _undo(a),
      onSkip: () => _skip(a),
      onOpenPlanner: () => openAthleteWeekPlanner(
        context,
        athleteUid: a.uid,
        athleteName: a.displayName,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Athlete card
// ═══════════════════════════════════════════════════════════════════════════

/// One athlete's Weekly Review card. Public and Firebase-free so the exact
/// production widget can be mounted in tests.
class CoachAthleteReviewCard extends StatelessWidget {
  const CoachAthleteReviewCard({
    super.key,
    required this.review,
    required this.currentKey,
    required this.busy,
    required this.mutable,
    required this.onCopy,
    required this.onRecopy,
    required this.onUndo,
    required this.onSkip,
    required this.onOpenPlanner,
    this.adherence,
  });

  final AthleteReview review;
  final String currentKey;

  /// Fixed Monday→Sunday adherence (server-computed). Absent on reports
  /// generated before this field existed — the card then falls back to the
  /// legacy completion map and omits the week strip.
  final Map<String, dynamic>? adherence;

  /// Per-card pending state only. No screen-wide loading flag is involved in
  /// any card action.
  final bool busy;
  final bool mutable;
  final VoidCallback onCopy;
  final VoidCallback onRecopy;
  final VoidCallback onUndo;
  final VoidCallback onSkip;
  final VoidCallback onOpenPlanner;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = review;
    final report = a.report;
    final status = a.status;
    final coverage = a.coverage(currentKey);
    final maxWeightPBs = a.eventsInWindow(currentKey, 'maxWeightPB');
    final repPBs = a.eventsInWindow(currentKey, 'repPB');
    final e1rmPBs = a.eventsInWindow(currentKey, 'e1rmPB');
    final rirMatchPBs = a.eventsInWindow(currentKey, 'rirMatchPB');
    // A set that is both an all-time heaviest lift and a rep-target PB is ONE
    // achievement (the backend praises it once, as the heaviest lift), so the
    // rep-PB evidence list hides the duplicate rather than showing it twice.
    final maxWeightKeys =
        maxWeightPBs.map((e) => '${e['exerciseId']}_${e['dateKey']}').toSet();
    final repOnlyPBs = repPBs
        .where((e) =>
            !maxWeightKeys.contains('${e['exerciseId']}_${e['dateKey']}'))
        .toList();
    final workouts = a.workoutsInWindow(currentKey);
    final completion = report?['completion'] as Map<String, dynamic>?;
    final weekStrip = CoachCheckinsLogic.weekStripRows(adherence);
    final bodyweight = report?['bodyweight'] as Map<String, dynamic>?;
    final fallbackWeek = report?['fallbackWeek'] as Map<String, dynamic>?;
    final weighStatus = a.weighInStatus;
    final draft = a.draftPreview;

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
                _plannerButton(),
                const SizedBox(width: 6),
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
                _fact(Icons.trending_up,
                    '${e1rmPBs.length} E1RM PB${e1rmPBs.length == 1 ? '' : 's'}'),
                if (rirMatchPBs.isNotEmpty)
                  _fact(Icons.bolt,
                      '${rirMatchPBs.length} PB match, more in reserve'),
                _fact(
                  Icons.fitness_center,
                  CoachCheckinsLogic.adherenceFactLabel(
                    workoutsInCoverage: workouts,
                    adherence: adherence,
                    legacyCompletion: completion,
                  ),
                ),
                if (bodyweight?['currentAvg'] != null)
                  _fact(Icons.monitor_weight,
                      '7d avg ${bodyweight!['currentAvg']} kg · ${_trendLabel(bodyweight)}'),
                if (bodyweight?['newMilestoneId'] != null ||
                    report?['milestoneAwarded'] != null)
                  // milestoneAwarded is phase-scoped ('cut_110@<phase>');
                  // show only the objective boundary part.
                  _fact(Icons.celebration,
                      'Milestone ${(report?['milestoneAwarded'] ?? bodyweight?['newMilestoneId']).toString().split('@').first}'),
                if (weighStatus != 'ok')
                  _warn(weighStatus == 'due'
                      ? 'Weigh-in due'
                      : 'Weigh-in overdue'),
              ],
            ),
            if (weekStrip.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final row in weekStrip)
                Text(
                  row,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12, height: 1.35),
                ),
            ],
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
                  '• ${e['exerciseName']}: all-time heaviest ${_pbLoad(e, e['weightKg'])} × ${e['reps']} '
                  '(prev ${_pbPrev(e, e['prevWeightKg'])})',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              for (final e in repOnlyPBs)
                Text(
                  '• ${e['exerciseName']}: ${_pbLoad(e, e['weightKg'])} × ${e['reps']} '
                  '(prev ${_pbPrev(e, e['prevWeightKg'])} at ≥ ${e['reps']} reps)',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              for (final e in e1rmPBs)
                Text(
                  '• ${e['exerciseName']}: E1RM '
                  '${e['bodyweightKg'] is num ? _pbLoad(e, e['e1rmKg']) : '${(e['e1rmKg'] as num).toStringAsFixed(1)}kg'} '
                  '(prev ${(e['prevE1rmKg'] as num).toStringAsFixed(1)}kg'
                  '${e['bodyweightKg'] is num ? ' total' : ''}, no RIR)',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              for (final e in rirMatchPBs)
                Text(
                  '• ${e['exerciseName']}: matched ${_pbLoad(e, e['weightKg'])} × ${e['reps']} '
                  'at RIR ${e['rir']} (prev RIR ${e['prevRir']}) — more in reserve, '
                  'not a new PB',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
            ],
            const SizedBox(height: 8),
            if (a.reportLoadError != null)
              Text(
                'Could not load this athlete\'s report (${a.reportLoadError}). '
                'Tap Refresh to retry — other athletes are unaffected.',
                style: TextStyle(color: Colors.amber[200], fontSize: 12),
              )
            else if (report == null)
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
                    onPressed: busy || !mutable ? null : onCopy,
                    icon: busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
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
                    icon:
                        const Icon(Icons.copy, size: 16, color: Colors.white70),
                    onPressed: busy ? null : onRecopy,
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: busy || !mutable ? null : onUndo,
                    child: const Text('Undo / Mark Not Sent'),
                  ),
                ],
                const Spacer(),
                if (report != null && status == CheckInStatus.draft)
                  TextButton(
                    onPressed: busy ? null : onSkip,
                    child: const Text('Skip'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Compact planner control, in the header row beside the status chip.
  ///
  /// Sized to the surrounding 15px name text (16px icon, 11px label, 2px
  /// vertical padding) so the header row — and therefore the card — does not
  /// grow.
  Widget _plannerButton() {
    return Tooltip(
      message: 'Open week planner',
      child: Semantics(
        button: true,
        label: 'Open week planner',
        child: InkWell(
          key: const ValueKey('openWeekPlannerButton'),
          onTap: onOpenPlanner,
          borderRadius: BorderRadius.circular(8),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.calendar_view_week, size: 16, color: Colors.white70),
                SizedBox(width: 4),
                Text('Planner',
                    style: TextStyle(color: Colors.white70, fontSize: 11)),
              ],
            ),
          ),
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
          debugPrint(
              '⚠️ [CheckinAthletes] settings read failed for ${a.uid}: $e');
        }
      }));

      if (mounted) setState(() => _loading = false);
    } catch (e) {
      debugPrint('❌ [CheckinAthletes] load failed: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error =
              'Couldn\'t load your athlete list. Tap refresh to try again.';
        });
      }
    }
  }

  Future<void> _save(String uid, Map<String, dynamic> patch) async {
    final name = _roster
        .firstWhere((a) => a.uid == uid, orElse: () => CoachAthlete(uid: uid))
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
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
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
                        final mode = (s['messageExerciseMode'] as String?) ??
                            'automatic';
                        final customCount =
                            (s['customExerciseIds'] as List<dynamic>? ??
                                    const [])
                                .length;

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
                                  // The athlete's CURRENT username, resolved by uid.
                                  // athlete.label is denormalised roster data — what
                                  // they were called when the roster was built — so it
                                  // is the fallback, never the answer.
                                  title: LiveUserName(
                                    uid: athlete.uid,
                                    fallback: athlete.label,
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
                                    if (v && s['goal'] == null)
                                      'goal': 'maintain',
                                    if (v && s['messageExerciseMode'] == null)
                                      'messageExerciseMode': 'automatic',
                                    if (v)
                                      'enabledAt':
                                          DateTime.now().toIso8601String(),
                                  }),
                                ),
                                if (enabled)
                                  Row(
                                    children: [
                                      DropdownButton<String>(
                                        value: goal,
                                        dropdownColor: Theme.of(context)
                                            .colorScheme
                                            .surface,
                                        items: const [
                                          DropdownMenuItem(
                                              value: 'cut',
                                              child: Text('Cutting')),
                                          DropdownMenuItem(
                                              value: 'bulk',
                                              child: Text('Bulking')),
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
                                        dropdownColor: Theme.of(context)
                                            .colorScheme
                                            .surface,
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
                                            : _save(uid,
                                                {'messageExerciseMode': v}),
                                      ),
                                      const Spacer(),
                                      if (mode == 'custom')
                                        TextButton(
                                          onPressed: () =>
                                              _pickCustomExercises(uid),
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
