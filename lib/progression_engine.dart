//progression_engine.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:core';
import 'package:firebase_auth/firebase_auth.dart';
import 'periodization_model_utils.dart'; // your existing utils


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



    if (cached != null && blockStartDate != null && blockEndDate != null) {
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

      final seeded = <String, dynamic>{
        'exerciseName': exName,
        'exerciseId': exId,
        'weight': absW,
        'reps': (seed['s1_reps'] as num?)?.toDouble() ?? 10.0,
      };

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
      return {
        'exerciseName': _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '',
        'weight': 20.0,
        'reps': 10,
      };
    }

    _debugPrintBlockDates();
      // Get exercise info.
      final exerciseName =
          _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
      final exerciseId =
          PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
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
      final model =
      PeriodizationModelUtils.exercisePeriodizationModels[exerciseId];

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
            int completedBeforeTodayInBlock = 0;
            final matchedDates = <String>{};

            try {
              final base = DateTime(blockStartDate!.year, blockStartDate!.month,
                  blockStartDate!.day);
              final todayStart = DateTime(
                  _selectedDate!.year, _selectedDate!.month,
                  _selectedDate!.day);

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
                final sets = (setsRaw is List) ? setsRaw.cast<Map>() : const <
                    Map>[];
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
                if (dayOnly.isBefore(base) || !dayOnly.isBefore(todayStart))
                  continue; // [base, today)

                final exs = w['exercises'];
                if (exs is! List) continue;

                final matched = exs.any((ex) {
                  if (!hasValidSet(ex['sets'])) return false;

                  final exId = (ex['exerciseId'] ?? ex['id'] ??
                      ex['exercise_id'] ?? '').toString();
                  if (exId.isNotEmpty && exId == targetId) return true;

                  final exName = (ex['name'] ?? ex['exercise'] ?? ex['title'] ??
                      '').toString();
                  if (exName.isNotEmpty && norm(exName) == targetNameNorm)
                    return true;

                  final mapped = (PeriodizationModelUtils.nameToId[exName] ??
                      '').toString();
                  return mapped.isNotEmpty && mapped == targetId;
                });

                if (matched) {
                  matchedDates.add(dateStr.length >= 10
                      ? dateStr.substring(0, 10)
                      : dateStr);
                }
              }

              completedBeforeTodayInBlock = matchedDates.length;
            } catch (e) {}

            // AFTER you finish building `matchedDates` (and before plannedIndex/index):
            final countedDebug = <Map<String, String>>[];

            // Re-scan only the matched dates to grab a representative set per day
            for (final w in PeriodizationModelUtils.savedWorkoutsList) {
              final dateStr = (w['date'] ?? '').toString();
              final key = dateStr.length >= 10
                  ? dateStr.substring(0, 10)
                  : dateStr;
              if (!matchedDates.contains(key)) continue;

              final exs = w['exercises'];
              if (exs is! List) continue;

              String? weightTxt, repsTxt, rirTxt;

              for (final ex in exs) {
                // ID-first match (fallback to name→id only if no id on row)
                final exId = (ex['exerciseId'] ?? ex['id'] ??
                    ex['exercise_id'] ?? '').toString().trim();
                final exName = (ex['name'] ?? ex['exercise'] ?? ex['title'] ??
                    '').toString().trim();
                final idMatches = exId.isNotEmpty
                    ? (exId == exerciseId)
                    : false;
                final nameMatches = (exId.isEmpty)
                    ? ((PeriodizationModelUtils.nameToId[exName] ?? '')
                    .toString()
                    .trim() == exerciseId)
                    : false;
                if (!(idMatches || nameMatches)) continue;

                final sets = (ex['sets'] is List)
                    ? List<Map<String, dynamic>>.from(ex['sets'])
                    : const <Map<String, dynamic>>[];

                // Pick the first set that looks numeric
                for (final s in sets) {
                  final wTxt = (s['actualWeight'] ?? s['weight'] ?? '')
                      .toString()
                      .trim();
                  final rTxt = (s['actualReps'] ?? s['reps'] ?? '')
                      .toString()
                      .trim();
                  final rir = (s['actualRir'] ?? s['rir'] ?? '')
                      .toString()
                      .trim();

                  final looksNumber = double.tryParse(wTxt) != null &&
                      int.tryParse(rTxt) != null;
                  if (looksNumber) {
                    weightTxt = wTxt;
                    repsTxt = rTxt;
                    rirTxt = rir.isEmpty ? null : rir;
                    break;
                  }
                }

                if (weightTxt != null || repsTxt != null) break;
              }

              countedDebug.add({
                'date': key,
                'weight': weightTxt ?? '—',
                'reps': repsTxt ?? '—',
                'rir': rirTxt ?? '—',
              });
            }

            // Sort by date (ascending) so the cycle order is obvious
            countedDebug.sort((a, b) => a['date']!.compareTo(b['date']!));

            // Now compute plannedIndex / index as before
            final plannedIndex = completedBeforeTodayInBlock +
                plannedCountBefore;
            final index = sorted.isEmpty ? 0 : plannedIndex % sorted.length;

            final raw = sorted.isNotEmpty ? (sorted[index].value?.toString() ??
                '') : '';
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
              int completedEarlierThisWeek = 0;
              final matchedDates = <String>{};

              try {
                final base = DateTime(
                    blockStartDate!.year, blockStartDate!.month,
                    blockStartDate!.day);
                final wkIdx = weekIndex ?? 0;
                final weekStart = base.add(Duration(days: wkIdx * 7));
                final todayStart = DateTime(
                    _selectedDate!.year, _selectedDate!.month,
                    _selectedDate!.day);

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
                  final sets = (setsRaw is List) ? setsRaw.cast<Map>() : const <
                      Map>[];
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
                  if (dayOnly.isBefore(weekStart) ||
                      !dayOnly.isBefore(todayStart))
                    continue; // strictly before today

                  final exs = w['exercises'];
                  if (exs is! List) continue;

                  final matched = exs.any((ex) {
                    if (!hasValidSet(ex['sets'])) return false;

                    final exId = (ex['exerciseId'] ?? ex['id'] ??
                        ex['exercise_id'] ?? '').toString();
                    if (exId.isNotEmpty && exId == targetId) return true;

                    final exName = (ex['name'] ?? ex['exercise'] ??
                        ex['title'] ?? '').toString();
                    if (exName.isNotEmpty && norm(exName) == targetNameNorm)
                      return true;

                    final mapped = (PeriodizationModelUtils.nameToId[exName] ??
                        '').toString();
                    return mapped.isNotEmpty && mapped == targetId;
                  });

                  if (matched) {
                    matchedDates.add(dateStr.length >= 10
                        ? dateStr.substring(0, 10)
                        : dateStr);
                  }
                }

                completedEarlierThisWeek = matchedDates.length;
              } catch (e) {}

              // 🔑 WES rule: planned rows don't affect DUP Weekly indexing
              final plannedIndex = completedEarlierThisWeek;
              final index = plannedIndex % sorted.length;

              final raw = sorted[index].value?.toString() ?? '';
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
        // ✅ fallback
        maxWeightByReps: _exerciseSettings[exerciseId]?['maxWeightByReps'],
        topSetHistory: PeriodizationModelUtils.topSetsByExercise[exerciseName],
        weekIndex: (blockStartDate == null || _selectedDate == null)
            ? 0 // safe default until initialized
            : PeriodizationModelUtils.getWeekIndexForDate(
          _selectedDate,
          blockStartDate!,
        ),
      );

      // as-of date for BW lookups = the day being edited in WES
      final DateTime _asOfDate = _selectedDate ?? DateTime.now();

      final target = (progressed['weight'] as num).toDouble();

      // keep variable name `snapped` so nothing else downstream changes
      double snapped;

      final bool _isBwEx = PeriodizationModelUtils.isBodyweightExercise(
        id: exerciseId,
        name: exerciseName,
      );

      if (_isBwEx) {
        // convert ABS → ADDED
        final double _targetAdded =
        PeriodizationModelUtils.toDisplayAddedWeight(
          uid: uidForBw,
          absoluteKg: target,
          exerciseId: exerciseId,
          exerciseName: exerciseName,
          asOfDate: _asOfDate, // ⬅️ add this
        );

        // snap on ADDED (use your expanded increments)
        final List<double> _opts = (increments == null || increments.isEmpty)
            ? <double>[2.5]
            : increments;
        double _snappedAdded = _opts.reduce(
              (a, b) =>
          (a - _targetAdded).abs() < (b - _targetAdded).abs() ? a : b,
        );

        // cap min at 0 for display semantics
        if (_snappedAdded < 0) _snappedAdded = 0.0;

        // convert back to ABS for storage/math and assign to your usual `snapped`
        snapped = PeriodizationModelUtils.toAbsoluteWeight(
          uid: uidForBw,
          displayAddedKg: _snappedAdded,
          exerciseId: exerciseId,
          exerciseName: exerciseName,
        );

        // optional: expose display-only value for your hint UI (no impact to normal exercises)
        progressed['weightDisplayAdded'] = _snappedAdded;
      } else {
        // 🔁 NORMAL EXERCISES: unchanged behavior and names
        snapped = increments.reduce(
              (a, b) => (a - target).abs() < (b - target).abs() ? a : b,
        );
        // for non-BW, display == absolute (this key is optional; omit if you prefer)
        progressed['weightDisplayAdded'] = snapped;
      }

      // write back absolute weight as before
    progressed['weight'] = snapped;

    // Cache and return
    progressed['exerciseName'] = exerciseName;
    progressed['exerciseId'] = exerciseId;
    final canCache = (blockStartDate != null) &&
        (_selectedDate != null) &&
        (PeriodizationModelUtils.savedWorkoutsList.isNotEmpty);
    if (canCache) {
      _cachedProgressedValues[_rowCacheKey(exerciseIndex)] = progressed;
    }

    // === Overlay with BB2 / user-entered values if available ===
    var overrides = i.resolvedBB2Values[exerciseId];

// 🔁 Fallback: also check by name (lowercased) if id lookup fails
    if (overrides == null) {
      final lowerName = exerciseName.toLowerCase().trim();
      overrides = i.resolvedBB2Values[lowerName];
    }

    if (overrides != null) {
      print('[ENGINE] applying overrides for $exerciseName → $overrides');

      if (overrides['weight'] != null) {
        progressed['weight'] = (overrides['weight'] as num).toDouble();
      }
      if (overrides['reps'] != null) {
        progressed['reps'] = (overrides['reps'] as num).toDouble();
      }
      if (overrides['rir'] != null) {
        progressed['rir'] = (overrides['rir'] as num).toDouble();
      }
    }


    // Print final resolved values
    print(
        '🧮 [ENGINE] Final for $exerciseName = ${progressed['weight']} kg '
            '@ ${progressed['reps']} reps, RIR ${progressed['rir']}');

    return progressed;
  }

  }

