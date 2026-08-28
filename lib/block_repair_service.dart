import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'template_bootstrapper.dart';

/// Outcome of a [BlockRepairService.ensureActiveBlockAndTemplatesForUser] run.
class BlockRepairResult {
  final String? activeBlockId;
  final bool activatedExistingBlock; // an existing block was set isActive=true
  final bool createdBlocks; // the create hook ran (full default-block setup)
  final bool templatesEnsured; // the template bootstrapper was invoked
  final int templateCount; // template docs present after the run (-1 = not read)
  final String message; // human-readable summary for snackbars/logs

  const BlockRepairResult({
    required this.activeBlockId,
    this.activatedExistingBlock = false,
    this.createdBlocks = false,
    this.templatesEnsured = false,
    this.templateCount = -1,
    required this.message,
  });

  bool get hasActiveBlock => activeBlockId != null && activeBlockId!.isNotEmpty;
}

/// Idempotent self-heal for the "user has no active block / no templates"
/// state that otherwise dead-ends the app (Warmup aborts, Templates can't
/// group, HomeScreen2 gates navigation behind activeBlockId forever).
///
/// Repair tiers — each safe to run any number of times:
///  1. A block is already active → nothing to fix (optionally ensure templates).
///  2. Blocks exist but none is active → re-activate the date-correct block
///     (metadata-only write; never touches workouts, weeks, or settings),
///     then ensure templates.
///  3. No blocks at all → only creates them when [allowCreate] is true AND a
///     [createBlocks] hook was supplied (wired to the production
///     HomeBootstrapService.ensureBlocksExist path by callers). Automatic
///     background callers never pass allowCreate.
///
/// All writes go to the uid passed in — for a coach this is the SELECTED
/// ATHLETE uid (UserContext.currentUid), never the coach's own auth uid.
class BlockRepairService {
  final FirebaseFirestore _fs;

  /// Full default-block creation for [uid]. Only invoked when allowCreate.
  final Future<void> Function(String uid)? createBlocks;

  /// Template creation/repair for [uid]. Defaults to the production
  /// TemplatesBootstrapper (flag-guarded, idempotent).
  final Future<void> Function(String uid)? ensureTemplates;

  BlockRepairService({
    FirebaseFirestore? firestore,
    this.createBlocks,
    this.ensureTemplates,
  }) : _fs = firestore ?? FirebaseFirestore.instance;

