import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'template_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'workout_entry_screen.dart';
import 'periodization_model_utils.dart';
import 'core_exercises.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'periodization_model_utils.dart';



class Block_Planner extends StatefulWidget {
  const Block_Planner({super.key});

  @override
  State<Block_Planner> createState() => _BlockPlannerState();


}

class _BlockPlannerState extends State<Block_Planner> {
  // Example list of tracked exercises
  List<String> exercises = [];
  Map<String, String> _exerciseIdToName = {}; // id ➔ name
  DateTime? _blockStartDate;
  DateTime? _blockEndDate;
  Map<String, dynamic> exerciseRepTargets = {};
  Map<String, dynamic> plannedExerciseDetails = {};


  Map<String, Map<String, dynamic>> exerciseSettings = {};

  @override
  void initState() {
    super.initState();

    _initData();
  }

  @override
  void dispose() {
    // 🧠 Wait until after final frame callbacks
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _savePlannedExercises();
    });
    super.dispose();
  }


  Future<void> _initData() async {
    await loadExercisesFromFirestore(); // 🧠 make sure this finishes first
    await _loadBlockDatesFromFirestore();
    await _loadPlannedExercises();
    await initializePlannedExerciseDetails(exercises);
  }




  Future<void> _loadBlockDatesFromFirestore() async {
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
      if (data != null) {
        setState(() {
          _blockStartDate = data['blockStartDate'] != null
              ? DateTime.parse(data['blockStartDate'])
              : null;
          _blockEndDate = data['blockEndDate'] != null
              ? DateTime.parse(data['blockEndDate'])
              : null;
        });
      }
    }
  }




  PeriodizationModelType _mapLabelToModelType(String label) {
    switch (label) {
      case 'Daily Undulating Periodization':
        return PeriodizationModelType.dailyUndulating;
      case 'DUP, Signature':
        return PeriodizationModelType.dupSignature;
      case 'DUP, Custom':
        return PeriodizationModelType.dupCustom;
      case 'Linear, Classic':
        return PeriodizationModelType.linearClassic;
      case 'Linear, by Exposure':
        return PeriodizationModelType.linearExposure;
      default:
        return PeriodizationModelType.dupSignature;
    }
  }






  Map<String, List<String>> groupedExercises = {};

  Future<void> loadExercisesFromFirestore() async {
    final snapshot = await FirebaseFirestore.instance.collection('exercises').get();

// Clear previous
    _exerciseIdToName.clear();

    final exercises = snapshot.docs.map((doc) {
      final id = doc.id; // 👈 New
      final name = doc['name'] as String;
      final category = doc['category'] as String;
      final bodyPart = doc['bodyPart'] as String;

      _exerciseIdToName[id] = name; // 👈 New: map id ➔ name

      return {
        'id': id, // 👈 Add id here too if needed later
        'name': name,
        'category': category,
        'bodyPart': bodyPart,
      };
    }).toList();

    setState(() {
      groupedExercises = groupExercisesByCategory(exercises);
    });
  }



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

  void _showExercisePickerDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // 🔥 Fetch exercises from Firestore (including ID)
    final snapshot = await FirebaseFirestore.instance.collection('exercises').get();
    final exercisesFromFirestore = snapshot.docs.map((doc) => {
      'id': doc.id,
      'name': doc['name'] as String,
      'category': doc['category'] as String,
    }).toList();

    // 🧠 Desired category order
    const categoryOrder = [
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

    // 🧩 Group exercises by category
    final Map<String, List<Map<String, String>>> grouped = {};
    for (final exercise in exercisesFromFirestore) {
      final category = exercise['category'] ?? 'Other';
      grouped.putIfAbsent(category, () => []).add(exercise);
    }

    // 🔠 Sort names within each group
    for (final group in grouped.values) {
      group.sort((a, b) => a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));
    }

    // 🧱 Ordered + any extras
    final Map<String, List<Map<String, String>>> orderedGrouped = {};
    for (final cat in categoryOrder) {
      if (grouped.containsKey(cat)) {
        orderedGrouped[cat] = grouped[cat]!;
      }
    }
    for (final entry in grouped.entries) {
      if (!orderedGrouped.containsKey(entry.key)) {
        orderedGrouped[entry.key] = entry.value;
      }
    }

    // 📦 Expand/collapse state
    final Map<String, bool> expandedGroups = {
      for (final category in orderedGrouped.keys) category: true
    };

    final List<String> selected = await showDialog<List<String>>(
      context: context,
      builder: (ctx) {
        List<String> tempSelected = [...exercises]; // exercises = selected IDs now

        return StatefulBuilder(builder: (context, setLocalState) {
          return AlertDialog(
            backgroundColor: Colors.blueGrey.shade900,
            title: const Text(
              "Select Exercises",
              style: TextStyle(color: Colors.white),
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                children: orderedGrouped.entries.map((entry) {
                  final category = entry.key;
                  final exercises = entry.value;
                  final isExpanded = expandedGroups[category] ?? true;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        tileColor: Colors.blueGrey.shade800,
                        title: Text(
                          category,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        trailing: Icon(
                          isExpanded ? Icons.expand_less : Icons.expand_more,
                          color: Colors.white70,
                        ),
                        onTap: () {
                          setLocalState(() {
                            expandedGroups[category] = !isExpanded;
                          });
                        },
                      ),
                      if (isExpanded)
                        ...exercises.map((exercise) {
                          final id = exercise['id']!;
                          final name = exercise['name']!;
                          final isChecked = tempSelected.contains(id);
                          return CheckboxListTile(
                            value: isChecked,
                            title: Text(name, style: const TextStyle(color: Colors.white)),
                            controlAffinity: ListTileControlAffinity.leading,
                            activeColor: Colors.lightBlueAccent,
                            checkColor: Colors.black,
                            onChanged: (checked) {
                              setLocalState(() {
                                if (checked == true) {
                                  tempSelected.add(id);
                                } else {
                                  tempSelected.remove(id);
                                }
                              });
                            },
                          );
                        }),
                      const Divider(height: 10, color: Colors.grey),
                    ],
                  );
                }).toList(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Cancel"),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, tempSelected),
                child: const Text("Save"),
              ),
            ],
          );
        });
      },
    ) ?? [];

    setState(() {
      exercises = selected; // 🧠 Now saving IDs
    });
  }


  Future<void> _savePlannedExercises() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final docRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_planner')
        .doc('current_block');

    final snapshot = await docRef.get();
    final data = snapshot.data() ?? {};

    final existingDetails = Map<String, dynamic>.from(
      data['plannedExerciseDetails'] ?? {},
    );

    for (final exercise in exercises) {
      final entry = Map<String, dynamic>.from(exerciseSettings[exercise] ?? {});
      final repTargets = entry['repTargets'];

      // ✅ Normalize flat List<String> into List<List<String>> (legacy fallback)
      if (repTargets is List && repTargets.isNotEmpty && repTargets.first is String) {
        final flat = repTargets
            .expand((e) => e.toString().split(','))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();

        final weeklyFreq = int.tryParse(entry['weeklyFrequency'].toString()) ?? 3;
        final numWeeks = (flat.length / weeklyFreq).ceil();

        final nested = List.generate(numWeeks, (i) {
          final start = i * weeklyFreq;
          final end = (start + weeklyFreq).clamp(0, flat.length);
          return flat.sublist(start, end);
        });

        entry['repTargets'] = nested;
        print("🛠️ Normalized legacy repTargets for $exercise: $nested");
      }

      // ✅ If already in Map<String, Map<String, String>> format, use directly
      final savedTargets = repTargets is Map<String, Map<String, String>>
          ? repTargets
          : _convertToMap(repTargets);

      entry['repTargets'] = savedTargets; // <-- ✅ This was missing before

      print("🧪 Saving repTargets for $exercise: ${jsonEncode(savedTargets)}");
      // ✅ Special handling for Daily Undulating Periodization
      final model = entry['periodizationModel'];
      if (model == 'Daily Undulating Periodization' &&
          repTargets is List &&
          repTargets.isNotEmpty &&
          repTargets.first is String) {
        final reps = List<String>.from(repTargets);
        final dupMap = <String, Map<String, String>>{
          'week1': {
            for (int i = 0; i < reps.length; i++) 'instance${i + 1}': reps[i]
          }
        };
        entry['repTargets'] = dupMap;
        print('🔁 Converted DUP repTargets for $exercise: ${jsonEncode(dupMap)}');
      }


      existingDetails[exercise] = {
        'periodizationModel': entry['periodizationModel'] ?? 'Linear Exposure',
        'repTargets': savedTargets,
        'progressionModel': entry['progressionModel'] ?? 'linear',
        'increments': entry['increments'] ?? {'week': 2.5, 'block': 5.0},
        'weeklyFrequency': entry['weeklyFrequency'] ?? 3,
        'maxWeightXReps': entry['maxWeightXReps'] ?? '',
        'notes': entry['notes'] ?? '',
      };
    }

    print("📤 Saving plannedExerciseDetails:\n${jsonEncode(existingDetails)}");

    await docRef.set({
      'plannedExercises': exercises,
      'plannedExerciseDetails': existingDetails,
    }, SetOptions(merge: true));

    print("✅ Planned exercises and details saved safely.");

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Planned exercises updated.')),
      );
    }

    print("📦 Final saved frequencies:");
    for (final ex in exercises) {
      print("• $ex: ${exerciseSettings[ex]?['weeklyFrequency']}");
    }
  }


  Map<String, Map<String, String>> _convertToMap(dynamic data) {
    if (data is List && data.isNotEmpty) {
      if (data.first is List) {
        // ✅ Convert List<List<String>> to Map<String, Map<String, String>>
        return {
          for (int week = 0; week < data.length; week++)
            'week${week + 1}': {
              for (int i = 0; i < data[week].length; i++)
                'instance${i + 1}': data[week][i]
            }
        };
      } else if (data.first is String) {
        // ✅ Flat list → assign to week1 with instance keys
        return {
          'week1': {
            for (int i = 0; i < data.length; i++)
              'instance${i + 1}': data[i]
          }
        };
      }
    }
    // ❌ Invalid or empty structure
    return {};
  }

  Future<void> _loadPlannedExercises() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_planner')
        .doc('current_block')
        .get();

    if (snapshot.exists) {
      final data = snapshot.data();
      if (data != null) {
        // ✅ Restore planned exercise IDs
        if (data.containsKey('plannedExercises')) {
          setState(() {
            exercises = List<String>.from(data['plannedExercises']);
          });
        }

        // ✅ Restore detailed settings
        if (data.containsKey('plannedExerciseDetails')) {
          final raw = Map<String, dynamic>.from(data['plannedExerciseDetails']);
          final Map<String, Map<String, dynamic>> converted = {};

          raw.forEach((exerciseId, value) {
            converted[exerciseId] = Map<String, dynamic>.from(value as Map);
          });

          setState(() {
            exerciseSettings = converted;
          });

          print("📋 Loaded plannedExerciseDetails for ${converted.length} exercises");
        }
      }
    }
  }



  Future<void> initializePlannedExerciseDetails(List<String> plannedExercises) async {

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final docRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_planner')
        .doc('current_block');

    final snapshot = await docRef.get();
    final data = snapshot.data() ?? {};

    // ✅ This matches what's saved in _savePlannedExercises()
    final existingDetails = Map<String, dynamic>.from(
      data['plannedExerciseDetails'] ?? {},
    );


    // Update or insert entries for each planned exercise
    for (final exercise in plannedExercises) {
      final existingEntry = existingDetails[exercise] as Map<String, dynamic>?;

      final reps = exerciseRepTargets[exercise] ?? [10, 8, 6];

      final entry = {
        'periodizationModel': existingEntry?['periodizationModel'] ?? 'Linear Exposure',
        'repTargets': reps,
        'progressionModel': existingEntry?['progressionModel'] ?? 'linear',
        'increments': existingEntry?['increments'] ?? {'week': 2.5, 'block': 5.0},
        'weeklyFrequency': existingEntry?['weeklyFrequency'] ?? 3,
        'maxWeightXReps': existingEntry?['maxWeightXReps'] ?? '',
        'notes': existingEntry?['notes'] ?? '',
      };

      existingDetails[exercise] = entry;
      exerciseSettings[exercise] = entry;
    }


    await docRef.set({
      'plannedExerciseDetails': existingDetails,

    }, SetOptions(merge: true));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.blueGrey.shade900,
      appBar: AppBar(
        title: const Text("Block Planner"),
        backgroundColor: Colors.blueGrey.shade800,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildGlobalBlockInputs(),
            const SizedBox(height: 20),
            Row(
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text(
                    "Add Exercises",
                    style: TextStyle(color: Colors.pink),
                  ),

                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onPressed: _showExercisePickerDialog,
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.clear, size: 16),
                  label: const Text("Clear Exercises"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text("Clear All Exercises?"),
                        content: const Text("This will remove all selected exercises from the planner."),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text("Cancel"),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text("Yes, Clear"),
                          ),
                        ],
                      ),
                    );

                    if (confirm == true) {
                      setState(() {
                        exercises.clear();
                      });
                    }
                  },

                ),
              ],
            ),


            const SizedBox(height: 12),
            SizedBox(
              height: exercises.length * 100, // 👈 Tweak if your cards are taller/shorter
              child: ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(), // Prevent internal scrolling
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) newIndex -= 1;
                    final item = exercises.removeAt(oldIndex);
                    exercises.insert(newIndex, item);
                  });
                },
                itemCount: exercises.length,
                itemBuilder: (context, index) {
                  final exercise = exercises[index];
                  return Dismissible(
                    key: ValueKey(exercise),
                    direction: DismissDirection.endToStart,
                    onDismissed: (_) {
                      final removedExercise = exercises[index];

                      setState(() {
                        exercises.removeAt(index);
                      });

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Removed "${_exerciseIdToName[removedExercise] ?? 'Unknown Exercise'}"'),
                          action: SnackBarAction(
                            label: 'Undo',
                            textColor: Colors.amberAccent,
                            onPressed: () {
                              setState(() {
                                exercises.insert(index, removedExercise);
                              });
                            },
                          ),
                          duration: const Duration(seconds: 4),
                          backgroundColor: Colors.blueGrey.shade700,
                          behavior: SnackBarBehavior.floating,
                          margin: const EdgeInsets.all(16),
                        ),
                      );
                    },


                    background: Container(
                      color: Colors.red,
                      padding: const EdgeInsets.only(left: 16),
                      alignment: Alignment.centerLeft,
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    child: _ExerciseCard(
                      exerciseId: exercise,
                      exerciseName: _exerciseIdToName[exercise] ?? 'Unknown Exercise',
                      exerciseSettings: exerciseSettings,
                      onUpdateSetting: (exerciseId, key, value) {
                        setState(() {
                          exerciseSettings[exerciseId] ??= {};
                          exerciseSettings[exerciseId]![key] = value;
                        });
                      },
                    ),

                  );
                },
              ),
            ),

          ],
        ),
      ),
    );
  }

  Widget _buildGlobalBlockInputs() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () async {
                  final now = DateTime.now();
                  final DateTimeRange? picked = await showDateRangePicker(
                    context: context,
                    firstDate: now.subtract(const Duration(days: 365)),
                    lastDate: now.add(const Duration(days: 365 * 2)),
                    initialDateRange: _blockStartDate != null && _blockEndDate != null
                        ? DateTimeRange(start: _blockStartDate!, end: _blockEndDate!)
                        : null,
                    builder: (context, child) {
                      return Theme(
                        data: ThemeData.dark().copyWith(
                          colorScheme: ColorScheme.dark(
                            primary: Colors.blueGrey.shade300,
                            surface: Colors.blueGrey.shade800,
                          ),
                        ),
                        child: child!,
                      );
                    },
                  );

                  if (picked != null) {
                    setState(() {
                      _blockStartDate = picked.start;
                      _blockEndDate = picked.end;
                    });

                    // Optional: save to Firestore here
                    final user = FirebaseAuth.instance.currentUser;
                    if (user != null) {
                      await FirebaseFirestore.instance
                          .collection('users')
                          .doc(user.uid)
                          .collection('block_planner')
                          .doc('current_block')
                          .set({
                        'blockStartDate': picked.start.toIso8601String(),
                        'blockEndDate': picked.end.toIso8601String(),
                      }, SetOptions(merge: true));
                    }
                  }
                },
                child: Container(
                  height: 56,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.blueGrey.shade800,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white30),
                  ),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _blockStartDate != null && _blockEndDate != null
                        ? 'Block: ${DateFormat('d MMM').format(_blockStartDate!)} – ${DateFormat('d MMM y').format(_blockEndDate!)}'
                        : 'Select Block Dates',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
              ),
            ),


            const SizedBox(width: 8),
            _buildInputBox("Training days per week"),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _buildInputBox("Block goals", multiline: true),
            const SizedBox(width: 8),
            _buildInputBox("Planned calories surplus/deficit", multiline: true),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _buildInputBox("Injuries", multiline: true),
            const SizedBox(width: 8),
            _buildInputBox("General Notes", multiline: true),
          ],
        ),
      ],
    );
  }

  Widget _buildInputBox(String label, {bool multiline = false}) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        child: TextField(
          maxLines: multiline ? 3 : 1,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: const TextStyle(color: Colors.white70, fontSize: 12),
            filled: true,
            fillColor: Colors.blueGrey.shade800,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          ),
        ),
      ),
    );
  }


  Widget _smallInput(String label, {bool multiline = false}) {
    return SizedBox(
      width: 140,
      child: TextField(
        maxLines: multiline ? 3 : 1,
        style: const TextStyle(color: Colors.white, fontSize: 12),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white70, fontSize: 11),
          filled: true,
          fillColor: Colors.blueGrey.shade700,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        ),
      ),
    );
  }
}

