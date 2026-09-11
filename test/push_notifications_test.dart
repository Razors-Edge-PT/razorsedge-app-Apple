// Push notifications — client behaviour, with FCM, Firestore registration and
// local state all faked. Nothing here talks to Firebase.
//
// Server-side delivery (who is sent what) is covered by the functions suites:
// functions/test/push_model.test.js, functions/test-emulator/
// push_delivery.spec.js and functions/test-rules/push_rules.spec.js.

import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart' show AuthorizationStatus;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/push/foreground_conversation.dart';
import 'package:localtest222/push/notification_platform.dart';
import 'package:localtest222/push/notification_settings_screen.dart';
import 'package:localtest222/push/push_intent.dart';
import 'package:localtest222/push/push_notification_service.dart';
import 'package:localtest222/push/push_router.dart';

const String alice = 'aliceUidaliceUidaliceUid0001';
const String bob = 'bobUidbobUidbobUidbobUid0002';
const String athlete = 'athleteUidathleteUidathle03';

Map<String, dynamic> dmData({String to = alice, String from = bob}) => <String, dynamic>{
      'v': '1',
      'type': 'directMessage',
      'recipientUid': to,
      'actorUid': from,
      'convId': conversationIdFor(to, from),
    };

Map<String, dynamic> requestData({String to = alice, String from = bob}) => <String, dynamic>{
      'v': '1',
      'type': 'friendRequest',
      'recipientUid': to,
      'actorUid': from,
    };

// ── Fakes ───────────────────────────────────────────────────────────────────

/// Adapter-level fake: returns RAW plugin statuses, as the production adapter
/// does. (test/push_permission_routing_test.dart drives the real
/// FirebasePushMessagingAdapter itself.)
class FakeMessaging implements PushMessagingAdapter {
  AuthorizationStatus status = AuthorizationStatus.authorized;
  AuthorizationStatus onRequest = AuthorizationStatus.authorized;
  String? token = 'token-1';
  Completer<String?>? tokenGate;
  bool deleteFails = false;
  bool deleteHangs = false;
  int deleteCalls = 0;
  int requestCalls = 0;
  final List<String> log = <String>[];
  PushMessage? initial;

  final StreamController<String> refresh = StreamController<String>.broadcast();
  final StreamController<PushMessage> foreground = StreamController<PushMessage>.broadcast();
  final StreamController<PushMessage> opened = StreamController<PushMessage>.broadcast();

  @override
  Future<AuthorizationStatus> osPermissionStatus() async => status;

  @override
  Future<AuthorizationStatus> requestOsPermission() async {
    requestCalls++;
    status = onRequest;
    return status;
  }

  @override
  Future<String?> getToken() async {
    log.add('getToken');
    if (tokenGate != null) return tokenGate!.future;
    return token;
  }

  @override
  Future<void> deleteToken() async {
    deleteCalls++;
    log.add('deleteToken');
    if (deleteHangs) return Completer<void>().future;
    if (deleteFails) throw Exception('offline');
    token = 'token-after-delete-$deleteCalls';
  }

  @override
  Stream<String> get onTokenRefresh => refresh.stream;
  @override
  Stream<PushMessage> get onForegroundMessage => foreground.stream;
  @override
  Stream<PushMessage> get onOpenedApp => opened.stream;
  @override
  Future<PushMessage?> initialMessage() async {
    final PushMessage? m = initial;
    initial = null;
    return m;
  }
}

class FakeStore implements PushRegistrationStore {
  /// token → owner, as the Firestore document would hold it.
  final Map<String, String> owners = <String, String>{};
  final List<String> calls = <String>[];
  bool hang = false;

  @override
  Future<void> register({
    required String uid,
    required String token,
    required String platform,
    required String appVersion,
  }) async {
    calls.add('register:$uid:$token');
    if (hang) return Completer<void>().future;
    owners[token] = uid;
  }

  @override
  Future<void> unregister({required String token}) async {
    calls.add('unregister:$token');
    if (hang) return Completer<void>().future;
    owners.remove(token);
  }
}

