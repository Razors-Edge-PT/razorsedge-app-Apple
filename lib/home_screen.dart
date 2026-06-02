import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'workout_model.dart';
import 'app_drawer.dart';
import 'package:table_calendar/table_calendar.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'coach_home_screen.dart';
import 'approve_requests_screen.dart';
import 'bb3_week_planner.dart';
import 'WES2_screen.dart';
import 'core_exercises.dart';
import 'profile_page.dart';
import 'user_settings.dart';
import 'warmup_service.dart';
import 'dart:async';
import 'directMessages.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'warmupBB2.dart';
import 'post_service.dart';
import 'feed_post_card.dart';
import 'main.dart';
import 'leaderboard_page.dart';
import 'template_bootstrapper.dart';
import 'block_exercise_defaults_repository.dart';
import 'block_creation_helper.dart';
import 'templates.dart';
import 'planned_blocks_screen.dart';
import 'local_cache/block_plan_cache.dart';
import 'onboarding_prefs.dart';
import 'package:intl/intl.dart';



enum SelectedFeed { home, points, leaderboard }
const String kUserPrefFeedTab = 'feedTab'; // 'home' | 'points'




class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with RouteAware {
  late final UserContext _uc;
  bool _ucBound = false;

  // Onboarding cue state — default true so no cue flashes before prefs load
  bool _wpDone = true;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  static const double kFeatureCardWidth = 150;

  String? mostRecentWeight;
  Workout? mostRecentWorkout;
  bool isLoading = true;
  String errorMessage = '';

  // Firestore subscription for active block changes (training days refresh)
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _activeBlockSub;

  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Set<DateTime> _trainingDays = {};

  //Profile image
  bool _avatarPersistInProgress = false;
  String? _avatarLastUrlSaved;

  //Warm ups
  bool _bb2WarmupScheduled = false;     // first-time warmup




  String? _actingAsEmail;
  String? _lastWarmUid;

  // ── Home FEED ─────────────────────────────────────────────────────────
  final ScrollController _homeScrollCtrl = ScrollController();
  List<Post> _feedPosts = [];
  bool _feedLoading = false;
  bool _feedHasMore = true;
  SelectedFeed _selectedFeed = SelectedFeed.home;
  final ScrollController _pointsScrollCtrl = ScrollController();

// Points feed state
  List<Post> _pointsPosts = [];
  bool _pointsLoading = false;
  bool _pointsHasMore = true;
  Timestamp? _lastPointsCreatedAt;


// Points month filter (yyyy-MM), default = current month
  final String _pointsMonthKey = () {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
  }();

  List<String> _feedOwnerUids = []; // self + buddies
  bool _feedOwnersResolved = false;
  static const int _kFeedPageSize = 6;
  bool _feedError = false;
  Timestamp? _lastCreatedAt; // simple, stable pagination
  bool _loadMoreScheduled = false;








  @override
  void initState() {
    super.initState();
    debugPrint('🏠 [HOME:initState] running initState()');

    final userContext = Provider.of<UserContext>(context, listen: false);
    final actingUid = userContext.actingAsUid;
    _homeScrollCtrl.addListener(_onHomeScroll);
    _pointsScrollCtrl.addListener(_onPointsScroll);

    // 🔄 Replace the three separate blocks with this single kickoff
    unawaited(() async {
      // 1) Resolve owners once
      await _resolveFeedOwners();

      // 2) Restore last selected tab once
      await _restoreSelectedFeed();
      if (!mounted) return;

      // 4) Kick exactly one initial load for the selected tab
      if (_selectedFeed == SelectedFeed.home) {
        await _loadInitialHomeFeed();
      } else {
        await _loadInitialPointsFeed();
      }
    }());

// Pass block + date so Warmup can precompute the exact WES snapshot you'll need.
    // BB2 wiring disabled: warmWES pre-computes BB2-derived hints into WESInitSnapshot.
    // Disabled until BB3 integration is ready.
    // unawaited(WarmupService.instance.warmWES(
    //   actingUid ?? '',
    //   activeBlockId: userContext.activeBlockId,
    //   selectedDate: _warmDate,
    // ));

    debugPrint('🏁 [HOME] Triggering WarmupBB2 for $actingUid');



    // Delay the email fetch until after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAthleteEmail();
    });

    _ensureAtLeastOneBlockExists().then((_) async {
      if (!mounted) return;
      final uc = Provider.of<UserContext>(context, listen: false);
      await uc.refreshBlockMetaFromServer(uid: uc.actingAsUid);

      _fetchRecentData();
      _fetchTrainingDaysForMonth(_focusedDay);

      _activeBlockSub = FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(actingUid) //
          .collection('blocks')
          .where('isActive', isEqualTo: true)
          .snapshots()
          .listen((_) {
        _fetchTrainingDaysForMonth(_focusedDay);
      });


      // 🔎 Kick the 8-day local/FS scan once (post-frame so context is ready)
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final uc = Provider.of<UserContext>(context, listen: false);
        final uid = uc.actingAsUid;
        final bid = uc.activeBlockId;
        if (uid.isNotEmpty && bid != null && bid.isNotEmpty) {
          // ✅ Roll forward missed BB2 plans into the next available days
          await _rollForwardMissedBB2Plans(uid: uid, blockId: bid);
          // Self-heal sparse rirPlan for existing users (no-op if already complete).
          unawaited(BlockExerciseDefaultsRepository.healActiveBlockRirPlan(
            uid: uid,
            blockId: bid,
          ));
        }

        // 🔥 Prewarm BB2 current week (server-based merged cache for first-paint correctness)
        if (actingUid.isNotEmpty) {
          unawaited(WarmupBB2.runForActiveBlock(uid: actingUid));
        }
      });
    });

    // Load onboarding cue state (non-blocking; defaults keep Home safe until this resolves)
    unawaited(_loadOnboardingState());

    // 🔧 One-time default template bootstrap (non-blocking) — gated on users + fitness_onboarding
    // 🚫 Auth stability guard — do NOT attach Firestore listeners if auth is unstable
    final authUser = FirebaseAuth.instance.currentUser;
    if (!mounted || authUser == null || authUser.uid != actingUid) {
      debugPrint('🛑 [HOME] Skipping onboarding listeners (auth unstable)');
      return;
    }

    if (actingUid.isNotEmpty) {
      final usersRef    = FirebaseFirestore.instance.collection('users').doc(actingUid);
      final onboardRef  = FirebaseFirestore.instance
          .collection('users')
          .doc(actingUid)
          .collection('profile')
          .doc('fitness_onboarding');

      bool fired = false;

      Future<void> maybeRun() async {
        if (fired || !mounted) return;
        try {
          fired = true;

          // ✅ Run bootstrap now that data is ready (all 3 block docs exist by this point)
          await TemplatesBootstrapper.ensureInitialTemplatesForUser(actingUid);


          // ✅ Let the user know without blocking UI
          if (mounted && ScaffoldMessenger.maybeOf(context) != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Programs ready')),
            );
          }

          debugPrint('🧰 [HOME] Template bootstrap complete (gated) for $actingUid');
        } catch (e, st) {
          debugPrint('🧰 [HOME] Gated bootstrap threw: $e\n$st');
          fired = false; // allow retry if something transient failed
        }
      }

      StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? userSub;
      StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? onboardSub;


      // Non-blocking listeners; auto-cancel after first success
      userSub = usersRef
          .snapshots()
          .listen(
            (u) async {
          if (!u.exists) return;
          final d = u.data();
          final hasCore =
              d != null &&
                  d['sex'] != null &&
                  d['dob'] != null &&
                  d['username'] != null;

          if (!hasCore) return;

          // Check onboarding doc in parallel
          final oSnap = await onboardRef.get();
          final onboardingReady = oSnap.exists && (oSnap.data()?.isNotEmpty ?? false);

          if (onboardingReady) {
            await maybeRun();
            await userSub?.cancel();
            // onboardSub might be null if we never attached (see below)
          }
        },
        onError: (Object e, StackTrace st) async {
          debugPrint('🟥 [HOME] usersRef.snapshots denied: $e');
          // Optional: cancel so it doesn't spam logs
          try { await userSub?.cancel(); } catch (_) {}
        },
      );


      // Also watch onboarding; if onboarding arrives first, verify user core then run
      onboardSub = onboardRef
          .snapshots()
          .listen(
            (o) async {
          if (!o.exists || (o.data()?.isNotEmpty != true)) return;

          final u = await usersRef.get();
          final d = u.data();
          final hasCore =
              u.exists &&
                  d != null &&
                  d['sex'] != null &&
                  d['dob'] != null &&
                  d['username'] != null;

          if (hasCore) {
            await maybeRun();
            await onboardSub?.cancel();
            try { await userSub?.cancel(); } catch (_) {}
          }
        },
        onError: (Object e, StackTrace st) async {
          debugPrint('🟥 [HOME] onboardRef.snapshots denied: $e');
          try { await onboardSub?.cancel(); } catch (_) {}
        },
      );


      // (Keep your templates watcher block below if you want live counts)
    }
  }
