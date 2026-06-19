/// Pure, Firestore-free helpers for canonical `exerciseSettings` merging,
/// model-aware cross-week propagation, and conservative sparse-shadow repair.
///
/// These functions never touch any storage and never reference the deprecated
/// `plannedExerciseDetails` structure. They operate only on the in-memory
/// `exerciseSettings[exerciseId]` map shape:
///   {
///     periodizationModel, rirModel, progressionModel,
///     weeklyFrequency, defaultSets, increments:{primary,secondary},
///     repTargets: { week1:{instance1:'9 x 3', ...}, repRange:{min,max}, ... },
///     rirPlan:    { week1:{session1:{set1:{rir:'2', reps:'9'}, ...}, ...}, ... },
///     ...unknown keys preserved...
///   }
library;

import 'wes2_exercise_settings_patch.dart';

/// How a week-keyed structure propagates an edit.
enum WeekScope {
  /// `week1` is the single repeating template (DUP By Week / By Exposure;
  /// Static RIR / Session RIR Undulation). Edits write `week1` only and sparse
  /// `weekN` shadows are removed.
  template,

  /// Each week has its own map (Linear rep models; Linear-Taper /
  /// Wave RIR undulation). Edits propagate the changed leaf to all weeks and
  /// sparse `weekN` shadows are filled (never removed).
  perWeek,

  /// DUP Signature rep targets use `repRange.{min,max}` (block-scoped).
  signature,
}

class SettingsMerge {
  // ── Model classification ───────────────────────────────────────────────────

  static WeekScope repTargetScope(String? periodizationModel) {
    final m = periodizationModel ?? '';
    if (m == 'DUP, Signature') return WeekScope.signature;
    if (m == 'DUP, By Week' || m == 'DUP, By Exposure') return WeekScope.template;
    return WeekScope.perWeek; // Linear, Classic / Linear, by Exposure / unknown
  }

  static WeekScope rirScope(String? rirModel) {
    final m = rirModel ?? '';
    // RIR models that genuinely vary across weeks.
    if (m == 'Linear-Taper' || m == 'Wave RIR undulation') {
      return WeekScope.perWeek;
    }
    // Static RIR, Session RIR Undulation, or unspecified → week1 template.
    return WeekScope.template;
  }

  // ── Small map utilities ─────────────────────────────────────────────────────

  static Map<String, dynamic>? asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : null;

  static Map<String, dynamic> deepCopyMap(Map<String, dynamic> src) {
    final out = <String, dynamic>{};
    src.forEach((k, v) {
      out[k] = _deepCopyValue(v);
    });
    return out;
  }

  static dynamic _deepCopyValue(dynamic v) {
    if (v is Map) {
      return v.map((k, val) => MapEntry(k.toString(), _deepCopyValue(val)));
    }
    if (v is List) {
      return v.map(_deepCopyValue).toList();
    }
    return v;
  }

  // ── Leaf application ────────────────────────────────────────────────────────

  /// Sets or clears `rirPlan[weekKey][session][set].rir`, preserving every
  /// sibling key (e.g. `reps`) and every unrelated session/set/week.
  /// Clearing prunes parents only when they become empty as a direct result.
  static void applyRirLeaf(
    Map<String, dynamic> rirPlan,
    String weekKey,
    String session,
    String set,
    String? rir,
  ) {
    final week = asMap(rirPlan[weekKey]) ?? <String, dynamic>{};
    final sess = asMap(week[session]) ?? <String, dynamic>{};
    final st = asMap(sess[set]) ?? <String, dynamic>{};

    if (rir == null || rir.isEmpty) {
      st.remove('rir');
      if (st.isEmpty) {
        sess.remove(set);
      } else {
        sess[set] = st;
      }
      if (sess.isEmpty) {
        week.remove(session);
      } else {
        week[session] = sess;
      }
    } else {
      st['rir'] = rir;
      sess[set] = st;
      week[session] = sess;
    }

    if (week.isEmpty) {
      rirPlan.remove(weekKey);
    } else {
      rirPlan[weekKey] = week;
    }
  }

  /// Sets or clears `repTargets[weekKey][instanceKey]`.
  static void applyRepInstance(
    Map<String, dynamic> repTargets,
    String weekKey,
    String instanceKey,
    String? value,
  ) {
    final week = asMap(repTargets[weekKey]) ?? <String, dynamic>{};
    if (value == null || value.isEmpty) {
      week.remove(instanceKey);
    } else {
      week[instanceKey] = value;
    }
    if (week.isEmpty) {
      repTargets.remove(weekKey);
    } else {
      repTargets[weekKey] = week;
    }
  }

