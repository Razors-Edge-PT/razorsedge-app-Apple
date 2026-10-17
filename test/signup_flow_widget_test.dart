// End-to-end widget coverage of the two signup pages driven through the real
// UI, with the production SignupCoordinator + FirestoreSignupBackend over
// fakes (see test/signup/signup_test_harness.dart).
//
// Reproduces the reported defects and pins their fixes:
//  * Back from Page 2 used to discard every answer (they lived only in the
//    Page 2 State); a username collision did the same.
//  * Finish was blocked by a pre-account availability read that a logged-out
//    device can never perform.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/create_new_account_screen.dart';
import 'package:localtest222/signup/signup_coordinator.dart';

import 'signup/signup_test_harness.dart';

/// Page 2's existing layout puts ListTiles inside decorated Containers, which
/// trips a debug-only "ink splashes may be invisible" assertion (pre-existing,
/// unrelated to signup, absent from release builds). Ignore exactly that
/// message so every other framework error still fails the test.
void _tolerateExistingListTileInkAssertion() {
  final original = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details
        .exceptionAsString()
        .contains('ListTile background color or ink splashes may be invisible')) {
      return;
    }
    original?.call(details);
  };
  addTearDown(() => FlutterError.onError = original);
}

Future<void> _openSignup(WidgetTester tester, SignupCoordinator coordinator) async {
  _tolerateExistingListTileInkAssertion();
  tester.view.physicalSize = const Size(1400, 9000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => CreateNewAccountScreen(coordinator: coordinator),
            )),
            child: const Text('Create account'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Create account'));
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextFormField, label);

