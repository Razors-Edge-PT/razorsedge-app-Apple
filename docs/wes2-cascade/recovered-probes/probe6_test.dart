// THROWAWAY PROBE — queue ordering defects through the REAL outbox, engine and
// FirestoreWes2Repository on FakeFirebaseFirestore.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_repository.dart';
import 'package:localtest222/wes2_sync/wes2_mutation.dart';
import 'package:localtest222/wes2_sync/wes2_mutation_outbox.dart';
import 'package:localtest222/wes2_sync/wes2_sync_engine.dart';

const ex = 'bench';
final date = DateTime(2026, 5, 4);

class ScriptedRepo extends FirestoreWes2Repository {
  ScriptedRepo(FakeFirebaseFirestore fs) : super(firestore: fs);
  int failRemoveSetTimes = 0;
  Future<void> Function()? duringFieldPatch;
  @override
  Future<void> removeSet({required String uid, required DateTime date, required String exerciseId, required int setIndex, int? expectedSetCountBefore}) async {
    if (failRemoveSetTimes > 0) {
      failRemoveSetTimes--;
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    return super.removeSet(uid: uid, date: date, exerciseId: exerciseId, setIndex: setIndex, expectedSetCountBefore: expectedSetCountBefore);
  }
  @override
  Future<void> saveFieldPatch({required String uid, required DateTime date, required Wes2ExerciseRow row, required int setIndex, required Wes2FieldKey fieldKey, required dynamic value}) async {
    final hook = duringFieldPatch;
    duringFieldPatch = null;
    if (hook != null) await hook();
    return super.saveFieldPatch(uid: uid, date: date, row: row, setIndex: setIndex, fieldKey: fieldKey, value: value);
  }
}

Future<FakeFirebaseFirestore> seed(List<double> weights) async {
  final fs = FakeFirebaseFirestore();
  await fs.collection('users').doc('a').collection('workouts').doc('2026-05-04').set({
    'userId': 'a', 'date': '2026-05-04',
    'exercises': [
      {'exerciseId': ex, 'name': 'Bench', 'circuitIndex': 0, 'orderIndex': 0, 'setCount': weights.length,
       'sets': [for (int i = 0; i < weights.length; i++) {'setIndex': i, 'weight': weights[i]}]}
    ],
    'wesPlannedExercises': [],
  });
  return fs;
}

Future<String> server(FakeFirebaseFirestore fs) async {
  final d = (await fs.collection('users').doc('a').collection('workouts').doc('2026-05-04').get()).data()!;
  final r = (d['exercises'] as List).first as Map;
  return 'setCount=${r['setCount']} weights=${(r['sets'] as List).map((s) => (s as Map)['weight']).toList()}';
}

Wes2ExerciseRow row(int n) => Wes2ExerciseRow(exerciseId: ex, name: 'Bench', circuitIndex: 0, orderIndex: 0, setCount: n, source: Wes2RowSource.completedServer, sets: List.generate(n, (i) => Wes2SetState(setIndex: i)));
Wes2Mutation weight(int i, double v, int n) => Wes2Mutation.fieldPatch(actorUid: 'a', athleteUid: 'a', date: date, row: row(n), setIndex: i, fieldKey: Wes2FieldKey.weight, value: v);
Wes2Mutation remove(int i, int expected, int seq) => Wes2Mutation.removeSet(actorUid: 'a', athleteUid: 'a', date: date, exerciseId: ex, setIndex: i, expectedSetCountBefore: expected, localSeq: seq);

Future<String> queue(Wes2MutationOutbox o) async =>
    (await o.pendingForDay(actorUid: 'a', athleteUid: 'a', dateKey: '2026-05-04')).map((r) => '${r.seq}:${r.kind}@${r.setIndex}').join(', ');

void main() {
  late Wes2MutationDatabase db;
  late Wes2MutationOutbox outbox;
  setUp(() {
    db = Wes2MutationDatabase.memory();
    outbox = Wes2MutationOutbox(db);
  });
  tearDown(() => db.close());

  Wes2SyncEngine engineFor(Wes2Repository repo) => Wes2SyncEngine(outbox: outbox, repository: repo, currentActorUid: () => 'a', autoStartTimer: false, autoProcessOnSubmit: false, baseBackoff: const Duration(minutes: 5));

  test('P6a offline delete B then C', () async {
    final fs = await seed([10, 20, 30]);
    final engine = engineFor(ScriptedRepo(fs));
    await engine.submit(remove(1, 3, 1)); // B
    await engine.submit(remove(1, 2, 2)); // C (now at index 1)
    // ignore: avoid_print
    print('P6a QUEUE: ${await queue(outbox)}');
    await engine.processNow();
    // ignore: avoid_print
    print('P6a SERVER: ${await server(fs)}  (intent: weights=[10.0])');
    await engine.dispose();
  });

  test('P6b removal in backoff overtaken by later edit', () async {
    final fs = await seed([10, 20, 30]);
    final repo = ScriptedRepo(fs)..failRemoveSetTimes = 1;
    final engine = engineFor(repo);
    await engine.submit(remove(0, 3, 1)); // remove set 1 (10)
    await engine.process(); // fails transiently -> 5 min backoff
    await engine.submit(weight(0, 99, 2)); // athlete edits what is now set 1 (was 20)
    await engine.process(); // edit is claimable, removal is not
    // ignore: avoid_print
    print('P6b SERVER after 2nd pass: ${await server(fs)}  QUEUE: ${await queue(outbox)}');
    await engine.processNow();
    // ignore: avoid_print
    print('P6b SERVER final: ${await server(fs)}  (intent: weights=[99.0, 30.0])');
    await engine.dispose();
  });

  test('P6c acknowledgement of old attempt deletes newer intent', () async {
    final fs = await seed([10, 20, 30]);
    final repo = ScriptedRepo(fs);
    final engine = engineFor(repo);
    await engine.submit(weight(0, 50, 3));
    repo.duringFieldPatch = () async {
      // Athlete types a newer value while the 50 is in flight (same coalescing id).
      await outbox.enqueue(weight(0, 55, 3));
    };
    await engine.process();
    // ignore: avoid_print
    print('P6c SERVER: ${await server(fs)}  QUEUE: [${await queue(outbox)}]  (intent: set 1 = 55.0, still queued or applied)');
    await engine.dispose();
  });
}
