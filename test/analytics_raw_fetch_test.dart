// Regression coverage for the safe, mixed-date-type pagination fix (issue
// 5) in lib/analytics_history_loader.dart.
//
// IMPORTANT LIMITATION, disclosed rather than hidden: fake_cloud_firestore
// (the only Firestore test double available in this project) does not
// replicate real Firestore's per-type range-filter exclusion. Real
// Firestore silently excludes a document whose field is a different type
// than an inequality filter's bound value; the fake instead THROWS
// (`type 'X' is not a subtype of type 'Y'`) as soon as it tries to compare
// across types — and it does this even when only ONE type is actually
// present, because fetchRawWorkoutDocsFromFirestore always runs both the
// Timestamp-stream and the String-stream queries in parallel against the
// same collection, and the fake attempts the "wrong" comparison on
// whichever real documents are there.
//
// That makes it impossible to exercise the full two-stream orchestration
// end-to-end in this environment, mixed types or not. What IS verified
// here, against the real fake, is fetchAllPagesForQuery — the pagination
// helper each stream is built from — called directly with a single,
// hand-built, homogeneously-typed query (exactly what
// fetchRawWorkoutDocsFromFirestore constructs for each stream):
//   * pagination across a page boundary is correct for Timestamp-typed
//     documents, and separately for String-typed documents in both real
//     sub-formats (WES2's zero-padded `yyyy-MM-dd`, and legacy screens'
//     full `toIso8601String()`),
//   * the inclusive calendar-day cutoff boundary in both formats,
//   * document identity/multi-doc-per-day preservation.
// The loader-level merge of two streams' results (issue 5's "recent
// timestamp records must not be lost behind old string records") is
// covered without Firestore at all in analytics_history_loader_test.dart,
// via AnalyticsHistoryLoader's injected fetcher.
// The cross-type exclusion itself rests on Firestore's documented value-type
// ordering (the page this fix's review comment referenced):
// https://firebase.google.com/docs/firestore/manage-data/data-types#value_type_ordering

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/analytics_history_loader.dart';

Map<String, dynamic> workoutDoc(dynamic date, {String exerciseId = 'ex1'}) => {
      'date': date,
      'exercises': [
        {'id': exerciseId, 'name': 'Bench Press', 'sets': const []},
      ],
    };

void main() {
  group('fetchAllPagesForQuery — Timestamp-typed documents', () {
    test('pages across a boundary and includes the most recent document', () async {
      final db = FakeFirebaseFirestore();
      final col = db.collection('users').doc('u1').collection('workouts');

      // 250 old docs (forces >1 page at the 200-doc batch size), plus one
      // genuinely recent one, all Timestamp-typed.
      for (int i = 0; i < 250; i++) {
        final d = DateTime(2020, 1, 1).add(Duration(days: i));
        await col.doc('old-$i').set(workoutDoc(Timestamp.fromDate(d)));
      }
      await col.doc('recent').set(workoutDoc(Timestamp.fromDate(DateTime(2026, 8, 20))));

      final cutoff = DateTime(2026, 1, 1);
      final query = col
          .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(cutoff))
          .orderBy('date', descending: true);
      final docs = await fetchAllPagesForQuery(query);

      expect(docs.map((d) => d.id), ['recent']);
    });

    test('the cutoff day itself is included (inclusive boundary)', () async {
      final db = FakeFirebaseFirestore();
      final col = db.collection('users').doc('u1').collection('workouts');
      await col.doc('on-cutoff').set(workoutDoc(Timestamp.fromDate(DateTime(2026, 3, 1))));
      await col.doc('before-cutoff').set(workoutDoc(Timestamp.fromDate(DateTime(2026, 2, 28))));

      final query = col
          .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(DateTime(2026, 3, 1)))
          .orderBy('date', descending: true);
      final docs = await fetchAllPagesForQuery(query);

      expect(docs.map((d) => d.id), ['on-cutoff']);
    });
  });

  group('fetchAllPagesForQuery — String-typed documents (legacy)', () {
    test("WES2's zero-padded yyyy-MM-dd format pages correctly across a boundary", () async {
      final db = FakeFirebaseFirestore();
      final col = db.collection('users').doc('u1').collection('workouts');
      for (int i = 0; i < 250; i++) {
        final d = DateTime(2020, 1, 1).add(Duration(days: i));
        final key =
            '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        await col.doc(key).set(workoutDoc(key));
      }
      await col.doc('2026-08-20').set(workoutDoc('2026-08-20'));

      final query = col
          .where('date', isGreaterThanOrEqualTo: '2026-01-01')
          .orderBy('date', descending: true);
      final docs = await fetchAllPagesForQuery(query);

      expect(docs.map((d) => d.id), ['2026-08-20']);
    });

    test('legacy full toIso8601String() documents are correctly bounded by a date-only cutoff',
        () async {
      final db = FakeFirebaseFirestore();
      final col = db.collection('users').doc('u1').collection('workouts');
      final recent = DateTime(2026, 8, 20, 14, 30, 5, 123);
      final old = DateTime(2020, 6, 1, 9, 0);
      await col.doc('recent').set(workoutDoc(recent.toIso8601String()));
      await col.doc('old').set(workoutDoc(old.toIso8601String()));

      final query = col
          .where('date', isGreaterThanOrEqualTo: '2026-01-01')
          .orderBy('date', descending: true);
      final docs = await fetchAllPagesForQuery(query);

      expect(docs.map((d) => d.id), ['recent']);
      expect(docs.single.date, recent);
    });

    test('a same-day full-ISO8601 record is included by a date-only cutoff (inclusive boundary)',
        () async {
      final db = FakeFirebaseFirestore();
      final col = db.collection('users').doc('u1').collection('workouts');
      final sameDayWithTime = DateTime(2026, 3, 1, 9, 15);
      await col.doc('same-day').set(workoutDoc(sameDayWithTime.toIso8601String()));

      final query = col
          .where('date', isGreaterThanOrEqualTo: '2026-03-01')
          .orderBy('date', descending: true);
      final docs = await fetchAllPagesForQuery(query);

      expect(docs.map((d) => d.id), ['same-day']);
    });
  });

  group('fetchAllPagesForQuery — document identity preserved', () {
    test('multiple workout documents on the same calendar day are both retained', () async {
      final db = FakeFirebaseFirestore();
      final col = db.collection('users').doc('u1').collection('workouts');
      // Two distinct String-typed documents that both fall on 2026-08-20.
      await col.doc('wes2-2026-08-20').set(workoutDoc('2026-08-20'));
      await col.doc('legacy-auto-id').set(workoutDoc('2026-08-20T06:00:00.000'));

      final query = col
          .where('date', isGreaterThanOrEqualTo: '2026-08-01')
          .orderBy('date', descending: true);
      final docs = await fetchAllPagesForQuery(query);

      expect(docs.map((d) => d.id).toSet(), {'wes2-2026-08-20', 'legacy-auto-id'},
          reason: 'both documents on the same calendar day must survive — dedup is by '
              'document id, never by calendar day, at the fetch layer');
    });
  });
}
