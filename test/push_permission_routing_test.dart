// Regressions for two release-review findings (1.7.21+91):
//
//  1. Android 13+ first-use permission. Firebase reports `denied` on Android
//     13+ both BEFORE the OS prompt and after a refusal. These tests drive the
//     PRODUCTION FirebasePushMessagingAdapter with a FirebaseMessaging fake that
//     returns exactly what the plugin returns on each platform — never a
//     synthetic "notDetermined" on Android — through the real service, the
//     real explanation dialog and the real Settings screen.
//
//  2. Successive notification taps. Navigator.push completes only when the
//     route is POPPED; the router must not stay busy while a destination is
//     open. These tests route through the production PushDestinations logic
//     onto a real Navigator (only the destination widgets and the DM lookup
//     are stand-ins, because the real screens need Firebase).

import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
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
const String carol = 'carolUidcarolUidcarolUid0003';

// ════════════════════════════════════════════════════════════════════════════
// Fakes at the plugin boundary
// ════════════════════════════════════════════════════════════════════════════

NotificationSettings settingsWith(AuthorizationStatus s) => NotificationSettings(
      alert: AppleNotificationSetting.enabled,
      announcement: AppleNotificationSetting.enabled,
      authorizationStatus: s,
      badge: AppleNotificationSetting.enabled,
      carPlay: AppleNotificationSetting.enabled,
      lockScreen: AppleNotificationSetting.enabled,
      notificationCenter: AppleNotificationSetting.enabled,
      showPreviews: AppleShowPreviewSetting.always,
      timeSensitive: AppleNotificationSetting.enabled,
      criticalAlert: AppleNotificationSetting.enabled,
      sound: AppleNotificationSetting.enabled,
      providesAppNotificationSettings: AppleNotificationSetting.enabled,
    );

/// The FirebaseMessaging plugin as each OS behaves.
///
/// [status] is what getNotificationSettings reports. [osAnswer] is what the
/// OS prompt yields when requestPermission shows it; null means no prompt
/// exists (Android 12 and earlier, or a permission already decided) and the
/// current status is returned unchanged — the plugin's behaviour.
class OsMessaging extends Fake implements FirebaseMessaging {
  OsMessaging(this.status, {this.osAnswer});

  AuthorizationStatus status;
  AuthorizationStatus? osAnswer;
  int requestCalls = 0;
  Object? requestError;
  Completer<void>? requestGate;

  @override
  Future<NotificationSettings> getNotificationSettings() async =>
      settingsWith(status);

  @override
  Future<NotificationSettings> requestPermission({
    bool alert = true,
    bool announcement = false,
    bool badge = true,
    bool carPlay = false,
    bool criticalAlert = false,
    bool provisional = false,
    bool sound = true,
    bool providesAppNotificationSettings = false,
  }) async {
    requestCalls++;
    if (requestGate != null) await requestGate!.future;
    if (requestError != null) throw requestError!;
    if (osAnswer != null) status = osAnswer!;
    return settingsWith(status);
  }

  @override
  Future<String?> getToken({String? vapidKey, String? serviceWorkerScriptPath}) async =>
      'fcm-token-1';

  @override
  Future<String?> getAPNSToken() async => 'apns-token';

  @override
  Future<void> deleteToken() async {}

  @override
  Stream<String> get onTokenRefresh => const Stream<String>.empty();

  @override
  Future<RemoteMessage?> getInitialMessage() async => null;
}

class Store implements PushRegistrationStore {
  final Map<String, String> owners = <String, String>{};

  @override
  Future<void> register({
    required String uid,
    required String token,
    required String platform,
    required String appVersion,
  }) async =>
      owners[token] = uid;

  @override
  Future<void> unregister({required String token}) async => owners.remove(token);
}

/// Survives "app restarts" (a new service instance sharing it), like
/// SharedPreferences.
class Local implements PushLocalState {
  bool primer = false;
  bool requested = false;
  bool pending = false;
  PushRegistrationRecord? record;

