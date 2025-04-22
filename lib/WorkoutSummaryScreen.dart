import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart'; // Import for date formatting
import 'package:localtest222/workout_model.dart';
import 'exercise_selection_screen.dart';
import 'template_model.dart';
import 'templates.dart';
import 'exercise_details_screen.dart'; // Import your exercise details screen
import 'top_sets_screen.dart';
import 'periodization_model_utils.dart';

class WorkoutSummaryScreen extends StatefulWidget {
  final DateTime date;
  final String workoutName;
  final List<Map<String, dynamic>> exercises;

  const WorkoutSummaryScreen({
    super.key,
    required this.date,
    required this.workoutName,
    required this.exercises,
  });

  @override
  State<WorkoutSummaryScreen> createState() => _WorkoutSummaryScreenState();
}

class _WorkoutSummaryScreenState extends State<WorkoutSummaryScreen> {
  late List<Map<String, dynamic>> editableExercises;
  bool isEditable = false;

  @override
  void initState() {
    super.initState();
    editableExercises = (widget.exercises ?? []).map((e) => Map<String, dynamic>.from(e)).toList();
    loadAllWorkoutsForDay();

  }

  Future<void> loadAllWorkoutsForDay() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .where('date', isGreaterThanOrEqualTo: DateTime(widget.date.year, widget.date.month, widget.date.day).toIso8601String())
        .where('date', isLessThan: DateTime(widget.date.year, widget.date.month, widget.date.day + 1).toIso8601String())
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
          // Merge sets
          final existingSets = List<Map<String, dynamic>>.from(exerciseMap[name]!['sets']);
          existingSets.addAll(sets);
          exerciseMap[name]!['sets'] = existingSets;
        }
      }
    }

    setState(() {
      editableExercises = exerciseMap.values.toList();
    });
  }


  void _toggleEdit() {
    if (!isEditable) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Edit Workout"),
          content: const Text("Are you sure you want to edit this completed workout?"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                setState(() => isEditable = true);
                Navigator.pop(ctx);
              },
              child: const Text("Yes"),
            )
          ],
        ),
      );
    }
  }

  Future<void> _save() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final workoutData = {
      'name': widget.workoutName,
      'date': widget.date.toIso8601String(),
      'userId': user.uid,
      'exercises': editableExercises,
    };

    // Save to workouts
    final workoutsRef = FirebaseFirestore.instance.collection('users').doc(user.uid).collection('workouts');
    final existing = await workoutsRef
        .where('date', isEqualTo: widget.date.toIso8601String())
        .limit(1)
        .get();

    if (existing.docs.isNotEmpty) {
      await existing.docs.first.reference.set(workoutData);
    } else {
      await workoutsRef.add(workoutData);
    }

    // Save top sets to block_data
    final blockRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_planner')
        .doc('current_block');

    final blockDoc = await blockRef.get();
    if (!blockDoc.exists) return;

    final blockStart = DateTime.parse(blockDoc['blockStartDate']);
    final daysSinceStart = widget.date.difference(blockStart).inDays;
    final weekIndex = (daysSinceStart / 7).floor();
    final dayIndex = daysSinceStart % 7;

    final weekDocRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_data')
        .doc('current_block')
        .collection('weeks')
        .doc('week_$weekIndex');

    await weekDocRef.set({'exists': true}, SetOptions(merge: true));
    final dayDoc = await weekDocRef.collection('days').doc('day_$dayIndex').get();
    final existingExercises = List<Map<String, dynamic>>.from(dayDoc.data()?['exercises'] ?? []);

    for (final newEx in editableExercises) {
      final matchIndex = existingExercises.indexWhere((e) => e['name'] == newEx['name']);
      if (matchIndex == -1) {
        existingExercises.add(newEx);
      } else {
        final old = existingExercises[matchIndex];
        final oldE1RM = PeriodizationModelUtils.calculateE1RM(
          old['weight'],
          old['reps']?.toDouble(),
          old['rir'],
        );

        final newE1RM = PeriodizationModelUtils.calculateE1RM(
          newEx['weight'],
          newEx['reps']?.toDouble(),
          newEx['rir'],
        );

        if (newE1RM > oldE1RM) {
          existingExercises[matchIndex] = newEx;
        }
      }
    }

    await weekDocRef.collection('days').doc('day_$dayIndex').set({
      'exercises': existingExercises,
    }, SetOptions(merge: true));

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Workout updated.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.workoutName),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: _toggleEdit,
          )
        ],
      ),
      body: ListView.builder(
        itemCount: editableExercises.length,
        itemBuilder: (context, i) {
          final ex = editableExercises[i];
          final name = ex['name'] ?? 'Unnamed';
          final circuitIndex = ex['circuitIndex'] ?? 0;

          return Card(
            margin: const EdgeInsets.all(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Circuit ${circuitIndex + 1}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(name, style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: const [
                      Text('Weight'),
                      Text('Reps'),
                      Text('RIR'),
                      Text('E1RM'),
                    ],
                  ),
                  const Divider(),
                  ...List.generate(((ex['sets'] ?? []) as List).length, (j) {
                    final set = (ex['sets'] ?? [])[j];
                    final weightCtrl = TextEditingController(text: set['weight'].toString());
                    final repsCtrl = TextEditingController(text: set['reps'].toString());
                    final rirCtrl = TextEditingController(text: set['rir'].toString());


                    final e1rm = PeriodizationModelUtils.calculateE1RM(
                      double.tryParse(weightCtrl.text),
                      double.tryParse(repsCtrl.text),
                      double.tryParse(rirCtrl.text),
                    );

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          SizedBox(width: 60, child: TextField(controller: weightCtrl, enabled: isEditable)),
                          SizedBox(width: 40, child: TextField(controller: repsCtrl, enabled: isEditable)),
                          SizedBox(width: 40, child: TextField(controller: rirCtrl, enabled: isEditable)),
                          Text(e1rm.toStringAsFixed(1)),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: isEditable
          ? FloatingActionButton(
        onPressed: _save,
        child: const Icon(Icons.save),
      )
          : null,
    );
  }
}
