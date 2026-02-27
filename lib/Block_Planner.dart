import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:localtest222/Camp_BB2.dart';
import 'template_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'workout_entry_screen.dart';
import 'periodization_model_utils.dart';
import 'core_exercises.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'periodization_model_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'week_planner.dart';
import 'planned_blocks_screen.dart';
import 'package:uuid/uuid.dart';
import 'user_context.dart';
import 'warmup_service.dart';
import 'dart:math' as math;


class Block_Planner extends StatefulWidget {
  const Block_Planner({super.key});

  // 👇 Static parser, same logic you provided
  static Map<String, double> parseIncrements(String incString) {
    final parts = incString
        .split(',')
        .map((s) => double.tryParse(s.trim()))
        .whereType<double>()
        .toList();

    final keys = ['primary', 'secondary', 'tertiary', 'quaternary'];
    final map = <String, double>{};
    for (int i = 0; i < parts.length && i < keys.length; i++) {
      map[keys[i]] = parts[i];
    }
    return map;
  }

  @override
  State<Block_Planner> createState() => _BlockPlannerState();

}

class _BlockPlannerState extends State<Block_Planner> {
  final TextEditingController _blockNameController = TextEditingController();
  List<String> exercises = [];
  final Map<String, String> _exerciseIdToName = {}; // id ➔ name
  Map<String, String> nameToId = {}; // ✅ global map for name → ID
  final TextEditingController _historyInputController = TextEditingController();
  List<String> selectedDays = []; // e.g., ['Mon', 'Wed', 'Fri']
  List<Map<String, dynamic>> weekPlans = [];
  String? blockIdToUse;
  Set<String> _templateExerciseIds = {};
  final GlobalKey<ScaffoldMessengerState> _bpMessengerKey = GlobalKey<ScaffoldMessengerState>();

  bool _isSavedBlock = false;
  bool _didRunInitOnce = false;
  bool _initialBlockIsActive = false;
  bool _hasLocalEdits = false;

  String get userId => UserContext.of(context, listen: false).currentUid;

  ScaffoldMessengerState? _scaffoldMessenger;


  @override
  void dispose() {
    _blockNameController.dispose();
    _historyInputController.dispose();

    // 🏁 Best-effort background save. Non-blocking for navigation.
    Future.microtask(() async {
      try {
        if (blockIdToUse == null) {
          print("ℹ️ [BP.dispose] Skipping save (blockIdToUse is null)");
          return;
        }

        // 1) Persist the full block doc (planned_blocks/{uid}/blocks/{blockId})
        await _savePlannedExercises(suppressSnack: true);

        print('🧪[BP.dispose pre] blockId=$blockIdToUse '
            'exercises.len=${exercises.length} '
            'hasAdd(EFbQl9i9NdYi13F3DqHr)=${exercises.contains('EFbQl9i9NdYi13F3DqHr')} '
            'hasEx(eyh76KELuuO805rZBpMa)=${exercises.contains('eyh76KELuuO805rZBpMa')}');

        print("💾 [BP.dispose] _savePlannedExercises() completed");

        // 2) Mirror per-exercise details to WES-compatible location
        //    Use in-memory exerciseSettings as the source of truth.
        if (exercises.isEmpty) {
          print("ℹ️ [BP.dispose] No exercises to mirror");
          return;
        }

        for (final exerciseId in exercises) {
          final data = exerciseSettings[exerciseId];
          if (data == null) {
            print("⚠️ [BP.dispose] No settings for $exerciseId; skipping mirror");
            continue;
          }

          await FirebaseFirestore.instance
              .collection('users')
              .doc(userId)
              .collection('plannedExerciseDetails')
              .doc(exerciseId)
              .set({
            'progressionModel': data['progressionModel'],
            'periodizationModel': data['periodizationModel'],
            'repTargets': data['repTargets'],
            'rirPlan': data['rirPlan'],
            'rirModel': data['rirModel'],
            'increments': data['increments'],
            'weeklyFrequency': data['weeklyFrequency'],
            'maxWeightXReps': data['maxWeightXReps'],
            'notes': data['notes'] ?? '',
          }, SetOptions(merge: true));

          print("📌 [BP.dispose] Mirrored plannedExerciseDetails for $exerciseId");
        }
      } catch (e) {
        print("❌ [BP.dispose] Background save/mirror error: $e");
      }
    });

    super.dispose();
  }



  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didRunInitOnce) return;

    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    blockIdToUse = args?['blockId'];

    if (blockIdToUse != null) {
      _loadExistingBlock(blockIdToUse!);
    }

    _didRunInitOnce = true;
    _scaffoldMessenger ??= ScaffoldMessenger.maybeOf(context);
  }

  Future<void> _loadExistingBlock(String blockId) async {
    final userId = UserContext.of(context, listen: false).currentUid;

    if (userId == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(blockId)
        .get();

    if (!doc.exists) return;

    final data = doc.data()!;

    final loaded = List<String>.from(data['exercises'] ?? const <String>[]);
    final u = loaded.toSet().length;
    if (u != loaded.length) {
      print('❌ [BP._loadExistingBlock] DUPLICATES IN FIRESTORE exercises: len=${loaded.length} unique=$u');
      print('❌ [BP._loadExistingBlock] exercises=$loaded');
      print('❌ [BP._loadExistingBlock] blockId=$blockId');
    }

    setState(() {
      _blockNameController.text = data['name'] ?? '';
      _blockStartDate = (data['startDate'] as Timestamp).toDate();
      _blockEndDate = (data['endDate'] as Timestamp).toDate();
      selectedDays = List<String>.from(data['selectedDays'] ?? []);
      final loadedExercises = List<String>.from(data['exercises'] ?? const <String>[]);
      final fixed = <String>[];
      for (final id in loadedExercises) {
        if (!fixed.contains(id)) fixed.add(id);
      }
      exercises = fixed;

// 🔧 Self-heal corrupted blocks (safe, idempotent)
      if (fixed.length != loadedExercises.length) {
        FirebaseFirestore.instance
            .collection('planned_blocks')
            .doc(userId)
            .collection('blocks')
            .doc(blockId)
            .update({
          'exercises': fixed,
          'plannedExercises': fixed,
        }).catchError((_) {});
      }

      exerciseSettings = Map<String, Map<String, dynamic>>.from(
        (data['exerciseSettings'] ?? {})
            .map((key, val) => MapEntry(key, Map<String, dynamic>.from(val))),
      );
      _isSavedBlock = true;

      _initialBlockIsActive = data['isActive'] ?? false;
    });
    _loadTemplateExerciseIds();
  }

  Future<void> _loadTemplateExerciseIds() async {
    final uid = userId;
    if (uid == null || blockIdToUse == null) return;
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('templates')
        .get();
    final ids = <String>{};
    int matchedTemplates = 0;
    for (final doc in snapshot.docs) {
      final data = doc.data();
      if (data['blockId'] == blockIdToUse) {
        matchedTemplates++;
        final exList = data['exercises'] as List? ?? [];
        for (final ex in exList) {
          if (ex is Map && ex['exerciseId'] != null) {
            ids.add(ex['exerciseId'].toString());
          }
        }
      }
    }
    debugPrint('BP templates: $matchedTemplates templates, ${ids.length} exerciseIds (for blockId=$blockIdToUse, uid=$uid)');
    if (mounted) setState(() => _templateExerciseIds = ids);
  }

  String _repsText = '';


  DateTime? _blockStartDate;
  DateTime? _blockEndDate;
  Map<String, dynamic> exerciseRepTargets = {};
  Map<String, dynamic> plannedExerciseDetails = {};
  final TextEditingController _blockGoalsController = TextEditingController();

  Map<String, Map<String, dynamic>> exerciseSettings = {};

  bool _isNewBlock = true;
  final bool _didLoadData = false;
  final bool _discardDraft = false;

// 🔁 AUTO-SAVE & SAVE BLOCK FEATURES INTEGRATED
// Add this inside your _BlockPlannerState class:

  dynamic _sanitizeForFirestore(dynamic value) {
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), _sanitizeForFirestore(val)));
    } else if (value is List) {
      return value.map(_sanitizeForFirestore).toList();
    } else if (value is double && value.isNaN) {
      return 0; // Firestore can't store NaN
    }
    return value;
  }


  void _onUpdateSetting(String exerciseId, String key, dynamic value) {
    print("📤 [TOP] Writing to Firestore: $exerciseId → $key = $value");

    // 1) update local map so UI stays in sync
    setState(() {
      exerciseSettings.putIfAbsent(exerciseId, () => {});
      exerciseSettings[exerciseId]![key] = value;
    });

    // 🔁 2) Safely encode value before writing to Firestore
    final safeValue = _sanitizeForFirestore(value);

    final userId = UserContext.of(context, listen: false).currentUid;
    // 🧱 Hard guard: do NOT write unless we have a stable block id
    final bid = blockIdToUse;
    if (bid == null || bid.trim().isEmpty) {
      print("⚠️ [TOP] Skipping write: blockIdToUse is null/empty ($exerciseId → $key)");
      return;
    }

    final docRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(bid);

// ✅ Special-case repTargets so stale instances can't survive merge
    if (key == 'repTargets') {
      docRef.update({
        'exerciseSettings.$exerciseId.repTargets': safeValue,
        'plannedExerciseDetails.$exerciseId.repTargets': safeValue,
      }).catchError((e) {
        print("❌ Failed to save $key for $exerciseId: $e");
      });
      return;
    }

// ✅ Default path for all other keys (keep your existing merge behavior)
    docRef.set({
      'exerciseSettings': {
        exerciseId: {
          key: safeValue,
        },
      },
      'plannedExerciseDetails': {
        exerciseId: {
          key: safeValue,
        },
      },
    }, SetOptions(merge: true)).catchError((e) {
      print("❌ Failed to save $key for $exerciseId: $e");
    });




  }



  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;

      await loadExercisesFromFirestore(); // names/cache first for defaults

      if (args != null && args['blockId'] != null) {
        // Explicit block → load its dates/scaffold, then planned IDs & settings
        await _loadBlockFromFirestore(args['blockId']);
        await _seedDefaultsFor(_idsWithoutSettings(exercises)); // mirror “Save” in picker


      } else if (args != null && args['newBlock'] == true) {
        // ✅ New block = local draft with default exercise IDs (no pointer hydration)

        const defaultExerciseIds = <String>[
          'AmfUWbF1DH3I7qPAdh5k',
          'kTs5fLSTKjUkUZL10iii',
          'heeBViVINHO6tUScSd6y',
          'y5q9OU9OBzZQMkfPzFrf',
          'v2XlZUvFfBUhogOdKtJ8',
          'lVDG90yN6Z8aPjRNV2wc',
          '2yJSfLMfOnNDSeZ7DqZT',
          '9siQpXF2KLCj7M9kCy2m',
          '1XOIXxeLFhgmgjZS9Cyq',
          'Url65Q2RxZa00dkDpUdl',
          'JbthLLjMF6xRvvaUY8PU',
          'ETm055bydWtUCxTMu3MR',
          'wIcMsf2J9cswJRs1GuYX',
          'QkEgE8gnIva2kkNJEfxw',
          'ZKpGshMxFl2dxNmYSATj',
          'ci3KpMTEacH4bw8ZumJW',
          'spGqXXReJNHMcc62YgZX',
          'WPb8rtRTupKIBzgydB5k',
          '0dZrCqZ8M7Q1sAn0zeeb',
          'zn5PgKNRrWo1MTE4wnCy',
          'E6jPE8YYR0KA3xtVaKJo',
          'QacImADmlpljltUvB0dD',
          'eeEXnmSXv90q0rUgGECq',
          'KPewxxYYrhsOp84lIQr5',
          'P88Vj5pBydqmiEzFowag',
          'uY8uJaSFK9czKIX4TLc4',
          'FtayDmR5BVnGS1FXlXLL',
          'OJaMXFKgMnM0X5xttBE1',
          '6SGWrCKfe7KQLThRYXQ6',
          'Z1LpfaEBvHBDMsJ54pgw',
          'z5gs1ilr4DpKlSZaRNG5',
          'LVMQEQl6ZWBcgEUdk2tP',
          'ISXQqOEXLjMrPEs0xjgJ',
          'ocNWJv7xLrlinGmjG6cV',
          'eyh76KELuuO805rZBpMa',
          'RdsGazgdH0xgpjek0n3u',
          'xWpCQO504iGfU3LKLZlD',
          'XM9026peNIu0R8qh7UqY',
        ];

        setState(() {
          exercises = defaultExerciseIds.toSet().toList(); // defensive de-dupe
          selectedDays = const ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
          _isSavedBlock = false;
          _isNewBlock = true;
        });


        // ✅ Default dates for a NEW draft block: start = Monday just gone, length = 9 weeks
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day); // date-only
        final start =
        today.subtract(Duration(days: today.weekday - DateTime.monday));
        final end = start.add(const Duration(days: 62)); // 9 weeks = 63 days, inclusive end

        setState(() {
          _blockStartDate = start;
          _blockEndDate = end;
        });

// ✅ Default block name: "<username> 5 Jan - 8 Mar" (editable)
// reuse existing userId (do NOT redeclare)
        String username = 'Block';



        if (userId != null) {
          final userSnap = await FirebaseFirestore.instance.collection('users').doc(userId).get();
          final udata = userSnap.data() ?? const <String, dynamic>{};

          final u1 = (udata['username'] as String?)?.trim();
          final u2 = (udata['fullName'] as String?)?.trim();
          final fallback = (FirebaseAuth.instance.currentUser?.displayName ?? '')
              .trim()
              .isNotEmpty
              ? FirebaseAuth.instance.currentUser!.displayName!.trim()
              : (FirebaseAuth.instance.currentUser?.email?.split('@').first ?? '').trim();

          username = (u1 != null && u1.isNotEmpty)
              ? u1
              : (u2 != null && u2.isNotEmpty)
              ? u2
              : (fallback.isNotEmpty ? fallback : 'Block');
        }

        final months = const ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        String fmt(DateTime d) => '${d.day} ${months[d.month - 1]}';

        final defaultName = "$username ${fmt(start)} - ${fmt(end)}";

// Only auto-fill if user hasn't typed a name already
        if (_blockNameController.text.trim().isEmpty) {
          _blockNameController.text = defaultName;
        }



        // ✅ Apply existing per-exercise defaults (same path as picker Save)
        await _seedDefaultsFor(_idsWithoutSettings(exercises));

        if (!mounted) return;

// 1) Ensure blockIdToUse exists (and save the base block doc)
        await _savePlannedBlock(setActive: false);

        if (!mounted) return;

// 2) Save plannedExerciseDetails/exerciseSettings/week docs/current_block pointer, etc.
        await _savePlannedExercises(suppressSnack: true);

      }
      else {
        // Default path: load dates & planned → hydrate any missing settings
        await _initData(); // see updated version below
      }

      // Still needed for preview (runs after defaults are in place)
      await _loadRepHistoryAndGenerateReps();
    });
  }


  Future<void> _loadBlockFromFirestore(String blockId) async {
    final userId = UserContext.of(context, listen: false).currentUid;
    if (userId == null) return;


    await loadExercisesFromFirestore(); // ✅ Ensure names are ready

    final doc = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(blockId)
        .get();

    if (!doc.exists) return;

    final data = doc.data()!;
    setState(() {
      _blockStartDate = (data['startDate'] as Timestamp).toDate();
      _blockEndDate = (data['endDate'] as Timestamp).toDate();
      final loadedExercises = List<String>.from(data['exercises'] ?? const <String>[]);
      final fixed = <String>[];
      for (final id in loadedExercises) {
        if (!fixed.contains(id)) fixed.add(id);
      }
      exercises = fixed;

// Optional: write the cleaned list back to Firestore immediately (self-heal)
      if (fixed.length != loadedExercises.length) {
        FirebaseFirestore.instance
            .collection('planned_blocks')
            .doc(userId)
            .collection('blocks')
            .doc(blockId)
            .update({'exercises': fixed}).catchError((_) {});
      }

      selectedDays = List<String>.from(data['selectedDays'] ?? []);

      exerciseSettings = Map<String, Map<String, dynamic>>.from(
        (data['exerciseSettings'] ?? {}).map(
              (key, value) => MapEntry(key, Map<String, dynamic>.from(value)),
        ),
      );
      print("📥 Loaded block $blockId from Firestore");
      print("📥 Found ${exerciseSettings.length} exerciseSettings entries:");

      for (final entry in exerciseSettings.entries) {
        print("🔍 ${entry.key} → ${jsonEncode(entry.value)}");
      }


    });
  }


// Call _autoSaveDraft anywhere changes are made:
// e.g. in setState blocks in _showExercisePickerDialog and onUpdateSetting

