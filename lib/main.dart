import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:io'; // 👈 Needed for Platform check

import 'body_weight_tracker.dart'; // Import the new file
import 'exercises.dart';
import 'home_screen.dart';
import 'login_screen.dart';
import 'templates.dart';
import 'workout_entry_screen.dart';
import 'workout_history_screen.dart';
import 'BlockBuilderScreen.dart';
import 'BlockBuilder2.0.dart'; // Update path if needed




void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase for all platforms
  if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
    await Firebase.initializeApp();
  } else {
    // Avoid crashing on unsupported platforms (e.g. desktop)
    try {
      await Firebase.initializeApp();
    } catch (e) {
      debugPrint("Firebase not supported on this platform.");
    }
  }

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
        '/block_builder': (context) => const BlockBuilderScreen(),
        '/block_builder_2': (context) => const BlockBuilder2(),

      },
    );
  }
}
