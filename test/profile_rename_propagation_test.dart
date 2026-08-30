import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/data/identity_repository.dart';
import 'package:localtest222/profile/ui/live_identity.dart';

/// A rename has to reach every surface that shows a name — post headers,
/// historical comments, DM rows, the leaderboard, the coach roster — WITHOUT
/// restarting the app.
///
/// Two things stopped it before:
///
///   * Several surfaces preferred the DENORMALISED copy on the document
///     (`comments.username`, `buddyAssignments…displayName`, roster rows). That
///     copy records what the author was called when the document was written,
///     so a rename left the old name on every comment the person had ever
///     made, forever.
///   * The surfaces that did look the uid up cached the answer in a
///     process-lifetime map with `putIfAbsent`, which by construction reads
///     each uid exactly once per process. A rename made during the session was
///     invisible until the app was killed and reopened.
///
/// These tests mount a widget, rename the account in Firestore underneath it,
/// pump, and assert the widget now shows the new name — with no rebuild of the
/// widget tree, no new repository, and no restart.
void main() {
  const String uid = 'renamedUid';

  late FakeFirebaseFirestore db;
  late IdentityRepository identity;

  setUp(() {
    db = FakeFirebaseFirestore();
    identity = IdentityRepository(firestore: db);
  });

  Future<void> seed(String username, {String? photoURL}) =>
      db.collection('users_public').doc(uid).set(<String, Object?>{
        'username': username,
        'usernameLower': username.toLowerCase(),
        'displayName': username,
        if (photoURL != null) 'photoURL': photoURL,
      });

  Future<void> rename(String username) =>
      db.collection('users_public').doc(uid).set(<String, Object?>{
        'username': username,
        'usernameLower': username.toLowerCase(),
        'displayName': username,
      }, SetOptions(merge: true));

  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  group('a rename reaches the screen with no restart', () {
    testWidgets('a name resolved by uid updates live', (WidgetTester t) async {
      await seed('BenchKing');
      await t.pumpWidget(wrap(LiveUserName(uid: uid, identity: identity)));
      await t.pumpAndSettle();
      expect(find.text('BenchKing'), findsOneWidget);

      await rename('SquatQueen');
      await t.pumpAndSettle();

      expect(find.text('SquatQueen'), findsOneWidget);
      expect(find.text('BenchKing'), findsNothing);
    });

    testWidgets('the DENORMALISED name loses to the live one',
        (WidgetTester t) async {
      // This is the historical-comment case: the comment document says
      // "BenchKing" because that is who wrote it, and the person is now called
      // SquatQueen. The comment must show who they ARE.
      await seed('SquatQueen');
      await t.pumpWidget(wrap(
        LiveUserName(uid: uid, fallback: 'BenchKing', identity: identity),
      ));
      await t.pumpAndSettle();

      expect(find.text('SquatQueen'), findsOneWidget);
      expect(find.text('BenchKing'), findsNothing,
          reason: 'the stored copy is audit data, not identity');
    });

    testWidgets('the denormalised name IS used while nothing else is known',
        (WidgetTester t) async {
      // No document at all: an account that has been deleted, or a cold
      // offline cache. Showing the historical name beats showing nothing, and
      // beats showing a raw uid.
      await t.pumpWidget(wrap(
        LiveUserName(uid: uid, fallback: 'BenchKing', identity: identity),
      ));
      await t.pumpAndSettle();
      expect(find.text('BenchKing'), findsOneWidget);
    });

    testWidgets('with neither, a readable placeholder is shown, not a uid',
        (WidgetTester t) async {
      await t.pumpWidget(wrap(LiveUserName(uid: uid, identity: identity)));
      await t.pumpAndSettle();
      expect(find.text(kUnknownAthleteName), findsOneWidget);
      expect(find.text(uid), findsNothing);
    });

    testWidgets('several surfaces showing one person all update together',
        (WidgetTester t) async {
      // Twenty comments by one author, a post header and a roster row are all
      // on screen at once. They share ONE listener and they must all change in
      // the same frame — the old per-widget cache made each of them decide
      // independently, and once.
      await seed('BenchKing');
      await t.pumpWidget(wrap(Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < 5; i++)
            LiveUserName(
              key: ValueKey<int>(i),
              uid: uid,
              fallback: 'BenchKing',
              identity: identity,
            ),
        ],
      )));
      await t.pumpAndSettle();
      expect(find.text('BenchKing'), findsNWidgets(5));

      await rename('SquatQueen');
      await t.pumpAndSettle();

      expect(find.text('SquatQueen'), findsNWidgets(5));
      expect(find.text('BenchKing'), findsNothing);
    });

    testWidgets('two people are resolved independently',
        (WidgetTester t) async {
      await seed('BenchKing');
      await db.collection('users_public').doc('other').set(<String, Object?>{
        'username': 'DeadliftDan',
      });
      await t.pumpWidget(wrap(Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          LiveUserName(uid: uid, identity: identity),
          LiveUserName(uid: 'other', identity: identity),
        ],
      )));
      await t.pumpAndSettle();
      expect(find.text('BenchKing'), findsOneWidget);
      expect(find.text('DeadliftDan'), findsOneWidget);

      await rename('SquatQueen');
      await t.pumpAndSettle();
      expect(find.text('SquatQueen'), findsOneWidget);
      expect(find.text('DeadliftDan'), findsOneWidget,
          reason: 'renaming one account must not disturb another');
    });
  });

  group('the repository underneath', () {
    test('watchPublicIdentity emits every change', () async {
      await seed('BenchKing');
      final List<String?> seen = <String?>[];
      final Stream<PublicIdentity> stream = identity.watchPublicIdentity(uid);
      final Future<void> collected = stream
          .map((PublicIdentity i) => i.displayName)
          .take(3)
          .forEach(seen.add);

      await Future<void>.delayed(Duration.zero);
      await rename('SquatQueen');
      await Future<void>.delayed(Duration.zero);
      await rename('OverheadOli');
      await collected;

      expect(seen, <String>['BenchKing', 'SquatQueen', 'OverheadOli']);
    });

    test('one channel per uid serves every caller', () async {
      // Twenty comments by one author cost ONE Firestore listener, and a
      // second caller joins the SAME channel rather than opening another.
      await seed('BenchKing');
      expect(identity.hasOpenChannel(uid), isFalse);

      // One caller resolves and then LEAVES. asBroadcastStream() cancelled the
      // upstream subscription at that point and never restarted it, so every
      // later subscriber got nothing — the same "read once and never again"
      // failure the old process-lifetime cache had, by another route.
      final Stream<PublicIdentity> first = identity.watchPublicIdentity(uid);
      expect((await first.first).displayName, 'BenchKing');
      expect(identity.hasOpenChannel(uid), isTrue);

      // A later caller joins the SAME channel and is replayed the last known
      // value immediately, rather than waiting for the next change.
      expect((await identity.watchPublicIdentity(uid).first).displayName,
          'BenchKing');

      // And the channel is still following the document.
      await rename('SquatQueen');
      expect(
        (await identity.watchPublicIdentity(uid).firstWhere(
                (PublicIdentity i) => i.displayName == 'SquatQueen'))
            .displayName,
        'SquatQueen',
      );
    });

    test('a resolved name is cached for the next first frame', () async {
      await seed('BenchKing');
      expect(identity.cachedPublicIdentity(uid), isNull);
      await identity.watchPublicIdentity(uid).first;
      expect(identity.cachedPublicIdentity(uid)!.displayName, 'BenchKing');
    });

    test('an empty uid resolves to nothing rather than reading a document',
        () async {
      final PublicIdentity resolved =
          await identity.watchPublicIdentity('').first;
      expect(resolved.displayName, isNull);
    });

    test('the avatar travels on the same stream as the name', () async {
      // LiveUserAvatar reads photoURL from this, so replacing an avatar
      // reaches every post header and roster row the same way a rename does.
      // Asserted here rather than through the widget because a rendered
      // NetworkImage would attempt a real HTTP fetch under the test binding.
      await seed('BenchKing', photoURL: 'https://example.invalid/old.jpg');
      final List<String?> seen = <String?>[];
      final Future<void> collected = identity
          .watchPublicIdentity(uid)
          .map((PublicIdentity i) => i.photoURL)
          .take(2)
          .forEach(seen.add);

      await Future<void>.delayed(Duration.zero);
      await db.collection('users_public').doc(uid).set(<String, Object?>{
        'photoURL': 'https://example.invalid/new.jpg',
      }, SetOptions(merge: true));
      await collected;

      expect(seen, <String>[
        'https://example.invalid/old.jpg',
        'https://example.invalid/new.jpg',
      ]);
    });

    test('watchDisplayName is the same stream, narrowed', () async {
      await seed('BenchKing');
      expect(await identity.watchDisplayName(uid).first, 'BenchKing');
    });

    test('username wins over displayName when they disagree', () async {
      // username is the reserved, authoritative field; displayName is its
      // mirror and can briefly lag a reconciliation.
      await db.collection('users_public').doc(uid).set(<String, Object?>{
        'username': 'Current',
        'displayName': 'Stale',
      });
      expect(await identity.watchDisplayName(uid).first, 'Current');
    });
  });
}
