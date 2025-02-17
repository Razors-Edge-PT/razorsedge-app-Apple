import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'body_weight_tracker.dart';
import 'workout_details_screen.dart';
import 'workout_entry_screen.dart';
import 'workout_model.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'main.dart'; // Import for routeObserver

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

  @override
  void initState() {
    super.initState();
    _fetchRecentData();
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
                  () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const BodyWeightTracker()),
              ),
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
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const WorkoutPage()),
              ),
              child: const Text('Add Workout'),
            ),
            const SizedBox(height: 24),
            Text('Planned Workouts', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            plannedWorkouts.isEmpty
                ? const Text('No planned workouts.')
                : Column(children: plannedWorkouts.map(_buildWorkoutCard).toList()),
          ],
        ),
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
