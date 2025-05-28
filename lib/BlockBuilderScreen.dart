import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'template_model.dart';
import 'periodization_model_utils.dart';
// Import this for date formatting
import 'package:table_calendar/table_calendar.dart';


class BlockBuilderScreen extends StatefulWidget {
  const BlockBuilderScreen({super.key});


  @override
  _BlockBuilderScreenState createState() => _BlockBuilderScreenState();
}

class _BlockBuilderScreenState extends State<BlockBuilderScreen> {
  List<String> days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  List<List<String?>> templateDropdownValues = List.generate(52, (_) => List.filled(7, null, growable: true));
  List<List<List<String?>>> exerciseSelection = [];
  List<String> savedExercises = [];
  List<List<String>> tableData = List.generate(11, (_) => List.generate(7, (_) => ''));
  List<String> weeks = ['Week 1', 'Week 2', 'Week 3', 'Week 4', 'Week 5', 'Week 6', 'Week 7','Week 8'];
  List<Template> templates = [];
  List<List<double?>> weightValues = List.generate(7, (_) => List.generate(11, (_) => null, growable: true));
  List<List<int?>> repsValues = List.generate(7, (_) => List.generate(11, (_) => null, growable: true));
  List<List<double?>> rirValues = List.generate(7, (_) => List.generate(11, (_) => null, growable: true));
  bool _isLoadingData = true; // Tracks data loading
  List<int> addedWeeks = [];
  final List<int> _exerciseRowsPerDay = List.generate(12, (_) => 11); // ✅ Match 12 weeks
  final Map<int, bool> _showAddRowButton = {}; // ✅ Track when to show button
  final ScrollController _scrollController = ScrollController(); // ✅ Detect scrolling

  late DateTime selectedWeekMonday; // ✅ Declare without assigning

  List<List<TextEditingController>> _repsControllers = [];
  List<List<TextEditingController>> _rirControllers = [];
  List<List<TextEditingController>> _weightControllers = [];
  List<List<TextEditingController>>  _e1rmControllers = [];
  Map<String, List<Map<String, dynamic>>> topSetsByExercise = {};


  @override
  void initState() {
    super.initState();

    selectedWeekMonday = _getMostRecentMonday(); // ✅ Ensure it's initialized

    // ✅ Ensure `addedWeeks` has at least one element before using its length
    if (addedWeeks.isEmpty) {
      addedWeeks = List.generate(1, (index) => index); // ✅ Starts with 12 weeks (0 to 11)
    }
    loadTopSetsFromWorkouts(); // 🔥 Load top sets early


    // ✅ Ensure exerciseSelection initializes with 12 weeks
    exerciseSelection = List.generate(
      12, // 🔥 Set to 12 to match addedWeeks
          (_) => List.generate(7, (_) => List.generate(11, (_) => null, growable: true), growable: true),
      growable: true,
    );

    // ✅ Initialize controllers for all exercises
    _repsControllers = List.generate(12, (_) =>
        List.generate(11, (_) => TextEditingController(), growable: true));
    _rirControllers = List.generate(12, (_) =>
        List.generate(11, (_) => TextEditingController(), growable: true));
    _weightControllers = List.generate(12, (_) =>
        List.generate(11, (_) => TextEditingController(), growable: true));
    _e1rmControllers = List.generate(12, (_) =>
        List.generate(11, (_) => TextEditingController(), growable: true));

  }





  // ✅ Function to add a row for a specific day
  // ✅ Function to add a row for a specific day
  void _addRow(int weekIndex, int dayIndex) {
    setState(() {
      _exerciseRowsPerDay[dayIndex]++;

      print("Adding row at week: $weekIndex, day: $dayIndex | Total rows now: ${_exerciseRowsPerDay[dayIndex]}");

      // ✅ Expand list for the correct week and day
      exerciseSelection[weekIndex][dayIndex].add(null);
      _repsControllers[dayIndex].add(TextEditingController());
      _weightControllers[dayIndex].add(TextEditingController());
      _rirControllers[dayIndex].add(TextEditingController());

      print("Updated Lists Lengths -> Exercises: ${exerciseSelection[weekIndex][dayIndex].length}");
    });
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
  }


  DateTime _getMostRecentMonday() {
    DateTime now = DateTime.now();
    int daysSinceMonday = now.weekday - DateTime.monday;
    if (daysSinceMonday < 0) daysSinceMonday += 7; // Handles cases where today is Sunday
    return now.subtract(Duration(days: daysSinceMonday));
  }


