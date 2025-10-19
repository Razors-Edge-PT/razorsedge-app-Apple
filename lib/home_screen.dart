import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'workout_entry_screen.dart';
import 'workout_model.dart';
import 'app_drawer.dart';
import 'package:table_calendar/table_calendar.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'coach_home_screen.dart';
import 'approve_requests_screen.dart';
import 'Camp_BB2.dart';
import 'update_exercises.dart';
import 'core_exercises.dart';
import 'profile_page.dart';
import 'warmup_service.dart';
import 'dart:async';
import'stats_snapshot.dart';
import 'directMessages.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'post_service.dart';
import 'post_header.dart';
import 'feed_post_card.dart';
import 'main.dart';
import 're_daily.dart';
import 'dart:math';
import 'leaderboard_page.dart';

 import 'dart:convert';
 import 'package:cloud_firestore/cloud_firestore.dart';
 import 'local_cache/block_plan_cache.dart';
 import 'local_cache/workout_day_cache.dart';


enum SelectedFeed { home, points, leaderboard }
const String kUserPrefFeedTab = 'feedTab'; // 'home' | 'points'



// Taglines to rotate
const List<String> _kPointsTaglines = [
  'Certified Gainz Accounting™ department 🧮🏋️‍♂️📊',
  'Do you even metrics? 📏📐',
  'Literally your street cred 🏙️✅',
  'Woah take those points the bank, so you earn interest 🏦💰📈',
  'Today’s gains: properly weighted. ⚖️💪',
  'Scored and adored ❤️🧮',
  'That e1RM? Extremely my type 😏📊',
  'Swipe right on those metrics 👉❤️📈',
  'PRs + Pts = good chemistry 🧪❤️‍🔥',
  'Points that slap 👋✨',
  'You’re not just strong—you’re quantifiably tempting 📊😮‍💨',
  'Big sets, big energy, big data 📦⚡💾',
  'Quantifiable Clout',
];

const List<String> _kHomeTaglines = [
  'Go on, scroll. We won’t tell 🤫💪📱',
  'For the love of iron pls do not scroll instagram.',
  'Don’t ghost the feed—post the set 👻📤',
  'If it’s not posted, was it even a set? 📸❓',
  'Scroll your home feed, you love it 👇 ❤️📲',
  'Humblebrag optional 🙃📤✅',
  'Your spotter can film. No excuses 🎥🤝🙅‍♂️',
  'The grid needs iron. Contribute 🔩🟦➕',
  'Pics or it was active recovery 📸🆚🧘‍♂️',
  'Post-workout afterglow belongs on the feed ✨📲',
  'You + good lighting = public service 💡📸🫶',
  'Camera loves you. Algorithm agrees ❤️‍🔥',
  'Strong is the new aesthetic 💅🏽🏋️',
  'The algorithm is blushing. Keep going 🤖😳➡️',
  'Hit depth on that scroll ⬇️📱',
  'A little lurk between sets 👀⏱️',
  'Scroll like you mean it 💨📱',
  'This is your sign to keep scrolling ➡️📱',
  'Keep the algorithm company 🤖🫶',
];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum HomeSection { calendar, topLifts }

class _HomeScreenState extends State<HomeScreen> with RouteAware {

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  static const double kFeatureCardWidth = 150;

  String? mostRecentWeight;
  Workout? mostRecentWorkout;
  bool isLoading = true;
  String errorMessage = '';

  final CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Set<DateTime> _trainingDays = {};

  //Profile image
  bool _avatarPersistInProgress = false;
  String? _avatarLastUrlSaved;
  final ImagePicker _picker = ImagePicker();


  String? _actingAsEmail;
  String? _lastWarmUid;

  HomeSection _currentSection = HomeSection.calendar;