Future<void> _tapText(WidgetTester tester, String text) async {
  final f = find.text(text).last;
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _tapFinder(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _tapCheckbox(WidgetTester tester, String label) =>
    _tapFinder(tester, find.widgetWithText(CheckboxListTile, label));

Future<void> _tapChip(WidgetTester tester, String label) =>
    _tapFinder(tester, find.widgetWithText(ChoiceChip, label));

Future<void> _tapBack(WidgetTester tester) =>
    _tapFinder(tester, find.widgetWithText(OutlinedButton, 'Back'));

Future<void> _fillPageOne(WidgetTester tester, {required String username}) async {
  await tester.enterText(_field('Username'), username);
  await tester.enterText(_field('Full Name'), 'Anna Lift');
  await tester.enterText(_field('Email'), 'anna@example.test');
  await tester.enterText(_field('Password'), 'secret123');
  await tester.enterText(_field('Confirm Password'), 'secret123');
  await tester.pump(const Duration(milliseconds: 500)); // username debounce

  await tester.tap(find.text('Select your date of birth'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Done'));
  await tester.pumpAndSettle();

  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Female').last);
  await tester.pumpAndSettle();
}

Future<void> _continue(WidgetTester tester) async {
  await _tapText(tester, 'Continue');
  expect(find.text('Set your training priorities'), findsOneWidget);
}

bool _checked(WidgetTester tester, String label) =>
    tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, label)).value ==
    true;

T? _radioGroup<T>(WidgetTester tester, String label) =>
    // The screen still uses groupValue; read back exactly what it renders.
    // ignore: deprecated_member_use
    tester.widget<RadioListTile<T>>(find.widgetWithText(RadioListTile<T>, label)).groupValue;

T _radioValue<T>(WidgetTester tester, String label) =>
    tester.widget<RadioListTile<T>>(find.widgetWithText(RadioListTile<T>, label)).value;

List<String> _visibleGoalOrder(WidgetTester tester) {
  const goals = [
    'Get stronger', 'Build more muscle', 'Get fitter', 'Powerlifting',
    'Get leaner', 'Feel healthier / move better', 'Tone and shape',
    'Defeat my gym nemesis', 'Power-Building', 'Bench Press Specialist',
  ];
  final ys = {for (final g in goals) g: tester.getTopLeft(find.text(g)).dy};
  return goals.toList()..sort((a, b) => ys[a]!.compareTo(ys[b]!));
}

double _sliderValue(WidgetTester tester, int index) =>
    tester.widget<Slider>(find.byType(Slider).at(index)).value;

/// Fills non-default answers in every Page 2 section. Returns what was set
/// where it cannot be predicted exactly (drag / slider positions).
Future<({List<String> goals, double kneePain})> _fillPageTwo(WidgetTester tester) async {
  // Goals: long-press drag "Get fitter" above "Get stronger".
  final from = tester.getCenter(find.text('Get fitter'));
  final gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 700));
  await gesture.moveBy(const Offset(0, -140), timeStamp: const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.up();
  await tester.pumpAndSettle();
  final goals = _visibleGoalOrder(tester);

  // Injuries + pain + shoulder/elbow detail.
  await _tapCheckbox(tester, 'Knees');
  await _tapCheckbox(tester, 'Shoulders');
  await _tapCheckbox(tester, 'Elbows');
  final kneeSlider = find.byType(Slider).first;
  final box = tester.getRect(kneeSlider);
  await tester.tapAt(Offset(box.left + box.width * 0.85, box.center.dy));
  await tester.pumpAndSettle();
  final kneePain = _sliderValue(tester, 0);
  await _tapCheckbox(tester, 'Pressing above my head');
  await _tapCheckbox(tester, 'The outside hurts');

  // Experience + PT history (labels depend on sex/DOB).
  await _tapText(tester, '2+ years');
  final ptTiles = find.byType(RadioListTile<int>);
  expect(ptTiles, findsWidgets);
  await _tapText(tester, 'Had some help (4–16 sessions)');

  // Body focus: Chest x2, More specific, Back x1, then a child.
  await _tapChip(tester, 'Chest');
  await _tapChip(tester, 'Chest');
  await _tapChip(tester, 'Back');
  await _tapChip(tester, 'More specific');
  await _tapChip(tester, 'Lats');

  // Environment, equipment, dumbbells.
  await _tapChip(tester, 'Home gym');
  await _tapCheckbox(tester, 'Smith Machine');
  await _tapCheckbox(tester, 'Leg Press');
  await _tapText(tester, 'up to 30');

  // Weekly frequency + effort.
  await _tapText(tester, '5  X week');
  await _tapText(tester, 'Make me work');

  return (goals: goals, kneePain: kneePain);
}

void _expectPageTwoRestored(WidgetTester tester,
    ({List<String> goals, double kneePain}) expected) {
  expect(_visibleGoalOrder(tester), expected.goals);
  expect(_checked(tester, 'Knees'), isTrue);
  expect(_checked(tester, 'Shoulders'), isTrue);
  expect(_checked(tester, 'Elbows'), isTrue);
  expect(_checked(tester, 'Neck'), isFalse);
  expect(_sliderValue(tester, 0), expected.kneePain);
  expect(_checked(tester, 'Pressing above my head'), isTrue);
  expect(_checked(tester, 'Pressing out in front of me'), isFalse);
  expect(_checked(tester, 'The outside hurts'), isTrue);
  expect(_radioGroup<TrainingExperience>(tester, '2+ years'),
      TrainingExperience.twoPlus);
  expect(
      _radioGroup<int>(tester, 'Had some help (4–16 sessions)'),
      _radioValue<int>(tester, 'Had some help (4–16 sessions)'));
  expect(find.text('Less specific'), findsOneWidget,
      reason: 'More specific toggle restored');
  expect(find.text('Lats'), findsOneWidget, reason: 'child levels visible');
  expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Home gym')).selected,
      isTrue);
  expect(_checked(tester, 'Smith Machine'), isTrue);
  expect(_checked(tester, 'Leg Press'), isTrue);
  expect(_checked(tester, 'Hack Squat'), isFalse);
  expect(_radioGroup<int>(tester, 'up to 30'), 30);
  expect(_radioGroup<int>(tester, '5  X week'), 5);
  expect(_radioGroup<int>(tester, 'Make me work'), 3);
}