class _ExerciseCard extends StatefulWidget {
  final String exerciseName;
  final String exerciseId;
  final Map<String, Map<String, dynamic>> exerciseSettings;
  final void Function(String exerciseName, String key, dynamic value) onUpdateSetting;

  const _ExerciseCard({
    required this.exerciseId,
    required this.exerciseName,
    required this.exerciseSettings,
    required this.onUpdateSetting,
  });

  @override
  State<_ExerciseCard> createState() => _ExerciseCardState();
}

class _ExerciseCardState extends State<_ExerciseCard> {
  bool isExpanded = false;
  final FocusNode _incrementsFocusNode = FocusNode();
  final TextEditingController _weeklyFrequencyController = TextEditingController(text: "7");
  final TextEditingController _repTargetsDisplayController = TextEditingController();
  final List<int> dupCustomDefaultReps = [10, 5, 12, 8, 3, 7, 1];
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _incrementsController = TextEditingController();
  final TextEditingController _maxWeightController = TextEditingController();
  final TextEditingController _maxRepsController = TextEditingController();
  Map<String, Map<String, String>>? _cachedRepTargetMap;
  double _currentE1RM = 0.0;

  String _selectedModel = 'DUP, Signature'; // default or load from Firestore



  PeriodizationModelType _mapLabelToModelType(String label) {
    switch (label) {
      case 'Daily Undulating Periodization':
        return PeriodizationModelType.dailyUndulating;
      case 'DUP, Signature':
        return PeriodizationModelType.dupSignature;
      case 'DUP, Custom':
        return PeriodizationModelType.dupCustom;
      case 'Linear, Classic':
        return PeriodizationModelType.linearClassic;
      case 'Linear, by Exposure':
        return PeriodizationModelType.linearExposure;
      default:
        return PeriodizationModelType.dupSignature;
    }
  }

