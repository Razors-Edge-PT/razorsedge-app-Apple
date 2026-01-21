import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'auto_circuit_planner.dart';
import'template_generator.dart';

class TemplatesBootstrapper {
  static const _flagField = 'templatesBootstrapped_v1';

  /// Returns the active blockId and a startDate-ordered list of all upcoming (non-active) blockIds.
  static Future<({String? activeId, List<String> upcomingIds})> _resolveOrderedBlockIds(String uid) async {
    final blocksCol = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks');

    final snap = await blocksCol.get();
    if (snap.docs.isEmpty) {
      debugPrint('🧱 [TB] no blocks found!');
      return (activeId: null, upcomingIds: const <String>[]);

    }

    final all = snap.docs.map((d) {
      final data = d.data();
      final isActive = data['isActive'] == true;
      final start = (data['startDate'] is Timestamp)
          ? (data['startDate'] as Timestamp).toDate()
          : null;
      return {'id': d.id, 'isActive': isActive, 'start': start};
    }).toList();

    final active = all.firstWhere((b) => b['isActive'] == true, orElse: () => {});
    final activeId = active.isEmpty ? null : active['id'] as String?;

    final upcoming = all
        .where((b) => b['isActive'] != true)
        .toList()
      ..sort((a, b) {
        final as = a['start'] as DateTime?;
        final bs = b['start'] as DateTime?;
        if (as == null && bs == null) return 0;
        if (as == null) return 1;  // nulls last
        if (bs == null) return -1;
        return as.compareTo(bs);   // earliest first
      });

    final upcomingIds = upcoming.map((b) => b['id'] as String).toList();

    debugPrint('🧰 [TB] ordered blocks → active=$activeId upcoming=$upcomingIds');
    return (activeId: activeId, upcomingIds: upcomingIds);
  }



  /// Debug utility: lists all blocks for a given user
  static Future<void> debugPrintAllBlocks(String uid) async {
    final blocksCol = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks');

    final snap = await blocksCol.get();

    if (snap.docs.isEmpty) {
      debugPrint('🧱 [TB] No blocks found for uid=$uid');
      return;
    }

    debugPrint('📋 [TB] ====== BLOCK LIST for $uid ======');
    for (final doc in snap.docs) {
      final data = doc.data();
      final id = doc.id;
      final isActive = data['isActive'] == true;
      final start = (data['startDate'] is Timestamp)
          ? (data['startDate'] as Timestamp).toDate()
          : null;
      final end = (data['endDate'] is Timestamp)
          ? (data['endDate'] as Timestamp).toDate()
          : null;
      debugPrint('🧩 id=$id | active=$isActive | start=$start | end=$end');
    }
    debugPrint('📋 [TB] ==================================');
  }