// ─────────────────────────────────────────────────────────────
// BB2 Roll-forward: move missed planned days forward (chain push)
// Planned day exists: exercises.length > 0
// Completed day blocks ONLY if any set has reps>0 AND weight>0
// ─────────────────────────────────────────────────────────────
  Future<void> _rollForwardMissedBB2Plans({
    required String uid,
    required String blockId,
  }) async {
    // Must have block dates (same local-date semantics you confirmed)
    final DateTime? bs = _uc.blockStartDate;
    final DateTime? be = _uc.blockEndDate;
    if (bs == null || be == null) {
      debugPrint('⚠️ [ROLL] abort: blockStartDate/endDate missing');
      return;
    }

    // Normalize to local date-only
    DateTime _d0(DateTime d) => DateTime(d.year, d.month, d.day);

    final blockStart = _d0(bs);
    final blockEnd   = _d0(be);
    final today      = _d0(DateTime.now());

    // Only meaningful if today is within the block window at all
    if (today.isBefore(blockStart)) {
      debugPrint('ℹ️ [ROLL] today before blockStart → nothing to roll');
      return;
    }

    // Clamp scan end to block end
    final scanEnd = today.isBefore(blockEnd) ? today : blockEnd;

    int _daysBetween(DateTime a, DateTime b) => _d0(b).difference(_d0(a)).inDays;

    final int lastOffsetInclusive = _daysBetween(blockStart, scanEnd);
    final int todayOffset = _daysBetween(blockStart, today);

    // 🔒 Optional once-per-day guard (COMMENTED OUT FOR TESTING)
    // Search-bar anchor: "[ROLL GUARD]"
    /*
  try {
    final prefs = await SharedPreferences.getInstance();
    final key = 'bb2.rollForward.lastRun.$uid';
    final stamp = DateFormat('yyyy-MM-dd').format(today);
    final last = prefs.getString(key);
    if (last == stamp) {
      debugPrint('🛑 [ROLL GUARD] already ran today ($stamp) for uid=$uid');
      return;
    }
    await prefs.setString(key, stamp);
  } catch (e) {
    debugPrint('⚠️ [ROLL GUARD] prefs failed: $e');
  }
  */

    debugPrint('🧠 [ROLL] start uid=$uid block=$blockId '
        'range=0..$lastOffsetInclusive todayOffset=$todayOffset');
    // 🔁 Keep WES super-cache (Isar) in sync with roll-forward writes
    Future<void> _isarPutOffset(int offset, List<Map<String, dynamic>> exercises) async {
      try {
        final int w = offset ~/ 7;
        final int d = offset % 7;
        await BlockPlanCache.putDay(
          uid: uid,
          blockId: blockId,
          weekIndex: w,
          dayIndex: d,
          exercises: exercises,
          updatedAt: DateTime.now(),
        );
        debugPrint('🧊 [ROLL] ISAR put week_$w/day_$d ex=${exercises.length}');
      } catch (e) {
        debugPrint('⚠️ [ROLL] ISAR put failed (non-fatal) off=$offset → $e');
      }
    }

    // Firestore refs
    final blocksRoot = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId);

    final workoutsCol = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts');

    String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(_d0(d));

    DocumentReference<Map<String, dynamic>> _dayRefForOffset(int offset) {
      final w = offset ~/ 7;
      final d = offset % 7;
      return blocksRoot
          .collection('weeks')
          .doc('week_$w')
          .collection('days')
          .doc('day_$d');
    }

    DocumentReference<Map<String, dynamic>> _weekRefForOffset(int offset) {
      final w = offset ~/ 7;
      return blocksRoot.collection('weeks').doc('week_$w');
    }

    // 1) Load planned day docs (cache-first ok; but server preferred for correctness)
    final plannedByOffset = <int, Map<String, dynamic>>{};
    {
      final futures = <Future<DocumentSnapshot<Map<String, dynamic>>>>[];
      for (int off = 0; off <= lastOffsetInclusive; off++) {
        futures.add(_dayRefForOffset(off).get(const GetOptions(source: Source.server)));
      }
      final snaps = await Future.wait(futures);
      for (int i = 0; i < snaps.length; i++) {
        final s = snaps[i];
        if (!s.exists) continue;
        final data = s.data();
        if (data == null) continue;
        plannedByOffset[i] = Map<String, dynamic>.from(data);
      }
    }

    bool _isPlannedDay(Map<String, dynamic>? dayDoc) {
      if (dayDoc == null) return false;
      final ex = dayDoc['exercises'];
      if (ex is List) return ex.isNotEmpty;
      return false;
    }

    // 2) Load completion status for each day (workouts/{yyyy-MM-dd})
    final completed = <int, bool>{};
    {
      final futures = <Future<DocumentSnapshot<Map<String, dynamic>>>>[];
      final keys = <String>[];
      for (int off = 0; off <= lastOffsetInclusive; off++) {
        final date = blockStart.add(Duration(days: off));
        final key = _ymd(date);
        keys.add(key);
        futures.add(workoutsCol.doc(key).get(const GetOptions(source: Source.server)));
      }

      final snaps = await Future.wait(futures);
      for (int i = 0; i < snaps.length; i++) {
        final snap = snaps[i];
        bool isDone = false;

        if (snap.exists) {
          final data = snap.data() ?? const {};
          final exs = (data['exercises'] is List)
              ? List<Map<String, dynamic>>.from(data['exercises'] as List)
              : const <Map<String, dynamic>>[];

          // Completed day definition: any set anywhere has reps>0 AND weight>0
          for (final ex in exs) {
            final sets = (ex['sets'] is List)
                ? List<Map<String, dynamic>>.from(ex['sets'] as List)
                : const <Map<String, dynamic>>[];

            for (final s in sets) {
              final dynamic repsRaw = s['reps'];
              final dynamic wRaw = s['weight'];

              final int reps = (repsRaw is num)
                  ? repsRaw.toInt()
                  : int.tryParse('${repsRaw ?? ''}'.trim()) ?? 0;

              final double w = (wRaw is num)
                  ? wRaw.toDouble()
                  : double.tryParse('${wRaw ?? ''}'.trim()) ?? 0.0;

              if (reps > 0 && w > 0.0) {
                isDone = true;
                break;
              }
            }

            if (isDone) break;
          }

        }

        completed[i] = isDone;
      }
    }

    // Helper: ensure week doc exists (so day writes don't fail)
    Future<void> _ensureWeekExistsForOffset(int offset) async {
      final weekRef = _weekRefForOffset(offset);
      final s = await weekRef.get(const GetOptions(source: Source.server));
      if (!s.exists) {
        final int w = offset ~/ 7;
        await weekRef.set({
          'exists': true,
          'startDate': Timestamp.fromDate(blockStart.add(Duration(days: w * 7))),
          'endDate': Timestamp.fromDate(blockStart.add(Duration(days: (w + 1) * 7 - 1))),
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } else {
        await weekRef.set({'exists': true}, SetOptions(merge: true));
      }
    }

    // Helper: write a planned day payload to an offset (updates date/workoutName)
    Future<void> _writePlannedToOffset(int offset, Map<String, dynamic> payload) async {
      await _ensureWeekExistsForOffset(offset);

      final DateTime date = blockStart.add(Duration(days: offset));
      final int w = offset ~/ 7;

      final String workoutName =
          "${DateFormat('EEE d MMM').format(date)} - Week ${w + 1}";

      final out = <String, dynamic>{
        'exercises': payload['exercises'] ?? const [],
        'circuitStartIndices': payload['circuitStartIndices'] ?? [0],
        'date': Timestamp.fromDate(_d0(date)),
        'workoutName': workoutName,
      };

      await _dayRefForOffset(offset).set(out, SetOptions(merge: false));

// ✅ Mirror to Isar so WES sees it immediately
      final raw = out['exercises'];
      final List<Map<String, dynamic>> exList =
      (raw is List)
          ? raw.map((e) => Map<String, dynamic>.from(e as Map)).toList()
          : <Map<String, dynamic>>[];

      await _isarPutOffset(offset, exList);


    }

    // Helper: clear a planned day (set exercises empty; keep other fields consistent)
    Future<void> _clearPlannedAtOffset(int offset) async {
      await _ensureWeekExistsForOffset(offset);
      final DateTime date = blockStart.add(Duration(days: offset));
      final int w = offset ~/ 7;
      final String workoutName =
          "${DateFormat('EEE d MMM').format(date)} - Week ${w + 1}";

      await _dayRefForOffset(offset).set({
        'exercises': [],
        'circuitStartIndices': [0],
        'date': Timestamp.fromDate(_d0(date)),
        'workoutName': workoutName,
      }, SetOptions(merge: false));
      // ✅ Mirror clear to Isar
      await _isarPutOffset(offset, const <Map<String, dynamic>>[]);

    }

    // 3) Identify missed planned days BEFORE today that are not completed
    final missedOffsets = <int>[];
    for (int off = 0; off < todayOffset && off <= lastOffsetInclusive; off++) {
      if (completed[off] == true) continue;
      final dayDoc = plannedByOffset[off];
      if (_isPlannedDay(dayDoc)) missedOffsets.add(off);
    }

    if (missedOffsets.isEmpty) {
      debugPrint('✅ [ROLL] no missed planned days before today');
      return;
    }

    debugPrint('📦 [ROLL] missedOffsets=$missedOffsets');

    // 4) STABLE reschedule that preserves order:
    //    queue = (missed before today) + (existing future plans), both in chronological order
    final int maxOffset = _daysBetween(blockStart, blockEnd);

    // Build the queue (payloads) in correct order
    final List<Map<String, dynamic>> queue = [];

    // A) Missed plans before today (keep order)
    for (final off in missedOffsets) {
      Map<String, dynamic>? data = plannedByOffset[off];
      if (!_isPlannedDay(data)) {
        final s = await _dayRefForOffset(off).get(const GetOptions(source: Source.server));
        data = s.data();
      }
      if (_isPlannedDay(data)) {
        queue.add(Map<String, dynamic>.from(data!));
      }
    }

    // B) Existing future plans (today..end), keep order, skip completed days
    final futurePlannedOffsetsToClear = <int>[];
    for (int off = todayOffset; off <= maxOffset; off++) {
      if (completed[off] == true) continue;

      Map<String, dynamic>? dayDoc = plannedByOffset[off];

      // ✅ IMPORTANT: we only preloaded up to "today", so for future offsets
      // we must fetch from server or we will overwrite existing plans.
      if (!_isPlannedDay(dayDoc)) {
        final s = await _dayRefForOffset(off)
            .get(const GetOptions(source: Source.server));
        dayDoc = s.data();
      }

      if (_isPlannedDay(dayDoc)) {
        queue.add(Map<String, dynamic>.from(dayDoc!));
        futurePlannedOffsetsToClear.add(off);
        debugPrint('🧪 [ROLL] queued existing future plan off=$off date=${_ymd(blockStart.add(Duration(days: off)))}');


      }
    }


    if (queue.isEmpty) {
      debugPrint('✅ [ROLL] queue empty after read (nothing to move)');
      return;
    }

    debugPrint('📦 [ROLL] reschedule queue size=${queue.length} '
        '(missed=${missedOffsets.length}, future=${futurePlannedOffsetsToClear.length})');

    // 5) Clear sources that will be re-packed
    for (final off in missedOffsets) {
      await _clearPlannedAtOffset(off);
    }
    for (final off in futurePlannedOffsetsToClear) {
      await _clearPlannedAtOffset(off);
    }

    // 6) Pack forward from todayOffset into earliest valid (not completed) slots
    int dest = todayOffset;

    for (final payload in queue) {
      while (dest <= maxOffset) {
        // 🔒 HARD BLOCK: never write into a completed WES day
        bool isDone = completed[dest] == true;

        if (!isDone) {
          // If this offset wasn't preloaded, check server directly
          final date = blockStart.add(Duration(days: dest));
          final key = _ymd(date);
          final snap = await workoutsCol
              .doc(key)
              .get(const GetOptions(source: Source.server));
          debugPrint('🧪 [ROLL] dest=$dest key=$key snapExists=${snap.exists}');
          if (snap.exists) debugPrint('🧪 [ROLL] exercisesLen=${(snap.data()?['exercises'] as List?)?.length ?? 0}');


          if (snap.exists) {
            final data = snap.data() ?? const {};
            final exs = (data['exercises'] is List)
                ? List<Map<String, dynamic>>.from(data['exercises'] as List)
                : const <Map<String, dynamic>>[];

            for (final ex in exs) {
              final sets = (ex['sets'] is List)
                  ? List<Map<String, dynamic>>.from(ex['sets'] as List)
                  : const <Map<String, dynamic>>[];
              for (final s in sets) {
                final int reps = (s['reps'] is num)
                    ? (s['reps'] as num).toInt()
                    : 0;
                final double w = (s['weight'] is num)
                    ? (s['weight'] as num).toDouble()
                    : 0.0;
                if (reps > 0 && w > 0.0) {
                  isDone = true;
                  break;
                }
              }
              if (isDone) break;
            }
          }
        }

        if (isDone) {
          dest++;
          continue;
        }

        // ✅ safe slot
        break;
      }

      if (dest > maxOffset) {
        debugPrint('🧯 [ROLL] hit block end; dropping remaining queued plans');
        break;
      }

      await _writePlannedToOffset(dest, payload);
      debugPrint('✅ [ROLL] placed queued plan → offset $dest');
      dest++;
    }


    debugPrint('✅ [ROLL] finished uid=$uid block=$blockId');

  }



  Future<void> _persistAvatarLocalIfNeeded(BuildContext context, {
    required String uid,
    required String photoURL,
  }) async {
    if (_avatarPersistInProgress) return;
    final uc = context.read<UserContext>();

    // Already have a good local file? done.
    if (uc.localPhotoPath != null) {
      final f = File(uc.localPhotoPath!);
      if (f.existsSync() && await f.length() > 0) return;
    }

    // Avoid refetching the same URL repeatedly
    if (_avatarLastUrlSaved == photoURL) return;

    _avatarPersistInProgress = true;
    try {
      // Download (or hit cache) and persist a copy to app docs
      final file = await DefaultCacheManager().getSingleFile(photoURL);
      if (!file.existsSync()) return;

      final dir = await getApplicationDocumentsDirectory();
      final dest = File('${dir.path}/avatar_$uid.jpg');
      try { if (dest.existsSync()) await dest.delete(); } catch (_) {}
      await file.copy(dest.path);

      _avatarLastUrlSaved = photoURL;
      uc.setLocalPhotoPath(dest.path); // 🔔 notifies listeners → AppBar swaps to FileImage
    } catch (_) {
      // ignore; fallback stays as NetworkImage
    } finally {
      _avatarPersistInProgress = false;
    }
  }

  Future<void> _restoreSelectedFeed() async {
    if (!mounted) return;

    try {
      final uid = UserContext.of(context, listen: false).actorUid;
      final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final prefs = (snap.data()?['prefs'] as Map<String, dynamic>?) ?? const {};
      final tab = (prefs[kUserPrefFeedTab] as String?) ?? 'home';
      _selectedFeed = (tab == 'points') ? SelectedFeed.points : SelectedFeed.home;
      setState(() {});
    } catch (_) {
      _selectedFeed = SelectedFeed.home;
    }
  }

  Future<void> _persistSelectedFeed() async {
    if (!mounted) return;

    try {
      final uid = UserContext.of(context, listen: false).actorUid;
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'prefs': { kUserPrefFeedTab: _selectedFeed == SelectedFeed.points ? 'points' : 'home' }
      }, SetOptions(merge: true));
    } catch (_) {}
  }


  Future<void> _ensureAtLeastOneBlockExists() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final swTotal = Stopwatch()..start();

    final uid = user.uid;
    final blocksRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks');

    final existingBlocks = await blocksRef.get();

    if (existingBlocks.docs.isEmpty) {
      // ── Fetch username & sex from /users/{uid} ───────────────────────────────
      final usersRef = FirebaseFirestore.instance.collection('users').doc(uid);
      final userSnap = await usersRef.get();
      final data = userSnap.data() ?? {};

      // 🔒 Gate: wait until /users has core fields (prevents female default)
      final hasCore = userSnap.exists &&
          (data['sex'] != null) &&
          (data['username'] != null || data['fullName'] != null);

      if (!hasCore) {
        debugPrint('🛑 [Home] Block gate: /users/$uid incomplete → retry in 800ms');
        // tiny, non-blocking retry; won't slow first paint
        unawaited(Future.delayed(const Duration(milliseconds: 800), () async {
          await _ensureAtLeastOneBlockExists();
        }));
        return;
      }

      print('🔎 [Home] Reading /users/$uid  exists=${userSnap.exists}');
      print('🔎 [Home] /users/$uid keys=${data.keys.toList()}');

      final usernameFromDoc = (data['username'] as String?)?.trim();
      final sexRawFromDoc   = (data['sex'] as String?)?.trim();

      // Fallbacks so we still name the block if the user doc isn't ready yet:
      final auth = FirebaseAuth.instance.currentUser!;
      final fallbackUsername = (auth.displayName?.trim().isNotEmpty == true)
          ? auth.displayName!.trim()
          : (auth.email?.split('@').first ?? '').trim();

      final username = (usernameFromDoc?.isNotEmpty == true)
          ? usernameFromDoc
          : (fallbackUsername.isNotEmpty ? fallbackUsername : null);

      final sex = (sexRawFromDoc == null || sexRawFromDoc.isEmpty)
          ? 'N'  // default → treated as female branch per your rules
          : sexRawFromDoc.toUpperCase();

      print('🧬 [Home] Using uid=$uid username="$username" sex="$sex"');

      final isFemale = sex == 'F' || sex == 'N';
      print('🧬 [Home] Template branch = ${isFemale ? 'FEMALE' : 'MALE'}');

      // Block names
      final block1Name = (username != null && username.isNotEmpty)
          ? "${username}'s First Block"
          : "1st Block";
      final block2Name = (username != null && username.isNotEmpty)
          ? "${username}'s 2nd Block"
          : "2nd Block";

      print('🆕 [Home] No blocks found — creating "$block1Name" and "$block2Name"...');

      // ── Dates: start = Monday of the current week ("Monday just gone") ──────
      final now = DateTime.now();

      // Normalize to date-only (midnight) to avoid time-of-day drift in Firestore dates
      final today = DateTime(now.year, now.month, now.day);

      // DateTime.weekday: Mon=1 ... Sun=7
      final startDate1 = today.subtract(Duration(days: today.weekday - DateTime.monday));

      // 26 weeks = 182 days total. If start is day 0, last day is start + 181.
      final endDate1 = startDate1.add(const Duration(days: 181));

      // Next blocks start the day after the previous ends
      final startDate2 = endDate1.add(const Duration(days: 1));
      final endDate2   = startDate2.add(const Duration(days: 181));

      final startDate3 = endDate2.add(const Duration(days: 1));
      final endDate3   = startDate3.add(const Duration(days: 181));

      debugPrint('📅 [Home] Block1 start=${startDate1.toIso8601String()} end=${endDate1.toIso8601String()} (today=${today.toIso8601String()})');



      // ── Base exercise IDs (shared by both sexes) ─────────────────────────────
      const baseExercises = <String>[
        'AmfUWbF1DH3I7qPAdh5k', // Bench Press, Barbell
        'kTs5fLSTKjUkUZL10iii', // Flat Bench Dumbbell Press
        'heeBViVINHO6tUScSd6y', // Back Squat, Barbell
        'y5q9OU9OBzZQMkfPzFrf', // Romanian Deadlift
        'v2XlZUvFfBUhogOdKtJ8', // Leg Press
        'lVDG90yN6Z8aPjRNV2wc', // Overhead Barbell Press
        '2yJSfLMfOnNDSeZ7DqZT', // Overhead Dumbbell Press
        '9siQpXF2KLCj7M9kCy2m', // Seated Shoulder Dumbbell Press
        '1XOIXxeLFhgmgjZS9Cyq', // Lat Pull Down, Supinated
        'Url65Q2RxZa00dkDpUdl', // Lat Pull Down, Wide Arm
        'JbthLLjMF6xRvvaUY8PU', // Lat Pull Down, Unilateral
        'ETm055bydWtUCxTMu3MR', // Seated Leg Curl
        'wIcMsf2J9cswJRs1GuYX', // Lying Leg Curl
        'QkEgE8gnIva2kkNJEfxw', // Leg Extension
        'ZKpGshMxFl2dxNmYSATj', // Leg Extension, Unilateral
        'ci3KpMTEacH4bw8ZumJW', // Standing Calf Raise
        'spGqXXReJNHMcc62YgZX', // Seated Calf Raise
        'WPb8rtRTupKIBzgydB5k', // Cable Biceps Curl
        '0dZrCqZ8M7Q1sAn0zeeb', // Dumbbell Biceps Curl
        'zn5PgKNRrWo1MTE4wnCy', // Bayesian Biceps Curl
        'E6jPE8YYR0KA3xtVaKJo', // Triceps Push Down
        'QacImADmlpljltUvB0dD', // Overhead Cable Triceps Extension
        'eeEXnmSXv90q0rUgGECq', // KP Face Pull
        'KPewxxYYrhsOp84lIQr5', // Suspended High Row
        'P88Vj5pBydqmiEzFowag', // Hanging Straight Leg Raise
        'uY8uJaSFK9czKIX4TLc4', // Machine Chest Press
        'FtayDmR5BVnGS1FX1XLL', // Triceps Dip
        'OJaMXFKgMnM0X5xttBE1', // Cable Face Pull
        '6SGWrCKfe7KQLThRYXQ6', // One Arm Row, Dumbbell
        'Z1LpfaEBvHBDMsJ54pgw', // Hack Squat
        'z5gs1ilr4DpKlSZaRNG5', // Overhead Cable Triceps Extension, Unilateral
        'LVMQEQl6ZWBcgEUdk2tP', // Leg Press Calf Raise
        'ISXQqOEXLjMrPEs0xjgJ', // Bulgarian Split Squat
        'ocNWJv7xLrlinGmjG6cV', // Machine Row, Supported
        'eyh76KELuuO805rZBpMa', // 45 Degree Hip Extension
        'RdsGazgdH0xgpjek0n3u', // Overhead Dumbbell Press, Unilateral
        'xWpCQO504iGfU3LKLZlD', // Cable High Row, Unilateral
        'XM9026peNIu0R8qh7UqY', // Chin-Up

      ];

      // ── Male-specific exercises ─────────────────────────────────────────────
      const maleSpecificExercises = <String>[
        '6d9Ud7ffAHpljWsSKrFe', // Seated Face Pull
        'TBSudbow1OLdX6mSCC6S', // Machine Chest Fly
        '72HAT6Od4iJodEFxzw62', // Machine Reverse Fly
        'igNo9pSuaOFt0GVX0zBG', // Cable Lateral Raise
        'ZKrfhPhJIiC1hRuwBEw1', // Bayesian Fly
        'RcC48r0oLsNCH798d3jc', // Butterfly Dumbbell Raise
        'ewJBWuDzj1CxfQ3vI3QS', // Reverse Bayesian Fly
        '8saP9lWMoQffuh30A99K', // Lat Prayer
        '0s4yMXygBXZZJH66Yi6h', // Seated Face Pull, Unilateral
      ];

      // ── Female-specific exercises ───────────────────────────────────────────
      const femaleSpecificExercises = <String>[
        'vrSYibzR5DHzl6Gzp4ER', // Machine Shoulder Press, Pin Loaded
        '3dWgorRmtgzsV0U4qu47', // Glute Cable Kick Back
        'kxgQUX7Cr75l1kOwRaqc', // Spider-Girl Plank
        'YaQ0FCQEUAk4ALwAPhv2', // Machine Hip Thrust
        'visub8iG0LIXYYCv5Qom', // Hip Thrust, Unilateral
        'LGhFj8o0sG3X12296UAh', // Hip Thrust, Barbell
        'hCpQR1NgeEAp31lVRWLw', // Machine Hip Adduction
        '7WBffXwK7vJcMi3mtJTF', // Machine Hip Abduction
        't66qeWQqnuEtaoyZqRp0', // Triceps Dip Machine
        'zpNb7HgXjtcrzR14F3iF', // Cable One Arm Row
        '8CIXN12uS2xwF4JzVLq3', // Long Lever Plank
        'SoHQVtsCQreaHM8LUI5F', // Bicycle Crunch
        'qU2wXMth4duOhhzTUWet', // Decline Crunch
      ];

      // ── Build merged list based on sex ─────────────────────────────────────
      final seededExerciseIds = [
        ...baseExercises,
        if (isFemale) ...femaleSpecificExercises else ...maleSpecificExercises,
      ];

      // Sex-derived candidate pool for templateCandidateExerciseIds
      final candidateIds = computeTemplateCandidateIds(isFemale: isFemale);
      debugPrint('✅ [HOME] First-login: using candidateIds=${candidateIds.length}, no full exercise scan');

      // ── Block 2 exercise adjustments (sex-specific ± tweaks) ─────────────────────
// Base = all exercises from Block 1. Then apply -exclusions +additions.

      const femaleAdditionsB2 = <String>[
        // e.g., 'LGhFj8o0sG3X12296UAh', // Hip Thrust, Barbell
        // e.g., 'F76PnvlLLVF6hviuhRfH', // Seated Dumbbell Biceps Curl
      ];

      const maleAdditionsB2 = <String>[
        // e.g., '6d9Ud7ffAHpljWsSKrFe', // Seated Face Pull
      ];

      const femaleExclusionsB2 = <String>[
        // e.g., 'heeBViVINHO6tUScSd6y', // Back Squat, Barbell
      ];

      const maleExclusionsB2 = <String>[
        // e.g., 'wIcMsf2J9cswJRs1GuYX', // Lying Leg Curl
      ];

// Apply Block 2 adjustments dynamically
      final block2ExerciseIds = <String>{
        ...seededExerciseIds.where(
              (id) => !(isFemale ? femaleExclusionsB2 : maleExclusionsB2).contains(id),
        ),
        ...(isFemale ? femaleAdditionsB2 : maleAdditionsB2),
      }.toList(growable: false);


      // ── Block 3 exercise adjustments (sex-specific ± tweaks) ───────────────────────
// Use these four lists to easily fine-tune Block 3 composition.
// Base = all exercises from Block 1/2. Then apply -exclusions +additions.

      const femaleAdditions = <String>[
        'I4021icWTx3EAnAe1eHf', // Box Jump Squat
        // e.g., 'zpNb7HgXjtcrzR14F3iF', // Cable One Arm Row
      ];

      const maleAdditions = <String>[
        'EFbQl9i9NdYi13F3DqHr', // Push Up, Suspended
        'Ah9XLjbWvLJOWxb6e1H0', // Triceps Push Down, Unilateral

      ];

      const femaleExclusions = <String>[
        'uY8uJaSFK9czKIX4TLc4', // Machine Chest Press
      ];

      const maleExclusions = <String>[
        'eyh76KELuuO805rZBpMa', // 45 Degree Hip Extension
      ];

// Compute Block 3 exercises dynamically
      final block3ExerciseIds = <String>{
        ...seededExerciseIds.where(
              (id) => !(isFemale ? femaleExclusions : maleExclusions).contains(id),
        ),
        ...(isFemale ? femaleAdditions : maleAdditions),
      }.toList(growable: false);



      // Helper to build a block payload (lightweight sentinel — no full exercise arrays)
      Map<String, dynamic> buildBlock({
        required String name,
        required bool isActive,
        required DateTime start,
        required DateTime end,
        required List<String> candidateExerciseIds,
      }) {
        return {
          'name': name,
          'isActive': isActive,
          'createdAt': Timestamp.now(),
          'startDate': Timestamp.fromDate(start),
          'endDate': Timestamp.fromDate(end),
          'selectedDays': ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],
          'allExercisesAvailable': true,
          'excludedExerciseIds': <String>[],
          'templateCandidateExerciseIds': candidateExerciseIds,
          'plannedExerciseDetails': {
            'blockMeta': {
              'blockStartDate': start.toIso8601String(),
              'blockEndDate': end.toIso8601String(),
              'selectedDays': ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],
            }
          },
        };
      }

      // ── Create Block 1 (active) ─────────────────────────────────────────────
      final block1Payload = buildBlock(
        name: block1Name,
        isActive: true,
        start: startDate1,
        end: endDate1,
        candidateExerciseIds: candidateIds,
      );

      final swCreate1 = Stopwatch()..start();
      final block1Ref = await blocksRef.add(block1Payload);
      swCreate1.stop();
      final block1Id = block1Ref.id;
      print('✅ [Home] Block 1 created id=$block1Id (${swCreate1.elapsed.inMilliseconds} ms)');

      if (mounted) {
        Provider.of<UserContext>(context, listen: false).applyBlockMeta(
          uid: uid,
          activeBlockId: block1Id,
          startDate: startDate1,
          endDate: endDate1,
        );
      }

      await BlockExerciseDefaultsRepository.seedDefaultsForBlock(
        uid: uid,
        blockId: block1Id,
        exerciseIds: seededExerciseIds,
      );


      // Pointer write to current_block → Block 1
      final swPtr = Stopwatch()..start();
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('block_planner')
          .doc('current_block')
          .set({
        'blockId': block1Id,
        'blockName': block1Name,
        'templateCandidateExerciseIds': candidateIds,
        'plannedExerciseDetails': {
          'blockMeta': {
            'blockStartDate': startDate1.toIso8601String(),
            'blockEndDate': endDate1.toIso8601String(),
            'selectedDays': ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],
          }
        },
        'blockMeta': {
          'blockStartDate': startDate1.toIso8601String(),
          'blockEndDate': endDate1.toIso8601String(),
        },
      }, SetOptions(merge: true));
      swPtr.stop();
      print('📌 [Home] Set current_block pointer → $block1Id (${swPtr.elapsed.inMilliseconds} ms)');

      // Eagerly write week_0 (1 week doc + 7 day docs) so WES2/BB3 can read
      // the current week immediately without waiting for the full scaffold.
      {
        const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        const weekdays = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
        final week0Ref = block1Ref.collection('weeks').doc('week_0');
        final eagerBatch = FirebaseFirestore.instance.batch();
        eagerBatch.set(week0Ref, {'exists': true}, SetOptions(merge: true));
        for (int day = 0; day < 7; day++) {
          final date = startDate1.add(Duration(days: day));
          eagerBatch.set(week0Ref.collection('days').doc('day_$day'), {
            'date': Timestamp.fromDate(date),
            'circuitStartIndices': [0],
            'exercises': [],
            'workoutName': '${weekdays[day]} ${date.day} ${months[date.month - 1]} - Week 1',
            'exists': true,
          }, SetOptions(merge: true));
        }
        await eagerBatch.commit();
        debugPrint('🧱 [Home] Block 1 week_0 ready (eager)');
      }
      // Defer weeks 1–25 for Block 1 to background (already usable via week_0).
      unawaited(scaffoldBlockInBackground(block1Ref, startDate1, startWeek: 1));

      // ── Create Block 2 (upcoming, not active) ───────────────────────────────
      final block2Payload = buildBlock(
        name: block2Name,
        isActive: false,
        start: startDate2,
        end: endDate2,
        candidateExerciseIds: candidateIds,
      );

      final swCreate2 = Stopwatch()..start();
      final block2Ref = await blocksRef.add(block2Payload);
      swCreate2.stop();
      final block2Id = block2Ref.id;
      print('✅ [Home] Block 2 created id=$block2Id (${swCreate2.elapsed.inMilliseconds} ms)');

      // Defer Block 2 seed + full scaffold to background — block doc is already created.
      unawaited(() async {
        try {
          await BlockExerciseDefaultsRepository.seedDefaultsForBlock(
            uid: uid,
            blockId: block2Id,
            exerciseIds: block2ExerciseIds,
          );
          await scaffoldBlockInBackground(block2Ref, startDate2);
        } catch (e, st) {
          debugPrint('❌ [Home] Block 2 background init failed: $e\n$st');
        }
      }());

      debugPrint('🧪[B3 pre-add] seed=${seededExerciseIds.length} adj=${block3ExerciseIds.length} '
          'hasAdd(EFbQl9i9NdYi13F3DqHr)=${block3ExerciseIds.contains('EFbQl9i9NdYi13F3DqHr')} '
          'hasEx(eyh76KELuuO805rZBpMa)=${block3ExerciseIds.contains('eyh76KELuuO805rZBpMa')}');

      // ── Create Block 3 (upcoming, not active) ─────────────────────────────────────
      final block3Name = (username != null && username.isNotEmpty)
          ? "${username}'s 3rd Block"
          : "3rd Block";

      final block3Payload = buildBlock(
        name: block3Name,
        isActive: false,
        start: startDate3,
        end: endDate3,
        candidateExerciseIds: candidateIds,
      );

      final swCreate3 = Stopwatch()..start();
      final block3Ref = await blocksRef.add(block3Payload);
      swCreate3.stop();
      final block3Id = block3Ref.id;
      print('✅ [Home] Block 3 created id=$block3Id (${swCreate3.elapsed.inMilliseconds} ms)');

      // Defer Block 3 seed + full scaffold to background — block doc is already created.
      unawaited(() async {
        try {
          await BlockExerciseDefaultsRepository.seedDefaultsForBlock(
            uid: uid,
            blockId: block3Id,
            exerciseIds: block3ExerciseIds,
          );
          await scaffoldBlockInBackground(block3Ref, startDate3);
        } catch (e, st) {
          debugPrint('❌ [Home] Block 3 background init failed: $e\n$st');
        }
      }());

    }



    swTotal.stop();
    print('⏱️ [Home] _ensureAtLeastOneBlockExists total: ${swTotal.elapsed.inMilliseconds} ms');
  }







  void _onUserContextChange() {
    final uc = Provider.of<UserContext>(context, listen: false);
    final newUid = uc.actingAsUid;

    if (newUid != _lastWarmUid) {
      _lastWarmUid = newUid;

      // Keep your existing warm
      unawaited(WarmupService.instance.warmWES(newUid));

      // ✅ Roll-forward + RIR heal after switch (post-frame so block meta has a chance to hydrate)
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final bid = uc.activeBlockId;
        if (bid != null && bid.isNotEmpty) {
          await _rollForwardMissedBB2Plans(uid: newUid, blockId: bid);
          unawaited(BlockExerciseDefaultsRepository.healActiveBlockRirPlan(
            uid: newUid,
            blockId: bid,
          ));
        } else {
          debugPrint('⚠️ [ROLL] skip on switch: activeBlockId missing');
        }
      });
    }
  }


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_ucBound) {
      _uc = context.read<UserContext>(); // ✅ safe here
      _ucBound = true;
      _uc.addListener(_onUserContextChange); // ✅ (also ensures you're actually listening)
    }

    _loadAthleteEmail(); // 👈 this line ensures _actingAsEmail is set
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route); // 👈 subscribe
    }
    // First time this page becomes active → schedule a one-shot warmup post-frame
    if (!_bb2WarmupScheduled) {
      _bb2WarmupScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final userContext = UserContext.maybeOf(context, listen: false);
        if (userContext == null) {
          debugPrint('🟥 [HOME:initState] UserContext not found above HomeScreen (provider scope issue).');
          return;
        }
        final actingUid = userContext.actingAsUid.isNotEmpty
            ? userContext.actingAsUid
            : userContext.actorUid;

        debugPrint('🏁 [HOME] First-show: schedule WarmupBB2 for $actingUid');
        if (actingUid.isNotEmpty) {
          unawaited(WarmupBB2.runForActiveBlock(uid: actingUid));
        }
      });
    }
  }

  @override
  void dispose() {
    // Stop listening to UserContext changes (don't use context in dispose)
    if (_ucBound) {
      _uc.removeListener(_onUserContextChange);
    }


    // Unsubscribe from route observer
    routeObserver.unsubscribe(this);

    // Cancel Firestore listener for active block changes
    _activeBlockSub?.cancel();

    // Scroll controllers
    _homeScrollCtrl.removeListener(_onHomeScroll);
    _homeScrollCtrl.dispose();

    _pointsScrollCtrl.removeListener(_onPointsScroll);
    _pointsScrollCtrl.dispose();

    debugPrint('🏠 [HOME] dispose() called');
    super.dispose();
  }


  @override
  void didPopNext() {
    if (!mounted) return;

    // Run after the current frame so the tree is stable again
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      // Refresh onboarding cue (picks up wpDemoComplete if just set in Templates)
      unawaited(_loadOnboardingState());

      // 🟢 Existing logic — re-fetch whichever feed is active
      if (_feedOwnersResolved) {
        if (_selectedFeed == SelectedFeed.home) {
          await _loadInitialHomeFeed();
        } else {
          await _loadInitialPointsFeed();
        }
      }

      // 🔥 Warm up BB2 cache on resume
      final userContext = Provider.of<UserContext>(context, listen: false);
      final actingUid = userContext.actingAsUid;
      debugPrint('🔁 [HOME] didPopNext: resume WarmupBB2 for $actingUid');
      if (actingUid.isNotEmpty) {
        unawaited(WarmupBB2.runForActiveBlock(uid: actingUid));
      }
    });
  }