  @override
  void initState() {
    super.initState();
    print("📦 [INIT] Full settings map: ${widget.exerciseSettings}");

    _incrementsFocusNode.addListener(() {
      if (!_incrementsFocusNode.hasFocus) {
        final cleaned = _incrementsController.text
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .map((e) => double.tryParse(e))
            .whereType<double>()
            .where((v) => v > 0)
            .map((v) => v.toString())
            .join(', ');

        _incrementsController.text = cleaned;
      }
    });

    print("🛠️ [_ExerciseCard] INIT for: ${widget.exerciseName}");
    final settings = widget.exerciseSettings[widget.exerciseId];
    print("📦 Settings: $settings");

    if (settings != null) {
      final reps = settings['repTargets'];

      // ✅ Skip DUP Signature (which uses {min, max})
      final isSignature = reps is Map<String, dynamic> &&
          reps.containsKey('min') &&
          reps.containsKey('max');

      if (!isSignature) {
        _syncCachedRepTargets(widget.exerciseId); // 🧠 Apply for all other models
      }

      final frequency = settings['weeklyFrequency'];
      if (frequency != null) {
        _weeklyFrequencyController.text = frequency.toString();
      }


      final model = settings['periodizationModel'];
      if (model != null &&
          [
            'Daily Undulating Periodization',
            'DUP, Signature',
            'DUP, Custom',
            'Linear, Classic',
            'Linear, by Exposure',
          ].contains(model)) {
        _selectedModel = model;
      }

      final notes = settings['notes'];
      if (notes != null) {
        _notesController.text = notes.toString();
      }

      final increments = settings['increments'];
      if (increments is Map) {
        final values = ['primary', 'secondary', 'tertiary', 'quaternary']
            .map((key) => increments[key])
            .whereType<num>()
            .where((v) => v > 0)
            .map((v) => v.toString())
            .toList();
        _incrementsController.text = values.join(', ');
      }

      final maxCombo = settings['maxWeightXReps'];
      if (maxCombo is String && maxCombo.contains('x')) {
        final parts = maxCombo.split('x');
        if (parts.length == 2) {
          _maxWeightController.text = parts[0].trim();
          _maxRepsController.text = parts[1].trim();
        }
      }
    }

    // ✅ Live frequency update
    _weeklyFrequencyController.addListener(() {
      final value = int.tryParse(_weeklyFrequencyController.text.trim());
      if (value != null) {
        widget.onUpdateSetting(widget.exerciseId, 'weeklyFrequency', value);
      }
    });
  }

