// Aurelian 2.0 athlete switching against the real UserContext and the real
// coach roster rules (CoachRosterService over an in-memory Firestore): only
// authorised athletes are reachable, the switch uses the Coach Dashboard's own
// selected-athlete state, and an open workout is reopened for the same day.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/aurelian/actions/action_ports.dart';
import 'package:localtest222/aurelian/actions/action_service.dart';
import 'package:localtest222/aurelian/actions/goodlift_athlete_port.dart';
import 'package:localtest222/coach_roster.dart';
import 'package:localtest222/user_context.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// A workout that "reopens" itself for the context's athlete, as WES2 does.
class _ReopeningWorkout extends FakeWorkout implements ReloadableWorkout {
  _ReopeningWorkout(this.service, this.uc, String uid) : super(uid: uid);

  final AurelianActionService service;
  final UserContext uc;
  int reopened = 0;

  @override
  Future<void> reopenForCurrentAthlete() async {
    reopened++;
    service.unregisterWorkout(this);
    service.registerWorkout(
        _ReopeningWorkout(service, uc, uc.currentUid)..day = day);
  }
}

/// WES2 as it really behaves: left through its own exit (which saves), and
/// opened again from Home for whoever is selected.
class _ExitingWorkout extends FakeWorkout implements ExitableWorkout {
  _ExitingWorkout(this.service, String uid, {super.day}) : super(uid: uid);

  final AurelianActionService service;
  bool exited = false;
  bool savedOnExit = false;

  @override
  Future<bool> exitToHome() async {
    savedOnExit = true;
    exited = true;
    service.unregisterWorkout(this);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeFirebaseFirestore fs;
  late UserContext uc;
  late AurelianActionService service;
  late GoodLiftAthletePort port;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    fs = FakeFirebaseFirestore();
    await fs.collection('users').doc('ruby').set(
        <String, dynamic>{'username': 'rubycakes', 'fullName': 'Ruby Cakes'});
    await fs
        .collection('users')
        .doc('stranger')
        .set(<String, dynamic>{'username': 'strangerdanger'});
    await fs.collection('coachAthleteLinks').doc('l1').set(<String, dynamic>{
      'coachUid': 'coach',
      'athleteUid': 'ruby',
      'status': 'active',
    });
    uc = UserContext(actorUid: 'coach', isCoach: true);
    service = AurelianActionService();
    port = GoodLiftAthletePort(() => uc, service,
        roster: CoachRosterService(firestore: fs), signedInUid: () => 'coach');
    service.athletePort = port;
  });

  test('the roster is the coach roster plus the coach themself', () async {
    final List<AthleteCandidate> roster = await port.authorisedAthletes();
    expect(roster.map((AthleteCandidate c) => c.uid),
        unorderedEquals(<String>['coach', 'ruby']));
  });

  test('a signed-in account other than the session is treated as signed out',
      () {
    final GoodLiftAthletePort other = GoodLiftAthletePort(() => uc, service,
        roster: CoachRosterService(firestore: fs),
        signedInUid: () => 'someone-else');
    expect(other.actorUid, isNull);
  });

  test('an athlete outside the roster cannot be reached by name', () async {
    final AurelianActionResultLike r = await _run(service, 'athlete.switch',
        <String, Object?>{'query': 'strangerdanger'});
    expect(r.status, 'not_found');
    expect(uc.currentUid, 'coach');
  });

  test(
      'switching reopens the open workout for the same day and undo switches back',
      () async {
    final _ReopeningWorkout workout = _ReopeningWorkout(service, uc, 'coach')
      ..day = DateTime(2026, 9, 30);
    service.registerWorkout(workout);
    // The switched-to athlete's block arrives shortly after the switch.
    uc.addListener(() {
      if (uc.currentUid == 'ruby' && uc.activeBlockId == null) {
        Future<void>.microtask(() => uc.debugSetBlockMeta(
            activeBlockId: 'b-ruby', startDate: DateTime(2026, 9, 1)));
      }
    });
    final AurelianActionResultLike r = await _run(
        service, 'athlete.switch', <String, Object?>{'query': 'Ruby Cakes'});
    expect(r.status, 'success');
    expect(r.summary,
        'Switched to Ruby Cakes (rubycakes) · workout for Wed 30 Sep reopened');
    expect(uc.currentUid, 'ruby');
    expect(workout.reopened, 1);
    expect(service.workoutPort!.actingUid, 'ruby');
    expect(service.workoutPort!.date, DateTime(2026, 9, 30),
        reason: 'same day');
    final AurelianActionResultLike back = await _run(
        service, 'undo', <String, Object?>{'undoToken': r.undoToken});
    expect(back.status, 'success');
    expect(uc.currentUid, 'coach');
    expect(service.workoutPort!.actingUid, 'coach');
  });

  test(
      'from Workout Entry: exit (saving), switch, reopen the same day for the new athlete',
      () async {
    final _ExitingWorkout first =
        _ExitingWorkout(service, 'coach', day: DateTime(2026, 10, 2));
    service.registerWorkout(first);
    final List<_ExitingWorkout> opened = <_ExitingWorkout>[];
    // Home's path: Enter Workout opens on today for the selected athlete.
    service.openWorkout = () async {
      final _ExitingWorkout w =
          _ExitingWorkout(service, uc.currentUid, day: DateTime(2026, 10, 3));
      opened.add(w);
      Future<void>.microtask(() => service.registerWorkout(w));
      return true;
    };
    uc.addListener(() {
      if (uc.currentUid == 'ruby' && uc.activeBlockId == null) {
        Future<void>.microtask(() => uc.debugSetBlockMeta(
            activeBlockId: 'b-ruby', startDate: DateTime(2026, 9, 1)));
      }
    });
    final AurelianActionResultLike r = await _run(
        service, 'athlete.switch', <String, Object?>{'query': 'rubycakes'});
    expect(r.status, 'success');
    expect(first.exited, isTrue);
    expect(first.savedOnExit, isTrue);
    expect(uc.currentUid, 'ruby');
    expect(opened.single.actingUid, 'ruby');
    expect(service.workoutPort!.date, DateTime(2026, 10, 2),
        reason: 'same day');
    expect(r.summary,
        'Switched to Ruby Cakes (rubycakes) · workout for Fri 2 Oct reopened');
  });

  test('from Home: the switch selects the athlete and stays on Home', () async {
    final AurelianActionResultLike r = await _run(
        service, 'athlete.switch', <String, Object?>{'query': 'Ruby Cakes'});
    expect(r.status, 'success');
    expect(r.summary, 'Switched to Ruby Cakes (rubycakes)');
    expect(uc.currentUid, 'ruby');
    expect(service.workoutPort, isNull);
  });
}

class AurelianActionResultLike {
  AurelianActionResultLike(this.status, this.summary, this.undoToken);
  final String status;
  final String summary;
  final String? undoToken;
}

Future<AurelianActionResultLike> _run(AurelianActionService s, String action,
    Map<String, Object?> payload) async {
  final r = await s.execute(parseEnvelopeOrThrow(envelope(action, payload)));
  return AurelianActionResultLike(r.status.wire, r.summary, r.undoToken);
}
