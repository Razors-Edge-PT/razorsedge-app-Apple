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

class TemplateGenerator {
  /// Where we expect you to place the bundled library you exported earlier.
  /// You can rename the file; just update this path and pubspec assets.


  static const String _assetPath = 'assets/exercise_dump_20251109_112626.json';
  // Max circuits per day (age-dependent). Default = 5.
  static const int _defaultMaxCircuitsPerDay = 5;
  static int _maxCircuitsPerDay = _defaultMaxCircuitsPerDay;

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

    // 2) Read knobs from onboarding
    final int weeklyFrequency = _readWeeklyFrequency(onboarding) ?? 4; // default to 4
    final bool isFemale = sexU == 'F' || sexU == 'N';

    // Age-based max circuits per day: >27 → 4 circuits, else default (5).
    _maxCircuitsPerDay = (age != null && age > 27)
        ? 4
        : _defaultMaxCircuitsPerDay;

// 🧬 Hypertrophy-focused male flag based on top 2 goals
    final List<dynamic>? goalsRankedRaw =
    onboarding['goalsRanked'] as List<dynamic>?;
    final List<String> topGoals = (goalsRankedRaw ?? const [])
        .map((e) => e.toString())
        .take(2)
        .toList();

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
      // rules: keep Squat Pattern min 2 regardless
      if (k == 'Squat Pattern' && cap['min']! < 2) cap['min'] = 2;
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
    final int perDayOverallMax = weeklyFrequency * 5; // theoretical high ceiling

    void allocate(String cat) {
      final cap = freqCaps[cat];
      if (cap == null) return;
      final have = byCat[cat]?.isNotEmpty == true;
      if (!have) return;
      final want = cap['max']!;
      weeklyPlan[cat] = want;
    }

    // Ensure weekly minimums by sex (after we’ve built the first pass of weeklyPlan).
    final categoryEmphasis = _buildCategoryEmphasis(onboarding);


