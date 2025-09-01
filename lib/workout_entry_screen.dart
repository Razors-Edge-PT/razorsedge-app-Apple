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

class _WorkoutPageState extends State<WorkoutPage> with WidgetsBindingObserver {
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
  Map<String, bool> _showVelocityByExercise = {}; // exerciseName.toLowerCase() → true/false

  String get userId => UserContext.of(context, listen: false).currentUid;
  String? _lastMergedUid;
  late final String _cachedUid;
  DateTime? _lastMergedDate;



  final int _defaultSets = 3;
  VoidCallback? _lastUndoAction;
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
  final Map<int, Map<String, dynamic>> _cachedProgressedValues = {};

  bool _isLoadingData = true;
  bool _isInitialized = false;


  late Future<void> _initialLoad;
  late Future<void> _blockDateLoad;

  //autosave bits
  // ---- NEW: State fields ----
  bool _pendingChanges = false;
  bool _lifecycleSaveInFlight = false; // prevents overlapping lifecycle saves
  String? _lastSavedHash; // to skip redundant writes on exit
  final Set<String> _savedExerciseKeysForDate = {}; // local UI "saved format"

// Deterministic doc id for this date
  String _workoutDocIdForDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

// Stable exercise key (name + circuitIndex)
  String _exerciseKey(String name, int circuitIndex) => '${name.trim()}__$circuitIndex';

// Has any non-zero data in sets?
  bool _hasAnyDataForExercise(int exerciseIndex) {
    if (exerciseIndex < 0 || exerciseIndex >= _workoutSets.length) return false;
    for (final s in _workoutSets[exerciseIndex]) {
      final reps = s.reps ?? 0;
      final w = s.weight ?? 0.0;
      final rir = s.rir ?? 0.0;
      final vel = s.velocity ?? 0.0;
      final notes = s.notes?.trim() ?? '';
      if (reps > 0 || w > 0 || rir > 0 || vel > 0 || notes.isNotEmpty) return true;
    }
    return false;
  }

  final Set<TextEditingController> _attachedDirty = {}; // guards against double-attach
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

  bool _hasSetWithWeightAndReps(int exerciseIndex) {
    if (exerciseIndex < 0 || exerciseIndex >= _workoutSets.length) return false;
    for (final s in _workoutSets[exerciseIndex]) {
      final reps = (s.reps ?? 0);
      final w = (s.weight ?? 0.0);
      if (reps > 0 && w > 0) return true;
    }
    return false;
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


  //autosave bits finish

  //UI bits
  late ScrollController _horizontalScrollController;

  //Timing Bits
  final _wesInitTimer = Stopwatch()..start();


  Future<void> loadPreviousWorkoutData() async {
    final sw = Stopwatch()..start(); // ⏱️ start
    await PeriodizationModelUtils.fetchLastWorkoutTopSetRepsCacheFirst(
      uid: UserContext.of(context, listen: false).currentUid,
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
    final totalSw = Stopwatch()..start();
    try {
      // ✅ Same uid source you use elsewhere (impersonation-safe, no Provider listen)
      final uid = userId;
      final blockId = _selectedBlockId; // ✅ match _loadPlannedExerciseDetails()

      if (uid.isEmpty || blockId == null || blockId.isEmpty) {
        print('⚠️ [WES] loadPlannedExercisesFromFirestore missing uid/blockId (uid=$uid, blockId=$blockId)');
        return;
      }

      final ref = FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks')
          .doc(blockId);

      print('[WES] loadPlannedExercisesFromFirestore → planned_blocks/$uid/blocks/$blockId');

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
      final cacheSw = Stopwatch()..start();
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
        print('📦 [WES] plannedExercises (cache) items=${cached.length} in ${cacheSw.elapsedMilliseconds}ms');

        // 2) Background reconcile
        unawaited(() async {
          try {
            final srvSw = Stopwatch()..start();
            final srvSnap = await ref.get(); // server
            srvSw.stop();
            final fresh = parseDoc(srvSnap);
            if (mounted && !listEq(plannedExercises, fresh)) {
              setState(() => plannedExercises = fresh);
              print('🔁 [WES] reconciled from server (items=${fresh.length}, ${srvSw.elapsedMilliseconds}ms)');
            }
          } catch (e) {
            print('ℹ️ [WES] plannedExercises reconcile failed: $e');
          }
        }());

      } else {
        // 3) Guaranteed SERVER fallback (awaited) for cold start
        final srvSw = Stopwatch()..start();
        final srvSnap = await ref.get();
        srvSw.stop();

        if (!srvSnap.exists) {
          print('⚠️ [WES] Block doc missing at planned_blocks/$uid/blocks/$blockId');
          if (mounted && (plannedExercises == null || plannedExercises.isNotEmpty)) {
            setState(() => plannedExercises = const <String>[]);
          }
        } else {
          final fresh = parseDoc(srvSnap);
          if (mounted && !listEq(plannedExercises, fresh)) {
            setState(() => plannedExercises = fresh);
          }
          print('🌐 [WES] plannedExercises (server) items=${fresh.length} in ${srvSw.elapsedMilliseconds}ms');
        }
      }
    } catch (e, st) {
      print('❌ [WES] loadPlannedExercisesFromFirestore error: $e');
      print(st);
    } finally {
      totalSw.stop();
      print('⏱️ [WES] loadPlannedExercisesFromFirestore total took ${totalSw.elapsedMilliseconds}ms');
    }
  }

  // ✅ Custom Hybrid E1RM Formula: Brzycki for ≤6 reps, Epley for >6 reps
  double calculateE1RM(double? weight, double? reps, double? rir) {
    double w = weight ?? 0.0;
    double r = reps ?? 0.0;
    double rValue = rir ?? 0.0;
    double totalReps = r + rValue; // ✅ No clamping, keeps raw calculation

    if (totalReps <= 6) {
      // ✅ Brzycki for low reps (≤6)
      return w * (36 / (37 - totalReps));
    } else {
      // ✅ Epley for higher reps (>6)
      return w * (1 + (0.0333 * totalReps));
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

  double getAverageE1RM(
      String exerciseName, {
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
    final base = DateTime(blockStartDate!.year, blockStartDate!.month, blockStartDate!.day);
    final sel  = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    final weekIndex = ((sel.difference(base).inDays) ~/ 7).clamp(0, 11);

    final sessionIndex = PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
      exerciseName: name,
      savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
      blockStartDate: blockStartDate!,
      weekIndex: weekIndex,
      selectedDate: _selectedDate,
    );

    final rirPlan = PeriodizationModelUtils.plannedExerciseDetails[exerciseId]?['rirPlan'];
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
    const names = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return names[(dayIndex.clamp(0, 6))];
  }

// Build a name->id map from exerciseSettings if possible.
// Falls back gracefully when no mapping exists.
  Map<String, String> _buildNameToIdLookup() {
    // You already populate `_exerciseSettings` keys = exerciseId.
    // We try common "name" fields inside each settings map.
    final out = <String,String>{};
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
    if (id != null && id.trim().isNotEmpty) return 'id#$id';
    return 'name#$nk';
  }

  Future<List<_MissedItem>> _computeMissedExercisesForWeek() async {
    if (_selectedBlockId == null || _selectedDate == null || blockStartDate == null) return const [];
    final uid = UserContext.of(context, listen: false).currentUid;
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
    final dayDocsServer = await daysCol.get(const GetOptions(source: Source.server))
        .catchError((_) => null);
    final dayDocs = dayDocsServer ??
        await daysCol.get(const GetOptions(source: Source.cache));

    // Build: planned per dayIndex
    final plannedByDay = <int, List<Map<String, dynamic>>>{};
    for (final d in dayDocs.docs) {
      final di = int.tryParse(d.id.replaceFirst('day_', '')) ?? 0;
      plannedByDay[di] = List<Map<String, dynamic>>.from(d.data()['exercises'] ?? const []);
    }
    for (int i = 0; i < 7; i++) {
      plannedByDay.putIfAbsent(i, () => <Map<String, dynamic>>[]);
    }

    // 2) Load completed workouts for all 7 days of this week (doc-id + legacy auto-ID)
    final weekStart = DateTime(blockStartDate!.year, blockStartDate!.month, blockStartDate!.day)
        .add(Duration(days: weekIndex * 7));
    final workoutsCol = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts');

    String isoDay(DateTime d) => '${DateTime(d.year, d.month, d.day).toIso8601String().split(".").first}.000';

    final weekServer = await workoutsCol
        .where('date', isGreaterThanOrEqualTo: isoDay(weekStart))
        .where('date', isLessThan: isoDay(weekStart.add(const Duration(days: 7))))
        .get(const GetOptions(source: Source.server))
        .catchError((_) => null);

    final weekCache = weekServer ??
        await workoutsCol
            .where('date', isGreaterThanOrEqualTo: isoDay(weekStart))
            .where('date', isLessThan: isoDay(weekStart.add(const Duration(days: 7))))
            .get(const GetOptions(source: Source.cache));

    final legacyByDate = <String, List<Map<String, dynamic>>>{};
    for (final doc in weekCache.docs) {
      final raw = doc.data()['date'];
      final dt = (raw is Timestamp) ? raw.toDate() : DateTime.tryParse(raw?.toString() ?? '');
      if (dt == null) continue;
      final key = _ymd(dt);
      (legacyByDate[key] ??= []).addAll(List<Map<String, dynamic>>.from(doc.data()['exercises'] ?? const []));
    }

    // Also try doc-id per day (server preferred)
    final completedByDay = <int, List<Map<String, dynamic>>>{};
    for (int d = 0; d < 7; d++) {
      final date = weekStart.add(Duration(days: d));
      final key = _ymd(date);
      final docServer = await workoutsCol.doc(key).get(const GetOptions(source: Source.server))
          .catchError((_) => null);
      final docCache  = (docServer?.exists == true ? docServer : await workoutsCol.doc(key).get(const GetOptions(source: Source.cache)));

      final merged = <Map<String, dynamic>>[];
      if (docCache?.exists == true) {
        merged.addAll(List<Map<String, dynamic>>.from(docCache!.data()?['exercises'] ?? const []));
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

  Future<void> _maybePromptForMissedExercises() async {
    if (_selectedDate == null) return;
    final key = _ymd(_selectedDate!);
    if (_missedDialogShownForDateKeys.contains(key)) return;

    final items = await _computeMissedExercisesForWeek();
    if (items.isEmpty) {
      _missedDialogShownForDateKeys.add(key);
      return;
    }

    _missedDialogShownForDateKeys.add(key);

    final selections = List<bool>.filled(items.length, false); // default unchecked

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
            final chipColor = isDark ? const Color(0xFF1E1E1E) : cs.surfaceVariant;
            final chipSelectedElevation = 4.0;

            return AlertDialog
              (
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
                      child: Icon(Icons.close, color: isDark ? Colors.white70 : Colors.black54),
                    ),
                  ),
                ],
              ),

              content: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420, minWidth: 320),
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
                                spreadRadius: 0,
                                offset: const Offset(0, 4),
                                color: (cs.primary.withOpacity(0.25)),
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
                              onChanged: (v) => setLocal(() => selections[i] = v ?? false),
                              checkboxShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              activeColor: cs.primary,
                              title: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Text(
                                  '${items[i].name} Missed on ${_weekdayShortLabel(items[i].sourceDayIndex)}',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: selections[i] ? FontWeight.w700 : FontWeight.w500,
                                    color: isDark
                                        ? (selections[i] ? Colors.white : Colors.white70)
                                        : (selections[i] ? Colors.black : Colors.black87),
                                  ),
                                ),
                              ),
                              // subtle visual lift on select
                              tileColor: selections[i] ? chipColor.withOpacity(0.92) : chipColor,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              actions: [
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: isDark ? Colors.white70 : cs.onSurfaceVariant,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    textStyle: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  onPressed: () async {
                    final chosen = <_MissedItem>[];
                    for (int i = 0; i < items.length; i++) {
                      if (selections[i]) chosen.add(items[i]);
                    }
                    if (chosen.isNotEmpty) {
                      await _applyMissedExercisesToToday(chosen);
                    }
                    if (mounted) Navigator.of(ctx).pop();
                  },
                  child: const Text('Add selected'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: cs.primary,
                    foregroundColor: cs.onPrimary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    textStyle: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                    elevation: 3,
                    shadowColor: cs.primary.withOpacity(0.4),
                  ),
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

  void _scheduleMissedDialogAfterPaint() {
    if (_selectedDate == null) return;
    final dateKey = _ymd(_selectedDate!);
    if (_missedDialogShownForDateKeys.contains(dateKey)) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.microtask(() async {
        if (!mounted) return;
        await _maybePromptForMissedExercises(); // 👈 call the same function
      });
    });
  }


  Future<void> _applyMissedExercisesToToday(List<_MissedItem> chosen) async {
    if (_selectedBlockId == null || _selectedDate == null || blockStartDate == null) return;
    final uid = UserContext.of(context, listen: false).currentUid;
    if ((uid ?? '').isEmpty) return;

    final daysSinceStart = _selectedDate!.difference(blockStartDate!).inDays;
    final weekIndex = (daysSinceStart / 7).floor();
    final dayIndex  = daysSinceStart % 7;

    final blocksCol = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks');
    final weekDocRef = blocksCol.doc(_selectedBlockId!)
        .collection('weeks')
        .doc('week_$weekIndex');
    final todayRef = weekDocRef.collection('days').doc('day_$dayIndex');

    // 1) Read today's doc (server→cache), determine new circuit index
    final todaySnapServer = await todayRef.get(const GetOptions(source: Source.server)).catchError((_) => null);
    final todaySnap = (todaySnapServer?.exists == true ? todaySnapServer
        : await todayRef.get(const GetOptions(source: Source.cache)));

    final todayExercises = todaySnap?.data()?['exercises'];
    final List<Map<String, dynamic>> todayList =
    todayExercises != null ? List<Map<String, dynamic>>.from(todayExercises) : <Map<String, dynamic>>[];

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
      final srcSrv = await srcRef.get(const GetOptions(source: Source.server)).catchError((_) => null);
      final srcSnap = (srcSrv?.exists == true ? srcSrv
          : await srcRef.get(const GetOptions(source: Source.cache)));

      final List<Map<String, dynamic>> srcList =
      List<Map<String, dynamic>>.from(srcSnap?.data()?['exercises'] ?? const []);

      // Remove the specific rows (by (name,circuitIndex) matching FIRST occurrence)
      for (final m in entry.value) {
        final idx = srcList.indexWhere((e) =>
        (e['name'] ?? '').toString().trim().toLowerCase() == m.name.trim().toLowerCase() &&
            (e['circuitIndex'] ?? 0) == m.circuitIndex);
        if (idx >= 0) srcList.removeAt(idx);
      }

      batch.set(srcRef, {'exercises': srcList}, SetOptions(merge: true));
    }

    // Append moved rows to today with the NEW circuit index
    final appended = <Map<String, dynamic>>[];
    for (final m in chosen) {
      final row = Map<String, dynamic>.from(m.row);
      row['circuitIndex'] = newCircuitIndex; // force new circuit
      appended.add(row);
    }
    final newToday = <Map<String, dynamic>>[];
    newToday.addAll(todayList);
    newToday.addAll(appended);

    // circuitStartIndices: ensure new circuit header at the append start
    final savedStarts = List<int>.from(todaySnap?.data()?['circuitStartIndices'] ?? const [0]);
    final appendStartIndex = todayList.length; // first index of appended rows
    final newStarts = List<int>.from(savedStarts);
    if (!newStarts.contains(appendStartIndex)) newStarts.add(appendStartIndex);
    newStarts.sort();

    // workoutName/date (like saveDayToFirestore)
    final date = blockStartDate!.add(Duration(days: weekIndex * 7 + dayIndex));
    final workoutName = "${DateFormat('EEE d MMM').format(date)} - Week ${weekIndex + 1}";

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
        _selectedExercisesWithCircuits.add({
          'name': name,
          'circuitIndex': newCircuitIndex,
        });

        _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
        _repsControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
        _weightControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
        _rirControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
        _velocityControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
        _notesControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));

        // ----- NEW: seed only if non-zero / non-empty -----
        // ----- REPLACE the current seeding/hydration block with this -----

        final repsVal    = (m['reps'] as num?)?.toInt();
        final weightVal  = (m['weight'] as num?)?.toDouble();
        final rirVal     = (m['rir'] as num?)?.toDouble();
        final velVal     = (m['velocity']?.toString() ?? '').trim();
        final notesVal   = (m['notes']?.toString() ?? '').trim();

        final hasReps    = repsVal != null && repsVal != 0;
        final hasWeight  = weightVal != null && weightVal != 0.0;
        final hasRir     = rirVal != null && rirVal != 0.0;

        final key = name.toLowerCase();

