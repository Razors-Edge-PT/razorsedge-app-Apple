import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'template_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'workout_entry_screen.dart';
import 'periodization_model_utils.dart';
import 'core_exercises.dart';

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

  @override
  @override
  void initState() {
    super.initState();
    _initData();
  }

  Future<void> _initData() async {
    await loadExercisesFromFirestore(); // 🧠 make sure this finishes first
    await _loadBlockDatesFromFirestore();
    await _loadPlannedExercises();
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

  @override
  void dispose() {
    _savePlannedExercises();
    super.dispose();
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

    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_planner')
        .doc('current_block')
        .set({
      'plannedExercises': exercises,
    }, SetOptions(merge: true));

    print("✅ Planned exercises saved.");

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ Planned exercises saved.')),
      );
    }
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
      if (data != null && data.containsKey('plannedExercises')) {
        final List<dynamic> loaded = data['plannedExercises'];
        setState(() {
          exercises = List<String>.from(loaded);
        });
        print("📦 Loaded ${exercises.length} planned exercises");
      }
    }
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
                  label: const Text("Add Exercises"),
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
                    child: _buildExerciseCard(_exerciseIdToName[exercise] ?? 'Unknown Exercise'),

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

  Widget _buildExerciseCard(String exerciseName) {
    return _ExerciseCard(exerciseName: exerciseName);
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

  const _ExerciseCard({required this.exerciseName});

  @override
  State<_ExerciseCard> createState() => _ExerciseCardState();
}

class _ExerciseCardState extends State<_ExerciseCard> {
  bool isExpanded = false;

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


                const Text(
                  "Avg E1RM: 180",
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),

          if (isExpanded) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 5,
              runSpacing: 4,
              children: [
                _smallInput("Periodization Model", width: 158),
                _smallInput("Weekly Frequency", width: 158),
                _smallInput("Progression Model", width: 158),
                _smallInput("Rep Targets", width: 158),
                _smallInput("Max Weight X Reps", width: 158),
                _smallInput("Notes", width: 158),
              ],
            )

          ]
        ],
      ),
    );
  }

  Widget _smallInput(String label, {bool multiline = false, double width = 150, double verticalPadding = 10}) {
    return SizedBox(
      width: width,
      child: TextField(
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