    _enforceWeeklyMinimums(
      isFemale: isFemale,
      weeklyPlan: weeklyPlan,
      freqCaps: freqCaps,
      byCat: byCat,
      categoryEmphasis: categoryEmphasis, // 🆕
    );

// 🧭 Emphasis routing (child sliders → category bumps + id targets)
    final childLevels = _buildChildEmphasis(onboarding);
    final routed = _routeEmphasisToDemand(childLevels: childLevels, byCat: byCat);
    final Map<String,int> _idTargetsRemaining = Map.of(routed.idTargets);

// Lift weekly minima by emphasis bumps (respect caps & availability)
    _applyEmphasisCategoryBumps(
      weeklyPlan: weeklyPlan,
      freqCaps: freqCaps,
      byCat: byCat,
      categoryBumps: routed.categoryBumps,
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
    //    For block 2, we mirror the same count (names B2 Day1..DayN)
    final days = List.generate(
      weeklyFrequency,
          (i) => _DayPlan(index: i, totalDays: weeklyFrequency),
    ); // <-- close List.generate here

// Seed each day with the requested “minimum per day” set for the user’s sex.
// (This is a soft seed; further placements will still obey pairing rules.)
    _seedDailyMinimums(
      days: days,
      isFemale: isFemale,
      byCat: byCat,
      allDays: days,                           // 🆕
      idTargetsRemaining: _idTargetsRemaining, // 🆕
      isHypertrophyMale: isHypertrophyMale,
      requiredHPullPrimaryDays: requiredHPullPrimaryDays,
    );




    // 7) Greedy round-robin placement following pairing & overlap rules.
    // Per-day category cap: "prefer 1, allow 2" → enforce hard cap = 2
    const int perDayCategoryHardCap = 2;

    // Make a working list of categories expanded by their weekly counts.
    final workList = <String>[];
    weeklyPlan.forEach((cat, n) {
      for (int i = 0; i < n; i++) {
        workList.add(cat);
      }
    });

    // Rotation pointer
    int cursor = 0;
    for (final cat in workList) {
      bool placed = false;
      for (int attempts = 0; attempts < weeklyFrequency; attempts++) {
        final dayIdx = (cursor + attempts) % weeklyFrequency;
        final day = days[dayIdx];

        // Per-day category count
        final usedThisCat = day.countByCategory[cat] ?? 0;
        if (usedThisCat >= perDayCategoryHardCap) continue;

        final chosen = _chooseExercise(
          pool: byCat[cat] ?? const [],
          day: day,
          category: cat,
          allDays: days,
          idTargetsRemaining: _idTargetsRemaining, // 🆕
        );

        if (chosen == null) continue;

        // Allocate to a circuit that respects pairing rules
        final circuitIdx = _placeIntoCircuit(day, chosen);
        day.addExercise(chosen, cat, circuitIdx);
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

    // 9) Create Block 2 variants (same categories, but we’ll bias toward alternates)
    final daysB2 = _alternateBlock(days, byCat);
    for (int i = 0; i < daysB2.length; i++) {
      out.add({
        'name': 'B2 Day ${i + 1}',
        'exercises': daysB2[i].emit(),
      });
    }

    // 10) Create Block 3 variants (another alternate pass off B2)
    final daysB3 = _alternateBlock(daysB2, byCat);
    for (int i = 0; i < daysB3.length; i++) {
      out.add({
        'name': 'B3 Day ${i + 1}',
        'exercises': daysB3[i].emit(),
      });
    }


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
    // Extend here later: e.g., 'Arm Curl' from 'biceps', 'Arm Extension' from 'triceps', etc.
    return <String, int>{
      'Calf Raise': _readEmphasisLevel(onb, 'calves'),
      'Arm Curl': _readEmphasisLevel(onb, 'biceps'),
      'Arm Extension': _readEmphasisLevel(onb, 'triceps'),
      'Horizontal Press': _readEmphasisLevel(onb, 'chest'),
      'Vertical Pull': _readEmphasisLevel(onb, 'lats'),

    };
  }

  // Max emphasis-driven minimums per category (default ceiling = 3)
  static const Map<String, int> _emphasisMinCeilByCat = {
    'Horizontal Press': 4, // chest can scale up to 4
    // everything else defaults to 3
  };



  // Frequency caps by sex, for ≥4 days/wk baseline; we’ll reduce max if fewer days.
  static Map<String, Map<String, int>> _capsFor({required bool isFemale}) {
    if (isFemale) {
      return {
        'Horizontal Press': {'min': 1, 'max': 4},
        'Vertical Press'  : {'min': 0, 'max': 2},
        'Horizontal Pull' : {'min': 1, 'max': 4},
        'Vertical Pull'   : {'min': 1, 'max': 4},
        'Lateral Raise'   : {'min': 1, 'max': 2},
        'Arm Extension'   : {'min': 1, 'max': 4},
        'Arm Curl'        : {'min': 1, 'max': 2},
        'Squat Pattern'   : {'min': 2, 'max': 2},
        'Leg Extension'   : {'min': 1, 'max': 3},
        'Hip Hinge'       : {'min': 2, 'max': 4}, // max deadlift 2/wk is enforced at choose-time
        'Leg Curl'        : {'min': 2, 'max': 4},
        'Calf Raise'      : {'min': 0, 'max': 5}, // 🆕 allow up to 3x/wk
        'Hip Abduction'   : {'min': 0, 'max': 5}, // 🆕 allow up to 3x/wk
        'Core'            : {'min': 1, 'max': 7}, // we’ll cap by per-day pairing/circuits anyway
      };
    }
    // Male/default
    return {
      'Horizontal Press': {'min': 1, 'max': 4},
      'Vertical Press'  : {'min': 0, 'max': 2},
      'Horizontal Pull' : {'min': 1, 'max': 4},
      'Vertical Pull'   : {'min': 1, 'max': 4},
      'Lateral Raise'   : {'min': 1, 'max': 4},
      'Arm Extension'   : {'min': 1, 'max': 4},
      'Arm Curl'        : {'min': 1, 'max': 4},
      'Squat Pattern'   : {'min': 2, 'max': 2},
      'Leg Extension'   : {'min': 1, 'max': 3},
      'Hip Hinge'       : {'min': 1, 'max': 3}, // max deadlift 2/wk enforced later
      'Leg Curl'        : {'min': 1, 'max': 3},
      'Calf Raise'      : {'min': 1, 'max': 5}, // 🆕 allow up to 3x/wk
      'Core'            : {'min': 1, 'max': 4},
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
    Map<String, int> categoryEmphasis = const {}, // 🆕 emphasis per category (0..3)
  }) {

    void bump(String cat, int min) {
      final cap = freqCaps[cat];
      if (cap == null) return;
      if ((byCat[cat]?.isEmpty ?? true)) return;
      final current = weeklyPlan[cat] ?? 0;
      final desired = current < min ? min : current;
      weeklyPlan[cat] = desired.clamp(cap['min']!, cap['max']!);
    }


    // Helper: bump with emphasis (min = clamp(baseMin + level, baseMin..ceiling)), then respect caps & availability
    void bumpWithEmphasis(String cat, int baseMin) {
      final cap = freqCaps[cat];
      if (cap == null) return;
      if ((byCat[cat]?.isEmpty ?? true)) return;

      final level   = (categoryEmphasis[cat] ?? 0).clamp(0, 3); // 0..3 from onboarding
      final ceiling = _emphasisMinCeilByCat[cat] ?? 3;          // default emphasis ceiling = 3
      final boosted = (baseMin + level).clamp(baseMin, ceiling);

      final current = weeklyPlan[cat] ?? 0;
      final desired = current < boosted ? boosted : current;

      weeklyPlan[cat] = desired.clamp(cap['min']!, cap['max']!);
    }



    if (isFemale) {
      // Female weekly minimums (existing fixed mins)
      bump('Squat Pattern', 2);
      bump('Hip Hinge', 1);
      bump('Leg Curl', 2);
      bump('Core', 2);

// Both sexes (now emphasis-aware)
      bumpWithEmphasis('Calf Raise', 1);     // base 1 → +level, ceiling 3
      bumpWithEmphasis('Arm Curl', 1);       // base 1 → +level, ceiling 3
      bumpWithEmphasis('Arm Extension', 1);  // base 1 → +level, ceiling 3
      bumpWithEmphasis('Horizontal Press', 0); // female base 0 → +level, chest ceiling 4
      bumpWithEmphasis('Vertical Pull', 0);    // base 0 → +level, ceiling 3

// Female-specific fixed minimums
      bump('Hip Abduction', 2);

    } else {
      // Male weekly minimums (existing)
      // Male weekly minimums (fixed mins)
      bump('Squat Pattern', 2);
      bump('Hip Hinge', 1);
      bump('Core', 2);

// Both sexes (now emphasis-aware)
      bumpWithEmphasis('Calf Raise', 1);     // base 1 → +level, ceiling 3
      bumpWithEmphasis('Arm Curl', 1);       // base 1 → +level, ceiling 3
      bumpWithEmphasis('Arm Extension', 1);  // base 1 → +level, ceiling 3

// Male-specific: keep base mins but allow emphasis to push higher (within ceilings)
      bumpWithEmphasis('Horizontal Press', 2); // base 2 → +level, chest ceiling 4
      bumpWithEmphasis('Horizontal Pull', 1);  // base 1 → +level, ceiling 3
      bumpWithEmphasis('Vertical Pull', 1);    // base 1 → +level, ceiling 3
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
      );

      if (picked == null) continue;
      final ci = _placeIntoCircuit(day, picked);
      day.addExercise(picked, cat, ci);
      return true;
    }
    return false;
  }


  // Seed a day with the preferred “minimum per day” set for the given sex.
  // Seed a day with the preferred “minimum per day” set for the given sex.
  static void _seedDailyMinimums({
    required List<_DayPlan> days,
    required bool isFemale,
    required Map<String, List<ExLite>> byCat,
    required List<_DayPlan> allDays,                // 🆕
    Map<String,int>? idTargetsRemaining,            // 🆕
    bool isHypertrophyMale = false,
    int requiredHPullPrimaryDays = 0,
  }) {
    final sets = isFemale ? _femaleDailyPrefSets : _maleDailyPrefSets;
    final int weeklyFrequency = days.length;

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
        if (haveHP && haveHPull) {
          // Step A: Horizontal Press first
          final hp = _chooseExercise(
            pool: hpPool!,
            day: d,
            category: 'Horizontal Press',
            allDays: allDays,
            idTargetsRemaining: idTargetsRemaining,
          );

          if (hp != null) {
            final hpCircuitIdx = _placeIntoCircuit(d, hp); // usually creates circuit 0
            d.addExercise(hp, 'Horizontal Press', hpCircuitIdx);

            // Step B: Horizontal Pull second, ideally in the same circuit 0
            final hPull = _chooseExercise(
              pool: hPullPool!,
              day: d,
              category: 'Horizontal Pull',
              allDays: allDays,
              idTargetsRemaining: idTargetsRemaining,
            );

            if (hPull != null) {
              int targetCircuit = 0;
              if (d.circuits.isNotEmpty && _canJoin(d, 0, hPull)) {
                targetCircuit = 0; // pair with the press
              } else {
                targetCircuit = _placeIntoCircuit(d, hPull);
              }
              d.addExercise(hPull, 'Horizontal Pull', targetCircuit);
            }
          }
        }

        // ── Circuit 1: Vertical Press (or LR) → Vertical Pull ────────────────
        if (haveVPull && (haveVPress || haveLatR)) {
          // Ensure there is at least one circuit before we try to target index 1
          if (d.circuits.isEmpty) {
            // If somehow no circuits yet, we’ll let placement logic create them
            // when we place the first exercise below.
          }

          // First exercise for Circuit 1: prefer Vertical Press,
          // but if it can't be placed and weeklyFrequency > 2,
          // we allow Lateral Raise as a flexible alternative.
          ExLite? firstC1;
          String? firstC1Category;

          // Prefer Vertical Press
          if (haveVPress) {
            final vp = _chooseExercise(
              pool: vPressPool!,
              day: d,
              category: 'Vertical Press',
              allDays: allDays,
              idTargetsRemaining: idTargetsRemaining,
            );
            if (vp != null) {
              firstC1 = vp;
              firstC1Category = 'Vertical Press';
            }
          }

          // Flexible Lateral Raise option (only if we couldn't place VP)
          if (firstC1 == null && weeklyFrequency > 2 && haveLatR) {
            final lr = _chooseExercise(
              pool: latRaisePool!,
              day: d,
              category: 'Lateral Raise',
              allDays: allDays,
              idTargetsRemaining: idTargetsRemaining,
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

            // Second exercise for Circuit 1: Vertical Pull
            final vPull = _chooseExercise(
              pool: vPullPool!,
              day: d,
              category: 'Vertical Pull',
              allDays: allDays,
              idTargetsRemaining: idTargetsRemaining,
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
            }
          }
        }

        // We successfully attempted a "primary hypertrophy day" pattern on this day
        remainingHPullPrimaryDays--;
      }

      // 🔁 Then apply the normal daily preference sets
      for (final choiceList in sets) {
        _trySeedOneFrom(
          day: d,
          choices: choiceList,
          byCat: byCat,
          allDays: allDays,                      // keep explicit
          idTargetsRemaining: idTargetsRemaining,
        );
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
  }) {
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
      // Prefer specific accessories
      for (final ex in pool) {
        // 🚫 Allow only one "squat" exercise by name per day
        if (_alreadyHasSquatNamedExercise(day) &&
            ex.name.toLowerCase().contains('squat')) {
          continue;
        }

        if (!_isPreferredAccessoryHorizontalPress(ex)) continue;
        if (day.hasExercise(ex.id)) continue;
        if (day.isBanned(ex, category)) continue;
        return ex; // choose preferred accessory
      }
      // Otherwise, still enforce "not bench" for this first slot
      for (final ex in pool) {
        // 🚫 Allow only one "squat" exercise by name per day
        if (_alreadyHasSquatNamedExercise(day) &&
            ex.name.toLowerCase().contains('squat')) {
          continue;
        }

        if (_isBarbellBenchPress(ex)) continue;   // skip bench here
        if (day.hasExercise(ex.id)) continue;
        if (day.isBanned(ex, category)) continue;
        return ex; // choose any non-bench option
      }
      // If nothing else is allowed/available, fall through to normal logic.
    }

    // 🧠 Global week-level limit — per-exercise caps + no back-to-back days
// - Bench Press (barbell): no cap, no spacing rule
// - Calf Raise (any): max 3 uses/week
// - Everything else: max 2 uses/week
//   PLUS: avoid using the same exercise on two consecutive days,
//   except Back Squat, Barbell when weeklyFrequency > 2.
    for (final ex in pool.toList()) {
      // Bench: no weekly cap or spacing rule
      if (_isBarbellBenchPress(ex)) continue; // skip bench entirely for this rule

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

      // 🚫 No two consecutive days (spacing rule)
      bool usedYesterday = false;
      if (day.index > 0) {
        final prevDay = allDays[day.index - 1];
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
    if (category == 'Horizontal Press' && (day.countByCategory['Horizontal Press'] ?? 0) == 0) {
      for (final ex in pool) {
        // 🚫 Allow only one "squat" exercise by name per day
        if (_alreadyHasSquatNamedExercise(day) &&
            ex.name.toLowerCase().contains('squat')) {
          continue;
        }

        if (!_isBarbellBenchPress(ex)) continue;
        if (day.hasExercise(ex.id)) continue;      // not already used today
        if (day.isBanned(ex, category)) continue;  // respect day-level bans
        return ex;                                 // prefer this exact pick
      }
      // If no barbell bench is available/allowed, we fall through to normal logic.
    }

    // 🥇 Try to satisfy any remaining exercise-ID targets first (preferred picks)
    if (idTargetsRemaining != null && idTargetsRemaining.isNotEmpty) {
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

        // Must be able to join some circuit (or open a new one if under 5)
        bool canJoinAny = false;
        for (int ci = 0; ci < day.circuits.length; ci++) {
          if (_canJoin(day, ci, ex)) { canJoinAny = true; break; }
        }
        if (!canJoinAny && day.circuits.length >= _maxCircuitsPerDay) continue;

        _decrementTarget(idTargetsRemaining, ex.id);
        return ex;
      }
    }

    // Default chooser (only pick if it can legally join some circuit)
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
          if (used >= maxPerWeek) continue; // skip, already at cap
        }
      }

