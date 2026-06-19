import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../WES2_plan_service.dart';
import '../block_exercise_defaults_repository.dart';

const Set<String> _defaultVelocityExerciseIds = {
  'heeBViVINHO6tUScSd6y',
  'AJIQi4kzUVb7IfOyxfZs',
  'm6zHYgovIiYPM7NgqoeR',
  'AmfUWbF1DH3I7qPAdh5k',
  'pU7wce56hFDsam53aKDr',
  'wtrVB88vFR0EDRc7Uli0',
  'IECRZ5GJrc78DRnyuhtQ',
  'ZH6VIWHexxxlpKRYgwil',
  'WH2qpYjDeb6M0j2FtlGs',
  'MsGl7e9yanDeEnYX0e4X',
  'EQL6s4QJnXApe8DdmJbX',
  'YvwK9kwc1hcA2omz1g4r',
  'lVDG90yN6Z8aPjRNV2wc',
  '10pEctikt6PP8eAg9Eip',
  'NkctO0XmQrUHfLCkpRXr',
};

class Wes2ExerciseSettingsDialog extends StatefulWidget {
  final String uid;
  final String blockId;
  final String exerciseId;
  final String exerciseName;
  final int weekIndex; // 0-based
  final int dayIndex; // 0-based, used as estimated session display
  final int totalBlockWeeks; // used to write RIR from current week forward
  final Wes2PlanService planService;
  final int?
      resolvedActiveInstanceOverride; // history-aware override for DUP models
  final int?
      completedInstanceCount; // completed instances of this exercise in the active block to date
  final int?
      weeklyInstanceOverride; // BB3-computed within-week instance number (1-based)
  /// 1-based RIR session the hint engine uses for the selected workout, derived
  /// from the block-relative dayIndex (days % 7) + 1 — independent of the
  /// rep-target instance. Null when the caller cannot supply the correct source.
  final int? activeRirSessionIndex;

  const Wes2ExerciseSettingsDialog({
    super.key,
    required this.uid,
    required this.blockId,
    required this.exerciseId,
    required this.exerciseName,
    required this.weekIndex,
    required this.dayIndex,
    required this.totalBlockWeeks,
    required this.planService,
    this.resolvedActiveInstanceOverride,
    this.completedInstanceCount,
    this.weeklyInstanceOverride,
    this.activeRirSessionIndex,
  });

  @override
  State<Wes2ExerciseSettingsDialog> createState() =>
      _Wes2ExerciseSettingsDialogState();
}

