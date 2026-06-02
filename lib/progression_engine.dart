//progression_engine.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:core';
import 'package:firebase_auth/firebase_auth.dart';
import 'periodization_model_utils.dart'; // your existing utils
import 'dart:convert'; // for jsonEncode in debug logs


/// Simple getter callbacks for values WES used to read from controllers/state.
typedef WeightTextAt = String Function(int exerciseIndex, int setIndex);
typedef RirTextAt = String Function(int exerciseIndex, int setIndex);

/// Function types for helpers that existed in WES.
typedef RowKeyBy = String Function(int exerciseIndex);
typedef RowCacheKey = String Function(int exerciseIndex);
typedef GetApplicableWeekIndex = int? Function(String exerciseId);
typedef GetRirFromPlanOrInput = double Function(int exerciseIndex, int setNumber);
typedef DebugPrintBlockDates = void Function();

class ProgressionEngineInputs {
  final DateTime? blockStartDate;
  final DateTime? blockEndDate;
  final DateTime? selectedDate;
  final String?   cachedUid;

  final List<Map<String, dynamic>> selectedExercisesWithCircuits;
  final Map<String, dynamic>       exerciseSettings;
  final Map<String, Map<String, dynamic>> cachedProgressedValues;
  final Map<String, dynamic>       seedHintsByKey;
  final Map<String, Map<String, dynamic>> resolvedBB2Values;  // 👈 added

  final RowKeyBy rowKeyBy;
  final RowCacheKey rowCacheKey;
  final GetApplicableWeekIndex getApplicableWeekIndex;
  final GetRirFromPlanOrInput getRirFromPlanOrInput;

  final WeightTextAt weightTextAt; // replaces direct _weightControllers[..][0].text
  final RirTextAt    rirTextAt;    // replaces direct _rirControllers[..][0].text

  final void Function()? debugPrintBlockDates; // optional

  const ProgressionEngineInputs({
    required this.blockStartDate,
    required this.blockEndDate,
    required this.selectedDate,
    required this.cachedUid,
    required this.selectedExercisesWithCircuits,
    required this.exerciseSettings,
    required this.cachedProgressedValues,
    required this.seedHintsByKey,
    required this.resolvedBB2Values,   // 👈 added
    required this.rowKeyBy,
    required this.rowCacheKey,
    required this.getApplicableWeekIndex,
    required this.getRirFromPlanOrInput,
    required this.weightTextAt,
    required this.rirTextAt,
    this.debugPrintBlockDates,
  });
}

/// Engine wrapper so we can keep a method signature similar to WES.
class ProgressionEngine {
  ProgressionEngine(this.i);

  final ProgressionEngineInputs i;



  /// Resolves which DUP instance is active today and returns the raw rep-target string.
  ///
  /// byWeek=false → DUP By Exposure: counts completions in [blockStart, today).
  ///   plannedCountBefore is added before modding (for same-exercise siblings in a session).
  /// byWeek=true  → DUP By Week: counts completions in [weekStart, today).
  ///   plannedCountBefore should always be 0 (WES rule for weekly DUP).
  ///
  /// Returns null when sorted is empty or blockStartDate / selectedDate is null.
  static ({int instanceIndex, int instanceNumber, String raw, int completedCount, Set<String> matchedDates})?
      resolveDupActiveInstance({
    required String exerciseId,
    required String exerciseName,
    required DateTime? blockStartDate,
    required DateTime? selectedDate,
    required int weekIndex,
    required List<MapEntry<String, dynamic>> sorted,
    required int plannedCountBefore,
    required bool byWeek,
  }) {
    if (sorted.isEmpty || blockStartDate == null || selectedDate == null) return null;

    int completedCount = 0;
    final matchedDates = <String>{};

    try {
      final base = DateTime(blockStartDate.year, blockStartDate.month, blockStartDate.day);
      final todayStart = DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
      final windowStart = byWeek ? base.add(Duration(days: weekIndex * 7)) : base;

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
        final sets = (setsRaw is List) ? setsRaw.cast<Map>() : const <Map>[];
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
        if (dayOnly.isBefore(windowStart) || !dayOnly.isBefore(todayStart)) continue;

        final exs = w['exercises'];
        if (exs is! List) continue;

        final matched = exs.any((ex) {
          if (!hasValidSet(ex['sets'])) return false;

          final exId = (ex['exerciseId'] ?? ex['id'] ?? ex['exercise_id'] ?? '').toString();
          if (exId.isNotEmpty && exId == targetId) return true;

          final exName = (ex['name'] ?? ex['exercise'] ?? ex['title'] ?? '').toString();
          if (exName.isNotEmpty && norm(exName) == targetNameNorm) return true;

          final mapped = (PeriodizationModelUtils.nameToId[exName] ?? '').toString();
          return mapped.isNotEmpty && mapped == targetId;
        });

        if (matched) {
          matchedDates.add(dateStr.length >= 10 ? dateStr.substring(0, 10) : dateStr);
        }
      }

      completedCount = matchedDates.length;
    } catch (e) {}