  // ── Home FEED ─────────────────────────────────────────────────────────
  final ScrollController _homeScrollCtrl = ScrollController();
  List<Post> _feedPosts = [];
  bool _feedLoading = false;
  bool _feedHasMore = true;
  SelectedFeed _selectedFeed = SelectedFeed.home;
  final ScrollController _pointsScrollCtrl = ScrollController();
  String _homeTagline = _kHomeTaglines.first;

// Points feed state
  List<Post> _pointsPosts = [];
  bool _pointsLoading = false;
  bool _pointsHasMore = true;
  DocumentSnapshot<Map<String, dynamic>>? _lastPointsSnap;
  Timestamp? _lastPointsCreatedAt;
  String _pointsTagline = _kPointsTaglines.first;


// Points month filter (yyyy-MM), default = current month
  String _pointsMonthKey = () {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
  }();

  DocumentSnapshot<Map<String, dynamic>>? _lastFeedSnap; // last doc for pagination
  List<String> _feedOwnerUids = []; // self + buddies
  bool _feedOwnersResolved = false;
  static const int _kFeedPageSize = 6;
  bool _feedError = false;
  String _feedErrorMsg = '';
  Timestamp? _lastCreatedAt; // simple, stable pagination
  bool _loadMoreScheduled = false;


  Future<void> debugPrintEightDayWindow({
    required String uid,
    required String blockId,
    DateTime? blockStartDate, // if null, we’ll fetch it
  }) async {
    String _ymd(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    DateTime _dOnly(DateTime d) => DateTime(d.year, d.month, d.day);

    final fs = FirebaseFirestore.instance;

    // fetch blockStartDate if not provided
    DateTime? _blockStart = blockStartDate;
    if (_blockStart == null) {
      try {
        final snap = await fs
            .collection('planned_blocks').doc(uid)
            .collection('blocks').doc(blockId)
            .get(const GetOptions(source: Source.server));
        final v = (snap.data() ?? const {})['startDate'];
        if (v is Timestamp) _blockStart = _dOnly(v.toDate());
        if (v is String) {
          final dt = DateTime.tryParse(v);
          if (dt != null) _blockStart = _dOnly(dt);
        }
      } catch (_) {}
    }
    if (_blockStart == null) {

    }

    final base = _dOnly(DateTime.now());


    // today-5 … today+2
    for (int offset = -5; offset <= 2; offset++) {
      final day = _dOnly(base.add(Duration(days: offset)));
      final ymd = _ymd(day);

      int? weekIdx;
      int? dayIdx;
      if (_blockStart != null) {
        final delta = day.difference(_blockStart!).inDays;
        weekIdx = (delta ~/ 7);
        dayIdx  = delta % 7;
        if (dayIdx < 0) dayIdx += 7; // keep 0..6
      }

      // ==== Local: BB2 planned from ISAR ====
      List<Map<String, dynamic>>? bb2Local;
      if (weekIdx != null && dayIdx != null) {
        bb2Local = await BlockPlanCache.getDay(
          uid: uid, blockId: blockId, weekIndex: weekIdx, dayIndex: dayIdx,
        );
      }

      // ==== Local: WESInit snapshot (planned & wesPlanned) ====
      int wesInitPlanned = 0, wesInitWesPlanned = 0;
      try {
        final snap = await BlockPlanCache.getInitSnapshot(
          uid: uid, blockId: blockId, dateYmd: ymd,
        );
        if (snap != null) {
          try {
            final p = jsonDecode(snap.plannedExercisesJson);
            if (p is List) wesInitPlanned = p.length;
          } catch (_) {}
          try {
            final w = jsonDecode(snap.wesPlannedExercisesJson);
            if (w is List) wesInitWesPlanned = w.length;
          } catch (_) {}
        }
      } catch (_) {}

      // ==== Local: per-day workout cache ====
      int wdcPlanned = 0, wdcWesPlanned = 0;
      try {
        final rec = await WorkoutCacheDb.getDay(uid: uid, dateKey: ymd);
        if (rec != null) {
          final ex = rec['exList'] as List<Map<String, dynamic>>? ?? const [];
          final wp = rec['wesPlanned'] as List<Map<String, dynamic>>? ?? const [];
          wdcPlanned = ex.length;
          wdcWesPlanned = wp.length;
        }
      } catch (_) {}

      // ==== Firestore: planned_blocks day (rows & date) ====
      int fsPlanRows = 0;
      String? fsPlanDate;
      if (weekIdx != null && dayIdx != null) {
        try {
          final dSnap = await fs
              .collection('planned_blocks').doc(uid)
              .collection('blocks').doc(blockId)
              .collection('weeks').doc('week_$weekIdx')
              .collection('days').doc('day_$dayIdx')
              .get(const GetOptions(source: Source.server));
          if (dSnap.exists) {
            final data = dSnap.data() ?? const <String, dynamic>{};
            final raw = data['exercises'];
            if (raw is List) fsPlanRows = raw.length;
            final v = data['date'];
            if (v is Timestamp) fsPlanDate = _ymd(_dOnly(v.toDate()));
            if (v is String && v.isNotEmpty) {
              final dt = DateTime.tryParse(v);
              fsPlanDate = dt != null ? _ymd(_dOnly(dt)) : (v.length >= 10 ? v.substring(0, 10) : v);
            }
          }
        } catch (_) {}
      }

      // ==== Firestore: users/workouts/{ymd} (wesPlanned + exercises) ====
      int fsWesPlanned = 0, fsExercises = 0;
      try {
        final wSnap = await fs
            .collection('users').doc(uid)
            .collection('workouts').doc(ymd)
            .get(const GetOptions(source: Source.server));
        if (wSnap.exists) {
          final data = wSnap.data() ?? const <String, dynamic>{};
          final wp = data['wesPlannedExercises'];
          final ex = data['exercises'];
          if (wp is List) fsWesPlanned = wp.length;
          if (ex is List) fsExercises  = ex.length;
        }
      } catch (_) {}

      // ==== Print one compact block per day ====
      final left = (weekIdx != null && dayIdx != null)
          ? 'w$weekIdx d$dayIdx'
          : 'w? d?';
      print('📅 [$ymd] ($left)');
      print('   • Local  BB2=${bb2Local?.length ?? 0}  WESInit(p=${wesInitPlanned}, w=${wesInitWesPlanned})  WDC(p=${wdcPlanned}, w=${wdcWesPlanned})');
      print('   • FS     planned_blocks rows=$fsPlanRows date=${fsPlanDate ?? '—'}  workouts wesPlanned=$fsWesPlanned ex=$fsExercises');
    }
  }


  @override
  void initState() {
    super.initState();



    final src = _selectedDay ?? _focusedDay;
    final dateOnly = DateTime(src.year, src.month, src.day);



    final userContext = Provider.of<UserContext>(context, listen: false);
    final actingUid = userContext.actingAsUid ?? userContext.actorUid; // add this line
    _homeScrollCtrl.addListener(_onHomeScroll);
    _pointsScrollCtrl.addListener(_onPointsScroll);

    // 🔄 Replace the three separate blocks with this single kickoff
    unawaited(() async {
      // 1) Resolve owners once
      await _resolveFeedOwners();

      // 2) Restore last selected tab once
      await _restoreSelectedFeed();
      if (!mounted) return;

      // 3) Pick the tagline once for the selected tab
      setState(() {
        if (_selectedFeed == SelectedFeed.home) {
          _pickHomeTagline();
        } else {
          _pickPointsTagline();
        }
      });

      // 4) Kick exactly one initial load for the selected tab
      if (_selectedFeed == SelectedFeed.home) {
        await _loadInitialHomeFeed();
      } else {
        await _loadInitialPointsFeed();
      }
    }());



// Pass block + date so Warmup can precompute the exact WES snapshot you’ll need.
    final _warmDateSrc = _selectedDay ?? _focusedDay; // use picked day, else the visible day
    final _warmDate = DateTime(_warmDateSrc.year, _warmDateSrc.month, _warmDateSrc.day);

    unawaited(WarmupService.instance.warmWES(
      actingUid ?? '',
      activeBlockId: userContext.activeBlockId,
      selectedDate: _warmDate,
    ));




    // Delay the email fetch until after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAthleteEmail();
    });


