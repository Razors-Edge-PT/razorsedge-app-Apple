import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'user_context.dart';
import 'Block_Planner.dart';
import 'package:provider/provider.dart';
import 'block_repository.dart';
import 'block_planner_repository.dart';
import 'dart:async';
import 'block_exercise_defaults_repository.dart';




class PlannedBlocksScreen extends StatefulWidget {
  const PlannedBlocksScreen({super.key});

  @override
  State<PlannedBlocksScreen> createState() => _PlannedBlocksScreenState();
}

class _PlannedBlocksScreenState extends State<PlannedBlocksScreen> {
  String get userId => UserContext.of(context, listen: false).currentUid;

  bool _isSeedingDefaults = false;
  String? _seedStatus; // optional UI text




  Future<void> _setBlockAsActive(String blockId) async {
    final blocksRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks');

    // load the block you want to activate
    final newActiveSnap = await blocksRef.doc(blockId).get();
    final newName = (newActiveSnap.data()?['name'] as String?) ?? 'Unnamed Block';

    // find any other active ones
    final activeQuery = await blocksRef.where('isActive', isEqualTo: true).get();
    final others = activeQuery.docs.where((d) => d.id != blockId).toList();

    if (others.isNotEmpty) {
      final oldName = (others.first.data()['name'] as String?) ?? 'Unnamed Block';
      final shouldOverride = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Override Active Block?'),
          content: Text(
              '“$oldName” is currently active.\n\n'
                  'Activate “$newName” instead?'
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
            TextButton(onPressed: () => Navigator.pop(ctx, true),  child: const Text('Yes')),
          ],
        ),
      );
      if (shouldOverride != true) return;

