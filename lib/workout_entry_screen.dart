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
import 'stats_snapshot.dart';
import 'local_cache/block_plan_cache.dart';   // from a file inside lib/
import 'local_cache/workout_day_cache.dart';
import 'local_cache/isar_block_plan.dart';
import 'local_cache/isar_wes_init.dart';
import 'local_cache/isar_db.dart';
import 'package:isar/isar.dart';


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

class _WorkoutPageState extends State<WorkoutPage> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
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
  Map<String, bool> _showVelocityByExercise = {
  }; // exerciseName.toLowerCase() → true/false

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
  final Map<String, Map<String, dynamic>> _cachedProgressedValues = {};
  // Pre-resolved S1 hints from snapshot for instant first paint
  final Map<String, Map<String, dynamic>> _seedHintsByKey = {};

  // Stable key for a row: "name|circuitIndex"
  String _rowKeyBy(int i) {
    final n = (_selectedExercisesWithCircuits[i]['name'] ?? '').toString().trim().toLowerCase();
    final ci = (_selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0) as int;
    return '$n|$ci';
  }



  bool _isLoadingData = true;
  bool _isInitialized = false;


  late Future<void> _initialLoad;
  late Future<void> _blockDateLoad;
  bool _didFastPaint = false;
  bool _bootPaintDone = false;  // prevent double fast-paint
  bool _uiLoggedOnce = false; // debug: only log UI decision once
  bool _overlayLogged = false;
  bool _firstRowsLogged = false;


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
    if (setIdx == 0) {
      final base = _actualE1RMForSet(exIdx, 0);
      print('🧪 [_targetE1RMForSet] setIdx=$setIdx (Set1) '
          '→ baseE1RM=$base (no drop applied)');
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
    print('🧪 [_targetE1RMForSet] setIdx=$setIdx '
        'prevAnyTyped=$prevAnyTyped baseE1RM=$baseE1RM '
        'prevRIR=$prevRIR dropRaw=$dropRaw dropGated=$dropGated '
        '→ target=$target');

    return target;
  }

  // Build ranges + mid for current set
  Future<({List<double> weightRangeDisplay, List<
      int> repsRange, double weightMidDisplay, int repsMid, double e1rmMid})>
  _synthesizeHintsForSet(int exIdx, int setIdx) async {
    assert(setIdx >= 1, 'Range synthesis is for set ≥ 2');

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

    print('🛑 [cap] setIdx=$setIdx prevTyped=$prevTypedDisplay '
        'prevHintMax=$prevHintMaxDisplay prevSuggested=$prevSuggestedDisplay '
        '→ cap=$prevDisplayCap');

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

// (optional) debug
    print(
        '✅ [final-cap] setIdx=$setIdx cap=$cap midDisplay=$weightMidDisplayCapped '
            'reps=$repsMidFinal e1rmMid=$e1rmMidFinal');

// 5) Return capped values
    return (
    weightRangeDisplay: filteredWeightsDisplay,
    repsRange: filteredReps,
    weightMidDisplay: weightMidDisplayCapped,
    repsMid: repsMidFinal,
    e1rmMid: e1rmMidFinal,
    );
  }

  // Formatters for hint text (range or single)
  Future<String> _weightHintText(int exIdx, int setIdx) async {
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

        // center candidates around the same math-based center we use in _synthesizeHintsForSet
        final prevWAbs = _typedOrHintWeightAbs(
            exIdx: exIdx, setIdx: setIdx - 1);
        final rirCurrent = _typedOrHintRIR(exIdx: exIdx, setIdx: setIdx);
        final repsNeeded = PeriodizationModelUtils.reverseCalculateReps(
          targetE1RM: target,
          weight: prevWAbs,
          // anchor at previous ABS weight
          baseWeight: prevWAbs,
          rir: rirCurrent,
          minReps: null,
        ).clamp(1.0, 45.0);

        final int center = repsNeeded.round().clamp(1, 45);
        final candidates = <int>{
          (center - 1).clamp(1, 45),
          center,
          (center + 1).clamp(1, 45),
        }.toList()
          ..sort();

        // collect all candidates within tolerance for the typed weight
        final withinTol = <int>[];
        double bestErr = double.infinity;
        int bestRep = candidates.first;

        for (final r in candidates) {
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


  //...autosave bits finish

  //Missing Exercises bits...
// Missed cache for today
  List<_MissedItem> _missedItemsForToday = [];
  bool _hasMissedForToday = false;

// One-time shine per page open (per date)
  bool _didShineThisOpen = false;

// Shine animation
  late final AnimationController _catchupShineCtl;
  late final Animation<double> _catchupShineAnim;


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
        print('📦 [WES] plannedExercises (cache) items=${cached
            .length} in ${cacheSw.elapsedMilliseconds}ms');

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

  String _rowCacheKey(int rowIndex) {
    var id = _selectedExercisesWithCircuits[rowIndex]['rowId'];
    if (id == null || (id as String).isEmpty) {
      // generate stable identity once
      id = '${DateTime
          .now()
          .microsecondsSinceEpoch}_$rowIndex';
      _selectedExercisesWithCircuits[rowIndex]['rowId'] = id;
    }
    final ymd = DateFormat('yyyy-MM-dd').format(
        _selectedDate ?? DateTime.now());
    return '$id|$ymd';
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
        _selectedExercisesWithCircuits.add({
          'name': name,
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

        final key = name.toLowerCase();

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
            print('🔍 Top sets for $name → E1RMs: [$e1rms], Reps: [$reps]');
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

    print(
        '🔍 [WES] Getting repTarget for $exerciseId → model: $model, weekIndex: $weekIndex');

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

  Future<void> debugPrintRepTargetsFromExerciseSettings(BuildContext context,
      String blockId,
      String exerciseId,) async {
    final uid = UserContext
        .of(context, listen: false)
        .actingAsUid;


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
    print(
        '🔍 [DEBUG] repTargets from exerciseSettings for $exerciseId:\n${jsonEncode(
            repTargets)}');

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
    final key = _rowCacheKey(exerciseIndex);
    final cached = _cachedProgressedValues[key];
    if (cached != null && blockStartDate != null && blockEndDate != null) {
      final exName = _selectedExercisesWithCircuits[exerciseIndex]['name'];
      print('🧳 [WES cache HIT] key=$key for "$exName" '
          '→ cachedFor="${cached['exerciseName']}" '
          'weight=${cached['weight']} reps=${cached['reps']}');
      return cached;
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
    print(
        '🔎 [WES] Progression model for $exerciseId (${exerciseName}): $model');

    if (model == PeriodizationModelType.dailyUndulatingExposure) {
      // (Assuming your existing model-specific logic is used here)
      final fullDetails = _exerciseSettings[exerciseId];
      final week1 = fullDetails?['repTargets']?['week1'];


      print(
          '🔍 [WES] Checking DUP Exposure → exerciseId: $exerciseId, exerciseName: $exerciseName');
      print(
          '📦 Full exerciseSettings[$exerciseId] = ${jsonEncode(fullDetails)}');
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
          } catch (e) {
            print(
                '⚠️ [WES DUP Exposure] completedBeforeTodayInBlock calc failed: $e');
          }

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

// Print the counted days with set details and cycle position
          for (int i = 0; i < countedDebug.length; i++) {
            final e = countedDebug[i];
            // cyclePos is 1-based within the week1 instances list size
            final cyclePos = sorted.isEmpty ? 'n/a' : ((i % sorted.length) + 1)
                .toString();
            final cycleDen = sorted.isEmpty ? 'n/a' : sorted.length.toString();
            print('🧾 [WES DUP Exposure] prior #${i + 1} → ${e['date']} '
                '• ${e['weight']} kg × ${e['reps']} '
                '${e['rir'] != '—' ? '(RIR ${e['rir']}) ' : ''}'
                '→ cycle ${cyclePos}/${cycleDen}');
          }

// Now compute plannedIndex / index as before
          final plannedIndex = completedBeforeTodayInBlock + plannedCountBefore;
          final index = sorted.isEmpty ? 0 : plannedIndex % sorted.length;

          print(
              '🧮 [WES DUP Exposure] completedBeforeTodayInBlock=$completedBeforeTodayInBlock '
                  'plannedBefore=$plannedCountBefore → plannedIndex=$plannedIndex '
                  '→ instance=${sorted.isEmpty ? 'n/a' : (index + 1)}/${sorted
                  .length}');


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
              print(
                  '⚠️ [WES DUP Week] completedEarlierThisWeek calc failed: $e');
            }

            // 🔑 WES rule: planned rows don't affect DUP Weekly indexing
            final plannedIndex = completedEarlierThisWeek;
            final index = plannedIndex % sorted.length;

            print(
                '🧮 [WES DUP Week] completedEarlierThisWeek=$completedEarlierThisWeek '
                    '→ plannedIndex=$plannedIndex → instance=${index +
                    1}/${sorted.length}');

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

      print(
          '🎯 [WES] dailyUndulatingWeek → repTarget = $repTarget for $exerciseName (using week1 pattern)');
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
    print(
        '🔧 [WES] progressionModelName for $exerciseId = $progressionModelName');
    print('📦 [WES] Full _exerciseSettings for $exerciseId: ${jsonEncode(
        _exerciseSettings[exerciseId])}');

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


    final maxWeightMap = _exerciseSettings[exerciseId]?['maxWeightByReps'];
    final maxWeightKeys = (maxWeightMap is Map)
        ? maxWeightMap.keys.toList()
        : 'null';

    print('⚙️ [PMU] inputs name=$exerciseName '
        'model=$progressionModel '
        'repTarget=$repTarget '
        'incs=${increments ?? [2.5]} '
        'bw=${PeriodizationModelUtils.bodyweightKgForDate(uid: uidForBw, asOf: _selectedDate)} '
        'hasMaxByReps=${_exerciseSettings[exerciseId]?['maxWeightByReps'] != null} '
        'week=${blockStartDate != null ? PeriodizationModelUtils.getWeekIndexForDate(_selectedDate, blockStartDate!) : -1}');


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

      topSetHistory: PeriodizationModelUtils.topSetsByExercise[exerciseName],
      weekIndex: (blockStartDate == null || _selectedDate == null)
          ? 0 // safe default until initialized
          : PeriodizationModelUtils.getWeekIndexForDate(
        _selectedDate, blockStartDate!,
      ),


    );
    print(
        '🧾 [WES <- PMU] pre-overlay ${progressed['weight']} × ${progressed['reps']}');
    print('✅ [PMU] progressed=${progressed['weight']}x${progressed['reps']} (pre-snap) ORIGIN='
        '${_isLoadingData ? 'EARLY_DEFAULTS' : 'READY'}');

// as-of date for BW lookups = the day being edited in WES
    final DateTime _asOfDate = _selectedDate ?? DateTime.now();

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

    print('🧾 [WES overlay] ${progressed['weight']} → $snapped');

    // Cache and return
// Cache and return
    progressed['exerciseName'] = exerciseName;
    progressed['exerciseId'] = exerciseId;
    _cachedProgressedValues[_rowCacheKey(exerciseIndex)] = progressed;


    print(
        '🧮 [WES] Progressed for ${exerciseName} = ${progressed['weight']} kg @ ${repTarget} reps, RIR $rir');

    return progressed;
  }

  //Determine hint texts for this workout:NEW METHOD

  double set1SuggestedReps(int exerciseIndex) {
    // FAST-PATH: use precomputed hint if available
    final hintK = _rowKeyBy(exerciseIndex);
    final num? hr = _seedHintsByKey[hintK]?['s1_reps'] as num?;
    if (hr != null) {
      // print('⚡ [WES Hints] S1 reps from snapshot for $hintK = $hr');
      return hr.toDouble();
    }

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
    final bool hasUserReps = reps != null;
    final bool hasBB2Reps = bb2Reps != null && bb2Reps > 0;

    // CASE 1: Reps already entered by user → use it
    if (hasUserReps) return reps!;

    // CASE 2: BB2-entered reps → use them
    if (hasBB2Reps) {
      print('🔁 [WES] Using BB2-entered reps for $exerciseName = $bb2Reps');
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


    final exerciseId =
        PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
    final weekIndex = _getApplicableWeekIndex(exerciseId);
    if (weekIndex == null) return setNumber == 1 ? 1 : 1.5;



    if (blockStartDate == null) {
      print(
          '❌ [WES] RIR_blockStartDate is null in getRirFromPlanOrInput for $exerciseName');
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

    final rirPlan =
    PeriodizationModelUtils.plannedExerciseDetails[exerciseId]?['rirPlan'];
    final weekKey = 'week${weekIndex + 1}';
    final weekData = (rirPlan?[weekKey] as Map?)?.cast<String, dynamic>() ??
        const {};
    final maxSessions = weekData.keys
        .where((k) => k.startsWith('session'))
        .length;
    final safeSessionIndex = (maxSessions > 0) ? sessionIndex.clamp(
        0, maxSessions - 1) : 0;

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
    print('🪫 [S1W] start i=$exerciseIndex '
        'init=$_isInitialized load=$_isLoadingData '
        'name=${_selectedExercisesWithCircuits[exerciseIndex]['name']}');

    // FAST-PATH: use precomputed hint if available
    final hintK = _rowKeyBy(exerciseIndex);
    final hint  = _seedHintsByKey[hintK];
    if (hint != null) {
      final exerciseName = _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
      final exId = PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
      final isBw = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: exerciseName);

      final num? v = isBw ? (hint['s1_weight_added'] as num?) : (hint['s1_weight'] as num?);
      if (v != null) {
        // print('⚡ [WES Hints] S1 weight from snapshot for $hintK = $v');
        return v.toDouble();
      }
    }

    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    final normalizedKey = exerciseName.toLowerCase();
    final String exerciseId =
        PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;

    final bb2Entry = _resolvedBB2Values[normalizedKey];
    print('🧩 [S1W] bb2Entry weight=${bb2Entry?['weight']} '
        'reps=${bb2Entry?['reps']} rir=${bb2Entry?['rir']}');


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
      if (PeriodizationModelUtils.isBodyweightExercise(
          id: exerciseId, name: exerciseName)) {
        // already entered as ADDED in the field → just return it
        return userWeight;
      }
      return userWeight; // unchanged for non-BW
    }

    print('🧮 [S1W] calling _getProgressedValues for '
        '${_selectedExercisesWithCircuits[exerciseIndex]['name']}');

    // ✅ Step 4: Pull model progression values
    final progressed = _getProgressedValues(exerciseIndex);
    final double baseWeight = progressed['weight']?.toDouble() ?? 20.0;
    final double baseReps = progressed['reps']?.toDouble() ?? 10.0;
    final double modelRir = getRirFromPlanOrInput(exerciseIndex, 1);

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
    final String _normKey = exerciseName.trim().toLowerCase();
    final dynamic _bb2RirRaw = _resolvedBB2Values[_normKey]?['rir'];
    final double? _bb2Rir = (_bb2RirRaw is num)
        ? _bb2RirRaw.toDouble()
        : double.tryParse(_bb2RirRaw?.toString() ?? '');

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
        _bb2Rir != null;

// Use planned RIR as the seed ONLY for that one case; otherwise keep existing modelRir
    final double _seedRIR = _rirOnlyBw ? _plannedRirForSet1() : modelRir;

// Compute base using the chosen seed
    final double baseE1RM = PeriodizationModelUtils.calculateE1RM(
      baseWeight,
      baseReps,
      _seedRIR,
    );

// (Optional, compact trace to confirm seeds during testing)
    print('🎯 [WES Seed] isBw=$_isBwEx rirOnlyBw=$_rirOnlyBw seedRIR=${_seedRIR
        .toStringAsFixed(2)} '
        '→ baseE1RM=${baseE1RM.toStringAsFixed(2)} (base=${baseWeight
        .toStringAsFixed(2)}×${baseReps.toStringAsFixed(1)})');


    // ✅ Step 6: Use user RIR and/or reps if available
    if (userReps != null || userRir != null) {
      final double repsToUse = userReps ?? set1SuggestedReps(exerciseIndex);
      final double rirToUse = userRir ?? modelRir;
      print(
          '⚙️ [WES S1Weight] override path → repsToUse=$repsToUse rirToUse=$rirToUse baseWeight=$baseWeight baseReps=$baseReps');


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

// NEW: compact summary of the override calc
      print('⚙️ [WES OverrideCalc] reps=$repsToUse rir=$rirToUse '
          'derivedAbs=${derived.toStringAsFixed(2)} roundedAbs=${rounded
          .toStringAsFixed(2)}');

      print('🧲 [WES snap] $derived → $rounded (candidates=${_candidates.take(10)
          .toList()} …)');

      final double newE1RM = PeriodizationModelUtils.calculateE1RM(
        rounded,
        repsToUse,
        rirToUse,
      );
      print(
          '🔁 [WES] Derived weight = $rounded using reps = $repsToUse and RIR = $rirToUse '
              '→ new E1RM = ${newE1RM.toStringAsFixed(2)}');

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

