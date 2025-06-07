import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'body_weight_tracker.dart';
import 'workout_details_screen.dart';
import 'workout_entry_screen.dart';
import 'workout_model.dart';
import 'block_planner.dart';
import 'SavedWorkoutsScreen.dart';

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
                    reps: (setData['reps'] is num)
                        ? setData['reps'] as int
                        : int.tryParse(setData['reps'].toString()) ?? 0,
                    weight: (setData['weight'] is num)
                        ? (setData['weight'] as num).toDouble()
                        : double.tryParse(setData['weight'].toString()) ?? 0.0,
                    rir: (setData['rir'] is num)
                        ? (setData['rir'] as num).toDouble()
                        : double.tryParse(setData['rir'].toString()) ?? 0.0,
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

  Future<DocumentSnapshot<Object?>> _fetchActiveBlock() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) {
      throw Exception('User not logged in');
    }

    final query = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .where('isActive', isEqualTo: true)
        .limit(1)
        .get();

    if (query.docs.isNotEmpty) {
      return query.docs.first;
    } else {
      throw Exception('No active block found');
    }
  }

  Future<List<Map<String, dynamic>>> _fetchTopLifts() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('workouts')
        .get();

    Map<String, double> maxes = {};

    for (var doc in snapshot.docs) {
      final exercises = List.from(doc['exercises'] ?? []);
      for (var exercise in exercises) {
        final name = exercise['name'] ?? '';
        final sets = List.from(exercise['sets'] ?? []);
        for (var set in sets) {
          final weight = (set['weight'] as num?)?.toDouble() ?? 0;
          if (!maxes.containsKey(name) || weight > maxes[name]!) {
            maxes[name] = weight;
          }
        }
      }
    }

    return maxes.entries.map((e) => {'exercise': e.key, 'weight': e.value}).toList();
  }

  Widget _buildFeatureCard(IconData icon, String label, String route) {
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, route),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 30, color: Colors.blueAccent),
              const SizedBox(height: 12),
              Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userEmail = FirebaseAuth.instance.currentUser?.email ?? '';

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Welcome back!', style: TextStyle(fontSize: 14)),
                Text(userEmail, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            const CircleAvatar(radius: 20, backgroundImage: AssetImage('assets/avatar.png')),
          ],
        ),
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(decoration: BoxDecoration(color: Colors.cyan), child: Text('Menu')),
            ListTile(title: const Text('Weigh In'), onTap: () => Navigator.pushNamed(context, '/body_weight_tracker')),
            ListTile(title: const Text('Exercises'), onTap: () => Navigator.pushNamed(context, '/exercises')),
            ListTile(title: const Text('Workout Planner'), onTap: () => Navigator.pushNamed(context, '/templates')),
            ListTile(title: const Text('Planned Blocks'), onTap: () => Navigator.pushNamed(context, '/planned_blocks')),
            ListTile(title: const Text('Week Planner 🚀'), onTap: () => Navigator.pushNamed(context, '/block_builder_2')),
            ListTile(title: const Text('Block Planner 🧠'), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const Block_Planner()))),
            ListTile(title: const Text('Saved Workouts 📓'), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const SavedWorkoutsScreen()))),
            ListTile(title: const Text('Logout'), onTap: () async { await FirebaseAuth.instance.signOut(); Navigator.pushReplacementNamed(context, '/login'); }),
          ],
        ),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : errorMessage.isNotEmpty
          ? Center(child: Text(errorMessage))
          : SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FutureBuilder<DocumentSnapshot>(
              future: _fetchActiveBlock(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const CircularProgressIndicator();
                }
                if (snapshot.hasError || !snapshot.hasData || !snapshot.data!.exists) {
                  return const Text('No active training block found.');
                }

                final data = snapshot.data!.data() as Map<String, dynamic>;
                final exercises = List<String>.from(data['exercises'] ?? []);
                final startDate = (data['startDate'] as Timestamp).toDate();
                final endDate = (data['endDate'] as Timestamp).toDate();

                return ListTile(
                  leading: const Icon(Icons.calendar_today, color: Colors.orangeAccent),
                  title: const Text("Upcoming Workout"),
                  subtitle: Text(
                    exercises.isNotEmpty
                        ? 'Next: ${exercises.first} (Block: ${DateFormat('MMM d').format(startDate)}–${DateFormat('MMM d').format(endDate)})'
                        : 'Active block found but no exercises listed.',
                  ),
                  onTap: () {
                    Navigator.pushNamed(context, '/block_builder', arguments: {
                      'blockId': snapshot.data!.id,
                    });
                  },
                );
              },
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.fitness_center, color: Colors.blueAccent),
              title: const Text("Most Recent Workout"),
              subtitle: Text(mostRecentWorkout != null
                  ? '${mostRecentWorkout!.name} - ${DateFormat('dd-MM-yyyy').format(mostRecentWorkout!.date)}'
                  : 'No recent workout found'),
              trailing: ElevatedButton(
                onPressed: () {
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const WorkoutPage()));
                },
                child: const Text('Add Workout'),
              ),
              onTap: () {
                if (mostRecentWorkout != null) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => WorkoutDetailsScreen(workout: mostRecentWorkout!),
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('No recent workout available')),
                  );
                }
              },
            ),
            const SizedBox(height: 20),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildFeatureCard(Icons.bar_chart, 'Weigh In', '/body_weight_tracker'),
                _buildFeatureCard(Icons.schedule, 'Week Planner', '/block_builder_2'),
                _buildFeatureCard(Icons.bookmark, 'Saved Workouts', '/saved_workouts'),
                _buildFeatureCard(Icons.logout, 'Logout', '/login'),
              ],
            ),
            const SizedBox(height: 20),
            const Text('Top Lifts', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _fetchTopLifts(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const CircularProgressIndicator();
                final lifts = snapshot.data!;
                return Column(
                  children: lifts
                      .map((e) => ListTile(
                    title: Text(e['exercise']),
                    trailing: Text('${e['weight'].toStringAsFixed(1)} kg'),
                  ))
                      .toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
