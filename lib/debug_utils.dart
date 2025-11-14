/// One-time helper: fetch all exercises and group by category with body parts.
/// Prints a compact JSON preview and returns a Map you can use for inspection.
/// Call from a debug button; remove after use.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart'; // debugPrint
import 'dart:convert';                    // jsonEncode
import 'dart:io';                         // File
import 'package:path_provider/path_provider.dart'; // getApplicationDocumentsDirectory
import 'template_generator.dart';



/// Fetch the entire exercises collection, grouped by category.
/// Set [writeFile] = true to also save a JSON file to app Documents dir.
Future<Map<String, List<Map<String, dynamic>>>> dumpExercisesByCategory({
  bool writeFile = false,
}) async {
  final snap = await FirebaseFirestore.instance
      .collection('exercises')
      .orderBy('category')
      .get();

  final byCategory = <String, List<Map<String, dynamic>>>{};
  int total = 0;

  for (final d in snap.docs) {
    final data = d.data();
    final id = d.id;
    final name = (data['name'] ?? '').toString();
    final category = (data['category'] ?? 'Uncategorized').toString();

    // Prefer 'bodyParts' list; fall back to single 'bodyPart'
    final bodyParts = (data['bodyParts'] is List)
        ? (data['bodyParts'] as List).map((e) => e.toString()).toList()
        : (data['bodyPart'] != null ? [data['bodyPart'].toString()] : <String>[]);

    final item = <String, dynamic>{
      'id': id,
      'name': name,
      'category': category,
      'bodyParts': bodyParts,
      // keep any useful extras if present
      if (data.containsKey('isIsolation')) 'isIsolation': data['isIsolation'],
      if (data.containsKey('equipment')) 'equipment': data['equipment'],
    };

    (byCategory[category] ??= <Map<String, dynamic>>[]).add(item);
    total++;
  }

  debugPrint('🗂️ [DumpExercises] categories=${byCategory.length}, total=$total');

  if (writeFile) {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now();
      final stamp =
          '${ts.year}${ts.month.toString().padLeft(2, '0')}${ts.day.toString().padLeft(2, '0')}_'
          '${ts.hour.toString().padLeft(2, '0')}${ts.minute.toString().padLeft(2, '0')}${ts.second.toString().padLeft(2, '0')}';
      final file = File('${dir.path}/exercise_dump_$stamp.json');

      // Sort keys for stable output
      final sorted = Map.fromEntries(
        byCategory.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
      );

      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(sorted));
      debugPrint('✅ [DumpExercises] wrote file: ${file.path}');
    } catch (e) {
      debugPrint('❌ [DumpExercises] failed to write file: $e');
    }
  }

  return byCategory;
}

void debugWeeklyCategoryAndMuscleCounts(List<dynamic> days) {
  final Map<String, int> categoryCounts = {};
  final Map<String, int> muscleCounts   = {};

  for (final d in days) {
    for (final circ in d.circuits) {
      for (final placed in circ) {
        final ex = placed.ex;

        // Count per category
        final catKey = ex.category.trim();
        if (catKey.isNotEmpty) {
          categoryCounts[catKey] = (categoryCounts[catKey] ?? 0) + 1;
        }

        // Collect up to 4 muscles total (primary + secondary)
        final allMuscles = <String>[];
        allMuscles.addAll(ex.primary);
        allMuscles.addAll(ex.secondary);

        for (final m in allMuscles.take(4)) {
          final mk = m.trim();
          if (mk.isEmpty) continue;
          muscleCounts[mk] = (muscleCounts[mk] ?? 0) + 1;
        }
      }
    }
  }

  debugPrint('──────────── 📊 WEEKLY CATEGORY COUNTS ────────────');
  final sortedCats = categoryCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sortedCats) {
    debugPrint('  • ${e.key}: ${e.value}');
  }

  debugPrint('──────────── 🧬 WEEKLY MUSCLE COUNTS (top 4 hits/ex) ────────────');
  final sortedMuscles = muscleCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sortedMuscles) {
    debugPrint('  • ${e.key}: ${e.value}');
  }
  debugPrint('────────────────────────────────────────────────────');
}

