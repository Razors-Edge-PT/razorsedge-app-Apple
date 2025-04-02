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
    'Squat Pattern',

    'Vertical Press',
    'Lateral Raise',
    'Vertical Pull',
    'Hip Hinge',

    'Arm Extension',
    'Arm Curl',
    'Core',
    'Calf Raise',
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
  int visibleWeekCount = 3; // Initially load 3 weeks
  final int totalWeeks = 12;
  final int exercisesPerDay = 11;
  List <Template> templates = []; // Make sure Template is imported
  List<List<String?>> selectedTemplateIds = [];
  late List<List<List<String?>>> exerciseSelection;
  List<List<List<TextEditingController>>> exerciseControllers = [];
  List<List<List<TextEditingController>>> weightControllers = [];
  List<List<List<TextEditingController>>> repsControllers = [];
  List<List<List<TextEditingController>>> rirControllers = [];
  List<List<List<TextEditingController>>> e1rmControllers = [];
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();
  Map<String, List<int>> scheduledRepTargets = {}; // 🆕





  late DateTime selectedWeekMonday;
  late DateTime blockStartDate;



  List<int> weekIndices = [];

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

    setState(() {
      groupedExercises = groupExercisesByCategory(exercises);
    });
  }


  @override
  void initState() {
    super.initState();

    _horizontalScrollController.addListener(() {
      final maxScroll = _horizontalScrollController.position.maxScrollExtent;
      final currentScroll = _horizontalScrollController.position.pixels;

      // Load more when user scrolls to 80% of max
      if (currentScroll / maxScroll > 0.8 && visibleWeekCount < totalWeeks) {
        setState(() {
          visibleWeekCount = (visibleWeekCount + 2).clamp(0, totalWeeks);
        });
      }
    });


    selectedWeekMonday = _getMostRecentMonday();
    blockStartDate = _getMostRecentMonday();
    weekIndices = List.generate(initialWeeks, (index) => index);

    exerciseSelection = List.generate(
      initialWeeks,
          (_) => List.generate(7, (_) => List.filled(exercisesPerDay, null, growable: true)),
    );

    _fetchTemplates();

    loadExercisesFromFirestore(); // ✅ NEW: Firestore-only fetch (non-blocking)

    selectedTemplateIds = List.generate(
      initialWeeks,
          (_) => List.generate(7, (_) => null),
    );

    loadBlockDataFromFirestore().then((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        scrollToCurrentWeek();
        scrollToCurrentDay();
      });
    });

    final now = DateTime.now();
    print("🕓 Today: $now");
    print("📅 Block Start: $blockStartDate");
  }



  @override
  void dispose() {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      for (int week = 0; week < weekIndices.length; week++) {
        for (int day = 0; day < 7; day++) {
          saveDayToFirestore(week, day); // Autosave each day before exit
        }
      }
    }
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

  DateTime _getMostRecentMonday() {
    DateTime now = DateTime.now();
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

  Color getRowColor(int rowIndex) {
    // You can later pull these thresholds and colors from settings
    if (rowIndex < 3) {
      return Colors.blueGrey.shade700;
    } else if (rowIndex < 6) {
      return Colors.blueGrey.shade900;
    } else {
      return Colors.blueGrey.shade800;
    }
  }
  bool _isLastOfColorBlock(int rowIndex, int dayIndex, int weekIndex) {
    final currentColor = getRowColor(rowIndex);
    final totalRows = exerciseSelection[weekIndex][dayIndex].length;

    if (rowIndex >= totalRows - 1) return true;

    final nextColor = getRowColor(rowIndex + 1);
    return currentColor != nextColor;
  }

  void _addCircuitRowBelow(int weekIndex, int dayIndex, int rowIndex) {
    setState(() {
      final colorToMaintain = getRowColor(rowIndex);

      // Insert one row below the current row
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

      // If needed, update any other structures like hint maps or saved state

      // Optionally scroll to the new row or give visual feedback
    });
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

      }
    }
    await Future.delayed(Duration(milliseconds: 100));
    setState(() {
      print("✅ Data loaded, triggering UI rebuild");
    });


    setState(() {});
  }



  Future<void> saveDayToFirestore(int weekIndex, int dayIndex) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final exercises = <Map<String, dynamic>>[];

    for (int i = 0; i < exercisesPerDay; i++) {
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
        .set({'exercises': exercises});

    print("✅ Saved day: week $weekIndex, day $dayIndex");
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
        )
            : 0.0;


        final double? e1rm = PeriodizationModelUtils.calculateE1RM(
          weight ?? (weightController.text.isEmpty ? hintWeight : null),
          reps?.toDouble() ?? (repsController.text.isEmpty ? hintReps.toDouble() : null),
          rir ?? (rirController.text.isEmpty ? 0.5 : null),
        );
