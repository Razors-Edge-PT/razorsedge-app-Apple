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


// 🧠 Group exercises by category for dropdown UI
Map<String, List<String>> groupExercisesByCategory(List<Map<String, String>> allExercises) {
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
  int circuitIndex;

  ExerciseRow({String? id, this.exercise, required this.circuitIndex})
      : id = id ?? const Uuid().v4(); // <-- generate if not provided
}


class BlockBuilder2 extends StatefulWidget {
  const BlockBuilder2({super.key});

  @override
  State<BlockBuilder2> createState() => _BlockBuilder2State();
}


class _BlockBuilder2State extends State<BlockBuilder2> {
  final int initialWeeks = 12;
  int visibleWeekCount = 2; // Initially load 3 weeks
  int totalWeeks = 12;
  final int exercisesPerDay = 3;
  List <Template> templates = []; // Make sure Template is imported
  List<List<String?>> selectedTemplateIds = [];
  List<List<List<ExerciseRow>>> exerciseRows = [];
  final Map<String, bool> _savedFields = {}; // key = 'w0_d1_r2_weight'

  List<List<List<TextEditingController>>> e1rmControllers = [];
  List<List<List<int>>> circuitStartIndices = [];
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();
  Map<String, dynamic> repTargetsByExercise = {};
  Map<String, dynamic> plannedExerciseDetails = {};

  Map<String, dynamic> _repTargetsByExercise = {};
  Map<String, List<int>> scheduledRepTargets = {}; // 🆕
  Map<String, List<Map<String, dynamic>>> topSetsByExercise = {};
  Map<String, List<Map<String, dynamic>>> completedWesRows = {};

  late DateTime selectedWeekMonday;
  late DateTime blockStartDate;
  late DateTime blockEndDate;

  int? _draggedRowIndex;
  List<Map<String, String>> allExercisesFromFirestore = []; // 🔥 Full list
  Map<String, String> _exerciseIdToName = {}; // 🧠 New: exerciseID ➔ exerciseName lookup
  Map<String, String> nameToIdMap = {}; // 🧠 Exercise name ➔ ID lookup
  List<String> plannedExercises = []; // 💡 Selected in BlockPlanner
  List<int> weekIndices = [];
  Map<int, List<ExerciseRow>> latestEditedWeekdayTemplates = {};
// Key = weekday index (0=Mon...6=Sun), Value = latest edited structure
  VoidCallback? _lastUndoAction;



  late Future<void> _initialLoad;



  final Map<String, FocusNode> _focusNodes = {};

  FocusNode _getFocusNode(String key) {
    return _focusNodes.putIfAbsent(key, () => FocusNode());
  }

  Map<int, List<ExerciseRow>> groupByCircuitIndex(List<ExerciseRow> rows) {
    final Map<int, List<ExerciseRow>> grouped = {};
    for (final row in rows) {
      grouped.putIfAbsent(row.circuitIndex, () => []).add(row);
    }
    return grouped;
  }


  Future<void> loadAllData() async {
    print("🧪 [BB2] Starting loadAllData()...");
    // 🧠 Ensure full top set history is loaded before progression model logic
    await PeriodizationModelUtils.fetchFullTopSetHistory();
    // ✅ Load top sets from workout history (PMU global fetch)
    await PeriodizationModelUtils.fetchLastWorkoutTopSetReps();
    print('🧪 [BB2] Top set reps loaded: ${PeriodizationModelUtils.exercisePreviousTopSetReps.keys.length} exercises');
    print('🧪 [BB2] Top set reps loaded: ${PeriodizationModelUtils.exercisePreviousTopSetReps.keys.toList()}');

    await loadBlockDateRange();

    await Future.wait([
      _fetchTemplates(),
      loadExercisesFromFirestore(),
      loadTopSetsFromWorkouts(),
      loadPlannedExercisesFromFirestore(),
      _loadRepTargets(),
      PeriodizationModelUtils.loadPeriodizationModelsFromFirestore(),
    ]);

    selectedTemplateIds = List.generate(totalWeeks, (_) => List.generate(7, (_) => null));
    await _loadPersistedSavedFields();
    await loadBlockDataFromFirestore();

    print("✅ All data loaded for BB2.");
  }



  Future<void> loadBlockDateRange() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_planner')
        .doc('current_block')
        .get();

