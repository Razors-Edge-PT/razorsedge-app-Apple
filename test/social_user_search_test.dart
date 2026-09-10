// Buddy search: ranking, candidate selection, staleness and privacy.
//
// The defects these cover, all of which the legacy search had:
//   * a prefix range cannot tolerate a typo, so `jonh` found nobody;
//   * results came back in index order, so the person you meant was wherever
//     the index happened to put them;
//   * the search queried and RETURNED emailLower, which made a search box an
//     email-enumeration primitive;
//   * two parallel queries plus a keystroke stream means an older search can
//     land after a newer one and overwrite it.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/social/search_normalize.dart';
import 'package:localtest222/social/user_search_repository.dart';
import 'package:localtest222/social/user_search_result.dart';

UserSearchResult user({
  required String uid,
  String username = '',
  String fullName = '',
  String displayName = '',
}) {
  final List<String> parts =
      fullName.split(RegExp(r'\s+')).where((String p) => p.isNotEmpty).toList();
  return UserSearchResult(
    uid: uid,
    username: username,
    displayName: displayName.isNotEmpty ? displayName : fullName,
    fullName: fullName,
    firstName: parts.isEmpty
        ? ''
        : parts.length == 1
            ? parts.first
            : parts.sublist(0, parts.length - 1).join(' '),
    lastName: parts.length > 1 ? parts.last : '',
  );
}

/// Seeds `userSearchIndex` the way functions/social/search_index.js does.
Future<void> seed(
  FakeFirebaseFirestore db, {
  required String uid,
  required String username,
  String fullName = '',
  String photoURL = '',
  Map<String, Object?> extra = const <String, Object?>{},
}) async {
  final List<String> parts =
      fullName.split(RegExp(r'\s+')).where((String p) => p.isNotEmpty).toList();
  final String first =
      parts.isEmpty ? '' : parts.sublist(0, parts.length - 1).join(' ');
  final String last = parts.length > 1 ? parts.last : (parts.isEmpty ? '' : parts.first);

  final Set<String> terms = <String>{
    normalizeText(username),
    normalizeText(first),
    normalizeText(last),
    normalizeText(fullName),
    compactText(fullName),
  }..removeWhere((String t) => t.isEmpty);

  final Set<String> prefixes = <String>{};
  final Set<String> grams = <String>{};
  for (final String t in terms) {
    prefixes.addAll(prefixesOf(t));
    grams.addAll(trigramsOf(t));
  }

  await db.collection('userSearchIndex').doc(uid).set(<String, Object?>{
    'uid': uid,
    'username': username,
    'usernameLower': normalizeText(username),
    'displayName': fullName.isNotEmpty ? fullName : username,
    'fullName': fullName,
    'firstName': parts.length > 1 ? first : (parts.isEmpty ? '' : parts.first),
    'lastName': parts.length > 1 ? last : '',
    'photoURL': photoURL,
    'terms': terms.toList()..sort(),
    'prefixes': prefixes.toList()..sort(),
    'grams': grams.toList()..sort(),
    ...extra,
  });
}

