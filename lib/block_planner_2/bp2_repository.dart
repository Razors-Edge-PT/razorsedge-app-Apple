/// Direct client-side Firestore access for Block Planner 2.
///
/// Paths (all canonical, none legacy):
///   /exercises/{id}                                  shared catalogue
///   /users/{uid}/customExercises/{id}                athlete custom pool
///   /users/{uid}/templates/{id}                      templates (blockId link)
///   /users/{uid}/planned_blocks/{id}                 blocks + exerciseSettings
///   /users/{uid}/planned_blocks/{id}/weeks/week_N/…  canonical week scaffold
///
/// Only `exerciseSettings` is ever read or written for per-exercise settings.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../block_creation_helper.dart' as block_domain;
import '../block_exercise_defaults_repository.dart';
import '../exercise_catalog.dart';
import '../settings_merge.dart';
import '../wes2_exercise_settings_patch.dart';
import 'bp2_date_utils.dart';
import 'bp2_models.dart';

/// Writes the canonical week/day scaffold for a block. Defaults to the shared
/// block-domain helper; injectable so tests never touch a real batch.
typedef Bp2WeekScaffolder = Future<void> Function(
  DocumentReference<Map<String, dynamic>> blockRef,
  DateTime startDate,
  int totalWeeks,
);

class Bp2ActivationResult {
  final String activeBlockId;
  final List<String> retiredBlockIds;
  const Bp2ActivationResult(this.activeBlockId, this.retiredBlockIds);
}

class Bp2Repository {
  final FirebaseFirestore _db;
  final Bp2WeekScaffolder _scaffold;

  Bp2Repository({FirebaseFirestore? firestore, Bp2WeekScaffolder? scaffolder})
      : _db = firestore ?? FirebaseFirestore.instance,
        _scaffold = scaffolder ??
            ((ref, start, weeks) => block_domain
                .scaffoldBlockInBackground(ref, start, totalWeeks: weeks));

  // ── References ────────────────────────────────────────────────────────────

  CollectionReference<Map<String, dynamic>> _exercises() =>
      _db.collection('exercises');
  CollectionReference<Map<String, dynamic>> _custom(String uid) =>
      _db.collection('users').doc(uid).collection('customExercises');
  CollectionReference<Map<String, dynamic>> _templates(String uid) =>
      _db.collection('users').doc(uid).collection('templates');
  CollectionReference<Map<String, dynamic>> _blocks(String uid) =>
      _db.collection('users').doc(uid).collection('planned_blocks');

  // ── Freshness (aggregate count = 1 read each) ─────────────────────────────

  Future<int> _count(Query<Map<String, dynamic>> q) async =>
      (await q.count().get()).count ?? 0;

  Future<int> countGlobalExercises() => _count(_exercises());
  Future<int> countCustomExercises(String uid) => _count(_custom(uid));
  Future<int> countTemplates(String uid) => _count(_templates(uid));
  Future<int> countBlocks(String uid) => _count(_blocks(uid));

  // ── Reads ─────────────────────────────────────────────────────────────────

  Future<List<CatalogExercise>> fetchGlobalExercises() async {
    final snap = await _exercises().get();
    return snap.docs
        .map((d) => CatalogExercise.fromMap(d.id, d.data(),
            source: ExerciseSource.global))
        .toList();
  }

  Future<List<CatalogExercise>> fetchCustomExercises(String uid) async {
    final snap = await _custom(uid).get();
    return snap.docs
        .map((d) => CatalogExercise.fromMap(d.id, d.data(),
            source: ExerciseSource.custom, ownerUid: uid))
        .toList();
  }

  Future<List<Bp2TemplateSummary>> fetchTemplates(String uid) async {
    final snap = await _templates(uid).get();
    return snap.docs.map((d) => parseTemplate(d.id, d.data())).toList();
  }

