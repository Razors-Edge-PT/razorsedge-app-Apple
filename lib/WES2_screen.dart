import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'onboarding_prefs.dart';
import 'onboarding/onboarding_cue.dart';
import 'onboarding/onboarding_cue_service.dart';
import 'user_context.dart';
import 'WES2_widgets/WES2_app_bar.dart';
import 'WES2_widgets/WES2_tutorial_banner.dart';
import 'WES2_controller.dart';
import 'WES2_models.dart';
import 'profile/profile_services.dart';
import 'wes2_video/set_video_coordinator.dart';
import 'wes2_video/set_video_copy.dart';
import 'WES2_plan_service.dart';
import 'WES2_repository.dart';
import 'WES2_widgets/WES2_day_header.dart';
import 'WES2_widgets/WES2_empty_state.dart';
import 'WES2_widgets/WES2_day_actions_row.dart';
import 'WES2_widgets/WES2_exercise_card.dart';
import 'units/exercise_unit_registry.dart';
import 'units/weight_unit.dart';
import 'WES2_widgets/WES2_exercise_picker.dart';
import 'WES2_local_store.dart';
import 'WES2_template_service.dart';
import 'WES2_widgets/WES2_template_picker.dart';
import 'WES2_widgets/WES2_exercise_settings_dialog.dart';
import 'WES2_widgets/WES2_weight_converter_dialog.dart';
import 'exercise_details_screen.dart';
import 'top_sets_screen.dart';
import 'wes2_top_set_navigation.dart';
import 'exercise_type.dart';
import 'periodization_model_utils.dart';
import 'progression_engine.dart';
import 'progression_history_store.dart';
import 'block_exercise_defaults_repository.dart';
import 'app_check_ready.dart';
import 'startup_route_service.dart';
import 'startup_trace.dart';
import 'wes2_done_coordinator.dart';
import 'wes2_exit_coordinator.dart';
import 'wes2_sync/wes2_mutation.dart';
import 'wes2_sync/wes2_mutation_outbox.dart';
import 'wes2_sync/wes2_pending_overlay.dart';
import 'wes2_sync/wes2_sync_engine.dart';
import 'wes2_sync/wes2_sync_services.dart';
import 'wes2_field_parser.dart';
import 'wes2_hint_input.dart';
import 'wes2_hint_load_runner.dart';
import 'wes2_hint_trace.dart';
import 'aurelian/actions/action_ports.dart';
import 'aurelian/actions/action_service.dart';
import 'aurelian/aurelian_add_list.dart';
import 'aurelian/aurelian_bus.dart';
import 'aurelian/aurelian_catalogue.dart';
import 'aurelian/aurelian_command.dart';
import 'aurelian/aurelian_exercise_match.dart';
import 'aurelian/aurelian_set_entry.dart';
import 'aurelian/wes2_voice_target.dart';
import 'exercise_catalog.dart';
import 'membership_gate.dart' show gatedWes2;
import 'WES2_widgets/wes2_set_timer_hub.dart';

/// WES2 beta route shell.
/// Receives an optional [initialDate]; defaults to today when omitted.
/// Accesses athlete identity via UserContext — never via FirebaseAuth directly.
class Wes2Screen extends StatefulWidget {
  final DateTime? initialDate;

  /// Test seams. Production passes nothing and gets the real services, exactly
  /// as before; the integration test supplies fakes so the actual screen can
  /// be driven without Firebase, Isar or Drift.
  @visibleForTesting
  final Wes2Repository? repositoryOverride;
  @visibleForTesting
  final Wes2PlanService? planServiceOverride;
  @visibleForTesting
  final Wes2LocalStore? localStoreOverride;

  const Wes2Screen({
    super.key,
    this.initialDate,
    this.repositoryOverride,
    this.planServiceOverride,
    this.localStoreOverride,
  });

  @override
  State<Wes2Screen> createState() => _Wes2ScreenState();
}

class _Wes2ScreenState extends State<Wes2Screen> with WidgetsBindingObserver {
  late final Wes2SessionController _controller;

  /// Display indices with attached set footage, per exerciseId. Resolved from
  /// the durable store by stable setId, refreshed whenever the day changes or
  /// the video flow reports a change.
  Map<String, Set<int>> _setsWithVideo = const <String, Set<int>>{};
  late final Wes2Repository _repository =
      widget.repositoryOverride ?? FirestoreWes2Repository();
  late final Wes2PlanService _planService =
      widget.planServiceOverride ?? FirestoreWes2PlanService();
  late final Wes2LocalStore _localStore =
      widget.localStoreOverride ?? IsarWes2LocalStore();
  final Wes2TemplateService _templateService = FirestoreWes2TemplateService();
  bool _loadStarted = false;
  // One-shot guard so the WES2-first-build timing trace fires only once.
  bool _tracedFirstBuild = false;
  // Guards against overlapping retry attempts from the polished load-error state.
  bool _retryInProgress = false;
  // Coordinates the deliberate-exit paths (_exitToPreviousRoute and
  // _exitDirectlyToHome). Holds the re-entrancy guard so repeated back/logo
  // taps cannot double-pop or create duplicate Home routes.
  final Wes2ExitCoordinator _exitCoordinator = Wes2ExitCoordinator();

  /// Owns the "let the focused field finish its ordinary save first" ordering
  /// for the Done checkmark, plus the repeat-tap guard. See
  /// [Wes2DoneCoordinator] for why Done has to wait on the field path.
  final Wes2DoneCoordinator _doneCoordinator = Wes2DoneCoordinator();

  /// Prevents repeated Top Sets taps from starting overlapping date loads.
  bool _openingTopSetWorkout = false;
  final Map<String, GlobalKey> _exerciseCardKeys = <String, GlobalKey>{};
  int? _confirmedServerLoadEpoch;

  /// Local-durability barrier for the deliberate-exit paths AND for Done.
  ///
  /// Every mutation's DURABLE LOCAL write is tracked here so Back/Home and the
  /// "Completed?" checkmark can wait for SQLite (milliseconds) without ever
  /// waiting for the network. This is what makes "type the last RIR, tap Back
  /// immediately" — and "type the last RIR, tap Completed? immediately" — safe:
  /// the field widgets are torn down only after the intent is on disk.
  final Wes2DurableWriteBarrier _durableWrites = Wes2DurableWriteBarrier();

  /// Monotonic per-session counter for mutations whose repetition is
  /// meaningful (remove set, delete all, template replace) and which therefore
  /// must never coalesce with an earlier one.
  int _localMutationSeq = 0;

  /// Live queue depth, for the unobtrusive status line in the day header.
  Wes2SyncStatus _syncStatus = const Wes2SyncStatus(pending: 0, blocked: 0);
  StreamSubscription<Wes2SyncStatus>? _syncStatusSub;
  StreamSubscription<Wes2MutationRow>? _syncConfirmedSub;

  String? _athleteUsername;
  String? _athleteGreeting;
  String? _fetchedForUid;
  /// Owns the hint pass: the settings/type caches, the identity guards and
  /// the single application to the controller.
  late final Wes2HintLoadRunner _hintRunner;

  Map<String, dynamic> get _cachedExerciseSettings => _hintRunner.settings;

  /// Authoritative BB3 prescriptions for the loaded day, by exerciseId.
  /// Held apart from the rows: a row's hintValue is calculation output, and
  /// treating it as prescription authority is what let a generated - or
  /// draft-recovered - number behave like a BB3 lock.
  Map<String, Wes2Prescriptions> _prescriptions =
      const <String, Wes2Prescriptions>{};


  static const Set<String> _defaultVelocityExerciseIds = {
    'heeBViVINHO6tUScSd6y', // Back Squat, Barbell
    'AJIQi4kzUVb7IfOyxfZs', // Back Squat, Pin Squat
    'm6zHYgovIiYPM7NgqoeR', // Bench Press, Banded
    'AmfUWbF1DH3I7qPAdh5k', // Bench Press, Barbell
    'pU7wce56hFDsam53aKDr', // Bench Press, Larsen Press
    'wtrVB88vFR0EDRc7Uli0', // Bench Press, Long Pause
    'IECRZ5GJrc78DRnyuhtQ', // Bench Press, Narrow Grip
    'ZH6VIWHexxxlpKRYgwil', // Bench Press, Pin Press
    'WH2qpYjDeb6M0j2FtlGs', // Bench Press, Touch n Go
    'MsGl7e9yanDeEnYX0e4X', // Deadlift, Conventional
    'EQL6s4QJnXApe8DdmJbX', // Deadlift, Deficit
    'YvwK9kwc1hcA2omz1g4r', // Larsen Bench Press
    'lVDG90yN6Z8aPjRNV2wc', // Overhead Barbell Press
    '10pEctikt6PP8eAg9Eip', // Sumo Deadlift
    'NkctO0XmQrUHfLCkpRXr', // Sumo Deadlift, Deficit
  };
  // IDs present in the BB3 planned day at last load. Keyed by exerciseId.
  // Allows post-merge rows (source=completedServer) to still trigger BB3 sync.
  Set<String> _bb3PlannedExerciseIds = const {};
  // Composite key uid|blockId|date — prevents redundant server history refreshes.
  /// True while a background history refresh triggered by this screen is
  /// still pending, so the follow-up hint pass is scheduled only once.
  bool _awaitingHistoryRefresh = false;


  // ── Tutorial state (Phase 2 onboarding) ──────────────────────────────────
  // 0=inactive 1=loadTemplateCue 2=firstTemplateCue 3=weight 4=reps 5=rir
  // Uses FirebaseAuth actor UID, NOT the impersonated athlete.
  int _tutorialStep = 0;

  // ── Settings cog tutorial cue ────────────────────────────────────────────
  // Durable completion via OnboardingCueService (cue wes2_settings_cog_v1),
  // keyed on the actor UID. Marked complete when the settings panel is opened.
  bool _cogCueDismissed = false;
  // True once the actor has logged qualifying sets on 3 distinct calendar days.
  bool _cogCueUnlocked = false;

  // Prevents overlapping template-replacement operations (confirmation + load).
  bool _isLoadingTemplate = false;

  // ── Day timer state (Phase 17) ─────────────────────────────────────────────
  bool _timerVisible = false;
  bool _timerRunning = false;
  int _elapsedMilliseconds = 0;
  DateTime? _timerStartedAt;
  Timer? _timerTicker;

  // ── Automatic workout duration (separate from manual floating timer) ────────
  int _workoutDurationMilliseconds = 0;
  DateTime? _workoutDurationSegmentStartedAt;

  // ── Paywall qualifying-date tracking ─────────────────────────────────────────
  // Loaded once per session from the membership doc; updated locally on each new
  // qualifying date so we never double-count or re-read Firestore every save.
  final Set<String> _qualifiedDatesCached = {};
  int _qualifiedDaysCountCached = 0;
  bool _qualifiedDatesLoaded = false;
  bool _qualifiedDatesLoading = false;

  // ── Aurelian voice bridge (session-local; never saved) ───────────────────
  Object? _aurelianHandle;

  /// The exercise voice commands act on ("set one weight 50").
  final Wes2VoiceTarget _voiceTarget = Wes2VoiceTarget();

  /// Outline the voice target once voice has been used in this visit.
  bool _voiceTargetShown = false;

  /// The Add Exercise picker was opened by voice: its pick becomes the target.
  bool _voicePickerOpen = false;

  /// This screen as the Aurelian 2.0 action service's workout (see
  /// [_Wes2ActionPort]); registered while mounted.
  late final _Wes2ActionPort _actionPort = _Wes2ActionPort(this);
  Object? _actionPortHandle;

  // ── Tutorial helpers ──────────────────────────────────────────────────────

  Future<void> _loadTutorialState() async {
    // Uses Firebase Auth UID (logged-in actor), never the impersonated athlete.
    final uid = _authUidOrNull();
    if (uid == null) return;
    final svc = OnboardingCueService.instance;
    await svc.ensureLoaded(uid);
    if (!mounted) return;
    // WP video prerequisite (permanent) must be met before the WES chain.
    if (!svc.isPermanentlyComplete(OnboardingCueId.wpDemoVideo, uid)) return;
    if (svc.shouldShowCue(OnboardingCueId.wes2FieldWalkthrough, uid)) {
      setState(() => _tutorialStep = 1);
    }
  }

  Future<void> _loadCogCueState() async {
    // Uses FirebaseAuth actor UID — never the impersonated athlete UID.
    final uid = _authUidOrNull();
    if (uid == null) return;
    final svc = OnboardingCueService.instance;
    await svc.ensureLoaded(uid);
    if (!mounted) return;
    // Already completed (build-aware for the cue-QA account) → never show.
    if (!svc.shouldShowCue(OnboardingCueId.wes2SettingsCog, uid)) {
      setState(() => _cogCueDismissed = true);
      return;
    }
    // 3-day unlock from the DURABLE membership qualification data so it survives
    // reinstall / device change (local prefs are only a cache).
    await _ensureQualifiedDatesLoaded();
    if (_qualifiedDaysCountCached >= 3 && mounted) {
      setState(() => _cogCueUnlocked = true);
    }
  }

  Future<void> _onTutorialStepDismiss() async {
    if (_tutorialStep < 5) {
      setState(() => _tutorialStep++);
    } else {
      final uid = _authUidOrNull();
      if (uid != null) {
        await OnboardingCueService.instance
            .markCueComplete(OnboardingCueId.wes2FieldWalkthrough, uid);
      }
      if (mounted) setState(() => _tutorialStep = 0);
    }
  }

  void _onTutorialStepBack() {
    if (_tutorialStep > 3 && mounted) setState(() => _tutorialStep--);
  }

  void _onRepsTutorialAccepted() {
    if (_tutorialStep == 4 && mounted) setState(() => _tutorialStep = 5);
  }

  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _fetchAthleteUsername(String uid) async {
    try {
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = doc.data() ?? {};

      // Prefer username, fall back to displayName then fullName
      String? name;
      for (final key in ['username', 'displayName', 'fullName']) {
        final v = (data[key] as String?)?.trim();
        if (v != null && v.isNotEmpty) {
          name = v;
          break;
        }
      }

      // Greeting from profile.gender (not sex)
      String greeting = 'Welcome';
      final profile = data['profile'];
      if (profile is Map<String, dynamic>) {
        final gender =
            (profile['gender'] as String?)?.toLowerCase().trim() ?? '';
        if (gender == 'female' || gender == 'woman' || gender == 'girl') {
          greeting = 'Welcome queen';
        } else if (gender == 'male' || gender == 'man' || gender == 'boy') {
          greeting = 'Welcome king';
        }
      }

      if (mounted) {
        setState(() {
          _athleteUsername = (name != null && name.isNotEmpty) ? name : null;
          _athleteGreeting = greeting;
          _fetchedForUid = uid;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _fetchedForUid = uid);
    }
  }

  @override
  void initState() {
    super.initState();
    // Each exercise's kg/lb display unit (block setting → published choice);
    // a unit saved from the cog or elsewhere re-renders the rows at once.
    ExerciseUnitRegistry.shared.addListener(_onUnitsChanged);
    WidgetsBinding.instance.addObserver(this);
    final raw = widget.initialDate ?? DateTime.now();
    _controller = Wes2SessionController(raw);
    // Opening the logger is a retry trigger in its own right: whatever failed
    // to sync on the last visit gets another attempt before the athlete has
    // done anything.
    _hintRunner = Wes2HintLoadRunner(
      controller: _controller,
      planService: _planService,
      // In memory only: opening WES2 never writes the block. Defaults are
      // stored when the athlete saves that exercise (or adds it explicitly).
      projectDefaults: (String exerciseId, Map<String, dynamic>? existing) =>
          BlockExerciseDefaultsRepository.projectExerciseDefaults(
        uid: _controller.actingUid,
        exerciseId: exerciseId,
        existing: existing,
      ),
      isSettingsUsable: BlockExerciseDefaultsRepository.isSettingsUsable,
      refreshHistory: () => _refreshHistoryForHints(_controller.selectedDate),
    );
    unawaited(_attachSyncEngine());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _aurelianHandle = AurelianCommandBus.instance
          .register(AurelianScopeKind.wes2, _onAurelianCommand);
      _actionPortHandle =
          AurelianActionService.instance.registerWorkout(_actionPort);
    });
  }