class FakeLocal implements PushLocalState {
  PushRegistrationRecord? record;
  bool pending = false;
  bool primer = false;
  bool requested = false;

  @override
  Future<bool> permissionRequested() async => requested;
  @override
  Future<void> setPermissionRequested() async => requested = true;

  @override
  Future<PushRegistrationRecord?> lastRegistration() async => record;
  @override
  Future<void> saveRegistration(PushRegistrationRecord r) async => record = r;
  @override
  Future<void> clearRegistration() async => record = null;
  @override
  Future<bool> pendingTokenDelete() async => pending;
  @override
  Future<void> setPendingTokenDelete(bool value) async => pending = value;
  @override
  Future<bool> primerShown() async => primer;
  @override
  Future<void> setPrimerShown() async => primer = true;
}

class FakePlatform extends NotificationPlatform {
  int cleared = 0;
  int opened = 0;
  @override
  Future<void> clearDelivered() async => cleared++;
  @override
  Future<void> openSystemSettings() async => opened++;
}

class Harness {
  Harness({String? uid = alice, this.device = const PushPlatformInfo.android(34)})
      : authUid = uid {
    router = PushRouter(
      currentUid: () => authUid,
      navigate: (BuildContext _, PushIntent i, bool Function() valid) async {
        navigated.add(i);
        return true;
      },
      notify: notices.add,
      clock: () => now,
    );
    service = PushNotificationService(
      messaging: messaging,
      store: store,
      local: local,
      router: router,
      platform: platform,
      currentUid: () => authUid,
      appVersion: () async => '1.7.21+91',
      platformName: 'android',
      clock: () => now,
      showBanner: (PushIntent i, PushMessage m) => banners.add(i),
      supported: true,
      platformInfo: () async => device,
    );
  }

  final PushPlatformInfo device;
  String? authUid;
  DateTime now = DateTime(2026, 9, 11, 12);
  final FakeMessaging messaging = FakeMessaging();
  final FakeStore store = FakeStore();
  final FakeLocal local = FakeLocal();
  final FakePlatform platform = FakePlatform();
  final List<PushIntent> navigated = <PushIntent>[];
  final List<String> notices = <String>[];
  final List<PushIntent> banners = <PushIntent>[];
  late final PushRouter router;
  late final PushNotificationService service;
}

