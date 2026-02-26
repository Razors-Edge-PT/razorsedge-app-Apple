// lib/bootstrap/template_generator.dart
import 'dart:convert';
import 'package:flutter/foundation.dart'; // for debugPrint
import 'package:cloud_firestore/cloud_firestore.dart'; // 🆕 for plannedExercises fetch

import 'debug_utils.dart';

import 'package:flutter/services.dart' show rootBundle;

/// Lightweight model of an exercise from the bundled asset.
class ExLite {
  final String id;
  final String name;
  final String category; // e.g., 'Horizontal Press', 'Vertical Pull', 'Squat Pattern', 'Hip Hinge', 'Leg Extension', 'Leg Curl', 'Lateral Raise', 'Arm Curl', 'Arm Extension', 'Core'
  final List<String> primary;   // ordered, highest priority first
  final List<String> secondary; // optional / lower priority hits

  ExLite({
    required this.id,
    required this.name,
    required this.category,
    required this.primary,
    required this.secondary,
  });

  /// Tries to be resilient to slightly different dump shapes.
  static ExLite fromMap(Map<String, dynamic> m) {
    final id   = (m['id'] ?? m['docId'] ?? '').toString();
    final name = (m['name'] ?? '').toString();
    final cat  = (m['category'] ?? m['cat'] ?? 'Uncategorized').toString();

    // Prefer fine-grained order if present; otherwise fall back to 'bodyParts'
    List<String> prim = const [];
    List<String> sec  = const [];

    // Accept either explicit fields or infer from a single 'muscles'/'bodyParts' list
    final muscles = (m['muscles'] ?? m['bodyParts'] ?? m['musclesTargeted']);
    if (muscles is List) {
      final flat = muscles.map((e) => e.toString()).toList();
      // Without explicit split we’ll treat the first as primary, others as secondary
      prim = flat.isNotEmpty ? [flat.first] : const [];
      sec  = flat.length > 1 ? flat.sublist(1) : const [];
    }

    // If explicit lists exist, prefer them.
    if (m['primary'] is List) {
      prim = (m['primary'] as List).map((e) => e.toString()).toList();
    }
    if (m['secondary'] is List) {
      sec = (m['secondary'] as List).map((e) => e.toString()).toList();
    }

    return ExLite(id: id, name: name, category: cat, primary: prim, secondary: sec);
  }

  bool hitsAny(Set<String> muscles) {
    for (final x in primary) {
      if (muscles.contains(x)) return true;
    }
    for (final x in secondary) {
      if (muscles.contains(x)) return true;
    }
    return false;
  }
}

/// Weekly volume target for a major muscle group.
class MuscleVolumeTarget {
  final int mevSets;          // Minimum effective volume
  final int mrvSets;          // Maximum recoverable volume (age-adjusted)
  final int targetSets;       // Where this user should roughly land
  final int minExercises;     // ~MEV in exercise appearances
  final int targetExercises;  // main planning anchor
  final int maxExercises;     // ~MRV in exercise appearances

  const MuscleVolumeTarget({
    required this.mevSets,
    required this.mrvSets,
    required this.targetSets,
    required this.minExercises,
    required this.targetExercises,
    required this.maxExercises,
  });

  @override
  String toString() {
    return 'MEV=$mevSets, target=$targetSets, MRV=$mrvSets | '
        'ex/week: min=$minExercises, target=$targetExercises, max=$maxExercises';
  }
}


/// Bench-press selection tier derived from user's ranked onboarding goals.
enum _BenchTier { tierA, tierB, tierC }

class TemplateGenerator {
  /// Where we expect you to place the bundled library you exported earlier.
  /// You can rename the file; just update this path and pubspec assets.


  static const String _assetPath = 'assets/exercise_dump_20251109_112626.json';
// Max circuits per day (age-dependent). Default for younger / unknown age.
  static const int _defaultMaxCircuitsPerDay = 4;
  static const int _maxExercisesPerCircuit = 3; // typical antagonist circuit size

  static int _maxCircuitsPerDay = _defaultMaxCircuitsPerDay;

  // ── Bench-tier state (set once per generateFromOnboarding call) ──────────
  // tierA = full emphasis (no cap, no spacing, prefer first HP)
  // tierB = partial (prefer first HP, weekly cap of 2 or 3)
  // tierC = default (no preference, normal cap + spacing like any exercise)
  static _BenchTier _benchTier = _BenchTier.tierA;
  static int _benchWeeklyCap = 999; // only meaningful for Tier B


  /// Generate a set of starter templates (e.g., B1 Day1.., B2 Day1..)
  /// based on onboarding + pairing & overlap rules.
  ///
  /// Return format per template:
  /// {
  ///   'name': 'B1 Day 1',
  ///   'exercises': [
  ///      {'exerciseId': 'xyz', 'name': 'Bench Press, Barbell', 'circuitIndex': 0},
  ///      ...
  ///   ]
  /// }


