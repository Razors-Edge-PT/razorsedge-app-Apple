import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'exercise_catalog.dart';

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


  // Same default RIR matrix used in Block_Planner._showStaticRirDialog.
  // Rows = sessions 1-4; columns = set1, set2, set3, set4 defaults.
  static const List<List<double>> _defaultRirMatrix = [
    [2.0, 2.0, 2.5, 3.0], // Session 1
    [2.0, 2.0, 2.5, 3.0], // Session 2
    [2.0, 2.0, 2.5, 3.5], // Session 3
    [2.5, 3.0, 3.0, 3.5], // Session 4
  ];

  /// Build week1/sessionX/set1..setN/rir+reps structure.
  /// [sets] controls how many set entries are written per session.
  /// [week1RepTargets] optionally provides per-instance rep strings ("9 x 3")
  /// so each set gets the correct reps value and per-session set count.
  static Map<String, dynamic> _buildRirPlan(
      dynamic rirTargetsRaw, {
      int sets = 3,
      Map<String, String>? week1RepTargets,
      }) {
    final rirTargets = (rirTargetsRaw as List).map((e) => e as num).toList();
    final weekMap = <String, dynamic>{};

    for (int i = 0; i < rirTargets.length; i++) {
      final patternIndex =
          i < _defaultRirMatrix.length ? i : i % _defaultRirMatrix.length;

      final instanceKey = 'instance${i + 1}';
      final repStr = week1RepTargets?[instanceKey] ?? '';
      final repMatch = RegExp(r'^(\d+)').firstMatch(repStr);
      final repsVal = repMatch?.group(1);
      final setsMatch = RegExp(r'x\s*(\d+)').firstMatch(repStr);
      final sessionSets = int.tryParse(setsMatch?.group(1) ?? '') ?? sets;

      final sessionMap = <String, dynamic>{};
      for (int s = 0; s < sessionSets; s++) {
        final setKey = 'set${s + 1}';
        final String setRir;
        if (s == 0) {
          setRir = rirTargets[i].toStringAsFixed(1);
        } else {
          final matrixRir = s < _defaultRirMatrix[patternIndex].length
              ? _defaultRirMatrix[patternIndex][s]
              : 3.0;
          setRir = matrixRir.toStringAsFixed(1);
        }
        sessionMap[setKey] = {
          'rir': setRir,
          if (repsVal != null) 'reps': repsVal,
        };
      }
      weekMap['session${i + 1}'] = sessionMap;
    }

    return {'week1': weekMap};
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
      final int defaultSets = (def['defaultSets'] as int?) ?? 3;
      final repTargets = _buildRepTargetMap(def['repTargets'], sets: defaultSets);
      return {
        'weeklyFrequency': def['weeklyFrequency'],
        'increments': _parseIncrements(def['increments']),
        'periodizationModel': def['periodizationModel'],
        'repTargets': repTargets,
        'rirModel': def['rirModel'],
        'rirPlan': _buildRirPlan(
          def['rirTargets'],
          sets: defaultSets,
          week1RepTargets: repTargets['week1'],
        ),
        'progressionModel': def['progressionModel'],
        'defaultSets': defaultSets,
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
  // 3b) USABILITY CHECK — distinguishes complete entries from partial fragments
  // ---------------------------------------------------------------------------

  /// Returns true when [settings] contains the minimum core fields required
  /// for the hint engine and settings dialog to function correctly.
  /// An entry that carries only week-N repTargets/rirPlan fragments but is
  /// missing core scalars (periodizationModel, weeklyFrequency, repTargets)
  /// is considered incomplete and returns false.
  static bool isSettingsUsable(Map<String, dynamic>? settings) {
    if (settings == null || settings.isEmpty) return false;
    final model = settings['periodizationModel'];
    if (model is! String || model.isEmpty) return false;
    final wf = settings['weeklyFrequency'];
    if (wf == null || (wf is num && wf <= 0)) return false;
    final repTargets = settings['repTargets'];
    if (repTargets is! Map || repTargets.isEmpty) return false;
    // For DUP By Exposure/Week: weeklyFrequency must equal the instanceN count
    // in repTargets.week1. A mismatch (e.g. wf=14 but only 2 instances) means
    // the data is corrupt and needs healing. Skipped for DUP Signature which
    // uses repRange instead of instanceN keys (instanceCount would be 0).
    if (model.startsWith('DUP') && repTargets is Map) {
      final week1 = repTargets['week1'];
      if (week1 is Map) {
        final instanceCount = week1.keys
            .where((k) => k.toString().startsWith('instance'))
            .length;
        if (instanceCount > 0 && instanceCount != (wf is num ? wf.toInt() : 0)) {
          return false;
        }
      }
    }
    return true;
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

  // ---------------------------------------------------------------------------
  // 5b) LAZY HEALER: ensure a single exercise has defaults in a block doc
  // ---------------------------------------------------------------------------

  /// Ensures [exerciseId] has complete, usable exerciseSettings in [blockId].
  /// No-op when settings are already complete (per [isSettingsUsable]).
  /// When settings are absent, writes the full default payload.
  /// When settings exist but are incomplete (e.g. only week-N fragments),
  /// writes only the missing top-level fields and missing sub-keys —
  /// existing values are never overwritten.
  static Future<void> ensureExerciseDefaults({
    required String uid,
    required String blockId,
    required String exerciseId,
  }) async {
    if (exerciseId.isEmpty || blockId.isEmpty) return;

    final docRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId);

    // 1. Check whether settings are already complete — skip if so.
    final snap = await docRef.get();
    final existing = snap.data()?['exerciseSettings'] as Map<String, dynamic>? ?? {};
    final existingForId = existing[exerciseId];
    if (existingForId is Map<String, dynamic> && isSettingsUsable(existingForId)) return;

    // 2. Fetch exercise metadata. Resolve global /exercises first, then fall
    //    back to this account's custom pool (/users/{uid}/customExercises) so
    //    custom exercise IDs get defaults just like global ones.
    final ex = await ExerciseCatalog.resolveExercise(
      exerciseId: exerciseId,
      uid: uid,
    );
    if (ex == null) return;

    final name = ex.name;
    final category = ex.category.isNotEmpty ? ex.category : 'Other';
    final bodyPart = ex.bodyPart;

    // 3. Compute defaults using the same logic as seedDefaultsForBlock.
    final defaults = getDefaultSettings(name, category, bodyPart);
    if (defaults.isEmpty) return;

    final repTargets = defaults['repTargets'];
    final savedTargets = repTargets is Map<String, Map<String, String>>
        ? repTargets
        : _convertToMap(repTargets);

    final detailPayload = {
      'periodizationModel': defaults['periodizationModel'],
      'repTargets': savedTargets,
      'rirPlan': defaults['rirPlan'],
      'rirModel': defaults['rirModel'],
      'progressionModel': defaults['progressionModel'],
      'increments': defaults['increments'],
      'weeklyFrequency': defaults['weeklyFrequency'],
      'maxWeightXReps': '',
      'notes': '',
    };

    final settingsPayload = {
      ...detailPayload,
      'defaultSets': defaults['defaultSets'],
      'modelSpecificRepTargets': defaults['modelSpecificRepTargets'],
    };

    // 4. Write: strategy depends on whether a partial entry already exists.
    if (existingForId == null) {
      // Fully absent: write the complete payload for both sub-collections.
      await docRef.set({
        'plannedExerciseDetails': {exerciseId: detailPayload},
        'exerciseSettings': {exerciseId: settingsPayload},
      }, SetOptions(merge: true));
    } else {
      // Partially present (e.g. only week-N repTargets/rirPlan fragments):
      // update only fields and sub-keys that are missing — never overwrite.
      //
      // Exception: weeklyFrequency, repTargets, and rirPlan are tightly coupled
      // (wf dictates how many instanceN keys must exist). When wf doesn't match
      // the computed defaults, all three are force-overwritten as a unit so they
      // stay self-consistent (e.g. wf=14 with only 2 instances → reset to 3/3/3).
      final existingMap = Map<String, dynamic>.from(existingForId);
      final existingWf = (existingMap['weeklyFrequency'] as num?)?.toInt() ?? 0;
      final defaultWf  = (settingsPayload['weeklyFrequency'] as num?)?.toInt() ?? 0;
      final wfMismatch = defaultWf > 0 && existingWf != defaultWf;

      final updates = <String, dynamic>{};
      settingsPayload.forEach((key, value) {
        final isCoupled =
            key == 'weeklyFrequency' || key == 'repTargets' || key == 'rirPlan';
        if (wfMismatch && isCoupled) {
          // Force-write the three coupled fields to make them self-consistent.
          updates['exerciseSettings.$exerciseId.$key'] = value;
        } else if (!existingMap.containsKey(key)) {
          // Top-level key entirely absent: write the full default value.
          updates['exerciseSettings.$exerciseId.$key'] = value;
        } else if (!isCoupled && value is Map && existingMap[key] is Map) {
          // Both are maps: only add sub-keys that are missing.
          final existingSub = Map<String, dynamic>.from(existingMap[key] as Map);
          (value as Map).forEach((subKey, subValue) {
            if (!existingSub.containsKey(subKey)) {
              updates['exerciseSettings.$exerciseId.$key.$subKey'] = subValue;
            }
          });
        }
        // Scalar field already present and not coupled: existing value wins — skip.
      });
      if (updates.isNotEmpty) {
        await docRef.update(updates);
      }
    }

    debugPrint('🩹 [DefaultsRepo] healed defaults for $exerciseId in block=$blockId');
  }

  // ---------------------------------------------------------------------------
  // 6) SELF-HEAL: fill missing week1 set entries for existing users
  // ---------------------------------------------------------------------------

  /// Inspects [settings] for one exercise and returns a healed rirPlan map
  /// (week1 only) if any session is missing set2/set3/etc entries.
  /// Returns null when the rirPlan is already complete — no Firestore write needed.
  /// Never overwrites existing rir values; only adds absent set keys and adds
  /// the 'reps' field to sets that lack it.
  static Map<String, dynamic>? healWeek1RirPlan(Map<String, dynamic> settings) {
    final repTargetsRaw = settings['repTargets'];
    if (repTargetsRaw is! Map) return null;

    final repWeek1Raw = repTargetsRaw['week1'];
    if (repWeek1Raw is! Map) return null;

    final sessionCount = repWeek1Raw.keys
        .where((k) => k.toString().startsWith('instance'))
        .length;
    if (sessionCount == 0) return null;

    final defaultSets = (settings['defaultSets'] as int?) ?? 3;
    bool changed = false;

    // Start from existing rirPlan if present; create from scratch if absent.
    final rirPlanRaw = settings['rirPlan'];
    final existingRirPlan = rirPlanRaw is Map
        ? Map<String, dynamic>.from(rirPlanRaw)
        : <String, dynamic>{};

    // Start from existing week1 if present; create from scratch if absent.
    final week1Raw = existingRirPlan['week1'];
    final patchedWeek1 = week1Raw is Map
        ? Map<String, dynamic>.from(week1Raw)
        : <String, dynamic>{};

    for (int i = 0; i < sessionCount; i++) {
      final sessionKey = 'session${i + 1}';
      final instanceKey = 'instance${i + 1}';
      final repStr = repWeek1Raw[instanceKey]?.toString() ?? '';

      final repMatch = RegExp(r'^(\d+)').firstMatch(repStr);
      final repsVal = repMatch?.group(1);
      final setsMatch = RegExp(r'x\s*(\d+)').firstMatch(repStr);
      final sessionSets = int.tryParse(setsMatch?.group(1) ?? '') ?? defaultSets;

      if (sessionSets <= 0) continue;

      final patternIndex =
          i < _defaultRirMatrix.length ? i : i % _defaultRirMatrix.length;
      final existingSessionRaw = patchedWeek1[sessionKey];
      final patchedSession = existingSessionRaw is Map
          ? Map<String, dynamic>.from(existingSessionRaw)
          : <String, dynamic>{};

      bool sessionChanged = false;

      for (int s = 0; s < sessionSets; s++) {
        final setKey = 'set${s + 1}';
        final existingSetRaw = patchedSession[setKey];
        final existingSet = existingSetRaw is Map
            ? Map<String, dynamic>.from(existingSetRaw)
            : null;

        if (existingSet == null) {
          // Entire set entry absent — create it.
          final int idx = s < _defaultRirMatrix[patternIndex].length
              ? s
              : _defaultRirMatrix[patternIndex].length - 1;
          final setRir = _defaultRirMatrix[patternIndex][idx].toStringAsFixed(1);
          patchedSession[setKey] = {
            'rir': setRir,
            if (repsVal != null) 'reps': repsVal,
          };
          sessionChanged = true;
        } else if (repsVal != null && !existingSet.containsKey('reps')) {
          // Set exists but lacks 'reps' — add it without touching 'rir'.
          existingSet['reps'] = repsVal;
          patchedSession[setKey] = existingSet;
          sessionChanged = true;
        }
        // Set is complete — leave it untouched.
      }

      if (sessionChanged) {
        patchedWeek1[sessionKey] = patchedSession;
        changed = true;
      }
    }

    if (!changed) return null;

    // Return the patched rirPlan; other weeks are preserved as-is.
    existingRirPlan['week1'] = patchedWeek1;
    return existingRirPlan;
  }

  /// Reads the active block's exerciseSettings, heals any sparse week1 rirPlan
  /// entries, and writes back only the changed rirPlan fields via a targeted
  /// Firestore update. Silently no-ops if all plans are already complete.
  static Future<void> healActiveBlockRirPlan({
    required String uid,
    required String blockId,
  }) async {
    try {
      final docRef = FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks')
          .doc(blockId);

      final snap = await docRef.get();
      if (!snap.exists) return;
      final data = snap.data();
      if (data == null) return;

      final rawSettings = data['exerciseSettings'];
      if (rawSettings is! Map) return;

      final exerciseSettings =
          Map<String, dynamic>.from(rawSettings);
      final updates = <String, dynamic>{};

      for (final entry in exerciseSettings.entries) {
        final exerciseId = entry.key;
        final settingsRaw = entry.value;
        if (settingsRaw is! Map) continue;
        final settings = Map<String, dynamic>.from(settingsRaw);
        final healedRirPlan = healWeek1RirPlan(settings);
        if (healedRirPlan != null) {
          updates['exerciseSettings.$exerciseId.rirPlan'] =
              _sanitizeForFirestore(healedRirPlan);
        }
      }

      if (updates.isEmpty) {
        print('✅ [DefaultsRepo] rirPlan already complete for block=$blockId');
        return;
      }

      print(
          '🩹 [DefaultsRepo] Healing rirPlan for ${updates.length} exercise(s) in block=$blockId');
      await docRef.update(updates);
      print('✅ [DefaultsRepo] rirPlan healed for block=$blockId');
    } catch (e) {
      print('❌ [DefaultsRepo] healActiveBlockRirPlan failed for block=$blockId: $e');
    }
  }
}