// non-BW stays absolute
      print('🟢 [WES S1Weight] non-BW override → abs=$rounded');
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


    final double rir = double.tryParse(rirText) ??
        (setIdx == 0 ? (_isInitialized ? set1RIR(exIdx) : 0.5)
            : setIdx == 1 ? (_isInitialized ? set2RIR(exIdx) : 0.5)
            : (_isInitialized ? set3RIR(exIdx) : 0.5));

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

    _selectedDate = widget.initialDate ?? DateTime.now();
    if (_workoutNameController.text.trim().isEmpty) {
      _workoutNameController.text = DateFormat('EEE d MMM yyyy').format(_selectedDate);
    }

    // Read global block meta published by UserContext bootstrap (instant, no fetch)
    _cachedUid = UserContext.of(context, listen: false).currentUid;
    final uc = UserContext.of(context, listen: false);
    _activeBlockId   = uc.activeBlockId ?? _activeBlockId;
    _selectedBlockId = uc.activeBlockId ?? _selectedBlockId;
    _blockStartDate  = uc.blockStartDate ?? _blockStartDate;
    _blockEndDate    = uc.blockEndDate   ?? _blockEndDate;

    // 🔎 Offline preflight: verify caches are present before painting (non-blocking)
    Future.microtask(() async { await _offlinePreflightDebug(); });

    // Fast paint #1: uid+date fallback (works even if blockId not known yet)
    // ignore: unawaited_futures
    _paintFromSnapshotIfAny();

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
          print('📦 [WES] _loadAllBlocks complete, total blocks: ${_allBlocks
              .length}');


          _selectedBlockId = _allBlocks
              .firstWhere(
                (b) => b.id == _activeBlockId,
            orElse: () => _allBlocks.first,
          )
              .id;

          print("🧱 [WES] Selected blockId: $_selectedBlockId");
          // ⚡ Try exact-key fast paint now that blockId is known
          unawaited(_paintFromSnapshotIfAny());


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

          if (widget.initialDate != null) {
            _selectedDate = widget.initialDate!;
            _workoutNameController.text = _formatWorkoutDate(_selectedDate);
          }

          _cachedProgressedValues.clear();

