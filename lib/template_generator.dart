// lib/bootstrap/template_generator.dart
import 'dart:convert';
import 'package:flutter/foundation.dart'; // for debugPrint

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
  }) async {
    // 1) Load library
    final lib = await _loadExerciseLibrary();

    // 2) Read knobs from onboarding
    final int weeklyFrequency = _readWeeklyFrequency(onboarding) ?? 4; // default to 4
    final bool isFemale = sexU == 'F' || sexU == 'N';

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
    for (final e in lib) {
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
    _enforceWeeklyMinimums(
      isFemale: isFemale,
      weeklyPlan: weeklyPlan,
      freqCaps: freqCaps,
      byCat: byCat,
    );


    // Core categories first so we don’t starve them
    for (final cat in _orderedCategoriesPriority) {
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

        // Pick a candidate exercise that doesn’t violate overlap rules on this day
        final chosen = _chooseExercise(
          pool: byCat[cat] ?? const [],
          day: day,
          category: cat,
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



  static int? _readWeeklyFrequency(Map<String, dynamic> onb) {
    final wf = onb['weeklyFrequency'];
    final legacy = onb['minTrainingDaysPerWeek'];
    if (wf is int) return wf;
    if (legacy is int) return legacy;
    return null;
  }

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
      'Core'            : {'min': 1, 'max': 4},
    };
  }

  // Order we try to allocate categories so key work gets space first.
  static const List<String> _orderedCategoriesPriority = [
    'Squat Pattern',
    'Hip Hinge',
    'Horizontal Press',
    'Horizontal Pull',
    'Vertical Press',
    'Vertical Pull',
    'Leg Extension',
    'Leg Curl',
    'Arm Extension',
    'Arm Curl',
    'Lateral Raise',
    'Core',
  ];

  // ── Weekly minimums by sex ────────────────────────────────────────────────
  static void _enforceWeeklyMinimums({
    required bool isFemale,
    required Map<String, int> weeklyPlan,
    required Map<String, Map<String, int>> freqCaps,
    required Map<String, List<ExLite>> byCat,
  }) {
    void bump(String cat, int min) {
      final cap = freqCaps[cat];
      if (cap == null) return;
      if ((byCat[cat]?.isEmpty ?? true)) return;
      final current = weeklyPlan[cat] ?? 0;
      final desired = current < min ? min : current;
      weeklyPlan[cat] = desired.clamp(cap['min']!, cap['max']!);
    }

    if (isFemale) {
      // Female weekly minimums
      bump('Squat Pattern', 2);
      bump('Hip Hinge', 1);
      bump('Leg Curl', 2);
      bump('Core', 2);
    } else {
      // Male weekly minimums
      bump('Squat Pattern', 2);
      bump('Hip Hinge', 1);
      bump('Core', 2);
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
  }) {
    for (final cat in choices) {
      final pool = byCat[cat];
      if (pool == null || pool.isEmpty) continue;
      final picked = _chooseExercise(pool: pool, day: day, category: cat);
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
  }) {
    final sets = isFemale ? _femaleDailyPrefSets : _maleDailyPrefSets;

    for (final d in days) {
      for (final choiceList in sets) {
        _trySeedOneFrom(day: d, choices: choiceList, byCat: byCat);
      }
    }
  }


  /// Returns an exercise that doesn't violate overlap rules *for this day*.
  static ExLite? _chooseExercise({
    required List<ExLite> pool,
    required _DayPlan day,
    required String category,
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
        if (!_isPreferredAccessoryHorizontalPress(ex)) continue;
        if (day.hasExercise(ex.id)) continue;
        if (day.isBanned(ex, category)) continue;
        return ex; // choose preferred accessory
      }
      // Otherwise, still enforce "not bench" for this first slot
      for (final ex in pool) {
        if (_isBarbellBenchPress(ex)) continue;   // skip bench here
        if (day.hasExercise(ex.id)) continue;
        if (day.isBanned(ex, category)) continue;
        return ex; // choose any non-bench option
      }
      // If nothing else is allowed/available, fall through to normal logic.
    }

    // ✅ Bench-first preference SECOND:
    // If this is the FIRST Horizontal Press of the day, prefer Barbell Bench Press.
    if (category == 'Horizontal Press' && (day.countByCategory['Horizontal Press'] ?? 0) == 0) {
      for (final ex in pool) {
        if (!_isBarbellBenchPress(ex)) continue;
        if (day.hasExercise(ex.id)) continue;      // not already used today
        if (day.isBanned(ex, category)) continue;  // respect day-level bans
        return ex;                                 // prefer this exact pick
      }
      // If no barbell bench is available/allowed, we fall through to normal logic.
    }

    // Default chooser
    for (final ex in pool) {
      if (day.hasExercise(ex.id)) continue;      // 🚫 already used today
      if (day.isBanned(ex, category)) continue;  // existing rule checks
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

    if (day.circuits.length < 5) {
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

    // 1) Category-level rules
    for (final p in circuit) {
      final a = p.category;
      final b = _normCat(ex.category);

      // Horizontal Press vs Vertical Press/Arm Extension
      if (a == 'Horizontal Press' && (b == 'Vertical Press' || b == 'Arm Extension')) return false;
      if (b == 'Horizontal Press' && (a == 'Vertical Press' || a == 'Arm Extension')) return false;

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

    // 3) Circuit length cap (2..5 allowed); we prefer 2–3.
    if (circuit.length >= 5) return false;

    return true;
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
  static bool _isStraightArmLatVariant(ExLite ex) {
    final s = ex.name.toLowerCase();
    final hasStraightArm =
        s.contains('straight arm lat') || s.contains('straight-arm lat') ||
            s.contains('straight arm pull') || s.contains('straight-arm pull') ||
            s.contains('straight arm pulldown') || s.contains('straight-arm pulldown');

    final hasLatPrayer = s.contains('lat prayer');

    // Only treat “pullover/pull over” as this variant when it’s explicitly lat-focused (has “lat”)
    final hasLatPullover =
        (s.contains('pullover') || s.contains('pull over') || s.contains('pull-over')) &&
            s.contains('lat');

    return hasStraightArm || hasLatPrayer || hasLatPullover;
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

  // === ADD THIS INSIDE class TemplateGenerator, near the end ===
  static Future<void> debugPrintExerciseAsset() async {
    try {
      final lib = await _loadExerciseLibrary();
      debugPrint('📦 [GEN] parsed ${lib.length} exercises from bundled asset');
      for (final e in lib.take(10)) {
        debugPrint('   → ${e.name} (${e.category})');
      }
    } catch (e, st) {
      debugPrint('❌ [TEST] loadExerciseLibrary failed: $e\n$st');
    }
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


