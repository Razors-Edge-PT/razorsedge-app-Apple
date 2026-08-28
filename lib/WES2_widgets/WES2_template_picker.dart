import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../template_model.dart';

class _PickerData {
  final List<Template> templates;
  final Map<String, String> blockNames; // blockId → display name

  _PickerData(this.templates, this.blockNames);
}

/// Modal bottom sheet that lists the user's templates grouped by block
/// and pops the selected templateId, or null if dismissed.
class Wes2TemplatePicker extends StatefulWidget {
  final String uid;
  final String? activeBlockId;
  /// When true, draws a highlight + label on the first listed template.
  final bool highlightFirstTemplate;

  const Wes2TemplatePicker({
    super.key,
    required this.uid,
    this.activeBlockId,
    this.highlightFirstTemplate = false,
  });

  @override
  State<Wes2TemplatePicker> createState() => _Wes2TemplatePickerState();
}

class _Wes2TemplatePickerState extends State<Wes2TemplatePicker> {
  late final Future<_PickerData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_PickerData> _load() async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.uid)
        .collection('templates')
        .orderBy('name')
        .get();
    final templates = snap.docs
        .map((d) => Template.fromFirestore(d.data(), d.id))
        .where((t) => t.exercises.any((e) {
          final id = ((e['exerciseId'] ?? e['id']) as String? ?? '').trim();
          if (id.isNotEmpty) return true;
          return ((e['name'] ?? e['exercise']) as String? ?? '').trim().isNotEmpty;
        }))
        .toList();

    // Best-effort load block names for group headers.
    Map<String, String> blockNames = {};
    try {
      final blocksSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .collection('planned_blocks')
          .get();
      for (final doc in blocksSnap.docs) {
        final name = doc.data()['name'] as String?;
        if (name != null && name.isNotEmpty) {
          blockNames[doc.id] = name;
        }
      }
    } catch (_) {
      // Best-effort only; picker still works without block metadata.
    }

    return _PickerData(templates, blockNames);
  }

  // Extract leading number from template name for day-based sorting.
  static int _dayNumber(String name) {
    final m = RegExp(r'\d+').firstMatch(name);
    return m != null ? (int.tryParse(m.group(0)!) ?? 9999) : 9999;
  }

  static List<Template> _sorted(List<Template> list) {
    return List<Template>.from(list)
      ..sort((a, b) {
        final da = _dayNumber(a.name);
        final db = _dayNumber(b.name);
        if (da != db) return da.compareTo(db);
        return a.name.compareTo(b.name);
      });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.25,
      builder: (_, scrollCtrl) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Load Template',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 36, height: 36),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<_PickerData>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Failed to load templates.',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  );
                }
                final data = snapshot.data!;
                if (data.templates.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No templates available. Create one from the Workout Planner screen.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  );
                }
                return _buildGroupedList(scrollCtrl, data);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupedList(ScrollController scrollCtrl, _PickerData data) {
    final activeId = widget.activeBlockId;
    final templates = data.templates;
    final blockNames = data.blockNames;

    final String? activeBlockName =
        (activeId != null && activeId.isNotEmpty) ? blockNames[activeId] : null;

    final List<Template> activeGroup = [];
    final Map<String, List<Template>> otherGroups = {};
    final List<Template> unassigned = [];

    for (final t in templates) {
      if (activeId != null && activeId.isNotEmpty) {
        if (t.blockId == activeId) {
          activeGroup.add(t);
          continue;
        }
        // Legacy fallback: match blockAssignment string to active block name.
        if ((t.blockId == null || t.blockId!.isEmpty) &&
            t.blockAssignment != null &&
            activeBlockName != null &&
            t.blockAssignment!.toLowerCase() == activeBlockName.toLowerCase()) {
          activeGroup.add(t);
          continue;
        }
      }
      if (t.blockId != null && t.blockId!.isNotEmpty) {
        otherGroups.putIfAbsent(t.blockId!, () => []).add(t);
      } else {
        unassigned.add(t);
      }
    }

    // If there's only one implicit group and no grouping metadata, show flat.
    final hasGroups = activeGroup.isNotEmpty ||
        otherGroups.isNotEmpty ||
        (unassigned.isNotEmpty &&
            (activeGroup.isNotEmpty || otherGroups.isNotEmpty));

    if (!hasGroups) {
      // Flat list — no headers.
      final all = _sorted(unassigned);
      return ListView.builder(
        controller: scrollCtrl,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: all.length,
        itemBuilder: (_, i) => _TemplateListTile(
          template: all[i],
          highlight: i == 0 && widget.highlightFirstTemplate,
          onTap: () => Navigator.of(context).pop(all[i].id),
        ),
      );
    }

    final sections = <Widget>[];
    int sectionCount = 0;

    if (activeGroup.isNotEmpty) {
      final label = activeBlockName ?? 'Active Block';
      sections.add(_GroupSection(
        title: label,
        templates: _sorted(activeGroup),
        initiallyExpanded: true,
        highlightFirstItem: widget.highlightFirstTemplate && sectionCount == 0,
        onSelect: (id) => Navigator.of(context).pop(id),
      ));
      sectionCount++;
    }

    for (final blockId in otherGroups.keys) {
      final label = blockNames[blockId] ?? blockId;
      sections.add(_GroupSection(
        title: label,
        templates: _sorted(otherGroups[blockId]!),
        initiallyExpanded: false,
        highlightFirstItem: widget.highlightFirstTemplate && sectionCount == 0,
        onSelect: (id) => Navigator.of(context).pop(id),
      ));
      sectionCount++;
    }

    if (unassigned.isNotEmpty) {
      sections.add(_GroupSection(
        title: 'Other Templates',
        templates: _sorted(unassigned),
        initiallyExpanded: true,
        highlightFirstItem: widget.highlightFirstTemplate && sectionCount == 0,
        onSelect: (id) => Navigator.of(context).pop(id),
      ));
    }

    return ListView(
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 80),
      children: sections,
    );
  }
}

