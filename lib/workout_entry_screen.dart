import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart'; // Import for date formatting
import 'package:localtest222/workout_model.dart';
import 'exercise_selection_screen.dart';
import 'template_model.dart';
import 'templates.dart';
import 'exercise_details_screen.dart'; // Import your exercise details screen
import 'top_sets_screen.dart';
import 'periodization_model_utils.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'main.dart';

// For JSON encoding
import 'debounce_Utils.dart';
import 'block_planner_repository.dart';
import 'block_repository.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'warmup_service.dart';
import 'package:google_fonts/google_fonts.dart';
import 'stats_snapshot.dart';
import 'local_cache/block_plan_cache.dart';   // from a file inside lib/
import 'local_cache/workout_day_cache.dart';
import 'local_cache/isar_block_plan.dart';
import 'local_cache/isar_wes_init.dart';
import 'local_cache/isar_db.dart';
import 'package:isar/isar.dart';
import 're_daily.dart';
import 'progression_engine.dart';
import 'package:lottie/lottie.dart';
import 'exercise_video_button.dart';
import 'package:video_player/video_player.dart';
import 'exercise_video_assets.dart';
import 'exercise_video_player_screen.dart';
import 'demographics_cache.dart';
import 'local_cache/isar_claude_bullet_snapshot.dart';

import 'package:cloud_firestore/cloud_firestore.dart' as firebase_firestore;

import 'formula.dart' as formula;



Future<void> deleteAllUserWorkouts() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return; // Exit if no user is signed in

  try {
    final collectionRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts');

    final snapshot = await collectionRef.get();

    for (var doc in snapshot.docs) {
      await doc.reference.delete(); // Deletes each workout document
    }
  } catch (e) {
    // Handle error silently or show a message to the user if needed
  }
}

class BlockMeta {
  final String id;
  final String? name; // ✅ Now nullable
  final DateTime? startDate; // ✅ nullable
  final DateTime? endDate;   // ✅ nullable
  final List<String> selectedDays;

  BlockMeta({
    required this.id,
    this.name,
    this.startDate, // ✅ optional
    this.endDate,   // ✅ optional
    required this.selectedDays,
  });
}

// ——— Missed exercises model ———
class _MissedItem {
  final int sourceWeekIndex;
  final int sourceDayIndex;
  final int rowIndex;           // index within source day's exercises[]
  final String name;            // planned row 'name'
  final int circuitIndex;       // planned row 'circuitIndex'
  final Map<String, dynamic> row; // full planned row map (weight/reps/rir/velocity/notes/circuitIndex)

  _MissedItem({
    required this.sourceWeekIndex,
    required this.sourceDayIndex,
    required this.rowIndex,
    required this.name,
    required this.circuitIndex,
    required this.row,
  });
}



class WorkoutPage extends StatefulWidget {
  final Template? initialTemplate;
  final Workout? workout; // Make workout optional
  final bool isNewWorkout;
  final List<Map<String, dynamic>>? prefilledExercisesWithCircuits;
  final List<String>? prefilledExercises; // ✅ Add this line back
  final DateTime? initialDate; // ✅ Add this line
  final String? initialWorkoutName; // ✅ Add this
  final String? blockId; // ✅ Needed for BP/BB2 integration

  const WorkoutPage({
    Key? key,
    this.initialTemplate,
    this.workout,
    this.isNewWorkout = true,
    this.prefilledExercisesWithCircuits,
    this.prefilledExercises, // ✅ Don’t forget this!
    this.initialDate,
    this.initialWorkoutName,
    this.blockId, // ✅ Wire through from navigation
  }) : super(key: key);

  @override
  _WorkoutPageState createState() => _WorkoutPageState();
}

class _WorkoutPageState extends State<WorkoutPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {

  /// In-memory draft saved synchronously on dispose(), consumed on next
  /// _paintFromSnapshotIfAny(). Survives widget lifecycle because it's static.
  /// This is the primary mechanism for fast re-entry value restore.
  static Map<String, dynamic>? _exitDraft;

  List<String> exercises = []; // Store selected exercises from dialog
  final TextEditingController _workoutNameController = TextEditingController();
  late DateTime _selectedDate;
  final List<Map<String, dynamic>> _selectedExercisesWithCircuits = [];
  List<String> plannedExercises = [];
  Map<String, Map<String, dynamic>> _exerciseSettings = {};
  Map<String, String> nameToIdMap = {}; // 🧠 Exercise name ➔ ID
  final List<List<SetDetails>> _workoutSets = [];
  final List<List<TextEditingController>> _repsControllers = [];
  final List<List<TextEditingController>> _weightControllers = [];
  final List<List<TextEditingController>> _rirControllers = [];
  List<List<TextEditingController>> _velocityControllers = [];
  List<List<TextEditingController>> _notesControllers = [];
  final Map<String, String> _blockNameById = {};

  Map<String, bool> _showVelocityByExercise = {
  }; // exerciseName.toLowerCase() → true/false
  bool _claudeBulletDumpMode = false;

  double _dragX = 0;


  String get userId =>
      UserContext
          .of(context, listen: false)
          .currentUid;

  String? _lastMergedUid;
  late final String _cachedUid;
  DateTime? _lastMergedDate;
  bool _hasCompletedInitialMergeForThisDate = false; // 👈 gate: prevents double-merge

  // ✅ Tracks BB2-planned keys for the currently selected date (exerciseId|circuitIndex)
  final Set<String> _bb2PlannedKeysForSelectedDate = {};


  final int _defaultSets = 3;
  List<VoidCallback> _undoStack = [];
  bool _applyingUndo = false;
  Set<String> _selectDateHintFields = {};


  // 🧠 Block metadata
  DateTime? _blockStartDate;
  DateTime? _blockEndDate;
  DateTime? blockStartDate;
  DateTime? blockEndDate;


  List<String> _selectedDays = [];
  String? _activeBlockId;
  String? _selectedBlockId;
  List<BlockMeta> _allBlocks = [];

  late final BlockPlannerRepository _repo;

  // 🧠 BB2 and progression logic
  Map<String, Map<String, dynamic>> _bb2DataByExercise = {};
  Map<String, Map<String, dynamic>> _resolvedBB2Values = {};
  Map<String, String> _progressionModelsByExercise = {};
  final Map<String, Map<String, dynamic>> _cachedProgressedValues = {};
  // Per-keystroke memoization caches for hint computation
  // Cleared in every onChanged that touches weight/reps/rir, and in _onReorderExercises.
  final Map<String, double> _e1rmTargetCache = {};
  final Map<String, ({List<double> weightRangeDisplay, List<int> repsRange, double weightMidDisplay, int repsMid, double e1rmMid})> _synthHintCache = {};
  // Pre-resolved S1 hints from snapshot for instant first paint
  final Map<String, Map<String, dynamic>> _seedHintsByKey = {};

  // ── Claude_bullet resume snapshot overrides ──
  // When a valid Claude_bullet snapshot is restored, these maps hold the
  // exact hint strings that were visible at exit time so the UI can paint
  // them synchronously without running async hint computation.
  //   Key: instanceKey ("exerciseId|circuitIndex")
  //   Value: Map<int setIdx, String displayString>
  bool _claudeBulletActiveForThisDay = false;
  bool _claudeBulletPhase0Active = false;  // Phase 0 tripwire: prevents later init steps from overwriting
  final Map<String, Map<int, String>> _claudeBulletWeightHintOverrides = {};
  final Map<String, Map<int, String>> _claudeBulletRepsHintOverrides = {};
  final Map<String, Map<int, String>> _claudeBulletRirHintOverrides = {};
  Timer? _claudeBulletSaveDebounce;

  // Stable key for a row: "name|circuitIndex"
  String _rowKeyBy(int i) {
    final row = _selectedExercisesWithCircuits[i];
    final nameRaw = (row['name'] ?? '').toString().trim();
    final ci = (row['circuitIndex'] ?? 0) as int;

    // ✅ Prefer row's own exerciseId/id; fall back to nameToId lookup.
    final rawId = (row['exerciseId'] ?? row['id'])?.toString().trim() ?? '';
    final exId = rawId.isNotEmpty ? rawId : (PeriodizationModelUtils.nameToId[nameRaw] ?? nameRaw).toString().trim();

    return '$exId|$ci';
  }


  // 🔢 Ensure rows are ordered by circuitIndex, then by original row order
  void _sortRowsByCircuitIndex() {
    if (_selectedExercisesWithCircuits.length <= 1) return;

    final List<int> indices = List<int>.generate(
      _selectedExercisesWithCircuits.length,
          (i) => i,
    );

    int _ciFor(int idx) {
      final raw = _selectedExercisesWithCircuits[idx]['circuitIndex'];
      if (raw is int) return raw;
      return int.tryParse('$raw') ?? 0;
    }

    indices.sort((a, b) {
      final ca = _ciFor(a);
      final cb = _ciFor(b);
      if (ca != cb) {
        // Circuit 0 first, then 1, then 2, etc.
        return ca.compareTo(cb);
      }
      // Within same circuit, keep original order stable.
      return a.compareTo(b);
    });

    final List<Map<String, dynamic>> newSelected = [];
    final List<List<SetDetails>> newWorkoutSets = [];
    final List<List<TextEditingController>> newRepsCtr = [];
    final List<List<TextEditingController>> newWeightCtr = [];
    final List<List<TextEditingController>> newRirCtr = [];
    final List<List<TextEditingController>> newVelocityCtr = [];
    final List<List<TextEditingController>> newNotesCtr = [];

    for (final idx in indices) {
      newSelected.add(_selectedExercisesWithCircuits[idx]);
      if (_workoutSets.length > idx) {
        newWorkoutSets.add(_workoutSets[idx]);
      }
      if (_repsControllers.length > idx) {
        newRepsCtr.add(_repsControllers[idx]);
      }
      if (_weightControllers.length > idx) {
        newWeightCtr.add(_weightControllers[idx]);
      }
      if (_rirControllers.length > idx) {
        newRirCtr.add(_rirControllers[idx]);
      }
      if (_velocityControllers.length > idx) {
        newVelocityCtr.add(_velocityControllers[idx]);
      }
      if (_notesControllers.length > idx) {
        newNotesCtr.add(_notesControllers[idx]);
      }
    }

    _selectedExercisesWithCircuits
      ..clear()
      ..addAll(newSelected);
    if (_workoutSets.length == newWorkoutSets.length) {
      _workoutSets
        ..clear()
        ..addAll(newWorkoutSets);
      _repsControllers
        ..clear()
        ..addAll(newRepsCtr);
      _weightControllers
        ..clear()
        ..addAll(newWeightCtr);
      _rirControllers
        ..clear()
        ..addAll(newRirCtr);
      _velocityControllers
        ..clear()
        ..addAll(newVelocityCtr);
      _notesControllers
        ..clear()
        ..addAll(newNotesCtr);
    }

    // Optional: debug the final order
    // for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
    //   final r = _selectedExercisesWithCircuits[i];
    //   debugPrint('🔢 [WES sort] row=$i ci=${r['circuitIndex']} name=${r['name']}');
    // }
  }



  int _buildN = 0;

  bool _isLoadingData = true;
  bool _isInitialized = false;
// Epoch guard for late loaders
  int _epoch = 0;
  bool _isStale(int e) => e != _epoch;
// Active day key (YYYY-MM-DD) for the current page session
  String _dayKey = '';
  String get _currentDayKey => _dayKey;
  // ⏳ Coalescing for swipe-driven date changes
  Timer? _dateCoalesceTimer;
  DateTime? _pendingPickedForCoalesce;
  bool _hasOpenedOnce = false;
  Timer? _heavyWorkTimer;



// Start a new date session: bump epoch + set dayKey
  void _beginDateSession(DateTime d) {
    _epoch++;
    _dayKey = DateFormat('yyyy-MM-dd').format(DateTime(d.year, d.month, d.day));
    // Reset Claude_bullet overrides when switching dates
    _claudeBulletActiveForThisDay = false;
    _claudeBulletPhase0Active = false;  // Reset Phase 0 tripwire for new date session
    _claudeBulletWeightHintOverrides.clear();
    _claudeBulletRepsHintOverrides.clear();
    _claudeBulletRirHintOverrides.clear();
  }

  late Future<void> _initialLoad;
  late Future<void> _blockDateLoad;
  bool _didFastPaint = false;
  bool _bootPaintDone = false;  // prevent double fast-paint
  bool _uiLoggedOnce = false; // debug: only log UI decision once
  bool _overlayLogged = false;
  bool _firstRowsLogged = false;

  //Refresh bits
  final Map<String, DateTime> _selfHealLastRun = <String, DateTime>{};
  static const Duration _selfHealCooldown = Duration(seconds: 12);
  late final AnimationController _sparkleCtrl;
  bool _showSparkles = false;
  final ValueNotifier<bool> _isMergingBB2 = ValueNotifier<bool>(false);
  bool _openingMergePhase = true; // latch merge lock during WES open


  //autosave bits
  // ---- NEW: State fields ----
  bool _pendingChanges = false;
  bool _lifecycleSaveInFlight = false; // prevents overlapping lifecycle saves
  String? _lastSavedHash; // to skip redundant writes on exit
  final Set<String> _savedExerciseKeysForDate = {}; // local UI "saved format"

// Deterministic doc id for this date
  String _workoutDocIdForDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

// Stable exercise key (name + circuitIndex)
  String _exerciseKey(String name, int circuitIndex) =>
      '${name.trim()}__$circuitIndex';

  String _wesKeyPrefId(String name, int circuitIndex) {
    final id = PeriodizationModelUtils.nameToId[name] ?? name;
    return '$id|$circuitIndex';
  }

// set 2 & 3 hint logic functions 14th Sep 2025...

  // ─────────────────────────────────────────────────────────────────────────────
  // Set 2+ hint synthesis (grouped logic, RIR-gated, cumulative drops)
  // ─────────────────────────────────────────────────────────────────────────────

  // name → category cache for WES session (fetched from `exercises` if unseen)
  final Map<String, String> _categoryByNameCache = {};

  Future<String?> _getExerciseCategoryByName(String name) async {
    final key = name.trim().toLowerCase();
    if (_categoryByNameCache.containsKey(key)) return _categoryByNameCache[key];

    try {
      final snap = await FirebaseFirestore.instance
          .collection('exercises')
          .where('name', isEqualTo: name)
          .limit(1)
          .get();
      if (snap.docs.isNotEmpty) {
        final cat = (snap.docs.first.data()['category'] as String?)?.trim();
        if (cat != null && cat.isNotEmpty) {
          _categoryByNameCache[key] = cat;
          return cat;
        }
      }
    } catch (_) {}
    return null;
  }

  void _debugRowSetCounts(String tag) {
    final buf = StringBuffer('$tag — row setCounts: ');
    for (int i = 0; i < _workoutSets.length; i++) {
      buf.write('r$i=${_workoutSets[i].length} ');
    }
    print(buf.toString());
  }

  void _debugLogCardsForSelectedDate(String tag) {
    try {
      final String ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);
      print('📋 [$tag Summary] date=$ymd');

      int found = 0;
      for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
        final row = _selectedExercisesWithCircuits[i];
        final String card = (row['cardId'] ?? '').toString();
        final String name = ((row['name'] ?? '') as String).trim();

        // classify
        final bool isBB2Today  = card.startsWith('bb2|$ymd|');
        final bool isPlanToday = card.startsWith('$ymd|plan|');

        // Only show rows for the selected date. If you want literally all rows, remove the two checks below.
        if (!isBB2Today && !isPlanToday) continue;

        final s0 = (_workoutSets.length > i && _workoutSets[i].isNotEmpty)
            ? _workoutSets[i][0]
            : null;

        // prefer SetDetails; fall back to controller texts
        final repsVal = s0?.reps ?? (
            (_repsControllers.length > i && _repsControllers[i].isNotEmpty)
                ? int.tryParse(_repsControllers[i][0].text)
                : null
        );

        final weightVal = s0?.weight ?? (
            (_weightControllers.length > i && _weightControllers[i].isNotEmpty)
                ? double.tryParse(_weightControllers[i][0].text)
                : null
        );

        final rirVal = s0?.rir ?? (
            (_rirControllers.length > i && _rirControllers[i].isNotEmpty)
                ? double.tryParse(_rirControllers[i][0].text)
                : null
        );

        found++;
        print(
            '${isBB2Today ? "✅ [BB2→UI]" : "🟣 [PLAN→UI]"} '
                'name="$name"  card="$card"  '
                'S1(reps=${repsVal ?? '—'}, weight=${weightVal ?? '—'}, rir=${rirVal ?? '—'})'
        );
      }
      if (found == 0) {
        print('∅ [$tag Summary] no BB2/PLAN rows in UI for date=$ymd');
      }
    } catch (e) {
      print('⚠️ [$tag Summary] logging failed: $e');
    }
  }
  Future<void> debugPrintWesDayCache(String uid, DateTime date) async {
    final dateKey = DateFormat('yyyy-MM-dd').format(date);
    final isar = await IsarDb.instance;

    final rec = await isar.workoutDayCaches
        .where()
        .filter()
        .uidEqualTo(uid)
        .and()
        .dateKeyEqualTo(dateKey)
        .findFirst();

    if (rec == null) {
      print('🗃️ [WES LocalCache] No record for $dateKey (uid=$uid)');
      return;
    }

    final exList = jsonDecode(rec.exListJson) as List<dynamic>;
    final wesPlanned = jsonDecode(rec.wesPlannedJson) as List<dynamic>;

    print('🗃️ [WES LocalCache] $dateKey (uid=$uid)');
    print('   • exList (${exList.length}):');
    for (final ex in exList) {
      final m = Map<String, dynamic>.from(ex as Map);
      print('     - ${m['name']} (wt=${m['weight']} reps=${m['reps']} rir=${m['rir']} ci=${m['circuitIndex']})');
    }
    print('   • wesPlanned (${wesPlanned.length}):');
    for (final ex in wesPlanned) {
      final m = Map<String, dynamic>.from(ex as Map);
      print('     - ${m['name']} (ci=${m['circuitIndex']})');
    }
  }

  Future<void> debugPrintWesInitSnapshot({
    required String uid,
    required String blockId,
    required DateTime date,
  }) async {
    final ymd = DateFormat('yyyy-MM-dd').format(date);
    final snap = await BlockPlanCache.getInitSnapshot(
      uid: uid,
      blockId: blockId,
      dateYmd: ymd,
    );

    if (snap == null) {
      print('🗃️ [WESInit] No snapshot for $ymd (uid=$uid block=$blockId)');
      return;
    }

    List<Map<String, dynamic>> _parse(String s) {
      if (s.isEmpty) return const [];
      final raw = jsonDecode(s);
      if (raw is! List) return const [];
      return raw.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
    }

    final planned        = _parse(snap.plannedExercisesJson);
    final wesPlanned     = _parse(snap.wesPlannedExercisesJson);
    final previous       = _parse(snap.previousWorkoutJson);

    print('🗃️ [WESInit] $ymd  planned=${planned.length}  wesPlanned=${wesPlanned.length}  previous=${previous.length}');
    if (planned.isNotEmpty) {
      print('   • planned:');
      for (final m in planned) {
        print('     - ${m['name']} (ci=${m['circuitIndex']})');
      }
    }
    if (wesPlanned.isNotEmpty) {
      print('   • wesPlanned:');
      for (final m in wesPlanned) {
        print('     - ${m['name']} (ci=${m['circuitIndex']})');
      }
    }
  }

  /// Provide [getWesDraftKeyForDate] if you want the function to also remove your WES draft.
  Future<void> nukeLocalWorkoutsForDay({
    required String uid,
    required String blockId,
    required DateTime date,
    DateTime? blockStartDate,
    String Function(DateTime date)? getWesDraftKeyForDate,
  }) async {
    final ymd = DateFormat('yyyy-MM-dd').format(date);
    print('🧨 [NUKE] Begin local wipe → uid=$uid block=$blockId date=$ymd');

    // ---------- ISAR: open once ----------
    final isar = await IsarDb.instance;

    // ---------- 1) WESInitSnapshot (FastPaint super-cache) ----------
    try {
      final toDelete = await isar.wESInitSnapshots
          .filter()
          .uidEqualTo(uid)
          .and()
          .blockIdEqualTo(blockId)
          .and()
          .dateYmdEqualTo(ymd)
          .findAll();

      if (toDelete.isNotEmpty) {
        await isar.writeTxn(() async {
          await isar.wESInitSnapshots.deleteAll(toDelete.map((e) => e.id).toList());
        });
        print('🗑️ [NUKE→WESInit] removed ${toDelete.length} snapshot(s) for $ymd');
      } else {
        print('ℹ️ [NUKE→WESInit] none for $ymd');
      }
    } catch (e) {
      print('⚠️ [NUKE→WESInit] failed: $e');
    }

    // ---------- 2) WorkoutDayCache (WES local day cache: exList/wesPlanned) ----------
    try {
      final recs = await isar.workoutDayCaches
          .filter()
          .uidEqualTo(uid)
          .and()
          .dateKeyEqualTo(ymd)
          .findAll();

      if (recs.isNotEmpty) {
        await isar.writeTxn(() async {
          await isar.workoutDayCaches.deleteAll(recs.map((e) => e.id).toList());
        });
        print('🗑️ [NUKE→WorkoutDayCache] removed ${recs.length} record(s) for $ymd');
      } else {
        print('ℹ️ [NUKE→WorkoutDayCache] none for $ymd');
      }
    } catch (e) {
      print('⚠️ [NUKE→WorkoutDayCache] failed: $e');
    }

    // ---------- 3) BB2 BlockDay (super-cache used by Warmup/FastPaint) ----------
    try {
      if (blockStartDate == null) {
        print('🚧 [NUKE→BB2] skipped (blockStartDate is null)');
      } else {
        final days = date.difference(blockStartDate).inDays;
        if (days < 0) {
          print('🚧 [NUKE→BB2] skipped (date < blockStartDate)');
        } else {
          final weekIndex = days ~/ 7;
          final dayIndex  = days % 7;
          final id = blockDayId(uid, blockId, weekIndex, dayIndex);

          final existed = await isar.blockDays.get(id) != null;
          await isar.writeTxn(() async {
            await isar.blockDays.delete(id);
          });
          if (existed) {
            print('🗑️ [NUKE→BB2] removed BlockDay w$weekIndex d$dayIndex (id=$id)');
          } else {
            print('ℹ️ [NUKE→BB2] no BlockDay for w$weekIndex d$dayIndex');
          }
        }
      }
    } catch (e) {
      print('⚠️ [NUKE→BB2] failed: $e');
    }

    // ---------- 4) SharedPreferences ----------
    try {
      final prefs = await SharedPreferences.getInstance();

      // 4a) WES draft for this date (if caller provides a key resolver)
      if (getWesDraftKeyForDate != null) {
        final k = getWesDraftKeyForDate(date);
        final had = prefs.containsKey(k);
        if (had) {
          await prefs.remove(k);
          print('🗑️ [NUKE→Prefs] removed WES draft "$k"');
        } else {
          print('ℹ️ [NUKE→Prefs] no WES draft "$k"');
        }
      } else {
        print('ℹ️ [NUKE→Prefs] WES draft skipped (no key resolver provided)');
      }

      // 4b) BB2 per-day JSON (your BB2 saver uses this key)
      final bb2Key = 'bb2_dayData_$ymd';
      final hadBb2 = prefs.containsKey(bb2Key);
      if (hadBb2) {
        await prefs.remove(bb2Key);
        print('🗑️ [NUKE→Prefs] removed "$bb2Key"');
      } else {
        print('ℹ️ [NUKE→Prefs] no "$bb2Key"');
      }
    } catch (e) {
      print('⚠️ [NUKE→Prefs] failed: $e');
    }

    print('✅ [NUKE] local wipe complete for $ymd');
  }

  /// Safe to run any time. Best-effort with verbose prints.
  Future<void> nukeAllWesPlannedAndLocalCaches({
    required String uid,
    String? blockId, // optional: if provided, restrict BB2 local wipe to this block
  }) async {
    final sw = Stopwatch()..start();
    print('🧨 [NUKE*] Begin full wipe → uid=$uid block=${blockId ?? "(all)"}');

    int fsDocsTouched = 0;
    int isarWesInitDel = 0;
    int isarWdcDel = 0;
    int isarBb2Del = 0;
    int prefsDraftDel = 0;
    int prefsBb2Del = 0;
    int prefsWarmKeys = 0;

    // ─────────────── Firestore: wipe wesPlannedExercises on every workout doc ───────────────
    try {
      final fs = FirebaseFirestore.instance;
      final col = fs.collection('users').doc(uid).collection('workouts');

      // Page through the collection in batches (server-backed read).
      QueryDocumentSnapshot<Map<String, dynamic>>? lastDoc;
      const batchSize = 200;
      while (true) {
        firebase_firestore.Query<Map<String, dynamic>> q = col.orderBy(FieldPath.documentId).limit(batchSize);

        if (lastDoc != null) q = q.startAfterDocument(lastDoc);

        final page = await q.get(const GetOptions(source: Source.server));
        if (page.docs.isEmpty) break;

        final writes = <Future<void>>[];
        for (final d in page.docs) {
          // Set to [] (don’t delete the field; explicit empty is clearer)
          writes.add(d.reference.set(
            {'wesPlannedExercises': <Map<String, dynamic>>[]},
            SetOptions(merge: true),
          ));
        }
        await Future.wait(writes);
        fsDocsTouched += page.docs.length;
        lastDoc = page.docs.last;
        if (page.docs.length < batchSize) break;
      }
      print('🗑️ [NUKE*→FS] cleared wesPlannedExercises on $fsDocsTouched workout doc(s)');
    } catch (e) {
      print('🟥 [NUKE*→FS] failed: $e');
    }

    // ─────────────── ISAR: wipe local caches for this uid ───────────────
    try {
      final isar = await IsarDb.instance;

      await isar.writeTxn(() async {
        // WESInitSnapshot
        isarWesInitDel = await isar.wESInitSnapshots
            .filter()
            .uidEqualTo(uid)
            .deleteAll();

        // WorkoutDayCache
        isarWdcDel = await isar.workoutDayCaches
            .filter()
            .uidEqualTo(uid)
            .deleteAll();

        // BlockDay (BB2 local plan cache) — optionally scope to a single block
        if (blockId == null || blockId.isEmpty) {
          isarBb2Del = await isar.blockDays
              .filter()
              .uidEqualTo(uid)
              .deleteAll();
        } else {
          isarBb2Del = await isar.blockDays
              .filter()
              .uidEqualTo(uid)
              .and()
              .blockIdEqualTo(blockId)
              .deleteAll();
        }
      });

      print('🗑️ [NUKE*→ISAR] WESInit=$isarWesInitDel WDC=$isarWdcDel BB2=$isarBb2Del');
    } catch (e) {
      print('🟥 [NUKE*→ISAR] failed: $e');
    }

    // ─────────────── SharedPreferences: wipe WES drafts + BB2 dayData + warmup cooldowns ───────────────
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().toList();

      // WES drafts are keyed like "wes_draft_{uid}_{YYYY-MM-DD}"
      for (final k in keys.where((k) => k.startsWith('wes_draft_${uid}_'))) {
        await prefs.remove(k);
        prefsDraftDel++;
      }

      // BB2 day cache in prefs is keyed like "bb2_dayData_{YYYY-MM-DD}" (no uid)
      for (final k in keys.where((k) => k.startsWith('bb2_dayData_'))) {
        await prefs.remove(k);
        prefsBb2Del++;
      }

      // Warmup cooldowns so we don’t instant rewarm stale shapes
      for (final k in keys.where((k) =>
      k == 'wes_warm_last:$uid' || k == 'wes_warm_exercises_last')) {
        await prefs.remove(k);
        prefsWarmKeys++;
      }

      print('🗑️ [NUKE*→Prefs] drafts=$prefsDraftDel bb2Days=$prefsBb2Del warmKeys=$prefsWarmKeys');
    } catch (e) {
      print('🟥 [NUKE*→Prefs] failed: $e');
    }

    sw.stop();
    print('✅ [NUKE*] complete in ${sw.elapsedMilliseconds}ms '
        '(FS:$fsDocsTouched, WESInit:$isarWesInitDel, WDC:$isarWdcDel, BB2:$isarBb2Del, '
        'prefs: drafts=$prefsDraftDel bb2=$prefsBb2Del warm=$prefsWarmKeys)');
  }


  String _nukeSnackMessage({
    required String? sexRaw,
    required String? dobRaw,
  }) {
    const fallback = '💥 Workout is deleted af now';

    print('🧪 [NukeMsg] ENTRY sexRaw="$sexRaw" dobRaw="$dobRaw"');

    final sex = (sexRaw ?? '').trim().toUpperCase();
    final dob = (dobRaw ?? '').trim();

    if (sex.isEmpty) {
      print('🧪 [NukeMsg] FALLBACK → sex empty/null');
      return fallback;
    }

    if (dob.isEmpty) {
      print('🧪 [NukeMsg] FALLBACK → dob empty/null');
      return fallback;
    }

    int? year;

    final parts = dob.split('-');
    print('🧪 [NukeMsg] dob parts=$parts');

    if (parts.length == 3) {
      // yyyy-mm-dd
      if (parts[0].length == 4) {
        year = int.tryParse(parts[0]);
        print('🧪 [NukeMsg] Parsed yyyy-mm-dd → year=$year');
      }
      // dd-mm-yyyy
      else if (parts[2].length == 4) {
        year = int.tryParse(parts[2]);
        print('🧪 [NukeMsg] Parsed dd-mm-yyyy → year=$year');
      } else {
        print('🧪 [NukeMsg] FALLBACK → unrecognised dob format');
      }
    } else {
      print('🧪 [NukeMsg] FALLBACK → dob does not have 3 parts');
    }

    if (year == null) {
      print('🧪 [NukeMsg] FALLBACK → year == null after parse');
      return fallback;
    }

    final bornBefore1999 = year <= 1998;
    print('🧪 [NukeMsg] sex=$sex bornBefore1999=$bornBefore1999');

    if (sex == 'M' && bornBefore1999) {
      return '💥 That workout is gone, bro.';
    }
    if (sex == 'M' && !bornBefore1999) {
      return '💥 Bro, that workout never happened.';
    }
    if (sex == 'F' && bornBefore1999) {
      return '💥 All cleared — you’re good to go.';
    }
    if (sex == 'F' && !bornBefore1999) {
      return '💥 Gone and dusted, queen.';
    }

    print('🧪 [NukeMsg] FALLBACK → sex not M/F (sex="$sex")');
    return fallback;
  }

  String _hintsReadySnackMessage({
    required String? sexRaw,
    required String? dobRaw,
  }) {
    const fallback = 'Suggested weights and reps are ready';

    final sex = (sexRaw ?? '').trim().toUpperCase();
    final dob = (dobRaw ?? '').trim();

    if (sex.isEmpty || dob.isEmpty) return fallback;

    int? year;
    final parts = dob.split('-');
    if (parts.length == 3) {
      if (parts[0].length == 4) year = int.tryParse(parts[0]);      // yyyy-mm-dd
      else if (parts[2].length == 4) year = int.tryParse(parts[2]); // dd-mm-yyyy
    }
    if (year == null) return fallback;

    final bornBefore1999 = year <= 1998;

    if (sex == 'M' && !bornBefore1999) return 'Dialled in, mate — your suggested weights and reps are ready.';
    if (sex == 'M' && bornBefore1999)  return 'All sorted — suggested weights and rep targets are ready.';
    if (sex == 'F' && !bornBefore1999) return 'Ready, queen — suggested weights and rep targets are set.';
    if (sex == 'F' && bornBefore1999)  return 'Good to go — your suggested weights and rep targets are ready.';

    return fallback;
  }



  Future<void> _deleteExerciseEverywhereForDate({
    required Map<String, dynamic> exerciseRow,
    required DateTime date,
  }) async {
    final uid = _cachedUid ??
        UserContext.of(context, listen: false).currentUid!;
    final blockId = _selectedBlockId ?? _activeBlockId!;
    final ymd = DateFormat('yyyy-MM-dd').format(date);

    final String removedName =
    ((exerciseRow['name'] ?? exerciseRow['exerciseName'] ?? '') as String)
        .trim();
    final int removedCi = (exerciseRow['circuitIndex'] is num)
        ? (exerciseRow['circuitIndex'] as num).toInt()
        : 0;
    final String? removedExId =
    (exerciseRow['exerciseId'] ?? exerciseRow['id'])?.toString();


    debugPrint(
        '🧨 [DEL] removing exercise "$removedName" (id=$removedExId ci=$removedCi) '
            'for uid=$uid block=$blockId date=$ymd');

    // ───────── 1) Firestore: wesPlannedExercises for that date ─────────
    try {
      final fs = FirebaseFirestore.instance;
      final docRef = fs
          .collection('users')
          .doc(uid)
          .collection('workouts')
          .doc(ymd);

      await fs.runTransaction((tx) async {
        final snap = await tx.get(docRef);
        if (!snap.exists) {
          debugPrint('ℹ️ [DEL→FS] no workout doc for $ymd');
          return;
        }

        final data =
            (snap.data() as Map<String, dynamic>?) ?? <String, dynamic>{};

        final rawPlanned    = data['wesPlannedExercises'];
        final rawExercises  = data['exercises'];

        final Map<String, dynamic> updates = {};

// 📝 1) Prune wesPlannedExercises if present
        if (rawPlanned is List) {
          final filteredPlanned = rawPlanned
              .where((e) =>
          !_isSameExerciseRow(e, removedExId, removedName, removedCi))
              .toList();
          updates['wesPlannedExercises'] = filteredPlanned;
        } else {
          debugPrint(
              'ℹ️ [DEL→FS] "wesPlannedExercises" not a List for $ymd; skipping that field');
        }

// 📝 2) Prune COMPLETED exercises list as well
        if (rawExercises is List) {
          final filteredExercises = rawExercises
              .where((e) =>
          !_isSameExerciseRow(e, removedExId, removedName, removedCi))
              .toList();
          updates['exercises'] = filteredExercises;
        }

// Only write if something to update
        if (updates.isNotEmpty) {
          tx.update(docRef, updates);
        }

      });

      debugPrint('🗑️ [DEL→FS] pruned wesPlannedExercises for $ymd');
    } catch (e) {
      debugPrint('🟥 [DEL→FS] failed: $e');
    }

    // ───────── 2) ISAR: WESInitSnapshot + WorkoutDayCache for that date ─────────
    try {
      final isar = await IsarDb.instance;

      await isar.writeTxn(() async {
        // 2a) WESInitSnapshot (FastPaint super-cache)
        final initSnaps = await isar.wESInitSnapshots
            .filter()
            .uidEqualTo(uid)
            .and()
            .blockIdEqualTo(blockId)
            .and()
            .dateYmdEqualTo(ymd)
            .findAll();

        for (final snap in initSnaps) {
          bool changed = false;

          // 2a) plannedExercisesJson: list of planned exercises
          try {
            final planned =
                (jsonDecode(snap.plannedExercisesJson) as List?) ?? <dynamic>[];
            final filteredPlanned = planned
                .where((e) =>
            !_isSameExerciseRow(e, removedExId, removedName, removedCi))
                .toList();
            if (filteredPlanned.length != planned.length) {
              snap.plannedExercisesJson = jsonEncode(filteredPlanned);
              changed = true;
            }
          } catch (e) {
            debugPrint('⚠️ [DEL→ISAR] failed to prune plannedExercisesJson: $e');
          }

          // 2b) wesPlannedExercisesJson: list of WES-planned exercises
          try {
            final wesPlanned =
                (jsonDecode(snap.wesPlannedExercisesJson) as List?) ?? <dynamic>[];
            final filteredWesPlanned = wesPlanned
                .where((e) =>
            !_isSameExerciseRow(e, removedExId, removedName, removedCi))
                .toList();
            if (filteredWesPlanned.length != wesPlanned.length) {
              snap.wesPlannedExercisesJson = jsonEncode(filteredWesPlanned);
              changed = true;
            }
          } catch (e) {
            debugPrint(
                '⚠️ [DEL→ISAR] failed to prune wesPlannedExercisesJson: $e');
          }

          // 2c) 🔥 NEW: previousWorkoutJson – this is what _loadExistingWorkoutIfAny uses for exList
          try {
            if ((snap.previousWorkoutJson ?? '').isNotEmpty) {
              final prev =
                  (jsonDecode(snap.previousWorkoutJson) as List?) ?? <dynamic>[];
              final filteredPrev = prev
                  .where((e) =>
              !_isSameExerciseRow(e, removedExId, removedName, removedCi))
                  .toList();
              if (filteredPrev.length != prev.length) {
                snap.previousWorkoutJson = jsonEncode(filteredPrev);
                changed = true;
              }
            }
          } catch (e) {
            debugPrint(
                '⚠️ [DEL→ISAR] failed to prune previousWorkoutJson: $e');
          }

          if (changed) {
            await isar.wESInitSnapshots.put(snap);
          }
        }


        // 2b) WorkoutDayCache (WES local day cache)
        final dayCaches = await isar.workoutDayCaches
            .filter()
            .uidEqualTo(uid)
            .and()
            .dateKeyEqualTo(ymd)
            .findAll();

        for (final cache in dayCaches) {
          // exListJson: exercises list used to rebuild rows
          try {
            final exList =
                (jsonDecode(cache.exListJson) as List?) ?? <dynamic>[];
            final filteredExList = exList
                .where((e) =>
            !_isSameExerciseRow(e, removedExId, removedName, removedCi))
                .toList();
            cache.exListJson = jsonEncode(filteredExList);
          } catch (e) {
            debugPrint('⚠️ [DEL→ISAR] failed to prune exListJson: $e');
          }

          // wesPlannedJson: cached wesPlannedExercises[]
          try {
            final wesPlanned =
                (jsonDecode(cache.wesPlannedJson) as List?) ?? <dynamic>[];
            final filteredWesPlanned = wesPlanned
                .where((e) =>
            !_isSameExerciseRow(e, removedExId, removedName, removedCi))
                .toList();
            cache.wesPlannedJson = jsonEncode(filteredWesPlanned);
          } catch (e) {
            debugPrint('⚠️ [DEL→ISAR] failed to prune wesPlannedJson: $e');
          }

          await isar.workoutDayCaches.put(cache);
        }
      });

      debugPrint('🗑️ [DEL→ISAR] pruned WESInitSnapshot + WorkoutDayCache for $ymd');
    } catch (e) {
      debugPrint('🟥 [DEL→ISAR] failed: $e');
    }

    // ───────── 2c) ISAR: claudeBulletSnapshots for that uid+date ─────────
    try {
      final isar = await IsarDb.instance;
      final uidDateKey = '$uid|$ymd';

      await isar.writeTxn(() async {
        final cbSnap = await isar.claudeBulletSnapshots
            .filter()
            .uidDateKeyEqualTo(uidDateKey)
            .findFirst();

        if (cbSnap != null) {
          final data = jsonDecode(cbSnap.snapshotJson) as Map<String, dynamic>;
          final exercises = (data['exercises'] as List?) ?? [];
          final filtered = exercises
              .where((e) =>
                  !_isSameExerciseRow(e, removedExId, removedName, removedCi))
              .toList();

          if (filtered.length != exercises.length) {
            data['exercises'] = filtered;
            cbSnap.snapshotJson = jsonEncode(data);
            await isar.claudeBulletSnapshots.put(cbSnap);
            debugPrint('🗑️ [DEL→ISAR] pruned claudeBulletSnapshot for $uidDateKey');
          }
        }
      });
    } catch (e) {
      debugPrint('🟥 [DEL→ISAR CB] failed: $e');
    }

    // ───────── 3) SharedPreferences: WES draft + BB2 day JSON for that date ─────────
    try {
      final prefs = await SharedPreferences.getInstance();

      // 3a) WES draft (same key pattern used in nukeLocalWorkoutsForDay)
      final draftKey = _getDraftKeyFor(date);
      if (prefs.containsKey(draftKey)) {
        final raw = prefs.getString(draftKey);
        if (raw != null) {
          final map = jsonDecode(raw) as Map<String, dynamic>;

          final exList =
              (map['selectedExercisesWithCircuits'] as List?) ?? <dynamic>[];
          map['selectedExercisesWithCircuits'] = exList
              .where((e) =>
          !_isSameExerciseRow(e, removedExId, removedName, removedCi))
              .toList();

          await prefs.setString(draftKey, jsonEncode(map));
          debugPrint('🗑️ [DEL→Prefs] pruned WES draft "$draftKey"');
        }
      } else {
        debugPrint('ℹ️ [DEL→Prefs] no WES draft "$draftKey"');
      }

      // 3b) BB2 per-day JSON (if you want to also prune this; your BB2 helper
      //     may already cover part of this via _pruneBb2DayCacheForSelectedDate)
      final bb2Key = 'bb2_dayData_$ymd';
      if (prefs.containsKey(bb2Key)) {
        final raw = prefs.getString(bb2Key);
        if (raw != null) {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          final exList = (map['exList'] as List?) ?? <dynamic>[];

          map['exList'] = exList
              .where((e) =>
          !_isSameExerciseRow(e, removedExId, removedName, removedCi))
              .toList();

          await prefs.setString(bb2Key, jsonEncode(map));
          debugPrint('🗑️ [DEL→Prefs] pruned "$bb2Key"');
        }
      } else {
        debugPrint('ℹ️ [DEL→Prefs] no "$bb2Key"');
      }
    } catch (e) {
      debugPrint('🟥 [DEL→Prefs] failed: $e');
    }

    // ───────── 4) In-memory _exitDraft: prune deleted exercise ─────────
    if (_exitDraft != null &&
        _exitDraft!['dateKey'] == ymd &&
        _exitDraft!['uid'] == uid) {
      try {
        final draftEx = (_exitDraft!['exercises'] as List?) ?? [];
        final draftSets = (_exitDraft!['sets'] as List?) ?? [];
        final indicesToRemove = <int>[];

        for (int di = 0; di < draftEx.length; di++) {
          if (_isSameExerciseRow(draftEx[di], removedExId, removedName, removedCi)) {
            indicesToRemove.add(di);
          }
        }

        if (indicesToRemove.isNotEmpty) {
          for (final idx in indicesToRemove.reversed) {
            draftEx.removeAt(idx);
            if (idx < draftSets.length) draftSets.removeAt(idx);
          }
          debugPrint('🗑️ [DEL→exitDraft] pruned ${indicesToRemove.length} exercise(s)');
        }
      } catch (e) {
        debugPrint('🟥 [DEL→exitDraft] failed: $e');
      }
    }

    debugPrint('✅ [DEL] finished pruning exercise for $ymd');
  }


  String _getDraftKeyFor(DateTime d) {
    // if your _getDraftKey() currently uses _selectedDate internally,
    // copy its logic here but base it on `d` instead.
    final uid = _cachedUid ?? UserContext.of(context, listen:false).currentUid!;
    final ymd = DateFormat('yyyy-MM-dd').format(d);
    return 'wes_draft_${uid}_$ymd'; // <-- replace with your actual convention
  }

  /// Decide how many sets to create for this exercise based on BP repTargets.
  /// Falls back to _defaultSets if anything is missing / malformed.
  ///
  /// Expects repTargets to look like:
  /// repTargets: {
  ///   week1: { instance1: "9 x 4", instance2: "2 x 5", ... },
  ///   week2: { ... }
  /// }



  String _normNameBB2(String s) {
    var t = s.toLowerCase().trim();
    t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
    t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');
    t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
    return t;
  }

  /// Remove a single exercise from the **BB2 day cache** (Isar BlockDay) for the currently selected date.
  /// Matches by exerciseId (if provided) OR by normalized name + circuitIndex.
  Future<void> _pruneBb2DayCacheForSelectedDate({
    required String name,
    required int circuitIndex,
    String? exerciseId,
  }) async {
    try {
      final uid = _cachedUid ?? UserContext.of(context, listen: false).currentUid;
      final blockId = _selectedBlockId ?? _activeBlockId;
      final bs = blockStartDate;
      if (uid == null || uid.isEmpty || blockId == null || bs == null) {
        print('🚧 [WES→BB2 Cache] skip prune (uid/blockId/blockStartDate missing)');
        return;
      }

      final daysSinceStart = _selectedDate.difference(bs).inDays;
      if (daysSinceStart < 0) {
        print('🚧 [WES→BB2 Cache] skip prune (selectedDate before blockStartDate)');
        return;
      }
      final weekIndex = daysSinceStart ~/ 7;
      final dayIndex = daysSinceStart % 7;

      final list = await BlockPlanCache.getDay(
        uid: uid,
        blockId: blockId,
        weekIndex: weekIndex,
        dayIndex: dayIndex,
      ) ?? const <Map<String, dynamic>>[];

      final before = list.length;
      if (before == 0) {
        print('ℹ️ [WES→BB2 Cache] nothing to prune (empty day cache) w$weekIndex d$dayIndex');
        return;
      }

      bool _matches(Map<String, dynamic> m) {
        final id = ((m['exerciseId'] ?? m['id'] ?? '') as String).trim();
        final nm = ((m['name'] ?? m['exercise'] ?? '') as String).trim();
        final ci = (m['circuitIndex'] is num) ? (m['circuitIndex'] as num).toInt() : 0;

        if (exerciseId != null && exerciseId.isNotEmpty) {
          if (id == exerciseId) return true;
        }
        return _normNameBB2(nm) == _normNameBB2(name) && ci == circuitIndex;
      }

      final filtered = <Map<String, dynamic>>[];
      for (final m in list) {
        final mm = Map<String, dynamic>.from(m);
        if (!_matches(mm)) filtered.add(mm);
      }
      final after = filtered.length;

      if (after != before) {
        await BlockPlanCache.putDay(
          uid: uid,
          blockId: blockId,
          weekIndex: weekIndex,
          dayIndex: dayIndex,
          exercises: filtered,
        );
        print('🗑️ [WES→BB2 Cache] pruned "$name"|ci=$circuitIndex w$weekIndex d$dayIndex: $before → $after (−${before - after})');
      } else {
        print('ℹ️ [WES→BB2 Cache] no match to prune for "$name"|ci=$circuitIndex (w$weekIndex d$dayIndex)');
      }
    } catch (e) {
      print('⚠️ [WES→BB2 Cache] prune failed: $e');
    }
  }

  bool _isSameExerciseRow(
      dynamic e,
      String? removedExId,
      String removedName,
      int removedCi,
      ) {
    if (e is! Map) return false;

    // Normalize map
    final map = Map<String, dynamic>.from(e as Map);

    // 1) Extract ID from the stored row
    final String? exId = (map['exerciseId'] ??
        map['exercise_id'] ??
        map['id'])
        ?.toString();

    // 2) Extract name, supporting both "name" and "exerciseName"
    final String name = (map['name'] ?? map['exerciseName'] ?? '')
        .toString()
        .trim();

    // 3) Extract circuit index (both spellings)
    final int ci = (map['circuitIndex'] is num)
        ? (map['circuitIndex'] as num).toInt()
        : (map['circuit_index'] is num)
        ? (map['circuit_index'] as num).toInt()
        : 0;

    // 🔥 PRIMARY MATCH: exerciseId match
    // If both sides have ids, and they match → delete it.
    if (removedExId != null && exId != null && exId == removedExId) {
      return true;
    }

    // 🔥 SECONDARY MATCH: name + circuitIndex
    // Used only when ID is missing.
    return name == removedName && ci == removedCi;
  }




  /// Restore the exercise back into the **BB2 day cache** (used by Undo).
  Future<void> _restoreBb2DayCacheForSelectedDate({
    required Map<String, dynamic> exerciseRow, // expects 'name' and 'circuitIndex' at minimum
  }) async {
    try {
      final uid = _cachedUid ?? UserContext.of(context, listen: false).currentUid;
      final blockId = _selectedBlockId ?? _activeBlockId;
      final bs = blockStartDate;
      if (uid == null || uid.isEmpty || blockId == null || bs == null) return;

      final daysSinceStart = _selectedDate.difference(bs).inDays;
      if (daysSinceStart < 0) return;
      final weekIndex = daysSinceStart ~/ 7;
      final dayIndex = daysSinceStart % 7;

      final list = await BlockPlanCache.getDay(
        uid: uid,
        blockId: blockId,
        weekIndex: weekIndex,
        dayIndex: dayIndex,
      ) ?? <Map<String, dynamic>>[];

      // Make a minimal BB2 map; keep any id if present.
      final restored = <String, dynamic>{
        'name': (exerciseRow['name'] ?? '').toString().trim(),
        'circuitIndex': (exerciseRow['circuitIndex'] is num)
            ? (exerciseRow['circuitIndex'] as num).toInt()
            : 0,
      };
      final exId = (exerciseRow['exerciseId'] ?? exerciseRow['id'])?.toString();
      if (exId != null && exId.isNotEmpty) restored['exerciseId'] = exId;

      list.add(restored);
      await BlockPlanCache.putDay(
        uid: uid,
        blockId: blockId,
        weekIndex: weekIndex,
        dayIndex: dayIndex,
        exercises: list,
      );
      print('↩️ [WES→BB2 Cache] restored "${restored['name']}"|ci=${restored['circuitIndex']} to w$weekIndex d$dayIndex (count=${list.length})');
    } catch (e) {
      print('⚠️ [WES→BB2 Cache] restore failed: $e');
    }
  }

  String formatRir(dynamic value) {
    if (value == null) return '';

    double? d;
    if (value is num) {
      d = value.toDouble();
    } else {
      d = double.tryParse(value.toString());
    }

    if (d == null) return '';

    // If it's a whole number, drop .0
    if (d % 1 == 0) {
      return d.toInt().toString();
    }

    // Otherwise return the decimal version
    return d.toString();
  }


  // Map exercise → Group A/B/C/D
  Future<String> _resolveGroupForExercise(String name) async {
    final n = name.trim();

    // Group A overrides by name (case-insensitive)
    const groupA = {
      'chin-up',
      'bench press, barbell',
      'bench press, narrow grip',
      'bench press, larsen press',
      'bench press, long pause',
      'back squat, barbell',
      'back squat, low bar',
      'back squat, paused squat',
      'back squat, pin squat',
      'deadlift, conventional',
      'deadlift, deficit',
      'deadlift, sumo',
      'deadlift, sumo, deficit',
      'romanian deadlift',
    };
    if (groupA.contains(n.toLowerCase())) return 'A';

    // Group B overrides by name
    const groupB = {
      'overhead dumbbell press, unilateral',
      'overhead barbell press',
    };
    if (groupB.contains(n.toLowerCase())) return 'B';

    // Else by category
    final cat = await _getExerciseCategoryByName(n) ?? '';
    final c = cat.toLowerCase();
    const groupC = {
      'horizontal press',
      'horizontal pull',
      'vertical press',
      'vertical pull',
      'squat pattern',
      'hip hinge',
    };
    const groupD = {
      'lateral raise',
      'arm extension',
      'arm curl',
      'leg extension',
      'leg curl',
      'hip abduction/adduction',
      'calf raise',
      'core',
    };
    if (groupC.contains(c)) return 'C';
    if (groupD.contains(c)) return 'D';
    // default to C (compound-ish behavior) if unknown
    return 'C';
  }

  // Per-group per-set drop (kg) for setIndex ≥ 2, before RIR gating
  double _rawDropFor(String group, int setIndex) {
    // 0 = Set 1 → no drop
    if (setIndex == 0) return 0.0;

    switch (group) {
      case 'A':
      // Bench/Squat/Deadlift/Chin-up: −5.5 kg every set ≥2
        return 5.5;

      case 'B':
      // Uni DB Shoulder Press / Barbell OHP:
      // Set 2 (idx=1): −1.5, Set 3 (idx=2): −4.3, Set 4+ (idx>=3): −1.5
        if (setIndex == 1) return 1.5; // Set 2
        if (setIndex == 2) return 4.3; // Set 3
        return 1.5; // Set 4+

      case 'C':
      // Other push/pull/squat/hinge: −1.0 each set ≥2
        return 1.0;

      case 'D':
      // Arms/iso/core: −0.3 each set ≥2
        return 0.3;

      default:
        return 1.0;
    }
  }


  // Apply RIR gating to drop (use prev set's RIR: typed if present else hint)
  double _gatedDrop({
    required double baseDrop,
    required double prevSetRIR,
  }) {
    if (prevSetRIR > 2.0) return 0.0;
    if (prevSetRIR >= 1.8 && prevSetRIR <= 2.0) return baseDrop * 0.8;
    return baseDrop;
  }

  // Utility: get typed-or-hint for a controller field
  double _typedOrHintWeightAbs({
    required int exIdx,
    required int setIdx,
  }) {
    final name = (_selectedExercisesWithCircuits[exIdx]['name'] as String?)
        ?.trim() ?? '';
    final isBw = PeriodizationModelUtils.isBodyweightExercise(name: name);

    final typedText = _weightControllers[exIdx][setIdx].text.trim();
    double displayWeight = 0.0;
    if (typedText.isNotEmpty) {
      displayWeight = double.tryParse(typedText) ?? 0.0;
    } else {
      // fallback to hint mid-values
      if (setIdx == 0) {
        displayWeight = set1SuggestedWeight(exIdx); // ← Set 1 untouched
      } else {
        displayWeight = suggestedWeightForSet(exIdx, setIdx); // ← S2+
      }
    }

    if (!isBw) return displayWeight;

    // convert to absolute for BW math
    final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    return PeriodizationModelUtils.toAbsoluteWeight(
      uid: uid,
      displayAddedKg: displayWeight,
      exerciseName: name,
      asOfDate: _selectedDate,
    );
  }

  int _typedOrHintReps({required int exIdx, required int setIdx}) {
    final typedText = _repsControllers[exIdx][setIdx].text.trim();
    if (typedText.isNotEmpty) {
      final v = int.tryParse(typedText);
      if (v != null && v > 0) return v;
    }
    if (setIdx == 0)
      return set1SuggestedReps(exIdx).toInt(); // ← Set 1 untouched
    return suggestedRepsForSet(exIdx, setIdx).toInt(); // ← S2+

  }

  double _typedOrHintRIR({required int exIdx, required int setIdx}) {
    // setIdx is 0-based; planner getter expects 1-based
    final txt = _rirControllers[exIdx][setIdx].text.trim();
    if (txt.isNotEmpty) {
      final v = double.tryParse(txt);
      if (v != null) return v;
    }
    // fallback to the same hint RIR the UI shows for that set
    return getRirFromPlanOrInput(exIdx, setIdx + 1);
  }


  // Compute the actual E1RM for a given set (typed wins, else hint)
  double _actualE1RMForSet(int exIdx, int setIdx) {
    final weightAbs = _typedOrHintWeightAbs(exIdx: exIdx, setIdx: setIdx);
    final reps = _typedOrHintReps(exIdx: exIdx, setIdx: setIdx);
    final rir = _typedOrHintRIR(exIdx: exIdx, setIdx: setIdx);
    return PeriodizationModelUtils.calculateE1RM(
        weightAbs, reps.toDouble(), rir);
  }

  // Compute target E1RM for setIdx (≥2), cumulative from prior set actual/target with RIR gating
  Future<double> _targetE1RMForSet(int exIdx, int setIdx) async {
    // ── Per-keystroke memo: stable identity key (same derivation as _mergeNewBB2ExercisesIntoDraft) ──
    final _mRow  = _selectedExercisesWithCircuits[exIdx];
    final _mName = ((_mRow['name'] ?? '') as String).trim();
    final _mRawId = (_mRow['exerciseId'] ?? _mRow['id'])?.toString().trim() ?? '';
    final _mExId  = _mRawId.isNotEmpty ? _mRawId : (PeriodizationModelUtils.nameToId[_mName] ?? _mName);
    final _mCi    = (_mRow['circuitIndex'] is num)
        ? (_mRow['circuitIndex'] as num).toInt()
        : int.tryParse(_mRow['circuitIndex']?.toString() ?? '') ?? 0;
    final _memoKey = '${_mExId.toLowerCase().trim()}|$_mCi|$setIdx';
    final _memoHit = _e1rmTargetCache[_memoKey];
    if (_memoHit != null) return _memoHit;

    if (setIdx == 0) {
      final base = _actualE1RMForSet(exIdx, 0);
      // [perf] print removed from hot path
      _e1rmTargetCache[_memoKey] = base;
      return base;
    }
    final name = (_selectedExercisesWithCircuits[exIdx]['name'] as String?)
        ?.trim() ?? '';
    final group = await _resolveGroupForExercise(name);

    // previous set base: actual if any typed value present, else previous target
    bool prevAnyTyped = _weightControllers[exIdx][setIdx - 1].text
        .trim()
        .isNotEmpty ||
        _repsControllers[exIdx][setIdx - 1].text
            .trim()
            .isNotEmpty ||
        _rirControllers[exIdx][setIdx - 1].text
            .trim()
            .isNotEmpty;

    final prevTarget = await _targetE1RMForSet(exIdx, setIdx - 1);
    final prevActual = _actualE1RMForSet(exIdx, setIdx - 1);
// Use tolerance to treat “typed equals hinted” as the same base
    final tolBase = (group == 'D') ? 0.3 : 0.7;
    final baseE1RM = (prevAnyTyped && (prevActual - prevTarget).abs() > tolBase)
        ? prevActual
        : prevTarget;


    final prevRIR = _typedOrHintRIR(exIdx: exIdx, setIdx: setIdx - 1);
    final dropRaw = _rawDropFor(group, setIdx);
    final dropGated = _gatedDrop(baseDrop: dropRaw, prevSetRIR: prevRIR);

    final target = (baseE1RM - dropGated).clamp(1.0, 9999.0);
    // [perf] print removed from hot path
    _e1rmTargetCache[_memoKey] = target;
    return target;
  }

  // Build ranges + mid for current set
  Future<({List<double> weightRangeDisplay, List<
      int> repsRange, double weightMidDisplay, int repsMid, double e1rmMid})>
  _synthesizeHintsForSet(int exIdx, int setIdx) async {
    assert(setIdx >= 1, 'Range synthesis is for set ≥ 2');

    // ── Per-keystroke memo: stable identity key ──
    final _sRow   = _selectedExercisesWithCircuits[exIdx];
    final _sName0 = ((_sRow['name'] ?? '') as String).trim();
    final _sRawId = (_sRow['exerciseId'] ?? _sRow['id'])?.toString().trim() ?? '';
    final _sExId  = _sRawId.isNotEmpty ? _sRawId : (PeriodizationModelUtils.nameToId[_sName0] ?? _sName0);
    final _sCi    = (_sRow['circuitIndex'] is num)
        ? (_sRow['circuitIndex'] as num).toInt()
        : int.tryParse(_sRow['circuitIndex']?.toString() ?? '') ?? 0;
    final _synthKey = '${_sExId.toLowerCase().trim()}|$_sCi|$setIdx';
    final _synthHit = _synthHintCache[_synthKey];
    if (_synthHit != null) return _synthHit;

    final name = (_selectedExercisesWithCircuits[exIdx]['name'] as String?)
        ?.trim() ?? '';
    final isBw = PeriodizationModelUtils.isBodyweightExercise(name: name);
    final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';

    final group = await _resolveGroupForExercise(name);
    final tolKg = (group == 'D') ? 0.3 : 0.7;

    final targetE1RM = await _targetE1RMForSet(exIdx, setIdx);

    // RIR for current set (typed if present else hint)
    final rirCurrent = _typedOrHintRIR(exIdx: exIdx, setIdx: setIdx);

    // Choose mid reps: favor prev reps - 1 (typed else hint), else best to target
    // --- NEW CENTER: solve reps that hit target at a stable anchor weight ---
    final prevReps = _typedOrHintReps(exIdx: exIdx, setIdx: setIdx - 1);
    final prevWAbs = _typedOrHintWeightAbs(exIdx: exIdx, setIdx: setIdx - 1);
    final prevRir = _typedOrHintRIR(exIdx: exIdx, setIdx: setIdx - 1);

// if previous RIR was > 2 (i.e. drop likely gated to ~0), anchor on previous ABS weight
// otherwise we’ll still solve a mid weight below, but the anchor gives a better center
    final double anchorAbs = prevWAbs;

// reps that would keep E1RM at targetE1RM using the anchorAbs at current set RIR
    final double repsNeeded = PeriodizationModelUtils.reverseCalculateReps(
      targetE1RM: targetE1RM,
      weight: anchorAbs,
      baseWeight: anchorAbs,
      // guard path: no min clamp here
      rir: rirCurrent,
      minReps: null,
    );

// center on the math, not on (prevReps - 1)
    int repsMid = repsNeeded.clamp(1.0, 45.0).round();


    // Compute unrounded weight that hits target at repsMid
    double weightMidAbs = PeriodizationModelUtils.reverseCalculateWeight(
      targetE1RM: targetE1RM,
      reps: repsMid,
      rir: rirCurrent,
    );

    // Round to nearest increment (ties → down). We’ll do manual tie handling:
    double roundedMid = PeriodizationModelUtils.roundToNearestValidIncrement(
      targetWeight: weightMidAbs,
      exerciseName: name,
    );
    // Tie-down handling: if two are equally close, prefer the lower one.
    // The current PMU rounding picks nearest, but not guaranteed tie-down;
    // we’ll enforce by checking neighbor below:
    if ((roundedMid - weightMidAbs).abs() >
        (weightMidAbs - (roundedMid - 0.0001)).abs()) {
      roundedMid = (roundedMid > 0.0001) ? (roundedMid - 0.0001) : roundedMid;
    }

    // Weight window: ±7.5% around mid (absolute math), pick valid increments in that band
    final double bandLo = weightMidAbs * 0.925;
    final double bandHi = weightMidAbs * 1.075;

    final incOptions = PeriodizationModelUtils.getIncrementsForExercise(name);
    final weightCandidatesAbs = incOptions.where((w) =>
    w >= bandLo && w <= bandHi).toList()
      ..sort();

    // If none except one, keep single; ensure mid is included
    if (!weightCandidatesAbs.contains(roundedMid)) {
      weightCandidatesAbs.add(roundedMid);
      weightCandidatesAbs.sort();
    }
    // Convert to display if BW
    List<double> weightCandidatesDisplay = weightCandidatesAbs.map((absW) {
      if (!isBw) return absW;
      return PeriodizationModelUtils.toDisplayAddedWeight(
        uid: uid,
        absoluteKg: absW,
        exerciseName: name,
        asOfDate: _selectedDate,
      );
    }).toList();

    // --- CAP: never exceed previous set's effective display weight
    double? prevTypedDisplay;
    final prevTxt = _weightControllers[exIdx][setIdx - 1].text.trim();
    if (prevTxt.isNotEmpty) {
      final v = double.tryParse(prevTxt);
      if (v != null && v > 0) prevTypedDisplay = v;
    }

    double? prevHintMaxDisplay;
// Only synthesize previous hints if previous is ≥ Set 2 (0-based: setIdx-1 >= 1)
    if (setIdx - 1 >= 1) {
      final prevHint = await _synthesizeHintsForSet(exIdx, setIdx - 1);
      if (prevHint.weightRangeDisplay.isNotEmpty) {
        prevHintMaxDisplay = prevHint.weightRangeDisplay.last;
      }
    }

// Always have a fallback
    final prevSuggestedDisplay = suggestedWeightForSet(exIdx, setIdx - 1);

// Cap = MIN of all available candidates
    final capCandidates = <double>[
      if (prevTypedDisplay != null) prevTypedDisplay!,
      if (prevHintMaxDisplay != null) prevHintMaxDisplay!,
      prevSuggestedDisplay,
    ];
    final prevDisplayCap = capCandidates.reduce((a, b) => a < b ? a : b);


// Apply cap to candidates
    weightCandidatesDisplay = weightCandidatesDisplay
        .where((wd) => wd <= prevDisplayCap + 1e-9)
        .toList()
      ..sort();

// If everything got filtered out, keep nearest valid ≤ cap; else clamp to cap
    if (weightCandidatesDisplay.isEmpty) {
      final allInBandDisplay = PeriodizationModelUtils
          .getIncrementsForExercise(name)
          .where((wAbs) => wAbs >= bandLo && wAbs <= bandHi)
          .map((wAbs) =>
      isBw
          ? PeriodizationModelUtils.toDisplayAddedWeight(
          uid: uid,
          absoluteKg: wAbs,
          exerciseName: name,
          asOfDate: _selectedDate)
          : wAbs)
          .toList()
        ..sort();

      double pick = prevDisplayCap;
      for (final wd in allInBandDisplay.reversed) {
        if (wd <= prevDisplayCap + 1e-9) {
          pick = wd;
          break;
        }
      }
      weightCandidatesDisplay = [pick];
    }


    // Reps range: mid ±1 within [1, …], may shrink later if tolerance requires
    final List<int> repsRange = {
      (repsMid - 1).clamp(1, 45),
      repsMid,
      (repsMid + 1).clamp(1, 45),
    }.toList()
      ..sort();

    // Tolerance filter: prefer adjusting reps before weight if needed
    List<int> filteredReps = [];
    List<double> filteredWeightsDisplay = [];

    for (final r in repsRange) {
      // Keep weight options as-is; we’ll collect those that can meet tolerance with this reps
      bool anyMet = false;
      for (final wd in weightCandidatesDisplay) {
        // Convert display to absolute for calc if BW
        final wAbs = isBw
            ? PeriodizationModelUtils.toAbsoluteWeight(
            uid: uid,
            displayAddedKg: wd,
            exerciseName: name,
            asOfDate: _selectedDate)
            : wd;

        final e = PeriodizationModelUtils.calculateE1RM(
            wAbs, r.toDouble(), rirCurrent);
        if ((e - targetE1RM).abs() <= tolKg + 1e-6) {
          anyMet = true;
        }
      }
      if (anyMet) filteredReps.add(r);
    }

    if (filteredReps.isEmpty) {
      // If increments too coarse, accept original reps range and keep mid weight only
      filteredReps.addAll(repsRange);
      weightCandidatesDisplay = [
        if (weightCandidatesDisplay.isNotEmpty) roundedMid == 0
            ? weightCandidatesDisplay.first
            : (isBw
            ? PeriodizationModelUtils.toDisplayAddedWeight(uid: uid,
            absoluteKg: roundedMid,
            exerciseName: name,
            asOfDate: _selectedDate)
            : roundedMid)
      ];
    }

    // Build weight list again but include only those that can meet tolerance with at least one allowed reps
    filteredWeightsDisplay = [];
    for (final wd in weightCandidatesDisplay) {
      bool ok = false;
      for (final r in filteredReps) {
        final wAbs = isBw
            ? PeriodizationModelUtils.toAbsoluteWeight(
            uid: uid,
            displayAddedKg: wd,
            exerciseName: name,
            asOfDate: _selectedDate)
            : wd;
        final e = PeriodizationModelUtils.calculateE1RM(
            wAbs, r.toDouble(), rirCurrent);
        if ((e - targetE1RM).abs() <= tolKg + 1e-6) {
          ok = true;
          break;
        }
      }
      if (ok) filteredWeightsDisplay.add(wd);
    }
    filteredWeightsDisplay.sort();

    // Ensure at least one weight value
    if (filteredWeightsDisplay.isEmpty) {
      final wd = isBw
          ? PeriodizationModelUtils.toDisplayAddedWeight(
          uid: uid,
          absoluteKg: roundedMid,
          exerciseName: name,
          asOfDate: _selectedDate)
          : roundedMid;
      filteredWeightsDisplay = [wd];
    }
    // Collapse degenerate ranges (e.g., 32.50–32.50) to a single value
    // Collapse degenerate ranges (e.g., 32.50–32.50) to a single value
    if (filteredWeightsDisplay.length >= 2) {
      final first = filteredWeightsDisplay.first;
      final last = filteredWeightsDisplay.last;
      if ((last - first).abs() <= 1e-6) {
        filteredWeightsDisplay = [first];
      }
    }

    // Choose mid scenario from filtered sets:
    // Prefer repsMid if still present; else nearest to repsMid; weight choose nearest to weightMidAbs
    int repsMidFinal = filteredReps.contains(repsMid)
        ? repsMid
        : (filteredReps
      ..sort((a, b) => (a - repsMid).abs().compareTo((b - repsMid).abs())))
        .first;

    double weightMidDisplay;
    {
      // pick candidate closest (in absolute space) to weightMidAbs; ties → round down (choose lower display)
      double best = filteredWeightsDisplay.first;
      double bestDiff = double.infinity;
      for (final wd in filteredWeightsDisplay) {
        final wAbs = isBw
            ? PeriodizationModelUtils.toAbsoluteWeight(
            uid: uid,
            displayAddedKg: wd,
            exerciseName: name,
            asOfDate: _selectedDate)
            : wd;
        final diff = (wAbs - weightMidAbs).abs();
        if (diff < bestDiff - 1e-9) {
          best = wd;
          bestDiff = diff;
        }
        else if ((diff - bestDiff).abs() <= 1e-9 && wd < best) {
          best = wd;
        } // tie → down
      }
      weightMidDisplay = best;
    }

    // e1rmMid from mid scenario
    final weightMidAbsForE = isBw
        ? PeriodizationModelUtils.toAbsoluteWeight(
        uid: uid,
        displayAddedKg: weightMidDisplay,
        exerciseName: name,
        asOfDate: _selectedDate)
        : weightMidDisplay;
    final e1rmMid = PeriodizationModelUtils.calculateE1RM(
      weightMidAbsForE, repsMidFinal.toDouble(), rirCurrent,
    );

    // --- FINAL CAP ENFORCEMENT (never exceed previous set cap) ---
    final double cap = prevDisplayCap; // use the cap you computed earlier


// 1) Clamp range to ≤ cap
    filteredWeightsDisplay = filteredWeightsDisplay
        .where((wd) => wd <= cap + 1e-9)
        .toList()
      ..sort();

// 2) Ensure at least one value remains
    if (filteredWeightsDisplay.isEmpty) {
      filteredWeightsDisplay = [cap];
    }

    // 2b) Collapse degenerate range *after* cap as well
    if (filteredWeightsDisplay.length >= 2) {
      final first = filteredWeightsDisplay.first;
      final last = filteredWeightsDisplay.last;
      if ((last - first).abs() <= 1e-6) {
        filteredWeightsDisplay = [first];
      }
    }

// 3) Clamp mid pick to the largest value ≤ cap (list is sorted ascending)
    double weightMidDisplayCapped = filteredWeightsDisplay.first;
    for (final wd in filteredWeightsDisplay) {
      if (wd <= cap + 1e-9) weightMidDisplayCapped = wd;
    }

// 4) Recompute mid E1RM from the *final* mid pick
    final weightMidAbsForE_final = isBw
        ? PeriodizationModelUtils.toAbsoluteWeight(
      uid: uid,
      displayAddedKg: weightMidDisplayCapped,
      exerciseName: name,
      asOfDate: _selectedDate,
    )
        : weightMidDisplayCapped;

    final e1rmMidFinal = PeriodizationModelUtils.calculateE1RM(
      weightMidAbsForE_final,
      repsMidFinal.toDouble(),
      rirCurrent,
    );




// 5) Return capped values
    final _synthResult = (
    weightRangeDisplay: filteredWeightsDisplay,
    repsRange: filteredReps,
    weightMidDisplay: weightMidDisplayCapped,
    repsMid: repsMidFinal,
    e1rmMid: e1rmMidFinal,
    );
    _synthHintCache[_synthKey] = _synthResult;
    return _synthResult;
  }

  // Formatters for hint text (range or single)
  Future<String> _weightHintText(int exIdx, int setIdx) async {
    // Claude_bullet override: return cached hint string synchronously
    if (_claudeBulletActiveForThisDay) {
      final ik = _rowKeyBy(exIdx);
      final ov = _claudeBulletWeightHintOverrides[ik]?[setIdx];
      if (ov != null) return ov;
    }
    // current field texts
    final weightText = _weightControllers[exIdx][setIdx].text.trim();
    final repsText = _repsControllers[exIdx][setIdx].text.trim();

    // if BOTH typed → no hint
    if (weightText.isNotEmpty && repsText.isNotEmpty) return '';

    // context
    final name = (_selectedExercisesWithCircuits[exIdx]['name'] as String?)
        ?.trim() ?? '';
    final isBw = PeriodizationModelUtils.isBodyweightExercise(name: name);
    final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    final rir = _typedOrHintRIR(
        exIdx: exIdx, setIdx: setIdx); // current set RIR

    // If REPS is typed (and weight empty) → collapse WEIGHT to a single target
    if (repsText.isNotEmpty && weightText.isEmpty) {
      final repsI = int.tryParse(repsText);
      if (repsI != null && repsI > 0) {
        final target = await _targetE1RMForSet(exIdx, setIdx);
        final wAbs = PeriodizationModelUtils.reverseCalculateWeight(
          targetE1RM: target,
          reps: repsI,
          rir: rir,
        );

        if (isBw) {
          // round in display (added) domain for BW
          final displayGuess = PeriodizationModelUtils.toDisplayAddedWeight(
            uid: uid,
            absoluteKg: wAbs,
            exerciseName: name,
            asOfDate: _selectedDate,
          );
          final roundedDisplay = PeriodizationModelUtils
              .roundToNearestValidIncrement(
            targetWeight: displayGuess,
            exerciseName: name,
          );
          return formatWeight(roundedDisplay);
        } else {
          // round in absolute domain
          final roundedAbs = PeriodizationModelUtils
              .roundToNearestValidIncrement(
            targetWeight: wAbs,
            exerciseName: name,
          );
          return formatWeight(roundedAbs);
        }
      }
    }

    // If WEIGHT is typed (and reps empty) → we let the reps hint collapse, not the weight hint
    if (weightText.isNotEmpty && repsText.isEmpty) {
      return ''; // weight already chosen by user → no weight hint
    }

    // Neither typed → show range from synthesis
    final h = await _synthesizeHintsForSet(exIdx, setIdx);
    if (h.weightRangeDisplay.isEmpty) return '';
    if (h.weightRangeDisplay.length == 1)
      return formatWeight(h.weightRangeDisplay.first);

    final first = formatWeight(h.weightRangeDisplay.first);
    final last = formatWeight(h.weightRangeDisplay.last);
    return (first == last) ? first : '$first–$last';
  }

  Future<String> _repsHintText(int exIdx, int setIdx) async {
    // Claude_bullet override: return cached hint string synchronously
    if (_claudeBulletActiveForThisDay) {
      final ik = _rowKeyBy(exIdx);
      final ov = _claudeBulletRepsHintOverrides[ik]?[setIdx];
      if (ov != null) return ov;
    }
    // current field texts
    final weightText = _weightControllers[exIdx][setIdx].text.trim();
    final repsText = _repsControllers[exIdx][setIdx].text.trim();

    // if BOTH typed → no hint
    if (weightText.isNotEmpty && repsText.isNotEmpty) return '';

    // context
    final name = (_selectedExercisesWithCircuits[exIdx]['name'] as String?)
        ?.trim() ?? '';
    final isBw = PeriodizationModelUtils.isBodyweightExercise(name: name);
    final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    final rir = _typedOrHintRIR(
        exIdx: exIdx, setIdx: setIdx); // current set RIR

    // If WEIGHT is typed (and reps empty) → compute allowed reps via the same candidate+tolerance logic
    if (weightText.isNotEmpty && repsText.isEmpty) {
      final wDisp = double.tryParse(weightText);
      if (wDisp != null && wDisp > 0) {
        final target = await _targetE1RMForSet(exIdx, setIdx);
        final wAbs = isBw
            ? PeriodizationModelUtils.toAbsoluteWeight(
            uid: uid,
            displayAddedKg: wDisp,
            exerciseName: name,
            asOfDate: _selectedDate)
            : wDisp;

        // same tolerance you use elsewhere
        final group = await _resolveGroupForExercise(name);
        final tolKg = (group == 'D') ? 0.3 : 0.7;

        // center candidates around the reps required at the *typed weight* to keep target E1RM stable
        final prevWAbs = _typedOrHintWeightAbs(
            exIdx: exIdx, setIdx: setIdx - 1);
        final rirCurrent = _typedOrHintRIR(exIdx: exIdx, setIdx: setIdx);

// Solve reps needed at the user's typed weight (not at prevWAbs)
        final repsNeeded = PeriodizationModelUtils.reverseCalculateReps(
          targetE1RM: target,
          weight: wAbs,
          baseWeight: wAbs,
          rir: rirCurrent,
          minReps: null,
        ).clamp(1.0, 45.0);

        final int center = repsNeeded.round().clamp(1, 45);

// Expand candidates beyond ±1 so reps can move outside the original hint range when weight is off-plan
        final candidates = <int>{};
        for (int r = (center - 6); r <= (center + 6); r++) {
          candidates.add(r.clamp(1, 45));
        }
        final candidatesList = candidates.toList()..sort();

        // collect all candidates within tolerance for the typed weight
        final withinTol = <int>[];
        double bestErr = double.infinity;
        int bestRep = candidatesList.first;

        for (final r in candidatesList) {
          final e = PeriodizationModelUtils.calculateE1RM(
              wAbs, r.toDouble(), rirCurrent);
          final err = (e - target).abs();

          if (err <= tolKg + 1e-6) withinTol.add(r);

          final take =
              (err < bestErr - 1e-9) ||
                  ((err - bestErr).abs() <= 1e-9 && r < bestRep);
          if (take) {
            bestErr = err;
            bestRep = r;
          }
        }

        // your requested behavior:
        // - if multiple reps satisfy tolerance at this weight → show a RANGE "a–b"
        // - if exactly one satisfies → show that single rep
        // - if none satisfy → show the best (closest) rep
        if (withinTol.length >= 2) {
          withinTol.sort();
          return '${withinTol.first}–${withinTol.last}';
        } else if (withinTol.length == 1) {
          return withinTol.first.toString();
        } else {
          return bestRep.toString();
        }
      }
    }


    // If REPS is typed (and weight empty) → we let the weight hint collapse, not the reps hint
    if (repsText.isNotEmpty && weightText.isEmpty) {
      return ''; // reps already chosen by user → no reps hint
    }

    // Neither typed → show range from synthesis
    final h = await _synthesizeHintsForSet(exIdx, setIdx);
    if (h.repsRange.isEmpty) return '';
    if (h.repsRange.length == 1) return h.repsRange.first.toString();
    final first = h.repsRange.first.toString();
    final last = h.repsRange.last.toString();
    return '$first–$last';
  }


// ...set 2 & 3 hint logic functions 14th Sep 2025 ends



  final Set<TextEditingController> _attachedDirty = {
  }; // guards against double-attach
// Mark the page "dirty" when a field changes
  void _markDirty() {
    if (!_pendingChanges && mounted) {
      _pendingChanges = true;
    }
    // 👇 NEW: drop Done flag if all weight+reps cleared for any exercise
    _reevaluateSavedFlagsFromControllers();
  }

  void _attachDirtyListeners() {
    void ensure(TextEditingController c) {
      if (!_attachedDirty.contains(c)) {
        c.addListener(_markDirty);
        _attachedDirty.add(c);
      }
    }

    for (int i = 0; i < _repsControllers.length; i++) {
      for (int j = 0; j < _repsControllers[i].length; j++) {
        ensure(_repsControllers[i][j]);
        ensure(_weightControllers[i][j]);
        ensure(_rirControllers[i][j]);
        ensure(_velocityControllers[i][j]);
        ensure(_notesControllers[i][j]);
      }
    }
  }


  bool _hasTypedWeightAndRepsInAnySet(int i) {
    if (i < 0 || i >= _weightControllers.length) return false;
    for (int j = 0; j < _weightControllers[i].length; j++) {
      final w = double.tryParse(_weightControllers[i][j].text.trim()) ?? 0.0;
      final r = int.tryParse(_repsControllers[i][j].text.trim()) ?? 0;
      if (w > 0 && r > 0) return true;
    }
    return false;
  }


  //...autosave bits finish

  //Missing Exercises bits...
// Missed cache for today
  List<_MissedItem> _missedItemsForToday = [];
  bool _hasMissedForToday = false;

// One-time shine per page open (per date)
  bool _didShineThisOpen = false;

// Shine animation
// Shine animation
  AnimationController? _catchupShineCtl;
  Animation<double>? _catchupShineAnim;



  //UI bits
  late ScrollController _horizontalScrollController;

  //Timing Bits
  final _wesInitTimer = Stopwatch()
    ..start();


  Future<void> loadPreviousWorkoutData() async {
    final sw = Stopwatch()
      ..start(); // ⏱️ start
    await PeriodizationModelUtils.fetchLastWorkoutTopSetRepsCacheFirst(
      uid: UserContext
          .of(context, listen: false)
          .currentUid,
    );

    setState(() {
      _isLoadingData = false; // ✅ Data has been fetched, UI can update
    });
    sw.stop();
    print('⏱️ [WES] loadPreviousWorkoutData took ${sw.elapsedMilliseconds}ms');
  }



  static const TextStyle _headerStyle = TextStyle(
    fontSize: 10.0,
    color: Colors.white70,
    fontWeight: FontWeight.bold,
  );


  Future<void> loadPlannedExercisesFromFirestore() async {
    final totalSw = Stopwatch()
      ..start();
    try {
      // ✅ Same uid source you use elsewhere (impersonation-safe, no Provider listen)
      final uid = userId;
      final blockId = _selectedBlockId; // ✅ match _loadPlannedExerciseDetails()

      if (uid.isEmpty || blockId == null || blockId.isEmpty) {
        print(
            '⚠️ [WES] loadPlannedExercisesFromFirestore missing uid/blockId (uid=$uid, blockId=$blockId)');
        return;
      }

      final ref = FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks')
          .doc(blockId);

      print(
          '[WES] loadPlannedExercisesFromFirestore → planned_blocks/$uid/blocks/$blockId');

      List<String> parseDoc(DocumentSnapshot<Map<String, dynamic>> snap) {
        if (!snap.exists) return const <String>[];
        final data = snap.data() ?? const <String, dynamic>{};
        final raw = data['plannedExercises'];
        if (raw is List) {
          return raw
              .map((e) => (e?.toString() ?? '').trim())
              .where((s) => s.isNotEmpty)
              .toList(growable: false);
        }
        return const <String>[];
      }

      bool listEq<T>(List<T>? a, List<T>? b) {
        if (identical(a, b)) return true;
        if (a == null || b == null || a.length != b.length) return false;
        for (var i = 0; i < a.length; i++) {
          if (a[i] != b[i]) return false;
        }
        return true;
      }

      // 1) Try CACHE first
      final cacheSw = Stopwatch()
        ..start();
      DocumentSnapshot<Map<String, dynamic>>? cacheSnap;
      try {
        cacheSnap = await ref.get(const GetOptions(source: Source.cache));
      } catch (_) {}
      cacheSw.stop();

      if (cacheSnap != null && cacheSnap.exists) {
        final cached = parseDoc(cacheSnap);
        if (mounted && !listEq(plannedExercises, cached)) {
          setState(() => plannedExercises = cached);
        }


        // 2) Background reconcile
        unawaited(() async {
          try {
            final srvSw = Stopwatch()
              ..start();
            final srvSnap = await ref.get(); // server
            srvSw.stop();
            final fresh = parseDoc(srvSnap);
            if (mounted && !listEq(plannedExercises, fresh)) {
              setState(() => plannedExercises = fresh);
              print('🔁 [WES] reconciled from server (items=${fresh
                  .length}, ${srvSw.elapsedMilliseconds}ms)');
            }
          } catch (e) {
            print('ℹ️ [WES] plannedExercises reconcile failed: $e');
          }
        }());
      } else {
        // 3) Guaranteed SERVER fallback (awaited) for cold start
        final srvSw = Stopwatch()
          ..start();
        final srvSnap = await ref.get();
        srvSw.stop();

        if (!srvSnap.exists) {
          print(
              '⚠️ [WES] Block doc missing at planned_blocks/$uid/blocks/$blockId');
          if (mounted &&
              (plannedExercises == null || plannedExercises.isNotEmpty)) {
            setState(() => plannedExercises = const <String>[]);
          }
        } else {
          final fresh = parseDoc(srvSnap);
          if (mounted && !listEq(plannedExercises, fresh)) {
            setState(() => plannedExercises = fresh);
          }
          print('🌐 [WES] plannedExercises (server) items=${fresh
              .length} in ${srvSw.elapsedMilliseconds}ms');
        }
      }
    } catch (e, st) {
      print('❌ [WES] loadPlannedExercisesFromFirestore error: $e');
      print(st);
    } finally {
      totalSw.stop();
      print('⏱️ [WES] loadPlannedExercisesFromFirestore total took ${totalSw
          .elapsedMilliseconds}ms');
    }
  }

  // ✅ Custom Hybrid E1RM Formula: Brzycki for ≤6 reps, Epley for >6 reps
  static double calculateE1RM(double? weight, double? reps, double? rir) {
    double w = weight ?? 0.0;
    double r = reps ?? 0.0;
    double rValue = rir ?? 0.0; // ✅ default RIR = 0

    double totalReps = r + rValue;
    totalReps = double.parse(totalReps.toStringAsFixed(4));

    if (totalReps <= 25.0) {
      // Brzycki
      return w * (36 / (37 - totalReps));
    } else {
      // Epley
      return w * (1 + 0.0333 * totalReps);
    }
  }


  /// ✅ Helper Function to Parse Any Firestore Value to a Double
  double _parseToDouble(dynamic value) {
    if (value is double) return value; // ✅ Already a double, return it
    if (value is int) return value.toDouble(); // ✅ Convert int to double
    if (value is String)
      return double.tryParse(value) ?? 0; // ✅ Convert String to double
    return 0; // ✅ Default case
  }

  //Determine available rep targets for this workout:
  Map<String, List<double>> exercisePreviousE1RMs =
  {}; // ✅ E1RM history per exercise

  Map<String, List<int>> exercisePreviousTopSetReps =
  {}; // ✅ Tracks reps per exercise

  double getAverageE1RM(String exerciseName, {
    DateTime? now,
  }) {
    // small local helper to parse num-or-string safely
    num? _asNum(dynamic v) {
      if (v is num) return v;
      if (v is String) return double.tryParse(v);
      return null;
    }

    final name = exerciseName.trim();
    final String exerciseId =
        PeriodizationModelUtils.nameToId[name] ?? name;

    // Fallback if dates missing
    if (blockStartDate == null || _selectedDate == null) {
      final info = PeriodizationModelUtils.computeBaseE1RMFromHistory(
        exerciseName: name,
        repTarget: 5,
        plannedRIR: 1.0,
        topSetHistory: null,
        maxWeightByReps: null,
        now: now ?? DateTime.now(),
      );
      final double? base = info['baseE1RM'] as double?;
      return (base != null && base.isFinite) ? base : 0.0;
    }

    // Same week/session logic as SP/WES
    final base = DateTime(
        blockStartDate!.year, blockStartDate!.month, blockStartDate!.day);
    final sel = DateTime(
        _selectedDate.year, _selectedDate.month, _selectedDate.day);
    final weekIndex = ((sel
        .difference(base)
        .inDays) ~/ 7).clamp(0, 11);

    final sessionIndex = PeriodizationModelUtils
        .getInstanceCountForExerciseInWeek(
      exerciseName: name,
      savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
      blockStartDate: blockStartDate!,
      weekIndex: weekIndex,
      selectedDate: _selectedDate,
    );

    final rirPlan = PeriodizationModelUtils
        .plannedExerciseDetails[exerciseId]?['rirPlan'];
    final weekKey = 'week${weekIndex + 1}';
    final sessionKey = 'session${sessionIndex + 1}';
    final Map<String, dynamic>? set1 =
    (rirPlan?[weekKey]?[sessionKey]?['set1'] as Map?)?.cast<String, dynamic>();

    // ✅ robust to num or string
    final int repTarget =
        (_asNum(set1?['reps'])?.toInt()) ?? 5;

    final double plannedRIR =
        (_asNum(set1?['rir'])?.toDouble()) ?? 1.0;

    final info = PeriodizationModelUtils.computeBaseE1RMFromHistory(
      exerciseName: name,
      repTarget: repTarget,
      plannedRIR: plannedRIR,
      topSetHistory: null,
      maxWeightByReps: null,
      now: now ?? DateTime.now(),
    );

    final double? baseE1RM = info['baseE1RM'] as double?;
    return (baseE1RM != null && baseE1RM.isFinite) ? baseE1RM : 0.0;
  }





// Missing exercises block begins...

  final Set<String> _missedDialogShownForDateKeys = {}; // "yyyy-MM-dd"

// Lowercase "yyyy-MM-dd"
  String _ymd(DateTime d) {
    final dd = DateTime(d.year, d.month, d.day);
    final m = dd.month.toString().padLeft(2, '0');
    final day = dd.day.toString().padLeft(2, '0');
    return '${dd.year}-$m-$day';
  }

  String _weekdayShortLabel(int dayIndex) {
    // 0=Mon … 6=Sun (matches your week layout)
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return names[(dayIndex.clamp(0, 6))];
  }

// Build a name->id map from exerciseSettings if possible.
// Falls back gracefully when no mapping exists.
  Map<String, String> _buildNameToIdLookup() {
    // You already populate `_exerciseSettings` keys = exerciseId.
    // We try common "name" fields inside each settings map.
    final out = <String, String>{};
    _exerciseSettings.forEach((exId, cfg) {
      final maybeNames = <String?>[
        cfg['displayName']?.toString(),
        cfg['name']?.toString(),
        cfg['exerciseName']?.toString(),
      ].where((s) => s != null && s!.trim().isNotEmpty).cast<String>().toList();

      for (final n in maybeNames) {
        out[n.trim().toLowerCase()] = exId;
      }
    });
    return out;
  }

// Create a composite planned key for dedupe (prefer ID when resolvable).
  String _plannedKey({String? id, required String name}) {
    final nk = name.trim().toLowerCase();
    if (id != null && id
        .trim()
        .isNotEmpty) return 'id#$id';
    return 'name#$nk';
  }

  // 🔎 Filter a candidate list of missed exercises against what's already on today's UI
  List<_MissedItem> _filterStillMissingNow(List<_MissedItem> items) {
    final nameToId = _buildNameToIdLookup();

    // Build today keys from current WES state (local, instant)
    final plannedTodayKeys = <String>{};
    for (final e in _selectedExercisesWithCircuits) {
      final n = (e['name'] ?? '').toString().trim();
      if (n.isEmpty) continue;
      final id = nameToId[n.toLowerCase()];
      plannedTodayKeys.add(_plannedKey(id: id, name: n));
    }

    // Keep only those not already present today
    return items.where((m) {
      final id = nameToId[m.name.toLowerCase()];
      final key = _plannedKey(id: id, name: m.name);
      return !plannedTodayKeys.contains(key);
    }).toList();
  }

  Future<void> _refreshMissedState() async {
    final items = await _computeMissedExercisesForWeek();
    final filtered = _filterStillMissingNow(items);
    setState(() {
      _missedItemsForToday =
          filtered; // make sure this field exists (List<_MissedItem>)
      _hasMissedForToday = filtered.isNotEmpty; // and this (bool)
    });
  }

  String _computeNowInputsHash() {
    final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    final bid = _selectedBlockId ?? _activeBlockId ?? '';
    final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate ?? DateTime.now());

    final wk = (blockStartDate != null && _selectedDate != null)
        ? PeriodizationModelUtils.getWeekIndexForDate(_selectedDate!, blockStartDate!)
        : 0;

    final planned = _selectedExercisesWithCircuits
        .map<Map<String,dynamic>>((e) => {
      'id': PeriodizationModelUtils.nameToId[e['name']] ?? e['id'] ?? e['name'],
      'circuitIndex': e['circuitIndex'] ?? 0,
    })
        .toList();

    final details  = PeriodizationModelUtils.plannedExerciseDetails;
    final settings = PeriodizationModelUtils.getExerciseSettings();

    final bw = PeriodizationModelUtils.bodyweightKgForDate(
      uid: uid,
      asOf: _selectedDate,
    );
    final lastW = wesMaxWorkoutDate(PeriodizationModelUtils.savedWorkoutsList);
    final lastT = wesMaxTopSetDate(PeriodizationModelUtils.topSetsByExercise);

    return WesHintInputsPayload(
      uid: uid,
      blockId: bid,
      dateYmd: ymd,
      weekIndex: wk,
      plannedExercises: planned,
      plannedExerciseDetails: details,
      exerciseSettings: settings,
      bodyweightAsOfDay: bw,
      lastWorkoutDate: lastW,
      lastTopSetDate: lastT,
    ).hash();
  }

  /// Force-recompute engine hints for the selected day, repainting this screen.
  /// Returns true if a newer/different snapshot was applied.
  // sparkle function
  Future<bool> _refreshHintsForSelectedDay({bool alsoWarmTomorrow = false}) async {
    try {
      // ——— 0) Resolve acting/selected user + date + block ———
      final String uid = UserContext.of(context, listen: false).currentUid; // ✅ selected athlete
      final String? blockId = _selectedBlockId ?? _activeBlockId;
      if (uid.isEmpty || blockId == null || blockId.isEmpty) {
        print('🟥 [WES Refresh] Missing uid/blockId (uid="$uid", blockId="$blockId")');
        return false;
      }

      // Normalize to LOCAL date-only (avoid TZ edges)
      final DateTime d0 = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
      final String ymd = DateFormat('yyyy-MM-dd').format(d0);

      print('✨ [WES Refresh] START → uid=$uid block=$blockId date=$ymd');

      // ——— helpers ———
      Map<String, Map<String, dynamic>> _parseHintsJson(String? jsonStr) {
        if (jsonStr == null || jsonStr.isEmpty || jsonStr == '{}') return {};
        try {
          final raw = Map<String, dynamic>.from(jsonDecode(jsonStr));
          return raw.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)));
        } catch (e) {
          print('⚠️ [WES Refresh] hintsJson parse failed: $e');
          return {};
        }
      }

      List<String> _summarizeHints(Map<String, Map<String, dynamic>> m, {int take = 6}) {
        final out = <String>[];
        int c = 0;
        for (final e in m.entries) {
          final name = (e.value['name'] ?? '').toString();
          final ci   = (e.value['circuitIndex'] ?? 0).toString();
          final w    = (e.value['s1_weight'] as num?)?.toDouble();
          final wa   = (e.value['s1_weight_added'] as num?)?.toDouble();
          final r    = (e.value['s1_reps'] as num?)?.toDouble();
          final rr   = (e.value['s1_rir'] as num?)?.toDouble();
          out.add('$name|$ci → w=${w ?? '—'} add=${wa ?? '—'} r=${r ?? '—'} rir=${rr ?? '—'}');
          if (++c >= take) break;
        }
        return out;
      }

      List<String> _diffHints(Map<String, Map<String, dynamic>> a, Map<String, Map<String, dynamic>> b) {
        final keys = {...a.keys, ...b.keys}.toList()..sort();
        final lines = <String>[];
        for (final k in keys) {
          final va = a[k] ?? const {};
          final vb = b[k] ?? const {};
          // compare key fields only
          double? wA = (va['s1_weight'] as num?)?.toDouble();
          double? wB = (vb['s1_weight'] as num?)?.toDouble();
          double? waA = (va['s1_weight_added'] as num?)?.toDouble();
          double? waB = (vb['s1_weight_added'] as num?)?.toDouble();
          double? rA = (va['s1_reps'] as num?)?.toDouble();
          double? rB = (vb['s1_reps'] as num?)?.toDouble();
          double? rirA = (va['s1_rir'] as num?)?.toDouble();
          double? rirB = (vb['s1_rir'] as num?)?.toDouble();
          if (wA != wB || waA != waB || rA != rB || rirA != rirB) {
            final name = (vb['name'] ?? va['name'] ?? '').toString();
            final ci   = (vb['circuitIndex'] ?? va['circuitIndex'] ?? 0).toString();
            lines.add('$name|$ci: '
                'w ${wA ?? '—'}→${wB ?? '—'}, '
                'add ${waA ?? '—'}→${waB ?? '—'}, '
                'r ${rA ?? '—'}→${rB ?? '—'}, '
                'rir ${rirA ?? '—'}→${rirB ?? '—'}');
          }
        }
        return lines;
      }

      // ——— 1) Read BEFORE snapshot for change detection ———
      final before = await BlockPlanCache.getInitSnapshot(
        uid: uid, blockId: blockId, dateYmd: ymd,
      );
      final String beforeHash   = before?.hintsInputsHash ?? '';
      final String beforeHintsS = before?.hintsJson ?? '{}';
      final DateTime? beforeCachedAt = before?.cachedAt;
      final beforeHints = _parseHintsJson(beforeHintsS);

      print('🔹 [WES Refresh] BEFORE hash=${beforeHash.isEmpty ? '—' : beforeHash} '
          'rows=${beforeHints.length}');
      if (beforeHints.isNotEmpty) {
        final p = _summarizeHints(beforeHints);
        for (final line in p) print('   • $line');
      }

      // ——— 2) Ensure BB2 plan edits are merged into WES draft (best effort) ———
      try {
        await _mergeNewBB2ExercisesIntoDraft();
      } catch (e) {
        print('⚠️ [WES Refresh] _mergeNewBB2ExercisesIntoDraft failed (continuing): $e');
      }

      // ——— 2b) Server-first: prime Isar with fresh planned exercises ———
      // Without this, _loadPlannedDay inside doWarmWES reuses the Isar cache
      // (valid by date but potentially stale in content), so hints reflect old
      // planned reps/RIR/weight rather than what the coach just saved in BB2.
      if (blockStartDate != null) {
        final int daysSinceStart = d0.difference(blockStartDate!).inDays;
        if (daysSinceStart >= 0) {
          final int weekIndex = daysSinceStart ~/ 7;
          final int dayIndex  = daysSinceStart % 7;
          try {
            final serverSnap = await FirebaseFirestore.instance
                .collection('planned_blocks').doc(uid)
                .collection('blocks').doc(blockId)
                .collection('weeks').doc('week_$weekIndex')
                .collection('days').doc('day_$dayIndex')
                .get(const GetOptions(source: Source.server));

            if (serverSnap.exists) {
              final raw = serverSnap.data()?['exercises'];
              final serverExercises = (raw is List)
                  ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
                  : <Map<String, dynamic>>[];

              print('🌐 [WES Refresh] SERVER planned day fetched '
                  '(ymd=$ymd blockId=$blockId w=$weekIndex d=$dayIndex): '
                  '${serverExercises.length} exercise(s)');
              for (final ex in serverExercises.take(6)) {
                print('   ⬡ ${ex['name'] ?? '?'} → '
                    'reps=${ex['reps'] ?? '—'} '
                    'rir=${ex['rir'] ?? '—'} '
                    'weight=${ex['weight'] ?? '—'}');
              }

              // Overwrite Isar cache so doWarmWES._loadPlannedDay reads server truth.
              await BlockPlanCache.putDay(
                uid: uid,
                blockId: blockId,
                weekIndex: weekIndex,
                dayIndex: dayIndex,
                exercises: serverExercises,
                updatedAt: DateTime.now(),
              );
              print('✅ [WES Refresh] Isar primed with server planned exercises '
                  '(w=$weekIndex d=$dayIndex count=${serverExercises.length})');
            } else {
              print('ℹ️ [WES Refresh] Server planned day doc absent '
                  '(w=$weekIndex d=$dayIndex) — doWarmWES will use defaults');
            }
          } catch (e) {
            // Non-fatal: doWarmWES will still run with whatever Isar has.
            print('⚠️ [WES Refresh] Server planned day prefetch failed (non-fatal): $e');
          }
        }
      }

      // ——— 3) Force recompute now (skip cooldown): await doWarmWES ———
      print('✨ [WES Refresh] Running WarmupService.doWarmWES()…');
      await WarmupService.instance.doWarmWES(
        uid,
        activeBlockId: blockId,
        selectedDate: d0,
        warmAthlete: true,
        warmExercises: true,
      );

      // Optionally warm tomorrow (non-blocking)
      if (alsoWarmTomorrow) {
        final d1 = d0.add(const Duration(days: 1));
        WarmupService.instance.warmWES(uid, activeBlockId: blockId, selectedDate: d1);
      }

      // ——— 4) Retry-read until we observe newer/changed snapshot ———
      const int maxAttempts = 6;
      const Duration pause = Duration(milliseconds: 80);
      WESInitSnapshot? after;
      for (int i = 1; i <= maxAttempts; i++) {
        after = await BlockPlanCache.getInitSnapshot(uid: uid, blockId: blockId, dateYmd: ymd);
        final bool newer =
            after != null && (beforeCachedAt == null || after.cachedAt.isAfter(beforeCachedAt));
        final bool contentChanged =
            after != null &&
                (((after.hintsInputsHash ?? '') != beforeHash) || (after.hintsJson != beforeHintsS));

        print('🔎 [WES Refresh] attempt $i/$maxAttempts '
            'newer=$newer changed=$contentChanged '
            'hash=${after?.hintsInputsHash ?? '—'}');

        if (newer || contentChanged) break;
        await Future.delayed(pause);
      }
      if (after == null) {
        print('🟥 [WES Refresh] No snapshot found after warm; aborting');
        return false;
      }

      final afterHints = _parseHintsJson(after.hintsJson);
      print('🔹 [WES Refresh] AFTER  hash=${after.hintsInputsHash ?? '—'} '
          'rows=${afterHints.length}');
      if (afterHints.isNotEmpty) {
        final p = _summarizeHints(afterHints);
        for (final line in p) print('   • $line');
      }

      // ——— 5) Print a concise DIFF so you can see exactly what changed ———
      final diffs = _diffHints(beforeHints, afterHints);
      if (diffs.isEmpty) {
        print('ℹ️  [WES Refresh] Hints unchanged (but repaint will still ensure UI is in sync).');
      } else {
        print('✅ [WES Refresh] Hints changed on ${diffs.length} row(s):');
        for (final d in diffs) print('   • $d');
      }

      // ——— 6) Full repaint from snapshot (rock-solid) ———
      print('🎨 [WES Refresh] Repainting from snapshot…');
      _bootPaintDone = false;          // allow fast-paint to run again
      await _paintFromSnapshotIfAny(); // this will call setState()
      print('✅ [WES Refresh] Full repaint applied.');


      // ——— 7) Post-paint confirmation: echo the first few hints we believe are live ———
      // (We can’t read hintText from controllers, so we re-echo what was just painted.)
      if (afterHints.isNotEmpty) {
        final applied = _summarizeHints(afterHints);
        for (final line in applied) print('🟢 [WES Refresh][Applied] $line');
      }

      return true;
    } catch (e, st) {
      print('🟥 [WES Refresh] Failed: $e');
      return false;
    }
  }

  // ──────────────────────────────────────────────────────────────
// ALIAS used by self-heal to refresh today's hints only.
// This simply forwards to your existing _refreshHintsForSelectedDay.
// ──────────────────────────────────────────────────────────────
  Future<void> _refreshHintsForCurrentDate({
    bool forceCooldownSkip = false, // ignored here if your refresh already bypasses cooldown internally
    bool silent = true,             // only used for snackbar control below
    bool onlyToday = true,          // map to alsoWarmTomorrow=false
  }) async {
    final ok = await _refreshHintsForSelectedDay(
      alsoWarmTomorrow: !onlyToday, // we want today only → false
    );

    // Optional: only toast when updated and NOT silent
    if (ok && !silent && mounted) {
      final uid = _cachedUid ?? UserContext.of(context, listen: false).currentUid;
      if (uid != null && uid.isNotEmpty) {
        final (sex, dob) = await DemographicsCache.load(uid);
        final msg = _hintsReadySnackMessage(sexRaw: sex, dobRaw: dob);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Suggested weights and reps are ready')),
        );
      }
    }

  }




// ──────────────────────────────────────────────────────────────
// Verify the local snapshot for TODAY and self-heal if it's stale
// Conditions to refresh:
//  - no snapshot
//  - snapshot.hintsReady == false
//  - snapshot.hintsInputsHash != _computeNowInputsHash()
// Cooldown: 12s per (uid|block|date)
// Only shows a snackbar if hints actually changed.
// ──────────────────────────────────────────────────────────────
  Future<void> _verifyAndSelfHealIfStale() async {
    try {
      final int _healEpoch = _epoch;
      final String _healDayKey = _currentDayKey;

      final uid = UserContext.of(context, listen: false).currentUid;
      final bid = _selectedBlockId ?? _activeBlockId;
      final date = _selectedDate ?? DateTime.now();
      if (uid == null || uid.isEmpty || bid == null) {
        debugPrint('🟨 [SelfHeal] Missing uid or block; skipping.');
        return;
      }

      final ymd = DateFormat('yyyy-MM-dd').format(DateTime(date.year, date.month, date.day));
      final key = '$uid|$bid|$ymd';

      // Cooldown
      final last = _selfHealLastRun[key];
      if (last != null && DateTime.now().difference(last) < _selfHealCooldown) {
        debugPrint('🟨 [SelfHeal] Cooldown active; skipping.');
        return;
      }

      // Read current snapshot
      final snap = await BlockPlanCache.getInitSnapshot(uid: uid, blockId: bid, dateYmd: ymd);
      final nowHash = _computeNowInputsHash();

      final bool needsRefresh = (snap == null) ||
          (snap.hintsReady != true) ||
          ((snap.hintsInputsHash ?? '') != nowHash);

      debugPrint('🔎 [SelfHeal] hasSnap=${snap != null} ready=${snap?.hintsReady} '
          'hashMatch=${(snap?.hintsInputsHash ?? '') == nowHash} → needs=$needsRefresh');

      if (!needsRefresh) {
        _selfHealLastRun[key] = DateTime.now();
        return; // nothing to do
      }

      final beforeHints = snap?.hintsJson ?? '';

      if (_isStale(_healEpoch) || _healDayKey != _currentDayKey) {
        debugPrint('⛔️ [SelfHeal] stale epoch; aborting');
        return;
      }

      // Reuse your sparkle routine for TODAY only
      debugPrint('⚙️ [SelfHeal] Running refresh (forced, silent) for $ymd…');
      await _refreshHintsForCurrentDate(
        forceCooldownSkip: true,   // skip warm cooldowns
        silent: true,              // no "starting" snack
        onlyToday: true,           // do not touch tomorrow
      );

      if (_isStale(_healEpoch) || _healDayKey != _currentDayKey) {
        debugPrint('⛔️ [SelfHeal] stale epoch post-refresh; skipping UI apply');
        return;
      }

      // Re-read snapshot and decide what changed
      final snap2 = await BlockPlanCache.getInitSnapshot(uid: uid, blockId: bid, dateYmd: ymd);
      final afterHints = snap2?.hintsJson ?? '';

      final bool hintsChanged = (afterHints.isNotEmpty && afterHints != beforeHints);

      if (hintsChanged) {
        // 🔧 Also fix set counts per row based on planned structure
        bool structureChanged = false;

        // Small helper to resize a single row in a 2D list while preserving existing values.
        void _resizeRow<T>(
            List<List<T>> matrix,
            int rowIndex,
            int desiredLen,
            T Function() create,
            ) {
          if (rowIndex >= matrix.length) return;
          final row = matrix[rowIndex];

          if (row.length > desiredLen) {
            row.removeRange(desiredLen, row.length);
            structureChanged = true;
          } else if (row.length < desiredLen) {
            while (row.length < desiredLen) {
              row.add(create());
            }
            structureChanged = true;
          }
        }

        for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
          final name = (_selectedExercisesWithCircuits[i]['name'] as String? ?? '').trim();
          if (name.isEmpty) continue;

          final exId = PeriodizationModelUtils.nameToId[name] ?? name;
          final desiredSetCount = _plannedSetCountFor(i);
          if (desiredSetCount <= 0) continue;

          // Guard: if we somehow don't have rows yet, skip instead of crashing
          if (i >= _workoutSets.length ||
              i >= _repsControllers.length ||
              i >= _weightControllers.length ||
              i >= _rirControllers.length ||
              i >= _velocityControllers.length ||
              i >= _notesControllers.length) {
            continue;
          }

          _resizeRow<SetDetails>(
            _workoutSets,
            i,
            desiredSetCount,
                () => SetDetails(),
          );
          _resizeRow<TextEditingController>(
            _repsControllers,
            i,
            desiredSetCount,
                () => TextEditingController(),
          );
          _resizeRow<TextEditingController>(
            _weightControllers,
            i,
            desiredSetCount,
                () => TextEditingController(),
          );
          _resizeRow<TextEditingController>(
            _rirControllers,
            i,
            desiredSetCount,
                () => TextEditingController(),
          );
          _resizeRow<TextEditingController>(
            _velocityControllers,
            i,
            desiredSetCount,
                () => TextEditingController(),
          );
          _resizeRow<TextEditingController>(
            _notesControllers,
            i,
            desiredSetCount,
                () => TextEditingController(),
          );
        }

        if (structureChanged && mounted) {
          setState(() {});
        }

        // Optional: tiny toast to let user know silently updated
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Hints updated'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        debugPrint('✅ [SelfHeal] Hints changed; UI + set counts updated.');
      } else {
        debugPrint('🟦 [SelfHeal] No diff after refresh (snapshot unchanged).');
      }


      _selfHealLastRun[key] = DateTime.now();
    } catch (e) {
      debugPrint('🟥 [SelfHeal] Failed: $e');
    }
  }

  int _sparklePlays = 0;
  void _playSparkles() {
    debugPrint('✨ [Sparkles] request (mounted=$mounted, showing=$_showSparkles)');
    if (!mounted) return;

    // 🧭 debug: count or confirm when sparkles run
    debugPrint('✨ [Sparkles] Triggered at ${DateTime.now()} (already showing=$_showSparkles)');

    // prevent overlap if already showing
    if (_showSparkles) return;

    setState(() => _showSparkles = true);

    // short burst duration — adjust freely (ms)
    _sparkleCtrl
      ..reset()
      ..duration = const Duration(milliseconds: 1000)
      ..forward();

    // auto-hide after the same duration
    Future.delayed(const Duration(milliseconds: 1000), () {
      if (mounted) {
        _sparkleCtrl.stop();
        setState(() => _showSparkles = false);
        debugPrint('✨ [Sparkles] Hidden at ${DateTime.now()}');
      }
    });
  }


  // --- Heavy work coalescer (merge + self-heal) ---
  void _scheduleHeavyWork({Duration delay = const Duration(milliseconds: 1000)}) {
    print('🕒 [WES] _scheduleHeavyWork() called (will run in ${delay.inMilliseconds}ms)… epoch=$_epoch dayKey=$_currentDayKey');
    _heavyWorkTimer?.cancel();

    // Capture the session keys at schedule time
    final int epochAtSchedule = _epoch;
    final String dayKeyAtSchedule = _currentDayKey;

    _heavyWorkTimer = Timer(delay, () async {
      // Abort if a new date/session started
      if (_isStale(epochAtSchedule)) return;
      if (_currentDayKey != dayKeyAtSchedule) return;

      // Re-compute allowMerge based on the *current* selected date,
      // then run the heavy steps guarded.
      try {
        final picked = _selectedDate;
        if (picked == null) return;

        bool allowMerge = true;
        try {
          final DateTime pickedOnly = DateTime(picked.year, picked.month, picked.day);
          final DateTime? blockStartOnly = (blockStartDate == null)
              ? null
              : DateTime(blockStartDate!.year, blockStartDate!.month, blockStartDate!.day);
          if (blockStartOnly != null) {
            final delta = pickedOnly.difference(blockStartOnly).inDays;
            final wk = delta ~/ 7;
            final diRaw = delta % 7;
            final di = diRaw < 0 ? diRaw + 7 : diRaw;

            final uid = _cachedUid ?? UserContext.of(context, listen: false).currentUid;
            final bid = _selectedBlockId ?? _activeBlockId;

            if (uid != null && bid != null) {
              final dayDoc = await FirebaseFirestore.instance
                  .collection('planned_blocks').doc(uid)
                  .collection('blocks').doc(bid)
                  .collection('weeks').doc('week_$wk')
                  .collection('days').doc('day_$di')
                  .get(const GetOptions(source: Source.server));

              String _d(dynamic v) {
                if (v == null) return '∅';
                if (v is Timestamp) { final d = v.toDate(); return '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}'; }
                if (v is DateTime)  { final d = DateTime(v.year, v.month, v.day); return DateFormat('yyyy-MM-dd').format(d); }
                if (v is String)    { return v.length >= 10 ? v.substring(0,10) : v; }
                return v.toString();
              }
              final fsDate = _d(dayDoc.data()?['date']);
              final pick   = DateFormat('yyyy-MM-dd').format(pickedOnly);
              allowMerge = (fsDate == pick);
              debugPrint('✅ [HeavyCoalesce MergeGate] allowMerge=$allowMerge (doc=$fsDate pick=$pick)');
            }
          }
        } catch (e) {
          debugPrint('⚠️ [HeavyCoalesce MergeGate] failed: $e (default allowMerge=true)');
          allowMerge = true;
        }

        // Abort again if stale before mutating UI
        if (_isStale(epochAtSchedule) || _currentDayKey != dayKeyAtSchedule) return;

        // MERGE (deferred)
        if (blockStartDate == null) {
          debugPrint('🚧 [HeavyCoalesce] No block meta → skipping merge.');
        } else if (allowMerge) {
          try {
            await _mergeNewBB2ExercisesIntoDraft();
          } catch (e) {
            debugPrint('⚠️ [HeavyCoalesce Merge] threw: $e');
          }
        } else {
          debugPrint('🛑 [HeavyCoalesce] Skipping merge: FS day≠picked calendar date.');
        }

        // Abort again before self-heal
        if (_isStale(epochAtSchedule) || _currentDayKey != dayKeyAtSchedule) return;

        // SELF-HEAL (deferred)
        try {
          await _verifyAndSelfHealIfStale();
        } catch (e) {
          debugPrint('⚠️ [HeavyCoalesce SelfHeal] threw: $e');
        }
      } finally {
        // no-op
      }
    });
  }




  String _rowCacheKey(int rowIndex) {
    var id = _selectedExercisesWithCircuits[rowIndex]['rowId'];
    if (id == null || (id as String).isEmpty) {
      // generate stable identity once
      id = '${DateTime.now().microsecondsSinceEpoch}_$rowIndex';
      _selectedExercisesWithCircuits[rowIndex]['rowId'] = id;
    }
    final ymd = DateFormat('yyyy-MM-dd').format(
        _selectedDate ?? DateTime.now());

    // 🔑 include hash of current inputs so stale rows can’t leak through
    final hash = _computeNowInputsHash(); // new helper from Step 3
    return '$id|$ymd|$hash';
  }





  Future<List<_MissedItem>> _computeMissedExercisesForWeek() async {
    if (_selectedBlockId == null || _selectedDate == null ||
        blockStartDate == null) return const [];
    final uid = UserContext
        .of(context, listen: false)
        .currentUid;
    if ((uid ?? '').isEmpty) return const [];

    final daysSinceStart = _selectedDate!.difference(blockStartDate!).inDays;
    if (daysSinceStart < 0) return const [];
    final weekIndex = (daysSinceStart / 7).floor();
    final todayIndex = daysSinceStart % 7;

    // Paths
    final blocksCol = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks');
    final weekDocRef = blocksCol.doc(_selectedBlockId)
        .collection('weeks')
        .doc('week_$weekIndex');
    final daysCol = weekDocRef.collection('days');

    // 1) Load planned for all 7 days (server, fallback cache)
    final dayDocsServer = await daysCol.get(
        const GetOptions(source: Source.server))
        .catchError((_) => null);
    final dayDocs = dayDocsServer ??
        await daysCol.get(const GetOptions(source: Source.cache));

    // Build: planned per dayIndex
    final plannedByDay = <int, List<Map<String, dynamic>>>{};
    for (final d in dayDocs.docs) {
      final di = int.tryParse(d.id.replaceFirst('day_', '')) ?? 0;
      plannedByDay[di] =
      List<Map<String, dynamic>>.from(d.data()['exercises'] ?? const []);
    }
    for (int i = 0; i < 7; i++) {
      plannedByDay.putIfAbsent(i, () => <Map<String, dynamic>>[]);
    }

    // 2) Load completed workouts for all 7 days of this week (doc-id + legacy auto-ID)
    final weekStart = DateTime(
        blockStartDate!.year, blockStartDate!.month, blockStartDate!.day)
        .add(Duration(days: weekIndex * 7));
    final workoutsCol = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts');

    String isoDay(DateTime d) => '${DateTime(d.year, d.month, d.day)
        .toIso8601String()
        .split(".")
        .first}.000';

    final weekServer = await workoutsCol
        .where('date', isGreaterThanOrEqualTo: isoDay(weekStart))
        .where(
        'date', isLessThan: isoDay(weekStart.add(const Duration(days: 7))))
        .get(const GetOptions(source: Source.server))
        .catchError((_) => null);

    final weekCache = weekServer ??
        await workoutsCol
            .where('date', isGreaterThanOrEqualTo: isoDay(weekStart))
            .where(
            'date', isLessThan: isoDay(weekStart.add(const Duration(days: 7))))
            .get(const GetOptions(source: Source.cache));

    final legacyByDate = <String, List<Map<String, dynamic>>>{};
    for (final doc in weekCache.docs) {
      final raw = doc.data()['date'];
      final dt = (raw is Timestamp) ? raw.toDate() : DateTime.tryParse(
          raw?.toString() ?? '');
      if (dt == null) continue;
      final key = _ymd(dt);
      (legacyByDate[key] ??= []).addAll(
          List<Map<String, dynamic>>.from(doc.data()['exercises'] ?? const []));
    }

    // Also try doc-id per day (server preferred)
    final completedByDay = <int, List<Map<String, dynamic>>>{};
    for (int d = 0; d < 7; d++) {
      final date = weekStart.add(Duration(days: d));
      final key = _ymd(date);
      final docServer = await workoutsCol.doc(key).get(
          const GetOptions(source: Source.server))
          .catchError((_) => null);
      final docCache = (docServer?.exists == true
          ? docServer
          : await workoutsCol.doc(key).get(
          const GetOptions(source: Source.cache)));

      final merged = <Map<String, dynamic>>[];
      if (docCache?.exists == true) {
        merged.addAll(List<Map<String, dynamic>>.from(
            docCache!.data()?['exercises'] ?? const []));
      }
      if ((legacyByDate[key] ?? const []).isNotEmpty) {
        merged.addAll(legacyByDate[key]!);
      }
      completedByDay[d] = merged;
    }

    // 3) Build dedupe keys for TODAY planned (use both id and name)
    final nameToId = _buildNameToIdLookup();
    final todayPlanned = plannedByDay[todayIndex]!;
    final plannedTodayKeys = <String>{};
    for (final ex in todayPlanned) {
      final name = (ex['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final id = nameToId[name.toLowerCase()];
      plannedTodayKeys.add(_plannedKey(id: id, name: name));
    }
    // Also suppress anything already present in today's *current UI state*
    for (final e in _selectedExercisesWithCircuits) {
      final n = (e['name'] ?? '').toString().trim();
      if (n.isEmpty) continue;
      final id = nameToId[n.toLowerCase()];
      plannedTodayKeys.add(_plannedKey(id: id, name: n));
    }


    // 4) Walk earlier days of this week; collect "missed"
    final missed = <_MissedItem>[];
    for (int d = 0; d < todayIndex; d++) {
      final planned = plannedByDay[d]!;
      if (planned.isEmpty) continue;

      // Build completed set for day d (use composite by name+circuitIndex)
      final completed = completedByDay[d]!;
      final completedKeys = <String>{};
      for (final cx in completed) {
        final n = (cx['name'] ?? '').toString().trim().toLowerCase();
        final c = (cx['circuitIndex'] ?? 0) as int;
        if (n.isEmpty) continue;
        completedKeys.add('$n@$c');
      }

      for (int i = 0; i < planned.length; i++) {
        final row = planned[i];
        final n = (row['name'] ?? '').toString().trim();
        if (n.isEmpty) continue;
        final c = (row['circuitIndex'] ?? 0) as int;

        final alreadyDone = completedKeys.contains('${n.toLowerCase()}@$c');
        if (alreadyDone) continue;

        // suppress if planned today (by id or name)
        final id = nameToId[n.toLowerCase()];
        final key = _plannedKey(id: id, name: n);
        if (plannedTodayKeys.contains(key)) {
          // "damage mitigation": do not offer today, but still considered missed globally
          continue;
        }

        missed.add(_MissedItem(
          sourceWeekIndex: weekIndex,
          sourceDayIndex: d,
          rowIndex: i,
          name: n,
          circuitIndex: c,
          row: Map<String, dynamic>.from(row),
        ));
      }
    }

    // Collapse duplicates by name for this feature (show once per exercise), per your rule 5
    final seen = <String>{};
    final deduped = <_MissedItem>[];
    for (final m in missed) {
      final k = m.name.trim().toLowerCase();
      if (seen.contains(k)) continue;
      seen.add(k);
      deduped.add(m);
    }
    return deduped;
  }

  Future<void> _maybePromptForMissedExercises(
      {List<_MissedItem>? precomputed}) async {
    if (_selectedDate == null) return;
    await _refreshMissedState();

    var items = precomputed ?? await _computeMissedExercisesForWeek();
    items = _filterStillMissingNow(items);
    if (items.isEmpty) return;

    // ✅ Keep selections outside the builder so it persists across setLocal rebuilds
    final selections = List<bool>.filled(items.length, false);

    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final theme = Theme.of(context);
            final cs = theme.colorScheme;
            final isDark = theme.brightness == Brightness.dark;
            final bg = isDark ? const Color(0xFF121212) : cs.surface;
            final titleColor = isDark ? cs.tertiary : cs.primary;
            final chipColor = isDark ? const Color(0xFF1E1E1E) : cs
                .surfaceVariant;

            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              backgroundColor: bg,
              elevation: 8,
              titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
              contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),

              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Missed exercises',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: titleColor,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => Navigator.of(ctx).pop(),
                    child: Padding(
                      padding: const EdgeInsets.all(6.0),
                      child: Icon(Icons.close,
                          color: isDark ? Colors.white70 : Colors.black54),
                    ),
                  ),
                ],
              ),

              content: ConstrainedBox(
                constraints: const BoxConstraints(
                    maxHeight: 420, minWidth: 320),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (int i = 0; i < items.length; i++)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: chipColor,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: selections[i]
                                ? [
                              BoxShadow(
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                                color: cs.primary.withOpacity(0.25),
                              ),
                            ]
                                : null,
                          ),
                          child: Material(
                            type: MaterialType.transparency,
                            child: CheckboxListTile(
                              dense: true,
                              controlAffinity: ListTileControlAffinity.leading,
                              value: selections[i],
                              onChanged: (v) =>
                                  setLocal(() => selections[i] = v ?? false),
                              checkboxShape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6)),
                              activeColor: cs.primary,
                              title: Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 2),
                                child: Text(
                                  '${items[i]
                                      .name} — missed on ${_weekdayShortLabel(
                                      items[i].sourceDayIndex)}',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: selections[i]
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: isDark
                                        ? (selections[i] ? Colors.white : Colors
                                        .white70)
                                        : (selections[i] ? Colors.black : Colors
                                        .black87),
                                  ),
                                ),
                              ),
                              tileColor: selections[i] ? chipColor.withOpacity(
                                  0.92) : chipColor,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              actions: [
                TextButton(
                  onPressed: () async {
                    final chosen = <_MissedItem>[];
                    for (int i = 0; i < items.length; i++) {
                      if (selections[i]) chosen.add(items[i]);
                    }
                    if (chosen.isNotEmpty) await _applyMissedExercisesToToday(
                        chosen);
                    if (mounted) Navigator.of(ctx).pop();
                  },
                  child: const Text('Add selected'),
                ),
                FilledButton(
                  onPressed: () async {
                    await _applyMissedExercisesToToday(items);
                    if (mounted) Navigator.of(ctx).pop();
                  },
                  child: const Text('Add all'),
                ),
              ],
            );
          },
        );
      },
    );
  }


  Future<void> _applyMissedExercisesToToday(List<_MissedItem> chosen) async {
    if (_selectedBlockId == null || _selectedDate == null ||
        blockStartDate == null) return;
    final uid = UserContext
        .of(context, listen: false)
        .currentUid;
    if ((uid ?? '').isEmpty) return;

    final daysSinceStart = _selectedDate!.difference(blockStartDate!).inDays;
    final weekIndex = (daysSinceStart / 7).floor();
    final dayIndex = daysSinceStart % 7;

    // --- PRUNE: keep only rows for the selected date before merging BB2 ---
    final String _ymdSel = DateFormat('yyyy-MM-dd').format(_selectedDate);

    bool _rowMatchesSelectedDate(Map<String, dynamic> row) {
      final String cardId = (row['cardId'] ?? '') as String;
      if (cardId.isEmpty) {
        // Legacy/ambiguous rows (from existing workout overlay) are treated as current-date scoped.
        return true;
      }
      // Warmup/plan snapshot rows: "YYYY-MM-DD|plan|..."
      if (cardId.startsWith('$_ymdSel|plan|')) return true;
      // BB2-inserted rows: "bb2|YYYY-MM-DD|..."
      if (cardId.startsWith('bb2|$_ymdSel|')) return true;

      // Anything else belongs to a different date → drop.
      return false;
    }

// Collect indices to keep
    final List<int> _keepIdx = <int>[];
    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      final row = _selectedExercisesWithCircuits[i];
      if (_rowMatchesSelectedDate(row)) _keepIdx.add(i);
    }

    if (_keepIdx.length != _selectedExercisesWithCircuits.length) {
      print('🧹 [WES Merge] Pruning ${_selectedExercisesWithCircuits.length - _keepIdx.length} row(s) not for date=$_ymdSel');

      // Helper to slice by index list
      List<T> _slice<T>(List<T> src) =>
          [for (int i = 0; i < src.length; i++) if (_keepIdx.contains(i)) src[i]];


      // Mutate in place (don’t reassign the list variables)
      setState(() {
        final sel = _slice(_selectedExercisesWithCircuits);
        final sets = _slice(_workoutSets);
        final reps = _slice(_repsControllers);
        final wts  = _slice(_weightControllers);
        final rir  = _slice(_rirControllers);
        final vel  = _slice(_velocityControllers);
        final notes= _slice(_notesControllers);

        _selectedExercisesWithCircuits
          ..clear()
          ..addAll(sel);
        _workoutSets
          ..clear()
          ..addAll(sets);
        _repsControllers
          ..clear()
          ..addAll(reps);
        _weightControllers
          ..clear()
          ..addAll(wts);
        _rirControllers
          ..clear()
          ..addAll(rir);
        _velocityControllers
          ..clear()
          ..addAll(vel);
        _notesControllers
          ..clear()
          ..addAll(notes);
      });
    }


    final blocksCol = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks');
    final weekDocRef = blocksCol.doc(_selectedBlockId!)
        .collection('weeks')
        .doc('week_$weekIndex');
    final todayRef = weekDocRef.collection('days').doc('day_$dayIndex');

    // 1) Read today's doc (server→cache), determine new circuit index
    final todaySnapServer = await todayRef.get(
        const GetOptions(source: Source.server)).catchError((_) => null);
    final todaySnap = (todaySnapServer?.exists == true ? todaySnapServer
        : await todayRef.get(const GetOptions(source: Source.cache)));

    final todayExercises = todaySnap?.data()?['exercises'];
    final List<Map<String, dynamic>> todayList =
    todayExercises != null ? List<Map<String, dynamic>>.from(todayExercises) : <
        Map<String, dynamic>>[];

    // Determine next circuit index (new circuit for all moved items)
    int maxCircuit = 0;
    for (final ex in todayList) {
      final ci = (ex['circuitIndex'] ?? 0) as int;
      if (ci > maxCircuit) maxCircuit = ci;
    }
    final int newCircuitIndex = maxCircuit + 1;

    // 2) Group chosen by source day (so we only read/write each source once)
    final bySource = <int, List<_MissedItem>>{};
    for (final m in chosen) {
      (bySource[m.sourceDayIndex] ??= []).add(m);
    }

    // 3) Build batch: remove from each source day; append to today
    final batch = FirebaseFirestore.instance.batch();

    // Ensure week doc exists (metadata merge—keeps consistent with your save)
    batch.set(weekDocRef, {'exists': true}, SetOptions(merge: true));

    // Load & update sources
    for (final entry in bySource.entries) {
      final sDay = entry.key;
      final srcRef = weekDocRef.collection('days').doc('day_$sDay');

      // Read source (server→cache)
      final srcSrv = await srcRef.get(const GetOptions(source: Source.server))
          .catchError((_) => null);
      final srcSnap = (srcSrv?.exists == true ? srcSrv
          : await srcRef.get(const GetOptions(source: Source.cache)));

      final List<Map<String, dynamic>> srcList =
      List<Map<String, dynamic>>.from(
          srcSnap?.data()?['exercises'] ?? const []);

      // Remove the specific rows (by (name,circuitIndex) matching FIRST occurrence)
      for (final m in entry.value) {
        final idx = srcList.indexWhere((e) =>
        (e['name'] ?? '').toString().trim().toLowerCase() ==
            m.name.trim().toLowerCase() &&
            (e['circuitIndex'] ?? 0) == m.circuitIndex);
        if (idx >= 0) srcList.removeAt(idx);
      }

      batch.set(srcRef, {'exercises': srcList}, SetOptions(merge: true));
    }

    // Append moved rows to today with the NEW circuit index (DEDUPE by id or name)
    final existingTodayKeys = <String>{};
// current Firestore state for today
    for (final ex in todayList) {
      final n = (ex['name'] ?? '').toString().trim().toLowerCase();
      final id = (ex['exerciseId'] ?? '').toString().trim().toLowerCase();
      if (n.isNotEmpty) existingTodayKeys.add('name#$n');
      if (id.isNotEmpty) existingTodayKeys.add('id#$id');
    }

// avoid dupes within this single batch too
    final willAppendKeys = <String>{};

    final appended = <Map<String, dynamic>>[];
    for (final m in chosen) {
      final row = Map<String, dynamic>.from(m.row);
      final n = (row['name'] ?? '').toString().trim().toLowerCase();
      final id = (row['exerciseId'] ?? '').toString().trim().toLowerCase();

      final kName = n.isNotEmpty ? 'name#$n' : null;
      final kId = id.isNotEmpty ? 'id#$id' : null;

      final alreadyPlanned =
          (kId != null && existingTodayKeys.contains(kId)) ||
              (kName != null && existingTodayKeys.contains(kName)) ||
              (kId != null && willAppendKeys.contains(kId)) ||
              (kName != null && willAppendKeys.contains(kName));

      if (alreadyPlanned) {
        // Skip duplicate
        continue;
      }

      row['circuitIndex'] = newCircuitIndex; // force new circuit
      appended.add(row);

      if (kName != null) willAppendKeys.add(kName);
      if (kId != null) willAppendKeys.add(kId);
    }

    final newToday = <Map<String, dynamic>>[];
    newToday.addAll(todayList);
    newToday.addAll(appended);

    // circuitStartIndices: ensure new circuit header at the append start
    final savedStarts = List<int>.from(
        todaySnap?.data()?['circuitStartIndices'] ?? const [0]);
    final appendStartIndex = todayList.length; // first index of appended rows
    final newStarts = List<int>.from(savedStarts);
    if (!newStarts.contains(appendStartIndex)) newStarts.add(appendStartIndex);
    newStarts.sort();

    // workoutName/date (like saveDayToFirestore)
    final date = blockStartDate!.add(Duration(days: weekIndex * 7 + dayIndex));
    final workoutName = "${DateFormat('EEE d MMM').format(
        date)} - Week ${weekIndex + 1}";

    batch.set(todayRef, {
      'exercises': newToday,
      'circuitStartIndices': newStarts,
      'date': Timestamp.fromDate(date),
      'workoutName': workoutName,
    }, SetOptions(merge: true));

    await batch.commit();

    // 4) Mirror into WES state (append rows with new circuit)
    if (!mounted) return;
    setState(() {
      // add to UI lists
      for (final m in appended) {
        final name = (m['name'] ?? '').toString().trim();
        final eid = (m['exerciseId'] ?? m['id'])?.toString().trim() ?? '';
        final resolvedId = eid.isNotEmpty ? eid : (PeriodizationModelUtils.nameToId[name] ?? name).trim();
        _selectedExercisesWithCircuits.add({
          'name': name,
          'exerciseId': resolvedId,
          'id': resolvedId,
          'circuitIndex': newCircuitIndex,
          'rowId': UniqueKey().toString(),
          // ensure stable identity for caching/UI
        });

        _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
        _repsControllers.add(
            List.generate(_defaultSets, (_) => TextEditingController()));
        _weightControllers.add(
            List.generate(_defaultSets, (_) => TextEditingController()));
        _rirControllers.add(
            List.generate(_defaultSets, (_) => TextEditingController()));
        _velocityControllers.add(
            List.generate(_defaultSets, (_) => TextEditingController()));
        _notesControllers.add(
            List.generate(_defaultSets, (_) => TextEditingController()));

        // ----- NEW: seed only if non-zero / non-empty -----
        // ----- REPLACE the current seeding/hydration block with this -----

        final repsVal = (m['reps'] as num?)?.toInt();
        final weightVal = (m['weight'] as num?)?.toDouble();
        final rirVal = (m['rir'] as num?)?.toDouble();
        final velVal = (m['velocity']?.toString() ?? '').trim();
        final notesVal = (m['notes']?.toString() ?? '').trim();

        final hasReps = repsVal != null && repsVal != 0;
        final hasWeight = weightVal != null && weightVal != 0.0;
        final hasRir = rirVal != null && rirVal != 0.0;

        final key = resolvedId.toLowerCase();

// 1) Put non-zero BB2 values into hint storage ONLY
        if (hasReps || hasWeight || hasRir) {
          _resolvedBB2Values[key] = {
            if (hasReps) 'reps': repsVal,
            if (hasWeight) 'weight': weightVal,
            if (hasRir) 'rir': rirVal,
          };
        }

// 2) Do NOT hydrate sets or controllers with reps/weight/rir.
//    Leave them blank so they render as hint, not as user-entered.
//
//    If you still want to carry velocity/notes (not part of hint logic),
//    it's okay to set them only when non-empty:

        final idx = _selectedExercisesWithCircuits.length - 1;

        if (_velocityControllers.length > idx &&
            _velocityControllers[idx].isNotEmpty) {
          if (velVal.isNotEmpty) _velocityControllers[idx][0].text = velVal;
        }
        if (_notesControllers.length > idx &&
            _notesControllers[idx].isNotEmpty) {
          if (notesVal.isNotEmpty) _notesControllers[idx][0].text = notesVal;
        }

// Also: do NOT set any _savedFields[...] flags here.
// -----------------------------------------------

        // ----- END NEW -----
      }
    });


    await _saveWorkoutDraftToCache();
    await _refreshMissedState(); // 👈 recompute; will flip _hasMissedForToday to false if none left
    if (mounted) setState(() {});
  }


  //...Missing exercises block ends

  //Bodyweight exercises block begins...

  Future<void> _primeLatestBodyweightCache(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('weights')
          .orderBy('timestamp', descending: true)
          .limit(1)
          .get();

      if (snap.docs.isNotEmpty) {
        final d = snap.docs.first.data();
        final bw = (d['weight'] as num?)?.toDouble();
        final ts = (d['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now();
        if (bw != null && bw > 0) {
          PeriodizationModelUtils.setLatestBodyweight(
            uid: uid,
            weightKg: bw,
            asOf: ts,
          );
        }
      }
    } catch (e) {
      debugPrint(
          '⚠️ _primeLatestBodyweightCache failed → using default 80kg: $e');
    }
  }


  Future<void> _primeBodyweightHistoryCache(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('weights')
          .orderBy('timestamp', descending: true)
          .limit(1000) // plenty; adjust as you like
          .get();

      final entries = <Map<String, dynamic>>[];
      for (final d in snap.docs) {
        final data = d.data();
        final double? bw = (data['weight'] as num?)?.toDouble();
        final DateTime ts = (data['timestamp'] as Timestamp?)?.toDate() ??
            DateTime.now();
        final String unit = (data['unit'] as String?) ?? 'kg';
        if (bw != null && bw > 0 && unit == 'kg') {
          entries.add({'date': ts, 'weight': bw, 'unit': 'kg'});
        }
      }

      if (entries.isNotEmpty) {
        PeriodizationModelUtils.setBodyweightHistory(
            uid: uid, entries: entries);
        // also keep your “latest” cache in sync (PMU does this too, but safe either way)
        PeriodizationModelUtils.setLatestBodyweight(
          uid: uid,
          weightKg: entries.first['weight'] as double,
          asOf: entries.first['date'] as DateTime,
        );
      }
    } catch (e) {
      debugPrint(
          '⚠️ _primeBodyweightHistoryCache failed → using default 80kg: $e');
    }
  }

//... Bodyweight exercises block ends


  String formatWeight(double v) {
    // Round to 2 decimals for display decisions
    final s2 = v.toStringAsFixed(2); // e.g., "32.50", "37.75", "40.00"

    // Keep two decimals for quarter plates
    if (s2.endsWith('25') || s2.endsWith('75')) return s2;

    // If second decimal is 0 → show one decimal
    if (s2.endsWith('0')) {
      final s1 = v.toStringAsFixed(1); // e.g., "32.5", "40.0"
      if (s1.endsWith('.0')) {
        return s1.substring(0, s1.length - 2); // "40.0" → "40"
      }
      return s1; // "32.5"
    }

    // Otherwise keep two
    return s2;
  }


  double getSet2E1RM(int exerciseIndex) {
    String exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

    double set1Weight =
        double.tryParse(_weightControllers[exerciseIndex][0].text) ??
            set1SuggestedWeight(exerciseIndex);
    int set1Reps = int.tryParse(_repsControllers[exerciseIndex][0].text) ??
        set1SuggestedReps(exerciseIndex).toInt();
    double set1RIRValue =
        double.tryParse(_rirControllers[exerciseIndex][0].text) ??
            set1RIR(exerciseIndex);
    double set1EffectiveReps = set1Reps + set1RIRValue;

    double set1E1RM = (set1EffectiveReps <= 6)
        ? (set1Weight * (36 / (37 - set1EffectiveReps))) // Brzycki for low reps
        : (set1Weight *
        (1 + (0.0333 * set1EffectiveReps))); // Epley for high reps

    print(
        "Set 2 E1RM for $exerciseName: ${set1E1RM.toStringAsFixed(
            1)}"); // ✅ Debugging
    return (set1E1RM > 7) ? (set1E1RM - 7) : 1.0;
  }

  double getSet3E1RM(int exerciseIndex) {
    String exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

    double set1Weight =
        double.tryParse(_weightControllers[exerciseIndex][0].text) ??
            set1SuggestedWeight(exerciseIndex);
    int set1Reps = int.tryParse(_repsControllers[exerciseIndex][0].text) ??
        set1SuggestedReps(exerciseIndex).toInt();
    double set1RIRValue =
        double.tryParse(_rirControllers[exerciseIndex][0].text) ??
            set1RIR(exerciseIndex);
    double set1EffectiveReps = set1Reps + set1RIRValue;

    double set1E1RM = (set1EffectiveReps <= 6)
        ? (set1Weight * (36 / (37 - set1EffectiveReps))) // Brzycki for low reps
        : (set1Weight *
        (1 + (0.0333 * set1EffectiveReps))); // Epley for high reps

    return (set1E1RM > 7) ? (set1E1RM - 10.5) : 1.0;
  }

  Future<void> _fetchLastWorkoutTopSetReps() async {
    final uid = UserContext
        .of(context, listen: false)
        .currentUid;
    if (uid == null) return;
    print('📡 Fetching top sets for user: $uid');

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .orderBy('date', descending: true) // ✅ Fetch newest first
        .limit(12) // ✅ Get last 12 workouts
        .get();

    if (snapshot.docs.isNotEmpty) {
      setState(() {
        exercisePreviousTopSetReps.clear(); // ✅ Reset reps per exercise
        exercisePreviousE1RMs.clear(); // ✅ Reset E1RMs per exercise

        for (var doc in snapshot.docs) {
          final workout = Workout.fromFirestore(doc);

          if (workout.exercises.isNotEmpty) {
            for (var exercise in workout.exercises) {
              String exerciseName =
                  exercise.name; // ✅ Exercise-specific tracking

              SetDetails? topSet;
              double highestE1RM = 0.0;

              for (var set in exercise.sets) {
                double weight = _parseToDouble(set.weight);
                double reps = _parseToDouble(set.reps);
                double rir = _parseToDouble(set.rir);
                double totalReps = reps + rir;

                double e1rm = (totalReps <= 6)
                    ? (weight * (36 / (37 - totalReps))) // Brzycki formula
                    : (weight * (1 + (0.0333 * totalReps))); // Epley formula

                if (topSet == null || e1rm > highestE1RM) {
                  highestE1RM = e1rm;
                  topSet = set;
                }
              }

              if (topSet != null) {
                int effectiveReps =
                (_parseToDouble(topSet.reps) + _parseToDouble(topSet.rir))
                    .floor();

                // ✅ Store E1RM per exercise
                exercisePreviousE1RMs.putIfAbsent(exerciseName, () => []);
                exercisePreviousE1RMs[exerciseName]!.add(highestE1RM);

                // ✅ Keep only last 4 E1RMs per exercise
                if (exercisePreviousE1RMs[exerciseName]!.length > 4) {
                  exercisePreviousE1RMs[exerciseName] =
                      exercisePreviousE1RMs[exerciseName]!.take(4).toList();
                }

                // ✅ Store reps per exercise
                exercisePreviousTopSetReps.putIfAbsent(exerciseName, () => []);
                exercisePreviousTopSetReps[exerciseName]!.add(effectiveReps);

                // ✅ Keep only last 12 reps per exercise
                if (exercisePreviousTopSetReps[exerciseName]!.length > 12) {
                  exercisePreviousTopSetReps[exerciseName] =
                      exercisePreviousTopSetReps[exerciseName]!
                          .take(12)
                          .toList();
                }
              }
            }
          }
          // 🔍 Print final stored top sets for debugging
          for (final entry in exercisePreviousE1RMs.entries) {
            final name = entry.key;
            final e1rms = entry.value.map((e) => e.toStringAsFixed(2)).join(
                ', ');
            final reps = exercisePreviousTopSetReps[name]?.join(', ') ?? '—';

          }
        }
      });
    }
  }

  String? getRepTargetForExerciseWES(String exerciseName, int rowIndex) {
    if (_blockStartDate == null || _selectedDate == null) {
      return null;
    }

    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName];
    if (exerciseId == null) return null;

    final details = PeriodizationModelUtils.plannedExerciseDetails[exerciseId];
    if (details == null) return null;

    final repTargets = details['repTargets'];
    if (repTargets == null) return null;

    final model = PeriodizationModelUtils
        .exercisePeriodizationModels[exerciseId];
    final weekIndex = getWeekIndexFromDate(_selectedDate!, _blockStartDate!);



    try {
      int? rep;

      switch (model) {
        case PeriodizationModelType.linearExposure:
          final exposureIndex = rowIndex;
          rep = PeriodizationModelUtils.getLinearExposureRepTarget(
            exerciseId: exerciseId,
            exposureIndex: exposureIndex,
            repTargetsByExercise: {exerciseId: {'repTargets': repTargets}},
            plannedExerciseDetails: PeriodizationModelUtils
                .plannedExerciseDetails,
          );
          break;

        case PeriodizationModelType.linearClassic:
          rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exerciseId,
            plannedIndex: rowIndex,
            weekIndex: weekIndex,
            repTargetsByExercise: {exerciseId: {'repTargets': repTargets}},
            plannedExerciseDetails: PeriodizationModelUtils
                .plannedExerciseDetails,
            blockStartDate: _blockStartDate,
            blockEndDate: _blockEndDate,
          );
          break;
        case PeriodizationModelType.dailyUndulatingWeek:
          rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exerciseId,
            plannedIndex: rowIndex,
            weekIndex: weekIndex,
            repTargetsByExercise: {exerciseId: {'repTargets': repTargets}},
            plannedExerciseDetails: PeriodizationModelUtils
                .plannedExerciseDetails,
            blockStartDate: _blockStartDate,
            blockEndDate: _blockEndDate,
          );
          break;

        case PeriodizationModelType.dupSignature:
        case PeriodizationModelType.dailyUndulatingExposure:
          rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exerciseId,
            plannedIndex: rowIndex,
            weekIndex: weekIndex,
            repTargetsByExercise: {exerciseId: {'repTargets': repTargets}},
            plannedExerciseDetails: PeriodizationModelUtils
                .plannedExerciseDetails,
          );
          break;

        default:
          return null;
      }

      print(
          '✅ [WES] Final rep target for $exerciseName (row $rowIndex) = $rep');
      return rep?.toString();
    } catch (e) {
      print('❌ [WES] Error in getRepTargetForExerciseWES: $e');
      return null;
    }
  }


  double bb2HintReps(int i) {
    final exerciseName = _selectedExercisesWithCircuits[i]['name']?.trim() ??
        '';
    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName] ??
        exerciseName;

    if (_blockStartDate == null || _selectedDate == null) {
      print(
          '❌ [WES] 1_blockStartDate or _selectedDate is null — cannot compute weekIndex');
      return 10.0;
    }

    final weekIndex = getWeekIndexFromDate(_selectedDate!, _blockStartDate!);

    final repTarget = getRepTargetForExerciseWES(exerciseName, 0);


    if (repTarget == null || repTarget
        .trim()
        .isEmpty) {
      print('❌ [WES] No rep target found for $exerciseName (week $weekIndex)');
      return 10.0;
    }

    final parsed = double.tryParse(repTarget
        .split('x')
        .first
        .trim());
    print('🔢 [WES] BB2 hintReps for $exerciseName (week $weekIndex) = $parsed');
    return parsed ?? 10.0;
  }


  int getWeekIndexFromDate(DateTime selectedDate, DateTime blockStartDate) {
    return selectedDate
        .difference(blockStartDate)
        .inDays ~/ 7;
  }


  void _debugPrintBlockDates() {

  }

  // Helper: resize a single row in a List<List<T>> to desiredSetCount
  void _resizeRow<T>(
      List<List<T>> outer,
      int rowIndex,
      int desiredSetCount,
      T Function() builder,
      ) {
    if (rowIndex < 0 || rowIndex >= outer.length) return;

    final row = outer[rowIndex];

    // Already the right size
    if (row.length == desiredSetCount) return;

    if (row.length > desiredSetCount) {
      // Trim extra sets
      outer[rowIndex] = row.sublist(0, desiredSetCount);
    } else {
      // Grow row by adding new items from builder()
      final List<T> newRow = List<T>.from(row);
      while (newRow.length < desiredSetCount) {
        newRow.add(builder());
      }
      outer[rowIndex] = newRow;
    }
  }

  int _plannedSetCountFor(int exerciseIndex) {
    // 🔒 Extra guard: if index is out of range or no rows yet, use default
    if (exerciseIndex < 0 ||
        exerciseIndex >= _selectedExercisesWithCircuits.length ||
        _selectedExercisesWithCircuits.isEmpty) {
      return _defaultSets;
    }
    int fallbackSets = _defaultSets;

    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    if (exerciseName.isEmpty) return fallbackSets;

    final exerciseId =
        PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;

    final model =
    PeriodizationModelUtils.exercisePeriodizationModels[exerciseId];

    // How many times this exercise is planned earlier on this day
    int plannedCountBefore = 0;
    for (int i = 0; i < exerciseIndex; i++) {
      if (_selectedExercisesWithCircuits[i]['name'] == exerciseName) {
        plannedCountBefore++;
      }
    }

    // Small helpers duplicated from _getProgressedValues
    String _norm(String s) {
      var t = s.toLowerCase().trim();
      t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
      t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
      t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
      t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');
      t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
      return t;
    }

    bool _hasValidSet(dynamic setsRaw) {
      final sets = (setsRaw is List) ? setsRaw.cast<Map>() : const <Map>[];
      return sets.any((s) {
        final w = (s['weight']?.toString() ?? '').trim();
        final r = (s['reps']?.toString() ?? '').trim();
        return w.isNotEmpty && r.isNotEmpty;
      });
    }

    int _parseSets(String raw) {
      // expect formats like "9 x 4" or "9x4"
      final match = RegExp(r'[xX]\s*(\d+)').firstMatch(raw);
      final parsed = match != null ? int.tryParse(match.group(1)!) : null;
      return (parsed != null && parsed > 0) ? parsed : fallbackSets;
    }

    // ---------------- DUP, By Exposure ----------------
    if (model == PeriodizationModelType.dailyUndulatingExposure) {
      final fullDetails = _exerciseSettings[exerciseId];
      final week1 = fullDetails?['repTargets']?['week1'];

      if (week1 is Map<String, dynamic>) {
        final sorted = week1.entries
            .where((e) => e.key.startsWith('instance'))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));

        if (sorted.isEmpty) return fallbackSets;

        int completedBeforeTodayInBlock = 0;

        if (blockStartDate != null && _selectedDate != null) {
          final matchedDates = <String>{};
          try {
            final base = DateTime(
                blockStartDate!.year, blockStartDate!.month, blockStartDate!.day);
            final todayStart = DateTime(
                _selectedDate!.year, _selectedDate!.month, _selectedDate!.day);

            final targetId = exerciseId;
            final targetNameNorm = _norm(exerciseName);

            for (final w in PeriodizationModelUtils.savedWorkoutsList) {
              final dateStr = (w['date'] ?? '').toString();
              final dt = DateTime.tryParse(dateStr);
              if (dt == null) continue;

              final dayOnly = DateTime(dt.year, dt.month, dt.day);
              if (dayOnly.isBefore(base) || !dayOnly.isBefore(todayStart)) {
                continue; // [base, today)
              }

              final exs = w['exercises'];
              if (exs is! List) continue;

              final matched = exs.any((ex) {
                if (!_hasValidSet(ex['sets'])) return false;

                final exId =
                (ex['exerciseId'] ?? ex['id'] ?? ex['exercise_id'] ?? '')
                    .toString();
                if (exId.isNotEmpty && exId == targetId) return true;

                final exName =
                (ex['name'] ?? ex['exercise'] ?? ex['title'] ?? '')
                    .toString();
                if (exName.isNotEmpty && _norm(exName) == targetNameNorm) {
                  return true;
                }

                final mapped =
                (PeriodizationModelUtils.nameToId[exName] ?? '').toString();
                return mapped.isNotEmpty && mapped == targetId;
              });

              if (matched) {
                final key =
                dateStr.length >= 10 ? dateStr.substring(0, 10) : dateStr;
                matchedDates.add(key);
              }
            }

            completedBeforeTodayInBlock = matchedDates.length;
          } catch (_) {/* keep 0 */}
        }

        final plannedIndex = completedBeforeTodayInBlock + plannedCountBefore;
        final idx = sorted.isEmpty ? 0 : plannedIndex % sorted.length;
        final raw = sorted[idx].value?.toString() ?? '';

        return _parseSets(raw);
      }

      return fallbackSets;
    }

    // ---------------- DUP, By Week ----------------
    if (model == PeriodizationModelType.dailyUndulatingWeek) {
      final weekMap = _exerciseSettings[exerciseId]?['repTargets']?['week1'];
      if (weekMap is Map<String, dynamic>) {
        final sorted = weekMap.entries
            .where((e) => e.key.startsWith('instance'))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));

        if (sorted.isEmpty) return fallbackSets;

        int completedEarlierThisWeek = 0;

        if (blockStartDate != null && _selectedDate != null) {
          final matchedDates = <String>{};
          try {
            final wkIdx =
            PeriodizationModelUtils.getWeekIndexForDate(_selectedDate, blockStartDate!);
            final base = DateTime(
                blockStartDate!.year, blockStartDate!.month, blockStartDate!.day);
            final weekStart = base.add(Duration(days: wkIdx * 7));
            final todayStart = DateTime(
                _selectedDate!.year, _selectedDate!.month, _selectedDate!.day);

            final targetId = exerciseId;
            final targetNameNorm = _norm(exerciseName);

            for (final w in PeriodizationModelUtils.savedWorkoutsList) {
              final dateStr = (w['date'] ?? '').toString();
              final dt = DateTime.tryParse(dateStr);
              if (dt == null) continue;

              final dayOnly = DateTime(dt.year, dt.month, dt.day);
              if (dayOnly.isBefore(weekStart) || !dayOnly.isBefore(todayStart)) {
                continue; // strictly before today in this week
              }

              final exs = w['exercises'];
              if (exs is! List) continue;

              final matched = exs.any((ex) {
                if (!_hasValidSet(ex['sets'])) return false;

                final exId =
                (ex['exerciseId'] ?? ex['id'] ?? ex['exercise_id'] ?? '')
                    .toString();
                if (exId.isNotEmpty && exId == targetId) return true;

                final exName =
                (ex['name'] ?? ex['exercise'] ?? ex['title'] ?? '')
                    .toString();
                if (exName.isNotEmpty && _norm(exName) == targetNameNorm) {
                  return true;
                }

                final mapped =
                (PeriodizationModelUtils.nameToId[exName] ?? '').toString();
                return mapped.isNotEmpty && mapped == targetId;
              });

              if (matched) {
                final key =
                dateStr.length >= 10 ? dateStr.substring(0, 10) : dateStr;
                matchedDates.add(key);
              }
            }

            completedEarlierThisWeek = matchedDates.length;
          } catch (_) {/* keep 0 */}
        }

        final plannedIndex = completedEarlierThisWeek;
        final idx = plannedIndex % sorted.length;
        final raw = sorted[idx].value?.toString() ?? '';

        return _parseSets(raw);
      }

      return fallbackSets;
    }

    // ---------------- Linear Classic ----------------
    if (model == PeriodizationModelType.linearClassic) {
      final repTargets = _exerciseSettings[exerciseId]?['repTargets'];
      final weekStart = repTargets?['week1'];

      if (weekStart is Map<String, dynamic> && blockStartDate != null && blockEndDate != null) {
        final week = PeriodizationModelUtils.getWeekIndexForDate(
          _selectedDate,
          blockStartDate!,
        );

        final blockLength = PeriodizationModelUtils.getBlockLength(
          blockStartDate: blockStartDate!,
          blockEndDate: blockEndDate!,
        );

        final instanceCount =
        PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
          exerciseName: exerciseName,
          savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
          blockStartDate: blockStartDate!,
          weekIndex: week,
        );

        final sortedKeys = weekStart.keys
            .where((k) => k.startsWith('instance'))
            .toList()
          ..sort();

        if (sortedKeys.isEmpty) return fallbackSets;

        final instanceKey =
        sortedKeys[instanceCount % sortedKeys.length];

        final startRaw = weekStart[instanceKey]?.toString() ?? '10 x 3';

        // sets don't depend on week interpolation; we just parse them from startRaw
        return _parseSets(startRaw);
      }

      return fallbackSets;
    }

    // Other models → keep using whatever app-wide default you use
    return fallbackSets;
  }

  void _debugDumpSet1Ui(int i, {String tag = ''}) {
    if (i < 0 || i >= _selectedExercisesWithCircuits.length) return;

    final exName = (_selectedExercisesWithCircuits[i]['name'] ?? '').toString().trim();
    final rowKey = _rowKeyBy(i);

    final wTxt = _weightControllers[i][0].text.trim();
    final rTxt = _repsControllers[i][0].text.trim();
    final rirTxt = _rirControllers[i][0].text.trim();

    // What the UI would show as hint if the field is empty
    final wHint = (_isInitialized && !_isLoadingData) ? formatWeight(set1SuggestedWeight(i)) : '';
    final rHint = (_isInitialized && !_isLoadingData) ? (set1SuggestedReps(i).toInt().toString()) : '';

    // What is actually visible in the TextField:
    // - If controller has text, the user sees that (typed)
    // - Else they see hintText
    final wVisible = wTxt.isNotEmpty ? 'TYPED:$wTxt' : 'HINT:$wHint';
    final rVisible = rTxt.isNotEmpty ? 'TYPED:$rTxt' : 'HINT:$rHint';
    final rirVisible = rirTxt.isNotEmpty ? 'TYPED:$rirTxt' : 'HINT:(computed)';

    final seed = _seedHintsByKey[rowKey];

    print('🧾 [WES UI$tag] i=$i ex="$exName" rowKey="$rowKey" init=$_isInitialized loading=$_isLoadingData');
    print('   weight: $wVisible  (seed s1_weight=${seed?['s1_weight']} s1_weight_added=${seed?['s1_weight_added']})');
    print('   reps:   $rVisible  (seed s1_reps=${seed?['s1_reps']})');
    print('   rir:    $rirVisible (seed rir=${seed?['rir']} s1_rir?=${seed?['s1_rir']})');
  }

  // CLAUDE_BULLET: Dump the entire visible UI state for the day (all exercises, all sets)
  Future<void> Claude_bulletDebugDumpFullDayUi({String tag = ''}) async {
    try {
      final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final workoutName = _workoutNameController.text;

      print('🧾 [WES UI DUMP$tag] date=$ymd  workoutName="${workoutName}"  '
          'rows=${_selectedExercisesWithCircuits.length}  init=$_isInitialized loading=$_isLoadingData');

      // Helper: what the RIR TextField uses as hint (matches the UI logic you currently have)
      String _rirHintFor(int i, int j) {
        // NOTE: this matches your current UI key usage in the RIR hintText block
        final seedKey = _rowKeyBy(i);
        final seed = _seedHintsByKey[seedKey];

        if (j == 0) {
          return formatRir((seed?['rir'] as num?)?.toDouble() ?? set1RIR(i));
        }
        if (j >= 1 && j <= 7) {
          final k = 's${j + 1}_rir';
          final seeded = (seed?[k] as num?)?.toDouble();
          final fallback = (j == 1)
              ? set2RIR(i)
              : (j == 2)
              ? set3RIR(i)
              : 1.0;
          return formatRir(seeded ?? fallback);
        }
        return '1';
      }

      // Helper: normalize “what’s visible”
      String _visibleOrHint(String typed, String hint) {
        final t = typed.trim();
        return t.isNotEmpty ? 'TYPED:$t' : 'HINT:$hint';
      }

      for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
        final exName =
        (_selectedExercisesWithCircuits[i]['name'] ?? '').toString().trim();
        final ci =
        (_selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0);

        // Prefer stable identifiers for prints + future snapshot shape
        final exId = (_selectedExercisesWithCircuits[i]['exerciseId'] ??
            _selectedExercisesWithCircuits[i]['id'] ??
            _selectedExercisesWithCircuits[i]['exerciseID'] ??
            '')
            .toString();

        final instanceKey = '$exId|$ci';

        // NOTE: still useful to print the internal rowKey for debugging,
        // but the stable "instanceKey" is what you want to key snapshots by.
        final rowKey = _rowKeyBy(i);

        int setCount = [
          if (i < _weightControllers.length) _weightControllers[i].length,
          if (i < _repsControllers.length) _repsControllers[i].length,
          if (i < _rirControllers.length) _rirControllers[i].length,
          if (i < _velocityControllers.length) _velocityControllers[i].length,
          if (i < _notesControllers.length) _notesControllers[i].length,
        ].fold<int>(0, (a, b) => a > b ? a : b);

        print(
          '  ── exerciseInstance="$instanceKey" exId="$exId" name="$exName" '
              'circuitIndex=$ci rowKey="$rowKey" sets=$setCount',
        );

        for (int j = 0; j < setCount; j++) {
          final wTxt =
          (i < _weightControllers.length && j < _weightControllers[i].length)
              ? _weightControllers[i][j].text
              : '';
          final rTxt =
          (i < _repsControllers.length && j < _repsControllers[i].length)
              ? _repsControllers[i][j].text
              : '';
          final rirTxt =
          (i < _rirControllers.length && j < _rirControllers[i].length)
              ? _rirControllers[i][j].text
              : '';
          final vTxt = (i < _velocityControllers.length &&
              j < _velocityControllers[i].length)
              ? _velocityControllers[i][j].text
              : '';
          final nTxt =
          (i < _notesControllers.length && j < _notesControllers[i].length)
              ? _notesControllers[i][j].text
              : '';

          // These match your current UI hint logic for weight & reps.
          String wHint = '';
          String rHint = '';

          if (_isInitialized && !_isLoadingData) {
            if (j == 0) {
              // Set 1 uses your existing logic
              wHint = formatWeight(set1SuggestedWeight(i));
              rHint = set1SuggestedReps(i).toInt().toString();
            } else {
              // Set 2+ must use the same async hint logic as the UI (ranges, caps, etc.)
              wHint = await _weightHintText(i, j);
              rHint = await _repsHintText(i, j);
            }
          }

          // RIR hint matches your UI logic per set index.
          final rirHint = _rirHintFor(i, j);

          final wVisible = _visibleOrHint(wTxt, wHint);
          final rVisible = _visibleOrHint(rTxt, rHint);
          final rirVisible = _visibleOrHint(rirTxt, rirHint);

          final vVisible =
          vTxt.trim().isNotEmpty ? 'TYPED:${vTxt.trim()}' : 'EMPTY';
          final nVisible =
          nTxt.trim().isNotEmpty ? 'TYPED:${nTxt.trim()}' : 'EMPTY';

          print(
            '     setIdx=$j (set${j + 1}): '
                'weight=$wVisible  reps=$rVisible  rir=$rirVisible  vel=$vVisible  notes=$nVisible',
          );
        }
      }

      print('🧾 [WES UI DUMP$tag] END');
    } catch (e, st) {
      print('🧾 [WES UI DUMP$tag] ERROR: $e');
      print(st);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Claude_bullet  –  Resume-like full-day UI snapshot  (Line 0)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Persist the complete visible state of every exercise×set so that
  /// re-entering WES for the same date within 2 hours restores the page
  /// exactly (hint stays hint, typed stays typed, empty stays empty).
  Future<void> Claude_bulletSaveFullDayUiSnapshot({required String reason}) async {
    try {
      if (_selectedExercisesWithCircuits.isEmpty) return;


      final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final uid = UserContext.of(context, listen: false).currentUid;
      final uidDateKey = '$uid|$ymd';

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final workoutName = _workoutNameController.text;

      // ── RIR-hint helper (same logic as debug dump) ──
      String rirHintFor(int i, int j) {
        final seedKey = _rowKeyBy(i);
        final seed = _seedHintsByKey[seedKey];
        if (j == 0) {
          return formatRir((seed?['rir'] as num?)?.toDouble() ?? set1RIR(i));
        }
        if (j >= 1 && j <= 7) {
          final k = 's${j + 1}_rir';
          final seeded = (seed?[k] as num?)?.toDouble();
          final fallback = (j == 1) ? set2RIR(i) : (j == 2) ? set3RIR(i) : 1.0;
          return formatRir(seeded ?? fallback);
        }
        return '1';
      }

      final List<Map<String, dynamic>> exercisesPayload = [];

      for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
        final exMap = _selectedExercisesWithCircuits[i];
        final exName = (exMap['name'] ?? '').toString().trim();
        final ci = (exMap['circuitIndex'] ?? 0);
        final exId = (exMap['exerciseId'] ?? exMap['id'] ?? exMap['exerciseID'] ?? '').toString();
        final instanceKey = '$exId|$ci';

        int setCount = [
          if (i < _weightControllers.length) _weightControllers[i].length,
          if (i < _repsControllers.length) _repsControllers[i].length,
          if (i < _rirControllers.length) _rirControllers[i].length,
          if (i < _velocityControllers.length) _velocityControllers[i].length,
          if (i < _notesControllers.length) _notesControllers[i].length,
        ].fold<int>(0, (a, b) => a > b ? a : b);

        final List<Map<String, dynamic>> setsPayload = [];

        // set1 numeric seeds
        double? s1WeightNum;
        double? s1RepsNum;
        double? s1RirNum;
        bool s1WeightTyped = false;
        bool s1RepsTyped = false;
        bool s1RirTyped = false;

        for (int j = 0; j < setCount; j++) {
          final wTxt = (i < _weightControllers.length && j < _weightControllers[i].length)
              ? _weightControllers[i][j].text.trim() : '';
          final rTxt = (i < _repsControllers.length && j < _repsControllers[i].length)
              ? _repsControllers[i][j].text.trim() : '';
          final rirTxt = (i < _rirControllers.length && j < _rirControllers[i].length)
              ? _rirControllers[i][j].text.trim() : '';
          final vTxt = (i < _velocityControllers.length && j < _velocityControllers[i].length)
              ? _velocityControllers[i][j].text.trim() : '';
          final nTxt = (i < _notesControllers.length && j < _notesControllers[i].length)
              ? _notesControllers[i][j].text.trim() : '';

          // Weight origin + display
          String wOrigin, wDisplay;
          if (wTxt.isNotEmpty) {
            wOrigin = 'typed'; wDisplay = wTxt;
          } else if (_isInitialized && !_isLoadingData) {
            String hintStr = '';
            if (j == 0) {
              hintStr = formatWeight(set1SuggestedWeight(i));
            } else {
              hintStr = await _weightHintText(i, j);
            }
            wOrigin = hintStr.isNotEmpty ? 'hint' : 'empty';
            wDisplay = hintStr;
          } else {
            wOrigin = 'empty'; wDisplay = '';
          }

          // Reps origin + display
          String rOrigin, rDisplay;
          if (rTxt.isNotEmpty) {
            rOrigin = 'typed'; rDisplay = rTxt;
          } else if (_isInitialized && !_isLoadingData) {
            String hintStr = '';
            if (j == 0) {
              final r = set1SuggestedReps(i);
              hintStr = r.toInt().toString();
            } else {
              hintStr = await _repsHintText(i, j);
            }
            rOrigin = hintStr.isNotEmpty ? 'hint' : 'empty';
            rDisplay = hintStr;
          } else {
            rOrigin = 'empty'; rDisplay = '';
          }

          // RIR origin + display
          String rirOrigin, rirDisplay;
          if (rirTxt.isNotEmpty) {
            rirOrigin = 'typed'; rirDisplay = rirTxt;
          } else {
            final hintStr = rirHintFor(i, j);
            rirOrigin = hintStr.isNotEmpty ? 'hint' : 'empty';
            rirDisplay = hintStr;
          }

          // Velocity + notes: typed or empty only
          final vOrigin = vTxt.isNotEmpty ? 'typed' : 'empty';
          final nOrigin = nTxt.isNotEmpty ? 'typed' : 'empty';

          setsPayload.add({
            'setIdx': j,
            'weight': {'origin': wOrigin, 'display': wDisplay},
            'reps': {'origin': rOrigin, 'display': rDisplay},
            'rir': {'origin': rirOrigin, 'display': rirDisplay},
            'velocity': {'origin': vOrigin, 'display': vTxt},
            'notes': {'origin': nOrigin, 'display': nTxt},
          });

          // Capture set1 numeric seeds
          if (j == 0) {
            s1WeightTyped = wOrigin == 'typed';
            s1RepsTyped = rOrigin == 'typed';
            s1RirTyped = rirOrigin == 'typed';
            s1WeightNum = double.tryParse(wDisplay.replaceAll('–', ''));
            s1RepsNum = double.tryParse(rDisplay.replaceAll('–', ''));
            s1RirNum = double.tryParse(rirDisplay.replaceAll('–', ''));
          }
        }

        exercisesPayload.add({
          'instanceKey': instanceKey,
          'exerciseId': exId,
          'name': exName,
          'circuitIndex': ci,
          'sets': setsPayload,
          'set1_weight_num': s1WeightNum,
          'set1_reps_num': s1RepsNum,
          'set1_rir_num': s1RirNum,
          'set1_weight_typed': s1WeightTyped,
          'set1_reps_typed': s1RepsTyped,
          'set1_rir_typed': s1RirTyped,
        });
      }

      final payload = jsonEncode({'exercises': exercisesPayload});

      final isar = await IsarDb.instance;
      final snap = ClaudeBulletSnapshot()
        ..dateYmd = ymd
        ..uidDateKey = uidDateKey
        ..lastEditedAt = nowMs
        ..workoutName = workoutName
        ..snapshotJson = payload
        ..cachedAt = DateTime.now();

      await isar.writeTxn(() async {
        await isar.claudeBulletSnapshots.put(snap);
      });

      // Log summary
      final firstEx = exercisesPayload.isNotEmpty ? exercisesPayload.first : null;
      String s1Summary = '';
      if (firstEx != null && (firstEx['sets'] as List).isNotEmpty) {
        final s1 = (firstEx['sets'] as List).first as Map<String, dynamic>;
        s1Summary = ' set1: w=${s1['weight']['origin']}:${s1['weight']['display']}'
            ' r=${s1['reps']['origin']}:${s1['reps']['display']}'
            ' rir=${s1['rir']['origin']}:${s1['rir']['display']}';
      }
      print('[Claude_bullet] SAVED snapshot reason=$reason date=$ymd '
          'lastEditedAt=$nowMs exercises=${exercisesPayload.length}$s1Summary');
    } catch (e, st) {
      print('[Claude_bullet] SAVE ERROR: $e');
      print(st);
    }
  }

  /// Attempt to restore the full-day UI snapshot from Isar.
  /// Returns true if a valid (< 2 hours old) snapshot was found and applied.
  /// Must be called AFTER controllers are initialized but BEFORE heavy hint boot.
  Future<bool> Claude_bulletTryRestoreFullDayUiSnapshot() async {
    try {
      final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final uid = UserContext.of(context, listen: false).currentUid;
      final uidDateKey = '$uid|$ymd';

      final isar = await IsarDb.instance;

      final snap = await isar.claudeBulletSnapshots
          .filter()
          .uidDateKeyEqualTo(uidDateKey)
          .findFirst();


      if (snap == null) {
        print('[Claude_bullet] No snapshot found for $ymd');
        return false;
      }

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final ageMs = nowMs - snap.lastEditedAt;
      const twoHoursMs = 2 * 60 * 60 * 1000;

      if (ageMs > twoHoursMs) {
        print('[Claude_bullet] Snapshot for $ymd is stale '
            '(age=${(ageMs / 60000).toStringAsFixed(1)} min) — skipping');
        return false;
      }

      final data = jsonDecode(snap.snapshotJson) as Map<String, dynamic>;
      final exercises = (data['exercises'] as List?) ?? [];

      if (exercises.isEmpty) {
        print('[Claude_bullet] Snapshot for $ymd has no exercises — skipping');
        return false;
      }

      // We need exercise rows + controllers to already be initialized.
      // If they're not, we can't restore yet.
      if (_selectedExercisesWithCircuits.isEmpty) {
        print('[Claude_bullet] No exercises loaded yet for $ymd — deferring');
        return false;
      }

      // Clear overrides from any previous restore
      _claudeBulletWeightHintOverrides.clear();
      _claudeBulletRepsHintOverrides.clear();
      _claudeBulletRirHintOverrides.clear();

      int restoredExercises = 0;
      String s1Summary = '';

      for (final exData in exercises) {
        final instanceKey = exData['instanceKey'] as String? ?? '';
        final sets = (exData['sets'] as List?) ?? [];

        // Find the matching row index in the current exercise list
        int? rowIdx;
        for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
          final exMap = _selectedExercisesWithCircuits[i];
          final exId = (exMap['exerciseId'] ?? exMap['id'] ?? exMap['exerciseID'] ?? '').toString();
          final ci = exMap['circuitIndex'] ?? 0;
          final currentKey = '$exId|$ci';
          if (currentKey == instanceKey) {
            rowIdx = i;
            break;
          }
        }

        if (rowIdx == null) continue;
        restoredExercises++;

        for (final setData in sets) {
          final j = (setData['setIdx'] as int?) ?? 0;
          final w = setData['weight'] as Map<String, dynamic>? ?? {};
          final r = setData['reps'] as Map<String, dynamic>? ?? {};
          final rir = setData['rir'] as Map<String, dynamic>? ?? {};
          final vel = setData['velocity'] as Map<String, dynamic>? ?? {};
          final notes = setData['notes'] as Map<String, dynamic>? ?? {};

          // ── Restore weight controller ──
          if (rowIdx < _weightControllers.length && j < _weightControllers[rowIdx].length) {
            if (w['origin'] == 'typed') {
              _weightControllers[rowIdx][j].text = w['display'] ?? '';
            } else {
              _weightControllers[rowIdx][j].text = '';
            }
          }
          // Weight hint override
          if (w['origin'] == 'hint' && (w['display'] ?? '').toString().isNotEmpty) {
            _claudeBulletWeightHintOverrides
                .putIfAbsent(instanceKey, () => {})
                [j] = w['display'].toString();
          }

          // ── Restore reps controller ──
          if (rowIdx < _repsControllers.length && j < _repsControllers[rowIdx].length) {
            if (r['origin'] == 'typed') {
              _repsControllers[rowIdx][j].text = r['display'] ?? '';
            } else {
              _repsControllers[rowIdx][j].text = '';
            }
          }
          // Reps hint override
          if (r['origin'] == 'hint' && (r['display'] ?? '').toString().isNotEmpty) {
            _claudeBulletRepsHintOverrides
                .putIfAbsent(instanceKey, () => {})
                [j] = r['display'].toString();
          }

          // ── Restore RIR controller ──
          if (rowIdx < _rirControllers.length && j < _rirControllers[rowIdx].length) {
            if (rir['origin'] == 'typed') {
              _rirControllers[rowIdx][j].text = rir['display'] ?? '';
            } else {
              _rirControllers[rowIdx][j].text = '';
            }
          }
          // RIR hint override
          if (rir['origin'] == 'hint' && (rir['display'] ?? '').toString().isNotEmpty) {
            _claudeBulletRirHintOverrides
                .putIfAbsent(instanceKey, () => {})
                [j] = rir['display'].toString();
          }

          // ── Restore velocity controller ──
          if (rowIdx < _velocityControllers.length && j < _velocityControllers[rowIdx].length) {
            if (vel['origin'] == 'typed') {
              _velocityControllers[rowIdx][j].text = vel['display'] ?? '';
            } else {
              _velocityControllers[rowIdx][j].text = '';
            }
          }

          // ── Restore notes controller ──
          if (rowIdx < _notesControllers.length && j < _notesControllers[rowIdx].length) {
            if (notes['origin'] == 'typed') {
              _notesControllers[rowIdx][j].text = notes['display'] ?? '';
            } else {
              _notesControllers[rowIdx][j].text = '';
            }
          }

          // Log first exercise set1
          if (restoredExercises == 1 && j == 0) {
            s1Summary = ' set1: w=${w['origin']}:${w['display']}'
                ' r=${r['origin']}:${r['display']}'
                ' rir=${rir['origin']}:${rir['display']}';
          }
        }

        // ── Seed set1 numeric cache ──
        final s1WNum = (exData['set1_weight_num'] as num?)?.toDouble();
        final s1RNum = (exData['set1_reps_num'] as num?)?.toDouble();
        final s1RirNum = (exData['set1_rir_num'] as num?)?.toDouble();
        final s1WTyped = exData['set1_weight_typed'] == true;
        final s1RTyped = exData['set1_reps_typed'] == true;
        final s1RirTyped = exData['set1_rir_typed'] == true;

        // Populate _seedHintsByKey for set1 so existing set1SuggestedWeight/Reps
        // functions work instantly without running async computation.
        // Only seed if the field was a hint (not typed) so we don't interfere
        // with typed values.
        final hintKey = _rowKeyBy(rowIdx);
        final existingSeed = _seedHintsByKey[hintKey] ?? {};

        if (!s1WTyped && s1WNum != null) {
          // Check if BW exercise to use correct key
          final exName = (exData['name'] ?? '').toString().trim();
          final isBw = PeriodizationModelUtils.isBodyweightExercise(name: exName);
          if (isBw) {
            existingSeed['s1_weight_added'] = s1WNum;
          } else {
            existingSeed['s1_weight'] = s1WNum;
          }
        }
        if (!s1RTyped && s1RNum != null) {
          existingSeed['s1_reps'] = s1RNum;
        }
        if (!s1RirTyped && s1RirNum != null) {
          existingSeed['s1_rir'] = s1RirNum;
          existingSeed['rir'] = s1RirNum;
        }

        if (existingSeed.isNotEmpty) {
          _seedHintsByKey[hintKey] = existingSeed;
        }
      }

      _claudeBulletActiveForThisDay = true;

      print('[Claude_bullet] RESTORED snapshot for $ymd '
          'age=${(ageMs / 60000).toStringAsFixed(1)}min '
          'exercises=$restoredExercises$s1Summary');

      return restoredExercises > 0;
    } catch (e, st) {
      print('[Claude_bullet] RESTORE ERROR: $e');
      print(st);
      return false;
    }
  }

  /// Schedule a debounced Claude_bullet save (400ms).
  void Claude_bulletScheduleDebouncedSave() {
    _claudeBulletSaveDebounce?.cancel();
    _claudeBulletSaveDebounce = Timer(
      const Duration(milliseconds: 400),
      () => Claude_bulletSaveFullDayUiSnapshot(reason: 'edit_debounce'),
    );
  }

  /// ═══════════════════════════════════════════════════════════════════════════
  /// Claude_bullet Phase 0: Claude-first fast paint
  /// ═══════════════════════════════════════════════════════════════════════════
  ///
  /// Runs on WES open BEFORE _paintFromSnapshotIfAny(). Reads Claude snapshot
  /// from Isar directly (no Warmup dependency) and paints the full UI if valid.
  /// Returns true if it painted successfully; false otherwise (no state mutated).
  Future<bool> Claude_bulletPhase0FastPaintIfRecent() async {
    try {
      final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final uid = _cachedUid ?? UserContext.of(context, listen: false).currentUid;
      if (uid == null || uid.isEmpty) {
        print('[Claude_bullet Phase0] No uid — skipping');
        return false;
      }
      final uidDateKey = '$uid|$ymd';

      final isar = await IsarDb.instance;

      final snap = await isar.claudeBulletSnapshots
          .filter()
          .uidDateKeyEqualTo(uidDateKey)
          .findFirst();

      if (snap == null) {
        print('[Claude_bullet Phase0] No snapshot for $ymd — skipping');
        return false;
      }

      // Check age: must be < 2 hours
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final ageMs = nowMs - snap.lastEditedAt;
      const twoHoursMs = 2 * 60 * 60 * 1000;

      if (ageMs > twoHoursMs) {
        print('[Claude_bullet Phase0] Snapshot for $ymd is stale '
            '(age=${(ageMs / 60000).toStringAsFixed(1)} min) — skipping');
        return false;
      }

      final data = jsonDecode(snap.snapshotJson) as Map<String, dynamic>;
      final exercises = (data['exercises'] as List?) ?? [];

      if (exercises.isEmpty) {
        print('[Claude_bullet Phase0] Snapshot for $ymd has no exercises — skipping');
        return false;
      }

      // ── Build exercise rows directly from snapshot (preserve order, no de-dupe) ──
      final List<Map<String, dynamic>> tmpRows = [];
      for (final exData in exercises) {
        final exId = (exData['exerciseId'] ?? '').toString();
        final exName = (exData['name'] ?? '').toString().trim();
        final ci = (exData['circuitIndex'] is int)
            ? exData['circuitIndex'] as int
            : int.tryParse('${exData['circuitIndex'] ?? 0}') ?? 0;

        if (exName.isEmpty) continue;

        tmpRows.add({
          'name': exName,
          'exerciseId': exId,
          'circuitIndex': ci,
          'cardId': '$ymd|phase0|${tmpRows.length}|$exId',
        });
      }

      if (tmpRows.isEmpty) {
        print('[Claude_bullet Phase0] Built 0 rows — skipping');
        return false;
      }

      // ── Build controllers from snapshot set counts ──
      final List<List<SetDetails>> tmpSets = [];
      final List<List<TextEditingController>> tmpReps = [];
      final List<List<TextEditingController>> tmpWts = [];
      final List<List<TextEditingController>> tmpRir = [];
      final List<List<TextEditingController>> tmpVel = [];
      final List<List<TextEditingController>> tmpNotes = [];

      // Clear override maps before populating
      _claudeBulletWeightHintOverrides.clear();
      _claudeBulletRepsHintOverrides.clear();
      _claudeBulletRirHintOverrides.clear();
      _seedHintsByKey.clear();

      String s1Summary = '';
      int restoredExercises = 0;

      for (int i = 0; i < tmpRows.length; i++) {
        final exData = exercises[i] as Map<String, dynamic>;
        final sets = (exData['sets'] as List?) ?? [];
        final setCount = sets.length > 0 ? sets.length : _defaultSets;

        final exId = (exData['exerciseId'] ?? '').toString();
        final ci = (exData['circuitIndex'] ?? 0);
        final instanceKey = '$exId|$ci';
        final exName = (exData['name'] ?? '').toString().trim();

        // Initialize controllers for this exercise
        tmpSets.add(List.generate(setCount, (_) => SetDetails()));
        tmpReps.add(List.generate(setCount, (_) => TextEditingController()));
        tmpWts.add(List.generate(setCount, (_) => TextEditingController()));
        tmpRir.add(List.generate(setCount, (_) => TextEditingController()));
        tmpVel.add(List.generate(setCount, (_) => TextEditingController()));
        tmpNotes.add(List.generate(setCount, (_) => TextEditingController()));

        // Restore each set from snapshot
        for (final setData in sets) {
          final j = (setData['setIdx'] as int?) ?? 0;
          if (j >= setCount) continue;

          final w = setData['weight'] as Map<String, dynamic>? ?? {};
          final r = setData['reps'] as Map<String, dynamic>? ?? {};
          final rir = setData['rir'] as Map<String, dynamic>? ?? {};
          final vel = setData['velocity'] as Map<String, dynamic>? ?? {};
          final notes = setData['notes'] as Map<String, dynamic>? ?? {};

          // ── Restore weight ──
          if (w['origin'] == 'typed') {
            tmpWts[i][j].text = w['display'] ?? '';
          } else if (w['origin'] == 'hint' && (w['display'] ?? '').toString().isNotEmpty) {
            // Keep controller empty, store hint override
            _claudeBulletWeightHintOverrides
                .putIfAbsent(instanceKey, () => {})
                [j] = w['display'].toString();
          }

          // ── Restore reps ──
          if (r['origin'] == 'typed') {
            tmpReps[i][j].text = r['display'] ?? '';
          } else if (r['origin'] == 'hint' && (r['display'] ?? '').toString().isNotEmpty) {
            _claudeBulletRepsHintOverrides
                .putIfAbsent(instanceKey, () => {})
                [j] = r['display'].toString();
          }

          // ── Restore RIR ──
          if (rir['origin'] == 'typed') {
            tmpRir[i][j].text = rir['display'] ?? '';
          } else if (rir['origin'] == 'hint' && (rir['display'] ?? '').toString().isNotEmpty) {
            _claudeBulletRirHintOverrides
                .putIfAbsent(instanceKey, () => {})
                [j] = rir['display'].toString();
          }

          // ── Restore velocity (typed only) ──
          if (vel['origin'] == 'typed') {
            tmpVel[i][j].text = vel['display'] ?? '';
          }

          // ── Restore notes (typed only) ──
          if (notes['origin'] == 'typed') {
            tmpNotes[i][j].text = notes['display'] ?? '';
          }

          // Log first exercise set1
          if (restoredExercises == 0 && j == 0) {
            s1Summary = ' set1: w=${w['origin']}:${w['display']}'
                ' r=${r['origin']}:${r['display']}'
                ' rir=${rir['origin']}:${rir['display']}';
          }
        }

        // ── Seed set1 numeric cache for instant hint rendering ──
        final s1WNum = (exData['set1_weight_num'] as num?)?.toDouble();
        final s1RNum = (exData['set1_reps_num'] as num?)?.toDouble();
        final s1RirNum = (exData['set1_rir_num'] as num?)?.toDouble();
        final s1WTyped = exData['set1_weight_typed'] == true;
        final s1RTyped = exData['set1_reps_typed'] == true;
        final s1RirTyped = exData['set1_rir_typed'] == true;

        final hintKey = instanceKey;
        final Map<String, dynamic> seedEntry = {};

        if (!s1WTyped && s1WNum != null) {
          final isBw = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: exName);
          if (isBw) {
            seedEntry['s1_weight_added'] = s1WNum;
          } else {
            seedEntry['s1_weight'] = s1WNum;
          }
        }
        if (!s1RTyped && s1RNum != null) {
          seedEntry['s1_reps'] = s1RNum;
        }
        if (!s1RirTyped && s1RirNum != null) {
          seedEntry['s1_rir'] = s1RirNum;
          seedEntry['rir'] = s1RirNum;
        }

        if (seedEntry.isNotEmpty) {
          _seedHintsByKey[hintKey] = seedEntry;
        }

        restoredExercises++;
      }

      // ── Commit state in single setState ──
      setState(() {
        _selectedExercisesWithCircuits
          ..clear()
          ..addAll(tmpRows);

        _workoutSets
          ..clear()
          ..addAll(tmpSets);
        _repsControllers
          ..clear()
          ..addAll(tmpReps);
        _weightControllers
          ..clear()
          ..addAll(tmpWts);
        _rirControllers
          ..clear()
          ..addAll(tmpRir);
        _velocityControllers
          ..clear()
          ..addAll(tmpVel);
        _notesControllers
          ..clear()
          ..addAll(tmpNotes);

        _didFastPaint = true;
        _isInitialized = true;
        _isLoadingData = false;
        _claudeBulletActiveForThisDay = true;
        _claudeBulletPhase0Active = true;  // Tripwire: Phase 0 succeeded
        _bootPaintDone = true;  // Claim the boot paint slot
      });

      print('[Claude_bullet Phase0] SUCCESS for $ymd '
          'age=${(ageMs / 60000).toStringAsFixed(1)}min '
          'exercises=$restoredExercises$s1Summary');

      return true;
    } catch (e, st) {
      print('[Claude_bullet Phase0] ERROR: $e');
      print(st);
      return false;
    }
  }


  Map<String, dynamic> _getProgressedValues(int exerciseIndex) {
    // ✅ New stable cache key: exerciseId|circuitIndex (keeps function signature unchanged)
    final exName =
    (_selectedExercisesWithCircuits[exerciseIndex]['name']?.toString() ?? '').trim();
    final exId =
    (PeriodizationModelUtils.nameToId[exName] ?? exName).toString().trim();
    final ci =
    (_selectedExercisesWithCircuits[exerciseIndex]['circuitIndex'] is num)
        ? (_selectedExercisesWithCircuits[exerciseIndex]['circuitIndex'] as num).toInt()
        : int.tryParse((_selectedExercisesWithCircuits[exerciseIndex]['circuitIndex'] ?? '0').toString()) ?? 0;

    final String instanceKey = '$exId|$ci';

    // 🧠 STEP 1: If we already cached a GOOD value, return it
    final cached = _cachedProgressedValues[instanceKey];
    if (cached != null && blockStartDate != null && blockEndDate != null) {
      return cached;
    }

    // 🔹 NEW: if we have seeded hints WITH ACTUAL VALUES, use them for the very first paint
    // (Keep seed hints row-keyed for now to avoid breaking other call sites.)
    final seedKey = _rowKeyBy(exerciseIndex);
    final seed = _seedHintsByKey[seedKey];
    if (seed != null) {
      final isBw = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: exName);

      // Prefer absolute if present; otherwise, for BW convert added→absolute; else use added as-is.
      double? absW = (seed['s1_weight'] as num?)?.toDouble();
      final double? addedW = (seed['s1_weight_added'] as num?)?.toDouble();
      if (absW == null && addedW != null) {
        absW = isBw
            ? PeriodizationModelUtils.toAbsoluteWeight(
          uid: _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '',
          displayAddedKg: addedW,
          exerciseId: exId,
          exerciseName: exName,
          asOfDate: _selectedDate,
        )
            : addedW; // non-BW hints sometimes only provide one field
      }

      final double? seedReps = (seed['s1_reps'] as num?)?.toDouble();

      // 🔧 FIX: Only use seed if it has ACTUAL values; otherwise fall through to full model calc
      if (absW != null && seedReps != null) {
        final seeded = <String, dynamic>{
          'exerciseName': exName,
          'exerciseId': exId,
          'weight': absW, // absolute kg for downstream math
          'reps': seedReps,
        };

        // ✅ Cache using the new stable key
        _cachedProgressedValues[instanceKey] = seeded;
        return seeded;
      }
    }


    // Avoid caching placeholders before core meta/history land
    if (blockStartDate == null || _selectedDate == null || PeriodizationModelUtils.savedWorkoutsList.isEmpty) {
      print('⏳ [WES] delaying progressed calc; meta/history not ready');
      final exerciseName = _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
      return {
        'exerciseName': exerciseName,
        'weight': 20.0,
        'reps': 10,
      };
    }

    _debugPrintBlockDates();
    // Get exercise info.
    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    final exerciseId =
        PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
    final uidForBw = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';

    final weekIndex = _getApplicableWeekIndex(exerciseId);

    // Determine how many times this exercise appeared before.
    int plannedCountBefore = 0;
    for (int i = 0; i < exerciseIndex; i++) {
      if (_selectedExercisesWithCircuits[i]['name'] == exerciseName) {
        plannedCountBefore++;
      }
    }

    // Get rep target.
    double repTarget;
    final model =
    PeriodizationModelUtils.exercisePeriodizationModels[exerciseId];

    if (model == PeriodizationModelType.dailyUndulatingExposure) {
      // (Assuming your existing model-specific logic is used here)
      final fullDetails = _exerciseSettings[exerciseId];
      final week1 = fullDetails?['repTargets']?['week1'];

      if (week1 is Map<String, dynamic>) {
        final sorted = week1.entries
            .where((e) => e.key.startsWith('instance'))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        if (sorted.isNotEmpty) {
          int completedBeforeTodayInBlock = 0;
          final matchedDates = <String>{};

          try {
            final base = DateTime(blockStartDate!.year, blockStartDate!.month,
                blockStartDate!.day);
            final todayStart = DateTime(
                _selectedDate!.year, _selectedDate!.month, _selectedDate!.day);

            String norm(String s) {
              var t = s.toLowerCase().trim();
              t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
              t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
              t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
              t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');
              t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
              return t;
            }

            final targetId = exerciseId;
            final targetNameNorm = norm(exerciseName);

            bool hasValidSet(dynamic setsRaw) {
              final sets = (setsRaw is List) ? setsRaw.cast<Map>() : const <
                  Map>[];
              return sets.any((s) {
                final w = (s['weight']?.toString() ?? '').trim();
                final r = (s['reps']?.toString() ?? '').trim();
                return w.isNotEmpty && r.isNotEmpty;
              });
            }

            for (final w in PeriodizationModelUtils.savedWorkoutsList) {
              final dateStr = (w['date'] ?? '').toString();
              final dt = DateTime.tryParse(dateStr);
              if (dt == null) continue;

              final dayOnly = DateTime(dt.year, dt.month, dt.day);
              if (dayOnly.isBefore(base) || !dayOnly.isBefore(todayStart))
                continue; // [base, today)

              final exs = w['exercises'];
              if (exs is! List) continue;

              final matched = exs.any((ex) {
                if (!hasValidSet(ex['sets'])) return false;

                final exId = (ex['exerciseId'] ?? ex['id'] ??
                    ex['exercise_id'] ?? '').toString();
                if (exId.isNotEmpty && exId == targetId) return true;

                final exName = (ex['name'] ?? ex['exercise'] ?? ex['title'] ??
                    '').toString();
                if (exName.isNotEmpty && norm(exName) == targetNameNorm)
                  return true;

                final mapped = (PeriodizationModelUtils.nameToId[exName] ?? '')
                    .toString();
                return mapped.isNotEmpty && mapped == targetId;
              });

              if (matched) {
                matchedDates.add(
                    dateStr.length >= 10 ? dateStr.substring(0, 10) : dateStr);
              }
            }

            completedBeforeTodayInBlock = matchedDates.length;
          } catch (e) {          }

          // AFTER you finish building `matchedDates` (and before plannedIndex/index):
          final countedDebug = <Map<String, String>>[];

// Re-scan only the matched dates to grab a representative set per day
          for (final w in PeriodizationModelUtils.savedWorkoutsList) {
            final dateStr = (w['date'] ?? '').toString();
            final key = dateStr.length >= 10
                ? dateStr.substring(0, 10)
                : dateStr;
            if (!matchedDates.contains(key)) continue;

            final exs = w['exercises'];
            if (exs is! List) continue;

            String? weightTxt, repsTxt, rirTxt;

            for (final ex in exs) {
              // ID-first match (fallback to name→id only if no id on row)
              final exId = (ex['exerciseId'] ?? ex['id'] ?? ex['exercise_id'] ??
                  '').toString().trim();
              final exName = (ex['name'] ?? ex['exercise'] ?? ex['title'] ?? '')
                  .toString()
                  .trim();
              final idMatches = exId.isNotEmpty ? (exId == exerciseId) : false;
              final nameMatches = (exId.isEmpty)
                  ? ((PeriodizationModelUtils.nameToId[exName] ?? '')
                  .toString()
                  .trim() == exerciseId)
                  : false;
              if (!(idMatches || nameMatches)) continue;

              final sets = (ex['sets'] is List) ? List<
                  Map<String, dynamic>>.from(ex['sets']) : const <
                  Map<String, dynamic>>[];

              // Pick the first set that looks numeric
              for (final s in sets) {
                final wTxt = (s['actualWeight'] ?? s['weight'] ?? '')
                    .toString()
                    .trim();
                final rTxt = (s['actualReps'] ?? s['reps'] ?? '')
                    .toString()
                    .trim();
                final rir = (s['actualRir'] ?? s['rir'] ?? '')
                    .toString()
                    .trim();

                final looksNumber = double.tryParse(wTxt) != null &&
                    int.tryParse(rTxt) != null;
                if (looksNumber) {
                  weightTxt = wTxt;
                  repsTxt = rTxt;
                  rirTxt = rir.isEmpty ? null : rir;
                  break;
                }
              }

              if (weightTxt != null || repsTxt != null) break;
            }

            countedDebug.add({
              'date': key,
              'weight': weightTxt ?? '—',
              'reps': repsTxt ?? '—',
              'rir': rirTxt ?? '—',
            });
          }

// Sort by date (ascending) so the cycle order is obvious
          countedDebug.sort((a, b) => a['date']!.compareTo(b['date']!));

// Now compute plannedIndex / index as before
          final plannedIndex = completedBeforeTodayInBlock + plannedCountBefore;
          final index = sorted.isEmpty ? 0 : plannedIndex % sorted.length;

          final raw = sorted.isNotEmpty ? (sorted[index].value?.toString() ??
              '') : '';
          final match = RegExp(r'^(\d+)').firstMatch(raw);
          repTarget = match != null
              ? int.tryParse(match.group(1)!)?.toDouble() ?? 10.0
              : 10.0;
        } else {
          repTarget = 10.0;
        }
      } else {
        repTarget = PeriodizationModelUtils.getSuggestedRepTargetByModel(
          exerciseName: exerciseId,
          plannedIndex: plannedCountBefore,
          weightText: _weightControllers[exerciseIndex][0].text,
          rirText: _rirControllers[exerciseIndex][0].text,
          weekIndex: weekIndex,
        ).toDouble();
      }
    } else if (model == PeriodizationModelType.dailyUndulatingWeek) {
      // 🔁 DUP Weekly: reuse week1's instance list every week
      final weekMap = _exerciseSettings[exerciseId]?['repTargets']?['week1'];

      if (weekMap is Map<String, dynamic>) {
        final sorted = weekMap.entries
            .where((e) => e.key.startsWith('instance'))
            .toList()
          ..sort((a, b) =>
              a.key.compareTo(b.key)); // keep your existing ordering

        if (sorted.isNotEmpty) {
          if (blockStartDate == null || _selectedDate == null) {
            repTarget = 10.0;
          } else {
            // ✅ Count only *actual* completions earlier this week (strictly before today)
            int completedEarlierThisWeek = 0;
            final matchedDates = <String>{};

            try {
              final base = DateTime(blockStartDate!.year, blockStartDate!.month,
                  blockStartDate!.day);
              final wkIdx = weekIndex ?? 0;
              final weekStart = base.add(Duration(days: wkIdx * 7));
              final todayStart = DateTime(
                  _selectedDate!.year, _selectedDate!.month,
                  _selectedDate!.day);

              String norm(String s) {
                var t = s.toLowerCase().trim();
                t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
                t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
                t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
                t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');
                t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
                return t;
              }

              final targetId = exerciseId;
              final targetNameNorm = norm(exerciseName);

              bool hasValidSet(dynamic setsRaw) {
                final sets = (setsRaw is List) ? setsRaw.cast<Map>() : const <
                    Map>[];
                return sets.any((s) {
                  final w = (s['weight']?.toString() ?? '').trim();
                  final r = (s['reps']?.toString() ?? '').trim();
                  return w.isNotEmpty && r.isNotEmpty;
                });
              }

              for (final w in PeriodizationModelUtils.savedWorkoutsList) {
                final dateStr = (w['date'] ?? '').toString();
                final dt = DateTime.tryParse(dateStr);
                if (dt == null) continue;

                final dayOnly = DateTime(dt.year, dt.month, dt.day);
                if (dayOnly.isBefore(weekStart) ||
                    !dayOnly.isBefore(todayStart))
                  continue; // strictly before today

                final exs = w['exercises'];
                if (exs is! List) continue;

                final matched = exs.any((ex) {
                  if (!hasValidSet(ex['sets'])) return false;

                  final exId = (ex['exerciseId'] ?? ex['id'] ??
                      ex['exercise_id'] ?? '').toString();
                  if (exId.isNotEmpty && exId == targetId) return true;

                  final exName = (ex['name'] ?? ex['exercise'] ?? ex['title'] ??
                      '').toString();
                  if (exName.isNotEmpty && norm(exName) == targetNameNorm)
                    return true;

                  final mapped = (PeriodizationModelUtils.nameToId[exName] ??
                      '').toString();
                  return mapped.isNotEmpty && mapped == targetId;
                });

                if (matched) {
                  matchedDates.add(dateStr.length >= 10
                      ? dateStr.substring(0, 10)
                      : dateStr);
                }
              }

              completedEarlierThisWeek = matchedDates.length;
            } catch (e) {

            }

            // 🔑 WES rule: planned rows don't affect DUP Weekly indexing
            final plannedIndex = completedEarlierThisWeek;
            final index = plannedIndex % sorted.length;

            final raw = sorted[index].value?.toString() ?? '';
            final match = RegExp(r'^(\d+)').firstMatch(raw);
            repTarget = match != null
                ? (int.tryParse(match.group(1)!)?.toDouble() ?? 10.0)
                : 10.0;
          }
        } else {
          repTarget = 10.0;
        }
      } else {
        repTarget = 10.0;
      }

    } else if (model == PeriodizationModelType.linearClassic) {
      final repTargets = _exerciseSettings[exerciseId]?['repTargets'];


      final weekStart = repTargets?['week1'];
      final week = PeriodizationModelUtils.getWeekIndexForDate(
        _selectedDate,
        blockStartDate!,
      );

      final blockLength = PeriodizationModelUtils.getBlockLength(
        blockStartDate: blockStartDate!,
        blockEndDate: blockEndDate!,
      );
      if (weekStart is Map<String, dynamic>) {
        final instanceCount =
        PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
          exerciseName: exerciseName,
          savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
          blockStartDate: blockStartDate!,
          weekIndex: week,
        );
        final sortedKeys = weekStart.keys
            .where((k) => k.startsWith('instance'))
            .toList()
          ..sort();
        if (sortedKeys.isNotEmpty) {
          final instanceKey = sortedKeys[instanceCount % sortedKeys.length];
          final startRaw = weekStart[instanceKey]?.toString() ?? '10 x 3';
          final startMatch = RegExp(r'^(\d+)').firstMatch(startRaw);
          final startReps = startMatch != null
              ? int.tryParse(startMatch.group(1)!) ?? 10
              : 10;
          const endReps = 1;
          repTarget =
              (startReps + ((endReps - startReps) * (week / (blockLength - 1))))
                  .roundToDouble();
        } else {
          repTarget = 10.0;
        }
      } else {
        repTarget = 10.0;
      }
    } else {
      repTarget = PeriodizationModelUtils.getSuggestedRepTargetByModel(
        exerciseName: exerciseId,
        plannedIndex: plannedCountBefore,
        weightText: _weightControllers[exerciseIndex][0].text,
        rirText: _rirControllers[exerciseIndex][0].text,
        weekIndex: weekIndex,
      ).toDouble();
    }

    // Get the progression model info.
    final String? progressionModelName = _exerciseSettings[exerciseId]?['progressionModel'];

    final progressionModel =
    PeriodizationModelUtils.parseProgressionModel(progressionModelName);
    final double rir = getRirFromPlanOrInput(exerciseIndex, 1);

    final double defaultWeight =
    PeriodizationModelUtils.getSuggestedWeightFromRep(
      exerciseName,
      repTarget.toInt(),
      rir,
    );

    // Call the progression model (which contains its internal logic).
    final incRaw = _exerciseSettings[exerciseId]?['increments'];
    final incMap = PeriodizationModelUtils.incMapFromRaw(incRaw);
    final increments = PeriodizationModelUtils.expandIncrementOptions(incMap);

    final maxWeightMap = _exerciseSettings[exerciseId]?['maxWeightByReps'];
    final maxWeightKeys = (maxWeightMap is Map)
        ? maxWeightMap.keys.toList()
        : 'null';

    final Map<String, dynamic> progressed =
    PeriodizationModelUtils.getWeightByProgressionModel(
      model: progressionModel,
      exerciseName: exerciseName,
      repTarget: repTarget.toInt(),
      defaultWeight: defaultWeight,
      rirValue: rir,
      increments: increments ?? [2.5],
      // ✅ fallback
      maxWeightByReps: _exerciseSettings[exerciseId]?['maxWeightByReps'],
      debugOrigin: 'WES',

      topSetHistory: PeriodizationModelUtils.topSetsByExercise[exerciseName],
      weekIndex: (blockStartDate == null || _selectedDate == null)
          ? 0 // safe default until initialized
          : PeriodizationModelUtils.getWeekIndexForDate(
        _selectedDate, blockStartDate!,
      ),
    );

    // --- DEBUG: exact e1RM used by the model (if PMU exposes it) ---
    final debugE1 = progressed['__debug_e1rm'];
    if (debugE1 is num) {
      final wk = (blockStartDate == null || _selectedDate == null)
          ? 0
          : PeriodizationModelUtils.getWeekIndexForDate(_selectedDate!, blockStartDate!);
      print('🧪 [WES/e1RM] $exerciseName → e1RM=${debugE1.toStringAsFixed(2)} '
          '(repTarget=${repTarget.toInt()}, RIR=${rir.toStringAsFixed(2)}, wk=$wk)');
    } else {
      // Fallback: approximate from the returned working weight + current repTarget/RIR
      final w = (progressed['weight'] as num?)?.toDouble();
      if (w != null) {
        try {
          final approx = PeriodizationModelUtils.calculateE1RM(
            w,
            repTarget.toDouble(),
            rir,
          );
          print('🧪 [WES/e1RM≈] $exerciseName → approx=${approx.toStringAsFixed(2)} '
              '(repTarget=${repTarget.toInt()}, RIR=${rir.toStringAsFixed(2)})');
        } catch (_) {/* ignore */}
      }
    }


// as-of date for BW lookups = the day being edited in WES
    final DateTime _asOfDate = _selectedDate ?? DateTime.now();

    // 🔧 guard: LWI sometimes returns 'weight' as String; coerce once to double
    if (progressed['weight'] is String) {
      final _w = double.tryParse(progressed['weight'] as String);
      if (_w != null) progressed['weight'] = _w;
    }


    final target = (progressed['weight'] as num).toDouble();

// keep variable name `snapped` so nothing else downstream changes
    double snapped;

    final bool _isBwEx = PeriodizationModelUtils.isBodyweightExercise(
      id: exerciseId,
      name: exerciseName,
    );

    if (_isBwEx) {
      // convert ABS → ADDED
      final double _targetAdded = PeriodizationModelUtils.toDisplayAddedWeight(
        uid: uidForBw,
        absoluteKg: target,
        exerciseId: exerciseId,
        exerciseName: exerciseName,
        asOfDate: _asOfDate, // ⬅️ add this
      );

      // snap on ADDED (use your expanded increments)
      final List<double> _opts = (increments == null || increments.isEmpty)
          ? <double>[2.5]
          : increments;
      double _snappedAdded = _opts.reduce(
            (a, b) =>
        (a - _targetAdded).abs() < (b - _targetAdded).abs()
            ? a
            : b,
      );

      // cap min at 0 for display semantics
      if (_snappedAdded < 0) _snappedAdded = 0.0;

      // convert back to ABS for storage/math and assign to your usual `snapped`
      snapped = PeriodizationModelUtils.toAbsoluteWeight(
        uid: uidForBw,
        displayAddedKg: _snappedAdded,
        exerciseId: exerciseId,
        exerciseName: exerciseName,
      );

      // optional: expose display-only value for your hint UI (no impact to normal exercises)
      progressed['weightDisplayAdded'] = _snappedAdded;
    } else {
      // 🔁 NORMAL EXERCISES: unchanged behavior and names
      snapped = increments.reduce(
            (a, b) => (a - target).abs() < (b - target).abs() ? a : b,
      );
      // for non-BW, display == absolute (this key is optional; omit if you prefer)
      progressed['weightDisplayAdded'] = snapped;
    }

// write back absolute weight as before
    progressed['weight'] = snapped;


    // Cache and return
// Cache and return
    progressed['exerciseName'] = exerciseName;
    progressed['exerciseId'] = exerciseId;
    final canCache = (blockStartDate != null) && (_selectedDate != null) && (PeriodizationModelUtils.savedWorkoutsList.isNotEmpty);
    if (canCache) {
      _cachedProgressedValues[_rowCacheKey(exerciseIndex)] = progressed;
    }



    print(
        '🧮 [WES] Progressed for ${exerciseName} = ${progressed['weight']} kg @ ${repTarget} reps, RIR $rir');
    print('✅ [WES/out] ${exerciseName} → ${progressed['weight']} × ${progressed['reps']} (rir=${rir})');

    return progressed;
  }

  //Determine hint texts for this workout:NEW METHOD

  double set1SuggestedReps(int exerciseIndex) {
    // FAST-PATH: use precomputed hint if available
    final hintK = _rowKeyBy(exerciseIndex);

    // ⛳ Touch-state: use seed hint only when ALL set-1 fields are still empty.
    // If the user typed ANY value (weight, reps, or RIR), fall through to
    // E1RM derivation so reactive coupling works the same as on fresh workouts.
    final bool hasUserReps   = _repsControllers[exerciseIndex][0].text.trim().isNotEmpty;
    final bool hasUserWeight = _weightControllers[exerciseIndex][0].text.trim().isNotEmpty;
    final bool hasUserRir    = _rirControllers[exerciseIndex][0].text.trim().isNotEmpty;

    final num? hr = _seedHintsByKey[hintK]?['s1_reps'] as num?;
    if (hr != null && !hasUserReps && !hasUserWeight && !hasUserRir) {
      // [perf] print removed from hot path
      return hr.toDouble();
    } else if (hr != null) {
      // [perf] print removed from hot path
    }


    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    final rirText = _rirControllers[exerciseIndex][0].text;
    final weightText = _weightControllers[exerciseIndex][0].text;
    final repsText = _repsControllers[exerciseIndex][0].text;

    final bb2LookupId = (() {
      final row = _selectedExercisesWithCircuits[exerciseIndex];
      final rId = (row['exerciseId'] ?? row['id'])?.toString().trim() ?? '';
      return (rId.isNotEmpty ? rId : (PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName)).toString().toLowerCase();
    })();
    final bb2Entry = _resolvedBB2Values[bb2LookupId];

    final double? reps = double.tryParse(repsText);
    final double? weight = double.tryParse(weightText);
    final double rawRIR = double.tryParse(rirText) ?? set1RIR(exerciseIndex);
    final double? bb2Reps = bb2Entry?['reps']?.toDouble();
    final double? bb2Weight = bb2Entry?['weight']?.toDouble();
    final dynamic bb2RirRaw = bb2Entry?['rir'];
    final double? bb2Rir = (bb2RirRaw is num && bb2RirRaw > 0)
        ? (bb2RirRaw as num).toDouble()
        : null;

    final double usedRIR = bb2Rir ?? rawRIR ?? 1.0;

    // 🔎 BW detection & context we need for conversions
    final bool isBwEx = PeriodizationModelUtils.isBodyweightExercise(
      name: exerciseName,
    );
    final String uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ??
        '';
    final DateTime? asOf = _selectedDate;

    // Compute baseline (unchanged)
    final progressed = _getProgressedValues(exerciseIndex);
    final double baseWeight = (progressed['weight'] ?? 20.0).toDouble();
    final double baseReps = (progressed['reps'] ?? 10).toDouble();
    final double baseE1RM = progressed['e1rm'] ??
        PeriodizationModelUtils.calculateE1RM(
          baseWeight,
          baseReps,
          usedRIR,
        );
    print(
        '🧠 [WES] Base E1RM used for $exerciseName = ${baseE1RM.toStringAsFixed(
            2)} '
            '(weight = ${baseWeight.toStringAsFixed(1)}, reps = ${baseReps
            .toStringAsFixed(1)}, RIR = $usedRIR)');

    // Prioritization (unchanged for reps)

    final bool hasBB2Reps = bb2Reps != null && bb2Reps > 0;

    // CASE 1: Reps already entered by user → use it
    if (hasUserReps) return reps!;

    // CASE 2: BB2-entered reps → use them
    if (hasBB2Reps) {

      return bb2Reps!;
    }

    // CASE 3: Weight (from user or BB2) → derive reps
    if (!isBwEx) {
      // ✅ NORMAL EXERCISES: unchanged behavior
      final double? usedWeight =
          weight ?? (bb2Weight != null && bb2Weight > 0 ? bb2Weight : null);

      if (usedWeight != null) {
        final derivedReps = PeriodizationModelUtils.reverseCalculateReps(
          targetE1RM: baseE1RM,
          weight: usedWeight,
          baseWeight: baseWeight,
          rir: usedRIR,
          minReps: baseReps,
        );
        final double roundedReps = derivedReps % 1 >= 0.85
            ? derivedReps.ceilToDouble()
            : derivedReps.floorToDouble();
        print(
            '🔁 [WES] Using weight = $usedWeight & RIR = $usedRIR → derived reps = $derivedReps → rounded = $roundedReps (target E1RM = ${baseE1RM
                .toStringAsFixed(2)})');
        return roundedReps;
      }

      // No override → model default
      return baseReps;
    } else {
      // ✅ BODYWEIGHT EXERCISES: treat "weight" as ADDED kg (display domain)
      // Priority: user field (added) → bb2.addedWeight → convert bb2.absolute → added
      final double? bb2Added =
      (bb2Entry?['addedWeight'] as num?)?.toDouble();

      double? usedAddedKg;
      if (weight != null) {
        // WES field for BW shows ADDED kg
        usedAddedKg = weight;
      } else if (bb2Added != null && bb2Added > 0) {
        usedAddedKg = bb2Added;
      } else if (bb2Weight != null && bb2Weight > 0) {
        // Convert ABS → ADDED so we don't add BW twice
        usedAddedKg = PeriodizationModelUtils.toDisplayAddedWeight(
          uid: uid,
          absoluteKg: bb2Weight,
          exerciseName: exerciseName,
          asOfDate: asOf,
        );
      } else {
        usedAddedKg = null;
      }

      if (usedAddedKg != null) {
        // Convert ADDED → ABS exactly once for the math
        final double effectiveWeight = PeriodizationModelUtils.toAbsoluteWeight(
          uid: uid,
          displayAddedKg: usedAddedKg,
          exerciseName: exerciseName,
          asOfDate: asOf,
        );

        final double bwUsed =
        PeriodizationModelUtils.bodyweightKgForDate(uid: uid, asOf: asOf);

        final derivedReps = PeriodizationModelUtils.reverseCalculateReps(
          targetE1RM: baseE1RM,
          weight: effectiveWeight,
          baseWeight: baseWeight,
          rir: usedRIR,
          minReps: baseReps,
        );

        final double roundedReps = derivedReps % 1 >= 0.85
            ? derivedReps.ceilToDouble()
            : derivedReps.floorToDouble();

        print(
            '🧰 [WES BW] displayAdded=$usedAddedKg, bwUsed=$bwUsed → effectiveAbs=$effectiveWeight');
        print('🔁 [WES] Using weight(added) = $usedAddedKg & RIR = $usedRIR '
            '→ derived reps = $derivedReps → rounded = $roundedReps (target E1RM = ${baseE1RM
            .toStringAsFixed(2)})');

        return roundedReps;
      }

      // No override → model default
      return baseReps;
    }
  }


  double set2SuggestedReps(int exerciseIndex) {
    // Delegate to the unified resolver (setIdx = 1 for Set 2)
    return suggestedRepsForSet(exerciseIndex, 1);
  }


  double set3SuggestedReps(int exerciseIndex) {
    // Delegate to the unified resolver (setIdx = 2 for Set 3)
    return suggestedRepsForSet(exerciseIndex, 2);
  }

  // ─────────────────────────────────────────────────────────────────────────────
// Generic, synchronous suggestions for ANY set index (0-based: 0=Set1).
// Weight returns display kg for BW (added weight), absolute kg otherwise.
// Reps returns a double (your code expects double).
// ─────────────────────────────────────────────────────────────────────────────

  double suggestedWeightForSet(int exIdx, int setIdx) {
    // Set 1 and Set 2 keep your existing functions
    if (setIdx == 0) return set1SuggestedWeight(exIdx);


    // From Set 3 onward: same behavior as your new Set 3 (chained off previous set)
    final exerciseName = (_selectedExercisesWithCircuits[exIdx]['name'] as String?)
        ?.trim() ?? '';
    final category = (_selectedExercisesWithCircuits[exIdx]['category'] as String?)
        ?.trim()
        .toLowerCase() ?? '';
    final isBw = PeriodizationModelUtils.isBodyweightExercise(
        name: exerciseName);
    final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';

    String _groupFor(String name, String cat) {
      final n = name.trim().toLowerCase();
      const groupA = {
        'chin-up',
        'bench press, barbell',
        'bench press, narrow grip',
        'bench press, larsen press',
        'bench press, long pause',
        'back squat, barbell',
        'back squat, low bar',
        'back squat, paused squat',
        'back squat, pin squat',
        'deadlift, conventional',
        'deadlift, deficit',
        'deadlift, sumo',
        'deadlift, sumo, deficit',
        'romanian deadlift',
      };
      if (groupA.contains(n)) return 'A';

      const groupB = {
        'overhead dumbbell press, unilateral',
        'overhead barbell press',
      };
      if (groupB.contains(n)) return 'B';

      const groupC = {
        'horizontal press',
        'horizontal pull',
        'vertical press',
        'vertical pull',
        'squat pattern',
        'hip hinge',
      };
      const groupD = {
        'lateral raise',
        'arm extension',
        'arm curl',
        'leg extension',
        'leg curl',
        'hip abduction/adduction',
        'calf raise',
        'core',
      };
      if (groupC.contains(cat)) return 'C';
      if (groupD.contains(cat)) return 'D';
      return 'C';
    }

    // Raw per-set drop by group (setIdx is 0-based; Set 2→setIdx=1, Set 3→2, etc.)
    double _rawDropFor(String group, int idx) {
      // Only applies for setIdx >= 2 here
      switch (group) {
        case 'A':
          return 5.5; // every set 2+ is −5.5 kg
        case 'B':
          if (idx == 1) return 1.5; // Set 2
          if (idx == 2) return 4.3; // Set 3
          return 1.5; // Set 4+
        case 'C':
          return 1.0;
        case 'D':
          return 0.3;
        default:
          return 1.0;
      }
    }

    double _gatedDrop(double drop, double prevRir) {
      if (prevRir > 2.0) return 0.0;
      if (prevRir >= 1.8 && prevRir <= 2.0) return drop * 0.8;
      return drop;
    }

    double _toAbsFromDisplay(double displayKg) {
      if (!isBw) return displayKg;
      return PeriodizationModelUtils.toAbsoluteWeight(
        uid: uid,
        displayAddedKg: displayKg,
        exerciseName: exerciseName,
        asOfDate: _selectedDate,
      );
    }
    double _toDisplayFromAbs(double absKg) {
      if (!isBw) return absKg;
      return PeriodizationModelUtils.toDisplayAddedWeight(
        uid: uid,
        absoluteKg: absKg,
        exerciseName: exerciseName,
        asOfDate: _selectedDate,
      );
    }

    // If user already typed weight for this set, that wins
    final typedW = _weightControllers[exIdx][setIdx].text.trim();
    if (typedW.isNotEmpty) {
      final v = double.tryParse(typedW);
      if (v != null) return v;
    }

    // Previous set actual (typed wins; else our own suggestion)
    final prevIdx = setIdx - 1;

    final prevWDisplay = (_weightControllers[exIdx][prevIdx].text
        .trim()
        .isNotEmpty)
        ? (double.tryParse(_weightControllers[exIdx][prevIdx].text.trim()) ??
        suggestedWeightForSet(exIdx, prevIdx))
        : suggestedWeightForSet(exIdx, prevIdx);
    final prevWAbs = _toAbsFromDisplay(prevWDisplay);

    final prevReps = (_repsControllers[exIdx][prevIdx].text
        .trim()
        .isNotEmpty)
        ? (int.tryParse(_repsControllers[exIdx][prevIdx].text.trim()) ??
        suggestedRepsForSet(exIdx, prevIdx).toInt())
        : suggestedRepsForSet(exIdx, prevIdx).toInt();

    // RIR for previous set (typed if present; else plan)
    double _rirFor(int setZeroBased) {
      final t = _rirControllers[exIdx][setZeroBased].text.trim();
      if (t.isNotEmpty) {
        final p = double.tryParse(t);
        if (p != null) return p;
      }
      // getRirFromPlanOrInput expects 1-based set number
      return getRirFromPlanOrInput(exIdx, setZeroBased + 1);
    }
    final prevRir = _rirFor(prevIdx);

    // Previous set actual E1RM
    final prevE1RM = PeriodizationModelUtils.calculateE1RM(
      prevWAbs, prevReps.toDouble(), prevRir,
    );

    // Target drop for this set (group + gating on previous set RIR)
    final group = _groupFor(exerciseName, category);
    final rawDrop = _rawDropFor(group, setIdx);
    final drop = _gatedDrop(rawDrop, prevRir);
    final targetE1RM = (prevE1RM - drop).clamp(1.0, 9999.0);

    // Collapse rules:
    // If reps typed for *this* set → compute single weight
    final typedRepsText = _repsControllers[exIdx][setIdx].text.trim();
    final thisRir = _rirFor(setIdx);

    if (typedRepsText.isNotEmpty) {
      final repsI = int.tryParse(typedRepsText) ??
          suggestedRepsForSet(exIdx, setIdx).toInt();
      final wAbs = PeriodizationModelUtils.reverseCalculateWeight(
        targetE1RM: targetE1RM,
        reps: repsI,
        rir: thisRir,
      );
      if (isBw) {
        final displayGuess = _toDisplayFromAbs(wAbs);
        final roundedDisplay = PeriodizationModelUtils
            .roundToNearestValidIncrement(
          targetWeight: displayGuess,
          exerciseName: exerciseName,
        );
        return roundedDisplay;
      } else {
        final roundedAbs = PeriodizationModelUtils.roundToNearestValidIncrement(
          targetWeight: wAbs,
          exerciseName: exerciseName,
        );
        return roundedAbs;
      }
    }

    // Neither typed → use math-centered mid:
// center reps that hit target at a stable anchor (previous ABS weight)
    final int midRep = PeriodizationModelUtils
        .reverseCalculateReps(
      targetE1RM: targetE1RM,
      weight: prevWAbs,
      // anchor at previous set ABS weight
      baseWeight: prevWAbs,
      rir: thisRir,
      minReps: null,
    )
        .clamp(1.0, 45.0)
        .round();

    final midAbs = PeriodizationModelUtils.reverseCalculateWeight(
      targetE1RM: targetE1RM,
      reps: midRep,
      rir: thisRir,
    );

    if (isBw) {
      final displayGuess = _toDisplayFromAbs(midAbs);
      final roundedDisplay = PeriodizationModelUtils
          .roundToNearestValidIncrement(
        targetWeight: displayGuess,
        exerciseName: exerciseName,
      );
      return roundedDisplay;
    } else {
      final roundedAbs = PeriodizationModelUtils.roundToNearestValidIncrement(
        targetWeight: midAbs,
        exerciseName: exerciseName,
      );
      return roundedAbs;
    }
  }

  double suggestedRepsForSet(int exIdx, int setIdx) {
    // Set 1 and Set 2 keep your existing functions
    if (setIdx == 0) return set1SuggestedReps(exIdx);

    // From Set 3 onward: same behavior as your new Set 3 (chained off previous set)
    final exerciseName = (_selectedExercisesWithCircuits[exIdx]['name'] as String?)
        ?.trim() ?? '';
    final category = (_selectedExercisesWithCircuits[exIdx]['category'] as String?)
        ?.trim()
        .toLowerCase() ?? '';
    final isBw = PeriodizationModelUtils.isBodyweightExercise(
        name: exerciseName);
    final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';

    String _groupFor(String name, String cat) {
      final n = name.trim().toLowerCase();
      const groupA = {
        'chin-up',
        'bench press, barbell',
        'bench press, narrow grip',
        'bench press, larsen press',
        'bench press, long pause',
        'back squat, barbell',
        'back squat, low bar',
        'back squat, paused squat',
        'back squat, pin squat',
        'deadlift, conventional',
        'deadlift, deficit',
        'deadlift, sumo',
        'deadlift, sumo, deficit',
        'romanian deadlift',
      };
      if (groupA.contains(n)) return 'A';

      const groupB = {
        'overhead dumbbell press, unilateral',
        'overhead barbell press',
      };
      if (groupB.contains(n)) return 'B';

      const groupC = {
        'horizontal press',
        'horizontal pull',
        'vertical press',
        'vertical pull',
        'squat pattern',
        'hip hinge',
      };
      const groupD = {
        'lateral raise',
        'arm extension',
        'arm curl',
        'leg extension',
        'leg curl',
        'hip abduction/adduction',
        'calf raise',
        'core',
      };
      if (groupC.contains(cat)) return 'C';
      if (groupD.contains(cat)) return 'D';
      return 'C';
    }

    double _rawDropFor(String group, int idx) {
      switch (group) {
        case 'A':
          return 5.5;
        case 'B':
          if (idx == 1) return 1.5; // S2
          if (idx == 2) return 4.3; // S3
          return 1.5; // S4+
        case 'C':
          return 1.0;
        case 'D':
          return 0.3;
        default:
          return 1.0;
      }
    }

    double _gatedDrop(double drop, double prevRir) {
      if (prevRir > 2.0) return 0.0;
      if (prevRir >= 1.8 && prevRir <= 2.0) return drop * 0.8;
      return drop;
    }

    double _toAbsFromDisplay(double displayKg) {
      if (!isBw) return displayKg;
      return PeriodizationModelUtils.toAbsoluteWeight(
        uid: uid,
        displayAddedKg: displayKg,
        exerciseName: exerciseName,
        asOfDate: _selectedDate,
      );
    }

    // If reps typed for this set, that wins
    final typedReps = _repsControllers[exIdx][setIdx].text.trim();
    if (typedReps.isNotEmpty) {
      final v = double.tryParse(typedReps);
      if (v != null && v > 0) return v;
    }

    // Previous set actual
    final prevIdx = setIdx - 1;

    final prevWDisplay = (_weightControllers[exIdx][prevIdx].text
        .trim()
        .isNotEmpty)
        ? (double.tryParse(_weightControllers[exIdx][prevIdx].text.trim()) ??
        suggestedWeightForSet(exIdx, prevIdx))
        : suggestedWeightForSet(exIdx, prevIdx);
    final prevWAbs = _toAbsFromDisplay(prevWDisplay);

    final prevReps = (_repsControllers[exIdx][prevIdx].text
        .trim()
        .isNotEmpty)
        ? (int.tryParse(_repsControllers[exIdx][prevIdx].text.trim()) ??
        suggestedRepsForSet(exIdx, prevIdx).toInt())
        : suggestedRepsForSet(exIdx, prevIdx).toInt();

    double _rirFor(int setZeroBased) {
      final t = _rirControllers[exIdx][setZeroBased].text.trim();
      if (t.isNotEmpty) {
        final p = double.tryParse(t);
        if (p != null) return p;
      }
      return getRirFromPlanOrInput(exIdx, setZeroBased + 1);
    }
    final prevRir = _rirFor(prevIdx);

    final prevE1RM = PeriodizationModelUtils.calculateE1RM(
      prevWAbs, prevReps.toDouble(), prevRir,
    );

    final group = _groupFor(exerciseName, category);
    final rawDrop = _rawDropFor(group, setIdx);
    final drop = _gatedDrop(rawDrop, prevRir);
    final targetE1RM = (prevE1RM - drop).clamp(1.0, 9999.0);

    // --- math-based center reps for this set (anchor at previous ABS weight) ---
    final double rirCurrent = _typedOrHintRIR(exIdx: exIdx, setIdx: setIdx);
    final double repsNeededD = PeriodizationModelUtils.reverseCalculateReps(
      targetE1RM: targetE1RM,
      weight: prevWAbs,
      // anchor at previous set ABS weight
      baseWeight: prevWAbs,
      rir: rirCurrent,
      minReps: null,
    ).clamp(1.0, 45.0);
    final int repsCenter = repsNeededD.round().clamp(1, 45);

    // Collapse if weight typed for this set → single reps (consistent with hint)
    final typedW = _weightControllers[exIdx][setIdx].text.trim();
    if (typedW.isNotEmpty) {
      final wDisp = double.tryParse(typedW);
      if (wDisp != null && wDisp > 0) {
        final wAbs = _toAbsFromDisplay(wDisp);
        final thisRir = _typedOrHintRIR(exIdx: exIdx, setIdx: setIdx);

        // same tolerance as _synthesizeHintsForSet
        final tolKg = (group == 'D') ? 0.3 : 0.7;

        // allowed reps window = repsCenter ± 1 (clamped)
        final candidates = <int>{
          (repsCenter - 1).clamp(1, 45),
          repsCenter,
          (repsCenter + 1).clamp(1, 45),
        }.toList()
          ..sort();


        // evaluate error vs target for each candidate
        double bestErr = double.infinity;
        int bestRep = candidates.first;

        for (final r in candidates) {
          final e = PeriodizationModelUtils.calculateE1RM(
              wAbs, r.toDouble(), thisRir);
          final err = (e - targetE1RM).abs();

          // prefer any within tolerance, else minimize error; ties → lower reps
          final withinTolBest = (bestErr <= tolKg + 1e-6);
          final withinTolCur = (err <= tolKg + 1e-6);

          final take =
          // if current is within tol and best isn't → take current
          (withinTolCur && !withinTolBest)
              // if both within tol → take smaller error; tie → lower reps
              || (withinTolCur && withinTolBest && (err < bestErr - 1e-9 ||
              ((err - bestErr).abs() <= 1e-9 && r < bestRep)))
              // if neither within tol → minimize error; tie → lower reps
              || (!withinTolCur && !withinTolBest && (err < bestErr - 1e-9 ||
              ((err - bestErr).abs() <= 1e-9 && r < bestRep)));

          if (take) {
            bestErr = err;
            bestRep = r;
          }
        }

        return bestRep.toDouble();
      }
    }
    // Neither typed → use math-centered reps
    return repsCenter.toDouble();
  }


  Map<String, dynamic>? getPlannedRirSetValuesWES({
    required String exerciseName,
    required int exerciseIndex,
    required int setNumber,
  }) {
    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName];
    if (exerciseId == null) {
      print('❌ [WES ALT] No exerciseId found for "$exerciseName"');
      return null;
    }

    final rirPlan =
    PeriodizationModelUtils.plannedExerciseDetails[exerciseId]?['rirPlan'];
    if (rirPlan == null) {
      print('❌ [WES ALT] No rirPlan found for ID "$exerciseId"');
      return null;
    }

    final weekIndex = _getApplicableWeekIndex(exerciseId);
    if (weekIndex == null) {
      print('❌ [WES ALT] No weekIndex for "$exerciseName"');
      return null;
    }

    final sessionIndex =
    PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
      exerciseName: exerciseName,
      savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
      blockStartDate: _blockStartDate!,
      weekIndex: weekIndex,

    );

    final weekKey = 'week${weekIndex + 1}';
    final sessionKey = 'session${sessionIndex + 1}';
    final setKey = 'set$setNumber';

    print(
        '🧪 [WES ALT] $exerciseName ($exerciseId) → $weekKey > $sessionKey > $setKey');
    final sessionData = rirPlan[weekKey]?[sessionKey] as Map?;
    if (sessionData == null) {
      print('❌ [WES ALT] No session data found for $weekKey → $sessionKey');
      return null;
    }

    return sessionData.map((key, value) =>
        MapEntry(key, {
          'reps': value['reps'],
          'rir': value['rir'],
        }));
  }

  double getRirFromPlanOrInput(int exerciseIndex, int setNumber) {
    if (setNumber < 1 || setNumber > 8) return 1; // Safety fallback

    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    final bb2LookupIdRir = (() {
      final row = _selectedExercisesWithCircuits[exerciseIndex];
      final rId = (row['exerciseId'] ?? row['id'])?.toString().trim() ?? '';
      return (rId.isNotEmpty ? rId : (PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName)).toString().toLowerCase();
    })();
    final bb2Entry = _resolvedBB2Values[bb2LookupIdRir];
    final rawBB2Rir = bb2Entry?['rir'];
    final bb2Rir = (rawBB2Rir != null && rawBB2Rir
        .toString()
        .trim()
        .isNotEmpty)
        ? double.tryParse(rawBB2Rir.toString())
        : null;

    // ✅ Set 1: Use BB2 if available
    if (setNumber == 1 && bb2Rir != null && bb2Rir != 0.0) {
      print(
          '🔁 [WES] Using BB2-entered RIR for "$exerciseName" Set 1: $bb2Rir');
      return bb2Rir;
    }


    final exerciseId =
        PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
    final weekIndex = _getApplicableWeekIndex(exerciseId);
    if (weekIndex == null) return setNumber == 1 ? 1 : 1.5;

    if (blockStartDate == null && _blockStartDate != null) {
      print('🟥 [WES] blockStartDate NULL but _blockStartDate=$_blockStartDate (set$setNumber fallback)');
    }
    if (blockStartDate == null) {
      return 2; // fallback RIR value
    }


    final sessionIndex =
    PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
      exerciseName: exerciseName,
      savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
      blockStartDate: blockStartDate!,
      weekIndex: weekIndex,
      selectedDate: _selectedDate, // ← ensure this is present
    );

    final plannedDetails = PeriodizationModelUtils
        .plannedExerciseDetails[exerciseId] ?? const {};
    final repInstances = ((plannedDetails['repTargets']?['week1']) as Map?)
        ?.keys
        .where((k) => k.toString().startsWith('instance'))
        .length ?? 0;
    final effectiveFreq = repInstances > 0
        ? repInstances
        : (plannedDetails['weeklyFrequency'] as int? ?? 1);

// Rotate occurrences by effective frequency (e.g., 3rd appearance with freq=2 → session2)
    final desiredSessionIndex = (effectiveFreq > 0) ? (sessionIndex %
        effectiveFreq) : 0;

    final rirPlan = plannedDetails['rirPlan'];
    final weekKey = 'week${weekIndex + 1}';
    final weekData = (rirPlan?[weekKey] as Map?)?.cast<String, dynamic>() ??
        const {};

    String sessionKey = 'session${desiredSessionIndex + 1}';

// If the desired session isn’t present (e.g., ghosts elsewhere), fall back to session1
    if (!weekData.containsKey(sessionKey)) {
      sessionKey = 'session1';
    }

    final setKey = 'set$setNumber';


    final plannedRir = double.tryParse(
      rirPlan?[weekKey]?[sessionKey]?[setKey]?['rir']?.toString() ?? '',
    );

    // ✅ Sets 2–8: Use BB2 RIR if it's higher than planned
    if (setNumber > 1 && bb2Rir != null && plannedRir != null) {
      final chosen = bb2Rir > plannedRir ? bb2Rir : plannedRir;
      print(
          '🔁 [WES] Using higher of BB2 ($bb2Rir) vs planned ($plannedRir) → $chosen');
      return chosen;
    }

    final fallback = 1.0;

    final finalRir = plannedRir ?? fallback;

    // ── DEBUG DUMPS (week start respected via your weekIndex/sessionIndex utilities) ──

// 1) Dump repTargets.week1 “instances” for visibility
    final repWeek1Map = ((plannedDetails['repTargets']?['week1']) as Map?)
        ?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? const {};
    final repInstancesList = repWeek1Map.keys
        .where((k) => k.startsWith('instance'))
        .toList()
      ..sort((a, b) {
        final ai = int.tryParse(
            RegExp(r'(\d+)').firstMatch(a)?.group(1) ?? '0') ?? 0;
        final bi = int.tryParse(
            RegExp(r'(\d+)').firstMatch(b)?.group(1) ?? '0') ?? 0;
        return ai.compareTo(bi);
      });
    final repInstancesPretty = repInstancesList
        .map((k) => '$k=${repWeek1Map[k]}')
        .join(', ');

// 2) Dump full RIR plan for the current week (compact)
    String _dumpWeek(Map<String, dynamic> wk) {
      final sessKeys = wk.keys
          .where((k) => k.toString().startsWith('session'))
          .map((k) => k.toString())
          .toList()
        ..sort((a, b) {
          final ai = int.tryParse(
              RegExp(r'(\d+)').firstMatch(a)?.group(1) ?? '0') ?? 0;
          final bi = int.tryParse(
              RegExp(r'(\d+)').firstMatch(b)?.group(1) ?? '0') ?? 0;
          return ai.compareTo(bi);
        });

      final lines = <String>[];
      for (final sKey in sessKeys) {
        final sets = (wk[sKey] as Map?)?.cast<String, dynamic>() ?? const {};
        String setStr(int n) {
          final set = (sets['set$n'] as Map?)?.cast<String, dynamic>() ??
              const {};
          final reps = set['reps']?.toString();
          final rir = set['rir']?.toString();
          return (reps != null || rir != null)
              ? 'set$n{reps:$reps, rir:$rir}'
              : '';
        }
        final s = [setStr(1), setStr(2), setStr(3), setStr(4)]
            .where((e) => e.isNotEmpty)
            .join('  ');
        lines.add('  $sKey → $s');
      }
      return (lines.isEmpty) ? '  (no sessions found)' : lines.join('\n');
    }



// 3) Final pick summary (shows rotation + week start effects indirectly)



    return finalRir;
  }


  double set1RIR(int i) {
    final v = getRirFromPlanOrInput(i, 1);
    print('🟢 set1RIR($i) → $v');
    return v;
  }


// ✅ Function to determine RIR for Set 2 (Default: 1.5, Modifiable in Future)
  double set2RIR(int i) => getRirFromPlanOrInput(i, 2);

  double set3RIR(int i) => getRirFromPlanOrInput(i, 3);

  double set4RIR(int i) => getRirFromPlanOrInput(i, 4);

  double set5RIR(int i) => getRirFromPlanOrInput(i, 5);

  double set6RIR(int i) => getRirFromPlanOrInput(i, 6);

  double set7RIR(int i) => getRirFromPlanOrInput(i, 7);

  double set8RIR(int i) => getRirFromPlanOrInput(i, 8);

  double set1SuggestedWeight(int exerciseIndex) {

    // FAST-PATH: use precomputed hint if available
    final hintK = _rowKeyBy(exerciseIndex);

    // ⛳ Touch-state: use seed hint only when ALL set-1 fields are still empty.
    // If the user typed ANY value (weight, reps, or RIR), fall through to
    // E1RM derivation so reactive coupling works the same as on fresh workouts.
    final bool hasUserWeight = _weightControllers[exerciseIndex][0].text.trim().isNotEmpty;
    final bool hasUserReps   = _repsControllers[exerciseIndex][0].text.trim().isNotEmpty;
    final bool hasUserRir    = _rirControllers[exerciseIndex][0].text.trim().isNotEmpty;

    final hint  = _seedHintsByKey[hintK];
    if (hint != null && !hasUserWeight && !hasUserReps && !hasUserRir) {

      final exerciseName = _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
      final exId = PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
      final isBw = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: exerciseName);

      final num? v = isBw ? (hint['s1_weight_added'] as num?) : (hint['s1_weight'] as num?);
      if (v != null) {
        // [perf] print removed from hot path
        return v.toDouble();
      }
    } else if (hint != null) {
      // [perf] print removed from hot path
    }


    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    final bb2LookupIdWt = (() {
      final row = _selectedExercisesWithCircuits[exerciseIndex];
      final rId = (row['exerciseId'] ?? row['id'])?.toString().trim() ?? '';
      return (rId.isNotEmpty ? rId : (PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName)).toString().toLowerCase();
    })();
    final String exerciseId =
        PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;

    final bb2Entry = _resolvedBB2Values[bb2LookupIdWt];



    // ✅ Step 1: Use BB2-entered weight if available
    final double? bb2Weight = bb2Entry?['weight']?.toDouble();
    if (bb2Weight != null && bb2Weight > 0) {

      if (PeriodizationModelUtils.isBodyweightExercise(
          id: exerciseId, name: exerciseName)) {
        return PeriodizationModelUtils.toDisplayAddedWeight(
          uid: _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '',
          absoluteKg: bb2Weight,
          exerciseId: exerciseId,
          exerciseName: exerciseName,
          asOfDate: _selectedDate, // 👈 add this

        );
      }
      return bb2Weight;
    }


    // ✅ Step 2: Pull user-entered text fields
    final String weightText = _weightControllers[exerciseIndex][0].text;
    // [perf] debug parse + print removed from hot path

    final String repsText = _repsControllers[exerciseIndex][0].text;
    final String rirText = _rirControllers[exerciseIndex][0].text;

    final double? userWeight = double.tryParse(weightText);
    final double? userReps = double.tryParse(repsText) ??
        ((bb2Entry?['reps'] is num && (bb2Entry?['reps'] as num) > 0)
            ? (bb2Entry?['reps'] as num).toDouble()
            : null);

    final double? userRir = double.tryParse(rirText) ??
        ((bb2Entry?['rir'] is num && (bb2Entry?['rir'] as num) > 0)
            ? (bb2Entry?['rir'] as num).toDouble()
            : null);



    // 🛑 Step 3: Respect user-entered weight
    if (userWeight != null) {
      // [perf] print removed from hot path
      if (PeriodizationModelUtils.isBodyweightExercise(
          id: exerciseId, name: exerciseName)) {
        // already entered as ADDED in the field → just return it
        return userWeight;
      }
      return userWeight; // unchanged for non-BW
    }

    // ✅ Step 4: Pull model progression values
    final progressed = _getProgressedValues(exerciseIndex);
    final double baseWeight = progressed['weight']?.toDouble() ?? 20.0;
    final double baseReps = progressed['reps']?.toDouble() ?? 10.0;
    final double modelRir = getRirFromPlanOrInput(exerciseIndex, 1);
    // [perf] print removed from hot path

    // ✅ Step 5: Seed base E1RM
    final String _exId = PeriodizationModelUtils.nameToId[exerciseName] ??
        exerciseName;
    final bool _isBwEx = PeriodizationModelUtils.isBodyweightExercise(
        id: _exId, name: exerciseName);

// Current controller texts (WES fields)
    final String _repsTxt = _repsControllers[exerciseIndex][0].text.trim();
    final String _rirTxt = _rirControllers[exerciseIndex][0].text.trim();
    final double? _userRir = double.tryParse(_rirTxt);

// BB2-merged RIR (if any)
    final String normBB2Key = (() {
      final row = _selectedExercisesWithCircuits[exerciseIndex];
      final rId = (row['exerciseId'] ?? row['id'])?.toString().trim() ?? '';
      return (rId.isNotEmpty ? rId : (PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName)).toString().toLowerCase();
    })();
    final dynamic bb2RirRaw = _resolvedBB2Values[normBB2Key]?['rir'];
    final double? bb2Rir = (bb2RirRaw is num)
        ? bb2RirRaw.toDouble()
        : double.tryParse(bb2RirRaw?.toString() ?? '');

// Planned RIR for set 1 (pure plan; no BB2 overlay)
    double _plannedRirForSet1() {
      final plan = PeriodizationModelUtils
          .plannedExerciseDetails[_exId]?['rirPlan'];
      if (plan == null || blockStartDate == null) return modelRir;

      final int? wk = _getApplicableWeekIndex(_exId);
      if (wk == null) return modelRir;

      final int sessionIndex = PeriodizationModelUtils
          .getInstanceCountForExerciseInWeek(
        exerciseName: exerciseName,
        savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
        blockStartDate: blockStartDate!,
        weekIndex: wk,
        selectedDate: _selectedDate,
      );

      final String weekKey = 'week${wk + 1}';
      final Map? weekData = plan[weekKey] as Map?;
      final int maxSessions = weekData?.keys
          .where((k) => k.toString().startsWith('session'))
          .length ?? 0;
      final int safeSession = (maxSessions > 0) ? sessionIndex.clamp(
          0, maxSessions - 1) : 0;

      final String sessionKey = 'session${safeSession + 1}';
      final String setKey = 'set1';
      final String? raw = plan[weekKey]?[sessionKey]?[setKey]?['rir']
          ?.toString();
      return double.tryParse(raw ?? '') ?? modelRir;
    }

// BW + RIR-only (from BB2 hint) detection:
// - BW exercise
// - No reps typed in WES
// - No RIR typed in WES (so the value in play is from BB2 hint)
// - BB2 RIR exists
    final bool _rirOnlyBw = _isBwEx && _repsTxt.isEmpty && _userRir == null &&
        bb2Rir != null;

// Use planned RIR as the seed ONLY for that one case; otherwise keep existing modelRir
    final double _seedRIR = _rirOnlyBw ? _plannedRirForSet1() : modelRir;

// Compute base using the chosen seed
    final double baseE1RM = PeriodizationModelUtils.calculateE1RM(
      baseWeight,
      baseReps,
      _seedRIR,
    );

// (Optional, compact trace to confirm seeds during testing)



    // ✅ Step 6: Use user RIR and/or reps if available
    if (userReps != null || userRir != null) {
      final double repsToUse = userReps ?? set1SuggestedReps(exerciseIndex);
      final double rirToUse = userRir ?? modelRir;

      final double derived = PeriodizationModelUtils.reverseCalculateWeight(
        targetE1RM: baseE1RM,
        reps: repsToUse.toInt(),
        rir: rirToUse,
      );

      final String _exId = PeriodizationModelUtils.nameToId[exerciseName] ??
          exerciseName;
      final List<double> _candidates = PeriodizationModelUtils
          .getIncrementsForExercise(_exId);
      final double rounded = (_candidates.isNotEmpty ? _candidates : List<
          double>.generate(200, (i) => i * 2.5))
          .reduce((a, b) => (a - derived).abs() < (b - derived).abs() ? a : b);



      final double newE1RM = PeriodizationModelUtils.calculateE1RM(
        rounded,
        repsToUse,
        rirToUse,
      );

// ✅ Single BW branch: log THEN return display-added
      if (PeriodizationModelUtils.isBodyweightExercise(
          id: _exId, name: exerciseName)) {
        final double displayAdded = PeriodizationModelUtils
            .toDisplayAddedWeight(
          uid: _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '',
          absoluteKg: rounded,
          exerciseId: _exId,
          exerciseName: exerciseName,
          asOfDate: _selectedDate,
        );
        print('⚖️ [WES BW Convert] abs=${rounded.toStringAsFixed(
            2)} → displayAdded=${displayAdded.toStringAsFixed(2)}');
        return displayAdded;
      }

      return rounded;
    }

    // ✅ Step 7: No overrides — fallback to rounded base weight

    final List<double> _candidates = PeriodizationModelUtils
        .getIncrementsForExercise(_exId);
    final double fallbackRounded = (_candidates.isNotEmpty ? _candidates : List<
        double>.generate(200, (i) => i * 2.5))
        .reduce((a, b) =>
    (a - baseWeight).abs() < (b - baseWeight).abs()
        ? a
        : b);
    print(
        '🧲 [WES snap fallback] $baseWeight → $fallbackRounded (candidates=${_candidates
            .take(10).toList()} …)');

    print(
        '🎯 [WES] Final progression for $exerciseName using default RIR $modelRir → $fallbackRounded kg');

// 👇 print first, then return (BW converts to display)

    if (PeriodizationModelUtils.isBodyweightExercise(
        id: _exId, name: exerciseName)) {
      final double displayAdded = PeriodizationModelUtils.toDisplayAddedWeight(
        uid: _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '',
        absoluteKg: fallbackRounded,
        exerciseId: _exId,
        exerciseName: exerciseName,
      );
      return displayAdded;
    }
    return fallbackRounded;
  }

  // --- anchor: wherever set2SuggestedWeight is currently defined ---
  double set2SuggestedWeight(int i) => suggestedWeightForSet(i, 1);

// --- anchor: wherever set3SuggestedWeight is currently defined ---
  double set3SuggestedWeight(int i) => suggestedWeightForSet(i, 2);


  double e1rmDisplayForCell(int exIdx, int setIdx) {
    final name = (_selectedExercisesWithCircuits[exIdx]['name'] as String?)
        ?.trim() ?? '';
    final isBw = PeriodizationModelUtils.isBodyweightExercise(name: name);

    // raw values from controllers
    final weightText = _weightControllers[exIdx][setIdx].text;
    final repsText = _repsControllers[exIdx][setIdx].text;
    final rirText = _rirControllers[exIdx][setIdx].text;

    final double weight = double.tryParse(weightText) ??
        (_isInitialized ? suggestedWeightForSet(exIdx, setIdx) : 20.0);

    final int reps = int.tryParse(repsText) ??
        (_isInitialized
            ? suggestedRepsForSet(exIdx, setIdx).toInt()
            : (setIdx == 0 ? 15 : 10));


    // --- RIR: prefer typed → seed hint → plan ---
    final double? rirTyped = double.tryParse(rirText);

// build the same seed-key the hintText uses
    final String _normName = name.toLowerCase();
    final String _seedKey  = '$_normName|$exIdx';

// read seed rir for the correct set index
    double? _seedRirFor(int setIdx) {
      if (setIdx == 0) {
        final v = (_seedHintsByKey[_seedKey]?['s1_rir'] ??
            _seedHintsByKey[_seedKey]?['rir']);
        return (v is num) ? v.toDouble() : double.tryParse(v?.toString() ?? '');
      }
      final v = _seedHintsByKey[_seedKey]?['s${setIdx + 1}_rir'];
      return (v is num) ? v.toDouble() : double.tryParse(v?.toString() ?? '');
    }

    final double? rirSeed = _seedRirFor(setIdx);

// read plan RIR the same way your UI hint does
    double _planRirFor(int setIdx) {
      if (setIdx == 0) return set1RIR(exIdx);
      if (setIdx == 1) return set2RIR(exIdx);
      if (setIdx == 2) return set3RIR(exIdx);
      // safe default for sets >3 if you don’t have helpers
      return 1.0;
    }

// final chosen rir: typed > seed > plan
    final double rir = rirTyped ?? rirSeed ?? _planRirFor(setIdx);


    // convert to absolute if BW
    final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    final asOf = _selectedDate;

    final double abs = isBw
        ? PeriodizationModelUtils.toAbsoluteWeight(
      uid: uid,
      displayAddedKg: weight,
      exerciseName: name,
      asOfDate: asOf,
    )
        : weight;

    // use e1rmForDisplay → BW shows "added", non-BW normal
    return PeriodizationModelUtils.e1rmForDisplay(
      uid: uid,
      absoluteKg: abs,
      reps: reps,
      rir: rir,
      exerciseName: name,
      asOfDate: asOf,
    );
  }


  void _debugUid(String where) {
    final ctx = UserContext.of(context, listen: false);
    print('👤 [$where] actorUid=${ctx.actorUid} actingAsUid=${ctx
        .actingAsUid} currentUid=${ctx.currentUid}');
  }

  Future<T> _timeStep<T>(String label, Future<T> Function() step,
      {Stopwatch? total}) async {
    final sw = Stopwatch()
      ..start();
    try {
      return await step();
    } finally {
      sw.stop();
      if (kDebugMode) {
        debugPrint('⏱️ [WES Init] $label took ${sw.elapsedMilliseconds}ms'
            '${total != null
            ? " (total: ${total.elapsedMilliseconds}ms)"
            : ""}');
      }
    }
  }

  // ⏱️ WES open total timer (first-paint)
  Stopwatch? _wesOpenTotal;
  bool _wesOpenLogged = false;

  void _wesOpenDone(String reason) {
    if (_wesOpenLogged) return;
    _wesOpenLogged = true;
    _wesOpenTotal?.stop();
    final ms = _wesOpenTotal?.elapsedMilliseconds ?? -1;
    print('⏱️ [WES] FIRST-PAINT total = ${ms}ms ($reason)');
  }


  @override
  void initState() {
    super.initState();

    print('🚀 [WES] initState started');
    _isMergingBB2.value = true; // unlock button once
    Future.delayed(const Duration(seconds: 2), () {
      // If the widget is gone, do nothing
      if (!mounted) return;

      // Only re-enable if nothing else has set it back to true in the meantime
      if (_isMergingBB2.value == true) {
        _isMergingBB2.value = false;
      }
    });

    _sparkleCtrl = AnimationController(vsync: this);

    // Initialize "catch up" shine animation early to avoid LateInitializationError
    _catchupShineCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _catchupShineAnim = CurvedAnimation(
      parent: _catchupShineCtl!,
      curve: Curves.easeInOut,
    );

    _selectedDate = widget.initialDate ?? DateTime.now();
    if (_workoutNameController.text.trim().isEmpty) {
      _workoutNameController.text = DateFormat('EEE d MMM yyyy').format(_selectedDate);
    }
    // 🔒 Start session for the initial date
    _beginDateSession(_selectedDate);


    // 🔒 New epoch for this session/day
    _epoch++;
    final int _initEpoch = _epoch;


    // Read global block meta published by UserContext bootstrap (instant, no fetch)
    _cachedUid = UserContext.of(context, listen: false).currentUid;
    final uc = UserContext.of(context, listen: false);
    _activeBlockId   = uc.activeBlockId ?? _activeBlockId;
    _selectedBlockId = uc.activeBlockId ?? _selectedBlockId;
    _blockStartDate  = uc.blockStartDate ?? _blockStartDate;
    _blockEndDate    = uc.blockEndDate   ?? _blockEndDate;

    // 🔎 Offline preflight: verify caches are present before painting (non-blocking)
    Future.microtask(() async { await _offlinePreflightDebug(); });

    // ══════════════════════════════════════════════════════════════════════════
    // Phase 0: Claude-first fast paint (priority over Warmup snapshot)
    // Runs BEFORE _paintFromSnapshotIfAny(). If Phase 0 succeeds, Tripwire 1
    // will cause _paintFromSnapshotIfAny() to return early.
    // ══════════════════════════════════════════════════════════════════════════
    // ignore: unawaited_futures
    Claude_bulletPhase0FastPaintIfRecent().then((phase0Success) {
      // Whether Phase 0 succeeded or not, let _paintFromSnapshotIfAny() run.
      // Tripwire 1 will skip it if Phase 0 already painted.
      _paintFromSnapshotIfAny();
    });

    _wesOpenTotal = Stopwatch()..start();


    _blockDateLoad = _loadBlockDatesOnly(userId); // ✅ actingAsUid

    _repo = BlockPlannerRepository();
    WidgetsBinding.instance.addObserver(this);

    _selectedDate = widget.initialDate ?? DateTime.now();
    if (_workoutNameController.text.trim().isEmpty) {
      _workoutNameController.text = DateFormat('EEE d MMM yyyy').format(_selectedDate);
    }
    final initTotal = Stopwatch()..start();


    _initialLoad = _fetchActiveBlockThenMeta().then((_) {
      // ✅ Return an async function and immediately invoke it
      return (() async {
        try {
          await _blockDateLoad;

          print('⏳ [WES] fetchActiveBlockThenMeta() completed');

          if (_activeBlockId == null || _blockStartDate == null ||
              _blockEndDate == null) {
            print('❌ [WES Init] Missing required block meta. Exiting...');
            return;
          }

          await _loadAllBlocks();



          _selectedBlockId = _allBlocks
              .firstWhere(
                (b) => b.id == _activeBlockId,
            orElse: () => _allBlocks.first,
          )
              .id;

          print("🧱 [WES] Selected blockId: $_selectedBlockId");
          // ⚡ Try exact-key fast paint now that blockId is known



          // ✅ Pre-warm exact block doc for WES
          // right after: print("🧱 [WES] Selected blockId: $_selectedBlockId");
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final uidForWarm = userId;
            if (uidForWarm.isNotEmpty && _selectedBlockId != null &&
                _selectedBlockId!.isNotEmpty) {
              WarmupService.instance.warmWES(
                uidForWarm,
                activeBlockId: _selectedBlockId,
                selectedDate: _selectedDate,
              );
            }
          });

          WidgetsBinding.instance.addPostFrameCallback((_) {
            // If data flags already flipped and nothing claimed the stopwatch yet, log here.
            if (!_wesOpenLogged && _isInitialized && !_isLoadingData) {
              _wesOpenDone('postFrame');
            }
          });


          await _loadInitialData();

          await _fetchLastWorkoutTopSetReps();
          print("📈 [WES] Top set reps fetched");

          _debugPrintBlockDates();

          await _initializeDayDocIfNeeded(_selectedDate);

          _primeLatestBodyweightCache(_cachedUid!);
          await _primeBodyweightHistoryCache(_cachedUid!);

// [A/B] Compare WES vs Engine for first few rows
          for (int i = 0; i < (_selectedExercisesWithCircuits.length).clamp(0, 3); i++) {
            final wes = _getProgressedValues(i);
            final engine = ProgressionEngine.engineProgressedValues(
              ProgressionEngineInputs(
                blockStartDate: blockStartDate,
                blockEndDate: blockEndDate,
                selectedDate: _selectedDate,
                cachedUid: _cachedUid,
                selectedExercisesWithCircuits: _selectedExercisesWithCircuits,
                exerciseSettings: _exerciseSettings,
                cachedProgressedValues: _cachedProgressedValues,
                seedHintsByKey: _seedHintsByKey,
                resolvedBB2Values: _resolvedBB2Values,   // ✅ pass BB2 overrides
                rowKeyBy: _rowKeyBy,
                rowCacheKey: _rowCacheKey,
                getApplicableWeekIndex: _getApplicableWeekIndex,
                getRirFromPlanOrInput: getRirFromPlanOrInput,
                weightTextAt: (exIdx, setIdx) => _weightControllers[exIdx][setIdx].text,
                rirTextAt: (exIdx, setIdx) => _rirControllers[exIdx][setIdx].text,
                debugPrintBlockDates: _debugPrintBlockDates,
              ),
              i,
            );

            // Compare outputs
            debugPrint('[A/B] row=$i WES=${wes['weight']}kg/${wes['reps']} '
                'ENGINE=${engine['weight']}kg/${engine['reps']} '
                'ids: ${wes['exerciseId']} vs ${engine['exerciseId']}');

            // Show BB2 overrides if present
            final exName = _selectedExercisesWithCircuits[i]['name']?.trim() ?? '';
            final exId = PeriodizationModelUtils.nameToId[exName] ?? exName;
            final overrides = _resolvedBB2Values[exId];
            if (overrides != null) {
              debugPrint('[BB2] row=$i overrides → weight=${overrides['weight']} '
                  'reps=${overrides['reps']} rir=${overrides['rir']}');
            } else {
              debugPrint('[BB2] row=$i overrides → none');
            }
          }

          if (widget.initialDate != null) {
            _selectedDate = widget.initialDate!;
            _workoutNameController.text = _formatWorkoutDate(_selectedDate);
          }

          _cachedProgressedValues.clear();

// ⚠️ Non-destructive policy: if we already have rows (fast paint or user), never hard-clear.
          if (_didFastPaint || _selectedExercisesWithCircuits.isNotEmpty) {
            // Do NOT clear _resolvedBB2Values here — it holds BB2 override values needed for hint display
          } else {
            // Only clear if truly nothing is on screen AND epoch is still current
            if (!_isStale(_initEpoch)) {
              _selectedExercisesWithCircuits.clear();
              _workoutSets.clear();
              _repsControllers.clear();
              _weightControllers.clear();
              _rirControllers.clear();
              _velocityControllers.clear();
              _notesControllers.clear();
              _resolvedBB2Values.clear();
            }
          }


          //await _loadDraftLocallyIfAvailable();
          _populateVelocityFlags();
          print("🔀 [WES] Merged BB2 into draft");

          _cachedProgressedValues.clear();


          final hasUserData = _weightControllers.any((controllerList) =>
              controllerList.any((c) =>
              c.text
                  .trim()
                  .isNotEmpty));

          if (!hasUserData) {

            _lastMergedUid = null;
            await _mergeNewBB2ExercisesIntoDraft();
          } else {

          }

          _openingMergePhase = false;   // boot merges are done

          // 🟢 Safety net: once init/boot merges are done, ensure the Add Exercises
          // button is enabled (unless a later merge flips it back to true).
          _isMergingBB2.value = false;
          print('🟢 [WES Init] Boot phase complete → enabling Add Exercises button');



          print(
              '🔄 [WES Init] Overlaying saved workout (completed + WES-planned) after final BB2 merge…');
          // Capture row/controller structure before overlay
          final _beforeSel  = _selectedExercisesWithCircuits.length;
          final _beforeSets = _workoutSets.length;
          final _beforeReps = _repsControllers.length;
          final _beforeWts  = _weightControllers.length;
          final _beforeRir  = _rirControllers.length;
          final _beforeVel  = _velocityControllers.length;
          final _beforeNote = _notesControllers.length;

          await _loadExistingWorkoutIfAny(); // ← updates controllers & may insert rows

// Compare after overlay; only rebuild if the structure actually changed
          final _structureChanged =
              _selectedExercisesWithCircuits.length != _beforeSel  ||
                  _workoutSets.length                     != _beforeSets ||
                  _repsControllers.length                 != _beforeReps ||
                  _weightControllers.length               != _beforeWts  ||
                  _rirControllers.length                  != _beforeRir  ||
                  _velocityControllers.length             != _beforeVel  ||
                  _notesControllers.length                != _beforeNote;

          if (mounted && _structureChanged) {
            setState(() {}); // rebuild only when new rows were added/removed
          }
// else: only controller.text changed → TextFields update themselves; no repaint.


          // === BEGIN: SAVE WESInitSnapshot TO ISAR ===
          try {
            final uid = _cachedUid ?? UserContext.of(context, listen: false).currentUid;
            final bid = _selectedBlockId ?? _activeBlockId;
            final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);

            if (uid != null && bid != null) {
              final planned = _selectedExercisesWithCircuits
                  .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
                  .toList();

              // If you have these, supply them; otherwise use empty lists
              final previous = const <Map<String, dynamic>>[];
              final topSets  = const <Map<String, dynamic>>[];

              final plannedCount  = planned.length;
              final previousCount = previous.length;

              if (plannedCount == 0 && previousCount == 0) {
                print('🟨 [WES Init] Skip snapshot PUT (both planned & previous empty) for $ymd');
              } else {
                await BlockPlanCache.putInitSnapshot(
                  uid: uid,
                  blockId: bid,
                  dateYmd: ymd,
                  plannedExercises: planned,
                  wesPlannedExercises: const <Map<String, dynamic>>[],  // ← NEW (empty at boot is OK)
                  previousWorkout: previous,
                  topSetHistory: topSets,
                  hintsJson: '{}',             // empty at boot
                  hintsInputsHash: '',         // unknown at boot
                  hintsReady: false,           // mark not ready
                  schemaVersion: kWesSnapshotSchema,
                  updatedAt: DateTime.now(),
                );



                print('🟩 [WES Init] Snapshot PUT to Isar for $ymd (uid=$uid, block=$bid) '
                    'planned=$plannedCount, prev=$previousCount');
              }
            } else {
              print('🟨 [WES Init] Skip snapshot PUT (uid or blockId missing)');
            }
          } catch (e) {
            print('🟥 [WES Init] Snapshot PUT failed: $e');
          }

// === END: SAVE WESInitSnapshot TO ISAR ===


          _scheduleMissedButtonAfterPaint(); // compute in background; show button when ready



          Future.delayed(const Duration(milliseconds: 10), () {
            if (_selectedExercisesWithCircuits.isNotEmpty) {
              final testExercise = _selectedExercisesWithCircuits.first['name']
                  ?.trim() ?? '';
              final rep = getRepTargetForExerciseWES(testExercise, 0);

            } else {
              print(
                  '⚠️ [WES Init] No exercises in _selectedExercisesWithCircuits');
            }
          });
        } catch (e, stack) {
          print('💥 [WES Init] Exception caught: $e');
          print(stack);
        }
      })(); // ✅ ← This invokes and returns the async block
    });


    Future.microtask(() async {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('wasSavedFromWES') == true) {
        prefs.remove('wasSavedFromWES');
        setState(() {
          print("🟣 Triggered UI update due to save from WES");
        });
      }
    });

    _horizontalScrollController = ScrollController();

    print('🧠 [WES] initState complete — awaiting _initialLoad...');
    _wesInitTimer.stop();
    print('⏱️ [WES] initState total = ${_wesInitTimer.elapsedMilliseconds}ms');

  }

  Future<void> _loadInitialData() async {
    final _tInit = Stopwatch()
      ..start(); // ⏱️ start total timer
    print('⏱️ [WES] _loadInitialData started');
    final int _loadEpoch = _epoch; // capture
    final String _loadDayKey = _currentDayKey;


    // If fast-paint already put rows on screen, never gate UI again.
    final _bootPainted = _didFastPaint || _selectedExercisesWithCircuits.isNotEmpty;
    if (_bootPainted) {
      // Make sure UI shows content and never regresses to a spinner/placeholder
      _isInitialized = true;
      _isLoadingData = false;
    }

    print('🚀 [WES Init] Starting _loadInitialData');
    final _loadInitialDataTimer = Stopwatch()
      ..start();

    // 0) Fast path for prefilled (unchanged)
    if (widget.prefilledExercisesWithCircuits?.isNotEmpty ?? false) {
      if (_isStale(_loadEpoch) || _loadDayKey != _currentDayKey) {
        print('⛔️ [_loadInitialData] stale (epoch/dayKey) — aborting apply');
        return;
      }

      setState(() {
        _selectedExercisesWithCircuits
          ..clear()
          ..addAll(widget.prefilledExercisesWithCircuits!.map((e) => Map<
              String,
              dynamic>.from(e)));
        // init controllers
        _workoutSets.clear();
        _repsControllers.clear();
        _weightControllers.clear();
        _rirControllers.clear();
        _velocityControllers.clear();
        _notesControllers.clear();
        for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
          _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
          _repsControllers.add(
              List.generate(_defaultSets, (_) => TextEditingController()));
          _weightControllers.add(
              List.generate(_defaultSets, (_) => TextEditingController()));
          _rirControllers.add(
              List.generate(_defaultSets, (_) => TextEditingController()));
          _velocityControllers.add(
              List.generate(_defaultSets, (_) => TextEditingController()));
          _notesControllers.add(
              List.generate(_defaultSets, (_) => TextEditingController()));
        }
        _blockStartDate = widget.initialDate;
        _blockEndDate = widget.initialDate;
        _isLoadingData = false;
        _isInitialized = true;
      });
      return;
    }



// ──────────────────────────────────────────────────────────────
// SUPER-CACHE READ: disabled here to avoid double fast-paint.
// ──────────────────────────────────────────────────────────────



    // A) ORDER-DEPENDENT chain (keep sequential)
    //    1) load exercises base list
    await loadExercisesFromFirestoreForWES(); // has its own stopwatch
    //    2) name/id maps
    await _buildNameToIdMapsFromFirestore();
    //    3) planned exercise **details** (depends on maps)
    await _loadPlannedExerciseDetails();

    // B) FIRE CACHE-FIRST READS IN PARALLEL (independent after A)
    final uid = _cachedUid;
    final List<Future> reads = [
      // Saved workouts (instance counts / overlays)
      loadSavedWorkoutsForInstanceCount(), // already ~134ms
      // Planned exercises rows (weekly/day plan containers)
      loadPlannedExercisesFromFirestore(),
      // Previous workout data (overlay)
      loadPreviousWorkoutData(), // ~100ms
      // Full top-set history (can be long: keep parallel)
      PeriodizationModelUtils.fetchFullTopSetHistory(uid: uid),
    ];

    // C) ALSO kick a cache-first touch of today’s BB2 day via Isar so first paint has data
//    (non-blocking; _mergeNewBB2ExercisesIntoDraft will read Isar first now)
// ignore: unawaited_futures
    (() async {
      try {
        if (_blockStartDate != null && _selectedDate != null &&
            _selectedBlockId != null) {
          final ds = _selectedDate
              .difference(_blockStartDate!)
              .inDays;
          if (ds >= 0) {
            final wi = ds ~/ 7;
            final di = ds % 7;
            final isarList = await BlockPlanCache.getDay(
              uid: _cachedUid ?? '',
              blockId: _selectedBlockId!,
              weekIndex: wi,
              dayIndex: di,
            );
            if (isarList != null) {
              print('🟣 [Init] ISAR day prefetch count=${isarList.length}');
            }
          }
        }
      } catch (_) {}
    })();


    // D) Await the parallel batch (don’t block paint on server reconciliation elsewhere)
    await Future.wait(reads);

    // E) Draft load (as before)
    print('[WES_REENTER] _loadInitialData: about to load draft from cache');
    final draftLoaded = await _loadWorkoutDraftFromCache();
    print('[WES_REENTER] _loadInitialData: draftLoaded=$draftLoaded');
    if (draftLoaded && mounted) {
      setState(() {}); // rebuild UI with draft-restored controllers
    }


    // F) Touch BB2 day doc from SERVER (best-effort) so merge has fresh data
    //    Keep **non-blocking**: the merge will re-run when data arrives if needed
    //    (You already have a server touch below; keep it best-effort)
    try {
      final uid = _cachedUid;
      final bid = _selectedBlockId;
      if (uid != null && bid != null && _blockStartDate != null &&
          _selectedDate != null) {
        final ds = _selectedDate
            .difference(_blockStartDate!)
            .inDays;
        if (ds >= 0) {
          final wi = (ds / 7).floor();
          final di = ds % 7;
          // server touch; cache-first UI has already painted from Isar/draft
          await FirebaseFirestore.instance
              .collection('planned_blocks').doc(uid)
              .collection('blocks').doc(bid)
              .collection('weeks').doc('week_$wi')
              .collection('days').doc('day_$di')
              .get(const GetOptions(source: Source.server));
        }
      }
    } catch (e) {
      print('⚠️ [WES Init] Server touch failed (non-fatal): $e');
    }

    // G) Merge BB2 into UI
    final _rowsExist = _selectedExercisesWithCircuits.isNotEmpty;

    if (draftLoaded) {

      await _mergeNewBB2ExercisesIntoDraft(); // Isar-first inside
    } else {

      if (_isStale(_loadEpoch) || _loadDayKey != _currentDayKey) {
        print('⛔️ [_loadInitialData] stale (epoch/dayKey) — aborting apply');
        return;
      }

      if (!_rowsExist && !_didFastPaint) {


        _selectedExercisesWithCircuits.clear();
      }
      await _mergeNewBB2ExercisesIntoDraft();

    }


    // H) Finalize UI flags + paint
    final _needSpinnerFlip = (!_isInitialized || _isLoadingData);
    _isLoadingData = false;
    _isInitialized = true;
// Only rebuild if we’d otherwise show a spinner and there’s no content yet
    if (mounted && _needSpinnerFlip && _selectedExercisesWithCircuits.isEmpty) {
      print('🟢 [WES] Spinner→content flip repaint');
      if (_isStale(_loadEpoch) || _loadDayKey != _currentDayKey) {
        print('⛔️ [_loadInitialData] stale (epoch/dayKey) — aborting apply');
        return;
      }

      setState(() {});
    } else {
      print('⚪ [WES] Skip spinner repaint (content already on screen)');
    }


    // ──────────────────────────────────────────────────────────────
// SUPER-CACHE WRITE: persist a minimal snapshot for next open
// (planned list + previous overlay + top-set history)
// ──────────────────────────────────────────────────────────────
    try {
      final uid = _cachedUid;
      final bid = _selectedBlockId;
      if (uid != null && bid != null) {
        final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);

        // (1) Planned list: compact (name + circuitIndex)
        final plannedCompact = _selectedExercisesWithCircuits.map((e) {
          final name = (e['name'] ?? '').toString().trim();
          final ci = (e['circuitIndex'] ?? 0) as int;
          return {'name': name, 'circuitIndex': ci};
        }).toList();

        // (2) Previous workout overlay (compact rows)
        final List<Map<String, dynamic>> previousOverlay = [];
        for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
          final exName = (_selectedExercisesWithCircuits[i]['name'] ?? '')
              .toString()
              .trim();
          final ci = (_selectedExercisesWithCircuits[i]['circuitIndex'] ??
              0) as int;
          if (i >= _workoutSets.length) continue;
          final sets = _workoutSets[i].map((s) =>
          {
            if (s.reps != null) 'reps': s.reps,
            if (s.weight != null) 'weight': s.weight,
            if (s.rir != null) 'rir': s.rir,
            if (s.velocity != null) 'velocity': s.velocity,
            if ((s.notes ?? '')
                .toString()
                .isNotEmpty) 'notes': s.notes,
          }).toList();
          previousOverlay.add({
            'name': exName,
            'circuitIndex': ci,
            'sets': sets,
          });
        }

        // (3) Top-set history (best-effort)
        Map<String, dynamic> topSetHistory = const {};
        try {
          // If you have a real source, populate it here.
          // topSetHistory = PeriodizationModelUtils.fullTopSetHistoryCache ?? const {};
        } catch (_) {}
        final List<Map<String, dynamic>> topSetHistoryList = [topSetHistory];

        // ✅ Save snapshot via the helper with named params
        final plannedCount  = plannedCompact.length;
        final previousCount = previousOverlay.length;

        // (4) Pre-resolved S1 hints map for instant first paint next time
        final Map<String, dynamic> hints = {};
        for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
          final name = (_selectedExercisesWithCircuits[i]['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;
          final ci   = (_selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0) as int;
          final key  = '${name.toLowerCase()}|$ci';

          // Use current helpers (they won’t recurse because _seedHintsByKey is empty on first save)
          final double s1W = set1SuggestedWeight(i);
          final double s1R = set1SuggestedReps(i);
          final double s1Ri = getRirFromPlanOrInput(i, 1);

          final exId = PeriodizationModelUtils.nameToId[name] ?? name;
          final isBw = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: name);

          final double e1 = PeriodizationModelUtils.calculateE1RM(
            // For BW: reverse to absolute for e1rm computation
            isBw
                ? PeriodizationModelUtils.toAbsoluteWeight(
              uid: _cachedUid ?? '',
              displayAddedKg: s1W,
              exerciseId: exId,
              exerciseName: name,
              asOfDate: _selectedDate,
            )
                : s1W,
            s1R,
            s1Ri,
          );

          final String stableKey = '${exId.toString().trim()}|$ci'; // canonical
          final Map<String, dynamic> base = {
            // ✅ self-describing fields so snapshot can be re-keyed deterministically
            'name': name,
            'circuitIndex': ci,
            'exerciseId': exId.toString().trim(),
          };

          hints[stableKey] = isBw
              ? {
            ...base,
            's1_weight_added': s1W, // display-added kg for BW
            's1_reps': s1R,
            's1_rir': s1Ri,
            'e1rm': e1,
          }
              : {
            ...base,
            's1_weight': s1W,       // absolute kg for non-BW
            's1_reps': s1R,
            's1_rir': s1Ri,
            'e1rm': e1,
          };

        }
        final String hintsJson = jsonEncode(hints);
        print(
            '🧪 [WES HINTS SNAPSHOT WRITE] '
                '${hints.entries.take(1).map((e) => {
              "key": e.key,
              "value": e.value,
            }).toList()}'
        );


        if (plannedCount == 0 && previousCount == 0) {
          print('🟨 [WES Init] Skip snapshot save (both planned & previous empty) for $ymd');
        } else {
          await BlockPlanCache.putInitSnapshot(
            uid: uid,
            blockId: bid,
            dateYmd: ymd,
            plannedExercises: plannedCompact,
            wesPlannedExercises: const <Map<String, dynamic>>[],   // ← NEW (or your real WES placeholders if available)
            previousWorkout: previousOverlay,
            topSetHistory: topSetHistoryList,
            hintsJson: hintsJson,
            hintsInputsHash: '',            // ← set to your computed hash if you have it here
            hintsReady: hintsJson.isNotEmpty && hintsJson != '{}',
            schemaVersion: kWesSnapshotSchema,  // ← keep consistent with Warmup
            updatedAt: DateTime.now(),
          );

          print('💾 [WES Init] Snapshot saved for $ymd (planned=$plannedCount, prev=$previousCount)');
        }

      } else {
        print('🟨 [WES Init] Skip snapshot PUT (uid or blockId missing)');
      }
    } catch (e) {
      print('🟥 [WES Init] WESInitSnapshot save failed: $e');
    }

    _debugLogCardsForSelectedDate('LoadExisting');

    print('✅ [WES Init] _loadInitialData complete');
    _loadInitialDataTimer.stop();
    print('⏱️ [WES] _loadInitialData took ${_loadInitialDataTimer
        .elapsedMilliseconds}ms');

    // ⏱️ Add this for the full wall-clock first-paint measure
    print('⏱️ [WES] FIRST-PAINT total = ${_loadInitialDataTimer
        .elapsedMilliseconds}ms (_loadInitialData)');

    // I) Overlay saved workout rows AFTER initial paint (kept non-blocking now)
    //    You previously called this synchronously; now kick it after paint
    //    (Your _loadExistingWorkoutIfAny already has cache/Isar-first)
    // ignore: unawaited_futures
    (() async {
      final _before = _structureHash();
      await _loadExistingWorkoutIfAny();
      final _after = _structureHash();
      if (mounted && _after != _before) setState(() {}); // only if shape changed
    })();

  }


  Future<void> _fetchActiveBlockThenMeta() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _activeBlockId = await BlockRepository().fetchActiveBlockId(userId);
    print('🎯 [WES] Active Block ID from Firestore = $_activeBlockId');

    if (_activeBlockId == null) {
      print('❌ [WES] No active block found');
      return;
    }

    // ⏳ Retry loop to wait for start/end dates if not yet available
    const maxAttempts = 5;
    const delayBetweenAttempts = Duration(milliseconds: 300);

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final meta = await _repo.loadBlockMeta(
        userId: userId, // ✅ actingAsUid
        blockId: _activeBlockId!,
      );

// 🔍 Fetch block name directly (BlockMeta does not include it)
      final blockDoc = await FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(userId)
          .collection('blocks')
          .doc(_activeBlockId!)
          .get();

      final blockName = blockDoc.data()?['name'];
      if (blockName is String && blockName.isNotEmpty) {
        _blockNameById[_activeBlockId!] = blockName;
      }


      final start = meta.startDate;
      final end = meta.endDate;
      final days = meta.selectedDays;

      if (start != null && end != null) {
        blockStartDate = start;
        blockEndDate = end;
        _selectedDays = days;

        return;
      } else {
        print('⏳ [WES] BlockMeta not ready (attempt $attempt) — retrying...');
        await Future.delayed(delayBetweenAttempts);
      }
    }

    // ❌ Still null after all attempts
    print(
        '❌ [WES] Failed to fetch valid blockMeta after $maxAttempts attempts');
  }

  void _populateVelocityFlags() {
    for (final exercise in _selectedExercisesWithCircuits) {
      final name = (exercise['name'] as String?)?.toLowerCase() ?? '';
      final isTracked = PeriodizationModelUtils.isVelocityTracked(
          name); // ✅ declare it here
      _showVelocityByExercise[name] = isTracked;
    }
  }


  Future<void> _loadBlockDatesOnly(String userId) async {
    final blockId = await BlockRepository().fetchActiveBlockId(userId);

    if (blockId == null) {
      throw StateError("No active block found");
    }

    final meta = await _repo.loadBlockMeta(
      userId: userId, // ✅ now passed in
      blockId: blockId,
    );

    _blockStartDate = meta.startDate;
    _blockEndDate = meta.endDate;


  }


  Future<void> _loadAllBlocks() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    print(
        '👤 [WES] _loadAllBlocks using userId=$userId and currentUser.uid=${FirebaseAuth
            .instance.currentUser?.uid}');

    final snap = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .get();



    final blocks = snap.docs.map((d) {
      final data = d.data();

      final Timestamp? startTs = data.containsKey('startDate')
          ? data['startDate'] as Timestamp?
          : null;
      final Timestamp? endTs = data.containsKey('endDate')
          ? data['endDate'] as Timestamp?
          : null;

      return BlockMeta(
        id: d.id,
        name: data['name'],
        // nullable is fine now
        startDate: startTs?.toDate(),
        endDate: endTs?.toDate(),
        selectedDays: List<String>.from(data['selectedDays'] ?? []),
      );
    }).toList();


    setState(() {
      _allBlocks = blocks;
    });
  }

  Future<void> _initializeDayDocIfNeeded(DateTime date) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _selectedBlockId == null || blockStartDate == null)
      return;

    final blockId = _selectedBlockId!;
    final daysSinceStart = date
        .difference(blockStartDate!)
        .inDays;
    if (daysSinceStart < 0) return;

    final weekIndex = (daysSinceStart / 7).floor();
    final dayIndex = daysSinceStart % 7;

    final dayDocRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(blockId)
        .collection('weeks')
        .doc('week_$weekIndex')
        .collection('days')
        .doc('day_$dayIndex');

    final doc = await dayDocRef.get();
    if (!doc.exists) {
      // Look for fallback data
      final dateKey = DateFormat('yyyy-MM-dd').format(date);
      final blockDataDoc = await FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(userId)
          .collection('blocks')
          .doc(blockId)
          .collection('block_data')
          .doc(dateKey)
          .get();

      if (blockDataDoc.exists && blockDataDoc.data()?['rows'] != null) {
        print(
            '[WES Init] Populating missing week/day doc from fallback block_data...');
        await dayDocRef.set({
          'exercises': blockDataDoc.data()!['rows'],
        });
      } else {
        print('[WES Init] No fallback block_data to populate day doc');
      }
    } else {
      print('[WES Init] Day doc already exists → no action needed');
    }
  }

  //fast page-open bits...





    Future<void> _offlinePreflightDebug() async {
    try {
      final uid = _cachedUid ?? UserContext.of(context, listen: false).currentUid;
      final bid = _selectedBlockId
          ?? _activeBlockId
          ?? UserContext.of(context, listen: false).activeBlockId;
      final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);

      print('🧪 [Offline] Preflight → uid=$uid bid=$bid ymd=$ymd');

      if (uid == null || bid == null) {
        print('⚠️ [Offline] Missing uid or blockId — cannot verify caches');
        return;
      }

      // A) WESInitSnapshot (what fast-paint uses)
      final snap = await BlockPlanCache.getInitSnapshot(
        uid: uid,
        blockId: bid,
        dateYmd: ymd,
      );
      print('📥 [FAST-snap] got snapshot for $ymd '
          'ready=${snap?.hintsReady} '
          'sv=${snap?.schemaVersion} '
          'hash=${snap?.hintsInputsHash} '
          'jsonPreview=${(snap?.hintsJson ?? '').substring(0, (snap?.hintsJson ?? '').length.clamp(0, 80))}...');


      if (snap == null) {
        print('🔴 [Offline] No WESInitSnapshot in Isar for $ymd');
      } else {
        final plannedLen = (snap.plannedExercisesJson.isNotEmpty)
            ? (jsonDecode(snap.plannedExercisesJson) as List).length
            : 0;
        final prevLen = (snap.previousWorkoutJson.isNotEmpty)
            ? (jsonDecode(snap.previousWorkoutJson) as List).length
            : 0;
        print('🟢 [Offline] WESInitSnapshot OK → planned=$plannedLen prev=$prevLen for $ymd');
      }

      // B) Day super-cache (week/day rows from BB2)
      final bs = _blockStartDate ?? UserContext.of(context, listen: false).blockStartDate;
      if (bs == null) {
        print('⚠️ [Offline] blockStartDate unknown — skipping day-cache check');
        return;
      }

      final startOnly = DateTime(bs.year, bs.month, bs.day);
      final daysSince = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day)
          .difference(startOnly)
          .inDays;

      if (daysSince < 0) {
        print('⚠️ [Offline] Selected date is before block start — no day-cache expected');
        return;
      }

      final wi = daysSince ~/ 7;
      final di = daysSince % 7;

      final day = await BlockPlanCache.getDay(
        uid: uid,
        blockId: bid,
        weekIndex: wi,
        dayIndex: di,
      );

      if (day == null || day.isEmpty) {
        print('🟡 [Offline] Day cache empty for week=$wi day=$di (not fatal if snapshot exists)');
      } else {
        print('🟢 [Offline] Day cache OK → week=$wi day=$di rows=${day.length}');
      }
    } catch (e) {
      print('🟥 [Offline] Preflight failed: $e');
    }
  }
  // ─────────────────────────────────────────────────────────────
// Silent, in-place overlay: updates existing rows' controllers,
// and appends new rows if the server has extras. No clearing.
// ─────────────────────────────────────────────────────────────
  bool _applyOverlayInPlace(List<Map<String, dynamic>> exList) {
    if (!mounted || exList.isEmpty) return false;

    // 🧮 capture shape before
    final __before = _structureHash();

    // Build quick lookup for incoming rows by name|ci
    String _key(String name, int ci) => '${name.trim().toLowerCase()}|$ci';
    final incomingByKey = <String, Map<String, dynamic>>{};
    for (final raw in exList) {
      final name = (raw['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final ci = (raw['circuitIndex'] ?? 0) is int
          ? raw['circuitIndex'] as int
          : int.tryParse('${raw['circuitIndex'] ?? 0}') ?? 0;
      incomingByKey[_key(name, ci)] = raw;
    }

    // 1) Update existing rows
    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      final name = ((_selectedExercisesWithCircuits[i]['name'] ?? '') as String).trim();
      final ci   = (_selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0) as int;
      final k    = _key(name, ci);

      final match = incomingByKey[k];
      if (match == null) continue;

      // Extract sets -> SetDetails list (respect BW conversion the same way you already do)
      final setMaps = List<Map<String, dynamic>>.from(match['sets'] ?? const []);
      if (setMaps.isEmpty) continue;

      final isBw = PeriodizationModelUtils.isBodyweightExercise(name: name);
      final asOf = _selectedDate;

      final sets = setMaps.map((s) {
        final reps = (s['reps'] is int) ? s['reps'] : int.tryParse(s['reps']?.toString() ?? '');
        final double? abs = (s['weight'] is num) ? (s['weight'] as num).toDouble() : null;
        final num? awRaw = (s['addedWeight'] as num?) ?? (s['weightAdded'] as num?); // legacy fallback

        final double? display = isBw
            ? (awRaw != null
            ? awRaw.toDouble()
            : (abs != null
            ? PeriodizationModelUtils.toDisplayAddedWeight(
          uid: _cachedUid ?? '',
          absoluteKg: abs,
          exerciseName: name,
          asOfDate: asOf,
        )
            : null))
            : abs;

        return SetDetails(
          reps: reps,
          weight: display,
          rir: (s['rir'] is num) ? (s['rir'] as num).toDouble() : null,
          velocity: (s['velocity'] is num) ? (s['velocity'] as num).toDouble() : null,
          notes: s['notes']?.toString(),
        );
      }).toList();

      // Pad to default rows for hint text
      while (sets.length < _defaultSets) {
        sets.add(SetDetails());
      }

      // Ensure controller lists exist and match size
      if (_workoutSets.length <= i) {
        _workoutSets.add(List<SetDetails>.from(sets));
        _repsControllers.add(List.generate(sets.length, (_) => TextEditingController()));
        _weightControllers.add(List.generate(sets.length, (_) => TextEditingController()));
        _rirControllers.add(List.generate(sets.length, (_) => TextEditingController()));
        _velocityControllers.add(List.generate(sets.length, (_) => TextEditingController()));
        _notesControllers.add(List.generate(sets.length, (_) => TextEditingController()));
      } else {
        _workoutSets[i] = List<SetDetails>.from(sets);
        // Resize controllers if needed (recreate only when length differs)
        void _ensureLen(List<List<TextEditingController>> list) {
          if (list.length <= i) {
            list.add(List.generate(sets.length, (_) => TextEditingController()));
          } else if (list[i].length != sets.length) {
            list[i] = List.generate(sets.length, (_) => TextEditingController());
          }
        }
        _ensureLen(_repsControllers);
        _ensureLen(_weightControllers);
        _ensureLen(_rirControllers);
        _ensureLen(_velocityControllers);
        _ensureLen(_notesControllers);
      }

      // Seed controller text
      for (int j = 0; j < sets.length; j++) {
        final s = sets[j];
        _repsControllers[i][j].text     = (s.reps?.toString() ?? '');
        _weightControllers[i][j].text   = (s.weight?.toString() ?? '');
        _rirControllers[i][j].text      = (s.rir?.toString() ?? '');
        _velocityControllers[i][j].text = (s.velocity?.toString() ?? '');
        _notesControllers[i][j].text    = (s.notes ?? '');
      }
    }

    // 2) Append any incoming rows that don’t exist in UI yet
    final existingKeys = _selectedExercisesWithCircuits
        .map<String>((e) => '${((e['name'] ?? '') as String).trim().toLowerCase()}|${(e['circuitIndex'] ?? 0) as int}')
        .toSet();

    for (final raw in exList) {
      final name = (raw['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final ci = (raw['circuitIndex'] ?? 0) is int
          ? raw['circuitIndex'] as int
          : int.tryParse('${raw['circuitIndex'] ?? 0}') ?? 0;
      final k  = _key(name, ci);
      if (existingKeys.contains(k)) continue;

      // Build new row sets
      final setMaps = List<Map<String, dynamic>>.from(raw['sets'] ?? const []);
      final isBw = PeriodizationModelUtils.isBodyweightExercise(name: name);
      final asOf = _selectedDate;

      final sets = setMaps.map((s) {
        final reps = (s['reps'] is int) ? s['reps'] : int.tryParse(s['reps']?.toString() ?? '');
        final double? abs = (s['weight'] is num) ? (s['weight'] as num).toDouble() : null;
        final num? awRaw = (s['addedWeight'] as num?) ?? (s['weightAdded'] as num?);
        final double? display = isBw
            ? (awRaw != null
            ? awRaw.toDouble()
            : (abs != null
            ? PeriodizationModelUtils.toDisplayAddedWeight(
          uid: _cachedUid ?? '',
          absoluteKg: abs,
          exerciseName: name,
          asOfDate: asOf,
        )
            : null))
            : abs;

        return SetDetails(
          reps: reps,
          weight: display,
          rir: (s['rir'] is num) ? (s['rir'] as num).toDouble() : null,
          velocity: (s['velocity'] is num) ? (s['velocity'] as num).toDouble() : null,
          notes: s['notes']?.toString(),
        );
      }).toList();

      while (sets.length < _defaultSets) {
        sets.add(SetDetails());
      }

      // Append UI row + controllers
      final eid = (raw['exerciseId'] ?? raw['id'])?.toString().trim() ?? '';
      final resolvedId = eid.isNotEmpty ? eid : (PeriodizationModelUtils.nameToId[name] ?? name).trim();
      _selectedExercisesWithCircuits.add({'name': name, 'exerciseId': resolvedId, 'id': resolvedId, 'circuitIndex': ci});
      _workoutSets.add(sets);
      _repsControllers.add(List.generate(sets.length, (_) => TextEditingController()));
      _weightControllers.add(List.generate(sets.length, (_) => TextEditingController()));
      _rirControllers.add(List.generate(sets.length, (_) => TextEditingController()));
      _velocityControllers.add(List.generate(sets.length, (_) => TextEditingController()));
      _notesControllers.add(List.generate(sets.length, (_) => TextEditingController()));

      final idx = _selectedExercisesWithCircuits.length - 1;
      for (int j = 0; j < sets.length; j++) {
        final s = sets[j];
        _repsControllers[idx][j].text     = (s.reps?.toString() ?? '');
        _weightControllers[idx][j].text   = (s.weight?.toString() ?? '');
        _rirControllers[idx][j].text      = (s.rir?.toString() ?? '');
        _velocityControllers[idx][j].text = (s.velocity?.toString() ?? '');
        _notesControllers[idx][j].text    = (s.notes ?? '');
      }
    }

    // 🧮 capture shape after
    final __after = _structureHash();
    return __after != __before; // caller decides whether to setState()
  }




  void _ensureControllersForRowsLazily() {
    // Build minimal controllers/sets ONLY if missing (non-blocking first frame).
    final int n = _selectedExercisesWithCircuits.length;

    while (_workoutSets.length < n) {
      _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
    }
    while (_repsControllers.length < n) {
      _repsControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
      _weightControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
      _rirControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
      _velocityControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
      _notesControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
    }

    _attachDirtyListeners();
  }

// 🔸 FAST seed for velocity flags before first paint
  bool _wesShouldShowVelocityFast({
    required String exerciseName,
    required String exerciseId,
    Map<String, dynamic>? hintEntry, // may be null
  }) {
    // 1) Highest priority: if hint carried it
    final hv = (hintEntry?['velocity'] ?? hintEntry?['s1_velocity']);
    if (hv is num) return true;

    // 2) If RIR/rep scheme implies velocity work (common for your velocity days)
    final rir = (hintEntry?['rir'] ?? hintEntry?['s1_rir']);
    if (rir is num && rir <= 1.0) {
      // tweak if you only show velocity for ≤1 RIR days
      // return true;
    }

    // 3) PMU detail-level switch (present in many of your plans)
    final detail = PeriodizationModelUtils.plannedExerciseDetails[exerciseId]
        ?? PeriodizationModelUtils.plannedExerciseDetails[exerciseName];
    if (detail is Map && detail['velocityEnabled'] == true) return true;

    // 4) Model-based heuristic (kept conservative to avoid flicker)
    final model = PeriodizationModelUtils.exercisePeriodizationModels[exerciseId]
        ?? PeriodizationModelUtils.exercisePeriodizationModels[exerciseName];
    if (model != null && model.toString().contains('velocity')) return true;

    return false;
  }




  // Anchor A: add inside _WorkoutPageState
  Future<void> _paintFromSnapshotIfAny() async {
    // Tripwire 1: Phase 0 already painted — skip entirely
    if (_claudeBulletPhase0Active) return;

    if (_bootPaintDone) return;
    _bootPaintDone = true;

    try {
      final uid = _cachedUid ?? UserContext.of(context, listen: false).currentUid;
      final bid = _selectedBlockId ?? _activeBlockId;
      final date = _selectedDate ?? DateTime.now();
      if ((uid == null || uid.isEmpty) || bid == null) return;

      final ymd = DateFormat('yyyy-MM-dd').format(date);

      // ⏩ Strictly local read (no network)
      final snap = await BlockPlanCache.getInitSnapshot(
        uid: uid,
        blockId: bid,
        dateYmd: ymd,
      );


      if (snap != null) {

      } else {
        print('🟣 [FastPaint] No snapshot found for $ymd');
      }
      if (snap == null) {
        // No snapshot, but we may still have an in-memory draft from previous
        // dispose. The backup _loadWorkoutDraftFromCache path will pick it up.
        if (_exitDraft != null && _exitDraft!['dateKey'] == ymd) {
          debugPrint('[WES_REENTER] _paintFromSnapshotIfAny: no snapshot but '
              'in-memory draft exists — will be consumed by draft loader');
        }
        return;
      }

      // Decode planned rows (preferred) or previous overlay
      final List planned = snap.plannedExercisesJson.isNotEmpty
          ? (jsonDecode(snap.plannedExercisesJson) as List)
          : const [];
      final List prev = snap.previousWorkoutJson.isNotEmpty
          ? (jsonDecode(snap.previousWorkoutJson) as List)
          : const [];

      // Build rows in memory (no setState yet) — de-dupe by NAME ONLY
      final tmpRows = <Map<String, dynamic>>[];
      final Set<String> _seenNames = <String>{};
      int _plannedIdx = 0;
      int _prevIdx = 0;

      String _kName(String n) {
        var t = n.toLowerCase().trim();
        t = t.replaceAll(RegExp(r'\([^)]*\)'), '');       // strip parentheses text
        t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');    // punctuation → space
        t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
        t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');  // common abbrev norms
        t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
        return t;
      }

      if (planned.isNotEmpty) {
        for (final e in planned) {
          final m = Map<String, dynamic>.from(e as Map);
          final name = (m['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;

          // keep whichever circuitIndex the first occurrence has; ignore later ones
          final ci = (m['circuitIndex'] is int)
              ? m['circuitIndex'] as int
              : int.tryParse('${m['circuitIndex'] ?? 0}') ?? 0;

          final kn = _kName(name);
          if (_seenNames.contains(kn)) {
            // print('🧹 [FastPaint] skipped duplicate by name: $kn');
            continue;
          }
          _seenNames.add(kn);

          tmpRows.add({
            'name': name,
            'circuitIndex': ci,
            // stable per-snapshot, per-date id
            'cardId': '$ymd|plan|$_plannedIdx|$kn',
          });
          _plannedIdx++;
        }
      } else {
        // No planned rows for this date → do not auto-seed from previousWorkoutJson.
        // Leave tmpRows empty to avoid “ghost” exercises.
      }

      if (tmpRows.isEmpty) return;


      // Parse hints and map to a form WES expects (re-key to name|ci)
      final Map<String, Map<String, dynamic>> hintsByKey = {};
      if (snap.hintsJson.isNotEmpty && snap.hintsJson != '{}') {
        final raw = Map<String, dynamic>.from(jsonDecode(snap.hintsJson));

        for (final e in raw.entries) {
          if (e.value is! Map) continue;
          final v = Map<String, dynamic>.from(e.value as Map);

          // Snapshot map key (may already be "exerciseId|ci" OR legacy "nameLower|ci")
          final String rawKey = e.key.toString().trim();
          if (rawKey.isEmpty) continue;

          // Keep these because later logic relies on them
          final name = (v['name'] ?? '').toString().trim();
          final ci = (v['circuitIndex'] is num) ? (v['circuitIndex'] as num).toInt() : 0;

          // Legacy key (what your old code used)
          final String keyByName = name.isEmpty ? '' : '${name.toLowerCase()}|$ci';

          // New key (stable)
          final String exId = (name.isEmpty)
              ? ''
              : (PeriodizationModelUtils.nameToId[name] ?? name).toString().trim();
          final String keyById = exId.isEmpty ? '' : '$exId|$ci';

          // Choose a canonical rowKey for prints + RIR override
          // Prefer name-key if we have a name, else fall back to rawKey
          final String rowKey = keyByName.isNotEmpty ? keyByName : rawKey;

          final s1W  = (v['s1_weight'] as num?)?.toDouble();
          final s1WA = (v['s1_weight_added'] as num?)?.toDouble();
          final s1R  = (v['s1_reps'] as num?)?.toDouble();
          final s1Ri = (v['s1_rir'] as num?)?.toDouble();
          final e1   = (v['e1rm'] as num?)?.toDouble();

          // NEW: completion flags from Warmup (if present)
          final bool completed = (v['completed'] == true);
          final List completedSets = (v['completedSets'] is List)
              ? (v['completedSets'] as List)
              : const [];

          // NEW: pull planned RIRs for sets 2–8 if present
          final s2Ri = (v['s2_rir'] as num?)?.toDouble();
          final s3Ri = (v['s3_rir'] as num?)?.toDouble();
          final s4Ri = (v['s4_rir'] as num?)?.toDouble();
          final s5Ri = (v['s5_rir'] as num?)?.toDouble();
          final s6Ri = (v['s6_rir'] as num?)?.toDouble();
          final s7Ri = (v['s7_rir'] as num?)?.toDouble();
          final s8Ri = (v['s8_rir'] as num?)?.toDouble();

          final Map<String, dynamic> normalized = {
            's1_weight'       : s1W,
            's1_weight_added' : s1WA,
            's1_reps'         : s1R,
            's1_rir'          : s1Ri,
            'e1rm'            : e1,

            if (s2Ri != null) 's2_rir': s2Ri,
            if (s3Ri != null) 's3_rir': s3Ri,
            if (s4Ri != null) 's4_rir': s4Ri,
            if (s5Ri != null) 's5_rir': s5Ri,
            if (s6Ri != null) 's6_rir': s6Ri,
            if (s7Ri != null) 's7_rir': s7Ri,
            if (s8Ri != null) 's8_rir': s8Ri,

            // Aliases
            'weight'          : s1W,
            'absWeight'       : s1W,
            'reps'            : s1R,
            'rir'             : s1Ri,

            // NEW: completion flags & sets
            'completed'       : completed,
            'completedSets'   : completedSets,
          };

          // ✅ Store under ALL reasonable keys (so later lookups succeed)
          // 1) rawKey (whatever the snapshot actually used)
          hintsByKey[rawKey] = normalized;

          // 2) legacy nameLower|ci
          if (keyByName.isNotEmpty) {
            hintsByKey.putIfAbsent(keyByName, () => normalized);
          }

          // 3) new exerciseId|ci
          if (keyById.isNotEmpty) {
            hintsByKey.putIfAbsent(keyById, () => normalized);
          }

          // 🔁 Override RIR hints with rotated pick from today's planned occurrence (null-safe)
          try {
            if (name.isNotEmpty) {
              final exIdForPlan = PeriodizationModelUtils.nameToId[name] ?? name;

              // Resolve dates safely (respects BP week-start because your helpers do)
              final DateTime? start = _blockStartDate ?? blockStartDate;
              final DateTime? sel   = _selectedDate;
              if (start == null || sel == null) {
                print('🟨 [FastPaint RIR Override] skip: missing dates (start=$start sel=$sel)');
              } else {
                // 1) Determine week for this exercise
                final int? weekIndex = _getApplicableWeekIndex(exIdForPlan);
                if (weekIndex == null) {
                  print('🟨 [FastPaint RIR Override] skip: weekIndex=null for $exIdForPlan');
                } else {
                  final String weekKey = 'week${weekIndex + 1}';

                  // 2) Raw occurrence index this week (up to + incl. today)
                  final int rawSessionIndex =
                  PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
                    exerciseName: name,
                    savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
                    blockStartDate: start,
                    weekIndex: weekIndex,
                    selectedDate: sel,
                  );

                  // 3) Effective frequency from repTargets (fallback 1)
                  final Map<String, dynamic>? repTargets =
                  (PeriodizationModelUtils.plannedExerciseDetails[exIdForPlan]?['repTargets'] as Map?)
                      ?.cast<String, dynamic>();
                  final Map<String, dynamic> wk1 =
                      (repTargets?['week1'] as Map?)?.cast<String, dynamic>() ?? const {};
                  final int effectiveFreq =
                  wk1.keys.where((k) => k.toString().startsWith('instance')).length.clamp(1, 99);

                  // 4) Rotate raw index into session key
                  final int desiredSessionIndex = (rawSessionIndex % effectiveFreq);
                  final String sessionKey = 'session${desiredSessionIndex + 1}';

                  // 5) Read planned RIRs for sets 1..8
                  final Map<String, dynamic>? rirPlan =
                  (PeriodizationModelUtils.plannedExerciseDetails[exIdForPlan]?['rirPlan'] as Map?)
                      ?.cast<String, dynamic>();
                  final Map<String, dynamic> weekData =
                      (rirPlan?[weekKey] as Map?)?.cast<String, dynamic>() ?? const {};
                  final Map<String, dynamic> sessionData =
                      (weekData[sessionKey] as Map?)?.cast<String, dynamic>() ?? const {};

                  double? _rirForSet(int setNo) {
                    final setKey = 'set$setNo';
                    final vv = (sessionData[setKey] as Map?)?['rir'];
                    if (vv == null) return null;
                    final s = vv.toString().trim();
                    if (s.isEmpty) return null;
                    return double.tryParse(s);
                  }

                  // 6) Ensure non-null hint map and write overrides (write into canonical rowKey)
                  final Map<String, dynamic> hb = hintsByKey[rowKey] ?? <String, dynamic>{};
                  hintsByKey[rowKey] = hb;

                  final s1o = _rirForSet(1);
                  if (s1o != null) {
                    hb['rir']    = s1o;
                    hb['s1_rir'] = s1o;
                  }
                  for (int setNo = 2; setNo <= 8; setNo++) {
                    final vv = _rirForSet(setNo);
                    if (vv != null) hb['s${setNo}_rir'] = vv;
                  }

                  // 7) Debug
                  print(
                    '🟪 [FastPaint RIR Override] ${name.toLowerCase()}|$ci '
                        '→ s1=${hintsByKey[rowKey]?['s1_rir']} '
                        's2=${hintsByKey[rowKey]?['s2_rir']} '
                        's3=${hintsByKey[rowKey]?['s3_rir']} '
                        '(week=$weekKey session=session${desiredSessionIndex + 1} '
                        'raw=$rawSessionIndex freq=$effectiveFreq)',
                  );

                  // 8) Merged locals (kept to match your structure)
                  final double? s1RiMerged =
                      (hintsByKey[rowKey]?['s1_rir'] as num?)?.toDouble() ?? s1Ri;
                  final double? s2RiMerged =
                      (hintsByKey[rowKey]?['s2_rir'] as num?)?.toDouble() ?? s2Ri;
                  final double? s3RiMerged =
                      (hintsByKey[rowKey]?['s3_rir'] as num?)?.toDouble() ?? s3Ri;

                  final _rirMergedForDebug = <int, double?>{
                    1: s1RiMerged,
                    2: s2RiMerged,
                    3: s3RiMerged,
                  };
                }
              }
            }
          } catch (e) {
            print('🟥 [FastPaint RIR Override] failed for "$name": $e');
          }

          // Short debug
          final rirs = [
            if (s1Ri != null) 's1=$s1Ri',
            if (s2Ri != null) 's2=$s2Ri',
            if (s3Ri != null) 's3=$s3Ri',
          ].join(' ');
          print('🟣 [FastPaint→Hints] $rowKey → '
              'weight=${s1W ?? '—'} added=${s1WA ?? '—'} reps=${s1R ?? '—'} rir: $rirs');
        }

      }

      // Seed hints map now (used by other paths later)
      _seedHintsByKey
        ..clear()
        ..addAll(hintsByKey);
// Preserve any user-typed text from existing controllers (if this runs again)
      final prevWtsCtr   = _weightControllers;
      final prevRepsCtr  = _repsControllers;
      final prevRirCtr   = _rirControllers;
// (Optional, if you want to preserve velocity/notes too)
// final prevVelCtr   = _velocityControllers;
// final prevNotesCtr = _notesControllers;

      // 🔑 Build maps of previous controllers keyed by exerciseId|circuitIndex
      final Map<String, List<TextEditingController>> prevWtsByKey  = {};
      final Map<String, List<TextEditingController>> prevRepsByKey = {};
      final Map<String, List<TextEditingController>> prevRirByKey  = {};

      for (var i = 0; i < _selectedExercisesWithCircuits.length; i++) {
        final row  = _selectedExercisesWithCircuits[i];
        final name = ((row['name'] ?? '') as String).trim();
        if (name.isEmpty) continue;

        final int ci = (row['circuitIndex'] is int)
            ? row['circuitIndex'] as int
            : int.tryParse('${row['circuitIndex'] ?? 0}') ?? 0;

        // Uses exercise ID primarily, with fallback to name
        final String key = _wesKeyPrefId(name, ci);

        if (i < prevWtsCtr.length)  prevWtsByKey[key]  = prevWtsCtr[i];
        if (i < prevRepsCtr.length) prevRepsByKey[key] = prevRepsCtr[i];
        if (i < prevRirCtr.length)  prevRirByKey[key]  = prevRirCtr[i];
      }



      // ⚙️ Build controllers and sets in locals and hydrate BEFORE setState
      final List<List<SetDetails>> tmpSets = [];
      final List<List<TextEditingController>> tmpReps = [];
      final List<List<TextEditingController>> tmpWts = [];
      final List<List<TextEditingController>> tmpRir = [];
      final List<List<TextEditingController>> tmpVel = [];
      final List<List<TextEditingController>> tmpNotes = [];

      for (var i = 0; i < tmpRows.length; i++) {
        // 🔢 Use the same planned-set logic as everywhere else
        final int setCount = _plannedSetCountFor(i);

        tmpSets.add(List.generate(setCount, (_) => SetDetails()));
        tmpReps.add(List.generate(setCount, (_) => TextEditingController()));
        tmpWts.add(List.generate(setCount, (_) => TextEditingController()));
        tmpRir.add(List.generate(setCount, (_) => TextEditingController()));
        tmpVel.add(List.generate(setCount, (_) => TextEditingController()));
        tmpNotes.add(List.generate(setCount, (_) => TextEditingController()));
      }


      // Hydrate set-1 from hints (with BW conversion) directly into tmp controllers
      for (var i = 0; i < tmpRows.length; i++) {
        final name = (tmpRows[i]['name'] ?? '').toString().trim();
        final ci   = (tmpRows[i]['circuitIndex'] ?? 0) as int;
        if (name.isEmpty) continue;


        final String ctrlKey = _wesKeyPrefId(name, ci);
        final prevWtsRow  = prevWtsByKey[ctrlKey];
        final prevRepsRow = prevRepsByKey[ctrlKey];
        final prevRirRow  = prevRirByKey[ctrlKey];


        final exId = (PeriodizationModelUtils.nameToId[name] ?? name).toString().trim();
        final isBw = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: name);

        final String keyById = '$exId|$ci';
        final String keyByName = '${name.toLowerCase()}|$ci';
        final h = hintsByKey[keyById] ?? hintsByKey[keyByName];
        if (h == null) continue;

        // NEW: if the row is completed, hydrate from completedSets and skip the hint path
        final bool isCompleted = (h['completed'] == true);

        if (isCompleted) {
          final List cs = (h['completedSets'] is List) ? (h['completedSets'] as List) : const [];
          final int maxSets = (_defaultSets < cs.length) ? _defaultSets : cs.length;

          for (var k = 0; k < maxSets; k++) {
            final m = Map<String, dynamic>.from(cs[k] as Map);

            // Pull normalized fields (these were normalized by Warmup)
            final double? absW   = (m['weight'] as num?)?.toDouble();
            final double? addW   = (m['addedWeight'] as num?)?.toDouble();
            final int?    reps   = (m['reps'] as num?)?.toInt();
            final double? rir    = (m['rir'] as num?)?.toDouble();
            final double? vel    = (m['velocity'] as num?)?.toDouble();
            final String? notes  = (m['notes'] as String?);

            // Convert to display weight for BW exercises (prefer addedWeight)
            double? displayWeight;
            if (isBw) {
              if (addW != null) {
                displayWeight = addW;
              } else if (absW != null) {
                displayWeight = PeriodizationModelUtils.toDisplayAddedWeight(
                  uid: uid,
                  absoluteKg: absW,
                  exerciseId: exId,
                  exerciseName: name,
                  asOfDate: _selectedDate,
                );
              }
            } else {
              displayWeight = absW;
            }

            // Controllers text — set actual values (not hints)
            // Controllers text — keep any user-entered text from previous controllers
            // for THIS exercise (by exerciseId|circuitIndex), otherwise use completed value.
            String? userWt, userReps, userRir;

            // weight
            if (prevWtsRow != null && k < prevWtsRow.length) {
              final prev = prevWtsRow[k];
              if (prev.text.isNotEmpty) userWt = prev.text;
            }
            // reps
            if (prevRepsRow != null && k < prevRepsRow.length) {
              final prev = prevRepsRow[k];
              if (prev.text.isNotEmpty) userReps = prev.text;
            }
            // rir
            if (prevRirRow != null && k < prevRirRow.length) {
              final prev = prevRirRow[k];
              if (prev.text.isNotEmpty) userRir = prev.text;
            }

            if (k < tmpWts[i].length)   tmpWts[i][k].text  = userWt   ?? ((displayWeight == null) ? '' : displayWeight.toString());
            if (k < tmpReps[i].length)  tmpReps[i][k].text = userReps ?? ((reps == null) ? '' : reps.toString());
            if (k < tmpRir[i].length)   tmpRir[i][k].text  = userRir  ?? ((rir == null) ? '' : rir.toString());


            if (k < tmpVel[i].length && vel != null)   tmpVel[i][k].text   = vel.toString();
            if (k < tmpNotes[i].length && notes != null && notes.trim().isNotEmpty) {
              tmpNotes[i][k].text = notes.trim();
            }

            // SetDetails (kept for non-controller readers)
            if (k < tmpSets[i].length) {
              tmpSets[i][k].weight = displayWeight;
              tmpSets[i][k].reps   = reps;
              tmpSets[i][k].rir    = rir;
              // If your SetDetails class has velocity/notes fields, assign here too:
              // tmpSets[i][k].velocity = vel;
              // tmpSets[i][k].notes = notes?.trim();
            }
          }

          // Clear any remaining sets (so they appear empty/hidden depending on your UI)
          for (var k = maxSets; k < _defaultSets && k < tmpWts[i].length; k++) {
            tmpWts[i][k].text  = '';
            tmpReps[i][k].text = '';
            tmpRir[i][k].text  = '';
            // optional: tmpVel/tmpNotes left empty
            if (k < tmpSets[i].length) {
              tmpSets[i][k].weight = null;
              tmpSets[i][k].reps   = null;
              tmpSets[i][k].rir    = null;
            }
          }

          print('✅ [FastPaint Completed] ${name}|$ci → hydrated ${maxSets} set(s) from completedSets');
          continue; // ⬅️ very important: skip the hint path below
        }


        final abs = (h['s1_weight'] as num?)?.toDouble();
        final add = (h['s1_weight_added'] as num?)?.toDouble();

        double? displayWeight;
        if (isBw) {
          if (add != null) {
            displayWeight = add;
          } else if (abs != null) {
            displayWeight = PeriodizationModelUtils.toDisplayAddedWeight(
              uid: uid,
              absoluteKg: abs,
              exerciseId: exId,
              exerciseName: name,
              asOfDate: _selectedDate,
            );
          }
        } else {
          displayWeight = abs;
        }

        final reps = (h['s1_reps'] as num?)?.toInt();
        final rir  = (h['s1_rir'] as num?)?.toString();

        // Controllers (Set 1): keep any user-entered text from previous controllers
        // for THIS exercise (by exerciseId|circuitIndex); else keep empty so hint shows.
        String? userWt, userReps, userRir;

        if (prevWtsRow != null && prevWtsRow.isNotEmpty) {
          final prev = prevWtsRow[0];
          if (prev.text.isNotEmpty) userWt = prev.text;
        }
        if (prevRepsRow != null && prevRepsRow.isNotEmpty) {
          final prev = prevRepsRow[0];
          if (prev.text.isNotEmpty) userReps = prev.text;
        }
        if (prevRirRow != null && prevRirRow.isNotEmpty) {
          final prev = prevRirRow[0];
          if (prev.text.isNotEmpty) userRir = prev.text;
        }

        // Set the new controllers to the user’s prior text if present; else keep empty to show hint
        tmpWts[i][0].text  = userWt   ?? '';
        tmpReps[i][0].text = userReps ?? '';
        tmpRir[i][0].text  = userRir  ?? '';



        print('🟢 [FastPaint Row $i] ${name}|$ci '
            '→ HINT weight=${displayWeight ?? '—'} reps=${reps ?? '—'} rir=${rir ?? '—'} '
            '(isBW=$isBw)');

        // SetDetails for non-controller readers (Set 1)
        tmpSets[i][0].weight = displayWeight;
        tmpSets[i][0].reps   = reps;
        tmpSets[i][0].rir    = double.tryParse(rir ?? '');

        // 🔒 Preserve user-typed values for Set 2+ from the prior controllers
        // for THIS exercise (by exerciseId|circuitIndex).
        final int _maxSets = _defaultSets;
        for (var k = 1; k < _maxSets; k++) {
          // weight
          if (prevWtsRow != null && k < prevWtsRow.length) {
            final t = prevWtsRow[k].text.trim();
            if (t.isNotEmpty) tmpWts[i][k].text = t;
          }
          // reps
          if (prevRepsRow != null && k < prevRepsRow.length) {
            final t = prevRepsRow[k].text.trim();
            if (t.isNotEmpty) tmpReps[i][k].text = t;
          }
          // RIR
          if (prevRirRow != null && k < prevRirRow.length) {
            final t = prevRirRow[k].text.trim();
            if (t.isNotEmpty) tmpRir[i][k].text = t;
          }
          // (Optional: preserve velocity/notes typed by user too)
          // if (prevVelRow != null && k < prevVelRow.length) { ... }
          // if (prevNotesRow != null && k < prevNotesRow.length) { ... }
        }


        // ✅ Also hydrate RIR for sets 2–8 from hints if present (as hints, not user input)
        for (var setNo = 2; setNo <= _defaultSets && setNo <= 8; setNo++) {
          final rirKey = 's${setNo}_rir';
          final num? rirValNum = h[rirKey] as num?;
          if (rirValNum == null) continue;

          final int setIdx = setNo - 1; // setNo=2 → index 1
          if (setIdx >= tmpSets[i].length) break;

          // keep SetDetails in sync for downstream logic
          tmpSets[i][setIdx].rir = rirValNum.toDouble();

          // ❌ Do NOT set tmpRir[i][setIdx].text here → we want it to show as hint
          // tmpRir[i][setIdx].text = ...
        }



        // 🔎 Debug what we hydrated for RIR across sets
        final _rirDbg = List.generate(
          (_defaultSets <= 8 ? _defaultSets : 8),
              (k) => (h['s${k+1}_rir'] != null) ? 's${k+1}=${h['s${k+1}_rir']}' : null,
        ).whereType<String>().join(' ');
        if (_rirDbg.isNotEmpty) {
          print('🟪 [FastPaint RIR] $name|$ci → $_rirDbg');
        }
      }

      // [WES_REENTER] Overlay in-memory draft from previous dispose() if
      // available. This restores user-entered values (e.g. RIR=2.5) instantly
      // on fast re-entry, before the first frame is painted.
      if (_exitDraft != null && _exitDraft!['dateKey'] == ymd && _exitDraft!['uid'] == _cachedUid) {
        debugPrint('[WES_REENTER] _paintFromSnapshotIfAny: found in-memory draft for $ymd (uid=$_cachedUid) — overlaying');
        try {
          final draftExercises = (_exitDraft!['exercises'] as List?) ?? [];
          final draftSets = (_exitDraft!['sets'] as List?) ?? [];

          // Build lookup: lowercased name|ci → draft index
          final Map<String, int> draftLookup = {};
          for (int di = 0; di < draftExercises.length; di++) {
            final dn = (draftExercises[di]['name'] ?? '').toString().trim().toLowerCase();
            final dc = draftExercises[di]['circuitIndex'] ?? 0;
            draftLookup['$dn|$dc'] = di;
          }

          int overlaid = 0;
          for (int i = 0; i < tmpRows.length; i++) {
            final rn = (tmpRows[i]['name'] ?? '').toString().trim().toLowerCase();
            final rc = tmpRows[i]['circuitIndex'] ?? 0;
            final di = draftLookup['$rn|$rc'];
            if (di == null || di >= draftSets.length) continue;

            final draftSetList = draftSets[di] as List;
            for (int k = 0; k < draftSetList.length; k++) {
              final ds = Map<String, dynamic>.from(draftSetList[k] as Map);
              // Weight
              if (k < tmpWts[i].length && ds['weight'] != null) {
                final w = (ds['weight'] as num).toDouble();
                tmpWts[i][k].text = w == w.truncateToDouble()
                    ? w.toStringAsFixed(1) : w.toString();
                if (k < tmpSets[i].length) tmpSets[i][k].weight = w;
              }
              // Reps
              if (k < tmpReps[i].length && ds['reps'] != null) {
                tmpReps[i][k].text = ds['reps'].toString();
                if (k < tmpSets[i].length) tmpSets[i][k].reps = (ds['reps'] as num).toInt();
              }
              // RIR
              if (k < tmpRir[i].length && ds['rir'] != null) {
                final r = (ds['rir'] as num).toDouble();
                tmpRir[i][k].text = r == r.truncateToDouble()
                    ? r.toStringAsFixed(1) : r.toString();
                if (k < tmpSets[i].length) tmpSets[i][k].rir = r;
              }
              // Velocity
              if (k < tmpVel[i].length && ds['velocity'] != null) {
                tmpVel[i][k].text = (ds['velocity'] as num).toDouble().toStringAsFixed(2);
              }
              // Notes
              if (k < tmpNotes[i].length && ds['notes'] != null && (ds['notes'] as String).trim().isNotEmpty) {
                tmpNotes[i][k].text = (ds['notes'] as String).trim();
              }
              overlaid++;
            }
          }
          debugPrint('[WES_REENTER] _paintFromSnapshotIfAny: overlaid $overlaid set(s) from in-memory draft');
        } catch (e) {
          debugPrint('[WES_REENTER] _paintFromSnapshotIfAny: draft overlay error: $e');
        }
        _exitDraft = null; // consumed
      } else if (_exitDraft != null) {
        debugPrint('[WES_REENTER] _paintFromSnapshotIfAny: in-memory draft exists but dateKey=${_exitDraft!['dateKey']} != $ymd — skipping');
      }

      // ✅ One paint: assign fully hydrated state
      setState(() {
        _selectedExercisesWithCircuits
          ..clear()
          ..addAll(tmpRows);

        _workoutSets
          ..clear()
          ..addAll(tmpSets);
        _repsControllers
          ..clear()
          ..addAll(tmpReps);
        _weightControllers
          ..clear()
          ..addAll(tmpWts);
        _rirControllers
          ..clear()
          ..addAll(tmpRir);
        _velocityControllers
          ..clear()
          ..addAll(tmpVel);
        _notesControllers
          ..clear()
          ..addAll(tmpNotes);

        _didFastPaint = true;
        _isInitialized = true;
        _isLoadingData = false;
      });

      print('👀 [FastPaint Post] rows=${_selectedExercisesWithCircuits.length} '
          'sets=${_workoutSets.length} repsCtr=${_repsControllers.length} '
          'wtsCtr=${_weightControllers.length} rirCtr=${_rirControllers.length} '
          'init=$_isInitialized load=$_isLoadingData didFast=$_didFastPaint');

      _debugRowSetCounts('[FastPaint end]');
      _debugLogCardsForSelectedDate('FastPaint');

      // ── Claude_bullet Line 0: attempt resume-like restore ──
      // This must happen AFTER exercises + controllers are initialized
      // but BEFORE the first visual frame so the user sees exact state.
      final cbRestored = await Claude_bulletTryRestoreFullDayUiSnapshot();
      if (cbRestored) {
        print('[Claude_bullet] Line 0 restore succeeded — skipping heavy hint boot for initial load');
        if (mounted) setState(() {});
      }

      if (!_firstRowsLogged && _selectedExercisesWithCircuits.isNotEmpty) {
        _firstRowsLogged = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          print('🟢 [WES UI] First frame painted from ISAR hints (no defaults).');
        });
      }

      if (_hasOpenedOnce) {
        print('🟢 [WES] _scheduleHeavyWork triggered via date change (not first open)');
      //  _scheduleHeavyWork();
      } else {
        print('🟣 [WES] First open → running immediate self-heal (no scheduled delay)');
        unawaited(_verifyAndSelfHealIfStale());
        _hasOpenedOnce = true;
      }



    } catch (e, st) {
      print('⚠️ [_paintFromSnapshotIfAny] error: $e');
      print(st);
    }
  }


  Future<void> _loadExistingWorkoutIfAny() async {
    final _tLoadExisting = Stopwatch()
      ..start();
    print('⏱️ [WES] _loadExistingWorkoutIfAny started');
    print('👀 [LoadExisting Pre] rows=${_selectedExercisesWithCircuits.length} '
        'sets=${_workoutSets.length} repsCtr=${_repsControllers.length} '
        'wtsCtr=${_weightControllers.length} rirCtr=${_rirControllers.length} '
        'init=$_isInitialized load=$_isLoadingData didFast=$_didFastPaint');

    try {
      final uid = UserContext
          .of(context, listen: false)
          .currentUid ?? FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      final workoutsCol = FirebaseFirestore.instance.collection('users').doc(
          uid).collection('workouts');
      final String newDocId = _workoutDocIdForDate(
          _selectedDate); // e.g. 2025-08-24
      final DateTime startOfDay = DateTime(
          _selectedDate.year, _selectedDate.month, _selectedDate.day);
      final DateTime nextDay = startOfDay.add(const Duration(days: 1));


      // ⬇️ SUPER-CACHE: try local Isar first for instant hydration
      try {
        final isarList = await BlockPlanCache.getDay(
          uid: uid,
          blockId: _selectedBlockId ?? '',
          weekIndex: PeriodizationModelUtils.getWeekIndexForDate(
              _selectedDate, blockStartDate!),
          dayIndex: _selectedDate
              .difference(blockStartDate!)
              .inDays % 7,
        );
        if (isarList != null && isarList.isNotEmpty) {
          // TODO: hydrate state/controllers if you want ISAR data to render immediately
        }
      } catch (e) {
      }

      // 1) Primary: new-style doc keyed by date string
      // --- BEGIN UNION LOOKUP (new-style preferred; include legacy-only) ---
      // Helpers kept local so names don't leak
      List<Map<String, dynamic>> _exListFromDoc(
          DocumentSnapshot<Map<String, dynamic>>? d) {
        if (d == null || !d.exists) return const [];
        final data = d.data();
        if (data == null) return const [];
        final raw = (data['exercises'] as List?) ?? const [];
        return raw.map<Map<String, dynamic>>((e) =>
        Map<String, dynamic>.from(e as Map)).toList();
      }

      List<Map<String, dynamic>> _wesPlannedFromDoc(
          DocumentSnapshot<Map<String, dynamic>>? d) {
        if (d == null || !d.exists) return const [];
        final data = d.data();
        if (data == null) return const [];
        final raw = (data['wesPlannedExercises'] as List?) ?? const [];
        return raw.map<Map<String, dynamic>>((e) =>
        Map<String, dynamic>.from(e as Map)).toList();
      }

      // Variables the rest of the function expects
      List exList = const [];
      List<Map<String, dynamic>> wesPlannedList = const [];

      bool _usedFastPath = false;
      // ⚡ FAST PATH: WESInitSnapshot → immediate overlay of previous sets if present
      try {
        final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);
        final snap = await BlockPlanCache.getInitSnapshot(
          uid: uid!,
          blockId: _selectedBlockId ?? (_activeBlockId ?? ''),
          dateYmd: ymd,
        );
        if (snap == null || snap.dateYmd != ymd) {
          print('🛑 [FastPaint] ignoring snapshot (null or date mismatch)');
          // do NOT return here
        }



        if (snap != null) {
          // planned rows (name + ci) for placeholders
          final planned = snap.plannedExercisesJson.isNotEmpty
              ? (jsonDecode(snap.plannedExercisesJson) as List)
              : const [];

          // previous overlay: sets for those rows
          final prev = snap.previousWorkoutJson.isNotEmpty
              ? (jsonDecode(snap.previousWorkoutJson) as List)
              : const [];

          if (planned.isNotEmpty || prev.isNotEmpty) {
            // Build exList from the overlay snapshot (so the rest of the code can reuse it)
            exList =
                prev.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(
                    e as Map)).toList();
            wesPlannedList = planned.map<Map<String, dynamic>>((e) => Map<
                String,
                dynamic>.from(e as Map)).toList();
            _usedFastPath = true;

            // Minimal UI tick now: we’ll reuse the normal overlay logic below.
            // (We still run server union in the background for reconciliation.)
            // ignore: unawaited_futures
            (() async {
              try {
                // Trigger the legacy/server union path in the background to reconcile
                // Just re-call this function slowly in the background? No—better to run the
                // server fetchers directly here, but to keep the change small, we let the
                // normal flow continue below since we haven’t returned.
              } catch (_) {}
            })();
          }
          // 🔁 HINTS NORMALIZATION (Warmup → WES expected keys)
// Warmup: s1_weight, s1_weight_added, s1_reps, s1_rir
// WES expects (when seeding first-frame fields): weight, absWeight, reps, rir
          try {
            if ((snap.hintsJson ?? '').isNotEmpty) {
              final Map<String, dynamic> rawHints =
              Map<String, dynamic>.from(jsonDecode(snap.hintsJson));

              _seedHintsByKey.clear();

              // Helper: normalize a legacy "name|ci" key into "exerciseId|ci" when possible.
              String? _aliasToExerciseIdKey(String rawKey) {
                final k = rawKey.toString().trim();
                final parts = k.split('|');
                if (parts.length != 2) return null;

                final left = parts[0].trim(); // could be legacy name (maybe lowercased), or already an id
                final ci = parts[1].trim();

                // 1) Direct hit: left matches a nameToId entry exactly
                final direct = PeriodizationModelUtils.nameToId[left];
                if (direct != null && direct.toString().trim().isNotEmpty) {
                  return '${direct.toString().trim()}|$ci';
                }

                // 2) Legacy writer often used lowercase name. Try to find a nameToId key case-insensitively.
                try {
                  final String leftLower = left.toLowerCase();
                  for (final entry in PeriodizationModelUtils.nameToId.entries) {
                    final kName = entry.key.toString();
                    if (kName.toLowerCase() == leftLower) {
                      final id = entry.value.toString().trim();
                      if (id.isNotEmpty) return '$id|$ci';
                    }
                  }
                } catch (_) {}

                // 3) If left already *looks like* an id (you sometimes used id directly), just pass it through.
                // (No perfect test here; safest is: if it’s not empty, allow it.)
                if (left.isNotEmpty) {
                  return '${left.trim()}|$ci';
                }

                return null;
              }

              rawHints.forEach((rowKeyRaw, v) {
                final rowKey = rowKeyRaw.toString().trim();
                if (v is! Map) return;

                final m = Map<String, dynamic>.from(v as Map);

                final abs = (m['s1_weight'] ?? m['absWeight']);
                final added = (m['s1_weight_added'] ?? m['displayAdded']);
                final reps = (m['s1_reps'] ?? m['reps']);
                final rir  = (m['s1_rir'] ?? m['rir']);

                final normalized = <String, dynamic>{
                  // WES-expected generic names:
                  'weight'    : abs,
                  'absWeight' : abs,
                  'reps'      : reps,
                  'rir'       : rir,

                  // Warmup (S1) names kept for _getProgressedValues() fast path:
                  's1_weight'        : m['s1_weight'],
                  's1_weight_added'  : m['s1_weight_added'],
                  's1_reps'          : m['s1_reps'],
                  's1_rir'           : m['s1_rir'],
                };

                // 1) Store the raw key exactly as stored in snapshot (back-compat)
                _seedHintsByKey[rowKey] = normalized;

                // 2) Store exerciseId|ci alias key (new scheme), without overwriting if already present
                final alias = _aliasToExerciseIdKey(rowKey);
                if (alias != null && alias.isNotEmpty) {
                  _seedHintsByKey.putIfAbsent(alias, () => normalized);
                }
              });

              print('🟢 [WES Hints] Seeded ${_seedHintsByKey.length} hint rows from snapshot.');

              // Optional: only dump a few to avoid log spam
              int _dumped = 0;
              for (final e in _seedHintsByKey.entries) {
                debugPrint('🧪 [WES SeedDump] ${e.key} → ${e.value}');
                if (++_dumped >= 12) break;
              }
            }
          } catch (e) {
            print('⚠️ [WES Hints] Failed to parse/normalize hintsJson: $e');
          }


        }
      } catch (e) {
        print('⚠️ [WES LoadExisting] Snapshot fast-path failed: $e');
      }


      // FAST PATH: cache-first new-style → render immediately if present; reconcile legacy in background
      DocumentSnapshot<Map<String, dynamic>>? _newDocCache;
      try {
        _newDocCache = await workoutsCol.doc(newDocId).get(
            const GetOptions(source: Source.cache));
      } catch (_) {
        _newDocCache = null;
      }


      if (_newDocCache != null && _newDocCache.exists) {
        final _newExListCache = _exListFromDoc(_newDocCache);
        final _wesPlannedCache = _wesPlannedFromDoc(_newDocCache);

        if (_newExListCache.isNotEmpty || _wesPlannedCache.isNotEmpty) {
          exList = _newExListCache;
          wesPlannedList = _wesPlannedCache;
          _usedFastPath = true;

// INSERT: union wesPlanned placeholders into exList (dedup by name|ci)
          String _keyOf(Map<String, dynamic> e) =>
              '${(e['name'] ?? '').toString().trim()}|${(e['circuitIndex'] is int) ? e['circuitIndex'] as int : int.tryParse('${e['circuitIndex'] ?? 0}') ?? 0}';

          final Map<String, Map<String, dynamic>> byKey = {
            for (final e in (exList.cast<Map<String, dynamic>>())) _keyOf(e): Map<String, dynamic>.from(e),
          };

// coerce wesPlanned to placeholder rows with empty sets
          for (final p in wesPlannedList) {
            final name = (p['name'] ?? '').toString().trim();
            if (name.isEmpty) continue;
            final ci = (p['circuitIndex'] is int)
                ? p['circuitIndex'] as int
                : int.tryParse('${p['circuitIndex'] ?? 0}') ?? 0;
            final k = '$name|$ci';
            byKey.putIfAbsent(k, () => {'name': name, 'circuitIndex': ci, 'sets': const <Map<String, dynamic>>[]});
          }

          exList = byKey.values.toList();

          // Background reconcile (server): pull legacy-only rows forward into new-style
          // ignore: unawaited_futures
          (() async {
            try {
              final newDocServer = await workoutsCol.doc(newDocId).get(
                  const GetOptions(source: Source.server));

              // recompute date strings here to avoid scope issues
              final String _dateOnly = DateFormat('yyyy-MM-dd').format(
                  startOfDay);
              final String _nextDateOnly = DateFormat('yyyy-MM-dd').format(
                  nextDay);
              final String _isoLocal = startOfDay.toIso8601String();
              final String _isoUtc = DateTime.utc(
                  startOfDay.year, startOfDay.month, startOfDay.day)
                  .toIso8601String();

              Future<QuerySnapshot<Map<String, dynamic>>> _eqServer(String v) =>
                  workoutsCol.where('date', isEqualTo: v).get(
                      const GetOptions(source: Source.server));

              final results = await Future.wait([
                _eqServer(_isoLocal),
                _eqServer(_isoUtc),
                _eqServer(_dateOnly),
                workoutsCol
                    .where(
                    'date', isGreaterThanOrEqualTo: '${_dateOnly}T00:00:00')
                    .where('date', isLessThan: '${_nextDateOnly}T00:00:00')
                    .get(const GetOptions(source: Source.server)),
                workoutsCol
                    .where('date',
                    isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
                    .where('date', isLessThan: Timestamp.fromDate(nextDay))
                    .get(const GetOptions(source: Source.server)),
              ]);

              final Map<String,
                  DocumentSnapshot<Map<String, dynamic>>> legacyById = {};
              for (final snap in results) {
                for (final d in snap.docs) {
                  legacyById[d.id] = d;
                }
              }

              final List<Map<String, dynamic>> legacyEx = [
                for (final d in legacyById.values) ..._exListFromDoc(d),
              ];

              final List<Map<String, dynamic>> newExServer = _exListFromDoc(
                  newDocServer);
              String _key(Map<String, dynamic> e) => '${(e['name'] ?? '')
                  .toString()
                  .trim()}|${(e['circuitIndex'] ?? 0) as int}';
              final newKeys = { for (final e in newExServer) _key(e)};

              final List<Map<String, dynamic>> legacyOnly = [
                for (final e in legacyEx) if (!newKeys.contains(_key(e))) e
              ];

              if (legacyOnly.isNotEmpty) {
                final existing = Map<String, dynamic>.from(
                    newDocServer.data() ?? {});
                final existingRows = List<Map<String, dynamic>>.from(
                  (existing['exercises'] as List?)?.map((e) =>
                  Map<String, dynamic>.from(e as Map)) ?? const [],
                );
                existingRows.addAll(legacyOnly);
                existing['exercises'] = existingRows;

                await workoutsCol.doc(newDocId).set(
                    existing, SetOptions(merge: true));
                if (mounted) setState(() {});
              }
            } catch (_) {
              // best-effort
            }
          })();
        }
      }

      if (!_usedFastPath) {
        // ───────────────────────────────────────────────────────────────
        // CACHE UNION PATH → paint immediately if cache has anything.
        // Then background reconcile from SERVER. If cache empty, fall back
        // to your original server-union logic.
        // ───────────────────────────────────────────────────────────────
        DocumentSnapshot<Map<String, dynamic>>? newDocCache;
        try {
          newDocCache = await workoutsCol.doc(newDocId).get(
              const GetOptions(source: Source.cache));
        } catch (_) {
          newDocCache = null;
        }

        final isoLocal = startOfDay.toIso8601String();
        final isoUtc = DateTime.utc(
            startOfDay.year, startOfDay.month, startOfDay.day)
            .toIso8601String();
        final dateOnly = DateFormat('yyyy-MM-dd').format(startOfDay);
        final nextDateOnly = DateFormat('yyyy-MM-dd').format(nextDay);

        Future<QuerySnapshot<Map<String, dynamic>>> _eqCache(String value) =>
            workoutsCol.where('date', isEqualTo: value)
                .get(const GetOptions(source: Source.cache));
        Future<QuerySnapshot<Map<String, dynamic>>> _rangeStrCache() =>
            workoutsCol
                .where('date', isGreaterThanOrEqualTo: '${dateOnly}T00:00:00')
                .where('date', isLessThan: '${nextDateOnly}T00:00:00')
                .get(const GetOptions(source: Source.cache));
        Future<QuerySnapshot<Map<String, dynamic>>> _rangeTsCache() =>
            workoutsCol
                .where(
                'date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
                .where('date', isLessThan: Timestamp.fromDate(nextDay))
                .get(const GetOptions(source: Source.cache));

        bool paintedFromCache = false;
        try {
          final cacheResults = await Future.wait([
            _eqCache(isoLocal),
            _eqCache(isoUtc),
            _eqCache(dateOnly),
            _rangeStrCache(),
            _rangeTsCache(),
          ]);

          final Map<String,
              DocumentSnapshot<Map<String, dynamic>>> legacyByIdCache = {};
          for (final snap in cacheResults) {
            for (final d in snap.docs) {
              legacyByIdCache[d.id] = d;
            }
          }

          final newExCache = _exListFromDoc(newDocCache);
          final legacyExCache = [
            for (final d in legacyByIdCache.values) ..._exListFromDoc(d)
          ];

          String _key(Map<String, dynamic> e) =>
              '${(e['name'] ?? '').toString().trim()}|${(e['circuitIndex'] ??
                  0) as int}';

          final newByKeyCache = {for (final e in newExCache) _key(e): e};
          final List<Map<String, dynamic>> combinedCache = [...newExCache];
          for (final e in legacyExCache) {
            final k = _key(e);
            if (!newByKeyCache.containsKey(k)) combinedCache.add(e);
          }
          final wesPlannedCache = _wesPlannedFromDoc(newDocCache);

// INSERT: union wesPlanned placeholders into combinedCache
          final Map<String, Map<String, dynamic>> cacheByKey = {
            for (final e in combinedCache) _key(e): Map<String, dynamic>.from(e),
          };
          for (final p in wesPlannedCache) {
            final name = (p['name'] ?? '').toString().trim();
            if (name.isEmpty) continue;
            final ci = (p['circuitIndex'] is int)
                ? p['circuitIndex'] as int
                : int.tryParse('${p['circuitIndex'] ?? 0}') ?? 0;
            final k = '$name|$ci';
            cacheByKey.putIfAbsent(k, () => {'name': name, 'circuitIndex': ci, 'sets': const <Map<String, dynamic>>[]});
          }
          final List<Map<String, dynamic>> combinedCacheWithWes = cacheByKey.values.toList();

          if (combinedCacheWithWes.isNotEmpty) {
            // ⚡ Paint now from cache (including WES placeholders)
            exList = combinedCacheWithWes;
            wesPlannedList = wesPlannedCache; // keep for reconcile compare
            paintedFromCache = true;

            // Background reconcile from SERVER (best-effort)
            (() async {
              try {
                DocumentSnapshot<Map<String, dynamic>>? newDocServer;
                try {
                  newDocServer = await workoutsCol.doc(newDocId).get(
                      const GetOptions(source: Source.server));
                } catch (_) {
                  newDocServer = await workoutsCol.doc(newDocId).get();
                }

                Future<QuerySnapshot<Map<String, dynamic>>> _eqServer(String v) =>
                    workoutsCol.where('date', isEqualTo: v)
                        .get(const GetOptions(source: Source.server));

                final srvResults = await Future.wait([
                  _eqServer(isoLocal),
                  _eqServer(isoUtc),
                  _eqServer(dateOnly),
                  workoutsCol
                      .where('date', isGreaterThanOrEqualTo: '${dateOnly}T00:00:00')
                      .where('date', isLessThan: '${nextDateOnly}T00:00:00')
                      .get(const GetOptions(source: Source.server)),
                  workoutsCol
                      .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
                      .where('date', isLessThan: Timestamp.fromDate(nextDay))
                      .get(const GetOptions(source: Source.server)),
                ]);

                final Map<String, DocumentSnapshot<Map<String, dynamic>>> legacyByIdSrv = {};
                for (final snap in srvResults) {
                  for (final d in snap.docs) legacyByIdSrv[d.id] = d;
                }

                final newExSrv = _exListFromDoc(newDocServer);
                final legacyExSrv = [
                  for (final d in legacyByIdSrv.values) ..._exListFromDoc(d)
                ];

                final newByKeySrv = {for (final e in newExSrv) _key(e): e};
                final List<Map<String, dynamic>> combinedSrv = [...newExSrv];
                for (final e in legacyExSrv) {
                  final k = _key(e);
                  if (!newByKeySrv.containsKey(k)) combinedSrv.add(e);
                }
                final wesPlannedSrv = _wesPlannedFromDoc(newDocServer);

                final bool changed =
                    combinedSrv.length != combinedCache.length ||
                        wesPlannedSrv.length != wesPlannedCache.length;

                if (changed) {
                  final __preStruct = _structureHash();
                  final __preS1     = _s1ValueHash();

                  // ⤵️ Actually apply combinedSrv / wesPlannedSrv to your in-memory lists & controllers here

                  final __postStruct = _structureHash();
                  final __postS1     = _s1ValueHash();

                  if (mounted && (__postStruct != __preStruct || __postS1 != __preS1)) {
                    setState(() {});
                  }
                }

              } catch (_) {
                /* best-effort */
              }
            })();

          } else {
            print(
                '🕳️ [WES LoadExisting] Cache-union empty → falling back to server union');
          }
        } catch (_) {
          print(
              '⚠️ [WES LoadExisting] Cache-union path failed → falling back to server union');
        }

        if (!paintedFromCache) {
          // ───────────────────────────────────────────────────────────────
          // ORIGINAL SLOW PATH: server-first union logic (unchanged)
          // ───────────────────────────────────────────────────────────────
          DocumentSnapshot<Map<String, dynamic>>? newDoc;
          try {
            newDoc = await workoutsCol.doc(newDocId).get(
                const GetOptions(source: Source.server));
          } catch (_) {
            newDoc = await workoutsCol.doc(newDocId).get();
          }

          Future<QuerySnapshot<Map<String, dynamic>>> _eq(String value) async {
            try {
              return await workoutsCol.where('date', isEqualTo: value)
                  .get(const GetOptions(source: Source.server));
            } catch (_) {
              return await workoutsCol.where('date', isEqualTo: value).get();
            }
          }
          final legacyStrLocal = await _eq(isoLocal);
          final legacyStrUtc = await _eq(isoUtc);
          final legacyStrDate = await _eq(dateOnly);

          QuerySnapshot<Map<String, dynamic>> legacyStrRange;
          try {
            legacyStrRange = await workoutsCol
                .where('date', isGreaterThanOrEqualTo: '${dateOnly}T00:00:00')
                .where('date', isLessThan: '${nextDateOnly}T00:00:00')
                .get(const GetOptions(source: Source.server));
          } catch (_) {
            legacyStrRange = await workoutsCol
                .where('date', isGreaterThanOrEqualTo: '${dateOnly}T00:00:00')
                .where('date', isLessThan: '${nextDateOnly}T00:00:00')
                .get();
          }

          QuerySnapshot<Map<String, dynamic>> legacyTsSnap;
          try {
            legacyTsSnap = await workoutsCol
                .where(
                'date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
                .where('date', isLessThan: Timestamp.fromDate(nextDay))
                .get(const GetOptions(source: Source.server));
          } catch (_) {
            legacyTsSnap = await workoutsCol
                .where(
                'date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
                .where('date', isLessThan: Timestamp.fromDate(nextDay))
                .get();
          }

          final Map<String,
              DocumentSnapshot<Map<String, dynamic>>> _legacyDocsById = {};
          for (final d in [
            ...legacyStrLocal.docs,
            ...legacyStrUtc.docs,
            ...legacyStrDate.docs,
            ...legacyStrRange.docs,
            ...legacyTsSnap.docs,
          ]) {
            _legacyDocsById[d.id] = d;
          }

          final List<Map<String, dynamic>> newExList = _exListFromDoc(newDoc);
          final List<Map<String, dynamic>> legacyExList = [
            for (final d in _legacyDocsById.values) ..._exListFromDoc(d),
          ];

          String _key(Map<String, dynamic> e) =>
              '${(e['name'] ?? '').toString().trim()}|${(e['circuitIndex'] ??
                  0) as int}';

          final Map<String, Map<String, dynamic>> newByKey = {
            for (final e in newExList) _key(e): e,
          };

          final List<Map<String, dynamic>> combined = [...newExList];
          for (final e in legacyExList) {
            final k = _key(e);
            if (!newByKey.containsKey(k)) {
              combined.add(e);
            }
          }

          // INSERT: union wesPlanned placeholders

          final Map<String, Map<String, dynamic>> srvByKey = {
            for (final e in combined) _key(e): Map<String, dynamic>.from(e),
          };
          final wesPlannedSrv = _wesPlannedFromDoc(newDoc);
          for (final p in wesPlannedSrv) {
            final name = (p['name'] ?? '').toString().trim();
            if (name.isEmpty) continue;
            final ci = (p['circuitIndex'] is int)
                ? p['circuitIndex'] as int
                : int.tryParse('${p['circuitIndex'] ?? 0}') ?? 0;
            final k = '$name|$ci';
            srvByKey.putIfAbsent(k, () => {'name': name, 'circuitIndex': ci, 'sets': const <Map<String, dynamic>>[]});
          }
          exList = srvByKey.values.toList();
          wesPlannedList = wesPlannedSrv;
        }
      }

// --- END UNION LOOKUP ---


      // Mark saved keys from Firestore (for coloring/collapse)
      for (final e in exList) {
        if (e is! Map) continue;
        final name = (e['name'] as String?)?.trim() ?? 'Unnamed';
        final circuitIndex = (e['circuitIndex'] ?? 0) as int;
        if (e['savedAt'] != null) {
          _savedExerciseKeysForDate.add(_exerciseKey(name, circuitIndex));
        }
      }

      // 5) === SILENT RECONCILE: update in place (no clearing, no spinner) ===
      final List<Map<String, dynamic>> overlayRows = exList
          .whereType<Map>()
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
          .toList();




      // 6) Pass 2 (optional): add any saved exercises that aren’t in the plan/UI yet
      final existingKeys = _selectedExercisesWithCircuits
          .map<String>((e) => _exerciseKey(
        ((e['name'] ?? '') as String).trim(),
        (e['circuitIndex'] ?? 0) as int,
      ))
          .toSet();


      // 7.5) Pass 3 (NEW): merge WES-planned rows (placeholders) IN-PLACE, counting instances
      int plannedAdded = 0;
      final int beforeCount = _selectedExercisesWithCircuits.length;

// Build a NAME-only overlay of WES-planned (placeholders)
      final List<Map<String, dynamic>> plannedOverlay = wesPlannedList
          .whereType<Map>()
          .map<Map<String, dynamic>>((m0) {
        final m = Map<String, dynamic>.from(m0);
        final name = (m['name'] ?? '').toString().trim();
        if (name.isEmpty) return const <String, dynamic>{};
        final ci = (m['circuitIndex'] is int)
            ? m['circuitIndex'] as int
            : int.tryParse('${m['circuitIndex'] ?? 0}') ?? 0;
        return {
          'name': name,
          'circuitIndex': ci,
          'sets': const <Map<String, dynamic>>[], // placeholder only
        };
      })
          .where((e) => e.isNotEmpty)
          .toList();

// ---- NAME-ONLY de-dupe guard for adding planned placeholders ----
      String _ymd(DateTime d) {
        final m = d.month.toString().padLeft(2, '0');
        final day = d.day.toString().padLeft(2, '0');
        return '${d.year}-$m-$day';
      }
      String _normName(String s) {
        var t = s.toLowerCase().trim();
        t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
        t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
        t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
        t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');
        t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
        return t;
      }

      final String _dateKey = _ymd(_selectedDate);

// What names do we already have on the UI right now?
      final Set<String> _haveNames = _selectedExercisesWithCircuits
          .map((e) => _normName(((e['name'] ?? '') as String)))
          .toSet();

// Only add a planned row if that exercise NAME is not already present
      for (int j = 0; j < plannedOverlay.length; j++) {
        final n = (plannedOverlay[j]['name'] ?? '').toString().trim();
        if (n.isEmpty) continue;

        final nKey = _normName(n);
        if (_haveNames.contains(nKey)) continue; // already have a card for this exercise

        final int ci = (plannedOverlay[j]['circuitIndex'] ?? 0) as int;
        final String planExId = (PeriodizationModelUtils.nameToId[n] ?? n).trim().toLowerCase();
        final String cardId = '$_dateKey|plan|$j|$planExId';

        _selectedExercisesWithCircuits.add({
          'name': n,
          'exerciseId': planExId,
          'id': planExId,
          'circuitIndex': ci,
          'cardId': cardId,
        });

        // 🔢 Use planned set-count for this row (fallback to default)
        final int rowIndex = _selectedExercisesWithCircuits.length - 1;
        final int plannedSetCount = _plannedSetCountFor(rowIndex);
        final int setCount =
        (plannedSetCount <= 0) ? _defaultSets : plannedSetCount;

        _workoutSets.add(List.generate(setCount, (_) => SetDetails()));
        _repsControllers.add(
            List.generate(setCount, (_) => TextEditingController()));
        _weightControllers.add(
            List.generate(setCount, (_) => TextEditingController()));
        _rirControllers.add(
            List.generate(setCount, (_) => TextEditingController()));
        _velocityControllers.add(
            List.generate(setCount, (_) => TextEditingController()));
        _notesControllers.add(
            List.generate(setCount, (_) => TextEditingController()));

        _haveNames.add(nKey); // avoid any later duplicates in this pass
      }



      plannedAdded = _selectedExercisesWithCircuits.length - beforeCount;

      // 🔢 Ensure ALL rows have enough sets for their planned set-count
      for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
        final int plannedSetCount = _plannedSetCountFor(i);
        final int desiredSets =
        (plannedSetCount <= 0) ? _defaultSets : plannedSetCount;

        // Only ever grow; don’t shrink (avoids losing user-entered data)
        while (_workoutSets[i].length < desiredSets) {
          _workoutSets[i].add(SetDetails());
          _repsControllers[i].add(TextEditingController());
          _weightControllers[i].add(TextEditingController());
          _rirControllers[i].add(TextEditingController());
          _velocityControllers[i].add(TextEditingController());
          _notesControllers[i].add(TextEditingController());
        }
      }


      // 🔒 SAFETY NET: keep final order as circuit 0,1,2,... (within circuit: stable)
      _sortRowsByCircuitIndex();

      // 7) Ensure listeners on any new controllers
      _attachDirtyListeners();


      // 8) Persist merged flags so next open is instant
      await _persistSavedFlagsLocally();

      _pendingChanges = false;
      _lastSavedHash = null;

      if (exList.isEmpty && plannedAdded == 0) {
        print('   ❌ no workout items (completed or WES-planned) for this date');
      }

    } finally {
      _debugRowSetCounts('[LoadExisting end]');
      _tLoadExisting.stop();
      print('👀 [LoadExisting Exit] rows=${_selectedExercisesWithCircuits.length} '
          'sets=${_workoutSets.length} repsCtr=${_repsControllers.length} '
          'wtsCtr=${_weightControllers.length} rirCtr=${_rirControllers.length} '
          'plannedAdded=(ignored if not printed above)');

      print('⏱️ [WES] _loadExistingWorkoutIfAny took ${_tLoadExisting
          .elapsedMilliseconds}ms');
    }
  }



  Future<void> loadExercisesFromFirestoreForWES() async {
    print('➡️ [WES] loadExercisesFromFirestoreForWES START');
    final total = Stopwatch()..start();
    final getSw = Stopwatch();
    final mapSw = Stopwatch();

    int mapped = 0;

    Future<QuerySnapshot<Map<String, dynamic>>?> _getCached() async {
      try {
        return await FirebaseFirestore.instance
            .collection('exercises')
            .orderBy('name')
            .get(const GetOptions(source: Source.cache));
      } catch (_) {
        return null;
      }
    }

    Future<QuerySnapshot<Map<String, dynamic>>> _getServer() {
      return FirebaseFirestore.instance
          .collection('exercises')
          .orderBy('name')
          .get(); // server
    }

    try {
      getSw.start();
      var snapshot = await _getCached();
      if (snapshot == null || snapshot.docs.isEmpty) {
        snapshot = await _getServer();
        print('📥 [WES] exercises.get() from SERVER (docs: ${snapshot.docs.length})');
      } else {
        print('📥 [WES] exercises.get() from CACHE (docs: ${snapshot.docs.length})');
      }
      getSw.stop();

      mapSw.start();
      for (final doc in snapshot.docs) {
        final data = doc.data(); // 👈 grab once
        final id = doc.id;
        final rawName = data['name'];
        final name = rawName?.toString().trim();
        if (name != null && name.isNotEmpty) {
          PeriodizationModelUtils.nameToId[name] = id;
          PeriodizationModelUtils.idToName[id] = name;  // ⬅ anchor we patched under

          // 🔽 NEW: store type → exerciseTypeById
          final String? type = data['type'] as String?;
          if (type != null && type.isNotEmpty) {
            PeriodizationModelUtils.exerciseTypeById[id] = type;
            // optional debug:
            // print('🧩 [WES] Type mapped id="$id" name="$name" type="$type"');
          }

          mapped++;
        }
      }
      mapSw.stop();



    } catch (e, st) {
      print(st);
    } finally {
      total.stop();
    }
  }



  Future<Map<String, dynamic>> _loadPlannedExerciseDetails() async {
    // ⏱️ added
    final sw = Stopwatch()
      ..start(); // ⏱️ Start timer
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _selectedBlockId == null) return {};

    // ✅ 1. Load from BB2-style Firestore path using _selectedBlockId
    final ref = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(_selectedBlockId!);

// Cache-first load (uses warmed cache if available)
    DocumentSnapshot<Map<String, dynamic>> doc;
    try {
      final cacheDoc = await ref.get(const GetOptions(source: Source.cache));
      if (cacheDoc.exists) {
        doc = cacheDoc; // fast path: use warmed cache
      } else {
        doc =
        await ref.get(const GetOptions(source: Source.server)); // cold path
      }
    } catch (_) {
      doc = await ref.get(const GetOptions(source: Source.server)); // fallback
    }




    if (!doc.exists) {
      return {};
    }


    // ✅ 2. Extract data and handle blockMeta separately
    final data = doc.data()!;
    final blockMeta = data['blockMeta'] as Map<String, dynamic>? ?? {};
    final details = Map<String, dynamic>.from(
        data['plannedExerciseDetails'] ?? {});

    details.forEach((exerciseId, entry) {
      print('  🔍 $exerciseId → $entry');
    });
    _exerciseSettings = Map<String, Map<String, dynamic>>.from(
      (data['exerciseSettings'] ?? {}).map(
            (k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v)),
      ),
    );


    // ✅ 3. Do NOT setState() with plannedExercises — skipped by request

    // ✅ 4. Set blockStartDate and blockEndDate from meta directly
    _blockStartDate = DateTime.tryParse(blockMeta['blockStartDate'] ?? '');
    _blockEndDate = DateTime.tryParse(blockMeta['blockEndDate'] ?? '');
    print(
        '📅 [WES] Loaded blockStartDate=$_blockStartDate, blockEndDate=$_blockEndDate');
    blockStartDate = _blockStartDate;
    blockEndDate   = _blockEndDate;
    // ✅ 5. Reset PMU maps BEFORE setting anything
    PeriodizationModelUtils.plannedExerciseDetails.clear();
    PeriodizationModelUtils.exercisePeriodizationModels.clear();

    // Inject into PMU
    // Inject into PMU, but override increments with the ones from _exerciseSettings
    final mergedForPMU = <String, Map<String, dynamic>>{};

// start with details
    details.forEach((k, v) {
      mergedForPMU[k.toString()] = Map<String, dynamic>.from(v as Map);
    });

// overlay increments from _exerciseSettings (replace, don't merge)
    _exerciseSettings.forEach((exId, v) {
      final inc = v['increments'];
      if (inc != null) {
        mergedForPMU[exId] =
        Map<String, dynamic>.from(mergedForPMU[exId] ?? {});
        mergedForPMU[exId]!['increments'] = inc;

      }
    });

// now inject
    PeriodizationModelUtils.setExerciseSettings(mergedForPMU);



    // Walk each exercise entry
    details.forEach((exerciseId, entry) {
      if (entry is! Map<String, dynamic>) return;

      // Store the raw settings
      PeriodizationModelUtils.plannedExerciseDetails[exerciseId] = entry;

      // Map periodizationModel → enum
      final String? modelName = entry['periodizationModel'] as String?;
      final modelEnum = modelName != null
          ? PeriodizationModelUtils.stringToModel(modelName)
          : null;


      if (modelEnum != null) {
        PeriodizationModelUtils.exercisePeriodizationModels[exerciseId] =
            modelEnum;

      }

      // Track progressionModel if you need it later
      final progressionModel = entry['progressionModel'] ?? 'none';
      _progressionModelsByExercise[exerciseId] = progressionModel;
    });


    print('📄 [WES] Full plannedExerciseDetails loaded: ${details.keys}');
    sw.stop();
    print('⏱️ [WES] _loadPlannedExerciseDetails took ${sw
        .elapsedMilliseconds}ms');
    return details;
  }


  Future<void> _buildNameToIdMapsFromFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('planned_blocks') // ← your real root
        .doc(userId)
        .collection('blocks')
        .doc(widget.blockId)
        .get();

    final data = doc.data();
    if (data == null || !data.containsKey('plannedExerciseDetails')) {
      print('❌ [WES] No plannedExerciseDetails found in Firestore');
      return;
    }

    final rawDetails =
    Map<String, dynamic>.from(data['plannedExerciseDetails']);



    // ✅ Inject into PMU
    PeriodizationModelUtils.setExerciseSettings(rawDetails);


    // ✅ Build name ↔ ID maps
    final nameToIdMap = <String, String>{};
    final idToNameMap = <String, String>{};

    rawDetails.forEach((id, entry) {
      if (entry is Map<String, dynamic>) {
        // ✅ Try to get name directly from Firestore entry
        String? name = entry['name'];

        // ✅ Fallback: try to get it from injected _selectedExercisesWithCircuits
        if ((name == null || name
            .trim()
            .isEmpty) &&
            PeriodizationModelUtils.idToName.containsKey(id)) {
          name = PeriodizationModelUtils.idToName[id];
        }

        if (name != null && name
            .trim()
            .isNotEmpty) {
          nameToIdMap[name.trim()] = id;
          idToNameMap[id] = name.trim();

        } else {
          print('❌ [WES] Still missing name for exerciseId: $id');
        }
      }
    });

    PeriodizationModelUtils.nameToId = nameToIdMap;
    PeriodizationModelUtils.idToName.clear();
    PeriodizationModelUtils.idToName.addAll(idToNameMap);


  }


  Future<void> loadSavedWorkoutsForInstanceCount() async {
    final sw = Stopwatch()
      ..start();
    try {
      // Keep your original identity source/behavior
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final col = FirebaseFirestore.instance
          .collection('users')
          .doc(userId) // ✅ same as your original code
          .collection('workouts');

      // 1) Try cache first (fast when WarmupService has seeded)
      List<Map<String, dynamic>> workouts = const <Map<String, dynamic>>[];
      try {
        final cachedSnap = await col.get(
            const GetOptions(source: Source.cache));
        workouts = cachedSnap.docs.map((d) => d.data()).toList();
      } catch (_) {
        // cache may miss/throw on first-ever run; that's fine
      }

      // 2) If cache had anything, apply immediately
      if (workouts.isNotEmpty) {
        PeriodizationModelUtils.savedWorkoutsList =
        List<Map<String, dynamic>>.from(workouts);

      } else {
        // 3) Guarantee a server fallback (awaited) so behavior matches old code
        final serverSnap = await col.get(); // server
        workouts = serverSnap.docs.map((d) => d.data()).toList();
        PeriodizationModelUtils.savedWorkoutsList =
        List<Map<String, dynamic>>.from(workouts);

      }

      // 4) Background reconcile (non-blocking) for freshness, only if cache was used
      if (workouts.isNotEmpty) {
        unawaited(() async {
          try {
            final freshSnap = await col.get(); // server
            final fresh = freshSnap.docs.map((d) => d.data()).toList();
            if (fresh.length != workouts.length) {
              PeriodizationModelUtils.savedWorkoutsList =
              List<Map<String, dynamic>>.from(fresh);
              print('🔁 [WES] Reconciled saved workouts (server count ${fresh
                  .length})');
            }
          } catch (_) {}
        }());
      }
    } finally {
      sw.stop();
      print('⏱️ [WES] loadSavedWorkoutsForInstanceCount took ${sw
          .elapsedMilliseconds}ms');
    }
  }


  int? _getApplicableWeekIndex(String exerciseId) {
    final model =
    PeriodizationModelUtils.exercisePeriodizationModels[exerciseId];

    if (model == PeriodizationModelType.linearClassic ||
        model == PeriodizationModelType.dailyUndulatingWeek ||
        model == PeriodizationModelType.dupSignature ||
        model == PeriodizationModelType.dailyUndulatingExposure) {


      if (blockStartDate == null) return 0;

      final daysSinceStart = _selectedDate
          .difference(blockStartDate!)
          .inDays;

      final weekIndex = (daysSinceStart / 7).floor().clamp(0, 11);



      return weekIndex;
    }

    return null; // exposure-based models
  }


  @override
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    print('📱 [WES] AppLifecycleState changed: $state');
    print('📱 [WES] mounted = $mounted');

    // ✅ Disable ALL lifecycle behavior:
    // - no BB2 merge on resumed
    // - no local draft save
    // - no Firestore autosave / pendingWrites flush
    //
    // Rely on:
    // 1) inline saves (saveSingleRowToFirestore)
    // 2) dispose / back navigation saves
    return;
  }


  Future<void> _loadTemplate(Template template) async {

    // Match the cardId format used in _showExercisePickerDialog
    final String ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);
    int _ts() => DateTime.now().microsecondsSinceEpoch;

    // ✅ Persist current textfield values into _workoutSets BEFORE we rearrange anything
    await _persistDraftLocally();


    // Build a lookup of existing rows by (exerciseId + circuitIndex) so values stay attached
    String keyForExistingRow(Map<String, dynamic> row) {
      final ci = (row['circuitIndex'] ?? 0).toString();

      // Prefer exerciseId/id (consistent with render key formula)
      final rawId = (row['exerciseId'] ?? row['id'])?.toString().trim() ?? '';
      if (rawId.isNotEmpty) return '${rawId.toLowerCase()}|$ci';

      // Fallback: parse from cardId (with empty guard)
      final cardId = (row['cardId'] ?? '').toString();
      final parts = cardId.split('|');
      if (parts.length >= 5) {
        final parsed = parts[3].trim().toLowerCase();
        if (parsed.isNotEmpty) return '$parsed|${parts[4].trim()}';
      }

      // Final fallback: name lookup
      final name = (row['name'] ?? '').toString();
      final exId = (PeriodizationModelUtils.nameToId[name] ?? name).trim().toLowerCase();
      return '$exId|$ci';
    }

    // Snapshot existing rows + their attached data so we can rebuild without mixing anything
    final existingExerciseIds = <String>{};

    String exIdFromRow(Map<String, dynamic> row) {
      // Prefer exerciseId/id (consistent with render key formula)
      final rawId = (row['exerciseId'] ?? row['id'])?.toString().trim() ?? '';
      if (rawId.isNotEmpty) return rawId.toLowerCase();

      // Fallback: parse from cardId (with empty guard)
      final cardId = (row['cardId'] ?? '').toString();
      final parts = cardId.split('|');
      if (parts.length >= 5) {
        final parsed = parts[3].trim().toLowerCase();
        if (parsed.isNotEmpty) return parsed;
      }

      final name = (row['name'] ?? '').toString();
      return (PeriodizationModelUtils.nameToId[name] ?? name).trim().toLowerCase();
    }

    for (final row in _selectedExercisesWithCircuits) {
      existingExerciseIds.add(exIdFromRow(row));
    }


    setState(() {
      // If you want template name ONLY when workout name is empty:
      if (_workoutNameController.text.trim().isEmpty) {
        _workoutNameController.text = template.name;
      }

      // Add missing template exercises (do NOT wipe existing ones)
      for (final entry in template.exercises.asMap().entries) {
        final int idx = entry.key;
        final dynamic e = entry.value;

        final String name = (e is String) ? e : (e['name'] ?? 'Unnamed');

        final int circuitIndex =
        (e is Map && e.containsKey('circuitIndex')) ? (e['circuitIndex'] as int) : 0;

        final String exId =
        (PeriodizationModelUtils.nameToId[name] ?? name).trim().toLowerCase();

        final String category =
        (e is Map && e.containsKey('category')) ? (e['category'] ?? '') as String : '';

        if (existingExerciseIds.contains(exId)) {
          // ✅ Do not add duplicates via Load Template (one instance per exercise per day)
          continue;
        }


        final String cardId = 'wes|$ymd|${_ts() + idx}|$exId|$circuitIndex';

        _selectedExercisesWithCircuits.add({
          'name': name,
          'exerciseId': exId,
          'id': exId,
          'circuitIndex': circuitIndex,
          'cardId': cardId,
          'category': category,
        });
        existingExerciseIds.add(exId);


        // Create sets + controllers for the new row, using planned set-count if available
        final int newRowIndex = _selectedExercisesWithCircuits.length - 1;
        final int plannedSetCount = _plannedSetCountFor(newRowIndex);
        final int desiredSets = (plannedSetCount <= 0) ? _defaultSets : plannedSetCount;

        _workoutSets.add(List.generate(
          desiredSets,
              (_) => SetDetails(reps: null, weight: null, rir: null),
        ));

        _repsControllers.add(List.generate(desiredSets, (_) => TextEditingController()));
        _weightControllers.add(List.generate(desiredSets, (_) => TextEditingController()));
        _rirControllers.add(List.generate(desiredSets, (_) => TextEditingController()));
        _velocityControllers.add(List.generate(desiredSets, (_) => TextEditingController()));
        _notesControllers.add(List.generate(desiredSets, (_) => TextEditingController()));
      }

      // ✅ Keep everything aligned and ordered
      _sortRowsByCircuitIndex();

      // ✅ Top-up any missing controller/sets + re-overlay values
      _initializeControllers();
    });

  }

  String _blockHeaderTitle(String blockId, List<Template> templates) {
    final String base = _blockNameById[blockId] ?? 'Block';

    if (blockId == _selectedBlockId) {
      return '$base (current)';
    } else {
      return base;
    }
  }



  void _showTemplateSelectionDialog() async {
    final uid = userId;
    if (uid == null || uid.isEmpty) return;
    print("🧩 [TemplatePicker] uid=$uid _activeBlockId=$_activeBlockId _selectedBlockId=$_selectedBlockId");

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('templates')
        .get();

    final templates = snapshot.docs
        .map((doc) => Template.fromFirestore(doc.data(), doc.id))
        .toList();
    print("🧩 [TemplatePicker] Loaded templates: ${templates.length}");
    print("🧩 [TemplatePicker] template.blockId set = ${templates.map((t) => t.blockId?.trim()).toSet()}");


    if (templates.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            backgroundColor: Colors.blueGrey.shade900,
            title: const Text(
              'Select Template',
              style: TextStyle(color: Colors.white),
            ),
            content: const Text(
              'No templates available.',
              style: TextStyle(color: Colors.white70),
            ),
          );
        },
      );
      return;
    }

    // ─────────────────────────────────────────────────────────────
    // Group templates by blockId; collect "other" templates.
    // ─────────────────────────────────────────────────────────────
    final Map<String, List<Template>> templatesByBlockId = {};
    final List<Template> otherTemplates = [];

    for (final t in templates) {
      final blockId = t.blockId?.trim();
      if (blockId == null || blockId.isEmpty) {
        otherTemplates.add(t);
      } else {
        templatesByBlockId.putIfAbsent(blockId, () => []).add(t);
      }
    }

    // 🔤 Sort templates within each block alphabetically by name
    templatesByBlockId.forEach((blockId, list) {
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    });

    // 🔤 Also sort "other" templates alphabetically
    otherTemplates.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );


    final entries = templatesByBlockId.entries.toList()
      ..sort((a, b) {
        if (a.key == _selectedBlockId) return -1;
        if (b.key == _selectedBlockId) return 1;
        return 0;
      });

    // 🔑 PERSISTENT EXPANSION STATE (outside StatefulBuilder)
    final Map<String, bool> expandedBlocks = {
      for (final e in entries)
        e.key: e.key == _selectedBlockId, // current block open by default
    };
    bool otherExpanded = false;

    final selectedTemplate = await showDialog<Template>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            return AlertDialog(
              backgroundColor: Colors.blueGrey.shade900,
              insetPadding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
              contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              title: const Text(
                'Select Template',
                style: TextStyle(fontSize: 13, color: Colors.white),
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    // One collapsible section per blockId
                    for (final entry in entries) ...[
                      Builder(
                        builder: (_) {
                          final blockId = entry.key;
                          final isExpanded = expandedBlocks[blockId] ?? false;

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ListTile(
                                tileColor: Colors.blueGrey.shade800,
                                title: Text(
                                  _blockHeaderTitle(blockId, entry.value),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                trailing: Icon(
                                  isExpanded
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                  color: Colors.white70,
                                ),
                                onTap: () {
                                  setStateDialog(() {
                                    expandedBlocks[blockId] = !isExpanded;
                                  });
                                },
                              ),
                              if (isExpanded)
                                ...entry.value.map((template) {
                                  return ListTile(
                                    dense: true,
                                    title: Text(
                                      template.name,
                                      style:
                                      const TextStyle(color: Colors.white),
                                    ),
                                    onTap: () =>
                                        Navigator.pop(context, template),
                                  );
                                }),
                              const Divider(
                                height: 10,
                                color: Colors.grey,
                              ),
                            ],
                          );
                        },
                      ),
                    ],

                    // "Other templates" group at the bottom
                    if (otherTemplates.isNotEmpty) ...[
                      ListTile(
                        tileColor: Colors.blueGrey.shade800,
                        title: const Text(
                          'Other templates',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        trailing: Icon(
                          otherExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                          color: Colors.white70,
                        ),
                        onTap: () {
                          setStateDialog(() {
                            otherExpanded = !otherExpanded;
                          });
                        },
                      ),
                      if (otherExpanded)
                        ...otherTemplates.map((template) {
                          return ListTile(
                            dense: true,
                            title: Text(
                              template.name,
                              style: const TextStyle(color: Colors.white),
                            ),
                            onTap: () =>
                                Navigator.pop(context, template),
                          );
                        }),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (selectedTemplate != null) {
      await _loadTemplate(selectedTemplate);
    }

  }




  void _addNewCircuitExercise() {
    setState(() {
      // 1) Decide the next circuit index
      int nextCircuitIndex = 0;
      if (_selectedExercisesWithCircuits.isNotEmpty) {
        final lastCircuitIndex =
            _selectedExercisesWithCircuits.last['circuitIndex'] ?? 0;
        nextCircuitIndex = lastCircuitIndex + 1;
      }

      // 2) Add a placeholder row
      _selectedExercisesWithCircuits.add({
        'name': '', // empty until user picks an exercise
        'circuitIndex': nextCircuitIndex,
      });

      // new row index
      final int i = _selectedExercisesWithCircuits.length - 1;

      // 3) Ensure ALL parallel structures have a row i,
      //    and that each row contains _defaultSets entries.

      // workout sets
      while (_workoutSets.length <= i) {
        _workoutSets.add(<SetDetails>[]);
      }
      while (_workoutSets[i].length < _defaultSets) {
        _workoutSets[i].add(SetDetails());
      }

      // reps controllers
      while (_repsControllers.length <= i) {
        _repsControllers.add(<TextEditingController>[]);
      }
      while (_repsControllers[i].length < _defaultSets) {
        _repsControllers[i].add(TextEditingController());
      }

      // weight controllers
      while (_weightControllers.length <= i) {
        _weightControllers.add(<TextEditingController>[]);
      }
      while (_weightControllers[i].length < _defaultSets) {
        _weightControllers[i].add(TextEditingController());
      }

      // RIR controllers
      while (_rirControllers.length <= i) {
        _rirControllers.add(<TextEditingController>[]);
      }
      while (_rirControllers[i].length < _defaultSets) {
        _rirControllers[i].add(TextEditingController());
      }

      // OPTIONAL: if you also track velocity/notes per set, keep them in sync too.
      // Uncomment if these exist in your state:

      while (_velocityControllers.length <= i) {
        _velocityControllers.add(<TextEditingController>[]);
      }
      while (_velocityControllers[i].length < _defaultSets) {
        _velocityControllers[i].add(TextEditingController());
      }

      while (_notesControllers.length <= i) {
        _notesControllers.add(<TextEditingController>[]);
      }
      while (_notesControllers[i].length < _defaultSets) {
        _notesControllers[i].add(TextEditingController());
      }
    });
  }


  @override
  void dispose() {
    final _disposeSw = Stopwatch()..start();

    // 🔎 FIRST: snapshot of what the UI is ACTUALLY showing
    print('🧯 [WES dispose] selectedDate=$_selectedDate block=$_selectedBlockId uid=${_cachedUid ?? FirebaseAuth.instance.currentUser?.uid}');

    if (_selectedExercisesWithCircuits.isNotEmpty) {
      final prevDumpMode = _claudeBulletDumpMode;
      _claudeBulletDumpMode = true;

      unawaited(
        Claude_bulletDebugDumpFullDayUi(tag: ' BEFORE_DISPOSE')
            .whenComplete(() => _claudeBulletDumpMode = prevDumpMode),
      );

      // Claude_bullet: persist full UI state for resume-like restore
      unawaited(Claude_bulletSaveFullDayUiSnapshot(reason: 'dispose'));
    }

    // Cancel debounce timer
    _claudeBulletSaveDebounce?.cancel();

    print('🧹 [WES] dispose called — uid=$_cachedUid');
    _catchupShineCtl?.dispose();

    // [WES_REENTER] Sync controller values into _workoutSets BEFORE disposal
    print('[WES_REENTER] dispose: syncing controllers to model before disposal');
    _syncControllersToModel();

    // [WES_REENTER] PRIMARY: save in-memory draft SYNCHRONOUSLY.
    // This is the only reliable way to guarantee the draft exists before
    // the next WES instance opens (all async saves are race-prone).
    try {
      final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);
      _exitDraft = {
        'dateKey': ymd,
        'uid': _cachedUid,
        'workoutName': _workoutNameController.text,
        'exercises': _selectedExercisesWithCircuits
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
        'sets': _workoutSets
            .map((setsForEx) => setsForEx
                .map((s) => <String, dynamic>{
                      'reps': s.reps,
                      'weight': s.weight,
                      'rir': s.rir,
                      'velocity': s.velocity,
                      'notes': s.notes,
                    })
                .toList())
            .toList(),
      };
      debugPrint('[WES_REENTER] dispose: saved in-memory draft for $ymd '
          '(${_selectedExercisesWithCircuits.length} exercises, '
          '${_workoutSets.length} set rows)');
    } catch (e) {
      debugPrint('[WES_REENTER] dispose: failed to save in-memory draft: $e');
    }

    // BACKUP: async draft saves (may not complete before re-entry, but help
    // with app-restart scenarios). _saveWorkoutDraftToCache uses model data
    // already synced above, so it doesn't need live controllers.
    _saveWorkoutDraftToCache();
    _persistDraftLocally();
    _isMergingBB2.dispose();


    // ⭐ Always attempt autosave on exit; _upsert will skip/clear appropriately
    print('💾 [WES dispose] Attempting autosave to Firestore...');
    _upsertWorkoutToFirestore(alsoPushToBB2: false, markAllSaved: false);

    _workoutNameController.dispose();
    for (var controllers in _repsControllers) {
      for (var controller in controllers) {
        controller.dispose();
      }
    }
    for (var controllers in _weightControllers) {
      for (var controller in controllers) {
        controller.dispose();
      }
    }
    for (var controllers in _rirControllers) {
      for (var controller in controllers) {
        controller.dispose();
      }
    }
    WidgetsBinding.instance.removeObserver(this);


    _horizontalScrollController.dispose();
    _sparkleCtrl.dispose();

    print('✅ [WES dispose] Completed cleanup.');
    print('⏱️ [WES dispose] total=${_disposeSw.elapsedMilliseconds} ms');

    super.dispose();
  }

// === STRUCTURE HASH: only changes when rows/sets shape changes ===
  int _structureHash() {
    int h = _selectedExercisesWithCircuits.length;
    h = (h * 31) ^ _workoutSets.length;
    h = (h * 31) ^ _repsControllers.length;
    h = (h * 31) ^ _weightControllers.length;
    h = (h * 31) ^ _rirControllers.length;
    h = (h * 31) ^ _velocityControllers.length;
    h = (h * 31) ^ _notesControllers.length;
    // Per-row set counts (cheap)
    for (final s in _workoutSets) { h = (h * 31) ^ s.length; }
    return h;
  }
  int _s1ValueHash() {
    int h = 17;
    final n = _selectedExercisesWithCircuits.length;
    for (int i = 0; i < n; i++) {
      final reps   = (i < _repsControllers.length    && _repsControllers[i].isNotEmpty)    ? _repsControllers[i][0].text : '';
      final weight = (i < _weightControllers.length  && _weightControllers[i].isNotEmpty)  ? _weightControllers[i][0].text : '';
      final rir    = (i < _rirControllers.length     && _rirControllers[i].isNotEmpty)     ? _rirControllers[i][0].text : '';
      // simple string-based hash; fast and good enough
      h = (h * 31) ^ reps.hashCode;
      h = (h * 31) ^ weight.hashCode;
      h = (h * 31) ^ rir.hashCode;
    }
    return h;
  }


  void _initializeControllers() {
    // ✅ Ensure controller lists are at least as long as the exercise list
    while (_repsControllers.length < _selectedExercisesWithCircuits.length) {
      _repsControllers.add([]);
    }
    while (_weightControllers.length < _selectedExercisesWithCircuits.length) {
      _weightControllers.add([]);
    }
    while (_rirControllers.length < _selectedExercisesWithCircuits.length) {
      _rirControllers.add([]);
    }
    while (_velocityControllers.length <
        _selectedExercisesWithCircuits.length) {
      _velocityControllers.add([]);
    }
    while (_notesControllers.length < _selectedExercisesWithCircuits.length) {
      _notesControllers.add([]);
    }

    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      List<SetDetails> sets = _workoutSets[i];

      // ✅ Only add controllers if they don't already exist
      if (_repsControllers[i].isEmpty) {
        _repsControllers[i] = sets.map((set) {
          return TextEditingController(text: set.reps?.toString() ?? '');
        }).toList();
      }

      if (_weightControllers[i].isEmpty) {
        _weightControllers[i] = sets.map((set) {
          return TextEditingController(
              text: set.weight != null ? set.weight!.toStringAsFixed(1) : '');
        }).toList();
      }

      if (_rirControllers[i].isEmpty) {
        _rirControllers[i] = sets.map((set) {
          return TextEditingController(
              text: set.rir != null ? set.rir!.toStringAsFixed(1) : '');
        }).toList();
      }

      if (_velocityControllers[i].isEmpty) {
        _velocityControllers[i] = sets.map((set) {
          return TextEditingController(
              text: set.velocity != null
                  ? set.velocity!.toStringAsFixed(2)
                  : '');
        }).toList();
      }

      if (_notesControllers[i].isEmpty) {
        _notesControllers[i] = sets.map((set) {
          return TextEditingController(text: set.notes ?? '');
        }).toList();
      }
    }
    _attachDirtyListeners();
  }

  //Values persisting block: start

  /// Synchronously copies controller text values into [_workoutSets].
  /// MUST be called BEFORE controllers are disposed so _persistDraftLocally
  /// (which may run after dispose awaits) already has fresh data in the model.
  void _syncControllersToModel() {
    print('[WES_REENTER] _syncControllersToModel START');
    int synced = 0;
    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      if (i >= _workoutSets.length) break;
      for (int j = 0; j < _workoutSets[i].length; j++) {
        if (i < _repsControllers.length && j < _repsControllers[i].length) {
          _workoutSets[i][j].reps = int.tryParse(_repsControllers[i][j].text.trim());
        }
        if (i < _weightControllers.length && j < _weightControllers[i].length) {
          _workoutSets[i][j].weight = double.tryParse(_weightControllers[i][j].text.trim());
        }
        if (i < _rirControllers.length && j < _rirControllers[i].length) {
          _workoutSets[i][j].rir = double.tryParse(_rirControllers[i][j].text.trim());
        }
        if (i < _velocityControllers.length && j < _velocityControllers[i].length) {
          _workoutSets[i][j].velocity = double.tryParse(_velocityControllers[i][j].text.trim());
        }
        if (i < _notesControllers.length && j < _notesControllers[i].length) {
          _workoutSets[i][j].notes = _notesControllers[i][j].text.trim();
        }
        synced++;
      }
    }
    print('[WES_REENTER] _syncControllersToModel END — synced $synced sets');
  }

  Future<void> _persistDraftLocally() async {
    final bool controllersAvailable = mounted;
    if (!controllersAvailable) {
      print('[WES_REENTER] _persistDraftLocally: unmounted — using pre-synced _workoutSets');
    }

    try {
      final prefs = await SharedPreferences.getInstance();

      // Sync current TextField values into _workoutSets only if controllers
      // are still alive (i.e. widget is mounted). When called from dispose(),
      // _syncControllersToModel() already ran synchronously before disposal.
      if (controllersAvailable) {
        for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
          for (int j = 0; j < _workoutSets[i].length; j++) {
            _workoutSets[i][j].reps =
                int.tryParse(_repsControllers[i][j].text.trim());
            _workoutSets[i][j].weight =
                double.tryParse(_weightControllers[i][j].text.trim());
            _workoutSets[i][j].rir =
                double.tryParse(_rirControllers[i][j].text.trim());
            _workoutSets[i][j].velocity =
                double.tryParse(_velocityControllers[i][j].text.trim());
            _workoutSets[i][j].notes = _notesControllers[i][j].text.trim();
          }
        }
      }

      String workoutName = '';
      try { workoutName = _workoutNameController.text; } catch (_) {}

      final draft = {
        'workoutName': workoutName,
        'exercises': List.generate(_selectedExercisesWithCircuits.length, (i) =>
        {
          'name': _selectedExercisesWithCircuits[i]['name'],
          'circuitIndex': _selectedExercisesWithCircuits[i]['circuitIndex'],
          'sets': _workoutSets[i].map((set) => set.toMap()).toList(),
        }),
      };

      final key = _getDraftKey(); // 👈 use your helper
      await prefs.setString(key, jsonEncode(draft));
      print('[WES_REENTER] _persistDraftLocally saved key: $key (controllersAvailable=$controllersAvailable)');

      // print('💾 Draft saved: $_draftKey');
    } catch (e) {
      print('❌ Failed to persist WES draft: $e');
    }
  }

  String _getDraftKey() {
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    return 'workout_draft_${_cachedUid}_$dateKey';
  }

  Future<void> _loadDraftLocallyIfAvailable() async {
    final _tDraft = Stopwatch()..start();
    print('⏱️ [WES Draft] _loadDraftLocallyIfAvailable started');

    try {
      // Preconditions: this should run AFTER fast paint and before/alongside merges
      if (_selectedExercisesWithCircuits.isEmpty) {
        print('🛑 [WES Draft] Skipping: no painted rows yet');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final key = _getDraftKey();
      final jsonStr = prefs.getString(key);
      print('📥 [WES Draft] Read key: $key → ${jsonStr == null ? 'none' : '${jsonStr.length} bytes'}');
      if (jsonStr == null || jsonStr.isEmpty) return;

      // Parse draft
      Map<String, dynamic> decoded;
      try {
        decoded = Map<String, dynamic>.from(jsonDecode(jsonStr) as Map);
      } catch (e) {
        print('⚠️ [WES Draft] JSON decode failed: $e');
        return;
      }

      // Compare draft freshness vs WES snapshot for this date
      DateTime? _parseTs(dynamic v) {
        if (v == null) return null;
        if (v is DateTime) return v;
        if (v is String) return DateTime.tryParse(v);
        if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
        return null;
      }

      final draftUpdatedAt = _parseTs(decoded['updatedAt'] ?? decoded['savedAt']);
      DateTime? baselineUpdatedAt;
      try {
        final uid = _cachedUid ?? UserContext.of(context, listen: false).currentUid;
        final bid = _selectedBlockId ?? _activeBlockId;
        if ((uid != null && uid.isNotEmpty) && bid != null) {
          final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);
          final snap = await BlockPlanCache.getInitSnapshot(uid: uid, blockId: bid, dateYmd: ymd);
          baselineUpdatedAt = snap?.updatedAt ?? snap?.cachedAt;
        }
      } catch (_) {
        /* best-effort */
      }

      if (draftUpdatedAt != null && baselineUpdatedAt != null && !draftUpdatedAt.isAfter(baselineUpdatedAt)) {
        print('↩️ [WES Draft] Draft is not newer (draft=$draftUpdatedAt <= snap=$baselineUpdatedAt) → skip overlay');
        return;
      }

      // Non-destructive overlay
      final List draftExercises = (decoded['exercises'] is List) ? (decoded['exercises'] as List) : const [];
      if (draftExercises.isEmpty) {
        print('ℹ️ [WES Draft] Draft has no exercises → nothing to overlay');
        return;
      }

      // Build a quick lookup of painted rows by name|circuitIndex (case-insensitive name)
      String _keyOf(String name, int ci) => '${name.trim().toLowerCase()}|$ci';
      final Map<String, int> paintedIndexByKey = {
        for (int i = 0; i < _selectedExercisesWithCircuits.length; i++)
          _keyOf(
            ((_selectedExercisesWithCircuits[i]['name'] ?? '') as String),
            ((_selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0) as int),
          ): i
      };

      bool changed = false;
      int rowsTouched = 0;
      int fieldsFilled = 0;

      for (final e in draftExercises) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final name = (m['name'] ?? m['exercise'] ?? '').toString().trim();
        if (name.isEmpty) continue;

        final ci = (m['circuitIndex'] is num)
            ? (m['circuitIndex'] as num).toInt()
            : int.tryParse('${m['circuitIndex'] ?? 0}') ?? 0;

        final k = _keyOf(name, ci);
        final idx = paintedIndexByKey[k];
        if (idx == null) {
          // Non-destructive: do NOT add structural rows
          continue;
        }

        // Draft sets
        final List<Map<String, dynamic>> setMaps = (m['sets'] is List)
            ? (m['sets'] as List)
            .whereType<Map>()
            .map((x) => Map<String, dynamic>.from(x))
            .toList()
            : const <Map<String, dynamic>>[];

        // 🔢 Use planned set-count for this row, not a global default
        final int plannedSetCount = _plannedSetCountFor(idx);
        final int desiredSets =
        (plannedSetCount <= 0 ? _defaultSets : plannedSetCount);

        // Ensure this row has enough SetDetails / controllers allocated
        while (_workoutSets[idx].length < desiredSets) {
          _workoutSets[idx].add(SetDetails());
          _repsControllers[idx].add(TextEditingController());
          _weightControllers[idx].add(TextEditingController());
          _rirControllers[idx].add(TextEditingController());
          _velocityControllers[idx].add(TextEditingController());
          _notesControllers[idx].add(TextEditingController());
        }

        // Overlay set-by-set up to UI capacity
        final int maxSets = desiredSets;
        for (int s = 0; s < setMaps.length && s < maxSets; s++) {
          final ds = setMaps[s];
          final SetDetails sd = _workoutSets[idx][s];

          // Resolve BW vs non-BW weight display
          final exName = (_selectedExercisesWithCircuits[idx]['name'] as String).trim();
          final exId = PeriodizationModelUtils.nameToId[exName] ?? exName;
          final isBw = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: exName);

          double? draftAbs = (ds['weight'] is num) ? (ds['weight'] as num).toDouble() : null;
          double? draftAdded = (ds['addedWeight'] as num?)?.toDouble() ?? (ds['weightAdded'] as num?)?.toDouble();
          double? displayWeight;
          if (isBw) {
            displayWeight = draftAdded ??
                (draftAbs != null
                    ? PeriodizationModelUtils.toDisplayAddedWeight(
                  uid: _cachedUid ?? UserContext.of(context, listen: false).currentUid ?? '',
                  absoluteKg: draftAbs,
                  exerciseId: exId,
                  exerciseName: exName,
                  asOfDate: _selectedDate,
                )
                    : null);
          } else {
            displayWeight = draftAbs;
          }

          // Only fill EMPTY controller fields / null SetDetails
          // Claude_bullet: when resume snapshot is active, do not clobber
          // controllers — hints must remain as empty controllers, typed values
          // are already set.
          final bool _cbGuard = _claudeBulletActiveForThisDay;

          // reps
          if (!_cbGuard && (_repsControllers[idx][s].text.trim().isEmpty) && ds['reps'] != null) {
            final String repText = (ds['reps'] is num)
                ? (ds['reps'] as num).toInt().toString()
                : (ds['reps'] is String ? (ds['reps'] as String) : '');
            _repsControllers[idx][s].text = repText;


            fieldsFilled++; changed = true;
          }
          if (sd.reps == null && ds['reps'] != null) {
            sd.reps = (ds['reps'] as num?)?.toInt();
            fieldsFilled++; changed = true;
          }

          // weight (display)
          if (!_cbGuard && (_weightControllers[idx][s].text.trim().isEmpty) && displayWeight != null) {
            _weightControllers[idx][s].text = (displayWeight != null) ? displayWeight.toString() : '';

            fieldsFilled++; changed = true;
          }
          if (sd.weight == null && displayWeight != null) {
            sd.weight = displayWeight;
            fieldsFilled++; changed = true;
          }

          // rir
          final double? draftRir = (ds['rir'] is num)
              ? (ds['rir'] as num).toDouble()
              : (ds['rir'] is String ? double.tryParse(ds['rir']) : null);
          if (!_cbGuard && (_rirControllers[idx][s].text.trim().isEmpty) && draftRir != null) {
            final String rirText = (draftRir != null) ? draftRir.toString() : '';
            _rirControllers[idx][s].text = rirText;

            fieldsFilled++; changed = true;
          }
          if (sd.rir == null && draftRir != null) {
            sd.rir = draftRir;
            fieldsFilled++; changed = true;
          }

          // velocity
          final double? draftVel = (ds['velocity'] is num)
              ? (ds['velocity'] as num).toDouble()
              : (ds['velocity'] is String ? double.tryParse(ds['velocity']) : null);
          if (sd.velocity == null && draftVel != null) {
            sd.velocity = draftVel;
            fieldsFilled++; changed = true;
          }

          // notes (don’t touch controller text; SetDetails only if null)
          final String? draftNotes = (ds['notes'] is String) ? (ds['notes'] as String).trim() : null;
          if ((sd.notes == null || sd.notes!.isEmpty) && draftNotes != null && draftNotes.isNotEmpty) {
            sd.notes = draftNotes;
            fieldsFilled++; changed = true;
          }
        }

        rowsTouched++;
      }

      // Optionally restore workout name if empty (non-destructive)
      if ((_workoutNameController.text.trim().isEmpty) && (decoded['workoutName'] is String)) {
        _workoutNameController.text = (decoded['workoutName'] as String).trim();
        changed = true;
      }

      // Ensure listeners are attached for any controllers we might have touched
      _attachDirtyListeners();

      if (changed && mounted) {
        setState(() {});
      }

      print('✅ [WES Draft] Overlay done → rowsTouched=$rowsTouched fieldsFilled=$fieldsFilled changed=$changed');
    } catch (e, st) {
      print('❌ [WES Draft] Overlay failed: $e');
      print(st);
    } finally {
      _tDraft.stop();
      print('⏱️ [WES Draft] total=${_tDraft.elapsedMilliseconds}ms');
    }
  }


  void _showExercisePickerDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (plannedExercises.isEmpty) {
      await loadPlannedExercisesFromFirestore();
    }

// 🧠 Double guard: If it's still empty after loading, just skip the planned-only filter.

    bool showPlannedOnly = true;
    bool plannedModeAvailable = plannedExercises.isNotEmpty;

    final snapshot =
    await FirebaseFirestore.instance.collection('exercises').get();

    final allExercises = snapshot.docs
        .map((doc) =>
    {
      'id': doc.id,
      'name': doc['name'] as String,
      'category': doc['category'] as String,
    })
        .toList();

    // 🔥 Build Name ➔ ID map
    final Map<String, String> nameToIdMap = {
      for (final ex in allExercises) ex['name']!: ex['id']!,
    };
    // 🔗 Name → Category map (for sync group resolution in WES)
    final Map<String, String> nameToCategoryMap = {
      for (final ex in allExercises) ex['name']!: ex['category']!,
    };


    final Map<String, bool> expandedGroups = {};

    final List<String>? selected = await showDialog<List<String>>(
      context: context,
      builder: (ctx) {
        List<String> tempSelected = _selectedExercisesWithCircuits
            .map((e) => e['name'] as String)
            .toList();
        String searchQuery = "";

        return StatefulBuilder(builder: (context, setLocalState) {
          // 🔍 Toggle UI
          Widget toggleRow = Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                showPlannedOnly ? 'Planned Only' : 'All Exercises',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              Switch(
                value: showPlannedOnly,
                onChanged: (v) => setLocalState(() => showPlannedOnly = v),
                activeColor: Colors.lightBlueAccent,
              ),
            ],
          );

          // 🗂 Apply planned-only filter
          List<Map<String, String>> filteredExercises =
          (showPlannedOnly && plannedModeAvailable)
              ? allExercises
              .where((ex) => plannedExercises.contains(ex['id']))
              .toList()
              : allExercises;

          // 🔍 Apply case-insensitive name filter
          if (searchQuery
              .trim()
              .isNotEmpty) {
            final query = searchQuery.toLowerCase();
            filteredExercises = filteredExercises.where((ex) {
              final name = ex['name']?.toLowerCase() ?? "";
              return name.contains(query);
            }).toList();
          }

          print('Planned Exercise IDs: $plannedExercises');
          print(
              'Loaded Exercises (id, name): ${allExercises.map((
                  e) => '${e['id']} (${e['name']})').toList()}');
          print(
              'Filtered Exercises (${showPlannedOnly
                  ? "Planned Only"
                  : "All"}): ${filteredExercises.map((e) => e['name'])
                  .toList()}');

          final Map<String, List<String>> grouped = {};

          for (final exercise in filteredExercises) {
            final category = exercise['category'] ?? 'Other';
            final name = exercise['name'] ?? 'Unnamed';
            grouped.putIfAbsent(category, () => []).add(name);
          }

          for (final group in grouped.values) {
            group
                .sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          }

          const categoryOrder = [
            'Horizontal Press',
            'Horizontal Pull',
            'Vertical Press',
            'Vertical Pull',
            'Lateral Raise',
            'Arm Extension',
            'Arm Curl',
            'Squat Pattern',
            'Hip Hinge',
            'Leg Extension',
            'Leg Curl',
            'Hip Abduction/adduction',
            'Calf Raise',
            'Core',
          ];

          final Map<String, List<String>> orderedGrouped = {};
          for (final cat in categoryOrder) {
            if (grouped.containsKey(cat)) {
              orderedGrouped[cat] = grouped[cat]!;
            }
          }
          for (final entry in grouped.entries) {
            if (!orderedGrouped.containsKey(entry.key)) {
              orderedGrouped[entry.key] = entry.value;
            }
          }

          for (final category in orderedGrouped.keys) {
            expandedGroups.putIfAbsent(category, () => false);
          }

          return AlertDialog(
            backgroundColor: Colors.blueGrey.shade900,
            insetPadding: const EdgeInsets.symmetric(
                horizontal: 24, vertical: 2),
            // 🔧 reduce horizontal margin
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 12),
            // 🔧 reduce internal padding
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Select Exercises",
                    style: TextStyle(fontSize: 13, color: Colors.white)),
                if (plannedModeAvailable)
                  Row(
                    children: [
                      Text(
                        showPlannedOnly ? "Planned Only" : "All Exercises",
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white70),
                      ),
                      Switch(
                        value: showPlannedOnly,
                        onChanged: (value) =>
                            setLocalState(() => showPlannedOnly = value),
                        activeColor: Colors.lightBlueAccent,
                      ),
                    ],
                  )
                else
                  const SizedBox(),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                children: [
                  // 🔍 Search bar
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: TextField(
                      onChanged: (value) =>
                          setLocalState(() => searchQuery = value),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: "Search exercises...",
                        hintStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Colors.blueGrey.shade800,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8.0)),
                        prefixIcon:
                        const Icon(Icons.search, color: Colors.white70),
                      ),
                    ),
                  ),

                  // 🔍 Filtered exercise list
                  Expanded(
                    child: searchQuery
                        .trim()
                        .isNotEmpty
                        ? ListView(
                      children: filteredExercises.map((ex) {
                        final name = ex['name']!;
                        final isChecked = tempSelected.contains(name);
                        return CheckboxListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10),
                          // 🔧 tighter spacing
                          dense: true,
                          // ✅ less vertical space
                          value: isChecked,
                          title: Text(
                            name,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 18),
                          ),
                          controlAffinity:
                          ListTileControlAffinity.leading,
                          activeColor: Colors.lightBlueAccent,
                          checkColor: Colors.black,

                          onChanged: (checked) {
                            setLocalState(() {
                              if (checked == true) {
                                tempSelected.add(name);
                              } else {
                                tempSelected.remove(name);
                              }
                            });
                          },
                        );
                      }).toList(),
                    )
                        : ListView(
                      children: orderedGrouped.entries.map((entry) {
                        final category = entry.key;
                        final exercises = entry.value;
                        final isExpanded =
                            expandedGroups[category] ?? false;

                        return Column(
                          crossAxisAlignment:
                          CrossAxisAlignment.start,
                          children: [
                            ListTile(
                              tileColor: Colors.blueGrey.shade800,
                              title: Text(category,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold)),
                              trailing: Icon(
                                isExpanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                color: Colors.white70,
                              ),
                              onTap: () {
                                setLocalState(() {
                                  expandedGroups[category] =
                                  !isExpanded;
                                });
                              },
                            ),
                            if (isExpanded)
                              ...exercises.map((name) {
                                final isChecked =
                                tempSelected.contains(name);
                                return CheckboxListTile(
                                  value: isChecked,
                                  title: Text(name,
                                      style: const TextStyle(
                                          color: Colors.white)),
                                  controlAffinity:
                                  ListTileControlAffinity.leading,
                                  activeColor: Colors.lightBlueAccent,
                                  checkColor: Colors.black,
                                  onChanged: (checked) {
                                    setLocalState(() {
                                      if (checked == true) {
                                        tempSelected.add(name);
                                      } else {
                                        tempSelected.remove(name);
                                      }
                                    });
                                  },
                                );
                              }),
                            const Divider(
                                height: 10, color: Colors.grey),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),

            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Cancel"),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, tempSelected),
                child: const Text("Save"),
              ),
            ],
          );
        });
      },
    );


    if (selected == null) {
      // User tapped Cancel → keep existing exercises untouched.
      return;
    }
    // Tag user-added cards for this specific day (so date-prune logic keeps them)
    final String ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);
    int _ts() => DateTime.now().microsecondsSinceEpoch;


    setState(() {
      // 🔒 Snapshot existing rows & data so we can preserve user-entered values.
      final oldRows = List<Map<String, dynamic>>.from(_selectedExercisesWithCircuits);
      final oldWorkoutSets = _workoutSets.map((row) => List<SetDetails>.from(row)).toList();
      final oldRepsControllers = _repsControllers.map((row) => List<TextEditingController>.from(row)).toList();
      final oldWeightControllers = _weightControllers.map((row) => List<TextEditingController>.from(row)).toList();
      final oldRirControllers = _rirControllers.map((row) => List<TextEditingController>.from(row)).toList();
      final oldVelocityControllers = _velocityControllers.map((row) => List<TextEditingController>.from(row)).toList();
      final oldNotesControllers = _notesControllers.map((row) => List<TextEditingController>.from(row)).toList();

      // Map from exerciseId|circuitIndex → old row index
      final Map<String, int> oldIndexByKey = {};
      for (int idx = 0; idx < oldRows.length; idx++) {
        final row = oldRows[idx];
        final name = (row['name'] ?? '').toString();
        if (name.isEmpty) continue;
        final ci = (row['circuitIndex'] ?? 0) as int;
        final exId = (PeriodizationModelUtils.nameToId[name] ?? name)
            .toString()
            .trim()
            .toLowerCase();
        final key = '$exId|$ci';
        oldIndexByKey[key] = idx;
      }

      // 🧠 1) Capture current circuitIndex per exerciseId
      final Map<String, int> existingCircuitByExId = {};
      int lastCircuit = 0;

      for (final row in oldRows) {
        final name = (row['name'] ?? '').toString();
        if (name.isEmpty) continue;
        final ci = (row['circuitIndex'] ?? 0) as int;
        final exId = (PeriodizationModelUtils.nameToId[name] ?? name)
            .toString()
            .trim()
            .toLowerCase();
        existingCircuitByExId[exId] = ci;
        if (ci > lastCircuit) lastCircuit = ci;
      }

      // 🧠 2) Rebuild rows based on the new selection:
      //    - keep existing circuitIndex where possible (by exerciseId)
      //    - brand-new exercises go into the last circuit
      _selectedExercisesWithCircuits.clear();
      _selectedExercisesWithCircuits.addAll(
        selected.asMap().entries.map((entry) {
          final idx = entry.key;
          final name = entry.value;
          final exId = (nameToIdMap[name] ?? name).trim().toLowerCase();

          final int circuitIndex =
              existingCircuitByExId[exId] ?? lastCircuit;

          // wes|<YYYY-MM-DD>|<unique-ts>|<exercise-id>|<circuitIndex>
          final cardId = 'wes|$ymd|${_ts() + idx}|$exId|$circuitIndex';

          return {
            'name': name,
            'category': nameToCategoryMap[name] ?? '',
            'circuitIndex': circuitIndex,
            'cardId': cardId,
          };
        }),
      );

      // 🔁 3) Rebuild sets/controllers for the new list,
      //       preserving user-entered data by exerciseId|circuitIndex
      final List<List<SetDetails>> newWorkoutSets = [];
      final List<List<TextEditingController>> newRepsControllers = [];
      final List<List<TextEditingController>> newWeightControllers = [];
      final List<List<TextEditingController>> newRirControllers = [];
      final List<List<TextEditingController>> newVelocityControllers = [];
      final List<List<TextEditingController>> newNotesControllers = [];

      for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
        final row = _selectedExercisesWithCircuits[i];
        final String name = (row['name'] ?? '').toString();
        final int circuitIndex = (row['circuitIndex'] ?? 0) as int;
        final String exId =
        (PeriodizationModelUtils.nameToId[name] ?? name)
            .toString()
            .trim()
            .toLowerCase();
        final String key = '$exId|$circuitIndex';

        final int setCount = _plannedSetCountFor(i);
        final int desiredSets = (setCount <= 0) ? _defaultSets : setCount;

        final List<SetDetails> setsRow = [];
        final List<TextEditingController> repsRow = [];
        final List<TextEditingController> weightRow = [];
        final List<TextEditingController> rirRow = [];
        final List<TextEditingController> velRow = [];
        final List<TextEditingController> notesRow = [];

        final int? oldIdx = oldIndexByKey[key];

        for (int s = 0; s < desiredSets; s++) {
          if (oldIdx != null &&
              oldIdx < oldWorkoutSets.length &&
              s < oldWorkoutSets[oldIdx].length &&
              oldIdx < oldRepsControllers.length &&
              s < oldRepsControllers[oldIdx].length &&
              oldIdx < oldWeightControllers.length &&
              s < oldWeightControllers[oldIdx].length &&
              oldIdx < oldRirControllers.length &&
              s < oldRirControllers[oldIdx].length &&
              oldIdx < oldVelocityControllers.length &&
              s < oldVelocityControllers[oldIdx].length &&
              oldIdx < oldNotesControllers.length &&
              s < oldNotesControllers[oldIdx].length) {
            // Reuse existing SetDetails + controllers
            setsRow.add(oldWorkoutSets[oldIdx][s]);
            repsRow.add(oldRepsControllers[oldIdx][s]);
            weightRow.add(oldWeightControllers[oldIdx][s]);
            rirRow.add(oldRirControllers[oldIdx][s]);
            velRow.add(oldVelocityControllers[oldIdx][s]);
            notesRow.add(oldNotesControllers[oldIdx][s]);
          } else {
            // New blank set
            setsRow.add(SetDetails());
            repsRow.add(TextEditingController());
            weightRow.add(TextEditingController());
            rirRow.add(TextEditingController());
            velRow.add(TextEditingController());
            notesRow.add(TextEditingController());
          }
        }

        newWorkoutSets.add(setsRow);
        newRepsControllers.add(repsRow);
        newWeightControllers.add(weightRow);
        newRirControllers.add(rirRow);
        newVelocityControllers.add(velRow);
        newNotesControllers.add(notesRow);
      }

      _workoutSets
        ..clear()
        ..addAll(newWorkoutSets);

      _repsControllers
        ..clear()
        ..addAll(newRepsControllers);

      _weightControllers
        ..clear()
        ..addAll(newWeightControllers);

      _rirControllers
        ..clear()
        ..addAll(newRirControllers);

      _velocityControllers
        ..clear()
        ..addAll(newVelocityControllers);

      _notesControllers
        ..clear()
        ..addAll(newNotesControllers);


      // ✅ 4) Keep circuits ordered 0,1,2,… and preserve order within each circuit
      _sortRowsByCircuitIndex();

      // Undo: delta-only, reusing already-computed old* locals (no new full snapshot)
      if (!_applyingUndo) {
        final Set<String> newKeySet = {};
        for (int k = 0; k < _selectedExercisesWithCircuits.length; k++) {
          newKeySet.add(_rowKeyBy(k));
        }
        final Set<String> addedKeys = newKeySet.difference(oldIndexByKey.keys.toSet());
        final List<int>                      removedOrigIdxs = [];
        final List<Map<String, dynamic>>     removedRows     = [];
        final List<List<SetDetails>>         removedSets     = [];
        final List<List<String>>             removedRepsTs   = [];
        final List<List<String>>             removedWeightTs = [];
        final List<List<String>>             removedRirTs    = [];
        final List<List<String>>             removedVelTs    = [];
        final List<List<String>>             removedNotesTs  = [];
        for (final entry in oldIndexByKey.entries) {
          if (!newKeySet.contains(entry.key)) {
            final oi = entry.value;
            removedOrigIdxs.add(oi);
            removedRows.add(oldRows[oi]);
            removedSets.add(oldWorkoutSets[oi]);
            removedRepsTs.add(oldRepsControllers[oi].map((c) => c.text).toList());
            removedWeightTs.add(oldWeightControllers[oi].map((c) => c.text).toList());
            removedRirTs.add(oldRirControllers[oi].map((c) => c.text).toList());
            removedVelTs.add(oldVelocityControllers[oi].map((c) => c.text).toList());
            removedNotesTs.add(oldNotesControllers[oi].map((c) => c.text).toList());
          }
        }
        _undoStack.add(() {
          if (!mounted) return;
          setState(() {
            // Remove added exercises by key (reverse order keeps lower indices stable)
            for (int k = _selectedExercisesWithCircuits.length - 1; k >= 0; k--) {
              if (addedKeys.contains(_rowKeyBy(k))) {
                for (final c in _repsControllers[k]) c.dispose();
                for (final c in _weightControllers[k]) c.dispose();
                for (final c in _rirControllers[k]) c.dispose();
                for (final c in _velocityControllers[k]) c.dispose();
                for (final c in _notesControllers[k]) c.dispose();
                _selectedExercisesWithCircuits.removeAt(k);
                _workoutSets.removeAt(k);
                _repsControllers.removeAt(k);
                _weightControllers.removeAt(k);
                _rirControllers.removeAt(k);
                _velocityControllers.removeAt(k);
                _notesControllers.removeAt(k);
              }
            }
            // Re-insert removed exercises at original positions (ascending order)
            final sortedOrder = List.generate(removedOrigIdxs.length, (i) => i)
              ..sort((a, b) => removedOrigIdxs[a].compareTo(removedOrigIdxs[b]));
            for (final si in sortedOrder) {
              final insertAt = removedOrigIdxs[si].clamp(0, _selectedExercisesWithCircuits.length);
              _selectedExercisesWithCircuits.insert(insertAt, removedRows[si]);
              _workoutSets.insert(insertAt, removedSets[si]);
              _repsControllers.insert(insertAt,
                  removedRepsTs[si].map((t) => TextEditingController(text: t)).toList());
              _weightControllers.insert(insertAt,
                  removedWeightTs[si].map((t) => TextEditingController(text: t)).toList());
              _rirControllers.insert(insertAt,
                  removedRirTs[si].map((t) => TextEditingController(text: t)).toList());
              _velocityControllers.insert(insertAt,
                  removedVelTs[si].map((t) => TextEditingController(text: t)).toList());
              _notesControllers.insert(insertAt,
                  removedNotesTs[si].map((t) => TextEditingController(text: t)).toList());
            }
          });
          _attachDirtyListeners();
          _markDirty();
        });
      }

      // 🚫 Do NOT re-initialize controllers here; we just reused them.
      _populateVelocityFlags();
      () async {
        try {
          await _upsertWorkoutToFirestore(
          alsoPushToBB2: false,
          markAllSaved: false,
          );
        } catch (_) {}
      }();
    });



  }

  void _showExercisePickerForRow(int index) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (plannedExercises.isEmpty) {
      await loadPlannedExercisesFromFirestore();
    }

    bool plannedModeAvailable = plannedExercises.isNotEmpty;
    final snapshot =
    await FirebaseFirestore.instance.collection('exercises').get();

    final allExercises = snapshot.docs
        .map((doc) =>
    {
      'id': doc.id,
      'name': doc['name'] as String,
      'category': doc['category'] as String,
    })
        .toList();

    final Map<String, String> nameToIdMap = {
      for (final ex in allExercises) ex['name']!: ex['id']!,
    };

    // 🔗 Name → Category map (for sync group resolution in WES)
    final Map<String, String> nameToCategoryMap = {
      for (final ex in allExercises) ex['name']!: ex['category']!,
    };


    bool showPlannedOnly = true;
    final Map<String, bool> expandedGroups = {};
    String searchQuery = '';

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) {
        // Build exclusion set: exercises already on this day (skip the row being replaced)
        final Set<String> existingIds = {};
        final Set<String> existingNames = {};
        for (int ri = 0; ri < _selectedExercisesWithCircuits.length; ri++) {
          if (ri == index) continue;
          final row = _selectedExercisesWithCircuits[ri];
          final eid = (row['exerciseId'] ?? row['id'])?.toString().trim() ?? '';
          if (eid.isNotEmpty) existingIds.add(eid);
          final nm = (row['name'] ?? '').toString().trim().toLowerCase();
          if (nm.isNotEmpty) existingNames.add(nm);
        }

        return StatefulBuilder(builder: (context, setLocalState) {
          List<Widget> _buildExerciseList() {
            var filteredExercises = (showPlannedOnly && plannedModeAvailable)
                ? allExercises
                .where((ex) => plannedExercises.contains(ex['id']))
                .toList()
                : List<Map<String, String>>.from(allExercises);

            // Exclude exercises already present on this day
            filteredExercises = filteredExercises
                .where((ex) =>
                    !existingIds.contains(ex['id']) &&
                    !existingNames.contains(ex['name']!.trim().toLowerCase()))
                .toList();

            final searched = searchQuery.isNotEmpty
                ? filteredExercises
                .where(
                    (ex) => ex['name']!.toLowerCase().contains(searchQuery))
                .toList()
                : filteredExercises;

            if (searchQuery.isNotEmpty) {
              return searched
                  .map((ex) =>
                  ListTile(
                    title: Text(ex['name']!,
                        style: const TextStyle(color: Colors.white70)),
                    onTap: () => Navigator.pop(ctx, ex['name']!),
                    dense: true,
                    contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10),
                  ))
                  .toList();
            }

            final Map<String, List<String>> grouped = {};
            for (final exercise in filteredExercises) {
              final category = exercise['category'] ?? 'Other';
              final name = exercise['name'] ?? 'Unnamed';
              grouped.putIfAbsent(category, () => []).add(name);
            }

            for (final group in grouped.values) {
              group.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
            }

            const categoryOrder = [
              'Horizontal Press',
              'Horizontal Pull',
              'Vertical Press',
              'Vertical Pull',
              'Lateral Raise',
              'Arm Extension',
              'Arm Curl',
              'Squat Pattern',
              'Hip Hinge',
              'Leg Extension',
              'Leg Curl',
              'Hip Abduction/adduction',
              'Calf Raise',
              'Core',
            ];

            final Map<String, List<String>> orderedGrouped = {};
            for (final cat in categoryOrder) {
              if (grouped.containsKey(cat)) {
                orderedGrouped[cat] = grouped[cat]!;
              }
            }
            for (final entry in grouped.entries) {
              if (!orderedGrouped.containsKey(entry.key)) {
                orderedGrouped[entry.key] = entry.value;
              }
            }

            for (final category in orderedGrouped.keys) {
              expandedGroups.putIfAbsent(category, () => false);
            }

            return orderedGrouped.entries.map((entry) {
              final category = entry.key;
              final exercises = entry.value;
              final isExpanded = expandedGroups[category] ?? false;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    tileColor: Colors.blueGrey.shade800,
                    title: Text(category,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                    trailing: Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.white70,
                    ),
                    onTap: () =>
                        setLocalState(
                                () => expandedGroups[category] = !isExpanded),
                  ),
                  if (isExpanded)
                    ...exercises.map((name) =>
                        ListTile(
                          title: Text(name,
                              style: const TextStyle(color: Colors.white70)),
                          onTap: () => Navigator.pop(ctx, name),
                          dense: true,
                          contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10),
                        )),
                  const Divider(height: 10, color: Colors.grey),
                ],
              );
            }).toList();
          }

          return AlertDialog(
            backgroundColor: Colors.blueGrey.shade900,
            insetPadding: const EdgeInsets.symmetric(
                horizontal: 24, vertical: 2),
            // 🔧 reduce horizontal margin
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 12),
            // 🔧 reduce internal padding
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Select Exercise",
                    style: TextStyle(fontSize: 13, color: Colors.white)),
                if (plannedModeAvailable)
                  Row(
                    children: [
                      Text(
                        showPlannedOnly ? "Planned Only" : "All Exercises",
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white70),
                      ),
                      Switch(
                        value: showPlannedOnly,
                        onChanged: (value) =>
                            setLocalState(() => showPlannedOnly = value),
                        activeColor: Colors.lightBlueAccent,
                      ),
                    ],
                  )
                else
                  const SizedBox(),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10.0),
                    child: TextField(
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Search exercises...',
                        hintStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Colors.blueGrey.shade800,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8.0)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10.0, vertical: 10.0),
                      ),
                      onChanged: (val) =>
                          setLocalState(() => searchQuery = val.toLowerCase()),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: _buildExerciseList(),
                    ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );

    if (selected != null && selected.isNotEmpty) {
      final String newExId = nameToIdMap[selected] ?? '';
      final String newCategory = nameToCategoryMap[selected] ?? '';
      final String ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);

      setState(() {
        final row = _selectedExercisesWithCircuits[index];

        // 1️⃣ Update full identity for this row (name + exerciseId + category + cardId)
        row['name'] = selected;
        row['exerciseId'] = newExId;
        row['id'] = newExId;
        row['category'] = newCategory;
        row.remove('_runtimeId');
        final int ci = (row['circuitIndex'] ?? 0) as int;
        row['cardId'] = 'wes|$ymd|${DateTime.now().microsecondsSinceEpoch}|$newExId|$ci';

        // 2️⃣ Work out how many sets this row *should* have
        final int plannedSetCount = _plannedSetCountFor(index);
        final int desiredSets =
        (plannedSetCount <= 0) ? _defaultSets : plannedSetCount;

        // 3️⃣ Grow this row's sets/controllers up to desiredSets (never shrink)
        while (_workoutSets[index].length < desiredSets) {
          _workoutSets[index].add(SetDetails());
          _repsControllers[index].add(TextEditingController());
          _weightControllers[index].add(TextEditingController());
          _rirControllers[index].add(TextEditingController());
          _velocityControllers[index].add(TextEditingController());
          _notesControllers[index].add(TextEditingController());
        }

        // 4️⃣ Recompute per-exercise flags (e.g. velocity)
        _populateVelocityFlags();
      });

      // 5️⃣ Persist immediately (consistent with main dialog behavior)
      () async {
        try {
          await _upsertWorkoutToFirestore(
            alsoPushToBB2: false,
            markAllSaved: false,
          );
        } catch (_) {}
      }();
    }

  }

  void _onReorderExercises(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;

      // Remove data from old position
      final movedExercise = _selectedExercisesWithCircuits.removeAt(oldIndex);
      final movedSets = _workoutSets.removeAt(oldIndex);
      final movedReps = _repsControllers.removeAt(oldIndex);
      final movedWeight = _weightControllers.removeAt(oldIndex);
      final movedRir = _rirControllers.removeAt(oldIndex);
      final movedVelocity = _velocityControllers.removeAt(oldIndex);
      final movedNotes = _notesControllers.removeAt(oldIndex);


      // Get new circuit index from neighbor (fallback to 0)
      int newCircuitIndex = 0;
      if (_selectedExercisesWithCircuits.isNotEmpty) {
        if (newIndex == 0) {
          newCircuitIndex =
              _selectedExercisesWithCircuits.first['circuitIndex'] ?? 0;
        } else if (newIndex >= _selectedExercisesWithCircuits.length) {
          newCircuitIndex =
              _selectedExercisesWithCircuits.last['circuitIndex'] ?? 0;
        } else {
          newCircuitIndex =
              _selectedExercisesWithCircuits[newIndex]['circuitIndex'] ?? 0;
        }
      }

      movedExercise['circuitIndex'] = newCircuitIndex;

      _cachedProgressedValues.clear();
      _e1rmTargetCache.clear();
      _synthHintCache.clear();

      // Insert at new position
      _selectedExercisesWithCircuits.insert(newIndex, movedExercise);
      _workoutSets.insert(newIndex, movedSets);
      _repsControllers.insert(newIndex, movedReps);
      _weightControllers.insert(newIndex, movedWeight);
      _rirControllers.insert(newIndex, movedRir);
      _velocityControllers.insert(newIndex, movedVelocity);
      _notesControllers.insert(newIndex, movedNotes);

    });
  }

  //AUTOSAVE FUNCTIONS begin...

  Map<String, dynamic> _buildWorkoutPayload({
    required bool markAllSaved,
    required String uid, // 👈 pass the acting/selected user here
  }) {
    // 1) Sync controllers → _workoutSets (same as in _saveWorkout)
    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      for (int j = 0; j < _workoutSets[i].length; j++) {
        final repsText = _repsControllers[i][j].text.trim();
        final weightText = _weightControllers[i][j].text.trim();
        final rirText = _rirControllers[i][j].text.trim();
        final velocityText = _velocityControllers[i][j].text.trim();
        final notesText = _notesControllers[i][j].text.trim();

        _workoutSets[i][j].reps =
        repsText.isNotEmpty ? int.tryParse(repsText) : null;
        _workoutSets[i][j].weight =
        weightText.isNotEmpty ? double.tryParse(weightText) : null;
        _workoutSets[i][j].rir =
        rirText.isNotEmpty ? double.tryParse(rirText) : null; // blank → null, not 0
        _workoutSets[i][j].velocity =
        velocityText.isNotEmpty ? double.tryParse(velocityText) : null;
        _workoutSets[i][j].notes = notesText.isNotEmpty ? notesText : null;
      }
    }

    final exercises = <Map<String, dynamic>>[];

    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      final nameRaw = (_selectedExercisesWithCircuits[i]['name'] as String?) ??
          'Unnamed';
      final name = nameRaw
          .trim()
          .isEmpty ? 'Unnamed' : nameRaw.trim();
      final circuitIndex = _selectedExercisesWithCircuits[i]['circuitIndex'] ??
          0;
      final key = _exerciseKey(name, circuitIndex);

      // Only count sets with BOTH weight & reps as training sets.
      // (Optionally keep velocity/notes-only rows if desired.)
      final exId = PeriodizationModelUtils.nameToId[name] ?? name;
      final isBw = PeriodizationModelUtils.isBodyweightExercise(
          id: exId, name: name);

      final setsWithData = _workoutSets[i].where((s) {
        final reps = s.reps ?? 0;
        final double? wOpt = s.weight; // preserve null vs 0.0
        final double? rirOpt = s.rir;

        // "Any data" rule:
        //  - Reps alone is enough
        //  - Weight alone is enough
        //  - RIR alone is enough
        //  - Velocity / notes alone is enough
        final bool hasReps = reps > 0;

        // BW: any explicitly typed value (including 0 = pure BW) counts as data.
        // Non-BW: must be > 0 kg to count as a weight entry.
        final bool hasWeight = isBw
            ? (wOpt != null)
            : ((wOpt ?? 0.0) > 0.0);

        final bool hasRir = (rirOpt != null && rirOpt != 0.0);

        final bool hasOther = ((s.velocity ?? 0.0) > 0) ||
            ((s.notes ?? '').trim().isNotEmpty);

        return hasReps || hasWeight || hasRir || hasOther;
      }).toList();



      if (setsWithData.isEmpty) continue; // “No data gets nothing saved”

// lock BW resolution to the WES workout date (local noon to avoid TZ edges)
      final asOfDate = DateTime(
          _selectedDate.year, _selectedDate.month, _selectedDate.day, 12);


      final ex = <String, dynamic>{
        'name': name,
        'circuitIndex': circuitIndex,
        // ✅ Prefer row's own exerciseId/id; fall back to nameToId lookup.
        'exerciseId': () {
          final rid = (_selectedExercisesWithCircuits[i]['exerciseId'] ?? _selectedExercisesWithCircuits[i]['id'])?.toString().trim() ?? '';
          return rid.isNotEmpty ? rid : (PeriodizationModelUtils.nameToId[name] ?? name);
        }(),

        'sets': setsWithData.map((s) {
          final exId = PeriodizationModelUtils.nameToId[name] ?? name;
          final isBwEx = PeriodizationModelUtils.isBodyweightExercise(
            id: exId,
            name: name,
          );

          // 👉 Normalise blanks:
          //    - reps == 0   → treat as null
          //    - weight == 0 → treat as null
          final int? repsVal =
          (s.reps == null || s.reps == 0) ? null : s.reps;
          final double? weightVal =
          (s.weight == null || s.weight == 0.0) ? null : s.weight;

          if (isBwEx) {
            // If user entered an added weight → treat normally
            if (weightVal != null) {
              final added = weightVal;
              final abs = PeriodizationModelUtils.toAbsoluteWeight(
                uid: uid,
                displayAddedKg: added,
                exerciseId: exId,
                exerciseName: name,
                asOfDate: _selectedDate,
              );

              return {
                if (repsVal != null) 'reps': repsVal,   // 👈 omit if null
                'weight': abs,
                'weightAdded': added,
                'addedWeight': added,
                'rir': s.rir ?? 0.0,                    // 👈 ONLY RIR defaults to 0
                if (s.velocity != null) 'velocity': s.velocity,
                if ((s.notes ?? '').trim().isNotEmpty) 'notes': s.notes,
              };
            }

            // If NO added weight was typed → reps/RIR-only BW set
            return {
              if (repsVal != null) 'reps': repsVal,
              'rir': s.rir ?? 0.0,
              if (s.velocity != null) 'velocity': s.velocity,
              if ((s.notes ?? '').trim().isNotEmpty) 'notes': s.notes,
            };
          }

          // NON–bodyweight exercises
          return {
            if (repsVal != null) 'reps': repsVal,        // 👈 0 treated as blank
            if (weightVal != null) 'weight': weightVal,  // 👈 0 treated as blank
            'rir': s.rir ?? 0.0,                         // 👈 still 0 by default
            if (s.velocity != null) 'velocity': s.velocity,
            if ((s.notes ?? '').trim().isNotEmpty) 'notes': s.notes,
          };
        }).toList(),

      };



      // Saved-format marker:
      // - On global Save -> mark saved if the exercise has at least one non-empty set
      // - Otherwise -> respect per-exercise "Done" state
      final bool markThisSaved = markAllSaved
          ? setsWithData.isNotEmpty
          : _savedExerciseKeysForDate.contains(key);


      if (markThisSaved) {
        ex['saved'] = true; // optional boolean
        ex['savedAt'] = Timestamp.now(); // ✅ allowed inside arrays
      }

      exercises.add(ex);
    }

    return {
      'name': _workoutNameController.text
          .trim()
          .isEmpty
          ? _formatWorkoutDate(_selectedDate)
          : _workoutNameController.text.trim(),
      'date': _selectedDate.toIso8601String(),
      'userId': uid, // 👈 no context used
      'exercises': exercises, // replaces entire array on set()
      'lastEditedAt': FieldValue.serverTimestamp(),
    };
  }


  Future<void> _pushTopSetsToBlockDataIfAny() async {
    final uid = _cachedUid ??
        FirebaseAuth.instance.currentUser?.uid; // ← context-free

    final blockId = _selectedBlockId ??
        widget.blockId; // prefer selected, fallback to prop
    if (uid == null || blockId == null || blockId.isEmpty) {
      print('🚫 [BB2 Push] Missing uid or blockId — skipping.');
      return;
    }

    // Resolve block start date: prefer in-memory, else fetch
    DateTime? blockStart = _blockStartDate;
    if (blockStart == null) {
      final blockRef = FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks')
          .doc(blockId);
      final snap = await blockRef.get();
      if (!snap.exists) {
        print('🚫 [BB2 Push] Block doc not found — skipping.');
        return;
      }
      // support both Timestamp('startDate') and String('blockStartDate')
      final ts = snap.data()?['startDate'];
      if (ts is Timestamp) {
        blockStart = ts.toDate();
      } else {
        final str = snap.data()?['blockStartDate'];
        if (str is String) {
          blockStart = DateTime.tryParse(str);
        }
      }
      if (blockStart == null) {
        print('🚫 [BB2 Push] Could not resolve blockStartDate — skipping.');
        return;
      }
    }

    final daysSinceStart = _selectedDate
        .difference(blockStart)
        .inDays;
    final weekIndex = (daysSinceStart / 7).floor();
    final dayIndex = (daysSinceStart % 7 + 7) % 7; // guard negative

    final blockRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId);

    final weekDocRef = blockRef.collection('weeks').doc('week_$weekIndex');
    await weekDocRef.set({'exists': true}, SetOptions(merge: true));

    // Build updatedExercises from best set per exercise
    final List<Map<String, dynamic>> updatedExercises = [];

    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      final name = (_selectedExercisesWithCircuits[i]['name'] as String?)
          ?.trim() ?? 'Unnamed';
      final circuitIndex = _selectedExercisesWithCircuits[i]['circuitIndex'] ??
          0;
      if (i >= _workoutSets.length) continue;

      // keep only sets with any data
      final validSets = _workoutSets[i].where((s) {
        final reps = s.reps ?? 0;
        final weight = s.weight ?? 0.0;
        return reps > 0 && weight > 0; // 👈 require both
      }).toList();
      if (validSets.isEmpty) continue;

      // choose best by E1RM
      SetDetails? best = validSets.fold<SetDetails?>(null, (prev, curr) {
        if (prev == null) return curr;
        final prevE = calculateE1RM(
            prev.weight, prev.reps?.toDouble(), prev.rir);
        final currE = calculateE1RM(
            curr.weight, curr.reps?.toDouble(), curr.rir);
        return currE > prevE ? curr : prev;
      });

      if (best == null || best.weight == null || best.reps == null) continue;

      final isBw = PeriodizationModelUtils.isBodyweightExercise(name: name);
      final asOf = _selectedDate;

      double? absForCalc;
      if (best.weight != null) {
        absForCalc = isBw
            ? PeriodizationModelUtils.toAbsoluteWeight(
          uid: uid ?? '',
          displayAddedKg: best.weight!,
          exerciseName: name,
          asOfDate: asOf,
        )
            : best.weight!;
      }

      final topSet = <String, dynamic>{
        'name': name,
        'circuitIndex': circuitIndex,
        'weight': absForCalc, // 👈 now always ABS
        'reps': best.reps,
        'rir': best.rir ?? 0.0,
      };
      if ((best.velocity ?? 0) > 0) topSet['velocity'] = best.velocity;
      if ((best.notes ?? '')
          .toString()
          .trim()
          .isNotEmpty) topSet['notes'] = best.notes;

      topSet['wesOverlay'] = true; // ← tag as WES overlay so we can prune later
      updatedExercises.add(topSet);
    }


    // Merge with existing day doc, keeping highest E1RM per exercise
    final dayDocRef = weekDocRef.collection('days').doc('day_$dayIndex');
    // Read server-first so we prune against fresh data
    DocumentSnapshot<Map<String, dynamic>> existingSnap;
    try {
      existingSnap =
      await dayDocRef.get(const GetOptions(source: Source.server));
    } catch (_) {
      existingSnap = await dayDocRef.get();
    }
    final List<Map<String, dynamic>> existing =
    List<Map<String, dynamic>>.from(existingSnap.data()?['exercises'] ?? []);

// --- BEGIN: prune stale WES overlays when this save has no valid sets for them ---
    String _k(Map e) =>
        '${(e['name'] ?? '').toString().trim()}|${e['circuitIndex'] ?? 0}';
    final Set<String> updatedKeys = { for (final e in updatedExercises) _k(e)};

    bool _prunedAny = false;
    for (int i = 0; i < existing.length; i++) {
      final e = existing[i];
      if (e is! Map) continue;
      if (e['wesOverlay'] == true && !updatedKeys.contains(_k(e))) {
        e.remove('reps');
        e.remove('weight');
        e.remove('rir');
        e.remove('velocity');
        e.remove('notes');
        e.remove('sets');
        e.remove('wesOverlay');
        existing[i] = e;
        _prunedAny = true;
      }
    }
// --- END: prune stale WES overlays ---

// If there are no new top sets to push this save, we may still need to write the prune result.
    if (updatedExercises.isEmpty) {
      if (_prunedAny) {
        await dayDocRef.set({'exercises': existing}, SetOptions(merge: true));
        print(
            '🧹 [BB2 Push] Cleared stale WES overlays for $_prunedAny exercise(s).');
      } else {
        print('🔸 [BB2 Push] No valid sets and nothing to prune.');
      }
      return; // ← safe exit after handling demotion case
    }


    for (final newEx in updatedExercises) {
      final idx = existing.indexWhere((e) =>
      (e['name'] as String?)?.trim() == (newEx['name'] as String?)?.trim() &&
          (e['circuitIndex'] ?? 0) == (newEx['circuitIndex'] ?? 0));

      if (idx == -1) {
        existing.add(newEx);
      } else {
        final asOf = _selectedDate;
        final isBw = PeriodizationModelUtils.isBodyweightExercise(
          name: (existing[idx]['name'] ?? '').toString(),
        );

        final double? oldAbs = isBw
            ? PeriodizationModelUtils.toAbsoluteWeight(
          uid: uid ?? '',
          displayAddedKg: (existing[idx]['weight'] as num?)?.toDouble() ?? 0.0,
          exerciseName: (existing[idx]['name'] ?? '').toString(),
          asOfDate: asOf,
        )
            : (existing[idx]['weight'] as num?)?.toDouble();

        final oldE = calculateE1RM(
          oldAbs,
          (existing[idx]['reps'] as num?)?.toDouble(),
          existing[idx]['rir'],
        );

        final newE = calculateE1RM(
          newEx['weight'],
          (newEx['reps'] as num?)?.toDouble(),
          newEx['rir'],
        );

        if (newE > oldE) existing[idx] = newEx;
      }
    }


    await dayDocRef.set({'exercises': existing}, SetOptions(merge: true));
    print('✅ [BB2 Push] Wrote top sets for week_$weekIndex/day_$dayIndex');
  }

  Future<void> _saveSingleRowToFirestore({
    required int rowIndex,
    required int setIndex,
  }) async {
    print('💾 [INLINE SAVE] Triggered for row=$rowIndex set=$setIndex');

    // Claude_bullet: debounced snapshot save on every edit
    Claude_bulletScheduleDebouncedSave();

    try {
      final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        print('❌ [INLINE SAVE] No uid, aborting');
        return;
      }

      // Build a fresh payload from the CURRENT UI, using your canonical builder.
      // This will:
      //  - sync controllers -> _workoutSets
      //  - do BW absolute/added weight conversion
      //  - include only setsWithData
      final payload = _buildWorkoutPayload(
        markAllSaved: false,
        uid: uid,
      );

      final exercises = payload['exercises'];
      if (exercises is! List || exercises.isEmpty) {
        print('💾 [INLINE SAVE] Payload has no exercises, skipping write');
        return;
      }

      final String docId = _workoutDocIdForDate(_selectedDate);
      final docRef = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('workouts')
          .doc(docId);

      print('💾 [INLINE SAVE] About to write exercises=${exercises.length} to Firestore for $docId');
      print('🧾 [INLINE SAVE] payload.exercises[0]=${(exercises.isNotEmpty) ? exercises[0] : 'EMPTY'}');

      // Write ONLY the fields we know are safe and cheap to update frequently.
      await docRef.set(
        {
          'name': payload['name'],
          'date': payload['date'],
          'userId': uid,
          'exercises': exercises,
          'lastEditedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true), // don’t clobber wesPlannedExercises etc.
      );

      print('✅ [INLINE SAVE] Firestore write complete for row=$rowIndex set=$setIndex');
      // 🔁 ALSO refresh local WES init snapshot hints
      try {
        final bid = _selectedBlockId ?? _activeBlockId;
        if (bid != null && bid.isNotEmpty) {
          final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);

          // Build ONLY the hint map (cheap, synchronous)
          final Map<String, dynamic> hints = {};

          for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
            final name = (_selectedExercisesWithCircuits[i]['name'] ?? '').toString().trim();
            if (name.isEmpty) continue;

            final ci   = (_selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0) as int;
            final key  = '${name.toLowerCase()}|$ci';

            final double s1W  = set1SuggestedWeight(i);
            final double s1R  = set1SuggestedReps(i);
            final double s1Ri = getRirFromPlanOrInput(i, 1);

            final exId = PeriodizationModelUtils.nameToId[name] ?? name;
            final isBw = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: name);

            final double absForE1 = isBw
                ? PeriodizationModelUtils.toAbsoluteWeight(
              uid: uid,
              displayAddedKg: s1W,
              exerciseId: exId,
              exerciseName: name,
              asOfDate: _selectedDate,
            )
                : s1W;

            final double e1 = PeriodizationModelUtils.calculateE1RM(
              absForE1,
              s1R.toDouble(),
              s1Ri,
            );

            hints[key] = isBw
                ? {
              's1_weight_added': s1W,
              's1_reps': s1R,
              's1_rir': s1Ri,
              'e1rm': e1,
            }
                : {
              's1_weight': s1W,
              's1_reps': s1R,
              's1_rir': s1Ri,
              'e1rm': e1,
            };
          }

          await BlockPlanCache.putInitSnapshot(
            uid: uid,
            blockId: bid,
            dateYmd: ymd,
            plannedExercises: const [],
            wesPlannedExercises: const [],
            previousWorkout: const [],
            topSetHistory: const [],
            hintsJson: jsonEncode(hints),
            hintsInputsHash: _computeNowInputsHash(),
            hintsReady: hints.isNotEmpty,
            schemaVersion: kWesSnapshotSchema,
            updatedAt: DateTime.now(),
          );

          debugPrint('💾 [INLINE SAVE] Local WES snapshot refreshed ($ymd)');


        }
      } catch (e) {
        debugPrint('⚠️ [INLINE SAVE] Snapshot refresh failed: $e');
      }

    } catch (e, st) {
      print('❌ [INLINE SAVE] Failed to save single row (row=$rowIndex set=$setIndex): $e');
      print(st);
    }
  }



  Future<void> _upsertWorkoutToFirestore({
    required bool alsoPushToBB2,
    bool markAllSaved = false,
  }) async {
    print(
        '🚀 [WES upsert] Starting upsert (markAllSaved=$markAllSaved, pushBB2=$alsoPushToBB2)');
    final _upsertSw = Stopwatch()..start();
    try {


      // Ensure controllers → _workoutSets are in sync for the first-exit case
    await _persistDraftLocally();
    bool _printedUpsertBw = false;

    final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return;
    }

    final docId = _workoutDocIdForDate(_selectedDate);
    final coll = FirebaseFirestore.instance.collection('users')
        .doc(uid)
        .collection('workouts');
    final docRef = coll.doc(docId);

    // ⬇️ NEW: read existing doc so we can preserve previously-completed entries if user clears fields

    final _tGetStart = _upsertSw.elapsedMilliseconds;;
    final existingSnap = await docRef.get();

    final _tGetEnd = _upsertSw.elapsedMilliseconds;
    print('✅ [WES upsert] finished docRef.get() (+${_tGetEnd - _tGetStart} ms)');

    final List<Map<String, dynamic>> existingExercises =
    List<Map<String, dynamic>>.from(
        existingSnap.data()?['exercises'] ?? const []);
    final List<Map<String, dynamic>> existingWesPlanned =
    List<Map<String, dynamic>>.from(
        existingSnap.data()?['wesPlannedExercises'] ?? const []);

    final bool hadExisting = existingExercises.isNotEmpty;

    Map<String, dynamic> payload;
    try {
      payload = _buildWorkoutPayload(markAllSaved: markAllSaved, uid: uid);
    } catch (e, st) {
      print(
          '❌ [WES upsert] Payload build threw (likely context access in builder): $e');
      print(st);
      return;
    }

    // What the user typed this visit (only sets with BOTH weight & reps, per your builder)
    final List<Map<String, dynamic>> newExercises =
    List<Map<String, dynamic>>.from(
        (payload['exercises'] as List?) ?? const []);


    // ── BW-only: convert display "added" → ABSOLUTE for newly edited rows ──
    for (final e in newExercises) {
      final name = (e['name'] ?? '').toString();
      if (name.isEmpty) continue;

      final id = PeriodizationModelUtils.nameToId[name] ?? name;

      // Leave non-BW untouched
      if (!PeriodizationModelUtils.isBodyweightExercise(id: id, name: name))
        continue;

      // Prefer set-level structure; support legacy top-level too
      final sets = (e['sets'] is List) ? List<Map<String, dynamic>>.from(
          e['sets']) : null;

      // Use the selected date so ABSOLUTE is anchored to that day’s BW at time of save
      final DateTime? asOf = _selectedDate;

      if (sets != null) {
        // Map this exercise to its UI row so we can read the typed controllers
        final String nameKey = name.trim().toLowerCase();
        final int i = _selectedExercisesWithCircuits.indexWhere((row) =>
        ((row['name'] ?? '') as String).trim().toLowerCase() == nameKey &&
            (row['circuitIndex'] ?? 0) == (e['circuitIndex'] ?? 0));

        for (int j = 0; j < sets.length; j++) {
          final s = sets[j];

          // ✅ Always take the user-typed "added" (controllers) for BW sets.
          // Ignore whatever is currently in s['weight'] for BW.
          double added = 0.0;
          if (i >= 0 &&
              i < _weightControllers.length &&
              j < _weightControllers[i].length) {
            added = double.tryParse(_weightControllers[i][j].text) ?? 0.0;
          } else {
            // Fallback: if controller index not found, use explicit addedWeight if present, else the map
            added = (s['addedWeight'] as num?)?.toDouble()
                ?? (s['weight'] as num?)?.toDouble()
                ?? 0.0;
          }
          if (added < 0) added = 0.0;

          final DateTime? asOf = _selectedDate;
          final double abs = PeriodizationModelUtils.toAbsoluteWeight(
            uid: uid,
            displayAddedKg: added,
            exerciseId: id,
            exerciseName: name,
            asOfDate: asOf,
          );

          final double bw = PeriodizationModelUtils.bodyweightKgForDate(
              uid: uid, asOf: asOf);
          print('🧪[UP] $name set#$j typedAdded=$added, bw=$bw → save abs=$abs');

          // Persist both: absolute for math/history, and the exact typed added value
          s['weight'] = abs; // ABSOLUTE = BW + ADDED
          s['addedWeight'] = added; // the typed ADDED kg
        }

        e['sets'] = sets; // write back
      }
      else {
        // Legacy: single top-level weight
        double added = (e['weight'] as num?)?.toDouble() ?? 0.0;
        if (added < 0) added = 0.0;

        final abs = PeriodizationModelUtils.toAbsoluteWeight(
          uid: uid,
          displayAddedKg: added,
          exerciseId: id,
          exerciseName: name,
          asOfDate: asOf,
        );

        e['weight'] = abs;
        e['addedWeight'] = added;
      }
    }

    // Helper key for matching (same fields you already use elsewhere)
    String exKey(Map e) =>
        '${(e['name'] ?? '').toString().trim()}|${e['circuitIndex'] ?? 0}';

    // NEW BEHAVIOR: even if no qualifying sets were entered this visit,
// build wesPlannedExercises from current UI rows (per-athlete, per-date)
// and write that (no BB2 push). This enables "revert to WES-planned".
        {
      // Safety: if user truly made no changes and UI is empty, don't clobber.
      if (_selectedExercisesWithCircuits.isEmpty && hadExisting &&
          !_pendingChanges) {
        print(
            '🔸 [WES upsert] No UI rows & no changes; preserving existing workout (no write).');
        _pendingChanges = false;
        _lastSavedHash = null;
        await _persistSavedFlagsLocally();
        await _persistDraftLocally();
        return;
      }
      // fall-through — we will compute wesPlanned from the live UI below for all cases
    }

    // === Compute WES PLANNED (no qualifying sets) from the current UI ===
// Map existing planned by key to preserve createdAt when possible
    final Map<String, Map<String, dynamic>> existingPlannedByKey = {
      for (final p in existingWesPlanned)
        _wesKeyPrefId((p['name'] ?? '').toString().trim(),
            (p['circuitIndex'] ?? 0) as int): Map<String, dynamic>.from(p)
    };

// Helper to check if a row has at least one qualifying set (same semantics as builder)
    bool _rowHasQualifyingSet({
      required int rowIndex,
      required String name,
    }) {
      final exId = PeriodizationModelUtils.nameToId[name] ?? name;
      final isBw = PeriodizationModelUtils.isBodyweightExercise(
          id: exId, name: name);
      for (final s in _workoutSets[rowIndex]) {
        final reps = s.reps ?? 0;
        final double? wOpt = s.weight;
        final hasWR = isBw ? (reps > 0 && wOpt != null)
            : (reps > 0 && (wOpt ?? 0.0) > 0.0);
        final hasOther = ((s.velocity ?? 0.0) > 0) || ((s.notes ?? '')
            .trim()
            .isNotEmpty);
        if (isBw ? hasWR : (hasWR || hasOther)) return true;
      }
      return false;
    }

// Build fresh planned list ONLY from rows currently in UI that do NOT qualify,
// and are NOT BB2-planned (so they remain BB2-owned).
    final Map<String, Map<String, dynamic>> wesPlannedByKey = {};
    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      final name = ((_selectedExercisesWithCircuits[i]['name'] ?? '') as String)
          .trim();
      final ci = (_selectedExercisesWithCircuits[i]['circuitIndex'] ??
          0) as int;
      if (name.isEmpty) continue;

      final keyId = _wesKeyPrefId(name, ci);
      final qualifies = _rowHasQualifyingSet(rowIndex: i, name: name);
      final isBb2Planned = _bb2PlannedKeysForSelectedDate.contains(keyId);
      print('   bb2Owned? → $isBb2Planned');

      if (!qualifies && !isBb2Planned) {
        final prior = existingPlannedByKey[keyId];
        wesPlannedByKey[keyId] = {
          'exerciseId': PeriodizationModelUtils.nameToId[name] ?? name,
          'name': name,
          'circuitIndex': ci,
          'source': 'wes',
          if (prior != null &&
              prior['createdAt'] != null) 'createdAt': prior['createdAt'],
          if (prior == null) 'createdAt': Timestamp.now(),

        };
      }
    }

// Install planned list into payload (fresh each write based on UI)
    payload['wesPlannedExercises'] = wesPlannedByKey.values.toList();

    payload['exercises'] = newExercises;

    final currentHash = payload.hashCode.toString();
    if (_lastSavedHash == currentHash) {
      print(
          '🔸 [WES upsert] Payload unchanged from last save — skipping Firestore write.');
      return;
    }

    try {
      final _exCount = (payload['exercises'] as List?)?.length ?? 0;
      final _wesCount = (payload['wesPlannedExercises'] as List?)?.length ?? 0;
      print(
          '📝 [WES upsert] Writing doc $docId for uid=$uid (exercises=$_exCount, wesPlanned=$_wesCount)...');

      print('⏳ [WES upsert] starting Firestore write...');
      final _tWriteStart = _upsertSw.elapsedMilliseconds;
      await docRef.set(payload, SetOptions(merge: false));
      final _tWriteEnd = _upsertSw.elapsedMilliseconds;
      print('✅ [WES upsert] Firestore write complete (+${_tWriteEnd - _tWriteStart} ms)');




      // 🔥 [WES upsert → Warm] Precompute WES snapshots for *today* and *tomorrow* (fire-and-forget).
// Uses the *selected athlete* uid from this save, and the currently selected block id.
      try {
        final String? blockId = _selectedBlockId ?? _activeBlockId;
        if (blockId == null || blockId.isEmpty) {
          debugPrint('⚠️ [WES upsert] Skipping warm — no active block id.');
        } else {
          // Normalize to LOCAL date-only to avoid UTC/local drift.
          final DateTime d0 = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
          final DateTime d1 = d0.add(const Duration(days: 1));

          // Selected athlete UID (NOT necessarily the logged-in user)
          final String uidSelected = uid;

          // Kick both warms. warmWES is already non-blocking internally.
          WarmupService.instance.warmWES(
            uidSelected,
            activeBlockId: blockId,
            selectedDate: d0,
          );
          WarmupService.instance.warmWES(
            uidSelected,
            activeBlockId: blockId,
            selectedDate: d1,
          );
          debugPrint('✅ [WES upsert] Warm kicked for $d0 and $d1 (uid=$uidSelected, block=$blockId)');
        }
      } catch (e, st) {
        debugPrint('⚠️ [WES upsert] Warm kick failed: $e');
      }

      // ✅ Kick off RE Daily compute/write in the background (don’t block save UI)
      try {
        final uid2 = uid;           // capture
        final dayKey = docId;       // exactly "yyyy-MM-dd"

        debugPrint('[RE] kickoff scheduling for dayKey=$docId uid=$uid');

        // run fully in the background
        () async {
          debugPrint('[RE] kickoff ENTER for dayKey=$dayKey uid=$uid2');
          try {
            // Read biological sex from the user doc
            final userSnap = await FirebaseFirestore.instance
                .collection('users')
                .doc(uid2)
                .get();

            final sexRaw = (userSnap.data()?['sex'] as String?)?.trim().toLowerCase();

            final isFemale = sexRaw == 'female' || sexRaw == 'f' || sexRaw == 'woman' || sexRaw == 'w';
            final genderEnum = isFemale ? formula.Gender.female : formula.Gender.male;

            await DailyReCalculator().computeAndWrite(
              uid: uid2,
              dayKey: dayKey,
              gender: genderEnum,
            );

            debugPrint('✅ [RE Daily] compute+write done for $dayKey');
          } catch (e, st) {
            debugPrint('⚠️ [RE Daily] compute failed for $dayKey: $e');
          }
        }();
      } catch (e) {
        debugPrint('⚠️ [RE Daily] kickoff failed for $docId: $e');
      }

      // 🔁 Keep public profile stats fresh (only if there are completed sets)
      final hasExercises = ((payload['exercises'] as List?)?.isNotEmpty ?? false);
      if (hasExercises) {
        print('⏳ [WES upsert] scheduling updateStatsFromWorkout...');
        final _tStatsStart = _upsertSw.elapsedMilliseconds;
        () async {
          try {
            await updateStatsFromWorkout(uid: uid, workout: payload);
            final _tStatsEnd = _upsertSw.elapsedMilliseconds;
            print('✅ [WES upsert] finished updateStatsFromWorkout (+${_tStatsEnd - _tStatsStart} ms)');
          } catch (e) {
            print('⚠️ [WES upsert] Stats snapshot update failed: $e');
          }
        }();
      }


      _lastSavedHash = currentHash;
      _pendingChanges = false;

      if (alsoPushToBB2) {
        print('📤 [WES upsert] scheduling BB2 top-sets push (background)…');
        () async {
          final _bgSw = Stopwatch()..start();
          try {
            print('⏳ [WES upsert] (bg) starting _pushTopSetsToBlockDataIfAny()...');
            await _pushTopSetsToBlockDataIfAny();
            print('✅ [WES upsert] (bg) finished _pushTopSetsToBlockDataIfAny (+${_bgSw.elapsedMilliseconds} ms)');
          } catch (e) {
            print('⚠️ [WES upsert] (bg) top-sets push failed: $e');
          }
        }();
      }


      await _persistSavedFlagsLocally();
      await _persistDraftLocally();
    } catch (e, st) {
      print('❌ [WES upsert] Firestore write failed: $e');
      print(st);
    }
    } finally {
      print('⏱️ [WES upsert] total=${_upsertSw.elapsedMilliseconds} ms');
    }
  }



  bool _isExerciseSaved(int index) {
    if (index < 0 || index >= _selectedExercisesWithCircuits.length)
      return false;

    final name = (_selectedExercisesWithCircuits[index]['name'] as String?)
        ?.trim() ?? 'Unnamed';
    final circuitIndex = _selectedExercisesWithCircuits[index]['circuitIndex'] ??
        0;

    final key = _exerciseKey(name,
        circuitIndex); // 👈 you already have this helper from earlier steps

    return _savedExerciseKeysForDate.contains(key);
  }

  Future<void> _markExerciseSaved(int index) async {
    if (index < 0 || index >= _selectedExercisesWithCircuits.length) return;

    final name = (_selectedExercisesWithCircuits[index]['name'] as String?)
        ?.trim() ?? 'Unnamed';
    final circuitIndex = _selectedExercisesWithCircuits[index]['circuitIndex'] ??
        0;

    // ✅ Gate on live controller text so it works immediately as the user types
    if (!_hasTypedWeightAndRepsInAnySet(index)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Add weight and reps to at least one set first.')),
        );
      }
      return;
    }

    setState(() {
      _savedExerciseKeysForDate.add(_exerciseKey(name, circuitIndex));
    });
    await _persistSavedFlagsLocally();

    // Upsert just like autosave; this will include savedAt for this exercise
    await _upsertWorkoutToFirestore(alsoPushToBB2: false, markAllSaved: false);
    await _persistSavedFlagsLocally();
  }


  String _savedFlagsPrefsKey() {
    final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    return 'wes_saved_flags_${uid}_$dateKey';
  }

  Future<void> _persistSavedFlagsLocally() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          _savedFlagsPrefsKey(), _savedExerciseKeysForDate.toList());
      // print('💾 [SavedFlags] persisted: ${_savedExerciseKeysForDate.length}');
    } catch (e) {
      print('❌ [SavedFlags] persist failed: $e');
    }
  }

  Future<Set<String>> _loadSavedFlagsLocally() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_savedFlagsPrefsKey()) ?? const [];
      return list.toSet();
    } catch (e) {
      print('❌ [SavedFlags] load failed: $e');
      return {};
    }
  }

  void _reevaluateSavedFlagsFromControllers() {
    bool changed = false;

    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      final hasTyped = _hasTypedWeightAndRepsInAnySet(i); // uses controllers
      final name = (_selectedExercisesWithCircuits[i]['name'] as String?)
          ?.trim() ?? 'Unnamed';
      final circuitIndex = _selectedExercisesWithCircuits[i]['circuitIndex'] ??
          0;
      final key = _exerciseKey(name, circuitIndex);

      // If no longer eligible, remove saved flag
      if (!hasTyped && _savedExerciseKeysForDate.contains(key)) {
        _savedExerciseKeysForDate.remove(key);
        changed = true;
      }
    }

    if (changed) {
      // Persist and repaint so the green pill disappears immediately
      _persistSavedFlagsLocally();
      if (mounted) setState(() {});
    }
  }


  Future<String?> _saveWorkout() async {

    // 1) Mark every eligible exercise as "saved format" locally (strict: weight+reps in SAME set)
    int eligibleCount = 0;

    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      final name = (_selectedExercisesWithCircuits[i]['name'] as String?)
          ?.trim() ?? 'Unnamed';
      final circuitIndex = _selectedExercisesWithCircuits[i]['circuitIndex'] ??
          0;

      bool eligible = false;
      if (i < _weightControllers.length && i < _repsControllers.length) {
        final len = _weightControllers[i].length;
        for (int j = 0; j < len; j++) {
          final w = double.tryParse(_weightControllers[i][j].text.trim()) ??
              0.0;
          final r = int.tryParse(_repsControllers[i][j].text.trim()) ?? 0;
          if (w > 0 && r > 0) {
            eligible = true;
            break;
          }
        }
      }

      if (eligible) {
        _savedExerciseKeysForDate.add(_exerciseKey(name, circuitIndex));
        eligibleCount++;
      }
    }

    await _persistSavedFlagsLocally(); // keep local flags in sync

    // 2) Upsert → markAllSaved=true (payload will only mark eligible as saved)
    await _upsertWorkoutToFirestore(alsoPushToBB2: false, markAllSaved: true);

    // 3) UI hint
    if (!mounted) return null;
    setState(() {}); // visuals only
    return (eligibleCount > 0)
        ? 'Saved. $eligibleCount exercise${eligibleCount == 1 ? '' : 's'} marked Done.'
        : 'Brah you gotta do some work first, enter at least one set.';


  }


//...AUTOSAVE FUNCTIONS end

  Future<Map<String, dynamic>?> getBB2ExerciseValuesForDate({
    required String exerciseName,
    required DateTime date,
    required DateTime blockStartDate,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    // 1️⃣ Make sure we have a blockId on this screen
    final blockId = widget.blockId;
    if (blockId == null || blockId.isEmpty) return null;

    // 2️⃣ Compute which week/day to read
    final normalizedName = exerciseName.trim().toLowerCase();
    final weekIndex =
    PeriodizationModelUtils.getWeekIndexForDate(date, blockStartDate);
    final dayIndex = date.weekday - 1; // Mon=0 ... Sun=6

    // 3️⃣ Point at planned_blocks/{uid}/blocks/{blockId}/weeks/week_<i>
    final blockRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(blockId);

    final weekDocRef = blockRef.collection('weeks').doc('week_$weekIndex');

    // 4️⃣ Grab that day document
    final daySnapshot =
    await weekDocRef.collection('days').doc('day_$dayIndex').get();

    if (!daySnapshot.exists) return null;

    // 5️⃣ Parse out your saved exercises
    final exercises = List<Map<String, dynamic>>.from(
        daySnapshot.data()?['exercises'] ?? <Map<String, dynamic>>[]);

    // 6️⃣ Find the matching exercise by (lower-case) name
    for (final ex in exercises) {
      final name = (ex['name'] ?? '').toString().trim().toLowerCase();
      if (name == normalizedName) {
        final reps = ex['reps'] is num ? (ex['reps'] as num).toInt() : null;
        final weight =
        ex['weight'] is num ? (ex['weight'] as num).toDouble() : null;
        final rir = ex['rir'] is num ? (ex['rir'] as num).toDouble() : null;

        return {
          'reps': reps,
          'weight': weight,
          'rir': rir,
        };
      }
    }

    return null;
  }

  Future<Map<String, dynamic>?> getBB2SavedValuesFromSharedPrefs(
      String exerciseName, DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    final dateKey = DateFormat('yyyy-MM-dd').format(date);
    final raw = prefs.getString('bb2_dayData_$dateKey');

    if (raw == null) {
      print('❌ [WES] No BB2 SharedPrefs for $dateKey');
      return null;
    }

    final data = jsonDecode(raw);
    final exercises = List<Map<String, dynamic>>.from(data['exercises'] ?? []);

    final match = exercises.firstWhere(
          (e) =>
      (e['name']?.toString().trim().toLowerCase() ?? '') ==
          exerciseName.trim().toLowerCase(),
      orElse: () => {},
    );

    if (match.isNotEmpty) {
      print('🧪 [WES] BB2 SharedPrefs match for "$exerciseName": $match');
      return {
        'reps': match['reps'],
        'weight': match['weight'],
        'rir': match['rir'],
      };
    } else {
      print(
          '🚫 [WES] No matching exercise "$exerciseName" found in SharedPrefs for $dateKey');
      return null;
    }
  }

  Future<void> _saveWorkoutDraftToCache() async {
    // Capture ALL state synchronously BEFORE the first await, because
    // controllers may be disposed during the yield (called from dispose).
    final capturedName = (() {
      try { return _workoutNameController.text; } catch (_) { return ''; }
    })();
    final capturedDate = _selectedDate;
    final capturedExercises = List<Map<String, dynamic>>.from(
        _selectedExercisesWithCircuits.map((e) => Map<String, dynamic>.from(e)));
    final capturedSets = _workoutSets.map((setsForExercise) {
      return setsForExercise
          .map((set) => <String, dynamic>{
                'reps': set.reps,
                'weight': set.weight,
                'rir': set.rir,
              })
          .toList();
    }).toList();

    final dateKey =
        '${capturedDate.year}-${capturedDate.month.toString().padLeft(
        2, '0')}-${capturedDate.day.toString().padLeft(2, '0')}';
    final draftKey = 'workout_draft_$dateKey';
    final timestampKey = 'draft_last_saved_$dateKey';

    try {
      final prefs = await SharedPreferences.getInstance();

      final workoutDraft = {
        'name': capturedName,
        'date': capturedDate.toIso8601String(),
        'exercises': capturedExercises,
        'sets': capturedSets,
      };

      await prefs.setString(draftKey, jsonEncode(workoutDraft));
      await prefs.setString(timestampKey, DateTime.now().toIso8601String());

      debugPrint("[WES_REENTER] _saveWorkoutDraftToCache: saved key=$draftKey");
    } catch (e) {
      debugPrint("[WES_REENTER] _saveWorkoutDraftToCache: FAILED: $e");
    }
  }

  Future<bool> _loadWorkoutDraftFromCache() async {
    // 🔒 FastPaint guard: if FastPaint already hydrated rows+controllers
    // (including _exitDraft overlay), the SharedPrefs draft is redundant
    // and would destructively clear controllers. Skip it.
    if (_didFastPaint) {
      print('[WES_REENTER] _loadWorkoutDraftFromCache: SKIPPED — FastPaint already hydrated');
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    final dateKey =
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(
        2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
    final draftKey = 'workout_draft_$dateKey';
    final timestampKey = 'draft_last_saved_$dateKey';

    print('[WES_REENTER] _loadWorkoutDraftFromCache: key=$draftKey');

    final draftJson = prefs.getString(draftKey);
    final savedAtString = prefs.getString(timestampKey);

    if (draftJson == null || savedAtString == null) {
      // Fallback: try in-memory draft (saved synchronously by previous dispose)
      if (_exitDraft != null && _exitDraft!['dateKey'] == dateKey) {
        debugPrint('[WES_REENTER] _loadWorkoutDraftFromCache: SharedPrefs empty — '
            'using in-memory draft for $dateKey');
        return _hydrateFromExitDraft();
      }
      print('[WES_REENTER] _loadWorkoutDraftFromCache: NOT FOUND for $dateKey');
      return false;
    }

    try {
      final savedAt = DateTime.parse(savedAtString);
      final now = DateTime.now();
      final draft = jsonDecode(draftJson);

      final exercises =
      List<Map<String, dynamic>>.from(draft['exercises'] ?? []);
      final sets = List<List>.from(draft['sets'] ?? []);

      final filteredExercises = <Map<String, dynamic>>[];
      final filteredSets = <List<Map<String, dynamic>>>[];

      for (int i = 0; i < exercises.length; i++) {
        final setList = List<Map<String, dynamic>>.from(sets[i]);
        final hasRealData = setList.any((s) =>
        (s['weight'] ?? 0) > 0 ||
            (s['reps'] ?? 0) > 0 ||
            (s['rir'] ?? 0) > 0);
        if (hasRealData) {
          filteredExercises.add(exercises[i]);
          filteredSets.add(setList);
        }
      }

      final isExpired = now.difference(savedAt) > const Duration(hours: 2);

      if (isExpired) {
        await prefs.remove(draftKey);
        await prefs.remove(timestampKey);

        if (filteredExercises.isEmpty) {
          print('[WES] Draft expired and had no usable data — discarded.');
          return false;
        } else {
          print('[WES] Draft expired, but kept ${filteredExercises
              .length} non-empty exercises.');
        }
      } else {
        if (filteredExercises.isEmpty) {
          print('[WES] Draft is fresh but has no real data — skipping.');
          return false;
        }
        print('[WES] Draft is fresh — all exercises kept.');
      }


      _selectedExercisesWithCircuits.clear();
      _selectedExercisesWithCircuits.addAll(filteredExercises);

      _workoutSets.clear();
      _repsControllers.clear();
      _weightControllers.clear();
      _rirControllers.clear();

      for (int i = 0; i < filteredExercises.length; i++) {
        final setList = filteredSets[i];

        // 👇 NEW: bodyweight-aware rehydration (UI shows "added" for BW)
        final exName = ((filteredExercises[i]['name'] ?? '') as String).trim();
        final exId = PeriodizationModelUtils.nameToId[exName] ?? exName;
        final isBwEx = PeriodizationModelUtils.isBodyweightExercise(
            id: exId, name: exName);
        final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
        final DateTime? workoutDate = _selectedDate; // draft is for this day

        _workoutSets.add(setList
            .map((s) {
          final abs = (s['weight'] as num?)?.toDouble();
          final added = (s['weightAdded'] as num?)?.toDouble();
          final display = isBwEx
              ? (added ??
              (abs != null
                  ? PeriodizationModelUtils.toDisplayAddedWeight(
                uid: uid,
                absoluteKg: abs,
                exerciseId: exId,
                exerciseName: exName,
                asOfDate: workoutDate,
              )
                  : null))
              : abs;
          return SetDetails(
            reps: s['reps'],
            weight: display,
            rir: (s['rir'] as num?)?.toDouble(),
          );
        }).toList());


        _repsControllers
            .add(List.generate(setList.length, (_) => TextEditingController()));

        _weightControllers
            .add(List.generate(setList.length, (_) => TextEditingController()));
        _rirControllers
            .add(List.generate(setList.length, (_) => TextEditingController()));
      }

      _initializeControllers();
      _workoutNameController.text = draft['name'] ?? '';

      print(
          '[WES] Loaded draft (expired=$isExpired, kept=${filteredExercises
              .length})');

      return true;
    } catch (e) {
      debugPrint('[WES] Failed to load workout draft for $dateKey: $e');
      return false;
    }
  }


  /// Hydrate WES state from the static [_exitDraft]. Used as a fallback when
  /// SharedPreferences draft is not yet available (async race on fast re-entry).
  bool _hydrateFromExitDraft() {
    if (_exitDraft == null) return false;
    if (_exitDraft!['uid'] != _cachedUid) {
      debugPrint('[WES_REENTER] _hydrateFromExitDraft: uid mismatch '
          '(draft=${_exitDraft!['uid']}, current=$_cachedUid) — skipping');
      return false;
    }
    try {
      final draftExercises = List<Map<String, dynamic>>.from(
          (_exitDraft!['exercises'] as List?) ?? []);
      final draftSets = (_exitDraft!['sets'] as List?) ?? [];

      if (draftExercises.isEmpty || draftSets.isEmpty) return false;

      // Filter to exercises with real data (same logic as _loadWorkoutDraftFromCache)
      final filteredExercises = <Map<String, dynamic>>[];
      final filteredSets = <List<Map<String, dynamic>>>[];

      for (int i = 0; i < draftExercises.length && i < draftSets.length; i++) {
        final setList = List<Map<String, dynamic>>.from(
            (draftSets[i] as List).map((s) => Map<String, dynamic>.from(s as Map)));
        final hasRealData = setList.any((s) =>
            ((s['weight'] as num?) ?? 0) > 0 ||
            ((s['reps'] as num?) ?? 0) > 0 ||
            ((s['rir'] as num?) ?? 0) > 0);
        if (hasRealData) {
          filteredExercises.add(draftExercises[i]);
          filteredSets.add(setList);
        }
      }

      if (filteredExercises.isEmpty) return false;

      _selectedExercisesWithCircuits.clear();
      _selectedExercisesWithCircuits.addAll(filteredExercises);

      _workoutSets.clear();
      _repsControllers.clear();
      _weightControllers.clear();
      _rirControllers.clear();

      for (int i = 0; i < filteredExercises.length; i++) {
        final setList = filteredSets[i];

        final exName = ((filteredExercises[i]['name'] ?? '') as String).trim();
        final exId = PeriodizationModelUtils.nameToId[exName] ?? exName;
        final isBwEx = PeriodizationModelUtils.isBodyweightExercise(
            id: exId, name: exName);
        final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';

        _workoutSets.add(setList.map((s) {
          final abs = (s['weight'] as num?)?.toDouble();
          final display = isBwEx
              ? (abs != null
                  ? PeriodizationModelUtils.toDisplayAddedWeight(
                      uid: uid,
                      absoluteKg: abs,
                      exerciseId: exId,
                      exerciseName: exName,
                      asOfDate: _selectedDate,
                    )
                  : null)
              : abs;
          return SetDetails(
            reps: (s['reps'] as num?)?.toInt(),
            weight: display,
            rir: (s['rir'] as num?)?.toDouble(),
          );
        }).toList());

        _repsControllers
            .add(List.generate(setList.length, (_) => TextEditingController()));
        _weightControllers
            .add(List.generate(setList.length, (_) => TextEditingController()));
        _rirControllers
            .add(List.generate(setList.length, (_) => TextEditingController()));
      }

      _initializeControllers();
      try {
        _workoutNameController.text = _exitDraft!['workoutName'] ?? '';
      } catch (_) {}

      debugPrint('[WES_REENTER] _hydrateFromExitDraft: restored '
          '${filteredExercises.length} exercises from in-memory draft');
      _exitDraft = null; // consumed
      return true;
    } catch (e) {
      debugPrint('[WES_REENTER] _hydrateFromExitDraft: FAILED: $e');
      return false;
    }
  }

  Future<void> _mergeNewBB2ExercisesIntoDraft() async {
    // Tripwire 2: Phase 0 already painted — skip merge to preserve restored state
    if (_claudeBulletPhase0Active) {
      print('[WES] _mergeNewBB2ExercisesIntoDraft: SKIPPED — Phase 0 active');
      return;
    }

    final _tMergeBB2 = Stopwatch()
      ..start();
    print('⏱️ [WES] _mergeNewBB2ExercisesIntoDraft started');

    final int _mergeEpoch = _epoch;
    final String _mergeDayKey = _currentDayKey;


    print('👀 [Merge Pre] rows=${_selectedExercisesWithCircuits.length} '
        'sets=${_workoutSets.length} repsCtr=${_repsControllers.length} '
        'wtsCtr=${_weightControllers.length} rirCtr=${_rirControllers.length} '
        'init=$_isInitialized load=$_isLoadingData didFast=$_didFastPaint');

    // 👇 NEW: fast gate to avoid double-running for the same (uid, date)
    final uidGate = UserContext
        .of(context, listen: false)
        .currentUid;
    final sameAsLast = (_lastMergedUid == uidGate) &&
        (_lastMergedDate == _selectedDate);
    if (_hasCompletedInitialMergeForThisDate && sameAsLast) {
      print(
          '⏭️ [WES] merge already completed for uid=$uidGate date=$_selectedDate — skipping STRUCTURE merge, but still refreshing BB2 values');
      // IMPORTANT: do NOT return; we still want the latest BB2 values (reps/weight/rir)
      // to refresh hint precedence even when rows already exist in WES.
    }

    _isMergingBB2.value = true;

    try {
      print(
          '[WES] Attempting to merge BB2 exercises into draft for $_selectedDate');

      final uid = UserContext
          .of(context, listen: false)
          .currentUid;
      if (_selectedBlockId == null || _selectedDate == null) return;

      print('👤 [BB2 Merge] Using uid=$uid for athlete merge');

      // ✅ Clear state only if the selected athlete or date has changed
      final shouldForceMerge = _lastMergedUid != uid ||
          _lastMergedDate != _selectedDate;
      _lastMergedUid = uid;
      _lastMergedDate = _selectedDate;
      // REPLACE: force-merge repaint with deferred, hash-guarded reset (no immediate setState)
      int? __preStructMergeReset;
      bool __didResetStruct = false;
      if (shouldForceMerge) {
        print('🔁 [WES] Triggering BB2 merge due to athlete/date switch (deferred repaint)');

        final bool _userHasTyped =
            _weightControllers.any((row) => row.any((c) => c.text.trim().isNotEmpty)) ||
                _repsControllers.any((row) => row.any((c) => c.text.trim().isNotEmpty))   ||
                _rirControllers.any((row) => row.any((c) => c.text.trim().isNotEmpty));

// Only clear if we did NOT fast-paint this date.
        if (!_didFastPaint && !_userHasTyped) {
          __preStructMergeReset = _structureHash();   // ← move here

          // Mutate without setState; we’ll batch the repaint later only if needed.
          _selectedExercisesWithCircuits.clear();
          _workoutSets.clear();
          _repsControllers.clear();
          _weightControllers.clear();
          _rirControllers.clear();
          _velocityControllers.clear();
          _notesControllers.clear();
          _resolvedBB2Values.clear();

          __didResetStruct = true;
        } else {
          print('🟢 [WES] Preserving rows (fast paint or user typed); will union BB2 without reset');
        }




        _lastMergedUid = uid;
        _lastMergedDate = _selectedDate;
      }


      // insert under this line
      _hasCompletedInitialMergeForThisDate =
      false; // allow one merge for new uid/date


      _attachDirtyListeners(); // keep controllers wired

      final blockId = _selectedBlockId!;
      final daysSinceStart = _selectedDate
          .difference(blockStartDate!)
          .inDays;
      if (daysSinceStart < 0) return;
      print('[WES Merge] daysSinceStart = $daysSinceStart');

// 👇 ADD THIS BLOCK
      final String _ymdSelected = DateFormat('yyyy-MM-dd').format(_selectedDate);
// Purge BB2 rows that belong to other days (tagged as bb2|<ymd>|...)
      for (int idx = _selectedExercisesWithCircuits.length - 1; idx >= 0; idx--) {
        final String? cardId = _selectedExercisesWithCircuits[idx]['cardId'] as String?;
        if (cardId == null) continue;

        final bool isBB2 = cardId.startsWith('bb2|');
        final bool forOtherDay = isBB2 && !cardId.startsWith('bb2|$_ymdSelected|');
        if (forOtherDay) {
          _selectedExercisesWithCircuits.removeAt(idx);
          if (idx < _workoutSets.length) _workoutSets.removeAt(idx);
          if (idx < _repsControllers.length) _repsControllers.removeAt(idx);
          if (idx < _weightControllers.length) _weightControllers.removeAt(idx);
          if (idx < _rirControllers.length) _rirControllers.removeAt(idx);
          if (idx < _velocityControllers.length) _velocityControllers.removeAt(idx);
          if (idx < _notesControllers.length) _notesControllers.removeAt(idx);
        }
      }
      final weekIndex = (daysSinceStart / 7).floor();
      final dayIndex = daysSinceStart % 7;

      // --- PRUNE: keep only rows for the selected date before merging BB2 ---
      final String _ymdSel = DateFormat('yyyy-MM-dd').format(_selectedDate);

      bool _rowMatchesSelectedDate(Map<String, dynamic> row) {
        final String cardId = (row['cardId'] ?? '') as String;

        // ⛔️ Ambiguous/legacy rows (no cardId) must NOT be carried across days
        if (cardId.isEmpty) return false;

        // ✅ Warmup/plan snapshot rows are date-scoped like: "YYYY-MM-DD|plan|..."
        if (cardId.startsWith('$_ymdSel|plan|')) return true;

        // ✅ WES user-added rows are date-scoped like: "wes|YYYY-MM-DD|..."
        if (cardId.startsWith('wes|$_ymdSel|')) return true;

        // ✅ BB2 inserts are date-scoped like: "bb2|YYYY-MM-DD|..."
        if (cardId.startsWith('bb2|$_ymdSel|')) return true;

        // Anything else belongs to a different date → drop.
        return false;
      }

// Collect indices to keep for this date
      final List<int> _keepIdx = <int>[];
      for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
        final row = _selectedExercisesWithCircuits[i];
        if (_rowMatchesSelectedDate(row)) _keepIdx.add(i);
      }

      if (_keepIdx.length != _selectedExercisesWithCircuits.length) {
        print('🧹 [WES Merge] Pruning ${_selectedExercisesWithCircuits.length - _keepIdx.length} row(s) not for date=$_ymdSel');

        // Helper to slice by index list
        List<T> _slice<T>(List<T> src) =>
            [for (int i = 0; i < src.length; i++) if (_keepIdx.contains(i)) src[i]];

        if (_isStale(_mergeEpoch) || _mergeDayKey != _currentDayKey) {
          print('⛔️ [Merge] stale (epoch/dayKey) — aborting apply');
          return;
        }

        // Mutate in place (don’t reassign the list variables)
        setState(() {
          final sel  = _slice(_selectedExercisesWithCircuits);
          final sets = _slice(_workoutSets);
          final reps = _slice(_repsControllers);
          final wts  = _slice(_weightControllers);
          final rir  = _slice(_rirControllers);
          final vel  = _slice(_velocityControllers);
          final notes= _slice(_notesControllers);

          _selectedExercisesWithCircuits
            ..clear()
            ..addAll(sel);
          _workoutSets
            ..clear()
            ..addAll(sets);
          _repsControllers
            ..clear()
            ..addAll(reps);
          _weightControllers
            ..clear()
            ..addAll(wts);
          _rirControllers
            ..clear()
            ..addAll(rir);
          _velocityControllers
            ..clear()
            ..addAll(vel);
          _notesControllers
            ..clear()
            ..addAll(notes);
        });
      }


// 1) Primary: planned_blocks weeks/days
// ── CACHE FIRST; then refresh from SERVER in the background ──
      final dayDocRef = FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks')
          .doc(blockId)
          .collection('weeks')
          .doc('week_$weekIndex')
          .collection('days')
          .doc('day_$dayIndex');

// Keep bb2Exercises declared here so all code below can use it
      List<Map<String, dynamic>> bb2Exercises = [];

// ── SUPER-CACHE: try local Isar first for instant paint ──
      try {
        final isarList = await BlockPlanCache.getDay(
          uid: uid,
          blockId: blockId,
          weekIndex: weekIndex,
          dayIndex: dayIndex,
        );
        if (isarList != null && isarList.isNotEmpty) {
          bb2Exercises = isarList;
          print('[WES] BB2 day doc (ISAR) exercises: ${isarList.length}');
        }
      } catch (e) {
        print('[WES] ISAR read failed (non-fatal): $e');
      }

// Cache read (non-blocking first paint if present)
      try {
        final dayDocCache = await dayDocRef.get(
            const GetOptions(source: Source.cache));
        if (dayDocCache.exists && dayDocCache.data()?['exercises'] != null) {
          bb2Exercises =
          List<Map<String, dynamic>>.from(dayDocCache.data()!['exercises']);
          print('[WES] BB2 day doc (CACHE) exercises: ${bb2Exercises.length}');

          // ✅ Save cache hit back to Isar
          await BlockPlanCache.putDay(
            uid: uid,
            blockId: blockId,
            weekIndex: weekIndex,
            dayIndex: dayIndex,
            exercises: bb2Exercises,
          );

          // Background refresh from server (best-effort)
          // ignore: unawaited_futures
          (() async {
            try {
              final srv = await dayDocRef.get(
                  const GetOptions(source: Source.server));
              if (srv.exists && srv.data()?['exercises'] != null) {
                final srvList = List<Map<String, dynamic>>.from(
                    srv.data()!['exercises']);
                if (srvList.length != bb2Exercises.length /* (optional: deep diff) */) {
                  final __preStruct = _structureHash();
                  final __preS1     = _s1ValueHash();

                  // (Apply any in-memory updates you actually do here, if any)

                  final __postStruct = _structureHash();
                  final __postS1     = _s1ValueHash();

                  if (mounted && (__postStruct != __preStruct || __postS1 != __preS1)) {
                    setState(() {});
                  }
                  print('[WES] BB2 day doc refreshed from SERVER');

                  // ✅ Refresh ISAR with server copy
                  await BlockPlanCache.putDay(
                    uid: uid,
                    blockId: blockId,
                    weekIndex: weekIndex,
                    dayIndex: dayIndex,
                    exercises: srvList,
                  );
                }
              }
            } catch (_) {
              /* best-effort */
            }
          })();
        }
      } catch (_) {
        /* cache miss is fine */
      }

// If cache was empty, try server now (still keeping things tight)
      if (bb2Exercises.isEmpty) {
        try {
          final dayDocServer = await dayDocRef.get(
              const GetOptions(source: Source.server));
          if (dayDocServer.exists &&
              dayDocServer.data()?['exercises'] != null) {
            bb2Exercises =
            List<Map<String, dynamic>>.from(dayDocServer.data()!['exercises']);
            print(
                '[WES] BB2 day doc (SERVER) exercises: ${bb2Exercises.length}');

            // ✅ Save server copy into ISAR
            await BlockPlanCache.putDay(
              uid: uid,
              blockId: blockId,
              weekIndex: weekIndex,
              dayIndex: dayIndex,
              exercises: bb2Exercises,
            );
          } else {
            print(
                '[WES] BB2 day doc missing (both CACHE empty & SERVER none) for week_$weekIndex/day_$dayIndex');
          }
        } catch (_) {
          print(
              '[WES] BB2 day doc server read failed (non-fatal) for week_$weekIndex/day_$dayIndex');
        }
      }

// ── Fallback: block_data (CACHE FIRST; then background server refresh) ──
      if (bb2Exercises.isEmpty) {
        final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
        final blockDataRef = FirebaseFirestore.instance
            .collection('planned_blocks')
            .doc(uid)
            .collection('blocks')
            .doc(blockId)
            .collection('block_data')
            .doc(dateKey);

        // Cache read
        bool gotFromCache = false;
        try {
          final blockDataCache = await blockDataRef.get(
              const GetOptions(source: Source.cache));
          if (blockDataCache.exists && blockDataCache.data()?['rows'] != null) {
            bb2Exercises =
            List<Map<String, dynamic>>.from(blockDataCache.data()!['rows']);
            gotFromCache = true;
            print('[WES] BB2 fallback (block_data CACHE) rows: ${bb2Exercises
                .length}');

            // ✅ Save cache hit into ISAR
            await BlockPlanCache.putDay(
              uid: uid,
              blockId: blockId,
              weekIndex: weekIndex,
              dayIndex: dayIndex,
              exercises: bb2Exercises,
            );

            // Background refresh from server
            // ignore: unawaited_futures
            (() async {
              try {
                final srv = await blockDataRef.get(
                    const GetOptions(source: Source.server));
                if (srv.exists && srv.data()?['rows'] != null) {
                  final srvList = List<Map<String, dynamic>>.from(
                      srv.data()!['rows']);
                  if (srvList.length != bb2Exercises.length /* (optional: deep diff) */) {
                    final __preStruct = _structureHash();
                    final __preS1     = _s1ValueHash();

                    // (Apply any in-memory updates you actually do here, if any)

                    final __postStruct = _structureHash();
                    final __postS1     = _s1ValueHash();

                    if (mounted && (__postStruct != __preStruct || __postS1 != __preS1)) {
                      setState(() {});
                    }
                    print('[WES] BB2 block_data refreshed from SERVER');

                    // ✅ Refresh ISAR with server copy
                    await BlockPlanCache.putDay(
                      uid: uid,
                      blockId: blockId,
                      weekIndex: weekIndex,
                      dayIndex: dayIndex,
                      exercises: srvList,
                    );
                  }
                }
              } catch (_) {
                /* best-effort */
              }
            })();
          }
        } catch (_) {
          /* cache miss is fine */
        }

        // If cache empty, hit server now
        if (!gotFromCache && bb2Exercises.isEmpty) {
          try {
            final blockDataServer = await blockDataRef.get(
                const GetOptions(source: Source.server));
            if (blockDataServer.exists &&
                blockDataServer.data()?['rows'] != null) {
              bb2Exercises =
              List<Map<String, dynamic>>.from(blockDataServer.data()!['rows']);
              print('[WES] BB2 fallback (block_data SERVER) rows: ${bb2Exercises
                  .length}');

              // ✅ Save server copy into ISAR super-cache for next fast paint
              try {
                await BlockPlanCache.putDay(
                  uid: uid,
                  blockId: blockId,
                  weekIndex: weekIndex,
                  dayIndex: dayIndex,
                  exercises: bb2Exercises,
                );
                print('[WES] BB2 block_data SERVER rows written to ISAR cache');
              } catch (e) {
                print('[WES] ISAR write failed (non-fatal): $e');
              }
            }
          } catch (e) {
            print(
                '[WES] BB2 block_data server read failed (non-fatal) for $dateKey → $e');
          }
        }
      }


      // NEW: Capture BB2-planned keys for this date for later dedupe/upsert
      _bb2PlannedKeysForSelectedDate.clear();
      for (final ex in bb2Exercises) {
        final name = (ex['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        final rawId = (ex['exerciseId'] ?? ex['id'])?.toString().trim() ?? '';
        final exId = rawId.isNotEmpty ? rawId : (PeriodizationModelUtils.nameToId[name] ?? name);
        final ci = (ex['circuitIndex'] ?? 0) as int;
        _bb2PlannedKeysForSelectedDate.add('$exId|$ci');
      }
      print(
          '🧭 [WES] bb2PlannedKeysForSelectedDate=${_bb2PlannedKeysForSelectedDate
              .length}');


      if (bb2Exercises.isEmpty) {
        print('[WES] No BB2 exercises to merge for $_selectedDate');
        return;
      }


      // Merge logic — composite key: name + circuitIndex
      String _k(Map<String, dynamic> ex) {
        final n = (ex['name'] ?? '').toString().trim();
        final c = (ex['circuitIndex'] ?? 0) as int;
        return _exerciseKey(n, c);
      }

      String _normName(String s) {
        var t = s.toLowerCase().trim();
        t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
        t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
        t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
        t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');
        t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
        return t;
      }

      // Build exerciseId|ci keys for existing rows
      final Set<String> haveKeys = {};
      final Set<String> haveNamesLower = {};
      for (final e in _selectedExercisesWithCircuits) {
        final n = ((e['name'] ?? '') as String).trim();
        final rawId = (e['exerciseId'] ?? e['id'])?.toString().trim() ?? '';
        final exId = rawId.isNotEmpty ? rawId : (PeriodizationModelUtils.nameToId[n] ?? n);
        final ci = (e['circuitIndex'] ?? 0) as int;
        haveKeys.add('${exId.toString().toLowerCase()}|$ci');
        if (n.isNotEmpty) haveNamesLower.add(n.toLowerCase());
      }

      String keyOfBB2(Map<String, dynamic> ex) {
        final n = ((ex['name'] ?? '') as String).trim();
        final rawId = (ex['exerciseId'] ?? ex['id'])?.toString().trim() ?? '';
        final exId = rawId.isNotEmpty ? rawId : (PeriodizationModelUtils.nameToId[n] ?? n);
        final ci = (ex['circuitIndex'] ?? 0) as int;
        return '${exId.toString().toLowerCase()}|$ci';
      }

      final List<Map<String, dynamic>> newOnes = bb2Exercises
          .where((ex) {
            final n = ((ex['name'] ?? '') as String).trim();
            if (n.isEmpty) return false;
            return !haveKeys.contains(keyOfBB2(ex)) && !haveNamesLower.contains(n.toLowerCase());
          })
          .toList();

      print('[WES] Found ${newOnes.length} new exercises to merge (id+ci)');


      if (newOnes.isNotEmpty || bb2Exercises.isNotEmpty) {
        // Tag every BB2 insert with the currently selected date to avoid bleed
        final String ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);

        // Guard: don't add a BB2 card if a card with same exerciseId|ci already exists
        final Set<String> existingKeys = {};
        final Set<String> existingNamesLowerGuard = {};
        for (final e in _selectedExercisesWithCircuits) {
          final n = ((e['name'] ?? '') as String).trim();
          final rawId = (e['exerciseId'] ?? e['id'])?.toString().trim() ?? '';
          final exId = rawId.isNotEmpty ? rawId : (PeriodizationModelUtils.nameToId[n] ?? n);
          final ci = (e['circuitIndex'] ?? 0) as int;
          existingKeys.add('${exId.toString().toLowerCase()}|$ci');
          if (n.isNotEmpty) existingNamesLowerGuard.add(n.toLowerCase());
        }

        if (_isStale(_mergeEpoch) || _mergeDayKey != _currentDayKey) {
          print('⛔️ [Merge] stale (epoch/dayKey) — aborting apply');
          return;
        }

        setState(() {
          for (final newEx in newOnes) {
            final name = (newEx['name'] ?? '').toString().trim();
            if (name.isEmpty) continue;

            final lower = name.toLowerCase();
            final rawExId = (newEx['exerciseId'] ?? newEx['id'])?.toString().trim() ?? '';
            final exId = rawExId.isNotEmpty ? rawExId : (PeriodizationModelUtils.nameToId[name] ?? name);
            final circuitIndex = (newEx['circuitIndex'] ?? 0) as int;
            final dupeKey = '${exId.toString().toLowerCase()}|$circuitIndex';

            if (existingKeys.contains(dupeKey) || existingNamesLowerGuard.contains(lower)) {
              continue; // avoid duplicates
            }

            final String cardId = (newEx['cardId'] as String?) ??
                'bb2|$ymd|${DateTime.now().microsecondsSinceEpoch}|$exId|$circuitIndex';

            _selectedExercisesWithCircuits.add({
              'name': name,
              'exerciseId': exId,
              'id': exId,
              'circuitIndex': circuitIndex,
              'cardId': cardId,
            });

            final int setCount = _plannedSetCountFor(
              _selectedExercisesWithCircuits.length - 1,
            );

            _workoutSets.add(List.generate(setCount, (_) => SetDetails()));
            _repsControllers.add(List.generate(setCount, (_) => TextEditingController()));
            _weightControllers.add(List.generate(setCount, (_) => TextEditingController()));
            _rirControllers.add(List.generate(setCount, (_) => TextEditingController()));
            _velocityControllers.add(List.generate(setCount, (_) => TextEditingController()));
            _notesControllers.add(List.generate(setCount, (_) => TextEditingController()));

            existingKeys.add(dupeKey);
            existingNamesLowerGuard.add(lower);
          }

          // ✅ Keep circuits in numeric order after merging BB2 rows
          _sortRowsByCircuitIndex();
        });





        // Seed initial values for newly added rows (prefer flat; else sets[0])
        for (final newEx in bb2Exercises) {

          final bbName = (newEx['name'] ?? '').toString().trim();
          final bbRawId = (newEx['exerciseId'] ?? newEx['id'])?.toString().trim() ?? '';
          final bbExId = bbRawId.isNotEmpty ? bbRawId : (PeriodizationModelUtils.nameToId[bbName] ?? bbName);
          final resolvedKey = bbExId.toString().toLowerCase();
          if (resolvedKey.isEmpty || _resolvedBB2Values.containsKey(resolvedKey))
            continue;

          final flatReps = newEx['reps'];
          final flatWeight = newEx['weight'];
          final flatRir = newEx['rir'];
          final flatAdded = (newEx['addedWeight'] as num?)?.toDouble()
              ?? (newEx['weightAdded'] as num?)?.toDouble(); // legacy fallback

          if (flatReps != null || flatWeight != null || flatRir != null) {
            _resolvedBB2Values[resolvedKey] = {
              'reps': flatReps,
              'weight': flatWeight,
              'rir': flatRir,
              'addedWeight': flatAdded,
              // ✅ preserve BB2's addedWeight for hydration
            };
            print(
                '🧠 [WES Merge] Injected FLAT BB2 values for $resolvedKey = ${_resolvedBB2Values[resolvedKey]}');
            debugPrint('🧾[BB2→WES flat] name=$resolvedKey '
                'isBw=${PeriodizationModelUtils.isBodyweightExercise(
                name: (newEx['name'] ?? '').toString())} '
                'reps=$flatReps weight(abs)=$flatWeight addedWeight=$flatAdded rir=$flatRir');

            continue;
          }


          final rawSets = newEx['sets'];
          if (rawSets is List && rawSets.isNotEmpty) {
            final firstSet = Map<String, dynamic>.from(rawSets.first as Map);
            final setAdded = (firstSet['addedWeight'] as num?)?.toDouble()
                ?? (firstSet['weightAdded'] as num?)
                    ?.toDouble(); // legacy fallback
            _resolvedBB2Values[resolvedKey] = {
              'reps': firstSet['reps'],
              'weight': firstSet['weight'],
              'rir': firstSet['rir'],
              'addedWeight': setAdded, // 👈 carry addedWeight
            };
            print(
                '🧠 [WES Merge] Injected SETS[0] BB2 values for $resolvedKey = ${_resolvedBB2Values[resolvedKey]}');
            debugPrint('🧾[BB2→WES sets0] name=$resolvedKey '
                'isBw=${PeriodizationModelUtils.isBodyweightExercise(
                name: (newEx['name'] ?? '').toString())} '
                'reps=${firstSet['reps']} weight(abs)=${firstSet['weight']} '
                'addedWeight=$setAdded rir=${firstSet['rir']}');
          } else {
            // Even if there are no numbers, keep the exercise row so the user can edit it.
            _resolvedBB2Values[resolvedKey] = {
              'reps': null,
              'weight': null,
              'rir': null,
            };
            print(
                'ℹ️ [WES Merge] No values found for $resolvedKey — seeding empty controllers');
          }

// ⬇️ INSERT HYDRATION BLOCK HERE
          if (_resolvedBB2Values.containsKey(resolvedKey)) {
            final values = _resolvedBB2Values[resolvedKey]!;
            debugPrint('➡️[WES Hydrate BEGIN] resolvedKey=$resolvedKey values=$values');

            final idx = _selectedExercisesWithCircuits.indexWhere((e) {
              final rId = (e['exerciseId'] ?? e['id'])?.toString().trim() ?? '';
              final n = ((e['name'] ?? '') as String).trim();
              final eKey = (rId.isNotEmpty ? rId : (PeriodizationModelUtils.nameToId[n] ?? n)).toString().toLowerCase();
              return eKey == resolvedKey;
            });

            if (idx != -1) {
              final sets = _workoutSets[idx];
              if (sets.isNotEmpty) {
                final exName = (_selectedExercisesWithCircuits[idx]['name'] as String)
                    .trim();
                final exId = PeriodizationModelUtils.nameToId[exName] ?? exName;
                final isBwEx = PeriodizationModelUtils.isBodyweightExercise(
                    id: exId, name: exName);
                final uid = _cachedUid ??
                    FirebaseAuth.instance.currentUser?.uid ?? '';
                final DateTime? asOf = _selectedDate;

                final abs = (values['weight'] as num?)?.toDouble();
                final added = (values['addedWeight'] as num?)?.toDouble()
                    ?? (values['weightAdded'] as num?)?.toDouble();

                final display = isBwEx
                    ? (added ??
                    (abs != null
                        ? PeriodizationModelUtils.toDisplayAddedWeight(
                      uid: uid,
                      absoluteKg: abs,
                      exerciseId: exId,
                      exerciseName: exName,
                      asOfDate: asOf,
                    )
                        : null))
                    : abs;

                if (_isStale(_mergeEpoch) || _mergeDayKey != _currentDayKey) {
                  print('⛔️ [Merge] stale (epoch/dayKey) — aborting apply');
                  return;
                }

                sets[0].reps = (values['reps'] as num?)?.toInt();
                sets[0].weight = display;
                sets[0].rir = (values['rir'] as num?)?.toDouble();
              }

              debugPrint(
                  '🧮[WES Hydrate Check] ex=${_selectedExercisesWithCircuits[idx]['name']} '
                      'repsField="${_repsControllers[idx][0].text}" '
                      'weightField="${_weightControllers[idx][0].text}"');

              if (_isStale(_mergeEpoch) || _mergeDayKey != _currentDayKey) {
                print('⛔️ [Merge] stale (epoch/dayKey) — aborting apply');
                return;
              }

              if (_repsControllers.length > idx &&
                  _repsControllers[idx].isNotEmpty) {
                final exName = (_selectedExercisesWithCircuits[idx]['name'] as String)
                    .trim();
                final exId = PeriodizationModelUtils.nameToId[exName] ?? exName;
                final isBwEx = PeriodizationModelUtils.isBodyweightExercise(
                    id: exId, name: exName);
                final uid = _cachedUid ??
                    FirebaseAuth.instance.currentUser?.uid ?? '';
                final DateTime? asOf = _selectedDate;

                final abs = (values['weight'] as num?)?.toDouble();
                final added = (values['addedWeight'] as num?)?.toDouble()
                    ?? (values['weightAdded'] as num?)?.toDouble();

                final display = isBwEx
                    ? (added ??
                    (abs != null
                        ? PeriodizationModelUtils.toDisplayAddedWeight(
                      uid: uid,
                      absoluteKg: abs,
                      exerciseId: exId,
                      exerciseName: exName,
                      asOfDate: asOf,
                    )
                        : null))
                    : abs;

                // 🚫 Don’t overwrite if the user has already typed
                if (_repsControllers[idx][0].text.trim().isEmpty) {
                  _repsControllers[idx][0].text = values['reps']?.toString() ?? '';
                }
                if (_weightControllers[idx][0].text.trim().isEmpty) {
                  _weightControllers[idx][0].text = display?.toString() ?? '';
                  print(
                      '🪙 [WES HydrateWeight] ex=$exName isBW=$isBwEx abs=$abs added=$added display=$display '
                          '→ wrote text="${_weightControllers[idx][0].text}"');
                }
                if (_rirControllers[idx][0].text.trim().isEmpty) {
                  _rirControllers[idx][0].text = values['rir']?.toString() ?? '';
                }
              }

            }
          }
        }

        print('[WES] Merged ${newOnes.length} exercise(s) into draft');

        print('[WES] Merged ${newOnes.length} exercise(s) into draft');

        // 🔧 FINAL PASS: normalize all rows to their planned set-counts
        if (mounted) {
          setState(() {
            for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
              final name = (_selectedExercisesWithCircuits[i]['name'] as String? ?? '').trim();
              if (name.isEmpty) continue;

              final int desiredSetCount = _plannedSetCountFor(i);
              if (desiredSetCount <= 0) continue;

              if (i >= _workoutSets.length ||
                  i >= _repsControllers.length ||
                  i >= _weightControllers.length ||
                  i >= _rirControllers.length ||
                  i >= _velocityControllers.length ||
                  i >= _notesControllers.length) {
                continue;
              }

              _resizeRow<SetDetails>(
                _workoutSets,
                i,
                desiredSetCount,
                    () => SetDetails(),
              );
              _resizeRow<TextEditingController>(
                _repsControllers,
                i,
                desiredSetCount,
                    () => TextEditingController(),
              );
              _resizeRow<TextEditingController>(
                _weightControllers,
                i,
                desiredSetCount,
                    () => TextEditingController(),
              );
              _resizeRow<TextEditingController>(
                _rirControllers,
                i,
                desiredSetCount,
                    () => TextEditingController(),
              );
              _resizeRow<TextEditingController>(
                _velocityControllers,
                i,
                desiredSetCount,
                    () => TextEditingController(),
              );
              _resizeRow<TextEditingController>(
                _notesControllers,
                i,
                desiredSetCount,
                    () => TextEditingController(),
              );
            }
          });
        }

        _hasCompletedInitialMergeForThisDate = true; // ✅ gate further same-session calls


        _hasCompletedInitialMergeForThisDate = true; // ✅ gate further same-session calls
        // ANCHOR: [WES Merge] Finalize deferred reset repaint if nothing added
        if (__didResetStruct == true && mounted && newOnes.isEmpty) {
          final __postStructMergeReset = _structureHash();
          if (__preStructMergeReset != null && __postStructMergeReset != __preStructMergeReset) {
            setState(() {}); // one minimal repaint
          }
        }

        await _saveWorkoutDraftToCache();
        _debugLogCardsForSelectedDate('BB2 Merge');

      }
    } finally {
      if (!_openingMergePhase) {
        // Only unlock if select-date (or open) latch isn’t active
        _isMergingBB2.value = _openingMergePhase;

      }

      _debugRowSetCounts('[MergeBB2 end]');
      _tMergeBB2.stop();
      print('⏱️ [WES] _mergeNewBB2ExercisesIntoDraft took ${_tMergeBB2.elapsedMilliseconds}ms');

    }

  }

  void _scheduleMissedButtonAfterPaint() {
    if (_selectedDate == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.microtask(() async {
        if (!mounted) return;

        final items = await _computeMissedExercisesForWeek();
        if (!mounted) return;

        setState(() {
          _missedItemsForToday = items;
          _hasMissedForToday = items.isNotEmpty;
        });

        // One-time shine each page open if we have missed items
        if (_hasMissedForToday && !_didShineThisOpen && _catchupShineCtl != null) {
          _didShineThisOpen = true;
          _catchupShineCtl!
            ..reset()
            ..forward();
        }

      });
    });
  }


  void addSet(int exerciseIndex) {

    setState(() {
      // 0) Make sure the outer row exists for every parallel structure
      while (_workoutSets.length <= exerciseIndex) _workoutSets.add(
          <SetDetails>[]);
      while (_repsControllers.length <= exerciseIndex) _repsControllers.add(
          <TextEditingController>[]);
      while (_weightControllers.length <= exerciseIndex) _weightControllers.add(
          <TextEditingController>[]);
      while (_rirControllers.length <= exerciseIndex) _rirControllers.add(
          <TextEditingController>[]);
      while (_velocityControllers.length <= exerciseIndex) _velocityControllers
          .add(<TextEditingController>[]);
      while (_notesControllers.length <= exerciseIndex) _notesControllers.add(
          <TextEditingController>[]);

      // 1) Append a new set to every parallel structure
      _workoutSets[exerciseIndex].add(SetDetails(
        reps: null,
        weight: null,
        rir: null,
        // add velocity/notes fields here if SetDetails has them; otherwise leave as controllers only
      ));
      _repsControllers[exerciseIndex].add(TextEditingController());
      _weightControllers[exerciseIndex].add(TextEditingController());
      _rirControllers[exerciseIndex].add(TextEditingController());
      _velocityControllers[exerciseIndex].add(TextEditingController());
      _notesControllers[exerciseIndex].add(TextEditingController());
    });
    if (!_applyingUndo) {
      final cKey = _rowKeyBy(exerciseIndex);
      _undoStack.add(() {
        if (!mounted) return;
        int resolvedIdx = -1;
        for (int k = 0; k < _selectedExercisesWithCircuits.length; k++) {
          if (_rowKeyBy(k) == cKey) { resolvedIdx = k; break; }
        }
        if (resolvedIdx == -1 || _workoutSets[resolvedIdx].isEmpty) return;
        final lastIdx = _workoutSets[resolvedIdx].length - 1;
        _repsControllers[resolvedIdx][lastIdx].dispose();
        _weightControllers[resolvedIdx][lastIdx].dispose();
        _rirControllers[resolvedIdx][lastIdx].dispose();
        _velocityControllers[resolvedIdx][lastIdx].dispose();
        _notesControllers[resolvedIdx][lastIdx].dispose();
        setState(() {
          _workoutSets[resolvedIdx].removeLast();
          _repsControllers[resolvedIdx].removeLast();
          _weightControllers[resolvedIdx].removeLast();
          _rirControllers[resolvedIdx].removeLast();
          _velocityControllers[resolvedIdx].removeLast();
          _notesControllers[resolvedIdx].removeLast();
        });
        _markDirty();
      });
    }
  }


  void removeSet(int exerciseIndex, int setIndex) {
    setState(() {
      // Check if only one set remains and confirm removal
      if (_workoutSets[exerciseIndex].length == 1) {
        // Capture before dialog opens — outer setState runs synchronously
        final cOrigIdx   = exerciseIndex;
        final cExercise  = Map<String, dynamic>.from(_selectedExercisesWithCircuits[exerciseIndex]);
        final cSets      = _workoutSets[exerciseIndex]
            .map((s) => SetDetails(reps: s.reps, weight: s.weight, rir: s.rir,
                                   velocity: s.velocity, notes: s.notes))
            .toList();
        final cRepsT     = _repsControllers[exerciseIndex].map((c) => c.text).toList();
        final cWeightT   = _weightControllers[exerciseIndex].map((c) => c.text).toList();
        final cRirT      = _rirControllers[exerciseIndex].map((c) => c.text).toList();
        final cVelocityT = _velocityControllers[exerciseIndex].map((c) => c.text).toList();
        final cNotesT    = _notesControllers[exerciseIndex].map((c) => c.text).toList();

        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Confirm Removal'),
              content:
              const Text('Are you sure you want to remove this exercise?'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    // Dispose all controllers for this exercise
                    for (final c in _repsControllers[cOrigIdx]) c.dispose();
                    for (final c in _weightControllers[cOrigIdx]) c.dispose();
                    for (final c in _rirControllers[cOrigIdx]) c.dispose();
                    for (final c in _velocityControllers[cOrigIdx]) c.dispose();
                    for (final c in _notesControllers[cOrigIdx]) c.dispose();
                    setState(() {
                      _selectedExercisesWithCircuits.removeAt(cOrigIdx);
                      _workoutSets.removeAt(cOrigIdx);
                      _repsControllers.removeAt(cOrigIdx);
                      _weightControllers.removeAt(cOrigIdx);
                      _rirControllers.removeAt(cOrigIdx);
                      _velocityControllers.removeAt(cOrigIdx);
                      _notesControllers.removeAt(cOrigIdx);
                    });
                    if (!_applyingUndo) {
                      _undoStack.add(() {
                        if (!mounted) return;
                        final insertAt = cOrigIdx.clamp(0, _selectedExercisesWithCircuits.length);
                        setState(() {
                          _selectedExercisesWithCircuits.insert(insertAt, cExercise);
                          _workoutSets.insert(insertAt, cSets);
                          _repsControllers.insert(insertAt,
                              cRepsT.map((t) => TextEditingController(text: t)).toList());
                          _weightControllers.insert(insertAt,
                              cWeightT.map((t) => TextEditingController(text: t)).toList());
                          _rirControllers.insert(insertAt,
                              cRirT.map((t) => TextEditingController(text: t)).toList());
                          _velocityControllers.insert(insertAt,
                              cVelocityT.map((t) => TextEditingController(text: t)).toList());
                          _notesControllers.insert(insertAt,
                              cNotesT.map((t) => TextEditingController(text: t)).toList());
                        });
                        _attachDirtyListeners();
                        _markDirty();
                      });
                    }
                    Navigator.of(context).pop();
                  },
                  child: const Text('Yes'),
                ),
              ],
            );
          },
        );
      } else {
        // Capture snapshot before removal
        final cKey      = _rowKeyBy(exerciseIndex);
        final cSet      = setIndex;
        final cDetails  = SetDetails(
          reps: _workoutSets[exerciseIndex][setIndex].reps,
          weight: _workoutSets[exerciseIndex][setIndex].weight,
          rir: _workoutSets[exerciseIndex][setIndex].rir,
          velocity: _workoutSets[exerciseIndex][setIndex].velocity,
          notes: _workoutSets[exerciseIndex][setIndex].notes,
        );
        final cReps     = _repsControllers[exerciseIndex][setIndex].text;
        final cWeight   = _weightControllers[exerciseIndex][setIndex].text;
        final cRir      = _rirControllers[exerciseIndex][setIndex].text;
        final cVelocity = _velocityControllers[exerciseIndex][setIndex].text;
        final cNotes    = _notesControllers[exerciseIndex][setIndex].text;

        // Dispose removed controllers
        _repsControllers[exerciseIndex][setIndex].dispose();
        _weightControllers[exerciseIndex][setIndex].dispose();
        _rirControllers[exerciseIndex][setIndex].dispose();
        _velocityControllers[exerciseIndex][setIndex].dispose();
        _notesControllers[exerciseIndex][setIndex].dispose();

        // Remove from all 6 parallel arrays (fix: adds velocity + notes)
        _workoutSets[exerciseIndex].removeAt(setIndex);
        _repsControllers[exerciseIndex].removeAt(setIndex);
        _weightControllers[exerciseIndex].removeAt(setIndex);
        _rirControllers[exerciseIndex].removeAt(setIndex);
        _velocityControllers[exerciseIndex].removeAt(setIndex);
        _notesControllers[exerciseIndex].removeAt(setIndex);

        // Push undo
        if (!_applyingUndo) {
          _undoStack.add(() {
            if (!mounted) return;
            int resolvedIdx = -1;
            for (int k = 0; k < _selectedExercisesWithCircuits.length; k++) {
              if (_rowKeyBy(k) == cKey) { resolvedIdx = k; break; }
            }
            if (resolvedIdx == -1) return;
            setState(() {
              _workoutSets[resolvedIdx].insert(cSet, cDetails);
              _repsControllers[resolvedIdx].insert(cSet, TextEditingController(text: cReps));
              _weightControllers[resolvedIdx].insert(cSet, TextEditingController(text: cWeight));
              _rirControllers[resolvedIdx].insert(cSet, TextEditingController(text: cRir));
              _velocityControllers[resolvedIdx].insert(cSet, TextEditingController(text: cVelocity));
              _notesControllers[resolvedIdx].insert(cSet, TextEditingController(text: cNotes));
            });
            _attachDirtyListeners();
            _markDirty();
          });
        }

        // Re-initialize controllers for consistent UI behavior
        _initializeControllers();
      }
    });
  }

  Future<void> _selectDate(BuildContext context, {DateTime? pickedOverride}) async {

    final sw = Stopwatch()..start();
    print('⏱️ [WES] _selectDate started');
    // 🔒 Latch merge lock for the entire select-date pipeline
    _openingMergePhase = true;
    _isMergingBB2.value = true;

    final picked = pickedOverride ?? await showDatePicker(
    context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
    );
    if (picked == null || picked == _selectedDate) {
      print('⛔️ [WES] Date selection cancelled or unchanged');
      // 🔓 User cancelled / unchanged → release latch
      _openingMergePhase = false;
      _isMergingBB2.value = false;

      return;
    }
    final ymdPicked = DateFormat('yyyy-MM-dd').format(picked);
    print('📆 [WES] Date changed → $ymdPicked');
    // 🔒 Begin a fresh session for this picked date (makes prior async results stale)
    _beginDateSession(picked);
    final int _selectEpoch = _epoch;
    final String _selectDayKey = _currentDayKey;



    String _normNameForProv(String s) {
      var t = s.toLowerCase().trim();
      t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
      t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
      t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
      t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');
      t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
      return t;
    }

    List<Map<String, dynamic>> _snapshotRows() =>
        _selectedExercisesWithCircuits
            .map((e) {
          final name = ((e['name'] ?? '') as String).trim();
          final ci = (e['circuitIndex'] is num)
              ? (e['circuitIndex'] as num).toInt()
              : 0;
          // Canonical identity: exerciseId/id first, then cardId parse, then name lookup
          var exId = (e['exerciseId'] ?? e['id'])?.toString().trim() ?? '';
          if (exId.isEmpty) {
            final cardId = (e['cardId'] ?? '').toString();
            final parts = cardId.split('|');
            if (parts.length >= 5) {
              final parsed = parts[3].trim().toLowerCase();
              if (parsed.isNotEmpty) exId = parsed;
            }
          }
          if (exId.isEmpty) {
            exId = (PeriodizationModelUtils.nameToId[name] ?? name).trim().toLowerCase();
          }
          return {
            'name': name,
            'ci': ci,
            'exId': exId.toLowerCase(),
            'cardId': (e['cardId'] ?? '').toString(),
          };
        })
            .toList();

    List<Map<String, dynamic>> _diffAdded(
        List<Map<String, dynamic>> before,
        List<Map<String, dynamic>> after,
        ) {
      final beforeKeys = {
        for (final e in before)
          '${(e['exId'] ?? _normNameForProv(e['name'] ?? '')).toString().toLowerCase()}|${e['ci']}'
      };
      final added = <Map<String, dynamic>>[];
      for (final e in after) {
        final k = '${(e['exId'] ?? _normNameForProv(e['name'] ?? '')).toString().toLowerCase()}|${e['ci']}';
        if (!beforeKeys.contains(k)) added.add(e);
      }
      return added;
    }

    // nameKey → list of sources (order preserved)
    final Map<String, List<String>> _provenance = {};
    void _record(String source, List<Map<String, dynamic>> added) {
      for (final e in added) {
        final k = '${(e['exId'] ?? _normNameForProv((e['name'] ?? '') as String)).toString().toLowerCase()}|${e['ci']}';
        (_provenance[k] ??= <String>[]).add(source);
      }
    }

    // Clear per-date caches (keep it light)
    _cachedProgressedValues.clear();
    _resolvedBB2Values.clear();
    _savedExerciseKeysForDate.clear();

    _seedHintsByKey.clear();                // prevent stale fast-paint hints influencing merge
    _bb2PlannedKeysForSelectedDate.clear(); // ensure merge recomputes keys for this date
    _lastMergedDate = null;                 // force merge to treat this as a new date
    _hasCompletedInitialMergeForThisDate = false;



    // Allow FastPaint to run for the new date
    _bootPaintDone = false;
    _didFastPaint = false;

    // Pre-warm ISAR + caches for the picked date (best-effort)
    try {
      final uid = _cachedUid;
      final bid = _selectedBlockId ?? _activeBlockId;
      print('🧩 [SelectDate→Warmup] about to warm '
          '${DateFormat('yyyy-MM-dd').format(picked)} '
          '(uid=$uid bid=$bid)');

      if (uid != null && bid != null) {
        WarmupService.instance
            .warmWES(uid, activeBlockId: bid, selectedDate: picked);
      }
    } catch (e) {
      print('⚠️ [SelectDate→Warmup] error: $e');
    } finally {
      print('🧩 [SelectDate→Warmup] issued for '
          '${DateFormat('yyyy-MM-dd').format(picked)}');
    }


    // Switch date & clear UI structure in one setState
    print('🧼 [WES] Reset UI for new date…');
    setState(() {
      _selectedDate = picked;
      _workoutNameController.text = _formatWorkoutDate(_selectedDate);

      _selectedExercisesWithCircuits.clear();
      _workoutSets.clear();
      _repsControllers.clear();
      _weightControllers.clear();
      _rirControllers.clear();
      _velocityControllers.clear();
      _notesControllers.clear();

      _pendingChanges = false;
      _lastSavedHash = null;
    });

    // 1) Fast paint from snapshot if present (instant rows + hints)
    final _snapBeforePaint = _snapshotRows();
    try {
      await _paintFromSnapshotIfAny();
// ⛑️ Guard
      if (!await _applyGuard('SelectDate→AfterFastPaint', _selectEpoch, _selectDayKey)) return;


    } catch (_) {}
    _record('FastPaint/ISAR',
        _diffAdded(_snapBeforePaint, _snapshotRows()));

    // PreMergeCheck
    try {
      final DateTime pickedOnly = DateTime(picked.year, picked.month, picked.day);
      final DateTime? blockStartOnly = (blockStartDate == null)
          ? null
          : DateTime(blockStartDate!.year, blockStartDate!.month, blockStartDate!.day);

      if (blockStartOnly != null) {
        final int delta = pickedOnly.difference(blockStartOnly).inDays;
        final int wk = delta ~/ 7;
        final int diRaw = delta % 7;
        final int di = diRaw < 0 ? diRaw + 7 : diRaw;

        print('🧮 [SelectDate PreMerge] picked=${DateFormat('yyyy-MM-dd').format(pickedOnly)} '
            'blockStart=${DateFormat('yyyy-MM-dd').format(blockStartOnly)} '
            '→ week_$wk/day_$di');

        final uid = _cachedUid ?? UserContext.of(context, listen: false).currentUid;
        final bid = _selectedBlockId ?? _activeBlockId;

        if (uid != null && bid != null) {
          final dayDoc = await FirebaseFirestore.instance
              .collection('planned_blocks').doc(uid)
              .collection('blocks').doc(bid)
              .collection('weeks').doc('week_$wk')
              .collection('days').doc('day_$di')
              .get(const GetOptions(source: Source.server));

          String _d(dynamic v) {
            if (v == null) return '∅';
            if (v is Timestamp) { final d = v.toDate(); return '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}'; }
            if (v is DateTime)   { final d = DateTime(v.year, v.month, v.day); return DateFormat('yyyy-MM-dd').format(d); }
            if (v is String)     { return v.length >= 10 ? v.substring(0,10) : v; }
            return v.toString();
          }

          final fsDate = _d(dayDoc.data()?['date']);
          final pick   = DateFormat('yyyy-MM-dd').format(pickedOnly);
          print('🔎 [SelectDate PreMerge] FS week_$wk/day_$di has date=$fsDate vs picked=$pick');
        }
      }
    } catch (e) {
      print('⚠️ [SelectDate PreMerge] probe failed: $e');
    }

    // 2) Merge BB2 planned for this exact calendar date (guard block meta)
    final _snapBeforeBB2 = _snapshotRows();
    bool _allowMerge = true; // will flip to false if FS day≠picked

    try {
      final DateTime pickedOnly = DateTime(picked.year, picked.month, picked.day);
      final DateTime? blockStartOnly = (blockStartDate == null)
          ? null
          : DateTime(blockStartDate!.year, blockStartDate!.month, blockStartDate!.day);

      if (blockStartOnly != null) {
        final int delta = pickedOnly.difference(blockStartOnly).inDays;
        final int wk = delta ~/ 7;
        final int diRaw = delta % 7;
        final int di = diRaw < 0 ? diRaw + 7 : diRaw;

        final uid = _cachedUid ?? UserContext.of(context, listen: false).currentUid;
        final bid = _selectedBlockId ?? _activeBlockId;

        if (uid != null && bid != null) {
          final dayDoc = await FirebaseFirestore.instance
              .collection('planned_blocks').doc(uid)
              .collection('blocks').doc(bid)
              .collection('weeks').doc('week_$wk')
              .collection('days').doc('day_$di')
              .get(const GetOptions(source: Source.server));

          String _d(dynamic v) {
            if (v == null) return '∅';
            if (v is Timestamp) { final d = v.toDate(); return '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}'; }
            if (v is DateTime)  { final d = DateTime(v.year, v.month, v.day); return DateFormat('yyyy-MM-dd').format(d); }
            if (v is String)    { return v.length >= 10 ? v.substring(0,10) : v; }
            return v.toString();
          }
          final fsDate = _d(dayDoc.data()?['date']);
          final pick   = DateFormat('yyyy-MM-dd').format(pickedOnly);
          _allowMerge = (fsDate == pick);
          print('✅ [SelectDate MergeGate] allowMerge=$_allowMerge (doc=$fsDate pick=$pick week_$wk/day_$di)');
        }
      }
    } catch (e) {
      print('⚠️ [SelectDate MergeGate] failed: $e (default allowMerge=true)');
    }

    // 🕒 Defer heavy work (merge + self-heal) after fast paint — except on very first open
    if (_hasOpenedOnce) {
     // _scheduleHeavyWork();  // delayed, cancellable heavy operations
    } else {
      // 🚀 First open: run merge immediately, mark as opened
      if (blockStartDate == null) {
        print('🚧 [WES] No block meta yet → skipping BB2 merge for $ymdPicked');
      } else if (_allowMerge) {
        try { await _mergeNewBB2ExercisesIntoDraft(); } catch (e) { print('⚠️ [WES Merge] threw: $e'); }
      } else {
        print('🛑 [WES] Skipping BB2 merge: FS day date doesn’t match picked calendar date.');
      }

      _hasOpenedOnce = true;
    }

    _record('BB2 planned', _diffAdded(_snapBeforeBB2, _snapshotRows()));

    // 3) Overlay any saved WES workout (completed + wesPlanned placeholders)
    final _snapBeforeWES = _snapshotRows();
    try {
      await _loadExistingWorkoutIfAny();
    } catch (_) {}
    _record(
        'WES (completed/plan)', _diffAdded(_snapBeforeWES, _snapshotRows()));

    // 4) Non-destructive local draft overlay (fill only empty fields)
    final _snapBeforeDraft = _snapshotRows();
    try {
      print('📂 [WES] Attempting local draft overlay…');
      await _loadDraftLocallyIfAvailable();
    } catch (_) {}
    // ⛑️ Guard
    if (!await _applyGuard('SelectDate→AfterOverlays', _selectEpoch, _selectDayKey)) return;
    _record('Local Draft', _diffAdded(_snapBeforeDraft, _snapshotRows()));

    // Provenance summary print (once, after all sources applied)
    try {
      final byName = <String, Map<String, dynamic>>{};
      for (final r in _selectedExercisesWithCircuits) {
        final name = ((r['name'] ?? '') as String).trim();
        final ci = (r['circuitIndex'] is num)
            ? (r['circuitIndex'] as num).toInt()
            : 0;
        var exId = (r['exerciseId'] ?? r['id'])?.toString().trim() ?? '';
        if (exId.isEmpty) exId = (PeriodizationModelUtils.nameToId[name] ?? name).trim().toLowerCase();
        final key = '${exId.toLowerCase()}|$ci';
        byName[key] = {'name': name, 'ci': ci};
      }

      print('🧭 [WES SelectDate Provenance] $ymdPicked → ${byName.length} exercise(s)');
      int i = 0;
      byName.forEach((k, v) {
        final sources = _provenance[k]?.join(' → ') ?? 'unknown';
        print('   • #${i++} "${v['name']}" (ci=${v['ci']})  from: $sources');
      });
    } catch (_) {/* best-effort */ }

    // Final wiring & debug
    _attachDirtyListeners();
    try {
      _debugLogCardsForSelectedDate('SelectDate');
    } catch (_) {}

    // 🔓 Entire date-switch pipeline is done → release latch
    _openingMergePhase = false;
    _isMergingBB2.value = false;

    sw.stop();
    print('⏱️ [WES] _selectDate total = ${sw.elapsedMilliseconds}ms');
    await debugPrintWesDayCache(
      UserContext.of(context, listen: false).currentUid,
      _selectedDate,
    );
    await debugPrintWesInitSnapshot(
      uid: _cachedUid ?? UserContext.of(context, listen:false).currentUid!,
      blockId: _selectedBlockId ?? _activeBlockId!,
      date: _selectedDate,
    );
    _openingMergePhase = false;

  }

  void _enqueueDateChange(DateTime picked) {
    // 70–80ms is a sweet spot; choose 75ms for a little more batching headroom.
    _pendingPickedForCoalesce = picked;
    _dateCoalesceTimer?.cancel();
    _dateCoalesceTimer = Timer(const Duration(milliseconds: 01), () {
      if (!mounted) return;
      final d = _pendingPickedForCoalesce;
      _pendingPickedForCoalesce = null;
      if (d != null) {
        _selectDate(context, pickedOverride: d);
      }
    });
  }

  Future<bool> _applyGuard(String tag, int startedEpoch, String startedDayKey) async {
    if (!mounted) {
      print('⛔️ [$tag] not mounted; abort');
      return false;
    }
    if (startedEpoch != _epoch || startedDayKey != _currentDayKey) {
      print('⛔️ [$tag] stale (epoch/day changed); abort');
      return false;
    }
    return true;
  }

  void _bumpDate(int deltaDays) {
    final next = _selectedDate.add(Duration(days: deltaDays));
    _selectDate(context, pickedOverride: next); // ← uses the same pipeline
  }

  String _formatWorkoutDate(DateTime date) {
    final dayOfWeek = DateFormat('EEEE').format(date); // e.g., Tuesday
    final day = date.day; // 29
    final month = DateFormat('MMMM').format(date); // April
    final year = date.year; // 2025

    return '$dayOfWeek $day $month $year';
  }

  void _navigateToExerciseDetails(String exerciseName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // ✅ Best-effort: try to find an exerciseId from recent history,
    // but do NOT block navigation if none found.
    String exerciseId = exerciseName; // fallback

    try {
      final recentWorkouts =
      await getRecentWorkoutsForExercise(exerciseName, _selectedDate);

      if (recentWorkouts.isNotEmpty) {
        final firstWithExercise = recentWorkouts.firstWhere(
              (w) => w.exercises.any((ex) => ex.name == exerciseName),
        );
        final exercise = firstWithExercise.exercises
            .firstWhere((ex) => ex.name == exerciseName);

        exerciseId = exercise.id ?? exerciseName;
      }
    } catch (e) {
      // If fetch fails or no match, just fall back to name.
      print('⚠️ [WES] ExerciseDetails couldn’t resolve id for "$exerciseName": $e');
    }

    print('➡️ [WES] Push ExerciseDetailsScreen id="$exerciseId" name="$exerciseName"');

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExerciseDetailsScreen(
          exerciseId: exerciseId,
          exerciseName: exerciseName, // optional, but good for title
        ),
      ),
    );
  }



  void _navigateToTopSets(String exerciseName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TopSetsScreen(
          exerciseName: exerciseName,
          recentWorkouts: const [], // no longer used
        ),
      ),
    );
  }


  Future<List<Workout>> getRecentWorkoutsForExercise(String exerciseName,
      DateTime currentWorkoutDate) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return [];
    }

    try {
      // ✅ Fetch last 12 workouts from Firestore
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('workouts')
          .orderBy('date', descending: true)
          .limit(12)
          .get();

      List<Workout> filteredWorkouts = snapshot.docs
          .map((doc) {
        final data = doc.data();

        // ✅ Handle both Firestore Timestamp and String date formats safely
        DateTime workoutDate;
        if (data['date'] is Timestamp) {
          workoutDate = (data['date'] as Timestamp).toDate();
        } else if (data['date'] is String) {
          workoutDate = DateTime.tryParse(data['date']) ?? DateTime.now();
        } else {
          throw Exception('Invalid date format in Firestore');
        }

        // ✅ Convert exercises safely
        List<Exercise> exercises = [];
        if (data['exercises'] is List) {
          exercises = (data['exercises'] as List)
              .map((exercise) =>
              Exercise.fromFirestore(exercise as Map<String, dynamic>))
              .toList();
        }

        return Workout(
          name: data['name'] ?? 'Unnamed Workout',
          date: workoutDate,
          exercises: exercises,
        );
      })
          .where((workout) =>
      workout.date.isBefore(currentWorkoutDate) &&
          workout.exercises
              .any((exercise) => exercise.name == exerciseName))
          .toList();

      return filteredWorkouts;
    } catch (error) {
      print('Error fetching workouts: $error');
      return [];
    }
  }

  Widget _buildCatchUpButton() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final childText = Text(
      'Catch up exercises?',
      style: theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w700,
        // Match your Circuit 1 label height by keeping text small:
        fontSize: 12,
        color: cs.primary,
        letterSpacing: 0.1,
      ),
    );

    if (_catchupShineAnim == null) {
      // Before shine is initialized, render nothing (or a placeholder)
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: _catchupShineAnim!,
      builder: (context, _) {
        // t goes 0 → 1 once per open
        final t = _catchupShineAnim!.value;


        return TextButton(
          onPressed: _hasMissedForToday
              ? () =>
              _maybePromptForMissedExercises(precomputed: _missedItemsForToday)
              : null,
          style: TextButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            minimumSize: const Size(0, 0),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            visualDensity: VisualDensity.compact,
          ),
          child: ShaderMask(
            shaderCallback: (rect) {
              // Width fraction of the bright band
              const band = 0.25; // 25% of the width
              double a = (t - band / 2).clamp(0.0, 1.0);
              double b = t.clamp(0.0, 1.0);
              double c = (t + band / 2).clamp(0.0, 1.0);

              // ensure increasing order
              const eps = 0.001;
              if (b <= a) b = (a + eps).clamp(0.0, 1.0);
              if (c <= b) c = (b + eps).clamp(0.0, 1.0);

              return LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: const [Colors.white24, Colors.white, Colors.white24],
                stops: [a, b, c], // 👈 just put the stops here
              ).createShader(rect);
            },
            blendMode: BlendMode.srcATop,
            child: childText,
          ),

        );
      },
    );
  }

  //settings cog

  Map<String, dynamic> _updateFullWeek1RirPlan(
      dynamic rirPlan,
      Map<String, TextEditingController> ctrls,
      ) {
    final plan = Map<String, dynamic>.from(rirPlan ?? {});
    plan['week1'] ??= {};

    // iterate sessions set1, set2, set3, ...
    for (int session = 1; session <= 6; session++) {
      final sKey = 'session$session';
      final sessionMap = Map<String, dynamic>.from(plan['week1'][sKey] ?? {});

      for (int set = 1; set <= 8; set++) {
        final cKey = 'w1_s${session}_set$set';
        final ctrl = ctrls[cKey];
        if (ctrl == null) continue;

        final val = ctrl.text.trim();
        if (val.isEmpty) continue;

        sessionMap['set$set'] ??= {};
        sessionMap['set$set']['rir'] = val;
      }

      if (sessionMap.isNotEmpty) {
        plan['week1'][sKey] = sessionMap;
      }
    }

    return plan;
  }


  // 🔧 Opens a small alert dialog to edit increments, repTargets and a simple RIR target
  Future<void> _showExerciseSettingsDialog(String exerciseId, String exerciseName) async {
    // You should already have this map in WES from BB2 load:
    // Map<String, dynamic> plannedExerciseDetails = {};
    // Pull existing settings for this exercise from WES local cache
    final existing = Map<String, dynamic>.from(
      (_exerciseSettings[exerciseId] ?? {}) as Map<String, dynamic>,
    );


    final Map<String, dynamic> existingIncrements =
    Map<String, dynamic>.from(existing['increments'] ?? {});
    final dynamic existingRepTargets = existing['repTargets'];
    final dynamic existingRirPlan = existing['rirPlan'];

    // 🔎 Which week are we currently in for this exercise?
    // _getApplicableWeekIndex(exerciseId) is the same helper used in getRirFromPlanOrInput.
    final int? _currentWeekIndex = _getApplicableWeekIndex(exerciseId);
    final String _currentWeekKey =
    _currentWeekIndex != null ? 'week${_currentWeekIndex + 1}' : 'week1';


    // ---- format current values for the text fields ----
    String _formatIncrementsForField(Map<String, dynamic> inc) {
      if (inc.isEmpty) return '';
      final parts = <String>[];
      if (inc['primary'] != null) {
        parts.add((inc['primary'] as num).toString());
      }
      if (inc['secondary'] != null) {
        parts.add((inc['secondary'] as num).toString());
      }
      if (inc['tertiary'] != null) {
        parts.add((inc['tertiary'] as num).toString());
      }
      return parts.join(', ');
    }

    String _formatRepTargetsForField(dynamic repTargets) {
      // We only care about week1 here (DUP / most current week use case)
      if (repTargets is Map && repTargets['week1'] is Map) {
        final week1 = Map<String, dynamic>.from(repTargets['week1'] as Map);
        final keys = week1.keys.toList()
          ..sort(); // instance1, instance2, ...
        final vals = <String>[];
        for (final k in keys) {
          final v = week1[k];
          if (v != null && v.toString().trim().isNotEmpty) {
            vals.add(v.toString());
          }
        }
        return vals.join(', ');
      }
      return '';
    }

    String _formatRirForField(dynamic rirPlan) {
      // Very small, conservative: just show week1.session1.set1.rir if present
      try {
        if (rirPlan is Map &&
            rirPlan['week1'] is Map &&
            (rirPlan['week1'] as Map)['session1'] is Map &&
            ((rirPlan['week1'] as Map)['session1'] as Map)['set1'] is Map) {
          final set1 = Map<String, dynamic>.from(
              ((rirPlan['week1'] as Map)['session1'] as Map)['set1'] as Map);
          final rir = set1['rir']?.toString();
          if (rir != null && rir.isNotEmpty) return rir;
        }
      } catch (_) {}
      return '';
    }

    // ---- controllers prefilled with current values ----
    final incrementsController = TextEditingController(
      text: _formatIncrementsForField(existingIncrements),
    );

    final repTargetsController = TextEditingController(
      text: _formatRepTargetsForField(existingRepTargets),
    );

    final rirController = TextEditingController(
      text: _formatRirForField(existingRirPlan),
    );

    Map<String, double> _parseIncrements(String txt) {
      final parts = txt
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

      if (parts.isEmpty) return {};

      final nums = parts
          .map((p) => double.tryParse(p.replaceAll(',', '.')))
          .whereType<double>()
          .toList();

      if (nums.isEmpty) return {};

      final map = <String, double>{};
      if (nums.length > 0) map['primary'] = nums[0];
      if (nums.length > 1) map['secondary'] = nums[1];
      if (nums.length > 2) map['tertiary'] = nums[2];
      return map;
    }

    Map<String, dynamic> _parseRepTargets(String txt) {
      // User enters:  "9 x 3, 15 x 3, 5 x 3"
      final entries = txt
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

      if (entries.isEmpty) return {};

      final week1 = <String, String>{};
      for (int i = 0; i < entries.length; i++) {
        week1['instance${i + 1}'] = entries[i];
      }

      return {
        'week1': week1,
      };
    }

    // 🔁 Update ALL week1 RIR values from controllers (sessionX.setY),
    // also stamping the correct REPS for each set from repTargets.
    Map<String, dynamic> _updateRirPlan(
        dynamic rirPlan,
        Map<String, TextEditingController> rirControllers,
        dynamic repTargetsRaw,
        ) {
      final plan = Map<String, dynamic>.from(rirPlan ?? {});

      // 🔎 Work out which week we're in right now
      final int? currentWeekIndex = _getApplicableWeekIndex(exerciseId);
      final int startWeekIndex = (currentWeekIndex ?? 0); // 0-based
      final String currentWeekKey = 'week${startWeekIndex + 1}';

      // Use the current week as the base template
      Map<String, dynamic> currentWeek =
      Map<String, dynamic>.from(plan[currentWeekKey] ?? {});

      // Build session → reps map from repTargets.week1.instanceX
      // (repTargets still driven off week1 only – unchanged)
      final Map<String, int> repsBySession = {};
      if (repTargetsRaw is Map && repTargetsRaw['week1'] is Map) {
        final rtWeek1 =
        Map<String, dynamic>.from(repTargetsRaw['week1'] as Map);
        final instKeys = rtWeek1.keys
            .where((k) => k.toString().startsWith('instance'))
            .toList()
          ..sort();
        for (int idx = 0; idx < instKeys.length; idx++) {
          final val = rtWeek1[instKeys[idx]]?.toString() ?? '';
          final match = RegExp(r'^(\d+)').firstMatch(val);
          if (match != null) {
            final reps = int.tryParse(match.group(1)!);
            if (reps != null) {
              repsBySession['session${idx + 1}'] = reps;
            }
          }
        }
      }

      rirControllers.forEach((key, ctrl) {
        final txt = ctrl.text.trim();
        if (txt.isEmpty) return;

        // key is "session1.set1"
        final parts = key.split('.');
        if (parts.length != 2) return;

        final sessionKey = parts[0]; // e.g. "session1"
        final setKey = parts[1]; // e.g. "set1"

        currentWeek[sessionKey] ??= {};
        final sessionMap =
        Map<String, dynamic>.from(currentWeek[sessionKey] as Map? ?? {});

        sessionMap[setKey] ??= {};
        final setMap =
        Map<String, dynamic>.from(sessionMap[setKey] as Map? ?? {});

        // ✅ write RIR
        setMap['rir'] = txt;

        // ✅ stamp reps for this session (non-editable in UI)
        final repsForSession = repsBySession[sessionKey];
        if (repsForSession != null) {
          setMap['reps'] = repsForSession.toString();
        }

        sessionMap[setKey] = setMap;
        currentWeek[sessionKey] = sessionMap;
      });

      // ✅ Save back to the current week
      plan[currentWeekKey] = currentWeek;

      // ✅ Propagate this pattern to all *later* weeks that already exist
      for (int wi = startWeekIndex + 1; wi < 20; wi++) {
        final wkKey = 'week${wi + 1}';
        if (!plan.containsKey(wkKey)) break;
        plan[wkKey] = Map<String, dynamic>.from(currentWeek);
      }

      return plan;
    }


    // ─────────────────────────────────────────────
    // Build controllers for WEEK 1, all sessions/sets
    // Sessions = weeklyFrequency / instances
    // Sets     = parsed from "9 x 3" etc
    // ─────────────────────────────────────────────
    final Map<String, int> repsBySession = {}; // "session1" → 9
    int weeklyFrequency = 0;
    int setsPerSession = 3; // default fallback

    if (existingRepTargets is Map && existingRepTargets['week1'] is Map) {
      final week1RT =
      Map<String, dynamic>.from(existingRepTargets['week1'] as Map);
      final instKeys = week1RT.keys
          .where((k) => k.toString().startsWith('instance'))
          .toList()
        ..sort();

      weeklyFrequency = instKeys.length;

      if (instKeys.isNotEmpty) {
        final firstVal = week1RT[instKeys[0]]?.toString() ?? '';
        final setsMatch = RegExp(r'x\s*(\d+)').firstMatch(firstVal);
        if (setsMatch != null) {
          setsPerSession =
              int.tryParse(setsMatch.group(1)!) ?? setsPerSession;
        }
      }

      for (int idx = 0; idx < instKeys.length; idx++) {
        final val = week1RT[instKeys[idx]]?.toString() ?? '';
        final repsMatch = RegExp(r'^(\\d+)').firstMatch(val);
        if (repsMatch != null) {
          final reps = int.tryParse(repsMatch.group(1)!);
          if (reps != null) {
            repsBySession['session${idx + 1}'] = reps;
          }
        }
      }
    }

    if (weeklyFrequency == 0) {
      weeklyFrequency = (existing['weeklyFrequency'] as int?) ?? 1;
    }

    final Map<String, TextEditingController> rirControllers = {};

    // 🎯 Per-session rep-target controllers: "instance1", "instance2", ...
    final Map<String, TextEditingController> repTargetControllers = {};

    if (existingRepTargets is Map && existingRepTargets['week1'] is Map) {
      final Map<String, dynamic> week1RT =
      Map<String, dynamic>.from(existingRepTargets['week1'] as Map);

      for (int s = 1; s <= weeklyFrequency; s++) {
        final instanceKey = 'instance$s';
        final existingVal = week1RT[instanceKey]?.toString() ?? '';
        repTargetControllers[instanceKey] =
            TextEditingController(text: existingVal);
      }
    } else {
      // No existing repTargets – create empty controllers for each session
      for (int s = 1; s <= weeklyFrequency; s++) {
        final instanceKey = 'instance$s';
        repTargetControllers[instanceKey] =
            TextEditingController(text: '');
      }
    }


// 🔎 Figure out which week we're in for pre-filling the dialog
    int? dialogWeekIndex = _getApplicableWeekIndex(exerciseId);
    dialogWeekIndex ??= 0; // fallback to week1 if null
    final String dialogWeekKey = 'week${dialogWeekIndex + 1}';

    final weekRir = (existingRirPlan is Map &&
        existingRirPlan[dialogWeekKey] is Map)
        ? (existingRirPlan[dialogWeekKey] as Map).cast<String, dynamic>()
        : <String, dynamic>{};

    for (int s = 1; s <= weeklyFrequency; s++) {
      final sessionKey = 'session$s';
      final sessionMap =
          (weekRir[sessionKey] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{};

      for (int set = 1; set <= setsPerSession; set++) {
        final setKey = 'set$set';
        final setMap =
            (sessionMap[setKey] as Map?)?.cast<String, dynamic>() ??
                <String, dynamic>{};
        final rirVal = setMap['rir']?.toString() ?? '';

        final controllerKey = '$sessionKey.$setKey';
        rirControllers[controllerKey] =
            TextEditingController(text: rirVal);
      }
    }



    // 🔢 Reps per session/set used ONLY for label text in the RIR dialog.
    final Map<String, String> repsBySessionSet = {};

// 1️⃣ Prefer reps already stored in the *current week's* RIR plan.
//     This aligns the dialog sessions with WES sessions.
    if (weekRir.isNotEmpty) {
      weekRir.forEach((sessionKey, sessionVal) {
        final sessionMap =
        (sessionVal as Map).cast<String, dynamic>();

        sessionMap.forEach((setKey, setVal) {
          final setMap =
          (setVal as Map).cast<String, dynamic>();
          final reps = setMap['reps']?.toString();
          if (reps != null && reps.isNotEmpty) {
            repsBySessionSet['$sessionKey.$setKey'] = reps;
          }
        });
      });
    }

// 2️⃣ Fallback: derive from repTargets if no RIR-set reps exist yet.
    if (repsBySessionSet.isEmpty &&
        existingRepTargets is Map &&
        existingRepTargets['week1'] is Map) {
      final week1Targets =
      (existingRepTargets['week1'] as Map).cast<String, dynamic>();

      week1Targets.forEach((instanceKey, value) {
        final raw = value.toString();
        final m = RegExp(r'(\d+)\s*x\s*(\d+)').firstMatch(raw);
        if (m == null) return;

        final reps = m.group(1)!;
        final setsCount = int.tryParse(m.group(2)!) ?? 0;
        if (setsCount <= 0) return;

        final instNum = int.tryParse(
          RegExp(r'(\d+)').firstMatch(instanceKey)?.group(1) ?? '',
        ) ?? 0;
        if (instNum <= 0) return;

        final sessionKey = 'session$instNum';
        for (int set = 1; set <= setsCount; set++) {
          repsBySessionSet['$sessionKey.set$set'] = reps;
        }
      });
    }

    // ─────────────────────────────────────────────
    // ✅ Compute *real* RIR session index (0-based),
    //    matching getRirFromPlanOrInput logic
    // ─────────────────────────────────────────────
    int currentRirSessionIndex = 0; // 0 → Session 1, 1 → Session 2, etc.

    try {
      if (blockStartDate != null && _selectedDate != null) {
        final String trimmedName = exerciseName.trim();
        final int resolvedWeekIndex = _getApplicableWeekIndex(exerciseId) ?? 0;

        final Map<String, dynamic> plannedDetails =
        Map<String, dynamic>.from(
          PeriodizationModelUtils.plannedExerciseDetails[exerciseId] ??
              const {},
        );

        // Same effectiveFreq logic as getRirFromPlanOrInput
        final Map<String, dynamic> repWeek1 =
            (plannedDetails['repTargets']?['week1'] as Map?)
                ?.cast<String, dynamic>() ??
                <String, dynamic>{};

        final repInstanceKeys = repWeek1.keys
            .where((k) => k.toString().startsWith('instance'))
            .toList()
          ..sort();

        final int repInstancesCount = repInstanceKeys.length;
        final int effectiveFreq = repInstancesCount > 0
            ? repInstancesCount
            : (plannedDetails['weeklyFrequency'] as int? ?? 1);

        final int rawSessionIndex =
        PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
          exerciseName: trimmedName,
          savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
          blockStartDate: blockStartDate!,
          weekIndex: resolvedWeekIndex,
          selectedDate: _selectedDate,
        );

        final int desiredSessionIndex =
        (effectiveFreq > 0) ? (rawSessionIndex % effectiveFreq) : 0;

        currentRirSessionIndex =
        desiredSessionIndex < 0 ? 0 : desiredSessionIndex;


      }
    } catch (e) {
      debugPrint('⚠️ [WES/RIR-Dialog] Failed to compute RIR session index: $e');
    }



    await showDialog(
    context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900,
          title: Text(
            'Exercise settings',
            style: const TextStyle(color: Colors.white),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  exerciseName,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 14),

                // Increments
                SizedBox(
                  width: 220,
                  height: 40,
                  child: TextField(
                    controller: incrementsController,
                    keyboardType: TextInputType.text,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9., ]')),
                    ],
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Increments (kg)',
                      hintText: '2.5, 1, 0.5',
                      labelStyle: const TextStyle(color: Colors.white),
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.blueGrey.shade700,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // Rep Targets (one box per session, like RIR)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Rep targets (week 1)',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 10,
                      children: [
                        for (int s = 1; s <= weeklyFrequency; s++)
                          SizedBox(
                            width: 110,
                            child: TextField(
                              controller:
                              repTargetControllers['instance$s'],
                              keyboardType: TextInputType.text,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                              decoration: InputDecoration(
                                labelText: 'Session $s',
                                hintText: '9 x 3',
                                labelStyle: const TextStyle(
                                  color: Colors.white70,
                                ),
                                hintStyle: const TextStyle(
                                  color: Colors.white38,
                                ),
                                filled: true,
                                fillColor: Colors.blueGrey.shade700,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                isDense: true,
                                contentPadding:
                                const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 6,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                const SizedBox(height: 10),

                // Week 1 RIR targets (all sessions / sets)
                if (rirControllers.isNotEmpty) ...[
                  const Text(
                    'RIR targets (week 1)',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  const SizedBox(height: 6),

                  // Group inputs by session
                  ...(() {
                    final Map<String,
                        List<MapEntry<String, TextEditingController>>> bySession =
                    {};

                    rirControllers.forEach((key, ctrl) {
                      final parts = key.split('.'); // "session1.set1"
                      if (parts.length != 2) return;
                      final sessionKey = parts[0];
                      final setKey = parts[1];
                      bySession.putIfAbsent(sessionKey, () => []);
                      bySession[sessionKey]!.add(MapEntry(setKey, ctrl));
                    });

                    final sessionNames = bySession.keys.toList()..sort();

                    return sessionNames.map((sessionKey) {
                      final entries = bySession[sessionKey]!;
                      entries.sort((a, b) => a.key.compareTo(b.key));

                      final sessionNumber = int.tryParse(
                        sessionKey.replaceAll(RegExp(r'[^0-9]'), ''),
                      ) ??
                          0;

                      // ⭐ NEW: 0-based index + highlight flag
                      final sessionIdx = sessionNumber - 1;
                      final bool isCurrentRirSession =
                          sessionIdx == currentRirSessionIndex;

                      final repsForSession = repsBySession[sessionKey];

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Session $sessionNumber',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              runSpacing: 10,
                              children: [
                                for (int i = 0; i < entries.length; i++)
                                  Builder(
                                    builder: (_) {
                                      final setNumber = i + 1;
                                      final controller = entries[i].value;

                                      final controllerKey = '$sessionKey.set$setNumber';
                                      final reps = repsBySessionSet[controllerKey];

                                      final labelText = (reps != null)
                                          ? 'Set $setNumber: $reps @ RIR'
                                          : 'Set $setNumber: ? @ RIR';

                                      return SizedBox(
                                        width: 110,
                                        child: TextField(
                                          controller: controller,
                                          keyboardType: const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                          ),
                                          decoration: InputDecoration(
                                            labelText: labelText,
                                            labelStyle: const TextStyle(color: Colors.white70),
                                            filled: true,
                                            fillColor: Colors.blueGrey.shade700,

                                            // ⭐⭐⭐ NEW: cyan border when RIR session matches
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(6),
                                              borderSide: BorderSide(
                                                color: isCurrentRirSession
                                                    ? Colors.cyanAccent
                                                    : Colors.grey,
                                                width: isCurrentRirSession ? 2 : 1,
                                              ),
                                            ),
                                            enabledBorder: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(6),
                                              borderSide: BorderSide(
                                                color: isCurrentRirSession
                                                    ? Colors.cyanAccent
                                                    : Colors.grey,
                                                width: isCurrentRirSession ? 2 : 1,
                                              ),
                                            ),
                                            focusedBorder: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(6),
                                              borderSide: BorderSide(
                                                color: isCurrentRirSession
                                                    ? Colors.cyanAccent
                                                    : Colors.lightBlueAccent,
                                                width: isCurrentRirSession ? 2 : 1.5,
                                              ),
                                            ),

                                            isDense: true,
                                            contentPadding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 6,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }).toList();

                  })(),
                ] else ...[
                  const Text(
                    'No week 1 RIR plan to edit.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],

              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final userId =
                    UserContext.of(context, listen: false).currentUid;
                if (userId == null || _selectedBlockId == null) {
                  Navigator.of(ctx).pop();
                  return;
                }

                // --- BUILD UPDATED MAPS ---
                final newIncrements =
                _parseIncrements(incrementsController.text);

                // Build repTargets as: { week1: { instance1: '9 x 3', ... } }
                final Map<String, dynamic> newRepTargets = {};
                final Map<String, String> week1RepMap = {};

                repTargetControllers.forEach((instanceKey, ctrl) {
                  final txt = ctrl.text.trim();
                  if (txt.isNotEmpty) {
                    week1RepMap[instanceKey] = txt;
                  }
                });

                if (week1RepMap.isNotEmpty) {
                  newRepTargets['week1'] = week1RepMap;
                }

                // Decide which repTargets drive the RIR plan:
                final dynamic repTargetsForRir =
                newRepTargets.isNotEmpty ? newRepTargets : existingRepTargets;


                // 🔥 NEW: update entire week1 RIR plan (all sessions + sets),
                // also stamping REPS for each set from repTargets
                final newRirPlan = _updateRirPlan(
                  existingRirPlan,
                  rirControllers,
                  repTargetsForRir,
                );

                final docRef = FirebaseFirestore.instance
                    .collection('planned_blocks')
                    .doc(userId)
                    .collection('blocks')
                    .doc(_selectedBlockId);

                // --- FIRESTORE SAVE: both plannedExerciseDetails & exerciseSettings ---
                final Map<String, dynamic> payloadPerExercise = {
                  if (newIncrements.isNotEmpty) 'increments': newIncrements,
                  if (newRepTargets.isNotEmpty) 'repTargets': newRepTargets,
                  'rirPlan': newRirPlan,
                };

                await docRef.set({
                  'plannedExerciseDetails': {
                    exerciseId: payloadPerExercise,
                  },
                  'exerciseSettings': {
                    exerciseId: payloadPerExercise,
                  },
                }, SetOptions(merge: true));

                // --- LOCAL STATE & PMU UPDATE ---
                setState(() {
                  final local = Map<String, dynamic>.from(
                    _exerciseSettings[exerciseId] ?? {},
                  );

                  if (newIncrements.isNotEmpty) {
                    local['increments'] = newIncrements;
                  }
                  if (newRepTargets.isNotEmpty) {
                    local['repTargets'] = newRepTargets;
                  } else if (repTargetsForRir != null) {
                    // keep existing repTargets so RIR "reps" stay in sync
                    local['repTargets'] = repTargetsForRir;
                  }
                  local['rirPlan'] = newRirPlan;
                  _exerciseSettings[exerciseId] = local;

                  // Mirror into PMU so WES hints see it immediately
                  final pmuEntry = Map<String, dynamic>.from(
                    PeriodizationModelUtils
                        .plannedExerciseDetails[exerciseId] ??
                        {},
                  );
                  if (newIncrements.isNotEmpty) {
                    pmuEntry['increments'] = newIncrements;
                  }
                  if (repTargetsForRir != null) {
                    pmuEntry['repTargets'] = repTargetsForRir;
                  }
                  pmuEntry['rirPlan'] = newRirPlan;
                  PeriodizationModelUtils
                      .plannedExerciseDetails[exerciseId] = pmuEntry;

                  // ⚡ Force WES to recompute hints immediately
                  _cachedProgressedValues.clear();
                });

                Navigator.of(ctx).pop();
              },
              child: const Text('Save'),
            ),

          ],
        );
      },
    );

  }

  Widget _buildExerciseSettingsCog(int i) {
    final exName = _selectedExercisesWithCircuits[i]['name']?.toString() ?? '';
    if (exName.isEmpty) {
      return const SizedBox.shrink();
    }

    final exerciseId = PeriodizationModelUtils.nameToId[exName];

    if (exerciseId == null) {
      debugPrint('⚠️ [WES] No exerciseId for "$exName" when opening settings cog.');
      return const SizedBox.shrink();
    }

    return IconButton(
      padding: EdgeInsets.zero,
      // 🔽 Force a small tap target so it doesn't blow up row height
      constraints: const BoxConstraints.tightFor(
        width: 15,
        height: 10,
      ),
      iconSize: 12,
      icon: const Icon(
        Icons.settings,
        size: 23,
        color: Colors.grey,
      ),
      onPressed: () {
        _showExerciseSettingsDialog(exerciseId, exName);
      },
    );
  }




  @override
  Widget build(BuildContext context) {
    // Non-blocking: always build the page; no spinner overlay.
    return _buildWesScaffold();
  }
// Tiny helper used above. Your existing Scaffold body stays unchanged.
  Widget _buildWesScaffold() {
    // ── DEBUG: first rows visible (no spinner path at all) ─────────
    if (!_firstRowsLogged && _selectedExercisesWithCircuits.isNotEmpty) {
      _firstRowsLogged = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        print('🟢 [WES UI] First rows visible in frame → rows=${_selectedExercisesWithCircuits.length}');
      });
    }
    // ───────────────────────────────────────────────────────────────
    return Stack(
        children: [
        // Your existing page (unchanged, just moved inside the Stack)
        WillPopScope(
        onWillPop: () async {
      if (_pendingChanges) {
        await _upsertWorkoutToFirestore(alsoPushToBB2: false, markAllSaved: false);
      }
      return true;
    },
    child: Scaffold(
    backgroundColor: Colors.blueGrey.shade900,
    appBar: AppBar(
    backgroundColor: Colors.blueGrey.shade800,
    title: Builder(
            builder: (context) {
              final actingAsUid = Provider.of<UserContext>(context, listen: true).actingAsUid;

              final nameStyle = GoogleFonts.monda(
                color: Colors.white,
              ).copyWith(
                // Fallbacks if Monda can't load for any reason
                fontFamilyFallback: const ['Roboto', 'Helvetica', 'Arial'],
              );

              if (actingAsUid == null) {
                return Text('Razors Edge', style: nameStyle);
              }

              return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('users')
                    .doc(actingAsUid)
                    .snapshots(),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return Text('Razors Edge', style: nameStyle);
                  }

                  final data = snap.data?.data();
                  String? pick(dynamic v) {
                    final s = (v ?? '').toString().trim();
                    return s.isEmpty ? null : s;
                  }

                  final label = pick(data?['username']) ??
                      pick(data?['displayName']) ??
                      pick(data?['email']) ??
                      'Razors Edge';

                  return Text(
                    label,
                    style: nameStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
                },
              );
            },
          ),

          iconTheme: const IconThemeData(color: Colors.white),
          actionsIconTheme: const IconThemeData(color: Colors.white),
          actions: [
            IconButton(

            icon: const Icon(Icons.undo),
              tooltip: "Undo last action",
              onPressed: _undoStack.isNotEmpty
                  ? () {
                if (_applyingUndo) return;
                _applyingUndo = true;
                (_undoStack.removeLast())();
                _applyingUndo = false;
              }
                  : null,
            ),


            IconButton(
              icon: const Icon(
                Icons.auto_awesome,
                color: Colors.amberAccent,
              ),
              tooltip: 'Refresh hints',
              onPressed: () async {
                debugPrint('✨ [SparkleBtn] pressed, mounted=$mounted');

                // ✅ Capture uid BEFORE awaits (avoid context lookups later)
                final String uid = (_cachedUid?.isNotEmpty == true)
                    ? _cachedUid!
                    : UserContext.of(context, listen: false).currentUid;

                void showSafeSnack(String text) {
                  // ✅ Defer snackbar until next frame + re-resolve messenger fresh
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    final m = ScaffoldMessenger.maybeOf(context);
                    m?.hideCurrentSnackBar();
                    m?.showSnackBar(SnackBar(content: Text(text)));
                  });
                }

                // Immediate feedback (safe)
                showSafeSnack('Refreshing ✨');

                final ok = await _refreshHintsForSelectedDay(alsoWarmTomorrow: true);
                debugPrint('✨ [SparkleBtn] refresh result ok=$ok (mounted=$mounted)');

                if (!mounted) return;

                if (ok) {
                  if (uid.isNotEmpty) {
                    final (sex, dob) = await DemographicsCache.load(uid);
                    if (!mounted) return;

                    final msg = _hintsReadySnackMessage(sexRaw: sex, dobRaw: dob);
                    showSafeSnack(msg);
                  } else {
                    showSafeSnack('Suggested weights and reps are ready');
                  }

                  // ✨ Run sparkles only when refresh succeeded
                  if (mounted) _playSparkles();
                } else {
                  showSafeSnack('Refresh failed');
                }
              },
            ),


            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (BuildContext dialogCtx) {
                    return AlertDialog(
                      backgroundColor: Colors.blueGrey.shade900,
                      title: const Text(
                        'Clear Workout',
                        style: TextStyle(fontFamily: 'Verdana', color: Colors.white),
                      ),
                      content: const Text(
                        'Delete this workout?',
                        style: TextStyle(fontFamily: 'Verdana', color: Colors.white),
                      ),
                      actions: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(dialogCtx).pop(),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () async {
                            // Close the dialog (same as before, just async now)
                            final messenger = rootScaffoldMessengerKey.currentState;

                            Navigator.of(dialogCtx).pop();

                            // 🔥 1) Run nukes (same as the bolt button)
                            final uid = _cachedUid ??
                                UserContext.of(context, listen: false).currentUid;
                            final blockId = _selectedBlockId ?? _activeBlockId;

                            if (uid != null && uid.isNotEmpty && blockId != null) {
                              try {
                                // Per-day nuke for this date
                                await nukeLocalWorkoutsForDay(
                                  uid: uid,
                                  blockId: blockId,
                                  date: _selectedDate,
                                  blockStartDate: blockStartDate,
                                  getWesDraftKeyForDate: (d) => _getDraftKeyFor(d),
                                );

                                // Global WES planned + local caches (all dates)
                                await nukeAllWesPlannedAndLocalCaches(
                                  uid: uid,
                                  blockId: blockId,
                                );

                                final (sex, dob) = await DemographicsCache.load(uid);

                                final msg = _nukeSnackMessage(
                                  sexRaw: sex,
                                  dobRaw: dob,
                                );

                                showAppSnack(msg);



                              } catch (e, st) {
                                debugPrint('❌ [ClearWorkout] Nuke failed: $e');
                                debugPrint('$st');
                                showAppSnack('⚠️ Failed to clear all caches, see logs');




                              }
                            } else {
                              debugPrint(
                                  '⚠️ [ClearWorkout] Skipping nukes (uid/blockId missing)');
                            }

                            // ✅ 2) Original in-memory clear behaviour (unchanged)
                            if (!mounted) return;
                            setState(() {
                              _workoutNameController.clear();
                              _selectedExercisesWithCircuits.clear();
                              _workoutSets.clear();
                              _initializeControllers();
                            });

                          },
                          child: const Text('Yes'),
                        ),
                      ],
                    );
                  },
                );
              },
            ),




           /* IconButton(
              icon: const Icon(Icons.bolt, color: Colors.orange), // 💥 closest stock icon; swap if you add custom nuclear icon
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (BuildContext context) {
                    return AlertDialog(
                      backgroundColor: Colors.blueGrey.shade900,
                      title: const Text(
                        'NUKE Local Cache',
                        style: TextStyle(fontFamily: 'Verdana', color: Colors.white),
                      ),
                      content: Text(
                        'Delete ALL locally stored data for ${DateFormat('yyyy-MM-dd').format(_selectedDate)}?\n\n'
                            'This will wipe WESInit, WorkoutDayCache, BB2 BlockDay, SharedPrefs (drafts) for this date.',
                        style: const TextStyle(fontFamily: 'Verdana', color: Colors.white),
                      ),
                      actions: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () async {
                            Navigator.of(context).pop();

                            // 1) Your existing per-day nuke
                            await nukeLocalWorkoutsForDay(
                              uid: _cachedUid ?? UserContext.of(context, listen: false).currentUid!,
                              blockId: _selectedBlockId ?? _activeBlockId!,
                              date: _selectedDate,
                              blockStartDate: blockStartDate,
                              getWesDraftKeyForDate: (d) => _getDraftKeyFor(d),
                            );

                            // 2) Global wipe (ALL dates) of WES planned + all local caches
                            await nukeAllWesPlannedAndLocalCaches(
                              uid: _cachedUid ?? UserContext.of(context, listen: false).currentUid!,
                              blockId: _selectedBlockId ?? _activeBlockId!, // optional
                            );

                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('💥 Local + WESPlanned nuked')),
                            );
                          },
                          child: const Text('NUKE', style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    );
                  },
                );
              },
            ), */


            IconButton(
              icon: const Icon(Icons.save),
              onPressed: () async {
                final msg = await _saveWorkout();
                if (msg == null) return;

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  final sm = rootScaffoldMessengerKey.currentState;
                  if (sm == null || !sm.mounted) return;

                  sm.clearSnackBars();
                  sm.showSnackBar(
                    SnackBar(
                      content: Text(msg),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                });
              },

            ),
          ],
        ),
    body: GestureDetector(
    behavior: HitTestBehavior.translucent,
    onTap: () => FocusScope.of(context).unfocus(),
    child: SingleChildScrollView(
    padding: const EdgeInsets.only(
    left: 12, top: 0, right: 12, bottom: 0),
    child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
    TextField(
    controller: _workoutNameController,
                style: TextStyle(fontSize: 18),
                textAlign: TextAlign.center, // 👈 Center the text,
                decoration: InputDecoration(
                  // ✅ remove `const`
                  labelStyle: const TextStyle(color: Colors.white),
                  filled: true,
                  fillColor: Colors.blueGrey.shade900,
                  // ✅ works now
                  border: OutlineInputBorder(borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(
                      vertical: 10, horizontal: 12), // 👈 Tighten spacing
                ),
              ),
// 🆕 Add a non-editable display of the workout date
              // 🆕 Date displayed below, uneditable

              GestureDetector(
                behavior: HitTestBehavior.opaque, // makes the whole area swipeable
                onHorizontalDragUpdate: (details) {
                  _dragX += details.delta.dx;
                },
                onHorizontalDragEnd: (_) {
                  // simple threshold for intentional swipes
                  if (_dragX > 24) {
                    final next = _selectedDate.add(const Duration(days: -1));
                    _enqueueDateChange(next);
                  } else if (_dragX < -24) {
                    final next = _selectedDate.add(const Duration(days: 1));
                    _enqueueDateChange(next);
                  }

                  _dragX = 0;
                },
                child: Padding(
                  padding: const EdgeInsets.only(left: 8.0, bottom: 7.0),
                  child: Row(
                    children: [
                      // Date text (same as before)
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            DateFormat('EEE d MMM yyyy').format(_selectedDate),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),




              const SizedBox(height: 0.0),
              Padding(
                padding: const EdgeInsets.only(
                    left: 5,
                    top: 0,
                    right: 5,
                    bottom: 0), // 🔥 Added cleaner side spacing
                child: Row(
                  children: [
                    Flexible(
                      flex: 4,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _isMergingBB2,
                        builder: (context, merging, _) {
                          return ElevatedButton.icon(
                            icon: const Icon(Icons.add, size: 16),
                            label: Text(
                              "Add Exercises",
                              style: TextStyle(
                                fontSize: 14,
                                color: merging ? Colors.grey.shade400 : Colors.white,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: merging
                                  ? Colors.blueGrey.shade700.withOpacity(0.55)
                                  : Colors.blueGrey.shade700,
                              foregroundColor: merging ? Colors.grey.shade400 : Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
                            ),
                            onPressed: merging ? null : _showExercisePickerDialog,
                          );
                        },
                      ),

                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      flex: 3,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueGrey.shade700,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 2, vertical: 8),
                        ),
                        onPressed: _showTemplateSelectionDialog,
                        child: const Text('Load Template',
                            style: TextStyle(
                                fontSize: 13,
                                fontFamily: 'Verdana',
                                color: Colors.white)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      flex: 3,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueGrey.shade700,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 8),
                        ),
                        onPressed: () => _selectDate(context),
                        child: const Text('Select Date',
                            style: TextStyle(
                                fontFamily: 'Verdana', color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 4.0),

              if (_selectedExercisesWithCircuits.isEmpty) ...[
                // Empty-state info
                Column(
                  children: const [
                    Text(
                      'No exercises selected yet. Add some to get started.',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    SizedBox(height: 6),
                  ],
                ),

                // Row with Catch-up (left) and Add Circuit (right)


                const SizedBox(height: 0),
              ]
              else
              // 👇 your existing “not empty” branch continues here


                ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  onReorder: _onReorderExercises,
                  children: List.generate(
                      _selectedExercisesWithCircuits.length, (i) {
                    // 🛡 Defensive check for list mismatches
                    if (i >= _selectedExercisesWithCircuits.length ||
                        i >= _workoutSets.length ||
                        i >= _repsControllers.length ||
                        i >= _weightControllers.length ||
                        i >= _rirControllers.length ||
                        i >= _velocityControllers.length ||
                        i >= _notesControllers.length) {
                      print("⚠️ Skipping index $i due to mismatched list lengths");
                      return SizedBox(
                        key: ValueKey('skipped_$i'),
                      );
                    }


                    final current = _selectedExercisesWithCircuits[i];
                    final prev = i > 0
                        ? _selectedExercisesWithCircuits[i - 1]
                        : null;
                    final isNewCircuit = i == 0 ||
                        current['circuitIndex'] != prev?['circuitIndex'];

// 🔑 stable key for this row (per-card unique)
                    final name = (current['name'] ?? '').toString().trim();
                    final ci   = (current['circuitIndex'] ?? 0) as int;
                    final exIdRaw = (current['exerciseId'] ?? current['id'])?.toString()?.trim();
                    final stableExId = (exIdRaw != null && exIdRaw.isNotEmpty) ? exIdRaw : name.toLowerCase();
                    final cardId = '$stableExId|$ci';



                    return Column(
                      key: ValueKey('col_$cardId'),



                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isNewCircuit)if (isNewCircuit) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 6),
                            child: Row(
                              children: [
                                Text(
                                  'Circuit ${current['circuitIndex'] + 1}',
                                  style: const TextStyle(
                                    color: Colors.lightBlueAccent,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                                const Spacer(),

                                // ✅ Show button on the *first circuit header*, whatever its index is
                                if (_hasMissedForToday &&
                                    current['circuitIndex'] ==
                                        (_selectedExercisesWithCircuits
                                            .isNotEmpty
                                            ? _selectedExercisesWithCircuits
                                            .first['circuitIndex']
                                            : 0))
                                  _buildCatchUpButton(),
                              ],
                            ),
                          ),
                        ],


                        Dismissible(
                          key: ValueKey('dismiss_$cardId'),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            color: Colors.red,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 16),
                            child: const Icon(
                                Icons.delete, color: Colors.white),
                          ),
                          onDismissed: (_) async {
                            final capturedOrigIdx  = i;
                            final capturedExercise = Map<String, dynamic>.from(_selectedExercisesWithCircuits[i]);
                            final capturedSets     = _workoutSets[i]
                                .map((s) => SetDetails(reps: s.reps, weight: s.weight, rir: s.rir,
                                                       velocity: s.velocity, notes: s.notes))
                                .toList();
                            final capturedRepsT     = _repsControllers[i].map((c) => c.text).toList();
                            final capturedWeightT   = _weightControllers[i].map((c) => c.text).toList();
                            final capturedRirT      = _rirControllers[i].map((c) => c.text).toList();
                            final capturedVelocityT = _velocityControllers[i].map((c) => c.text).toList();
                            final capturedNotesT    = _notesControllers[i].map((c) => c.text).toList();

                            // Extract keys for cache operations
                            final String removedName = ((capturedExercise['name'] ?? '') as String).trim();
                            final int removedCi = (capturedExercise['circuitIndex'] is num)
                                ? (capturedExercise['circuitIndex'] as num).toInt()
                                : 0;
                            final String? removedExId = (capturedExercise['exerciseId'] ?? capturedExercise['id'])?.toString();

                            // Dispose controllers before removing from lists
                            for (final c in _repsControllers[i]) c.dispose();
                            for (final c in _weightControllers[i]) c.dispose();
                            for (final c in _rirControllers[i]) c.dispose();
                            for (final c in _velocityControllers[i]) c.dispose();
                            for (final c in _notesControllers[i]) c.dispose();

                            setState(() {
                              _selectedExercisesWithCircuits.removeAt(i);
                              _workoutSets.removeAt(i);
                              _repsControllers.removeAt(i);
                              _weightControllers.removeAt(i);
                              _rirControllers.removeAt(i);
                              _velocityControllers.removeAt(i);
                              _notesControllers.removeAt(i);
                            });

                            await _pruneBb2DayCacheForSelectedDate(
                              name: removedName,
                              circuitIndex: removedCi,
                              exerciseId: removedExId,
                            );

                            await _deleteExerciseEverywhereForDate(
                              exerciseRow: capturedExercise,
                              date: _selectedDate,
                            );

                            final VoidCallback undoAction = () {
                              if (!mounted) return;
                              final insertAt = capturedOrigIdx.clamp(0, _selectedExercisesWithCircuits.length);
                              setState(() {
                                _selectedExercisesWithCircuits.insert(insertAt, capturedExercise);
                                _workoutSets.insert(insertAt, capturedSets);
                                _repsControllers.insert(insertAt,
                                    capturedRepsT.map((t) => TextEditingController(text: t)).toList());
                                _weightControllers.insert(insertAt,
                                    capturedWeightT.map((t) => TextEditingController(text: t)).toList());
                                _rirControllers.insert(insertAt,
                                    capturedRirT.map((t) => TextEditingController(text: t)).toList());
                                _velocityControllers.insert(insertAt,
                                    capturedVelocityT.map((t) => TextEditingController(text: t)).toList());
                                _notesControllers.insert(insertAt,
                                    capturedNotesT.map((t) => TextEditingController(text: t)).toList());
                              });
                              unawaited(_restoreBb2DayCacheForSelectedDate(exerciseRow: capturedExercise));
                              _attachDirtyListeners();
                            };
                            _undoStack.add(undoAction);

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Deleted "$removedName"'),
                                action: SnackBarAction(
                                  label: 'Undo',
                                  textColor: Colors.blueGrey.shade700,
                                  onPressed: () {
                                    if (_applyingUndo) return;
                                    _applyingUndo = true;
                                    _undoStack.remove(undoAction);
                                    undoAction();
                                    _applyingUndo = false;
                                  },
                                ),
                              ),
                            );
                          },



                          child: FutureBuilder<void>(
                              future: _initialLoad,
                              // ✅ Keep the wrapper, but do NOT gate rendering on snapshot
                              builder: (context, snapshot) {
                                // 🔓 No gating: always render the row; reconciliation happens in background
                                final bool isSaved = _isExerciseSaved(i);

                                final exId   = _selectedExercisesWithCircuits[i]['exerciseId'] ?? _selectedExercisesWithCircuits[i]['id'];
                                final exName = _selectedExercisesWithCircuits[i]['name'] ?? '';

// Try ID → fallback to name
                                String? videoKey;
                                if (exId != null && kExerciseVideoAssets.containsKey(exId)) {
                                  videoKey = exId;
                                } else if (exName.isNotEmpty && kExerciseVideoAssets.containsKey(exName)) {
                                  videoKey = exName;
                                }



                                // TEMP: inspect structure for this row
                                debugPrint('_selectedExercisesWithCircuits[$i] = ${_selectedExercisesWithCircuits[i]}');

                                return Card(
                                  key: ValueKey('card_$cardId'),

                                  // 👈 Unique per exercise
                                  color: Colors.blueGrey.shade700,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  margin: const EdgeInsets.only(
                                      left: 0, top: 2, right: 0, bottom: 0),

                                  child: ExpansionTile(
                                    key: ValueKey('wes_ex_tile_${cardId}_$isSaved'),
                                    // 👆 include isSaved in the key so the tile fully rebuilds when saved state changes

                                    // saved → collapsed by default
                                    initiallyExpanded: !isSaved,

                                    // saved → collapsed by default
                                    tilePadding: const EdgeInsets.symmetric(
                                        horizontal: 8),

                                    // 🔹 Subtle saved-format background
                                    backgroundColor: isSaved
                                        ? Theme
                                        .of(context)
                                        .colorScheme
                                        .surfaceVariant
                                        .withOpacity(0.6)
                                        : Theme
                                        .of(context)
                                        .colorScheme
                                        .surface,
                                    collapsedBackgroundColor: isSaved
                                        ? Theme
                                        .of(context)
                                        .colorScheme
                                        .surfaceVariant
                                        .withOpacity(0.6)
                                        : Theme
                                        .of(context)
                                        .colorScheme
                                        .surface,

                                    // Optional: saved gets a friendlier icon tint
                                    iconColor: isSaved
                                        ? Colors.greenAccent
                                        : Theme
                                        .of(context)
                                        .iconTheme
                                        .color,
                                    collapsedIconColor: isSaved ? Colors
                                        .greenAccent : Theme
                                        .of(context)
                                        .iconTheme
                                        .color,

                                    title: (_selectedExercisesWithCircuits[i]['name'] ??
                                        '').isEmpty
                                        ? TextButton(
                                      onPressed: () =>
                                          _showExercisePickerForRow(i),
                                      child: const Text(
                                        'Select Exercise',
                                        style: TextStyle(color: Colors.white70),
                                      ),
                                    )
                                        : Text(
                                      _selectedExercisesWithCircuits[i]['name'],
                                      style: TextStyle(
                                        color: Colors.grey.shade300,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),

                                    // 👇 Wrap trailing in a Builder so we can print before returning the Row
                                    trailing: Builder(
                                      builder: (context) {
                                        final ex = _selectedExercisesWithCircuits[i];
                                        final String name = ex['name'] ?? '';
                                        final String? id = (ex['exerciseId'] ?? ex['id'])?.toString();

// Prefer ID, fall back to name (matches your kExerciseVideoAssets keys)
                                        final String videoKey = (id ?? name).trim();

// Look up the asset path in the map
                                        final String? assetPath = videoKey.isEmpty
                                            ? null
                                            : (kExerciseVideoAssets[videoKey] ??
                                            kExerciseVideoAssets[videoKey.trim()]);


                                        debugPrint(
                                          '🎥 row video lookup → '
                                              'name="$name", id="$id", key="$videoKey", asset="$assetPath"',
                                        );

                                        return Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            // If already saved → show the green "Saved" pill
                                            if (isSaved) ...[
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                                margin: const EdgeInsets.only(right: 1),
                                                decoration: BoxDecoration(
                                                  color: Colors.green.withOpacity(0.15),
                                                  borderRadius: BorderRadius.circular(12),
                                                  border: Border.all(color: Colors.green.withOpacity(0.6)),
                                                ),
                                                child: const Row(
                                                  children: [
                                                    Icon(Icons.check_circle, size: 14, color: Colors.green),
                                                    SizedBox(width: 4),
                                                    Text(
                                                      'Done',
                                                      style: TextStyle(fontSize: 11, color: Colors.green),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],

                                            // 🎥 Only show the video icon if we actually found a video asset
                                            if (assetPath != null)
                                              GestureDetector(
                                                onTap: () {
                                                  debugPrint('▶️ Opening video: $assetPath');
                                                  Navigator.of(context).push(
                                                    MaterialPageRoute(
                                                      builder: (_) => ExerciseVideoPlayerScreen(
                                                        assetPath: assetPath,
                                                        exerciseName: name,   // ← add this
                                                      ),

                                                    ),
                                                  );
                                                },
                                                child: Icon(
                                                  Icons.play_circle_fill,
                                                  size: 22,
                                                  color: Colors.blueGrey.shade400,
                                                ),
                                              ),

                                            // Existing graph button
                                            IconButton(
                                              icon: const Icon(Icons.insights),
                                              color: Colors.lightBlueAccent,
                                              onPressed: () {
                                                _navigateToExerciseDetails(
                                                  _selectedExercisesWithCircuits[i]['name'] ?? '',
                                                );
                                              },
                                            ),

                                            const SizedBox(width: 1),

                                            // Existing History button
                                            ElevatedButton(
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.blueGrey[700],
                                              ),
                                              onPressed: () {
                                                _navigateToTopSets(
                                                  _selectedExercisesWithCircuits[i]['name'] ?? '',
                                                );
                                              },
                                              child: const Text(
                                                'History',
                                                style: TextStyle(
                                                  fontFamily: 'Verdana',
                                                  color: Colors.white70,
                                                ),
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    ),


                                    children: [
                                      StatefulBuilder(
                                        builder: (context, rebuildCard) {
                                          return Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [

                                      // 👇 Your set rows and other ExpansionTile children continue here

                                      // New row between selected exercise and workout sets:
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6.0, vertical: 0),
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment
                                              .end, // 👈 Pushes to the right
                                          children: [],
                                        ),
                                      ),

                                      for (int j = 0; j <
                                          _workoutSets[i].length; j++)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                              left: 6,
                                              bottom: 0,
                                              top: 0,
                                              right: 6),
                                          child: Column(
                                            crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                            children: [
                                              if (j == 0) ...[
                                                const SizedBox(height: 2),
                                                Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 1),
                                                  child: SingleChildScrollView(
                                                    scrollDirection: Axis
                                                        .horizontal,
                                                    child: Row(
                                                      mainAxisAlignment:
                                                      MainAxisAlignment
                                                          .spaceBetween,
                                                      crossAxisAlignment: CrossAxisAlignment
                                                          .center,
                                                      // ✅ Center vertically
                                                      children: [
                                                        // ➡️ Previous Rep Targets + Available Rep Targets (on the LEFT)
                                                        Column(
                                                          crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                          children: [
                                                            Text(
                                                                  () {
                                                                final exerciseName =
                                                                    _selectedExercisesWithCircuits[i]['name']
                                                                        ?.toString()
                                                                        .trim() ??
                                                                        '';
                                                                final String? exerciseId =
                                                                (_selectedExercisesWithCircuits[i]['exerciseId'] ??
                                                                    _selectedExercisesWithCircuits[i]['id'])
                                                                    ?.toString();
                                                                final String historyKey = exerciseId ?? exerciseName;

                                                                final targetWeight = _isInitialized
                                                                    ? set1SuggestedWeight(i)
                                                                    : 20.0;

                                                                final history =
                                                                    PeriodizationModelUtils.topSetsByExercise[historyKey] ??
                                                                        PeriodizationModelUtils.topSetsByExercise[exerciseName] ??
                                                                        [];

                                                                final matchingSets = history
                                                                    .where((s) =>
                                                                (s['weight'] as double).toStringAsFixed(1) ==
                                                                    targetWeight.toStringAsFixed(1))
                                                                    .toList();

                                                                if (matchingSets.isEmpty) {
                                                                  return 'No previous sets at ${targetWeight.toStringAsFixed(1)} kg';
                                                                }

                                                                matchingSets.sort((a, b) {
                                                                  final repsA = a['reps'] ?? 0.0;
                                                                  final repsB = b['reps'] ?? 0.0;
                                                                  final rirA = a['rir'] ?? 99.0;
                                                                  final rirB = b['rir'] ?? 99.0;

                                                                  if (repsB.compareTo(repsA) != 0) {
                                                                    return repsB.compareTo(repsA);
                                                                  }
                                                                  return rirA.compareTo(rirB);
                                                                });

                                                                final best = matchingSets.first;
                                                                final reps = best['reps'];
                                                                final rir = best['rir'];

                                                                return 'Best at ${targetWeight.toStringAsFixed(1)} kg: $reps reps @ RIR $rir';
                                                              }(),
                                                              style: const TextStyle(
                                                                fontSize: 10.0,
                                                                fontWeight: FontWeight.bold,
                                                                color: Colors.white24,
                                                              ),
                                                            ),
                                                            const SizedBox(height: 0),
                                                            Builder(
                                                              builder: (context) {
                                                                if (!_isInitialized) {
                                                                  return const Text(
                                                                    'Loading...',
                                                                    style: TextStyle(
                                                                      fontSize: 10.0,
                                                                      fontWeight: FontWeight.bold,
                                                                      color: Colors.white54,
                                                                    ),
                                                                  );
                                                                }

                                                                final exerciseName =
                                                                    _selectedExercisesWithCircuits[i]['name']
                                                                        ?.toString()
                                                                        .trim() ??
                                                                        '';
                                                                final String? exerciseId =
                                                                (_selectedExercisesWithCircuits[i]['exerciseId'] ??
                                                                    _selectedExercisesWithCircuits[i]['id'])
                                                                    ?.toString();
                                                                final String historyKey = exerciseId ?? exerciseName;

                                                                final repTarget = set1SuggestedReps(i); // no `.round()` yet

                                                                if (repTarget == null) {
                                                                  return const Text(
                                                                    'Loading...',
                                                                    style: TextStyle(
                                                                      fontSize: 10.0,
                                                                      fontWeight: FontWeight.bold,
                                                                      color: Colors.white54,
                                                                    ),
                                                                  );
                                                                }

                                                                final roundedTarget = repTarget.round(); // (kept for behaviour parity even if unused)
                                                                final history =
                                                                    PeriodizationModelUtils.topSetsByExercise[historyKey] ??
                                                                        PeriodizationModelUtils.topSetsByExercise[exerciseName] ??
                                                                        [];

                                                                final matchingSets = history.where((s) {
                                                                  final reps = (s['reps'] as num?)?.round();
                                                                  return reps == repTarget;
                                                                }).toList();

                                                                if (matchingSets.isEmpty) {
                                                                  return Text(
                                                                    'No previous sets at $repTarget reps',
                                                                    style: const TextStyle(
                                                                      fontSize: 10.0,
                                                                      fontWeight: FontWeight.bold,
                                                                      color: Colors.white54,
                                                                    ),
                                                                  );
                                                                }

                                                                matchingSets.sort((a, b) {
                                                                  final wa = a['weight'] ?? 0.0;
                                                                  final wb = b['weight'] ?? 0.0;
                                                                  return (wb as num).compareTo(wa as num);
                                                                });

                                                                final best = matchingSets.first;
                                                                double weight =
                                                                    (best['weight'] as num?)?.toDouble() ?? 0.0;

                                                                final isBwEx = PeriodizationModelUtils.isBodyweightExercise(
                                                                  id: exerciseId ??
                                                                      PeriodizationModelUtils.nameToId[exerciseName] ??
                                                                      exerciseName,
                                                                  name: exerciseName,
                                                                );

                                                                if (isBwEx) {
                                                                  weight = PeriodizationModelUtils.toDisplayAddedWeight(
                                                                    uid: _cachedUid ??
                                                                        FirebaseAuth.instance.currentUser?.uid ??
                                                                        '',
                                                                    absoluteKg: weight,
                                                                    exerciseId: exerciseId ??
                                                                        PeriodizationModelUtils.nameToId[exerciseName] ??
                                                                        exerciseName,
                                                                    exerciseName: exerciseName,
                                                                    asOfDate: (best['date'] is DateTime)
                                                                        ? best['date']
                                                                        : null,
                                                                  );
                                                                }

                                                                final rir = best['rir'];

                                                                return Text(
                                                                  'Best at $repTarget reps: ${weight.toStringAsFixed(1)} kg @ RIR ${rir.toString()}',
                                                                  style: const TextStyle(
                                                                    fontSize: 10.0,
                                                                    fontWeight: FontWeight.bold,
                                                                    color: Colors.white54,
                                                                  ),
                                                                );
                                                              },
                                                            ),
                                                          ],

                                                        ),

                                                        const SizedBox(
                                                            width: 1),
                                                        // ⚙️ Exercise settings cog (opens small dialog)
                                                        _buildExerciseSettingsCog(i),
                                                        const SizedBox(width: 1),

                                                        // ➡️ Avg E1RM (on the RIGHT)
                                                        Text(
                                                          'Avg E1RM: ${getAverageE1RM(
                                                              _selectedExercisesWithCircuits[i]['name'] ??
                                                                  '')
                                                              .toStringAsFixed(1)}Kg',
                                                          style: const TextStyle(
                                                            fontSize: 12.0,
                                                            fontWeight: FontWeight.bold,
                                                            color: Colors.blueGrey,
                                                          ),
                                                        ),

                                                      ],
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(height: 1),
                                              ],

                                              SizedBox(
                                                height:
                                                25,
                                                // or 26, or 28 (experiment to see what feels tight but readable)
                                                child: Row(
                                                  mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                                  crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                                  children: [
                                                    Padding(
                                                      padding: const EdgeInsets
                                                          .only(
                                                          left: 4, top: 5),
                                                      child: Text(
                                                        'Set ${j + 1}',
                                                        style: const TextStyle(
                                                          fontWeight: FontWeight
                                                              .bold,
                                                          fontSize: 12.0,
                                                          color: Colors.white70,
                                                        ),
                                                      ),
                                                    ),
                                                    Container(
                                                      padding:
                                                      const EdgeInsets.only(
                                                          top: 2),
                                                      child: IconButton(
                                                        icon: const Icon(Icons
                                                            .remove),
                                                        iconSize: 18,
                                                        padding: EdgeInsets
                                                            .zero,
                                                        constraints:
                                                        const BoxConstraints(),
                                                        onPressed: () =>
                                                            removeSet(i, j),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),

                                              // ✅ Header Row with aligned labels
                                              SingleChildScrollView(
                                                controller: _horizontalScrollController,
                                                scrollDirection: Axis
                                                    .horizontal,
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment
                                                      .start,
                                                  children: [
                                                    // 🟨 Header Row (per exercise row)
                                                    Row(
                                                      crossAxisAlignment: CrossAxisAlignment
                                                          .start,
                                                      children: [
                                                        const SizedBox(
                                                          width: 76,
                                                          child: Padding(
                                                            padding: EdgeInsets
                                                                .only(left: 3),
                                                            child: Text(
                                                                'Weight',
                                                                style: _headerStyle),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                            width: 4),

                                                        const SizedBox(
                                                          width: 50,
                                                          child: Padding(
                                                            padding: EdgeInsets
                                                                .only(left: 2),
                                                            child: Text('Reps',
                                                                style: _headerStyle),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                            width: 4),

                                                        const SizedBox(
                                                          width: 50,
                                                          child: Padding(
                                                            padding: EdgeInsets
                                                                .only(left: 3),
                                                            child: Text('RIR',
                                                                style: _headerStyle),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                            width: 4),


                                                        const SizedBox(
                                                          width: 55,
                                                          child: Text('E1RM', style: _headerStyle),
                                                        ),
                                                        const SizedBox(width: 4),

// ✅ Conditionally include Velocity (header)
                                                        if (_showVelocityByExercise[
                                                        '${(_selectedExercisesWithCircuits[i]['name'] as String).toLowerCase()}|${_selectedExercisesWithCircuits[i]['circuitIndex']}'
                                                        ] == true ||
                                                            _showVelocityByExercise[
                                                            (_selectedExercisesWithCircuits[i]['name'] as String).toLowerCase()
                                                            ] == true) ...[
                                                          const SizedBox(
                                                            width: 45,
                                                            child: Text('Vel.', style: _headerStyle),
                                                          ),
                                                          const SizedBox(width: 4),
                                                        ],

                                                        const SizedBox(
                                                          width: 120,
                                                          child: Text('Notes', style: _headerStyle),
                                                        ),

                                                      ],
                                                    ),


                                                    const SizedBox(height: 2),

                                                    // 🟩 Input Row
                                                    Row(
                                                      crossAxisAlignment: CrossAxisAlignment.end, // ✅ makes underline bottoms line up
                                                      children: [
                                                        // Weight
                                                        SizedBox(
                                                          width: 76,
                                                          child: (j == 0)
                                                              ? GestureDetector(
                                                            onDoubleTap: () {
                                                              if (!_isInitialized) return;
                                                              if (_weightControllers[i][j].text.isNotEmpty) return;

                                                              final w = set1SuggestedWeight(i);
                                                              final wHint = formatWeight(w);

                                                              if (wHint.isEmpty) return;

                                                              setState(() {
                                                                _weightControllers[i][j].text = wHint;
                                                                _weightControllers[i][j].selection = TextSelection.fromPosition(
                                                                  TextPosition(offset: wHint.length),
                                                                );
                                                              });
                                                            },
                                                            child: Focus(
                                                              onFocusChange: (hasFocus) {
                                                                if (!hasFocus) {
                                                                  _saveSingleRowToFirestore(rowIndex: i, setIndex: j);
                                                                }
                                                              },
                                                              child: TextField(
                                                                controller: _weightControllers[i][j],
                                                                keyboardType: const TextInputType.numberWithOptions(decimal: true),

                                                                decoration: InputDecoration(
                                                                  hintText: !_isInitialized
                                                                      ? ''
                                                                      : (() {
                                                                    final w = set1SuggestedWeight(i);
                                                                    return formatWeight(w);
                                                                  })(),
                                                                  hintStyle: const TextStyle(
                                                                    color: Colors.grey,
                                                                    fontStyle: FontStyle.italic,
                                                                    fontSize: 12,
                                                                  ),
                                                                  contentPadding: const EdgeInsets.only(left: 2),
                                                                  enabledBorder: const UnderlineInputBorder(
                                                                    borderSide: BorderSide(color: Colors.white, width: 1),
                                                                  ),
                                                                  focusedBorder: const UnderlineInputBorder(
                                                                    borderSide: BorderSide(color: Colors.white, width: 1.5),
                                                                  ),
                                                                  disabledBorder: const UnderlineInputBorder(
                                                                    borderSide: BorderSide(color: Colors.white, width: 1),
                                                                  ),
                                                                ),
                                                                onChanged: (value) {
                                                                  _e1rmTargetCache.clear();
                                                                  _synthHintCache.clear();
                                                                  rebuildCard(() {});
                                                                },
                                                                style: TextStyle(
                                                                  color: _weightControllers[i][j].text.isEmpty
                                                                      ? Colors.grey
                                                                      : Colors.white,
                                                                  fontSize: 12,
                                                                ),
                                                              ),
                                                            ),

                                                          )
                                                              : FutureBuilder<String>(

                                                          future: _weightHintText(
                                                                i, j),
                                                            builder: (_, snap) {
                                                              final hasTyped = _weightControllers[i][j]
                                                                  .text
                                                                  .isNotEmpty;
                                                              final showHint = !hasTyped &&
                                                                  _isInitialized &&
                                                                  !_isLoadingData;
                                                              final hint = showHint
                                                                  ? (snap
                                                                  .data ?? '')
                                                                  : '';

                                                              return GestureDetector(
                                                                onDoubleTap: () {
                                                                  if (_weightControllers[i][j].text.isNotEmpty) return;
                                                                  if (hint.isEmpty) return;

                                                                  setState(() {
                                                                    _weightControllers[i][j].text = hint;
                                                                    _weightControllers[i][j].selection = TextSelection.fromPosition(
                                                                      TextPosition(offset: hint.length),
                                                                    );
                                                                  });
                                                                },
                                                                child: Focus(
                                                                  onFocusChange: (hasFocus) {
                                                                    if (!hasFocus) {
                                                                      _saveSingleRowToFirestore(rowIndex: i, setIndex: j);
                                                                    }
                                                                  },
                                                                  child: TextField(
                                                                    controller: _weightControllers[i][j],
                                                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),

                                                                    decoration: InputDecoration(
                                                                      hintText: hint, // range like "50–52.5"
                                                                      hintStyle: const TextStyle(
                                                                        color: Colors.grey,
                                                                        fontStyle: FontStyle.italic,
                                                                        fontSize: 12,
                                                                      ),
                                                                      contentPadding: const EdgeInsets.only(left: 2),
                                                                      enabledBorder: const UnderlineInputBorder(
                                                                        borderSide: BorderSide(color: Colors.white, width: 1),
                                                                      ),
                                                                      focusedBorder: const UnderlineInputBorder(
                                                                        borderSide: BorderSide(color: Colors.white, width: 1.5),
                                                                      ),
                                                                      disabledBorder: const UnderlineInputBorder(
                                                                        borderSide: BorderSide(color: Colors.white, width: 1),
                                                                      ),
                                                                    ),
                                                                    onChanged: (value) {
                                                                      _e1rmTargetCache.clear();
                                                                      _synthHintCache.clear();
                                                                      rebuildCard(() {});
                                                                    },
                                                                    style: TextStyle(
                                                                      color: _weightControllers[i][j].text.isNotEmpty
                                                                          ? Colors.white
                                                                          : Colors.grey,
                                                                      fontSize: 12,
                                                                    ),
                                                                  ),
                                                                ),
                                                              );


                                                            },
                                                          ),
                                                        ),


                                                        const SizedBox(
                                                            width: 4),

                                                        // Reps
                                                        SizedBox(
                                                          width: 50,
                                                          child: (j == 0)
                                                              ? GestureDetector(
                                                            onDoubleTap: () {
                                                              if (_isLoadingData || !_isInitialized) return;
                                                              if (_repsControllers[i][j].text.isNotEmpty) return;

                                                              final r = set1SuggestedReps(i);
                                                              final rHint = (r?.toInt().toString() ?? '');

                                                              if (rHint.isEmpty) return;

                                                              setState(() {
                                                                _repsControllers[i][j].text = rHint;
                                                                _repsControllers[i][j].selection = TextSelection.fromPosition(
                                                                  TextPosition(offset: rHint.length),
                                                                );
                                                              });
                                                            },
                                                            child: Focus(
                                                              onFocusChange: (hasFocus) {
                                                                if (!hasFocus) {
                                                                  _saveSingleRowToFirestore(rowIndex: i, setIndex: j);
                                                                }
                                                              },
                                                              child: TextField(
                                                                controller: _repsControllers[i][j],
                                                                keyboardType: TextInputType.number,
                                                                decoration: InputDecoration(
                                                                  contentPadding: const EdgeInsets.only(left: 2),
                                                                  hintText: (_isLoadingData || !_isInitialized)
                                                                      ? ''
                                                                      : (() {
                                                                    final r = set1SuggestedReps(i);
                                                                    return (r?.toInt().toString() ?? '');
                                                                  })(),
                                                                  hintStyle: const TextStyle(
                                                                    color: Colors.grey,
                                                                    fontStyle: FontStyle.italic,
                                                                    fontSize: 12,
                                                                  ),
                                                                  enabledBorder: const UnderlineInputBorder(
                                                                    borderSide: BorderSide(color: Colors.white, width: 1),
                                                                  ),
                                                                  focusedBorder: const UnderlineInputBorder(
                                                                    borderSide: BorderSide(color: Colors.white, width: 1.5),
                                                                  ),
                                                                  disabledBorder: const UnderlineInputBorder(
                                                                    borderSide: BorderSide(color: Colors.white, width: 1),
                                                                  ),
                                                                ),
                                                                onChanged: (value) {
                                                                  _e1rmTargetCache.clear();
                                                                  _synthHintCache.clear();
                                                                  rebuildCard(() {});
                                                                },
                                                                style: TextStyle(
                                                                  color: _repsControllers[i][j].text.isNotEmpty
                                                                      ? Colors.white
                                                                      : Colors.grey,
                                                                  fontSize: 12,
                                                                ),
                                                              ),
                                                            ),

                                                          )
                                                              : FutureBuilder<String>(

                                                          future: _repsHintText(
                                                                i, j),
                                                            builder: (_, snap) {
                                                              final hasTyped = _repsControllers[i][j]
                                                                  .text
                                                                  .isNotEmpty;
                                                              final showHint = !hasTyped &&
                                                                  _isInitialized &&
                                                                  !_isLoadingData;
                                                              final hint = showHint
                                                                  ? (snap
                                                                  .data ?? '')
                                                                  : '';

                                                              return GestureDetector(
                                                                onDoubleTap: () {
                                                                  if (_repsControllers[i][j].text.isNotEmpty) return;
                                                                  if (hint.isEmpty) return;

                                                                  setState(() {
                                                                    _repsControllers[i][j].text = hint;
                                                                    _repsControllers[i][j].selection = TextSelection.fromPosition(
                                                                      TextPosition(offset: hint.length),
                                                                    );
                                                                  });
                                                                },
                                                                child: Focus(
                                                                  onFocusChange: (hasFocus) {
                                                                    if (!hasFocus) {
                                                                      _saveSingleRowToFirestore(rowIndex: i, setIndex: j);
                                                                    }
                                                                  },
                                                                  child: TextField(
                                                                    controller: _repsControllers[i][j],
                                                                    keyboardType: TextInputType.number,
                                                                    decoration: InputDecoration(
                                                                      contentPadding: const EdgeInsets.only(left: 2),
                                                                      hintText: hint, // "4–6"
                                                                      hintStyle: const TextStyle(
                                                                        color: Colors.grey,
                                                                        fontStyle: FontStyle.italic,
                                                                        fontSize: 12,
                                                                      ),
                                                                      enabledBorder: const UnderlineInputBorder(
                                                                        borderSide: BorderSide(color: Colors.white, width: 1),
                                                                      ),
                                                                      focusedBorder: const UnderlineInputBorder(
                                                                        borderSide: BorderSide(color: Colors.white, width: 1.5),
                                                                      ),
                                                                      disabledBorder: const UnderlineInputBorder(
                                                                        borderSide: BorderSide(color: Colors.white, width: 1),
                                                                      ),
                                                                    ),
                                                                    onChanged: (value) {
                                                                      _e1rmTargetCache.clear();
                                                                      _synthHintCache.clear();
                                                                      rebuildCard(() {});
                                                                    },
                                                                    style: TextStyle(
                                                                      color: _repsControllers[i][j].text.isNotEmpty
                                                                          ? Colors.white
                                                                          : Colors.grey,
                                                                      fontSize: 12,
                                                                    ),
                                                                  ),
                                                                ),

                                                              );

                                                            },
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                            width: 4),


                                                        // RIR
                                                        SizedBox(
                                                          width: 50,
                                                          child: GestureDetector(
                                                            onDoubleTap: () {
                                                              if (_rirControllers[i][j].text.isNotEmpty) return;

                                                              // Claude_bullet override for RIR double-tap
                                                              if (_claudeBulletActiveForThisDay) {
                                                                final ik = _rowKeyBy(i);
                                                                final ov = _claudeBulletRirHintOverrides[ik]?[j];
                                                                if (ov != null && ov.isNotEmpty) {
                                                                  setState(() {
                                                                    _rirControllers[i][j].text = ov;
                                                                    _rirControllers[i][j].selection = TextSelection.fromPosition(
                                                                      TextPosition(offset: ov.length),
                                                                    );
                                                                  });
                                                                  return;
                                                                }
                                                              }

                                                              final exNameKey = _rowKeyBy(i);

                                                              String rawRirHint;

                                                              if (j == 0) {
                                                                rawRirHint = (
                                                                    _seedHintsByKey[exNameKey]?['rir']
                                                                        ?? set1RIR(i)
                                                                ).toString();
                                                              } else if (j >= 1 && j <= 7) {
                                                                rawRirHint = (
                                                                    _seedHintsByKey[exNameKey]?['s${j + 1}_rir']
                                                                        ?? (j == 1
                                                                        ? set2RIR(i)
                                                                        : j == 2
                                                                        ? set3RIR(i)
                                                                        : 1)
                                                                ).toString();
                                                              } else {
                                                                rawRirHint = '1';
                                                              }

                                                              final rirHint = formatRir(rawRirHint);

                                                              if (rirHint.isEmpty) return;

                                                              setState(() {
                                                                _rirControllers[i][j].text = rirHint;
                                                                _rirControllers[i][j].selection = TextSelection.fromPosition(
                                                                  TextPosition(offset: rirHint.length),
                                                                );
                                                              });
                                                            },
                                                            child: Focus(
                                                              onFocusChange: (hasFocus) {
                                                                if (!hasFocus) {
                                                                  _saveSingleRowToFirestore(rowIndex: i, setIndex: j);
                                                                }
                                                              },
                                                              child: TextField(
                                                                controller: _rirControllers[i][j],
                                                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                                                decoration: InputDecoration(
                                                                  contentPadding: const EdgeInsets.only(left: 2),
                                                                  hintText: (() {
                                                                    // Claude_bullet override: use cached RIR hint
                                                                    if (_claudeBulletActiveForThisDay) {
                                                                      final ik = _rowKeyBy(i);
                                                                      final ov = _claudeBulletRirHintOverrides[ik]?[j];
                                                                      if (ov != null) return ov;
                                                                    }
                                                                    return (j == 0)
                                                                        ? formatRir(
                                                                        _seedHintsByKey[
                                                                        _rowKeyBy(i)]?['rir']
                                                                            ?? set1RIR(i)
                                                                    )
                                                                        : (j >= 1 && j <= 7)
                                                                        ? formatRir(
                                                                        _seedHintsByKey[
                                                                        _rowKeyBy(i)]?['s${j + 1}_rir']
                                                                            ?? (j == 1
                                                                            ? set2RIR(i)
                                                                            : j == 2
                                                                            ? set3RIR(i)
                                                                            : 1)
                                                                    )
                                                                        : '1';
                                                                  })(),
                                                                  hintStyle: const TextStyle(
                                                                    color: Colors.grey,
                                                                    fontStyle: FontStyle.italic,
                                                                    fontSize: 12,
                                                                  ),
                                                                ),
                                                                onChanged: (value) {
                                                                  _e1rmTargetCache.clear();
                                                                  _synthHintCache.clear();
                                                                  rebuildCard(() {});
                                                                },
                                                                style: TextStyle(
                                                                  color: _rirControllers[i][j].text.isEmpty
                                                                      ? Colors.grey
                                                                      : Colors.white,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),



                                                        const SizedBox(
                                                            width: 4),


                                                        // E1RM — display-only; Container+Text avoids per-build controller allocation
                                                        SizedBox(
                                                          width: 55,
                                                          height: 36, // ✅ fixed height to match TextField-ish height across devices
                                                          child: Align(
                                                            alignment: Alignment.bottomLeft,
                                                            child: Container(
                                                              height: 36, // ✅ ensure border sits at the same y-position everywhere
                                                              padding: const EdgeInsets.only(left: 2, bottom: 6), // ✅ tune baseline without font-metric drift
                                                              decoration: const BoxDecoration(
                                                                border: Border(
                                                                  bottom: BorderSide(color: Colors.white, width: 1),
                                                                ),
                                                              ),
                                                              alignment: Alignment.bottomLeft,
                                                              child: Text(
                                                                e1rmDisplayForCell(i, j).toStringAsFixed(1),
                                                                strutStyle: const StrutStyle(
                                                                  fontSize: 12,
                                                                  height: 2.5,
                                                                  forceStrutHeight: true, // ✅ locks vertical metrics across devices
                                                                ),
                                                                style: TextStyle(
                                                                  fontSize: 12,
                                                                  height: 1.0, // ✅ don’t use 3.5 (that’s the main drift culprit)
                                                                  color: (_weightControllers[i][j].text.isNotEmpty ||
                                                                      _repsControllers[i][j].text.isNotEmpty ||
                                                                      _rirControllers[i][j].text.isNotEmpty)
                                                                      ? Colors.white
                                                                      : Colors.grey,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                            width: 4),

                                                        // ✅ Conditionally show Velocity
                                                        if (_showVelocityByExercise[
                                                        '${(_selectedExercisesWithCircuits[i]['name'] as String).toLowerCase()}|${_selectedExercisesWithCircuits[i]['circuitIndex']}'
                                                        ] == true ||
                                                            _showVelocityByExercise[
                                                            (_selectedExercisesWithCircuits[i]['name'] as String).toLowerCase()
                                                            ] == true) ...[
                                                          SizedBox(
                                                            width: 45,
                                                            child: TextField(
                                                              controller: _velocityControllers[i][j],
                                                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                                              decoration: const InputDecoration(
                                                                hintText: '',
                                                                hintStyle: TextStyle(
                                                                  color: Colors.grey,
                                                                  fontStyle: FontStyle.italic,
                                                                  fontSize: 11,
                                                                ),
                                                              ),
                                                              onChanged: (value) {
                                                                _e1rmTargetCache.clear();
                                                                _synthHintCache.clear();
                                                                rebuildCard(() {});
                                                              },
                                                              style: TextStyle(
                                                                color: _velocityControllers[i][j].text.isEmpty
                                                                    ? Colors.grey
                                                                    : Colors.white,
                                                              ),
                                                            ),
                                                          ),
                                                          const SizedBox(width: 4),
                                                        ],

// Notes
                                                        SizedBox(

                                                        width: 120,
                                                          child: TextField(
                                                            controller: _notesControllers[i][j],
                                                            keyboardType: TextInputType
                                                                .text,
                                                            decoration: const InputDecoration(
                                                              hintText: '',
                                                              hintStyle: TextStyle(
                                                                color: Colors
                                                                    .grey,
                                                                fontStyle: FontStyle
                                                                    .italic,
                                                                fontSize: 12,
                                                              ),
                                                            ),
                                                            onChanged: (value) {
                                                              _e1rmTargetCache.clear();
                                                              _synthHintCache.clear();
                                                              rebuildCard(() {});
                                                            },
                                                            style: TextStyle(
                                                              color: _notesControllers[i][j]
                                                                  .text.isEmpty
                                                                  ? Colors.grey
                                                                  : Colors
                                                                  .white,
                                                              fontSize: 12,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    )
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 4),
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment
                                              .end, // 👈 pack to the right
                                          children: [
                                            if (!isSaved &&
                                                _hasTypedWeightAndRepsInAnySet(
                                                    i)) ...[
                                              OutlinedButton.icon(
                                                style: OutlinedButton.styleFrom(
                                                  side: const BorderSide(
                                                      color: Colors.white24),
                                                  padding: const EdgeInsets
                                                      .symmetric(horizontal: 6,
                                                      vertical: 6),
                                                  visualDensity: VisualDensity
                                                      .compact,
                                                ),
                                                onPressed: () =>
                                                    _markExerciseSaved(i),
                                                icon: const Icon(
                                                    Icons.check_circle_outline,
                                                    size: 14),
                                                label: const Text('Completed?',
                                                    style: TextStyle(
                                                        fontSize: 12)),
                                              ),
                                              const SizedBox(width: 8),
                                              // 👈 small gap between Done? and +
                                            ],
                                            IconButton(
                                              icon: const Icon(Icons.add),
                                              onPressed: () => addSet(i),
                                            ),
                                          ],
                                        ),
                                      ),

                                            ], // Column children (StatefulBuilder)
                                          ); // Column (StatefulBuilder)
                                        }, // StatefulBuilder builder
                                      ), // StatefulBuilder

                                    ], //paste point
                                  ),
                                );
                              }), //old bracket for Card
                        )
                      ],
                    );
                  }),
                ),

              Padding(
                padding: const EdgeInsets.only(top: 12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // 👇 show catch-up only when no circuits AND there are missed items
                    if (_selectedExercisesWithCircuits.isEmpty &&
                        _hasMissedForToday) ...[
                      _buildCatchUpButton(),
                      const SizedBox(width: 12), // space between buttons
                    ],

                    ElevatedButton.icon(
                      onPressed: _addNewCircuitExercise,
                      icon: const Icon(Icons.add),
                      label: const Text("Add Circuit"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 55), // after the last exercise card
            ],
          ), // Column
        ), // SingleChildScrollView
      ),
    ),
        ),
          // Sparkle overlay (on top of everything; ignores touch)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: true, // overlay should never block taps
              child: AnimatedOpacity(
                opacity: _showSparkles ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: Center(
                  // Feel free to tweak sizing; this fills safely on phones & tablets
                  child: SizedBox(
                    width: MediaQuery.of(context).size.width * 0.9,
                    height: MediaQuery.of(context).size.height * 0.9,
                    child: Lottie.asset(
                      'assets/lottie/sparkle_stars.json',
                      controller: _sparkleCtrl,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
          ),

        ],// Scaffold
    ); //this the will pop // WillPopScope
  }
}


class ExerciseVideoButton extends StatelessWidget {
  final String exerciseId;
  final double size;

  const ExerciseVideoButton({
    Key? key,
    required this.exerciseId,
    this.size = 22,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final assetPath = kExerciseVideoAssets[exerciseId];

    // If we don't have a clip for this exercise, hide the icon.
    if (assetPath == null) {
      return const SizedBox.shrink();
    }

    return IconButton(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      icon: Icon(
        Icons.play_circle_fill,
        size: size,
        color: Colors.green,
      ),
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ExerciseVideoPlayerScreen(
              assetPath: assetPath,
              exerciseName: exerciseId,   // ← THIS is valid and always available
            ),
          ),
        );
      },
    );

  }
}
