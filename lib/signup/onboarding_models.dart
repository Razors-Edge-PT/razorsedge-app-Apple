/// Page 2 ("Set your training priorities") data: the persisted answer models,
/// the mutable form state behind every editable control, and the immutable
/// submission that is written to Firestore.
///
/// The form state lives outside the widget so that, during signup, it can be
/// owned by the route-independent signup draft (see signup_draft.dart). Back,
/// system/predictive Back, a username collision or an auth-driven rebuild can
/// then destroy the Page 2 route without losing a single answer: the next
/// Page 2 instance binds to the same object and shows exactly what was there.
///
/// Firestore shapes are unchanged; [OnboardingSubmission] produces precisely
/// the fields the screen has always written.
library;

/// Weights-training experience radio.
enum TrainingExperience { never, lt6mo, oneYear, twoPlus }

class BestEffort {
  final String liftKey; // e.g. 'bench_barbell', 'bench_db', 'squat', 'leg_press', 'chinup', 'lat_pulldown', 'deadlift'
  final double? weightKg;
  final int? reps;
  const BestEffort({this.liftKey = '', this.weightKg, this.reps});

  Map<String, dynamic> toJson() => {
        'liftKey': liftKey,
        'weightKg': weightKg,
        'reps': reps,
      };

  factory BestEffort.fromJson(Map<String, dynamic> j) => BestEffort(
        liftKey: (j['liftKey'] ?? '') as String,
        weightKg: (j['weightKg'] as num?)?.toDouble(),
        reps: (j['reps'] as num?)?.toInt(),
      );
}

class OnboardingAnswers {
  final List<String>? goalsRanked;
  final List<String>? bodyFocus;
  final Map<String, int>? painNow;
  final List<String>? injuries;
  final TrainingExperience? experience;
  final List<BestEffort>? bestEfforts;
  final int? minTrainingDaysPerWeek; // existing
  final int? trainingEffort;
  final DateTime? createdAt;
  final String? version;

  const OnboardingAnswers({
    this.goalsRanked,
    this.bodyFocus,
    this.painNow,
    this.injuries,
    this.experience,
    this.bestEfforts,
    this.minTrainingDaysPerWeek,
    this.trainingEffort,
    this.createdAt,
    this.version,
  });

