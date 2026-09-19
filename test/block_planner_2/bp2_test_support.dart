import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:localtest222/block_planner_2/bp2_cache.dart';
import 'package:localtest222/block_planner_2/bp2_controller.dart';
import 'package:localtest222/block_planner_2/bp2_models.dart';
import 'package:localtest222/block_planner_2/bp2_repository.dart';
import 'package:localtest222/block_planner_2/bp2_sync_service.dart';
import 'package:localtest222/exercise_catalog.dart';

/// Repository over a fake Firestore that counts full-collection downloads so
/// tests can assert the freshness contract.
class CountingRepo extends Bp2Repository {
  int sharedFetches = 0;
  int customFetches = 0;
  int templateFetches = 0;
  int blockFetches = 0;
  int countCalls = 0;
  int blockDocFetches = 0;
  final List<(String, String, DateTime, int)> scaffolds = [];

  CountingRepo(FakeFirebaseFirestore db)
      : super(
          firestore: db,
          scaffolder: (ref, start, weeks) async {},
        ) {
    _self = this;
  }

  static CountingRepo? _self;

  @override
  Future<int> countGlobalExercises() {
    countCalls++;
    return super.countGlobalExercises();
  }

  @override
  Future<int> countCustomExercises(String uid) {
    countCalls++;
    return super.countCustomExercises(uid);
  }

  @override
  Future<int> countTemplates(String uid) {
    countCalls++;
    return super.countTemplates(uid);
  }

  @override
  Future<int> countBlocks(String uid) {
    countCalls++;
    return super.countBlocks(uid);
  }

  @override
  Future<List<CatalogExercise>> fetchGlobalExercises() {
    sharedFetches++;
    return super.fetchGlobalExercises();
  }

  @override
  Future<List<CatalogExercise>> fetchCustomExercises(String uid) {
    customFetches++;
    return super.fetchCustomExercises(uid);
  }

  @override
  Future<List<Bp2TemplateSummary>> fetchTemplates(String uid) {
    templateFetches++;
    return super.fetchTemplates(uid);
  }

  @override
  Future<List<Bp2BlockSummary>> fetchBlockSummaries(String uid) {
    blockFetches++;
    return super.fetchBlockSummaries(uid);
  }

  @override
  Future<Bp2BlockRecord?> fetchBlock(String uid, String blockId) {
    blockDocFetches++;
    return super.fetchBlock(uid, blockId);
  }

  @override
  Future<void> ensureWeekScaffold({
    required String uid,
    required String blockId,
    required range,
  }) async {
    scaffolds.add((uid, blockId, range.start, range.weeks));
  }

  int get totalFetches =>
      sharedFetches + customFetches + templateFetches + blockFetches;

  static CountingRepo get last => _self!;
}

class Harness {
  final FakeFirebaseFirestore db = FakeFirebaseFirestore();
  late final CountingRepo repo = CountingRepo(db);
  final Bp2MemoryCacheStore cache = Bp2MemoryCacheStore();
  DateTime now = DateTime(2026, 9, 24, 10);
  late final Bp2SyncService sync =
      Bp2SyncService(repo: repo, cache: cache, now: () => now);
  late final Bp2Controller controller = Bp2Controller(
    sync: sync,
    repo: repo,
    now: () => now,
    draftDebounce: Duration.zero,
    writeTimeout: const Duration(seconds: 2),
  );

  Future<void> seedShared(String id, String name,
          {String category = 'Horizontal Press', String bodyPart = 'Chest'}) =>
      db.collection('exercises').doc(id).set({
        'name': name,
        'category': category,
        'bodyParts': [bodyPart],
        'bodyPart': bodyPart,
      });

  Future<void> seedCustom(String uid, String id, String name) => db
          .collection('users')
          .doc(uid)
          .collection('customExercises')
          .doc(id)
          .set({
        'name': name,
        'category': 'Core',
        'bodyParts': ['Abs'],
        'ownerUid': uid,
        'source': 'custom',
      });

  Future<void> seedTemplate(String uid, String id, String? blockId,
          List<Map<String, dynamic>> exercises) =>
      db.collection('users').doc(uid).collection('templates').doc(id).set({
        'name': id,
        if (blockId != null) 'blockId': blockId,
        'exercises': exercises,
      });

  Future<void> seedBlock(String uid, String id,
          {required bool isActive,
          String? name,
          bool omitName = false,
          DateTime? start,
          DateTime? end,
          Map<String, dynamic>? exerciseSettings,
          Map<String, dynamic> extra = const {}}) =>
      db.collection('users').doc(uid).collection('planned_blocks').doc(id).set({
        if (!omitName) 'name': name ?? id,
        'isActive': isActive,
        'startDate': Timestamp.fromDate(start ?? DateTime(2026, 8, 3)),
        'endDate': Timestamp.fromDate(end ?? DateTime(2026, 8, 30)),
        if (exerciseSettings != null) 'exerciseSettings': exerciseSettings,
        ...extra,
      });

  Future<void> seedUser(String uid, {String? username, String? displayName}) =>
      db.collection('users').doc(uid).set({
        if (username != null) 'username': username,
        if (displayName != null) 'displayName': displayName,
      });

  Future<Map<String, dynamic>?> block(String uid, String id) async => (await db
          .collection('users')
          .doc(uid)
          .collection('planned_blocks')
          .doc(id)
          .get())
      .data();

  Future<List<String>> activeBlockIds(String uid) async => (await db
          .collection('users')
          .doc(uid)
          .collection('planned_blocks')
          .where('isActive', isEqualTo: true)
          .get())
      .docs
      .map((d) => d.id)
      .toList();
}
