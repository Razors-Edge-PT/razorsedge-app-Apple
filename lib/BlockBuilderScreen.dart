

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'exercise_selection_screen.dart';
import 'template_model.dart';
import 'templates.dart';
import 'exercise_details_screen.dart';
import 'top_sets_screen.dart';
import 'workout_model.dart';
import 'periodization_model_utils.dart';

class BlockBuilderScreen extends StatefulWidget {
  const BlockBuilderScreen({super.key});


  @override
  _BlockBuilderScreenState createState() => _BlockBuilderScreenState();
}

class _BlockBuilderScreenState extends State<BlockBuilderScreen> {
  List<String> days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  List<String?> templateDropdownValues = List.filled(7, null);
  List<List<String?>> exerciseSelection = List.generate(7, (_) => List.generate(11, (_) => null, growable: true));
  List<String> savedExercises = [];
  List<List<String>> tableData = List.generate(11, (_) => List.generate(7, (_) => ''));
  List<String> weeks = ['Week 1', 'Week 2', 'Week 3', 'Week 4', 'Week 5', 'Week 6', 'Week 7'];
  List<Template> templates = [];
  List<List<double?>> weightValues = List.generate(7, (_) => List.generate(11, (_) => null, growable: true));
  List<List<int?>> repsValues = List.generate(7, (_) => List.generate(11, (_) => null, growable: true));
  List<List<double?>> rirValues = List.generate(7, (_) => List.generate(11, (_) => null, growable: true));
  bool _isLoadingData = true; // Tracks data loading

  List<int> _exerciseRowsPerDay = List.generate(7, (_) => 11); // Start with 11 rows per day
  Map<int, bool> _showAddRowButton = {}; // ✅ Track when to show button
  ScrollController _scrollController = ScrollController(); // ✅ Detect scrolling

  List<List<TextEditingController>> _repsControllers = [];
  List<List<TextEditingController>> _rirControllers = [];
  List<List<TextEditingController>> _weightControllers = [];


  @override
  void initState() {
    super.initState();

    // ✅ Initialize controllers for all exercises & make them growable
    _repsControllers = List.generate(7, (_) => List.generate(11, (_) => TextEditingController(), growable: true));
    _rirControllers = List.generate(7, (_) => List.generate(11, (_) => TextEditingController(), growable: true));
    _weightControllers = List.generate(7, (_) => List.generate(11, (_) => TextEditingController(), growable: true));
  }




