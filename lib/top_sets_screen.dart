import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'workout_model.dart';

class TopSetsScreen extends StatefulWidget {
  final String exerciseName; // ✅ Define exercise name
  final List<Workout> recentWorkouts; // ✅ Add recent workouts as a parameter

  const TopSetsScreen({
    Key? key,
    required this.exerciseName,
    required this.recentWorkouts, // ✅ Accepts recent workouts
  }) : super(key: key);

  @override
  _TopSetsScreenState createState() => _TopSetsScreenState();
}


class _TopSetsScreenState extends State<TopSetsScreen> {
  List<Workout> _workouts = [];
  bool _isLoading = true;
  int? _selectedRepTarget;
  String _sortOption = 'date';

  @override
  void initState() {
    super.initState();
  }


  Future<void> _fetchWorkoutHistory() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('workouts')
          .orderBy('date', descending: true)
          .limit(4000)
          .get();

      setState(() {
        _workouts = snapshot.docs.map((doc) => Workout.fromFirestore(doc)).toList();
        _isLoading = false;
      });
    } else {
      setState(() {
        _isLoading = false;
      });
    }
  }

  double calculateE1RM(double weight, double reps, double rir) {
    double totalReps = reps + rir;
    return (totalReps <= 6)
        ? (weight * (36 / (37 - totalReps)))
        : (weight * (1 + (0.0333 * totalReps)));
  }

  void _sortWorkouts() {
    setState(() {
      if (_sortOption == 'date') {
        widget.recentWorkouts.sort((a, b) => b.date.compareTo(a.date)); // ✅ Sorts by newest first
      } else if (_sortOption == 'e1rm') {
        widget.recentWorkouts.sort((a, b) {
          double e1rmA = a.exercises
              .expand((e) => e.sets)
              .map((s) => calculateE1RM(s.weight ?? 0, s.reps?.toDouble() ?? 0, s.rir ?? 0))
              .fold(0, (p, c) => c > p ? c : p);

          double e1rmB = b.exercises
              .expand((e) => e.sets)
              .map((s) => calculateE1RM(s.weight ?? 0, s.reps?.toDouble() ?? 0, s.rir ?? 0))
              .fold(0, (p, c) => c > p ? c : p);

          return e1rmB.compareTo(e1rmA); // ✅ Sorts by highest E1RM first
        });
      }
    });
  }


  void _showFilterDialog(BuildContext context) {
    TextEditingController _repTargetController = TextEditingController();
    _repTargetController.text = _selectedRepTarget?.toString() ?? '';

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Filter by Rep Target"),
          content: TextField(
            controller: _repTargetController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: "Enter Rep Target",
              border: OutlineInputBorder(),
            ),
            onChanged: (input) {
              int? manualInput = int.tryParse(input);
              if (manualInput != null && manualInput > 0) {
                setState(() {
                  _selectedRepTarget = manualInput;
                });
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _selectedRepTarget = null;
                });
                Navigator.pop(context);
              },
              child: const Text("Clear"),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text("Apply"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Workout> filteredWorkouts = widget.recentWorkouts
        .where((workout) => workout.exercises.any((exercise) => exercise.name == widget.exerciseName))
        .toList(); // ✅ Filters by selected exercise

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.exerciseName} - Top Sets'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                SizedBox(width: 68), // Add spacing to move Sort closer to Filter

                PopupMenuButton<String>(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12.0), // Rounded edges for the dropdown
                  ),
                  onSelected: (String value) {
                    setState(() {
                      _sortOption = value;
                      _sortWorkouts();
                    });
                  },
                  itemBuilder: (BuildContext context) => [
                    const PopupMenuItem(value: 'date', child: Text('Sort by Date')),
                    const PopupMenuItem(value: 'e1rm', child: Text('Sort by Top E1RM')),
                  ],
                  child: ElevatedButton(
                    onPressed: null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.lightBlue.shade200, // Sort button color
                      disabledBackgroundColor: Colors.lightBlue.shade200,
                      disabledForegroundColor: Colors.grey,
                      elevation: 0,
                    ),
                    child: const Text("Sort", style: TextStyle(color: Colors.white)),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => _showFilterDialog(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.lightBlue.shade200, // Filter button color
                  ),
                  child: const Text("Filters", style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),
          Expanded(
            child: widget.recentWorkouts.isEmpty
                ? const Center(child: Text("No previous workouts found."))
                : ListView.builder(
              itemCount: widget.recentWorkouts.length,
              itemBuilder: (context, index) {
                final workout = widget.recentWorkouts[index];
                SetDetails? topSet;
                double highestE1RM = 0.0;
                String? topExerciseName; // ✅ Store the name of the exercise for the top set

                for (var exercise in workout.exercises) {
                  if (exercise.name != widget.exerciseName) continue; // ✅ Filter by selected exercise

                  for (var set in exercise.sets) {
                    if (_selectedRepTarget != null && set.reps != _selectedRepTarget) {
                      continue;
                    }
                    double weight = set.weight ?? 0.0;
                    double reps = (set.reps ?? 0).toDouble();
                    double rir = set.rir ?? 0.0;
                    double e1rm = calculateE1RM(weight, reps, rir);

                    if (topSet == null || e1rm > highestE1RM) {
                      highestE1RM = e1rm;
                      topSet = set;
                      topExerciseName = exercise.name; // ✅ Store the exercise name
                    }
                  }
                }

                if (topSet == null) return const SizedBox.shrink();
                bool highlight = _selectedRepTarget != null && topSet.reps == _selectedRepTarget;

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  shape: highlight
                      ? RoundedRectangleBorder(
                    side: BorderSide(color: Colors.blue, width: 2.0),
                    borderRadius: BorderRadius.circular(8.0),
                  )
                      : null,
                  child: ListTile(
                    title: Text(
                      '$topExerciseName - ${DateFormat('dd-MM-yyyy').format(workout.date)}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: RichText(
                      text: TextSpan(
                        style: DefaultTextStyle.of(context).style,
                        children: [
                          TextSpan(text: '${topSet.weight}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                          TextSpan(text: 'kg ', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                          TextSpan(text: 'x ', style: const TextStyle(color: Colors.blue)),
                          TextSpan(text: '${topSet.reps}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                          TextSpan(text: ', RIR: ', style: const TextStyle(color: Colors.blue)),
                          TextSpan(text: '${topSet.rir}', style: const TextStyle(color: Colors.indigo)),
                          TextSpan(text: ' | E1RM: ', style: const TextStyle(color: Colors.blue)),
                          TextSpan(text: '${highestE1RM.toStringAsFixed(1)} kg', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),

    );
  }
}
