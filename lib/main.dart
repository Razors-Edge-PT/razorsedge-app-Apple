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
import 'home_screen_2.dart';
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
import 'package:facebook_app_events/facebook_app_events.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'auth_debug.dart';
import 'membership_gate.dart';
import 'theme_controller.dart';
import 'app_theme.dart';
import 'app_check_ready.dart';
import 'startup_route_service.dart';
import 'startup_trace.dart';




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
  // Per-uid cache of isCoach so we never block on getIdTokenResult at startup.
  static const _kCoachCache = 'goodlift_iscoach_'; // + uid suffix

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

  // Major route to restore on this cold start. Resolved (UID-keyed) during
  // _handleValidUser before _phase becomes authenticated, so MyApp's initial
  // route stack is built directly into WES2 when appropriate (no Home flash).
  StartupDestination _startupDestination = StartupDestination.home;

  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => StartupTrace.firstFrame());
    _authSub = FirebaseAuth.instance.authStateChanges().listen(_onAuthEvent);

    // ── Synchronous fast path ────────────────────────────────────────────────
    // For a remembered (already-restored) user, route immediately instead of
    // waiting for authStateChanges to emit or for the 2 s watchdog. The
    // explicit-logout prerequisite is enforced INSIDE _handleValidUser, so a
    // stale cached Firebase user can never override a deliberate logout, and
    // the logout flag is never cleared before being confirmed false for this
    // generation. Stale async chains are dropped via the _authGen guards.
    final fastGen = ++_authGen;
    final cached = FirebaseAuth.instance.currentUser;
    StartupTrace.cachedUserRead(cached?.uid);
    if (cached != null && !cached.isAnonymous) {
      unawaited(_handleValidUser(cached, fastGen));
    }
    // Watchdog: if authStateChanges never emits within 2 s (Play Integrity / cold-start
    // race), manually kick the auth path so _phase never stays loading forever.
    Future.delayed(const Duration(seconds: 2), () async {
      if (!mounted || _phase != _AuthPhase.loading) return;
      final gen = ++_authGen;
      final user = FirebaseAuth.instance.currentUser;
      await writeAuthBreadcrumb(
          'AUTHWATCHDOG startup phaseStillLoading currentUser=${user?.uid} gen=$gen');
      debugPrint('[AUTHWATCHDOG] startup triggered gen=$gen user=${user?.uid}');
      if (user != null && !user.isAnonymous) {
        await _handleValidUser(user, gen);
      } else {
        await _handleNullOrAnon(gen);
      }
    });

    // Hard cap: if restoring/tokenPending is still stuck after 12 s, try a final
    // currentUser read. Only force Login when the user explicitly logged out —
    // a slow network must never kick a remembered user back to the login screen.
    Future.delayed(const Duration(seconds: 12), () async {
      if (!mounted) return;
      if (_phase != _AuthPhase.restoring && _phase != _AuthPhase.tokenPending) return;
      final gen = ++_authGen;
      final phaseLabel = _phase.name;
      await writeAuthBreadcrumb(
        'AUTHWATCHDOG hardCap phase=$phaseLabel checking explicitLogout gen=$gen',
      );
      debugPrint('[AUTHWATCHDOG] hardCap phase=$phaseLabel gen=$gen — checking explicitLogout');

      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;

      final explicitLogout = prefs.getBool(_kExplicitLogout) ?? false;
      if (explicitLogout) {
        await writeAuthBreadcrumb(
          'AUTHWATCHDOG hardCap explicitLogout=true forcingLogin gen=$gen',
        );
        debugPrint('[AUTHWATCHDOG] hardCap explicitLogout=true — forcing login');
        _clearMemo();
        setState(() => _phase = _AuthPhase.unauthenticated);
        return;
      }

      // Not an explicit logout — attempt one final currentUser recovery.
      final current = FirebaseAuth.instance.currentUser;
      if (current != null && !current.isAnonymous) {
        await writeAuthBreadcrumb(
          'AUTHWATCHDOG hardCap recoveredUser uid=${current.uid} gen=$gen',
        );
        debugPrint('[AUTHWATCHDOG] hardCap: found currentUser ${current.uid} — recovering');
        await _handleValidUser(current, gen);
      } else {
        // Still no user but no explicit logout — log and leave the phase alone.
        // The user may be on a very poor connection; we must not force them to Login.
        await writeAuthBreadcrumb(
          'AUTHWATCHDOG hardCap noUser noExplicitLogout — leaving phase=$phaseLabel gen=$gen',
        );
        debugPrint(
          '[AUTHWATCHDOG] hardCap: no user, no explicit logout — not forcing Login',
        );
      }
    });
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

    final prefs = await SharedPreferences.getInstance();
    if (gen != _authGen || !mounted) return;

    // ── Explicit-logout prerequisite (shared by EVERY valid-user caller:
    // the synchronous fast path, authStateChanges, the watchdogs, restore
    // steps and silent Google restore all route through here). A stale cached
    // Firebase user must never override a deliberate logout, and the flag must
    // not be cleared until it has been confirmed false for THIS generation.
    final explicitLogout = prefs.getBool(_kExplicitLogout) ?? false;
    if (explicitLogout) {
      unawaited(writeAuthBreadcrumb(
          'handleValidUser explicitLogout=true → unauthenticated gen=$gen'));
      if (gen != _authGen || !mounted) return;
      _clearMemo();
      setState(() => _phase = _AuthPhase.unauthenticated);
      return;
    }

    // Confirmed false → safe to clear. Fire-and-forget so the disk write never
    // delays routing.
    unawaited(prefs.setBool(_kExplicitLogout, false));

    // Memoize per uid so WarmupService is not re-triggered on provider rebuilds.
    if (user.uid != _memoUid) {
      _memoUid = user.uid;
      _tokenFuture = user.getIdTokenResult();
      _userContext = null;
    }

    if (_userContext == null) {
      // Determine isCoach without waiting on the network token.
      // Priority: (1) hardcoded dev/admin list (sync), (2) cached prefs value from
      // last session (sync), (3) background token refresh updates cache for next open.
      bool isCoach = _devCoachUids.contains(user.uid);
      if (!isCoach) {
        isCoach = prefs.getBool('$_kCoachCache${user.uid}') ?? false;
      }
      debugPrint(
        '[AUTHROOT] isCoach=$isCoach (sync, uid=${user.uid}) — '
        'token refreshing in background',
      );

      ensureMembershipDoc(user.uid);
      upsertUserLookup();
      _userContext = UserContext(actorUid: user.uid, isCoach: isCoach);
      _userContext!.bootstrapBlockMeta(uid: user.uid);

      // Background: resolve real token claim, persist for next session, rebuild
      // UserContext only if coach status changed.
      _resolveTokenInBackground(
        user: user,
        gen: gen,
        prefs: prefs,
        currentIsCoach: isCoach,
      );
    }

    // Resolve the UID-keyed restore destination from prefs already in hand, so
    // MyApp builds the initial route stack straight into WES2 when appropriate
    // (no transient Home frame). Defaults to Home on any miss/mismatch/error.
    final dest = await StartupRouteService.readStartupDestination(user.uid);
    if (gen != _authGen || !mounted) return;
    _startupDestination = dest;
    StartupTrace.restoredDestination(dest.name);

    unawaited(writeAuthBreadcrumb('authenticated uid=${user.uid}'));
    // Route immediately — never stall on tokenPending for remembered users.
    StartupTrace.authenticatedSelected();
    setState(() => _phase = _AuthPhase.authenticated);
  }

  /// Resolves the Firebase ID token in background and keeps isCoach prefs up to date.
  /// Rebuilds UserContext only if coach status differs from what we assumed at startup.
  void _resolveTokenInBackground({
    required User user,
    required int gen,
    required SharedPreferences prefs,
    required bool currentIsCoach,
  }) {
    final tokenFuture = _tokenFuture;
    if (tokenFuture == null) return;

    tokenFuture.timeout(const Duration(seconds: 10)).then((token) async {
      if (!mounted) return;
      final isCoachFromToken =
          (token.claims?['isCoach'] == true) || _devCoachUids.contains(user.uid);

      // Persist authoritative value for next cold start.
      await prefs.setBool('$_kCoachCache${user.uid}', isCoachFromToken);
      debugPrint(
        '[AUTHROOT] background token resolved: uid=${user.uid} '
        'isCoach=$isCoachFromToken (was $currentIsCoach)',
      );
      await writeAuthBreadcrumb(
        'tokenResolved uid=${user.uid} isCoach=$isCoachFromToken gen=$gen',
      );

      // If coach status changed, rebuild UserContext so the UI reflects reality.
      if (mounted && gen == _authGen && isCoachFromToken != currentIsCoach) {
        debugPrint(
          '[AUTHROOT] coach status $currentIsCoach→$isCoachFromToken — '
          'rebuilding UserContext uid=${user.uid}',
        );
        final newCtx = UserContext(actorUid: user.uid, isCoach: isCoachFromToken);
        setState(() => _userContext = newCtx);
        unawaited(newCtx.bootstrapBlockMeta(uid: user.uid));
      }
    }).catchError((Object e) async {
      debugPrint('[AUTHROOT] background token resolve failed: $e');
      await writeAuthBreadcrumb(
        'tokenResolveFailed uid=${user.uid} gen=$gen err=$e',
      );
      // Persist current best-guess so it is used on next cold start.
      await prefs.setBool('$_kCoachCache${user.uid}', currentIsCoach);
    });
  }

  // ─── null / anon path with restore grace period ──────────────────────────

  Future<void> _handleNullOrAnon(int gen) async {
    if (!mounted) return;

    // Transient-null guard: authStateChanges can emit a spurious null on cold
    // start (the very reason the restore grace exists). If the synchronous fast
    // path already authenticated and Firebase still holds a non-anon
    // currentUser, this null is NOT a logout — do not downgrade the live
    // authenticated UI to a restore spinner. A real logout leaves currentUser
    // null and still flows through below.
    final liveUser = FirebaseAuth.instance.currentUser;
    if (_phase == _AuthPhase.authenticated &&
        liveUser != null &&
        !liveUser.isAnonymous) {
      debugPrint('[AUTHNULL] ignoring transient null — authenticated user '
          '${liveUser.uid} still present gen=$gen');
      return;
    }

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

    // Step 5: silent Google restore — only when last provider was Google.
    // signInWithCredential fires authStateChanges() as a side-effect, advancing
    // _authGen before _trySilentGoogleRestore returns. The function still returns
    // the user on success; we handle gen state here in the caller.
    if (gen != _authGen || !mounted) return;
    final silentlyRestored = await _trySilentGoogleRestore(gen);
    if (silentlyRestored != null && !silentlyRestored.isAnonymous) {
      if (gen == _authGen && mounted) {
        await writeAuthBreadcrumb(
            'silentGoogleRestore returnedUser handleValidUser gen=$gen');
        await _handleValidUser(silentlyRestored, gen);
      } else {
        await writeAuthBreadcrumb(
            'silentGoogleRestore returnedUser newerGenOwnsRouting gen=$gen currentGen=$_authGen');
        debugPrint(
            '[AUTHRESTORE] silentGoogleRestore succeeded — gen=$_authGen owns routing, not falling to Login');
      }
      return;
    }

    debugPrint('[AUTHNULL] all restore checks confirm no user — showing Login');
    await writeAuthBreadcrumb('allRestoreChecksFailed showLogin gen=$gen');
    if (gen != _authGen || !mounted) {
      await writeAuthBreadcrumb(
          'allRestoreChecksFailed skipped stale gen=$gen currentGen=$_authGen');
      return;
    }
    _clearMemo();
    setState(() => _phase = _AuthPhase.unauthenticated);
  }

  void _clearMemo() {
    _memoUid = null;
    _tokenFuture = null;
    _userContext = null;
  }

  // ─── silent Google restore ────────────────────────────────────────────────
  // Returns the signed-in Firebase User on success, null otherwise.
  //
  // Key invariant: after signInWithCredential resolves successfully we do NOT
  // gate on gen != _authGen. signInWithCredential fires authStateChanges() as a
  // side-effect, incrementing _authGen before this continuation resumes. That is
  // expected, not a failure — the credential exchange succeeded. The caller
  // (step 5 in _handleNullOrAnon) is responsible for routing based on gen state.

  Future<User?> _trySilentGoogleRestore(int gen) async {
    var step = 'init';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (gen != _authGen || !mounted) return null;

      final lastProvider = prefs.getString(_kLastLoginProvider);
      if (lastProvider != 'google') {
        await writeAuthBreadcrumb(
            'silentGoogleRestore skipped lastProvider=$lastProvider gen=$gen');
        return null;
      }

      await writeAuthBreadcrumb('silentGoogleRestore start gen=$gen');

      step = 'signInSilently';
      await writeAuthBreadcrumb(
          'silentGoogleRestore signInSilently start gen=$gen');
      final googleUser = await GoogleSignIn()
          .signInSilently()
          .timeout(const Duration(seconds: 4));
      if (gen != _authGen || !mounted) return null;

      if (googleUser == null) {
        await writeAuthBreadcrumb('silentGoogleRestore noAccount gen=$gen');
        debugPrint('[AUTHRESTORE] silentGoogleRestore: no Google account returned');
        return null;
      }

      step = 'authTokens';
      await writeAuthBreadcrumb(
          'silentGoogleRestore authTokens start gen=$gen');
      final googleAuth =
          await googleUser.authentication.timeout(const Duration(seconds: 4));
      if (gen != _authGen || !mounted) return null;

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      step = 'firebaseCredential';
      await writeAuthBreadcrumb(
          'silentGoogleRestore firebaseCredential start gen=$gen');
      final cred = await FirebaseAuth.instance
          .signInWithCredential(credential)
          .timeout(const Duration(seconds: 6));

      // signInWithCredential succeeded — do NOT return null because gen
      // advanced. authStateChanges() fires as a side-effect and increments
      // _authGen; that is the expected path, not a fault. Log it and return.
      if (gen != _authGen) {
        await writeAuthBreadcrumb(
            'silentGoogleRestore success uid=${cred.user?.uid} gen=$gen currentGen=$_authGen — authStateChanges advanced gen');
        debugPrint(
            '[AUTHRESTORE] silentGoogleRestore success uid=${cred.user?.uid} — authStateChanges advanced gen to $_authGen');
      }
      await prefs.setBool(_kExplicitLogout, false);
      await writeAuthBreadcrumb(
          'silentGoogleRestore success uid=${cred.user?.uid} gen=$gen');
      debugPrint(
          '[AUTHRESTORE] silentGoogleRestore success uid=${cred.user?.uid}');
      return cred.user;
    } on TimeoutException {
      await writeAuthBreadcrumb(
          'silentGoogleRestore timeout step=$step gen=$gen');
      debugPrint('[AUTHRESTORE] silentGoogleRestore timeout at step=$step');
      return null;
    } on FirebaseAuthException catch (e) {
      await writeAuthBreadcrumb(
          'silentGoogleRestore FirebaseAuthException ${e.code} gen=$gen');
      debugPrint('[AUTHRESTORE] silentGoogleRestore FirebaseAuthException: $e');
      return null;
    } catch (e) {
      await writeAuthBreadcrumb(
          'silentGoogleRestore error step=$step gen=$gen');
      debugPrint('[AUTHRESTORE] silentGoogleRestore error at step=$step: $e');
      return null;
    }
  }

  // ─── build ────────────────────────────────────────────────────────────────

  /// Themed loading shell so the pre-auth spinner never flashes an unthemed
  /// (default Material) screen before the real theme is applied.
  Widget _loadingApp(BuildContext context) {
    final tc = context.watch<ThemeController>();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(
        primary: tc.primaryColor,
        secondary: tc.secondaryColor,
        tertiary: tc.tertiaryColor,
        quaternary: tc.quaternaryColor,
      ),
      darkTheme: AppTheme.dark(
        primary: tc.primaryColor,
        secondary: tc.secondaryColor,
        tertiary: tc.tertiaryColor,
        quaternary: tc.quaternaryColor,
      ),
      themeMode: tc.themeMode,
      home: const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[AUTHROOT] build phase=$_phase');
    switch (_phase) {
      case _AuthPhase.loading:
      case _AuthPhase.restoring:
      case _AuthPhase.tokenPending:
        return _loadingApp(context);
      case _AuthPhase.unauthenticated:
        return const MyApp(isAuthenticated: false);
      case _AuthPhase.authenticated:
        if (_userContext == null) {
          return _loadingApp(context);
        }
        return ChangeNotifierProvider<UserContext>.value(
          value: _userContext!,
          child: MyApp(
            isAuthenticated: true,
            startupDestination: _startupDestination,
          ),
        );
    }
  }
}


