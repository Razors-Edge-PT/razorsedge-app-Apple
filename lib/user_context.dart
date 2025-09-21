// user_context.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class UserContext extends ChangeNotifier {
  // Identity & roles
  final String actorUid;
  final bool isCoach;
  String actingAsUid;

  UserContext({
    required this.actorUid,
    required this.isCoach,
  }) : actingAsUid = actorUid;

  bool get isActingAsSelf => actingAsUid == actorUid;

  bool get isSuperAdmin => [
    'yoVAqScwLMQLAgNHh8v9IK49fBw2', // Richard
  ].contains(actorUid);

  // ✅ Admin override (kept from your version)
  bool get isAdmin => [
    'yoVAqScwLMQLAgNHh8v9IK49fBw2', // Richard
    'wuiMe7phxYQh0MM39bfnhgv20yS2', // Campbell
    'SMTEVGPH1MXgOgbcBbJFU1HjU8G3', // Adam W
    // 'Rp6gFj16KMgsmOtC9tZGlUDCNRr1', // Courtney
  ].contains(actorUid);

  String get currentUid => actingAsUid;

  void switchAthlete(String newUid) {
    actingAsUid = newUid;
    notifyListeners();
  }

  // -------- Avatar single source of truth --------
  String? _networkPhotoUrl; // e.g., users/{uid}.photoURL from Firestore
  String? _localPhotoPath;  // on-device cached file path

  String? get networkPhotoUrl => _networkPhotoUrl;
  String? get localPhotoPath => _localPhotoPath;

  /// Prefer local file (fast/offline), then network URL, else null (UI shows placeholder)
  ImageProvider? get avatarImageProvider {
    if (_localPhotoPath != null) {
      final f = File(_localPhotoPath!);
      if (f.existsSync()) return FileImage(f);
    }
    if (_networkPhotoUrl != null && _networkPhotoUrl!.isNotEmpty) {
      return NetworkImage(_networkPhotoUrl!);
    }
    return null;
  }

  /// Call these ONLY from Profile page's picker/loader.
  void setLocalPhotoPath(String? path) {
    _localPhotoPath = path;
    notifyListeners();
  }

  void setNetworkPhotoUrl(String? url) {
    _networkPhotoUrl = url;
    notifyListeners();
  }

  void clearAvatar() {
    _localPhotoPath = null;
    _networkPhotoUrl = null;
    notifyListeners();
  }
  // ----------------------------------------------

  // Provider helpers
  static UserContext of(BuildContext context, {bool listen = true}) {
    return listen ? context.watch<UserContext>() : context.read<UserContext>();
  }

  static UserContext? maybeOf(BuildContext context, {bool listen = true}) {
    return listen ? context.watch<UserContext?>() : context.read<UserContext?>();
  }
}