//Colors.blueGrey.shade800,
        final bool isLastOfColor = _isLastOfColorBlock(rowIndex, dayIndex, weekIndex);
        return Container(
          height: isLastOfColor ? circuitEndRowHeight : exerciseRowHeight,

          padding: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: getRowColor(rowIndex),

            border: Border(
              bottom: BorderSide(color: Colors.blueGrey.shade700, width: 0.5),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,

            children: [
              // Exercise
              Expanded(
                flex: 3,
                child: GestureDetector(
                  onTap: () async {
                    final RenderBox box = context.findRenderObject() as RenderBox;
                    final Offset offset = box.localToGlobal(Offset.zero);
                    final RelativeRect position = RelativeRect.fromLTRB(
                      offset.dx,
                      offset.dy,
                      offset.dx + box.size.width,
                      offset.dy + box.size.height,
                    );

                    String? selected = await showMenu<String>(
                      context: context,
                      position: position,
                      items: groupedExercises.entries.expand((entry) {
                        final category = entry.key;
                        final exercises = entry.value;

                        return [
                          PopupMenuItem<String>(
                            enabled: false,
                            child: Text(
                              category,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          ...exercises.map((name) => PopupMenuItem<String>(
                            value: name,
                            child: Text(name, style: const TextStyle(fontSize: 13)),
                          )),
                        ];
                      }).toList(),

                    );

                    if (selected != null) {
                      localSetState(() {
                        exerciseSelection[weekIndex][dayIndex][rowIndex] = selected;
                        exerciseControllers[weekIndex][dayIndex][rowIndex].text = selected;

                        // Clear fields so that hintText logic can apply
                        repsControllers[weekIndex][dayIndex][rowIndex].clear();
                        weightControllers[weekIndex][dayIndex][rowIndex].clear();
                        rirControllers[weekIndex][dayIndex][rowIndex].clear(); //
                      });
                    }

                  },
                  child: Container(
                    width: 114,
                    height: 30,
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 3),
                    decoration: BoxDecoration(
                      color: getRowColor(rowIndex),
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(4.0),
                    ),
                    child: Text(
                      exerciseSelection[weekIndex][dayIndex][rowIndex] ?? 'Select Exercise',
                      style: const TextStyle(fontSize: 11, color: Colors.white),
                    ),
                  ),
                ),
              ),

              // Weight
              Expanded(
                flex: 2,
                child: TextField(
                  controller: weightController,
                  keyboardType: TextInputType.numberWithOptions(decimal: true),
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
                ),
              ),

              // Reps
              Expanded(
                flex: 1,
                child: TextField(
                  controller: repsController,
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
                ),
              ),

              // RIR
              Expanded(
                flex: 1,
                child: TextField(
                  controller: rirController,
                  keyboardType: TextInputType.numberWithOptions(decimal: true),
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
                ),
              ),

              // E1RM (as plain text for performance)
              // E1RM with Add Button
              Expanded(
                flex: 2,
                child: Container(
                  alignment: Alignment.center,
                  child: Stack(
                    children: [
                      // E1RM stays centered
                      Align(
                        alignment: Alignment.center,
                        child: Text(
                          e1rm != null && e1rm > 0 ? e1rm.toStringAsFixed(1) : '',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                      // Add button slightly below center (approx 5px below E1RM visually)
                      if (isLastOfColor)
                        Positioned(
                          top: (circuitEndRowHeight / 2) + 5, // Move 5px below vertical center
                          right: 0,
                          child: IconButton(
                            icon: const Icon(Icons.add_circle, size: 18, color: Colors.white70),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () {
                              _addCircuitRowBelow(weekIndex, dayIndex, rowIndex);
                            },
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
              crossAxisAlignment: CrossAxisAlignment.end, // ⬅️ Push contents to bottom
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
                              builder: (ctx) => AlertDialog(
                                title: const Text("Clear this day?"),
                                content: const Text("This will remove all exercises from this day."),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
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
                            position: RelativeRect.fromLTRB(100, 100, 200, 200),
                            items: templates.map((template) {
                              return PopupMenuItem<String>(
                                value: template.id,
                                child: Text(template.name),
                              );
                            }).toList(),
                          );

                          if (selectedTemplateId != null) {
                            setState(() {
                              selectedTemplateIds[weekIndex][dayIndex] = selectedTemplateId;
                              _populateExercisesFromTemplate(weekIndex, dayIndex, selectedTemplateId);
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
                              orElse: () => Template(id: '', name: 'Template', day: '', exercises: []),
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
                          foregroundColor: Colors.white, // 👈 Makes text white
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () {},
                        child: const Text("Notes", style: TextStyle(fontSize: 11)),
                      ),
                    ),
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
                        onPressed: () async {
                          // Now we can use await inside this block
                          final List<String> exercises = [];
                          for (int i = 0; i < exercisesPerDay; i++) {
                            final name = _getController(exerciseControllers, weekIndex, dayIndex, i).text.trim();
                            if (name.isNotEmpty) exercises.add(name);
                          }

                          final DateTime workoutDate = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
                          final String formattedWorkoutName =
                              "${DateFormat('EEE d MMM').format(workoutDate)} - Week ${weekIndex + 1}";

                          final result = await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => WorkoutPage(
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
                              final weight = entry['weight']?.toString() ?? '';
                              final reps = entry['reps']?.toString() ?? '';
                              final rir = entry['rir']?.toString() ?? '';

                              final exerciseController = _getController(exerciseControllers, weekIndex, dayIndex, i);
                              final weightController = _getController(weightControllers, weekIndex, dayIndex, i);
                              final repsController = _getController(repsControllers, weekIndex, dayIndex, i);
                              final rirController = _getController(rirControllers, weekIndex, dayIndex, i);

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
                      flex: 3,
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
              child: ListView.builder(
                physics: const BouncingScrollPhysics(),
                itemCount: exercisesPerDay,
                cacheExtent: 220,
                itemBuilder: (context, rowIndex) =>
                    _buildExerciseRow(weekIndex, dayIndex, rowIndex),
              ),
            ),


          ],
        ),
      ),
    );
  }




  Widget _buildWeek(int weekIndex) {
    return SizedBox(
      width: MediaQuery.of(context).size.width * 0.85,
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
