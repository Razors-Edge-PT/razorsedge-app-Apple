import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/big_five.dart';

/// Client/server parity for the canonical point-scoring lift list.
///
/// `lib/profile/core/big_five.dart` and `functions/showcase/big_five.js` are
/// pinned mirrors, and each already has its own suite asserting the ids and
/// rejections it expects. Nothing, however, compared the two files — so a lift
/// added to one side and not the other would leave both suites green.
///
/// That matters now for two reasons. The list is expected to grow by roughly
/// five more lifts, and the WES2 set-video feature publishes a clip only when
/// the SERVER projection confirms the fingerprint the CLIENT computed. If the
/// two lists disagree, the client offers footage for a lift the server never
/// scores, and the clip is queued and then never confirmed.
///
/// This reads the JavaScript source directly rather than importing it: there is
/// no JS runtime in a Dart test, and the file's shape is stable and simple.

/// One lift as declared on the server.
class _ServerLift {
  _ServerLift(this.slot, this.exerciseId, this.displayName, this.aliases);

  final String slot;
  final String exerciseId;
  final String displayName;
  final List<String> aliases;
}

/// Locates the repository root from the test's working directory.
File _serverFile() {
  final Directory cwd = Directory.current;
  for (Directory d = cwd; d.parent.path != d.path; d = d.parent) {
    final File f = File('${d.path}/functions/showcase/big_five.js');
    if (f.existsSync()) return f;
  }
  fail('functions/showcase/big_five.js not found from ${cwd.path}');
}

List<_ServerLift> _parseServerLifts(String source) {
  // Resolve the SLOTS.* indirection the server list uses for its slot keys.
  final Map<String, String> slotConstants = <String, String>{};
  for (final RegExpMatch m in RegExp(r"(\w+):\s*'([^']+)',").allMatches(
    RegExp(r'const SLOTS = \{(.*?)\};', dotAll: true)
            .firstMatch(source)
            ?.group(1) ??
        '',
  )) {
    slotConstants[m.group(1)!] = m.group(2)!;
  }
  expect(slotConstants, isNotEmpty, reason: 'could not read the SLOTS map');

  final String body = RegExp(r'const BIG_FIVE = \[(.*?)\n\];', dotAll: true)
          .firstMatch(source)
          ?.group(1) ??
      '';
  expect(body, isNotEmpty, reason: 'could not read the BIG_FIVE list');

  final List<_ServerLift> lifts = <_ServerLift>[];
  for (final RegExpMatch entry
      in RegExp(r'\{(.*?)\n  \}', dotAll: true).allMatches(body)) {
    final String block = entry.group(1)!;

    final String slotRef =
        RegExp(r'slot:\s*SLOTS\.(\w+)').firstMatch(block)!.group(1)!;
    final String id =
        RegExp(r"exerciseId:\s*'([^']+)'").firstMatch(block)!.group(1)!;
    final String name =
        RegExp(r"displayName:\s*'([^']+)'").firstMatch(block)!.group(1)!;
    final String aliasBody =
        RegExp(r'legacyNameAliases:\s*\[(.*?)\]', dotAll: true)
            .firstMatch(block)!
            .group(1)!;
    final List<String> aliases = RegExp(r"'([^']+)'")
        .allMatches(aliasBody)
        .map((RegExpMatch m) => m.group(1)!)
        .toList();

    lifts.add(_ServerLift(slotConstants[slotRef]!, id, name, aliases));
  }
  return lifts;
}

void main() {
  late List<_ServerLift> server;

  setUpAll(() {
    server = _parseServerLifts(_serverFile().readAsStringSync());
  });

  test('the parser actually found the server list', () {
    expect(server, isNotEmpty);
    expect(server.first.exerciseId, isNotEmpty);
  });

  test('both platforms declare the same number of lifts', () {
    expect(server.length, kBigFive.length,
        reason: 'a lift added to one platform only would silently never score');
  });

  test('slots agree, in the same display order', () {
    expect(server.map((l) => l.slot).toList(),
        kBigFive.map((l) => l.slot).toList());
    expect(server.map((l) => l.slot).toList(), BigFiveSlot.ordered);
  });

  test('catalogue ids agree exactly, slot for slot', () {
    for (final _ServerLift s in server) {
      final BigFiveLift? client = bigFiveBySlot(s.slot);
      expect(client, isNotNull, reason: 'client has no ${s.slot} slot');
      expect(client!.exerciseId, s.exerciseId,
          reason: 'ids must match for ${s.slot}, or the fingerprint differs');
    }
  });

  test('display names agree', () {
    for (final _ServerLift s in server) {
      expect(bigFiveBySlot(s.slot)!.displayName, s.displayName);
    }
  });

  test('legacy name aliases agree exactly', () {
    for (final _ServerLift s in server) {
      final BigFiveLift client = bigFiveBySlot(s.slot)!;
      expect(client.legacyNameAliases, s.aliases,
          reason: 'an alias on one side only resolves id-less rows differently '
              'on each platform, splitting one lift history in two');
    }
  });

  test('folded ids agree, since every stream key is folded', () {
    for (final _ServerLift s in server) {
      expect(bigFiveBySlot(s.slot)!.foldedId, s.exerciseId.toLowerCase());
    }
  });

  test('no slot key is duplicated on either side', () {
    expect(server.map((l) => l.slot).toSet().length, server.length);
    expect(kBigFive.map((l) => l.slot).toSet().length, kBigFive.length);
  });

  test('no catalogue id is duplicated on either side', () {
    expect(server.map((l) => l.exerciseId).toSet().length, server.length);
    expect(kBigFive.map((l) => l.exerciseId).toSet().length, kBigFive.length);
  });

  test('every client lift is matched by its own id and canonical name', () {
    // Guards the property the set-video feature relies on: whatever the list
    // grows to, matchBigFive resolves each entry without anything naming it.
    for (final BigFiveLift lift in kBigFive) {
      expect(matchBigFive(rawId: lift.exerciseId)?.slot, lift.slot);
      for (final String alias in lift.legacyNameAliases) {
        expect(matchBigFive(rawName: alias)?.slot, lift.slot,
            reason: '$alias must resolve to ${lift.slot}');
      }
    }
  });
}