//Home FEED functions
  Future<void> _loadInitialHomeFeed() async {
    if (!_feedOwnersResolved) return;
    setState(() {
      _feedLoading = false;
      _feedHasMore = true;
      _feedError = false;
      _feedPosts = [];
      _lastCreatedAt = null;
    });
    await _loadMoreHomeFeed();
  }

  Future<void> _loadMoreHomeFeed() async {
    if (_feedLoading || !_feedHasMore || _feedOwnerUids.isEmpty) return;

    // capture scroll metrics BEFORE we change state
    final hadClients = _homeScrollCtrl.hasClients;
    final prevOffset = hadClients ? _homeScrollCtrl.offset : 0.0;

    setState(() {
      _feedLoading = true;
      _feedError = false;
    });

    try {
      Query<Map<String, dynamic>> q = FirebaseFirestore.instance
          .collection('posts')
          .where('ownerUid', whereIn: _feedOwnerUids)
          .orderBy('createdAt', descending: true)
          .limit(_kFeedPageSize);

      if (_lastCreatedAt != null) {
        q = q.startAfter([_lastCreatedAt]);
      }
      final qs = await q.get();
      final docs = qs.docs;

// 👀 Count items that will actually render on Home
      final int _renderableThisPage = docs.where((d) {
        final m = d.data();
        final t = m['type'];
        if (t != 're_daily') return true; // media always renders on Home
        // re_daily renders on Home only when current gates pass:
        final promoted = (m['promoteToHome'] as bool?) == true;
        final badges = (m['badges'] as List?) ?? const [];
        final total = (m['dailyTotal'] as num?)?.toDouble() ?? 0.0;
        return promoted && badges.isNotEmpty && total > 0.0;
      }).length;

// Update cursor BEFORE deciding to prefetch
      if (docs.isNotEmpty) {
        final last = docs.last.data();
        final ts = (last['createdAt'] as Timestamp?);
        _lastCreatedAt = ts ?? _lastCreatedAt;
      }
// 🚀 If nothing on this page would render, prefetch the next page immediately
      if (_renderableThisPage == 0 && docs.isNotEmpty && docs.length >= _kFeedPageSize) {
        _feedLoading = false; // allow re-entry past the guard
        await _loadMoreHomeFeed();
        return;
      }

      final newPosts = <Post>[];
      for (final d in docs) {
        try {
          newPosts.add(Post.fromSnap(d));
        } catch (e) {
        }
      }
      if (docs.isNotEmpty) {
        final last = docs.last.data();
        final ts = (last['createdAt'] as Timestamp?);
        _lastCreatedAt = ts ?? _lastCreatedAt;
      }
      setState(() {
        _feedPosts.addAll(newPosts);
        _feedHasMore = docs.length >= _kFeedPageSize;
        _feedLoading = false;
      });
      // if nothing new, restore scroll offset so the view doesn't “jump”
      if (hadClients && docs.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_homeScrollCtrl.hasClients) {
            _homeScrollCtrl.jumpTo(prevOffset);
          }
        });
      }
    } on FirebaseException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Feed error: ${e.code}')),
        );
      }
      setState(() {
        _feedError = true;
        _feedLoading = false;
        _feedHasMore = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Feed failed to load: $e')));
      }
      setState(() {
        _feedError = true;
        _feedLoading = false;
        _feedHasMore = false;
      });
    }
  }

  Future<void> _loadInitialPointsFeed() async {
    if (!_feedOwnersResolved) return;
    setState(() {
      _pointsLoading = false;
      _pointsHasMore = true;
      _pointsPosts = [];
      _lastPointsCreatedAt = null;
    });
    await _loadMorePointsFeed();
  }

  Future<void> _loadMorePointsFeed() async {
    if (_pointsLoading || !_pointsHasMore || _feedOwnerUids.isEmpty) return;
    _pointsLoading = true;
    try {
      // Base query: owners + createdAt desc (no composite index requirements)
      Query<Map<String, dynamic>> q = FirebaseFirestore.instance
          .collection('posts')
          .where('ownerUid', whereIn: _feedOwnerUids)
          .orderBy('createdAt', descending: true)
          .limit(_kFeedPageSize * 2); // slight overfetch to survive filtering

      if (_lastPointsCreatedAt != null) {
        q = q.startAfter([_lastPointsCreatedAt]);
      }

      final qs = await q.get();
      final docs = qs.docs;

      // Update cursor/hasMore from raw page
      if (docs.isNotEmpty) {
        _lastPointsCreatedAt =
            (docs.last.data()['createdAt'] as Timestamp?) ?? _lastPointsCreatedAt;
      }
      _pointsHasMore = docs.length >= _kFeedPageSize * 2;

      // Client-side filter: only re_daily, >0 points, and (optional) month window
      DateTime? monthStart;
      DateTime? monthEnd;
      if ((_pointsMonthKey).isNotEmpty) {
        final start = DateTime.parse('$_pointsMonthKey-01');
        final end = (start.month == 12)
            ? DateTime(start.year + 1, 1, 1)
            : DateTime(start.year, start.month + 1, 1);
        monthStart = start;
        monthEnd = end;
      }
      final filtered = <Post>[];
      for (final d in docs) {
        Post? p;
        try {
          p = Post.fromSnap(d);
        } catch (_) {}
        if (p == null) continue;

        if ((p.type ?? '') != 're_daily') continue;

        // Cheap additional check: require positive dailyTotal to avoid empty cards
        final m = d.data();
        final total = (m['dailyTotal'] as num?)?.toDouble() ?? 0.0;
        if (total <= 0.0) continue;

        if (monthStart != null && monthEnd != null) {
          final created = p.createdAt.toDate();
          if (!(created.isAfter(monthStart.subtract(const Duration(milliseconds: 1))) &&
              created.isBefore(monthEnd))) {
            continue;
          }
        }

        filtered.add(p);
        if (filtered.length >= _kFeedPageSize) break; // cap to page size
      }

      setState(() {
        _pointsPosts.addAll(filtered);
      });

      // If we filtered out everything but still have more raw docs, fetch next page
      if (filtered.isEmpty && _pointsHasMore) {
        await _loadMorePointsFeed();
      }
    } catch (e) {
      _pointsHasMore = false;
    } finally {
      _pointsLoading = false;
    }
  }

  void _onPointsScroll() {
    if (!_pointsScrollCtrl.hasClients || _pointsLoading || !_pointsHasMore) return;
    final pos = _pointsScrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) {
      _loadMorePointsFeed();
    }
  }

