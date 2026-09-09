import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/coach_checkin_copy_action.dart';
import 'package:localtest222/coach_checkins_logic.dart';
import 'package:localtest222/coach_weekly_review_screen.dart';

/// Tests the REAL production [CoachAthleteReviewCard] — the exact widget the
/// Weekly Review renders per athlete — plus the real [CheckInCopyAction] that
/// drives its Copy button, without mounting CoachWeeklyReviewScreen (whose
/// load needs Firestore, Cloud Functions and UserContext).
///
/// Covers the two changes: the compact week-planner control in the header row,
/// and the scoped copy flow that must leave the rest of the screen untouched.

const _currentKey = '2026-09-07'; // a Monday checkpoint

AthleteReview _review({
  String uid = 'athlete1',
  String name = 'Ann Athlete',
  String status = CheckInStatus.draft,
  String draft = 'Nice week Ann.',
  String? finalText,
  String? coverageStart,
  String? coverageEnd,
}) {
  final r = AthleteReview(
    uid: uid,
    settings: const {'reportingEnabled': true},
    rosterName: name,
  );
  r.report = <String, dynamic>{
    'status': status,
    'draftIfPrevNotCopied': draft,
    'draftIfPrevCopied': draft,
    if (finalText != null) 'finalText': finalText,
    if (coverageStart != null) 'coverageStart': coverageStart,
    if (coverageEnd != null) 'coverageEnd': coverageEnd,
    'workoutDates': const ['2026-09-01', '2026-09-03'],
    'events': const [],
    'currentWeekAdherence': {
      'completedCount': 2,
      'plannedCount': 4,
      'plannedKnown': true,
      'days': [
        {'weekday': 'Mon', 'trained': true, 'exerciseCount': 5},
        {'weekday': 'Tue', 'trained': false},
        {'weekday': 'Wed', 'trained': true, 'exerciseCount': 4},
        {'weekday': 'Thu', 'trained': false},
        {'weekday': 'Fri', 'trained': false},
        {'weekday': 'Sat', 'trained': false},
        {'weekday': 'Sun', 'trained': false},
      ],
    },
  };
  return r;
}

Widget _wrapCard(
  AthleteReview review, {
  bool busy = false,
  bool mutable = true,
  VoidCallback? onCopy,
  VoidCallback? onOpenPlanner,
}) {
  return MaterialApp(
    home: Scaffold(
      body: CoachAthleteReviewCard(
        review: review,
        currentKey: _currentKey,
        adherence: review.report?['currentWeekAdherence'] as Map<String, dynamic>?,
        busy: busy,
        mutable: mutable,
        onCopy: onCopy ?? () {},
        onRecopy: () {},
        onUndo: () {},
        onSkip: () {},
        onOpenPlanner: onOpenPlanner ?? () {},
      ),
    ),
  );
}