  @override
  Future<bool> primerShown() async => primer;
  @override
  Future<void> setPrimerShown() async => primer = true;
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
}

class SettingsOpener extends NotificationPlatform {
  int opened = 0;
  @override
  Future<void> openSystemSettings() async => opened++;
  @override
  Future<void> clearDelivered() async {}
}

const PushPlatformInfo android14 = PushPlatformInfo.android(34);
const PushPlatformInfo android13 = PushPlatformInfo.android(33);
const PushPlatformInfo android12 = PushPlatformInfo.android(31);
const PushPlatformInfo iphone = PushPlatformInfo.ios();

class Device {
  Device(this.platformInfo, AuthorizationStatus status, {AuthorizationStatus? osAnswer})
      : os = OsMessaging(status, osAnswer: osAnswer);

  final PushPlatformInfo platformInfo;
  final OsMessaging os;
  final Store store = Store();
  final Local local = Local();
  final SettingsOpener settings = SettingsOpener();

  /// A fresh service — i.e. an app launch — over the same device state.
  PushNotificationService launch() => PushNotificationService(
        // The PRODUCTION adapter, over the plugin fake.
        messaging: FirebasePushMessagingAdapter(messaging: os),
        store: store,
        local: local,
        router: PushRouter(
          currentUid: () => alice,
          navigate: (BuildContext c, PushIntent i, bool Function() v) async => false,
          notify: (_) {},
        ),
        platform: settings,
        currentUid: () => alice,
        appVersion: () async => '1.7.22+92',
        platformName: platformInfo.platform == PushOsPlatform.ios ? 'ios' : 'android',
        supported: true,
        platformInfo: () async => platformInfo,
      );
}

/// Pumps a Home-like screen, signs in, and offers the explanation the way
/// PushReadyScope does. Returns the service.
Future<PushNotificationService> openHome(WidgetTester tester, Device d) async {
  final PushNotificationService service = d.launch();
  late BuildContext home;
  await tester.pumpWidget(MaterialApp(
    home: Builder(builder: (BuildContext c) {
      home = c;
      return const Scaffold(body: Text('HOME'));
    }),
  ));
  await service.onSignedIn(alice);
  await tester.pump();
  unawaited(service.maybeOfferPermission(home));
  await tester.pumpAndSettle();
  return service;
}

Future<void> openSettings(WidgetTester tester, PushNotificationService s) async {
  await tester.pumpWidget(MaterialApp(
    home: NotificationSettingsScreen(
      service: s,
      firestore: FakeFirebaseFirestore(),
      uid: alice,
    ),
  ));
  await tester.pumpAndSettle();
}

