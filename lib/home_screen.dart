import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'body_weight_tracker.dart';
import 'workout_model.dart'; // Import Workout model
import 'workout_details_screen.dart'; // Import workout details screen
import 'workout_entry_screen.dart'; // Import workout entry screen

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
          mostRecentWorkout = Workout.fromFirestore(querySnapshot.docs.first);
        }
      }
    } catch (error) {
      errorMessage = 'Failed to load recent workout: $error';
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
              title: const Text('Templates'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/templates');
              },
            ),
            ListTile(
              title: const Text('Workouts List'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/workouts_list');
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
              ],
            ),
          ],
        ),
      ),
    );
  }
}