  @override
  void dispose() {
    _maxWeightController.removeListener(_updateE1RM);
    _maxRepsController.removeListener(_updateE1RM);

    final value = int.tryParse(_weeklyFrequencyController.text.trim());
    if (value != null) {
      widget.onUpdateSetting(widget.exerciseId, 'weeklyFrequency', value);
      print("💾 [DISPOSE] Saved weeklyFrequency for ${widget.exerciseName}: $value");
    }

    final model = _selectedModel;
    if (model.isNotEmpty) {
      widget.onUpdateSetting(widget.exerciseId, 'periodizationModel', model);
      print("💾 [DISPOSE] Saved periodizationModel for ${widget.exerciseName}: $model");
    }

    // ✅ Save repTargets from display text as week → instance → value
    final repText = _repTargetsDisplayController.text.trim();
    if (repText.isNotEmpty) {
      final model = PeriodizationModelUtils.exercisePeriodizationModels[widget.exerciseId];

      final Map<String, Map<String, String>> result = {};

      if (model == PeriodizationModelType.linearClassic) {
        // 🟦 Linear By Week → Parse multiple weeks via ||
        final parts = repText.split('||');
        for (int i = 0; i < parts.length; i++) {
          final weekKey = 'week${i + 1}';
          final instanceMap = <String, String>{};

          final values = parts[i]
              .split('|')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();

          for (int j = 0; j < values.length; j++) {
            instanceMap['instance${j + 1}'] = values[j];
          }

          result[weekKey] = instanceMap;
        }
      } else {
        // ✅ All other models (exposure-based and DUP-week) → Single week1
        final values = repText
            .split('|')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();

        final instanceMap = <String, String>{
          for (int i = 0; i < values.length; i++) 'instance${i + 1}': values[i]
        };

        result['week1'] = instanceMap;
      }

      widget.onUpdateSetting(widget.exerciseId, 'repTargets', result);
      print("💾 [DISPOSE] Saved repTargets for ${widget.exerciseName} using model $model → $result");
    }


    // ✅ Clean and normalize increments
    final cleaned = _incrementsController.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join(', ');
    _incrementsController.text = cleaned;

    final List<double> parsedIncrements = cleaned
        .split(',')
        .map((s) => double.tryParse(s.trim()))
        .whereType<double>()
        .where((v) => v > 0)
        .toList();

    if (parsedIncrements.isNotEmpty) {
      final Map<String, double> incrementsMap = {};
      if (parsedIncrements.length > 0) incrementsMap['primary'] = parsedIncrements[0];
      if (parsedIncrements.length > 1) incrementsMap['secondary'] = parsedIncrements[1];
      if (parsedIncrements.length > 2) incrementsMap['tertiary'] = parsedIncrements[2];
      if (parsedIncrements.length > 3) incrementsMap['quaternary'] = parsedIncrements[3];

      widget.onUpdateSetting(widget.exerciseId, 'increments', incrementsMap);
      print("💾 [DISPOSE] Saved increments for ${widget.exerciseName}: $incrementsMap");
    }

    final notes = _notesController.text.trim();
    widget.onUpdateSetting(widget.exerciseId, 'notes', notes);
    print("💾 [DISPOSE] Saved notes for ${widget.exerciseName}: $notes");

    final kg = _maxWeightController.text.trim();
    final reps = _maxRepsController.text.trim();
    print("🧠 [DISPOSE] Entered max weight: $kg");
    print("🧠 [DISPOSE] Entered max reps: $reps");

    final kgDouble = double.tryParse(kg);
    final repsDouble = double.tryParse(reps);
    if (kgDouble != null && repsDouble != null) {
      final combined = '${kgDouble.toStringAsFixed(1)} x ${repsDouble.toStringAsFixed(0)}';
      widget.onUpdateSetting(widget.exerciseId, 'maxWeightXReps', combined);
      print("💾 [DISPOSE] Saved maxWeightXReps for ${widget.exerciseName}: $combined");
    } else {
      print("⚠️ [DISPOSE] Skipped saving maxWeightXReps due to invalid input.");
    }

    _weeklyFrequencyController.dispose();
    _repTargetsDisplayController.dispose();
    _incrementsController.dispose();
    _notesController.dispose();
    _maxWeightController.dispose();
    _maxRepsController.dispose();

    super.dispose();
  }

  void _syncCachedRepTargets(String exerciseName) {
    final settings = widget.exerciseSettings[exerciseName];
    final reps = settings?['repTargets'];

    print("🛠️ [_syncCachedRepTargets] for $exerciseName → $reps");

    if (reps is Map<String, dynamic> &&
        reps.keys.any((k) => k.toString().startsWith('week'))) {
      final sortedWeeks = reps.keys.toList()..sort();
      final formatted = <String>[];
      final safeMap = <String, Map<String, String>>{};

      for (final week in sortedWeeks) {
        final instanceMap = reps[week];
        if (instanceMap is Map<String, dynamic>) {
          final sortedInstances = instanceMap.keys.toList()
            ..sort((a, b) {
              final ai = int.tryParse(a.replaceAll('instance', '')) ?? 0;
              final bi = int.tryParse(b.replaceAll('instance', '')) ?? 0;
              return ai.compareTo(bi);
            });

          final weekSafeMap = <String, String>{};
          for (final key in sortedInstances) {
            final val = instanceMap[key]?.toString() ?? '';
            weekSafeMap[key] = val;
          }

          safeMap[week] = weekSafeMap;
          formatted.add(sortedInstances.map((k) => weekSafeMap[k]!).join(' | '));
        }
      }

      _repTargetsDisplayController.text = formatted.join(' || ');
      _cachedRepTargetMap = safeMap;
      print("✅ [_syncCachedRepTargets] Cache updated for $exerciseName");
    } else {
      print("! [_syncCachedRepTargets] No valid repTargets found (value: $reps)");
    }
  }



  void _updateE1RM() {
    final weight = double.tryParse(_maxWeightController.text);
    final reps = double.tryParse(_maxRepsController.text);

    if (weight != null && reps != null) {
      setState(() {
        _currentE1RM = PeriodizationModelUtils.calculateE1RM(weight, reps, 0.5);
      });
    }
  }

