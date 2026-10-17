/// Creates a new member's first three planned blocks and the current_block
/// pointer.
///
/// Moved out of `OnboardingPageTwo` (it was `_ensureAtLeastOneBlockExists`).
/// Block names, dates, exercise lists, candidate pools and the pointer shape
/// are unchanged.
///
/// Two entry points:
///  * [FirstBlockSeeder.ensureForEditMode] — the previous behaviour exactly,
///    for Save Changes from Templates / the drawer (an established member
///    already has blocks, so this is a read and nothing else).
///  * [FirstBlockSeeder.ensureForSignup] — resumable. Progress is recorded in
///    a [SeedProgress] owned by the signup attempt, so a retry after a
///    partial failure resumes at the first step that did not complete instead
///    of creating a second Block 1 or skipping the pointer. It reads from the
///    server, throws instead of deferring, and verifies the pointer before
///    returning, so signup never reports completion without a first block.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../block_creation_helper.dart';
import '../block_exercise_defaults_repository.dart';

typedef SeedDefaultsFn = Future<void> Function({
  required String uid,
  required String blockId,
  required List<String> exerciseIds,
});

typedef ScaffoldBlockFn = Future<void> Function(
  DocumentReference<Map<String, dynamic>> blockRef,
  DateTime startDate, {
  int startWeek,
});

Future<void> _defaultScaffold(
  DocumentReference<Map<String, dynamic>> blockRef,
  DateTime startDate, {
  int startWeek = 0,
}) =>
    scaffoldBlockInBackground(blockRef, startDate, startWeek: startWeek);

/// Which signup seeding steps have completed for one account. In memory,
/// owned by the signup attempt.
class SeedProgress {
  String? block1Id;
  String? block1Name;
  bool block1Seeded = false;
  bool pointerWritten = false;
  bool week0Written = false;
  String? block2Id;
  String? block3Id;

  /// True once a retry found blocks it did not create and only repaired the
  /// pointer (see [FirstBlockSeeder.ensureForSignup]).
  bool adoptedExisting = false;
}

/// Thrown when signup seeding cannot establish a first block + pointer.
class FirstBlockSeedException implements Exception {
  FirstBlockSeedException(this.message);
  final String message;
  @override
  String toString() => 'FirstBlockSeedException: $message';
}

class FirstBlockSeeder {
  FirstBlockSeeder({
    required FirebaseFirestore firestore,
    SeedDefaultsFn? seedDefaults,
    ScaffoldBlockFn? scaffold,
  })  : _db = firestore,
        _seedDefaults =
            seedDefaults ?? BlockExerciseDefaultsRepository.seedDefaultsForBlock,
        _scaffold = scaffold ?? _defaultScaffold;

  final FirebaseFirestore _db;
  final SeedDefaultsFn _seedDefaults;
  final ScaffoldBlockFn _scaffold;

  CollectionReference<Map<String, dynamic>> _blocks(String uid) =>
      _db.collection('users').doc(uid).collection('planned_blocks');

  DocumentReference<Map<String, dynamic>> _pointer(String uid) => _db
      .collection('users')
      .doc(uid)
      .collection('block_planner')
      .doc('current_block');

  // ── Edit mode: unchanged behaviour ────────────────────────────────────────

  /// The original `_ensureAtLeastOneBlockExists`. Creates the blocks only for
  /// an account that has none; defers itself briefly if /users is not ready.
  Future<void> ensureForEditMode(String uid, {String? authFallbackName}) async {
    final swTotal = Stopwatch()..start();
    final existingBlocks = await _blocks(uid).get();

    if (existingBlocks.docs.isEmpty) {
      final userSnap = await _db.collection('users').doc(uid).get();
      final data = userSnap.data() ?? {};

      // Gate: wait until /users has core fields (prevents female default).
      final hasCore = userSnap.exists &&
          (data['username'] != null || data['fullName'] != null);
      if (!hasCore) {
        debugPrint('🛑 [Home] Block gate: /users/$uid incomplete → retry in 800ms');
        unawaited(Future.delayed(const Duration(milliseconds: 800), () async {
          await ensureForEditMode(uid, authFallbackName: authFallbackName);
        }));
        return;
      }

      final plan = _SeedPlan.fromUserDoc(data, authFallbackName: authFallbackName);
      final progress = SeedProgress();
      await _createBlocks(uid, plan, progress);
    }

    swTotal.stop();
    debugPrint('⏱️ [Home] _ensureAtLeastOneBlockExists total: ${swTotal.elapsed.inMilliseconds} ms');
  }