// Trigger more when near bottom of outer scroll view
  void _onHomeScroll() {
    if (!_homeScrollCtrl.hasClients) return;
    final pos = _homeScrollCtrl.position;
    final shouldPrefetch = pos.maxScrollExtent - pos.pixels < 600;

    if (shouldPrefetch && !_feedLoading && _feedHasMore && !_loadMoreScheduled) {
      _loadMoreScheduled = true;
      Future.microtask(() async {
        try {
          await _loadMoreHomeFeed();

        } finally {
          _loadMoreScheduled = false;
        }
      });
    }
  }

  Future<void> _resolveFeedOwners() async {
    // If this widget is already gone, do nothing.
    if (!mounted) return;

    final uc = UserContext.of(context, listen: false);
    final viewerUid = uc.currentUid; // currentUid is non-nullable String in your UserContext
    final owners = <String>{};

    if (viewerUid.isNotEmpty) {
      owners.add(viewerUid);
    }

    try {
      final d = await FirebaseFirestore.instance
          .collection('buddyAssignments')
          .doc(viewerUid)
          .get();

      // You might get disposed while awaiting Firestore.
      if (!mounted) return;

      final data = d.data() ?? const <String, dynamic>{};
      final athletesMap = (data['athletes'] is Map)
          ? Map<String, dynamic>.from(data['athletes'] as Map)
          : const <String, dynamic>{};

      // Only include confirmed (accepted) friends in the home feed.
      // Pending requests must not surface social content before acceptance.
      athletesMap.forEach((uid, val) {
        if (val is Map && val['status'] == 'accepted') {
          owners.add(uid);
        }
      });
    } catch (e) {
      // Optional: log it, but don't crash
      debugPrint('⚠️ [HOME] _resolveFeedOwners failed: $e');
      if (!mounted) return;
    }

    if (!mounted) return;
    setState(() {
      _feedOwnerUids = owners.toList();
      _feedOwnersResolved = true;
    });
  }


