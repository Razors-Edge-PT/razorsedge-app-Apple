import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'workout_entry_screen.dart';
import 'workout_model.dart';
import 'app_drawer.dart';
import 'package:table_calendar/table_calendar.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum HomeSection { calendar, topLifts }

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  static const double kFeatureCardWidth = 150;

  String? mostRecentWeight;
  Workout? mostRecentWorkout;
  bool isLoading = true;
  String errorMessage = '';

  final CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Set<DateTime> _trainingDays = {};

  HomeSection _currentSection = HomeSection.calendar;

  @override
  void initState() {
    super.initState();
    _fetchRecentData();
    _fetchTrainingDaysForMonth(_focusedDay);

    // 🔔 Listen for any change in which block is active, and refresh the calendar
    FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(FirebaseAuth.instance.currentUser!.uid)
        .collection('blocks')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .listen((_) {
      _fetchTrainingDaysForMonth(_focusedDay);
    });
  }

  Future<void> _fetchTrainingDays() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .get();

    final days = snapshot.docs
        .map((doc) {
          final date = doc['date'];
          if (date is Timestamp) {
            return DateTime(
                date.toDate().year, date.toDate().month, date.toDate().day);
          }
          return null;
        })
        .whereType<DateTime>()
        .toSet();

    setState(() => _trainingDays = days);
  }

  Future<void> _fetchTrainingDaysForMonth(DateTime month) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      // 1️⃣ Get the active block doc
      final blockDoc = await _fetchActiveBlock();
      final data = blockDoc.data() as Map<String, dynamic>;

      // 2️⃣ Read the start/end Timestamps
      final Timestamp startTs = data['startDate'];
      final Timestamp endTs = data['endDate'];
      final DateTime blockStart = startTs.toDate();
      final DateTime blockEnd = endTs.toDate();

      // 3️⃣ Read the list of weekdays (Mon, Tue, …) that your user chose
      final List<dynamic> blockDays =
          data['selectedDays'] ?? data['daysOfWeek'] ?? [];

      // Map your string codes to Dart weekday ints
      final daysOfWeekMap = {
        'Mon': DateTime.monday,
        'Tue': DateTime.tuesday,
        'Wed': DateTime.wednesday,
        'Thu': DateTime.thursday,
        'Fri': DateTime.friday,
        'Sat': DateTime.saturday,
        'Sun': DateTime.sunday,
      };
      final Set<int> blockWeekdays = blockDays
          .map((d) => daysOfWeekMap[d.toString()])
          .whereType<int>()
          .toSet();

      // 4️⃣ Limit iteration to the visible month, but clipped to [blockStart, blockEnd]
      final firstOfMonth = DateTime(month.year, month.month, 1);
      final lastOfMonth = DateTime(month.year, month.month + 1, 0);

      final from = firstOfMonth.isAfter(blockStart) ? firstOfMonth : blockStart;
      final to = lastOfMonth.isBefore(blockEnd) ? lastOfMonth : blockEnd;

      final trainingDays = <DateTime>{};
      for (var day = from;
          !day.isAfter(to);
          day = day.add(const Duration(days: 1))) {
        if (blockWeekdays.contains(day.weekday)) {
          trainingDays.add(DateTime(day.year, day.month, day.day));
        }
      }

      setState(() => _trainingDays = trainingDays);
    } catch (e) {
      print('Error fetching training days: $e');
    }
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

    return maxes.entries
        .map((e) => {'exercise': e.key, 'weight': e.value})
        .toList();
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: Icon(icon, size: 45, color: Colors.cyanAccent),
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: Text(label,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              )
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
                      const Text('Quick Access',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                      SizedBox(
                        height: 125,
                        child: // in your HomeScreen.build():
                            SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              SizedBox(
                                width: kFeatureCardWidth,
                                child: _buildFeatureCard(
                                  Icons.fitness_center,
                                  'New\nWorkout',
                                  '/workout_entry',
                                ),
                              ),
                              SizedBox(
                                width: kFeatureCardWidth,
                                child: _buildFeatureCard(
                                  Icons.calendar_month,
                                  'Training\nSchedule',
                                  '/week_planner',
                                ),
                              ),
                              SizedBox(
                                width: kFeatureCardWidth,
                                child: _buildFeatureCard(
                                  Icons.history,
                                  'Saved\nWorkouts',
                                  '/saved_workouts',
                                ),
                              ),
                              SizedBox(
                                width: kFeatureCardWidth,
                                child: _buildFeatureCard(
                                  Icons.monitor_weight,
                                  'Weight\nTracker',
                                  '/body_weight',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: HomeSection.values.map((section) {
                          final isSelected = section == _currentSection;
                          final label = section == HomeSection.calendar
                              ? 'Training Calendar'
                              : 'Top Lifts';
                          return GestureDetector(
                            onTap: () =>
                                setState(() => _currentSection = section),
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 8),
                              padding: const EdgeInsets.symmetric(
                                  vertical: 6, horizontal: 12),
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    color: isSelected
                                        ? Colors.cyanAccent
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.white54,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),

                      const SizedBox(height: 20),
                      // Training Calendar
                      if (_currentSection == HomeSection.calendar) ...[
                        TableCalendar(
                          firstDay: DateTime.utc(2020, 1, 1),
                          lastDay: DateTime.utc(2100, 12, 31),
                          focusedDay: _focusedDay,
                          calendarFormat: CalendarFormat.month,
                          availableCalendarFormats: const {
                            CalendarFormat.month: 'Month',
                          }, // 🚫 disables switching format
                          headerStyle: const HeaderStyle(
                            formatButtonVisible:
                                false, // ❌ hides the format toggle
                            titleCentered: true,
                          ),
                          selectedDayPredicate: (day) =>
                              isSameDay(_selectedDay, day),
                          eventLoader: (day) {
                            final normalized =
                                DateTime(day.year, day.month, day.day);
                            return _trainingDays.contains(normalized)
                                ? [1]
                                : [];
                          },
                          onDaySelected: (selectedDay, focusedDay) {
                            setState(() {
                              _selectedDay = selectedDay;
                              _focusedDay = focusedDay;
                            });
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    WorkoutPage(initialDate: selectedDay),
                              ),
                            );
                          },
                          onPageChanged: (focusedDay) {
                            setState(() {
                              _focusedDay = focusedDay;
                            });
                            _fetchTrainingDaysForMonth(
                                focusedDay); // 🔄 refresh for new month
                          },
                          calendarBuilders: CalendarBuilders(
                            defaultBuilder: (context, date, _) {
                              final isTraining = _trainingDays.contains(
                                  DateTime(date.year, date.month, date.day));
                              return Container(
                                margin: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: isTraining
                                      ? Border.all(color: Colors.cyan, width: 2)
                                      : null,
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${date.day}',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              );
                            },
                            todayBuilder: (context, date, _) {
                              // optionally highlight today differently
                              return Container(
                                margin: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white24,
                                  border:
                                      Border.all(color: Colors.cyan, width: 2),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${date.day}',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold),
                                ),
                              );
                            },
                            selectedBuilder: (context, date, _) {
                              return Container(
                                margin: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.lightBlueAccent,
                                  border: Border.all(
                                      color: Colors.cyanAccent, width: 2),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${date.day}',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              );
                            },
                          ),
                        ),
                      ] else ...[
                        // Top Lifts
                        const SizedBox(height: 8),
                        Card(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          elevation: 2,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: FutureBuilder<List<Map<String, dynamic>>>(
                              future: _fetchTopLifts(),
                              builder: (context, snapshot) {
                                if (!snapshot.hasData) {
                                  return const CircularProgressIndicator();
                                }
                                final lifts = snapshot.data!;
                                return Column(
                                  children: lifts
                                      .map((e) => ListTile(
                                            title: Text(e['exercise']),
                                            trailing: Text(
                                                '${e['weight'].toStringAsFixed(1)} kg'),
                                          ))
                                      .toList(),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }
}
