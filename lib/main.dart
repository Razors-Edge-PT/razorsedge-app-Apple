import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'body_weight_tracker.dart'; // Import the new file
import 'login_screen.dart';
import 'exercises.dart';
import 'templates.dart';
import 'workout_entry_screen.dart';
import 'workout_history_screen.dart';
import 'home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Re App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      initialRoute: '/login',
      routes: {
        '/login': (context) => const LoginScreen(),
        '/home': (context) => const HomeScreen(), // Updated to HomeScreen
        '/exercises': (context) => const ExercisesScreen(),
        '/templates': (context) => const TemplatesScreen(),
        '/workouts': (context) => const WorkoutPage(),
        '/workouts_list': (context) => const WorkoutHistoryScreen(),
        '/body_weight_tracker': (context) => const BodyWeightTracker(),
      },
    );
  }
}