  List<List<String>> getDefaultReps(String model, int frequency) {
    switch (model) {
      case 'Daily Undulating Periodization':
        const dupMap = {
          1: [10],
          2: [10, 5],
          3: [10, 5, 8],
          4: [10, 5, 8, 1],
          5: [12, 4, 8, 1, 6],
          6: [10, 3, 6, 1, 9, 5],
          7: [10, 4, 8, 2, 12, 5, 1],
        };
        final reps = dupMap[frequency] ??
            List.generate(frequency, (i) => [10, 5, 8, 1, 12, 4, 6][i % 7]);
        return [reps.map((r) => '$r x 3').toList()]; // 👈 one week

      case 'Linear, Classic':
        final base = List.generate(12, (week) {
          return List.generate(frequency, (i) {
            final reps = (12 - week - i).clamp(3, 15);
            final sets = reps < 5 ? 4 : 3;
            return "$reps x $sets";
          });
        });
        return base;

      case 'Linear, by Exposure':
        final reps = [12, 10, 8, 6, 4, 2].take(frequency).map((r) => '$r x 3').toList();
        return [reps];

      case 'DUP, Signature':
        const dupMin = 6;
        const dupMax = 10;
        final week = List.generate(
          frequency,
              (i) => '${dupMin + (i % (dupMax - dupMin + 1))} x 3',
        );
        return [week];

      case 'DUP, Custom':
        const baseCycle = [
          [10, 5, 8, 3, 12, 1, 6],
          [9, 4, 7, 11, 2, 5, 8],
          [12, 3, 6, 1, 9, 4, 7],
        ];
        final block = List.generate(12, (week) {
          final pattern = baseCycle[week % baseCycle.length];
          return List.generate(frequency, (i) {
            final r = pattern[i % pattern.length];
            final s = r < 5 ? 4 : 3;
            return '$r x $s';
          });
        });
        return block;

      default:
        return [List.generate(frequency, (i) => '10 x 3')];
    }
  }

