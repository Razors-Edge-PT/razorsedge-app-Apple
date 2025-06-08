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
import 'app_drawer.dart';
import 'package:table_calendar/table_calendar.dart';


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

  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Set<DateTime> _trainingDays = {};

  @override
  void initState() {
    super.initState();
    _fetchRecentData();
    _fetchTrainingDays();
  }

  Future<void> _fetchTrainingDays() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .get();

    final days = snapshot.docs.map((doc) {
      final date = doc['date'];
      if (date is Timestamp) {
        return DateTime(date.toDate().year, date.toDate().month, date.toDate().day);
      }
      return null;
    }).whereType<DateTime>().toSet();

    setState(() => _trainingDays = days);
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
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 10),
                Image(image: AssetImage('assets/re_banner.png'), height: 40),
              ],
            ),
            GestureDetector(
              onTap: () => _scaffoldKey.currentState?.openDrawer(),
              child: const CircleAvatar(
                radius: 20,
                backgroundImage: AssetImage('assets/avatar.png'),
              ),
            ),
          ],
        ),
      ),
      drawer: const AppDrawer(),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : errorMessage.isNotEmpty
          ? Center(child: Text(errorMessage))
          : SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            const Text('Training Calendar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            TableCalendar(
              firstDay: DateTime.utc(2020, 1, 1),
              lastDay: DateTime.utc(2100, 12, 31),
              focusedDay: _focusedDay,
              calendarFormat: _calendarFormat,
              selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
              eventLoader: (day) {
                final normalized = DateTime(day.year, day.month, day.day);
                return _trainingDays.contains(normalized) ? [1] : [];
              },
              onDaySelected: (selectedDay, focusedDay) {
                setState(() {
                  _selectedDay = selectedDay;
                  _focusedDay = focusedDay;
                });
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => WorkoutPage(initialDate: selectedDay), // 👈 you'll need to support this
                  ),
                );
              },
              onFormatChanged: (format) {
                setState(() {
                  _calendarFormat = format;
                });
              },
              onPageChanged: (focusedDay) {
                _focusedDay = focusedDay;
              },
              calendarStyle: CalendarStyle(
                todayDecoration: BoxDecoration(color: Colors.blue.shade100, shape: BoxShape.circle),
                selectedDecoration: const BoxDecoration(color: Colors.blueAccent, shape: BoxShape.circle),
                markerDecoration: const BoxDecoration(color: Colors.deepOrange, shape: BoxShape.circle),
              ),
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
