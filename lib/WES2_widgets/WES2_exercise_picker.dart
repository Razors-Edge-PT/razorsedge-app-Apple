import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// WES2 exercise picker bottom sheet.
/// Opens immediately; fetches exercises and planned IDs asynchronously inside.
///
/// [excludedIds]   — exerciseIds already on the current WES2 day; omitted entirely.
/// [actingUid]     — for planned_blocks/{uid}/blocks/{blockId} read.
/// [activeBlockId] — if null, planned toggle is hidden.
///
/// Returns a `({String exerciseId, String name})` record on selection,
/// or null if the sheet is dismissed without a selection.
class Wes2ExercisePicker extends StatefulWidget {
  final Set<String> excludedIds;
  final String actingUid;
  final String? activeBlockId;
  final List<int> availableCircuits;
  final int initialCircuitIndex;
  final String? titleOverride;

  const Wes2ExercisePicker({
    super.key,
    required this.excludedIds,
    required this.actingUid,
    required this.activeBlockId,
    this.availableCircuits = const [],
    this.initialCircuitIndex = 0,
    this.titleOverride,
  });

  @override
  State<Wes2ExercisePicker> createState() => _Wes2ExercisePickerState();
}

class _Wes2ExercisePickerState extends State<Wes2ExercisePicker> {
  static const List<String> _categoryOrder = [
    'Horizontal Press',
    'Horizontal Pull',
    'Vertical Press',
    'Vertical Pull',
    'Lateral Raise',
    'Arm Extension',
    'Arm Curl',
    'Squat Pattern',
    'Hip Hinge',
    'Leg Extension',
    'Leg Curl',
    'Hip Abduction/adduction',
    'Calf Raise',
    'Core',
  ];

  final TextEditingController _searchCtrl = TextEditingController();
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _allDocs = [];
  Set<String> _plannedIds = {};
  bool _loadingExercises = true;
  bool _loadingPlanned = true;
  bool _showPlannedOnly = false;
  String _query = '';
  String _fetchError = '';
  late int _selectedCircuitIndex;
  final Set<String> _expandedCategories = {..._categoryOrder, 'Other'};