  static Future<void> ensureInitialTemplatesForUser(String? uid, {bool force = false, bool plannedOnly = true}) async {


    debugPrint('🧰 [TB] ensureInitialTemplatesForUser() called uid="$uid"');
    debugPrint('🧰 [TB] plannedOnly=$plannedOnly');

    if (uid == null || uid.isEmpty) {
      debugPrint('🧰 [TB] abort: uid is null/empty');
      return;
    }

    final users = FirebaseFirestore.instance.collection('users');
    final userRef = users.doc(uid);

    // Read user doc + flag
    final userSnap = await userRef.get();
    debugPrint('🧩 [TB] user exists=${userSnap.exists}');
    debugPrint('🧩 [TB] user data keys=${userSnap.data()?.keys.toList()}');

    final flag = userSnap.data()?[_flagField] == true;
    debugPrint('🧰 [TB] userDoc exists=${userSnap.exists} flag=$_flagField=$flag');

    if (!force && userSnap.exists && flag) {
      debugPrint('🧰 [TB] early-exit: bootstrap flag already set → skipping');
      return;
    }


    // ---- Demographic parse (sex + dob → age) --------------------------------
    final sexRaw = userSnap.data()?['sex'] as String?;
    final sex = sexRaw?.trim();
    DateTime? dob;
    final dobRaw = userSnap.data()?['dob'];
    if (dobRaw is String) {
      final parts = dobRaw.split(RegExp(r'[-/]'));
      if (parts.length == 3) {
        final d = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        final y = int.tryParse(parts[2]);
        if (d != null && m != null && y != null) {
          dob = DateTime(y, m, d);
          debugPrint('🧰 [TB] dob parsed as DMY → $dob (raw="$dobRaw")');
        } else {
          debugPrint('🧰 [TB] dob DMY parse failed for raw="$dobRaw"');
        }
      } else {
        try {
          dob = DateTime.parse(dobRaw);
          debugPrint('🧰 [TB] dob parsed via DateTime.parse → $dob (raw="$dobRaw")');
        } catch (_) {
          debugPrint('🧰 [TB] dob parse failed via DateTime.parse for raw="$dobRaw"');
        }
      }
    } else {
      debugPrint('🧰 [TB] dob missing or not a String (raw=$dobRaw)');
    }

    final now = DateTime.now();
    int? age;
    if (dob != null) {
      age = now.year - dob.year - ((now.month < dob.month || (now.month == dob.month && now.day < dob.day)) ? 1 : 0);
    }
    final sexU = sex?.toUpperCase();
    debugPrint('🧰 [TB] demographics: sex="$sexU" age=$age');

    // Branch eligibility (legacy fallbacks still use this)
    // 👩‍🦰 / 👩 / 🤷 Female (F) or Non-binary (N)
    final isFemale = (sexU == 'F' || sexU == 'N');

// 👨 Male
    final isMale   = (sexU == 'M');

// 👩‍🦰 FEMALE: teens → 30 (legacy supported group)
    final femaleEligible =
        isFemale && age != null && age >= 13 && age <= 30;

// 👩‍🦰 FEMALE: 31+ (NEW – allow template generation instead of exiting)
    final female30plus =
        isFemale && age != null && age >= 31;

// 👨 MALE: 16 → 26 (younger male program)
    final male16to26 =
        isMale && age != null && age >= 16 && age <= 26;

// 👨 MALE: 27 → 39 (standard adult male program)
    final male27to39 =
        isMale && age != null && age >= 27 && age <= 39;

// 👨 MALE: 40+ (NEW – treated same as 27–39 for now)
    final male40plus =
        isMale && age != null && age >= 40;


    debugPrint(
        '🧰 [TB] eval '
            'female13to30=$femaleEligible, '
            'female30plus=$female30plus, '
            'male16to26=$male16to26, '
            'male27to39=$male27to39, '
            'male40plus=$male40plus'
    );


    if (
    !femaleEligible &&   // 👩‍🦰 13–30
        !female30plus &&     // 👩‍🦰 31+
        !male16to26 &&       // 👨 16–26
        !male27to39 &&       // 👨 27–39
        !male40plus          // 👨 40+
    ) {

      debugPrint('🧰 [TB] not eligible for any branch → set flag and exit');
      await userRef.set(
        {_flagField: true, 'templatesBootstrappedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
      return;
    }

    final templatesCol = userRef.collection('templates');
    final ordered = await _resolveOrderedBlockIds(uid);
    final String? activeBlockId = ordered.activeId;
    final List<String> upcomingIds = ordered.upcomingIds;
    debugPrint('🧰 [TB] ordered → active=$activeBlockId upcoming=${upcomingIds.join(', ')}');

    // For visibility: how many currently exist
    try {
      final existing = await templatesCol.limit(5).get();
      debugPrint('🧰 [TB] existing templates found=${existing.size}');
      if (!force && existing.size > 0) {
        debugPrint('🧰 [TB] templates already exist → set flag & exit');
        await userRef.set(
          {_flagField: true, 'templatesBootstrappedAt': FieldValue.serverTimestamp()},
          SetOptions(merge: true),
        );
        return;
      }

    } catch (e, st) {
      debugPrint('🧰 [TB] warn: failed to count existing templates: $e\n$st');
    }

    // ──────────────────────────────────────────────────────────────────────────
    // NEW: Try generator path using onboarding data. If successful, write and return.
    // ──────────────────────────────────────────────────────────────────────────
    try {
      final onbSnap = await userRef.collection('profile').doc('fitness_onboarding').get();
      final onb = onbSnap.data();

      // Minimal validity: have either frequency or any body-focus info.
      final hasUsefulOnb = onbSnap.exists && onb != null && (
          onb.containsKey('weeklyFrequency') ||
              onb.containsKey('minTrainingDaysPerWeek') ||
              onb.containsKey('bodyFocusLevel') ||
              onb.containsKey('bodyFocusChildren') ||
              onb.containsKey('experience') ||
              onb.containsKey('environment') ||
              onb.containsKey('equipment')
      );

      if (hasUsefulOnb) {
        debugPrint('🧰 [GEN] onboarding found → attempting generator path');

        // NOTE: implement this class elsewhere (as we discussed).
        // It must return a List<Map<String,dynamic>> with entries like:
        // { 'name': 'B1 Day 1', 'exercises': [ {exerciseId,name,circuitIndex}, ... ] }
        final List<Map<String, dynamic>> genPayloads =
        await TemplateGenerator.generateFromOnboarding(
          uid: uid,
          sexU: sexU,
          age: age,
          onboarding: onb,
          plannedOnly: plannedOnly, // 🧩 propagate toggle
        );


        if (genPayloads.isNotEmpty) {
          const branchLabel = 'GEN_V1';

          // Write exactly like your legacy path does, including name→blockId routing.
          final batch = FirebaseFirestore.instance.batch();

          for (final t in genPayloads) {
            final exercises = (t['exercises'] as List).cast<Map<String, dynamic>>();
            final filtered = <Map<String, dynamic>>[];
            for (final ex in exercises) {
              final exId = (ex['exerciseId'] as String?)?.trim();
              final exName = (ex['name'] as String?) ?? '(unnamed)';
              if (exId == null || exId.isEmpty) {
                debugPrint('🟥 [GEN] skipping exercise without ID → "$exName" in template "${t['name']}"');
                continue;
              }
              filtered.add(ex);
            }

            if (filtered.isEmpty) {
              debugPrint('🟨 [GEN] template "${t['name']}" has no valid exercises after filtering → skipping create');
              continue;
            }

            final toWrite = {
              'name': t['name'],
              'exercises': filtered,
            };

            final nameStr = (t['name'] ?? '').toString().trim();
            final match = RegExp(r'^B(\d+)\b', caseSensitive: false).firstMatch(nameStr);
            final int? bNum = match != null ? int.tryParse(match.group(1)!) : null;

            if (bNum == null) {
              toWrite['blockAssignment'] = 'unspecified';
              debugPrint('🟨 [GEN] could not parse block number from "$nameStr" → leaving blockId null');
            } else {
              toWrite['blockAssignment'] = 'B$bNum';

              if (bNum == 1) {
                if (activeBlockId != null) {
                  toWrite['blockId'] = activeBlockId;
                } else {
                  debugPrint('🟥 [GEN] activeBlockId missing for "$nameStr"');
                }
              } else {
                final idx = bNum - 2;
                if (idx >= 0 && idx < upcomingIds.length) {
                  toWrite['blockId'] = upcomingIds[idx];
                } else {
                  debugPrint('🟥 [GEN] missing upcoming block for "$nameStr": need index=$idx in $upcomingIds');
                }
              }
            }

            final docRef = templatesCol.doc();
            batch.set(docRef, toWrite);
            debugPrint('🧰 [GEN] queued template "${t['name']}" (${filtered.length} exercises)');
          }

          batch.update(userRef, {
            _flagField: true,
            'templatesBootstrappedAt': FieldValue.serverTimestamp(),
            'templatesBranch': branchLabel,
            'templatesBootstrappedVersion': 1,
          });

          await batch.commit();
          debugPrint('🧰 [GEN] batch.commit OK (created ${genPayloads.length} + flag set)');

          final verifySnap = await templatesCol.get();
          debugPrint('🧰 [GEN] post-commit templates count=${verifySnap.size}');
          return; // ✅ done – do not fall through to legacy payloads
        } else {
          debugPrint('🧰 [GEN] generator returned 0 payloads → falling back to legacy branch');
        }
      } else {
        debugPrint('🧰 [GEN] onboarding missing/insufficient → using legacy branch');
      }
    } catch (e, st) {
      debugPrint('🧰 [GEN] generator path failed: $e\n$st\n→ falling back to legacy branch');
    }

    // ──────────────────────────────────────────────────────────────────────────
    // LEGACY PATH continues below (your existing hard-coded payloads)
    // ──────────────────────────────────────────────────────────────────────────


    // ---------------- PAYLOADS (IDs primary; names kept) ----------------
    // MALE (unchanged content, now as IDs)
    final male_b1d1 = {
      'name': 'B1 Day 1',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'OJaMXFKgMnM0X5xttBE1', 'name': 'Cable Face Pull', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Back Squat, Barbell', 'circuitIndex': 0},

        {'exerciseId': '9siQpXF2KLCj7M9kCy2m', 'name': 'Seated Shoulder Dumbbell Press', 'circuitIndex': 1},
        {'exerciseId': '1XOIXxeLFhgmgjZS9Cyq', 'name': 'Lat Pull Down, Supinated', 'circuitIndex': 1},
        {'exerciseId': 'wIcMsf2J9cswJRs1GuYX', 'name': 'Lying Leg Curl', 'circuitIndex': 1},
      ],
    };

    final male_b1d2 = {
      'name': 'B1 Day 2',
      'exercises': [
        {'exerciseId': 'kTs5fLSTKjUkUZL10iii', 'name': 'Flat Bench Dumbbell Press', 'circuitIndex': 0},
        {'exerciseId': '6SGWrCKfe7KQLThRYXQ6', 'name': 'One Arm Row, Dumbbell', 'circuitIndex': 0},
        {'exerciseId': 'y5q9OU9OBzZQMkfPzFrf', 'name': 'Romanian Deadlift', 'circuitIndex': 0},

        {'exerciseId': 'lVDG90yN6Z8aPjRNV2wc', 'name': 'Overhead Barbell Press', 'circuitIndex': 1},
        {'exerciseId': 'Url65Q2RxZa00dkDpUdl', 'name': 'Lat Pull Down, Wide Arm', 'circuitIndex': 1},
        {'exerciseId': 'QkEgE8gnIva2kkNJEfxw', 'name': 'Leg Extension', 'circuitIndex': 1},
      ],
    };

    final male_b1d3 = {
      'name': 'B1 Day 3',
      'exercises': [
        {'exerciseId': 'uY8uJaSFK9czKIX4TLc4', 'name': 'Machine Chest Press', 'circuitIndex': 0},
        {'exerciseId': 'eeEXnmSXv90q0rUgGECq', 'name': 'KP Face Pull', 'circuitIndex': 0},
        {'exerciseId': 'v2XlZUvFfBUhogOdKtJ8', 'name': 'Leg Press', 'circuitIndex': 0},

        {'exerciseId': 'igNo9pSuaOFt0GVX0zBG', 'name': 'Cable Lateral Raise', 'circuitIndex': 1},
        {'exerciseId': '7x7nEW5Goq8fu8fggUNL', 'name': 'Straight Arm Lat Pull Down', 'circuitIndex': 1},
        {'exerciseId': 'LVMQEQl6ZWBcgEUdk2tP', 'name': 'Leg Press Calf Raise', 'circuitIndex': 1},
      ],
    };

    final male_b1d4 = {
      'name': 'B1 Day 4',
      'exercises': [
        {'exerciseId': 'TBSudbow1OLdX6mSCC6S', 'name': 'Machine Chest Fly', 'circuitIndex': 0},
        {'exerciseId': '72HAT6Od4iJodEFxzw62', 'name': 'Machine Reverse Fly', 'circuitIndex': 0},
        {'exerciseId': 'Z1LpfaEBvHBDMsJ54pgw', 'name': 'Hack Squat', 'circuitIndex': 0},

        {'exerciseId': 'RcC48r0oLsNCH798d3jc', 'name': 'Butterfly Dumbbell Raise', 'circuitIndex': 1},
        {'exerciseId': 'JbthLLjMF6xRvvaUY8PU', 'name': 'Lat Pull Down, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'spGqXXReJNHMcc62YgZX', 'name': 'Seated Calf Raise', 'circuitIndex': 1},
      ],
    };

    final male_b2d1 = {
      'name': 'B2 Day 1',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': '6d9Ud7ffAHpljWsSKrFe', 'name': 'Seated Face Pull', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Back Squat, Barbell', 'circuitIndex': 0},

        {'exerciseId': 'RdsGazgdH0xgpjek0n3u', 'name': 'Overhead Dumbbell Press, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'XM9026peNIu0R8qh7UqY', 'name': 'Chin-Up', 'circuitIndex': 1},
        {'exerciseId': 'ETm055bydWtUCxTMu3MR', 'name': 'Seated Leg Curl', 'circuitIndex': 1},
      ],
    };

    final male_b2d2 = {
      'name': 'B2 Day 2',
      'exercises': [
        {'exerciseId': 'jtMoW3Nht1k97YgweteC', 'name': 'Incline Bench Dumbbell Press', 'circuitIndex': 0},
        {'exerciseId': '6SGWrCKfe7KQLThRYXQ6', 'name': 'One Arm Row, Dumbbell', 'circuitIndex': 0},
        {'exerciseId': 'y5q9OU9OBzZQMkfPzFrf', 'name': 'Romanian Deadlift', 'circuitIndex': 0},

        {'exerciseId': 'lVDG90yN6Z8aPjRNV2wc', 'name': 'Barbell Overhead Press', 'circuitIndex': 1},
        {'exerciseId': 'Url65Q2RxZa00dkDpUdl', 'name': 'Lat Pull Down, Wide Arm', 'circuitIndex': 1},
        {'exerciseId': 'ZKpGshMxFl2dxNmYSATj', 'name': 'Leg Extension, Unilateral', 'circuitIndex': 1},
      ],
    };

    final male_b2d3 = {
      'name': 'B2 Day 3',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'eeEXnmSXv90q0rUgGECq', 'name': 'KP Face Pull', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Barbell Back Squat', 'circuitIndex': 0},

        {'exerciseId': 'igNo9pSuaOFt0GVX0zBG', 'name': 'Cable Lateral Raise', 'circuitIndex': 1},
        {'exerciseId': '8saP9lWMoQffuh30A99K', 'name': 'Lat Prayer', 'circuitIndex': 1},
        {'exerciseId': 'LVMQEQl6ZWBcgEUdk2tP', 'name': 'Leg Press Calf Raise', 'circuitIndex': 1},
      ],
    };

    final male_b2d4 = {
      'name': 'B2 Day 4',
      'exercises': [
        {'exerciseId': 'ZKrfhPhJIiC1hRuwBEw1', 'name': 'Bayesian Fly', 'circuitIndex': 0},
        {'exerciseId': 'qU2wXMth4duOhhzTUWet', 'name': 'Decline Crunch', 'circuitIndex': 0},
        {'exerciseId': 'ISXQqOEXLjMrPEs0xjgJ', 'name': 'Bulgarian Split Squat', 'circuitIndex': 0},

        {'exerciseId': 'RcC48r0oLsNCH798d3jc', 'name': 'Butterfly Dumbbell Raise', 'circuitIndex': 1},
        {'exerciseId': 'JbthLLjMF6xRvvaUY8PU', 'name': 'Lat Pull Down, Unilateral', 'circuitIndex': 1},
        {'exerciseId': '9Oovma2yszjmSm420awp', 'name': 'Suspended Triceps Extension', 'circuitIndex': 1},
      ],
    };

    final male_b3d1 = {
      'name': 'B3 Day 1',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'KPewxxYYrhsOp84lIQr5', 'name': 'Suspended High Row', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Barbell Back Squat', 'circuitIndex': 0},

        {'exerciseId': 'RdsGazgdH0xgpjek0n3u', 'name': 'Overhead Dumbbell Press, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'XM9026peNIu0R8qh7UqY', 'name': 'Chin-Up', 'circuitIndex': 1},
        {'exerciseId': 'PXqhBA8ib7FWAcPjDlES', 'name': 'Suspended Leg Curl', 'circuitIndex': 1},
      ],
    };

    final male_b3d2 = {
      'name': 'B3 Day 2',
      'exercises': [
        {'exerciseId': 'kTs5fLSTKjUkUZL10iii', 'name': 'Flat Bench Dumbbell Press', 'circuitIndex': 0},
        {'exerciseId': '6SGWrCKfe7KQLThRYXQ6', 'name': 'One Arm Row, Dumbbell', 'circuitIndex': 0},
        {'exerciseId': 'MsGl7e9yanDeEnYX0e4X', 'name': 'Deadlift, Conventional', 'circuitIndex': 0},

        {'exerciseId': 'lVDG90yN6Z8aPjRNV2wc', 'name': 'Barbell Overhead Press', 'circuitIndex': 1},
        {'exerciseId': 'Url65Q2RxZa00dkDpUdl', 'name': 'Lat Pull Down, Wide Arm', 'circuitIndex': 1},
        {'exerciseId': 'ZKpGshMxFl2dxNmYSATj', 'name': 'Leg Extension, Unilateral', 'circuitIndex': 1},
      ],
    };

    final male_b3d3 = {
      'name': 'B3 Day 3',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'P88Vj5pBydqmiEzFowag', 'name': 'Hanging Straight Leg Raise', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Barbell Back Squat', 'circuitIndex': 0},

        {'exerciseId': 'igNo9pSuaOFt0GVX0zBG', 'name': 'Cable Lateral Raise', 'circuitIndex': 1},
        {'exerciseId': '8saP9lWMoQffuh30A99K', 'name': 'Lat Prayer', 'circuitIndex': 1},
        {'exerciseId': 'LVMQEQl6ZWBcgEUdk2tP', 'name': 'Leg Press Calf Raise', 'circuitIndex': 1},
      ],
    };

