import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'dart:io'; // 👈 Needed for Platform check
import 'package:firebase_auth/firebase_auth.dart';
import 'body_weight_tracker.dart'; // Import the new file
import 'exercises.dart';
import 'home_screen.dart';
import 'login_screen.dart';
import 'templates.dart';
import 'workout_entry_screen.dart';
import 'week_planner.dart'; // Update path if needed
import 'planned_blocks_screen.dart';
import 'Block_Planner.dart';
import 'SavedWorkoutsScreen.dart';

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
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasData) {
          // ✅ User is signed in
          return const HomeScreen();
        } else {
          // 🔐 Not signed in
          return const LoginScreen();
        }
      },
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Re App',

      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', 'US'),
        Locale('en', 'GB'), // Monday-first week
        // add any others you need…
      ],

      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.blueGrey.shade900,
        primaryColor: Colors.lightBlueAccent,
        colorScheme: ColorScheme.dark(
          primary: Colors.lightBlueAccent,
          onPrimary: Colors.white,
          surface: Colors.blueGrey.shade800,
          onSurface: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blueGrey.shade700,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        iconTheme: const IconThemeData(
          color: Colors.white70,
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white),
          labelLarge: TextStyle(color: Colors.white),
        ),
      ),

      home: AuthGate(), // 👈 this new widget decides where to go
      routes: {
        '/login': (context) => const LoginScreen(),
        '/home': (context) => const HomeScreen(),
        '/exercises': (context) => const ExercisesScreen(),
        '/templates': (context) => const TemplatesScreen(),
        '/workouts': (context) => const WorkoutPage(),
        '/body_weight_tracker': (context) => const BodyWeightTracker(),
        '/block_builder_2': (context) => const WeekPlanner(),
        '/planned_blocks': (context) => const PlannedBlocksScreen(),
        '/block_builder': (context) => const Block_Planner(),
        '/workout_entry':   (c) => const WorkoutPage(),                // new workout
        '/week_planner':   (c) => const WeekPlanner(),              // training schedule
        '/saved_workouts':  (c) => const SavedWorkoutsScreen(),        // saved workouts
        '/body_weight':     (c) => const BodyWeightTracker(),          // weight tracker
      },
    );
  }
}
