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
  List<String> exercises = [
    'Bench Press, Barbell',
    'Deadlift, Conventional',
  ];

  void _showExercisePickerDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Fetch user-defined exercises
    final snapshot = await FirebaseFirestore.instance.collection('exercises').get();
    final firestoreExercises = snapshot.docs.map((doc) => doc['name'] as String).toList();

    // Combine with local core exercises
    final allExercises = {
      ...coreExercises.map((e) => e['name'] as String),
      ...firestoreExercises,
    }.toList();

    allExercises.sort();

    final List<String> selected = await showDialog<List<String>>(
      context: context,
      builder: (ctx) {
        List<String> selected = [...exercises]; // copy current state
        return AlertDialog(
          title: const Text("Select Exercises"),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              children: allExercises.map((exerciseName) {
                final isSelected = selected.contains(exerciseName);
                return CheckboxListTile(
                  value: isSelected,
                  title: Text(exerciseName),
                  onChanged: (checked) {
                    if (checked == true) {
                      selected.add(exerciseName);
                    } else {
                      selected.remove(exerciseName);
                    }
                    setState(() {}); // Force update during selection
                  },
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
            TextButton(onPressed: () => Navigator.pop(ctx, selected), child: const Text("Save")),
          ],
        );
      },
    ) ?? [];

    setState(() {
      exercises = selected;
    });
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


            const SizedBox(height: 4),
            ...exercises.map((e) => _buildExerciseCard(e)).toList(),
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
            _buildInputBox("Block length"),
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
      padding: const EdgeInsets.all(10),
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
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: isExpanded ? "▼  " : "▶  ",
                        style: const TextStyle(
                          color: Colors.white, // 👈 More subtle than white
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

                const Text(
                  "Avg E1RM: 180",
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),

          if (isExpanded) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              children: [
                _smallInput("Periodization Model", width: 160),
                _smallInput("Weekly Frequency", width: 140),
                _smallInput("Progression Model", width: 160),
                _smallInput("Rep Targets", width: 140),
                _smallInput("Max Weight X Reps", width: 140),
                _smallInput("Notes", multiline: true, width: 140, verticalPadding: 1),
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

