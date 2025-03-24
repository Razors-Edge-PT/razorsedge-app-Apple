import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'template_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class BlockBuilder2 extends StatefulWidget {
  const BlockBuilder2({super.key});

  @override
  State<BlockBuilder2> createState() => _BlockBuilder2State();
}

class _BlockBuilder2State extends State<BlockBuilder2> {
  final int initialWeeks = 12;
  final int exercisesPerDay = 11;
  List <Template> templates = []; // Make sure Template is imported
  List<List<String?>> selectedTemplateIds = [];
  late List<List<List<String?>>> exerciseSelection;
  List<List<List<TextEditingController>>> exerciseControllers = [];
  List<List<List<TextEditingController>>> weightControllers = [];
  List<List<List<TextEditingController>>> repsControllers = [];
  List<List<List<TextEditingController>>> rirControllers = [];
  List<List<List<TextEditingController>>> e1rmControllers = [];




  late DateTime selectedWeekMonday;
  late DateTime blockStartDate;

  final double exerciseRowHeight = 36; // 👈 Try 32–40 for compact rows

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

  @override
  void initState() {
    super.initState();
    selectedWeekMonday = _getMostRecentMonday();
    blockStartDate = _getMostRecentMonday();
    weekIndices = List.generate(initialWeeks, (index) => index);

    exerciseSelection = List.generate(
      initialWeeks,
          (_) => List.generate(7, (_) => List.filled(exercisesPerDay, null, growable: true)),
    );

    _fetchTemplates();
    selectedTemplateIds = List.generate(
      initialWeeks,
          (_) => List.generate(7, (_) => null),
    );
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
    final exerciseName = _getController(exerciseControllers, weekIndex, dayIndex, rowIndex).text;

    final weightController = _getController(weightControllers, weekIndex, dayIndex, rowIndex);
    final repsController = _getController(repsControllers, weekIndex, dayIndex, rowIndex);
    final rirController = _getController(rirControllers, weekIndex, dayIndex, rowIndex);

    // Calculate E1RM if all fields have input
    double? e1rm;
    if (weightController.text.isNotEmpty &&
        repsController.text.isNotEmpty &&
        rirController.text.isNotEmpty) {
      final weight = double.tryParse(weightController.text);
      final reps = int.tryParse(repsController.text);
      final rir = double.tryParse(rirController.text);

      if (weight != null && reps != null && rir != null) {
        // Simple E1RM formula (customize as needed)
        e1rm = weight * (1 + reps / 30) * (1 - rir * 0.03);
      }
    }

    return Container(
      height: exerciseRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade800,
        border: Border(
          bottom: BorderSide(color: Colors.blueGrey.shade700, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // Exercise name (text only for now)
          Expanded(
            flex: 3,
            child: Center(
              child: Text(
                exerciseName.isEmpty ? "Exercise ${rowIndex + 1}" : exerciseName,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                textAlign: TextAlign.center,
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
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
                hintText: "152.75",
                hintStyle: TextStyle(color: Colors.grey),
                border: InputBorder.none,
              ),
              onChanged: (_) => setState(() {}),
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
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
                hintText: "12",
                hintStyle: TextStyle(color: Colors.grey),
                border: InputBorder.none,
              ),
              onChanged: (_) => setState(() {}),
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
                hintText: "0.55",
                hintStyle: TextStyle(color: Colors.grey),
                border: InputBorder.none,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),

          // E1RM (read-only)
          Expanded(
            flex: 2,
            child: TextField(
              controller: TextEditingController(
                text: e1rm != null ? e1rm.toStringAsFixed(1) : '',
              ),
              readOnly: true,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
                border: InputBorder.none,
              ),
            ),
          ),
        ],
      ),
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
                    Text(
                      "Week ${weekIndex + 1}", // 🟡 Week label
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.white70,
                      ),
                    ),
                    Text(
                      dayLabel, // 🟡 Date label below it
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
                          foregroundColor: Colors.white, // 👈 Makes text white
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                          minimumSize: const Size(0, 30), // Adjust height to match image
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () {},
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
              height: 220, // Enough to show 6.5 rows
              child: ListView.builder(
                physics: const BouncingScrollPhysics(),
                itemCount: exercisesPerDay,
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
      appBar: AppBar(title: const Text("Block Builder 2.0")),
      body: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: weekIndices.map((i) => _buildWeek(i)).toList(),
          ),
        ),
      ),
    );
  }
}