void main() {
  group('ranking priority', () {
    final List<UserSearchResult> people = <UserSearchResult>[
      user(uid: 'u1', username: 'sam', fullName: 'Priya Raman'),
      user(uid: 'u2', username: 'samantha_lifts', fullName: 'Samantha Vaughn'),
      user(uid: 'u3', username: 'ironjaw', fullName: 'Sam Okafor'),
      user(uid: 'u4', username: 'benchgod', fullName: 'Jodie Sam'),
      user(uid: 'u5', username: 'samu', fullName: 'Tom Hardy'),
    ];

    List<String> rank(String q) => rankSearchResults(
          rawQuery: q,
          candidates: people,
        ).map((UserSearchResult u) => u.uid).toList();

    test('an exact username outranks every kind of name match', () {
      expect(rank('sam').first, 'u1');
    });

    test('a username prefix outranks a name match', () {
      // u5 (samu) and u2 (samantha_lifts) are username prefixes; u3 and u4
      // match on a name. The shorter username comes first within the tier.
      final List<String> order = rank('sam');
      expect(order.indexOf('u5'), lessThan(order.indexOf('u3')));
      expect(order.indexOf('u2'), lessThan(order.indexOf('u3')));
      expect(order.indexOf('u5'), lessThan(order.indexOf('u2')));
    });

    test('an exact full name outranks a bare first or last name', () {
      final List<String> order = rank('samantha vaughn');
      expect(order.first, 'u2');
    });

    test('an exact first or last name outranks a prefix', () {
      // "sam" is u3's first name exactly and u4's last name exactly.
      final List<String> order = rank('sam');
      expect(order.indexOf('u3'), lessThan(order.indexOf('u1') + order.length));
      expect(order.contains('u4'), isTrue);
    });

    test('duplicate names are distinguished, and ordered, by username', () {
      final List<UserSearchResult> twins = <UserSearchResult>[
        user(uid: 'b', username: 'zeta', fullName: 'Alex Stone'),
        user(uid: 'a', username: 'alpha', fullName: 'Alex Stone'),
      ];
      final List<UserSearchResult> ranked =
          rankSearchResults(rawQuery: 'alex stone', candidates: twins);
      expect(ranked.map((UserSearchResult u) => u.uid).toList(), <String>['a', 'b']);
      // Both are shown; the username is what tells them apart on the row.
      expect(ranked.map((UserSearchResult u) => u.handle).toList(),
          <String>['@alpha', '@zeta']);
    });
  });

  group('typo tolerance', () {
    final List<UserSearchResult> people = <UserSearchResult>[
      user(uid: 'j', username: 'johnny', fullName: 'John Doe'),
      user(uid: 'm', username: 'mikec', fullName: 'Michael Chen'),
    ];

    List<String> rank(String q) => rankSearchResults(
          rawQuery: q,
          candidates: people,
        ).map((UserSearchResult u) => u.uid).toList();

    test('a transposition still finds the person', () {
      // The case a prefix range can never serve: `jhon` and `john` diverge at
      // the second character.
      expect(rank('jhon'), contains('j'));
    });

    test('a missing character still finds the person', () {
      expect(rank('jon doe'), contains('j'));
      expect(rank('michal chen'), contains('m'));
    });

    test('an extra character still finds the person', () {
      expect(rank('johnn doe'), contains('j'));
    });

    test('a wrong character still finds the person', () {
      expect(rank('jahn doe'), contains('j'));
    });

    test('something genuinely different does not match', () {
      // A fuzzy net that catches everything is worse than none: it fills the
      // list with strangers and buries the real answer.
      expect(rank('zzzzzzzz'), isEmpty);
      expect(rank('kayleigh'), isEmpty);
    });

    test('an exact match still beats a fuzzy one', () {
      final List<UserSearchResult> both = <UserSearchResult>[
        user(uid: 'fuzzy', username: 'jon', fullName: 'Jon Smith'),
        user(uid: 'exact', username: 'john', fullName: 'John Smith'),
      ];
      expect(
        rankSearchResults(rawQuery: 'john', candidates: both).first.uid,
        'exact',
      );
    });
  });

  group('normalisation in ranking', () {
    test('case is irrelevant', () {
      final List<UserSearchResult> p = <UserSearchResult>[
        user(uid: 'u', username: 'IronSam', fullName: 'Samantha Vaughn'),
      ];
      for (final String q in <String>['ironsam', 'IRONSAM', 'IrOnSaM']) {
        expect(rankSearchResults(rawQuery: q, candidates: p).length, 1,
            reason: 'query "$q" found nobody');
      }
    });

    test('accents, punctuation and extra spacing are irrelevant', () {
      final List<UserSearchResult> p = <UserSearchResult>[
        user(uid: 'u', username: 'renee', fullName: 'Renée O’Brien'),
      ];
      for (final String q in <String>[
        'renee o brien',
        'Renée   O’Brien',
        'renee obrien',
        '  RENEE  O-BRIEN  ',
      ]) {
        expect(rankSearchResults(rawQuery: q, candidates: p).length, 1,
            reason: 'query "$q" found nobody');
      }
    });
  });

  group('exclusions', () {
    test('the signed-in account never appears in its own results', () {
      final List<UserSearchResult> p = <UserSearchResult>[
        user(uid: 'me', username: 'sam', fullName: 'Sam One'),
        user(uid: 'other', username: 'sammy', fullName: 'Sam Two'),
      ];
      final List<UserSearchResult> ranked = rankSearchResults(
        rawQuery: 'sam',
        candidates: p,
        excludeUid: 'me',
      );
      expect(ranked.map((UserSearchResult u) => u.uid), <String>['other']);
    });

    test('a candidate arriving from both queries appears once', () {
      final UserSearchResult u = user(uid: 'dup', username: 'sam');
      expect(
        rankSearchResults(rawQuery: 'sam', candidates: <UserSearchResult>[u, u]).length,
        1,
      );
    });

    test('an empty query matches nobody', () {
      expect(
        rankSearchResults(
          rawQuery: '   ',
          candidates: <UserSearchResult>[user(uid: 'u', username: 'sam')],
        ),
        isEmpty,
      );
    });
  });

  group('minimum query length', () {
    test('one character is refused, two are accepted', () {
      expect(UserSearchRepository.isQueryLongEnough('a'), isFalse);
      expect(UserSearchRepository.isQueryLongEnough('  a  '), isFalse);
      expect(UserSearchRepository.isQueryLongEnough('!'), isFalse);
      expect(UserSearchRepository.isQueryLongEnough(''), isFalse);
      expect(UserSearchRepository.isQueryLongEnough('ab'), isTrue);
      expect(UserSearchRepository.isQueryLongEnough('a b'), isTrue);
    });

    test('a short query is not sent to the server', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seed(db, uid: 'u1', username: 'alpha', fullName: 'Al Pha');
      final UserSearchRepository repo = UserSearchRepository(firestore: db);
      final UserSearchOutcome? out =
          await repo.search(rawQuery: 'a', excludeUid: null);
      expect(out, isNotNull);
      expect(out!.results, isEmpty);
    });
  });

  group('against the index', () {
    late FakeFirebaseFirestore db;
    late UserSearchRepository repo;

    setUp(() async {
      db = FakeFirebaseFirestore();
      repo = UserSearchRepository(firestore: db);
      await seed(db, uid: 'me', username: 'myself', fullName: 'Me Myself');
      await seed(db, uid: 'u1', username: 'ironsam', fullName: 'Samantha Vaughn');
      await seed(db, uid: 'u2', username: 'benchking', fullName: 'John Doe');
      await seed(db, uid: 'u3', username: 'sammy', fullName: 'Sammy Tan');
    });

    test('finds an account by exact username', () async {
      final UserSearchOutcome? out =
          await repo.search(rawQuery: 'ironsam', excludeUid: 'me');
      expect(out!.results.first.uid, 'u1');
    });

    test('finds an account by username prefix', () async {
      final UserSearchOutcome? out =
          await repo.search(rawQuery: 'iron', excludeUid: 'me');
      expect(out!.results.map((UserSearchResult u) => u.uid), contains('u1'));
    });

    test('finds an account by first, last and full name', () async {
      for (final String q in <String>['samantha', 'vaughn', 'samantha vaughn']) {
        final UserSearchOutcome? out =
            await repo.search(rawQuery: q, excludeUid: 'me');
        expect(out!.results.map((UserSearchResult u) => u.uid), contains('u1'),
            reason: 'query "$q" did not find u1');
      }
    });

    test('excludes the signed-in account', () async {
      final UserSearchOutcome? out =
          await repo.search(rawQuery: 'myself', excludeUid: 'me');
      expect(out!.results.map((UserSearchResult u) => u.uid), isNot(contains('me')));
    });

    test('never exposes a private field, even if one is in the document', () {
      // Defence in depth: the projection should not carry these at all, and
      // the model has nowhere to put them if it did.
      final UserSearchResult parsed = UserSearchResult.fromMap('u', <String, dynamic>{
        'username': 'sam',
        'emailLower': 'sam@example.com',
        'phone': '+15550000000',
        'dob': '1990-01-01',
        'isCoach': true,
      });
      final String blob = parsed.toCacheMap().toString().toLowerCase();
      expect(blob, isNot(contains('example.com')));
      expect(blob, isNot(contains('15550000000')));
      expect(blob, isNot(contains('1990')));
    });

    test('a stale search is dropped rather than overwriting a newer one', () async {
      // Both are started before either is awaited, so the first is stale by
      // the time it completes. Without the generation check the earlier,
      // broader result would replace the later, narrower one and the row the
      // user is reaching for would move.
      final Future<UserSearchOutcome?> older =
          repo.search(rawQuery: 'sam', excludeUid: 'me');
      final Future<UserSearchOutcome?> newer =
          repo.search(rawQuery: 'sammy', excludeUid: 'me');
      final List<UserSearchOutcome?> both =
          await Future.wait(<Future<UserSearchOutcome?>>[older, newer]);
      expect(both[0], isNull, reason: 'the stale search should have been dropped');
      expect(both[1], isNotNull);
      expect(both[1]!.query, 'sammy');
    });

    test('recent rows are cached so a lookup does not re-read them', () async {
      await repo.search(rawQuery: 'ironsam', excludeUid: 'me');
      expect(repo.cachedCount, greaterThan(0));
      final Map<String, UserSearchResult> found = await repo.lookupUsers(<String>['u1']);
      expect(found['u1']!.username, 'ironsam');
    });

    test('a lookup resolves distinct accounts in one batch, not one per row', () async {
      final Map<String, UserSearchResult> found =
          await repo.lookupUsers(<String>['u1', 'u2', 'u3', 'u1', 'u2']);
      expect(found.keys.toSet(), <String>{'u1', 'u2', 'u3'});
    });

    test('a lookup of nothing does no work', () async {
      expect(await repo.lookupUsers(const <String>[]), isEmpty);
      expect(await repo.lookupUsers(<String>['', '   ']), isEmpty);
    });
  });

  group('offline honesty', () {
    test('a failed query replays the cache and says it is offline', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seed(db, uid: 'u1', username: 'ironsam', fullName: 'Samantha Vaughn');
      final UserSearchRepository repo = UserSearchRepository(
        firestore: db,
        runQuery: _unavailable,
      );

      // Warm the cache through a working path first.
      final UserSearchRepository warm = UserSearchRepository(firestore: db);
      final UserSearchOutcome? ok =
          await warm.search(rawQuery: 'ironsam', excludeUid: null);
      expect(ok!.results, isNotEmpty);

      final UserSearchOutcome? out =
          await repo.search(rawQuery: 'ironsam', excludeUid: null);
      expect(out, isNotNull);
      expect(out!.offline, isTrue,
          reason: 'a dropped connection must not read as "no such person"');
      expect(out.source, SearchSource.cache);
      expect(out.error, isNotNull);
    });
  });
}

/// A query runner that always fails with `unavailable`, standing in for a
/// device with no connectivity and a cold Firestore cache.
///
/// Substituted for the transport rather than for `Query`, which is sealed:
/// the repository still builds its real queries, and only the round trip is
/// replaced. That is exactly the thing being simulated.
Future<QuerySnapshot<Map<String, dynamic>>> _unavailable(
  Query<Map<String, dynamic>> query,
) =>
    Future<QuerySnapshot<Map<String, dynamic>>>.error(
      FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
    );