// ⚠️ Do NOT wipe rows if a snapshot already painted them.
          if (!_didFastPaint) {
            _selectedExercisesWithCircuits.clear();
            _workoutSets.clear();
            _repsControllers.clear();
            _weightControllers.clear();
            _rirControllers.clear();
            _velocityControllers.clear();
            _notesControllers.clear();
            _resolvedBB2Values.clear();
          } else {
            // Keep rows the fast paint drew; still reset non-row flags if needed.
            _resolvedBB2Values.clear();
          }

          await _loadDraftLocallyIfAvailable();
          _populateVelocityFlags();
          print("🔀 [WES] Merged BB2 into draft");

          _cachedProgressedValues.clear();


          final hasUserData = _weightControllers.any((controllerList) =>
              controllerList.any((c) =>
              c.text
                  .trim()
                  .isNotEmpty));

          if (!hasUserData) {
            print(
                '🔁 [WES Init] No user-entered data in WES → re-merging BB2 values');
            _lastMergedUid = null;
            await _mergeNewBB2ExercisesIntoDraft();
          } else {
            print(
                '✅ [WES Init] Skipping BB2 re-merge — WES already has user-entered data');
          }
          print(
              '🔄 [WES Init] Overlaying saved workout (completed + WES-planned) after final BB2 merge…');
          await _loadExistingWorkoutIfAny(); // <- puts the WES-planned rows back
          if (mounted) setState(() {}); // <- repaint

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
                  previousWorkout: previous,
                  topSetHistory: topSets,
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
          _catchupShineCtl = AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 1200),
          );


          _catchupShineAnim = CurvedAnimation(
            parent: _catchupShineCtl,
            curve: Curves.easeInOut,
          );

          Future.delayed(const Duration(milliseconds: 10), () {
            if (_selectedExercisesWithCircuits.isNotEmpty) {
              final testExercise = _selectedExercisesWithCircuits.first['name']
                  ?.trim() ?? '';
              final rep = getRepTargetForExerciseWES(testExercise, 0);
              print('🧪 [WES Init] Test rep target for "$testExercise" = $rep');
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
        print(
            '📦 [WES] BlockMeta (attempt $attempt) → start: $blockStartDate | end: $blockEndDate | days: $_selectedDays');
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

    print('✅ [WES] Loaded block dates: $_blockStartDate → $_blockEndDate');
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

    print('🔍 [WES] Loaded ${snap.docs.length} blocks: ${snap.docs.map((d) => d
        .id)}');

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
  void _applyOverlayInPlace(List<Map<String, dynamic>> exList) {
    if (!mounted || exList.isEmpty) return;

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
        // Resize controllers if needed
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
        _repsControllers[idx][j].text     = (s.reps?.toString() ?? '');
        _weightControllers[idx][j].text   = (s.weight?.toString() ?? '');
        _rirControllers[idx][j].text      = (s.rir?.toString() ?? '');
        _velocityControllers[idx][j].text = (s.velocity?.toString() ?? '');
        _notesControllers[idx][j].text    = (s.notes ?? '');
      }
    }

    // We updated in place; only a single subtle repaint.
    if (mounted) setState(() {});
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


  // Anchor A: add inside _WorkoutPageState
  Future<void> _paintFromSnapshotIfAny() async {
    print('🚩 [WES Boot] _paintFromSnapshotIfAny CALLED');  // <── add here
    try {
      // 🔒 Make this strictly single-shot. Set BEFORE any awaits to avoid races.
      if (_bootPaintDone) return;
      _bootPaintDone = true;

      final uid = _cachedUid ?? UserContext.of(context, listen: false).currentUid;
      final bid = _selectedBlockId ?? _activeBlockId;
      final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);

      print('🟨 [WES Boot] _paintFromSnapshotIfAny enter uid=$uid bid=$bid ymd=$ymd');
      if (uid == null || bid == null) {
        print('⚪ [WES Boot] Skip snapshot paint (uid or blockId missing)');
        return;
      }

      // Use latest snapshot by cachedAt DESC (via helper)
      final snap = await BlockPlanCache.getInitSnapshot(
        uid: uid,
        blockId: bid,
        dateYmd: ymd,
      );
      print('🔎 [WES Boot] Exact snapshot lookup (uid=$uid, block=$bid, ymd=$ymd) → ${snap == null ? 'MISS' : 'HIT'}');
      if (snap == null) return;

      // 🔐 Robust decode for planned / previous (handles legacy Map shapes)
      List<dynamic> _safeListFromJson(String raw, {String? fallbackKey}) {
        if (raw.isEmpty) return const [];
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) return decoded;
          if (decoded is Map) {
            // Try common legacy keys
            final keys = <String>[
              if (fallbackKey != null) fallbackKey,
              'rows', 'planned', 'exercises', 'list'
            ];
            for (final k in keys.where((k) => k != null)) {
              final v = decoded[k];
              if (v is List) return v;
            }
          }
        } catch (_) {/* swallow */}
        return const [];
      }

      final planned = _safeListFromJson(snap.plannedExercisesJson, fallbackKey: 'planned');
      final prev    = _safeListFromJson(snap.previousWorkoutJson,   fallbackKey: 'exercises');

      print('🧪 [WES Boot] plannedLen=${planned.length} prevLen=${prev.length}');
      print('🔔 [FAST-check] about to inspect snap.hintsJson=${snap.hintsJson}');

      // 🔎 FAST-path hints (from snapshot.hintsJson)
      final String _hj = snap.hintsJson ?? '';
      if (_hj.isEmpty || _hj == '{}') {
        print('🚫 [FAST] no hintsJson in snapshot.');
      } else {
        try {
          final Map<String, dynamic> hintsMap =
          (jsonDecode(_hj) as Map).cast<String, dynamic>();

          final Map<String, dynamic> weights =
              (hintsMap['weights'] as Map?)?.cast<String, dynamic>() ?? const {};
          final Map<String, dynamic> reps =
              (hintsMap['reps'] as Map?)?.cast<String, dynamic>() ?? const {};
          final Map<String, dynamic> rir =
              (hintsMap['rir'] as Map?)?.cast<String, dynamic>() ?? const {};

          print('🚀 [FAST] hints sizes → weights=${weights.length} reps=${reps.length} rir=${rir.length}');
        } catch (e) {
          print('⚠️ [WES Boot] hintsJson parse failed: $e');
        }
      }


      // 👇 Load pre-resolved hints if present
      try {
        if (snap.hintsJson.isNotEmpty && snap.hintsJson != '{}') {
          final raw = jsonDecode(snap.hintsJson);
          if (raw is Map) {
            _seedHintsByKey.clear();
            raw.forEach((k, v) {
              if (v is Map) {
                _seedHintsByKey[k.toString()] = Map<String, dynamic>.from(v);
              }
            });
            print('⚡ [WES Boot] Loaded ${_seedHintsByKey.length} pre-resolved hint(s)');
          }
        }
      } catch (e) {
        print('⚠️ [WES Boot] hintsJson parse failed: $e');
      }


      // Choose rows to paint (prefer planned, else derive from prev)
      List<Map<String, dynamic>> rows = [];
      if (planned.isNotEmpty) {
        rows = planned.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else if (prev.isNotEmpty) {
        rows = prev.map<Map<String, dynamic>>((e) {
          final m = Map<String, dynamic>.from(e as Map);
          return {
            'name': (m['name'] ?? '').toString().trim(),
            'circuitIndex': (m['circuitIndex'] is int)
                ? (m['circuitIndex'] as int)
                : int.tryParse('${m['circuitIndex'] ?? 0}') ?? 0,
          };
        }).toList();
      }

      if (rows.isEmpty) {
        print('⚪ [WES Boot] Snapshot had no planned rows and no prev overlay — nothing to paint');
        return;
      }

      if (!mounted) return;
      setState(() {
        // ⚡ First frame: paint names only (controllers later)
        _selectedExercisesWithCircuits
          ..clear()
          ..addAll(rows);

        _isLoadingData = false;
        _isInitialized = true;
        _didFastPaint  = true;
      });
      // 🔭 DEBUG: confirm the *frame after* setState actually presented the rows
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        print('🟢 [WES Boot] Fast-paint rows are now on-screen (frame complete). rows=${_selectedExercisesWithCircuits.length}');
      });

      // 🔧 Seed sets + controllers to match the newly-painted rows (avoid 1-frame mismatch)
      for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
        // Ensure a SetDetails list exists for this row
        if (i >= _workoutSets.length) {
          _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
        } else if (_workoutSets[i].isEmpty) {
          _workoutSets[i] = List.generate(_defaultSets, (_) => SetDetails());
        }

        // Ensure controller matrix has a row for index i
        void _ensureRow(List<List<TextEditingController>> m) {
          while (m.length <= i) m.add(<TextEditingController>[]);
          final need = _workoutSets[i].length;
          if (m[i].length != need) {
            m[i] = List.generate(need, (_) => TextEditingController());
          }
        }

        _ensureRow(_repsControllers);
        _ensureRow(_weightControllers);
        _ensureRow(_rirControllers);
        _ensureRow(_velocityControllers);
        _ensureRow(_notesControllers);
      }

// (Optional) listeners
      _attachDirtyListeners();
// 🟣 NEW: Seed first-set fields from hintsJson (final targets) for instant, correct first paint.
      final List hintsList = (snap.hintsJson.isNotEmpty)
          ? (jsonDecode(snap.hintsJson) as List)
          : const [];

      if (hintsList.isNotEmpty) {
        // Build quick lookup by "name|ci"
        String _k(String n, int ci) => '${n.trim().toLowerCase()}|$ci';
        final Map<String, Map<String, dynamic>> hintsByKey = {};
        for (final raw in hintsList) {
          if (raw is! Map) continue;
          final m = Map<String, dynamic>.from(raw as Map);
          final name = (m['name'] ?? '').toString().trim();
          final ci = (m['circuitIndex'] is int)
              ? (m['circuitIndex'] as int)
              : int.tryParse('${m['circuitIndex'] ?? 0}') ?? 0;
          if (name.isEmpty) continue;
          hintsByKey[_k(name, ci)] = m;
        }

        // Apply to rows we just painted
        for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
          final name = (_selectedExercisesWithCircuits[i]['name'] ?? '').toString();
          final ci   = (_selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0) as int;
          final key  = _k(name, ci);
          final hint = hintsByKey[key];
          if (hint == null) continue;

          // Ensure we have at least one set slot + controllers
          if (_workoutSets.length <= i || _workoutSets[i].isEmpty) {
            if (_workoutSets.length <= i) {
              _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
            } else {
              _workoutSets[i] = List.generate(_defaultSets, (_) => SetDetails());
            }
          }
          void _ensureRow(List<List<TextEditingController>> m) {
            while (m.length <= i) m.add(<TextEditingController>[]);
            final need = _workoutSets[i].length;
            if (m[i].length != need) {
              m[i] = List.generate(need, (_) => TextEditingController());
            }
          }
          _ensureRow(_repsControllers);
          _ensureRow(_weightControllers);
          _ensureRow(_rirControllers);
          _ensureRow(_velocityControllers);
          _ensureRow(_notesControllers);

          // Pull set1 targets (display-ready). We accept either display "weight" or "absWeight" fallback.
          final String exId = PeriodizationModelUtils.nameToId[name] ?? name;
          final bool isBw   = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: name);

          // targets are display-ready (added kg for BW, absolute for others)
          double? dispWeight = (hint['weight']      is num) ? (hint['weight'] as num).toDouble() : null;
          final  double? absWeight  = (hint['absWeight']   is num) ? (hint['absWeight'] as num).toDouble() : null;
          final  double? reps1      = (hint['reps']        is num) ? (hint['reps'] as num).toDouble()      : null;
          final  double? rir1       = (hint['rir']         is num) ? (hint['rir'] as num).toDouble()       : null;

          // If BW and only absWeight is present, convert abs → displayAdded for the text field
          if (dispWeight == null && isBw && absWeight != null) {
            try {
              dispWeight = PeriodizationModelUtils.toDisplayAddedWeight(
                uid: _cachedUid ?? '',
                absoluteKg: absWeight,
                exerciseId: exId,
                exerciseName: name,
                asOfDate: _selectedDate,
              );
            } catch (_) {}
          }
          // If non-BW and only absWeight present, that's the display too
          if (dispWeight == null && !isBw && absWeight != null) {
            dispWeight = absWeight;
          }

          // Seed set[0] model + controllers ONLY if fields are currently empty
          final int j = 0;
          final repsCtl   = _repsControllers[i][j];
          final weightCtl = _weightControllers[i][j];
          final rirCtl    = _rirControllers[i][j];

          final bool hasReps   = repsCtl.text.trim().isNotEmpty;
          final bool hasWeight = weightCtl.text.trim().isNotEmpty;
          final bool hasRir    = rirCtl.text.trim().isNotEmpty;

          // Update underlying model (SetDetails) as well
          final current = _workoutSets[i][j];
          _workoutSets[i][j] = SetDetails(
            reps:    current.reps    ?? (reps1?.toInt()),
            weight:  current.weight  ?? dispWeight,
            rir:     current.rir     ?? rir1,
            velocity: current.velocity,
            notes:    current.notes,
          );

          if (!hasReps && reps1 != null)   repsCtl.text   = reps1.toInt().toString();
          if (!hasWeight && dispWeight != null) weightCtl.text = dispWeight.toString();
          if (!hasRir && rir1 != null)     rirCtl.text    = rir1.toString();
        }

        // We updated values in place before any server reconcile.
        if (mounted) setState(() {});
      }

// ✅ At this point, builder won’t see mismatched lengths

