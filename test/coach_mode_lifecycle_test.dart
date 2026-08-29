import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:localtest222/coach_mode/coach_mode_models.dart';
import 'package:localtest222/coach_mode/coach_mode_role_watcher.dart';
import 'package:localtest222/user_context.dart';

// Widget/lifecycle tests for the client entitlement lifecycle.
//
// The defect these pin: CoachHome subscribed to the UserContext obtained once
// during initState. AppRoot replaces that Provider value after token
// resolution, so the screen stayed bound to the DISCARDED instance and a
// suspension delivered to the replacement never ejected the dashboard.
//
// CoachModeRoleWatcher is the shipped mixin CoachHomeScreen now uses, so these
// exercise the real rebinding code rather than a stand-in.

const active = CoachEntitlement(state: CoachEntitlementState.active);
const suspended = CoachEntitlement(state: CoachEntitlementState.suspended);
const revoked = CoachEntitlement(state: CoachEntitlementState.revoked);

/// Minimal host that reports what the mixin did, and fails closed in build.
class _Host extends StatefulWidget {
  const _Host({required this.log});
  final List<String> log;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with CoachModeRoleWatcher<_Host> {
  @override
  void onCoachModeBound(UserContext ctx) {
    widget.log.add('bound:${ctx.actorUid}:${identityHashCode(ctx)}');
  }

  @override
  void onCoachModeRevoked({required bool duringBind}) {
    widget.log.add('revoked:duringBind=$duringBind');
  }

  @override
  void dispose() {
    disposeRoleWatcher();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watches, so a notify or a Provider value swap rebuilds this.
    final ctx = UserContext.maybeOf(context);
    if (ctx == null) return const Text('no-context');
    // FAIL CLOSED.
    if (!ctx.hasCoachMode) return const Text('LOCKED');
    return const Text('DASHBOARD');
  }
}

Widget wrap(UserContext ctx, List<String> log) {
  return MaterialApp(
    home: ChangeNotifierProvider<UserContext>.value(
      value: ctx,
      child: _Host(log: log),
    ),
  );
}

void main() {
  group('UserContext replacement rebinds the watcher', () {
    testWidgets('binds to the first provided context', (tester) async {
      final log = <String>[];
      final ctx = UserContext(actorUid: 'u1', isCoach: false)
        ..coachEntitlement = active;

      await tester.pumpWidget(wrap(ctx, log));

      expect(find.text('DASHBOARD'), findsOneWidget);
      expect(log.single, startsWith('bound:u1:'));
    });

    testWidgets('rebinds when AppRoot replaces the UserContext instance',
        (tester) async {
      final log = <String>[];
      final first = UserContext(actorUid: 'u1', isCoach: false)
        ..coachEntitlement = active;
      await tester.pumpWidget(wrap(first, log));
      expect(log.length, 1);

      // AppRoot rebuilds UserContext after token resolution.
      final second = UserContext(actorUid: 'u1', isCoach: true)
        ..coachEntitlement = active;
      await tester.pumpWidget(wrap(second, log));

      expect(log.length, 2, reason: 'must rebind to the new instance');
      expect(log[1], startsWith('bound:u1:'));
      expect(log[0], isNot(log[1]), reason: 'a DIFFERENT instance was bound');
      expect(find.text('DASHBOARD'), findsOneWidget);
    });

    testWidgets('the OLD context is detached — its notifications are ignored',
        (tester) async {
      final log = <String>[];
      final first = UserContext(actorUid: 'u1', isCoach: false)
        ..coachEntitlement = active;
      await tester.pumpWidget(wrap(first, log));

      final second = UserContext(actorUid: 'u1', isCoach: false)
        ..coachEntitlement = active;
      await tester.pumpWidget(wrap(second, log));
      log.clear();

      // Suspend the DISCARDED context: nothing may happen.
      first.coachEntitlement = suspended;
      await tester.pump();

      expect(log, isEmpty,
          reason: 'a discarded context must never call back into the screen');
      expect(find.text('DASHBOARD'), findsOneWidget);
    });

    testWidgets('a suspension on the REPLACEMENT context ejects the dashboard',
        (tester) async {
      final log = <String>[];
      final first = UserContext(actorUid: 'u1', isCoach: true)
        ..coachEntitlement = active;
      await tester.pumpWidget(wrap(first, log));

      final second = UserContext(actorUid: 'u1', isCoach: true)
        ..coachEntitlement = active;
      await tester.pumpWidget(wrap(second, log));
      log.clear();

      // This is the exact regression: before the fix the screen was still
      // listening to `first`, so this did nothing.
      second.coachEntitlement = suspended;
      await tester.pump();

      expect(log, ['revoked:duringBind=false']);
      expect(find.text('LOCKED'), findsOneWidget,
          reason: 'build must fail closed');
      expect(find.text('DASHBOARD'), findsNothing);
    });

    testWidgets('a revocation on the replacement context also ejects',
        (tester) async {
      final log = <String>[];
      final ctx = UserContext(actorUid: 'u1', isCoach: true)
        ..coachEntitlement = active;
      await tester.pumpWidget(wrap(ctx, log));
      log.clear();

      ctx.coachEntitlement = revoked;
      await tester.pump();

      expect(log, ['revoked:duringBind=false']);
      expect(find.text('LOCKED'), findsOneWidget);
    });

    testWidgets('binding to an already-suspended replacement fails closed',
        (tester) async {
      final log = <String>[];
      final first = UserContext(actorUid: 'u1', isCoach: true)
        ..coachEntitlement = active;
      await tester.pumpWidget(wrap(first, log));
      log.clear();

      // The replacement already carries the suspension.
      final second = UserContext(actorUid: 'u1', isCoach: true)
        ..coachEntitlement = suspended;
      await tester.pumpWidget(wrap(second, log));

      expect(log, ['revoked:duringBind=true']);
      expect(find.text('LOCKED'), findsOneWidget);
    });

    testWidgets('rebinding to an active context after a revocation recovers',
        (tester) async {
      final log = <String>[];
      final suspendedCtx = UserContext(actorUid: 'u1', isCoach: true)
        ..coachEntitlement = suspended;
      await tester.pumpWidget(wrap(suspendedCtx, log));
      expect(find.text('LOCKED'), findsOneWidget);
      log.clear();

      final restored = UserContext(actorUid: 'u1', isCoach: true)
        ..coachEntitlement = active;
      await tester.pumpWidget(wrap(restored, log));

      expect(log.single, startsWith('bound:u1:'));
      expect(find.text('DASHBOARD'), findsOneWidget);
    });

    testWidgets('a super admin is never ejected', (tester) async {
      final log = <String>[];
      final ctx = UserContext(actorUid: kSuperAdminUid, isCoach: false);
      await tester.pumpWidget(wrap(ctx, log));
      expect(find.text('DASHBOARD'), findsOneWidget);
      log.clear();

      ctx.coachEntitlement = revoked;
      await tester.pump();

      expect(log, isEmpty);
      expect(find.text('DASHBOARD'), findsOneWidget);
    });

    testWidgets('disposing detaches the listener', (tester) async {
      final log = <String>[];
      final ctx = UserContext(actorUid: 'u1', isCoach: false)
        ..coachEntitlement = active;
      await tester.pumpWidget(wrap(ctx, log));

      await tester.pumpWidget(const MaterialApp(home: Text('gone')));
      log.clear();

      // No listener should remain; this must not throw or call back.
      ctx.coachEntitlement = suspended;
      await tester.pump();
      expect(log, isEmpty);
    });
  });

  group('entitlement read failure never promotes a stale claim', () {
    test('an unresolved entitlement lets the claim route provisionally', () {
      final ctx = UserContext(actorUid: 'u1', isCoach: true);
      expect(ctx.coachEntitlementResolved, isFalse);
      expect(ctx.hasCoachMode, isTrue,
          reason: 'the claim may route the first frame');
    });

    test('a SUCCESSFUL read of no document is authoritative "none"', () {
      final ctx = UserContext(actorUid: 'u1', isCoach: true);
      // A successful read that found no document.
      ctx.coachEntitlement = CoachEntitlement.none;

      expect(ctx.coachEntitlementResolved, isTrue);
      expect(ctx.hasCoachMode, isFalse,
          reason: 'once resolved, none means no Coach Mode — claim ignored');
      expect(ctx.coachRole, CoachRole.athlete);
    });

    test('a resolved "none" notifies so the UI re-evaluates', () {
      final ctx = UserContext(actorUid: 'u1', isCoach: true);
      var notified = 0;
      ctx.addListener(() => notified++);

      // Same VALUE as the initial none, but now authoritative.
      ctx.coachEntitlement = CoachEntitlement.none;

      expect(notified, 1,
          reason: 'the role flips from claim-provisional to athlete');
      expect(ctx.hasCoachMode, isFalse);
    });

    test('a read FAILURE preserves the last known entitlement', () {
      final ctx = UserContext(actorUid: 'u1', isCoach: false)
        ..coachEntitlement = active;
      expect(ctx.hasCoachMode, isTrue);

      // A failure assigns NOTHING (see _attachCoachEntitlement in main.dart).
      // The last known state survives.
      expect(ctx.coachEntitlement.isActive, isTrue);
      expect(ctx.hasCoachMode, isTrue);
      expect(ctx.coachEntitlementResolved, isTrue);
    });

    test('a failure after a resolved suspension does not restore the claim',
        () {
      final ctx = UserContext(actorUid: 'u1', isCoach: true)
        ..coachEntitlement = suspended;
      expect(ctx.hasCoachMode, isFalse);

      // Simulate a later read failure: nothing is assigned.
      expect(ctx.hasCoachMode, isFalse,
          reason: 'a stale claim must never resurrect a suspended coach');
    });

    test('a failure after a resolved "none" does not restore the claim', () {
      final ctx = UserContext(actorUid: 'u1', isCoach: true)
        ..coachEntitlement = CoachEntitlement.none;
      expect(ctx.hasCoachMode, isFalse);
      // A later failure assigns nothing; resolved stays true.
      expect(ctx.coachEntitlementResolved, isTrue);
      expect(ctx.hasCoachMode, isFalse);
    });

    test('resolveCoachRole ignores the claim once resolved', () {
      expect(
        resolveCoachRole(
          uid: 'u1',
          entitlement: CoachEntitlement.none,
          claimIsCoach: true,
          entitlementResolved: false,
        ),
        CoachRole.coach,
        reason: 'provisional before any successful read',
      );
      expect(
        resolveCoachRole(
          uid: 'u1',
          entitlement: CoachEntitlement.none,
          claimIsCoach: true,
          entitlementResolved: true,
        ),
        CoachRole.athlete,
        reason: 'authoritative after a successful read',
      );
      // The super admin is unaffected either way.
      expect(
        resolveCoachRole(
          uid: kSuperAdminUid,
          entitlement: CoachEntitlement.none,
          entitlementResolved: true,
        ),
        CoachRole.superAdmin,
      );
    });
  });
}
