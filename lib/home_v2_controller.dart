import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';

import 'home_bootstrap_service.dart';
import 'home_v2_calendar_service.dart';
import 'onboarding/onboarding_cue.dart';
import 'onboarding/onboarding_cue_service.dart';
import 'user_context.dart';
import 'warmup_service.dart';

/// Startup orchestrator and state holder for HomeScreen2.
///
/// Owns all non-UI startup / background-maintenance responsibilities that were
/// previously inlined in the widget.  HomeScreen2 reads from the exposed fields
/// and calls the public coordination methods; it never touches Firestore or
/// service classes directly.
///
/// Lifecycle:
///   1. Widget creates instance in initState.
///   2. Widget calls [onInitialStartup] once from didChangeDependencies.
///   3. Widget calls [onReturnedToHome] from didPopNext.
///   4. Widget calls [onActingUserChanged] when UserContext.actingAsUid changes.
///   5. Widget calls [updateFocusedMonth] when the calendar page changes.
///   6. Widget disposes this controller in its own dispose().
class HomeV2Controller extends ChangeNotifier {
  // ── Exposed state (read-only from widget) ──────────────────────────────────

  bool isFirstTimeSetup = false;
  String setupStatusMessage = '';
  bool blockSetupComplete = false;

  /// Best-available display name for the acting user (AppBar banner).
  /// Null until first Firestore load; widget shows '...' while null.
  String? actingDisplayName;

  /// Calendar day states keyed by normalised date; empty until first load.
  Map<DateTime, HomeV2CalendarDayKind> calendarDays = {};

  /// Onboarding cue flags — default true so no cue flashes before prefs load.
  bool wpDone = true;
  bool wesDone = true;

  // ── Private ────────────────────────────────────────────────────────────────

  bool _disposed = false;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _blockSub;

  // Session-level gates — reset when a new controller instance is created.
  String? _rirHealedBlockId; // only heal each block once per session
  bool _startupRun = false; // only run ensureBlocksExist once per session
  String _calendarFetchKey = ''; // dedup guard: '$uid/$year-$month'

  // Used by the block-listener onChange callback without a BuildContext.
  String _currentActingUid = '';
  DateTime _currentMonth = DateTime.now();

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Call once from [didChangeDependencies] when UserContext is first available.
  Future<void> onInitialStartup({
    required UserContext uc,
    required DateTime initialMonth,
  }) async {
    final actingUid = uc.actingAsUid;
    _currentActingUid = actingUid;
    _currentMonth = initialMonth;
    debugPrint('🎮 [CTRL] onInitialStartup uid=$actingUid');

    final hasBlockMeta = uc.activeBlockId?.isNotEmpty == true;
    if (hasBlockMeta) {
      // Existing user: render immediately from cached state.
      blockSetupComplete = true;
      _notify();
      _setupBlockListener(actingUid);
      _schedulePostFrameWork(uc: uc, month: initialMonth);
    } else {
      // New user: run first-time setup (shows spinner in widget).
      await _runFirstTimeSetup(
          uc: uc, actingUid: actingUid, month: initialMonth);
    }

    // Display name and onboarding prefs are always non-blocking.
    unawaited(_loadDisplayName(actingUid));
    unawaited(_loadOnboardingPrefs());
  }

  /// Call from [didPopNext] — refreshes cue state and calendar after returning.
  /// Uses force=true to bypass the dedup guard in case a workout was just saved.
  Future<void> onReturnedToHome({
    required String actingUid,
    required DateTime month,
  }) async {
    _currentMonth = month;
    unawaited(_loadOnboardingPrefs());
    unawaited(_refreshCalendar(month, uid: actingUid, force: true));
  }

  /// Call when UserContext.actingAsUid changes (coach switches athlete).
  Future<void> onActingUserChanged({
    required String newUid,
    required UserContext uc,
    required DateTime month,
  }) async {
    debugPrint('🎮 [CTRL] onActingUserChanged → $newUid');
    _currentActingUid = newUid;
    _currentMonth = month;

    _setupBlockListener(newUid);
    unawaited(_loadDisplayName(newUid));
    unawaited(_refreshCalendar(month, uid: newUid));
    unawaited(WarmupService.instance.warmWES(newUid));
    _tryRirHeal(uid: newUid, blockId: uc.activeBlockId);
  }

  /// Call when the calendar page changes so the block-listener refresh uses
  /// the correct month.
  void updateFocusedMonth(DateTime month) {
    _currentMonth = month;
  }

  /// Returns the [HomeV2CalendarDayKind] for a normalised date.
  HomeV2CalendarDayKind dayKindFor(DateTime day) {
    final norm = DateTime(day.year, day.month, day.day);
    return calendarDays[norm] ?? HomeV2CalendarDayKind.none;
  }