// Call this when user wants to save the block permanently
  Future<void> _savePlannedBlock({ required bool setActive }) async {
    final userId = UserContext.of(context, listen: false).currentUid;
    if (userId == null) return;


    final userBlocksRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks');

    // ─── 1) If we're turning this block on, look for any other active one ───
    if (setActive) {
      final activeQuery = await userBlocksRef
          .where('isActive', isEqualTo: true)
          .get();

      // Exclude our own doc if we're editing
      final others = activeQuery.docs.where((d) => d.id != blockIdToUse).toList();

      if (others.isNotEmpty) {
        // 2) Ask the user if they want to override:
        final otherName = others.first.data()['name'] ?? 'Unnamed';
        final override = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Override Active Block?'),
            content: Text(
                "You already have an active block “$otherName”.\n\n"
                    "If you continue this one will become active and the old one will be deactivated."
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true),  child: const Text('OK')),
            ],
          ),
        );

        if (override != true) {
          // user backed out—don't save as active
          return;
        }

        // 3) Deactivate the others in Firestore:
        final batch = FirebaseFirestore.instance.batch();
        for (final doc in others) {
          batch.update(doc.reference, {'isActive': false});
        }
        await batch.commit();
      }
    }

    // ─── Now your existing save logic ───
    final blockDocRef = blockIdToUse != null
        ? userBlocksRef.doc(blockIdToUse)
        : userBlocksRef.doc();
    blockIdToUse ??= blockDocRef.id;

    // ✅ Capture messenger BEFORE any awaits (safe ancestor lookup)
    final messenger = ScaffoldMessenger.of(context);

    await blockDocRef.set({
      'name': _blockNameController.text.trim().isEmpty
          ? 'Unnamed Block'
          : _blockNameController.text.trim(),
      'startDate': _blockStartDate,
      'endDate': _blockEndDate,
      'exercises': exercises,
      'exerciseSettings': exerciseSettings,
      'selectedDays': selectedDays,
      'isActive': setActive,
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (!mounted) return;

    setState(() => _isSavedBlock = true);

    _scaffoldMessenger?.showSnackBar(
      SnackBar(
        content: Text('✅ Block saved${setActive ? ' and activated' : ''}.'),
      ),
    );




    if (setActive) {
      final blockDataRef = FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('block_data')
          .doc('current_block')
          .collection('weeks')
          .doc('week_0')
          .collection('days')
          .doc('day_0');

      final existingDay0 = await blockDataRef.get();
      if (!existingDay0.exists) {
        final start = _blockStartDate;
        String workoutName = 'Week 1';
        if (start != null) {
          final day = start.day;
          final month = [
            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
          ][start.month - 1];
          workoutName = 'Mon $day $month - Week 1';
        }

        await blockDataRef.set({
          'date': start != null ? Timestamp.fromDate(start) : null,

          'circuitStartIndices': [0],
          'exercises': [],
          'workoutName': workoutName,
        });

        print('✅ [BlockPlanner] Stub week_0/day_0 created under block_data/current_block');
      }
    }


  }

  Future<void> _loadRepHistoryAndGenerateReps() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('repHistoryInput') ?? '';

    _historyInputController.text = stored;

    final parsedHistory = PeriodizationModelUtils.parseHistoryInput(stored);
    final reps = PeriodizationModelUtils.REsignatureRepTargets(
      min: 2,
      max: 10,
      history: parsedHistory,
    );

    setState(() {
      _repsText = reps.join(', ');
    });
  }




  List<int> _parseHistoryInput(String input) {
    return input
        .split(',')
        .map((s) => s.replaceAll(RegExp(r'[^0-9]'), '')) // remove non-numeric
        .map((s) => int.tryParse(s))
        .whereType<int>() // remove nulls
        .toList();
  }

  Future<void> _initData() async {
    await loadExercisesFromFirestore();
    await _loadBlockDatesFromFirestore();
    await _loadPlannedExercises();           // sets exercises + any existing settings
    await _seedDefaultsFor(_idsWithoutSettings(exercises));  // complete like picker Save
  }

  List<String> _idsWithoutSettings(List<String> ids) {
    final out = <String>[];
    for (final id in ids) {
      final m = exerciseSettings[id];
      if (m == null || (m is Map && m.isEmpty)) out.add(id);
    }
    return out;
  }


  Future<void> _seedDefaultsFor(List<String> ids) async {
    if (ids.isEmpty) return;

    // ---- 1) Ensure we know name/category/bodyPart for each id ----
    // Try to use what you may already have in memory (_exerciseIdToName, etc.)
    final metaById = <String, Map<String, String>>{};
    final idsNeedingFetch = <String>[];

    for (final id in ids) {
      final name = _exerciseIdToName[id]; // you already maintain this
      // If we don't have enough to resolve defaults, fetch the doc.
      if (name == null || name.isEmpty) {
        idsNeedingFetch.add(id);
      } else {
        metaById[id] = {
          'name': name,
          // category/bodyPart may still be needed for getDefaultSettings
          // we'll fetch them below if missing after this pass
        };
      }
    }

    if (idsNeedingFetch.isNotEmpty) {
      final snaps = await Future.wait(idsNeedingFetch.map(
            (id) => FirebaseFirestore.instance.collection('exercises').doc(id).get(),
      ));
      for (final doc in snaps) {
        final d = doc.data();
        if (d == null) continue;
        final id = doc.id;
        final name = (d['name'] as String?) ?? '';
        final category = (d['category'] as String?) ?? 'Other';
        // bodyPart can be string or list
        String bodyPart = '';
        final bp = d['bodyPart'];
        if (bp is List && bp.isNotEmpty) bodyPart = bp.first.toString();
        if (bp is String) bodyPart = bp;

        _exerciseIdToName[id] = name; // keep your cache aligned
        metaById[id] = {'name': name, 'category': category, 'bodyPart': bodyPart};
      }
    }

    // If any entries still missing category/bodyPart, try to fetch them (cheap single gets)
    final idsMissingCat = metaById.entries
        .where((e) => (e.value['category'] ?? '').isEmpty)
        .map((e) => e.key)
        .toList();
    if (idsMissingCat.isNotEmpty) {
      final snaps = await Future.wait(idsMissingCat.map(
            (id) => FirebaseFirestore.instance.collection('exercises').doc(id).get(),
      ));
      for (final doc in snaps) {
        final d = doc.data();
        if (d == null) continue;
        final id = doc.id;
        final category = (d['category'] as String?) ?? 'Other';
        String bodyPart = '';
        final bp = d['bodyPart'];
        if (bp is List && bp.isNotEmpty) bodyPart = bp.first.toString();
        if (bp is String) bodyPart = bp;

        final cur = metaById[id] ?? <String, String>{};
        cur['category'] = category;
        cur['bodyPart'] = bodyPart;
        metaById[id] = cur;
      }
    }

    // ---- 2) Mirror the dialog's seeding into in-memory settings ----
    bool changed = false;
    for (final id in ids) {
      final meta = metaById[id] ?? const {};
      final name = meta['name'] ?? '';
      final category = (meta['category'] ?? 'Other');
      final bodyPart = (meta['bodyPart'] ?? '');

      // getDefaultSettings exactly like the dialog
      final defaults = getDefaultSettings(name, category, bodyPart);

      // Normalize repTargets to Map<String, Map<String, String>>
      final repTargets = defaults['repTargets'];
      if (repTargets is! Map<String, Map<String, String>>) {
        defaults['repTargets'] = _convertToMap(repTargets);
        print("🔧 Normalized repTargets for $name");
      }

      // Ensure rirPlan is a Map to avoid crashes
      final rirPlan = defaults['rirPlan'];
      if (rirPlan is! Map<String, dynamic>) {
        defaults['rirPlan'] = {};
        print("⚠️ Fallback: Empty rirPlan injected for $name");
      }

      // Keep explicit copy for reseeding after model flips (in-memory only)
      final explicitSeed = defaults['repTargets'];

      // Write to in-memory settings (same as dialog)
      exerciseSettings[id] = {
        ...defaults,
        if (explicitSeed != null) 'explicitRepTargets': explicitSeed,
      };
      changed = true;
    }
    if (changed && mounted) setState(() {});

    // ---- 3) Persist the same fields the dialog persists ----
    for (final id in ids) {
      final settings = exerciseSettings[id];
      if (settings != null) {
        _onUpdateSetting(id, 'repTargets', settings['repTargets']);
        _onUpdateSetting(id, 'defaultSets', settings['defaultSets'] ?? 3);
        _onUpdateSetting(
          id,
          'modelSpecificRepTargets',
          settings['modelSpecificRepTargets'],
        );
      }
    }

    // ---- 4) Silent background save (same as dialog) ----
    Future.microtask(() => _savePlannedExercises(suppressSnack: true));
  }


  Future<void> _loadBlockDatesFromFirestore() async {
    final userId = UserContext.of(context, listen: false).currentUid;
    if (userId == null) return;


    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('block_planner')
        .doc('current_block')
        .get();

    if (doc.exists) {
      final data = doc.data();
      if (data != null && data['blockMeta'] != null) {
        final meta = Map<String, dynamic>.from(data['blockMeta']);
        setState(() {
          _blockStartDate = meta['blockStartDate'] != null
              ? DateTime.parse(meta['blockStartDate'])
              : null;
          _blockEndDate = meta['blockEndDate'] != null
              ? DateTime.parse(meta['blockEndDate'])
              : null;
        });
      }
    }
  }



  Map<String, List<String>> groupedExercises = {};

  Future<void> loadExercisesFromFirestore() async {
    print('🚀 Starting loadExercisesFromFirestore');
    final snapshot =
        await FirebaseFirestore.instance.collection('exercises').get();

// Clear previous
    _exerciseIdToName.clear();
    PeriodizationModelUtils.nameToId.clear(); // ✅ clear shared name → ID map

    final exercises = snapshot.docs.map((doc) {
      final id = doc.id; // 👈 New
      final name = doc['name'] as String;
      final category = doc['category'] as String;
      final bodyPart = doc['bodyPart'] as String;

      _exerciseIdToName[id] = name;
      PeriodizationModelUtils.nameToId[name.trim()] =
          id; // ✅ this is what you're missing

      return {
        'id': id, // 👈 Add id here too if needed later
        'name': name,
        'category': category,
        'bodyPart': bodyPart,
      };
    }).toList();

    setState(() {
      groupedExercises = groupExercisesByCategory(exercises);
    });
  }
//Handles Default Settings for most Exercises

  Map<String, dynamic> getDefaultSettings(String name, String category, String bodyPart) {
    Map<String, dynamic> sanitize(Map<String, dynamic> def) {
      return {
        'weeklyFrequency': def['weeklyFrequency'],
        'increments': Block_Planner.parseIncrements(def['increments']),
        'periodizationModel': def['periodizationModel'],
        'repTargets': _buildRepTargetMap(def['repTargets'], sets: (def['defaultSets'] ?? 3)),
        'rirModel': def['rirModel'],
        'rirPlan': _buildRirPlan(def['rirTargets']),
        'progressionModel': def['progressionModel'],
        'defaultSets': def['defaultSets'] ?? 3,
        // ⬇️ carry overrides so the card can use them on model flip
        'modelSpecificRepTargets': def['modelSpecificRepTargets'],
        // 'modelSpecificSets': def['modelSpecificSets'],  // only if you added it
      };


    }

    // --- Tier 1: Named overrides ---
    if (_explicitDefaults.containsKey(name)) {
      final def = _explicitDefaults[name]!;
      return sanitize(def);
    }

    // --- Tier 2: Group/category fallback ---
    if (_defaultsByGroup.containsKey(category)) {
      final def = _defaultsByGroup[category]!;
      return sanitize(def);
    }

    // --- Tier 3: Isolation override ---
    if (_isIsolation(bodyPart)) {
      final def = _defaultsByGroup['isolation']!;
      return sanitize(def);
    }
    // 🔸 Fallback if unmatched
    return {};
  }


  bool _isIsolation(String bodyPart) {
    return bodyPart.split(',').length == 1;
  }

  Map<String, Map<String, String>> _buildRepTargetMap(List<int> reps, {int sets = 3}) {
    final instanceMap = <String, String>{
      for (int i = 0; i < reps.length; i++) 'instance${i + 1}': '${reps[i]} x $sets'
    };
    return {'week1': instanceMap};
  }



  Map<String, Map<String, Map<String, Map<String, String>>>> _buildRirPlan(List<num> rirTargets) {
    final weekMap = <String, Map<String, Map<String, String>>>{};

    for (int i = 0; i < rirTargets.length; i++) {
      weekMap['session${i + 1}'] = {
        'set1': {
          'rir': rirTargets[i].toStringAsFixed(1),
        }
      };
    }

    return {
      'week1': weekMap,
    };
  }



  final Map<String, Map<String, dynamic>> _explicitDefaults = {
    'Bench Press, Barbell': {
      'weeklyFrequency': 4,
      'increments': '2.5',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [9, 5, 12, 3],
      'rirModel': 'Static RIR',
      'rirTargets': [2, 2, 1.5, 2],
      'defaultSets': 3,
      'progressionModel': 'Smart Progression',
      'modelSpecificRepTargets': {
        'Linear, Classic': [15, 20, 16, 18]  // ← your LC reps for Squat
      },

    },
    'Back Squat, Barbell': {
      'weeklyFrequency': 2,
      'increments': '2.5',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [8, 3],
      'rirModel': 'Static RIR',
      'rirTargets': [2, 3, 2],
      'defaultSets': 3,
      'progressionModel': 'Smart Progression',
      'modelSpecificRepTargets': {
        'Linear, Classic': [15, 19, 12,]  // ← your LC reps for Squat
      },


    },

    'Deadlift, Conventional': {
      'weeklyFrequency': 4,
      'increments': '2.5',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [9, 5, 3, 1],
      'rirModel': 'Static RIR',
      'rirTargets': [3.5, 3, 2, 2],
      'defaultSets': 4,
      'progressionModel': 'Smart Progression',
      'modelSpecificRepTargets': {
        'Linear, Classic': [15, 18, 12, 13]
      },
// (optional, if sets differ for LC)
// 'modelSpecificSets': { 'Linear, Classic': 3 },

    },

    'Deadlift, Sumo': {
      'weeklyFrequency': 3,
      'increments': '2.5',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [15, 9, 5],
      'rirModel': 'Static RIR',
      'rirTargets': [2, 2, 2.5, 2.5],
      'defaultSets': 2,
      'progressionModel': 'Smart Progression',
    },
    'Bulgarian Split Squat, Deficit': {
      'weeklyFrequency': 2,
      'increments': '2.5',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [6, 8],
      'rirModel': 'Static RIR',
      'rirTargets': [3, 3, 2],
      'defaultSets': 3,
      'progressionModel': 'Smart Progression',
    },
    'Chin-Up': {
      'weeklyFrequency': 4,
      'increments': '2.5, 1.25',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [8, 3, 6, 1],
      'rirModel': 'Static RIR',
      'defaultSets': 3,
      'rirTargets': [1.5, 2, 2, 0.5 ],
      'progressionModel': 'Smart Progression',
    },
    'Overhead Dumbbell Press, Unilateral': {
      'weeklyFrequency': 3,
      'increments': '2.5',
      'periodizationModel': 'DUP, By Week',
      'repTargets': [15, 9, 6],
      'rirModel': 'Static RIR',
      'rirTargets': [1, 1.5, 2],
      'defaultSets': 3,
      'progressionModel': 'Smart Progression',
    },
  };

  final Map<String, Map<String, dynamic>> _defaultsByGroup = {
    'Squat Pattern': {
      'weeklyFrequency': 2,
      'increments': '2.5',
      'periodizationModel': 'DUP, By Week',
      'repTargets': [15, 9],
      'rirModel': 'Static RIR',
      'rirTargets': [1, 1.5],
      'defaultSets': 3,
      'progressionModel': 'Smart Progression',
    },
    'Hip Hinge': {
      'weeklyFrequency': 3,
      'increments': '2.5',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [15, 18, 9],
      'rirModel': 'Static RIR',
      'rirTargets': [1, 1, 1.5],
      'defaultSets': 3,
      'progressionModel': 'Smart Progression',
    },
    'Horizontal Press': {
      'weeklyFrequency': 3,
      'increments': '2.5',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [9, 15, 5],
      'rirModel': 'Static RIR',
      'rirTargets': [1, 1, 1],
      'defaultSets': 3,
      'progressionModel': 'Smart Progression',
    },
    'Vertical Press': {
      'weeklyFrequency': 3,
      'increments': '2.5',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [9, 15, 6],
      'rirModel': 'Static RIR',
      'rirTargets': [1.5, 1, 1],
      'defaultSets': 3,
      'progressionModel': 'Smart Progression',
    },
    'Vertical Pull': {
      'weeklyFrequency': 3,
      'increments': '2.5',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [9, 15, 5],
      'rirModel': 'Static RIR',
      'rirTargets': [1.5, 1, 1],
      'defaultSets': 3,
      'progressionModel': 'Smart Progression',
    },
    'Horizontal Pull': {
      'weeklyFrequency': 3,
      'increments': '2.5',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [9, 15, 5],
      'rirModel': 'Static RIR',
      'rirTargets': [1.5, 2, 1],
      'defaultSets': 3,
      'progressionModel': 'Smart Progression',
    },
    'Core': {
      'weeklyFrequency': 4,
      'increments': '5',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [9, 14, 6, 18],
      'rirModel': 'Static RIR',
      'rirTargets': [1, 1, 1, 0.5],
      'defaultSets': 3,
      'progressionModel': 'Smart Progression',
    },
    'isolation': {
      'weeklyFrequency': 4,
      'increments': '2.5, 1.25',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [9, 14, 6, 18],
      'rirModel': 'Static RIR',
      'rirTargets': [1, 1, 1, 0.5],
      'defaultSets': 3,
      'progressionModel': 'Smart Progression',
    },
  };
