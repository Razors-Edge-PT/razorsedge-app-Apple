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

  Map<String, dynamic> _repTargetsByExercise = {};
  Map<String, List<int>> scheduledRepTargets = {}; // 🆕
  Map<String, List<Map<String, dynamic>>> topSetsByExercise = {};
  Map<String, List<Map<String, dynamic>>> completedWesRows = {};
  final Set<String> _loadedDays = {};


  late DateTime selectedWeekMonday;
  late DateTime blockStartDate;
  late DateTime blockEndDate;
  late DateTime _displayStart;
  late DateTime _displayEnd;

  String get userId => UserContext.of(context, listen: false).currentUid;


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


  DateTime _bb2StartTime = DateTime.now();



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

  @override
  void initState() {
    super.initState();
    _repo = BlockPlannerRepository();


    final pageLoadTimer = Stopwatch()..start(); // ⏱️ Start timing
    print("⏱️ BB2 initState started...");


    // 1) Kick off both meta‐loads
    _initialLoad = Future.wait([
      _fetchActiveBlockThenMeta(), // sets blockStartDate, _displayStart, totalWeeks, etc.
      _loadAllBlocks(), // loads your list of all blocks into _allBlocks
    ]).then((_) async {
      // 2) Pick the selected block
      print("✅ Meta loaded. Block list and active block ID ready.");

      setState(() {
        _selectedBlockId = _allBlocks
            .firstWhere((b) => b.id == _activeBlockId,
                orElse: () => _allBlocks.first)
            .id;

        print("🧱 [BB2 Init] Loaded blockId: $_selectedBlockId (should match active: $_activeBlockId)");

      });

      // 3) Now that _displayStart & totalWeeks are valid, compute today’s week
      final today = DateTime.now();
      _currentWeekPage = (today.difference(_displayStart).inDays ~/ 7)
          .clamp(0, totalWeeks - 1);
      print("📊 Rep targets loaded.");

      await _loadRepTargets();

      // 4) Create your PageController
      _weekPageController = PageController(initialPage: _currentWeekPage);

      // 5) Load that week’s data
      await loadBlockDataForWeek(_currentWeekPage);
      print("📦 Week $_currentWeekPage data loaded.");

      loadedWeekIndices.add(_currentWeekPage);

      await loadPlannedExercisesFromFirestore();
     // await _loadRepTargets();    // not sure this actually does anything?
      // 6) Finally trigger a rebuild
      setState(() {});
      pageLoadTimer.stop();
      print("✅ BB2 initState completed in ${pageLoadTimer.elapsedMilliseconds} ms");

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



  Future<void> _loadAllBlocks() async {
    final userContext = UserContext.of(context, listen: false);
    final userId = userContext.currentUid;


    final snap = await FirebaseFirestore.instance
        .collection('planned_blocks') // ✅ correct root
        .doc(userId)
        .collection('blocks')
        .get();

    print(
        '🔍 Loaded ${snap.docs.length} blocks: ${snap.docs.map((d) => d.id)}');

    final blocks = snap.docs
        .map((d) => BlockMeta(
              id: d.id,
              name: d['name'],
              startDate: (d['startDate'] as Timestamp).toDate(),
              endDate: (d['endDate'] as Timestamp).toDate(),
              selectedDays: List<String>.from(d['selectedDays'] ?? []),
            ))
        .toList();

    setState(() {
      _allBlocks = blocks;
      _selectedBlockId = blocks
          .firstWhere((b) => b.id == _activeBlockId, orElse: () => blocks.first)
          .id;
    });
  }

  Future<void> _fetchActiveBlockThenMeta() async {
    // 1️⃣ fetch the active blockId
    print("🧱 fetchActiveBlockThenMeta started");
    _activeBlockId = widget.blockId ?? await BlockRepository().fetchActiveBlockId();

// 🔁 Fallback: try block_planner if block_data is missing
    if (_activeBlockId == null) {
      print("🧩 Initial activeBlockId: $_activeBlockId");
      final userContext = UserContext.of(context, listen: false);
      final uid = userContext.currentUid;
       {
         print("🔄 Trying fallback block_planner for uid: $uid");
        final plannerSnap = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .collection('block_planner')
            .doc('current_block')
            .get();

        _activeBlockId = plannerSnap.data()?['blockId'];
        print("🔁 Fallback blockId from block_planner → $_activeBlockId");
      }
    }

    print("✅ Using active blockId = $_activeBlockId");

    // 2️⃣ guard against “no active block”
    if (_activeBlockId == null) {
      throw StateError("No active block found");
    }

    // 3️⃣ load only the meta you care about first
    final meta = await _repo.loadBlockMeta(
      userId: userId, // 👈 Uses context-aware getter
      blockId: _activeBlockId!,
    );
    print("📦 Meta loaded: start=${meta.startDate}, end=${meta.endDate}");

    // 4️⃣ stash the dates & selected days
    blockStartDate = meta.startDate;
    blockEndDate = meta.endDate;
    _selectedDays = meta.selectedDays;

    // ← compute your Mon→Sun bounds, totalWeeks and weekIndices
    // ← compute your Mon→Sun bounds, totalWeeks and weekIndices
    _computeWeekBounds();

// ✅ Init page controller now that we know how many weeks exist
    final today = DateTime.now();
    _currentWeekPage = (today.difference(_displayStart).inDays ~/ 7).clamp(0, totalWeeks - 1);
    _weekPageController = PageController(initialPage: _currentWeekPage);
    print("📖 _weekPageController initialized to week $_currentWeekPage");


    // 5️⃣ initialize your per-week/day arrays using the now-correct totalWeeks
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

    // 6️⃣ now load everything else
    await loadAllData();
  }

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

  Future<void> loadAllData() async {
    print("🧪 [BB2] Starting loadAllData()...");
    final stopwatch = Stopwatch()..start();
    // 🧠 Ensure full top set history is loaded before progression model logic
    await PeriodizationModelUtils.fetchFullTopSetHistory();
    // ✅ Load top sets from workout history (PMU global fetch)
    await PeriodizationModelUtils.fetchLastWorkoutTopSetReps();
    print('🧪 [BB2] Top set reps loaded: ${PeriodizationModelUtils.exercisePreviousTopSetReps.keys.length} exercises');
    print('🧪 [BB2] Top set reps loaded: ${PeriodizationModelUtils.exercisePreviousTopSetReps.keys.toList()}');



    await Future.wait([
      _fetchTemplates(),
      loadExercisesFromFirestore(),
      loadTopSetsFromWorkouts(),
      loadPlannedExercisesFromFirestore(),
      _loadRepTargets(),
      PeriodizationModelUtils.loadPeriodizationModelsFromFirestore(),
    ]);

    selectedTemplateIds = List.generate(totalWeeks, (_) => List.generate(7, (_) => null));
    Future.delayed(Duration(milliseconds: 100), () {
      _loadPersistedSavedFields();
    });
    await loadVisibleWeeksOnly();


    print("✅ All data loaded for BB2.");
    print('⏱️ BB2 loadAllData + loadVisibleWeeksOnly took ${stopwatch.elapsedMilliseconds}ms');

    final int initialWeek = _currentWeekPage;
    await loadBlockDataForWeek(initialWeek);
    loadedWeekIndices.add(initialWeek);
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

    final clampedSessionIndex = sessionIndex.clamp(0, maxSessions - 1);
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

    final repTargets = details['repTargets'];
    if (repTargets == null) return null;

    final model = PeriodizationModelUtils.exercisePeriodizationModels[exerciseId];
    print('🔍 Model for $exerciseId → $model');
    try {
      switch (model) {
        case PeriodizationModelType.linearExposure:
          final exposureIndex = getExercisePlannedCountBefore(exerciseName, week, day, row);
          final reps = PeriodizationModelUtils.getLinearExposureRepTarget(
            exerciseId: exerciseId,
            exposureIndex: exposureIndex,
            repTargetsByExercise: {exerciseId: {'repTargets': repTargets}},
            plannedExerciseDetails: plannedExerciseDetails,
          );

          return reps.toString();

        case PeriodizationModelType.linearClassic:
          final plannedIndex = getExerciseCountInWeek(exerciseName, week, day, row); // 🆕 Use this
          final rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exerciseId,
            plannedIndex: plannedIndex,
            weekIndex: week,
            repTargetsByExercise: repTargetsByExercise,
            plannedExerciseDetails: plannedExerciseDetails,
            blockStartDate: blockStartDate,
            blockEndDate: blockEndDate,
          );
          print('📈 LinearClassic rep → $rep for $exerciseId (week $week, instance $plannedIndex)');
          return rep.toString();

        case PeriodizationModelType.dailyUndulatingWeek:
          final indexInWeek = getExerciseCountInWeek(exerciseName, week, day, row);
          final rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exerciseId,
            plannedIndex: indexInWeek, // ✅ resets each week
            weekIndex: week,
            plannedExerciseDetails: plannedExerciseDetails,
          );
          print('🔁 DUP by Week rep: $rep for $exerciseId (week $week, index $indexInWeek)');
          return rep.toString();

        case PeriodizationModelType.dupSignature:
          final globalIndex = getExercisePlannedCountBefore(exerciseName, week, day, row);

          final rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(

            exerciseName: exerciseId,
            plannedIndex: globalIndex,
            weekIndex: week,
          );

          return rep.toString();

        case PeriodizationModelType.dailyUndulatingExposure:
          final globalIndex = getExercisePlannedCountBefore(exerciseName, week, day, row);
          final rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exerciseId,
            plannedIndex: globalIndex,
            weekIndex: week,
            repTargetsByExercise: {exerciseId: {'repTargets': repTargets}},
            plannedExerciseDetails: plannedExerciseDetails,
          );
          print('🔁 Model-based rep: $rep for $exerciseId using $model (index $globalIndex)');
          return rep.toString();

        default:
          return null;
      }
    } catch (e) {}
    return null;
  }


  int getExerciseCountInWeek(String exerciseName, int week, int day, int row) {
    int count = 0;

    for (int d = 0; d <= day; d++) {
      final rows = exerciseRows[week][d];
      final lastRow = (d == day) ? row + 1 : rows.length; // ✅ include current row

      for (int r = 0; r < lastRow; r++) {
        final thisName = (rows[r].exercise ?? '').trim();
        if (thisName == exerciseName.trim()) {
          count++;
        }
      }
    }

    final result = count - 1; // ✅ zero-based index

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
            print('🧩 [BB2] Injected repTargets for $exerciseId from plannedExerciseDetails');
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

    final Map<String, dynamic> progressed = {
      'weight': baseWeight,
      'reps': baseReps,
      'e1rm': e1rm,
    };

    print('✅ [BB2] Progressed weight: ${progressed['weight']}');
    print('✅ [BB2] Progressed reps: ${progressed['reps']}');
    print('✅ [BB2] Progressed E1RM: ${progressed['e1rm']}');


    final double? weight = progressed['weight'];
    final int? reps = progressed['reps'];

    print('🔍 [DEBUG] progressed["weight"] = $weight');
    print('🔍 [DEBUG] progressed["reps"] = $reps');

    print('🧪 [BB2] Raw progressed map: $progressed');
    print('🧪 progressed[weight] type = ${progressed['weight']?.runtimeType}');
    print('🧪 progressed[reps] type = ${progressed['reps']?.runtimeType}');



    print('📦 [BB2] Caching progression E1RM for $exerciseName → $e1rm');

    progressed['e1rm'] = e1rm;
    _cachedProgressedValues[cacheKey] = progressed;


    return progressed;
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

  @override
  void dispose() {
    _weekPageController?.dispose(); // ✅ only dispose if it was initialized
    final userId = UserContext.of(context, listen: false).currentUid;
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

          _trimEmptyExerciseRows(week, day); // ✅ Trim only loaded days
          saveDayToFirestore(week, day);     // ✅ Save only loaded days
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

  //Big function, calls full week
  Future<void> loadBlockDataFromFirestore() async {
    final stopwatch = Stopwatch()..start();
    print('⏳ [BB2] Starting loadBlockDataFromFirestore');
    final userId = UserContext.of(context, listen: false).currentUid;
    if (userId.isEmpty || _selectedBlockId == null) return;


    final weeksSnapshot = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(_selectedBlockId!)
        .collection('weeks')
        .get();
    print('🧩 Found ${weeksSnapshot.docs.length} week documents');

    for (final weekDoc in weeksSnapshot.docs) {
      final weekIndex = int.tryParse(weekDoc.id.replaceAll('week_', '')) ?? 0;
      final daySnapshots = await weekDoc.reference.collection('days').get();
      print('📆 Week $weekIndex → ${daySnapshots.docs.length} day docs '
          '[${stopwatch.elapsedMilliseconds}ms]');

      for (final dayDoc in daySnapshots.docs) {
        final dayIndex = int.tryParse(dayDoc.id.replaceAll('day_', '')) ?? 0;
        final data = dayDoc.data();

        final parseStart = stopwatch.elapsedMilliseconds;
        final exercises =
            List<Map<String, dynamic>>.from(data['exercises'] ?? []);
        final savedCircuitIndices =
            List<int>.from(data['circuitStartIndices'] ?? [0]);

        final List<ExerciseRow> loadedRows = [];

        for (int i = 0; i < exercises.length; i++) {
          final ex = exercises[i];
          final name = (ex['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;

          final row = ExerciseRow(
            id: const Uuid().v4(),
            exercise: name,
            circuitIndex: ex.containsKey('circuitIndex')
                ? ex['circuitIndex']
                : _getCircuitIndexForRow(i, savedCircuitIndices),
          );

          row.exerciseController.text = name;
          final dynamic rawWeight = ex['weight'];
          final dynamic rawReps = ex['reps'];
          final dynamic rawRIR = ex['rir'];

          final double? weightVal =
              rawWeight != null ? double.tryParse(rawWeight.toString()) : null;
          final int? repsVal =
              rawReps != null ? int.tryParse(rawReps.toString()) : null;
          final double? rirVal =
              rawRIR != null ? double.tryParse(rawRIR.toString()) : null;

// ✅ Only populate if user likely typed something in (i.e., not default 0)
          if (weightVal != null && weightVal != 0.0) {
            row.weightController.text = weightVal.toString();
          }
          if (repsVal != null && repsVal != 0) {
            row.repsController.text = repsVal.toString();
          }
          if (rirVal != null && rirVal != 0.0) {
            row.rirController.text = rirVal.toString();
          }

          final rowIndex = loadedRows.length;
          final baseKey = 'w${weekIndex}_d${dayIndex}_r$rowIndex';

          if (row.weightController.text.trim().isNotEmpty &&
              double.tryParse(row.weightController.text.trim()) != null &&
              double.tryParse(row.weightController.text.trim()) != 0.0) {
            _savedFields['${baseKey}_weight'] = true;
          }

          if (row.repsController.text.trim().isNotEmpty &&
              int.tryParse(row.repsController.text.trim()) != null &&
              int.tryParse(row.repsController.text.trim()) != 0) {
            _savedFields['${baseKey}_reps'] = true;
          }

          if (row.rirController.text.trim().isNotEmpty &&
              double.tryParse(row.rirController.text.trim()) != null) {
            _savedFields['${baseKey}_rir'] = true;
          }

          loadedRows.add(row);
        }

        print('[Parse] Week $weekIndex Day $dayIndex parse time: ${stopwatch.elapsedMilliseconds - parseStart}ms');

        // ⛓ Assign to map

        exerciseRows[weekIndex][dayIndex] = loadedRows;
        print('[BLOCK LOAD] Week $weekIndex, Day $dayIndex loaded ${loadedRows.length} rows from block_data');

        for (final row in loadedRows) {
          print('  • ${row.exercise} | weight: ${row.weightController.text} | reps: ${row.repsController.text} | RIR: ${row.rirController.text}');
        }

        final List<int> newStarts = [];
        int? lastCircuit;
        for (int i = 0; i < loadedRows.length; i++) {
          final currentCircuit = loadedRows[i].circuitIndex;
          if (i == 0 || currentCircuit != lastCircuit) {
            newStarts.add(i);
            lastCircuit = currentCircuit;
          }
        }

        _ensureCircuitStartIndicesInitialized(weekIndex, dayIndex);
        circuitStartIndices[weekIndex][dayIndex] = newStarts;

// 🔁 Inject saved WES workout override logic
        final DateTime date =
            blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
        final String dateKey = DateFormat('yyyy-MM-dd').format(date);

        final wesStart = stopwatch.elapsedMilliseconds;

        print('[WES Check] Checking for saved workout on $dateKey...');
        print('[WES OVERRIDE] blockStartDate = $blockStartDate');
        print('[WES OVERRIDE] dateKey = $dateKey');

        final workoutDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .collection('workouts')
            .doc(dateKey)
            .get();

        if (!workoutDoc.exists) {
          print('[WES Check] No saved workout for $dateKey.');
        } else {
          print(
              '[WES Check] Found saved WES workout. Attempting to override...');
        }

// 🕓 Print how long this WES lookup took
        print(
            '[WES Check] Week $weekIndex Day $dayIndex override time: ${stopwatch.elapsedMilliseconds - wesStart}ms');

        if (workoutDoc.exists) {
          final workoutData = workoutDoc.data();
          final savedExercises =
              List<Map<String, dynamic>>.from(workoutData?['exercises'] ?? []);

          print(
              '[WES OVERRIDE] Overriding Week $weekIndex, Day $dayIndex with ${savedExercises.length} WES exercises');

          for (int i = 0; i < savedExercises.length; i++) {
            final ex = savedExercises[i];
            final name = ex['name'] ?? '';
            final circuit = ex['circuitIndex'] ?? 0;
            final sets = List<Map<String, dynamic>>.from(ex['sets'] ?? []);

            ExerciseRow? matchingRow;
            try {
              matchingRow = loadedRows.firstWhere(
                (r) => r.exercise == name && r.circuitIndex == circuit,
              );
            } catch (_) {
              matchingRow = null;
            }

            if (matchingRow == null || sets.isEmpty) continue;

            final rowIndex = loadedRows.indexOf(matchingRow);
            final baseKey = 'w${weekIndex}_d${dayIndex}_r$rowIndex';

            matchingRow.weightController.text =
                sets[0]['weight']?.toString() ?? '';
            matchingRow.repsController.text = sets[0]['reps']?.toString() ?? '';
            matchingRow.rirController.text = sets[0]['rir']?.toString() ?? '';

            _savedFields['${baseKey}_weight'] = true;
            _savedFields['${baseKey}_reps'] = true;
            _savedFields['${baseKey}_rir'] = true;
          }
        }
      }
    }

    print(
        '✅ [BB2] loadBlockDataFromFirestore done in ${stopwatch.elapsedMilliseconds}ms');
    setState(() {});
  }

  // Week specific function, calls current week on start up and triggered by page scroll

  Future<void> loadBlockDataForWeek(int weekIndex) async {
    final stopwatch = Stopwatch()..start();
    print('⏳ [BB2] Starting loadBlockDataForWeek($weekIndex)');

    final userId = UserContext.of(context, listen: false).currentUid;
    if (userId.isEmpty || _selectedBlockId == null) return;

    final uid = UserContext.of(context, listen: false).currentUid;


    print("🧱 [BB2 loadBlockDataForWeek] Loaded blockId: $_selectedBlockId (should match active: $_activeBlockId)");

    final weekDocRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(_selectedBlockId)
        .collection('weeks')
        .doc('week_$weekIndex');

    final weekSnapshot = await weekDocRef.get();
    if (!weekSnapshot.exists) {
      print('❌ Week $weekIndex does not exist under planned_blocks.');
      return;
    }
    print('🔍 [loadBlockData] Using UID = $uid for week_$weekIndex');

    final daySnapshots = await weekDocRef.collection('days').get();
    print('📆 Week $weekIndex → ${daySnapshots.docs.length} day docs');

    // ✅ Auto-create placeholder day docs if missing
    if (daySnapshots.docs.isEmpty) {
      print('📭 Week $weekIndex has no day docs. Creating day_0 to day_6...');
      final daysCollectionRef = weekDocRef.collection('days');
      for (int day = 0; day < 7; day++) {
        await daysCollectionRef.doc('day_$day').set({'exists': true});
      }
      // 🔁 Re-fetch daySnapshots now that we created them
      final refreshedDaySnapshots = await daysCollectionRef.get();
      daySnapshots.docs.addAll(refreshedDaySnapshots.docs);
    }


    for (final dayDoc in daySnapshots.docs) {
      final dayIndex = int.tryParse(dayDoc.id.replaceFirst('day_', '')) ?? 0;
      final data = dayDoc.data();

      final exercises = List<Map<String, dynamic>>.from(data['exercises'] ?? []);
      final savedCircuitIndices = List<int>.from(data['circuitStartIndices'] ?? [0]);

      final List<ExerciseRow> loadedRows = [];

      for (var i = 0; i < exercises.length; i++) {
        final ex = exercises[i];
        final name = (ex['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;

        final row = ExerciseRow(
          id: const Uuid().v4(),
          exercise: name,
          circuitIndex: ex.containsKey('circuitIndex')
              ? ex['circuitIndex']
              : _getCircuitIndexForRow(i, savedCircuitIndices),
        );
        row.exerciseController.text = name;

        final rowIndex = loadedRows.length;
        final baseKey = 'w${weekIndex}_d${dayIndex}_r${rowIndex}';

        final dynamic rawWeight = ex['weight'];
        final dynamic rawReps = ex['reps'];
        final dynamic rawRIR = ex['rir'];
        // ✅ Restore velocity (if available)
        final dynamic rawVelocity = ex['velocity'];
        if (rawVelocity != null && rawVelocity.toString().trim().isNotEmpty) {
          row.velocityController.text = rawVelocity.toString().trim();
          _savedFields['${baseKey}_velocity'] = true;
        }

// ✅ Restore notes (if available)
        final dynamic rawNotes = ex['notes'];
        if (rawNotes != null && rawNotes.toString().trim().isNotEmpty) {
          row.notesController.text = rawNotes.toString().trim();
          _savedFields['${baseKey}_notes'] = true;
        }


        final double? weightVal = rawWeight != null ? double.tryParse(rawWeight.toString()) : null;
        final int? repsVal = rawReps != null ? int.tryParse(rawReps.toString()) : null;
        final double? rirVal = rawRIR != null ? double.tryParse(rawRIR.toString()) : null;

        if (weightVal != null && weightVal != 0.0) {
          row.weightController.text = weightVal.toString();
        }
        if (repsVal != null && repsVal != 0) {
          row.repsController.text = repsVal.toString();
        }
        if (rirVal != null && rirVal != 0.0) {
          row.rirController.text = rirVal.toString();
        }

        if (row.weightController.text.trim().isNotEmpty &&
            double.tryParse(row.weightController.text.trim()) != null &&
            double.tryParse(row.weightController.text.trim()) != 0.0) {
          _savedFields['${baseKey}_weight'] = true;
        }

        if (row.repsController.text.trim().isNotEmpty &&
            int.tryParse(row.repsController.text.trim()) != null &&
            int.tryParse(row.repsController.text.trim()) != 0) {
          _savedFields['${baseKey}_reps'] = true;
        }

        if (row.rirController.text.trim().isNotEmpty &&
            double.tryParse(row.rirController.text.trim()) != null &&
            rawRIR != null &&
            rawRIR.toString().trim().isNotEmpty) {
          _savedFields['${baseKey}_rir'] = true;
        }


        loadedRows.add(row);

        print("Loaded: ${row.exercise}, "
            "weight: ${row.weightController.text}, "
            "reps: ${row.repsController.text}, "
            "RIR: ${row.rirController.text}, "
            "velocity: ${row.velocityController.text}, "
            "notes: ${row.notesController.text}");

      }

      exerciseRows[weekIndex][dayIndex] = loadedRows;
      print('[BLOCK LOAD] Week $weekIndex, Day $dayIndex loaded ${loadedRows.length} rows from block_data');

      _loadedDays.add('w${weekIndex}_d${dayIndex}'); // ✅ Track that we’ve loaded this day

      for (final row in loadedRows) {
        print('  • ${row.exercise} | weight: ${row.weightController.text} | reps: ${row.repsController.text} | RIR: ${row.rirController.text} | velocity: ${row.velocityController.text} | notes: ${row.notesController.text}');

      }

      final List<int> newStarts = [];
      int? lastCircuit;
      for (int i = 0; i < loadedRows.length; i++) {
        final currentCircuit = loadedRows[i].circuitIndex;
        if (i == 0 || currentCircuit != lastCircuit) {
          newStarts.add(i);
          lastCircuit = currentCircuit;
        }
      }

      _ensureCircuitStartIndicesInitialized(weekIndex, dayIndex);
      circuitStartIndices[weekIndex][dayIndex] = newStarts;

      // 🔁 Inject saved WES workout override logic
      final DateTime date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
      final String dateKey = DateFormat('yyyy-MM-dd').format(date);

      final workoutDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('workouts')
          .doc(dateKey)
          .get();

      if (!workoutDoc.exists) {
        print('[WES Check] No saved workout for $dateKey.');
      } else {
        print('[WES Check] Found saved WES workout. Attempting to override...');
      }

      if (workoutDoc.exists) {
        final workoutData = workoutDoc.data();
        final savedExercises = List<Map<String, dynamic>>.from(workoutData?['exercises'] ?? []);

        print('[WES OVERRIDE] Overriding Week $weekIndex, Day $dayIndex with ${savedExercises.length} WES exercises');

        for (int i = 0; i < savedExercises.length; i++) {
          final ex = savedExercises[i];
          final name = ex['name'] ?? '';
          final circuit = ex['circuitIndex'] ?? 0;
          final sets = List<Map<String, dynamic>>.from(ex['sets'] ?? []);

          ExerciseRow? matchingRow;
          try {
            matchingRow = loadedRows.firstWhere(
                  (r) => r.exercise == name && r.circuitIndex == circuit,
            );
          } catch (_) {
            matchingRow = null;
          }

          if (matchingRow == null || sets.isEmpty) continue;

          final rowIndex = loadedRows.indexOf(matchingRow);
          final baseKey = 'w${weekIndex}_d${dayIndex}_r${rowIndex}';

          matchingRow.weightController.text =
              sets[0]['weight']?.toString() ?? '';
          matchingRow.repsController.text = sets[0]['reps']?.toString() ?? '';
          matchingRow.rirController.text = sets[0]['rir']?.toString() ?? '';
          matchingRow.velocityController.text = sets[0]['velocity']?.toString() ?? '';
          matchingRow.notesController.text = sets[0]['notes']?.toString() ?? '';


          _savedFields['${baseKey}_weight'] = true;
          _savedFields['${baseKey}_reps'] = true;
          _savedFields['${baseKey}_rir'] = true;
          _savedFields['${baseKey}_velocity'] = true;
          _savedFields['${baseKey}_notes'] = true;

          print("Overrode with WES: ${matchingRow.exercise}, "
              "weight: ${matchingRow.weightController.text}, "
              "reps: ${matchingRow.repsController.text}, "
              "RIR: ${matchingRow.rirController.text}, "
              "velocity: ${matchingRow.velocityController.text}, "
              "notes: ${matchingRow.notesController.text}");

          print('[Override Attempt] Exercise: $name, Circuit: $circuit, Sets: $sets');
        }
      }
    }

    print('✅ [BB2] loadBlockDataForWeek($weekIndex) done in ${stopwatch.elapsedMilliseconds}ms');
    setState(() {});
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

  Future<void> loadTopSetsFromWorkouts() async {
    final uid = UserContext.of(context, listen: false).currentUid;


    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid) // ✅ now using the selected athlete
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
    final uid = UserContext.of(context, listen: false).currentUid;


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

    print('📝 [SAVE] Week $weekIndex, Day $dayIndex → Saving ${exercises.length} exercises:');
    for (final ex in exercises) {
      print('  • ${ex['name']} | weight: ${ex['weight']} | reps: ${ex['reps']} | RIR: ${ex['rir']} | circuit: ${ex['circuitIndex']}');
    }

    final weekDocRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(_selectedBlockId!)
        .collection('weeks')
        .doc('week_$weekIndex');

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
    print('💾 [BB2 → SharedPrefs] Saved day $dateKey → ${jsonEncode(dayData)}');
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

        final String? plannedRep = getRepTargetForExercise(
          exerciseName,
          weekIndex,
          dayIndex,
          rowIndex,
        );

        print('🔢 plannedRep returned: $plannedRep');

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
        final double historyWeight = PeriodizationModelUtils.getSuggestedWeightFromRep(
          exerciseName,
          repsValue.toInt(),
          rirValue,
        );

        final bool userTypedRir = rirController.text.isNotEmpty;
        final bool userTypedWeight = weightController.text.isNotEmpty;

// 🚀 Progression logic (only triggers if model is explicitly selected)
        final Map<String, dynamic> progressed = _getCachedProgressedValues(
          exerciseName: exerciseName,
          exerciseId: exerciseId,
          weekIndex: weekIndex,
          dayIndex: dayIndex,
          rowIndex: rowIndex,
          repTarget: repsValue.toInt(),
          defaultWeight: historyWeight,
          rir: rirValue,
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

            final double newWeight = double.tryParse(weightController.text) ?? baseWeight;

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
          print('🔁 [BB2] Triggered weight recalculation due to ${userTypedRir ? "RIR" : ""}${(userTypedRir && repsController.text.isNotEmpty) ? " + " : ""}${repsController.text.isNotEmpty ? "reps" : ""}');


          // 🧠 Recalculate weight to preserve E1RM with new RIR at same reps
          final double baseWeight = progressedWeightRaw;
          final double baseReps = progressedRepsRaw.toDouble();

          final double? baseE1RM = progressed['e1rm']; // ✅ Use cached base E1RM
          final List<double> increments = PeriodizationModelUtils.getIncrementsForExercise(exerciseId ?? '');


          if (baseE1RM == null) {
            print('❌ [BB2] No cached baseE1RM found — falling back to original weight');
            effectiveWeight = progressedWeightRaw;
          } else {
            // 🔁 Calculate trial weight to maintain E1RM
            double trialWeight = PeriodizationModelUtils.reverseCalculateWeight(
              targetE1RM: baseE1RM,
              reps: effectiveReps.toInt(),
              rir: effectiveRir,
            );

            // 🎯 Round to nearest valid increment
            trialWeight = PeriodizationModelUtils.roundToNearestValidIncrement(
              targetWeight: trialWeight,
              exerciseName: exerciseName,
            );


            print('🎯 [BB2] Rounded weight to nearest valid increment → $trialWeight');

            // 🧠 Recalculate E1RM using rounded weight
            final double actualE1RM = PeriodizationModelUtils.calculateE1RM(
              trialWeight,
              effectiveReps.toDouble(),
              effectiveRir,
            );

            final double minE1RM = baseE1RM * 0.85;
            final double maxE1RM = baseE1RM * 1.02;

            const double epsilon = 0.01;
            if ((actualE1RM < minE1RM - epsilon) || (actualE1RM > maxE1RM + epsilon))
            {
              print('⚠️ [BB2] Adjusted weight = ${trialWeight.toStringAsFixed(1)} '
                  'would cause E1RM = ${actualE1RM.toStringAsFixed(1)} '
                  '(outside range ${minE1RM.toStringAsFixed(1)}–${maxE1RM.toStringAsFixed(1)}) '
                  '→ falling back to cache weight = ${progressedWeightRaw.toStringAsFixed(1)}');
              effectiveWeight = progressedWeightRaw;
            } else {
              effectiveWeight = trialWeight;

              print('🎯 [BB2] Updated weight for $exerciseName = ${trialWeight.toStringAsFixed(1)} '
                  '(to preserve E1RM ${baseE1RM.toStringAsFixed(2)} '
                  'using reps = ${effectiveReps?.toStringAsFixed(1)}, RIR = $effectiveRir)');

              print('✅ [BB2] Accepted adjusted weight = ${trialWeight.toStringAsFixed(1)} '
                  'for E1RM = ${actualE1RM.toStringAsFixed(1)} (base = ${baseE1RM.toStringAsFixed(1)})');

            }
            print('📏 [BB2] Comparing actual E1RM = ${actualE1RM.toStringAsFixed(4)} with range ${minE1RM.toStringAsFixed(4)} – ${maxE1RM.toStringAsFixed(4)}');

          }

        } else {
          // 🧠 Default fallback
          effectiveWeight = weight ?? progressedWeightRaw;
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
            ? ((userTypedRir || repsController.text.isNotEmpty) && effectiveWeight != null

            ? effectiveWeight.toStringAsFixed(1)
            : progressedWeightRaw.toStringAsFixed(1))
            : '';

        print('[TRACE] Checking effectiveReps: reps="${repsController.text}", weight="${weightController.text}", hintWeight="$hintWeight", hintReps="$hintReps"');
        print('📋 repsController: "${repsController.text}", plannedRep: "$plannedRep", hintReps: "$hintReps"');




        final double? e1rm = PeriodizationModelUtils.calculateE1RM(
          effectiveWeight,
          effectiveReps,
          effectiveRir,
        );

        print('🧠 [BB2] Final E1RM used for $exerciseName = ${e1rm?.toStringAsFixed(2)} '
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
                child: Container(
                  alignment: Alignment.center,
                  child: Text(
                    e1rm != null && e1rm > 0 ? e1rm.toStringAsFixed(1) : '',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
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
        onChanged: (_) => localSetState(() {}),
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
    final Set<String> seen = {};
    final savedWesExercises = rawSaved.where((e) {
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
                            padding: const EdgeInsets.symmetric(horizontal: 6,
                                vertical: 6),
                            minimumSize: const Size(0, 30),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () async {
                            // 1️⃣ Figure out your workout date & name first
                            final DateTime workoutDate = blockStartDate.add(
                              Duration(days: weekIndex * 7 + dayIndex),
                            );
                            final String formattedWorkoutName =
                                "${DateFormat('EEE d MMM').format(workoutDate)} - Week ${weekIndex + 1}";

                            // 3️⃣ Build your prefilled list from the in-memory rows
                            final rows = exerciseRows[weekIndex][dayIndex];
                            final List<Map<String, dynamic>> prefilled = [];
                            print('[BB2] exerciseRows for week $weekIndex, day $dayIndex:');
                            for (final row in rows) {
                              print('• ${row.exercise} | weight: ${row.weightController.text} | reps: ${row.repsController.text}');
                              final name = row.exerciseController.text.trim();
                              print('• $name | weight: ${row.weightController.text} | reps: ${row.repsController.text}');
                              if (name.isNotEmpty) {
                                prefilled.add({
                                  'name': name,
                                  'circuitIndex': row.circuitIndex,
                                });
                              }
                            }

                            print('🏷️ prefilledExercisesWithCircuits: $prefilled');

                            // ✅ Ensure BB2 data is persisted for WES to access
                            await saveDayToFirestore(weekIndex, dayIndex);

                            final now = DateTime.now();
                            final today = DateTime(now.year, now.month, now.day);
                            final yesterday = today.subtract(const Duration(days: 1));
                            final bool isOlderThanYesterday = workoutDate.isBefore(yesterday);

                            if (isOlderThanYesterday) {
                              final userContext = UserContext.of(context, listen: false);
                              final userId = userContext.currentUid;

                              final blockId =
                                  _selectedBlockId!; // or however you’re storing the active block
                              final dayDoc = await FirebaseFirestore.instance
                                  .collection('planned_blocks')
                                  .doc(userId)
                                  .collection('blocks')
                                  .doc(blockId)
                                  .collection('weeks')
                                  .doc('week_$weekIndex')
                                  .collection('days')
                                  .doc('day_$dayIndex')
                                  .get();

                              final savedExercises =
                                  dayDoc.data()?['exercises'] ?? [];
                              if (savedExercises.isNotEmpty) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => WorkoutSummaryScreen(
                                      date: workoutDate,
                                      workoutName: formattedWorkoutName,
                                      exercises:
                                          List<Map<String, dynamic>>.from(
                                              savedExercises),
                                    ),
                                  ),
                                );
                                return;
                              }
                            }

                            // 🚀 Open WES normally
                            print("Selected Exercises${prefilled}");    // should show your two exercises
                            final result = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => WorkoutPage(
                                  prefilledExercisesWithCircuits: prefilled,
                                  isNewWorkout: true,
                                  initialDate: workoutDate,
                                  initialWorkoutName: formattedWorkoutName,
                                  blockId: _selectedBlockId!,
                                  // isActive: true,
                                ),
                              ),
                            );

                            // ✅ Pull back updated top sets from WES if available
                            if (result != null && result['topSets'] != null) {
                              final List<dynamic> topSets = result['topSets'];
                              for (int i = 0; i < topSets.length; i++) {
                                final entry = topSets[i];
                                final row = exerciseRows[weekIndex][dayIndex][i];
                                row.exerciseController.text = entry['exercise'] ?? '';
                                row.weightController.text = entry['weight']?.toString() ?? '';
                                row.repsController.text = entry['reps']?.toString() ?? '';
                                row.rirController.text = entry['rir']?.toString() ?? '';
                                row.velocityController.text = entry['velocity']?.toString() ?? '';
                                row.notesController.text = entry['notes']?.toString() ?? '';
                              }
                              await saveDayToFirestore(weekIndex, dayIndex); // ✅ still needed for Firestore

// 🧠 NEW: Also save BB2 in-memory values to SharedPrefs for WES
                              final prefs = await SharedPreferences.getInstance();
                              final dateKey = DateFormat('yyyy-MM-dd').format(workoutDate);

                              final List<Map<String, dynamic>> bb2Exercises = [];
                              for (final row in exerciseRows[weekIndex][dayIndex]) {
                                final name = row.exerciseController.text.trim();
                                if (name.isNotEmpty) {
                                  bb2Exercises.add({
                                    'name': name,
                                    'circuitIndex': row.circuitIndex,
                                    'sets': [
                                      {
                                        'reps': row.repsController.text,
                                        'weight': row.weightController.text,
                                        'rir': row.rirController.text,
                                        'velocity': row.velocityController.text, // ✅ NEW
                                        'notes': row.notesController.text,       // ✅ NEW
                                      }
                                    ],
                                  });
                                }
                              }
                              await prefs.setString('bb2_dayData_$dateKey', jsonEncode({'exercises': bb2Exercises}));
                              print('💾 [BB2 → SharedPrefs] Wrote ${bb2Exercises.length} exercises to cache for $dateKey');

                              setState(() {});
                            }
                            print('[BB2] Passing to WES:');
                            for (var ex in prefilled) {
                              print('→ ${ex['name']} (circuit: ${ex['circuitIndex']})');
                            }

                            print('[BB2 → WES] Prefilled from BB2:');
                            for (final ex in prefilled) {
                              print('• ${ex['name']} (circuitIndex: ${ex['circuitIndex']})');
                            }
                          },
                          child: const Text(
                            "Go to\nWorkout",
                            style: TextStyle(fontSize: 11),
                            textAlign: TextAlign.center,
                          ),
                        ),
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

                                final allSets = List<Map<String, dynamic>>.from(sets);

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
                                                    weight.toStringAsFixed(1),
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
                                                    ' ${e1rm.toStringAsFixed(1)}', // 👈 space before value
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
                                                    setWeight.toStringAsFixed(1),
                                                    textAlign: TextAlign.center,
                                                    style: const TextStyle(fontSize: 12, color: Colors.white, fontStyle: FontStyle.italic),
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
                                                    setE1RM.toStringAsFixed(1),
                                                    textAlign: TextAlign.center,
                                                    style: const TextStyle(fontSize: 12, color: Colors.white70, fontStyle: FontStyle.italic),
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

                                                // Notes
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
          // Prevent reordering of read-only rows
          if (oldIndex < savedWesExercises.length || newIndex < savedWesExercises.length) return;

          setState(() {
          final adjustedOld = oldIndex - savedWesExercises.length;
          var adjustedNew = newIndex - savedWesExercises.length;
          if (adjustedNew > adjustedOld) adjustedNew -= 1;

          final movedRow = exerciseRows[weekIndex][dayIndex].removeAt(adjustedOld);
          exerciseRows[weekIndex][dayIndex].insert(adjustedNew, movedRow);

          // ✅ Rebuild circuit structure and propagate
          final starts = <int>{};
          for (int i = 0; i < exerciseRows[weekIndex][dayIndex].length; i++) {
          if (i == 0 || exerciseRows[weekIndex][dayIndex][i].circuitIndex != exerciseRows[weekIndex][dayIndex][i - 1].circuitIndex) {
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
          if (index < savedWesExercises.length) {
          final skipped = savedWesExercises[index];
          return SizedBox(
          key: ValueKey('skipped_saved_row_${skipped['name']}_${skipped['circuitIndex']}'),
          );
          }

          final rowIndex = index - savedWesExercises.length;
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
                          onDismissed: (_) {
                            final removedRow = row;
                            final removedExerciseName = removedRow.exercise?.trim() ?? '';
                            final List<Map<String, dynamic>> futureRemovedRows = [];

                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              setState(() {
                                exerciseRows[weekIndex][dayIndex].removeAt(rowIndex);

                                final starts = circuitStartIndices[weekIndex][dayIndex];
                                starts.removeWhere((start) => start >= exerciseRows[weekIndex][dayIndex].length);
                                if (starts.isEmpty || starts.first != 0) starts.insert(0, 0);
                                circuitStartIndices[weekIndex][dayIndex] = starts.toSet().toList()..sort();

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

                                _lastUndoAction = () {
                                  setState(() {
                                    exerciseRows[weekIndex][dayIndex].insert(rowIndex, removedRow);
                                    for (final info in futureRemovedRows) {
                                      final w = info['weekIndex'] as int;
                                      final d = info['dayIndex'] as int;
                                      final ExerciseRow r = info['row'] as ExerciseRow;
                                      final int insertAt = info['rowIndex'] as int;
                                      exerciseRows[w][d].insert(insertAt, r);

                                      final futureStarts = <int>{};
                                      for (int i = 0; i < exerciseRows[w][d].length; i++) {
                                        if (i == 0 || exerciseRows[w][d][i].circuitIndex != exerciseRows[w][d][i - 1].circuitIndex) {
                                          futureStarts.add(i);
                                        }
                                      }
                                      circuitStartIndices[w][d] = futureStarts.toList()..sort();
                                    }
                                  });
                                };
                              });
                            });

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Deleted "${row.exercise ?? 'Unnamed'}" across future weeks'),
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