void main() {
  testWidgets(
      'answers survive UI Back, system Back, a username change and a collision, '
      'then Finish persists them', (tester) async {
    final h = SignupHarness();
    h.server.reserve('IronAnna2', 'someone_else');
    await _openSignup(tester, h.coordinator);

    await _fillPageOne(tester, username: 'IronAnna');
    await _continue(tester);
    final expected = await _fillPageTwo(tester);
    expect(expected.goals.first, 'Get fitter', reason: 'drag reordered goals');

    // 1) UI Back, then Continue: everything is restored.
    await _tapBack(tester);
    expect(find.text('Build your training profile'), findsOneWidget);
    expect(find.text('IronAnna'), findsOneWidget);
    await _continue(tester);
    _expectPageTwoRestored(tester, expected);

    // 2) System / predictive Back, change the username, Continue.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Build your training profile'), findsOneWidget);
    await tester.enterText(_field('Username'), 'IronAnna2');
    await tester.pump(const Duration(milliseconds: 500));
    await _continue(tester);
    _expectPageTwoRestored(tester, expected);

    // 3) Finish with a name someone else holds: back to the field, with the
    //    server's verdict on it, and nothing lost.
    await _tapText(tester, 'Finish');
    await tester.pumpAndSettle();
    expect(find.text('Build your training profile'), findsOneWidget);
    expect(find.text("That username's already taken — try another."), findsOneWidget);
    expect(find.textContaining('check your connection', findRichText: true), findsNothing);
    final uid = h.coordinator.current!.authUid!;

    // Email/password are locked to the account already created.
    expect(tester.widget<TextField>(find.descendant(
        of: _field('Email'), matching: find.byType(TextField))).enabled, isFalse);

    await tester.enterText(_field('Username'), 'IronAnna3');
    await tester.pump(const Duration(milliseconds: 500));
    await _continue(tester);
    _expectPageTwoRestored(tester, expected);

    // 4) Finish succeeds for the same account and persists every answer. The
    //    spinner stays up until AppRoot routes, so this never settles.
    await tester.ensureVisible(find.text('Finish'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(h.coordinator.takeCompletedUid(), uid);
    expect(h.auth.calls.where((c) => c == 'create'), hasLength(1));

    final user = (await h.doc('users/$uid'))!;
    expect(user['username'], 'IronAnna3');
    expect(user['sex'], 'F');
    expect(user['fullName'], 'Anna Lift');
    expect(h.server.holderOf('IronAnna2'), 'someone_else');

    final onb = (await h.doc('users/$uid/profile/fitness_onboarding'))!;
    expect(onb['goalsRanked'], expected.goals);
    expect((onb['injuries'] as List).toSet(), {'Knees', 'Shoulders', 'Elbows'});
    expect((onb['painNow'] as Map)['Knees'], expected.kneePain.round());
    expect(onb['shoulderPainOverhead'], true);
    expect(onb['shoulderPainFront'], false);
    expect(onb['elbowPainOutside'], true);
    expect(onb['elbowPainInside'], false);
    expect(onb['experience'], 'twoPlus');
    expect((onb['ptHistory'] as Map)['index'], 2);
    expect((onb['bodyFocusLevel'] as Map)['Chest'], 2);
    expect((onb['bodyFocusLevel'] as Map)['Back'], greaterThan(0));
    expect((onb['bodyFocusChildren'] as Map)['Back'], isNotNull);
    expect(onb['environment'], 'home');
    expect(((onb['equipment'] as Map)['items'] as List).toSet(),
        {'Smith Machine', 'Leg Press'});
    expect((onb['equipment'] as Map)['dumbbellsMax'], 30);
    expect(onb['weeklyFrequency'], 5);
    expect(onb['trainingEffort'], 3);
    expect(await h.blockCount(uid), 3);
  });

  testWidgets('leaving signup cancels the attempt; the next one starts empty',
      (tester) async {
    final h = SignupHarness();
    await _openSignup(tester, h.coordinator);
    await _fillPageOne(tester, username: 'FirstPerson');
    await _continue(tester);
    await _tapCheckbox(tester, 'Knees');

    await _tapBack(tester); // to Page 1
    await tester.binding.handlePopRoute(); // to Login
    await tester.pumpAndSettle();
    expect(h.coordinator.current, isNull);

    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(find.text('FirstPerson'), findsNothing);
    expect(h.coordinator.current!.draft.onboarding.injuries, isEmpty);
  });

  testWidgets('edit mode (drawer / Templates) never binds to a signup draft',
      (tester) async {
    final h = SignupHarness();
    final attempt = h.beginFilled();
    attempt.draft.onboarding.injuries.add('Neck');
    _tolerateExistingListTileInkAssertion();
    tester.view.physicalSize = const Size(1400, 9000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        settings: const RouteSettings(arguments: {'entryFrom': 'drawer'}),
        builder: (_) => const OnboardingPageTwo(
          email: 'member@example.test',
          password: 'edit-mode',
          sex: 'F',
          dob: '07-04-1992',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Save Changes'), findsOneWidget);
    expect(find.text('Back to Home'), findsOneWidget);
    expect(_checked(tester, 'Neck'), isFalse);
    await _tapCheckbox(tester, 'Knees');
    expect(attempt.draft.onboarding.injuries, {'Neck'},
        reason: 'edit-mode changes never touch a signup draft');
  });
}
