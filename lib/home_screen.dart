import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'body_weight_tracker.dart';
import 'workout_details_screen.dart';
import 'workout_entry_screen.dart';
import 'workout_model.dart';
import 'main.dart'; // Import for routeObserver
import 'dart:convert';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with RouteAware {
  String? mostRecentWeight;
  Workout? mostRecentWorkout;
  List<Workout> plannedWorkouts = [];
  bool isLoading = true;
  bool hasSavedWorkout = false;

  @override
  void initState() {
    super.initState();
    _fetchRecentData();
    _checkSavedWorkout();
  }

  Future<void> _fetchRecentData() async {
    await Future.wait([
      _fetchMostRecentWeight(),
      _fetchMostRecentWorkout(),
      _fetchPlannedWorkouts(),
    ]);
    if (mounted) setState(() => isLoading = false);
  }

  Future<void> _fetchMostRecentWeight() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('weights')
        .orderBy('timestamp', descending: true)
        .limit(1)
        .get();

    if (snapshot.docs.isNotEmpty) {
      final weightData = snapshot.docs.first.data();
      setState(() => mostRecentWeight = '${weightData['weight']} ${weightData['unit']}');
    }
  }

  Future<void> _fetchMostRecentWorkout() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final now = DateTime.now();
    final querySnapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .where('date', isLessThan: now.toIso8601String())
        .orderBy('date', descending: true)
        .limit(1)
        .get();

    if (querySnapshot.docs.isNotEmpty) {
      setState(() => mostRecentWorkout = Workout.fromFirestore(querySnapshot.docs.first));
    }
  }

  Future<void> _fetchPlannedWorkouts() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final now = DateTime.now();
    final querySnapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .where('date', isGreaterThan: now.toIso8601String())
        .orderBy('date')
        .limit(5)
        .get();

    setState(() => plannedWorkouts = querySnapshot.docs.map((doc) => Workout.fromFirestore(doc)).toList());
  }

  Future<void> _checkSavedWorkout() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => hasSavedWorkout = prefs.containsKey('savedWorkout'));
  }

  Future<void> _clearSavedWorkout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('savedWorkout');
    setState(() => hasSavedWorkout = false);
  }

  Future<void> _navigateToWorkoutEntry({bool resume = false}) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WorkoutPage(isNewWorkout: !resume),
      ),
    );
    if (result == true) {
      _checkSavedWorkout();
    }
  }

  Future<void> _confirmDiscardWorkout() async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Discard Active Workout?'),
          content: const Text('Are you sure you want to discard the active workout?'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                _clearSavedWorkout();
                Navigator.of(context).pop();
              },
              child: const Text('Yes, Discard'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _signOut() async {
    await FirebaseAuth.instance.signOut();
    await GoogleSignIn().signOut();
    Navigator.pushReplacementNamed(context, '/login');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchRecentData,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoCard(
              'Most Recent Weight',
              mostRecentWeight ?? 'No recent weight found',
              Icons.fitness_center,
                  () => Navigator.pushNamed(context, '/body_weight_tracker'),
            ),
            const SizedBox(height: 16),
            _buildInfoCard(
              'Most Recent Workout',
              mostRecentWorkout != null
                  ? '${mostRecentWorkout!.name} - ${DateFormat('dd-MM-yyyy').format(mostRecentWorkout!.date)}'
                  : 'No recent workout found',
              Icons.history,
                  () {
                if (mostRecentWorkout != null) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => WorkoutDetailsScreen(workout: mostRecentWorkout!),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
      floatingActionButton: hasSavedWorkout
          ? FloatingActionButton.extended(
        onPressed: _navigateToWorkoutEntry,
        backgroundColor: Colors.orangeAccent,
        icon: const Icon(Icons.play_arrow, color: Colors.white),
        label: const Text('Resume Workout', style: TextStyle(color: Colors.white)),
      )
          : FloatingActionButton.extended(
        onPressed: _navigateToWorkoutEntry,
        backgroundColor: Colors.blueAccent,
        icon: const Icon(Icons.fitness_center, color: Colors.white),
        label: const Text('New Workout', style: TextStyle(color: Colors.white)),
      ),
    );
  }

  Widget _buildInfoCard(String title, String value, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 8.0),
        elevation: 4.0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ListTile(
          leading: Icon(icon, color: Colors.blue),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(value, style: const TextStyle(fontSize: 16)),
        ),
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Colors.cyan),
            child: Text('Menu'),
          ),
          _buildDrawerItem(Icons.track_changes, 'Body Weight Tracker', '/body_weight_tracker'),
          _buildDrawerItem(Icons.fitness_center, 'Exercises', '/exercises'),
          _buildDrawerItem(Icons.list, 'Templates', '/templates'),
          _buildDrawerItem(Icons.history, 'Workouts List', '/workouts_list'),
        ],
      ),
    );
  }

  Widget _buildDrawerItem(IconData icon, String title, String route) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      onTap: () {
        Navigator.pop(context);
        Navigator.pushNamed(context, route);
      },
    );
  }

  Widget _buildWorkoutCard(Workout workout) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      elevation: 4.0,
      child: ListTile(
        title: Text(workout.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('Date: ${DateFormat('dd-MM-yyyy').format(workout.date)}'),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => WorkoutDetailsScreen(workout: workout)),
        ),
      ),
    );
  }
}
