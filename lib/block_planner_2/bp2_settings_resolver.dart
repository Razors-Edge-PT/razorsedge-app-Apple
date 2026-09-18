/// Pure settings resolution for Block Planner 2.
///
/// Three layers are kept strictly apart:
///   1. [Bp2ExerciseDraft] — raw editor text keyed by field path (unsaved).
///   2. Canonical base — the persisted `exerciseSettings[exerciseId]` object,
///      healed through the canonical default system when incomplete.
///   3. Projection — `heal(applyPatch(base, patch(draft)))`, i.e. exactly what
///      the server-side merge will produce, used only for display.
///
/// Precedence therefore is: unsaved entry → persisted custom value →
/// exercise/model default → canonical global fallback (only where the existing
/// system defines one — e.g. the 3-set fallback WES2 already uses).
library;

import '../block_exercise_defaults_repository.dart';
import '../exercise_model_registry.dart';
import '../settings_merge.dart';
import '../wes2_exercise_settings_patch.dart';

// ── Field keys ────────────────────────────────────────────────────────────────

class Bp2Field {
  Bp2Field._();
  static const periodizationModel = 'periodizationModel';
  static const rirModel = 'rirModel';
  static const progressionModel = 'progressionModel';
  static const weeklyFrequency = 'weeklyFrequency';
  static const defaultSets = 'defaultSets';
  static const showVelocityField = 'showVelocityField';
  static const incrementPrimary = 'increments.primary';
  static const incrementSecondary = 'increments.secondary';
  static const repMin = 'rep.min';
  static const repMax = 'rep.max';

  static String repInstance(int session) => 'rep.instance$session';
  static String rir(int session, int set) => 'rir.session$session.set$set';

  static const _repInstancePrefix = 'rep.instance';
  static const _rirPrefix = 'rir.session';

  static int? repInstanceNumber(String key) =>
      key.startsWith(_repInstancePrefix)
          ? int.tryParse(key.substring(_repInstancePrefix.length))
          : null;

  /// `(session, set)` for an RIR key, else null.
  static (int, int)? rirCoords(String key) {
    if (!key.startsWith(_rirPrefix)) return null;
    final rest = key.substring(_rirPrefix.length); // "N.setM"
    final dot = rest.indexOf('.set');
    if (dot < 0) return null;
    final s = int.tryParse(rest.substring(0, dot));
    final st = int.tryParse(rest.substring(dot + 4));
    if (s == null || st == null) return null;
    return (s, st);
  }
}

// ── Draft ─────────────────────────────────────────────────────────────────────

/// Immutable map of unsaved raw edits for one exercise. A `null` value means
/// the user cleared the field. Keys not present were never touched.
class Bp2ExerciseDraft {
  final Map<String, String?> edits;
  const Bp2ExerciseDraft([this.edits = const {}]);

  static const empty = Bp2ExerciseDraft();

  bool get isEmpty => edits.isEmpty;
  bool has(String key) => edits.containsKey(key);
  String? operator [](String key) => edits[key];

  Bp2ExerciseDraft withEdit(String key, String? value) =>
      Bp2ExerciseDraft({...edits, key: value});

  Bp2ExerciseDraft without(Iterable<String> keys) {
    final m = Map<String, String?>.from(edits);
    for (final k in keys) {
      m.remove(k);
    }
    return Bp2ExerciseDraft(m);
  }

  Map<String, dynamic> toJson() => Map<String, dynamic>.from(edits);
  factory Bp2ExerciseDraft.fromJson(Map<String, dynamic> m) =>
      Bp2ExerciseDraft(m.map((k, v) => MapEntry(k, v?.toString())));
}

// ── Resolved view ─────────────────────────────────────────────────────────────

class Bp2SessionTarget {
  final int session; // 1-based
  final int? reps;
  final int sets;
  final List<String> rir; // one entry per set, '' when unknown
  const Bp2SessionTarget({
    required this.session,
    required this.reps,
    required this.sets,
    required this.rir,
  });
}

