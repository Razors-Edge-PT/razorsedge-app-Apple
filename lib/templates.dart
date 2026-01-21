import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'block_repository.dart'; // 👈 to get active block id + meta
import 'template_bootstrapper.dart';
import 'create_new_account_screen.dart';
import 'main.dart';

// Import the shared methods
import 'create_template_screen.dart';
import 'template_details.dart';
import 'template_model.dart'; // Import Exercise model
import 'package:provider/provider.dart';
import 'user_context.dart';

class _DraggedExercise {
  final String sourceTemplateId;
  final int sourceIndex;

  _DraggedExercise({
    required this.sourceTemplateId,
    required this.sourceIndex,
  });
}

class _DraggedTemplateCard {
  final String templateId;
  final String? fromBlockId;
  _DraggedTemplateCard({
    required this.templateId,
    required this.fromBlockId,
  });
}


class TemplatesScreen extends StatefulWidget {
  const TemplatesScreen({super.key, this.fromWorkoutPage = false});

  final bool
      fromWorkoutPage; // Add flag to determine if navigated from WorkoutPage


  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> {
  List<Template> templates = [];
  QuerySnapshot<Map<String, dynamic>>? templateSnapshot;

  // which template cards are currently expanded
  final Set<String> _expandedTemplateIds = {};

  // 🔁 block-aware grouping
  String? _activeBlockId;
  final Map<String, Map<String, dynamic>> _blockMetaById = {}; // blockId -> {startDate, endDate, name?}
  final Map<String, String?> _templateBlockIds = {}; // templateId -> blockId (from Firestore, may be null)

  // which block groups are expanded (we always show active)
  bool _showPreviousBlocks = false;
  bool _showUpcomingBlocks = false;
  bool _showActiveBlock = true;
  bool _plannedOnly = true;

  final Set<String> _expandedPreviousBlockIds = {}; // for per-block expansion
  final Set<String> _expandedUpcomingBlockIds = {};

  bool _loadingBlocks = true;

  // when you hover/drop we can give a little highlight
  String? _draggingOverTemplateId;
  // template.id -> extra circuit indices that have no exercises yet
  final Map<String, Set<int>> _extraEmptyCircuits = {};


  final _formKey = GlobalKey<FormState>();
  final String _templateName = '';
  final String _templateDay = '';
  final List<String> _selectedExercises = []; // List of selected exercise IDs
  Template? _lastDeletedTemplate;

  String get userId => UserContext.of(context, listen: false).currentUid;

  @override
  void initState() {
    super.initState();
    _loadBlocksThenTemplates();
  }

  Future<void> editTemplateName(Template template) async {
    final controller = TextEditingController(text: template.name);

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename workout'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => Navigator.of(ctx).pop(controller.text),
          decoration: const InputDecoration(hintText: 'Workout name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    final newName = (result ?? '').trim();
    if (newName.isEmpty || newName == template.name) return;

    // ✅ Update local UI (master list)
    setState(() {
      final i = templates.indexWhere((t) => t.id == template.id);
      if (i != -1) {
        templates[i].name = newName; // assumes Template.name is mutable (most common in your codebase)
      } else {
        template.name = newName;
      }
    });

    // ✅ Persist to Firestore (same user switching system you’re using elsewhere)
    final uid = UserContext.of(context, listen: false).currentUid;

    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('templates')
        .doc(template.id)
        .update({'name': newName});
  }


  Future<void> _showExercisePickerDialogForTemplate(Template template) async {
    // 1) load planned exercise ids (for planned-only toggle)
    Set<String> plannedExerciseIds = {};
    bool plannedModeAvailable = false;

    try {
      if (_activeBlockId != null) {
        final plannedDoc = await FirebaseFirestore.instance
            .collection('planned_blocks')
            .doc(userId)
            .collection('blocks')
            .doc(_activeBlockId!)
            .get();

        final List<dynamic> plannedList =
            plannedDoc.data()?['plannedExercises'] ?? [];
        plannedExerciseIds = plannedList.cast<String>().toSet();
        plannedModeAvailable = plannedExerciseIds.isNotEmpty;
      }
    } catch (_) {
      plannedModeAvailable = false;
    }

    // 2) load all exercises
    final snapshot =
    await FirebaseFirestore.instance.collection('exercises').get();

    final allExercises = snapshot.docs.map((doc) {
      final data = doc.data();
      return <String, String>{
        'id': doc.id,
        'name': (data['name'] ?? '').toString(),
        'category': (data['category'] ?? 'Other').toString(),
      };
    }).toList();


    bool showPlannedOnly = plannedModeAvailable; // default ON if available
    String searchQuery = '';
    final Map<String, bool> expandedGroups = {};

    final List<Map<String, String>>? selected =
    await showDialog<List<Map<String, String>>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (context, setLocalState) {
          // Planned-only filter
          final filteredExercises =
          (showPlannedOnly && plannedModeAvailable)
              ? allExercises
              .where((ex) => plannedExerciseIds.contains(ex['id']))
              .toList()
              : allExercises;

          // Search filter
          final searched = searchQuery.isNotEmpty
              ? filteredExercises
              .where((ex) =>
              ex['name']!.toLowerCase().contains(searchQuery))
              .toList()
              : filteredExercises;

          // Group by category when not searching
          Map<String, List<Map<String, String>>> grouped = {};
          if (searchQuery.isEmpty) {
            for (final ex in searched) {
              final cat = ex['category'] ?? 'Other';
              grouped.putIfAbsent(cat, () => []).add(ex);
            }
            for (final g in grouped.values) {
              g.sort((a, b) =>
                  a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));
            }
          }

          const categoryOrder = [
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
            'Other',
          ];

          final Map<String, List<Map<String, String>>> orderedGrouped = {};
          for (final cat in categoryOrder) {
            if (grouped.containsKey(cat)) orderedGrouped[cat] = grouped[cat]!;
          }
          for (final entry in grouped.entries) {
            if (!orderedGrouped.containsKey(entry.key)) {
              orderedGrouped[entry.key] = entry.value;
            }
          }

          for (final category in orderedGrouped.keys) {
            expandedGroups.putIfAbsent(category, () => false);
          }

          List<Widget> buildList() {
            if (searchQuery.isNotEmpty) {
              // flat list when searching
              return searched
                  .map((ex) => ListTile(
                title: Text(
                  ex['name']!,
                  style: const TextStyle(color: Colors.white70),
                ),
                dense: true,
                contentPadding:
                const EdgeInsets.symmetric(horizontal: 10),
                onTap: () => Navigator.pop(ctx, [ex]),
              ))
                  .toList();
            }

            // grouped list when no search
            return orderedGrouped.entries.map((entry) {
              final category = entry.key;
              final exercises = entry.value;
              final isExpanded = expandedGroups[category] ?? false;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    tileColor: Colors.blueGrey.shade800,
                    title: Text(
                      category,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    trailing: Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.white70,
                    ),
                    onTap: () => setLocalState(
                            () => expandedGroups[category] = !isExpanded),
                  ),
                  if (isExpanded)
                    ...exercises.map((ex) => ListTile(
                      title: Text(
                        ex['name']!,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      dense: true,
                      contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10),
                      onTap: () => Navigator.pop(ctx, [ex]),
                    )),
                  const Divider(height: 10, color: Colors.grey),
                ],
              );
            }).toList();
          }

