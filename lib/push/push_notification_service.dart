/// Device side of push notifications: registration, taps, the foreground
/// banner, the one-time permission explanation, and logout cleanup.
///
/// ── Whose notifications ─────────────────────────────────────────────────────
/// Always the account FirebaseAuth has signed in on this device — the uid the
/// AppRoot passes to [onSignedIn]. Never `UserContext.actingAsUid`: a coach
/// viewing an athlete registers, receives and navigates as the COACH, and
/// nothing here can register for, receive as, or open the athlete's social
/// account.
///
/// ── Registration ────────────────────────────────────────────────────────────
/// `pushDevices/{sha256(token)}` = { uid, token, platform, appVersion,
/// updatedAt(server) }. One document per token, so a token has one owner: a
/// second account signing in on the same phone re-registers the same token
/// and takes the document over. Refreshed on sign-in, on token refresh, and
/// on resume once it is a week old (FCM treats a month of silence as stale).
///
/// ── Never in the way ────────────────────────────────────────────────────────
/// Nothing here is awaited on the startup path, blocks first render, the
/// restored WES2 route, offline use, or logout. Every network step is
/// bounded and failure-tolerant. Every async continuation re-checks a
/// generation counter so a result that lands after an account change is
/// dropped.
///
/// ── Explicit logout ─────────────────────────────────────────────────────────
/// [onExplicitSignOut] runs BEFORE Firebase sign-out (it needs the account's
/// credentials to delete its own registration): cancels listeners, forgets a
/// pending tap, clears this app's notifications from the tray, deletes this
/// device's registration and the FCM token. Bounded to a few seconds; if the
/// phone is offline the logout still proceeds, and the token deletion is
/// retried on the next launch (which also invalidates the old registration
/// server-side: FCM then reports it unregistered and the worker removes it).
/// Other devices are untouched.
///
/// A transient null from Firebase Auth during startup restoration is NOT a
/// logout and never reaches this code: only the explicit logout paths call it.
///
/// OS limitation: a notification the OS had already received or queued before
/// logout can still be displayed or tapped afterwards. The tray is cleared at
/// logout, and a later tap is ignored unless its recipient is signed in.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_check_ready.dart';
import '../main.dart' show rootScaffoldMessengerKey;
import 'foreground_conversation.dart';
import 'notification_platform.dart';
import 'push_intent.dart';
import 'push_router.dart';

/// A received notification, reduced to what the app uses.
class PushMessage {
  const PushMessage({required this.data, this.title, this.body});

  final Map<String, dynamic> data;
  final String? title;
  final String? body;

  static PushMessage fromRemote(RemoteMessage m) => PushMessage(
        data: Map<String, dynamic>.from(m.data),
        title: m.notification?.title,
        body: m.notification?.body,
      );
}

/// The FCM surface the service uses. Faked in tests.
abstract class PushMessagingAdapter {
  Future<PushPermission> permissionStatus();
  Future<PushPermission> requestPermission();

  /// The FCM token, or null when it cannot be had yet (no APNs token, no
  /// network, no Play services).
  Future<String?> getToken();
  Future<void> deleteToken();
  Stream<String> get onTokenRefresh;
  Stream<PushMessage> get onForegroundMessage;
  Stream<PushMessage> get onOpenedApp;
  Future<PushMessage?> initialMessage();
}

/// Where registrations live. Faked in tests.
abstract class PushRegistrationStore {
  Future<void> register({
    required String uid,
    required String token,
    required String platform,
    required String appVersion,
  });

  Future<void> unregister({required String token});
}

/// What this device remembers between launches. Faked in tests.
abstract class PushLocalState {
  Future<PushRegistrationRecord?> lastRegistration();
  Future<void> saveRegistration(PushRegistrationRecord record);
  Future<void> clearRegistration();
  Future<bool> pendingTokenDelete();
  Future<void> setPendingTokenDelete(bool value);
  Future<bool> primerShown();
  Future<void> setPrimerShown();
}

class PushRegistrationRecord {
  const PushRegistrationRecord({
    required this.uid,
    required this.token,
    required this.at,
  });

  final String uid;
  final String token;
  final DateTime at;
}