//Default Settings Block End

  // 🧠 Group exercises by category for dropdown UI
  Map<String, List<String>> groupExercisesByCategory(
      List<Map<String, String>> allExercises) {
    const desiredOrder = [
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

    // Create raw grouping
    final Map<String, List<String>> grouped = {};
    for (final exercise in allExercises) {
      final category = exercise['category'] ?? 'Other';
      final name = exercise['name'] ?? 'Unnamed';

      grouped.putIfAbsent(category, () => []);
      grouped[category]!.add(name);
    }

    // Sort each group alphabetically
    for (final group in grouped.values) {
      group.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }

    // Build ordered output map
    final Map<String, List<String>> orderedGrouped = {};
    for (final category in desiredOrder) {
      if (grouped.containsKey(category)) {
        orderedGrouped[category] = grouped[category]!;
      }
    }

    // Include any extra categories not in desiredOrder
    for (final entry in grouped.entries) {
      if (!orderedGrouped.containsKey(entry.key)) {
        orderedGrouped[entry.key] = entry.value;
      }
    }

    return orderedGrouped;
  }

  void _showExercisePickerDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // 🔥 Fetch exercises from Firestore (including ID)
    final snapshot =
        await FirebaseFirestore.instance.collection('exercises').get();
    final exercisesFromFirestore = snapshot.docs
        .map((doc) => {
              'id': doc.id,
              'name': doc['name'] as String,
              'category': doc['category'] as String,
            })
        .toList();

    // 🧠 Desired category order
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

    // 🧩 Group exercises by category
    final Map<String, List<Map<String, String>>> grouped = {};
    for (final exercise in exercisesFromFirestore) {
      final category = exercise['category'] ?? 'Other';
      grouped.putIfAbsent(category, () => []).add(exercise);
    }

    // 🔠 Sort names within each group
    for (final group in grouped.values) {
      group.sort((a, b) =>
          a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));
    }

    // 🧱 Ordered + any extras
    final Map<String, List<Map<String, String>>> orderedGrouped = {};
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

    // 📦 Expand/collapse state
    final Map<String, bool> expandedGroups = {
      for (final category in orderedGrouped.keys) category: true
    };

    final List<String> selected = await showDialog<List<String>>(
          context: context,
          builder: (ctx) {
            List<String> tempSelected = [
              ...exercises
            ]; // exercises = selected IDs now

            return StatefulBuilder(builder: (context, setLocalState) {
              return AlertDialog(
                backgroundColor: Colors.blueGrey.shade900,
                title: const Text(
                  "Select Exercises",
                  style: TextStyle(color: Colors.white),
                ),
                content: SizedBox(
                  width: double.maxFinite,
                  child: ListView(
                    children: orderedGrouped.entries.map((entry) {
                      final category = entry.key;
                      final exercises = entry.value;
                      final isExpanded = expandedGroups[category] ?? true;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            tileColor: Colors.blueGrey.shade800,
                            title: Text(
                              category,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                            ),
                            trailing: Icon(
                              isExpanded
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              color: Colors.white70,
                            ),
                            onTap: () {
                              setLocalState(() {
                                expandedGroups[category] = !isExpanded;
                              });
                            },
                          ),
                          if (isExpanded)
                            ...exercises.map((exercise) {
                              final id = exercise['id']!;
                              final name = exercise['name']!;
                              final isChecked = tempSelected.contains(id);
                              return CheckboxListTile(
                                value: isChecked,
                                title: Text(name,
                                    style:
                                        const TextStyle(color: Colors.white)),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                activeColor: Colors.lightBlueAccent,
                                checkColor: Colors.black,
                                onChanged: (checked) {
                                  setLocalState(() {
                                    if (checked == true) {
                                      tempSelected.add(id);
                                    } else {
                                      tempSelected.remove(id);
                                    }
                                  });
                                },
                              );
                            }),
                          const Divider(height: 10, color: Colors.grey),
                        ],
                      );
                    }).toList(),
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
        ) ??
        [];
// Capture current exercises BEFORE any mutation
    final prevSelected = Set<String>.from(exercises);

// Determine which ones are new
    final newIds = selected.where((id) => !prevSelected.contains(id)).toList();

// Now apply changes
    if (selected.isNotEmpty) {
      setState(() {
        exerciseSettings.removeWhere((id, _) => !selected.contains(id));
        _exerciseIdToName.removeWhere((id, _) => !selected.contains(id));

        exercises = selected;

        for (final id in newIds) {
          final match = exercisesFromFirestore.firstWhere(
                (ex) => ex['id'] == id,
            orElse: () => {}, // ✅ Works with match.isNotEmpty
          );

          if (match.isNotEmpty) {
            final name = match['name']!;
            final category = match['category'] ?? 'Other';
            final bodyPart = match['bodyPart'] ?? '';

            _exerciseIdToName[id] = name;

            // 🧠 Get default settings
            final defaults = getDefaultSettings(name, category, bodyPart);

            // 🛡️ Sanitize repTargets if needed
            final repTargets = defaults['repTargets'];
            if (repTargets is! Map<String, Map<String, String>>) {
              defaults['repTargets'] = _convertToMap(repTargets);
              print("🔧 Normalized repTargets for $name");
            }

            // 🛡️ Optional: ensure rirPlan is Map (avoids crash if broken upstream)
            final rirPlan = defaults['rirPlan'];
            if (rirPlan is! Map<String, dynamic>) {
              defaults['rirPlan'] = {};
              print("⚠️ Fallback: Empty rirPlan injected for $name");
            }

            // 🧩 Keep a copy of explicit week1 rep defaults for reseeding previews after model flips
            final explicitSeed = defaults['repTargets']; // keep whatever structure you already built
            exerciseSettings[id] = {
              ...defaults,
              if (explicitSeed != null) 'explicitRepTargets': explicitSeed,
            };

          }
        }
      });

      // 💾 Persist seeds so re-open uses explicit defaults (not PMU fallbacks)
      for (final id in newIds) {

        final settings = exerciseSettings[id];
        if (settings != null) {
          _onUpdateSetting(id, 'repTargets', settings['repTargets']);
          _onUpdateSetting(id, 'defaultSets', settings['defaultSets'] ?? 3);
         // _onUpdateSetting(id, 'explicitRepTargets', settings['repTargets']);
          _onUpdateSetting(id, 'modelSpecificRepTargets', settings['modelSpecificRepTargets']);

        }
      }

      // Also persist the list/details (silent)
      Future.microtask(() => _savePlannedExercises(suppressSnack: true));
    }


  }

  Future<void> _savePlannedExercises({bool suppressSnack = false}) async {

    final userId = UserContext.of(context, listen: false).currentUid;
    if (userId == null || blockIdToUse == null) return;


    // 🔄 Now writing into the *same* collection as savePlannedBlock
    final docRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(blockIdToUse);

    print("📤 Saving exerciseSettings for ${exercises.length} exercises");

    for (final id in exercises) {
      final settings = exerciseSettings[id];
      print("💾 $id → ${jsonEncode(settings)}");
    }

    print("📤 Writing full block to Firestore...");

    // 🧼 Robustness: enforce unique exercise IDs (preserve order)
    final uniqueExercises = <String>[];
    for (final id in exercises) {
      if (!uniqueExercises.contains(id)) uniqueExercises.add(id);
    }
    if (uniqueExercises.length != exercises.length) {
      print('🧼 [BP.save] deduped exercises: ${exercises.length} -> ${uniqueExercises.length}');
      exercises
        ..clear()
        ..addAll(uniqueExercises);
    }

    // Read-modify your exerciseDetails as before
    final snapshot = await docRef.get();
    final data = snapshot.data() ?? {};

    final existingDetails = Map<String, dynamic>.from(
      data['plannedExerciseDetails'] ?? {},
    );
    // 🔁 Also track existing exerciseSettings so we mirror all changes there too
    final existingSettings = Map<String, dynamic>.from(
      data['exerciseSettings'] ?? {},
    );


    for (final exercise in exercises) {
      final entry = Map<String, dynamic>.from(exerciseSettings[exercise] ?? {});
      print("🧾 [SAVE] pre-normalize increments for $exercise → "
          "${jsonEncode(entry['increments'])}");

      final repTargets = entry['repTargets'];

      // ✅ Normalize legacy List<String> format
      if (repTargets is List &&
          repTargets.isNotEmpty &&
          repTargets.first is String) {
        final flat = repTargets
            .expand((e) => e.toString().split(','))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();

        final weeklyFreq =
            int.tryParse(entry['weeklyFrequency'].toString()) ?? 3;
        final numWeeks = (flat.length / weeklyFreq).ceil();

        final nested = List.generate(numWeeks, (i) {
          final start = i * weeklyFreq;
          final end = (start + weeklyFreq).clamp(0, flat.length);
          return flat.sublist(start, end);
        });

        entry['repTargets'] = nested;
        print("🛠️ Normalized legacy repTargets for $exercise: $nested");
      }

      // ✅ Normalize Firestore dynamic maps into Map<String, Map<String, String>>
      Map<String, Map<String, String>> _normalizeRepTargetsMap(dynamic value) {
        if (value is Map) {
          final out = <String, Map<String, String>>{};
          value.forEach((k, v) {
            final key = k.toString();
            if (v is Map) {
              out[key] = v.map((k2, v2) => MapEntry(k2.toString(), v2.toString()));
            } else {
              out[key] = <String, String>{};
            }
          });
          return out;
        }
        return <String, Map<String, String>>{};
      }

// 🔎 Optional debug (leave it in while testing)
      print("🔎 [$exercise] repTargets runtimeType = ${repTargets.runtimeType} | value=${jsonEncode(repTargets)}");

// ✅ IMPORTANT: stop using the strict generic type check (it fails for Map<String, dynamic>)
      final Map<String, Map<String, String>> savedTargets =
      (repTargets is Map) ? _normalizeRepTargetsMap(repTargets) : _convertToMap(repTargets);

      entry['repTargets'] = savedTargets;
      print("🧪 Saving repTargets for $exercise: ${jsonEncode(savedTargets)}");

      print("🧪 Saving repTargets for $exercise: ${jsonEncode(savedTargets)}");
// ⬇️ Add this line here
      print('🔎 [BP] increments (raw) for $exercise → ${jsonEncode(entry['increments'])}');

      // ✅ Special handling for Daily Undulating Periodization
      final model = entry['periodizationModel'];
      if (model == 'DUP, By Exposure' &&
          repTargets is List &&
          repTargets.isNotEmpty &&
          repTargets.first is String) {
        final reps = List<String>.from(repTargets);
        final dupMap = <String, Map<String, String>>{
          'week1': {
            for (int i = 0; i < reps.length; i++) 'instance${i + 1}': reps[i]
          }
        };
        entry['repTargets'] = dupMap;
        print(
            '🔁 Converted DUP repTargets for $exercise: ${jsonEncode(dupMap)}');
      }

      if (entry['periodizationModel'] == 'DUP, Signature') {

        existingDetails[exercise] = {
          'periodizationModel': 'DUP, Signature',
          'repTargets': entry['repTargets'], // ← include the correct full structure
          'rirPlan': entry['rirPlan'], // ✅ Add this
          'rirModel': entry['rirModel'], // ✅ add this line
          'progressionModel': entry['progressionModel'] ?? 'Linear Weight Increase',
          'increments': entry['increments'] ?? {'primary': 2.5},
          'weeklyFrequency': entry['weeklyFrequency'] ?? 3,
          'maxWeightXReps': entry['maxWeightXReps'] ?? '',
          'notes': entry['notes'] ?? '',
        };
      }
      else {
        existingDetails[exercise] = {
          'periodizationModel': entry['periodizationModel'],
          'repTargets': savedTargets,
          'rirPlan': entry['rirPlan'], // ✅ Add this
          'rirModel': entry['rirModel'], // ✅ add this line
          'progressionModel': entry['progressionModel'] ?? 'Linear Weight Increase',
          'increments': entry['increments'] ?? {'primary': 2.5},
          'weeklyFrequency': entry['weeklyFrequency'] ?? 3,
          'maxWeightXReps': entry['maxWeightXReps'] ?? '',
          'notes': entry['notes'] ?? '',
        };
      }
      print('💾 [BP] saving increments for $exercise → '
          '${jsonEncode(existingDetails[exercise]['increments'])}');

      // 🔁 Mirror the same per-exercise payload into exerciseSettings,
      // but keep any extra keys that already existed there (e.g. defaultSets).
      final Map<String, dynamic> existingSettingsEntry =
      Map<String, dynamic>.from(existingSettings[exercise] ?? {});
      existingSettingsEntry.addAll(
          existingDetails[exercise] as Map<String, dynamic>);
      existingSettings[exercise] = existingSettingsEntry;

      print('💾 [BP] mirrored into exerciseSettings for $exercise → '
          '${jsonEncode(existingSettings[exercise])}');
    }


    if (_blockStartDate != null && _blockEndDate != null) {
      existingDetails['blockMeta'] = {
        'blockStartDate': _blockStartDate!.toIso8601String(),
        'blockEndDate': _blockEndDate!.toIso8601String(),
      };
      print("📅 Saved blockMeta to plannedExerciseDetails");
    }

    // 🧹 Remove details for exercises that were deleted (keep blockMeta)
    existingDetails.removeWhere((k, v) => k != 'blockMeta' && !exercises.contains(k));


    print("📤 Saving plannedExerciseDetails:\n${jsonEncode(existingDetails)}");
    print("📤 Saving exerciseSettings:\n${jsonEncode(existingSettings)}");

    await docRef.set({
      'exercises': exercises,
      'plannedExercises': exercises,
      'plannedExerciseDetails': existingDetails,
      'exerciseSettings':       existingSettings,
    }, SetOptions(merge: true));


    // 🧹 Schema hygiene: remove explicitRepTargets from Firestore (kept only in local state)
    final cleanup = <String, dynamic>{};
    for (final ex in exercises) {
      cleanup['exerciseSettings.$ex.explicitRepTargets'] = FieldValue.delete();
    }
    await docRef.update(cleanup).catchError((_) {
      // ignore if nothing to delete
    });


    print("✅ Planned exercises and details saved safely.");

// ✅ Also update the pointer at 'current_block'

    if (userId != null && blockIdToUse != null) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('block_planner')
          .doc('current_block')
          .set({
        'blockId': blockIdToUse,
        'blockName': _blockNameController.text.trim(),
        'blockMeta': {
          'blockStartDate': _blockStartDate?.toIso8601String() ?? '',
          'blockEndDate': _blockEndDate?.toIso8601String() ?? '',
        },
      }, SetOptions(merge: true));

      print('📌 Updated current_block → ID: $blockIdToUse');
    }


    // 🧱 Ensure week docs exist for BB2 compatibility
    if (_blockStartDate != null && _blockEndDate != null) {
      final int totalWeeks = _blockEndDate!
          .difference(_blockStartDate!)
          .inDays ~/ 7 + 1;

      final weeksCollection = FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(userId) // ✅ selected athlete
          .collection('blocks')
          .doc(blockIdToUse!)
          .collection('weeks');


      for (int i = 0; i < totalWeeks; i++) {
        final weekDocRef = weeksCollection.doc('week_$i');

        await weekDocRef.set({
          'exists': true,
        }, SetOptions(merge: true));
        print("📤 Creating weeks under blockId: $blockIdToUse");


        print("📅 Created week_$i doc");
      }
    }



    if (!suppressSnack && mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        const SnackBar(content: Text('✅ Planned exercises updated.')),
      );
    }


    print("📦 Final saved frequencies:");
    for (final ex in exercises) {
      print("• $ex: ${exerciseSettings[ex]?['weeklyFrequency']}");
    }
  }

  Map<String, Map<String, String>> _convertToMap(dynamic data) {
    if (data is List && data.isNotEmpty) {
      if (data.first is List) {
        // ✅ Convert List<List<String>> to Map<String, Map<String, String>>
        return {
          for (int week = 0; week < data.length; week++)
            'week${week + 1}': {
              for (int i = 0; i < data[week].length; i++)
                'instance${i + 1}': data[week][i]
            }
        };
      } else if (data.first is String) {
        // ✅ Flat list → assign to week1 with instance keys
        return {
          'week1': {
            for (int i = 0; i < data.length; i++) 'instance${i + 1}': data[i]
          }
        };
      }
    }
    // ❌ Invalid or empty structure
    return {};
  }

  Future<void> _loadPlannedExercises() async {
    final userId = UserContext.of(context, listen: false).currentUid;
    if (userId == null || blockIdToUse == null) return;

    // If there are unsaved local edits, do NOT clobber them with remote
    if (_hasLocalEdits) {
      debugPrint('🛑 [BP.load] Skipping remote load (has local edits)');
      return;
    }

    final docRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(blockIdToUse); // ✅ read the actual block being edited

    final snapshot = await docRef.get();

    // INSERT UNDER THIS LINE
    debugPrint('🧪 [BP.load] block=$blockIdToUse exists=${snapshot.exists}');
    if (snapshot.exists) {
      final dd = snapshot.data();
      debugPrint('🧪 [BP.load] keys=${dd?.keys.toList()}');
      debugPrint('🧪 [BP.load] plannedExercises.len=${(dd?['plannedExercises'] as List?)?.length ?? -1}');
    }

    if (!snapshot.exists) return;

    final data = snapshot.data();
    if (data == null) return;

    // ✅ Restore planned exercise IDs (only if no local edits)
    if (data.containsKey('plannedExercises') && !_hasLocalEdits) {
      final remote = List<String>.from(data['plannedExercises'] ?? const <String>[]);

      setState(() {
        exercises = remote;
      });
      debugPrint('📋 [BP.load] Applied plannedExercises from block ($blockIdToUse): ${exercises.length}');
    }

    // ✅ Restore detailed settings, skipping blockMeta and guarding local edits
    if (data.containsKey('plannedExerciseDetails') && !_hasLocalEdits) {
      final raw = Map<String, dynamic>.from(data['plannedExerciseDetails'] ?? const {});
      final Map<String, Map<String, dynamic>> converted = {};

      raw.forEach((exerciseId, value) {
        if (exerciseId == 'blockMeta') return; // 🚫 skip metadata
        if (value is Map) {
          converted[exerciseId] = Map<String, dynamic>.from(value);
        }
      });

      setState(() {
        exerciseSettings = converted;
      });

      final rir = exerciseSettings.entries.firstWhere(
            (e) => e.value.containsKey('rirPlan'),
        orElse: () => const MapEntry('none', {}),
      );
    }
  }


  @override
  Widget build(BuildContext context) {
    final isKeyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
    child: Scaffold(
      backgroundColor: Colors.blueGrey.shade900,
      appBar: AppBar(
        title: const Text("Block Planner"),
        backgroundColor: Colors.blueGrey.shade800,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Save Block',
            onPressed: () async {
              final name = _blockNameController.text.trim();

              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Please enter a block name.")),
                );
                return;
              }

              if (_blockStartDate == null || _blockEndDate == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Please select block dates.")),
                );
                return;
              }

              if (exercises.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Add at least one exercise.")),
                );
                return;
              }

              // Use StatefulBuilder to capture checkbox value
              bool tempActive = _initialBlockIsActive;

              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) {
                  return StatefulBuilder(builder: (context, setState) {
                    return AlertDialog(
                      title: const Text("Save Block?"),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text("Do you want to save this block to your plans?"),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("Set as Active?"),
                              Switch(
                                value: tempActive,
                                onChanged: (v) => setState(() => tempActive = v),
                              ),
                            ],
                          ),
                        ],
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text("Cancel")),
                        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Save")),
                      ],
                    );
                  });
                },
              );

              if (confirm == true) {
                await _savePlannedExercises(suppressSnack: true); // ✅ Save exercise-level data
                await _savePlannedBlock(setActive: tempActive); // ✅ Save block-level metadata
              }


            },
          ),
        ],
      ),

      // 🔽 Floating button shows conditionally
      floatingActionButton: _isSavedBlock && !isKeyboardOpen
          ? FloatingActionButton.extended(
        onPressed: () {
          if (blockIdToUse == null) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => Camp_BB2(blockId: blockIdToUse!),
            ),
          );
        },
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.arrow_forward, size: 18),
            SizedBox(width: 4),
            Text(
              "Week Planner",
              style: TextStyle(fontSize: 14), // 👈 smaller font
            ),
          ],
        ),
      )
          : null,


      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildGlobalBlockInputs(),
            const FittedBox(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text(
                    "Add Exercises",
                    style: TextStyle(color: Colors.white),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onPressed: _showExercisePickerDialog,
                ),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.clear),
                    label: const Text("Clear Exercises"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueGrey.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text("Clear All Exercises?"),
                          content: const Text(
                            "This will remove all selected exercises from the planner.",
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text("Cancel"),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text("Yes, Clear"),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        setState(() {
                          exercises.clear();
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Builder(
              builder: (context) {
                final seen = <String>{};
                for (final id in exercises) {
                  if (!seen.add(id)) {
                    print('❌ DUPLICATE exerciseId in exercises list: $id');
                  }
                }
                print('✅ exercises unique count=${seen.length} total=${exercises.length}');

                int cmp(String a, String b) =>
                    (_exerciseIdToName[a] ?? '').toLowerCase()
                        .compareTo((_exerciseIdToName[b] ?? '').toLowerCase());
                final inTemplates = exercises
                    .where((id) => _templateExerciseIds.contains(id))
                    .toList()
                  ..sort(cmp);
                final notInTemplates = exercises
                    .where((id) => !_templateExerciseIds.contains(id))
                    .toList()
                  ..sort(cmp);
                final showDivider =
                    inTemplates.isNotEmpty && notInTemplates.isNotEmpty;
                final items = <String?>[
                  ...inTemplates,
                  if (showDivider) null,
                  ...notInTemplates,
                ];

                return SizedBox(
                  height: math.max(exercises.length * 380, 550).toDouble(),
                  // 👈 Tweak if your cards are taller/shorter
                  child: ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final exercise = items[index];

                      if (exercise == null) {
                        return const Divider(
                          height: 4,
                          thickness: 1,
                          color: Colors.white,
                        );
                      }

                      final u = exercises.toSet().length;
                      if (u != exercises.length) {
                        print('❌ [BP.UI] DUP PRESENT: len=${exercises.length} unique=$u exercises=$exercises');
                        print(StackTrace.current);
                      }

                      final settingsExist = exerciseSettings.containsKey(exercise);
                      final datesLoaded = _blockStartDate != null && _blockEndDate != null;

                      return Dismissible(
                        key: ValueKey('bp_${blockIdToUse}_$exercise'),

                        direction: DismissDirection.endToStart,
                        onDismissed: (_) {
                          final removedExercise = exercise;

                          setState(() {
                            exercises.remove(removedExercise);
                            // 🧼 Also drop its settings locally so save won't re-add details
                            exerciseSettings.remove(removedExercise);
                          });

                          // 💾 Fire-and-forget save so deletion persists immediately
                          Future.microtask(() => _savePlannedExercises(suppressSnack: true));

                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) return;
                            try {
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Removed "${_exerciseIdToName[removedExercise] ?? 'Unknown Exercise'}"',
                                  ),
                                  action: SnackBarAction(
                                    label: 'Undo',
                                    textColor: Colors.amberAccent,
                                    onPressed: () {
                                      if (!mounted) return;
                                      setState(() {
                                        if (!exercises.contains(removedExercise)) {
                                          exercises.add(removedExercise);
                                        }
                                      });
                                      Future.microtask(() => _savePlannedExercises(suppressSnack: true));
                                    },
                                  ),
                                  duration: const Duration(seconds: 4),
                                  backgroundColor: Colors.blueGrey.shade700,
                                  behavior: SnackBarBehavior.floating,
                                  margin: const EdgeInsets.all(16),
                                ),
                              );
                            } catch (_) {
                              // ignore — context likely deactivated during dismiss animation
                            }
                          });
                        },
                        background: Container(
                          color: Colors.red,
                          padding: const EdgeInsets.only(left: 16),
                          alignment: Alignment.centerLeft,
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),

                        // ✅ Only render _ExerciseCard once both block dates AND settings exist
                        child: (!datesLoaded || !settingsExist)
                            ? const SizedBox.shrink()
                            : _ExerciseCard(
                          exerciseId: exercise,
                          exerciseName: _exerciseIdToName[exercise] ?? 'Unknown Exercise',
                          exerciseSettings: exerciseSettings,
                          blockStartDate: _blockStartDate,
                          blockEndDate: _blockEndDate,
                          onUpdateSetting: _onUpdateSetting, // ✅ Calls the real one that updates Firestore
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),

    ));
  }

  Widget _buildGlobalBlockInputs() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: TextField(
            controller: _blockNameController,
            decoration: InputDecoration(
              labelText: 'Block Name',
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () async {
                  final now = DateTime.now();
                  final DateTimeRange? picked = await showDateRangePicker(
                    context: context,
                    firstDate: now.subtract(const Duration(days: 365)),
                    lastDate: now.add(const Duration(days: 365 * 2)),
                    initialDateRange: (_blockStartDate != null && _blockEndDate != null)
                        ? DateTimeRange(start: _blockStartDate!, end: _blockEndDate!)
                        : null,
                    builder: (context, child) {
                      return Localizations.override(
                        context: context,
                        locale: const Locale('en', 'GB'),  // Monday-first weeks
                        child: child!,
                      );
                    },
                  );

                  if (picked != null) {
                    setState(() {
                      _blockStartDate = picked.start;
                      _blockEndDate = picked.end;

                      final weeks = PeriodizationModelUtils.getBlockLength(
                        blockStartDate: _blockStartDate,
                        blockEndDate: _blockEndDate,
                      );

                      _blockGoalsController.text = '$weeks week block';
                    });

                    // ✅ Save to Firestore if needed
                    final user = FirebaseAuth.instance.currentUser;
                    if (user != null) {
                      await FirebaseFirestore.instance
                          .collection('users')
                          .doc(userId)
                          .collection('block_planner')
                          .doc('current_block')
                          .set({
                        'blockMeta': {
                          'blockStartDate': picked.start.toIso8601String(),
                          'blockEndDate': picked.end.toIso8601String(),
                        },
                        'blockId': blockIdToUse, // ✅ Inject block ID here
                        'blockName': _blockNameController.text.trim(), // ✅ Optional name if supported
                      }, SetOptions(merge: true));

                    }
                  }
                },
                child: Container(
                  height: 56,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.blueGrey.shade800,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white30),
                  ),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _blockStartDate != null && _blockEndDate != null
                        ? 'Block: ${DateFormat('d MMM').format(_blockStartDate!)} – ${DateFormat('d MMM y').format(_blockEndDate!)}'
                        : 'Select Block Dates',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _buildTrainingDaySelector(),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _buildInputBox(
              _blockStartDate != null && _blockEndDate != null
                  ? '${(((_blockEndDate!.difference(_blockStartDate!).inDays + 6) ~/ 7))} Weeks'
                  : 'Block goals',
              multiline: true,
            ),
//            const SizedBox(width: 8),
//             _buildInputBox("Planned calories surplus/deficit", multiline: true),
          ],
        ),
      ],
    );
  }

  Widget _buildTrainingDaySelector() {
    final days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final initials = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text(
            "Select Training Days",
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(7, (index) {
            final day = days[index];
            final isSelected = selectedDays.contains(day);

            return GestureDetector(
              onTap: () {
                setState(() {
                  if (isSelected) {
                    selectedDays.remove(day);
                  } else {
                    selectedDays.add(day);
                  }

                  // ✅ Auto-update weeklyFrequency in each exercise
                  final newFreq = selectedDays.length;
                  for (final ex in exercises) {
                    exerciseSettings[ex] ??= {};
                    exerciseSettings[ex]!['weeklyFrequency'] = newFreq;
                  }
                });
              },
              child: CircleAvatar(
                radius: 16,
                backgroundColor:
                    isSelected ? Colors.pinkAccent : Colors.blueGrey.shade700,
                child: Text(
                  initials[index],
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white70,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            );
          }),
        ),
        if (selectedDays.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              "Selected: ${selectedDays.join(', ')}",
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _buildInputBox(
    String label, {
    bool multiline = false,
    String? initialText,
    bool readOnly = false,
  }) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: TextEditingController(text: initialText ?? ''),
          readOnly: readOnly,
          maxLines: multiline ? 3 : 1,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: const TextStyle(color: Colors.white70, fontSize: 12),
            filled: true,
            fillColor: Colors.blueGrey.shade800,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          ),
        ),
      ),
    );
  }
}