    final male_b3d4 = {
      'name': 'B3 Day 4',
      'exercises': [
        {'exerciseId': 'EFbQl9i9NdYi13F3DqHr', 'name': 'Suspended Push Up', 'circuitIndex': 0},
        {'exerciseId': 'ewJBWuDzj1CxfQ3vI3QS', 'name': 'Reverse Bayesian Fly', 'circuitIndex': 0},
        {'exerciseId': 'xbePAZEtQIFEjvu2YaPV', 'name': 'Bulgarian Split Squat, Deficit', 'circuitIndex': 0},

        {'exerciseId': 'RcC48r0oLsNCH798d3jc', 'name': 'Butterfly Dumbbell Raise', 'circuitIndex': 1},
        {'exerciseId': 'JbthLLjMF6xRvvaUY8PU', 'name': 'Lat Pull Down, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'FtayDmR5BVnGS1FXlXLL', 'name': 'Triceps Dip', 'circuitIndex': 1},
      ],
    };

    // ─────────────── Male 16–26: B1 ───────────────
    final m1626_b1d1 = {
      'name': 'B1 Day 1',
      'exercises': [
        // circuit 0 (3)
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'OJaMXFKgMnM0X5xttBE1', 'name': 'Cable Face Pull', 'circuitIndex': 0},
        {'exerciseId': 'v2XlZUvFfBUhogOdKtJ8', 'name': 'Leg Press', 'circuitIndex': 0},
        // circuit 1 (3)
        {'exerciseId': '2yJSfLMfOnNDSeZ7DqZT', 'name': 'Overhead Dumbbell Press', 'circuitIndex': 1},
        {'exerciseId': '1XOIXxeLFhgmgjZS9Cyq', 'name': 'Lat Pull Down, Supinated', 'circuitIndex': 1},
        {'exerciseId': 'wIcMsf2J9cswJRs1GuYX', 'name': 'Lying Leg Curl', 'circuitIndex': 1},
        // circuit 2 (2)
        {'exerciseId': 'QacImADmlpljltUvB0dD', 'name': 'Overhead Cable Triceps Extension', 'circuitIndex': 2},
        {'exerciseId': 'zn5PgKNRrWo1MTE4wnCy', 'name': 'Bayesian Curl', 'circuitIndex': 2},
      ],
    };