  String? _authUidForLog() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null; // no Firebase app in unit tests
    }
  }

  CollectionReference<Map<String, dynamic>> _blocksCol(String uid) =>
      _fs.collection('users').doc(uid).collection('planned_blocks');

  CollectionReference<Map<String, dynamic>> _templatesCol(String uid) =>
      _fs.collection('users').doc(uid).collection('templates');

  /// Picks which existing block should be active. Preference order:
  ///  1. block whose [startDate, endDate] covers today (latest start wins),
  ///  2. upcoming block with the earliest startDate,
  ///  3. past block with the latest endDate,
  ///  4. first doc (no usable dates anywhere).
  /// Exposed for tests. Returns null only for an empty list.
  static String? chooseBlockToActivate(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, {
    DateTime? now,
  }) {
    if (docs.isEmpty) return null;
    final today = now ?? DateTime.now();

    DateTime? asDate(dynamic v) => v is Timestamp ? v.toDate() : null;

    QueryDocumentSnapshot<Map<String, dynamic>>? covering;
    QueryDocumentSnapshot<Map<String, dynamic>>? upcoming;
    QueryDocumentSnapshot<Map<String, dynamic>>? past;

    for (final d in docs) {
      final start = asDate(d.data()['startDate']);
      final end = asDate(d.data()['endDate']);
      if (start != null && end != null) {
        if (!today.isBefore(start) && !today.isAfter(end)) {
          final prevStart = covering == null
              ? null
              : asDate(covering.data()['startDate']);
          if (prevStart == null || start.isAfter(prevStart)) covering = d;
          continue;
        }
      }
      if (start != null && start.isAfter(today)) {
        final prevStart =
            upcoming == null ? null : asDate(upcoming.data()['startDate']);
        if (prevStart == null || start.isBefore(prevStart)) upcoming = d;
        continue;
      }
      if (end != null && end.isBefore(today)) {
        final prevEnd = past == null ? null : asDate(past.data()['endDate']);
        if (prevEnd == null || end.isAfter(prevEnd)) past = d;
      }
    }

    return (covering ?? upcoming ?? past ?? docs.first).id;
  }

  /// See class docs. [allowCreate] gates tier 3 (block creation) — pass true
  /// only from an explicit user action. [alwaysEnsureTemplates] runs the
  /// template bootstrapper even when the block was already healthy (used by
  /// the Templates screen); background callers leave it false so healthy
  /// athletes cost no extra writes.
  Future<BlockRepairResult> ensureActiveBlockAndTemplatesForUser(
    String uid, {
    bool allowCreate = false,
    bool alwaysEnsureTemplates = false,
  }) async {
    final authUid = _authUidForLog();
    debugPrint(
        '🩹 [Repair] start selectedUid=$uid authUid=${authUid ?? 'n/a'} '
        'allowCreate=$allowCreate alwaysEnsureTemplates=$alwaysEnsureTemplates');

    var snap = await _blocksCol(uid).get();
    debugPrint('🩹 [Repair] blocks found=${snap.docs.length} for uid=$uid');

    String? activeId;
    for (final d in snap.docs) {
      if (d.data()['isActive'] == true) {
        activeId = d.id;
        break;
      }
    }

    bool activated = false;
    bool created = false;

    if (activeId == null && snap.docs.isNotEmpty) {
      // Tier 2: metadata-only re-activation of an existing block.
      final chosen = chooseBlockToActivate(snap.docs);
      if (chosen != null) {
        await _blocksCol(uid).doc(chosen).update({'isActive': true});
        activeId = chosen;
        activated = true;
        debugPrint('🩹 [Repair] activated existing block=$chosen for uid=$uid');
      }
    } else if (activeId == null && snap.docs.isEmpty) {
      // Tier 3: nothing to activate — create only when explicitly allowed.
      if (allowCreate && createBlocks != null) {
        debugPrint('🩹 [Repair] no blocks — running full creation for uid=$uid');
        await createBlocks!(uid);
        created = true;
        snap = await _blocksCol(uid).get();
        for (final d in snap.docs) {
          if (d.data()['isActive'] == true) {
            activeId = d.id;
            break;
          }
        }
        debugPrint(
            '🩹 [Repair] post-create blocks=${snap.docs.length} active=$activeId');
      } else {
        debugPrint(
            '🩹 [Repair] no blocks for uid=$uid and creation not allowed — needs setup');
        return BlockRepairResult(
          activeBlockId: null,
          message: 'No training blocks exist for this user yet.',
        );
      }
    } else {
      debugPrint('🩹 [Repair] active block already present: $activeId');
    }

    // Templates: run when we just repaired something, or when forced.
    bool templatesEnsured = false;
    int templateCount = -1;
    if (activeId != null && (activated || created || alwaysEnsureTemplates)) {
      try {
        final ensure = ensureTemplates ??
            (String u) => TemplatesBootstrapper.ensureInitialTemplatesForUser(u);
        await ensure(uid);
        templatesEnsured = true;
        final tSnap = await _templatesCol(uid).get();
        templateCount = tSnap.size;
        debugPrint('🩹 [Repair] templates ensured, count=$templateCount');
      } catch (e, st) {
        debugPrint('🩹 [Repair] template ensure failed for uid=$uid: $e\n$st');
      }
    }

    final message = created
        ? 'Training blocks and templates created.'
        : activated
            ? 'Active training block restored.'
            : activeId != null
                ? 'Training setup is healthy.'
                : 'Repair could not restore an active block.';

    debugPrint(
        '🩹 [Repair] done uid=$uid active=$activeId activated=$activated '
        'created=$created templates=$templateCount → $message');

    return BlockRepairResult(
      activeBlockId: activeId,
      activatedExistingBlock: activated,
      createdBlocks: created,
      templatesEnsured: templatesEnsured,
      templateCount: templateCount,
      message: message,
    );
  }
}