// 1) Put non-zero BB2 values into hint storage ONLY
        if (hasReps || hasWeight || hasRir) {
          _resolvedBB2Values[key] = {
            if (hasReps)   'reps': repsVal,
            if (hasWeight) 'weight': weightVal,
            if (hasRir)    'rir': rirVal,
          };
        }

// 2) Do NOT hydrate sets or controllers with reps/weight/rir.
//    Leave them blank so they render as hint, not as user-entered.
//
//    If you still want to carry velocity/notes (not part of hint logic),
//    it's okay to set them only when non-empty:

        final idx = _selectedExercisesWithCircuits.length - 1;

        if (_velocityControllers.length > idx && _velocityControllers[idx].isNotEmpty) {
          if (velVal.isNotEmpty)   _velocityControllers[idx][0].text = velVal;
        }
        if (_notesControllers.length > idx && _notesControllers[idx].isNotEmpty) {
          if (notesVal.isNotEmpty) _notesControllers[idx][0].text = notesVal;
        }

// Also: do NOT set any _savedFields[...] flags here.
// -----------------------------------------------

        // ----- END NEW -----
      }
    });


    await _saveWorkoutDraftToCache();
    if (mounted) setState(() {});
  }



  //...Missing exercises block ends


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
    final uid = UserContext.of(context, listen: false).currentUid;
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
            final e1rms = entry.value.map((e) => e.toStringAsFixed(2)).join(', ');
            final reps = exercisePreviousTopSetReps[name]?.join(', ') ?? '—';
            print('🔍 Top sets for $name → E1RMs: [$e1rms], Reps: [$reps]');
        }}
      });
    }
  }

  String? getRepTargetForExerciseWES(String exerciseName, int rowIndex) {
    print('🚨 [WES] ENTERED getRepTargetForExerciseWES → $exerciseName, row $rowIndex');
    print('🗓️ [WES] _blockStartDate = $_blockStartDate');
    print('📅 [WES] _selectedDate = $_selectedDate');

    if (_blockStartDate == null || _selectedDate == null) {
      print('❌ [WES] Block start or selected date is null');
      return null;
    }

    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName];
    if (exerciseId == null) return null;

    final details = PeriodizationModelUtils.plannedExerciseDetails[exerciseId];
    if (details == null) return null;

    final repTargets = details['repTargets'];
    if (repTargets == null) return null;

    final model = PeriodizationModelUtils.exercisePeriodizationModels[exerciseId];
    final weekIndex = getWeekIndexFromDate(_selectedDate!, _blockStartDate!);

    print('🔍 [WES] Getting repTarget for $exerciseId → model: $model, weekIndex: $weekIndex');

    try {
      int? rep;

      switch (model) {
        case PeriodizationModelType.linearExposure:
          final exposureIndex = rowIndex;
          rep = PeriodizationModelUtils.getLinearExposureRepTarget(
            exerciseId: exerciseId,
            exposureIndex: exposureIndex,
            repTargetsByExercise: {exerciseId: {'repTargets': repTargets}},
            plannedExerciseDetails: PeriodizationModelUtils.plannedExerciseDetails,
          );
          break;

        case PeriodizationModelType.linearClassic:
          rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exerciseId,
            plannedIndex: rowIndex,
            weekIndex: weekIndex,
            repTargetsByExercise: {exerciseId: {'repTargets': repTargets}},
            plannedExerciseDetails: PeriodizationModelUtils.plannedExerciseDetails,
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
            plannedExerciseDetails: PeriodizationModelUtils.plannedExerciseDetails,
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
            plannedExerciseDetails: PeriodizationModelUtils.plannedExerciseDetails,
          );
          break;

        default:
          return null;
      }

      print('✅ [WES] Final rep target for $exerciseName (row $rowIndex) = $rep');
      return rep?.toString();
    } catch (e) {
      print('❌ [WES] Error in getRepTargetForExerciseWES: $e');
      return null;
    }
  }




  double bb2HintReps(int i) {
    final exerciseName = _selectedExercisesWithCircuits[i]['name']?.trim() ?? '';
    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;

    if (_blockStartDate == null || _selectedDate == null) {
      print('❌ [WES] 1_blockStartDate or _selectedDate is null — cannot compute weekIndex');
      return 10.0;
    }

    final weekIndex = getWeekIndexFromDate(_selectedDate!, _blockStartDate!);

    final repTarget = getRepTargetForExerciseWES(exerciseName, 0);


    if (repTarget == null || repTarget.trim().isEmpty) {
      print('❌ [WES] No rep target found for $exerciseName (week $weekIndex)');
      return 10.0;
    }

    final parsed = double.tryParse(repTarget.split('x').first.trim());
    print('🔢 [WES] BB2 hintReps for $exerciseName (week $weekIndex) = $parsed');
    return parsed ?? 10.0;
  }



  int getWeekIndexFromDate(DateTime selectedDate, DateTime blockStartDate) {
    return selectedDate.difference(blockStartDate).inDays ~/ 7;
  }




  void _debugPrintBlockDates() {
    print('🗓️ [DEBUG] _blockStartDate: $blockStartDate');
    print('🗓️ [DEBUG] _blockEndDate: $blockEndDate');
  }

  Future<void> debugPrintRepTargetsFromExerciseSettings(
      BuildContext context,
      String blockId,
      String exerciseId,
      ) async {
    final uid = UserContext.of(context, listen: false).actingAsUid;


    final docRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId);

    final docSnap = await docRef.get();
    if (!docSnap.exists) {
      print('🚫 [DEBUG] Block document not found for $blockId');
      return;
    }

    final data = docSnap.data();
    if (data == null || !data.containsKey('exerciseSettings')) {
      print('🚫 [DEBUG] No exerciseSettings field in block document.');
      print('🧾 [DEBUG] Full block doc:\n${jsonEncode(data)}');

      return;
    }

    final settings = data['exerciseSettings'][exerciseId];
    if (settings == null) {
      print('🚫 [DEBUG] No exerciseSettings found for $exerciseId');
      return;
    }

    final repTargets = settings['repTargets'];
    print('🔍 [DEBUG] repTargets from exerciseSettings for $exerciseId:\n${jsonEncode(repTargets)}');

    final week1 = repTargets?['week1'];
    if (week1 is! Map<String, dynamic>) {
      print('❌ [DEBUG] week1 not found in repTargets for $exerciseId');
      return;
    }

    final sorted = week1.entries
        .where((e) => e.key.startsWith('instance'))
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    for (final e in sorted) {
      print('✅ [DEBUG] $exerciseId → ${e.key}: ${e.value}');
    }
  }


  Map<String, dynamic> _getProgressedValues(int exerciseIndex) {

    // 🧠 STEP 1: If we already cached a GOOD value, return it
    final cached = _cachedProgressedValues[exerciseIndex];
    if (cached != null && blockStartDate != null && blockEndDate != null) {
      return cached;
    }

    _debugPrintBlockDates();
    // Get exercise info.
    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    final exerciseId =
        PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;

    final weekIndex = _getApplicableWeekIndex(exerciseId);
    print('📅 [WES] selectedDate = $_selectedDate');
    print('📅 [WES] blockStartDate = $blockStartDate');
    print('🧮 [WES] Computed weekIndex = ${blockStartDate != null ? PeriodizationModelUtils.getWeekIndexForDate(_selectedDate, blockStartDate!) : '⚠️ blockStartDate is null!'}');



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
    print('🔎 [WES] Progression model for $exerciseId (${exerciseName}): $model');

    if (model == PeriodizationModelType.dailyUndulatingExposure) {
      // (Assuming your existing model-specific logic is used here)
      final fullDetails = _exerciseSettings[exerciseId];
      final week1 = fullDetails?['repTargets']?['week1'];


      print('🔍 [WES] Checking DUP Exposure → exerciseId: $exerciseId, exerciseName: $exerciseName');
      print('📦 Full exerciseSettings[$exerciseId] = ${jsonEncode(fullDetails)}');
      print('📦 repTargets = ${jsonEncode(fullDetails?['repTargets'])}');
      print('📦 week1 = ${jsonEncode(week1)}');

      if (week1 is Map<String, dynamic>) {
        final sorted = week1.entries
            .where((e) => e.key.startsWith('instance'))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        if (sorted.isNotEmpty) {

          int completedBeforeTodayInBlock = 0;
          final matchedDates = <String>{};

          try {
            final base = DateTime(blockStartDate!.year, blockStartDate!.month, blockStartDate!.day);
            final todayStart = DateTime(_selectedDate!.year, _selectedDate!.month, _selectedDate!.day);

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
              final sets = (setsRaw is List) ? setsRaw.cast<Map>() : const <Map>[];
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
              if (dayOnly.isBefore(base) || !dayOnly.isBefore(todayStart)) continue; // [base, today)

              final exs = w['exercises'];
              if (exs is! List) continue;

              final matched = exs.any((ex) {
                if (!hasValidSet(ex['sets'])) return false;

                final exId = (ex['exerciseId'] ?? ex['id'] ?? ex['exercise_id'] ?? '').toString();
                if (exId.isNotEmpty && exId == targetId) return true;

                final exName = (ex['name'] ?? ex['exercise'] ?? ex['title'] ?? '').toString();
                if (exName.isNotEmpty && norm(exName) == targetNameNorm) return true;

                final mapped = (PeriodizationModelUtils.nameToId[exName] ?? '').toString();
                return mapped.isNotEmpty && mapped == targetId;
              });

              if (matched) {
                matchedDates.add(dateStr.length >= 10 ? dateStr.substring(0, 10) : dateStr);
              }
            }

            completedBeforeTodayInBlock = matchedDates.length;
          } catch (e) {
            print('⚠️ [WES DUP Exposure] completedBeforeTodayInBlock calc failed: $e');
          }

          // AFTER you finish building `matchedDates` (and before plannedIndex/index):
          final countedDebug = <Map<String, String>>[];

// Re-scan only the matched dates to grab a representative set per day
          for (final w in PeriodizationModelUtils.savedWorkoutsList) {
            final dateStr = (w['date'] ?? '').toString();
            final key = dateStr.length >= 10 ? dateStr.substring(0, 10) : dateStr;
            if (!matchedDates.contains(key)) continue;

            final exs = w['exercises'];
            if (exs is! List) continue;

            String? weightTxt, repsTxt, rirTxt;

            for (final ex in exs) {
              // ID-first match (fallback to name→id only if no id on row)
              final exId   = (ex['exerciseId'] ?? ex['id'] ?? ex['exercise_id'] ?? '').toString().trim();
              final exName = (ex['name'] ?? ex['exercise'] ?? ex['title'] ?? '').toString().trim();
              final idMatches = exId.isNotEmpty ? (exId == exerciseId) : false;
              final nameMatches = (exId.isEmpty)
                  ? ((PeriodizationModelUtils.nameToId[exName] ?? '').toString().trim() == exerciseId)
                  : false;
              if (!(idMatches || nameMatches)) continue;

              final sets = (ex['sets'] is List) ? List<Map<String, dynamic>>.from(ex['sets']) : const <Map<String, dynamic>>[];

              // Pick the first set that looks numeric
              for (final s in sets) {
                final wTxt = (s['actualWeight'] ?? s['weight'] ?? '').toString().trim();
                final rTxt = (s['actualReps']   ?? s['reps']   ?? '').toString().trim();
                final rir  = (s['actualRir']    ?? s['rir']    ?? '').toString().trim();

                final looksNumber = double.tryParse(wTxt) != null && int.tryParse(rTxt) != null;
                if (looksNumber) {
                  weightTxt = wTxt;
                  repsTxt   = rTxt;
                  rirTxt    = rir.isEmpty ? null : rir;
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

// Print the counted days with set details and cycle position
          for (int i = 0; i < countedDebug.length; i++) {
            final e = countedDebug[i];
            // cyclePos is 1-based within the week1 instances list size
            final cyclePos = sorted.isEmpty ? 'n/a' : ((i % sorted.length) + 1).toString();
            final cycleDen = sorted.isEmpty ? 'n/a' : sorted.length.toString();
            print('🧾 [WES DUP Exposure] prior #${i + 1} → ${e['date']} '
                '• ${e['weight']} kg × ${e['reps']} '
                '${e['rir'] != '—' ? '(RIR ${e['rir']}) ' : ''}'
                '→ cycle ${cyclePos}/${cycleDen}');
          }

// Now compute plannedIndex / index as before
          final plannedIndex = completedBeforeTodayInBlock + plannedCountBefore;
          final index = sorted.isEmpty ? 0 : plannedIndex % sorted.length;

          print('🧮 [WES DUP Exposure] completedBeforeTodayInBlock=$completedBeforeTodayInBlock '
              'plannedBefore=$plannedCountBefore → plannedIndex=$plannedIndex '
              '→ instance=${sorted.isEmpty ? 'n/a' : (index + 1)}/${sorted.length}');


          final raw = sorted.isNotEmpty ? (sorted[index].value?.toString() ?? '') : '';
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
          ..sort((a, b) => a.key.compareTo(b.key)); // keep your existing ordering

        if (sorted.isNotEmpty) {
          if (blockStartDate == null || _selectedDate == null) {
            repTarget = 10.0;
          } else {
            // ✅ Count only *actual* completions earlier this week (strictly before today)
            int completedEarlierThisWeek = 0;
            final matchedDates = <String>{};

            try {
              final base = DateTime(blockStartDate!.year, blockStartDate!.month, blockStartDate!.day);
              final wkIdx = weekIndex ?? 0;
              final weekStart = base.add(Duration(days: wkIdx * 7));
              final todayStart = DateTime(_selectedDate!.year, _selectedDate!.month, _selectedDate!.day);

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
                final sets = (setsRaw is List) ? setsRaw.cast<Map>() : const <Map>[];
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
                if (dayOnly.isBefore(weekStart) || !dayOnly.isBefore(todayStart)) continue; // strictly before today

                final exs = w['exercises'];
                if (exs is! List) continue;

                final matched = exs.any((ex) {
                  if (!hasValidSet(ex['sets'])) return false;

                  final exId = (ex['exerciseId'] ?? ex['id'] ?? ex['exercise_id'] ?? '').toString();
                  if (exId.isNotEmpty && exId == targetId) return true;

                  final exName = (ex['name'] ?? ex['exercise'] ?? ex['title'] ?? '').toString();
                  if (exName.isNotEmpty && norm(exName) == targetNameNorm) return true;

                  final mapped = (PeriodizationModelUtils.nameToId[exName] ?? '').toString();
                  return mapped.isNotEmpty && mapped == targetId;
                });

                if (matched) {
                  matchedDates.add(dateStr.length >= 10 ? dateStr.substring(0, 10) : dateStr);
                }
              }

              completedEarlierThisWeek = matchedDates.length;
            } catch (e) {
              print('⚠️ [WES DUP Week] completedEarlierThisWeek calc failed: $e');
            }

            // 🔑 WES rule: planned rows don't affect DUP Weekly indexing
            final plannedIndex = completedEarlierThisWeek;
            final index = plannedIndex % sorted.length;

            print('🧮 [WES DUP Week] completedEarlierThisWeek=$completedEarlierThisWeek '
                '→ plannedIndex=$plannedIndex → instance=${index + 1}/${sorted.length}');

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

      print('🎯 [WES] dailyUndulatingWeek → repTarget = $repTarget for $exerciseName (using week1 pattern)');



    } else if (model == PeriodizationModelType.linearClassic) {

      final repTargets = _exerciseSettings[exerciseId]?['repTargets'];

      print('🧠 [WES] LinearClassic → exerciseId = $exerciseId');
      print('📌 repTargets = $repTargets');
      print('📆 weekIndex = $weekIndex');

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
    // Get default weight using rep and RIR logic.
    // Get the progression model info.
    final String? progressionModelName = _exerciseSettings[exerciseId]?['progressionModel'];
    print('🔧 [WES] progressionModelName for $exerciseId = $progressionModelName');
    print('📦 [WES] Full _exerciseSettings for $exerciseId: ${jsonEncode(_exerciseSettings[exerciseId])}');

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

    print('🧷 [WES] increments (expanded) for $exerciseId → '
        '${increments.take(12).toList()} … total=${increments.length}');

    print('🧾 [WES→PMU] exId=$exerciseId exName=$exerciseName '
        'repTarget=${repTarget.toInt()} rir=$rir '
        'defaultWeight=${defaultWeight.toStringAsFixed(2)}');
    final maxWeightMap = _exerciseSettings[exerciseId]?['maxWeightByReps'];
    final maxWeightKeys = (maxWeightMap is Map) ? maxWeightMap.keys.toList() : 'null';

    print('🧾 [WES→PMU] increments=${(increments ?? []).join(", ")} '
        'maxWeightByRepsKeys=$maxWeightKeys');


    final Map<String, dynamic> progressed =
    PeriodizationModelUtils.getWeightByProgressionModel(
      model: progressionModel,
      exerciseName: exerciseName,
      repTarget: repTarget.toInt(),
      defaultWeight: defaultWeight,
      rirValue: rir,
      increments: increments ?? [2.5], // ✅ fallback
      maxWeightByReps: _exerciseSettings[exerciseId]?['maxWeightByReps'],

      topSetHistory: PeriodizationModelUtils.topSetsByExercise[exerciseName],
      weekIndex: PeriodizationModelUtils.getWeekIndexForDate(_selectedDate, blockStartDate!),

    );
    print('🧾 [WES <- PMU] pre-overlay ${progressed['weight']} × ${progressed['reps']}');

    final target = (progressed['weight'] as num).toDouble();
    final snapped = increments.reduce(
          (a, b) => (a - target).abs() < (b - target).abs() ? a : b,
    );


    print('🧾 [WES overlay] ${progressed['weight']} → $snapped');
    // Cache and return
    _cachedProgressedValues[exerciseIndex] = progressed;

    print('🧮 [WES] Progressed for ${exerciseName} = ${progressed['weight']} kg @ ${repTarget} reps, RIR $rir');

    return progressed;
  }

  //Determine hint texts for this workout:NEW METHOD

  double set1SuggestedReps(int exerciseIndex) {

    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    final rirText = _rirControllers[exerciseIndex][0].text;
    final weightText = _weightControllers[exerciseIndex][0].text;
    final repsText = _repsControllers[exerciseIndex][0].text;

    final normalizedKey = exerciseName.toLowerCase();
    final bb2Entry = _resolvedBB2Values[normalizedKey];

    final double? reps = double.tryParse(repsText);
    final double? weight = double.tryParse(weightText);
    final double rawRIR = double.tryParse(rirText) ?? set1RIR(exerciseIndex);
    final double? bb2Reps = bb2Entry?['reps']?.toDouble();
    final double? bb2Weight = bb2Entry?['weight']?.toDouble();
    final dynamic bb2RirRaw = bb2Entry?['rir'];
    final double? bb2Rir = (bb2RirRaw is num && bb2RirRaw > 0)
        ? (bb2RirRaw as num).toDouble()
        : null;

    final double usedRIR = bb2Rir ?? rawRIR?? 1.0;

    final progressed = _getProgressedValues(exerciseIndex);
    final double baseWeight = (progressed['weight'] ?? 20.0).toDouble();
    final double baseReps = (progressed['reps'] ?? 10).toDouble();
    final double baseE1RM = progressed['e1rm'] ?? PeriodizationModelUtils.calculateE1RM(
      baseWeight,
      baseReps,
      usedRIR,
    );
    print('🧠 [WES] Base E1RM used for ${exerciseName} = ${baseE1RM.toStringAsFixed(2)} '
        '(weight = ${baseWeight.toStringAsFixed(1)}, reps = ${baseReps.toStringAsFixed(1)}, RIR = $usedRIR)');

// Prioritization logic
    final bool hasUserReps = reps != null;
    final bool hasBB2Reps = bb2Reps != null && bb2Reps > 0;
    final double? usedWeight = weight ?? (bb2Weight != null && bb2Weight > 0 ? bb2Weight : null);

// CASE 1: Reps already entered by user → use it
    if (hasUserReps) return reps!;

// CASE 2: BB2-entered reps → use them
    if (hasBB2Reps) {
      print('🔁 [WES] Using BB2-entered reps for $exerciseName = $bb2Reps');
      return bb2Reps!;
    }

// CASE 3: Weight (from user or BB2) → derive reps
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

      print('🔁 [WES] Using weight = $usedWeight & RIR = $usedRIR → derived reps = $derivedReps → rounded = $roundedReps (target E1RM = ${baseE1RM.toStringAsFixed(2)})');

      return roundedReps;
    }


    // CASE 3: No override → use model default
    return baseReps;
  }

  double set2SuggestedReps(int exerciseIndex) {
    String exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

    double set2E1RM = getSet2E1RM(exerciseIndex);
    double? set1Reps =
        double.tryParse(_repsControllers[exerciseIndex][0].text) ??
            set1SuggestedReps(exerciseIndex);

    return PeriodizationModelUtils.getSuggestedSet2RepsByModel(
      exerciseName: exerciseName,
      set2E1RM: set2E1RM,
      set1Reps: set1Reps,
      weightText: _weightControllers[exerciseIndex][1].text,
      rirText: _rirControllers[exerciseIndex][1].text,
    );
  }

  double set3SuggestedReps(int exerciseIndex) {
    String exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

    double set3E1RM = getSet3E1RM(exerciseIndex);
    double? set2Reps =
        double.tryParse(_repsControllers[exerciseIndex][1].text) ??
            set2SuggestedReps(exerciseIndex);

    return PeriodizationModelUtils.getSuggestedSet3RepsByModel(
      exerciseName: exerciseName,
      set3E1RM: set3E1RM,
      set2Reps: set2Reps,
      weightText: _weightControllers[exerciseIndex][2].text,
      rirText: _rirControllers[exerciseIndex][2].text,
    );
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
    final bb2Entry = _resolvedBB2Values[exerciseName.toLowerCase()];
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
    print('🧭 [WES RIR] exercise="$exerciseName" '
        'blockStartDate=$blockStartDate _selectedDate=$_selectedDate');

    final exerciseId =
        PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
    final weekIndex = _getApplicableWeekIndex(exerciseId);
    if (weekIndex == null) return setNumber == 1 ? 1 : 1.5;

    print('🧭 [WES RIR] _getApplicableWeekIndex → weekIndex=$weekIndex');

    if (blockStartDate == null) {
      print(
          '❌ [WES] RIR_blockStartDate is null in getRirFromPlanOrInput for $exerciseName');
      return 1; // fallback RIR value
    }

    print('📞 [WES RIR] calling getInstanceCountForExerciseInWeek with '
        'weekIndex=$weekIndex selectedDate=$_selectedDate');

    final sessionIndex =
    PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
      exerciseName: exerciseName,
      savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
      blockStartDate: blockStartDate!,
      weekIndex: weekIndex,
      selectedDate: _selectedDate, // ← ensure this is present
    );

    final rirPlan =
    PeriodizationModelUtils.plannedExerciseDetails[exerciseId]?['rirPlan'];
    final weekKey = 'week${weekIndex + 1}';
    final weekData = (rirPlan?[weekKey] as Map?)?.cast<String, dynamic>() ?? const {};
    final maxSessions = weekData.keys.where((k) => k.startsWith('session')).length;
    final safeSessionIndex = (maxSessions > 0) ? sessionIndex.clamp(0, maxSessions - 1) : 0;

    final sessionKey = 'session${safeSessionIndex + 1}';
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
    print(
        '📦 [WES] Final RIR used for "$exerciseName" set $setNumber → $finalRir');
    return finalRir;
  }



  double set1RIR(int i) => getRirFromPlanOrInput(i, 1);

// ✅ Function to determine RIR for Set 2 (Default: 1.5, Modifiable in Future)
  double set2RIR(int i) => getRirFromPlanOrInput(i, 2);

  double set3RIR(int i) => getRirFromPlanOrInput(i, 3);

  double set4RIR(int i) => getRirFromPlanOrInput(i, 4);

  double set5RIR(int i) => getRirFromPlanOrInput(i, 5);

  double set6RIR(int i) => getRirFromPlanOrInput(i, 6);

  double set7RIR(int i) => getRirFromPlanOrInput(i, 7);

  double set8RIR(int i) => getRirFromPlanOrInput(i, 8);

  double set1SuggestedWeight(int exerciseIndex) {
    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    final normalizedKey = exerciseName.toLowerCase();
    final bb2Entry = _resolvedBB2Values[normalizedKey];

    // ✅ Step 1: Use BB2-entered weight if available
    final double? bb2Weight = bb2Entry?['weight']?.toDouble();
    if (bb2Weight != null && bb2Weight > 0) {
      print('🔁 [WES] Using BB2-entered weight for $exerciseName: $bb2Weight');
      return bb2Weight;
    }

    // ✅ Step 2: Pull user-entered text fields
    final String weightText = _weightControllers[exerciseIndex][0].text;
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
      print('✍️ [WES] User-entered weight for $exerciseName = $userWeight');
      return userWeight;
    }

    // ✅ Step 4: Pull model progression values
    final progressed = _getProgressedValues(exerciseIndex);
    final double baseWeight = progressed['weight']?.toDouble() ?? 20.0;
    final double baseReps = progressed['reps']?.toDouble() ?? 10.0;
    final double modelRir = getRirFromPlanOrInput(exerciseIndex, 1);

    // ✅ Step 5: Calculate base E1RM using progression model only
    final double baseE1RM =
    PeriodizationModelUtils.calculateE1RM(baseWeight, baseReps, modelRir);
    print('🧠 [WES] Base progression E1RM = ${baseE1RM.toStringAsFixed(2)} '
        '(from $baseWeight × $baseReps @ RIR $modelRir)');

    // ✅ Step 6: Use user RIR and/or reps if available
    if (userReps != null || userRir != null) {
      final double repsToUse = userReps ?? set1SuggestedReps(exerciseIndex);
      final double rirToUse = userRir ?? modelRir;

      final double derived = PeriodizationModelUtils.reverseCalculateWeight(
        targetE1RM: baseE1RM,
        reps: repsToUse.toInt(),
        rir: rirToUse,
      );

      final String _exId = PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
      final List<double> _candidates = PeriodizationModelUtils.getIncrementsForExercise(_exId);
      final double rounded = (_candidates.isNotEmpty ? _candidates : List<double>.generate(200, (i) => i * 2.5))
          .reduce((a, b) => (a - derived).abs() < (b - derived).abs() ? a : b);
      print('🧲 [WES snap] $derived → $rounded (candidates=${_candidates.take(10).toList()} …)');


      final double newE1RM = PeriodizationModelUtils.calculateE1RM(
        rounded,
        repsToUse,
        rirToUse,
      );

      print('🔁 [WES] Derived weight = $rounded using reps = $repsToUse and RIR = $rirToUse → new E1RM = ${newE1RM.toStringAsFixed(2)}');

      return rounded;
    }


    // ✅ Step 7: No overrides — fallback to rounded base weight
    final String _exId = PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
    final List<double> _candidates = PeriodizationModelUtils.getIncrementsForExercise(_exId);
    final double fallbackRounded = (_candidates.isNotEmpty ? _candidates : List<double>.generate(200, (i) => i * 2.5))
        .reduce((a, b) => (a - baseWeight).abs() < (b - baseWeight).abs() ? a : b);
    print('🧲 [WES snap fallback] $baseWeight → $fallbackRounded (candidates=${_candidates.take(10).toList()} …)');

    print(
        '🎯 [WES] Final progression for $exerciseName using default RIR $modelRir → $fallbackRounded kg');
    return fallbackRounded;
  }

  double set2SuggestedWeight(int exerciseIndex) {
    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';
    final set2E1RM = getSet2E1RM(exerciseIndex);

    final repsText = _repsControllers[exerciseIndex][1].text;
    final rirText = _rirControllers[exerciseIndex][1].text;

    final reps = double.tryParse(repsText) ?? set2SuggestedReps(exerciseIndex);
    final rir = double.tryParse(rirText) ?? set2RIR(exerciseIndex);

    return PeriodizationModelUtils.getSuggestedSet2WeightByModel(
      exerciseName: exerciseName,
      set2E1RM: set2E1RM,
      reps: reps,
      rir: rir,
    );
  }

  double set3SuggestedWeight(int exerciseIndex) {
    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';
    final set3E1RM = getSet3E1RM(exerciseIndex);

    final repsText = _repsControllers[exerciseIndex][2].text;
    final rirText = _rirControllers[exerciseIndex][2].text;

    final reps = double.tryParse(repsText) ?? set3SuggestedReps(exerciseIndex);
    final rir = double.tryParse(rirText) ?? set3RIR(exerciseIndex);

    return PeriodizationModelUtils.getSuggestedSet3WeightByModel(
      exerciseName: exerciseName,
      set3E1RM: set3E1RM,
      reps: reps,
      rir: rir,
    );
  }

  void _debugUid(String where) {
    final ctx = UserContext.of(context, listen: false);
    print('👤 [$where] actorUid=${ctx.actorUid} actingAsUid=${ctx.actingAsUid} currentUid=${ctx.currentUid}');
  }

  Future<T> _timeStep<T>(String label, Future<T> Function() step, {Stopwatch? total}) async {
    final sw = Stopwatch()..start();
    try {
      return await step();
    } finally {
      sw.stop();
      if (kDebugMode) {
        debugPrint('⏱️ [WES Init] $label took ${sw.elapsedMilliseconds}ms'
            '${total != null ? " (total: ${total.elapsedMilliseconds}ms)" : ""}');
      }
    }
  }

  @override
  void initState() {
    super.initState();

    print('🚀 [WES] initState started');
    _cachedUid = UserContext.of(context, listen: false).currentUid;

    final contextUid = UserContext.of(context, listen: false).currentUid;
    final formattedDate = DateFormat('yyyy-MM-dd').format(DateTime.now());

    final legacyDraftKey = 'workout_draft_$formattedDate';
    final namespacedDraftKey = 'workout_draft_${contextUid}_$formattedDate';

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

          if (_activeBlockId == null || _blockStartDate == null || _blockEndDate == null) {
            print('❌ [WES Init] Missing required block meta. Exiting...');
            return;
          }

          await _loadAllBlocks();
          print('📦 [WES] _loadAllBlocks complete, total blocks: ${_allBlocks.length}');


          _selectedBlockId = _allBlocks.firstWhere(
                (b) => b.id == _activeBlockId,
            orElse: () => _allBlocks.first,
          ).id;

          print("🧱 [WES] Selected blockId: $_selectedBlockId");
          // ✅ Pre-warm exact block doc for WES
          // right after: print("🧱 [WES] Selected blockId: $_selectedBlockId");
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final uidForWarm = userId;
            if (uidForWarm.isNotEmpty && _selectedBlockId != null && _selectedBlockId!.isNotEmpty) {
              WarmupService.instance.warmWES(uidForWarm, activeBlockId: _selectedBlockId);
            }
          });


          await _loadInitialData();

          await _fetchLastWorkoutTopSetReps();
          print("📈 [WES] Top set reps fetched");

          _debugPrintBlockDates();

          await _initializeDayDocIfNeeded(_selectedDate);



          if (widget.initialDate != null) {
            _selectedDate = widget.initialDate!;
            _workoutNameController.text = _formatWorkoutDate(_selectedDate);
          }

          _cachedProgressedValues.clear();
          _selectedExercisesWithCircuits.clear();
          _workoutSets.clear();
          _repsControllers.clear();
          _weightControllers.clear();
          _rirControllers.clear();
          _velocityControllers.clear();
          _notesControllers.clear();
          _resolvedBB2Values.clear();

          await _loadDraftLocallyIfAvailable();
          _populateVelocityFlags();
          print("🔀 [WES] Merged BB2 into draft");

          _cachedProgressedValues.clear();

          final hasUserData = _weightControllers.any((controllerList) =>
              controllerList.any((c) => c.text.trim().isNotEmpty));

          if (!hasUserData) {
            print('🔁 [WES Init] No user-entered data in WES → re-merging BB2 values');
            _lastMergedUid = null;
            await _mergeNewBB2ExercisesIntoDraft();
          } else {
            print('✅ [WES Init] Skipping BB2 re-merge — WES already has user-entered data');
          }
          _scheduleMissedDialogAfterPaint();

          Future.delayed(const Duration(milliseconds: 10), () {
            if (_selectedExercisesWithCircuits.isNotEmpty) {
              final testExercise = _selectedExercisesWithCircuits.first['name']?.trim() ?? '';
              final rep = getRepTargetForExerciseWES(testExercise, 0);
              print('🧪 [WES Init] Test rep target for "$testExercise" = $rep');
            } else {
              print('⚠️ [WES Init] No exercises in _selectedExercisesWithCircuits');
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


      final start = meta.startDate;
      final end = meta.endDate;
      final days = meta.selectedDays;

      if (start != null && end != null) {
        blockStartDate = start;
        blockEndDate = end;
        _selectedDays = days;
        print('📦 [WES] BlockMeta (attempt $attempt) → start: $blockStartDate | end: $blockEndDate | days: $_selectedDays');
        return;
      } else {
        print('⏳ [WES] BlockMeta not ready (attempt $attempt) — retrying...');
        await Future.delayed(delayBetweenAttempts);
      }
    }

    // ❌ Still null after all attempts
    print('❌ [WES] Failed to fetch valid blockMeta after $maxAttempts attempts');
  }

  void _populateVelocityFlags() {
    for (final exercise in _selectedExercisesWithCircuits) {
      final name = (exercise['name'] as String?)?.toLowerCase() ?? '';
      final isTracked = PeriodizationModelUtils.isVelocityTracked(name); // ✅ declare it here
      _showVelocityByExercise[name] = isTracked;

      print('📈 Velocity Check → $name → $isTracked'); // ✅ now it exists
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

    print('✅ [WES] Loaded block dates: $_blockStartDate → $_blockEndDate');
  }


  Future<void> _loadAllBlocks() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    print('👤 [WES] _loadAllBlocks using userId=$userId and currentUser.uid=${FirebaseAuth.instance.currentUser?.uid}');

    final snap = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .get();

    print('🔍 [WES] Loaded ${snap.docs.length} blocks: ${snap.docs.map((d) => d.id)}');

    final blocks = snap.docs.map((d) {
      final data = d.data();

      final Timestamp? startTs = data.containsKey('startDate') ? data['startDate'] as Timestamp? : null;
      final Timestamp? endTs = data.containsKey('endDate') ? data['endDate'] as Timestamp? : null;

      return BlockMeta(
        id: d.id,
        name: data['name'], // nullable is fine now
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
    if (user == null || _selectedBlockId == null || blockStartDate == null) return;

    final blockId = _selectedBlockId!;
    final daysSinceStart = date.difference(blockStartDate!).inDays;
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
        print('[WES Init] Populating missing week/day doc from fallback block_data...');
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


  Future<void> _loadExercisesFromBB2ForDay() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _selectedBlockId == null || _selectedDate == null) return;
    if (user == null) {
      return;
    }
    if (_selectedBlockId == null) {
      return;
    }
    if (_selectedDate == null) {
      return;
    }

    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    print('📅 [WES] Loading BB2 exercises for $dateKey (block: $_selectedBlockId)');
    final doc = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(_selectedBlockId)
        .collection('block_data')
        .doc(dateKey)
        .get();

    if (!doc.exists) {
      print('🟡 [WES] No BB2 plan found for $dateKey in block $_selectedBlockId');
      return;
    }

    final data = doc.data();
    final List<dynamic> rows = data?['rows'] ?? [];

    // Optional: clear old list first
    _selectedExercisesWithCircuits.clear();

    for (final row in rows) {
      final name = row['name'] ?? '';
      final circuit = row['circuitIndex'] ?? 0;

      if (name.trim().isEmpty) continue;

      _selectedExercisesWithCircuits.add({
        'name': name.trim(),
        'circuitIndex': circuit,
      });
    }

    print('✅ [WES] Loaded ${_selectedExercisesWithCircuits.length} exercises from BB2 for $dateKey');

    setState(() {}); // 🧠 Trigger UI update
  }

  Future<void> _loadInitialData() async {
    print('🚀 [WES Init] Starting _loadInitialData');
    final _loadInitialDataTimer = Stopwatch()..start();

    if (widget.prefilledExercisesWithCircuits?.isNotEmpty ?? false) {
      setState(() {
        _selectedExercisesWithCircuits.clear();
        _workoutSets.clear();
        _repsControllers.clear();
        _weightControllers.clear();
        _rirControllers.clear();
        _resolvedBB2Values.clear();
        _blockStartDate = widget.initialDate;
        _blockEndDate = widget.initialDate;

        _selectedExercisesWithCircuits.addAll(
          widget.prefilledExercisesWithCircuits!
              .map((e) => Map<String, dynamic>.from(e)),
        );

        for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
          _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
          _repsControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _weightControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _rirControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _velocityControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _notesControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
        }

        _isLoadingData = false;
      });
      return;
    }

    // 🔁 Normal flow
    print('🔁 [WES Init] Running full BB2 plan load');

// These 3 appear order-dependent → keep them sequential
    await loadExercisesFromFirestoreForWES(); //done
    await _buildNameToIdMapsFromFirestore();
    await _loadPlannedExerciseDetails(); //done

// These are independent once the above are done → run in parallel
    final uid = _cachedUid; // use the selected athlete
    await Future.wait([
      PeriodizationModelUtils.fetchFullTopSetHistory(uid: uid),
      loadSavedWorkoutsForInstanceCount(), //done
      loadPlannedExercisesFromFirestore(),
      loadPreviousWorkoutData(),//done
    ]);

// 💾 Draft Load
    print('💾 [WES Init] Attempting to load draft from cache...');
    final draftLoaded = await _loadWorkoutDraftFromCache();
    print('📦 [WES Init] Draft loaded: $draftLoaded');

// 🔸 Minimal: ensure the BB2 day doc is fresh from SERVER before merging
    try {
      final uid = _cachedUid;
      final bid = _selectedBlockId;
      if (uid != null && bid != null && _blockStartDate != null && _selectedDate != null) {
        final ds = _selectedDate.difference(_blockStartDate!).inDays;
        if (ds >= 0) {
          final wi = (ds / 7).floor();
          final di = ds % 7;
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

    if (draftLoaded) {
      print('🔁 [WES Init] Merging BB2 exercises post-draft...');
      await _mergeNewBB2ExercisesIntoDraft();
      if (mounted) setState(() {}); // force UI to render merged exercises
    } else {
      print('📭 [WES Init] No draft found → merging BB2 from scratch');
      _selectedExercisesWithCircuits.clear(); // ensure fully fresh
      print('[WES Init] Exercises before BB2 merge: ${_selectedExercisesWithCircuits.length}');
      await _mergeNewBB2ExercisesIntoDraft();
      if (mounted) setState(() {}); // force UI to render merged exercises
      print('[WES Init] Exercises after BB2 merge: ${_selectedExercisesWithCircuits.length}');
    }

    print('🧪 [WES Init] Resolved BB2 values:');
    _resolvedBB2Values.forEach((name, values) {
      print('    → $name → $values');
    });


    setState(() {
      _isLoadingData = false;
      _isInitialized = true;
    });
    print('✅ [WES Init] _loadInitialData complete');
    _loadInitialDataTimer.stop();
    print('⏱️ [WES] _loadInitialData took ${_loadInitialDataTimer.elapsedMilliseconds}ms');
    await _loadExistingWorkoutIfAny();
    setState(() {}); // to repaint saved color/collapse if you gate on it
  }

  Future<void> _loadExistingWorkoutIfAny() async {
    final uid = UserContext.of(context, listen: false).currentUid ?? FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final workoutsCol = FirebaseFirestore.instance.collection('users').doc(uid).collection('workouts');
    final String newDocId = _workoutDocIdForDate(_selectedDate); // e.g. 2025-08-24
    final DateTime startOfDay = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    final DateTime nextDay = startOfDay.add(const Duration(days: 1));

    print('🔎 [WES LoadExisting] Looking up workout for ${DateFormat('yyyy-MM-dd').format(_selectedDate)}');
    print('   └─ primary docId = $newDocId');

    // 1) Primary: new-style doc keyed by date string
    // --- BEGIN UNION LOOKUP (new-style preferred; include legacy-only) ---

// Server-first reads so cross-device saves show up
    DocumentSnapshot<Map<String, dynamic>>? newDoc;
    try {
      newDoc = await workoutsCol.doc(newDocId).get(const GetOptions(source: Source.server));
    } catch (_) {
      newDoc = await workoutsCol.doc(newDocId).get();
    }

// ----- Legacy lookups: try string equals, string range (ISO), and timestamp range -----
    final isoLocal = DateTime(startOfDay.year, startOfDay.month, startOfDay.day).toIso8601String();    // …T00:00:00.000
    final isoUtc   = DateTime.utc(startOfDay.year, startOfDay.month, startOfDay.day).toIso8601String(); // …T00:00:00.000Z
    final dateOnly = DateFormat('yyyy-MM-dd').format(startOfDay); // 2025-08-19
    final nextDateOnly = DateFormat('yyyy-MM-dd').format(nextDay);

// For string *equals* (covers old midnight saves, with and without Z, and date-only)
    Future<QuerySnapshot<Map<String, dynamic>>> _eq(String value) async {
      try {
        return await workoutsCol.where('date', isEqualTo: value)
            .get(const GetOptions(source: Source.server));
      } catch (_) {
        return await workoutsCol.where('date', isEqualTo: value).get();
      }
    }
    final legacyStrLocal = await _eq(isoLocal);
    final legacyStrUtc   = await _eq(isoUtc);
    final legacyStrDate  = await _eq(dateOnly);

// NEW: For string *range* (catches ISO strings with time-of-day, e.g. 2025-08-14T09:00:29.295539)
    QuerySnapshot<Map<String, dynamic>> legacyStrRange;
    try {
      legacyStrRange = await workoutsCol
          .where('date', isGreaterThanOrEqualTo: '${dateOnly}T00:00:00') // lower bound (inclusive)
          .where('date', isLessThan:        '${nextDateOnly}T00:00:00')  // upper bound (exclusive)
          .get(const GetOptions(source: Source.server));
    } catch (_) {
      legacyStrRange = await workoutsCol
          .where('date', isGreaterThanOrEqualTo: '${dateOnly}T00:00:00')
          .where('date', isLessThan:        '${nextDateOnly}T00:00:00')
          .get();
    }

// Timestamp day-range (only hits docs where `date` is a Timestamp)
    QuerySnapshot<Map<String, dynamic>> legacyTsSnap;
    try {
      legacyTsSnap = await workoutsCol
          .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
          .where('date', isLessThan: Timestamp.fromDate(nextDay))
          .get(const GetOptions(source: Source.server));
    } catch (_) {
      legacyTsSnap = await workoutsCol
          .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
          .where('date', isLessThan: Timestamp.fromDate(nextDay))
          .get();
    }

// De-dup doc hits by id across all legacy queries
    final Map<String, DocumentSnapshot<Map<String, dynamic>>> _legacyDocsById = {};
    for (final d in [
      ...legacyStrLocal.docs,
      ...legacyStrUtc.docs,
      ...legacyStrDate.docs,
      ...legacyStrRange.docs,  // << add the string-range hits
      ...legacyTsSnap.docs,
    ]) {
      _legacyDocsById[d.id] = d;
    }

// Extract exercises from a doc
    List<Map<String, dynamic>> _exListFromDoc(DocumentSnapshot<Map<String, dynamic>>? d) {
      if (d == null || !d.exists) return const [];
      final data = d.data();
      if (data == null) return const [];
      final raw = (data['exercises'] as List?) ?? const [];
      return raw.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
    }

// Gather lists
    final List<Map<String, dynamic>> newExList = _exListFromDoc(newDoc);
    final List<Map<String, dynamic>> legacyExList = [
      for (final d in _legacyDocsById.values) ..._exListFromDoc(d),
    ];

    print('   ℹ️ legacy candidates: '
        'eqLocal=${legacyStrLocal.docs.length}, eqUtcZ=${legacyStrUtc.docs.length}, '
        'eqDateOnly=${legacyStrDate.docs.length}, strRange=${legacyStrRange.docs.length}, '
        'tsRange=${legacyTsSnap.docs.length}, uniqueDocs=${_legacyDocsById.length}, '
        'legacyExList=${legacyExList.length}');

// Build union keyed by (name|circuitIndex). Prefer NEW if both contain same exercise.
    String _key(Map<String, dynamic> e) =>
        '${(e['name'] ?? '').toString().trim()}|${(e['circuitIndex'] ?? 0) as int}';


    final Map<String, Map<String, dynamic>> newByKey = {
      for (final e in newExList) _key(e): e,
    };

// Start with all NEW
    final List<Map<String, dynamic>> combined = [...newExList];

// Add LEGACY-ONLY exercises (skip if same exercise exists in NEW)
    for (final e in legacyExList) {
      final k = _key(e);
      if (!newByKey.containsKey(k)) {
        combined.add(e);
      }
    }

    if (combined.isEmpty) {
      print('   ❌ no workout exercises found (new or legacy) for this date');
      await _persistSavedFlagsLocally();
      if (mounted) setState(() {});
      return;
    }

// This replaces your earlier `exList` assignment:
    final List exList = combined;

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

    // 5) Pass 1 (existing behavior): overlay onto any rows that already exist (from BB2 merge)
    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      final nameRaw = (_selectedExercisesWithCircuits[i]['name'] as String?) ?? 'Unnamed';
      final nameLc  = nameRaw.trim().toLowerCase();
      final circuitIndex = _selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0;

      final match = exList.cast<Map<String, dynamic>?>().firstWhere(
            (e) {
          if (e == null) return false;
          final exNameLc = (e['name'] as String?)?.trim().toLowerCase();
          final exCi     = (e['circuitIndex'] ?? 0) as int;
          return exNameLc == nameLc && exCi == circuitIndex;
        },
        orElse: () => null,
      );

      if (match != null) {
        final setMaps = List<Map<String, dynamic>>.from(match['sets'] ?? []);
        if (setMaps.isEmpty) {
          continue; // keep local draft visible
        }

        final sets = setMaps.map((s) => SetDetails(
          reps: (s['reps'] is int) ? s['reps'] : int.tryParse(s['reps']?.toString() ?? ''),
          weight: (s['weight'] is num) ? (s['weight'] as num).toDouble() : null,
          rir: (s['rir'] is num) ? (s['rir'] as num).toDouble() : null,
          velocity: (s['velocity'] is num) ? (s['velocity'] as num).toDouble() : null,
          notes: s['notes']?.toString(),
        )).toList();

        if (i >= _workoutSets.length) continue;

        // pad to default rows for hint text
        final int minRows = _defaultSets;
        if (sets.length < minRows) {
          sets.addAll(List.generate(minRows - sets.length, (_) => SetDetails()));
        }
        _workoutSets[i] = sets;

        // resize + seed controllers
        if (_repsControllers.length <= i || _repsControllers[i].length != sets.length) {
          _repsControllers[i] = List.generate(sets.length, (_) => TextEditingController());
          _weightControllers[i] = List.generate(sets.length, (_) => TextEditingController());
          _rirControllers[i] = List.generate(sets.length, (_) => TextEditingController());
          _velocityControllers[i] = List.generate(sets.length, (_) => TextEditingController());
          _notesControllers[i] = List.generate(sets.length, (_) => TextEditingController());
        }
        for (int j = 0; j < sets.length; j++) {
          final s = _workoutSets[i][j];
          _repsControllers[i][j].text = (s.reps?.toString() ?? '');
          _weightControllers[i][j].text = (s.weight?.toString() ?? '');
          _rirControllers[i][j].text = (s.rir?.toString() ?? '');
          _velocityControllers[i][j].text = (s.velocity?.toString() ?? '');
          _notesControllers[i][j].text = (s.notes ?? '');
        }
      }
    }

    // 6) Pass 2 (NEW): add any saved exercises that aren’t in the plan/UI yet
    final existingKeys = _selectedExercisesWithCircuits
        .map<String>((e) => _exerciseKey(
      ((e['name'] ?? '') as String).trim(),
      (e['circuitIndex'] ?? 0) as int,
    ))
        .toSet();

    int added = 0;
    for (final raw in exList) {
      if (raw is! Map) continue;
      final name = (raw['name'] ?? '').toString().trim();
      final ci = (raw['circuitIndex'] ?? 0) as int;
      final key = _exerciseKey(name, ci);
      if (existingKeys.contains(key)) continue;

      final setMaps = List<Map<String, dynamic>>.from(raw['sets'] ?? []);
      // build SetDetails (pad to default rows)
      final sets = setMaps.map((s) => SetDetails(
        reps: (s['reps'] is int) ? s['reps'] : int.tryParse(s['reps']?.toString() ?? ''),
        weight: (s['weight'] is num) ? (s['weight'] as num).toDouble() : null,
        rir: (s['rir'] is num) ? (s['rir'] as num).toDouble() : null,
        velocity: (s['velocity'] is num) ? (s['velocity'] as num).toDouble() : null,
        notes: s['notes']?.toString(),
      )).toList();

      if (sets.length < _defaultSets) {
        sets.addAll(List.generate(_defaultSets - sets.length, (_) => SetDetails()));
      }

      // append row
      _selectedExercisesWithCircuits.add({'name': name, 'circuitIndex': ci});
      _workoutSets.add(sets);
      _repsControllers.add(List.generate(sets.length, (_) => TextEditingController()));
      _weightControllers.add(List.generate(sets.length, (_) => TextEditingController()));
      _rirControllers.add(List.generate(sets.length, (_) => TextEditingController()));
      _velocityControllers.add(List.generate(sets.length, (_) => TextEditingController()));
      _notesControllers.add(List.generate(sets.length, (_) => TextEditingController()));

      final idx = _selectedExercisesWithCircuits.length - 1;
      for (int j = 0; j < sets.length; j++) {
        final s = sets[j];
        _repsControllers[idx][j].text = (s.reps?.toString() ?? '');
        _weightControllers[idx][j].text = (s.weight?.toString() ?? '');
        _rirControllers[idx][j].text = (s.rir?.toString() ?? '');
        _velocityControllers[idx][j].text = (s.velocity?.toString() ?? '');
        _notesControllers[idx][j].text = (s.notes ?? '');
      }

      // mark saved for paint if savedAt present
      if (raw['savedAt'] != null) {
        _savedExerciseKeysForDate.add(key);
      }

      added++;
    }

    print('🧩 [WES LoadExisting] Added $added saved-only exercise row(s) from Firestore');

    // 7) Ensure listeners on any new controllers
    _attachDirtyListeners();

    // 8) Persist merged flags so next open is instant
    await _persistSavedFlagsLocally();

    _pendingChanges = false;
    _lastSavedHash = null;

    if (mounted) setState(() {}); // repaint now that overlay + additions are in
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
        final id = doc.id;
        final rawName = doc.data()['name'];
        final name = rawName?.toString().trim();
        if (name != null && name.isNotEmpty) {
          PeriodizationModelUtils.nameToId[name] = id;
          PeriodizationModelUtils.idToName[id] = name;
          mapped++;
          print('✅ [WES] Mapped "$name" → $id');
        }
      }
      mapSw.stop();

      print('📥 [WES] exercises.get() took ${getSw.elapsedMilliseconds}ms');
      print('🧭 [WES] Mapping loop took ${mapSw.elapsedMilliseconds}ms (mapped $mapped)');
    } catch (e, st) {
      print('❌ [WES] loadExercisesFromFirestoreForWES error: $e');
      print(st);
    } finally {
      total.stop();
      print('⏱️ [WES] loadExercisesFromFirestoreForWES total ${total.elapsedMilliseconds}ms (mapped $mapped)');
      print('⤴️ [WES] loadExercisesFromFirestoreForWES END');
    }
  }




  Future<Map<String, dynamic>> _loadPlannedExerciseDetails() async {
    // ⏱️ added
    final sw = Stopwatch()..start(); // ⏱️ Start timer
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
        doc = await ref.get(const GetOptions(source: Source.server)); // cold path
      }
    } catch (_) {
      doc = await ref.get(const GetOptions(source: Source.server)); // fallback
    }

    print('🧾 [RAW] Full Firestore doc snapshot data: ${doc.data()}');



    if (!doc.exists) {
      return {};
    }


    // ✅ 2. Extract data and handle blockMeta separately
    final data = doc.data()!;
    final blockMeta = data['blockMeta'] as Map<String, dynamic>? ?? {};
    final details = Map<String, dynamic>.from(data['plannedExerciseDetails'] ?? {});

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
    print('📅 [WES] Loaded blockStartDate=$_blockStartDate, blockEndDate=$_blockEndDate');

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
        mergedForPMU[exId] = Map<String, dynamic>.from(mergedForPMU[exId] ?? {});
        mergedForPMU[exId]!['increments'] = inc;
        print('🩹 [WES LOAD] overriding increments for $exId → $inc');
      }
    });

// now inject
    PeriodizationModelUtils.setExerciseSettings(mergedForPMU);
    print('✅ [WES] Injected exerciseSettings into PMU with keys: ${mergedForPMU.keys}');


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
      print("🧠 [WES] modelName = $modelName → modelEnum = $modelEnum");

      if (modelEnum != null) {
        PeriodizationModelUtils.exercisePeriodizationModels[exerciseId] = modelEnum;
        print('✅ [WES] Mapped model $modelName → $modelEnum for $exerciseId');
      }

      // Track progressionModel if you need it later
      final progressionModel = entry['progressionModel'] ?? 'none';
      _progressionModelsByExercise[exerciseId] = progressionModel;
      print('🏗️ [WES] Progression model for $exerciseId: $progressionModel');
    });


    print('📄 [WES] Full plannedExerciseDetails loaded: ${details.keys}');
    sw.stop();
    print('⏱️ [WES] _loadPlannedExerciseDetails took ${sw.elapsedMilliseconds}ms');
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
    print(
        '📦 [WES] [Firestore Function] Full raw Firestore data: ${jsonEncode(data)}');
    print(
        '📦 [WES] Extracted plannedExerciseDetails: ${jsonEncode(rawDetails)}');



    // ✅ Inject into PMU
    PeriodizationModelUtils.setExerciseSettings(rawDetails);
    print(
        '✅ [WES] Injected exerciseSettings into PMU with keys: ${rawDetails.keys}');

    // ✅ Build name ↔ ID maps
    final nameToIdMap = <String, String>{};
    final idToNameMap = <String, String>{};

    rawDetails.forEach((id, entry) {
      if (entry is Map<String, dynamic>) {
        // ✅ Try to get name directly from Firestore entry
        String? name = entry['name'];

        // ✅ Fallback: try to get it from injected _selectedExercisesWithCircuits
        if ((name == null || name.trim().isEmpty) &&
            PeriodizationModelUtils.idToName.containsKey(id)) {
          name = PeriodizationModelUtils.idToName[id];
          print('🔁 [WES] Using fallback name from idToName for $id → $name');
        }

        if (name != null && name.trim().isNotEmpty) {
          nameToIdMap[name.trim()] = id;
          idToNameMap[id] = name.trim();
          print('✅ [WES] Mapped name "$name" ↔ id $id');
        } else {
          print('❌ [WES] Still missing name for exerciseId: $id');
        }
      }
    });

    PeriodizationModelUtils.nameToId = nameToIdMap;
    PeriodizationModelUtils.idToName.clear();
    PeriodizationModelUtils.idToName.addAll(idToNameMap);

    print('✅ [WES] nameToIdMap injected with ${nameToIdMap.length} entries');
    print('✅ [WES] idToNameMap injected with ${idToNameMap.length} entries');
  }

  void _injectIdToNameFromSelectedExercises() {
    for (final ex in _selectedExercisesWithCircuits) {
      final id = ex['id'];
      final name = ex['name'];
      if (id != null && name != null) {
        PeriodizationModelUtils.idToName[id] = name;
        print("🧩 [WES inject] id=$id → name=$name"); // ✅ Debug print
      }
    }
  }

  Future<void> loadSavedWorkoutsForInstanceCount() async {
    final sw = Stopwatch()..start();
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
        final cachedSnap = await col.get(const GetOptions(source: Source.cache));
        workouts = cachedSnap.docs.map((d) => d.data()).toList();
      } catch (_) {
        // cache may miss/throw on first-ever run; that's fine
      }

      // 2) If cache had anything, apply immediately
      if (workouts.isNotEmpty) {
        PeriodizationModelUtils.savedWorkoutsList =
        List<Map<String, dynamic>>.from(workouts);
        print('📦 [WES] (cache) Loaded ${workouts.length} saved workouts into savedWorkoutsList');
      } else {
        // 3) Guarantee a server fallback (awaited) so behavior matches old code
        final serverSnap = await col.get(); // server
        workouts = serverSnap.docs.map((d) => d.data()).toList();
        PeriodizationModelUtils.savedWorkoutsList =
        List<Map<String, dynamic>>.from(workouts);
        print('📦 [WES] (server) Loaded ${workouts.length} saved workouts into savedWorkoutsList');
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
              print('🔁 [WES] Reconciled saved workouts (server count ${fresh.length})');
            }
          } catch (_) {}
        }());
      }
    } finally {
      sw.stop();
      print('⏱️ [WES] loadSavedWorkoutsForInstanceCount took ${sw.elapsedMilliseconds}ms');
    }
  }


  int? _getApplicableWeekIndex(String exerciseId) {
    final model =
        PeriodizationModelUtils.exercisePeriodizationModels[exerciseId];
    print('🧮 [_getApplicableWeekIndex] start for exerciseId=$exerciseId '
        'blockStartDate=$blockStartDate _selectedDate=$_selectedDate');

    if (model == PeriodizationModelType.linearClassic ||
        model == PeriodizationModelType.dailyUndulatingWeek ||
        model == PeriodizationModelType.dupSignature ||
        model == PeriodizationModelType.dailyUndulatingExposure) {
      print('🧩 [_getApplicableWeekIndex] _blockStartDate=$_blockStartDate (vs blockStartDate=$blockStartDate)');

      if (blockStartDate == null) return 0;

      final daysSinceStart = _selectedDate.difference(blockStartDate!).inDays;

      final weekIndex = (daysSinceStart / 7).floor().clamp(0, 11);

      print('📆 [WES] Calculated weekIndex=$weekIndex for $exerciseId');

      return weekIndex;
    }

    return null; // exposure-based models
  }

  void _setInitialWorkoutName() {
    if (widget.initialTemplate != null &&
        widget.initialTemplate!.name.isNotEmpty) {
      _workoutNameController.text = widget.initialTemplate!.name;
    } else if (widget.initialWorkoutName != null) {
      _workoutNameController.text = widget.initialWorkoutName!;
    } else {
      _workoutNameController.text =
          DateFormat('EEE d MMM yyyy').format(_selectedDate);
    }
  }
