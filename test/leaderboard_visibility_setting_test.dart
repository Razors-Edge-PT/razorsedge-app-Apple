import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/leaderboard/leaderboard_visibility.dart';

/// A repository whose stream and save the test controls.
class _ScriptedRepository extends LeaderboardVisibilityRepository {
  _ScriptedRepository() : super(firestore: FakeFirebaseFirestore());

  final StreamController<bool> values = StreamController<bool>.broadcast();
  final List<(String, bool)> saves = <(String, bool)>[];
  Completer<void>? pendingSave;

  @override
  Stream<bool> watch(String uid) => values.stream;

  @override
  Future<void> setVisible(String uid, bool visible) {
    saves.add((uid, visible));
    pendingSave = Completer<void>();
    return pendingSave!.future;
  }
}

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SingleChildScrollView(child: child),
      ),
    );

bool _switchValue(WidgetTester tester) => tester
    .widget<SwitchListTile>(find.byKey(const Key('leaderboardVisibilitySwitch')))
    .value;

bool _switchEnabled(WidgetTester tester) =>
    tester
        .widget<SwitchListTile>(
            find.byKey(const Key('leaderboardVisibilitySwitch')))
        .onChanged !=
    null;

/// fake_cloud_firestore's transaction fires its writes without awaiting
/// them (a real one completes after the server commit), so let them land.
Future<void> _settleFakeTransaction() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  group('LeaderboardVisibilityRepository', () {
    test('no document, no field or true → visible; only false hides', () {
      expect(LeaderboardVisibilityRepository.visibleOf(null), isTrue);
      expect(LeaderboardVisibilityRepository.visibleOf(<String, dynamic>{}),
          isTrue);
      expect(
          LeaderboardVisibilityRepository.visibleOf(
              <String, dynamic>{'leaderboardVisible': true}),
          isTrue);
      expect(
          LeaderboardVisibilityRepository.visibleOf(
              <String, dynamic>{'leaderboardVisible': false}),
          isFalse);
    });

    test('a save writes only the owner\'s own document, merged', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await db.collection('users').doc('me').set(<String, Object?>{
        'username': 'me',
        'dob': '01-01-1990',
      });
      await db.collection('users').doc('athlete').set(<String, Object?>{
        'username': 'athlete',
      });
      final LeaderboardVisibilityRepository repo =
          LeaderboardVisibilityRepository(firestore: db);

      expect(await repo.watch('me').first, isTrue, reason: 'existing user');
      expect(await repo.watch('brand-new').first, isTrue, reason: 'new user');

      await repo.setVisible('me', false);
      await _settleFakeTransaction();
      final Map<String, dynamic> me =
          (await db.collection('users').doc('me').get()).data()!;
      expect(me['leaderboardVisible'], isFalse);
      expect(me['dob'], '01-01-1990', reason: 'other profile fields untouched');
      expect(await repo.watch('me').first, isFalse);
      expect(
          (await db.collection('users').doc('athlete').get())
              .data()!
              .containsKey('leaderboardVisible'),
          isFalse);

      await repo.setVisible('me', true);
      await _settleFakeTransaction();
      expect(await repo.watch('me').first, isTrue);
    });
  });

  group('LeaderboardVisibilitySetting', () {
    testWidgets('shows the label and helper text, ON by default', (tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await db.collection('users').doc('me').set(<String, Object?>{'x': 1});
      await tester.pumpWidget(_host(LeaderboardVisibilitySetting(
        ownerUid: 'me',
        actingAsSelf: true,
        repository: LeaderboardVisibilityRepository(firestore: db),
      )));
      await tester.pumpAndSettle();
      expect(find.text('Show me on leaderboards'), findsOneWidget);
      expect(
          find.text(
              "When turned off, your name and RE Points won't appear on GoodLift's monthly, all-time or public website leaderboards."),
          findsOneWidget);
      expect(_switchValue(tester), isTrue);
      expect(_switchEnabled(tester), isTrue);
    });

    testWidgets('shows a saved OFF accurately', (tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await db
          .collection('users')
          .doc('me')
          .set(<String, Object?>{'leaderboardVisible': false});
      await tester.pumpWidget(_host(LeaderboardVisibilitySetting(
        ownerUid: 'me',
        actingAsSelf: true,
        repository: LeaderboardVisibilityRepository(firestore: db),
      )));
      await tester.pumpAndSettle();
      expect(_switchValue(tester), isFalse);
    });

    testWidgets('turning it off saves for the signed-in uid and confirms only after the server',
        (tester) async {
      final _ScriptedRepository repo = _ScriptedRepository();
      await tester.pumpWidget(_host(LeaderboardVisibilitySetting(
          ownerUid: 'me', actingAsSelf: true, repository: repo)));
      // Loading: disabled until the saved value is known.
      expect(_switchEnabled(tester), isFalse);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      repo.values.add(true);
      await tester.pump();
      expect(_switchEnabled(tester), isTrue);

      await tester.tap(find.byKey(const Key('leaderboardVisibilitySwitch')));
      await tester.pump();
      expect(repo.saves, <(String, bool)>[('me', false)]);
      expect(_switchValue(tester), isTrue,
          reason: 'still the SAVED value while the write is in flight');
      expect(_switchEnabled(tester), isFalse);
      expect(find.text('Saving…'), findsOneWidget);

      repo.pendingSave!.complete();
      await tester.pump();
      expect(_switchValue(tester), isFalse);
      expect(find.text(kLeaderboardHiddenSaved), findsOneWidget);
      expect(find.textContaining('up to two hours'), findsOneWidget,
          reason: 'the website delay is not hidden behind "instant"');
    });

    testWidgets('a failed save changes nothing and says so', (tester) async {
      final _ScriptedRepository repo = _ScriptedRepository();
      await tester.pumpWidget(_host(LeaderboardVisibilitySetting(
          ownerUid: 'me', actingAsSelf: true, repository: repo)));
      repo.values.add(true);
      await tester.pump();
      await tester.tap(find.byKey(const Key('leaderboardVisibilitySwitch')));
      await tester.pump();
      repo.pendingSave!.completeError(Exception('offline'));
      await tester.pump();
      expect(_switchValue(tester), isTrue, reason: 'nothing was applied');
      expect(find.text(kLeaderboardSaveFailed), findsOneWidget);
      expect(find.text(kLeaderboardHiddenSaved), findsNothing);
      expect(_switchEnabled(tester), isTrue, reason: 'can try again');
    });

    testWidgets('a load error is shown with a retry, never a guessed value',
        (tester) async {
      final _ScriptedRepository repo = _ScriptedRepository();
      await tester.pumpWidget(_host(LeaderboardVisibilitySetting(
          ownerUid: 'me', actingAsSelf: true, repository: repo)));
      repo.values.addError(Exception('denied'));
      await tester.pump();
      expect(find.text(kLeaderboardLoadFailed), findsOneWidget);
      expect(_switchEnabled(tester), isFalse);
      await tester.tap(find.byKey(const Key('leaderboardVisibilityRetry')));
      await tester.pump();
      repo.values.add(false);
      await tester.pump();
      expect(find.text(kLeaderboardLoadFailed), findsNothing);
      expect(_switchValue(tester), isFalse);
    });

    testWidgets('a coach acting as an athlete gets a note, never a switch',
        (tester) async {
      final _ScriptedRepository repo = _ScriptedRepository();
      await tester.pumpWidget(_host(LeaderboardVisibilitySetting(
          ownerUid: 'coach', actingAsSelf: false, repository: repo)));
      await tester.pump();
      expect(find.byKey(const Key('leaderboardVisibilitySwitch')), findsNothing);
      expect(find.text(kLeaderboardVisibilityCoachNote), findsOneWidget);
      expect(repo.values.hasListener, isFalse,
          reason: "nobody's choice is even read");
      expect(repo.saves, isEmpty);
    });

    testWidgets('signed out: nothing to change', (tester) async {
      final _ScriptedRepository repo = _ScriptedRepository();
      await tester.pumpWidget(_host(LeaderboardVisibilitySetting(
          ownerUid: null, actingAsSelf: true, repository: repo)));
      await tester.pump();
      expect(find.byKey(const Key('leaderboardVisibilitySwitch')), findsNothing);
      expect(repo.saves, isEmpty);
    });
  });
}
