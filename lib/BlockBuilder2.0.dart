import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'template_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'workout_entry_screen.dart';
import 'periodization_model_utils.dart';
import 'core_exercises.dart';


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
  late List<List<List<String?>>> exerciseSelection;
  List<List<List<TextEditingController>>> exerciseControllers = [];
  List<List<List<TextEditingController>>> weightControllers = [];
  List<List<List<TextEditingController>>> repsControllers = [];
  List<List<List<TextEditingController>>> rirControllers = [];
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



  final Map<String, FocusNode> _focusNodes = {};

  FocusNode _getFocusNode(String key) {
    return _focusNodes.putIfAbsent(key, () => FocusNode());
  }

  List<int> weekIndices = [];

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
        return Template(
          id: doc.id,
          name: doc['name'],
          day: doc.get('day'), // ✅ Add this line
          exercises: List<String>.from(doc['exercises']),
        );
      }).toList();
      setState(() {}); // Trigger rebuild once loaded
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

    loadBlockDateRange().then((_) {
      _fetchTemplates();
      loadExercisesFromFirestore();
      loadTopSetsFromWorkouts();
      loadPlannedExercisesFromFirestore(); // ✅ ADD THIS LINE

      selectedTemplateIds = List.generate(totalWeeks, (_) => List.generate(7, (_) => null));
      exerciseSelection = List.generate(totalWeeks, (_) => List.generate(7, (_) => List.filled(exercisesPerDay, null, growable: true)));

      loadBlockDataFromFirestore().then((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          scrollToCurrentWeek();
          scrollToCurrentDay();
        });
      });
    });
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
    final template = templates.firstWhere((t) => t.id == templateId, orElse: () => Template(id: '', name: '', day: '', exercises: []));

    for (int i = 0; i < exercisesPerDay; i++) {
      final controller = _getController(exerciseControllers, weekIndex, dayIndex, i);
      controller.text = i < template.exercises.length ? template.exercises[i] : '';
    }
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



  void _addCircuitRowBelow(int weekIndex, int dayIndex, int rowIndex) {
    setState(() {
      final insertIndex = rowIndex + 1;

      exerciseSelection[weekIndex][dayIndex]
          .insert(insertIndex, null);
      exerciseControllers[weekIndex][dayIndex]
          .insert(insertIndex, TextEditingController());
      weightControllers[weekIndex][dayIndex]
          .insert(insertIndex, TextEditingController());
      repsControllers[weekIndex][dayIndex]
          .insert(insertIndex, TextEditingController());
      rirControllers[weekIndex][dayIndex]
          .insert(insertIndex, TextEditingController());
    });
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
    void move<T>(List<List<List<T>>> list) {
      final item = list[weekIndex][dayIndex].removeAt(from);
      list[weekIndex][dayIndex].insert(to, item);
    }

    move(exerciseSelection);
    move(exerciseControllers);
    move(weightControllers);
    move(repsControllers);
    move(rirControllers);
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


        for (int i = 0; i < exercises.length; i++) {
          final ex = exercises[i];
          final name = ex['name'] ?? '';
          final weight = ex['weight'];
          final reps = ex['reps'];
          final rir = ex['rir'];

          // 🧠 Ensure lists are long enough
          while (exerciseSelection[weekIndex][dayIndex].length <= i) {
            exerciseSelection[weekIndex][dayIndex].add(null);
            exerciseControllers[weekIndex][dayIndex].add(TextEditingController());
            weightControllers[weekIndex][dayIndex].add(TextEditingController());
            repsControllers[weekIndex][dayIndex].add(TextEditingController());
            rirControllers[weekIndex][dayIndex].add(TextEditingController());
          }

          exerciseSelection[weekIndex][dayIndex][i] = name;
          _getController(exerciseControllers, weekIndex, dayIndex, i).text = name;

          if (weight != null && weight > 0) {
            _getController(weightControllers, weekIndex, dayIndex, i).text = weight.toString();
          }
          if (reps != null && reps > 0) {
            _getController(repsControllers, weekIndex, dayIndex, i).text = reps.toString();
          }
          if (rir != null && rir > 0) {
            _getController(rirControllers, weekIndex, dayIndex, i).text = rir.toString();
          }
        }
        final savedCircuitStartIndices = List<int>.from(data['circuitStartIndices'] ?? [0]);

        _ensureCircuitStartIndicesInitialized(weekIndex, dayIndex);
        circuitStartIndices[weekIndex][dayIndex] = savedCircuitStartIndices;


      }
    }
    await Future.delayed(Duration(milliseconds: 100));
    setState(() {
      print("✅ Data loaded, triggering UI rebuild");
    });


    setState(() {});
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
          tempTopSets.putIfAbsent(name, () => []).add(set);
        }
      }
    }

    setState(() {
      topSetsByExercise = tempTopSets;
      print("✅ Top sets loaded for ${topSetsByExercise.length} exercises.");
    });

    await Future.delayed(const Duration(milliseconds: 50));
    if (mounted) setState(() {});
  }


  Future<void> saveDayToFirestore(int weekIndex, int dayIndex) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final exercises = <Map<String, dynamic>>[];

    for (int i = 0; i < exerciseSelection[weekIndex][dayIndex].length; i++) {
      final name = _getController(exerciseControllers, weekIndex, dayIndex, i).text.trim();
      final weightText = _getController(weightControllers, weekIndex, dayIndex, i).text.trim();
      final repsText = _getController(repsControllers, weekIndex, dayIndex, i).text.trim();
      final rirText = _getController(rirControllers, weekIndex, dayIndex, i).text.trim();

      if (name.isNotEmpty) {
        exercises.add({
          'name': name,
          'weight': double.tryParse(weightText) ?? 0.0,
          'reps': int.tryParse(repsText) ?? 0,
          'rir': double.tryParse(rirText) ?? 0.0,
        });
      }
    }


    final weekDocRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_data')
        .doc('current_block')
        .collection('weeks')
        .doc('week_$weekIndex');

    // 🛠️ Make sure parent doc exists
    await weekDocRef.set({'exists': true}, SetOptions(merge: true));

    await weekDocRef
        .collection('days')
        .doc('day_$dayIndex')
        .set({
      'exercises': exercises,
      'circuitStartIndices': circuitStartIndices[weekIndex][dayIndex], // ✅ Save circuit structure
    });

    print("✅ Saved day: week $weekIndex, day $dayIndex");

  }

  void _trimEmptyExerciseRows(int weekIndex, int dayIndex) {
    final names = exerciseControllers[weekIndex][dayIndex];

    for (int i = exerciseSelection[weekIndex][dayIndex].length - 1; i >= 0; i--) {
      final name = names[i].text.trim();
      if (name.isEmpty) {
        exerciseSelection[weekIndex][dayIndex].removeAt(i);
        exerciseControllers[weekIndex][dayIndex].removeAt(i);
        weightControllers[weekIndex][dayIndex].removeAt(i);
        repsControllers[weekIndex][dayIndex].removeAt(i);
        rirControllers[weekIndex][dayIndex].removeAt(i);
      }
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
    setState(() {
      for (int i = 0; i < exercisesPerDay; i++) {
        exerciseSelection[weekIndex][dayIndex][i] = null;
        _getController(exerciseControllers, weekIndex, dayIndex, i).clear();
        _getController(weightControllers, weekIndex, dayIndex, i).clear();
        _getController(repsControllers, weekIndex, dayIndex, i).clear();
        _getController(rirControllers, weekIndex, dayIndex, i).clear();
      }
    });

    // Optional: delete it from Firestore too
    saveDayToFirestore(weekIndex, dayIndex);
  }



  int getExercisePlannedCountBefore(String exerciseName, int targetWeek, int targetDay, int targetRow) {
    int count = 0;

    for (int w = 0; w <= targetWeek; w++) {
      for (int d = 0; d < 7; d++) {
        if (w == targetWeek && d > targetDay) break;

        for (int r = 0; r < exercisesPerDay; r++) {
          if (w == targetWeek && d == targetDay && r >= targetRow) break;

          final name = exerciseSelection[w][d][r];
          if (name == exerciseName) {
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
    required Map<String, List<String>> groupedExercises,
    required void Function(String selectedExercise) onSelected,
  }) async {
    bool showPlannedOnly = true;

    // Maintain expanded state for each group
    final Map<String, bool> expandedGroups = {
      for (final category in groupedExercises.keys) category: true,
    };

    await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Select Exercise'),
              content: SizedBox(
                width: double.maxFinite,
                height: 500,
                child: ListView(
                  children: groupedExercises.entries.map((entry) {
                    final category = entry.key;
                    final exercises = entry.value;

                    return ExpansionTile(
                      title: Text(
                        category,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
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
                            Navigator.of(context).pop(); // Close the dialog
                            onSelected(name); // Return selected exercise
                          },
                        );
                      }).toList(),
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildExerciseField(int weekIndex, int dayIndex, int rowIndex) {
    final selected = exerciseSelection[weekIndex][dayIndex][rowIndex];

    return GestureDetector(
      onTap: () async {
        await showCollapsibleExercisePicker(
          context: context,
          groupedExercises: groupExercisesByCategory(
            allExercisesFromFirestore
                .where((ex) => plannedExercises.contains(ex['name']))
                .toList(),
          ),
          onSelected: (selectedExercise) {
            setState(() {
              exerciseSelection[weekIndex][dayIndex][rowIndex] = selectedExercise;
              _getController(exerciseControllers, weekIndex, dayIndex, rowIndex).text = selectedExercise;

              // Clear related inputs
              _getController(weightControllers, weekIndex, dayIndex, rowIndex).clear();
              _getController(repsControllers, weekIndex, dayIndex, rowIndex).clear();
              _getController(rirControllers, weekIndex, dayIndex, rowIndex).clear();
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
            selected ?? 'Select Exercise',
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

    final weightController = _getController(weightControllers, weekIndex, dayIndex, rowIndex);
    final repsController = _getController(repsControllers, weekIndex, dayIndex, rowIndex);
    final rirController = _getController(rirControllers, weekIndex, dayIndex, rowIndex);


    return StatefulBuilder(
      builder: (context, localSetState) {
        final exerciseName = _getController(exerciseControllers, weekIndex, dayIndex, rowIndex).text;
        // Parse values (or null if not present)
        final double? weight = double.tryParse(weightController.text);
        final int? reps = int.tryParse(repsController.text);
        final double? rir = double.tryParse(rirController.text);

        // Hint logic (only when field is empty)
        int hintReps = 0;
        if (repsController.text.isEmpty && exerciseName.isNotEmpty) {
          final plannedIndex = getExercisePlannedCountBefore(exerciseName, weekIndex, dayIndex, rowIndex);
          if (weightController.text.isNotEmpty) {
            // Calculate reps from weight input and correct sequence index
            hintReps = PeriodizationModelUtils.updateRepTarget(
              exerciseName,
              weightController.text,
              rirController.text,
              plannedIndex,
            );
          } else {
            // Use rep target from sequence based on planned position
            hintReps = PeriodizationModelUtils.upcomingRepTargetSequence(
              exerciseName,
              plannedIndex + 1,
            ).last;
          }
        }
        final int plannedIndex = getExercisePlannedCountBefore(exerciseName, weekIndex, dayIndex, rowIndex);

        final double hintWeight = (weightController.text.isEmpty && exerciseName.isNotEmpty)
            ? PeriodizationModelUtils.getSuggestedWeight(
          exerciseName,
          repsController,
          rirController,
          plannedIndex,
          topSetsByExercise, // 🔥 new argument
        )
            : 0.0;



        final double? e1rm = PeriodizationModelUtils.calculateE1RM(
          weight ?? (weightController.text.isEmpty ? hintWeight : null),
          reps?.toDouble() ?? (repsController.text.isEmpty ? hintReps.toDouble() : null),
          rir ?? (rirController.text.isEmpty ? 0.5 : null),
        );
//Colors.blueGrey.shade800,

        return DragTarget<int>(
          onWillAccept: (fromIndex) => fromIndex != rowIndex,
          onAccept: (fromIndex) {
            setState(() {
              _reorderRow(weekIndex, dayIndex, fromIndex, rowIndex);
              _draggedRowIndex = null;
            });
          },
          builder: (context, candidateData, rejectedData) {
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
                  // 🟡 Exercise Cell with Drag
                  Expanded(
                    flex: 4,
                    child: LongPressDraggable<int>(
                      data: rowIndex,
                      dragAnchorStrategy: pointerDragAnchorStrategy,
                      onDragStarted: () => setState(() => _draggedRowIndex = rowIndex),
                      onDraggableCanceled: (_, __) => setState(() => _draggedRowIndex = null),
                      onDragEnd: (_) => setState(() => _draggedRowIndex = null),
                      feedback: Material(
                        color: Colors.transparent,
                        child: Opacity(
                          opacity: 0.8,
                          child: _buildExerciseDragPreview(
                            exerciseSelection[weekIndex][dayIndex][rowIndex],
                          ),
                        ),
                      ),
                      child: _buildExerciseField(weekIndex, dayIndex, rowIndex),
                    ),
                  ),

                  // Weight
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: weightController,
                      focusNode: _getFocusNode('w${weekIndex}_d${dayIndex}_r${rowIndex}_weight'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        hintText: (weightController.text.isEmpty && hintWeight > 0)
                            ? hintWeight.toStringAsFixed(1)
                            : null,
                        hintStyle: const TextStyle(color: Colors.grey),
                        border: InputBorder.none,
                      ),
                      onChanged: (_) => localSetState(() {}),
                      onEditingComplete: () {
                        _getFocusNode('w${weekIndex}_d${dayIndex}_r${rowIndex}_weight').unfocus();
                      },
                    ),
                  ),

                  // Reps
                  Expanded(
                    flex: 1,
                    child: TextField(
                      controller: repsController,
                      focusNode: _getFocusNode('w${weekIndex}_d${dayIndex}_r${rowIndex}_reps'),
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        hintText: (repsController.text.isEmpty && hintReps > 0)
                            ? hintReps.toString()
                            : null,
                        hintStyle: const TextStyle(color: Colors.grey),
                        border: InputBorder.none,
                      ),
                      onChanged: (_) => localSetState(() {}),
                      onEditingComplete: () {
                        _getFocusNode('w${weekIndex}_d${dayIndex}_r${rowIndex}_reps').unfocus();
                      },
                    ),
                  ),

                  // RIR
                  Expanded(
                    flex: 1,
                    child: TextField(
                      controller: rirController,
                      focusNode: _getFocusNode('w${weekIndex}_d${dayIndex}_r${rowIndex}_rir'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                        hintText: "0.5",
                        hintStyle: TextStyle(color: Colors.grey),
                        border: InputBorder.none,
                      ),
                      onChanged: (_) => localSetState(() {}),
                      onEditingComplete: () {
                        _getFocusNode('w${weekIndex}_d${dayIndex}_r${rowIndex}_rir').unfocus();
                      },
                    ),
                  ),

                  // E1RM + Add Button
                  Expanded(
                    flex: 2,
                    child: Container(
                      alignment: Alignment.center,
                      child: Stack(
                        children: [
                          Align(
                            alignment: Alignment.center,
                            child: Text(
                              e1rm != null && e1rm > 0 ? e1rm.toStringAsFixed(1) : '',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                            ),
                          ),

                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );

      },
    );

  }



  TextEditingController _ensureExerciseController(int w, int d, int r) {
    while (exerciseControllers.length <= w) {
      exerciseControllers.add([]);
    }
    while (exerciseControllers[w].length <= d) {
      exerciseControllers[w].add([]);
    }
    while (exerciseControllers[w][d].length <= r) {
      exerciseControllers[w][d].add(TextEditingController());
    }
    return exerciseControllers[w][d][r];
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
          padding: const EdgeInsets.fromLTRB(6, 1, 6, 6), // 👈 Less top padding

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
                      Row(
                        children: [
                          Text(
                            "Week ${weekIndex + 1}",
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.white70,
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            icon: const Icon(Icons.delete_sweep_outlined),
                            color: Colors.white,
                            tooltip: "Clear this day",
                            iconSize: 16,
                            padding: EdgeInsets.zero,
                            constraints: BoxConstraints(),
                            onPressed: () {
                              showDialog(
                                context: context,
                                builder: (ctx) =>
                                    AlertDialog(
                                      title: const Text("Clear this day?"),
                                      content: const Text(
                                          "This will remove all exercises from this day."),
                                      actions: [
                                        TextButton(
                                            onPressed: () => Navigator.pop(ctx),
                                            child: const Text("Cancel")),
                                        TextButton(
                                          onPressed: () {
                                            Navigator.pop(ctx);
                                            clearDay(weekIndex, dayIndex);
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(content: Text(
                                                  "✅ Day cleared.")),
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
                      Text(
                        dayLabel,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
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
                            final selectedTemplateId = await showMenu<String>(
                              context: context,
                              position: RelativeRect.fromLTRB(
                                  100, 100, 200, 200),
                              items: templates.map((template) {
                                return PopupMenuItem<String>(
                                  value: template.id,
                                  child: Text(template.name),
                                );
                              }).toList(),
                            );

                            if (selectedTemplateId != null) {
                              setState(() {
                                selectedTemplateIds[weekIndex][dayIndex] =
                                    selectedTemplateId;
                                _populateExercisesFromTemplate(
                                    weekIndex, dayIndex, selectedTemplateId);
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
                              final id = selectedTemplateIds[weekIndex][dayIndex];
                              if (id == null) return "Template";
                              final match = templates.firstWhere(
                                    (t) => t.id == id,
                                orElse: () => Template(id: '',
                                    name: 'Template',
                                    day: '',
                                    exercises: []),
                              );
                              return match.name;
                            }(),
                            style: const TextStyle(fontSize: 11,
                                color: Colors.white),
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
                            // Now we can use await inside this block
                            final List<String> exercises = [];
                            for (int i = 0; i < exercisesPerDay; i++) {
                              final name = _getController(
                                  exerciseControllers, weekIndex, dayIndex, i)
                                  .text.trim();
                              if (name.isNotEmpty) exercises.add(name);
                            }

                            final DateTime workoutDate = blockStartDate.add(
                                Duration(days: weekIndex * 7 + dayIndex));
                            final String formattedWorkoutName =
                                "${DateFormat('EEE d MMM').format(
                                workoutDate)} - Week ${weekIndex + 1}";

                            final result = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    WorkoutPage(
                                      prefilledExercises: exercises,
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
                                final exerciseName = entry['exercise'] ?? '';
                                final weight = entry['weight']?.toString() ??
                                    '';
                                final reps = entry['reps']?.toString() ?? '';
                                final rir = entry['rir']?.toString() ?? '';

                                final exerciseController = _getController(
                                    exerciseControllers, weekIndex, dayIndex,
                                    i);
                                final weightController = _getController(
                                    weightControllers, weekIndex, dayIndex, i);
                                final repsController = _getController(
                                    repsControllers, weekIndex, dayIndex, i);
                                final rirController = _getController(
                                    rirControllers, weekIndex, dayIndex, i);

                                exerciseController.text = exerciseName;
                                weightController.text = weight;
                                repsController.text = reps;
                                rirController.text = rir;
                              }

                              await saveDayToFirestore(weekIndex, dayIndex);
                              setState(() {});
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

              const SizedBox(height: 6),

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
                height: 220,
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  children: [
                    ...() {
                      final widgets = <Widget>[];
                      final circuits = _getCircuitStartIndices(weekIndex, dayIndex);
                      final totalRows = exerciseSelection[weekIndex][dayIndex].length;

                      for (int c = 0; c < circuits.length; c++) {
                        final start = circuits[c];
                        final end = (c + 1 < circuits.length) ? circuits[c + 1] : totalRows;

                        for (int rowIndex = start; rowIndex < end; rowIndex++) {
                          final isOriginalRow = rowIndex < exercisesPerDay;

                          widgets.add(
                            Dismissible(
                              key: ValueKey('week${weekIndex}_day${dayIndex}_row${rowIndex}_${exerciseSelection[weekIndex][dayIndex][rowIndex] ?? 'none'}'),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                color: Colors.red,
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 16),
                                child: const Icon(Icons.delete, color: Colors.white),
                              ),
                              confirmDismiss: (_) async {
                                // Prevent removal of original rows, but still allow the swipe gesture
                                if (isOriginalRow) {
                                  setState(() {
                                    exerciseSelection[weekIndex][dayIndex][rowIndex] = null;
                                    exerciseControllers[weekIndex][dayIndex][rowIndex].clear();
                                    weightControllers[weekIndex][dayIndex][rowIndex].clear();
                                    repsControllers[weekIndex][dayIndex][rowIndex].clear();
                                    rirControllers[weekIndex][dayIndex][rowIndex].clear();
                                  });

                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Row cleared.')),
                                  );

                                  return false; // Don't actually dismiss
                                }

                                return true; // Proceed with dismissal for added rows
                              },
                              onDismissed: (_) {
                                // Only runs for non-original rows now
                                final removed = {
                                  'name': exerciseSelection[weekIndex][dayIndex][rowIndex],
                                  'nameCtrl': exerciseControllers[weekIndex][dayIndex][rowIndex],
                                  'weightCtrl': weightControllers[weekIndex][dayIndex][rowIndex],
                                  'repsCtrl': repsControllers[weekIndex][dayIndex][rowIndex],
                                  'rirCtrl': rirControllers[weekIndex][dayIndex][rowIndex],
                                };

                                setState(() {
                                  exerciseSelection[weekIndex][dayIndex].removeAt(rowIndex);
                                  exerciseControllers[weekIndex][dayIndex].removeAt(rowIndex);
                                  weightControllers[weekIndex][dayIndex].removeAt(rowIndex);
                                  repsControllers[weekIndex][dayIndex].removeAt(rowIndex);
                                  rirControllers[weekIndex][dayIndex].removeAt(rowIndex);
                                });

                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Deleted "${removed['name']}"'),
                                    action: SnackBarAction(
                                      label: 'Undo',
                                      onPressed: () {
                                        setState(() {
                                          exerciseSelection[weekIndex][dayIndex].insert(rowIndex, removed['name'] as String?);
                                          exerciseControllers[weekIndex][dayIndex].insert(rowIndex, removed['nameCtrl'] as TextEditingController);
                                          weightControllers[weekIndex][dayIndex].insert(rowIndex, removed['weightCtrl'] as TextEditingController);
                                          repsControllers[weekIndex][dayIndex].insert(rowIndex, removed['repsCtrl'] as TextEditingController);
                                          rirControllers[weekIndex][dayIndex].insert(rowIndex, removed['rirCtrl'] as TextEditingController);
                                        });
                                      },
                                    ),
                                  ),
                                );
                              },
                              child: _buildExerciseRow(weekIndex, dayIndex, rowIndex),
                            ),
                          );
                        }



                        // Add the circuit-level "+" button
                        widgets.add(const SizedBox(height: 4));
                        widgets.add(
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              icon: const Icon(Icons.add_circle_outline, color: Colors.white),
                              label: const Text("Add Exercise", style: TextStyle(color: Colors.white, fontSize: 11)),
                              onPressed: () {
                                setState(() {
                                  final insertIndex = end;

                                  exerciseSelection[weekIndex][dayIndex].insert(insertIndex, null);
                                  exerciseControllers[weekIndex][dayIndex].insert(insertIndex, TextEditingController());
                                  weightControllers[weekIndex][dayIndex].insert(insertIndex, TextEditingController());
                                  repsControllers[weekIndex][dayIndex].insert(insertIndex, TextEditingController());
                                  rirControllers[weekIndex][dayIndex].insert(insertIndex, TextEditingController());

                                  // 🧠 Shift all circuit starts that come after this insert
                                  for (int i = 0; i < circuitStartIndices[weekIndex][dayIndex].length; i++) {
                                    if (circuitStartIndices[weekIndex][dayIndex][i] > insertIndex) {
                                      circuitStartIndices[weekIndex][dayIndex][i]++;
                                    }
                                  }
                                });
                              },

                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                minimumSize: const Size(0, 24),
                              ),
                            ),
                          ),
                        );
                        widgets.add(const SizedBox(height: 8));
                      }

                      return widgets;
                    }(),
                  ],

                ),
              ),

              const SizedBox(height: 8),

              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _ensureCircuitStartIndicesInitialized(weekIndex, dayIndex);

                      final insertIndex = exerciseSelection[weekIndex][dayIndex].length;

                      for (int i = 0; i < 2; i++) {
                        exerciseSelection[weekIndex][dayIndex].insert(insertIndex + i, null);
                        exerciseControllers[weekIndex][dayIndex].insert(insertIndex + i, TextEditingController());
                        weightControllers[weekIndex][dayIndex].insert(insertIndex + i, TextEditingController());
                        repsControllers[weekIndex][dayIndex].insert(insertIndex + i, TextEditingController());
                        rirControllers[weekIndex][dayIndex].insert(insertIndex + i, TextEditingController());
                      }

                      circuitStartIndices[weekIndex][dayIndex].add(insertIndex);
                      circuitStartIndices[weekIndex][dayIndex].sort(); // optional but safe
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
    return Scaffold(
      appBar: AppBar(
        title: const Text("Block Builder 2.0"),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_forever),
            tooltip: "Delete All Data",
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text("Wipe All Progress?"),
                  content: Text("This will delete all workouts and block data. Are you sure?"),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: Text("Cancel")),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: Text("Yes")),
                  ],
                ),
              );

              if (confirm == true) {
                await deleteAllBlockAndWorkoutData();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('✅ All progress wiped.')),
                );
                setState(() {
                  exerciseControllers.clear();
                  weightControllers.clear();
                  repsControllers.clear();
                  rirControllers.clear();
                  scheduledRepTargets.clear();
                  selectedTemplateIds = List.generate(initialWeeks, (_) => List.generate(7, (_) => null));
                  exerciseSelection = List.generate(initialWeeks, (_) => List.generate(7, (_) => List.filled(exercisesPerDay, null)));
                });
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: "Delete BlockBuilder Only",
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text("Clear Block Builder?"),
                  content: Text("This will delete all exercise planning from BlockBuilder, but not any workouts you've done."),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: Text("Cancel")),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: Text("Yes")),
                  ],
                ),
              );

              if (confirm == true) {
                await deleteBlockBuilderDataOnly();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('🧼 BlockBuilder data deleted.')),
                );

                setState(() {
                  exerciseControllers.clear();
                  weightControllers.clear();
                  repsControllers.clear();
                  rirControllers.clear();
                  selectedTemplateIds = List.generate(initialWeeks, (_) => List.generate(7, (_) => null));
                  exerciseSelection = List.generate(initialWeeks, (_) => List.generate(7, (_) => List.filled(exercisesPerDay, null)));
                  scheduledRepTargets.clear();
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
  }
}
