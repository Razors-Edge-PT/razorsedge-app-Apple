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
 // late List<List<List<String?>>> exerciseSelection;
  List<List<List<ExerciseRow>>> exerciseRows = [];

  //List<List<List<TextEditingController>>> exerciseControllers = [];
  //List<List<List<TextEditingController>>> weightControllers = [];
  //List<List<List<TextEditingController>>> repsControllers = [];
  //List<List<List<TextEditingController>>> rirControllers = [];
  List<List<List<TextEditingController>>> e1rmControllers = [];
  List<List<List<int>>> circuitStartIndices = [];
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();
  Map<String, List<int>> scheduledRepTargets = {}; // 🆕
  Map<String, List<Map<String, dynamic>>> topSetsByExercise = {};
  late DateTime selectedWeekMonday;
  late DateTime blockStartDate;
  int? _draggedRowIndex;
  List<Map<String, String>> allExercisesFromFirestore = []; // 🔥 Full list
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
    await loadBlockDateRange();
    await Future.wait([
      _fetchTemplates(),
      loadExercisesFromFirestore(),
      loadTopSetsFromWorkouts(),
      loadPlannedExercisesFromFirestore(),
    ]);

    selectedTemplateIds = List.generate(totalWeeks, (_) => List.generate(7, (_) => null));
    //exerciseSelection = List.generate(totalWeeks, (_) => List.generate(7, (_) => List.filled(exercisesPerDay, null, growable: true)));

    await loadBlockDataFromFirestore();
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
      final startDateStr = data?['blockStartDate'];
      final endDateStr = data?['blockEndDate'];

      if (startDateStr != null && endDateStr != null) {
        final start = DateTime.parse(startDateStr);
        final end = DateTime.parse(endDateStr);

        setState(() {
          blockStartDate = start;
          selectedWeekMonday = _getMostRecentMonday(start);
          totalWeeks = ((end.difference(start).inDays) / 7).ceil();
          visibleWeekCount = 2;
          weekIndices = List.generate(totalWeeks, (i) => i);

          // ✅ INITIALIZE 2 STARTING ROWS PER DAY:
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
    final snapshot = await FirebaseFirestore.instance.collection('exercises').get();
    final exercises = snapshot.docs.map((doc) => {
      'name': doc['name'] as String,
      'category': doc['category'] as String,
      'bodyPart': doc['bodyPart'] as String,
    }).toList();

    allExercisesFromFirestore = exercises; // 🔐 Save the full list
    setState(() {
      groupedExercises = groupExercisesByCategory(exercises);
    });
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

  bool isWorkoutCompleted(int weekIndex, int dayIndex) {
    final rows = exerciseRows[weekIndex][dayIndex];
    return rows.any((row) =>
    row.exerciseController.text.trim().isNotEmpty &&
        row.weightController.text.trim().isNotEmpty &&
        row.repsController.text.trim().isNotEmpty);
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

    _initialLoad = loadAllData();
  }


  @override
  void dispose() {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      for (int week = 0; week < weekIndices.length; week++) {
        for (int day = 0; day < 7; day++) {
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




  TextEditingController _getController(
      List<List<List<TextEditingController>>> controllerList,
      int weekIndex,
      int dayIndex,
      int rowIndex,
      ) {
    // Ensure outer week list is big enough
    while (controllerList.length <= weekIndex) {
      controllerList.add([]);
    }

    // Ensure day list is big enough
    while (controllerList[weekIndex].length <= dayIndex) {
      controllerList[weekIndex].add([]);
    }

    // Ensure row list is big enough
    while (controllerList[weekIndex][dayIndex].length <= rowIndex) {
      controllerList[weekIndex][dayIndex].add(TextEditingController());
    }

    return controllerList[weekIndex][dayIndex][rowIndex];
  }

  DateTime _getMostRecentMonday([DateTime? reference]) {
    DateTime now = reference ?? DateTime.now();
    int diff = now.weekday - DateTime.monday;
    return now.subtract(Duration(days: diff < 0 ? 7 + diff : diff));
  }


  void _addWeek() {
    setState(() {
      weekIndices.add(weekIndices.length);
    });
  }

  String _getDayLabel(int weekIndex, int dayOffset) {
    DateTime date = blockStartDate.add(Duration(days: weekIndex * 7 + dayOffset));
    return DateFormat('EEE d MMM yyyy').format(date);
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
      Colors.blueGrey.shade700,
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


  void _reorderRow(int weekIndex, int dayIndex, int from, int to) {
    final list = exerciseRows[weekIndex][dayIndex];
    final row = list.removeAt(from);
    list.insert(to, row);
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

          if (name.isEmpty) continue; // 🧹 Skip blanks

          final row = ExerciseRow(
            id: const Uuid().v4(),
            exercise: name,
            circuitIndex: ex.containsKey('circuitIndex')
                ? ex['circuitIndex']
                : _getCircuitIndexForRow(i, savedCircuitIndices), // ✅ fallback
          );

          row.exerciseController.text = name;
          row.weightController.text = (ex['weight'] != null && ex['weight'] != 0) ? ex['weight'].toString() : '';
          row.repsController.text = (ex['reps'] != null && ex['reps'] != 0) ? ex['reps'].toString() : '';
          row.rirController.text = (ex['rir'] != null && ex['rir'] != 0) ? ex['rir'].toString() : '';

          loadedRows.add(row);
        }

        // ✅ Assign the loaded list
        exerciseRows[weekIndex][dayIndex] = loadedRows;

        // ✅ Rebuild circuitStartIndices based on circuitIndex values
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
      print("✅ Top sets loaded (max 4 per exercise): ${topSetsByExercise.length} exercises.");
    });
  }

  void _onExerciseChanged(int weekIndex, int dayIndex) {
    final weekday = DateTime.now().add(Duration(days: dayIndex)).weekday % 7; // Sunday = 0
    latestEditedWeekdayTemplates[weekday] = List<ExerciseRow>.from(
      exerciseRows[weekIndex][dayIndex].map((row) => ExerciseRow(
        exercise: row.exercise,
        circuitIndex: row.circuitIndex,
      )),
    );
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



  Future<void> saveDayToFirestore(int weekIndex, int dayIndex) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final exercises = <Map<String, dynamic>>[];

    final rows = exerciseRows[weekIndex][dayIndex];
    for (final row in rows) {
      final name = (row.exercise ?? '').trim();
      if (name.isEmpty) continue;

      exercises.add({
        'name': name,
        'weight': double.tryParse(row.weightController.text) ?? 0.0,
        'reps': int.tryParse(row.repsController.text) ?? 0,
        'rir': double.tryParse(row.rirController.text) ?? 0.0,
        'circuitIndex': row.circuitIndex, // ✅ NEW
      });

    }

    final weekDocRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_data')
        .doc('current_block')
        .collection('weeks')
        .doc('week_$weekIndex');

    await weekDocRef.set({'exists': true}, SetOptions(merge: true));

    await weekDocRef
        .collection('days')
        .doc('day_$dayIndex')
        .set({
      'exercises': exercises,
      'circuitStartIndices': circuitStartIndices[weekIndex]?[dayIndex] ?? [0],
    });

    print("✅ Saved day: week $weekIndex, day $dayIndex");
  }



  void _trimEmptyExerciseRows(int weekIndex, int dayIndex) {
    if (weekIndex >= exerciseRows.length || dayIndex >= exerciseRows[weekIndex].length) return;

    final rows = exerciseRows[weekIndex][dayIndex];

    rows.removeWhere((row) => (row.exercise ?? '').trim().isEmpty);

    // Optional: clean up circuitStartIndices if needed
    final totalRows = rows.length;
    final starts = circuitStartIndices[weekIndex][dayIndex];

    starts.removeWhere((start) => start >= totalRows);

    // Always ensure the first circuit starts at 0
    if (starts.isEmpty || starts.first != 0) {
      starts.insert(0, 0);
    }

    circuitStartIndices[weekIndex][dayIndex] = starts.toSet().toList()..sort();
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


  Widget _buildExerciseDragPreview(String? name) {
    return Container(
      width: 120,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade800,
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        name ?? 'Exercise',
        style: const TextStyle(fontSize: 11, color: Colors.white),
        overflow: TextOverflow.ellipsis,
      ),
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
                  ? exercises.where((e) => plannedExercises.contains(e)).toList()
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
                      const Text("Planned Only", style: TextStyle(fontSize: 12)),
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


  Widget _buildExerciseField(int weekIndex, int dayIndex, int rowIndex) {
    final row = exerciseRows[weekIndex][dayIndex][rowIndex];

    return GestureDetector(
      onTap: () async {
        await showCollapsibleExercisePicker(
          context: context,
          allGroupedExercises: groupExercisesByCategory(allExercisesFromFirestore),
          plannedExercises: plannedExercises,
          onSelected: (selectedExercise) {
            setState(() {
              row.exercise = selectedExercise;
              row.exerciseController.text = selectedExercise;

              // Clear related inputs
              row.weightController.clear();
              row.repsController.clear();
              row.rirController.clear();
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
    );
  }


  Widget _inputBox({required String hint, int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Container(
        margin: const EdgeInsets.all(2),
        height: 36,
        child: TextField(
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            hintText: hint,
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
          ),
        ),
      ),
    );
  }

  Widget _textBox(String text, {int flex = 1, bool readOnly = false}) {
    return Expanded(
      flex: flex,
      child: Container(
        margin: const EdgeInsets.all(2),
        height: 36,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey),
        ),
        alignment: Alignment.center,
        child: Text(text, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _smallHeaderButton(String label) {
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () {},
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }


  Widget _buildExerciseRow(int weekIndex, int dayIndex, int rowIndex) {
    if (weekIndex >= exerciseRows.length ||
        dayIndex >= exerciseRows[weekIndex].length ||
        rowIndex >= exerciseRows[weekIndex][dayIndex].length) {
      return const SizedBox.shrink();
    }

    final row = exerciseRows[weekIndex][dayIndex][rowIndex];
    final weightController = row.weightController;
    final repsController = row.repsController;
    final rirController = row.rirController;
    final exerciseController = row.exerciseController;

    return StatefulBuilder(
      builder: (context, localSetState) {
        final exerciseName = exerciseController.text;

        final double? weight = double.tryParse(weightController.text);
        final int? reps = int.tryParse(repsController.text);
        final double? rir = double.tryParse(rirController.text);

        int hintReps = 0;
        if (repsController.text.isEmpty && exerciseName.isNotEmpty) {
          final plannedIndex = getExercisePlannedCountBefore(exerciseName, weekIndex, dayIndex, rowIndex);
          if (weightController.text.isNotEmpty) {
            hintReps = PeriodizationModelUtils.updateRepTarget(
              exerciseName,
              weightController.text,
              rirController.text,
              plannedIndex,
            );
          } else {
            hintReps = PeriodizationModelUtils.upcomingRepTargetSequence(
              exerciseName,
              plannedIndex + 1,
            ).last;
          }
        }

        final plannedIndex = getExercisePlannedCountBefore(exerciseName, weekIndex, dayIndex, rowIndex);

        final double hintWeight = (weightController.text.isEmpty && exerciseName.isNotEmpty)
            ? PeriodizationModelUtils.getSuggestedWeight(
          exerciseName,
          repsController,
          rirController,
          plannedIndex,
          topSetsByExercise,
        )
            : 0.0;

        final double? e1rm = PeriodizationModelUtils.calculateE1RM(
          weight ?? (weightController.text.isEmpty ? hintWeight : null),
          reps?.toDouble() ?? (repsController.text.isEmpty ? hintReps.toDouble() : null),
          rir ?? (rirController.text.isEmpty ? 0.5 : null),
        );

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
              // 🟡 Drag handle only in exercise name
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
                        onSelected: (selectedExercise) {
                          setState(() {
                            row.exercise = selectedExercise;
                            exerciseController.text = selectedExercise;
                            weightController.clear();
                            repsController.clear();
                            rirController.clear();
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
              _buildFieldBox(weightController, hintWeight > 0 ? hintWeight.toStringAsFixed(1) : null,
                  weekIndex, dayIndex, rowIndex, "weight", localSetState),

              // Reps
              _buildFieldBox(repsController, hintReps > 0 ? hintReps.toString() : null,
                  weekIndex, dayIndex, rowIndex, "reps", localSetState),

              // RIR
              _buildFieldBox(rirController, "0.5",
                  weekIndex, dayIndex, rowIndex, "rir", localSetState),

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


  Widget _buildFieldBox(
      TextEditingController controller,
      String? hint,
      int week, int day, int row,
      String fieldKey,
      void Function(void Function()) localSetState,
      ) {
    return Expanded(
      flex: fieldKey == "weight" ? 2 : 1,
      child: TextField(
        controller: controller,
        focusNode: _getFocusNode('w${week}_d${day}_r${row}_$fieldKey'),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 12),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          hintText: controller.text.isEmpty ? hint : null,
          hintStyle: const TextStyle(color: Colors.grey),
          border: InputBorder.none,
        ),
        onChanged: (_) => localSetState(() {}),
        onEditingComplete: () => _getFocusNode('w${week}_d${day}_r${row}_$fieldKey').unfocus(),
      ),
    );
  }



  Widget _buildDay(int weekIndex, int dayIndex) {
    final date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
    final dayLabel = DateFormat('E d MMM y').format(date); // e.g., "Mon 17 Mar 2025"

    return StatefulBuilder(
        builder: (context, localSetState)
    {
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
                // ⬅️ Push contents to bottom
                children: [
                  // Week + Date Label
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        "Week ${weekIndex + 1}",
                        style: const TextStyle(
                          fontSize: 11,
                          height: 0.9,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70,
                        ),
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
                          if (isWorkoutCompleted(weekIndex, dayIndex))
                            const Icon(
                              Icons.check_circle,
                              size: 16,
                              color: Colors.lightGreenAccent,
                            ),

                          const SizedBox(width: 6),

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




                  const Spacer(),

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
                              if (id == null || id.isEmpty) return "Template";

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
                      // Notes
                      Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            // 👈 Makes text white
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(0, 30),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () {},
                          child: const Text("Notes", style: TextStyle(
                              fontSize: 11)),
                        ),
                      ),
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

                            for (final row in rows) {
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

                            final user = FirebaseAuth.instance.currentUser;
                            final userDoc = FirebaseFirestore.instance.collection('users').doc(user!.uid);
                            final weekDoc = userDoc
                                .collection('block_data')
                                .doc('current_block')
                                .collection('weeks')
                                .doc('week_$weekIndex');

                            final dayDoc = await weekDoc.collection('days').doc('day_$dayIndex').get();
                            final savedExercises = dayDoc.data()?['exercises'] ?? [];

                            final now = DateTime.now();
                            final today = DateTime(now.year, now.month, now.day);
                            final yesterday = today.subtract(const Duration(days: 1));
                            final bool isOlderThanYesterday = workoutDate.isBefore(yesterday);
                            final bool hasSavedExercises = savedExercises.isNotEmpty;

                            if (isOlderThanYesterday && hasSavedExercises) {
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
                            } else {
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
                  itemCount: exerciseRows[weekIndex][dayIndex].length,
                  onReorder: (oldIndex, newIndex) {
                    setState(() {
                      if (newIndex > oldIndex) newIndex -= 1;

                      final movedRow = exerciseRows[weekIndex][dayIndex].removeAt(oldIndex);
                      exerciseRows[weekIndex][dayIndex].insert(newIndex, movedRow);

                      // ✅ Update circuitIndex to match destination context
                      if (newIndex > 0) {
                        movedRow.circuitIndex = exerciseRows[weekIndex][dayIndex][newIndex - 1].circuitIndex;
                      } else {
                        movedRow.circuitIndex = 0;
                      }

                      // ✅ Rebuild circuitStartIndices
                      final starts = <int>{};
                      for (int i = 0; i < exerciseRows[weekIndex][dayIndex].length; i++) {
                        if (i == 0 || exerciseRows[weekIndex][dayIndex][i].circuitIndex != exerciseRows[weekIndex][dayIndex][i - 1].circuitIndex) {
                          starts.add(i);
                        }
                      }
                      circuitStartIndices[weekIndex][dayIndex] = starts.toList()..sort();

                      // ✅ Mirror changes forward
                      updateFutureDaysWithEditedDay(weekIndex, dayIndex);
                    });
                  },


                  proxyDecorator: (child, index, animation) {
                    return Material(
                      elevation: 2,
                      child: child,
                    );
                  },
                  buildDefaultDragHandles: false,
                  itemBuilder: (context, rowIndex) {
                    final rows = exerciseRows[weekIndex][dayIndex];
                    final row = rows[rowIndex];
                    final isFirstInCircuit = rowIndex == 0 || row.circuitIndex != rows[rowIndex - 1].circuitIndex;
                    final currentCircuit = row.circuitIndex;

                    // ✅ Detect if this is the last row of its circuit
                    final isLastInCircuit = rowIndex == rows.lastIndexWhere(
                          (r) => r.circuitIndex == currentCircuit,
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      key: ValueKey('row_wrapper_${row.id}'),
                      children: [
                        if (isFirstInCircuit)
                          Padding(
                            padding: const EdgeInsets.only(left: 8, bottom:1, top: 6), // ⬅ reduced top padding
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
                            setState(() {
                              exerciseRows[weekIndex][dayIndex].removeAt(rowIndex);
                              final starts = circuitStartIndices[weekIndex][dayIndex];
                              starts.removeWhere((start) => start >= rows.length);
                              if (starts.isEmpty || starts.first != 0) {
                                starts.insert(0, 0);
                              }
                              circuitStartIndices[weekIndex][dayIndex] = starts.toSet().toList()..sort();
                            });

                            _lastUndoAction = () {
                              setState(() {
                                exerciseRows[weekIndex][dayIndex].insert(rowIndex, removedRow);
                              });
                            };

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Deleted "${removedRow.exercise ?? 'Unnamed'}"'),
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
                              const Padding(
                                padding: EdgeInsets.only(left: 6, right: 4),
                              ),
                              Expanded(child: _buildExerciseRow(weekIndex, dayIndex, rowIndex)),
                            ],
                          ),
                        ),
                        if (isLastInCircuit)
                          Padding(
                            padding: const EdgeInsets.only(top: 4, right: 8), // tighter vertical space
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end, // ⬅️ Align to the right
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
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
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




  Widget _buildWeek(int weekIndex) {
    return SizedBox(
      width: MediaQuery.of(context).size.width * 0.95,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(7, (dayIndex) => _buildDay(weekIndex, dayIndex)),
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
                .map((i) => _buildWeek(i))
                .toList(),
          ),
        ),
    ),
    ),
      );
        },
    );
  }}