  // ── Cross-week propagation ──────────────────────────────────────────────────

  static void _propagateRir(
    Map<String, dynamic> rirPlan,
    RirChange c,
    WeekScope scope,
    int totalWeeks,
  ) {
    if (scope == WeekScope.template) {
      applyRirLeaf(rirPlan, 'week1', c.session, c.set, c.rir);
      return;
    }
    // perWeek: write the changed leaf to every block week. Materialise a missing
    // week from the week1 template first so previously-resolved (fallback)
    // values are preserved rather than lost.
    final weeks = totalWeeks < 1 ? 1 : totalWeeks;
    for (int w = 1; w <= weeks; w++) {
      final wk = 'week$w';
      if (c.rir != null && c.rir!.isNotEmpty && rirPlan[wk] == null) {
        final base = asMap(rirPlan['week1']);
        if (base != null) rirPlan[wk] = deepCopyMap(base);
      }
      applyRirLeaf(rirPlan, wk, c.session, c.set, c.rir);
    }
  }

  static void _propagateRepInstance(
    Map<String, dynamic> repTargets,
    RepTargetChange c,
    WeekScope scope,
    int totalWeeks,
  ) {
    if (scope == WeekScope.signature) {
      // min/max written into repRange (block-scoped).
      final rr = asMap(repTargets['repRange']) ?? <String, dynamic>{};
      final iv = int.tryParse((c.value ?? '').trim());
      if (iv != null) {
        rr[c.key] = iv;
      } else if (c.value == null || c.value!.trim().isEmpty) {
        rr.remove(c.key);
      }
      repTargets['repRange'] = rr;
      return;
    }
    if (scope == WeekScope.template) {
      applyRepInstance(repTargets, 'week1', c.key, c.value);
      return;
    }
    final weeks = totalWeeks < 1 ? 1 : totalWeeks;
    for (int w = 1; w <= weeks; w++) {
      final wk = 'week$w';
      if ((c.value ?? '').isNotEmpty && repTargets[wk] == null) {
        final base = asMap(repTargets['week1']);
        if (base != null) repTargets[wk] = deepCopyMap(base);
      }
      applyRepInstance(repTargets, wk, c.key, c.value);
    }
  }

  /// Applies [patch] onto a deep copy of the complete latest server object
  /// [latest] and returns the merged result. Untouched and unknown keys are
  /// always preserved; a partial nested map can never replace a complete one.
  static Map<String, dynamic> applyPatch(
    Map<String, dynamic> latest,
    ExerciseSettingsPatch patch,
  ) {
    final result = deepCopyMap(latest);

    // Scalars.
    patch.scalarChanges.forEach((k, v) => result[k] = v);
    for (final k in patch.clearedScalars) {
      result.remove(k);
    }

    // Increments — merge only changed sub-keys, preserving siblings.
    if (patch.incrementChanges.isNotEmpty) {
      final inc = asMap(result['increments']) ?? <String, dynamic>{};
      patch.incrementChanges.forEach((k, v) {
        if (v == null) {
          inc.remove(k);
        } else {
          inc[k] = v;
        }
      });
      result['increments'] = inc;
    }

    // Resolve effective models AFTER scalar changes (model may change in the
    // same save) so propagation routing is correct.
    final repModel = (patch.scalarChanges['periodizationModel'] as String?) ??
        result['periodizationModel'] as String?;
    final rirModel = (patch.scalarChanges['rirModel'] as String?) ??
        result['rirModel'] as String?;

    if (patch.repTargetChanges.isNotEmpty) {
      final rt = asMap(result['repTargets']) ?? <String, dynamic>{};
      final scope = repTargetScope(repModel);
      for (final c in patch.repTargetChanges) {
        _propagateRepInstance(rt, c, scope, patch.totalBlockWeeks);
      }
      result['repTargets'] = rt;
    }

    if (patch.rirChanges.isNotEmpty) {
      final rp = asMap(result['rirPlan']) ?? <String, dynamic>{};
      final scope = rirScope(rirModel);
      for (final c in patch.rirChanges) {
        _propagateRir(rp, c, scope, patch.totalBlockWeeks);
      }
      result['rirPlan'] = rp;
    }

    return result;
  }

  // ── Conservative sparse-shadow repair ───────────────────────────────────────

