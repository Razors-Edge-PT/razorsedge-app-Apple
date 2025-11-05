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

    // Branch eligibility
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

    // ---------------- PAYLOADS ----------------
    // Male payloads = your original
    final male_b1d1 = {
      'name': 'B1 Day 1',
      'exercises': [
        {'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'name': 'KP Face Pull', 'circuitIndex': 0},
        {'name': 'Back Squat, Barbell', 'circuitIndex': 0},
        {'name': 'Overhead Dumbbell Press', 'circuitIndex': 1},
        {'name': 'Lat Pull Down, Supinated', 'circuitIndex': 1},
        {'name': 'Lying Leg Curl', 'circuitIndex': 1},
      ],
    };
    final male_b1d2 = {
      'name': 'B1 Day 2',
      'exercises': [
        {'name': 'Flat Bench Dumbbell Press', 'circuitIndex': 0},
        {'name': 'Machine Row, Supported', 'circuitIndex': 0},
        {'name': '45 Degree Hip Extension', 'circuitIndex': 0},
        {'name': 'Overhead Barbell Press', 'circuitIndex': 1},
        {'name': 'Lat Pull Down, Wide Arm', 'circuitIndex': 1},
        {'name': 'Leg Extension', 'circuitIndex': 1},
      ],
    };
    final male_b1d3 = {
      'name': 'B1 Day 3',
      'exercises': [
        {'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'name': 'KP Face Pull', 'circuitIndex': 0},
        {'name': 'Back Squat, Barbell', 'circuitIndex': 0},
        {'name': 'Cable Lateral Raise', 'circuitIndex': 1},
        {'name': 'Bench Lat Pull Down, Straight Arm', 'circuitIndex': 1},
        {'name': 'Triceps Push down', 'circuitIndex': 1},
      ],
    };
    final male_b1d4 = {
      'name': 'B1 Day 4',
      'exercises': [
        {'name': 'Leg Press', 'circuitIndex': 0},
        {'name': 'Seated Shoulder Dumbbell Press', 'circuitIndex': 1},
        {'name': 'Dumbbell Biceps Curl', 'circuitIndex': 1},
        {'name': 'Standing Calf Raise', 'circuitIndex': 1},
      ],
    };
    final male_b2d1 = {
      'name': 'B2 Day 1',
      'exercises': [
        {'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'name': 'Suspended High Row', 'circuitIndex': 0},
        {'name': 'Back Squat, Barbell', 'circuitIndex': 0},
        {'name': 'Overhead Dumbbell Press, Unilateral', 'circuitIndex': 1},
        {'name': 'Lat Pull Down, Unilateral', 'circuitIndex': 1},
        {'name': 'Seated Leg Curl', 'circuitIndex': 1},
      ],
    };
    final male_b2d2 = {
      'name': 'B2 Day 2',
      'exercises': [
        {'name': 'Incline Bench Dumbbell Press', 'circuitIndex': 0},
        {'name': 'One Arm Row, Dumbbell', 'circuitIndex': 0},
        {'name': 'Romanian Deadlift', 'circuitIndex': 0},
        {'name': 'Overhead Barbell Press', 'circuitIndex': 1},
        {'name': 'Lat Pull Down, Wide Arm', 'circuitIndex': 1},
        {'name': 'Leg Extension, Unilateral', 'circuitIndex': 1},
      ],
    };
    final male_b2d3 = {
      'name': 'B2 Day 3',
      'exercises': [
        {'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'name': 'Cable High Row, Unilateral', 'circuitIndex': 0},
        {'name': 'Back Squat, Barbell', 'circuitIndex': 0},
        {'name': 'Butterfly Dumbbell Raise', 'circuitIndex': 1},
        {'name': 'Bench Lat Pull Down, Straight Arm', 'circuitIndex': 1},
        {'name': 'Standing Calf Raise', 'circuitIndex': 1},
      ],
    };
    final male_b2d4 = {
      'name': 'B2 Day 4',
      'exercises': [
        {'name': 'Bayesian Fly', 'circuitIndex': 0},
        {'name': 'Reverse Bayesian Fly', 'circuitIndex': 0},
        {'name': 'Bulgarian Split Squat', 'circuitIndex': 0},
        {'name': 'Seated Shoulder Dumbbell Press', 'circuitIndex': 1},
        {'name': 'Bayesian Biceps Curl', 'circuitIndex': 1},
        {'name': 'Overhead Cable Triceps Extension', 'circuitIndex': 1},
      ],
    };

    // Female payloads (from your screenshots; explicit circuitIndex)
    final female_b1d1 = {
      'name': 'B1 Day 1',
      'exercises': [
        {'name': 'Machine Chest Press', 'circuitIndex': 0},
        {'name': 'Lying Leg Curl', 'circuitIndex': 0},
        {'name': 'Back Squat, Barbell', 'circuitIndex': 0},
        {'name': 'Lat Pull Down, Supinated', 'circuitIndex': 1},
        {'name': 'Machine Hip Thrust', 'circuitIndex': 1},
        {'name': 'SpiderGirl Plank', 'circuitIndex': 1},
        {'name': 'Cable Biceps Curl', 'circuitIndex': 2},
        {'name': 'Overhead Cable Triceps Extension', 'circuitIndex': 2},
      ],
    };
    final female_b1d2 = {
      'name': 'B1 Day 2',
      'exercises': [
        {'name': 'Machine Shoulder Press, Pronated', 'circuitIndex': 0},
        {'name': '45 Degree Hip Extension', 'circuitIndex': 0},
        {'name': 'Leg Extension', 'circuitIndex': 0},
        {'name': 'Machine Row, Supported', 'circuitIndex': 1},
        {'name': 'Hip Thrust, Unilateral', 'circuitIndex': 1},
        {'name': 'Hanging Knee Raise', 'circuitIndex': 1},
        {'name': 'Triceps Dip Machine', 'circuitIndex': 2},
        {'name': 'Machine Hip Abduction', 'circuitIndex': 2},
      ],
    };
    final female_b1d3 = {
      'name': 'B1 Day 3',
      'exercises': [
        {'name': 'Flat Bench Dumbbell Press', 'circuitIndex': 0},
        {'name': 'Cable One Arm Row', 'circuitIndex': 0},
        {'name': 'Leg Press', 'circuitIndex': 0},
        {'name': 'Machine Hip Thrust', 'circuitIndex': 1},
        {'name': 'Cable Biceps Curl', 'circuitIndex': 1},
        {'name': 'Bicycle Crunch', 'circuitIndex': 1},
        {'name': 'Machine Hip Adduction', 'circuitIndex': 2},
        {'name': 'Leg Press Calf Raise', 'circuitIndex': 2},
      ],
    };
    final female_b1d4 = {
      'name': 'B1 Day 4',
      'exercises': [
        {'name': 'Machine Shoulder Press, Pronated', 'circuitIndex': 0},
        {'name': 'Lat Pull Down, Wide Arm', 'circuitIndex': 0},
        {'name': 'Barbell Hip Thrust', 'circuitIndex': 0},
        {'name': 'Seated Shoulder Dumbbell Press', 'circuitIndex': 1},
        {'name': 'Machine Hip Abduction', 'circuitIndex': 1},
        {'name': 'Seated Calf Raise', 'circuitIndex': 1},
        {'name': 'Triceps Dip Machine', 'circuitIndex': 2},
        {'name': 'Hanging Knee Raise', 'circuitIndex': 2},
      ],
    };
    final female_b2d1 = {
      'name': 'B2 Day 1',
      'exercises': [
        {'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'name': 'Seated Leg Curl', 'circuitIndex': 0},
        {'name': 'Back Squat, Barbell', 'circuitIndex': 0},
        {'name': 'Straight Arm Lat Pull Down', 'circuitIndex': 1},
        {'name': 'Barbell Hip Thrust', 'circuitIndex': 1},
        {'name': 'Long Lever Plank', 'circuitIndex': 1},
        {'name': 'Glute Cable Kick Back', 'circuitIndex': 2},
        {'name': 'Overhead Cable Triceps Extension, Unilateral', 'circuitIndex': 2},
      ],
    };
    final female_b2d2 = {
      'name': 'B2 Day 2',
      'exercises': [
        {'name': 'Flat Bench Dumbbell Press', 'circuitIndex': 0},
        {'name': 'Romanian Deadlift', 'circuitIndex': 0},
        {'name': 'Leg Extension, Unilateral', 'circuitIndex': 0},
        {'name': 'Seated Row, Cable', 'circuitIndex': 1},
        {'name': 'Hip Thrust, Unilateral', 'circuitIndex': 1},
        {'name': 'Hanging Straight Leg Raise', 'circuitIndex': 1},
        {'name': 'Machine Hip Adduction', 'circuitIndex': 2},
        {'name': 'Machine Hip Abduction', 'circuitIndex': 2},
      ],
    };
    final female_b2d3 = {
      'name': 'B2 Day 3',
      'exercises': [
        {'name': 'Bench Press, Barbell', 'circuitIndex': 0},
        {'name': 'Cable One Arm Row', 'circuitIndex': 0},
        {'name': 'Hack Squat', 'circuitIndex': 0},
        {'name': 'Barbell Hip Thrust', 'circuitIndex': 1},
        {'name': 'Dumbbell Biceps Curl', 'circuitIndex': 1},
        {'name': 'Decline Crunch', 'circuitIndex': 1},
        {'name': 'Overhead Cable Triceps Extension', 'circuitIndex': 2},
        {'name': 'Standing Calf Raise', 'circuitIndex': 2},
      ],
    };
    final female_b2d4 = {
      'name': 'B2 Day 4',
      'exercises': [
        {'name': 'Overhead Barbell Press', 'circuitIndex': 0},
        {'name': 'Lat Pull Down, Unilateral', 'circuitIndex': 0},
        {'name': 'Machine Hip Thrust', 'circuitIndex': 0},
        {'name': 'Seated Shoulder Dumbbell Press', 'circuitIndex': 1},
        {'name': 'Seated Calf Raise', 'circuitIndex': 1},
        {'name': 'Triceps Push Down', 'circuitIndex': 2},
        {'name': 'Hanging Straight Leg Raise', 'circuitIndex': 2},
      ],
    };

    final payloads = femaleEligible
        ? [female_b1d1, female_b1d2, female_b1d3, female_b1d4, female_b2d1, female_b2d2, female_b2d3, female_b2d4]
        : [male_b1d1, male_b1d2, male_b1d3, male_b1d4, male_b2d1, male_b2d2, male_b2d3, male_b2d4];

    debugPrint('🧰 [TB] prepared ${payloads.length} templates to create '
        '(branch=${femaleEligible ? 'FEMALE_13_30' : 'MALE_27_39'})');

    try {
      final batch = FirebaseFirestore.instance.batch();
      for (final t in payloads) {
        final docRef = templatesCol.doc();
        batch.set(docRef, t);
        debugPrint('🧰 [TB] queued template "${t['name']}" (${(t['exercises'] as List).length} exercises)');
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