  void _showLinearClassicRepTargetDialog(String exerciseName) {

    _syncCachedRepTargets(exerciseName); // 🔁 Pull from exerciseSettings if available

    final blockLength = 12;
    final weeklyFreq = int.tryParse(_weeklyFrequencyController.text) ?? 3;

    // Load from exerciseSettings
    final existing = _cachedRepTargetMap ?? widget.exerciseSettings[exerciseName]?['repTargets'];
    print('🧪 [BP] Opening rep target dialog for $exerciseName');
    print('🧪 [BP] Found existing rep targets: ${jsonEncode(existing)}');

    List<List<String>> reps;

    if (existing is Map<String, dynamic>) {
      print('✅ [BP] Using saved rep targets from Map structure');

      reps = List.generate(blockLength, (weekIndex) {
        final weekKey = 'week${weekIndex + 1}';
        final weekMap = existing[weekKey] as Map<String, dynamic>? ?? {};
        print('📦 [BP] Week $weekKey map: $weekMap');

        return List.generate(weeklyFreq, (i) {
          final instanceKey = 'instance${i + 1}';
          final saved = weekMap[instanceKey]?.toString();

          if (saved != null && saved.trim().isNotEmpty) {
            return saved;
          } else {
            // 💡 Use fallback default if nothing saved
            final defaultReps = (12 - weekIndex - i).clamp(3, 15);
            final sets = defaultReps < 5 ? 4 : 3;
            return "$defaultReps x $sets";
          }
        });

      });

    } else {
      print('⚠️ [BP] No valid saved repTargets found — falling back to default');

      reps = List.generate(blockLength, (week) {
        return List.generate(weeklyFreq, (i) {
          final repsVal = (12 - week - i).clamp(3, 15);
          final sets = repsVal < 5 ? 4 : 3;
          return "$repsVal x $sets";
        });
      });
    }
    // Create text controllers
    final controllers = List.generate(
      reps.length,
          (week) => List.generate(
        reps[week].length,
            (i) => TextEditingController(text: reps[week][i]),
      ),
    );

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900,
          title: const Text("Rep Targets by Week", style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: blockLength,
              itemBuilder: (context, week) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text("Week ${week + 1}", style: const TextStyle(color: Colors.white70)),
                          const SizedBox(width: 12),
                          const Text("(Linear Classic)", style: TextStyle(color: Colors.white38, fontSize: 11)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        children: List.generate(
                          weeklyFreq,
                              (i) => SizedBox(
                            width: 100,
                            child: TextField(
                              controller: controllers[week][i],
                              keyboardType: TextInputType.text,
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                              decoration: InputDecoration(
                                hintText: "e.g. 10 x 3",
                                hintStyle: const TextStyle(color: Colors.white38),
                                filled: true,
                                fillColor: Colors.blueGrey.shade800,
                                border: const OutlineInputBorder(),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel", style: TextStyle(color: Colors.white)),
            ),
            TextButton(
        onPressed: () {
        final result = <String, Map<String, String>>{};

        for (int weekIndex = 0; weekIndex < controllers.length; weekIndex++) {
        final weekList = controllers[weekIndex];
        final weekKey = 'week${weekIndex + 1}';
        final instanceMap = <String, String>{};

        for (int i = 0; i < weekList.length; i++) {
        final input = weekList[i].text.trim();
        print('📝 [SAVE] Week $weekKey, Instance ${i + 1} = "$input"');

        if (input.isNotEmpty) {
        instanceMap['instance${i + 1}'] = input;
        }
        }

        if (instanceMap.isNotEmpty) {
        result[weekKey] = instanceMap;
        }
        }

        print('💾 [SAVE] Final result to save: ${jsonEncode(result)}');

        setState(() {
        widget.onUpdateSetting(exerciseName, 'repTargets', result);

        final previewText = result.entries.map((e) {
        final reps = e.value.values.join(' | ');
        return reps;
        }).join(' || ');

        _repTargetsDisplayController.text = previewText;
        });

        Navigator.pop(ctx);
        },


        child: const Text("Save", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showDailyUndulatingRepTargetDialog(String exerciseName) {
    _syncCachedRepTargets(exerciseName); // 🔁 Pull saved data from settings if available

    final frequency = int.tryParse(_weeklyFrequencyController.text) ?? 3;

    // Load raw saved value
    final existing = _cachedRepTargetMap ?? widget.exerciseSettings[exerciseName]?['repTargets'];
    print("📍 [DUP Daily - By Week] Raw data: $existing");

    // Get fallback defaults
    final defaults = PeriodizationModelUtils.getDefaultReps(
      PeriodizationModelType.dailyUndulating,
      frequency,
    );
    final defaultReps = defaults['week1']?.values.toList() ?? [];

    // Normalize to saved user reps and sets
    final repsControllers = <TextEditingController>[];
    final setsControllers = <TextEditingController>[];

    for (int i = 0; i < frequency; i++) {
      String fallback = (i < defaultReps.length) ? defaultReps[i] : '10 x 3';
      String saved = '';

      if (existing is Map<String, dynamic>) {
        final weekMap = existing['week1'] as Map<String, dynamic>?;
        saved = weekMap?['instance${i + 1}']?.toString() ?? '';
      }

      final combined = saved.isNotEmpty ? saved : fallback;
      final parts = combined.split('x').map((s) => s.trim()).toList();
      final reps = parts.isNotEmpty ? parts[0] : '';
      final sets = parts.length > 1 ? parts[1] : '';

      repsControllers.add(TextEditingController(text: reps));
      setsControllers.add(TextEditingController(text: sets));
    }

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900,
          title: const Text(
            "Daily Undulating Reps (1 Week Pattern)",
            style: TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: frequency,
              itemBuilder: (context, i) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: repsControllers[i],
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: "Day ${i + 1} Reps",
                            labelStyle: const TextStyle(color: Colors.white70),
                            filled: true,
                            fillColor: Colors.blueGrey.shade800,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: setsControllers[i],
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: "Sets",
                            labelStyle: const TextStyle(color: Colors.white70),
                            filled: true,
                            fillColor: Colors.blueGrey.shade800,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel", style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () {
                final instanceMap = <String, String>{};

                for (int i = 0; i < frequency; i++) {
                  final reps = repsControllers[i].text.trim();
                  final sets = setsControllers[i].text.trim();
                  final combined = reps.isNotEmpty && sets.isNotEmpty ? "$reps x $sets" : '';
                  instanceMap['instance${i + 1}'] = combined;
                  print('✅ Saving instance${i + 1}: "$combined"');
                }

                final result = {'week1': instanceMap};
                print('🧠 Final saved map: ${jsonEncode(result)}');

                setState(() {
                  widget.onUpdateSetting(exerciseName, 'repTargets', result);

                  final preview = instanceMap.values
                      .take(5)
                      .where((r) => r.isNotEmpty)
                      .join(' | ') +
                      (instanceMap.length > 5 ? ' ...' : '');
                  _repTargetsDisplayController.text = preview;
                });

                Navigator.pop(ctx);
              },
              child: const Text("Save", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }





  void _showDupSignatureRepTargetDialog(String exerciseName) async {
    int min = 6;
    int max = 10;

    final existing = _cachedRepTargetMap ?? widget.exerciseSettings[exerciseName]?['repTargets'];
    print("🧪 [DUP Signature] Raw repTargets: $existing");

    if (existing is Map<String, dynamic> && existing.containsKey('repRange')) {
      final range = existing['repRange'] as Map<String, dynamic>;
      min = int.tryParse(range['min']?.toString() ?? '') ?? min;
      max = int.tryParse(range['max']?.toString() ?? '') ?? max;
      print("🔢 Loaded from repRange → min: $min, max: $max");
    } else if (existing is Map<String, dynamic>) {
      // fallback check (legacy format)
      final fallback = existing['week1']?['instance1']?.toString();
      final parts = fallback?.split('–');
      if (parts != null && parts.length == 2) {
        min = int.tryParse(parts[0].trim()) ?? min;
        max = int.tryParse(parts[1].replaceAll('reps', '').trim()) ?? max;
        print("🔁 Inferred from legacy fallback → min: $min, max: $max");
      }
    }


    await showDialog(
      context: context,
      builder: (ctx) {
        int tempMin = min;
        int tempMax = max;

        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900,
          title: Text("Set Rep Range for $exerciseName", style: const TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text("Min Reps:", style: TextStyle(color: Colors.white)),
                  const SizedBox(width: 10),
                  DropdownButton<int>(
                    value: tempMin,
                    dropdownColor: Colors.blueGrey.shade800,
                    items: List.generate(12, (i) => i + 1).map((rep) {
                      return DropdownMenuItem(
                        value: rep,
                        child: Text("$rep", style: const TextStyle(color: Colors.white)),
                      );
                    }).toList(),
                    onChanged: (val) => val != null ? setState(() => tempMin = val) : null,
                  ),
                ],
              ),
              Row(
                children: [
                  const Text("Max Reps:", style: TextStyle(color: Colors.white)),
                  const SizedBox(width: 10),
                  DropdownButton<int>(
                    value: tempMax,
                    dropdownColor: Colors.blueGrey.shade800,
                    items: List.generate(20, (i) => i + 1).map((rep) {
                      return DropdownMenuItem(
                        value: rep,
                        child: Text("$rep", style: const TextStyle(color: Colors.white)),
                      );
                    }).toList(),
                    onChanged: (val) => val != null ? setState(() => tempMax = val) : null,
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                final firestoreResult = {
                  'min': tempMin,
                  'max': tempMax,
                  'week1': {
                    'instance1': "$tempMin – $tempMax reps",
                  },
                };

// ✅ Save to shared in-memory cache with compatible structure
                final memoryCache = {
                  'repRange': {
                    'min': tempMin.toString(),
                    'max': tempMax.toString(),
                  }
                };

                _cachedRepTargetMap = memoryCache;


                print("💾 [DUP Signature] Saving min=$tempMin, max=$tempMax");

                // ✅ Update cache used by dialog open
                _cachedRepTargetMap = memoryCache;

                setState(() {
                  widget.onUpdateSetting(exerciseName, 'repTargets', firestoreResult);
                  _repTargetsDisplayController.text = "$tempMin – $tempMax reps";
                });

                Navigator.pop(ctx);
              }
              ,

              child: const Text("Save"),
            ),
          ],
        );
      },
    );
  }



  void _showLinearExposureRepTargetDialog(String exerciseName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_planner')
        .doc('current_block')
        .get();

    final data = snapshot.data();
    if (data == null) return;

    final blockStart = DateTime.parse(data['blockStartDate']);
    final blockEnd = DateTime.parse(data['blockEndDate']);
    final weeklyFreq = int.tryParse(_weeklyFrequencyController.text) ?? 2;

    final totalWeeks = blockEnd.difference(blockStart).inDays ~/ 7;
    final exposureCount = (totalWeeks * weeklyFreq).clamp(1, 36);

    final existing = _cachedRepTargetMap ?? widget.exerciseSettings[exerciseName]?['repTargets'];

    print("📍 [LE] Raw data: $existing");
    print('🧪 [LinearExposure] Raw existing: ${jsonEncode(existing)}');

    List<String> repsList = List.generate(exposureCount, (i) {
      final reps = (12 - (i * 7 / exposureCount).round()).clamp(5, 15);
      final sets = (i % 2 == 0) ? 3 : 4;
      return "$reps x $sets";
    });

// 🧠 Overlay saved instance values if present
    if (existing is Map<String, dynamic>) {
      final weekMap = existing['week1'];
      if (weekMap is Map<String, dynamic>) {
        for (int i = 0; i < exposureCount; i++) {
          final key = 'instance${i + 1}';
          final saved = weekMap[key]?.toString();
          if (saved != null && saved.isNotEmpty) {
            repsList[i] = saved;
          }
        }
      }
    }


    final controllers = repsList
        .map((value) => TextEditingController(text: value))
        .toList();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900,
          title: const Text("Rep Targets by Exposure", style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: (exposureCount / 2).ceil(),
              itemBuilder: (context, i) {
                final index1 = i * 2;
                final index2 = index1 + 1;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text("Exposure ${index1 + 1}", style: const TextStyle(color: Colors.white70)),
                          const SizedBox(width: 24),
                          if (index2 < exposureCount)
                            Text("Exposure ${index2 + 1}", style: const TextStyle(color: Colors.white70)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: controllers[index1],
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: "e.g. 10 x 3",
                                hintStyle: const TextStyle(color: Colors.white38),
                                filled: true,
                                fillColor: Colors.blueGrey.shade800,
                                border: const OutlineInputBorder(),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          if (index2 < exposureCount)
                            Expanded(
                              child: TextField(
                                controller: controllers[index2],
                                style: const TextStyle(color: Colors.white),
                                decoration: InputDecoration(
                                  hintText: "e.g. 8 x 4",
                                  hintStyle: const TextStyle(color: Colors.white38),
                                  filled: true,
                                  fillColor: Colors.blueGrey.shade800,
                                  border: const OutlineInputBorder(),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel", style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () {
                final updated = controllers
                    .map((c) => c.text.trim())
                    .toList();

                // 🧪 DEBUG: Print each field input
                for (int i = 0; i < updated.length; i++) {
                  print('✅ Exposure ${i + 1}: ${updated[i]}');
                }

                // ✅ Create a proper instance map
                final instanceMap = <String, String>{
                  for (int i = 0; i < updated.length; i++) 'instance${i + 1}': updated[i]
                };

                final result = {'week1': instanceMap};

                // ✅ Save to state and update display controller
                setState(() {
                  widget.onUpdateSetting(exerciseName, 'repTargets', result);
                  _repTargetsDisplayController.text = updated.take(5).join(' | ') +
                      (updated.length > 5 ? ' ...' : '');

                });

                Navigator.pop(ctx);
              },

              child: const Text("Save", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }





  void _showDupCustomRepTargetDialog(String exerciseName) {
    final frequency = int.tryParse(_weeklyFrequencyController.text) ?? 3;
    final blockLength = 12;

    final baseCycle = [
      [10, 5, 8, 3, 12, 1, 6],
      [9, 4, 7, 11, 2, 5, 8],
      [12, 3, 6, 1, 9, 4, 7],
    ];

    List<List<int>> extendedCycle = baseCycle.map((weekPattern) {
      if (weekPattern.length >= frequency) return weekPattern.sublist(0, frequency);
      final extended = [...weekPattern];
      int i = 0;
      while (extended.length < frequency) {
        extended.add(weekPattern[i % weekPattern.length]);
        i++;
      }
      return extended;
    }).toList();

    // ✅ Safely normalize saved format
    final raw = _cachedRepTargetMap ?? widget.exerciseSettings[exerciseName]?['repTargets'];
    print("📍 [DUP Custom] Raw data: $raw");

    Map<String, dynamic> saved = {};
    if (raw is Map<String, dynamic>) {
      saved = raw;
    }

    List<List<String>> repsByWeek = List.generate(blockLength, (week) {
      final weekKey = 'week${week + 1}';
      final savedWeek = saved[weekKey] as Map<String, dynamic>? ?? {};

      return List.generate(frequency, (i) {
        final instanceKey = 'instance${i + 1}';
        final savedVal = savedWeek[instanceKey]?.toString();
        if (savedVal != null && savedVal.isNotEmpty) return savedVal;

        final fallback = extendedCycle[week % extendedCycle.length][i % extendedCycle[0].length];
        final sets = fallback < 5 ? 4 : 3;
        return "$fallback x $sets";
      });
    });

    final controllers = List.generate(
      repsByWeek.length,
          (week) => List.generate(
        repsByWeek[week].length,
            (i) => TextEditingController(text: repsByWeek[week][i]),
      ),
    );

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900,
          title: const Text("Rep Targets by Week", style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: blockLength,
              itemBuilder: (context, week) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Week ${week + 1}", style: const TextStyle(color: Colors.white70)),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        children: List.generate(
                          frequency,
                              (i) => SizedBox(
                            width: 100,
                            child: TextField(
                              controller: controllers[week][i],
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                              decoration: InputDecoration(
                                hintText: "e.g. 10 x 3",
                                hintStyle: const TextStyle(color: Colors.white38),
                                filled: true,
                                fillColor: Colors.blueGrey.shade800,
                                border: const OutlineInputBorder(),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel", style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () {
                final updated = controllers.map((weekList) {
                  return weekList.map((c) {
                    final t = c.text.trim();
                    return t.isNotEmpty ? t : ""; // Preserve empty slots
                  }).toList();
                }).toList();

                final result = <String, Map<String, String>>{};
                for (int w = 0; w < updated.length; w++) {
                  final weekKey = 'week${w + 1}';
                  final instanceMap = <String, String>{};
                  for (int i = 0; i < updated[w].length; i++) {
                    instanceMap['instance${i + 1}'] = updated[w][i];
                  }
                  result[weekKey] = instanceMap;
                }

                setState(() {
                  widget.onUpdateSetting(exerciseName, 'repTargets', result);

                  // 🔍 Show preview of first 3 weeks, skip blanks
                  _repTargetsDisplayController.text = updated
                      .take(3)
                      .map((weekList) => weekList.where((r) => r.isNotEmpty).join(' | '))
                      .join(' || ') +
                      (updated.length > 3 ? ' ...' : '');
                });

                Navigator.pop(ctx);
              },

              child: const Text("Save", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }






  void _showRepTargetDialog(String exerciseName) {
    List<int> reps = List<int>.from(widget.exerciseSettings[widget.exerciseName]?['repTargets'] ?? List.filled(12, 6));


    showDialog(
      context: context,
      builder: (ctx) {
        List<TextEditingController> controllers = List.generate(
          reps.length,
              (i) => TextEditingController(text: reps[i].toString()),
        );

        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900,
          title: const Text("Rep Targets by Week", style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: 12,
              itemBuilder: (context, i) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: TextField(
                    controller: controllers[i],
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: "Week ${i + 1}",
                      labelStyle: const TextStyle(color: Colors.white70),
                      filled: true,
                      fillColor: Colors.blueGrey.shade800,
                      border: OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel", style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () {
                final updatedReps = controllers.map((c) => int.tryParse(c.text) ?? 6).toList();
                setState(() {
                  widget.exerciseSettings[widget.exerciseName]?['repTargets'] = updatedReps;

                });
                Navigator.pop(ctx);
              },
              child: const Text("Save", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }



  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(6, 10, 6, 10), // reduced horizontal padding
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade800,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blueGrey.shade700),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 🔽 Header Row with Expand/Collapse toggle
          GestureDetector(
            onTap: () => setState(() => isExpanded = !isExpanded),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: RichText(
                    overflow: isExpanded ? TextOverflow.visible : TextOverflow.ellipsis, // ✅ Dynamic
                    maxLines: isExpanded ? null : 1, // ✅ Allow full multi-line when expanded
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: isExpanded ? "▼  " : "➤  ",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                        TextSpan(
                          text: widget.exerciseName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),


                Builder(
                  builder: (_) {
                    final double? weight = double.tryParse(_maxWeightController.text);
                    final double? reps = double.tryParse(_maxRepsController.text);

                    String displayText;
                    if (weight != null && reps != null) {
                      final e1rm = PeriodizationModelUtils.calculateE1RM(weight, reps, 0.5);
                      displayText = "Avg E1RM: ${e1rm.toStringAsFixed(1)} kg";
                    } else {
                      displayText = "Avg E1RM: –";
                    }

                    return Text(
                      displayText,
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                    );
                  },
                )


              ],
            ),
          ),

          if (isExpanded) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 5,
              runSpacing: 4,
              children: [
                SizedBox(
                  width: 158,
                  child: DropdownButtonFormField<String>(
                    value: _selectedModel,
                    isExpanded: true,
                    items: [
                      'Daily Undulating Periodization',
                      'DUP, Signature',
                      'DUP, Custom',
                      'Linear, Classic',
                      'Linear, by Exposure',
                    ].map((label) {
                      return DropdownMenuItem<String>(
                        value: label,
                        child: Text(
                          label,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value == null) return;

                      final modelType = _mapLabelToModelType(value);
                      final frequency = int.tryParse(_weeklyFrequencyController.text) ?? 3;
                      final defaultReps = PeriodizationModelUtils.getDefaultReps(modelType, frequency);

                      print("🧠 Model selected: $value → mapped to $modelType");
                      print("🎯 Default reps generated for $modelType: $defaultReps");

                      // ✅ Force UI sync
                      FocusScope.of(context).unfocus();

                      setState(() {
                        _selectedModel = value;
                        widget.onUpdateSetting(widget.exerciseId, 'periodizationModel', value);
                        widget.onUpdateSetting(widget.exerciseId, 'repTargets', defaultReps);

                        // ✅ Preview rep targets from Map<String, Map<String, String>>
                        final preview = defaultReps.entries
                            .expand((weekEntry) {
                          final instanceMap = weekEntry.value;
                          if (instanceMap is Map<String, dynamic>) {
                            return instanceMap.values;
                          }
                          return <dynamic>[];
                        })
                            .join(', ');
                        _repTargetsDisplayController.text = preview;
                      });


                    },



                    dropdownColor: Colors.blueGrey.shade800,
                    decoration: InputDecoration(
                      labelText: "Periodization Model",
                      labelStyle: const TextStyle(color: Colors.white),
                      filled: true,
                      fillColor: Colors.blueGrey.shade700,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),

                  ),
                ),

                _smallInput(
                  "Weekly Frequency",
                  controller: _weeklyFrequencyController,
                  width: 158,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    FilteringTextInputFormatter.allow(RegExp(r'^[0-9]{0,2}$')),
                    TextInputFormatter.withFunction((oldValue, newValue) {
                      final intVal = int.tryParse(newValue.text);
                      if (intVal != null && intVal > 14) {
                        return oldValue;
                      }
                      return newValue;
                    }),
                  ],
                ),


                _smallInput("Progression Model", width: 158),
                SizedBox(
                  width: 158,
                  child: GestureDetector(
                    onTap: () {
                      final model = _mapLabelToModelType(_selectedModel);
                      switch (model) {
                        case PeriodizationModelType.dailyUndulating:
                          _showDailyUndulatingRepTargetDialog(widget.exerciseName);
                          break;

                        case PeriodizationModelType.dupSignature:
                          _showDupSignatureRepTargetDialog(widget.exerciseName);
                          break;

                        case PeriodizationModelType.linearClassic:
                          print("➡ Opening Linear Classic rep dialog"); // 👈 Debug
                          _showLinearClassicRepTargetDialog(widget.exerciseName);
                          break;
                        case PeriodizationModelType.linearExposure:
                          print("➡ Opening Linear Exposure rep dialog"); // ✅ ADD THIS
                          _showLinearExposureRepTargetDialog(widget.exerciseName);
                          break;

                        case PeriodizationModelType.dupCustom:
                          _showDupCustomRepTargetDialog(widget.exerciseName);
                          break;
                        default:
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Model "$_selectedModel" not supported yet')),
                          );
                      }
                    },
                    child: AbsorbPointer(
                      child: TextFormField(
                        controller: _repTargetsDisplayController,
                        readOnly: true,
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        decoration: InputDecoration(
                          labelText: 'Rep Targets X sets',
                          labelStyle: const TextStyle(color: Colors.white),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                          filled: true,
                          fillColor: Colors.blueGrey.shade700,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 6, width:400), // Adjust to 10 or 12 if you want more breathing room
                SizedBox(
                  width: 158,
                  child: TextFormField(
                    controller: _incrementsController,
                    focusNode: _incrementsFocusNode,
                    keyboardType: TextInputType.text,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9., ]'))

                      // ❌ Removed auto-formatting to preserve cursor position
                    ],
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    decoration: InputDecoration(
                      labelText: 'Increments (kg)',
                      hintText: '2.5, 1, 0.5, …',
                      labelStyle: const TextStyle(color: Colors.white),
                      hintStyle: const TextStyle(color: Colors.white38),
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      filled: true,
                      fillColor: Colors.blueGrey.shade700,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                  ),
                ),



                const SizedBox(height: 6, width:400), // Adjust to 10 or 12 if you want more breathing room


                SizedBox(
                  width: 158,
                  height: 48, // Match Notes height
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.blueGrey.shade800,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.white38),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Flexible(
                                child: TextField(
                                  controller: _maxWeightController,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                  style: const TextStyle(color: Colors.white, fontSize: 18),
                                  decoration: const InputDecoration(
                                    hintText: 'kg',
                                    hintStyle: TextStyle(color: Colors.white38),
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                                child: Text('×', style: TextStyle(color: Colors.white70, fontSize: 20)),
                              ),
                              Flexible(
                                child: TextField(
                                  controller: _maxRepsController,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                  style: const TextStyle(color: Colors.white, fontSize: 18),
                                  decoration: const InputDecoration(
                                    hintText: 'reps',
                                    hintStyle: TextStyle(color: Colors.white38),
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                       Positioned(
                        left: 8,
                        top: -4,
                        child: Text(
                          'Max Weight × Reps',
                          style: TextStyle(fontSize: 12, color: Colors.white, backgroundColor: Colors.blueGrey.shade800
                          ),
                        ),
                      ),
                    ],
                  ),
                ),



                SizedBox(
                  width: 158,
                  height:48,
                  child: TextField(
                    controller: _notesController,
                    maxLines: null,
                    minLines: 1,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      labelText: 'Notes',
                      labelStyle: const TextStyle(color: Colors.white),
                      filled: true,
                      fillColor: Colors.blueGrey.shade800,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    ),
                  ),
                ),

              ],
            )

          ]
        ],
      ),
    );
  }

  Widget _smallInput(
      String label, {
        TextEditingController? controller,
        bool multiline = false,
        double width = 150,
        double verticalPadding = 10,
        TextInputType? keyboardType, // 👈 Add this
        List<TextInputFormatter>? inputFormatters, // 👈 And this
      }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType, // 👈 Apply here
        inputFormatters: inputFormatters, // 👈 And here
        minLines: multiline ? 3 : 1,
        maxLines: multiline ? 5 : 1,
        style: const TextStyle(fontSize: 12, color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white),
          filled: true,
          fillColor: Colors.blueGrey.shade700,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: verticalPadding),
        ),
      ),
    );
  }




}