  static Future<List<Map<String, dynamic>>> generateFromOnboarding({
    required String uid,
    required String? sexU,
    required int? age,
    required Map<String, dynamic> onboarding,
    bool plannedOnly = false, // 🆕
  }) async {
    // 1) Load library
    final lib = await _loadExerciseLibrary();
    // 🆕 Planned-only filter (from Block Planner current_block)
    List<ExLite> workingLib = lib;
    if (plannedOnly) {
      final plannedIds = await _fetchPlannedExerciseIds(uid);
      if (plannedIds.isNotEmpty) {
        final filtered = workingLib.where((e) => plannedIds.contains(e.id)).toList();
        if (filtered.isEmpty) {
          debugPrint('⚠️ [GEN] planned-only produced 0 matches; falling back to full library');
        } else {
          workingLib = filtered;
          debugPrint('✅ [GEN] planned-only active: ${workingLib.length} exercises remain');
        }
      } else {
        debugPrint('⚠️ [GEN] no plannedExercises; falling back to full library');
      }
    }

    // 🩹 Injury filters (lower back, shoulders, elbow, knees)
    workingLib = _applyInjuryFilters(
      lib: workingLib,
      onboarding: onboarding,
    );


    // 🏋️ Equipment filters (machines / TRX etc.)
    workingLib = _applyEquipmentFilters(
      lib: workingLib,
      onboarding: onboarding,
    );



    // 2) Read knobs from onboarding
    final int weeklyFrequency = _readWeeklyFrequency(onboarding) ?? 4; // default to 4
    final bool isFemale = sexU == 'F' || sexU == 'N';

    debugPrint(
      '🧬 [GEN] sexU=$sexU isFemale=$isFemale age=$age maxCircuits=$_maxCircuitsPerDay',
    );


    // Training effort (1..4), default 3
    final int trainingEffort = (() {
      final raw = onboarding['trainingEffort'];
      if (raw is int) return raw.clamp(1, 4);
      if (raw is num) return raw.toInt().clamp(1, 4);
      if (raw is String) {
        final p = int.tryParse(raw);
        if (p != null) return p.clamp(1, 4);
      }
      return 3;
    })();


    final volumeTargets = computeVolumeTargetsFromOnboarding(
      age: age,
      onboarding: onboarding,
    );

    // TEMP: debug only
    debugPrintVolumeTargets(volumeTargets);


    // Age-based max circuits per day:
//   age > 47 → 2 circuits
//   age > 27 → 3 circuits
//   else (younger / unknown) → 4 circuits
    if (age == null) {
      _maxCircuitsPerDay = _defaultMaxCircuitsPerDay; // 4
    } else if (age > 47) {
      _maxCircuitsPerDay = 2;
    } else if (age > 27) {
      _maxCircuitsPerDay = 3;
    } else {
      _maxCircuitsPerDay = _defaultMaxCircuitsPerDay; // 4
    }


// 🧬 Hypertrophy-focused male flag based on top 2 goals
    final List<dynamic>? goalsRankedRaw =
    onboarding['goalsRanked'] as List<dynamic>?;
    final List<String> topGoals = (goalsRankedRaw ?? const [])
        .map((e) => e.toString())
        .take(2)
        .toList();

    // ── Bench-tier computation ───────────────────────────────────────────────
    {
      final List<String> goalsRanked = (goalsRankedRaw ?? const [])
          .map((e) => e.toString())
          .toList();

      final int rankPL       = goalsRanked.indexOf('Powerlifting');
      final int rankBPS      = goalsRanked.indexOf('Bench Press Specialist');
      final int rankStrength = goalsRanked.indexOf('Strength');
      final int rankSize     = goalsRanked.indexOf('Build more muscle');

      // Tier A: PL or BPS in top 2, AND at least one ranks above 'Build more muscle'
      final bool plOrBpsInTop2 =
          (rankPL  >= 0 && rankPL  < 2) || (rankBPS >= 0 && rankBPS < 2);
      final bool plAboveSize  = rankPL  >= 0 && (rankSize < 0 || rankPL  < rankSize);
      final bool bpsAboveSize = rankBPS >= 0 && (rankSize < 0 || rankBPS < rankSize);
      final bool isTierA = plOrBpsInTop2 && (plAboveSize || bpsAboveSize);

      // Tier B — B1: PL or BPS in top 3, but 'Build more muscle' outranks both
      final bool plOrBpsInTop3 =
          (rankPL  >= 0 && rankPL  < 3) || (rankBPS >= 0 && rankBPS < 3);
      final bool sizeAbovePL  = rankSize >= 0 && (rankPL  < 0 || rankSize < rankPL);
      final bool sizeAboveBPS = rankSize >= 0 && (rankBPS < 0 || rankSize < rankBPS);
      final bool b1 = plOrBpsInTop3 && sizeAbovePL && sizeAboveBPS;

      // Tier B — B2: 'Strength' in top 3 and ranked above 'Build more muscle'
      final bool strengthInTop3    = rankStrength >= 0 && rankStrength < 3;
      final bool strengthAboveSize = rankSize < 0 || rankStrength < rankSize;
      final bool b2 = strengthInTop3 && strengthAboveSize;

      final bool isTierB = !isTierA && (b1 || b2);

      if (isTierA) {
        _benchTier      = _BenchTier.tierA;
        _benchWeeklyCap = 999;
      } else if (isTierB) {
        _benchTier      = _BenchTier.tierB;
        _benchWeeklyCap = weeklyFrequency >= 4 ? 3 : 2;
      } else {
        _benchTier      = _BenchTier.tierC;
        _benchWeeklyCap = 999;
      }
      debugPrint('🏋️ [GEN] benchTier=$_benchTier cap=$_benchWeeklyCap '
          '(PL=$rankPL BPS=$rankBPS STR=$rankStrength SIZE=$rankSize)');
    }
    // ────────────────────────────────────────────────────────────────────────

    const Set<String> _hypertrophyGoalSet = {
      'Build more muscle',
      'Tone and shape',
      'Get leaner',
    };

    final bool isHypertrophyMale =
        !isFemale && topGoals.any((g) => _hypertrophyGoalSet.contains(g));

// We want HP first + HPull second in circuit 0 on ~ (weeklyFrequency - 1) days
    final int requiredHPullPrimaryDays =
    isHypertrophyMale ? ((weeklyFrequency - 1).clamp(0, weeklyFrequency) as int) : 0;


    // 3) Frequency caps by sex (baseline at ≥4x/wk), then reduce max caps if fewer days.
    final freqCaps = _capsFor(isFemale: isFemale);
    final reduceSteps = (weeklyFrequency >= 4) ? 0 : (4 - weeklyFrequency);
    for (final k in freqCaps.keys) {
      final cap = freqCaps[k]!;
      final reducedMax = (cap['max']! - reduceSteps).clamp(cap['min']!, cap['max']!);
      cap['max'] = reducedMax;
    }

    // 4) Build a per-category pick list from the library (no duplicates)
    final byCat = <String, List<ExLite>>{};
    for (final e in workingLib) {               // ← use workingLib
      byCat.putIfAbsent(e.category, () => <ExLite>[]).add(e);
    }

    // 5) Decide how many *total* slots per category (weekly) we’ll try to schedule.
    // Start at min, allow up to max, but don’t exceed weeklyFrequency * 2 per-day caps.
    final weeklyPlan = <String, int>{};
    int totalPlanned = 0;
    final int perDayOverallMax = weeklyFrequency * (_maxCircuitsPerDay * 3);


    void allocate(String cat) {
      final cap = freqCaps[cat];
      if (cap == null) return;

      // Skip categories that aren't available in the library
      if (!(byCat[cat]?.isNotEmpty ?? false)) return;

      final current = weeklyPlan[cat];

      if (current == null) {
        // If nothing planned yet, start at the category's min
        weeklyPlan[cat] = cap['min']!;
      } else {
        // Clamp the already-computed plan into [min, max]
        if (current < cap['min']!) {
          weeklyPlan[cat] = cap['min']!;
        } else if (current > cap['max']!) {
          weeklyPlan[cat] = cap['max']!;
        }
      }
    }


    // Ensure weekly minimums by sex (after we’ve built the first pass of weeklyPlan).
    final categoryEmphasis = _buildCategoryEmphasis(onboarding);

    _enforceWeeklyMinimums(
      isFemale: isFemale,
      weeklyPlan: weeklyPlan,
      freqCaps: freqCaps,
      byCat: byCat,
      categoryEmphasis: categoryEmphasis,
    );

    // 🧭 Emphasis routing (child sliders → category bumps + id targets)
    final childLevels = _buildChildEmphasis(onboarding);
    debugPrint('🎯 childLevels = $childLevels');
    final routed = _routeEmphasisToDemand(
      childLevels: childLevels,
      byCat: byCat,
      trainingEffort: trainingEffort,
    );

    final Map<String,int> _idTargetsRemaining = Map.of(routed.idTargets);

    // 🔢 New: volume-engine-driven category bumps (MEV/MAV/MRV → ex/week)
    final volumeCategoryBumps = _volumeCategoryBumpsFromTargets(
      volumeTargets: volumeTargets,
      freqCaps: freqCaps,
      childLevels: childLevels, // 🔍 so we can skip zero-emphasis muscles
      trainingEffort: trainingEffort, // 🆕 effort-aware bumps
    );



    // Lift weekly minima by BOTH:
    // 1) slider-based bumps (routed.categoryBumps)
    // 2) volume-engine bumps (volumeCategoryBumps)
    final mergedCategoryBumps = <String, int>{};

    // Start with slider bumps
    routed.categoryBumps.forEach((cat, inc) {
      mergedCategoryBumps[cat] = (mergedCategoryBumps[cat] ?? 0) + inc;
    });

    // Add volume bumps
    volumeCategoryBumps.forEach((cat, inc) {
      mergedCategoryBumps[cat] = (mergedCategoryBumps[cat] ?? 0) + inc;
    });

    _applyEmphasisCategoryBumps(
      weeklyPlan: weeklyPlan,
      freqCaps: freqCaps,
      byCat: byCat,
      categoryBumps: mergedCategoryBumps,
    );



    // Core categories first so we don’t starve them (sex-specific ordering)
    final ordered = _orderedCategoriesPriorityFor(isFemale: isFemale);
    for (final cat in ordered) {
      allocate(cat);
    }

    // Quick sanity bound
    totalPlanned = weeklyPlan.values.fold<int>(0, (a, b) => a + b);
    if (totalPlanned > perDayOverallMax) {
      // If severely over, proportionally scale down but never below min.
      final scale = perDayOverallMax / totalPlanned;
      weeklyPlan.updateAll((cat, count) {
        final cap = freqCaps[cat]!;
        final scaled = (count * scale).floor();
        return scaled < cap['min']! ? cap['min']! : scaled;
      });
    }

    // 6) Build day shells. For block 1, we produce exactly `weeklyFrequency` days.
    final days = List.generate(
      weeklyFrequency,
          (i) => _DayPlan(index: i, totalDays: weeklyFrequency),
    ); // <-- close List.generate here

// 🧮 Track how many times each category is already seeded
    final Map<String, int> _seededCountByCategory = {};

    // Build a fresh block (B2 / B3) using the same pipeline as Block 1:
    // - _seedDailyMinimums
    // - greedy round-robin fill
    // - _chooseExercise / _canJoin / _placeIntoCircuit
    // - spacing rules, per-exercise caps, muscle overlap, etc.
    List<_DayPlan> _buildBlockFromScratch({
      required int weeklyFrequency,
      required bool isFemale,
      required bool isHypertrophyMale,
      required int requiredHPullPrimaryDays,
      required Map<String, List<ExLite>> byCat,
      required Map<String, Map<String, int>> freqCaps,
      required Map<String, int> weeklyPlanTemplate,
      required int age,
    }) {
      // Fresh days list for this block
      final days = List<_DayPlan>.generate(
        weeklyFrequency,
            (idx) => _DayPlan(index: idx, totalDays: weeklyFrequency),
      );

      // Fresh mutable copies so we don't touch the originals
      final Map<String, int> weeklyPlan =
      Map<String, int>.from(weeklyPlanTemplate);
      final Map<String, int> _seededCountByCategory = {};
      final Map<String, int> _idTargetsRemaining = {};

      // Optionally shuffle pools so B2/B3 pick different exercises
      final Map<String, List<ExLite>> shuffledByCat = <String, List<ExLite>>{};
      byCat.forEach((cat, list) {
        final copy = List<ExLite>.from(list);
        copy.shuffle();
        shuffledByCat[cat] = copy;
      });

      // 1) Seed daily minimums (same rules as B1)
      _seedDailyMinimums(
        days: days,
        isFemale: isFemale,
        byCat: shuffledByCat,
        allDays: days,
        idTargetsRemaining: _idTargetsRemaining,
        isHypertrophyMale: isHypertrophyMale,
        requiredHPullPrimaryDays: requiredHPullPrimaryDays,
        weeklyPlan: weeklyPlan,
        seededCountByCategory: _seededCountByCategory,
        userAge: age,
      );

      // 2) Adjust weeklyPlan by subtracting what seeding already placed
      final Map<String, int> seededCount = {};
      for (final d in days) {
        d.countByCategory.forEach((cat, count) {
          seededCount[cat] = (seededCount[cat] ?? 0) + count;
        });
      }

      final Map<String, int> remainingPlan = {};
      weeklyPlan.forEach((cat, planned) {
        final seeded = seededCount[cat] ?? 0;
        final remaining = planned - seeded;
        if (remaining > 0) {
          remainingPlan[cat] = remaining;
        }
      });

      // 3) Greedy round-robin placement (copy of your Step 7)
      const int perDayCategoryHardCap = 2;

      final workList = <String>[];
      remainingPlan.forEach((cat, n) {
        for (int i = 0; i < n; i++) {
          workList.add(cat);
        }
      });

      int cursor = 0;
      for (final cat in workList) {
        bool placed = false;

        // lighter-day-first + round-robin flavour
        final dayIndices = List<int>.generate(
          weeklyFrequency,
              (offset) => (cursor + offset) % weeklyFrequency,
        );

        dayIndices.sort((a, b) {
          final int aLoad = days[a].circuits.fold<int>(
            0,
                (sum, circ) => sum + circ.length,
          );
          final int bLoad = days[b].circuits.fold<int>(
            0,
                (sum, circ) => sum + circ.length,
          );

          if (aLoad != bLoad) {
            return aLoad.compareTo(bLoad);
          }

          final int aDist =
          (a - cursor) >= 0 ? (a - cursor) : (a - cursor + weeklyFrequency);
          final int bDist =
          (b - cursor) >= 0 ? (b - cursor) : (b - cursor + weeklyFrequency);
          return aDist.compareTo(bDist);
        });

        for (final dayIdx in dayIndices) {
          final day = days[dayIdx];

          final usedThisCat = day.countByCategory[cat] ?? 0;
          if (usedThisCat >= perDayCategoryHardCap) continue;

          const pressCats = {'Horizontal Press', 'Vertical Press'};
          if (pressCats.contains(cat)) {
            final int pressesToday =
                (day.countByCategory['Horizontal Press'] ?? 0) +
                    (day.countByCategory['Vertical Press'] ?? 0);
            if (pressesToday >= 2) {
              continue;
            }
          }

          final chosen = _chooseExercise(
            pool: shuffledByCat[cat] ?? const [],
            day: day,
            category: cat,
            allDays: days,
            idTargetsRemaining: _idTargetsRemaining,
            isMale: !isFemale,
          );

          if (chosen == null) continue;

          final circuitIdx = _placeIntoCircuit(day, chosen);
          day.addExercise(chosen, cat, circuitIdx);

          seededCount[cat] = (seededCount[cat] ?? 0) + 1;

          placed = true;
          cursor = (dayIdx + 1) % weeklyFrequency;
          break;
        }

        // If we couldn't place it anywhere, we just skip – same behaviour as B1.
      }

      return days;
    }

// Seed each day with the requested “minimum per day” set for the user’s sex.
// (This is a soft seed; further placements will still obey pairing rules.)
    _seedDailyMinimums(
      days: days,
      isFemale: isFemale,
      byCat: byCat,
      allDays: days,
      idTargetsRemaining: _idTargetsRemaining,
      isHypertrophyMale: isHypertrophyMale,
      requiredHPullPrimaryDays: requiredHPullPrimaryDays,
      weeklyPlan: weeklyPlan,                      // 🆕 pass weekly caps
      seededCountByCategory: _seededCountByCategory, // 🆕 out-param map
      userAge: age ?? 27, // 👈 use `age` from this method’s params                       // 🆕 age for circuit caps
    );


    // 6.5) Adjust weeklyPlan by subtracting what seeding already placed
    final Map<String, int> seededCount = {};
    for (final d in days) {
      d.countByCategory.forEach((cat, count) {
        seededCount[cat] = (seededCount[cat] ?? 0) + count;
      });
    }

    final Map<String, int> remainingPlan = {};
    weeklyPlan.forEach((cat, planned) {
      final seeded = seededCount[cat] ?? 0;
      final remaining = planned - seeded;
      if (remaining > 0) {
        remainingPlan[cat] = remaining;
      }
    });

    // 7) Greedy round-robin placement following pairing & overlap rules.
// Per-day category cap: "prefer 1, allow 2" → enforce hard cap = 2
    const int perDayCategoryHardCap = 2;

// Make a working list of categories expanded by their *remaining* weekly counts.
    final workList = <String>[];
    remainingPlan.forEach((cat, n) {
      for (int i = 0; i < n; i++) {
        workList.add(cat);
      }
    });

// INSERT HERE ⬇️
    workList.shuffle();   // 🔀 More aggressive variation


// EXTRA VARIATION: randomize day evaluation order
    final dayOrder = List<int>.generate(days.length, (i) => i)..shuffle();

// Rotation pointer
    int cursor = 0;
    for (final cat in workList) {
      bool placed = false;

      // Start with the shuffled day order, then apply light-day + round-robin sorting
      final dayIndices = List<int>.from(dayOrder);

      dayIndices.sort((a, b) {
        final int aLoad = days[a].circuits.fold<int>(0, (s, c) => s + c.length);
        final int bLoad = days[b].circuits.fold<int>(0, (s, c) => s + c.length);

        if (aLoad != bLoad) return aLoad.compareTo(bLoad);

        final int aDist = (a - cursor) >= 0 ? (a - cursor) : (a - cursor + weeklyFrequency);
        final int bDist = (b - cursor) >= 0 ? (b - cursor) : (b - cursor + weeklyFrequency);
        return aDist.compareTo(bDist);
      });

      for (final dayIdx in dayIndices) {
        final day = days[dayIdx];

        // Per-day category count
        final usedThisCat = day.countByCategory[cat] ?? 0;
        if (usedThisCat >= perDayCategoryHardCap) continue;

        // 🆕 RULE: Maximum 2 pressing movements per day (HP + VP combined)
        const pressCats = {'Horizontal Press', 'Vertical Press'};
        if (pressCats.contains(cat)) {
          final int pressesToday =
              (day.countByCategory['Horizontal Press'] ?? 0) +
                  (day.countByCategory['Vertical Press'] ?? 0);

          if (pressesToday >= 2) {
            continue; // skip this day for pressing categories
          }
        }

        // 🧱 Weekly cap guard — do NOT exceed remainingPlan[cat]
        final int remaining = remainingPlan[cat] ?? 0;
        final int alreadyUsed = seededCount[cat] ?? 0;

        if (alreadyUsed >= (weeklyPlan[cat] ?? 0)) {
          // Category is fully capped — skip entirely
          continue;
        }

        final chosen = _chooseExercise(
          pool: byCat[cat] ?? const [],
          day: day,
          category: cat,
          allDays: days,
          idTargetsRemaining: _idTargetsRemaining,
          isMale: !isFemale,
        );

        if (chosen == null) continue;

        // Allocate to a circuit that respects pairing rules
        final circuitIdx = _placeIntoCircuit(day, chosen);
        day.addExercise(chosen, cat, circuitIdx);

        // 📈 Track total weekly usage (seeded + greedy)
        seededCount[cat] = (seededCount[cat] ?? 0) + 1;

        placed = true;
        cursor = (dayIdx + 1) % weeklyFrequency;
        break;
      }

      // If we couldn’t place it anywhere, we skip silently (library / rules too strict)
    }


    // 8) Emit templates: B1 first
    final out = <Map<String, dynamic>>[];
    for (int i = 0; i < days.length; i++) {
      out.add({
        'name': 'B1 Day ${i + 1}',
        'exercises': days[i].emit(),
      });
    }

    // 🧩 DEBUG: Print Block 1 day/circuit layout for inspection
    debugPrint('──────────── 🧠 BLOCK 1 DEBUG ────────────');
    for (final d in days) {
      debugPrint('📅  Day ${d.index + 1}');
      for (int ci = 0; ci < d.circuits.length; ci++) {
        final circuit = d.circuits[ci];
        final buffer = StringBuffer('  🔁  Circuit $ci → ');
        for (final p in circuit) {
          buffer.write('${p.ex.name} [${p.category}], ');
        }
        debugPrint(buffer.toString());
      }
    }
    debugPrint('──────────────────────────────────────────');

    // 🧪 DEBUG: scan for actual illegal pairings (pairwise, no self-comparisons)
    debugPrint('──────────── ⚠️  PAIRING VIOLATION CHECK ────────────');
    for (final d in days) {
      for (int ci = 0; ci < d.circuits.length; ci++) {
        final circuit = d.circuits[ci];
        for (int i = 0; i < circuit.length; i++) {
          for (int j = i + 1; j < circuit.length; j++) {
            final a = circuit[i];
            final b = circuit[j];
            if (_pairIsIllegal(a, b)) {
              debugPrint('⚠️  [Day ${d.index + 1} | Circuit $ci] Illegal pair:\n'
                  '     → ${a.ex.name} [${a.category}]\n'
                  '     ↔ ${b.ex.name} [${b.category}]');
            }
          }
        }
      }
    }
    debugPrint('──────────────────────────────────────────────');
    // 🧮 DEBUG: Weekly category & muscle hit counts (Block 1 only)
    debugWeeklyCategoryAndMuscleCounts(days);

    // 9) Build Block 2 by re-running the full pipeline
    final daysB2 = _buildBlockFromScratch(
      weeklyFrequency: weeklyFrequency,
      isFemale: isFemale,
      isHypertrophyMale: isHypertrophyMale,
      requiredHPullPrimaryDays: requiredHPullPrimaryDays,
      byCat: byCat,
      freqCaps: freqCaps,
      weeklyPlanTemplate: weeklyPlan,
      age: age ?? 27,
    );
    for (int i = 0; i < daysB2.length; i++) {
      out.add({
        'name': 'B2 Day ${i + 1}',
        'exercises': daysB2[i].emit(),
      });
    }

    // 10) Build Block 3 by re-running the full pipeline again
    final daysB3 = _buildBlockFromScratch(
      weeklyFrequency: weeklyFrequency,
      isFemale: isFemale,
      isHypertrophyMale: isHypertrophyMale,
      requiredHPullPrimaryDays: requiredHPullPrimaryDays,
      byCat: byCat,
      freqCaps: freqCaps,
      weeklyPlanTemplate: weeklyPlan,
      age: age ?? 27,
    );
    for (int i = 0; i < daysB3.length; i++) {
      out.add({
        'name': 'B3 Day ${i + 1}',
        'exercises': daysB3[i].emit(),
      });
    }

    // ───────────────────── DEBUG PRINT ALL BLOCKS ─────────────────────
    void _debugPrintBlocks(
        List<_DayPlan> b1,
        List<_DayPlan> b2,
        List<_DayPlan> b3,
        ) {
      String dump(String name, List<_DayPlan> block) {
        final buffer = StringBuffer();
        buffer.writeln('================ $name ================');
        for (final d in block) {
          buffer.writeln('Day ${d.index + 1}:');
          for (int ci = 0; ci < d.circuits.length; ci++) {
            buffer.writeln('  Circuit $ci:');
            for (final p in d.circuits[ci]) {
              buffer.writeln(
                  '    • ${p.ex.name} (id=${p.ex.id}, cat=${p.category})');
            }
          }
          buffer.writeln('');
        }
        return buffer.toString();
      }

      final s1 = dump('BLOCK 1', b1);
      final s2 = dump('BLOCK 2', b2);
      final s3 = dump('BLOCK 3', b3);

      debugPrint(s1);
      debugPrint(s2);
      debugPrint(s3);
    }

    // Call it:
    _debugPrintBlocks(days, daysB2, daysB3);


// ──────────────────────────────────────────────────────────────────



    return out;
  }