// 🔌 If snapshot had a previous overlay, prefill the first few set fields now (instant values)
      if (prev.isNotEmpty) {
        // Build quick lookup: "name|ci" -> sets[]
        String _k(String n, int ci) => '${n.trim().toLowerCase()}|$ci';
        final Map<String, List<Map<String, dynamic>>> prevByKey = {};
        for (final raw in prev) {
          if (raw is! Map) continue;
          final m = Map<String, dynamic>.from(raw as Map);
          final name = (m['name'] ?? '').toString().trim();
          final ci = (m['circuitIndex'] is int)
              ? (m['circuitIndex'] as int)
              : int.tryParse('${m['circuitIndex'] ?? 0}') ?? 0;
          final sets = (m['sets'] as List?)?.whereType<Map>().map((s0) => Map<String, dynamic>.from(s0)).toList() ?? const [];
          if (name.isNotEmpty && sets.isNotEmpty) {
            prevByKey[_k(name, ci)] = sets;
          }
        }

        for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
          final name = (_selectedExercisesWithCircuits[i]['name'] ?? '').toString();
          final ci   = (_selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0) as int;
          final sets = prevByKey[_k(name, ci)];
          if (sets == null || sets.isEmpty) continue;

          // Fill up to the number of seeded set rows
          final limit = (_workoutSets[i].length < sets.length) ? _workoutSets[i].length : sets.length;
          for (int j = 0; j < limit; j++) {
            final s = sets[j];
            // Normalize bodyweight “addedWeight” vs absolute weight
            final reps = (s['reps'] is int) ? s['reps'] : int.tryParse('${s['reps'] ?? ''}');
            final weight = (s['weight'] is num) ? (s['weight'] as num).toDouble()
                : (s['addedWeight'] is num) ? (s['addedWeight'] as num).toDouble()
                : (s['weightAdded'] is num) ? (s['weightAdded'] as num).toDouble()
                : null;
            final rir = (s['rir'] is num) ? (s['rir'] as num).toDouble() : null;
            final vel = (s['velocity'] is num) ? (s['velocity'] as num).toDouble() : null;
            final notes = (s['notes'] ?? '').toString();

            // Update model
            _workoutSets[i][j] = SetDetails(
              reps: reps,
              weight: weight,
              rir: rir,
              velocity: vel,
              notes: notes.isEmpty ? null : notes,
            );

            // Update controllers
            _repsControllers[i][j].text     = reps?.toString() ?? '';
            _weightControllers[i][j].text   = weight?.toString() ?? '';
            _rirControllers[i][j].text      = rir?.toString() ?? '';
            _velocityControllers[i][j].text = vel?.toString() ?? '';
            _notesControllers[i][j].text    = notes;
          }
        }
      }


      // Build controllers AFTER first paint
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _ensureControllersForRowsLazily();
        if (mounted) setState(() {}); // tick if sizes changed
      });

      print('⚡ [WES Boot] Snapshot PAINTED ${rows.length} row(s) for $ymd (instant-visible)');
    } catch (e, st) {
      print('⚠️ [WES Boot] Snapshot hydrate failed: $e');
      print(st);
    }
  }


  Future<void> _loadInitialData() async {
    final _tInit = Stopwatch()
      ..start(); // ⏱️ start total timer
    print('⏱️ [WES] _loadInitialData started');
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

    print('🔁 [WES Init] Running full BB2 plan load');

// ──────────────────────────────────────────────────────────────
// SUPER-CACHE READ: disabled here to avoid double fast-paint.
// ──────────────────────────────────────────────────────────────
    print('⏭️ [WES Init] Skipping in-function snapshot hydrate (boot paint handles it)');


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
    print('💾 [WES Init] Attempting to load draft from cache...');
    final draftLoaded = await _loadWorkoutDraftFromCache();
    print('📦 [WES Init] Draft loaded: $draftLoaded');

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
      print('🔁 [WES Init] Merging BB2 exercises post-draft...');
      await _mergeNewBB2ExercisesIntoDraft(); // Isar-first inside
    } else {
      print('📭 [WES Init] No draft found → merging BB2...');
      if (!_rowsExist && !_didFastPaint) {
        _selectedExercisesWithCircuits.clear();
      }
      await _mergeNewBB2ExercisesIntoDraft();

    }


    // H) Finalize UI flags + paint
    setState(() {
      _isLoadingData = false;
      _isInitialized = true;
    });

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
        final String hintsJson = jsonEncode(hints);


        if (plannedCount == 0 && previousCount == 0) {
          print('🟨 [WES Init] Skip snapshot save (both planned & previous empty) for $ymd');
        } else {
          await BlockPlanCache.putInitSnapshot(
            uid: uid,
            blockId: bid,
            dateYmd: ymd,
            plannedExercises: plannedCompact,
            previousWorkout: previousOverlay,
            topSetHistory: topSetHistoryList,
            hintsJson: hintsJson,            // 👈 NEW
            // hintsInputsHash: null,        // (optional, add later)
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
      await _loadExistingWorkoutIfAny();

      if (mounted) setState(() {}); // subtle repaint with overlays if changed
    })();
  }


  Future<void> _loadExistingWorkoutIfAny() async {
    final _tLoadExisting = Stopwatch()
      ..start();
    print('⏱️ [WES] _loadExistingWorkoutIfAny started');
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
      bool _printedLoadBw = false;

      print('🔎 [WES LoadExisting] Looking up workout for ${DateFormat(
          'yyyy-MM-dd').format(_selectedDate)}');
      print('   └─ primary docId = $newDocId');

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
          print('[WES LoadExisting] Found ${isarList
              .length} exercise(s) in ISAR super-cache');
          // TODO: hydrate state/controllers if you want ISAR data to render immediately
        }
      } catch (e) {
        print('[WES LoadExisting] ISAR read failed (non-fatal): $e');
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

            print('⚡ [WES LoadExisting] Snapshot fast-path: prev=${exList
                .length}, planned=${wesPlannedList.length}');

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

          print('⚡ [WES LoadExisting] Fast-path (cache) new-style: '
              'ex=${_newExListCache.length}, wesPlanned=${_wesPlannedCache
              .length}');

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
                print('🧩 [WES Reconcile] Merged ${legacyOnly
                    .length} legacy-only rows → new-style');
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

          if (combinedCache.isNotEmpty || wesPlannedCache.isNotEmpty) {
            // ⚡ Paint now from cache
            exList = combinedCache;
            wesPlannedList = wesPlannedCache;
            paintedFromCache = true;
            print('⚡ [WES LoadExisting] Cache-union path: ex=${combinedCache
                .length}, wesPlanned=${wesPlannedCache.length}');

            // Background reconcile from SERVER (best-effort)
            // ignore: unawaited_futures
            (() async {
              try {
                DocumentSnapshot<Map<String, dynamic>>? newDocServer;
                try {
                  newDocServer = await workoutsCol.doc(newDocId).get(
                      const GetOptions(source: Source.server));
                } catch (_) {
                  newDocServer = await workoutsCol.doc(newDocId).get();
                }

                Future<QuerySnapshot<Map<String, dynamic>>> _eqServer(
                    String v) =>
                    workoutsCol.where('date', isEqualTo: v).get(
                        const GetOptions(source: Source.server));

                final srvResults = await Future.wait([
                  _eqServer(isoLocal),
                  _eqServer(isoUtc),
                  _eqServer(dateOnly),
                  workoutsCol
                      .where(
                      'date', isGreaterThanOrEqualTo: '${dateOnly}T00:00:00')
                      .where('date', isLessThan: '${nextDateOnly}T00:00:00')
                      .get(const GetOptions(source: Source.server)),
                  workoutsCol
                      .where('date',
                      isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
                      .where('date', isLessThan: Timestamp.fromDate(nextDay))
                      .get(const GetOptions(source: Source.server)),
                ]);

                final Map<String,
                    DocumentSnapshot<Map<String, dynamic>>> legacyByIdSrv = {};
                for (final snap in srvResults) {
                  for (final d in snap.docs)
                    legacyByIdSrv[d.id] = d;
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

                if (changed && mounted) {
                  setState(() {}); // minimal repaint; data already updated in memory by callers
                  print(
                      '🔄 [WES LoadExisting] Applied server-union refresh (background)');
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

          print('   ℹ️ legacy candidates: '
              'eqLocal=${legacyStrLocal.docs.length}, eqUtcZ=${legacyStrUtc.docs
              .length}, '
              'eqDateOnly=${legacyStrDate.docs
              .length}, strRange=${legacyStrRange.docs.length}, '
              'tsRange=${legacyTsSnap.docs.length}, uniqueDocs=${_legacyDocsById
              .length}, '
              'legacyExList=${legacyExList.length}');

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

          exList = combined;
          wesPlannedList = _wesPlannedFromDoc(newDoc);
          print('   ℹ️ wesPlannedExercises count: ${wesPlannedList.length}');
          print(
              '   → wesPlanned: ${wesPlannedList.map((p) => "${(p['name'] ?? '')
                  .toString()
                  .trim()}|${(p['circuitIndex'] ?? 0)}").toList()}');
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

      //5 === SILENT RECONCILE: update in place (no clearing, no spinner) ===
      final List<Map<String, dynamic>> overlayRows = exList
          .whereType<Map>()
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
          .toList();

      _applyOverlayInPlace(overlayRows);


      // 6) Pass 2 (optional): add any saved exercises that aren’t in the plan/UI yet
      final existingKeys = _selectedExercisesWithCircuits
          .map<String>((e) => _exerciseKey(
        ((e['name'] ?? '') as String).trim(),
        (e['circuitIndex'] ?? 0) as int,
      ))
          .toSet();


      // 7.5) Pass 3 (NEW): merge WES-planned rows (placeholders) IN-PLACE (no clears, no dupes)
      int plannedAdded = 0;

// Build a minimal overlay from wesPlannedList: name + circuitIndex, empty sets.
// _applyOverlayInPlace will skip existing rows and append any missing ones.
      final int beforeCount = _selectedExercisesWithCircuits.length;

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
          // empty sets → acts as a placeholder; overlay helper will not wipe existing sets
          'sets': const <Map<String, dynamic>>[],
        };
      })
          .where((e) => e.isNotEmpty)
          .toList();

// 🔧 In-place merge (no UI teardown)
      _applyOverlayInPlace(plannedOverlay);

// Count how many were appended by the helper
      plannedAdded = _selectedExercisesWithCircuits.length - beforeCount;

      print('🧩 [WES LoadExisting] Added $plannedAdded WES-planned placeholder row(s) (in-place)');



      // 7) Ensure listeners on any new controllers
      _attachDirtyListeners();

      // 8) Persist merged flags so next open is instant
      await _persistSavedFlagsLocally();

      _pendingChanges = false;
      _lastSavedHash = null;

      if (mounted) setState(() {}); // repaint now that overlay + additions are in
      if (exList.isEmpty && plannedAdded == 0) {
        print('   ❌ no workout items (completed or WES-planned) for this date');
      }
    } finally {
      _tLoadExisting.stop();
      print('⏱️ [WES] _loadExistingWorkoutIfAny took ${_tLoadExisting
          .elapsedMilliseconds}ms');
    }
  }


  Future<void> loadExercisesFromFirestoreForWES() async {
    print('➡️ [WES] loadExercisesFromFirestoreForWES START');
    final total = Stopwatch()
      ..start();
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
        print('📥 [WES] exercises.get() from SERVER (docs: ${snapshot.docs
            .length})');
      } else {
        print('📥 [WES] exercises.get() from CACHE (docs: ${snapshot.docs
            .length})');
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

        }
      }
      mapSw.stop();

      print('📥 [WES] exercises.get() took ${getSw.elapsedMilliseconds}ms');
      print('🧭 [WES] Mapping loop took ${mapSw
          .elapsedMilliseconds}ms (mapped $mapped)');
    } catch (e, st) {
      print(st);
    } finally {
      total.stop();
      print('⏱️ [WES] loadExercisesFromFirestoreForWES total ${total
          .elapsedMilliseconds}ms (mapped $mapped)');
      print('⤴️ [WES] loadExercisesFromFirestoreForWES END');
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

    print('🧾 [RAW] Full Firestore doc snapshot data: ${doc.data()}');


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
        print('🩹 [WES LOAD] overriding increments for $exId → $inc');
      }
    });