/// A registration older than this is refreshed on the next resume.
const Duration kRegistrationRefreshAfter = Duration(days: 7);

/// Upper bound on logout cleanup. Logout never waits longer than this.
const Duration kSignOutCleanupBudget = Duration(seconds: 3);

class PushNotificationService with WidgetsBindingObserver {
  PushNotificationService({
    PushMessagingAdapter? messaging,
    PushRegistrationStore? store,
    PushLocalState? local,
    PushRouter? router,
    NotificationPlatform? platform,
    String? Function()? currentUid,
    Future<String> Function()? appVersion,
    String? platformName,
    DateTime Function()? clock,
    void Function(PushIntent intent, PushMessage message)? showBanner,
    bool? supported,
  })  : _messagingOverride = messaging,
        _store = store ?? FirestorePushRegistrationStore(),
        _local = local ?? SharedPrefsPushLocalState(),
        _router = router ?? PushRouter.instance,
        _platform = platform ?? NotificationPlatform(),
        _currentUid =
            currentUid ?? (() => FirebaseAuth.instance.currentUser?.uid),
        _appVersion = appVersion ?? _packageVersion,
        _platformName = platformName ?? _defaultPlatformName(),
        _clock = clock ?? DateTime.now,
        _showBannerOverride = showBanner,
        _supported = supported ?? _defaultSupported();

  static final PushNotificationService instance = PushNotificationService();

  final PushMessagingAdapter? _messagingOverride;
  PushMessagingAdapter? _messagingDefault;
  PushMessagingAdapter get _messaging =>
      _messagingOverride ?? (_messagingDefault ??= FirebasePushMessagingAdapter());
  final PushRegistrationStore _store;
  final PushLocalState _local;
  final PushRouter _router;
  final NotificationPlatform _platform;
  final String? Function() _currentUid;
  final Future<String> Function() _appVersion;
  final String _platformName;
  final DateTime Function() _clock;
  final void Function(PushIntent intent, PushMessage message)? _showBannerOverride;
  final bool _supported;

