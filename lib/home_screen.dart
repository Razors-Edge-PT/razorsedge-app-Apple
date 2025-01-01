import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'body_weight_tracker.dart';
import 'workout_details_screen.dart';
import 'workout_entry_screen.dart';
import 'workout_model.dart';
import 'main.dart'; // Import main.dart for routeObserver

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with RouteAware {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  String? mostRecentWeight;
  Workout? mostRecentWorkout;
  bool isLoading = true;
  String errorMessage = '';
  List<Workout> plannedWorkouts = []; // State for holding future-dated workouts

  @override
  void initState() {
    super.initState();
    _fetchRecentData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeObserver.subscribe(this, route);
    }
    _fetchPlannedWorkouts();
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    _fetchPlannedWorkouts(); // Refresh planned workouts when returning to this screen
  }

  Future<void> _fetchMostRecentWeight() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final snapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
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
        // Get the current date and time
        final now = DateTime.now();

        // Query for workouts strictly before the current date and time
        final querySnapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('workouts')
            .where('date', isLessThan: now.toIso8601String())
            .orderBy('date', descending: true)
            .limit(1)
            .get();

        // Check if any workout was found
        if (querySnapshot.docs.isNotEmpty) {
          mostRecentWorkout = Workout.fromFirestore(querySnapshot.docs.first);
        } else {
          mostRecentWorkout = null;
        }
      }
    } catch (error) {
      errorMessage = 'Failed to load recent workout: $error';
    }
  }

  Future<void> _fetchRecentData() async {
    print("Starting data fetch for recent weight, workout, and planned workouts.");
    await Future.wait([
      _fetchMostRecentWeight(),
      _fetchMostRecentWorkout(),
    ]);
    setState(() {
      isLoading = false;
    });
  }

  Future<void> _fetchPlannedWorkouts() async {
    print("Fetching planned workouts...");
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final querySnapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('workouts')
            .orderBy('date')
            .get();

        // Manually filter for future-dated workouts and limit to 5
        final now = DateTime.now();
        plannedWorkouts = querySnapshot.docs
            .map((doc) => Workout.fromFirestore(doc))
            .where((workout) => workout.date.isAfter(now))
            .take(5) // Limit to the first 5 future-dated workouts
            .toList();

        print("Filtered planned workouts: ${plannedWorkouts.length} found.");
      } else {
        print("User not logged in.");
      }
    } catch (error) {
      print('Failed to load planned workouts: $error');
      setState(() {
        errorMessage = 'Failed to load planned workouts: $error';
      });
    }
    setState(() {}); // Refresh the UI
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
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        title: const Text('Most Recent Weight'),
                        subtitle: Text(mostRecentWeight ?? 'No recent weight found'),
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
                                      builder: (context) => WorkoutDetailsScreen(
                                          workout: mostRecentWorkout!),
                                    ),
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('No recent workout available')),
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
                      const SizedBox(height: 24),
                      Text(
                        'Planned Workouts',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      plannedWorkouts.isEmpty
                          ? const Text('No planned workouts.')
                          : ListView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: plannedWorkouts.length,
                              itemBuilder: (context, index) {
                                final workout = plannedWorkouts[index];
                                return Card(
                                  margin: const EdgeInsets.symmetric(vertical: 8.0),
                                  elevation: 4.0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10.0),
                                  ),
                                  child: ListTile(
                                    title: Text(
                                      workout.name,
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                    subtitle: Text(
                                      'Date: ${DateFormat('dd-MM-yyyy').format(workout.date)}',
                                      style: TextStyle(color: Colors.grey[600]),
                                    ),
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => WorkoutDetailsScreen(
                                              workout: workout),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                    ],
                  ),
                ),
    );
  }
}