//101here
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    print('📱 [WES] AppLifecycleState changed: $state');
    print('📱 [WES] mounted = $mounted');

    if (state == AppLifecycleState.resumed) {
      final prefs = await SharedPreferences.getInstance();
      final dateKey =
          '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
      final timestampStr = prefs.getString('draft_last_saved_$dateKey');

      print('🔍 [WES] Checking last draft timestamp for key: $dateKey → $timestampStr');

      if (timestampStr != null) {
        final savedAt = DateTime.tryParse(timestampStr);
        final now = DateTime.now();
        print('🕒 [WES] Draft last saved at: $savedAt — now: $now');

        if (savedAt != null && now.difference(savedAt).inHours < 2) {
          print('[WES] App resumed — refreshing draft with BB2 merge');
          await _mergeNewBB2ExercisesIntoDraft();
          if (mounted) setState(() {}); // Refresh UI if merged
        }
      }
      return; // nothing else to do on resumed
    }

    // For paused/inactive/detached → persist local draft AND autosave to Firestore (+ BB2 push)
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      print('📦 [WES] App $state — persisting local draft...');
      _persistDraftLocally();

      // Guard against overlapping lifecycle saves
      if (_lifecycleSaveInFlight) {
        print('⏳ [WES] Lifecycle save already in flight — skipping.');
        return;
      }
      _lifecycleSaveInFlight = true;

      try {
        if (_pendingChanges) {
          print('💾 [WES] Autosaving to Firestore (with BB2 push)…');
          await _upsertWorkoutToFirestore(
            alsoPushToBB2: true, // ← you asked for BB2 merge on autosave
            markAllSaved: false, // ← don’t force saved-format on autosave
          );
          print('✅ [WES] Autosave complete.');
        } else {
          print('🔸 [WES] No pending changes — skipping autosave.');
        }
      } catch (e, st) {
        print('❌ [WES] Autosave failed: $e');
        print(st);
        // We already persisted the local draft above; this gives resilience if the autosave fails.
      } finally {
        _lifecycleSaveInFlight = false;
      }
    }
  }



  void _loadWorkout(Workout workout) {
    _workoutNameController.text = workout.name;
    _selectedDate = workout.date;

    _selectedExercisesWithCircuits.clear();
    _workoutSets.clear();

    for (var exercise in workout.exercises) {
      _selectedExercisesWithCircuits.add({
        'name': exercise.name,
        'circuitIndex':
            exercise.circuitIndex ?? 0, // ✅ fallback to 0 if missing
      });

      _workoutSets.add(
        exercise.sets
            .map((set) => SetDetails(
                  reps: set.reps,
                  weight: set.weight,
                  rir: set.rir,
                ))
            .toList(),
      );
    }

   // _initializeControllers();
  }

  void _loadTemplate(Template template) {
    setState(() {
      _workoutNameController.text = template.name;
      _selectedExercisesWithCircuits.clear();
      _workoutSets.clear();

      // ✅ Convert each exercise into a Map with name + circuitIndex
      for (var e in template.exercises) {
        _selectedExercisesWithCircuits.add({
          'name': (e is String) ? e : (e['name'] ?? 'Unnamed'),
          'circuitIndex': (e is Map && e.containsKey('circuitIndex'))
              ? e['circuitIndex']
              : 0,
        });
      }

      // ✅ Initialize sets and controllers
      _workoutSets.addAll(List.generate(
        _selectedExercisesWithCircuits.length,
        (_) => List.generate(
          _defaultSets,
          (_) => SetDetails(reps: null, weight: null, rir: null),
        ),
      ));

     _initializeControllers();
    });
  }

  void _showTemplateSelectionDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('templates')
        .get();

    final templates = snapshot.docs
        .map((doc) => Template.fromFirestore(doc.data(), doc.id))
        .toList();

    final selectedTemplate = await showDialog<Template>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade800,
          title: const Text('Select Template',
              style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: templates.isEmpty
                ? const Center(
                    child: Text(
                      'No templates available.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: templates.length,
                    itemBuilder: (context, index) {
                      final template = templates[index];
                      return ListTile(
                        title: Text(template.name,
                            style: const TextStyle(color: Colors.white)),
                        dense: true, // ✅ THIS is what reduces vertical space
                        onTap: () => Navigator.pop(context, template),
                      );
                    },
                  ),
          ),
        );
      },
    );

    if (selectedTemplate != null) {
      _loadTemplate(selectedTemplate);
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
    print('🧹 [WES] dispose called — uid=$_cachedUid');

    print('💾 [WES dispose] Persisting local draft...');
    _persistDraftLocally();

    // ⭐ Always attempt autosave on exit; _upsert will skip/clear appropriately
    print('💾 [WES dispose] Attempting autosave to Firestore...');
    _upsertWorkoutToFirestore(alsoPushToBB2: true, markAllSaved: false);

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
    print('✅ [WES dispose] Completed cleanup.');
    super.dispose();
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
    while (_velocityControllers.length < _selectedExercisesWithCircuits.length) {
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
              text: set.velocity != null ? set.velocity!.toStringAsFixed(2) : '');
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

  String get _draftKey {
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    return 'wes_draft_$dateKey';
  }

  //101here
  Future<void> _persistDraftLocally() async {
    if (!mounted) {
      print('🚫 [WES] Skipped draft save — widget is unmounted.');
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();

      // Sync current TextField values into _workoutSets
      for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
        for (int j = 0; j < _workoutSets[i].length; j++) {
          _workoutSets[i][j].reps = int.tryParse(_repsControllers[i][j].text.trim());
          _workoutSets[i][j].weight = double.tryParse(_weightControllers[i][j].text.trim());
          _workoutSets[i][j].rir = double.tryParse(_rirControllers[i][j].text.trim());
          _workoutSets[i][j].velocity = double.tryParse(_velocityControllers[i][j].text.trim());
          _workoutSets[i][j].notes = _notesControllers[i][j].text.trim();
        }
      }

      final draft = {
        'workoutName': _workoutNameController.text,
        'exercises': List.generate(_selectedExercisesWithCircuits.length, (i) => {
          'name': _selectedExercisesWithCircuits[i]['name'],
          'circuitIndex': _selectedExercisesWithCircuits[i]['circuitIndex'],
          'sets': _workoutSets[i].map((set) => set.toMap()).toList(),
        }),
      };

      final key = _getDraftKey(); // 👈 use your helper
      await prefs.setString(key, jsonEncode(draft));
      print('💾 [WES] Draft saved for ${_selectedDate.toIso8601String()} under key: $key');

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
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getDraftKey(); // 👈 use your helper
      final jsonStr = prefs.getString(key);
      print('📥 [WES] Loading draft using key: $key');

      if (jsonStr == null) return;

      final decoded = jsonDecode(jsonStr);
      final List exercises = decoded['exercises'] ?? [];

      _selectedExercisesWithCircuits.clear();
      _workoutSets.clear();
      _repsControllers.clear();
      _weightControllers.clear();
      _rirControllers.clear();
      _velocityControllers.clear();
      _notesControllers.clear();

      _workoutNameController.text = decoded['workoutName'] ?? _formatWorkoutDate(_selectedDate);

      for (final e in exercises) {
        _selectedExercisesWithCircuits.add({
          'name': e['name'],
          'circuitIndex': e['circuitIndex'] ?? 0,
        });

        final List<Map<String, dynamic>> setMaps = List<Map<String, dynamic>>.from(e['sets'] ?? []);
        final sets = setMaps.map((s) => SetDetails(
          reps: (s['reps'] is int) ? s['reps'] : int.tryParse(s['reps']?.toString() ?? ''),
          weight: (s['weight'] is num) ? (s['weight'] as num).toDouble() : null,
          rir: (s['rir'] is num) ? (s['rir'] as num).toDouble() : null,
          velocity: (s['velocity'] is num) ? (s['velocity'] as num).toDouble() : null,
          notes: s['notes']?.toString(),
        )).toList();

        _workoutSets.add(sets);
      }

      _initializeControllers();
    } catch (e) {
      print('❌ Failed to load WES draft: $e');
    }
  }


  Future<void> _clearDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getDraftKey(); // 👈 use helper
    await prefs.remove(key);
    print('🧹 [WES] Cleared draft for key: $key');
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
        .map((doc) => {
              'id': doc.id,
              'name': doc['name'] as String,
              'category': doc['category'] as String,
            })
        .toList();

    // 🔥 Build Name ➔ ID map
    final Map<String, String> nameToIdMap = {
      for (final ex in allExercises) ex['name']!: ex['id']!,
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
              if (searchQuery.trim().isNotEmpty) {
                final query = searchQuery.toLowerCase();
                filteredExercises = filteredExercises.where((ex) {
                  final name = ex['name']?.toLowerCase() ?? "";
                  return name.contains(query);
                }).toList();
              }

              print('Planned Exercise IDs: $plannedExercises');
              print(
                  'Loaded Exercises (id, name): ${allExercises.map((e) => '${e['id']} (${e['name']})').toList()}');
              print(
                  'Filtered Exercises (${showPlannedOnly ? "Planned Only" : "All"}): ${filteredExercises.map((e) => e['name']).toList()}');

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
                    horizontal: 24, vertical: 2), // 🔧 reduce horizontal margin
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12), // 🔧 reduce internal padding
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
                        child: searchQuery.trim().isNotEmpty
                            ? ListView(
                                children: filteredExercises.map((ex) {
                                  final name = ex['name']!;
                                  final isChecked = tempSelected.contains(name);
                                  return CheckboxListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 10), // 🔧 tighter spacing
                                    dense: true, // ✅ less vertical space
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
        ) ;


    if (selected == null) {
      // User tapped Cancel → keep existing exercises untouched.
      return;
    }

    setState(() {
      _selectedExercisesWithCircuits.clear();
      _selectedExercisesWithCircuits.addAll(
        selected.map((name) => {
          'name': name,
          'circuitIndex': 0,
        }),
      );

      _workoutSets.clear();
      _workoutSets.addAll(
        List.generate(
          _selectedExercisesWithCircuits.length,
              (_) => List.generate(_defaultSets, (_) => SetDetails()),
        ),
      );

      _initializeControllers();
      _populateVelocityFlags();
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
        .map((doc) => {
              'id': doc.id,
              'name': doc['name'] as String,
              'category': doc['category'] as String,
            })
        .toList();

    final Map<String, String> nameToIdMap = {
      for (final ex in allExercises) ex['name']!: ex['id']!,
    };

    bool showPlannedOnly = true;
    final Map<String, bool> expandedGroups = {};
    String searchQuery = '';

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (context, setLocalState) {
          List<Widget> _buildExerciseList() {
            final filteredExercises = (showPlannedOnly && plannedModeAvailable)
                ? allExercises
                    .where((ex) => plannedExercises.contains(ex['id']))
                    .toList()
                : allExercises;

            final searched = searchQuery.isNotEmpty
                ? filteredExercises
                    .where(
                        (ex) => ex['name']!.toLowerCase().contains(searchQuery))
                    .toList()
                : filteredExercises;

            if (searchQuery.isNotEmpty) {
              return searched
                  .map((ex) => ListTile(
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
                    onTap: () => setLocalState(
                        () => expandedGroups[category] = !isExpanded),
                  ),
                  if (isExpanded)
                    ...exercises.map((name) => ListTile(
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
                horizontal: 24, vertical: 2), // 🔧 reduce horizontal margin
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 12), // 🔧 reduce internal padding
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
      setState(() {
        _selectedExercisesWithCircuits[index]['name'] = selected;
        _populateVelocityFlags();
      });
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

      // Insert at new position
      _selectedExercisesWithCircuits.insert(newIndex, movedExercise);
      _workoutSets.insert(newIndex, movedSets);
      _repsControllers.insert(newIndex, movedReps);
      _weightControllers.insert(newIndex, movedWeight);
      _rirControllers.insert(newIndex, movedRir);
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
        final repsText     = _repsControllers[i][j].text.trim();
        final weightText   = _weightControllers[i][j].text.trim();
        final rirText      = _rirControllers[i][j].text.trim();
        final velocityText = _velocityControllers[i][j].text.trim();
        final notesText    = _notesControllers[i][j].text.trim();

        _workoutSets[i][j].reps     = repsText.isNotEmpty     ? int.tryParse(repsText)       : null;
        _workoutSets[i][j].weight   = weightText.isNotEmpty   ? double.tryParse(weightText)  : null;
        _workoutSets[i][j].rir      = rirText.isNotEmpty      ? double.tryParse(rirText)     : 0.0; // default 0
        _workoutSets[i][j].velocity = velocityText.isNotEmpty ? double.tryParse(velocityText): null;
        _workoutSets[i][j].notes    = notesText.isNotEmpty    ? notesText                    : null;
      }
    }

    final exercises = <Map<String, dynamic>>[];

    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      final nameRaw      = (_selectedExercisesWithCircuits[i]['name'] as String?) ?? 'Unnamed';
      final name         = nameRaw.trim().isEmpty ? 'Unnamed' : nameRaw.trim();
      final circuitIndex = _selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0;
      final key          = _exerciseKey(name, circuitIndex);

      // Only count sets with BOTH weight & reps as training sets.
      // (Optionally keep velocity/notes-only rows if desired.)
      final setsWithData = _workoutSets[i].where((s) {
        final reps   = s.reps ?? 0;
        final w      = s.weight ?? 0.0;
        final hasWR  = reps > 0 && w > 0; // strict gate
        final hasOther = ((s.velocity ?? 0.0) > 0) || ((s.notes ?? '').trim().isNotEmpty);
        return hasWR || hasOther;
      }).toList();

      if (setsWithData.isEmpty) continue; // “No data gets nothing saved”

      final ex = <String, dynamic>{
        'name': name,
        'circuitIndex': circuitIndex,
        'sets': setsWithData.map((s) => {
          'reps': s.reps ?? 0,
          'weight': s.weight ?? 0.0,
          'rir': s.rir ?? 0.0, // assume 0 when not entered
          if (s.velocity != null) 'velocity': s.velocity,
          if ((s.notes ?? '').trim().isNotEmpty) 'notes': s.notes,
        }).toList(),
      };

      // Saved-format marker:
      // - On global Save -> only if exercise has at least one set with BOTH weight & reps
      // - Otherwise -> respect per-exercise "Done" state
      final bool markThisSaved = markAllSaved
          ? _hasSetWithWeightAndReps(i)
          : _savedExerciseKeysForDate.contains(key);

      if (markThisSaved) {
        ex['saved']  = true;              // optional boolean
        ex['savedAt'] = Timestamp.now();  // ✅ allowed inside arrays
      }

      exercises.add(ex);
    }

    return {
      'name': _workoutNameController.text.trim().isEmpty
          ? _formatWorkoutDate(_selectedDate)
          : _workoutNameController.text.trim(),
      'date': _selectedDate.toIso8601String(),
      'userId': uid,                           // 👈 no context used
      'exercises': exercises,                  // replaces entire array on set()
      'lastEditedAt': FieldValue.serverTimestamp(),
    };
  }


  Future<void> _pushTopSetsToBlockDataIfAny() async {
    final uid = UserContext.of(context, listen: false).currentUid ?? FirebaseAuth.instance.currentUser?.uid;
    final blockId = _selectedBlockId ?? widget.blockId; // prefer selected, fallback to prop
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

    final daysSinceStart = _selectedDate.difference(blockStart).inDays;
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
      final name = (_selectedExercisesWithCircuits[i]['name'] as String?)?.trim() ?? 'Unnamed';
      final circuitIndex = _selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0;
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
        final prevE = calculateE1RM(prev.weight, prev.reps?.toDouble(), prev.rir);
        final currE = calculateE1RM(curr.weight, curr.reps?.toDouble(), curr.rir);
        return currE > prevE ? curr : prev;
      });

      if (best == null || best.weight == null || best.reps == null) continue;

      final topSet = <String, dynamic>{
        'name': name,
        'circuitIndex': circuitIndex,
        'weight': best.weight,
        'reps': best.reps,
        'rir': best.rir ?? 0.0,
      };
      if ((best.velocity ?? 0) > 0) topSet['velocity'] = best.velocity;
      if ((best.notes ?? '').toString().trim().isNotEmpty) topSet['notes'] = best.notes;

      updatedExercises.add(topSet);
    }

    if (updatedExercises.isEmpty) {
      print('🔸 [BB2 Push] No valid top sets to push.');
      return;
    }

    // Merge with existing day doc, keeping highest E1RM per exercise
    final dayDocRef = weekDocRef.collection('days').doc('day_$dayIndex');
    final existingSnap = await dayDocRef.get();
    final List<Map<String, dynamic>> existing =
    List<Map<String, dynamic>>.from(existingSnap.data()?['exercises'] ?? []);

    for (final newEx in updatedExercises) {
      final idx = existing.indexWhere((e) =>
      (e['name'] as String?)?.trim() == (newEx['name'] as String?)?.trim() &&
          (e['circuitIndex'] ?? 0) == (newEx['circuitIndex'] ?? 0));

      if (idx == -1) {
        existing.add(newEx);
      } else {
        final oldE = calculateE1RM(existing[idx]['weight'],
            (existing[idx]['reps'] as num?)?.toDouble(), existing[idx]['rir']);
        final newE = calculateE1RM(newEx['weight'],
            (newEx['reps'] as num?)?.toDouble(), newEx['rir']);
        if (newE > oldE) existing[idx] = newEx;
      }
    }

    await dayDocRef.set({'exercises': existing}, SetOptions(merge: true));
    print('✅ [BB2 Push] Wrote top sets for week_$weekIndex/day_$dayIndex');
  }


  Future<void> _upsertWorkoutToFirestore({
    required bool alsoPushToBB2,
    bool markAllSaved = false,
  }) async {
    print('🚀 [WES upsert] Starting upsert (markAllSaved=$markAllSaved, pushBB2=$alsoPushToBB2)');

    // Ensure controllers → _workoutSets are in sync for the first-exit case
    await _persistDraftLocally();

    // Resolve the acting UID WITHOUT using context (dispose-safe)
    final uid = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      print('❌ [WES upsert] No UID found — aborting.');
      return;
    }

    final docId = _workoutDocIdForDate(_selectedDate);
    final coll = FirebaseFirestore.instance.collection('users').doc(uid).collection('workouts');
    final docRef = coll.doc(docId);

    // ⬇️ NEW: read existing doc so we can preserve previously-completed entries if user clears fields
    final existingSnap = await docRef.get();
    final List<Map<String, dynamic>> existingExercises =
    List<Map<String, dynamic>>.from(existingSnap.data()?['exercises'] ?? const []);
    final bool hadExisting = existingExercises.isNotEmpty;

    Map<String, dynamic> payload;
    try {
      payload = _buildWorkoutPayload(markAllSaved: markAllSaved, uid: uid);
    } catch (e, st) {
      print('❌ [WES upsert] Payload build threw (likely context access in builder): $e');
      print(st);
      return;
    }

    // What the user typed this visit (only sets with BOTH weight & reps, per your builder)
    final List<Map<String, dynamic>> newExercises =
    List<Map<String, dynamic>>.from((payload['exercises'] as List?) ?? const []);
    print('📦 [WES upsert] Built payload: newExercises=${newExercises.length} (hadExisting=$hadExisting)');

    // Helper key for matching (same fields you already use elsewhere)
    String exKey(Map e) => '${(e['name'] ?? '').toString().trim()}|${e['circuitIndex'] ?? 0}';

    // If user cleared everything this visit:
    // - If there was an existing workout → DO NOT overwrite; keep existing as-is (skip write)
    // - If there was nothing before → keep current behavior (write/clear as needed)
    if (newExercises.isEmpty) {
      if (hadExisting) {
        print('🔸 [WES upsert] User left insufficient data; preserving existing workout (no write).');
        _pendingChanges = false;
        _lastSavedHash = null;
        await _persistSavedFlagsLocally();
        await _persistDraftLocally();
        return; // ← early exit: do not clobber existing doc
      }

      // No new data and no existing → write minimal empty doc (unchanged behavior)
      print('🔸 [WES upsert] No exercises with data AND no existing — writing empty shell.');
      try {
        await docRef.set({
          'name': _workoutNameController.text.trim().isEmpty
              ? _formatWorkoutDate(_selectedDate)
              : _workoutNameController.text.trim(),
          'date': _selectedDate.toIso8601String(),
          'userId': uid,
          'exercises': <Map<String, dynamic>>[],
          'lastEditedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: false));
        print('✅ [WES upsert] Wrote empty exercises array.');

        _pendingChanges = false;
        _lastSavedHash = null;
        _savedExerciseKeysForDate.clear();
        await _persistSavedFlagsLocally();
        await _persistDraftLocally();
      } catch (e, st) {
        print('❌ [WES upsert] Failed to write empty shell: $e'); print(st);
      }
      return;
    }

    // NEW: Merge logic — replace only the entries the user actually edited this visit,
    // and keep any existing ones that the user *cleared* (so they aren't deleted).
    final merged = <Map<String, dynamic>>[];

    // Build a set of keys present in this visit
    final Set<String> newKeys = newExercises.map(exKey).toSet();

    // 1) Start with the new/edited ones (these will override existing)
    merged.addAll(newExercises);

    // 2) Add back any existing entries not touched/updated this visit
    for (final e in existingExercises) {
      if (!newKeys.contains(exKey(e))) {
        merged.add(e);
      }
    }

    // Install merged list back into payload before hashing/writing
    payload['exercises'] = merged;

    final currentHash = payload.hashCode.toString();
    if (_lastSavedHash == currentHash) {
      print('🔸 [WES upsert] Payload unchanged from last save — skipping Firestore write.');
      return;
    }

    try {
      print('📝 [WES upsert] Writing doc $docId for uid=$uid (merged=${merged.length})...');
      await docRef.set(payload, SetOptions(merge: false));
      print('✅ [WES upsert] Firestore write complete.');

      _lastSavedHash = currentHash;
      _pendingChanges = false;

      if (alsoPushToBB2) {
        print('📤 [WES upsert] Pushing top sets to BB2...');
        await _pushTopSetsToBlockDataIfAny();
        print('✅ [WES upsert] BB2 push complete.');
      }

      await _persistSavedFlagsLocally();
      await _persistDraftLocally();
    } catch (e, st) {
      print('❌ [WES upsert] Firestore write failed: $e'); print(st);
    }
  }




  bool _isExerciseSaved(int index) {
    if (index < 0 || index >= _selectedExercisesWithCircuits.length) return false;

    final name = (_selectedExercisesWithCircuits[index]['name'] as String?)?.trim() ?? 'Unnamed';
    final circuitIndex = _selectedExercisesWithCircuits[index]['circuitIndex'] ?? 0;

    final key = _exerciseKey(name, circuitIndex); // 👈 you already have this helper from earlier steps

    return _savedExerciseKeysForDate.contains(key);
  }

  Future<void> _markExerciseSaved(int index) async {
    if (index < 0 || index >= _selectedExercisesWithCircuits.length) return;

    final name = (_selectedExercisesWithCircuits[index]['name'] as String?)?.trim() ?? 'Unnamed';
    final circuitIndex = _selectedExercisesWithCircuits[index]['circuitIndex'] ?? 0;

    // ✅ Gate on live controller text so it works immediately as the user types
    if (!_hasTypedWeightAndRepsInAnySet(index)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add weight and reps to at least one set first.')),
        );
      }
      return;
    }

    setState(() {
      _savedExerciseKeysForDate.add(_exerciseKey(name, circuitIndex));
    });
    await _persistSavedFlagsLocally();

    // Upsert just like autosave; this will include savedAt for this exercise
    await _upsertWorkoutToFirestore(alsoPushToBB2: true, markAllSaved: false);
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
      await prefs.setStringList(_savedFlagsPrefsKey(), _savedExerciseKeysForDate.toList());
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
      final name = (_selectedExercisesWithCircuits[i]['name'] as String?)?.trim() ?? 'Unnamed';
      final circuitIndex = _selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0;
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



  Future<void> _saveWorkout() async {
    // 1) Mark every eligible exercise as "saved format" locally (strict: weight+reps in SAME set)
    int eligibleCount = 0;

    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      final name = (_selectedExercisesWithCircuits[i]['name'] as String?)?.trim() ?? 'Unnamed';
      final circuitIndex = _selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0;

      bool eligible = false;
      if (i < _weightControllers.length && i < _repsControllers.length) {
        final len = _weightControllers[i].length;
        for (int j = 0; j < len; j++) {
          final w = double.tryParse(_weightControllers[i][j].text.trim()) ?? 0.0;
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
    await _upsertWorkoutToFirestore(alsoPushToBB2: true, markAllSaved: true);

    // 3) UI hint
    if (mounted) {
      final msg = (eligibleCount > 0)
          ? 'Saved. $eligibleCount exercise${eligibleCount == 1 ? '' : 's'} marked Done.'
          : 'Brah you gotta do some work first, enter at least one set.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      setState(() {}); // refresh saved-format visuals
    }
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
    final prefs = await SharedPreferences.getInstance();
    final dateKey =
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
    final draftKey = 'workout_draft_$dateKey';
    final timestampKey = 'draft_last_saved_$dateKey';

    final workoutDraft = {
      'name': _workoutNameController.text,
      'date': _selectedDate.toIso8601String(),
      'exercises': _selectedExercisesWithCircuits,
      'sets': _workoutSets.map((setsForExercise) {
        return setsForExercise
            .map((set) => {
                  'reps': set.reps,
                  'weight': set.weight,
                  'rir': set.rir,
                })
            .toList();
      }).toList(),
    };

    await prefs.setString(
        draftKey, jsonEncode(workoutDraft)); // ✅ actually save the draft
    await prefs.setString(
        timestampKey, DateTime.now().toIso8601String()); // ✅ save timestamp

    print("[WES] Draft saved for $_selectedDate under key: $draftKey");
  }

  Future<bool> _loadWorkoutDraftFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final dateKey =
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
    final draftKey = 'workout_draft_$dateKey';
    final timestampKey = 'draft_last_saved_$dateKey';

    final draftJson = prefs.getString(draftKey);
    final savedAtString = prefs.getString(timestampKey);

    if (draftJson == null || savedAtString == null) {
      print('[WES] No draft found for $dateKey.');
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
          print('[WES] Draft expired, but kept ${filteredExercises.length} non-empty exercises.');
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

        _workoutSets.add(setList
            .map((s) => SetDetails(
                  reps: s['reps'],
                  weight: (s['weight'] as num?)?.toDouble(),
                  rir: (s['rir'] as num?)?.toDouble(),
                ))
            .toList());

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
          '[WES] Loaded draft (expired=$isExpired, kept=${filteredExercises.length})');

      return true;
    } catch (e) {
      debugPrint('[WES] Failed to load workout draft for $dateKey: $e');
      return false;
    }
  }



  Future<void> _mergeNewBB2ExercisesIntoDraft() async {
    print('[WES] Attempting to merge BB2 exercises into draft for $_selectedDate');

    final uid = UserContext.of(context, listen: false).currentUid;
    if (_selectedBlockId == null || _selectedDate == null) return;

    print('👤 [BB2 Merge] Using uid=$uid for athlete merge');

    // ✅ Clear state only if the selected athlete or date has changed
    final shouldForceMerge = _lastMergedUid != uid || _lastMergedDate != _selectedDate;
    if (shouldForceMerge) {
      print('🔁 [WES] Triggering BB2 merge due to athlete/date switch');
      setState(() {
        _selectedExercisesWithCircuits.clear();
        _workoutSets.clear();
        _repsControllers.clear();
        _weightControllers.clear();
        _rirControllers.clear();
        _velocityControllers.clear();
        _notesControllers.clear();
        _resolvedBB2Values.clear();
      });
      _lastMergedUid = uid;
      _lastMergedDate = _selectedDate;
    }

    _attachDirtyListeners(); // keep controllers wired

    final blockId = _selectedBlockId!;
    final daysSinceStart = _selectedDate.difference(blockStartDate!).inDays;
    if (daysSinceStart < 0) return;
    print('[WES Merge] daysSinceStart = $daysSinceStart');

    final weekIndex = (daysSinceStart / 7).floor();
    final dayIndex  = daysSinceStart % 7;

    // 1) Primary: planned_blocks weeks/days
    // ── Try modern BB2 source: weeks > days (server first, then cache) ──
    final dayDocRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId)
        .collection('weeks')
        .doc('week_$weekIndex')
        .collection('days')
        .doc('day_$dayIndex');

    final dayDocServer = await dayDocRef.get(const GetOptions(source: Source.server));
    final dayDocCache  = await dayDocRef.get(const GetOptions(source: Source.cache));

    List<Map<String, dynamic>> bb2Exercises = [];

    if (dayDocServer.exists && dayDocServer.data()?['exercises'] != null) {
      bb2Exercises = List<Map<String, dynamic>>.from(dayDocServer.data()!['exercises']);
      print('[WES] BB2 day doc (SERVER) exercises: ${bb2Exercises.length}');
    } else if (dayDocCache.exists && dayDocCache.data()?['exercises'] != null) {
      bb2Exercises = List<Map<String, dynamic>>.from(dayDocCache.data()!['exercises']);
      print('[WES] BB2 day doc (CACHE) exercises: ${bb2Exercises.length}');
    } else {
      print('[WES] BB2 day doc missing in both SERVER and CACHE for week_$weekIndex/day_$dayIndex');
    }

