/// Durable local draft for one block, written to the athlete-partitioned cache
/// (debounced) so an app kill never loses typed values. Never sent to Firestore.
library;

import 'bp2_date_utils.dart';
import 'bp2_settings_resolver.dart';

class Bp2LocalDraft {
  final String blockId;

  /// Raw Block Name field text (only meaningful when [nameEdited]).
  final String name;

  /// The user typed in the Block Name field.
  final bool nameEdited;

  /// The user changed the date range.
  final bool rangeTouched;
  final Bp2DateRange range;
  final Map<String, Bp2ExerciseDraft> exerciseDrafts;

  /// True once the user has interacted with the block (name/date edit), so a
  /// new block that was merely opened and closed is never written.
  final bool blockTouched;

  const Bp2LocalDraft({
    required this.blockId,
    required this.name,
    required this.nameEdited,
    required this.rangeTouched,
    required this.range,
    required this.exerciseDrafts,
    required this.blockTouched,
  });

  Map<String, dynamic> toJson() => {
        'blockId': blockId,
        'name': name,
        'nameEdited': nameEdited,
        'rangeTouched': rangeTouched,
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
      // Drafts written before these flags existed: fall back to the older
      // `nameIsAuto` / `blockTouched` markers.
      nameEdited: m['nameEdited'] is bool
          ? m['nameEdited'] as bool
          : m.containsKey('nameIsAuto') && m['nameIsAuto'] != true,
      rangeTouched: m['rangeTouched'] is bool
          ? m['rangeTouched'] as bool
          : m['blockTouched'] == true,
      range: Bp2DateUtils.normalizeRange(start, end),
      exerciseDrafts: drafts,
      blockTouched: m['blockTouched'] == true,
    );
  }
}