  String? _uid;
  int _gen = 0;
  String? _lastToken;
  bool _initialConsumed = false;
  bool _observing = false;
  bool _primerInFlight = false;
  Future<void>? _startupCleanup;
  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];

  static bool _defaultSupported() =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static String _defaultPlatformName() {
    if (kIsWeb) return 'web';
    return Platform.isIOS ? 'ios' : 'android';
  }

  static Future<String> _packageVersion() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return '';
    }
  }

  /// The account this device is currently set up for, if any.
  @visibleForTesting
  String? get attachedUid => _uid;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Process start, before any sign-in. Finishes a token deletion that an
  /// offline explicit logout could not complete. Not awaited by main().
  Future<void> onAppStart() {
    if (!_supported) return Future<void>.value();
    return _startupCleanup ??= _completePendingTokenDelete();
  }

  /// The AppRoot has an authenticated user [uid] (fresh sign-in, restored
  /// session, or account switch). Idempotent for the same uid.
  Future<void> onSignedIn(String uid) async {
    if (!_supported || uid.isEmpty) return;
    if (_uid == uid) {
      _router.onAuthChanged();
      return;
    }
    _detachListeners();
    _uid = uid;
    final int gen = ++_gen;
    _attachListeners(gen);
    _router.onAuthChanged();

    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
    }

    // A tap that launched the app from killed. Read once per process; the
    // router holds it until auth and the membership gate are ready.
    if (!_initialConsumed) {
      _initialConsumed = true;
      try {
        final PushMessage? m = await _messaging.initialMessage();
        if (m != null) _onOpened(m);
      } catch (e) {
        debugPrint('[push] initial message unavailable: $e');
      }
    }
    if (gen != _gen) return;
    await refreshRegistration();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Permission may have been granted in system settings meanwhile, and a
    // week-old registration is refreshed.
    if (state == AppLifecycleState.resumed && _uid != null) {
      unawaited(refreshRegistration());
    }
  }

  void _attachListeners(int gen) {
    try {
      _subs.add(_messaging.onTokenRefresh.listen((String token) {
        if (gen != _gen) return;
        unawaited(_registerToken(token, gen, force: true));
      }, onError: (Object _) {}));
      _subs.add(_messaging.onForegroundMessage.listen((PushMessage m) {
        if (gen != _gen) return;
        _onForeground(m);
      }, onError: (Object _) {}));
      _subs.add(_messaging.onOpenedApp.listen((PushMessage m) {
        if (gen != _gen) return;
        _onOpened(m);
      }, onError: (Object _) {}));
    } catch (e) {
      debugPrint('[push] listeners unavailable: $e');
    }
  }

  void _detachListeners() {
    for (final StreamSubscription<Object?> s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
  }

  // ── Registration ──────────────────────────────────────────────────────────

  /// Registers this device for the signed-in account when the OS allows
  /// notifications. Cheap when nothing changed.
  Future<void> refreshRegistration({bool force = false}) async {
    final String? uid = _uid;
    if (!_supported || uid == null) return;
    final int gen = _gen;
    try {
      await (_startupCleanup ?? Future<void>.value());
      await _completePendingTokenDelete();
      if (gen != _gen) return;
      final PushPermission permission = await _messaging.permissionStatus();
      if (!permission.allowsDelivery) return;
      final String? token = await _messaging.getToken();
      if (token == null || token.isEmpty) return;
      await _registerToken(token, gen, force: force);
    } catch (e) {
      debugPrint('[push] registration skipped: $e');
    }
  }

  Future<void> _registerToken(String token, int gen, {bool force = false}) async {
    final String? uid = _uid;
    if (uid == null || gen != _gen) return;
    // The auth account must still be the one we are registering for.
    if (_currentUid() != uid) return;

    final PushRegistrationRecord? last = await _local.lastRegistration();
    final DateTime now = _clock();
    final bool fresh = last != null &&
        last.uid == uid &&
        last.token == token &&
        now.difference(last.at) < kRegistrationRefreshAfter;
    _lastToken = token;
    if (fresh && !force) return;

    try {
      await _store.register(
        uid: uid,
        token: token,
        platform: _platformName,
        appVersion: await _appVersion(),
      );
    } catch (e) {
      // Offline: the write is queued by Firestore; we simply do not record
      // it, so the next resume tries again.
      debugPrint('[push] registration write not confirmed: $e');
      return;
    }
    if (gen != _gen) return;
    // A token rotated for the SAME account: drop the old registration. (For
    // a different account the same token's document was taken over above.)
    if (last != null && last.uid == uid && last.token != token) {
      try {
        await _store.unregister(token: last.token);
      } catch (_) {}
    }
    await _local.saveRegistration(
      PushRegistrationRecord(uid: uid, token: token, at: now),
    );
  }

  Future<void> _completePendingTokenDelete() async {
    try {
      if (!await _local.pendingTokenDelete()) return;
      await _messaging.deleteToken().timeout(const Duration(seconds: 10));
      await _local.setPendingTokenDelete(false);
    } catch (e) {
      debugPrint('[push] deferred token deletion still pending: $e');
    }
  }

  // ── Explicit logout / account deletion ────────────────────────────────────

  /// See the library comment. Never throws; bounded by [budget].
  Future<void> onExplicitSignOut({Duration budget = kSignOutCleanupBudget}) async {
    if (!_supported) return;
    _gen++;
    _uid = null;
    _detachListeners();
    _router.clear();

    String? token = _lastToken;
    try {
      token ??= (await _local.lastRegistration())?.token;
    } catch (_) {}
    _lastToken = null;

    unawaited(_platform.clearDelivered());

    bool tokenDeleted = false;
    final List<Future<void>> work = <Future<void>>[
      if (token != null)
        _store.unregister(token: token).catchError((Object _) {}),
      _messaging.deleteToken().then((_) {
        tokenDeleted = true;
      }).catchError((Object _) {}),
    ];
    try {
      await Future.wait(work).timeout(budget);
    } catch (_) {
      // Offline or slow: logout proceeds regardless.
    }
    try {
      if (!tokenDeleted) await _local.setPendingTokenDelete(true);
      await _local.clearRegistration();
    } catch (_) {}
  }

  // ── Received notifications ────────────────────────────────────────────────

  void _onOpened(PushMessage m) {
    final PushIntent? intent = PushIntent.fromData(m.data, now: _clock());
    if (intent == null) return;
    _router.submit(intent);
  }

  void _onForeground(PushMessage m) {
    final PushIntent? intent = PushIntent.fromData(m.data, now: _clock());
    if (intent == null) return;
    final bool resumed =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!shouldShowForegroundBanner(
      intent: intent,
      currentUid: _currentUid(),
      visibleConvId: ForegroundConversation.visibleConvId,
      appResumed: resumed,
    )) {
      return;
    }
    final void Function(PushIntent, PushMessage) show =
        _showBannerOverride ?? _showBanner;
    show(intent, m);
  }

  /// One compact, tappable banner. Replaces any banner already showing so
  /// a burst of messages never stacks up.
  void _showBanner(PushIntent intent, PushMessage m) {
    final ScaffoldMessengerState? messenger =
        rootScaffoldMessengerKey.currentState;
    if (messenger == null || !messenger.mounted) return;
    final String text = <String?>[m.title, m.body]
        .whereType<String>()
        .where((String s) => s.trim().isNotEmpty)
        .join(' · ');
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 5),
      content: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          messenger.hideCurrentSnackBar();
          _router.submit(intent);
        },
        child: Text(
          text.isEmpty ? 'New notification' : text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      action: SnackBarAction(
        label: 'View',
        onPressed: () => _router.submit(intent),
      ),
    ));
  }

  // ── Permission ────────────────────────────────────────────────────────────

  Future<PushPermission> permissionStatus() async {
    if (!_supported) return PushPermission.denied;
    try {
      return await _messaging.permissionStatus();
    } catch (_) {
      return PushPermission.notDetermined;
    }
  }

  /// Asks the OS (only ever in response to the person's own choice).
  Future<PushPermission> requestPermission() async {
    if (!_supported) return PushPermission.denied;
    PushPermission status;
    try {
      status = await _messaging.requestPermission();
    } catch (_) {
      return PushPermission.notDetermined;
    }
    if (status.allowsDelivery) unawaited(refreshRegistration(force: true));
    return status;
  }

  /// The one-time explanation, then the OS prompt. Offered from Home once
  /// the authenticated UI has settled — never over a workout, never twice on
  /// this device, never after the OS has already been answered.
  Future<void> maybeOfferPermission(BuildContext context) async {
    if (!_supported || _uid == null || _primerInFlight) return;
    _primerInFlight = true;
    try {
      final PushPermission status = await permissionStatus();
      final bool shown = await _local.primerShown();
      if (!shouldOfferPermissionPrimer(
        status: status,
        alreadyShown: shown,
        signedIn: _uid != null,
      )) {
        if (status.allowsDelivery) unawaited(refreshRegistration());
        return;
      }
      await _local.setPrimerShown();
      if (!context.mounted) return;
      final bool? proceed = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('Stay in the loop'),
          content: const Text(
            'GoodLift can let you know when someone sends you a friend '
            'request, accepts yours, or sends you a message.\n\n'
            'You can change this any time in Settings → Notifications.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Not now'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (proceed == true) await requestPermission();
    } catch (e) {
      debugPrint('[push] permission explanation skipped: $e');
    } finally {
      _primerInFlight = false;
    }
  }

  /// Opens this app's notification settings in the OS.
  Future<void> openSystemSettings() => _platform.openSystemSettings();
}

