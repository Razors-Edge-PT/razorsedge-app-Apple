/// Durable local draft for one block, written to the athlete-partitioned cache
/// (debounced) so an app kill never loses typed values. Never sent to Firestore.
library;

import 'bp2_date_utils.dart';
import 'bp2_settings_resolver.dart';

class Bp2LocalDraft {
  final String blockId;
  final String name;
  final bool nameIsAuto;
  final Bp2DateRange range;
  final Map<String, Bp2ExerciseDraft> exerciseDrafts;

  /// True once the user has interacted with the block (name/date edit), so a
  /// new block that was merely opened and closed is never written.
  final bool blockTouched;

  const Bp2LocalDraft({
    required this.blockId,
    required this.name,
    required this.nameIsAuto,
    required this.range,
    required this.exerciseDrafts,
    required this.blockTouched,
  });

  Map<String, dynamic> toJson() => {
        'blockId': blockId,
        'name': name,
        'nameIsAuto': nameIsAuto,
        'start': range.start.toIso8601String(),
        'end': range.end.toIso8601String(),
        'blockTouched': blockTouched,
        'exerciseDrafts': exerciseDrafts.map((k, v) => MapEntry(k, v.toJson())),
      };

  static Bp2LocalDraft? fromJson(Map<String, dynamic> m) {
    final start = DateTime.tryParse((m['start'] ?? '').toString());
    final end = DateTime.tryParse((m['end'] ?? '').toString());
    final blockId = (m['blockId'] ?? '').toString();
    if (start == null || end == null || blockId.isEmpty) return null;
    final drafts = <String, Bp2ExerciseDraft>{};
    final raw = m['exerciseDrafts'];
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is Map) {
          final d = Bp2ExerciseDraft.fromJson(Map<String, dynamic>.from(v));
          if (!d.isEmpty) drafts[k.toString()] = d;
        }
      });
    }
    return Bp2LocalDraft(
      blockId: blockId,
      name: (m['name'] ?? '').toString(),
      nameIsAuto: m['nameIsAuto'] == true,
      range: Bp2DateUtils.normalizeRange(start, end),
      exerciseDrafts: drafts,
      blockTouched: m['blockTouched'] == true,
    );
  }
}