  Future<DateTime?> _selectWeek(BuildContext context) async {
    DateTime focusedDay = selectedWeekMonday; // Start on selected Monday
    DateTime firstMonday = _getMostRecentMonday(); // Get current week's Monday

    return showDialog<DateTime>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900, // ✅ Change background color
          title: const Text(
            "Select a Week",
            style: TextStyle(color: Colors.white), // ✅ Title color
          ),
          content: StatefulBuilder(
            builder: (context, setDialogState) {
              return SizedBox(
                height: 400, // Adjust size for calendar
                child: TableCalendar(
                  firstDay: firstMonday, // Start from this week's Monday
                  lastDay: firstMonday.add(Duration(days: 365)), // Show a year ahead
                  focusedDay: focusedDay,
                  calendarFormat: CalendarFormat.month,
                  startingDayOfWeek: StartingDayOfWeek.monday, // Ensure Mondays are first
                  headerStyle: const HeaderStyle(
                    formatButtonVisible: false,
                    titleCentered: true,
                    titleTextStyle: TextStyle(color: Colors.white, fontSize: 18), // ✅ Header text color
                    leftChevronIcon: Icon(Icons.chevron_left, color: Colors.white),
                    rightChevronIcon: Icon(Icons.chevron_right, color: Colors.white),
                  ),
                  daysOfWeekStyle: const DaysOfWeekStyle(
                    weekdayStyle: TextStyle(color: Colors.white70), // ✅ Days row color
                    weekendStyle: TextStyle(color: Colors.white70),
                  ),
                  calendarStyle: CalendarStyle(
                    defaultTextStyle: const TextStyle(color: Colors.white), // ✅ Default day color
                    weekendTextStyle: const TextStyle(color: Colors.white70),
                    outsideDaysVisible: false, // Hide outside month days
                    todayDecoration: BoxDecoration(
                      color: Colors.blueGrey.shade600, // ✅ Slightly different shade from other days
                      borderRadius: BorderRadius.circular(8), // ✅ Match other elements
                      border: Border.all(
                        color: Colors.blueGrey.shade700, // ✅ Border color for visibility
                        width: 1,
                      ),
                    ),

                    selectedDecoration: BoxDecoration(
                      color: Colors.blueGrey.shade800, // ✅ Unified background color for selected days
                      shape: BoxShape.rectangle,
                      borderRadius: BorderRadius.circular(8), // ✅ Optional: Rounded corners for consistency
                      border: Border.all(
                        color: Colors.amberAccent, // ✅ Same amber border as other selected days
                        width: 2, // ✅ Match the width of other selected days
                      ),
                    ),



                  ),
                  calendarBuilders: CalendarBuilders(
                    defaultBuilder: (context, date, _) {
                      // ✅ Check if the date belongs to the currently selected Monday's row
                      bool isInSelectedWeek = date
                          .difference(selectedWeekMonday)
                          .inDays >= 0 && // Not before the selected Monday
                          date.difference(selectedWeekMonday).inDays < 7; // Within the same week row

                      return GestureDetector(
                        onTap: () {
                          // ✅ When any day is tapped, find the Monday of that week and select it
                          Navigator.pop(context, date.subtract(Duration(days: date.weekday - 1)));
                        },
                        child: Container(
                          margin: const EdgeInsets.all(4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.blueGrey.shade800, // ✅ Unified background color
                            borderRadius: BorderRadius.circular(8),
                            border: isInSelectedWeek
                                ? Border.all(
                              color: Colors.amberAccent, // ✅ Same amber border for all selected week days
                              width: 2,
                            )
                                : null,
                          ),
                          child: Text(
                            '${date.day}',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: isInSelectedWeek ? FontWeight.bold : FontWeight.normal, // ✅ Highlight selected week days
                            ),
                          ),
                        ),
                      );
                    },
                  ),


                ),
              );
            },
          ),
        );
      },
    );
  }



  void showAddNotesDialog(BuildContext context) {
    TextEditingController weightController = TextEditingController();
    TextEditingController sleepHoursController = TextEditingController();
    TextEditingController caloriesController = TextEditingController();
    TextEditingController notesController = TextEditingController();
    double sleepQuality = 5; // Default middle value for sleep quality

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900, // ✅ Matches calendar theme
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          title: Text(
            "Add Notes",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          content: StatefulBuilder(
            builder: (context, setState) {
              return SingleChildScrollView( // ✅ Enables scrolling to prevent overflow
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ✅ Body Weight Field
                    Row(
                      children: [
                        SizedBox(
                          width: 120,
                          height: 35,
                          child: TextField(
                            controller: weightController,
                            keyboardType: TextInputType.numberWithOptions(decimal: true),
                            decoration: InputDecoration(
                              labelText: "Body Weight",
                              labelStyle: TextStyle(color: Colors.white70),
                              border: OutlineInputBorder(),
                              filled: true,
                              fillColor: Colors.blueGrey.shade800,
                              contentPadding: EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                            ),
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                        SizedBox(width: 8),
                        Text("Kg", style: TextStyle(color: Colors.white, fontSize: 14)),
                      ],
                    ),
                    SizedBox(height: 8),

                    // ✅ Calories Field
                    Row(
                      children: [
                        SizedBox(
                          width: 120,
                          height: 35,
                          child: TextField(
                            controller: caloriesController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: "Calories",
                              labelStyle: TextStyle(color: Colors.white70),
                              border: OutlineInputBorder(),
                              filled: true,
                              fillColor: Colors.blueGrey.shade800,
                              contentPadding: EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                            ),
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                        SizedBox(width: 8),
                        Text("Kcal", style: TextStyle(color: Colors.white, fontSize: 14)),
                      ],
                    ),
                    SizedBox(height: 8),

                    // ✅ Sleep Hours Field
                    Row(
                      children: [
                        SizedBox(
                          width: 120,
                          height: 35,
                          child: TextField(
                            controller: sleepHoursController,
                            keyboardType: TextInputType.numberWithOptions(decimal: true),
                            decoration: InputDecoration(
                              labelText: "Sleep Hours",
                              labelStyle: TextStyle(color: Colors.white70),
                              border: OutlineInputBorder(),
                              filled: true,
                              fillColor: Colors.blueGrey.shade800,
                              contentPadding: EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                            ),
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                        SizedBox(width: 8),
                        Text("hrs", style: TextStyle(color: Colors.white, fontSize: 14)),
                      ],
                    ),
                    SizedBox(height: 15),

                    // ✅ Sleep Quality Slider (1-10)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Sleep Quality", style: TextStyle(color: Colors.white70, fontSize: 14)),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text("Poor", style: TextStyle(color: Colors.white54, fontSize: 12)),
                            Expanded(
                              child: Slider(
                                value: sleepQuality,
                                min: 1,
                                max: 10,
                                divisions: 9,
                                label: sleepQuality.round().toString(),
                                activeColor: Colors.amberAccent,
                                onChanged: (value) {
                                  setState(() {
                                    sleepQuality = value;
                                  });
                                },
                              ),
                            ),
                            Text("Great", style: TextStyle(color: Colors.white54, fontSize: 12)),
                          ],
                        ),
                      ],
                    ),
                    SizedBox(height: 8),

                    // ✅ Notes Field (Scrollable)
                    SizedBox(
                      width: double.infinity,
                      height: 200, // ✅ Allows scrolling inside
                      child: SingleChildScrollView(
                        scrollDirection: Axis.vertical,
                        child: TextField(
                          controller: notesController,
                          keyboardType: TextInputType.multiline,
                          maxLines: null,
                          decoration: InputDecoration(
                            labelText: "Notes",
                            labelStyle: TextStyle(color: Colors.white70),
                            border: OutlineInputBorder(),
                            filled: true,
                            fillColor: Colors.blueGrey.shade800,
                            contentPadding: EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                          ),
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              );

            },
          ),
          actions: [
            // ✅ Cancel Button
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("Cancel", style: TextStyle(color: Colors.white70)),
            ),

            // ✅ Save Button
            TextButton(
              onPressed: () {
                // ✅ Save the data (implement storage logic)
                Navigator.pop(context);
              },
              child: Text("Save", style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }



  Widget buildWeekWidget(int weekIndex, int dayIndex) {
    DateTime currentDayDate = selectedWeekMonday.add(Duration(days: weekIndex * 7 + dayIndex));

    return Row(
      children: [
        // ✅ Correct Day & Date (Each row will now have its own date)
        Container(
          width: 119,
          padding: EdgeInsets.symmetric(vertical: 2, horizontal: 8),
          margin: EdgeInsets.only(right: 5),
          decoration: BoxDecoration(
            color: Colors.blueGrey.shade800,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '${days[dayIndex].substring(0, 3)} ${DateFormat('d MMM y').format(currentDayDate)}',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),

        const SizedBox(width: 5),

        // ✅ Select Template
        GestureDetector(
          onTap: () async {
            String? selectedTemplate = await showMenu<String>(
              context: context,
              position: RelativeRect.fromLTRB(100, 100, 200, 200),
              items: templates.isNotEmpty
                  ? templates.map((template) => PopupMenuItem<String>(
                value: template.id,
                child: Text(
                  template.name,
                  style: TextStyle(fontSize: 10),
                ),
              ))
                  .toList()
                  : [const PopupMenuItem(value: null, child: Text("No templates available"))],
            );

            if (selectedTemplate != null) {
              setState(() {
                templateDropdownValues[weekIndex][dayIndex] = selectedTemplate;

                _updateExerciseSelection(weekIndex, dayIndex, selectedTemplate);
              });
            }
          },
          child: Container(
            width: 99,
            height: 25,
            padding: EdgeInsets.symmetric(vertical: 2, horizontal: 4),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey),
              borderRadius: BorderRadius.circular(6.0),
              color: Colors.blueGrey.shade500,
            ),
            child:Text(
              (templateDropdownValues[weekIndex][dayIndex] != null)
                  ? templates.firstWhere(
                    (template) => template.id == templateDropdownValues[weekIndex][dayIndex],
                orElse: () => Template(id: '', name: 'Select Template', day: '', exercises: []),
              ).name
                  : 'Select Template',
              style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),

          ),
        ),

        const SizedBox(width: 5),

        // ✅ Add Notes
        GestureDetector(
          onTap: () {
            showAddNotesDialog(context);
          },
          child: Container(
            width: 55,
            height: 25,
            padding: EdgeInsets.symmetric(vertical: 6, horizontal: 5),
            decoration: BoxDecoration(
              color: Colors.blueGrey.shade800,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                "Notes",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ],
    );
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

      final templateList = templateSnapshot.docs.map((doc) {
        final rawExercises = doc.get('exercises');

        // Support both formats: List<String> and List<Map<String, dynamic>>
        final parsedExercises = rawExercises is List && rawExercises.isNotEmpty
            ? (rawExercises.first is Map
            ? List<Map<String, dynamic>>.from(rawExercises)
            : List<Map<String, dynamic>>.from(
            rawExercises.map((e) => {'name': e, 'circuitIndex': 0})))
            : <Map<String, dynamic>>[];

        return Template(
          id: doc.id,
          name: doc.get('name'),
          day: doc.data().containsKey('day') ? doc.get('day') : null,
          exercises: parsedExercises,
        );
      }).toList();

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

  void _updateExerciseSelection(int weekIndex, int dayIndex, String? templateId) {
    if (templateId != null) {
      final selectedTemplate = templates.firstWhere(
            (t) => t.id == templateId,
        orElse: () => Template(id: '', name: '', day: '', exercises: []),
      );

      // ✅ Ensure exerciseSelection is initialized before accessing indices
      if (exerciseSelection.isEmpty ||
          weekIndex >= exerciseSelection.length ||
          dayIndex >= exerciseSelection[weekIndex].length) {
        debugPrint("Error: exerciseSelection[$weekIndex][$dayIndex] is null or out of bounds!");
        return;
      }

      setState(() {
        for (int i = 0; i < 11; i++) {
          if (i < selectedTemplate.exercises.length) {
            final entry = selectedTemplate.exercises[i];
            final name = entry is String ? entry : entry['name'];
            exerciseSelection[weekIndex][dayIndex][i] = name;
          } else {
            exerciseSelection[weekIndex][dayIndex][i] = null;
          }
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

  int getExercisePlannedCountBefore(String exerciseName, int weekIndex, int dayIndex, int rowIndex) {
    int count = 0;

    for (int w = 0; w <= weekIndex; w++) {
      for (int d = 0; d < 7; d++) {
        if (w == weekIndex && d > dayIndex) break;

        for (int r = 0; r < 11; r++) {
          if (w == weekIndex && d == dayIndex && r >= rowIndex) break;

          if (exerciseSelection[w][d][r] == exerciseName) {
            count++;
          }
        }
      }
    }

    return count;
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

          ],
        ),
      ),
      body: Scaffold(
        backgroundColor: Colors.black, // Optional: Set background color
        body: DefaultTextStyle(
          style: const TextStyle(color: Colors.white), // ✅ Set default text color to white

          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ✅ Display today's date above everything
              Padding(
                padding: const EdgeInsets.all(7.0),
                child: Text(
                  DateFormat.yMMMMd().format(DateTime.now()), // E.g., "March 6, 2025"
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white, // ✅ Adjust color if needed
                  ),
                ),
              ),

              // ✅ The main ListView
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal, // ✅ Ensures all weeks scroll together
                  child: Row(
                    mainAxisSize: MainAxisSize.min, // ✅ Allows Row to expand naturally
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.start, // ✅ Moves content to the left
                    children: List.generate(addedWeeks.length + 1, (weekIndex) {
                      return SizedBox(
                        width: MediaQuery.of(context).size.width * 0.85, // ✅ Adjust width to fit content properly
                        child: Column(
                          children: [
                            // ✅ Add Week Button (Appears only in the first row, after Monday)
                            if (weekIndex == addedWeeks.length)
                              const SizedBox(height: 0), // ✅ Keeps spacing intact


                            // ✅ Allow full vertical scrolling for all days
                            Expanded(
                              child: SingleChildScrollView(
                                child: Align( // ✅ Aligns everything inside to the left
                                  alignment: Alignment.centerLeft, // ✅ Forces it to the left
                                  child: Column(
                                    children: List.generate(7, (dayIndex) {
                                      return SizedBox(
                                        width: MediaQuery.of(context).size.width * 0.85, // ✅ Increase width by 5%

                                        child: Card(
                                          color: Colors.blueGrey.shade200,
                                          margin: const EdgeInsets.symmetric(vertical: 1, horizontal:1),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(2), // 🔽 Reduce the rounding (change value)
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.all(6.0),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                // ✅ Show Date Picker & Week Label only on first week
                                                if (dayIndex == 0)
                                                  Padding(
                                                    padding: const EdgeInsets.only(bottom: 3, top: 3),
                                                    child: Row(
                                                      crossAxisAlignment: CrossAxisAlignment.center,
                                                      children: [
                                                        // ✅ Only show the date picker in the first week
                                                        if (weekIndex == 0)
                                                          GestureDetector(
                                                            onTap: () async {
                                                              DateTime? newDate = await _selectWeek(context);
                                                              if (newDate != null) {
                                                                setState(() {
                                                                  selectedWeekMonday = newDate;
                                                                });
                                                              }
                                                            },
                                                            child: Container(
                                                              width: 140, // ✅ Ensure consistent width
                                                              padding: const EdgeInsets.symmetric(vertical:2, horizontal: 10),
                                                              decoration: BoxDecoration(
                                                                color: Color(0xFFDDE3E6),
                                                                borderRadius: BorderRadius.circular(6),
                                                                border: Border.all(color: Colors.grey),
                                                              ),
                                                              child: Row(
                                                                mainAxisSize: MainAxisSize.min,
                                                                children: [
                                                                  Text(
                                                                    DateFormat.yMMMMd().format(selectedWeekMonday),
                                                                    style: const TextStyle(
                                                                      fontSize: 12,
                                                                      fontWeight: FontWeight.bold,
                                                                      color: Colors.black,
                                                                    ),
                                                                  ),
                                                                  const SizedBox(width: 5),
                                                                  const Icon(Icons.calendar_today, size: 14, color: Colors.black),
                                                                ],
                                                              ),
                                                            ),
                                                          )
                                                        else
                                                          SizedBox(width: 4), // ✅ Placeholder to maintain alignment across weeks

                                                        const SizedBox(width: 8), // ✅ Space between picker & label
                                                        // ✅ "Week X" Label (Appears in every Monday column)
                                                        SizedBox(
                                                          width: 99, // ✅ Matches template selector width
                                                          height: 25, // ✅ Matches template selector height
                                                          child: Container(
                                                            padding: EdgeInsets.symmetric(vertical: 2, horizontal: 4), // ✅ Consistent padding
                                                            decoration: BoxDecoration(
                                                              border: Border.all(color: Colors.grey), // ✅ Matches the template selector border
                                                              borderRadius: BorderRadius.circular(6.0), // ✅ Rounded corners for consistency
                                                              color: Colors.blueGrey.shade500, // ✅ Background color same as template selector
                                                            ),
                                                            child: Center(
                                                              child: Text(
                                                                "Week ${weekIndex + 1}",
                                                                style: const TextStyle(
                                                                  fontSize: 13,
                                                                  fontWeight: FontWeight.bold,
                                                                  color: Colors.white, // ✅ Matches the template selector text color
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),

                                                        const SizedBox(width:5), // ✅ Space between picker & label
                                                        // ✅ "+ Add Week" Button (Only on Monday, last week)
                                                        if (dayIndex == 0 && weekIndex == addedWeeks.length)
                                                          Padding(
                                                            padding: const EdgeInsets.symmetric(vertical: 1),
                                                            child: GestureDetector(
                                                              onTap: () {
                                                                setState(() {
                                                                  int nextWeekIndex = addedWeeks.isNotEmpty ? addedWeeks.last + 1 : 1;
                                                                  addedWeeks.add(nextWeekIndex);

                                                                  // ✅ Ensure new week has 7 days, each with 11 exercise slots
                                                                  for (int i = 0; i < 7; i++) {
                                                                    exerciseSelection.add(List.generate(7, (_) => List.generate(11, (_) => null, growable: true), growable: true));
                                                                    _repsControllers.add(List.generate(11, (_) => TextEditingController()));
                                                                    _weightControllers.add(List.generate(11, (_) => TextEditingController()));
                                                                    _rirControllers.add(List.generate(11, (_) => TextEditingController()));
                                                                    _e1rmControllers.add(List.generate(11, (_) => TextEditingController()));

                                                                    _exerciseRowsPerDay.add(11);
                                                                  }
                                                                });
                                                              },
                                                              child: Container(
                                                                width: 75,
                                                                height: 20,
                                                                padding: EdgeInsets.symmetric(vertical: 2, horizontal: 5),
                                                                decoration: BoxDecoration(
                                                                  color: Colors.blueGrey.shade800,
                                                                  borderRadius: BorderRadius.circular(8),
                                                                ),
                                                                child: Center(
                                                                  child: Text(
                                                                    "+ Add Week",
                                                                    textAlign: TextAlign.center,
                                                                    style: TextStyle(
                                                                      color: Colors.white,
                                                                      fontSize: 10,
                                                                      fontWeight: FontWeight.bold,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          ),

                                                        const SizedBox(height: 6),
                                                      ],
                                                    ),
                                                  ),

                                                // ✅ Week Widget (Template, Notes, etc.)
                                                buildWeekWidget(weekIndex, dayIndex),

                                                const SizedBox(height: 6),

                                                // ✅ HEADER ROW (Weight, Reps, RIR, E1RM)
                                                Row(
                                                  crossAxisAlignment: CrossAxisAlignment.center,
                                                  mainAxisAlignment: MainAxisAlignment.start, // ✅ Aligns with exercise fields
                                                  children: [
                                                    const SizedBox(width: 115), // ✅ Align with exercise selection

                                                    const SizedBox(width: 3), // Space before Weight field
                                                    SizedBox(
                                                      width: 49, // ✅ Matches Weight field
                                                      child: Text(
                                                        'Weight',
                                                        textAlign: TextAlign.center,
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.bold,
                                                          color: Colors.blueGrey.shade800,
                                                        ),
                                                      ),
                                                    ),

                                                    const SizedBox(width: 3), // Space before Reps field
                                                    SizedBox(
                                                      width: 37, // ✅ Matches Reps field
                                                      child: Text(
                                                        'Reps',
                                                        textAlign: TextAlign.center,
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.bold,
                                                          color: Colors.blueGrey.shade800,
                                                        ),
                                                      ),
                                                    ),

                                                    const SizedBox(width: 2), // Space before RIR field
                                                    SizedBox(
                                                      width: 30, // ✅ Matches RIR field
                                                      child: Text(
                                                        'RIR',
                                                        textAlign: TextAlign.center,
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.bold,
                                                          color: Colors.blueGrey.shade800,
                                                        ),
                                                      ),
                                                    ),

                                                    const SizedBox(width: 2), // Space before E1RM field
                                                    SizedBox(
                                                      width: 48, // ✅ Matches E1RM field
                                                      child: Text(
                                                        'E1RM',
                                                        textAlign: TextAlign.center,
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.bold,
                                                          color: Colors.blueGrey.shade800,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),


                                                const SizedBox(height: 2),

                                                // ✅ Exercise Table (Scrolls Vertically)
                                                SizedBox(
                                                  height: 200,
                                                  child: SingleChildScrollView(
                                                    child: Column(
                                                      children: List.generate(_exerciseRowsPerDay[dayIndex], (rowIndex) {
                                                        return Row(
                                                          crossAxisAlignment: CrossAxisAlignment.center,
                                                          children: [
                                                            // ✅ Exercise Selection
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
                                                                    exerciseSelection[weekIndex][dayIndex][rowIndex]  = selected;
                                                                  });
                                                                }
                                                              },
                                                              child: Container(
                                                                width: 114,
                                                                height: 30,
                                                                padding: EdgeInsets.symmetric(vertical: 4, horizontal: 3),
                                                                decoration: BoxDecoration(
                                                                  color: getRowColor(rowIndex),
                                                                  border: Border.all(color: Colors.grey),
                                                                  borderRadius: BorderRadius.circular(4.0),
                                                                ),
                                                                child: Text(
                                                                  exerciseSelection[weekIndex][dayIndex][rowIndex] ?? 'Select Exercise',

                                                                  style: TextStyle(fontSize: 11, color: Colors.black),
                                                                ),
                                                              ),
                                                            ),

                                                            const SizedBox(width: 3),

                                                            // ✅ Weight Input Field
                                                            SizedBox(
                                                              width: 49,
                                                              height: 30,
                                                              child: TextField(
                                                                controller: _weightControllers[dayIndex][rowIndex],
                                                                keyboardType: TextInputType.number,
                                                                textAlign: TextAlign.center,
                                                                style: TextStyle(
                                                                  fontSize: 12,
                                                                  fontWeight: FontWeight.bold,
                                                                  color: _weightControllers[dayIndex][rowIndex].text.isEmpty ? Colors.grey : Colors.black, // ✅ Grey for hint, black for input
                                                                ),
                                                                decoration: InputDecoration(
                                                                  contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 2), // ✅ Reduces padding to fit larger numbers
                                                                  hintText: (_weightControllers.length > dayIndex &&
                                                                      _weightControllers[dayIndex].length > rowIndex &&
                                                                      _weightControllers[dayIndex][rowIndex].text.isEmpty &&
                                                                      exerciseSelection.length > weekIndex &&
                                                                      exerciseSelection[weekIndex].length > dayIndex &&
                                                                      exerciseSelection[weekIndex][dayIndex].length > rowIndex &&
                                                                      exerciseSelection[weekIndex][dayIndex][rowIndex] != null)
                                                                      ? PeriodizationModelUtils.getSuggestedWeight(
                                                                    exerciseSelection[weekIndex][dayIndex][rowIndex]!,
                                                                    _repsControllers[dayIndex][rowIndex],
                                                                    _rirControllers[dayIndex][rowIndex],
                                                                    getExercisePlannedCountBefore(
                                                                      exerciseSelection[weekIndex][dayIndex][rowIndex]!,
                                                                      weekIndex,
                                                                      dayIndex,
                                                                      rowIndex,
                                                                    ),
                                                                    topSetsByExercise, // 🔥 new argument
                                                                  ).toStringAsFixed(1)
                                                                  // ✅ Only show hint if weight field is empty
                                                                      : '',
                                                                  hintStyle: const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic, fontSize: 12),
                                                                  border: OutlineInputBorder(),
                                                                  filled: true,
                                                                  fillColor: getRowColor(rowIndex),
                                                                ),

                                                                onChanged: (value) {
                                                                  String exerciseName = exerciseSelection[weekIndex][dayIndex][rowIndex] ?? '';
                                                                  if (exerciseName.isNotEmpty) {
                                                                    // ✅ When weight changes, trigger UI update for reps hint (without overriding user input)
                                                                    setState(() {});
                                                                  }
                                                                },
                                                              ),
                                                            ),

                                                            const SizedBox(width: 3),

// ✅ Reps Input Field
                                                            SizedBox(
                                                              width: 37,
                                                              height: 30,
                                                              child: TextField(
                                                                controller: _repsControllers[dayIndex][rowIndex],
                                                                keyboardType: TextInputType.number,
                                                                textAlign: TextAlign.center,
                                                                style: TextStyle(
                                                                  fontSize: 12,
                                                                  fontWeight: FontWeight.bold,
                                                                  color: _repsControllers[dayIndex][rowIndex].text.isNotEmpty ? Colors.black : Colors.grey, // ✅ Black for input, Grey for hint
                                                                ),
                                                                decoration: InputDecoration(
                                                                  contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                                                                  hintText: (_repsControllers.asMap().containsKey(dayIndex) &&
                                                                      _repsControllers[dayIndex].asMap().containsKey(rowIndex) &&
                                                                      _repsControllers[dayIndex][rowIndex].text.isEmpty &&
                                                                      exerciseSelection.asMap().containsKey(weekIndex) &&
                                                                      exerciseSelection[weekIndex].asMap().containsKey(dayIndex) &&
                                                                      exerciseSelection[weekIndex][dayIndex].asMap().containsKey(rowIndex) &&
                                                                      exerciseSelection[weekIndex][dayIndex][rowIndex] != null)
                                                                      ? PeriodizationModelUtils.updateRepTarget(
                                                                    exerciseSelection[weekIndex][dayIndex][rowIndex]!,
                                                                    (_weightControllers.asMap().containsKey(dayIndex) &&
                                                                        _weightControllers[dayIndex].asMap().containsKey(rowIndex))
                                                                        ? _weightControllers[dayIndex][rowIndex].text
                                                                        : "0",
                                                                    (_rirControllers.asMap().containsKey(dayIndex) &&
                                                                        _rirControllers[dayIndex].asMap().containsKey(rowIndex))
                                                                        ? _rirControllers[dayIndex][rowIndex].text
                                                                        : "0",
                                                                    getExercisePlannedCountBefore(
                                                                      exerciseSelection[weekIndex][dayIndex][rowIndex]!,
                                                                      weekIndex,
                                                                      dayIndex,
                                                                      rowIndex,
                                                                    ),
                                                                  ).toString()
                                                                      : '',

                                                                  hintStyle: const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic, fontSize: 12),
                                                                  border: OutlineInputBorder(),
                                                                  filled: true,
                                                                  fillColor: getRowColor(rowIndex),
                                                                ),

                                                                onChanged: (value) {
                                                                  String exerciseName = exerciseSelection[weekIndex][dayIndex][rowIndex] ?? '';
                                                                  if (exerciseName.isNotEmpty) {
                                                                    if (_weightControllers[dayIndex][rowIndex].text.isEmpty) {
                                                                      setState(() {}); // ✅ Refresh UI to update hint text for weight
                                                                    }
                                                                  }
                                                                  setState(() {}); // ✅ Ensures UI refresh for user input
                                                                },
                                                              ),
                                                            ),

                                                            const SizedBox(width: 3),

// ✅ RIR Input Field
                                                            SizedBox(
                                                              width: 30,
                                                              height: 30,
                                                              child: TextField(
                                                                controller: _rirControllers[dayIndex][rowIndex],
                                                                keyboardType: TextInputType.number,
                                                                textAlign: TextAlign.center,
                                                                style: TextStyle(
                                                                  fontSize: 11,
                                                                  fontWeight: FontWeight.bold,
                                                                  color: _rirControllers[dayIndex][rowIndex].text.isNotEmpty ? Colors.black : Colors.grey, // ✅ Black for input, Grey for hint
                                                                ),
                                                                decoration: InputDecoration(
                                                                  contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                                                                  hintText: _rirControllers[dayIndex][rowIndex].text.isEmpty ? "0.5" : '', // ✅ Default RIR hint
                                                                  hintStyle: const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic, fontSize: 10),
                                                                  border: OutlineInputBorder(),
                                                                  filled: true,
                                                                  fillColor: getRowColor(rowIndex),
                                                                ),
                                                                onChanged: (value) {
                                                                  String exerciseName = exerciseSelection[weekIndex][dayIndex][rowIndex] ?? '';
                                                                  if (exerciseName.isNotEmpty) {
                                                                    if (_weightControllers[dayIndex][rowIndex].text.isEmpty || _repsControllers[dayIndex][rowIndex].text.isEmpty) {
                                                                      setState(() {}); // ✅ Refresh UI
                                                                    }
                                                                  }
                                                                  setState(() {}); // ✅ Ensures UI refresh when RIR changes
                                                                },
                                                              ),
                                                            ),

                                                            const SizedBox(width: 3),

// ✅ E1RM Read-Only Field
                                                            SizedBox(
                                                              width: 48,
                                                              height: 30,
                                                              child: TextField(
                                                                controller: TextEditingController(
                                                                  text: PeriodizationModelUtils.calculateE1RM(
                                                                    double.tryParse(_weightControllers[dayIndex][rowIndex].text) ??
                                                                        PeriodizationModelUtils.getSuggestedWeight(
                                                                          exerciseSelection[weekIndex][dayIndex][rowIndex] ?? '',
                                                                          _repsControllers[dayIndex][rowIndex],
                                                                          _rirControllers[dayIndex][rowIndex],
                                                                          getExercisePlannedCountBefore(
                                                                            exerciseSelection[weekIndex][dayIndex][rowIndex] ?? '',
                                                                            weekIndex,
                                                                            dayIndex,
                                                                            rowIndex,
                                                                          ),
                                                                          topSetsByExercise, // 🔥 new argument
                                                                        ),
                                                                    (int.tryParse(_repsControllers[dayIndex][rowIndex].text) ??
                                                                        PeriodizationModelUtils.updateRepTarget(
                                                                          exerciseSelection[weekIndex][dayIndex][rowIndex] ?? '',
                                                                          _weightControllers[dayIndex][rowIndex].text,
                                                                          _rirControllers[dayIndex][rowIndex].text,
                                                                          getExercisePlannedCountBefore(
                                                                            exerciseSelection[weekIndex][dayIndex][rowIndex] ?? '',
                                                                            weekIndex,
                                                                            dayIndex,
                                                                            rowIndex,
                                                                          ),
                                                                        )
                                                                    ).toDouble(),

                                                                    double.tryParse(_rirControllers[dayIndex][rowIndex].text) ?? 0.5,
                                                                  ).toStringAsFixed(1),

                                                                ),
                                                                readOnly: true, // ✅ Prevents user input
                                                                textAlign: TextAlign.center,
                                                                style: TextStyle(
                                                                  fontSize: 10,
                                                                  fontWeight: FontWeight.bold,
                                                                  color: (_weightControllers[dayIndex][rowIndex].text.isNotEmpty ||
                                                                      _repsControllers[dayIndex][rowIndex].text.isNotEmpty ||
                                                                      _rirControllers[dayIndex][rowIndex].text.isNotEmpty)
                                                                      ? Colors.black
                                                                      : Colors.grey, // ✅ Grey for hint, black for calculated values
                                                                ),
                                                                decoration: InputDecoration(
                                                                  contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                                                                  border: OutlineInputBorder(),
                                                                  filled: true,
                                                                  fillColor: getRowColor(rowIndex),
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        );
                                                      }),

                                                    ),

                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    }),

                                  ),
                                ),
                              ),

                            ),
                            //this is where I must put the button, before this bracket
                          ],
                        ),
                      );
                    }),
                  ),
                ),
              ),

            ],
          ),
        ),
      ),
    );

  }
}