    final plannedIndex = completedCount + (byWeek ? 0 : plannedCountBefore);
    final index = plannedIndex % sorted.length;
    final raw = sorted[index].value?.toString() ?? '';

    return (
      instanceIndex: index,
      instanceNumber: index + 1,
      raw: raw,
      completedCount: completedCount,
      matchedDates: matchedDates,
    );
  }

  /// Public method you can call from WarmupServices or anywhere else.
  static Map<String, dynamic> engineProgressedValues(
      ProgressionEngineInputs i,
      int exerciseIndex,
      ) {
    // --- Local aliases so the pasted body can stay as intact as possible ---
    final DateTime? blockStartDate = i.blockStartDate;
    final DateTime? blockEndDate = i.blockEndDate;
    final DateTime? _selectedDate = i.selectedDate;
    final String? _cachedUid = i.cachedUid;

    final _selectedExercisesWithCircuits = i.selectedExercisesWithCircuits;
    final Map<String, dynamic> _exerciseSettings = i.exerciseSettings;
    final Map<String, Map<String, dynamic>> _cachedProgressedValues = i.cachedProgressedValues;
    final Map<String, dynamic> _seedHintsByKey = i.seedHintsByKey;

    final RowKeyBy _rowKeyBy = i.rowKeyBy;
    final RowCacheKey _rowCacheKey = i.rowCacheKey;
    final GetApplicableWeekIndex _getApplicableWeekIndex = i.getApplicableWeekIndex;
    final GetRirFromPlanOrInput getRirFromPlanOrInput = i.getRirFromPlanOrInput;

    String weightTextAt(int exIdx, int setIdx) => i.weightTextAt(exIdx, setIdx);
    String rirTextAt(int exIdx, int setIdx) => i.rirTextAt(exIdx, setIdx);

    void _debugPrintBlockDates() => i.debugPrintBlockDates?.call();
    print('[ENGINE] resolvedBB2Values dump = '
        '${i.resolvedBB2Values.map((k,v) => MapEntry(k, v.toString()))}');
// DEBUG: show the seed hint that came from Isar → WES → _seedHintsByKey for this row
    final _seedKeyDbg = _rowKeyBy(exerciseIndex);
    final _seedDbg = _seedHintsByKey[_seedKeyDbg];
    print('[ENGINE][seed] row=$exerciseIndex key=$_seedKeyDbg → '
        '${_seedDbg == null ? '∅' : jsonEncode(_seedDbg)}');


    // -------------------- BEGIN: original function body --------------------
    // 🧠 STEP 1: If we already cached a GOOD value, return it
    final key = _rowCacheKey(exerciseIndex);
    final cached = _cachedProgressedValues[key];
    if (cached != null && blockStartDate != null && blockEndDate != null) {
      // derive name/id locally for this early-return path
      final cachedName = (_selectedExercisesWithCircuits[exerciseIndex]['name']?.toString() ?? '').trim();
      final cachedId   = (PeriodizationModelUtils.nameToId[cachedName] ?? cachedName).toString();

      // look up BB2 overrides by id, then fall back to lowercased name
      Map<String, dynamic>? overrides = i.resolvedBB2Values[cachedId];
      overrides ??= i.resolvedBB2Values[cachedName.toLowerCase()];

      if (overrides != null) {
        print('🧮 [ENGINE] (cache) Final for $cachedName = '
            '${cached['weight']}kg @ ${cached['reps']} reps, RIR ${cached['rir']} '
            '|| BB2 overrides → weight=${overrides['weight']}, reps=${overrides['reps']}, rir=${overrides['rir']}');
      } else {
        print('🧮 [ENGINE] (cache) Final for $cachedName = '
            '${cached['weight']}kg @ ${cached['reps']} reps, RIR ${cached['rir']} '
            '|| BB2 overrides → none');
      }
      return cached;
    }


    // 🔹 NEW: if we have seeded hints, use them for the very first paint
    final seedKey = _rowKeyBy(exerciseIndex);
    final seed = _seedHintsByKey[seedKey];


    if (seed != null) {
      final exName = _selectedExercisesWithCircuits[exerciseIndex]['name']?.toString() ?? '';
      final exId = PeriodizationModelUtils.nameToId[exName] ?? exName;
      final isBw = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: exName);

      double? absW = (seed['s1_weight'] as num?)?.toDouble();
      final double? addedW = (seed['s1_weight_added'] as num?)?.toDouble();
      if (absW == null && addedW != null) {
        absW = isBw
            ? PeriodizationModelUtils.toAbsoluteWeight(
          uid: _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ?? '',
          displayAddedKg: addedW,
          exerciseId: exId,
          exerciseName: exName,
          asOfDate: _selectedDate,
        )
            : addedW;
      }
      absW ??= 20.0;

      final double? seedRir = (seed['s1_rir'] as num?)?.toDouble();

      final seeded = <String, dynamic>{
        'exerciseName': exName,
        'exerciseId': exId,
        'weight': absW,                                   // absolute kg
        'reps': (seed['s1_reps'] as num?)?.toDouble() ?? 10.0,
        'rir': seedRir ?? 1.0,                            // add this line
      };

      print('[ENGINE][seed→use] row=$exerciseIndex '
          'name=$exName id=$exId abs=${absW?.toStringAsFixed(2)} '
          'disp=${(seed['s1_weight_added'] as num?)?.toString()} '
          'reps=${(seed['s1_reps'] as num?)?.toString()} '
          'rir=${(seed['s1_rir'] as num?)?.toString()}');


      _cachedProgressedValues[_rowCacheKey(exerciseIndex)] = seeded;
      return seeded;
    }
    if (cached != null && blockStartDate != null && blockEndDate != null) {
      final cachedName = _selectedExercisesWithCircuits[exerciseIndex]['name']?.toString() ?? '';
      print('🧮 [ENGINE] (cache) Final for $cachedName = ${cached['weight']}kg @ ${cached['reps']} reps, RIR ${cached['rir']}');
      return cached;
    }

    // Avoid caching placeholders before core meta/history land
    if (blockStartDate == null || _selectedDate == null || PeriodizationModelUtils.savedWorkoutsList.isEmpty) {
      final exName = _selectedExercisesWithCircuits[exerciseIndex]['name']?.toString().trim() ?? '';
      final exId   = PeriodizationModelUtils.nameToId[exName] ?? exName;
      print('⏳ [ENGINE] delaying progressed calc; meta/history not ready');
      return {
        'exerciseName': exName,
        'exerciseId'  : exId,
        'weight'      : 20.0,
        'reps'        : 10.0,
        'rir'         : 17.9,
      };
    }


    _debugPrintBlockDates();
      // Get exercise info.
      final exerciseName =
          _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
      final rawExId = ((_selectedExercisesWithCircuits[exerciseIndex]['exerciseId']
          ?? _selectedExercisesWithCircuits[exerciseIndex]['id']) as String?)?.trim() ?? '';
      final exerciseId = rawExId.isNotEmpty
          ? rawExId
          : PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
      final uidForBw = _cachedUid ?? FirebaseAuth.instance.currentUser?.uid ??
          '';

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
      PeriodizationModelType? model =
          PeriodizationModelUtils.exercisePeriodizationModels[exerciseId];
      if (model == null) {
        final pmStr = _exerciseSettings[exerciseId]?['periodizationModel'] as String?;
        if (pmStr != null && pmStr.isNotEmpty) {
          model = PeriodizationModelUtils.stringToModel(pmStr);
        }
      }

      if (model == PeriodizationModelType.dailyUndulatingExposure) {
        // (Assuming your existing model-specific logic is used here)
        final fullDetails = _exerciseSettings[exerciseId];
        final week1 = fullDetails?['repTargets']?['week1'];

        if (week1 is Map<String, dynamic>) {
          final sorted = week1.entries
              .where((e) => e.key.startsWith('instance'))
              .toList()
            ..sort((a, b) => a.key.compareTo(b.key));
          if (sorted.isNotEmpty) {
            final expRes = resolveDupActiveInstance(
              exerciseId: exerciseId,
              exerciseName: exerciseName,
              blockStartDate: blockStartDate,
              selectedDate: _selectedDate,
              weekIndex: weekIndex ?? 0,
              sorted: sorted,
              plannedCountBefore: plannedCountBefore,
              byWeek: false,
            );
            final raw = expRes?.raw ?? '';
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
            weightText: weightTextAt(exerciseIndex, 0),
            rirText: rirTextAt(exerciseIndex, 0),
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
              final wkRes = resolveDupActiveInstance(
                exerciseId: exerciseId,
                exerciseName: exerciseName,
                blockStartDate: blockStartDate,
                selectedDate: _selectedDate,
                weekIndex: weekIndex ?? 0,
                sorted: sorted,
                plannedCountBefore: 0,
                byWeek: true,
              );
              final raw = wkRes?.raw ?? '';
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
      } else if (model == PeriodizationModelType.linearClassic) {
        final repTargets = _exerciseSettings[exerciseId]?['repTargets'];

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
                (startReps +
                    ((endReps - startReps) * (week / (blockLength - 1))))
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
          weightText: weightTextAt(exerciseIndex, 0),
          rirText: rirTextAt(exerciseIndex, 0),
          weekIndex: weekIndex,
        ).toDouble();
      }

      // Get the progression model info.
      final String? progressionModelName = _exerciseSettings[exerciseId]?['progressionModel'];

      final progressionModel =
      PeriodizationModelUtils.parseProgressionModel(progressionModelName);
      final double rir = getRirFromPlanOrInput(exerciseIndex, 1);

    print('[ENGINE][plan] row=$exerciseIndex name=$exerciseName '
        'repTarget=${repTarget.toStringAsFixed(1)} '
        'rir=${rir.toStringAsFixed(2)} model=$progressionModelName');
// ——— apply reps/RIR overrides BEFORE computing weight ———
    var _ovr = i.resolvedBB2Values[exerciseId] ?? i.resolvedBB2Values[exerciseName.toLowerCase().trim()];
    final double repTargetEff = (_ovr?['reps'] is num && (_ovr!['reps'] as num) > 0)
        ? (_ovr['reps'] as num).toDouble()
        : repTarget;
    final double rirEff = (_ovr != null && _ovr.containsKey('rir') && _ovr['rir'] is num)
        ? (_ovr['rir'] as num).toDouble()
        : rir;


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

// 🔒 PATCH: normalize increments for snapping everywhere

    final List<double> _incOpts =
    (increments == null || increments.isEmpty) ? <double>[2.5] : increments;

      final maxWeightMap = _exerciseSettings[exerciseId]?['maxWeightByReps'];
      final maxWeightKeys = (maxWeightMap is Map)
          ? maxWeightMap.keys.toList()
          : 'null';

      final Map<String, dynamic> progressed =
      PeriodizationModelUtils.getWeightByProgressionModel(
        model: progressionModel,
        exerciseName: exerciseName,
        repTarget: repTarget.toInt(),
        defaultWeight: defaultWeight,
        rirValue: rir,
        increments: increments ?? [2.5],
        debugOrigin: 'ENGINE',

        // ✅ fallback
        maxWeightByReps: _exerciseSettings[exerciseId]?['maxWeightByReps'],
        // exerciseId-first lookup: history is now keyed by exerciseId when the
        // workout document carried one. Fall back to name for legacy rows that
        // were stored without an id (they remain under a name key).
        topSetHistory: PeriodizationModelUtils.topSetsByExercise[exerciseId]
            ?? PeriodizationModelUtils.topSetsByExercise[exerciseName],
        weekIndex: (blockStartDate == null || _selectedDate == null)
            ? 0 // safe default until initialized
            : PeriodizationModelUtils.getWeekIndexForDate(
          _selectedDate,
          blockStartDate!,
        ),
      );

    // --- DEBUG: show the exact e1RM used by the model ---
    final debugE1 = progressed['__debug_e1rm'];
    if (debugE1 is num) {
      final wk = (blockStartDate == null || _selectedDate == null)
          ? 0
          : PeriodizationModelUtils.getWeekIndexForDate(_selectedDate!, blockStartDate!);
      print('🧪 [ENGINE/e1RM] $exerciseName → e1RM=${debugE1.toStringAsFixed(2)} '
          '(repTarget=${repTarget.toInt()}, RIR=${rir.toStringAsFixed(2)}, wk=$wk)');
    } else {
      // Fallback: approximate from returned working weight if PMU didn’t surface e1RM
      final w = (progressed['weight'] as num?)?.toDouble();
      if (w != null) {
        try {
          final approx = PeriodizationModelUtils.calculateE1RM(
            w,
            repTarget.toDouble(),
            rir,
          );
          print('🧪 [ENGINE/e1RM≈] $exerciseName → approx=${approx.toStringAsFixed(2)} '
              '(repTarget=${repTarget.toInt()}, RIR=${rir.toStringAsFixed(2)})');
        } catch (_) {/* silent */}
      }
    }


    // as-of date for BW lookups = the day being edited in WES
      final DateTime _asOfDate = _selectedDate ?? DateTime.now();

      final target = (progressed['weight'] as num).toDouble();
    // Baseline e1RM from the pre-override plan calc (keep this constant for reps/RIR overrides)
    final double _baselineE1rm =
    (progressed['__debug_e1rm'] is num)
        ? (progressed['__debug_e1rm'] as num).toDouble()
        : PeriodizationModelUtils.calculateE1RM(
      target,
      repTarget.toDouble(),
      rir,
    );


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
        asOfDate: _asOfDate,
      );

      // snap on ADDED
      double _snappedAdded = _incOpts.reduce(
            (a, b) => (a - _targetAdded).abs() < (b - _targetAdded).abs() ? a : b,
      );
      if (_snappedAdded < 0) _snappedAdded = 0.0;

      // ADDED → ABS
      snapped = PeriodizationModelUtils.toAbsoluteWeight(
        uid: uidForBw,
        displayAddedKg: _snappedAdded,
        exerciseId: exerciseId,
        exerciseName: exerciseName,
      );

      progressed['weightDisplayAdded'] = _snappedAdded;
    } else {
      // non-BW: snap absolute
      snapped = _incOpts.reduce(
            (a, b) => (a - target).abs() < (b - target).abs() ? a : b,
      );
      // (leaving your displayAdded mirror as-is)
      progressed['weightDisplayAdded'] = snapped;
    }


    // write back absolute weight as before