    if (doc.exists) {
      final data = doc.data();

      // ✅ Read from blockMeta instead of top-level fields
      final meta = data?['blockMeta'] as Map<String, dynamic>? ?? {};
      final startDateStr = meta['blockStartDate'];
      final endDateStr = meta['blockEndDate'];

      if (startDateStr != null && endDateStr != null) {
        final start = DateTime.parse(startDateStr);
        final end = DateTime.parse(endDateStr);

        setState(() {
          blockStartDate = start;
          blockEndDate = end;
          selectedWeekMonday = _getMostRecentMonday(start);
          totalWeeks = ((end.difference(start).inDays) / 7).ceil();
          visibleWeekCount = 2;
          weekIndices = List.generate(totalWeeks, (i) => i);

          exerciseRows = List.generate(
            totalWeeks,
                (_) => List.generate(
              7,
                  (_) => [
                ExerciseRow(id: const Uuid().v4(), circuitIndex: 0),
                ExerciseRow(id: const Uuid().v4(), circuitIndex: 0),
              ],
            ),
          );
        });
      }
    }
  }


  Future<void> _fetchTemplates() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final userDoc = FirebaseFirestore.instance.collection('users').doc(user.uid);
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
    print('🚀 [BB2] Starting loadExercisesFromFirestore');

    final snapshot = await FirebaseFirestore.instance.collection('exercises').get();

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


      print('✅ [BB2] Mapped "$name" → $id'); // 🔍 Confirm mapping
    }

    print('📦 [BB2] nameToId map now contains: ${PeriodizationModelUtils.nameToId.length} entries');

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

    final rirPlan = plannedExerciseDetails[exerciseId]?['rirPlan'];
    if (rirPlan == null) return null;

    final sessionIndex = getExerciseCountInWeek(exerciseName, week, day, row);
    final weekKey = 'week${week + 1}';
    final sessionKey = 'session${sessionIndex + 1}';

    final Map<String, dynamic>? sessionData =
    (rirPlan[weekKey]?[sessionKey] as Map?)?.cast<String, dynamic>();

    if (sessionData == null) return null;

    return sessionData.map((setKey, setValue) => MapEntry(setKey, {
      'reps': setValue['reps'],
      'rir': setValue['rir'],
    }));
  }



  String? getRepTargetForExercise(String exerciseName, int week, int day, int row) {
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
          print('📊 LinearExposure rep → $reps for $exerciseId');
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
          print('❌ Unknown model type for $exerciseId: $model');
          return null;
      }
    } catch (e) {
      print('⚠️ Error getting rep target for $exerciseName [$exerciseId]: $e');
    }

    print('! No matching rep target found for "$exerciseName" (model: $model)');
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
          print('🔎 Match: "$thisName" == "$exerciseName" (week $week, day $d, row $r)');
        }
      }
    }

    final result = count - 1; // ✅ zero-based index
    print('📊 getExerciseCountInWeek → "$exerciseName" → index $result');
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
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_planner')
        .doc('current_block')
        .get();

    final data = doc.data();
    if (data == null) return;

    setState(() {
      if (data.containsKey('plannedExerciseDetails')) {
        plannedExerciseDetails = Map<String, dynamic>.from(data['plannedExerciseDetails']);
        PeriodizationModelUtils.setExerciseSettings(plannedExerciseDetails);
        print('✅ [PMU] Set exerciseSettings in PMU for ${plannedExerciseDetails.length} exercises');


        // ✅ Inject blockMeta if it exists
        if (data.containsKey('blockMeta')) {
          plannedExerciseDetails['blockMeta'] = Map<String, dynamic>.from(data['blockMeta']);
          print('📎 Injected blockMeta into plannedExerciseDetails');
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
          print('✅ [BB2] Assigned full details to plannedExerciseDetails[$exerciseId]');

        });
      } else {
        print('❌ [BB2] No plannedExerciseDetails found.');
      }
    });

    print("✅ Rep targets map size: ${_repTargetsByExercise.length}");

    plannedExerciseDetails.forEach((exerciseId, details) {
      if (exerciseId == 'blockMeta') return;

      final modelName = details['periodizationModel'];
      if (modelName != null) {
        final modelEnum = PeriodizationModelUtils.stringToModel(modelName);
        PeriodizationModelUtils.exercisePeriodizationModels[exerciseId] = modelEnum;
      }

      final repTargetEntry = _repTargetsByExercise[exerciseId];
      if (repTargetEntry is Map &&
          repTargetEntry.containsKey('repTargets') &&
          modelName == 'Daily Undulating Periodization') {
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
        print('📦 repTargets structure valid for $exerciseId');
      } else {
        print('⚠️ Malformed repTargets entry for $exerciseId: $updatedEntry');
      }

      if (updatedEntry != null) {
        print('🧠 [BB2] Rep targets found for $exerciseId → $updatedEntry');
      } else {
        print('⚠️ [BB2] repTargets entry missing for $exerciseId');
      }
    });

    print("✅ [BB2] exercisePeriodizationModels mapped: ${PeriodizationModelUtils.exercisePeriodizationModels.length}");
    print('📄 Full plannedExerciseDetails: ${jsonEncode(plannedExerciseDetails)}');
  }




  Future<void> loadPlannedExercisesFromFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_planner')
        .doc('current_block')
        .get();

    if (doc.exists) {
      final data = doc.data();
      if (data != null && data['plannedExercises'] != null) {
        plannedExercises = List<String>.from(data['plannedExercises']);
      }
    }

    setState(() {});
  }



  @override
  void initState() {
    super.initState();

    _horizontalScrollController.addListener(() {
      final maxScroll = _horizontalScrollController.position.maxScrollExtent;
      final currentScroll = _horizontalScrollController.position.pixels;
      if (currentScroll / maxScroll > 0.8 && visibleWeekCount < totalWeeks) {
        setState(() {
          visibleWeekCount = (visibleWeekCount + 2).clamp(0, totalWeeks);
        });
      }
    });

    // Main data loading
    _initialLoad = loadAllData();

    // 🔁 Microtask to check WES flag and repaint
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



  @override
  void dispose() {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      for (int week = 0; week < weekIndices.length; week++) {
        final weekStartDate = blockStartDate.add(Duration(days: week * 7));
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

          _trimEmptyExerciseRows(week, day); // ✅ Trim before saving
          saveDayToFirestore(week, day);     // ✅ Save only filled row
        }
      }
    }

    for (final node in _focusNodes.values) {
      node.dispose();
    }
    _focusNodes.clear();

    super.dispose();
  }



  void _populateExercisesFromTemplate(int weekIndex, int dayIndex, String templateId) {
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
      Colors.blueGrey.shade900,
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

  Future<void> loadBlockDataFromFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final weekSnapshots = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_data')
        .doc('current_block')
        .collection('weeks')
        .get();
    print('🧩 Found ${weekSnapshots.docs.length} week documents');


    for (final weekDoc in weekSnapshots.docs) {
      final weekIndex = int.tryParse(weekDoc.id.replaceAll('week_', '')) ?? 0;
      final daySnapshots = await weekDoc.reference.collection('days').get();

      for (final dayDoc in daySnapshots.docs) {
        final dayIndex = int.tryParse(dayDoc.id.replaceAll('day_', '')) ?? 0;
        final data = dayDoc.data();

        final exercises = List<Map<String, dynamic>>.from(data['exercises'] ?? []);
        final savedCircuitIndices = List<int>.from(data['circuitStartIndices'] ?? [0]);

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

          final double? weightVal = rawWeight != null ? double.tryParse(rawWeight.toString()) : null;
          final int? repsVal = rawReps != null ? int.tryParse(rawReps.toString()) : null;
          final double? rirVal = rawRIR != null ? double.tryParse(rawRIR.toString()) : null;

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

          print("Loaded: ${row.exercise}, "
              "${row.weightController.text}, "
              "${row.repsController.text}, "
              "${row.rirController.text}");
        }



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
        final DateTime date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
        final String dateKey = DateFormat('yyyy-MM-dd').format(date);

        print('[WES Check] Checking for saved workout on $dateKey...');
        print('[WES OVERRIDE] blockStartDate = $blockStartDate');
        print('[WES OVERRIDE] dateKey = $dateKey');


        final workoutDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
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
            final baseKey = 'w${weekIndex}_d${dayIndex}_r$rowIndex';

            matchingRow.weightController.text = sets[0]['weight']?.toString() ?? '';
            matchingRow.repsController.text = sets[0]['reps']?.toString() ?? '';
            matchingRow.rirController.text = sets[0]['rir']?.toString() ?? '';

            _savedFields['${baseKey}_weight'] = true;
            _savedFields['${baseKey}_reps'] = true;
            _savedFields['${baseKey}_rir'] = true;

            print("Overrode with WES: ${matchingRow.exercise}, "
                "${matchingRow.weightController.text}, "
                "${matchingRow.repsController.text}, "
                "${matchingRow.rirController.text}");
            print('[Override Attempt] Exercise: $name, Circuit: $circuit, Sets: $sets');

          }

        }
      }
    }

    setState(() {});
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
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final String dateKey = DateFormat('yyyy-MM-dd').format(date);
    if (completedWesRows.containsKey(dateKey)) return; // already loaded

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
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
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .get();

    final Map<String, List<Map<String, dynamic>>> tempTopSets = {};

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final topSets = List<Map<String, dynamic>>.from(data['topSets'] ?? []);

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
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // 🛡️ Guard against index errors
    if (weekIndex >= exerciseRows.length || weekIndex >= circuitStartIndices.length) return;
    if (dayIndex >= exerciseRows[weekIndex].length || dayIndex >= circuitStartIndices[weekIndex].length) return;

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
        'circuitIndex': row.circuitIndex,
      });
    }

    print('📝 [SAVE] Week $weekIndex, Day $dayIndex → Saving ${exercises.length} exercises:');
    for (final ex in exercises) {
      print('  • ${ex['name']} | weight: ${ex['weight']} | reps: ${ex['reps']} | RIR: ${ex['rir']} | circuit: ${ex['circuitIndex']}');
    }

    final weekDocRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_data')
        .doc('current_block')
        .collection('weeks')
        .doc('week_$weekIndex');

    await weekDocRef.set({'exists': true}, SetOptions(merge: true));

    final date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
    final workoutName = "${DateFormat('EEE d MMM').format(date)} - Week ${weekIndex + 1}";

    await weekDocRef
        .collection('days')
        .doc('day_$dayIndex')
        .set({
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
    if (weekIndex >= exerciseRows.length || dayIndex >= exerciseRows[weekIndex].length) return;

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

      circuitStartIndices[weekIndex][dayIndex] = starts.toSet().toList()..sort();
    }
  }


  Future<void> deleteAllBlockAndWorkoutData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userDoc = FirebaseFirestore.instance.collection('users').doc(user.uid);

    // 🧹 1. Delete all workouts
    final workoutsSnapshot = await userDoc.collection('workouts').get();
    for (final doc in workoutsSnapshot.docs) {
      await doc.reference.delete();
    }
    print("🗑️ All workouts deleted.");

    // 🧹 2. Delete block_data > current_block > weeks > days
    final currentBlockDoc = userDoc.collection('block_data').doc('current_block');
    final weeksSnapshot = await currentBlockDoc.collection('weeks').get();

    for (final weekDoc in weeksSnapshot.docs) {
      final daysSnapshot = await weekDoc.reference.collection('days').get();
      for (final dayDoc in daysSnapshot.docs) {
        await dayDoc.reference.delete();
      }
      await weekDoc.reference.delete();
    }

    await currentBlockDoc.delete();
    print("🧼 All block data deleted.");
  }

  Future<void> deleteBlockBuilderDataOnly() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final currentBlockDoc = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_data')
        .doc('current_block');

    final weeksSnapshot = await currentBlockDoc.collection('weeks').get();

    for (final weekDoc in weeksSnapshot.docs) {
      final daysSnapshot = await weekDoc.reference.collection('days').get();
      for (final dayDoc in daysSnapshot.docs) {
        await dayDoc.reference.delete();
      }
      await weekDoc.reference.delete();
    }

    await currentBlockDoc.delete(); // Optional: keep this if you want to remove the doc shell
    print("🧼 BlockBuilder-only data deleted.");
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
    required List<String> plannedExercises,
    required void Function(String selectedExercise) onSelected,
  }) async {
    bool showPlannedOnly = true;
    final Map<String, bool> expandedGroups = {
      for (final category in allGroupedExercises.keys) category: false,
    };

    await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            // 🔄 Filter exercises if Planned Only is active
            final filteredGrouped = <String, List<String>>{};
            allGroupedExercises.forEach((category, exercises) {
              final filtered = showPlannedOnly
                  ? exercises.where((e) => plannedExercises.contains(nameToIdMap[e])).toList()
                  : exercises;

              if (filtered.isNotEmpty) {
                filteredGrouped[category] = filtered;
              }
            });

            return AlertDialog(
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Select Exercise', style: TextStyle(fontSize: 12)),
                  Row(
                    children: [
                      Text(
                        showPlannedOnly ? "Planned Only" : "All Exercises",
                        style: const TextStyle(fontSize: 12),
                      ),
                      Switch(
                        value: showPlannedOnly,
                        onChanged: (value) => setState(() => showPlannedOnly = value),
                      ),
                    ],
                  ),

                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 500,
                child: ListView(
                  children: filteredGrouped.entries.map((entry) {
                    final category = entry.key;
                    final exercises = entry.value;

                    return ExpansionTile(
                      title: Text(
                        category,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      initiallyExpanded: expandedGroups[category]!,
                      onExpansionChanged: (expanded) {
                        setState(() {
                          expandedGroups[category] = expanded;
                        });
                      },
                      children: exercises.map((name) {
                        return ListTile(
                          title: Text(name),
                          onTap: () {
                            Navigator.of(context).pop(); // Close dialog
                            onSelected(name); // Send back selected exercise
                          },
                        );
                      }).toList(),
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ],
            );
          },
        );
      },
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
    final exerciseController = row.exerciseController;

    return StatefulBuilder(
      builder: (context, localSetState) {
        final exerciseName = exerciseController.text;
        print('🧠 Building row for exercise: "$exerciseName" (w$weekIndex d$dayIndex r$rowIndex)');

        final exerciseId = nameToIdMap[exerciseName];
        print('🔍 ID for $exerciseName: $exerciseId');

        if (exerciseId != null) {
          print('🔍 repTargets entry for $exerciseId: ${jsonEncode(repTargetsByExercise[exerciseId])}');
        }
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
        final String hintRir = (rirController.text.isEmpty && rirSetValues != null)
            ? (rirSetValues['set1']?['rir']?.toString() ?? '0.5')
            : rirController.text;

// ✅ Then use it here
        final double rirValue = rirController.text.isNotEmpty
            ? double.tryParse(rirController.text) ?? 0.5
            : double.tryParse(hintRir) ?? 0.5;

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

        // 🚀 Progression logic (only triggers if model is explicitly selected)
        final Map<String, dynamic> progressed = PeriodizationModelUtils.getWeightByProgressionModel(
          model: progressionModel,
          exerciseName: exerciseName,
          repTarget: repsValue.toInt(),
          defaultWeight: historyWeight,
          increments: PeriodizationModelUtils.getIncrementsForExercise(exerciseId ?? ''),
          maxWeightByReps: plannedExerciseDetails[exerciseId]?['maxWeightByReps'],
          topSetHistory: PeriodizationModelUtils.topSetsByExercise[exerciseName],
          weekIndex: weekIndex,
          rirValue: rirValue, // ✅ Pass the existing BB2-calculated RIR here
        );


        final double progressedWeight = progressed['weight'];
        final int progressedReps = progressed['reps'];

        print('🧠 Progression model "$progressionModelName" → using weight ${progressedWeight.toStringAsFixed(1)} (base: $historyWeight)');


        final String hintWeight = (weightController.text.isEmpty && isExerciseNamed)
            ? progressedWeight.toStringAsFixed(1)
            : '';

        final String hintReps = (repsController.text.isEmpty && isExerciseNamed)
            ? progressedReps.toString()
            : '';

        print('📋 repsController: "${repsController.text}", plannedRep: "$plannedRep", hintReps: "$hintReps"');


        final double? effectiveWeight = weightController.text.isNotEmpty
            ? double.tryParse(weightController.text)
            : (weight ?? double.tryParse(hintWeight) ?? historyWeight);

        final double? effectiveReps = repsController.text.isNotEmpty
            ? double.tryParse(repsController.text)
            : double.tryParse(hintReps);


        final double effectiveRir = rirController.text.isNotEmpty
            ? double.tryParse(rirController.text) ?? double.tryParse(hintRir) ?? 0.5
            : double.tryParse(hintRir) ?? 0.5;


        final double? e1rm = PeriodizationModelUtils.calculateE1RM(
          effectiveWeight,
          effectiveReps,
          effectiveRir,
        );

        print("🧠 [BB2 UI] Calculating E1RM from weight=$effectiveWeight, reps=$effectiveReps, rir=$effectiveRir → E1RM=$e1rm");



        return Container(
          height: exerciseRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: getRowColor(weekIndex, dayIndex, rowIndex),
            border: Border(
              bottom: BorderSide(color: Colors.blueGrey.shade700, width: 0.5),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 4,
                child: ReorderableDelayedDragStartListener(
                  index: rowIndex,
                  child: GestureDetector(
                    onTap: () async {
                      await showCollapsibleExercisePicker(
                        context: context,
                        allGroupedExercises: groupExercisesByCategory(allExercisesFromFirestore),
                        plannedExercises: plannedExercises,
                        onSelected: (selectedExerciseName) {
                          final exerciseId = nameToIdMap[selectedExerciseName];
                          final isPlanned = exerciseId != null && plannedExercises.contains(exerciseId);

                          setState(() {
                            row.exercise = selectedExerciseName;
                            exerciseController.text = selectedExerciseName;
                            weightController.clear();
                            repsController.clear();
                            rirController.clear();

                            if (isPlanned) {
                              print('🧾 [BB2] repTargetsByExercise contains: ${repTargetsByExercise?.keys}');
                              print('🧾 [BB2] looking for: $exerciseId');
                              print('🧾 [BB2] entry for $exerciseId: ${repTargetsByExercise?[exerciseId]}');

                              // ✅ Normalize repTargets (flat → nested) for safety
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
                                plannedExerciseDetails: plannedExerciseDetails, // ✅ Pass it in here
                              );


                              // Do not set repsController.text — just clear it
                              repsController.clear();
                            }
                            final hintRir = (() {
                              final planned = getPlannedRirSetValues(
                                exerciseName: exerciseName,
                                week: weekIndex,
                                day: dayIndex,
                                row: rowIndex,
                              );
                              return planned?['set1']?['rir']?.toString() ?? '0.5';
                            })();


                          });
                        },
                      );


                    },
                    child: Container(
                      width: 114,
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

              // Weight
              _buildFieldBox(weightController, hintWeight, weekIndex, dayIndex, rowIndex, "weight", localSetState),

              // Reps
              _buildFieldBox(repsController, hintReps, weekIndex, dayIndex, rowIndex, "reps", localSetState),

              // RIR
              _buildFieldBox(rirController, hintRir, weekIndex, dayIndex, rowIndex, "rir", localSetState),


              // E1RM
              Expanded(
                flex: 2,
                child: Container(
                  alignment: Alignment.center,
                  child: Text(
                    e1rm != null && e1rm > 0 ? e1rm.toStringAsFixed(1) : '',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
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

    // Determine whether user typed something
    final bool wasManuallyEntered = value.isNotEmpty;
    final String state = wasManuallyEntered ? 'user' : 'hint';
    final color = _getFieldColor(state);

    print('📝 hint="$hint" | controller="${controller.text}" for field: $fieldKey');

    return Expanded(
      flex: fieldKey == "weight" ? 2 : 1,
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





  Widget _buildReadOnlyRow(Map<String, dynamic> savedExercise, {Key? key}) {

    final name = savedExercise['name'] ?? 'Unnamed';
    final circuitIndex = savedExercise['circuitIndex'] ?? 0;
    final sets = List<Map<String, dynamic>>.from(savedExercise['sets'] ?? []);

    final topSet = sets.isNotEmpty
        ? sets.reduce((a, b) {
      final e1A = PeriodizationModelUtils.calculateE1RM(
        (a['weight'] ?? 0).toDouble(),
        (a['reps'] ?? 0).toDouble(),
        (a['rir'] ?? 0).toDouble(),
      );
      final e1B = PeriodizationModelUtils.calculateE1RM(
        (b['weight'] ?? 0).toDouble(),
        (b['reps'] ?? 0).toDouble(),
        (b['rir'] ?? 0).toDouble(),
      );
      return e1A >= e1B ? a : b;
    })
        : null;


    final weight = (topSet?['weight'] ?? 0).toDouble();
    final reps = (topSet?['reps'] ?? 0).toDouble();
    final rir = (topSet?['rir'] ?? 0).toDouble();
    final e1rm = PeriodizationModelUtils.calculateE1RM(weight, reps, rir);

    return Container(
      key: key, // ✅ attach the key here
      height: exerciseRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: Colors.blueGrey[300]!.withOpacity(0.15),
        border: Border(bottom: BorderSide(color: Colors.blueGrey[500]!   , width: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 4,
            child: Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(name,
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
          Expanded(
            flex: 2,
            child: Text(weight.toStringAsFixed(1),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.white,  fontStyle: FontStyle.italic)),
          ),
          Expanded(
            flex: 1,
            child: Text(reps.toStringAsFixed(0),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.white,  fontStyle: FontStyle.italic)),
          ),
          Expanded(
            flex: 1,
            child: Text(rir.toStringAsFixed(1),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.white,  fontStyle: FontStyle.italic)),
          ),
          Expanded(
            flex: 2,
            child: Text(e1rm.toStringAsFixed(1),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.white70,  fontStyle: FontStyle.italic)),
          ),
        ],
      ),
    );
  }




  Widget _buildDayView(int weekIndex, int dayIndex, Map<String, dynamic> repTargetsByExercise) {

    final date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
    final dateKey = DateFormat('yyyy-MM-dd').format(date);

// ✅ Lazy-load completed WES data for this specific day
    if (!completedWesRows.containsKey(dateKey)) {
      loadCompletedWorkoutsForDay(date);
    }

    final savedWesExercises = completedWesRows[dateKey] ?? [];


    // continue with the rest of your UI rendering


    final dayLabel = DateFormat('E d MMM y').format(date); // e.g., "Mon 17 Mar 2025"

    return StatefulBuilder(
        builder: (context, localSetState) {
          final meta = (plannedExerciseDetails['blockMeta'] ?? {}) as Map<String, dynamic>;
          final blockStart = DateTime.tryParse(meta['blockStartDate'] ?? '');
          final blockEnd = DateTime.tryParse(meta['blockEndDate'] ?? '');
          final blockLength = PeriodizationModelUtils.getBlockLength(
            blockStartDate: blockStart,
            blockEndDate: blockEnd,
          );

          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            color: Colors.blueGrey.shade900,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
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
                                    "Week ${weekIndex + 1} • $blockLength weeks",
                                    style: const TextStyle(
                                      fontSize: 11,
                                      height: 0.9,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white70,
                                    ),
                                  ),
                                  /*Builder(
                                      builder: (_) {
                                        final rows = exerciseRows[weekIndex][dayIndex];
                                        final firstExercise = rows.isNotEmpty ? rows[0].exercise : null;
                                        if (firstExercise == null || !PeriodizationModelUtils.exercisePreviousTopSetReps.containsKey(firstExercise)) {
                                          return const Text(
                                            "  Upcoming reps: None",
                                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: Colors.white70  ),
                                          );
                                        }
                                        final range = PeriodizationModelUtils.getDupSignatureRepRange(firstExercise);
                                        final int min = range?['min'] ?? 2;
                                        final int max = range?['max'] ?? 10;

                                        final upcoming = PeriodizationModelUtils.REsignatureRepsByExercise(
                                          exerciseName: firstExercise,
                                          min: min,
                                          max: max,
                                          count: 5,
                                        );

                                        // 🧾 Print the 5 reps that will appear in the UI
                                        print('🔮 [BB2 UI] Upcoming 5 reps for $firstExercise → ${upcoming.join(', ')}');

                                        return Text(
                                          "  Upcoming reps: ${upcoming.join(', ')}",
                                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: Colors.white70   ),
                                        );
                                      }

                                  ),*/
                                ],
                              ),

                              /*
                              Builder(
                                builder: (_) {
                                  final rows = exerciseRows[weekIndex][dayIndex];
                                  final firstExercise = rows.isNotEmpty ? rows[0].exercise : null;

                                  if (firstExercise == null || !PeriodizationModelUtils.exercisePreviousTopSetReps.containsKey(firstExercise)) {
                                    return const Text(
                                      "Top set history: None",
                                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: Colors.white70  ),
                                    );
                                  }

                                  final history = PeriodizationModelUtils.exercisePreviousTopSetReps[firstExercise]!;

                                  // 🔍 Print to console
                                  print('🧠 [BB2 UI] Top set history for $firstExercise → ${history.join(', ')}');

                                  return Text(
                                    "Top set history: ${history.reversed.join(', ')}",
                                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: Colors.white70  ),
                                  );

                                },
                              ),*/
                            ],
                          ),

                          const SizedBox(height: 0),
                      Row(
                        children: [
                          Text(
                            dayLabel,
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
                                  dayIndex >= selectedTemplateIds[weekIndex].length) {
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
                            final rows = exerciseRows[weekIndex][dayIndex];
                            final List<Map<String, dynamic>> prefilled = [];

                            print('[BB2] exerciseRows for week $weekIndex, day $dayIndex:');
                            for (final row in rows) {
                              print('• ${row.exercise} | weight: ${row.weightController.text} | reps: ${row.repsController.text}');
                              final name = row.exerciseController.text.trim();
                              if (name.isNotEmpty) {
                                prefilled.add({
                                  'name': name,
                                  'circuitIndex': row.circuitIndex,
                                });
                              }
                            }

                            final DateTime workoutDate = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
                            final String formattedWorkoutName = "${DateFormat('EEE d MMM').format(workoutDate)} - Week ${weekIndex + 1}";

                            // ✅ Ensure BB2 data is persisted for WES to access
                            await saveDayToFirestore(weekIndex, dayIndex);

                            final now = DateTime.now();
                            final today = DateTime(now.year, now.month, now.day);
                            final yesterday = today.subtract(const Duration(days: 1));
                            final bool isOlderThanYesterday = workoutDate.isBefore(yesterday);

                            if (isOlderThanYesterday) {
                              final user = FirebaseAuth.instance.currentUser;
                              final userDoc = FirebaseFirestore.instance.collection('users').doc(user!.uid);
                              final dayDoc = await userDoc
                                  .collection('block_data')
                                  .doc('current_block')
                                  .collection('weeks')
                                  .doc('week_$weekIndex')
                                  .collection('days')
                                  .doc('day_$dayIndex')
                                  .get();

                              final savedExercises = dayDoc.data()?['exercises'] ?? [];
                              if (savedExercises.isNotEmpty) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => WorkoutSummaryScreen(
                                      date: workoutDate,
                                      workoutName: formattedWorkoutName,
                                      exercises: List<Map<String, dynamic>>.from(savedExercises),
                                    ),
                                  ),
                                );
                                return;
                              }
                            }

                            // 🚀 Open WES normally
                            final result = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => WorkoutPage(
                                  prefilledExercisesWithCircuits: prefilled,
                                  isNewWorkout: true,
                                  initialDate: workoutDate,
                                  initialWorkoutName: formattedWorkoutName,
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
                              }
                              await saveDayToFirestore(weekIndex, dayIndex);
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
              Container(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                color: Colors.blueGrey.shade800,
                child: Row(
                  children: const [
                    Expanded(
                        flex: 4,
                        child: Text("Exercise",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.white))),
                    Expanded(
                        flex: 2,
                        child: Text("Weight",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.white))),
                    Expanded(
                        flex: 1,
                        child: Text("Reps",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.white))),
                    Expanded(
                        flex: 1,
                        child: Text("RIR",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.white))),
                    Expanded(
                        flex: 2,
                        child: Text("E1RM",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.white))),
                  ],
                ),
              ),

              // 🟣 Scrollable Exercise Table (~6.5 visible rows)
              const SizedBox(height: 6),
              SizedBox(
                height: 255,
                child: ReorderableListView.builder(
                  itemCount: savedWesExercises.length + exerciseRows[weekIndex][dayIndex].length,
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
                      final exercise = savedWesExercises[index];
                      return _buildReadOnlyRow(
                        exercise,
                        key: ValueKey('readonly_row_${exercise['name']}_${exercise['circuitIndex']}'),
                      );

                    }

                    final rowIndex = index - savedWesExercises.length;
                    final rows = exerciseRows[weekIndex][dayIndex];
                    final row = rows[rowIndex];
                    final isFirstInCircuit = rowIndex == 0 || row.circuitIndex != rows[rowIndex - 1].circuitIndex;
                    final currentCircuit = row.circuitIndex;
                    final isLastInCircuit = rowIndex == rows.lastIndexWhere((r) => r.circuitIndex == currentCircuit);

                    return Column(
                      key: ValueKey('row_wrapper_${row.id}'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isFirstInCircuit)
                          Padding(
                            padding: const EdgeInsets.only(left: 8, bottom: 1, top: 6),
                            child: Text(
                              'Circuit ${row.circuitIndex + 1}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.lightBlueAccent,
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
                          child: Row(
                            children: [
                              const Padding(padding: EdgeInsets.only(left: 6, right: 4)),
                              Expanded(child: _buildExerciseRow(weekIndex, dayIndex, rowIndex, repTargetsByExercise)),

                            ],
                          ),
                        ),
                        if (isLastInCircuit)
                          Padding(
                            padding: const EdgeInsets.only(top: 4, right: 8),
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
                  label: const Text("Add New Circuit", style: TextStyle(color: Colors.white70, fontSize: 11)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),


            ],
          ),
        ),
      );
    }
    );
  }




  Widget _buildWeek(int weekIndex, Map<String, dynamic> repTargetsByExercise) {
    return SizedBox(
      width: MediaQuery.of(context).size.width * 0.95,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(
          7,
                (dayIndex) => _buildDayView(weekIndex, dayIndex, repTargetsByExercise)

        ),
      ),
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

      return Scaffold(
        appBar: AppBar(
          title: const Text("Block Builder 2.0"),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: "Undo last action",
            onPressed: _lastUndoAction != null
                ? () {
              _lastUndoAction?.call();
              _lastUndoAction = null;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("✅ Last action undone.")),
              );
            }
                : null, // Disable button if nothing to undo
          ),

          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: "Delete BlockBuilder Only",
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text("Clear Block Builder?"),
                  content: const Text("This will delete all exercise planning from BlockBuilder, but not any workouts you've done."),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Yes")),
                  ],
                ),
              );

              if (confirm == true) {
                await deleteBlockBuilderDataOnly();

                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('🧼 BlockBuilder data deleted.')),
                );

                setState(() {
                  exerciseRows = List.generate(
                    initialWeeks,
                        (_) => List.generate(7, (_) => [
                      ExerciseRow(circuitIndex: 0),
                      ExerciseRow(circuitIndex: 0),
                    ]),
                  );

                  selectedTemplateIds = List.generate(initialWeeks, (_) => List.generate(7, (_) => null));
                  circuitStartIndices = List.generate(initialWeeks, (_) => List.generate(7, (_) => [0]));
                  scheduledRepTargets.clear();
                  _lastUndoAction = null;
                });
              }
            },
          ),


        ],
      ),

        body: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(), // ✅ Dismiss keyboard
          child: SingleChildScrollView(
            controller: _verticalScrollController,
            scrollDirection: Axis.vertical,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: SingleChildScrollView(
              controller: _horizontalScrollController,
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: weekIndices
                    .take(visibleWeekCount) // 👈 Only load X weeks
                    .map((i) => _buildWeek(i, repTargetsByExercise))
                    .toList(),
              ),
            ),
          ),
        ),

      );
        },
    );
  }}


