// user_context.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';


class UserContext extends ChangeNotifier {
  final String actorUid;
  final bool isCoach;
  String actingAsUid;



  UserContext({
    required this.actorUid,
    required this.isCoach,
  }) : actingAsUid = actorUid;

  bool get isActingAsSelf => actingAsUid == actorUid;
  bool get isSuperAdmin => [
    'Mxj2NXankQdVv4Xrj2sZzBBm4W92', // Richard
  ].contains(actorUid);

  // ✅ Add this for admin override
  bool get isAdmin => [
    'Mxj2NXankQdVv4Xrj2sZzBBm4W92', // Richard
    'B3dWiljf4ISavFufZ0xN6o9LsD93', // Campbell
    //'Rp6gFj16KMgsmOtC9tZGlUDCNRr1', // Courtney
  ].contains(actorUid);

  String get currentUid => actingAsUid; // ✅ ADD THIS LINE

  void switchAthlete(String newUid) {
    actingAsUid = newUid;
    notifyListeners();
  }

  static UserContext of(BuildContext context, {bool listen = true}) {
    return listen
        ? context.watch<UserContext>()
        : context.read<UserContext>();
  }

  static UserContext? maybeOf(BuildContext context, {bool listen = true}) {
    return listen
        ? context.watch<UserContext?>()
        : context.read<UserContext?>();
  }
}