class Bp2ResolvedSettings {
  final String? periodizationModel;
  final String? rirModel;
  final String? progressionModel;
  final int? weeklyFrequency;
  final int? defaultSets;
  final bool showVelocity;
  final String incrementPrimary;
  final String incrementSecondary;
  final RepTargetShape repShape;
  final int? repMin;
  final int? repMax;
  final List<Bp2SessionTarget> sessions;

  /// The projected canonical object (display only — never persisted as-is).
  final Map<String, dynamic> projected;

  const Bp2ResolvedSettings({
    required this.periodizationModel,
    required this.rirModel,
    required this.progressionModel,
    required this.weeklyFrequency,
    required this.defaultSets,
    required this.showVelocity,
    required this.incrementPrimary,
    required this.incrementSecondary,
    required this.repShape,
    required this.repMin,
    required this.repMax,
    required this.sessions,
    required this.projected,
  });

  String get repSummary {
    if (repShape == RepTargetShape.repRange) {
      final ds = defaultSets ?? Bp2SettingsResolver.fallbackSets;
      if (repMin == null || repMax == null) return 'Not set';
      return '$repMin–$repMax reps × $ds';
    }
    if (sessions.isEmpty) return 'Not set';
    return sessions
        .map((s) => '${s.reps?.toString() ?? '–'}×${s.sets}')
        .join(', ');
  }

  String get rirSummary {
    if (sessions.isEmpty) return 'Not set';
    return sessions
        .map((s) => s.rir.map((r) => r.isEmpty ? '–' : r).join('/'))
        .join(' · ');
  }
}

class Bp2ValidationError {
  final String field;
  final String message;
  const Bp2ValidationError(this.field, this.message);
  @override
  String toString() => '$field: $message';
}

// ── Resolver ──────────────────────────────────────────────────────────────────

class Bp2SettingsResolver {
  Bp2SettingsResolver._();

  /// Canonical global fallback already used by WES2 when neither a rep string
  /// nor `defaultSets` carries a set count.
  static const int fallbackSets = 3;
  static const int maxSets = 10;
  static const int minWeeklyFrequency = 1;
  static const int maxWeeklyFrequency = SettingsMerge.maxWeeklyFrequency;

  static Map<String, dynamic>? _asMap(dynamic v) => SettingsMerge.asMap(v);

  /// Canonical base object: the persisted object when complete, otherwise the
  /// persisted fragments projected over the tiered defaults (same routine
  /// `ensureExerciseDefaults` uses), then week1 RIR healed.
  static Map<String, dynamic> canonicalBase(
    Map<String, dynamic>? persisted,
    Map<String, dynamic> defaultsPayload,
  ) {
    Map<String, dynamic> base;
    if (BlockExerciseDefaultsRepository.isSettingsUsable(persisted)) {
      base = SettingsMerge.deepCopyMap(persisted!);
    } else if (defaultsPayload.isEmpty) {
      base = SettingsMerge.deepCopyMap(persisted ?? const {});
    } else {
      base = BlockExerciseDefaultsRepository.projectHealedSettings(
        persisted ?? const {},
        SettingsMerge.deepCopyMap(defaultsPayload),
      );
    }
    final healed = BlockExerciseDefaultsRepository.healWeek1RirPlan(base);
    if (healed != null) base['rirPlan'] = healed;
    return base;
  }

  // ── Reading canonical values ──────────────────────────────────────────────

