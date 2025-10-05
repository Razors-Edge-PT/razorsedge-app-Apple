library block_builder2;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'template_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'workout_entry_screen.dart';
import 'periodization_model_utils.dart';
import 'core_exercises.dart';
import 'package:uuid/uuid.dart';
import 'template_details.dart'; // if you're navigating directly to TemplateDetailsScreen
import 'templates.dart'; // ✅ this is the one that defines TemplatesScreen
import 'WorkoutSummaryScreen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'block_planner_repository.dart';
import 'block_repository.dart';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';
import 'user_context.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:convert'; // (top of file if not already)
import 'local_cache/block_plan_cache.dart';
import 'warmup_service.dart';


part 'block_data_loader.dart';



Map<String, List<String>> groupExercisesByCategory(
    List<Map<String, String>> allExercises) {
  const desiredOrder = [
    'Horizontal Press',
    'Horizontal Pull',
    'Vertical Press',
    'Vertical Pull',
    'Lateral Raise',
    'Arm Extension',
    'Arm Curl',
    'Squat Pattern',
    'Hip Hinge',
    'Leg Extension',
    'Leg Curl',
    'Hip Abduction/adduction',
    'Calf Raise',
    'Core',
  ];

  // Create raw grouping
  final Map<String, List<String>> grouped = {};
  for (final exercise in allExercises) {
    final category = exercise['category'] ?? 'Other';
    final name = exercise['name'] ?? 'Unnamed';

    grouped.putIfAbsent(category, () => []);
    grouped[category]!.add(name);
  }

  // Sort each group alphabetically
  for (final group in grouped.values) {
    group.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  // Build ordered output map
  final Map<String, List<String>> orderedGrouped = {};
  for (final category in desiredOrder) {
    if (grouped.containsKey(category)) {
      orderedGrouped[category] = grouped[category]!;
    }
  }

  // Include any extra categories not in desiredOrder
  for (final entry in grouped.entries) {
    if (!orderedGrouped.containsKey(entry.key)) {
      orderedGrouped[entry.key] = entry.value;
    }
  }

  return orderedGrouped;
}

// Near the top of your file (outside of any class or method):
const double exerciseRowHeight = 36.0;
const double circuitEndRowHeight = 70.0;

class ExerciseRow {
  final String id; // ✅ Unique per row
  String? exercise;
  TextEditingController exerciseController = TextEditingController();
  TextEditingController weightController = TextEditingController();
  TextEditingController repsController = TextEditingController();
  TextEditingController rirController = TextEditingController();
  TextEditingController velocityController = TextEditingController(); // ✅ NEW
  TextEditingController notesController = TextEditingController();    // ✅ NEW
  int circuitIndex;

  ExerciseRow({String? id, this.exercise, required this.circuitIndex})
      : id = id ?? const Uuid().v4(); // <-- generate if not provided
}

class BlockMeta {
  final String id;
  final String name;
  final DateTime startDate;
  final DateTime endDate;
  final List<String> selectedDays;

  BlockMeta({
    required this.id,
    required this.name,
    required this.startDate,
    required this.endDate,
    required this.selectedDays,
  });
}

class  Camp_BB2  extends StatefulWidget {
  final String? blockId;
  const Camp_BB2({this.blockId, Key? key}) : super(key: key);

  @override
  State<Camp_BB2> createState() => _BlockBuilder2State();
}

class _BlockBuilder2State extends State<Camp_BB2> {

  bool completedWesRowsReady = false;
  Map<String, Map<String, dynamic>>? _pendingPmuPatch;

  late final BlockPlannerRepository _repo;
  List<String> _selectedDays = [];
  String? _activeBlockId;
  bool _loading = true;
  List<BlockMeta> _allBlocks = [];
  String? _selectedBlockId;
  List<Map<String, dynamic>> _selectedExercisesWithCircuits = [];

  PageController? _weekPageController;
  int _currentWeekPage = 0;

  final int initialWeeks = 12;
  // int visibleWeekCount = 2; // Initially load 3 weeks
  int totalWeeks = 0;
  final int exercisesPerDay = 3;
  List<Template> templates = []; // Make sure Template is imported
  List<List<String?>> selectedTemplateIds = [];
  List<List<List<ExerciseRow>>> exerciseRows = [];
  final Map<String, bool> _savedFields = {}; // key = 'w0_d1_r2_weight'
  List<List<TextEditingController>> _velocityControllers = [];
  List<List<TextEditingController>> _notesControllers = [];


  List<List<List<TextEditingController>>> e1rmControllers = [];
  List<List<List<int>>> circuitStartIndices = [];
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _fieldScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();
  Map<String, dynamic> repTargetsByExercise = {};
  Map<String, dynamic> plannedExerciseDetails = {};
  Map<String, Map<String, dynamic>> _exerciseSettings = {};

  Map<String, dynamic> _repTargetsByExercise = {};
  Map<String, List<int>> scheduledRepTargets = {}; // 🆕
  Map<String, List<Map<String, dynamic>>> topSetsByExercise = {};
  Map<String, List<Map<String, dynamic>>> completedWesRows = {};
  final Set<String> _loadedDays = {};
  String _exKey(String name, int circuit) => '${name.trim()}_$circuit';

  late DateTime selectedWeekMonday;
  late DateTime blockStartDate;
  late DateTime blockEndDate;
  late DateTime _displayStart;
  late DateTime _displayEnd;

  String get userId => UserContext.of(context, listen: false).currentUid;
  late final String _cachedUid;
  String? _dataOwnerUid;
  String? _dataOwnerBlockId;

  int? _draggedRowIndex;
  List<Map<String, String>> allExercisesFromFirestore = []; // 🔥 Full list
  Map<String, String> _exerciseIdToName = {}; // 🧠 New: exerciseID ➔ exerciseName lookup
  Map<String, String> nameToIdMap = {}; // 🧠 Exercise name ➔ ID lookup
  List<String> plannedExercises = []; // 💡 Selected in BlockPlanner
  List<int> weekIndices = [];
  Map<int, List<ExerciseRow>> latestEditedWeekdayTemplates = {};
  final Map<String, Map<String, dynamic>> _cachedProgressedValues = {};

  //UI bits

  final GlobalKey cardKey = GlobalKey();
  final GlobalKey contentKey = GlobalKey();
  Map<String, bool> wesExpansionStates = {};

// UI Timing bits
  int initialWeekIndex = 0;
  int initialDayIndex = 0; // Optional but useful for fine control
  final Set<int> loadedWeekIndices = {};
  final Set<int> _loadingWeeks = {};


  DateTime _bb2StartTime = DateTime.now();

  //Debug bits:
  final Set<TextEditingController> _dbgTrackedWeights = {};

// Key = weekday index (0=Mon...6=Sun), Value = latest edited structure
  VoidCallback? _lastUndoAction;
  late Future<void> _initialLoad;
  final Map<String, FocusNode> _focusNodes = {};

  FocusNode _getFocusNode(String key) {
    return _focusNodes.putIfAbsent(key, () => FocusNode());
  }

  void bb2Debug(String label) {
    final elapsed = DateTime.now().difference(_bb2StartTime).inMilliseconds;
    print('⏱️ [$elapsed ms] $label');
  }

  // TinyTimer
  Future<T> _timeStep<T>(
      String label,
      Future<T> Function() step, {
        Stopwatch? total,
      }) async {
    final sw = Stopwatch()..start();
    try {
      return await step();
    } finally {
      sw.stop();
      final totalMs = total?.elapsedMilliseconds;
      print('⏱️ [BB2 Init] $label took ${sw.elapsedMilliseconds}ms'
          '${totalMs != null ? " (total so far: ${totalMs}ms)" : ""}');
    }
  }


  Map<int, List<ExerciseRow>> groupByCircuitIndex(List<ExerciseRow> rows) {
    final Map<int, List<ExerciseRow>> grouped = {};
    for (final row in rows) {
      grouped.putIfAbsent(row.circuitIndex, () => []).add(row);
    }
    return grouped;
  }

  double getTotalWesHeight(List<Map<String, dynamic>> savedWesExercises) {
    const baseHeightPerCard = 60.0;
    const setHeight = 28.0;
    const minHeight = 5.0;
    const maxHeight = 300.0;

    double total = 0;

    for (final ex in savedWesExercises) {
      final name = ex['name'] ?? 'Unnamed';
      final sets = List<Map<String, dynamic>>.from(ex['sets'] ?? []);
      final expanded = wesExpansionStates[name] ?? false;
      final extraSetCount = expanded ? (sets.length - 1).clamp(0, 10) : 0;

      total += baseHeightPerCard + (extraSetCount * setHeight);
    }

    return total.clamp(minHeight, maxHeight);
  }

  void _trackWeightController({
    required TextEditingController c,
    required String exerciseName,
    required int weekIndex,
    required int dayIndex,
    required int rowIndex,
  }) {
    if (_dbgTrackedWeights.contains(c)) return; // only hook once

    // Log initial value at attach time
    debugPrint('🔧 [track attach] weightController '
        '(ex="$exerciseName" w$weekIndex d$dayIndex r$rowIndex) '
        'initial="${c.text}"');

    String last = c.text;

    c.addListener(() {
      final newText = c.text;
      if (newText == last) return;
      last = newText;

      final ts = DateTime.now().toIso8601String();
      debugPrint('🕵️ weightController change '
          '(ex="$exerciseName" w$weekIndex d$dayIndex r$rowIndex @ $ts): '
          '"${(newText.length > 80 ? newText.substring(0,80)+'…' : newText)}"');

      // Print stack line-by-line to avoid truncation
      final lines = StackTrace.current.toString().split('\n');
      for (int i = 0; i < lines.length && i < 20; i++) {
        debugPrint('   ↳ $i) ${lines[i]}');
      }
    });

    _dbgTrackedWeights.add(c);
  }




  @override
  void initState() {
    super.initState();
    _cachedUid = UserContext.of(context, listen: false).currentUid;
    _repo = BlockPlannerRepository();

    final total = Stopwatch()..start();
    print("⏱️ BB2 initState started…");

    _initialLoad = Future.wait([
      _fetchActiveBlockThenMeta(),
      _loadAllBlocks(),
    ]).then((_) async {
      print('🟢 [BB2] _initialLoad.then started');

      // 2) Pick the selected block
      print("✅ Meta loaded. Block list and active block ID ready.");

      setState(() {
        _selectedBlockId = _allBlocks
            .firstWhere((b) => b.id == _activeBlockId, orElse: () => _allBlocks.first)
            .id;

        print("🧱 [BB2 Init] Loaded blockId: $_selectedBlockId (should match active: $_activeBlockId)");
      });

      final today = DateTime.now();
      _currentWeekPage = (today.difference(_displayStart).inDays ~/ 7)
          .clamp(0, totalWeeks - 1);
      print("📊 Rep targets loaded.");
      await _loadRepTargets();
      _weekPageController = PageController(initialPage: _currentWeekPage);

      await _timeStep('loadBlockDataForWeek($_currentWeekPage)',
              () => loadBlockDataForWeek(_currentWeekPage),
          total: total);
      print("📦 Week $_currentWeekPage data loaded.");
      loadedWeekIndices.add(_currentWeekPage);
      unawaited(_prefetchNeighborWeeks(_currentWeekPage));

      await _timeStep('loadPlannedExercisesFromFirestore',
              () => loadPlannedExercisesFromFirestore(),
          total: total);

      setState(() {});
      total.stop();
      print("✅ BB2 initState completed in ${total.elapsedMilliseconds}ms");
    }).catchError((e, stack) {
      print('❌ [BB2 INIT] Future.wait failed: $e');
      print(stack);
    });

    // Preserve your WES‐save flag logic
    Future.microtask(() async {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('wasSavedFromWES') == true) {
        prefs.remove('wasSavedFromWES');
        setState(() {
          print("🟣 Triggered UI update due to save from WES");
        });
      }
    });
  }

  Future<void> _fetchActiveBlockThenMeta() async {
    final total = Stopwatch()..start();
    if (kDebugMode) debugPrint('⏱️ [_fetchActiveBlockThenMeta] start');

    final uid = _cachedUid; // ✅ selected athlete, not auth uid
    print('👤 [_fetchActiveBlockThenMeta] using uid=$uid'); // optional sanity log

    // 1) Resolve active block ID: widget → repo → fallback
    String? activeId = widget.blockId;
    if (activeId == null) {
      try {
        activeId = await BlockRepository().fetchActiveBlockId(uid); // 🔧 pass uid explicitly
      } catch (e) {
        if (kDebugMode) debugPrint('   ⚠️ fetchActiveBlockId failed: $e');
      }
    }
    if (activeId == null) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('users').doc(uid) // 🔧 use the same uid here
            .collection('block_planner')
            .doc('current_block')
            .get(const GetOptions(source: Source.server));
        activeId = snap.data()?['blockId'] as String?;
      } catch (e) {
        if (kDebugMode) debugPrint('   ⚠️ fallback current_block failed: $e');
      }
    }
    if (activeId == null) {
      total.stop();
      throw StateError("No active block found");
    }
    _activeBlockId = activeId;

    _maybeResetCaches(_cachedUid, _activeBlockId!); // keep this

    // 2) Load meta (authoritative) + normalize to local dates
    DateTime _asLocalDate(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

    final tMeta = Stopwatch()..start();
    final meta = await _repo.loadBlockMeta(
      userId: uid,          // 🔧 pass the selected uid
      blockId: activeId,    // non-null here
    );
    tMeta.stop();
    if (kDebugMode) {
      debugPrint('   ↳ loadBlockMeta took ${tMeta.elapsedMilliseconds}ms '
          '(raw start=${meta.startDate.toIso8601String()}, end=${meta.endDate.toIso8601String()})');
    }

    blockStartDate = _asLocalDate(meta.startDate);
    blockEndDate   = _asLocalDate(meta.endDate);
    _selectedDays  = meta.selectedDays;

    // 3) Compute week bounds, page, and init arrays
    final tCompute = Stopwatch()..start();
    _computeWeekBounds();

    final today = DateTime.now();
    _currentWeekPage =
        (today.difference(_displayStart).inDays ~/ 7).clamp(0, totalWeeks - 1);
    _weekPageController = PageController(initialPage: _currentWeekPage);

    exerciseRows = List.generate(
      totalWeeks,
          (_) => List.generate(7, (_) => [
        ExerciseRow(circuitIndex: 0),
        ExerciseRow(circuitIndex: 0),
      ]),
    );
    selectedTemplateIds = List.generate(totalWeeks, (_) => List.filled(7, null));
    circuitStartIndices =
        List.generate(totalWeeks, (_) => List.generate(7, (_) => [0]));
    tCompute.stop();
    if (kDebugMode) {
      debugPrint('   ↳ compute/init took ${tCompute.elapsedMilliseconds}ms');
    }

    // 4) Load the rest
    final tAll = Stopwatch()..start();
    await loadAllData();
    tAll.stop();
    if (kDebugMode) {
      debugPrint('   ↳ loadAllData took ${tAll.elapsedMilliseconds}ms');
    }

    total.stop();
    if (kDebugMode) {
      debugPrint('✅ [_fetchActiveBlockThenMeta] ${total.elapsedMilliseconds}ms total '
          '(start=${blockStartDate.toIso8601String().substring(0,10)}, '
          'end=${blockEndDate.toIso8601String().substring(0,10)}, weeks=$totalWeeks)');
    }
  }

  Future<void> loadAllData() async {
    print("🧪 [BB2] Starting loadAllData()…");
    final total = Stopwatch()..start();
    final uid = _cachedUid; // avoid context lookup
    await _primeLatestBodyweightCacheBB2(_cachedUid!);

    // 0) Pre-size template id grid (cheap, unblocks UI later)
    selectedTemplateIds = List.generate(totalWeeks, (_) => List.generate(7, (_) => null));

    // 1) History fetches in parallel
    await _timeStep('topSetHistory (both)', () async {
      await Future.wait([
        PeriodizationModelUtils.fetchFullTopSetHistory(uid: uid),
        PeriodizationModelUtils.fetchLastWorkoutTopSetReps(uid: uid),
      ]);
    }, total: total);

    print('🧪 [BB2] Top set keys: ${PeriodizationModelUtils.exercisePreviousTopSetReps.keys.length}');

    // 2) Critical BB2 data in parallel (block first paint depends on these)
    await _timeStep('critical loads', () async {
      await Future.wait([
        loadExercisesFromFirestore(),          // exercise catalog
        loadPlannedExercisesFromFirestore(),   // planned list (UI needs)
        _loadRepTargets(),                     // hint logic needs this
        loadTopSetsFromWorkouts(uid: uid),     // used by hints/progression
      ]);
    }, total: total);

    // 3) Non-critical: kick off in background (cache-first reconcile)
    //    These shouldn’t block first paint.
    unawaited(() async {
      final bg = Stopwatch()..start();
      try {
        // Try cache first (fast), then reconcile server.
        await _fetchTemplates(); // if you can, make a cache-first version internally
        await PeriodizationModelUtils.loadPeriodizationModelsFromFirestore(uid: uid);
        print('🌀 [BB2] bg non-critical finished in ${bg.elapsedMilliseconds}ms');
        if (mounted) setState(() {}); // update any UI that relies on these
      } catch (e) {
        print('⚠️ [BB2] bg non-critical failed: $e');
      }
    }());

    // 4) Load any persisted field overrides after a tick (avoids jank)
    Future.delayed(const Duration(milliseconds: 60), _loadPersistedSavedFields);

    // 5) Only load visible weeks now (don’t fetch everything)
    await _timeStep('loadVisibleWeeksOnly', () => loadVisibleWeeksOnly(), total: total);

    print("✅ All data loaded for BB2.");
    print('⏱️ BB2 loadAllData(+visibleWeeks) took ${total.elapsedMilliseconds}ms');
  }

  Future<void> _loadAllBlocks() async {
    final total = Stopwatch()..start();
    if (kDebugMode) debugPrint('⏱️ [_loadAllBlocks] start');

    final userId = UserContext.of(context, listen: false).currentUid;

    // Fetch
    final tFetch = Stopwatch()..start();
    final snap = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .get(const GetOptions(source: Source.server));
    tFetch.stop();
    if (kDebugMode) {
      debugPrint('   ↳ fetch blocks took ${tFetch.elapsedMilliseconds}ms (count=${snap.docs.length})');
    }

    // Parse/map
    final tParse = Stopwatch()..start();
    final blocks = snap.docs
        .where((d) {
      final data = d.data();
      final hasAllFields = data.containsKey('name') &&
          data.containsKey('startDate') &&
          data.containsKey('endDate');
      if (kDebugMode && !hasAllFields) {
        debugPrint('   ⚠️ skipping ${d.id} (missing fields)');
      }
      return hasAllFields;
    })
        .map((d) {
      final data = d.data();
      return BlockMeta(
        id: d.id,
        name: data['name'],
        startDate: (data['startDate'] as Timestamp).toDate(),
        endDate: (data['endDate'] as Timestamp).toDate(),
        selectedDays: List<String>.from(data['selectedDays'] ?? []),
      );
    })
        .toList();
    tParse.stop();
    if (kDebugMode) {
      debugPrint('   ↳ parse/map took ${tParse.elapsedMilliseconds}ms');
    }

    // setState
    final tSet = Stopwatch()..start();
    if (mounted) {
      setState(() {
        _allBlocks = blocks;
        _selectedBlockId = blocks
            .firstWhere((b) => b.id == _activeBlockId, orElse: () => blocks.first)
            .id;
      });
    }
    tSet.stop();

    total.stop();
    if (kDebugMode) {
      debugPrint('✅ [_loadAllBlocks] ${total.elapsedMilliseconds}ms '
          '(fetch ${tFetch.elapsedMilliseconds} | parse ${tParse.elapsedMilliseconds} | setState ${tSet.elapsedMilliseconds})');
    }
  }

  Future<void> _saveActiveBlockIdCache(String uid, String blockId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('activeBlockId:$uid', blockId);
  }

  Future<String?> _loadActiveBlockIdCache(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('activeBlockId:$uid');
  }

  Future<void> _saveBlockMetaCache(String uid, String blockId, Map<String, dynamic> meta) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('blockMeta:$uid:$blockId', meta.toString()); // quick-n-dirty; use jsonEncode in your codebase
  }

  Map<String, dynamic>? _parseBlockMetaCache(String s) {
    // replace with jsonDecode if you switch to JSON
    // expected keys: startDateMillis, endDateMillis, selectedDaysCsv
    try {
      // minimal parser for meta.toString(); prefer JSON in real code
      return null; // keep simple if you prefer: skip parsing fallback
    } catch (_) { return null; }
  }



// Cache loading technique...
  String? _lastCtxKey;
  void _maybeResetCaches(String uid, String blockId) {
    final key = '$uid::$blockId';
    if (key == _lastCtxKey) return; // same athlete+block → keep caches
    _lastCtxKey = key;

    // Reset per-athlete/block caches ONLY when context changes
    _exerciseSettings.clear();
    _savedFields.clear();
    // If you have other per-athlete caches, clear them here too:
    // _hintCache?.clear();
    // _repTargetsCache?.clear();
  }

  Future<void> _loadWeekIfNeeded(int week) async {
    if (week < 0 || week >= totalWeeks) return;
    if (loadedWeekIndices.contains(week)) return;
    if (_loadingWeeks.contains(week)) return;

    _loadingWeeks.add(week);
    try {
      await loadBlockDataForWeek(week);
      loadedWeekIndices.add(week);
      if (mounted) setState(() {}); // optional if your loader already setState's
    } finally {
      _loadingWeeks.remove(week);
    }
  }

  Future<void> _prefetchNeighborWeeks(int center) async {
    final futures = <Future<void>>[];
    // previous
    futures.add(_loadWeekIfNeeded(center - 1));
    // next
    futures.add(_loadWeekIfNeeded(center + 1));
    await Future.wait(futures);
  }

  Future<void> loadVisibleWeeksOnly() async {
    final stopwatch = Stopwatch()..start();
    final today = DateTime.now();
    final currentWeekIndex = today.difference(blockStartDate).inDays ~/ 7;


    // CHANGE here to load more weeks on open
    final weeksToLoad = {
      currentWeekIndex,
    };
    print('⏳ [BB2] Loading visible weeks: $weeksToLoad');
    print('🧭 [BB2] currentWeekIndex=$currentWeekIndex alreadyLoaded=$loadedWeekIndices uid=${_cachedUid} blockId=${_selectedBlockId}');


    for (final weekIndex in weeksToLoad) {
      if (!loadedWeekIndices.contains(weekIndex)) {
        print('📦 [BB2] Requesting load for week_$weekIndex...');
        await loadBlockDataForWeek(weekIndex);
        loadedWeekIndices.add(weekIndex);
      }
    }
    stopwatch.stop();
    print('✅ [BB2] loadVisibleWeeksOnly completed in ${stopwatch.elapsedMilliseconds}ms');
  }

  // ...Cache loading technique

  void _computeWeekBounds() {
    // 1) get Monday on-or-before blockStart
    final startOffset = (blockStartDate.weekday - DateTime.monday + 7) % 7;
    _displayStart = blockStartDate.subtract(Duration(days: startOffset));

    // 2) get Sunday on-or-after blockEnd
    final endOffset = (DateTime.sunday - blockEndDate.weekday + 7) % 7;
    _displayEnd = blockEndDate.add(Duration(days: endOffset));

    // 3) how many days total (inclusive)
    final totalDays = _displayEnd.difference(_displayStart).inDays + 1;

    // ← MISSING ←
    // 4) how many full weeks?
    totalWeeks = totalDays ~/ 7;
    // 5) build your index list
    weekIndices = List.generate(totalWeeks, (i) => i);
  }

