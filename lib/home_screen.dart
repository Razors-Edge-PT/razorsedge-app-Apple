import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'core_exercises.dart';
import 'body_weight_tracker.dart';
import 'workout_details_screen.dart'; // Import workout details screen
import 'workout_entry_screen.dart'; // Import workout entry screen
import 'workout_model.dart'; // Import Workout model
import 'block_planner.dart'; // 👈 Add this line
import 'WorkoutSummaryScreen.dart';
import'update_exercises.dart';


class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}



class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  String? mostRecentWeight;
  Workout? mostRecentWorkout;
  bool isLoading = true;
  String errorMessage = '';

  @override
  void initState() {
    super.initState();

    _fetchRecentData();
  }

  Future<void> _fetchRecentData() async {
    await Future.wait([
      _fetchMostRecentWeight(),
      _fetchMostRecentWorkout(),
    ]);
    setState(() {
      isLoading = false;
    });
  }

  Future<void> _fetchMostRecentWeight() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final userId = user.uid;
        final snapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .collection('weights')
            .orderBy('timestamp', descending: true)
            .limit(1)
            .get();

        if (snapshot.docs.isNotEmpty) {
          final weightData = snapshot.docs.first.data();
          mostRecentWeight = '${weightData['weight']} ${weightData['unit']}';
        }
      }
    } catch (error) {
      errorMessage = 'Failed to load recent weight: $error';
    }
  }

  Future<void> _fetchMostRecentWorkout() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final querySnapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('workouts')
            .orderBy('date', descending: true)
            .limit(1)
            .get();

        if (querySnapshot.docs.isNotEmpty) {
          final doc = querySnapshot.docs.first;
          final data = doc.data();

          // ✅ Safely parse data to prevent "String is not a subtype of num" errors
          mostRecentWorkout = Workout(
            name: data['name'] ?? 'Unnamed Workout',
            date: data['date'] is Timestamp
                ? (data['date'] as Timestamp).toDate()
                : DateTime.parse(data['date']),
            exercises: (data['exercises'] as List<dynamic>).map((exercise) {
              final exerciseData = exercise as Map<String, dynamic>;
              return Exercise(
                name: exerciseData['name'] ?? 'Unnamed Exercise',
                sets: (exerciseData['sets'] as List<dynamic>).map((set) {
                  final setData = set as Map<String, dynamic>;
                  return SetDetails(
                    reps: (setData['reps'] is num) ? setData['reps'] as int : int.tryParse(setData['reps'].toString()) ?? 0,
                    weight: (setData['weight'] is num) ? (setData['weight'] as num).toDouble() : double.tryParse(setData['weight'].toString()) ?? 0.0,
                    rir: (setData['rir'] is num) ? (setData['rir'] as num).toDouble() : double.tryParse(setData['rir'].toString()) ?? 0.0,
                  );
                }).toList(),
              );
            }).toList(),
          );
        }
      }
    } catch (error) {
      setState(() {
        errorMessage = 'Failed to load recent workout: $error';
      });
    }
  }



  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: const Text('User Profile'),
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: _openDrawer,
        ),
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(
                color: Colors.cyan,
              ),
              child: Text('Menu'),
            ),
            ListTile(
              title: const Text('Body Weight Tracker'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/body_weight_tracker');
              },
            ),
            ListTile(
              title: const Text('Exercises'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/exercises');
              },
            ),
            ListTile(
              title: const Text('Workout Planner'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/templates');
              },
            ),

            ListTile(
              title: const Text('Workout History'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/workouts_list'); // ✅ Match main.dart, dont change - it shits itself
              },
            ),

            //ListTile(
             // title: const Text('Block Builder'),
             // onTap: () {
              //  Navigator.pop(context);
              //  Navigator.pushNamed(context, '/block_builder');
              //},
           // ),
            ListTile(
              title: const Text('Week Planner 🚀'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/block_builder_2'); // 👈 Match the route
              },
            ),
            ListTile(
              title: const Text('Block Planner 🧠'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const Block_Planner(), // ✅ Correct name with underscore
                  ),
                );
              },
            ),

            ListTile(
              title: const Text('Workout Summary 📋'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => WorkoutSummaryScreen(
                      date: DateTime.now(), // Replace with actual date if needed
                      workoutName: "Today's Summary", // Or pull a name dynamically
                      exercises: [], // 👈 Replace with a real list of exercises if available
                    ),
                  ),
                );
              },
            ),

            ListTile(
              title: const Text('Logout'),
              onTap: () async {
                await FirebaseAuth.instance.signOut();
                Navigator.pushReplacementNamed(context, '/login');
              },
            ),



          ],
        ),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : errorMessage.isNotEmpty
              ? Center(child: Text(errorMessage))
              : Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        title: const Text('Most Recent Weight'),
                        subtitle:
                            Text(mostRecentWeight ?? 'No recent weight found'),
                        onTap: () {
                          if (mostRecentWeight != null) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const BodyWeightTracker(),
                              ),
                            );
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: ListTile(
                              title: const Text('Most Recent Workout'),
                              subtitle: Text(mostRecentWorkout != null
                                  ? '${mostRecentWorkout!.name} - ${DateFormat('dd-MM-yyyy').format(mostRecentWorkout!.date)}'
                                  : 'No recent workout found'),
                              onTap: () {
                                if (mostRecentWorkout != null) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) =>
                                          WorkoutDetailsScreen(
                                              workout: mostRecentWorkout!),
                                    ),
                                  );
                                } else {
                                  // Optionally, you can show a message if there is no recent workout.
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text(
                                            'No recent workout available')),
                                  );
                                }
                              },
                            ),
                          ),
                          ElevatedButton(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => const WorkoutPage(),
                                ),
                              );
                            },
                            child: const Text('Add Workout'),



                          ),


                          // const SizedBox(height: 20), // Space between buttons
                         // ElevatedButton.icon(
                           // icon: const Icon(Icons.cloud_upload),
                          //  label: const Text('Upload Core Exercises to Firestore'),
                           // style: ElevatedButton.styleFrom(
                            //  backgroundColor: Colors.blueGrey.shade700,
                             // foregroundColor: Colors.white,
                           // ),
                           // onPressed: () async {
                           //   await uploadCoreExercisesToFirestore();
                           // },
                         // ),
                        ],
                      ),
                    ],
                  ),
                ),
    );
  }
}