// ── Production adapters ─────────────────────────────────────────────────────

class FirebasePushMessagingAdapter implements PushMessagingAdapter {
  FirebaseMessaging get _fm => FirebaseMessaging.instance;

  static PushPermission _map(AuthorizationStatus s) {
    switch (s) {
      case AuthorizationStatus.authorized:
        return PushPermission.granted;
      case AuthorizationStatus.provisional:
        return PushPermission.provisional;
      case AuthorizationStatus.denied:
        return PushPermission.denied;
      case AuthorizationStatus.notDetermined:
        return PushPermission.notDetermined;
    }
  }

  @override
  Future<PushPermission> permissionStatus() async =>
      _map((await _fm.getNotificationSettings()).authorizationStatus);

  @override
  Future<PushPermission> requestPermission() async => _map(
        (await _fm.requestPermission(alert: true, badge: true, sound: true))
            .authorizationStatus,
      );

  @override
  Future<String?> getToken() async {
    if (!kIsWeb && Platform.isIOS) {
      // FCM needs the APNs token first; it can lag app start by a moment.
      String? apns;
      for (int i = 0; i < 10 && apns == null; i++) {
        apns = await _fm.getAPNSToken();
        if (apns == null) await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (apns == null) return null;
    }
    return _fm.getToken().timeout(const Duration(seconds: 20));
  }

  @override
  Future<void> deleteToken() => _fm.deleteToken();

  @override
  Stream<String> get onTokenRefresh => _fm.onTokenRefresh;

  @override
  Stream<PushMessage> get onForegroundMessage =>
      FirebaseMessaging.onMessage.map(PushMessage.fromRemote);

  @override
  Stream<PushMessage> get onOpenedApp =>
      FirebaseMessaging.onMessageOpenedApp.map(PushMessage.fromRemote);

  @override
  Future<PushMessage?> initialMessage() async {
    final RemoteMessage? m = await _fm.getInitialMessage();
    return m == null ? null : PushMessage.fromRemote(m);
  }
}

class FirestorePushRegistrationStore implements PushRegistrationStore {
  FirestorePushRegistrationStore({FirebaseFirestore? firestore})
      : _db = firestore;