class _Wes2ExerciseSettingsDialogState
    extends State<Wes2ExerciseSettingsDialog> {
  bool _loading = true;
  String? _loadError;
  bool _saving = false;
  String? _saveError;
  String? _exerciseType;
  bool _showVelocityField = false;

  // The full exerciseSettings map from the block doc (for merging on save).
  Map<String, dynamic> _existingSettings = {};

  // Dropdown state
  String? _periodizationModel;
  String? _rirModel;
  String? _progressionModel;

  // Text controllers
  final _weeklyFrequencyCtrl = TextEditingController();
  final _incrementsPrimaryCtrl = TextEditingController();
  final _incrementsSecondaryCtrl = TextEditingController();
  final _defaultSetsCtrl = TextEditingController();

  // repTargets for current week: instanceN → format string, or 'min'/'max' for Signature
  final Map<String, TextEditingController> _repTargetCtrls = {};

  // rirPlan for current week: sessionN_setM → rir string
  final Map<String, TextEditingController> _rirPlanCtrls = {};

  // Snapshot of values as loaded from Firestore; used in _buildRirPlan to
  // detect which fields the user actually changed before writing forward.
  final Map<String, String> _originalRirPlanValues = {};

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _weeklyFrequencyCtrl.dispose();
    _incrementsPrimaryCtrl.dispose();
    _incrementsSecondaryCtrl.dispose();
    _defaultSetsCtrl.dispose();
    for (final c in _repTargetCtrls.values) {
      c.dispose();
    }
    for (final c in _rirPlanCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  String get _weekKey => 'week${widget.weekIndex + 1}';

  bool get _isDupSignature => _periodizationModel == 'DUP, Signature';

  bool get _isDupWeekOrExposure =>
      _periodizationModel == 'DUP, By Week' ||
      _periodizationModel == 'DUP, By Exposure';

  int get _weeklyInstanceDisplay {
    if (widget.weeklyInstanceOverride != null)
      return widget.weeklyInstanceOverride!;
    final count = _sessionCount;
    if (count <= 0) return 1;
    return (widget.dayIndex % count) + 1;
  }

  int get _globalInstanceDisplay {
    if (widget.completedInstanceCount != null)
      return widget.completedInstanceCount!;
    final count = _sessionCount;
    if (count <= 0) return widget.dayIndex + 1;
    return (widget.weekIndex * count) + _weeklyInstanceDisplay;
  }

  /// weekData source for rep-target slot count and active instance resolution.
  /// DUP By Week / DUP By Exposure: always week1 (single repeating template;
  /// never let polluted weekN keys affect slot count or active instance).
  /// Other models: current week with week1 fallback.
  Map<String, dynamic>? get _repTargetWeekData {
    final repTargets = _existingSettings['repTargets'] as Map<String, dynamic>?;
    if (repTargets == null) return null;
    if (_isDupWeekOrExposure) {
      return repTargets['week1'] as Map<String, dynamic>?;
    }
    return (repTargets.containsKey(_weekKey)
        ? repTargets[_weekKey]
        : repTargets['week1']) as Map<String, dynamic>?;
  }

  int get _microcycleSlotCount {
    final weekData = _repTargetWeekData;
    if (weekData == null) return 0;
    return weekData.keys.where((k) => k.startsWith('instance')).length;
  }

  /// 1-based rep target instance number WES2 is using for today.
  /// Mirrors _targetSetCountForSession / getRepTargetForSet instance selection:
  /// if instance${dayIndex+1} exists in weekData → use it; else fall back to 1.
  int get _resolvedActiveInstanceNumber {
    if (_isDupSignature) return 1;
    final weekData = _repTargetWeekData;
    if (weekData == null) return 1;
    // Use history-aware override when provided (DUP By Exposure / By Week).
    // Clamp to valid slot range so a stale override cannot point outside the microcycle.
    final slotCount = _microcycleSlotCount;
    if (widget.resolvedActiveInstanceOverride != null && slotCount > 0) {
      final clamped =
          ((widget.resolvedActiveInstanceOverride! - 1) % slotCount) + 1;
      return clamped;
    }
    final candidate = widget.dayIndex + 1;
    final resolved = weekData.containsKey('instance$candidate') ? candidate : 1;
    return resolved;
  }

  String get _microcycleInstanceDisplay {
    final n = _microcycleSlotCount;
    if (n <= 0) return 'Not set';
    return '$_resolvedActiveInstanceNumber of $n';
  }

  int get _sessionCount {
    final wf = int.tryParse(_weeklyFrequencyCtrl.text.trim());
    if (wf != null && wf > 0) return wf;
    final existing = _existingSettings['weeklyFrequency'];
    if (existing is num && existing.toInt() > 0) return existing.toInt();
    return 3;
  }

  /// Returns the planned set count for [sessionNumber] (1-based).
  /// DUP Signature: uses live _defaultSetsCtrl.text, then saved defaultSets, then 3.
  /// Other models: parses "N x M" from instanceN rep target, then saved defaultSets, then 3.
  int _setCountForSession(int sessionNumber) {
    if (!_isDupSignature) {
      final raw = _repTargetCtrls['instance$sessionNumber']?.text.trim() ?? '';
      if (raw.isNotEmpty) {
        final m = RegExp(r'[xX]\s*(\d+)').firstMatch(raw);
        if (m != null) {
          final n = int.tryParse(m.group(1)!);
          if (n != null && n > 0) return n.clamp(1, 10);
        }
      }
    }
    if (_isDupSignature) {
      final live = int.tryParse(_defaultSetsCtrl.text.trim());
      if (live != null && live > 0) return live.clamp(1, 10);
    }
    final ds = (_existingSettings['defaultSets'] as num?)?.toInt();
    if (ds != null && ds > 0) return ds.clamp(1, 10);
    return 3;
  }

  Future<void> _loadSettings() async {
    try {
      final allSettings = await widget.planService.loadExerciseSettings(
        uid: widget.uid,
        blockId: widget.blockId,
      );
      if (!mounted) return;

      var raw = allSettings[widget.exerciseId];
      // Safety net: trigger if settings are absent OR incomplete (e.g. only
      // week-N fragments with no core scalars like periodizationModel).
      if (!BlockExerciseDefaultsRepository.isSettingsUsable(
          raw is Map<String, dynamic> ? raw : null)) {
        try {
          await BlockExerciseDefaultsRepository.ensureExerciseDefaults(
            uid: widget.uid,
            blockId: widget.blockId,
            exerciseId: widget.exerciseId,
          );
          final reloaded = await widget.planService.loadExerciseSettings(
            uid: widget.uid,
            blockId: widget.blockId,
          );
          raw = reloaded[widget.exerciseId];
        } catch (_) {}
      }
      final Map<String, dynamic> settings =
          raw is Map<String, dynamic> ? raw : {};

      _existingSettings = settings;

      _periodizationModel = settings['periodizationModel'] as String?;
      _rirModel = settings['rirModel'] as String?;
      _progressionModel = settings['progressionModel'] as String?;

      final explicitVelocity = settings['showVelocityField'];
      _showVelocityField = explicitVelocity is bool
          ? explicitVelocity
          : _defaultVelocityExerciseIds.contains(widget.exerciseId);

      final wf = settings['weeklyFrequency'];
      _weeklyFrequencyCtrl.text = wf != null ? '$wf' : '';

      final increments = settings['increments'] as Map<String, dynamic>?;
      _incrementsPrimaryCtrl.text = increments?['primary']?.toString() ?? '';
      _incrementsSecondaryCtrl.text =
          increments?['secondary']?.toString() ?? '';

      _defaultSetsCtrl.text = settings['defaultSets']?.toString() ?? '';

      _populateRepTargets(settings);
      _populateRirPlan(settings);

      // Fetch exercise type for display in footer.
      try {
        final exDoc = await FirebaseFirestore.instance
            .collection('exercises')
            .doc(widget.exerciseId)
            .get();
        if (mounted) {
          _exerciseType = exDoc.data()?['type'] as String?;
        }
      } catch (_) {
        // Non-critical; footer shows 'Not set' if unavailable.
      }

      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Failed to load settings.';
      });
    }
  }

  void _populateRepTargets(Map<String, dynamic> settings) {
    for (final c in _repTargetCtrls.values) {
      c.dispose();
    }
    _repTargetCtrls.clear();

    if (_isDupSignature) {
      final range = _parseDupSignatureRange(settings['repTargets']);
      _repTargetCtrls['min'] = TextEditingController(
        text: range?['min']?.toString() ?? '',
      );
      _repTargetCtrls['max'] = TextEditingController(
        text: range?['max']?.toString() ?? '',
      );
    } else {
      final repTargets = settings['repTargets'] as Map<String, dynamic>?;
      // DUP By Week/Exposure: week1 is the single repeating microcycle template.
      // Other models: prefer current week, fall back to week1.
      Map<String, dynamic>? weekData;
      if (_isDupWeekOrExposure) {
        weekData = repTargets?['week1'] as Map<String, dynamic>?;
      } else {
        weekData = (repTargets?[_weekKey] ?? repTargets?['week1'])
            as Map<String, dynamic>?;
      }
      final count = _sessionCount;
      for (int i = 1; i <= count; i++) {
        final key = 'instance$i';
        _repTargetCtrls[key] = TextEditingController(
          text: weekData?[key]?.toString() ?? '',
        );
      }
    }
  }

  void _populateRirPlan(Map<String, dynamic> settings) {
    for (final c in _rirPlanCtrls.values) {
      c.dispose();
    }
    _rirPlanCtrls.clear();
    _originalRirPlanValues.clear();

    final rirPlan = settings['rirPlan'] as Map<String, dynamic>?;
    final weekData =
        (rirPlan?[_weekKey] ?? rirPlan?['week1']) as Map<String, dynamic>?;

    final count = _sessionCount;
    for (int i = 1; i <= count; i++) {
      final sessionKey = 'session$i';
      final sessionData = weekData?[sessionKey] as Map<String, dynamic>?;
      final sc = _setCountForSession(i);
      for (int s = 1; s <= sc; s++) {
        final key = '${sessionKey}_set$s';
        final setData = sessionData?['set$s'] as Map<String, dynamic>?;
        final loaded = setData?['rir']?.toString() ?? '';
        _rirPlanCtrls[key] = TextEditingController(text: loaded);
        _originalRirPlanValues[key] = loaded;
      }
    }
  }

  Map<String, dynamic> _buildRepTargets() {
    final existing =
        (_existingSettings['repTargets'] as Map<String, dynamic>?) ?? {};

    if (_isDupSignature) {
      // DUP Signature range is block-scoped: write to repRange.
      // Spread existing first so week1, weekN, and any other keys are preserved.
      final minVal = int.tryParse(_repTargetCtrls['min']?.text.trim() ?? '');
      final maxVal = int.tryParse(_repTargetCtrls['max']?.text.trim() ?? '');
      final existingRepRangeRaw = existing['repRange'];
      final repRange = existingRepRangeRaw is Map
          ? Map<String, dynamic>.from(existingRepRangeRaw)
          : <String, dynamic>{};
      if (minVal != null) repRange['min'] = minVal;
      if (maxVal != null) repRange['max'] = maxVal;
      return {...existing, 'repRange': repRange};
    }

    final Map<String, dynamic> weekData = {};
    for (final entry in _repTargetCtrls.entries) {
      final v = entry.value.text.trim();
      if (v.isNotEmpty) weekData[entry.key] = v;
    }
    // DUP By Week/Exposure: save into week1 (the repeating template); never write weekN.
    final saveKey = _isDupWeekOrExposure ? 'week1' : _weekKey;
    return {...existing, saveKey: weekData};
  }

  /// Parses a DUP Signature min/max rep range from a raw repTargets value.
  /// DUP Signature range is block-scoped; no week index needed.
  /// Priority: repRange.{min,max} → week1.{min,max} → week1.instance1 string.
  /// Uses only safe conversions — never throws on malformed data.
  static Map<String, int>? _parseDupSignatureRange(dynamic repTargetsRaw) {
    Map<String, dynamic>? asStringMap(dynamic v) {
      if (v is Map) return Map<String, dynamic>.from(v);
      return null;
    }

    int? parseInt(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString().trim());
    }

    Map<String, int>? fromMap(Map<String, dynamic>? m) {
      if (m == null) return null;
      final mn = parseInt(m['min']);
      final mx = parseInt(m['max']);
      if (mn != null && mx != null && mn < mx) return {'min': mn, 'max': mx};
      return null;
    }

    final repTargets = asStringMap(repTargetsRaw);
    if (repTargets == null) return null;

    // 1. repRange — canonical block-scoped shape
    final r1 = fromMap(asStringMap(repTargets['repRange']));
    if (r1 != null) return r1;

    // 2. week1.{min,max} — compatibility fallback
    final week1 = asStringMap(repTargets['week1']);
    final r2 = fromMap(week1);
    if (r2 != null) return r2;

    // 3. week1.instance1 string e.g. "6 – 12 reps" / "6-12" / "6 - 12"
    if (week1 != null) {
      final raw = week1['instance1']?.toString();
      if (raw != null) {
        final m = RegExp(r'(\d+)\s*[–\-—]\s*(\d+)').firstMatch(raw);
        if (m != null) {
          final mn = int.tryParse(m.group(1)!);
          final mx = int.tryParse(m.group(2)!);
          if (mn != null && mx != null && mn < mx)
            return {'min': mn, 'max': mx};
        }
      }
    }

    return null;
  }

  Map<String, dynamic> _buildRirPlan() {
    final existing =
        (_existingSettings['rirPlan'] as Map<String, dynamic>?) ?? {};
    final result = Map<String, dynamic>.from(existing);

    // Only propagate session/set keys where the user actually changed the value.
    // null = user cleared a previously non-empty field → remove 'rir' from future weeks.
    // non-null = user set or updated a value → write it forward.
    final sessionChanges = <String, Map<String, String?>>{};
    for (final entry in _rirPlanCtrls.entries) {
      final current = entry.value.text.trim();
      final original = _originalRirPlanValues[entry.key] ?? '';
      if (current == original)
        continue; // unchanged — do not touch future weeks
      final parts = entry.key.split('_'); // ['sessionN', 'setM']
      if (parts.length != 2) continue;
      sessionChanges.putIfAbsent(parts[0], () => {})[parts[1]] =
          current.isEmpty ? null : current;
    }

    if (sessionChanges.isEmpty) return result; // nothing changed

    // Write changes from the current week onward; leave previous weeks untouched.
    for (int w = widget.weekIndex + 1; w <= widget.totalBlockWeeks; w++) {
      final weekKey = 'week$w';
      final existingWeek = (result[weekKey] as Map<String, dynamic>?) ?? {};
      final weekData = Map<String, dynamic>.from(existingWeek);

      for (final sessionEntry in sessionChanges.entries) {
        final sessionKey = sessionEntry.key;
        final existingSession =
            (weekData[sessionKey] as Map<String, dynamic>?) ?? {};
        final sessionData = Map<String, dynamic>.from(existingSession);

        for (final setEntry in sessionEntry.value.entries) {
          final setKey = setEntry.key;
          final existingSet =
              (sessionData[setKey] as Map<String, dynamic>?) ?? {};
          if (setEntry.value == null) {
            // User cleared — remove 'rir' key, preserve any other set-level keys.
            final cleaned = Map<String, dynamic>.from(existingSet)
              ..remove('rir');
            if (cleaned.isEmpty) {
              sessionData.remove(setKey);
            } else {
              sessionData[setKey] = cleaned;
            }
          } else {
            sessionData[setKey] = {...existingSet, 'rir': setEntry.value};
          }
        }

        weekData[sessionKey] = sessionData;
      }

      result[weekKey] = weekData;
    }

    return result;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final existingIncrements =
          (_existingSettings['increments'] as Map<String, dynamic>?) ?? {};
      final increments = Map<String, dynamic>.from(existingIncrements);
      final primText = _incrementsPrimaryCtrl.text.trim();
      final secText = _incrementsSecondaryCtrl.text.trim();
      if (primText.isNotEmpty) {
        increments['primary'] = double.tryParse(primText) ?? primText;
      }
      if (secText.isNotEmpty) {
        increments['secondary'] = double.tryParse(secText) ?? secText;
      }

      final wfText = _weeklyFrequencyCtrl.text.trim();
      final wf = wfText.isNotEmpty ? int.tryParse(wfText) : null;

      final dsText = _defaultSetsCtrl.text.trim();
      final ds = dsText.isNotEmpty ? int.tryParse(dsText) : null;
      if (_isDupSignature && ds != null && ds < 1) {
        setState(() {
          _saving = false;
          _saveError = 'Default Set Count must be at least 1.';
        });
        return;
      }

      final merged = <String, dynamic>{
        ..._existingSettings,
        if (_periodizationModel != null)
          'periodizationModel': _periodizationModel,
        if (_rirModel != null) 'rirModel': _rirModel,
        if (_progressionModel != null) 'progressionModel': _progressionModel,
        if (wf != null) 'weeklyFrequency': wf,
        if (increments.isNotEmpty) 'increments': increments,
        if (_isDupSignature && ds != null) 'defaultSets': ds,
        'repTargets': _buildRepTargets(),
        'rirPlan': _buildRirPlan(),
        'showVelocityField': _showVelocityField,
      };

      await widget.planService.saveExerciseSettings(
        uid: widget.uid,
        blockId: widget.blockId,
        exerciseId: widget.exerciseId,
        settings: merged,
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Could not save — check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      titlePadding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
      contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      actionsPadding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.exerciseName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            'Week ${widget.weekIndex + 1} · Session $_weeklyInstanceDisplay of $_sessionCount',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ],
      ),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.94,
        child: _buildContent(),
      ),
      actions: _buildActions(),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const SizedBox(
        height: 80,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(_loadError!, style: const TextStyle(color: Colors.red)),
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.72,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_saveError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _saveError!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
            _settingsRow(
              left: _buildTextField(
                controller: _incrementsPrimaryCtrl,
                label: 'Primary Increment',
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              right: _buildTextField(
                controller: _weeklyFrequencyCtrl,
                label: 'Weekly Frequency',
                keyboardType: TextInputType.number,
                onChanged: (_) {
                  _syncSessionControllersToFrequency();
                  setState(() {});
                },
              ),
            ),
            const SizedBox(height: 8),
            _buildDropdown(
              label: 'Periodisation Reps Model',
              value: _periodizationModel,
              items: const [
                'DUP, By Exposure',
                'DUP, Signature',
                'DUP, By Week',
                'Linear, Classic',
                'Linear, by Exposure',
              ],
              onChanged: (v) {
                final wasSignature = _isDupSignature;
                _periodizationModel = v;
                if (_isDupSignature != wasSignature) {
                  _populateRepTargets(_existingSettings);
                } else {
                  _syncSessionControllersToFrequency();
                }
                setState(() {});
              },
            ),
            const SizedBox(height: 8),
            _buildRepTargetsSection(),
            const SizedBox(height: 10),
            _buildDropdown(
              label: 'Periodisation RIR Model',
              value: _rirModel,
              items: const [
                'Linear-Taper',
                'Wave RIR undulation',
                'Session RIR Undulation',
                'Static RIR',
              ],
              onChanged: (v) => setState(() => _rirModel = v),
            ),
            const SizedBox(height: 8),
            _buildRirPlanSection(),
            const SizedBox(height: 10),
            _buildDropdown(
              label: 'Progression Model',
              value: _progressionModel,
              items: const [
                'Linear Weight Increase',
                'Add Reps',
                'Smart Progression',
                'None',
              ],
              onChanged: (v) => setState(() => _progressionModel = v),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              'Show velocity input',
                              style: const TextStyle(fontSize: 14),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Tooltip(
                            message:
                                'We recommend using a Vitruve Velocity Encoder or GymAware Encoder.',
                            triggerMode: TooltipTriggerMode.tap,
                            child: const Icon(
                              Icons.info_outline,
                              size: 15,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Adds a Vel. field so you can manually record bar speed if you track it.',
                        style: TextStyle(fontSize: 11, color: Colors.white54),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _showVelocityField,
                  onChanged: (v) => setState(() => _showVelocityField = v),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _buildIndexFooter(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildRepTargetsSection() {
    _syncSessionControllersToFrequency();

    if (_isDupSignature) {
      return Column(
        children: [
          _settingsRow(
            left: _buildTextField(
              controller: _repTargetCtrls['min'] ??= TextEditingController(),
              label: 'Min Reps',
              keyboardType: TextInputType.number,
            ),
            right: _buildTextField(
              controller: _repTargetCtrls['max'] ??= TextEditingController(),
              label: 'Max Reps',
              keyboardType: TextInputType.number,
            ),
          ),
          const SizedBox(height: 8),
          _settingsRow(
            left: _buildTextField(
              controller: _defaultSetsCtrl,
              label: 'Default Set Count',
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
            ),
            right: const SizedBox.shrink(),
          ),
        ],
      );
    }

    final entries = _repTargetCtrls.entries.toList()
      ..sort((a, b) {
        final ai = int.tryParse(a.key.replaceAll('instance', '')) ?? 0;
        final bi = int.tryParse(b.key.replaceAll('instance', '')) ?? 0;
        return ai.compareTo(bi);
      });

    if (entries.isEmpty) {
      return const Text(
        'Set weekly frequency to populate rep targets.',
        style: TextStyle(fontSize: 12, color: Colors.white54),
      );
    }

    final activeKey = 'instance$_resolvedActiveInstanceNumber';
    String slotLabel(String key) {
      final num = key.replaceAll('instance', '');
      return key == activeKey
          ? 'Reps Session $num · Active'
          : 'Reps Session $num';
    }

    return Column(
      children: [
        for (int i = 0; i < entries.length; i += 2) ...[
          _settingsRow(
            left: _buildTextField(
              controller: entries[i].value,
              label: slotLabel(entries[i].key),
            ),
            right: i + 1 < entries.length
                ? _buildTextField(
                    controller: entries[i + 1].value,
                    label: slotLabel(entries[i + 1].key),
                  )
                : const SizedBox.shrink(),
          ),
          if (i + 2 < entries.length) const SizedBox(height: 8),
        ],
      ],
    );
  }

  /// 1-based RIR session number to highlight, or null when no highlight should
  /// be shown. Mirrors [BB3PlannedExerciseService.getRirFromPlan] session
  /// selection exactly: resolves against the actual rirPlan map using the
  /// current-week → week1 fallback, then the requested-session → session1
  /// fallback. Returns null only when the caller supplied no source index.
  int? get _activeRirSessionNumber {
    final n = widget.activeRirSessionIndex;
    if (n == null) return null;
    final rirPlan = _existingSettings['rirPlan'];
    if (rirPlan is! Map) return 1; // matches getRirFromPlan's session1 default
    final weekData = (rirPlan[_weekKey] ?? rirPlan['week1']);
    if (weekData is! Map) return 1;
    return weekData.containsKey('session$n') ? n : 1;
  }

  Widget _buildRirPlanSection() {
    _syncSessionControllersToFrequency();

    final count = _sessionCount.clamp(1, 14);
    if (_rirPlanCtrls.isEmpty) {
      return const Text(
        'Set weekly frequency to populate RIR targets.',
        style: TextStyle(fontSize: 12, color: Colors.white54),
      );
    }

    final activeSession = _activeRirSessionNumber;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 1; i <= count; i++) ...[
          if (i > 1) const SizedBox(height: 5),
          Builder(
            builder: (context) {
              final group = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Session $i',
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                  const SizedBox(height: 2),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      const double minFieldWidth = 60;
                      const double gap = 4;
                      final sc = _setCountForSession(i);

                      Widget field(int s) => _buildRirTextField(
                            controller: _rirPlanCtrls['session${i}_set$s'] ??
                                TextEditingController(),
                            label: 'S$s',
                          );

                      Widget rowOf(int from, int to) => Row(
                            children: [
                              for (int s = from; s <= to; s++) ...[
                                if (s > from) const SizedBox(width: gap),
                                Expanded(child: field(s)),
                              ],
                            ],
                          );

                      // All sets fit on one row when sc <= 4 and width allows.
                      final allOnOneRow = sc <= 4 &&
                          constraints.maxWidth >=
                              minFieldWidth * sc + gap * (sc - 1);

                      if (allOnOneRow) return rowOf(1, sc);

                      // Chunks of up to 4 per row.
                      final rows = <Widget>[];
                      for (int start = 1; start <= sc; start += 4) {
                        final end = (start + 3).clamp(start, sc);
                        if (rows.isNotEmpty) {
                          rows.add(const SizedBox(height: gap));
                        }
                        rows.add(rowOf(start, end));
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: rows,
                      );
                    },
                  ),
                ],
              );

              // Subtle 1px border around the RIR session the hint engine uses.
              // Display-only; never changes or saves any RIR value.
              if (activeSession != i) return group;
              return Container(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .secondary
                        .withValues(alpha: 0.6),
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: group,
              );
            },
          ),
        ],
      ],
    );
  }

  void _syncSessionControllersToFrequency() {
    final count = _sessionCount.clamp(1, 14).toInt();

    if (_isDupSignature) {
      _repTargetCtrls.putIfAbsent('min', () => TextEditingController());
      _repTargetCtrls.putIfAbsent('max', () => TextEditingController());

      final removeKeys =
          _repTargetCtrls.keys.where((k) => k != 'min' && k != 'max').toList();
      for (final k in removeKeys) {
        _repTargetCtrls.remove(k)?.dispose();
      }
    } else {
      final wanted = <String>{
        for (int i = 1; i <= count; i++) 'instance$i',
      };

      for (int i = 1; i <= count; i++) {
        _repTargetCtrls.putIfAbsent(
          'instance$i',
          () => TextEditingController(),
        );
      }

      final removeKeys =
          _repTargetCtrls.keys.where((k) => !wanted.contains(k)).toList();
      for (final k in removeKeys) {
        _repTargetCtrls.remove(k)?.dispose();
      }
    }

    final wantedRir = <String>{};
    for (int i = 1; i <= count; i++) {
      final sc = _setCountForSession(i);
      for (int s = 1; s <= sc; s++) {
        wantedRir.add('session${i}_set$s');
      }
    }

    for (int i = 1; i <= count; i++) {
      final sc = _setCountForSession(i);
      for (int s = 1; s <= sc; s++) {
        _rirPlanCtrls.putIfAbsent(
          'session${i}_set$s',
          () => TextEditingController(),
        );
      }
    }

    final removeRirKeys =
        _rirPlanCtrls.keys.where((k) => !wantedRir.contains(k)).toList();
    for (final k in removeRirKeys) {
      _rirPlanCtrls.remove(k)?.dispose();
    }
  }

  Widget _settingsRow({
    required Widget left,
    required Widget right,
  }) {
    return Row(
      children: [
        Expanded(child: left),
        const SizedBox(width: 8),
        Expanded(child: right),
      ],
    );
  }

  Widget _buildIndexFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Current global rep target instance: $_globalInstanceDisplay',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          Text(
            'Current weekly rep target instance: $_weeklyInstanceDisplay of $_sessionCount',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          Text(
            'Current microcycle rep target instance: $_microcycleInstanceDisplay',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          Text(
            'Exercise type: ${_exerciseType ?? 'Not set'}',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown({
    required String label,
    required String? value,
    required List<String> items,
    required void Function(String?) onChanged,
  }) {
    return SizedBox(
      height: 48,
      child: DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          floatingLabelBehavior: FloatingLabelBehavior.always,
          isDense: true,
          filled: true,
          fillColor: Theme.of(context).cardTheme.color ??
              Theme.of(context).colorScheme.surface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
        items: items
            .map(
              (s) => DropdownMenuItem(
                value: s,
                child: Text(
                  s,
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            )
            .toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) {
    return SizedBox(
      height: 48,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          floatingLabelBehavior: FloatingLabelBehavior.always,
          isDense: true,
          filled: true,
          fillColor: Theme.of(context).cardTheme.color ??
              Theme.of(context).colorScheme.surface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }

  /// Compact variant of [_buildTextField] for RIR set fields only.
  /// Shorter height and tighter padding to reduce vertical space in the RIR section.
  Widget _buildRirTextField({
    required TextEditingController controller,
    required String label,
  }) {
    return SizedBox(
      height: 40,
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          floatingLabelBehavior: FloatingLabelBehavior.always,
          isDense: true,
          filled: true,
          fillColor: Theme.of(context).cardTheme.color ??
              Theme.of(context).colorScheme.surface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }

  List<Widget> _buildActions() {
    if (_loading || _loadError != null) {
      return [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ];
    }
    return [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: _saving ? null : _save,
        child: _saving
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Save'),
      ),
    ];
  }
}