      // batch‐deactivate the old one(s)
      final batch = FirebaseFirestore.instance.batch();
      for (final doc in others) {
        batch.update(doc.reference, {'isActive': false});
      }
      await batch.commit();
    }

    // now activate the new one
    await blocksRef.doc(blockId).update({'isActive': true});
    setState(() { /* so your UI re‐reads the stream */ });
  }

  Future<void> _deleteBlock(String blockId) async {
    await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(blockId)
        .delete();
  }

  void _createNewBlock() {
    Navigator.pushNamed(
      context,
      '/block_builder',
      arguments: {'newBlock': true}, // ✅ prevents draft from loading
    );
  }

  void _editBlock(String blockId, [String? blockName]) {
    final userContext = UserContext.of(context, listen: false);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider<UserContext>.value(
          value: userContext,
          child: const Block_Planner(),
        ),
        settings: RouteSettings(arguments: {
          'blockId': blockId,
          if (blockName != null) 'blockName': blockName, // ✅ only include if provided
        }),
      ),
    );
  }

  Future<void> _ensureAtLeastOneBlockExistsFromPlannedBlocks() async {
    if (_isSeedingDefaults) return;

    setState(() {
      _isSeedingDefaults = true;
      _seedStatus = 'Creating default blocks…';
    });

    try {
      final swTotal = Stopwatch()..start();

      // ✅ IMPORTANT: use selected/acting uid, not FirebaseAuth uid
      final uid = userId;

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
          // tiny, non-blocking retry; won’t slow first paint
          unawaited(Future.delayed(const Duration(milliseconds: 800), () async {
            await _ensureAtLeastOneBlockExistsFromPlannedBlocks();

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

        // 8 weeks = 56 days total. If start is day 0, last day is start + 55.
        final endDate1 = startDate1.add(const Duration(days: 55));

        // Next blocks start the day after the previous ends
        final startDate2 = endDate1.add(const Duration(days: 1));
        final endDate2   = startDate2.add(const Duration(days: 55));

        final startDate3 = endDate2.add(const Duration(days: 1));
        final endDate3   = startDate3.add(const Duration(days: 55));

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



        // Helper to build a block payload
        Map<String, dynamic> buildBlock({
          required String name,
          required bool isActive,
          required DateTime start,
          required DateTime end,
          required List<String> exerciseIds,
        }) {
          return {
            'name': name,
            'isActive': isActive,
            'createdAt': Timestamp.now(),
            'startDate': Timestamp.fromDate(start),
            'endDate': Timestamp.fromDate(end),
            'selectedDays': ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],
            'exercises': exerciseIds,
            'plannedExercises': exerciseIds,
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
          exerciseIds: seededExerciseIds,
        );

        final swCreate1 = Stopwatch()..start();
        final block1Ref = await blocksRef.add(block1Payload);
        swCreate1.stop();
        final block1Id = block1Ref.id;
        print('✅ [Home] Block 1 created id=$block1Id (${swCreate1.elapsed.inMilliseconds} ms)');

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
          'plannedExercises': seededExerciseIds,
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

        // Scaffold weeks & days for Block 1
        final swScaffold1 = Stopwatch()..start();
        {
          final batch = FirebaseFirestore.instance.batch();
          for (int week = 0; week < 8; week++) {
            final weekRef = block1Ref.collection('weeks').doc('week_$week');
            batch.set(weekRef, {'exists': true}, SetOptions(merge: true));

            final daysRef = weekRef.collection('days');
            for (int day = 0; day < 7; day++) {
              final currentDate = startDate1.add(Duration(days: week * 7 + day));
              final weekday = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][day];
              final monthName = [
                'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
              ][currentDate.month - 1];

              final dayRef = daysRef.doc('day_$day');
              batch.set(dayRef, {
                'date': Timestamp.fromDate(currentDate),
                'circuitStartIndices': [0],
                'exercises': [],
                'workoutName': '$weekday ${currentDate.day} $monthName - Week ${week + 1}',
                'exists': true,
              }, SetOptions(merge: true));
            }
          }
          batch.set(block1Ref, {'scaffoldReady': true}, SetOptions(merge: true));
          await batch.commit();
        }
        swScaffold1.stop();
        print('🧱 [Home] Block 1 scaffold ready (${swScaffold1.elapsed.inMilliseconds} ms)');

        // ── Create Block 2 (upcoming, not active) ───────────────────────────────
        final block2Payload = buildBlock(
          name: block2Name,
          isActive: false, // keep only 1 active block
          start: startDate2,
          end: endDate2,
          exerciseIds: block2ExerciseIds, // ✅ now uses sex-specific adjusted list
        );

        final swCreate2 = Stopwatch()..start();
        final block2Ref = await blocksRef.add(block2Payload);
        swCreate2.stop();
        final block2Id = block2Ref.id;
        print('✅ [Home] Block 2 created id=$block2Id (${swCreate2.elapsed.inMilliseconds} ms)');

        await BlockExerciseDefaultsRepository.seedDefaultsForBlock(
          uid: uid,
          blockId: block2Id,
          exerciseIds: block2ExerciseIds,
        );


        // Scaffold weeks & days for Block 2
        final swScaffold2 = Stopwatch()..start();
        {
          final batch = FirebaseFirestore.instance.batch();
          for (int week = 0; week < 8; week++) {
            final weekRef = block2Ref.collection('weeks').doc('week_$week');
            batch.set(weekRef, {'exists': true}, SetOptions(merge: true));

            final daysRef = weekRef.collection('days');
            for (int day = 0; day < 7; day++) {
              final currentDate = startDate2.add(Duration(days: week * 7 + day));
              final weekday = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][day];
              final monthName = [
                'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
              ][currentDate.month - 1];

              final dayRef = daysRef.doc('day_$day');
              batch.set(dayRef, {
                'date': Timestamp.fromDate(currentDate),
                'circuitStartIndices': [0],
                'exercises': [],
                'workoutName': '$weekday ${currentDate.day} $monthName - Week ${week + 1}',
                'exists': true,
              }, SetOptions(merge: true));
            }
          }
          batch.set(block2Ref, {'scaffoldReady': true}, SetOptions(merge: true));
          await batch.commit();
        }
        swScaffold2.stop();
        print('🧱 [Home] Block 2 scaffold ready (${swScaffold2.elapsed.inMilliseconds} ms)');

        debugPrint('🧪[B3 pre-add] seed=${seededExerciseIds.length} adj=${block3ExerciseIds.length} '
            'hasAdd(EFbQl9i9NdYi13F3DqHr)=${block3ExerciseIds.contains('EFbQl9i9NdYi13F3DqHr')} '
            'hasEx(eyh76KELuuO805rZBpMa)=${block3ExerciseIds.contains('eyh76KELuuO805rZBpMa')}');

        // ── Create Block 3 (upcoming, not active) ─────────────────────────────────────
        final block3Name = (username != null && username.isNotEmpty)
            ? "${username}'s 3rd Block"
            : "3rd Block";

        final block3Payload = buildBlock(
          name: block3Name,
          isActive: false, // keep only 1 active block
          start: startDate3,
          end: endDate3,
          exerciseIds: block3ExerciseIds,
        );

        final swCreate3 = Stopwatch()..start();
        final block3Ref = await blocksRef.add(block3Payload);
        final _savedB3 = await block3Ref.get();
        final _savedPlanned = List<String>.from((_savedB3.data() ?? const {})['plannedExercises'] ?? const <String>[]);
        debugPrint('🔎[B3 saved] planned=${_savedPlanned.length} '
            'hasAdd(EFbQl9i9NdYi13F3DqHr)=${_savedPlanned.contains('EFbQl9i9NdYi13F3DqHr')} '
            'hasEx(eyh76KELuuO805rZBpMa)=${_savedPlanned.contains('eyh76KELuuO805rZBpMa')}');

        swCreate3.stop();
        final block3Id = block3Ref.id;
        print('✅ [Home] Block 3 created id=$block3Id (${swCreate3.elapsed.inMilliseconds} ms)');

        await BlockExerciseDefaultsRepository.seedDefaultsForBlock(
          uid: uid,
          blockId: block3Id,
          exerciseIds: block3ExerciseIds,
        );


// Scaffold weeks & days for Block 3
        final swScaffold3 = Stopwatch()..start();
        {
          final batch = FirebaseFirestore.instance.batch();
          for (int week = 0; week < 8; week++) {
            final weekRef = block3Ref.collection('weeks').doc('week_$week');
            batch.set(weekRef, {'exists': true}, SetOptions(merge: true));

            final daysRef = weekRef.collection('days');
            for (int day = 0; day < 7; day++) {
              final currentDate = startDate3.add(Duration(days: week * 7 + day));
              final weekday = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][day];
              final monthName = [
                'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
              ][currentDate.month - 1];

              final dayRef = daysRef.doc('day_$day');
              batch.set(dayRef, {
                'date': Timestamp.fromDate(currentDate),
                'circuitStartIndices': [0],
                'exercises': [],
                'workoutName': '$weekday ${currentDate.day} $monthName - Week ${week + 1}',
                'exists': true,
              }, SetOptions(merge: true));
            }
          }
          batch.set(block3Ref, {'scaffoldReady': true}, SetOptions(merge: true));
          await batch.commit();
        }
        swScaffold3.stop();
        print('🧱 [Home] Block 3 scaffold ready (${swScaffold3.elapsed.inMilliseconds} ms)');

      }

      swTotal.stop();
      debugPrint('⏱️ [PlannedBlocks] ensure defaults total: ${swTotal.elapsed.inMilliseconds} ms');

      if (mounted) {
        setState(() => _seedStatus = 'Done.');
      }
    } catch (e) {
      debugPrint('❌ [PlannedBlocks] seed defaults failed: $e');
      if (mounted) {
        setState(() => _seedStatus = 'Failed: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isSeedingDefaults = false);
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    final blocksRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks');

    return Scaffold(
      appBar: AppBar(title: const Text('Planned Blocks')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNewBlock,
        icon: const Icon(Icons.add),
        label: const Text('New Block'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: blocksRef.orderBy('createdAt', descending: true).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final rawDocs = snapshot.data!.docs;

          if (rawDocs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('No planned blocks yet.'),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _createNewBlock,
                    icon: const Icon(Icons.add),
                    label: const Text('Create Block'),
                  ),
                  const SizedBox(height: 12),

                  ElevatedButton.icon(
                    onPressed: _isSeedingDefaults ? null : () async {
                      await _ensureAtLeastOneBlockExistsFromPlannedBlocks();
                    },
                    icon: const Icon(Icons.auto_fix_high),
                    label: Text(_isSeedingDefaults ? 'Creating…' : 'Create default blocks?'),
                  ),
                  if (_seedStatus != null) ...[
                    const SizedBox(height: 8),
                    Text(_seedStatus!, style: const TextStyle(fontSize: 12)),
                  ],


                ],

              ),
            );
          }

          final blocks = rawDocs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            data['id'] = doc.id;
            return data;
          }).toList();

          // ✅ Sort active blocks first
          blocks.sort((a, b) {
            final aActive = a['isActive'] == true;
            final bActive = b['isActive'] == true;
            return (bActive ? 1 : 0).compareTo(aActive ? 1 : 0);
          });

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: blocks.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final block = blocks[index];
              final blockId = block['id'];

              final blockName = block['name'] ?? 'Untitled Block';

              final isActive = block['isActive'] ?? false;

              String dateRange = 'No dates';
              try {
                final start = (block['startDate'] as Timestamp).toDate();
                final end = (block['endDate'] as Timestamp).toDate();
                dateRange =
                    '${DateFormat('dd MMM').format(start)} → ${DateFormat('dd MMM yyyy').format(end)}';
              } catch (_) {}

              final exercises = (block['exercises'] as List?)?.length ?? 0;

              return Card(
                elevation: 3,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  onTap: () => _editBlock(blockId, blockName),

                  title: Text(
                    blockName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(dateRange),
                      if (exercises > 0)
                        Text('$exercises exercises',
                            style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                  leading: CircleAvatar(
                    backgroundColor: isActive ? Colors.green : Colors.grey[300],
                    child: Icon(
                      isActive ? Icons.check : Icons.fitness_center,
                      color: Colors.white,
                    ),
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) async {
                      if (value == 'activate') {
                        await _setBlockAsActive(blockId);
                      } else if (value == 'delete') {
                        await _deleteBlock(blockId);
                      }
                    },
                    itemBuilder: (context) => [
                      if (!isActive)
                        const PopupMenuItem(
                          value: 'activate',
                          child: Text('Set Active'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete'),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