  final FirebaseFirestore? _db;
  FirebaseFirestore get _fs => _db ?? FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> _ref(String token) =>
      _fs.collection('pushDevices').doc(pushDeviceIdForToken(token));

  @override
  Future<void> register({
    required String uid,
    required String token,
    required String platform,
    required String appVersion,
  }) async {
    await appCheckReady;
    await _ref(token).set(<String, Object?>{
      'uid': uid,
      'token': token,
      'platform': platform,
      if (appVersion.isNotEmpty) 'appVersion': appVersion,
      'updatedAt': FieldValue.serverTimestamp(),
    }).timeout(const Duration(seconds: 15));
  }

  @override
  Future<void> unregister({required String token}) =>
      _ref(token).delete().timeout(const Duration(seconds: 5));
}

class SharedPrefsPushLocalState implements PushLocalState {
  static const String _kUid = 'push.lastReg.uid';
  static const String _kToken = 'push.lastReg.token';
  static const String _kAt = 'push.lastReg.at';
  static const String _kPendingDelete = 'push.pendingTokenDelete';
  static const String _kPrimer = 'push.permissionPrimerShown.v1';

  Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  @override
  Future<PushRegistrationRecord?> lastRegistration() async {
    final SharedPreferences p = await _p;
    final String? uid = p.getString(_kUid);
    final String? token = p.getString(_kToken);
    final int? at = p.getInt(_kAt);
    if (uid == null || token == null || at == null) return null;
    return PushRegistrationRecord(
      uid: uid,
      token: token,
      at: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }

  @override
  Future<void> saveRegistration(PushRegistrationRecord r) async {
    final SharedPreferences p = await _p;
    await p.setString(_kUid, r.uid);
    await p.setString(_kToken, r.token);
    await p.setInt(_kAt, r.at.millisecondsSinceEpoch);
  }

  @override
  Future<void> clearRegistration() async {
    final SharedPreferences p = await _p;
    await p.remove(_kUid);
    await p.remove(_kToken);
    await p.remove(_kAt);
  }

  @override
  Future<bool> pendingTokenDelete() async =>
      (await _p).getBool(_kPendingDelete) ?? false;

  @override
  Future<void> setPendingTokenDelete(bool value) async {
    final SharedPreferences p = await _p;
    if (value) {
      await p.setBool(_kPendingDelete, true);
    } else {
      await p.remove(_kPendingDelete);
    }
  }

  @override
  Future<bool> primerShown() async => (await _p).getBool(_kPrimer) ?? false;

  @override
  Future<void> setPrimerShown() async => (await _p).setBool(_kPrimer, true);
}