// 1) New helper for days outside the block:
  Widget _buildOutsideDayRow(DateTime date) {
    final label = DateFormat('E • d MMM').format(date);
    return Container(
      height: exerciseRowHeight,
      margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.grey.shade900, // dark grey fill
        border: Border.all(color: Colors.grey), // pale grey outline
        borderRadius: BorderRadius.circular(6),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ),
    );
  }


  Future<void> _fetchTemplates() async {
    final userId = UserContext.of(context, listen: false).currentUid;
    {
      final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
      final snapshot = await userDoc.collection('templates').get();

      templates = snapshot.docs.map((doc) {
        final rawExercises = doc.get('exercises');

        // 🧠 Detect whether it's the new format or the old one
        final List<Map<String, dynamic>> parsedExercises = rawExercises is List && rawExercises.isNotEmpty
            ? (rawExercises.first is Map
            ? List<Map<String, dynamic>>.from(rawExercises)
            : List<Map<String, dynamic>>.from(
            rawExercises.map((e) => {'name': e, 'circuitIndex': 0})))
            : <Map<String, dynamic>>[];

        return Template(
          id: doc.id,
          name: doc.get('name') ?? 'Unnamed',
          day: doc.data().containsKey('day') ? doc.get('day') : null,
          exercises: parsedExercises,
        );
      }).toList();

      setState(() {});
      print("✅ Templates loaded: ${templates.map((t) => t.name).toList()}");
    }
  }


  Map<String, List<String>> groupedExercises = {};

  Future<void> loadExercisesFromFirestore() async {
    final snapshot =
        await FirebaseFirestore.instance.collection('exercises').get();

    allExercisesFromFirestore.clear();
    _exerciseIdToName.clear();
    PeriodizationModelUtils.nameToId.clear(); // ✅ Clear global map

    for (final doc in snapshot.docs) {
      final id = doc.id;
      final name = doc['name'].toString();
      final category = doc['category'] as String;
      final bodyPart = doc['bodyPart'] as String;

      allExercisesFromFirestore.add({
        'id': id,
        'name': name,
        'category': category,
        'bodyPart': bodyPart,
      });

      _exerciseIdToName[id] = name;
      nameToIdMap[name] = id;
      PeriodizationModelUtils.nameToId[name.trim()] = id;
      PeriodizationModelUtils.idToName[id] = name; // ✅ Add this line
    }

    setState(() {
      groupedExercises = groupExercisesByCategory(allExercisesFromFirestore);
    });

  }

  //..body weight exercises bit...

  Future<void> _primeLatestBodyweightCacheBB2(String uid) async {
    try {
      final weightsCol = FirebaseFirestore.instance
          .collection('users').doc(uid).collection('weights');

      // Latest (for fast fallback)
      final latestSnap = await weightsCol
          .orderBy('timestamp', descending: true)
          .limit(1)
          .get();

      if (latestSnap.docs.isNotEmpty) {
        final d = latestSnap.docs.first.data();
        final bw = (d['weight'] as num?)?.toDouble();
        final ts = (d['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now();
        if (bw != null && bw > 0) {
          PeriodizationModelUtils.setLatestBodyweight(
            uid: uid,
            weightKg: bw,
            asOf: ts,
          );
        }
      }

      // History (so bodyweightKgForDate(asOf) works on first open)
      final histSnap = await weightsCol
          .orderBy('timestamp', descending: true)
          .limit(180) // ~6 months; adjust as you like
          .get();

      final entries = histSnap.docs.map((doc) {
        final data = doc.data();
        final w = (data['weight'] as num?)?.toDouble();
        final t = (data['timestamp'] as Timestamp?)?.toDate();
        if (w == null || t == null) return null;
        return {
          'date': t,
          'weight': w,
          'unit': 'kg',
        };
      }).where((e) => e != null).cast<Map<String, dynamic>>().toList();

      if (entries.isNotEmpty) {
        PeriodizationModelUtils.setBodyweightHistory(uid: uid, entries: entries);
      }
    } catch (e) {
      debugPrint('⚠️ _primeLatestBodyweightCacheBB2 failed → using default 80kg: $e');
    }
  }


  // Periodization logic...

  Map<String, dynamic>? getPlannedRirSetValues({
    required String exerciseName,
    required int week,
    required int day,
    required int row,
  }) {
    final exerciseId = nameToIdMap[exerciseName];
    if (exerciseId == null) return null;
    print('🔍 [getPlannedRirSetValues] $exerciseName → $exerciseId');

    if (exerciseId == null) {
      print('❌ nameToIdMap missing for $exerciseName');
      return null;
    }

    final rirPlan = plannedExerciseDetails[exerciseId]?['rirPlan'];
    if (rirPlan == null) return null;

    final sessionIndex = getExerciseCountInWeek(exerciseName, week, day, row);
    final weekKey = 'week${week + 1}';

    final weekData = rirPlan[weekKey] as Map<String, dynamic>? ?? {};
    final maxSessions = weekData.keys.length;

    final clampedSessionIndex = (maxSessions != null && maxSessions > 0)
        ? sessionIndex.clamp(0, maxSessions - 1)
        : 0;
    print('📌 RIR Plan — sessionIndex: $sessionIndex, maxSessions: $maxSessions, clamped: $clampedSessionIndex');

    final sessionKey = 'session${clampedSessionIndex + 1}';

    print('🧪 Checking $weekKey → $sessionKey (original index $sessionIndex)');

    final Map<String, dynamic>? sessionData =
    (rirPlan[weekKey]?[sessionKey] as Map?)?.cast<String, dynamic>();


    if (sessionData == null) {
      print('❌ No sessionData found at $weekKey → $sessionKey');
      return null;
    }

    return sessionData.map((setKey, setValue) => MapEntry(setKey, {
      'reps': setValue['reps'],
      'rir': (setValue['rir'] ?? 1.0),  // ✅ default to 1.0 if missing
    }));

  }

  String? getRepTargetForExercise(
      String exerciseName, int week, int day, int row) {
    final exerciseId = nameToIdMap[exerciseName];

    if (exerciseId == null) return null;

    final details = plannedExerciseDetails[exerciseId];
    if (details == null) return null;

    final repTargets = _exerciseSettings[exerciseId]?['repTargets'];
    print('📌 Rep targets for $exerciseId → $repTargets');

    if (repTargets == null) return null;
    print('🧪 [DEBUG] From _exerciseSettings → ${_exerciseSettings[exerciseId]?['periodizationModel']}');
    print('🧪 [DEBUG] From plannedExerciseDetails → ${plannedExerciseDetails[exerciseId]?['periodizationModel']}');

    final modelString = _exerciseSettings[exerciseId]?['periodizationModel']
        ?? plannedExerciseDetails[exerciseId]?['periodizationModel'];

    final normalizedModel = (modelString ?? '').trim().toLowerCase();

    final model = {
      'dup, by exposure': PeriodizationModelType.dailyUndulatingExposure,
      'dup, by week': PeriodizationModelType.dailyUndulatingWeek,
      'linear by exposure': PeriodizationModelType.linearExposure,
      'linear, classic': PeriodizationModelType.linearClassic, // ✅ Add this line
      'dup, signature': PeriodizationModelType.dupSignature,
    }[normalizedModel];

    print('🧠 [BB2] exerciseSettings model for $exerciseId → ${_exerciseSettings[exerciseId]?['periodizationModel']}');
    print('🧪 [DEBUG] From plannedExerciseDetails → ${plannedExerciseDetails[exerciseId]?['periodizationModel']}');
    print('🔍 ENTERING getRepTargetForExercise → model = $model for $exerciseId');



    print('🔍 [BB2] Model from exerciseSettings for $exerciseId → $model');

    try {
      print('🔍 ENTERING getRepTargetForExercise → model = $model for $exerciseId');

      print('🔎 [BB2] About to enter switch → model = $model for $exerciseId');
      print('🧠 [BB2] exerciseSettings model for $exerciseId → ${_exerciseSettings[exerciseId]?['periodizationModel']}');

      switch (model) {
        case PeriodizationModelType.linearExposure:
          final exposureIndex = getExercisePlannedCountBefore(exerciseName, week, day, row);
          final reps = PeriodizationModelUtils.getLinearExposureRepTarget(
            exerciseId: exerciseId,
            exposureIndex: exposureIndex,
            repTargetsByExercise: {exerciseId: repTargets},
            plannedExerciseDetails: plannedExerciseDetails,
          );

          return reps.toString();

        case PeriodizationModelType.linearClassic: {
          // Unified occurrences BEFORE this row in the same week (completed wins per day)
          final int plannedIndex = getExerciseCountInWeek(exerciseName, week, day, row);
          // ^ getExerciseCountInWeek already counts completed days via completedWesRows,
          //   so don't add completedThisWeek again.

          final rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exerciseId,
            plannedIndex: plannedIndex,          // ✅ week-scoped exposure index (0-based)
            weekIndex: week,
            repTargetsByExercise: { exerciseId: repTargets }, // ok: PMU now accepts inner map
            plannedExerciseDetails: plannedExerciseDetails,
            blockStartDate: blockStartDate,
            blockEndDate: blockEndDate,
          );

          print('📈 LinearClassic rep → $rep for $exerciseId '
              '(week $week, unifiedIndex=$plannedIndex)');
          return rep.toString();
        }



        case PeriodizationModelType.dailyUndulatingWeek: {
          // ✅ Unified index within THIS WEEK (counts planned-before + completed)
          final int plannedIndex = getExerciseCountInWeek(exerciseName, week, day, row);

          // ✅ Pass the full settings node at exerciseId so PMU can read ['repTargets']
          final rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exerciseId,
            plannedIndex: plannedIndex,
            weekIndex: week,
            repTargetsByExercise: { exerciseId: _exerciseSettings[exerciseId] },
            plannedExerciseDetails: plannedExerciseDetails,
          );

          print('🔁 DUP by Week rep: $rep for $exerciseId '
              '(week $week, unifiedIndex=$plannedIndex)');
          return rep.toString();
        }

        case PeriodizationModelType.dupSignature: {
          // 🔢 Completed exposures across the whole block
          int completedCount = 0;
          if (blockStartDate != null && blockEndDate != null) {
            completedCount = PeriodizationModelUtils.getInstanceCountForExerciseInBlock(
              exerciseName: exerciseName,
              savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
              blockStartDate: blockStartDate!,
              blockEndDate: blockEndDate!,
            );
          } else {
            print('⚠️ [BB2] blockStartDate or blockEndDate is null — treating completedCount=0');
          }

          // 🗓️ Planned occurrences before this position in the planner
          final int plannedBefore = getExercisePlannedCountBefore(exerciseName, week, day, row);

          // 🌍 Global exposure index within the block = completed + plannedBefore
          final int plannedIndex = completedCount + plannedBefore;

          // ⚙️ Keep dupSignature’s existing wiring (uses _exerciseSettings map)
          final rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exerciseId,
            plannedIndex: plannedIndex,                 // ✅ combined global index
            repTargetsByExercise: _exerciseSettings,    // ← unchanged, dupSignature-specific
            weekIndex: week,
          );

          print('🎛️ DUP Signature rep: $rep for $exerciseId '
              '(completedInBlock=$completedCount, plannedBefore=$plannedBefore, index=$plannedIndex)');

          return rep.toString();
        }


        case PeriodizationModelType.dailyUndulatingExposure: {
          print('🔍 Entering getRepTargetForExercise → model = $model for $exerciseId');
          print('🧭 [BB2 DUP Exposure] context: week=$week day=$day row=$row '
              'blockStart=${blockStartDate?.toIso8601String()}');

          int completedCount = 0;
          final countedDebug = <Map<String, String>>[];

          try {
            if (blockStartDate != null) {
              final targetId   = exerciseId;
              final targetName = exerciseName.trim();
              final daysIntoBlock = week * 7 + day; // inclusive
              final base = DateTime(blockStartDate!.year, blockStartDate!.month, blockStartDate!.day);

              // show which days BB2 cache even has rows for
              final cacheKeys = (completedWesRows.keys.toList()..sort()).join(', ');
              print('🗂️ [BB2 DUP Exposure] completedWesRows has keys: [$cacheKeys]');

              // walk every day from start → today
              for (int off = 0; off <= daysIntoBlock; off++) {
                final date = base.add(Duration(days: off));
                final dateKey = DateFormat('yyyy-MM-dd').format(date);
                final raw = List<Map<String, dynamic>>.from(completedWesRows[dateKey] ?? const []);
                print('  • [BB2 cache] $dateKey → ${raw.length} entries');

                // If BB2 cache for this day is empty (race w/ paint), peek at savedWorkoutsList (read-only)
                List<Map<String, dynamic>> rawFallback = const [];
                if (raw.isEmpty) {
                  rawFallback = PeriodizationModelUtils.savedWorkoutsList
                      .where((w) {
                    final ds = (w['date'] ?? '').toString();
                    return ds.startsWith(dateKey);
                  })
                      .expand((w) {
                    final exs = w['exercises'];
                    if (exs is List) {
                      return exs.cast<Map<String, dynamic>>();
                    }
                    return const <Map<String, dynamic>>[];
                  })
                      .toList();

                  if (rawFallback.isNotEmpty) {
                    print('    ↪︎ [fallback] using ${rawFallback.length} exercises from savedWorkoutsList for $dateKey');
                  }

                }

                bool hasCompleted = false;
                String? wTxt, rTxt, rirTxt;

                // prefer cache; else use fallback snapshot
                final source = raw.isNotEmpty ? raw : rawFallback;

                for (final ex in source) {
                  // ID-first match; fall back to name if id missing
                  final exId   = (ex['exerciseId'] ?? ex['id'] ?? ex['exercise_id'] ?? '').toString().trim();
                  final exName = (ex['name'] ?? ex['exercise'] ?? ex['title'] ?? '').toString().trim();

                  final idMatches   = exId.isNotEmpty && exId == targetId;
                  final nameMatches = exId.isEmpty && exName == targetName;
                  if (!(idMatches || nameMatches)) continue;

                  final sets = List<Map<String, dynamic>>.from(ex['sets'] ?? const []);
                  if (sets.isEmpty) continue;

                  hasCompleted = true;

                  for (final s in sets) {
                    final w = (s['actualWeight'] ?? s['weight'] ?? '').toString().trim();
                    final r = (s['actualReps']   ?? s['reps']   ?? '').toString().trim();
                    final rr= (s['actualRir']    ?? s['rir']    ?? '').toString().trim();
                    if (wTxt == null && rTxt == null) {
                      wTxt  = double.tryParse(w) != null ? w : (w.isEmpty ? '—' : w);
                      rTxt  = int.tryParse(r)    != null ? r : (r.isEmpty ? '—' : r);
                      rirTxt= rr.isEmpty ? '—' : rr;
                    }
                    break;
                  }
                }

                if (hasCompleted) {
                  completedCount += 1;
                  countedDebug.add({'date': dateKey, 'weight': wTxt ?? '—', 'reps': rTxt ?? '—', 'rir': rirTxt ?? '—'});
                }
              }

            } else {
              print('⚠️ [BB2] blockStartDate is null — treating completedCount=0');
            }
          } catch (e) {
            print('⚠️ [BB2] completedCount calc failed: $e');
          }

          // planned rows before on this day
          final int plannedCountBefore = getExercisePlannedCountBefore(exerciseName, week, day, row);
          final int plannedIndex = completedCount + plannedCountBefore;

          // instances count (from week1)
          final repTargetsRaw = _exerciseSettings[exerciseId]?['repTargets'];
          final week1 = repTargetsRaw?['week1'] as Map<String, dynamic>?;
          final int numInstances = week1 == null
              ? 0
              : week1.keys.where((k) => k.startsWith('instance')).length;

          for (int i = 0; i < countedDebug.length; i++) {
            final e = countedDebug[i];
            final cyclePos = numInstances == 0 ? 'n/a' : ((i % numInstances) + 1).toString();
            final cycleDen = numInstances == 0 ? 'n/a' : numInstances.toString();
            print('🧾 [BB2 DUP Exposure] prior #${i + 1} → ${e['date']} • ${e['weight']} kg × ${e['reps']} '
                '${(e['rir'] ?? '—') != '—' ? '(RIR ${e['rir']}) ' : ''}→ cycle $cyclePos/$cycleDen');
          }

          final instanceLabel = numInstances == 0 ? 'n/a'
              : '${(plannedIndex % (numInstances == 0 ? 1 : numInstances)) + 1}/$numInstances';

          print('🧮 [BB2 DUP Exposure] completedSoFar=$completedCount '
              'plannedBefore=$plannedCountBefore → plannedIndex=$plannedIndex '
              '→ instance=$instanceLabel');

          final rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exerciseId,
            plannedIndex: plannedIndex,
            weekIndex: week,
            repTargetsByExercise: {exerciseId: repTargets},
            plannedExerciseDetails: plannedExerciseDetails,
          );

          print('🔁 [BB2] DUP by Exposure rep: $rep for $exerciseId '
              '(completed=$completedCount, plannedBefore=$plannedCountBefore, index=$plannedIndex)');

          return rep.toString();
        }





        default:
          return null;
      }
    } catch (e) {}
    return null;
  }


  int getExerciseCountInWeek(String exerciseName, int week, int day, int row) {
    final _keys = (completedWesRows?.keys ?? const <String>[]).toList()..sort();
    print('🗂️ [BB2 Count Enter] ex="$exerciseName" week=$week day=$day row=$row keys=$_keys');

    int count = 0;
    final target = exerciseName.trim();
    if (target.isEmpty) return 0;

    for (int d = 0; d <= day; d++) {
      // 1) Check completed (WES) for this day first — cache-first, then fallback to savedWorkoutsList
      final date = blockStartDate.add(Duration(days: week * 7 + d));
      final dateKey = DateFormat('yyyy-MM-dd').format(date);

      final cacheSaved = List<Map<String, dynamic>>.from(
        completedWesRows[dateKey] ?? const <Map<String, dynamic>>[],
      );

      // Fallback to savedWorkoutsList if cache is empty for this day
      List<Map<String, dynamic>> fallbackSaved = const <Map<String, dynamic>>[];
      if (cacheSaved.isEmpty) {
        fallbackSaved = PeriodizationModelUtils.savedWorkoutsList
            .where((w) => (w['date'] ?? '').toString().startsWith(dateKey))
            .expand((w) {
          final exs = w['exercises'];
          return (exs is List)
              ? exs.cast<Map<String, dynamic>>()
              : const <Map<String, dynamic>>[];
        })
            .toList();
      }

      final source = cacheSaved.isNotEmpty ? cacheSaved : fallbackSaved;
      final sourceTag = cacheSaved.isNotEmpty ? 'cache' : 'fallback';

      print('📅 [BB2 Count] d=$d date=$dateKey saved=${source.length} '
          'planned=${exerciseRows[week][d].length} src=$sourceTag');

      bool countedCompletedForDay = false;

      // ID-first matching, then name (only if id missing)
      final targetId = nameToIdMap[exerciseName] ?? target;
      for (final ex in source) {
        final exId   = (ex['exerciseId'] ?? ex['id'] ?? ex['exercise_id'] ?? '').toString().trim();
        final exName = (ex['name'] ?? ex['exercise'] ?? ex['title'] ?? '').toString().trim();
        final idMatches   = exId.isNotEmpty && exId == targetId;
        final nameMatches = exId.isEmpty     && exName == target;
        if (!(idMatches || nameMatches)) continue;

        final sets = (ex['sets'] is List)
            ? List<Map<String, dynamic>>.from(ex['sets'])
            : const <Map<String, dynamic>>[];
        if (sets.isEmpty) continue;

        count += 1;
        countedCompletedForDay = true;
        print('✅ [BB2 Count] matched COMPLETED "${exName.isNotEmpty ? exName : target}" '
            'on $dateKey → +1 (sets=${sets.length}) src=$sourceTag');
        break; // keep "one per day" behavior
      }

      if (countedCompletedForDay) {
        // Completed exists → do not also count planned for this day
        continue;
      }


      // 2) No completed entry → fall back to planned rows (your existing logic)
      final rows = exerciseRows[week][d];
      final lastRow = (d == day) ? row + 1 : rows.length; // include current row on current day

      for (int r = 0; r < lastRow; r++) {
        final thisName = (rows[r].exercise ?? '').toString().trim();
        if (thisName == target) {
          count++;
          print('📝 [BB2 Count] matched PLANNED "$thisName" on d=$d r=$r (lastRow=$lastRow) → +1');
        }
      }
    }

    final result = count - 1; // zero-based index (unchanged)
    print('🧠 getExerciseCountInWeek("$exerciseName", week: $week, day: $day, row: $row) = $result');
    return result;
  }




  int getPlannedIndexForWeek(String exerciseId, int week, int day, int row) {
    int count = 0;

    for (int w = 0; w <= week; w++) {
      final lastDay = (w == week) ? day : 6;
      for (int d = 0; d <= lastDay; d++) {
        final lastRow = (w == week && d == day) ? row + 1 : exerciseRows[w][d].length;

        for (int r = 0; r < lastRow; r++) {
          final thisId = (exerciseRows[w][d][r].exercise ?? '').trim();

          if (thisId == exerciseId) {
            count++;
          }
        }
      }
    }

    return count - 1; // zero-based
  }




  Future<void> _loadRepTargets() async {
    final userId = UserContext.of(context, listen: false).currentUid;
    if (userId.isEmpty) return; // Fallback in case something goes wrong


    final blockId = _selectedBlockId!;

    final doc = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(blockId)
        .get();

    if (!doc.exists) return;

    final data = doc.data();
    if (data == null) return;

    setState(() {
      if (data.containsKey('plannedExerciseDetails')) {
        plannedExerciseDetails = Map<String, dynamic>.from(data['plannedExerciseDetails']);
        PeriodizationModelUtils.setExerciseSettings(plannedExerciseDetails);

        // ✅ Inject blockMeta if it exists
        if (data.containsKey('blockMeta')) {
          plannedExerciseDetails['blockMeta'] =
              Map<String, dynamic>.from(data['blockMeta']);
        }

        print('✅ PlannedExerciseDetails loaded: ${plannedExerciseDetails.length} items');

        // ✅ Preload repTargets into _repTargetsByExercise
        plannedExerciseDetails.forEach((exerciseId, details) {
          if (exerciseId == 'blockMeta') return; // skip meta
          if (details is Map<String, dynamic> && details.containsKey('repTargets')) {
            _repTargetsByExercise[exerciseId] = {
              'repTargets': details['repTargets']
            };

          }
          PeriodizationModelUtils.plannedExerciseDetails[exerciseId] = details;
        });
      } else {}
    });

    print("✅ Rep targets map size: ${_repTargetsByExercise.length}");

    plannedExerciseDetails.forEach((exerciseId, details) {
      if (exerciseId == 'blockMeta') return;

      final modelName = details['periodizationModel'];
      if (modelName != null) {
        final modelEnum = PeriodizationModelUtils.stringToModel(modelName);
        PeriodizationModelUtils.exercisePeriodizationModels[exerciseId] =
            modelEnum;
      }

      final repTargetEntry = _repTargetsByExercise[exerciseId];
      if (repTargetEntry is Map &&
          repTargetEntry.containsKey('repTargets') &&
          modelName == 'DUP, By Exposure') {
        final map = repTargetEntry['repTargets'];
        if (map is Map<String, dynamic> && map.keys.length == 1 && map.containsKey('week1')) {
          final expanded = PeriodizationModelUtils.expandDupDailyWeek1(
            Map<String, String>.from(map['week1']),
            12,
          );
          _repTargetsByExercise[exerciseId]['repTargets'] = expanded;
          print('🔁 Expanded DUP Daily week1 for $exerciseId');
        }
      }

      final updatedEntry = _repTargetsByExercise[exerciseId];
      if (updatedEntry is Map && updatedEntry.containsKey('repTargets')) {
      } else {}

    });

    print("✅ [BB2] exercisePeriodizationModels mapped: ${PeriodizationModelUtils.exercisePeriodizationModels.length}");
    print('📄 Full plannedExerciseDetails: ${jsonEncode(plannedExerciseDetails)}');
  }

  Map<String, dynamic> _getCachedProgressedValues({
    required String exerciseName,
    required String? exerciseId,
    required int weekIndex,
    required int dayIndex,
    required int rowIndex,
    required int repTarget,
    required double defaultWeight,
    required double rir,
  }) {

    final String cacheKey = '$exerciseId-$weekIndex-$dayIndex-$rowIndex';

    if (_cachedProgressedValues.containsKey(cacheKey)) {
      return _cachedProgressedValues[cacheKey]!;
    }
    final double baseWeight = defaultWeight;
    final int baseReps = repTarget;
    final double baseRir = rir;
    final progressionModelName = plannedExerciseDetails[exerciseId]?['progressionModel'];
    final progressionModel = PeriodizationModelUtils.parseProgressionModel(progressionModelName);

    final double? e1rm = PeriodizationModelUtils.calculateE1RM(
      baseWeight,
      baseReps.toDouble(),
      baseRir,
    );

    print('🔬 [BB2] Progression model input for $exerciseName');
    print('     → repTarget: $repTarget');
    print('     → baseWeight: $defaultWeight');
    print('     → RIR: $rir');


    print('📦 [BB2] Using baseWeight = $baseWeight, baseReps = $baseReps, baseRIR = $baseRir');
    print('📦 [BB2] Final E1RM = ${e1rm?.toStringAsFixed(2)}');

    final String exerciseKey = exerciseName.trim();
    final List<Map<String, dynamic>> topSetHistory =
        PeriodizationModelUtils.topSetsByExercise[exerciseKey] ?? [];

    print('🧪 [BB2] topSetsByExercise key="$exerciseKey" histLen=${topSetHistory.length}');
    if (topSetHistory.isNotEmpty) {
      final s = topSetHistory.first;
      print('🧪 [BB2] sampleTopSet → w=${s['weight']} r=${s['reps']} rir=${s['rir']} date=${s['date']}');
    }

    print('🧾 [BB2→PMU] exId=$exerciseId exName=$exerciseName '
        'repTarget=$baseReps rir=$baseRir '
        'defaultWeight=${baseWeight.toStringAsFixed(2)}');

// 🔩 ES-only increments (no PD), sanitize any stray secondary
    final incRawES = _exerciseSettings[exerciseId]?['increments']
        ?? _exerciseSettings[exerciseName]?['increments'];
    final incMapES = PeriodizationModelUtils.incMapFromRaw(incRawES);

// If ES has no secondary, remove it
    final esHasSecondary = (incRawES is Map) && (incRawES['secondary'] is num) && ((incRawES['secondary'] as num) > 0);
    if (!esHasSecondary) incMapES.remove('secondary');
    // [ADD PRINT] —— ES origin tag (again)
    final String esOrigin = _exerciseSettings[exerciseId]?['increments'] != null
        ? 'byId' : (_exerciseSettings[exerciseName]?['increments'] != null ? 'byName' : 'fallback');
    print('🧷 [BB2→PMU set] increments patched → origin=$esOrigin map=$incMapES');


// 🔁 Push a tiny patch into PMU so internal lookups match ES
    final Map<String, Map<String, dynamic>> pmuPatch = {};
    if ((exerciseId ?? '').isNotEmpty) {
      pmuPatch[exerciseId!] = {'increments': Map<String, dynamic>.from(incMapES)};
    }
    pmuPatch[exerciseName] = {'increments': Map<String, dynamic>.from(incMapES)};
    PeriodizationModelUtils.setExerciseSettings(pmuPatch);
    print('🧷 [BB2→PMU set] increments patched for ${pmuPatch.keys.toList()} → ${incMapES}');

// Build options from sanitized ES and pass them in
    final esOptions = PeriodizationModelUtils.expandIncrementOptions(incMapES);
    print('🧾 [BB2→PMU] ES increments primary=${incMapES['primary']} '
        'secondary=${incMapES['secondary'] ?? 0} '
        'sample=${esOptions.take(10).toList()} … total=${esOptions.length} '
        'maxWeightByRepsKeys=${plannedExerciseDetails[exerciseId]?['maxWeightByReps'] is Map
        ? (plannedExerciseDetails[exerciseId]['maxWeightByReps'] as Map).keys.toList()
        : 'null'}');

    final progressed = PeriodizationModelUtils.getWeightByProgressionModel(
      model: progressionModel,
      exerciseName: exerciseName,
      repTarget: baseReps,
      defaultWeight: baseWeight,
      rirValue: baseRir,
      increments: esOptions, // ← only ES-based candidates
      maxWeightByReps: plannedExerciseDetails[exerciseId]?['maxWeightByReps'],
      topSetHistory: topSetHistory,
      weekIndex: weekIndex,
    );
    final double? pW = (progressed['weight'] as num?)?.toDouble();
    final int?   pR = (progressed['reps'] as num? )?.toInt();


    // 🔎 Parity debug: which E1RM are we preserving?
    final double _e1rm_default = PeriodizationModelUtils.calculateE1RM(
      baseWeight,
      baseReps.toDouble(),
      baseRir,
    );
    final double _e1rm_progressed = PeriodizationModelUtils.calculateE1RM(
      (progressed['weight'] as num?)?.toDouble() ?? 0.0,
      (progressed['reps'] as num?)?.toDouble() ?? 0.0,
      baseRir,
    );
    print('🧮 [PROG OUT] weight=$pW reps=$pR '
        'base(repTarget=$baseReps, rir=$baseRir) '
        'e1rm_default=${_e1rm_default.toStringAsFixed(2)} '
        'e1rm_progressed=${_e1rm_progressed.toStringAsFixed(2)}');

    if (pR != null && pR != baseReps && baseRir != 0) {
      print('⚠️ [RIR-only drift check] Progression changed reps '
          '(baseReps=$baseReps → progressedReps=$pR) at same RIR=$baseRir');
    }
    print('🎯 [BB2 parity] e1rm_default   = ${_e1rm_default.toStringAsFixed(2)} '
        'from ${baseWeight.toStringAsFixed(2)} × ${baseReps} @ RIR ${baseRir}');
    print('🎯 [BB2 parity] e1rm_progressed= ${_e1rm_progressed.toStringAsFixed(2)} '
        'from ${(progressed['weight'] as num?)?.toDouble() ?? 0.0} × '
        '${(progressed['reps'] as num?)?.toDouble() ?? 0.0} @ RIR ${baseRir}');
    print('🧰 [BB2 parity] ES increments primary=${incMapES['primary']} '
        'secondary=${incMapES['secondary'] ?? 0} '
        'sample=${esOptions.take(10).toList()} … total=${esOptions.length}');
//parity debug ends


    final double? weight = progressed['weight'];
    final int? reps = progressed['reps'];

    print('📦 [BB2] Caching progression E1RM for $exerciseName → $e1rm');
    progressed['e1rm'] = e1rm;
    _cachedProgressedValues[cacheKey] = progressed;


    return progressed;
  }

  // ...Periodization logic





  List<int> _recomputeCircuitStartsFromPlanned(List<Map<String, dynamic>> planned) {
    final starts = <int>[];
    int? last;
    for (int i = 0; i < planned.length; i++) {
      final c = (planned[i]['circuitIndex'] ?? 0) as int;
      if (i == 0 || c != last) {
        starts.add(i);
        last = c;
      }
    }
    if (starts.isEmpty || starts.first != 0) starts.insert(0, 0);
    return starts;
  }

  Set<String> _completedKeysFromSaved(List<Map<String, dynamic>> savedExercises) {
    final keys = <String>{};
    for (final ex in savedExercises) {
      final name = (ex['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final circuit = ex['circuitIndex'] ?? 0;
      final sets = List<Map<String, dynamic>>.from(ex['sets'] ?? const []);
      if (sets.isEmpty) continue; // only treat as "completed" if at least 1 set
      keys.add(_exKey(name, circuit));
    }
    return keys;
  }

  /// Move conflicting planned rows into `suppressedPlanned` so they don’t count,
  /// but can be restored later if completion disappears.
  Future<bool> _suppressPlannedForCompletedKeys({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
    required Set<String> completedKeys,
  }) async {
    if (completedKeys.isEmpty) return false;

    final dayDoc = FirebaseFirestore.instance
        .collection('planned_blocks').doc(uid)
        .collection('blocks').doc(blockId)
        .collection('weeks').doc('week_$weekIndex')
        .collection('days').doc('day_$dayIndex');

    final snap = await dayDoc.get(const GetOptions(source: Source.server));
    if (!snap.exists) return false;

    final data = snap.data() ?? {};
    final planned = List<Map<String, dynamic>>.from(data['exercises'] ?? const []);
    final suppressedRaw = (data['suppressedPlanned'] ?? {}) as Map<String, dynamic>;
    final suppressed = Map<String, dynamic>.from(suppressedRaw);

    // Collect removals with original indices
    final removals = <int, Map<String, dynamic>>{};
    for (int i = 0; i < planned.length; i++) {
      final ex = planned[i];
      final name = (ex['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final circuit = ex['circuitIndex'] ?? 0;
      final key = _exKey(name, circuit);
      if (completedKeys.contains(key)) {
        removals[i] = ex;
      }
    }

    if (removals.isEmpty) return false;

    // Remove from planned (highest index first), and store into suppressed with original insertIndex
    final indices = removals.keys.toList()..sort((a,b) => b.compareTo(a));
    for (final i in indices) {
      final ex = planned.removeAt(i);
      final name = (ex['name'] ?? '').toString().trim();
      final circuit = ex['circuitIndex'] ?? 0;
      final key = _exKey(name, circuit);
      suppressed[key] = {
        'row': ex,
        'insertIndex': i,
      };
    }

    final newStarts = _recomputeCircuitStartsFromPlanned(planned);

    await dayDoc.set({
      'exercises': planned,
      'circuitStartIndices': newStarts,
      'suppressedPlanned': suppressed,
    }, SetOptions(merge: true));

    return true;
  }

  /// Restore any suppressed planned rows whose completion disappeared (no sets).
  /// Restore any suppressed planned rows whose completion disappeared (no sets),
  /// and return the restored records so the UI can mirror immediately.
  Future<List<Map<String, dynamic>>> _restoreSuppressedWhereNotCompleted({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
    required Set<String> completedKeys,
  }) async {
    final dayDoc = FirebaseFirestore.instance
        .collection('planned_blocks').doc(uid)
        .collection('blocks').doc(blockId)
        .collection('weeks').doc('week_$weekIndex')
        .collection('days').doc('day_$dayIndex');

    final snap = await dayDoc.get(const GetOptions(source: Source.server));
    if (!snap.exists) return const [];

    final data = snap.data() ?? {};
    final planned = List<Map<String, dynamic>>.from(data['exercises'] ?? const []);
    final suppressedRaw = (data['suppressedPlanned'] ?? {}) as Map<String, dynamic>;
    if (suppressedRaw.isEmpty) return const [];

    // Keys to restore (suppressed but not completed anymore)
    final suppressedKeys = suppressedRaw.keys.toSet();
    final toRestoreKeys = suppressedKeys.difference(completedKeys);
    if (toRestoreKeys.isEmpty) return const [];

    // Pull records, sort by original insertIndex
    final records = <Map<String, dynamic>>[];
    for (final key in toRestoreKeys) {
      final rec = suppressedRaw[key] as Map<String, dynamic>;
      final row = Map<String, dynamic>.from(rec['row'] as Map);
      final idx = (rec['insertIndex'] ?? planned.length) as int;
      records.add({'key': key, 'row': row, 'insertIndex': idx});
    }
    records.sort((a, b) => (a['insertIndex'] as int).compareTo(b['insertIndex'] as int));

    // Reinsert into planned
    for (final r in records) {
      final idx = (r['insertIndex'] as int).clamp(0, planned.length);
      planned.insert(idx, Map<String, dynamic>.from(r['row'] as Map));
    }

    // Remove restored from suppressed
    for (final r in records) {
      suppressedRaw.remove(r['key'] as String);
    }

    final newStarts = _recomputeCircuitStartsFromPlanned(planned);

    await dayDoc.set({
      'exercises': planned,
      'circuitStartIndices': newStarts,
      'suppressedPlanned': suppressedRaw,
    }, SetOptions(merge: true));

    // ⬅️ Return the restored records so caller can mirror in-memory
    return records;
  }

  /// In-memory prune (unchanged): hide any planned rows that conflict with current completed set.
  bool _prunePlannedRowsInMemory({
    required Map<int, List<ExerciseRow>> parsedByDayIndex,
    required Map<int, List<int>> circuitStartsByDay,
    required int dayIndex,
    required Set<String> completedKeys,
  }) {
    if (!parsedByDayIndex.containsKey(dayIndex)) return false;
    final rows = parsedByDayIndex[dayIndex]!;
    final before = rows.length;

    rows.removeWhere((r) {
      final key = _exKey((r.exercise ?? '').toString(), r.circuitIndex);
      return completedKeys.contains(key);
    });

    if (rows.length != before) {
      final starts = <int>[];
      int? lastCircuit;
      for (int i = 0; i < rows.length; i++) {
        final c = rows[i].circuitIndex;
        if (i == 0 || c != lastCircuit) {
          starts.add(i);
          lastCircuit = c;
        }
      }
      circuitStartsByDay[dayIndex] = starts;
      return true;
    }
    return false;
  }


  Future<void> loadPlannedExercisesFromFirestore() async {
    final userId = UserContext.of(context, listen: false).currentUid;
    if (userId.isEmpty) return; // Fallback in case something goes wrong

    final blockId = _selectedBlockId!;

    final docSnap = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(blockId)
        .get();

    if (!docSnap.exists) return;
    final data = docSnap.data()!;
    final raw = data['plannedExercises'] as List<dynamic>? ?? [];
    plannedExercises = raw.whereType<String>().toList();
    setState(() {});
  }

  void _populateExercisesFromTemplate(
      int weekIndex, int dayIndex, String templateId) {
    final template = templates.firstWhere(
          (t) => t.id == templateId,
      orElse: () => Template(id: '', name: '', day: '', exercises: []),
    );

    // 🔄 Detect if the template used the new circuit-based format
    final List<Map<String, dynamic>> parsedRows = template.exercises is List<Map<String, dynamic>>
        ? List<Map<String, dynamic>>.from(template.exercises)
        : (template.exercises as List)
        .map((e) => {'name': e.toString(), 'circuitIndex': 0})
        .toList();

    final requiredCount = parsedRows.length;
    final rows = exerciseRows[weekIndex][dayIndex];

    // 🧹 Clear existing rows
    rows.clear();

    for (int i = 0; i < requiredCount; i++) {
      final entry = parsedRows[i];
      final row = ExerciseRow(
        exercise: entry['name'],
        circuitIndex: entry['circuitIndex'] ?? 0,
      );

      row.exerciseController.text = entry['name'];
      rows.add(row);
    }

    // 🔄 Update circuitStartIndices
    final List<int> newStarts = [];
    int? lastCircuit;
    for (int i = 0; i < rows.length; i++) {
      final current = rows[i].circuitIndex;
      if (i == 0 || current != lastCircuit) {
        newStarts.add(i);
        lastCircuit = current;
      }
    }

    _ensureCircuitStartIndicesInitialized(weekIndex, dayIndex);
    circuitStartIndices[weekIndex][dayIndex] = newStarts;

    setState(() {});
  }

  @override
  void dispose() {
    _weekPageController?.dispose(); // ✅ only dispose if it was initialized
    final userId = _cachedUid;
    print('🧹 [DISPOSE] Called for userId: $userId');

    if (userId.isEmpty) return; // Fallback in case something goes wrong
    {
      for (int week = 0; week < weekIndices.length; week++) {
        final weekStartDate = _displayStart.add(Duration(days: week * 7));
        if (weekStartDate.isAfter(blockEndDate)) {
          print('⛔ Skipping week_$week — outside block range.');
          continue;
        }

        for (int day = 0; day < 7; day++) {
          final thisDate = weekStartDate.add(Duration(days: day));
          if (thisDate.isAfter(blockEndDate)) {
            print('⛔ Skipping day $day in week_$week — beyond block end.');
            continue;
          }

          final dayKey = 'w${week}_d${day}';
          if (!_loadedDays.contains(dayKey)) {
            print('⏩ Skipping unload day $dayKey — was never loaded.');
            continue;
          }
          print('📤 Proceeding to save w$week d$day...');
          saveDayToFirestore(week, day).catchError((e, stack) {
            print('❌ Failed to save week $week day $day during dispose: $e');
          });


          _trimEmptyExerciseRows(week, day); // ✅ Trim only loaded days
          saveDayToFirestore(week, day).catchError((e, stack) {
            print('❌ Failed to save week $week day $day during dispose: $e');
          });

        }

      }
    }

    // ✅ Dispose TextEditingControllers
    for (final week in exerciseRows) {
      for (final day in week) {
        for (final row in day) {
          row.exerciseController.dispose();
          row.weightController.dispose();
          row.repsController.dispose();
          row.rirController.dispose();
          row.velocityController.dispose();
          row.notesController.dispose();
        }
      }
    }

    for (final node in _focusNodes.values) {
      node.dispose();
    }
    _focusNodes.clear();
    _fieldScrollController.dispose();

    super.dispose();
  }



  DateTime _getMostRecentMonday([DateTime? reference]) {
    DateTime now = reference ?? DateTime.now();
    int diff = now.weekday - DateTime.monday;
    return now.subtract(Duration(days: diff < 0 ? 7 + diff : diff));
  }

  List<int> _getCircuitStartIndices(int weekIndex, int dayIndex) {
    _ensureCircuitStartIndicesInitialized(weekIndex, dayIndex);
    return circuitStartIndices[weekIndex][dayIndex];
  }

  Color getRowColor(int weekIndex, int dayIndex, int rowIndex) {
    final circuitStartIndices = _getCircuitStartIndices(weekIndex, dayIndex);

    // Find which circuit this row belongs to
    int circuitNumber = 0;
    for (int i = 0; i < circuitStartIndices.length; i++) {
      if (rowIndex >= circuitStartIndices[i]) {
        circuitNumber = i;
      }
    }

    // Rotate through your preferred circuit colors
    final circuitColors = [
      Colors.blueGrey.shade800,
      Colors.blueGrey.shade800,
      Colors.blueGrey.shade800,
    ];

    return circuitColors[circuitNumber % circuitColors.length];
  }

  void _ensureCircuitStartIndicesInitialized(int weekIndex, int dayIndex) {
    while (circuitStartIndices.length <= weekIndex) {
      circuitStartIndices.add([]);
    }

    while (circuitStartIndices[weekIndex].length <= dayIndex) {
      circuitStartIndices[weekIndex].add([0]); // Default to one circuit
    }

    if (circuitStartIndices[weekIndex][dayIndex].isEmpty) {
      circuitStartIndices[weekIndex][dayIndex] = [0];
    }
  }

  // Week specific function, calls current week on start up and triggered by page scroll

  Future<void> loadBlockDataForWeek(int weekIndex) async {
    final total = Stopwatch()..start();
    print('⏳ [BB2] loadBlockDataForWeek($weekIndex) start');


    final uid = _cachedUid; // lock to the selected athlete for this BB2 State
    print('🧬 [UID CHECK] start: local=$uid field=$_cachedUid');

    if ((uid ?? '').isEmpty || _selectedBlockId == null) {
      print('❌ [LOAD_ABORT] uid or selectedBlockId missing');
      return;
    }

    final blocksCol = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks');
    final weekDocRef = blocksCol.doc(_selectedBlockId)
        .collection('weeks')
        .doc('week_$weekIndex');
    print('🧭 [PATH] uid=${_cachedUid} block=${_selectedBlockId} week=$weekIndex');
    print('🧭 [PATH] weekDocRef=${weekDocRef.path}');
    print('🧭 [PATH] blockDoc=${blocksCol.doc(_selectedBlockId).path}');
    print('🧭 [PATH] daysCol=${weekDocRef.collection('days').path}');


    // 1) Pull stable pieces in parallel (cache-first for fast path)
    final step = Stopwatch()..start();
    final cacheFetch = Future.wait([
      weekDocRef.get(const GetOptions(source: Source.cache)),
      blocksCol.doc(_selectedBlockId).get(const GetOptions(source: Source.cache)),
      weekDocRef.collection('days').get(const GetOptions(source: Source.cache)),
    ]);



    final serverFetch = Future.wait([
      weekDocRef.get(const GetOptions(source: Source.server)),
      blocksCol.doc(_selectedBlockId).get(const GetOptions(source: Source.server)),
      weekDocRef.collection('days').get(const GetOptions(source: Source.server)),
    ]);



    // Try cache first (fast UI), then reconcile with server
    var cacheResults = await cacheFetch;
    var weekSnap = cacheResults[0] as DocumentSnapshot<Map<String, dynamic>>;
    var parentBlockSnap = cacheResults[1] as DocumentSnapshot<Map<String, dynamic>>;
    var daySnaps = cacheResults[2] as QuerySnapshot<Map<String, dynamic>>;
    print('✅ [CACHE OK] week.exists=${weekSnap.exists} block.exists=${parentBlockSnap.exists} days=${daySnaps.docs.length}');

    print('   ↳ cache fetch took ${step.elapsedMilliseconds}ms');
    step
      ..reset()
      ..start();

    // Optional: if cache empty, we’ll rely on server below
    // (Don’t early-return; we still want the server pass.)

    // 2) Server reconciliation (don’t block UI if cache had data)
    try {
      final srv = await serverFetch;
      weekSnap = srv[0] as DocumentSnapshot<Map<String, dynamic>>;
      parentBlockSnap = srv[1] as DocumentSnapshot<Map<String, dynamic>>;
      daySnaps = srv[2] as QuerySnapshot<Map<String, dynamic>>;
      print('✅ [SERVER OK] week.exists=${weekSnap.exists} block.exists=${parentBlockSnap.exists} days=${daySnaps.docs.length}');

      print('   ↳ server fetch took ${step.elapsedMilliseconds}ms (total: ${total.elapsedMilliseconds}ms)');
    } catch (e) {
      print('   ⚠️ server fetch failed (offline?): $e — using cache results');
    }

    if (!weekSnap.exists) {
      print('❌ Week $weekIndex does not exist under planned_blocks.');
      return;
    }

    // 3) Exercise settings — load once & cache globally if already loaded
    final blockData = parentBlockSnap.data();
    // 🚚 Give PMU the planned details (same source WES uses)
    final plannedDetails = Map<String, Map<String, dynamic>>.from(
      ((blockData?['plannedExerciseDetails'] ?? const {}) as Map).map(
            (k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)),
      ),
    );
    PeriodizationModelUtils.setExerciseSettings(plannedDetails);
    print('🧭 [BB2→PMU] injected plannedExerciseDetails keys=${plannedDetails.keys}');

    final settings = blockData?['exerciseSettings'];

    final needSettingsReload =
        _exerciseSettings.isEmpty ||
            _dataOwnerUid != uid ||
            _dataOwnerBlockId != _selectedBlockId;

    if (settings != null && needSettingsReload) {
      _exerciseSettings = Map<String, Map<String, dynamic>>.from(
        (settings as Map).map((k, v) =>
            MapEntry(k.toString(), Map<String, dynamic>.from(v as Map))),
      );
      _dataOwnerUid = uid;
      _dataOwnerBlockId = _selectedBlockId;
      if (kDebugMode) {
        debugPrint('📦 [BB2] exerciseSettings reloaded for uid=$uid, block=$_selectedBlockId '
            '(${_exerciseSettings.length} exercises)');
      }

    }

    // 4) Ensure all 7 day docs exist (handle partial weeks too)
    final existingIds = daySnaps.docs.map((d) => d.id).toSet();
    final missingIds = <String>[];
    for (int d = 0; d < 7; d++) {
      final id = 'day_$d';
      if (!existingIds.contains(id)) missingIds.add(id);
    }

    if (missingIds.isNotEmpty) {
      print('📭 Week $weekIndex missing ${missingIds.length} day docs → creating: $missingIds');
      final batch = FirebaseFirestore.instance.batch();
      final daysCol = weekDocRef.collection('days');
      for (final id in missingIds) {
        batch.set(daysCol.doc(id), {
          'exists': true,
          'exercises': [],
          'circuitStartIndices': [0],
        });
      }
      final t = Stopwatch()..start();
      await batch.commit();
      // refresh daySnaps so downstream parsing sees all 7
      daySnaps = await daysCol.get(const GetOptions(source: Source.server));
      print('   ↳ created ${missingIds.length} day docs in ${t.elapsedMilliseconds}ms');
    }

    // === 4.5) Pre-hydrate completedWesRows for counting across the block (CACHE-ONLY) ===
// This makes DUP-by-exposure indexing correct on first paint, before opening WES.
        {
      String _ymd(DateTime d) {
        final m = d.month.toString().padLeft(2, '0');
        final day = d.day.toString().padLeft(2, '0');
        return '${d.year}-$m-$day';
      }
      String _isoDay(DateTime d) =>
          '${DateTime(d.year, d.month, d.day).toIso8601String().split(".").first}.000';

      print('🧬 [UID CHECK] prehydrate: local=$uid field=$_cachedUid');

      final workoutsCol = FirebaseFirestore.instance
          .collection('users')
          .doc(_cachedUid)
          .collection('workouts');

      // Cover from block start through the END of this week (inclusive of this week)
      final rangeStart = DateTime(blockStartDate.year, blockStartDate.month, blockStartDate.day);
      final rangeEnd   = rangeStart.add(Duration(days: (weekIndex * 7) + 7));

      // 1) Per-day doc-id snapshots (CACHE)
      final futures   = <Future<DocumentSnapshot<Map<String, dynamic>>>>[];
      final dateKeys  = <String>[];
      final totalDays = (weekIndex * 7) + 7;
      for (int d = 0; d < totalDays; d++) {
        final date = rangeStart.add(Duration(days: d));
        final key  = _ymd(date);
        dateKeys.add(key);
        final _preHydDocRef = workoutsCol.doc(key);
        futures.add(
            _preHydDocRef
                .get(const GetOptions(source: Source.cache))
                .catchError((_) => _preHydDocRef.get(const GetOptions(source: Source.server)))
        );

      }
      print('▶️ [PREHYD] waiting ${futures.length} doc-id cache gets...');

      final docIdSnaps = await Future.wait(futures);

      // 2) Legacy auto-ID snapshots for the whole range (CACHE)
      final legacyCacheSnap = await workoutsCol
          .where('date', isGreaterThanOrEqualTo: _isoDay(rangeStart))
          .where('date', isLessThan: _isoDay(rangeEnd))
          .get(const GetOptions(source: Source.cache));

      // Index legacy docs by day
      final legacyByDateCache = <String, List<Map<String, dynamic>>>{};
      for (final d in legacyCacheSnap.docs) {
        final raw = d.data()['date'];
        final dt  = (raw is Timestamp) ? raw.toDate() : DateTime.tryParse(raw?.toString() ?? '');
        if (dt == null) continue;
        final key = _ymd(DateTime(dt.year, dt.month, dt.day));
        final exs = List<Map<String, dynamic>>.from(d.data()['exercises'] ?? const []);
        (legacyByDateCache[key] ??= <Map<String, dynamic>>[]).addAll(exs);
      }

      // 3) Merge doc-id + legacy into completedWesRows if not already present
      int seeded = 0;
      for (int i = 0; i < docIdSnaps.length; i++) {
        final dateKey = dateKeys[i];
        final snap    = docIdSnaps[i];

        final fromDocId = snap.exists
            ? List<Map<String, dynamic>>.from(snap.data()?['exercises'] ?? const [])
            : const <Map<String, dynamic>>[];

        final fromLegacy = legacyByDateCache[dateKey] ?? const <Map<String, dynamic>>[];

        if ((fromDocId.isEmpty && fromLegacy.isEmpty) || completedWesRows.containsKey(dateKey)) {
          continue;
        }

        final merged = <Map<String, dynamic>>[];
        if (fromDocId.isNotEmpty) merged.addAll(fromDocId);
        if (fromLegacy.isNotEmpty) merged.addAll(fromLegacy);

        if (merged.isNotEmpty) {
          completedWesRows[dateKey] = merged;
          seeded++;
        }
      }

      print('📦 [BB2 Count PreHydrate] seeded $seeded day(s) from cache '
          'for ${dateKeys.length} target days (block → endOfWeek ${_ymd(rangeEnd.subtract(const Duration(days: 1)))})');
    }
// === end 4.5 ===


    // 5) Build day data first (parse Firestore)
    final parsedByDayIndex = <int, List<ExerciseRow>>{};
    final circuitStartsByDay = <int, List<int>>{};
    for (final d in daySnaps.docs) {
      final dayIndex = int.tryParse(d.id.replaceFirst('day_', '')) ?? 0;
      final data = d.data();
      final exercises = List<Map<String, dynamic>>.from(data['exercises'] ?? []);
      final savedCircuitIndices = List<int>.from(data['circuitStartIndices'] ?? [0]);

      final rows = <ExerciseRow>[];
      for (var i = 0; i < exercises.length; i++) {
        final ex = exercises[i];

        // ⬅️ NAME RESTORE: same as old version
        final name = (ex['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;

        final row = ExerciseRow(
          id: const Uuid().v4(),
          exercise: name,
          circuitIndex: ex.containsKey('circuitIndex')
              ? ex['circuitIndex']
              : _getCircuitIndexForRow(i, savedCircuitIndices),
        );
        // ⬅️ NAME RESTORE: put the name into the controller for hint logic
        row.exerciseController.text = name;



        // ⬇️ ADD THIS after creating the row:
        final rowIndex = rows.length;  // <-- define it first
        _trackWeightController(
          c: row.weightController,
          exerciseName: name,
          weekIndex: weekIndex,
          dayIndex: dayIndex,
          rowIndex: rowIndex,
        );
        debugPrint('🧩 [RowNew] "$name" created (w$weekIndex d$dayIndex r$rowIndex) '
            'initial weight="${row.weightController.text}" '
            'reps="${row.repsController.text}" rir="${row.rirController.text}"');
        final baseKey = 'w${weekIndex}_d${dayIndex}_r${rowIndex}';

        // Restore fields
        // Restore fields
        final rawWeight = ex['weight'];
        final rawReps   = ex['reps'];
        final rawRIR    = ex['rir'];
        final rawVelocity = ex['velocity'];
        final rawNotes    = ex['notes'];

        if (rawVelocity != null && rawVelocity.toString().trim().isNotEmpty) {
          row.velocityController.text = rawVelocity.toString().trim();
        }
        if (rawNotes != null && rawNotes.toString().trim().isNotEmpty) {
          row.notesController.text = rawNotes.toString().trim();
        }

        final weightVal = rawWeight != null ? double.tryParse(rawWeight.toString()) : null;
        final repsVal   = rawReps   != null ? int.tryParse(rawReps.toString())      : null;
        final rirVal    = rawRIR    != null ? double.tryParse(rawRIR.toString())    : null;

// 👇 BW-aware weight restore for PLANNED rows
        final exIdForRow = PeriodizationModelUtils.nameToId[name] ?? name;
        final bool _isBw = PeriodizationModelUtils.isBodyweightExercise(id: exIdForRow, name: name);
        final DateTime _planDate = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));

        if (_isBw) {
          final num? awRaw = (ex['addedWeight'] as num?) ?? (ex['weightAdded'] as num?); // legacy alias
          double? displayAdded;

          if (awRaw != null) {
            displayAdded = awRaw.toDouble();
          } else if (weightVal != null && weightVal != 0.0) {
            // derive once from absolute if we don't have addedWeight yet
            displayAdded = PeriodizationModelUtils.toDisplayAddedWeight(
              uid: _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '',
              absoluteKg: weightVal,
              exerciseId: exIdForRow,
              exerciseName: name,
              asOfDate: _planDate,
            );
          }

          if (displayAdded != null) {
            debugPrint( '🪪 [Step5 Loader] ex="$name" ' 'w$weekIndex d$dayIndex r$rowIndex ' '→ weightVal=$weightVal ' 'from ex["weight"]=${ex['weight']} ' '(type=${ex['weight']?.runtimeType})', );
            row.weightController.text = displayAdded.toString();
            _savedFields['${baseKey}_weight'] = true;
          }
        } else {
          if (weightVal != null && weightVal != 0.0) {
            row.weightController.text = '$weightVal';
            _savedFields['${baseKey}_weight'] = true;
          }
        }

// reps
        if (repsVal != null && repsVal != 0) {
          row.repsController.text = '$repsVal';
          _savedFields['${baseKey}_reps'] = true;
        }

// RIR
        if (rirVal != null && rirVal != 0.0) {
          row.rirController.text = '$rirVal';
          _savedFields['${baseKey}_rir'] = true;
        }


// velocity
        if (rawVelocity != null && rawVelocity.toString().trim().isNotEmpty) {
          row.velocityController.text = rawVelocity.toString().trim();
          _savedFields['${baseKey}_velocity'] = true; // ✅ save bit
        }

// notes
        if (rawNotes != null && rawNotes.toString().trim().isNotEmpty) {
          row.notesController.text = rawNotes.toString().trim();
          _savedFields['${baseKey}_notes'] = true;    // ✅ save bit
        }

        rows.add(row);
      }

      parsedByDayIndex[dayIndex] = rows;

      // recompute circuit starts
      final starts = <int>[];
      int? lastCircuit;
      for (int i = 0; i < rows.length; i++) {
        final c = rows[i].circuitIndex;
        if (i == 0 || c != lastCircuit) {
          starts.add(i);
          lastCircuit = c;
        }
      }
      circuitStartsByDay[dayIndex] = starts;
    }

    String _ymd(DateTime d) {
      final m = d.month.toString().padLeft(2, '0');
      final day = d.day.toString().padLeft(2, '0');
      return '${d.year}-$m-$day';
    }

    // 6) WES overrides: cache-first, then server reconcile
    final wesStep = Stopwatch()..start();
    final wesCacheFetches = <Future<DocumentSnapshot<Map<String, dynamic>>>>[];
    final wesServerFetches = <Future<DocumentSnapshot<Map<String, dynamic>>>>[];
    final wesDayOrder = <int>[];

// Week window for a single range query (covers legacy auto-ID docs)
    final weekStart = DateTime(blockStartDate.year, blockStartDate.month, blockStartDate.day)
        .add(Duration(days: weekIndex * 7));
    final weekEnd = weekStart.add(const Duration(days: 7));

    String _isoDay(DateTime d) =>
        '${DateTime(d.year, d.month, d.day).toIso8601String().split(".").first}.000';
    print('🧬 [UID CHECK] wes-cache: local=$uid field=$_cachedUid');

    final workoutsCol = FirebaseFirestore.instance
        .collection('users')
        .doc(_cachedUid)
        .collection('workouts');

// One range query for the whole week (cache + server) to catch auto-ID docs
    final weekCacheQuery = workoutsCol
        .where('date', isGreaterThanOrEqualTo: _isoDay(weekStart))
        .where('date', isLessThan: _isoDay(weekEnd))
        .get(const GetOptions(source: Source.cache));

    final weekServerQuery = workoutsCol
        .where('date', isGreaterThanOrEqualTo: _isoDay(weekStart))
        .where('date', isLessThan: _isoDay(weekEnd))
        .get(const GetOptions(source: Source.server));

// Always fetch WES for all 7 days so completed entries are available for indexing
    for (int dayIndex = 0; dayIndex < 7; dayIndex++) {
      final date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
      final docRef = FirebaseFirestore.instance
          .collection('users')
          .doc(_cachedUid) // selected athlete
          .collection('workouts')
          .doc(_ymd(date));
      wesDayOrder.add(dayIndex);
      wesCacheFetches.add(
          docRef
              .get(const GetOptions(source: Source.cache))
              .catchError((_) => docRef.get(const GetOptions(source: Source.server)))
      );

      wesServerFetches.add(docRef.get(const GetOptions(source: Source.server)));
    }

// 6a) Apply cache (fast paint)
// Fetch: per-day doc-id attempts
    final wesCacheDocs = await Future.wait(wesCacheFetches);

// Fetch: weekly legacy (auto-ID) docs once
    final weekCacheSnap = await weekCacheQuery;

// Index legacy docs by yyyy-MM-dd (date field) → collect ALL docs per day
    final Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>> legacyByDateCache = {};
    for (final d in weekCacheSnap.docs) {
      final raw = d.data()['date'];
      final dt = (raw is Timestamp)
          ? raw.toDate()
          : DateTime.tryParse(raw?.toString() ?? '');
      if (dt == null) continue;
      final key = _ymd(DateTime(dt.year, dt.month, dt.day));
      (legacyByDateCache[key] ??= []).add(d);
    }

// Now process the 7 days, preferring doc-id; also merge any legacy docs
    for (int i = 0; i < wesCacheDocs.length; i++) {
      final dayIndex = wesDayOrder[i];
      final date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
      final dateKey = _ymd(date);

      // Merge doc-id snapshot + ALL legacy auto-ID docs into one list
      final mergedSaved = <Map<String, dynamic>>[];

      final docIdSnap = wesCacheDocs[i];
      if (docIdSnap.exists) {
        mergedSaved.addAll(List<Map<String, dynamic>>.from(
            docIdSnap.data()?['exercises'] ?? const []));
      }

      final legacyList = legacyByDateCache[dateKey] ?? const [];
      for (final legacy in legacyList) {
        mergedSaved.addAll(List<Map<String, dynamic>>.from(
            legacy.data()['exercises'] ?? const []));
      }
      if (!docIdSnap.exists && legacyList.isNotEmpty) {
        print('↩️ [BB2] Using ${legacyList.length} legacy auto-ID workout(s) from cache for $dateKey');
      }

      if (mergedSaved.isEmpty) {
        completedWesRows[dateKey] = const [];
        continue;
      }

      // Keep original name so the rest of the loop stays unchanged
      final savedExercises = mergedSaved;

      // Right after: final savedExercises = mergedSaved;
      for (final ex in savedExercises) {
        final nameDbg = (ex['name'] ?? '').toString();
        if (nameDbg.trim().isEmpty) continue;
        final setsDbg = List<Map<String, dynamic>>.from(ex['sets'] ?? const []);
        if (setsDbg.isEmpty) continue;
        final wDbg = setsDbg[0]['weight'];
        debugPrint('📦 [SavedSnapshot] $nameDbg w${weekIndex} d${dayIndex} → set0.weight=$wDbg');
      }

      completedWesRows[dateKey] = savedExercises;

      // Planned rows may be null/empty; only apply top-set values if present
      final rows = parsedByDayIndex[dayIndex]; // may be null or empty

      for (final ex in savedExercises) {
        final name = (ex['name'] ?? '').toString();
        final circuit = ex['circuitIndex'] ?? 0;
        final sets = List<Map<String, dynamic>>.from(ex['sets'] ?? const []);
        if (name.trim().isEmpty || sets.isEmpty) continue;

        if (rows != null && rows.isNotEmpty) {
          final idx = rows.indexWhere((r) => r.exercise == name && r.circuitIndex == circuit);
          if (idx < 0) continue;
          final r = rows[idx];

          // ⬇️ BW-only guard: do not prefill planned BW weight as user text
          final bool _isBw = PeriodizationModelUtils.isBodyweightExercise(name: name);
          final bool _isCompleted = (ex['savedAt'] != null) || (ex['status'] == 'completed');
          final String _w = sets.isNotEmpty ? (sets[0]['weight']?.toString() ?? '') : '';

          if (_isBw && !_isCompleted) {
            r.weightController.text = '';                  // planned BW → keep blank
          } else {
            r.weightController.text = _w;                  // non-BW or completed BW → restore as before
          }

          // Unchanged for other fields
          r.repsController.text     = sets[0]['reps']?.toString()     ?? '';
          r.rirController.text      = sets[0]['rir']?.toString()      ?? '';
          r.velocityController.text = sets[0]['velocity']?.toString() ?? '';
          r.notesController.text    = sets[0]['notes']?.toString()    ?? '';

          final baseKey = 'w${weekIndex}_d${dayIndex}_r$idx';

          // ⬇️ Only adjust the weight saved flag to match the guard above
          _savedFields['${baseKey}_weight']   =
          (_isBw && !_isCompleted) ? false : r.weightController.text.trim().isNotEmpty;

          // Everything else unchanged
          _savedFields['${baseKey}_reps']     = r.repsController.text.trim().isNotEmpty;
          _savedFields['${baseKey}_rir']      = r.rirController.text.trim().isNotEmpty;
          _savedFields['${baseKey}_velocity'] = r.velocityController.text.trim().isNotEmpty;
          _savedFields['${baseKey}_notes']    = r.notesController.text.trim().isNotEmpty;
        }

      }

      // ✅ Prune planned dupes in-memory so UI shows only one per exercise that day
      final completedKeys = _completedKeysFromSaved(savedExercises);
      _prunePlannedRowsInMemory(
        parsedByDayIndex: parsedByDayIndex,
        circuitStartsByDay: circuitStartsByDay,
        dayIndex: dayIndex,
        completedKeys: completedKeys,
      );
    }
    print('   ↳ WES cache fetch (${wesCacheDocs.length} docs) took ${wesStep.elapsedMilliseconds}ms');

// 6b) Server reconcile in background
    unawaited(Future.wait(wesServerFetches).then((wesServerDocs) async {
      bool changed = false;

      // Fetch weekly legacy (server) and index by date (ALL docs per day)
      final weekServerSnap = await weekServerQuery;
      final Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>> legacyByDateServer = {};
      for (final d in weekServerSnap.docs) {
        final raw = d.data()['date'];
        final dt = (raw is Timestamp)
            ? raw.toDate()
            : DateTime.tryParse(raw?.toString() ?? '');
        if (dt == null) continue;
        final key = _ymd(DateTime(dt.year, dt.month, dt.day));
        (legacyByDateServer[key] ??= []).add(d);
      }

      for (int i = 0; i < 7; i++) {
        final dayIndex = wesDayOrder[i];
        final date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
        final dateKey = _ymd(date);

        // Merge doc-id snapshot + ALL legacy auto-ID docs into one list
        final mergedSaved = <Map<String, dynamic>>[];

        final docIdSnap = wesServerDocs[i];
        if (docIdSnap.exists) {
          mergedSaved.addAll(List<Map<String, dynamic>>.from(
              docIdSnap.data()?['exercises'] ?? const []));
        }

        final legacyList = legacyByDateServer[dateKey] ?? const [];
        for (final legacy in legacyList) {
          mergedSaved.addAll(List<Map<String, dynamic>>.from(
              legacy.data()['exercises'] ?? const []));
        }

        if (!docIdSnap.exists && legacyList.isNotEmpty) {
          print('↩️ [BB2] Using ${legacyList.length} legacy auto-ID workout(s) from server for $dateKey');
        }

        if (mergedSaved.isEmpty) continue;

        // Keep original name so the rest of the loop stays unchanged
        final savedExercises = mergedSaved;

        // ⬇️ Ensure we always have a mutable list for this day
        final rows = parsedByDayIndex[dayIndex] ?? <ExerciseRow>[];
        if (!parsedByDayIndex.containsKey(dayIndex)) {
          parsedByDayIndex[dayIndex] = rows;
        }

        // Apply WES values into matching planned rows (unchanged)
        for (final ex in savedExercises) {
          final name = (ex['name'] ?? '').toString();
          final circuit = ex['circuitIndex'] ?? 0;
          final sets = List<Map<String, dynamic>>.from(ex['sets'] ?? []);
          if (name.trim().isEmpty || sets.isEmpty) continue;

          if (rows.isNotEmpty) {
            final idx = rows.indexWhere((r) => r.exercise == name && r.circuitIndex == circuit);
            if (idx >= 0) {
              final r = rows[idx];
              String v(dynamic s) => s?.toString() ?? '';
              final w  = v(sets[0]['weight']);
              final rp = v(sets[0]['reps']);
              final rr = v(sets[0]['rir']);
              final ve = v(sets[0]['velocity']);
              final no = v(sets[0]['notes']);

              // ⬇️ BW-only guard: do not prefill planned BW weight as user text
              final bool _isBw = PeriodizationModelUtils.isBodyweightExercise(name: name);
              final bool _isCompleted = (ex['savedAt'] != null) || (ex['status'] == 'completed');
              final String wApplied = (_isBw && !_isCompleted) ? '' : w;

              if (r.weightController.text != wApplied ||
                  r.repsController.text   != rp ||
                  r.rirController.text    != rr ||
                  r.velocityController.text != ve ||
                  r.notesController.text  != no) {

                r.weightController.text   = wApplied;
                r.repsController.text     = rp;
                r.rirController.text      = rr;
                r.velocityController.text = ve;
                r.notesController.text    = no;

                final baseKey = 'w${weekIndex}_d${dayIndex}_r$idx';
                _savedFields['${baseKey}_weight']   = (_isBw && !_isCompleted) ? false : wApplied.isNotEmpty;
                _savedFields['${baseKey}_reps']     = rp.isNotEmpty;
                _savedFields['${baseKey}_rir']      = rr.isNotEmpty;
                _savedFields['${baseKey}_velocity'] = ve.isNotEmpty;
                _savedFields['${baseKey}_notes']    = no.isNotEmpty;
                changed = true;
              }
            }
          }

        }

        // Compute keys that are currently "completed" (must have ≥1 set)
        final completedKeys = _completedKeysFromSaved(savedExercises);

        // (A) SUPPRESS planned duplicates (persist)
        if (completedKeys.isNotEmpty && _cachedUid != null && _selectedBlockId != null) {
          final didSuppress = await _suppressPlannedForCompletedKeys(
            uid: _cachedUid!,
            blockId: _selectedBlockId!,
            weekIndex: weekIndex,
            dayIndex: dayIndex,
            completedKeys: completedKeys,
          );
          if (didSuppress) changed = true;
        }

        // (B) RESTORE suppressed rows where completion disappeared, and mirror them in-memory
        if (_cachedUid != null && _selectedBlockId != null) {
          final restored = await _restoreSuppressedWhereNotCompleted(
            uid: _cachedUid!,
            blockId: _selectedBlockId!,
            weekIndex: weekIndex,
            dayIndex: dayIndex,
            completedKeys: completedKeys,
          );

          if (restored.isNotEmpty) {
            for (final r in restored) {
              final rowMap  = Map<String, dynamic>.from(r['row'] as Map);
              final insertAt = (r['insertIndex'] as int).clamp(0, rows.length);

              final name = (rowMap['name'] ?? '').toString().trim();
              if (name.isEmpty) continue;
              final circuit = (rowMap['circuitIndex'] ?? 0) as int;

              final er = ExerciseRow(
                id: const Uuid().v4(),
                exercise: name,
                circuitIndex: circuit,
              );
              er.exerciseController.text = name;

              rows.insert(insertAt, er);
            }

            // Recompute circuit headers for the day
            final starts = <int>{};
            for (int j = 0; j < rows.length; j++) {
              if (j == 0 || rows[j].circuitIndex != rows[j - 1].circuitIndex) {
                starts.add(j);
              }
            }
            circuitStartsByDay[dayIndex] = starts.toList()..sort();
            changed = true;
          }
        }

        // (C) Prune in-memory planned rows that are still completed (so we never show both)
        final didPrune = _prunePlannedRowsInMemory(
          parsedByDayIndex: parsedByDayIndex,
          circuitStartsByDay: circuitStartsByDay,
          dayIndex: dayIndex,
          completedKeys: completedKeys,
        );
        if (didPrune) changed = true;
      }

      if (changed && mounted) setState(() {});
    }));

    // 8) Commit to state once
    if (!mounted) return;
    setState(() {
      for (final e in parsedByDayIndex.entries) {
        final dayIndex = e.key;
        exerciseRows[weekIndex][dayIndex] = e.value;
        circuitStartIndices[weekIndex][dayIndex] = circuitStartsByDay[dayIndex] ?? [0];
        _loadedDays.add('w${weekIndex}_d$dayIndex');
      }
    });

    print('✅ [BB2] loadBlockDataForWeek($weekIndex) done in ${total.elapsedMilliseconds}ms');
    print('📦 [BB2 Count Ready] week=$weekIndex hydratedKeys=${completedWesRows.keys.toList()..sort()}');

  }




  int _getCircuitIndexForRow(int rowIndex, List<int> circuitStartIndices) {
    int index = 0;
    for (int i = 0; i < circuitStartIndices.length; i++) {
      if (rowIndex >= circuitStartIndices[i]) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  Future<void> loadCompletedWorkoutsForDay(DateTime date) async {
    final uid = UserContext.of(context, listen: false).currentUid;


    final String dateKey = DateFormat('yyyy-MM-dd').format(date);
    if (completedWesRows.containsKey(dateKey)) return; // already loaded

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid) // ✅ now using the selected athlete
        .collection('workouts')
        .where('date', isGreaterThanOrEqualTo: date.toIso8601String())
        .where('date', isLessThan: date.add(const Duration(days: 1)).toIso8601String())
        .get();

    final Map<String, Map<String, dynamic>> exerciseMap = {};

    for (final doc in snapshot.docs) {
      final List<dynamic> exercises = doc['exercises'] ?? [];
      for (final e in exercises) {
        final name = e['name'] ?? 'Unnamed';
        final circuitIndex = e['circuitIndex'] ?? 0;
        final sets = List<Map<String, dynamic>>.from(e['sets'] ?? []);

        if (!exerciseMap.containsKey(name)) {
          exerciseMap[name] = {
            'name': name,
            'circuitIndex': circuitIndex,
            'sets': sets,
          };
        } else {
          exerciseMap[name]!['sets'].addAll(sets);
        }
      }
    }

    if (exerciseMap.isNotEmpty) {
      setState(() {
        completedWesRows[dateKey] = exerciseMap.values.toList();
      });
    }
  }

  Future<void> loadTopSetsFromWorkouts({String? uid}) async {
    final resolvedUid = uid ?? FirebaseAuth.instance.currentUser!.uid;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(resolvedUid)
        .collection('workouts')
        .get();

    final Map<String, List<Map<String, dynamic>>> tempTopSets = {};

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final topSetsRaw = data['topSets'] as List<dynamic>? ?? [];

      final topSets = topSetsRaw
          .whereType<Map>() // ensure each is a map
          .map((e) => Map<String, dynamic>.from(e))
          .toList();


      for (final set in topSets) {
        final name = set['exercise'];
        if (name != null && name is String && name.trim().isNotEmpty) {
          tempTopSets.putIfAbsent(name, () => []);
          tempTopSets[name]!.add(set);
        }
      }
    }

    // ✅ Keep only the most recent 4 sets per exercise
    tempTopSets.updateAll((_, sets) => sets.take(4).toList());

    setState(() {
      topSetsByExercise = tempTopSets;

      // ✅ ALSO assign to global rep history map using both name + ID
      for (final name in tempTopSets.keys) {
        final reps = tempTopSets[name]!
            .map((set) => int.tryParse(set['reps']?.toString() ?? ''))
            .whereType<int>()
            .toList();

        PeriodizationModelUtils.exercisePreviousTopSetReps[name] = reps;

        final id = PeriodizationModelUtils.nameToId[name];
        if (id != null) {
          PeriodizationModelUtils.exercisePreviousTopSetReps[id] = reps;
        }

        print('🧠 [TopSetLoader] Stored ${reps.length} reps for "$name" and ID=$id');
      }

      print("✅ Top sets loaded (max 4 per exercise): ${topSetsByExercise.length} exercises.");
    });
  }

  void updateFutureDaysWithEditedDay(int sourceWeekIndex, int sourceDayIndex) {
    if (sourceWeekIndex >= exerciseRows.length) return;

    final sourceRows = exerciseRows[sourceWeekIndex][sourceDayIndex];

    for (int week = sourceWeekIndex + 1; week < exerciseRows.length; week++) {
      final targetRows = exerciseRows[week][sourceDayIndex];

      // Match circuit structure from source
      targetRows.clear();
      for (final srcRow in sourceRows) {
        final clonedRow = ExerciseRow(
          circuitIndex: srcRow.circuitIndex,
          exercise: srcRow.exercise,
        );
        clonedRow.exerciseController.text = srcRow.exercise ?? '';
        targetRows.add(clonedRow);
      }

      // Rebuild circuitStartIndices
      final starts = <int>{};
      for (int i = 0; i < targetRows.length; i++) {
        if (i == 0 || targetRows[i].circuitIndex != targetRows[i - 1].circuitIndex) {
          starts.add(i);
        }
      }

      _ensureCircuitStartIndicesInitialized(week, sourceDayIndex);
      circuitStartIndices[week][sourceDayIndex] = starts.toList()..sort();
    }

    setState(() {}); // Rebuild UI
  }

  void _markSavedFields(int week, int day, List<ExerciseRow> rows) {
    for (int rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];

      if (row.weightController.text.isNotEmpty) {
        _savedFields['w${week}_d${day}_r${rowIndex}_weight'] = true;
      }
      if (row.repsController.text.isNotEmpty) {
        _savedFields['w${week}_d${day}_r${rowIndex}_reps'] = true;
      }
      if (row.rirController.text.isNotEmpty) {
        _savedFields['w${week}_d${day}_r${rowIndex}_rir'] = true;
      }
    }
  }

  Future<void> _reloadForBlock(String blockId) async {
    setState(() {
      _loading = true;
    });

    // 1) clear out everything
    exerciseRows.clear();
    selectedTemplateIds.clear();
    circuitStartIndices.clear();
    loadedWeekIndices.clear();
    _cachedProgressedValues.clear();
    plannedExerciseDetails.clear();

    // 2) load the new block’s meta
    final meta = await _repo.loadBlockMeta(
      userId: UserContext.of(context, listen: false).currentUid,
      blockId: blockId,
    );

    blockStartDate = meta.startDate;
    blockEndDate = meta.endDate;
    _selectedDays = meta.selectedDays;

    // 3) recompute how many weeks we now have
    _computeWeekBounds();

    // 4) **re‐initialize your per‐week/day arrays** for the new totalWeeks:
    exerciseRows = List.generate(
      totalWeeks,
      (_) => List.generate(
          7,
          (_) => [
                ExerciseRow(circuitIndex: 0),
                ExerciseRow(circuitIndex: 0),
              ]),
    );
    selectedTemplateIds = List.generate(
      totalWeeks,
      (_) => List.filled(7, null),
    );
    circuitStartIndices = List.generate(
      totalWeeks,
      (_) => List.generate(7, (_) => [0]),
    );

    // 5) now pull in all of your Firestore + template + WES + progression data
    await loadAllData();
    await loadPlannedExercisesFromFirestore();


    // 6) finally, turn off the loading spinner
    setState(() {
      _loading = false;
    });
  }

  Future<void> _persistSavedFieldKeysForDay(int week, int day) async {
    final prefs = await SharedPreferences.getInstance();
    final keysForDay = _savedFields.entries
        .where((e) => e.key.startsWith('w${week}_d${day}_') && e.value == true)
        .map((e) => e.key)
        .toList();

    await prefs.setStringList('savedFields_w${week}_d${day}', keysForDay);
  }

  Future<void> _loadPersistedSavedFields() async {
    final prefs = await SharedPreferences.getInstance();
    final allKeys = prefs.getKeys().where((k) => k.startsWith('savedFields_'));

    for (final key in allKeys) {
      final fieldKeys = prefs.getStringList(key) ?? [];
      for (final fk in fieldKeys) {
        _savedFields[fk] = true;
      }
    }
  }

  Future<void> saveDayToFirestore(int weekIndex, int dayIndex) async {
    final uid = _cachedUid; // ✅ safe, cached in initState()

    print('🧠 [SAVE] Attempting save for w$weekIndex d$dayIndex | currentUid: $uid');

    if (uid.isEmpty) {
      print('❌ [SAVE_ABORT] UID is empty — skipping save');
      return;
    }

    print('🧠 [SAVE_START] currentUid = $uid');
    print('📦 Saving to block: $_selectedBlockId');
    print('📅 Target = week_$weekIndex → day_$dayIndex');
    if (_selectedBlockId == null) {
      print('❌ saveDayToFirestore called with null _selectedBlockId');
      return;
    }
    // 🛡️ Guard against index errors
    if (weekIndex >= exerciseRows.length ||
        weekIndex >= circuitStartIndices.length) return;
    if (dayIndex >= exerciseRows[weekIndex].length ||
        dayIndex >= circuitStartIndices[weekIndex].length) return;

    final rows = exerciseRows[weekIndex][dayIndex];
    final exercises = <Map<String, dynamic>>[];

    for (final row in rows) {
      final name = (row.exercise ?? '').trim();
      if (name.isEmpty) continue;

      final String exId = PeriodizationModelUtils.nameToId[name] ?? name;
      final bool isBw   = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: name);

      final String wTxt  = row.weightController.text.trim();
      final String rTxt  = row.repsController.text.trim();
      final String rirTxt = row.rirController.text.trim();

      final double typed = double.tryParse(wTxt) ?? 0.0; // what user typed in the weight box
      final int reps     = int.tryParse(rTxt) ?? 0;
      final double rir   = double.tryParse(rirTxt) ?? 0.0;

      final bool hasWeightInput = wTxt.isNotEmpty;   // user typed something (even "0")
      final bool hasRepsInput   = rTxt.isNotEmpty;   // user typed something (even "0", which we won't save)
      final bool hasRirInput    = rirTxt.isNotEmpty; // user typed something (even "0")

      double saveWeight = typed;   // default (normal exercises)
      double? saveAdded;           // only set for BW

      if (isBw) {
        // For BW, treat any typed value (including 0.0) as intentional.
        if (hasWeightInput) {
          final date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
          final asOfDate = DateTime(date.year, date.month, date.day, 12);

          final double absolute = PeriodizationModelUtils.toAbsoluteWeight(
            uid: _cachedUid,
            displayAddedKg: typed, // ADDED (may be 0.0)
            exerciseId: exId,
            exerciseName: name,
            asOfDate: asOfDate,
          );
          saveWeight = absolute;   // ABSOLUTE = BW + ADDED
          saveAdded  = typed;      // keep ADDED exactly as typed (0.0 allowed)
        } else {
          // No user entry for BW → do not persist weight at all.
          saveAdded = null;
        }
      }

// Build the exercise map; include only intentional fields
      final exMap = <String, dynamic>{
        'name': name,
        // reps: save only if user entered > 0
        if (hasRepsInput && reps > 0) 'reps': reps,
        // rir: save even if 0.0; omit only when no input
        if (hasRirInput) 'rir': rir,
        'velocity': row.velocityController.text.trim(),
        'notes': row.notesController.text.trim(),
        'circuitIndex': row.circuitIndex,
      };

// Non-BW: store typed weight only if user typed AND > 0
      if (!isBw && hasWeightInput && typed > 0) {
        exMap['weight'] = saveWeight; // (== typed)
      }

// BW: store ABSOLUTE & ADDED when the user typed (including 0.0)
      if (isBw && hasWeightInput) {
        exMap['weight'] = saveWeight;         // ABSOLUTE (BW + added)
        exMap['addedWeight'] = saveAdded;     // ADDED (can be 0.0)
      }

      exercises.add(exMap);


    }


    print('📝 [SAVE] Week $weekIndex, Day $dayIndex → Saving ${exercises.length} exercises:');
    for (final ex in exercises) {
      print('  • ${ex['name']} | weight: ${ex['weight']} | reps: ${ex['reps']} | RIR: ${ex['rir']} | circuit: ${ex['circuitIndex']}');
    }

    final weekDocRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid) // ✅ use uid
        .collection('blocks')
        .doc(_selectedBlockId!)
        .collection('weeks')
        .doc('week_$weekIndex');

    print('💾 [SAVE_PATH] writing to: planned_blocks/$uid/blocks/$_selectedBlockId/weeks/week_$weekIndex/days/day_$dayIndex');
// Check if the week doc already exists
    final weekSnapshot = await weekDocRef.get();

    if (!weekSnapshot.exists) {
      // 🆕 First time writing → include metadata
      await weekDocRef.set({
        'exists': true,
        'startDate': Timestamp.fromDate(
            blockStartDate.add(Duration(days: weekIndex * 7))),
        'endDate': Timestamp.fromDate(
            blockStartDate.add(Duration(days: (weekIndex + 1) * 7 - 1))),
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } else {
      // 📝 Already exists → just update flag
      await weekDocRef.set({'exists': true}, SetOptions(merge: true));
    }


    final date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
    final workoutName = "${DateFormat('EEE d MMM').format(date)} - Week ${weekIndex + 1}";

    await weekDocRef.collection('days').doc('day_$dayIndex').set({
      'exercises': exercises,
      'circuitStartIndices': circuitStartIndices[weekIndex][dayIndex],
      'date': Timestamp.fromDate(date),
      'workoutName': workoutName,
    });

    // 🔥 [BB2 → Warm] Precompute WES snapshots for this day and tomorrow (non-blocking).
    try {
      final String blockId = _selectedBlockId!;
      if (blockId.isEmpty) {
        print('⚠️ [BB2 Warm] Skipping warm — blockId empty');
      } else {
        // Use the exact calendar date you just saved; normalize to LOCAL date-only
        final DateTime d0 = DateTime(date.year, date.month, date.day);
        final DateTime d1 = d0.add(const Duration(days: 1));

        // Selected athlete (NOT necessarily the logged-in user)
        final String uidSelected = _cachedUid;

        // Kick both warms; WarmupService.warmWES is already fire-and-forget
        WarmupService.instance.warmWES(
          uidSelected,
          activeBlockId: blockId,
          selectedDate: d0,
        );
        WarmupService.instance.warmWES(
          uidSelected,
          activeBlockId: blockId,
          selectedDate: d1,
        );

        print('✅ [BB2 Warm] Warm kicked for $d0 and $d1 (uid=$uidSelected, block=$blockId)');
      }
    } catch (e, st) {
      print('⚠️ [BB2 Warm] Warm kick failed: $e');
    }


    await saveDayToSharedPrefs(weekIndex, dayIndex); // 👈 Add this right after Firestore save

    _markSavedFields(weekIndex, dayIndex, rows);
    await _persistSavedFieldKeysForDay(weekIndex, dayIndex);

    if (!mounted) return;
    setState(() {});
    print("✅ Saved day: week $weekIndex, day $dayIndex");
  }

  Future<void> saveDayToSharedPrefs(int weekIndex, int dayIndex) async {
    final prefs = await SharedPreferences.getInstance();
    final rows = exerciseRows[weekIndex][dayIndex];
    final exercises = <Map<String, dynamic>>[];

    for (final row in rows) {
      final name = (row.exercise ?? '').trim();
      if (name.isEmpty) continue;

      exercises.add({
        'name': name,
        'weight': double.tryParse(row.weightController.text) ?? 0.0,
        'reps': int.tryParse(row.repsController.text) ?? 0,
        'rir': double.tryParse(row.rirController.text) ?? 0.0,
        'velocity': row.velocityController.text.trim(), // ✅ NEW
        'notes': row.notesController.text.trim(),       // ✅ NEW
        'circuitIndex': row.circuitIndex,
      });
    }

    final date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
    final dateKey = DateFormat('yyyy-MM-dd').format(date);

    final dayData = {
      'exercises': exercises,
      'circuitStartIndices': circuitStartIndices[weekIndex][dayIndex],
      'date': date.toIso8601String(),
    };

    await prefs.setString('bb2_dayData_$dateKey', jsonEncode(dayData));
  }

  void _trimEmptyExerciseRows(int weekIndex, int dayIndex) {
    if (weekIndex >= exerciseRows.length ||
        dayIndex >= exerciseRows[weekIndex].length) return;

    final rows = exerciseRows[weekIndex][dayIndex];

    // 🧹 Remove rows with no exercise name
    rows.removeWhere((row) => (row.exercise ?? '').trim().isEmpty);

    // 🧪 Safeguard: only access circuitStartIndices if they exist
    if (weekIndex < circuitStartIndices.length &&
        dayIndex < circuitStartIndices[weekIndex].length) {
      final totalRows = rows.length;
      final starts = circuitStartIndices[weekIndex][dayIndex];

      // 🧹 Remove invalid circuit start indices
      starts.removeWhere((start) => start >= totalRows);

      // ✅ Ensure first circuit starts at 0
      if (starts.isEmpty || starts.first != 0) {
        starts.insert(0, 0);
      }

      circuitStartIndices[weekIndex]
          [dayIndex] = starts.toSet().toList()..sort();
    }
  }

  Future<void> deleteAllBlockAndWorkoutData() async {
    final userContext = UserContext.of(context, listen: false);
    if (_selectedBlockId == null) return;
    final uid = userContext.currentUid;


    // 1️⃣ Delete all workouts
    final workoutsSnapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .get();
    for (final doc in workoutsSnapshot.docs) {
      await doc.reference.delete();
    }
    print("🗑️ All workouts deleted.");

    // 2️⃣ Delete all block‐planner data under planned_blocks/{uid}/blocks/{blockId}
    final blockWeekColl = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(_selectedBlockId)
        .collection('weeks');

    final weeksSnapshot = await blockWeekColl.get();
    for (final weekDoc in weeksSnapshot.docs) {
      final daysSnapshot = await weekDoc.reference.collection('days').get();
      for (final dayDoc in daysSnapshot.docs) {
        await dayDoc.reference.delete();
      }
      await weekDoc.reference.delete();
    }

    print("🧼 All block‐planner data deleted for block $_selectedBlockId.");
  }

  Future<void> deleteBlockBuilderDataOnly() async {
    final userContext = UserContext.of(context, listen: false);
    if (_selectedBlockId == null) return;
    final uid = userContext.currentUid;


    // Reference to weeks under the active block
    final weeksColl = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(_selectedBlockId)
        .collection('weeks');

    // Delete each day sub-doc, then each week doc
    final weeksSnapshot = await weeksColl.get();
    for (final weekDoc in weeksSnapshot.docs) {
      final daysSnapshot = await weekDoc.reference.collection('days').get();
      for (final dayDoc in daysSnapshot.docs) {
        await dayDoc.reference.delete();
      }
      await weekDoc.reference.delete();
    }

    print("🧼 BlockBuilder-only data deleted for block $_selectedBlockId.");
  }

  void clearDay(int weekIndex, int dayIndex) {
    final backup = List<ExerciseRow>.from(exerciseRows[weekIndex][dayIndex]);

    setState(() {
      // 🧹 Clear the entire list of rows
      exerciseRows[weekIndex][dayIndex].clear();
    });

    // 🛟 Allow Undo
    _lastUndoAction = () {
      setState(() {
        exerciseRows[weekIndex][dayIndex] = List<ExerciseRow>.from(backup);
      });
    };

    // ✅ Reset circuitStartIndices for that day
    circuitStartIndices[weekIndex][dayIndex] = [0];

    saveDayToFirestore(weekIndex, dayIndex);
  }

  int getExercisePlannedCountBefore(String exerciseName, int targetWeek, int targetDay, int targetRow) {
    int count = 0;

    for (int w = 0; w <= targetWeek; w++) {
      for (int d = 0; d < 7; d++) {
        if (w == targetWeek && d > targetDay) break;

        final rows = exerciseRows[w][d];
        final int lastRow = (w == targetWeek && d == targetDay) ? targetRow : rows.length;

        for (int r = 0; r < lastRow; r++) {
          final row = rows[r];
          if ((row.exercise ?? '').trim() == exerciseName) {
            count++;
          }
        }
      }
    }

    return count;
  }

  //Horizontal scroll to current week
  void scrollToCurrentWeek() {
    final today = DateTime.now();
    final daysSinceStart = today.difference(blockStartDate).inDays;
    final currentWeekIndex = (daysSinceStart / 7).floor().clamp(0, weekIndices.length - 1);

    final double weekCardWidth = MediaQuery.of(context).size.width * 0.85;
    final double targetScrollOffset = currentWeekIndex * weekCardWidth;

    _horizontalScrollController.animateTo(
      targetScrollOffset,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  void scrollToCurrentDay() {
    final today = DateTime.now();
    final daysSinceStart = today.difference(blockStartDate).inDays;
    final currentDayIndex = daysSinceStart.clamp(0, weekIndices.length * 7 - 1);

    const double dayCardHeight = 250; // Approx. height of each day card (adjust if needed)
    final double targetScrollOffset = currentDayIndex * dayCardHeight;

    _verticalScrollController.animateTo(
      targetScrollOffset,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  Future<void> showCollapsibleExercisePicker({
    required BuildContext context,
    required Map<String, List<String>> allGroupedExercises,
    required Map<String, String> exerciseIdToName, // id → name
    required void Function(String selectedExercise) onSelected,
  }) async {
    bool showPlannedOnly = true;
    String searchQuery = '';

    final plannedNames = plannedExerciseDetails.keys
        .where((id) => id != 'blockMeta')
        .map((id) => exerciseIdToName[id])
        .whereType<String>()
        .toSet();

    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setState) {
        final filtered = <String, List<String>>{};
        allGroupedExercises.forEach((cat, list) {
          final keep = (showPlannedOnly && plannedNames.isNotEmpty)
              ? list.where((name) => plannedNames.contains(name)).toList()
              : list;
          if (keep.isNotEmpty) filtered[cat] = keep;
        });

        final Map<String, List<String>> searched = {};
        filtered.forEach((cat, list) {
          final matches = list
              .where((name) =>
              name.toLowerCase().contains(searchQuery.toLowerCase()))
              .toList();
          if (matches.isNotEmpty) searched[cat] = matches;
        });

        final Map<String, bool> expandedGroups = {
          for (var cat in searched.keys) cat: false,
        };

        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
          contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Select Exercise',
                  style: TextStyle(fontSize: 13, color: Colors.white)),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    showPlannedOnly ? 'Planned Only' : 'All Exercises',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  Switch(
                    value: showPlannedOnly,
                    onChanged: (v) => setState(() => showPlannedOnly = v),
                    activeColor: Colors.lightBlueAccent,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search exercises...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: Colors.blueGrey.shade800,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8.0)),
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
                onChanged: (val) =>
                    setState(() => searchQuery = val.toLowerCase()),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: ListView(
              children: [
                ...searched.entries.map((e) {
                  final isExpanded = searchQuery.isNotEmpty || (expandedGroups[e.key] ?? false);
                  expandedGroups[e.key] = isExpanded; // Ensure it's tracked

                  return ExpansionTile(
                    initiallyExpanded: isExpanded,
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    collapsedBackgroundColor: Colors.blueGrey.shade800,
                    backgroundColor: Colors.blueGrey.shade700,
                    title: Text(
                      e.key,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    onExpansionChanged: (expanded) {
                      setState(() => expandedGroups[e.key] = expanded);
                    },
                    children: e.value.map((name) {
                      return ListTile(
                        title: Text(name, style: const TextStyle(color: Colors.white70)),
                        onTap: () {
                          Navigator.pop(context);
                          onSelected(name);
                        },
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                      );
                    }).toList(),
                  );
                }),
              ],
            ),


          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel', style: TextStyle(color: Colors.white70))),
          ],
        );
      }),
    );
  }



  Widget _buildExerciseRow(int weekIndex, int dayIndex, int rowIndex, Map<String, dynamic> repTargetsByExercise) {
    if (weekIndex >= exerciseRows.length ||
        dayIndex >= exerciseRows[weekIndex].length ||
        rowIndex >= exerciseRows[weekIndex][dayIndex].length) {
      return const SizedBox.shrink(); // ✅ Defensive: avoid RangeError
    }

    final row = exerciseRows[weekIndex][dayIndex][rowIndex];
    final weightController = row.weightController;
    final repsController = row.repsController;
    final rirController = row.rirController;
    final velocityController = row.velocityController;
    final notesController = row.notesController;
    final exerciseController = row.exerciseController;

    return StatefulBuilder(
      builder: (context, localSetState) {
        final exerciseName = exerciseController.text;
        print('🧠 Building row for exercise: "$exerciseName" (w$weekIndex d$dayIndex r$rowIndex)');

        final exerciseId = nameToIdMap[exerciseName];
        print('🔍 ID for $exerciseName: $exerciseId');



// 🧷 Use exerciseSettings (ES) ONLY to build valid options
        final incRawES = _exerciseSettings[exerciseId]?['increments']
            ?? _exerciseSettings[exerciseName]?['increments'];

        final incMapES = PeriodizationModelUtils.incMapFromRaw(incRawES);
        final optionsES = PeriodizationModelUtils.expandIncrementOptions(incMapES);

        print('🔎 ES inc (raw) for $exerciseName/$exerciseId → ${jsonEncode(incRawES)}');
        print('🧷 [BB2:chosen increments] $exerciseName → '
            'primary=${incMapES['primary'] ?? 2.5} '
            'secondary=${incMapES['secondary'] ?? 0.0} '
            'sample=${optionsES.take(10).toList()} … total=${optionsES.length}');

        final String incOrigin = _exerciseSettings[exerciseId]?['increments'] != null
            ? 'byId'
            : (_exerciseSettings[exerciseName]?['increments'] != null ? 'byName' : 'fallback');
        print('🧭 [INC ORIGIN] $exerciseName/$exerciseId → origin=$incOrigin');

        final String? plannedRep = getRepTargetForExercise(
          exerciseName,
          weekIndex,
          dayIndex,
          rowIndex,
        );

        print('🔢 plannedRep returned: $plannedRep');

        _trackWeightController(
          c: weightController,
          exerciseName: exerciseName,
          weekIndex: weekIndex,
          dayIndex: dayIndex,
          rowIndex: rowIndex,
        );
        debugPrint('🔎 attach tracker for "$exerciseName" w$weekIndex d$dayIndex r$rowIndex; current="${weightController.text}"');
        final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
        final asOf = _displayStart.add(Duration(days: weekIndex * 7 + dayIndex));
        final bwForDay = PeriodizationModelUtils.bodyweightKgForDate(uid: uid, asOf: asOf);
        debugPrint('⚖️ BW for plan date = ${bwForDay.toStringAsFixed(2)}');

        final double? weight = double.tryParse(weightController.text);
        final int? reps = int.tryParse(repsController.text);
        final double? rir = double.tryParse(rirController.text);


        final bool isExerciseNamed = exerciseName.isNotEmpty;
        final double repsValue = reps?.toDouble() ??
            (repsController.text.isEmpty
                ? double.tryParse(plannedRep?.split('x').first.trim() ?? '') ?? 10.0
                : double.tryParse(repsController.text) ?? 10.0);

        final Map<String, dynamic>? rirSetValues = getPlannedRirSetValues(
          exerciseName: exerciseName,
          week: weekIndex,
          day: dayIndex,
          row: rowIndex,
        );

        // 🧠 First define hintRir (safe to use afterward)
        final String hintRir = rirController.text.isNotEmpty
            ? rirController.text
            : rirSetValues?['set1']?['rir']?.toString() ?? '1';

// ✅ Then use it here
        final double rirValue = rirController.text.isNotEmpty
            ? double.tryParse(rirController.text) ?? 1
            : double.tryParse(hintRir) ?? 1;

        final actual = PeriodizationModelUtils.getActualRepsAndRir(
          repsController: repsController,
          rirController: rirController,
          plannedRep: plannedRep,
          plannedRir: hintRir,
        );
        final double actualReps = actual['reps']!;
        final double actualRir = actual['rir']!;

        // 🔍 Check for selected progression model (optional per-exercise)
        final String? progressionModelName = plannedExerciseDetails[exerciseId]?['progressionModel'];
        final ProgressionModelType progressionModel =
        PeriodizationModelUtils.parseProgressionModel(progressionModelName);

// 🧠 Calculate default E1RM-based suggested weight
        final int repTargetForBase = int.tryParse(plannedRep?.split('x').first.trim() ?? '')
            ?? repsValue.toInt();
        final double historyWeight = PeriodizationModelUtils.getSuggestedWeightFromRep(
          exerciseName,
          repTargetForBase,
          PeriodizationModelUtils.isBodyweightExercise(id: exerciseId, name: exerciseName)
              ? (double.tryParse(hintRir) ?? 1.0)   // BW: planned RIR
              : rirValue,                           // non-BW: existing RIR
        );

        print('🧱 [BB2 defaultWeight] = ${historyWeight.toStringAsFixed(2)} '
            '(for repTarget=$repTargetForBase, rir='
            '${PeriodizationModelUtils.isBodyweightExercise(id: exerciseId, name: exerciseName) ? (double.tryParse(hintRir) ?? 1.0) : rirValue})');

        final bool userTypedRir = rirController.text.isNotEmpty;
        final bool userTypedWeight = weightController.text.isNotEmpty;

        print('🧪 [BB2] Top set history used for base E1RM: ${topSetsByExercise[exerciseName]}');

// 🚀 Progression logic (only triggers if model is explicitly selected)
        final Map<String, dynamic> progressed = _getCachedProgressedValues(
          exerciseName: exerciseName,
          exerciseId: exerciseId,
          weekIndex: PeriodizationModelUtils.getWeekIndexForDate(
            _displayStart.add(Duration(days: weekIndex * 7 + dayIndex)),
            blockStartDate,
          ),
          dayIndex: dayIndex,
          rowIndex: rowIndex,
          repTarget: repTargetForBase,   // same seed as before
          defaultWeight: historyWeight,
          rir: PeriodizationModelUtils.isBodyweightExercise(id: exerciseId, name: exerciseName)
              ? (double.tryParse(hintRir) ?? 1.0)   // BW: planned RIR
              : rirValue,                           // non-BW: existing RIR
        );

        final double progressedWeightRaw = progressed['weight'];
        final int progressedRepsRaw = progressed['reps'];

        final double? cachedE1RM = progressed['e1rm']; // ← if your function returns this

        print('📦 [BB2] Cached progression E1RM for $exerciseName → ${cachedE1RM?.toStringAsFixed(2)}');

        print('🧠 Progression model "$progressionModelName" → using weight ${progressedWeightRaw.toStringAsFixed(1)} (base: $historyWeight)');

        double? effectiveReps;

// ✅ Use hintRir first to ensure effectiveRir is valid
        final double effectiveRir = rirController.text.isNotEmpty
            ? double.tryParse(rirController.text) ?? double.tryParse(hintRir) ?? 1
            : double.tryParse(hintRir) ?? 1;

        if (repsController.text.isNotEmpty) {
          print('[TRACE] Using manually entered reps');
          effectiveReps = double.tryParse(repsController.text);
        } else if (weightController.text.isNotEmpty && isExerciseNamed) {
          print('[TRACE] Trying reverse calculation because weight was typed but reps is empty');

          final double? baseWeight = progressedWeightRaw;
          final double? baseReps = progressedRepsRaw.toDouble();

          print('[DEBUG] Parsed baseWeight = $baseWeight, baseReps = $baseReps');

          if (baseWeight != null && baseReps != null) {
            final double baseE1RM = PeriodizationModelUtils.calculateE1RM(
              baseWeight,
              baseReps,
              rirValue,
            );

            // ⬇️ CHANGE THIS: treat typed weight as ADDED for BW → convert to ABSOLUTE
            final double newWeight = (() {
              final double? typed = double.tryParse(weightController.text);
              if (typed == null) return baseWeight;
              final bool isBwHere = PeriodizationModelUtils.isBodyweightExercise(
                id: exerciseId, name: exerciseName,
              );
              if (!isBwHere) return typed;
              return PeriodizationModelUtils.toAbsoluteWeight(
                uid: uid,
                displayAddedKg: typed,
                exerciseId: exerciseId,
                exerciseName: exerciseName,
                asOfDate: asOf,
              );
            })();

            effectiveReps = PeriodizationModelUtils.reverseCalculateReps(
              targetE1RM: baseE1RM,
              weight: newWeight,
              baseWeight: baseWeight,
              rir: effectiveRir,
              minReps: baseReps,
            );

            print('🔁 [BB2] Recalculated reps = ${effectiveReps.toStringAsFixed(1)} at new weight = $newWeight to preserve E1RM ≈ ${baseE1RM.toStringAsFixed(1)}');
          } else {
            print('[DEBUG] Could not parse baseWeight or baseReps — falling back');
            effectiveReps = progressedRepsRaw.toDouble();
          }
        } else {
          print('[TRACE] No weight entered or exercise unnamed — using fallback');
          effectiveReps = progressedRepsRaw.toDouble();
        }

        double? effectiveWeight;

        if (userTypedWeight) {
          effectiveWeight = double.tryParse(weightController.text);
          print('🧠 [BB2] Original progressed weight for $exerciseName = ${progressedWeightRaw.toStringAsFixed(1)} '
              'at ${progressedRepsRaw} reps, RIR $rirValue');

        } else if ((userTypedRir || repsController.text.isNotEmpty) && effectiveReps != null) {
          print('🔁 [BB2] Triggered weight recalculation due to ${userTypedRir ? "RIR" : ""}'
              '${(userTypedRir && repsController.text.isNotEmpty) ? " + " : ""}'
              '${repsController.text.isNotEmpty ? "reps" : ""}');

          // 🧠 Recalculate weight to preserve E1RM with new RIR at same reps
          final double? baseE1RM = progressed['e1rm']; // ✅ cached base E1RM

          // Parity debug (optional; keep if helpful)
          final double _e1rm_progressed_local = PeriodizationModelUtils.calculateE1RM(
            progressedWeightRaw,
            progressedRepsRaw.toDouble(),
            effectiveRir,
          );
          print('🎯 [BB2 BW parity] targetE1RM_used=${(baseE1RM ?? -1).toStringAsFixed(2)} '
              '| e1rm_progressed_now=${_e1rm_progressed_local.toStringAsFixed(2)} '
              '(from ${progressedWeightRaw.toStringAsFixed(2)} × ${progressedRepsRaw} @ RIR ${effectiveRir})');

          if (baseE1RM == null) {
            print('❌ [BB2] No cached baseE1RM found — falling back to original weight');
            effectiveWeight = progressedWeightRaw;
          } else {
            // 📐 BW-only parity; non-BW stays exactly the same as before
            final bool _isBwHere_forSnap =
            PeriodizationModelUtils.isBodyweightExercise(id: exerciseId, name: exerciseName);
            final bool _rirOnlyBw = _isBwHere_forSnap && userTypedRir && !repsController.text.isNotEmpty;

            // For BW:
            //  - if RIR-only change → preserve BASE (planned-RIR) E1RM
            //  - otherwise use progressed-now
            // For non-BW:
            //  - always preserve BASE E1RM (original behavior)
            final double _targetE1RM = _isBwHere_forSnap
                ? (_rirOnlyBw
                ? baseE1RM
                : PeriodizationModelUtils.calculateE1RM(
              progressedWeightRaw,
              progressedRepsRaw.toDouble(),
              effectiveRir,
            ))
                : (baseE1RM // ← non-BW unchanged
            );

            print('🎯 [TargetE1RM chosen] '
                '${_isBwHere_forSnap ? (_rirOnlyBw ? "BASE_BW" : "PROG_NOW_BW") : "NON_BW_BASE"} '
                'target=${_targetE1RM.toStringAsFixed(2)}');

            // 🔁 Recompute trial weight using the chosen target
            double trialWeight = PeriodizationModelUtils.reverseCalculateWeight(
              targetE1RM: _targetE1RM,
              reps: effectiveReps.toInt(),
              rir: effectiveRir,
            );



// 🎯 Snap: BW → snap in ADDED domain; non-BW → snap in ABS (existing behavior)
            if (_isBwHere_forSnap) {
              final double _bwUsed = PeriodizationModelUtils.bodyweightKgForDate(
                uid: uid,
                asOf: asOf,
              );
              final double _preSnapAbs   = trialWeight;
              final double _preSnapAdded = _preSnapAbs - _bwUsed;
              print('🧍 [BB2 BW] bwUsed=${_bwUsed.toStringAsFixed(2)}');
              print('📐 [BB2 BW] preSnapAbs=${_preSnapAbs.toStringAsFixed(2)} → preSnapAdded=${_preSnapAdded.toStringAsFixed(2)}');

              // Snap on ADDED using ES options (same grid WES uses)
              double snappedAdded = optionsES.isNotEmpty
                  ? optionsES.reduce((a, b) =>
              (a - _preSnapAdded).abs() < (b - _preSnapAdded).abs() ? a : b)
                  : _preSnapAdded;
              if (snappedAdded < 0) snappedAdded = 0.0; // no negative added

              final double snappedAbs = _bwUsed + snappedAdded;
              print('📏 [BB2 BW] snappingDomain=ADDED | ES options sample=${optionsES.take(10).toList()}');
              print('🧲 [BB2 BW parity] trialAbs=${_preSnapAbs.toStringAsFixed(2)} '
                  '→ trialAdded=${_preSnapAdded.toStringAsFixed(2)} '
                  '→ snappedAdded=${snappedAdded.toStringAsFixed(2)} '
                  '→ snappedAbs=${snappedAbs.toStringAsFixed(2)}');

              trialWeight = snappedAbs;
            } else {
              // Non-BW: keep existing ABS snap logic
              if (optionsES.isNotEmpty) {
                final t = trialWeight;
                trialWeight = optionsES.reduce(
                      (a, b) => (a - t).abs() < (b - t).abs() ? a : b,
                );
                print('🧲 [BB2 snap ES] $t → $trialWeight');
              } else {
                final snapped = PeriodizationModelUtils.roundToNearestValidIncrement(
                  targetWeight: trialWeight,
                  exerciseName: exerciseName,
                );
                print('🧲 [BB2 snap fallback] $trialWeight → $snapped (PMU)');
                trialWeight = snapped;
              }
              print('📏 [BB2] snappingDomain=ABS | ES options sample=${optionsES.take(10).toList()}');
            }

// 🧠 Recalculate E1RM using snapped weight
            final double actualE1RM = PeriodizationModelUtils.calculateE1RM(
              trialWeight,
              effectiveReps.toDouble(),
              effectiveRir,
            );

// Use the chosen (parity) target for range checks and prints
            final double minE1RM = _targetE1RM * 0.85;
            final double maxE1RM = _targetE1RM * 1.02;

            const double epsilon = 0.01;
            if ((actualE1RM < minE1RM - epsilon) || (actualE1RM > maxE1RM + epsilon)) {
              print('⚠️ [BB2] Adjusted weight = ${trialWeight.toStringAsFixed(1)} '
                  'would cause E1RM = ${actualE1RM.toStringAsFixed(1)} '
                  '(outside range ${minE1RM.toStringAsFixed(1)}–${maxE1RM.toStringAsFixed(1)}) '
                  '→ falling back to cache weight = ${progressedWeightRaw.toStringAsFixed(1)}');
              effectiveWeight = progressedWeightRaw;
            } else {
              effectiveWeight = trialWeight;

              print('🎯 [BB2] Updated weight for $exerciseName = ${trialWeight.toStringAsFixed(1)} '
                  '(to preserve E1RM ${_targetE1RM.toStringAsFixed(2)} '
                  'using reps = ${effectiveReps?.toStringAsFixed(1)}, RIR = $effectiveRir)');
              print('✅ [BB2] Accepted adjusted weight = ${trialWeight.toStringAsFixed(1)} '
                  'for E1RM = ${actualE1RM.toStringAsFixed(1)} '
                  '(base = ${_targetE1RM.toStringAsFixed(1)})');
            }

            print('📏 [BB2] Comparing actual E1RM = ${actualE1RM.toStringAsFixed(4)} with range ${minE1RM.toStringAsFixed(4)} – ${maxE1RM.toStringAsFixed(4)}');

          }

        } else {
          // 🧠 Default fallback: snap PMU result to ES options
          final base = progressedWeightRaw;
          final snapped = optionsES.isNotEmpty
              ? optionsES.reduce((a, b) => (a - base).abs() < (b - base).abs() ? a : b)
              : base;

          if (snapped != base) {
            print('🧲 [BB2 default snap ES] ${base.toStringAsFixed(1)} → ${snapped.toStringAsFixed(1)}');
          }
          effectiveWeight = weight ?? snapped;
        }

        // 🔒 Always use ABSOLUTE for math; treat typed BW weight as ADDED
        final bool isBwEx = PeriodizationModelUtils.isBodyweightExercise(
          id: exerciseId, name: exerciseName,
        );

        double absForCalc = effectiveWeight ?? progressedWeightRaw;
        if (isBwEx) {
          if (userTypedWeight && weightController.text.isNotEmpty) {
            final double addedTyped = double.tryParse(weightController.text) ?? 0.0;
            absForCalc = PeriodizationModelUtils.toAbsoluteWeight(
              uid: uid,
              displayAddedKg: addedTyped,
              exerciseId: exerciseId,
              exerciseName: exerciseName,
              asOfDate: asOf,
            );
          } else {
            // progressedWeightRaw/effectiveWeight already absolute suggestions
            absForCalc = effectiveWeight ?? progressedWeightRaw;
          }
        }

// ✅ Now that effectiveReps is defined, compute hintReps from it
        final int roundedReps = effectiveReps != null
            ? (effectiveReps % 1 >= 0.85
            ? effectiveReps.ceil()
            : effectiveReps.floor())
            : progressedRepsRaw;

        final String hintReps = (repsController.text.isEmpty && isExerciseNamed)
            ? (() {
          print("🔍 [BB2 Rep Hint] Using hint from blockId: $_selectedBlockId");
          print("📅 [BB2 Rep Hint] Block dates available? start = $blockStartDate, end = $blockEndDate");
          return roundedReps.toString();
        })()
            : repsController.text;

        final String hintWeight = (weightController.text.isEmpty && isExerciseNamed)
            ? (() {
          // absForCalc is always absolute here
          if (isBwEx) {
            final added = PeriodizationModelUtils.toDisplayAddedWeight(
              uid: uid,
              absoluteKg: absForCalc,
              exerciseId: exerciseId,
              exerciseName: exerciseName,
              asOfDate: asOf,
            );
            return added.toStringAsFixed(1);
          } else {
            return absForCalc.toStringAsFixed(1);
          }
        })()
            : '';

// ⬇️ add this just before _buildFieldBox(weightController, ...)
        final bool _isBwRow = PeriodizationModelUtils.isBodyweightExercise(id: exerciseId, name: exerciseName);
        print('🧩 [BW HintCheck] isBw=$_isBwRow repsTyped=${repsController.text.isNotEmpty} '
            'rirTyped=${rirController.text.isNotEmpty} hintWeight=$hintWeight');


        print('[TRACE] Checking effectiveReps: reps="${repsController.text}", weight="${weightController.text}", hintWeight="$hintWeight", hintReps="$hintReps"');
        print('📋 repsController: "${repsController.text}", plannedRep: "$plannedRep", hintReps: "$hintReps"');


        final double? e1rm = PeriodizationModelUtils.calculateE1RM(
          absForCalc,
          effectiveReps,
          effectiveRir,
        );

// BW-only: compute display E1RM = (absolute E1RM − BW); normal keeps original 'e1rm'
        final bool _isBwEx = PeriodizationModelUtils.isBodyweightExercise(
          id: exerciseId, name: exerciseName,
        );
        final double? e1rmUi = !_isBwEx
            ? e1rm
            : (e1rm == null
            ? null
            : PeriodizationModelUtils.e1rmForDisplay(
          uid: uid,
          absoluteKg: absForCalc,
          reps: (effectiveReps ?? progressedRepsRaw).round(),
          rir: effectiveRir,
          exerciseId: exerciseId,
          exerciseName: exerciseName,
          asOfDate: asOf,
        ));


// Print: normal exercises print 'e1rm' exactly as before; BW prints the display-only number
        print('🧠 [BB2] Final E1RM used for $exerciseName = ${(_isBwEx ? e1rmUi : e1rm)?.toStringAsFixed(2)} '
            '(weight = ${effectiveWeight?.toStringAsFixed(1) ?? "null"}, '
            'reps = ${effectiveReps?.toStringAsFixed(1) ?? "null"}, '
            'RIR = ${effectiveRir?.toStringAsFixed(1) ?? "null"})');



        print("🧠 [BB2 UI] Calculating E1RM from weight=$effectiveWeight, reps=$effectiveReps, rir=$effectiveRir → E1RM=$e1rm");


        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 🟦 Fixed Exercise field
            SizedBox(
              width: 134,
              child: ReorderableDelayedDragStartListener(
                index: rowIndex,
                child: GestureDetector(
                  onTap: () async {
                    await showCollapsibleExercisePicker(
                      context: context,
                      allGroupedExercises: groupedExercises,
                      exerciseIdToName: _exerciseIdToName,
                      onSelected: (selectedExerciseName) {
                        final exerciseId = nameToIdMap[selectedExerciseName];
                        final isPlanned = exerciseId != null && plannedExercises.contains(exerciseId);

                        setState(() {
                          row.exercise = selectedExerciseName;
                          row.exerciseController.text = selectedExerciseName;
                          row.weightController.clear();
                          row.repsController.clear();
                          row.rirController.clear();

                          if (isPlanned) {
                            // ✅ Normalize repTargets if flat
                            if (repTargetsByExercise?[exerciseId]?['repTargets'] is List) {
                              final reps = repTargetsByExercise?[exerciseId]?['repTargets'];
                              if (reps.isNotEmpty && reps.first is String) {
                                repTargetsByExercise?[exerciseId]?['repTargets'] = [List<String>.from(reps)];
                                print('🔄 [BB2] Normalized flat repTargets → nested for $exerciseId');
                              }
                            }

                            final repTarget = PeriodizationModelUtils.getSuggestedRepTargetByModel(
                              exerciseName: exerciseId!,
                              plannedIndex: getExerciseCountInWeek(
                                selectedExerciseName,
                                weekIndex,
                                dayIndex,
                                rowIndex,
                              ),
                              weekIndex: weekIndex,
                              repTargetsByExercise: repTargetsByExercise,
                              plannedExerciseDetails: plannedExerciseDetails,
                            );

                            // 🧠 You could use this value if needed — but right now, we just clear reps field.
                            print('🎯 [BB2] Suggested rep target for $selectedExerciseName = $repTarget');
                          }

                          // ✅ Always inject planned RIR if available
                          final hintRir = (() {
                            final planned = getPlannedRirSetValues(
                              exerciseName: selectedExerciseName,
                              week: weekIndex,
                              day: dayIndex,
                              row: rowIndex,
                            );
                            return planned?['set1']?['rir']?.toString() ?? '0.5';
                          })();

                          row.rirController.text = '';

                        });
                      },
                    );
                  },


                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 1),
                    decoration: BoxDecoration(
                      color: getRowColor(weekIndex, dayIndex, rowIndex),
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(4.0),
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        row.exercise ?? 'Select Exercise',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // 🟥 Scrollable fields
            Expanded(
            child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            controller: _fieldScrollController, // 👈 same controller used for all rows
            child: Row(
            children: [
              SizedBox(width: 3),
            _buildFieldBox(weightController, hintWeight, weekIndex, dayIndex, rowIndex, "weight", localSetState),

              SizedBox(width: 1),
              // Reps
              _buildFieldBox(repsController, hintReps, weekIndex, dayIndex, rowIndex, "reps", localSetState),
              SizedBox(width: 3),
              // RIR
              _buildFieldBox(rirController, hintRir, weekIndex, dayIndex, rowIndex, "rir", localSetState),


              // E1RM
              SizedBox(
                width: 48,
                child: Text(
                      () {
                    if (e1rm != null && e1rm > 0) {
                      final bool isBwEx = PeriodizationModelUtils.isBodyweightExercise(
                        id: exerciseId, name: exerciseName,
                      );
                      if (isBwEx) {
                        final double? e1rmUi = PeriodizationModelUtils.e1rmForDisplay(
                          uid: _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '',
                          absoluteKg: effectiveWeight ?? progressedWeightRaw,
                          reps: (effectiveReps ?? progressedRepsRaw).round(),
                          rir: effectiveRir,
                          exerciseId: exerciseId,
                          exerciseName: exerciseName,
                        );
                        return e1rmUi?.toStringAsFixed(1) ?? '';
                      } else {
                        return e1rm.toStringAsFixed(1);
                      }
                    }
                    return '';
                  }(),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),

              ),

              // Notes
              SizedBox(
                width: 100,
                child: TextField(
                  controller: notesController,
                  decoration: const InputDecoration(
                    hintText: 'Notes',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    border: InputBorder.none,
                    hintStyle: TextStyle(
                      color: Colors.grey, // 👈 greyed out hint
                      fontSize: 12,
                    ),
                  ),
                  style: const TextStyle(fontSize: 12),
                  keyboardType: TextInputType.text,
                ),
              )

            ],
              ),
                ),
            ),
          ],
        );
      },
    );
  }

  Color _getFieldColor(String state) {
    switch (state) {
      case 'hint':
        return Colors.white;
      case 'user':
        return Color(0xFFF8BBD0);
      default:
        return Colors.black;
    }
  }

  Widget _buildFieldBox(
      TextEditingController controller,
      String? hint,
      int week,
      int day,
      int row,
      String fieldKey,
      void Function(void Function()) localSetState,
      ) {
    final String key = 'w${week}_d${day}_r${row}_$fieldKey';
    final String value = controller.text.trim();

    final bool wasManuallyEntered = value.isNotEmpty;
    final String state = wasManuallyEntered ? 'user' : 'hint';
    final color = _getFieldColor(state);

    print('📝 hint="$hint" | controller="${controller.text}" for field: $fieldKey');

    // 🔧 Widths per field
    final fieldWidths = {
      "weight": 42.0,
      "reps": 34.0,
      "rir": 34.0,
      "velocity": 30.0,
      "notes": 100.0,
    };
    final width = fieldWidths[fieldKey] ?? 40.0;

    // keep your current print if you like, add this tiny one
    if (fieldKey == "weight") {
      final bool _controllerEmpty = controller.text.trim().isEmpty;
      final String? _appliedHint = _controllerEmpty ? hint : null;
      print('🎯 [Field weight] empty=$_controllerEmpty hintParam=$hint appliedHint=$_appliedHint');
    }

    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        focusNode: _getFocusNode(key),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.center,
        style: TextStyle(color: color, fontSize: 12),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          hintText: value.isEmpty ? hint : null,
          hintStyle: TextStyle(color: color.withOpacity(0.6)),
          border: InputBorder.none,
        ),
        onChanged: (_) {
          if (fieldKey == "rir") {
            print('⏩ [RIR onChanged] new="${controller.text}" → localSetState()');
          }
          localSetState(() {});
        },

        onEditingComplete: () => _getFocusNode(key).unfocus(),
      ),
    );
  }

  /// A compact card showing “Rest Day” on a date that isn’t in `_selectedDays`.
  Widget _buildRestDayRow(String dayAbbrev, DateTime date) {
    final label = DateFormat('EEE d MMM').format(date); // e.g. “Mon 17 Mar”
    return Container(
      height: exerciseRowHeight,
      margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade800,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '$dayAbbrev • $label',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            'Rest Day',
            style: TextStyle(
              color: Colors.white70,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeek(int weekIndex, Map<String, dynamic> repTargets) {
    final weekStart = _displayStart.add(Duration(days: weekIndex * 7));

    return SizedBox(
      width: MediaQuery.of(context).size.width * .999,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(7, (dow) {
          final date = weekStart.add(Duration(days: dow));
          final dowAbbrev = DateFormat('E').format(date).substring(0, 3);
          final rows = exerciseRows[weekIndex][dow];

          // 1) days completely outside the block window
          if (date.isBefore(blockStartDate) || date.isAfter(blockEndDate)) {
            return _buildOutsideDayRow(date);
          }

          // 2) check if **any** row has a real exercise name
          final hasNamedExercise =
          rows.any((r) => (r.exercise ?? '').trim().isNotEmpty);
          if (hasNamedExercise) {
            // this covers your moved workout, plus any “real” saved days
            return _buildDayView(weekIndex, dow, repTargets);
          }

          // 3) it’s inside the block but not one of your selected weekdays
          if (!_selectedDays.contains(dowAbbrev)) {
            return _buildRestDayRow(dowAbbrev, date);
          }

          // 4) it’s a training-day with no data yet → show the blank workout UI
          return _buildDayView(weekIndex, dow, repTargets);
        }),
      ),
    );
  }

  Widget _buildDayView(int weekIndex, int dayIndex, Map<String, dynamic> repTargetsByExercise) {

    final date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));

    final abbrev =
        DateFormat('E').format(date).substring(0, 3); // "Mon","Tue",…
    final dateKey = DateFormat('yyyy-MM-dd').format(date);

    // 2️⃣ If this weekday isn’t selected, show a Rest-Day stub:
    if (!_selectedDays.contains(abbrev)) {
      return _buildRestDayRow(abbrev, date);
    }

    if (!_selectedDays.contains(abbrev)) {
      return _buildRestDayRow(abbrev, date);
    }

// ✅ Lazy-load completed WES data for this specific day
    if (!completedWesRows.containsKey(dateKey)) {
      loadCompletedWorkoutsForDay(date);
    }

    final rawSaved = completedWesRows[dateKey] ?? [];

// 🔐 Ensure every exercise carries the workout date (for BW as-of lookups)
    final List<Map<String, dynamic>> rawWithDate = rawSaved.map((e) {
      final m = Map<String, dynamic>.from(e);
      if (m['date'] == null) {
        m['date'] = Timestamp.fromDate(date); // 👈 use the block’s day date
      }
      return m;
    }).toList();

    final Set<String> seen = {};
    final savedWesExercises = rawWithDate.where((e) {
      final key = '${e['name']?.toString().trim()}_${e['circuitIndex']}';
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();


    final dayLabel =
        DateFormat('E d MMM y').format(date); // e.g., "Mon 17 Mar 2025"

    return StatefulBuilder(
        builder: (context, localSetState) {
          final metaRaw = plannedExerciseDetails['blockMeta'];
          final meta = metaRaw is Map ? Map<String, dynamic>.from(metaRaw) : {};

          final blockStart = DateTime.tryParse(meta['blockStartDate'] ?? '');
          final blockEnd = DateTime.tryParse(meta['blockEndDate'] ?? '');
          final blockLength = PeriodizationModelUtils.getBlockLength(
            blockStartDate: blockStart,
            blockEndDate: blockEnd,
          );

          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 3),
            color: Colors.blueGrey.shade900,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 🟣 Day Header Row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Week + Date Label
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    "  Week ${weekIndex + 1} • $blockLength weeks",
                                    style: const TextStyle(
                                      fontSize: 11,
                                      height: 0.9,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),

                          const SizedBox(height: 0),
                      Row(
                        children: [
                          Text(
                           '  $dayLabel',
                            style: const TextStyle(
                              fontSize: 12,
                              height: 0.5,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),

                          const SizedBox(width: 6),

                          // ✅ Tick icon to indicate completed workout

                          const SizedBox(width: 2),

                          IconButton(
                            icon: const Icon(Icons.delete_sweep_outlined),
                            visualDensity: VisualDensity.compact,
                            iconSize: 16,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            color: Colors.white,
                            tooltip: "Clear this day",
                            onPressed: () {
                              showDialog(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text("Clear this day?"),
                                  content: const Text("This will remove all exercises from this day."),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx),
                                      child: const Text("Cancel"),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        Navigator.pop(ctx);
                                        clearDay(weekIndex, dayIndex);
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text("✅ Day cleared.")),
                                        );
                                      },
                                      child: const Text("Yes"),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),

                  // 🟡 Buttons
                  Row(
                    children: [
                      // Template
                      Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: TextButton(
                          onPressed: () async {
                            // Wait for templates to finish loading (safe guard)
                            await _initialLoad;

                            if (templates.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("⚠️ No templates found.")),
                              );
                              return;
                            }

                            final selectedTemplate = await showDialog<Template>(
                              context: context,
                              builder: (context) {
                                return AlertDialog(
                                  title: const Text('Select a Template'),
                                  content: SizedBox(
                                    width: double.maxFinite,
                                    height: 400,
                                    child: ListView.builder(
                                      itemCount: templates.length,
                                      itemBuilder: (context, index) {
                                        final template = templates[index];
                                        return ListTile(
                                          title: Text(template.name),
                                          onTap: () {
                                            Navigator.of(context).pop(template);
                                          },
                                        );
                                      },
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text("Cancel"),
                                    ),
                                  ],
                                );
                              },
                            );

                            if (selectedTemplate != null) {
                              setState(() {
                                selectedTemplateIds[weekIndex][dayIndex] = selectedTemplate.id;
                                _populateExercisesFromTemplate(weekIndex, dayIndex, selectedTemplate.id);
                                updateFutureDaysWithEditedDay(weekIndex, dayIndex); // ✅ Mirror into future weeks
                              });
                            }
                          },
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(0, 30),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            () {
                              if (weekIndex >= selectedTemplateIds.length ||
                                  dayIndex >=
                                      selectedTemplateIds[weekIndex].length) {
                                return "Template";
                              }

                              final id = selectedTemplateIds[weekIndex][dayIndex];
                              if (id == null || id.isEmpty) return "Choose Workout";

                              final match = templates.firstWhere(
                                    (t) => t.id == id,
                                orElse: () => Template(
                                  id: '',
                                  name: 'Template',
                                  day: '',
                                  exercises: [],
                                ),
                              );
                              return match.name;
                            }(),
                            style: const TextStyle(fontSize: 11, color: Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(height: 1, width: 14),

                      // 🟡 Workout Button – formatted like your sketch
                      Padding(
                        padding: const EdgeInsets.only(right: 0),
                          child: TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                              minimumSize: const Size(0, 30),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () {
                              // Compute the exact date for this BB2 cell (normalize to midnight)
                              final DateTime base = DateTime(
                                blockStartDate.year,
                                blockStartDate.month,
                                blockStartDate.day,
                              );
                              final DateTime workoutDate = base.add(
                                Duration(days: weekIndex * 7 + dayIndex),
                              );

                              // Open WES with only the date; WES initState will handle everything else
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => WorkoutPage(
                                    initialDate: workoutDate,
                                  ),
                                ),
                              );
                            },
                            child: const Text(
                              "Go to\nWorkout",
                              style: TextStyle(fontSize: 11),
                              textAlign: TextAlign.center,
                            ),
                          )

                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 3),

                  // 🟣 Table Header
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    controller: _fieldScrollController, // ✅ Use same controller!
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                      color: Colors.blueGrey.shade800,
                      child: Row(
                        children: const [
                          // Exercise
                          SizedBox(
                            width: 126,
                            child: Text("Exercise",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white)),
                          ),
                          SizedBox(width: 2),
                          // Weight
                          SizedBox(
                            width: 54,
                            child: Text("Weight",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white)),
                          ),

                          // Reps
                          SizedBox(
                            width: 30,
                            child: Text("Reps",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white)),
                          ),
                          SizedBox(width: 3),
                          // RIR
                          SizedBox(
                            width: 33,
                            child: Text("RIR",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white)),
                          ),
                          SizedBox(width: 2),
                          // E1RM
                          SizedBox(
                            width: 42,
                            child: Text("E1RM",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white)),
                          ),
                          SizedBox(width: 10),
                          // Notes
                          SizedBox(
                            width: 100,
                            child: Text("Notes",
                                textAlign: TextAlign.left,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white)),
                          ),
                        ],
                      ),
                    ),
                  ),


                  // 🟣 Scrollable Exercise Table (~6.5 visible rows)
              const SizedBox(height: 6),
                  SizedBox(
                    height: 395,
                    child: Column(
                      children: [
                        // ✅ Always show read-only WES-saved exercises
                        AnimatedSize(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          child: SizedBox(
                            height: getTotalWesHeight(savedWesExercises),
                            // ✅ now dynamic based on expanded sets
                            child: Scrollbar(
                              child: SingleChildScrollView(
                                child: Column(
                                  children: savedWesExercises.map((exercise) {
                                final sets = List<Map<String, dynamic>>.from(exercise['sets'] ?? []);
                                if (sets.isEmpty) return const SizedBox.shrink();

                                final topSet = sets.reduce((a, b) {
                                  final e1 = PeriodizationModelUtils.calculateE1RM(
                                    (a['weight'] ?? 0).toDouble(),
                                    (a['reps'] ?? 0).toDouble(),
                                    (a['rir'] ?? 0).toDouble(),
                                  );
                                  final e2 = PeriodizationModelUtils.calculateE1RM(
                                    (b['weight'] ?? 0).toDouble(),
                                    (b['reps'] ?? 0).toDouble(),
                                    (b['rir'] ?? 0).toDouble(),
                                  );
                                  return e1 >= e2 ? a : b;
                                });

                                final DateTime? workoutDate = (exercise['date'] is Timestamp)
                                    ? (exercise['date'] as Timestamp).toDate()
                                    : null;

                                final allSets = List<Map<String, dynamic>>.from(sets);

                                print('🕒 [BB2 SavedEx] name=${exercise['name']} '
                                    'dateRaw=${exercise['date']} '
                                    '→ workoutDate=$workoutDate');

                                final name = exercise['name'] ?? 'Unnamed';
                                final weight = (topSet['weight'] ?? 0).toDouble();
                                final reps = (topSet['reps'] ?? 0).toDouble();
                                final rir = (topSet['rir'] ?? 0).toDouble();
                                final e1rm = PeriodizationModelUtils.calculateE1RM(weight, reps, rir);

                                final GlobalKey cardKey = GlobalKey();
                                final GlobalKey contentKey = GlobalKey();

                                return Container(
                                  key: cardKey,
                                  padding: const EdgeInsets.symmetric(horizontal:2, vertical: 0),
                                  decoration: BoxDecoration(
                                    color: Colors.blueGrey[200]!.withOpacity(0.15),
                                    border: Border(bottom: BorderSide(color: Colors.blueGrey[500]!, width: 0.5)),
                                  ),
                                  child: Theme(
                                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                                    child: Theme(
                                      data: Theme.of(context).copyWith(
                                        dividerColor: Colors.transparent,
                                        listTileTheme: const ListTileThemeData(
                                          dense: true,
                                          minVerticalPadding: 0,
                                          horizontalTitleGap: 0,
                                          contentPadding: EdgeInsets.zero,
                                        ),
                                      ),
                                      child: ExpansionTile(
                                        tilePadding: EdgeInsets.zero,
                                        collapsedIconColor: Colors.grey.shade400,
                                        iconColor: Colors.lightBlueAccent,
                                        trailing: const SizedBox.shrink(),
                                        childrenPadding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
                                        initiallyExpanded: wesExpansionStates[name] ?? false, // ✅ restore expansion state
                                        onExpansionChanged: (isExpanded) {
                                          setState(() {
                                            wesExpansionStates[name] = isExpanded; // ✅ track per exercise
                                          });
                                        },
                                          title: Row(
                                            crossAxisAlignment: CrossAxisAlignment.center,
                                            children: [
                                              // Name
                                              SizedBox(
                                                width: 125,
                                                child: Container(
                                                  alignment: Alignment.centerLeft,
                                                  padding: const EdgeInsets.symmetric(horizontal: 3),
                                                  child: Text(
                                                    name,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.w600,
                                                      fontStyle: FontStyle.italic,
                                                    ),
                                                  ),
                                                ),
                                              ),

                                              // Weight
                                              SizedBox(
                                                width: 60,
                                                child: Container(
                                                  alignment: Alignment.center,
                                                  child: Text(
                                                        () {
                                                      final bool isBwEx = PeriodizationModelUtils.isBodyweightExercise(
                                                        id: exercise['exerciseId'] ?? '',
                                                        name: name,
                                                      );
                                                      if (isBwEx) {
                                                        final num? awRaw = topSet['addedWeight'] as num?;
                                                        return (awRaw != null) ? awRaw.toStringAsFixed(1) : '';
                                                      }

                                                      return weight.toStringAsFixed(1);
                                                    }(),
                                                    textAlign: TextAlign.center,
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      color: Colors.white,
                                                      fontStyle: FontStyle.italic,
                                                    ),
                                                  ),

                                                ),
                                              ),

                                              const SizedBox(width: 1),

                                              // Reps
                                              SizedBox(
                                                width: 25,
                                                child: Text(
                                                  reps.toStringAsFixed(0),
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.white,
                                                    fontStyle: FontStyle.italic,
                                                  ),
                                                ),
                                              ),

                                              const SizedBox(width: 8),

                                              // RIR
                                              SizedBox(
                                                width: 30,
                                                child: Text(
                                                  rir.toStringAsFixed(1),
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.white,
                                                    fontStyle: FontStyle.italic,
                                                  ),
                                                ),
                                              ),

                                              const SizedBox(width: 2),

                                              // E1RM
                                              SizedBox(
                                                width: 38,
                                                child: Align(
                                                  alignment: Alignment.centerRight,
                                                  child: Text(
                                                        () {
                                                      final bool isBwEx = PeriodizationModelUtils.isBodyweightExercise(
                                                        id: exercise['exerciseId'] ?? '',
                                                        name: name,
                                                      );
                                                      if (isBwEx) {
                                                        final e1rmUi = PeriodizationModelUtils.e1rmForDisplay(
                                                          uid: _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '',
                                                          absoluteKg: weight,
                                                          reps: reps.round(),
                                                          rir: rir,
                                                          exerciseId: exercise['exerciseId'] ?? '',
                                                          exerciseName: name,
                                                          asOfDate: workoutDate, // 👈 NEW
                                                        );
                                                        return ' ${e1rmUi?.toStringAsFixed(1) ?? ''}';

                                                      }
                                                      return ' ${e1rm.toStringAsFixed(1)}';
                                                    }(),
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      color: Colors.white70,
                                                      fontStyle: FontStyle.italic,
                                                    ),
                                                  ),

                                                ),
                                              ),
                                            ],
                                          ),

                                          children: [
                                        // 🟦 Header Row
                                        Container(
                                        height: 28,
                                        padding: const EdgeInsets.symmetric(horizontal: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.blueGrey[300]!.withOpacity(0.25),
                                          border: Border(bottom: BorderSide(color: Colors.blueGrey[500]!, width: 0.5)),
                                        ),
                                          child: Row(
                                            crossAxisAlignment: CrossAxisAlignment.center,
                                            children: const [
                                              // Set #
                                              SizedBox(
                                                width: 30,
                                                child: Padding(
                                                  padding: EdgeInsets.symmetric(horizontal: 6),
                                                  child: Text(
                                                    'Set',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.bold,
                                                      color: Colors.white,
                                                      fontStyle: FontStyle.italic,
                                                    ),
                                                  ),
                                                ),
                                              ),

                                              // Weight
                                              SizedBox(
                                                width: 60,
                                                child: Text(
                                                  'Weight',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                                                ),
                                              ),

                                              // Reps
                                              SizedBox(
                                                width: 40,
                                                child: Text(
                                                  'Reps',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                                                ),
                                              ),
                                              const SizedBox(width: 2),
                                              // RIR
                                              SizedBox(
                                                width: 40,
                                                child: Text(
                                                  'RIR',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                                                ),
                                              ),
                                              SizedBox(width: 8),
                                              // E1RM
                                              SizedBox(
                                                width: 40,
                                                child: Text(
                                                  'E1RM',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70),
                                                ),
                                              ),
                                              SizedBox(width: 13),
                                              // 🟩 Velocity
                                              SizedBox(
                                                width: 22,
                                                child: Text(
                                                  'Vel',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70),
                                                ),
                                              ),
                                              SizedBox(width: 6),
                                              // 🟪 Notes
                                              SizedBox(
                                                width: 50,
                                                child: Text(
                                                  'Notes',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70),
                                                ),
                                              ),
                                            ],
                                          ),

                                        ),
                                      ...allSets.asMap().entries.map((entry) {
                                          final i = entry.key;
                                          final set = entry.value;

                                          final setWeight = (set['weight'] ?? 0).toDouble();
                                          final setReps = (set['reps'] ?? 0).toDouble();
                                          final setRir = (set['rir'] ?? 0).toDouble();

                                          final setE1RM = PeriodizationModelUtils.calculateE1RM(setWeight, setReps, setRir);

                                          return Container(
                                            height: 28,
                                            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
                                            decoration: BoxDecoration(
                                              color: Colors.blueGrey[200]!.withOpacity(0.10),
                                              border: Border(bottom: BorderSide(color: Colors.blueGrey[500]!, width: 0.25)),
                                            ),
                                            child: Row(
                                              crossAxisAlignment: CrossAxisAlignment.center,
                                              children: [
                                                // Set #
                                                SizedBox(
                                                  width: 30,
                                                  child: Padding(
                                                    padding: const EdgeInsets.symmetric(horizontal: 6),
                                                    child: Text(
                                                      '${i + 1}',
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.w600,
                                                        fontStyle: FontStyle.italic,
                                                      ),
                                                    ),
                                                  ),
                                                ),

                                                // Weight
                                                SizedBox(
                                                  width: 60,
                                                  child: Text(
                                                        () {
                                                      final bool isBwEx = PeriodizationModelUtils.isBodyweightExercise(
                                                        id: exercise['exerciseId'] ?? '',
                                                        name: name,
                                                      );
                                                      if (isBwEx) {
                                                        final num? awRaw = set['addedWeight'] as num?;
                                                        return (awRaw != null) ? awRaw.toStringAsFixed(1) : '';
                                                      }

                                                      return setWeight.toStringAsFixed(1);
                                                    }(),
                                                    textAlign: TextAlign.center,
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      color: Colors.white,
                                                      fontStyle: FontStyle.italic,
                                                    ),
                                                  ),

                                                ),

                                                // Reps
                                                SizedBox(
                                                  width: 40,
                                                  child: Text(
                                                    setReps.toStringAsFixed(0),
                                                    textAlign: TextAlign.center,
                                                    style: const TextStyle(fontSize: 12, color: Colors.white, fontStyle: FontStyle.italic),
                                                  ),
                                                ),
                                                const SizedBox(width: 2),
                                                // RIR
                                                SizedBox(
                                                  width: 40,
                                                  child: Text(
                                                    setRir.toStringAsFixed(1),
                                                    textAlign: TextAlign.center,
                                                    style: const TextStyle(fontSize: 12, color: Colors.white, fontStyle: FontStyle.italic),
                                                  ),
                                                ),

                                                // Spacer before E1RM
                                                const SizedBox(width: 8),

                                                // E1RM
                                                SizedBox(
                                                  width: 40,
                                                  child: Text(
                                                        () {
                                                      final bool isBwEx = PeriodizationModelUtils.isBodyweightExercise(
                                                        id: exercise['exerciseId'] ?? '',
                                                        name: name,
                                                      );
                                                      if (isBwEx) {
                                                        final e1rmUi = PeriodizationModelUtils.e1rmForDisplay(
                                                          uid: _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '',
                                                          absoluteKg: setWeight,
                                                          reps: setReps.round(),
                                                          rir: setRir,
                                                          exerciseId: exercise['exerciseId'] ?? '',
                                                          exerciseName: name,
                                                          asOfDate: workoutDate, // 👈 NEW
                                                        );
                                                        return e1rmUi?.toStringAsFixed(1) ?? '';

                                                      }
                                                      return setE1RM.toStringAsFixed(1);
                                                    }(),
                                                    textAlign: TextAlign.center,
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      color: Colors.white70,
                                                      fontStyle: FontStyle.italic,
                                                    ),
                                                  ),

                                                ),

                                                // Spacer before Velocity
                                                const SizedBox(width: 10),

                                                // Velocity
                                                SizedBox(
                                                  width: 28,
                                                  child: Text(
                                                    (set['velocity'] ?? '').toString(),
                                                    textAlign: TextAlign.center,
                                                    style: const TextStyle(fontSize: 12, color: Colors.white70, fontStyle: FontStyle.italic),
                                                  ),
                                                ),

                                                // Spacer before Notes
                                                const SizedBox(width: 11),

                                                // Notes (scrollable only if overflow)
                                                SizedBox(
                                                  width: 50,
                                                  child: SingleChildScrollView(
                                                    scrollDirection: Axis.horizontal,
                                                    child: Text(
                                                      (set['notes'] ?? '').toString(),
                                                      textAlign: TextAlign.left,
                                                      style: const TextStyle(
                                                        fontSize: 11,
                                                        color: Colors.white70,
                                                        fontStyle: FontStyle.italic,
                                                      ),
                                                    ),
                                                  ),
                                                ),

                                              ],
                                            ),


                                          );
                                        }).toList(),

                                      ]
                                      ),
                                    ),
                                  ),
                                );
                                    }).toList(),
                                  ),
                                ),
                              ),
                            ),
                        ),

                    const SizedBox(height: 0), // ⬅️ reduce vertical space here

                        // ✅ Show "Add First Exercise" button if day is empty
                        if (exerciseRows[weekIndex][dayIndex].isEmpty)
                          Transform.translate(
                            offset: const Offset(0, -2), // 👈 Raise the button up by 8 pixels
                            child: Padding(
                              padding: const EdgeInsets.only(left: 8.0), // 👈 Align to left instead of center
                              child: Align(
                                alignment: Alignment.centerLeft, // 👈 Pin it to the left side
                                child: TextButton.icon(
                                  onPressed: () {
                                    setState(() {
                                      _ensureCircuitStartIndicesInitialized(weekIndex, dayIndex);
                                      if (circuitStartIndices[weekIndex][dayIndex].isEmpty) {
                                        circuitStartIndices[weekIndex][dayIndex].add(0);
                                      }
                                      exerciseRows[weekIndex][dayIndex].add(
                                        ExerciseRow(circuitIndex: 0),
                                      );
                                    });
                                    updateFutureDaysWithEditedDay(weekIndex, dayIndex);
                                  },
                                  icon: const Icon(Icons.add),
                                  label: const Text('Add Exercise'),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.lightBlueAccent,
                                    textStyle: const TextStyle(fontSize: 13),
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                              ),
                            ),
                          ),



                        // ✅ Show planned exercises only if any exist
          if (exerciseRows[weekIndex][dayIndex].isNotEmpty)
          Expanded(
          child: ReorderableListView.builder(
          itemCount: exerciseRows[weekIndex][dayIndex].length,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) newIndex -= 1;

                final movedRow = exerciseRows[weekIndex][dayIndex].removeAt(oldIndex);
                exerciseRows[weekIndex][dayIndex].insert(newIndex, movedRow);

                // rebuild circuit structure
                final starts = <int>{};
                final rows = exerciseRows[weekIndex][dayIndex];
                for (int i = 0; i < rows.length; i++) {
                  if (i == 0 || rows[i].circuitIndex != rows[i - 1].circuitIndex) {
                    starts.add(i);
                  }
                }
                circuitStartIndices[weekIndex][dayIndex] = starts.toList()..sort();

                updateFutureDaysWithEditedDay(weekIndex, dayIndex);
              });
            },

            buildDefaultDragHandles: false,
          proxyDecorator: (child, index, animation) => Material(elevation: 2, child: child),
          itemBuilder: (context, index) {


          final rowIndex = index;
          final rows = exerciseRows[weekIndex][dayIndex];
          final row = rows[rowIndex];
          final isFirstInCircuit = rowIndex == 0 || row.circuitIndex != rows[rowIndex - 1].circuitIndex;
          final currentCircuit = row.circuitIndex;
          final isLastInCircuit = rowIndex == rows.lastIndexWhere((r) => r.circuitIndex == currentCircuit);

          print('📦 Editable Row: ${row.exercise} (week $weekIndex day $dayIndex row $rowIndex)');

          return Column(
          key: ValueKey('row_wrapper_${row.id}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          if (isFirstInCircuit)
          Transform.translate(
          offset: const Offset(0, -6),
          child: Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 1),
          child: Text(
          '  Circuit ${row.circuitIndex + 1}',
          style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Colors.lightBlueAccent,
          ),
          ),
          ),
          ),
          Dismissible(

          key: ValueKey(row.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            color: Colors.red,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 16),
                            child: const Icon(Icons.delete, color: Colors.white),
                          ),
                          confirmDismiss: (_) async => true,
            onDismissed: (_) async {
              final removedRow = row;
              final removedExerciseName = (removedRow.exercise ?? '').trim();
              final List<Map<String, dynamic>> futureRemovedRows = [];

              // 1️⃣ Update UI state first
              setState(() {
                exerciseRows[weekIndex][dayIndex].removeAt(rowIndex);

                final starts = circuitStartIndices[weekIndex][dayIndex];
                starts.removeWhere((start) => start >= exerciseRows[weekIndex][dayIndex].length);
                if (starts.isEmpty || starts.first != 0) starts.insert(0, 0);
                circuitStartIndices[weekIndex][dayIndex] = starts.toSet().toList()..sort();

                // Remove across future weeks
                for (int futureWeek = weekIndex + 1; futureWeek < exerciseRows.length; futureWeek++) {
                  if (dayIndex >= exerciseRows[futureWeek].length) continue;
                  final futureRows = exerciseRows[futureWeek][dayIndex];
                  for (int i = futureRows.length - 1; i >= 0; i--) {
                    if ((futureRows[i].exercise ?? '').trim() == removedExerciseName) {
                      futureRemovedRows.add({
                        'weekIndex': futureWeek,
                        'dayIndex': dayIndex,
                        'row': futureRows[i],
                        'rowIndex': i,
                      });
                      futureRows.removeAt(i);
                    }
                  }

                  final futureStarts = <int>{};
                  for (int i = 0; i < futureRows.length; i++) {
                    if (i == 0 || futureRows[i].circuitIndex != futureRows[i - 1].circuitIndex) {
                      futureStarts.add(i);
                    }
                  }
                  circuitStartIndices[futureWeek][dayIndex] = futureStarts.toList()..sort();
                }
              });

              // 2️⃣ Cascade delete to persistence
              final uid = _cachedUid;
              final updatedList = exerciseRows[weekIndex][dayIndex]
                  .map((r) => {
                'name': (r.exercise ?? '').trim(),
                'weight': double.tryParse(r.weightController.text) ?? 0.0,
                'reps': int.tryParse(r.repsController.text) ?? 0,
                'rir': double.tryParse(r.rirController.text) ?? 0.0,
                'velocity': r.velocityController.text.trim(),
                'notes': r.notesController.text.trim(),
                'circuitIndex': r.circuitIndex,
              })
                  .toList();

              // Save to Firestore
              await saveDayToFirestore(weekIndex, dayIndex);
              print('🗑️ [BB2 Delete→FS] uid=$uid w$weekIndex d$dayIndex name="$removedExerciseName" saved ${updatedList.length} exercises');

              // Save to Isar
              await BlockPlanCache.putDay(
                uid: uid,
                blockId: _selectedBlockId!,
                weekIndex: weekIndex,
                dayIndex: dayIndex,
                exercises: updatedList,
              );
              print('🗑️ [BB2 Delete→ISAR] uid=$uid w$weekIndex d$dayIndex updatedList=${updatedList.length}');

              // 3️⃣ Undo support
              _lastUndoAction = () {
                setState(() {
                  exerciseRows[weekIndex][dayIndex].insert(rowIndex, removedRow);
                  for (final info in futureRemovedRows) {
                    final w = info['weekIndex'] as int;
                    final d = info['dayIndex'] as int;
                    final ExerciseRow r = info['row'] as ExerciseRow;
                    final int insertAt = info['rowIndex'] as int;
                    exerciseRows[w][d].insert(insertAt, r);
                  }
                });
                // Also restore persistence
                saveDayToFirestore(weekIndex, dayIndex);
                BlockPlanCache.putDay(
                  uid: uid,
                  blockId: _selectedBlockId!,
                  weekIndex: weekIndex,
                  dayIndex: dayIndex,
                  exercises: exerciseRows[weekIndex][dayIndex]
                      .map((r) => {
                    'name': (r.exercise ?? '').trim(),
                    'weight': double.tryParse(r.weightController.text) ?? 0.0,
                    'reps': int.tryParse(r.repsController.text) ?? 0,
                    'rir': double.tryParse(r.rirController.text) ?? 0.0,
                    'velocity': r.velocityController.text.trim(),
                    'notes': r.notesController.text.trim(),
                    'circuitIndex': r.circuitIndex,
                  })
                      .toList(),
                );
                print('↩️ [BB2 Undo] Restored "$removedExerciseName"');
              };

              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Deleted "$removedExerciseName" across future weeks'),
                  action: SnackBarAction(
                    label: 'Undo',
                    textColor: Colors.black,
                    onPressed: () {
                      _lastUndoAction?.call();
                      _lastUndoAction = null;
                    },
                  ),
                ),
              );
            },


            child: Transform.translate(
                            offset: const Offset(0, -8), // 👈 shift upward by 6 pixels
                            child: Row(
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(left: 0, right: 2), // ✅ removed `top: 0`, not needed
                                ),
                                Expanded(
                                  child: _buildExerciseRow(weekIndex, dayIndex, rowIndex, repTargetsByExercise),
                                ),
                              ],
                            ),
                          ),

                        ),
                        if (isLastInCircuit)
                          Transform.translate(
                            offset: const Offset(0, -6), // 👈 shift upward by 6 pixels
                            child: Padding(
                              padding: const EdgeInsets.only(right: 4), // ⬅️ removed top padding since we're shifting manually
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton.icon(
                                    onPressed: () {
                                      setState(() {
                                        exerciseRows[weekIndex][dayIndex].insert(
                                          rowIndex + 1,
                                          ExerciseRow(circuitIndex: currentCircuit),
                                        );
                                      });
                                      updateFutureDaysWithEditedDay(weekIndex, dayIndex);
                                    },
                                    icon: const Icon(Icons.add, size: 16),
                                    label: const Text('Add Exercise', style: TextStyle(fontSize: 12)),
                                    style: TextButton.styleFrom(
                                      foregroundColor: Colors.lightBlueAccent,
                                      padding: const EdgeInsets.symmetric(horizontal: 8),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                                  ],
                    );

                  },
                ),


          ),


              const SizedBox(height: 8),

              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _ensureCircuitStartIndicesInitialized(weekIndex, dayIndex);

                      final insertIndex = exerciseRows[weekIndex][dayIndex].length;

                      // Insert 2 new ExerciseRows into the current day
                      for (int i = 0; i < 2; i++) {
                        exerciseRows[weekIndex][dayIndex].insert(
                          insertIndex + i,
                          ExerciseRow(circuitIndex: circuitStartIndices[weekIndex][dayIndex].length),
                        );
                      }

                      // Add circuit start index and sort
                      circuitStartIndices[weekIndex][dayIndex].add(insertIndex);
                      circuitStartIndices[weekIndex][dayIndex].sort();
                    });
                  },
                  icon: const Icon(Icons.add, size: 16, color: Colors.white70),
                  label: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: const [
                      Text(
                        "Add New Circuit",
                        style: TextStyle(color: Colors.lightBlueAccent, fontSize: 11),
                      ),
                      Text(
                        "Scroll to next week →",
                        style: TextStyle(color: Colors.white70, fontSize: 11, fontStyle: FontStyle.italic),
                      ),
                    ],
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
                      ],
          ),
        ),
          ],
          ),
            ),
      );
    }
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
        future: _initialLoad,
        builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()),
        );
      }
      if (_weekPageController == null) {
        return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()),
        );
      }


      return Scaffold(
          appBar: AppBar(
            title: _allBlocks.isEmpty
                ? const Text("Block Builder 2")
                : Row(
                    children: [
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            // 1️⃣ make it fill the row
                            isExpanded: true,

                            // 2️⃣ current selection
                            value: _selectedBlockId,
                            style: const TextStyle(color: Colors.white),
                            iconEnabledColor: Colors.white,
                            dropdownColor: Colors.blueGrey.shade900,

                            // 3️⃣ build each menu item, with a check icon on the active one
                            items: _allBlocks.map((b) {
                              return DropdownMenuItem<String>(
                                value: b.id,
                                child: Row(
                                  children: [
                                    if (b.id == _activeBlockId)
                                      const Icon(
                                        Icons.check_circle,
                                        size: 16,
                                        color: Colors.lightGreenAccent,
                                      ),
                                    if (b.id == _activeBlockId) const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        b.name,
                                        style: const TextStyle(color: Colors.white),
                                        overflow: TextOverflow.ellipsis,
                                        softWrap: false,
                                      ),
                                    ),
                                  ],
                                ),
                              );

                            }).toList(),

                            // 4️⃣ also show the check-icon in the closed header
                            selectedItemBuilder: (context) {
                              return _allBlocks.map((b) {
                                return Row(
                                  children: [
                                    if (b.id == _activeBlockId)
                                      const Icon(
                                        Icons.check_circle,
                                        size: 16,
                                        color: Colors.lightGreenAccent,
                                      ),
                                    if (b.id == _activeBlockId) const SizedBox(width: 4),
                                    Expanded(
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Text(
                                          b.name,
                                          style: const TextStyle(color: Colors.white),
                                          overflow: TextOverflow.ellipsis,
                                          softWrap: false,
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              }).toList();
                            },


                            // 5️⃣ on change remains the same
                            onChanged: (newId) {
                              if (newId == null || newId == _selectedBlockId)
                                return;
                              setState(() {
                                _loading = true;
                                _selectedBlockId = newId;
                              });
                              _reloadForBlock(newId);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
            actions: [
              IconButton(
                icon: const Icon(Icons.undo),
                tooltip: "Undo last action",
                onPressed: _lastUndoAction != null
                    ? () {
                        _lastUndoAction?.call();
                        _lastUndoAction = null;
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text("✅ Last action undone.")));
                      }
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: "Delete BlockBuilder Only",
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text("Clear Block Builder?"),
                      content: const Text(
                          "This will delete all exercise planning from BlockBuilder, but not any workouts you've done."),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text("Cancel")),
                        TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text("Yes")),
                      ],
                    ),
                  );
                },
              ),
            ],
          ), // ← end AppBar
          body: GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      PageView.builder(
                        controller: _weekPageController!,
                        itemCount: weekIndices.length,
                        onPageChanged: (newPage) async {
                          setState(() => _currentWeekPage = newPage);
                          if (!loadedWeekIndices.contains(newPage)) {
                            await loadBlockDataForWeek(newPage);
                            loadedWeekIndices.add(newPage);
                            setState(() {});
                          }
                        },
                        itemBuilder: (ctx, pageIndex) {
                          // each week can scroll vertically if it overflows:
                          return SingleChildScrollView(
                            child: _buildWeek(pageIndex, repTargetsByExercise),
                          );
                        },
                      ),

                      // ‹ button
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        child: IconButton(
                          icon: Icon(Icons.chevron_left, color: Colors.white70),
                          onPressed: () {
                            if (_currentWeekPage > 0) {
                              _weekPageController!.previousPage(
                                duration: Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                            }
                          },
                        ),
                      ),

                      // › button
                      Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: IconButton(
                          icon:
                              Icon(Icons.chevron_right, color: Colors.white70),
                          onPressed: () {
                            if (_currentWeekPage < weekIndices.length - 1) {
                              _weekPageController!.nextPage(
                                duration: Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
