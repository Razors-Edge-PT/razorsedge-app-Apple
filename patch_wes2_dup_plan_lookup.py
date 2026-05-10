from pathlib import Path

p = Path("lib/WES2_hint_service.dart")
s = p.read_text(encoding="utf-8")

backup = Path(str(p) + ".bak_dup_plan_lookup")
backup.write_text(s, encoding="utf-8")

helper_marker = "  /// Computes Set 1 hints with full priority chain:"

helper = '''  /// Resolves exerciseSettings repTargets/rirPlan lookup keys.
  ///
  /// The calendar day index is not the same thing as a configured DUP
  /// microcycle instance/session. For DUP models, week1 is treated as the
  /// configured microcycle pattern and the session index is wrapped to the
  /// number of configured instance/session slots. This prevents valid
  /// instance1/instance2 data from being missed as instance3+ and falling
  /// back to default reps like 8.
  static ({int weekIndex, int sessionIndex}) _resolvePlanLookup({
    required Map<String, dynamic>? exSettings,
    required int weekIndex,
    required int sessionIndex,
  }) {
    if (exSettings == null) {
      return (weekIndex: weekIndex, sessionIndex: sessionIndex);
    }

    final model =
        (exSettings['periodizationModel'] as String? ?? '').toLowerCase();
    final isDup = model.contains('dup') || model.contains('undulating');

    if (!isDup) {
      return (weekIndex: weekIndex, sessionIndex: sessionIndex);
    }

    // WES2 spec: DUP week/exposure uses week1 as the microcycle pattern.
    final resolvedWeek = 0;
    final configuredSlots = _configuredPlanSlotCount(exSettings, resolvedWeek);

    if (configuredSlots <= 0) {
      return (weekIndex: resolvedWeek, sessionIndex: sessionIndex);
    }

    final safeSession =
        sessionIndex < 0 ? 0 : sessionIndex % configuredSlots;
    return (weekIndex: resolvedWeek, sessionIndex: safeSession);
  }

  static int _configuredPlanSlotCount(
    Map<String, dynamic> exSettings,
    int weekIndex,
  ) {
    final weekKey = 'week${weekIndex + 1}';
    var maxSlot = 0;

    final repTargets = exSettings['repTargets'];
    if (repTargets is Map) {
      final weekData = repTargets[weekKey];
      if (weekData is Map) {
        final n = _maxNumberedKey(weekData, 'instance');
        if (n > maxSlot) maxSlot = n;
      }
    }

    final rirPlan = exSettings['rirPlan'];
    if (rirPlan is Map) {
      final weekData = rirPlan[weekKey];
      if (weekData is Map) {
        final n = _maxNumberedKey(weekData, 'session');
        if (n > maxSlot) maxSlot = n;
      }
    }

    return maxSlot;
  }

  static int _maxNumberedKey(Map<dynamic, dynamic> map, String prefix) {
    var maxFound = 0;
    for (final rawKey in map.keys) {
      final key = rawKey.toString();
      if (!key.startsWith(prefix)) continue;
      final suffix = key.substring(prefix.length);
      final parsed = int.tryParse(suffix);
      if (parsed != null && parsed > maxFound) {
        maxFound = parsed;
      }
    }
    return maxFound;
  }

'''

if "_resolvePlanLookup" not in s:
    if helper_marker not in s:
        raise SystemExit("FAILED: helper insertion marker not found.")
    s = s.replace(helper_marker, helper + helper_marker, 1)

old = '''    // Build a padded sets list that covers at least setCount slots.
    // WES2-manual rows are created with setCount > 0 but sets: const [],
    // so we must not bail out on sets.isEmpty.
    final effectiveCount = row.setCount > 0 ? row.setCount : 3;
    final padded = List<Wes2SetState>.generate(effectiveCount, (i) {
      return i < row.sets.length ? row.sets[i] : Wes2SetState(setIndex: i);
    });

    final newSets = List<Wes2SetState>.from(padded);
    newSets[0] = _computeSet1Hints(
      row: row,
      set: padded[0],
      weekIndex: weekIndex,
      sessionIndex: sessionIndex,
      date: date,
      uid: uid,
    );

    // Phase 21D: cascade Set 2+ hints from the immediately prior resolved set.
    final exSettings = exerciseSettings[row.exerciseId] as Map<String, dynamic>?;
    for (int i = 1; i < effectiveCount; i++) {
      newSets[i] = _computeSetNHints(
        row: row,
        set: newSets[i],
        prevSet: newSets[i - 1],
        setIdx: i,
        exSettings: exSettings,
        weekIndex: weekIndex,
        sessionIndex: sessionIndex,
      );
    }

    return row.copyWith(sets: newSets, setCount: effectiveCount);
'''

new = '''    // Build a padded sets list that covers at least setCount slots.
    // WES2-manual rows are created with setCount > 0 but sets: const [],
    // so we must not bail out on sets.isEmpty.
    final effectiveCount = row.setCount > 0 ? row.setCount : 3;
    final padded = List<Wes2SetState>.generate(effectiveCount, (i) {
      return i < row.sets.length ? row.sets[i] : Wes2SetState(setIndex: i);
    });

    final exSettings = exerciseSettings[row.exerciseId] as Map<String, dynamic>?;
    final planLookup = _resolvePlanLookup(
      exSettings: exSettings,
      weekIndex: weekIndex,
      sessionIndex: sessionIndex,
    );

    final newSets = List<Wes2SetState>.from(padded);
    newSets[0] = _computeSet1Hints(
      row: row,
      set: padded[0],
      weekIndex: planLookup.weekIndex,
      sessionIndex: planLookup.sessionIndex,
      date: date,
      uid: uid,
    );

    // Phase 21D: cascade Set 2+ hints from the immediately prior resolved set.
    for (int i = 1; i < effectiveCount; i++) {
      newSets[i] = _computeSetNHints(
        row: row,
        set: newSets[i],
        prevSet: newSets[i - 1],
        setIdx: i,
        exSettings: exSettings,
        weekIndex: planLookup.weekIndex,
        sessionIndex: planLookup.sessionIndex,
      );
    }

    return row.copyWith(sets: newSets, setCount: effectiveCount);
'''

if old in s:
    s = s.replace(old, new, 1)
elif "final planLookup = _resolvePlanLookup(" in s:
    print("computeRowHints already appears patched; no block replacement needed.")
else:
    raise SystemExit("FAILED: exact computeRowHints block not found; file may differ from uploaded version.")

p.write_text(s, encoding="utf-8")
print("SUCCESS: patched lib/WES2_hint_service.dart")
print(f"Backup written to {backup}")
