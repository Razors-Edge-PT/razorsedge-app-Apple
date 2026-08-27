import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'bb3_day_panel.dart';
import 'bb3_models.dart';
import 'bb3_planned_exercise_service.dart';
import 'exercise_catalog.dart';
import 'planned_only_resolver.dart';
import 'template_model.dart';
import 'user_context.dart';

// ─── BB3WeekPlanner ──────────────────────────────────────────────────────────
//
// Main BB3 screen: vertical day stack per week, horizontal swipe between weeks.
//
// Layout:
//   • PageView (horizontal) — each page = one week
//   • Each page = ListView (vertical) — one BB3DayPanel per day (Mon–Sun)
//
// Block switching jumps to the block's start week (spec requirement).
// Outside-block days show a banner; fallback/default hints still render.

class BB3WeekPlanner extends StatefulWidget {
  const BB3WeekPlanner({super.key});

  @override
  State<BB3WeekPlanner> createState() => _BB3WeekPlannerState();
}

class _BB3WeekPlannerState extends State<BB3WeekPlanner> {
  // ── State ─────────────────────────────────────────────────────────────────

  late DateTime _weekStart; // always a Monday
  String? _selectedBlockId;
  BB3BlockSettings? _blockSettings;

  // 7-element lists, one per weekday (0=Mon … 6=Sun)
  final List<List<BB3Exercise>> _plannedByDay = List.generate(7, (_) => []);
  final List<List<Map<String, dynamic>>> _completedByDay =
      List.generate(7, (_) => []);
  final List<bool> _loadingByDay = List.filled(7, false);

  List<BB3BlockSettings> _allBlocks = [];
  List<Map<String, dynamic>> _allExercises = [];
  List<Template> _templates = [];
  List<String>? _templateCandidateIds;

  bool _loadingBlocks = false;
  bool _refreshing = false;
  int _loadEpoch = 0;

  // Pre-computed sessionIndex for DUP By Exposure / DUP Signature planned rows.
  // Key: "YYYY-MM-DD_<exerciseId>". Populated asynchronously after _loadWeek.
  final Map<String, int> _hintIndexCache = {};

  // Pre-computed DUP Signature rep targets for planned rows.
  // Key: "YYYY-MM-DD_<exerciseId>". Populated alongside _hintIndexCache.
  final Map<String, int> _dupSigRepCache = {};

  // PageView controller: each page = one week; anchor on a known Monday epoch.
  late final PageController _pageController;

  // Epoch: a known Monday used to convert between week-start dates and page indices.
  // UTC-based so that DST transitions never cause inDays to round to the wrong week.
  static final DateTime _epochUtc = DateTime.utc(2020, 1, 6);
  static final _dateFmt = DateFormat('yyyy-MM-dd');

  static int _weekToPage(DateTime monday) {
    final m = DateTime.utc(monday.year, monday.month, monday.day);
    return m.difference(_epochUtc).inDays ~/ 7;
  }

  static DateTime _pageToWeek(int page) {
    final u = _epochUtc.add(Duration(days: page * 7));
    return DateTime(u.year, u.month, u.day);
  }

