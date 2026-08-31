import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/big_five.dart';
import 'package:localtest222/profile/core/showcase_models.dart';
import 'package:localtest222/wes2_video/set_video_publication.dart';
import 'package:localtest222/wes2_video/set_video_store.dart';

/// The publication gate — the rule that keeps set footage private.
///
/// The default for a set video is DEVICE-ONLY. These pin the narrow set of
/// conditions under which one is allowed to leave the device, and, more
/// importantly, all the ways in which it must not.

const String _uid = 'owner-1';
const String _coach = 'coach-9';
const String _dateKey = '2026-08-31';

/// A real Big Five id, read from the canonical list rather than hardcoded, so
/// this suite keeps working when the list grows.
final BigFiveLift _bench = bigFiveBySlot(BigFiveSlot.bench)!;

SetVideoRecord _record({
  String ownerUid = _uid,
  String? exerciseId,
  String setId = 'sid-1',
  String state = SetVideoState.local,
  bool suppressed = false,
  int? deletedAtMs,
}) =>
    SetVideoRecord(
      id: setVideoIdFor(
        ownerUid: ownerUid,
        dateKey: _dateKey,
        exerciseId: exerciseId ?? _bench.exerciseId,
        setId: setId,
      ),
      ownerUid: ownerUid,
      dateKey: _dateKey,
      exerciseId: exerciseId ?? _bench.exerciseId,
      setId: setId,
      setIndex: 0,
      localVideoPath: '/clips/a.mp4',
      localPosterPath: '/clips/a.jpg',
      durationMs: 4200,
      sizeBytes: 2048,
      createdAtMs: 1,
      updatedAtMs: 1,
      state: state,
      suppressed: suppressed,
      deletedAtMs: deletedAtMs,
      generation: 0,
    );

/// The fingerprint the server would compute for this performance.
String _fp({
  String slot = BigFiveSlot.bench,
  String? exerciseId,
  String setKey = 'sid-1',
  double weight = 180,
  int reps = 2,
}) =>
    recordFingerprint(
      slot: slot,
      exerciseId: exerciseId ?? _bench.exerciseId,
      dateKey: _dateKey,
      setKey: setKey,
      weight: weight,
      reps: reps,
    );

ShowcaseRecord _rec(String fingerprint, {double weight = 180, int reps = 2}) =>
    ShowcaseRecord(
      slot: BigFiveSlot.bench,
      exerciseId: _bench.exerciseId,
      dateKey: _dateKey,
      setKey: 'sid-1',
      weight: weight,
      reps: reps,
      e1rm: 190,
      formulaVersion: 1,
      fingerprint: fingerprint,
    );

/// A server projection in which [fingerprint] stands as the live record.
ProfileShowcase _showcaseWith(
  String? fingerprint, {
  String? heaviestFingerprint,
}) {
  if (fingerprint == null && heaviestFingerprint == null) {
    return ProfileShowcase.empty;
  }
  return ProfileShowcase(
    lifts: <String, ShowcaseLiftSnapshot>{
      BigFiveSlot.bench: ShowcaseLiftSnapshot(
        slot: BigFiveSlot.bench,
        bestE1rm: fingerprint == null ? null : _rec(fingerprint),
        heaviest:
            heaviestFingerprint == null ? null : _rec(heaviestFingerprint),
      ),
    },
  );
}

const SetVideoActor _self =
    SetVideoActor(authenticatedUid: _uid, actingUid: _uid);

SetVideoPublishPlan _plan({
  SetVideoRecord? record,
  String exerciseName = 'Bench Press, Barbell',
  double? weight = 180,
  int? reps = 2,
  ProfileShowcase? showcase,
  SetVideoActor actor = _self,
}) =>
    planSetVideoPublication(
      record: record ?? _record(),
      exerciseName: exerciseName,
      weight: weight,
      reps: reps,
      showcase: showcase ?? _showcaseWith(_fp()),
      actor: actor,
    );

