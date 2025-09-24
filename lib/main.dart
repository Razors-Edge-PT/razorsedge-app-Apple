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
import 'Camp_BB2.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'coach_home_screen.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_app_check/firebase_app_check.dart';

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const MaterialApp(home: LoginScreen());
        }

        final user = snapshot.data!;
        return FutureBuilder<IdTokenResult>(
          future: user.getIdTokenResult(),
          builder: (context, tokenSnap) {
            if (!tokenSnap.hasData) {
              return const MaterialApp(home: Scaffold(body: Center(child: CircularProgressIndicator())));
            }

            final token = tokenSnap.data!;
            const devCoachUids = {
              'yoVAqScwLMQLAgNHh8v9IK49fBw2', // Richard
              'wuiMe7phxYQh0MM39bfnhgv20yS2', //Campbell
              'SMTEVGPH1MXgOgbcBbJFU1HjU8G3', // Adam
            };
            final isCoachClaim = token.claims?['isCoach'] == true;
            final isCoach = isCoachClaim || devCoachUids.contains(user.uid);

            upsertUserLookup(); // fire and forget is fine here

            final userContext = UserContext(actorUid: user.uid, isCoach: isCoach);

            // 🐛 DEBUG: Confirm coach/admin flags for this login
            print('🔍 UID: ${user.uid} | isCoach: $isCoach | isAdmin: ${userContext.isAdmin}');

            // ── ANCHOR APP-ROOT:A — bootstrap global block meta (non-blocking; kicks WarmupService too)
            // NOTE: safe to call before providing; it doesn't need BuildContext.
            // Do NOT await—this hydrates from prefs instantly and refreshes server in background.
            // If you prefer, you can import dart:async and use `unawaited(...)` here.
            userContext.bootstrapBlockMeta(uid: user.uid);

            return ChangeNotifierProvider<UserContext>.value(
              value: userContext,
              child: const MyApp(), // 🟢 Now provider wraps entire app
            );
          },
        );

      },
    );
  }
}


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }

  // 👇 App Check: Play Integrity in release, Debug provider in dev
  await FirebaseAppCheck.instance.activate(
    androidProvider: kReleaseMode
        ? AndroidProvider.playIntegrity
        : AndroidProvider.debug,
    appleProvider: AppleProvider.deviceCheck, // harmless on Android
  );

  runApp(const AppRoot());
}


class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  Future<Widget> _buildHome(User user) async {
    final token = await user.getIdTokenResult();

    const devCoachUids = {
      'yoVAqScwLMQLAgNHh8v9IK49fBw2', // ✅ your UID
    };

    final isCoachClaim = token.claims?['isCoach'] == true;
    final isCoach = isCoachClaim || devCoachUids.contains(user.uid);

    final userContext = UserContext(
      actorUid: user.uid,
      isCoach: isCoach,
    );

    print("🧪 UID match = ${devCoachUids.contains(user.uid)}");
    print("🔐 Logged in as ${user.uid} — Coach: $isCoach");

    return ChangeNotifierProvider<UserContext>.value(
      value: userContext,
      child: const HomeScreen(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        if (snapshot.hasData) {
          return FutureBuilder<Widget>(
            future: _buildHome(snapshot.data!),
            builder: (context, futureSnap) {
              if (!futureSnap.hasData) {
                return const Scaffold(body: Center(child: CircularProgressIndicator()));
              }
              return futureSnap.data!;
            },
          );
        } else {
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
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.blueGrey.shade900,
          foregroundColor: Colors.white, // affects title/icon colors
          titleTextStyle: GoogleFonts.monda(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ).copyWith(
            fontFamilyFallback: const ['Roboto', 'Helvetica', 'Arial'],
          ),
          toolbarTextStyle: GoogleFonts.monda(
            color: Colors.white,
            fontSize: 16,
          ).copyWith(
            fontFamilyFallback: const ['Roboto', 'Helvetica', 'Arial'],
          ),
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
        iconTheme: const IconThemeData(color: Colors.white70),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white),
          labelLarge: TextStyle(color: Colors.white),
        ),
      ),


      // ✅ Provider< UserContext > is now already wrapping this via AppRoot
      home: const HomeScreen(),
      routes: {
        '/login': (context) => const LoginScreen(),
        '/home': (context) => const HomeScreen(),
        '/exercises': (context) => const ExercisesScreen(),
        '/templates': (context) => const TemplatesScreen(),
        '/workouts': (context) => const WorkoutPage(),
        '/week_planner': (context) => const Camp_BB2(),         // ✅ Only once
        '/body_weight_tracker': (context) => const BodyWeightTracker(),
        '/planned_blocks': (context) => const PlannedBlocksScreen(),
        '/block_builder': (context) => const Block_Planner(),
        '/workout_entry': (c) => const WorkoutPage(),
        '/week_planner_b': (c) => const Camp_BB2(),
        '/saved_workouts': (c) => const SavedWorkoutsScreen(),
        '/body_weight': (c) => const BodyWeightTracker(),
        '/coach_home': (context) => const CoachHomeScreen(),

      },

    );
  }
}