  // Date-only equality: ignores time-of-day and DST offsets.
  static bool _sameCalendarDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _weekStart = _mondayOf(DateTime.now());
    _pageController = PageController(initialPage: _weekToPage(_weekStart));
    _boot();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    await Future.wait([
      _loadBlocks(),       // _loadBlocks → _selectBlock → _loadWeek owns the first load
      _loadExercises(),
      _loadTemplates(),
    ]);
    // _loadWeek is called inside _selectBlock; no second call needed here.
  }

  // ── Block list ────────────────────────────────────────────────────────────

  Future<void> _loadBlocks() async {
    final uid = _uid;
    setState(() => _loadingBlocks = true);
    try {
      final blocks = await BB3PlannedExerciseService.listBlocks(uid);
      if (!mounted) return;
      setState(() {
        _allBlocks = blocks;
        _loadingBlocks = false;
      });
      // Auto-select active block from UserContext if present
      final userContext = UserContext.of(context, listen: false);
      final activeId = userContext.activeBlockId;
      if (activeId != null && activeId.isNotEmpty) {
        final match = blocks.where((b) => b.blockId == activeId).toList();
        if (match.isNotEmpty) {
          await _selectBlock(match.first.blockId, jumpToStart: false);
          return;
        }
      }
      // Fall back to most-recent block (list already sorted newest-first)
      if (blocks.isNotEmpty) {
        await _selectBlock(blocks.first.blockId, jumpToStart: false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingBlocks = false);
    }
  }

  // ── Block selection + week jump ───────────────────────────────────────────
  //
  // Spec: changing the selected block must jump to that block's start week.
  // Hint path uses the SELECTED block's exerciseSettings / startDate / endDate
  // exclusively — not the active-block context from UserContext.
  //
  // Hint source trace:
  //   _blockSettings.exerciseSettings → BB3DayPanel.blockSettings.exerciseSettings
  //       → BB3HintService.getHintsForSet(fullExerciseSettings: ...)
  //       → BB3PlannedExerciseService.getRirFromPlan(exSettings: ...) ✓
  //   _blockSettings.startDate → weekIndex computation in _buildPageContent()
  //       → BB3DayPanel.weekIndex → BB3HintService.getHintsForSet(weekIndex: ...) ✓
  //   _blockSettings.startDate / endDate → BB3HintService.getHintsForSet(
  //       blockStartDate: ..., blockEndDate: ...) ✓
  //   No blockId is passed to BB3HintService — the engine uses historical
  //   workout data (uid + date), not Firestore block documents, so blockId
  //   is irrelevant to hint generation. ✓

  Future<void> _reloadBlockSettings() async {
    final blockId = _selectedBlockId;
    if (blockId == null || blockId.isEmpty) return;
    final settings =
        await BB3PlannedExerciseService.getBlockSettings(_uid, blockId);
    if (!mounted) return;
    setState(() => _blockSettings = settings);
  }

  Future<void> _selectBlock(String blockId, {bool jumpToStart = true}) async {
    final uid = _uid;
    final settings =
        await BB3PlannedExerciseService.getBlockSettings(uid, blockId);
    if (!mounted) return;

    // Resolve planned-only IDs: templateCandidateExerciseIds ∪ template-used IDs for this block.
    List<String>? candidateIds;
    try {
      final resolved = await resolvePlannedOnlyIds(uid: uid, blockId: blockId);
      if (resolved.isNotEmpty) candidateIds = resolved.toList();
    } catch (_) {}

    // jumpToStart=true (manual block switch via dropdown): jump to the block's
    // start week so the user immediately sees week 1 of what they selected.
    // jumpToStart=false (auto-select on boot): stay on the current calendar
    // week so BB3 opens to today's week of the active block.
    DateTime newWeekStart = _weekStart;
    if (jumpToStart && settings.startDate != null) {
      newWeekStart = _mondayOf(settings.startDate!);
    }

    setState(() {
      _selectedBlockId = blockId;
      _blockSettings = settings;
      _weekStart = newWeekStart;
      _templateCandidateIds = candidateIds;
    });

    // Animate page controller to the new week (no rebuild needed — setState
    // already updated _weekStart; _loadWeek below loads data for the new week).
    final targetPage = _weekToPage(newWeekStart);
    if (_pageController.hasClients) {
      _pageController.jumpToPage(targetPage);
    }

    await _loadWeek(fromServer: false);
  }

  // ── Exercise library ──────────────────────────────────────────────────────

  Future<void> _loadExercises() async {
    try {
      // Combined pool = global /exercises + the acting account's custom
      // exercises (_uid = selected athlete in coach mode).
      final combined =
          await ExerciseCatalog.loadCombinedExercisesForUser(_uid);
      if (!mounted) return;
      setState(() {
        _allExercises = combined.map((e) => e.toDisplayMap()).toList();
      });
    } catch (_) {}
  }

  // ── Templates ─────────────────────────────────────────────────────────────

  Future<void> _loadTemplates() async {
    final uid = _uid;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('templates')
          .get();
      if (!mounted) return;
      setState(() {
        _templates = snap.docs
            .map((d) => Template.fromFirestore(d.data(), d.id))
            .toList();
      });
    } catch (_) {}
  }

  // ── Week data load ────────────────────────────────────────────────────────

  Future<void> _loadWeek({required bool fromServer}) async {
    final blockId = _selectedBlockId;
    if (blockId == null || blockId.isEmpty) return;
    final uid = _uid;

    // Capture mutable state at call time so all 7 inner futures read the same
    // week/block even if _weekStart or _blockSettings changes mid-flight.
    final localWeekStart = _weekStart;
    final localBlockSettings = _blockSettings;
    final localEpoch = ++_loadEpoch;

    debugPrint('[BB3 loadWeek start] epoch=$localEpoch weekStart=$localWeekStart block=$blockId fromServer=$fromServer');

    setState(() {
      _hintIndexCache.clear();
      _dupSigRepCache.clear();
      for (int d = 0; d < 7; d++) {
        _loadingByDay[d] = true;
      }
    });

    await Future.wait(List.generate(7, (d) async {
      final date = localWeekStart.add(Duration(days: d));
      final (:weekIndex, :dayIndex) =
          BB3PlannedExerciseService.dateToWeekDay(
        localBlockSettings?.startDate ?? localWeekStart,
        date,
      );

      try {
        List<BB3Exercise> planned;
        if (fromServer) {
          final dayRef = FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .collection('planned_blocks')
              .doc(blockId)
              .collection('weeks')
              .doc('week_$weekIndex')
              .collection('days')
              .doc('day_$dayIndex');
          final snap =
              await dayRef.get(const GetOptions(source: Source.server));
          final exercises = snap.exists && snap.data() != null
              ? _extractExercises(snap.data()!)
              : <Map<String, dynamic>>[];
          planned = _deserialize(exercises, weekIndex, dayIndex,
              blockSettings: localBlockSettings);
        } else {
          planned = await BB3PlannedExerciseService.getPlannedDay(
            uid: uid,
            blockId: blockId,
            weekIndex: weekIndex,
            dayIndex: dayIndex,
            date: date,
            exerciseSettings: localBlockSettings?.exerciseSettings,
          );
        }

        final completed =
            await BB3PlannedExerciseService.getCompletedExercises(uid, date);

        debugPrint('[BB3 loadDay result] epoch=$localEpoch d=$d planned=${planned.length} completed=${completed.length}');

        // If a newer load has started, discard this result silently. The newer
        // load set _loadingByDay to true at its entry and will clear the flags
        // when its own futures complete — no extra setState needed here.
        if (!mounted || localEpoch != _loadEpoch) {
          debugPrint('[BB3 loadWeek stale ignored] epoch=$localEpoch current=$_loadEpoch');
          return;
        }
        setState(() {
          _plannedByDay[d] = planned;
          _completedByDay[d] = completed;
          _loadingByDay[d] = false;
        });
      } catch (_) {
        // Same stale check in error path — the newer load owns the flags.
        if (!mounted || localEpoch != _loadEpoch) return;
        setState(() => _loadingByDay[d] = false);
      }
    }));

    // Populate cross-week exposure hint cache after week data is fully loaded.
    if (mounted) _refreshExposureHintCache(localWeekStart);
  }

  // ── Exposure hint index cache ─────────────────────────────────────────────
  //
  // Async post-load step: queries getExposureHintIndex for every DUP By Exposure
  // / DUP Signature exercise in the displayed week and stores the result in
  // _hintIndexCache. _buildDayList reads from this cache synchronously; a cache
  // miss falls back to the within-week date-aware count (getWeeklyInstanceCount).

  // Updates only _dupSigRepCache after a planned-row field save.
  // Skips getExposureHintIndex (session counts don't change on rep edits).
  Future<void> _refreshDupSigRepCacheOnly(DateTime weekStart) async {
    final blockId = _selectedBlockId;
    final blockSettings = _blockSettings;
    if (blockId == null || blockId.isEmpty || blockSettings == null) return;
    if (blockSettings.startDate == null) return;
    final uid = _uid;
    final newDupSigCache = <String, int>{};

    for (int d = 0; d < 7; d++) {
      for (final ex in _plannedByDay[d]) {
        final exSettings =
            blockSettings.exerciseSettings[ex.exerciseId] as Map<String, dynamic>?;
        final model = (exSettings?['periodizationModel'] as String?) ?? '';
        if (model != 'DUP, Signature') continue;
        final date = weekStart.add(Duration(days: d));
        final cacheKey = '${_dateFmt.format(date)}_${ex.exerciseId}';
        final rep = await BB3PlannedExerciseService.getDupSignatureRepForDate(
          exerciseId: ex.exerciseId,
          exerciseName: ex.name,
          exSettings: exSettings,
          blockStartDate: blockSettings.startDate!,
          selectedDate: date,
          uid: uid,
          blockId: blockId,
        );
        newDupSigCache[cacheKey] = rep;
      }
    }

    if (!mounted) return;
    setState(() {
      _dupSigRepCache
        ..clear()
        ..addAll(newDupSigCache);
    });
  }

  Future<void> _refreshExposureHintCache(DateTime weekStart) async {
    final blockId = _selectedBlockId;
    final blockSettings = _blockSettings;
    if (blockId == null || blockId.isEmpty || blockSettings == null) return;
    if (blockSettings.startDate == null) return;
    final uid = _uid;
    final newCache = <String, int>{};
    final newDupSigCache = <String, int>{};

    for (int d = 0; d < 7; d++) {
      for (final ex in _plannedByDay[d]) {
        final exSettings =
            blockSettings.exerciseSettings[ex.exerciseId] as Map<String, dynamic>?;
        final model = (exSettings?['periodizationModel'] as String?) ?? '';
        if (model != 'DUP, By Exposure' && model != 'DUP, Signature') continue;
        final date = weekStart.add(Duration(days: d));
        final cacheKey = '${_dateFmt.format(date)}_${ex.exerciseId}';

        final idx = await BB3PlannedExerciseService.getExposureHintIndex(
          exerciseId: ex.exerciseId,
          exerciseName: ex.name,
          blockStartDate: blockSettings.startDate!,
          selectedDate: date,
          uid: uid,
          blockId: blockId,
        );
        newCache[cacheKey] = idx;

        if (model == 'DUP, Signature') {
          final rep = await BB3PlannedExerciseService.getDupSignatureRepForDate(
            exerciseId: ex.exerciseId,
            exerciseName: ex.name,
            exSettings: exSettings,
            blockStartDate: blockSettings.startDate!,
            selectedDate: date,
            uid: uid,
            blockId: blockId,
          );
          newDupSigCache[cacheKey] = rep;
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _hintIndexCache
        ..clear()
        ..addAll(newCache);
      _dupSigRepCache
        ..clear()
        ..addAll(newDupSigCache);
    });
  }

  List<Map<String, dynamic>> _extractExercises(Map<String, dynamic> data) {
    final raw = data['exercises'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }
    return [];
  }

  List<BB3Exercise> _deserialize(
      List<Map<String, dynamic>> raw, int weekIndex, int dayIndex,
      {BB3BlockSettings? blockSettings}) {
    final effectiveSettings = blockSettings ?? _blockSettings;
    return raw
        .where((m) =>
            (m['exerciseId'] ?? m['id'] ?? m['name'] ?? '').toString().isNotEmpty)
        .map((m) {
          final exId = (m['exerciseId'] ?? m['id'] ?? '').toString().trim();
          final exSettings = effectiveSettings?.exerciseSettings != null
              ? (effectiveSettings!.exerciseSettings[exId] as Map<String, dynamic>?)
              : null;
          final defaultCount =
              (exSettings?['defaultSets'] as num?)?.toInt() ?? 3;
          return BB3Exercise.fromMap(m, fallbackSetCount: defaultCount);
        })
        .toList();
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  Future<void> _onDaySave(int dayIndex, List<BB3Exercise> exercises) async {
    final blockId = _selectedBlockId;
    if (blockId == null || blockId.isEmpty) return;
    final uid = _uid;

    final date = _weekStart.add(Duration(days: dayIndex));
    final (:weekIndex, dayIndex: wdDayIndex) =
        BB3PlannedExerciseService.dateToWeekDay(
      _blockSettings?.startDate ?? _weekStart,
      date,
    );

    setState(() => _plannedByDay[dayIndex] = exercises);

    await BB3PlannedExerciseService.savePlannedDay(
      uid: uid,
      blockId: blockId,
      weekIndex: weekIndex,
      dayIndex: wdDayIndex,
      exercises: exercises,
    );

    if (mounted) _refreshDupSigRepCacheOnly(_weekStart);
  }

  // ── Cross-day drag ────────────────────────────────────────────────────────

  void _onDrop(int sourceDayIndex, int targetDayIndex, BB3Exercise exercise) {
    if (sourceDayIndex == targetDayIndex) return;

    final sourceList = List<BB3Exercise>.from(_plannedByDay[sourceDayIndex]);
    final targetList = List<BB3Exercise>.from(_plannedByDay[targetDayIndex]);

    final targetIds = targetList.map((e) => e.exerciseId).toSet();
    if (targetIds.contains(exercise.exerciseId)) return;

    sourceList.removeWhere((e) => e.exerciseId == exercise.exerciseId);
    targetList.add(exercise.copyWith(orderIndex: targetList.length));

    setState(() {
      _plannedByDay[sourceDayIndex] = sourceList;
      _plannedByDay[targetDayIndex] = targetList;
    });

    _onDaySave(sourceDayIndex, sourceList);
    _onDaySave(targetDayIndex, targetList);
  }

  // ── Move-all to next day ──────────────────────────────────────────────────

  void _onMoveAllToNextDay(int sourceDayIndex) {
    final completedIds = _completedByDay[sourceDayIndex]
        .map((c) => (c['exerciseId'] ?? c['id'] ?? '').toString())
        .toSet();
    final toMove = _plannedByDay[sourceDayIndex]
        .where((e) => !completedIds.contains(e.exerciseId))
        .toList();
    if (toMove.isEmpty) return;

    if (sourceDayIndex < 6) {
      final targetDayIndex = sourceDayIndex + 1;
      final sourceList = _plannedByDay[sourceDayIndex]
          .where((e) => completedIds.contains(e.exerciseId))
          .toList();

      final targetExistingIds =
          _plannedByDay[targetDayIndex].map((e) => e.exerciseId).toSet();
      final targetList =
          List<BB3Exercise>.from(_plannedByDay[targetDayIndex]);

      for (final ex in toMove) {
        if (!targetExistingIds.contains(ex.exerciseId)) {
          targetList.add(ex.copyWith(orderIndex: targetList.length));
        }
      }

      final reindexed = targetList
          .asMap()
          .entries
          .map((e) => e.value.copyWith(orderIndex: e.key))
          .toList();

      setState(() {
        _plannedByDay[sourceDayIndex] = sourceList;
        _plannedByDay[targetDayIndex] = reindexed;
      });

      _onDaySave(sourceDayIndex, sourceList);
      _onDaySave(targetDayIndex, reindexed);
    } else {
      // ignore: discarded_futures
      _moveAllToNextWeekMonday(toMove, sourceDayIndex);
    }
  }

  Future<void> _moveAllToNextWeekMonday(
      List<BB3Exercise> toMove, int sourceDayIndex) async {
    final blockId = _selectedBlockId;
    if (blockId == null || blockId.isEmpty) return;
    final uid = _uid;

    final completedIds = _completedByDay[sourceDayIndex]
        .map((c) => (c['exerciseId'] ?? c['id'] ?? '').toString())
        .toSet();
    final sundayLocked = _plannedByDay[sourceDayIndex]
        .where((e) => completedIds.contains(e.exerciseId))
        .toList();

    setState(() => _plannedByDay[sourceDayIndex] = sundayLocked);
    await _onDaySave(sourceDayIndex, sundayLocked);

    final nextMonday = _weekStart.add(const Duration(days: 7));
    final (:weekIndex, :dayIndex) = BB3PlannedExerciseService.dateToWeekDay(
      _blockSettings?.startDate ?? _weekStart,
      nextMonday,
    );

    List<BB3Exercise> existing = [];
    try {
      existing = await BB3PlannedExerciseService.getPlannedDay(
        uid: uid,
        blockId: blockId,
        weekIndex: weekIndex,
        dayIndex: dayIndex,
        date: nextMonday,
        exerciseSettings: _blockSettings?.exerciseSettings,
      );
    } catch (_) {}

    final existingIds = existing.map((e) => e.exerciseId).toSet();
    final merged = List<BB3Exercise>.from(existing);
    for (final ex in toMove) {
      if (!existingIds.contains(ex.exerciseId)) {
        merged.add(ex.copyWith(orderIndex: merged.length));
      }
    }
    final reindexed = merged
        .asMap()
        .entries
        .map((e) => e.value.copyWith(orderIndex: e.key))
        .toList();

    await BB3PlannedExerciseService.savePlannedDay(
      uid: uid,
      blockId: blockId,
      weekIndex: weekIndex,
      dayIndex: dayIndex,
      exercises: reindexed,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Exercises moved to next week Monday')),
      );
    }
  }

  // ── Week navigation ───────────────────────────────────────────────────────

  // ignore: unused_element
  void _prevWeek() {
    _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  // ignore: unused_element
  void _nextWeek() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _refresh() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Refreshing ✨'),
        duration: Duration(seconds: 1),
      ),
    );
    setState(() => _refreshing = true);
    await _loadWeek(fromServer: true);
    if (mounted) setState(() => _refreshing = false);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String get _uid => UserContext.of(context, listen: false).actingAsUid;

  static DateTime _mondayOf(DateTime d) {
    final days = d.weekday - 1;
    return DateTime(d.year, d.month, d.day).subtract(Duration(days: days));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(context),
      body: _buildBody(context),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final weekEnd = _weekStart.add(const Duration(days: 6));
    final label =
        '${DateFormat('MMM d').format(_weekStart)} – ${DateFormat('MMM d').format(weekEnd)}';

    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const
          Text('Week Planner',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          Text(label,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.normal)),

        ],
      ),
      actions: [
       /* IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: 'Previous week',
          onPressed: _prevWeek,
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          tooltip: 'Next week',
          onPressed: _nextWeek,
        ),

        */
        _refreshing
            ? const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                icon: const Icon(Icons.auto_awesome,
                    color: Colors.amberAccent),
                tooltip: 'Refresh hints',
                onPressed: _refresh,
              ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _buildBlockSelector(),
          ),
        ),
      ],
    );
  }

  Widget _buildBlockSelector() {
    if (_loadingBlocks) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_allBlocks.isEmpty) {
      return const Text('No blocks', style: TextStyle(fontSize: 12));
    }
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: _selectedBlockId,
        isDense: true,
        isExpanded: true,
        style: const TextStyle(fontSize: 13, color: Colors.white),
        dropdownColor: Colors.blueGrey.shade800,
        iconEnabledColor: Colors.white,
        selectedItemBuilder: (context) {
          return _allBlocks.map((b) {
            return Align(
              alignment: Alignment.centerLeft,
              child: Text(
                b.name ?? b.blockId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: const TextStyle(fontSize: 13, color: Colors.white),
              ),
            );
          }).toList();
        },
        items: _allBlocks.map((b) {
          return DropdownMenuItem(
            value: b.blockId,
            child: Text(
              b.name ?? b.blockId,
              style: const TextStyle(fontSize: 13, color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
          );
        }).toList(),
        onChanged: (id) {
          if (id != null) _selectBlock(id);
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);

    // Do not evaluate outside-block status until block settings have loaded.
    // Without this guard, _blockSettings == null triggers the banner on every open.
    final settingsReady = !_loadingBlocks && _blockSettings != null;

    bool showBanner = false;
    if (settingsReady) {
      if (!_blockSettings!.hasDateRange) {
        showBanner = true;
      } else {
        showBanner = List.generate(7, (d) {
          final date = _weekStart.add(Duration(days: d));
          return !_blockSettings!.isDateInRange(date);
        }).any((v) => v);
      }
    }

    debugPrint('[BB3 blockBanner] loadingBlocks=$_loadingBlocks '
        'hasSettings=$settingsReady '
        'hasDateRange=${_blockSettings?.hasDateRange} '
        'show=$showBanner');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showBanner) _buildOutsideBlockBanner(theme),
        Expanded(
          child: _buildWeekPageView(),
        ),
      ],
    );
  }

  Widget _buildOutsideBlockBanner(ThemeData theme) {
    return Container(
      color: Colors.orange.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 18, color: Colors.orange.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Outside block range — showing default/fallback hints based on training history.',
              style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
            ),
          ),
        ],
      ),
    );
  }

  // ── PageView: one page per week, days stacked vertically ──────────────────

  Widget _buildWeekPageView() {
    return PageView.builder(
      controller: _pageController,
      onPageChanged: (page) {
        final newWeek = _pageToWeek(page);
        if (newWeek != _weekStart) {
          setState(() => _weekStart = newWeek);
          _loadWeek(fromServer: false);
        }
      },
      itemBuilder: (context, page) {
        // itemBuilder is called for any page including non-current pages during
        // swipe animation. We only have data for _weekStart (current page), so
        // panels for adjacent pages during the swipe will load asynchronously.
        final pageWeekStart = _pageToWeek(page);
        return _buildDayList(pageWeekStart);
      },
    );
  }

  Widget _buildDayList(DateTime weekStart) {
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 30,
      ),

      itemCount: 7,
      itemBuilder: (context, d) {
        final date = weekStart.add(Duration(days: d));
        final isCurrentWeek = _sameCalendarDate(weekStart, _weekStart);
        final isInBlock = _blockSettings?.isDateInRange(date) ?? false;
        if (d == 0) {
          debugPrint('[BB3 buildDay] d=$d isCurrentWeek=$isCurrentWeek '
              'planned=${isCurrentWeek ? _plannedByDay[d].length : -1} '
              'completed=${isCurrentWeek ? _completedByDay[d].length : -1}');
        }

        final (:weekIndex, :dayIndex) =
            BB3PlannedExerciseService.dateToWeekDay(
          _blockSettings?.startDate ?? weekStart,
          date,
        );

        // Compute per-exercise session index for this day's panel.
        //
        // todayDayIndex maps "today" onto the displayed week's day axis so that
        // getWeeklyInstanceCount can distinguish past days (need completed+valid)
        // from today/future days (allow planned). Clamped to [0,7]:
        //   0 → entire week is in the future (all days treated as future)
        //   7 → entire week is in the past (all days require completed+valid)
        //
        // DUP, By Exposure / DUP, Signature also use the async _hintIndexCache
        // (cross-week, block-wide) when available; the within-week count below
        // serves as the fallback until the cache populates.
        final sessionIndexByExId = <String, int>{};
        if (isCurrentWeek) {
          final now = DateTime.now();
          final todayNorm = DateTime(now.year, now.month, now.day);
          final wsNorm =
              DateTime(weekStart.year, weekStart.month, weekStart.day);
          final todayDayIndex =
              todayNorm.difference(wsNorm).inDays.clamp(0, 7);

          for (final ex in _plannedByDay[d]) {
            final exSettings =
                _blockSettings?.exerciseSettings[ex.exerciseId] as Map<String, dynamic>?;
            final model = (exSettings?['periodizationModel'] as String?) ?? '';
            final isExposureModel =
                model == 'DUP, By Exposure' || model == 'DUP, Signature';
            final cacheKey = '${_dateFmt.format(date)}_${ex.exerciseId}';

            if (isExposureModel && _hintIndexCache.containsKey(cacheKey)) {
              final rawCount = _hintIndexCache[cacheKey]!;
              final patternCount =
                  BB3PlannedExerciseService.getRepTargetPatternCount(exSettings);
              sessionIndexByExId[ex.exerciseId] =
                  patternCount > 0 ? rawCount % patternCount : rawCount;
            } else {
              sessionIndexByExId[ex.exerciseId] =
                  BB3PlannedExerciseService.getWeeklyInstanceCount(
                plannedByDay: _plannedByDay,
                completedByDay: _completedByDay,
                selectedDayIndex: d - 1,
                todayDayIndex: todayDayIndex,
                exerciseId: ex.exerciseId,
                exerciseName: ex.name,
              );
            }
          }
        }

        if (isCurrentWeek && _loadingByDay[d]) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
                child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        return BB3DayPanel(
          key: ValueKey('day_$d${weekStart.toIso8601String()}'),
          dayIndex: d,
          date: date,
          plannedExercises:
              isCurrentWeek ? _plannedByDay[d] : const [],
          completedExercises:
              isCurrentWeek ? _completedByDay[d] : const [],
          blockSettings: _blockSettings,
          weekIndex: weekIndex,
          sessionIndex: 0,
          sessionIndexByExerciseId:
              sessionIndexByExId.isNotEmpty ? sessionIndexByExId : null,
          uid: _uid,
          allExercises: _allExercises,
          templates: _templates,
          onSave: _onDaySave,
          onDrop: _onDrop,
          onMoveAllToNextDay: _onMoveAllToNextDay,
          isInsideBlock: isInBlock,
          blockId: _selectedBlockId,
          onBlockSettingsChanged: _reloadBlockSettings,
          allWeekPlannedByDay: _plannedByDay,
          allWeekCompletedByDay: _completedByDay,
          dupSigRepByExId: _dupSigRepCache.isNotEmpty ? _dupSigRepCache : null,
          templateCandidateIds: _templateCandidateIds,
        );
      },
    );
  }
}