  @override
  void initState() {
    super.initState();
    _selectedCircuitIndex = widget.initialCircuitIndex;
    _fetchExercises();
    _fetchPlannedIds();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchExercises() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('exercises')
          .orderBy('name')
          .limit(200)
          .get();
      if (!mounted) return;
      setState(() {
        _allDocs = snap.docs;
        _loadingExercises = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _fetchError = 'Could not load exercises.';
        _loadingExercises = false;
      });
    }
  }

  Future<void> _fetchPlannedIds() async {
    if (widget.activeBlockId == null) {
      if (!mounted) return;
      setState(() => _loadingPlanned = false);
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(widget.actingUid)
          .collection('blocks')
          .doc(widget.activeBlockId)
          .get();
      if (!mounted) return;
      final data = doc.data();
      // 3-step planned-only fallback
      final candidateList = (data?['templateCandidateExerciseIds'] as List?)
          ?.map((e) => e.toString()).toSet() ?? const <String>{};
      final settings = data?['exerciseSettings'] as Map<String, dynamic>? ?? {};
      final legacyPlanned = (data?['plannedExercises'] as List?)
          ?.map((e) => e.toString()).toSet() ?? const <String>{};
      final resolvedIds = candidateList.isNotEmpty
          ? candidateList
          : settings.isNotEmpty
              ? settings.keys.toSet()
              : legacyPlanned;
      setState(() {
        _plannedIds = resolvedIds;
        _showPlannedOnly = resolvedIds.isNotEmpty;
        _loadingPlanned = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingPlanned = false);
    }
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _visible {
    var docs =
        _allDocs.where((d) => !widget.excludedIds.contains(d.id)).toList();
    if (_showPlannedOnly && _plannedIds.isNotEmpty) {
      docs = docs.where((d) => _plannedIds.contains(d.id)).toList();
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      docs = docs.where((d) {
        final name = (d.data()['name'] as String? ?? '').toLowerCase();
        return name.contains(q);
      }).toList();
    }
    return docs;
  }

  Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>> _grouped() {
    final docs = _visible;
    final map = <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
    for (final cat in _categoryOrder) {
      map[cat] = [];
    }
    map['Other'] = [];
    for (final doc in docs) {
      final cat = (doc.data()['category'] as String?)?.trim() ?? '';
      if (_categoryOrder.contains(cat)) {
        map[cat]!.add(doc);
      } else {
        map['Other']!.add(doc);
      }
    }
    for (final list in map.values) {
      list.sort((a, b) => ((a.data()['name'] as String?) ?? '')
          .toLowerCase()
          .compareTo(((b.data()['name'] as String?) ?? '').toLowerCase()));
    }
    map.removeWhere((_, list) => list.isEmpty);
    return map;
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.84,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollCtrl) => Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 0),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: _buildPickerTitle(),
                ),
                const SizedBox(width: 8),
                _buildPlannedToggle(),
              ],
            ),
          ),
          const SizedBox(height: 0),
          if (widget.availableCircuits.length > 1) _buildCircuitSelector(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search exercises…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(child: _buildList(scrollCtrl)),
        ],
      ),
    );
  }

  Widget _buildPickerTitle() {
    final titleOverride = widget.titleOverride;
    final isReplace = titleOverride != null &&
        titleOverride.trim().toLowerCase().startsWith('replace');

    if (isReplace) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Replace',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          Text(
            _cleanReplaceExerciseName(titleOverride),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ],
      );
    }

    return Text(
      titleOverride ??
          'Add Exercise to Circuit ${_selectedCircuitIndex + 1}',
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
    );
  }

  String _cleanReplaceExerciseName(String rawTitle) {
    var s = rawTitle.trim();
    if (s.toLowerCase().startsWith('replace')) {
      s = s.substring('replace'.length).trim();
    }
    if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
      s = s.substring(1, s.length - 1);
    }
    return s.isEmpty ? 'exercise' : s;
  }

  Widget _buildCircuitSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Row(
        children: widget.availableCircuits.map((ci) {
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text('Circuit ${ci + 1}'),
              selected: _selectedCircuitIndex == ci,
              onSelected: (_) => setState(() => _selectedCircuitIndex = ci),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildPlannedToggle() {
    if (widget.activeBlockId == null) return const SizedBox.shrink();
    if (_loadingPlanned) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_plannedIds.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Planned',
          style: TextStyle(fontSize: 12, color: Colors.white70),
        ),
        Switch(
          value: _showPlannedOnly,
          onChanged: (v) => setState(() => _showPlannedOnly = v),
        ),
      ],
    );
  }

  Widget _buildList(ScrollController scrollCtrl) {
    if (_loadingExercises) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_fetchError.isNotEmpty) {
      return Center(child: Text(_fetchError));
    }
    final docs = _visible;
    if (docs.isEmpty) {
      return const Center(
        child: Text(
          'No exercises found.',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    if (_query.isNotEmpty) {
      final sorted = List.of(docs)
        ..sort((a, b) => ((a.data()['name'] as String?) ?? '')
            .toLowerCase()
            .compareTo(((b.data()['name'] as String?) ?? '').toLowerCase()));
      return ListView.builder(
        controller: scrollCtrl,
        itemCount: sorted.length,
        itemBuilder: (context, i) => _buildTile(sorted[i]),
      );
    }
    final groups = _grouped();
    final items = <Widget>[];
    for (final entry in groups.entries) {
      final cat = entry.key;
      final exercises = entry.value;
      final isExpanded = _expandedCategories.contains(cat);
      items.add(_buildCategoryHeader(cat, isExpanded));
      if (isExpanded) {
        for (final doc in exercises) {
          items.add(_buildTile(doc));
        }
      }
    }
    return ListView(
      controller: scrollCtrl,
      children: items,
    );
  }

  Widget _buildCategoryHeader(String category, bool isExpanded) {
    return InkWell(
      onTap: () => setState(() {
        if (isExpanded) {
          _expandedCategories.remove(category);
        } else {
          _expandedCategories.add(category);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Row(
          children: [
            Text(
              category.toUpperCase(),
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white38,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
              ),
            ),
            const Spacer(),
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              size: 16,
              color: Colors.white38,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTile(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final name = (doc.data()['name'] as String?) ?? doc.id;
    return ListTile(
      title: Text(
        name,
        style: const TextStyle(fontSize: 13),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      dense: true,
      visualDensity: VisualDensity.compact,
      minVerticalPadding: 0,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      onTap: () => Navigator.of(context).pop((
      exerciseId: doc.id,
      name: name,
      circuitIndex: _selectedCircuitIndex,
      )),
    );
  }
}
