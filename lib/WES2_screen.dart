import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'user_context.dart';
import 'WES2_controller.dart';
import 'WES2_models.dart';
import 'WES2_plan_service.dart';
import 'WES2_repository.dart';
import 'WES2_widgets/WES2_day_header.dart';
import 'WES2_widgets/WES2_empty_state.dart';
import 'WES2_widgets/WES2_day_actions_row.dart';
import 'WES2_widgets/WES2_exercise_card.dart';
import 'WES2_widgets/WES2_exercise_picker.dart';
import 'WES2_hint_service.dart';
import 'WES2_local_store.dart';
import 'WES2_template_service.dart';
import 'WES2_widgets/WES2_template_picker.dart';
import 'WES2_widgets/WES2_exercise_settings_dialog.dart';
import 'exercise_details_screen.dart';
import 'top_sets_screen.dart';
import 'periodization_model_utils.dart';
import 'progression_engine.dart';

enum _Wes2AppBarMenuAction { timer, templates, deleteAll }

/// WES2 beta route shell.
/// Receives an optional [initialDate]; defaults to today when omitted.
/// Accesses athlete identity via UserContext — never via FirebaseAuth directly.
class Wes2Screen extends StatefulWidget {
  final DateTime? initialDate;

  const Wes2Screen({super.key, this.initialDate});

  @override
  State<Wes2Screen> createState() => _Wes2ScreenState();
}

class _Wes2ScreenState extends State<Wes2Screen> with WidgetsBindingObserver {
  late final Wes2SessionController _controller;
  final Wes2Repository _repository = FirestoreWes2Repository();
  final Wes2PlanService _planService = FirestoreWes2PlanService();
  final Wes2LocalStore _localStore = IsarWes2LocalStore();
  final Wes2TemplateService _templateService = FirestoreWes2TemplateService();
  bool _loadStarted = false;
  String? _athleteUsername;
  String? _athleteGreeting;
  String? _fetchedForUid;
  Map<String, dynamic> _cachedExerciseSettings = const {};
  Map<String, String> _cachedExerciseTypes = const {};
  // IDs present in the BB3 planned day at last load. Keyed by exerciseId.
  // Allows post-merge rows (source=completedServer) to still trigger BB3 sync.
  Set<String> _bb3PlannedExerciseIds = const {};
  // Composite key uid|blockId|date — prevents redundant server history refreshes.
  String? _lastHistoryRefreshKey;

  // ── Day timer state (Phase 17) ─────────────────────────────────────────────
  bool _timerVisible = false;
  bool _timerRunning = false;
  int _elapsedMilliseconds = 0;
  DateTime? _timerStartedAt;
  Timer? _timerTicker;

  // ── Automatic workout duration (separate from manual floating timer) ────────
  int _workoutDurationMilliseconds = 0;
  DateTime? _workoutDurationSegmentStartedAt;