    _ensureAtLeastOneBlockExists().then((_) {
      _fetchRecentData();
      _fetchTrainingDaysForMonth(_focusedDay);

      FirebaseFirestore.instance
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
        final uid = actingUid ?? userContext.actorUid;
        final bid = userContext.activeBlockId;
        if (uid != null && bid != null && bid.isNotEmpty) {
          await debugPrintEightDayWindow(uid: uid, blockId: bid);
        } else {

        }
      });
    });

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
    try {
      final uid = UserContext.of(context, listen: false).actorUid;
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'prefs': { kUserPrefFeedTab: _selectedFeed == SelectedFeed.points ? 'points' : 'home' }
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  void _pickPointsTagline() {
    final r = Random();
    _pointsTagline = _kPointsTaglines[r.nextInt(_kPointsTaglines.length)];
  }

  void _pickHomeTagline() {
    final r = Random();
    _homeTagline = _kHomeTaglines[r.nextInt(_kHomeTaglines.length)];
  }

  Future<void> _ensureAtLeastOneBlockExists() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final uid = user.uid;
    final blocksRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks');

    final existingBlocks = await blocksRef.get();

    if (existingBlocks.docs.isEmpty) {
      print('🆕 [Home] No blocks found — creating default "1st Block"...');
      final now = DateTime.now();
      final startDate = now;
      final endDate = now.add(const Duration(days: 42));

      final defaultBlock = {
        'name': '1st Block',
        'isActive': true,
        'createdAt': Timestamp.now(),
        'startDate': Timestamp.fromDate(startDate),
        'endDate': Timestamp.fromDate(endDate),
        'selectedDays': ['Mon', 'Wed', 'Fri'],
      };

      final newBlockRef = await blocksRef.add(defaultBlock);
      final newBlockId = newBlockRef.id;
      print('✅ [Home] Default block created with ID: $newBlockId');

      // ✅ Create week_0 to week_5 and day_0 to day_6 in each
      for (int week = 0; week < 6; week++) {
        final weekRef = newBlockRef.collection('weeks').doc('week_$week');
        await weekRef.set({'exists': true}, SetOptions(merge: true));

        final daysRef = weekRef.collection('days');
        for (int day = 0; day < 7; day++) {
          final currentDate = now.add(Duration(days: week * 7 + day));
          final weekday = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][day];
          final monthName = [
            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
          ][currentDate.month - 1];

          await daysRef.doc('day_$day').set({
            'date': Timestamp.fromDate(currentDate),
            'circuitStartIndices': [0],
            'exercises': [],
            'workoutName': '$weekday ${currentDate.day} $monthName - Week ${week + 1}',
            'exists': true,
          });
        }
      }

      // ✅ Inject a planned exercise with Static RIR and periodization
      final exerciseId = 'AmfUWbF1DH3I7qPAdh5k'; // Bench Press, Barbell
      final defaultRirPlan = {
        for (int w = 1; w <= 6; w++)
          'week$w': {
            'session1': {
              'set1': {'reps': '10', 'rir': '1'},
              'set2': {'reps': '10', 'rir': '1'},
              'set3': {'reps': '10', 'rir': '1'},
            }
          }
      };

      final plannedExerciseDetails = {
        exerciseId: {
          'rirModel': 'Static RIR',
          'rirPlan': defaultRirPlan,
          'periodizationModel': 'DUP, Custom',
          'progressionModel': 'Add Reps',
          'weeklyFrequency': 3,
          'increments': {'week': 2.5, 'block': 5.0},
          'notes': '',
          'maxWeightXReps': '',
        },
        'blockMeta': {
          'blockStartDate': startDate.toIso8601String(),
          'blockEndDate': endDate.toIso8601String(),
          'selectedDays': ['Mon', 'Wed', 'Fri'],
        }
      };

      await newBlockRef.set({
        'plannedExerciseDetails': plannedExerciseDetails,
      }, SetOptions(merge: true));
    }
  }

  void _onUserContextChange() {
    final uc = Provider.of<UserContext>(context, listen: false);
    final newUid = uc.actingAsUid ?? uc.actorUid;
    if (newUid != null && newUid != _lastWarmUid) {
      _lastWarmUid = newUid;
      unawaited(WarmupService.instance.warmWES(newUid));
    }
  }


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadAthleteEmail(); // 👈 this line ensures _actingAsEmail is set
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route); // 👈 subscribe
    }
  }

  @override
  void dispose() {
    Provider.of<UserContext>(context, listen: false).removeListener(_onUserContextChange);
    _homeScrollCtrl.removeListener(_onHomeScroll);
    _homeScrollCtrl.dispose();
    routeObserver.unsubscribe(this); // 👈 unsubscribe
    _homeScrollCtrl.removeListener(_onHomeScroll);
    _homeScrollCtrl.dispose();
    _pointsScrollCtrl.removeListener(_onPointsScroll);
    _pointsScrollCtrl.dispose();

    super.dispose();
  }

  @override
  void didPopNext() {
    if (!_feedOwnersResolved) return;
    if (_selectedFeed == SelectedFeed.home) {
      _loadInitialHomeFeed();
    } else {
      _loadInitialPointsFeed();
    }
  }


