// THROWAWAY PROBE — offline edit on a later set, then removal of an earlier set,
// through the REAL outbox (in-memory Drift), engine and FirestoreWes2Repository.
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_repository.dart';
import 'package:localtest222/wes2_sync/wes2_mutation.dart';
import 'package:localtest222/wes2_sync/wes2_mutation_outbox.dart';
import 'package:localtest222/wes2_sync/wes2_sync_engine.dart';

void main() {
  test('edit set 3 offline, then remove set 2', () async {
    final fs = FakeFirebaseFirestore();
    final date = DateTime(2026, 5, 4);
    const ex = 'bench';
    await fs.collection('users').doc('a').collection('workouts').doc('2026-05-04').set({
      'userId': 'a',
      'date': '2026-05-04',
      'exercises': [
        {
          'exerciseId': ex, 'name': 'Bench', 'circuitIndex': 0, 'orderIndex': 0, 'setCount': 3,
          'sets': [
            {'setIndex': 0, 'weight': 50.0},
            {'setIndex': 1, 'weight': 60.0},
            {'setIndex': 2, 'weight': 70.0},
          ],
        }
      ],
      'wesPlannedExercises': [],
    });
    final db = Wes2MutationDatabase.memory();
    final outbox = Wes2MutationOutbox(db);
    final repo = FirestoreWes2Repository(firestore: fs);
    final engine = Wes2SyncEngine(outbox: outbox, repository: repo, currentActorUid: () => 'a', autoStartTimer: false, autoProcessOnSubmit: false, baseBackoff: Duration.zero);
    final row = Wes2ExerciseRow(exerciseId: ex, name: 'Bench', circuitIndex: 0, orderIndex: 0, setCount: 3, source: Wes2RowSource.completedServer,
        sets: List.generate(3, (i) => Wes2SetState(setIndex: i)));

    await engine.submit(Wes2Mutation.fieldPatch(actorUid: 'a', athleteUid: 'a', date: date, row: row, setIndex: 2, fieldKey: Wes2FieldKey.weight, value: 100.0));
    await engine.submit(Wes2Mutation.removeSet(actorUid: 'a', athleteUid: 'a', date: date, exerciseId: ex, setIndex: 1, expectedSetCountBefore: 3, localSeq: 1));
    final pending = await outbox.pendingForDay(actorUid: 'a', athleteUid: 'a', dateKey: '2026-05-04');
    // ignore: avoid_print
    print('QUEUE: ${pending.map((r) => '${r.seq}:${r.kind}@${r.setIndex}').join(', ')}');
    await engine.processNow();
    final doc = await fs.collection('users').doc('a').collection('workouts').doc('2026-05-04').get();
    final sets = ((doc.data()!['exercises'] as List).first as Map)['sets'];
    // ignore: avoid_print
    print('SERVER AFTER: setCount=${((doc.data()!['exercises'] as List).first as Map)['setCount']} sets=$sets');
    // ignore: avoid_print
    print('EXPECTED (athlete intent): [50.0, 100.0]');
    await engine.dispose();
    await db.close();
  });
}