class _ExerciseCard extends StatefulWidget {
  final String exerciseName;
  final String exerciseId;
  final Map<String, Map<String, dynamic>> exerciseSettings;
  final void Function(String exerciseName, String key, dynamic value)
      onUpdateSetting;
  final DateTime? blockStartDate;
  final DateTime? blockEndDate;
  final Map<String, dynamic>? plannedExerciseDetails;


  const _ExerciseCard({
    required this.exerciseId,
    required this.exerciseName,
    required this.exerciseSettings,
    required this.onUpdateSetting,
    this.plannedExerciseDetails, // 🔁 not required
    this.blockStartDate,
    this.blockEndDate,

  });

  @override
  State<_ExerciseCard> createState() => _ExerciseCardState();
}

class _ExerciseCardState extends State<_ExerciseCard> {
  bool isExpanded = false;
  final FocusNode _incrementsFocusNode = FocusNode();
  final FocusNode _rirFocusNode = FocusNode();
  final FocusNode _weeklyFrequencyFocusNode = FocusNode();
  final TextEditingController _weeklyFrequencyController = TextEditingController(text: "7");
  final TextEditingController _repTargetsDisplayController = TextEditingController();
  final TextEditingController _rirDisplayController = TextEditingController();
  final List<int> dailyUndulatingWeekDefaultReps = [10, 5, 12, 8, 3, 7, 1];
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _incrementsController = TextEditingController();
  final TextEditingController _maxWeightController = TextEditingController();
  final TextEditingController _maxRepsController = TextEditingController();
  Map<String, Map<String, String>>? _cachedRepTargetMap;
  Map<String, String> _selectedRirModel = {}; // Keeps track of selection per exercise
  Map<String, String> _selectedProgressionModel = {};

  Map<String, Map<String, Map<String, Map<String, String>>>>? _cachedRirPlan;
  String get userId => UserContext.of(context, listen: false).currentUid;
  String? _parentBlockId;
  String? _cachedUid;

  double _currentE1RM = 0.0;

  String _selectedModel = 'DUP, Signature'; // default or load from Firestore
  PeriodizationModelType? _lastOpenedModel;

  final List<String> supportedModels = [
    'Linear Weight Increase',
    'Add Reps',
    'Smart Progression',
  ];


// 🔧 Prune any RIR sessions beyond the current frequency
  void _pruneRirPlanToFrequency(int freq) {
    if (_cachedRirPlan == null || _cachedRirPlan!.isEmpty) return;

    _cachedRirPlan!.forEach((weekKey, weekMap) {
      // Collect first, then remove to avoid concurrent modification
      final toRemove = <String>[];
      weekMap.forEach((sessionKey, _) {
        final m = RegExp(r'^session(\d+)$').firstMatch(sessionKey);
        if (m != null) {
          final s = int.tryParse(m.group(1) ?? '');
          if (s != null && s > freq) toRemove.add(sessionKey);
        }
      });
      for (final k in toRemove) {
        weekMap.remove(k);
      }
    });
  }

// 🔧 Refresh the compact W1 summary in the read-only RIR field
  void _updateRirSummaryDisplay({int? freqOverride}) {
    final weekData = _cachedRirPlan?['week1'] as Map<String, dynamic>?;
    if (weekData == null) {
      _rirDisplayController.text = '';
      return;
    }
    // Prefer live frequency from repTargets (instances), else text field, else 3
    int freq = freqOverride ??
        (() {
          final instCount = (widget.exerciseSettings[widget.exerciseId]?['repTargets']?['week1'] as Map?)?.keys
              .where((k) => k.toString().startsWith('instance'))
              .length ??
              0;
          if (instCount > 0) return instCount;
          return int.tryParse(_weeklyFrequencyController.text.trim()) ?? 3;
        })();

    final summary = <String>[];
    for (int i = 1; i <= freq; i++) {
      final session = weekData['session$i'] as Map<String, dynamic>?;
      final set1 = session?['set1'] as Map<String, dynamic>?;
      final rir = set1?['rir'];
      if (rir != null) summary.add(rir.toString());
    }
    _rirDisplayController.text =
    summary.isEmpty ? '' : 'W1 → ${summary.join(' | ')}';
  }


  PeriodizationModelType _mapLabelToModelType(String label) {
    switch (label) {
      case 'DUP, By Exposure':
        return PeriodizationModelType.dailyUndulatingExposure;
      case 'DUP, Signature':
        return PeriodizationModelType.dupSignature;
      case 'DUP, By Week':
        return PeriodizationModelType.dailyUndulatingWeek;
      case 'Linear, Classic':
        return PeriodizationModelType.linearClassic;
      case 'Linear, by Exposure':
        return PeriodizationModelType.linearExposure;
      default:
        return PeriodizationModelType.dupSignature;
    }
  }


  @override
  void initState() {
    super.initState();
    _syncCachedRirPlan(widget.exerciseName);
    _incrementsFocusNode.addListener(() {
      if (!_incrementsFocusNode.hasFocus) {
        final cleaned = _incrementsController.text
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .map((e) => double.tryParse(e))
            .whereType<double>()
            .where((v) => v > 0)
            .map((v) => v.toString())
            .join(', ');

        _incrementsController.text = cleaned;
      }
    });

    _rirFocusNode.addListener(() {
      if (!_rirFocusNode.hasFocus) {
        _flushRirToFirestore(reason: 'focus_lost');
      }
    });


    final settings = widget.exerciseSettings[widget.exerciseId];


    if (settings != null) {
      final reps = settings['repTargets'];

      // ✅ Skip DUP Signature (which uses {min, max})
      final isSignature = reps is Map<String, dynamic> &&
          reps.containsKey('min') &&
          reps.containsKey('max');

      if (!isSignature) {
        _syncCachedRepTargets(
            widget.exerciseId); // 🧠 Apply for all other models
      }

      final frequency = settings['weeklyFrequency'];
      if (frequency != null) {
        _weeklyFrequencyController.text = frequency.toString();
      }

      final model = settings['periodizationModel'];
      print('📋 Found model in settings: $model');
      if (model != null &&
          [
            'DUP, By Exposure',
            'DUP, Signature',
            'DUP, By Week',
            'Linear, Classic',
            'Linear, by Exposure',
          ].contains(model)) {
        _selectedModel = model;
        print('✅ Applied model to _selectedModel: $_selectedModel');
      }


      final notes = settings['notes'];
      if (notes != null) {
        _notesController.text = notes.toString();
      }

      final increments = settings['increments'];
      if (increments is Map) {
        final values = ['primary', 'secondary', 'tertiary', 'quaternary']
            .map((key) => increments[key])
            .whereType<num>()
            .where((v) => v > 0)
            .map((v) => v.toString())
            .toList();
        _incrementsController.text = values.join(', ');
      }

      final maxCombo = settings['maxWeightXReps'];
      if (maxCombo is String && maxCombo.contains('x')) {
        final parts = maxCombo.split('x');
        if (parts.length == 2) {
          _maxWeightController.text = parts[0].trim();
          _maxRepsController.text = parts[1].trim();
        }
      }
    }

    // ✅ Commit frequency on UNFOCUS (avoid partial keystroke states)
    _weeklyFrequencyFocusNode.addListener(() {
      if (_weeklyFrequencyFocusNode.hasFocus) return; // only run on UNFOCUS

      final parsed = int.tryParse(_weeklyFrequencyController.text.trim());
      if (parsed == null) return;

      final int freq = parsed.clamp(1, 14);

      // ✅ Save weeklyFrequency
      widget.onUpdateSetting(widget.exerciseId, 'weeklyFrequency', freq);

      // 🧹 Prune RIR sessions beyond the new frequency
      _pruneRirPlanToFrequency(freq);

      if (mounted) {
        setState(() {
          widget.onUpdateSetting(widget.exerciseId, 'rirPlan', _cachedRirPlan);
          _updateRirSummaryDisplay(freqOverride: freq);
        });
      }

      // ✅ ALSO prune repTargets instances to match weeklyFrequency
      final raw = widget.exerciseSettings[widget.exerciseId]?['repTargets'];
      if (raw is Map) {
        final pruned = <String, dynamic>{};

        for (final entry in raw.entries) {
          final key = entry.key.toString();
          final val = entry.value;

          // Keep non-week keys (e.g. repRange for DUP Signature)
          if (!key.startsWith('week') || val is! Map) {
            pruned[key] = val;
            continue;
          }

          final weekMap = Map<String, dynamic>.from(val as Map);
          final kept = <String, String>{};

          for (int i = 1; i <= freq; i++) {
            final k = 'instance$i';
            if (weekMap.containsKey(k) && weekMap[k] != null) {
              kept[k] = weekMap[k].toString();
            }
          }

          pruned[key] = kept;
        }

        widget.onUpdateSetting(widget.exerciseId, 'repTargets', pruned);
        print("🧼 [FREQ UNFOCUS] Pruned repTargets to freq=$freq for ${widget.exerciseName} → ${jsonEncode(pruned)}");
      }
    });




    final rirModel = settings != null ? settings['rirModel'] : null;
    if (rirModel != null && rirModel is String && rirModel.isNotEmpty) {
      setState(() {
        _selectedRirModel[widget.exerciseId] = rirModel;

        print("📥 [INIT] Loaded RIR model for ${widget.exerciseName}: $rirModel");
      });
    }




    final rirPlan = settings?['rirPlan'];
    if (rirPlan != null && rirPlan is Map<String, dynamic>) {
      _cachedRirPlan = rirPlan.map((weekKey, weekVal) {
        return MapEntry(
          weekKey,
          (weekVal as Map<String, dynamic>).map((sessionKey, sessionVal) {
            return MapEntry(
              sessionKey,
              (sessionVal as Map<String, dynamic>).map((setKey, setVal) {
                return MapEntry(
                  setKey,
                  Map<String, String>.from(setVal as Map),
                );
              }),
            );
          }),
        );
      });

      print("📥 [INIT] Loaded and casted RIR plan for ${widget.exerciseName}: $_cachedRirPlan");
    }

    _updateRirSummaryDisplay();


    final supportedModels = [
      'Linear Weight Increase',
      'Add Reps',
      'Smart Progression',
    ];

    final savedProgressionModel = widget.exerciseSettings[widget.exerciseId]?['progressionModel'];

    if (savedProgressionModel is String && savedProgressionModel.isNotEmpty) {
      final normalized = savedProgressionModel.trim() == 'linear'
          ? 'Linear Weight Increase'
          : savedProgressionModel.trim();

      if (supportedModels.contains(normalized)) {
        _selectedProgressionModel[widget.exerciseId] = normalized;
      } else {
        final fallback = supportedModels.first;
        _selectedProgressionModel[widget.exerciseId] = fallback;

        // 🧼 One-time cleanup of bad saved value
        WidgetsBinding.instance.addPostFrameCallback((_) {
          widget.onUpdateSetting(widget.exerciseId, 'progressionModel', fallback);
          print("🧼 Cleaned up invalid progressionModel: '$savedProgressionModel' → '$fallback'");
        });
      }
    }




    _maxWeightController.addListener(_updateE1RM);
    _maxRepsController.  addListener(_updateE1RM);

    _maxWeightController.addListener(_syncBestWeightXReps);
    _maxRepsController  .addListener(_syncBestWeightXReps);

  }

  void _flushRirToFirestore({required String reason}) {
    // Must be mounted to read context safely
    if (!mounted) return;

    final uid = UserContext.of(context, listen: false).currentUid;
    final bid = context.findAncestorStateOfType<_BlockPlannerState>()?.blockIdToUse;

    if (uid.isEmpty || bid == null || bid.isEmpty) {
      print("⚠️ [RIR.flush] skip (uid=$uid blockId=$bid) reason=$reason");
      return;
    }

    // Ensure latest local state is saved first
    if (_cachedRirPlan != null) {
      safeSave('rirPlan', _cachedRirPlan);
    }

    // Also persist rirModel if present (use id first)
    final rirModel =
        _selectedRirModel[widget.exerciseId] ?? _selectedRirModel[widget.exerciseName];
    if (rirModel != null && rirModel.isNotEmpty) {
      safeSave('rirModel', rirModel);
    }

    final entry = Map<String, dynamic>.from(
      widget.exerciseSettings[widget.exerciseId] ?? {},
    );

    final payload = <String, dynamic>{
      'exerciseSettings.${widget.exerciseId}.rirPlan': entry['rirPlan'],
      'plannedExerciseDetails.${widget.exerciseId}.rirPlan': entry['rirPlan'],
      'exerciseSettings.${widget.exerciseId}.rirModel': entry['rirModel'],
      'plannedExerciseDetails.${widget.exerciseId}.rirModel': entry['rirModel'],
    };

    FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(bid)
        .set(payload, SetOptions(merge: true))
        .then((_) => print("✅ [RIR.flush] wrote on $reason for ${widget.exerciseName}"))
        .catchError((e) => print("❌ [RIR.flush] failed: $e"));
  }


  void _syncBestWeightXReps() {
    final kg   = _maxWeightController.text.trim();
    final reps = _maxRepsController .text.trim();
    if (kg.isNotEmpty && reps.isNotEmpty) {
      // fire your generic onUpdateSetting callback with the combined string
      widget.onUpdateSetting(
        widget.exerciseId,
        'maxWeightXReps',
        '$kg x $reps',
      );
    }
  }