void main() {
  group('the happy path is narrow', () {
    test('an exact server-confirmed PB on a canonical lift publishes', () {
      final SetVideoPublishPlan p = _plan();
      expect(p.shouldPublish, isTrue);
      expect(p.slot, BigFiveSlot.bench);
      expect(p.fingerprint, _fp());
    });

    test('the plan carries the exact fingerprint the projection confirmed', () {
      expect(_plan().fingerprint, _fp());
    });
  });

  group('ordinary sets never upload', () {
    test('a non-canonical exercise is never published', () {
      final SetVideoPublishPlan p = _plan(
        record: _record(exerciseId: 'some-other-lift'),
        exerciseName: 'Leg Press',
        showcase: _showcaseWith(_fp(exerciseId: 'some-other-lift')),
      );
      expect(p.decision, SetVideoPublishDecision.notCanonical);
    });

    test('a canonical lift that is not a PB is never published', () {
      expect(_plan(showcase: ProfileShowcase.empty).decision,
          SetVideoPublishDecision.notPersonalBest);
    });

    test('a locally impressive set does not upload before the server agrees',
        () {
      // The projection lists a DIFFERENT performance as the record.
      expect(
        _plan(showcase: _showcaseWith(_fp(weight: 200))).decision,
        SetVideoPublishDecision.notPersonalBest,
      );
    });

    test('a near miss on weight is not an exact match', () {
      expect(
        _plan(showcase: _showcaseWith(_fp(weight: 180.001))).decision,
        SetVideoPublishDecision.notPersonalBest,
      );
    });

    test('a different set of the same session does not borrow the record', () {
      expect(
        _plan(showcase: _showcaseWith(_fp(setKey: 'sid-2'))).decision,
        SetVideoPublishDecision.notPersonalBest,
      );
    });

    test('a superseded PB is not uploaded', () {
      // Confirmed earlier, then beaten before the pass ran.
      expect(
        _plan(showcase: _showcaseWith(_fp(weight: 185))).decision,
        SetVideoPublishDecision.notPersonalBest,
      );
    });
  });

  group('cross-account and coach-mode protection', () {
    test('a coach acting as an athlete cannot publish their footage', () {
      final SetVideoPublishPlan p = _plan(
        actor: const SetVideoActor(authenticatedUid: _coach, actingUid: _uid),
      );
      expect(p.decision, SetVideoPublishDecision.actorMismatch);
    });

    test('a signed-in user cannot publish to another profile', () {
      expect(
        _plan(
          record: _record(ownerUid: 'someone-else'),
          actor: _self,
        ).decision,
        SetVideoPublishDecision.actorMismatch,
      );
    });

    test('acting as someone else blocks even your own footage', () {
      expect(
        _plan(
          actor: const SetVideoActor(
              authenticatedUid: _uid, actingUid: 'athlete-2'),
        ).decision,
        SetVideoPublishDecision.actorMismatch,
      );
    });

    test('a missing identity is refused rather than assumed', () {
      expect(
        _plan(actor: const SetVideoActor(authenticatedUid: '', actingUid: ''))
            .decision,
        SetVideoPublishDecision.actorMismatch,
      );
    });

    test('identity is checked before anything else', () {
      // Even a perfect PB is refused when the actor is wrong.
      final SetVideoPublishPlan p = _plan(
        actor: const SetVideoActor(authenticatedUid: _coach, actingUid: _uid),
        showcase: _showcaseWith(_fp()),
      );
      expect(p.decision, SetVideoPublishDecision.actorMismatch);
      expect(p.fingerprint, isNull);
    });
  });

  group('explicit user choices are not undone by reconciliation', () {
    test('a suppressed record is never resurrected', () {
      expect(_plan(record: _record(suppressed: true)).decision,
          SetVideoPublishDecision.suppressed);
    });

    test('a soft-deleted record is never resurrected', () {
      expect(_plan(record: _record(deletedAtMs: 123)).decision,
          SetVideoPublishDecision.suppressed);
    });

    test('suppression outranks being a genuine PB', () {
      expect(
        _plan(
          record: _record(suppressed: true),
          showcase: _showcaseWith(_fp()),
        ).decision,
        SetVideoPublishDecision.suppressed,
      );
    });
  });

  group('idempotence', () {
    test('an already queued record is not queued again', () {
      expect(_plan(record: _record(state: SetVideoState.queued)).decision,
          SetVideoPublishDecision.alreadyHandled);
    });

    test('an already published record is not uploaded again', () {
      expect(_plan(record: _record(state: SetVideoState.published)).decision,
          SetVideoPublishDecision.alreadyHandled);
    });

    test('planning twice yields the same answer', () {
      final SetVideoPublishPlan a = _plan();
      final SetVideoPublishPlan b = _plan();
      expect(a.decision, b.decision);
      expect(a.fingerprint, b.fingerprint);
    });
  });

  group('incomplete performances', () {
    test('a set with no stable identity cannot be fingerprinted', () {
      expect(_plan(record: _record(setId: '  ')).decision,
          SetVideoPublishDecision.incomplete);
    });

    test('missing weight or reps is incomplete', () {
      expect(_plan(weight: null).decision, SetVideoPublishDecision.incomplete);
      expect(_plan(reps: null).decision, SetVideoPublishDecision.incomplete);
    });

    test('non-positive values are rejected as the reducers reject them', () {
      expect(_plan(weight: 0).decision, SetVideoPublishDecision.incomplete);
      expect(_plan(reps: 0).decision, SetVideoPublishDecision.incomplete);
      expect(_plan(weight: -5).decision, SetVideoPublishDecision.incomplete);
    });

    test('a non-finite weight is rejected', () {
      expect(_plan(weight: double.infinity).decision,
          SetVideoPublishDecision.incomplete);
      expect(_plan(weight: double.nan).decision,
          SetVideoPublishDecision.incomplete);
    });
  });

  group('one upload serves both record categories', () {
    test('a set owning both best-E1RM and heaviest yields one fingerprint', () {
      final String fp = _fp();
      final ProfileShowcase showcase =
          _showcaseWith(fp, heaviestFingerprint: fp);

      final SetVideoPublishPlan p = _plan(showcase: showcase);
      expect(p.shouldPublish, isTrue);
      expect(slotsProvenBy(showcase, fp), <String>[BigFiveSlot.bench],
          reason: 'one slot, one upload, two proof references');
      expect(showcase.liveFingerprints.length, 1,
          reason: 'both records share the one fingerprint');
    });

    test('slotsProvenBy finds nothing for an unrelated fingerprint', () {
      expect(slotsProvenBy(_showcaseWith(_fp()), 'not-a-fingerprint'), isEmpty);
    });
  });

  group('revalidation before commit', () {
    test('a still-live fingerprint passes', () {
      expect(fingerprintStillLive(_showcaseWith(_fp()), _fp()), isTrue);
    });

    test('a fingerprint beaten while uploading no longer passes', () {
      expect(fingerprintStillLive(_showcaseWith(_fp(weight: 200)), _fp()),
          isFalse);
    });

    test('an empty or null fingerprint never passes', () {
      expect(fingerprintStillLive(_showcaseWith(_fp()), null), isFalse);
      expect(fingerprintStillLive(_showcaseWith(_fp()), ''), isFalse);
    });
  });

  group('the canonical list is followed, not copied', () {
    test('every canonical lift is publishable by id, with none named here', () {
      for (final BigFiveLift lift in kBigFive) {
        final String fp = recordFingerprint(
          slot: lift.slot,
          exerciseId: lift.exerciseId,
          dateKey: _dateKey,
          setKey: 'sid-1',
          weight: 100,
          reps: 3,
        );
        final SetVideoPublishPlan p = planSetVideoPublication(
          record: _record(exerciseId: lift.exerciseId),
          exerciseName: lift.displayName,
          weight: 100,
          reps: 3,
          showcase: ProfileShowcase(
            lifts: <String, ShowcaseLiftSnapshot>{
              lift.slot: ShowcaseLiftSnapshot(
                slot: lift.slot,
                bestE1rm: ShowcaseRecord(
                  slot: lift.slot,
                  exerciseId: lift.exerciseId,
                  dateKey: _dateKey,
                  setKey: 'sid-1',
                  weight: 100,
                  reps: 3,
                  e1rm: 110,
                  formulaVersion: 1,
                  fingerprint: fp,
                ),
              ),
            },
          ),
          actor: _self,
        );
        expect(p.shouldPublish, isTrue,
            reason:
                '${lift.displayName} must publish without being named here');
        expect(p.slot, lift.slot);
      }
    });

    test('a lift added to the canonical list would be picked up for free', () {
      // Nothing in the feature enumerates lifts, so this is really a guard that
      // the count is read from the canonical source rather than assumed.
      expect(kBigFive.length, BigFiveSlot.ordered.length);
    });

    test('an id-less legacy row still matches by its canonical name', () {
      final SetVideoPublishPlan p = _plan(
        record: _record(exerciseId: ''),
        exerciseName: 'Bench Press',
        showcase: _showcaseWith(_fp(exerciseId: '')),
      );
      expect(p.shouldPublish, isTrue);
    });

    test('a near-miss name is not rescued into a canonical slot', () {
      expect(
        _plan(
          record: _record(exerciseId: ''),
          exerciseName: 'Larsen Bench Press',
        ).decision,
        SetVideoPublishDecision.notCanonical,
      );
    });
  });
}