          return AlertDialog(
            backgroundColor: Colors.blueGrey.shade900,
            insetPadding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
            contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Select Exercise",
                    style: TextStyle(fontSize: 13, color: Colors.white)),
                if (plannedModeAvailable)
                  Row(
                    children: [
                      Text(
                        showPlannedOnly ? "Planned Only" : "All Exercises",
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white70),
                      ),
                      Switch(
                        value: showPlannedOnly,
                        activeColor: Colors.lightBlueAccent,
                        onChanged: (value) => setLocalState(
                                () => showPlannedOnly = value),
                      ),
                    ],
                  )
                else
                  const SizedBox(),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10.0),
                    child: TextField(
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Search exercises...',
                        hintStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Colors.blueGrey.shade800,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8.0)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10.0, vertical: 10.0),
                      ),
                      onChanged: (val) => setLocalState(
                              () => searchQuery = val.toLowerCase()),
                    ),
                  ),
                  Expanded(
                    child: ListView(children: buildList()),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Cancel'),
              ),
            ],
          );
        });
      },
    );


    if (selected == null || selected.isEmpty) return;

    // 2) figure out the last circuit for this template
    final circuits = _getCircuitIndices(template);
    final lastCircuit = circuits.isEmpty ? 0 : circuits.last;

    // 3) append to template + persist
    setState(() {
      for (final ex in selected) {
        template.exercises.add({
          'id': ex['id'],
          'name': ex['name'],
          'category': ex['category'] ?? '',
          'circuitIndex': lastCircuit,
        });
      }
    });

    await _saveTemplateExercises(
      template.id,
      List<Map<String, dynamic>>.from(template.exercises),
    );
  }

  Future<void> _showExercisePickerDialogForChip(
      Template template,
      int exerciseIndex,
      ) async {

    // ---- Planned-only support (safe-guarded)
    Set<String> plannedExerciseIds = {};
    bool plannedModeAvailable = false;

    try {
      if (_activeBlockId != null) {
        final plannedDoc = await FirebaseFirestore.instance
            .collection('planned_blocks')
            .doc(userId)
            .collection('blocks')
            .doc(_activeBlockId!)
            .get();

        final List<dynamic> plannedList =
            plannedDoc.data()?['plannedExercises'] ?? [];
        plannedExerciseIds = plannedList.cast<String>().toSet();
        plannedModeAvailable = plannedExerciseIds.isNotEmpty;
      }
    } catch (_) {
      plannedModeAvailable = false;
    }

    // ---- Load all exercises
    final snapshot =
    await FirebaseFirestore.instance.collection('exercises').get();

    final allExercises = snapshot.docs.map((doc) {
      final data = doc.data();
      return <String, String>{
        'id': doc.id,
        'name': (data['name'] ?? '').toString(),
        'category': (data['category'] ?? 'Other').toString(),
      };
    }).toList();

    bool showPlannedOnly = plannedModeAvailable; // default ON if available
    String searchQuery = '';
    final Map<String, bool> expandedGroups = {};

    final selected = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (context, setLocalState) {
          // 1) Planned-only filter
          final filteredExercises = (showPlannedOnly && plannedModeAvailable)
              ? allExercises
              .where((ex) => plannedExerciseIds.contains(ex['id']))
              .toList()
              : allExercises;

          // 2) Search filter
          final searched = searchQuery.isNotEmpty
              ? filteredExercises
              .where((ex) =>
              ex['name']!.toLowerCase().contains(searchQuery))
              .toList()
              : filteredExercises;

          // 3) Group by category (only when not searching)
          Map<String, List<Map<String, String>>> grouped = {};
          if (searchQuery.isEmpty) {
            for (final ex in searched) {
              final cat = ex['category'] ?? 'Other';
              grouped.putIfAbsent(cat, () => []).add(ex);
            }
            for (final g in grouped.values) {
              g.sort((a, b) =>
                  a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));
            }
          }

          const categoryOrder = [
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
            'Other',
          ];

          final Map<String, List<Map<String, String>>> orderedGrouped = {};
          for (final cat in categoryOrder) {
            if (grouped.containsKey(cat)) orderedGrouped[cat] = grouped[cat]!;
          }
          for (final entry in grouped.entries) {
            if (!orderedGrouped.containsKey(entry.key)) {
              orderedGrouped[entry.key] = entry.value;
            }
          }

          for (final category in orderedGrouped.keys) {
            expandedGroups.putIfAbsent(category, () => false);
          }

          List<Widget> buildList() {
            if (searchQuery.isNotEmpty) {
              // flat list when searching
              return searched
                  .map((ex) => ListTile(
                title: Text(
                  ex['name']!,
                  style: const TextStyle(color: Colors.white70),
                ),
                dense: true,
                contentPadding:
                const EdgeInsets.symmetric(horizontal: 10),
                onTap: () => Navigator.pop(ctx, ex),
              ))
                  .toList();
            }

            // grouped list when no search
            return orderedGrouped.entries.map((entry) {
              final category = entry.key;
              final exercises = entry.value;
              final isExpanded = expandedGroups[category] ?? false;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    tileColor: Colors.blueGrey.shade800,
                    title: Text(
                      category,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    trailing: Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.white70,
                    ),
                    onTap: () => setLocalState(
                            () => expandedGroups[category] = !isExpanded),
                  ),
                  if (isExpanded)
                    ...exercises.map((ex) => ListTile(
                      title: Text(
                        ex['name']!,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      dense: true,
                      contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10),
                      onTap: () => Navigator.pop(ctx, ex),
                    )),
                  const Divider(height: 10, color: Colors.grey),
                ],
              );
            }).toList();
          }

          return AlertDialog(
            backgroundColor: Colors.blueGrey.shade900,
            insetPadding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
            contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Select Exercise",
                    style: TextStyle(fontSize: 13, color: Colors.white)),
                if (plannedModeAvailable)
                  Row(
                    children: [
                      Text(
                        showPlannedOnly ? "Planned Only" : "All Exercises",
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white70),
                      ),
                      Switch(
                        value: showPlannedOnly,
                        activeColor: Colors.lightBlueAccent,
                        onChanged: (value) => setLocalState(
                                () => showPlannedOnly = value),
                      ),
                    ],
                  )
                else
                  const SizedBox(),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10.0),
                    child: TextField(
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Search exercises...',
                        hintStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Colors.blueGrey.shade800,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8.0)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10.0, vertical: 10.0),
                      ),
                      onChanged: (val) => setLocalState(
                              () => searchQuery = val.toLowerCase()),
                    ),
                  ),
                  Expanded(
                    child: ListView(children: buildList()),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Cancel'),
              ),
            ],
          );
        });
      },
    );

    if (selected == null) return;

    final oldCircuitIndex =
        template.exercises[exerciseIndex]['circuitIndex'] ?? 0;

    setState(() {
      template.exercises[exerciseIndex] = {
        'id': selected['id'],
        'name': selected['name'],
        'category': selected['category'] ?? '',
        'circuitIndex': oldCircuitIndex, // ✅ keep same circuit
      };
    });

    await _saveTemplateExercises(
      template.id,
      List<Map<String, dynamic>>.from(template.exercises),
    );
  }



  void _createTemplate() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CreateTemplateScreen(
          onTemplateCreated: _fetchTemplates, // Pass the refresh function

        ),
      ),
    );
  }

  Future<void> _regenerateAllTemplates() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('🚫 No user logged in')),
      );
      return;
    }


    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Regenerate templates?'),
        content: const Text(
          'This will delete all current templates for this user and rebuild them from your onboarding settings.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Regenerate')),
        ],
      ),
    ) ?? false;

    if (!ok) return;

    try {
      setState(() => _loadingBlocks = true);

      final db = FirebaseFirestore.instance;
      final userRef = db.collection('users').doc(uid);
      final templatesCol = userRef.collection('templates');

      // 1️⃣ Delete existing templates in batches
      while (true) {
        final snap = await templatesCol.limit(300).get();
        if (snap.docs.isEmpty) break;
        final batch = db.batch();
        for (final d in snap.docs) {
          batch.delete(d.reference);
        }
        await batch.commit();
      }

      // 2️⃣ Clear the bootstrap flag(s) (keep both for backward compatibility)
      await userRef.set({
        'templatesBootstrapped_v1': FieldValue.delete(),
        'templatesBootstrapped': FieldValue.delete(), // older field if it exists anywhere
      }, SetOptions(merge: true));



      // 3️⃣ Force-run the generator path (respect planned-only toggle)
      await TemplatesBootstrapper.ensureInitialTemplatesForUser(
        uid,
        force: true,
        plannedOnly: _plannedOnly, // 🧩 new
      );


      // 4️⃣ ✅ Refresh your UI list using your actual method
      await _fetchTemplates();

      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Templates regenerated successfully ✅')),
      );

    } catch (e, st) {
      debugPrint('❌ regenerate failed: $e\n$st');
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Regenerate failed: $e')),
      );

    }
    finally {
      if (mounted) setState(() => _loadingBlocks = false);
    }
  }

  Future<void> _openEditFitnessPreferencesFromTemplates() async {
    debugPrint('🧭 [Templates] Edit Training Preferences tapped');

    try {
      // Prefer actingAsUid (coach mode) else current user
      final actingUid = Provider.of<UserContext>(context, listen: false).currentUid;
// or equivalently: final actingUid = context.read<UserContext>().currentUid;

      final db = FirebaseFirestore.instance;

      String? sex;
      String? dob;

      try {
        final snap = await db.collection('users').doc(actingUid).get();
        final data = snap.data();
        sex = data?['sex']?.toString();
        dob = data?['dob']?.toString(); // e.g. "dd-mm-yyyy" (your UI already handles both)
        debugPrint('🧭 [Templates] Loaded profile for $actingUid → sex=$sex, dob=$dob');
      } catch (e) {
        debugPrint('⚠️ [Templates] Could not prefetch sex/dob: $e');
        // continue; screen will degrade labels gracefully
      }

      final email = FirebaseAuth.instance.currentUser?.email ?? '';

      // Navigate to the existing onboarding page in edit mode
      debugPrint('🚪 [Templates] Pushing OnboardingPageTwo (entryFrom=templates)');
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => OnboardingPageTwo(
            email: email,
            password: 'edit-mode', // harmless in logged-in flow
            sex: sex,
            username: null,
            fullName: null,
            dob: dob,
          ),
          // IMPORTANT: do not use `const` here because the map isn't const
          settings: RouteSettings(
            arguments: {'entryFrom': 'templates'},
          ),
        ),
      );

      debugPrint('✅ [Templates] Returned from Edit Training Preferences');
    } catch (e, st) {
      debugPrint('❌ [Templates] openEditFitnessPreferences failed: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t open Training Preferences.')),
      );
    }
  }



  Future<void> _loadBlocksThenTemplates() async {
    // 1) get active block id (same source of truth as BB2/BP)
    String? activeId;
    try {
      activeId = await BlockRepository().fetchActiveBlockId(userId);

    } catch (e) {
      debugPrint('⚠️ [Templates] Could not fetch active block id: $e');
    }

    // 2) load block meta (dates) → we show under the headers
    final uid = userId;
    final blocksSnap = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .get();
    debugPrint('📦 [Templates] blocksSnap.docs=${blocksSnap.docs.length} for uid=$uid');
    for (final d in blocksSnap.docs) {
      final data = d.data();
      debugPrint('🧱 [Templates] blockId=${d.id} keys=${data.keys.toList()} name=${data['name']} isActive=${data['isActive']}');
      final bm = data['blockMeta'];
      if (bm is Map) {
        debugPrint('   ↳ blockMeta keys=${bm.keys.toList()} start=${bm['blockStartDate']} end=${bm['blockEndDate']}');
      }
    }
    debugPrint('⭐ [Templates] activeId(from BlockRepository)=$activeId');


    final meta = <String, Map<String, dynamic>>{};
    for (final doc in blocksSnap.docs) {
      final data = doc.data();
      meta[doc.id] = data;
    }

    // 3) load templates (as before)
    await _fetchTemplates();

    // 4) commit to state
    setState(() {
      _activeBlockId = activeId;
      _blockMetaById.clear();
      _blockMetaById.addAll(meta);
      _loadingBlocks = false;
    });
  }


  Future<void> _fetchTemplates() async {
    final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
    templateSnapshot = await userDoc.collection('templates').get();

    if (templateSnapshot != null) {
      print("📦 Raw Firestore template snapshot: ${templateSnapshot!.docs.length} templates");

      final templateList = templateSnapshot!.docs.map((doc) {
        final rawExercises = doc.get('exercises');

        final parsedExercises = rawExercises is List && rawExercises.isNotEmpty
            ? (rawExercises.first is Map
            ? List<Map<String, dynamic>>.from(rawExercises)
            : List<Map<String, dynamic>>.from(
            (rawExercises).map((e) => {'name': e, 'circuitIndex': 0})))
            : <Map<String, dynamic>>[];

        // 👇 read blockId if it exists on the template doc
        final String? blockIdFromDoc =
        doc.data().containsKey('blockId') ? (doc.get('blockId') as String?) : null;

// store in side map so we can group later
        _templateBlockIds[doc.id] = blockIdFromDoc;

        return Template(
          id: doc.id,
          name: doc.get('name') ?? 'Unnamed',
          day: doc.data().containsKey('day') ? doc.get('day') : null,
          exercises: parsedExercises,
          blockId: blockIdFromDoc, // ✅ add this line so the Template itself keeps it
        );

      }).toList();


      setState(() {
        templates = templateList;
        print("✅ Parsed templates: ${templates.length}");
        for (final t in templates) {
          debugPrint('🧾 tmpl "${t.name}" id=${t.id} blockId=${_templateBlockIds[t.id]} assign=${t.blockId}');
        }

      });
    }
  }

  int _extractDayNumberFromName(String name) {
    final lower = name.toLowerCase();
    final match = RegExp(r'day\s*(\d+)').firstMatch(lower);
    if (match != null) {
      final n = int.tryParse(match.group(1)!);
      if (n != null) return n;
    }
    // If we can't find a day number, push it to the end
    return 9999;
  }


  List<Template> _templatesForBlock(String? blockId) {
    if (blockId == null) return const [];

    final blockMeta = _blockMetaById[blockId];
    final blockName = blockMeta != null && (blockMeta['name'] is String)
        ? (blockMeta['name'] as String).trim()
        : null;

    final results = templates.where((t) {
      final tmplBlockId = _templateBlockIds[t.id]?.trim();
      if (tmplBlockId == blockId) return true;

      // ✅ fallback: match by blockAssignment name when ids are wrong/legacy
      final assign = (t.blockAssignment ?? '').trim();
      return blockName != null && assign.isNotEmpty && assign == blockName;
    }).toList();

    results.sort((a, b) {
      final dayA = _extractDayNumberFromName(a.name);
      final dayB = _extractDayNumberFromName(b.name);
      if (dayA != dayB) return dayA.compareTo(dayB);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return results;
  }




  List<Template> get _templatesWithoutBlock {
    return templates.where((t) => _templateBlockIds[t.id] == null).toList();
  }



  void _toggleExpanded(String templateId) {
    setState(() {
      if (_expandedTemplateIds.contains(templateId)) {
        _expandedTemplateIds.remove(templateId);
      } else {
        _expandedTemplateIds.add(templateId);
      }
    });
  }

  // collect all circuit indices used in this template, sorted
  List<int> _getCircuitIndices(Template template) {
    final set = <int>{};
    for (final ex in template.exercises) {
      final ci = (ex['circuitIndex'] ?? 0) as int;
      set.add(ci);
    }

    // also include explicit empty circuits we created via "+ Add circuit"
    final extra = _extraEmptyCircuits[template.id];
    if (extra != null) {
      set.addAll(extra);
    }

    final list = set.toList()..sort();
    return list.isEmpty ? [0] : list;
  }

  bool _isCircuitEmpty(Template template, int circuitIndex) {
    // if any real exercise uses this circuit, it's not empty
    final hasExercise = template.exercises.any(
          (ex) => (ex['circuitIndex'] ?? 0) == circuitIndex,
    );
    if (hasExercise) return false;

    // if it's one of our extra circuits, and has no exercises → it's empty
    final extra = _extraEmptyCircuits[template.id];
    if (extra != null && extra.contains(circuitIndex)) {
      return true;
    }

    return false;
  }

  void _removeEmptyCircuitForTemplate(Template template, int circuitIndex) {
    setState(() {
      final extra = _extraEmptyCircuits[template.id];
      if (extra != null) {
        extra.remove(circuitIndex);
        if (extra.isEmpty) {
          _extraEmptyCircuits.remove(template.id);
        }
      }
      // no Firestore write needed – there were no exercises to persist
    });
  }



  // given a GLOBAL index (position in template.exercises), tell me this exercise's position INSIDE its circuit
  int _positionInCircuit(Template template, int circuitIndex, int globalIndex) {
    int count = 0;
    for (int i = 0; i < template.exercises.length; i++) {
      final ex = template.exercises[i];
      if ((ex['circuitIndex'] ?? 0) == circuitIndex) {
        if (i == globalIndex) return count;
        count++;
      }
    }
    return count;
  }

  // find the GLOBAL index where we should insert something into the given circuit at the given circuit-position
  int _findGlobalInsertIndexForCircuit(
      Template template, {
        required int circuitIndex,
        required int positionInCircuit,
      }) {
    int seen = 0;
    for (int i = 0; i < template.exercises.length; i++) {
      final ex = template.exercises[i];
      final ci = (ex['circuitIndex'] ?? 0) as int;
      if (ci != circuitIndex) continue;

      // we've reached the correct spot inside this circuit
      if (seen == positionInCircuit) {
        return i;
      }
      seen++;
    }

    // if we got here: we want to append to the END of that circuit
    final lastIndexOfCircuit = template.exercises.lastIndexWhere(
          (ex) => (ex['circuitIndex'] ?? 0) == circuitIndex,
    );

    if (lastIndexOfCircuit == -1) {
      // circuit is currently empty → just dump at end of whole list
      return template.exercises.length;
    }

    return lastIndexOfCircuit + 1;
  }

  void _addEmptyCircuitForTemplate(Template template) {
    setState(() {
      final existing = _getCircuitIndices(template);
      final newCircuitIndex = (existing.isEmpty ? 0 : (existing.last + 1));
      _extraEmptyCircuits.putIfAbsent(template.id, () => <int>{}).add(newCircuitIndex);
      // no Firestore write yet — we persist when an exercise is dropped/added
    });
  }

  void _deleteExerciseFromDragged(_DraggedExercise dragged) {
    setState(() {
      final sourceTemplate = templates.firstWhere((t) => t.id == dragged.sourceTemplateId);
      if (dragged.sourceIndex < 0 || dragged.sourceIndex >= sourceTemplate.exercises.length) {
        return;
      }
      sourceTemplate.exercises.removeAt(dragged.sourceIndex);

      // persist
      _saveTemplateExercises(
        sourceTemplate.id,
        List<Map<String, dynamic>>.from(sourceTemplate.exercises),
      );
    });
  }




  String _fmtDate(dynamic ts) {
    if (ts == null) return '';

    if (ts is Timestamp) {
      final d = ts.toDate();
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }

    // if it's an ISO string like "2026-01-12T00:00:00.000"
    if (ts is String) {
      final d = DateTime.tryParse(ts);
      if (d != null) {
        return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      }
    }

    return ts.toString();
  }


  String _blockTitle(String blockId, Map<String, dynamic> meta) {
    if (meta.containsKey('name') && (meta['name'] as String).isNotEmpty) {
      return meta['name'] as String;
    }
    return 'Block $blockId';
  }


  Future<void> _reassignTemplateToBlock({
    required String templateId,
    required String? newBlockId,
  }) async {
    final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
    final templateRef = userDoc.collection('templates').doc(templateId);

    await templateRef.update({
      'blockId': newBlockId,
    });

    setState(() {
      _templateBlockIds[templateId] = newBlockId;
    });
  }


  Future<void> _saveTemplateExercises(String templateId, List<Map<String, dynamic>> exercises) async {
    final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
    await userDoc.collection('templates').doc(templateId).update({
      'exercises': exercises,
    });
  }

  void _moveExerciseToCircuit({
    required String targetTemplateId,
    required int targetCircuitIndex,
    required int targetPositionInCircuit,
    required _DraggedExercise dragged,
  }) {
    setState(() {
      // 1) source template + exercise
      final sourceTemplate = templates.firstWhere((t) => t.id == dragged.sourceTemplateId);
      final movedExercise = sourceTemplate.exercises.removeAt(dragged.sourceIndex);

      // 2) target template
      final targetTemplate = templates.firstWhere((t) => t.id == targetTemplateId);

      // 3) change the exercise's circuit to the target circuit
      movedExercise['circuitIndex'] = targetCircuitIndex;

      // 4) find CORRECT global insertion index inside target template
      final insertAt = _findGlobalInsertIndexForCircuit(
        targetTemplate,
        circuitIndex: targetCircuitIndex,
        positionInCircuit: targetPositionInCircuit,
      );

      targetTemplate.exercises.insert(insertAt, movedExercise);

      // 5) clear highlight
      _draggingOverTemplateId = null;

      // 6) persist
      _saveTemplateExercises(
        sourceTemplate.id,
        List<Map<String, dynamic>>.from(sourceTemplate.exercises),
      );

      // if moved across templates, persist target too
      if (sourceTemplate.id != targetTemplate.id) {
        _saveTemplateExercises(
          targetTemplate.id,
          List<Map<String, dynamic>>.from(targetTemplate.exercises),
        );
      } else {
        // same template but order changed
        _saveTemplateExercises(
          targetTemplate.id,
          List<Map<String, dynamic>>.from(targetTemplate.exercises),
        );
      }
    });
  }

  Widget _buildActiveBlockHeader() {
    final blockId = _activeBlockId;
    final meta = blockId != null ? _blockMetaById[blockId] : null;

    String subtitle = '';
    if (meta != null) {
      final bm = meta['blockMeta'];
      final start = (bm is Map) ? bm['blockStartDate'] : null;
      final end = (bm is Map) ? bm['blockEndDate'] : null;

      if (start != null && end != null) {
        subtitle = '${_fmtDate(start)} → ${_fmtDate(end)}';
      } else if (start != null) {
        subtitle = 'from ${_fmtDate(start)}';
      }

    }

    return DragTarget<_DraggedTemplateCard>(
      onWillAccept: (data) => true,
      onAccept: (data) async {
        await _reassignTemplateToBlock(
          templateId: data.templateId,
          newBlockId: _activeBlockId,
        );
      },
      builder: (context, candidate, rejected) {
        final isDrop = candidate.isNotEmpty;
        return InkWell(
          onTap: () {
            setState(() {
              _showActiveBlock = !_showActiveBlock;
            });
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            decoration: BoxDecoration(
              color: isDrop
                  ? Colors.blueGrey.shade600.withOpacity(0.25)
                  : Colors.blueGrey.shade900.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isDrop ? Colors.cyanAccent.withOpacity(0.5) : Colors.white10,
                width: 0.6,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _showActiveBlock ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: Colors.cyanAccent.shade100,
                ),
                const SizedBox(width: 4),

                // 🔽 LEFT SIDE (takes ALL available space)
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Active block${(blockId != null && meta != null) ? ': ${_blockTitle(blockId, meta)}' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                          ),
                        ),
                      ),

                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(width: 6),

                // 🔽 RIGHT SIDE (fixed width)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.tealAccent.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.tealAccent.withOpacity(0.25),
                      width: 0.4,
                    ),
                  ),
                  child: const Text(
                    'current',
                    style: TextStyle(
                      color: Colors.tealAccent,
                      fontSize: 9.8,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),

          ),
        );
      },
    );
  }




  Widget _buildActiveBlockTemplatesList() {
    // templates tied to the active block
    final activeBlockTemplates =
    _activeBlockId != null ? _templatesForBlock(_activeBlockId) : <Template>[];

    // only those tied to the active block
    final allToShow = activeBlockTemplates;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 🔹 Active block templates (reorderable)
            if (allToShow.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12.0),
                child: Center(
                  child: Text(
                    'No workouts in active block',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(), // ✔ outer scroll handles it
                itemCount: allToShow.length,
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) newIndex--;
                    final moved = allToShow.removeAt(oldIndex);
                    allToShow.insert(newIndex, moved);

                    // reflect in global list, simplest way:
                    templates
                      ..removeWhere((t) => t.id == moved.id)
                      ..insert(newIndex, moved);
                  });
                },
                buildDefaultDragHandles: false,
                itemBuilder: (context, index) {
                  final template = allToShow[index];
                  return _buildTemplateCard(template, index: index);
                },
              ),

            const SizedBox(height: 8),



            const SizedBox(height: 54),
          ],
        ),
      ),
    );
  }



  Widget _buildOtherTemplatesSection() {
    // Templates that are NOT shown inside any known block group.
    // Rule: if template has a valid blockId that exists in _blockMetaById -> it belongs to a block.
    // Otherwise it's an orphan/unassigned and must appear here.

    final otherTemplates = templates.where((t) {
      final bid = (_templateBlockIds[t.id])?.trim();

      // no block id at all
      if (bid == null || bid.isEmpty) return true;

      // block id exists but we don't have that block loaded (deleted/mismatched/legacy)
      final exists = _blockMetaById.containsKey(bid);
      if (!exists) return true;

      // otherwise it should appear under that block
      return false;
    }).toList();

    if (otherTemplates.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 8.0, bottom: 4.0),
          child: Text(
            'Other templates',
            style: TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: otherTemplates.length,
          itemBuilder: (context, index) {
            final template = otherTemplates[index];
            return _buildTemplateCard(template, index: index);
          },
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex--;
              final moved = otherTemplates.removeAt(oldIndex);
              otherTemplates.insert(newIndex, moved);

              templates
                ..removeWhere((t) => t.id == moved.id)
                ..insert(newIndex, moved);
            });
          },
        ),
      ],
    );
  }





  Widget _buildTemplateCard(Template template, {int? index}) {
    return ReorderableDelayedDragStartListener(
      index: index ?? 0,
      key: ValueKey(template.id),
      child: Dismissible(
        key: ValueKey('dismiss_${template.id}'),
        direction: DismissDirection.endToStart,
        confirmDismiss: (DismissDirection direction) async {
          return await _confirmDeleteTemplate(context, template.id);
        },
        background: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          color: Colors.red,
          child: const Icon(Icons.delete, color: Colors.white),
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.blueGrey.shade700,
            borderRadius: BorderRadius.circular(8),
            border: _draggingOverTemplateId == template.id
                ? Border.all(color: Colors.white60, width: 1)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ✅ paste your existing ListTile + expanded circuits here
              // (everything you had inside before)
              _buildTemplateHeaderRow(template),
              if (_expandedTemplateIds.contains(template.id))
                _buildTemplateExpandedBody(template),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTemplateHeaderRow(Template template) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal:2, vertical: 0),
      title: Text(
        template.name,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 15,
        ),
      ),
      subtitle: template.day != null
          ? Text(
        template.day!,
        style: const TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.w500,
          color: Colors.white70,
        ),
      )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [

          IconButton(
            icon: const Icon(Icons.edit, size: 15, color: Colors.white60),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => editTemplateName(template),
          ),
          const SizedBox(width: 0),


          // 🏁 cross-block drag handle
          LongPressDraggable<_DraggedTemplateCard>(
            data: _DraggedTemplateCard(
              templateId: template.id,
              fromBlockId: _templateBlockIds[template.id],
            ),
            feedback: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.shade300,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  template.name,
                  style: const TextStyle(fontSize: 11, color: Colors.black),
                ),
              ),
            ),
            child: const Padding(
              padding: EdgeInsets.only(right: 1.0),
              child: Icon(
                Icons.open_with,
                size: 16,
                color: Colors.white60,
              ),
            ),
          ),

          // 👇 show bin only when expanded
          if (_expandedTemplateIds.contains(template.id))
            _buildHeaderDeleteDropZone(template),

          // 👇 your + add exercise, only when expanded
          if (_expandedTemplateIds.contains(template.id))
            TextButton(
              onPressed: () => _showExercisePickerDialogForTemplate(template),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                '+ add exercise',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white,
                ),
              ),
            ),

          // 👇 expand/collapse arrow (always)
          IconButton(
            icon: Icon(
              _expandedTemplateIds.contains(template.id)
                  ? Icons.expand_less
                  : Icons.expand_more,
              color: Colors.white70,
              size: 20,
            ),
            onPressed: () => _toggleExpanded(template.id),
          ),
        ],
      ),

     // onTap: () => _navigateToTemplateDetails(context, template),
    );
  }

  Widget _buildTemplateExpandedBody(Template template) {
    return Padding(
      padding: const EdgeInsets.only(left: 9, right: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Builder(
            builder: (context) {
              final circuitIndices = _getCircuitIndices(template);
              final circuitCount = circuitIndices.length;

              const totalWidth = 330.0;
              final divisor = circuitCount == 1
                  ? 2
                  : (circuitCount >= 3 ? 3 : circuitCount);
              final columnWidth = totalWidth / divisor; // 165 or 110

              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (int i = 0; i < circuitIndices.length; i++)
                      SizedBox(
                        width: columnWidth,
                        child: Builder(
                          builder: (context) {
                            final circuitIndex = circuitIndices[i];
                            final isLast = i == circuitIndices.length - 1;

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // header row
                                Row(
                                  mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_isCircuitEmpty(
                                            template, circuitIndex))
                                          InkWell(
                                            onTap: () =>
                                                _removeEmptyCircuitForTemplate(
                                                  template,
                                                  circuitIndex,
                                                ),
                                            child: const Padding(
                                              padding:
                                              EdgeInsets.only(right: 4.0),
                                              child: Text(
                                                ' - ',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.white54,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                          ),
                                        Text(
                                          'Circuit ${circuitIndex + 1}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (isLast)
                                      InkWell(
                                        onTap: () =>
                                            _addEmptyCircuitForTemplate(template),
                                        child: const Padding(
                                          padding: EdgeInsets.only(left: 6.0),
                                          child: Text(
                                            '+ circuit',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.white70,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 4),

                                // exercises in this circuit
                                for (final entry
                                in template.exercises.asMap().entries)
                                  if ((entry.value['circuitIndex'] ?? 0) ==
                                      circuitIndex)
                                    _buildDraggableExerciseChip(
                                      template: template,
                                      exerciseIndex: entry.key,
                                    ),

                                // drop zone
                                _buildEndDropZone(
                                  template,
                                  circuitIndex: circuitIndex,
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }


  Widget _buildPreviousBlocksSection() {
    final List<Widget> blockWidgets = [];

    // active block date
    final activeMeta = _activeBlockId != null ? _blockMetaById[_activeBlockId] : null;
    final activeBm = activeMeta != null ? activeMeta['blockMeta'] : null;
    final activeStartStr = (activeBm is Map) ? activeBm['blockStartDate'] : null;
    final DateTime? activeStart =
    (activeStartStr is String) ? DateTime.tryParse(activeStartStr) : null;


    _blockMetaById.forEach((blockId, meta) {
      if (blockId == _activeBlockId) return;

      final bm = meta['blockMeta'];
      final startStr = (bm is Map) ? bm['blockStartDate'] : null;
      final DateTime? thisStart = (startStr is String) ? DateTime.tryParse(startStr) : null;


      // classify as previous
      final isPrevious = () {
        if (activeStart != null && thisStart != null) {
          return thisStart.isBefore(activeStart);
        }
        if (activeStart == null && thisStart == null) return true;
        if (activeStart != null && thisStart == null) return true;
        return false;
      }();

      if (!isPrevious) return;

      final templatesForThisBlock = _templatesForBlock(blockId);

      blockWidgets.add(
        DragTarget<_DraggedTemplateCard>(
          onWillAccept: (data) => true,
          onAccept: (data) async {
            await _reassignTemplateToBlock(
              templateId: data.templateId,
              newBlockId: blockId,
            );
          },
          builder: (context, candidate, rejected) {
            final isDrop = candidate.isNotEmpty;
            return Container(
              // 🔽 small indent, not 24
              margin: const EdgeInsets.only(left: 0, right: 1, bottom: 1),
              decoration: BoxDecoration(
                color: isDrop
                    ? Colors.blueGrey.shade700.withOpacity(0.25)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InkWell(
                    onTap: () {
                      setState(() {
                        if (_expandedPreviousBlockIds.contains(blockId)) {
                          _expandedPreviousBlockIds.remove(blockId);
                        } else {
                          _expandedPreviousBlockIds.add(blockId);
                        }
                      });
                    },
                    child: Padding(
                      // 🔽 very light padding to keep height same
                      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 2),
                      child: Row(
                        children: [
                          Icon(
                            _expandedPreviousBlockIds.contains(blockId)
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 14,
                            color: Colors.white54,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            _blockTitle(blockId, meta),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 6),

                          // ✅ UPDATED: read date from blockMeta.blockStartDate
                          if (meta['blockMeta'] is Map &&
                              (meta['blockMeta']['blockStartDate'] != null))
                            Text(
                              _fmtDate(meta['blockMeta']['blockStartDate']),
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                              ),
                            ),
                        ],
                      ),
                    ),

                  ),
                  if (_expandedPreviousBlockIds.contains(blockId))
                  // 🔽 NO extra left padding here so templates line up with active ones
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: templatesForThisBlock
                          .map(
                            (t) => Container(
                          margin: const EdgeInsets.only(bottom: 1),
                          child: _buildTemplateCard(t),
                        ),
                      )
                          .toList(),
                    ),
                ],
              ),
            );
          },
        ),
      );
    });

    return DragTarget<_DraggedTemplateCard>(
      onWillAccept: (data) => true,
      onAccept: (data) async {
        // optional
      },
      builder: (context, candidate, rejected) {
        final isDrop = candidate.isNotEmpty;
        return Container(
          // 🔽 slightly smaller margin so it hugs the card stack
          margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
          decoration: BoxDecoration(
            color: isDrop
                ? Colors.blueGrey.shade800.withOpacity(0.25)
                : Colors.blueGrey.shade900.withOpacity(0.02),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white10, width: 0.4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: () {
                  setState(() {
                    _showPreviousBlocks = !_showPreviousBlocks;
                  });
                },
                child: Row(
                  children: [
                    Icon(
                      _showPreviousBlocks ? Icons.expand_less : Icons.expand_more,
                      size: 15,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Previous blocks',
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (_showPreviousBlocks)
                (blockWidgets.isEmpty)
                    ? const Padding(
                  padding: EdgeInsets.only(left: 2, top: 3, bottom: 1),
                  child: Text(
                    'No previous blocks',
                    style: TextStyle(color: Colors.white30, fontSize: 11),
                  ),
                )
                    : Column(children: blockWidgets),
            ],
          ),
        );
      },
    );
  }



  Widget _buildUpcomingBlocksSection() {
    final List<Widget> blockWidgets = [];

    final activeMeta = _activeBlockId != null ? _blockMetaById[_activeBlockId] : null;
    final activeStartTs = activeMeta != null ? activeMeta['startDate'] : null;
    final DateTime? activeStart =
    (activeStartTs is Timestamp) ? activeStartTs.toDate() : null;

    _blockMetaById.forEach((blockId, meta) {
      if (blockId == _activeBlockId) return;

      final startTs = meta['startDate'];
      final DateTime? thisStart = (startTs is Timestamp) ? startTs.toDate() : null;

      final isUpcoming = () {
        if (activeStart != null && thisStart != null) {
          return thisStart.isAfter(activeStart);
        }
        if (activeStart == null && thisStart != null) {
          return true;
        }
        return false;
      }();

      if (!isUpcoming) return;

      final templatesForThisBlock = _templatesForBlock(blockId);

      blockWidgets.add(
        DragTarget<_DraggedTemplateCard>(
          onWillAccept: (data) => true,
          onAccept: (data) async {
            await _reassignTemplateToBlock(
              templateId: data.templateId,
              newBlockId: blockId,
            );
          },
          builder: (context, candidate, rejected) {
            final isDrop = candidate.isNotEmpty;
            return Container(
              // 🔽 was 24, now 12
              margin: const EdgeInsets.only(left: 0, right: 1, bottom: 1),
              decoration: BoxDecoration(
                color: isDrop
                    ? Colors.blueGrey.shade700.withOpacity(0.25)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InkWell(
                    onTap: () {
                      setState(() {
                        if (_expandedUpcomingBlockIds.contains(blockId)) {
                          _expandedUpcomingBlockIds.remove(blockId);
                        } else {
                          _expandedUpcomingBlockIds.add(blockId);
                        }
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            _expandedUpcomingBlockIds.contains(blockId)
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 14,
                            color: Colors.white54,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _blockTitle(blockId, meta),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 6),
                          if (meta['startDate'] != null)
                            Text(
                              _fmtDate(meta['startDate']),
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_expandedUpcomingBlockIds.contains(blockId))
                  // 🔽 no extra left padding → templates full width
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: templatesForThisBlock
                          .map(
                            (t) => Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          child: _buildTemplateCard(t),
                        ),
                      )
                          .toList(),
                    ),
                ],
              ),
            );
          },
        ),
      );
    });

    return DragTarget<_DraggedTemplateCard>(
      onWillAccept: (data) => true,
      onAccept: (data) async {},
      builder: (context, candidate, rejected) {
        final isDrop = candidate.isNotEmpty;
        return Container(
          // 🔽 match previous
          margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
          decoration: BoxDecoration(
            color: isDrop
                ? Colors.blueGrey.shade800.withOpacity(0.25)
                : Colors.blueGrey.shade900.withOpacity(0.02),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white10, width: 0.4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: () {
                  setState(() {
                    _showUpcomingBlocks = !_showUpcomingBlocks;
                  });
                },
                child: Row(
                  children: [
                    Icon(
                      _showUpcomingBlocks ? Icons.expand_less : Icons.expand_more,
                      size: 15,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Upcoming blocks',
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (_showUpcomingBlocks)
                (blockWidgets.isEmpty)
                    ? const Padding(
                  padding: EdgeInsets.only(left: 14, top: 3, bottom: 3),
                  child: Text(
                    'No upcoming blocks',
                    style: TextStyle(color: Colors.white30, fontSize: 11),
                  ),
                )
                    : Column(children: blockWidgets),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDraggableExerciseChip({
    required Template template,
    required int exerciseIndex, // GLOBAL index in template.exercises
  }) {
    final exercise = template.exercises[exerciseIndex];
    final name = (exercise['name'] ?? '').toString();
    final circuitIndex = (exercise['circuitIndex'] ?? 0) as int;

    // how far down in THIS circuit is this exercise?
    final positionInCircuit = _positionInCircuit(template, circuitIndex, exerciseIndex);

    return DragTarget<_DraggedExercise>(
      onWillAccept: (data) {
        setState(() {
          _draggingOverTemplateId = template.id;
        });
        return true;
      },
      onLeave: (_) {
        setState(() {
          _draggingOverTemplateId = null;
        });
      },
      onAccept: (data) {
        _moveExerciseToCircuit(
          targetTemplateId: template.id,
          targetCircuitIndex: circuitIndex,
          targetPositionInCircuit: positionInCircuit,
          dragged: data,
        );
      },
      builder: (context, candidate, rejected) {
        return LongPressDraggable<_DraggedExercise>(
          data: _DraggedExercise(
            sourceTemplateId: template.id,
            sourceIndex: exerciseIndex,
          ),
          feedback: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blueGrey.shade300,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                name,
                style: const TextStyle(fontSize: 11, color: Colors.black),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.35,
            child: GestureDetector(
              onTap: () => _showExercisePickerDialogForChip(template, exerciseIndex),
              child: _exerciseChipBody(name),
            ),
          ),
          child: GestureDetector(
            onTap: () => _showExercisePickerDialogForChip(template, exerciseIndex),
            child: _exerciseChipBody(name),
          ),

        );
      },
    );
  }


  Widget _exerciseChipBody(String name) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      margin: const EdgeInsets.only(right: 6, bottom: 6),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade500,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        name,
        style: const TextStyle(
          fontSize: 11,
          color: Colors.white,
          height: 1.1,
        ),
      ),
    );
  }
  Widget _buildEndDropZone(Template template, {required int circuitIndex}) {
    return DragTarget<_DraggedExercise>(
      onWillAccept: (data) {
        setState(() {
          _draggingOverTemplateId = template.id;
        });
        return true;
      },
      onLeave: (_) {
        setState(() {
          _draggingOverTemplateId = null;
        });
      },
      onAccept: (data) {
        // drop to END of this circuit
        final pos = 9999; // big number → _findGlobalInsertIndexForCircuit will append
        _moveExerciseToCircuit(
          targetTemplateId: template.id,
          targetCircuitIndex: circuitIndex,
          targetPositionInCircuit: pos,
          dragged: data,
        );
      },
      builder: (context, candidate, rejected) {
        final isActive = _draggingOverTemplateId == template.id && candidate.isNotEmpty;
        return Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          margin: const EdgeInsets.only(right: 6, bottom: 4, top: 2),
          decoration: BoxDecoration(
            color: isActive ? Colors.blueGrey.shade300.withOpacity(0.5) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isActive ? Colors.white54 : Colors.white24,
              width: isActive ? 1 : 0.5,
            ),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            isActive ? 'Drop to add here' : '+ add to circuit',
            style: TextStyle(
              fontSize: 10,
              color: isActive ? Colors.white : Colors.white38,
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeaderDeleteDropZone(Template template) {
    return DragTarget<_DraggedExercise>(
      onWillAccept: (data) => true,
      onAccept: (data) {
        _deleteExerciseFromDragged(data);
      },
      builder: (context, candidate, rejected) {
        final isActive = candidate.isNotEmpty;
        return Container(
          width: 30,
          height: 26,
          margin: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: isActive
                ? Colors.redAccent.withOpacity(0.45)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isActive ? Colors.redAccent : Colors.transparent,
              width: isActive ? 1 : 0.3,
            ),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.delete_outline,
            size: 14,
            color: isActive ? Colors.white : Colors.white54,
          ),
        );
      },
    );
  }




  Future<void> _undoDeleteTemplate() async {
    if (_lastDeletedTemplate == null) return;

    final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
    await userDoc.collection('templates').doc(_lastDeletedTemplate!.id).set({
      'name': _lastDeletedTemplate!.name,
      'exercises': _lastDeletedTemplate!.exercises,
      if (_lastDeletedTemplate!.day != null) 'day': _lastDeletedTemplate!.day,
    });

    setState(() {
      templates.add(_lastDeletedTemplate!);
      _lastDeletedTemplate = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✅ Template restored')),
    );
  }

  Future<bool> _confirmDeleteTemplate(BuildContext context, String templateId) async {
    final shouldDelete = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Delete'),
        content: Text('Are you sure you want to delete the template "${findTemplateName(templateId)}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (shouldDelete == true) {
      final deletedTemplate = templates.firstWhere((t) => t.id == templateId);
      _lastDeletedTemplate = deletedTemplate; // ✅ Save for undo
      await _deleteTemplateFromFirestore(templateId);
      setState(() {
        templates.removeWhere((t) => t.id == templateId);
      });
    }
    return shouldDelete ?? false;
  }

  Future<void> _confirmAndDeleteAllTemplates() async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete All Templates?'),
        content: const Text('This will permanently remove all saved templates. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete All', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (shouldDelete == true) {
      final batch = FirebaseFirestore.instance.batch();
      final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
      final templatesRef = userDoc.collection('templates');

      final snapshot = await templatesRef.get();
      for (var doc in snapshot.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();

      setState(() {
        templates.clear();
        _lastDeletedTemplate = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('All templates deleted.'),
          backgroundColor: Colors.red.shade400,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
        ),
      );
    }
  }




  String findTemplateName(String templateId) {
    // Find the template document using the doc ID from Firestore
    final matchingDoc =
        templateSnapshot?.docs.firstWhere((doc) => doc.id == templateId);

    // If a matching document is found, return the name
    if (matchingDoc != null) {
      return matchingDoc.get('name') as String;
    } else {
      // Handle missing template, return 'Unknown Template'
      return 'Unknown Template';
    }
  }

  Future<void> _deleteTemplateFromFirestore(String templateId) async {
    final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
    final templateRef = userDoc.collection('templates').doc(templateId);
    await templateRef.delete();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(

        title: const Text('Workout Planner'),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Undo Delete',
            onPressed: _lastDeletedTemplate != null ? _undoDeleteTemplate : null,
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever),
            tooltip: 'Delete All Templates',
            onPressed: _confirmAndDeleteAllTemplates,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Create Template',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => CreateTemplateScreen(
                    onTemplateCreated: _fetchTemplates,
                  ),
                ),
              );
            },
          ),
        ],
      ),

      body: Column(
        children: [
          const SizedBox(height: 1),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 9,
            runSpacing: 1,
            children: [
              // 🧩 Toggle Planned-Only Mode
              StatefulBuilder(
                builder: (context, setLocalState) {
                  return ElevatedButton.icon(
                    icon: Icon(
                      _plannedOnly ? Icons.checklist : Icons.list_alt,
                      size: 32, // ↓ smaller icon
                    ),
                    label: Text(
                      _plannedOnly ? "Planned Exercises" : "Wild Card",
                      style: const TextStyle(fontSize: 14), // ↓ slightly smaller text
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _plannedOnly
                          ? Colors.blueGrey.shade700
                          : Colors.pink.shade200,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), // ↓ tighter vertical padding
                      minimumSize: const Size(0, 28), // ✅ ensures button stays short
                      visualDensity: VisualDensity.compact, // ✅ reduces height slightly more
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: () {
                      setLocalState(() => _plannedOnly = !_plannedOnly);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(_plannedOnly
                              ? "Planned-only mode enabled"
                              : "All exercises enabled"),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                  );
                },
              ),

// 🔁 Regenerate Templates
              ElevatedButton.icon(
                icon: const Icon(
                  Icons.refresh,
                  size: 32,
                  color: Colors.cyanAccent, // 👈 cyan icon
                ),
                label: const Text(
                  "Regen",
                  style: TextStyle(fontSize: 13.5),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueGrey.shade700,
                  foregroundColor: Colors.white, // text stays white
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  minimumSize: const Size(0, 28),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: _regenerateAllTemplates,
              ),


              // ➕ Create New Workout (existing)
              ElevatedButton.icon(
                icon: const Icon(
                  Icons.add,
                  size: 32,
                  color: Colors.cyanAccent, // 👈 cyan accent icon
                ),
                label: const Text(
                  "Add New Workout",
                  style: TextStyle(fontSize: 14),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueGrey.shade700,
                  foregroundColor: Colors.white, // text stays white
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  minimumSize: const Size(0, 28),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: _createTemplate,
              ),

              const SizedBox(width: 1), // ✅ give them a bit more breathing room

// 🛠️ Edit Training Preferences (opens the existing onboarding page in edit mode)
              ElevatedButton.icon(
                icon: const Icon(Icons.settings, color: Colors.grey, size: 32),
                label: const Text(
                  "Edit Preferences",
                  style: TextStyle(fontSize: 14),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueGrey.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  minimumSize: const Size(0, 28),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _openEditFitnessPreferencesFromTemplates,
              ),


            ],
          ),

          const SizedBox(height: 2),

          // 👇 always show block sections (once blocks & templates loaded)
          if (_loadingBlocks)
            const Expanded(
              child: Center(
                child: CircularProgressIndicator(),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  // 🔹 Active block (own header + dropdown)
                  _buildActiveBlockHeader(),
                  const SizedBox(height: 4),
                  if (_showActiveBlock) _buildActiveBlockTemplatesList(),

                  const SizedBox(height: 8),

                  // 🔹 Previous blocks (independent section)
                  _buildPreviousBlocksSection(),

                  const SizedBox(height: 8),

                  // 🔹 Upcoming blocks (independent section)
                  _buildUpcomingBlocksSection(),

                  const SizedBox(height: 8),

                  // 🔹 Other / orphan templates (independent section)
                  _buildOtherTemplatesSection(),

                  const SizedBox(height: 54), // bottom breathing room
                ],
              ),
            ),

        ],
      ),

    );
  }

  void _navigateToTemplateDetails(BuildContext context, Template template) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TemplateDetailsScreen(
          template: template,
          //fromWorkoutPage: widget.fromWorkoutPage, // Pass the flag
          onLoadTemplate: (selectedTemplate) {
            Navigator.pop(context,
                selectedTemplate); // Pass the template back to WorkoutPage
          },
        ),
      ),
    );
  }
}