// write back absolute weight as before
    progressed['weight'] = snapped;

// ✅ also persist the plan-derived reps & rir so they exist even without overrides
    progressed['reps'] = repTarget.toInt();
    progressed['rir']  = rir;

    // Cache and return
    progressed['exerciseName'] = exerciseName;
    progressed['exerciseId'] = exerciseId;
    final canCache = (blockStartDate != null) &&
        (_selectedDate != null) &&
        (PeriodizationModelUtils.savedWorkoutsList.isNotEmpty);


    // === Overlay with BB2 / user-entered values if available ===
    var overrides = i.resolvedBB2Values[exerciseId];
    if (overrides == null) {
      final lowerName = exerciseName.toLowerCase().trim();
      overrides = i.resolvedBB2Values[lowerName];
    }

    if (overrides != null) {
      print('[ENGINE] applying overrides for $exerciseName → $overrides');


      // BW: prefer addedWeight override → convert to absolute and snap on ADDED
      double? _overrideAbsFromAdded;
      if (_isBwEx && overrides['addedWeight'] is num) {
        double _added = (overrides['addedWeight'] as num).toDouble();
        if (_added < 0) _added = 0.0;

        // snap on ADDED using increments
        double _snappedAdded = _incOpts.reduce(
              (a, b) => (a - _added).abs() < (b - _added).abs() ? a : b,
        );
        if (_snappedAdded < 0) _snappedAdded = 0.0;

        // ADDED → ABS
        final double _abs = PeriodizationModelUtils.toAbsoluteWeight(
          uid: uidForBw,
          displayAddedKg: _snappedAdded,
          exerciseId: exerciseId,
          exerciseName: exerciseName,
          asOfDate: _asOfDate,
        );

        progressed['weightDisplayAdded'] = _snappedAdded;
        progressed['weight'] = _abs;
        _overrideAbsFromAdded = _abs;
      }

      // Weight: only apply if a positive number was supplied (never allow 0 here)
      final ow = overrides['weight'];

      // If BW exercise and user typed into the weight box, treat it as ADDED kg
      double? _bwAbsFromWeightAsAdded;
      double? _bwSnappedAddedFromWeight;
      if (_isBwEx && ow is num && ow > 0 && !(overrides['addedWeight'] is num)) {
        double _added = ow.toDouble();
        // snap on ADDED
        double _snappedAdded = _incOpts.reduce(
              (a, b) => (a - _added).abs() < (b - _added).abs() ? a : b,
        );
        if (_snappedAdded < 0) _snappedAdded = 0.0;
        // ADDED → ABS with bodyweight as-of date
        final double _abs = PeriodizationModelUtils.toAbsoluteWeight(
          uid: uidForBw,
          displayAddedKg: _snappedAdded,
          exerciseId: exerciseId,
          exerciseName: exerciseName,
          asOfDate: _asOfDate,
        );
        _bwSnappedAddedFromWeight = _snappedAdded;
        _bwAbsFromWeightAsAdded   = _abs;
        // mirror to progressed
        progressed['weightDisplayAdded'] = _snappedAdded;
        progressed['weight']             = _abs;
      }


      final orp = overrides['reps'];
      final bool _repsChanged = (orp is num && orp > 0);
      final bool _rirChanged = overrides.containsKey('rir') && (overrides['rir'] is num);
      final bool _hasUserWeight = (ow is num && ow > 0) || (_bwAbsFromWeightAsAdded != null);
      final bool _needSolve = !_hasUserWeight && (_repsChanged || _rirChanged);



      if (ow is num && ow > 0 && !_isBwEx) {
        progressed['weight'] = ow.toDouble();
      }


      // Reps: only apply if a positive integer was supplied (never allow 0 here)

      if (orp is num && orp > 0) {
        progressed['reps'] = orp.toDouble(); // keep as double for consistency with elsewhere
      }

      // RIR: apply whenever it is present (0.0 is valid and intentional)
      if (overrides.containsKey('rir')) {
        final orir = overrides['rir'];
        if (orir == null) {
          // explicit null → do NOT override (leave planned rir)
        } else if (orir is num) {
          progressed['rir'] = orir.toDouble();
        }
      }
      // If reps/RIR changed but no explicit weight, solve weight to keep baseline e1RM



      if (_needSolve) {
        final double _repsFor = _repsChanged
            ? (orp as num).toDouble()
            : (progressed['reps'] as num).toDouble();
        final double _rirFor = _rirChanged
            ? (overrides['rir'] as num).toDouble()
            : (progressed['rir'] as num).toDouble();

        // Invert calculateE1RM by a tiny bisection (monotonic in weight)
        double _low = 0.0;
        double _high = ((progressed['weight'] as num?)?.toDouble() ?? 20.0) * 3.0;
        for (int it = 0; it < 24; it++) {
          final mid = (_low + _high) / 2.0;
          final e = PeriodizationModelUtils.calculateE1RM(mid, _repsFor, _rirFor);
          if (e < _baselineE1rm) {
            _low = mid;
          } else {
            _high = mid;
          }
        }
        double _solvedAbs = (_low + _high) / 2.0;

        // Snap exactly like the base path
        if (_isBwEx) {
          final double _targetAdded = PeriodizationModelUtils.toDisplayAddedWeight(
            uid: uidForBw,
            absoluteKg: _solvedAbs,
            exerciseId: exerciseId,
            exerciseName: exerciseName,
            asOfDate: _asOfDate,
          );
          double _snappedAdded = _incOpts.reduce(
                (a, b) => (a - _targetAdded).abs() < (b - _targetAdded).abs() ? a : b,
          );
          if (_snappedAdded < 0) _snappedAdded = 0.0;
          final double _snappedAbs = PeriodizationModelUtils.toAbsoluteWeight(
            uid: uidForBw,
            displayAddedKg: _snappedAdded,
            exerciseId: exerciseId,
            exerciseName: exerciseName,
          );
          progressed['weightDisplayAdded'] = _snappedAdded;
          progressed['weight'] = _snappedAbs;
        } else {
          final double _snapped = _incOpts.reduce(
                (a, b) => (a - _solvedAbs).abs() < (b - _solvedAbs).abs() ? a : b,
          );
          progressed['weightDisplayAdded'] = _snapped;
          progressed['weight'] = _snapped;
        }

        // Optional: quick sanity log
        try {
          final eCheck = PeriodizationModelUtils.calculateE1RM(
            (progressed['weight'] as num).toDouble(),
            _repsFor,
            _rirFor,
          );
          print('🧪 [ENGINE/hold-e1RM] target=${_baselineE1rm.toStringAsFixed(1)} '
              '→ newW=${(progressed['weight'] as num).toStringAsFixed(1)} '
              '@$_repsFor (rir=$_rirFor) e1rm≈${eCheck.toStringAsFixed(1)}');
        } catch (_) {}
      }

      // If WEIGHT provided but no REPS, solve reps to preserve baseline e1RM (RIR stays as-is or overridden)
      final bool _hasWeightOnly = _hasUserWeight && !(orp is num && orp > 0);

      if (_hasWeightOnly) {
        // absolute weight to use (non-BW direct; BW uses the same absolute field here)
        final double _wAbs = _bwAbsFromWeightAsAdded ?? (ow as num).toDouble();


        // use current rir (after any override already applied above)
        final double _rirHold = (progressed['rir'] as num).toDouble();

        // brute-force reps 1..30, pick the one that keeps e1RM closest to baseline
        int bestReps = (progressed['reps'] as num).toInt();
        double bestGap = double.infinity;

        for (int r = 1; r <= 30; r++) {
          final e = PeriodizationModelUtils.calculateE1RM(_wAbs, r.toDouble(), _rirHold);
          final gap = (e - _baselineE1rm).abs();
          if (gap < bestGap) {
            bestGap = gap;
            bestReps = r;
          }
        }

        progressed['reps'] = bestReps.toDouble();
        progressed['weight'] = _wAbs; // honor the user-specified weight

        if (_isBwEx) {
          // derive ADDED mirror from absolute, snap on ADDED, then regenerate ABS from snapped ADDED
          final _disp = PeriodizationModelUtils.toDisplayAddedWeight(
            uid: uidForBw,
            absoluteKg: _wAbs,
            exerciseId: exerciseId,
            exerciseName: exerciseName,
            asOfDate: _asOfDate,
          );
          double _snappedAdded = _incOpts.reduce(
                (a, b) => (a - _disp).abs() < (b - _disp).abs() ? a : b,
          );
          if (_snappedAdded < 0) _snappedAdded = 0.0;
          final _snappedAbs = PeriodizationModelUtils.toAbsoluteWeight(
            uid: uidForBw,
            displayAddedKg: _snappedAdded,
            exerciseId: exerciseId,
            exerciseName: exerciseName,
            asOfDate: _asOfDate,
          );
          progressed['weightDisplayAdded'] = _snappedAdded;
          progressed['weight']             = _snappedAbs;  // keep ABS aligned to snapped ADDED
        } else {
          // non-BW unchanged: mirror ABS into the display field
          progressed['weightDisplayAdded'] = _wAbs;
        }


        // optional quick check
        try {
          final eCheck = PeriodizationModelUtils.calculateE1RM(
            _wAbs,
            bestReps.toDouble(),
            _rirHold,
          );
          print('🧪 [ENGINE/hold-e1RM←weight] base≈${_baselineE1rm.toStringAsFixed(1)} '
              '→ weight=${_wAbs.toStringAsFixed(1)} reps=$bestReps (rir=${_rirHold.toStringAsFixed(2)}) '
              'e1rm≈${eCheck.toStringAsFixed(1)}');
        } catch (_) {}
      }



    }

    if (canCache) {
      _cachedProgressedValues[_rowCacheKey(exerciseIndex)] = progressed;
    }
    // Print final resolved values
    print(
        '🧮 [ENGINE] Final for $exerciseName = ${progressed['weight']} kg '
            '@ ${progressed['reps']} reps, RIR ${progressed['rir']}');
    print('✅ [ENGINE/out] ${progressed['exerciseName']} → ${progressed['weight']} × ${progressed['reps']} (rir=${progressed['rir']})');

    return progressed;
  }

  }