  void safeSave(String key, dynamic value) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onUpdateSetting(widget.exerciseId, key, value);
      }
    });
  }


  @override
  void dispose() {
    print("🧹 [DISPOSE] Called for ${widget.exerciseName}");
    _maxWeightController.removeListener(_updateE1RM);
    _maxRepsController.removeListener(_updateE1RM);
    _maxWeightController.removeListener(_syncBestWeightXReps);
    _maxRepsController .removeListener(_syncBestWeightXReps);

    final parsed = int.tryParse(_weeklyFrequencyController.text.trim());
    if (parsed != null) {
      final int freq = parsed; // ✅ non-null from here down
      safeSave('weeklyFrequency', freq);
      print("💾 [DISPOSE] Saved weeklyFrequency for ${widget.exerciseName}: $freq");

      // ✅ Keep repTargets instance count aligned with weeklyFrequency
      final raw = widget.exerciseSettings[widget.exerciseId]?['repTargets'];

      if (raw is Map) {
        final pruned = <String, dynamic>{};

        for (final entry in raw.entries) {
          final key = entry.key.toString();
          final val = entry.value;

          // Keep non-week keys (e.g. repRange for DUP Signature)
          if (!key.startsWith('week') || val is! Map) {
            pruned[key] = val;
            continue;
          }

          // Prune week maps to instance1..instanceN
          final weekMap = Map<String, dynamic>.from(val as Map);

          final kept = <String, String>{};
          for (int i = 1; i <= freq; i++) {
            final k = 'instance$i';
            if (weekMap.containsKey(k) && weekMap[k] != null) {
              kept[k] = weekMap[k].toString();
            }
          }

          pruned[key] = kept;
        }

        safeSave('repTargets', pruned);

        // ✅ IMPORTANT: also push the pruned structure through the same path that writes to Firestore
        widget.onUpdateSetting(widget.exerciseId, 'repTargets', pruned);

        print(
          "🧼 [DISPOSE] Pruned repTargets to weeklyFrequency=$freq "
              "for ${widget.exerciseName} → ${jsonEncode(pruned)}",
        );
      } else {
        print(
          "🧼 [DISPOSE] repTargets not a Map for ${widget.exerciseName}; skip prune.",
        );
      }
    }




    final model = _selectedModel;
    if (model.isNotEmpty) {
      safeSave('periodizationModel', model);
      print("💾 [DISPOSE] Saved periodizationModel for ${widget.exerciseName}: $model");
    }


    // ✅ Save repTargets from display text as week → instance → value
    final repText = _repTargetsDisplayController.text.trim();
    if (repText.isNotEmpty) {
      final model = PeriodizationModelUtils
          .exercisePeriodizationModels[widget.exerciseId];

      final Map<String, Map<String, String>> result = {};

      if (model == PeriodizationModelType.linearClassic) {
        // 🟦 Linear By Week → Parse multiple weeks via ||
        final parts = repText.split('||');
        for (int i = 0; i < parts.length; i++) {
          final weekKey = 'week${i + 1}';
          final instanceMap = <String, String>{};

          final values = parts[i]
              .split('|')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();

          for (int j = 0; j < values.length; j++) {
            instanceMap['instance${j + 1}'] = values[j];
          }

          result[weekKey] = instanceMap;
        }
      } else if (model == 'DUP, Signature') {
        // 🟣 Parse "min – max reps" from display
        final parts = repText.split('–');
        final min = parts.isNotEmpty ? parts[0].trim() : '6';
        final max =
            parts.length > 1 ? parts[1].replaceAll('reps', '').trim() : '10';

        result['repRange'] = {
          'min': min,
          'max': max,
        };
        result['week1'] = {
          'instance1': repText,
        };

        // ✅ Save RIR plan from cache
        if (_cachedRirPlan != null) {
          safeSave('rirPlan', _cachedRirPlan);
          print("💾 [DISPOSE] Saved DUP Signature rirPlan → $_cachedRirPlan");
        } else {
          print("⚠️ [DISPOSE] No cached RIR plan found for DUP Signature");
        }


      } else {
        // ✅ All other models (DUP-week, exposure, etc.)
        final values = repText
            .split('|')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();

        final instanceMap = <String, String>{
          for (int i = 0; i < values.length; i++) 'instance${i + 1}': values[i]
        };

        result['week1'] = instanceMap;
      }

      safeSave('repTargets', result);
      print("💾 [DISPOSE] Saved repTargets for ${widget.exerciseName} using model $model → $result");


    }

    // ✅ Clean and normalize increments
    final cleaned = _incrementsController.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join(', ');
    _incrementsController.text = cleaned;

    // 🔎 ADD THIS: show the cleaned raw string
    print("🧼 [DISPOSE] increments input (cleaned) for ${widget.exerciseName}: '$cleaned'");

    final List<double> parsedIncrements = cleaned
        .split(',')
        .map((s) => double.tryParse(s.trim()))
        .whereType<double>()
        .where((v) => v > 0)
        .toList();

    print("🧮 [DISPOSE] parsedIncrements for ${widget.exerciseName}: $parsedIncrements");
    if (parsedIncrements.isNotEmpty) {
      final Map<String, double> incrementsMap = {};
      if (parsedIncrements.isNotEmpty) {
        incrementsMap['primary'] = parsedIncrements[0];
      }
      if (parsedIncrements.length > 1) {
        incrementsMap['secondary'] = parsedIncrements[1];
      }
      if (parsedIncrements.length > 2) {
        incrementsMap['tertiary'] = parsedIncrements[2];
      }
      if (parsedIncrements.length > 3) {
        incrementsMap['quaternary'] = parsedIncrements[3];
      }

      safeSave('increments', incrementsMap);
      print("💾 [DISPOSE] Saved increments for ${widget.exerciseName}: $incrementsMap");

      print("🧾 [DISPOSE] post-save increments in settings for ${widget.exerciseId} → "
          "${jsonEncode(widget.exerciseSettings[widget.exerciseId]?['increments'])}");


    }

    // 🔎 Prefer exerciseId → fallback to name
    final idVal   = _selectedProgressionModel[widget.exerciseId];
    final nameVal = _selectedProgressionModel[widget.exerciseName];

    print("🔎 [DISPOSE] progressionModel candidates for ${widget.exerciseName} (${widget.exerciseId}) → "
        "byId='$idVal' byName='$nameVal'");

    final String? pickedRaw = (idVal != null && idVal.isNotEmpty)
        ? idVal
        : (nameVal != null && nameVal.isNotEmpty ? nameVal : null);

    if (pickedRaw != null && pickedRaw.isNotEmpty) {
      // 🧼 Normalize legacy aliases (keep this minimal)
      final normalized = (pickedRaw.trim() == 'linear')
          ? 'Linear Weight Increase'
          : pickedRaw.trim();

      safeSave('progressionModel', normalized);
      print("💾 [DISPOSE] Saved progression model for ${widget.exerciseName} (${widget.exerciseId}): $normalized");
    } else {
      print("⚠️ [DISPOSE] No progressionModel found for ${widget.exerciseName} (${widget.exerciseId}); leaving existing value untouched.");
    }


    final notes = _notesController.text.trim();
    safeSave('notes', notes);
    print("💾 [DISPOSE] Saved notes for ${widget.exerciseName}: $notes");


    final kg = _maxWeightController.text.trim();
    final reps = _maxRepsController.text.trim();
    print("🧠 [DISPOSE] Entered max weight: $kg");
    print("🧠 [DISPOSE] Entered max reps: $reps");

    final kgDouble = double.tryParse(kg);
    final repsDouble = double.tryParse(reps);
    if (kgDouble != null && repsDouble != null) {
      final combined =
          '${kgDouble.toStringAsFixed(1)} x ${repsDouble.toStringAsFixed(0)}';
      safeSave('maxWeightXReps', combined);
      print("💾 [DISPOSE] Saved maxWeightXReps for ${widget.exerciseName}: $combined");
    } else {
      print("⚠️ [DISPOSE] Skipped saving maxWeightXReps due to invalid input.");
    }

    final rirModel = _selectedRirModel[widget.exerciseName];
    print("🧪 [DISPOSE] Checking RIR model for ${widget.exerciseName}: ${_selectedRirModel[widget.exerciseName]}");

    if (rirModel != null && rirModel.isNotEmpty) {
      safeSave('rirModel', rirModel);
      print("💾 [DISPOSE] Saved RIR model for ${widget.exerciseName}: $rirModel");

    }


    if (_cachedRirPlan != null && _cachedRirPlan!.isNotEmpty) {
      // 🧯 One final prune using repTargets as the source of truth
      final repTargets = widget.exerciseSettings[widget.exerciseId]?['repTargets'];
      final instCount = (repTargets?['week1'] as Map?)?.keys
          .where((k) => k.toString().startsWith('instance'))
          .length ??
          0;
      final freqForSave = instCount > 0
          ? instCount
          : int.tryParse(_weeklyFrequencyController.text.trim()) ?? 3;

      _pruneRirPlanToFrequency(freqForSave);
      _updateRirSummaryDisplay(freqOverride: freqForSave);

      safeSave('rirPlan', _cachedRirPlan);
      print("💾 [DISPOSE] Saved rirPlan (pruned to $freqForSave) for ${widget.exerciseName}: ${jsonEncode(_cachedRirPlan)}");
      final uid = _cachedUid;
      final bid = _parentBlockId;

      if (uid != null && uid.isNotEmpty && bid != null && bid.isNotEmpty) {
        final docRef = FirebaseFirestore.instance
            .collection('planned_blocks')
            .doc(uid)
            .collection('blocks')
            .doc(bid);

        // Pull latest local entry (safeSave already wrote into exerciseSettings)
        final entry = Map<String, dynamic>.from(
          widget.exerciseSettings[widget.exerciseId] ?? {},
        );

        final payload = <String, dynamic>{
          'exerciseSettings.${widget.exerciseId}.rirPlan': entry['rirPlan'],
          'plannedExerciseDetails.${widget.exerciseId}.rirPlan': entry['rirPlan'],
          'exerciseSettings.${widget.exerciseId}.rirModel': entry['rirModel'],
          'plannedExerciseDetails.${widget.exerciseId}.rirModel': entry['rirModel'],
        };

        docRef.set(payload, SetOptions(merge: true)).catchError((e) {
          print("❌ [DISPOSE] Firestore flush failed for ${widget.exerciseId}: $e");
        });

        print("📤 [DISPOSE] Flushed rirPlan/rirModel to Firestore for ${widget.exerciseName} (block=$bid)");

        // ✅ Refresh the current_block pointer so WES re-reads the active block
        FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .collection('block_planner')
            .doc('current_block')
            .set({
          'blockId': bid,
        }, SetOptions(merge: true)).catchError((e) {
          print("❌ [DISPOSE] current_block update failed (uid=$uid blockId=$bid): $e");
        });

      } else {
        print("⚠️ [DISPOSE] Skip Firestore flush (uid=$uid blockId=$bid)");
      }


    }

    _weeklyFrequencyController.dispose();
    _weeklyFrequencyFocusNode.dispose();
    _repTargetsDisplayController.dispose();
    _incrementsController.dispose();
    _notesController.dispose();
    _maxWeightController.dispose();
    _maxRepsController.dispose();
    _rirDisplayController.dispose();
    _incrementsFocusNode.dispose();
    _rirFocusNode.dispose();


    // ⬇️ Kick a WES warm for *today* based on these BP edits (fire-and-forget)
    try {
      final String uidSelected = UserContext.of(context, listen: false).currentUid; // selected athlete
      if (uidSelected.isNotEmpty) {
        final now = DateTime.now();
        final dOnly = DateTime(now.year, now.month, now.day); // LOCAL date-only
        // Service should fetch the active block id internally
        WarmupService.instance.warmWES(uidSelected, selectedDate: dOnly);
        debugPrint('🚀 [BP→Warm] Warm kicked for ${dOnly.toIso8601String().substring(0,10)} (uid=$uidSelected)');
      } else {
        debugPrint('⚠️ [BP→Warm] No selected uid; skip warm.');
      }
    } catch (e) {
      debugPrint('🟧 [BP→Warm] warm kick failed: $e');
    }


    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Safe time to read ancestors
    _parentBlockId = context.findAncestorStateOfType<_BlockPlannerState>()?.blockIdToUse;
    _cachedUid = UserContext.of(context, listen: false).currentUid;

  }


  double roundToNearestHalf(double value) {
    return (value * 2).round() / 2.0;
  }

  void _syncCachedRepTargets(String exerciseId) {
    // 🧩 Try by ID first, then fall back to name
    var settings = widget.exerciseSettings[exerciseId];
    if (settings == null && widget.exerciseSettings.containsKey(widget.exerciseName)) {
      settings = widget.exerciseSettings[widget.exerciseName];
      print("⚠️ [_syncCachedRepTargets] Fallback used: exerciseName key instead of ID");
    }

    final reps = settings?['repTargets'];
    final exName = widget.exerciseName;
    final exId = exerciseId;
    print("🛠️ [_syncCachedRepTargets] for $exName ($exId) → $reps");
    // 🟣 Handle DUP Signature: show "min – max reps"
    if (reps is Map<String, dynamic> && reps['repRange'] is Map) {
      final rr = Map<String, dynamic>.from(reps['repRange'] as Map);
      final min = rr['min']?.toString() ?? '6';
      final max = rr['max']?.toString() ?? '10';
      _repTargetsDisplayController.text = '$min – $max reps';

      // Keep a minimal cache so dialogs relying on _cachedRepTargetMap are safe
      _cachedRepTargetMap = {
        'week1': {'instance1': '$min – $max reps'}
      };
      print("✅ [_syncCachedRepTargets] Signature preview → ${_repTargetsDisplayController.text}");
      return; // done
    }



    if (reps is Map<String, dynamic> &&
        reps.keys.any((k) => k.toString().startsWith('week'))) {
      final sortedWeeks = reps.keys.toList()..sort();
      final formatted = <String>[];
      final safeMap = <String, Map<String, String>>{};

      for (final week in sortedWeeks) {
        final instanceMap = reps[week];
        if (instanceMap is Map<String, dynamic>) {
          final sortedInstances = instanceMap.keys.toList()
            ..sort((a, b) {
              final ai = int.tryParse(a.replaceAll('instance', '')) ?? 0;
              final bi = int.tryParse(b.replaceAll('instance', '')) ?? 0;
              return ai.compareTo(bi);
            });

          final weekSafeMap = <String, String>{};
          for (final key in sortedInstances) {
            final val = instanceMap[key]?.toString() ?? '';
            weekSafeMap[key] = val;
          }

          safeMap[week] = weekSafeMap;
          formatted
              .add(sortedInstances.map((k) => weekSafeMap[k]!).join(' | '));
        }
      }

      _repTargetsDisplayController.text = formatted.join(' || ');
      _cachedRepTargetMap = safeMap;
      print("✅ [_syncCachedRepTargets] Cache updated for $exerciseId");
    } else {
      print(
          "! [_syncCachedRepTargets] No valid repTargets found (value: $reps)");
    }


  }

  void _syncCachedRirPlan(String exerciseName) {
    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName];
    final rirRaw = widget.exerciseSettings[exerciseId]?['rirPlan']
        ?? widget.exerciseSettings[exerciseName]?['rirPlan'];


    print("🛠️ [_syncCachedRirPlan] for $exerciseName → $rirRaw");

    if (rirRaw is Map<String, dynamic>) {
      final parsed = <String, Map<String, Map<String, Map<String, String>>>>{};

      for (final weekKey in rirRaw.keys) {
        final weekVal = rirRaw[weekKey];
        if (weekVal is Map<String, dynamic>) {
          final sessionMap = <String, Map<String, Map<String, String>>>{};

          for (final sessionKey in weekVal.keys) {
            final sessionVal = weekVal[sessionKey];
            if (sessionVal is Map<String, dynamic>) {
              final setMap = <String, Map<String, String>>{};

              for (final setKey in sessionVal.keys) {
                final setVal = sessionVal[setKey];
                if (setVal is Map<String, dynamic>) {
                  setMap[setKey] = {
                    'rir': setVal['rir']?.toString() ?? '',
                    'reps': setVal['reps']?.toString() ?? '',
                  };
                }
              }

              sessionMap[sessionKey] = setMap;
            }
          }

          parsed[weekKey] = sessionMap;
        }
      }

      _cachedRirPlan = parsed;
      print("✅ [_syncCachedRirPlan] RIR cache updated for $exerciseName");
    } else {
      print("❌ [_syncCachedRirPlan] No valid rirPlan found.");
      _cachedRirPlan = {};
    }
  }


  void _updateE1RM() {
    final weight = double.tryParse(_maxWeightController.text);
    final reps = double.tryParse(_maxRepsController.text);

    if (weight != null && reps != null) {
      setState(() {
        _currentE1RM = PeriodizationModelUtils.calculateE1RM(weight, reps, 0.5);
      });
    }
  }

  //Handles Default Settings for most Exercises