final Finder explanation = find.text('Stay in the loop');
final Finder turnOn = find.byKey(const ValueKey<String>('push-turn-on'));
final Finder openSystemSettings = find.byKey(const ValueKey<String>('push-open-settings'));
final Finder isOn = find.text('Notifications are on for this device.');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(ForegroundConversation.reset);

  // ══════════════════════════════════════════════════════════════════════════
  // 1. Permission
  // ══════════════════════════════════════════════════════════════════════════

  group('resolvePushPermission — the raw plugin status per platform', () {
    PushPermission r(AuthorizationStatus os, PushPlatformInfo p, bool asked) =>
        resolvePushPermission(os: os, platform: p, requestedBefore: asked);

    test('Android 13+: "denied" before GoodLift asked means NOT ASKED YET', () {
      expect(r(AuthorizationStatus.denied, android13, false), PushPermission.notDetermined);
      expect(r(AuthorizationStatus.denied, android14, false), PushPermission.notDetermined);
    });
    test('Android 13+: "denied" after GoodLift asked is a real denial', () {
      expect(r(AuthorizationStatus.denied, android14, true), PushPermission.denied);
    });
    test('granted is granted everywhere, asked or not', () {
      for (final PushPlatformInfo p in <PushPlatformInfo>[android14, android12, iphone]) {
        expect(r(AuthorizationStatus.authorized, p, false), PushPermission.granted);
        expect(r(AuthorizationStatus.authorized, p, true), PushPermission.granted);
      }
    });
    test('Android 12 and earlier: "denied" is notifications switched off — no prompt exists', () {
      expect(r(AuthorizationStatus.denied, android12, false), PushPermission.denied);
    });
    test('iOS statuses are taken as reported', () {
      expect(r(AuthorizationStatus.notDetermined, iphone, false), PushPermission.notDetermined);
      expect(r(AuthorizationStatus.denied, iphone, false), PushPermission.denied);
      expect(r(AuthorizationStatus.provisional, iphone, false), PushPermission.provisional);
    });
  });

  group('Android 13+ first use (plugin reports "denied", nothing asked yet)', () {
    testWidgets('the explanation is offered; Continue → Allow registers the token', (WidgetTester tester) async {
      final Device d = Device(android14, AuthorizationStatus.denied, osAnswer: AuthorizationStatus.authorized);
      final PushNotificationService s = await openHome(tester, d);
      expect(explanation, findsOneWidget, reason: 'a new Android 13+ user must be asked');
      expect(d.store.owners, isEmpty, reason: 'nothing registered before permission');

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(d.os.requestCalls, 1);
      expect(d.local.requested, isTrue);
      expect(await s.permissionStatus(), PushPermission.granted);
      expect(d.store.owners, <String, String>{'fcm-token-1': alice});
    });

    testWidgets('Continue → Don\'t allow is recorded: no automatic re-prompt, Settings offers system settings',
        (WidgetTester tester) async {
      final Device d = Device(android14, AuthorizationStatus.denied, osAnswer: AuthorizationStatus.denied);
      final PushNotificationService s = await openHome(tester, d);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(d.os.requestCalls, 1);
      expect(await s.permissionStatus(), PushPermission.denied);
      expect(d.store.owners, isEmpty);

      await openSettings(tester, s);
      expect(openSystemSettings, findsOneWidget);
      expect(turnOn, findsNothing);
      await tester.tap(openSystemSettings);
      await tester.pump();
      expect(d.settings.opened, 1);
      expect(d.os.requestCalls, 1, reason: 'no second prompt');
    });

    testWidgets('Not now → later Settings → Turn on still asks the OS', (WidgetTester tester) async {
      final Device d = Device(android14, AuthorizationStatus.denied, osAnswer: AuthorizationStatus.authorized);
      await openHome(tester, d);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(d.os.requestCalls, 0);
      expect(d.local.primer, isTrue);
      expect(d.local.requested, isFalse, reason: 'explaining is not asking');

      // A later launch: the explanation is not repeated…
      final PushNotificationService relaunch = await openHome(tester, d);
      expect(explanation, findsNothing);

      // …but Settings still offers the real request.
      await openSettings(tester, relaunch);
      expect(turnOn, findsOneWidget);
      expect(openSystemSettings, findsNothing);
      await tester.tap(turnOn);
      await tester.pumpAndSettle();
      expect(d.os.requestCalls, 1);
      expect(isOn, findsOneWidget);
      expect(d.store.owners['fcm-token-1'], alice);
    });

    testWidgets('after a recorded denial, later launches never prompt automatically', (WidgetTester tester) async {
      final Device d = Device(android14, AuthorizationStatus.denied);
      d.local
        ..primer = true
        ..requested = true;
      for (int launch = 0; launch < 3; launch++) {
        final PushNotificationService s = await openHome(tester, d);
        expect(explanation, findsNothing);
        await s.refreshRegistration(force: true);
      }
      expect(d.os.requestCalls, 0);
      expect(d.store.owners, isEmpty);
    });

    testWidgets('returning from system settings with notifications allowed registers', (WidgetTester tester) async {
      final Device d = Device(android14, AuthorizationStatus.denied);
      d.local
        ..primer = true
        ..requested = true;
      final PushNotificationService s = await openHome(tester, d);
      await openSettings(tester, s);
      expect(openSystemSettings, findsOneWidget);

      d.os.status = AuthorizationStatus.authorized; // switched on in system settings
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(isOn, findsOneWidget);
      expect(d.store.owners['fcm-token-1'], alice);
      expect(d.os.requestCalls, 0);
    });

    testWidgets('a failed request is not recorded as asked: the person can still opt in', (WidgetTester tester) async {
      final Device d = Device(android14, AuthorizationStatus.denied, osAnswer: AuthorizationStatus.authorized);
      d.os.requestError = Exception('activity not attached');
      final PushNotificationService s = await openHome(tester, d);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(d.local.requested, isFalse);
      expect(await s.permissionStatus(), PushPermission.notDetermined);

      d.os.requestError = null;
      await openSettings(tester, s);
      expect(turnOn, findsOneWidget);
      await tester.tap(turnOn);
      await tester.pumpAndSettle();
      expect(isOn, findsOneWidget);
      expect(d.os.requestCalls, 2);
    });

    test('concurrent requests share ONE OS prompt', () async {
      final Device d = Device(android14, AuthorizationStatus.denied, osAnswer: AuthorizationStatus.authorized);
      d.os.requestGate = Completer<void>();
      final PushNotificationService s = d.launch();
      final Future<PushPermission> a = s.requestPermission();
      final Future<PushPermission> b = s.requestPermission();
      d.os.requestGate!.complete();
      expect(await Future.wait(<Future<PushPermission>>[a, b]),
          <PushPermission>[PushPermission.granted, PushPermission.granted]);
      expect(d.os.requestCalls, 1);
      // And a later one is a fresh request (the shared one was released).
      await s.requestPermission();
      expect(d.os.requestCalls, 2);
    });
  });

  group('other states keep their behaviour', () {
    testWidgets('Android 13+ already granted: no explanation, registers', (WidgetTester tester) async {
      final Device d = Device(android14, AuthorizationStatus.authorized);
      await openHome(tester, d);
      expect(explanation, findsNothing);
      expect(d.os.requestCalls, 0);
      expect(d.store.owners['fcm-token-1'], alice);
    });

    testWidgets('Android 12: notifications on by default — no explanation, no prompt, registers',
        (WidgetTester tester) async {
      final Device d = Device(android12, AuthorizationStatus.authorized);
      final PushNotificationService s = await openHome(tester, d);
      expect(explanation, findsNothing);
      expect(d.store.owners['fcm-token-1'], alice);
      await openSettings(tester, s);
      expect(isOn, findsOneWidget);
    });

    testWidgets('Android 12 with notifications switched off: system settings, never a prompt',
        (WidgetTester tester) async {
      final Device d = Device(android12, AuthorizationStatus.denied);
      final PushNotificationService s = await openHome(tester, d);
      expect(explanation, findsNothing);
      await openSettings(tester, s);
      expect(openSystemSettings, findsOneWidget);
      expect(turnOn, findsNothing);
      expect(d.os.requestCalls, 0);
    });

    testWidgets('iOS: explanation, Continue → Allow registers; a denial is final', (WidgetTester tester) async {
      final Device ok = Device(iphone, AuthorizationStatus.notDetermined, osAnswer: AuthorizationStatus.authorized);
      await openHome(tester, ok);
      expect(explanation, findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(ok.store.owners['fcm-token-1'], alice);

      final Device no = Device(iphone, AuthorizationStatus.denied);
      final PushNotificationService s = await openHome(tester, no);
      expect(explanation, findsNothing);
      await openSettings(tester, s);
      expect(openSystemSettings, findsOneWidget);
      expect(no.os.requestCalls, 0);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 2. Routing successive taps
  // ══════════════════════════════════════════════════════════════════════════

  group('routing on a real Navigator', () {
    late String? authUid;
    late DateTime now;
    late List<String> notices;
    late Map<String, Completer<bool?>> lookups;
    late _PushCounter observer;

    PushIntent dm(String from, {String to = alice}) =>
        PushIntent.fromData(<String, dynamic>{
          'type': 'directMessage',
          'recipientUid': to,
          'actorUid': from,
          'convId': conversationIdFor(to, from),
        }, now: now)!;
    PushIntent request(String from) => PushIntent.fromData(<String, dynamic>{
          'type': 'friendRequest',
          'recipientUid': alice,
          'actorUid': from,
        }, now: now)!;

    /// The production routing logic, with stand-in screens.
    PushDestinations destinations() => PushDestinations(
          buddyHub: (PushIntent i, bool other) =>
              Scaffold(appBar: AppBar(), body: Text('HUB from ${i.actorUid}')),
          conversation: (PushIntent i) =>
              Scaffold(appBar: AppBar(), body: Text('CHAT ${i.convId}')),
          conversationList: () => const Scaffold(body: Text('CHAT LIST')),
          conversationAccessible: (String convId) {
            final Completer<bool?>? gate = lookups[convId];
            return gate == null ? Future<bool?>.value(true) : gate.future;
          },
          notice: notices.add,
        );

    Future<PushRouter> restoredWorkout(WidgetTester tester) async {
      authUid = alice;
      now = DateTime(2026, 9, 12, 9);
      notices = <String>[];
      lookups = <String, Completer<bool?>>{};
      observer = _PushCounter();
      final PushRouter router = PushRouter(
        currentUid: () => authUid,
        navigate: destinations().navigate,
        clock: () => now,
        notify: notices.add,
      );
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: <NavigatorObserver>[observer],
        home: const _RestoredWorkout(),
      ));
      // The gate has let the person through: a ready scope inside the app's
      // navigator, as PushReadyScope registers.
      final BuildContext scope = tester.element(find.byType(_RestoredWorkout));
      router.attachScope(() => scope.mounted ? scope : null);
      await tester.pump();
      observer.pushes = 0;
      return router;
    }

    testWidgets('a second tap opens immediately while the first destination is still open',
        (WidgetTester tester) async {
      final PushRouter router = await restoredWorkout(tester);
      await tester.tap(find.text('add set'));
      await tester.pump();
      expect(find.text('sets: 1'), findsOneWidget);

      router.submit(request(bob));
      await tester.pumpAndSettle();
      expect(find.text('HUB from $bob'), findsOneWidget);
      expect(router.dispatching, isFalse, reason: 'not blocked by the open Buddy Hub');

      // The Buddy Hub stays open; the person taps a DM notification.
      now = now.add(const Duration(seconds: 5));
      router.submit(dm(carol));
      await tester.pumpAndSettle();
      expect(find.text('CHAT ${conversationIdFor(alice, carol)}'), findsOneWidget);
      expect(router.pending, isNull);
      expect(observer.pushes, 2);

      // Back walks the stack down to the untouched restored workout.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('HUB from $bob'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('sets: 1'), findsOneWidget, reason: 'workout state survived');
    });

    testWidgets('a tap for the conversation already on screen opens nothing; another thread opens',
        (WidgetTester tester) async {
      final PushRouter router = await restoredWorkout(tester);
      ForegroundConversation.shown(conversationIdFor(alice, bob)); // ConversationPage visible
      router.submit(dm(bob));
      await tester.pumpAndSettle();
      expect(observer.pushes, 0);

      router.submit(dm(carol));
      await tester.pumpAndSettle();
      expect(observer.pushes, 1);
      expect(find.text('CHAT ${conversationIdFor(alice, carol)}'), findsOneWidget);
    });

    testWidgets('rapid taps: one screen per destination, the latest tap is not lost',
        (WidgetTester tester) async {
      final PushRouter router = await restoredWorkout(tester);
      // The same notification tapped twice in quick succession.
      router.submit(request(bob));
      await tester.pump();
      router.submit(request(bob));
      await tester.pumpAndSettle();
      expect(observer.pushes, 1, reason: 'no duplicate Buddy Hub');

      // A DM whose access check is slow, then another tap while it runs.
      final String slow = conversationIdFor(alice, carol);
      lookups[slow] = Completer<bool?>();
      now = now.add(const Duration(seconds: 5));
      router.submit(dm(carol));
      await tester.pump();
      expect(router.dispatching, isTrue, reason: 'the lookup is serialized');
      router.submit(dm(bob));
      await tester.pump();
      expect(router.pending, isNotNull, reason: 'held while the lookup runs');

      lookups[slow]!.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('CHAT ${conversationIdFor(alice, bob)}'), findsOneWidget);
      expect(observer.pushes, 3);
      expect(router.pending, isNull);
    });

    testWidgets('logout while a lookup is pending: nothing opens afterwards', (WidgetTester tester) async {
      final PushRouter router = await restoredWorkout(tester);
      final String conv = conversationIdFor(alice, bob);
      lookups[conv] = Completer<bool?>();
      router.submit(dm(bob));
      await tester.pump();
      expect(router.dispatching, isTrue);

      router.clear(); // PushNotificationService.onExplicitSignOut
      authUid = null;
      lookups[conv]!.complete(true);
      await tester.pumpAndSettle();
      expect(observer.pushes, 0);
      expect(find.text('CHAT $conv'), findsNothing);
      expect(router.dispatching, isFalse);
    });

    testWidgets('account switch while a lookup is pending: never opens for the old account',
        (WidgetTester tester) async {
      final PushRouter router = await restoredWorkout(tester);
      final String conv = conversationIdFor(alice, bob);
      lookups[conv] = Completer<bool?>();
      router.submit(dm(bob));
      await tester.pump();

      authUid = carol; // another account signed in on this phone meanwhile
      lookups[conv]!.complete(true);
      await tester.pumpAndSettle();
      expect(observer.pushes, 0);

      // And a new tap addressed to the old account is refused.
      router.submit(request(bob));
      await tester.pumpAndSettle();
      expect(observer.pushes, 0);
      expect(notices.single, contains('different GoodLift account'));
    });

    testWidgets('a conversation no longer accessible falls back to the list', (WidgetTester tester) async {
      final PushRouter router = await restoredWorkout(tester);
      final String conv = conversationIdFor(alice, bob);
      lookups[conv] = Completer<bool?>()..complete(false);
      router.submit(dm(bob));
      await tester.pumpAndSettle();
      expect(find.text('CHAT LIST'), findsOneWidget);
      expect(notices.single, contains('no longer available'));
    });

    testWidgets('cold start: the tap waits for auth and the gated UI, then opens on the real navigator',
        (WidgetTester tester) async {
      authUid = null;
      now = DateTime(2026, 9, 12, 9);
      notices = <String>[];
      lookups = <String, Completer<bool?>>{};
      observer = _PushCounter();
      final PushRouter router = PushRouter(
        currentUid: () => authUid,
        navigate: destinations().navigate,
        clock: () => now,
        notify: notices.add,
      );
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: <NavigatorObserver>[observer],
        home: const _RestoredWorkout(),
      ));
      observer.pushes = 0;
      router.submit(request(bob)); // getInitialMessage
      await tester.pump();
      expect(observer.pushes, 0, reason: 'auth still restoring');

      authUid = alice;
      router.onAuthChanged();
      await tester.pump();
      expect(observer.pushes, 0, reason: 'membership gate not passed yet');

      final BuildContext scope = tester.element(find.byType(_RestoredWorkout));
      router.attachScope(() => scope);
      await tester.pumpAndSettle();
      expect(find.text('HUB from $bob'), findsOneWidget);
    });
  });
}

class _PushCounter extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

/// Stands in for the restored WES2 root: state that must survive anything a
/// notification opens on top of it.
class _RestoredWorkout extends StatefulWidget {
  const _RestoredWorkout();
  @override
  State<_RestoredWorkout> createState() => _RestoredWorkoutState();
}

class _RestoredWorkoutState extends State<_RestoredWorkout> {
  int sets = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: <Widget>[
          Text('sets: $sets'),
          TextButton(onPressed: () => setState(() => sets++), child: const Text('add set')),
        ]),
      );
}
