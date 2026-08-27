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
import 'coach_mode/coach_mode_service.dart';
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
import 'silent_restore_coordinator.dart';
import 'valid_user_gate.dart';
import 'auth_diag.dart';
import 'auth_signout.dart';




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

class _AppRootState extends State<AppRoot> with WidgetsBindingObserver {
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

  // ── Cold-auth restoration budgets (Google graceful degradation) ────────────
  // Native auth (idTokenChanges / currentUser) restoration grace. Bounds how
  // long we wait for Firebase to surface a cached user after a spurious
  // cold-start null before that lane reports failure.
  static const Duration _nativeRestoreGrace = Duration(seconds: 4);
  // Overall failure budget for the concurrent restoration race. Backstop so the
  // restoring spinner can never linger near the old ~10–13 s; well under the
  // 12 s hard-cap watchdog. The first valid Firebase user wins long before this.
  // NOTE: this budget never routes to Login while the Google lane is still
  // unsettled — a native signInWithCredential cannot be cancelled, so a late
  // success would otherwise flip Login→Home. See [_raceRestore].
  static const Duration _restoreBudget = Duration(seconds: 7);

  // Bound on the PRE-credential Google steps (signInSilently / token fetch)
  // only. Kept short (well under [_restoreBudget]) so that, by the time the
  // budget could fire, the Google lane is either already failed or has entered
  // the (genuinely awaited, non-timeout-bounded) credential exchange.
  static const Duration _googleAcquireTimeout = Duration(seconds: 3);