    final m1626_b1d2 = {
      'name': 'B1 Day 2',
      'exercises': [
        // circuit 0 (3)
        {'exerciseId': 'kTs5fLSTKjUkUZL10iii', 'name': 'Flat Bench DB Press', 'circuitIndex': 0},
        {'exerciseId': 'ocNWJv7xLrlinGmjG6cV', 'name': 'Machine Row, Supported', 'circuitIndex': 0},
        {'exerciseId': 'eyh76KELuuO805rZBpMa', 'name': '45 Degree Hip Extension', 'circuitIndex': 0},
        // circuit 1 (3)
        {'exerciseId': 'lVDG90yN6Z8aPjRNV2wc', 'name': 'Barbell Overhead Press', 'circuitIndex': 1},
        {'exerciseId': 'Url65Q2RxZa00dkDpUdl', 'name': 'Wide Arm Lat Pull Down', 'circuitIndex': 1},
        {'exerciseId': 'QkEgE8gnIva2kkNJEfxw', 'name': 'Leg Extension', 'circuitIndex': 1},
        // circuit 2 (2)
        {'exerciseId': 'E6jPE8YYR0KA3xtVaKJo', 'name': 'Triceps Push Down', 'circuitIndex': 2},
        {'exerciseId': '0dZrCqZ8M7Q1sAn0zeeb', 'name': 'Dumbbell Biceps Curl', 'circuitIndex': 2},
      ],
    };

    final m1626_b1d3 = {
      'name': 'B1 Day 3',
      'exercises': [
        // circuit 0 (3)
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'eeEXnmSXv90q0rUgGECq', 'name': 'Seated Face Pull', 'circuitIndex': 0},
        {'exerciseId': 'v2XlZUvFfBUhogOdKtJ8', 'name': 'Leg Press', 'circuitIndex': 0},
        // circuit 1 (3)
        {'exerciseId': 'igNo9pSuaOFt0GVX0zBG', 'name': 'Cable Lateral Raise', 'circuitIndex': 1},
        {'exerciseId': '7x7nEW5Goq8fu8fggUNL', 'name': 'Straight Arm Lat Pull Down', 'circuitIndex': 1},
        {'exerciseId': 'ci3KpMTEacH4bw8ZumJW', 'name': 'Standing Calf Raise', 'circuitIndex': 1},
        // circuit 2 (2)
        {'exerciseId': 'P88Vj5pBydqmiEzFowag', 'name': 'Hanging Straight Leg Raise', 'circuitIndex': 2},
        {'exerciseId': 'zn5PgKNRrWo1MTE4wnCy', 'name': 'Bayesian Curl', 'circuitIndex': 2},
      ],
    };

    final m1626_b1d4 = {
      'name': 'B1 Day 4',
      'exercises': [
        // circuit 0 (3)
        {'exerciseId': 'TBSudbow1OLdX6mSCC6S', 'name': 'Machine Chest Fly', 'circuitIndex': 0},
        {'exerciseId': '72HAT6Od4iJodEFxzw62', 'name': 'Machine Reverse Fly', 'circuitIndex': 0},
        {'exerciseId': 'Z1LpfaEBvHBDMsJ54pgw', 'name': 'Hack Squat', 'circuitIndex': 0},
        // circuit 1 (3)
        {'exerciseId': '9siQpXF2KLCj7M9kCy2m', 'name': 'Seated Shoulder DB Press', 'circuitIndex': 1},
        {'exerciseId': '6SGWrCKfe7KQLThRYXQ6', 'name': 'One Arm Row, Dumbbell', 'circuitIndex': 1},
        {'exerciseId': 'spGqXXReJNHMcc62YgZX', 'name': 'Seated Calf Raise', 'circuitIndex': 1},
        // circuit 2 (2)
        {'exerciseId': 't66qeWQqnuEtaoyZqRp0', 'name': 'Triceps Dip Machine', 'circuitIndex': 2},
        {'exerciseId': 'qU2wXMth4duOhhzTUWet', 'name': 'Decline Crunch', 'circuitIndex': 2},
      ],
    };