// Model Begin

  List<List<String>> getDefaultReps(String model, int frequency) {
    switch (model) {
      case 'DUP, By Exposure':
        const dupMap = {
          1: [10],
          2: [10, 5],
          3: [10, 5, 8],
          4: [10, 5, 8, 1],
          5: [12, 4, 8, 1, 6],
          6: [10, 3, 6, 1, 9, 5],
          7: [10, 4, 8, 2, 12, 5, 1],
        };
        final reps = dupMap[frequency] ??
            List.generate(frequency, (i) => [10, 5, 8, 1, 12, 4, 6][i % 7]);
        return [reps.map((r) => '$r x 3').toList()]; // 👈 one week

      case 'Linear, Classic':
        final base = List.generate(12, (week) {
          return List.generate(frequency, (i) {
            final reps = (12 - week - i).clamp(3, 15);
            final sets = reps < 5 ? 4 : 3;
            return "$reps x $sets";
          });
        });
        return base;

      case 'Linear, by Exposure':
        final reps =
            [12, 10, 8, 6, 4, 2].take(frequency).map((r) => '$r x 3').toList();
        return [reps];

      case 'DUP, Signature':
        const dupMin = 6;
        const dupMax = 10;
        final week = List.generate(
          frequency,
          (i) => '${dupMin + (i % (dupMax - dupMin + 1))} x 3',
        );
        return [week];

      case 'DUP, By Week':
        const baseCycle = [
          [10, 5, 8, 3, 12, 1, 6],
          [9, 4, 7, 11, 2, 5, 8],
          [12, 3, 6, 1, 9, 4, 7],
        ];
        final block = List.generate(12, (week) {
          final pattern = baseCycle[week % baseCycle.length];
          return List.generate(frequency, (i) {
            final r = pattern[i % pattern.length];
            final s = r < 5 ? 4 : 3;
            return '$r x $s';
          });
        });
        return block;

      default:
        return [List.generate(frequency, (i) => '10 x 3')];
    }
  }

  void _showLinearClassicRepTargetDialog(String exerciseName) {
    _syncCachedRepTargets(widget.exerciseId);


    print("📆 widget.blockStartDate = ${widget.blockStartDate}");
    print("📆 widget.blockEndDate = ${widget.blockEndDate}");

    final blockLength = PeriodizationModelUtils.getBlockLength(
      blockStartDate: widget.blockStartDate,
      blockEndDate: widget.blockEndDate,
    );
    print("🧠 Calculated blockLength = $blockLength");

    final frequency = int.tryParse(_weeklyFrequencyController.text) ?? 3;

    final defaultStart = List.generate(frequency, (i) => '${12 - i} x 3');
    final defaultEnd = List.generate(frequency, (i) => '1 x 3');

    // Load any saved data
    final raw = _cachedRepTargetMap ?? widget.exerciseSettings[widget.exerciseId]?['repTargets'];

    final saved =
        raw is Map<String, dynamic> ? Map<String, dynamic>.from(raw) : {};

    // Extract week1 and finalWeek from saved
    final week1 = saved['week1'] as Map<String, dynamic>? ?? {};
    final weekFinal = saved['week$blockLength'] as Map<String, dynamic>? ?? {};

    List<String> week1Vals = List.generate(frequency, (i) {
      final raw = week1['instance${i + 1}']?.toString();
      return raw ?? defaultStart[i];
    });

    List<String> finalWeekVals = List.generate(frequency, (i) {
      final raw = weekFinal['instance${i + 1}']?.toString();
      return raw ?? defaultEnd[i];
    });

    // Create controllers for start and end weeks
    final week1Reps = <TextEditingController>[];
    final week1Sets = <TextEditingController>[];
    final finalReps = <TextEditingController>[];
    final finalSets = <TextEditingController>[];

    print("🧠 blockLength = $blockLength");
    print("🧠 week1 raw = ${saved['week1']}");
    print("🧠 final week raw = ${saved['week$blockLength']}");

    for (int i = 0; i < frequency; i++) {
      final partsStart = week1Vals[i].split('x').map((s) => s.trim()).toList();
      week1Reps.add(TextEditingController(
          text: partsStart.isNotEmpty ? partsStart[0] : '10'));
      week1Sets.add(TextEditingController(
          text: partsStart.length > 1 ? partsStart[1] : '3'));

      final partsEnd =
          finalWeekVals[i].split('x').map((s) => s.trim()).toList();
      finalReps.add(
          TextEditingController(text: partsEnd.isNotEmpty ? partsEnd[0] : '1'));
      finalSets.add(
          TextEditingController(text: partsEnd.length > 1 ? partsEnd[1] : '3'));
    }

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900,
          title: const Text("Linear Classic Rep Targets",
              style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Week 1",
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                for (int i = 0; i < frequency; i++) ...[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: week1Reps[i],
                              keyboardType: TextInputType.number,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                labelText: "Day ${i + 1} Reps",
                                filled: true,
                                fillColor: Colors.blueGrey.shade800,
                                border: const OutlineInputBorder(),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text("x",
                              style:
                                  TextStyle(color: Colors.white, fontSize: 14)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: TextField(
                              controller: week1Sets[i],
                              keyboardType: TextInputType.number,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                labelText: "Sets",
                                filled: true,
                                fillColor: Colors.blueGrey.shade800,
                                border: const OutlineInputBorder(),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                const Text("Final Week",
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                for (int i = 0; i < frequency; i++) ...[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: finalReps[i],
                              keyboardType: TextInputType.number,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                labelText: "Day ${i + 1} Reps",
                                filled: true,
                                fillColor: Colors.blueGrey.shade800,
                                border: const OutlineInputBorder(),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text("x",
                              style:
                                  TextStyle(color: Colors.white, fontSize: 14)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: TextField(
                              controller: finalSets[i],
                              keyboardType: TextInputType.number,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                labelText: "Sets",
                                filled: true,
                                fillColor: Colors.blueGrey.shade800,
                                border: const OutlineInputBorder(),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 8),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:
                  const Text("Cancel", style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () {
                final result = <String, Map<String, String>>{};

                for (int week = 0; week < blockLength; week++) {
                  final instanceMap = <String, String>{};

                  for (int i = 0; i < frequency; i++) {
                    final startReps =
                        int.tryParse(week1Reps[i].text.trim()) ?? 10;
                    final endReps = int.tryParse(finalReps[i].text.trim()) ?? 1;
                    final sets = week1Sets[i].text.trim(); // sets stay constant

                    final repsThisWeek = (startReps +
                            ((endReps - startReps) *
                                (week / (blockLength - 1))))
                        .round();
                    instanceMap['instance${i + 1}'] = "$repsThisWeek x $sets";
                    print('💾 finalReps[0] = ${finalReps[0].text}');
                    print('💾 finalSets[0] = ${finalSets[0].text}');
                  }

                  result['week${week + 1}'] = instanceMap;
                  print("💾 Saving week${week + 1} = $instanceMap");
                }

                setState(() {
                  widget.onUpdateSetting(widget.exerciseId, 'repTargets', result);
                  _repTargetsDisplayController.text =
                      result['week1']!.values.join(' | ');
                });

                Navigator.pop(ctx);
              },
              child: const Text("Save", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showDailyUndulatingExposureRepTargetDialog(String exerciseName) {
    _syncCachedRepTargets(
        exerciseName); // 🔁 Pull saved data from settings if available

    final frequency = int.tryParse(_weeklyFrequencyController.text) ?? 3;

    // Load raw saved value
    final existing = _cachedRepTargetMap ?? widget.exerciseSettings[widget.exerciseId]?['repTargets'];

    print("📍 [DUP Daily - By Week] Raw data: $existing");

    // Get fallback defaults
    final defaults = PeriodizationModelUtils.getDefaultReps(
      PeriodizationModelType.dailyUndulatingExposure,
      frequency,
    );
    final defaultReps = defaults['week1']?.values.toList() ?? [];
    // 🔢 Pull per-exercise default sets (falls back to 3)
    final int defaultSets = (widget.exerciseSettings[widget.exerciseId]?['defaultSets'] ?? 3) as int;


    // Normalize to saved user reps and sets
    final repsControllers = <TextEditingController>[];
    final setsControllers = <TextEditingController>[];

    for (int i = 0; i < frequency; i++) {
      final base = (i < defaultReps.length) ? defaultReps[i] : '10 x 3';
      final baseReps = base.split('x').first.trim();
      final String fallback = '$baseReps x $defaultSets';

      String saved = '';

      if (existing is Map<String, dynamic>) {
        final weekMap = existing['week1'] as Map<String, dynamic>?;
        saved = weekMap?['instance${i + 1}']?.toString() ?? '';
      }

      final combined = saved.isNotEmpty ? saved : fallback;
      final parts = combined.split('x').map((s) => s.trim()).toList();
      final reps = parts.isNotEmpty ? parts[0] : '';
      final sets = parts.length > 1 ? parts[1] : '';

      repsControllers.add(TextEditingController(text: reps));
      setsControllers.add(TextEditingController(text: sets));
    }

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900,
          title: const Text(
            "Daily Undulating Reps (1 Week Pattern)",
            style: TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: frequency,
              itemBuilder: (context, i) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: repsControllers[i],
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: "Day ${i + 1} Reps",
                            labelStyle: const TextStyle(color: Colors.white70),
                            filled: true,
                            fillColor: Colors.blueGrey.shade800,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 10),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: setsControllers[i],
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: "Sets",
                            labelStyle: const TextStyle(color: Colors.white70),
                            filled: true,
                            fillColor: Colors.blueGrey.shade800,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 10),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:
                  const Text("Cancel", style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () {
                final instanceMap = <String, String>{};

                for (int i = 0; i < frequency; i++) {
                  final reps = repsControllers[i].text.trim();
                  final sets = setsControllers[i].text.trim();
                  final combined =
                  reps.isNotEmpty && sets.isNotEmpty ? "$reps x $sets" : '';
                  instanceMap['instance${i + 1}'] = combined;
                  print('✅ Saving instance${i + 1}: "$combined"');
                }

                final result = {'week1': instanceMap};
                print('🧠 Final saved map: ${jsonEncode(result)}');

                setState(() {
                  _cachedRepTargetMap = result; // ✅ Cache it locally too

                  widget.onUpdateSetting(widget.exerciseId, 'repTargets', result);


                  final preview = instanceMap.values
                      .take(5)
                      .where((r) => r.isNotEmpty)
                      .join(' | ') +
                      (instanceMap.length > 5 ? ' ...' : '');
                  print('🧠 [DUP Exposure Save] Preview Text → $preview');
                  _repTargetsDisplayController.text = preview;
                });

                Navigator.pop(ctx);
              }              ,
              child: const Text("Save", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showDupSignatureRepTargetDialog(String exerciseName) async {
    int min = 6;
    int max = 10;

    final existing = _cachedRepTargetMap ??
        widget.exerciseSettings[widget.exerciseId]?['repTargets'];
    print("🧪 [DUP Signature] Raw repTargets: $existing");

    if (existing is Map<String, dynamic> && existing.containsKey('repRange')) {
      final range = existing['repRange'] as Map<String, dynamic>;
      min = int.tryParse(range['min']?.toString() ?? '') ?? min;
      max = int.tryParse(range['max']?.toString() ?? '') ?? max;
      print("🔢 Loaded from repRange → min: $min, max: $max");
    } else if (existing is Map<String, dynamic>) {
      // fallback check (legacy format)
      final fallback = existing['week1']?['instance1']?.toString();
      final parts = fallback?.split('–');
      if (parts != null && parts.length == 2) {
        min = int.tryParse(parts[0].trim()) ?? min;
        max = int.tryParse(parts[1].replaceAll('reps', '').trim()) ?? max;
        print("🔁 Inferred from legacy fallback → min: $min, max: $max");
      }
    }

    await showDialog(
      context: context,
      builder: (ctx) {
        int tempMin = min;
        int tempMax = max;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.blueGrey.shade900,
              title: Text("Set Rep Range for $exerciseName",
                  style: const TextStyle(color: Colors.white)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Text("Min Reps:",
                          style: TextStyle(color: Colors.white)),
                      const SizedBox(width: 10),
                      DropdownButton<int>(
                        value: tempMin,
                        dropdownColor: Colors.blueGrey.shade800,
                        items: List.generate(12, (i) => i + 1).map((rep) {
                          return DropdownMenuItem(
                            value: rep,
                            child: Text("$rep",
                                style: const TextStyle(color: Colors.white)),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() {
                              tempMin = val;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text("Max Reps:",
                          style: TextStyle(color: Colors.white)),
                      const SizedBox(width: 10),
                      DropdownButton<int>(
                        value: tempMax,
                        dropdownColor: Colors.blueGrey.shade800,
                        items: List.generate(20, (i) => i + 1).map((rep) {
                          return DropdownMenuItem(
                            value: rep,
                            child: Text("$rep",
                                style: const TextStyle(color: Colors.white)),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() {
                              tempMax = val;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Cancel"),
                ),
                TextButton(
                  onPressed: () {
                    final firestoreResult = {
                      'repRange': {
                        'min': tempMin.toString(),
                        'max': tempMax.toString(),
                      },
                      'week1': {
                        'instance1': "$tempMin – $tempMax reps",
                      }
                    };

                    final memoryCache = {
                      'repRange': {
                        'min': tempMin.toString(),
                        'max': tempMax.toString(),
                      }
                    };

                    _cachedRepTargetMap = memoryCache;
                    print("💾 [DUP Signature] Saving min=$tempMin, max=$tempMax");
                    print(
                        "💾 [DUP Signature] Final repTargets structure: ${jsonEncode(firestoreResult)}");

                    setState(() {
                      widget.onUpdateSetting(
                          widget.exerciseId, 'repTargets', firestoreResult);
                      widget.onUpdateSetting(
                          widget.exerciseId, 'periodizationModel', 'DUP, Signature');
                      _repTargetsDisplayController.text =
                      "$tempMin – $tempMax reps";
                    });


                    Navigator.pop(ctx);
                  },
                  child: const Text("Save"),
                ),
              ],
            );
          },
        );
      },
    );

  }

  void _showLinearExposureRepTargetDialog(String exerciseName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('block_planner')
        .doc('current_block')
        .get();

    final data = snapshot.data();
    if (data == null) return;

    final blockStart = DateTime.parse(data['blockStartDate']);
    final blockEnd = DateTime.parse(data['blockEndDate']);
    final weeklyFreq = int.tryParse(_weeklyFrequencyController.text) ?? 2;

    final totalWeeks = blockEnd.difference(blockStart).inDays ~/ 7;
    final exposureCount = (totalWeeks * weeklyFreq).clamp(1, 36);

    final existing = _cachedRepTargetMap ??
        widget.exerciseSettings[widget.exerciseId]?['repTargets'];

    print("📍 [LE] Raw data: $existing");
    print('🧪 [LinearExposure] Raw existing: ${jsonEncode(existing)}');

    List<String> repsList = List.generate(exposureCount, (i) {
      final reps = (12 - (i * 7 / exposureCount).round()).clamp(5, 15);
      final sets = (i % 2 == 0) ? 3 : 4;
      return "$reps x $sets";
    });

// 🧠 Overlay saved instance values if present
    if (existing is Map<String, dynamic>) {
      final weekMap = existing['week1'];
      if (weekMap is Map<String, dynamic>) {
        for (int i = 0; i < exposureCount; i++) {
          final key = 'instance${i + 1}';
          final saved = weekMap[key]?.toString();
          if (saved != null && saved.isNotEmpty) {
            repsList[i] = saved;
          }
        }
      }
    }

    final controllers =
        repsList.map((value) => TextEditingController(text: value)).toList();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900,
          title: const Text("Rep Targets by Exposure",
              style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: (exposureCount / 2).ceil(),
              itemBuilder: (context, i) {
                final index1 = i * 2;
                final index2 = index1 + 1;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text("Exposure ${index1 + 1}",
                              style: const TextStyle(color: Colors.white70)),
                          const SizedBox(width: 24),
                          if (index2 < exposureCount)
                            Text("Exposure ${index2 + 1}",
                                style: const TextStyle(color: Colors.white70)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: controllers[index1],
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: "e.g. 10 x 3",
                                hintStyle:
                                    const TextStyle(color: Colors.white38),
                                filled: true,
                                fillColor: Colors.blueGrey.shade800,
                                border: const OutlineInputBorder(),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 10),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          if (index2 < exposureCount)
                            Expanded(
                              child: TextField(
                                controller: controllers[index2],
                                style: const TextStyle(color: Colors.white),
                                decoration: InputDecoration(
                                  hintText: "e.g. 8 x 4",
                                  hintStyle:
                                      const TextStyle(color: Colors.white38),
                                  filled: true,
                                  fillColor: Colors.blueGrey.shade800,
                                  border: const OutlineInputBorder(),
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 10),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:
                  const Text("Cancel", style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () {
                final updated = controllers.map((c) => c.text.trim()).toList();

                // 🧪 DEBUG: Print each field input
                for (int i = 0; i < updated.length; i++) {
                  print('✅ Exposure ${i + 1}: ${updated[i]}');
                }

                // ✅ Create a proper instance map
                final instanceMap = <String, String>{
                  for (int i = 0; i < updated.length; i++)
                    'instance${i + 1}': updated[i]
                };

                final result = {'week1': instanceMap};

                // ✅ Save to state and update display controller
                setState(() {
                  widget.onUpdateSetting(widget.exerciseId, 'repTargets', result);
                  _repTargetsDisplayController.text =
                      updated.take(5).join(' | ') +
                          (updated.length > 5 ? ' ...' : '');
                });


                Navigator.pop(ctx);
              },
              child: const Text("Save", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showDailyUndulatingWeekRepTargetDialog(String exerciseName) {
    _syncCachedRepTargets(widget.exerciseId);

    final frequency = int.tryParse(_weeklyFrequencyController.text) ?? 3;
    // 🔢 Per-exercise default sets (3 by default)
    final int defaultSets = (widget.exerciseSettings[widget.exerciseId]?['defaultSets'] ?? 3) as int;

// 🧩 Exercise explicit week1 defaults (seed created when exercise was added)
    final Map<String, dynamic>? explicitWeek1 =
    (widget.exerciseSettings[widget.exerciseId]?['explicitRepTargets']?['week1'] as Map?)?.cast<String, dynamic>();


    // Load saved or default data
    final raw = _cachedRepTargetMap ??
        widget.exerciseSettings[widget.exerciseId]?['repTargets'];
    final savedMap = raw is Map<String, dynamic>
        ? Map<String, dynamic>.from(raw['week1'] ?? {})
        : {};

    // Build fallback: prefer the exercise's explicit defaults; otherwise PMU pattern normalized to defaultSets
    final List<String> fallback = () {
      if (explicitWeek1 != null && explicitWeek1.isNotEmpty) {
        // Use explicit week1 instance1..instanceN
        final keys = explicitWeek1.keys.toList()
          ..sort((a, b) {
            final ai = int.tryParse(a.replaceAll('instance', '')) ?? 0;
            final bi = int.tryParse(b.replaceAll('instance', '')) ?? 0;
            return ai.compareTo(bi);
          });
        final values = keys.map((k) => explicitWeek1[k]?.toString() ?? '').where((s) => s.isNotEmpty).toList();
        return List<String>.generate(frequency, (i) {
          final v = (i < values.length) ? values[i] : values.lastOrNull ?? '10 x $defaultSets';
          return v;
        });
      } else {
        // Fallback to PMU-like reps but force sets = defaultSets
        const pattern = [10, 5, 8, 3, 12, 1, 6];
        return List<String>.generate(frequency, (i) => '${pattern[i % pattern.length]} x $defaultSets');
      }
    }();


    final reps = List<String>.generate(frequency, (i) {
      final key = 'instance${i + 1}';
      return savedMap[key]?.toString() ?? fallback[i];
    });

    final repsControllers = <TextEditingController>[];
    final setsControllers = <TextEditingController>[];

    for (final r in reps) {
      final parts = r.split('x').map((s) => s.trim()).toList();
      repsControllers
          .add(TextEditingController(text: parts.isNotEmpty ? parts[0] : '10'));
      setsControllers
          .add(TextEditingController(text: parts.length > 1 ? parts[1] : '3'));
    }

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900,
          title: const Text("Rep Targets (1 Week)",
              style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: frequency,
              itemBuilder: (context, i) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: repsControllers[i],
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: "Day ${i + 1} Reps",
                            labelStyle: const TextStyle(color: Colors.white70),
                            filled: true,
                            fillColor: Colors.blueGrey.shade800,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 10),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: setsControllers[i],
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: "Sets",
                            labelStyle: const TextStyle(color: Colors.white70),
                            filled: true,
                            fillColor: Colors.blueGrey.shade800,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 10),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:
                  const Text("Cancel", style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () {
                final instanceMap = <String, String>{};
                for (int i = 0; i < repsControllers.length; i++) {
                  final reps = repsControllers[i].text.trim();
                  final sets = setsControllers[i].text.trim();
                  instanceMap['instance${i + 1}'] = "$reps x $sets";
                }

                final result = {'week1': instanceMap};

                setState(() {
                  widget.onUpdateSetting(widget.exerciseId, 'repTargets', result);
                  _repTargetsDisplayController.text =
                      instanceMap.values.where((v) => v.isNotEmpty).join(' | ');
                });

                Navigator.pop(ctx);
              },
              child: const Text("Save", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }



  // RIR Models                                               RIR MODELS

  void _showLinearTaperRirTargetDialog(String exerciseName, {int? frequency}) {
    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName];

    print("🆔 Checking keys → ID: $exerciseId | Name: $exerciseName");
    print("📦 Settings keys: ${widget.exerciseSettings.keys}");


    final settings = widget.exerciseSettings[exerciseId];
    final model = settings?['periodizationModel'];
    final weeklyFrequency = settings?['weeklyFrequency'];

    final details = widget.exerciseSettings[widget.exerciseId] ?? {};

    final blockLengthWeeks = widget.blockStartDate != null && widget.blockEndDate != null
        ? PeriodizationModelUtils.getBlockLength(
      blockStartDate: widget.blockStartDate!,
      blockEndDate: widget.blockEndDate!,
    )
        : 6;

    final periodizationModel = details['periodizationModel'] ?? '';
    final instanceMap = details['repTargets']?['week1'] ?? {};

    // ✅ Rep string parsing for sets per session
    final repString = details['repTargets']?['week1']?['instance1'] ?? '';
    final match = RegExp(r'x\s*(\d+)').firstMatch(repString);
    final setsPerSession = int.tryParse(match?.group(1) ?? '3') ?? 3;

    // 🧪 Debugging
    print("📦 [LinearTaper] repString = $repString");
    print("✅ [LinearTaper] $exerciseName → weeklyFrequency=$weeklyFrequency, setsPerSession=$setsPerSession");

    // ✅ Taper logic
    final startRir = blockLengthWeeks > 5 ? 4.0 : 3.0;
    final decrementPerWeek = startRir / blockLengthWeeks;

    showDialog(
      context: context,
      builder: (context) {
        print('🔍 [SHOWDIALOG] Cached RIR Plan for $exerciseName: $_cachedRirPlan');
        print('🔍 [SHOWDIALOG] Lookup week1/session1/set1 = ${_cachedRirPlan?["week1"]?["session1"]?["set1"]}');
        return Dialog(
          child: SizedBox(
            width: double.maxFinite,
            height: 500,
            child: Column(
              children: [
                Expanded(
                  child: Scrollbar(
                    thumbVisibility: true,
                    child: ListView.builder(
                      itemCount: blockLengthWeeks,
                      itemBuilder: (context, weekIndex) {
                        final currentWeek = weekIndex + 1;
                        final rawBase = startRir - (weekIndex * decrementPerWeek);
                        final baseRir = roundToNearestHalf(rawBase.clamp(0, 4));

                        final exerciseId = PeriodizationModelUtils.nameToId[exerciseName];
                        final settings = widget.exerciseSettings[exerciseId];
                        final model = settings?['periodizationModel'];
                        final frequency = model == 'DUP, Signature'
                            ? (settings?['weeklyFrequency'] ?? 3)
                            : instanceMap.keys.where((k) => k.toString().startsWith('instance')).length;

                        return ExpansionTile(
                          title: Text('Week $currentWeek'),
                          children: List.generate(frequency, (sessionIndex) {
                            final sessionTitle = 'Session ${sessionIndex + 1}';
                            final sessionInstanceKey = 'instance${sessionIndex + 1}';
                            final sessionRepString = instanceMap[sessionInstanceKey] ?? '';
                            final repMatch = RegExp(r'^(\d+)\s*x\s*(\d+)').firstMatch(sessionRepString);

                            final set1Reps = int.tryParse(repMatch?.group(1) ?? '10') ?? 10;
                            final setsPerSession = int.tryParse(repMatch?.group(2) ?? '3') ?? 3;

                            return ExpansionTile(
                              title: Text(sessionTitle),
                              children: List.generate(setsPerSession, (setIndex) {
                                final weekKey = 'week${weekIndex + 1}';
                                final sessionKey = 'session${sessionIndex + 1}';
                                final setKey = 'set${setIndex + 1}';

                                final defaultRir = setIndex == 0
                                    ? roundToNearestHalf(baseRir).toString()
                                    : roundToNearestHalf((baseRir + 1 + (setIndex - 1) * 0.5).clamp(0, 4)).toString();

                                final defaultReps = set1Reps.toString();


                                _cachedRirPlan ??= {};
                                _cachedRirPlan!.putIfAbsent(weekKey, () => {});
                                _cachedRirPlan![weekKey]!.putIfAbsent(sessionKey, () => {});
                                _cachedRirPlan![weekKey]![sessionKey]!.putIfAbsent(setKey, () {
                                  return {
                                    'rir': defaultRir,
                                    'reps': defaultReps,
                                  };
                                });

                                final currentSetData = _cachedRirPlan![weekKey]![sessionKey]![setKey]!;
                                final repsValue = currentSetData['reps'] ?? defaultReps;
                                final rirValue = currentSetData['rir'] ?? defaultRir;

                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: TextEditingController.fromValue(
                                            TextEditingValue(
                                              text: repsValue,
                                              selection: TextSelection.collapsed(offset: repsValue.length),
                                            ),
                                          ),
                                          keyboardType: TextInputType.number,
                                          readOnly: setIndex == 0,
                                          style: TextStyle(
                                            color: setIndex == 0 ? Colors.white54 : Colors.white,
                                          ),
                                          decoration: InputDecoration(
                                            labelText: 'Set ${setIndex + 1} Reps',
                                            labelStyle: const TextStyle(color: Colors.white70),
                                            filled: true,
                                            fillColor: Colors.blueGrey.shade800,
                                            border: const OutlineInputBorder(),
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                          ),
                                          onChanged: (val) {
                                            _cachedRirPlan![weekKey]![sessionKey]![setKey]!['reps'] = val;
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: TextField(
                                          controller: TextEditingController.fromValue(
                                            TextEditingValue(
                                              text: rirValue,
                                              selection: TextSelection.collapsed(offset: rirValue.length),
                                            ),
                                          ),
                                          keyboardType: const TextInputType.numberWithOptions(decimal: true),

                                          style: const TextStyle(color: Colors.white),
                                          decoration: InputDecoration(
                                            labelText: 'Set ${setIndex + 1} RIR',
                                            labelStyle: const TextStyle(color: Colors.white70),
                                            filled: true,
                                            fillColor: Colors.blueGrey.shade800,
                                            border: const OutlineInputBorder(),
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                          ),
                                          onChanged: (val) {
                                            _cachedRirPlan![weekKey]![sessionKey]![setKey]!['rir'] = val;
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            );
                          }),
                        );
                      },
                    ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                        },
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          widget.onUpdateSetting(
                            widget.exerciseId,
                            'rirPlan',
                            _cachedRirPlan ?? {},
                          );

                          final weekData = _cachedRirPlan?['week1'] as Map<String, dynamic>?;
                          final freq = widget.exerciseSettings[PeriodizationModelUtils.nameToId[exerciseName]]?['weeklyFrequency'] ?? 3;

                          if (weekData != null) {
                            final summary = <String>[];

                            for (int i = 1; i <= freq; i++) {
                              final session = weekData['session$i'] as Map<String, dynamic>?;
                              final set1 = session?['set1'] as Map<String, dynamic>?;
                              final rir = set1?['rir'];
                              if (rir != null) summary.add(rir.toString());
                            }

                            _rirDisplayController.text = 'W1 → ${summary.join(' | ')}';
                          }

                          Navigator.of(context).pop();
                        },

                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );

      },
    );

  }


  void _showWaveRirUndulationDialog(String exerciseName, {int? frequency}) {
    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName];


    final settings = widget.exerciseSettings[exerciseId];
    final model = settings?['periodizationModel'];
    final weeklyFrequency = settings?['weeklyFrequency'];

    print("🧪 [RIR Tap] Settings for $exerciseName: $settings");
    print("📆 [RIR Tap] Weekly Frequency from settings = $weeklyFrequency hello");
    print("🧪 [RIR Tap] $exerciseName → Selected model: $model");
    final details = widget.exerciseSettings[widget.exerciseId] ?? {};

    print("🆔 Checking keys → ID: $exerciseId | Name: $exerciseName");
    print("📦 Settings keys: ${widget.exerciseSettings.keys}");

    final blockLengthWeeks = widget.blockStartDate != null && widget.blockEndDate != null
        ? PeriodizationModelUtils.getBlockLength(
      blockStartDate: widget.blockStartDate!,
      blockEndDate: widget.blockEndDate!,
    )
        : 6;

    final periodizationModel = details['periodizationModel'] ?? '';
    final instanceMap = details['repTargets']?['week1'] ?? {};

    // ✅ Rep string parsing for sets per session
    final repString = details['repTargets']?['week1']?['instance1'] ?? '';
    final match = RegExp(r'x\s*(\d+)').firstMatch(repString);
    final setsPerSession = int.tryParse(match?.group(1) ?? '3') ?? 3;

    final wave = [3.0, 2.0, 1.0];

    showDialog(
      context: context,
      builder: (context) {
        final Map<String, TextEditingController> _rirControllers = {};
        final Map<String, TextEditingController> _repsControllers = {};

        return Dialog(
          child: SizedBox(
            width: double.maxFinite,
            height: 560,
            child: Column(
              children: [
                Expanded(
                  child: Scrollbar(
                    thumbVisibility: true,
                    child: ListView.builder(
                      itemCount: blockLengthWeeks,
                      itemBuilder: (context, weekIndex) {
                        final currentWeek = weekIndex + 1;
                        final baseRir = wave[weekIndex % wave.length];

                        final model = settings?['periodizationModel'];
                        final frequency = model == 'DUP, Signature'
                            ? (settings?['weeklyFrequency'] ?? 3)
                            : instanceMap.keys.where((k) => k.toString().startsWith('instance')).length;

                        return ExpansionTile(
                          title: Text('Week $currentWeek'),
                          children: List.generate(frequency, (sessionIndex) {
                            final sessionKey = 'instance${sessionIndex + 1}';
                            final sessionRepString = instanceMap[sessionKey] ?? '';
                            final repMatch = RegExp(r'^(\d+)\s*x\s*(\d+)').firstMatch(sessionRepString);

                            final set1Reps = int.tryParse(repMatch?.group(1) ?? '10') ?? 10;
                            final setsPerSession = int.tryParse(repMatch?.group(2) ?? '3') ?? 3;
                            print('🔍 [WaveRIR] Rep string for session ${sessionIndex + 1} = "$sessionRepString" → match = ${repMatch?.group(0)}');


                            print('📘 [WaveRIR] $exerciseName → Week $currentWeek, Session ${sessionIndex + 1} = $sessionRepString → $setsPerSession sets');

                            return ExpansionTile(
                              title: Text('Session ${sessionIndex + 1}'),
                              children: List.generate(setsPerSession, (setIndex) {
                                final weekKey = 'week${weekIndex + 1}';
                                final sKey = 'session${sessionIndex + 1}';
                                final setKey = 'set${setIndex + 1}';

                                final defaultRir = setIndex == 0
                                    ? roundToNearestHalf(baseRir).toString()
                                    : roundToNearestHalf((baseRir + 1 + (setIndex - 1) * 0.5).clamp(0, 4)).toString();

                                final defaultReps = setIndex == 0
                                    ? set1Reps.toString()
                                    : (set1Reps - setIndex).clamp(1, set1Reps).toString();

                                _cachedRirPlan ??= {};
                                _cachedRirPlan![weekKey] ??= {};
                                _cachedRirPlan![weekKey]![sKey] ??= {};

// Only insert defaults if set doesn't exist at all
                                if (!_cachedRirPlan![weekKey]![sKey]!.containsKey(setKey)) {
                                  _cachedRirPlan![weekKey]![sKey]![setKey] = {
                                    'rir': defaultRir,
                                    'reps': defaultReps,
                                  };
                                }

// Use whatever is already in the cache
                                final repsValue = _cachedRirPlan![weekKey]![sKey]![setKey]!['reps'] ?? defaultReps;
                                final rirValue  = _cachedRirPlan![weekKey]![sKey]![setKey]!['rir'] ?? defaultRir;

                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  child: Row(
                                    children: [
                                      // Reps
                                      Expanded(
                                        child: Builder(
                                          builder: (context) {
                                            final controllerKey = '$weekKey-$sKey-$setKey';
                                            _repsControllers[controllerKey] ??= TextEditingController(text: repsValue);

                                            return TextField(
                                              controller: _repsControllers[controllerKey],
                                              keyboardType: TextInputType.number,
                                              readOnly: setIndex == 0, // ✅ Set 1 = read-only
                                              style: TextStyle(
                                                color: setIndex == 0 ? Colors.white54 : Colors.white,
                                              ),
                                              decoration: InputDecoration(
                                                labelText: 'Set ${setIndex + 1} Reps',
                                                labelStyle: const TextStyle(color: Colors.white70),
                                                filled: true,
                                                fillColor: Colors.blueGrey.shade800,
                                                border: const OutlineInputBorder(),
                                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                              ),
                                            );
                                          },
                                        ),
                                      ),

                                      const SizedBox(width: 12),
                                      // RIR
                                      Expanded(
                                        child: Builder(
                                          builder: (context) {
                                            final controllerKey = '$weekKey-$sKey-$setKey';
                                            _rirControllers[controllerKey] ??= TextEditingController(text: rirValue);

                                            return TextField(
                                              controller: _rirControllers[controllerKey],
                                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                              style: const TextStyle(color: Colors.white),
                                              decoration: InputDecoration(
                                                labelText: 'Set ${setIndex + 1} RIR',
                                                labelStyle: const TextStyle(color: Colors.white70),
                                                filled: true,
                                                fillColor: Colors.blueGrey.shade800,
                                                border: const OutlineInputBorder(),
                                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                              ),
                                            );
                                          },
                                        ),
                                      ),

                                    ],
                                  ),
                                );
                              }),
                            );
                          }),
                        );
                      },
                    ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () {
                          Navigator.pop(context); // ❌ Discard changes
                        },
                        child: const Text("Cancel", style: TextStyle(color: Colors.white)),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          // ✅ Write user inputs back into _cachedRirPlan
                          for (final key in _rirControllers.keys) {
                            final parts = key.split('-'); // key = week1-session1-set1
                            if (parts.length != 3) continue;

                            final weekKey = parts[0];
                            final sessionKey = parts[1];
                            final setKey = parts[2];

                            _cachedRirPlan ??= {};
                            _cachedRirPlan![weekKey] ??= {};
                            _cachedRirPlan![weekKey]![sessionKey] ??= {};
                            _cachedRirPlan![weekKey]![sessionKey]![setKey] = {
                              'rir': _rirControllers[key]?.text.trim() ?? '',
                              'reps': _repsControllers[key]?.text.trim() ?? '',
                            };
                          }

                          // ✅ Save to Firestore
                          widget.onUpdateSetting(
                            widget.exerciseId,
                            'rirPlan',
                            _cachedRirPlan ?? {},
                          );

                          final weekData = _cachedRirPlan?['week1'] as Map<String, dynamic>?;

                          if (weekData != null) {
                            final summary = <String>[];

                            for (int i = 1; i <= 3; i++) {
                              final session = weekData['session$i'] as Map<String, dynamic>?;

                              if (session != null) {
                                final set1 = session['set1'] as Map<String, dynamic>?;

                                if (set1 != null) {
                                  final rir = set1['rir'];
                                  if (rir != null) summary.add(rir.toString());
                                }
                              }
                            }

                            _rirDisplayController.text = 'W1 → ${summary.join(' | ')}';
                          }


                          print("💾 [RIR Dialog] Saved RIR plan for $exerciseName → $_cachedRirPlan");
                          Navigator.pop(context); // ✅ Close
                        },
                        child: const Text("Save", style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                ),

              ],
            ),
          ),
        );

      },
    );
  }

  void _showStaticRirDialog(String exerciseName, {int? frequency}) {
    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName];
    final settings = widget.exerciseSettings[exerciseId];
    final weeklyFrequency = settings?['weeklyFrequency'];
    final details = widget.exerciseSettings[widget.exerciseId] ?? {};

    final blockLengthWeeks = widget.blockStartDate != null && widget.blockEndDate != null
        ? PeriodizationModelUtils.getBlockLength(
      blockStartDate: widget.blockStartDate!,
      blockEndDate: widget.blockEndDate!,
    )
        : 6;

    final instanceMap = details['repTargets']?['week1'] ?? {};
    final repString = instanceMap['instance1'] ?? '';
    final match = RegExp(r'x\s*(\d+)').firstMatch(repString);
    final setsPerSession = int.tryParse(match?.group(1) ?? '3') ?? 3;

    showDialog(
      context: context,
      builder: (context) {
        final Map<String, TextEditingController> _rirControllers = {};
        final Map<String, TextEditingController> _repsControllers = {};

        bool _isUpdating = false;

        return Dialog(
          child: SizedBox(
            width: double.maxFinite,
            height: 560,
            child: Column(
              children: [
                Expanded(
                  child: Scrollbar(
                    thumbVisibility: true,
                    child: ListView.builder(
                      itemCount: blockLengthWeeks,
                      itemBuilder: (context, weekIndex) {
                        final currentWeek = weekIndex + 1;
                        final isWeek1 = weekIndex == 0;
                        final weekKey = 'week$currentWeek';
                        final week1Values = _cachedRirPlan?['week1'];

                        final model = settings?['periodizationModel'];
                        final frequency = model == 'DUP, Signature'
                            ? (settings?['weeklyFrequency'] ?? 3)
                            : instanceMap.keys.where((k) => k.toString().startsWith('instance')).length;

                        return ExpansionTile(
                          title: Text('Week $currentWeek'),
                          children: List.generate(frequency, (sessionIndex) {
                            final sKey = 'session${sessionIndex + 1}';
                            final instanceKey = 'instance${sessionIndex + 1}';
                            final repMatch = RegExp(r'^(\d+)\s*x\s*(\d+)').firstMatch(instanceMap[instanceKey] ?? '');
                            final setsPerSession = int.tryParse(repMatch?.group(2) ?? '3') ?? 3;

                            return ExpansionTile(
                              title: Text('Session ${sessionIndex + 1}'),
                              children: List.generate(setsPerSession, (setIndex) {
                                final weekKey = 'week${weekIndex + 1}';
                                final sessionKey = 'session${sessionIndex + 1}';
                                final setKey = 'set${setIndex + 1}';
                                final isWeek1 = weekIndex == 0;

                                // 👇 Default RIR matrix by session index
                                final List<List<double>> defaultRirMatrix = [
                                  [2.0, 2.0, 2.5, 3.0],   // Session 1
                                  [2.0, 2.0, 2.5, 3.0],   // Session 2
                                  [2.0, 2.0, 2.5, 3.5],   // Session 3
                                  [2.5, 3.0, 3.0, 3.5],   // Session 4
                                ];

                                final sessionPatternIndex = sessionIndex < defaultRirMatrix.length
                                    ? sessionIndex
                                    : (sessionIndex % 3); // Cycle if more than 4 sessions

                                final defaultRirFromPattern = setIndex < defaultRirMatrix[sessionPatternIndex].length
                                    ? defaultRirMatrix[sessionPatternIndex][setIndex]
                                    : 3.0;

                                final defaultRir = defaultRirFromPattern.toString();
                                final defaultReps = repMatch?.group(1) ?? '10';

// Ensure cache entry exists
                                _cachedRirPlan ??= {};
                                _cachedRirPlan!.putIfAbsent(weekKey, () => {});
                                _cachedRirPlan![weekKey]!.putIfAbsent(sessionKey, () => {});
                                _cachedRirPlan![weekKey]![sessionKey]!.putIfAbsent(setKey, () {
                                  return {
                                    'rir': defaultRir,
                                    'reps': defaultReps,
                                  };
                                });

                                final currentSetData = _cachedRirPlan![weekKey]![sessionKey]![setKey]!;
                                final repsValue = currentSetData['reps'] ?? defaultReps;
                                final rirValue = currentSetData['rir'] ?? defaultRir;

                                final controllerKey = '$weekKey-$sKey-$setKey';
                                _repsControllers[controllerKey] ??= TextEditingController(text: repsValue);
                                if (isWeek1) {
                                  _repsControllers[controllerKey]!.addListener(() {
                                    if (_isUpdating) return;
                                    _isUpdating = true;

                                    final updatedValue = _repsControllers[controllerKey]!.text;
                                    for (int w = 1; w < blockLengthWeeks; w++) {
                                      final wk = 'week${w + 1}';
                                      final copyKey = '$wk-$sKey-$setKey';
                                      if (_repsControllers[copyKey] != null) {
                                        _repsControllers[copyKey]!.text = updatedValue;
                                      }
                                    }

                                    _isUpdating = false;
                                  });
                                }

                                _rirControllers[controllerKey] ??= TextEditingController(text: rirValue);
                                if (isWeek1) {
                                  _rirControllers[controllerKey]!.addListener(() {
                                    if (_isUpdating) return;
                                    _isUpdating = true;

                                    final updatedValue = _rirControllers[controllerKey]!.text;
                                    for (int w = 1; w < blockLengthWeeks; w++) {
                                      final wk = 'week${w + 1}';
                                      final copyKey = '$wk-$sKey-$setKey';
                                      if (_rirControllers[copyKey] != null) {
                                        _rirControllers[copyKey]!.text = updatedValue;
                                      }
                                    }

                                    _isUpdating = false;
                                  });
                                }


                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _repsControllers[controllerKey],
                                          keyboardType: TextInputType.number,
                                          readOnly: setIndex == 0,
                                          style: TextStyle(color: setIndex == 0 ? Colors.white54 : Colors.white),
                                          decoration: InputDecoration(
                                            labelText: 'Set ${setIndex + 1} Reps',
                                            labelStyle: const TextStyle(color: Colors.white70),
                                            filled: true,
                                            fillColor: Colors.blueGrey.shade800,
                                            border: const OutlineInputBorder(),
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: TextField(
                                          controller: _rirControllers[controllerKey],
                                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                          onChanged: (v) {
                                            // Keep cache hot locally while typing (NO Firestore writes)
                                            final txt = v.trim();
                                            _cachedRirPlan![weekKey]![sessionKey]![setKey]!['rir'] = txt;
                                          },

                                          onTapOutside: (_) {
                                            FocusScope.of(context).unfocus();

                                            // Finalize and flush once on "tap out"
                                            final txt = (_rirControllers[controllerKey]?.text ?? '').trim();
                                            _cachedRirPlan![weekKey]![sessionKey]![setKey]!['rir'] = txt;

                                            widget.onUpdateSetting(widget.exerciseId, 'rirPlan', _cachedRirPlan ?? {});
                                            widget.onUpdateSetting(widget.exerciseId, 'rirModel', 'Static RIR'); // optional but good
                                          },

                                          onEditingComplete: () {
                                            FocusScope.of(context).unfocus();
                                            final txt = (_rirControllers[controllerKey]?.text ?? '').trim();
                                            _cachedRirPlan![weekKey]![sessionKey]![setKey]!['rir'] = txt;

                                            widget.onUpdateSetting(widget.exerciseId, 'rirPlan', _cachedRirPlan ?? {});
                                            widget.onUpdateSetting(widget.exerciseId, 'rirModel', 'Static RIR');
                                          },



                                          style: const TextStyle(color: Colors.white),
                                          decoration: InputDecoration(
                                            labelText: 'Set ${setIndex + 1} RIR',
                                            labelStyle: const TextStyle(color: Colors.white70),
                                            filled: true,
                                            fillColor: Colors.blueGrey.shade800,
                                            border: const OutlineInputBorder(),
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            );

                          }),
                        );
                      },
                    ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text("Cancel", style: TextStyle(color: Colors.white)),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          for (final key in _rirControllers.keys) {
                            final parts = key.split('-');
                            if (parts.length != 3) continue;

                            final weekKey = parts[0];
                            final sessionKey = parts[1];
                            final setKey = parts[2];

                            _cachedRirPlan![weekKey]![sessionKey]![setKey] = {
                              'rir': _rirControllers[key]?.text.trim() ?? '',
                              'reps': _repsControllers[key]?.text.trim() ?? '',
                            };
                          }

                          // 🔒 Safety prune based on current frequency prior to saving
                          final freqNow = (() {
                            // Prefer instance count from repTargets (week1)
                            final instCount = (details['repTargets']?['week1'] as Map?)?.keys
                                .where((k) => k.toString().startsWith('instance'))
                                .length ??
                                0;
                            if (instCount > 0) return instCount;
                            // Fallback to the visible text field
                            return int.tryParse(_weeklyFrequencyController.text.trim()) ?? 3;
                          })();
                          _pruneRirPlanToFrequency(freqNow);


                          widget.onUpdateSetting(widget.exerciseId, 'rirPlan', _cachedRirPlan ?? {});
                          _updateRirSummaryDisplay(freqOverride: freqNow);


                          final weekData = _cachedRirPlan?['week1'] as Map<String, dynamic>?;
                          if (weekData != null) {
                            final summary = <String>[];
                            for (int i = 1; i <= 3; i++) {
                              final session = weekData['session$i'] as Map<String, dynamic>?;
                              final set1 = session?['set1'] as Map<String, dynamic>?;
                              final rir = set1?['rir'];
                              if (rir != null) summary.add(rir.toString());
                            }
                            _rirDisplayController.text = 'W1 → ${summary.join(' | ')}';
                          }

                          print("💾 [Static RIR] Saved RIR plan for $exerciseName → $_cachedRirPlan");
                          Navigator.pop(context);
                        },
                        child: const Text("Save", style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                )
              ],
            ),
          ),
        );
      },
    );
  }


  static Map<String, dynamic> generateStaticRirPlan({
    required int weeks,
    required int sessionsPerWeek,
    required int setsPerSession,
  }) {
    final Map<String, dynamic> plan = {};

    final List<List<double>> defaultRirMatrix = [
      [2.0, 2.0, 2.5, 3.0],
      [2.0, 2.0, 2.5, 3.0],
      [2.0, 2.0, 2.5, 3.5],
      [2.5, 3.0, 3.0, 3.5],
    ];

    for (int week = 1; week <= weeks; week++) {
      final weekKey = 'week$week';
      plan[weekKey] = {};

      for (int session = 1; session <= sessionsPerWeek; session++) {
        final sessionKey = 'session$session';
        plan[weekKey][sessionKey] = {};

        final patternIndex = session < defaultRirMatrix.length ? session - 1 : (session - 1) % 3;

        for (int set = 1; set <= setsPerSession; set++) {
          final setKey = 'set$set';
          final rir = set - 1 < defaultRirMatrix[patternIndex].length
              ? defaultRirMatrix[patternIndex][set - 1]
              : 3.0;

          plan[weekKey][sessionKey][setKey] = {
            'rir': rir.toString(),
            'reps': '10',
          };
        }
      }
    }

    return plan;
  }

  static const Map<String, List<double>> sessionBasedRirPatternsByName = {
    'Bench Press, Barbell': [2.0, 1.5, 0.5, 1.0],
    'Chin-Up': [2.0, 1.5, 0.5, 1.0],
    'Overhead Dumbbell Press, Unilateral': [2.0, 1.5, 0.5, 1.0],
    'Deadlift, Conventional': [3.0, 3.5, 2.5, 1.5],
    'Back Squat, Barbell': [3.0, 2.0, 1.0, 2.5],
    'default': [1.5, 1.0, 0.5, 1.0],
  };




  void _showSessionUndulatingRirDialog(String exerciseName, {int? frequency}) {
    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName];
    final settings = widget.exerciseSettings[exerciseId];
    final weeklyFrequency = settings?['weeklyFrequency'] ?? 3;
    final details = widget.exerciseSettings[widget.exerciseId] ?? {};

    final blockLengthWeeks = widget.blockStartDate != null && widget.blockEndDate != null
        ? PeriodizationModelUtils.getBlockLength(
      blockStartDate: widget.blockStartDate!,
      blockEndDate: widget.blockEndDate!,
    )
        : 6;

    final instanceMap = details['repTargets']?['week1'] ?? {};
    final repString = instanceMap['instance1'] ?? '';
    final match = RegExp(r'x\s*(\d+)').firstMatch(repString);
    final setsPerSession = int.tryParse(match?.group(1) ?? '3') ?? 3;

    final List<double> rirPattern =
        sessionBasedRirPatternsByName[exerciseName] ?? sessionBasedRirPatternsByName['default']!;

    showDialog(
      context: context,
      builder: (context) {
        final Map<String, TextEditingController> _rirControllers = {};
        final Map<String, TextEditingController> _repsControllers = {};

        return Dialog(
          child: SizedBox(
            width: double.maxFinite,
            height: 560,
            child: Column(
              children: [
                Expanded(
                  child: Scrollbar(
                    thumbVisibility: true,
                    child: ListView.builder(
                      itemCount: blockLengthWeeks,
                      itemBuilder: (context, weekIndex) {
                        final currentWeek = weekIndex + 1;
                        final weekKey = 'week$currentWeek';

                        return ExpansionTile(
                          title: Text('Week $currentWeek'),
                          children: List.generate(weeklyFrequency, (sessionIndex) {
                            final sKey = 'session${sessionIndex + 1}';

                            // ✅ Use global session index to avoid resetting each week
                            final totalSessionIndex = (weekIndex * weeklyFrequency) + sessionIndex;
                            final sessionRir = rirPattern[(totalSessionIndex % rirPattern.length).toInt()];

                            final instanceKey = 'instance${sessionIndex + 1}';
                            final repMatch = RegExp(r'^(\d+)\s*x\s*(\d+)').firstMatch(instanceMap[instanceKey] ?? '');
                            final plannedReps = int.tryParse(repMatch?.group(1) ?? '10') ?? 10;
                            final setsPerSession = int.tryParse(repMatch?.group(2) ?? '3') ?? 3;


                            return ExpansionTile(
                              title: Text('Session ${sessionIndex + 1}'),
                              children: List.generate(setsPerSession, (setIndex) {
                                final setKey = 'set${setIndex + 1}';
                                final defaultRir = sessionRir.toString();

                                _cachedRirPlan ??= {};
                                _cachedRirPlan!.putIfAbsent(weekKey, () => {});
                                _cachedRirPlan![weekKey]!.putIfAbsent(sKey, () => {});
                                final isWeek1Set1 = weekIndex == 0 && setIndex == 0;

                                if (isWeek1Set1 || !_cachedRirPlan![weekKey]![sKey]!.containsKey(setKey)) {
                                  _cachedRirPlan![weekKey]![sKey]![setKey] = {
                                    'rir': defaultRir,
                                    'reps': plannedReps.toString(), // ✅ Use reps from the rep target model
                                  };
                                }


                                final currentSetData = _cachedRirPlan![weekKey]![sKey]![setKey]!;
                                final repsValue = plannedReps.toString(); // ✅ Use same reps for all sets

                                final rirValue = currentSetData['rir'] ?? defaultRir;

                                final controllerKey = '$weekKey-$sKey-$setKey';
                                _repsControllers[controllerKey] ??= TextEditingController(text: repsValue);
                                _rirControllers[controllerKey] ??= TextEditingController(text: rirValue);

                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _repsControllers[controllerKey],
                                          keyboardType: TextInputType.number,
                                          readOnly: setIndex == 0,
                                          style: TextStyle(color: setIndex == 0 ? Colors.white54 : Colors.white),
                                          decoration: InputDecoration(
                                            labelText: 'Set ${setIndex + 1} Reps',
                                            labelStyle: const TextStyle(color: Colors.white70),
                                            filled: true,
                                            fillColor: Colors.blueGrey.shade800,
                                            border: const OutlineInputBorder(),
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                          ),
                                        ),
                                      ),

                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: TextField(
                                          controller: _rirControllers[controllerKey],
                                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                          style: const TextStyle(color: Colors.white),
                                          decoration: InputDecoration(
                                            labelText: 'Set ${setIndex + 1} RIR',
                                            labelStyle: const TextStyle(color: Colors.white70),
                                            filled: true,
                                            fillColor: Colors.blueGrey.shade800,
                                            border: const OutlineInputBorder(),
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            );
                          }),
                        );
                      },
                    ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text("Cancel", style: TextStyle(color: Colors.white)),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          for (final key in _rirControllers.keys) {
                            final parts = key.split('-');
                            if (parts.length != 3) continue;

                            final weekKey = parts[0];
                            final sessionKey = parts[1];
                            final setKey = parts[2];

                            _cachedRirPlan![weekKey]![sessionKey]![setKey] = {
                              'rir': _rirControllers[key]?.text.trim() ?? '',
                              'reps': _repsControllers[key]?.text.trim() ?? '',
                            };
                          }

                          // 🔒 Safety prune based on current frequency prior to saving
                          final freqNow = (() {
                            // Prefer instance count from repTargets (week1)
                            final instCount = (details['repTargets']?['week1'] as Map?)?.keys
                                .where((k) => k.toString().startsWith('instance'))
                                .length ??
                                0;
                            if (instCount > 0) return instCount;
                            // Fallback to the visible text field
                            return int.tryParse(_weeklyFrequencyController.text.trim()) ?? 3;
                          })();
                          _pruneRirPlanToFrequency(freqNow);


                          widget.onUpdateSetting(widget.exerciseId, 'rirPlan', _cachedRirPlan ?? {});

                          final weekData = _cachedRirPlan?['week1'] as Map<String, dynamic>?;
                          if (weekData != null) {
                            final summary = <String>[];
                            for (int i = 1; i <= 3; i++) {
                              final session = weekData['session$i'] as Map<String, dynamic>?;
                              final set1 = session?['set1'] as Map<String, dynamic>?;
                              final rir = set1?['rir'];
                              if (rir != null) summary.add(rir.toString());
                            }
                            _rirDisplayController.text = 'W1 → ${summary.join(' | ')}';
                          }

                          print("💾 [Session RIR] Saved RIR plan for $exerciseName → $_cachedRirPlan");
                          Navigator.pop(context);
                        },
                        child: const Text("Save", style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                )
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return GestureDetector(
      onTap: () => setState(() => isExpanded = !isExpanded),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: RichText(
              overflow: isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
              maxLines: isExpanded ? null : 1,
              text: TextSpan(
                children: [
                  TextSpan(
                    text: isExpanded ? "▼  " : "➤  ",
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  TextSpan(
                    text: widget.exerciseName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // E1RM display
          Builder(builder: (_) {
            final w = double.tryParse(_maxWeightController.text);
            final r = double.tryParse(_maxRepsController.text);
            final display = (w != null && r != null)
                ? "Avg E1RM: ${PeriodizationModelUtils.calculateE1RM(w, r, 0.5).toStringAsFixed(1)}kg"
                : "Avg E1RM: –";
            return Text(display, style: const TextStyle(color: Colors.white70, fontSize: 11));
          }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding:
          const EdgeInsets.fromLTRB(6, 10, 6, 10), // reduced horizontal padding
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade800,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blueGrey.shade700),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          GestureDetector(
            onTap: () => setState(() => isExpanded = !isExpanded),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
              ],
            ),
          ),

          if (isExpanded) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 5,
              runSpacing: 4,
              children: [

                SizedBox(
                  width: 158, height: 39,
                  child: TextFormField(
                    controller: _incrementsController,
                    focusNode: _incrementsFocusNode,
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
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      filled: true,
                      fillColor: Colors.blueGrey.shade700,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),

                    // live update while typing
                    onChanged: (txt) {
                      widget.onUpdateSetting(
                        widget.exerciseId,
                        'increments',
                        Block_Planner.parseIncrements(txt),
                      );
                    },

                    // commit on Enter / blur as well
                    onEditingComplete: () {
                      widget.onUpdateSetting(
                        widget.exerciseId,
                        'increments',
                        Block_Planner.parseIncrements(_incrementsController.text),
                      );
                    },
                  ),
                ),


                _smallInput(
                  "Weekly Frequency",
                  controller: _weeklyFrequencyController,
                  focusNode: _weeklyFrequencyFocusNode, // 👈 THIS IS THE ANCHOR YOU ASKED FOR
                  width: 158,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    FilteringTextInputFormatter.allow(RegExp(r'^[0-9]{0,2}$')),
                    TextInputFormatter.withFunction((oldValue, newValue) {
                      final intVal = int.tryParse(newValue.text);
                      if (intVal != null && intVal > 14) {
                        return oldValue;
                      }
                      return newValue;
                    }),
                  ],
                ),



                const SizedBox(height: 6, width:400),

                SizedBox(
                  width: 158,
                  child: DropdownButtonFormField<String>(
                    value: _selectedModel,
                    isExpanded: true,
                    items: [
                      'DUP, By Exposure',
                      'DUP, By Week',
                      'DUP, Signature',
                      'Linear, Classic',
                      'Linear, by Exposure',
                    ].map((label) {
                      return DropdownMenuItem<String>(
                        value: label,
                        child: Text(
                          label,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value == null) return;

                      // blur any focused input
                      FocusScope.of(context).unfocus();

                      // Save the chosen label
                      setState(() {
                        _selectedModel = value;
                        widget.onUpdateSetting(widget.exerciseId, 'periodizationModel', value);
                      });

                      // Map to enum and decide reseed policy
                      final model = _mapLabelToModelType(value);
                      // If DUP Signature, show/save the range in the preview immediately
                      if (model == PeriodizationModelType.dupSignature) {
                        // Try existing range first
                        final existing = widget.exerciseSettings[widget.exerciseId]?['repTargets'];
                        String min = '6';
                        String max = '10';

                        if (existing is Map<String, dynamic> && existing['repRange'] is Map) {
                          final rr = Map<String, dynamic>.from(existing['repRange'] as Map);
                          min = rr['min']?.toString() ?? min;
                          max = rr['max']?.toString() ?? max;
                        }

                        // Seed the structure the dialog expects
                        final result = {
                          'repRange': {'min': min, 'max': max},
                          'week1': {'instance1': '$min – $max reps'},
                        };
                        widget.onUpdateSetting(widget.exerciseId, 'repTargets', result);

                        // Update the read-only field so it matches the dialog
                        _repTargetsDisplayController.text = '$min – $max reps';
                        return; // we're done for Signature
                      }

                      // 🔀 If this exercise defines an override for Linear, Classic, use it (and stop)
                      if (model == PeriodizationModelType.linearClassic) {
                        final perModel = widget.exerciseSettings[widget.exerciseId]?['modelSpecificRepTargets'];
                        if (perModel is Map<String, dynamic>) {
                          final list = perModel['Linear, Classic'];
                          if (list is List) {
                            final sets = (widget.exerciseSettings[widget.exerciseId]?['defaultSets'] as int?) ?? 3;
                            final inst = <String, String>{
                              for (int i = 0; i < list.length; i++) 'instance${i + 1}': '${list[i]} x $sets'
                            };
                            final result = {'week1': inst};

                            widget.onUpdateSetting(widget.exerciseId, 'repTargets', result);
                            _repTargetsDisplayController.text = inst.values.join(' | ');
                            return; // ⬅️ IMPORTANT: do not fall through to useExplicit (Exposure seed)
                          }
                        }
                      }


                      final useExplicit =
                          model == PeriodizationModelType.dailyUndulatingExposure ||
                              model == PeriodizationModelType.dailyUndulatingWeek ||
                              model == PeriodizationModelType.linearClassic;

                      if (useExplicit) {
                        // 1) Try the exercise-specific explicit week1 defaults (what you stored when adding)
                        final seed = widget.exerciseSettings[widget.exerciseId]?['explicitRepTargets'];
                        if (seed is Map<String, dynamic>) {
                          widget.onUpdateSetting(widget.exerciseId, 'repTargets', seed);

                          // Update preview to exactly match the dialog
                          final week1 = Map<String, dynamic>.from(seed['week1'] as Map? ?? const {});
                          final keys = week1.keys.toList()
                            ..sort((a, b) {
                              final ai = int.tryParse(a.toString().replaceAll('instance', '')) ?? 0;
                              final bi = int.tryParse(b.toString().replaceAll('instance', '')) ?? 0;
                              return ai.compareTo(bi);
                            });
                          final preview = keys
                              .map((k) => week1[k]?.toString() ?? '')
                              .where((s) => s.isNotEmpty)
                              .join(' | ');
                          _repTargetsDisplayController.text = preview;
                          return; // done
                        }
                      }

                      if (useExplicit) {
                        // Fallback: reuse the existing saved repTargets (first week) as the seed
                        final existing = widget.exerciseSettings[widget.exerciseId]?['repTargets'];
                        if (existing is Map<String, dynamic> && existing['week1'] is Map) {
                          widget.onUpdateSetting(widget.exerciseId, 'repTargets', existing);
                          final w1 = Map<String, dynamic>.from(existing['week1'] as Map);
                          final keys = w1.keys.toList()
                            ..sort((a, b) {
                              final ai = int.tryParse(a.toString().replaceAll('instance', '')) ?? 0;
                              final bi = int.tryParse(b.toString().replaceAll('instance', '')) ?? 0;
                              return ai.compareTo(bi);
                            });
                          _repTargetsDisplayController.text = keys
                              .map((k) => w1[k]?.toString() ?? '')
                              .where((s) => s.isNotEmpty)
                              .join(' | ');
                          return;
                        }
                      }


                      // 2) Fallback: use PMU defaults but normalize sets to this exercise's defaultSets
                      final frequency = int.tryParse(_weeklyFrequencyController.text) ??
                          (widget.exerciseSettings[widget.exerciseId]?['weeklyFrequency'] as int? ?? 3);
                      final defaultSets = (widget.exerciseSettings[widget.exerciseId]?['defaultSets'] as int?) ?? 3;

                      final def = PeriodizationModelUtils.getDefaultReps(model, frequency);
                      final week1 = Map<String, dynamic>.from(def['week1'] ?? const {});

                      // Normalize "R x 3" -> "R x {defaultSets}"
                      final values = week1.values
                          .take(frequency)
                          .map((v) {
                        final reps = v.toString().split('x').first.trim();
                        return '$reps x $defaultSets';
                      })
                          .toList();

                      // Write normalized map so the dialog reads exactly this
                      final instMap = <String, String>{
                        for (int i = 0; i < values.length; i++) 'instance${i + 1}': values[i]
                      };
                      final normalized = {'week1': instMap};
                      widget.onUpdateSetting(widget.exerciseId, 'repTargets', normalized);

                      // And mirror into the preview
                      _repTargetsDisplayController.text = values.join(' | ');
                    },

                    dropdownColor: Colors.blueGrey.shade800,
                    decoration: InputDecoration(
                      labelText: "Periodization Model",
                      labelStyle: const TextStyle(color: Colors.white),
                      filled: true,
                      fillColor: Colors.blueGrey.shade700,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 10),
                    ),

                  ),
                ),

//Rep target dialog UI
                SizedBox(
                  width: 158, height: 48,
                  child: GestureDetector(
                    onTap: () {
                      final model = _mapLabelToModelType(_selectedModel);

                      // 🧼 Clear stale repTargets if the model changed since last open
                      if (_lastOpenedModel != null && _lastOpenedModel != model) {
                        print("🧼 Model changed from $_lastOpenedModel → $model. Clearing stale repTargets.");
                        widget.onUpdateSetting(widget.exerciseId, 'repTargets', null);

                      }

                      // 🧠 Store this model as last used
                      _lastOpenedModel = model;

                      switch (model) {
                        case PeriodizationModelType.dailyUndulatingExposure:
                          _showDailyUndulatingExposureRepTargetDialog(widget.exerciseName);
                          break;
                        case PeriodizationModelType.dupSignature:
                          _showDupSignatureRepTargetDialog(widget.exerciseName);
                          break;
                        case PeriodizationModelType.linearClassic:
                          print("➡ Opening Linear Classic rep dialog");
                          _showLinearClassicRepTargetDialog(widget.exerciseName);
                          break;
                        case PeriodizationModelType.linearExposure:
                          print("➡ Opening Linear Exposure rep dialog");
                          _showLinearExposureRepTargetDialog(widget.exerciseName);
                          break;
                        case PeriodizationModelType.dailyUndulatingWeek:
                          _showDailyUndulatingWeekRepTargetDialog(widget.exerciseName);
                          break;
                        default:
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Model "$_selectedModel" not supported yet')),
                          );
                      }
                    },

                    child: AbsorbPointer(
                      child: TextFormField(
                        controller: _repTargetsDisplayController,
                        readOnly: true,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'Rep Targets X sets',
                          labelStyle: const TextStyle(color: Colors.white),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                          filled: true,
                          fillColor: Colors.blueGrey.shade700,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 6, width:400),


                //RIR Alert Dialog
                SizedBox(
                  width: 158,
                  child: Theme(
                    data: Theme.of(context).copyWith(
                      canvasColor: Colors.blueGrey.shade700,
                    ),
                    child: DropdownButtonFormField<String>(
                      value: _selectedRirModel[widget.exerciseId], // ✅ FIXED
                      isExpanded: true,
                      items: [
                        'Linear-Taper',
                        'Wave RIR undulation',
                        'Session RIR Undulation',
                        'Static RIR',
                      ].map((label) {
                        return DropdownMenuItem<String>(
                          value: label,
                          child: Text(
                            label,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            softWrap: false,
                          ),
                        );
                      }).toList(),
                      selectedItemBuilder: (context) {
                        return [
                          'Linear-Taper',
                          'Wave RIR undulation',
                          'Session RIR Undulation',
                          'Static RIR',
                        ].map((label) {
                          return Container(
                            alignment: Alignment.centerLeft,
                            width: 130,
                            child: Text(
                              label,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                            ),
                          );
                        }).toList();
                      },
                      onChanged: (value) {
                        setState(() {
                          _selectedRirModel[widget.exerciseId] = value!; // ✅ FIXED
                          print("💾 [UI] Saved RIR model '$value' for ${widget.exerciseId}");

                          _cachedRirPlan = null;
                          _rirDisplayController.text = '[Defaults for Model]';

                          widget.onUpdateSetting(widget.exerciseId, 'rirModel', value);
                        });
                      },
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      decoration: InputDecoration(
                        labelText: 'RIR Periodization Model',
                        labelStyle: const TextStyle(color: Colors.white),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        filled: true,
                        fillColor: Colors.blueGrey.shade700,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      ),
                    ),

                  ),
                ),


                //RIR Targets Alert Dialog
                SizedBox(
                  width: 158,
                  height: 48,
                  child: GestureDetector(
                    onTap: () {
                      final exerciseId = PeriodizationModelUtils.nameToId[widget.exerciseName];
                      final model = _selectedRirModel[exerciseId];
                      final settings = widget.exerciseSettings[exerciseId];
                      final weeklyFrequency = settings?['weeklyFrequency'];

                      print("🧪 [RIR Tap] Settings for ${widget.exerciseName}: $settings");
                      print("📆 [RIR Tap] Weekly Frequency from settings = $weeklyFrequency");
                      print("🧪 [RIR Tap] ${widget.exerciseName} → Selected model: $model");

                      switch (model) {
                        case 'Linear-Taper':
                          _showLinearTaperRirTargetDialog(widget.exerciseName, frequency: weeklyFrequency);
                          break;

                        case 'Wave RIR undulation':
                          _showWaveRirUndulationDialog(widget.exerciseName, frequency: weeklyFrequency);
                          break;

                        case 'Static RIR':
                          _showStaticRirDialog(widget.exerciseName, frequency: weeklyFrequency);
                          break;

                        case 'Session RIR Undulation':
                          _showSessionUndulatingRirDialog(widget.exerciseName, frequency: weeklyFrequency);
                          break;

                        default:
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Model "$model" not supported yet')),
                          );
                      }
                    },
                    child: AbsorbPointer(
                      child: TextFormField(
                        controller: _rirDisplayController, // ✅ ADD THIS LINE
                        focusNode: _rirFocusNode, // ✅ ADD THIS LINE
                        readOnly: true,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'RIR Targets',
                          labelStyle: const TextStyle(color: Colors.white),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                          filled: true,
                          fillColor: Colors.blueGrey.shade700,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                        ),
                      ),
                    ),
                  ),
                ),




                const SizedBox(height: 6, width:400), // Adjust to 10 or 12 if you want more breathing room

                SizedBox(
                  width: 158,
                  height: 48,
                  child: Theme(
                    data: Theme.of(context).copyWith(
                      canvasColor: Colors.blueGrey.shade700,
                    ),
                    child: DropdownButtonFormField<String>(
                      // ✅ Safe assignment for value
                      value: [
                        'Linear Weight Increase',
                        'Smart Progression',
                        'Add Reps',
                        'None',
                      ].contains(_selectedProgressionModel[widget.exerciseId])
                          ? _selectedProgressionModel[widget.exerciseId]
                          : null,

                      isExpanded: true,
                      items: [
                        DropdownMenuItem<String>(
                          value: 'Linear Weight Increase',
                          child: Text(
                            'Linear Weight Increase',
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                        DropdownMenuItem<String>(
                          value: 'Smart Progression',
                          child: Text(
                            'Smart Progression',
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                        DropdownMenuItem<String>(
                          value: 'Add Reps',
                          child: Text(
                            'Add Reps',
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                        DropdownMenuItem<String>(
                          value: 'None',
                          child: Text(
                            'None',
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                      ],
                      selectedItemBuilder: (context) {
                        return [
                          'Linear Weight Increase',
                          'Smart Progression',
                          'Add Reps',
                          'None',
                        ].map((label) {
                          return Container(
                            alignment: Alignment.centerLeft,
                            width: 130,
                            child: Text(
                              label,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                            ),
                          );
                        }).toList();
                      },
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            _selectedProgressionModel[widget.exerciseId] = value;
                            widget.onUpdateSetting(widget.exerciseId, 'progressionModel', value);
                            print("💾 [UI] Saved progression model '$value' for ${widget.exerciseId}");
                          });
                        }
                      },
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      decoration: InputDecoration(
                        labelText: 'Progression Model',
                        labelStyle: const TextStyle(color: Colors.white),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        filled: true,
                        fillColor: Colors.blueGrey.shade700,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      ),
                    ),
                  ),
                ),


                // Add spacing if needed




                SizedBox(
                  width: 158,
                  height: 44, // Match Notes height
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.blueGrey.shade700,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.white38),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Flexible(
                                child: TextField(
                                  controller: _maxWeightController,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),

                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly
                                  ],
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 18),
                                  decoration: const InputDecoration(
                                    hintText: 'kg',
                                    hintStyle: TextStyle(color: Colors.white38),
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(
                                    horizontal: 13, vertical: 10),
                                child: Text('×',
                                    style: TextStyle(
                                        color: Colors.white70, fontSize: 20)),
                              ),
                              Flexible(
                                child: TextField(
                                  controller: _maxRepsController,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly
                                  ],
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 18),
                                  decoration: const InputDecoration(
                                    hintText: 'reps',
                                    hintStyle: TextStyle(color: Colors.white38),
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 8,
                        top: -4,
                        child: Text(
                          'Best Weight × Reps',
                          style: TextStyle(fontSize: 12, color: Colors.white, backgroundColor: Colors.blueGrey.shade700
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 3, width:400), // Adjust to 10 or 12 if you want more breathing room

                SizedBox(
                  width: 350,
                  height:48,
                  child: TextField(
                    controller: _notesController,
                    maxLines: null,
                    minLines: 1,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      labelText: 'Notes',
                      labelStyle: const TextStyle(color: Colors.white),
                      filled: true,
                      fillColor: Colors.blueGrey.shade700,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10),
                    ),
                  ),
                ),
              ],
            )
          ]
        ],
      ),
    );
  }

  Widget _smallInput(
      String label, {
        TextEditingController? controller,
        FocusNode? focusNode, // 👈 ADD THIS
        bool multiline = false,
        double width = 150,
        double verticalPadding = 10,
        TextInputType? keyboardType,
        List<TextInputFormatter>? inputFormatters,
      }) {

    return SizedBox(
      width: width,
      child: TextField(
        focusNode: focusNode, // 👈 ADD THIS
        controller: controller,
        keyboardType: keyboardType, // 👈 Apply here
        inputFormatters: inputFormatters, // 👈 And here
        minLines: multiline ? 3 : 1,
        maxLines: multiline ? 5 : 1,
        style: const TextStyle(fontSize: 12, color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white),
          filled: true,
          fillColor: Colors.blueGrey.shade700,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          isDense: true,
          contentPadding:
              EdgeInsets.symmetric(horizontal: 10, vertical: verticalPadding),
        ),
      ),
    );
  }
}