  /// Coverage of an RIR week map = the set of 'session/set' coordinates that
  /// carry an `rir` leaf.
  static Set<String> rirCoverage(Map<String, dynamic> week) {
    final out = <String>{};
    week.forEach((sessionKey, sessionVal) {
      if (!sessionKey.startsWith('session')) return;
      final sess = asMap(sessionVal);
      if (sess == null) return;
      sess.forEach((setKey, setVal) {
        if (!setKey.startsWith('set')) return;
        final st = asMap(setVal);
        if (st != null && st.containsKey('rir')) {
          out.add('$sessionKey/$setKey');
        }
      });
    });
    return out;
  }

  static Set<String> repCoverage(Map<String, dynamic> week) =>
      week.keys.where((k) => k.startsWith('instance')).toSet();

  /// Repairs sparse `weekN` (N>1) shadows in [rirPlan] relative to a complete
  /// `week1` template. Returns true if anything changed.
  ///
  /// A `weekN` is a *sparse shadow* only when it is a STRICT SUBSET of week1's
  /// coverage (it lacks coords week1 has, and introduces none of its own).
  /// A complete or divergent (custom) `weekN` is left untouched — repair is
  /// structural, never value-based, so manually edited values are preserved.
  static bool repairRirShadows(Map<String, dynamic> rirPlan, WeekScope scope) {
    final week1 = asMap(rirPlan['week1']);
    if (week1 == null) return false;
    final base = rirCoverage(week1);
    if (base.isEmpty) return false;

    var changed = false;
    for (final key in rirPlan.keys.toList()) {
      if (key == 'week1' || !key.startsWith('week')) continue;
      final wk = asMap(rirPlan[key]);
      if (wk == null) continue;
      final cov = rirCoverage(wk);
      final isStrictSubset =
          cov.length < base.length && cov.every(base.contains);
      if (!isStrictSubset) continue; // complete or custom → leave alone

      if (scope == WeekScope.template) {
        // Template contract: weekN must not exist. Remove the shadow so reads
        // fall back to the complete week1 template.
        rirPlan.remove(key);
        changed = true;
      } else {
        // Per-week: fill only the genuinely missing leaves from week1.
        for (final coord in base) {
          if (cov.contains(coord)) continue;
          final parts = coord.split('/');
          final src = asMap(asMap(week1[parts[0]])?[parts[1]]);
          if (src == null) continue;
          final sess = asMap(wk[parts[0]]) ?? <String, dynamic>{};
          sess[parts[1]] = deepCopyMap(src);
          wk[parts[0]] = sess;
          changed = true;
        }
        rirPlan[key] = wk;
      }
    }
    return changed;
  }

  /// Repairs sparse `weekN` rep-target shadows relative to a complete `week1`.
  /// Skipped entirely for DUP Signature (handled via repRange).
  static bool repairRepShadows(
      Map<String, dynamic> repTargets, WeekScope scope) {
    if (scope == WeekScope.signature) return false;
    final week1 = asMap(repTargets['week1']);
    if (week1 == null) return false;
    final base = repCoverage(week1);
    if (base.isEmpty) return false;

    var changed = false;
    for (final key in repTargets.keys.toList()) {
      if (key == 'week1' || !key.startsWith('week')) continue;
      final wk = asMap(repTargets[key]);
      if (wk == null) continue;
      final cov = repCoverage(wk);
      final isStrictSubset =
          cov.length < base.length && cov.every(base.contains);
      if (!isStrictSubset) continue;

      if (scope == WeekScope.template) {
        repTargets.remove(key);
        changed = true;
      } else {
        for (final inst in base) {
          if (cov.contains(inst)) continue;
          wk[inst] = week1[inst];
          changed = true;
        }
        repTargets[key] = wk;
      }
    }
    return changed;
  }

  /// Repairs both rirPlan and repTargets sparse shadows on a deep copy of
  /// [settings]. Returns the (possibly repaired) copy and whether it changed.
  /// Conservative: only removes proven sparse shadows or fills genuinely
  /// missing leaves; never overwrites present values, never copies defaults
  /// over existing data, never normalises custom values.
  static (Map<String, dynamic> repaired, bool changed) repairShadows(
      Map<String, dynamic> settings) {
    final result = deepCopyMap(settings);
    var changed = false;

    final repModel = result['periodizationModel'] as String?;
    final rirModel = result['rirModel'] as String?;

    final rp = asMap(result['rirPlan']);
    if (rp != null) {
      if (repairRirShadows(rp, rirScope(rirModel))) {
        result['rirPlan'] = rp;
        changed = true;
      }
    }

    final rt = asMap(result['repTargets']);
    if (rt != null) {
      if (repairRepShadows(rt, repTargetScope(repModel))) {
        result['repTargets'] = rt;
        changed = true;
      }
    }

    return (result, changed);
  }
}