  /// Apply equipment filters to the working exercise library.
  ///
  /// Reads from onboarding['equipment']['items'] (array of strings).
  ///
  /// Behaviour:
  ///   • If environment == 'powerlifting' → use the powerlifting rules below.
  ///   • Else (commercial / default)      → use the original commercial list.
  static List<ExLite> _applyEquipmentFilters({
    required List<ExLite> lib,
    required Map<String, dynamic> onboarding,
  }) {
    final eqRaw = onboarding['equipment'];
    if (eqRaw is! Map) {
      debugPrint('🏋️ [EQ] onboarding.equipment missing → no equipment filters');
      return lib;
    }

    final eqMap = Map<String, dynamic>.from(eqRaw as Map);
    final itemsRaw = eqMap['items'];

    if (itemsRaw is! List || itemsRaw.isEmpty) {
      debugPrint('🏋️ [EQ] onboarding.equipment.items empty → no equipment filters');
      return lib;
    }

    // Normalised list of owned equipment strings
    final owned = <String>{};
    for (final item in itemsRaw) {
      if (item == null) continue;
      owned.add(item.toString().trim());
    }
    final ownedLower = owned.map((e) => e.toLowerCase().trim()).toList();

    // Environment (e.g. "commercial", "powerlifting", "home")
    final envRaw = onboarding['environment'];
    final env = envRaw is String ? envRaw.toLowerCase().trim() : '';

    debugPrint('🏋️ [EQ] env="$env", owned equipment = $owned');

    // ─────────────────────────────────────────────────────────────
    // HOME GYM RULES  (INSERTED HERE — before powerlifting)
    // ─────────────────────────────────────────────────────────────
    if (env == 'home') {
      return lib.where((ex) {
        String nameLower = ex.name.toLowerCase();

        // Home gym expected equipment
        final homeReq = [
          'Squat Rack, Barbell',
          'Bench Press, Barbell',
          'Smith Machine',
          '45 Degree Hip Extension',
          'Leg Extension Machine',
          'Seated Leg Curl Machine',
          'Standing Leg Curl Machine',
          'lying Leg Curl Machine',
          'Leg Press',
          'Hack Squat',
          'Chest Press Machine',
          'Seated Row',
          'Lat Pull Down',
          'Cable Stack',
          'Suspension Training system',
          'Seated Calf Raise',
        ];

        // Missing equipment lookup
        final missing = <String, bool>{};
        for (final item in homeReq) {
          final key = item.toLowerCase();
          missing[item] = !ownedLower.any((e) => e.contains(key));
        }

        bool keep = true;

        final hasSquatRack   = !missing['Squat Rack, Barbell']!;
        final hasBenchPress  = !missing['Bench Press, Barbell']!;
        final hasSmith       = !missing['Smith Machine']!;
        final hasHipExt      = !missing['45 Degree Hip Extension']!;
        final hasLegExt      = !missing['Leg Extension Machine']!;
        final hasSeatedCurl  = !missing['Seated Leg Curl Machine']!;
        final hasStandingCurl= !missing['Standing Leg Curl Machine']!;
        final hasLyingCurl   = !missing['lying Leg Curl Machine']!;
        final hasLegPress    = !missing['Leg Press']!;
        final hasHackSquat   = !missing['Hack Squat']!;
        final hasChestPress  = !missing['Chest Press Machine']!;
        final hasSeatedRow   = !missing['Seated Row']!;
        final hasLatPull     = !missing['Lat Pull Down']!;
        final hasCableStack  = !missing['Cable Stack']!;
        final hasSuspension  = !missing['Suspension Training system']!;
        final hasSeatedCalf  = !missing['Seated Calf Raise']!;

        // Apply equipment-based exclusions
        if (!hasSquatRack && (nameLower.contains('squat') || nameLower.contains('barbell'))) keep = false;
        if (keep && !hasBenchPress && nameLower.contains('bench press')) keep = false;
        if (keep && !hasSmith && nameLower.contains('smith')) keep = false;
        if (keep && !hasHipExt && nameLower.contains('hip extension')) keep = false;
        if (keep && !hasLegExt && nameLower.contains('leg extension')) keep = false;

        if (keep && !hasSeatedCurl && nameLower.contains('seated leg curl')) keep = false;
        if (keep && !hasStandingCurl && nameLower.contains('standing leg curl')) keep = false;
        if (keep && !hasLyingCurl && nameLower.contains('lying leg curl')) keep = false;

        if (keep && !hasLegPress && nameLower.contains('leg press')) keep = false;
        if (keep && !hasHackSquat && nameLower.contains('hack squat')) keep = false;
        if (keep && !hasChestPress && nameLower.contains('chest press')) keep = false;
        if (keep && !hasSeatedRow && nameLower.contains('seated row')) keep = false;
        if (keep && !hasLatPull && nameLower.contains('lat pull')) keep = false;

        // Cable dependency filter
        if (!hasCableStack) {
          final isCableDependent =
              nameLower.contains('bayesian') ||
                  nameLower.contains('lat prayer') ||
                  nameLower.contains('triceps push down') ||
                  nameLower.contains('triceps pushdown') ||
                  nameLower.contains('cable');

          if (keep && isCableDependent) keep = false;
        }

        if (keep && !hasSuspension && nameLower.contains('suspended')) keep = false;
        if (keep && !hasSeatedCalf && nameLower.contains('seated calf')) keep = false;

        return keep;
      }).toList();
    }

    // ─────────────────────────────────────────────────────────────
    // POWERLIFTING GYM RULES
    // ─────────────────────────────────────────────────────────────
    if (env == 'powerlifting') {
      // Booleans: does the user *have* each thing?
      bool hasLegExtensionMachine =
      ownedLower.contains('leg extension machine');

      bool hasSeatedLegCurlMachine =
      ownedLower.contains('seated leg curl machine');

      bool hasStandingLegCurlMachine =
      ownedLower.contains('standing leg curl machine');

      bool hasLyingLegCurlMachine =
      ownedLower.contains('lying leg curl machine');

      bool hasLegPress =
      ownedLower.contains('leg press');

      bool hasLatPullDown =
          ownedLower.contains('lat pull down') ||
              ownedLower.contains('lat pulldown');

      bool hasCableStack =
      ownedLower.contains('cable stack');

      bool hasSuspension =
      ownedLower.any((s) =>
      s.contains('suspension training') || s.contains('trx'));

      bool has45HipExt =
      ownedLower.contains('45 degree hip extension');

      bool hasHackSquat =
      ownedLower.contains('hack squat');

      bool hasMachineHipThrust =
      ownedLower.contains('machine hip thrust');

      bool hasSeatedCalfRaiseEquip =
      ownedLower.contains('seated calf raise');

      // Standing calf raise can be done on either a standing calf machine OR smith
      bool hasStandingCalfOrSmith =
          ownedLower.contains('standing calf raise') ||
              ownedLower.contains('smith machine');

      debugPrint(
          '🏋️ [EQ] powerlifting: '
              'legExt=$hasLegExtensionMachine, '
              'LCurl(seated)=$hasSeatedLegCurlMachine, '
              'LCurl(standing)=$hasStandingLegCurlMachine, '
              'LCurl(lying)=$hasLyingLegCurlMachine, '
              'legPress=$hasLegPress, '
              'latPD=$hasLatPullDown, '
              'cableStack=$hasCableStack, '
              'suspension=$hasSuspension, '
              '45HipExt=$has45HipExt, '
              'hackSquat=$hasHackSquat, '
              'machHipThrust=$hasMachineHipThrust, '
              'seatedCalf=$hasSeatedCalfRaiseEquip, '
              'standingCalfOrSmith=$hasStandingCalfOrSmith');

      final out = lib.where((ex) {
        bool keep = true;
        final nameLower = ex.name.toLowerCase().trim();
        final cat = _normCat(ex.category);

        // Leg Extension Machine → all Leg Extension category
        if (keep &&
            !hasLegExtensionMachine &&
            cat == 'Leg Extension') {
          keep = false;
        }

        // Seated Leg Curl Machine → seated leg curl
        if (keep &&
            !hasSeatedLegCurlMachine &&
            cat == 'Leg Curl' &&
            nameLower.contains('seated')) {
          keep = false;
        }

        // Standing Leg Curl Machine → standing leg curl
        if (keep &&
            !hasStandingLegCurlMachine &&
            cat == 'Leg Curl' &&
            nameLower.contains('standing')) {
          keep = false;
        }

        // Lying Leg Curl Machine → lying leg curl
        if (keep &&
            !hasLyingLegCurlMachine &&
            cat == 'Leg Curl' &&
            nameLower.contains('lying')) {
          keep = false;
        }

        // Leg Press machine → any leg press
        if (keep &&
            !hasLegPress &&
            nameLower.contains('leg press')) {
          keep = false;
        }

        // Lat Pull Down → all lat pulldown variants
        if (keep &&
            !hasLatPullDown &&
            (nameLower.contains('lat pull down') ||
                nameLower.contains('lat pulldown'))) {
          keep = false;
        }

        // Cable Stack → ONLY remove exercises that are truly cable-dependent.
// (We avoid blanket nameLower.contains('cable') because many exercises
// include "cable" in the name but are substitutable.)
        if (!hasCableStack) {
          final isCableDependent =
              nameLower.contains('bayesian') ||
                  nameLower.contains('lat prayer') ||
                  nameLower.contains('triceps push down') ||
                  nameLower.contains('cable') ||
                  nameLower.contains('Face Pull') ||
                  nameLower.contains('triceps pushdown'); // covers wording variations

          if (keep && isCableDependent) {
            keep = false;
          }
        }


        // Suspension Training system → any "suspended" exercise
        if (keep &&
            !hasSuspension &&
            nameLower.contains('suspended')) {
          keep = false;
        }

        // 45 Degree Hip Extension
        if (keep &&
            !has45HipExt &&
            nameLower.contains('45 degree hip extension')) {
          keep = false;
        }

        // Hack Squat
        if (keep &&
            !hasHackSquat &&
            nameLower.contains('hack squat')) {
          keep = false;
        }

        // Machine Hip Thrust
        if (keep &&
            !hasMachineHipThrust &&
            nameLower.contains('machine hip thrust')) {
          keep = false;
        }

        // Seated Calf Raise
        if (keep &&
            !hasSeatedCalfRaiseEquip &&
            cat == 'Calf Raise' &&
            nameLower.contains('seated')) {
          keep = false;
        }

        // Standing Calf Raise (needs either standing calf machine OR Smith)
        if (keep &&
            !hasStandingCalfOrSmith &&
            cat == 'Calf Raise' &&
            nameLower.contains('standing')) {
          keep = false;
        }

        return keep;
      }).toList();

      debugPrint(
          '🏋️ [EQ] After powerlifting equipment filters → final size=${out.length} (removed ${lib.length - out.length})');
      return out;
    }



    // ─────────────────────────────────────────────────────────────
    // DEFAULT / COMMERCIAL RULES (your original 7-item list)
    // ─────────────────────────────────────────────────────────────
    const List<String> restrictedEquipment = [
      '45 Degree Hip Extension',
      'Hack Squat',
      'Triceps Dip Machine',
      'Machine Hip Thrust',
      'Suspension Training System (like TRX)',
      'Seated leg curl',
      'Seated Calf Raise',
    ];

    final missing = <String>{};
    for (final req in restrictedEquipment) {
      final hasIt = owned.any(
            (o) => o.toLowerCase().trim() == req.toLowerCase().trim(),
      );
      if (!hasIt) missing.add(req);
    }

    if (missing.isEmpty) {
      debugPrint(
          '🏋️ [EQ] commercial/default: all restricted equipment present → no filters; size=${lib.length}');
      return lib;
    }

    debugPrint('🏋️ [EQ] commercial/default: missing equipment items: $missing');
    debugPrint(
        '🏋️ [EQ] Applying equipment filters → starting size=${lib.length}');

    final out = lib.where((ex) {
      bool keep = true;
      final name = ex.name;
      final nameLower = name.toLowerCase().trim();

      // If Suspension / TRX is missing, drop any exercise with "suspended" in the name
      if (keep &&
          missing.contains('Suspension Training System (like TRX)') &&
          nameLower.contains('suspended')) {
        keep = false;
      }

      // For other missing equipment, drop the SINGLE matching exercise by name
      if (keep) {
        for (final eq in missing) {
          if (eq == 'Suspension Training System (like TRX)') {
            // already handled
            continue;
          }
          if (nameLower == eq.toLowerCase().trim()) {
            keep = false;
            break;
          }
        }
      }

      return keep;
    }).toList();

    debugPrint(
        '🏋️ [EQ] After commercial/default equipment filters → final size=${out.length} (removed ${lib.length - out.length})');

    return out;
  }



  /// Apply injury / pain-slider filters to the working exercise library.
  ///
  /// Expects onboarding['injuries'] to be a map like:
  /// {
  ///   'lowerBack': 0..10,
  ///   'shoulder' : 0..10,
  ///   'elbow'    : 0..10,
  ///   'knee'     : 0..10,
  /// }
  // Apply injury-based filters to the working exercise library.
  // Reads pain sliders from onboarding['painNow'].
  static List<ExLite> _applyInjuryFilters({
    required List<ExLite> lib,
    required Map<String, dynamic> onboarding,
  })
  {
    int lowerBack = 0;
    int shoulder  = 0;
    int elbow     = 0;
    int knee      = 0;

    // 🔎 Read from onboarding.painNow (case-insensitive key matching)
    final painRaw = onboarding['painNow'];
    if (painRaw is Map) {
      final painMap = Map<String, dynamic>.from(painRaw as Map);
      painMap.forEach((k, v) {
        final key = k.toString().toLowerCase().trim();

        int? val;
        if (v is int) {
          val = v;
        } else if (v is num) {
          val = v.toInt();
        } else if (v is String) {
          val = int.tryParse(v);
        }
        if (val == null) return;

        if (key.contains('lower back')) {
          lowerBack = val;
        } else if (key.contains('shoulder')) {
          shoulder = val;
        } else if (key.contains('elbow')) {
          elbow = val;
        } else if (key.contains('knee')) {
          knee = val;
        }
      });
    }

    // Shoulder cause flags from onboarding root doc
    final bool shoulderPainFront    = onboarding['shoulderPainFront'] == true;
    final bool shoulderPainOverhead = onboarding['shoulderPainOverhead'] == true;

    // Elbow cause flags from onboarding root doc
    final bool elbowPainInside  = onboarding['elbowPainInside'] == true;
    final bool elbowPainOutside = onboarding['elbowPainOutside'] == true;


    // 🩹 Debug: print levels every time
    debugPrint(
        '🩹 [INJ] Injury levels: '
            'lowerBack=$lowerBack, shoulder=$shoulder, elbow=$elbow, knee=$knee');
    debugPrint(
        '🩹 [INJ] Shoulder cause flags: front=$shoulderPainFront, overhead=$shoulderPainOverhead');

    // 🩹 Debug: print levels every time
    debugPrint(
        '🩹 [INJ] Injury levels: '
            'lowerBack=$lowerBack, shoulder=$shoulder, elbow=$elbow, knee=$knee');
    debugPrint(
        '🩹 [INJ] Shoulder cause flags: front=$shoulderPainFront, overhead=$shoulderPainOverhead');
    debugPrint(
        '🩹 [INJ] Elbow cause flags: inside=$elbowPainInside, outside=$elbowPainOutside');


    // Fast-path: nothing to filter
    if (lowerBack == 0 && shoulder == 0 && elbow == 0 && knee == 0) {
      debugPrint(
          '🩹 [INJ] No injury filters applied → library size = ${lib.length}');
      return lib;
    }

    // Decide which pressing directions to eliminate for shoulder pain > 3
    bool elimShoulderHP = false; // Horizontal Press
    bool elimShoulderVP = false; // Vertical Press

    if (shoulder > 3) {
      if (shoulderPainFront && !shoulderPainOverhead) {
        // Pain only on horizontal pressing
        elimShoulderHP = true;
        elimShoulderVP = false;
      } else if (shoulderPainOverhead && !shoulderPainFront) {
        // Pain only on vertical pressing
        elimShoulderHP = false;
        elimShoulderVP = true;
      } else {
        // Both checked OR neither checked → eliminate both
        elimShoulderHP = true;
        elimShoulderVP = true;
      }
    }

    debugPrint(
        '🩹 [INJ] Shoulder rule → elimHP=$elimShoulderHP, elimVP=$elimShoulderVP');

    debugPrint(
        '🩹 [INJ] Applying injury filters → starting size = ${lib.length}');


    final out = lib.where((ex) {
      final name = ex.name.toLowerCase();
      final cat  = _normCat(ex.category);

      bool keep = true;

      // ───────────── LOWER BACK ─────────────
      if (keep && lowerBack > 1) {
        // Remove anything with the word "deadlift" in the name
        if (name.contains('deadlift')) keep = false;
      }
      if (keep && lowerBack > 2) {
        // Eliminate Hip Hinge category
        if (cat == 'Hip Hinge') keep = false;
      }
      if (keep && lowerBack > 3) {
        // Eliminate Squat Pattern
        if (cat == 'Squat Pattern') keep = false;

        // Core: keep only *plank* variants, but NOT weighted plank
        if (cat == 'Core') {
          final hasPlank = name.contains('plank');
          final isWeightedPlank = hasPlank && name.contains('weighted');
          if (!hasPlank || isWeightedPlank) {
            keep = false;
          }
        }
      }
      if (keep && lowerBack > 4) {
        // Eliminate Vertical Press
        if (cat == 'Vertical Press') keep = false;

        // Eliminate anything with "row" in the name,
        // except "suspended high row" and "bar high row".
        if (keep && name.contains('row')) {
          final isSuspendedHighRow =
              name.contains('suspended') && name.contains('row');
          final isBarHighRow =
              name.contains('bar') && name.contains('row');
          if (!isSuspendedHighRow && !isBarHighRow) {
            keep = false;
          }
        }

        // Eliminate Leg Curl category
        if (keep && cat == 'Leg Curl') keep = false;

        // 🆕 Eliminate Butterfly Dumbbell Raise for back pain > 4
        if (keep &&
            name.contains('butterfly') &&
            name.contains('dumbbell') &&
            name.contains('raise')) {
          keep = false;
        }
      }

      if (keep && lowerBack > 5) {
        // Eliminate Leg Extension
        if (cat == 'Leg Extension') keep = false;

        // Eliminate all Calf Raise except "seated calf raise"
        if (cat == 'Calf Raise') {
          final isSeatedCalfRaise =
              name.contains('seated') && name.contains('calf');
          if (!isSeatedCalfRaise) keep = false;
        }
      }

      // ───────────── SHOULDERS ─────────────
      if (keep && shoulder > 3) {
        if (elimShoulderHP && cat == 'Horizontal Press') {
          keep = false;
        } else if (elimShoulderVP && cat == 'Vertical Press') {
          keep = false;
        }
      }


      // ───────────── ELBOW ─────────────
      // Inside elbow pain (medial) rules
      if (keep && elbow > 2 && elbowPainInside) {
        final nNorm = ex.name.toLowerCase().trim();

        // Specific inside offenders
        const bannedInsideNames = [
          'chin-up',
          'chin up',
          'chinup',
          'lat pull down, unilateral',
          'lat pulldown, unilateral',
          'lat pull down, supinated',
          'lat pulldown, supinated',
        ];

        if (bannedInsideNames.contains(nNorm)) {
          keep = false;
        }

        // All Arm Curl category
        if (keep && cat == 'Arm Curl') keep = false;
      }

      if (keep && elbow > 4 && elbowPainInside) {
        // Eliminate all Vertical Pull category
        if (cat == 'Vertical Pull') keep = false;
      }

      if (keep && elbow > 6 && elbowPainInside) {
        // Eliminate all Horizontal Pull category
        if (cat == 'Horizontal Pull') keep = false;
      }

      // Outside elbow pain (lateral) rules
      if (keep && elbow > 4 && elbowPainOutside) {
        // Eliminate all Vertical Press
        if (cat == 'Vertical Press') keep = false;

        // Eliminate Arm Extension *with* "overhead" in the name
        if (keep && cat == 'Arm Extension' && name.contains('overhead')) {
          keep = false;
        }
      }

      if (keep && elbow > 5 && elbowPainOutside) {
        // Eliminate all Horizontal Press
        if (cat == 'Horizontal Press') keep = false;

        // Eliminate all remaining Arm Extension
        if (keep && cat == 'Arm Extension') {
          keep = false;
        }
      }


      // ───────────── KNEES ─────────────
      if (keep && knee > 4) {
        // Eliminate Leg Extension category
        if (cat == 'Leg Extension') keep = false;
      }

      if (keep && knee > 6) {
        // Eliminate Squat Pattern + Leg Curl
        if (cat == 'Squat Pattern' || cat == 'Leg Curl') {
          keep = false;
        }
      }

      // (knee > 7 re-elim leg curl is redundant; covered by >6)

      return keep;
    }).toList();

    debugPrint(
        '🩹 [INJ] After injury filters → final size = ${out.length}');

    return out;
  }



