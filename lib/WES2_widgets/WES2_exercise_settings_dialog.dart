import 'package:flutter/material.dart';
import '../WES2_plan_service.dart';

class Wes2ExerciseSettingsDialog extends StatefulWidget {
  final String uid;
  final String blockId;
  final String exerciseId;
  final String exerciseName;
  final int weekIndex; // 0-based
  final int dayIndex; // 0-based, used as estimated session display
  final Wes2PlanService planService;

  const Wes2ExerciseSettingsDialog({
    super.key,
    required this.uid,
    required this.blockId,
    required this.exerciseId,
    required this.exerciseName,
    required this.weekIndex,
    required this.dayIndex,
    required this.planService,
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

  // repTargets for current week: instanceN → format string, or 'min'/'max' for Signature
  final Map<String, TextEditingController> _repTargetCtrls = {};

  // rirPlan for current week: sessionN → set1 rir string
  final Map<String, TextEditingController> _rirPlanCtrls = {};

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

  int get _weeklyInstanceDisplay {
    final count = _sessionCount;
    if (count <= 0) return 1;
    return (widget.dayIndex % count) + 1;
  }

  int get _globalInstanceDisplay {
    final count = _sessionCount;
    if (count <= 0) return widget.dayIndex + 1;
    return (widget.weekIndex * count) + _weeklyInstanceDisplay;
  }


  int get _sessionCount {
    final wf = int.tryParse(_weeklyFrequencyCtrl.text.trim());
    if (wf != null && wf > 0) return wf;
    final existing = _existingSettings['weeklyFrequency'];
    if (existing is num && existing.toInt() > 0) return existing.toInt();
    return 3;
  }

  Future<void> _loadSettings() async {
    try {
      final allSettings = await widget.planService.loadExerciseSettings(
        uid: widget.uid,
        blockId: widget.blockId,
      );
      if (!mounted) return;

      final raw = allSettings[widget.exerciseId];
      final Map<String, dynamic> settings =
          raw is Map<String, dynamic> ? raw : {};

      _existingSettings = settings;

      _periodizationModel = settings['periodizationModel'] as String?;
      _rirModel = settings['rirModel'] as String?;
      _progressionModel = settings['progressionModel'] as String?;

      final wf = settings['weeklyFrequency'];
      _weeklyFrequencyCtrl.text = wf != null ? '$wf' : '';

      final increments = settings['increments'] as Map<String, dynamic>?;
      _incrementsPrimaryCtrl.text = increments?['primary']?.toString() ?? '';
      _incrementsSecondaryCtrl.text =
          increments?['secondary']?.toString() ?? '';

      _populateRepTargets(settings);
      _populateRirPlan(settings);

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

    final repTargets = settings['repTargets'] as Map<String, dynamic>?;
    final weekData = repTargets?[_weekKey] as Map<String, dynamic>?;

    if (_isDupSignature) {
      _repTargetCtrls['min'] = TextEditingController(
        text: weekData?['min']?.toString() ?? '',
      );
      _repTargetCtrls['max'] = TextEditingController(
        text: weekData?['max']?.toString() ?? '',
      );
    } else {
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

    final rirPlan = settings['rirPlan'] as Map<String, dynamic>?;
    final weekData = rirPlan?[_weekKey] as Map<String, dynamic>?;

    final count = _sessionCount;
    for (int i = 1; i <= count; i++) {
      final sessionKey = 'session$i';
      final sessionData = weekData?[sessionKey] as Map<String, dynamic>?;
      final set1 = sessionData?['set1'] as Map<String, dynamic>?;
      _rirPlanCtrls[sessionKey] = TextEditingController(
        text: set1?['rir']?.toString() ?? '',
      );
    }
  }

  Map<String, dynamic> _buildRepTargets() {
    final existing =
        (_existingSettings['repTargets'] as Map<String, dynamic>?) ?? {};
    final Map<String, dynamic> weekData = {};

    if (_isDupSignature) {
      final minVal = int.tryParse(_repTargetCtrls['min']?.text.trim() ?? '');
      final maxVal = int.tryParse(_repTargetCtrls['max']?.text.trim() ?? '');
      if (minVal != null) weekData['min'] = minVal;
      if (maxVal != null) weekData['max'] = maxVal;
    } else {
      for (final entry in _repTargetCtrls.entries) {
        final v = entry.value.text.trim();
        if (v.isNotEmpty) weekData[entry.key] = v;
      }
    }

    return {...existing, _weekKey: weekData};
  }

  Map<String, dynamic> _buildRirPlan() {
    final existing =
        (_existingSettings['rirPlan'] as Map<String, dynamic>?) ?? {};
    final existingWeek =
        (existing[_weekKey] as Map<String, dynamic>?) ?? {};
    final weekData = Map<String, dynamic>.from(existingWeek);

    for (final entry in _rirPlanCtrls.entries) {
      final rirText = entry.value.text.trim();
      if (rirText.isEmpty) continue;
      final sessionKey = entry.key;
      final existingSession =
          (weekData[sessionKey] as Map<String, dynamic>?) ?? {};
      final existingSet1 =
          (existingSession['set1'] as Map<String, dynamic>?) ?? {};
      weekData[sessionKey] = {
        ...existingSession,
        'set1': {...existingSet1, 'rir': rirText},
      };
    }

    return {...existing, _weekKey: weekData};
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

      final merged = <String, dynamic>{
        ..._existingSettings,
        if (_periodizationModel != null)
          'periodizationModel': _periodizationModel,
        if (_rirModel != null) 'rirModel': _rirModel,
        if (_progressionModel != null) 'progressionModel': _progressionModel,
        if (wf != null) 'weeklyFrequency': wf,
        if (increments.isNotEmpty) 'increments': increments,
        'repTargets': _buildRepTargets(),
        'rirPlan': _buildRirPlan(),
      };

      await widget.planService.saveExerciseSettings(
        uid: widget.uid,
        blockId: widget.blockId,
        exerciseId: widget.exerciseId,
        settings: merged,
      );

      if (!mounted) return;
      Navigator.of(context).pop();
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
      insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 18),
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
      return _settingsRow(
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

    return Column(
      children: [
        for (int i = 0; i < entries.length; i += 2) ...[
          _settingsRow(
            left: _buildTextField(
              controller: entries[i].value,
              label:
                  'Reps Session ${entries[i].key.replaceAll('instance', '')}',
            ),
            right: i + 1 < entries.length
                ? _buildTextField(
                    controller: entries[i + 1].value,
                    label:
                        'Reps Session ${entries[i + 1].key.replaceAll('instance', '')}',
                  )
                : const SizedBox.shrink(),
          ),
          if (i + 2 < entries.length) const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildRirPlanSection() {
    _syncSessionControllersToFrequency();

    final entries = _rirPlanCtrls.entries.toList()
      ..sort((a, b) {
        final ai = int.tryParse(a.key.replaceAll('session', '')) ?? 0;
        final bi = int.tryParse(b.key.replaceAll('session', '')) ?? 0;
        return ai.compareTo(bi);
      });

    if (entries.isEmpty) {
      return const Text(
        'Set weekly frequency to populate RIR targets.',
        style: TextStyle(fontSize: 12, color: Colors.white54),
      );
    }

    return Column(
      children: [
        for (int i = 0; i < entries.length; i += 2) ...[
          _settingsRow(
            left: _buildTextField(
              controller: entries[i].value,
              label:
                  'RIR Session ${entries[i].key.replaceAll('session', '')}',
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            right: i + 1 < entries.length
                ? _buildTextField(
                    controller: entries[i + 1].value,
                    label:
                        'RIR Session ${entries[i + 1].key.replaceAll('session', '')}',
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  )
                : const SizedBox.shrink(),
          ),
          if (i + 2 < entries.length) const SizedBox(height: 8),
        ],
      ],
    );
  }

  void _syncSessionControllersToFrequency() {
    final count = _sessionCount.clamp(1, 14).toInt();

    if (_isDupSignature) {
      _repTargetCtrls.putIfAbsent('min', () => TextEditingController());
      _repTargetCtrls.putIfAbsent('max', () => TextEditingController());

      final removeKeys = _repTargetCtrls.keys
          .where((k) => k != 'min' && k != 'max')
          .toList();
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

    final wantedRir = <String>{
      for (int i = 1; i <= count; i++) 'session$i',
    };

    for (int i = 1; i <= count; i++) {
      _rirPlanCtrls.putIfAbsent(
        'session$i',
        () => TextEditingController(),
      );
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
          fillColor:
              Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface,
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
          fillColor:
              Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
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