  Future<void> _fetchAthleteUsername(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = doc.data() ?? {};

      // Prefer username, fall back to displayName then fullName
      String? name;
      for (final key in ['username', 'displayName', 'fullName']) {
        final v = (data[key] as String?)?.trim();
        if (v != null && v.isNotEmpty) { name = v; break; }
      }

      // Greeting from profile.gender (not sex)
      String greeting = 'Welcome';
      final profile = data['profile'];
      if (profile is Map<String, dynamic>) {
        final gender = (profile['gender'] as String?)?.toLowerCase().trim() ?? '';
        if (gender == 'female' || gender == 'woman' || gender == 'girl') {
          greeting = 'Welcome queen';
        } else if (gender == 'male' || gender == 'man' || gender == 'boy') {
          greeting = 'Welcome king';
        }
      }

      if (mounted) {
        setState(() {
          _athleteUsername = (name != null && name.isNotEmpty) ? name : null;
          _athleteGreeting = greeting;
          _fetchedForUid = uid;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _fetchedForUid = uid);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final raw = widget.initialDate ?? DateTime.now();
    _controller = Wes2SessionController(raw);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // listen: false — identity is read once; UserContext.currentUid is the
    // acting athlete UID, never FirebaseAuth.currentUser.uid directly.
    final uc = UserContext.of(context, listen: false);
    _controller.initIdentity(
      actorUid: uc.actorUid,
      actingUid: uc.currentUid,
      isCoach: uc.isCoach,
      activeBlockId: uc.activeBlockId,
      blockStartDate: uc.blockStartDate,
      blockEndDate: uc.blockEndDate,
    );
    if (!_loadStarted) {
      _loadStarted = true;
      _loadDay();
    }
  }

  @override
  void dispose() {
    _timerTicker?.cancel();
    _pauseWorkoutDurationSegment();
    _saveDraftNow();
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pauseWorkoutDurationSegment();
      _saveDraftNow();
    } else if (state == AppLifecycleState.resumed) {
      // Resync timer elapsed from the anchored start time after backgrounding.
      if (_timerRunning && _timerStartedAt != null) {
        _syncTimerElapsed();
        if (_elapsedMilliseconds >= 3600000) {
          _stopTimer();
        } else if (mounted) {
          setState(() {});
        }
      }
    }
  }

  /// Fire-and-forget draft save. Returns void so it can be called from
  /// dispose/didChangeAppLifecycleState without an unawaited-future lint.
  void _saveDraftNow() {
    if (_controller.actingUid.isEmpty) return;
    // ignore: discarded_futures
    _localStore.saveDraft(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      rows: _controller.rows.toList(),
      workoutDurationMs: _currentWorkoutDurationMs(),
    );
  }

  // ── Timer (Phase 17) ──────────────────────────────────────────────────────

  void _toggleTimerVisible() => setState(() => _timerVisible = !_timerVisible);

  void _startTimer() {
    if (_timerRunning) return;
    _timerTicker?.cancel();
    setState(() {
      _timerRunning = true;
      // Anchor virtual start so that elapsed is preserved across stop/start.
      _timerStartedAt =
          DateTime.now().subtract(Duration(milliseconds: _elapsedMilliseconds));
    });
    _timerTicker =
        Timer.periodic(const Duration(milliseconds: 100), (_) => _tickTimer());
  }

  void _stopTimer() {
    _timerTicker?.cancel();
    _timerTicker = null;
    setState(() {
      // Freeze elapsed from start time before clearing the anchor.
      _syncTimerElapsed();
      _timerRunning = false;
      _timerStartedAt = null;
    });
  }

  void _resetTimer() {
    _timerTicker?.cancel();
    _timerTicker = null;
    setState(() {
      _timerRunning = false;
      _elapsedMilliseconds = 0;
      _timerStartedAt = null;
    });
  }

  // Close stops the timer so there is no runaway timer while hidden.
  void _closeTimer() {
    _stopTimer();
    setState(() => _timerVisible = false);
  }

  void _tickTimer() {
    if (!mounted) return;
    _syncTimerElapsed();
    if (_elapsedMilliseconds >= 3600000) {
      _stopTimer();
    } else {
      setState(() {});
    }
  }

  void _syncTimerElapsed() {
    if (_timerStartedAt == null) return;
    final elapsed = DateTime.now().difference(_timerStartedAt!).inMilliseconds;
    _elapsedMilliseconds = elapsed.clamp(0, 3600000);
  }

  String _formatDuration(int milliseconds, {bool includeSplitSeconds = false}) {
    final totalSeconds = milliseconds ~/ 1000;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    final cs = (milliseconds % 1000) ~/ 10;

    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    final cc = cs.toString().padLeft(2, '0');

    if (includeSplitSeconds) {
      return h > 0 ? '$h:$mm:$ss.$cc' : '$mm:$ss.$cc';
    }

    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  // ── Workout duration helpers ──────────────────────────────────────────────

  void _startWorkoutDurationSegment() {
    if (_workoutDurationSegmentStartedAt != null) return;
    _workoutDurationSegmentStartedAt = DateTime.now();
  }

  void _pauseWorkoutDurationSegment() {
    final start = _workoutDurationSegmentStartedAt;
    if (start == null) return;
    _workoutDurationMilliseconds +=
        DateTime.now().difference(start).inMilliseconds;
    _workoutDurationSegmentStartedAt = null;
  }

  int _currentWorkoutDurationMs() {
    final start = _workoutDurationSegmentStartedAt;
    if (start == null) return _workoutDurationMilliseconds;
    return _workoutDurationMilliseconds +
        DateTime.now().difference(start).inMilliseconds;
  }

  /// Load completed workout + BB3 planned rows for the current date, then merge.
  /// beginLoad() increments the epoch; stale completions are discarded.
  Future<void> _loadDay() async {
    final epoch = _controller.beginLoad();
    try {
      // Phase 3: completed workout document (exercises[] + wesPlannedExercises[])
      final completedRows = await _repository.loadDay(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
      );

      // Phase 4: BB3 planned day — skip if block context is absent or if
      // selectedDate is before blockStartDate (no negative week/day paths).
      _bb3PlannedExerciseIds = const {}; // reset before each load
      var bb3Rows = const <Wes2ExerciseRow>[];
      final blockId = _controller.activeBlockId;
      final blockStart = _controller.blockStartDate;
      if (blockId != null &&
          blockId.isNotEmpty &&
          blockStart != null &&
          !_isBeforeBlockStart(_controller.selectedDate, blockStart)) {
        final wd = _weekDayFromDate(blockStart, _controller.selectedDate);
        bb3Rows = await _planService.loadPlannedDay(
          uid: _controller.actingUid,
          blockId: blockId,
          weekIndex: wd.weekIndex,
          dayIndex: wd.dayIndex,
        );
        _bb3PlannedExerciseIds = bb3Rows.map((r) => r.exerciseId).toSet();
      }

      // Phase 7: overlay local draft actuals onto server/BB3 merged structure.
      final draft = await _localStore.loadDraft(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
      );
      if (!mounted) return;
      _controller.setRows(
        _hardened(_applyDraftActuals(_mergeRows(completedRows, bb3Rows), draft?.rows)),
        epoch,
      );
      _workoutDurationMilliseconds = draft?.workoutDurationMs ?? 0;
      _workoutDurationSegmentStartedAt = null;
      // Phase 21B: apply Set 1 model/default hints after rows settle.
      // ignore: discarded_futures
      _loadAndApplyHints();
      // Persist any exercises queued during loading, deduplicated against
      // freshly loaded server/BB3 data inside setRows/_flushPendingAdds.
      final flushed = _controller.consumeFlushedExercises();
      if (flushed.isNotEmpty) {
        _saveDraftNow();
        for (final row in flushed) {
          // ignore: discarded_futures
          _saveManualExerciseSilently(
            uid: _controller.actingUid,
            date: _controller.selectedDate,
            row: row,
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      _controller.setLoadError(e.toString(), epoch);
    }
  }

  /// Loads exerciseSettings once and applies Phase 21B Set 1 model/default
  /// hints to every current row. Fire-and-forget; errors are logged only.
  Future<void> _loadAndApplyHints() async {
    final blockId = _controller.activeBlockId;
    final blockStart = _controller.blockStartDate;
    if (blockId == null || blockId.isEmpty || blockStart == null) return;

    await _refreshHistoryForHints(_controller.selectedDate);

    try {
      if (_cachedExerciseSettings.isEmpty) {
        _cachedExerciseSettings = await _planService.loadExerciseSettings(
          uid: _controller.actingUid,
          blockId: blockId,
        );
        _controller.setExerciseSettings(_cachedExerciseSettings);
      }

      if (!mounted) return;

      // Fetch exercise types for type-aware default weight hints (Issue 5).
      // Only fetches IDs not already cached; keyed by exerciseId.
      final uncachedIds = _controller.rows
          .map((r) => r.exerciseId)
          .where((id) => !_cachedExerciseTypes.containsKey(id))
          .toSet()
          .toList();
      if (uncachedIds.isNotEmpty) {
        try {
          final fetched = await _planService.loadExerciseTypes(uncachedIds);
          _cachedExerciseTypes = {..._cachedExerciseTypes, ...fetched};
        } catch (_) {
          // Type fetch is non-critical; hints still work without it.
        }
      }

      if (!mounted) return;

      final svc = Wes2HintServiceImpl(
        exerciseSettings: _cachedExerciseSettings,
        exerciseTypes: _cachedExerciseTypes,
        blockStartDate: blockStart,
        blockEndDate: _controller.blockEndDate,
        uid: _controller.actingUid,
      );
      // Phase 21C: register service so updateSetField can do same-set recalc.
      _controller.setHintService(svc, blockId);

      final date = _controller.selectedDate;
      final rows = _controller.rows.toList();

      for (final row in rows) {
        if (!mounted) return;
        try {
          final hinted = svc.computeRowHints(
            row: row,
            blockId: blockId,
            uid: _controller.actingUid,
            date: date,
          );
          _controller.applyModelHints(row.exerciseId, hinted);
        } catch (e) {
          debugPrint('[WES2] Hint failed for ${row.name} (${row.exerciseId}): $e');
        }
      }
      // Snapshot hinted rows as baseline so same-set recalc can restore
      // original hints when the user clears all typed actuals.
      if (mounted) _controller.captureBaselineHintRows();
    } catch (e) {
      debugPrint('[WES2] Hint computation failed: $e');
    }
  }

  /// Fetches the bounded block workout history from Firestore and patches it
  /// into PeriodizationModelUtils.savedWorkoutsList so retroactive edits are
  /// visible to progression hints without a full app restart.
  ///
  /// Runs at most once per (uid, blockId, selectedDate) triple. On server
  /// failure the key is NOT marked, allowing a retry on the next navigation.
  Future<void> _refreshHistoryForHints(DateTime selectedDate) async {
    final uid = _controller.actingUid;
    if (uid.isEmpty) return;
    final blockStart = _controller.blockStartDate;
    if (blockStart == null) return;
    final blockId = _controller.activeBlockId ?? '';

    String ymd(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    final key = '$uid|$blockId|${ymd(selectedDate)}';
    if (_lastHistoryRefreshKey == key) return;

    final startKey = ymd(DateTime(blockStart.year, blockStart.month, blockStart.day));
    final endKey   = ymd(DateTime(selectedDate.year, selectedDate.month, selectedDate.day));

    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('workouts')
          .orderBy(FieldPath.documentId)
          .startAt([startKey])
          .endAt([endKey])
          .get(const GetOptions(source: Source.server));

      final freshData = snap.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        data['date'] ??= doc.id;
        return data;
      }).toList();

      // Replace cached entries in [startKey, endKey]; leave earlier history intact.
      final merged = <Map<String, dynamic>>[];
      for (final w in PeriodizationModelUtils.savedWorkoutsList) {
        final raw  = (w['date'] ?? '').toString();
        final wKey = raw.length >= 10 ? raw.substring(0, 10) : '';
        if (wKey.isEmpty || wKey.compareTo(startKey) < 0 || wKey.compareTo(endKey) > 0) {
          merged.add(w);
        }
      }
      merged.addAll(freshData);

      // Stable date order so downstream history logic receives a consistent list.
      merged.sort((a, b) {
        final aKey = (a['date'] ?? '').toString();
        final bKey = (b['date'] ?? '').toString();
        final ak = aKey.length >= 10 ? aKey.substring(0, 10) : aKey;
        final bk = bKey.length >= 10 ? bKey.substring(0, 10) : bKey;
        return bk.compareTo(ak); // newest-first, matching WarmupService convention
      });

      PeriodizationModelUtils.savedWorkoutsList = merged;
      _rebuildTopSetsFromSavedWorkouts();
      _lastHistoryRefreshKey = key;
    } catch (_) {
      // Server fetch failed; savedWorkoutsList is unchanged.
      // Key is intentionally NOT set — next navigation will retry.
    }
  }

  /// Rebuilds PeriodizationModelUtils.topSetsByExercise from the current
  /// savedWorkoutsList. Called after _refreshHistoryForHints patches in fresh
  /// server data so ProgressionEngine → BB3HintService sees updated history.
  void _rebuildTopSetsFromSavedWorkouts() {
    double parseD(dynamic v) {
      if (v == null) return 0.0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString().trim()) ?? 0.0;
    }
    DateTime? parseDate(dynamic v) {
      if (v is DateTime) return v;
      if (v is String && v.length >= 10) return DateTime.tryParse(v.substring(0, 10));
      return null;
    }

    final newMap = <String, List<Map<String, dynamic>>>{};
    for (final w in PeriodizationModelUtils.savedWorkoutsList) {
      final wDate = parseDate(w['date']);
      if (wDate == null) continue;
      final exs = w['exercises'];
      if (exs is! List) continue;
      for (final ex in exs) {
        if (ex is! Map) continue;
        final name = (ex['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        final sets = ex['sets'];
        if (sets is! List) continue;
        double bestE1rm = 0;
        Map<String, dynamic>? best;
        for (final s in sets) {
          if (s is! Map) continue;
          final w2  = parseD(s['weight']  ?? s['actualWeight']);
          final r   = parseD(s['reps']    ?? s['actualReps']);
          final rir = parseD(s['rir']     ?? s['actualRir']);
          if (w2 <= 0 || r <= 0) continue;
          final e1rm = PeriodizationModelUtils.calculateE1RM(w2, r, rir);
          if (e1rm > bestE1rm) {
            bestE1rm = e1rm;
            best = {'weight': w2, 'reps': r, 'rir': rir, 'date': wDate};
          }
        }
        if (best != null) newMap.putIfAbsent(name, () => []).add(best);
      }
    }
    for (final list in newMap.values) {
      list.sort((a, b) {
        final ad = a['date'] as DateTime?;
        final bd = b['date'] as DateTime?;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return bd.compareTo(ad); // newest-first
      });
    }
    PeriodizationModelUtils.topSetsByExercise
      ..clear()
      ..addAll(newMap);
  }

  /// Returns true if [date] (midnight-normalised) is strictly before
  /// [blockStart] (midnight-normalised). Prevents negative week/day indices.
  static bool _isBeforeBlockStart(DateTime date, DateTime blockStart) {
    final d = DateTime(date.year, date.month, date.day);
    final b = DateTime(blockStart.year, blockStart.month, blockStart.day);
    return d.isBefore(b);
  }

  /// Converts blockStart + selected date to BB3 weekIndex / dayIndex.
  /// Matches BB3PlannedExerciseService.dateToWeekDay logic; no import needed.
  static ({int weekIndex, int dayIndex}) _weekDayFromDate(
    DateTime blockStart,
    DateTime date,
  ) {
    final base = DateTime(blockStart.year, blockStart.month, blockStart.day);
    final sel = DateTime(date.year, date.month, date.day);
    final days = sel.difference(base).inDays;
    return (weekIndex: days ~/ 7, dayIndex: days % 7);
  }

  /// Merges completed + WES2-planned rows (Phase 3) with BB3 rows (Phase 4).
  /// When the same exerciseId appears in both lists, the rows are merged
  /// field-by-field so BB3 hint values are preserved underneath completed
  /// actual values rather than being discarded by a row-level putIfAbsent.
  static List<Wes2ExerciseRow> _mergeRows(
    List<Wes2ExerciseRow> completedRows,
    List<Wes2ExerciseRow> bb3Rows,
  ) {
    // Index bb3 rows for O(1) lookup.
    final bb3ById = <String, Wes2ExerciseRow>{};
    for (final r in bb3Rows) {
      bb3ById.putIfAbsent(r.exerciseId, () => r);
    }

    final seen = <String, Wes2ExerciseRow>{};

    for (final completed in completedRows) {
      final bb3 = bb3ById[completed.exerciseId];
      if (bb3 != null) {
        // Both sources have this exercise: inject BB3 hints into completed row.
        seen[completed.exerciseId] = _mergeCompletedAndBb3Row(completed, bb3);
      } else {
        seen.putIfAbsent(completed.exerciseId, () => completed);
      }
    }

    // BB3-only rows (no matching completed row): keep as-is.
    for (final bb3 in bb3Rows) {
      seen.putIfAbsent(bb3.exerciseId, () => bb3);
    }

    return seen.values.toList()
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  }

  /// Produces one row that preserves actual values, executionNote, and
  /// isMarkedDone from [completed] while injecting hint values and planNote
  /// from [bb3]. setCount is the max of both sources so hints for sets beyond
  /// the completed count are not dropped.
  static Wes2ExerciseRow _mergeCompletedAndBb3Row(
    Wes2ExerciseRow completed,
    Wes2ExerciseRow bb3,
  ) {
    final setCount =
        completed.setCount > bb3.setCount ? completed.setCount : bb3.setCount;
    final sets = List.generate(setCount, (i) {
      final cs = i < completed.sets.length ? completed.sets[i] : null;
      final bs = i < bb3.sets.length ? bb3.sets[i] : null;
      return _mergeSetHintsAndActuals(cs, bs, i);
    });
    return completed.copyWith(
      sets: sets,
      setCount: setCount,
      exercisePlanNote: bb3.exercisePlanNote,
    );
  }

  /// Merges one set slot: actual values and executionNote come from
  /// [completedSet]; hint values and planNote come from [bb3Set].
  static Wes2SetState _mergeSetHintsAndActuals(
    Wes2SetState? completedSet,
    Wes2SetState? bb3Set,
    int setIndex,
  ) {
    if (completedSet == null && bb3Set == null) {
      return Wes2SetState(setIndex: setIndex);
    }
    if (bb3Set == null) return completedSet!;
    if (completedSet == null) return bb3Set;
    // withHint preserves existing actualValue while injecting the hint.
    return Wes2SetState(
      setIndex: setIndex,
      weight: completedSet.weight
          .withHint(bb3Set.weight.hintValue, FieldOrigin.bb3Hint),
      reps: completedSet.reps
          .withHint(bb3Set.reps.hintValue, FieldOrigin.bb3Hint),
      rir: completedSet.rir
          .withHint(bb3Set.rir.hintValue, FieldOrigin.bb3Hint),
      velocity: completedSet.velocity
          .withHint(bb3Set.velocity.hintValue, FieldOrigin.bb3Hint),
      executionNote: completedSet.executionNote,
      planNote: bb3Set.planNote,
    );
  }

  /// Overlays local draft actualValues onto the server/BB3 merged row list.
  /// Server/BB3 is structural authority: row presence, names, circuitIndex,
  /// orderIndex, source, and hintValues are always preserved from [merged].
  /// Draft rows not present in [merged] are dropped (orphan guard).
  /// draft actualValues and isMarkedDone are the only things restored.
  static List<Wes2ExerciseRow> _applyDraftActuals(
    List<Wes2ExerciseRow> merged,
    List<Wes2ExerciseRow>? draft,
  ) {
    if (draft == null || draft.isEmpty) return merged;
    final draftMap = <String, Wes2ExerciseRow>{
      for (final r in draft) r.exerciseId: r,
    };
    return merged.map((row) {
      final d = draftMap[row.exerciseId];
      if (d == null) return row;
      // Highest setIndex in draft that carries any actual value.
      // Using index rather than count handles sparse/higher-index edited sets
      // (e.g. set at index 4 typed without Add Set — count=1 but span=5).
      final highestDraftActualIdx = d.sets.fold(
        -1,
        (int m, Wes2SetState s) =>
            s.hasAnyActual && s.setIndex > m ? s.setIndex : m,
      );
      // effectiveCount = max of server setCount, draft setCount (preserves
      // blank added sets), and span required to reach the highest actual.
      final effectiveCount = [
        row.setCount,
        d.setCount,
        highestDraftActualIdx + 1,
      ].reduce((a, b) => a > b ? a : b);
      final overlaidSets = List.generate(effectiveCount, (i) {
        final serverSet =
            i < row.sets.length ? row.sets[i] : Wes2SetState(setIndex: i);
        final draftSet = i < d.sets.length ? d.sets[i] : null;
        if (draftSet == null) return serverSet;
        // Overlay draft actualValues and executionNote.
        // server/BB3 hintValues and planNote are preserved from serverSet.
        // executionNote: non-null draft value wins; null draft defers to server.
        return serverSet.copyWith(
          weight: draftSet.weight.hasActual
              ? serverSet.weight.withActual(draftSet.weight.actualValue)
              : serverSet.weight,
          reps: draftSet.reps.hasActual
              ? serverSet.reps.withActual(draftSet.reps.actualValue)
              : serverSet.reps,
          rir: draftSet.rir.hasActual
              ? serverSet.rir.withActual(draftSet.rir.actualValue)
              : serverSet.rir,
          velocity: draftSet.velocity.hasActual
              ? serverSet.velocity.withActual(draftSet.velocity.actualValue)
              : serverSet.velocity,
          executionNote: draftSet.executionNote,
        );
      });
      return row.copyWith(
        sets: overlaidSets,
        setCount: effectiveCount,
        isMarkedDone: d.isMarkedDone,
      );
    }).toList();
  }

  /// Deduplicates rows by exerciseId (completedServer wins over planned/manual)
  /// and normalizes any zero-setCount ghost rows. Applied at all row entry points.
  static List<Wes2ExerciseRow> _hardened(List<Wes2ExerciseRow> rows) {
    const sourcePriority = {
      Wes2RowSource.completedServer: 0,
      Wes2RowSource.bb3Planned: 1,
      Wes2RowSource.templateLoaded: 1,
      Wes2RowSource.localDraft: 1,
      Wes2RowSource.wes2Manual: 2,
    };
    // Sort so higher-priority source is first — wins putIfAbsent-style dedupe.
    final sorted = List<Wes2ExerciseRow>.from(rows)
      ..sort((a, b) {
        final pa = sourcePriority[a.source] ?? 1;
        final pb = sourcePriority[b.source] ?? 1;
        if (pa != pb) return pa.compareTo(pb);
        return a.orderIndex.compareTo(b.orderIndex);
      });
    final seen = <String>{};
    final deduped = <Wes2ExerciseRow>[];
    for (final r in sorted) {
      final key = r.exerciseId.trim().toLowerCase();
      if (seen.add(key)) deduped.add(_normalizeSetCount(r));
    }
    deduped.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return deduped;
  }

  static Wes2ExerciseRow _normalizeSetCount(Wes2ExerciseRow row) {
    if (row.setCount > 0) return row;
    final fallback = row.source == Wes2RowSource.completedServer ? 1 : 3;
    return row.copyWith(
      setCount: row.sets.isNotEmpty ? row.sets.length : fallback,
    );
  }

  /// Called when any set field loses focus. Parses the raw text and fires a
  /// fire-and-forget Firestore field patch via [_saveFieldSilently].
  void _onFieldUnfocused(
    String exerciseId,
    int setIndex,
    Wes2FieldKey fieldKey,
    String rawText,
  ) {
    final text = rawText.trim();
    final dynamic value;
    if (text.isEmpty) {
      value = null; // blank → remove field from Firestore set map
    } else {
      value = _parseFieldValue(fieldKey, text);
      if (value == null) return; // invalid non-empty → skip save
      if (fieldKey == Wes2FieldKey.weight ||
          fieldKey == Wes2FieldKey.reps ||
          fieldKey == Wes2FieldKey.rir) {
        _startWorkoutDurationSegment();
      }
    }
    final rowIdx =
        _controller.rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _controller.rows[rowIdx];
    // ignore: discarded_futures
    _saveFieldSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      row: row,
      setIndex: setIndex,
      fieldKey: fieldKey,
      value: value,
    );
  }

  /// Calls [_repository.saveFieldPatch] and silently swallows any error.
  /// UI state and local draft are intentionally left intact on failure.
  Future<void> _saveFieldSilently({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setIndex,
    required Wes2FieldKey fieldKey,
    required dynamic value,
  }) async {
    try {
      await _repository.saveFieldPatch(
        uid: uid,
        date: date,
        row: row,
        setIndex: setIndex,
        fieldKey: fieldKey,
        value: value,
      );
    } catch (_) {
      // Silent failure for Phase 8.
      // Retry queue and error indicator deferred to a future phase.
    }
  }

  void _onToggleMarkedDone(String exerciseId, bool isDone) {
    _controller.toggleMarkedDone(exerciseId, isDone);
    final rowIdx =
        _controller.rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _controller.rows[rowIdx];
    // ignore: discarded_futures
    _setMarkedDoneSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      row: row,
      isDone: isDone,
    );
  }

  Future<void> _setMarkedDoneSilently({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required bool isDone,
  }) async {
    try {
      await _repository.setMarkedDone(
        uid: uid,
        date: date,
        row: row,
        isDone: isDone,
      );
    } catch (e, st) {
      debugPrint('[WES2] setMarkedDone FAILED: $e\n$st');
    }
  }

  // ── Add Set (Phase 10) ────────────────────────────────────────────────────

  void _onAddSet(String exerciseId) {
    _controller.addSet(exerciseId);
    // Persist new setCount to local draft immediately so blank added sets
    // survive fast reopen, especially for BB3-planned rows where no Firestore
    // write occurs until the user types an actual value.
    _saveDraftNow();

    final rowIdx =
        _controller.rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _controller.rows[rowIdx];

    // BB3-planned rows with no actuals are not yet materialised in the workout
    // document — skip Firestore until the first actual value is typed.
    if (row.source == Wes2RowSource.bb3Planned && !row.hasAnyExecutionValue) {
      return;
    }

    // ignore: discarded_futures
    _saveSetCountSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      row: row,
      setCount: row.setCount,
    );
  }

  Future<void> _saveSetCountSilently({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setCount,
  }) async {
    try {
      await _repository.saveSetCount(
        uid: uid,
        date: date,
        row: row,
        setCount: setCount,
      );
    } catch (_) {
      // Silent failure; local draft preserves setCount for next reopen.
    }
  }

  /// Parses [text] into the correct Dart type for [fieldKey].
  /// Returns null if [text] cannot be parsed (invalid non-empty input).
  static dynamic _parseFieldValue(Wes2FieldKey fieldKey, String text) {
    switch (fieldKey) {
      case Wes2FieldKey.weight:
        return double.tryParse(text);
      case Wes2FieldKey.reps:
        return int.tryParse(text);
      case Wes2FieldKey.rir:
        return double.tryParse(text);
      case Wes2FieldKey.velocity:
        return double.tryParse(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<Wes2SessionController>.value(
      value: _controller,
      child: Consumer<Wes2SessionController>(
        builder: (context, controller, _) {
          final uc = UserContext.of(context); // listen:true → rebuilds on athlete switch
          final actingUid = uc.currentUid;
          if (_fetchedForUid != actingUid) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _fetchedForUid != actingUid) _fetchAthleteUsername(actingUid);
            });
          }
          return Scaffold(
          appBar: AppBar(
            title: const Text(' '),
            actions: [
              if (_athleteGreeting != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _athleteGreeting!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.secondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (_athleteUsername != null)
                          Text(
                            _athleteUsername!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.secondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(left: 4, right: 4),
                child: Image.asset(
                  'assets/InApp/transparent_good_lift_logo_inApp.png',
                  height: 44,
                  fit: BoxFit.contain,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.undo),
                tooltip: 'Undo',
                onPressed: controller.canUndo ? _performUndo : null,
              ),
              IconButton(
                icon: const Icon(
                  Icons.auto_awesome,
                  color: Colors.amberAccent,
                ),
                tooltip: 'Refresh',
                onPressed: () {
                  _saveDraftNow();
                  _loadDay();
                },
              ),
              PopupMenuButton<_Wes2AppBarMenuAction>(
                icon: const Icon(Icons.more_vert),
                onSelected: (action) {
                  switch (action) {
                    case _Wes2AppBarMenuAction.timer:
                      _toggleTimerVisible();
                      break;
                    case _Wes2AppBarMenuAction.templates:
                      _showTemplatePicker();
                      break;
                    case _Wes2AppBarMenuAction.deleteAll:
                      _onDeleteAllExercisesForDay();
                      break;
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: _Wes2AppBarMenuAction.timer,
                    height: 40,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.timer_outlined, size: 18),
                        SizedBox(width: 10),
                        Text('Timer'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: _Wes2AppBarMenuAction.templates,
                    height: 40,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.layers_outlined, size: 18),
                        SizedBox(width: 10),
                        Text('Templates'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: _Wes2AppBarMenuAction.deleteAll,
                    height: 40,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.delete_outline, size: 18,
                            color: Colors.redAccent),
                        SizedBox(width: 10),
                        Text('Delete Day',
                            style: TextStyle(color: Colors.redAccent)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: Stack(
            children: [
              Column(
                children: [
                  Wes2DayHeader(
                    date: controller.selectedDate,
                    onSelectDate: _onSelectDate,
                    onPrevDay: _onPrevDay,
                    onNextDay: _onNextDay,
                  ),
                  const Divider(height: 1),
                  Expanded(child: _buildBody(context, controller)),
                ],
              ),
              if (_timerVisible)
                Positioned(
                  right: 12,
                  bottom: MediaQuery.of(context).padding.bottom + 2,
                  child: _buildFloatingTimer(),
                ),
            ],
          ),
        );
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, Wes2SessionController controller) {
    // Error state: full-screen message, no action bar.
    if (controller.loadState == Wes2LoadState.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not load workout.\n${controller.loadErrorMessage ?? ''}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.red, fontSize: 14),
          ),
        ),
      );
    }
    // All non-error states show the top action bar so Add Exercise is always
    // reachable — including during loading (queues the add until data arrives).
    return Column(
      children: [
        Wes2TopActionsBar(
            onAddExercise: _onAddExercise,
            onLoadTemplate: _showTemplatePicker),
        if (controller.hasPendingExerciseAdds &&
            (controller.loadState == Wes2LoadState.loading ||
                controller.loadState == Wes2LoadState.idle))
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              'Adding exercises when loaded…',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ),
        Expanded(child: _buildContentArea(context, controller)),
      ],
    );
  }

  Widget _buildContentArea(
      BuildContext context, Wes2SessionController controller) {
    switch (controller.loadState) {
      case Wes2LoadState.idle:
      case Wes2LoadState.loading:
        return const Center(child: Wes2WaitForIt());
      case Wes2LoadState.empty:
        return ListView(
          children: [
            const Wes2EmptyState(),
            Wes2BottomActionsRow(
              setsLogged: 0,
              onAddCircuit: _onAddCircuit,
              onSummary: _showWorkoutSummary,
            ),
          ],
        );
      case Wes2LoadState.loaded:
        final rows = controller.rows;
        final setsLogged =
            rows.expand((r) => r.sets).where((s) => s.hasAnyActual).length;

        // Build flat item list: circuit headers inserted when circuitIndex changes.
        final items = <Widget>[];
        int? prevCi;
        for (final row in rows) {
          if (prevCi == null || row.circuitIndex != prevCi) {
            final ci = row.circuitIndex;
            items.add(
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  children: [
                    Text(
                      'Circuit ${ci + 1}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text(
                        'Add Exercise',
                        style: TextStyle(fontSize: 12),
                      ),
                      onPressed: () => _onAddExerciseToCircuit(ci),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.primary,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
            );
            prevCi = ci;
          }
          final combinedNote = _buildCombinedPlanNote(row);
          items.add(Wes2ExerciseCard(
            row: row,
            onFieldUnfocused: _onFieldUnfocused,
            onToggleMarkedDone: (isDone) =>
                _onToggleMarkedDone(row.exerciseId, isDone),
            onAddSet: () => _onAddSet(row.exerciseId),
            onSettings: () => _showExerciseSettingsDialog(row),
            onDelete: () => _onDeleteExercise(row),
            onReplace: () => _onReplaceExercise(row),
            onMoveToCircuit: () => _onMoveExerciseToCircuit(row),
            onNotes: () => _showNotesPlaceholder(),
            onRemoveSet: (setIndex) => _onRemoveSet(row, setIndex),
            onNoteTap: (setIndex) => _onOpenSetNoteDialog(row, setIndex),
            onExerciseDetails: () => _navigateToExerciseDetails(row),
            onTopSets: () => _navigateToTopSets(row),
            isExercisePlanNoteRead:
                controller.isExercisePlanNoteRead(row.exerciseId),
            onOpenExercisePlanNote: combinedNote != null
                ? () => _onOpenExercisePlanNoteDialog(row, combinedNote)
                : null,
          ));
        }

        items.add(Wes2BottomActionsRow(
          setsLogged: setsLogged,
          onAddCircuit: _onAddCircuit,
          onSummary: _showWorkoutSummary,
          onSaveAsTemplate: controller.canSaveAsTemplate
              ? _showSaveAsTemplateDialog
              : null,
        ));
        return ListView(children: items);
      case Wes2LoadState.error:
        return const SizedBox.shrink(); // unreachable: handled in _buildBody
    }
  }

  // ── Add Exercise / Add Circuit (Phase 13) ────────────────────────────────

  /// Opens the picker and returns the selection including chosen circuit,
  /// or null if dismissed.
  /// [excludedIds] defaults to all current row IDs when omitted.
  /// [titleOverride] replaces the default "Add Exercise to Circuit N" header.
  Future<({String exerciseId, String name, int circuitIndex})?>
      _openExercisePicker({
    required List<int> availableCircuits,
    required int initialCircuitIndex,
    Set<String>? excludedIds,
    String? titleOverride,
  }) {
    final excluded =
        excludedIds ?? _controller.rows.map((r) => r.exerciseId).toSet();
    return showModalBottomSheet<
        ({String exerciseId, String name, int circuitIndex})>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => Wes2ExercisePicker(
        excludedIds: excluded,
        actingUid: _controller.actingUid,
        activeBlockId: _controller.activeBlockId,
        availableCircuits: availableCircuits,
        initialCircuitIndex: initialCircuitIndex,
        titleOverride: titleOverride,
      ),
    );
  }

  /// Applies a picker result to the controller, local draft, and Firestore.
  /// Immediate path: day loaded — persists via saveManualExercise now.
  /// Queue path (loading/idle): deferred to consumeFlushedExercises in _loadDay.
  void _addExerciseFromPicker(
      ({String exerciseId, String name, int circuitIndex}) result) {
    final added = _controller.addExercise(
      result.exerciseId,
      result.name,
      circuitIndex: result.circuitIndex,
    );
    if (!added) return;
    _saveDraftNow();
    if (_controller.loadState == Wes2LoadState.loaded) {
      final rowIdx =
          _controller.rows.indexWhere((r) => r.exerciseId == result.exerciseId);
      if (rowIdx != -1) {
        // ignore: discarded_futures
        _saveManualExerciseSilently(
          uid: _controller.actingUid,
          date: _controller.selectedDate,
          row: _controller.rows[rowIdx],
        );
      }
      // ignore: discarded_futures
      _loadAndApplyHints();
    }
  }

  /// Top "Add Exercise" button — defaults to Circuit 1.
  /// Shows circuit selector inside picker when multiple circuits exist.
  Future<void> _onAddExercise() async {
    final circuits =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final result = await _openExercisePicker(
      availableCircuits: circuits,
      initialCircuitIndex: 0,
    );
    if (result == null) return;
    _addExerciseFromPicker(result);
  }

  /// Per-circuit header "Add Exercise" button — pre-selects that circuit.
  Future<void> _onAddExerciseToCircuit(int targetCircuitIndex) async {
    final circuits =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final result = await _openExercisePicker(
      availableCircuits: circuits,
      initialCircuitIndex: targetCircuitIndex,
    );
    if (result == null) return;
    _addExerciseFromPicker(result);
  }

  /// Bottom "Add Circuit" button — pre-selects a new circuit index.
  /// Passes existing circuits + new one so the user may redirect to any.
  Future<void> _onAddCircuit() async {
    if (_controller.loadState != Wes2LoadState.loaded) return;
    final existing =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final nextCircuitIndex = existing.isEmpty ? 0 : existing.last + 1;
    final result = await _openExercisePicker(
      availableCircuits: [...existing, nextCircuitIndex],
      initialCircuitIndex: nextCircuitIndex,
    );
    if (result == null) return;
    _addExerciseFromPicker(result);
  }

  Future<void> _saveManualExerciseSilently({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
  }) async {
    try {
      await _repository.saveManualExercise(
        uid: uid,
        date: date,
        row: row,
      );
    } catch (_) {
      // Silent failure; local draft preserves the row for next reopen.
    }
  }

  // ── Date navigation (Phase 13) ────────────────────────────────────────────

  void _onPrevDay() {
    _pauseWorkoutDurationSegment();
    _saveDraftNow();
    _workoutDurationMilliseconds = 0;
    _workoutDurationSegmentStartedAt = null;
    _controller
        .changeDate(_controller.selectedDate.subtract(const Duration(days: 1)));
    _loadDay();
  }

  void _onNextDay() {
    _pauseWorkoutDurationSegment();
    _saveDraftNow();
    _workoutDurationMilliseconds = 0;
    _workoutDurationSegmentStartedAt = null;
    _controller
        .changeDate(_controller.selectedDate.add(const Duration(days: 1)));
    _loadDay();
  }

  Future<void> _onSelectDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _controller.selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day + 365),
    );
    if (picked == null || !mounted) return;
    _pauseWorkoutDurationSegment();
    _saveDraftNow();
    _workoutDurationMilliseconds = 0;
    _workoutDurationSegmentStartedAt = null;
    _controller.changeDate(picked);
    _loadDay();
  }