  // ✅ Function to add a row for a specific day
  // ✅ Function to add a row for a specific day
  void _addRow(int index) {
    setState(() {
      // ✅ Increase row count for the specific day
      _exerciseRowsPerDay[index]++;

      print("Adding row at index: $index | Total rows now: ${_exerciseRowsPerDay[index]}"); // Debugging print

      // ✅ Expand lists dynamically to match the new row count
      exerciseSelection[index].add(null);
      _repsControllers[index].add(TextEditingController());
      _weightControllers[index].add(TextEditingController());
      _rirControllers[index].add(TextEditingController());

      // ✅ Debugging print to confirm the lengths of lists
      print("Updated Lists Lengths -> Exercises: ${exerciseSelection[index].length}, "
          "Reps: ${_repsControllers[index].length}, "
          "Weight: ${_weightControllers[index].length}, "
          "RIR: ${_rirControllers[index].length}");
    });
  }






  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _fetchSavedExercises();
    _fetchTemplates();
    _loadPreviousWorkoutData();
  }

  Future<void> _fetchSavedExercises() async {
    try {
      final querySnapshot = await FirebaseFirestore.instance.collection('exercises').get();
      final List<String> exercisesList = querySnapshot.docs.map((doc) => doc['name'] as String).toList();
      setState(() {
        savedExercises = exercisesList;
      });
    } catch (e) {
      print('Error fetching exercises: $e');
    }
  }

  Future<void> _fetchTemplates() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final userDoc = FirebaseFirestore.instance.collection('users').doc(user.uid);
      final templateSnapshot = await userDoc.collection('templates').get();
      final templateList = templateSnapshot.docs.map((doc) => Template(
        id: doc.id,
        name: doc.get('name'),
        day: doc.get('day'),
        exercises: List<String>.from(doc.get('exercises')),
      )).toList();
      setState(() {
        templates = templateList;
      });
    }
  }
  Future<void> _loadPreviousWorkoutData() async {
    await PeriodizationModelUtils.fetchLastWorkoutTopSetReps();
    setState(() {
      _isLoadingData = false; // ✅ Data is ready
    });
  }

  void _updateExerciseSelection(int dayIndex, String? templateId) {
    if (templateId != null) {
      final selectedTemplate = templates.firstWhere((t) => t.id == templateId, orElse: () => Template(id: '', name: '', day: '', exercises: []));
      setState(() {
        for (int i = 0; i < 11; i++) {
          exerciseSelection[dayIndex][i] = i < selectedTemplate.exercises.length ? selectedTemplate.exercises[i] : null;
        }
      });
    }
  }

  Color getRowColor(int rowIndex) {
    List<Color> rowColors = [
      Colors.grey.shade100, // Light grey,  // ✅ First 3 rows
      Colors.grey.shade300,  // ✅ Next 3 rows
      Colors.blueGrey.shade200, // ✅ Next 3 rows
      Colors.grey.shade300,
    ];

    return rowColors[(rowIndex ~/ 3) % rowColors.length]; // Cycles every 3 rows
  }

  @override
  void dispose() {
    for (var list in _repsControllers) {
      for (var controller in list) {
        controller.dispose();
      }
    }
    for (var list in _rirControllers) {
      for (var controller in list) {
        controller.dispose();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween, // ✅ Space title & reps
          children: [
            const Text(
              'Block Builder',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w500, // Medium weight
                fontStyle: FontStyle.italic, // Optional
              ),
            ), // ✅ Keep the existing title

            // ✅ Available Rep Targets based on the first selected exercise
            if (!_isLoadingData)
              FutureBuilder<List<int>>(
                future: Future.value(
                  PeriodizationModelUtils.getAvailableRepTargets(
                    exerciseSelection.isNotEmpty &&
                        exerciseSelection.any((day) => day.isNotEmpty && day[0] != null)
                        ? exerciseSelection.firstWhere((day) => day.isNotEmpty && day[0] != null)[0]! // ✅ Use the first valid selected exercise
                        : '',
                  ),
                ),
                builder: (context, snapshot) {
                  if (!snapshot.hasData || snapshot.data!.isEmpty) {
                    return SizedBox(); // ✅ Hide if no exercise selected or no reps available
                  }
                  return Row(
                    children: snapshot.data!.map((rep) {
                      return Container(
                        margin: EdgeInsets.symmetric(horizontal: 1),
                        padding: EdgeInsets.symmetric(vertical: 3, horizontal: 1),
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.grey),
                        ),
                        child: Text(
                          rep.toString(),
                          style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
          ],
        ),
      ),
    body: Scaffold(
    backgroundColor: Colors.black, // Optional: Set background color
    body: DefaultTextStyle(
    style: const TextStyle(color: Colors.white), // ✅ Set default text color to white
    child: ListView.builder(
        itemCount: 7,
        itemBuilder: (context, index) {
          return Card(
            color:  Colors.blueGrey.shade100, // ✅ Different colors for first 3 and next 3
            margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 0),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Day Label
                      Padding(
                        padding: const EdgeInsets.only(left: 1),
                        child: Text(
                          days[index],
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold,  color: Color(0xFF36454F), // ✅ Set text color to white
                          ),
                        ),
                      ),

                      const SizedBox(width: 5),

                      // Template Selection Dropdown
                      DropdownButton<String>(
                        value: templateDropdownValues[index],
                        items: templates.map((template) => DropdownMenuItem(
                          value: template.id,
                          child: Text(
                            template.name,
                            style: TextStyle(fontSize: 8), // Change this to any size you want
                          ),

                        )).toList(),
                        onChanged: (newValue) {
                          if (newValue != null) {
                            setState(() {
                              templateDropdownValues[index] = newValue;
                              _updateExerciseSelection(index, newValue);
                            });
                          }
                        },
                      ),

                      const SizedBox(width: 1),

                      // Exercise Selection Dropdown
                      GestureDetector(
                        onTap: () async {
                          String? selected = await showMenu<String>(
                            context: context,
                            position: RelativeRect.fromLTRB(100, 100, 200, 200),
                            items: savedExercises.isNotEmpty
                                ? savedExercises.map((String value) => PopupMenuItem<String>(
                              value: value,
                              child: Text(value, style: TextStyle(fontSize: 10)),
                            )).toList()
                                : [const PopupMenuItem(value: null, child: Text("No exercises available"))],
                          );
                          if (selected != null) {
                            setState(() {
                              exerciseSelection[index][0] = selected; // ✅ Update selection
                            });
                          }
                        },
                        child: Container(
                          width: 60,
                          height:25,
                          padding: EdgeInsets.all(3.0),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(4.0),
                          ),
                          child: Text(
                            exerciseSelection[index][0] ?? 'Select Exercise',
                            style: TextStyle(fontSize: 10, color: Color(0xFF2C3539)),
                          ),
                        ),
                      ),

                      const SizedBox(width: 10),

                      SizedBox(
                        width: 35, // ✅ Adjusted width to fit the number
                        height: 25,
                        child: TextField(
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            hintText: _isLoadingData || exerciseSelection[index][0] == null
                                ? '' // ✅ No hint while loading
                                : PeriodizationModelUtils.getSuggestedRepTarget(exerciseSelection[index][0]!).toString(), // ✅ Show suggested rep target
                            hintStyle: const TextStyle(
                              color: Colors.grey,
                              fontStyle: FontStyle.italic,
                              fontSize: 8,
                            ),
                            border: OutlineInputBorder(),
                          ),
                          style: TextStyle(fontSize: 10, color: Colors.black),
                        ),
                      ),

                    ],
                  ),


                  const SizedBox(height: 4),
                  SizedBox(
                    height: 150,
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          // ✅ Generate all rows dynamically
                          ListView.builder(
                              shrinkWrap: true,
                              physics: NeverScrollableScrollPhysics(),
                              itemCount: _exerciseRowsPerDay[index], // ✅ Uses the dynamically updated row count
                              itemBuilder: (context, rowIndex) {

                                return Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                GestureDetector(
                                  onTap: () async {
                                    String? selected = await showMenu<String>(
                                      context: context,
                                      position: RelativeRect.fromLTRB(100, 100, 200, 200),
                                      items: savedExercises.isNotEmpty
                                          ? savedExercises.map((String value) => PopupMenuItem<String>(
                                        value: value,
                                        child: Text(value, style: TextStyle(fontSize: 12)),
                                      ))
                                          .toList()
                                          : [const PopupMenuItem(value: null, child: Text("No exercises available"))],
                                    );
                                    if (selected != null) {
                                      setState(() {
                                        exerciseSelection[index][rowIndex] = selected;
                                      });
                                    }
                                  },
                                  child: Container(
                                    width: 120,
                                    height: 30,
                                    padding: EdgeInsets.all(4.0),
                                    decoration: BoxDecoration(
                                      color: getRowColor(rowIndex), // ✅ Assign color dynamically
                                      border: Border.all(color: Colors.grey),
                                      borderRadius: BorderRadius.circular(4.0),
                                    ),
                                    child: Text(
                                      exerciseSelection[index][rowIndex] ?? 'Select Exercise',
                                      style: TextStyle(fontSize: 11, color: Colors.black),
                                    ),
                                  ),
                                ),

                                // ✅ Weight Input Field
                                SizedBox(
                                  width: 60,
                                  height: 30,
                                  child: TextField(
                                    controller: _weightControllers[index][rowIndex],
                                    keyboardType: TextInputType.number,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                    decoration: InputDecoration(
                                      hintText: _isLoadingData || exerciseSelection[index][rowIndex] == null
                                          ? ''
                                          : PeriodizationModelUtils.getSuggestedWeight(
                                        exerciseSelection[index][rowIndex]!,
                                        _repsControllers[index][rowIndex],
                                        _rirControllers[index][rowIndex],
                                      ).toString(),
                                      hintStyle: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
                                      border: OutlineInputBorder(),
                                      filled: true,
                                      fillColor: getRowColor(rowIndex),
                                    ),
                                    onChanged: (value) {
                                      String exerciseName = exerciseSelection[index][rowIndex] ?? '';
                                      if (exerciseName.isNotEmpty) {
                                        _repsControllers[index][rowIndex].text = PeriodizationModelUtils.updateRepTarget(
                                          exerciseName,
                                          _weightControllers[index][rowIndex].text,
                                          _rirControllers[index][rowIndex].text,
                                        ).toString();
                                      }
                                      setState(() {});
                                    },
                                  ),
                                ),

                                const SizedBox(width: 5), // Space between boxes

                                // ✅ Reps Input Field
                                SizedBox(
                                  width: 50,
                                  height: 30,
                                  child: TextField(
                                    controller: _repsControllers[index][rowIndex],
                                    keyboardType: TextInputType.number,
                                    textAlign: TextAlign.center,
                                    decoration: InputDecoration(
                                      hintText: _isLoadingData || exerciseSelection[index][rowIndex] == null
                                          ? ''
                                          : PeriodizationModelUtils.getSuggestedRepTarget(exerciseSelection[index][rowIndex]!).toString(),
                                      border: OutlineInputBorder(),
                                      filled: true,
                                      fillColor: getRowColor(rowIndex),
                                    ),
                                    style: TextStyle(fontSize: 11),
                                    onChanged: (value) {
                                      String exerciseName = exerciseSelection[index][rowIndex] ?? '';
                                      if (exerciseName.isNotEmpty) {
                                        PeriodizationModelUtils.updateWeight(
                                          exerciseName,
                                          _weightControllers[index][rowIndex],
                                          _repsControllers[index][rowIndex],
                                          _rirControllers[index][rowIndex],
                                        );
                                      }
                                    },
                                  ),
                                ),

                                const SizedBox(width: 5),

                                // ✅ RIR Input Field
                                SizedBox(
                                  width: 45,
                                  height: 30,
                                  child: TextField(
                                    controller: _rirControllers[index][rowIndex],
                                    keyboardType: TextInputType.number,
                                    textAlign: TextAlign.center,
                                    decoration: InputDecoration(
                                      hintText: '0.5', // ✅ Default RIR value
                                      border: OutlineInputBorder(),
                                      filled: true,
                                      fillColor: getRowColor(rowIndex),
                                    ),
                                    style: TextStyle(fontSize: 10),
                                    onChanged: (value) {
                                      String exerciseName = exerciseSelection[index][rowIndex] ?? '';
                                      if (exerciseName.isNotEmpty) {
                                        PeriodizationModelUtils.updateWeight(
                                          exerciseName,
                                          _weightControllers[index][rowIndex],
                                          _repsControllers[index][rowIndex],
                                          _rirControllers[index][rowIndex],
                                        );
                                      }
                                    },
                                  ),
                                ),
                              ],
                            );
                          }),

                          // ✅ "+ Add Exercise" Button only appears after scrolling to last row
                          // ✅ "+ Add Exercise" Button only appears after scrolling to last row
                          // ✅ "+ Add Exercise" Button only appears after scrolling to last row
                          if (_exerciseRowsPerDay[index] > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 8.0),
                              child: Center(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    // ✅ Text Field for user input
                                    SizedBox(
                                      width: 100, // ✅ Adjust width as needed
                                      height: 30,
                                      child: TextField(
                                        decoration: InputDecoration(
                                          hintText: 'Enter here', // ✅ Placeholder text
                                          border: OutlineInputBorder(),
                                          contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                                        ),
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    ),

                                    const SizedBox(width: 8), // ✅ Space between text field and button

                                    // ✅ "+ Add Exercise" Button
                                    TextButton(
                                      onPressed: () {
                                        _addRow(index); // ✅ Now properly updates UI
                                        Future.delayed(Duration(milliseconds: 200), () {
                                          setState(() {}); // ✅ Forces a refresh
                                        });
                                      },
                                      child: Text("+ Add Exercise", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                        ],
                      ),
                    ),
                  ),


                ],
              ),
            ),
          );
        },
      ),
    ),
    ),
    );
  }
}