  Map<String, dynamic> toJson() => {
        'goalsRanked': goalsRanked,
        'bodyFocus': bodyFocus,
        'painNow': painNow,
        'injuries': injuries,
        'experience': experience?.name,
        'bestEfforts': bestEfforts?.map((b) => b.toJson()).toList(),
        'minTrainingDaysPerWeek': minTrainingDaysPerWeek,
        'trainingEffort': trainingEffort,
        'createdAt': (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
        'version': version ?? 'v1',
      };

  factory OnboardingAnswers.fromJson(Map<String, dynamic> j) =>
      OnboardingAnswers(
        goalsRanked:
            (j['goalsRanked'] as List?)?.map((e) => e.toString()).toList(),
        bodyFocus: (j['bodyFocus'] as List?)?.map((e) => e.toString()).toList(),
        painNow: (j['painNow'] as Map?)
            ?.map((k, v) => MapEntry(k.toString(), (v as num).toInt())),
        injuries: (j['injuries'] as List?)?.map((e) => e.toString()).toList(),
        experience: experienceFromString(j['experience']),
        bestEfforts: (j['bestEfforts'] as List?)
            ?.map((e) => BestEffort.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        minTrainingDaysPerWeek: (j['minTrainingDaysPerWeek'] as num?)?.toInt(),
        trainingEffort: (j['trainingEffort'] as num?)?.toInt(),
        createdAt: (j['createdAt'] != null)
            ? DateTime.tryParse(j['createdAt'].toString())
            : null,
        version: j['version']?.toString(),
      );

  static TrainingExperience? experienceFromString(dynamic v) {
    final s = v?.toString();
    if (s == null) return null;
    return TrainingExperience.values.firstWhere(
      (e) => e.name == s,
      orElse: () => TrainingExperience.never,
    );
  }
}

/// Default goal order shown before the member ranks anything.
const List<String> kDefaultOnboardingGoals = <String>[
  'Get stronger',
  'Build more muscle',
  'Get fitter',
  'Powerlifting',
  'Get leaner',
  'Feel healthier / move better',
  'Tone and shape',
  'Defeat my gym nemesis',
  'Power-Building',
  'Bench Press Specialist',
];

/// Keys of the best-effort text fields. The rows are currently hidden in the
/// UI, but their state is carried so re-enabling them cannot lose input.
class BestEffortField {
  static const bench = 'bench';
  static const squat = 'squat';
  static const pull = 'pull';
  static const dead = 'dead';
  static const benchWeight = 'benchWeight';
  static const benchReps = 'benchReps';
  static const squatWeight = 'squatWeight';
  static const squatReps = 'squatReps';
  static const pullWeight = 'pullWeight';
  static const pullReps = 'pullReps';
  static const deadWeight = 'deadWeight';
  static const deadReps = 'deadReps';

  static const all = <String>[
    bench, squat, pull, dead,
    benchWeight, benchReps, squatWeight, squatReps,
    pullWeight, pullReps, deadWeight, deadReps,
  ];
}

/// Every editable value on Page 2.
///
/// `null` always means "not answered yet"; an explicit choice — a body part
/// cycled back to level 0, the dumbbell "None" option (-1), an empty
/// equipment list — is stored as that value, never collapsed to null.
class OnboardingFormData {
  OnboardingFormData();

  /// Ranked goals (drag order) and the "not important" bin.
  List<String> goals = List<String>.of(kDefaultOnboardingGoals);
  List<String> notImportantGoals = <String>[];

  /// Body focus: legacy checklist (written as `bodyFocus`), per-parent
  /// emphasis 0..3, the More specific toggle and per-child emphasis 0..3.
  Set<String> bodyFocus = <String>{};
  Map<String, int> bodyFocusLevel = <String, int>{};
  bool moreSpecific = false;
  Map<String, Map<String, int>> childFocusLevel = <String, Map<String, int>>{};

  /// Injuries, pain-now slider (1..10) per injury, shoulder/elbow detail.
  Set<String> injuries = <String>{};
  Map<String, double> painSlider = <String, double>{};
  bool shoulderPainOverhead = false;
  bool shoulderPainFront = false;
  bool elbowPainInside = false;
  bool elbowPainOutside = false;

  /// Experience and personal-training history (0..3).
  TrainingExperience? experience;
  int? ptHistory;

  /// Best-effort lift variants and raw text input.
  String benchVariant = 'Bench Press';
  String squatVariant = 'Back Squat';
  String pullVariant = 'Lat Pull Down, Supinated';
  String deadVariant = 'Deadlift';
  Map<String, String> bestEffortText = <String, String>{
    for (final k in BestEffortField.all) k: '',
  };

  /// Environment, selected equipment and the dumbbell maximum (-1 = None).
  String? env;
  Set<String> equipSelected = <String>{};
  int? dbMax;

  /// Weekly frequency (2..7) and effort choice (1..4).
  int? minTrainingDays;
  int? trainingEffort;

  /// Fills this form, in place, from a stored fitness_onboarding document
  /// (used when resuming an unfinished signup). Keys that are absent leave
  /// the current value alone.
  void loadFromFirestore(Map<String, dynamic> j) {
    List<String>? strings(Object? v) =>
        v is List ? v.map((e) => e.toString()).toList() : null;
    Map<String, int>? ints(Object? v) => v is Map
        ? v.map((k, x) => MapEntry(k.toString(), (x as num).toInt()))
        : null;

    final g = strings(j['goalsRanked']);
    if (g != null && g.isNotEmpty) goals = g;
    notImportantGoals = strings(j['goalsNotImportant']) ?? notImportantGoals;
    final bf = strings(j['bodyFocus']);
    if (bf != null) bodyFocus = bf.toSet();
    final lvl = ints(j['bodyFocusLevel']);
    if (lvl != null) bodyFocusLevel = lvl;
    final kids = j['bodyFocusChildren'];
    if (kids is Map) {
      childFocusLevel = kids.map((k, v) => MapEntry(k.toString(), ints(v) ?? <String, int>{}));
      moreSpecific = childFocusLevel.isNotEmpty;
    }
    final inj = strings(j['injuries']);
    if (inj != null) injuries = inj.toSet();
    final pain = j['painNow'];
    if (pain is Map) {
      painSlider = pain.map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
    }
    bool? flag(String k) => j[k] is bool ? j[k] as bool : null;
    shoulderPainOverhead = flag('shoulderPainOverhead') ?? shoulderPainOverhead;
    shoulderPainFront = flag('shoulderPainFront') ?? shoulderPainFront;
    elbowPainInside = flag('elbowPainInside') ?? elbowPainInside;
    elbowPainOutside = flag('elbowPainOutside') ?? elbowPainOutside;
    experience = OnboardingAnswers.experienceFromString(j['experience']) ?? experience;
    final pt = j['ptHistory'];
    if (pt is Map && pt['index'] is num) ptHistory = (pt['index'] as num).toInt();
    final freq = (j['weeklyFrequency'] ?? j['minTrainingDaysPerWeek']);
    if (freq is num) minTrainingDays = freq.toInt();
    if (j['trainingEffort'] is num) trainingEffort = (j['trainingEffort'] as num).toInt();
    if (j['environment'] is String) env = j['environment'] as String;
    final equip = j['equipment'];
    if (equip is Map) {
      equipSelected = (strings(equip['items']) ?? const <String>[]).toSet();
      if (equip['dumbbellsMax'] is num) dbMax = (equip['dumbbellsMax'] as num).toInt();
    }
  }

  /// A fully independent copy: no collection is shared with this instance.
  OnboardingFormData deepCopy() {
    final c = OnboardingFormData()
      ..goals = List<String>.of(goals)
      ..notImportantGoals = List<String>.of(notImportantGoals)
      ..bodyFocus = Set<String>.of(bodyFocus)
      ..bodyFocusLevel = Map<String, int>.of(bodyFocusLevel)
      ..moreSpecific = moreSpecific
      ..childFocusLevel = childFocusLevel
          .map((k, v) => MapEntry(k, Map<String, int>.of(v)))
      ..injuries = Set<String>.of(injuries)
      ..painSlider = Map<String, double>.of(painSlider)
      ..shoulderPainOverhead = shoulderPainOverhead
      ..shoulderPainFront = shoulderPainFront
      ..elbowPainInside = elbowPainInside
      ..elbowPainOutside = elbowPainOutside
      ..experience = experience
      ..ptHistory = ptHistory
      ..benchVariant = benchVariant
      ..squatVariant = squatVariant
      ..pullVariant = pullVariant
      ..deadVariant = deadVariant
      ..bestEffortText = Map<String, String>.of(bestEffortText)
      ..env = env
      ..equipSelected = Set<String>.of(equipSelected)
      ..dbMax = dbMax
      ..minTrainingDays = minTrainingDays
      ..trainingEffort = trainingEffort;
    return c;
  }

  /// The best efforts the member actually entered, keyed by the selected
  /// variant. A row without a parsable weight is skipped.
  List<BestEffort> collectBestEfforts() {
    final out = <BestEffort>[];

    String mapBench(String v) {
      switch (v) {
        case 'Bench Press':
          return 'bench_barbell';
        case 'Flat DB Press':
          return 'bench_db';
        case 'Chest Press':
          return 'chest_press';
        default:
          return v.replaceAll(' ', '_').toLowerCase();
      }
    }

    String mapSquat(String v) {
      switch (v) {
        case 'Back Squat':
          return 'back_squat';
        case 'Leg Press':
          return 'leg_press';
        default:
          return v.replaceAll(' ', '_').toLowerCase();
      }
    }

    String mapPull(String v) {
      switch (v) {
        case 'Lat Pull Down, Supinated':
          return 'lat_pulldown_supinated';
        case 'Lat Pull Down, Wide Arm':
          return 'lat_pulldown_wide';
        case 'Chin Up':
          return 'chinup';
        default:
          return v.replaceAll(' ', '_').toLowerCase();
      }
    }

    String mapDead(String v) {
      if (v == 'Deadlift') return 'deadlift';
      return v.replaceAll(' ', '_').toLowerCase();
    }

    void addIfPresent(String liftKey, String weightKey, String repsKey) {
      final w = double.tryParse((bestEffortText[weightKey] ?? '').trim());
      final r = int.tryParse((bestEffortText[repsKey] ?? '').trim());
      if (w != null) {
        out.add(BestEffort(liftKey: liftKey, weightKg: w, reps: r));
      }
    }

    addIfPresent(mapBench(benchVariant), BestEffortField.benchWeight,
        BestEffortField.benchReps);
    addIfPresent(mapSquat(squatVariant), BestEffortField.squatWeight,
        BestEffortField.squatReps);
    addIfPresent(mapPull(pullVariant), BestEffortField.pullWeight,
        BestEffortField.pullReps);
    addIfPresent(mapDead(deadVariant), BestEffortField.deadWeight,
        BestEffortField.deadReps);

    return out;
  }
}

/// The immutable set of Firestore writes Page 2 performs for one Finish /
/// Save Changes. Built from a deep copy, so later UI edits cannot alter a
/// submission that is already being written or retried.
class OnboardingSubmission {
  OnboardingSubmission._(this._form);

  factory OnboardingSubmission.fromForm(OnboardingFormData form) =>
      OnboardingSubmission._(form.deepCopy());

  final OnboardingFormData _form;

  OnboardingFormData get form => _form;

  List<BestEffort> get bestEfforts => _form.collectBestEfforts();

  int? get weeklyFrequency => _form.minTrainingDays;

  OnboardingAnswers answers({DateTime? now}) => OnboardingAnswers(
        goalsRanked: _form.goals.toList(),
        bodyFocus: _form.bodyFocus.isEmpty ? null : _form.bodyFocus.toList(),
        injuries: _form.injuries.isEmpty ? null : _form.injuries.toList(),
        painNow: _form.injuries.isEmpty
            ? null
            : Map.fromEntries(_form.injuries.map(
                (k) => MapEntry(k, (_form.painSlider[k] ?? 1).round()))),
        experience: _form.experience,
        bestEfforts: _form.collectBestEfforts(),
        minTrainingDaysPerWeek: _form.minTrainingDays,
        trainingEffort: _form.trainingEffort,
        createdAt: now ?? DateTime.now(),
        version: 'v1',
      );

  /// Shoulder / elbow detail flags, only for the injuries actually selected.
  Map<String, dynamic> painDetailFlags() {
    final flags = <String, dynamic>{};
    if (_form.injuries.contains('Shoulders')) {
      flags['shoulderPainOverhead'] = _form.shoulderPainOverhead;
      flags['shoulderPainFront'] = _form.shoulderPainFront;
    }
    if (_form.injuries.contains('Elbows')) {
      flags['elbowPainInside'] = _form.elbowPainInside;
      flags['elbowPainOutside'] = _form.elbowPainOutside;
    }
    return flags;
  }

  Map<String, int> get bodyFocusLevel =>
      Map<String, int>.of(_form.bodyFocusLevel);

  /// Child levels per parent, keeping explicit zeros, omitting empty parents.
  Map<String, Map<String, int>> get bodyFocusChildren {
    final filtered = <String, Map<String, int>>{};
    _form.childFocusLevel.forEach((parent, kids) {
      if (kids.isNotEmpty) filtered[parent] = Map<String, int>.of(kids);
    });
    return filtered;
  }

  List<String> get goalsRanked => List<String>.of(_form.goals);
  List<String> get goalsNotImportant =>
      List<String>.of(_form.notImportantGoals);

  String? get environment => _form.env;
  List<String> get equipmentItems => _form.equipSelected.toList();
  int? get dumbbellsMax => _form.dbMax;
  int? get ptHistoryIndex => _form.ptHistory;
}
