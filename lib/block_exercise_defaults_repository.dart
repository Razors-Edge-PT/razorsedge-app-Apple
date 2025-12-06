import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

/// Shared defaults + seeding logic for Block Planner / WES.
/// This is the "headless" version of BP's _seedDefaultsFor + getDefaultSettings,
/// with no setState / BuildContext.
class BlockExerciseDefaultsRepository {
  // ---------------------------------------------------------------------------
  // 1) COPY YOUR DEFAULT MAPS FROM BP (EXACTLY)
  // ---------------------------------------------------------------------------

  /// 🔁 Named overrides (Bench, Squat, Deadlift etc.)
  static final Map<String, Map<String, dynamic>> _explicitDefaults = {
    // ⬇️ PASTE your _explicitDefaults from BP here, exactly as-is:
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
        'Linear, Classic': [15, 20, 16, 18],
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
        'Linear, Classic': [15, 19, 12],
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
        'Linear, Classic': [15, 18, 12, 13],
      },
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
      'rirTargets': [1.5, 2, 2, 0.5],
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

  /// 🔁 Category / group defaults.
  static final Map<String, Map<String, dynamic>> _defaultsByGroup = {
    // ⬇️ PASTE your _defaultsByGroup from BP here, exactly as-is:
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
    'Lateral Raise': {
      'weeklyFrequency': 3,
      'increments': '2.5',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [9, 13, 18],
      'rirModel': 'Static RIR',
      'rirTargets': [1.5, 1, 1],
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
      'increments': '2.5',
      'periodizationModel': 'DUP, By Exposure',
      'repTargets': [9, 14, 6, 18],
      'rirModel': 'Static RIR',
      'rirTargets': [1, 1, 1, 0.5],
      'defaultSets': 3,
      'progressionModel': 'Smart Progression',
    },
  };

  // ---------------------------------------------------------------------------
  // 2) COPY YOUR HELPERS FROM BP (EXACT IMPLEMENTATIONS)
  // ---------------------------------------------------------------------------

  /// Isolation logic – same as BP
  static bool _isIsolation(String bodyPart) {
    return bodyPart.split(',').length == 1;
  }


  /// Identical to BP: convert comma-separated increments into named keys.
  static Map<String, double> _parseIncrements(dynamic raw) {
    if (raw is String) {
      final parts = raw
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

    // Already valid → return as-is
    if (raw is Map<String, double>) {
      return raw;
    }

    // Null or invalid → default to 2.5 primary
    return {'primary': 2.5};
  }


  /// Build week1 → instanceX map like BP.
  /// Accepts dynamic so we can pass def['repTargets'] directly.
  static Map<String, Map<String, String>> _buildRepTargetMap(
      dynamic repsRaw, {
        int sets = 3,
      }) {
    // Normalise to List<int> just in case it's num or dynamic
    final reps = (repsRaw as List).map((e) => (e as num).toInt()).toList();

    final instanceMap = <String, String>{
      for (int i = 0; i < reps.length; i++)
        'instance${i + 1}': '${reps[i]} x $sets',
    };
    return {'week1': instanceMap};
  }


  /// Build week1/sessionX/set1/rir structure – same as BP.
  static Map<String, Map<String, Map<String, Map<String, String>>>> _buildRirPlan(
      dynamic rirTargetsRaw,
      ) {
    final rirTargets = (rirTargetsRaw as List).map((e) => e as num).toList();

    final weekMap = <String, Map<String, Map<String, String>>>{};

    for (int i = 0; i < rirTargets.length; i++) {
      weekMap['session${i + 1}'] = {
        'set1': {
          'rir': rirTargets[i].toStringAsFixed(1),
        },
      };
    }

    return {
      'week1': weekMap,
    };
  }


  /// Convert List / List<List<String>> into week/instance map – same as BP.
  static Map<String, Map<String, String>> _convertToMap(dynamic data) {
    if (data is List && data.isNotEmpty) {
      if (data.first is List) {
        // ✅ Convert List<List<String>> to Map<String, Map<String, String>>
        return {
          for (int week = 0; week < data.length; week++)
            'week${week + 1}': {
              for (int i = 0; i < data[week].length; i++)
                'instance${i + 1}': data[week][i],
            },
        };
      } else if (data.first is String) {
        // ✅ Flat list → assign to week1 with instance keys
        return {
          'week1': {
            for (int i = 0; i < data.length; i++)
              'instance${i + 1}': data[i],
          }
        };
      }
    }
    // ❌ Invalid or empty structure
    return {};
  }


  /// Sanitize values so Firestore is happy (no NaN, keys as strings, etc.)
  static dynamic _sanitizeForFirestore(dynamic value) {
    if (value is Map) {
      return value.map(
            (key, val) => MapEntry(key.toString(), _sanitizeForFirestore(val)),
      );
    } else if (value is List) {
      return value.map(_sanitizeForFirestore).toList();
    } else if (value is double && value.isNaN) {
      return 0; // Firestore can't store NaN
    }
    return value;
  }


  // ---------------------------------------------------------------------------
  // 3) getDefaultSettings – SAME LOGIC AS IN BP (NO CONTEXT)
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> getDefaultSettings(
      String name,
      String category,
      String bodyPart,
      ) {
    Map<String, dynamic> sanitize(Map<String, dynamic> def) {
      return {
        'weeklyFrequency': def['weeklyFrequency'],
        'increments': _parseIncrements(def['increments']),
        'periodizationModel': def['periodizationModel'],
        'repTargets': _buildRepTargetMap(
          def['repTargets'],
          sets: (def['defaultSets'] ?? 3),
        ),
        'rirModel': def['rirModel'],
        'rirPlan': _buildRirPlan(def['rirTargets']),
        'progressionModel': def['progressionModel'],
        'defaultSets': def['defaultSets'] ?? 3,
        'modelSpecificRepTargets': def['modelSpecificRepTargets'],
      };
    }

    // Tier 1: named overrides
    if (_explicitDefaults.containsKey(name)) {
      final def = _explicitDefaults[name]!;
      return sanitize(def);
    }

    // Tier 2: category
    if (_defaultsByGroup.containsKey(category)) {
      final def = _defaultsByGroup[category]!;
      return sanitize(def);
    }

    // Tier 3: isolation
    if (_isIsolation(bodyPart)) {
      final def = _defaultsByGroup['isolation']!;
      return sanitize(def);
    }

    return {};
  }

  // ---------------------------------------------------------------------------
  // 4) Firestore-only "onUpdateSetting" equivalent (no setState)
  // ---------------------------------------------------------------------------

  static Future<void> updateSingleSetting({
    required String uid,
    required String blockId,
    required String exerciseId,
    required String key,
    required dynamic value,
  }) async {
    final safeValue = _sanitizeForFirestore(value);

    final docRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId);

    print('📤 [DefaultsRepo] Writing $exerciseId → $key = ${jsonEncode(safeValue)}');

    await docRef.update({
      'exerciseSettings.$exerciseId.$key': safeValue,
    }).catchError((e) {
      print('❌ [DefaultsRepo] Failed to save $key for $exerciseId: $e');
    });
  }