class _GroupSection extends StatefulWidget {
  final String title;
  final List<Template> templates;
  final bool initiallyExpanded;
  final bool highlightFirstItem;
  final void Function(String templateId) onSelect;

  const _GroupSection({
    required this.title,
    required this.templates,
    required this.initiallyExpanded,
    this.highlightFirstItem = false,
    required this.onSelect,
  });

  @override
  State<_GroupSection> createState() => _GroupSectionState();
}

class _GroupSectionState extends State<_GroupSection> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: Colors.white54,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          ...widget.templates.asMap().entries.map(
            (entry) => _TemplateListTile(
              template: entry.value,
              highlight: widget.highlightFirstItem && entry.key == 0,
              onTap: () => widget.onSelect(entry.value.id),
            ),
          ),
        const Divider(height: 1),
      ],
    );
  }
}

class _TemplateListTile extends StatelessWidget {
  final Template template;
  final VoidCallback onTap;
  final bool highlight;
  const _TemplateListTile({
    required this.template,
    required this.onTap,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final ex = template.exercises;
    final names = ex
        .take(3)
        .map((e) => (e['name'] as String? ?? '').trim())
        .where((n) => n.isNotEmpty)
        .join(', ');
    final more = ex.length > 3 ? '...' : '';
    final subtitle =
        names.isNotEmpty ? names + more : '${ex.length} exercises';

    final tile = InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    template.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Colors.white38),
          ],
        ),
      ),
    );

    if (!highlight) return tile;

    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: cs.secondary, width: 1.5),
        borderRadius: BorderRadius.circular(4),
        boxShadow: [
          BoxShadow(
            color: cs.secondary.withValues(alpha: 0.30),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 6, 28, 0),
            child: Text(
              'Tap to start first workout',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: cs.secondary,
              ),
            ),
          ),
          tile,
        ],
      ),
    );
  }
}