//Home FEED functions


  Future<void> _loadInitialHomeFeed() async {

    if (!_feedOwnersResolved) return;
    setState(() {
      _feedLoading = false;
      _feedHasMore = true;
      _feedError = false;
      _feedErrorMsg = '';
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
      _feedErrorMsg = '';
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

      // if nothing new, restore scroll offset so the view doesn’t “jump”
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
        _feedErrorMsg = '${e.code}: ${e.message}';
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
        _feedErrorMsg = '$e';
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
    final uc = UserContext.of(context, listen: false);
    final viewerUid = uc.currentUid ?? uc.actorUid;
    final owners = <String>{};

    if (viewerUid != null && viewerUid.isNotEmpty) {
      owners.add(viewerUid);
    }

    try {
      final d = await FirebaseFirestore.instance
          .collection('buddyAssignments')
          .doc(viewerUid)
          .get();

      final data = d.data() ?? const {};
      final athletesMap = (data['athletes'] is Map)
          ? Map<String, dynamic>.from(data['athletes'])
          : const <String, dynamic>{};

      owners.addAll(athletesMap.keys);

    } catch (e) {

    }

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
    if (uid == null) return;

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

  Future<List<Map<String, dynamic>>> _fetchTopLifts() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('workouts')
        .get();

    Map<String, double> maxes = {};

    for (var doc in snapshot.docs) {
      final exercises = List.from(doc['exercises'] ?? []);
      for (var exercise in exercises) {
        final name = exercise['name'] ?? '';
        final sets = List.from(exercise['sets'] ?? []);
        for (var set in sets) {
          final weight = (set['weight'] as num?)?.toDouble() ?? 0;
          if (!maxes.containsKey(name) || weight > maxes[name]!) {
            maxes[name] = weight;
          }
        }
      }
    }

    return maxes.entries
        .map((e) => {'exercise': e.key, 'weight': e.value})
        .toList();
  }


  Widget _buildFeatureCard(IconData icon, String label, String route) {
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, route),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: Icon(icon, size: 45, color: Colors.cyanAccent),
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: Text(label,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              )
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userEmail = FirebaseAuth.instance.currentUser?.email ?? '';

    return Scaffold(

      key: _scaffoldKey,
      appBar: AppBar(
        title: null,
        backgroundColor: Colors.blueGrey,
        automaticallyImplyLeading: false,
        actions: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 👤 Logged-in / impersonated user banner
              Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [

                    SizedBox(
                      width: 120, // max width
                      child: Text(
                        _actingAsEmail ?? 'loading...',
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
                    padding: const EdgeInsets.all(4.0),
                    child: Builder(
                      builder: (context) {
                        final uc = context.watch<UserContext>();
                        final actingUid = uc.actingAsUid ?? uc.actorUid;

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
                        if (actingUid == null) {
                          // Fallback if somehow no uid yet
                          return CircleAvatar(
                            radius: 18,
                            backgroundColor: Colors.grey.shade300,
                            child: ClipOval(
                              child: Image.asset(
                                'assets/InApp/Placeholder_profilepic.png',
                                fit: BoxFit.cover,
                                width: 36,
                                height: 36,
                              ),
                            ),
                          );
                        }

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
                            if (uid != null &&
                                (uc.localPhotoPath == null || !(File(uc.localPhotoPath!).existsSync())) &&
                                photoURL != null) {
                              _persistAvatarLocalIfNeeded(context, uid: uid, photoURL: photoURL!);
                            }

                            // Prefer local file instantly; fallback to network; else placeholder.
                            ImageProvider? provider;
                            if (uc.localPhotoPath != null) {
                              final f = File(uc.localPhotoPath!);
                              if (f.existsSync()) provider = FileImage(f);
                            }
                            provider ??= (photoURL != null ? NetworkImage(photoURL!) : null);

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


              const SizedBox(width: 3),

              // 📩 Direct Messages icon with unread badge
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('conversations')
                    .where('participants.${FirebaseAuth.instance.currentUser!.uid}', isEqualTo: true)
                    .snapshots(),
                builder: (context, snapshot) {
                  int unreadCount = 0;
                  if (snapshot.hasData) {
                    for (var doc in snapshot.data!.docs) {
                      final data = doc.data() as Map<String, dynamic>;
                      final state = data['participantState']?[FirebaseAuth.instance.currentUser!.uid];
                      final count = (state != null && state['unreadCount'] is int)
                          ? state['unreadCount'] as int
                          : 0;
                      unreadCount += count;
                    }
                  }

                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.message_outlined, size: 26, color: Colors.cyanAccent),
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

              const SizedBox(width: 3),

              // App logo
              Image.asset(
                'assets/InApp/transparent_good_lift_logo_inApp.png',
                height: 36,
                fit: BoxFit.contain,
              ),
              const SizedBox(width: 8),

              // Menu icon
              GestureDetector(
                onTap: () => _scaffoldKey.currentState?.openDrawer(),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8.0),
                  child: Icon(
                    Icons.menu,
                    size: 28,
                    color: Colors.grey,
                  ),
                ),
              ),
            ],
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
                      //Quick Access
                      SizedBox(
                        height: 125,
                        child: // in your HomeScreen.build():
                            SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [

                              if (UserContext.of(context).isCoach)
                              SizedBox(
                                width: kFeatureCardWidth,
                                height: 125,
                                child: GestureDetector(
                                  onTap: () {
                                    final userContext = context.read<UserContext>();
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ChangeNotifierProvider<UserContext>.value(
                                          value: userContext,
                                          child: const CoachHomeScreen(),
                                        ),
                                      ),
                                    );
                                  },

                                  child: Card(
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    color: Colors.blueGrey.shade800,
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Stack(
                                        children: [
                                          // ✅ Top-left icon
                                          const Positioned(
                                            top: 0,
                                            left: 0,
                                            child: Icon(
                                              Icons.supervisor_account,
                                              size: 48,
                                              color: Colors.amberAccent,
                                            ),
                                          ),
                                          // ✅ Bottom-right text
                                          Positioned(
                                            bottom: 0,
                                            right: 0,
                                            left: 50,
                                            child: Text(
                                              'Coach\nDashboard',
                                              textAlign: TextAlign.center,
                                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                color: Colors.white,
                                                height: 1.3,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                              SizedBox(
                                width: kFeatureCardWidth,
                                child: GestureDetector(
                                  onTap: () {
                                    final userContext = UserContext.of(context, listen: false);

                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ChangeNotifierProvider<UserContext>.value(
                                          value: userContext,
                                          child: const WorkoutPage(), // <- Your workout entry screen
                                        ),
                                      ),
                                    );
                                  },
                                  child: Card(
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    color: Colors.blueGrey.shade800,
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Stack(
                                        children: [
                                          const Positioned(
                                            top: 0,
                                            left: 0,
                                            child: Icon(
                                              Icons.fitness_center,
                                              size: 48,
                                              color: Colors.cyanAccent,
                                            ),
                                          ),
                                          Positioned(
                                            bottom: 0,
                                            right: 0,
                                            left: 50,
                                            child: Text(
                                              'Enter\nWorkout',
                                              textAlign: TextAlign.center,
                                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                color: Colors.white,
                                                height: 1.3,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                              SizedBox(
                                width: kFeatureCardWidth,
                                child: GestureDetector(
                                  onTap: () {
                                    final userContext = UserContext.of(context, listen: false);

                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ChangeNotifierProvider<UserContext>.value(
                                          value: userContext,
                                          child: const Camp_BB2(), // your week planner screen
                                        ),
                                      ),
                                    );
                                  },
                                  child: Card(
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    color: Colors.blueGrey.shade800,
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Stack(
                                        children: [
                                          const Positioned(
                                            top: 0,
                                            left: 0,
                                            child: Icon(
                                              Icons.calendar_month,
                                              size: 48,
                                              color: Colors.cyanAccent,
                                            ),
                                          ),
                                          Positioned(
                                            bottom: 0,
                                            right: 0,
                                            left: 50,
                                            child: Text(
                                              'Week\nPlanner',
                                              textAlign: TextAlign.center,
                                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                color: Colors.white,
                                                height: 1.3,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                              SizedBox(
                                width: kFeatureCardWidth,
                                height: 125,
                                child: GestureDetector(
                                  onTap: () => Navigator.pushNamed(context, '/body_weight'),
                                  child: Card(
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    color: Colors.blueGrey.shade800,
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Stack(
                                        children: [
                                          // ✅ Top-left icon
                                          Positioned(
                                            top: 0,
                                            left: 0,
                                            child: Icon(
                                              Icons.monitor_weight,
                                              size: 48,
                                              color: Colors.cyanAccent,

                                            ),
                                          ),
                                          // ✅ Bottom-right text
                                          Positioned(
                                            bottom: 0,
                                            right: 0,
                                            left: 50, // ⬅️ slight left constraint so text doesn’t run under the icon
                                            child: Text(
                                              'Body\nWeight\nTracker',
                                              textAlign: TextAlign.center,
                                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                color: Colors.white,
                                                height: 1.3,
                                                fontWeight: FontWeight.bold, // ✅ Make it bold
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
                              ),

                              SizedBox(
                                width: kFeatureCardWidth,
                                child: GestureDetector(
                                  onTap: () {
                                    final userContext = UserContext.of(context, listen: false);

                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ChangeNotifierProvider<UserContext>.value(
                                          value: userContext,
                                          child: const ProfilePage(), // 👈 Navigate to your ProfilePage

                                        ),
                                      ),
                                    );
                                  },
                                  child: Card(
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    color: Colors.blueGrey.shade800,
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Stack(
                                        children: [
                                          const Positioned(
                                            top: 0,
                                            left: 0,
                                            child: Icon(
                                              Icons.person_outline,
                                              size: 48,
                                              color: Colors.cyanAccent,
                                            ),
                                          ),
                                          Positioned(
                                            bottom: 0,
                                            right: 0,
                                            left: 50,
                                            child: Text(
                                              'Profile',
                                              textAlign: TextAlign.center,
                                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                color: Colors.white,
                                                height: 1.3,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                              //if (!UserContext.of(context).isCoach)
                                SizedBox(
                                  width: kFeatureCardWidth,
                                  height: 125,
                                  child: GestureDetector(
                                    onTap: () {
                                      final userContext = context.read<UserContext>();
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => ChangeNotifierProvider<UserContext>.value(
                                            value: userContext,
                                            child: const ApproveRequestsScreen(),
                                          ),
                                        ),
                                      );
                                    },
                                    child: Card(
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      color: Colors.blueGrey.shade800,
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Stack(
                                          children: [
                                            const Positioned(
                                              top: 0,
                                              left: 0,
                                              child: Icon(
                                                Icons.mail,
                                                size: 48,
                                                color: Colors.cyanAccent,
                                              ),
                                            ),
                                            Positioned(
                                              bottom: 0,
                                              right: 0,
                                              left: 50,
                                              child: Text(
                                                'Access\nRequests',
                                                textAlign: TextAlign.center,
                                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                  color: Colors.white,
                                                  height: 1.3,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),

                              SizedBox(
                                width: kFeatureCardWidth,
                                child: _buildFeatureCard(
                                  Icons.history,
                                  'Workout\nHistory',
                                  '/saved_workouts',
                                ),
                              ),

                            ],
                          ),
                        ),
                      ),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: HomeSection.values.map((section) {
                          final isSelected = section == _currentSection;
                          final label = section == HomeSection.calendar
                              ? 'Training Calendar'
                              : 'Top Lifts';
                          return GestureDetector(
                            onTap: () =>
                                setState(() => _currentSection = section),
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 8),
                              padding: const EdgeInsets.symmetric(
                                  vertical: 6, horizontal: 12),
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    color: isSelected
                                        ? Colors.cyanAccent
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.white54,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),

                      const SizedBox(height: 2),
                      // Training Calendar
                      if (_currentSection == HomeSection.calendar) ...[
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
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    WorkoutPage(initialDate: selectedDay),
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
                                      ? Border.all(color: Colors.cyan, width: 2)
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
                                  border:
                                      Border.all(color: Colors.cyan, width: 2),
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
                                  color: Colors.lightBlueAccent,
                                  border: Border.all(
                                      color: Colors.cyanAccent, width: 2),
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
                                        _pickHomeTagline();
                                        if (_feedPosts.isEmpty && !_feedLoading) _loadInitialHomeFeed();
                                      } else if (next == SelectedFeed.points) {
                                        _pickPointsTagline();
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

                              // ── Motivational tagline on the same row ───────────────
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
                            ],
                          ),
                        ),



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

                                  // re_daily: check eligibility first (promoted + has badge + points > 0)
                                  return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                                    stream: FirebaseFirestore.instance.collection('posts').doc(p.id).snapshots(),
                                    builder: (context, snap) {
                                      if (!snap.hasData) return const SizedBox.shrink();
                                      final d = snap.data!.data() ?? const <String, dynamic>{};
                                      final promoted = (d['promoteToHome'] as bool?) == true;
                                      final badges = (d['badges'] as List?) ?? const [];
                                      final hasBadge = badges.isNotEmpty;
                                      final total = (d['dailyTotal'] as num?)?.toDouble() ?? 0.0;

                                      if (!promoted || !hasBadge || total <= 0.0) {
                                        return const SizedBox.shrink(); // 🚫 don’t render a card at all
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

                      ],


                    ],
                  ),
                ),
    );
  }
}
class _MonthPickerChip extends StatelessWidget {
  final String monthKey; // "yyyy-MM"
  final ValueChanged<String> onChanged;
  const _MonthPickerChip({required this.monthKey, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(monthKey),
      onPressed: () async {
        final now = DateTime.now();
        final years = [for (int y = now.year; y >= now.year - 3; y--) y];
        final months = [for (int m = 1; m <= 12; m++) m];
        String? picked;
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Select month'),
            content: SizedBox(
              width: 320,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final y in years)
                    for (final m in months)
                      InkWell(
                        onTap: () {
                          picked = '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}';
                          Navigator.pop(context);
                        },
                        child: Chip(label: Text('$y-${m.toString().padLeft(2, '0')}')),
                      ),
                ],
              ),
            ),
          ),
        );
        if (picked != null && picked != monthKey) onChanged(picked!);
      },
    );
  }
}