  // ---------------------------------------------------------------------------
  // 5) MAIN ENTRY: seedDefaultsForBlock – this is what WES will call
  // ---------------------------------------------------------------------------

  static Future<void> seedDefaultsForBlock({
    required String uid,
    required String blockId,
    required List<String> exerciseIds,
  }) async {
    if (exerciseIds.isEmpty) return;

    print('🌱 [DefaultsRepo] Seeding defaults for block=$blockId (ex=${exerciseIds.length})');

    final docRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId);

    // 1) Fetch exercise meta (name, category, bodyPart) – same as BP _seedDefaultsFor
    final metaById = <String, Map<String, String>>{};
    final idsNeedingFetch = <String>[];

    for (final id in exerciseIds) {
      idsNeedingFetch.add(id);
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

        String bodyPart = '';
        final bp = d['bodyPart'];
        if (bp is List && bp.isNotEmpty) bodyPart = bp.first.toString();
        if (bp is String) bodyPart = bp;

        metaById[id] = {
          'name': name,
          'category': category,
          'bodyPart': bodyPart,
        };
      }
    }

    // 2) Build per-exercise defaults (same as BP, but in a local map)
    final Map<String, dynamic> newExerciseDetails = {};
    final Map<String, dynamic> newExerciseSettings = {};

    for (final id in exerciseIds) {
      final meta = metaById[id] ?? const {};
      final name = meta['name'] ?? '';
      final category = meta['category'] ?? 'Other';
      final bodyPart = meta['bodyPart'] ?? '';

      final defaults = getDefaultSettings(name, category, bodyPart);
      if (defaults.isEmpty) {
        print('⚠️ [DefaultsRepo] No defaults for $id ($name)');
        continue;
      }

      final repTargets = defaults['repTargets'];
      final rirPlan = defaults['rirPlan'];
      final periodizationModel = defaults['periodizationModel'];
      final weeklyFrequency = defaults['weeklyFrequency'];
      final progressionModel = defaults['progressionModel'];
      final increments = defaults['increments'];
      final rirModel = defaults['rirModel'];
      final defaultSets = defaults['defaultSets'];

      final savedTargets = repTargets is Map<String, Map<String, String>>
          ? repTargets
          : _convertToMap(repTargets);

      newExerciseDetails[id] = {
        'periodizationModel': periodizationModel,
        'repTargets': savedTargets,
        'rirPlan': rirPlan,
        'rirModel': rirModel,
        'progressionModel': progressionModel,
        'increments': increments,
        'weeklyFrequency': weeklyFrequency,
        'maxWeightXReps': '',
        'notes': '',
      };

      newExerciseSettings[id] = {
        ...newExerciseDetails[id] as Map<String, dynamic>,
        'defaultSets': defaultSets,
        'modelSpecificRepTargets': defaults['modelSpecificRepTargets'],
      };

      print('🌱 [DefaultsRepo] built defaults for $id ($name)');
    }

    // 3) Merge into existing block doc (preserve any existing data)
    final snapshot = await docRef.get();
    final data = snapshot.data() ?? {};

    final existingDetails = Map<String, dynamic>.from(
      data['plannedExerciseDetails'] ?? {},
    );
    final existingSettings = Map<String, dynamic>.from(
      data['exerciseSettings'] ?? {},
    );

    newExerciseDetails.forEach((id, payload) {
      existingDetails[id] = payload;
    });
    newExerciseSettings.forEach((id, payload) {
      final Map<String, dynamic> existing = Map<String, dynamic>.from(
        existingSettings[id] ?? {},
      );
      existing.addAll(payload as Map<String, dynamic>);
      existingSettings[id] = existing;
    });

    print('📤 [DefaultsRepo] Saving plannedExerciseDetails:\n${jsonEncode(existingDetails)}');
    print('📤 [DefaultsRepo] Saving exerciseSettings:\n${jsonEncode(existingSettings)}');

    await docRef.set({
      'plannedExerciseDetails': existingDetails,
      'exerciseSettings': existingSettings,
    }, SetOptions(merge: true));

    print('✅ [DefaultsRepo] Defaults seeded for block=$blockId');
  }
}