  // ── Signup: resumable, verified ───────────────────────────────────────────

  Future<void> ensureForSignup(
    String uid,
    SeedProgress progress, {
    String? authFallbackName,
  }) async {
    if (progress.block1Id == null && !progress.adoptedExisting) {
      final existing =
          await _blocks(uid).get(const GetOptions(source: Source.server));
      if (existing.docs.isNotEmpty) {
        // Blocks this attempt has no record of creating (an earlier attempt's
        // partial seeding on the same account). Never add a second set: adopt
        // them and make sure the pointer exists.
        await _repairPointer(uid, existing.docs);
        progress.adoptedExisting = true;
      }
    }

    if (!progress.adoptedExisting) {
      final userSnap = await _db
          .collection('users')
          .doc(uid)
          .get(const GetOptions(source: Source.server));
      final data = userSnap.data() ?? {};
      final hasCore = userSnap.exists &&
          (data['username'] != null || data['fullName'] != null);
      if (!hasCore) {
        throw FirstBlockSeedException('profile not written before seeding');
      }
      final plan = _SeedPlan.fromUserDoc(data, authFallbackName: authFallbackName);
      await _createBlocks(uid, plan, progress);
    }

    await verifyPointer(uid);
  }

  /// Throws unless current_block names a block that exists on the server.
  Future<void> verifyPointer(String uid) async {
    final ptr = await _pointer(uid).get(const GetOptions(source: Source.server));
    final blockId = (ptr.data() ?? const {})['blockId'];
    if (blockId is! String || blockId.trim().isEmpty) {
      throw FirstBlockSeedException('current_block pointer missing');
    }
    final block = await _blocks(uid)
        .doc(blockId)
        .get(const GetOptions(source: Source.server));
    if (!block.exists) {
      throw FirstBlockSeedException('current_block points at a missing block');
    }
  }

  Future<void> _repairPointer(
    String uid,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> blocks,
  ) async {
    final ptr = await _pointer(uid).get(const GetOptions(source: Source.server));
    final current = (ptr.data() ?? const {})['blockId'];
    if (current is String && blocks.any((d) => d.id == current)) return;

    var active = blocks.first;
    for (final d in blocks) {
      if (d.data()['isActive'] == true) {
        active = d;
        break;
      }
    }
    final data = active.data();
    final start = (data['startDate'] as Timestamp?)?.toDate();
    final end = (data['endDate'] as Timestamp?)?.toDate();
    await _pointer(uid).set({
      'blockId': active.id,
      'blockName': data['name'],
      'templateCandidateExerciseIds':
          data['templateCandidateExerciseIds'] ?? const <String>[],
      'blockMeta': {
        if (start != null) 'blockStartDate': start.toIso8601String(),
        if (end != null) 'blockEndDate': end.toIso8601String(),
      },
    }, SetOptions(merge: true));
    debugPrint('📌 [Onboarding] Repaired current_block pointer → ${active.id}');
  }