  // ── Undo (Phase 15) ──────────────────────────────────────────────────────

  void _performUndo() {
    _controller.undo();
    _saveDraftNow();
    // Restore BB3 planned-day structure from the recovered row set.
    // ignore: discarded_futures
    _syncBb3PlannedDayFromCurrentRowsSilently();
  }

  void _showUndoSnackBar(String label) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(label),
          action: SnackBarAction(label: 'Undo', onPressed: _performUndo),
        ),
      );
  }

  // ── Snackbar / confirm helpers (Phase 13) ─────────────────────────────────

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _showConfirmDialog({
    required String title,
    required String content,
  }) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<int?> _showCircuitPickerDialog(List<int> circuits) async {
    if (!mounted) return null;
    return showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Move to Circuit'),
        children: circuits
            .map((ci) => SimpleDialogOption(
                  onPressed: () => Navigator.of(ctx).pop(ci),
                  child: Text('Circuit ${ci + 1}'),
                ))
            .toList(),
      ),
    );
  }

  // ── Exercise settings dialog (Phase 19) ──────────────────────────────────

  Future<void> _showExerciseSettingsDialog(Wes2ExerciseRow row) async {
    final blockId = _controller.activeBlockId;
    final blockStart = _controller.blockStartDate;
    if (blockId == null ||
        blockId.isEmpty ||
        blockStart == null) {
      _showSnackBar('No active block — settings require a training block.');
      return;
    }
    if (_isBeforeBlockStart(_controller.selectedDate, blockStart)) {
      _showSnackBar('This date is before the active block start.');
      return;
    }
    final wd = _weekDayFromDate(blockStart, _controller.selectedDate);
    final blockEndDate = _controller.blockEndDate;
    int totalBlockWeeks;
    if (blockEndDate != null) {
      totalBlockWeeks = (blockEndDate.difference(blockStart).inDays ~/ 7) + 1;
    } else {
      totalBlockWeeks = wd.weekIndex + 52;
    }

    // Compute history-aware active instance for DUP models so settings cog
    // shows the same instance as ProgressionEngine.
    int? resolvedActiveInstance;
    final cogExSettings = _cachedExerciseSettings[row.exerciseId] as Map<String, dynamic>?;
    final cogModel = (cogExSettings?['periodizationModel'] as String?) ?? '';
    if (cogModel == 'DUP, By Exposure' || cogModel == 'DUP, By Week') {
      final cogWeek1 = (cogExSettings?['repTargets'] as Map?)?['week1'];
      final cogSorted = (cogWeek1 is Map<String, dynamic>)
          ? (cogWeek1.entries.where((e) => e.key.startsWith('instance')).toList()
              ..sort((a, b) => a.key.compareTo(b.key)))
          : <MapEntry<String, dynamic>>[];
      int cogPlannedBefore = 0;
      for (final r in _controller.rows) {
        if (r == row) break;
        if (r.exerciseId == row.exerciseId) cogPlannedBefore++;
      }
      final cogRes = ProgressionEngine.resolveDupActiveInstance(
        exerciseId: row.exerciseId,
        exerciseName: row.name,
        blockStartDate: blockStart,
        selectedDate: _controller.selectedDate,
        weekIndex: wd.weekIndex,
        sorted: cogSorted,
        plannedCountBefore: cogPlannedBefore,
        byWeek: cogModel == 'DUP, By Week',
      );
      resolvedActiveInstance = cogRes?.instanceNumber;
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => Wes2ExerciseSettingsDialog(
        uid: _controller.actingUid,
        blockId: blockId,
        exerciseId: row.exerciseId,
        exerciseName: row.name,
        weekIndex: wd.weekIndex,
        dayIndex: wd.dayIndex,
        totalBlockWeeks: totalBlockWeeks,
        planService: _planService,
        resolvedActiveInstanceOverride: resolvedActiveInstance,
      ),
    );
    if (saved == true && mounted) {
      _cachedExerciseSettings = await _planService.loadExerciseSettings(
        uid: _controller.actingUid,
        blockId: blockId,
      );
      _controller.setExerciseSettings(_cachedExerciseSettings);
      await _loadAndApplyHints();
    }
  }

  void _showNotesPlaceholder() {
    _showSnackBar('Use the note icon beside each set to add notes.');
  }

  void _navigateToExerciseDetails(Wes2ExerciseRow row) {
    if (_controller.actingUid.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExerciseDetailsScreen(
          exerciseId: row.exerciseId,
          exerciseName: row.name,
        ),
      ),
    );
  }

  void _navigateToTopSets(Wes2ExerciseRow row) {
    if (_controller.actingUid.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TopSetsScreen(
          exerciseName: row.name,
          exerciseId: row.exerciseId,
          recentWorkouts: const [],
        ),
      ),
    );
  }

  String? _buildCombinedPlanNote(Wes2ExerciseRow row) {
    final lines = <String>[];
    if (row.exercisePlanNote != null && row.exercisePlanNote!.trim().isNotEmpty) {
      lines.add('Exercise note: ${row.exercisePlanNote!.trim()}');
    }
    for (int i = 0; i < row.sets.length; i++) {
      final note = row.sets[i].planNote?.trim();
      if (note != null && note.isNotEmpty) {
        lines.add('Set ${i + 1}: $note');
      }
    }
    return lines.isEmpty ? null : lines.join('\n\n');
  }

  Future<void> _onOpenExercisePlanNoteDialog(
      Wes2ExerciseRow row, String combinedNote) async {
    _controller.markExercisePlanNoteRead(row.exerciseId);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          row.name,
          style: const TextStyle(fontSize: 16),
        ),
        content: Text(combinedNote),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _showTemplatePicker() async {
    if (_controller.actingUid.isEmpty) return;
    final templateId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => Wes2TemplatePicker(
        uid: _controller.actingUid,
        activeBlockId: _controller.activeBlockId,
      ),
    );
    if (templateId == null || !mounted) return;
    await _onLoadTemplate(templateId);
  }

  // ── Delete Day (Phase 18b) ────────────────────────────────────────────────

  Future<void> _onDeleteAllExercisesForDay() async {
    if (_controller.rows.isEmpty) {
      _showSnackBar('No exercises to delete.');
      return;
    }
    final confirmed = await _showConfirmDialog(
      title: 'Delete Day',
      content: 'Delete all exercises for this day, are you sure?',
    );
    if (!confirmed || !mounted) return;

    final hadBb3Rows =
        _bb3PlannedExerciseIds.isNotEmpty ||
        _controller.rows.any((r) =>
            r.source == Wes2RowSource.bb3Planned ||
            _bb3PlannedExerciseIds.contains(r.exerciseId));

    _controller.deleteAllExercises();
    _saveDraftNow();
    _showUndoSnackBar('All exercises deleted');

    // ignore: discarded_futures
    _deleteAllExercisesForDaySilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
    );

    if (hadBb3Rows) {
      final blockId = _controller.activeBlockId;
      final blockStart = _controller.blockStartDate;
      if (blockId != null && blockId.isNotEmpty && blockStart != null) {
        final wd = _weekDayFromDate(blockStart, _controller.selectedDate);
        // ignore: discarded_futures
        _clearBb3PlannedDaySilently(
          uid: _controller.actingUid,
          blockId: blockId,
          weekIndex: wd.weekIndex,
          dayIndex: wd.dayIndex,
        );
      }
    }
  }

  Future<void> _deleteAllExercisesForDaySilently({
    required String uid,
    required DateTime date,
  }) async {
    try {
      await _repository.deleteAllExercisesForDay(uid: uid, date: date);
    } catch (_) {
      // Silent failure; local draft preserves empty state for next reopen.
    }
  }

  // ── Structural exercise actions (Phase 13) ────────────────────────────────

  Future<void> _onDeleteExercise(Wes2ExerciseRow row) async {
    final hadActuals = row.hasAnyExecutionValue;
    // Capture before the async confirm gap. A row that reloaded as
    // completedServer (actual values saved) still needs BB3 sync if it was
    // originally BB3-planned on this date.
    final wasBb3 = row.source == Wes2RowSource.bb3Planned ||
        _bb3PlannedExerciseIds.contains(row.exerciseId);
    final confirmed = await _showConfirmDialog(
      title: 'Delete Exercise',
      content: 'Remove "${row.name}" from today\'s workout?',
    );
    if (!confirmed) return;
    _controller.deleteExercise(row.exerciseId);
    _saveDraftNow();
    if (hadActuals) _showUndoSnackBar('Exercise deleted');
    // ignore: discarded_futures
    _deleteExerciseSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      exerciseId: row.exerciseId,
    );
    if (wasBb3) {
      // ignore: discarded_futures
      _syncBb3PlannedDayFromCurrentRowsSilently();
    }
  }

  Future<void> _onReplaceExercise(Wes2ExerciseRow row) async {
    final excludedIds = _controller.rows
        .map((r) => r.exerciseId)
        .where((id) => id != row.exerciseId)
        .toSet();
    final circuits =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final result = await _openExercisePicker(
      availableCircuits: circuits,
      initialCircuitIndex: row.circuitIndex,
      excludedIds: excludedIds,
      titleOverride: 'Replace "${row.name}"',
    );
    if (result == null) return;
    _controller.replaceExercise(
      oldExerciseId: row.exerciseId,
      newExerciseId: result.exerciseId,
      newName: result.name,
    );
    _saveDraftNow();
    // ignore: discarded_futures
    _loadAndApplyHints();
    _showUndoSnackBar('Exercise replaced');
    // ignore: discarded_futures
    _replaceExerciseSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      oldExerciseId: row.exerciseId,
      newExerciseId: result.exerciseId,
      newName: result.name,
    );
    if (row.source == Wes2RowSource.bb3Planned) {
      // ignore: discarded_futures
      _syncBb3PlannedDayFromCurrentRowsSilently();
    }
  }

  Future<void> _onMoveExerciseToCircuit(Wes2ExerciseRow row) async {
    final circuits =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final available = circuits.where((ci) => ci != row.circuitIndex).toList();
    if (available.isEmpty) {
      _showSnackBar('Only one circuit — add another circuit first.');
      return;
    }
    final targetCi = await _showCircuitPickerDialog(available);
    if (targetCi == null) return;
    _controller.moveExerciseToCircuit(row.exerciseId, targetCi);
    _saveDraftNow();
    _showUndoSnackBar('Exercise moved to Circuit ${targetCi + 1}');
    // ignore: discarded_futures
    _moveExerciseToCircuitSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      exerciseId: row.exerciseId,
      targetCircuitIndex: targetCi,
    );
    if (row.source == Wes2RowSource.bb3Planned) {
      // ignore: discarded_futures
      _syncBb3PlannedDayFromCurrentRowsSilently();
    }
  }

  // ── Silent Firestore wrappers (Phase 13) ──────────────────────────────────

  Future<void> _deleteExerciseSilently({
    required String uid,
    required DateTime date,
    required String exerciseId,
  }) async {
    try {
      await _repository.deleteExercise(
        uid: uid,
        date: date,
        exerciseId: exerciseId,
      );
    } catch (_) {
      // Silent failure; row already removed from local state and draft.
    }
  }

  Future<void> _replaceExerciseSilently({
    required String uid,
    required DateTime date,
    required String oldExerciseId,
    required String newExerciseId,
    required String newName,
  }) async {
    try {
      await _repository.replaceExercise(
        uid: uid,
        date: date,
        oldExerciseId: oldExerciseId,
        newExerciseId: newExerciseId,
        newName: newName,
      );
    } catch (_) {
      // Silent failure; local draft preserves updated row.
    }
  }

  Future<void> _moveExerciseToCircuitSilently({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int targetCircuitIndex,
  }) async {
    try {
      await _repository.moveExerciseToCircuit(
        uid: uid,
        date: date,
        exerciseId: exerciseId,
        targetCircuitIndex: targetCircuitIndex,
      );
    } catch (_) {
      // Silent failure; local draft preserves circuit assignment.
    }
  }

  // ── Remove Set (Phase 14) ─────────────────────────────────────────────────

  Future<void> _onRemoveSet(Wes2ExerciseRow row, int setIndex) async {
    // Always re-fetch by exerciseId so we have the latest in-memory state.
    final currentRow = _controller.rows.firstWhere(
      (r) => r.exerciseId == row.exerciseId,
      orElse: () => row,
    );

    if (currentRow.source == Wes2RowSource.bb3Planned) {
      _showSnackBar(
          'Removing sets from BB3 planned exercises will be added in a later phase.');
      return;
    }

    // One-set removal routes to exercise deletion.
    if (currentRow.setCount <= 1) {
      final confirmed = await _showConfirmDialog(
        title: 'Delete Exercise',
        content:
            'This is the only set. Removing it will delete "${currentRow.name}". Continue?',
      );
      if (!confirmed || !mounted) return;
      _controller.deleteExercise(currentRow.exerciseId);
      _saveDraftNow();
      if (currentRow.hasAnyExecutionValue) _showUndoSnackBar('Exercise deleted');
      // ignore: discarded_futures
      _deleteExerciseSilently(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
        exerciseId: currentRow.exerciseId,
      );
      return;
    }

    // Find the target set in current in-memory state.
    final targetSet = currentRow.sets.firstWhere(
      (s) => s.setIndex == setIndex,
      orElse: () => Wes2SetState(setIndex: setIndex),
    );

    // Confirm only when the set carries actual logged values.
    if (targetSet.hasAnyActual) {
      final confirmed = await _showConfirmDialog(
        title: 'Remove Set',
        content: 'Removing this set will remove its logged values. Continue?',
      );
      if (!confirmed || !mounted) return;
    }

    _controller.removeSet(currentRow.exerciseId, setIndex);
    _saveDraftNow();
    final hasUserValues = targetSet.hasAnyActual ||
        (targetSet.executionNote?.trim().isNotEmpty ?? false);
    if (hasUserValues) _showUndoSnackBar('Set removed');
    // ignore: discarded_futures
    _removeSetSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      exerciseId: currentRow.exerciseId,
      setIndex: setIndex,
    );
  }

  Future<void> _removeSetSilently({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
  }) async {
    try {
      await _repository.removeSet(
        uid: uid,
        date: date,
        exerciseId: exerciseId,
        setIndex: setIndex,
      );
    } catch (_) {
      // Silent failure; local draft preserves current set state.
    }
  }

  // ── Set notes (Phase 16) ──────────────────────────────────────────────────

  Future<void> _onOpenSetNoteDialog(Wes2ExerciseRow row, int setIndex) async {
    // Always re-fetch from controller so we have the latest in-memory state.
    final currentRow = _controller.rows.firstWhere(
      (r) => r.exerciseId == row.exerciseId,
      orElse: () => row,
    );
    final set = currentRow.sets.firstWhere(
      (s) => s.setIndex == setIndex,
      orElse: () => Wes2SetState(setIndex: setIndex),
    );

    if (set.planNote != null) {
      _controller.markPlanNoteRead(currentRow.exerciseId, setIndex);
    }

    final noteCtrl = TextEditingController(text: set.executionNote ?? '');
    try {
      final saved = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text(
            '${currentRow.name} — Set ${setIndex + 1} Notes',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (set.planNote != null) ...[
                const Text(
                  'Plan note',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
                const SizedBox(height: 4),
                Text(
                  set.planNote!,
                  style: const TextStyle(fontSize: 13),
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                ),
                const Divider(height: 20),
              ],
              const Text(
                'Execution note',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: noteCtrl,
                maxLines: 4,
                minLines: 2,
                autofocus: set.planNote == null,
                decoration: const InputDecoration(
                  hintText: 'Add a note for this set…',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(noteCtrl.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );

      if (saved == null || !mounted) return;

      // Yield one frame so the dialog route fully deactivates and removes its
      // Overlay entry before notifyListeners() fires a Provider rebuild.
      // Calling notifyListeners() while the Overlay still has dependents
      // triggers the '_dependents.isEmpty' assertion in debug mode.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      final trimmed = saved.trim();
      _controller.updateExecutionNote(
        exerciseId: currentRow.exerciseId,
        setIndex: setIndex,
        rawText: trimmed,
      );
      _saveDraftNow();
      // ignore: discarded_futures
      _saveExecutionNoteSilently(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
        exerciseId: currentRow.exerciseId,
        setIndex: setIndex,
        note: trimmed.isEmpty ? null : trimmed,
      );
    } finally {
      noteCtrl.dispose();
    }
  }

  Future<void> _saveExecutionNoteSilently({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String? note,
  }) async {
    try {
      await _repository.saveExecutionNote(
        uid: uid,
        date: date,
        exerciseId: exerciseId,
        setIndex: setIndex,
        note: note,
      );
    } catch (_) {
      // Silent failure; local draft preserves the note for next reopen.
    }
  }

  // ── Floating timer widget (Phase 17) ──────────────────────────────────────

  Widget _buildFloatingTimer() {
    return Card(
      elevation: 8,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatDuration(_elapsedMilliseconds, includeSplitSeconds: true),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 24, height: 24),
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'Close timer',
                  onPressed: _closeTimer,
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: _timerRunning ? _stopTimer : _startTimer,
                  style: TextButton.styleFrom(
                    foregroundColor: _timerRunning
                        ? Colors.redAccent
                        : Colors.greenAccent,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(
                    _timerRunning ? 'Stop' : 'Start',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 2),
                TextButton(
                  onPressed: _timerRunning ? null : _resetTimer,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Reset', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Template load (Phase 18) ──────────────────────────────────────────────

  Future<void> _onLoadTemplate(String templateId) async {
    List<Wes2ExerciseRow> templateRows;
    try {
      templateRows = await _templateService.loadTemplate(
        uid: _controller.actingUid,
        templateId: templateId,
      );
    } catch (_) {
      _showSnackBar('Failed to load template.');
      return;
    }
    if (templateRows.isEmpty) {
      _showSnackBar('Template has no loadable exercises.');
      return;
    }
    if (!mounted) return;

    // Deduplicate and normalize template rows before loading.
    final hardened = _hardened(templateRows);
    final reindexed = List.generate(
      hardened.length,
      (i) => hardened[i].copyWith(orderIndex: i),
    );

    final hadAnyRows = _controller.rows.isNotEmpty;
    final hadBb3Rows = _controller.rows
        .any((r) => r.source == Wes2RowSource.bb3Planned);

    _controller.replaceWithTemplateRows(reindexed);
    _saveDraftNow();
    // ignore: discarded_futures
    _loadAndApplyHints();

    // Persist: clear exercises[] + wesPlanned[], write template rows to wesPlanned.
    // ignore: discarded_futures
    _replaceWithTemplateRowsSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      rows: reindexed,
    );

    // Clear BB3 planned day if pre-replacement had BB3-sourced rows.
    if (hadBb3Rows) {
      final blockId = _controller.activeBlockId;
      final blockStart = _controller.blockStartDate;
      if (blockId != null && blockId.isNotEmpty && blockStart != null) {
        final wd = _weekDayFromDate(blockStart, _controller.selectedDate);
        // ignore: discarded_futures
        _clearBb3PlannedDaySilently(
          uid: _controller.actingUid,
          blockId: blockId,
          weekIndex: wd.weekIndex,
          dayIndex: wd.dayIndex,
        );
      }
    }

    if (hadAnyRows && mounted) {
      _showUndoSnackBar('Exercises replaced by template');
    }
  }

  Future<void> _replaceWithTemplateRowsSilently({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
  }) async {
    try {
      await _repository.replaceAllWithTemplateRows(
        uid: uid,
        date: date,
        rows: rows,
      );
    } catch (_) {
      // Silent failure; local draft preserves the template rows.
    }
  }

  // ── BB3 planned-day sync (Phase 20) ──────────────────────────────────────

  /// Syncs the current BB3-sourced rows back to the active BB3 planned-day
  /// path. Called after structural edits on BB3-sourced rows and after undo.
  /// Scoped strictly to the current blockId / weekIndex / dayIndex.
  Future<void> _syncBb3PlannedDayFromCurrentRowsSilently() async {
    final blockId = _controller.activeBlockId;
    final blockStart = _controller.blockStartDate;
    if (blockId == null || blockId.isEmpty || blockStart == null) return;
    if (_isBeforeBlockStart(_controller.selectedDate, blockStart)) return;
    final wd = _weekDayFromDate(blockStart, _controller.selectedDate);
    final bb3Rows = _controller.rows
        .where((r) =>
            r.source == Wes2RowSource.bb3Planned ||
            _bb3PlannedExerciseIds.contains(r.exerciseId))
        .toList();
    try {
      await _planService.updatePlannedDay(
        uid: _controller.actingUid,
        blockId: blockId,
        weekIndex: wd.weekIndex,
        dayIndex: wd.dayIndex,
        updatedRows: bb3Rows,
      );
    } catch (_) {
      // Silent failure; local draft preserves structural state.
    }
  }

  Future<void> _clearBb3PlannedDaySilently({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
  }) async {
    try {
      await _planService.updatePlannedDay(
        uid: uid,
        blockId: blockId,
        weekIndex: weekIndex,
        dayIndex: dayIndex,
        updatedRows: const [],
      );
    } catch (_) {
      // Silent failure; BB3 clear is best-effort.
    }
  }

  // ── Save Workout as Template (Phase 18) ──────────────────────────────────

  Future<void> _showSaveAsTemplateDialog() async {
    if (!mounted) return;
    final nameCtrl = TextEditingController();
    try {
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Save as Template'),
          content: TextField(
            controller: nameCtrl,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => Navigator.of(ctx).pop(nameCtrl.text),
            decoration: const InputDecoration(
              hintText: 'Template name',
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                  horizontal: 10, vertical: 8),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(nameCtrl.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (result == null || !mounted) return;
      final name = result.trim();
      if (name.isEmpty) return;
      try {
        await _templateService.saveWorkoutAsTemplate(
          uid: _controller.actingUid,
          blockId: _controller.activeBlockId,
          templateName: name,
          rows: _controller.rows.toList(),
        );
        if (mounted) _showSnackBar('Template saved.');
      } catch (_) {
        if (mounted) _showSnackBar('Failed to save template.');
      }
    } finally {
      nameCtrl.dispose();
    }
  }

  // ── Workout summary (Phase 17) ────────────────────────────────────────────

  void _showWorkoutSummary() {
    final rows = _controller.rows;
    final date = _controller.selectedDate;
    final dateStr =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';

    final totalExercises = rows.length;
    final totalSets = rows.fold(0, (int s, r) => s + r.setCount);
    final setsLogged =
        rows.expand((r) => r.sets).where((s) => s.hasAnyActual).length;
    double totalVolume = 0;
    for (final row in rows) {
      for (final set in row.sets) {
        final w = set.weight.actualValue;
        final r = set.reps.actualValue;
        if (w != null && r != null) totalVolume += w * r;
      }
    }

    // Per-circuit exercise breakdown.
    final circuitMap = <int, List<Wes2ExerciseRow>>{};
    for (final row in rows) {
      circuitMap.putIfAbsent(row.circuitIndex, () => []).add(row);
    }
    final sortedCircuits = circuitMap.keys.toList()..sort();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        minChildSize: 0.25,
        builder: (_, scrollCtrl) => ListView(
          controller: scrollCtrl,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          children: [
            Text(
              'Workout Summary',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
            const SizedBox(height: 2),
            Text(
              dateStr,
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const Divider(height: 20),
            _summaryStatRow('Exercises', '$totalExercises'),
            _summaryStatRow('Total sets', '$totalSets'),
            _summaryStatRow('Sets logged', '$setsLogged'),
            if (_currentWorkoutDurationMs() > 0)
              _summaryStatRow(
                'Workout duration',
                _formatDuration(_currentWorkoutDurationMs()),
              ),
            if (_elapsedMilliseconds > 0)
              _summaryStatRow(
                'Last thing you timed',
                _formatDuration(_elapsedMilliseconds),
              ),
            if (totalVolume > 0)
              _summaryStatRow(
                'Total volume',
                '${totalVolume.toStringAsFixed(0)} kg·reps',
              ),
            if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'No exercises logged yet.',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
            if (rows.isNotEmpty) ...[
              const SizedBox(height: 16),
              for (final ci in sortedCircuits) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Circuit ${ci + 1}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                for (final row in circuitMap[ci]!)
                  _summaryExerciseRow(row),
                const SizedBox(height: 8),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _summaryStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryExerciseRow(Wes2ExerciseRow row) {
    final loggedSets = row.sets.where((s) => s.hasAnyActual).length;
    double vol = 0;
    for (final s in row.sets) {
      final w = s.weight.actualValue;
      final r = s.reps.actualValue;
      if (w != null && r != null) vol += w * r;
    }
    final volStr = vol > 0 ? ' · ${vol.toStringAsFixed(0)}' : '';
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              row.name,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$loggedSets/${row.setCount} sets$volStr',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ],
      ),
    );
  }
}
