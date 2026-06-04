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
import 'week_planner.dart'; // Update path if needed
import 'planned_blocks_screen.dart';
import 'Block_Planner.dart';
import 'SavedWorkoutsScreen.dart';
import 'bb3_week_planner.dart';
import 'WES2_screen.dart';
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
import 'package:facebook_app_events/facebook_app_events.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'auth_debug.dart';
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






// Auth lifecycle phases for the root state machine.
enum _AuthPhase { loading, restoring, tokenPending, authenticated, unauthenticated }

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  // SharedPreferences key written true only on an explicit user-initiated logout.
  // Prevents treating Firebase Auth's transient null on cold-start as a real logout.
  static const _kExplicitLogout = 'goodlift_explicit_logout';
  static const _kLastLoginProvider = 'goodlift_last_login_provider';

  static const _devCoachUids = {
    'yoVAqScwLMQLAgNHh8v9IK49fBw2', // Richard Razorsedge
    'wuiMe7phxYQh0MM39bfnhgv20yS2',
    'SMTEVGPH1MXgOgbcBbJFU1HjU8G3',
    'jhIB7Yi1whYwPvBSmK27KltJGn23',
    'ejBDKEZPFfQz2Sdzd7BZlNydxZ33', // Adam@razorsedgept
    'L7YjSMnm7tXD3BwyskmmrgVhKsS2', // Ruby cakes
    'ykx0RvDMc5OIuZ2R4kqWMhGbrGV2', // Google Play reviewer
  };

  _AuthPhase _phase = _AuthPhase.loading;

  // Monotonically increasing counter; each auth event captures its own gen value.
  // Guards every async continuation so stale async chains are dropped when a
  // newer auth event supersedes them.
  int _authGen = 0;

  // Memoized per uid — reset on sign-out or uid change.
  String? _memoUid;
  Future<IdTokenResult>? _tokenFuture;
  UserContext? _userContext;

  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    _authSub = FirebaseAuth.instance.authStateChanges().listen(_onAuthEvent);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  // ─── auth stream handler ──────────────────────────────────────────────────

  Future<void> _onAuthEvent(User? user) async {
    final gen = ++_authGen;
    debugPrint(
      '[AUTHROOT] authStateChanges uid=${user?.uid} '
      'isAnon=${user?.isAnonymous} gen=$gen',
    );
    // Fire-and-forget — breadcrumb is diagnostic only, must not block routing.
    unawaited(writeAuthBreadcrumb(
      'authStateChanges uid=${user?.uid} isAnon=${user?.isAnonymous}',
    ));
    if (user != null && !user.isAnonymous) {
      await _handleValidUser(user, gen);
    } else {
      await _handleNullOrAnon(gen);
    }
  }

  // ─── valid-user path ──────────────────────────────────────────────────────

  Future<void> _handleValidUser(User user, int gen) async {
    if (gen != _authGen || !mounted) return;

    // Clear explicit-logout flag whenever Firebase confirms a real user.
    final prefs = await SharedPreferences.getInstance();
    if (gen != _authGen || !mounted) return;
    await prefs.setBool(_kExplicitLogout, false);

    // Memoize per uid so WarmupService is not re-triggered on provider rebuilds.
    if (user.uid != _memoUid) {
      _memoUid = user.uid;
      _tokenFuture = user.getIdTokenResult();
      _userContext = null;
    }

    if (_userContext == null) {
      if (mounted) setState(() => _phase = _AuthPhase.tokenPending);
      try {
        final token = await _tokenFuture!;
        if (gen != _authGen || !mounted) return;
        if (_userContext == null) {
          final isCoach =
              (token.claims?['isCoach'] == true) ||
              _devCoachUids.contains(user.uid);
          ensureMembershipDoc(user.uid);
          upsertUserLookup();
          _userContext = UserContext(actorUid: user.uid, isCoach: isCoach);
          _userContext!.bootstrapBlockMeta(uid: user.uid);
        }
      } catch (e) {
        debugPrint('[AUTHROOT] getIdTokenResult failed: $e — falling back to uid-only coach check');
        if (gen != _authGen || !mounted) return;
        if (_userContext == null) {
          final isCoach = _devCoachUids.contains(user.uid);
          ensureMembershipDoc(user.uid);
          upsertUserLookup();
          _userContext = UserContext(actorUid: user.uid, isCoach: isCoach);
          _userContext!.bootstrapBlockMeta(uid: user.uid);
        }
      }
    }

    if (gen != _authGen || !mounted) return;
    await writeAuthBreadcrumb('authenticated uid=${user.uid}');
    setState(() => _phase = _AuthPhase.authenticated);
  }

  // ─── null / anon path with restore grace period ──────────────────────────

  Future<void> _handleNullOrAnon(int gen) async {
    if (!mounted) return;

    final prefs = await SharedPreferences.getInstance();
    if (gen != _authGen || !mounted) return;

    final explicitLogout = prefs.getBool(_kExplicitLogout) ?? false;
    debugPrint('[AUTHNULL] gen=$gen explicitLogout=$explicitLogout phase=$_phase');

    if (explicitLogout) {
      await writeAuthBreadcrumb('nullEvent explicitLogout=true showLogin gen=$gen');
      _clearMemo();
      setState(() => _phase = _AuthPhase.unauthenticated);
      return;
    }

    await writeAuthBreadcrumb('nullEvent explicitLogout=false startRestore gen=$gen');
    // Unexpected null (cold-start race, token refresh, Play Integrity delay).
    // Do NOT show Login yet — run a multi-step restore check first.
    debugPrint('[AUTHRESTORE] starting restore grace period gen=$gen');
    setState(() => _phase = _AuthPhase.restoring);

    // Step 1: synchronous currentUser read.
    var current = FirebaseAuth.instance.currentUser;
    debugPrint('[AUTHRESTORE] step1 currentUser=${current?.uid}');
    if (current != null && !current.isAnonymous) {
      await _handleValidUser(current, gen);
      return;
    }

    // Step 2: brief pause, then re-read.
    await Future.delayed(const Duration(milliseconds: 1500));
    if (gen != _authGen || !mounted) return;
    current = FirebaseAuth.instance.currentUser;
    debugPrint('[AUTHRESTORE] step2 currentUser(1.5s)=${current?.uid}');
    if (current != null && !current.isAnonymous) {
      await _handleValidUser(current, gen);
      return;
    }

    // Step 3: wait for idTokenChanges to emit a real user (up to 3 s).
    // Catches the case where Firebase Auth finishes loading the cached user
    // slightly after authStateChanges already emitted null.
    debugPrint('[AUTHRESTORE] step3 waiting on idTokenChanges (3s timeout)');
    try {
      final restored = await FirebaseAuth.instance
          .idTokenChanges()
          .where((u) => u != null && !u.isAnonymous)
          .first
          .timeout(const Duration(seconds: 3));
      if (gen != _authGen || !mounted) return;
      if (restored != null && !restored.isAnonymous) {
        debugPrint('[AUTHRESTORE] idTokenChanges uid=${restored.uid}');
        await _handleValidUser(restored, gen);
        return;
      }
    } catch (_) {
      debugPrint('[AUTHRESTORE] idTokenChanges timed out or errored');
    }

    // Step 4: final synchronous check before giving up.
    if (gen != _authGen || !mounted) return;
    current = FirebaseAuth.instance.currentUser;
    debugPrint('[AUTHRESTORE] step4 final currentUser=${current?.uid}');
    if (current != null && !current.isAnonymous) {
      await _handleValidUser(current, gen);
      return;
    }

    // Step 5: silent Google restore — only runs when last provider was Google.
    if (gen != _authGen || !mounted) return;
    final silentlyRestored = await _trySilentGoogleRestore(gen);
    if (silentlyRestored != null && !silentlyRestored.isAnonymous) {
      await _handleValidUser(silentlyRestored, gen);
      return;
    }

    debugPrint('[AUTHNULL] all restore checks confirm no user — showing Login');
    await writeAuthBreadcrumb('allRestoreChecksFailed showLogin gen=$gen');
    _clearMemo();
    setState(() => _phase = _AuthPhase.unauthenticated);
  }

  void _clearMemo() {
    _memoUid = null;
    _tokenFuture = null;
    _userContext = null;
  }

  // ─── silent Google restore ────────────────────────────────────────────────

  Future<User?> _trySilentGoogleRestore(int gen) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (gen != _authGen || !mounted) return null;

      final lastProvider = prefs.getString(_kLastLoginProvider);
      if (lastProvider != 'google') {
        await writeAuthBreadcrumb('silentGoogleRestore skipped lastProvider=$lastProvider gen=$gen');
        return null;
      }

      final googleUser = await GoogleSignIn().signInSilently();
      if (gen != _authGen || !mounted) return null;

      if (googleUser == null) {
        await writeAuthBreadcrumb('silentGoogleRestore noAccount gen=$gen');
        debugPrint('[AUTHRESTORE] silentGoogleRestore: no Google account returned');
        return null;
      }

      final googleAuth = await googleUser.authentication;
      if (gen != _authGen || !mounted) return null;

      final accessTokenPresent = googleAuth.accessToken != null;
      final idTokenPresent = googleAuth.idToken != null;
      debugPrint('[AUTHRESTORE] silentGoogleRestore accessTokenPresent=$accessTokenPresent idTokenPresent=$idTokenPresent');

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final cred = await FirebaseAuth.instance.signInWithCredential(credential);
      if (gen != _authGen || !mounted) return null;

      await prefs.setBool(_kExplicitLogout, false);
      await writeAuthBreadcrumb('silentGoogleRestore success uid=${cred.user?.uid} gen=$gen');
      debugPrint('[AUTHRESTORE] silentGoogleRestore success uid=${cred.user?.uid}');
      return cred.user;
    } on FirebaseAuthException catch (e) {
      await writeAuthBreadcrumb('silentGoogleRestore FirebaseAuthException ${e.code} gen=$gen');
      debugPrint('[AUTHRESTORE] silentGoogleRestore FirebaseAuthException: $e');
      return null;
    } catch (e) {
      await writeAuthBreadcrumb('silentGoogleRestore error gen=$gen');
      debugPrint('[AUTHRESTORE] silentGoogleRestore error: $e');
      return null;
    }
  }

  // ─── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    debugPrint('[AUTHROOT] build phase=$_phase');
    switch (_phase) {
      case _AuthPhase.loading:
      case _AuthPhase.restoring:
      case _AuthPhase.tokenPending:
        return const MaterialApp(
          home: Scaffold(body: Center(child: CircularProgressIndicator())),
        );
      case _AuthPhase.unauthenticated:
        return const MyApp(isAuthenticated: false);
      case _AuthPhase.authenticated:
        if (_userContext == null) {
          return const MaterialApp(
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }
        return ChangeNotifierProvider<UserContext>.value(
          value: _userContext!,
          child: const MyApp(isAuthenticated: true),
        );
    }
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


  if (!kIsWeb && Platform.isIOS) {
    await FacebookAppEvents().activateApp();
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
  final bool isAuthenticated;
  const MyApp({super.key, required this.isAuthenticated});

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

      // AppRoot is the single auth-state authority — no second authStateChanges() here.
      home: isAuthenticated
          ? const MembershipGate(child: HomeScreen())
          : const LoginScreen(),

      routes: {
        '/login': (context) => const LoginScreen(),
        '/home': (context) => const MembershipGate(child: HomeScreen()),

        '/exercises': (context) => const ExercisesScreen(),
        '/templates': (context) => const TemplatesScreen(),
        '/workouts': (context) => const Wes2Screen(),
        '/week_planner': (context) => const BB3WeekPlanner(),
        '/body_weight_tracker': (context) => const BodyWeightTracker(),
        '/planned_blocks': (context) => const PlannedBlocksScreen(),
        '/block_builder': (context) => const Block_Planner(),
        '/workout_entry': (c) => const Wes2Screen(),
        '/week_planner_b': (c) => const BB3WeekPlanner(),
        '/saved_workouts': (c) => const SavedWorkoutsScreen(),
        '/body_weight': (c) => const BodyWeightTracker(),
        '/coach_home': (context) => const CoachHomeScreen(),
        '/bb3_week_planner': (_) => const BB3WeekPlanner(),

      },

    );
  }
}
