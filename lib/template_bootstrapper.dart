import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class TemplatesBootstrapper {
  static const _flagField = 'templatesBootstrapped_v1';

  static Future<void> ensureInitialTemplatesForUser(String? uid) async {
    debugPrint('🧰 [TB] ensureInitialTemplatesForUser() called uid="$uid"');
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

    if (userSnap.exists && flag) {
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

    // Branch eligibility (as agreed)
    final femaleEligible = (sexU == 'F' || sexU == 'N') && (age != null && age >= 13 && age <= 30);
    final maleEligible   = (sexU == 'M') && (age != null && age >= 27 && age <= 39);

    debugPrint('🧰 [TB] eval femaleEligible=$femaleEligible (F/N & 13–30), maleEligible=$maleEligible (M & 27–39)');

    if (!femaleEligible && !maleEligible) {
      debugPrint('🧰 [TB] not eligible for any branch → set flag and exit');
      await userRef.set(
        {_flagField: true, 'templatesBootstrappedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
      return;
    }

    final templatesCol = userRef.collection('templates');

    // For visibility: how many currently exist
    try {
      final existing = await templatesCol.limit(5).get();
      debugPrint('🧰 [TB] existing templates found=${existing.size}');
      if (existing.size > 0) {
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

    // ---------------- PAYLOADS (IDs primary; names kept) ----------------
    // MALE (unchanged content, now as IDs)
    final male_b1d1 = {
      'name': 'B1 Day 1',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'eeEXnmSXv90q0rUgGECq', 'name': 'KP Face Pull', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Back Squat, Barbell', 'circuitIndex': 0},
        {'exerciseId': '2yJSfLMfOnNDSeZ7DqZT', 'name': 'Overhead Dumbbell Press', 'circuitIndex': 1},
        {'exerciseId': '1XOIXxeLFhgmgjZS9Cyq', 'name': 'Lat Pull Down, Supinated', 'circuitIndex': 1},
        {'exerciseId': 'wIcMsf2J9cswJRs1GuYX', 'name': 'Lying Leg Curl', 'circuitIndex': 1},
      ],
    };
    final male_b1d2 = {
      'name': 'B1 Day 2',
      'exercises': [
        {'exerciseId': 'kTs5fLSTKjUkUZL10iii', 'name': 'Flat Bench Dumbbell Press', 'circuitIndex': 0},
        {'exerciseId': 'ocNWJv7xLrlinGmjG6cV', 'name': 'Machine Row, Supported', 'circuitIndex': 0},
        {'exerciseId': 'eyh76KELuuO805rZBpMa', 'name': '45 Degree Hip Extension', 'circuitIndex': 0},
        {'exerciseId': 'lVDG90yN6Z8aPjRNV2wc', 'name': 'Overhead Barbell Press', 'circuitIndex': 1},
        {'exerciseId': 'Url65Q2RxZa00dkDpUdl', 'name': 'Lat Pull Down, Wide Arm', 'circuitIndex': 1},
        {'exerciseId': 'QkEgE8gnIva2kkNJEfxw', 'name': 'Leg Extension', 'circuitIndex': 1},
      ],
    };
    final male_b1d3 = {
      'name': 'B1 Day 3',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'eeEXnmSXv90q0rUgGECq', 'name': 'KP Face Pull', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Back Squat, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'igNo9pSuaOFt0GVX0zBG', 'name': 'Cable Lateral Raise', 'circuitIndex': 1},
        {'exerciseId': '7x7nEW5Goq8fu8fggUNL', 'name': 'Straight Arm Lat Pull Down', 'circuitIndex': 1},
        {'exerciseId': 'E6jPE8YYR0KA3xtVaKJo', 'name': 'Triceps Push Down', 'circuitIndex': 1},
      ],
    };
    final male_b1d4 = {
      'name': 'B1 Day 4',
      'exercises': [
        {'exerciseId': 'v2XlZUvFfBUhogOdKtJ8', 'name': 'Leg Press', 'circuitIndex': 0},
        {'exerciseId': '9siQpXF2KLCj7M9kCy2m', 'name': 'Seated Shoulder Dumbbell Press', 'circuitIndex': 1},
        {'exerciseId': '0dZrCqZ8M7Q1sAn0zeeb', 'name': 'Dumbbell Biceps Curl', 'circuitIndex': 1},
        {'exerciseId': 'ci3KpMTEacH4bw8ZumJW', 'name': 'Standing Calf Raise', 'circuitIndex': 1},
      ],
    };
    final male_b2d1 = {
      'name': 'B2 Day 1',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'KPewxxYYrhsOp84lIQr5', 'name': 'Suspended High Row', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Back Squat, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'RdsGazgdH0xgpjek0n3u', 'name': 'Overhead Dumbbell Press, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'JbthLLjMF6xRvvaUY8PU', 'name': 'Lat Pull Down, Unilateral', 'circuitIndex': 1},
        {'exerciseId': 'ETm055bydWtUCxTMu3MR', 'name': 'Seated Leg Curl', 'circuitIndex': 1},
      ],
    };
    final male_b2d2 = {
      'name': 'B2 Day 2',
      'exercises': [
        {'exerciseId': 'kTs5fLSTKjUkUZL10iii', 'name': 'Flat Bench Dumbbell Press', 'circuitIndex': 0},
        {'exerciseId': '6SGWrCKfe7KQLThRYXQ6', 'name': 'One Arm Row, Dumbbell', 'circuitIndex': 0},
        {'exerciseId': 'y5q9OU9OBzZQMkfPzFrf', 'name': 'Romanian Deadlift', 'circuitIndex': 0},
        {'exerciseId': 'lVDG90yN6Z8aPjRNV2wc', 'name': 'Overhead Barbell Press', 'circuitIndex': 1},
        {'exerciseId': 'Url65Q2RxZa00dkDpUdl', 'name': 'Lat Pull Down, Wide Arm', 'circuitIndex': 1},
        {'exerciseId': 'ZKpGshMxFl2dxNmYSATj', 'name': 'Leg Extension, Unilateral', 'circuitIndex': 1},
      ],
    };
    final male_b2d3 = {
      'name': 'B2 Day 3',
      'exercises': [
        {'exerciseId': 'AmfUWbF1DH3I7qPAdh5k', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'xWpCQO504iGfU3LKLZlD', 'name': 'Cable High Row, Unilateral', 'circuitIndex': 0},
        {'exerciseId': 'heeBViVINHO6tUScSd6y', 'name': 'Back Squat, Barbell', 'circuitIndex': 0},
        {'exerciseId': 'RcC48r0oLsNCH798d3jc', 'name': 'Butterfly Dumbbell Raise', 'circuitIndex': 1},
        {'exerciseId': '7x7nEW5Goq8fu8fggUNL', 'name': 'Straight Arm Lat Pull Down', 'circuitIndex': 1},
        {'exerciseId': 'ci3KpMTEacH4bw8ZumJW', 'name': 'Standing Calf Raise', 'circuitIndex': 1},
      ],
    };
    final male_b2d4 = {
      'name': 'B2 Day 4',
      'exercises': [
        {'exerciseId': 'ZKrfhPhJIiC1hRuwBEw1', 'name': 'Bayesian Fly', 'circuitIndex': 0},
        {'exerciseId': 'ewJBWuDzj1CxfQ3vI3QS', 'name': 'Reverse Bayesian Fly', 'circuitIndex': 0},
        {'exerciseId': 'ISXQqOEXLjMrPEs0xjgJ', 'name': 'Bulgarian Split Squat', 'circuitIndex': 0},
        {'exerciseId': '9siQpXF2KLCj7M9kCy2m', 'name': 'Seated Shoulder Dumbbell Press', 'circuitIndex': 1},
        {'exerciseId': 'zn5PgKNRrWo1MTE4wnCy', 'name': 'Bayesian Biceps Curl', 'circuitIndex': 1},
        {'exerciseId': 'QacImADmlpljltUvB0dD', 'name': 'Overhead Cable Triceps Extension', 'circuitIndex': 1},
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
        {'exerciseId': 'spGqXXReJNHMcc62YgZX', 'name': 'Seated Calf Raise', 'circuitIndex': 1},
        {'exerciseId': 'E6jPE8YYR0KA3xtVaKJo', 'name': 'Triceps Push Down', 'circuitIndex': 2},
        {'exerciseId': 'P88Vj5pBydqmiEzFowag', 'name': 'Hanging Straight Leg Raise', 'circuitIndex': 2},
      ],
    };

    final payloads = femaleEligible
        ? [female_b1d1, female_b1d2, female_b1d3, female_b1d4, female_b2d1, female_b2d2, female_b2d3, female_b2d4]
        : [male_b1d1, male_b1d2, male_b1d3, male_b1d4, male_b2d1, male_b2d2, male_b2d3, male_b2d4];

    debugPrint('🧰 [TB] prepared ${payloads.length} templates to create (branch=${femaleEligible ? 'FEMALE_13_30' : 'MALE_27_39'})');

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

        // 🧠 Tag each template with its intended block assignment
        if (t['name'].toString().startsWith('B1')) {
          toWrite['blockAssignment'] = 'B1';
        } else if (t['name'].toString().startsWith('B2')) {
          toWrite['blockAssignment'] = 'B2';
        } else {
          toWrite['blockAssignment'] = 'unspecified';
        }


        final docRef = templatesCol.doc();
        batch.set(docRef, toWrite);
        debugPrint('🧰 [TB] queued template "${t['name']}" (${filtered.length} exercises)');
      }

      batch.update(userRef, {
        _flagField: true,
        'templatesBootstrappedAt': FieldValue.serverTimestamp(),
        'templatesBranch': femaleEligible ? 'FEMALE_13_30' : 'MALE_27_39',
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