// now inject
    PeriodizationModelUtils.setExerciseSettings(mergedForPMU);
    print('✅ [WES] Injected exerciseSettings into PMU with keys: ${mergedForPMU
        .keys}');


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
        PeriodizationModelUtils.exercisePeriodizationModels[exerciseId] =
            modelEnum;
        print('✅ [WES] Mapped model $modelName → $modelEnum for $exerciseId');
      }

      // Track progressionModel if you need it later
      final progressionModel = entry['progressionModel'] ?? 'none';
      _progressionModelsByExercise[exerciseId] = progressionModel;
      print('🏗️ [WES] Progression model for $exerciseId: $progressionModel');
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
    print(
        '📦 [WES] [Firestore Function] Full raw Firestore data: ${jsonEncode(
            data)}');
    print(
        '📦 [WES] Extracted plannedExerciseDetails: ${jsonEncode(rawDetails)}');


    // ✅ Inject into PMU
    PeriodizationModelUtils.setExerciseSettings(rawDetails);
    print(
        '✅ [WES] Injected exerciseSettings into PMU with keys: ${rawDetails
            .keys}');

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
        print('📦 [WES] (cache) Loaded ${workouts
            .length} saved workouts into savedWorkoutsList');
      } else {
        // 3) Guarantee a server fallback (awaited) so behavior matches old code
        final serverSnap = await col.get(); // server
        workouts = serverSnap.docs.map((d) => d.data()).toList();
        PeriodizationModelUtils.savedWorkoutsList =
        List<Map<String, dynamic>>.from(workouts);
        print('📦 [WES] (server) Loaded ${workouts
            .length} saved workouts into savedWorkoutsList');
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
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    print('📱 [WES] AppLifecycleState changed: $state');
    print('📱 [WES] mounted = $mounted');

    if (state == AppLifecycleState.resumed) {
      final prefs = await SharedPreferences.getInstance();
      final dateKey =
          '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(
          2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
      final timestampStr = prefs.getString('draft_last_saved_$dateKey');

      print(
          '🔍 [WES] Checking last draft timestamp for key: $dateKey → $timestampStr');

      if (timestampStr != null) {
        final savedAt = DateTime.tryParse(timestampStr);
        final now = DateTime.now();
        print('🕒 [WES] Draft last saved at: $savedAt — now: $now');

        if (savedAt != null && now
            .difference(savedAt)
            .inHours < 2) {
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
      await _persistDraftLocally();

      // Guard against overlapping lifecycle saves
      if (_lifecycleSaveInFlight) {
        print('⏳ [WES] Lifecycle save already in flight — skipping.');
        return;
      }
      _lifecycleSaveInFlight = true;

      try {
        final bool hasAnyRows = _selectedExercisesWithCircuits
            .isNotEmpty; // covers WES shells
        final bool hasSavedFlags = _savedExerciseKeysForDate
            .isNotEmpty; // covers completed rows

// Reuse your existing completed semantics to detect "qualifying sets"
        bool hasQualifyingSets = false;
        for (int i = 0; i < _selectedExercisesWithCircuits.length &&
            !hasQualifyingSets; i++) {
          final name = ((_selectedExercisesWithCircuits[i]['name'] ??
              '') as String).trim();
          if (name.isEmpty) continue;
          final exId = PeriodizationModelUtils.nameToId[name] ?? name;
          final isBw = PeriodizationModelUtils.isBodyweightExercise(
              id: exId, name: name);
          for (final s in _workoutSets[i]) {
            final reps = s.reps ?? 0;
            final double? w = s.weight;
            final hasWR = isBw ? (reps > 0 && w != null) : (reps > 0 &&
                (w ?? 0.0) > 0.0);
            final hasOther = ((s.velocity ?? 0.0) > 0) || ((s.notes ?? '')
                .trim()
                .isNotEmpty);
            if (isBw ? hasWR : (hasWR || hasOther)) {
              hasQualifyingSets = true;
              break;
            }
          }
        }

        final bool shouldSave = _pendingChanges || hasAnyRows || hasSavedFlags;

        if (shouldSave) {
          final pushBB2 = hasQualifyingSets; // only push if we actually have completed sets
          print('💾 [WES] Autosaving to Firestore (pushBB2=$pushBB2)…');
          await _upsertWorkoutToFirestore(
            alsoPushToBB2: pushBB2,
            markAllSaved: false,
          );
          print('✅ [WES] Autosave complete.');
        } else {
          print('🔸 [WES] Nothing to save — skipping autosave.');
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
            (_) =>
            List.generate(
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
    _catchupShineCtl.dispose();

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

      final draft = {
        'workoutName': _workoutNameController.text,
        'exercises': List.generate(_selectedExercisesWithCircuits.length, (i) =>
        {
          'name': _selectedExercisesWithCircuits[i]['name'],
          'circuitIndex': _selectedExercisesWithCircuits[i]['circuitIndex'],
          'sets': _workoutSets[i].map((set) => set.toMap()).toList(),
        }),
      };

      final key = _getDraftKey(); // 👈 use your helper
      await prefs.setString(key, jsonEncode(draft));
      print('💾 [WES] Draft saved for ${_selectedDate
          .toIso8601String()} under key: $key');

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

      _workoutNameController.text =
          decoded['workoutName'] ?? _formatWorkoutDate(_selectedDate);

      for (final e in exercises) {
        _selectedExercisesWithCircuits.add({
          'name': e['name'],
          'circuitIndex': e['circuitIndex'] ?? 0,
        });

        final List<Map<String, dynamic>> setMaps = List<
            Map<String, dynamic>>.from(e['sets'] ?? []);
        final sets = setMaps.map((s) =>
            SetDetails(
              reps: (s['reps'] is int) ? s['reps'] : int.tryParse(
                  s['reps']?.toString() ?? ''),
              weight: (s['weight'] is num)
                  ? (s['weight'] as num).toDouble()
                  : null,
              rir: (s['rir'] is num) ? (s['rir'] as num).toDouble() : null,
              velocity: (s['velocity'] is num) ? (s['velocity'] as num)
                  .toDouble() : null,
              notes: s['notes']?.toString(),
            )).toList();

        _workoutSets.add(sets);
      }

      _initializeControllers();
    } catch (e) {
      print('❌ Failed to load WES draft: $e');
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

    setState(() {
      _selectedExercisesWithCircuits.clear();
      _selectedExercisesWithCircuits.addAll(
        selected.map((name) =>
        {
          'name': name,
          'category': nameToCategoryMap[name] ?? '', // 👈 add this line
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
        rirText.isNotEmpty ? double.tryParse(rirText) : 0.0; // default 0
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

        // BW: require reps AND an explicit weight entry (0 allowed if typed)
        final hasWR = isBw
            ? (reps > 0 && wOpt != null)
            : (reps > 0 && (wOpt ?? 0.0) > 0.0); // non-BW unchanged

        final hasOther = ((s.velocity ?? 0.0) > 0) ||
            ((s.notes ?? '')
                .trim()
                .isNotEmpty);

        // BW must meet hasWR; non-BW can also save on notes/velocity
        return isBw ? hasWR : (hasWR || hasOther);
      }).toList();

      if (setsWithData.isEmpty) continue; // “No data gets nothing saved”

// lock BW resolution to the WES workout date (local noon to avoid TZ edges)
      final asOfDate = DateTime(
          _selectedDate.year, _selectedDate.month, _selectedDate.day, 12);


      final ex = <String, dynamic>{
        'name': name,
        'circuitIndex': circuitIndex,
        // ✅ add this so BB2/WES rendering can reliably use the ID
        'exerciseId': PeriodizationModelUtils.nameToId[name] ?? name,

        'sets': setsWithData.map((s) {
          final exId = PeriodizationModelUtils.nameToId[name] ?? name;
          final isBwEx = PeriodizationModelUtils.isBodyweightExercise(
              id: exId, name: name);

          if (isBwEx) {
            final added = s.weight ?? 0.0; // user typed "weight added"
            final abs = PeriodizationModelUtils.toAbsoluteWeight(
              uid: uid,
              displayAddedKg: added,
              exerciseId: exId,
              exerciseName: name,
              asOfDate: _selectedDate, // ← DateTime for correct retro logic
            );
            return {
              'reps': s.reps ?? 0,
              'weight': abs,
              // ✅ persist ABSOLUTE for math/history
              'weightAdded': added,
              // ✅ persist ADDED for stable display
              'addedWeight': added,
              // 👈 add this key so upsert/loader can rely on it
              'rir': s.rir ?? 0.0,
              if (s.velocity != null) 'velocity': s.velocity,
              if ((s.notes ?? '')
                  .trim()
                  .isNotEmpty) 'notes': s.notes,
            };
          }

          // Non-BW exercises unchanged
          return {
            'reps': s.reps ?? 0,
            'weight': s.weight ?? 0.0,
            'rir': s.rir ?? 0.0,
            if (s.velocity != null) 'velocity': s.velocity,
            if ((s.notes ?? '')
                .trim()
                .isNotEmpty) 'notes': s.notes,
          };
        }).toList(),
      };


      // Saved-format marker:
      // - On global Save -> only if exercise has at least one set with BOTH weight & reps
      // - Otherwise -> respect per-exercise "Done" state
      final bool markThisSaved = markAllSaved
          ? _hasSetWithWeightAndReps(i)
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


  Future<void> _upsertWorkoutToFirestore({
    required bool alsoPushToBB2,
    bool markAllSaved = false,
  }) async {
    print(
        '🚀 [WES upsert] Starting upsert (markAllSaved=$markAllSaved, pushBB2=$alsoPushToBB2)');

    // Ensure controllers → _workoutSets are in sync for the first-exit case
    await _persistDraftLocally();
    bool _printedUpsertBw = false;
    // Resolve the acting UID WITHOUT using context (dispose-safe)
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
    final existingSnap = await docRef.get();
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
    print('📦 [WES upsert] Built payload: newExercises=${newExercises
        .length} (hadExisting=$hadExisting)');

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


    // NEW: Exercises now reflect ONLY rows with qualifying sets currently in UI.
// (If a previously completed row was cleared, it is excluded here and
// represented in wesPlannedExercises above.)
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

      await docRef.set(payload, SetOptions(merge: false));
      print('✅ [WES upsert] Firestore write complete.');

      // 🔁 Keep public profile stats fresh (only if there are completed sets)
      final hasExercises = ((payload['exercises'] as List?)?.isNotEmpty ??
          false);
      if (hasExercises) {
        try {
          await updateStatsFromWorkout(uid: uid, workout: payload);
          print('🏷️ [WES upsert] Stats snapshot updated.');
        } catch (e) {
          print('⚠️ [WES upsert] Stats snapshot update failed: $e');
        }
      }


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
      print('❌ [WES upsert] Firestore write failed: $e');
      print(st);
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


  Future<void> _saveWorkout() async {
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
    await _upsertWorkoutToFirestore(alsoPushToBB2: true, markAllSaved: true);

    // 3) UI hint
    if (mounted) {
      final msg = (eligibleCount > 0)
          ? 'Saved. $eligibleCount exercise${eligibleCount == 1
          ? ''
          : 's'} marked Done.'
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
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(
        2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
    final draftKey = 'workout_draft_$dateKey';
    final timestampKey = 'draft_last_saved_$dateKey';

    final workoutDraft = {
      'name': _workoutNameController.text,
      'date': _selectedDate.toIso8601String(),
      'exercises': _selectedExercisesWithCircuits,
      'sets': _workoutSets.map((setsForExercise) {
        return setsForExercise
            .map((set) =>
        {
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
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(
        2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
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


  Future<void> _mergeNewBB2ExercisesIntoDraft() async {
    final _tMergeBB2 = Stopwatch()
      ..start();
    print('⏱️ [WES] _mergeNewBB2ExercisesIntoDraft started');
    // 👇 NEW: fast gate to avoid double-running for the same (uid, date)
    final uidGate = UserContext
        .of(context, listen: false)
        .currentUid;
    final sameAsLast = (_lastMergedUid == uidGate) &&
        (_lastMergedDate == _selectedDate);
    if (_hasCompletedInitialMergeForThisDate && sameAsLast) {
      print(
          '⏭️ [WES] _mergeNewBB2ExercisesIntoDraft skipped (already completed for uid=$uidGate date=$_selectedDate)');
      return;
    }
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

      final weekIndex = (daysSinceStart / 7).floor();
      final dayIndex = daysSinceStart % 7;

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
                if (srvList.length !=
                    bb2Exercises.length /* (optional: deep diff) */) {
                  if (mounted) setState(() {}); // minimal UI tick after server hydrate
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
                  if (srvList.length !=
                      bb2Exercises.length /* (optional: deep diff) */) {
                    if (mounted) setState(() {}); // minimal repaint after server hydrate
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
        final ci = (ex['circuitIndex'] ?? 0) as int;
        _bb2PlannedKeysForSelectedDate.add(_wesKeyPrefId(name, ci));
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

      final existingKeys = _selectedExercisesWithCircuits
          .map<String>((e) =>
          _exerciseKey(
            ((e['name'] ?? '') as String).trim(),
            (e['circuitIndex'] ?? 0) as int,
          ))
          .toSet();

      final newOnes = bb2Exercises.where((ex) => !existingKeys.contains(_k(ex)))
          .toList();
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
        });

        // Seed initial values for newly added rows (prefer flat; else sets[0])
        for (final newEx in newOnes) {
          final nameKey = (newEx['name'] ?? '').toString().trim().toLowerCase();
          if (nameKey.isEmpty || _resolvedBB2Values.containsKey(nameKey))
            continue;

          final flatReps = newEx['reps'];
          final flatWeight = newEx['weight'];
          final flatRir = newEx['rir'];
          final flatAdded = (newEx['addedWeight'] as num?)?.toDouble()
              ?? (newEx['weightAdded'] as num?)?.toDouble(); // legacy fallback

          if (flatReps != null || flatWeight != null || flatRir != null) {
            _resolvedBB2Values[nameKey] = {
              'reps': flatReps,
              'weight': flatWeight,
              'rir': flatRir,
              'addedWeight': flatAdded,
              // ✅ preserve BB2’s addedWeight for hydration
            };
            print(
                '🧠 [WES Merge] Injected FLAT BB2 values for $nameKey = ${_resolvedBB2Values[nameKey]}');
            debugPrint('🧾[BB2→WES flat] name=$nameKey '
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
            _resolvedBB2Values[nameKey] = {
              'reps': firstSet['reps'],
              'weight': firstSet['weight'],
              'rir': firstSet['rir'],
              'addedWeight': setAdded, // 👈 carry addedWeight
            };
            print(
                '🧠 [WES Merge] Injected SETS[0] BB2 values for $nameKey = ${_resolvedBB2Values[nameKey]}');
            debugPrint('🧾[BB2→WES sets0] name=$nameKey '
                'isBw=${PeriodizationModelUtils.isBodyweightExercise(
                name: (newEx['name'] ?? '').toString())} '
                'reps=${firstSet['reps']} weight(abs)=${firstSet['weight']} '
                'addedWeight=$setAdded rir=${firstSet['rir']}');
          } else {
            // Even if there are no numbers, keep the exercise row so the user can edit it.
            _resolvedBB2Values[nameKey] = {
              'reps': null,
              'weight': null,
              'rir': null,
            };
            print(
                'ℹ️ [WES Merge] No values found for $nameKey — seeding empty controllers');
          }

// ⬇️ INSERT HYDRATION BLOCK HERE
          if (_resolvedBB2Values.containsKey(nameKey)) {
            final values = _resolvedBB2Values[nameKey]!;
            debugPrint('➡️[WES Hydrate BEGIN] nameKey=$nameKey values=$values');

            final idx = _selectedExercisesWithCircuits.indexWhere((e) =>
            (e['name'] as String).trim().toLowerCase() == nameKey);

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

                sets[0].reps = (values['reps'] as num?)?.toInt();
                sets[0].weight = display;
                sets[0].rir = (values['rir'] as num?)?.toDouble();
              }

              debugPrint(
                  '🧮[WES Hydrate Check] ex=${_selectedExercisesWithCircuits[idx]['name']} '
                      'repsField="${_repsControllers[idx][0].text}" '
                      'weightField="${_weightControllers[idx][0].text}"');

              if (_repsControllers.length > idx &&
                  _repsControllers[idx].isNotEmpty) {
                _repsControllers[idx][0].text =
                    values['reps']?.toString() ?? '';
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

                _weightControllers[idx][0].text = display?.toString() ?? '';

                print(
                    '🪙 [WES HydrateWeight] ex=$exName isBW=$isBwEx abs=$abs added=$added display=$display '
                        '→ wrote text="${_weightControllers[idx][0].text}"');

                _rirControllers[idx][0].text = values['rir']?.toString() ?? '';
              }
            }
          }
        }

        print('[WES] Merged ${newOnes.length} exercise(s) into draft');
        _hasCompletedInitialMergeForThisDate =
        true; // ✅ gate further same-session calls
        await _saveWorkoutDraftToCache();
      }
    } finally {
      _tMergeBB2.stop();
      print('⏱️ [WES] _mergeNewBB2ExercisesIntoDraft took ${_tMergeBB2
          .elapsedMilliseconds}ms');
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
        if (_hasMissedForToday && !_didShineThisOpen) {
          _didShineThisOpen = true;
          _catchupShineCtl
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
    final _tSelect = Stopwatch()
      ..start(); // ⏱️ start total timer
    print('⏱️ [WES] _selectDate started');

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

    print('📆 [WES] Date changed to: ${DateFormat('yyyy-MM-dd').format(
        pickedDate)}');

    _cachedProgressedValues.clear();

    // 💾 Do NOT block the UI: best-effort autosave previous day in background
    if (mounted) {
      // ignore: unawaited_futures
      (() async {
        try {
          print('💾 [WES] Autosaving current date in background…');
          await _upsertWorkoutToFirestore(
              alsoPushToBB2: true, markAllSaved: false);
          await _persistDraftLocally();
          await _persistSavedFlagsLocally();
        } catch (e) {
          print('⚠️ [WES] Background autosave failed (non-fatal): $e');
        }
      })();
    }

    // 2️⃣ Update selected date and clear UI state
    print('🧼 [WES] Clearing UI and updating selected date...');
    setState(() {
      _selectedDate = pickedDate;
      _workoutNameController.text = _formatWorkoutDate(_selectedDate);

      _selectedExercisesWithCircuits.clear();
      _workoutSets.clear();
      _repsControllers.clear();
      _weightControllers.clear();
      _rirControllers.clear();
      _velocityControllers.clear();
      _notesControllers.clear();

      _resolvedBB2Values.clear();

      _savedExerciseKeysForDate.clear();
      _pendingChanges = false;
      _lastSavedHash = null;
    });

    // ⚡ SUPER-CACHE FIRST PAINT: try WESInitSnapshot for the picked date
    try {
      final uid = _cachedUid;
      final bid = _selectedBlockId;
      if (uid != null && bid != null) {
        final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);
        final snap = await BlockPlanCache.getInitSnapshot(
          uid: uid, blockId: bid, dateYmd: ymd,
        );
        if (snap != null) {
          final plannedList = snap.plannedExercisesJson.isNotEmpty
              ? (jsonDecode(snap.plannedExercisesJson) as List)
              : const [];

          if (plannedList.isNotEmpty) {
            setState(() {
              for (final raw in plannedList) {
                final m = Map<String, dynamic>.from(raw as Map);
                final name = (m['name'] ?? '').toString().trim();
                final ci = (m['circuitIndex'] ?? 0) as int;
                if (name.isEmpty) continue;

                _selectedExercisesWithCircuits.add(
                    {'name': name, 'circuitIndex': ci});
                _workoutSets.add(
                    List.generate(_defaultSets, (_) => SetDetails()));
                _repsControllers.add(List.generate(
                    _defaultSets, (_) => TextEditingController()));
                _weightControllers.add(List.generate(
                    _defaultSets, (_) => TextEditingController()));
                _rirControllers.add(List.generate(
                    _defaultSets, (_) => TextEditingController()));
                _velocityControllers.add(List.generate(
                    _defaultSets, (_) => TextEditingController()));
                _notesControllers.add(List.generate(
                    _defaultSets, (_) => TextEditingController()));
              }
            });
            print('⚡ [WES] Snapshot planned rows painted for $ymd (${plannedList
                .length})');
          }

          // (Optional) You can also hydrate previous sets from snap.previousWorkoutJson here
          // if you want the controllers populated instantly too.
        }
      }
    } catch (e) {
      print('⚠️ [WES] Snapshot hydrate on date switch failed: $e');
    }

    // 3️⃣ Load locally saved draft (if available) — now that rows exist
    //    (This fills any locally drafted sets/notes for the picked date.)
    print('📂 [WES] Attempting to load local draft for new date...');
    await _loadDraftLocallyIfAvailable();

    // 4️⃣ Kick the heavy hitters in PARALLEL (both are cache/isar-first now)
    print('🔁 [WES] Kicking BB2 merge + existing overlay in parallel...');
    await Future.wait([
      _mergeNewBB2ExercisesIntoDraft(),
      _loadExistingWorkoutIfAny(),
    ]);

    // 5️⃣ Ensure listeners are attached in case controllers resized
    _attachDirtyListeners();

    print('✅ [WES] Date switch complete.');
    _tSelect.stop();
    print('⏱️ [WES] _selectDate total = ${_tSelect.elapsedMilliseconds}ms');
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

    print('➡️ [WES] Push ExerciseDetailsScreen id="${exercise
        .id}" name="${exercise.name}"');
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ExerciseDetailsScreen(
              exerciseId: exerciseId,
              exerciseName: exerciseName, // optional, but good for title
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
        builder: (context) =>
            TopSetsScreen(
              exerciseName: exerciseName,
              recentWorkouts: recentWorkouts,
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

    return AnimatedBuilder(
      animation: _catchupShineAnim,
      builder: (context, _) {
        // t goes 0 → 1 once per open
        final t = _catchupShineAnim.value;

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
                        i >= _rirControllers.length) {
                      print(
                          "⚠️ Skipping index $i due to mismatched list lengths");
                      return SizedBox(
                        key: ValueKey(
                            'skipped_$i'), // 🔑 Ensure even placeholder has a key
                      );
                    }

                    final current = _selectedExercisesWithCircuits[i];
                    final prev = i > 0
                        ? _selectedExercisesWithCircuits[i - 1]
                        : null;
                    final isNewCircuit = i == 0 ||
                        current['circuitIndex'] != prev?['circuitIndex'];

// 🔑 stable key for this row
                    final name = (current['name'] ?? '').toString().trim();
                    final ci   = (current['circuitIndex'] ?? 0) as int;
                    final rowKey = '${name.toLowerCase()}|$ci';

                    return Column(
                      key: ValueKey('col_$rowKey'),



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
                          key: ValueKey(rowKey),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            color: Colors.red,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 16),
                            child: const Icon(
                                Icons.delete, color: Colors.white),
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
                              future: _initialLoad,
                              // ✅ Keep the wrapper, but do NOT gate rendering on snapshot
                              builder: (context, snapshot) {
                                // 🔓 No gating: always render the row; reconciliation happens in background
                                final bool isSaved = _isExerciseSaved(i);

                                return Card(

                                  key: ValueKey("card_$i"),
                                  // 👈 Unique per exercise
                                  color: Colors.blueGrey.shade700,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  margin: const EdgeInsets.only(
                                      left: 0, top: 2, right: 0, bottom: 0),

                                  child: ExpansionTile(
                                    key: ValueKey('wes_ex_tile_${i}_${isSaved
                                        ? 'saved'
                                        : 'live'}'),
                                    // force rebuild when state flips
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

                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // If already saved → show the green "Saved" pill (as you have now)
                                        if (isSaved) ...[
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 4, vertical: 4),
                                            margin: const EdgeInsets.only(
                                                right: 1),
                                            decoration: BoxDecoration(
                                              color: Colors.green.withOpacity(
                                                  0.15),
                                              borderRadius: BorderRadius
                                                  .circular(12),
                                              border: Border.all(
                                                  color: Colors.green
                                                      .withOpacity(0.6)),
                                            ),
                                            child: const Row(
                                              children: [
                                                Icon(Icons.check_circle,
                                                    size: 14,
                                                    color: Colors.green),
                                                SizedBox(width: 4),
                                                Text('Done', style: TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.green)),
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
                                                _selectedExercisesWithCircuits[i]['name'] ??
                                                    '');
                                          },
                                        ),
                                        const SizedBox(width: 1),
                                        ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors
                                                .blueGrey[700],
                                          ),
                                          onPressed: () {
                                            _navigateToTopSets(
                                                _selectedExercisesWithCircuits[i]['name'] ??
                                                    '');
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
                                                                    _selectedExercisesWithCircuits[
                                                                    i]
                                                                    ['name']
                                                                        ?.trim() ??
                                                                        '';
                                                                final targetWeight = _isInitialized
                                                                    ? set1SuggestedWeight(
                                                                    i)
                                                                    : 20.0;

                                                                final history =
                                                                    PeriodizationModelUtils
                                                                        .topSetsByExercise[
                                                                    exerciseName] ??
                                                                        [];

                                                                final matchingSets = history
                                                                    .where((
                                                                    s) =>
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
                                                                      .toStringAsFixed(
                                                                      1)} kg';

                                                                matchingSets
                                                                    .sort((a,
                                                                    b) {
                                                                  final repsA =
                                                                      a['reps'] ??
                                                                          0.0;
                                                                  final repsB =
                                                                      b['reps'] ??
                                                                          0.0;
                                                                  final rirA =
                                                                      a['rir'] ??
                                                                          99.0;
                                                                  final rirB =
                                                                      b['rir'] ??
                                                                          99.0;

                                                                  if (repsB
                                                                      .compareTo(
                                                                      repsA) !=
                                                                      0)
                                                                    return repsB
                                                                        .compareTo(
                                                                        repsA);
                                                                  return rirA
                                                                      .compareTo(
                                                                      rirB);
                                                                });

                                                                final best =
                                                                    matchingSets
                                                                        .first;
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
                                                                color: Colors
                                                                    .white24,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                                height: 0),
                                                            Builder(
                                                              builder: (
                                                                  context) {
                                                                if (!_isInitialized) {
                                                                  return const Text(
                                                                    'Loading...',
                                                                    style: TextStyle(
                                                                      fontSize: 10.0,
                                                                      fontWeight: FontWeight
                                                                          .bold,
                                                                      color: Colors
                                                                          .white54,
                                                                    ),
                                                                  );
                                                                }

                                                                final exerciseName = _selectedExercisesWithCircuits[i]['name']
                                                                    ?.trim() ??
                                                                    '';
                                                                final repTarget = set1SuggestedReps(
                                                                    i); // no `.round()` yet

                                                                if (repTarget ==
                                                                    null) {
                                                                  return const Text(
                                                                    'Loading...',
                                                                    style: TextStyle(
                                                                      fontSize: 10.0,
                                                                      fontWeight: FontWeight
                                                                          .bold,
                                                                      color: Colors
                                                                          .white54,
                                                                    ),
                                                                  );
                                                                }

                                                                final roundedTarget = repTarget
                                                                    .round();
                                                                final history = PeriodizationModelUtils
                                                                    .topSetsByExercise[exerciseName] ??
                                                                    [];

                                                                final matchingSets = history
                                                                    .where((s) {
                                                                  final reps = (s['reps'] as num?)
                                                                      ?.round();
                                                                  return reps ==
                                                                      repTarget;
                                                                }).toList();

                                                                if (matchingSets
                                                                    .isEmpty) {
                                                                  return Text(
                                                                    'No previous sets at $repTarget reps',
                                                                    style: const TextStyle(
                                                                      fontSize: 10.0,
                                                                      fontWeight: FontWeight
                                                                          .bold,
                                                                      color: Colors
                                                                          .white54,
                                                                    ),
                                                                  );
                                                                }

                                                                matchingSets
                                                                    .sort((a,
                                                                    b) {
                                                                  final wa = a['weight'] ??
                                                                      0.0;
                                                                  final wb = b['weight'] ??
                                                                      0.0;
                                                                  return (wb as num)
                                                                      .compareTo(
                                                                      wa as num);
                                                                });

                                                                final best = matchingSets
                                                                    .first;
                                                                double weight = (best['weight'] as num?)
                                                                    ?.toDouble() ??
                                                                    0.0;
                                                                final isBwEx = PeriodizationModelUtils
                                                                    .isBodyweightExercise(
                                                                  id: PeriodizationModelUtils
                                                                      .nameToId[exerciseName] ??
                                                                      exerciseName,
                                                                  name: exerciseName,
                                                                );
                                                                if (isBwEx) {
                                                                  weight =
                                                                      PeriodizationModelUtils
                                                                          .toDisplayAddedWeight(
                                                                        uid: _cachedUid ??
                                                                            FirebaseAuth
                                                                                .instance
                                                                                .currentUser
                                                                                ?.uid ??
                                                                            '',
                                                                        absoluteKg: weight,
                                                                        exerciseId: PeriodizationModelUtils
                                                                            .nameToId[exerciseName] ??
                                                                            exerciseName,
                                                                        exerciseName: exerciseName,
                                                                        asOfDate: (best['date'] is DateTime)
                                                                            ? best['date']
                                                                            : null,
                                                                      );
                                                                }

                                                                final rir = best['rir'];

                                                                return Text(
                                                                  'Best at $repTarget reps: ${weight
                                                                      .toStringAsFixed(
                                                                      1)} kg @ RIR ${rir
                                                                      .toString()}',
                                                                  style: const TextStyle(
                                                                    fontSize: 10.0,
                                                                    fontWeight: FontWeight
                                                                        .bold,
                                                                    color: Colors
                                                                        .white54,
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
                                                                  '')
                                                              .toStringAsFixed(
                                                              1)}Kg',
                                                          style: const TextStyle(
                                                            fontSize: 12.0,
                                                            fontWeight: FontWeight
                                                                .bold,
                                                            color: Colors
                                                                .blueGrey,
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
                                                            child: Text('E1RM',
                                                                style: _headerStyle)),
                                                        const SizedBox(
                                                            width: 4),

                                                        // ✅ Conditionally include Velocity (for this exercise only)
                                                        if (_showVelocityByExercise[
                                                        (_selectedExercisesWithCircuits[i]['name'] as String)
                                                            .toLowerCase()] ==
                                                            true) ...[
                                                          const SizedBox(
                                                              width: 45,
                                                              child: Text(
                                                                  'Vel.',
                                                                  style: _headerStyle)),
                                                          const SizedBox(
                                                              width: 4),
                                                        ],
                                                        const SizedBox(
                                                            width: 120,
                                                            child: Text('Notes',
                                                                style: _headerStyle)),
                                                      ],
                                                    ),


                                                    const SizedBox(height: 2),

                                                    // 🟩 Input Row
                                                    Row(
                                                      children: [
                                                        // Weight
                                                        SizedBox(
                                                          width: 76,
                                                          child: (j == 0)
                                                              ? TextField(
                                                            controller: _weightControllers[i][j],
                                                            keyboardType: TextInputType
                                                                .number,
                                                            decoration: InputDecoration(
                                                              hintText: !_isInitialized
                                                                  ? ''
                                                                  : (() {
                                                                print("🐞 [Debug] set1SuggestedWeight($i) about to run, _isInitialized=$_isInitialized");
                                                                final w = set1SuggestedWeight(i);
                                                                print("🐞 [Debug] set1SuggestedWeight($i) returned $w");
                                                                return formatWeight(w);
                                                              })(),
                                                              hintStyle: const TextStyle(
                                                                color: Colors
                                                                    .grey,
                                                                fontStyle: FontStyle
                                                                    .italic,
                                                                fontSize: 12,
                                                              ),
                                                              contentPadding: const EdgeInsets
                                                                  .only(
                                                                  left: 2),
                                                              // align with RIR/E1RM
                                                              enabledBorder: const UnderlineInputBorder(
                                                                borderSide: BorderSide(
                                                                    color: Colors
                                                                        .white,
                                                                    width: 1),
                                                              ),
                                                              focusedBorder: const UnderlineInputBorder(
                                                                borderSide: BorderSide(
                                                                    color: Colors
                                                                        .white,
                                                                    width: 1.5),
                                                              ),
                                                              disabledBorder: const UnderlineInputBorder(
                                                                borderSide: BorderSide(
                                                                    color: Colors
                                                                        .white,
                                                                    width: 1),
                                                              ),
                                                            ),
                                                            onChanged: (
                                                                value) =>
                                                                setState(() {}),
                                                            style: TextStyle(
                                                              color: _weightControllers[i][j]
                                                                  .text.isEmpty
                                                                  ? Colors.grey
                                                                  : Colors
                                                                  .white,
                                                              fontSize: 12, // align with E1RM font size
                                                            ),
                                                          )
                                                              : FutureBuilder<
                                                              String>(
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

                                                              return TextField(
                                                                controller: _weightControllers[i][j],
                                                                keyboardType: TextInputType
                                                                    .number,
                                                                decoration: InputDecoration(
                                                                  hintText: hint,
                                                                  // range like "50–52.5", disappears on input
                                                                  hintStyle: const TextStyle(
                                                                    color: Colors
                                                                        .grey,
                                                                    fontStyle: FontStyle
                                                                        .italic,
                                                                    fontSize: 12,
                                                                  ),
                                                                  contentPadding: const EdgeInsets
                                                                      .only(
                                                                      left: 2),
                                                                  enabledBorder: const UnderlineInputBorder(
                                                                    borderSide: BorderSide(
                                                                        color: Colors
                                                                            .white,
                                                                        width: 1),
                                                                  ),
                                                                  focusedBorder: const UnderlineInputBorder(
                                                                    borderSide: BorderSide(
                                                                        color: Colors
                                                                            .white,
                                                                        width: 1.5),
                                                                  ),
                                                                  disabledBorder: const UnderlineInputBorder(
                                                                    borderSide: BorderSide(
                                                                        color: Colors
                                                                            .white,
                                                                        width: 1),
                                                                  ),
                                                                ),
                                                                onChanged: (
                                                                    value) =>
                                                                    setState(() {}),
                                                                style: TextStyle(
                                                                  color: _weightControllers[i][j]
                                                                      .text
                                                                      .isNotEmpty
                                                                      ? Colors
                                                                      .white
                                                                      : Colors
                                                                      .grey,
                                                                  fontSize: 12,
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
                                                              ? TextField(
                                                            controller: _repsControllers[i][j],
                                                            keyboardType: TextInputType
                                                                .number,
                                                            decoration: InputDecoration(
                                                              contentPadding: const EdgeInsets
                                                                  .only(
                                                                  left: 2),
                                                              // align with RIR/E1RM
                                                              hintText: (_isLoadingData || !_isInitialized)
                                                                  ? ''
                                                                  : (() {
                                                                print("🐞 [Debug] set1SuggestedReps($i) about to run, "
                                                                    "_isInitialized=$_isInitialized _isLoadingData=$_isLoadingData");
                                                                final r = set1SuggestedReps(i);
                                                                print("🐞 [Debug] set1SuggestedReps($i) returned $r");
                                                                return (r?.toInt().toString() ?? '');
                                                              })(),

                                                              hintStyle: const TextStyle(
                                                                color: Colors
                                                                    .grey,
                                                                fontStyle: FontStyle
                                                                    .italic,
                                                                fontSize: 12,
                                                              ),
                                                              enabledBorder: const UnderlineInputBorder(
                                                                borderSide: BorderSide(
                                                                    color: Colors
                                                                        .white,
                                                                    width: 1),
                                                              ),
                                                              focusedBorder: const UnderlineInputBorder(
                                                                borderSide: BorderSide(
                                                                    color: Colors
                                                                        .white,
                                                                    width: 1.5),
                                                              ),
                                                              disabledBorder: const UnderlineInputBorder(
                                                                borderSide: BorderSide(
                                                                    color: Colors
                                                                        .white,
                                                                    width: 1),
                                                              ),
                                                            ),
                                                            onChanged: (
                                                                value) =>
                                                                setState(() {}),
                                                            style: TextStyle(
                                                              color: _repsControllers[i][j]
                                                                  .text
                                                                  .isNotEmpty
                                                                  ? Colors.white
                                                                  : Colors.grey,
                                                              fontSize: 12,
                                                            ),
                                                          )
                                                              : FutureBuilder<
                                                              String>(
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

                                                              return TextField(
                                                                controller: _repsControllers[i][j],
                                                                keyboardType: TextInputType
                                                                    .number,
                                                                decoration: InputDecoration(
                                                                  contentPadding: const EdgeInsets
                                                                      .only(
                                                                      left: 2),
                                                                  hintText: hint,
                                                                  // "4–6", disappears on input
                                                                  hintStyle: const TextStyle(
                                                                    color: Colors
                                                                        .grey,
                                                                    fontStyle: FontStyle
                                                                        .italic,
                                                                    fontSize: 12,
                                                                  ),
                                                                  enabledBorder: const UnderlineInputBorder(
                                                                    borderSide: BorderSide(
                                                                        color: Colors
                                                                            .white,
                                                                        width: 1),
                                                                  ),
                                                                  focusedBorder: const UnderlineInputBorder(
                                                                    borderSide: BorderSide(
                                                                        color: Colors
                                                                            .white,
                                                                        width: 1.5),
                                                                  ),
                                                                  disabledBorder: const UnderlineInputBorder(
                                                                    borderSide: BorderSide(
                                                                        color: Colors
                                                                            .white,
                                                                        width: 1),
                                                                  ),
                                                                ),
                                                                onChanged: (
                                                                    value) =>
                                                                    setState(() {}),
                                                                style: TextStyle(
                                                                  color: _repsControllers[i][j]
                                                                      .text
                                                                      .isNotEmpty
                                                                      ? Colors
                                                                      .white
                                                                      : Colors
                                                                      .grey,
                                                                  fontSize: 12,
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
                                                          child: TextField(
                                                            controller: _rirControllers[i][j],
                                                            keyboardType: TextInputType
                                                                .number,
                                                            decoration: InputDecoration(
                                                              contentPadding: const EdgeInsets
                                                                  .only(
                                                                  left: 2),
                                                              hintText: (j == 0)
                                                                  ? set1RIR(i)
                                                                  .toString()
                                                                  : (j == 1)
                                                                  ? set2RIR(i)
                                                                  .toString()
                                                                  : (j == 2)
                                                                  ? set3RIR(i)
                                                                  .toString()
                                                                  : '1',
                                                              hintStyle: const TextStyle(
                                                                color: Colors
                                                                    .grey,
                                                                fontStyle: FontStyle
                                                                    .italic,
                                                                fontSize: 12,
                                                              ),
                                                            ),
                                                            onChanged: (
                                                                value) =>
                                                                setState(() {}),
                                                            style: TextStyle(
                                                              color: _rirControllers[i][j]
                                                                  .text.isEmpty
                                                                  ? Colors.grey
                                                                  : Colors
                                                                  .white,
                                                            ),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                            width: 4),


                                                        // E1RM
                                                        SizedBox(
                                                          width: 55,
                                                          child: TextField(
                                                            controller: TextEditingController(
                                                              text: e1rmDisplayForCell(
                                                                  i, j)
                                                                  .toStringAsFixed(
                                                                  1),
                                                            ),

                                                            enabled: false,
                                                            readOnly: true,
                                                            decoration: const InputDecoration(
                                                              hintText: '',
                                                              hintStyle: TextStyle(
                                                                color: Colors
                                                                    .grey,
                                                                fontStyle: FontStyle
                                                                    .italic,
                                                                fontSize: 12,
                                                              ),
                                                              contentPadding: EdgeInsets
                                                                  .only(
                                                                  left: 4),
                                                              enabledBorder: UnderlineInputBorder(
                                                                borderSide: BorderSide(
                                                                    color: Colors
                                                                        .white,
                                                                    width: 1),
                                                              ),
                                                              disabledBorder: UnderlineInputBorder(
                                                                borderSide: BorderSide(
                                                                    color: Colors
                                                                        .white,
                                                                    width: 1),
                                                              ),
                                                              focusedBorder: UnderlineInputBorder(
                                                                borderSide: BorderSide(
                                                                    color: Colors
                                                                        .white,
                                                                    width: 1.5),
                                                              ),
                                                            ),
                                                            style: TextStyle(
                                                              fontSize: 12,
                                                              color: (_weightControllers[i][j]
                                                                  .text
                                                                  .isNotEmpty ||
                                                                  _repsControllers[i][j]
                                                                      .text
                                                                      .isNotEmpty ||
                                                                  _rirControllers[i][j]
                                                                      .text
                                                                      .isNotEmpty)
                                                                  ? Colors.white
                                                                  : Colors.grey,
                                                            ),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                            width: 4),

                                                        // ✅ Conditionally show Velocity
                                                        if (_showVelocityByExercise[
                                                        (_selectedExercisesWithCircuits[i]['name'] as String)
                                                            .toLowerCase()] ==
                                                            true) ...[
                                                          SizedBox(
                                                            width: 45,
                                                            child: TextField(
                                                              controller: _velocityControllers[i][j],
                                                              keyboardType: TextInputType
                                                                  .number,
                                                              decoration: const InputDecoration(
                                                                hintText: '',
                                                                hintStyle: TextStyle(
                                                                  color: Colors
                                                                      .grey,
                                                                  fontStyle: FontStyle
                                                                      .italic,
                                                                  fontSize: 11,
                                                                ),
                                                              ),
                                                              onChanged: (
                                                                  value) =>
                                                                  setState(() {}),
                                                              style: TextStyle(
                                                                color: _velocityControllers[i][j]
                                                                    .text
                                                                    .isEmpty
                                                                    ? Colors
                                                                    .grey
                                                                    : Colors
                                                                    .white,
                                                              ),
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                              width: 4),
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
                                                            onChanged: (
                                                                value) =>
                                                                setState(() {}),
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
      ), // Scaffold
    ); // WillPopScope
  }
}