// ── Fallback: block_data (server first, then cache) ──
    if (bb2Exercises.isEmpty) {
      final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final blockDataRef = FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks')
          .doc(blockId)
          .collection('block_data')
          .doc(dateKey);

      final blockDataServer = await blockDataRef.get(const GetOptions(source: Source.server));
      if (blockDataServer.exists && blockDataServer.data()?['rows'] != null) {
        bb2Exercises = List<Map<String, dynamic>>.from(blockDataServer.data()!['rows']);
        print('[WES] BB2 fallback (block_data SERVER) rows: ${bb2Exercises.length}');
      } else {
        final blockDataCache = await blockDataRef.get(const GetOptions(source: Source.cache));
        if (blockDataCache.exists && blockDataCache.data()?['rows'] != null) {
          bb2Exercises = List<Map<String, dynamic>>.from(blockDataCache.data()!['rows']);
          print('[WES] BB2 fallback (block_data CACHE) rows: ${bb2Exercises.length}');
        }
      }
    }

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

    final existingKeys = _selectedExercisesWithCircuits
        .map<String>((e) => _exerciseKey(
      ((e['name'] ?? '') as String).trim(),
      (e['circuitIndex'] ?? 0) as int,
    ))
        .toSet();

    final newOnes = bb2Exercises.where((ex) => !existingKeys.contains(_k(ex))).toList();
    print('[WES] Found ${newOnes.length} new exercises to merge');

    if (newOnes.isNotEmpty) {
      setState(() {
        for (final newEx in newOnes) {
          final name = (newEx['name'] ?? '').toString().trim();
          final circuitIndex = (newEx['circuitIndex'] ?? 0) as int;

          _selectedExercisesWithCircuits.add({
            'name': name,
            'circuitIndex': circuitIndex,
          });

          _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
          _repsControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _weightControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _rirControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _velocityControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _notesControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
        }
      });

      // Seed initial values for newly added rows (prefer flat; else sets[0])
      for (final newEx in newOnes) {
        final nameKey = (newEx['name'] ?? '').toString().trim().toLowerCase();
        if (nameKey.isEmpty || _resolvedBB2Values.containsKey(nameKey)) continue;

        final flatReps   = newEx['reps'];
        final flatWeight = newEx['weight'];
        final flatRir    = newEx['rir'];

        if (flatReps != null || flatWeight != null || flatRir != null) {
          _resolvedBB2Values[nameKey] = {
            'reps': flatReps,
            'weight': flatWeight,
            'rir': flatRir,
          };
          print('🧠 [WES Merge] Injected FLAT BB2 values for $nameKey = ${_resolvedBB2Values[nameKey]}');
          continue;
        }

        final rawSets = newEx['sets'];
        if (rawSets is List && rawSets.isNotEmpty) {
          final firstSet = Map<String, dynamic>.from(rawSets.first as Map);
          _resolvedBB2Values[nameKey] = {
            'reps': firstSet['reps'],
            'weight': firstSet['weight'],
            'rir': firstSet['rir'],
          };
          print('🧠 [WES Merge] Injected SETS[0] BB2 values for $nameKey = ${_resolvedBB2Values[nameKey]}');
        } else {
          // Even if there are no numbers, keep the exercise row so the user can edit it.
          _resolvedBB2Values[nameKey] = {
            'reps': null,
            'weight': null,
            'rir': null,
          };
          print('ℹ️ [WES Merge] No values found for $nameKey — seeding empty controllers');
        }

// ⬇️ INSERT HYDRATION BLOCK HERE
        if (_resolvedBB2Values.containsKey(nameKey)) {
          final values = _resolvedBB2Values[nameKey]!;
          final idx = _selectedExercisesWithCircuits.indexWhere((e) =>
          (e['name'] as String).trim().toLowerCase() == nameKey);

          if (idx != -1) {
            final sets = _workoutSets[idx];
            if (sets.isNotEmpty) {
              sets[0].reps = (values['reps'] as num?)?.toInt();
              sets[0].weight = (values['weight'] as num?)?.toDouble();
              sets[0].rir = (values['rir'] as num?)?.toDouble();
            }

            if (_repsControllers.length > idx && _repsControllers[idx].isNotEmpty) {
              _repsControllers[idx][0].text = values['reps']?.toString() ?? '';
              _weightControllers[idx][0].text = values['weight']?.toString() ?? '';
              _rirControllers[idx][0].text = values['rir']?.toString() ?? '';
            }
          }
        }
      }

      print('[WES] Merged ${newOnes.length} exercise(s) into draft');
      await _saveWorkoutDraftToCache();
    }
  }

  void addSet(int exerciseIndex) {
    setState(() {
      // 0) Make sure the outer row exists for every parallel structure
      while (_workoutSets.length <= exerciseIndex) _workoutSets.add(<SetDetails>[]);
      while (_repsControllers.length <= exerciseIndex) _repsControllers.add(<TextEditingController>[]);
      while (_weightControllers.length <= exerciseIndex) _weightControllers.add(<TextEditingController>[]);
      while (_rirControllers.length <= exerciseIndex) _rirControllers.add(<TextEditingController>[]);
      while (_velocityControllers.length <= exerciseIndex) _velocityControllers.add(<TextEditingController>[]);
      while (_notesControllers.length <= exerciseIndex) _notesControllers.add(<TextEditingController>[]);

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
  }


  void removeSet(int exerciseIndex, int setIndex) {
    setState(() {
      // Check if only one set remains and confirm removal
      if (_workoutSets[exerciseIndex].length == 1) {
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
                    setState(() {
                      _selectedExercisesWithCircuits.removeAt(exerciseIndex);
                      _workoutSets.removeAt(exerciseIndex);
                      _repsControllers.removeAt(exerciseIndex);
                      _weightControllers.removeAt(exerciseIndex);
                      _rirControllers.removeAt(exerciseIndex);
                    });
                    Navigator.of(context).pop();
                  },
                  child: const Text('Yes'),
                ),
              ],
            );
          },
        );
      } else {
        // Remove the specific set at setIndex
        _workoutSets[exerciseIndex].removeAt(setIndex);
        _repsControllers[exerciseIndex].removeAt(setIndex);
        _weightControllers[exerciseIndex].removeAt(setIndex);
        _rirControllers[exerciseIndex].removeAt(setIndex);

        // Re-initialize controllers for consistent UI behavior
        _initializeControllers();
      }
    });
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
    );

    if (pickedDate == null || pickedDate == _selectedDate) {
      print('⛔️ [WES] Date selection cancelled or unchanged');
      return;
    }

    print('📆 [WES] Date changed to: ${DateFormat('yyyy-MM-dd').format(pickedDate)}');

    _cachedProgressedValues.clear(); // ✅ Main fix

    // ⭐ NEW: autosave current day (and push BB2) before switching
    if (mounted) {
      print('💾 [WES] Autosaving current date before switch…');
      await _upsertWorkoutToFirestore(alsoPushToBB2: true, markAllSaved: false);
    }

    await _persistDraftLocally(); // ✅ Save previous date before switching
    await _persistSavedFlagsLocally(); // ⭐ NEW: persist done flags for current date

    // 2️⃣ Update selected date and clear UI state
    print('🧼 [WES] Clearing UI and updating selected date...');
    setState(() {
      _selectedDate = pickedDate;
      _workoutNameController.text = _formatWorkoutDate(_selectedDate);

      // Clear exercise + controllers (include all controller families)
      _selectedExercisesWithCircuits.clear();
      _workoutSets.clear();
      _repsControllers.clear();
      _weightControllers.clear();
      _rirControllers.clear();
      _velocityControllers.clear();   // ⭐ NEW: ensure cleared
      _notesControllers.clear();      // ⭐ NEW: ensure cleared

      _resolvedBB2Values.clear();

      // Per-date runtime state resets
      _savedExerciseKeysForDate.clear(); // ⭐ NEW: we'll rehydrate for new date
      _pendingChanges = false;           // ⭐ NEW
      _lastSavedHash = null;             // ⭐ NEW: force fresh write on new date
    });

    // 3️⃣ Load locally saved draft (if available)
    print('📂 [WES] Attempting to load local draft for new date...');
    await _loadDraftLocallyIfAvailable();

    // 4️⃣ Merge in BB2 exercises (primary loader)
    print('🔁 [WES] Merging in BB2 exercises for selected date...');
    await _mergeNewBB2ExercisesIntoDraft();

    // 5️⃣ Rehydrate saved/done flags + overlay Firestore sets for the NEW date
    print('🔄 [WES] Loading existing workout (Firestore + local flags) for new date…');
    await _loadExistingWorkoutIfAny(); // ⭐ NEW: brings back savedAt + sets for picked date

    // 6️⃣ (Optional) ensure listeners are attached in case controllers resized
    _attachDirtyListeners(); // ⭐ NEW: safe no-op if already attached

    // 7️⃣ Visual hints if you use them
    print('🔍 [WES] Loading BB2 read-only visual hints...');
    // await _loadExercisesFromBB2ForDay();

    print('✅ [WES] Date switch complete.');
  }


  String _formatWorkoutDate(DateTime date) {
    final dayOfWeek = DateFormat('EEEE').format(date); // e.g., Tuesday
    final day = date.day; // 29
    final month = DateFormat('MMMM').format(date); // April
    final year = date.year; // 2025

    return '$dayOfWeek $day $month $year';
  }

  void _navigateToExerciseDetails(String exerciseName) async {
    // fetch workouts as before
    List<Workout> recentWorkouts =
    await getRecentWorkoutsForExercise(exerciseName, _selectedDate);

    if (recentWorkouts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No recent workouts found for this exercise.')),
      );
      return;
    }

    // ✅ find the ID of the exercise from the most recent workout
    final firstWithExercise = recentWorkouts.firstWhere(
          (w) => w.exercises.any((ex) => ex.name == exerciseName),
    );
    final exercise = firstWithExercise.exercises
        .firstWhere((ex) => ex.name == exerciseName);

    final exerciseId = exercise.id ?? exerciseName;
    // 👆 fallback to name if your Exercise model doesn’t yet expose `id`

    print('➡️ [WES] Push ExerciseDetailsScreen id="${exercise.id}" name="${exercise.name}"');
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExerciseDetailsScreen(
          exerciseId: exerciseId,
          exerciseName: exerciseName,        // optional, but good for title
        ),
      ),
    );
  }


  void _navigateToTopSets(String exerciseName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('workouts')
        .orderBy('date', descending: true)
        .limit(20)
        .get();

    final recentWorkouts = snapshot.docs
        .map((doc) {
          return Workout.fromFirestore(doc);
        })
        .where(
            (workout) => workout.exercises.any((ex) => ex.name == exerciseName))
        .toList();

    if (recentWorkouts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No recent workouts found for this exercise.')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TopSetsScreen(
          exerciseName: exerciseName,
          recentWorkouts: recentWorkouts,
        ),
      ),
    );
  }

  Future<List<Workout>> getRecentWorkoutsForExercise(
      String exerciseName, DateTime currentWorkoutDate) async {
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

  @override
  Widget build(BuildContext context) {

    return FutureBuilder<void>(
        future: _initialLoad, // ✅ only runs once, doesn't re-run on rebuild
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          return WillPopScope(
              onWillPop: () async {
            if (_pendingChanges) {
              await _upsertWorkoutToFirestore(alsoPushToBB2: true, markAllSaved: false);
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
            onPressed: _lastUndoAction != null
                ? () {
                    _lastUndoAction?.call();
                    _lastUndoAction = null;
                  }
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              showDialog(
                context: context,
                builder: (BuildContext context) {
                  return AlertDialog(
                    title: const Text(
                      'Clear Workout',
                      style:
                          TextStyle(fontFamily: 'Verdana', color: Colors.white),
                    ),
                    content: const Text(
                      'Delete this workout?',
                      style:
                          TextStyle(fontFamily: 'Verdana', color: Colors.white),
                    ),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _workoutNameController.clear();
                            _selectedExercisesWithCircuits.clear();
                            _workoutSets.clear();
                            _initializeControllers();
                          });
                          Navigator.of(context).pop();
                        },
                        child: const Text('Yes'),
                      ),
                    ],
                  );
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveWorkout,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(left: 12, top: 0, right: 12, bottom: 0),
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
                fillColor: Colors.blueGrey.shade900, // ✅ works now
                border: OutlineInputBorder(borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(
                    vertical: 10, horizontal: 12), // 👈 Tighten spacing
              ),
            ),
// 🆕 Add a non-editable display of the workout date
            // 🆕 Date displayed below, uneditable

            Padding(
              padding: const EdgeInsets.only(
                  left: 8.0, bottom: 7.0), // 👈 shifts it to the right
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
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text("Add Exercises",
                          style: TextStyle(fontSize: 14)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 8),
                      ),
                      onPressed: _showExercisePickerDialog,
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
            if (_selectedExercisesWithCircuits.isEmpty)
              Column(
                children: [
                  Text(
                    'No exercises selected yet. Add some to get started.',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const SizedBox(height: 6),
                ],
              )
            else
              ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                onReorder: _onReorderExercises,
                children: List.generate(_selectedExercisesWithCircuits.length, (i) {
                  // 🛡 Defensive check for list mismatches
                  if (i >= _selectedExercisesWithCircuits.length ||
                      i >= _workoutSets.length ||
                      i >= _repsControllers.length ||
                      i >= _weightControllers.length ||
                      i >= _rirControllers.length) {
                    print("⚠️ Skipping index $i due to mismatched list lengths");
                    return  SizedBox(
                      key: ValueKey('skipped_$i'), // 🔑 Ensure even placeholder has a key
                    );
                  }

                  final current = _selectedExercisesWithCircuits[i];
                  final prev = i > 0 ? _selectedExercisesWithCircuits[i - 1] : null;
                  final isNewCircuit = i == 0 || current['circuitIndex'] != prev?['circuitIndex'];

                  return Column(
                    key: ValueKey("column_$i"), // 🔑 Required for ReorderableListView
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isNewCircuit)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                          child: Text(
                            'Circuit ${current['circuitIndex'] + 1}',
                            style: const TextStyle(
                              color: Colors.lightBlueAccent,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      Dismissible(
                        key: ValueKey(current['name']),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Colors.red,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        onDismissed: (_) {
                          final removedExercise =
                              _selectedExercisesWithCircuits[i];
                          final removedSets = _workoutSets[i];
                          final removedReps = _repsControllers[i];
                          final removedWeight = _weightControllers[i];
                          final removedRIR = _rirControllers[i];

                          setState(() {
                            _selectedExercisesWithCircuits.removeAt(i);
                            _workoutSets.removeAt(i);
                            _repsControllers.removeAt(i);
                            _weightControllers.removeAt(i);
                            _rirControllers.removeAt(i);
                          });

                          _lastUndoAction = () {
                            setState(() {
                              _selectedExercisesWithCircuits.insert(
                                  i, removedExercise);
                              _workoutSets.insert(i, removedSets);
                              _repsControllers.insert(i, removedReps);
                              _weightControllers.insert(i, removedWeight);
                              _rirControllers.insert(i, removedRIR);
                            });
                          };

                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content:
                                  Text('Deleted "${removedExercise['name']}"'),
                              action: SnackBarAction(
                                label: 'Undo',
                                textColor: Colors.blueGrey.shade700,
                                onPressed: () {
                                  _lastUndoAction?.call();
                                  _lastUndoAction = null;
                                },
                              ),
                            ),
                          );
                        },
    child: FutureBuilder<void>(
        future: _initialLoad, // ✅ Wait for full blockMeta + data load
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Padding(
          padding: EdgeInsets.all(8),
          child: SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        );
      }
      print("⏱️ [WES Row Delay] Delay complete for row $i — blockStartDate = $_blockStartDate");

      final bool isSaved = _isExerciseSaved(i);

      return Card(

        key: ValueKey("card_$i"),
        // 👈 Unique per exercise
        color: Colors.blueGrey.shade700,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(3),
        ),
        margin: const EdgeInsets.only(left: 0, top: 2, right: 0, bottom: 0),

        child: ExpansionTile(
          key: ValueKey('wes_ex_tile_${i}_${isSaved ? 'saved' : 'live'}'), // force rebuild when state flips
          initiallyExpanded: !isSaved, // saved → collapsed by default
          tilePadding: const EdgeInsets.symmetric(horizontal: 8),

          // 🔹 Subtle saved-format background
          backgroundColor: isSaved
              ? Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.6)
              : Theme.of(context).colorScheme.surface,
          collapsedBackgroundColor: isSaved
              ? Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.6)
              : Theme.of(context).colorScheme.surface,

          // Optional: saved gets a friendlier icon tint
          iconColor: isSaved ? Colors.greenAccent : Theme.of(context).iconTheme.color,
          collapsedIconColor: isSaved ? Colors.greenAccent : Theme.of(context).iconTheme.color,

          title: (_selectedExercisesWithCircuits[i]['name'] ?? '').isEmpty
              ? TextButton(
            onPressed: () => _showExercisePickerForRow(i),
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

          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // If already saved → show the green "Saved" pill (as you have now)
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
                      Text('Done', style: TextStyle(fontSize: 11, color: Colors.green)),
                    ],
                  ),
                ),
              ],

              // …keep your existing info + Top Sets buttons…
              IconButton(
                icon: const Icon(Icons.insights),

                color: Colors.lightBlueAccent,
                onPressed: () {
                  _navigateToExerciseDetails(
                      _selectedExercisesWithCircuits[i]['name'] ?? '');
                },
              ),
              const SizedBox(width: 1),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueGrey[700],
                ),
                onPressed: () {
                  _navigateToTopSets(
                      _selectedExercisesWithCircuits[i]['name'] ?? '');
                },
                child: Text(
                  'History',
                  style: TextStyle(
                    fontFamily: 'Verdana',
                    color: Colors.white70
                  ),
                ),
              ),
            ],
          ),


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

            for (int j = 0; j < _workoutSets[i].length; j++)
              Padding(
                padding: const EdgeInsets.only(
                    left: 6, bottom: 0, top: 0, right: 6),
                child: Column(
                  crossAxisAlignment:
                  CrossAxisAlignment.start,
                  children: [
                    if (j == 0) ...[
                      const SizedBox(height: 2),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 1),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisAlignment:
                            MainAxisAlignment
                                .spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment
                                .center, // ✅ Center vertically
                            children: [
                              // ➡️ Previous Rep Targets + Available Rep Targets (on the LEFT)
                              Column(
                                crossAxisAlignment:
                                CrossAxisAlignment.start,
                                children: [
                                  Text(
                                        () {
                                      final exerciseName =
                                          _selectedExercisesWithCircuits[
                                          i]
                                          ['name']
                                              ?.trim() ??
                                              '';
                                      final targetWeight = _isInitialized
                                          ? set1SuggestedWeight(i)
                                          : 20.0;

                                      final history =
                                          PeriodizationModelUtils
                                              .topSetsByExercise[
                                          exerciseName] ??
                                              [];

                                      final matchingSets = history
                                          .where((s) =>
                                      (s['weight']
                                      as double)
                                          .toStringAsFixed(
                                          1) ==
                                          targetWeight
                                              .toStringAsFixed(
                                              1))
                                          .toList();

                                      if (matchingSets
                                          .isEmpty)
                                        return 'No previous sets at ${targetWeight
                                            .toStringAsFixed(1)} kg';

                                      matchingSets
                                          .sort((a, b) {
                                        final repsA =
                                            a['reps'] ?? 0.0;
                                        final repsB =
                                            b['reps'] ?? 0.0;
                                        final rirA =
                                            a['rir'] ?? 99.0;
                                        final rirB =
                                            b['rir'] ?? 99.0;

                                        if (repsB.compareTo(
                                            repsA) !=
                                            0)
                                          return repsB
                                              .compareTo(
                                              repsA);
                                        return rirA
                                            .compareTo(rirB);
                                      });

                                      final best =
                                          matchingSets.first;
                                      final reps =
                                      best['reps'];
                                      final rir = best['rir'];

                                      return 'Best at ${targetWeight
                                          .toStringAsFixed(
                                          1)} kg: $reps reps @ RIR $rir';
                                    }(),
                                    style: const TextStyle(
                                      fontSize: 10.0,
                                      fontWeight:
                                      FontWeight.bold,
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

                                      final exerciseName = _selectedExercisesWithCircuits[i]['name']
                                          ?.trim() ?? '';
                                      final repTarget = set1SuggestedReps(
                                          i); // no `.round()` yet

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

                                      final roundedTarget = repTarget.round();
                                      final history = PeriodizationModelUtils
                                          .topSetsByExercise[exerciseName] ??
                                          [];

                                      final matchingSets = history.where((s) {
                                        final reps = (s['reps'] as num?)
                                            ?.round();
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
                                      final weight = best['weight'];
                                      final rir = best['rir'];

                                      return Text(
                                        'Best at $repTarget reps: ${weight
                                            .toStringAsFixed(1)} kg @ RIR ${rir
                                            .toString()}',
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
                                  width:
                                  12),
                              // ✅ Optional spacing between sections

                              // ➡️ Avg E1RM (on the RIGHT)
                              Text(
                                'Avg E1RM: ${getAverageE1RM(
                                    _selectedExercisesWithCircuits[i]['name'] ??
                                        '').toStringAsFixed(1)}Kg',
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
                        MainAxisAlignment.spaceBetween,
                        crossAxisAlignment:
                        CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(
                                left: 4, top: 5),
                            child: Text(
                              'Set ${j + 1}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12.0,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                          Container(
                            padding:
                            const EdgeInsets.only(top: 2),
                            child: IconButton(
                              icon: const Icon(Icons.remove),
                              iconSize: 18,
                              padding: EdgeInsets.zero,
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
                      scrollDirection: Axis.horizontal,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 🟨 Header Row (per exercise row)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(
                                width: 68,
                                child: Padding(
                                  padding: EdgeInsets.only(left: 3),
                                  child: Text('Weight', style: _headerStyle),
                                ),
                              ),
                              const SizedBox(width: 4),

                              const SizedBox(
                                width: 50,
                                child: Padding(
                                  padding: EdgeInsets.only(left: 2),
                                  child: Text('Reps', style: _headerStyle),
                                ),
                              ),
                              const SizedBox(width: 4),

                              const SizedBox(
                                width: 50,
                                child: Padding(
                                  padding: EdgeInsets.only(left: 3),
                                  child: Text('RIR', style: _headerStyle),
                                ),
                              ),
                              const SizedBox(width: 4),



                              const SizedBox(width: 55, child: Text('E1RM', style: _headerStyle)),
                              const SizedBox(width: 4),

                              // ✅ Conditionally include Velocity (for this exercise only)
                              if (_showVelocityByExercise[
                              (_selectedExercisesWithCircuits[i]['name'] as String).toLowerCase()] ==
                                  true) ...[
                                const SizedBox(width: 45, child: Text('Vel.', style: _headerStyle)),
                                const SizedBox(width: 4),
                              ],
                              const SizedBox(width: 120, child: Text('Notes', style: _headerStyle)),
                            ],
                          ),



                          const SizedBox(height: 2),

                          // 🟩 Input Row
                          Row(
                            children: [
                              // Weight
                              SizedBox(
                                width: 68,
                                child: TextField(
                                  controller: _weightControllers[i][j],
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    hintText: !_isInitialized
                                        ? ''
                                        : (j == 0)
                                        ? set1SuggestedWeight(i).toStringAsFixed(1)
                                        : (j == 1)
                                        ? set2SuggestedWeight(i).toStringAsFixed(1)
                                        : (j == 2)
                                        ? set3SuggestedWeight(i).toStringAsFixed(1)
                                        : '20',
                                    hintStyle: const TextStyle(
                                      color: Colors.grey,
                                      fontStyle: FontStyle.italic,
                                      fontSize: 12,
                                    ),
                                    contentPadding: const EdgeInsets.only(left: 4),
                                  ),
                                  onChanged: (value) => setState(() {}),
                                  style: TextStyle(
                                    color: _weightControllers[i][j].text.isEmpty ? Colors.grey : Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),

                              // Reps
                              SizedBox(
                                width: 50,
                                child: TextField(
                                  controller: _repsControllers[i][j],
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.only(left: 3),
                                    hintText: (_isLoadingData || !_isInitialized)
                                        ? ''
                                        : (j == 0)
                                        ? (set1SuggestedReps(i)?.toInt().toString() ?? '')
                                        : (j == 1)
                                        ? (set2SuggestedReps(i)?.toInt().toString() ?? '')
                                        : (j == 2)
                                        ? (set3SuggestedReps(i)?.toInt().toString() ?? '')
                                        : '15',
                                    hintStyle: const TextStyle(
                                      color: Colors.grey,
                                      fontStyle: FontStyle.italic,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onChanged: (value) => setState(() {}),
                                  style: TextStyle(
                                    color: _repsControllers[i][j].text.isEmpty ? Colors.grey : Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),

                              // RIR
                              SizedBox(
                                width: 50,
                                child: TextField(
                                  controller: _rirControllers[i][j],
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.only(left: 2),
                                    hintText: (j == 0)
                                        ? set1RIR(i).toString()
                                        : (j == 1)
                                        ? set2RIR(i).toString()
                                        : (j == 2)
                                        ? set3RIR(i).toString()
                                        : '1',
                                    hintStyle: const TextStyle(
                                      color: Colors.grey,
                                      fontStyle: FontStyle.italic,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onChanged: (value) => setState(() {}),
                                  style: TextStyle(
                                    color: _rirControllers[i][j].text.isEmpty ? Colors.grey : Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),



                              // E1RM
                              SizedBox(
                                width: 55,
                                child: TextField(
                                  controller: TextEditingController(
                                    text: calculateE1RM(
                                        double.tryParse(_weightControllers[i][j].text) ??
                                            (j == 0
                                                ? (_isInitialized ? set1SuggestedWeight(i) : 20.0)
                                                : j == 1
                                                ? (_isInitialized ? set2SuggestedWeight(i) : 20.0)
                                                : (_isInitialized ? set3SuggestedWeight(i) : 20.0)),
                                        (int.tryParse(_repsControllers[i][j].text) ??
                                            (j == 0
                                                ? (_isInitialized ? set1SuggestedReps(i).toDouble() : 15.0)
                                                : j == 1
                                                ? (_isInitialized ? set2SuggestedReps(i).toDouble() : 10.0)
                                                : (_isInitialized ? set3SuggestedReps(i).toDouble() : 10.0)))
                                            .toDouble(),
                                        double.tryParse(_rirControllers[i][j].text) ??
                                            (j == 0
                                                ? (_isInitialized ? set1RIR(i) : 0.5)
                                                : j == 1
                                                ? (_isInitialized ? set2RIR(i) : 0.5)
                                                : (_isInitialized ? set3RIR(i) : 0.5)))
                                        .toStringAsFixed(1),
                                  ),
                                  enabled: false,
                                  readOnly: true,
                                  decoration: const InputDecoration(
                                    hintText: '',
                                    hintStyle: TextStyle(
                                      color: Colors.grey,
                                      fontStyle: FontStyle.italic,
                                      fontSize: 12,
                                    ),
                                    contentPadding: EdgeInsets.only(left: 4),
                                    enabledBorder: UnderlineInputBorder(
                                      borderSide: BorderSide(color: Colors.white, width: 1),
                                    ),
                                    disabledBorder: UnderlineInputBorder(
                                      borderSide: BorderSide(color: Colors.white, width: 1),
                                    ),
                                    focusedBorder: UnderlineInputBorder(
                                      borderSide: BorderSide(color: Colors.white, width: 1.5),
                                    ),
                                  ),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: (_weightControllers[i][j].text.isNotEmpty ||
                                        _repsControllers[i][j].text.isNotEmpty ||
                                        _rirControllers[i][j].text.isNotEmpty)
                                        ? Colors.white
                                        : Colors.grey,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),

                              // ✅ Conditionally show Velocity
                              if (_showVelocityByExercise[
                              (_selectedExercisesWithCircuits[i]['name'] as String).toLowerCase()] ==
                                  true) ...[
                                SizedBox(
                                  width: 45,
                                  child: TextField(
                                    controller: _velocityControllers[i][j],
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      hintText: '',
                                      hintStyle: TextStyle(
                                        color: Colors.grey,
                                        fontStyle: FontStyle.italic,
                                        fontSize: 11,
                                      ),
                                    ),
                                    onChanged: (value) => setState(() {}),
                                    style: TextStyle(
                                      color: _velocityControllers[i][j].text.isEmpty ? Colors.grey : Colors.white,
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
                                  keyboardType: TextInputType.text,
                                  decoration: const InputDecoration(
                                    hintText: '',
                                    hintStyle: TextStyle(
                                      color: Colors.grey,
                                      fontStyle: FontStyle.italic,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onChanged: (value) => setState(() {}),
                                  style: TextStyle(
                                    color: _notesControllers[i][j].text.isEmpty ? Colors.grey : Colors.white,
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end, // 👈 pack to the right
                children: [
                  if (!isSaved && _hasTypedWeightAndRepsInAnySet(i)) ...[
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => _markExerciseSaved(i),
                      icon: const Icon(Icons.check_circle_outline, size: 14),
                      label: const Text('Completed?', style: TextStyle(fontSize: 12)),
                    ),
                    const SizedBox(width: 8), // 👈 small gap between Done? and +
                  ],
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () => addSet(i),
                  ),
                ],
              ),
            ),


          ], //paste point
        ),
      );
    }),//old bracket for Card
    )],
                  );
                }),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 12.0),
              child: Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  onPressed: _addNewCircuitExercise,
                  icon: const Icon(Icons.add),
                  label: const Text("Add Circuit"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 55), // after the last exercise card

          ],
        ),
      ),
          )
    );
    });
  }
}
