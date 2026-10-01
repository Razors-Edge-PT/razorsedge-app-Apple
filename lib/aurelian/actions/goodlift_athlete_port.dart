/// The production [AthleteActionPort]: the signed-in Firebase account, the
/// Coach Dashboard's own roster rules (CoachRosterService) and its own
/// selected-athlete state (UserContext.switchAthlete).
library;

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';

import '../../coach_roster.dart';
import '../../user_context.dart';
import 'action_ports.dart';
import 'action_service.dart';

class GoodLiftAthletePort implements AthleteActionPort {
  GoodLiftAthletePort(this._context, this._service,
      {CoachRosterService? roster, String? Function()? signedInUid})
      : _roster = roster ?? CoachRosterService(),
        _signedInUid =
            signedInUid ?? (() => FirebaseAuth.instance.currentUser?.uid);

  /// The UserContext of the mounted root scope; null once it is gone.
  final UserContext? Function() _context;
  final AurelianActionService _service;
  final CoachRosterService _roster;

  /// The Firebase Auth account (injectable for tests).
  final String? Function() _signedInUid;

  static const Duration _rosterFresh = Duration(seconds: 60);
  List<AthleteCandidate>? _cached;
  String? _cachedFor;
  DateTime? _cachedAt;

  @override
  String? get actorUid {
    final UserContext? uc = _context();
    final String? signedIn = _signedInUid();
    // The session must still belong to the signed-in account.
    if (uc == null || signedIn == null || signedIn != uc.actorUid) return null;
    return signedIn;
  }

  @override
  bool get hasCoachMode => _context()?.hasCoachMode ?? false;

  @override
  String get actingUid => _context()?.currentUid ?? '';

  @override
  Future<List<AthleteCandidate>> authorisedAthletes() async {
    final UserContext? uc = _context();
    final String? actor = actorUid;
    if (uc == null || actor == null || !uc.hasCoachMode) {
      return const <AthleteCandidate>[];
    }
    final DateTime now = DateTime.now();
    if (_cached != null &&
        _cachedFor == actor &&
        now.difference(_cachedAt!) < _rosterFresh) {
      return _cached!;
    }
    final List<CoachAthlete> roster = await _roster.loadRoster(uc);
    final List<AthleteCandidate> out = <AthleteCandidate>[
      AthleteCandidate(
          uid: actor, displayName: 'your own account', isSelf: true),
      for (final CoachAthlete a in roster)
        if (a.uid != actor)
          AthleteCandidate(
            uid: a.uid,
            username: a.username,
            displayName: a.displayName,
            fullName: a.fullName,
            email: a.email,
          ),
    ];
    _cached = out;
    _cachedFor = actor;
    _cachedAt = now;
    return out;
  }

  @override
  Future<String> switchTo(String uid) async {
    final UserContext? uc = _context();
    if (uc == null) return '';
    uc.switchAthlete(uid);
    // Home and the dashboards listen to UserContext and refresh themselves. An
    // open workout read its athlete when it opened, so it is reopened for the
    // same day once the new athlete's block is known.
    final WorkoutActionPort? workout = _service.workoutPort;
    if (workout != null &&
        workout.actingUid != uid &&
        workout is ReloadableWorkout) {
      await _waitForBlock(uc, uid);
      await (workout as ReloadableWorkout).reopenForCurrentAthlete();
      await _service.waitForWorkout((WorkoutActionPort w) => w.actingUid == uid,
          const Duration(seconds: 10));
    }
    return uc.currentUid;
  }

  /// Waits (bounded) for the switched-to athlete's block metadata.
  Future<void> _waitForBlock(UserContext uc, String uid) async {
    bool ready() =>
        uc.currentUid == uid && (uc.activeBlockId?.isNotEmpty ?? false);
    if (ready()) return;
    final Completer<void> done = Completer<void>();
    void listener() {
      if (ready() && !done.isCompleted) done.complete();
    }

    uc.addListener(listener);
    try {
      await done.future.timeout(const Duration(seconds: 6));
    } on TimeoutException {
      // No cached block yet: the workout opens without one, as from Home.
    } finally {
      uc.removeListener(listener);
    }
  }
}