  // ---------- Helpers ----------

  // Accept both flat Firestore dumps and byCategory maps.
  // Replace the entire _loadExerciseLibrary() with this:
  static Future<List<ExLite>> _loadExerciseLibrary() async {
    final raw = await rootBundle.loadString(_assetPath);
    final decoded = json.decode(raw);

    List<Map<String, dynamic>> items;

    if (decoded is List) {
      // Top-level flat list
      items = decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } else if (decoded is Map<String, dynamic>) {
      if (decoded['exercises'] is List) {
        // { "exercises": [ ... ] }
        items = (decoded['exercises'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } else {
        // { "Arm Curl": [ {...}, ... ], "Arm Extension": [ ... ], ... }
        final flattened = <Map<String, dynamic>>[];
        decoded.forEach((categoryKey, value) {
          if (value is List) {
            for (final e in value) {
              if (e is Map) {
                final m = Map<String, dynamic>.from(e as Map);
                // Ensure category is present; inject from the map key if missing
                m.putIfAbsent('category', () => categoryKey.toString());
                flattened.add(m);
              }
            }
          }
        });
        items = flattened;
      }
    } else {
      throw StateError('Unexpected exercises asset shape for $_assetPath');
    }

    return items.map((m) => ExLite.fromMap(m)).toList();
  }

// 🆕 Fetch planned exercise IDs from Block Planner → /users/{uid}/block_planner/current_block
  static Future<Set<String>> _fetchPlannedExerciseIds(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('block_planner')
          .doc('current_block')
          .get();

      if (!doc.exists) {
        debugPrint('🧩 [GEN] planned-only: current_block missing for uid=$uid');
        return const {};
      }

      final data = doc.data();
      if (data == null) return const {};

      // plannedExercises is expected to be an array of exercise IDs
      final list = (data['plannedExercises'] as List?)?.map((e) => e.toString()).toList() ?? const [];
      final ids = Set<String>.from(list);

      debugPrint('🧩 [GEN] planned-only: fetched ${ids.length} planned exercise ids');
      return ids;
    } catch (e, st) {
      debugPrint('❌ [GEN] planned-only fetch failed: $e\n$st');
      return const {};
    }
  }


  static int? _readWeeklyFrequency(Map<String, dynamic> onb) {
    final wf = onb['weeklyFrequency'];
    final legacy = onb['minTrainingDaysPerWeek'];
    if (wf is int) return wf;
    if (legacy is int) return legacy;
    return null;
  }

  // Read emphasis level (0..3) from onboarding. Accepts { emphasis: { key: 0..3 } } or strings.
  static int _readEmphasisLevel(Map<String, dynamic> onb, String key) {
    final raw = onb['emphasis'] ?? onb['bodyFocus'] ?? onb['muscleEmphasis'];
    if (raw is Map) {
      final v = raw[key];
      if (v is int) return v.clamp(0, 3);
      if (v is String) {
        final p = int.tryParse(v);
        if (p != null) return p.clamp(0, 3);
      }
    }
    return 0; // default = no emphasis
  }

// Map categories to emphasis levels (0..3). Start with Calves only.
  static Map<String, int> _buildCategoryEmphasis(Map<String, dynamic> onb) {
    return <String, int>{
      // Existing
      'Calf Raise'      : _readEmphasisLevel(onb, 'calves'),
      'Arm Curl'        : _readEmphasisLevel(onb, 'biceps'),
      'Arm Extension'   : _readEmphasisLevel(onb, 'triceps'),
      'Horizontal Press': _readEmphasisLevel(onb, 'chest'),
      'Vertical Pull'   : _readEmphasisLevel(onb, 'lats'),

      // 🆕 Quads → Squat Pattern & Leg Extension
      'Squat Pattern'   : _readEmphasisLevel(onb, 'quads'),
      'Leg Extension'   : _readEmphasisLevel(onb, 'quads'),

      // 🆕 Hamstrings → Hip Hinge & Leg Curl
      'Hip Hinge'       : _readEmphasisLevel(onb, 'hamstrings'),
      'Leg Curl'        : _readEmphasisLevel(onb, 'hamstrings'),

      // 🆕 Abs → Core
      'Core'            : _readEmphasisLevel(onb, 'abs'),

      // Optional: Glutes → Hip Abduction / Hip Hinge / Squat Pattern if you want
      // 'Hip Abduction' : _readEmphasisLevel(onb, 'glutes'),
    };
  }


  // Max emphasis-driven minimums per category (default ceiling = 3)
  static const Map<String, int> _emphasisMinCeilByCat = {
    'Horizontal Press': 5, // chest can scale up to 4
    // everything else defaults to 3
  };



  // Frequency caps by sex, for ≥4 days/wk baseline; we’ll reduce max if fewer days.
  static Map<String, Map<String, int>> _capsFor({required bool isFemale}) {
    if (isFemale) {
      return {
        'Horizontal Press': {'min': 1, 'max': 5},
        'Vertical Press'  : {'min': 0, 'max': 5},
        'Horizontal Pull' : {'min': 1, 'max': 4},
        'Vertical Pull'   : {'min': 1, 'max': 6},
        'Lateral Raise'   : {'min': 0, 'max': 4},
        'Arm Extension'   : {'min': 1, 'max': 4},
        'Arm Curl'        : {'min': 1, 'max': 2},
        'Squat Pattern'   : {'min': 2, 'max': 6},
        'Leg Extension'   : {'min': 1, 'max': 4},
        'Hip Hinge'       : {'min': 1, 'max': 6}, // max deadlift 2/wk is enforced at choose-time
        'Leg Curl'        : {'min': 2, 'max': 5},
        'Calf Raise'      : {'min': 0, 'max': 5}, // 🆕 allow up to 3x/wk
        'Hip Abduction'   : {'min': 1, 'max': 5}, // 🆕 allow up to 3x/wk
        'Core'            : {'min': 1, 'max': 7}, // we’ll cap by per-day pairing/circuits anyway
      };
    }
    // Male/default
    return {
      'Horizontal Press': {'min': 1, 'max': 6},
      'Vertical Press'  : {'min': 1, 'max': 6},
      'Horizontal Pull' : {'min': 1, 'max': 6},
      'Vertical Pull'   : {'min': 1, 'max': 6},
      'Lateral Raise'   : {'min': 1, 'max': 6},
      'Arm Extension'   : {'min': 1, 'max': 6},
      'Arm Curl'        : {'min': 1, 'max': 6},
      'Squat Pattern'   : {'min': 1, 'max': 4},
      'Leg Extension'   : {'min': 1, 'max': 4},
      'Hip Hinge'       : {'min': 1, 'max': 4}, // max deadlift 2/wk enforced later
      'Leg Curl'        : {'min': 1, 'max': 4},
      'Calf Raise'      : {'min': 1, 'max': 5}, // 🆕 allow up to 3x/wk
      'Core'            : {'min': 1, 'max': 5},
    };
  }

  // Order we try to allocate categories so key work gets space first.
  // Order we try to allocate categories so key work gets space first — sex-specific.
  static const List<String> _orderedCategoriesPriorityMale = [
    'Horizontal Press',
    'Squat Pattern',
    'Hip Hinge',
    'Vertical Pull',
    'Vertical Press',
    'Horizontal Pull',
    'Arm Extension',
    'Arm Curl',
    'Lateral Raise',
    'Leg Curl',
    'Leg Extension',
    'Calf Raise',
    'Core',
  ];

  static const List<String> _orderedCategoriesPriorityFemale = [
    'Squat Pattern',
    'Hip Hinge',
    'Leg Curl',
    'Horizontal Press',
    'Hip Abduction',
    'Vertical Pull',
    'Horizontal Pull',
    'Vertical Press',
    'Leg Extension',
    'Core',
    'Arm Extension',
    'Calf Raise',
    'Arm Curl',
    'Lateral Raise',

  ];

  static List<String> _orderedCategoriesPriorityFor({required bool isFemale}) =>
      isFemale ? _orderedCategoriesPriorityFemale : _orderedCategoriesPriorityMale;


  // ── Weekly minimums by sex ────────────────────────────────────────────────
  static void _enforceWeeklyMinimums({
    required bool isFemale,
    required Map<String, int> weeklyPlan,
    required Map<String, Map<String, int>> freqCaps,
    required Map<String, List<ExLite>> byCat,
    Map<String, int> categoryEmphasis = const {}, // emphasis 0..3
  }) {

    // Helper: bump only if emphasis > 0
    void bumpIfEmphasised(String cat, int forcedMin) {
      final emph = categoryEmphasis[cat] ?? 0;

      if (emph > 0) {
        final caps = freqCaps[cat];
        if (caps == null) return;

        final cappedValue = forcedMin.clamp(caps['min']!, caps['max']!);
        if (weeklyPlan[cat] == null || weeklyPlan[cat]! < cappedValue) {
          weeklyPlan[cat] = cappedValue;
        }
      }
      // If emph == 0 → skip → capsFor()[cat]['min'] becomes the true min.
    }

    // Alias for clarity
    void bumpWithEmphasis(String cat, int forcedMin) {
      bumpIfEmphasised(cat, forcedMin);
    }

    // ────────────────────────────────────────────────────────────────
    //                            FEMALE
    // ────────────────────────────────────────────────────────────────
    if (isFemale) {
      bumpIfEmphasised('Squat Pattern', 2);
      bumpIfEmphasised('Hip Hinge', 1);
      bumpIfEmphasised('Leg Curl', 2);
      bumpIfEmphasised('Leg Extension', 0);
      bumpIfEmphasised('Core', 2);

      bumpWithEmphasis('Horizontal Press', 0);
      bumpWithEmphasis('Vertical Press', 0);

      bumpWithEmphasis('Horizontal Pull', 0);
      bumpWithEmphasis('Vertical Pull', 0);

      bumpWithEmphasis('Lateral Raise', 0);
      bumpWithEmphasis('Arm Curl', 0);
      bumpWithEmphasis('Arm Extension', 0);
    }

    // ────────────────────────────────────────────────────────────────
    //                             MALE
    // ────────────────────────────────────────────────────────────────
    else {
      bumpIfEmphasised('Squat Pattern', 2);
      bumpIfEmphasised('Hip Hinge', 1);
      bumpIfEmphasised('Leg Curl', 0);
      bumpIfEmphasised('Leg Extension', 0);

      bumpIfEmphasised('Core', 2);

      bumpIfEmphasised('Horizontal Press', 2);
      bumpWithEmphasis('Vertical Press', 0);

      bumpWithEmphasis('Horizontal Pull', 1);
      bumpWithEmphasis('Vertical Pull', 1);

      bumpWithEmphasis('Lateral Raise', 0);
      bumpWithEmphasis('Arm Curl', 0);
      bumpWithEmphasis('Arm Extension', 0);
    }
  }


  // ── Daily “minimum per day” preference sets (soft/first-pass seeding) ─────
  // Each entry is a list of alternatives; we’ll try them in order.
  static const List<List<String>> _maleDailyPrefSets = [
    // One horizontal press
    ['Horizontal Press'],
    // One vertical pull or one horizontal pull
    ['Vertical Pull', 'Horizontal Pull'],
    // One vertical press (or lateral raise)
    ['Vertical Press', 'Lateral Raise'],
    // One arm curl or arm extension
    ['Arm Curl', 'Arm Extension'],
    // One from lower-body/supporting set
    ['Squat Pattern', 'Hip Hinge', 'Core', 'Leg Curl', 'Leg Extension' /* 'Calf Raise' if present */],
  ];

  static const List<List<String>> _femaleDailyPrefSets = [
    // One horizontal press or one vertical press (or lateral raise)
    ['Horizontal Press', 'Vertical Press', 'Lateral Raise'],
    // One vertical pull or one horizontal pull
    ['Vertical Pull', 'Horizontal Pull'],
    // One squat pattern or hip hinge
    ['Squat Pattern', 'Hip Hinge'],
    // One leg curl or hip abduction
    ['Leg Curl', 'Hip Abduction' /* if present */],
    // One arm curl or arm extension
    ['Arm Curl', 'Arm Extension'],
    // One leg extension or calf raise
    ['Leg Extension', 'Calf Raise' /* if present */],
  ];

  // Try to place exactly one exercise from any of the categories in `choices`.
  // Respects overlap/pairing by using the existing chooser + circuit placer.
  static bool _trySeedOneFrom({
    required _DayPlan day,
    required List<String> choices,
    required Map<String, List<ExLite>> byCat,
    required List<_DayPlan> allDays,
    Map<String,int>? idTargetsRemaining,  // 🆕
    bool isMale = false,
  }) {
    for (final cat in choices) {
      final pool = byCat[cat];
      if (pool == null || pool.isEmpty) continue;

      final picked = _chooseExercise(
        pool: pool,
        day: day,
        category: cat,
        allDays: allDays,
        idTargetsRemaining: idTargetsRemaining, // 🆕
        isMale: isMale,
      );

      if (picked == null) continue;
      final ci = _placeIntoCircuit(day, picked);
      day.addExercise(picked, cat, ci);
      return true;
    }
    return false;
  }



  // Seed a day with the preferred “minimum per day” set for the given sex.
  static void _seedDailyMinimums({
    required List<_DayPlan> days,
    required bool isFemale,
    required Map<String, List<ExLite>> byCat,
    required List<_DayPlan> allDays,
    required Map<String,int> idTargetsRemaining,
    required bool isHypertrophyMale,
    required int requiredHPullPrimaryDays,
    required Map<String, int> weeklyPlan,
    required Map<String, int> seededCountByCategory,
    required int userAge,   // 👈 NEW
  })
  {
    final sets = isFemale ? _femaleDailyPrefSets : _maleDailyPrefSets;
    final int weeklyFrequency = days.length;

    // 🧮 Helper: total presses (HP + VP) already on this day
    int _pressesToday(_DayPlan d) {
      return (d.countByCategory['Horizontal Press'] ?? 0) +
          (d.countByCategory['Vertical Press'] ?? 0);
    }

    // 🧮 Helper: check & record category usage vs weeklyPlan
    bool _canSeedCategory(String cat) {
      final cap = weeklyPlan[cat];
      if (cap == null) return true; // if not in plan, treat as uncapped
      final seeded = seededCountByCategory[cat] ?? 0;
      return seeded < cap;
    }

    void _recordSeed(String cat) {
      seededCountByCategory[cat] = (seededCountByCategory[cat] ?? 0) + 1;
    }

    // For hypertrophy-focused males, we want on ~ (weeklyFrequency - 1) days:
    //   Circuit 0: [Horizontal Press, Horizontal Pull]
    //   Circuit 1: [Vertical Press (or Lateral Raise if needed), Vertical Pull]
    int remainingHPullPrimaryDays = isHypertrophyMale
        ? (requiredHPullPrimaryDays > weeklyFrequency
        ? weeklyFrequency
        : requiredHPullPrimaryDays)
        : 0;

    for (final d in days) {
      // 🧩 Special seeding for hypertrophy-focused males:
      // Try to pre-build:
      //   Circuit 0 → [Horizontal Press, Horizontal Pull]
      //   Circuit 1 → [Vertical Press (or LR fallback), Vertical Pull]
      if (isHypertrophyMale && remainingHPullPrimaryDays > 0) {
        final hpPool       = byCat['Horizontal Press'];
        final hPullPool    = byCat['Horizontal Pull'];
        final vPressPool   = byCat['Vertical Press'];
        final latRaisePool = byCat['Lateral Raise'];
        final vPullPool    = byCat['Vertical Pull'];

        final bool haveHP      = hpPool != null && hpPool.isNotEmpty;
        final bool haveHPull   = hPullPool != null && hPullPool.isNotEmpty;
        final bool haveVPress  = vPressPool != null && vPressPool.isNotEmpty;
        final bool haveLatR    = latRaisePool != null && latRaisePool.isNotEmpty;
        final bool haveVPull   = vPullPool != null && vPullPool.isNotEmpty;

        // ── Circuit 0: Horizontal Press → Horizontal Pull ────────────────────
        if (haveHP &&
            haveHPull &&
            _canSeedCategory('Horizontal Press') &&
            _pressesToday(d) < 2) {

          // Step A: Horizontal Press first
          final hp = _chooseExercise(
            pool: hpPool!,
            day: d,
            category: 'Horizontal Press',
            allDays: allDays,
            idTargetsRemaining: idTargetsRemaining,
            isMale: !isFemale,
          );

          if (hp != null) {
            final hpCircuitIdx = _placeIntoCircuit(d, hp); // usually creates circuit 0
            d.addExercise(hp, 'Horizontal Press', hpCircuitIdx);
            _recordSeed('Horizontal Press');

            // Step B: Horizontal Pull second, ideally in the same circuit 0
            if (_canSeedCategory('Horizontal Pull')) {
              final hPull = _chooseExercise(
                pool: hPullPool!,
                day: d,
                category: 'Horizontal Pull',
                allDays: allDays,
                idTargetsRemaining: idTargetsRemaining,
                isMale: !isFemale,
              );

              if (hPull != null) {
                int targetCircuit = 0;
                if (d.circuits.isNotEmpty && _canJoin(d, 0, hPull)) {
                  targetCircuit = 0; // pair with the press
                } else {
                  targetCircuit = _placeIntoCircuit(d, hPull);
                }
                d.addExercise(hPull, 'Horizontal Pull', targetCircuit);
                _recordSeed('Horizontal Pull');
              }
            }
          }
        }

        // ── Circuit 1: Vertical Press (or LR) → Vertical Pull ────────────────
        if (haveVPull && (haveVPress || haveLatR)) {
          ExLite? firstC1;
          String? firstC1Category;

          // First exercise for Circuit 1: prefer Vertical Press,
          // but if it can't be placed and weeklyFrequency > 2,
          // we allow Lateral Raise as a flexible alternative.
          if (haveVPress &&
              _canSeedCategory('Vertical Press') &&
              _pressesToday(d) < 2) {
            final vp = _chooseExercise(
              pool: vPressPool!,
              day: d,
              category: 'Vertical Press',
              allDays: allDays,
              idTargetsRemaining: idTargetsRemaining,
              isMale: !isFemale,
            );

            if (vp != null) {
              firstC1 = vp;
              firstC1Category = 'Vertical Press';
            }
          }

          // Flexible Lateral Raise option (only if we couldn't place VP)
          if (firstC1 == null &&
              weeklyFrequency > 2 &&
              haveLatR &&
              _canSeedCategory('Lateral Raise')) {
            final lr = _chooseExercise(
              pool: latRaisePool!,
              day: d,
              category: 'Lateral Raise',
              allDays: allDays,
              idTargetsRemaining: idTargetsRemaining,
              isMale: !isFemale,
            );
            if (lr != null) {
              firstC1 = lr;
              firstC1Category = 'Lateral Raise';
            }
          }

          if (firstC1 != null && firstC1Category != null) {
            int circuitIdx1;
            // If circuit 1 exists and we can join it, prefer that.
            if (d.circuits.length > 1 && _canJoin(d, 1, firstC1)) {
              circuitIdx1 = 1;
            } else {
              // Otherwise, place and let it create the best circuit (likely index 1).
              circuitIdx1 = _placeIntoCircuit(d, firstC1);
            }
            d.addExercise(firstC1, firstC1Category, circuitIdx1);
            _recordSeed(firstC1Category);

            // Second exercise for Circuit 1: Vertical Pull
            if (_canSeedCategory('Vertical Pull')) {
              final vPull = _chooseExercise(
                pool: vPullPool!,
                day: d,
                category: 'Vertical Pull',
                allDays: allDays,
                idTargetsRemaining: idTargetsRemaining,
                isMale: !isFemale,
              );

              if (vPull != null) {
                int targetCircuit = circuitIdx1;
                if (d.circuits.length > circuitIdx1 &&
                    _canJoin(d, circuitIdx1, vPull)) {
                  targetCircuit = circuitIdx1;
                } else {
                  targetCircuit = _placeIntoCircuit(d, vPull);
                }
                d.addExercise(vPull, 'Vertical Pull', targetCircuit);
                _recordSeed('Vertical Pull');
              }
            }
          }
        }

        // We successfully attempted a "primary hypertrophy day" pattern on this day
        remainingHPullPrimaryDays--;
      }

      // 🔁 Then apply the normal daily preference sets,
      // but only from categories that still have budget left in weeklyPlan.
      for (final choiceList in sets) {
        // 🛑 Age-based circuit cap: if we've already hit the max,
        // stop seeding any further categories onto this day.
        if (d.circuits.length >= _maxCircuitsPerDay) {
          break;
        }

        // choiceList is e.g. ['Squat Pattern', 'Hip Hinge', 'Leg Curl', ...]
        final filteredChoices = choiceList.where((cat) {
          if (!_canSeedCategory(cat)) return false;

          // 🆕 Press cap: at most 2 (HP + VP) per day
          if (cat == 'Horizontal Press' || cat == 'Vertical Press') {
            if (_pressesToday(d) >= 2) return false;
          }
          return true;
        }).toList();



        if (filteredChoices.isEmpty) {
          continue; // no categories with remaining budget
        }

        // Snapshot counts before seeding one from this choice list
        final beforeCounts = Map<String, int>.from(d.countByCategory);

        _trySeedOneFrom(
          day: d,
          choices: filteredChoices,
          byCat: byCat,
          allDays: allDays,
          idTargetsRemaining: idTargetsRemaining,
          isMale: !isFemale,
        );

        // Detect which category actually got seeded and bump its counter
        d.countByCategory.forEach((cat, count) {
          final before = beforeCounts[cat] ?? 0;
          if (count > before) {
            final delta = count - before;
            if (delta > 0) {
              seededCountByCategory[cat] =
                  (seededCountByCategory[cat] ?? 0) + delta;
            }
          }
        });
      }

      // ─────────────────────────────────────────────────────────────
// Final safety trim: respect the global age-based max circuits per day.
      while (d.circuits.length > _maxCircuitsPerDay) {
        d.circuits.removeLast();
      }
    }
  }



  static bool exNameHasSquat(List<ExLite> pool) {
    for (final e in pool) {
      if (e.name.toLowerCase().contains('squat')) return true;
    }
    return false;
  }


  /// Returns an exercise that doesn't violate overlap rules *for this day*.
  static ExLite? _chooseExercise({
    required List<ExLite> pool,
    required _DayPlan day,
    required String category,
    required List<_DayPlan> allDays,
    Map<String, int>? idTargetsRemaining, // 🆕
    bool isMale = false, // male circuit-0 compound gate
  }) {

    // 🚧 Male circuit-0 compound gate (applied at every return ex; below).
    // When isMale is true and the intended circuit for the candidate is 0,
    // upper-body exercises must come from compound press/pull categories and
    // include the correct arm muscle (triceps for presses, biceps for pulls).
    bool _failsGate(ExLite ex) {
      if (!isMale) return false;
      final cat = _normCat(ex.category);
      if (!_isUpperBodyCategory(cat)) return false; // lower body is always exempt
      if (_intendedCircuit(day, ex) != 0) return false; // not targeting circuit 0
      const allowedC0 = {
        'Horizontal Press', 'Horizontal Pull', 'Vertical Press', 'Vertical Pull',
      };
      if (!allowedC0.contains(cat)) {
        if (kDebugMode) {
          debugPrint('🚧 [C0 gate] blocked isolation "$cat" (male circuit-0 rule)');
        }
        return true;
      }
      final bool isPress = cat == 'Horizontal Press' || cat == 'Vertical Press';
      final bool armOk =
          isPress ? _hasMuscleName(ex, 'triceps') : _hasMuscleName(ex, 'biceps');
      if (!armOk && kDebugMode) {
        debugPrint('🚧 [C0 gate] blocked "${ex.name}" ($cat): '
            'missing ${isPress ? "triceps" : "biceps"}');
      }
      return !armOk;
    }

    // Compute minimum circular distance from ex to any existing use in allDays.
    // Returns allDays.length when ex has never been placed (best possible score).
    int spacingScore(ExLite ex) {
      final N = allDays.length;
      if (N <= 1) return 1;
      int minDist = N;
      for (int i = 0; i < N; i++) {
        if (i == day.index) continue;
        for (final circ in allDays[i].circuits) {
          for (final p in circ) {
            if (p.ex.id == ex.id) {
              final raw = (day.index - i).abs();
              final dist = raw < N - raw ? raw : N - raw;
              if (dist < minDist) minDist = dist;
            }
          }
        }
      }
      return minDist;
    }

    // 🚫 Day-level cap: only one of each isolation category per day
    const Set<String> isoCats = {
      'Arm Curl', 'Arm Extension', 'Lateral Raise',
      'Leg Curl', 'Leg Extension', 'Core',
    };
    if (isoCats.contains(category) && (day.countByCategory[category] ?? 0) >= 1) {
      return null;
    }
    // Avoid pairing agonists / overlapping prime movers within same circuit/day:
    // - Any Horizontal Press cannot pair with Vertical Press or Arm Extension
    // - Any Horizontal Pull cannot pair with Vertical Pull or Arm Curl
    // - Hip Dominant: deadlift/RDL/hip thrust don’t pair with each other; leg curl is not hip-dominant and may pair with Squat Pattern (but hip-dominants may NOT pair with Squat Pattern)
    // - Squat Pattern cannot pair with Leg Extension in same circuit/day
    // - General: if top two muscles overlap between two exercises, avoid pairing in same circuit.

    // ✅ Variety rule FIRST:
    // If training > 2 days/week, on Day 3 (index 2)
    // the FIRST Horizontal Press must NOT be Barbell Bench.
    if (category == 'Horizontal Press' &&
        (day.countByCategory['Horizontal Press'] ?? 0) == 0 &&
        day.totalDays > 2 &&
        day.index == 2) {
      // Single-pass over the full pool: bench excluded (hard), spacing primary,
      // preferred-accessory secondary tiebreaker.  This ensures a non-adjacent
      // non-accessory always beats an adjacent accessory.
      ExLite? bestV;
      int bestVScore = -1;
      bool bestVIsAcc = false;
      for (final ex in pool) {
        // 🚫 Allow only one "squat" exercise by name per day
        if (_alreadyHasSquatNamedExercise(day) &&
            ex.name.toLowerCase().contains('squat')) {
          continue;
        }
        if (_isBarbellBenchPress(ex)) continue;  // hard: not bench on Day 3 first HP
        if (day.hasExercise(ex.id)) continue;
        if (day.isBanned(ex, category)) continue;
        if (_failsGate(ex)) continue;
        final s = spacingScore(ex);
        final isAcc = _isPreferredAccessoryHorizontalPress(ex);
        if (bestV == null ||
            s > bestVScore ||
            (s == bestVScore && isAcc && !bestVIsAcc)) {
          bestVScore = s;
          bestV = ex;
          bestVIsAcc = isAcc;
        }
      }
      if (bestV != null) return bestV;
      // If nothing valid found, fall through to normal logic.
    }

    // 🧠 Global week-level limit — per-exercise caps + no back-to-back days
// - Bench Press (barbell): no cap, no spacing rule
// - Calf Raise (any): max 3 uses/week
// - Everything else: max 2 uses/week
//   PLUS: avoid using the same exercise on two consecutive days,
//   except Back Squat, Barbell when weeklyFrequency > 2.
    for (final ex in pool.toList()) {
      // Bench: tier-dependent cap/spacing exemption
      if (_isBarbellBenchPress(ex)) {
        if (_benchTier == _BenchTier.tierA) {
          continue; // Tier A: full exemption — no cap, no spacing rule
        }
        if (_benchTier == _BenchTier.tierB) {
          // Tier B: enforce weekly cap only; bench stays exempt from spacing rule
          int priorBenchUses = 0;
          for (final pastDay in allDays.take(day.index)) {
            for (final circ in pastDay.circuits) {
              for (final placed in circ) {
                if (_isBarbellBenchPress(placed.ex)) priorBenchUses++;
              }
            }
          }
          if (priorBenchUses >= _benchWeeklyCap) {
            day._idsToday.add(ex.id);
          }
          continue; // still exempt from spacing check
        }
        // Tier C: fall through — bench gets generic cap (2/week) + spacing like any exercise
      }

      // Category-specific caps
      final bool isCalfRaise = _normCat(ex.category) == 'Calf Raise';
      final int weeklyCap = isCalfRaise ? 3 : 2;

      // Count prior uses up to "yesterday"
      int priorUses = 0;
      for (final pastDay in allDays.take(day.index)) {
        for (final circ in pastDay.circuits) {
          for (final placed in circ) {
            if (placed.ex.id == ex.id) priorUses++;
          }
        }
      }

      // 🚫 No two consecutive days (spacing rule) — circular: day 0 is adjacent to day N-1
      bool usedYesterday = false;
      {
        final prevDay = allDays[(day.index - 1 + allDays.length) % allDays.length];
        for (final circ in prevDay.circuits) {
          for (final placed in circ) {
            if (placed.ex.id == ex.id) {
              usedYesterday = true;
              break;
            }
          }
          if (usedYesterday) break;
        }
      }

      // Back Squat exemption from spacing rule when weeklyFrequency > 2
      final bool isBackSquat = _isBackSquatBarbell(ex);
      final bool spacingRuleApplies =
          !isBackSquat || day.totalDays <= 2; // if >2 days/week, skip spacing for back squat

      if (spacingRuleApplies && usedYesterday) {
        // Block this exercise for today to avoid back-to-back days
        day._idsToday.add(ex.id);
        continue;
      }

      // Weekly cap enforcement
      if (priorUses >= weeklyCap) {
        day._idsToday.add(ex.id); // pseudo-ban: prevents selection below
      }
    }




    // ✅ Bench-first preference SECOND:
    // If this is the FIRST Horizontal Press of the day, prefer Barbell Bench Press.
    // Tier C: bench gets no special preference — skip this block entirely.
    if (_benchTier != _BenchTier.tierC &&
        category == 'Horizontal Press' && (day.countByCategory['Horizontal Press'] ?? 0) == 0) {
      for (final ex in pool) {
        // 🚫 Allow only one "squat" exercise by name per day
        if (_alreadyHasSquatNamedExercise(day) &&
            ex.name.toLowerCase().contains('squat')) {
          continue;
        }

        if (!_isBarbellBenchPress(ex)) continue;
        if (day.hasExercise(ex.id)) continue;      // not already used today
        if (day.isBanned(ex, category)) continue;  // respect day-level bans
        if (_failsGate(ex)) continue;
        return ex;                                 // prefer this exact pick
      }
      // If no barbell bench is available/allowed, we fall through to normal logic.
    }

    // 🥇 Try to satisfy any remaining exercise-ID targets first (preferred picks)
    if (idTargetsRemaining != null && idTargetsRemaining.isNotEmpty) {
      ExLite? bestT;
      int bestTScore = -1;
      for (final ex in pool) {
        // 🚫 Allow only one "squat" exercise by name per day
        if (_alreadyHasSquatNamedExercise(day) &&
            ex.name.toLowerCase().contains('squat')) {
          continue;
        }

        final need = idTargetsRemaining[ex.id] ?? 0;
        if (need <= 0) continue;

        if (day.hasExercise(ex.id)) continue;
        if (day.isBanned(ex, category)) continue;

        // Weekly per-exercise caps
        final maxPerWeek = _perExerciseWeeklyMaxById[ex.id];
        if (maxPerWeek != null) {
          final used = _weeklyCountForExercise(ex.id, allDays);
          if (used >= maxPerWeek) continue;
        }

        // Must be able to join some circuit (or open a new one if under cap)
        bool canJoinAny = false;
        for (int ci = 0; ci < day.circuits.length; ci++) {
          if (_canJoin(day, ci, ex)) { canJoinAny = true; break; }
        }
        if (!canJoinAny && day.circuits.length >= _maxCircuitsPerDay) continue;

        if (_failsGate(ex)) continue;
        final s = spacingScore(ex);
        if (bestT == null || s > bestTScore) { bestTScore = s; bestT = ex; }
      }
      if (bestT != null) {
        _decrementTarget(idTargetsRemaining, bestT.id);
        return bestT;
      }
    }

    // Default chooser — collect all valid candidates, return the best-spaced one
    ExLite? best;
    int bestScore = -1;
    for (final ex in pool) {
      // 🚫 Allow only one "squat" exercise by name per day
      if (_alreadyHasSquatNamedExercise(day) &&
          ex.name.toLowerCase().contains('squat')) {
        continue;
      }

      if (day.hasExercise(ex.id)) continue;
      if (day.isBanned(ex, category)) continue;

      // 🔒 Per-exercise weekly cap (e.g. Bulgarian Split Squat)
      if (allDays != null) {
        final maxPerWeek = _perExerciseWeeklyMaxById[ex.id];
        if (maxPerWeek != null) {
          final used = _weeklyCountForExercise(ex.id, allDays);
          if (used >= maxPerWeek) continue;
        }
      }

      // 🧠 pre-check: must be able to join at least one current circuit, or start a new one if under cap
      bool canJoinAny = false;
      for (int ci = 0; ci < day.circuits.length; ci++) {
        if (_canJoin(day, ci, ex)) { canJoinAny = true; break; }
      }
      if (!canJoinAny && day.circuits.length >= _maxCircuitsPerDay) continue;

      if (_failsGate(ex)) continue;
      final s = spacingScore(ex);
      if (best == null || s > bestScore) { bestScore = s; best = ex; }
    }
    return best;
  }



  /// Pure (non-mutating) mirror of [_placeIntoCircuit] used by the circuit-0 gate.
  /// Returns the circuit index that _placeIntoCircuit *would* assign without
  /// touching day.circuits. Keeps the same iso-category set, score tie-break,
  /// and last-resort fallback as the real placer.
  static int _intendedCircuit(_DayPlan day, ExLite ex) {
    final cat = _normCat(ex.category);
    final bool isIso =
        cat == 'Arm Curl'      || cat == 'Arm Extension' ||
        cat == 'Lateral Raise' || cat == 'Calf Raise'    ||
        cat == 'Core'          || cat == 'Hip Abduction';

    // Mirror: isolation forced to a fresh circuit when exactly 2 exist.
    if (isIso && day.circuits.length == 2 && day.circuits.length < _maxCircuitsPerDay) {
      return 2; // index the new circuit would receive
    }

    // Find best joinable circuit — same score + tie-break as _placeIntoCircuit.
    int bestIdx = -1, bestScore = -0x3fffffff, bestLen = 1 << 30;
    for (int i = 0; i < day.circuits.length; i++) {
      if (_canJoin(day, i, ex)) {
        final s = _pairingScoreFor(day, i, ex);
        if (s > bestScore || (s == bestScore && day.circuits[i].length < bestLen)) {
          bestScore = s;
          bestLen   = day.circuits[i].length;
          bestIdx   = i;
        }
      }
    }
    if (bestIdx != -1) return bestIdx;

    // No joinable circuit → would open a new one (non-mutating).
    if (day.circuits.length < _maxCircuitsPerDay) {
      return day.circuits.length; // index of the circuit that would be added
    }

    // Last resort: smallest-load circuit — same fallback as _placeIntoCircuit.
    int fallback = 0, minLen = 1 << 30;
    for (int i = 0; i < day.circuits.length; i++) {
      if (day.circuits[i].length < minLen) {
        minLen   = day.circuits[i].length;
        fallback = i;
      }
    }
    return fallback;
  }

  /// Decide circuit index (0..N) for a chosen exercise to minimize overlap.
  static int _placeIntoCircuit(_DayPlan day, ExLite ex) {
    // Isolation categories that are allowed to live in circuit 3+
    final cat = _normCat(ex.category);
    final bool isIsoCategory =
        cat == 'Arm Curl' ||
            cat == 'Arm Extension' ||
            cat == 'Lateral Raise' ||
            cat == 'Calf Raise' ||
            cat == 'Core' ||
            cat == 'Hip Abduction';

    // 👉 If we already have 2 circuits, and this is an isolation exercise,
    // start a *new* iso-only circuit (index 2) instead of stuffing it into 0/1.
    if (isIsoCategory &&
        day.circuits.length == 2 &&
        day.circuits.length < _maxCircuitsPerDay) {
      day.circuits.add(<_Placed>[]);
      return day.circuits.length - 1; // this will be 2
    }

    // Otherwise: try to put it in the BEST existing circuit (by score),
    // then optionally start a new circuit if allowed.
    int bestIdx = -1;
    int bestScore = -0x3fffffff;
    int bestLen = 1 << 30;

    // Evaluate all circuits we CAN join, pick the one with the highest score.
    for (int i = 0; i < day.circuits.length; i++) {
      if (_canJoin(day, i, ex)) {
        final s = _pairingScoreFor(day, i, ex);
        // Prefer higher score; break ties by shorter circuit (keeps 2–3 ideal size)
        if (s > bestScore || (s == bestScore && day.circuits[i].length < bestLen)) {
          bestScore = s;
          bestLen = day.circuits[i].length;
          bestIdx = i;
        }
      }
    }

    if (bestIdx != -1) return bestIdx;

    // No existing circuit could take it → can we open a new one?
    if (day.circuits.length < _maxCircuitsPerDay) {
      // For non-iso lifts, this usually happens only for the first 1–2 circuits.
      day.circuits.add(<_Placed>[]);
      return day.circuits.length - 1;
    }

    // As a last resort, drop into the smallest load circuit.
    int fallback = 0, minLen = 1 << 30;
    for (int i = 0; i < day.circuits.length; i++) {
      if (day.circuits[i].length < minLen) {
        minLen = day.circuits[i].length;
        fallback = i;
      }
    }
    return fallback;
  }




  static bool _canJoin(_DayPlan day, int circuitIdx, ExLite ex) {
    final circuit = day.circuits[circuitIdx];

    // 🚫 Prevent duplicate categories within the same circuit
    final c = _normCat(ex.category);
    for (final p in circuit) {
      if (_normCat(p.category) == c) return false;
    }

    // 👉 For circuits 2 and above (index >= 2), restrict to isolation categories only.
    final bool isIsoCategory =
        c == 'Arm Curl' ||
            c == 'Arm Extension' ||
            c == 'Lateral Raise' ||
            c == 'Calf Raise' ||
            c == 'Core' ||
            c == 'Hip Abduction';

    if (circuitIdx >= 2 && !isIsoCategory) {
      return false;
    }

    // 1) Category-level rules
    for (final p in circuit) {
      final a = p.category;
      final b = _normCat(ex.category);

      // Horizontal Press vs Vertical Press/Arm Extension
      if (a == 'Horizontal Press' && (b == 'Vertical Press' || b == 'Arm Extension')) return false;
      if (b == 'Horizontal Press' && (a == 'Vertical Press' || a == 'Arm Extension')) return false;
      // 🚫 New rule: Horizontal Press should not pair with Arm Curl
      if ((a == 'Horizontal Press' && b == 'Arm Curl') ||
          (b == 'Horizontal Press' && a == 'Arm Curl')) {
        return false;
      }

      // 🆕 Vertical Press should not pair with Arm Extension (symmetry with Horizontal Press rule)
      if ((a == 'Vertical Press' && b == 'Arm Extension') ||
          (b == 'Vertical Press' && a == 'Arm Extension')) {
        return false;
      }


      // Lateral Raise should not be combined with Vertical Press or Horizontal Press
      if ((a == 'Lateral Raise' && (b == 'Vertical Press' || b == 'Horizontal Press')) ||
          (b == 'Lateral Raise' && (a == 'Vertical Press' || a == 'Horizontal Press'))) {
        return false;
      }

      // Horizontal Press should NOT pair with Vertical Pull in the same circuit,
      // EXCEPT when the Vertical Pull is the *exact* Wide-Arm Lat Pulldown ID.
      if ((a == 'Horizontal Press' && b == 'Vertical Pull') ||
          (b == 'Horizontal Press' && a == 'Vertical Pull')) {
        final vpEx = (a == 'Vertical Pull') ? p.ex : ex; // whichever is the Vertical Pull
        if (!_isWideArmLatPulldownAllowed(vpEx)) {
          return false; // block e.g., "Lat Pulldown, Supinated", etc.
        }
      }

      // Straight-arm lat variants (lat prayer / straight-arm pulldown / lat pullover machine)
      // should not pair with Horizontal Press, Vertical Press, or Arm Extension.
      final aIsSAL = _isStraightArmLatVariant(p.ex);
      final bIsSAL = _isStraightArmLatVariant(ex);
      if ((aIsSAL && (b == 'Horizontal Press' || b == 'Vertical Press' || b == 'Arm Extension')) ||
          (bIsSAL && (a == 'Horizontal Press' || a == 'Vertical Press' || a == 'Arm Extension'))) {
        return false;
      }

      // Horizontal Pull vs Vertical Pull/Arm Curl
      if (a == 'Horizontal Pull' && (b == 'Vertical Pull' || b == 'Arm Curl')) return false;
      if (b == 'Horizontal Pull' && (a == 'Vertical Pull' || a == 'Arm Curl')) return false;
      // Vertical Pull vs Arm Curl (no pair)
      if ((a == 'Vertical Pull' && b == 'Arm Curl') ||
          (b == 'Vertical Pull' && a == 'Arm Curl')) {
        return false;
      }


      // Squat Pattern vs Leg Extension (no pair)
      if ((a == 'Squat Pattern' && b == 'Leg Extension') || (b == 'Squat Pattern' && a == 'Leg Extension')) {
        return false;
      }

      // Hip Dominant family:
      final aHipDom = _isHipDominant(a);
      final bHipDom = _isHipDominant(b);
      if (aHipDom && bHipDom) return false; // hip-dominants don’t pair together
      if ((aHipDom && b == 'Squat Pattern') || (bHipDom && a == 'Squat Pattern')) return false; // hip dom ≠ squat
      // Leg Curl is NOT hip-dominant and CAN pair with Squat Pattern → allowed
    }

    // 2) Muscle-overlap rule: if the top 1–2 priorities overlap, reject.
    final exPrimaries = ex.primary.take(2).toSet();
    for (final p in circuit) {
      final primA = p.ex.primary.take(2).toSet();
      if (primA.intersection(exPrimaries).isNotEmpty) return false;
    }

    // 3) Circuit length cap (2.._maxCircuitsPerDay allowed); we prefer 2–3.
    if (circuit.length >= _maxCircuitsPerDay) return false;


    return true;
  }

  // ✅ Pairwise legality check for debug: mirrors the key rules in _canJoin
  static bool _pairIsIllegal(_Placed a, _Placed b) {
    final A = _normCat(a.category);
    final B = _normCat(b.category);

    // Horizontal Press vs Vertical Press / Arm Extension
    if ((A == 'Horizontal Press' && (B == 'Vertical Press' || B == 'Arm Extension')) ||
        (B == 'Horizontal Press' && (A == 'Vertical Press' || A == 'Arm Extension'))) {
      return true;
    }

    // 🚫 New rule: Horizontal Press should not pair with Arm Curl
    if ((A == 'Horizontal Press' && B == 'Arm Curl') ||
        (B == 'Horizontal Press' && A == 'Arm Curl')) {
      return true;
    }

    // 🆕 Vertical Press vs Arm Extension
    if ((A == 'Vertical Press' && B == 'Arm Extension') ||
        (B == 'Vertical Press' && A == 'Arm Extension')) {
      return true;
    }


    // Lateral Raise should not pair with Vertical Press or Horizontal Press
    if ((A == 'Lateral Raise' && (B == 'Vertical Press' || B == 'Horizontal Press')) ||
        (B == 'Lateral Raise' && (A == 'Vertical Press' || A == 'Horizontal Press'))) {
      return true;
    }

    // Horizontal Press should NOT pair with Vertical Pull (except the exact wide-arm ID)
    if ((A == 'Horizontal Press' && B == 'Vertical Pull') ||
        (B == 'Horizontal Press' && A == 'Vertical Pull')) {
      final vpEx = (A == 'Vertical Pull') ? a.ex : b.ex;
      if (!_isWideArmLatPulldownAllowed(vpEx)) return true;
    }

    // Straight-arm lat variants must not pair with Horizontal/Vertical Press or Arm Extension
    final aIsSAL = _isStraightArmLatVariant(a.ex);
    final bIsSAL = _isStraightArmLatVariant(b.ex);
    if ((aIsSAL && (B == 'Horizontal Press' || B == 'Vertical Press' || B == 'Arm Extension')) ||
        (bIsSAL && (A == 'Horizontal Press' || A == 'Vertical Press' || A == 'Arm Extension'))) {
      return true;
    }

    // Horizontal Pull vs Vertical Pull / Arm Curl
    if ((A == 'Horizontal Pull' && (B == 'Vertical Pull' || B == 'Arm Curl')) ||
        (B == 'Horizontal Pull' && (A == 'Vertical Pull' || A == 'Arm Curl'))) {
      return true;
    }

    // Vertical Pull vs Arm Curl
    if ((A == 'Vertical Pull' && B == 'Arm Curl') ||
        (B == 'Vertical Pull' && A == 'Arm Curl')) {
      return true;
    }

    // Squat Pattern vs Leg Extension
    if ((A == 'Squat Pattern' && B == 'Leg Extension') ||
        (B == 'Squat Pattern' && A == 'Leg Extension')) {
      return true;
    }

    // Hip-dominant family: hip-dom with hip-dom, or hip-dom with Squat Pattern
    final aHip = _isHipDominant(A);
    final bHip = _isHipDominant(B);
    if (aHip && bHip) return true;
    if ((aHip && B == 'Squat Pattern') || (bHip && A == 'Squat Pattern')) return true;

    // Muscle-overlap (top 1–2 primaries) — but avoid self-compare by construction
    final primA = a.ex.primary.take(2).toSet();
    final primB = b.ex.primary.take(2).toSet();
    if (primA.isNotEmpty && primB.isNotEmpty && primA.intersection(primB).isNotEmpty) {
      return true;
    }

    return false;
  }


  static String _normCat(String c) => c.trim();

  static bool _isHipDominant(String c) =>
      c == 'Hip Hinge' || c == 'Deadlift' || c == 'RDL' || c == 'Hip Thrust';

  // Place under: static bool _isHipDominant(String c) => ...
  static bool _isBarbellBenchPress(ExLite ex) {
    if (_normCat(ex.category) != 'Horizontal Press') return false;
    final s = ex.name.toLowerCase();
    // robust to naming like "Bench Press, Barbell" / "Barbell Bench Press"
    return (s.contains('bench') && s.contains('press') && s.contains('barbell'));
  }

  /// Returns true if [cat] is an upper-body movement category.
  /// Used by the male circuit-0 gate to decide whether to apply restrictions.
  static bool _isUpperBodyCategory(String cat) {
    switch (cat) {
      case 'Horizontal Press': case 'Horizontal Pull':
      case 'Vertical Press':   case 'Vertical Pull':
      case 'Arm Curl':         case 'Arm Extension':
      case 'Lateral Raise':    return true;
      default:                 return false;
    }
  }

  /// Returns true if [ex].primary or [ex].secondary contains [muscle]
  /// (case-insensitive substring match). Used by the circuit-0 arm-muscle check.
  static bool _hasMuscleName(ExLite ex, String muscle) {
    final m = muscle.toLowerCase();
    for (final s in [...ex.primary, ...ex.secondary]) {
      if (s.toLowerCase().contains(m)) return true;
    }
    return false;
  }

  // Place under: static bool _isBarbellBenchPress(ExLite ex) { ... }
  static bool _isBackSquatBarbell(ExLite ex) {
    if (_normCat(ex.category) != 'Squat Pattern') return false;
    final s = ex.name.toLowerCase();
    // robust to naming like "Back Squat, Barbell" / "Barbell Back Squat"
    return s.contains('back') && s.contains('squat') && s.contains('barbell');
  }


  // Use exact exercise id for "Wide Arm Lat Pulldown" OK-to-pair case.
  static const String _wideArmLatPulldownId = 'Url65Q2RxZa00dkDpUdl';

  static bool _isWideArmLatPulldownAllowed(ExLite ex) {
    return ex.id == _wideArmLatPulldownId;
  }


  // Scores how well `ex` fits into an existing circuit, for preference ordering.
// Only adds bias when `ex` is a Horizontal Press.
  static int _pairingScoreFor(_DayPlan day, int circuitIdx, ExLite ex) {
    if (_normCat(ex.category) != 'Horizontal Press') return 0;

    int score = 0;
    final circuit = day.circuits[circuitIdx];

    for (final p in circuit) {
      final cat = _normCat(p.category);

      // Ideal: Horizontal Press + Horizontal Pull
      if (cat == 'Horizontal Pull') score += 2;

      // "Okay": Wide-arm Lat Pulldown (exact ID) allowed with presses
      if (cat == 'Vertical Pull' && _isWideArmLatPulldownAllowed(p.ex)) score += 1;

// Least ideal: other Vertical Pulls with Horizontal Press
      if (cat == 'Vertical Pull' && !_isWideArmLatPulldownAllowed(p.ex)) score -= 2;

    }

    return score;
  }



  // Prefer these non-bench Horizontal Press options on the designated variety day
  static bool _isPreferredAccessoryHorizontalPress(ExLite ex) {
    if (_normCat(ex.category) != 'Horizontal Press') return false;
    final s = ex.name.toLowerCase();

    // Flat Bench Dumbbell Press (robust to naming)
    final isFlatDbPress = (s.contains('dumbbell') || s.contains('db')) &&
        s.contains('press') &&
        (s.contains('flat') || s.contains('bench'));

    // Incline Dumbbell Press
    final isInclineDbPress = (s.contains('dumbbell') || s.contains('db')) &&
        s.contains('press') &&
        s.contains('incline');

    // Bayesian Fly (various spellings)
    final isBayesianFly = s.contains('bayesian') && (s.contains('fly') || s.contains('flye'));

    // Deficit Push-Up
    final isDeficitPushUp = (s.contains('deficit') &&
        (s.contains('push up') || s.contains('push-up') || s.contains('pushup')));

    return isFlatDbPress || isInclineDbPress || isBayesianFly || isDeficitPushUp;
  }



  // Detects straight-arm lat pulldown / lat prayer / machine pullover variants by name.
  // Detects straight-arm lat pulldown / lat prayer / machine pullover variants by name.
  static bool _isStraightArmLatVariant(ExLite ex) {
    final s = ex.name.toLowerCase();

    // Core markers
    final hasStraightOrStiff =
        s.contains('straight arm') || s.contains('straight-arm') ||
            s.contains('stiff arm')    || s.contains('stiff-arm');

    final hasLat = s.contains('lat');

    // Pulldown / pull down / pull-over / pullover
    final hasPulldown =
        s.contains('pulldown') || s.contains('pull down') || s.contains('pull-down');
    final hasPullover =
        s.contains('pullover') || s.contains('pull over') || s.contains('pull-over');

    // “Lat prayer” variants
    final hasLatPrayer = s.contains('lat prayer') || s.contains('prayer');

    // Heuristics:
    // 1) Straight/Stiff-arm + (lat OR pulldown/pullover)
    if (hasStraightOrStiff && (hasLat || hasPulldown || hasPullover)) return true;

    // 2) Any explicit “lat prayer”
    if (hasLatPrayer && hasLat) return true;

    // 3) Machine pullover explicitly for lats
    if (hasPullover && hasLat) return true;

    return false;
  }

  // ───────────────── Emphasis → Demand routing config ─────────────────

// Read child-muscle slider level. Checks onboarding.emphasis[key] first, then top-level key.
  static int _readChildLevel(Map<String, dynamic> onb, String key) {
    // Normalise lookup
    final keyNorm = key.toString().toLowerCase().trim();

    // 1) Try bodyFocusChildren first
    final childrenRaw = onb['bodyFocusChildren'];
    if (childrenRaw is Map<String, dynamic>) {
      for (final parentEntry in childrenRaw.entries) {
        final kids = parentEntry.value;
        if (kids is Map<String, dynamic>) {
          for (final childEntry in kids.entries) {
            final childName = childEntry.key.toString().toLowerCase().trim();
            if (childName == keyNorm) {
              final v = childEntry.value;
              if (v is int) return v.clamp(0, 3);
              if (v is String) {
                final p = int.tryParse(v);
                if (p != null) return p.clamp(0, 3);
              }
            }
          }
        }
      }
    }

    // 2) Fallback to bodyFocusLevel (for big muscle groups)
    final parentRaw = onb['bodyFocusLevel'];
    if (parentRaw is Map<String, dynamic>) {
      const parentKeyMap = {
        'chest': 'Chest',
        'core': 'Abs',
        'abs': 'Abs',
        'hamstrings': 'Hamstrings',
        'quads': 'Quads',
        'calves': 'Calves',
      };

      final parentKey = parentKeyMap[keyNorm];
      if (parentKey != null) {
        final v = parentRaw[parentKey];
        if (v is int) return v.clamp(0, 3);
        if (v is String) {
          final p = int.tryParse(v);
          if (p != null) return p.clamp(0, 3);
        }
      }
    }

    // Default
    return 0;
  }


// Child muscle → emphasis level (0–3).
  static Map<String, int> _buildChildEmphasis(Map<String, dynamic> onb) {
    return <String, int>{
      // Back
      'Lats'                 : _readChildLevel(onb, 'Lats'),
      'Mid traps & rear delts': _readChildLevel(onb, 'Mid traps & rear delts'),
      'Lower back 🎄'        : _readChildLevel(onb, 'Lower back 🎄'),

      // Delts / traps
      'Anterior delts'       : _readChildLevel(onb, 'Anterior delts'),
      'Lateral delts'        : _readChildLevel(onb, 'Lateral delts'),
      'Upper traps'          : _readChildLevel(onb, 'Upper traps'),

      // Arms
      'Biceps'               : _readChildLevel(onb, 'Biceps'),
      'Triceps'              : _readChildLevel(onb, 'Triceps'),
      'Forearms'             : _readChildLevel(onb, 'Forearms'),

      // Glutes
      'Glute Maximus'        : _readChildLevel(onb, 'Glute Maximus'),
      'Glute Medius'         : _readChildLevel(onb, 'Glute Medius'),

      // Big groups (fall back to bodyFocusLevel)
      'Chest'                : _readChildLevel(onb, 'Chest'),
      'Abs'                  : _readChildLevel(onb, 'Abs'),
      'Hamstrings'           : _readChildLevel(onb, 'Hamstrings'),
      'Quads'                : _readChildLevel(onb, 'Quads'),
      'Calves'               : _readChildLevel(onb, 'Calves'),
    };
  }


// Special exercise IDs (fill with your real IDs later if you want extra bias)
  static const String _idSupinatedLatPulldown = '1XOIXxeLFhgmgjZS9Cyq';
  static const String _idChinUp = 'XM9026peNIu0R8qh7UqY';
  static const String _idBarbellOverheadPress = 'lVDG90yN6Z8aPjRNV2wc';

// Optional: forearm isolation IDs (leave empty if none yet)
  static const List<String> _forearmIsolationIds = <String>[
    '0h3rJfPtx1beUw0TIUzU', // Hammer Curl
    // 'REPLACE_WITH_REVERSE_WRIST_CURL_ID',
    // 'REPLACE_WITH_FARMERS_CARRY_ID',
  ];

// Split weights
  static const double _w50 = 0.5;
  static const double _w60 = 0.6;
  static const double _w40 = 0.4;

// Route child-muscle emphasis into category bumps & per-ID targets
  static ({Map<String,int> categoryBumps, Map<String,int> idTargets})
  _routeEmphasisToDemand({
    required Map<String, int> childLevels,
    required Map<String, List<ExLite>> byCat,
    required int trainingEffort, // 1..4
  }) {
    final cat = <String, int>{};
    final ids = <String, int>{};

    // Effort scaling: 1 = very conservative, 4 = full emphasis
    double _effortScale(int effort) {
      switch (effort.clamp(1, 4)) {
        case 1:
          return 0.3;  // low effort → small slider impact
        case 2:
          return 0.6;  // moderate
        case 3:
          return 0.85; // high
        case 4:
        default:
          return 1.0;  // max effort → full slider effect
      }
    }

    final double effortScale = _effortScale(trainingEffort);

    // Scale integer bumps by effort factor
    int bumpInt(int base) {
      if (base <= 0) return 0;
      return (base * effortScale).round().clamp(0, 99);
    }


    void addCat(String category, int inc) {
      if (inc <= 0) return;
      if ((byCat[category]?.isNotEmpty ?? false)) {
        cat[category] = (cat[category] ?? 0) + inc;
      }
    }

    void addId(String exId, int inc) {
      if (inc <= 0) return;
      bool present = false;
      for (final list in byCat.values) {
        if (list.any((e) => e.id == exId)) { present = true; break; }
      }
      if (present) ids[exId] = (ids[exId] ?? 0) + inc;
    }

    // Chest → Horizontal Press
    final chestL = childLevels['Chest'] ?? 0;
    if (chestL > 0) {
      addCat('Horizontal Press', bumpInt(chestL));
    }

    // Lats → Vertical Pull (+ optional horiz-pull IDs later)
    final latsL = childLevels['Lats'] ?? 0;
    if (latsL > 0) {
      addCat('Vertical Pull', bumpInt(latsL));
    }

    // Mid traps & rear delts → Horizontal Pull
    final upperBackL = childLevels['Mid traps & rear delts'] ?? 0;
    if (upperBackL > 0) {
      addCat('Horizontal Pull', bumpInt(upperBackL));
    }

    // Lower back → Hip Hinge
    final lowBackL = childLevels['Lower back 🎄'] ?? 0;
    if (lowBackL > 0) {
      addCat('Hip Hinge', bumpInt(lowBackL));
    }

    // Anterior delts → VP + HP + LR
    final antDeltsL = childLevels['Anterior delts'] ?? 0;
    if (antDeltsL > 0) {
      addCat('Vertical Press',   bumpInt((antDeltsL * _w60).round()));
      addCat('Horizontal Press', bumpInt((antDeltsL * _w40).round()));
      addCat('Lateral Raise',    bumpInt((antDeltsL * _w40).round()));
    }

    // Lateral delts → LR + VP
    final latDeltsL = childLevels['Lateral delts'] ?? 0;
    if (latDeltsL > 0) {
      addCat('Lateral Raise',  bumpInt((latDeltsL * _w60).round()));
      addCat('Vertical Press', bumpInt((latDeltsL * _w40).round()));
    }

    // Upper traps → Vertical Press
    final upperTrapsL = childLevels['Upper traps'] ?? 0;
    if (upperTrapsL > 0) {
      addCat('Vertical Press', bumpInt(upperTrapsL));
    }

    // Biceps → Arm Curl (+ preferred IDs)
    final bicepsL = childLevels['Biceps'] ?? 0;
    if (bicepsL > 0) {
      final inc = bumpInt(bicepsL);
      addCat('Arm Curl', inc);
      addId(_idSupinatedLatPulldown, inc);
      addId(_idChinUp, inc);
    }

    // Triceps → Arm Extension (+ OHP ID)
    final tricepsL = childLevels['Triceps'] ?? 0;
    if (tricepsL > 0) {
      final inc = bumpInt(tricepsL);
      addCat('Arm Extension', inc);
      addId(_idBarbellOverheadPress, inc);
    }

    // Forearms → Pulls + Curl (+ optional isolation ids)
    final forearmsL = childLevels['Forearms'] ?? 0;
    if (forearmsL > 0) {
      addCat('Horizontal Pull', bumpInt((forearmsL * _w50).round()));
      addCat('Vertical Pull',   bumpInt((forearmsL * _w50).round()));
      addCat('Arm Curl',        bumpInt((forearmsL * _w40).round()));
      if (forearmsL >= 3) {
        for (final id in _forearmIsolationIds) {
          addId(id, bumpInt(1)); // small, effort-scaled nudge
        }
      }
    }

    // Glute Max → Hip Hinge + Squat Pattern
    final gmaxL = childLevels['Glute Maximus'] ?? 0;
    if (gmaxL > 0) {
      addCat('Hip Hinge',     bumpInt((gmaxL * _w50).round()));
      addCat('Squat Pattern', bumpInt((gmaxL * _w50).round()));
    }

    // Glute Med → Hip Abduction
    final gmedL = childLevels['Glute Medius'] ?? 0;
    if (gmedL > 0) {
      addCat('Hip Abduction', bumpInt(gmedL));
    }

    // Abs → Core
    final absL = childLevels['Abs'] ?? 0;
    if (absL > 0) {
      addCat('Core', bumpInt(absL));
    }

    // Hamstrings → Leg Curl + Hip Hinge
    final hamsL = childLevels['Hamstrings'] ?? 0;
    if (hamsL > 0) {
      addCat('Leg Curl',  bumpInt((hamsL * _w60).round()));
      addCat('Hip Hinge', bumpInt((hamsL * _w40).round()));
    }

    // Quads → Squat Pattern + Leg Extension
    final quadsL = childLevels['Quads'] ?? 0;
    if (quadsL > 0) {
      addCat('Squat Pattern', bumpInt((quadsL * _w60).round()));
      addCat('Leg Extension', bumpInt((quadsL * _w40).round()));
    }

    // Calves → Calf Raise
    final calvesL = childLevels['Calves'] ?? 0;
    if (calvesL > 0) {
      addCat('Calf Raise', bumpInt(calvesL));
    }

    return (categoryBumps: cat, idTargets: ids);
  }


  // Map your exercise categories to the muscle keys used by the volume engine.
  static String? _muscleKeyForCategory(String category) {
    final c = _normCat(category);
    switch (c) {
      case 'Horizontal Press':
        return 'Chest';
      case 'Vertical Press':
      case 'Lateral Raise':
        return 'Shoulders';
      case 'Horizontal Pull':
      case 'Vertical Pull':
        return 'Back';
      case 'Squat Pattern':
      case 'Leg Extension':
        return 'Quads';
      case 'Leg Curl':
        return 'Hamstrings';
      case 'Hip Hinge':
      // Could also be 'Glutes'; both get similar volume in our model.
        return 'Hamstrings';
      case 'Calf Raise':
        return 'Calves';
      case 'Core':
        return 'Abs';
      case 'Arm Curl':
        return 'Biceps';
      case 'Arm Extension':
        return 'Triceps';
      case 'Hip Abduction':
        return 'Glutes';
      default:
        return null;
    }
  }

  // Convert per-muscle volume targets into per-category "extra weekly slots".
// We look at MEV (min) vs targetExercises, and ask:
// "How many extra appearances above the min should this category get?"
  static Map<String, int> _volumeCategoryBumpsFromTargets({
    required Map<String, MuscleVolumeTarget> volumeTargets,
    required Map<String, Map<String,int>> freqCaps,
    required Map<String, int> childLevels,
    required int trainingEffort, // you can keep this arg for now, even if unused
  }) {
    final bumps = <String, int>{};

    // Effort is already reflected in volumeTargets.targetExercises,
    // so we do *no extra scaling* here to avoid double counting.
    const double effortScale = 1.0;


    void bumpFor(String cat) {
      final muscleKey = _muscleKeyForCategory(cat);
      if (muscleKey == null) return;

      // Emphasis level 0..3 for this muscle (Chest, Quads, etc.)
      final int muscleLevel = (childLevels[muscleKey] ?? 0).clamp(0, 3);

      // 🛑 If this muscle has zero emphasis, do NOT add volume bumps at all.
      if (muscleLevel == 0) {
        return; // category stays at capsFor() + seeding only
      }

      final vt = volumeTargets[muscleKey];
      if (vt == null) return;

      final caps = freqCaps[cat];
      if (caps == null) return;

      final int minCap = caps['min'] ?? 0;
      final int maxCap = caps['max'] ?? 0;

      if (maxCap <= minCap) return; // fixed-cap categories stay as-is.

      // Ideal target (from volume engine), still clamped by caps.
      final int desiredCount = vt.targetExercises.clamp(minCap, maxCap);
      final int rawExtraOverMin = desiredCount - minCap;
      if (rawExtraOverMin <= 0) return;

      // 🔢 Emphasis 1..3 → 0.33 .. 1.0
      final double emphasisScale = muscleLevel / 3.0;

      // Final bump scale = effort × emphasis.
      final double bumpScale = effortScale * emphasisScale;

      // Scale the "extra over min" by bump scale.
      int scaledExtra = (rawExtraOverMin * bumpScale).round();

      // If there is any emphasis/effort at all but rounding gave 0, allow a minimum bump of 1
      // (optional – you can remove this if you want very fine-grained behaviour).
      if (scaledExtra <= 0 && bumpScale > 0) {
        scaledExtra = 1;
      }

      if (scaledExtra <= 0) return;

      bumps[cat] = (bumps[cat] ?? 0) + scaledExtra;
    }

    for (final cat in freqCaps.keys) {
      bumpFor(cat);
    }

    return bumps;
  }



// Lift weeklyPlan mins using bumps (caps & availability respected)
  static void _applyEmphasisCategoryBumps({
    required Map<String, int> weeklyPlan,
    required Map<String, Map<String,int>> freqCaps,
    required Map<String, List<ExLite>> byCat,
    required Map<String, int> categoryBumps,
  }) {
    categoryBumps.forEach((cat, inc) {
      if (inc <= 0) return;
      if ((byCat[cat]?.isEmpty ?? true)) return;
      final caps = freqCaps[cat];
      if (caps == null) return;
      final curr = weeklyPlan[cat] ?? (caps['min'] ?? 0);
      final desired = (curr + inc).clamp(caps['min']!, caps['max']!);
      weeklyPlan[cat] = desired;
    });
  }

  /// Compute weekly volume targets per muscle group from onboarding.
  ///
  /// - Uses unified base: MEV 12, MAV ~18-20, MRV 26 (per muscle, per week).
  /// - Adjusts MEV/MRV down a bit for older ages.
  /// - Blends trainingEffort (1..4) and emphasis (0..3) into a 0..1 weight
  ///   to choose a target between MEV and MRV.
  /// - Returns sets + approximate exercise frequencies per week.
  static Map<String, MuscleVolumeTarget> computeVolumeTargetsFromOnboarding({
    required int? age,
    required Map<String, dynamic> onboarding,
  }) {
    // ── 1) Training effort (1..4) ─────────────────────────────────────────────
    final int effRaw = (onboarding['trainingEffort'] is int)
        ? onboarding['trainingEffort'] as int
        : 3;
    final int trainingEffort = effRaw.clamp(1, 4);

    // ── 2) Onboarding body-focus maps ─────────────────────────────────────────
    final Map<String, dynamic> bodyFocusLevelRaw =
        (onboarding['bodyFocusLevel'] as Map<String, dynamic>?) ?? const {};
    final Map<String, dynamic> bodyFocusChildrenRaw =
        (onboarding['bodyFocusChildren'] as Map<String, dynamic>?) ?? const {};

    // Age handling: null → treat as 27 (young bucket).
    final int userAge = age ?? 27;

    // ── 3) Age → average sets per exercise (for converting sets → exercises) ──
    double setsPerExercise;
    if (userAge <= 27) {
      setsPerExercise = 4.0;   // younger: assume ~4 sets/ex
    } else if (userAge <= 37) {
      setsPerExercise = 3.5;   // transitional
    } else {
      setsPerExercise = 3.0;   // older buckets
    }

    // ── 4) Region / child emphasis readers (0..3) ─────────────────────────────
    int _readRegionLevel(String region) {
      final raw = bodyFocusLevelRaw[region];
      if (raw is int) return raw.clamp(0, 3);
      if (raw is num) return raw.toInt().clamp(0, 3);
      if (raw is String) {
        final p = int.tryParse(raw);
        if (p != null) return p.clamp(0, 3);
      }
      return 0;
    }

    int _readChildLevel(String parent, String childKey) {
      final parentMap = bodyFocusChildrenRaw[parent];
      if (parentMap is Map) {
        final raw = parentMap[childKey];
        if (raw is int) return raw.clamp(0, 3);
        if (raw is num) return raw.toInt().clamp(0, 3);
        if (raw is String) {
          final p = int.tryParse(raw);
          if (p != null) return p.clamp(0, 3);
        }
      }
      // fallback to parent region level
      return _readRegionLevel(parent);
    }

    // ── 5) Per-muscle emphasis (0..3) ─────────────────────────────────────────
    // These keys are muscle names, on purpose.
    final Map<String, int> emphasisByMuscle = <String, int>{
      // Big groups
      'Chest'      : _readRegionLevel('Chest'),
      'Back'       : _readRegionLevel('Back'),
      'Quads'      : _readRegionLevel('Quads'),
      'Hamstrings' : _readRegionLevel('Hamstrings'),
      'Glutes'     : _readRegionLevel('Glutes'),
      'Shoulders'  : _readRegionLevel('Shoulders'),
      'Calves'     : _readRegionLevel('Calves'),
      'Abs'        : _readRegionLevel('Abs'),

      // Arms – try child first
      'Biceps'     : _readChildLevel('Arms', 'Biceps'),
      'Triceps'    : _readChildLevel('Arms', 'Triceps'),
      'Forearms'   : _readChildLevel('Arms', 'Forearms'),
    };

    // ── 6) Effort → base set bands per muscle (pre age/emphasis) ──────────────
    // These are sets per muscle per week, before age & emphasis adjustments.
    int _effortLow(int effort) {
      switch (effort.clamp(1, 4)) {
        case 1: return 10; // 10–12
        case 2: return 13; // 13–15
        case 3: return 16; // 16–19
        case 4:
        default:
          return 20;       // 20–24
      }
    }

    int _effortMid(int effort) {
      switch (effort.clamp(1, 4)) {
        case 1: return 11; // midpoint of 10–12
        case 2: return 14; // midpoint of 13–15
        case 3: return 18; // midpoint of 16–19
        case 4:
        default:
          return 22;       // midpoint of 20–24
      }
    }

    int _effortHigh(int effort) {
      switch (effort.clamp(1, 4)) {
        case 1: return 12; // 10–12
        case 2: return 15; // 13–15
        case 3: return 19; // 16–19
        case 4:
        default:
          return 24;       // 20–24
      }
    }

    // ── 7) Age / emphasis scaling ─────────────────────────────────────────────
    double _ageScale(int age) {
      if (age > 40) return 0.8; // –20%
      if (age > 30) return 0.9; // –10%
      return 1.0;
    }

    // Emphasis slider = add ~15–30% on top of effort level.
    // 0 = neutral (zero-emphasis is handled separately in routing/bumps),
    // 1 = baseline, 2 = +15%, 3 = +30%.
    double _emphScale(int level) {
      switch (level.clamp(0, 3)) {
        case 0:
        case 1:
          return 1.0;
        case 2:
          return 1.15;
        case 3:
          return 1.30;
        default:
          return 1.0;
      }
    }

    final int baseLow   = _effortLow(trainingEffort);
    final int baseMid   = _effortMid(trainingEffort);
    final int baseHigh  = _effortHigh(trainingEffort);
    final double ageFactor = _ageScale(userAge);

    // ── 8) Core builder per muscle ────────────────────────────────────────────
    MuscleVolumeTarget _buildForMuscle(String muscleKey) {
      final int emp = emphasisByMuscle[muscleKey] ?? 0;
      final double eScale = _emphScale(emp);

      // Raw (float) bands after age + emphasis scaling
      final double rawLow  = baseLow  * ageFactor * eScale;
      final double rawMid  = baseMid  * ageFactor * eScale;
      final double rawHigh = baseHigh * ageFactor * eScale;

      // Clamp into a reasonable global safety band (e.g. 8–30 sets/week)
      int mevSets     = rawLow.clamp(8.0, 30.0).floor();
      int targetSets  = rawMid.clamp(8.0, 30.0).round();
      int mrvSets     = rawHigh.clamp(8.0, 30.0).ceil();

      // Make sure ordering is sane
      if (targetSets < mevSets) targetSets = mevSets;
      if (mrvSets < targetSets) mrvSets = targetSets;

      // Convert sets → exercise counts (soft guidance)
      int minExercises    = (mevSets / setsPerExercise).ceil();
      int targetExercises = (targetSets / setsPerExercise).round();
      int maxExercises    = (mrvSets / setsPerExercise).floor();

      if (targetExercises == 0 && targetSets > 0) {
        targetExercises = 1;
      }
      if (maxExercises < targetExercises) {
        maxExercises = targetExercises;
      }

      return MuscleVolumeTarget(
        mevSets: mevSets,
        mrvSets: mrvSets,
        targetSets: targetSets,
        minExercises: minExercises,
        targetExercises: targetExercises,
        maxExercises: maxExercises,
      );
    }

    // ── 9) Final map: per-muscle targets ──────────────────────────────────────
    final Map<String, MuscleVolumeTarget> out = <String, MuscleVolumeTarget>{};

    for (final muscle in emphasisByMuscle.keys) {
      out[muscle] = _buildForMuscle(muscle);
    }

    return out;
  }


  static void debugPrintVolumeTargets(
      Map<String, MuscleVolumeTarget> vt,
      ) {
    debugPrint('──────────── 📊 VOLUME ENGINE OUTPUT ────────────');
    vt.forEach((muscle, target) {
      debugPrint('  • $muscle → $target');
    });
    debugPrint('────────────────────────────────────────────────');
  }


// ───────────────── Per-day "Squat" name cap ─────────────────
// We allow only one exercise *with "squat" in its name* per day,
// even if multiple belong to the "Squat Pattern" category.
  static bool _alreadyHasSquatNamedExercise(_DayPlan day) {
    for (final circuits in day.circuits) {
      for (final p in circuits) {
        final n = p.ex.name.toLowerCase();
        if (n.contains('squat')) return true;
      }
    }
    return false;
  }


  // 🚫 Weekly per-exercise caps
  static const Map<String, int> _perExerciseWeeklyMaxById = {
    'ISXQqOEXLjMrPEs0xjgJ': 1, // Bulgarian Split Squat
    'xbePAZEtQIFEjvu2YaPV': 1, // Bulgarian Split Squat, Deficit
  };

  static int _weeklyCountForExercise(String exId, List<_DayPlan> allDays) {
    int count = 0;
    for (final d in allDays) {
      for (final circ in d.circuits) {
        for (final p in circ) {
          if (p.ex.id == exId) count++;
        }
      }
    }
    return count;
  }

  static void _decrementTarget(Map<String,int>? idTargetsRemaining, String id) {
    if (idTargetsRemaining == null) return;
    final left = idTargetsRemaining[id];
    if (left == null) return;
    if (left <= 1) {
      idTargetsRemaining.remove(id);
    } else {
      idTargetsRemaining[id] = left - 1;
    }
  }


  /// Produce alternate versions for Block-2/Block-3 by rebuilding the block
  /// from scratch using the SAME rules as Block 1 (chooseExercise / canJoin /
  /// placeIntoCircuit / caps / spacing / overlap / variety / bench-first).
  ///
  /// We use Block 1's final per-day category counts as the blueprint, but
  /// pick fresh exercises from the given byCat pools.
  static List<_DayPlan> _alternateBlock(
      List<_DayPlan> b1,
      Map<String, List<ExLite>> byCat,
      ) {
    // 1. Make a shuffled copy of byCat so that selection order differs from Block 1.
    final Map<String, List<ExLite>> shuffledByCat = <String, List<ExLite>>{};
    byCat.forEach((cat, list) {
      final copy = List<ExLite>.from(list);
      copy.shuffle();
      shuffledByCat[cat] = copy;
    });

    // 2. Rebuild a brand-new block using the same legality rules as Block 1,
    //    but matching Block 1's category pattern per day.
    final out = <_DayPlan>[];

    for (final originalDay in b1) {
      final d = _DayPlan(
        index: originalDay.index,
        totalDays: originalDay.totalDays,
      );

      // For spacing & weekly caps inside _chooseExercise:
      // we pass the list of already-built days in this new block.
      final List<_DayPlan> allDaysSoFar = out;

      // Build a flat "demand list" of categories we need to place on this day,
      // based on Block 1's final category counts (e.g. 2x HP, 1x VP, 1x Squat).
      final List<String> categorySlots = <String>[];
      originalDay.countByCategory.forEach((cat, count) {
        for (int i = 0; i < count; i++) {
          categorySlots.add(cat);
        }
      });

      // Shuffle the order we satisfy categories to increase variety.
      categorySlots.shuffle();

      // For each category slot, try to pick a legal exercise & place it.
      for (final cat in categorySlots) {
        final pool = shuffledByCat[cat];
        if (pool == null || pool.isEmpty) continue;

        final ex = _chooseExercise(
          pool: pool,
          day: d,
          category: cat,
          allDays: allDaysSoFar,
          // idTargetsRemaining is optional; we skip it for alternates for now.
        );

        if (ex == null) {
          // No legal choice for this slot → skip; better to leave the day slightly lighter
          // than violate pairing/spacing rules.
          continue;
        }

        final ci = _placeIntoCircuit(d, ex);
        d.addExercise(ex, cat, ci);
      }

      out.add(d);
    }

    return out;
  }


}

// ---------- Small day/circuit container types ----------

class _Placed {
  final ExLite ex;
  final String category;
  _Placed({required this.ex, required this.category});
}

class _DayPlan {
  final int index;
  final int totalDays; // ✅ added field