  /// Block 1 (active) + defaults + pointer + week_0, then Blocks 2 and 3.
  /// Each step is skipped when [progress] says it already completed.
  Future<void> _createBlocks(String uid, _SeedPlan plan, SeedProgress progress) async {
    final blocksRef = _blocks(uid);
    debugPrint('🆕 [Home] Creating "${plan.block1Name}", "${plan.block2Name}", "${plan.block3Name}"');

    // ── Block 1 (active) ───────────────────────────────────────────────────
    final DocumentReference<Map<String, dynamic>> block1Ref;
    if (progress.block1Id == null) {
      block1Ref = await blocksRef.add(plan.buildBlock(
        name: plan.block1Name,
        isActive: true,
        start: plan.startDate1,
        end: plan.endDate1,
      ));
      progress
        ..block1Id = block1Ref.id
        ..block1Name = plan.block1Name;
      debugPrint('✅ [Home] Block 1 created id=${block1Ref.id}');
    } else {
      block1Ref = blocksRef.doc(progress.block1Id);
    }

    if (!progress.block1Seeded) {
      await _seedDefaults(
        uid: uid,
        blockId: block1Ref.id,
        exerciseIds: plan.seededExerciseIds,
      );
      progress.block1Seeded = true;
    }

    // Pointer write to current_block → Block 1
    if (!progress.pointerWritten) {
      await _pointer(uid).set({
        'blockId': block1Ref.id,
        'blockName': progress.block1Name ?? plan.block1Name,
        'templateCandidateExerciseIds': plan.candidateIds,
        'blockMeta': {
          'blockStartDate': plan.startDate1.toIso8601String(),
          'blockEndDate': plan.endDate1.toIso8601String(),
        },
      }, SetOptions(merge: true));
      progress.pointerWritten = true;
      debugPrint('📌 [Home] Set current_block pointer → ${block1Ref.id}');
    }

    // Eagerly write week_0 so WES2/BB3 can read the current week immediately.
    if (!progress.week0Written) {
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      const weekdays = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
      final week0Ref = block1Ref.collection('weeks').doc('week_0');
      final eagerBatch = _db.batch();
      eagerBatch.set(week0Ref, {'exists': true}, SetOptions(merge: true));
      for (int day = 0; day < 7; day++) {
        final date = plan.startDate1.add(Duration(days: day));
        eagerBatch.set(week0Ref.collection('days').doc('day_$day'), {
          'date': Timestamp.fromDate(date),
          'circuitStartIndices': [0],
          'exercises': [],
          'workoutName': '${weekdays[day]} ${date.day} ${months[date.month - 1]} - Week 1',
          'exists': true,
        }, SetOptions(merge: true));
      }
      await eagerBatch.commit();
      progress.week0Written = true;
      debugPrint('🧱 [Onboarding] Block 1 week_0 ready (eager)');
      // Defer weeks 1–25 for Block 1 to background.
      unawaited(_scaffold(block1Ref, plan.startDate1, startWeek: 1));
    }

    // ── Block 2 (upcoming, not active) ─────────────────────────────────────
    if (progress.block2Id == null) {
      final block2Ref = await blocksRef.add(plan.buildBlock(
        name: plan.block2Name,
        isActive: false,
        start: plan.startDate2,
        end: plan.endDate2,
      ));
      progress.block2Id = block2Ref.id;
      debugPrint('✅ [Onboarding] Block 2 created id=${block2Ref.id}');
      unawaited(() async {
        try {
          await _seedDefaults(
            uid: uid,
            blockId: block2Ref.id,
            exerciseIds: plan.block2ExerciseIds,
          );
          await _scaffold(block2Ref, plan.startDate2);
        } catch (e, st) {
          debugPrint('❌ [Onboarding] Block 2 background init failed: $e\n$st');
        }
      }());
    }

    // ── Block 3 (upcoming, not active) ─────────────────────────────────────
    if (progress.block3Id == null) {
      final block3Ref = await blocksRef.add(plan.buildBlock(
        name: plan.block3Name,
        isActive: false,
        start: plan.startDate3,
        end: plan.endDate3,
      ));
      progress.block3Id = block3Ref.id;
      debugPrint('✅ [Onboarding] Block 3 created id=${block3Ref.id}');
      unawaited(() async {
        try {
          await _seedDefaults(
            uid: uid,
            blockId: block3Ref.id,
            exerciseIds: plan.block3ExerciseIds,
          );
          await _scaffold(block3Ref, plan.startDate3);
        } catch (e, st) {
          debugPrint('❌ [Onboarding] Block 3 background init failed: $e\n$st');
        }
      }());
    }
  }
}