  static int? intOf(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString().trim());
  }

  static double? doubleOf(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim().replaceAll(',', '.'));
  }

  /// Compact numeric text: `2.5` stays `2.5`, `2.0` becomes `2`.
  static String compactNumber(double d) {
    if (d == d.roundToDouble()) return d.toInt().toString();
    var s = d.toStringAsFixed(3);
    while (s.endsWith('0')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static String numberText(dynamic v) {
    final d = doubleOf(v);
    return d == null ? (v?.toString() ?? '') : compactNumber(d);
  }

  /// `'9 x 3'` → `(9, 3)`; either side may be null when absent.
  static (int?, int?) parseRepString(String? raw) {
    if (raw == null) return (null, null);
    final s = raw.trim();
    if (s.isEmpty) return (null, null);
    final repsMatch = RegExp(r'^(\d+)').firstMatch(s);
    final setsMatch = RegExp(r'[xX×]\s*(\d+)').firstMatch(s);
    return (
      repsMatch == null ? null : int.tryParse(repsMatch.group(1)!),
      setsMatch == null ? null : int.tryParse(setsMatch.group(1)!),
    );
  }

  static String repString(int reps, int sets) => '$reps x $sets';

  static Map<String, dynamic>? _repWeek1(Map<String, dynamic> settings) =>
      _asMap(_asMap(settings['repTargets'])?['week1']);

  static Map<String, dynamic>? _rirWeek1(Map<String, dynamic> settings) =>
      _asMap(_asMap(settings['rirPlan'])?['week1']);

  static int? _weeklyFrequency(Map<String, dynamic> settings) {
    final wf = intOf(settings['weeklyFrequency']);
    return (wf == null || wf <= 0) ? null : wf;
  }

  /// Planned set count for a session — WES2 rule: `N x S` string → defaultSets
  /// → 3.
  static int setCountForSession(Map<String, dynamic> settings, int session) {
    final shape = ExerciseModelRegistry.repTargetShape(
        settings['periodizationModel'] as String?);
    if (shape == RepTargetShape.perSession) {
      final (_, sets) =
          parseRepString(_repWeek1(settings)?['instance$session']?.toString());
      if (sets != null && sets > 0) return sets.clamp(1, maxSets);
    }
    final ds = intOf(settings['defaultSets']);
    if (ds != null && ds > 0) return ds.clamp(1, maxSets);
    return fallbackSets;
  }

  // ── Draft → patch ─────────────────────────────────────────────────────────

  /// Builds the explicit dirty-field patch for [draft] relative to [base].
  /// Fields whose raw text equals the base value are dropped so an untouched
  /// field (or one edited back to its original) never produces a write.
  static ExerciseSettingsPatch buildPatch({
    required Map<String, dynamic> base,
    required Bp2ExerciseDraft draft,
    required int totalBlockWeeks,
  }) {
    final scalars = <String, dynamic>{};
    final cleared = <String>{};
    final inc = <String, dynamic>{};
    final reps = <RepTargetChange>[];
    final rirs = <RirChange>[];

    final baseInc = _asMap(base['increments']) ?? const {};
    final baseRep = _repWeek1(base) ?? const {};
    final baseRange =
        _asMap(_asMap(base['repTargets'])?['repRange']) ?? const {};
    final baseRir = _rirWeek1(base) ?? const {};

    draft.edits.forEach((key, raw) {
      final text = raw?.trim() ?? '';
      switch (key) {
        case Bp2Field.periodizationModel:
        case Bp2Field.rirModel:
        case Bp2Field.progressionModel:
          if (text.isNotEmpty && text != (base[key] as String?)) {
            scalars[key] = text;
          }
          return;
        case Bp2Field.weeklyFrequency:
        case Bp2Field.defaultSets:
          final v = int.tryParse(text);
          if (v != null && v != intOf(base[key])) scalars[key] = v;
          return;
        case Bp2Field.showVelocityField:
          final v = text == 'true';
          final current = base[key];
          if (current is! bool || current != v) scalars[key] = v;
          return;
        case Bp2Field.incrementPrimary:
        case Bp2Field.incrementSecondary:
          final sub =
              key == Bp2Field.incrementPrimary ? 'primary' : 'secondary';
          final parsed = text.isEmpty ? null : doubleOf(text);
          if (text.isNotEmpty && parsed == null) return; // invalid → validation
          if (numberText(parsed) != numberText(baseInc[sub])) {
            inc[sub] = parsed;
          }
          return;
        case Bp2Field.repMin:
        case Bp2Field.repMax:
          final sub = key == Bp2Field.repMin ? 'min' : 'max';
          final v = text.isEmpty ? null : int.tryParse(text);
          if (text.isNotEmpty && v == null) return;
          if (v != intOf(baseRange[sub])) {
            reps.add(RepTargetChange(sub, v?.toString()));
          }
          return;
      }
      final inst = Bp2Field.repInstanceNumber(key);
      if (inst != null) {
        final baseText = baseRep['instance$inst']?.toString().trim() ?? '';
        if (text != baseText) {
          reps.add(
              RepTargetChange('instance$inst', text.isEmpty ? null : text));
        }
        return;
      }
      final coords = Bp2Field.rirCoords(key);
      if (coords != null) {
        final (s, st) = coords;
        final baseCell = _asMap(_asMap(baseRir['session$s'])?['set$st'])?['rir']
                ?.toString()
                .trim() ??
            '';
        final normalized = text.isEmpty ? '' : numberText(text);
        if (text.isNotEmpty && doubleOf(text) == null) return;
        if (normalized != numberText(baseCell) ||
            (text.isEmpty) != (baseCell.isEmpty)) {
          rirs.add(RirChange(
              session: 'session$s',
              set: 'set$st',
              rir: normalized.isEmpty ? null : normalized));
        }
      }
    });

    return ExerciseSettingsPatch(
      scalarChanges: scalars,
      clearedScalars: cleared,
      incrementChanges: inc,
      repTargetChanges: reps,
      rirChanges: rirs,
      totalBlockWeeks: totalBlockWeeks,
    );
  }

  /// `heal(applyPatch(base, patch))` — the object the server merge will store.
  static Map<String, dynamic> project({
    required Map<String, dynamic> base,
    required Bp2ExerciseDraft draft,
    required int totalBlockWeeks,
  }) {
    final patch =
        buildPatch(base: base, draft: draft, totalBlockWeeks: totalBlockWeeks);
    final merged = patch.isEmpty
        ? SettingsMerge.deepCopyMap(base)
        : SettingsMerge.applyPatch(base, patch);
    return healed(merged);
  }

  /// Fills only genuinely missing week1 RIR sets from the canonical matrix.
  static Map<String, dynamic> healed(Map<String, dynamic> settings) {
    final h = BlockExerciseDefaultsRepository.healWeek1RirPlan(settings);
    if (h != null) settings['rirPlan'] = h;
    return settings;
  }

  // ── Resolve for display ───────────────────────────────────────────────────

  static Bp2ResolvedSettings resolve({
    required String exerciseId,
    required Map<String, dynamic> base,
    required Bp2ExerciseDraft draft,
    required int totalBlockWeeks,
  }) {
    final p =
        project(base: base, draft: draft, totalBlockWeeks: totalBlockWeeks);
    final repModel = p['periodizationModel'] as String?;
    final shape = ExerciseModelRegistry.repTargetShape(repModel);
    final wf = _weeklyFrequency(p);
    final inc = _asMap(p['increments']) ?? const {};
    final range = _asMap(_asMap(p['repTargets'])?['repRange']) ?? const {};

    // Raw text wins for the field the user is typing in, so a half-typed
    // "2." is never re-rendered as "2" underneath them.
    String text(String key, String canonical) =>
        draft.has(key) ? (draft[key] ?? '') : canonical;

    final showVelocity = draft.has(Bp2Field.showVelocityField)
        ? draft[Bp2Field.showVelocityField] == 'true'
        : (p['showVelocityField'] is bool
            ? p['showVelocityField'] as bool
            : ExerciseModelRegistry.defaultShowVelocity(exerciseId));

    final sessions = <Bp2SessionTarget>[];
    final repWeek1 = _repWeek1(p) ?? const {};
    final rirWeek1 = _rirWeek1(p) ?? const {};
    for (var s = 1; s <= (wf ?? 0); s++) {
      int? reps;
      int sets;
      if (shape == RepTargetShape.perSession) {
        final rawText = text(
            Bp2Field.repInstance(s), repWeek1['instance$s']?.toString() ?? '');
        final (r, st) = parseRepString(rawText);
        reps = r;
        sets = st != null && st > 0
            ? st.clamp(1, maxSets)
            : setCountForSession(p, s);
      } else {
        reps = null;
        sets = setCountForSession(p, s);
      }
      final sess = _asMap(rirWeek1['session$s']) ?? const {};
      final rir = <String>[];
      for (var st = 1; st <= sets; st++) {
        final cell = _asMap(sess['set$st'])?['rir'];
        rir.add(
            text(Bp2Field.rir(s, st), cell == null ? '' : numberText(cell)));
      }
      sessions
          .add(Bp2SessionTarget(session: s, reps: reps, sets: sets, rir: rir));
    }

    return Bp2ResolvedSettings(
      periodizationModel: ExerciseModelRegistry.knownOrNull(
          repModel, ExerciseModelRegistry.repModels),
      rirModel: ExerciseModelRegistry.knownOrNull(
          p['rirModel'] as String?, ExerciseModelRegistry.rirModels),
      progressionModel: ExerciseModelRegistry.knownOrNull(
          p['progressionModel'] as String?,
          ExerciseModelRegistry.progressionModels),
      weeklyFrequency: draft.has(Bp2Field.weeklyFrequency)
          ? int.tryParse(draft[Bp2Field.weeklyFrequency] ?? '')
          : wf,
      defaultSets: intOf(p['defaultSets']),
      showVelocity: showVelocity,
      incrementPrimary:
          text(Bp2Field.incrementPrimary, numberText(inc['primary'])),
      incrementSecondary:
          text(Bp2Field.incrementSecondary, numberText(inc['secondary'])),
      repShape: shape,
      repMin: intOf(text(Bp2Field.repMin, range['min']?.toString() ?? '')),
      repMax: intOf(text(Bp2Field.repMax, range['max']?.toString() ?? '')),
      sessions: sessions,
      projected: p,
    );
  }

  // ── Validation ────────────────────────────────────────────────────────────

  /// Validates the raw draft text (visible or not). Empty list = valid.
  static List<Bp2ValidationError> validate(Bp2ExerciseDraft draft) {
    final errors = <Bp2ValidationError>[];
    draft.edits.forEach((key, raw) {
      final text = raw?.trim() ?? '';
      if (text.isEmpty) return; // clearing is allowed everywhere WES2 allows it
      switch (key) {
        case Bp2Field.weeklyFrequency:
          final v = int.tryParse(text);
          if (v == null || v < minWeeklyFrequency || v > maxWeeklyFrequency) {
            errors.add(Bp2ValidationError(key,
                'Weekly frequency must be a whole number from $minWeeklyFrequency to $maxWeeklyFrequency.'));
          }
          return;
        case Bp2Field.defaultSets:
          final v = int.tryParse(text);
          if (v == null || v < 1 || v > maxSets) {
            errors.add(Bp2ValidationError(
                key, 'Set count must be a whole number from 1 to $maxSets.'));
          }
          return;
        case Bp2Field.incrementPrimary:
        case Bp2Field.incrementSecondary:
          final v = doubleOf(text);
          if (v == null || v <= 0) {
            errors.add(Bp2ValidationError(
                key, 'Increments must be a positive number.'));
          }
          return;
        case Bp2Field.repMin:
        case Bp2Field.repMax:
          final v = int.tryParse(text);
          if (v == null || v < 1) {
            errors.add(Bp2ValidationError(
                key, 'Reps must be a whole number of at least 1.'));
          }
          return;
      }
      if (Bp2Field.repInstanceNumber(key) != null) {
        final (r, s) = parseRepString(text);
        if (r == null || r < 1 || s == null || s < 1 || s > maxSets) {
          errors.add(Bp2ValidationError(
              key, 'Enter reps of at least 1 and sets from 1 to $maxSets.'));
        }
        return;
      }
      if (Bp2Field.rirCoords(key) != null) {
        final v = doubleOf(text);
        if (v == null || v < 0) {
          errors.add(
              Bp2ValidationError(key, 'RIR must be a number of 0 or more.'));
        }
      }
    });
    final min = int.tryParse(draft[Bp2Field.repMin] ?? '');
    final max = int.tryParse(draft[Bp2Field.repMax] ?? '');
    if (min != null && max != null && min >= max) {
      errors.add(const Bp2ValidationError(
          Bp2Field.repMax, 'Max reps must be greater than min reps.'));
    }
    return errors;
  }
}