void main() {
  // ── Planner control ──────────────────────────────────────────────────────

  group('week planner control', () {
    testWidgets('renders in the same header row as the name and status chip',
        (tester) async {
      await tester.pumpWidget(_wrapCard(_review()));

      final planner = find.byKey(const ValueKey('openWeekPlannerButton'));
      expect(planner, findsOneWidget);
      expect(find.byTooltip('Open week planner'), findsOneWidget);
      expect(find.byIcon(Icons.calendar_view_week), findsOneWidget);
      expect(find.text('Planner'), findsOneWidget);

      // Same row: vertically centred with the athlete name and the status chip.
      final nameCentre = tester.getCenter(find.text('Ann Athlete')).dy;
      final statusCentre = tester.getCenter(find.text('Draft')).dy;
      final plannerCentre = tester.getCenter(planner).dy;
      expect((plannerCentre - nameCentre).abs(), lessThan(2));
      expect((plannerCentre - statusCentre).abs(), lessThan(2));
      // ...and to the left of the status chip, which stays the row's tail.
      expect(tester.getTopLeft(planner).dx,
          lessThan(tester.getTopLeft(find.text('Draft')).dx));
    });

    testWidgets('does not meaningfully increase the card height',
        (tester) async {
      await tester.pumpWidget(_wrapCard(_review()));

      // The header row is already at least as tall as the 15px name text and
      // the status chip; the control must fit inside that, not extend it.
      final plannerHeight = tester
          .getSize(find.byKey(const ValueKey('openWeekPlannerButton')))
          .height;
      final chipHeight = tester
          .getSize(find.ancestor(
            of: find.text('Draft'),
            matching: find.byType(Container),
          ).first)
          .height;
      expect(plannerHeight, lessThanOrEqualTo(chipHeight));
    });

    testWidgets('reports the card athlete and mutates no report state',
        (tester) async {
      final review = _review(uid: 'athlete_uid_42');
      final before = Map<String, dynamic>.from(review.report!);
      var taps = 0;

      await tester.pumpWidget(_wrapCard(review, onOpenPlanner: () => taps++));
      await tester.tap(find.byKey(const ValueKey('openWeekPlannerButton')));
      await tester.pump();

      expect(taps, 1);
      // Navigation only.
      expect(review.report, before);
      expect(review.status, CheckInStatus.draft);
      expect(find.text('Draft'), findsOneWidget);
    });

    testWidgets('is available whatever the check-in status is', (tester) async {
      for (final status in [
        CheckInStatus.draft,
        CheckInStatus.copied,
        CheckInStatus.skipped,
        'pending',
      ]) {
        await tester.pumpWidget(_wrapCard(_review(
          status: status,
          finalText: 'sent text',
          coverageStart: '2026-09-03',
          coverageEnd: _currentKey,
        )));
        expect(find.byKey(const ValueKey('openWeekPlannerButton')), findsOneWidget,
            reason: 'planner control missing for status "$status"');
      }
    });
  });

  // ── Copied-state rendering ───────────────────────────────────────────────

  group('copied state reconciled from the callable response', () {
    test('applyCopyOutcome takes status, finalText and both coverage fields',
        () {
      final review = _review();
      review.applyCopyOutcome(const CheckInCopyOutcome(
        status: CheckInCopyStatus.copied,
        text: 'server frozen text',
        reportPatch: {
          'status': CheckInStatus.copied,
          'finalText': 'server frozen text',
          'coverageStart': '2026-08-31',
          'coverageEnd': _currentKey,
        },
        coverageEnd: _currentKey,
      ));

      expect(review.status, CheckInStatus.copied);
      expect(review.draftPreview, 'server frozen text');
      expect(review.coverage(_currentKey).start, '2026-08-31');
      expect(review.coverage(_currentKey).end, _currentKey);
      // The same transaction advanced the coach-side watermark.
      expect(review.settings['lastFinalizedCoverageEnd'], _currentKey);
      // The draft fields are left alone — nothing else was invented locally.
      expect(review.report!['draftIfPrevNotCopied'], 'Nice week Ann.');
    });

    testWidgets('the card shows Copied and the exact finalText', (tester) async {
      final review = _review();
      review.applyCopyOutcome(const CheckInCopyOutcome(
        status: CheckInCopyStatus.copied,
        text: 'server frozen text',
        reportPatch: {
          'status': CheckInStatus.copied,
          'finalText': 'server frozen text',
          'coverageStart': '2026-08-31',
          'coverageEnd': _currentKey,
        },
        coverageEnd: _currentKey,
      ));

      await tester.pumpWidget(_wrapCard(review));

      expect(find.text('Copied'), findsNWidgets(2)); // status chip + button row
      expect(find.text('Draft'), findsNothing);
      expect(find.text('server frozen text'), findsOneWidget);
      expect(find.text('Nice week Ann.'), findsNothing);
      expect(find.text('Copy Message'), findsNothing);
      expect(find.text('Undo / Mark Not Sent'), findsOneWidget);
      // Coverage comes from the frozen pair the server returned.
      expect(find.text('Coverage 2026-08-31 → $_currentKey'), findsOneWidget);
    });

    testWidgets('the Monday–Sunday strip and adherence fact are unchanged',
        (tester) async {
      await tester.pumpWidget(_wrapCard(_review()));

      expect(find.text('Mon ✓5 · Tue — · Wed ✓4 · Thu —'), findsOneWidget);
      expect(find.text('Fri — · Sat — · Sun —'), findsOneWidget);
      expect(find.text('2 done · week 2/4 planned'), findsOneWidget);
    });

    testWidgets('skipped and undone states still render as before',
        (tester) async {
      await tester.pumpWidget(_wrapCard(_review(status: CheckInStatus.skipped)));
      expect(find.text('Skipped'), findsOneWidget);
      expect(find.text('Copy Message'), findsNothing);

      // Undo puts the report back to draft; the Copy button returns.
      await tester.pumpWidget(_wrapCard(_review()));
      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('Copy Message'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
    });

    testWidgets('a non-mutable check-in cannot be copied or undone',
        (tester) async {
      await tester.pumpWidget(_wrapCard(_review(), mutable: false));
      final copy = tester.widget<ElevatedButton>(
          find.ancestor(of: find.text('Copy Message'), matching: find.byType(ElevatedButton)));
      expect(copy.onPressed, isNull);
    });

    testWidgets('the pending state is a spinner on the button only',
        (tester) async {
      await tester.pumpWidget(_wrapCard(_review(), busy: true));

      // One small indicator, inside the Copy button — never a screen-wide one.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ElevatedButton),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(tester.getSize(find.byType(CircularProgressIndicator)),
          const Size(14, 14));
    });
  });

  // ── Whole-list stability during a copy ───────────────────────────────────

  group('copying one athlete leaves the rest of the list alone', () {
    testWidgets('scroll offset, other cards and the list itself are preserved',
        (tester) async {
      final clipboard = <String>[];
      final action = CheckInCopyAction(
        invoke: ({required athleteUid, required checkpointKey}) async => {
          'text': 'frozen for $athleteUid',
          'coverageStart': '2026-08-31',
          'coverageEnd': checkpointKey,
        },
        writeClipboard: (t) async => clipboard.add(t),
      );

      final reviews = [
        for (var i = 1; i <= 6; i++)
          _review(uid: 'athlete$i', name: 'Athlete $i', draft: 'Draft $i'),
      ];
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_ReviewListHarness(
        reviews: reviews,
        action: action,
        controller: controller,
      ));
      await tester.pump();

      await tester.drag(find.byType(ListView), const Offset(0, -60));
      await tester.pump();
      final offsetBefore = controller.offset;
      expect(offsetBefore, greaterThan(0));

      final elementsBefore = tester
          .widgetList<CoachAthleteReviewCard>(find.byType(CoachAthleteReviewCard))
          .map((c) => c.review.uid)
          .toList();
      expect(elementsBefore, contains('athlete1'));

      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('weeklyReviewCard_athlete1')),
        matching: find.text('Copy Message'),
      ));
      await tester.pump(); // pending state
      await tester.pump(); // callable + clipboard resolve

      // The one card that was acted on flipped, using the server's text.
      expect(clipboard, ['frozen for athlete1']);
      expect(reviews.first.status, CheckInStatus.copied);
      expect(reviews.first.report!['finalText'], clipboard.single);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('weeklyReviewCard_athlete1')),
          matching: find.text('frozen for athlete1'),
        ),
        findsOneWidget,
      );

      // Nothing else moved: same offset, same cards, no full-screen loader.
      expect(controller.offset, offsetBefore);
      expect(
        tester
            .widgetList<CoachAthleteReviewCard>(
                find.byType(CoachAthleteReviewCard))
            .map((c) => c.review.uid)
            .toList(),
        elementsBefore,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(ListView), findsOneWidget);
      for (var i = 2; i <= 3; i++) {
        expect(reviews[i - 1].status, CheckInStatus.draft,
            reason: 'athlete$i must be untouched');
      }
    });

    testWidgets('rapid repeat taps produce exactly one finalisation',
        (tester) async {
      var invocations = 0;
      final action = CheckInCopyAction(
        invoke: ({required athleteUid, required checkpointKey}) async {
          invocations++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return {'text': 'msg', 'coverageEnd': checkpointKey};
        },
        writeClipboard: (_) async {},
      );
      final reviews = [_review(uid: 'athlete1')];
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_ReviewListHarness(
        reviews: reviews,
        action: action,
        controller: controller,
      ));

      final copy = find.text('Copy Message');
      await tester.tap(copy);
      await tester.tap(copy, warnIfMissed: false);
      await tester.tap(copy, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();

      expect(invocations, 1);
      expect(reviews.single.status, CheckInStatus.copied);
    });
  });

  // ── The requirement that copy never triggers the screen reload ───────────

  test('_copyMessage never calls the global _load() or touches _loading', () {
    final source =
        File('lib/coach_weekly_review_screen.dart').readAsStringSync();
    final body = _methodBody(source, 'Future<void> _copyMessage(');

    expect(body, isNotEmpty);
    expect(body.contains('_load('), isFalse,
        reason: 'copy must never trigger the whole-screen reload');
    expect(body.contains('_loading'), isFalse,
        reason: 'copy must never put the screen into a loading state');
    // It must still go through the scoped action and the per-card pending set.
    expect(body.contains('_copyAction.run('), isTrue);
    expect(body.contains('_copyPending'), isTrue);
  });
}