/// Names, dates and exercise lists for the first three blocks.
class _SeedPlan {
  _SeedPlan._({
    required this.username,
    required this.isFemale,
    required DateTime today,
  }) {
    // Start = Monday of the current week ("Monday just gone"); 26 weeks each.
    startDate1 = today.subtract(Duration(days: today.weekday - DateTime.monday));
    endDate1 = startDate1.add(const Duration(days: 181));
    startDate2 = endDate1.add(const Duration(days: 1));
    endDate2 = startDate2.add(const Duration(days: 181));
    startDate3 = endDate2.add(const Duration(days: 1));
    endDate3 = startDate3.add(const Duration(days: 181));

    seededExerciseIds = [
      ..._baseExercises,
      if (isFemale) ..._femaleSpecificExercises else ..._maleSpecificExercises,
    ];
    candidateIds = computeTemplateCandidateIds(isFemale: isFemale);

    block2ExerciseIds = <String>{
      ...seededExerciseIds.where(
        (id) => !(isFemale ? _femaleExclusionsB2 : _maleExclusionsB2).contains(id),
      ),
      ...(isFemale ? _femaleAdditionsB2 : _maleAdditionsB2),
    }.toList(growable: false);

    block3ExerciseIds = <String>{
      ...seededExerciseIds.where(
        (id) => !(isFemale ? _femaleExclusionsB3 : _maleExclusionsB3).contains(id),
      ),
      ...(isFemale ? _femaleAdditionsB3 : _maleAdditionsB3),
    }.toList(growable: false);
  }

  factory _SeedPlan.fromUserDoc(Map<String, dynamic> data, {String? authFallbackName}) {
    final usernameFromDoc = (data['username'] as String?)?.trim();
    final sexRawFromDoc = (data['sex'] as String?)?.trim();
    final fallback = (authFallbackName ?? '').trim();
    final username = (usernameFromDoc?.isNotEmpty == true)
        ? usernameFromDoc
        : (fallback.isNotEmpty ? fallback : null);
    final sex = (sexRawFromDoc == null || sexRawFromDoc.isEmpty)
        ? 'N' // default → treated as female branch
        : sexRawFromDoc.toUpperCase();
    final now = DateTime.now();
    debugPrint('🧬 [Home] Using username="$username" sex="$sex"');
    return _SeedPlan._(
      username: username,
      isFemale: sex == 'F' || sex == 'N',
      today: DateTime(now.year, now.month, now.day),
    );
  }

  final String? username;
  final bool isFemale;

  late final DateTime startDate1, endDate1, startDate2, endDate2, startDate3, endDate3;
  late final List<String> seededExerciseIds;
  late final List<String> candidateIds;
  late final List<String> block2ExerciseIds;
  late final List<String> block3ExerciseIds;

  bool get _named => username != null && username!.isNotEmpty;
  String get block1Name => _named ? "$username's First Block" : '1st Block';
  String get block2Name => _named ? "$username's 2nd Block" : '2nd Block';
  String get block3Name => _named ? "$username's 3rd Block" : '3rd Block';

  /// Lightweight sentinel block payload — no full exercise arrays.
  Map<String, dynamic> buildBlock({
    required String name,
    required bool isActive,
    required DateTime start,
    required DateTime end,
  }) =>
      {
        'name': name,
        'isActive': isActive,
        'createdAt': Timestamp.now(),
        'startDate': Timestamp.fromDate(start),
        'endDate': Timestamp.fromDate(end),
        'selectedDays': ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],
        'allExercisesAvailable': true,
        'excludedExerciseIds': <String>[],
        'templateCandidateExerciseIds': candidateIds,
      };

  // ── Base exercise IDs (shared by both sexes) ─────────────────────────────
  static const _baseExercises = <String>[
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
  static const _maleSpecificExercises = <String>[
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
  static const _femaleSpecificExercises = <String>[
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

  // ── Block 2 adjustments (base = Block 1, then -exclusions +additions) ────
  static const _femaleAdditionsB2 = <String>[];
  static const _maleAdditionsB2 = <String>[];
  static const _femaleExclusionsB2 = <String>[];
  static const _maleExclusionsB2 = <String>[];

  // ── Block 3 adjustments ──────────────────────────────────────────────────
  static const _femaleAdditionsB3 = <String>[
    'I4021icWTx3EAnAe1eHf', // Box Jump Squat
  ];
  static const _maleAdditionsB3 = <String>[
    'EFbQl9i9NdYi13F3DqHr', // Push Up, Suspended
    'Ah9XLjbWvLJOWxb6e1H0', // Triceps Push Down, Unilateral
  ];
  static const _femaleExclusionsB3 = <String>[
    'uY8uJaSFK9czKIX4TLc4', // Machine Chest Press
  ];
  static const _maleExclusionsB3 = <String>[
    'eyh76KELuuO805rZBpMa', // 45 Degree Hip Extension
  ];
}