void main() async {

  StartupTrace.processStart();
  WidgetsFlutterBinding.ensureInitialized();
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
  StartupTrace.firebaseInitialized();

  // App Check: invoke activation SYNCHRONOUSLY (registers the provider before
  // any widget builds / any Firestore request can start) but do NOT await it —
  // the first visible Flutter frame must not wait on Play Integrity /
  // DeviceCheck attestation. Protected startup operations await `appCheckReady`
  // individually at their Firestore boundaries. See app_check_ready.dart.
  initAppCheck();
  StartupTrace.appCheckInvoked();
  unawaited(appCheckReady.then((_) => StartupTrace.appCheckSettled()));

  // Diagnostics/analytics — must never block the first frame.
  if (!kIsWeb && Platform.isIOS) {
    unawaited(FacebookAppEvents().activateApp());
  }

  // Theme load is a single SharedPreferences read (sub-ms) — kept awaited so
  // the first frame renders with the user's persisted theme (no theme flash).
  final themeController = ThemeController();
  await themeController.load();

  StartupTrace.runAppCalled();
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



// ── ROLLBACK FLAG — flip to false to restore HomeScreen (v1) as default.
const bool kUseHomeScreen2AsDefault = true;

class MyApp extends StatelessWidget {
  final bool isAuthenticated;
  final StartupDestination startupDestination;
  const MyApp({
    super.key,
    required this.isAuthenticated,
    this.startupDestination = StartupDestination.home,
  });

  /// Gated default Home — used by `/home`, the initial route, and as the
  /// restore target when a root WES2 route is deliberately exited.
  static Widget _gatedHome() => MembershipGate(
        child: kUseHomeScreen2AsDefault
            ? const HomeScreen2()
            : const HomeScreen(),
      );

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) {
      debugPrint(
        '🏠 [APP ROOT] Default home = '
        '${kUseHomeScreen2AsDefault ? "HomeScreen2" : "HomeScreen"}',
      );
    }
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

      theme: AppTheme.light(primary: tc.primaryColor, secondary: tc.secondaryColor, tertiary: tc.tertiaryColor, quaternary: tc.quaternaryColor),
      darkTheme: AppTheme.dark(primary: tc.primaryColor, secondary: tc.secondaryColor, tertiary: tc.tertiaryColor, quaternary: tc.quaternaryColor),
      themeMode: tc.themeMode,
      navigatorObservers: [routeObserver],

      // AppRoot is the single auth-state authority — no second authStateChanges() here.
      //
      // Authenticated: build the initial route stack directly via
      // onGenerateInitialRoutes (home must be null when that is set). When the
      // last major route was WES2 we restore ONLY a gated WES2 root — Home is
      // NOT constructed beneath it, so Home's heavy startup work cannot compete
      // with WES2 startup (Issue 5). The WES2 PopScope routes to '/home' when
      // that root is deliberately exited, preserving expected back behaviour.
      home: isAuthenticated ? null : const LoginScreen(),
      initialRoute: isAuthenticated ? '/home' : null,
      onGenerateInitialRoutes: isAuthenticated
          ? (_) {
              if (startupDestination == StartupDestination.wes2) {
                StartupTrace.restoredDestination('wes2');
                return [
                  MaterialPageRoute<void>(
                    settings: const RouteSettings(name: '/workouts'),
                    builder: (_) =>
                        const MembershipGate(child: Wes2Screen()),
                  ),
                ];
              }
              StartupTrace.restoredDestination('home');
              return [
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: '/home'),
                  builder: (_) => _gatedHome(),
                ),
              ];
            }
          : null,

      routes: {
        '/login': (context) => const LoginScreen(),
        '/home': (context) => _gatedHome(),

        '/exercises': (context) => const ExercisesScreen(),
        '/templates': (context) => const TemplatesScreen(),
        // Gated so a direct/deep-link to WES2 can never bypass the paywall.
        '/workouts': (context) => const MembershipGate(child: Wes2Screen()),
        '/week_planner': (context) => const BB3WeekPlanner(),
        '/body_weight_tracker': (context) => const BodyWeightTracker(),
        '/planned_blocks': (context) => const PlannedBlocksScreen(),
        '/block_builder': (context) => const Block_Planner(),
        '/workout_entry': (c) => const MembershipGate(child: Wes2Screen()),
        '/week_planner_b': (c) => const BB3WeekPlanner(),
        '/saved_workouts': (c) => const SavedWorkoutsScreen(),
        '/body_weight': (c) => const BodyWeightTracker(),
        '/coach_home': (context) => const CoachHomeScreen(),
        '/bb3_week_planner': (_) => const BB3WeekPlanner(),

      },

    );
  }
}