/// Returns the body of the method whose signature starts with [signature],
/// by brace matching from the first `{` after it.
String _methodBody(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return '';
  var i = source.indexOf('{', start);
  if (i < 0) return '';
  var depth = 0;
  final open = i;
  for (; i < source.length; i++) {
    final c = source[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  return '';
}

/// Small harness reproducing exactly what the screen does on Copy: run the
/// scoped action, apply its outcome to that ONE review, setState. No global
/// loading flag and no list rebuild from scratch.
class _ReviewListHarness extends StatefulWidget {
  const _ReviewListHarness({
    required this.reviews,
    required this.action,
    required this.controller,
  });

  final List<AthleteReview> reviews;
  final CheckInCopyAction action;
  final ScrollController controller;

  @override
  State<_ReviewListHarness> createState() => _ReviewListHarnessState();
}

class _ReviewListHarnessState extends State<_ReviewListHarness> {
  final Set<String> _copyPending = {};

  Future<void> _copy(AthleteReview a) async {
    if (_copyPending.contains(a.uid)) return;
    setState(() => _copyPending.add(a.uid));
    try {
      await widget.action.run(
        athleteUid: a.uid,
        checkpointKey: _currentKey,
        onFinalised: (o) {
          if (!mounted) return;
          setState(() => a.applyCopyOutcome(o));
        },
      );
    } finally {
      if (mounted) setState(() => _copyPending.remove(a.uid));
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ListView.separated(
          controller: widget.controller,
          itemCount: widget.reviews.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (_, i) {
            final a = widget.reviews[i];
            return CoachAthleteReviewCard(
              key: ValueKey('weeklyReviewCard_${a.uid}'),
              review: a,
              currentKey: _currentKey,
              adherence:
                  a.report?['currentWeekAdherence'] as Map<String, dynamic>?,
              busy: _copyPending.contains(a.uid),
              mutable: true,
              onCopy: () => _copy(a),
              onRecopy: () {},
              onUndo: () {},
              onSkip: () {},
              onOpenPlanner: () {},
            );
          },
        ),
      ),
    );
  }
}