  static Bp2TemplateSummary parseTemplate(
      String id, Map<String, dynamic> data) {
    final raw = data['exercises'];
    final refs = <Bp2TemplateRef>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          final m = Map<String, dynamic>.from(e);
          refs.add(Bp2TemplateRef(
            exerciseId: ((m['exerciseId'] ?? m['id']) ?? '').toString().trim(),
            name: ((m['name'] ?? m['exercise']) ?? '').toString().trim(),
          ));
        } else if (e is String && e.trim().isNotEmpty) {
          refs.add(Bp2TemplateRef(exerciseId: '', name: e.trim()));
        }
      }
    }
    final blockId = data['blockId'];
    return Bp2TemplateSummary(
      id: id,
      blockId: blockId is String && blockId.isNotEmpty ? blockId : null,
      refs: refs,
    );
  }

  Future<List<Bp2BlockSummary>> fetchBlockSummaries(String uid) async {
    final snap = await _blocks(uid).get();
    return snap.docs.map((d) => parseBlockSummary(d.id, d.data())).toList();
  }

  static DateTime? _date(dynamic v) {
    if (v is Timestamp) return Bp2DateUtils.dateOnly(v.toDate());
    if (v is DateTime) return Bp2DateUtils.dateOnly(v);
    return null;
  }

  static Bp2BlockSummary parseBlockSummary(String id, Map<String, dynamic> d) =>
      Bp2BlockSummary(
        id: id,
        name: (d['name'] ?? '').toString(),
        startDate: _date(d['startDate']),
        endDate: _date(d['endDate']),
        isActive: d['isActive'] == true,
      );

  static Map<String, Map<String, dynamic>> parseExerciseSettings(dynamic raw) {
    final out = <String, Map<String, dynamic>>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        final m = SettingsMerge.asMap(v);
        if (m != null) out[k.toString()] = m;
      });
    }
    return out;
  }

  Future<Bp2BlockRecord?> fetchBlock(String uid, String blockId) async {
    final snap = await _blocks(uid).doc(blockId).get();
    if (!snap.exists) return null;
    final d = snap.data() ?? const {};
    final start = _date(d['startDate']);
    final end = _date(d['endDate']);
    return Bp2BlockRecord(
      id: blockId,
      name: (d['name'] ?? '').toString(),
      range: start != null && end != null
          ? Bp2DateUtils.normalizeRange(start, end)
          : Bp2DateUtils.defaultRange(DateTime.now(),
              weeks: block_domain.kDefaultBlockWeeks),
      isActive: d['isActive'] == true,
      exerciseSettings: parseExerciseSettings(d['exerciseSettings']),
      existsRemotely: true,
    );
  }

  /// Resolves one exercise by id after the canonical add flow returns:
  /// global pool first, then the athlete's custom pool (at most two reads).
  Future<CatalogExercise?> fetchExerciseById(String uid, String id) async {
    if (id.isEmpty) return null;
    final g = await _exercises().doc(id).get();
    if (g.exists && g.data() != null) {
      return CatalogExercise.fromMap(g.id, g.data()!,
          source: ExerciseSource.global);
    }
    final c = await _custom(uid).doc(id).get();
    if (c.exists && c.data() != null) {
      return CatalogExercise.fromMap(c.id, c.data()!,
          source: ExerciseSource.custom, ownerUid: uid);
    }
    return null;
  }

  /// `username` → `displayName` → neutral fallback.
  Future<String> fetchAthleteLabel(String uid) async {
    try {
      final snap = await _db.collection('users').doc(uid).get();
      final d = snap.data() ?? const {};
      for (final key in const ['username', 'displayName']) {
        final v = d[key];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
    } catch (e) {
      debugPrint('[BP2] athlete label lookup failed: $e');
    }
    return neutralAthleteLabel;
  }

  static const String neutralAthleteLabel = 'athlete';

  // ── Writes ────────────────────────────────────────────────────────────────

  /// Allocates a Firestore document id without writing anything.
  String newBlockId(String uid) => _blocks(uid).doc().id;

  /// Creates or updates the block's name and Monday–Sunday dates. Nothing else
  /// on the document is touched. Creation writes the same top-level fields
  /// the app's bootstrap uses so every existing consumer can read the block.
  Future<void> upsertBlock({
    required String uid,
    required String blockId,
    required String name,
    required Bp2DateRange range,
    required bool create,
  }) async {
    final ref = _blocks(uid).doc(blockId);
    final data = <String, dynamic>{
      'name': name,
      'startDate': Timestamp.fromDate(range.start),
      'endDate': Timestamp.fromDate(range.end),
      'updatedAt': FieldValue.serverTimestamp(),
      if (create) ...{
        'isActive': false,
        'createdAt': Timestamp.now(),
        'selectedDays': const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
        'allExercisesAvailable': true,
        'excludedExerciseIds': <String>[],
        'ownerUid': uid,
      },
    };
    await ref.set(data, SetOptions(merge: true));
  }

  /// Ensures the canonical `weeks/week_N/days/day_M` scaffold exists for every
  /// week of [range] (idempotent, merge writes).
  Future<void> ensureWeekScaffold({
    required String uid,
    required String blockId,
    required Bp2DateRange range,
  }) =>
      _scaffold(_blocks(uid).doc(blockId), range.start, range.weeks);

  /// Deep-merges one exercise's dirty patch onto the latest server object
  /// inside a transaction (identical semantics to the WES2 cog), seeding the
  /// canonical defaults first when the exercise has no usable settings yet.
  /// Returns the merged object.
  Future<Map<String, dynamic>> saveExerciseSettings({
    required String uid,
    required String blockId,
    required String exerciseId,
    required ExerciseSettingsPatch patch,
    required Map<String, dynamic> defaultsPayload,
  }) {
    final docRef = _blocks(uid).doc(blockId);
    return _db.runTransaction<Map<String, dynamic>>((txn) async {
      final snap = await txn.get(docRef);
      final data =
          snap.exists ? (snap.data() ?? const {}) : const <String, dynamic>{};
      final all = SettingsMerge.asMap(data['exerciseSettings']) ?? const {};
      final latest = SettingsMerge.asMap(all[exerciseId]);
      final merged = mergeForSave(latest, patch, defaultsPayload);
      // Replace ONLY this exercise's object (so deliberately cleared leaves
      // disappear) and leave every other exercise and top-level field alone.
      txn.update(docRef, {
        FieldPath(['exerciseSettings', exerciseId]): merged
      });
      return merged;
    });
  }

  /// Offline fallback: transactions cannot be queued, so the merge computed
  /// against the last known object is written with a plain merge-set, which
  /// Firestore's offline persistence queues durably.
  Future<Map<String, dynamic>> queueExerciseSettingsOffline({
    required String uid,
    required String blockId,
    required String exerciseId,
    required Map<String, dynamic>? lastKnown,
    required ExerciseSettingsPatch patch,
    required Map<String, dynamic> defaultsPayload,
  }) async {
    final merged = mergeForSave(lastKnown, patch, defaultsPayload);
    // Not awaited: an offline write only completes when connectivity returns.
    unawaited(_blocks(uid).doc(blockId).set({
      'exerciseSettings': {exerciseId: merged}
    }, SetOptions(merge: true)));
    return merged;
  }

  /// Pure: base (healed defaults when incomplete) + patch → healed object.
  static Map<String, dynamic> mergeForSave(
    Map<String, dynamic>? latest,
    ExerciseSettingsPatch patch,
    Map<String, dynamic> defaultsPayload,
  ) {
    Map<String, dynamic> base;
    if (BlockExerciseDefaultsRepository.isSettingsUsable(latest) ||
        defaultsPayload.isEmpty) {
      base = latest ?? <String, dynamic>{};
    } else {
      base = BlockExerciseDefaultsRepository.projectHealedSettings(
          latest ?? const {}, SettingsMerge.deepCopyMap(defaultsPayload));
    }
    final merged = SettingsMerge.applyPatch(base, patch);
    final healedRir = BlockExerciseDefaultsRepository.healWeek1RirPlan(merged);
    if (healedRir != null) merged['rirPlan'] = healedRir;
    return merged;
  }

  // ── Activation ────────────────────────────────────────────────────────────

  /// Makes [blockId] the athlete's single active block.
  ///
  /// 1. Query currently active blocks (outside the transaction — the client
  ///    SDK cannot query inside one).
  /// 2. Transaction: re-read every candidate + the target, retire the ones
  ///    still active, activate the target.
  /// 3. Verify: re-query; if a concurrent activation slipped in, retire every
  ///    active block other than the target so the invariant always converges.
  Future<Bp2ActivationResult> activateBlock({
    required String uid,
    required String blockId,
  }) async {
    final col = _blocks(uid);
    final target = col.doc(blockId);

    Future<List<String>> activeIds() async {
      final snap = await col.where('isActive', isEqualTo: true).get();
      return snap.docs.map((d) => d.id).toList();
    }

    final candidates =
        (await activeIds()).where((id) => id != blockId).toList();
    final retired = <String>[];

    await _db.runTransaction<void>((txn) async {
      final targetSnap = await txn.get(target);
      if (!targetSnap.exists) {
        throw StateError('Block $blockId does not exist');
      }
      final snaps = <DocumentSnapshot<Map<String, dynamic>>>[];
      for (final id in candidates) {
        snaps.add(await txn.get(col.doc(id)));
      }
      for (final s in snaps) {
        if (s.exists && (s.data()?['isActive'] == true)) {
          txn.update(s.reference, {
            'isActive': false,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          retired.add(s.id);
        }
      }
      if (targetSnap.data()?['isActive'] != true) {
        txn.update(target, {
          'isActive': true,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    });

    // Convergence check for concurrent activations.
    final stillActive =
        (await activeIds()).where((id) => id != blockId).toList();
    if (stillActive.isNotEmpty) {
      final batch = _db.batch();
      for (final id in stillActive) {
        batch.update(col.doc(id), {'isActive': false});
        retired.add(id);
      }
      await batch.commit();
    }
    return Bp2ActivationResult(blockId, retired.toSet().toList());
  }
}