  // Shared silent Google restoration handle. The FIRST null-auth event creates
  // the attempt; any later null event while it runs awaits and shares THE EXACT
  // SAME future, so a concurrent attempt never returns null (a false
  // "restoration failed"). See SharedRestoreAttempt.
  final SharedRestoreAttempt<User> _silentRestore = SharedRestoreAttempt<User>();

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
    // Lifecycle observer is DIAGNOSTIC ONLY (logs the current Firebase UID at
    // paused/inactive/detached/resumed) — it performs no auth work.
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    _authSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Diagnostic only — no auth side-effects. Captures the current Firebase UID
    // at each lifecycle transition to prove the session is intact across
    // background/foreground and at process detach.
    AuthDiag.lifecycle(state.name);
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
    // steps and silent Google restore all route through here).
    //
    // The flag is read BEFORE it is cleared or the UI is authenticated. A stale
    // / unexpected Firebase user that arrives AFTER an explicit logout — e.g. an
    // older silent credential exchange whose authStateChanges(user) lands here
    // before that exchange's own post-abandonment check runs — must NOT
    // authenticate and must NOT clear the flag. The unexpected user is signed
    // back out so the Firebase session matches the logged-out UI; a legitimate
    // interactive login has already cleared the flag (login_screen /
    // create_new_account_screen) BEFORE sign-in, so it passes the gate.
    final allowed = await passesExplicitLogoutGate(
      isExplicitLogout: () async => prefs.getBool(_kExplicitLogout) ?? false,
      signOutUnexpected: _signOutUnexpectedUser,
    );
    if (gen != _authGen || !mounted) return;
    if (!allowed) {
      unawaited(writeAuthBreadcrumb(
          'handleValidUser explicitLogout=true → signOut+unauthenticated gen=$gen'));
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
      StartupTrace.userContextCreated();

      // Server-authoritative Coach Mode state. Fire-and-forget: never blocks
      // render, and the mirrored claim above already handles fast routing.
      _hydrateCoachEntitlement(_userContext!, user.uid);

      // Await ONLY local SharedPreferences hydration of cached block meta so
      // Home can read activeBlockId on its first build. Without this, Home sees
      // a transiently-null activeBlockId and wrongly enters first-time setup
      // (a 30×500ms poll + 1.5s delay ≈ the ~10s slow Home cold start). This
      // touches no Firestore / App Check — just a couple of cached prefs reads.
      await _userContext!.hydrateBlockMetaFromPrefs(user.uid);
      if (gen != _authGen || !mounted) return;

      // Server refresh + warmup remain fire-and-forget (never block render).
      _userContext!.refreshBlockMetaInBackground(user.uid);

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

  /// Loads accountEntitlements/{uid} in the background and keeps the context's
  /// Coach Mode state live. The entitlement — not the mirrored `isCoach`
  /// claim — is what actually authorises coach access, so a suspension or
  /// revocation takes effect here as soon as the server commits it.
  void _hydrateCoachEntitlement(UserContext ctx, String uid) {
    unawaited(() async {
      try {
        final service = CoachModeService();
        ctx.coachEntitlement = await service.fetchEntitlement(uid);
        await for (final ent in service.watchMyEntitlement(uid)) {
          if (!mounted || ctx.actorUid != uid) break;
          ctx.coachEntitlement = ent;
        }
      } catch (e) {
        debugPrint('[AUTHROOT] coach entitlement hydration failed: $e');
      }
    }());
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
    final current = FirebaseAuth.instance.currentUser;
    debugPrint('[AUTHRESTORE] step1 currentUser=${current?.uid}');
    if (current != null && !current.isAnonymous) {
      await _handleValidUser(current, gen);
      return;
    }

    // ── Concurrent, race-safe restoration ──────────────────────────────────
    // The old path waited 1.5 s, then up to 3 s on idTokenChanges, and only
    // THEN began silent Google restore (≈4.5 s of serial delay before Google
    // even started). Instead, start both lanes immediately and concurrently:
    //   • native lane  — Firebase surfacing the cached user (idTokenChanges /
    //     currentUser) after the spurious cold-start null;
    //   • Google lane  — the existing silent Google restoration (only when the
    //     last login provider was Google and there was no explicit logout).
    // The FIRST valid non-anonymous Firebase user wins and routes through the
    // existing _handleValidUser() path. _authGen guards drop stale completions.
    final lastProvider = prefs.getString(_kLastLoginProvider);
    final googleEligible = lastProvider == 'google';
    debugPrint(
        '[AUTHRESTORE] starting concurrent restore lastProvider=$lastProvider '
        'googleEligible=$googleEligible gen=$gen');

    StartupTrace.nativeRestoreStarted();
    final nativeFuture = _awaitNativeRestore(gen);

    Future<User?>? googleFuture;
    if (googleEligible) {
      StartupTrace.silentGoogleStarted();
      // signInWithCredential fires authStateChanges() as a side-effect on
      // success, advancing _authGen before this future resolves. That is the
      // expected path — gen state is reconciled by the caller below.
      googleFuture = _trySilentGoogleRestore(gen);
    }

    final restored = await _raceRestore(
      native: nativeFuture,
      google: googleFuture,
      budget: _restoreBudget,
    );

    // A newer auth event may already own routing (e.g. the Google credential
    // exchange's authStateChanges side-effect advanced _authGen and routed
    // through _onAuthEvent). Never override it, and never fall to Login.
    if (gen != _authGen || !mounted) {
      await writeAuthBreadcrumb(
          'restoreRace newerGenOwnsRouting gen=$gen currentGen=$_authGen');
      debugPrint(
          '[AUTHRESTORE] restore race — gen=$_authGen owns routing, not falling to Login');
      return;
    }

    if (restored != null && !restored.isAnonymous) {
      await writeAuthBreadcrumb('restoreRace restored uid=${restored.uid} gen=$gen');
      await _handleValidUser(restored, gen);
      return;
    }

    // Genuine failure within the overall budget → show Login exactly once.
    StartupTrace.restoreFailedOrTimedOut();
    debugPrint('[AUTHNULL] restore race confirmed no user — showing Login');
    await writeAuthBreadcrumb('restoreRaceFailed showLogin gen=$gen');
    _clearMemo();
    setState(() => _phase = _AuthPhase.unauthenticated);
  }

  /// Native restoration lane: completes with the first valid non-anonymous
  /// Firebase user surfaced via idTokenChanges (or a currentUser that
  /// materialised synchronously), or null after [_nativeRestoreGrace].
  ///
  /// Uses an explicit, cancelled subscription + timer so no idTokenChanges
  /// listener leaks past the grace window. Routing is performed by the caller
  /// (via the race) under the _authGen guard, never here.
  Future<User?> _awaitNativeRestore(int gen) {
    final completer = Completer<User?>();
    StreamSubscription<User?>? sub;
    Timer? timer;

    void finish(User? user) {
      if (completer.isCompleted) return;
      timer?.cancel();
      unawaited(sub?.cancel());
      completer.complete(user);
    }

    sub = FirebaseAuth.instance.idTokenChanges().listen(
      (user) {
        if (user != null && !user.isAnonymous) {
          debugPrint('[AUTHRESTORE] native lane idTokenChanges uid=${user.uid}');
          finish(user);
        }
      },
      onError: (_) {}, // errors fall through to the grace timeout
    );

    // A user may have materialised between the null event and this listener
    // attaching — catch it synchronously.
    final now = FirebaseAuth.instance.currentUser;
    if (now != null && !now.isAnonymous) {
      finish(now);
    } else {
      timer = Timer(_nativeRestoreGrace, () {
        debugPrint('[AUTHRESTORE] native lane grace expired gen=$gen');
        finish(null);
      });
    }

    return completer.future;
  }

  /// Races the native and (optional) Google restoration lanes. Completes with
  /// the FIRST lane to yield a valid non-anonymous user; with null only once
  /// every started lane has reported failure, or when [budget] elapses
  /// (whichever comes first). Emits the won/failed StartupTrace marks.
  Future<User?> _raceRestore({
    required Future<User?> native,
    Future<User?>? google,
    required Duration budget,
  }) {
    // Delegates to the pure, unit-tested race in silent_restore_coordinator.
    // Lanes pre-filter anonymous users (native lane only completes non-anon;
    // a Google credential is never anonymous), so a non-null value here is a
    // valid restored user.
    return raceRestore<User>(
      native: native,
      google: google,
      budget: budget,
      onNativeWon: StartupTrace.nativeRestoreWon,
      onGoogleWon: StartupTrace.silentGoogleWon,
    );
  }

  /// Signs out an unexpected / stale Firebase user that arrived after an
  /// explicit logout, so the Firebase session matches the logged-out UI. The
  /// explicit-logout flag is left untouched (preserved by the caller). The
  /// resulting authStateChanges(null) re-confirms the unauthenticated phase via
  /// _handleNullOrAnon (which reads the preserved flag). Best-effort.
  Future<void> _signOutUnexpectedUser() async {
    await performSignOut(
      reason: SignOutReason.staleUserAfterExplicitLogout,
      caller: 'AppRoot._handleValidUser',
    );
  }

  void _clearMemo() {
    _memoUid = null;
    _tokenFuture = null;
    _userContext = null;
    // Invalidate the shared silent-restore handle so a NEW null event starts a
    // fresh attempt rather than sharing the one being torn down. Any in-flight
    // attempt self-abandons via its explicit-logout re-checks (it signs out a
    // late credential completion that lands after an explicit logout).
    _silentRestore.invalidate();
  }

  // ─── silent Google restore ────────────────────────────────────────────────
  // Returns the signed-in Firebase User on success, null otherwise.
  //
  // Key invariant: after signInWithCredential resolves successfully we do NOT
  // gate on gen != _authGen. signInWithCredential fires authStateChanges() as a
  // side-effect, incrementing _authGen before this continuation resumes. That is
  // expected, not a failure — the credential exchange succeeded. The caller
  // (step 5 in _handleNullOrAnon) is responsible for routing based on gen state.

  Future<User?> _trySilentGoogleRestore(int gen) {
    // SHARED in-flight handle: a burst of cold-start null events must not launch
    // parallel signInSilently chains, and — critically — a later caller must
    // NOT receive a synchronous null that the race would read as "Google failed".
    // Every concurrent caller awaits and shares THE EXACT SAME future.
    return _silentRestore.run(() => _runSilentGoogleRestore(gen));
  }

  /// Reads the explicit-logout flag fresh from SharedPreferences.
  Future<bool> _isExplicitLogout() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kExplicitLogout) ?? false;
  }

  /// The actual silent Google restoration, expressed via the unit-tested
  /// [runAbandonAwareRestore] sequence. Routing/gen reconciliation is the
  /// caller's responsibility (via the race + `_authGen`); this does NOT gate its
  /// own steps on `_authGen` (sibling null events legitimately advance the
  /// generation while this shared attempt runs).
  Future<User?> _runSilentGoogleRestore(int gen) async {
    final user = await runAbandonAwareRestore<User, AuthCredential>(
      isExplicitLogout: _isExplicitLogout,
      // Bounded pre-credential acquisition. Returns null (graceful failure) on
      // wrong provider / no cached account / timeout / any error.
      acquire: () async {
        try {
          final prefs = await SharedPreferences.getInstance();
          if (prefs.getString(_kLastLoginProvider) != 'google') {
            await writeAuthBreadcrumb('silentGoogleRestore skipped notGoogle gen=$gen');
            return null;
          }
          await writeAuthBreadcrumb('silentGoogleRestore start gen=$gen');
          final googleUser = await GoogleSignIn()
              .signInSilently()
              .timeout(_googleAcquireTimeout);
          if (googleUser == null) {
            await writeAuthBreadcrumb('silentGoogleRestore noAccount gen=$gen');
            return null;
          }
          final googleAuth =
              await googleUser.authentication.timeout(_googleAcquireTimeout);
          return GoogleAuthProvider.credential(
            accessToken: googleAuth.accessToken,
            idToken: googleAuth.idToken,
          );
        } on TimeoutException {
          await writeAuthBreadcrumb('silentGoogleRestore acquireTimeout gen=$gen');
          return null;
        } catch (e) {
          await writeAuthBreadcrumb('silentGoogleRestore acquireError gen=$gen');
          debugPrint('[AUTHRESTORE] silentGoogleRestore acquire error: $e');
          return null;
        }
      },
      // GENUINE credential exchange — NOT timeout-bounded (a Dart .timeout()
      // cannot cancel the native sign-in; abandoning a late success flips
      // Login→Home). signInWithCredential fires authStateChanges as a side
      // effect — that is the expected path, reconciled by the caller's gen.
      exchange: (credential) async {
        try {
          await writeAuthBreadcrumb(
              'silentGoogleRestore firebaseCredential start gen=$gen');
          final cred =
              await FirebaseAuth.instance.signInWithCredential(credential);
          return cred.user;
        } on FirebaseAuthException catch (e) {
          await writeAuthBreadcrumb(
              'silentGoogleRestore FirebaseAuthException ${e.code} gen=$gen');
          return null;
        } catch (e) {
          await writeAuthBreadcrumb('silentGoogleRestore exchangeError gen=$gen');
          debugPrint('[AUTHRESTORE] silentGoogleRestore exchange error: $e');
          return null;
        }
      },
      // Abandonment: a stale success that lands after an explicit logout is
      // signed back out so the user is never silently signed back in.
      signOutLateCompletion: () async {
        await performSignOut(
          reason: SignOutReason.lateSilentRestoreAbandon,
          caller: 'AppRoot._runSilentGoogleRestore',
        );
      },
    );

    if (user != null) {
      // Legitimate restore confirmed (not abandoned) → clear the logout flag.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kExplicitLogout, false);
      await writeAuthBreadcrumb('silentGoogleRestore success gen=$gen');
      debugPrint('[AUTHRESTORE] silentGoogleRestore success uid=${user.uid}');
    }
    return user;
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
  // Auth-persistence diagnostic: log project/app id + currentUser + last
  // provider + explicit-logout immediately after init on this (possibly new)
  // process. Fire-and-forget — proves whether the native session survived.
  unawaited(AuthDiag.afterFirebaseInit());

  // App Check: invoke activation SYNCHRONOUSLY (registers the provider before
  // any widget builds / any Firestore request can start) but do NOT await it —
  // the first visible Flutter frame must not wait on Play Integrity /
  // DeviceCheck attestation. Protected startup operations await `appCheckReady`
  // individually at their Firestore boundaries. See app_check_ready.dart.
  // initAppCheck emits its own trace marks: `appcheck_disabled` when skipped,
  // or `appcheck_activate_invoked` + `appcheck_ready_settled` when attempted.
  initAppCheck();

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