// cleaning function
  Future<void> cleanAndSyncExercisesInFirestore() async {
    final FirebaseFirestore firestore = FirebaseFirestore.instance;
    final CollectionReference exercisesRef = firestore.collection('exercises');

    // 🔍 1. Fetch all current exercises
    final snapshot = await exercisesRef.get();
    final existingDocs = snapshot.docs;

    // 🔥 2. Delete any docs that used exercise name as doc ID
    for (final doc in existingDocs) {
      final id = doc.id;
      final data = doc.data() as Map<String, dynamic>?;

      // If the doc ID is the same as the 'name' field, it's likely incorrectly added
      if (data != null && data['name'] == id) {
        await doc.reference.delete();
      }
    }

    // 🔁 3. Get fresh list of existing names (after cleanup)
    final refreshedSnapshot = await exercisesRef.get();
    final existingNames = refreshedSnapshot.docs
        .map((doc) => (doc.data() as Map<String, dynamic>?)?['name']?.toLowerCase().trim())
        .whereType<String>()
        .toSet();

    // ➕ 4. Add any missing core exercises
    for (final core in coreExercises) {
      final name = core['name']?.toLowerCase().trim();
      if (name != null && !existingNames.contains(name)) {
        await exercisesRef.add({
          'name': core['name'],
          'category': core['category'] ?? '',
          'bodyPart': core['bodyPart'] ?? '',
        });

      }
    }
  }


  Future<void> _loadAthleteEmail() async {
    final uid = Provider.of<UserContext>(context, listen: false).actingAsUid;
    final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final data = snap.data();
    if (!mounted || data == null) return;

    String? pick(dynamic v) {
      final s = (v ?? '').toString().trim();
      return s.isEmpty ? null : s;
    }

    final chosen =
        pick(data['username']) ??      // ✅ username first
            pick(data['displayName']) ??   // fallback to display name
            pick(data['email']) ??         // fallback to email
            'Unknown';

    setState(() => _actingAsEmail = chosen);
  }

  Future<void> _fetchTrainingDaysForMonth(DateTime month) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      // 1️⃣ Get the active block doc
      final blockDoc = await _fetchActiveBlock();
      final data = blockDoc.data() as Map<String, dynamic>;

      // 2️⃣ Read the start/end Timestamps
      final Timestamp startTs = data['startDate'];
      final Timestamp endTs = data['endDate'];
      final DateTime blockStart = startTs.toDate();
      final DateTime blockEnd = endTs.toDate();

      // 3️⃣ Read the list of weekdays (Mon, Tue, …) that your user chose
      final List<dynamic> blockDays =
          data['selectedDays'] ?? data['daysOfWeek'] ?? [];

      // Map your string codes to Dart weekday ints
      final daysOfWeekMap = {
        'Mon': DateTime.monday,
        'Tue': DateTime.tuesday,
        'Wed': DateTime.wednesday,
        'Thu': DateTime.thursday,
        'Fri': DateTime.friday,
        'Sat': DateTime.saturday,
        'Sun': DateTime.sunday,
      };
      final Set<int> blockWeekdays = blockDays
          .map((d) => daysOfWeekMap[d.toString()])
          .whereType<int>()
          .toSet();

      // 4️⃣ Limit iteration to the visible month, but clipped to [blockStart, blockEnd]
      final firstOfMonth = DateTime(month.year, month.month, 1);
      final lastOfMonth = DateTime(month.year, month.month + 1, 0);

      final from = firstOfMonth.isAfter(blockStart) ? firstOfMonth : blockStart;
      final to = lastOfMonth.isBefore(blockEnd) ? lastOfMonth : blockEnd;

      final trainingDays = <DateTime>{};
      for (var day = from;
          !day.isAfter(to);
          day = day.add(const Duration(days: 1))) {
        if (blockWeekdays.contains(day.weekday)) {
          trainingDays.add(DateTime(day.year, day.month, day.day));
        }
      }

      setState(() => _trainingDays = trainingDays);
    } catch (e) {
    }
  }

  Future<void> _fetchRecentData() async {
    await Future.wait([
      _fetchMostRecentWeight(),
      _fetchMostRecentWorkout(),
    ]);
    if (!mounted) return;
    setState(() {
      isLoading = false;
    });
  }


  Future<void> _fetchMostRecentWeight() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final userId = user.uid;
        final snapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .collection('weights')
            .orderBy('timestamp', descending: true)
            .limit(1)
            .get();

        if (snapshot.docs.isNotEmpty) {
          final weightData = snapshot.docs.first.data();
          mostRecentWeight = '${weightData['weight']} ${weightData['unit']}';
        }
      }
    } catch (error) {
      errorMessage = 'Failed to load recent weight: $error';
    }
  }

  Future<void> _fetchMostRecentWorkout() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final querySnapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('workouts')
            .orderBy('date', descending: true)
            .limit(1)
            .get();

        if (querySnapshot.docs.isNotEmpty) {
          final doc = querySnapshot.docs.first;
          final data = doc.data();

          mostRecentWorkout = Workout(
            name: data['name'] ?? 'Unnamed Workout',
            date: data['date'] is Timestamp
                ? (data['date'] as Timestamp).toDate()
                : DateTime.parse(data['date']),
            exercises: (data['exercises'] as List<dynamic>).map((exercise) {
              final exerciseData = exercise as Map<String, dynamic>;
              return Exercise(
                name: exerciseData['name'] ?? 'Unnamed Exercise',
                sets: (exerciseData['sets'] as List<dynamic>).map((set) {
                  final setData = set as Map<String, dynamic>;
                  return SetDetails(
                    reps: (setData['reps'] is num)
                        ? setData['reps'] as int
                        : int.tryParse(setData['reps'].toString()) ?? 0,
                    weight: (setData['weight'] is num)
                        ? (setData['weight'] as num).toDouble()
                        : double.tryParse(setData['weight'].toString()) ?? 0.0,
                    rir: (setData['rir'] is num)
                        ? (setData['rir'] as num).toDouble()
                        : double.tryParse(setData['rir'].toString()) ?? 0.0,
                  );
                }).toList(),
              );
            }).toList(),
          );
        }
      }
    } catch (error) {
      setState(() {
        errorMessage = 'Failed to load recent workout: $error';
      });
    }
  }

  Future<DocumentSnapshot<Object?>> _fetchActiveBlock() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) {
      throw Exception('User not logged in');
    }

    final query = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .where('isActive', isEqualTo: true)
        .limit(1)
        .get();

    if (query.docs.isNotEmpty) {
      return query.docs.first;
    } else {
      throw Exception('No active block found');
    }
  }

  Future<void> _loadOnboardingState() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || !mounted) return;
    final done = await OnboardingPrefs.getWpDone(uid);
    if (!mounted) return;
    setState(() => _wpDone = done);
  }

  Widget _buildQACard({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? iconColor,
    Widget? iconWidget,
  }) {
    return SizedBox(
      width: kFeatureCardWidth,
      height: 130,
      child: GestureDetector(
        onTap: onTap,
        child: Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  child: iconWidget ??
                      Icon(icon, size: 44,
                          color: iconColor ?? Theme.of(context).colorScheme.secondary),
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  left: 44,
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.3,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQAColumn(Widget top, Widget bottom) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [top, const SizedBox(height: 8), bottom],
    );
  }


  @override
  Widget build(BuildContext context) {
    final uc = context.watch<UserContext>();
    final dmUid = uc.currentUid;

    return Scaffold(

      key: _scaffoldKey,
      appBar: AppBar(
        title: null,
        automaticallyImplyLeading: false,
        actions: [
      Flexible(
      child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 15),
            // 👤 Logged-in / impersonated user banner
            Padding(
              padding: const EdgeInsets.only(right: 1.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [

                  SizedBox(
                    width: 95, // max width
                    child: Text(
                      _actingAsEmail ?? '...',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        overflow: TextOverflow.ellipsis,
                      ),
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),

              // 👤 Profile picture (Home)
              Material(
                color: Colors.transparent,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    final userContext = context.read<UserContext>();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChangeNotifierProvider<UserContext>.value(
                          value: userContext,
                          child: const ProfilePage(),
                        ),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(2.0),
                    child: Builder(
                      builder: (context) {
                        final uc = context.watch<UserContext>();
                        final actingUid = uc.actingAsUid;

                        // 1) Prefer local file if present (fast path)
                        ImageProvider? localAvatar;
                        if (uc.localPhotoPath != null) {
                          final f = File(uc.localPhotoPath!);
                          if (f.existsSync()) localAvatar = FileImage(f);
                        }

                        // 2) If we DO have a local file, render it and skip the stream entirely
                        if (localAvatar != null) {
                          return CircleAvatar(
                            radius: 18,
                            backgroundColor: Colors.grey.shade300,
                            backgroundImage: localAvatar,
                          );
                        }

                        // 3) Otherwise, live-listen to users_public/{actingUid} for photoURL
                        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                          stream: FirebaseFirestore.instance
                              .collection('users_public')
                              .doc(actingUid)
                              .snapshots(),
                          builder: (context, snap) {
                            final uc = context.watch<UserContext>();
                            final uid = actingUid;

                            // Extract photoURL from users_public
                            String? photoURL;
                            if (snap.hasData && snap.data!.data() != null) {
                              final m = snap.data!.data()!;
                              final v = m['photoURL'];
                              if (v is String && v.isNotEmpty) photoURL = v;
                            }

                            // If we don't already have a good local file, persist one in the background.
                            if ((uc.localPhotoPath == null || !(File(uc.localPhotoPath!).existsSync())) &&
                                photoURL != null) {
                              _persistAvatarLocalIfNeeded(context, uid: uid, photoURL: photoURL);
                            }

                            // Prefer local file instantly; fallback to network; else placeholder.
                            ImageProvider? provider;
                            if (uc.localPhotoPath != null) {
                              final f = File(uc.localPhotoPath!);
                              if (f.existsSync()) provider = FileImage(f);
                            }
                            provider ??= (photoURL != null ? NetworkImage(photoURL) : null);

                            return CircleAvatar(
                              radius: 18,
                              backgroundColor: Colors.grey.shade300,
                              backgroundImage: provider,
                              child: provider == null
                                  ? ClipOval(
                                child: Image.asset(
                                  'assets/InApp/Placeholder_profilepic.png',
                                  fit: BoxFit.cover,
                                  width: 36,
                                  height: 36,
                                ),
                              )
                                  : null,
                            );
                          },
                        );

                      },
                    ),
                  ),

                ),
              ),


            const SizedBox(width: 1),

            // Buddy invite notifications
            Builder(
              builder: (context) {
                final userCtx = context.watch<UserContext>();
                final String invitesUid = userCtx.actingAsUid;

                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('users')
                      .doc(invitesUid)
                      .collection('buddyInvites')
                      .where('status', isEqualTo: 'pending')
                      .snapshots(),
                  builder: (context, snapshot) {
                    final int buddyCount =
                    snapshot.hasData ? snapshot.data!.docs.length : 0;

                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        IconButton(
                          icon: Icon(Icons.person_add_alt_1,
                              size: 24, color: Theme.of(context).colorScheme.secondary),
                          onPressed: () {
                            if (!snapshot.hasData ||
                                snapshot.data!.docs.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text("No buddy requests.")),
                              );
                              return;
                            }

                            showDialog(
                              context: context,
                              builder: (ctx) {
                                return AlertDialog(
                                  title: const Text("Buddy Requests"),
                                  content: SizedBox(
                                    width: 310,
                                    child: ListView.builder(
                                      shrinkWrap: true,
                                      itemCount:
                                      snapshot.data!.docs.length,
                                      itemBuilder: (_, i) {
                                        final doc =
                                        snapshot.data!.docs[i];
                                        final data = doc.data()
                                        as Map<String, dynamic>;

                                        final fromUid =
                                            data['fromUid'] ?? '';
                                        final fromName =
                                            data['fromDisplayName'] ??
                                                'Someone';

                                        return Column(
                                          crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              "$fromName added you!",
                                              style: const TextStyle(
                                                  fontWeight:
                                                  FontWeight.bold),
                                            ),
                                            const SizedBox(height: 6),
                                            Row(
                                              children: [
                                                TextButton(
                                                  onPressed: () async {
                                                    await acceptBuddyInvite(
                                                      ownerUid: fromUid,
                                                      buddyUid: invitesUid,
                                                    );
                                                    Navigator.pop(ctx);
                                                  },
                                                  child:
                                                  const Text("Accept"),
                                                ),
                                                const SizedBox(width: 12),
                                                TextButton(
                                                  onPressed: () async {
                                                    await denyBuddyInvite(
                                                      ownerUid: fromUid,
                                                      buddyUid: invitesUid,
                                                    );
                                                    Navigator.pop(ctx);
                                                  },
                                                  child:
                                                  const Text("Deny"),
                                                ),
                                              ],
                                            ),
                                            const Divider(),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),

                        if (buddyCount > 0)
                          Positioned(
                            right: 6,
                            top: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 3, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                buddyCount.toString(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
            ),

            const SizedBox(width: 1),

              // 📩 Direct Messages icon with unread badge
              StreamBuilder<QuerySnapshot>(
                stream: dmUid.isEmpty
                    ? const Stream<QuerySnapshot>.empty()
                    : FirebaseFirestore.instance
                    .collection('conversations')
                    .where('participants.$dmUid', isEqualTo: true)
                    .snapshots(),

                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return IconButton(
                      icon: Icon(
                        Icons.message_outlined,
                        size: 26,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const DirectMessages(),
                          ),
                        );
                      },
                    );
                  }

                  int unreadCount = 0;

                  final me = FirebaseAuth.instance.currentUser?.uid;

                  if (snapshot.hasData && me != null) {
                    for (var doc in snapshot.data!.docs) {
                      final data = doc.data() as Map<String, dynamic>;

                      final state = data['participantState']?[me];
                      final count = (state is Map && state['unreadCount'] is int)
                          ? state['unreadCount'] as int
                          : 0;

                      unreadCount += count;
                    }
                  }


                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      IconButton(
                        icon: Icon(Icons.message_outlined, size: 26, color: Theme.of(context).colorScheme.secondary),
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const DirectMessages(),
                            ),
                          );
                        },
                      ),
                      if (unreadCount > 0)
                        Positioned(
                          right: 6,
                          top: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              unreadCount.toString(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );

                },
              ),

              const SizedBox(width: 1),

              // App logo
              Image.asset(
                'assets/InApp/transparent_good_lift_logo_inApp.png',
                height: 36,
                fit: BoxFit.contain,
              ),
              const SizedBox(width: 2),

              // Menu icon
              GestureDetector(
                onTap: () => _scaffoldKey.currentState?.openDrawer(),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 3.0),
                  child: Icon(
                    Icons.menu,
                    size: 28,
                    color: Colors.grey,
                  ),
                ),
              ),
            ],
          ),
      ),
      ),
        ],
      ),


      //backgroundImage: AssetImage('assets/avatar.png'),

      drawer: const AppDrawer(),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : errorMessage.isNotEmpty
              ? Center(child: Text(errorMessage))
              : SingleChildScrollView(
                  controller: _homeScrollCtrl, // 👈 add this
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      //Quick Access — two-row synchronized horizontal scroll
                      SizedBox(
                        height: !_wpDone ? 296.0 : 280.0,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Column 1: Enter Workout / Body Weight Tracker
                              _buildQAColumn(
                                _buildQACard(
                                  icon: Icons.fitness_center,
                                  label: 'Enter\nWorkout',
                                  onTap: () {
                                    final uc = UserContext.of(context, listen: false);
                                    Navigator.push(context, MaterialPageRoute(
                                      builder: (_) => ChangeNotifierProvider<UserContext>.value(
                                        value: uc, child: const Wes2Screen()),
                                    ));
                                  },
                                  iconWidget: SizedBox(
                                    width: 52, height: 56,
                                    child: Stack(clipBehavior: Clip.none, children: [
                                      Icon(Icons.fitness_center, size: 44,
                                          color: Theme.of(context).colorScheme.secondary),
                                      Positioned(right: -2, bottom: -2,
                                          child: Icon(Icons.bolt, size: 20,
                                              color: Theme.of(context).colorScheme.tertiary)),
                                    ]),
                                  ),
                                ),
                                _buildQACard(
                                  icon: Icons.monitor_weight,
                                  label: 'Body\nWeight\nTracker',
                                  onTap: () => Navigator.pushNamed(context, '/body_weight'),
                                ),
                              ),
                              // Column 2: Workout Planner / Profile
                              _buildQAColumn(
                                _GlowingCueWrapper(
                                  active: !_wpDone,
                                  label: 'Tap here first',
                                  child: _buildQACard(
                                    icon: Icons.view_list,
                                    label: 'Workout\nPlanner',
                                    onTap: () {
                                      final uc = UserContext.of(context, listen: false);
                                      Navigator.push(context, MaterialPageRoute(
                                        builder: (_) => ChangeNotifierProvider<UserContext>.value(
                                          value: uc, child: const TemplatesScreen()),
                                      ));
                                    },
                                  ),
                                ),
                                _buildQACard(
                                  icon: Icons.person_outline,
                                  label: 'Profile',
                                  onTap: () {
                                    final uc = UserContext.of(context, listen: false);
                                    Navigator.of(context).push(MaterialPageRoute(
                                      builder: (_) => ChangeNotifierProvider<UserContext>.value(
                                        value: uc, child: const ProfilePage()),
                                    ));
                                  },
                                ),
                              ),
                              // Column 3: Planned Blocks / Week Planner
                              _buildQAColumn(
                                _buildQACard(
                                  icon: Icons.track_changes,
                                  label: 'Planned\nBlocks',
                                  onTap: () {
                                    final uc = UserContext.of(context, listen: false);
                                    Navigator.of(context).push(MaterialPageRoute(
                                      builder: (_) => ChangeNotifierProvider<UserContext>.value(
                                        value: uc, child: const PlannedBlocksScreen()),
                                    ));
                                  },
                                ),
                                _buildQACard(
                                  icon: Icons.calendar_view_week,
                                  label: 'Week\nPlanner',
                                  onTap: () {
                                    final uc = UserContext.of(context, listen: false);
                                    Navigator.push(context, MaterialPageRoute(
                                      builder: (_) => ChangeNotifierProvider<UserContext>.value(
                                        value: uc, child: const BB3WeekPlanner()),
                                    ));
                                  },
                                ),
                              ),
                              // Column 4: Settings / Coach Dashboard (coach only)
                              _buildQAColumn(
                                _buildQACard(
                                  icon: Icons.settings_outlined,
                                  label: 'Settings',
                                  onTap: () {
                                    final uc = UserContext.of(context, listen: false);
                                    Navigator.of(context).push(MaterialPageRoute(
                                      builder: (_) => ChangeNotifierProvider<UserContext>.value(
                                        value: uc, child: const UserSettingsScreen()),
                                    ));
                                  },
                                ),
                                UserContext.of(context).isCoach
                                  ? _buildQACard(
                                      icon: Icons.supervisor_account,
                                      label: 'Coach\nDashboard',
                                      iconColor: Colors.amberAccent,
                                      onTap: () {
                                        final uc = context.read<UserContext>();
                                        Navigator.of(context).push(MaterialPageRoute(
                                          builder: (_) => ChangeNotifierProvider<UserContext>.value(
                                            value: uc, child: const CoachHomeScreen()),
                                        ));
                                      },
                                    )
                                  : const SizedBox(width: kFeatureCardWidth, height: 130),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 8),
                      const Text(
                        'Training Calendar',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                        TableCalendar(
                          firstDay: DateTime.utc(2020, 1, 1),
                          lastDay: DateTime.utc(2100, 12, 31),
                          focusedDay: _focusedDay,
                          calendarFormat: CalendarFormat.month,
                          availableCalendarFormats: const {
                            CalendarFormat.month: 'Month',
                          }, // 🚫 disables switching format
                          headerStyle: const HeaderStyle(
                            formatButtonVisible:
                                false, // ❌ hides the format toggle
                            titleCentered: true,
                          ),
                          selectedDayPredicate: (day) =>
                              isSameDay(_selectedDay, day),
                          eventLoader: (day) {
                            final normalized =
                                DateTime(day.year, day.month, day.day);
                            return _trainingDays.contains(normalized)
                                ? [1]
                                : [];
                          },
                          onDaySelected: (selectedDay, focusedDay) {
                            setState(() {
                              _selectedDay = selectedDay;
                              _focusedDay = focusedDay;
                            });

                            final userContext = UserContext.of(context, listen: false);

                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChangeNotifierProvider<UserContext>.value(
                                  value: userContext,
                                  child: Wes2Screen(initialDate: selectedDay),
                                ),
                              ),
                            );
                          },
                          onPageChanged: (focusedDay) {
                            setState(() {
                              _focusedDay = focusedDay;
                            });
                            _fetchTrainingDaysForMonth(
                                focusedDay); // 🔄 refresh for new month
                          },
                          calendarBuilders: CalendarBuilders(
                            defaultBuilder: (context, date, _) {
                              final isTraining = _trainingDays.contains(
                                  DateTime(date.year, date.month, date.day));
                              return Container(
                                margin: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: isTraining
                                      ? Border.all(
                                    color: Theme.of(context).colorScheme.tertiary,
                                    width: 2,
                                  )
                                      : null,
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${date.day}',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              );
                            },
                            todayBuilder: (context, date, _) {
                              // optionally highlight today differently
                              return Container(
                                margin: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white24,
                                  border: Border.all(
                                    color: Theme.of(context).colorScheme.tertiary,
                                    width: 2,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${date.day}',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold),
                                ),
                              );
                            },
                            selectedBuilder: (context, date, _) {
                              return Container(
                                margin: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Theme.of(context).colorScheme.primary,
                                  border: Border.all(
                                      color: Theme.of(context).colorScheme.secondary, width: 2),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${date.day}',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 1),
                        // Simple grey background input

                        // ── Feed Switcher ──────────────────────────────────────────────────────
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // ── Feed switch buttons ───────────────────────────────
                              Row(
                                children: [
                                  SegmentedButton<SelectedFeed>(
                                    showSelectedIcon: false,
                                    segments: const [

                                      ButtonSegment<SelectedFeed>(
                                        value: SelectedFeed.home,
                                        icon: Icon(Icons.photo_library_outlined, size: 16),
                                        label: SizedBox.shrink(), // icon-only
                                      ),
                                      ButtonSegment<SelectedFeed>(
                                        value: SelectedFeed.points,
                                        icon: Icon(Icons.leaderboard_outlined, size: 16),
                                        label: SizedBox.shrink(), // icon-only
                                      ),
                                      ButtonSegment<SelectedFeed>(
                                        value: SelectedFeed.leaderboard,
                                        icon: Icon(Icons.emoji_events_outlined, size: 16),
                                        label: SizedBox.shrink(), // icon-only
                                      ),
                                    ],
                                    selected: <SelectedFeed>{_selectedFeed},
                                    onSelectionChanged: (s) async {

                                      final next = s.first;
                                      if (_selectedFeed == next) return;

                                      setState(() => _selectedFeed = next);
                                      await _persistSelectedFeed();

                                      if (next == SelectedFeed.home) {
                                        if (_feedPosts.isEmpty && !_feedLoading) _loadInitialHomeFeed();
                                      } else if (next == SelectedFeed.points) {
                                        if (_pointsPosts.isEmpty && !_pointsLoading) _loadInitialPointsFeed();
                                      } else { // SelectedFeed.leaderboard
                                        // optional: _pickLeaderboardTagline();
                                      }
                                    },

                                    style: ButtonStyle(
                                      padding: MaterialStateProperty.all(const EdgeInsets.symmetric(horizontal: 6, vertical: 2)),
                                      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                                      side: MaterialStateProperty.resolveWith((states) {
                                        final selected = states.contains(MaterialState.selected);
                                        return BorderSide(color: selected ? Colors.white70 : Colors.white24, width: 1);
                                      }),
                                      backgroundColor: MaterialStateProperty.resolveWith((states) {
                                        final selected = states.contains(MaterialState.selected);
                                        return selected ? Colors.white12 : Colors.transparent;
                                      }),
                                      shape: MaterialStateProperty.all(
                                        RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      foregroundColor: MaterialStateProperty.all(Colors.white),
                                    ),
                                  ),
                                  /*if (_selectedFeed == SelectedFeed.points) ...[
                                    const SizedBox(width: 8),
                                    _MonthPickerChip(
                                      monthKey: _pointsMonthKey,
                                      onChanged: (mk) {
                                        setState(() => _pointsMonthKey = mk);
                                        _loadInitialPointsFeed();
                                      },
                                    ),
                                  ],*/
                                ],
                              ),

                              /*// ── Motivational tagline on the same row ───────────────
                              Flexible(
                                child: Text(
                                  _selectedFeed == SelectedFeed.home
                                      ? _homeTagline
                                      : (_selectedFeed == SelectedFeed.points ? _pointsTagline : 'Leaderboard')
                                  ,
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.end,
                                ),
                              ),
                              */
                            ],
                          ),
                        ),

                        const SizedBox(width: 8),

                        // 🔧 Sneaky debug button (one-time Firestore dump)
                        /*TextButton.icon(
                          onPressed: () async {
                            try {
                              // 👇 enable file output
                              final result = await dumpExercisesByCategory(writeFile: true);
                              debugPrint('🗂️ [DumpExercises] categories: ${result.keys.length}');
                              if (!mounted) return;

                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('✅ Exercise dump saved — check debug log for file path'),
                                  duration: Duration(seconds: 3),
                                ),
                              );
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Dump failed: $e')),
                              );
                            }
                          },

                          icon: const Icon(Icons.bug_report, size: 16, color: Colors.white),
                          label: const Text('Sneaky', style: TextStyle(color: Colors.white)),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            backgroundColor: Colors.white12,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            foregroundColor: Colors.white,
                          ),
                        ),
*/

                        // ── Home Feed ──────────────────────────────────────────────────────────
                        if (_selectedFeed == SelectedFeed.home) ...[
                          const SizedBox(height: 2),
                          const SizedBox(height: 8),

                          if (!_feedOwnersResolved)
                            const Center(
                              child: SizedBox(
                                width: 24, height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          else if (_feedOwnerUids.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                'No recent posts from you or your gym buddies yet.',
                                style: TextStyle(color: Colors.white70),
                              ),
                            )
                          else
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Cards (Home: media + RE posts that were explicitly shared to Home)
                                ..._feedPosts.map((p) {
                                  // Media: render immediately
                                  if (p.type != 're_daily') {
                                    return FeedPostCard(
                                      post: p,
                                      isHomeContext: true,
                                      onOpenDetail: () async {
                                        await Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => PostDetailPage(
                                              post: p,
                                              onToggleLike: (pp) => PostService.instance.toggleLike(pp.id),
                                              onToggleGoodLift: (pp) => PostService.instance.toggleGoodLift(
                                                  pp.id, isVideo: pp.mediaType == 'video'),
                                              onAddComment: (pp, text) =>
                                                  PostService.instance.addComment(pp.id, text, usernameFallback: 'user'),
                                              canDelete: (UserContext.of(context, listen: false).actorUid == p.ownerUid),
                                            ),
                                          ),
                                        );
                                        if (!context.mounted) return;
                                        _loadInitialHomeFeed();
                                      },
                                    );
                                  }

                                  // re_daily: eligibility captured in Post model at load time — no stream needed
                                  if (!p.promoteToHome || p.badges.isEmpty || p.dailyTotal <= 0.0) {
                                    return const SizedBox.shrink();
                                  }
                                  return FeedPostCard(
                                    post: p,
                                    isHomeContext: true,
                                    onOpenDetail: () async {
                                      await Navigator.of(context).push(
                                        MaterialPageRoute(builder: (_) => ReDailyDetailPage(postId: p.id)),
                                      );
                                      if (!context.mounted) return;
                                      _loadInitialHomeFeed();
                                    },
                                  );
                                }),

                                // Footer (Home)
                                SizedBox(
                                  height: 52,
                                  child: Center(
                                    child: () {
                                      if (_feedLoading) {
                                        return const SizedBox(
                                          width: 24, height: 24,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        );
                                      }
                                      if (_feedError) {
                                        return TextButton(onPressed: _loadInitialHomeFeed, child: const Text('Retry'));
                                      }
                                      if (_feedHasMore) {
                                        return TextButton(onPressed: _loadMoreHomeFeed, child: const Text('Load more'));
                                      }
                                      return const SizedBox.shrink();
                                    }(),
                                  ),
                                ),
                                const SizedBox(height: 8),
                              ],
                            ),
                        ] else if (_selectedFeed == SelectedFeed.points) ...[
                          // ── Points Feed ──────────────────────────────────────────────────────
                          const SizedBox(height: 2),
                          const SizedBox(height: 8),

                          if (_pointsLoading && _pointsPosts.isEmpty)
                            const Center(
                              child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          else if (_pointsPosts.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Column(
                                children: [
                                  const Text(
                                    'No points posts for this month yet, brah do you even lift.',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                  TextButton.icon(
                                    onPressed: () {},
                                    icon: const Icon(Icons.fitness_center),
                                    label: const Text('Log a workout'),
                                  ),
                                ],
                              ),
                            )
                          else
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ..._pointsPosts.map((p) => FeedPostCard(
                                  post: p,
                                  isHomeContext: false,
                                  onOpenDetail: () async { /* ReDailyDetailPage */ },
                                )),

                                // Footer (Points)
                                SizedBox(
                                  height: 52,
                                  child: Center(
                                    child: () {
                                      if (_pointsLoading) {
                                        return const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2));
                                      }
                                      if (_pointsHasMore) {
                                        return TextButton(onPressed: _loadMorePointsFeed, child: const Text('Load more'));
                                      }
                                      return const SizedBox.shrink();
                                    }(),
                                  ),
                                ),
                                const SizedBox(height: 8),
                              ],
                            ),
                        ] else ...[
                          // ── Leaderboard Tab ──────────────────────────────────────────────────
                          const SizedBox(height: 2),
                          const SizedBox(height: 8),

                          // Inline leaderboard widget (no Scaffold inside this page)
                          const LeaderboardEmbedded(),

                          // Give short leaderboards some scrollable breathing room
                          const SizedBox(height: 140),

                        ],

                      SizedBox(height: MediaQuery.of(context).padding.bottom + 24),

                    ],
                  ),
                ),
    );
  }
}

// ── Glowing cue wrapper ────────────────────────────────────────────────────────
// Wraps a Quick Access card with an animated colour-cycling glow border and a
// small label above it. Renders the child unchanged when active is false.
class _GlowingCueWrapper extends StatefulWidget {
  final bool active;
  final String label;
  final Widget child;
  const _GlowingCueWrapper({
    required this.active,
    required this.label,
    required this.child,
  });

  @override
  State<_GlowingCueWrapper> createState() => _GlowingCueWrapperState();
}

class _GlowingCueWrapperState extends State<_GlowingCueWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;

    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final color = Color.lerp(cs.secondary, cs.tertiary, _ctrl.value)!;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: color.withOpacity(0.9),
              ),
            ),
            const SizedBox(height: 2),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(0.4),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: widget.child,
            ),
          ],
        );
      },
    );
  }
}