  final List<List<_Placed>> circuits = <List<_Placed>>[];
  final Map<String, int> countByCategory = <String, int>{};
  // Track which exercise IDs already used today to prevent duplicates.
  final Set<String> _idsToday = <String>{};

  bool hasExercise(String id) => _idsToday.contains(id);

  _DayPlan({required this.index, required this.totalDays}); // ✅ updated constructor


  void addExercise(ExLite ex, String cat, int circuitIdx) {
    circuits[circuitIdx].add(_Placed(ex: ex, category: cat));
    countByCategory[cat] = (countByCategory[cat] ?? 0) + 1;
    _idsToday.add(ex.id); // 🚫 prevent duplicates-in-day
  }


  bool isBanned(ExLite ex, String cat) {
    // per-day category hard cap is checked upstream
    // deadlift max 2/wk would be enforced at a higher level if you tag them; omitted here
    // We can extend with equipment/setup-burden, experience gates later.
    return false;
  }

  List<Map<String, dynamic>> emit() {
    final out = <Map<String, dynamic>>[];
    for (int c = 0; c < circuits.length; c++) {
      for (final p in circuits[c]) {
        out.add({
          'exerciseId': p.ex.id,
          'name': p.ex.name,
          'circuitIndex': c,
        });
      }
    }
    return out;
  }

  _DayPlan clone() {
    final d = _DayPlan(index: index, totalDays: totalDays); // ⬅️ keep totalDays
    for (final circ in circuits) {
      d.circuits.add(circ.map((p) => _Placed(ex: p.ex, category: p.category)).toList());
    }
    d.countByCategory.addAll(countByCategory);
    return d;
  }


}