  /// Opens the durable outbox (idempotent) and subscribes to it.
  Future<void> _attachSyncEngine() async {
    try {
      final Wes2SyncServices services =
          await Wes2SyncServices.ensureInitialised();
      if (!mounted) return;
      _syncStatusSub = services.engine.status.listen((Wes2SyncStatus st) {
        if (!mounted) return;
        if (st == _syncStatus) return;
        setState(() => _syncStatus = st);
      });
      _syncConfirmedSub =
          services.engine.confirmed.listen(_onMutationConfirmed);
      final Wes2SyncStatus initial = await services.engine.currentStatus();
      if (mounted && initial != _syncStatus) {
        setState(() => _syncStatus = initial);
      }
      await services.engine.processNow();
    } catch (e) {
      debugPrint('[WES2SYNC] could not attach engine: $e');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // listen: false — identity is read once; UserContext.currentUid is the
    // acting athlete UID, never FirebaseAuth.currentUser.uid directly.
    final uc = UserContext.of(context, listen: false);
    _controller.initIdentity(
      actorUid: uc.actorUid,
      actingUid: uc.currentUid,
      isCoach: uc.isCoach,
      activeBlockId: uc.activeBlockId,
      blockStartDate: uc.blockStartDate,
      blockEndDate: uc.blockEndDate,
    );
    if (!_loadStarted) {
      _loadStarted = true;
      // Mark WES2 as the last active major route (UserContext is available
      // here, so we use the actor UID — never assume FirebaseAuth in initState).
      // Fire-and-forget; cleared only on deliberate exit (PopScope), never from
      // dispose(), so process death cannot wipe the WES2 marker.
      unawaited(StartupRouteService.markWes2Active(uc.actorUid));
      _loadDay();
      unawaited(_loadTutorialState());
      unawaited(_loadCogCueState());
    }
  }

  void _onUnitsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AurelianCommandBus.instance.unregister(_aurelianHandle);
    AurelianActionService.instance.unregisterWorkout(_actionPortHandle);
    ExerciseUnitRegistry.shared.removeListener(_onUnitsChanged);
    _timerTicker?.cancel();
    _hintRunner.dispose();
    _pauseWorkoutDurationSegment();
    _saveDraftNow();
    unawaited(_syncStatusSub?.cancel());
    unawaited(_syncConfirmedSub?.cancel());
    _syncStatusSub = null;
    _syncConfirmedSub = null;
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pauseWorkoutDurationSegment();
      _saveDraftNow();
    } else if (state == AppLifecycleState.resumed) {
      // Coming back is the most likely moment for connectivity to have
      // returned, so anything queued is retried immediately rather than
      // waiting out a backoff set while the phone was in a pocket.
      unawaited(Wes2SyncServices.processNow());
      // Workouts may have been logged on another device while we were away.
      // Mark the history snapshot stale so the next hint pass refreshes it in
      // the background; the current (valid) hints stay on screen meanwhile.
      ProgressionHistoryStore.instance.markStale(_controller.actingUid);
      // Resync timer elapsed from the anchored start time after backgrounding.
      if (_timerRunning && _timerStartedAt != null) {
        _syncTimerElapsed();
        if (_elapsedMilliseconds >= 3600000) {
          _stopTimer();
        } else if (mounted) {
          setState(() {});
        }
      }
    }
  }

  /// Fire-and-forget draft save. Returns void so it can be called from
  /// dispose/didChangeAppLifecycleState without an unawaited-future lint.
  void _saveDraftNow() {
    if (_controller.actingUid.isEmpty) return;
    // ignore: discarded_futures
    _localStore.saveDraft(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      rows: _controller.rows.toList(),
      workoutDurationMs: _currentWorkoutDurationMs(),
    );
  }

  Future<void> _saveDraft() async {
    if (_controller.actingUid.isEmpty) return;
    await _localStore.saveDraft(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      rows: _controller.rows.toList(),
      workoutDurationMs: _currentWorkoutDurationMs(),
    );
  }

  // ── Timer (Phase 17) ──────────────────────────────────────────────────────

  void _toggleTimerVisible() => setState(() => _timerVisible = !_timerVisible);

  /// Shows the floating timer (voice "start a timer" opens it like the menu).
  void _showTimer() {
    if (!_timerVisible) setState(() => _timerVisible = true);
  }

  void _setLoadingTemplate(bool loading) =>
      setState(() => _isLoadingTemplate = loading);

  void _startTimer() {
    if (_timerRunning) return;
    _timerTicker?.cancel();
    setState(() {
      _timerRunning = true;
      // Anchor virtual start so that elapsed is preserved across stop/start.
      _timerStartedAt =
          DateTime.now().subtract(Duration(milliseconds: _elapsedMilliseconds));
    });
    _timerTicker =
        Timer.periodic(const Duration(milliseconds: 100), (_) => _tickTimer());
  }

  void _stopTimer() {
    _timerTicker?.cancel();
    _timerTicker = null;
    setState(() {
      // Freeze elapsed from start time before clearing the anchor.
      _syncTimerElapsed();
      _timerRunning = false;
      _timerStartedAt = null;
    });
  }

  void _resetTimer() {
    _timerTicker?.cancel();
    _timerTicker = null;
    setState(() {
      _timerRunning = false;
      _elapsedMilliseconds = 0;
      _timerStartedAt = null;
    });
  }

  // Close stops the timer so there is no runaway timer while hidden.
  void _closeTimer() {
    _stopTimer();
    setState(() => _timerVisible = false);
  }

  void _tickTimer() {
    if (!mounted) return;
    _syncTimerElapsed();
    if (_elapsedMilliseconds >= 3600000) {
      _stopTimer();
    } else {
      setState(() {});
    }
  }

  void _syncTimerElapsed() {
    if (_timerStartedAt == null) return;
    final elapsed = DateTime.now().difference(_timerStartedAt!).inMilliseconds;
    _elapsedMilliseconds = elapsed.clamp(0, 3600000);
  }

  String _formatDuration(int milliseconds, {bool includeSplitSeconds = false}) {
    final totalSeconds = milliseconds ~/ 1000;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    final cs = (milliseconds % 1000) ~/ 10;

    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    final cc = cs.toString().padLeft(2, '0');

    if (includeSplitSeconds) {
      return h > 0 ? '$h:$mm:$ss.$cc' : '$mm:$ss.$cc';
    }

    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  // ── Workout duration helpers ──────────────────────────────────────────────

  void _startWorkoutDurationSegment() {
    if (_workoutDurationSegmentStartedAt != null) return;
    _workoutDurationSegmentStartedAt = DateTime.now();
  }

  void _pauseWorkoutDurationSegment() {
    final start = _workoutDurationSegmentStartedAt;
    if (start == null) return;
    _workoutDurationMilliseconds +=
        DateTime.now().difference(start).inMilliseconds;
    _workoutDurationSegmentStartedAt = null;
  }

  int _currentWorkoutDurationMs() {
    final start = _workoutDurationSegmentStartedAt;
    if (start == null) return _workoutDurationMilliseconds;
    return _workoutDurationMilliseconds +
        DateTime.now().difference(start).inMilliseconds;
  }

  /// Load completed workout + BB3 planned rows for the current date, then merge.
  /// beginLoad() increments the epoch; stale completions are discarded.
  Future<void> _loadDay() async {
    final epoch = _controller.beginLoad();
    StartupTrace.wes2LoadStart();
    if (Wes2HintTrace.enabled) {
      Wes2HintTrace.log(
          'loadDay',
          'start epoch=$epoch actingUid=${_controller.actingUid} '
          'actorUid=${_controller.actorUid} '
          'date=${_controller.selectedDate.toIso8601String().substring(0, 10)} '
          'blockId=${_controller.activeBlockId} '
          'blockStart=${_controller.blockStartDate?.toIso8601String()}');
    }
    try {
      // Sequence Firestore behind App Check activation (settles even on
      // failure/timeout, so this never deadlocks). WES2 shows its existing
      // loading state while activation settles.
      await appCheckReady;
      if (!mounted) return;
      // Phase 3: completed workout document (exercises[] + wesPlannedExercises[])
      final completedRows = await _repository.loadDay(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
      );

      // Phase 4: BB3 planned day — skip if block context is absent or if
      // selectedDate is before blockStartDate (no negative week/day paths).
      // Kept LOCAL until the load is proven current: a stale day's
      // prescriptions and planned-exercise ids must never reach shared state,
      // even if its rows are rejected a moment later.
      Set<String> plannedIds = const <String>{};
      Map<String, Wes2Prescriptions> prescriptions =
          const <String, Wes2Prescriptions>{};
      var bb3Rows = const <Wes2ExerciseRow>[];
      final blockId = _controller.activeBlockId;
      final blockStart = _controller.blockStartDate;
      if (blockId != null &&
          blockId.isNotEmpty &&
          blockStart != null &&
          !_isBeforeBlockStart(_controller.selectedDate, blockStart)) {
        final wd = _weekDayFromDate(blockStart, _controller.selectedDate);
        bb3Rows = await _planService.loadPlannedDay(
          uid: _controller.actingUid,
          blockId: blockId,
          weekIndex: wd.weekIndex,
          dayIndex: wd.dayIndex,
        );
        plannedIds = bb3Rows.map((r) => r.exerciseId).toSet();
        prescriptions = <String, Wes2Prescriptions>{
          for (final Wes2ExerciseRow r in bb3Rows)
            r.exerciseId: Wes2HintInput.prescriptionsFromRow(r),
        };
      }

      // Phase 7: overlay local draft actuals onto server/BB3 merged structure.
      final draft = await _localStore.loadDraft(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
      );
      if (!mounted) return;
      // Reconciliation, in order of authority:
      //   1. server + plan merge — Firestore is canonical for CONFIRMED data;
      //   2. the local draft may FILL a field the server does not hold, but
      //      never overrides a confirmed value (a stale draft used to win
      //      unconditionally, which is what hid the missing writes);
      //   3. genuinely pending mutations override the server, because they are
      //      newer intent the server has not accepted yet. They are removed
      //      only once confirmed, so this covers exactly the unsynced gap.
      final pending = await _loadPendingChanges();
      if (!mounted) return;
      final mergedRows = _hardened(wes2ApplyPendingOverlay(
        wes2ApplyDraftWithoutOverridingServer(
          _mergeRows(completedRows, bb3Rows),
          draft?.rows,
        ),
        pending,
      ));
      // One guarded publication: a stale completion changes nothing at all.
      if (_controller.loadEpoch != epoch) return;
      _prescriptions = prescriptions;
      _bb3PlannedExerciseIds = plannedIds;
      _controller.publishLoad(
        rows: mergedRows,
        prescriptions: prescriptions,
        epoch: epoch,
      );
      _confirmedServerLoadEpoch = epoch;
      // A successful read proves the server is reachable, so anything still
      // queued is retried now instead of waiting out a backoff set while there
      // was no signal.
      unawaited(Wes2SyncServices.processNow());
      // Local, offline, and off the critical path: reopening a day shows the
      // footage filmed against it without waiting for anything remote.
      unawaited(_refreshSetVideoState());
      StartupTrace.wes2LoadComplete();
      if (Wes2HintTrace.enabled) {
        Wes2HintTrace.log(
            'loadDay',
            'rowsSet epoch=$epoch completedRows=${completedRows.length} '
            'bb3Rows=${bb3Rows.length} merged=${mergedRows.length} '
            'draftRows=${draft?.rows.length ?? 0} '
            'controllerEpochNow=${_controller.loadEpoch}');
        for (final r in mergedRows) {
          Wes2HintTrace.log(
              'loadDay',
              'row src=${r.source.name} setCount=${r.setCount} '
              'name="${r.name}" hasActuals=${Wes2HintTrace.rowHasActuals(r)}',
              exerciseId: r.exerciseId);
        }
        // Rows are DISPLAYED from this point; the hint pass below is async —
        // any user edit between here and 'hints.baselineCaptured' is cause A/F.
        Wes2HintTrace.log('loadDay',
            'scheduling _loadAndApplyHints (rows already displayed) epoch=$epoch');
      }
      _workoutDurationMilliseconds = draft?.workoutDurationMs ?? 0;
      _workoutDurationSegmentStartedAt = null;
      // Phase 21B: apply Set 1 model/default hints after rows settle.
      // ignore: discarded_futures
      _loadAndApplyHints();
      // Persist any exercises queued during loading, deduplicated against
      // freshly loaded server/BB3 data inside setRows/_flushPendingAdds.
      final flushed = _controller.consumeFlushedExercises();
      if (flushed.isNotEmpty) {
        _saveDraftNow();
        for (final row in flushed) {
          // ignore: discarded_futures
          _saveManualExerciseSilently(
            uid: _controller.actingUid,
            date: _controller.selectedDate,
            row: row,
          );
        }
      }
    } catch (e, st) {
      // Technical detail stays in logs/crash reporting only — never shown to the
      // customer. The UI renders a polished error state instead.
      debugPrint('[WES2] _loadDay failed: $e\n$st');
      if (!mounted) return;
      // Offline fallback: the server could not be read, but this device may
      // still hold the athlete's own work. Showing the draft with pending
      // intent applied lets them keep logging instead of facing an error page
      // over a day they already filled in. Nothing is fabricated — only what
      // was genuinely stored locally is used.
      final recovered = await _offlineRowsFromLocalState();
      if (!mounted) return;
      if (recovered != null && recovered.isNotEmpty) {
        if (_controller.loadEpoch != epoch) return;
        // The planned day could not be read, but the recovered rows carry the
        // coach's prescription themselves, stored as bb3 hints. Reading it back
        // from them keeps an offline day on the prescribed numbers; publishing
        // nothing would silently replace them with history-derived hints.
        // Only this day's rows are used, so no other day's plan can leak in.
        final Map<String, Wes2Prescriptions> recoveredPrescriptions =
            <String, Wes2Prescriptions>{};
        for (final Wes2ExerciseRow row in recovered) {
          final Wes2Prescriptions p = Wes2HintInput.prescriptionsFromRow(
            row,
            source: Wes2PrescriptionSource.localStored,
          );
          if (!p.isEmpty) recoveredPrescriptions[row.exerciseId] = p;
        }
        _bb3PlannedExerciseIds = recovered
            .where((Wes2ExerciseRow r) =>
                r.source == Wes2RowSource.bb3Planned &&
                recoveredPrescriptions.containsKey(r.exerciseId))
            .map((Wes2ExerciseRow r) => r.exerciseId)
            .toSet();
        _prescriptions = recoveredPrescriptions;
        _controller.publishLoad(
          rows: recovered,
          prescriptions: recoveredPrescriptions,
          epoch: epoch,
        );
        // ignore: discarded_futures
        _loadAndApplyHints();
        return;
      }
      if (_controller.loadEpoch != epoch) return;
      _controller.setLoadError(e.toString(), epoch);
    }
  }

  /// The pending mutations for the day currently on screen, reduced to what the
  /// overlay needs.
  Future<List<Wes2PendingChange>> _loadPendingChanges() async {
    final String actorUid = _actorUidForMutations;
    if (actorUid.isEmpty) return const <Wes2PendingChange>[];
    try {
      final Wes2SyncServices services =
          await Wes2SyncServices.ensureInitialised();
      final List<Wes2MutationRow> rows = await services.outbox.pendingForDay(
        actorUid: actorUid,
        athleteUid: _controller.actingUid,
        dateKey: wes2DateKey(_controller.selectedDate),
      );
      return rows
          .map((Wes2MutationRow r) => Wes2PendingChange(
                seq: r.seq,
                kind: r.kind,
                exerciseId: r.exerciseId,
                setIndex: r.setIndex,
                payload: Wes2Mutation.decodePayload(r.payloadJson),
              ))
          .toList();
    } catch (e) {
      debugPrint('[WES2SYNC] could not read pending mutations: $e');
      return const <Wes2PendingChange>[];
    }
  }

  /// Rows to show when the server is unreachable: the local draft with pending
  /// intent applied. Null when there is nothing stored locally either.
  Future<List<Wes2ExerciseRow>?> _offlineRowsFromLocalState() async {
    try {
      final draft = await _localStore.loadDraft(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
      );
      final List<Wes2ExerciseRow> rows = draft?.rows ?? const <Wes2ExerciseRow>[];
      if (rows.isEmpty) return null;
      final pending = await _loadPendingChanges();
      return _hardened(wes2ApplyPendingOverlay(rows, pending));
    } catch (e) {
      debugPrint('[WES2SYNC] offline fallback failed: $e');
      return null;
    }
  }

  /// Retries the current day load for the currently selected date and acting
  /// athlete. Guards against overlapping retries via [_retryInProgress] and the
  /// controller's loading state. Safe to wire directly to the Try again button.
  Future<void> _retryLoad() async {
    if (_retryInProgress || _controller.loadState == Wes2LoadState.loading) {
      return;
    }
    setState(() => _retryInProgress = true);
    try {
      await _loadDay();
    } finally {
      if (mounted) setState(() => _retryInProgress = false);
    }
  }

  /// Runs one hint pass through [Wes2HintLoadRunner].
  ///
  /// Everything the pass needs to guard against — a date change, an athlete
  /// switch, a reload, a settings save landing mid-flight — lives in the
  /// runner, which applies its result only while it is still the current pass.
  Future<void> _loadAndApplyHints() async {
    final Wes2HintPassOutcome outcome = await _hintRunner.run();
    if (outcome != Wes2HintPassOutcome.applied) return;
    if (!mounted) return;

    // A background history refresh may still be in flight. The hints just
    // applied came from valid history, so nothing bogus is on screen; when
    // fresher history lands, recompute once and apply atomically.
    final pending =
        ProgressionHistoryStore.instance.pendingRefresh(_controller.actingUid);
    if (pending != null && !_awaitingHistoryRefresh) {
      _awaitingHistoryRefresh = true;
      // ignore: discarded_futures
      pending.whenComplete(() {
        _awaitingHistoryRefresh = false;
        if (!mounted) return;
        // ignore: discarded_futures
        _loadAndApplyHints();
      });
    }
  }

  /// Ensures the athlete's canonical progression history is hydrated and
  /// published before hints are computed.
  ///
  /// This used to fetch only [blockStart .. selectedDate] from the server and
  /// rebuild the top-set index from that bounded window, which silently
  /// discarded every workout older than the current block — an exercise with
  /// years of top sets could still be classified as "no history" and fall back
  /// to the generic 5 kg / 20 kg default.
  ///
  /// [ProgressionHistoryStore] now owns hydration for the whole app:
  ///   * one authoritative server read per athlete per session, deduplicated
  ///     with WarmupService through an in-flight Future keyed on UID,
  ///   * zero network work when reopening WES2 with a still-valid snapshot,
  ///   * a partial Firestore cache is never treated as complete history.
  ///
  /// First paint is unaffected: rows are already on screen before the hint
  /// pass (and therefore this call) runs.
  Future<void> _refreshHistoryForHints(DateTime selectedDate) async {
    final uid = _controller.actingUid;
    if (uid.isEmpty) return;

    final store = ProgressionHistoryStore.instance;
    await store.ensureHydrated(uid: uid);

    if (Wes2HintTrace.enabled) {
      final snap = store.snapshotFor(uid);
      Wes2HintTrace.log(
          'history',
          'snapshot uid=$uid workouts=${snap?.workoutCount ?? 0} '
          'authoritative=${snap?.authoritative} '
          'savedList=${PeriodizationModelUtils.savedWorkoutsList.length} '
          'topSetKeys=${PeriodizationModelUtils.topSetsByExercise.length} '
          'indexBuilds=${PeriodizationModelUtils.historyIndexBuilds}');
      _traceHistoryAvailabilityForRows(uid);
    }
  }

  /// Debug-only (cause C probe): for every current row, report whether
  /// topSetsByExercise can be found by exact exerciseId, exact name, and
  /// normalized (lowercased/trimmed) name. A row that resolves by name but
  /// NOT by id is the C-mismatch signature (Top Sets shows history, hints
  /// fall back to defaults like 5 kg).
  void _traceHistoryAvailabilityForRows(String uid) {
    if (!Wes2HintTrace.enabled) return;
    final tops = PeriodizationModelUtils.topSetsByExercise;
    final normKeys = <String, String>{
      for (final k in tops.keys) k.trim().toLowerCase(): k,
    };
    for (final row in _controller.rows) {
      final byId = tops.containsKey(row.exerciseId);
      final byName = tops.containsKey(row.name);
      final normMatch = normKeys[row.name.trim().toLowerCase()];
      final byNorm = normMatch != null;
      final entries = byId
          ? tops[row.exerciseId]!
          : byName
              ? tops[row.name]!
              : byNorm
                  ? tops[normMatch]!
                  : const <Map<String, dynamic>>[];
      final first = entries.isNotEmpty ? entries.first : null;
      final flag = (!byId && (byName || byNorm)) ? ' ⚠️ NAME-ONLY(C)' : '';
      Wes2HintTrace.log(
          'history',
          'avail "${row.name}" byId=$byId byName=$byName byNorm=$byNorm '
          'entries=${entries.length} '
          'latest=${first == null ? '-' : '${first['weight']}kg x${first['reps']} @rir${first['rir']} ${first['date']}'}'
          '$flag',
          exerciseId: row.exerciseId);
    }
  }

  // ── Hint debug snapshot (debug builds only) ───────────────────────────────

  /// Builds a copyable one-shot state dump for the intermittent hint bug.
  /// Reachable only in debug builds (the app-bar item is null-gated on
  /// [Wes2HintTrace.enabled]); reads state only — never mutates anything.
  String _buildHintDebugSnapshot() {
    final b = StringBuffer();
    final tops = PeriodizationModelUtils.topSetsByExercise;
    final normKeys = <String, String>{
      for (final k in tops.keys) k.trim().toLowerCase(): k,
    };
    final prescriptions = _prescriptions;

    b.writeln('===== WES2 HINT DEBUG SNAPSHOT =====');
    b.writeln('capturedAt: ${DateTime.now().toIso8601String()}');
    b.writeln('actingUid: ${_controller.actingUid}');
    b.writeln('actorUid: ${_controller.actorUid}');
    b.writeln('selectedDate: '
        '${_controller.selectedDate.toIso8601String().substring(0, 10)}');
    b.writeln('blockId: ${_controller.activeBlockId}');
    b.writeln('blockStartDate: '
        '${_controller.blockStartDate?.toIso8601String()}');
    b.writeln('loadState: ${_controller.loadState.name} '
        'epoch: ${_controller.loadEpoch}');
    final histSnap =
        ProgressionHistoryStore.instance.snapshotFor(_controller.actingUid);
    b.writeln('historySnapshot: workouts=${histSnap?.workoutCount ?? 0} '
        'authoritative=${histSnap?.authoritative} '
        'hydratedAt=${histSnap?.hydratedAt.toIso8601String()}');
    b.writeln('cachedSettingsKey: ${_hintRunner.settingsKey}');
    b.writeln('savedWorkoutsList: '
        '${PeriodizationModelUtils.savedWorkoutsList.length} entries');
    b.writeln('topSetsByExercise: ${tops.length} keys');
    b.writeln('prescriptions: ${prescriptions.length} exercises');
    b.writeln('');

    for (final row in _controller.rows) {
      b.writeln('--- ROW "${row.name}" (${row.exerciseId}) ---');
      b.writeln('current: ${Wes2HintTrace.fmtRow(row)}');

      final p = prescriptions[row.exerciseId];
      if (p == null || p.isEmpty) {
        b.writeln('prescription: none (model hints only)');
      } else {
        b.writeln('prescription (${p.source.name}): '
            '${p.sets.map((x) => '${x.weight ?? '-'}x${x.reps ?? '-'}@${x.rir ?? '-'}').join(' | ')}');
      }

      final s = _cachedExerciseSettings[row.exerciseId];
      final usable = BlockExerciseDefaultsRepository.isSettingsUsable(
          s is Map<String, dynamic> ? s : null);
      b.writeln('exerciseSettings: present=${s != null} usable=$usable'
          '${s is Map ? ' model=${s['periodizationModel']}' : ''}');

      final byId = tops.containsKey(row.exerciseId);
      final byName = tops.containsKey(row.name);
      final normMatch = normKeys[row.name.trim().toLowerCase()];
      b.writeln('topSets: byId=$byId byName=$byName byNorm=${normMatch != null}'
          '${!byId && (byName || normMatch != null) ? ' ⚠️ NAME-ONLY(C)' : ''}');
      final entries = byId
          ? tops[row.exerciseId]!
          : byName
              ? tops[row.name]!
              : normMatch != null
                  ? tops[normMatch]!
                  : const <Map<String, dynamic>>[];
      for (final e in entries.take(3)) {
        b.writeln('  topSet: ${e['weight']}kg x${e['reps']} @rir${e['rir']} '
            '${e['date']}');
      }

      final rowTrace =
          Wes2HintTrace.tail(n: 25, exerciseId: row.exerciseId);
      b.writeln('trace (last ${rowTrace.length} events for this exercise):');
      for (final line in rowTrace) {
        b.writeln('  $line');
      }
      b.writeln('');
    }

    b.writeln('--- GLOBAL TRACE TAIL (${Wes2HintTrace.eventCount} total) ---');
    for (final line in Wes2HintTrace.tail(n: 80)) {
      b.writeln(line);
    }
    b.writeln('===== END SNAPSHOT =====');
    return b.toString();
  }

  Future<void> _showHintDebugSnapshot() async {
    final snapshot = _buildHintDebugSnapshot();
    Wes2HintTrace.log('snapshot', 'captured (${snapshot.length} chars)');
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('WES2 hint debug snapshot',
            style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              snapshot,
              style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: snapshot));
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Hint debug snapshot copied')),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  /// Returns true if [date] (midnight-normalised) is strictly before
  /// [blockStart] (midnight-normalised). Prevents negative week/day indices.
  static bool _isBeforeBlockStart(DateTime date, DateTime blockStart) {
    final d = DateTime(date.year, date.month, date.day);
    final b = DateTime(blockStart.year, blockStart.month, blockStart.day);
    return d.isBefore(b);
  }

  /// Converts blockStart + selected date to BB3 weekIndex / dayIndex.
  /// Matches BB3PlannedExerciseService.dateToWeekDay logic; no import needed.
  static ({int weekIndex, int dayIndex}) _weekDayFromDate(
    DateTime blockStart,
    DateTime date,
  ) {
    final base = DateTime(blockStart.year, blockStart.month, blockStart.day);
    final sel = DateTime(date.year, date.month, date.day);
    final days = sel.difference(base).inDays;
    return (weekIndex: days ~/ 7, dayIndex: days % 7);
  }

  /// Merges completed + WES2-planned rows (Phase 3) with BB3 rows (Phase 4).
  /// When the same exerciseId appears in both lists, the rows are merged
  /// field-by-field so BB3 hint values are preserved underneath completed
  /// actual values rather than being discarded by a row-level putIfAbsent.
  static List<Wes2ExerciseRow> _mergeRows(
    List<Wes2ExerciseRow> completedRows,
    List<Wes2ExerciseRow> bb3Rows,
  ) {
    // Index bb3 rows for O(1) lookup.
    final bb3ById = <String, Wes2ExerciseRow>{};
    for (final r in bb3Rows) {
      bb3ById.putIfAbsent(r.exerciseId, () => r);
    }

    final seen = <String, Wes2ExerciseRow>{};

    for (final completed in completedRows) {
      final bb3 = bb3ById[completed.exerciseId];
      if (bb3 != null) {
        // Both sources have this exercise: inject BB3 hints into completed row.
        seen[completed.exerciseId] = _mergeCompletedAndBb3Row(completed, bb3);
      } else {
        seen.putIfAbsent(completed.exerciseId, () => completed);
      }
    }

    // BB3-only rows (no matching completed row): keep as-is.
    for (final bb3 in bb3Rows) {
      seen.putIfAbsent(bb3.exerciseId, () => bb3);
    }

    return seen.values.toList()
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  }

  /// Produces one row that preserves actual values, executionNote, and
  /// isMarkedDone from [completed] while injecting hint values and planNote
  /// from [bb3]. setCount is the max of both sources so hints for sets beyond
  /// the completed count are not dropped.
  static Wes2ExerciseRow _mergeCompletedAndBb3Row(
    Wes2ExerciseRow completed,
    Wes2ExerciseRow bb3,
  ) {
    // Saved structure wins over a larger plan: a row the athlete has already
    // shaped keeps its own count, and the plan's extra sets are not re-added.
    // Prescriptions stay POSITIONAL, so set i keeps prescription i.
    final setCount = completed.structureEstablished
        ? completed.setCount
        : (completed.setCount > bb3.setCount ? completed.setCount : bb3.setCount);
    final sets = List.generate(setCount, (i) {
      final cs = i < completed.sets.length ? completed.sets[i] : null;
      final bs = i < bb3.sets.length ? bb3.sets[i] : null;
      return _mergeSetHintsAndActuals(cs, bs, i);
    });
    return completed.copyWith(
      sets: sets,
      setCount: setCount,
      exercisePlanNote: bb3.exercisePlanNote,
    );
  }

  /// Merges one set slot: actual values and executionNote come from
  /// [completedSet]; hint values and planNote come from [bb3Set].
  static Wes2SetState _mergeSetHintsAndActuals(
    Wes2SetState? completedSet,
    Wes2SetState? bb3Set,
    int setIndex,
  ) {
    if (completedSet == null && bb3Set == null) {
      return Wes2SetState(setIndex: setIndex);
    }
    if (bb3Set == null) return completedSet!;
    if (completedSet == null) return bb3Set;
    // withHint preserves existing actualValue while injecting the hint.
    return Wes2SetState(
      setIndex: setIndex,
      // Execution identity wins: the BB3 side is a plan hint and carries none.
      setId: completedSet.setId ?? bb3Set.setId,
      weight: completedSet.weight
          .withHint(bb3Set.weight.hintValue, FieldOrigin.bb3Hint),
      reps: completedSet.reps
          .withHint(bb3Set.reps.hintValue, FieldOrigin.bb3Hint),
      rir: completedSet.rir.withHint(bb3Set.rir.hintValue, FieldOrigin.bb3Hint),
      velocity: completedSet.velocity
          .withHint(bb3Set.velocity.hintValue, FieldOrigin.bb3Hint),
      executionNote: completedSet.executionNote,
      planNote: bb3Set.planNote,
    );
  }

  /// Deduplicates rows by exerciseId (completedServer wins over planned/manual)
  /// and normalizes any zero-setCount ghost rows. Applied at all row entry points.
  static List<Wes2ExerciseRow> _hardened(List<Wes2ExerciseRow> rows) {
    const sourcePriority = {
      Wes2RowSource.completedServer: 0,
      Wes2RowSource.bb3Planned: 1,
      Wes2RowSource.templateLoaded: 1,
      Wes2RowSource.localDraft: 1,
      Wes2RowSource.wes2Manual: 2,
    };
    // Sort so higher-priority source is first — wins putIfAbsent-style dedupe.
    final sorted = List<Wes2ExerciseRow>.from(rows)
      ..sort((a, b) {
        final pa = sourcePriority[a.source] ?? 1;
        final pb = sourcePriority[b.source] ?? 1;
        if (pa != pb) return pa.compareTo(pb);
        return a.orderIndex.compareTo(b.orderIndex);
      });
    final seen = <String>{};
    final deduped = <Wes2ExerciseRow>[];
    for (final r in sorted) {
      final key = r.exerciseId.trim().toLowerCase();
      if (seen.add(key)) deduped.add(_normalizeSetCount(r));
    }
    deduped.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return deduped;
  }

  static Wes2ExerciseRow _normalizeSetCount(Wes2ExerciseRow row) {
    if (row.setCount > 0) return row;
    final fallback = row.source == Wes2RowSource.completedServer ? 1 : 3;
    return row.copyWith(
      setCount: row.sets.isNotEmpty ? row.sets.length : fallback,
    );
  }

  /// Called when any set field loses focus. Parses the raw text and fires a
  /// fire-and-forget Firestore field patch via [_saveFieldSilently].
  void _onFieldUnfocused(
    String exerciseId,
    int setIndex,
    Wes2FieldKey fieldKey,
    String rawText,
  ) {
    // ── Tutorial auto-advancement (additive — does not alter save variables) ─
    if (rawText.trim().isNotEmpty) {
      if (_tutorialStep == 3 && fieldKey == Wes2FieldKey.weight) {
        // Weight entered → advance to reps cue.
        if (mounted) setState(() => _tutorialStep = 4);
      } else if (_tutorialStep == 5 && fieldKey == Wes2FieldKey.rir) {
        // RIR entered → complete tutorial (idempotent with _onTutorialStepDismiss).
        final uid = _authUidOrNull();
        if (uid != null) {
          unawaited(OnboardingCueService.instance
              .markCueComplete(OnboardingCueId.wes2FieldWalkthrough, uid));
        }
        if (mounted) setState(() => _tutorialStep = 0);
      }
    }
    // ─────────────────────────────────────────────────────────────────────────
    final text = rawText.trim();
    final dynamic value;
    if (text.isEmpty) {
      value = null; // blank → remove field from Firestore set map
    } else {
      value = _parseFieldValue(fieldKey, text);
      if (value == null) return; // invalid non-empty → skip save
      if (fieldKey == Wes2FieldKey.weight ||
          fieldKey == Wes2FieldKey.reps ||
          fieldKey == Wes2FieldKey.rir) {
        _startWorkoutDurationSegment();
      }
    }
    final rowIdx =
        _controller.rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _controller.rows[rowIdx];
    // ignore: discarded_futures
    _saveFieldSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      row: row,
      setIndex: setIndex,
      fieldKey: fieldKey,
      value: value,
    );
  }

  /// Makes one athlete mutation DURABLE, then lets the engine sync it.
  ///
  /// This replaced thirteen `catch (_) {}` wrappers. Each of those attempted a
  /// Firestore transaction and discarded the failure, so a lift logged with no
  /// signal existed on screen, in the controller and in the draft — and nowhere
  /// on the server, with nothing queued to try again. Now the local write comes
  /// FIRST and the network attempt is a retry of something already safe.
  ///
  /// The returned future covers the local write only. Callers on the hot path
  /// (a field losing focus) do not await it; the deliberate actions — leaving
  /// the screen, and the Done checkmark — await [_awaitDurableWrites], which
  /// waits for SQLite and never for the network.
  Future<void> _submitMutation(Wes2Mutation mutation) =>
      _durableWrites.track(_submitMutationInner(mutation));

  Future<void> _submitMutationInner(Wes2Mutation mutation) async {
    try {
      final Wes2SyncServices services =
          await Wes2SyncServices.ensureInitialised();
      await services.engine.submit(mutation);
    } catch (e, st) {
      // The outbox itself could not be written. Nothing else can be done here,
      // but this is a real defect rather than an expected offline condition, so
      // it is logged loudly instead of being swallowed.
      debugPrint('[WES2SYNC] durable enqueue FAILED '
          'kind=${mutation.kind} ex=${mutation.exerciseId}: $e'
          '\n$st');
    }
  }

  /// A one-line, non-intrusive account of anything not yet on the server.
  ///
  /// Renders nothing at all in the overwhelmingly common case, so an ordinary
  /// online session looks exactly as it always has. It exists because silence
  /// is what made the original bug invisible: the athlete had no way to tell a
  /// saved lift from a lost one.
  Widget _buildSyncStatusLine() {
    if (_syncStatus.isIdle) return const SizedBox.shrink();
    final bool issue = _syncStatus.hasIssue;
    final String text = issue
        ? 'Sync issue - tap to retry'
        : 'Saved on device - syncing';
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, bottom: 2),
      child: GestureDetector(
        onTap: issue
            ? () => unawaited(Wes2SyncServices.retryBlockedNow())
            : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              issue ? Icons.sync_problem : Icons.cloud_queue,
              size: 12,
              color: issue ? Colors.amberAccent : Colors.white38,
            ),
            const SizedBox(width: 4),
            Text(
              text,
              style: TextStyle(
                fontSize: 11,
                color: issue ? Colors.amberAccent : Colors.white38,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Waits for every in-flight LOCAL durability write. Never waits on network.
  ///
  /// Used by the deliberate-exit paths and by Done, so navigation and the
  /// checkmark stay instant while the last thing the athlete typed is
  /// guaranteed to be on disk before the field widgets are destroyed.
  Future<void> _awaitDurableWrites() => _durableWrites.settle();

  /// The signed-in account, or null when Firebase Auth is not available.
  /// Reading `FirebaseAuth.instance` throws when no app is configured, which
  /// must not take down an ordinary screen path.
  static String? _authUidOrNull() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  String get _actorUidForMutations {
    final String fromAuth = _authUidOrNull() ?? '';
    if (fromAuth.isNotEmpty) return fromAuth;
    // Coach mode still routes through the authenticated account; the controller
    // actor is the fallback for the brief window before auth has surfaced.
    return _controller.actorUid;
  }

  /// Queues one set-field edit or clear.
  ///
  /// [value] null is an explicit CLEAR and is queued as such, so a value the
  /// athlete deleted offline does not reappear from the server at the next
  /// merge.
  Future<void> _saveFieldSilently({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setIndex,
    required Wes2FieldKey fieldKey,
    required dynamic value,
  }) async {
    await _submitMutation(Wes2Mutation.fieldPatch(
      actorUid: _actorUidForMutations,
      athleteUid: uid,
      date: date,
      row: row,
      setIndex: setIndex,
      fieldKey: fieldKey,
      value: value,
    ));
  }

  /// Post-confirmation side effects for one synced mutation.
  ///
  /// Runs when the SERVER has accepted the write, which may be minutes after
  /// the athlete typed it, or on a later launch entirely. Both effects are
  /// idempotent: [_checkQualifyingDate] is guarded by the per-date key in the
  /// membership document, and set-video reconciliation is a no-op for a day
  /// with no footage — so a replay after a crash cannot double-count a
  /// qualifying day or republish a proof.
  void _onMutationConfirmed(Wes2MutationRow row) {
    if (!mounted) return;
    if (row.kind != Wes2MutationKind.field) return;
    final Map<String, dynamic> payload =
        Wes2Mutation.decodePayload(row.payloadJson);
    if (payload['value'] == null) return;
    final Wes2FieldKey? key = Wes2Mutation.fieldKeyFrom(payload);
    if (key != Wes2FieldKey.weight && key != Wes2FieldKey.reps) return;
    if (row.athleteUid != _controller.actingUid) return;
    final DateTime date = wes2DateFromKey(row.dateKey);
    unawaited(() async {
      try {
        await _checkQualifyingDate(date: date);
        await _maybeReconcileAfterSetSave();
      } catch (e) {
        debugPrint('[WES2SYNC] post-confirm side effect failed: $e');
      }
    }());
  }

  /// Fetches the membership doc once per session and populates the local
  /// qualified-dates cache. No-ops if already loaded or loading.
  Future<void> _ensureQualifiedDatesLoaded() async {
    if (_qualifiedDatesLoaded || _qualifiedDatesLoading) return;
    _qualifiedDatesLoading = true;
    try {
      final actorUid = _controller.actorUid;
      if (actorUid.isEmpty) return;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(actorUid)
          .collection('profile')
          .doc('membership')
          .get();
      if (doc.exists) {
        final data = doc.data() ?? {};
        final datesMap =
            (data['qualifiedWorkoutDates'] as Map<String, dynamic>?) ?? {};
        _qualifiedDatesCached.addAll(datesMap.keys);
        // Fall back to map length if the count field is missing (legacy docs).
        _qualifiedDaysCountCached =
            (data['qualifiedWorkoutDaysCount'] as int?) ?? datesMap.length;
      }
      _qualifiedDatesLoaded = true;
    } catch (e) {
      debugPrint('[WES2] _ensureQualifiedDatesLoaded error: $e');
      // Leave _qualifiedDatesLoaded false so the next save retries.
    } finally {
      _qualifiedDatesLoading = false;
    }
  }

  /// Called after each confirmed weight/reps save.
  /// Counts qualifying sets (a valid stored weight AND reps > 0) across all rows for
  /// [date]. If the date reaches ≥ 2 qualifying sets and hasn't been counted
  /// before, records it in the membership doc and increments the count.
  /// When the count reaches 1 (the user's first qualifying day), sets
  /// paywallTriggered: true.
  /// Uses actorUid (logged-in account UID) — never the impersonated athlete.
  Future<void> _checkQualifyingDate({required DateTime date}) async {
    final actorUid = _controller.actorUid;
    if (actorUid.isEmpty) return;

    final dateKey =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    if (!_qualifiedDatesLoaded) {
      await _ensureQualifiedDatesLoaded();
    }

    // Already counted for this date → nothing to do.
    if (_qualifiedDatesCached.contains(dateKey)) return;

    // Count performed sets across all rows, using the shared raw-set rule: a
    // stored 0 is "0 kg ADDED" on a bodyweight exercise (a real set) and
    // nothing logged on every other exercise. Negative is never valid.
    int validSets = 0;
    outer:
    for (final r in _controller.rows) {
      final bool isBw = PeriodizationModelUtils.isBodyweightExercise(
        id: r.exerciseId,
        name: r.name,
        type: r.exerciseType,
      );
      for (final s in r.sets) {
        if (isRawSetPerformed(
            weightKg: s.weight.actualValue,
            reps: s.reps.actualValue,
            isBodyweight: isBw)) {
          validSets++;
          if (validSets >= 2) break outer;
        }
      }
    }
    if (validSets < 2) return;

    // Date qualifies — update local cache first, then persist.
    _qualifiedDatesCached.add(dateKey);
    _qualifiedDaysCountCached++;
    final triggerPaywall = _qualifiedDaysCountCached >= 1;

    // Record qualifying day in the local cache (actor-keyed). The DURABLE
    // authority for the 3-day unlock is the membership doc count
    // (_qualifiedDaysCountCached), updated just above, so the gate survives
    // reinstall / device change.
    await OnboardingPrefs.addWesCogCueQualifiedDay(actorUid, dateKey);
    if (!_cogCueDismissed &&
        !_cogCueUnlocked &&
        _qualifiedDaysCountCached >= 3 &&
        mounted) {
      setState(() => _cogCueUnlocked = true);
    }

    try {
      final membershipRef = FirebaseFirestore.instance
          .collection('users')
          .doc(actorUid)
          .collection('profile')
          .doc('membership');

      final Map<String, dynamic> patch = {
        'qualifiedWorkoutDates.$dateKey': true,
        'qualifiedWorkoutDaysCount': FieldValue.increment(1),
        if (triggerPaywall) 'paywallTriggered': true,
        if (triggerPaywall) 'paywallTriggeredAt': FieldValue.serverTimestamp(),
      };
      await membershipRef.update(patch);
      debugPrint(
          '[WES2] qualifyingDate=$dateKey count=$_qualifiedDaysCountCached paywall=$triggerPaywall');
    } catch (e) {
      debugPrint('[WES2] _checkQualifyingDate write failed: $e');
      // Roll back local cache so the next save retries.
      _qualifiedDatesCached.remove(dateKey);
      _qualifiedDaysCountCached--;
    }
  }

  /// "Completed?" / "Mark as not done".
  ///
  /// Done is a checkmark and nothing else — it never accepts, materialises or
  /// infers a value. What it now does is WAIT for the field the athlete is
  /// still typing in to finish its OWN ordinary save first.
  ///
  /// Without that wait, "type RIR, tap Completed? immediately" lost the RIR:
  /// toggling `isMarkedDone` re-keys the card's ExpansionTile, every
  /// `Wes2SetRow` is disposed, and `dispose()` removes the focus listeners
  /// before the nodes ever report the focus loss — so the field patch was
  /// never created, while the Done mutation went through. See
  /// [Wes2DoneCoordinator] for the full ordering contract.
  void _onToggleMarkedDone(String exerciseId, bool isDone) {
    unawaited(_doneCoordinator.toggleMarkedDone(
      exerciseId: exerciseId,
      dropFocus: () => FocusManager.instance.primaryFocus?.unfocus(),
      awaitDurableWrites: _awaitDurableWrites,
      commitDone: () => _commitMarkedDone(exerciseId, isDone),
    ));
  }

  /// The ordinary Done work, run only once the focused field's mutation is on
  /// disk: flip the controller, then queue the completion checkmark.
  Future<void> _commitMarkedDone(String exerciseId, bool isDone) async {
    // The barrier is awaited above, so the screen may have been left in the
    // meantime; the controller is disposed with it and must not be notified.
    // The durable mutation is still queued, so the tap is never lost.
    if (mounted) _controller.toggleMarkedDone(exerciseId, isDone);
    final rowIdx =
        _controller.rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _controller.rows[rowIdx];
    await _setMarkedDoneSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      row: row,
      isDone: isDone,
    );
  }

  /// Queues the completion checkmark, and NOTHING else.
  ///
  /// The mutation carries `isDone` plus the row for the repository's existing
  /// create/promote path, which serialises actualValues only. No hint of any
  /// kind can become execution data by way of Done.
  Future<void> _setMarkedDoneSilently({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required bool isDone,
  }) async {
    await _submitMutation(Wes2Mutation.markDone(
      actorUid: _actorUidForMutations,
      athleteUid: uid,
      date: date,
      row: row,
      isDone: isDone,
    ));
  }

  // ── Add Set (Phase 10) ────────────────────────────────────────────────────

  void _onAddSet(String exerciseId) {
    _controller.addSet(exerciseId);
    // Persist new setCount to local draft immediately so blank added sets
    // survive fast reopen, especially for BB3-planned rows where no Firestore
    // write occurs until the user types an actual value.
    _saveDraftNow();

    final rowIdx =
        _controller.rows.indexWhere((r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    final row = _controller.rows[rowIdx];

    // Reapply hints so the new set receives normal cascade hints immediately.
    // ignore: discarded_futures
    _loadAndApplyHints();

    // BB3-planned rows with no actuals are not yet materialised in the workout
    // document — skip Firestore until the first actual value is typed.
    if (row.source == Wes2RowSource.bb3Planned && !row.hasAnyExecutionValue) {
      return;
    }

    // ignore: discarded_futures
    _saveSetCountSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      row: row,
      setCount: row.setCount,
    );
  }

  Future<void> _saveSetCountSilently({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setCount,
  }) async {
    await _submitMutation(Wes2Mutation.setCount(
      actorUid: _actorUidForMutations,
      athleteUid: uid,
      date: date,
      row: row,
      setCount: setCount,
    ));
  }

  /// Parses [text] into the correct Dart type for [fieldKey].
  /// Returns null if [text] cannot be parsed (invalid non-empty input).
  /// Parses [text] for [fieldKey], or null when it is not a saveable number.
  /// Shared with the controller and the row widget so every path agrees on
  /// what counts as an entry - NaN, Infinity and exponent forms do not.
  static dynamic _parseFieldValue(Wes2FieldKey fieldKey, String text) =>
      Wes2FieldParser.valueOrNull(fieldKey, text);

  /// Deliberate exit to the actual previous route (explicit Back button and
  /// Android/system Back via PopScope).
  ///
  /// Delegates to [Wes2ExitCoordinator] (real production logic, also driven by
  /// tests). The coordinator drops focus FIRST so the still-mounted Wes2SetRow
  /// focus listener fires its existing onFieldUnfocused save exactly once and
  /// the iOS keyboard is dismissed before the route subtree is torn down, then
  /// navigates exactly once: pops one route when one exists beneath (returning
  /// to Home, BB3, or whatever pushed WES2), or pushReplacementNamed('/home')
  /// for a restored root WES2 route so the app never closes.
  ///
  /// The Firestore field patch is intentionally NOT awaited — the controller
  /// already holds the latest typed value (synchronous onChanged), the focus
  /// callback starts the existing field-patch save, and the local Isar draft is
  /// the fallback.
  Future<void> _exitToPreviousRoute() {
    return _exitCoordinator.exitToPreviousRoute(
      dropFocus: () => FocusManager.instance.primaryFocus?.unfocus(),
      awaitDurableWrites: _awaitDurableWrites,
      isMounted: () => mounted,
      markHomeActive: () => unawaited(
        StartupRouteService.markHomeActive(
          UserContext.of(context, listen: false).actorUid,
        ),
      ),
      navigatorOf: () => mounted ? Navigator.of(context) : null,
    );
  }

  /// Deliberate exit straight to Home (GoodLift logo). Intentionally different
  /// from Back: it pops past any intermediate routes (e.g. BB3) to the existing
  /// '/home' route, retaining Home state without creating a duplicate, or
  /// pushReplacementNamed('/home') for a restored root WES2 route.
  ///
  /// Shares the coordinator's focus/keyboard sequencing and re-entrancy guard
  /// with [_exitToPreviousRoute]; the focus/draft ordering note above applies.
  Future<void> _exitDirectlyToHome() {
    return _exitCoordinator.exitDirectlyToHome(
      dropFocus: () => FocusManager.instance.primaryFocus?.unfocus(),
      awaitDurableWrites: _awaitDurableWrites,
      isMounted: () => mounted,
      markHomeActive: () => unawaited(
        StartupRouteService.markHomeActive(
          UserContext.of(context, listen: false).actorUid,
        ),
      ),
      navigatorOf: () => mounted ? Navigator.of(context) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<Wes2SessionController>.value(
      value: _controller,
      child: Consumer<Wes2SessionController>(
        builder: (context, controller, _) {
          final uc = UserContext.of(
              context); // listen:true → rebuilds on athlete switch
          final actingUid = uc.currentUid;

          // Guard: if WES2 opened before activeBlockId was available (new-user race),
          // re-init identity and reload once UserContext publishes a non-null blockId.
          if (_controller.activeBlockId == null &&
              uc.activeBlockId != null &&
              uc.activeBlockId!.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _controller.initIdentity(
                actorUid: uc.actorUid,
                actingUid: uc.currentUid,
                isCoach: uc.isCoach,
                activeBlockId: uc.activeBlockId,
                blockStartDate: uc.blockStartDate,
                blockEndDate: uc.blockEndDate,
              );
              _loadDay();
            });
          }

          if (_fetchedForUid != actingUid) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _fetchedForUid != actingUid)
                _fetchAthleteUsername(actingUid);
            });
          }
          if (!_tracedFirstBuild) {
            _tracedFirstBuild = true;
            StartupTrace.wes2FirstBuild();
          }
          return PopScope(
            // Intercept EVERY deliberate back action so focus is dropped (iOS
            // keyboard dismissed + latest field saved via the existing unfocus
            // callback) BEFORE the route subtree is torn down. canPop:false
            // also disables the native iOS interactive edge-swipe back gesture
            // on WES2; the explicit AppBar Back button and system back continue
            // to work and route through _exitToPreviousRoute, which also handles
            // the restored-root '/home' replacement so a root WES2 never closes
            // the app (Issue 5).
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (didPop) return;
              // ignore: discarded_futures
              _exitToPreviousRoute();
            },
            child: Scaffold(
              appBar: Wes2AppBar(
                // Back → previous route; logo → straight Home. Both route through
                // the shared exit coordinator (focus drop + guard).
                onBack: _exitToPreviousRoute,
                onHome: _exitDirectlyToHome,
                greeting: _athleteGreeting,
                username: _athleteUsername,
                canUndo: controller.canUndo,
                onUndo: _performUndo,
                onRefresh: () {
                  _saveDraftNow();
                  _loadDay();
                },
                onToggleTimer: _toggleTimerVisible,
                onShowTemplates: _showTemplatePicker,
                // Local calculator: never touches the controller or workout.
                onShowWeightConverter: () =>
                    unawaited(showWes2WeightConverter(context)),
                onDeleteAll: _onDeleteAllExercisesForDay,
                onHintDebugSnapshot: null,
              ),
              body: Stack(
                children: [
                  Column(
                    children: [
                      Wes2DayHeader(
                        date: controller.selectedDate,
                        onSelectDate: _onSelectDate,
                        onPrevDay: _onPrevDay,
                        onNextDay: _onNextDay,
                      ),
                      _buildSyncStatusLine(),
                      const Divider(height: 1),
                      Expanded(child: _buildBody(context, controller)),
                    ],
                  ),
                  if (_timerVisible)
                    Positioned(
                      right: 12,
                      bottom: MediaQuery.of(context).padding.bottom + 2,
                      child: _buildFloatingTimer(),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, Wes2SessionController controller) {
    // Error state: full-screen polished message with a retry action.
    // The raw exception is intentionally never rendered here — it is logged in
    // _loadDay. App bar and date header remain mounted above _buildBody, so back
    // and date navigation stay usable.
    if (controller.loadState == Wes2LoadState.error) {
      final retrying =
          _retryInProgress || controller.loadState == Wes2LoadState.loading;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 40,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(height: 16),
              const Text(
                'We couldn’t load this workout',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Check your connection and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.white60),
              ),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: retrying ? null : _retryLoad,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                ),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    // All non-error states show the top action bar so Add Exercise is always
    // reachable — including during loading (queues the add until data arrives).
    return Column(
      children: [
        Wes2TopActionsBar(
          onAddExercise: _onAddExercise,
          onLoadTemplate: _showTemplatePicker,
          highlightLoadTemplate: _tutorialStep == 1,
        ),
        if (controller.hasPendingExerciseAdds &&
            (controller.loadState == Wes2LoadState.loading ||
                controller.loadState == Wes2LoadState.idle))
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              'Adding exercises when loaded…',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ),
        if (_tutorialStep >= 3)
          Wes2TutorialBanner(
            step: _tutorialStep - 2, // 3→1(weight) 4→2(reps) 5→3(RIR)
            onDismiss: _onTutorialStepDismiss,
            onBack: _tutorialStep >= 4 ? _onTutorialStepBack : null,
          ),
        Expanded(child: _buildContentArea(context, controller)),
      ],
    );
  }

  Widget _buildContentArea(
      BuildContext context, Wes2SessionController controller) {
    switch (controller.loadState) {
      case Wes2LoadState.idle:
      case Wes2LoadState.loading:
        return const Center(child: Wes2WaitForIt());
      case Wes2LoadState.empty:
        return ListView(
          children: [
            const Wes2EmptyState(),
            Wes2BottomActionsRow(
              setsLogged: 0,
              onAddCircuit: _onAddCircuit,
              onSummary: _showWorkoutSummary,
            ),
          ],
        );
      case Wes2LoadState.loaded:
        final rows = controller.rows;
        final setsLogged =
            rows.expand((r) => r.sets).where((s) => s.hasAnyActual).length;

        final showCogCue =
            _tutorialStep == 0 && !_cogCueDismissed && _cogCueUnlocked;

        // Build flat item list: circuit headers inserted when circuitIndex changes.
        final items = <Widget>[];
        int? prevCi;
        bool isFirstCard = true;
        for (final row in rows) {
          if (prevCi == null || row.circuitIndex != prevCi) {
            final ci = row.circuitIndex;
            items.add(
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  children: [
                    Text(
                      'Circuit ${ci + 1}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text(
                        'Add Exercise',
                        style: TextStyle(fontSize: 12),
                      ),
                      onPressed: () => _onAddExerciseToCircuit(ci),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.primary,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
            );
            prevCi = ci;
          }
          final combinedNote = _buildCombinedPlanNote(row);
          final cardKey = _exerciseCardKeys.putIfAbsent(
            row.exerciseId,
            GlobalKey.new,
          );
          final bool isVoiceTarget = _voiceTargetShown &&
              row.exerciseId == _voiceTarget.exerciseId;
          items.add(KeyedSubtree(
            key: cardKey,
            // Always present (transparent unless targeted) so toggling the
            // outline never rebuilds the card's own state or fields.
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isVoiceTarget
                      ? Theme.of(context).colorScheme.secondary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Wes2ExerciseCard(
              row: row,
              weightUnit: ExerciseUnitRegistry.shared
                  .unitsFor(controller.actingUid,
                      blockSettings: controller.exerciseSettings)
                  .unitFor(row.exerciseId),
              onFieldUnfocused: _onFieldUnfocused,
              onToggleMarkedDone: (isDone) =>
                  _onToggleMarkedDone(row.exerciseId, isDone),
              onAddSet: () => _onAddSet(row.exerciseId),
              onSettings: () => _showExerciseSettingsDialog(row),
              onDelete: () => _onDeleteExercise(row),
              onReplace: () => _onReplaceExercise(row),
              onMoveToCircuit: () => _onMoveExerciseToCircuit(row),
              onNotes: () => _showExerciseNoteDialog(row),
              onRemoveSet: (setIndex) => _onRemoveSet(row, setIndex),
              onNoteTap: (setIndex) => _onOpenSetNoteDialog(row, setIndex),
              onVideoTap: (setIndex) => _onSetVideoTap(row, setIndex),
              setsWithVideo:
                  _setsWithVideo[row.exerciseId] ?? const <int>{},
              onExerciseDetails: () => _navigateToExerciseDetails(row),
              onTopSets: () => _navigateToTopSets(row),
              isExercisePlanNoteRead:
                  controller.isExercisePlanNoteRead(row.exerciseId),
              hasExerciseExecutionNote:
                  row.exerciseExecutionNote?.trim().isNotEmpty == true,
              onOpenExercisePlanNote: combinedNote != null
                  ? () => _onOpenExercisePlanNoteDialog(row, combinedNote)
                  : null,
              showVelocityField: _shouldShowVelocityField(row),
              tutorialStep: isFirstCard
                  ? (_tutorialStep >= 3 ? _tutorialStep - 2 : 0)
                  : 0,
              onTutorialRepsAccepted: (isFirstCard && _tutorialStep == 4)
                  ? _onRepsTutorialAccepted
                  : null,
              showCogCue: isFirstCard && showCogCue,
            ),
            ),
          ));
          isFirstCard = false;
        }

        items.add(Wes2BottomActionsRow(
          setsLogged: setsLogged,
          onAddCircuit: _onAddCircuit,
          onSummary: _showWorkoutSummary,
          onSaveAsTemplate:
              controller.canSaveAsTemplate ? _showSaveAsTemplateDialog : null,
        ));
        return ListView(children: items);
      case Wes2LoadState.error:
        return const SizedBox.shrink(); // unreachable: handled in _buildBody
    }
  }

  // ── Add Exercise / Add Circuit (Phase 13) ────────────────────────────────

  /// Opens the picker and returns the selection including chosen circuit,
  /// or null if dismissed.
  /// [excludedIds] defaults to all current row IDs when omitted.
  /// [titleOverride] replaces the default "Add Exercise to Circuit N" header.
  Future<({String exerciseId, String name, int circuitIndex})?>
      _openExercisePicker({
    required List<int> availableCircuits,
    required int initialCircuitIndex,
    Set<String>? excludedIds,
    String? titleOverride,
  }) {
    final excluded =
        excludedIds ?? _controller.rows.map((r) => r.exerciseId).toSet();
    return showModalBottomSheet<
        ({String exerciseId, String name, int circuitIndex})>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => Wes2ExercisePicker(
        excludedIds: excluded,
        actingUid: _controller.actingUid,
        activeBlockId: _controller.activeBlockId,
        availableCircuits: availableCircuits,
        initialCircuitIndex: initialCircuitIndex,
        titleOverride: titleOverride,
      ),
    );
  }

  /// Applies a picker result to the controller, local draft, and Firestore.
  /// Immediate path: day loaded — persists via saveManualExercise now.
  /// Queue path (loading/idle): deferred to consumeFlushedExercises in _loadDay.
  Future<void> _addExerciseFromPicker(
      ({String exerciseId, String name, int circuitIndex}) result) async {
    final added = _controller.addExercise(
      result.exerciseId,
      result.name,
      circuitIndex: result.circuitIndex,
    );
    final bool viaVoice = _voicePickerOpen;
    _voicePickerOpen = false;
    if (!added) return;
    // A newly added exercise is where the next set entry goes.
    _voiceTarget.select(result.exerciseId);
    // Await defaults so hints are correct immediately after adding.
    final activeBlockId = _controller.activeBlockId;
    if (activeBlockId != null && activeBlockId.isNotEmpty) {
      await BlockExerciseDefaultsRepository.ensureExerciseDefaults(
        uid: _controller.actingUid,
        blockId: activeBlockId,
        exerciseId: result.exerciseId,
      );
    }
    _saveDraftNow();
    if (_controller.loadState == Wes2LoadState.loaded) {
      final rowIdx =
          _controller.rows.indexWhere((r) => r.exerciseId == result.exerciseId);
      if (rowIdx != -1) {
        // ignore: discarded_futures
        _saveManualExerciseSilently(
          uid: _controller.actingUid,
          date: _controller.selectedDate,
          row: _controller.rows[rowIdx],
        );
      }
      // ignore: discarded_futures
      _loadAndApplyHints();
    }
    if (viaVoice && mounted) unawaited(_revealVoiceTarget());
  }

  /// Top "Add Exercise" button — defaults to Circuit 1.
  /// Shows circuit selector inside picker when multiple circuits exist.
  Future<void> _onAddExercise() async {
    final circuits =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final result = await _openExercisePicker(
      availableCircuits: circuits,
      initialCircuitIndex: 0,
    );
    if (result == null) return;
    await _addExerciseFromPicker(result);
  }

  /// Per-circuit header "Add Exercise" button — pre-selects that circuit.
  Future<void> _onAddExerciseToCircuit(int targetCircuitIndex) async {
    final circuits =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final result = await _openExercisePicker(
      availableCircuits: circuits,
      initialCircuitIndex: targetCircuitIndex,
    );
    if (result == null) return;
    await _addExerciseFromPicker(result);
  }

  /// Bottom "Add Circuit" button — pre-selects a new circuit index.
  /// Passes existing circuits + new one so the user may redirect to any.
  Future<void> _onAddCircuit() async {
    if (_controller.loadState != Wes2LoadState.loaded) return;
    final existing =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final nextCircuitIndex = existing.isEmpty ? 0 : existing.last + 1;
    final result = await _openExercisePicker(
      availableCircuits: [...existing, nextCircuitIndex],
      initialCircuitIndex: nextCircuitIndex,
    );
    if (result == null) return;
    await _addExerciseFromPicker(result);
  }

  Future<void> _saveManualExerciseSilently({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
  }) async {
    await _submitMutation(Wes2Mutation.manualExercise(
      actorUid: _actorUidForMutations,
      athleteUid: uid,
      date: date,
      row: row,
    ));
  }

  // ── Date navigation (Phase 13) ────────────────────────────────────────────

  void _onPrevDay() {
    _pauseWorkoutDurationSegment();
    _saveDraftNow();
    _workoutDurationMilliseconds = 0;
    _workoutDurationSegmentStartedAt = null;
    _controller
        .changeDate(_controller.selectedDate.subtract(const Duration(days: 1)));
    _loadDay();
  }

  void _onNextDay() {
    _pauseWorkoutDurationSegment();
    _saveDraftNow();
    _workoutDurationMilliseconds = 0;
    _workoutDurationSegmentStartedAt = null;
    _controller
        .changeDate(_controller.selectedDate.add(const Duration(days: 1)));
    _loadDay();
  }

  Future<void> _onSelectDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _controller.selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day + 365),
    );
    if (picked == null || !mounted) return;
    _pauseWorkoutDurationSegment();
    _saveDraftNow();
    _workoutDurationMilliseconds = 0;
    _workoutDurationSegmentStartedAt = null;
    _controller.changeDate(picked);
    _loadDay();
  }

  // ── Aurelian voice commands (first-party bridge) ─────────────────────────
  //
  // Every command runs the SAME canonical operation as the equivalent tap or
  // typed entry: the Add Exercise picker, updateSetField + _onFieldUnfocused
  // (the durable outbox), _onAddSet, the Done coordinator and the existing
  // note dialogs. Voice only adds a session-local target exercise.

  List<String> _rowIds() =>
      _controller.rows.map((Wes2ExerciseRow r) => r.exerciseId).toList();

  Wes2ExerciseRow? _voiceTargetRow() {
    final String? id = _voiceTarget.resolve(_rowIds());
    if (id == null) return null;
    for (final Wes2ExerciseRow r in _controller.rows) {
      if (r.exerciseId == id) return r;
    }
    return null;
  }

  bool get _isCurrentRoute => ModalRoute.of(context)?.isCurrent ?? true;

  Future<AurelianResult?> _onAurelianCommand(AurelianCommand command) async {
    if (!mounted) return null;
    switch (command.kind) {
      case AurelianCommandKind.openWorkout:
        final String? blocked = await _bringWorkoutToFront();
        return blocked == null
            ? const AurelianResult.ok('Workout open')
            : AurelianResult.unavailable(blocked);
      case AurelianCommandKind.selectExercise:
        // Another screen on top (Analytics) selects there instead.
        if (!_isCurrentRoute) return null;
        if (!await _waitForDay()) {
          return const AurelianResult.unavailable('The workout is still loading');
        }
        return _voiceSelectExercise(command);
      case AurelianCommandKind.addExercise:
      case AurelianCommandKind.nextExercise:
      case AurelianCommandKind.previousExercise:
      case AurelianCommandKind.setFields:
      case AurelianCommandKind.openSetNote:
      case AurelianCommandKind.openExerciseNote:
      case AurelianCommandKind.addSet:
      case AurelianCommandKind.markExerciseDone:
      case AurelianCommandKind.workoutAction:
      case AurelianCommandKind.addExercises:
      case AurelianCommandKind.clearSet:
      case AurelianCommandKind.removeSet:
      case AurelianCommandKind.deleteExercise:
      case AurelianCommandKind.replaceExercise:
      case AurelianCommandKind.addExerciseToCircuit:
      case AurelianCommandKind.moveToCircuit:
        final String? blocked = await _bringWorkoutToFront();
        if (blocked != null) return AurelianResult.unavailable(blocked);
        if (!await _waitForDay()) {
          return const AurelianResult.unavailable('The workout is still loading');
        }
        if (!mounted) return const AurelianResult.unavailable('The workout closed');
        return _runVoiceWorkoutCommand(command);
      case AurelianCommandKind.openAnalytics:
      case AurelianCommandKind.analyticsMetric:
      case AurelianCommandKind.navigate:
      case AurelianCommandKind.executeAction:
        return null;
    }
  }

  /// Makes WES2 the current screen again by popping pages above it (Analytics,
  /// for example). A dialog or sheet is never dismissed (it may hold unsaved
  /// text): popping stops at the first popup, before popping it.
  Future<String?> _bringWorkoutToFront() async {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route == null || route.isCurrent) return null;
    bool blocked = false;
    Navigator.of(context).popUntil((Route<dynamic> r) {
      if (r == route) return true;
      if (r is PopupRoute) {
        blocked = true;
        return true;
      }
      return false;
    });
    if (blocked) return 'Close the open dialog first';
    await WidgetsBinding.instance.endOfFrame;
    return mounted ? null : 'The workout closed';
  }

  /// Waits (bounded) for the day to finish loading, by listening to the
  /// controller rather than sleeping.
  Future<bool> _waitForDay() async {
    bool settled() =>
        _controller.loadState != Wes2LoadState.idle &&
        _controller.loadState != Wes2LoadState.loading;
    if (settled()) return true;
    final Completer<void> done = Completer<void>();
    void listener() {
      if (settled() && !done.isCompleted) done.complete();
    }

    _controller.addListener(listener);
    try {
      await done.future.timeout(const Duration(seconds: 8));
      return true;
    } on TimeoutException {
      return false;
    } finally {
      if (mounted) _controller.removeListener(listener);
    }
  }

  Future<AurelianResult> _runVoiceWorkoutCommand(AurelianCommand command) async {
    // Commands that need no particular exercise.
    switch (command.kind) {
      case AurelianCommandKind.addExercise:
        _voicePickerOpen = true;
        unawaited(_onAddExercise());
        return const AurelianResult.ok(
            'Add Exercise open — say "select" and the exercise');
      case AurelianCommandKind.addExercises:
        return _voiceAddExercises(command);
      case AurelianCommandKind.addExerciseToCircuit:
        final int ci = command.circuit! - 1;
        if (!_circuits().contains(ci)) return _noSuchCircuit(command.circuit!);
        _voicePickerOpen = true;
        unawaited(_onAddExerciseToCircuit(ci));
        return AurelianResult.ok('Add Exercise to Circuit ${ci + 1} open');
      case AurelianCommandKind.workoutAction:
        final AurelianResult? done = _voiceDayAction(command.action!);
        if (done != null) return done;
      default:
        break;
    }

    final ({Wes2ExerciseRow? row, AurelianResult? answer}) target =
        _voiceRowFor(command);
    if (target.answer != null) return target.answer!;
    final Wes2ExerciseRow row = target.row!;
    switch (command.kind) {
      case AurelianCommandKind.nextExercise:
      case AurelianCommandKind.previousExercise:
        final List<String> ids = _rowIds();
        final bool forward = command.kind == AurelianCommandKind.nextExercise;
        final String? id =
            forward ? _voiceTarget.next(ids) : _voiceTarget.previous(ids);
        if (id == null) {
          await _revealVoiceTarget();
          return AurelianResult.unavailable(forward
              ? 'Already on the last exercise (${row.name})'
              : 'Already on the first exercise (${row.name})');
        }
        await _revealVoiceTarget();
        final Wes2ExerciseRow now =
            _controller.rows.firstWhere((Wes2ExerciseRow r) => r.exerciseId == id);
        return AurelianResult.ok(
            '${now.name} (${ids.indexOf(id) + 1} of ${ids.length})');
      case AurelianCommandKind.setFields:
        final ExerciseWeightUnit unit = ExerciseUnitRegistry.shared
            .unitsFor(_controller.actingUid,
                blockSettings: _controller.exerciseSettings)
            .unitFor(row.exerciseId);
        final SetEntryPlan plan = planSetEntry(
          command,
          exerciseName: row.name,
          setCount: row.setCount,
          displayUnit: unit,
          velocityShown: _shouldShowVelocityField(row),
          normalEntry: Wes2ExerciseCard.entryModeFor(row) ==
              Wes2ExerciseEntryMode.normal,
        );
        if (!plan.isValid) return AurelianResult.invalid(plan.error!);
        await _applyVoiceSetEdits(row.exerciseId, plan);
        return AurelianResult.ok('${row.name} · ${plan.summary}');
      case AurelianCommandKind.clearSet:
        return _voiceClearSet(row, command.setNumber!);
      case AurelianCommandKind.removeSet:
        return _voiceRemoveSet(row, command.setNumber!);
      case AurelianCommandKind.deleteExercise:
        final bool wasBb3 = row.source == Wes2RowSource.bb3Planned ||
            _bb3PlannedExerciseIds.contains(row.exerciseId);
        // Undo is offered exactly when the Delete button offers it.
        await _deleteExerciseConfirmed(row,
            offerUndo: row.hasAnyExecutionValue, wasBb3: wasBb3);
        if (mounted) unawaited(_revealVoiceTarget());
        return AurelianResult.ok('Deleted ${row.name}');
      case AurelianCommandKind.replaceExercise:
        return _voiceReplaceExercise(row, command);
      case AurelianCommandKind.moveToCircuit:
        final int ci = command.circuit! - 1;
        if (ci == row.circuitIndex) {
          return AurelianResult.ok('${row.name} is already in Circuit ${ci + 1}');
        }
        if (!_circuits().contains(ci)) return _noSuchCircuit(command.circuit!);
        _moveExerciseToCircuitConfirmed(row, ci);
        _voiceTarget.select(row.exerciseId);
        await _revealVoiceTarget();
        return AurelianResult.ok('${row.name} moved to Circuit ${ci + 1}');
      case AurelianCommandKind.openSetNote:
        final int n = command.setNumber!;
        if (n > row.setCount) return _noSuchSet(row, n);
        await _revealVoiceTarget();
        unawaited(_onOpenSetNoteDialog(row, n - 1, focusNote: true));
        return AurelianResult.ok(
            '${row.name} · set $n note — say "type …", then "tap save"');
      case AurelianCommandKind.openExerciseNote:
        await _revealVoiceTarget();
        unawaited(_showExerciseNoteDialog(row));
        return AurelianResult.ok(
            '${row.name} note — say "type …", then "tap save"');
      case AurelianCommandKind.addSet:
        _onAddSet(row.exerciseId);
        await _revealVoiceTarget();
        final Wes2ExerciseRow now = _controller.rows
            .firstWhere((Wes2ExerciseRow r) => r.exerciseId == row.exerciseId);
        return AurelianResult.ok('${row.name} · set ${now.setCount} added');
      case AurelianCommandKind.markExerciseDone:
        if (row.isMarkedDone) {
          return AurelianResult.ok('${row.name} is already done');
        }
        if (!Wes2ExerciseCard.isCompletedEligible(row)) {
          return AurelianResult.invalid(
              'Log a set of ${row.name} before marking it done');
        }
        _onToggleMarkedDone(row.exerciseId, true);
        await _revealVoiceTarget();
        return AurelianResult.ok('${row.name} marked done');
      case AurelianCommandKind.workoutAction:
        await _revealVoiceTarget();
        switch (command.action!) {
          case AurelianWorkoutAction.exerciseSettings:
            unawaited(_showExerciseSettingsDialog(row));
            return AurelianResult.ok('${row.name} settings');
          case AurelianWorkoutAction.exerciseDetails:
            _navigateToExerciseDetails(row);
            return AurelianResult.ok('${row.name} details');
          case AurelianWorkoutAction.topSets:
            _navigateToTopSets(row);
            return AurelianResult.ok('${row.name} top sets');
          case AurelianWorkoutAction.currentExercise:
            final List<String> ids = _rowIds();
            return AurelianResult.ok(
                'On ${row.name} (${ids.indexOf(row.exerciseId) + 1} of ${ids.length})');
          default:
            return const AurelianResult.unavailable('Not available here');
        }
      default:
        return const AurelianResult.unavailable('Not available here');
    }
  }

  /// Workout controls that act on the day rather than on an exercise; null
  /// for the ones that need an exercise.
  AurelianResult? _voiceDayAction(AurelianWorkoutAction action) {
    String day(DateTime d) =>
        MaterialLocalizations.of(context).formatMediumDate(d);
    switch (action) {
      case AurelianWorkoutAction.loadTemplate:
        if (_isLoadingTemplate) {
          return const AurelianResult.unavailable('A template is still loading');
        }
        unawaited(_showTemplatePicker());
        return const AurelianResult.ok('Templates open');
      case AurelianWorkoutAction.selectDate:
        unawaited(_onSelectDate());
        return const AurelianResult.ok('Choose a date');
      case AurelianWorkoutAction.previousDay:
        _onPrevDay();
        return AurelianResult.ok(day(_controller.selectedDate));
      case AurelianWorkoutAction.nextDay:
        _onNextDay();
        return AurelianResult.ok(day(_controller.selectedDate));
      case AurelianWorkoutAction.addCircuit:
        if (_controller.loadState != Wes2LoadState.loaded) {
          return const AurelianResult.unavailable('The workout is still loading');
        }
        _voicePickerOpen = true;
        unawaited(_onAddCircuit());
        return const AurelianResult.ok('Add Circuit open');
      case AurelianWorkoutAction.exerciseSettings:
      case AurelianWorkoutAction.exerciseDetails:
      case AurelianWorkoutAction.topSets:
      case AurelianWorkoutAction.currentExercise:
        return null;
    }
  }

  List<int> _circuits() =>
      _controller.rows.map((Wes2ExerciseRow r) => r.circuitIndex).toSet().toList()
        ..sort();

  AurelianResult _noSuchCircuit(int circuit) => AurelianResult.invalid(
      'There\'s no Circuit $circuit — say "add circuit" first');

  AurelianResult _noSuchSet(Wes2ExerciseRow row, int n) => AurelianResult.invalid(
      '${row.name} has ${row.setCount} ${row.setCount == 1 ? 'set' : 'sets'}');

  /// The exercise a command acts on: the one it names (which then becomes the
  /// voice target), or the current target. A name is matched against the
  /// workout's own rows; commands that remove or restructure never accept a
  /// fuzzy match. An unclear name comes back as a "which one?".
  ({Wes2ExerciseRow? row, AurelianResult? answer}) _voiceRowFor(
      AurelianCommand command) {
    final String? spoken = command.exercise;
    if (spoken == null) {
      final Wes2ExerciseRow? row = _voiceTargetRow();
      return row == null
          ? (
              row: null,
              answer: const AurelianResult.unavailable(
                  'No exercises in this workout yet — say "add exercise"')
            )
          : (row: row, answer: null);
    }
    final NamedResolution<Wes2ExerciseRow> r = resolveNamed<Wes2ExerciseRow>(
      spoken,
      _controller.rows.toList(),
      (Wes2ExerciseRow row) => row.name,
      (Wes2ExerciseRow row) => row.name,
      choices: command.choices,
      allowFuzzy: !command.kind.isDestructive,
    );
    if (r.isAmbiguous) {
      return (
        row: null,
        answer: AurelianResult.ambiguous('Which $spoken?',
            r.ask.map((Wes2ExerciseRow row) => row.name).toList(),
            context: 'wes2')
      );
    }
    final Wes2ExerciseRow? row = r.chosen;
    if (row == null) {
      return (
        row: null,
        answer: AurelianResult.notFound('"$spoken" isn\'t in this workout')
      );
    }
    if (command.kind != AurelianCommandKind.deleteExercise &&
        command.kind != AurelianCommandKind.replaceExercise) {
      _voiceTarget.select(row.exerciseId);
    }
    return (row: row, answer: null);
  }

  /// Clears the logged values of one set (weight, reps, RIR, velocity) the
  /// way deleting each field's text does. The set itself, its note and its
  /// video stay.
  Future<AurelianResult> _voiceClearSet(Wes2ExerciseRow row, int n) async {
    if (n > row.setCount) return _noSuchSet(row, n);
    final Wes2SetState set = row.sets.firstWhere(
        (Wes2SetState s) => s.setIndex == n - 1,
        orElse: () => Wes2SetState(setIndex: n - 1));
    final List<SetFieldEdit> edits = <SetFieldEdit>[
      if (set.weight.hasActual) const SetFieldEdit(Wes2FieldKey.weight, ''),
      if (set.reps.hasActual) const SetFieldEdit(Wes2FieldKey.reps, ''),
      if (set.rir.hasActual) const SetFieldEdit(Wes2FieldKey.rir, ''),
      if (set.velocity.hasActual) const SetFieldEdit(Wes2FieldKey.velocity, ''),
    ];
    if (edits.isEmpty) {
      await _revealVoiceTarget();
      return AurelianResult.ok('${row.name} · set $n is already empty');
    }
    await _applyVoiceFieldEdits(row.exerciseId, n - 1, edits);
    return AurelianResult.ok('${row.name} · set $n cleared');
  }

  Future<AurelianResult> _voiceRemoveSet(Wes2ExerciseRow row, int n) async {
    final Wes2ExerciseRow current = _controller.rows.firstWhere(
        (Wes2ExerciseRow r) => r.exerciseId == row.exerciseId,
        orElse: () => row);
    if (current.source == Wes2RowSource.bb3Planned) {
      return const AurelianResult.unavailable(
          'Removing sets from BB3 planned exercises isn\'t available yet');
    }
    if (n > current.setCount) return _noSuchSet(current, n);
    if (current.setCount <= 1) {
      return AurelianResult.invalid(
          'That\'s the only set — say "delete ${current.name}" to remove the exercise');
    }
    final Wes2SetState set = current.sets.firstWhere(
        (Wes2SetState s) => s.setIndex == n - 1,
        orElse: () => Wes2SetState(setIndex: n - 1));
    await _removeSetConfirmed(current, n - 1, set);
    await _revealVoiceTarget();
    return AurelianResult.ok('${current.name} · set $n removed');
  }

  // ── Voice add / replace: the Add Exercise picker's own catalogue ─────────

  Future<List<CatalogExercise>>? _voiceCatalogue;
  String? _voiceCatalogueUid;

  /// The list the Add Exercise picker shows (global + this athlete's custom
  /// exercises), loaded once per athlete while the workout is open.
  Future<List<CatalogExercise>> _catalogue() {
    final String uid = _controller.actingUid;
    if (_voiceCatalogue == null || _voiceCatalogueUid != uid) {
      _voiceCatalogueUid = uid;
      _voiceCatalogue = ExerciseCatalog.loadCombinedExercisesForUser(uid);
      // A failed load is retried next time rather than remembered.
      _voiceCatalogue!.catchError((Object _) {
        _voiceCatalogue = null;
        return <CatalogExercise>[];
      });
    }
    return _voiceCatalogue!;
  }

  Future<List<CatalogExercise>?> _catalogueOrNull() async {
    try {
      return await _catalogue().timeout(const Duration(seconds: 8));
    } catch (_) {
      _voiceCatalogue = null;
      return null;
    }
  }

  /// "add bench press, suspended high row and back squats": every name is
  /// resolved first; nothing is added unless all of them are clear.
  Future<AurelianResult> _voiceAddExercises(AurelianCommand command) async {
    final List<CatalogExercise>? all = await _catalogueOrNull();
    if (!mounted) return const AurelianResult.unavailable('The workout closed');
    if (all == null) {
      return const AurelianResult.failed('Could not load exercises');
    }
    final Set<String> inWorkout = _rowIds().toSet();
    final List<CatalogExercise> available =
        all.where((CatalogExercise e) => !inWorkout.contains(e.id)).toList();
    final SpokenList list = splitSpokenList<CatalogExercise>(
        command.phrase!, all, catalogueName);
    if (list.error != null) return AurelianResult.invalid(list.error!);

    final List<CatalogExercise> chosen = <CatalogExercise>[];
    for (final String spoken in list.names) {
      final NamedResolution<CatalogExercise> r = resolveNamed<CatalogExercise>(
        spoken,
        available,
        catalogueName,
        (CatalogExercise e) => catalogueVoiceLabel(e, all),
        choices: command.choices,
        allowFuzzy: true,
      );
      if (r.isAmbiguous) {
        return AurelianResult.ambiguous(
            'Which $spoken?',
            r.ask
                .take(kAurelianMaxCandidates)
                .map((CatalogExercise e) => catalogueVoiceLabel(e, all))
                .toList(),
            context: 'catalogue');
      }
      final CatalogExercise? e = r.chosen;
      if (e == null) return _notInCatalogue(spoken, all, inWorkout);
      if (!chosen.any((CatalogExercise c) => c.id == e.id)) chosen.add(e);
    }
    for (final CatalogExercise e in chosen) {
      if (!mounted) break;
      _voicePickerOpen = false;
      await _addExerciseFromPicker(
          (exerciseId: e.id, name: catalogueName(e), circuitIndex: 0));
    }
    if (mounted) unawaited(_revealVoiceTarget());
    return AurelianResult.ok('Added ${_spokenList(chosen.map(catalogueName))}');
  }

  /// "replace X with Y": Y is chosen from the same list the Replace picker
  /// offers (everything not already in the workout, apart from X itself).
  Future<AurelianResult> _voiceReplaceExercise(
      Wes2ExerciseRow row, AurelianCommand command) async {
    final List<CatalogExercise>? all = await _catalogueOrNull();
    if (!mounted) return const AurelianResult.unavailable('The workout closed');
    if (all == null) {
      return const AurelianResult.failed('Could not load exercises');
    }
    final Set<String> others = _rowIds()
        .where((String id) => id != row.exerciseId)
        .toSet();
    final List<CatalogExercise> available =
        all.where((CatalogExercise e) => !others.contains(e.id)).toList();
    final String spoken = command.replacement!;
    final NamedResolution<CatalogExercise> r = resolveNamed<CatalogExercise>(
      spoken,
      available,
      catalogueName,
      (CatalogExercise e) => catalogueVoiceLabel(e, all),
      choices: command.choices,
    );
    if (r.isAmbiguous) {
      return AurelianResult.ambiguous(
          'Which $spoken?',
          r.ask
              .take(kAurelianMaxCandidates)
              .map((CatalogExercise e) => catalogueVoiceLabel(e, all))
              .toList(),
          context: 'catalogue');
    }
    final CatalogExercise? e = r.chosen;
    if (e == null) return _notInCatalogue(spoken, all, others);
    if (e.id == row.exerciseId) {
      return AurelianResult.ok('${row.name} is already there');
    }
    final String newName = catalogueName(e);
    await _applyReplacement(row, e.id, newName,
        offerUndo: row.hasAnyExecutionValue);
    _voiceTarget.select(e.id);
    if (mounted) unawaited(_revealVoiceTarget());
    return AurelianResult.ok('Replaced ${row.name} with $newName');
  }

  AurelianResult _notInCatalogue(
      String spoken, List<CatalogExercise> all, Set<String> inWorkout) {
    final ExerciseMatch<CatalogExercise> already = matchExercise<CatalogExercise>(
        spoken,
        all.where((CatalogExercise e) => inWorkout.contains(e.id)),
        catalogueName);
    return already.isUnique
        ? AurelianResult.notFound(
            '${catalogueName(already.single)} is already in this workout')
        : AurelianResult.notFound('No exercise called "$spoken"');
  }

  static String _spokenList(Iterable<String> names) {
    final List<String> l = names.toList();
    if (l.length <= 1) return l.join();
    return '${l.sublist(0, l.length - 1).join(', ')} and ${l.last}';
  }

  /// "select X" on the workout itself: X becomes the voice target.
  Future<AurelianResult> _voiceSelectExercise(AurelianCommand command) async {
    final List<Wes2ExerciseRow> rows = _controller.rows.toList();
    final String spoken = command.name!;
    final String? choice = command.choice;
    Wes2ExerciseRow? picked;
    if (choice != null) {
      picked = resolveChoice<Wes2ExerciseRow>(spoken, choice, rows,
          (Wes2ExerciseRow r) => r.name, (Wes2ExerciseRow r) => r.name);
      if (picked == null) {
        return const AurelianResult.unavailable(
            'The workout changed — say it again');
      }
    } else {
      final ExerciseMatch<Wes2ExerciseRow> m =
          matchExercise<Wes2ExerciseRow>(spoken, rows, (Wes2ExerciseRow r) => r.name);
      if (m.isNone) {
        return AurelianResult.notFound(
            '"$spoken" isn\'t in this workout — say "add exercise" to add it');
      }
      if (m.isAmbiguous) {
        return AurelianResult.ambiguous(
            'Which one?',
            m.matches.map((Wes2ExerciseRow r) => r.name).toList(),
            context: 'wes2');
      }
      picked = m.single;
    }
    _voiceTarget.select(picked.exerciseId);
    await _revealVoiceTarget();
    return AurelianResult.ok('${picked.name} selected');
  }

  /// The ordinary typed-entry path, once per value: the model update the row's
  /// onFieldChanged makes (updateSetField, with the same cascade), then the save
  /// its focus loss makes (_onFieldUnfocused → local draft + durable outbox). A
  /// field still being typed in is left first, so its own text is saved before
  /// the voice value lands and can never overwrite it afterwards.
  Future<void> _applyVoiceSetEdits(String exerciseId, SetEntryPlan plan) =>
      _applyVoiceFieldEdits(exerciseId, plan.setIndex, plan.edits);

  /// See [_applyVoiceSetEdits]; an empty [SetFieldEdit.text] clears the field
  /// exactly as deleting its text does (null reaches the outbox).
  Future<void> _applyVoiceFieldEdits(
      String exerciseId, int setIndex, List<SetFieldEdit> edits) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(Duration.zero);
    await _awaitDurableWrites();
    if (!mounted) return;
    for (final SetFieldEdit edit in edits) {
      _controller.updateSetField(
        exerciseId: exerciseId,
        setIndex: setIndex,
        fieldKey: edit.fieldKey,
        rawText: edit.text,
      );
      _onFieldUnfocused(exerciseId, setIndex, edit.fieldKey, edit.text);
    }
    _voiceTarget.select(exerciseId);
    await _revealVoiceTarget();
  }

  /// Outlines the voice target and scrolls its card into view.
  Future<void> _revealVoiceTarget() async {
    if (!mounted) return;
    final String? id = _voiceTarget.resolve(_rowIds());
    if (!_voiceTargetShown) setState(() => _voiceTargetShown = true);
    if (id == null) return;
    await WidgetsBinding.instance.endOfFrame;
    await _ensureExerciseVisible(id);
  }

  /// Scrolls [exerciseId]'s card into view with its own layout (the existing
  /// card keys). The list builds cards lazily, so a card far away is reached by
  /// paging the list's own scroll position toward it until it is built.
  Future<void> _ensureExerciseVisible(String exerciseId) async {
    for (int attempt = 0; attempt < 30 && mounted; attempt++) {
      final BuildContext? target = _exerciseCardKeys[exerciseId]?.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(target,
            duration: const Duration(milliseconds: 250), alignment: 0.05);
        return;
      }
      final List<String> ids = _rowIds();
      final int want = ids.indexOf(exerciseId);
      if (want < 0) return;
      ScrollPosition? position;
      int? lowest;
      int? highest;
      for (final MapEntry<String, GlobalKey> e in _exerciseCardKeys.entries) {
        final BuildContext? c = e.value.currentContext;
        if (c == null || !c.mounted) continue;
        position ??= Scrollable.maybeOf(c)?.position;
        final int i = ids.indexOf(e.key);
        if (i < 0) continue;
        lowest = lowest == null || i < lowest ? i : lowest;
        highest = highest == null || i > highest ? i : highest;
      }
      if (position == null || lowest == null || highest == null) return;
      final double direction = want > highest ? 1 : (want < lowest ? -1 : 0);
      if (direction == 0) return;
      final double to = (position.pixels +
              direction * position.viewportDimension * 0.8)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (to == position.pixels) return;
      position.jumpTo(to);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  // ── Undo (Phase 15) ──────────────────────────────────────────────────────

  void _performUndo() {
    _controller.undo();
    _saveDraftNow();
    // Restores the SAME records the structural operation soft-deleted, so the
    // recovered set shows the footage it always had rather than a new one.
    // ignore: discarded_futures
    _videoUndoStructuralDelete();
    // Restore BB3 planned-day structure from the recovered row set.
    // ignore: discarded_futures
    _syncBb3PlannedDayFromCurrentRowsSilently();
  }

  void _showUndoSnackBar(String label) {
    if (!mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> controller =
        messenger.showSnackBar(
      SnackBar(
        content: Text(label),
        action: SnackBarAction(label: 'Undo', onPressed: _performUndo),
      ),
    );

    // When the bar closes WITHOUT Undo, the window has passed and the soft
    // deletion becomes final: the maintenance pass unlinks the video and poster
    // bytes and purges the row. Without this the record stayed soft-deleted
    // for ever and "Delete" only ever hid it.
    // ignore: discarded_futures
    controller.closed.then((SnackBarClosedReason reason) {
      if (reason == SnackBarClosedReason.action) return;
      _pendingVideoUndoIds = const <String>[];
      // ignore: discarded_futures
      _runSetVideoMaintenance();
    });
  }

  // ── Snackbar / confirm helpers (Phase 13) ─────────────────────────────────

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _showConfirmDialog({
    required String title,
    required String content,
  }) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<int?> _showCircuitPickerDialog(List<int> circuits) async {
    if (!mounted) return null;
    return showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Move to Circuit'),
        children: circuits
            .map((ci) => SimpleDialogOption(
                  onPressed: () => Navigator.of(ctx).pop(ci),
                  child: Text('Circuit ${ci + 1}'),
                ))
            .toList(),
      ),
    );
  }

  // ── Exercise settings dialog (Phase 19) ──────────────────────────────────

  Future<void> _showExerciseSettingsDialog(Wes2ExerciseRow row) async {
    final blockId = _controller.activeBlockId;
    final blockStart = _controller.blockStartDate;
    if (blockId == null || blockId.isEmpty || blockStart == null) {
      _showSnackBar('No active block — settings require a training block.');
      return;
    }
    if (_isBeforeBlockStart(_controller.selectedDate, blockStart)) {
      _showSnackBar('This date is before the active block start.');
      return;
    }
    final wd = _weekDayFromDate(blockStart, _controller.selectedDate);
    final blockEndDate = _controller.blockEndDate;
    int totalBlockWeeks;
    if (blockEndDate != null) {
      totalBlockWeeks = (blockEndDate.difference(blockStart).inDays ~/ 7) + 1;
    } else {
      totalBlockWeeks = wd.weekIndex + 52;
    }

    // Compute completed instance count for this exercise in the active block
    // up to and including the selected date. Used to display global rep target
    // instance in the settings cog, independent of periodisation model or frequency.
    final selectedDateOnly = DateTime(
      _controller.selectedDate.year,
      _controller.selectedDate.month,
      _controller.selectedDate.day,
    );
    final blockStartOnly = DateTime(
      blockStart.year,
      blockStart.month,
      blockStart.day,
    );
    final blockEndOnly = blockEndDate != null
        ? DateTime(blockEndDate.year, blockEndDate.month, blockEndDate.day)
        : null;

    // Robust date parser: handles String, DateTime, or Firestore Timestamp-like.
    DateTime? parseWorkoutDate(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      final dt = DateTime.tryParse(v.toString());
      if (dt != null) return dt;
      try {
        // ignore: avoid_dynamic_calls
        final d = (v as dynamic).toDate();
        if (d is DateTime) return d;
      } catch (_) {}
      return null;
    }

    int completedInstanceCount = 0;
    final countedDates = <String>{};

    for (final w in PeriodizationModelUtils.savedWorkoutsList) {
      final dt = parseWorkoutDate(w['date']);
      if (dt == null) continue;
      final dayOnly = DateTime(dt.year, dt.month, dt.day);
      if (dayOnly.isBefore(blockStartOnly)) continue;
      if (dayOnly.isAfter(selectedDateOnly)) continue;
      if (blockEndOnly != null && dayOnly.isAfter(blockEndOnly)) continue;

      final exs = w['exercises'];
      if (exs is! List) continue;

      bool matched = false;
      for (final ex in exs) {
        final exId = (ex['exerciseId'] ?? ex['id'] ?? '').toString();
        if (exId != row.exerciseId) continue;
        final setsRaw = ex['sets'];
        final sets = setsRaw is List ? setsRaw : const [];
        final hasWeightAndReps = sets.any((s) {
          final sw = (s['weight']?.toString() ?? '').trim();
          final sr = (s['reps']?.toString() ?? '').trim();
          return sw.isNotEmpty && sr.isNotEmpty;
        });
        if (hasWeightAndReps) {
          matched = true;
          break;
        }
      }

      if (matched) {
        final dateKey =
            '${dayOnly.year}-${dayOnly.month.toString().padLeft(2, '0')}-${dayOnly.day.toString().padLeft(2, '0')}';
        countedDates.add(dateKey);
        completedInstanceCount++;
      }
    }

    // Same-day check: include in-progress actuals for the selected date when
    // savedWorkoutsList has not yet captured them.
    final todayKey =
        '${selectedDateOnly.year}-${selectedDateOnly.month.toString().padLeft(2, '0')}-${selectedDateOnly.day.toString().padLeft(2, '0')}';
    if (!countedDates.contains(todayKey)) {
      bool hasCompletedToday = false;
      for (final r in _controller.rows) {
        if (r.exerciseId != row.exerciseId) continue;
        if (r.sets.any(
          (s) => s.weight.actualValue != null && s.reps.actualValue != null,
        )) {
          hasCompletedToday = true;
          break;
        }
      }
      if (hasCompletedToday) completedInstanceCount++;
    }

    // Compute history-aware active instance for DUP models so settings cog
    // shows the same instance as ProgressionEngine.
    int? resolvedActiveInstance;
    final cogExSettings =
        _cachedExerciseSettings[row.exerciseId] as Map<String, dynamic>?;
    final cogModel = (cogExSettings?['periodizationModel'] as String?) ?? '';
    if (cogModel == 'DUP, By Exposure' || cogModel == 'DUP, By Week') {
      final cogWeek1 = (cogExSettings?['repTargets'] as Map?)?['week1'];
      final cogSorted = (cogWeek1 is Map<String, dynamic>)
          ? (cogWeek1.entries
              .where((e) => e.key.startsWith('instance'))
              .toList()
            ..sort((a, b) => a.key.compareTo(b.key)))
          : <MapEntry<String, dynamic>>[];
      int cogPlannedBefore = 0;
      for (final r in _controller.rows) {
        if (r == row) break;
        if (r.exerciseId == row.exerciseId) cogPlannedBefore++;
      }
      final cogRes = ProgressionEngine.resolveDupActiveInstance(
        exerciseId: row.exerciseId,
        exerciseName: row.name,
        blockStartDate: blockStart,
        selectedDate: _controller.selectedDate,
        weekIndex: wd.weekIndex,
        sorted: cogSorted,
        plannedCountBefore: cogPlannedBefore,
        byWeek: cogModel == 'DUP, By Week',
      );
      resolvedActiveInstance = cogRes?.instanceNumber;
    }

    if (!_cogCueDismissed && mounted) {
      setState(() => _cogCueDismissed = true);
      final actorUid = _authUidOrNull();
      if (actorUid != null) {
        unawaited(OnboardingCueService.instance
            .markCueComplete(OnboardingCueId.wes2SettingsCog, actorUid));
      }
    }
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => Wes2ExerciseSettingsDialog(
        uid: _controller.actingUid,
        blockId: blockId,
        exerciseId: row.exerciseId,
        exerciseName: row.name,
        weekIndex: wd.weekIndex,
        dayIndex: wd.dayIndex,
        totalBlockWeeks: totalBlockWeeks,
        planService: _planService,
        resolvedActiveInstanceOverride: resolvedActiveInstance,
        completedInstanceCount: completedInstanceCount,
        // Active RIR session = block-relative dayIndex (days % 7) + 1, matching
        // the hint engine's sessionIndex. Independent of the rep-target instance.
        activeRirSessionIndex: wd.dayIndex + 1,
      ),
    );
    if (saved == true && mounted) {
      // Invalidated BEFORE awaiting anything: a settings response already in
      // flight belongs to the old settings and must not win.
      _hintRunner.invalidateSettings();
      await _loadAndApplyHints();
    }
  }

  bool _shouldShowVelocityField(Wes2ExerciseRow row) {
    final hasExistingVelocity =
        row.sets.any((s) => s.velocity.hasActual || s.velocity.hasHint);
    if (hasExistingVelocity) return true;
    final settings =
        _cachedExerciseSettings[row.exerciseId] as Map<String, dynamic>?;
    final explicit = settings?['showVelocityField'];
    if (explicit is bool) return explicit;
    return _defaultVelocityExerciseIds.contains(row.exerciseId);
  }

  Future<void> _showExerciseNoteDialog(Wes2ExerciseRow row) async {
    final currentRow = _controller.rows.firstWhere(
      (r) => r.exerciseId == row.exerciseId,
      orElse: () => row,
    );
    final planNote = currentRow.exercisePlanNote?.trim();
    final hasPlanNote = planNote != null && planNote.isNotEmpty;
    final noteCtrl = TextEditingController(
      text: currentRow.exerciseExecutionNote?.trim() ?? '',
    );
    try {
      final saved = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(currentRow.name, style: const TextStyle(fontSize: 16)),
          contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasPlanNote) ...[
                  const Text('Plan note',
                      style: TextStyle(fontSize: 11, color: Colors.white54)),
                  const SizedBox(height: 4),
                  Text(planNote, style: const TextStyle(fontSize: 13)),
                  const Divider(height: 20),
                ],
                const Text('Execution note',
                    style: TextStyle(fontSize: 11, color: Colors.white54)),
                const SizedBox(height: 4),
                TextField(
                  controller: noteCtrl,
                  autofocus: true,
                  maxLines: 4,
                  minLines: 2,
                  decoration: const InputDecoration(
                    hintText: 'How did this exercise feel?',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, noteCtrl.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (!mounted || saved == null) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final trimmed = saved.trim();
      _controller.updateExerciseExecutionNote(
        exerciseId: currentRow.exerciseId,
        rawText: trimmed,
      );
      _saveDraftNow();
      // ignore: discarded_futures
      _saveExerciseExecutionNoteSilently(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
        exerciseId: currentRow.exerciseId,
        note: trimmed.isEmpty ? null : trimmed,
      );
    } finally {
      noteCtrl.dispose();
    }
  }

  void _navigateToExerciseDetails(Wes2ExerciseRow row) {
    if (_controller.actingUid.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExerciseDetailsScreen(
          exerciseId: row.exerciseId,
          exerciseName: row.name,
        ),
      ),
    );
  }

  void _navigateToTopSets(Wes2ExerciseRow row) {
    if (_controller.actingUid.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TopSetsScreen(
          exerciseName: row.name,
          exerciseId: row.exerciseId,
          exerciseType: row.exerciseType,
          athleteUid: _controller.actingUid,
          recentWorkouts: const [],
          onWorkoutSelected: (date) =>
              _openWorkoutFromTopSets(date, row.exerciseId),
        ),
      ),
    );
  }

  /// Returns from Top Sets to this existing WES2 session on the workout day.
  /// Reusing the session preserves the selected athlete/coach context and
  /// avoids stacking a second logger above the first one.
  Future<void> _openWorkoutFromTopSets(
    DateTime date,
    String exerciseId,
  ) async {
    if (!mounted || _openingTopSetWorkout) return;
    _openingTopSetWorkout = true;
    final durationWasRunning = _workoutDurationSegmentStartedAt != null;
    bool navigationCommitted = false;
    _pauseWorkoutDurationSegment();
    try {
      FocusManager.instance.primaryFocus?.unfocus();
      // Focus loss is delivered in a microtask. Yield once so the field's
      // existing save registers with the durability barrier before we read it.
      await Future<void>.delayed(Duration.zero);
      await _awaitDurableWrites();
      await _saveDraft();
      if (!mounted) return;

      final navigator = Navigator.of(context);
      if (!navigator.canPop()) {
        if (durationWasRunning) _startWorkoutDurationSegment();
        return;
      }

      navigator.pop();
      _workoutDurationMilliseconds = 0;
      _workoutDurationSegmentStartedAt = null;
      _controller.changeDate(date);
      navigationCommitted = true;
      await _loadDay();
      if (!mounted) return;

      if (!wes2TopSetTargetIsLoaded(
        selectedDate: _controller.selectedDate,
        targetDate: date,
        exerciseId: exerciseId,
        rows: _controller.rows,
        serverLoadConfirmed:
            _confirmedServerLoadEpoch == _controller.loadEpoch,
      )) {
        _showSnackBar('That workout is no longer available.');
        return;
      }

      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final cardContext = _exerciseCardKeys[exerciseId]?.currentContext;
      if (cardContext != null) {
        await Scrollable.ensureVisible(
          cardContext,
          duration: const Duration(milliseconds: 250),
          alignment: 0.1,
        );
      }
    } catch (e, st) {
      debugPrint('[WES2] Top Sets navigation failed: $e\n$st');
      if (mounted) {
        if (durationWasRunning && !navigationCommitted) {
          _startWorkoutDurationSegment();
        }
        _showSnackBar('Could not open that workout. Please try again.');
      }
    } finally {
      _openingTopSetWorkout = false;
    }
  }

  String? _buildCombinedPlanNote(Wes2ExerciseRow row) {
    final lines = <String>[];
    if (row.exercisePlanNote != null &&
        row.exercisePlanNote!.trim().isNotEmpty) {
      lines.add('Exercise note: ${row.exercisePlanNote!.trim()}');
    }
    for (int i = 0; i < row.sets.length; i++) {
      final note = row.sets[i].planNote?.trim();
      if (note != null && note.isNotEmpty) {
        lines.add('Set ${i + 1}: $note');
      }
    }
    return lines.isEmpty ? null : lines.join('\n\n');
  }

  Future<void> _onOpenExercisePlanNoteDialog(
      Wes2ExerciseRow row, String combinedNote) async {
    _controller.markExercisePlanNoteRead(row.exerciseId);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          row.name,
          style: const TextStyle(fontSize: 16),
        ),
        content: Text(combinedNote),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _showTemplatePicker() async {
    if (_controller.actingUid.isEmpty) return;
    if (_isLoadingTemplate) return;

    // Tutorial: capture whether we're at the load-template cue step.
    final wasAtLoadStep = _tutorialStep == 1;
    // Advance to step 2 before opening picker so the first-template highlight renders.
    if (wasAtLoadStep && mounted) setState(() => _tutorialStep = 2);

    final templateId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => Wes2TemplatePicker(
        uid: _controller.actingUid,
        activeBlockId: _controller.activeBlockId,
        highlightFirstTemplate: wasAtLoadStep,
      ),
    );

    if (!mounted) return;
    if (templateId == null) {
      // Picker dismissed without selection — restore Load Template cue.
      if (wasAtLoadStep) setState(() => _tutorialStep = 1);
      return;
    }

    if (_isLoadingTemplate) return;
    setState(() => _isLoadingTemplate = true);
    try {
      // Confirm before replacing if the current workout has user-entered data.
      if (workoutHasUserEnteredData(_controller.rows)) {
        final confirmed = await _showReplaceWorkoutDialog();
        if (!mounted || !confirmed) return;
      }

      await _onLoadTemplate(templateId);

      // Advance to weight tutorial once template is successfully loaded.
      if (mounted && wasAtLoadStep && _tutorialStep == 2) {
        setState(() => _tutorialStep = 3);
      }
    } finally {
      if (mounted) setState(() => _isLoadingTemplate = false);
    }
  }

  Future<bool> _showReplaceWorkoutDialog() async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace current workout?'),
        content: const Text(
          'This workout contains entered data. Loading this template will'
          ' replace the current exercises and remove that data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Replace workout'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ── Delete Day (Phase 18b) ────────────────────────────────────────────────

  Future<void> _onDeleteAllExercisesForDay() async {
    if (_controller.rows.isEmpty) {
      _showSnackBar('No exercises to delete.');
      return;
    }
    final confirmed = await _showConfirmDialog(
      title: 'Delete Day',
      content: 'Delete all exercises for this day, are you sure?',
    );
    if (!confirmed || !mounted) return;

    final hadBb3Rows = _bb3PlannedExerciseIds.isNotEmpty ||
        _controller.rows.any((r) =>
            r.source == Wes2RowSource.bb3Planned ||
            _bb3PlannedExerciseIds.contains(r.exerciseId));

    _controller.deleteAllExercises();
    _saveDraftNow();
    // Nothing survives, so every recording on the day is now an orphan.
    // ignore: discarded_futures
    _videoSoftDeleteOrphans();
    _showUndoSnackBar('All exercises deleted');

    // ignore: discarded_futures
    _deleteAllExercisesForDaySilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
    );

    if (hadBb3Rows) {
      final blockId = _controller.activeBlockId;
      final blockStart = _controller.blockStartDate;
      if (blockId != null && blockId.isNotEmpty && blockStart != null) {
        final wd = _weekDayFromDate(blockStart, _controller.selectedDate);
        // ignore: discarded_futures
        _clearBb3PlannedDaySilently(
          uid: _controller.actingUid,
          blockId: blockId,
          weekIndex: wd.weekIndex,
          dayIndex: wd.dayIndex,
        );
      }
    }
  }

  Future<void> _deleteAllExercisesForDaySilently({
    required String uid,
    required DateTime date,
  }) async {
    await _submitMutation(Wes2Mutation.deleteAllForDay(
      actorUid: _actorUidForMutations,
      athleteUid: uid,
      date: date,
      localSeq: ++_localMutationSeq,
    ));
  }

  // ── Structural exercise actions (Phase 13) ────────────────────────────────

  Future<void> _onDeleteExercise(Wes2ExerciseRow row) async {
    final hadActuals = row.hasAnyExecutionValue;
    // Capture before the async confirm gap. A row that reloaded as
    // completedServer (actual values saved) still needs BB3 sync if it was
    // originally BB3-planned on this date.
    final wasBb3 = row.source == Wes2RowSource.bb3Planned ||
        _bb3PlannedExerciseIds.contains(row.exerciseId);
    final confirmed = await _showConfirmDialog(
      title: 'Delete Exercise',
      content: 'Remove "${row.name}" from today\'s workout?',
    );
    if (!confirmed) return;
    await _deleteExerciseConfirmed(row,
        offerUndo: hadActuals, wasBb3: wasBb3);
  }

  /// The deletion itself, once confirmed (by the dialog, or by an explicit
  /// voice command naming the exercise). [wasBb3] must be captured before any
  /// async gap (see [_onDeleteExercise]).
  Future<void> _deleteExerciseConfirmed(Wes2ExerciseRow row,
      {required bool offerUndo, required bool wasBb3}) async {
    // Every recording on this row, identified before the row goes.
    await _videoSoftDeleteExercise(row.exerciseId);
    _controller.deleteExercise(row.exerciseId);
    _saveDraftNow();
    await _refreshSetVideoState();
    if (offerUndo) _showUndoSnackBar('Exercise deleted');
    // ignore: discarded_futures
    _deleteExerciseSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      exerciseId: row.exerciseId,
    );
    if (wasBb3) {
      // ignore: discarded_futures
      _syncBb3PlannedDayFromCurrentRowsSilently();
    }
  }

  Future<void> _onReplaceExercise(Wes2ExerciseRow row) async {
    final excludedIds = _controller.rows
        .map((r) => r.exerciseId)
        .where((id) => id != row.exerciseId)
        .toSet();
    final circuits =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final result = await _openExercisePicker(
      availableCircuits: circuits,
      initialCircuitIndex: row.circuitIndex,
      excludedIds: excludedIds,
      titleOverride: 'Replace "${row.name}"',
    );
    if (result == null) return;
    await _applyReplacement(row, result.exerciseId, result.name,
        offerUndo: row.hasAnyExecutionValue);
  }

  /// Swaps [row] for the chosen exercise (from the Replace picker, or a voice
  /// "replace X with Y" resolved against the same catalogue).
  Future<void> _applyReplacement(
      Wes2ExerciseRow row, String newExerciseId, String newName,
      {required bool offerUndo}) async {
    // The old exerciseId is about to vanish from this day. Its footage is
    // soft-deleted here rather than left pointing at a row the user can no
    // longer open.
    if (newExerciseId != row.exerciseId) {
      await _videoSoftDeleteExercise(row.exerciseId);
    }
    _controller.replaceExercise(
      oldExerciseId: row.exerciseId,
      newExerciseId: newExerciseId,
      newName: newName,
    );
    _saveDraftNow();
    await _refreshSetVideoState();
    // ignore: discarded_futures
    _loadAndApplyHints();
    if (offerUndo) _showUndoSnackBar('Exercise replaced');
    // ignore: discarded_futures
    _replaceExerciseSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      oldExerciseId: row.exerciseId,
      newExerciseId: newExerciseId,
      newName: newName,
    );
    if (row.source == Wes2RowSource.bb3Planned) {
      // ignore: discarded_futures
      _syncBb3PlannedDayFromCurrentRowsSilently();
    }
  }

  Future<void> _onMoveExerciseToCircuit(Wes2ExerciseRow row) async {
    final circuits =
        _controller.rows.map((r) => r.circuitIndex).toSet().toList()..sort();
    final available = circuits.where((ci) => ci != row.circuitIndex).toList();
    if (available.isEmpty) {
      _showSnackBar('Only one circuit — add another circuit first.');
      return;
    }
    final targetCi = await _showCircuitPickerDialog(available);
    if (targetCi == null) return;
    _moveExerciseToCircuitConfirmed(row, targetCi);
  }

  /// Moves [row] to circuit [targetCi] (0-based), once chosen.
  void _moveExerciseToCircuitConfirmed(Wes2ExerciseRow row, int targetCi) {
    _controller.moveExerciseToCircuit(row.exerciseId, targetCi);
    _saveDraftNow();
    _showUndoSnackBar('Exercise moved to Circuit ${targetCi + 1}');
    // ignore: discarded_futures
    _moveExerciseToCircuitSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      exerciseId: row.exerciseId,
      targetCircuitIndex: targetCi,
    );
    if (row.source == Wes2RowSource.bb3Planned) {
      // ignore: discarded_futures
      _syncBb3PlannedDayFromCurrentRowsSilently();
    }
  }

  // ── Silent Firestore wrappers (Phase 13) ──────────────────────────────────

  Future<void> _deleteExerciseSilently({
    required String uid,
    required DateTime date,
    required String exerciseId,
  }) async {
    await _submitMutation(Wes2Mutation.deleteExercise(
      actorUid: _actorUidForMutations,
      athleteUid: uid,
      date: date,
      exerciseId: exerciseId,
    ));
  }

  Future<void> _replaceExerciseSilently({
    required String uid,
    required DateTime date,
    required String oldExerciseId,
    required String newExerciseId,
    required String newName,
  }) async {
    await _submitMutation(Wes2Mutation.replaceExercise(
      actorUid: _actorUidForMutations,
      athleteUid: uid,
      date: date,
      oldExerciseId: oldExerciseId,
      newExerciseId: newExerciseId,
      newName: newName,
    ));
  }

  Future<void> _moveExerciseToCircuitSilently({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int targetCircuitIndex,
  }) async {
    await _submitMutation(Wes2Mutation.moveCircuit(
      actorUid: _actorUidForMutations,
      athleteUid: uid,
      date: date,
      exerciseId: exerciseId,
      targetCircuitIndex: targetCircuitIndex,
    ));
  }

  // ── Remove Set (Phase 14) ─────────────────────────────────────────────────

  Future<void> _onRemoveSet(Wes2ExerciseRow row, int setIndex) async {
    // Always re-fetch by exerciseId so we have the latest in-memory state.
    final currentRow = _controller.rows.firstWhere(
      (r) => r.exerciseId == row.exerciseId,
      orElse: () => row,
    );

    if (currentRow.source == Wes2RowSource.bb3Planned) {
      _showSnackBar(
          'Removing sets from BB3 planned exercises will be added in a later phase.');
      return;
    }

    // One-set removal routes to exercise deletion.
    if (currentRow.setCount <= 1) {
      final confirmed = await _showConfirmDialog(
        title: 'Delete Exercise',
        content:
            'This is the only set. Removing it will delete "${currentRow.name}". Continue?',
      );
      if (!confirmed || !mounted) return;
      await _videoSoftDeleteExercise(currentRow.exerciseId);
      _controller.deleteExercise(currentRow.exerciseId);
      _saveDraftNow();
      await _refreshSetVideoState();
      if (currentRow.hasAnyExecutionValue)
        _showUndoSnackBar('Exercise deleted');
      // ignore: discarded_futures
      _deleteExerciseSilently(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
        exerciseId: currentRow.exerciseId,
      );
      return;
    }

    // Find the target set in current in-memory state.
    final targetSet = currentRow.sets.firstWhere(
      (s) => s.setIndex == setIndex,
      orElse: () => Wes2SetState(setIndex: setIndex),
    );

    // Confirm only when the set carries actual logged values.
    if (targetSet.hasAnyActual) {
      final confirmed = await _showConfirmDialog(
        title: 'Remove Set',
        content: 'Removing this set will remove its logged values. Continue?',
      );
      if (!confirmed || !mounted) return;
    }
    await _removeSetConfirmed(currentRow, setIndex, targetSet);
  }

  /// Removes one set of a multi-set, non-BB3 row, once confirmed. Callers
  /// guard those two cases (see [_onRemoveSet]).
  Future<void> _removeSetConfirmed(
      Wes2ExerciseRow currentRow, int setIndex, Wes2SetState targetSet) async {
    // BEFORE the controller renumbers: once compaction runs, the removed set's
    // identity is unreachable and its footage would be stranded.
    await _videoSoftDeleteSets(
        currentRow.exerciseId, _setIdsFor(currentRow, onlySetIndex: setIndex));

    // Captured BEFORE the controller compacts: this is the stored count the
    // queued removal expects to find, and the guard that makes a replay after
    // a crash a no-op rather than a second, wrong deletion.
    final int setCountBeforeRemoval = currentRow.setCount;

    _controller.removeSet(currentRow.exerciseId, setIndex);
    _saveDraftNow();
    await _refreshSetVideoState();
    final hasUserValues = targetSet.hasAnyActual ||
        (targetSet.executionNote?.trim().isNotEmpty ?? false);
    if (hasUserValues) _showUndoSnackBar('Set removed');
    // ignore: discarded_futures
    _removeSetSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      exerciseId: currentRow.exerciseId,
      setIndex: setIndex,
      expectedSetCountBefore: setCountBeforeRemoval,
    );
  }

  /// Queues one set removal.
  ///
  /// [expectedSetCountBefore] travels with the mutation so a replay after a
  /// crash is a no-op rather than deleting whichever set moved into the gap.
  Future<void> _removeSetSilently({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required int expectedSetCountBefore,
  }) async {
    await _submitMutation(Wes2Mutation.removeSet(
      actorUid: _actorUidForMutations,
      athleteUid: uid,
      date: date,
      exerciseId: exerciseId,
      setIndex: setIndex,
      expectedSetCountBefore: expectedSetCountBefore,
      localSeq: ++_localMutationSeq,
    ));
  }

  // ── Set notes (Phase 16) ──────────────────────────────────────────────────

  // ── Set video ─────────────────────────────────────────────────────────────

  /// Opens the set-video flow.
  ///
  /// Identity is minted and PERSISTED before the camera can open. Previously
  /// this only mutated the in-memory controller, so an app termination between
  /// recording and the next ordinary save left a clip filed under an id that
  /// existed nowhere on disk — permanently unassociable — and the server could
  /// never produce a matching record fingerprint for it.
  ///
  /// Order here is the fix, and each step guards the next:
  ///   1. re-read the row/set from the controller (never a stale capture);
  ///   2. reuse an existing id, or mint one;
  ///   3. write it into the local draft and WAIT for that;
  ///   4. write it additively to Firestore, best-effort;
  ///   5. only then open the camera, with the REFRESHED row.
  ///
  /// If step 3 fails the flow stops: recording a clip that cannot be
  /// re-associated after a restart is worse than not recording it.
  Future<void> _onSetVideoTap(Wes2ExerciseRow row, int setIndex) async {
    final String ownerUid = _controller.actingUid;
    if (ownerUid.isEmpty) return;

    // 1 + 2. Re-read from the controller, then reuse or mint.
    final String? setId = _controller.ensureSetId(row.exerciseId, setIndex);
    if (setId == null) return;

    // 3. Durable locally BEFORE the camera opens. Awaited deliberately: this is
    //    the step that makes the association survive a termination.
    try {
      await _localStore.saveDraft(
        uid: ownerUid,
        date: _controller.selectedDate,
        rows: _controller.rows.toList(),
        workoutDurationMs: _currentWorkoutDurationMs(),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(SetVideoCopy.identityNotSaved)),
      );
      return;
    }

    // 4. Additive server write. Allowed to fail: the clip stays device-only
    //    until a later save carries the id up, and the publication gate will
    //    not confirm anything the server has not seen.
    unawaited(_saveSetIdToServer(ownerUid, row.exerciseId, setIndex, setId));

    // 5. The REFRESHED row, so the coordinator sees the minted identity.
    final Wes2ExerciseRow current = _controller.rows.firstWhere(
      (Wes2ExerciseRow r) => r.exerciseId == row.exerciseId,
      orElse: () => row,
    );

    final SetVideoCoordinator coordinator;
    try {
      coordinator = await SetVideoCoordinator.instance();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(SetVideoCopy.storeUnavailable)),
      );
      return;
    }
    if (!mounted) return;

    final bool changed = await coordinator.handleTap(
      context,
      ownerUid: ownerUid,
      date: _controller.selectedDate,
      row: current,
      setIndex: setIndex,
      setId: setId,
    );
    if (changed) {
      await _refreshSetVideoState();
      // A newly saved clip is a publication candidate straight away, so the
      // pass runs here rather than waiting for the next app start.
      unawaited(_runSetVideoMaintenance());
    }
  }

  /// Queues the stable id, which is written additively and never overwrites
  /// an identity that already exists — so a replay leaves an attached proof
  /// video pointing at exactly the same performance.
  Future<void> _saveSetIdToServer(
    String ownerUid,
    String exerciseId,
    int setIndex,
    String setId,
  ) async {
    await _submitMutation(Wes2Mutation.stableSetId(
      actorUid: _actorUidForMutations,
      athleteUid: ownerUid,
      date: _controller.selectedDate,
      exerciseId: exerciseId,
      setIndex: setIndex,
      setId: setId,
    ));
  }

  // ── Structural operations: keeping footage with its set ───────────────────

  /// Record ids soft-deleted by the most recent structural operation, so the
  /// Undo that follows restores exactly those and creates nothing new.
  List<String> _pendingVideoUndoIds = const <String>[];

  /// Soft-deletes footage for [setIds] on [exerciseId]. Call BEFORE mutating
  /// the controller: after a removal the surviving sets have been renumbered
  /// and the removed set's identity is no longer reachable.
  Future<void> _videoSoftDeleteSets(
      String exerciseId, Iterable<String> setIds) async {
    final List<String> ids = setIds.toList();
    if (ids.isEmpty || _controller.actingUid.isEmpty) return;
    try {
      final SetVideoCoordinator c = await SetVideoCoordinator.instance();
      _pendingVideoUndoIds = await c.softDeleteForSets(
        ownerUid: _controller.actingUid,
        date: _controller.selectedDate,
        exerciseId: exerciseId,
        setIds: ids,
      );
    } catch (_) {
      // Set video unavailable. Structural editing must not be blocked by it.
    }
  }

  /// Soft-deletes every recording for one exercise.
  Future<void> _videoSoftDeleteExercise(String exerciseId) async {
    if (_controller.actingUid.isEmpty) return;
    try {
      final SetVideoCoordinator c = await SetVideoCoordinator.instance();
      _pendingVideoUndoIds = await c.softDeleteForExercise(
        ownerUid: _controller.actingUid,
        date: _controller.selectedDate,
        exerciseId: exerciseId,
      );
    } catch (_) {
      // As above.
    }
  }

  /// Soft-deletes footage whose exercise no longer exists on this day. Used
  /// after a wholesale rebuild (template or day replacement).
  Future<void> _videoSoftDeleteOrphans() async {
    if (_controller.actingUid.isEmpty) return;
    try {
      final SetVideoCoordinator c = await SetVideoCoordinator.instance();
      await c.softDeleteOrphans(
        ownerUid: _controller.actingUid,
        date: _controller.selectedDate,
        survivingExerciseIds:
            _controller.rows.map((Wes2ExerciseRow r) => r.exerciseId).toSet(),
      );
      await _refreshSetVideoState();
    } catch (_) {
      // As above.
    }
  }

  /// Restores the footage the last structural operation soft-deleted.
  Future<void> _videoUndoStructuralDelete() async {
    final List<String> ids = _pendingVideoUndoIds;
    _pendingVideoUndoIds = const <String>[];
    if (ids.isEmpty) return;
    try {
      final SetVideoCoordinator c = await SetVideoCoordinator.instance();
      await c.undoStructuralDelete(ids);
      await _refreshSetVideoState();
    } catch (_) {
      // As above.
    }
  }

  /// The stable ids on one set, if any.
  List<String> _setIdsFor(Wes2ExerciseRow row, {int? onlySetIndex}) =>
      row.sets
          .where((Wes2SetState s) =>
              onlySetIndex == null || s.setIndex == onlySetIndex)
          .map((Wes2SetState s) => s.setId)
          .whereType<String>()
          .toList();

  /// Reconciles after a confirmed set save, but only when this day actually
  /// has footage — otherwise every keystroke-driven save on every workout
  /// would wake a pass that has nothing to consider.
  Future<void> _maybeReconcileAfterSetSave() async {
    if (_setsWithVideo.isEmpty) return;
    await _runSetVideoMaintenance();
  }

  /// Runs one set-video maintenance pass for the acting user.
  Future<void> _runSetVideoMaintenance() async {
    if (_controller.actingUid.isEmpty) return;
    try {
      final ProfileServices services =
          await ProfileServices.ensureInitialised();
      await services.runSetVideoMaintenance(
          actingUid: _controller.actingUid);
    } catch (_) {
      // Background work; never surfaced as a failure of the user's action.
    }
  }

  /// Re-reads which sets currently have footage. Cheap, local, and offline.
  Future<void> _refreshSetVideoState() async {
    final String ownerUid = _controller.actingUid;
    if (ownerUid.isEmpty) return;
    try {
      final SetVideoCoordinator c = await SetVideoCoordinator.instance();
      final Map<String, Set<int>> next = await c.attachedByExercise(
        ownerUid: ownerUid,
        date: _controller.selectedDate,
        rows: _controller.rows,
      );
      if (mounted) setState(() => _setsWithVideo = next);
    } catch (_) {
      // Set footage is an enhancement. Failing to read it must never stop the
      // user logging their workout.
    }
  }

  /// [focusNote]: put the cursor in the note even when a plan note is shown
  /// (voice: the next thing said is "type …").
  Future<void> _onOpenSetNoteDialog(Wes2ExerciseRow row, int setIndex,
      {bool focusNote = false}) async {
    // Always re-fetch from controller so we have the latest in-memory state.
    final currentRow = _controller.rows.firstWhere(
      (r) => r.exerciseId == row.exerciseId,
      orElse: () => row,
    );
    final set = currentRow.sets.firstWhere(
      (s) => s.setIndex == setIndex,
      orElse: () => Wes2SetState(setIndex: setIndex),
    );

    if (set.planNote != null) {
      _controller.markPlanNoteRead(currentRow.exerciseId, setIndex);
    }

    final noteCtrl = TextEditingController(text: set.executionNote ?? '');
    try {
      final saved = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text(
            '${currentRow.name} — Set ${setIndex + 1} Notes',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (set.planNote != null) ...[
                const Text(
                  'Plan note',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
                const SizedBox(height: 4),
                Text(
                  set.planNote!,
                  style: const TextStyle(fontSize: 13),
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                ),
                const Divider(height: 20),
              ],
              const Text(
                'Execution note',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: noteCtrl,
                maxLines: 4,
                minLines: 2,
                autofocus: focusNote || set.planNote == null,
                decoration: const InputDecoration(
                  hintText: 'Add a note for this set…',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(noteCtrl.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );

      if (saved == null || !mounted) return;

      // Yield one frame so the dialog route fully deactivates and removes its
      // Overlay entry before notifyListeners() fires a Provider rebuild.
      // Calling notifyListeners() while the Overlay still has dependents
      // triggers the '_dependents.isEmpty' assertion in debug mode.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      final trimmed = saved.trim();
      _controller.updateExecutionNote(
        exerciseId: currentRow.exerciseId,
        setIndex: setIndex,
        rawText: trimmed,
      );
      _saveDraftNow();
      // ignore: discarded_futures
      _saveExecutionNoteSilently(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
        exerciseId: currentRow.exerciseId,
        setIndex: setIndex,
        note: trimmed.isEmpty ? null : trimmed,
      );
    } finally {
      noteCtrl.dispose();
    }
  }

  Future<void> _saveExecutionNoteSilently({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String? note,
  }) async {
    await _submitMutation(Wes2Mutation.setNote(
      actorUid: _actorUidForMutations,
      athleteUid: uid,
      date: date,
      exerciseId: exerciseId,
      setIndex: setIndex,
      note: note,
    ));
  }

  Future<void> _saveExerciseExecutionNoteSilently({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required String? note,
  }) async {
    await _submitMutation(Wes2Mutation.exerciseNote(
      actorUid: _actorUidForMutations,
      athleteUid: uid,
      date: date,
      exerciseId: exerciseId,
      note: note,
    ));
  }

  // ── Floating timer widget (Phase 17) ──────────────────────────────────────

  Widget _buildFloatingTimer() {
    return Card(
      elevation: 8,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatDuration(_elapsedMilliseconds,
                      includeSplitSeconds: true),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 24, height: 24),
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'Close timer',
                  onPressed: _closeTimer,
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: _timerRunning ? _stopTimer : _startTimer,
                  style: TextButton.styleFrom(
                    foregroundColor:
                        _timerRunning ? Colors.redAccent : Colors.greenAccent,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(
                    _timerRunning ? 'Stop' : 'Start',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 2),
                TextButton(
                  onPressed: _timerRunning ? null : _resetTimer,
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Reset', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Template load (Phase 18) ──────────────────────────────────────────────

  /// Returns true once the template has replaced the day (false when it could
  /// not be loaded; the snackbar has said why).
  Future<bool> _onLoadTemplate(String templateId) async {
    List<Wes2ExerciseRow> templateRows;
    try {
      templateRows = await _templateService.loadTemplate(
        uid: _controller.actingUid,
        templateId: templateId,
      );
    } catch (_) {
      _showSnackBar('Failed to load template.');
      return false;
    }
    if (templateRows.isEmpty) {
      _showSnackBar('Template has no loadable exercises.');
      return false;
    }
    if (!mounted) return false;

    // Deduplicate and normalize template rows before loading.
    final hardened = _hardened(templateRows);
    final reindexed = List.generate(
      hardened.length,
      (i) => hardened[i].copyWith(orderIndex: i),
    );

    final hadAnyRows = _controller.rows.isNotEmpty;
    final hadBb3Rows =
        _controller.rows.any((r) => r.source == Wes2RowSource.bb3Planned);

    _controller.replaceWithTemplateRows(reindexed);
    _saveDraftNow();
    // A template rebuilds the day wholesale. Anything filmed against an
    // exercise the template does not carry is now unreachable in the UI, so it
    // is soft-deleted rather than left occupying storage and still eligible for
    // publication.
    // ignore: discarded_futures
    _videoSoftDeleteOrphans();
    // ignore: discarded_futures
    _loadAndApplyHints();

    // Persist: clear exercises[] + wesPlanned[], write template rows to wesPlanned.
    // ignore: discarded_futures
    _replaceWithTemplateRowsSilently(
      uid: _controller.actingUid,
      date: _controller.selectedDate,
      rows: reindexed,
    );

    // Clear BB3 planned day if pre-replacement had BB3-sourced rows.
    if (hadBb3Rows) {
      final blockId = _controller.activeBlockId;
      final blockStart = _controller.blockStartDate;
      if (blockId != null && blockId.isNotEmpty && blockStart != null) {
        final wd = _weekDayFromDate(blockStart, _controller.selectedDate);
        // ignore: discarded_futures
        _clearBb3PlannedDaySilently(
          uid: _controller.actingUid,
          blockId: blockId,
          weekIndex: wd.weekIndex,
          dayIndex: wd.dayIndex,
        );
      }
    }

    if (hadAnyRows && mounted) {
      _showUndoSnackBar('Exercises replaced by template');
    }
    return true;
  }

  Future<void> _replaceWithTemplateRowsSilently({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
  }) async {
    await _submitMutation(Wes2Mutation.templateReplaceAll(
      actorUid: _actorUidForMutations,
      athleteUid: uid,
      date: date,
      rows: rows,
      localSeq: ++_localMutationSeq,
    ));
  }

  // ── BB3 planned-day sync (Phase 20) ──────────────────────────────────────

  /// Syncs the current BB3-sourced rows back to the active BB3 planned-day
  /// path. Called after structural edits on BB3-sourced rows and after undo.
  /// Scoped strictly to the current blockId / weekIndex / dayIndex.
  Future<void> _syncBb3PlannedDayFromCurrentRowsSilently() async {
    final blockId = _controller.activeBlockId;
    final blockStart = _controller.blockStartDate;
    if (blockId == null || blockId.isEmpty || blockStart == null) return;
    if (_isBeforeBlockStart(_controller.selectedDate, blockStart)) return;
    final wd = _weekDayFromDate(blockStart, _controller.selectedDate);
    final bb3Rows = _controller.rows
        .where((r) =>
            r.source == Wes2RowSource.bb3Planned ||
            _bb3PlannedExerciseIds.contains(r.exerciseId))
        .toList();
    try {
      await _planService.updatePlannedDay(
        uid: _controller.actingUid,
        blockId: blockId,
        weekIndex: wd.weekIndex,
        dayIndex: wd.dayIndex,
        updatedRows: bb3Rows,
      );
    } catch (_) {
      // Silent failure; local draft preserves structural state.
    }
  }

  Future<void> _clearBb3PlannedDaySilently({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
  }) async {
    try {
      await _planService.updatePlannedDay(
        uid: uid,
        blockId: blockId,
        weekIndex: weekIndex,
        dayIndex: dayIndex,
        updatedRows: const [],
      );
    } catch (_) {
      // Silent failure; BB3 clear is best-effort.
    }
  }

  // ── Save Workout as Template (Phase 18) ──────────────────────────────────

  Future<void> _showSaveAsTemplateDialog() async {
    if (!mounted) return;
    final nameCtrl = TextEditingController();
    try {
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Save as Template'),
          content: TextField(
            controller: nameCtrl,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => Navigator.of(ctx).pop(nameCtrl.text),
            decoration: const InputDecoration(
              hintText: 'Template name',
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(nameCtrl.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (result == null || !mounted) return;
      final name = result.trim();
      if (name.isEmpty) return;
      try {
        await _templateService.saveWorkoutAsTemplate(
          uid: _controller.actingUid,
          blockId: _controller.activeBlockId,
          templateName: name,
          rows: _controller.rows.toList(),
        );
        if (mounted) _showSnackBar('Template saved.');
      } catch (_) {
        if (mounted) _showSnackBar('Failed to save template.');
      }
    } finally {
      nameCtrl.dispose();
    }
  }

  // ── Workout summary (Phase 17) ────────────────────────────────────────────

  void _showWorkoutSummary() {
    final rows = _controller.rows;
    final date = _controller.selectedDate;
    final dateStr = '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';

    final totalExercises = rows.length;
    final totalSets = rows.fold(0, (int s, r) => s + r.setCount);
    final setsLogged =
        rows.expand((r) => r.sets).where((s) => s.hasAnyActual).length;
    double totalVolume = 0;
    for (final row in rows) {
      for (final set in row.sets) {
        final w = set.weight.actualValue;
        final r = set.reps.actualValue;
        if (w != null && r != null) totalVolume += w * r;
      }
    }

    // Per-circuit exercise breakdown.
    final circuitMap = <int, List<Wes2ExerciseRow>>{};
    for (final row in rows) {
      circuitMap.putIfAbsent(row.circuitIndex, () => []).add(row);
    }
    final sortedCircuits = circuitMap.keys.toList()..sort();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        minChildSize: 0.25,
        builder: (_, scrollCtrl) => ListView(
          controller: scrollCtrl,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          children: [
            Text(
              'Workout Summary',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
            const SizedBox(height: 2),
            Text(
              dateStr,
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const Divider(height: 20),
            _summaryStatRow('Exercises', '$totalExercises'),
            _summaryStatRow('Total sets', '$totalSets'),
            _summaryStatRow('Sets logged', '$setsLogged'),
            if (_currentWorkoutDurationMs() > 0)
              _summaryStatRow(
                'Workout duration',
                _formatDuration(_currentWorkoutDurationMs()),
              ),
            if (_elapsedMilliseconds > 0)
              _summaryStatRow(
                'Last thing you timed',
                _formatDuration(_elapsedMilliseconds),
              ),
            if (totalVolume > 0)
              _summaryStatRow(
                'Total volume',
                '${totalVolume.toStringAsFixed(0)} kg·reps',
              ),
            if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'No exercises logged yet.',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
            if (rows.isNotEmpty) ...[
              const SizedBox(height: 16),
              for (final ci in sortedCircuits) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Circuit ${ci + 1}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                for (final row in circuitMap[ci]!) _summaryExerciseRow(row),
                const SizedBox(height: 8),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _summaryStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryExerciseRow(Wes2ExerciseRow row) {
    final loggedSets = row.sets.where((s) => s.hasAnyActual).length;
    double vol = 0;
    for (final s in row.sets) {
      final w = s.weight.actualValue;
      final r = s.reps.actualValue;
      if (w != null && r != null) vol += w * r;
    }
    final volStr = vol > 0 ? ' · ${vol.toStringAsFixed(0)}' : '';
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              row.name,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$loggedSets/${row.setCount} sets$volStr',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

/// The open WES2 day as the Aurelian 2.0 action service's [WorkoutActionPort].
///
/// A thin adapter: every mutation runs the handler the screen's own controls
/// run (the typed-entry save, the Delete/Replace/Move cores, the Done
/// coordinator, the note saves, Load Template, Add Set, the timers), so voice
/// and touch share one canonical path to the local draft and the durable
/// outbox. Decisions (matching, confirmation, undo, read-back) live in the
/// service, which reads this screen's state back after each change.
class _Wes2ActionPort implements WorkoutActionPort, ReloadableWorkout {
  _Wes2ActionPort(this._s);

  final _Wes2ScreenState _s;

  Wes2SessionController get _c => _s._controller;

  Wes2ExerciseRow? _rowOf(String id) =>
      _c.rows.where((Wes2ExerciseRow r) => r.exerciseId == id).firstOrNull;

  @override
  Future<String?> prepare() async {
    if (!_s.mounted) return 'The workout closed';
    final String? blocked = await _s._bringWorkoutToFront();
    if (blocked != null) return blocked;
    if (!await _s._waitForDay()) return 'The workout is still loading';
    return _s.mounted ? null : 'The workout closed';
  }

  @override
  DateTime get date => _c.selectedDate;

  @override
  String get actingUid => _c.actingUid;

  @override
  List<WorkoutExerciseView> get exercises {
    final units = ExerciseUnitRegistry.shared
        .unitsFor(_c.actingUid, blockSettings: _c.exerciseSettings);
    return <WorkoutExerciseView>[
      for (final Wes2ExerciseRow r in _c.rows)
        WorkoutExerciseView(
          exerciseId: r.exerciseId,
          name: r.name,
          circuitIndex: r.circuitIndex,
          setCount: r.setCount,
          sets: <WorkoutSetView>[
            for (final Wes2SetState st in r.sets)
              if (st.setIndex < r.setCount)
                WorkoutSetView(
                  index: st.setIndex,
                  weightKg: st.weight.actualValue,
                  reps: st.reps.actualValue,
                  rir: st.rir.actualValue,
                  velocity: st.velocity.actualValue,
                  note: st.executionNote,
                ),
          ],
          note: r.exerciseExecutionNote,
          done: r.isMarkedDone,
          timed: Wes2ExerciseCard.entryModeFor(r) != Wes2ExerciseEntryMode.normal,
          velocityShown: _s._shouldShowVelocityField(r),
          bb3Planned: r.source == Wes2RowSource.bb3Planned,
          unit: units.unitFor(r.exerciseId),
        ),
    ];
  }

  @override
  String? get targetExerciseId => _s._voiceTarget.resolve(_s._rowIds());

  @override
  void setTarget(String exerciseId) {
    _s._voiceTarget.select(exerciseId);
    if (_s.mounted) unawaited(_s._revealVoiceTarget());
  }

  @override
  Map<String, int> exerciseUsage() {
    final Map<String, int> counts = <String, int>{};
    final snapshot = ProgressionHistoryStore.instance.snapshotFor(_c.actingUid);
    if (snapshot == null) return counts;
    for (final Map<String, dynamic> doc in snapshot.docsByDay.values) {
      final Object? list = doc['exercises'];
      if (list is! List) continue;
      final Set<String> seen = <String>{};
      for (final Object? e in list) {
        if (e is! Map) continue;
        final Object? id = e['exerciseId'] ?? e['id'];
        if (id is String && id.isNotEmpty && seen.add(id)) {
          counts[id] = (counts[id] ?? 0) + 1;
        }
      }
    }
    return counts;
  }

  @override
  Future<bool> changeDate(DateTime date) async {
    if (!_s.mounted) return false;
    // The same steps as choosing a day in the date picker.
    _s._pauseWorkoutDurationSegment();
    _s._saveDraftNow();
    _s._workoutDurationMilliseconds = 0;
    _s._workoutDurationSegmentStartedAt = null;
    _c.changeDate(date);
    unawaited(_s._loadDay());
    return _s._waitForDay();
  }

  @override
  Future<List<CatalogueEntry>?> catalogue() async {
    final List<CatalogExercise>? all = await _s._catalogueOrNull();
    if (all == null) return null;
    return <CatalogueEntry>[
      for (final CatalogExercise e in all)
        CatalogueEntry(id: e.id, name: catalogueName(e), label: catalogueVoiceLabel(e, all)),
    ];
  }

  @override
  Future<List<TemplateEntry>?> templates() async {
    try {
      final templates = await loadWes2PickerTemplates(_c.actingUid)
          .timeout(const Duration(seconds: 8));
      return <TemplateEntry>[
        for (final t in templates)
          TemplateEntry(
            id: t.id,
            name: t.name,
            day: t.day,
            inActiveBlock: t.blockId != null && t.blockId == _c.activeBlockId,
          ),
      ];
    } catch (_) {
      return null;
    }
  }

  @override
  int? blockDayNumber() {
    final DateTime? start = _c.blockStartDate;
    if (start == null || _Wes2ScreenState._isBeforeBlockStart(_c.selectedDate, start)) {
      return null;
    }
    return _Wes2ScreenState._weekDayFromDate(start, _c.selectedDate).dayIndex + 1;
  }

  @override
  Future<String?> loadTemplate(String templateId) async {
    if (_s._isLoadingTemplate) return 'A template is still loading';
    _s._setLoadingTemplate(true);
    try {
      // The service has already confirmed any replacement of logged data.
      final bool loaded = await _s._onLoadTemplate(templateId);
      return loaded ? null : 'The template could not be loaded';
    } finally {
      if (_s.mounted) _s._setLoadingTemplate(false);
    }
  }

  @override
  Future<void> addExercise(CatalogueEntry exercise, int circuitIndex) async {
    _s._voicePickerOpen = false;
    await _s._addExerciseFromPicker(
        (exerciseId: exercise.id, name: exercise.name, circuitIndex: circuitIndex));
  }

  @override
  Future<void> deleteExercise(String exerciseId) async {
    final Wes2ExerciseRow? row = _rowOf(exerciseId);
    if (row == null) return;
    final bool wasBb3 = row.source == Wes2RowSource.bb3Planned ||
        _s._bb3PlannedExerciseIds.contains(row.exerciseId);
    await _s._deleteExerciseConfirmed(row,
        offerUndo: row.hasAnyExecutionValue, wasBb3: wasBb3);
  }

  @override
  Future<void> replaceExercise(String exerciseId, CatalogueEntry replacement) async {
    final Wes2ExerciseRow? row = _rowOf(exerciseId);
    if (row == null) return;
    await _s._applyReplacement(row, replacement.id, replacement.name,
        offerUndo: row.hasAnyExecutionValue);
  }

  @override
  Future<void> moveExercise(String exerciseId, int circuitIndex) async {
    final Wes2ExerciseRow? row = _rowOf(exerciseId);
    if (row == null) return;
    _s._moveExerciseToCircuitConfirmed(row, circuitIndex);
  }

  @override
  Future<void> setFields(String exerciseId, int setIndex, List<FieldEdit> edits) =>
      _s._applyVoiceFieldEdits(exerciseId, setIndex,
          <SetFieldEdit>[for (final FieldEdit e in edits) SetFieldEdit(e.key, e.text)]);

  @override
  Future<void> setNote(String exerciseId, int setIndex, String? note) async {
    // The set-note dialog's Save, without the dialog.
    final String trimmed = (note ?? '').trim();
    _c.updateExecutionNote(exerciseId: exerciseId, setIndex: setIndex, rawText: trimmed);
    _s._saveDraftNow();
    unawaited(_s._saveExecutionNoteSilently(
      uid: _c.actingUid,
      date: _c.selectedDate,
      exerciseId: exerciseId,
      setIndex: setIndex,
      note: trimmed.isEmpty ? null : trimmed,
    ));
  }

  @override
  Future<void> exerciseNote(String exerciseId, String? note) async {
    // The exercise-note dialog's Save, without the dialog.
    final String trimmed = (note ?? '').trim();
    _c.updateExerciseExecutionNote(exerciseId: exerciseId, rawText: trimmed);
    _s._saveDraftNow();
    unawaited(_s._saveExerciseExecutionNoteSilently(
      uid: _c.actingUid,
      date: _c.selectedDate,
      exerciseId: exerciseId,
      note: trimmed.isEmpty ? null : trimmed,
    ));
  }

  @override
  Future<void> setCompleted(String exerciseId, bool done) async {
    // The Completed? toggle's own ordering (focus, durable write, then Done).
    await _s._doneCoordinator.toggleMarkedDone(
      exerciseId: exerciseId,
      dropFocus: () => FocusManager.instance.primaryFocus?.unfocus(),
      awaitDurableWrites: _s._awaitDurableWrites,
      commitDone: () => _s._commitMarkedDone(exerciseId, done),
    );
  }

  @override
  Future<void> addSet(String exerciseId) async => _s._onAddSet(exerciseId);

  @override
  Future<void> removeSet(String exerciseId, int setIndex) async {
    final Wes2ExerciseRow? row = _rowOf(exerciseId);
    if (row == null || row.source == Wes2RowSource.bb3Planned || row.setCount <= 1) return;
    final Wes2SetState set = row.sets.firstWhere((Wes2SetState x) => x.setIndex == setIndex,
        orElse: () => Wes2SetState(setIndex: setIndex));
    await _s._removeSetConfirmed(row, setIndex, set);
  }

  @override
  GeneralTimerView get generalTimer {
    _s._syncTimerElapsed();
    return GeneralTimerView(
        visible: _s._timerVisible, running: _s._timerRunning, elapsedMs: _s._elapsedMilliseconds);
  }

  @override
  Future<void> startGeneralTimer() async {
    // The three-dot menu's Timer: show it, then start it.
    _s._showTimer();
    _s._startTimer();
  }

  @override
  Future<void> stopGeneralTimer() async => _s._stopTimer();

  @override
  SetTimerView? get runningSetTimer {
    final String? key = Wes2SetTimerHub.instance.runningKey;
    if (key == null) return null;
    final int hash = key.lastIndexOf('#');
    final int? setIndex = hash <= 0 ? null : int.tryParse(key.substring(hash + 1));
    if (setIndex == null) return null;
    return SetTimerView(exerciseId: key.substring(0, hash), setIndex: setIndex, running: true);
  }

  @override
  Future<bool> startSetTimer(String exerciseId, int setIndex) async {
    final String key = Wes2SetTimerHub.keyFor(exerciseId, setIndex);
    // The stopwatch lives in the set's own cell, which exists only on screen.
    await _s._ensureExerciseVisible(exerciseId);
    await WidgetsBinding.instance.endOfFrame;
    return Wes2SetTimerHub.instance.start(key);
  }

  @override
  Future<bool> stopSetTimer() async {
    final String? key = Wes2SetTimerHub.instance.runningKey;
    if (key == null) return false;
    final bool stopped = Wes2SetTimerHub.instance.stop(key);
    await WidgetsBinding.instance.endOfFrame;
    return stopped;
  }

  @override
  Future<bool> cancelSetTimer() async {
    final String? key = Wes2SetTimerHub.instance.runningKey;
    return key != null && Wes2SetTimerHub.instance.cancel(key);
  }

  @override
  Future<void> reopenForCurrentAthlete() async {
    if (!_s.mounted) return;
    final UserContext uc = UserContext.of(_s.context, listen: false);
    final DateTime day = _c.selectedDate;
    unawaited(Navigator.of(_s.context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => ChangeNotifierProvider<UserContext>.value(
        value: uc,
        child: gatedWes2(initialDate: day),
      ),
    )));
  }
}
