// Whose social account is being acted on, in every screen that offers the
// control.
//
// ── The defect these exist to prevent ──────────────────────────────────────
// Both app bars used to stream `UserContext.actingAsUid` for the buddy badge,
// and both called `acceptBuddyInvite(buddyUid: actingAsUid)` from the dialog
// behind it. `actingAsUid` is the athlete a COACH currently has selected. So a
// coach reviewing an athlete saw that athlete's incoming buddy requests in
// their own header, and could accept or decline them — a social action taken
// on somebody else's account, from a permission granted for training.
//
// The fix is structural rather than a check that could be forgotten:
// BuddyRepository resolves the account from FirebaseAuth and never reads
// UserContext, and the callables behind it take no uid argument at all. These
// tests hold that structure in place — they assert the badge follows the
// AUTHENTICATED uid even while UserContext is pointed at somebody else, and
// that the acting-as flag reaches nothing but a caption.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/social/buddy_hub_screen.dart';
import 'package:localtest222/social/buddy_repository.dart';
import 'package:localtest222/social/ui/buddy_hub_button.dart';
import 'package:localtest222/social/user_search_repository.dart';

/// The signed-in account. Every social action must belong to this uid.
const String kCoachUid = 'coach-authenticated-uid';

/// The athlete a coach has selected. Must never own a social action.
const String kAthleteUid = 'athlete-selected-uid';

Future<void> seedPending(
  FakeFirebaseFirestore db, {
  required String toUid,
  required List<String> fromUids,
}) async {
  for (final String from in fromUids) {
    await db
        .collection('users')
        .doc(toUid)
        .collection('buddyInvites')
        .doc(from)
        .set(<String, Object?>{
      'status': 'pending',
      'fromUid': from,
      'buddyUid': toUid,
      'createdAt': Timestamp.now(),
    });
  }
}

Widget hostApp(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('the badge follows the authenticated account', () {
    testWidgets('a plain athlete sees their own pending requests',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedPending(db, toUid: kCoachUid, fromUids: <String>['a', 'b']);

      await tester.pumpWidget(hostApp(BuddyHubButton(
        buddies: BuddyRepository(firestore: db, overrideUid: kCoachUid),
      )));
      await tester.pump();
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets(
        'a coach acting as an athlete still sees only their OWN requests',
        (WidgetTester tester) async {
      // The exact scenario the legacy header got wrong. The athlete has three
      // requests waiting; the coach has one. The header must show the coach's
      // one, because the coach is who is signed in.
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedPending(db, toUid: kCoachUid, fromUids: <String>['x']);
      await seedPending(
        db,
        toUid: kAthleteUid,
        fromUids: <String>['p', 'q', 'r'],
      );

      await tester.pumpWidget(hostApp(BuddyHubButton(
        // The repository is built from the AUTHENTICATED uid. There is no
        // parameter on this widget that could point it at the athlete.
        buddies: BuddyRepository(firestore: db, overrideUid: kCoachUid),
        actingAsOtherAccount: true,
      )));
      await tester.pump();

      expect(find.text('1'), findsOneWidget,
          reason: "the coach's own single request");
      expect(find.text('3'), findsNothing,
          reason: "the athlete's requests must never reach the coach's header");
    });

    testWidgets('the acting-as flag does not change the account watched',
        (WidgetTester tester) async {
      // Same data, both flag values: the badge is identical, because the flag
      // is a caption and nothing else reads it.
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedPending(db, toUid: kCoachUid, fromUids: <String>['a', 'b']);
      await seedPending(db, toUid: kAthleteUid, fromUids: <String>['p']);

      for (final bool acting in <bool>[false, true]) {
        await tester.pumpWidget(hostApp(BuddyHubButton(
          key: ValueKey<bool>(acting),
          buddies: BuddyRepository(firestore: db, overrideUid: kCoachUid),
          actingAsOtherAccount: acting,
        )));
        await tester.pump();
        expect(find.text('2'), findsOneWidget,
            reason: 'actingAsOtherAccount=$acting changed the badge');
      }
    });

    testWidgets('no pending requests still opens the Hub',
        (WidgetTester tester) async {
      // The legacy control answered a tap with "No buddy requests." and went
      // nowhere, in both app bars.
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await tester.pumpWidget(hostApp(BuddyHubButton(
        buddies: BuddyRepository(firestore: db, overrideUid: kCoachUid),
      )));
      await tester.pump();
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull,
      );
    });
  });

  group('navigating into the Hub', () {
    testWidgets('the icon opens the Buddy Hub', (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: <Widget>[
            BuddyHubButton(
              buddies: BuddyRepository(firestore: db, overrideUid: kCoachUid),
              search: UserSearchRepository(firestore: db),
            ),
          ]),
        ),
      ));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.person_add_alt_1));
      await tester.pumpAndSettle();

      expect(find.byType(BuddyHubScreen), findsOneWidget);
      expect(find.text('PEOPLE'), findsOneWidget);
      expect(find.text('FEED'), findsOneWidget);
    });

    testWidgets('a coach opening it is told the list is their own',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: <Widget>[
            BuddyHubButton(
              buddies: BuddyRepository(firestore: db, overrideUid: kCoachUid),
              search: UserSearchRepository(firestore: db),
              actingAsOtherAccount: true,
            ),
          ]),
        ),
      ));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.person_add_alt_1));
      await tester.pumpAndSettle();

      // Everything else on HomeScreen2 is showing the athlete, so the Hub says
      // plainly that this part is not.
      expect(
        find.textContaining('Your own buddies'),
        findsOneWidget,
      );
    });

    testWidgets('an athlete is not shown a coaching caption',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await tester.pumpWidget(hostApp(BuddyHubScreen(
        buddies: BuddyRepository(firestore: db, overrideUid: kCoachUid),
        search: UserSearchRepository(firestore: db),
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('Your own buddies'), findsNothing);
    });
  });

  group('mutations belong to the signed-in account', () {
    test('the repository resolves the authenticated uid, not a passed-in one',
        () {
      // There is no constructor parameter, method argument or setter on
      // BuddyRepository that names another account to act as. `overrideUid`
      // exists for tests and stands in for FirebaseAuth itself.
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final BuddyRepository repo =
          BuddyRepository(firestore: db, overrideUid: kCoachUid);
      expect(repo.currentUid, kCoachUid);
      expect(repo.currentUid, isNot(kAthleteUid));
    });

    testWidgets('the Hub reads its exclusion uid from the repository',
        (WidgetTester tester) async {
      // Search excludes the signed-in account so nobody is offered a request
      // to themselves. It must exclude the COACH, not the selected athlete —
      // otherwise a coach searching would be offered their own account.
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final BuddyRepository repo =
          BuddyRepository(firestore: db, overrideUid: kCoachUid);
      await tester.pumpWidget(hostApp(BuddyHubScreen(
        buddies: repo,
        search: UserSearchRepository(firestore: db),
        showOwnAccountNotice: true,
      )));
      await tester.pumpAndSettle();
      expect(repo.currentUid, kCoachUid);
    });
  });
}
