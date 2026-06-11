import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'user_context.dart';
import 'block_creation_helper.dart';
import 'block_exercise_defaults_repository.dart';
import 'template_bootstrapper.dart';

/// Extracted new-user bootstrap logic from HomeScreen.
/// All methods are static; no BuildContext dependency.
/// UserContext is passed directly so callers can use it without context after async gaps.
class HomeBootstrapService {
  // ── Block setup ─────────────────────────────────────────────────────────────

  /// Creates the three default 26-week blocks for a brand-new self user.
  /// Skips silently when [uid] != [uc.actorUid] (coach viewing an athlete).
  /// When the user doc is not yet ready (missing sex/username), schedules
  /// a retry in 800 ms and returns — the [runFirstTimeSetup] polling loop
  /// will catch the result once the retry fires.
  static Future<void> ensureBlocksExist({
    required String uid,
    required UserContext uc,
  }) async {
    if (uid.isEmpty) return;

    // Never create blocks for an athlete being coached — only for self users.
    if (uid != uc.actorUid) {
      debugPrint(
        '🛑 [BOOTSTRAP] Block setup skipped — coaching athlete uid=$uid '
        '(actorUid=${uc.actorUid})',
      );
      return;
    }

    final swTotal = Stopwatch()..start();
    final blocksRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks');

    final existingBlocks = await blocksRef.get();

    if (existingBlocks.docs.isEmpty) {
      // ── Fetch username & sex from /users/{uid} ─────────────────────────────
      final usersRef = FirebaseFirestore.instance.collection('users').doc(uid);
      final userSnap = await usersRef.get();
      final data = userSnap.data() ?? {};

      // Gate: wait until /users has core fields (prevents female-default race).
      final hasCore = userSnap.exists &&
          (data['sex'] != null) &&
          (data['username'] != null || data['fullName'] != null);

      if (!hasCore) {
        debugPrint('🛑 [BOOTSTRAP] Block gate: /users/$uid incomplete → retry in 800ms');
        unawaited(Future.delayed(const Duration(milliseconds: 800), () async {
          await HomeBootstrapService.ensureBlocksExist(uid: uid, uc: uc);
        }));
        return;
      }

      debugPrint('🔎 [BOOTSTRAP] /users/$uid exists=${userSnap.exists} keys=${data.keys.toList()}');

      final usernameFromDoc = (data['username'] as String?)?.trim();
      final sexRawFromDoc   = (data['sex'] as String?)?.trim();

      // Fallbacks so the block is named even when the user doc isn't fully ready.
      final auth = FirebaseAuth.instance.currentUser!;
      final fallbackUsername = (auth.displayName?.trim().isNotEmpty == true)
          ? auth.displayName!.trim()
          : (auth.email?.split('@').first ?? '').trim();

      final username = (usernameFromDoc?.isNotEmpty == true)
          ? usernameFromDoc
          : (fallbackUsername.isNotEmpty ? fallbackUsername : null);

      final sex = (sexRawFromDoc == null || sexRawFromDoc.isEmpty)
          ? 'N' // default → treated as female branch
          : sexRawFromDoc.toUpperCase();

      debugPrint('🧬 [BOOTSTRAP] uid=$uid username="$username" sex="$sex"');

      // ── Owner metadata (debug/admin visibility only) ───────────────────────
      final ownerEmail = (() {
        final fromDoc = (data['email'] as String?)?.trim();
        if (fromDoc != null && fromDoc.isNotEmpty) return fromDoc;
        final fromAuth = auth.email?.trim();
        if (fromAuth != null && fromAuth.isNotEmpty) return fromAuth;
        return null;
      })();
      // `username` is already the best-available display name.
      final ownerName = username;

      final isFemale = sex == 'F' || sex == 'N';
      debugPrint('🧬 [BOOTSTRAP] Template branch = ${isFemale ? 'FEMALE' : 'MALE'}');

      // Block names
      final block1Name = (username != null && username.isNotEmpty)
          ? "${username}'s First Block"
          : '1st Block';
      final block2Name = (username != null && username.isNotEmpty)
          ? "${username}'s 2nd Block"
          : '2nd Block';
      final block3Name = (username != null && username.isNotEmpty)
          ? "${username}'s 3rd Block"
          : '3rd Block';

      // ── Dates: start = Monday of the current week ──────────────────────────
      final now   = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final startDate1 = today.subtract(Duration(days: today.weekday - DateTime.monday));
      final endDate1   = startDate1.add(const Duration(days: 181));
      final startDate2 = endDate1.add(const Duration(days: 1));
      final endDate2   = startDate2.add(const Duration(days: 181));
      final startDate3 = endDate2.add(const Duration(days: 1));
      final endDate3   = startDate3.add(const Duration(days: 181));

      debugPrint(
        '📅 [BOOTSTRAP] Block1 start=${startDate1.toIso8601String()} '
        'end=${endDate1.toIso8601String()} (today=${today.toIso8601String()})',
      );

      // ── Base exercise IDs (shared by both sexes) ───────────────────────────
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

      // ── Male-specific exercises ────────────────────────────────────────────
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

      // ── Female-specific exercises ──────────────────────────────────────────
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

      final candidateIds = computeTemplateCandidateIds(isFemale: isFemale);
      debugPrint('✅ [BOOTSTRAP] candidateIds=${candidateIds.length}');

      // ── Block 2 exercise adjustments ────────────────────────────────────────
      const femaleAdditionsB2 = <String>[];
      const maleAdditionsB2   = <String>[];
      const femaleExclusionsB2 = <String>[];
      const maleExclusionsB2   = <String>[];

      final block2ExerciseIds = <String>{
        ...seededExerciseIds.where(
          (id) => !(isFemale ? femaleExclusionsB2 : maleExclusionsB2).contains(id),
        ),
        ...(isFemale ? femaleAdditionsB2 : maleAdditionsB2),
      }.toList(growable: false);

      // ── Block 3 exercise adjustments ────────────────────────────────────────
      const femaleAdditions = <String>[
        'I4021icWTx3EAnAe1eHf', // Box Jump Squat
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

      final block3ExerciseIds = <String>{
        ...seededExerciseIds.where(
          (id) => !(isFemale ? femaleExclusions : maleExclusions).contains(id),
        ),
        ...(isFemale ? femaleAdditions : maleAdditions),
      }.toList(growable: false);

      debugPrint(
        '🧪[B3 pre-add] seed=${seededExerciseIds.length} adj=${block3ExerciseIds.length} '
        'hasAdd(EFbQl9i9NdYi13F3DqHr)=${block3ExerciseIds.contains('EFbQl9i9NdYi13F3DqHr')} '
        'hasEx(eyh76KELuuO805rZBpMa)=${block3ExerciseIds.contains('eyh76KELuuO805rZBpMa')}',
      );

      // ── Block payload builder ──────────────────────────────────────────────
      Map<String, dynamic> buildBlock({
        required String name,
        required bool isActive,
        required DateTime start,
        required DateTime end,
        required List<String> candidateExerciseIds,
        required int blockNumber,
      }) {
        final labelParts = <String>[
          if (ownerEmail != null) ownerEmail,
          if (ownerName != null) ownerName,
          'Block $blockNumber',
        ];
        return {
          'name': name,
          'isActive': isActive,
          'createdAt': Timestamp.now(),
          'startDate': Timestamp.fromDate(start),
          'endDate': Timestamp.fromDate(end),
          'selectedDays': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
          'allExercisesAvailable': true,
          'excludedExerciseIds': <String>[],
          'templateCandidateExerciseIds': candidateExerciseIds,
          'plannedExerciseDetails': {
            'blockMeta': {
              'blockStartDate': start.toIso8601String(),
              'blockEndDate': end.toIso8601String(),
              'selectedDays': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
            }
          },
          // Admin/debug fields — not read by app logic.
          'ownerUid': uid,
          if (ownerEmail != null) 'ownerEmail': ownerEmail,
          if (ownerName != null) 'ownerName': ownerName,
          'blockNumber': blockNumber,
          'debugLabel': labelParts.join(' · '),
        };
      }

      // ── Create Block 1 (active) ────────────────────────────────────────────
      final block1Payload = buildBlock(
        name: block1Name,
        isActive: true,
        start: startDate1,
        end: endDate1,
        candidateExerciseIds: candidateIds,
        blockNumber: 1,
      );

      final swCreate1 = Stopwatch()..start();
      final block1Ref = await blocksRef.add(block1Payload);
      swCreate1.stop();
      final block1Id = block1Ref.id;
      debugPrint('✅ [BOOTSTRAP] Block 1 created id=$block1Id (${swCreate1.elapsed.inMilliseconds} ms)');

      uc.applyBlockMeta(
        uid: uid,
        activeBlockId: block1Id,
        startDate: startDate1,
        endDate: endDate1,
      );

      await BlockExerciseDefaultsRepository.seedDefaultsForBlock(
        uid: uid,
        blockId: block1Id,
        exerciseIds: seededExerciseIds,
      );

      // Pointer write: current_block → Block 1
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
            'selectedDays': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
          }
        },
        'blockMeta': {
          'blockStartDate': startDate1.toIso8601String(),
          'blockEndDate': endDate1.toIso8601String(),
        },
      }, SetOptions(merge: true));
      swPtr.stop();
      debugPrint(
        '📌 [BOOTSTRAP] Set current_block pointer → $block1Id (${swPtr.elapsed.inMilliseconds} ms)',
      );

      // Eagerly write week_0 (1 week doc + 7 day docs) so WES2/BB3 can read
      // the current week immediately without waiting for the full scaffold.
      {
        const months = [
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
        ];
        const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        final week0Ref = block1Ref.collection('weeks').doc('week_0');
        final eagerBatch = FirebaseFirestore.instance.batch();
        eagerBatch.set(week0Ref, {'exists': true}, SetOptions(merge: true));
        for (int day = 0; day < 7; day++) {
          final date = startDate1.add(Duration(days: day));
          eagerBatch.set(week0Ref.collection('days').doc('day_$day'), {
            'date': Timestamp.fromDate(date),
            'circuitStartIndices': [0],
            'exercises': [],
            'workoutName':
                '${weekdays[day]} ${date.day} ${months[date.month - 1]} - Week 1',
            'exists': true,
          }, SetOptions(merge: true));
        }
        await eagerBatch.commit();
        debugPrint('🧱 [BOOTSTRAP] Block 1 week_0 ready (eager)');
      }
      // Defer weeks 1–25 for Block 1 to background (already usable via week_0).
      unawaited(scaffoldBlockInBackground(block1Ref, startDate1, startWeek: 1));

      // ── Create Block 2 (upcoming, not active) ────────────────────────────
      final block2Payload = buildBlock(
        name: block2Name,
        isActive: false,
        start: startDate2,
        end: endDate2,
        candidateExerciseIds: candidateIds,
        blockNumber: 2,
      );

      final swCreate2 = Stopwatch()..start();
      final block2Ref = await blocksRef.add(block2Payload);
      swCreate2.stop();
      final block2Id = block2Ref.id;
      debugPrint('✅ [BOOTSTRAP] Block 2 created id=$block2Id (${swCreate2.elapsed.inMilliseconds} ms)');

      unawaited(() async {
        try {
          await BlockExerciseDefaultsRepository.seedDefaultsForBlock(
            uid: uid,
            blockId: block2Id,
            exerciseIds: block2ExerciseIds,
          );
          await scaffoldBlockInBackground(block2Ref, startDate2);
        } catch (e, st) {
          debugPrint('❌ [BOOTSTRAP] Block 2 background init failed: $e\n$st');
        }
      }());

      // ── Create Block 3 (upcoming, not active) ────────────────────────────
      final block3Payload = buildBlock(
        name: block3Name,
        isActive: false,
        start: startDate3,
        end: endDate3,
        candidateExerciseIds: candidateIds,
        blockNumber: 3,
      );

      final swCreate3 = Stopwatch()..start();
      final block3Ref = await blocksRef.add(block3Payload);
      swCreate3.stop();
      final block3Id = block3Ref.id;
      debugPrint('✅ [BOOTSTRAP] Block 3 created id=$block3Id (${swCreate3.elapsed.inMilliseconds} ms)');

      // Merge allBlocks summary into current_block (admin visibility only).
      unawaited(FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('block_planner')
          .doc('current_block')
          .set({
        'allBlocks': [
          {
            'blockId': block1Id,
            'blockName': block1Name,
            'blockNumber': 1,
            'isActive': true,
            'startDateIso': startDate1.toIso8601String(),
            'endDateIso': endDate1.toIso8601String(),
          },
          {
            'blockId': block2Id,
            'blockName': block2Name,
            'blockNumber': 2,
            'isActive': false,
            'startDateIso': startDate2.toIso8601String(),
            'endDateIso': endDate2.toIso8601String(),
          },
          {
            'blockId': block3Id,
            'blockName': block3Name,
            'blockNumber': 3,
            'isActive': false,
            'startDateIso': startDate3.toIso8601String(),
            'endDateIso': endDate3.toIso8601String(),
          },
        ],
      }, SetOptions(merge: true)));

      unawaited(() async {
        try {
          await BlockExerciseDefaultsRepository.seedDefaultsForBlock(
            uid: uid,
            blockId: block3Id,
            exerciseIds: block3ExerciseIds,
          );
          await scaffoldBlockInBackground(block3Ref, startDate3);
        } catch (e, st) {
          debugPrint('❌ [BOOTSTRAP] Block 3 background init failed: $e\n$st');
        }
      }());
    }

    swTotal.stop();
    debugPrint(
      '⏱️ [BOOTSTRAP] ensureBlocksExist total: ${swTotal.elapsed.inMilliseconds} ms',
    );
  }

  /// Runs first-time setup for a brand-new user: creates blocks, waits for
  /// block meta to propagate into [uc], then server-confirms the meta.
  /// Progress strings are delivered via [onStatus] so the widget can setState.
  /// Returns true when [uc.activeBlockId] is non-null/non-empty on completion.
  static Future<bool> runFirstTimeSetup({
    required String uid,
    required UserContext uc,
    void Function(String)? onStatus,
  }) async {
    debugPrint('🏠 [BOOTSTRAP] runFirstTimeSetup uid=$uid');

    onStatus?.call(
      'Profile locked in\n'
      'Your training preferences are saved. Building your program based on your preferences...',
    );

    await ensureBlocksExist(uid: uid, uc: uc);

    // If user doc wasn't ready (hasCore=false), ensureBlocksExist returned early
    // and scheduled its own retry. Poll until applyBlockMeta fires.
    if (uc.activeBlockId == null) {
      debugPrint('🏠 [BOOTSTRAP] user doc not ready — waiting for retry...');
      for (int i = 0; i < 30 && uc.activeBlockId == null; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    onStatus?.call(
      'Training structure built\n'
      'Your first block is built. Finalising your exercise settings...',
    );

    // Server-confirm block meta so WES has accurate context from the start.
    await uc.refreshBlockMetaFromServer(uid: uid);

    onStatus?.call(
      'Ready to train\n'
      "GoodLift is ready. Let's start training with purpose 💪",
    );
    await Future.delayed(const Duration(milliseconds: 1500));

    final ready = uc.activeBlockId != null && uc.activeBlockId!.isNotEmpty;
    debugPrint('🏠 [BOOTSTRAP] runFirstTimeSetup complete blockReady=$ready');
    return ready;
  }

  // ── Active-block listener ──────────────────────────────────────────────────

  /// Subscribes to active-block changes for [uid].
  /// Calls [onChange] on every snapshot so the caller can refresh calendar data.
  /// Returns the subscription; the caller must cancel it in dispose.
  static StreamSubscription<QuerySnapshot<Map<String, dynamic>>>
      setupActiveBlockListener({
    required String uid,
    required void Function() onChange,
  }) {
    final sub = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .listen((_) => onChange());
    debugPrint('🏠 [BOOTSTRAP] block listener subscribed uid=$uid');
    return sub;
  }

  // ── RIR heal ──────────────────────────────────────────────────────────────

  /// Heals the RIR plan for the active block. Fire-and-forget; errors suppressed.
  static Future<void> healRirPlan({
    required String uid,
    required String blockId,
  }) async {
    try {
      await BlockExerciseDefaultsRepository.healActiveBlockRirPlan(
        uid: uid,
        blockId: blockId,
      );
    } catch (_) {}
  }

  // ── Template bootstrap ────────────────────────────────────────────────────

  /// Attaches gated Firestore listeners that fire [TemplatesBootstrapper] once
  /// both the user core fields and the fitness-onboarding doc are present.
  /// Listeners are self-cancelling after first success — same pattern as v1.
  /// Only started when [actingUid] == the logged-in auth user (not for coached athletes).
  static void startTemplateBootstrap(String actingUid) {
    if (actingUid.isEmpty) return;
    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser == null || authUser.uid != actingUid) {
      debugPrint('🛑 [BOOTSTRAP] Skipping template bootstrap (auth unstable or coaching)');
      return;
    }

    final usersRef = FirebaseFirestore.instance.collection('users').doc(actingUid);
    final onboardRef = FirebaseFirestore.instance
        .collection('users')
        .doc(actingUid)
        .collection('profile')
        .doc('fitness_onboarding');

    bool fired = false;

    Future<void> maybeRun() async {
      if (fired) return;
      try {
        fired = true;
        await TemplatesBootstrapper.ensureInitialTemplatesForUser(actingUid);
        debugPrint('🧰 [BOOTSTRAP] Template bootstrap complete for $actingUid');
      } catch (e, st) {
        debugPrint('🧰 [BOOTSTRAP] Template bootstrap threw: $e\n$st');
        fired = false; // allow retry on transient failure
      }
    }

    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? userSub;
    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? onboardSub;

    userSub = usersRef.snapshots().listen(
      (u) async {
        if (!u.exists) return;
        final d = u.data();
        final hasCore = d != null &&
            d['sex'] != null &&
            d['dob'] != null &&
            d['username'] != null;
        if (!hasCore) return;
        final oSnap = await onboardRef.get();
        final onboardingReady = oSnap.exists && (oSnap.data()?.isNotEmpty ?? false);
        if (onboardingReady) {
          await maybeRun();
          await userSub?.cancel();
        }
      },
      onError: (Object e) async {
        debugPrint('🟥 [BOOTSTRAP] usersRef.snapshots denied: $e');
        try { await userSub?.cancel(); } catch (_) {}
      },
    );

    onboardSub = onboardRef.snapshots().listen(
      (o) async {
        if (!o.exists || (o.data()?.isNotEmpty != true)) return;
        final u = await usersRef.get();
        final d = u.data();
        final hasCore = u.exists &&
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
      onError: (Object e) async {
        debugPrint('🟥 [BOOTSTRAP] onboardRef.snapshots denied: $e');
        try { await onboardSub?.cancel(); } catch (_) {}
      },
    );
  }

  // ── Owner-metadata backfill ───────────────────────────────────────────────

  /// Backfills admin/debug fields ([ownerUid], [ownerEmail], [ownerName],
  /// [blockNumber], [debugLabel]) onto existing block documents that are
  /// missing [ownerUid].  Skips the write entirely when all blocks already
  /// carry the metadata.  Safe to call repeatedly — idempotent.
  static Future<void> backfillOwnerMetadata(String uid) async {
    if (uid.isEmpty) return;

    final blocksRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks');

    final snap = await blocksRef.get();
    if (snap.docs.isEmpty) return;

    // Fast-path: nothing to do if all blocks already have ownerUid.
    if (snap.docs.every((d) => d.data()['ownerUid'] != null)) {
      debugPrint('🔧 [BOOTSTRAP.backfill] all blocks already have ownerUid — skipping');
      return;
    }

    // Fetch user doc for the richest available metadata.
    final userSnap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final data = userSnap.data() ?? {};
    final auth = FirebaseAuth.instance.currentUser;

    final ownerEmail = (() {
      final fromDoc = (data['email'] as String?)?.trim();
      if (fromDoc != null && fromDoc.isNotEmpty) return fromDoc;
      final fromAuth = auth?.email?.trim();
      if (fromAuth != null && fromAuth.isNotEmpty) return fromAuth;
      return null;
    })();

    final ownerName = (() {
      for (final key in ['username', 'fullName', 'displayName']) {
        final v = (data[key] as String?)?.trim();
        if (v != null && v.isNotEmpty) return v;
      }
      final fromAuth = auth?.displayName?.trim();
      if (fromAuth != null && fromAuth.isNotEmpty) return fromAuth;
      return null;
    })();

    // Sort by startDate so blockNumber is chronologically assigned.
    final sorted = snap.docs.toList()
      ..sort((a, b) {
        final aTs = a.data()['startDate'];
        final bTs = b.data()['startDate'];
        final aDate = aTs is Timestamp ? aTs.toDate() : DateTime(0);
        final bDate = bTs is Timestamp ? bTs.toDate() : DateTime(0);
        return aDate.compareTo(bDate);
      });

    final batch = FirebaseFirestore.instance.batch();

    for (int i = 0; i < sorted.length; i++) {
      final doc = sorted[i];
      final blockNumber = i + 1;
      final labelParts = <String>[
        if (ownerEmail != null) ownerEmail,
        if (ownerName != null) ownerName,
        'Block $blockNumber',
      ];
      batch.update(doc.reference, {
        'ownerUid': uid,
        if (ownerEmail != null) 'ownerEmail': ownerEmail,
        if (ownerName != null) 'ownerName': ownerName,
        'blockNumber': blockNumber,
        'debugLabel': labelParts.join(' · '),
      });
    }

    await batch.commit();
    debugPrint(
      '🔧 [BOOTSTRAP.backfill] wrote metadata to ${sorted.length} blocks for uid=$uid',
    );
  }
}
