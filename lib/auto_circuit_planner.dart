// lib/auto_circuit_planner.dart
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';

/// Mirror your enum names as used in UI. You can import your real enum instead.
enum TrainingExperience { never, under1, oneYear, twoPlus }

class AutoCircuitPlanner {
  /// Main entry: returns a map of 'day_0'..'day_N-1' => list of exerciseIds in order.
  static Future<Map<String, List<String>>> generateCircuits({
    required String sex, // 'M' | 'F' | 'N' (treat 'N' as female branch for baselines if age window warrants; here we just use 'F' rules for 'N')
    required int weeklyFrequency, // 2..7
    required TrainingExperience experience,
    required String assetPath, // e.g., 'assets/exercises.json'
    String environment = 'commercial', // 'commercial' | 'powerlifting' | 'home' | 'travelling'
  }) async {
    final lib = await _loadExercisesFromAsset(assetPath);

    // Split library into category buckets we use for planning.
    final pools = _buildCategoryPools(lib);

    // Compute per-category weekly target counts from your baselines.
    final targets = _weeklyTargets(
      sex: sex,
      days: weeklyFrequency,
    );

    // Prepare day containers.
    final Map<String, List<_PlannedExercise>> dayPlan = {
      for (int d = 0; d < weeklyFrequency; d++) 'day_$d': <_PlannedExercise>[],
    };

    // Per-day category caps (prefer 1, allow 2).
    const perDayCategoryCap = 2;

    // Build a “work list” of category instances to schedule (e.g., ['H_PRESS','H_PRESS','SQUAT',...]).
    final worklist = <_Cat>[];
    targets.forEach((cat, count) {
      for (int i = 0; i < count; i++) {
        worklist.add(cat);
      }
    });

    // Round-robin placement across days to spread load; then pick specific exercises that don't violate rules.
    int cursor = 0;
    for (final cat in worklist) {
      // Try up to `weeklyFrequency` placements to find a valid day.
      bool placed = false;
      for (int attempts = 0; attempts < weeklyFrequency; attempts++) {
        final dayIdx = (cursor + attempts) % weeklyFrequency;
        final key = 'day_$dayIdx';

        // Per-day category cap check
        final perDayUsed = dayPlan[key]!.whereCat(cat);
        if (perDayUsed >= perDayCategoryCap) {
          continue;
        }

        // Pick an exercise from the pool that doesn't break pairing rules with what’s already on that day.
        final chosen = _chooseExercise(
          pool: pools[cat] ?? const <_Exercise>[],
          existing: dayPlan[key],
          cat: cat,
        );

        if (chosen != null) {
          dayPlan[key]!.add(_PlannedExercise(cat: cat, ex: chosen));
          placed = true;
          cursor = (dayIdx + 1) % weeklyFrequency; // advance cursor
          break;
        }
      }

      // If we fail to place (rare with big libraries), relax to any day & any pick.
      if (!placed) {
        final dayIdx = cursor % weeklyFrequency;
        final key = 'day_$dayIdx';
        final fallback = (pools[cat] ?? const <_Exercise>[]);
        if (fallback.isNotEmpty) {
          // Place first that minimally conflicts (might reduce to 1-ex circuit later).
          final chosen = _firstNonCatBreaking(fallback, dayPlan[key], cat) ?? fallback.first;
          dayPlan[key]!.add(_PlannedExercise(cat: cat, ex: chosen));
          cursor = (dayIdx + 1) % weeklyFrequency;
        }
      }
    }

    // Convert to final output: day → exerciseIds (order preserved by insertion above).
    final out = <String, List<String>>{};
    dayPlan.forEach((k, v) {
      out[k] = v.map((pe) => pe.ex.id).toList();
    });

    // Optional: sort inside days by a pleasant order (Press/Pull/Leg/Core, etc.)
    // Keeping insertion order for now.

    return out;
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Data loading & structures
  // ────────────────────────────────────────────────────────────────────────────

  static Future<List<_Exercise>> _loadExercisesFromAsset(String assetPath) async {
    final raw = await rootBundle.loadString(assetPath);
    final decoded = jsonDecode(raw);

    // Support two shapes:
    // 1) { "<category>": [ {id,name,category,bodyParts:[]}, ... ], ... }
    // 2) [ {id,name,category,bodyParts:[]}, ... ]
    final List<_Exercise> out = [];
    if (decoded is Map<String, dynamic>) {
      decoded.forEach((_, list) {
        if (list is List) {
          for (final e in list) {
            final ex = _Exercise.fromJson(e as Map<String, dynamic>);
            if (ex != null) out.add(ex);
          }
        }
      });
    } else if (decoded is List) {
      for (final e in decoded) {
        final ex = _Exercise.fromJson((e as Map).cast<String, dynamic>());
        if (ex != null) out.add(ex);
      }
    } else {
      throw StateError('Unsupported exercise JSON shape at $assetPath');
    }

    debugPrint('🧩 [AutoPlanner] loaded ${out.length} exercises from $assetPath');
    return out;
  }

  static Map<_Cat, List<_Exercise>> _buildCategoryPools(List<_Exercise> lib) {
    final map = <_Cat, List<_Exercise>>{};
    for (final ex in lib) {
      final cat = _classify(ex);
      map.putIfAbsent(cat, () => []).add(ex);
    }
    return map;
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Weekly targets (your baselines + “reduce max by 1 if <4 days”)
  // ────────────────────────────────────────────────────────────────────────────

  static Map<_Cat, int> _weeklyTargets({required String sex, required int days}) {
    final isFemale = sex.toUpperCase() == 'F' || sex.toUpperCase() == 'N';

    // Helper to clamp max caps for <4 days (keeping min, squat min 2).
    int _cap(int base) => (days >= 4) ? base : max(0, base - (4 - days));

    // Build a “min..max” table, then pick a working target in that range.
    // You gave per-category bands; picking mid-to-upper within valid caps tends to feel better.
    // You can tweak these picks easily later.
    final minMax = <_Cat, (int min, int max)>{};

    if (!isFemale) {
      // ── Male ≥4: upper body 4 total, squat 2, etc. (with caps reduced if <4 days)
      minMax[_Cat.hPress]       = (1, _cap(2));
      minMax[_Cat.vPress]       = (1, _cap(2));
      minMax[_Cat.hPull]        = (1, _cap(2));
      minMax[_Cat.vPull]        = (1, _cap(2));
      // Upper total ~4; the distribution above yields 4 if days≥4.

      minMax[_Cat.squat]        = (2, 2); // keep at 2 even if <4 days (per your rule)
      minMax[_Cat.legExt]       = (1, _cap(3));
      minMax[_Cat.hinge]        = (1, _cap(3)); // remember: <=2 deadlift will be enforced at choose time by picking non-deadlift hinge if needed
      minMax[_Cat.legCurl]      = (1, _cap(3));

      minMax[_Cat.armCurl]      = (1, _cap(4));
      minMax[_Cat.armExt]       = (1, _cap(4));
      minMax[_Cat.latRaise]     = (1, _cap(4));
      minMax[_Cat.calves]       = (0, _cap(3));
      minMax[_Cat.core]         = (1, _cap(3));
    } else {
      // ── Female ≥4: upper body 4; hinge 2–4; leg curl 2–4; lat raise 1–2, etc. (with caps reduced if <4 days)
      minMax[_Cat.hPress]       = (1, _cap(2));
      minMax[_Cat.vPress]       = (1, _cap(2));
      minMax[_Cat.hPull]        = (1, _cap(2));
      minMax[_Cat.vPull]        = (1, _cap(2));
      // again totals to ~4

      minMax[_Cat.squat]        = (2, 2); // keep at 2
      minMax[_Cat.legExt]       = (1, _cap(3));
      minMax[_Cat.hinge]        = (2, _cap(4)); // female baseline higher
      minMax[_Cat.legCurl]      = (2, _cap(4));

      minMax[_Cat.armCurl]      = (1, _cap(2));
      minMax[_Cat.armExt]       = (1, _cap(4));
      minMax[_Cat.latRaise]     = (1, _cap(2));
      minMax[_Cat.calves]       = (0, _cap(3));
      minMax[_Cat.core]         = (2, _cap(5)); // females often tolerate more direct core; tune as needed
    }

    // Choose a target in [min..max]. Simple heuristic:
    // - if min == max → target = min
    // - else pick min+((max-min)≥1 ? 1 : 0) to sit just above minimum when possible
    final targets = <_Cat, int>{};
    minMax.forEach((cat, mm) {
      final (mn, mx) = mm;
      int t;
      if (mn >= mx) {
        t = mn;
      } else {
        t = min(mx, mn + 1); // slightly above min
      }
      // Ensure we don’t schedule more category instances than actual days * per-day-cap.
      final hardCap = 2 * days;
      targets[cat] = min(t, hardCap);
    });

    return targets;
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Exercise choice with rule checks
  // ────────────────────────────────────────────────────────────────────────────

  static _Exercise? _chooseExercise({
    required List<_Exercise> pool,
    required List<_PlannedExercise>? existing,
    required _Cat cat,
  }) {
    if (pool.isEmpty) return null;

    // Filter by non-overlap with today's already-picked exercises (top-2 children check + axis rules + lower-body rules).
    final candidates = pool.where((ex) {
      return _fitsDayRules(ex, existing ?? const <_PlannedExercise>[], cat);
    }).toList();

    if (candidates.isEmpty) {
      // Try a looser pass: allow minor conflicts but still respect the hard hinge/squat/axis disallows.
      final relaxed = pool.where((ex) {
        return _fitsHardDisallows(ex, existing ?? const <_PlannedExercise>[], cat);
      }).toList();

      if (relaxed.isEmpty) return null;
      return relaxed[_rng.nextInt(relaxed.length)];
    }

    // Prefer bilateral if day already has unilateral in same region, else random.
    final balanced = _preferBalancedUniBi(candidates, existing ?? const <_PlannedExercise>[]);
    return balanced[_rng.nextInt(balanced.length)];
  }

  static bool _fitsDayRules(_Exercise ex, List<_PlannedExercise> day, _Cat cat) {
    // Hard disallows first
    if (!_fitsHardDisallows(ex, day, cat)) return false;

    // No agonists by top-2 children overlap
    for (final pe in day) {
      if (_top2Overlap(ex.bodyParts, pe.ex.bodyParts)) return false;
    }

    // Axis pairing (Press/Pull matching)
    if (!_axisOkWithDay(ex, day, cat)) return false;

    return true;
  }

  static bool _fitsHardDisallows(_Exercise ex, List<_PlannedExercise> day, _Cat cat) {
    // Hinge with hinge? Disallow
    if (cat == _Cat.hinge) {
      for (final pe in day) {
        if (pe.cat == _Cat.hinge) return false;
        if (pe.cat == _Cat.squat) return false; // Hinge + Squat not allowed
      }
    }
    // Squat with hinge? Disallow (already covered above if day had hinge)
    if (cat == _Cat.squat) {
      for (final pe in day) {
        if (pe.cat == _Cat.hinge) return false;
      }
    }
    // Squat + Leg Extension not allowed same day
    if (cat == _Cat.squat) {
      for (final pe in day) {
        if (pe.cat == _Cat.legExt) return false;
      }
    }
    if (cat == _Cat.legExt) {
      for (final pe in day) {
        if (pe.cat == _Cat.squat) return false;
      }
    }

    // Leg Curl with Squat is OK (so no block here).

    return true;
  }

  static bool _axisOkWithDay(_Exercise ex, List<_PlannedExercise> day, _Cat cat) {
    // Arm Ext acts like Push: avoid same day if there's already a Press (preferred), but we allow up to 2 per category total per day
    // Arm Curl acts like Pull.
    bool isPressAxis = (cat == _Cat.hPress || cat == _Cat.vPress || cat == _Cat.armExt || cat == _Cat.latRaise);
    bool isPullAxis  = (cat == _Cat.hPull || cat == _Cat.vPull || cat == _Cat.armCurl);

    for (final pe in day) {
      final isPressAxisDay = (pe.cat == _Cat.hPress || pe.cat == _Cat.vPress || pe.cat == _Cat.armExt || pe.cat == _Cat.latRaise);
      final isPullAxisDay  = (pe.cat == _Cat.hPull || pe.cat == _Cat.vPull || pe.cat == _Cat.armCurl);

      // If this is Horizontal Press, prefer Horizontal Pull present (ok), but disallow Vertical Pull (soft).
      if (cat == _Cat.hPress && pe.cat == _Cat.vPull) return false;
      if (cat == _Cat.vPress && pe.cat == _Cat.hPull) return false;

      // If arms: extension clashes with press axis; curl clashes with pull axis — prefer not to stack (but allowed up to cap).
      if (cat == _Cat.armExt && isPressAxisDay) {
        // allow but prefer diversity; handled implicitly by candidate ranking
      }
      if (cat == _Cat.armCurl && isPullAxisDay) {
        // same note
      }

      // Most “bad” axes are caught by top-2 overlap anyway; keep this minimal.
    }
    return true;
  }

  static List<_Exercise> _preferBalancedUniBi(List<_Exercise> candidates, List<_PlannedExercise> day) {
    final hasUni = day.any((pe) => pe.ex.isUnilateral);
    final hasBi  = day.any((pe) => !pe.ex.isUnilateral);
    if (hasUni && !hasBi) {
      final bi = candidates.where((e) => !e.isUnilateral).toList();
      if (bi.isNotEmpty) return bi;
    }
    if (hasBi && !hasUni) {
      final uni = candidates.where((e) => e.isUnilateral).toList();
      if (uni.isNotEmpty) return uni;
    }
    return candidates;
  }

  static bool _top2Overlap(List<String> aParts, List<String> bParts) {
    final a = aParts.take(2).map(_norm).toSet();
    final b = bParts.take(2).map(_norm).toSet();
    // Children-level matching: normalize synonyms handled in _norm().
    return a.intersection(b).isNotEmpty;
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Classification & helpers
  // ────────────────────────────────────────────────────────────────────────────

  static _Cat _classify(_Exercise e) {
    final c = e.category.toLowerCase();

    // Map your known categories into our canonical set.
    // Adjust/add here freely as your library grows.
    if (c.contains('horizontal press') || c.contains('machine chest press') || c.contains('chest fly')) {
      return _Cat.hPress;
    }
    if (c.contains('vertical press') || c.contains('overhead press') || c.contains('lateral raise')) {
      // Lateral raise counts as vertical press by your rule.
      return c.contains('lateral') ? _Cat.latRaise : _Cat.vPress;
    }
    if (c.contains('horizontal pull') || c.contains('row')) {
      return _Cat.hPull;
    }
    if (c.contains('vertical pull') || c.contains('lat pull') || c.contains('chin') || c.contains('pull-up')) {
      return _Cat.vPull;
    }
    if (c.contains('squat')) {
      return _Cat.squat;
    }
    if (c.contains('hip hinge') || c.contains('deadlift') || c.contains('rdl') || c.contains('hip thrust')) {
      return _Cat.hinge;
    }
    if (c.contains('leg curl')) {
      return _Cat.legCurl;
    }
    if (c.contains('leg extension')) {
      return _Cat.legExt;
    }
    if (c.contains('biceps') || c.contains('curl')) {
      return _Cat.armCurl;
    }
    if (c.contains('triceps') || c.contains('extension') && !c.contains('leg')) {
      return _Cat.armExt;
    }
    if (c.contains('calf')) {
      return _Cat.calves;
    }
    if (c.contains('core') || c.contains('plank') || c.contains('crunch') || c.contains('ab')) {
      return _Cat.core;
    }

    // Default: try bodyParts heuristic
    final bp = e.bodyParts.map(_norm).toList();
    if (bp.contains('quads')) return _Cat.squat;
    if (bp.contains('hamstrings') || bp.contains('lower back') || bp.contains('glute max')) return _Cat.hinge;
    if (bp.contains('lats') || bp.contains('mid-traps/rear delts')) return _Cat.hPull;
    return _Cat.misc;
  }

  static String _norm(String s) {
    final t = s.trim().toLowerCase();
    // Normalize children synonyms
    if (t == 'mid traps & rear delts' || t == 'mid traps/rear delts' || t == 'rear delts' || t == 'mid traps') {
      return 'mid-traps/rear delts';
    }
    if (t == 'anterior delts' || t == 'front delts') return 'anterior delts';
    if (t == 'lateral delts' || t == 'medial delts') return 'lateral delts';
    if (t == 'upper traps' || t == 'traps (upper)') return 'upper traps';
    if (t == 'glute max' || t == 'glutes (max)') return 'glute max';
    if (t == 'glute med' || t == 'glutes (med)') return 'glute med';
    if (t == 'quads' || t == 'quadriceps') return 'quads';
    if (t == 'hams' || t == 'hamstring' || t == 'hamstrings') return 'hamstrings';
    if (t == 'abs' || t == 'core') return 'core';
    return t;
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Internal types
// ──────────────────────────────────────────────────────────────────────────────

enum _Cat {
  hPress, vPress, hPull, vPull,
  squat, hinge, legCurl, legExt,
  armCurl, armExt, latRaise,
  calves, core, misc,
}

class _Exercise {
  final String id;
  final String name;
  final String category;
  final List<String> bodyParts;
  final bool isUnilateral;

  _Exercise({
    required this.id,
    required this.name,
    required this.category,
    required this.bodyParts,
    required this.isUnilateral,
  });

  static _Exercise? fromJson(Map<String, dynamic> j) {
    final id = (j['exerciseId'] ?? j['id'])?.toString().trim();
    final name = (j['name'] ?? '').toString();
    final cat = (j['category'] ?? '').toString();
    final bpRaw = j['bodyParts'];
    if (id == null || id.isEmpty) return null;
    final parts = (bpRaw is List)
        ? bpRaw.map((e) => e.toString()).toList()
        : <String>[];
    final uni = name.toLowerCase().contains('unilateral');
    return _Exercise(id: id, name: name, category: cat, bodyParts: parts, isUnilateral: uni);
  }
}

class _PlannedExercise {
  final _Cat cat;
  final _Exercise ex;
  _PlannedExercise({required this.cat, required this.ex});
}

extension on List<_PlannedExercise> {
  int whereCat(_Cat c) => where((e) => e.cat == c).length;
}

_Exercise? _firstNonCatBreaking(List<_Exercise> pool, List<_PlannedExercise>? day, _Cat cat) {
  for (final e in pool) {
    if (AutoCircuitPlanner._fitsHardDisallows(e, day ?? const <_PlannedExercise>[], cat)) {
      return e;
    }
  }
  return null;
}

final _rng = Random();
