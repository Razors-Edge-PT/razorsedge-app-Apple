// Pins lib/social/search_normalize.dart to functions/social/search_normalize.js.
//
// The index is WRITTEN by the JavaScript indexer and READ by this Dart code.
// Nothing at runtime checks that the two agree, and a disagreement does not
// throw — it just means a query never matches the terms that were stored, so
// search silently returns nothing for exactly the accounts whose names needed
// normalising most. That is the failure this file exists to make loud.
//
// Both suites read functions/social/search_normalize_vectors.json, generated
// from the JS implementation by functions/scripts/gen_search_vectors.js. The
// expectations are therefore not hand-written in either language: they are the
// indexer's actual output, asserted against the client's actual output.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/social/search_normalize.dart';

Map<String, dynamic> _loadVectors() {
  final File file =
      File('functions/social/search_normalize_vectors.json');
  if (!file.existsSync()) {
    fail(
      'Shared vector file missing at ${file.path}. '
      'Run: cd functions && node scripts/gen_search_vectors.js',
    );
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final Map<String, dynamic> vectors = _loadVectors();

  group('normalizeText parity with the JavaScript indexer', () {
    for (final dynamic raw in vectors['normalize'] as List<dynamic>) {
      final Map<String, dynamic> v = raw as Map<String, dynamic>;
      final String input = v['input'] as String;
      final String expected = v['expected'] as String;
      test('normalizes ${jsonEncode(input)}', () {
        expect(normalizeText(input), expected);
      });
    }
  });

  group('compactText parity with the JavaScript indexer', () {
    for (final dynamic raw in vectors['compact'] as List<dynamic>) {
      final Map<String, dynamic> v = raw as Map<String, dynamic>;
      test('compacts ${jsonEncode(v['input'])}', () {
        expect(compactText(v['input'] as String), v['expected'] as String);
      });
    }
  });

  group('queryGrams parity with the JavaScript indexer', () {
    for (final dynamic raw in vectors['queryGrams'] as List<dynamic>) {
      final Map<String, dynamic> v = raw as Map<String, dynamic>;
      test('grams for ${jsonEncode(v['input'])}', () {
        expect(
          queryGrams(v['input'] as String),
          (v['expected'] as List<dynamic>).cast<String>(),
        );
      });
    }
  });

  group('a query matches the terms the indexer actually stored', () {
    // The parity that matters operationally: whatever the indexer wrote for an
    // account, the client's normalisation of a plausible query for that
    // account has to land inside it. A per-function assertion can pass while
    // this fails, which is why it is asserted separately.
    for (final dynamic raw in vectors['tokens'] as List<dynamic>) {
      final Map<String, dynamic> v = raw as Map<String, dynamic>;
      final Map<String, dynamic> identity =
          (v['identity'] as Map<String, dynamic>);
      final Map<String, dynamic> expected =
          (v['expected'] as Map<String, dynamic>);
      final List<String> terms =
          (expected['terms'] as List<dynamic>).cast<String>();
      final List<String> prefixes =
          (expected['prefixes'] as List<dynamic>).cast<String>();
      final List<String> grams =
          (expected['grams'] as List<dynamic>).cast<String>();

      test('${identity['username']} is reachable by its own fields', () {
        for (final String field in <String>[
          identity['username'] as String,
          identity['firstName'] as String,
          identity['lastName'] as String,
          identity['displayName'] as String,
        ]) {
          final String normalized = normalizeText(field);
          if (normalized.isEmpty) continue;
          expect(
            terms.contains(normalized) || prefixes.contains(normalized),
            isTrue,
            reason:
                'querying "$field" normalises to "$normalized", which is in '
                'neither the stored terms nor the stored prefixes — the '
                'account would be unfindable by its own name',
          );
        }
      });

      test('${identity['username']} shares grams with a typed query', () {
        final String probe = identity['firstName'] as String;
        final List<String> asked = queryGrams(probe);
        if (asked.isEmpty) return;
        expect(
          asked.any(grams.contains),
          isTrue,
          reason:
              'no trigram of "$probe" appears in the stored gram set, so the '
              'fuzzy fallback could never surface this account',
        );
      });
    }
  });

  group('prefix generation', () {
    test('starts at the minimum query length and stops at the cap', () {
      final List<String> p = prefixesOf('abcdefghijklmnopqrstuvwxyz');
      expect(p.first.length, kMinQuery);
      expect(p.last.length, kMaxPrefix);
    });

    test('a string shorter than the minimum produces no prefixes', () {
      expect(prefixesOf('a'), isEmpty);
    });

    test('never splits a surrogate pair', () {
      // Slicing by code unit would produce a lone high surrogate, which is a
      // prefix no keyboard can ever produce.
      final List<String> p = prefixesOf('🏋🏋🏋');
      for (final String prefix in p) {
        expect(prefix.runes.length * 2, prefix.length,
            reason: 'prefix "$prefix" split a surrogate pair');
      }
    });
  });

  group('damerauLevenshtein', () {
    test('an adjacent transposition costs one, not two', () {
      // The whole reason for Damerau over plain Levenshtein: `jhon` is one
      // slip, and scoring it 2 buries the person you meant behind unrelated
      // two-substitution noise.
      expect(damerauLevenshtein('jhon', 'john'), 1);
    });

    test('scores a substitution, an insertion and a deletion as one each', () {
      expect(damerauLevenshtein('john', 'john'), 0);
      expect(damerauLevenshtein('jonn', 'john'), 1);
      expect(damerauLevenshtein('jon', 'john'), 1);
      expect(damerauLevenshtein('johnn', 'john'), 1);
    });

    test('stops early rather than scoring a hopeless pair exactly', () {
      expect(
        damerauLevenshtein('aaaaaaaa', 'zzzzzzzz', maxDistance: 2),
        greaterThan(2),
      );
    });

    test('handles empty input on either side', () {
      expect(damerauLevenshtein('', 'john'), 4);
      expect(damerauLevenshtein('john', ''), 4);
      expect(damerauLevenshtein('', ''), 0);
    });
  });
}