// ─────────────── Male 16–26: B2 ───────────────
    final m1626_b2d1 = {
      'name': 'B2 Day 1',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'KPewxxYYrhsOp84lIQr5', 'name': 'Suspended High Row', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Barbell Back Squat', 'circuitIndex': 0},
        {'exerciseId': 'RdsGazgdH0xgpjek0n3u', 'name': 'Overhead DB Press, Unilateral', 'circuitIndex': 1},
        {'exerciseId': '1XOIXxeLFhgmgjZS9Cyq', 'name': 'Supinated Lat Pull', 'circuitIndex': 1},
        {'exerciseId': 'ETm055bydWtUCxTMu3MR', 'name': 'Seated Leg Curl', 'circuitIndex': 1},
        {'exerciseId': 'z5gs1ilr4DpKlSZaRNG5', 'name': 'Overhead Cable Triceps Ext, Unilateral', 'circuitIndex': 2},
        {'exerciseId': 'WPb8rtRTupKIBzgydB5k', 'name': 'Cable Biceps Curl', 'circuitIndex': 2},
      ],
    };

    final m1626_b2d2 = {
      'name': 'B2 Day 2',
      'exercises': [
        {'exerciseId': 'jtMoW3Nht1k97YgweteC', 'name': 'Incline Bench DB Press', 'circuitIndex': 0},
        {'exerciseId': '6SGWrCKfe7KQLThRYXQ6', 'name': 'One Arm Row, Dumbbell', 'circuitIndex': 0},
        {'exerciseId': 'y5q9OU9OBzZQMkfPzFrf', 'name': 'Romanian Deadlift', 'circuitIndex': 0},
        {'exerciseId': 'lVDG90yN6Z8aPjRNV2wc', 'name': 'Barbell Overhead Press', 'circuitIndex': 1},
        {'exerciseId': 'Url65Q2RxZa00dkDpUdl', 'name': 'Wide Arm Lat Pull', 'circuitIndex': 1},
        {'exerciseId': 'ZKpGshMxFl2dxNmYSATj', 'name': 'Leg Extension, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'E6jPE8YYR0KA3xtVaKJo', 'name': 'Triceps Push Down', 'circuitIndex': 2},
        {'exerciseId': '0dZrCqZ8M7Q1sAn0zeeb', 'name': 'Dumbbell Biceps Curl', 'circuitIndex': 2},
      ],
    };

    final m1626_b2d3 = {
      'name': 'B2 Day 3',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': '0s4yMXygBXZZJH66Yi6h', 'name': 'Seated Face Pull, Unilateral', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Barbell Back Squat', 'circuitIndex': 0},
        {'exerciseId': 'RcC48r0oLsNCH798d3jc', 'name': 'Butterfly Dumbbell Raise', 'circuitIndex': 1},
        {'exerciseId': '7x7nEW5Goq8fu8fggUNL', 'name': 'Straight Arm Lat Pull', 'circuitIndex': 1},
        {'exerciseId': 'LVMQEQl6ZWBcgEUdk2tP', 'name': 'Leg Press Calf Raise', 'circuitIndex': 1},
        {'exerciseId': 'P88Vj5pBydqmiEzFowag', 'name': 'Hanging Straight Leg Raise', 'circuitIndex': 2},
        {'exerciseId': 'zn5PgKNRrWo1MTE4wnCy', 'name': 'Bayesian Curl', 'circuitIndex': 2},
      ],
    };

    final m1626_b2d4 = {
      'name': 'B2 Day 4',
      'exercises': [
        {'exerciseId': 'ZKrfhPhJIiC1hRuwBEw1', 'name': 'Bayesian Fly', 'circuitIndex': 0},
        {'exerciseId': 'ewJBWuDzj1CxfQ3vI3QS', 'name': 'Reverse Bayesian Fly', 'circuitIndex': 0},
        {'exerciseId': 'v2XlZUvFfBUhogOdKtJ8', 'name': 'Leg Press', 'circuitIndex': 0},
        {'exerciseId': '9siQpXF2KLCj7M9kCy2m', 'name': 'Seated Shoulder DB Press', 'circuitIndex': 1},
        {'exerciseId': 'JbthLLjMF6xRvvaUY8PU', 'name': 'Lat Pull Down, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'ci3KpMTEacH4bw8ZumJW', 'name': 'Standing Calf Raise', 'circuitIndex': 1},
        {'exerciseId': 'FtayDmR5BVnGS1FX1XLL', 'name': 'Triceps Dips', 'circuitIndex': 2},
        {'exerciseId': 'qU2wXMth4duOhhzTUWet', 'name': 'Decline Crunch', 'circuitIndex': 2},
      ],
    };

// ─────────────── Male 16–26: B3 ───────────────
    final m1626_b3d1 = {
      'name': 'B3 Day 1',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'KPewxxYYrhsOp84lIQr5', 'name': 'Suspended High Row', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Barbell Back Squat', 'circuitIndex': 0},
        {'exerciseId': 'RdsGazgdH0xgpjek0n3u', 'name': 'Overhead DB Press, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'XM9026peNIu0R8qh7UqY', 'name': 'Chin-Up', 'circuitIndex': 1},
        {'exerciseId': 'PXqhBA8ib7FWAcPjDlES', 'name': 'Suspended Leg Curl', 'circuitIndex': 1},
        {'exerciseId': '9Oovma2yszjmSm420awp', 'name': 'Suspended Triceps Ext', 'circuitIndex': 2},
        {'exerciseId': 'zn5PgKNRrWo1MTE4wnCy', 'name': 'Bayesian Curl', 'circuitIndex': 2},
      ],
    };

    final m1626_b3d2 = {
      'name': 'B3 Day 2',
      'exercises': [
        {'exerciseId': 'kTs5fLSTKjUkUZL10iii', 'name': 'Flat Bench DB Press', 'circuitIndex': 0},
        {'exerciseId': '6SGWrCKfe7KQLThRYXQ6', 'name': 'One Arm Row', 'circuitIndex': 0},
        {'exerciseId': 'MsGl7e9yanDeEnYX0e4X', 'name': 'Conventional Deadlift', 'circuitIndex': 0},
        {'exerciseId': 'lVDG90yN6Z8aPjRNV2wc', 'name': 'Barbell Overhead Press', 'circuitIndex': 1},
        {'exerciseId': 'Url65Q2RxZa00dkDpUdl', 'name': 'Wide Arm Lat Pull Down', 'circuitIndex': 1},
        {'exerciseId': 'ZKpGshMxFl2dxNmYSATj', 'name': 'Leg Extension, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'Ah9XLjbWvLJOWxb6e1H0', 'name': 'Triceps Push Down, Unilateral', 'circuitIndex': 2},
        {'exerciseId': 'F76PnvlLLVF6hviuhRfH', 'name': 'Seated DB Biceps Curl', 'circuitIndex': 2},
      ],
    };

    final m1626_b3d3 = {
      'name': 'B3 Day 3',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'eeEXnmSXv90q0rUgGECq', 'name': 'KP Face Pull', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Barbell Back Squat', 'circuitIndex': 0},
        {'exerciseId': 'igNo9pSuaOFt0GVX0zBG', 'name': 'Cable Lateral Raise', 'circuitIndex': 1},
        {'exerciseId': '8saP9lWMoQffuh30A99K', 'name': 'Lat Prayer', 'circuitIndex': 1},
        {'exerciseId': 'LVMQEQl6ZWBcgEUdk2tP', 'name': 'Leg Press Calf Raise', 'circuitIndex': 1},
        {'exerciseId': 'P88Vj5pBydqmiEzFowag', 'name': 'Hanging Straight Leg Raise', 'circuitIndex': 2},
        {'exerciseId': 'zn5PgKNRrWo1MTE4wnCy', 'name': 'Bayesian Curl', 'circuitIndex': 2},
      ],
    };

    final m1626_b3d4 = {
      'name': 'B3 Day 4',
      'exercises': [
        {'exerciseId': 'EFbQl9i9NdYi13F3DqHr', 'name': 'Suspended Push Up', 'circuitIndex': 0},
        {'exerciseId': 'ewJBWuDzj1CxfQ3vI3QS', 'name': 'Reverse Bayesian Fly', 'circuitIndex': 0},
        {'exerciseId': 'ISXQqOEXLjMrPEs0xjgJ', 'name': 'Bulgarian Split Squat', 'circuitIndex': 0},

        {'exerciseId': 'RcC48r0oLsNCH798d3jc', 'name': 'Butterfly DB Raise', 'circuitIndex': 1},
        {'exerciseId': 'JbthLLjMF6xRvvaUY8PU', 'name': 'Lat Pull Down, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'spGqXXReJNHMcc62YgZX', 'name': 'Seated Calf Raise', 'circuitIndex': 1},

        {'exerciseId': 'FtayDmR5BVnGS1FX1XLL', 'name': 'Triceps Dips', 'circuitIndex': 2},
        {'exerciseId': 'qU2wXMth4duOhhzTUWet', 'name': 'Decline Crunch', 'circuitIndex': 2},
      ],
    };




    // FEMALE (IDs where known; unknowns will be skipped+logged)
    final female_b1d1 = {
      'name': 'B1 Day 1',
      'exercises': [
        {'exerciseId': 'uY8uJaSFK9czKIX4TLc4', 'name': 'Machine Chest Press', 'circuitIndex': 0},
        {'exerciseId': 'wIcMsf2J9cswJRs1GuYX', 'name': 'Lying Leg Curl', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Back Squat, Barbell', 'circuitIndex': 0},

        {'exerciseId': '1XOIXxeLFhgmgjZS9Cyq', 'name': 'Lat Pull Down, Supinated', 'circuitIndex': 1},
        {'exerciseId': 'YaQ0FCQEUAk4ALwAPhv2', 'name': 'Machine Hip Thrust', 'circuitIndex': 1},
        {'exerciseId': 'kxgQUX7Cr75l1kOwRaqc', 'name': 'Spider-Girl Plank', 'circuitIndex': 1},

        {'exerciseId': 'WPb8rtRTupKIBzgydB5k', 'name': 'Cable Biceps Curl', 'circuitIndex': 2},
        {'exerciseId': 'QacImADmlpljltUvB0dD', 'name': 'Overhead Cable Triceps Extension', 'circuitIndex': 2},
      ],
    };
    final female_b1d2 = {
      'name': 'B1 Day 2',
      'exercises': [
        {'exerciseId': 'vrSYibzR5DHzl6Gzp4ER', 'name': 'Machine Shoulder Press, Pin Loaded', 'circuitIndex': 0},
        {'exerciseId': 'eyh76KELuuO805rZBpMa', 'name': '45 Degree Hip Extension', 'circuitIndex': 0},
        {'exerciseId': 'QkEgE8gnIva2kkNJEfxw', 'name': 'Leg Extension', 'circuitIndex': 0},

        {'exerciseId': 'ocNWJv7xLrlinGmjG6cV', 'name': 'Machine Row, Supported', 'circuitIndex': 1},
        {'exerciseId': 'visub8iG0LIXYYCv5Qom', 'name': 'Hip Thrust, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'BpO7e9KsDJsvwhfo09uU', 'name': 'Hanging Knee Raise', 'circuitIndex': 1},

        {'exerciseId': 't66qeWQqnuEtaoyZqRp0', 'name': 'Triceps Dip Machine', 'circuitIndex': 2},
        {'exerciseId': '7WBffXwK7vJcMi3mtJTF', 'name': 'Machine Hip Abduction', 'circuitIndex': 2},
      ],
    };
    final female_b1d3 = {
      'name': 'B1 Day 3',
      'exercises': [
        {'exerciseId': 'kTs5fLSTKjUkUZL10iii', 'name': 'Flat Bench Dumbbell Press', 'circuitIndex': 0},
        {'exerciseId': 'zpNb7HgXjtcrzR14F3iF', 'name': 'Cable One Arm Row', 'circuitIndex': 0},
        {'exerciseId': 'v2XlZUvFfBUhogOdKtJ8', 'name': 'Leg Press', 'circuitIndex': 0},

        {'exerciseId': 'YaQ0FCQEUAk4ALwAPhv2', 'name': 'Machine Hip Thrust', 'circuitIndex': 1},
        {'exerciseId': 'WPb8rtRTupKIBzgydB5k', 'name': 'Cable Biceps Curl', 'circuitIndex': 1},
        {'exerciseId': 'SoHQVtsCQreaHM8LUI5F', 'name': 'Bicycle Crunch', 'circuitIndex': 1},

        {'exerciseId': 'hCpQR1NgeEAp31lVRWLw', 'name': 'Machine Hip Adduction', 'circuitIndex': 2},
        {'exerciseId': 'LVMQEQl6ZWBcgEUdk2tP', 'name': 'Leg Press Calf Raise', 'circuitIndex': 2},
      ],
    };
    final female_b1d4 = {
      'name': 'B1 Day 4',
      'exercises': [
        {'exerciseId': 'vrSYibzR5DHzl6Gzp4ER', 'name': 'Machine Shoulder Press, Pin Loaded', 'circuitIndex': 0},
        {'exerciseId': 'Url65Q2RxZa00dkDpUdl', 'name': 'Lat Pull Down, Wide Arm', 'circuitIndex': 0},
        {'exerciseId': 'LGhFj8o0sG3X12296UAh', 'name': 'Hip Thrust, Barbell', 'circuitIndex': 0},

        {'exerciseId': '9siQpXF2KLCj7M9kCy2m', 'name': 'Seated Shoulder Dumbbell Press', 'circuitIndex': 1},
        {'exerciseId': '7WBffXwK7vJcMi3mtJTF', 'name': 'Machine Hip Abduction', 'circuitIndex': 1},
        {'exerciseId': 'spGqXXReJNHMcc62YgZX', 'name': 'Seated Calf Raise', 'circuitIndex': 1},

        {'exerciseId': 't66qeWQqnuEtaoyZqRp0', 'name': 'Triceps Dip Machine', 'circuitIndex': 2},
        {'exerciseId': 'BpO7e9KsDJsvwhfo09uU', 'name': 'Hanging Knee Raise', 'circuitIndex': 2},
      ],
    };
    final female_b2d1 = {
      'name': 'B2 Day 1',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'ETm055bydWtUCxTMu3MR', 'name': 'Seated Leg Curl', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Back Squat, Barbell', 'circuitIndex': 0},

        {'exerciseId': '7x7nEW5Goq8fu8fggUNL', 'name': 'Straight Arm Lat Pull Down', 'circuitIndex': 1},
        {'exerciseId': 'LGhFj8o0sG3X12296UAh', 'name': 'Hip Thrust, Barbell', 'circuitIndex': 1},
        {'exerciseId': '8CIXN12uS2xwF4JzVLq3', 'name': 'Long Lever Plank', 'circuitIndex': 1},

        {'exerciseId': '3dWgorRmtgzsV0U4qu47', 'name': 'Glute Cable Kick Back', 'circuitIndex': 2},
        {'exerciseId': 'z5gs1ilr4DpKlSZaRNG5', 'name': 'Overhead Cable Triceps Extension, Unilateral', 'circuitIndex': 2},
      ],
    };
    final female_b2d2 = {
      'name': 'B2 Day 2',
      'exercises': [
        {'exerciseId': 'kTs5fLSTKjUkUZL10iii', 'name': 'Flat Bench Dumbbell Press', 'circuitIndex': 0},
        {'exerciseId': 'y5q9OU9OBzZQMkfPzFrf', 'name': 'Romanian Deadlift', 'circuitIndex': 0},
        {'exerciseId': 'ZKpGshMxFl2dxNmYSATj', 'name': 'Leg Extension, Unilateral', 'circuitIndex': 0},
        {'exerciseId': 'yiTmu2Ul6TwYs3XiXauz', 'name': 'Seated Row, Cable', 'circuitIndex': 1},
        {'exerciseId': 'visub8iG0LIXYYCv5Qom', 'name': 'Hip Thrust, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'P88Vj5pBydqmiEzFowag', 'name': 'Hanging Straight Leg Raise', 'circuitIndex': 1},

        {'exerciseId': 'hCpQR1NgeEAp31lVRWLw', 'name': 'Machine Hip Adduction', 'circuitIndex': 2},
        {'exerciseId': '7WBffXwK7vJcMi3mtJTF', 'name': 'Machine Hip Abduction', 'circuitIndex': 2},
      ],
    };
    final female_b2d3 = {
      'name': 'B2 Day 3',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'zpNb7HgXjtcrzR14F3iF', 'name': 'Cable One Arm Row', 'circuitIndex': 0},
        {'exerciseId': 'Z1LpfaEBvHBDMsJ54pgw', 'name': 'Hack Squat', 'circuitIndex': 0},

        {'exerciseId': 'LGhFj8o0sG3X12296UAh', 'name': 'Hip Thrust, Barbell', 'circuitIndex': 1},
        {'exerciseId': '0dZrCqZ8M7Q1sAn0zeeb', 'name': 'Dumbbell Biceps Curl', 'circuitIndex': 1},
        {'exerciseId': 'qU2wXMth4duOhhzTUWet', 'name': 'Decline Crunch', 'circuitIndex': 1},

        {'exerciseId': 'QacImADmlpljltUvB0dD', 'name': 'Overhead Cable Triceps Extension', 'circuitIndex': 2},
        {'exerciseId': 'ci3KpMTEacH4bw8ZumJW', 'name': 'Standing Calf Raise', 'circuitIndex': 2},
      ],
    };
    final female_b2d4 = {
      'name': 'B2 Day 4',
      'exercises': [
        {'exerciseId': 'lVDG90yN6Z8aPjRNV2wc', 'name': 'Overhead Barbell Press', 'circuitIndex': 0},
        {'exerciseId': 'JbthLLjMF6xRvvaUY8PU', 'name': 'Lat Pull Down, Unilateral', 'circuitIndex': 0},
        {'exerciseId': 'YaQ0FCQEUAk4ALwAPhv2', 'name': 'Machine Hip Thrust', 'circuitIndex': 0},

        {'exerciseId': '9siQpXF2KLCj7M9kCy2m', 'name': 'Seated Shoulder Dumbbell Press', 'circuitIndex': 1},
        {'exerciseId': '7WBffXwK7vJcMi3mtJTF', 'name': 'Machine Hip Abduction', 'circuitIndex': 1},
        {'exerciseId': 'spGqXXReJNHMcc62YgZX', 'name': 'Seated Calf Raise', 'circuitIndex': 1},

        {'exerciseId': 'E6jPE8YYR0KA3xtVaKJo', 'name': 'Triceps Push Down', 'circuitIndex': 2},
        {'exerciseId': 'P88Vj5pBydqmiEzFowag', 'name': 'Hanging Straight Leg Raise', 'circuitIndex': 2},
      ],
    };

    final female_b3d1 = {
      'name': 'B3 Day 1',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'ETm055bydWtUCxTMu3MR', 'name': 'Seated Leg Curl', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Back Squat, Barbell', 'circuitIndex': 0},

        {'exerciseId': 'Url65Q2RxZa00dkDpUdl', 'name': 'Lat Pull Down, Wide Arm', 'circuitIndex': 1},
        {'exerciseId': 'y5q9OU9OBzZQMkfPzFrf', 'name': 'Romanian Deadlift', 'circuitIndex': 1},
        {'exerciseId': '8CIXN12uS2xwF4JzVLq3', 'name': 'Long Lever Plank', 'circuitIndex': 1},

        {'exerciseId': 'QacImADmlpljltUvB0dD', 'name': 'Overhead Cable Triceps Extension', 'circuitIndex': 2},
        {'exerciseId': 'ci3KpMTEacH4bw8ZumJW', 'name': 'Standing Calf Raise', 'circuitIndex': 2},
      ],
    };

    final female_b3d2 = {
      'name': 'B3 Day 2',
      'exercises': [
        {'exerciseId': 'Da2xWZqbeCsbGCwdbwbs', 'name': 'Push Up, Deficit', 'circuitIndex': 0},
        {'exerciseId': 'y5q9OU9OBzZQMkfPzFrf', 'name': 'Romanian Deadlift', 'circuitIndex': 0},
        {'exerciseId': 'ZKpGshMxFl2dxNmYSATj', 'name': 'Leg Extension, Unilateral', 'circuitIndex': 0},

        {'exerciseId': 'OJaMXFKgMnM0X5xttBE1', 'name': 'Cable Face Pull', 'circuitIndex': 1},
        {'exerciseId': 'BiJsmBeyrAX2ot8CQkxa', 'name': 'Romanian Deadlift, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'P88Vj5pBydqmiEzFowag', 'name': 'Hanging Straight Leg Raise', 'circuitIndex': 1},

        {'exerciseId': 'hCpQR1NgeEAp31lVRWLw', 'name': 'Machine Hip Adduction', 'circuitIndex': 2},
        {'exerciseId': '7WBffXwK7vJcMi3mtJTF', 'name': 'Machine Hip Abduction', 'circuitIndex': 2},
      ],
    };

    final female_b3d3 = {
      'name': 'B3 Day 3',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'zpNb7HgXjtcrzR14F3iF', 'name': 'Cable One Arm Row', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Back Squat, Barbell', 'circuitIndex': 0},

        {'exerciseId': 'LGhFj8o0sG3X12296UAh', 'name': 'Hip Thrust, Barbell', 'circuitIndex': 1},
        {'exerciseId': 'zn5PgKNRrWo1MTE4wnCy', 'name': 'Bayesian Biceps Curl', 'circuitIndex': 1},
        {'exerciseId': 'kxgQUX7Cr75l1kOwRaqc', 'name': 'Spider-Girl Plank', 'circuitIndex': 1},

        {'exerciseId': 'E6jPE8YYR0KA3xtVaKJo', 'name': 'Triceps Push Down', 'circuitIndex': 2},
        {'exerciseId': 'visub8iG0LIXYYCv5Qom', 'name': 'Hip Thrust, Unilateral', 'circuitIndex': 2},
      ],
    };

    final female_b3d4 = {
      'name': 'B3 Day 4',
      'exercises': [
        {'exerciseId': 'lVDG90yN6Z8aPjRNV2wc', 'name': 'Overhead Barbell Press', 'circuitIndex': 0},
        {'exerciseId': 'y5q9OU9OBzZQMkfPzFrf', 'name': 'Romanian Deadlift', 'circuitIndex': 0},
        {'exerciseId': 'XM9026peNIu0R8qh7UqY', 'name': 'Chin-Up', 'circuitIndex': 0},

        {'exerciseId': '9siQpXF2KLCj7M9kCy2m', 'name': 'Seated Shoulder Dumbbell Press', 'circuitIndex': 1},
        {'exerciseId': 'JbthLLjMF6xRvvaUY8PU', 'name': 'Lat Pull Down, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'Z1LpfaEBvHBDMsJ54pgw', 'name': 'Hack Squat', 'circuitIndex': 1},


        {'exerciseId': 'P88Vj5pBydqmiEzFowag', 'name': 'Hanging Straight Leg Raise', 'circuitIndex': 2},
        {'exerciseId': 't66qeWQqnuEtaoyZqRp0', 'name': 'Triceps Dip Machine', 'circuitIndex': 2},
      ],
    };


    // Choose the correct payloads by branch
    late final List<Map<String, dynamic>> payloads;
    late final String branchLabel;

    if (femaleEligible || female30plus) {
      // 👩‍🦰 FEMALE: 13–30 OR 31+
      payloads = [
        female_b1d1, female_b1d2, female_b1d3, female_b1d4,
        female_b2d1, female_b2d2, female_b2d3, female_b2d4,
        female_b3d1, female_b3d2, female_b3d3, female_b3d4,
      ];
      branchLabel = female30plus ? 'FEMALE_31_PLUS' : 'FEMALE_13_30';

    } else if (male16to26) {
      // 👨 MALE: 16–26
      payloads = [
        m1626_b1d1, m1626_b1d2, m1626_b1d3, m1626_b1d4,
        m1626_b2d1, m1626_b2d2, m1626_b2d3, m1626_b2d4,
        m1626_b3d1, m1626_b3d2, m1626_b3d3, m1626_b3d4,
      ];
      branchLabel = 'MALE_16_26';

    } else if (male27to39 || male40plus) {
      // 👨 MALE: 27–39 OR 40+
      payloads = [
        male_b1d1, male_b1d2, male_b1d3, male_b1d4,
        male_b2d1, male_b2d2, male_b2d3, male_b2d4,
        male_b3d1, male_b3d2, male_b3d3, male_b3d4,
      ];
      branchLabel = male40plus ? 'MALE_40_PLUS' : 'MALE_27_39';

    } else {
      // 🚨 Should never happen (guard above prevents this)
      payloads = [
        male_b1d1, male_b1d2, male_b1d3, male_b1d4,
        male_b2d1, male_b2d2, male_b2d3, male_b2d4,
        male_b3d1, male_b3d2, male_b3d3, male_b3d4,
      ];
      branchLabel = 'MALE_FALLBACK';
    }


    debugPrint('🧰 [TB] prepared ${payloads.length} templates to create (branch=$branchLabel)');


    try {
      final batch = FirebaseFirestore.instance.batch();

      // Filter per-template for missing exerciseId (skip & log)
      for (final t in payloads) {
        final exercises = (t['exercises'] as List).cast<Map<String, dynamic>>();
        final filtered = <Map<String, dynamic>>[];
        for (final ex in exercises) {
          final exId = (ex['exerciseId'] as String?)?.trim();
          final exName = (ex['name'] as String?) ?? '(unnamed)';
          if (exId == null || exId.isEmpty) {
            debugPrint('🟥 [TB] skipping exercise without ID → "$exName" in template "${t['name']}"');
            continue;
          }
          filtered.add(ex);
        }

        if (filtered.isEmpty) {
          debugPrint('🟨 [TB] template "${t['name']}" has no valid exercises after filtering → skipping create');
          continue;
        }

        final toWrite = {
          'name': t['name'],
          'exercises': filtered,
        };

        // 🧠 Tag for debug + persist real block link
        final nameStr = (t['name'] ?? '').toString().trim();

// Extract the block number (e.g., "B1 Day 2" → 1), default to null if not matched.
        final match = RegExp(r'^B(\d+)\b', caseSensitive: false).firstMatch(nameStr);
        final int? bNum = match != null ? int.tryParse(match.group(1)!) : null;

        if (bNum == null) {
          toWrite['blockAssignment'] = 'unspecified';
          debugPrint('🟨 [TB] could not parse block number from "$nameStr" → leaving blockId null');
        } else {
          toWrite['blockAssignment'] = 'B$bNum';

          if (bNum == 1) {
            // B1 → active
            if (activeBlockId != null) {
              toWrite['blockId'] = activeBlockId;
            } else {
              debugPrint('🟥 [TB] activeBlockId missing for "$nameStr"');
            }
          } else {
            // B2 → upcomingIds[0], B3 → upcomingIds[1], etc.
            final idx = bNum - 2;
            if (idx >= 0 && idx < upcomingIds.length) {
              toWrite['blockId'] = upcomingIds[idx];
            } else {
              debugPrint('🟥 [TB] missing upcoming block for "$nameStr": need index=$idx in $upcomingIds');
            }
          }
        }

        final docRef = templatesCol.doc();
        batch.set(docRef, toWrite);
        debugPrint('🧰 [TB] queued template "${t['name']}" (${filtered.length} exercises)');
      }

      batch.update(userRef, {
        _flagField: true,
        'templatesBootstrappedAt': FieldValue.serverTimestamp(),
        'templatesBranch': branchLabel, // ← unified branch string
      });


      await batch.commit();
      debugPrint('🧰 [TB] batch.commit OK (created ${payloads.length} + flag set)');

      // Verify count after write
      final verifySnap = await templatesCol.get();
      debugPrint('🧰 [TB] post-commit templates count=${verifySnap.size}');
    } catch (e, st) {
      debugPrint('🧰 [TB] ERROR during commit: $e\n$st');
      rethrow;
    }
  }


}
