import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/signup_validation.dart';

/// Page 2 (OnboardingPageTwo) required-answer rules and their exact copy.
///
/// The four strings below are specified verbatim by the product owner. They are
/// asserted literally on purpose: a paraphrase is a regression, not a style
/// choice.
void main() {
  /// Everything answered — the baseline the individual cases deviate from.
  List<({String section, String message})> missing({
    bool hasGoal = true,
    bool muscleOrTonedChosen = false,
    bool hasAnyBodyFocus = true,
    bool everyInjuryRated = true,
    bool hasExperience = true,
    bool hasEnvironment = true,
  }) =>
      missingOnboardingRequirements(
        hasGoal: hasGoal,
        muscleOrTonedChosen: muscleOrTonedChosen,
        hasAnyBodyFocus: hasAnyBodyFocus,
        everyInjuryRated: everyInjuryRated,
        hasExperience: hasExperience,
        hasEnvironment: hasEnvironment,
      );

  group('exact Page 2 copy', () {
    test('training experience', () {
      expect(kExperienceMissingMessage, 'Select your training experience level.');
    });

    test('training location / environment', () {
      expect(
        kEnvironmentMissingMessage,
        'Tell us what kind of gym you will usually train at.',
      );
    });

    test('body focus', () {
      expect(
        kBodyFocusMissingMessage,
        "Pick at least one area you'd like to focus on.",
      );
    });

    test('selected injury missing a pain rating', () {
      expect(
        kInjuryPainMissingMessage,
        'Give this a pain rating out of 10 so we can account for it.',
      );
    });

    test('the superseded wording is gone from the whole lib tree', () {
      final stale = [
        'Choose your training experience.',
        'Choose at least one body area to focus on.',
        'Set a pain level (1–10) for each injury you selected.',
        "Choose where you'll be training.",
      ];
      for (final file in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final source = file.readAsStringSync();
        for (final phrase in stale) {
          expect(
            source,
            isNot(contains(phrase)),
            reason: 'stale copy "$phrase" still present in ${file.path}',
          );
        }
      }
    });
  });

  group('each requirement is exercised and reports its exact message', () {
    test('missing training experience', () {
      final result = missing(hasExperience: false);

      expect(result.single.section, OnboardingSection.experience);
      expect(result.single.message, 'Select your training experience level.');
    });

    test('missing training environment', () {
      final result = missing(hasEnvironment: false);

      expect(result.single.section, OnboardingSection.env);
      expect(
        result.single.message,
        'Tell us what kind of gym you will usually train at.',
      );
    });

    test('missing body focus, once muscle/toned was chosen', () {
      final result =
          missing(muscleOrTonedChosen: true, hasAnyBodyFocus: false);

      expect(result.single.section, OnboardingSection.bodyFocus);
      expect(
        result.single.message,
        "Pick at least one area you'd like to focus on.",
      );
    });

    test('body focus is not required when muscle/toned was not chosen', () {
      expect(missing(muscleOrTonedChosen: false, hasAnyBodyFocus: false),
          isEmpty);
    });

    test('a selected injury without a pain rating', () {
      final result = missing(everyInjuryRated: false);

      expect(result.single.section, OnboardingSection.injuries);
      expect(
        result.single.message,
        'Give this a pain rating out of 10 so we can account for it.',
      );
    });

    test('missing goals', () {
      final result = missing(hasGoal: false);

      expect(result.single.section, OnboardingSection.goals);
      expect(result.single.message, 'Pick at least one training goal.');
    });

    test('a fully answered page has nothing missing', () {
      expect(missing(), isEmpty);
    });
  });

  group('the Finish summary reports the first missing item verbatim', () {
    test('the first message is the exact copy, not a paraphrase', () {
      // Everything unanswered: the user must see the FIRST requirement's exact
      // wording, with the remainder only as a supplementary count.
      final result = missing(
        hasGoal: false,
        muscleOrTonedChosen: true,
        hasAnyBodyFocus: false,
        everyInjuryRated: false,
        hasExperience: false,
        hasEnvironment: false,
      );

      expect(result.length, 5);
      expect(result.first.message, 'Pick at least one training goal.');

      // "+N more to finish" is supplementary only — the message itself is exact.
      final more = result.length - 1;
      expect('${result.first.message} (+$more more to finish)',
          'Pick at least one training goal. (+4 more to finish)');
    });

    test('sections are reported in the order the questions appear', () {
      final result = missing(
        hasGoal: false,
        muscleOrTonedChosen: true,
        hasAnyBodyFocus: false,
        everyInjuryRated: false,
        hasExperience: false,
        hasEnvironment: false,
      );

      expect(result.map((r) => r.section).toList(), [
        OnboardingSection.goals,
        OnboardingSection.bodyFocus,
        OnboardingSection.injuries,
        OnboardingSection.experience,
        OnboardingSection.env,
      ]);
    });
  });
}
