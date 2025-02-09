import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'body_weight_tracker.dart';
import 'exercises.dart';
import 'home_screen.dart';
import 'login_screen.dart';
import 'templates.dart';
import 'workout_entry_screen.dart';
import 'workout_history_screen.dart';

final RouteObserver<PageRoute> routeObserver = RouteObserver<PageRoute>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(); // Initialize Firebase

  runApp(const MyApp()); // Use MyApp as the main widget
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: [routeObserver],
      title: 'Re App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      initialRoute: '/login',
      routes: {
        '/login': (context) => const LoginScreen(),
        '/home': (context) => const HomeScreen(),
        '/exercises': (context) => const ExercisesScreen(),
        '/templates': (context) => const TemplatesScreen(),
        '/workouts': (context) => const WorkoutPage(),
        '/workouts_list': (context) => const WorkoutHistoryScreen(),
        '/body_weight_tracker': (context) => const BodyWeightTracker(),
      },
    );
  }
}
