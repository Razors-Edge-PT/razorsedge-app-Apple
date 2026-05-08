import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../template_model.dart';

/// Modal bottom sheet that lists the user's templates and pops the
/// selected templateId, or null if dismissed.
class Wes2TemplatePicker extends StatefulWidget {
  final String uid;
  const Wes2TemplatePicker({super.key, required this.uid});

  @override
  State<Wes2TemplatePicker> createState() => _Wes2TemplatePickerState();
}

class _Wes2TemplatePickerState extends State<Wes2TemplatePicker> {
  late final Future<List<Template>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Template>> _load() async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.uid)
        .collection('templates')
        .orderBy('name')
        .get();
    return snap.docs
        .map((d) => Template.fromFirestore(d.data(), d.id))
        .where((t) => t.exercises.any((e) =>
            ((e['exerciseId'] ?? e['id']) as String? ?? '').isNotEmpty))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
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
                  constraints: const BoxConstraints.tightFor(
                      width: 36, height: 36),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<Template>>(
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
                final templates = snapshot.data ?? [];
                if (templates.isEmpty) {
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
                return ListView.builder(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: templates.length,
                  itemBuilder: (_, i) => _TemplateListTile(
                    template: templates[i],
                    onTap: () => Navigator.of(context).pop(templates[i].id),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TemplateListTile extends StatelessWidget {
  final Template template;
  final VoidCallback onTap;
  const _TemplateListTile({required this.template, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ex = template.exercises;
    final names = ex
        .take(3)
        .map((e) => (e['name'] as String? ?? '').trim())
        .where((n) => n.isNotEmpty)
        .join(', ');
    final more = ex.length > 3 ? '...' : '';
    final subtitle = names.isNotEmpty
        ? names + more
        : '${ex.length} exercises';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
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
                    style: const TextStyle(
                        fontSize: 12, color: Colors.white54),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18,
                color: Colors.white38),
          ],
        ),
      ),
    );
  }
}