      // 🧠 pre-check: must be able to join at least one current circuit, or we start a new one if under cap
      bool canJoinAny = false;
      for (int ci = 0; ci < day.circuits.length; ci++) {
        if (_canJoin(day, ci, ex)) { canJoinAny = true; break; }
      }
      if (!canJoinAny && day.circuits.length >= _maxCircuitsPerDay) continue; // skip if no spot and we've hit circuit cap

      return ex;
    }

    return null;
  }



  /// Decide circuit index (0..N) for a chosen exercise to minimize overlap.
  static int _placeIntoCircuit(_DayPlan day, ExLite ex) {
    // Try to put it in the BEST existing circuit (by score), else start new one.

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

    if (day.circuits.length < _maxCircuitsPerDay) {
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
    for (final p in circuit) {
      if (_normCat(p.category) == _normCat(ex.category)) return false;
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
    final raw = (onb['emphasis'] is Map) ? (onb['emphasis'][key]) : onb[key];
    if (raw is int) return raw.clamp(0, 3);
    if (raw is double) return raw.round().clamp(0, 3);
    if (raw is String) {
      final p = int.tryParse(raw);
      if (p != null) return p.clamp(0, 3);
    }
    return 0;
  }

// Child muscle → emphasis level (0–3).
  static Map<String, int> _buildChildEmphasis(Map<String, dynamic> onb) {
    return <String, int>{
      // Back
      'Lats': _readChildLevel(onb, 'lats'),
      'Mid traps & rear delts': _readChildLevel(onb, 'upper_back'),
      'Lower back 🎄': _readChildLevel(onb, 'lower_back'),

      // Delts / traps
      'Anterior delts': _readChildLevel(onb, 'anterior_delts'),
      'Lateral delts': _readChildLevel(onb, 'lateral_delts'),
      'Upper traps': _readChildLevel(onb, 'upper_traps'),

      // Arms
      'Biceps': _readChildLevel(onb, 'biceps'),
      'Triceps': _readChildLevel(onb, 'triceps'),
      'Forearms': _readChildLevel(onb, 'forearms'),

      // Glutes
      'Glute Maximus': _readChildLevel(onb, 'glute_max'),
      'Glute Medius': _readChildLevel(onb, 'glute_medius'),

      // Big groups
      'Chest': _readChildLevel(onb, 'chest'),
      'Abs': _readChildLevel(onb, 'core'),
      'Hamstrings': _readChildLevel(onb, 'hamstrings'),
      'Quads': _readChildLevel(onb, 'quads'),
      'Calves': _readChildLevel(onb, 'calves'),
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
  }) {
    final cat = <String, int>{};
    final ids = <String, int>{};

    int bump(double x) => x.round().clamp(0, 99);

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
    if (chestL > 0) addCat('Horizontal Press', chestL);

    // Lats → Vertical Pull (+ optional horiz-pull IDs later)
    final latsL = childLevels['Lats'] ?? 0;
    if (latsL > 0) addCat('Vertical Pull', latsL);

    // Mid traps & rear delts → Horizontal Pull
    final upperBackL = childLevels['Mid traps & rear delts'] ?? 0;
    if (upperBackL > 0) addCat('Horizontal Pull', upperBackL);

    // Lower back → Hip Hinge
    final lowBackL = childLevels['Lower back 🎄'] ?? 0;
    if (lowBackL > 0) addCat('Hip Hinge', lowBackL);

    // Anterior delts → VP + HP + LR
    final antDeltsL = childLevels['Anterior delts'] ?? 0;
    if (antDeltsL > 0) {
      addCat('Vertical Press', bump(antDeltsL * _w60));
      addCat('Horizontal Press', bump(antDeltsL * _w40));
      addCat('Lateral Raise',   bump(antDeltsL * _w40));
    }

    // Lateral delts → LR + VP
    final latDeltsL = childLevels['Lateral delts'] ?? 0;
    if (latDeltsL > 0) {
      addCat('Lateral Raise', bump(latDeltsL * _w60));
      addCat('Vertical Press', bump(latDeltsL * _w40));
    }

    // Upper traps → Vertical Press
    final upperTrapsL = childLevels['Upper traps'] ?? 0;
    if (upperTrapsL > 0) addCat('Vertical Press', upperTrapsL);

    // Biceps → Arm Curl (+ preferred IDs)
    final bicepsL = childLevels['Biceps'] ?? 0;
    if (bicepsL > 0) {
      addCat('Arm Curl', bicepsL);
      addId(_idSupinatedLatPulldown, bicepsL);
      addId(_idChinUp, bicepsL);
    }

    // Triceps → Arm Extension (+ OHP ID)
    final tricepsL = childLevels['Triceps'] ?? 0;
    if (tricepsL > 0) {
      addCat('Arm Extension', tricepsL);
      addId(_idBarbellOverheadPress, tricepsL);
    }

    // Forearms → Pulls + Curl (+ optional isolation ids)
    final forearmsL = childLevels['Forearms'] ?? 0;
    if (forearmsL > 0) {
      addCat('Horizontal Pull', bump(forearmsL * _w50));
      addCat('Vertical Pull',   bump(forearmsL * _w50));
      addCat('Arm Curl',        bump(forearmsL * _w40));
      if (forearmsL >= 3) {
        for (final id in _forearmIsolationIds) {
          addId(id, 1);
        }
      }
    }

    // Glute Max → Hip Hinge + Squat Pattern
    final gmaxL = childLevels['Glute Maximus'] ?? 0;
    if (gmaxL > 0) {
      addCat('Hip Hinge',     bump(gmaxL * _w50));
      addCat('Squat Pattern', bump(gmaxL * _w50));
    }

    // Glute Med → Hip Abduction
    final gmedL = childLevels['Glute Medius'] ?? 0;
    if (gmedL > 0) addCat('Hip Abduction', gmedL);

    // Abs → Core
    final absL = childLevels['Abs'] ?? 0;
    if (absL > 0) addCat('Core', absL);

    // Hamstrings → Leg Curl + Hip Hinge
    final hamsL = childLevels['Hamstrings'] ?? 0;
    if (hamsL > 0) {
      addCat('Leg Curl',  bump(hamsL * _w60));
      addCat('Hip Hinge', bump(hamsL * _w40));
    }

    // Quads → Squat Pattern + Leg Extension
    final quadsL = childLevels['Quads'] ?? 0;
    if (quadsL > 0) {
      addCat('Squat Pattern', bump(quadsL * _w60));
      addCat('Leg Extension', bump(quadsL * _w40));
    }

    // Calves → Calf Raise
    final calvesL = childLevels['Calves'] ?? 0;
    if (calvesL > 0) addCat('Calf Raise', calvesL);

    return (categoryBumps: cat, idTargets: ids);
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


  /// Produce alternate versions for Block-2 by swapping in different exercises
  /// from the same categories where available.
  static List<_DayPlan> _alternateBlock(List<_DayPlan> b1, Map<String, List<ExLite>> byCat) {
    final out = <_DayPlan>[];
    for (final d in b1) {
      final clone = d.clone();
      for (int ci = 0; ci < clone.circuits.length; ci++) {
        for (int ei = 0; ei < clone.circuits[ci].length; ei++) {
          final placed = clone.circuits[ci][ei];
          final pool = byCat[placed.category] ?? const [];
          // try to find a different exercise with the same category
          final alt = pool.firstWhere(
                (x) => x.id != placed.ex.id,
            orElse: () => placed.ex,
          );
          clone.circuits[ci][ei] = _Placed(ex: alt, category: placed.category);
        }
      }
      out.add(clone);
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


