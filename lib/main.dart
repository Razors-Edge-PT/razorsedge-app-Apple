import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

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
import 'membership_gate.dart';
import 'theme_controller.dart';
import 'app_theme.dart';




final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();
// ── ANCHOR ROOT-SNACKBAR-KEY:A — global messenger for SnackBars (no BuildContext needed)
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
GlobalKey<ScaffoldMessengerState>();


// ── ANCHOR ROOT-SNACKBAR:SHOW — ultra-safe snackbar (post-save)
void showAppSnack(String message) {
  Future<void>.delayed(const Duration(milliseconds: 250), () {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      debugPrint('⚠️ showAppSnack skipped (app not resumed)');
      return;
    }

    final sm = rootScaffoldMessengerKey.currentState;
    if (sm == null || !sm.mounted) {
      debugPrint('⚠️ showAppSnack skipped (messenger not ready)');
      return;
    }

    try {
      sm.clearSnackBars();
      sm.showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      debugPrint('⚠️ showAppSnack failed: $e');
    }
  });
}






class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

/// Memoizes UserContext and the token future so that widget-tree rebuilds caused
/// by theme changes (ThemeController notifying) do NOT recreate UserContext or
/// retrigger WarmupService / Isar side effects.
class _AppRootState extends State<AppRoot> {
  static const _devCoachUids = {
    'yoVAqScwLMQLAgNHh8v9IK49fBw2', // Richard Razorsedge
    'wuiMe7phxYQh0MM39bfnhgv20yS2',
    'SMTEVGPH1MXgOgbcBbJFU1HjU8G3',
    'jhIB7Yi1whYwPvBSmK27KltJGn23',
    'ejBDKEZPFfQz2Sdzd7BZlNydxZ33', // Adam@razorsedgept
    'L7YjSMnm7tXD3BwyskmmrgVhKsS2', // Ruby cakes
    'ykx0RvDMc5OIuZ2R4kqWMhGbrGV2', // Google Play reviewer
  };

  // Memoized per authenticated uid — reset on sign-out or uid change.
  String? _memoUid;
  Future<IdTokenResult>? _tokenFuture;
  UserContext? _userContext;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snap) {
        final user = snap.data;

        // Not logged in → clear memo and show unauthenticated app shell.
        if (user == null) {
          _memoUid = null;
          _tokenFuture = null;
          _userContext = null;
          return const MyApp();
        }

        // Only fetch token once per uid — prevents spurious WarmupService calls
        // on widget-tree rebuilds triggered by theme/provider changes.
        if (user.uid != _memoUid) {
          _memoUid = user.uid;
          _tokenFuture = user.getIdTokenResult();
          _userContext = null; // will be created after token resolves
        }

        return FutureBuilder<IdTokenResult>(
          future: _tokenFuture,
          builder: (context, tokenSnap) {
            if (tokenSnap.connectionState == ConnectionState.waiting || !tokenSnap.hasData) {
              return const MaterialApp(
                home: Scaffold(body: Center(child: CircularProgressIndicator())),
              );
            }

            // Create UserContext exactly once per uid.
            if (_userContext == null) {
              final token = tokenSnap.data!;
              final isCoach =
                  (token.claims?['isCoach'] == true) ||
                  _devCoachUids.contains(user.uid);

              ensureMembershipDoc(user.uid);
              upsertUserLookup();

              _userContext = UserContext(actorUid: user.uid, isCoach: isCoach);
              _userContext!.bootstrapBlockMeta(uid: user.uid);
            }

            return ChangeNotifierProvider<UserContext>.value(
              value: _userContext!,
              child: const MyApp(),
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
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }


  // Search-bar anchor: FirebaseAppCheck.instance.activate
  // ✅ Production-safe: App Check should never prevent the UI from rendering.
  try {
    await FirebaseAppCheck.instance.activate(
      androidProvider: kReleaseMode
          ? AndroidProvider.playIntegrity
          : AndroidProvider.debug,

      appleProvider: kReleaseMode
          ? AppleProvider.deviceCheck
          : AppleProvider.debug,
    );
  } catch (e, st) {
    debugPrint('❌ AppCheck activate failed: $e');
    debugPrint('$st');
  }


  final themeController = ThemeController();
  await themeController.load();

  runApp(
    ChangeNotifierProvider<ThemeController>.value(
      value: themeController,
      child: const AppRoot(),
    ),
  );
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
    final tc = context.watch<ThemeController>();
    return MaterialApp(
      scaffoldMessengerKey: rootScaffoldMessengerKey, // ✅ ROOT-SNACKBAR-KEY wired
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

      theme: AppTheme.light(primary: tc.primaryColor, secondary: tc.secondaryColor, tertiary: tc.tertiaryColor),
      darkTheme: AppTheme.dark(primary: tc.primaryColor, secondary: tc.secondaryColor, tertiary: tc.tertiaryColor),
      themeMode: tc.themeMode,
      navigatorObservers: [routeObserver],

      // ✅ Home is now gated by membership
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          if (!snap.hasData) return const LoginScreen();
          return const MembershipGate(child: HomeScreen());
        },
      ),

      routes: {
        '/login': (context) => const LoginScreen(),
        '/home': (context) => const MembershipGate(child: HomeScreen()),

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