Future<void> settle() => Future<void>.delayed(Duration.zero).then((_) => Future<void>.delayed(Duration.zero));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(ForegroundConversation.reset);

  // ── Intent parsing ────────────────────────────────────────────────────────

  group('PushIntent.fromData', () {
    test('parses the three notifications', () {
      expect(PushIntent.fromData(requestData())!.kind, PushKind.friendRequest);
      expect(
        PushIntent.fromData(<String, dynamic>{...requestData(), 'type': 'friendAccepted'})!.kind,
        PushKind.friendAccepted,
      );
      final PushIntent dm = PushIntent.fromData(dmData())!;
      expect(dm.kind, PushKind.directMessage);
      expect(dm.convId, conversationIdFor(alice, bob));
      expect(dm.actorUid, bob);
      expect(dm.recipientUid, alice);
    });

    test('rejects anything else or anything inconsistent', () {
      expect(PushIntent.fromData(<String, dynamic>{...requestData(), 'type': 'marketing'}), isNull);
      expect(PushIntent.fromData(<String, dynamic>{'type': 'friendRequest'}), isNull);
      expect(PushIntent.fromData(requestData(to: alice, from: alice)), isNull, reason: 'self');
      expect(
        PushIntent.fromData(<String, dynamic>{...dmData(), 'convId': conversationIdFor(alice, athlete)}),
        isNull,
        reason: 'a conversation that is not this pair',
      );
      expect(PushIntent.fromData(<String, dynamic>{...dmData()}..remove('convId')), isNull);
    });

    test('registration ids are the lowercase SHA-256 of the token', () {
      expect(
        pushDeviceIdForToken('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });

  // ── Decisions ─────────────────────────────────────────────────────────────

  group('decideDispatch — taps wait for auth and the membership gate', () {
    final PushIntent intent = PushIntent.fromData(dmData(), now: DateTime(2026, 1, 1, 12))!;
    final DateTime soon = DateTime(2026, 1, 1, 12, 0, 5);

    test('waits while auth is still restoring', () {
      expect(decideDispatch(intent: intent, currentUid: null, uiReady: true, now: soon), PushDispatch.wait);
    });
    test('waits until the gated UI is ready', () {
      expect(decideDispatch(intent: intent, currentUid: alice, uiReady: false, now: soon), PushDispatch.wait);
    });
    test('opens for the recipient once ready', () {
      expect(decideDispatch(intent: intent, currentUid: alice, uiReady: true, now: soon), PushDispatch.open);
    });
    test('never opens for another account — no account switching', () {
      expect(decideDispatch(intent: intent, currentUid: bob, uiReady: true, now: soon), PushDispatch.dropOtherAccount);
    });
    test('expires instead of waiting forever', () {
      expect(
        decideDispatch(intent: intent, currentUid: null, uiReady: false, now: soon.add(const Duration(minutes: 5))),
        PushDispatch.dropExpired,
      );
    });
  });

  group('shouldShowForegroundBanner', () {
    final PushIntent dm = PushIntent.fromData(dmData())!;
    final String conv = conversationIdFor(alice, bob);

    test('suppressed only while THAT conversation is on screen and the app is resumed', () {
      expect(shouldShowForegroundBanner(intent: dm, currentUid: alice, visibleConvId: conv, appResumed: true), isFalse);
      expect(shouldShowForegroundBanner(intent: dm, currentUid: alice, visibleConvId: conv, appResumed: false), isTrue,
          reason: 'a page left open in the background does not count');
      expect(shouldShowForegroundBanner(intent: dm, currentUid: alice, visibleConvId: null, appResumed: true), isTrue,
          reason: 'mounted under another screen does not count');
      expect(
        shouldShowForegroundBanner(
            intent: dm, currentUid: alice, visibleConvId: conversationIdFor(alice, athlete), appResumed: true),
        isTrue,
      );
    });

    test('never for another account (Coach Mode viewing an athlete is still the coach)', () {
      final PushIntent forAthlete = PushIntent.fromData(dmData(to: athlete, from: bob))!;
      expect(shouldShowForegroundBanner(intent: forAthlete, currentUid: alice, visibleConvId: null, appResumed: true),
          isFalse);
      expect(shouldShowForegroundBanner(intent: dm, currentUid: null, visibleConvId: null, appResumed: true), isFalse);
    });

    test('social notifications always show', () {
      final PushIntent fr = PushIntent.fromData(requestData())!;
      expect(shouldShowForegroundBanner(intent: fr, currentUid: alice, visibleConvId: conv, appResumed: true), isTrue);
    });
  });

  test('the permission explanation is offered once, and only before the OS asks', () {
    expect(shouldOfferPermissionPrimer(status: PushPermission.notDetermined, alreadyShown: false, signedIn: true), isTrue);
    expect(shouldOfferPermissionPrimer(status: PushPermission.notDetermined, alreadyShown: true, signedIn: true), isFalse);
    expect(shouldOfferPermissionPrimer(status: PushPermission.denied, alreadyShown: false, signedIn: true), isFalse,
        reason: 'a denial is respected — no re-prompt');
    expect(shouldOfferPermissionPrimer(status: PushPermission.granted, alreadyShown: false, signedIn: true), isFalse);
    expect(shouldOfferPermissionPrimer(status: PushPermission.notDetermined, alreadyShown: false, signedIn: false), isFalse);
  });

  test('preferences: categories default on, previews default off', () {
    const PushPreferences d = PushPreferences();
    expect(<bool>[d.friendRequests, d.friendAccepted, d.directMessages, d.messagePreviews],
        <bool>[true, true, true, false]);
    final PushPreferences p = PushPreferences.fromMap(<String, dynamic>{'directMessages': false, 'messagePreviews': 'x'});
    expect(p.directMessages, isFalse);
    expect(p.messagePreviews, isFalse);
    expect(p.withField(PushPreferences.fMessagePreviews, true).messagePreviews, isTrue);
  });

  test('ForegroundConversation tracks the visible thread only', () {
    ForegroundConversation.shown('c1');
    ForegroundConversation.shown('c2');
    expect(ForegroundConversation.visibleConvId, 'c2');
    ForegroundConversation.hidden('c2'); // covered or popped
    expect(ForegroundConversation.visibleConvId, 'c1');
    ForegroundConversation.hidden('c1');
    expect(ForegroundConversation.visibleConvId, isNull);
  });

  // ── Registration ──────────────────────────────────────────────────────────

  group('registration', () {
    test('registers the authenticated account when the OS allows notifications', () async {
      final Harness h = Harness();
      await h.service.onSignedIn(alice);
      expect(h.store.owners, <String, String>{'token-1': alice});
      expect(h.local.record!.uid, alice);

      // Signed in again (fast path + authStateChanges): no second write.
      await h.service.onSignedIn(alice);
      await h.service.refreshRegistration();
      expect(h.store.calls.where((String c) => c.startsWith('register')).length, 1);

      // A week later, a resume refreshes it.
      h.now = h.now.add(const Duration(days: 8));
      await h.service.refreshRegistration();
      expect(h.store.calls.where((String c) => c.startsWith('register')).length, 2);
    });

    test('does not register before permission, then registers once granted', () async {
      final Harness h = Harness();
      // Android 13+ before the prompt: the plugin says "denied".
      h.messaging.status = AuthorizationStatus.denied;
      await h.service.onSignedIn(alice);
      expect(h.store.calls, isEmpty);
      expect(await h.service.permissionStatus(), PushPermission.notDetermined);

      h.messaging.onRequest = AuthorizationStatus.authorized;
      expect(await h.service.requestPermission(), PushPermission.granted);
      await settle();
      expect(h.store.owners['token-1'], alice);
    });

    test('a denial stays respected: no registration, no re-prompt from the service', () async {
      final Harness h = Harness();
      h.messaging.status = AuthorizationStatus.denied;
      h.local.requested = true; // GoodLift asked before, and was refused
      await h.service.onSignedIn(alice);
      await h.service.refreshRegistration(force: true);
      expect(h.store.calls, isEmpty);
      expect(h.messaging.requestCalls, 0);
    });

    test('a refreshed token replaces the old registration', () async {
      final Harness h = Harness();
      await h.service.onSignedIn(alice);
      h.messaging.refresh.add('token-2');
      await settle();
      expect(h.store.owners, <String, String>{'token-2': alice});
      expect(h.store.calls, contains('unregister:token-1'));
    });

    test('switching accounts moves the token: it is never registered to both', () async {
      final Harness h = Harness();
      await h.service.onSignedIn(alice);
      h.authUid = bob;
      await h.service.onSignedIn(bob);
      expect(h.store.owners, <String, String>{'token-1': bob});
      expect(h.store.calls, isNot(contains('unregister:token-1')),
          reason: 'the document is taken over, not deleted');

      // Alice's listeners are gone: a late foreground message for her is not shown.
      h.messaging.foreground.add(PushMessage(data: dmData(to: alice)));
      await settle();
      expect(h.banners, isEmpty);
    });

    test('a token that arrives after an account change is not registered to the old account', () async {
      final Harness h = Harness();
      h.messaging.tokenGate = Completer<String?>();
      final Future<void> first = h.service.onSignedIn(alice);
      await settle();
      h.authUid = bob; // Alice signs out and Bob signs in while getToken is in flight
      h.messaging.tokenGate!.complete('token-1');
      await first;
      expect(h.store.calls.where((String c) => c.contains(alice)), isEmpty);
    });

    test('Coach Mode: only the authenticated coach is ever registered', () async {
      // The app passes FirebaseAuth's uid; a coach "acting as" an athlete is
      // still signed in as the coach. The service has no way to register for
      // anyone else, and never acts on an athlete-addressed notification.
      final Harness h = Harness(uid: alice);
      await h.service.onSignedIn(alice);
      h.messaging.foreground.add(PushMessage(data: dmData(to: athlete)));
      h.messaging.opened.add(PushMessage(data: requestData(to: athlete)));
      await settle();
      expect(h.store.owners.values.toSet(), <String>{alice});
      expect(h.banners, isEmpty);
      expect(h.navigated, isEmpty);
    });
  });

  // ── Logout ────────────────────────────────────────────────────────────────

  group('explicit logout', () {
    test('removes this device\'s registration, the FCM token, listeners and tray', () async {
      final Harness h = Harness();
      await h.service.onSignedIn(alice);
      h.store.owners['other-device-token'] = alice; // Alice's other phone
      h.router.submit(PushIntent.fromData(requestData(), now: h.now)!);

      await h.service.onExplicitSignOut();
      expect(h.store.owners, <String, String>{'other-device-token': alice},
          reason: 'other devices keep their registrations');
      expect(h.messaging.deleteCalls, 1);
      expect(h.platform.cleared, 1);
      expect(h.local.pending, isFalse);
      expect(h.local.record, isNull);
      expect(h.router.pending, isNull, reason: 'a pending tap does not survive logout');
      expect(h.service.attachedUid, isNull);

      h.messaging.foreground.add(PushMessage(data: dmData()));
      await settle();
      expect(h.banners, isEmpty);
    });

    test('offline logout never traps the person, and finishes on the next launch', () async {
      final Harness h = Harness();
      await h.service.onSignedIn(alice);
      h.store.hang = true; // Firestore delete never acknowledged
      h.messaging.deleteHangs = true; // FCM unreachable

      final Stopwatch sw = Stopwatch()..start();
      await h.service.onExplicitSignOut(budget: const Duration(milliseconds: 200));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      expect(h.local.pending, isTrue);

      // Next launch, back online, another account signs in: the stale token
      // is deleted BEFORE a registration is made.
      h.store.hang = false;
      h.messaging.deleteHangs = false;
      h.messaging.log.clear();
      h.authUid = bob;
      await h.service.onSignedIn(bob);
      expect(h.messaging.log.first, 'deleteToken');
      expect(h.local.pending, isFalse);
      // Bob is registered under a NEW token. Alice's old registration may
      // still exist (its delete never reached the server), but it names a
      // token FCM has now invalidated: the server worker gets UNREGISTERED
      // and removes it (see push_delivery.spec.js), so this phone can no
      // longer receive Alice's notifications.
      final List<String> bobTokens = h.store.owners.entries
          .where((MapEntry<String, String> e) => e.value == bob)
          .map((MapEntry<String, String> e) => e.key)
          .toList();
      expect(bobTokens, hasLength(1));
      expect(bobTokens.single, isNot('token-1'));
    });
  });

  // ── Taps and the router ───────────────────────────────────────────────────

  group('taps', () {
    testWidgets('a cold-start tap waits for auth and the gated UI, then opens once', (WidgetTester tester) async {
      final Harness h = Harness(uid: null);
      h.messaging.initial = PushMessage(data: dmData());
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final BuildContext ctx = tester.element(find.byType(SizedBox));

      // Auth restores.
      h.authUid = alice;
      await tester.runAsync(() => h.service.onSignedIn(alice));
      await tester.pump();
      expect(h.navigated, isEmpty, reason: 'membership gate has not let the person through yet');

      // The gate passes: a ready scope mounts.
      h.router.attachScope(() => ctx);
      await tester.pump();
      expect(h.navigated.single.kind, PushKind.directMessage);
      await tester.pump(const Duration(seconds: 2));
      expect(h.navigated.length, 1);
    });

    testWidgets('a background tap for another account is refused with a message', (WidgetTester tester) async {
      final Harness h = Harness(uid: bob);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final BuildContext ctx = tester.element(find.byType(SizedBox));
      h.router.attachScope(() => ctx);
      await tester.runAsync(() async {
        await h.service.onSignedIn(bob);
        h.messaging.opened.add(PushMessage(data: requestData(to: alice)));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      expect(h.navigated, isEmpty);
      expect(h.notices.single, contains('different GoodLift account'));
    });

    testWidgets('foreground: banner for the recipient, none for the conversation on screen',
        (WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final Harness h = Harness();
      await tester.runAsync(() => h.service.onSignedIn(alice));

      h.messaging.foreground.add(PushMessage(data: requestData(), title: 'Friend request'));
      await tester.pump();
      expect(h.banners.single.kind, PushKind.friendRequest);

      ForegroundConversation.shown(conversationIdFor(alice, bob));
      h.messaging.foreground.add(PushMessage(data: dmData()));
      await tester.pump();
      expect(h.banners.length, 1, reason: 'same chat on screen: no extra banner');

      ForegroundConversation.hidden(conversationIdFor(alice, bob));
      h.messaging.foreground.add(PushMessage(data: dmData()));
      await tester.pump();
      expect(h.banners.length, 2);
    });
  });

  // ── Settings → Notifications ──────────────────────────────────────────────

  group('Settings → Notifications', () {
    Future<(FakeFirebaseFirestore, Harness)> pumpScreen(
      WidgetTester tester,
      AuthorizationStatus status, {
      bool requestedBefore = false,
    }) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final Harness h = Harness(); // Android 13+
      h.messaging.status = status;
      h.local.requested = requestedBefore;
      await tester.pumpWidget(MaterialApp(
        home: NotificationSettingsScreen(service: h.service, firestore: db, uid: alice),
      ));
      await tester.pumpAndSettle();
      return (db, h);
    }

    testWidgets('three categories on, previews off, and toggles save to the account', (WidgetTester tester) async {
      final (FakeFirebaseFirestore db, Harness _) = await pumpScreen(tester, AuthorizationStatus.authorized);
      expect(find.text('Friend requests'), findsOneWidget);
      expect(find.text('Friend request accepted'), findsOneWidget);
      expect(find.text('Direct messages'), findsOneWidget);
      expect(find.text('Show message previews'), findsOneWidget);
      for (final String f in <String>['friendRequests', 'friendAccepted', 'directMessages']) {
        expect(tester.widget<SwitchListTile>(find.byKey(ValueKey<String>('push-pref-$f'))).value, isTrue);
      }
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey<String>('push-pref-messagePreviews'))).value,
          isFalse);

      await tester.tap(find.byKey(const ValueKey<String>('push-pref-directMessages')));
      await tester.pumpAndSettle();
      final Map<String, dynamic>? stored = (await db.doc('pushPreferences/$alice').get()).data();
      expect(stored!['directMessages'], isFalse);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey<String>('push-pref-directMessages'))).value,
          isFalse);
      expect(find.text('Notifications are on for this device.'), findsOneWidget);
    });

    testWidgets('after a denial it offers the system settings, not another prompt', (WidgetTester tester) async {
      final (FakeFirebaseFirestore _, Harness h) =
          await pumpScreen(tester, AuthorizationStatus.denied, requestedBefore: true);
      expect(find.byKey(const ValueKey<String>('push-turn-on')), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('push-open-settings')));
      await tester.pump();
      expect(h.platform.opened, 1);
      expect(h.messaging.requestCalls, 0);
    });

    testWidgets('before the OS has been asked, "Turn on" asks it', (WidgetTester tester) async {
      // Android 13+ raw "denied" with no request recorded = not asked yet.
      final (FakeFirebaseFirestore _, Harness h) = await pumpScreen(tester, AuthorizationStatus.denied);
      await tester.tap(find.byKey(const ValueKey<String>('push-turn-on')));
      await tester.pumpAndSettle();
      expect(h.messaging.requestCalls, 1);
      expect(find.text('Notifications are on for this device.'), findsOneWidget);
    });
  });
}