  /// Exposed so the widget can request a calendar refresh on page change.
  /// Uses the dedup guard — won't re-fetch the same uid+month until forced.
  Future<void> refreshCalendar(DateTime month, {required String uid}) {
    return _refreshCalendar(month, uid: uid);
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Schedules all post-first-frame background work for an existing user.
  /// Nothing here must happen before first paint.
  void _schedulePostFrameWork({
    required UserContext uc,
    required DateTime month,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      final uid = uc.actingAsUid;

      unawaited(_refreshCalendar(month, uid: uid));
      unawaited(WarmupService.instance.warmWES(uid));
      _tryRirHeal(uid: uid, blockId: uc.activeBlockId);

      if (!_startupRun) {
        _startupRun = true;
        // Template bootstrap — self only, idempotent.
        _tryTemplateBootstrap(uid: uid, actorUid: uc.actorUid);
        // ensureBlocksExist — guards against missing Firestore docs.
        if (uid == uc.actorUid) {
          unawaited(_ensureBlocksAndRefreshMeta(uid: uid, uc: uc));
        }
      }
    });
  }

  /// Heals the RIR plan for [blockId] at most once per session.
  void _tryRirHeal({required String uid, required String? blockId}) {
    if (blockId == null || blockId.isEmpty) return;
    if (_rirHealedBlockId == blockId) return;
    _rirHealedBlockId = blockId;
    unawaited(HomeBootstrapService.healRirPlan(uid: uid, blockId: blockId));
  }

  /// Triggers template bootstrap only for the logged-in user (not coached athletes).
  void _tryTemplateBootstrap({required String uid, required String actorUid}) {
    if (uid.isEmpty || uid != actorUid) return;
    HomeBootstrapService.startTemplateBootstrap(uid);
  }

  Future<void> _ensureBlocksAndRefreshMeta({
    required String uid,
    required UserContext uc,
  }) async {
    await HomeBootstrapService.ensureBlocksExist(uid: uid, uc: uc);
    if (_disposed) return;
    unawaited(uc.refreshBlockMetaFromServer(uid: uid));
  }

  /// First-time setup for a brand-new user. Drives spinner in widget.
  Future<void> _runFirstTimeSetup({
    required UserContext uc,
    required String actingUid,
    required DateTime month,
  }) async {
    if (_disposed) return;
    isFirstTimeSetup = true;
    setupStatusMessage = '';
    _notify();

    final ready = await HomeBootstrapService.runFirstTimeSetup(
      uid: actingUid,
      uc: uc,
      onStatus: (msg) {
        if (!_disposed) {
          setupStatusMessage = msg;
          _notify();
        }
      },
    );

    if (_disposed) return;
    blockSetupComplete = ready;
    isFirstTimeSetup = false;
    setupStatusMessage = '';
    _notify();
    debugPrint('🎮 [CTRL] first-time setup done blockSetupComplete=$ready');

    _setupBlockListener(actingUid);
    unawaited(_refreshCalendar(month, uid: actingUid));
    _tryRirHeal(uid: actingUid, blockId: uc.activeBlockId);
    _tryTemplateBootstrap(uid: actingUid, actorUid: uc.actorUid);
    _startupRun = true;
  }

  /// Sets up (or replaces) the Firestore active-block snapshot listener.
  void _setupBlockListener(String uid) {
    _blockSub?.cancel();
    _blockSub = null;
    if (uid.isEmpty) return;
    _blockSub = HomeBootstrapService.setupActiveBlockListener(
      uid: uid,
      onChange: () {
        unawaited(_refreshCalendar(_currentMonth,
            uid: _currentActingUid, force: true));
      },
    );
  }

  Future<void> _refreshCalendar(
    DateTime month, {
    required String uid,
    bool force = false,
  }) async {
    if (uid.isEmpty) return;
    final key = '$uid/${month.year}-${month.month}';
    if (!force && key == _calendarFetchKey) return;
    // Key is set AFTER a successful fetch so a network failure doesn't
    // permanently suppress retries for this month.
    final states = await HomeV2CalendarService.fetchCalendarDayStatesForMonth(
      uid: uid,
      month: month,
    );
    if (_disposed) return;
    _calendarFetchKey = key;
    calendarDays = states;
    _notify();
  }

  Future<void> _loadDisplayName(String uid) async {
    if (uid.isEmpty) return;
    try {
      final snap =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = snap.data();
      if (_disposed || data == null) return;

      String? pick(dynamic v) {
        final s = (v ?? '').toString().trim();
        return s.isEmpty ? null : s;
      }

      actingDisplayName = pick(data['username']) ??
          pick(data['displayName']) ??
          pick(data['email']);
      _notify();
    } catch (_) {}
  }

  Future<void> _loadOnboardingPrefs() async {
    // Actor UID only — never the impersonated athlete.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final svc = OnboardingCueService.instance;
    await svc.ensureLoaded(uid);
    if (_disposed || !svc.isLoaded(uid)) return; // fail-closed: keep defaults
    // Derived from durable cue state (same mapping as HomeScreen).
    wpDone = svc.isPermanentlyComplete(OnboardingCueId.wpDemoVideo, uid);
    wesDone = !svc.shouldShowCue(OnboardingCueId.wes2FieldWalkthrough, uid);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _blockSub?.cancel();
    super.dispose();
  }
}
